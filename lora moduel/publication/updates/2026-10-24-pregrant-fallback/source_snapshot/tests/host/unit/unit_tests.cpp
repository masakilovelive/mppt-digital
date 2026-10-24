#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_ground.hpp"
#include "vc_lora/tdd_link_demux.hpp"
#include "vc_lora/tx_gate.hpp"

namespace vc_lora::test {
namespace {

TddControlMessage sample_message(ControlType type) {
  TddControlMessage message{};
  message.type = type;
  message.session_id = 0x1234U;
  message.cycle_id = 0xFFFEU;
  message.guard_ms = 650U;
  message.window_ms = 300U;
  message.max_bytes = 64U;
  message.actual_bytes = type == ControlType::UlGrant ? 0U : 37U;
  return message;
}

bool messages_equal(const TddControlMessage& left,
                    const TddControlMessage& right) {
  return left.version == right.version && left.type == right.type &&
         left.session_id == right.session_id &&
         left.cycle_id == right.cycle_id && left.guard_ms == right.guard_ms &&
         left.window_ms == right.window_ms &&
         left.max_bytes == right.max_bytes &&
         left.actual_bytes == right.actual_bytes;
}

std::array<std::uint8_t, kTddControlFrameSize> encode_sample(
    const TddControlMessage& message, TestReport& report) {
  std::array<std::uint8_t, kTddControlFrameSize> frame{};
  std::size_t encoded_size = 0;
  report.check(encode_control(message, frame.data(), frame.size(),
                              encoded_size),
               "encode_control returned false");
  report.check(encoded_size == frame.size(), "encoded size is not 32 bytes");
  return frame;
}

void rewrite_crc(std::array<std::uint8_t, kTddControlFrameSize>& frame) {
  const std::uint16_t crc = crc16_ccitt_false(frame.data(), 30U);
  frame[30] = static_cast<std::uint8_t>(crc & 0xFFU);
  frame[31] = static_cast<std::uint8_t>((crc >> 8U) & 0xFFU);
}

}  // namespace

TestReport run_unit_test(const std::string& test_id, std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-CODEC-001" || test_id == "UT-CODEC-002") {
    const ControlType type = test_id == "UT-CODEC-001"
                                 ? ControlType::UlGrant
                                 : ControlType::UlDone;
    const TddControlMessage expected = sample_message(type);
    const auto frame = encode_sample(expected, report);
    const DecodeEvent decoded = decode_control(frame.data(), frame.size());
    report.check(decoded.status == DecodeStatus::Message,
                 "encoded frame did not decode");
    report.check(messages_equal(expected, decoded.message),
                 "decoded fields differ from encoded fields");
  } else if (test_id == "UT-CODEC-003") {
    constexpr std::array<std::size_t, 3> corrupt_offsets{{4U, 5U, 12U}};
    constexpr std::array<const char*, 3> failure_messages{{
        "one-bit version corruption was not rejected by CRC",
        "one-bit type corruption was not rejected by CRC",
        "one-bit payload corruption was not rejected by CRC",
    }};
    for (std::size_t index = 0; index < corrupt_offsets.size(); ++index) {
      auto frame = encode_sample(sample_message(ControlType::UlGrant), report);
      frame[corrupt_offsets[index]] ^= 0x01U;
      report.check(decode_control(frame.data(), frame.size()).status ==
                       DecodeStatus::BadCrc,
                   failure_messages[index]);
    }
  } else if (test_id == "UT-CODEC-004") {
    const auto frame =
        encode_sample(sample_message(ControlType::UlGrant), report);
    TddControlStreamDecoder decoder{};
    for (std::size_t index = 0; index < frame.size() / 2U; ++index) {
      report.check(decoder.push(frame[index]).status == DecodeStatus::NeedMore,
                   "truncated frame produced a message");
    }
    report.check(decoder.buffered_size() == frame.size() / 2U,
                 "truncated frame was not retained");
  } else if (test_id == "UT-CODEC-005") {
    const auto grant =
        encode_sample(sample_message(ControlType::UlGrant), report);
    const auto done = encode_sample(sample_message(ControlType::UlDone), report);
    TddControlStreamDecoder decoder{};
    std::uint32_t messages = 0;
    for (const auto byte : grant) {
      if (decoder.push(byte).status == DecodeStatus::Message) {
        ++messages;
      }
    }
    for (const auto byte : done) {
      if (decoder.push(byte).status == DecodeStatus::Message) {
        ++messages;
      }
    }
    report.check(messages == 2U, "two adjacent frames were not separated");
  } else if (test_id == "UT-CODEC-006") {
    LinkDiagnostics diagnostics{};
    auto frame = encode_sample(sample_message(ControlType::UlGrant), report);
    frame[4] = 99U;
    rewrite_crc(frame);
    const DecodeStatus unknown_version =
        decode_control(frame.data(), frame.size()).status;
    report.check(unknown_version == DecodeStatus::UnknownVersion,
                 "unknown version was not rejected");
    diagnostics.note_decode_status(unknown_version);
    frame[4] = kTddProtocolVersion;
    frame[5] = 99U;
    rewrite_crc(frame);
    const DecodeStatus unknown_type =
        decode_control(frame.data(), frame.size()).status;
    report.check(unknown_type == DecodeStatus::UnknownType,
                 "unknown type was not rejected");
    diagnostics.note_decode_status(unknown_type);
    report.check(diagnostics.control_unknown_version == 1U,
                 "unknown version diagnostic was not incremented");
    report.check(diagnostics.control_unknown_type == 1U,
                 "unknown type diagnostic was not incremented");
    report.diagnostics = diagnostics;
  } else if (test_id == "UT-CODEC-007") {
    const std::array<std::uint8_t, 14> noise{
        {0xFDU, 0x09U, 0x00U, 'V', 0xFEU, 'V', 'C', 0x00U,
         0x7FU, 0x10U, 'V', 'C', 'T', 0x01U}};
    const auto frame =
        encode_sample(sample_message(ControlType::UlGrant), report);
    TddControlStreamDecoder decoder{};
    std::uint32_t messages = 0;
    for (const auto byte : noise) {
      if (decoder.push(byte).status == DecodeStatus::Message) {
        ++messages;
      }
    }
    for (const auto byte : frame) {
      if (decoder.push(byte).status == DecodeStatus::Message) {
        ++messages;
      }
    }
    report.check(messages == 1U,
                 "MAVLink-like noise caused a false control message");
  } else if (test_id == "UT-DEMUX-001") {
    const auto grant =
        encode_sample(sample_message(ControlType::UlGrant), report);
    const auto done = encode_sample(sample_message(ControlType::UlDone), report);
    std::array<std::uint8_t, 8> expected_local{{
        0xFDU, 'V', 'X', 0x01U, 0x02U, 0x03U, 0x04U, 0x05U}};
    std::array<std::uint8_t, 8> actual_local{};
    std::size_t actual_local_size = 0;
    std::uint32_t control_count = 0;
    TddLinkDemux demux{};

    const auto push = [&](std::uint8_t byte) {
      const TddDemuxEvent event = demux.push(byte);
      for (std::size_t index = 0; index < event.local_size; ++index) {
        if (actual_local_size < actual_local.size()) {
          actual_local[actual_local_size++] = event.local_bytes[index];
        }
      }
      if (event.has_control) {
        report.check(event.control.status == DecodeStatus::Message,
                     "split/concatenated control frame did not decode");
        ++control_count;
      }
    };

    push(0xFDU);
    push('V');
    push('X');
    push(0x01U);
    push(0x02U);
    for (std::size_t index = 0; index < 7U; ++index) {
      push(grant[index]);
    }
    report.check(demux.buffered_size() == 7U,
                 "split control prefix was not retained across chunks");
    for (std::size_t index = 7U; index < grant.size(); ++index) {
      push(grant[index]);
    }
    push(0x03U);
    push(0x04U);
    push(0x05U);
    for (const auto byte : done) {
      push(byte);
    }

    report.check(control_count == 2U,
                 "split and concatenated controls were not both extracted");
    report.check(actual_local_size == expected_local.size(),
                 "demux changed the local byte count");
    report.check(actual_local == expected_local,
                 "demux changed local byte order or leaked control bytes");
  } else if (test_id.rfind("UT-GATE-", 0) == 0U) {
    LinkDiagnostics diagnostics{};
    if (test_id == "UT-GATE-001") {
      report.check(TxGate::authorize_vehicle(VehicleTddState::DownlinkSend,
                                             TxClass::DownlinkData,
                                             diagnostics),
                   "vehicle downlink was denied");
    } else if (test_id == "UT-GATE-002") {
      report.check(!TxGate::authorize_vehicle(VehicleTddState::UplinkReceive,
                                              TxClass::DownlinkData,
                                              diagnostics),
                   "vehicle TX was allowed during uplink receive");
      report.check(diagnostics.tx_during_rx_window_count == 1U,
                   "RX-window violation was not counted");
    } else if (test_id == "UT-GATE-003") {
      report.check(!TxGate::authorize_ground(GroundTddState::WaitGrant,
                                             TxClass::UplinkData, false, 650U,
                                             950U, diagnostics),
                   "ground TX was allowed without a grant");
      report.check(diagnostics.ground_tx_without_valid_grant == 1U,
                   "ungranted ground TX was not counted");
    } else if (test_id == "UT-GATE-004") {
      report.check(TxGate::authorize_ground(GroundTddState::UplinkSend,
                                            TxClass::UplinkData, true, 949U,
                                            950U, diagnostics),
                   "valid in-window ground TX was denied");
    } else if (test_id == "UT-GATE-005") {
      report.check(!TxGate::authorize_ground(GroundTddState::UplinkSend,
                                             TxClass::UplinkData, true, 950U,
                                             950U, diagnostics),
                   "TX was allowed at the half-open window boundary");
    } else if (test_id == "UT-GATE-006") {
      report.check(!TxGate::authorize_ground(GroundTddState::WaitGrant,
                                             TxClass::UplinkData, false, 700U,
                                             950U, diagnostics),
                   "forbidden request was authorized");
      report.check(diagnostics.tx_gate_violation == 1U,
                   "forbidden request did not increment gate violation");
    } else if (test_id == "UT-GATE-007") {
      report.check(!TxGate::authorize_ground(
                       GroundTddState::UplinkSend, TxClass::UplinkData, true,
                       951U, 950U, diagnostics, false),
                   "an unstarted frame was admitted after the window");
      report.check(TxGate::authorize_ground(
                       GroundTddState::UplinkSend, TxClass::UplinkData, true,
                       951U, 950U, diagnostics, true),
                   "a preflight-approved started frame could not finish "
                   "after the admission window");
    }
    report.diagnostics = diagnostics;
  } else if (test_id == "UT-GROUND-BOUNDED-CONTINUATION-001") {
    const auto start_two_chunk_transaction =
        [&report](GroundTddController& ground) {
          TddControlMessage grant{};
          grant.version = kTddProtocolVersion;
          grant.type = ControlType::UlGrant;
          grant.session_id = 0x6202U;
          grant.cycle_id = 1U;
          grant.guard_ms = 0U;
          grant.window_ms = 300U;
          grant.max_bytes = 64U;
          report.check(ground.on_control(grant, 0U) ==
                           ControlDisposition::Accepted,
                       "bounded-continuation fixture rejected its grant");

          TddInput input{};
          input.aux_high = true;
          input.radio_tx_empty = true;
          input.queued_bytes = 45U;
          input.front_frame_bytes = 45U;
          input.next_tx_application_bytes = 32U;
          input.next_tx_wire_bytes = 64U;
          input.now_ms = 0U;
          (void)ground.tick(input);
          input.now_ms = 15U;
          (void)ground.tick(input);
          input.now_ms = 16U;
          const LinkAction first = ground.tick(input);
          report.check(first.type == LinkActionType::SendRadioData &&
                           first.byte_budget == 32U,
                       "bounded-continuation fixture did not issue prefix 1");
          ground.complete_action(first.token, TxResult::Accepted, 16U, 32U);
          report.check(ground.actual_bytes() == 32U &&
                           ground.transaction_deadline_ms() == 2016U,
                       "first Accepted prefix did not start the absolute "
                       "Vehicle receive deadline");
        };

    // A permanently busy/unavailable writer after prefix 1 must fail closed
    // at a fixed deadline. It must not emit partial DONE or admit a new grant.
    LinkDiagnostics busy_diagnostics{};
    GroundTddController busy_ground{TddConfig{}, busy_diagnostics};
    busy_ground.reset(0U);
    start_two_chunk_transaction(busy_ground);
    TddInput blocked{};
    blocked.aux_high = true;
    blocked.radio_tx_empty = false;
    blocked.queued_bytes = 13U;
    blocked.front_frame_bytes = 13U;
    blocked.next_tx_application_bytes = 13U;
    blocked.next_tx_wire_bytes = 32U;
    blocked.now_ms = 2015U;
    report.check(busy_ground.tick(blocked).type == LinkActionType::None &&
                     !busy_ground.fail_closed(),
                 "started transaction failed before its absolute deadline");
    blocked.now_ms = 2016U;
    report.check(busy_ground.tick(blocked).type == LinkActionType::None &&
                     busy_ground.fail_closed() &&
                     busy_diagnostics.abandoned_uplink_transactions == 1U &&
                     busy_diagnostics.done_tx == 0U &&
                     busy_diagnostics.idle_tx == 0U,
                 "permanently unavailable writer did not fail closed exactly "
                 "once without partial DONE");
    blocked.now_ms = 2500U;
    (void)busy_ground.tick(blocked);
    TddControlMessage next_grant{};
    next_grant.version = kTddProtocolVersion;
    next_grant.type = ControlType::UlGrant;
    next_grant.session_id = 0x6202U;
    next_grant.cycle_id = 2U;
    next_grant.guard_ms = 0U;
    next_grant.window_ms = 300U;
    next_grant.max_bytes = 64U;
    report.check(busy_diagnostics.abandoned_uplink_transactions == 1U &&
                     busy_ground.on_control(next_grant, 2500U) ==
                         ControlDisposition::Invalid &&
                     busy_diagnostics.grant_rx == 1U,
                 "failed transaction was re-admitted or diagnosed twice");

    // A newer-session reboot cannot erase the watchdog or reinterpret the
    // retained suffix as a new frame.
    LinkDiagnostics reboot_diagnostics{};
    GroundTddController reboot_ground{TddConfig{}, reboot_diagnostics};
    reboot_ground.reset(0U);
    start_two_chunk_transaction(reboot_ground);
    TddControlMessage reboot_grant = next_grant;
    reboot_grant.session_id = 0x6203U;
    reboot_grant.cycle_id = 0U;
    report.check(reboot_ground.on_control(reboot_grant, 1000U) ==
                         ControlDisposition::Invalid &&
                     reboot_ground.fail_closed() &&
                     reboot_ground.actual_bytes() == 32U &&
                     reboot_ground.transaction_deadline_ms() == 2016U &&
                     reboot_diagnostics.grant_rx == 1U &&
                     reboot_diagnostics.abandoned_uplink_transactions == 1U,
                 "newer session reset an irreversible started prefix");

    // Repeated HardwareSerial zero-write/rejection follows the same bound.
    LinkDiagnostics rejected_diagnostics{};
    GroundTddController rejected_ground{TddConfig{}, rejected_diagnostics};
    rejected_ground.reset(0U);
    start_two_chunk_transaction(rejected_ground);
    TddInput retry = blocked;
    retry.radio_tx_empty = true;
    for (std::uint64_t now_ms = 567U; now_ms < 2016U; ++now_ms) {
      retry.now_ms = now_ms;
      const LinkAction action = rejected_ground.tick(retry);
      if (action.type == LinkActionType::SendRadioData) {
        rejected_ground.complete_action(action.token, TxResult::Rejected,
                                        now_ms);
      }
    }
    retry.now_ms = 2016U;
    report.check(rejected_ground.tick(retry).type == LinkActionType::None &&
                     rejected_ground.fail_closed() &&
                     rejected_diagnostics.action_retries > 0U &&
                     rejected_diagnostics.abandoned_uplink_transactions ==
                         1U,
                 "repeated zero-write rejection was not bounded fail-close");

    // Once a frame prefix has been irreversibly accepted, the frame-aware
    // ingress must retain its suffix until the fixed transaction target is
    // reached. If that invariant is violated, emitting a short UL_DONE would
    // falsely describe a partial MAVLink frame as a completed transaction.
    // Both the drain state and the next-send state must fail closed instead.
    LinkDiagnostics drain_underflow_diagnostics{};
    GroundTddController drain_underflow_ground{TddConfig{},
                                               drain_underflow_diagnostics};
    drain_underflow_ground.reset(0U);
    start_two_chunk_transaction(drain_underflow_ground);
    TddInput vanished_suffix{};
    vanished_suffix.aux_high = true;
    vanished_suffix.radio_tx_complete = true;
    vanished_suffix.radio_tx_empty = true;
    vanished_suffix.queued_bytes = 0U;
    vanished_suffix.front_frame_bytes = 0U;
    vanished_suffix.next_tx_application_bytes = 0U;
    vanished_suffix.next_tx_wire_bytes = 0U;
    vanished_suffix.now_ms = 567U;
    report.check(
        drain_underflow_ground.tick(vanished_suffix).type ==
                LinkActionType::None &&
            drain_underflow_ground.fail_closed() &&
            drain_underflow_diagnostics.abandoned_uplink_transactions == 1U &&
            drain_underflow_diagnostics.done_tx == 0U &&
            drain_underflow_diagnostics.idle_tx == 0U,
        "UplinkDrain emitted or prepared partial DONE after suffix vanished");

    LinkDiagnostics send_underflow_diagnostics{};
    GroundTddController send_underflow_ground{TddConfig{},
                                              send_underflow_diagnostics};
    send_underflow_ground.reset(0U);
    start_two_chunk_transaction(send_underflow_ground);
    TddInput suffix_ready = vanished_suffix;
    suffix_ready.queued_bytes = 13U;
    suffix_ready.front_frame_bytes = 13U;
    suffix_ready.next_tx_application_bytes = 13U;
    suffix_ready.next_tx_wire_bytes = 32U;
    suffix_ready.now_ms = 567U;
    (void)send_underflow_ground.tick(suffix_ready);
    report.check(send_underflow_ground.state() ==
                     GroundTddState::UplinkSend,
                 "underflow fixture did not enter UplinkSend");
    vanished_suffix.now_ms = 568U;
    report.check(
        send_underflow_ground.tick(vanished_suffix).type ==
                LinkActionType::None &&
            send_underflow_ground.fail_closed() &&
            send_underflow_diagnostics.abandoned_uplink_transactions == 1U &&
            send_underflow_diagnostics.done_tx == 0U &&
            send_underflow_diagnostics.idle_tx == 0U,
        "UplinkSend emitted or prepared partial DONE after suffix vanished");

    // At the exact boundary, an already accepted DONE whose radio completion
    // is observable wins over timeout and closes the lease normally.
    LinkDiagnostics boundary_diagnostics{};
    GroundTddController boundary_ground{TddConfig{}, boundary_diagnostics};
    boundary_ground.reset(0U);
    start_two_chunk_transaction(boundary_ground);
    TddInput ready = blocked;
    ready.radio_tx_complete = true;
    ready.radio_tx_empty = true;
    ready.now_ms = 567U;
    (void)boundary_ground.tick(ready);  // drain prefix 1 -> send prefix 2
    ready.now_ms = 568U;
    const LinkAction second = boundary_ground.tick(ready);
    report.check(second.type == LinkActionType::SendRadioData,
                 "boundary fixture did not issue prefix 2");
    boundary_ground.complete_action(second.token, TxResult::Accepted, 568U,
                                    13U);
    ready.queued_bytes = 0U;
    ready.front_frame_bytes = 0U;
    ready.next_tx_application_bytes = 0U;
    ready.next_tx_wire_bytes = 0U;
    ready.now_ms = 1118U;
    (void)boundary_ground.tick(ready);  // UplinkDrain -> SendUlDone
    ready.now_ms = 1119U;
    const LinkAction done = boundary_ground.tick(ready);
    report.check(done.type == LinkActionType::SendDone &&
                     done.control.actual_bytes == 45U,
                 "boundary fixture did not issue full UL_DONE");
    boundary_ground.complete_action(done.token, TxResult::Accepted, 1119U);
    ready.radio_tx_complete = false;
    ready.radio_tx_empty = false;
    ready.now_ms = 2015U;
    (void)boundary_ground.tick(ready);
    report.check(boundary_ground.state() == GroundTddState::DoneDrain,
                 "terminal completed before its exact-boundary observation");
    // The previous UL_DONE is physically complete at the boundary, but
    // capacity for a future 32-byte write remains low. Completion must not
    // depend on that future capacity.
    ready.radio_tx_complete = true;
    ready.radio_tx_empty = false;
    ready.now_ms = 2016U;
    report.check(boundary_ground.tick(ready).type == LinkActionType::None &&
                     boundary_ground.state() == GroundTddState::WaitGrant &&
                     !boundary_ground.fail_closed() &&
                     boundary_diagnostics.abandoned_uplink_transactions ==
                         0U,
                 "observable terminal completion lost to the exact deadline");

    report.diagnostics = busy_diagnostics;
    report.detail =
        "started prefix deadline=2016ms; busy and rejected paths fail closed "
        "once; vanished suffix fails closed without partial DONE; terminal "
        "completion at boundary wins";
  } else {
    report.check(false, "unknown unit test ID");
  }

  report.trace.record({0, "host", "UNIT", 0,
                       report.passed ? "PASS" : "FAIL", true, 0, 0, 0});
  return report;
}

}  // namespace vc_lora::test
