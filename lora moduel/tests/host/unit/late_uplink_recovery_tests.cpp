#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

#include "fixtures/mavlink_fixtures.hpp"
#include "vc_lora/embedded_io_adapter.hpp"
#include "vc_lora/late_uplink_recovery.hpp"
#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_link_demux.hpp"
#include "vc_lora/tdd_vehicle.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint16_t kSession = 0x4102U;
constexpr std::uint16_t kCycle = 7U;

TddInput input_at(std::uint64_t now_ms) noexcept {
  TddInput input{};
  input.now_ms = now_ms;
  input.aux_high = true;
  input.radio_tx_empty = true;
  input.local_tx_empty = true;
  return input;
}

TddControlMessage terminal(ControlType type, std::uint16_t actual_bytes,
                           std::uint16_t session = kSession,
                           std::uint16_t cycle = kCycle) noexcept {
  TddControlMessage message{};
  message.version = kTddProtocolVersion;
  message.type = type;
  message.session_id = session;
  message.cycle_id = cycle;
  message.guard_ms = 0U;
  message.window_ms = 0U;
  message.max_bytes = kVehicleLateUplinkRecoveryBytes;
  message.actual_bytes = actual_bytes;
  return message;
}

struct ControllerFixture {
  TddConfig config{};
  LinkDiagnostics diagnostics{};
  VehicleTddController controller{config, diagnostics};
  std::uint64_t grant_complete_ms{0U};
  std::uint64_t receive_started_ms{0U};
  std::uint64_t timeout_ms{0U};

  ControllerFixture() {
    controller.reset(kSession, kCycle, 0U);
    (void)controller.tick(input_at(0U));
    (void)controller.tick(input_at(config.aux_stable_ms));
    (void)controller.tick(input_at(config.downlink_send_ms));
    (void)controller.tick(input_at(config.downlink_send_ms + 1U));
    const LinkAction grant =
        controller.tick(input_at(config.downlink_send_ms + 2U));
    grant_complete_ms = config.downlink_send_ms + 2U;
    if (grant.type == LinkActionType::SendGrant) {
      controller.complete_action(grant.token, TxResult::Accepted,
                                 grant_complete_ms);
    }
    (void)controller.tick(input_at(grant_complete_ms + 1U));
    // The fixture completes GrantDrain one millisecond after UART acceptance;
    // the fixed guard begins at that physical-drain boundary.
    receive_started_ms =
        grant_complete_ms + 1U + config.uplink_guard_ms;
    timeout_ms = receive_started_ms + config.vehicle_receive_timeout_ms;
  }

  void enter_receive() {
    (void)controller.tick(input_at(receive_started_ms));
  }

  void enter_timeout_return_guard() {
    enter_receive();
    (void)controller.tick(input_at(timeout_ms));
  }
};

LateUplinkIngestStatus ingest_frame(VehicleLateUplinkRecovery& recovery,
                                    const MavlinkFrame& frame,
                                    std::size_t begin = 0U,
                                    std::size_t end = 0U) {
  const std::size_t bounded_end =
      end == 0U ? frame.size : std::min(end, frame.size);
  LateUplinkIngestStatus status = LateUplinkIngestStatus::NeedMore;
  for (std::size_t index = begin; index < bounded_end; ++index) {
    status = recovery.ingest(frame.bytes[index]);
  }
  return status;
}

bool take_exact(VehicleLateUplinkRecovery& recovery,
                const std::uint8_t* expected, std::size_t expected_size,
                std::uint16_t expected_frames, TestReport& report) {
  std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes> output{};
  std::size_t output_size = 99U;
  std::uint16_t output_frames = 99U;
  const bool taken = recovery.take_commit(output.data(), output.size(),
                                          output_size, output_frames);
  report.check(taken, "ready late-uplink commit could not be taken");
  report.check(output_size == expected_size,
               "late-uplink commit size differs from DONE actual_bytes");
  report.check(output_frames == expected_frames,
               "late-uplink commit frame count is incorrect");
  report.check(output_size == expected_size &&
                   std::equal(output.begin(), output.begin() + output_size,
                              expected),
               "late-uplink commit changed application bytes");
  return taken;
}

void check_no_commit(VehicleLateUplinkRecovery& recovery,
                     TestReport& report, const std::string& reason) {
  std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes> output{};
  std::size_t output_size = 99U;
  std::uint16_t output_frames = 99U;
  report.check(!recovery.take_commit(output.data(), output.size(),
                                     output_size, output_frames),
               reason);
  report.check(output_size == 0U && output_frames == 0U,
               "failed take_commit exposed stale size/frame metadata");
}

