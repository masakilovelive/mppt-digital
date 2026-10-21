#include "vc_lora/mavlink_scheduler.hpp"

#include <algorithm>
#include <limits>

namespace vc_lora {

MavlinkFrameScheduler::Priority MavlinkFrameScheduler::priority_for(
    std::uint32_t message_id) noexcept {
  if (message_id == 0U) {
    return Priority::Heartbeat;
  }
  switch (message_id) {
    case 4U:    // PING
    case 22U:   // PARAM_VALUE
    case 37U:   // MISSION_REQUEST_PARTIAL_LIST
    case 38U:   // MISSION_WRITE_PARTIAL_LIST
    case 39U:   // MISSION_ITEM
    case 40U:   // MISSION_REQUEST
    case 41U:   // MISSION_SET_CURRENT
    case 42U:   // MISSION_CURRENT
    case 43U:   // MISSION_REQUEST_LIST
    case 44U:   // MISSION_COUNT
    case 45U:   // MISSION_CLEAR_ALL
    case 46U:   // MISSION_ITEM_REACHED
    case 47U:   // MISSION_ACK
    case 51U:   // MISSION_REQUEST_INT
    case 53U:   // MISSION_CHECKSUM
    case 73U:   // MISSION_ITEM_INT
    case 77U:   // COMMAND_ACK
    case 110U:  // FILE_TRANSFER_PROTOCOL
    case 118U:  // LOG_ENTRY
    case 120U:  // LOG_DATA
    case 148U:  // AUTOPILOT_VERSION
    case 192U:  // MAG_CAL_REPORT
    case 242U:  // HOME_POSITION
    case 253U:  // STATUSTEXT
    case 320U:  // PARAM_EXT_REQUEST_READ
    case 321U:  // PARAM_EXT_REQUEST_LIST
    case 322U:  // PARAM_EXT_VALUE
    case 323U:  // PARAM_EXT_SET
    case 324U:  // PARAM_EXT_ACK
    case 345U:  // PARAM_ERROR
      return Priority::Urgent;
    default:
      break;
  }
  return Priority::Normal;
}

MavlinkFrameScheduler::RateBucket MavlinkFrameScheduler::rate_bucket_for(
    std::uint32_t message_id) noexcept {
  switch (message_id) {
    case 1U:  // SYS_STATUS
      return RateBucket::SysStatus;
    case 2U:  // SYSTEM_TIME
      return RateBucket::SystemTime;
    case 111U:  // TIMESYNC
      return RateBucket::TimeSync;
    case 24U:  // GPS_RAW_INT
      return RateBucket::Gps;
    case 30U:  // ATTITUDE
      return RateBucket::Attitude;
    case 33U:  // GLOBAL_POSITION_INT
      return RateBucket::GlobalPosition;
    case 74U:  // VFR_HUD
      return RateBucket::VfrHud;
    case 125U:  // POWER_STATUS
    case 147U:  // BATTERY_STATUS
      return RateBucket::Power;
    case 193U:  // EKF_STATUS_REPORT
    case 230U:  // ESTIMATOR_STATUS
    case 241U:  // VIBRATION
      return RateBucket::Estimator;
    case 162U:  // FENCE_STATUS
    case 191U:  // MAG_CAL_PROGRESS
    case 245U:  // EXTENDED_SYS_STATE
      return RateBucket::VehicleStatus;
    default:
      return RateBucket::None;
  }
}

bool MavlinkFrameScheduler::is_policy_filtered(
    std::uint32_t message_id) noexcept {
  switch (message_id) {
    case 27U:   // RAW_IMU
    case 29U:   // SCALED_PRESSURE
    case 35U:   // RC_CHANNELS_RAW
    case 36U:   // SERVO_OUTPUT_RAW
    case 62U:   // NAV_CONTROLLER_OUTPUT
    case 65U:   // RC_CHANNELS
    case 109U:  // RADIO_STATUS
    case 116U:  // SCALED_IMU2
    case 124U:  // GPS2_RAW
    case 150U:  // SENSOR_OFFSETS
    case 152U:  // MEMINFO
    case 163U:  // AHRS
    case 165U:  // HWSTATUS
    case 166U:  // RADIO
    case 168U:  // WIND
    case 178U:  // AHRS2
    case 182U:  // AHRS3
    case 194U:  // PID_TUNING
      return true;
    default:
      return false;
  }
}

std::size_t MavlinkFrameScheduler::find_free_slot() const noexcept {
  for (std::size_t index = 0; index < slots_.size(); ++index) {
    if (!slots_[index].occupied) {
      return index;
    }
  }
  return capacity();
}

std::size_t MavlinkFrameScheduler::choose_next_slot() const noexcept {
  std::size_t selected = capacity();
  for (std::size_t index = 0; index < slots_.size(); ++index) {
    if (!slots_[index].occupied) {
      continue;
    }
    if (selected == capacity() ||
        static_cast<std::uint8_t>(slots_[index].priority) <
            static_cast<std::uint8_t>(slots_[selected].priority) ||
        (slots_[index].priority == slots_[selected].priority &&
         slots_[index].order < slots_[selected].order)) {
      selected = index;
    }
  }
  return selected;
}

bool MavlinkFrameScheduler::has_pending_heartbeat() const noexcept {
  for (const Slot& slot : slots_) {
    if (slot.occupied && slot.frame.message_id == 0U) {
      return true;
    }
  }
  return false;
}

bool MavlinkFrameScheduler::heartbeat_tail_available() const noexcept {
  if (!has_pending_heartbeat()) {
    return false;
  }
  if (target_parameter_count_ == 0U || target_parameter_active_) {
    return true;
  }
  return !target_heartbeat_yielded_;
}

MavlinkHeartbeatCandidate
MavlinkFrameScheduler::heartbeat_candidate() const noexcept {
  MavlinkHeartbeatCandidate candidate{};
  std::size_t selected = capacity();

  if (active_frame_is_heartbeat()) {
    selected = active_index_;
  } else {
    for (std::size_t index = 0U; index < slots_.size(); ++index) {
      if (!slots_[index].occupied || slots_[index].frame.message_id != 0U) {
        continue;
      }
      if (selected == capacity() ||
          slots_[index].order < slots_[selected].order) {
        selected = index;
      }
    }
  }

  if (selected == capacity()) {
    return candidate;
  }

  const Slot& slot = slots_[selected];
  candidate.order = slot.order;
  candidate.enqueued_ms = slot.enqueued_ms;
  candidate.frame_bytes = slot.frame.size;
  candidate.active = selected == active_index_ && active_frame_is_heartbeat();
  candidate.active_started = candidate.active && active_offset_ > 0U;
  candidate.remaining_bytes =
      slot.frame.size - (candidate.active ? active_offset_ : 0U);
  candidate.present = true;
  candidate.tail_available = heartbeat_tail_available();
  return candidate;
}

bool MavlinkFrameScheduler::active_frame_is_heartbeat() const noexcept {
  return !parameter_active_ && !target_parameter_active_ &&
         active_index_ < capacity() &&
         slots_[active_index_].occupied &&
         slots_[active_index_].frame.message_id == 0U;
}

bool MavlinkFrameScheduler::active_frame_has_progress() const noexcept {
  if (target_parameter_active_) {
    return target_parameter_active_offset_ > 0U;
  }
  if (parameter_active_) {
    return parameter_active_offset_ > 0U;
  }
  return active_index_ < capacity() && slots_[active_index_].occupied &&
         active_offset_ > 0U;
}

std::size_t MavlinkFrameScheduler::choose_eviction(
    Priority incoming) const noexcept {
  std::size_t selected = capacity();
  for (std::size_t index = 0; index < slots_.size(); ++index) {
    if (!slots_[index].occupied || index == active_index_ ||
        static_cast<std::uint8_t>(slots_[index].priority) <=
            static_cast<std::uint8_t>(incoming)) {
      continue;
    }
    if (selected == capacity() ||
        static_cast<std::uint8_t>(slots_[index].priority) >
            static_cast<std::uint8_t>(slots_[selected].priority) ||
        (slots_[index].priority == slots_[selected].priority &&
         slots_[index].order < slots_[selected].order)) {
      selected = index;
    }
  }
  return selected;
}

void MavlinkFrameScheduler::drop_slot(std::size_t index) noexcept {
  if (index >= capacity() || !slots_[index].occupied) {
    return;
  }
  queued_bytes_ -= slots_[index].frame.size;
  slots_[index] = {};
  --slot_count_;
}

void MavlinkFrameScheduler::update_high_watermarks() noexcept {
  diagnostics_.max_queue_frames =
      std::max(diagnostics_.max_queue_frames, size());
  diagnostics_.max_queue_bytes =
      std::max(diagnostics_.max_queue_bytes, queued_bytes_);
}

MavlinkEnqueueStatus MavlinkFrameScheduler::enqueue_parameter_value(
    const MavlinkFrame& frame) noexcept {
  if (parameter_frame_count_ >= parameter_lengths_.size() ||
      frame.size > parameter_bytes_.size() - parameter_byte_count_) {
    ++diagnostics_.queue_drop_frames;
    diagnostics_.queue_drop_bytes += frame.size;
    return MavlinkEnqueueStatus::DroppedFull;
  }

  for (std::size_t index = 0U; index < frame.size; ++index) {
    parameter_bytes_[parameter_byte_tail_] = frame.bytes[index];
    parameter_byte_tail_ =
        (parameter_byte_tail_ + 1U) % parameter_bytes_.size();
  }
  parameter_lengths_[parameter_frame_tail_] =
      static_cast<std::uint16_t>(frame.size);
  parameter_frame_tail_ =
      (parameter_frame_tail_ + 1U) % parameter_lengths_.size();
  parameter_byte_count_ += frame.size;
  ++parameter_frame_count_;
  queued_bytes_ += frame.size;
  ++diagnostics_.frames_queued;
  update_high_watermarks();
  return MavlinkEnqueueStatus::Queued;
}

bool MavlinkFrameScheduler::can_begin_native_parameter_list() const noexcept {
  return !parameter_active_ && !target_parameter_active_ &&
         parameter_request_count_ == 0U && target_parameter_count_ == 0U &&
         (native_list_state_ == NativeParameterListState::Idle ||
          native_list_state_ == NativeParameterListState::Complete);
}

MavlinkParameterRequestStatus
MavlinkFrameScheduler::begin_native_parameter_list(
    const MavlinkFrame& frame) noexcept {
  return begin_native_parameter_list(frame, 0U);
}

bool MavlinkFrameScheduler::is_exact_stat_runtime(
    const MavlinkFrame& frame) noexcept {
  return stat_runtime_mismatch_mask(frame) == 0U;
}

std::uint16_t MavlinkFrameScheduler::stat_runtime_mismatch_mask(
    const MavlinkFrame& frame) noexcept {
  // Exact "STAT_RUNTIME" sentinel: the value and sequence are intentionally
  // variable, while every field that identifies its disposition is fixed.
  constexpr std::array<std::uint8_t, 16U> kStatRuntimeId{{
      'S', 'T', 'A', 'T', '_', 'R', 'U', 'N',
      'T', 'I', 'M', 'E', 0U, 0U, 0U, 0U}};
  std::uint16_t mismatch = 0U;
  if (frame.version != MavlinkVersion::V2) { mismatch |= 0x0001U; }
  if (frame.signed_frame) { mismatch |= 0x0002U; }
  if (frame.size != 37U) { mismatch |= 0x0004U; }
  if (frame.message_id != 22U) { mismatch |= 0x0008U; }
  if (frame.payload_length != 25U) { mismatch |= 0x0010U; }
  if (frame.system_id != 1U) { mismatch |= 0x0020U; }
  if (frame.component_id != 1U) { mismatch |= 0x0040U; }
  if (frame.message_id != 22U || frame.payload_length < 25U) {
    return mismatch;
  }
  const std::uint8_t* payload = frame.payload();
  const std::uint16_t count = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(payload[4U]) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(payload[5U]) << 8U));
  const std::uint16_t index = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(payload[6U]) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(payload[7U]) << 8U));
  if (count != 932U) { mismatch |= 0x0080U; }
  if (index != 0xFFFFU) { mismatch |= 0x0100U; }
  if (!std::equal(kStatRuntimeId.begin(), kStatRuntimeId.end(),
                  payload + 8U)) {
    mismatch |= 0x0200U;
  }
  if (payload[24U] != 6U) { mismatch |= 0x0400U; }
  return mismatch;
}

