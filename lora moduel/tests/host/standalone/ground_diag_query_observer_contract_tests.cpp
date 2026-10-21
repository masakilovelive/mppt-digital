#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_PHASE6_GROUND_DIAGNOSTICS 1

#include "vc_lora_ground_diag_observer.hpp"

#include <array>
#include <cstdint>
#include <cstdio>

namespace {

using namespace vc_lora;
using namespace vc_lora_ground_diag_observer;

bool check(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    return false;
  }
  return true;
}

void reset_observer() {
  stats = {};
  usb_parser = {};
  query_candidate = {};
  query_candidate_size = 0U;
  query_candidate_started_ms = 0U;
  fail_closed_query_candidate_size = 0U;
  query_request_pending = false;
  usb_report_active = false;
  usb_connection_initialized = false;
  usb_host_presence_initialized = false;
  serial1_baud_commit_goals = {};
  serial1_baud_commit_goal_head = 0U;
  serial1_baud_commit_goal_count = 0U;
  armed_runtime_stop_reason = GroundRuntimeStopReason::Unclassified;
  armed_downlink_disposition =
      GroundDownlinkDisposition::EndpointDropped;
  control_before = {};
}

void route_normal_byte(std::uint8_t byte, std::uint64_t now_ms) {
  const UsbRouteResult routed = route_usb_byte(byte, now_ms);
  if (!routed.consumed) {
    observe_usb_byte(byte, now_ms);
    return;
  }
  for (std::size_t index = 0U; index < routed.replay_size; ++index) {
    observe_usb_byte(routed.replay[index], now_ms);
  }
}

MavlinkFrame make_request_list() {
  constexpr std::array<std::uint8_t, 2U> payload{{1U, 1U}};
  MavlinkFrame frame{};
  if (!encode_mavlink_v2(0x31U, 255U, 190U, 21U, payload.data(),
                         payload.size(), frame)) {
    std::fprintf(stderr, "FAIL: could not encode #21 fixture\n");
  }
  return frame;
}

MavlinkFrame make_heartbeat(std::uint8_t sequence,
                            std::uint8_t system_id = 1U,
                            std::uint8_t component_id = 1U) {
  constexpr std::array<std::uint8_t, 9U> payload{};
  MavlinkFrame frame{};
  if (!encode_mavlink_v2(sequence, system_id, component_id, 0U,
                         payload.data(), payload.size(), frame)) {
    std::fprintf(stderr, "FAIL: could not encode heartbeat fixture\n");
  }
  return frame;
}

MavlinkFrame make_request_read() {
  std::array<std::uint8_t, 20U> payload{};
  payload[0U] = 0xFFU;
  payload[1U] = 0xFFU;
  payload[2U] = 1U;
  payload[3U] = 1U;
  constexpr char kParam[] = "SERIAL1_BAUD";
  for (std::size_t index = 0U; index < sizeof(kParam) - 1U; ++index) {
    payload[4U + index] = static_cast<std::uint8_t>(kParam[index]);
  }
  MavlinkFrame frame{};
  if (!encode_mavlink_v2(0x32U, 255U, 190U, 20U, payload.data(),
                         payload.size(), frame)) {
    std::fprintf(stderr, "FAIL: could not encode #20 fixture\n");
  }
  return frame;
}

MavlinkFrame make_serial1_baud_value(
    std::uint32_t value_bits = 0x42640000U,
    std::uint8_t system_id = 1U, std::uint8_t component_id = 1U,
    std::uint8_t sequence = 0x33U) {
  std::array<std::uint8_t, 25U> payload{};
  payload[0U] = static_cast<std::uint8_t>(value_bits & 0xFFU);
  payload[1U] = static_cast<std::uint8_t>((value_bits >> 8U) & 0xFFU);
  payload[2U] = static_cast<std::uint8_t>((value_bits >> 16U) & 0xFFU);
  payload[3U] = static_cast<std::uint8_t>((value_bits >> 24U) & 0xFFU);
  payload[4U] = 0x34U;
  payload[5U] = 0x12U;
  payload[6U] = 0xFFU;
  payload[7U] = 0xFFU;
  constexpr char kParam[] = "SERIAL1_BAUD";
  for (std::size_t index = 0U; index < sizeof(kParam) - 1U; ++index) {
    payload[8U + index] = static_cast<std::uint8_t>(kParam[index]);
  }
  payload[24U] = 6U;
  MavlinkFrame frame{};
  if (!encode_mavlink_v2(sequence, system_id, component_id, 22U, payload.data(),
                          payload.size(), frame)) {
    std::fprintf(stderr, "FAIL: could not encode SERIAL1_BAUD #22 fixture\n");
  }
  return frame;
}