void check_commit_exactly_once(TestReport& report) {
  VehicleLateUplinkRecovery recovery{};
  const MavlinkFrame request =
      fixtures::param_request_read_v2(0x51U, "ARMING_CHECK");
  report.check(request.size == 32U,
               "late-uplink regression request is no longer 32 bytes");
  recovery.begin(kSession, kCycle);
  report.check(ingest_frame(recovery, request) ==
                   LateUplinkIngestStatus::FrameReady,
               "complete valid msg20 was not quarantined as one frame");
  report.check(recovery.active() && !recovery.ready() &&
                   recovery.received_bytes() == request.size &&
                   recovery.buffered_bytes() == request.size &&
                   recovery.frame_count() == 1U,
               "valid msg20 quarantine accounting is incorrect");
  check_no_commit(recovery, report,
                  "msg20 became visible before matching UL_DONE");

  report.check(recovery.on_terminal(
                   terminal(ControlType::UlDone,
                            static_cast<std::uint16_t>(request.size))) ==
                   LateUplinkTerminalStatus::Ready,
               "matching UL_DONE did not make quarantined msg20 ready");
  report.check(!recovery.active() && recovery.ready(),
               "matching UL_DONE did not close application admission");
  report.check(recovery.ingest(0xFDU) == LateUplinkIngestStatus::Inactive,
               "application admission remained open after UL_DONE");

  std::array<std::uint8_t, 31U> too_small{};
  std::size_t too_small_size = 99U;
  std::uint16_t too_small_frames = 99U;
  report.check(!recovery.take_commit(too_small.data(), too_small.size(),
                                     too_small_size, too_small_frames),
               "undersized D6 capacity accepted an atomic commit");
  report.check(too_small_size == 0U && too_small_frames == 0U &&
                   recovery.ready(),
               "capacity failure lost or partially exposed the ready commit");
  (void)take_exact(recovery, request.bytes.data(), request.size, 1U, report);
  report.check(recovery.on_terminal(
                   terminal(ControlType::UlDone,
                            static_cast<std::uint16_t>(request.size))) ==
                   LateUplinkTerminalStatus::Ignored,
               "duplicate UL_DONE reactivated a completed transaction");
  check_no_commit(recovery, report,
                  "matching UL_DONE committed the same msg20 twice");
}

void check_idle_and_partial_discard(TestReport& report) {
  VehicleLateUplinkRecovery idle{};
  idle.begin(kSession, kCycle);
  report.check(idle.on_terminal(terminal(ControlType::UlIdle, 0U)) ==
                   LateUplinkTerminalStatus::Idle,
               "same-cycle UL_IDLE did not close an empty quarantine");
  check_no_commit(idle, report, "UL_IDLE produced a D6 commit");

  VehicleLateUplinkRecovery partial{};
  const MavlinkFrame request =
      fixtures::param_request_read_v2(0x52U, "SERIAL1_BAUD");
  partial.begin(kSession, kCycle);
  constexpr std::size_t kPartialBytes = 13U;
  (void)ingest_frame(partial, request, 0U, kPartialBytes);
  report.check(partial.on_terminal(
                   terminal(ControlType::UlDone, kPartialBytes)) ==
                   LateUplinkTerminalStatus::Discarded,
               "UL_DONE accepted a partial MAVLink frame");
  check_no_commit(partial, report,
                  "partial MAVLink prefix reached D6 after UL_DONE");
}

void check_identity_and_actual(TestReport& report) {
  const MavlinkFrame request =
      fixtures::param_request_read_v2(0x53U, "ARMING_CHECK");
  VehicleLateUplinkRecovery recovery{};
  recovery.begin(kSession, kCycle);
  (void)ingest_frame(recovery, request);

  report.check(recovery.on_terminal(terminal(
                   ControlType::UlDone,
                   static_cast<std::uint16_t>(request.size),
                   static_cast<std::uint16_t>(kSession - 1U), kCycle)) ==
                   LateUplinkTerminalStatus::Ignored,
               "wrong-session terminal was not ignored");
  report.check(recovery.on_terminal(terminal(
                   ControlType::UlDone,
                   static_cast<std::uint16_t>(request.size), kSession,
                   static_cast<std::uint16_t>(kCycle - 1U))) ==
                   LateUplinkTerminalStatus::Ignored,
               "wrong-cycle terminal was not ignored");
  check_no_commit(recovery, report,
                  "wrong session/cycle exposed quarantined data");
  report.check(recovery.active() &&
                   recovery.buffered_bytes() == request.size,
               "stale terminal destroyed the current transaction");

  report.check(recovery.on_terminal(terminal(
                   ControlType::UlDone,
                   static_cast<std::uint16_t>(request.size - 1U))) ==
                   LateUplinkTerminalStatus::Discarded,
               "same-cycle wrong actual_bytes was not discarded");
  check_no_commit(recovery, report,
                  "wrong actual_bytes exposed quarantined data");
}