void MavlinkFrameScheduler::latch_native_list_unexpected(
    const MavlinkFrame& frame, std::uint8_t reason,
    std::uint64_t now_ms) noexcept {
  if (diagnostics_.native_list_unexpected_latched != 0U) {
    return;
  }
  const std::uint8_t* payload = frame.payload();
  diagnostics_.native_list_unexpected_latched = 1U;
  diagnostics_.native_list_unexpected_reason = reason;
  diagnostics_.native_list_unexpected_version =
      static_cast<std::uint8_t>(frame.version);
  diagnostics_.native_list_unexpected_signed = frame.signed_frame ? 1U : 0U;
  diagnostics_.native_list_unexpected_frame_size =
      static_cast<std::uint16_t>(frame.size);
  diagnostics_.native_list_unexpected_payload_length = frame.payload_length;
  diagnostics_.native_list_unexpected_system_id = frame.system_id;
  diagnostics_.native_list_unexpected_component_id = frame.component_id;
  diagnostics_.native_list_unexpected_sequence = frame.sequence;
  diagnostics_.native_list_unexpected_mismatch_mask =
      stat_runtime_mismatch_mask(frame);
  diagnostics_.native_list_unexpected_value_bits =
      static_cast<std::uint32_t>(payload[0U]) |
      (static_cast<std::uint32_t>(payload[1U]) << 8U) |
      (static_cast<std::uint32_t>(payload[2U]) << 16U) |
      (static_cast<std::uint32_t>(payload[3U]) << 24U);
  diagnostics_.native_list_unexpected_count = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(payload[4U]) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(payload[5U]) << 8U));
  diagnostics_.native_list_unexpected_index = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(payload[6U]) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(payload[7U]) << 8U));
  std::copy_n(payload + 8U,
              diagnostics_.native_list_unexpected_parameter_id.size(),
              diagnostics_.native_list_unexpected_parameter_id.begin());
  diagnostics_.native_list_unexpected_type = payload[24U];
  diagnostics_.native_list_unexpected_ms = now_ms;
}

