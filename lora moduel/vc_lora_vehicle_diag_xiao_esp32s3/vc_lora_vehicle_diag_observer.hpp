#pragma once

#if !defined(VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS)
#error "Vehicle diagnostic observer requires the diagnostics build"
#endif

#include <array>
#include <cstddef>
#include <cstdint>
#include <type_traits>

#include <vc_lora/late_uplink_recovery.hpp>
#include <vc_lora/mavlink_frame.hpp>
#include <vc_lora/tdd_vehicle.hpp>

namespace vc_lora_vehicle_diag_observer {

struct StreamStats {
  std::uint64_t bytes{0U};
  std::uint64_t frames{0U};
  std::uint64_t invalid{0U};
  std::uint64_t crc_errors{0U};
  std::uint64_t msg0{0U};
  std::uint64_t msg20{0U};
  std::uint64_t msg22{0U};
  std::uint64_t msg23{0U};
  std::uint64_t msg76{0U};
  std::uint64_t msg77{0U};
  std::uint64_t last_frame_ms{0U};
  std::uint32_t last_message_id{0U};
  std::uint16_t last_frame_size{0U};
  std::uint8_t last_system_id{0U};
  std::uint8_t last_component_id{0U};
};

constexpr std::size_t kVehicleTddStateCount = 7U;
constexpr std::uint8_t kNoVehicleTddState = 0xFFU;

struct OutsideWindowStateStats {
  std::array<std::uint64_t, kVehicleTddStateCount> bytes{};
  std::array<std::uint64_t, kVehicleTddStateCount> frames{};
  std::uint8_t last_state{kNoVehicleTddState};
  std::uint16_t last_cycle{0U};
  std::uint64_t last_ms{0U};
  std::uint8_t last_frame_timing_valid{0U};
  std::uint64_t last_frame_state_elapsed_ms{0U};
  std::uint64_t last_frame_state_remaining_ms{0U};
};

struct ControlStateStats {
  std::array<std::uint64_t, kVehicleTddStateCount> done{};
  std::array<std::uint64_t, kVehicleTddStateCount> idle{};
  std::uint8_t last_type{0U};
  std::uint8_t last_state{kNoVehicleTddState};
  std::uint16_t last_cycle{0U};
  std::uint64_t last_ms{0U};
};

struct VehicleStateTimingStats {
  std::uint8_t current_state{kNoVehicleTddState};
  std::uint16_t current_cycle{0U};
  std::uint64_t state_entered_ms{0U};
  std::uint8_t return_guard_seen{0U};
  std::uint64_t last_return_guard_entry_ms{0U};
};

constexpr std::size_t kTargetEventCapacity = 24U;

enum class TargetEventCode : std::uint8_t {
  QuarantineBegin = 1U,
  ApplicationFirst = 2U,
  ApplicationFrame = 3U,
  ReturnGuard = 4U,
  Terminal = 5U,
  TerminalResult = 6U,
  CommitPreflight = 7U,
  CommitTake = 8U,
  CommitEgress = 9U,
  D6Msg20 = 10U,
  D7Msg22 = 11U,
  Timeout = 12U,
  CycleAdvance = 13U,
  Abort = 14U,
};

enum class TargetAbortReason : std::uint8_t {
  None = 0U,
  IngestInvalid = 1U,
  IngestOverflow = 2U,
  TerminalDiscarded = 3U,
  CycleClosed = 4U,
  CommitFailure = 5U,
};

enum class TargetCommitPhase : std::uint8_t {
  Preflight = 1U,
  Take = 2U,
  Egress = 3U,
};

struct TargetEvent {
  std::uint64_t ms{0U};
  std::uint16_t cycle{0U};
  std::uint16_t a{0U};
  std::uint16_t b{0U};
  std::uint8_t code{0U};
  std::uint8_t state{kNoVehicleTddState};
};

// Frozen on the first CRC-valid MAVLink msg20 observed after boot. Later
// UL_IDLE cycles cannot overwrite this evidence. All fields and the event
// ring are POD so the query path can take one correlated two-stage snapshot.
struct TargetUplinkSnapshot {
  std::array<TargetEvent, kTargetEventCapacity> events{};
  std::uint64_t quarantine_begin_ms{0U};
  std::uint64_t first_application_ms{0U};
  std::uint64_t last_application_ms{0U};
  std::uint64_t done_ms{0U};
  std::uint64_t done_gap_ms{0U};
  std::uint64_t d6_msg20_ms{0U};
  std::uint64_t d7_msg22_ms{0U};
  std::uint64_t cycle_advance_ms{0U};
  std::uint64_t timeout_at_begin{0U};
  std::uint64_t timeout_delta{0U};
  std::uint16_t session_id{0U};
  std::uint16_t cycle_id{0U};
  std::uint16_t received_bytes{0U};
  std::uint16_t buffered_bytes{0U};
  std::uint16_t frame_count{0U};
  std::uint16_t done_session_id{0U};
  std::uint16_t done_cycle_id{0U};
  std::uint16_t done_guard_ms{0U};
  std::uint16_t done_window_ms{0U};
  std::uint16_t done_max_bytes{0U};
  std::uint16_t done_actual_bytes{0U};
  std::uint16_t commit_free_bytes{0U};
  std::uint16_t commit_bytes{0U};
  std::uint16_t commit_frames{0U};
  std::uint16_t d6_msg20{0U};
  std::uint16_t d7_msg22{0U};
  std::uint16_t event_head{0U};
  std::uint16_t event_count{0U};
  std::uint16_t event_overflow{0U};
  std::uint8_t latched{0U};
  std::uint8_t quarantine_begin_state{kNoVehicleTddState};
  std::uint8_t first_application_state{kNoVehicleTddState};
  std::uint8_t last_application_state{kNoVehicleTddState};
  std::uint8_t ingest_status{0U};
  std::uint8_t done_seen{0U};
  std::uint8_t done_version{0U};
  std::uint8_t done_type{0U};
  std::uint8_t done_state{kNoVehicleTddState};
  std::uint8_t terminal_status{0U};
  std::uint8_t commit_preflight_seen{0U};
  std::uint8_t commit_preflight_ok{0U};
  std::uint8_t commit_take_seen{0U};
  std::uint8_t commit_take_ok{0U};
  std::uint8_t commit_egress_seen{0U};
  std::uint8_t commit_egress_ok{0U};
  std::uint8_t late_window_seen{0U};
  std::uint8_t timeout_cancelled{0U};
  std::uint8_t abort_reason{0U};
};

static_assert(std::is_trivially_copyable<TargetUplinkSnapshot>::value,
              "target uplink snapshot must remain POD-copyable");

struct CandidateUplink {
  std::uint64_t quarantine_begin_ms{0U};
  std::uint64_t first_application_ms{0U};
  std::uint64_t last_application_ms{0U};
  std::uint64_t timeout_at_begin{0U};
  std::uint16_t session_id{0U};
  std::uint16_t cycle_id{0U};
  std::uint16_t received_bytes{0U};
  std::uint16_t buffered_bytes{0U};
  std::uint16_t frame_count{0U};
  std::uint8_t quarantine_begin_state{kNoVehicleTddState};
  std::uint8_t first_application_state{kNoVehicleTddState};
  std::uint8_t last_application_state{kNoVehicleTddState};
  std::uint8_t ingest_status{0U};
  bool active{false};
};

struct ObserverStats {
  std::uint64_t e220_raw_bytes{0U};
  std::uint64_t e220_raw_in_window{0U};
  std::uint64_t e220_raw_outside_window{0U};
  std::uint64_t last_e220_raw_ms{0U};
  StreamStats radio_in_window{};
  StreamStats radio_outside_window{};
  OutsideWindowStateStats radio_outside_by_state{};
  ControlStateStats control_by_state{};
  VehicleStateTimingStats state_timing{};
  StreamStats pixhawk_d6_accepted{};
  StreamStats pixhawk_d7_received{};
  TargetUplinkSnapshot target{};
};

inline ObserverStats stats{};
inline vc_lora::MavlinkStreamParser radio_in_parser{};
inline vc_lora::MavlinkStreamParser radio_out_parser{};
inline vc_lora::MavlinkStreamParser pixhawk_d6_parser{};
inline vc_lora::MavlinkStreamParser pixhawk_d7_parser{};
inline CandidateUplink candidate{};
inline vc_lora::MavlinkStreamParser candidate_parser{};

inline std::uint16_t narrow_u16(std::size_t value) noexcept {
  return static_cast<std::uint16_t>(
      value > 0xFFFFU ? 0xFFFFU : value);
}

inline void append_target_event(TargetEventCode code,
                                vc_lora::VehicleTddState state,
                                std::uint16_t cycle_id,
                                std::uint64_t now_ms,
                                std::uint16_t a = 0U,
                                std::uint16_t b = 0U) noexcept {
  auto& target = stats.target;
  if (target.latched == 0U) {
    return;
  }
  std::size_t index = 0U;
  if (target.event_count < kTargetEventCapacity) {
    index = (static_cast<std::size_t>(target.event_head) +
             target.event_count) % kTargetEventCapacity;
    ++target.event_count;
  } else {
    index = target.event_head;
    target.event_head = static_cast<std::uint16_t>(
        (static_cast<std::size_t>(target.event_head) + 1U) %
        kTargetEventCapacity);
    if (target.event_overflow != 0xFFFFU) {
      ++target.event_overflow;
    }
  }
  target.events[index] = {
      now_ms, cycle_id, a, b, static_cast<std::uint8_t>(code),
      static_cast<std::uint8_t>(state)};
}

inline bool target_matches(std::uint16_t session_id,
                           std::uint16_t cycle_id) noexcept {
  return stats.target.latched != 0U &&
         stats.target.session_id == session_id &&
         stats.target.cycle_id == cycle_id;
}

inline void set_target_abort(TargetAbortReason reason,
                             vc_lora::VehicleTddState state,
                             std::uint16_t cycle_id,
                             std::uint64_t now_ms) noexcept {
  auto& target = stats.target;
  if (target.latched == 0U || target.abort_reason != 0U ||
      target.commit_egress_ok != 0U) {
    return;
  }
  target.abort_reason = static_cast<std::uint8_t>(reason);
  append_target_event(TargetEventCode::Abort, state, cycle_id, now_ms,
                      target.abort_reason, 0U);
}

inline void observe_uplink_quarantine_begin(
    std::uint16_t session_id, std::uint16_t cycle_id,
    vc_lora::VehicleTddState state, std::uint64_t now_ms,
    std::uint64_t timeout_count) noexcept {
  candidate = {};
  candidate_parser.reset();
  candidate.active = true;
  candidate.session_id = session_id;
  candidate.cycle_id = cycle_id;
  candidate.quarantine_begin_ms = now_ms;
  candidate.quarantine_begin_state = static_cast<std::uint8_t>(state);
  candidate.timeout_at_begin = timeout_count;
}

inline void observe_uplink_ingest(
    std::uint8_t byte, vc_lora::LateUplinkIngestStatus status,
    std::size_t received_bytes, std::size_t buffered_bytes,
    std::uint16_t frame_count, vc_lora::VehicleTddState state,
    std::uint16_t cycle_id, std::uint64_t now_ms) noexcept {
  if (!candidate.active || candidate.cycle_id != cycle_id) {
    return;
  }
  if (candidate.first_application_ms == 0U) {
    candidate.first_application_ms = now_ms;
    candidate.first_application_state = static_cast<std::uint8_t>(state);
  }
  candidate.last_application_ms = now_ms;
  candidate.last_application_state = static_cast<std::uint8_t>(state);
  candidate.received_bytes = narrow_u16(received_bytes);
  candidate.buffered_bytes = narrow_u16(buffered_bytes);
  candidate.frame_count = frame_count;
  candidate.ingest_status = static_cast<std::uint8_t>(status);

  vc_lora::MavlinkFrame frame{};
  const vc_lora::MavlinkParseStatus parse_status =
      candidate_parser.push(byte, frame);
  if (parse_status == vc_lora::MavlinkParseStatus::FrameReady &&
      frame.message_id == 20U && stats.target.latched == 0U) {
    auto& target = stats.target;
    target = {};
    target.latched = 1U;
    target.session_id = candidate.session_id;
    target.cycle_id = candidate.cycle_id;
    target.quarantine_begin_ms = candidate.quarantine_begin_ms;
    target.quarantine_begin_state = candidate.quarantine_begin_state;
    target.first_application_ms = candidate.first_application_ms;
    target.first_application_state = candidate.first_application_state;
    target.last_application_ms = candidate.last_application_ms;
    target.last_application_state = candidate.last_application_state;
    target.timeout_at_begin = candidate.timeout_at_begin;
    target.received_bytes = candidate.received_bytes;
    target.buffered_bytes = candidate.buffered_bytes;
    target.frame_count = candidate.frame_count;
    target.ingest_status = candidate.ingest_status;
    append_target_event(
        TargetEventCode::QuarantineBegin,
        static_cast<vc_lora::VehicleTddState>(
            target.quarantine_begin_state),
        target.cycle_id, target.quarantine_begin_ms, target.session_id,
        0U);
    append_target_event(
        TargetEventCode::ApplicationFirst,
        static_cast<vc_lora::VehicleTddState>(
            target.first_application_state),
        target.cycle_id, target.first_application_ms, 1U, 0U);
    append_target_event(TargetEventCode::ApplicationFrame, state,
                        target.cycle_id, now_ms,
                        target.received_bytes, target.frame_count);
  }

  if (target_matches(candidate.session_id, candidate.cycle_id)) {
    auto& target = stats.target;
    target.last_application_ms = now_ms;
    target.last_application_state = static_cast<std::uint8_t>(state);
    target.received_bytes = narrow_u16(received_bytes);
    target.buffered_bytes = narrow_u16(buffered_bytes);
    target.frame_count = frame_count;
    target.ingest_status = static_cast<std::uint8_t>(status);
    if (status == vc_lora::LateUplinkIngestStatus::Invalid) {
      set_target_abort(TargetAbortReason::IngestInvalid, state, cycle_id,
                       now_ms);
    } else if (status == vc_lora::LateUplinkIngestStatus::Overflow) {
      set_target_abort(TargetAbortReason::IngestOverflow, state, cycle_id,
                       now_ms);
    }
  }
}

inline void observe_uplink_terminal(
    const vc_lora::TddControlMessage& message,
    vc_lora::LateUplinkTerminalStatus status,
    vc_lora::VehicleTddState state, std::uint16_t current_cycle,
    std::uint64_t now_ms) noexcept {
  if (!target_matches(message.session_id, message.cycle_id)) {
    return;
  }
  auto& target = stats.target;
  if (target.done_seen != 0U) {
    return;
  }
  target.done_seen = 1U;
  target.done_ms = now_ms;
  target.done_gap_ms =
      now_ms >= target.last_application_ms
          ? now_ms - target.last_application_ms
          : 0U;
  target.done_version = message.version;
  target.done_type = static_cast<std::uint8_t>(message.type);
  target.done_state = static_cast<std::uint8_t>(state);
  target.done_session_id = message.session_id;
  target.done_cycle_id = message.cycle_id;
  target.done_guard_ms = message.guard_ms;
  target.done_window_ms = message.window_ms;
  target.done_max_bytes = message.max_bytes;
  target.done_actual_bytes = message.actual_bytes;
  target.terminal_status = static_cast<std::uint8_t>(status);
  if ((status == vc_lora::LateUplinkTerminalStatus::Ready ||
       status == vc_lora::LateUplinkTerminalStatus::Idle) &&
      state == vc_lora::VehicleTddState::ReturnGuard) {
    target.timeout_cancelled = 1U;
  }
  append_target_event(TargetEventCode::Terminal, state, current_cycle,
                      now_ms, message.actual_bytes, message.cycle_id);
  append_target_event(TargetEventCode::TerminalResult, state, current_cycle,
                      now_ms, target.terminal_status,
                      narrow_u16(target.done_gap_ms));
  if (status == vc_lora::LateUplinkTerminalStatus::Discarded) {
    set_target_abort(TargetAbortReason::TerminalDiscarded, state,
                     current_cycle, now_ms);
  }
}

inline void observe_uplink_commit(
    TargetCommitPhase phase, bool succeeded, std::uint16_t session_id,
    std::uint16_t cycle_id, std::size_t free_bytes,
    std::size_t committed_bytes, std::uint16_t committed_frames,
    vc_lora::VehicleTddState state, std::uint64_t now_ms) noexcept {
  if (!target_matches(session_id, cycle_id)) {
    return;
  }
  auto& target = stats.target;
  target.commit_free_bytes = narrow_u16(free_bytes);
  target.commit_bytes = narrow_u16(committed_bytes);
  target.commit_frames = committed_frames;
  TargetEventCode code = TargetEventCode::CommitPreflight;
  if (phase == TargetCommitPhase::Preflight) {
    target.commit_preflight_seen = 1U;
    target.commit_preflight_ok = succeeded ? 1U : 0U;
  } else if (phase == TargetCommitPhase::Take) {
    target.commit_take_seen = 1U;
    target.commit_take_ok = succeeded ? 1U : 0U;
    code = TargetEventCode::CommitTake;
  } else {
    target.commit_egress_seen = 1U;
    target.commit_egress_ok = succeeded ? 1U : 0U;
    code = TargetEventCode::CommitEgress;
  }
  append_target_event(code, state, cycle_id, now_ms,
                      succeeded ? 1U : 0U,
                      narrow_u16(committed_bytes));
  if (!succeeded) {
    set_target_abort(TargetAbortReason::CommitFailure, state, cycle_id,
                     now_ms);
  }
}

inline void observe_uplink_abort(
    std::uint16_t session_id, std::uint16_t cycle_id,
    TargetAbortReason reason, vc_lora::VehicleTddState state,
    std::uint64_t now_ms) noexcept {
  if (target_matches(session_id, cycle_id)) {
    set_target_abort(reason, state, cycle_id, now_ms);
  }
}

inline void observe_uplink_controller(
    std::uint16_t session_id, std::uint16_t cycle_id,
    vc_lora::VehicleTddState state, bool late_window,
    std::uint64_t timeout_count, std::uint64_t now_ms) noexcept {
  auto& target = stats.target;
  if (target.latched == 0U || target.session_id != session_id) {
    return;
  }
  if (cycle_id == target.cycle_id && late_window) {
    if (target.late_window_seen == 0U) {
      target.late_window_seen = 1U;
      append_target_event(TargetEventCode::ReturnGuard, state, cycle_id,
                          now_ms, 1U, 0U);
    }
  }
  if (timeout_count > target.timeout_at_begin) {
    const std::uint64_t delta = timeout_count - target.timeout_at_begin;
    if (target.timeout_delta == 0U) {
      append_target_event(TargetEventCode::Timeout, state, cycle_id,
                          now_ms, narrow_u16(delta), 0U);
    }
    target.timeout_delta = delta;
  }
  if (cycle_id != target.cycle_id && target.cycle_advance_ms == 0U) {
    target.cycle_advance_ms = now_ms;
    append_target_event(TargetEventCode::CycleAdvance, state, cycle_id,
                        now_ms, target.cycle_id, cycle_id);
    if (target.done_seen == 0U && target.commit_egress_ok == 0U) {
      set_target_abort(TargetAbortReason::CycleClosed, state, cycle_id,
                       now_ms);
    }
  }
}

constexpr std::size_t vehicle_tdd_state_index(
    vc_lora::VehicleTddState state) noexcept {
  switch (state) {
    case vc_lora::VehicleTddState::DownlinkSend:
      return 0U;
    case vc_lora::VehicleTddState::DownlinkDrain:
      return 1U;
    case vc_lora::VehicleTddState::SendUlGrant:
      return 2U;
    case vc_lora::VehicleTddState::GrantDrain:
      return 3U;
    case vc_lora::VehicleTddState::UplinkGuard:
      return 4U;
    case vc_lora::VehicleTddState::UplinkReceive:
      return 5U;
    case vc_lora::VehicleTddState::ReturnGuard:
      return 6U;
  }
  return 0U;
}

inline void observe_vehicle_state(vc_lora::VehicleTddState state,
                                  std::uint16_t cycle_id,
                                  std::uint64_t now_ms) noexcept {
  auto& timing = stats.state_timing;
  const std::uint8_t state_value = static_cast<std::uint8_t>(state);
  if (timing.current_state == state_value &&
      timing.current_cycle == cycle_id) {
    return;
  }
  timing.current_state = state_value;
  timing.current_cycle = cycle_id;
  timing.state_entered_ms = now_ms;
  if (state == vc_lora::VehicleTddState::ReturnGuard) {
    timing.return_guard_seen = 1U;
    timing.last_return_guard_entry_ms = now_ms;
  }
}

inline void observe_radio_control(const vc_lora::TddControlMessage& message,
                                  vc_lora::VehicleTddState state,
                                  std::uint16_t cycle_id,
                                  std::uint64_t now_ms) noexcept {
  if (message.type != vc_lora::ControlType::UlDone &&
      message.type != vc_lora::ControlType::UlIdle) {
    return;
  }
  auto& control = stats.control_by_state;
  const std::size_t state_index = vehicle_tdd_state_index(state);
  if (message.type == vc_lora::ControlType::UlDone) {
    ++control.done[state_index];
  } else {
    ++control.idle[state_index];
  }
  control.last_type = static_cast<std::uint8_t>(message.type);
  control.last_state = static_cast<std::uint8_t>(state);
  control.last_cycle = cycle_id;
  control.last_ms = now_ms;
}

inline void count_message(StreamStats& target,
                          const vc_lora::MavlinkFrame& frame,
                          std::uint64_t now_ms) noexcept {
  ++target.frames;
  target.last_frame_ms = now_ms;
  target.last_message_id = frame.message_id;
  target.last_frame_size = static_cast<std::uint16_t>(frame.size);
  target.last_system_id = frame.system_id;
  target.last_component_id = frame.component_id;
  switch (frame.message_id) {
    case 0U:
      ++target.msg0;
      break;
    case 20U:
      ++target.msg20;
      break;
    case 22U:
      ++target.msg22;
      break;
    case 23U:
      ++target.msg23;
      break;
    case 76U:
      ++target.msg76;
      break;
    case 77U:
      ++target.msg77;
      break;
    default:
      break;
  }
}

inline bool observe_stream_byte(vc_lora::MavlinkStreamParser& parser,
                                StreamStats& target, std::uint8_t byte,
                                std::uint64_t now_ms) noexcept {
  ++target.bytes;
  vc_lora::MavlinkFrame frame{};
  const vc_lora::MavlinkParseStatus status = parser.push(byte, frame);
  switch (status) {
    case vc_lora::MavlinkParseStatus::FrameReady:
      count_message(target, frame, now_ms);
      return true;
    case vc_lora::MavlinkParseStatus::BadCrc:
      ++target.crc_errors;
      ++target.invalid;
      return false;
    case vc_lora::MavlinkParseStatus::BadLength:
    case vc_lora::MavlinkParseStatus::UnsupportedMessage:
    case vc_lora::MavlinkParseStatus::UnsupportedFlags:
      ++target.invalid;
      return false;
    case vc_lora::MavlinkParseStatus::NeedMore:
    case vc_lora::MavlinkParseStatus::Noise:
      return false;
  }
  return false;
}

inline void observe_e220_raw(std::uint8_t, bool in_receive_window,
                             std::uint64_t now_ms) noexcept {
  ++stats.e220_raw_bytes;
  stats.last_e220_raw_ms = now_ms;
  if (in_receive_window) {
    ++stats.e220_raw_in_window;
  } else {
    ++stats.e220_raw_outside_window;
  }
}

inline void observe_radio_application(std::uint8_t byte,
                                      bool in_receive_window,
                                      vc_lora::VehicleTddState state,
                                      std::uint16_t cycle_id,
                                      std::uint32_t return_guard_ms,
                                      std::uint64_t now_ms) noexcept {
  if (in_receive_window) {
    (void)observe_stream_byte(radio_in_parser, stats.radio_in_window, byte,
                              now_ms);
    return;
  }

  auto& state_stats = stats.radio_outside_by_state;
  const std::uint8_t state_value = static_cast<std::uint8_t>(state);
  if (state_stats.last_state != kNoVehicleTddState &&
      (state_stats.last_state != state_value ||
       state_stats.last_cycle != cycle_id)) {
    // Never assemble one diagnostic frame from bytes that arrived in
    // different TDD states or cycles.
    radio_out_parser.reset();
  }

  const std::size_t state_index = vehicle_tdd_state_index(state);
  ++state_stats.bytes[state_index];
  state_stats.last_state = state_value;
  state_stats.last_cycle = cycle_id;
  state_stats.last_ms = now_ms;
  if (observe_stream_byte(radio_out_parser, stats.radio_outside_window, byte,
                          now_ms)) {
    // A frame belongs to the state in which its final byte arrived.
    ++state_stats.frames[state_index];
    const auto& timing = stats.state_timing;
    const bool timing_valid =
        timing.current_state == state_value &&
        timing.current_cycle == cycle_id && now_ms >= timing.state_entered_ms;
    state_stats.last_frame_timing_valid = timing_valid ? 1U : 0U;
    if (timing_valid) {
      const std::uint64_t elapsed_ms = now_ms - timing.state_entered_ms;
      state_stats.last_frame_state_elapsed_ms = elapsed_ms;
      state_stats.last_frame_state_remaining_ms =
          state == vc_lora::VehicleTddState::ReturnGuard &&
                  elapsed_ms < return_guard_ms
              ? static_cast<std::uint64_t>(return_guard_ms) - elapsed_ms
              : 0U;
    } else {
      state_stats.last_frame_state_elapsed_ms = 0U;
      state_stats.last_frame_state_remaining_ms = 0U;
    }
  }
}

inline void observe_pixhawk_write(const std::uint8_t* bytes,
                                  std::size_t count,
                                  std::uint64_t now_ms) noexcept {
  if (bytes == nullptr) {
    return;
  }
  for (std::size_t index = 0U; index < count; ++index) {
    if (observe_stream_byte(pixhawk_d6_parser,
                            stats.pixhawk_d6_accepted,
                            bytes[index], now_ms) &&
        stats.pixhawk_d6_accepted.last_message_id == 20U &&
        stats.target.latched != 0U) {
      auto& target = stats.target;
      if (target.d6_msg20 != 0xFFFFU) {
        ++target.d6_msg20;
      }
      if (target.d6_msg20_ms == 0U) {
        target.d6_msg20_ms = now_ms;
        append_target_event(TargetEventCode::D6Msg20,
                            vc_lora::VehicleTddState::ReturnGuard,
                            target.cycle_id, now_ms,
                            target.d6_msg20, 0U);
      }
    }
  }
}

inline void observe_pixhawk_read(std::uint8_t byte,
                                 std::uint64_t now_ms) noexcept {
  if (observe_stream_byte(pixhawk_d7_parser,
                          stats.pixhawk_d7_received, byte, now_ms) &&
      stats.pixhawk_d7_received.last_message_id == 22U &&
      stats.target.latched != 0U && stats.target.d6_msg20 > 0U) {
    auto& target = stats.target;
    if (target.d7_msg22 != 0xFFFFU) {
      ++target.d7_msg22;
    }
    if (target.d7_msg22_ms == 0U) {
      target.d7_msg22_ms = now_ms;
      append_target_event(TargetEventCode::D7Msg22,
                          vc_lora::VehicleTddState::DownlinkSend,
                          target.cycle_id, now_ms,
                          target.d7_msg22, 0U);
    }
  }
}

}  // namespace vc_lora_vehicle_diag_observer
