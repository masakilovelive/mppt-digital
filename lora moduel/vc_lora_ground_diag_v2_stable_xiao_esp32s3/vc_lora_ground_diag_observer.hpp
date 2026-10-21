#pragma once

#if !defined(VC_LORA_PHASE6_GROUND)
#error "Ground diagnostics require VC_LORA_PHASE6_GROUND"
#endif

#if !defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
#error "Ground diagnostics require VC_LORA_PHASE6_GROUND_DIAGNOSTICS"
#endif

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>

#include <vc_lora/embedded_io_adapter.hpp>
#include <vc_lora/ground_parameter_download_proxy.hpp>
#include <vc_lora/link_diagnostics.hpp>
#include <vc_lora/mavlink_frame.hpp>
#include <vc_lora/tdd_ground.hpp>
#include <vc_lora/tdd_types.hpp>

namespace vc_lora_ground_diag_observer {

constexpr char kQuery[] = "VCGSTAT?\n";
constexpr std::size_t kQuerySize = sizeof(kQuery) - 1U;
constexpr std::uint64_t kQueryCandidateTimeoutMs = 50U;
constexpr std::size_t kGroundStateCount = 6U;

// Numeric values are an evidence contract. They are intentionally fixed-size
// and are reported verbatim by GCSTAT so a postmortem does not depend on text
// emitted in the MAVLink stream.
enum class GroundRuntimeStopReason : std::uint8_t {
  Unclassified = 0U,
  UsbEgressInvalid = 1U,
  DownlinkOrderInvariant = 2U,
  HeartbeatPacerInvariant = 3U,
  ProxyAdmissionAbandoned = 4U,
  ProxyMarkAdmissionFailed = 5U,
  ProxyGeneratedIngressRejected = 6U,
  GroundIngressFault = 7U,
  E220WriteFault = 8U,
  TddControllerFault = 9U,
  UnknownRuntimeFault = 255U,
};

enum class GroundProxyWatchdogReason : std::uint8_t {
  None = 0U,
  AdmissionAbandoned = 1U,
  MarkAdmissionFailed = 2U,
  GeneratedIngressRejected = 3U,
};

enum class GroundDownlinkDisposition : std::uint8_t {
  EndpointQueued = 0U,
  DisconnectedRejected = 1U,
  EndpointDropped = 2U,
  BacklogQueued = 3U,
  ProxyConsumed = 4U,
  Invalid = 5U,
};

struct UsbRouteResult {
  std::array<std::uint8_t, kQuerySize> replay{};
  std::uint8_t replay_size{0U};
  bool consumed{false};
};

// Fixed event-time context captured only by the diagnostic build. It is
// deliberately supplied by the bridge so a later GCSTAT query reports the
// state which existed at the maximum heartbeat gap, not merely query-time
// state.
struct GroundHeartbeatRuntimeContext {
  std::uint32_t usb_queued_bytes{0U};
  std::uint32_t ordered_backlog_bytes{0U};
  std::uint16_t cycle{0U};
  std::uint16_t ordered_backlog_frames{0U};
  std::uint8_t state{0U};
  std::uint8_t aux{0U};
  std::uint8_t radio_busy{0U};
  std::uint8_t pending_action{0U};
  std::uint8_t pacer_queued{0U};
  std::uint8_t pacer_pending{0U};
  std::uint8_t pacer_admitted{0U};
  std::uint8_t usb_write_pending{0U};
  std::uint8_t usb_writer_available{0U};
};

struct GroundHeartbeatGapEvent {
  std::uint64_t gap_ms{0U};
  std::uint64_t event_ms{0U};
  GroundHeartbeatRuntimeContext context{};
  std::uint8_t previous_sequence{0U};
  std::uint8_t sequence{0U};
};

struct GroundHeartbeatGapStats {
  std::uint64_t events{0U};
  std::uint64_t gap_observations{0U};
  std::uint64_t gap_violation_count{0U};
  std::uint64_t last_ms{0U};
  GroundHeartbeatGapEvent latest{};
  GroundHeartbeatGapEvent maximum{};
  GroundHeartbeatGapEvent latest_violation{};
  std::uint8_t last_sequence{0U};
};

inline constexpr std::uint64_t kHeartbeatGapViolationMs = 2500U;

static_assert(std::is_trivially_copyable<GroundHeartbeatRuntimeContext>::value,
              "Ground heartbeat runtime context must remain fixed POD");
static_assert(std::is_trivially_copyable<GroundHeartbeatGapEvent>::value,
              "Ground heartbeat gap event must remain fixed POD");
static_assert(std::is_trivially_copyable<GroundHeartbeatGapStats>::value,
              "Ground heartbeat gap stats must remain fixed POD");

struct ObserverStats {
  std::uint64_t usb_normal_bytes{0U};
  std::uint64_t usb_frames_valid{0U};
  std::uint64_t usb_msg20{0U};
  std::uint64_t usb_msg21{0U};
  std::uint64_t usb_bad_crc{0U};
  std::uint64_t usb_invalid{0U};
  std::uint64_t usb_status_queued{0U};
  std::uint64_t usb_status_dropped{0U};
  std::uint64_t usb_proxy_consumed{0U};
  std::uint64_t usb_proxy_forwarded{0U};
  std::uint64_t usb_proxy_invalid{0U};