void MavlinkFrameScheduler::classify_cancelled_native_backlog(
    std::uint64_t now_ms) noexcept {
  std::size_t frame_cursor = parameter_frame_head_;
  std::size_t byte_cursor = parameter_byte_head_;
  for (std::size_t logical = 0U; logical < parameter_frame_count_; ++logical) {
    const std::size_t frame_size = parameter_lengths_[frame_cursor];
    MavlinkFrame wire{};
    if (frame_size <= wire.bytes.size()) {
      for (std::size_t offset = 0U; offset < frame_size; ++offset) {
        wire.bytes[offset] =
            parameter_bytes_[(byte_cursor + offset) % parameter_bytes_.size()];
      }
    }
    MavlinkFrame decoded{};
    const bool decoded_ok =
        frame_size <= wire.bytes.size() &&
        validate_mavlink_frame(wire.bytes.data(), frame_size, decoded) ==
            MavlinkParseStatus::FrameReady;
    if (decoded_ok && is_exact_stat_runtime(decoded)) {
      ++diagnostics_.native_list_stat_runtime_frames_cancelled;
      diagnostics_.native_list_stat_runtime_bytes_cancelled += frame_size;
    } else {
      ++diagnostics_.native_list_other_frames_cancelled;
      diagnostics_.native_list_other_bytes_cancelled += frame_size;
      if (decoded_ok) {
        latch_native_list_unexpected(decoded, 1U, now_ms);
      } else {
        ++diagnostics_.native_list_stale_classification_errors;
        if (diagnostics_.native_list_unexpected_latched == 0U) {
          diagnostics_.native_list_unexpected_latched = 1U;
          diagnostics_.native_list_unexpected_reason = 3U;
          diagnostics_.native_list_unexpected_frame_size =
              static_cast<std::uint16_t>(frame_size);
          diagnostics_.native_list_unexpected_ms = now_ms;
        }
      }
    }
    byte_cursor = (byte_cursor + frame_size) % parameter_bytes_.size();
    frame_cursor = (frame_cursor + 1U) % parameter_lengths_.size();
  }
}

void MavlinkFrameScheduler::record_native_list_filtered(
    const MavlinkFrame& frame, std::uint64_t now_ms) noexcept {
  if (!is_exact_stat_runtime(frame)) {
    ++diagnostics_.native_list_other_frames_filtered;
    latch_native_list_unexpected(frame, 2U, now_ms);
    return;
  }
  const std::uint64_t previous_count =
      diagnostics_.native_list_stat_runtime_frames_filtered;
  ++diagnostics_.native_list_stat_runtime_frames_filtered;
  if (previous_count == 0U) {
    diagnostics_.native_list_stat_runtime_first_filter_ms = now_ms;
    diagnostics_.native_list_stat_runtime_last_filter_ms = now_ms;
    return;
  }
  const std::uint64_t previous_ms =
      diagnostics_.native_list_stat_runtime_last_filter_ms;
  if (now_ms < previous_ms) {
    ++diagnostics_.native_list_stat_runtime_filter_time_regressions;
    diagnostics_.native_list_stat_runtime_last_filter_ms = now_ms;
    return;
  }
  const std::uint64_t gap_ms = now_ms - previous_ms;
  if (previous_count == 1U ||
      gap_ms < diagnostics_.native_list_stat_runtime_min_filter_gap_ms) {
    diagnostics_.native_list_stat_runtime_min_filter_gap_ms = gap_ms;
  }
  diagnostics_.native_list_stat_runtime_last_filter_ms = now_ms;
}