void check_terminal_contract(TestReport& report) {
  const MavlinkFrame request =
      fixtures::param_request_read_v2(0x5DU, "ARMING_CHECK");
  const auto fresh = [&request]() {
    VehicleLateUplinkRecovery recovery{};
    recovery.begin(kSession, kCycle);
    (void)ingest_frame(recovery, request);
    return recovery;
  };

  {
    VehicleLateUplinkRecovery recovery = fresh();
    TddControlMessage message = terminal(
        ControlType::UlDone, static_cast<std::uint16_t>(request.size));
    message.version = static_cast<std::uint8_t>(kTddProtocolVersion + 1U);
    report.check(recovery.on_terminal(message) !=
                     LateUplinkTerminalStatus::Ready,
                 "wrong-version terminal released quarantined data");
    check_no_commit(recovery, report,
                    "wrong-version terminal produced a D6 commit");
  }
  {
    VehicleLateUplinkRecovery recovery = fresh();
    TddControlMessage message = terminal(
        ControlType::UlDone, static_cast<std::uint16_t>(request.size));
    message.type = ControlType::LinkStatus;
    report.check(recovery.on_terminal(message) !=
                     LateUplinkTerminalStatus::Ready,
                 "non-terminal control released quarantined data");
    check_no_commit(recovery, report,
                    "non-terminal control produced a D6 commit");
  }

  const auto check_discarded = [&fresh, &report](TddControlMessage message,
                                                 const char* reason) {
    VehicleLateUplinkRecovery recovery = fresh();
    report.check(recovery.on_terminal(message) ==
                     LateUplinkTerminalStatus::Discarded,
                 reason);
    check_no_commit(recovery, report,
                    "invalid same-cycle terminal produced a D6 commit");
  };

  TddControlMessage wrong_max = terminal(
      ControlType::UlDone, static_cast<std::uint16_t>(request.size));
  wrong_max.max_bytes = 63U;
  check_discarded(wrong_max, "wrong max_bytes was not discarded");

  TddControlMessage wrong_guard = terminal(
      ControlType::UlDone, static_cast<std::uint16_t>(request.size));
  wrong_guard.guard_ms = 1U;
  check_discarded(wrong_guard, "nonzero terminal guard was not discarded");

  TddControlMessage wrong_window = terminal(
      ControlType::UlDone, static_cast<std::uint16_t>(request.size));
  wrong_window.window_ms = 1U;
  check_discarded(wrong_window,
                  "nonzero terminal window was not discarded");

  check_discarded(
      terminal(ControlType::UlDone,
               static_cast<std::uint16_t>(request.size - 1U)),
      "actual_bytes -1 was not discarded");
  check_discarded(
      terminal(ControlType::UlDone,
               static_cast<std::uint16_t>(request.size + 1U)),
      "actual_bytes +1 was not discarded");
  check_discarded(terminal(ControlType::UlIdle, 0U),
                  "UL_IDLE with application data was not discarded");
}

void check_escaped_wire_and_split_control(TestReport& report) {
  const MavlinkFrame frame = fixtures::adversarial_vctd_param_set();
  report.check(frame.size > 0U,
               "escaped-wire fixture is not a valid MAVLink frame");
  VehicleLateUplinkRecovery recovery{};
  recovery.begin(kSession, kCycle);
  TddLinkDemux demux{true};
  std::size_t application_offset = 0U;
  std::size_t wire_bytes = 0U;
  std::size_t local_bytes = 0U;
  std::size_t control_events = 0U;
  LateUplinkIngestStatus final_status = LateUplinkIngestStatus::NeedMore;
  while (application_offset < frame.size) {
    const EncodedLinkDataChunk encoded = encode_link_data(
        frame.bytes.data() + application_offset,
        frame.size - application_offset);
    report.check(encoded.input_consumed > 0U,
                 "escaped-wire encoder made no progress");
    if (encoded.input_consumed == 0U) {
      break;
    }
    for (std::size_t index = 0U; index < encoded.wire_size; ++index) {
      const TddDemuxEvent event = demux.push(encoded.wire_bytes[index]);
      ++wire_bytes;
      if (event.has_control) {
        ++control_events;
      }
      for (std::size_t local = 0U; local < event.local_size; ++local) {
        final_status = recovery.ingest(event.local_bytes[local]);
        ++local_bytes;
      }
    }
    application_offset += encoded.input_consumed;
  }
  report.check(wire_bytes > frame.size && local_bytes == frame.size,
               "link escaping did not separate wire/application byte counts");
  report.check(control_events == 0U &&
                   final_status == LateUplinkIngestStatus::FrameReady,
               "escaped application VCTD was mistaken for control");

  const TddControlMessage done = terminal(
      ControlType::UlDone, static_cast<std::uint16_t>(frame.size));
  std::array<std::uint8_t, kTddControlFrameSize> control_wire{};
  std::size_t control_size = 0U;
  report.check(encode_control(done, control_wire.data(), control_wire.size(),
                              control_size),
               "split UL_DONE encoding failed");
  const TddDemuxEvent first = demux.push(control_wire[0]);
  report.check(!first.has_control && first.local_size == 0U &&
                   demux.buffered_size() == 1U,
               "first raw V did not retain a split control candidate");
  DecodeEvent decoded{};
  bool have_control = false;
  for (std::size_t index = 1U; index < control_size; ++index) {
    const TddDemuxEvent event = demux.push(control_wire[index]);
    if (event.has_control) {
      decoded = event.control;
      have_control = true;
    }
  }
  report.check(have_control && decoded.status == DecodeStatus::Message,
               "loop-split UL_DONE did not remain quarantined in demux");
  report.check(
      have_control && recovery.on_terminal(decoded.message) ==
                          LateUplinkTerminalStatus::Ready,
      "application actual_bytes did not validate escaped-wire transaction");
  (void)take_exact(recovery, frame.bytes.data(), frame.size, 1U, report);
}

