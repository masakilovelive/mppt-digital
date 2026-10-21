#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

#include "fixtures/mavlink_fixtures.hpp"
#include "vc_lora/embedded_io_adapter.hpp"
#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/tdd_link_demux.hpp"
#include "vc_lora/tdd_vehicle.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint16_t kSession = 0x4102U;
constexpr std::uint16_t kCycle = 7U;

void check_fixed_tdd_config(const TddConfig& config,
                            TestReport& report) {
  report.check(config.downlink_send_ms == 3000U,
               "fixed downlink duration changed from 3000 ms");
  report.check(config.uplink_guard_ms == 650U,
               "fixed uplink guard changed from 650 ms");
  report.check(config.uplink_window_ms == 300U,
               "fixed Ground uplink window changed from 300 ms");
  report.check(config.vehicle_receive_timeout_ms == 2000U,
               "fixed Vehicle receive timeout changed from 2000 ms");
  report.check(config.return_guard_ms == 650U,
               "fixed return guard changed from 650 ms");
  report.check(config.late_terminal_wait_ms == 1300U,
               "timeout-originated terminal wait changed from 1300 ms");
  report.check(config.min_tx_gap_ms == 180U,
               "fixed minimum TX gap changed from 180 ms");
  report.check(config.radio_uart_bps == 115200U &&
                   config.radio_air_bps == 19200U,
               "fixed E220 UART/air bitrate changed");
}

TddInput vehicle_input(std::uint64_t now_ms,
                       bool radio_tx_empty = true) noexcept {
  TddInput input{};
  input.now_ms = now_ms;
  input.aux_high = true;
  input.radio_tx_empty = radio_tx_empty;
  input.local_tx_empty = true;
  return input;
}

struct VehicleFixture {
  TddConfig config{};
  LinkDiagnostics diagnostics{};
  VehicleTddController controller{config, diagnostics};
  std::uint64_t grant_complete_ms{0U};

  VehicleFixture() {
    controller.reset(kSession, kCycle, 0U);
    (void)controller.tick(vehicle_input(0U));
    (void)controller.tick(vehicle_input(config.aux_stable_ms));

    (void)controller.tick(vehicle_input(config.downlink_send_ms));
    (void)controller.tick(vehicle_input(config.downlink_send_ms + 1U));
    const LinkAction grant =
        controller.tick(vehicle_input(config.downlink_send_ms + 2U));
    grant_complete_ms = config.downlink_send_ms + 2U;
    if (grant.type == LinkActionType::SendGrant) {
      controller.complete_action(grant.token, TxResult::Accepted,
                                 grant_complete_ms);
    }
  }

  void finish_grant_drain() {
    (void)controller.tick(vehicle_input(grant_complete_ms + 1U));
  }
};

constexpr std::uint64_t kObservedHighOnlyDrainMs = 180U;
constexpr std::uint64_t kObservedFirstTerminalFromGuardMs = 2'624U;
constexpr std::uint64_t kObservedSecondTerminalFromGuardMs = 3'176U;
constexpr std::uint64_t kObservedTargetDoneFromGuardMs = 3'282U;
// FW-GUARD-EPOCH-DIAG-002 left only 18 ms before the old Q+3300 close and
// recorded 63 half-duplex overlap bytes after 9/42 terminals were missed.
// Preserve one additional observed 550-ms E220 delivery slot plus 118 ms of
// margin without changing the five existing 3000/650/300/2000/650 values.
constexpr std::uint64_t kObservedThirdTerminalFromGuardMs = 3'832U;
constexpr std::uint64_t kRequiredLateTerminalWaitMs = 1'300U;

TddControlMessage uplink_control(ControlType type,
                                 std::uint16_t session,
                                 std::uint16_t cycle) noexcept;

void enter_guard_after_drain(VehicleFixture& fixture,
                             std::uint64_t drain_ms,
                             TestReport& report) {
  const std::uint64_t guard_entered_ms =
      fixture.grant_complete_ms + drain_ms;
  if (drain_ms > 0U) {
    (void)fixture.controller.tick(
        vehicle_input(guard_entered_ms - 1U, false));
    report.check(fixture.controller.state() ==
                     VehicleTddState::GrantDrain,
                 "Vehicle left GrantDrain before physical completion");
  }
  (void)fixture.controller.tick(vehicle_input(guard_entered_ms));
  report.check(fixture.controller.state() == VehicleTddState::UplinkGuard,
               "physical grant completion did not enter UplinkGuard");
}

