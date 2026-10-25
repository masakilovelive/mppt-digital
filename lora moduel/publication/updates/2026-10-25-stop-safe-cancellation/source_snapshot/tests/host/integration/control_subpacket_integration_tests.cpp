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
#include "vc_lora/runtime_contract.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_ground.hpp"
#include "vc_lora/tdd_link_demux.hpp"
#include "vc_lora/tdd_vehicle.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint16_t kSession = 0x4102U;
constexpr std::uint16_t kCycle = 7U;
constexpr std::size_t kLegacyControlBytes = 22U;
constexpr std::size_t kFullSubpacketBytes = 32U;

// The 32-byte standalone E220 test measured about 164 ms for a two-way
// DATA/ACK exchange, so the model uses 82 ms for one full-subpacket hop.  The
// 22-byte counterfactual uses the production-observed grant/IDLE interval:
// 180 + (82 + 988) + 650 + (82 + 988) = 2,970 ms from the previous HB,
// or 2,790 ms from GRANT start (observed 2,789 ms).  This intentionally models
// the hardware symptom, not the nominal 50 ms datasheet flush setting.
constexpr std::uint64_t kFullSubpacketOneWayMs = 82U;
constexpr std::uint64_t kObservedPartialQueueMs = 988U;
constexpr std::uint64_t kHeartbeatLimitMs = 2'500U;

struct TddLatencyResult {
  std::size_t control_bytes{0U};
  bool partial_control{false};
  std::uint64_t grant_tx_ms{0U};
  std::uint64_t grant_rx_ms{0U};
  std::uint64_t vehicle_receive_start_ms{0U};
  std::uint64_t vehicle_receive_deadline_ms{0U};
  std::uint64_t data_rx_ms{0U};
  std::uint64_t done_rx_ms{0U};
  std::uint64_t idle_rx_ms{0U};
  std::uint64_t next_hb_after_done_ms{0U};
  std::uint64_t next_hb_after_idle_ms{0U};
};

constexpr std::uint64_t control_delivery_ms(
    std::size_t control_bytes) noexcept {
  return kFullSubpacketOneWayMs +
         (control_bytes < kFullSubpacketBytes
              ? kObservedPartialQueueMs
              : 0U);
}

TddLatencyResult model_fixed_tdd(std::size_t control_bytes) noexcept {
  const TddConfig config{};
  TddLatencyResult result{};
  result.control_bytes = control_bytes;
  result.partial_control = control_bytes < config.radio_chunk_bytes;

  // The previous downlink heartbeat finishes one minimum physical-write gap
  // before GRANT. All times below are relative to that heartbeat TX start.
  result.grant_tx_ms = config.min_tx_gap_ms;
  result.vehicle_receive_start_ms =
      result.grant_tx_ms + config.uplink_guard_ms;
  result.vehicle_receive_deadline_ms =
      result.vehicle_receive_start_ms + config.vehicle_receive_timeout_ms;
  result.grant_rx_ms =
      result.grant_tx_ms + control_delivery_ms(control_bytes);

  const std::uint64_t ground_data_or_idle_tx =
      result.grant_rx_ms + config.uplink_guard_ms;
  result.data_rx_ms =
      ground_data_or_idle_tx + kFullSubpacketOneWayMs;
  const std::uint64_t done_tx_ms =
      ground_data_or_idle_tx + config.min_tx_gap_ms;
  result.done_rx_ms = done_tx_ms + control_delivery_ms(control_bytes);
  result.idle_rx_ms =
      ground_data_or_idle_tx + control_delivery_ms(control_bytes);
  result.next_hb_after_done_ms =
      result.done_rx_ms + config.return_guard_ms;
  result.next_hb_after_idle_ms =
      result.idle_rx_ms + config.return_guard_ms;
  return result;
}

bool in_normal_vehicle_receive(const TddLatencyResult& timing,
                               std::uint64_t arrival_ms) noexcept {
  return arrival_ms >= timing.vehicle_receive_start_ms &&
         arrival_ms < timing.vehicle_receive_deadline_ms;
}