void check_bad_crc_and_missing_done(TestReport& report) {
  const MavlinkFrame request =
      fixtures::param_request_read_v2(0x54U, "SERIAL1_BAUD");

  VehicleLateUplinkRecovery bad_frame{};
  bad_frame.begin(kSession, kCycle);
  MavlinkFrame corrupted = request;
  corrupted.bytes[corrupted.size - 1U] ^= 0x80U;
  report.check(ingest_frame(bad_frame, corrupted) ==
                   LateUplinkIngestStatus::Invalid,
               "CRC-bad MAVLink frame was not rejected");
  report.check(!bad_frame.active() && !bad_frame.ready() &&
                   bad_frame.buffered_bytes() == 0U,
               "CRC-bad frame did not discard the current transaction");
  check_no_commit(bad_frame, report,
                  "CRC-bad MAVLink frame reached D6");
  report.check(bad_frame.on_terminal(terminal(
                   ControlType::UlDone,
                   static_cast<std::uint16_t>(corrupted.size))) ==
                   LateUplinkTerminalStatus::Ignored,
               "CRC-bad transaction was reactivated by a later terminal");
  check_no_commit(bad_frame, report,
                  "CRC-bad transaction became ready at terminal");

  VehicleLateUplinkRecovery bad_terminal{};
  bad_terminal.begin(kSession, kCycle);
  (void)ingest_frame(bad_terminal, request);
  TddControlMessage done = terminal(
      ControlType::UlDone, static_cast<std::uint16_t>(request.size));
  std::array<std::uint8_t, kTddControlFrameSize> wire{};
  std::size_t wire_size = 0U;
  report.check(encode_control(done, wire.data(), wire.size(), wire_size),
               "UL_DONE encoding failed");
  wire[wire_size - 1U] ^= 0x01U;
  TddLinkDemux demux{true};
  DecodeStatus decoded_status = DecodeStatus::NeedMore;
  for (const std::uint8_t byte : wire) {
    const TddDemuxEvent event = demux.push(byte);
    if (event.has_control) {
      decoded_status = event.control.status;
    }
  }
  report.check(decoded_status == DecodeStatus::BadCrc,
               "corrupted UL_DONE did not reproduce control CRC failure");
  if (decoded_status == DecodeStatus::BadCrc) {
    bad_terminal.discard();
  }
  check_no_commit(bad_terminal, report,
                  "CRC-bad UL_DONE released quarantined msg20");

  VehicleLateUplinkRecovery missing{};
  missing.begin(kSession, kCycle);
  (void)ingest_frame(missing, request);
  check_no_commit(missing, report,
                  "missing UL_DONE released quarantined msg20");
  missing.discard();  // Transaction/cycle expiry.
  check_no_commit(missing, report,
                  "expired transaction retained a hidden commit");

  VehicleLateUplinkRecovery noise{};
  noise.begin(kSession, kCycle);
  report.check(noise.ingest(0x01U) == LateUplinkIngestStatus::Invalid &&
                   !noise.active(),
               "non-MAVLink noise did not discard the transaction");
  check_no_commit(noise, report,
                  "non-MAVLink noise created a hidden commit");

  VehicleLateUplinkRecovery complete_plus_partial{};
  const MavlinkFrame second =
      fixtures::param_request_read_v2(0x5EU, "ARMING_CHECK");
  complete_plus_partial.begin(kSession, kCycle);
  (void)ingest_frame(complete_plus_partial, request);
  constexpr std::size_t kSecondPrefix = 9U;
  (void)ingest_frame(complete_plus_partial, second, 0U, kSecondPrefix);
  report.check(complete_plus_partial.on_terminal(terminal(
                   ControlType::UlDone,
                   static_cast<std::uint16_t>(request.size +
                                              kSecondPrefix))) ==
                   LateUplinkTerminalStatus::Discarded,
               "complete frame plus partial second frame was accepted");
  check_no_commit(complete_plus_partial, report,
                  "partial second MAVLink frame leaked a valid prefix");
}

void check_overflow(TestReport& report) {
  const MavlinkFrame first =
      fixtures::param_request_read_v2(0x55U, "ARMING_CHECK");
  const MavlinkFrame second =
      fixtures::param_request_read_v2(0x56U, "SERIAL1_BAUD");
  VehicleLateUplinkRecovery recovery{};
  recovery.begin(kSession, kCycle);
  report.check(ingest_frame(recovery, first) ==
                   LateUplinkIngestStatus::FrameReady &&
                   ingest_frame(recovery, second) ==
                       LateUplinkIngestStatus::FrameReady,
               "64-byte quarantine fixture did not fill exactly");
  report.check(recovery.buffered_bytes() ==
                       kVehicleLateUplinkRecoveryBytes &&
                   recovery.frame_count() == 2U,
               "exact-capacity quarantine accounting is incorrect");
  report.check(recovery.ingest(0xFDU) == LateUplinkIngestStatus::Overflow,
               "65th application byte did not fail closed");
  report.check(!recovery.active() && !recovery.ready() &&
                   recovery.buffered_bytes() == 0U,
               "overflow did not discard the current transaction");
  check_no_commit(recovery, report,
                  "overflow retained a partial D6 commit");
  report.check(recovery.on_terminal(
                   terminal(ControlType::UlDone, 64U)) ==
                   LateUplinkTerminalStatus::Ignored,
               "overflow transaction was reactivated by a later terminal");
  check_no_commit(recovery, report,
                  "overflow transaction became ready at terminal");
}