void advance_vehicle_millisecondwise(VehicleTddController& controller,
                                     std::uint64_t& now_ms,
                                     std::uint64_t target_ms,
                                     bool radio_tx_empty = true) {
  while (now_ms < target_ms) {
    ++now_ms;
    (void)controller.tick(vehicle_input(now_ms, radio_tx_empty));
  }
}

void check_guard_epoch_after_high_only_drain(TestReport& report) {
  VehicleFixture fixture{};
  check_fixed_tdd_config(fixture.config, report);
  enter_guard_after_drain(fixture, kObservedHighOnlyDrainMs, report);

  const std::uint64_t guard_entered_ms =
      fixture.grant_complete_ms + kObservedHighOnlyDrainMs;
  (void)fixture.controller.tick(vehicle_input(
      guard_entered_ms + fixture.config.uplink_guard_ms - 1U));
  report.check(fixture.controller.state() == VehicleTddState::UplinkGuard,
               "180-ms grant drain consumed part of the fixed 650-ms guard");
  (void)fixture.controller.tick(vehicle_input(
      guard_entered_ms + fixture.config.uplink_guard_ms));
  report.check(fixture.controller.state() ==
                   VehicleTddState::UplinkReceive,
               "UplinkReceive did not start exactly 650 ms after drain");
}

void check_second_delivery_slot_recovery(TestReport& report) {
  VehicleFixture fixture{};
  enter_guard_after_drain(fixture, kObservedHighOnlyDrainMs, report);
  const std::uint64_t guard_entered_ms =
      fixture.grant_complete_ms + kObservedHighOnlyDrainMs;
  std::uint64_t now_ms = guard_entered_ms;
  const std::uint64_t terminal_ms =
      guard_entered_ms + kObservedSecondTerminalFromGuardMs;
  advance_vehicle_millisecondwise(fixture.controller, now_ms, terminal_ms);

  report.check(fixture.controller.state() == VehicleTddState::ReturnGuard &&
                   fixture.controller.late_uplink_recovery_window() &&
                   fixture.controller.cycle_id() == kCycle,
               "second 550-ms delivery slot escaped timeout recovery");
  const bool accepted = fixture.controller.complete_late_uplink_terminal(
      terminal_ms, ControlType::UlIdle, true);
  report.check(accepted && fixture.diagnostics.idle_rx == 1U,
               "Q+3176 UL_IDLE was not accepted as the same cycle");

  advance_vehicle_millisecondwise(
      fixture.controller, now_ms,
      terminal_ms + fixture.config.return_guard_ms - 1U);
  report.check(fixture.controller.cycle_id() == kCycle &&
                   fixture.diagnostics.uplink_timeouts == 0U,
               "late UL_IDLE did not cancel the provisional timeout");
  advance_vehicle_millisecondwise(
      fixture.controller, now_ms,
      terminal_ms + fixture.config.return_guard_ms);
  report.check(fixture.controller.cycle_id() ==
                   static_cast<std::uint16_t>(kCycle + 1U) &&
                   fixture.diagnostics.uplink_timeouts == 0U,
               "cycle did not advance once after the re-anchored return guard");
}