  // HWCDC endpoint readiness may fall during a short write-progress stall.
  // These fields intentionally describe endpoint readiness, not physical USB
  // host/SOF presence and not whether a Windows COM handle is open.
  std::uint64_t usb_predicate_samples{0U};
  std::uint64_t usb_predicate_transitions{0U};
  std::uint64_t usb_predicate_connected_transitions{0U};
  std::uint64_t usb_predicate_disconnected_transitions{0U};
  std::uint64_t usb_predicate_last_transition_ms{0U};
  std::uint16_t usb_predicate_last_cycle{0U};
  std::uint8_t usb_predicate_last_state{0U};
  std::uint8_t usb_predicate_value{0U};

  // Serial.isPlugged() is the independent USB SOF/host-presence signal used
  // for destructive disconnect handling.
  std::uint64_t usb_host_presence_samples{0U};
  std::uint64_t usb_host_presence_transitions{0U};
  std::uint64_t usb_host_present_transitions{0U};
  std::uint64_t usb_host_absent_transitions{0U};
  std::uint64_t usb_host_presence_last_transition_ms{0U};
  std::uint16_t usb_host_presence_last_cycle{0U};
  std::uint8_t usb_host_presence_last_state{0U};
  std::uint8_t usb_host_presence_value{0U};

  std::uint64_t usb_pump_calls{0U};
  std::uint64_t usb_pump_disconnected{0U};
  std::uint64_t usb_pump_writer_unavailable{0U};
  std::uint64_t usb_pump_progress{0U};
  std::uint64_t usb_pump_invalid{0U};
  std::uint64_t usb_egress_last_queued_before{0U};
  std::uint64_t usb_egress_last_queued_after{0U};
  std::uint64_t usb_egress_last_committed_before{0U};
  std::uint64_t usb_egress_last_committed_after{0U};
  std::uint64_t usb_pump_last_ms{0U};
  std::uint16_t usb_pump_last_cycle{0U};
  std::uint8_t usb_pump_last_state{0U};
  std::uint8_t usb_pump_last_status{0U};

  std::uint64_t rf_frames_valid{0U};
  std::uint64_t rf_msg0{0U};
  std::uint64_t rf_msg20{0U};
  std::uint64_t rf_msg22{0U};
  std::uint64_t rf_downlink_queued{0U};
  std::uint64_t rf_downlink_disconnected_rejected{0U};
  std::uint64_t rf_downlink_dropped{0U};
  std::uint64_t rf_downlink_backlog_queued{0U};
  std::uint64_t rf_downlink_proxy_consumed{0U};
  std::uint64_t rf_downlink_invalid{0U};
  std::uint16_t ordered_backlog_param_value_frames{0U};
  std::uint64_t rf_last_valid_ms{0U};
  GroundHeartbeatGapStats rf_primary_heartbeat_gap{};
  GroundHeartbeatGapStats usb_primary_heartbeat_gap{};

  // Every field in this target chain uses one strict expected-response
  // predicate, so periodic STAT_RUNTIME PARAM_VALUE traffic cannot advance
  // RF-valid, disposition, admission or physical-commit evidence.
  std::uint64_t rf_serial1_baud_exact{0U};
  std::uint64_t rf_serial1_baud_expected{0U};
  std::uint64_t rf_serial1_endpoint_queued{0U};
  std::uint64_t rf_serial1_disconnected_rejected{0U};
  std::uint64_t rf_serial1_endpoint_dropped{0U};
  std::uint64_t rf_serial1_backlog_queued{0U};
  std::uint64_t rf_serial1_proxy_consumed{0U};
  std::uint64_t rf_serial1_invalid{0U};
  std::uint64_t rf_serial1_egress_goals_armed{0U};
  std::uint64_t rf_serial1_egress_committed{0U};
  std::uint64_t rf_serial1_egress_goal_overflow{0U};
  std::uint64_t rf_serial1_last_commit_goal{0U};
  std::uint64_t rf_serial1_last_committed_bytes{0U};
  std::uint64_t rf_serial1_last_ms{0U};
  std::uint32_t rf_serial1_last_value_bits{0U};
  std::uint16_t rf_serial1_last_count{0U};
  std::uint16_t rf_serial1_last_index{0U};
  std::uint8_t rf_serial1_last_type{0U};
  std::uint8_t rf_serial1_last_sequence{0U};
  std::uint8_t rf_serial1_last_system_id{0U};
  std::uint8_t rf_serial1_last_component_id{0U};
  std::uint8_t rf_serial1_egress_pending{0U};