void check_cycle_parser_isolation(TestReport& report) {
  const MavlinkFrame old_request =
      fixtures::param_request_read_v2(0x57U, "SERIAL1_BAUD");
  const MavlinkFrame fresh_request =
      fixtures::param_request_read_v2(0x58U, "ARMING_CHECK");
  VehicleLateUplinkRecovery recovery{};
  recovery.begin(kSession, kCycle);
  constexpr std::size_t kPrefix = 11U;
  (void)ingest_frame(recovery, old_request, 0U, kPrefix);
  report.check(recovery.received_bytes() == kPrefix,
               "old-cycle prefix was not retained by its transaction");

  recovery.begin(kSession, static_cast<std::uint16_t>(kCycle + 1U));
  report.check(recovery.received_bytes() == 0U &&
                   recovery.buffered_bytes() == 0U &&
                   recovery.frame_count() == 0U,
               "new cycle retained parser/quarantine residue");
  report.check(ingest_frame(recovery, fresh_request) ==
                   LateUplinkIngestStatus::FrameReady,
               "fresh frame did not parse after cycle boundary reset");
  report.check(recovery.on_terminal(terminal(
                   ControlType::UlDone,
                   static_cast<std::uint16_t>(fresh_request.size), kSession,
                   static_cast<std::uint16_t>(kCycle + 1U))) ==
                   LateUplinkTerminalStatus::Ready,
               "fresh-cycle DONE did not release its complete frame");
  (void)take_exact(recovery, fresh_request.bytes.data(), fresh_request.size,
                   1U, report);

  // Session rollover and uint16 cycle wrap must also start from a clean
  // parser. Old terminals are ignored without releasing the new data.
  recovery.begin(kSession, 0xFFFFU);
  (void)ingest_frame(recovery, old_request, 0U, kPrefix);
  const std::uint16_t new_session =
      static_cast<std::uint16_t>(kSession + 1U);
  recovery.begin(new_session, 0U);
  (void)ingest_frame(recovery, fresh_request);
  report.check(recovery.on_terminal(terminal(
                   ControlType::UlDone,
                   static_cast<std::uint16_t>(old_request.size), kSession,
                   0xFFFFU)) == LateUplinkTerminalStatus::Ignored,
               "pre-rollover terminal affected the new transaction");
  check_no_commit(recovery, report,
                  "old wrapped-cycle traffic released new-session data");
  report.check(recovery.on_terminal(terminal(
                   ControlType::UlDone,
                   static_cast<std::uint16_t>(fresh_request.size),
                   new_session, 0U)) == LateUplinkTerminalStatus::Ready,
               "session rollover/cycle wrap rejected fresh terminal");
  (void)take_exact(recovery, fresh_request.bytes.data(), fresh_request.size,
                   1U, report);
}

void check_64_byte_multiwrite(TestReport& report) {
  const MavlinkFrame first =
      fixtures::param_request_read_v2(0x59U, "ARMING_CHECK");
  const MavlinkFrame second =
      fixtures::param_request_read_v2(0x5AU, "SERIAL1_BAUD");
  std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes> expected{};
  std::copy_n(first.bytes.begin(), first.size, expected.begin());
  std::copy_n(second.bytes.begin(), second.size,
              expected.begin() + first.size);

  VehicleLateUplinkRecovery recovery{};
  recovery.begin(kSession, kCycle);
  (void)ingest_frame(recovery, first);
  (void)ingest_frame(recovery, second);
  report.check(recovery.on_terminal(
                   terminal(ControlType::UlDone, 64U)) ==
                   LateUplinkTerminalStatus::Ready,
               "exact 64-byte/two-frame transaction was not ready");

  std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes> committed{};
  std::size_t committed_size = 0U;
  std::uint16_t committed_frames = 0U;
  report.check(recovery.take_commit(committed.data(), committed.size(),
                                    committed_size, committed_frames),
               "64-byte commit could not be taken");
  report.check(committed_size == 64U && committed_frames == 2U &&
                   committed == expected,
               "64-byte commit content/accounting is incorrect");

  MavlinkValidatedLocalEgressAdapter<> endpoint{};
  for (std::size_t index = 0U; index < committed_size; ++index) {
    (void)endpoint.ingest_byte(committed[index]);
  }
  report.check(endpoint.egress().queued_bytes() == 64U,
               "D6 adapter did not atomically receive both frames");
  std::array<std::uint8_t, 32U> write{};
  const std::size_t first_size =
      endpoint.egress().peek(write.data(), write.size());
  report.check(first_size == 32U &&
                   std::equal(write.begin(), write.end(), expected.begin()),
               "first D6 physical write is not exact first frame");
  report.check(endpoint.egress().complete_write(first_size) ==
                   UartWriteProgress::Complete,
               "first D6 physical write did not commit");
  const std::size_t second_size =
      endpoint.egress().peek(write.data(), write.size());
  report.check(second_size == 32U &&
                   std::equal(write.begin(), write.end(),
                              expected.begin() + 32U),
               "second D6 physical write is not exact second frame");
  report.check(endpoint.egress().complete_write(second_size) ==
                       UartWriteProgress::Complete &&
                   endpoint.egress().empty(),
               "second D6 physical write did not drain exactly once");
}

