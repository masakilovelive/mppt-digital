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

bool MavlinkFrameScheduler::active_frame_is_heartbeat() const noexcept {
  return !parameter_active_ && active_index_ < capacity() &&
         slots_[active_index_].occupied &&
         slots_[active_index_].frame.message_id == 0U;
}

bool MavlinkFrameScheduler::active_frame_has_progress() const noexcept {
  return parameter_active_ ? parameter_active_offset_ > 0U
                           : active_index_ < capacity() &&
                                 slots_[active_index_].occupied &&
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

std::size_t MavlinkFrameScheduler::peek(std::uint8_t* output,
                                        std::size_t max_size) noexcept {
  if (output == nullptr || max_size == 0U || empty()) {
    last_peek_size_ = 0U;
    return 0U;
  }
  if (active_index_ >= capacity() && !parameter_active_) {
    const std::size_t selected = choose_next_slot();
    if (parameter_value_precedes(selected)) {
      parameter_active_ = true;
      parameter_active_offset_ = 0U;
    } else {
      active_index_ = selected;
      active_offset_ = 0U;
    }
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
  if ((!parameter_active_ && active_index_ >= capacity()) ||
      byte_count == 0U ||
      byte_count > last_peek_size_) {
    return false;
  }
  if (result == TxResult::Rejected) {
    ++diagnostics_.rejected_send_attempts;
    last_peek_size_ = 0U;
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
  last_peek_size_ = 0U;
  next_order_ = 0U;
  heartbeat_seen_ = false;
}

}  // namespace vc_lora