void check_timeout_recovery_deadline_boundaries(TestReport& report) {
  VehicleFixture before{};
  enter_guard_after_drain(before, kObservedHighOnlyDrainMs, report);
  const std::uint64_t guard_entered_ms =
      before.grant_complete_ms + kObservedHighOnlyDrainMs;
  const std::uint64_t timeout_ms =
      guard_entered_ms + before.config.uplink_guard_ms +
      before.config.vehicle_receive_timeout_ms;
  const std::uint64_t recovery_deadline_ms =
      timeout_ms + kRequiredLateTerminalWaitMs;
  std::uint64_t now_ms = guard_entered_ms;

  advance_vehicle_millisecondwise(before.controller, now_ms,
                                  recovery_deadline_ms - 1U);
  report.check(before.controller.state() == VehicleTddState::ReturnGuard &&
                   before.controller.late_uplink_recovery_window() &&
                   before.controller.cycle_id() == kCycle,
               "timeout recovery closed before its 1300-ms deadline");
  report.check(before.controller.complete_late_uplink_terminal(
                   recovery_deadline_ms, ControlType::UlIdle, true) &&
                   before.diagnostics.idle_rx == 1U,
               "deliver-before-tick terminal was rejected at Q+3950");

  VehicleFixture no_terminal{};
  enter_guard_after_drain(no_terminal, kObservedHighOnlyDrainMs, report);
  now_ms = guard_entered_ms;
  advance_vehicle_millisecondwise(no_terminal.controller, now_ms,
                                  recovery_deadline_ms - 1U);
  report.check(no_terminal.controller.cycle_id() == kCycle &&
                   no_terminal.diagnostics.uplink_timeouts == 0U,
               "no-terminal cycle advanced before Q+3950");
  advance_vehicle_millisecondwise(no_terminal.controller, now_ms,
                                  recovery_deadline_ms);
  report.check(no_terminal.controller.state() ==
                       VehicleTddState::DownlinkSend &&
                   no_terminal.controller.cycle_id() ==
                       static_cast<std::uint16_t>(kCycle + 1U) &&
                   no_terminal.diagnostics.uplink_timeouts == 1U,
               "no-terminal cycle did not close exactly at Q+3950");
}

void check_third_slot_data_and_terminal(TestReport& report) {
  VehicleFixture fixture{};
  enter_guard_after_drain(fixture, kObservedHighOnlyDrainMs, report);
  const std::uint64_t guard_entered_ms =
      fixture.grant_complete_ms + kObservedHighOnlyDrainMs;
  std::uint64_t now_ms = guard_entered_ms;
  const std::uint64_t data_ms =
      guard_entered_ms + kObservedThirdTerminalFromGuardMs;
  const std::uint64_t terminal_ms = data_ms + 550U;

  advance_vehicle_millisecondwise(fixture.controller, now_ms, data_ms);
  report.check(fixture.controller.state() == VehicleTddState::ReturnGuard &&
                   fixture.controller.late_uplink_recovery_window() &&
                   fixture.controller.note_return_guard_activity(data_ms),
               "Q+3832 application activity was outside late recovery");

  // Identity checks remain fail-closed throughout the longer silent lease.
  report.check(fixture.controller.on_control(
                   uplink_control(ControlType::UlDone,
                                  static_cast<std::uint16_t>(kSession - 1U),
                                  kCycle),
                   data_ms) == ControlDisposition::OldSession &&
                   fixture.controller.on_control(
                       uplink_control(
                           ControlType::UlDone, kSession,
                           static_cast<std::uint16_t>(kCycle - 1U)),
                       data_ms) == ControlDisposition::OldCycle &&
                   fixture.controller.late_uplink_recovery_window(),
               "stale identity changed the extended recovery lease");

  advance_vehicle_millisecondwise(fixture.controller, now_ms, terminal_ms);
  report.check(fixture.controller.complete_late_uplink_terminal(
                   terminal_ms, ControlType::UlDone, true) &&
                   fixture.diagnostics.done_rx == 1U &&
                   fixture.diagnostics.uplink_timeouts == 0U,
               "data at Q+3832 did not preserve DONE at Q+4382");
  advance_vehicle_millisecondwise(
      fixture.controller, now_ms,
      terminal_ms + fixture.config.return_guard_ms - 1U);
  report.check(fixture.controller.cycle_id() == kCycle &&
                   fixture.controller.state() == VehicleTddState::ReturnGuard,
               "late terminal allowed Vehicle TX before 650-ms quiet time");
  advance_vehicle_millisecondwise(
      fixture.controller, now_ms,
      terminal_ms + fixture.config.return_guard_ms);
  report.check(fixture.controller.cycle_id() ==
                       static_cast<std::uint16_t>(kCycle + 1U) &&
                   fixture.diagnostics.uplink_timeouts == 0U,
               "late terminal did not advance exactly once after quiet time");
}