MavlinkParameterRequestStatus
MavlinkFrameScheduler::begin_native_parameter_list(
    const MavlinkFrame& frame, std::uint64_t now_ms) noexcept {
  MavlinkFrame decoded{};
  if (validate_mavlink_frame(frame.bytes.data(), frame.size, decoded) !=
          MavlinkParseStatus::FrameReady ||
      decoded.message_id != 21U || decoded.payload_length != 2U ||
      decoded.signed_frame || decoded.payload()[0U] == 0U ||
      decoded.payload()[1U] == 0U) {
    ++diagnostics_.parameter_request_invalid_frames;
    return MavlinkParameterRequestStatus::Invalid;
  }

  const bool live_native_generation =
      native_list_state_ == NativeParameterListState::AwaitingFirst ||
      native_list_state_ == NativeParameterListState::Streaming;
  if (live_native_generation &&
      native_list_target_system_ == decoded.payload()[0U] &&
      native_list_target_component_ == decoded.payload()[1U]) {
    ++diagnostics_.parameter_request_duplicates;
    return MavlinkParameterRequestStatus::Duplicate;
  }
  if (!can_begin_native_parameter_list()) {
    ++diagnostics_.native_list_fence_busy;
    return MavlinkParameterRequestStatus::Busy;
  }

  classify_cancelled_native_backlog(now_ms);
  diagnostics_.native_list_stale_frames_cancelled +=
      parameter_frame_count_;
  diagnostics_.native_list_stale_bytes_cancelled += parameter_byte_count_;
  queued_bytes_ -= parameter_byte_count_;
  parameter_byte_head_ = 0U;
  parameter_byte_tail_ = 0U;
  parameter_byte_count_ = 0U;
  parameter_frame_head_ = 0U;
  parameter_frame_tail_ = 0U;
  parameter_frame_count_ = 0U;
  parameter_active_offset_ = 0U;
  parameter_active_ = false;

  native_list_state_ = NativeParameterListState::AwaitingFirst;
  native_list_expected_index_ = 0U;
  native_list_parameter_count_ = 0U;
  native_list_target_system_ = decoded.payload()[0U];
  native_list_target_component_ = decoded.payload()[1U];
  ++diagnostics_.native_list_fences_committed;
  return MavlinkParameterRequestStatus::Remembered;
}

MavlinkBulkHeartbeatPolicyStatus
MavlinkFrameScheduler::begin_bulk_heartbeat_policy(
    std::uint64_t now_ms) noexcept {
  if (bulk_heartbeat_policy_active_) {
    return MavlinkBulkHeartbeatPolicyStatus::AlreadyActive;
  }
  if (has_active_frame()) {
    ++diagnostics_.bulk_heartbeat_start_blocked_active;
    return MavlinkBulkHeartbeatPolicyStatus::BlockedByActiveFrame;
  }

  std::size_t newest = capacity();
  for (std::size_t index = 0U; index < slots_.size(); ++index) {
    if (!slots_[index].occupied || slots_[index].frame.message_id != 0U) {
      continue;
    }
    ++diagnostics_.bulk_heartbeat_prestart_seen_frames;
    diagnostics_.bulk_heartbeat_prestart_seen_bytes +=
        slots_[index].frame.size;
    if (newest == capacity() ||
        slots_[index].order > slots_[newest].order) {
      newest = index;
    }
  }

  if (newest < capacity()) {
    ++diagnostics_.bulk_heartbeat_prestart_retained_frames;
    diagnostics_.bulk_heartbeat_prestart_retained_bytes +=
        slots_[newest].frame.size;
  }
  for (std::size_t index = 0U; index < slots_.size(); ++index) {
    if (index == newest || !slots_[index].occupied ||
        slots_[index].frame.message_id != 0U) {
      continue;
    }
    ++diagnostics_.bulk_heartbeat_prestart_coalesced_frames;
    diagnostics_.bulk_heartbeat_prestart_coalesced_bytes +=
        slots_[index].frame.size;
    drop_slot(index);
  }

  bulk_heartbeat_last_admitted_ms_ = now_ms;
  bulk_heartbeat_policy_active_ = true;
  ++diagnostics_.bulk_heartbeat_sessions_started;
  return MavlinkBulkHeartbeatPolicyStatus::Started;
}

MavlinkBulkHeartbeatPolicyStatus
MavlinkFrameScheduler::end_bulk_heartbeat_policy() noexcept {
  if (!bulk_heartbeat_policy_active_) {
    return MavlinkBulkHeartbeatPolicyStatus::NotActive;
  }
  bulk_heartbeat_policy_active_ = false;
  bulk_heartbeat_last_admitted_ms_ = 0U;
  ++diagnostics_.bulk_heartbeat_sessions_ended;
  return MavlinkBulkHeartbeatPolicyStatus::Ended;
}

MavlinkEnqueueStatus
MavlinkFrameScheduler::enqueue_native_parameter_value(
    const MavlinkFrame& frame, std::uint64_t now_ms) noexcept {
  const std::uint8_t* payload = frame.payload();
  const std::uint16_t count = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(payload[4U]) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(payload[5U]) << 8U));
  const std::uint16_t index = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(payload[6U]) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(payload[7U]) << 8U));

  bool expected = false;
  if (native_list_state_ == NativeParameterListState::AwaitingFirst) {
    expected = index == 0U && count > 0U;
  } else if (native_list_state_ == NativeParameterListState::Streaming) {
    expected = count == native_list_parameter_count_ &&
               index == native_list_expected_index_ && index < count;
  }
  if (!expected) {
    ++diagnostics_.native_list_stale_frames_filtered;
    record_native_list_filtered(frame, now_ms);
    ++diagnostics_.policy_filtered_frames;
    diagnostics_.policy_filtered_bytes += frame.size;
    if (native_list_state_ == NativeParameterListState::Streaming &&
        (count != native_list_parameter_count_ ||
         index > native_list_expected_index_)) {
      ++diagnostics_.native_list_sequence_failures;
    }
    return MavlinkEnqueueStatus::Filtered;
  }

  const MavlinkEnqueueStatus status = enqueue_parameter_value(frame);
  if (status != MavlinkEnqueueStatus::Queued) {
    return status;
  }
  ++diagnostics_.native_list_frames_queued;
  if (native_list_state_ == NativeParameterListState::AwaitingFirst) {
    native_list_parameter_count_ = count;
  }
  if (static_cast<std::uint32_t>(index) + 1U >= count) {
    native_list_state_ = NativeParameterListState::Complete;
    native_list_expected_index_ = index;
  } else {
    native_list_state_ = NativeParameterListState::Streaming;
    native_list_expected_index_ = static_cast<std::uint16_t>(index + 1U);
  }
  return MavlinkEnqueueStatus::Queued;
}