  std::uint64_t radio_data_accepted{0U};
  std::uint64_t radio_data_rejected{0U};
  std::uint64_t radio_done_accepted{0U};
  std::uint64_t radio_done_rejected{0U};
  std::uint64_t radio_idle_accepted{0U};
  std::uint64_t radio_idle_rejected{0U};
  std::uint64_t radio_result_last_ms{0U};

  std::uint64_t proxy_watchdog_events{0U};
  std::uint64_t proxy_watchdog_last_ms{0U};
  std::uint32_t proxy_watchdog_last_token{0U};
  std::uint8_t proxy_watchdog_last_reason{0U};

  std::uint64_t runtime_stop_events{0U};
  std::uint64_t runtime_stop_first_ms{0U};
  std::uint16_t runtime_stop_first_cycle{0U};
  std::uint8_t runtime_stop_first_reason{0U};
  std::uint8_t runtime_stop_first_state{0U};
  std::uint8_t runtime_stop_first_ready{0U};

  std::uint64_t query_completed{0U};
  std::uint64_t query_prefix_mismatch{0U};
  std::uint64_t query_prefix_timeout{0U};

  std::uint64_t e220_raw_bytes{0U};
  std::uint64_t last_e220_raw_ms{0U};
  std::array<std::uint64_t, kGroundStateCount> raw_by_state{};

  std::uint64_t control_messages{0U};
  std::uint64_t control_grants{0U};
  std::uint64_t control_accepted{0U};
  std::uint64_t control_duplicate{0U};
  std::uint64_t control_future{0U};
  std::uint64_t control_stale_cycle{0U};
  std::uint64_t control_stale_session{0U};
  std::uint64_t control_invalid{0U};
  std::uint64_t last_control_ms{0U};
  std::uint16_t last_control_session{0U};
  std::uint16_t last_control_cycle{0U};
  std::uint8_t last_control_type{0U};
  std::uint8_t last_control_state{0U};
  std::array<std::uint64_t, kGroundStateCount> control_by_state{};

  std::uint64_t action_data_issued{0U};
  std::uint64_t action_done_issued{0U};
  std::uint64_t action_idle_issued{0U};
  std::uint64_t last_action_ms{0U};
  std::uint32_t last_action_token{0U};
  std::uint16_t last_action_cycle{0U};
  std::uint8_t last_action_type{0U};