void check_fixed_contract(TestReport& report) {
  const TddConfig config{};
  report.check(config.downlink_send_ms == 3'000U &&
                   config.uplink_guard_ms == 650U &&
                   config.uplink_window_ms == 300U &&
                   config.vehicle_receive_timeout_ms == 2'000U &&
                   config.return_guard_ms == 650U,
               "fixed 3000/650/300/2000/650 TDD profile changed");
  report.check(config.radio_chunk_bytes == 32U &&
                   config.min_tx_gap_ms == 180U &&
                   config.uplink_max_bytes == 64U,
               "fixed E220 chunk/gap/grant contract changed");
  report.check(FixedFirmwareContract::radio_chunk_bytes == 32U &&
                   FixedFirmwareContract::partial_flush_ms == 50U &&
                   FixedFirmwareContract::min_tx_gap_ms == 180U,
               "fixed physical E220 profile changed");
}

void check_latency_counterfactual(TestReport& report) {
  check_fixed_contract(report);
  const TddLatencyResult legacy = model_fixed_tdd(kLegacyControlBytes);
  const TddLatencyResult v2 = model_fixed_tdd(kFullSubpacketBytes);

  report.check(legacy.partial_control,
               "22-byte counterfactual was not treated as a partial packet");
  report.check(legacy.grant_rx_ms > legacy.vehicle_receive_start_ms,
               "22-byte GRANT did not reproduce the delayed grant phase");
  report.check(!in_normal_vehicle_receive(legacy, legacy.idle_rx_ms),
               "22-byte UL_IDLE did not reproduce late terminal delivery");
  report.check(!in_normal_vehicle_receive(legacy, legacy.done_rx_ms),
               "22-byte UL_DONE did not reproduce late terminal delivery");
  report.check(legacy.next_hb_after_idle_ms > kHeartbeatLimitMs &&
                   legacy.next_hb_after_done_ms > kHeartbeatLimitMs,
               "22-byte counterfactual did not reproduce HB gap >2500 ms");
  report.check(legacy.grant_rx_ms - legacy.grant_tx_ms >
                   kFullSubpacketOneWayMs,
               "22-byte counterfactual omitted the partial flush delay");

  report.check(!v2.partial_control,
               "32-byte v2 control was incorrectly modeled as partial");
  report.check(v2.grant_rx_ms - v2.grant_tx_ms ==
                   kFullSubpacketOneWayMs,
               "32-byte control did not receive immediate subpacket delivery");
  report.check(in_normal_vehicle_receive(v2, v2.idle_rx_ms) &&
                   in_normal_vehicle_receive(v2, v2.done_rx_ms),
               "32-byte IDLE/DONE did not arrive in normal receive state");
  report.check(v2.next_hb_after_idle_ms <= kHeartbeatLimitMs &&
                   v2.next_hb_after_done_ms <= kHeartbeatLimitMs,
               "32-byte fixed-TDD model exceeded the 2500 ms HB limit");
  report.check(v2.next_hb_after_idle_ms == 1'644U &&
                   v2.next_hb_after_done_ms == 1'824U,
               "32-byte fixed-TDD timing regression changed unexpectedly");

  // Selecting the production codec size ties this model to the real wire
  // contract. On the old 22-byte implementation this is the intentional RED.
  const TddLatencyResult production =
      model_fixed_tdd(kTddControlFrameSize);
  report.check(production.control_bytes == 32U &&
                   !production.partial_control,
               "production control still selects E220 partial-subpacket mode");
  report.check(in_normal_vehicle_receive(production,
                                         production.done_rx_ms) &&
                   production.next_hb_after_done_ms <= kHeartbeatLimitMs,
               "production control timing misses normal terminal/HB bounds");

  report.stress.heartbeat_gap_before_terminal_ms =
      legacy.next_hb_after_done_ms;
  report.stress.heartbeat_gap_after_terminal_ms =
      v2.next_hb_after_done_ms;
  report.detail =
      "22B: delayed GRANT, late IDLE/DONE, HB(done)=3800 ms; "
      "32B: full subpacket, normal terminal, HB(done)=1824 ms";
}

TddInput input_at(std::uint64_t now_ms) noexcept {
  TddInput input{};
  input.now_ms = now_ms;
  input.aux_high = true;
  input.radio_tx_empty = true;
  input.local_tx_empty = true;
  return input;
}