bool MavlinkFrameScheduler::same_parameter_request(
    const ParameterRequestIdentity& left,
    const ParameterRequestIdentity& right) noexcept {
  if (left.parameter_index != right.parameter_index ||
      left.target_system != right.target_system ||
      left.target_component != right.target_component) {
    return false;
  }
  // MAVLink PARAM_REQUEST_READ defines param_id as unused in index mode.
  // Its bytes may be stale or differ across a retransmission and therefore
  // cannot create a second request identity for the same target/index.
  return left.parameter_index != 0xFFFFU ||
         left.parameter_id == right.parameter_id;
}

bool MavlinkFrameScheduler::parameter_response_matches(
    const ParameterRequestIdentity& request,
    const MavlinkFrame& response) noexcept {
  if (response.message_id != 22U || response.payload_length != 25U ||
      // MAVLink target 0 is the broadcast wildcard for that address field.
      (request.target_system != 0U &&
       request.target_system != response.system_id) ||
      (request.target_component != 0U &&
       request.target_component != response.component_id)) {
    return false;
  }
  const std::uint8_t* payload = response.payload();
  const std::uint16_t response_index = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(payload[6U]) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(payload[7U]) << 8U));
  if (request.parameter_index != 0xFFFFU) {
    return response_index == request.parameter_index;
  }
  return std::equal(request.parameter_id.begin(), request.parameter_id.end(),
                    payload + 8U);
}

std::size_t MavlinkFrameScheduler::find_parameter_request(
    const MavlinkFrame& response,
    ParameterRequestState state) const noexcept {
  for (std::size_t index = 0U; index < parameter_requests_.size(); ++index) {
    if (parameter_requests_[index].state == state &&
        parameter_response_matches(parameter_requests_[index], response)) {
      return index;
    }
  }
  return parameter_request_capacity();
}

void MavlinkFrameScheduler::release_parameter_request(
    std::size_t request_slot) noexcept {
  if (request_slot >= parameter_requests_.size() ||
      parameter_requests_[request_slot].state ==
          ParameterRequestState::Empty) {
    return;
  }
  parameter_requests_[request_slot] = {};
  --parameter_request_count_;
}

MavlinkEnqueueStatus MavlinkFrameScheduler::enqueue_target_parameter_value(
    const MavlinkFrame& frame, std::size_t request_slot) noexcept {
  // One request slot remains owned until its target frame completes, so the
  // equal-sized priority lane cannot overflow without an internal invariant
  // violation. Fail closed and retain the request if that invariant changes.
  if (request_slot >= parameter_requests_.size() ||
      parameter_requests_[request_slot].state !=
          ParameterRequestState::Pending ||
      target_parameter_count_ >= target_parameter_frames_.size()) {
    ++diagnostics_.queue_drop_frames;
    diagnostics_.queue_drop_bytes += frame.size;
    return MavlinkEnqueueStatus::DroppedFull;
  }

  const bool first_target = target_parameter_count_ == 0U;
  target_parameter_frames_[target_parameter_tail_].frame = frame;
  target_parameter_frames_[target_parameter_tail_].request_slot = request_slot;
  target_parameter_tail_ =
      (target_parameter_tail_ + 1U) % target_parameter_frames_.size();
  ++target_parameter_count_;
  parameter_requests_[request_slot].state =
      ParameterRequestState::ResponseQueued;
  queued_bytes_ += frame.size;
  ++diagnostics_.frames_queued;
  ++diagnostics_.target_parameter_frames_queued;
  if (first_target) {
    target_heartbeat_yielded_ = active_frame_is_heartbeat();
    if (target_heartbeat_yielded_) {
      ++diagnostics_.target_heartbeat_yields;
    }
  }
  update_high_watermarks();
  return MavlinkEnqueueStatus::Queued;
}

MavlinkParameterRequestStatus
MavlinkFrameScheduler::remember_parameter_request(
    const MavlinkFrame& frame) noexcept {
  MavlinkFrame decoded{};
  if (validate_mavlink_frame(frame.bytes.data(), frame.size, decoded) !=
      MavlinkParseStatus::FrameReady) {
    ++diagnostics_.parameter_request_invalid_frames;
    return MavlinkParameterRequestStatus::Invalid;
  }
  if (decoded.message_id != 20U) {
    return MavlinkParameterRequestStatus::Ignored;
  }
  ++diagnostics_.parameter_requests_observed;
  if (decoded.payload_length < 4U || decoded.payload_length > 20U) {
    ++diagnostics_.parameter_request_invalid_frames;
    return MavlinkParameterRequestStatus::Invalid;
  }

  const std::uint8_t* payload = decoded.payload();
  ParameterRequestIdentity incoming{};
  incoming.parameter_index = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(payload[0U]) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(payload[1U]) << 8U));
  incoming.target_system = payload[2U];
  incoming.target_component = payload[3U];
  for (std::size_t index = 0U; index < incoming.parameter_id.size(); ++index) {
    incoming.parameter_id[index] =
        decoded.payload_byte_or_zero(4U + index);
  }
  incoming.state = ParameterRequestState::Pending;
  if (incoming.parameter_index == 0xFFFFU &&
      std::all_of(incoming.parameter_id.begin(), incoming.parameter_id.end(),
                  [](std::uint8_t byte) { return byte == 0U; })) {
    ++diagnostics_.parameter_request_invalid_frames;
    return MavlinkParameterRequestStatus::Invalid;
  }

  for (const ParameterRequestIdentity& existing : parameter_requests_) {
    if (existing.state != ParameterRequestState::Empty &&
        same_parameter_request(existing, incoming)) {
      ++diagnostics_.parameter_request_duplicates;
      return MavlinkParameterRequestStatus::Duplicate;
    }
  }
  for (ParameterRequestIdentity& destination : parameter_requests_) {
    if (destination.state == ParameterRequestState::Empty) {
      destination = incoming;
      ++parameter_request_count_;
      ++diagnostics_.parameter_requests_remembered;
      return MavlinkParameterRequestStatus::Remembered;
    }
  }
  ++diagnostics_.parameter_request_tracker_overflows;
  return MavlinkParameterRequestStatus::Full;
}