  std::array<std::uint64_t, kGroundStateCount> state_entries{};
  std::uint64_t state_changes{0U};
  std::uint64_t state_entered_ms{0U};
  std::uint16_t observed_cycle{0U};
  std::uint8_t observed_state{0xFFU};
};

static_assert(std::is_trivially_copyable<ObserverStats>::value,
              "Ground observer stats must remain fixed POD");

struct ControlCounterBaseline {
  std::uint64_t grant_rx{0U};
  std::uint64_t duplicate_grants{0U};
  std::uint64_t future_cycles{0U};
  std::uint64_t stale_cycles{0U};
  std::uint64_t stale_sessions{0U};
  bool active{false};
};

inline ObserverStats stats{};
inline vc_lora::MavlinkStreamParser usb_parser{};
inline std::array<std::uint8_t, kQuerySize> query_candidate{};
inline std::size_t query_candidate_size{0U};
inline std::uint64_t query_candidate_started_ms{0U};
inline std::size_t fail_closed_query_candidate_size{0U};
inline bool query_request_pending{false};
inline bool usb_report_active{false};
inline ControlCounterBaseline control_before{};
inline bool usb_connection_initialized{false};
inline bool usb_host_presence_initialized{false};
constexpr std::size_t kSerial1BaudCommitGoalCapacity = 4U;
inline std::array<std::uint64_t, kSerial1BaudCommitGoalCapacity>
    serial1_baud_commit_goals{};
inline std::size_t serial1_baud_commit_goal_head{0U};
inline std::size_t serial1_baud_commit_goal_count{0U};
inline GroundRuntimeStopReason armed_runtime_stop_reason{
    GroundRuntimeStopReason::Unclassified};
inline GroundDownlinkDisposition armed_downlink_disposition{
    GroundDownlinkDisposition::EndpointDropped};

constexpr std::size_t ground_state_index(
    vc_lora::GroundTddState state) noexcept {
  switch (state) {
    case vc_lora::GroundTddState::WaitGrant:
      return 0U;
    case vc_lora::GroundTddState::UplinkGuard:
      return 1U;
    case vc_lora::GroundTddState::UplinkSend:
      return 2U;
    case vc_lora::GroundTddState::UplinkDrain:
      return 3U;
    case vc_lora::GroundTddState::SendUlDone:
      return 4U;
    case vc_lora::GroundTddState::DoneDrain:
      return 5U;
  }
  return 0U;
}

inline void clear_query_candidate() noexcept {
  query_candidate_size = 0U;
  query_candidate_started_ms = 0U;
}

inline UsbRouteResult flush_query_candidate(
    std::uint64_t now_ms) noexcept {
  UsbRouteResult result{};
  if (query_candidate_size == 0U ||
      now_ms - query_candidate_started_ms < kQueryCandidateTimeoutMs) {
    return result;
  }
  result.consumed = true;
  result.replay_size = static_cast<std::uint8_t>(query_candidate_size);
  for (std::size_t index = 0U; index < query_candidate_size; ++index) {
    result.replay[index] = query_candidate[index];
  }
  ++stats.query_prefix_timeout;
  clear_query_candidate();
  return result;
}

inline UsbRouteResult route_usb_byte(std::uint8_t byte,
                                     std::uint64_t now_ms) noexcept {
  UsbRouteResult result{};
  if (query_candidate_size == 0U) {
    if (usb_parser.buffered_size() == 0U &&
        byte == static_cast<std::uint8_t>(kQuery[0U])) {
      query_candidate[0U] = byte;
      query_candidate_size = 1U;
      query_candidate_started_ms = now_ms;
      result.consumed = true;
    }
    return result;
  }

  result.consumed = true;
  if (byte == static_cast<std::uint8_t>(kQuery[query_candidate_size])) {
    query_candidate[query_candidate_size++] = byte;
    if (query_candidate_size == kQuerySize) {
      ++stats.query_completed;
      query_request_pending = true;
      clear_query_candidate();
    }
    return result;
  }

  query_candidate[query_candidate_size++] = byte;
  result.replay_size = static_cast<std::uint8_t>(query_candidate_size);
  for (std::size_t index = 0U; index < query_candidate_size; ++index) {
    result.replay[index] = query_candidate[index];
  }
  ++stats.query_prefix_mismatch;
  clear_query_candidate();
  return result;
}

inline bool take_query_request() noexcept {
  if (!query_request_pending) {
    return false;
  }
  query_request_pending = false;
  return true;
}

// In a stopped bridge the production USB parser is intentionally never
// serviced. This independent matcher consumes every byte locally, recognizes
// only the exact query, and never exposes a replay path to MAVLink/RF.
inline void consume_fail_closed_usb_byte(std::uint8_t byte) noexcept {
  if (byte == static_cast<std::uint8_t>(
                  kQuery[fail_closed_query_candidate_size])) {
    ++fail_closed_query_candidate_size;
    if (fail_closed_query_candidate_size == kQuerySize) {
      ++stats.query_completed;
      query_request_pending = true;
      fail_closed_query_candidate_size = 0U;
    }
    return;
  }
  fail_closed_query_candidate_size =
      byte == static_cast<std::uint8_t>(kQuery[0U]) ? 1U : 0U;
}

inline bool ground_report_can_start(
    bool stopped, vc_lora::GroundTddState state, bool radio_is_busy,
    bool action_pending, bool egress_empty,
    bool egress_write_pending) noexcept {
  if (stopped) {
    return true;
  }
  return state == vc_lora::GroundTddState::WaitGrant && !radio_is_busy &&
         !action_pending && egress_empty && !egress_write_pending;
}

inline void begin_usb_report() noexcept { usb_report_active = true; }

inline void finish_usb_report() noexcept { usb_report_active = false; }

inline void observe_usb_byte(std::uint8_t byte, std::uint64_t) noexcept {
  ++stats.usb_normal_bytes;
  vc_lora::MavlinkFrame frame{};
  const vc_lora::MavlinkParseStatus parse_status = usb_parser.push(byte, frame);
  if (parse_status == vc_lora::MavlinkParseStatus::FrameReady) {
    ++stats.usb_frames_valid;
    if (frame.message_id == 20U) {
      ++stats.usb_msg20;
    } else if (frame.message_id == 21U) {
      ++stats.usb_msg21;
    }
  } else if (parse_status == vc_lora::MavlinkParseStatus::BadCrc) {
    ++stats.usb_bad_crc;
    ++stats.usb_invalid;
  } else if (parse_status == vc_lora::MavlinkParseStatus::BadLength ||
             parse_status == vc_lora::MavlinkParseStatus::UnsupportedMessage ||
             parse_status == vc_lora::MavlinkParseStatus::UnsupportedFlags) {
    ++stats.usb_invalid;
  }
}

inline void observe_usb_frame(
    const vc_lora::MavlinkFrame&,
    vc_lora::GroundParameterProxyDisposition disposition,
    vc_lora::FrameIngressStatus status) noexcept {
  if (disposition == vc_lora::GroundParameterProxyDisposition::Consumed) {
    ++stats.usb_proxy_consumed;
  } else if (disposition ==
             vc_lora::GroundParameterProxyDisposition::Invalid) {
    ++stats.usb_proxy_invalid;
  } else {
    ++stats.usb_proxy_forwarded;
  }
  if (status == vc_lora::FrameIngressStatus::Queued) {
    ++stats.usb_status_queued;
  } else if (status == vc_lora::FrameIngressStatus::DroppedOverflow ||
             status == vc_lora::FrameIngressStatus::FailClosed) {
    ++stats.usb_status_dropped;
  }
}

// Retained for the older diagnostic contract test; the latest adapter uses
// observe_usb_byte() plus observe_usb_frame() so proxy-consumed #21 frames are
// visible without pretending they entered the RF descriptor FIFO.
inline void observe_usb_ingress(
    std::uint8_t byte, vc_lora::FrameIngressStatus status,
    std::uint64_t now_ms) noexcept {
  observe_usb_byte(byte, now_ms);
  if (status == vc_lora::FrameIngressStatus::Queued) {
    ++stats.usb_status_queued;
  } else if (status == vc_lora::FrameIngressStatus::DroppedOverflow ||
             status == vc_lora::FrameIngressStatus::FailClosed) {
    ++stats.usb_status_dropped;
  }
}

inline void observe_usb_connection(bool predicate,
                                   vc_lora::GroundTddState state,
                                   std::uint16_t cycle,
                                   std::uint64_t now_ms) noexcept {
  ++stats.usb_predicate_samples;
  const std::uint8_t value = predicate ? 1U : 0U;
  if (!usb_connection_initialized) {
    usb_connection_initialized = true;
    stats.usb_predicate_value = value;
    stats.usb_predicate_last_state = static_cast<std::uint8_t>(state);
    stats.usb_predicate_last_cycle = cycle;
    stats.usb_predicate_last_transition_ms = now_ms;
    return;
  }
  if (stats.usb_predicate_value == value) {
    return;
  }
  stats.usb_predicate_value = value;
  stats.usb_predicate_last_state = static_cast<std::uint8_t>(state);
  stats.usb_predicate_last_cycle = cycle;
  stats.usb_predicate_last_transition_ms = now_ms;
  ++stats.usb_predicate_transitions;
  if (predicate) {
    ++stats.usb_predicate_connected_transitions;
  } else {
    ++stats.usb_predicate_disconnected_transitions;
  }
}

inline void observe_usb_host_presence(bool present,
                                      vc_lora::GroundTddState state,
                                      std::uint16_t cycle,
                                      std::uint64_t now_ms) noexcept {
  ++stats.usb_host_presence_samples;
  const std::uint8_t value = present ? 1U : 0U;
  if (!usb_host_presence_initialized) {
    usb_host_presence_initialized = true;
    stats.usb_host_presence_value = value;
    stats.usb_host_presence_last_state = static_cast<std::uint8_t>(state);
    stats.usb_host_presence_last_cycle = cycle;
    stats.usb_host_presence_last_transition_ms = now_ms;
    return;
  }
  if (stats.usb_host_presence_value == value) {
    return;
  }
  stats.usb_host_presence_value = value;
  stats.usb_host_presence_last_state = static_cast<std::uint8_t>(state);
  stats.usb_host_presence_last_cycle = cycle;
  stats.usb_host_presence_last_transition_ms = now_ms;
  ++stats.usb_host_presence_transitions;
  if (present) {
    ++stats.usb_host_present_transitions;
  } else {
    ++stats.usb_host_absent_transitions;
  }
}

inline void observe_usb_egress_pump(
    vc_lora::LocalEgressPumpStatus status, std::size_t queued_before,
    std::size_t queued_after, std::uint64_t committed_before,
    std::uint64_t committed_after, vc_lora::GroundTddState state,
    std::uint16_t cycle, std::uint64_t now_ms) noexcept {
  ++stats.usb_pump_calls;
  if (status == vc_lora::LocalEgressPumpStatus::Disconnected) {
    ++stats.usb_pump_disconnected;
  } else if (status == vc_lora::LocalEgressPumpStatus::WriterUnavailable) {
    ++stats.usb_pump_writer_unavailable;
  } else if (status == vc_lora::LocalEgressPumpStatus::Progress) {
    ++stats.usb_pump_progress;
  } else if (status == vc_lora::LocalEgressPumpStatus::Invalid) {
    ++stats.usb_pump_invalid;
  }
  stats.usb_egress_last_queued_before = queued_before;
  stats.usb_egress_last_queued_after = queued_after;
  stats.usb_egress_last_committed_before = committed_before;
  stats.usb_egress_last_committed_after = committed_after;
  stats.usb_pump_last_status = static_cast<std::uint8_t>(status);
  stats.usb_pump_last_state = static_cast<std::uint8_t>(state);
  stats.usb_pump_last_cycle = cycle;
  stats.usb_pump_last_ms = now_ms;
  while (serial1_baud_commit_goal_count > 0U &&
         committed_after >=
             serial1_baud_commit_goals[serial1_baud_commit_goal_head]) {
    ++stats.rf_serial1_egress_committed;
    stats.rf_serial1_last_committed_bytes = committed_after;
    serial1_baud_commit_goals[serial1_baud_commit_goal_head] = 0U;
    serial1_baud_commit_goal_head =
        (serial1_baud_commit_goal_head + 1U) %
        serial1_baud_commit_goals.size();
    --serial1_baud_commit_goal_count;
  }
  stats.rf_serial1_egress_pending =
      static_cast<std::uint8_t>(serial1_baud_commit_goal_count);
}

inline std::uint16_t load_u16_le(const std::uint8_t* bytes) noexcept {
  return static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(bytes[0U]) |
      (static_cast<std::uint16_t>(bytes[1U]) << 8U));
}