struct VehicleFixture {
  TddConfig config{};
  LinkDiagnostics diagnostics{};
  VehicleTddController vehicle{config, diagnostics};
  std::uint64_t grant_complete_ms{0U};

  explicit VehicleFixture(TestReport& report) {
    vehicle.reset(kSession, kCycle, 0U);
    (void)vehicle.tick(input_at(0U));
    (void)vehicle.tick(input_at(config.aux_stable_ms));
    (void)vehicle.tick(input_at(config.downlink_send_ms));
    (void)vehicle.tick(input_at(config.downlink_send_ms + 1U));
    const LinkAction grant =
        vehicle.tick(input_at(config.downlink_send_ms + 2U));
    report.check(grant.type == LinkActionType::SendGrant,
                 "Vehicle did not issue UL_GRANT for the subpacket scenario");
    grant_complete_ms = config.downlink_send_ms + 2U;
    if (grant.type == LinkActionType::SendGrant) {
      vehicle.complete_action(grant.token, TxResult::Accepted,
                              grant_complete_ms);
    }
    (void)vehicle.tick(input_at(grant_complete_ms + 1U));
    report.check(vehicle.state() == VehicleTddState::UplinkGuard,
                 "Vehicle did not enter the fixed uplink guard");
  }

  void enter_receive(TestReport& report) {
    (void)vehicle.tick(
        input_at(grant_complete_ms + 1U + config.uplink_guard_ms));
    report.check(vehicle.state() == VehicleTddState::UplinkReceive,
                 "Vehicle did not enter normal UplinkReceive");
  }
};

TddControlMessage terminal(ControlType type,
                           std::uint16_t actual_bytes) noexcept {
  TddControlMessage message{};
  message.type = type;
  message.session_id = kSession;
  message.cycle_id = kCycle;
  message.guard_ms = 0U;
  message.window_ms = 0U;
  message.max_bytes = 64U;
  message.actual_bytes = actual_bytes;
  return message;
}

void check_idle_normal_path(TestReport& report,
                            const TddLatencyResult& timing) {
  VehicleFixture fixture{report};
  fixture.enter_receive(report);
  const std::uint64_t arrival =
      fixture.grant_complete_ms +
      (timing.idle_rx_ms - timing.grant_tx_ms);
  report.check(arrival < fixture.grant_complete_ms +
                             fixture.config.uplink_guard_ms +
                             fixture.config.vehicle_receive_timeout_ms,
               "modeled 32-byte UL_IDLE is not a normal terminal");
  const ControlDisposition disposition =
      fixture.vehicle.on_control(terminal(ControlType::UlIdle, 0U), arrival);
  report.check(disposition == ControlDisposition::Accepted &&
                   fixture.vehicle.state() == VehicleTddState::ReturnGuard &&
                   !fixture.vehicle.late_uplink_recovery_window(),
               "32-byte UL_IDLE did not close through the normal path");
}