bool MavlinkFrameScheduler::parameter_value_precedes(
    std::size_t slot_index) const noexcept {
  if (parameter_frame_count_ == 0U) {
    return false;
  }
  if (slot_index >= capacity()) {
    return true;
  }
  if (slots_[slot_index].priority == Priority::Heartbeat) {
    return false;
  }
  return slots_[slot_index].priority == Priority::Normal ||
         slots_[slot_index].frame.message_id == 42U;
}

MavlinkEnqueueStatus MavlinkFrameScheduler::enqueue_bulk_heartbeat(
    const MavlinkFrame& frame, std::uint64_t now_ms) noexcept {
  ++diagnostics_.bulk_heartbeat_input_frames;
  diagnostics_.bulk_heartbeat_input_bytes += frame.size;

  const bool time_regressed = now_ms < bulk_heartbeat_last_admitted_ms_;
  const bool too_early =
      !time_regressed &&
      now_ms - bulk_heartbeat_last_admitted_ms_ <
          bulk_heartbeat_admission_interval_ms();
  if (time_regressed || too_early) {
    ++diagnostics_.bulk_heartbeat_rate_violation_frames;
    diagnostics_.bulk_heartbeat_rate_violation_bytes += frame.size;
    ++diagnostics_.bulk_heartbeat_filtered_frames;
    diagnostics_.bulk_heartbeat_filtered_bytes += frame.size;
    ++diagnostics_.policy_filtered_frames;
    diagnostics_.policy_filtered_bytes += frame.size;
    if (time_regressed) {
      ++diagnostics_.bulk_heartbeat_time_regressions;
    }
    return MavlinkEnqueueStatus::Filtered;
  }

  std::size_t pending = capacity();
  for (std::size_t index = 0U; index < slots_.size(); ++index) {
    if (index == active_index_ || !slots_[index].occupied ||
        slots_[index].frame.message_id != 0U) {
      continue;
    }
    if (pending == capacity() ||
        slots_[index].order > slots_[pending].order) {
      pending = index;
    }
  }

  if (pending < capacity()) {
    ++diagnostics_.bulk_heartbeat_runtime_coalesced_frames;
    diagnostics_.bulk_heartbeat_runtime_coalesced_bytes +=
        slots_[pending].frame.size;
    queued_bytes_ -= slots_[pending].frame.size;
    slots_[pending].frame = frame;
    slots_[pending].order = next_order_++;
    slots_[pending].enqueued_ms = now_ms;
    slots_[pending].priority = Priority::Heartbeat;
    queued_bytes_ += frame.size;
    ++diagnostics_.frames_queued;
    ++diagnostics_.bulk_heartbeat_admitted_frames;
    diagnostics_.bulk_heartbeat_admitted_bytes += frame.size;
    bulk_heartbeat_last_admitted_ms_ = now_ms;
    update_high_watermarks();
    return MavlinkEnqueueStatus::Queued;
  }

  std::size_t destination = find_free_slot();
  if (destination == capacity()) {
    destination = choose_eviction(Priority::Heartbeat);
    if (destination == capacity()) {
      ++diagnostics_.queue_drop_frames;
      diagnostics_.queue_drop_bytes += frame.size;
      return MavlinkEnqueueStatus::DroppedFull;
    }
    ++diagnostics_.queue_drop_frames;
    diagnostics_.queue_drop_bytes += slots_[destination].frame.size;
    drop_slot(destination);
  }

  Slot& slot = slots_[destination];
  slot.frame = frame;
  slot.order = next_order_++;
  slot.enqueued_ms = now_ms;
  slot.priority = Priority::Heartbeat;
  slot.occupied = true;
  ++slot_count_;
  queued_bytes_ += frame.size;
  ++diagnostics_.frames_queued;
  ++diagnostics_.bulk_heartbeat_admitted_frames;
  diagnostics_.bulk_heartbeat_admitted_bytes += frame.size;
  bulk_heartbeat_last_admitted_ms_ = now_ms;
  update_high_watermarks();
  return MavlinkEnqueueStatus::Queued;
}

MavlinkEnqueueStatus MavlinkFrameScheduler::enqueue_impl(
    const MavlinkFrame& frame, std::uint64_t now_ms,
    bool apply_rate_limit) noexcept {
  MavlinkFrame decoded{};
  const MavlinkParseStatus validation =
      validate_mavlink_frame(frame.bytes.data(), frame.size, decoded);
  if (validation != MavlinkParseStatus::FrameReady) {
    ++diagnostics_.invalid_frames;
    return MavlinkEnqueueStatus::Invalid;
  }
  ++diagnostics_.frames_ingested;

  if (decoded.message_id == 0U) {
    heartbeat_seen_ = true;
    if (bulk_heartbeat_policy_active_) {
      return enqueue_bulk_heartbeat(decoded, now_ms);
    }
  }

  if (is_policy_filtered(decoded.message_id)) {
    ++diagnostics_.policy_filtered_frames;
    diagnostics_.policy_filtered_bytes += decoded.size;
    if (decoded.message_id == 194U) {
      ++diagnostics_.msg194_frames_filtered;
      diagnostics_.msg194_bytes_filtered += decoded.size;
    }
    return MavlinkEnqueueStatus::Filtered;
  }

  const RateBucket rate_bucket = rate_bucket_for(decoded.message_id);
  if (apply_rate_limit && rate_bucket != RateBucket::None) {
    const RateBucketState& state =
        rate_buckets_[static_cast<std::size_t>(rate_bucket)];
    if (state.initialized &&
        (now_ms < state.last_queued_ms ||
         now_ms - state.last_queued_ms < 1000U)) {
      ++diagnostics_.rate_limited_frames;
      diagnostics_.rate_limited_bytes += decoded.size;
      return MavlinkEnqueueStatus::Filtered;
    }
  }

  if (decoded.message_id == 22U) {
    // A response may match two distinct requests (for example an ID request
    // overlapping an index request). Give every still-Pending owner one
    // response before treating a later arrival as a queued duplicate.
    const std::size_t pending_request = find_parameter_request(
        decoded, ParameterRequestState::Pending);
    if (pending_request < parameter_request_capacity()) {
      return enqueue_target_parameter_value(decoded, pending_request);
    }
    const std::size_t queued_request = find_parameter_request(
        decoded, ParameterRequestState::ResponseQueued);
    if (queued_request < parameter_request_capacity()) {
      ++diagnostics_.target_parameter_duplicate_frames;
      ++diagnostics_.policy_filtered_frames;
      diagnostics_.policy_filtered_bytes += decoded.size;
      return MavlinkEnqueueStatus::Filtered;
    }
    if (native_list_state_ != NativeParameterListState::Idle &&
        decoded.system_id == native_list_target_system_ &&
        decoded.component_id == native_list_target_component_) {
      return enqueue_native_parameter_value(decoded, now_ms);
    }
    return enqueue_parameter_value(decoded);
  }

  const Priority priority = priority_for(decoded.message_id);
  std::size_t destination = find_free_slot();
  if (destination == capacity()) {
    destination = choose_eviction(priority);
    if (destination == capacity()) {
      ++diagnostics_.queue_drop_frames;
      diagnostics_.queue_drop_bytes += decoded.size;
      return MavlinkEnqueueStatus::DroppedFull;
    }
    ++diagnostics_.queue_drop_frames;
    diagnostics_.queue_drop_bytes += slots_[destination].frame.size;
    drop_slot(destination);
  }

  Slot& slot = slots_[destination];
  slot.frame = decoded;
  slot.order = next_order_++;
  slot.enqueued_ms = now_ms;
  slot.priority = priority;
  slot.occupied = true;
  ++slot_count_;
  queued_bytes_ += decoded.size;
  ++diagnostics_.frames_queued;
  if (apply_rate_limit && rate_bucket != RateBucket::None) {
    RateBucketState& state =
        rate_buckets_[static_cast<std::size_t>(rate_bucket)];
    state.last_queued_ms = now_ms;
    state.initialized = true;
  }
  update_high_watermarks();
  return MavlinkEnqueueStatus::Queued;
}

