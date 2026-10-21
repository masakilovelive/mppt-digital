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

#include <vc_lora/embedded_io_adapter.hpp>
#include <vc_lora/link_diagnostics.hpp>
#include <vc_lora/mavlink_frame.hpp>
#include <vc_lora/tdd_ground.hpp>
#include <vc_lora/tdd_types.hpp>

namespace vc_lora_ground_diag_observer {

constexpr char kQuery[] = "VCGSTAT?\n";
constexpr std::size_t kQuerySize = sizeof(kQuery) - 1U;
constexpr std::uint64_t kQueryCandidateTimeoutMs = 50U;
constexpr std::size_t kGroundStateCount = 6U;

struct UsbRouteResult {
  std::array<std::uint8_t, kQuerySize> replay{};
  std::uint8_t replay_size{0U};
  bool consumed{false};
};

struct ObserverStats {
  std::uint64_t usb_normal_bytes{0U};
  std::uint64_t usb_frames_valid{0U};
  std::uint64_t usb_msg20{0U};
  std::uint64_t usb_bad_crc{0U};
  std::uint64_t usb_invalid{0U};
  std::uint64_t usb_status_queued{0U};
  std::uint64_t usb_status_dropped{0U};

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
inline bool query_request_pending{false};
inline bool usb_report_active{false};
inline ControlCounterBaseline control_before{};

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
      usb_report_active = true;
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

inline void finish_usb_report() noexcept { usb_report_active = false; }

inline void observe_usb_ingress(
    std::uint8_t byte, vc_lora::FrameIngressStatus status,
    std::uint64_t) noexcept {
  ++stats.usb_normal_bytes;
  vc_lora::MavlinkFrame frame{};
  const vc_lora::MavlinkParseStatus parse_status = usb_parser.push(byte, frame);
  if (parse_status == vc_lora::MavlinkParseStatus::FrameReady) {
    ++stats.usb_frames_valid;
    if (frame.message_id == 20U) {
      ++stats.usb_msg20;
    }
  } else if (parse_status == vc_lora::MavlinkParseStatus::BadCrc) {
    ++stats.usb_bad_crc;
    ++stats.usb_invalid;
  } else if (parse_status == vc_lora::MavlinkParseStatus::BadLength ||
             parse_status == vc_lora::MavlinkParseStatus::UnsupportedMessage ||
             parse_status == vc_lora::MavlinkParseStatus::UnsupportedFlags) {
    ++stats.usb_invalid;
  }
  if (status == vc_lora::FrameIngressStatus::Queued) {
    ++stats.usb_status_queued;
  } else if (status == vc_lora::FrameIngressStatus::DroppedOverflow ||
             status == vc_lora::FrameIngressStatus::FailClosed) {
    ++stats.usb_status_dropped;
  }
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