void check_msg20_atomic_path(TestReport& report) {
  check_fixed_contract(report);
  const TddLatencyResult timing = model_fixed_tdd(kTddControlFrameSize);
  report.check(kTddControlFrameSize == 32U && !timing.partial_control,
               "msg20 scenario did not select exact 32-byte controls");
  check_idle_normal_path(report, timing);

  VehicleFixture fixture{report};
  fixture.enter_receive(report);
  VehicleLateUplinkRecovery recovery{};
  recovery.begin(kSession, kCycle);
  TddLinkDemux demux{true};
  MavlinkValidatedLocalEgressAdapter<> d6{};

  const MavlinkFrame request =
      fixtures::param_request_read_v2(0x51U, "ARMING_CHECK");
  report.check(request.message_id == 20U && request.size == 32U,
               "atomic D6 fixture is not the exact 32-byte msg20");
  const EncodedLinkDataChunk encoded =
      encode_link_data(request.bytes.data(), request.size);
  report.check(encoded.input_consumed == request.size &&
                   encoded.wire_size == 32U,
               "msg20 no longer fits one exact E220 data subpacket");

  // Exercise the production Ground controller, not a hand-authored terminal.
  // A complete exact-32 #20 is one data subpacket, but protocol v2 still
  // requires one explicit exact-32 UL_DONE before Vehicle may commit it.
  LinkDiagnostics ground_diagnostics{};
  GroundTddController ground{fixture.config, ground_diagnostics};
  ground.reset(0U);
  TddControlMessage grant{};
  grant.type = ControlType::UlGrant;
  grant.session_id = kSession;
  grant.cycle_id = kCycle;
  grant.guard_ms =
      static_cast<std::uint16_t>(fixture.config.uplink_guard_ms);
  grant.window_ms =
      static_cast<std::uint16_t>(fixture.config.uplink_window_ms);
  grant.max_bytes = fixture.config.uplink_max_bytes;
  report.check(ground.on_control(grant, 0U) ==
                   ControlDisposition::Accepted,
               "Ground rejected the exact-32 msg20 UL_GRANT");

  TddInput ground_input = input_at(0U);
  ground_input.queued_bytes = static_cast<std::uint32_t>(request.size);
  ground_input.next_tx_application_bytes =
      static_cast<std::uint16_t>(request.size);
  ground_input.next_tx_wire_bytes =
      static_cast<std::uint16_t>(encoded.wire_size);
  (void)ground.tick(ground_input);
  ground_input.now_ms = fixture.config.uplink_guard_ms;
  (void)ground.tick(ground_input);
  ground_input.now_ms = fixture.config.uplink_guard_ms + 1U;
  const LinkAction data_action = ground.tick(ground_input);
  report.check(data_action.type == LinkActionType::SendRadioData &&
                   data_action.byte_budget == request.size,
               "Ground did not issue one exact-32 msg20 data action");
  if (data_action.type == LinkActionType::SendRadioData) {
    ground.complete_action(data_action.token, TxResult::Accepted,
                           ground_input.now_ms,
                           static_cast<std::uint16_t>(request.size));
  }

  ground_input.queued_bytes = 0U;
  ground_input.next_tx_application_bytes = 0U;
  ground_input.next_tx_wire_bytes = 0U;
  ground_input.now_ms += fixture.config.min_tx_gap_ms;
  (void)ground.tick(ground_input);
  std::size_t issued_done = 0U;
  LinkAction production_done{};
  for (std::uint64_t step = 1U; step <= 4U; ++step) {
    ground_input.now_ms += step;
    const LinkAction action = ground.tick(ground_input);
    if (action.type != LinkActionType::SendDone) {
      continue;
    }
    ++issued_done;
    production_done = action;
    ground.complete_action(action.token, TxResult::Accepted,
                           ground_input.now_ms);
  }
  ground_input.now_ms += fixture.config.min_tx_gap_ms;
  const LinkAction duplicate_done = ground.tick(ground_input);
  report.check(kTddProtocolVersion == 2U && issued_done == 1U &&
                   production_done.control.type == ControlType::UlDone &&
                   production_done.control.actual_bytes == request.size &&
                   duplicate_done.type != LinkActionType::SendDone &&
                   ground_diagnostics.done_tx == 1U,
               "exact-32 msg20 was not followed by exactly one explicit "
               "protocol-v2 UL_DONE");

  const std::uint64_t data_arrival =
      fixture.grant_complete_ms +
      (timing.data_rx_ms - timing.grant_tx_ms);
  report.check(fixture.vehicle.state() ==
                   VehicleTddState::UplinkReceive &&
                   data_arrival < fixture.grant_complete_ms +
                                      fixture.config.uplink_guard_ms +
                                      fixture.config.vehicle_receive_timeout_ms,
               "32-byte msg20 did not arrive in normal UplinkReceive");
  std::size_t local_bytes = 0U;
  std::size_t unexpected_controls = 0U;
  for (std::size_t index = 0U; index < encoded.wire_size; ++index) {
    const TddDemuxEvent event = demux.push(encoded.wire_bytes[index]);
    unexpected_controls += event.has_control ? 1U : 0U;
    for (std::size_t local = 0U; local < event.local_size; ++local) {
      ++local_bytes;
      (void)recovery.ingest(event.local_bytes[local]);
    }
  }
  report.check(local_bytes == request.size && unexpected_controls == 0U,
               "msg20 data was changed or misclassified by the demux");
  report.check(recovery.buffered_bytes() == request.size &&
                   recovery.frame_count() == 1U,
               "complete msg20 was not held as one quarantined frame");
  report.check(d6.egress().queued_bytes() == 0U,
               "partial msg20 reached D6 before matching UL_DONE");

  const TddControlMessage done = terminal(
      ControlType::UlDone, static_cast<std::uint16_t>(request.size));
  std::array<std::uint8_t, kTddControlFrameSize> done_wire{};
  std::size_t done_wire_size = 0U;
  report.check(encode_control(done, done_wire.data(), done_wire.size(),
                              done_wire_size) &&
                   done_wire_size == 32U,
               "UL_DONE was not one exact full E220 subpacket");

  const std::uint64_t done_arrival =
      fixture.grant_complete_ms +
      (timing.done_rx_ms - timing.grant_tx_ms);
  report.check(in_normal_vehicle_receive(timing, timing.done_rx_ms) &&
                   fixture.vehicle.state() ==
                       VehicleTddState::UplinkReceive,
               "UL_DONE reached a late-recovery state instead of normal RX");
  std::size_t terminal_events = 0U;
  for (const std::uint8_t byte : done_wire) {
    const TddDemuxEvent event = demux.push(byte);
    report.check(event.local_size == 0U,
                 "UL_DONE padding leaked into the msg20 transaction");
    if (!event.has_control) {
      continue;
    }
    ++terminal_events;
    report.check(event.control.status == DecodeStatus::Message,
                 "UL_DONE failed decode after full-subpacket delivery");
    if (event.control.status != DecodeStatus::Message) {
      continue;
    }
    report.check(recovery.on_terminal(event.control.message) ==
                     LateUplinkTerminalStatus::Ready,
                 "matching normal UL_DONE did not authorize msg20 commit");
    report.check(fixture.vehicle.on_control(event.control.message,
                                            done_arrival) ==
                     ControlDisposition::Accepted,
                 "Vehicle did not accept normal same-cycle UL_DONE");
  }
  report.check(terminal_events == 1U,
               "UL_DONE was not consumed as one 32-byte control");

  std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes> committed{};
  std::size_t committed_size = 0U;
  std::uint16_t committed_frames = 0U;
  report.check(recovery.take_commit(committed.data(), committed.size(),
                                    committed_size, committed_frames),
               "authorized msg20 transaction could not be committed");
  report.check(committed_size == request.size && committed_frames == 1U &&
                   std::memcmp(committed.data(), request.bytes.data(),
                               request.size) == 0,
               "authorized msg20 commit was partial, duplicate, or changed");
  report.check(d6.egress().ingest(committed.data(), committed_size) ==
                   committed_size,
               "exact msg20 was not atomically admitted to D6");

  std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> d6_bytes{};
  const std::size_t d6_size =
      d6.egress().peek(d6_bytes.data(), d6_bytes.size());
  report.check(d6_size == request.size &&
                   std::memcmp(d6_bytes.data(), request.bytes.data(),
                               request.size) == 0,
               "D6 did not expose exactly one complete msg20");
  std::size_t duplicate_size = 99U;
  std::uint16_t duplicate_frames = 99U;
  report.check(!recovery.take_commit(committed.data(), committed.size(),
                                     duplicate_size, duplicate_frames) &&
                   duplicate_size == 0U && duplicate_frames == 0U,
               "msg20 transaction could be committed more than once");
  report.check(fixture.vehicle.state() == VehicleTddState::ReturnGuard &&
                   !fixture.vehicle.late_uplink_recovery_window(),
               "normal UL_DONE did not enter closed ReturnGuard");
  report.check(done_arrival + fixture.config.return_guard_ms -
                       (fixture.grant_complete_ms -
                        fixture.config.min_tx_gap_ms) <=
                   kHeartbeatLimitMs,
               "atomic msg20 path violates HB <=2500 ms");

  report.diagnostics = fixture.diagnostics;
  report.diagnostics.control_bytes_leaked_to_local_uart = 0U;
  report.diagnostics.param_requests_rx = 1U;
  report.diagnostics.mavlink_frames_forwarded = 1U;
  report.detail =
      "32B GRANT/DONE full-subpacket path: normal terminal, one atomic "
      "32-byte msg20 at D6, next HB within 1824 ms";
}