MavlinkEnqueueStatus MavlinkFrameScheduler::enqueue(
    const MavlinkFrame& frame) noexcept {
  return enqueue_impl(frame, 0U, true);
}

MavlinkEnqueueStatus MavlinkFrameScheduler::enqueue(
    const MavlinkFrame& frame, std::uint64_t now_ms) noexcept {
  return enqueue_impl(frame, now_ms, true);
}

MavlinkEnqueueStatus MavlinkFrameScheduler::ingest_byte(
    std::uint8_t byte) noexcept {
  MavlinkFrame frame{};
  const MavlinkParseStatus status = parser_.push(byte, frame);
  if (status == MavlinkParseStatus::FrameReady) {
    return enqueue_impl(frame, 0U, true);
  }
  if (status == MavlinkParseStatus::BadLength ||
      status == MavlinkParseStatus::BadCrc ||
      status == MavlinkParseStatus::UnsupportedMessage ||
      status == MavlinkParseStatus::UnsupportedFlags) {
    ++diagnostics_.invalid_frames;
    return MavlinkEnqueueStatus::Invalid;
  }
  return MavlinkEnqueueStatus::NeedMore;
}

MavlinkEnqueueStatus MavlinkFrameScheduler::ingest_byte(
    std::uint8_t byte, std::uint64_t now_ms) noexcept {
  MavlinkFrame frame{};
  const MavlinkParseStatus status = parser_.push(byte, frame);
  if (status == MavlinkParseStatus::FrameReady) {
    return enqueue(frame, now_ms);
  }
  if (status == MavlinkParseStatus::BadLength ||
      status == MavlinkParseStatus::BadCrc ||
      status == MavlinkParseStatus::UnsupportedMessage ||
      status == MavlinkParseStatus::UnsupportedFlags) {
    ++diagnostics_.invalid_frames;
    return MavlinkEnqueueStatus::Invalid;
  }
  return MavlinkEnqueueStatus::NeedMore;
}

MavlinkBulkPeekStatus MavlinkFrameScheduler::peek_bulk_frame(
    std::uint8_t* output, std::size_t max_size,
    std::size_t& output_size) noexcept {
  output_size = 0U;
  if (output == nullptr || max_size < kMavlinkMaxFrameBytes) {
    return MavlinkBulkPeekStatus::InvalidArgument;
  }

  if (has_active_frame()) {
    if (active_frame_has_progress() ||
        (!target_parameter_active_ && !parameter_active_ &&
         !active_frame_is_heartbeat())) {
      return MavlinkBulkPeekStatus::BlockedByActiveFrame;
    }
  } else {
    std::size_t heartbeat = capacity();
    for (std::size_t index = 0U; index < slots_.size(); ++index) {
      if (!slots_[index].occupied || slots_[index].frame.message_id != 0U) {
        continue;
      }
      if (heartbeat == capacity() ||
          slots_[index].order < slots_[heartbeat].order) {
        heartbeat = index;
      }
    }

    if (heartbeat < capacity()) {
      active_index_ = heartbeat;
      active_offset_ = 0U;
      if (target_parameter_count_ > 0U) {
        target_heartbeat_yielded_ = true;
        ++diagnostics_.target_heartbeat_yields;
      }
    } else if (target_parameter_count_ > 0U) {
      target_parameter_active_ = true;
      target_parameter_active_offset_ = 0U;
      ++diagnostics_.target_parameter_selections;
    } else if (parameter_frame_count_ > 0U) {
      parameter_active_ = true;
      parameter_active_offset_ = 0U;
    } else {
      return empty() ? MavlinkBulkPeekStatus::Empty
                     : MavlinkBulkPeekStatus::NoEligibleFrame;
    }
  }

  output_size = peek(output, max_size);
  if (output_size == 0U) {
    return MavlinkBulkPeekStatus::BlockedByActiveFrame;
  }
  return MavlinkBulkPeekStatus::FrameReady;
}