void check_variable_drain_preserves_full_guard(TestReport& report) {
  constexpr std::array<std::uint64_t, 4U> kDrainDurationsMs{{
      180U, 325U, 650U, 1'999U}};
  for (const std::uint64_t drain_ms : kDrainDurationsMs) {
    VehicleFixture fixture{};
    enter_guard_after_drain(fixture, drain_ms, report);
    const std::uint64_t guard_entered_ms =
        fixture.grant_complete_ms + drain_ms;
    (void)fixture.controller.tick(vehicle_input(
        guard_entered_ms + fixture.config.uplink_guard_ms - 1U));
    report.check(fixture.controller.state() == VehicleTddState::UplinkGuard,
                 "variable grant drain shortened the fixed guard");
    (void)fixture.controller.tick(vehicle_input(
        guard_entered_ms + fixture.config.uplink_guard_ms));
    report.check(fixture.controller.state() ==
                     VehicleTddState::UplinkReceive,
                 "variable drain did not preserve an exact 650-ms guard");
  }
}

void check_alternating_hil_delivery_slots(TestReport& report) {
  constexpr std::size_t kCycles = 100U;
  constexpr std::array<std::uint64_t, 4U> kTerminalOffsetsMs{{
      kObservedFirstTerminalFromGuardMs,
      kObservedSecondTerminalFromGuardMs,
      kObservedTargetDoneFromGuardMs,
      kObservedThirdTerminalFromGuardMs,
  }};
  TddConfig config{};
  LinkDiagnostics diagnostics{};
  VehicleTddController controller(config, diagnostics);
  controller.reset(kSession, 0U, 0U);

  std::uint64_t now_ms = 0U;
  (void)controller.tick(vehicle_input(now_ms));
  std::size_t accepted_terminals = 0U;
  for (std::size_t index = 0U; index < kCycles; ++index) {
    LinkAction grant{};
    while (grant.type == LinkActionType::None) {
      ++now_ms;
      grant = controller.tick(vehicle_input(now_ms));
    }
    report.check(grant.type == LinkActionType::SendGrant,
                 "empty-cycle fixture issued a non-GRANT action");
    if (grant.type != LinkActionType::SendGrant) {
      break;
    }

    const std::uint16_t granted_cycle = controller.cycle_id();
    const std::uint64_t grant_complete_ms = now_ms;
    controller.complete_action(grant.token, TxResult::Accepted,
                               grant_complete_ms);
    const std::uint64_t guard_entered_ms =
        grant_complete_ms + kObservedHighOnlyDrainMs;
    advance_vehicle_millisecondwise(controller, now_ms,
                                    guard_entered_ms - 1U, false);
    advance_vehicle_millisecondwise(controller, now_ms, guard_entered_ms);
    report.check(controller.state() == VehicleTddState::UplinkGuard,
                 "repeated fixture did not enter UplinkGuard after drain");

    const std::uint64_t terminal_offset_ms =
        kTerminalOffsetsMs[index % kTerminalOffsetsMs.size()];
    const std::uint64_t terminal_ms =
        guard_entered_ms + terminal_offset_ms;
    advance_vehicle_millisecondwise(controller, now_ms, terminal_ms);

    bool accepted = false;
    if (controller.radio_receive_window()) {
      accepted = controller.on_control(
                     uplink_control(ControlType::UlIdle, kSession,
                                    granted_cycle),
                     terminal_ms) == ControlDisposition::Accepted;
    } else if (controller.late_uplink_recovery_window() &&
               controller.cycle_id() == granted_cycle) {
      accepted = controller.complete_late_uplink_terminal(
          terminal_ms, ControlType::UlIdle, true);
    }
    if (accepted) {
      ++accepted_terminals;
    } else {
      // Mirrors the 63-byte Ground `hd/r1` overlap signature from the HIL
      // run whenever Vehicle advances and resumes downlink before a terminal.
      diagnostics.half_duplex_drop_count += 63U;
    }

    while (controller.cycle_id() == granted_cycle) {
      ++now_ms;
      (void)controller.tick(vehicle_input(now_ms));
    }
  }

  report.check(diagnostics.grant_tx == kCycles,
               "100-cycle HIL timing fixture did not send 100 grants");
  report.check(accepted_terminals == kCycles &&
                   diagnostics.idle_rx == kCycles,
               "Q+2624/3176/3282/3832 terminals were not all accepted");
  report.check(diagnostics.uplink_timeouts == 0U,
               "four-phase HIL delivery slots produced an uplink timeout");
  report.check(diagnostics.half_duplex_drop_count == 0U,
               "early cycle advance reproduced Ground hd/r1 overlap");
  report.diagnostics = diagnostics;
}

TddControlMessage uplink_control(ControlType type,
                                 std::uint16_t session = kSession,
                                 std::uint16_t cycle = kCycle) noexcept {
  TddControlMessage message{};
  message.version = kTddProtocolVersion;
  message.type = type;
  message.session_id = session;
  message.cycle_id = cycle;
  message.actual_bytes = type == ControlType::UlDone ? 32U : 0U;
  return message;
}

void feed_mavlink_as_radio_data(
    VehicleTddController& controller, LinkDiagnostics& diagnostics,
    const MavlinkFrame& frame, TddLinkDemux& demux,
    MavlinkValidatedLocalEgressAdapter<>& endpoint, TestReport& report) {
  std::size_t application_offset = 0U;
  while (application_offset < frame.size) {
    const EncodedLinkDataChunk encoded = encode_link_data(
        frame.bytes.data() + application_offset,
        frame.size - application_offset);
    report.check(encoded.input_consumed > 0U,
                 "link-data encoder made no progress");
    if (encoded.input_consumed == 0U) {
      return;
    }

    for (std::size_t wire_index = 0U; wire_index < encoded.wire_size;
         ++wire_index) {
      const TddDemuxEvent event = demux.push(encoded.wire_bytes[wire_index]);
      if (!controller.radio_receive_window() && event.local_size > 0U) {
        diagnostics.uplink_data_outside_receive_window += event.local_size;
        continue;
      }
      for (std::size_t local_index = 0U; local_index < event.local_size;
           ++local_index) {
        (void)endpoint.ingest_byte(event.local_bytes[local_index]);
      }
    }
    application_offset += encoded.input_consumed;
  }
  report.check(!endpoint.fail_closed(),
               "validated Pixhawk egress failed closed");
}

void check_exact_frame(const MavlinkFrame& frame,
                       MavlinkValidatedLocalEgressAdapter<>& endpoint,
                       TestReport& report) {
  std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> output{};
  const std::size_t output_size =
      endpoint.egress().peek(output.data(), output.size());
  report.check(output_size == frame.size,
               "same-cycle MAVLink frame was not queued for Pixhawk");
  report.check(output_size == frame.size &&
                   std::equal(output.begin(), output.begin() + output_size,
                              frame.bytes.begin()),
               "same-cycle MAVLink frame changed before Pixhawk egress");
}

void check_guard_data_at_offset(std::uint64_t offset_ms,
                                TestReport& report) {
  VehicleFixture fixture{};
  fixture.finish_grant_drain();
  const std::uint64_t arrival_ms = fixture.grant_complete_ms + offset_ms;
  (void)fixture.controller.tick(vehicle_input(arrival_ms));
  report.check(fixture.controller.state() == VehicleTddState::UplinkGuard,
               "boundary sample was not inside UplinkGuard");
  report.check(fixture.controller.radio_receive_window(),
               "UplinkGuard did not admit same-cycle radio data");

  const MavlinkFrame request =
      fixtures::param_request_read_v2(0x31U, "SERIAL1_BAUD");
  TddLinkDemux demux{true};
  MavlinkValidatedLocalEgressAdapter<> endpoint{};
  feed_mavlink_as_radio_data(fixture.controller, fixture.diagnostics,
                             request, demux, endpoint, report);
  report.check(
      fixture.diagnostics.uplink_data_outside_receive_window == 0U,
      "UplinkGuard data was counted outside the receive window");
  check_exact_frame(request, endpoint, report);
  report.diagnostics = fixture.diagnostics;
}

}  // namespace

TestReport run_uplink_guard_test(const std::string& test_id,
                                 std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-UPLINK-GUARD-DATA-001") {
    // Hardware reproduction: Ground data can arrive after GrantDrain but
    // before the Vehicle's local guard timer expires. It is already tied to
    // this session/cycle by the accepted UL_GRANT and must not be discarded.
    check_fixed_tdd_config(TddConfig{}, report);
    check_guard_data_at_offset(1U, report);

    // Receiving an early frame opens no new or sliding timeout. The timeout
    // still starts when the fixed guard expires, stays open through
    // timeout-1, and closes at the exact 2000 ms Vehicle deadline.
    VehicleFixture timeout_fixture{};
    timeout_fixture.finish_grant_drain();
    const MavlinkFrame early_request =
        fixtures::param_request_read_v2(0x32U, "SERIAL1_BAUD");
    TddLinkDemux timeout_demux{true};
    MavlinkValidatedLocalEgressAdapter<> timeout_endpoint{};
    feed_mavlink_as_radio_data(
        timeout_fixture.controller, timeout_fixture.diagnostics,
        early_request, timeout_demux, timeout_endpoint, report);
    const std::uint64_t receive_started_ms =
        timeout_fixture.grant_complete_ms + 1U +
        timeout_fixture.config.uplink_guard_ms;
    (void)timeout_fixture.controller.tick(vehicle_input(receive_started_ms));
    report.check(timeout_fixture.controller.state() ==
                     VehicleTddState::UplinkReceive,
                 "fixed guard expiry did not start UplinkReceive");
    const std::uint64_t timeout_minus_one_ms =
        receive_started_ms +
        timeout_fixture.config.vehicle_receive_timeout_ms - 1U;
    (void)timeout_fixture.controller.tick(
        vehicle_input(timeout_minus_one_ms));
    report.check(timeout_fixture.controller.state() ==
                         VehicleTddState::UplinkReceive &&
                     timeout_fixture.controller.radio_receive_window(),
                 "early data shortened or extended timeout-1 boundary");
    report.check(timeout_fixture.diagnostics.uplink_timeouts == 0U,
                 "timeout was counted before the exact deadline");
    const std::uint64_t timeout_exact_ms =
        receive_started_ms +
        timeout_fixture.config.vehicle_receive_timeout_ms;
    (void)timeout_fixture.controller.tick(vehicle_input(timeout_exact_ms));
    report.check(timeout_fixture.controller.state() ==
                         VehicleTddState::ReturnGuard &&
                     !timeout_fixture.controller.radio_receive_window(),
                 "early data extended the exact receive timeout deadline");
    report.check(timeout_fixture.diagnostics.uplink_timeouts == 0U,
                 "provisional timeout was counted before late recovery ended");
    const std::uint64_t recovery_expiry_ms =
        timeout_exact_ms + timeout_fixture.config.late_terminal_wait_ms;
    (void)timeout_fixture.controller.tick(
        vehicle_input(recovery_expiry_ms));
    report.check(timeout_fixture.controller.state() ==
                         VehicleTddState::DownlinkSend &&
                     timeout_fixture.diagnostics.uplink_timeouts == 1U,
                 "unrecovered receive timeout was not counted exactly once");
    (void)timeout_fixture.controller.tick(
        vehicle_input(recovery_expiry_ms + 1U));
    report.check(timeout_fixture.diagnostics.uplink_timeouts == 1U,
                 "unrecovered receive timeout was counted twice");
    report.detail =
        "early data accepted; timeout commits once after 1300-ms recovery";
  } else if (test_id == "UT-UPLINK-GUARD-DATA-002") {
    // Boundary sweep without changing any production TDD duration.
    const TddConfig fixed{};
    check_fixed_tdd_config(fixed, report);
    constexpr std::array<std::uint64_t, 3> kOffsets{{1U, 325U, 649U}};
    for (const std::uint64_t offset : kOffsets) {
      report.check(offset < fixed.uplink_guard_ms,
                   "test offset escaped the fixed 650 ms guard");
      check_guard_data_at_offset(offset, report);
    }
    report.detail = "UplinkGuard offsets 1/325/649 ms; fixed guard=650 ms";
  } else if (test_id == "UT-UPLINK-GUARD-CONTROL-001" ||
             test_id == "UT-UPLINK-GUARD-CONTROL-002") {
    VehicleFixture fixture{};
    fixture.finish_grant_drain();
    const ControlType type =
        test_id == "UT-UPLINK-GUARD-CONTROL-001" ? ControlType::UlDone
                                                  : ControlType::UlIdle;
    const std::uint16_t accepted_cycle = fixture.controller.cycle_id();
    const std::uint64_t terminal_ms = fixture.grant_complete_ms + 2U;
    const ControlDisposition disposition = fixture.controller.on_control(
        uplink_control(type), terminal_ms);
    report.check(disposition == ControlDisposition::Accepted,
                 type == ControlType::UlDone
                     ? "same-cycle UL_DONE was ignored during UplinkGuard"
                     : "same-cycle UL_IDLE was ignored during UplinkGuard");
    report.check(fixture.controller.state() == VehicleTddState::ReturnGuard,
                 "accepted guard control did not enter ReturnGuard");
    report.check(!fixture.controller.radio_receive_window(),
                 "receive window stayed open after accepted DONE/IDLE");
    report.check(type == ControlType::UlDone
                     ? fixture.diagnostics.done_rx == 1U
                     : fixture.diagnostics.idle_rx == 1U,
                 "accepted guard control diagnostic was not recorded");
    const LinkAction before_resume = fixture.controller.tick(vehicle_input(
        terminal_ms + fixture.config.return_guard_ms - 1U));
    report.check(before_resume.type == LinkActionType::None &&
                     fixture.controller.state() ==
                         VehicleTddState::ReturnGuard &&
                     fixture.controller.cycle_id() == accepted_cycle,
                 "terminal return guard ended before the fixed 650 ms");
    const std::uint64_t resumed_ms =
        terminal_ms + fixture.config.return_guard_ms;
    const LinkAction at_resume =
        fixture.controller.tick(vehicle_input(resumed_ms));
    report.check(at_resume.type == LinkActionType::None &&
                     fixture.controller.state() ==
                         VehicleTddState::DownlinkSend &&
                     fixture.controller.cycle_id() ==
                         static_cast<std::uint16_t>(accepted_cycle + 1U),
                 "valid terminal did not resume downlink at +650 ms");
    (void)fixture.controller.tick(vehicle_input(
        resumed_ms + fixture.config.downlink_send_ms - 1U));
    report.check(fixture.controller.state() ==
                         VehicleTddState::DownlinkSend &&
                     fixture.controller.cycle_id() ==
                         static_cast<std::uint16_t>(accepted_cycle + 1U),
                 "early-return cycle lost its full 3000-ms downlink window");
    (void)fixture.controller.tick(vehicle_input(
        resumed_ms + fixture.config.downlink_send_ms));
    report.check(fixture.controller.state() ==
                         VehicleTddState::DownlinkDrain &&
                     fixture.controller.cycle_id() ==
                         static_cast<std::uint16_t>(accepted_cycle + 1U),
                 "early-return downlink admission did not close at +3000 ms");
    report.diagnostics = fixture.diagnostics;
    report.detail = type == ControlType::UlDone
                        ? "UL_DONE -> 650-ms guard -> fresh 3000-ms downlink"
                        : "UL_IDLE -> 650-ms guard -> fresh 3000-ms downlink";
  } else if (test_id == "UT-UPLINK-GRANT-DRAIN-001") {
    VehicleFixture data_fixture{};
    check_fixed_tdd_config(data_fixture.config, report);
    report.check(data_fixture.controller.state() ==
                     VehicleTddState::GrantDrain,
                 "fixture did not stop in GrantDrain");
    report.check(!data_fixture.controller.radio_receive_window(),
                 "GrantDrain incorrectly admitted radio data");
    const MavlinkFrame request =
        fixtures::param_request_read_v2(0x41U, "SERIAL1_BAUD");
    TddLinkDemux demux{true};
    MavlinkValidatedLocalEgressAdapter<> endpoint{};
    feed_mavlink_as_radio_data(data_fixture.controller,
                               data_fixture.diagnostics, request, demux,
                               endpoint, report);
    report.check(endpoint.egress().empty(),
                 "GrantDrain data reached Pixhawk egress");
    report.check(data_fixture.diagnostics
                         .uplink_data_outside_receive_window == request.size,
                 "GrantDrain data rejection was not diagnosed");

    // A slow E220 drain must not consume the receive timeout. Even after the
    // nominal guard plus the full 2000 ms receive period has elapsed, the
    // controller remains in GrantDrain with no timeout until RF drain ends.
    const std::uint64_t long_drain_ms =
        data_fixture.grant_complete_ms +
        data_fixture.config.uplink_guard_ms +
        data_fixture.config.vehicle_receive_timeout_ms + 1U;
    (void)data_fixture.controller.tick(
        vehicle_input(long_drain_ms, false));
    report.check(data_fixture.controller.state() ==
                     VehicleTddState::GrantDrain,
                 "long RF drain incorrectly consumed receive states");
    report.check(data_fixture.diagnostics.uplink_timeouts == 0U,
                 "receive timeout ran while UL_GRANT was still draining");
    (void)data_fixture.controller.tick(vehicle_input(long_drain_ms + 1U));
    report.check(data_fixture.controller.state() ==
                         VehicleTddState::UplinkGuard &&
                     data_fixture.controller.radio_receive_window(),
                 "completed long drain did not enter the safe guard window");
    report.check(data_fixture.diagnostics.uplink_timeouts == 0U,
                 "completing a long drain caused an immediate timeout");

    VehicleFixture done_fixture{};
    VehicleFixture idle_fixture{};
    report.check(done_fixture.controller.on_control(
                     uplink_control(ControlType::UlDone),
                     done_fixture.grant_complete_ms + 1U) ==
                     ControlDisposition::Ignored,
                 "GrantDrain accepted UL_DONE before RF drain completed");
    report.check(idle_fixture.controller.on_control(
                     uplink_control(ControlType::UlIdle),
                     idle_fixture.grant_complete_ms + 1U) ==
                     ControlDisposition::Ignored,
                 "GrantDrain accepted UL_IDLE before RF drain completed");
    report.diagnostics = data_fixture.diagnostics;
    report.detail = "data/DONE/IDLE remain forbidden in GrantDrain";
  } else if (test_id == "UT-UPLINK-GUARD-EPOCH-001") {
    check_guard_epoch_after_high_only_drain(report);
    check_second_delivery_slot_recovery(report);
    check_timeout_recovery_deadline_boundaries(report);
    check_third_slot_data_and_terminal(report);
    check_variable_drain_preserves_full_guard(report);
    check_alternating_hil_delivery_slots(report);
    report.detail =
        "fixed guard plus 1300-ms timeout recovery; HIL slots "
        "Q+2624/3176/3282/3832 accepted for 100 cycles; HD overlap 0";
  } else if (test_id == "UT-UPLINK-IDENTITY-001") {
    VehicleFixture fixture{};
    check_fixed_tdd_config(fixture.config, report);
    fixture.finish_grant_drain();
    const ControlDisposition wrong_session = fixture.controller.on_control(
        uplink_control(ControlType::UlDone,
                       static_cast<std::uint16_t>(kSession - 1U), kCycle),
        fixture.grant_complete_ms + 2U);
    const ControlDisposition wrong_cycle = fixture.controller.on_control(
        uplink_control(ControlType::UlDone, kSession,
                       static_cast<std::uint16_t>(kCycle - 1U)),
        fixture.grant_complete_ms + 3U);
    report.check(wrong_session == ControlDisposition::OldSession,
                 "UplinkGuard accepted a different session");
    report.check(wrong_cycle == ControlDisposition::OldCycle,
                 "UplinkGuard accepted a different cycle");
    report.check(fixture.controller.state() == VehicleTddState::UplinkGuard,
                 "rejected identity changed the receive state");
    report.check(fixture.diagnostics.stale_sessions == 1U &&
                     fixture.diagnostics.stale_cycles == 1U,
                 "identity rejection diagnostics are incorrect");
    report.diagnostics = fixture.diagnostics;
    report.detail = "different session/cycle rejected during UplinkGuard";
  } else {
    report.check(false, "unknown UplinkGuard test case");
  }

  report.final_vehicle_state = "TEST_COMPLETE";
  report.final_ground_state = "NOT_APPLICABLE";
  return report;
}

}  // namespace vc_lora::test