void check_return_guard_reanchor(TestReport& report) {
  ControllerFixture fixture{};
  report.check(fixture.controller.state() == VehicleTddState::UplinkGuard &&
                   fixture.controller.radio_receive_window() &&
                   !fixture.controller.late_uplink_recovery_window(),
               "ordinary UplinkGuard timing/admission changed");
  fixture.enter_timeout_return_guard();
  report.check(fixture.controller.state() == VehicleTddState::ReturnGuard &&
                   !fixture.controller.radio_receive_window() &&
                   fixture.controller.late_uplink_recovery_window(),
               "timeout ReturnGuard did not open bounded late recovery");
  report.check(fixture.diagnostics.uplink_timeouts == 0U,
               "provisional receive timeout was counted before recovery ended");

  const std::uint64_t data_ms = fixture.timeout_ms + 150U;
  report.check(fixture.controller.note_return_guard_activity(data_ms),
               "late application activity was not admitted in ReturnGuard");
  const std::uint64_t legacy_guard_deadline =
      fixture.timeout_ms + fixture.config.return_guard_ms;
  const LinkAction old_deadline_action =
      fixture.controller.tick(input_at(legacy_guard_deadline));
  report.check(fixture.controller.state() == VehicleTddState::ReturnGuard &&
                   old_deadline_action.type == LinkActionType::None,
               "late data failed to block the next downlink at old deadline");

  const std::uint64_t done_ms = fixture.timeout_ms + 680U;
  report.check(fixture.controller.late_uplink_recovery_window(),
               "late window closed before HIL-timed UL_DONE arrival");
  report.check(
      fixture.controller.complete_late_uplink_terminal(
          done_ms, ControlType::UlDone, true),
      "valid late UL_DONE did not close/reanchor recovery");
  report.check(!fixture.controller.late_uplink_recovery_window() &&
                   !fixture.controller.radio_receive_window(),
               "application admission remained open after late UL_DONE");
  const std::uint64_t post_terminal_activity_ms = done_ms + 400U;
  report.check(
      fixture.controller.note_return_guard_activity(post_terminal_activity_ms),
      "post-terminal raw activity did not extend physical quiet guard");
  report.check(!fixture.controller.late_uplink_recovery_window(),
               "post-terminal raw activity reopened application admission");
  const LinkAction quiet_action = fixture.controller.tick(input_at(
      post_terminal_activity_ms + fixture.config.return_guard_ms - 1U));
  report.check(fixture.controller.state() == VehicleTddState::ReturnGuard &&
                   quiet_action.type == LinkActionType::None,
               "terminal quiet period ended one millisecond early");
  (void)fixture.controller.tick(input_at(
      post_terminal_activity_ms + fixture.config.return_guard_ms));
  report.check(fixture.controller.state() == VehicleTddState::DownlinkSend,
               "next downlink did not resume after terminal quiet period");
  report.check(fixture.diagnostics.uplink_timeouts == 0U,
               "valid late recovery was incorrectly counted as no-response");

  ControllerFixture edge{};
  edge.enter_timeout_return_guard();
  const std::uint64_t edge_data_ms = edge.timeout_ms +
                                     edge.config.return_guard_ms - 1U;
  report.check(edge.controller.note_return_guard_activity(edge_data_ms),
               "ReturnGuard +649 ms byte was not admitted before tick");
  const LinkAction edge_action = edge.controller.tick(
      input_at(edge.timeout_ms + edge.config.return_guard_ms));
  report.check(edge.controller.state() == VehicleTddState::ReturnGuard &&
                   edge.controller.cycle_id() == kCycle &&
                   edge_action.type == LinkActionType::None,
               "deliver-before-tick +649 ms byte failed to block cycle advance");

  ControllerFixture missing{};
  missing.enter_timeout_return_guard();
  const std::uint64_t missing_data_ms = missing.timeout_ms + 150U;
  report.check(missing.controller.note_return_guard_activity(missing_data_ms),
               "missing-DONE fixture did not admit late data");
  const std::uint64_t expiry_ms =
      missing.timeout_ms + missing.config.late_terminal_wait_ms;
  (void)missing.controller.tick(input_at(expiry_ms));
  report.check(missing.controller.state() == VehicleTddState::DownlinkSend &&
                   missing.controller.cycle_id() ==
                       static_cast<std::uint16_t>(kCycle + 1U) &&
                   missing.diagnostics.uplink_timeouts == 1U,
               "missing DONE did not expire once into the next cycle");
  (void)missing.controller.tick(input_at(expiry_ms + 1U));
  report.check(missing.controller.cycle_id() ==
                       static_cast<std::uint16_t>(kCycle + 1U) &&
                   missing.diagnostics.uplink_timeouts == 1U,
               "missing DONE advanced/counted the same timeout twice");
  report.diagnostics = fixture.diagnostics;
}