inline std::uint32_t load_u32_le(const std::uint8_t* bytes) noexcept {
  return static_cast<std::uint32_t>(bytes[0U]) |
         (static_cast<std::uint32_t>(bytes[1U]) << 8U) |
         (static_cast<std::uint32_t>(bytes[2U]) << 16U) |
         (static_cast<std::uint32_t>(bytes[3U]) << 24U);
}

inline bool is_expected_serial1_baud_param_value(
    const vc_lora::MavlinkFrame& frame) noexcept {
  if (frame.message_id != 22U || frame.payload_length != 25U ||
      frame.system_id != 1U || frame.component_id != 1U) {
    return false;
  }
  const std::uint8_t* payload = frame.payload();
  if (payload == nullptr) {
    return false;
  }
  constexpr std::array<std::uint8_t, 16U> kSerial1BaudParamId{{
      'S', 'E', 'R', 'I', 'A', 'L', '1', '_',
      'B', 'A', 'U', 'D', 0U, 0U, 0U, 0U}};
  const std::uint16_t count = load_u16_le(payload + 4U);
  return std::memcmp(payload + 8U, kSerial1BaudParamId.data(),
                     kSerial1BaudParamId.size()) == 0 &&
         load_u32_le(payload) == 0x42640000U && count != 0U &&
         load_u16_le(payload + 6U) == 0xFFFFU && payload[24U] == 6U;
}