MavlinkFrame make_stat_runtime_value() {
  std::array<std::uint8_t, 25U> payload{};
  payload[0U] = 0x00U;
  payload[1U] = 0x00U;
  payload[2U] = 0x64U;
  payload[3U] = 0x42U;  // all target fields match except the exact ID
  payload[4U] = 0x34U;
  payload[5U] = 0x12U;
  payload[6U] = 0xFFU;
  payload[7U] = 0xFFU;
  constexpr char kParam[] = "STAT_RUNTIME";
  for (std::size_t index = 0U; index < sizeof(kParam) - 1U; ++index) {
    payload[8U + index] = static_cast<std::uint8_t>(kParam[index]);
  }
  payload[24U] = 6U;
  MavlinkFrame frame{};
  if (!encode_mavlink_v2(0x34U, 1U, 1U, 22U, payload.data(),
                         payload.size(), frame)) {
    std::fprintf(stderr, "FAIL: could not encode STAT_RUNTIME #22 fixture\n");
  }
  return frame;
}

bool same_serial1_chain(const ObserverStats& left,
                        const ObserverStats& right) {
  return left.rf_serial1_baud_exact == right.rf_serial1_baud_exact &&
         left.rf_serial1_baud_expected == right.rf_serial1_baud_expected &&
         left.rf_serial1_endpoint_queued ==
             right.rf_serial1_endpoint_queued &&
         left.rf_serial1_disconnected_rejected ==
             right.rf_serial1_disconnected_rejected &&
         left.rf_serial1_endpoint_dropped ==
             right.rf_serial1_endpoint_dropped &&
         left.rf_serial1_backlog_queued ==
             right.rf_serial1_backlog_queued &&
         left.rf_serial1_proxy_consumed ==
             right.rf_serial1_proxy_consumed &&
         left.rf_serial1_invalid == right.rf_serial1_invalid &&
         left.rf_serial1_egress_goals_armed ==
             right.rf_serial1_egress_goals_armed &&
         left.rf_serial1_egress_committed ==
             right.rf_serial1_egress_committed &&
         left.rf_serial1_egress_goal_overflow ==
             right.rf_serial1_egress_goal_overflow &&
         left.rf_serial1_last_commit_goal ==
             right.rf_serial1_last_commit_goal &&
         left.rf_serial1_last_committed_bytes ==
             right.rf_serial1_last_committed_bytes &&
         left.rf_serial1_last_ms == right.rf_serial1_last_ms &&
         left.rf_serial1_last_value_bits ==
             right.rf_serial1_last_value_bits &&
         left.rf_serial1_last_count == right.rf_serial1_last_count &&
         left.rf_serial1_last_index == right.rf_serial1_last_index &&
         left.rf_serial1_last_type == right.rf_serial1_last_type &&
         left.rf_serial1_last_sequence == right.rf_serial1_last_sequence &&
         left.rf_serial1_last_system_id ==
             right.rf_serial1_last_system_id &&
         left.rf_serial1_last_component_id ==
             right.rf_serial1_last_component_id &&
         left.rf_serial1_egress_pending == right.rf_serial1_egress_pending;
}