void check_normal_guard_atomic(TestReport& report) {
  ControllerFixture fixture{};
  VehicleLateUplinkRecovery recovery{};
  MavlinkValidatedLocalEgressAdapter<> d6{};
  const MavlinkFrame request =
      fixtures::param_request_read_v2(0x5BU, "ARMING_CHECK");
  recovery.begin(kSession, kCycle);
  (void)ingest_frame(recovery, request);
  report.check(d6.egress().empty(),
               "normal Guard data reached D6 before UL_DONE");
  const TddControlMessage done = terminal(
      ControlType::UlDone, static_cast<std::uint16_t>(request.size));
  report.check(recovery.on_terminal(done) ==
                   LateUplinkTerminalStatus::Ready,
               "normal Guard transaction did not validate UL_DONE");
  report.check(fixture.controller.on_control(done,
                                             fixture.grant_complete_ms + 2U) ==
                   ControlDisposition::Accepted,
               "normal Guard controller path stopped accepting UL_DONE");
  std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes> output{};
  std::size_t output_size = 0U;
  std::uint16_t output_frames = 0U;
  report.check(recovery.take_commit(output.data(), output.size(), output_size,
                                    output_frames),
               "normal Guard commit was unavailable after UL_DONE");
  for (std::size_t index = 0U; index < output_size; ++index) {
    (void)d6.ingest_byte(output[index]);
  }
  report.check(d6.egress().queued_bytes() == request.size &&
                   output_frames == 1U,
               "normal Guard exact frame was not committed after UL_DONE");
  report.check(fixture.controller.state() == VehicleTddState::ReturnGuard &&
                   !fixture.controller.late_uplink_recovery_window(),
               "ordinary accepted DONE incorrectly opened late recovery");
}

void check_hil_straddle(TestReport& report) {
  ControllerFixture fixture{};
  VehicleLateUplinkRecovery recovery{};
  MavlinkValidatedLocalEgressAdapter<> d6{};
  TddLinkDemux demux{true};
  const MavlinkFrame request =
      fixtures::param_request_read_v2(0x56U, "ARMING_CHECK");
  report.check(request.message_id == 20U && request.size == 32U,
               "HIL fixture is not exact 32-byte PARAM_REQUEST_READ");

  std::array<std::uint8_t, 2U * kVehicleLateUplinkRecoveryBytes> wire{};
  std::size_t wire_size = 0U;
  std::size_t application_offset = 0U;
  while (application_offset < request.size) {
    const EncodedLinkDataChunk encoded = encode_link_data(
        request.bytes.data() + application_offset,
        request.size - application_offset);
    report.check(encoded.input_consumed > 0U &&
                     wire_size + encoded.wire_size <= wire.size(),
                 "HIL link-data encoding failed");
    if (encoded.input_consumed == 0U ||
        wire_size + encoded.wire_size > wire.size()) {
      break;
    }
    std::copy_n(encoded.wire_bytes.begin(), encoded.wire_size,
                wire.begin() + wire_size);
    wire_size += encoded.wire_size;
    application_offset += encoded.input_consumed;
  }
  report.check(wire_size > request.size,
               "HIL msg20 did not exercise escaped wire accounting");

  recovery.begin(kSession, kCycle);
  fixture.enter_receive();
  std::size_t wire_index = 0U;
  const auto deliver_one = [&](std::uint64_t now_ms) {
    (void)fixture.controller.note_return_guard_activity(now_ms);
    const TddDemuxEvent event = demux.push(wire[wire_index++]);
    for (std::size_t index = 0U; index < event.local_size; ++index) {
      (void)recovery.ingest(event.local_bytes[index]);
    }
    report.check(!event.has_control,
                 "escaped msg20 byte was misclassified as control");
  };
  while (wire_index < wire_size && recovery.received_bytes() < 31U) {
    deliver_one(fixture.timeout_ms - 1U);
  }
  report.check(d6.egress().empty() && recovery.received_bytes() == 31U,
               "pre-timeout prefix escaped transaction quarantine");

  (void)fixture.controller.tick(input_at(fixture.timeout_ms));
  report.check(fixture.controller.late_uplink_recovery_window(),
               "Receive-to-ReturnGuard timeout did not permit recovery");
  const std::uint64_t data_ms = fixture.timeout_ms + 150U;
  while (wire_index < wire_size) {
    deliver_one(data_ms);
  }
  report.check(recovery.received_bytes() == request.size &&
                   recovery.frame_count() == 1U,
               "frame spanning Receive/ReturnGuard did not validate");
  report.check(d6.egress().empty(),
               "straddled msg20 reached D6 before matching UL_DONE");

  const std::uint64_t done_ms = fixture.timeout_ms + 680U;
  const TddControlMessage done = terminal(
      ControlType::UlDone, static_cast<std::uint16_t>(request.size));
  std::array<std::uint8_t, kTddControlFrameSize> done_wire{};
  std::size_t done_wire_size = 0U;
  report.check(encode_control(done, done_wire.data(), done_wire.size(),
                              done_wire_size),
               "HIL UL_DONE encoding failed");
  LateUplinkTerminalStatus terminal_status =
      LateUplinkTerminalStatus::Ignored;
  for (std::size_t index = 0U; index < done_wire_size; ++index) {
    report.check(fixture.controller.note_return_guard_activity(done_ms),
                 "UL_DONE wire activity did not reanchor late recovery");
    const TddDemuxEvent event = demux.push(done_wire[index]);
    report.check(event.local_size == 0U,
                 "UL_DONE control byte leaked into application quarantine");
    if (event.has_control && event.control.status == DecodeStatus::Message) {
      terminal_status = recovery.on_terminal(event.control.message);
    }
  }
  report.check(terminal_status == LateUplinkTerminalStatus::Ready,
               "HIL-timed matching UL_DONE did not validate msg20");
  std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes> output{};
  std::size_t output_size = 0U;
  std::uint16_t output_frames = 0U;
  const bool capacity_ready =
      d6.egress().free_bytes() >= recovery.buffered_bytes();
  report.check(capacity_ready &&
                   recovery.take_commit(output.data(), output.size(),
                                        output_size, output_frames),
               "HIL-timed transaction did not expose atomic commit");
  report.check(d6.egress().ingest(output.data(), output_size) == output_size,
               "atomic HIL commit did not enter the D6 queue");
  report.check(fixture.controller.complete_late_uplink_terminal(
                   done_ms, ControlType::UlDone, true),
               "controller rejected HIL-timed matching UL_DONE");
  std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> exact{};
  const std::size_t exact_size =
      d6.egress().peek(exact.data(), exact.size());
  report.check(exact_size == request.size && output_frames == 1U &&
                   std::equal(exact.begin(), exact.begin() + exact_size,
                              request.bytes.begin()),
               "HIL-timed msg20 was not committed byte-exact once");
  const LinkAction quiet_action = fixture.controller.tick(
      input_at(done_ms + fixture.config.return_guard_ms - 1U));
  report.check(quiet_action.type == LinkActionType::None &&
                   fixture.controller.state() == VehicleTddState::ReturnGuard &&
                   fixture.controller.cycle_id() == kCycle,
               "late DONE quiet guard allowed early RF/cycle advance");
  (void)fixture.controller.tick(
      input_at(done_ms + fixture.config.return_guard_ms));
  report.check(fixture.controller.state() == VehicleTddState::DownlinkSend &&
                   fixture.controller.cycle_id() ==
                       static_cast<std::uint16_t>(kCycle + 1U),
               "late DONE did not resume exactly one next cycle");
  report.check(fixture.diagnostics.uplink_timeouts == 0U,
               "successful straddle recovery was counted as no-response");
  report.diagnostics = fixture.diagnostics;
}

}  // namespace