inline void observe_ground_validated_frame(
    const vc_lora::MavlinkFrame& frame, std::uint64_t now_ms) noexcept {
  ++stats.rf_frames_valid;
  if (frame.message_id == 0U) {
    ++stats.rf_msg0;
  } else if (frame.message_id == 20U) {
    ++stats.rf_msg20;
  } else if (frame.message_id == 22U) {
    ++stats.rf_msg22;
  }
  if (is_expected_serial1_baud_param_value(frame)) {
    const std::uint8_t* payload = frame.payload();
    const std::uint32_t value_bits = load_u32_le(payload);
    ++stats.rf_serial1_baud_exact;
    ++stats.rf_serial1_baud_expected;
    stats.rf_serial1_last_value_bits = value_bits;
    stats.rf_serial1_last_count = load_u16_le(payload + 4U);
    stats.rf_serial1_last_index = load_u16_le(payload + 6U);
    stats.rf_serial1_last_type = payload[24U];
    stats.rf_serial1_last_sequence = frame.sequence;
    stats.rf_serial1_last_system_id = frame.system_id;
    stats.rf_serial1_last_component_id = frame.component_id;
    stats.rf_serial1_last_ms = now_ms;
  }
  stats.rf_last_valid_ms = now_ms;
}

inline void observe_ground_heartbeat_gap(
    GroundHeartbeatGapStats& gap, std::uint8_t sequence,
    const GroundHeartbeatRuntimeContext& context,
    std::uint64_t now_ms) noexcept {
  const bool have_previous = gap.events > 0U;
  const std::uint8_t previous_sequence = gap.last_sequence;
  const std::uint64_t previous_ms = gap.last_ms;
  ++gap.events;
  gap.last_sequence = sequence;
  gap.last_ms = now_ms;
  if (!have_previous || now_ms < previous_ms) {
    return;
  }
  const std::uint64_t candidate = now_ms - previous_ms;
  ++gap.gap_observations;
  GroundHeartbeatGapEvent event{};
  event.gap_ms = candidate;
  event.event_ms = now_ms;
  event.context = context;
  event.previous_sequence = previous_sequence;
  event.sequence = sequence;
  gap.latest = event;
  if (candidate > gap.maximum.gap_ms) {
    gap.maximum = event;
  }
  if (candidate > kHeartbeatGapViolationMs) {
    ++gap.gap_violation_count;
    gap.latest_violation = event;
  }
}

inline void observe_ground_primary_heartbeat_rf(
    const vc_lora::MavlinkFrame& frame,
    const GroundHeartbeatRuntimeContext& context,
    std::uint64_t now_ms) noexcept {
  if (frame.message_id != 0U || frame.system_id != 1U ||
      frame.component_id != 1U) {
    return;
  }
  observe_ground_heartbeat_gap(stats.rf_primary_heartbeat_gap,
                               frame.sequence, context, now_ms);
}

inline void observe_ground_primary_heartbeat_usb_commit(
    std::uint8_t sequence, const GroundHeartbeatRuntimeContext& context,
    std::uint64_t now_ms) noexcept {
  observe_ground_heartbeat_gap(stats.usb_primary_heartbeat_gap,
                               sequence, context, now_ms);
}