std::size_t MavlinkFrameScheduler::peek(std::uint8_t* output,
                                        std::size_t max_size) noexcept {
  if (output == nullptr || max_size == 0U || empty()) {
    last_peek_size_ = 0U;
    return 0U;
  }
  if (active_index_ >= capacity() && !parameter_active_ &&
      !target_parameter_active_) {
    const std::size_t selected = choose_next_slot();
    const bool heartbeat_selected =
        selected < capacity() &&
        slots_[selected].priority == Priority::Heartbeat;
    if (target_parameter_count_ > 0U &&
        (!heartbeat_selected || target_heartbeat_yielded_)) {
      target_parameter_active_ = true;
      target_parameter_active_offset_ = 0U;
      ++diagnostics_.target_parameter_selections;
    } else if (target_parameter_count_ > 0U && heartbeat_selected) {
      active_index_ = selected;
      active_offset_ = 0U;
      target_heartbeat_yielded_ = true;
      ++diagnostics_.target_heartbeat_yields;
    } else if (parameter_value_precedes(selected)) {
      parameter_active_ = true;
      parameter_active_offset_ = 0U;
    } else {
      active_index_ = selected;
      active_offset_ = 0U;
    }
  }
  if (target_parameter_active_) {
    const MavlinkFrame& frame =
        target_parameter_frames_[target_parameter_head_].frame;
    const std::size_t remaining =
        frame.size - target_parameter_active_offset_;
    last_peek_size_ = std::min(max_size, remaining);
    std::copy_n(frame.bytes.begin() + target_parameter_active_offset_,
                last_peek_size_, output);
    return last_peek_size_;
  }
  if (parameter_active_) {
    const std::size_t frame_size =
        parameter_lengths_[parameter_frame_head_];
    const std::size_t remaining = frame_size - parameter_active_offset_;
    last_peek_size_ = std::min(max_size, remaining);
    for (std::size_t index = 0U; index < last_peek_size_; ++index) {
      output[index] = parameter_bytes_[
          (parameter_byte_head_ + index) % parameter_bytes_.size()];
    }
    return last_peek_size_;
  }
  if (active_index_ >= capacity()) {
    last_peek_size_ = 0U;
    return 0U;
  }

  const MavlinkFrame& frame = slots_[active_index_].frame;
  const std::size_t remaining = frame.size - active_offset_;
  last_peek_size_ = std::min(max_size, remaining);
  std::copy_n(frame.bytes.begin() + active_offset_, last_peek_size_, output);
  return last_peek_size_;
}

bool MavlinkFrameScheduler::complete_send(TxResult result,
                                          std::size_t byte_count) noexcept {
  if ((!target_parameter_active_ && !parameter_active_ &&
       active_index_ >= capacity()) ||
      byte_count == 0U ||
      byte_count > last_peek_size_) {
    return false;
  }
  if (result == TxResult::Rejected) {
    ++diagnostics_.rejected_send_attempts;
    if (target_parameter_active_) {
      ++diagnostics_.target_parameter_rejected_attempts;
    }
    last_peek_size_ = 0U;
    return true;
  }

  if (target_parameter_active_) {
    TargetParameterFrame& target =
        target_parameter_frames_[target_parameter_head_];
    target_parameter_active_offset_ += byte_count;
    queued_bytes_ -= byte_count;
    diagnostics_.bytes_forwarded += byte_count;
    ++diagnostics_.target_parameter_chunks_forwarded;
    last_peek_size_ = 0U;
    if (target_parameter_active_offset_ == target.frame.size) {
      release_parameter_request(target.request_slot);
      target = {};
      target_parameter_head_ =
          (target_parameter_head_ + 1U) % target_parameter_frames_.size();
      --target_parameter_count_;
      ++diagnostics_.frames_forwarded;
      ++diagnostics_.target_parameter_frames_completed;
      target_parameter_active_ = false;
      target_parameter_active_offset_ = 0U;
      target_heartbeat_yielded_ = false;
    }
    return true;
  }

  if (parameter_active_) {
    parameter_active_offset_ += byte_count;
    parameter_byte_head_ =
        (parameter_byte_head_ + byte_count) % parameter_bytes_.size();
    parameter_byte_count_ -= byte_count;
    queued_bytes_ -= byte_count;
    diagnostics_.bytes_forwarded += byte_count;
    last_peek_size_ = 0U;
    if (parameter_active_offset_ ==
        parameter_lengths_[parameter_frame_head_]) {
      parameter_lengths_[parameter_frame_head_] = 0U;
      parameter_frame_head_ =
          (parameter_frame_head_ + 1U) % parameter_lengths_.size();
      --parameter_frame_count_;
      ++diagnostics_.frames_forwarded;
      parameter_active_ = false;
      parameter_active_offset_ = 0U;
    }
    return true;
  }

  active_offset_ += byte_count;
  queued_bytes_ -= byte_count;
  diagnostics_.bytes_forwarded += byte_count;
  last_peek_size_ = 0U;
  if (active_offset_ == slots_[active_index_].frame.size) {
    slots_[active_index_] = {};
    --slot_count_;
    ++diagnostics_.frames_forwarded;
    active_index_ = capacity();
    active_offset_ = 0U;
  }
  return true;
}

void MavlinkFrameScheduler::reset() noexcept {
  slots_ = {};
  parameter_bytes_ = {};
  parameter_lengths_ = {};
  parameter_requests_ = {};
  target_parameter_frames_ = {};
  rate_buckets_ = {};
  parser_ = {};
  diagnostics_ = {};
  slot_count_ = 0U;
  queued_bytes_ = 0U;
  active_index_ = capacity();
  active_offset_ = 0U;
  parameter_byte_head_ = 0U;
  parameter_byte_tail_ = 0U;
  parameter_byte_count_ = 0U;
  parameter_frame_head_ = 0U;
  parameter_frame_tail_ = 0U;
  parameter_frame_count_ = 0U;
  parameter_active_offset_ = 0U;
  parameter_active_ = false;
  parameter_request_count_ = 0U;
  target_parameter_head_ = 0U;
  target_parameter_tail_ = 0U;
  target_parameter_count_ = 0U;
  target_parameter_active_offset_ = 0U;
  target_parameter_active_ = false;
  target_heartbeat_yielded_ = false;
  native_list_state_ = NativeParameterListState::Idle;
  native_list_expected_index_ = 0U;
  native_list_parameter_count_ = 0U;
  native_list_target_system_ = 0U;
  native_list_target_component_ = 0U;
  last_peek_size_ = 0U;
  next_order_ = 0U;
  bulk_heartbeat_last_admitted_ms_ = 0U;
  heartbeat_seen_ = false;
  bulk_heartbeat_policy_active_ = false;
}

}  // namespace vc_lora