void check_synchronized_heartbeat_slot(TestReport& report) {
  const TddConfig config{};
  report.check(kTddProtocolVersion == 2U,
               "heartbeat-slot protocol is not explicit-DONE v2");

  std::array<std::uint8_t, 2U> request_payload{{1U, 1U}};
  MavlinkFrame request{};
  report.check(encode_mavlink_v2(0x63U, 255U, 190U, 21U,
                                 request_payload.data(),
                                 request_payload.size(), request),
               "could not encode heartbeat-slot msg21 fixture");
  report.check(request.message_id == 21U && request.size == 14U,
               "heartbeat-slot fixture is not the exact msg21 request");
  const EncodedLinkDataChunk encoded =
      encode_link_data(request.bytes.data(), request.size);
  report.check(encoded.input_consumed == request.size &&
                   encoded.wire_size == config.radio_chunk_bytes,
               "short uplink frame was not padded to one exact subpacket");

  TddLinkDemux demux{true};
  std::array<std::uint8_t, kMavlinkMaxFrameBytes> decoded{};
  std::size_t decoded_size = 0U;
  std::size_t control_events = 0U;
  for (std::size_t index = 0U; index < encoded.wire_size; ++index) {
    const TddDemuxEvent event = demux.push(encoded.wire_bytes[index]);
    control_events += event.has_control ? 1U : 0U;
    for (std::size_t local = 0U; local < event.local_size; ++local) {
      if (decoded_size < decoded.size()) {
        decoded[decoded_size++] = event.local_bytes[local];
      }
    }
  }
  report.check(control_events == 0U && decoded_size == request.size &&
                   std::memcmp(decoded.data(), request.bytes.data(),
                               request.size) == 0,
               "exact-subpacket padding leaked into MAVLink application data");

  // Protocol v2 holds the complete frame until one explicit UL_DONE arrives.
  // The first safe downlink heartbeat slot is one return guard after that
  // exact-32 terminal subpacket.
  constexpr std::uint64_t kPreviousHeartbeatMs = 0U;
  const std::uint64_t grant_tx_ms = config.min_tx_gap_ms;
  const std::uint64_t grant_rx_ms =
      grant_tx_ms + kFullSubpacketOneWayMs;
  const std::uint64_t data_tx_ms = grant_rx_ms + config.uplink_guard_ms;
  const std::uint64_t data_rx_ms =
      data_tx_ms + kFullSubpacketOneWayMs;
  const std::uint64_t done_tx_ms =
      data_tx_ms + config.min_tx_gap_ms;
  const std::uint64_t done_rx_ms =
      done_tx_ms + kFullSubpacketOneWayMs;
  const std::uint64_t heartbeat_slot_ms =
      done_rx_ms + config.return_guard_ms;
  report.check(done_rx_ms > data_rx_ms,
               "explicit UL_DONE was not modeled after the data subpacket");
  report.check(heartbeat_slot_ms - kPreviousHeartbeatMs <=
                   kHeartbeatLimitMs,
               "synchronized return heartbeat slot exceeds 2500 ms");
  report.check(heartbeat_slot_ms == 1'824U,
               "synchronized heartbeat-slot timing changed unexpectedly");
  report.detail =
      "v2 exact32 msg21: explicit UL_DONE terminal, synchronized return "
      "heartbeat slot at 1824 ms";
}

}  // namespace

TestReport run_control_subpacket_test(const std::string& test_id,
                                      std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "IT-CONTROL-SUBPACKET-TIMING-001") {
    check_latency_counterfactual(report);
  } else if (test_id == "IT-CONTROL-SUBPACKET-MSG20-001") {
    check_msg20_atomic_path(report);
  } else if (test_id == "IT-CONTROL-SUBPACKET-HB-SLOT-001") {
    check_synchronized_heartbeat_slot(report);
  } else {
    report.check(false, "unknown control-subpacket integration test ID");
  }

  report.trace.record({0U, "host", "CONTROL_SUBPACKET", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