void exercise_negative_target_chain(const MavlinkFrame& frame,
                                    std::uint64_t now_ms,
                                    std::uint64_t false_commit_goal) {
  observe_ground_validated_frame(frame, now_ms);
  observe_ground_downlink(
      frame, GroundDownlinkDisposition::BacklogQueued, now_ms + 1U);
  observe_ground_downlink(
      frame, GroundDownlinkDisposition::EndpointQueued, now_ms + 2U);
  observe_ground_downlink(
      frame, GroundDownlinkDisposition::DisconnectedRejected, now_ms + 3U);
  observe_ground_downlink(
      frame, GroundDownlinkDisposition::EndpointDropped, now_ms + 4U);
  observe_ground_downlink(
      frame, GroundDownlinkDisposition::ProxyConsumed, now_ms + 5U);
  observe_ground_downlink(
      frame, GroundDownlinkDisposition::Invalid, now_ms + 6U);
  observe_target_egress_admission(frame, false_commit_goal);
  observe_usb_egress_pump(LocalEgressPumpStatus::Progress,
                          8U, 0U, false_commit_goal - 8U,
                          false_commit_goal, GroundTddState::WaitGrant,
                          11U, now_ms + 7U);
}

}  // namespace

int main() {
  bool passed = true;
  const MavlinkFrame request_list = make_request_list();
  const MavlinkFrame request_read = make_request_read();
  const MavlinkFrame serial1_baud_value = make_serial1_baud_value();
  const MavlinkFrame stat_runtime_value = make_stat_runtime_value();
  const MavlinkFrame serial1_wrong_source =
      make_serial1_baud_value(0x42640000U, 2U, 1U, 0x35U);
  const MavlinkFrame serial1_wrong_value =
      make_serial1_baud_value(0x42680000U, 1U, 1U, 0x36U);
  passed &= check(request_list.size > 0U, "empty #21 fixture");
  passed &= check(request_read.size > 0U, "empty #20 fixture");
  passed &= check(serial1_baud_value.size > 0U,
                  "empty SERIAL1_BAUD #22 fixture");
  passed &= check(stat_runtime_value.size > 0U,
                   "empty STAT_RUNTIME #22 fixture");
  passed &= check(serial1_wrong_source.size > 0U &&
                      serial1_wrong_value.size > 0U,
                  "empty strict-predicate negative #22 fixture");

  reset_observer();
  observe_ground_ordered_backlog_enqueued(make_heartbeat(1U));
  observe_ground_ordered_backlog_enqueued(make_heartbeat(2U));
  passed &= check(stats.ordered_backlog_param_value_frames == 0U,
                  "held heartbeats were misclassified as queued #22");
  observe_ground_ordered_backlog_enqueued(serial1_baud_value);
  passed &= check(stats.ordered_backlog_param_value_frames == 1U,
                  "queued #22 did not arm instantaneous backlog occupancy");
  observe_ground_ordered_backlog_removed(make_heartbeat(1U));
  passed &= check(stats.ordered_backlog_param_value_frames == 1U,
                  "removing a heartbeat changed queued #22 occupancy");
  observe_ground_ordered_backlog_removed(serial1_baud_value);
  passed &= check(stats.ordered_backlog_param_value_frames == 0U,
                  "releasing a #22 did not clear backlog occupancy");
  observe_ground_ordered_backlog_enqueued(serial1_baud_value);
  observe_ground_ordered_backlog_enqueued(stat_runtime_value);
  observe_ground_ordered_backlog_cleared();
  passed &= check(stats.ordered_backlog_param_value_frames == 0U,
                  "whole-backlog discard retained stale #22 occupancy");

  reset_observer();
  GroundHeartbeatRuntimeContext disconnected_rf_context{};
  disconnected_rf_context.usb_writer_available = 0U;
  disconnected_rf_context.usb_write_pending = 0U;
  disconnected_rf_context.state =
      static_cast<std::uint8_t>(GroundTddState::WaitGrant);
  const MavlinkFrame disconnected_heartbeat_1 = make_heartbeat(70U);
  const MavlinkFrame disconnected_heartbeat_2 = make_heartbeat(71U);
  observe_ground_validated_frame(disconnected_heartbeat_1, 1000U);
  observe_ground_primary_heartbeat_rf(
      disconnected_heartbeat_1, disconnected_rf_context, 1000U);
  observe_ground_downlink(
      disconnected_heartbeat_1,
      GroundDownlinkDisposition::DisconnectedRejected, 1000U);
  observe_ground_validated_frame(disconnected_heartbeat_2, 4001U);
  observe_ground_primary_heartbeat_rf(
      disconnected_heartbeat_2, disconnected_rf_context, 4001U);
  observe_ground_downlink(
      disconnected_heartbeat_2,
      GroundDownlinkDisposition::DisconnectedRejected, 4001U);
  passed &= check(
      stats.rf_frames_valid == 2U && stats.rf_msg0 == 2U &&
          stats.rf_downlink_disconnected_rejected == 2U &&
          stats.rf_primary_heartbeat_gap.events == 2U &&
          stats.rf_primary_heartbeat_gap.gap_observations == 1U &&
          stats.rf_primary_heartbeat_gap.gap_violation_count == 1U &&
          stats.rf_primary_heartbeat_gap.latest_violation.gap_ms == 3001U &&
          stats.usb_primary_heartbeat_gap.events == 0U,
      "USB-disconnected RF heartbeat supply was not latched independently");

  reset_observer();
  for (std::size_t index = 0U; index < request_list.size; ++index) {
    route_normal_byte(request_list.bytes[index], 100U + index);
  }
  passed &= check(stats.usb_frames_valid == 1U && stats.usb_msg21 == 1U,
                  "ordinary CRC-valid #21 was not observed exactly once");
  passed &= check(!query_request_pending && !usb_report_active,
                  "ordinary MAVLink armed a diagnostic report");

  for (std::size_t index = 0U; index < kQuerySize; ++index) {
    const UsbRouteResult routed = route_usb_byte(
        static_cast<std::uint8_t>(kQuery[index]), 1000U + index);
    passed &= check(routed.consumed && routed.replay_size == 0U,
                    "exact query byte leaked to MAVLink ingress");
  }
  passed &= check(query_request_pending && !usb_report_active &&
                      stats.query_completed == 1U &&
                      stats.usb_frames_valid == 1U,
                  "exact boundary query did not arm one isolated report");
  passed &= check(take_query_request() && !take_query_request(),
                  "query request was not one-shot");

  reset_observer();
  route_normal_byte(static_cast<std::uint8_t>('V'), 2000U);
  route_normal_byte(static_cast<std::uint8_t>('C'), 2001U);
  route_normal_byte(static_cast<std::uint8_t>('X'), 2002U);
  passed &= check(stats.query_prefix_mismatch == 1U &&
                      stats.usb_normal_bytes == 3U,
                  "query prefix mismatch did not replay every byte");
  for (std::size_t index = 0U; index < request_list.size; ++index) {
    route_normal_byte(request_list.bytes[index], 2100U + index);
  }
  passed &= check(stats.usb_frames_valid == 1U && stats.usb_msg21 == 1U,
                  "prefix replay poisoned the following MAVLink #21");

  reset_observer();
  route_normal_byte(request_list.bytes[0U], 3000U);
  const UsbRouteResult embedded_v =
      route_usb_byte(static_cast<std::uint8_t>('V'), 3001U);
  passed &= check(!embedded_v.consumed && !query_request_pending,
                  "query interception activated inside a MAVLink frame");

  reset_observer();
  observe_usb_connection(false, GroundTddState::WaitGrant, 10U, 4000U);
  observe_usb_connection(false, GroundTddState::WaitGrant, 10U, 4001U);
  observe_usb_connection(true, GroundTddState::UplinkGuard, 10U, 4002U);
  observe_usb_connection(true, GroundTddState::UplinkGuard, 10U, 4003U);
  observe_usb_connection(false, GroundTddState::WaitGrant, 11U, 4004U);
  passed &= check(stats.usb_predicate_samples == 5U &&
                      stats.usb_predicate_transitions == 2U &&
                      stats.usb_predicate_connected_transitions == 1U &&
                      stats.usb_predicate_disconnected_transitions == 1U &&
                      stats.usb_predicate_value == 0U &&
                      stats.usb_predicate_last_transition_ms == 4004U,
                   "sticky HWCDC predicate transitions were not observed");

  observe_usb_host_presence(true, GroundTddState::WaitGrant, 11U, 4010U);
  observe_usb_host_presence(true, GroundTddState::WaitGrant, 11U, 4011U);
  observe_usb_host_presence(false, GroundTddState::DoneDrain, 11U, 4012U);
  observe_usb_host_presence(true, GroundTddState::WaitGrant, 12U, 4013U);
  passed &= check(stats.usb_host_presence_samples == 4U &&
                      stats.usb_host_presence_transitions == 2U &&
                      stats.usb_host_present_transitions == 1U &&
                      stats.usb_host_absent_transitions == 1U &&
                      stats.usb_host_presence_value == 1U &&
                      stats.usb_host_presence_last_transition_ms == 4013U,
                  "USB SOF host-presence transitions were not observed "
                  "independently from HWCDC endpoint readiness");

  observe_usb_egress_pump(LocalEgressPumpStatus::Disconnected,
                          32U, 32U, 100U, 100U,
                          GroundTddState::WaitGrant, 11U, 4100U);
  observe_usb_egress_pump(LocalEgressPumpStatus::WriterUnavailable,
                          32U, 32U, 100U, 100U,
                          GroundTddState::WaitGrant, 11U, 4101U);
  observe_usb_egress_pump(LocalEgressPumpStatus::Progress,
                          32U, 0U, 100U, 132U,
                          GroundTddState::WaitGrant, 11U, 4102U);
  passed &= check(stats.usb_pump_calls == 3U &&
                      stats.usb_pump_disconnected == 1U &&
                      stats.usb_pump_writer_unavailable == 1U &&
                      stats.usb_pump_progress == 1U &&
                      stats.usb_egress_last_queued_before == 32U &&
                      stats.usb_egress_last_queued_after == 0U &&
                      stats.usb_egress_last_committed_before == 100U &&
                      stats.usb_egress_last_committed_after == 132U,
                  "USB egress queued/committed progress was not observed");

  observe_ground_validated_frame(request_read, 4200U);
  observe_ground_downlink(
      request_read, GroundDownlinkDisposition::DisconnectedRejected,
      4201U);
  observe_ground_validated_frame(request_list, 4202U);
  observe_ground_downlink(
      request_list, GroundDownlinkDisposition::EndpointQueued, 4203U);
  passed &= check(stats.rf_frames_valid == 2U &&
                      stats.rf_msg20 == 1U &&
                      stats.rf_downlink_disconnected_rejected == 1U &&
                      stats.rf_downlink_queued == 1U,
                  "RF validation/downlink disposition stages were not observed");

  GroundHeartbeatRuntimeContext rf_context{};
  rf_context.state = static_cast<std::uint8_t>(GroundTddState::WaitGrant);
  rf_context.cycle = 21U;
  rf_context.aux = 1U;
  rf_context.radio_busy = 0U;
  rf_context.pending_action = 0U;
  rf_context.pacer_queued = 1U;
  rf_context.pacer_pending = 0U;
  rf_context.pacer_admitted = 0U;
  rf_context.ordered_backlog_frames = 4U;
  rf_context.ordered_backlog_bytes = 128U;
  rf_context.usb_queued_bytes = 32U;
  rf_context.usb_write_pending = 0U;
  rf_context.usb_writer_available = 1U;
  observe_ground_primary_heartbeat_rf(make_heartbeat(250U), rf_context,
                                      5000U);
  rf_context.cycle = 22U;
  rf_context.radio_busy = 1U;
  rf_context.pending_action = 1U;
  rf_context.pacer_queued = 2U;
  rf_context.usb_queued_bytes = 96U;
  observe_ground_primary_heartbeat_rf(make_heartbeat(251U), rf_context,
                                      6200U);
  rf_context.cycle = 23U;
  rf_context.state = static_cast<std::uint8_t>(GroundTddState::UplinkGuard);
  rf_context.aux = 0U;
  rf_context.pacer_pending = 1U;
  rf_context.ordered_backlog_frames = 9U;
  rf_context.ordered_backlog_bytes = 189U;
  rf_context.usb_write_pending = 1U;
  rf_context.usb_writer_available = 0U;
  observe_ground_primary_heartbeat_rf(make_heartbeat(252U), rf_context,
                                      9000U);
  observe_ground_primary_heartbeat_rf(make_heartbeat(9U, 2U, 1U),
                                      rf_context, 12000U);
  const auto& rf_gap = stats.rf_primary_heartbeat_gap;
  passed &= check(
      rf_gap.events == 3U && rf_gap.gap_observations == 2U &&
          rf_gap.gap_violation_count == 1U &&
          rf_gap.last_sequence == 252U && rf_gap.last_ms == 9000U &&
          rf_gap.latest.gap_ms == 2800U &&
          rf_gap.latest.event_ms == 9000U &&
          rf_gap.maximum.gap_ms == 2800U &&
          rf_gap.maximum.event_ms == 9000U &&
          rf_gap.maximum.previous_sequence == 251U &&
          rf_gap.maximum.sequence == 252U &&
          rf_gap.maximum.context.cycle == 23U &&
          rf_gap.maximum.context.state ==
              static_cast<std::uint8_t>(GroundTddState::UplinkGuard) &&
          rf_gap.maximum.context.aux == 0U &&
          rf_gap.maximum.context.radio_busy == 1U &&
          rf_gap.maximum.context.pending_action == 1U &&
          rf_gap.maximum.context.pacer_queued == 2U &&
          rf_gap.maximum.context.pacer_pending == 1U &&
          rf_gap.maximum.context.ordered_backlog_frames == 9U &&
          rf_gap.maximum.context.ordered_backlog_bytes == 189U &&
          rf_gap.maximum.context.usb_queued_bytes == 96U &&
          rf_gap.maximum.context.usb_write_pending == 1U &&
          rf_gap.maximum.context.usb_writer_available == 0U &&
          rf_gap.latest_violation.gap_ms == 2800U &&
          rf_gap.latest_violation.event_ms == 9000U &&
          rf_gap.latest_violation.context.ordered_backlog_frames == 9U &&
          rf_gap.latest_violation.context.ordered_backlog_bytes == 189U,
      "RF primary-heartbeat maximum-gap context was not retained");

  GroundHeartbeatRuntimeContext usb_context = rf_context;
  usb_context.state = static_cast<std::uint8_t>(GroundTddState::WaitGrant);
  usb_context.cycle = 30U;
  usb_context.aux = 1U;
  usb_context.radio_busy = 0U;
  usb_context.pending_action = 0U;
  usb_context.pacer_queued = 1U;
  usb_context.pacer_pending = 0U;
  usb_context.pacer_admitted = 1U;
  usb_context.ordered_backlog_frames = 1U;
  usb_context.ordered_backlog_bytes = 21U;
  usb_context.usb_queued_bytes = 21U;
  usb_context.usb_write_pending = 1U;
  usb_context.usb_writer_available = 1U;
  observe_ground_primary_heartbeat_usb_commit(40U, usb_context, 10000U);
  usb_context.cycle = 31U;
  usb_context.usb_queued_bytes = 0U;
  usb_context.usb_write_pending = 0U;
  observe_ground_primary_heartbeat_usb_commit(41U, usb_context, 12500U);
  usb_context.cycle = 32U;
  usb_context.ordered_backlog_frames = 9U;
  usb_context.ordered_backlog_bytes = 189U;
  observe_ground_primary_heartbeat_usb_commit(42U, usb_context, 15501U);
  usb_context.cycle = 33U;
  usb_context.ordered_backlog_frames = 0U;
  usb_context.ordered_backlog_bytes = 0U;
  observe_ground_primary_heartbeat_usb_commit(43U, usb_context, 17000U);
  const auto& usb_gap = stats.usb_primary_heartbeat_gap;
  passed &= check(
      usb_gap.events == 4U && usb_gap.gap_observations == 3U &&
          usb_gap.gap_violation_count == 1U &&
          usb_gap.last_sequence == 43U && usb_gap.last_ms == 17000U &&
          usb_gap.latest.gap_ms == 1499U &&
          usb_gap.maximum.gap_ms == 3001U &&
          usb_gap.maximum.event_ms == 15501U &&
          usb_gap.maximum.previous_sequence == 41U &&
          usb_gap.maximum.sequence == 42U &&
          usb_gap.maximum.context.cycle == 32U &&
          usb_gap.maximum.context.pacer_admitted == 1U &&
          usb_gap.maximum.context.ordered_backlog_frames == 9U &&
          usb_gap.maximum.context.ordered_backlog_bytes == 189U &&
          usb_gap.latest_violation.gap_ms == 3001U &&
          usb_gap.latest_violation.event_ms == 15501U &&
          usb_gap.latest_violation.context.ordered_backlog_frames == 9U &&
          usb_gap.latest_violation.context.ordered_backlog_bytes == 189U,
      "USB physical-commit maximum-gap context was not retained");

  observe_ground_validated_frame(serial1_baud_value, 4210U);
  observe_ground_downlink(
      serial1_baud_value, GroundDownlinkDisposition::BacklogQueued, 4211U);
  observe_ground_downlink(
      serial1_baud_value, GroundDownlinkDisposition::EndpointQueued, 4212U);
  observe_ground_downlink(
      serial1_baud_value,
      GroundDownlinkDisposition::DisconnectedRejected, 4212U);
  observe_ground_downlink(
      serial1_baud_value, GroundDownlinkDisposition::EndpointDropped, 4212U);
  observe_ground_downlink(
      serial1_baud_value, GroundDownlinkDisposition::ProxyConsumed, 4212U);
  observe_ground_downlink(
      serial1_baud_value, GroundDownlinkDisposition::Invalid, 4212U);
  observe_target_egress_admission(serial1_baud_value, 500U);
  observe_usb_egress_pump(LocalEgressPumpStatus::Progress,
                          16U, 8U, 480U, 492U,
                          GroundTddState::WaitGrant, 11U, 4213U);
  observe_usb_egress_pump(LocalEgressPumpStatus::Progress,
                           8U, 0U, 492U, 500U,
                           GroundTddState::WaitGrant, 11U, 4214U);
  const ObserverStats target_before_stat_runtime = stats;
  exercise_negative_target_chain(stat_runtime_value, 4215U, 700U);
  exercise_negative_target_chain(serial1_wrong_source, 4230U, 800U);
  exercise_negative_target_chain(serial1_wrong_value, 4240U, 900U);
  passed &= check(
      stats.rf_serial1_baud_exact == 1U &&
          stats.rf_serial1_baud_expected == 1U &&
          stats.rf_serial1_last_value_bits == 0x42640000U &&
          stats.rf_serial1_last_count == 0x1234U &&
          stats.rf_serial1_last_index == 0xFFFFU &&
          stats.rf_serial1_last_type == 6U &&
          stats.rf_msg22 == 4U &&
          stats.rf_serial1_endpoint_queued == 1U &&
          stats.rf_serial1_backlog_queued == 1U &&
          stats.rf_serial1_disconnected_rejected == 1U &&
          stats.rf_serial1_endpoint_dropped == 1U &&
          stats.rf_serial1_proxy_consumed == 1U &&
          stats.rf_serial1_invalid == 1U &&
          stats.rf_downlink_backlog_queued == 4U &&
          stats.rf_downlink_proxy_consumed == 4U &&
          stats.rf_downlink_invalid == 4U &&
          stats.rf_serial1_egress_goals_armed == 1U &&
          stats.rf_serial1_egress_committed == 1U &&
          serial1_baud_commit_goal_count == 0U,
      "exact SERIAL1_BAUD #22 disposition/egress chain was ambiguous");
  passed &= check(
      same_serial1_chain(stats, target_before_stat_runtime) &&
          serial1_baud_commit_goal_count == 0U,
      "STAT_RUNTIME/wrong-source/wrong-value advanced the strict target chain");

  observe_radio_result(LinkActionType::SendRadioData, ControlType::UlIdle,
                       TxResult::Accepted, 4300U);
  observe_radio_result(LinkActionType::SendDone, ControlType::UlDone,
                       TxResult::Accepted, 4301U);
  observe_radio_result(LinkActionType::SendDone, ControlType::UlIdle,
                       TxResult::Rejected, 4302U);
  passed &= check(stats.radio_data_accepted == 1U &&
                      stats.radio_done_accepted == 1U &&
                      stats.radio_idle_rejected == 1U,
                  "E220 DATA/DONE terminal results were not observed");

  observe_proxy_watchdog(
      GroundProxyWatchdogReason::AdmissionAbandoned, 0x1234U, 4400U);
  arm_runtime_stop_reason(
      GroundRuntimeStopReason::ProxyAdmissionAbandoned);
  observe_runtime_fail_closed(true, GroundTddState::UplinkDrain,
                              12U, 4401U);
  arm_runtime_stop_reason(GroundRuntimeStopReason::UsbEgressInvalid);
  observe_runtime_fail_closed(false, GroundTddState::WaitGrant,
                              13U, 4402U);
  passed &= check(stats.proxy_watchdog_events == 1U &&
                      stats.proxy_watchdog_last_reason ==
                          static_cast<std::uint8_t>(
                              GroundProxyWatchdogReason::AdmissionAbandoned) &&
                      stats.proxy_watchdog_last_token == 0x1234U &&
                      stats.runtime_stop_events == 2U &&
                      stats.runtime_stop_first_reason ==
                          static_cast<std::uint8_t>(
                              GroundRuntimeStopReason::ProxyAdmissionAbandoned) &&
                      stats.runtime_stop_first_ms == 4401U &&
                      stats.runtime_stop_first_state ==
                          static_cast<std::uint8_t>(
                              GroundTddState::UplinkDrain) &&
                      stats.runtime_stop_first_cycle == 12U &&
                      stats.runtime_stop_first_ready == 1U,
                  "watchdog/runtime-stop first-cause evidence was not retained");

  reset_observer();
  observe_runtime_fail_closed(true, GroundTddState::WaitGrant,
                              14U, 4500U);
  passed &= check(
      stats.runtime_stop_events == 1U &&
          stats.runtime_stop_first_reason ==
              static_cast<std::uint8_t>(
                  GroundRuntimeStopReason::UnknownRuntimeFault) &&
          stats.runtime_stop_first_reason != 0U,
      "an unarmed runtime stop was not converted to a nonzero unknown cause");

  // Once the bridge is fail-closed the normal ingress collector no longer
  // runs. The dedicated collector must still recognize the exact query while
  // discarding every non-query byte instead of replaying it into MAVLink.
  const std::array<std::uint8_t, 3U> stopped_noise{{0xFDU, 'V', 'X'}};
  for (const std::uint8_t byte : stopped_noise) {
    consume_fail_closed_usb_byte(byte);
  }
  for (std::size_t index = 0U; index < kQuerySize; ++index) {
    consume_fail_closed_usb_byte(static_cast<std::uint8_t>(kQuery[index]));
  }
  passed &= check(query_request_pending && !usb_report_active &&
                      stats.query_completed == 1U &&
                      stats.usb_normal_bytes == 0U &&
                      usb_parser.buffered_size() == 0U,
                  "fail-closed query was not isolated and armed for report");
  passed &= check(take_query_request() && !take_query_request(),
                  "fail-closed query request was not one-shot");

  passed &= check(
      !ground_report_can_start(false, GroundTddState::WaitGrant,
                               false, false, false, true) &&
          !ground_report_can_start(false, GroundTddState::WaitGrant,
                                   false, false, false, false) &&
          ground_report_can_start(false, GroundTddState::WaitGrant,
                                  false, false, true, false) &&
          ground_report_can_start(true, GroundTddState::UplinkDrain,
                                  true, true, false, true),
      "report boundary allowed normal mid-frame interleave or blocked a "
      "non-WaitGrant stopped-state report");
  passed &= check(!usb_report_active, "query paused egress before boundary");
  begin_usb_report();
  passed &= check(usb_report_active, "safe boundary did not activate report");
  finish_usb_report();

  if (!passed) {
    return 1;
  }
  std::puts(
      "PASS Ground query/stage observer preserves MAVLink and retains "
      "continuous-open first-cause evidence");
  return 0;
}