TestReport run_late_uplink_recovery_test(const std::string& test_id,
                                         std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-UPLINK-LATE-COMMIT-001") {
    check_commit_exactly_once(report);
    report.detail = "32-byte msg20 quarantined until matching DONE; one commit";
  } else if (test_id == "UT-UPLINK-LATE-IDLE-001") {
    check_idle_and_partial_discard(report);
    report.detail = "UL_IDLE and partial-DONE transactions produce no commit";
  } else if (test_id == "UT-UPLINK-LATE-IDENTITY-001") {
    check_identity_and_actual(report);
    report.detail = "stale terminal ignored; mismatched actual_bytes discarded";
  } else if (test_id == "UT-UPLINK-LATE-TERMINAL-001") {
    check_terminal_contract(report);
    report.detail = "terminal version/type/timing/max/actual fields fail closed";
  } else if (test_id == "UT-UPLINK-LATE-INTEGRITY-001") {
    check_bad_crc_and_missing_done(report);
    report.detail = "bad MAVLink/control CRC and missing DONE cannot commit";
  } else if (test_id == "UT-UPLINK-LATE-OVERFLOW-001") {
    check_overflow(report);
    report.detail = "64-byte bound is exact; byte 65 discards atomically";
  } else if (test_id == "UT-UPLINK-LATE-ISOLATION-001") {
    check_cycle_parser_isolation(report);
    report.detail = "new session/cycle begins with clean parser/quarantine";
  } else if (test_id == "UT-UPLINK-LATE-64B-001") {
    check_64_byte_multiwrite(report);
    report.detail = "two exact 32-byte frames commit as two D6 writes";
  } else if (test_id == "UT-UPLINK-LATE-TIMING-001") {
    check_return_guard_reanchor(report);
    report.detail = "late activity and terminal each reanchor 650-ms quiet time";
  } else if (test_id == "UT-UPLINK-LATE-NORMAL-001") {
    check_normal_guard_atomic(report);
    report.detail = "normal Guard timing unchanged; D6 visibility atomic at DONE";
  } else if (test_id == "IT-UPLINK-LATE-ESCAPE-001") {
    check_escaped_wire_and_split_control(report);
    report.detail = "escaped app bytes and loop-split raw DONE stay isolated";
  } else if (test_id == "IT-UPLINK-LATE-HIL-001") {
    check_hil_straddle(report);
    report.detail =
        "msg20 spans Receive/ReturnGuard at +150 ms; DONE at +680 ms";
  } else {
    report.check(false, "unknown late-uplink recovery test case");
  }

  report.cycles = 1U;
  report.final_vehicle_state = "TEST_COMPLETE";
  report.final_ground_state = "NOT_APPLICABLE";
  return report;
}

}  // namespace vc_lora::test