inline void observe_ground_ordered_backlog_enqueued(
    const vc_lora::MavlinkFrame& frame) noexcept {
  if (frame.message_id == 22U &&
      stats.ordered_backlog_param_value_frames != UINT16_MAX) {
    ++stats.ordered_backlog_param_value_frames;
  }
}

inline void observe_ground_ordered_backlog_removed(
    const vc_lora::MavlinkFrame& frame) noexcept {
  if (frame.message_id == 22U &&
      stats.ordered_backlog_param_value_frames != 0U) {
    --stats.ordered_backlog_param_value_frames;
  }
}

inline void observe_ground_ordered_backlog_cleared() noexcept {
  stats.ordered_backlog_param_value_frames = 0U;
}

inline void observe_ground_downlink(
    const vc_lora::MavlinkFrame& frame, GroundDownlinkDisposition disposition,
    std::uint64_t) noexcept {
  switch (disposition) {
    case GroundDownlinkDisposition::EndpointQueued:
      ++stats.rf_downlink_queued;
      break;
    case GroundDownlinkDisposition::DisconnectedRejected:
      ++stats.rf_downlink_disconnected_rejected;
      break;
    case GroundDownlinkDisposition::EndpointDropped:
      ++stats.rf_downlink_dropped;
      break;
    case GroundDownlinkDisposition::BacklogQueued:
      ++stats.rf_downlink_backlog_queued;
      break;
    case GroundDownlinkDisposition::ProxyConsumed:
      ++stats.rf_downlink_proxy_consumed;
      break;
    case GroundDownlinkDisposition::Invalid:
      ++stats.rf_downlink_invalid;
      break;
  }
  if (!is_expected_serial1_baud_param_value(frame)) {
    return;
  }
  switch (disposition) {
    case GroundDownlinkDisposition::EndpointQueued:
      ++stats.rf_serial1_endpoint_queued;
      break;
    case GroundDownlinkDisposition::DisconnectedRejected:
      ++stats.rf_serial1_disconnected_rejected;
      break;
    case GroundDownlinkDisposition::EndpointDropped:
      ++stats.rf_serial1_endpoint_dropped;
      break;
    case GroundDownlinkDisposition::BacklogQueued:
      ++stats.rf_serial1_backlog_queued;
      break;
    case GroundDownlinkDisposition::ProxyConsumed:
      ++stats.rf_serial1_proxy_consumed;
      break;
    case GroundDownlinkDisposition::Invalid:
      ++stats.rf_serial1_invalid;
      break;
  }
}

inline void observe_target_egress_admission(
    const vc_lora::MavlinkFrame& frame,
    std::uint64_t cumulative_commit_goal) noexcept {
  if (!is_expected_serial1_baud_param_value(frame)) {
    return;
  }
  if (serial1_baud_commit_goal_count >= serial1_baud_commit_goals.size()) {
    ++stats.rf_serial1_egress_goal_overflow;
    return;
  }
  const std::size_t tail =
      (serial1_baud_commit_goal_head + serial1_baud_commit_goal_count) %
      serial1_baud_commit_goals.size();
  serial1_baud_commit_goals[tail] = cumulative_commit_goal;
  ++serial1_baud_commit_goal_count;
  ++stats.rf_serial1_egress_goals_armed;
  stats.rf_serial1_last_commit_goal = cumulative_commit_goal;
  stats.rf_serial1_egress_pending =
      static_cast<std::uint8_t>(serial1_baud_commit_goal_count);
}

inline void arm_ground_downlink_disposition(
    GroundDownlinkDisposition disposition) noexcept {
  armed_downlink_disposition = disposition;
}

inline GroundDownlinkDisposition take_ground_downlink_disposition() noexcept {
  const GroundDownlinkDisposition disposition = armed_downlink_disposition;
  armed_downlink_disposition = GroundDownlinkDisposition::EndpointDropped;
  return disposition;
}

inline void observe_radio_result(vc_lora::LinkActionType action_type,
                                 vc_lora::ControlType control_type,
                                 vc_lora::TxResult result,
                                 std::uint64_t now_ms) noexcept {
  const bool accepted = result == vc_lora::TxResult::Accepted;
  if (action_type == vc_lora::LinkActionType::SendRadioData) {
    accepted ? ++stats.radio_data_accepted : ++stats.radio_data_rejected;
  } else if (action_type == vc_lora::LinkActionType::SendDone &&
             control_type == vc_lora::ControlType::UlIdle) {
    accepted ? ++stats.radio_idle_accepted : ++stats.radio_idle_rejected;
  } else if (action_type == vc_lora::LinkActionType::SendDone) {
    accepted ? ++stats.radio_done_accepted : ++stats.radio_done_rejected;
  }
  stats.radio_result_last_ms = now_ms;
}

inline void observe_proxy_watchdog(GroundProxyWatchdogReason reason,
                                   std::uint32_t token,
                                   std::uint64_t now_ms) noexcept {
  ++stats.proxy_watchdog_events;
  stats.proxy_watchdog_last_reason = static_cast<std::uint8_t>(reason);
  stats.proxy_watchdog_last_token = token;
  stats.proxy_watchdog_last_ms = now_ms;
}

inline void arm_runtime_stop_reason(GroundRuntimeStopReason reason) noexcept {
  armed_runtime_stop_reason = reason;
}

inline void observe_runtime_fail_closed(bool ready_before,
                                        vc_lora::GroundTddState state,
                                        std::uint16_t cycle,
                                        std::uint64_t now_ms) noexcept {
  fail_closed_query_candidate_size = 0U;
  ++stats.runtime_stop_events;
  if (stats.runtime_stop_events == 1U) {
    const GroundRuntimeStopReason first_reason =
        armed_runtime_stop_reason == GroundRuntimeStopReason::Unclassified
            ? GroundRuntimeStopReason::UnknownRuntimeFault
            : armed_runtime_stop_reason;
    stats.runtime_stop_first_reason =
        static_cast<std::uint8_t>(first_reason);
    stats.runtime_stop_first_state = static_cast<std::uint8_t>(state);
    stats.runtime_stop_first_cycle = cycle;
    stats.runtime_stop_first_ms = now_ms;
    stats.runtime_stop_first_ready = ready_before ? 1U : 0U;
  }
  armed_runtime_stop_reason = GroundRuntimeStopReason::Unclassified;
}

inline void observe_e220_raw(std::uint8_t,
                             vc_lora::GroundTddState state,
                             std::uint16_t,
                             std::uint64_t now_ms) noexcept {
  ++stats.e220_raw_bytes;
  stats.last_e220_raw_ms = now_ms;
  ++stats.raw_by_state[ground_state_index(state)];
}

inline void observe_radio_control_before(
    const vc_lora::TddControlMessage& message,
    vc_lora::GroundTddState state, std::uint16_t,
    std::uint64_t now_ms,
    const vc_lora::LinkDiagnostics& diagnostics) noexcept {
  ++stats.control_messages;
  if (message.type == vc_lora::ControlType::UlGrant) {
    ++stats.control_grants;
  }
  stats.last_control_ms = now_ms;
  stats.last_control_session = message.session_id;
  stats.last_control_cycle = message.cycle_id;
  stats.last_control_type = static_cast<std::uint8_t>(message.type);
  stats.last_control_state = static_cast<std::uint8_t>(state);
  ++stats.control_by_state[ground_state_index(state)];
  control_before.grant_rx = diagnostics.grant_rx;
  control_before.duplicate_grants = diagnostics.duplicate_grants;
  control_before.future_cycles = diagnostics.future_cycles;
  control_before.stale_cycles = diagnostics.stale_cycles;
  control_before.stale_sessions = diagnostics.stale_sessions;
  control_before.active = true;
}

inline void observe_radio_control_after(
    const vc_lora::TddControlMessage&, vc_lora::GroundTddState,
    std::uint16_t, std::uint64_t,
    const vc_lora::LinkDiagnostics& diagnostics) noexcept {
  if (!control_before.active) {
    return;
  }
  if (diagnostics.grant_rx > control_before.grant_rx) {
    ++stats.control_accepted;
  } else if (diagnostics.duplicate_grants >
             control_before.duplicate_grants) {
    ++stats.control_duplicate;
  } else if (diagnostics.future_cycles > control_before.future_cycles) {
    ++stats.control_future;
  } else if (diagnostics.stale_cycles > control_before.stale_cycles) {
    ++stats.control_stale_cycle;
  } else if (diagnostics.stale_sessions > control_before.stale_sessions) {
    ++stats.control_stale_session;
  } else {
    ++stats.control_invalid;
  }
  control_before.active = false;
}

inline void observe_action_issued(const vc_lora::LinkAction& action,
                                  vc_lora::GroundTddState,
                                  std::uint16_t cycle,
                                  std::uint64_t now_ms) noexcept {
  if (action.type == vc_lora::LinkActionType::SendRadioData) {
    ++stats.action_data_issued;
  } else if (action.type == vc_lora::LinkActionType::SendDone) {
    ++stats.action_done_issued;
    if (action.control.type == vc_lora::ControlType::UlIdle) {
      ++stats.action_idle_issued;
    }
  }
  stats.last_action_ms = now_ms;
  stats.last_action_token = action.token;
  stats.last_action_cycle = cycle;
  stats.last_action_type = static_cast<std::uint8_t>(action.type);
}

inline void observe_ground_controller(vc_lora::GroundTddState state,
                                      std::uint16_t cycle,
                                      std::uint64_t now_ms) noexcept {
  const std::uint8_t value = static_cast<std::uint8_t>(state);
  if (stats.observed_state == value && stats.observed_cycle == cycle) {
    return;
  }
  stats.observed_state = value;
  stats.observed_cycle = cycle;
  stats.state_entered_ms = now_ms;
  ++stats.state_changes;
  ++stats.state_entries[ground_state_index(state)];
}

}  // namespace vc_lora_ground_diag_observer
