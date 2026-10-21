#include "vc_lora/ground_parameter_download_proxy.hpp"

#include <algorithm>
#include <array>
#include <limits>

namespace vc_lora {
namespace {

constexpr std::uint32_t kParamRequestReadMessageId = 20U;
constexpr std::uint32_t kParamRequestListMessageId = 21U;
constexpr std::uint32_t kParamValueMessageId = 22U;
constexpr std::uint32_t kParamSetMessageId = 23U;
constexpr std::uint32_t kHeartbeatMessageId = 0U;
constexpr std::uint32_t kPingMessageId = 4U;
constexpr std::uint32_t kRequestDataStreamMessageId = 66U;
constexpr std::uint32_t kCommandLongMessageId = 76U;
constexpr std::uint32_t kTimesyncMessageId = 111U;
constexpr std::uint32_t kAutopilotVersionRequestMessageId = 183U;
constexpr std::uint16_t kMavCmdSetMessageInterval = 511U;
constexpr std::uint16_t kMavCmdRequestMessage = 512U;
constexpr std::uint16_t kMavCmdRequestAutopilotCapabilities = 520U;
constexpr std::uint16_t kUnlistedParameterIndex = 0xFFFFU;
// PARAM_REQUEST_READ.param_index is int16_t: indexes 0..32767 are valid, so
// the corresponding maximum count is 32768.
constexpr std::uint16_t kMaximumIndexAddressableParameterCount = 0x8000U;

std::uint16_t read_u16(const std::uint8_t* bytes) noexcept {
  return static_cast<std::uint16_t>(bytes[0]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(bytes[1]) << 8U);
}

void write_u16(std::uint8_t* bytes, std::uint16_t value) noexcept {
  bytes[0] = static_cast<std::uint8_t>(value & 0xFFU);
  bytes[1] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
}

}  // namespace

GroundParameterDownloadProxy::GroundParameterDownloadProxy(
    GroundParameterDownloadProxyConfig config) noexcept
    : config_(config) {
  if (config_.value_timeout_ms == 0U) {
    config_.value_timeout_ms = 1U;
  }
  if (config_.retry_backoff_ms == 0U) {
    config_.retry_backoff_ms = 1U;
  }
  if (config_.max_value_attempts == 0U) {
    config_.max_value_attempts = 1U;
  }
}

bool GroundParameterDownloadProxy::frame_is_valid(
    const MavlinkFrame& frame) const noexcept {
  if (frame.size == 0U || frame.size > frame.bytes.size()) {
    return false;
  }
  MavlinkFrame validated{};
  return validate_mavlink_frame(frame.bytes.data(), frame.size, validated) ==
             MavlinkParseStatus::FrameReady &&
         validated.message_id == frame.message_id &&
         validated.payload_length == frame.payload_length &&
         validated.system_id == frame.system_id &&
         validated.component_id == frame.component_id &&
         validated.sequence == frame.sequence &&
         validated.version == frame.version &&
         validated.signed_frame == frame.signed_frame;
}

std::uint64_t GroundParameterDownloadProxy::deadline_after(
    std::uint64_t now_ms, std::uint32_t delay_ms) noexcept {
  const std::uint64_t delay = delay_ms;
  const std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
  return delay > maximum - now_ms ? maximum : now_ms + delay;
}

void GroundParameterDownloadProxy::reset_background_coalescing() noexcept {
  data_stream_cache_ = {};
  periodic_command_cache_ = {};
  background_retry_not_before_ms_ = 0U;
  autopilot_version_request_seen_ = false;
  background_retry_armed_ = false;
}

bool GroundParameterDownloadProxy::claim_background_forward(
    std::uint64_t now_ms, bool immediate) noexcept {
  if (!immediate && background_retry_armed_ &&
      now_ms < background_retry_not_before_ms_) {
    return false;
  }
  background_retry_armed_ = true;
  background_retry_not_before_ms_ =
      deadline_after(now_ms, config_.periodic_forward_interval_ms);
  return true;
}

bool GroundParameterDownloadProxy::start_session(
    const MavlinkFrame& frame, std::uint64_t now_ms) noexcept {
  if (frame.payload_length != 2U || frame.signed_frame) {
    return false;
  }
  const std::uint8_t* payload = frame.payload();
  if (payload[0] == 0U || payload[1] == 0U) {
    return false;
  }

  request_ = {};
  request_token_ = 0U;
  request_ready_ = false;
  expected_index_ = 0U;
  param_count_ = 0U;
  count_known_ = false;
  target_system_ = payload[0];
  target_component_ = payload[1];
  sender_system_ = frame.system_id;
  sender_component_ = frame.component_id;
  request_version_ = frame.version;
  if (!sequence_initialized_) {
    next_sequence_ = static_cast<std::uint8_t>(frame.sequence + 1U);
    sequence_initialized_ = true;
  }
  value_attempts_ = 0U;
  native_stream_recovery_active_ = false;
  clear_expired_parameter_set_quarantine(now_ms);
  backoff_is_retry_ = false;
  reset_background_coalescing();
  next_ping_forward_ms_ = 0U;
  next_timesync_forward_ms_ = 0U;
  ping_forwarded_ = false;
  timesync_forwarded_ = false;
  deadline_ms_ = now_ms;
  state_ = GroundParameterProxyState::Ready;
  if (config_.list_strategy == GroundParameterListStrategy::NativeStream) {
    // Keep the exact GCS wire image and send it through the same
    // admission/dequeue/UL_DONE lease used by generated #20 requests. This
    // permits exactly-once #21 transport without bypassing the existing
    // physical commit watchdog.
    request_ = frame;
    request_token_ = allocate_token();
    request_ready_ = true;
    ++diagnostics_.native_list_requests_leased;
  }
  ++diagnostics_.sessions_started;
  return true;
}

void GroundParameterDownloadProxy::begin_parameter_set_quarantine(
    const MavlinkFrame& frame, std::uint64_t now_ms) noexcept {
  const std::uint8_t* param_id = frame.payload() + 6U;
  if (!parameter_set_quarantine_active_) {
    std::copy_n(param_id, quarantined_param_id_.size(),
                quarantined_param_id_.begin());
    parameter_set_quarantine_active_ = true;
    quarantine_all_parameter_values_ = false;
    quarantine_target_system_ = target_system_;
    quarantine_target_component_ = target_component_;
    stale_response_quarantine_deadline_ms_ =
        deadline_after(now_ms, config_.value_timeout_ms);
    ++diagnostics_.parameter_set_preexisting_usb_race_windows;
    return;
  }
  if (!std::equal(param_id, param_id + quarantined_param_id_.size(),
                  quarantined_param_id_.begin()) &&
      !quarantine_all_parameter_values_) {
    // Fixed storage deliberately retains only one fingerprint. If another
    // parameter is attempted before the hold expires, quarantine every #22
    // from this target rather than risk a false write acknowledgement.
    quarantine_all_parameter_values_ = true;
    ++diagnostics_.parameter_set_quarantine_escalations;
  }
}

bool GroundParameterDownloadProxy::stale_response_quarantine_active(
    std::uint64_t now_ms) const noexcept {
  return parameter_set_quarantine_active_ &&
         now_ms < stale_response_quarantine_deadline_ms_;
}

void GroundParameterDownloadProxy::clear_expired_parameter_set_quarantine(
    std::uint64_t now_ms) noexcept {
  if (!parameter_set_quarantine_active_ ||
      cancelled_admitted_request_token_ != 0U ||
      now_ms < stale_response_quarantine_deadline_ms_) {
    return;
  }
  quarantined_param_id_ = {};
  quarantine_target_system_ = 0U;
  quarantine_target_component_ = 0U;
  stale_response_quarantine_deadline_ms_ = 0U;
  parameter_set_quarantine_active_ = false;
  quarantine_all_parameter_values_ = false;
}

bool GroundParameterDownloadProxy::response_expected() const noexcept {
  return state_ == GroundParameterProxyState::AwaitingValue ||
         (state_ == GroundParameterProxyState::Backoff && backoff_is_retry_) ||
         (state_ == GroundParameterProxyState::Ready && value_attempts_ > 0U);
}

void GroundParameterDownloadProxy::latch_recovery_event(
    GroundParameterRecoveryReason reason, const MavlinkFrame* frame,
    std::uint64_t now_ms) noexcept {
  if (recovery_latch_.valid) {
    return;
  }
  recovery_latch_ = {};
  recovery_latch_.valid = true;
  recovery_latch_.reason = reason;
  recovery_latch_.expected_index = expected_index_;
  recovery_latch_.received_index = kUnlistedParameterIndex;
  recovery_latch_.received_count = count_known_ ? param_count_ : 0U;
  recovery_latch_.observed_at_ms = now_ms;
  if (frame == nullptr) {
    return;
  }
  recovery_latch_.received_sequence = frame->sequence;
  if (frame->payload_length >= 8U) {
    recovery_latch_.received_count = read_u16(frame->payload() + 4U);
    recovery_latch_.received_index = read_u16(frame->payload() + 6U);
  }
}

bool GroundParameterDownloadProxy::begin_native_stream_recovery(
    GroundParameterRecoveryReason reason, const MavlinkFrame* frame,
    std::uint64_t now_ms) noexcept {
  if (config_.list_strategy != GroundParameterListStrategy::NativeStream ||
      native_stream_poisoned_ || !active()) {
    return false;
  }
  if (native_stream_recovery_active_) {
    return true;
  }

  std::uint16_t observed_count = count_known_ ? param_count_ : 0U;
  if (frame != nullptr && frame->payload_length >= 8U) {
    observed_count = read_u16(frame->payload() + 4U);
  }
  if (observed_count > kMaximumIndexAddressableParameterCount) {
    fail_native_stream(GroundParameterRecoveryReason::CountMismatch,
                       frame, now_ms);
    return false;
  }
  if (!count_known_ && observed_count != 0U) {
    param_count_ = observed_count;
    count_known_ = true;
  }

  latch_recovery_event(reason, frame, now_ms);
  native_stream_recovery_active_ = true;
  if (reason == GroundParameterRecoveryReason::FutureIndex) {
    ++diagnostics_.native_stream_gap_recoveries;
  } else {
    ++diagnostics_.native_stream_timeout_recoveries;
  }

  request_ = {};
  request_token_ = 0U;
  request_ready_ = false;
  value_attempts_ = 0U;
  backoff_is_retry_ = false;
  deadline_ms_ = now_ms;
  state_ = GroundParameterProxyState::Ready;
  if (prepare_request(now_ms)) {
    return true;
  }
  if (active()) {
    poison_native_stream(now_ms);
  }
  return false;
}

void GroundParameterDownloadProxy::fail_native_stream(
    GroundParameterRecoveryReason reason, const MavlinkFrame* frame,
    std::uint64_t now_ms) noexcept {
  latch_recovery_event(reason, frame, now_ms);
  poison_native_stream(now_ms);
}

void GroundParameterDownloadProxy::poison_native_stream(
    std::uint64_t now_ms) noexcept {
  if (config_.list_strategy != GroundParameterListStrategy::NativeStream) {
    fail_session(now_ms);
    return;
  }
  if (!native_stream_poisoned_) {
    native_stream_poisoned_ = true;
    ++diagnostics_.native_stream_poison_events;
  }
  if (active()) {
    fail_session(now_ms);
  }
}

GroundParameterProxyDisposition
GroundParameterDownloadProxy::on_gcs_frame(
    const MavlinkFrame& frame, std::uint64_t now_ms) noexcept {
  if (!frame_is_valid(frame)) {
    ++diagnostics_.invalid_frames;
    return GroundParameterProxyDisposition::Invalid;
  }

  clear_expired_parameter_set_quarantine(now_ms);
  const bool terminal_hold_active =
      (state_ == GroundParameterProxyState::Complete ||
       state_ == GroundParameterProxyState::Failed) &&
      now_ms < deadline_ms_;
  const bool parameter_set_quarantine_guard_active =
      parameter_set_quarantine_active_ &&
      (stale_response_quarantine_active(now_ms) ||
       cancelled_admitted_request_token_ != 0U);
  const bool abandoned_admission_guard_active =
      abandoned_admitted_request_token_ != 0U;
  const bool same_sender =
      (active() || terminal_hold_active ||
       parameter_set_quarantine_guard_active) &&
      frame.system_id == sender_system_ &&
      frame.component_id == sender_component_;

  if (frame.message_id == kParamSetMessageId) {
    const bool affects_session_target =
        frame.payload_length == 23U &&
        (frame.payload()[4] == 0U ||
         frame.payload()[4] == target_system_) &&
        (frame.payload()[5] == 0U ||
         frame.payload()[5] == target_component_);
    const bool affects_quarantine_target =
        frame.payload_length == 23U &&
        (frame.payload()[4] == 0U ||
         frame.payload()[4] == quarantine_target_system_) &&
        (frame.payload()[5] == 0U ||
         frame.payload()[5] == quarantine_target_component_);
    if (native_stream_poisoned_ && affects_session_target) {
      ++diagnostics_.parameter_sets_rejected;
      ++diagnostics_.terminal_requests_suppressed;
      return GroundParameterProxyDisposition::Consumed;
    }
    if (active() && affects_session_target) {
      // Never defer or forward a write while a generated read can already be
      // queued. A delayed PARAM_SET could mutate the aircraft after Mission
      // Planner has reported failure, and an old #22 could be mistaken for
      // its acknowledgement. Fail the list transaction and reject the write.
      ++diagnostics_.parameter_sets_cancelled_session;
      ++diagnostics_.parameter_sets_rejected;
      begin_parameter_set_quarantine(frame, now_ms);
      if (request_ready_ && admitted_request_token_ == request_token_) {
        cancelled_admitted_request_token_ = admitted_request_token_;
      }
      if (config_.list_strategy ==
          GroundParameterListStrategy::NativeStream) {
        poison_native_stream(now_ms);
      } else {
        fail_session(now_ms);
      }
      return GroundParameterProxyDisposition::Consumed;
    }
    if (terminal_hold_active && affects_session_target) {
      ++diagnostics_.parameter_sets_rejected;
      ++diagnostics_.terminal_requests_suppressed;
      begin_parameter_set_quarantine(frame, now_ms);
      return GroundParameterProxyDisposition::Consumed;
    }
    if (parameter_set_quarantine_guard_active &&
        affects_quarantine_target) {
      ++diagnostics_.parameter_sets_rejected;
      begin_parameter_set_quarantine(frame, now_ms);
      return GroundParameterProxyDisposition::Consumed;
    }
    return GroundParameterProxyDisposition::Forward;
  }

  if (frame.message_id == kParamRequestListMessageId) {
    if (frame.payload_length != 2U || frame.signed_frame ||
        frame.payload()[0] == 0U || frame.payload()[1] == 0U) {
      return GroundParameterProxyDisposition::Forward;
    }
    if (config_.list_strategy == GroundParameterListStrategy::NativeStream &&
        native_stream_poisoned_) {
      ++diagnostics_.terminal_requests_suppressed;
      return GroundParameterProxyDisposition::Consumed;
    }
    // Do not start a second target/session while a physically admitted stale
    // #20 can still re-arm quarantine for the prior target. One fixed
    // fingerprint cannot safely represent both sources.
    if (parameter_set_quarantine_guard_active ||
        abandoned_admission_guard_active) {
      ++diagnostics_.terminal_requests_suppressed;
      return GroundParameterProxyDisposition::Consumed;
    }
    const bool same_session =
        frame.system_id == sender_system_ &&
        frame.component_id == sender_component_ &&
        frame.payload()[0] == target_system_ &&
        frame.payload()[1] == target_component_;
    if ((state_ == GroundParameterProxyState::Complete ||
         state_ == GroundParameterProxyState::Failed) &&
        same_session && now_ms < deadline_ms_) {
      ++diagnostics_.terminal_requests_suppressed;
      return GroundParameterProxyDisposition::Consumed;
    }
    if (active()) {
      if (same_session) {
        ++diagnostics_.list_requests_coalesced;
        return GroundParameterProxyDisposition::Consumed;
      }
      if (config_.list_strategy ==
          GroundParameterListStrategy::NativeStream) {
        ++diagnostics_.terminal_requests_suppressed;
        return GroundParameterProxyDisposition::Consumed;
      }
      ++diagnostics_.conflicting_requests_forwarded;
      return GroundParameterProxyDisposition::Forward;
    }
    if (!start_session(frame, now_ms)) {
      return GroundParameterProxyDisposition::Forward;
    }
    return GroundParameterProxyDisposition::Consumed;
  }

  if (frame.message_id == kParamRequestReadMessageId) {
    const bool same_session =
        !frame.signed_frame && frame.payload_length >= 4U &&
        frame.payload_length <= 20U &&
        frame.system_id == sender_system_ &&
        frame.component_id == sender_component_ &&
        frame.payload()[2] == target_system_ &&
        frame.payload()[3] == target_component_;
    if (config_.list_strategy == GroundParameterListStrategy::NativeStream &&
        native_stream_poisoned_ && same_session) {
      ++diagnostics_.terminal_requests_suppressed;
      return GroundParameterProxyDisposition::Consumed;
    }
    if (abandoned_admission_guard_active && same_session) {
      ++diagnostics_.terminal_requests_suppressed;
      return GroundParameterProxyDisposition::Consumed;
    }
    if ((state_ == GroundParameterProxyState::Complete ||
         state_ == GroundParameterProxyState::Failed) &&
        same_session && now_ms < deadline_ms_) {
      ++diagnostics_.terminal_requests_suppressed;
      return GroundParameterProxyDisposition::Consumed;
    }
    if (active() && same_session) {
      ++diagnostics_.read_requests_coalesced;
      return GroundParameterProxyDisposition::Consumed;
    }
    if (active()) {
      ++diagnostics_.conflicting_requests_forwarded;
    }
    return GroundParameterProxyDisposition::Forward;
  }

  // Mission Planner repeats setup/capability requests faster than the
  // half-duplex uplink can drain while a parameter transaction is active.
  // Cache only semantic identities in fixed storage. New identities remain
  // transparent once, while every retry class shares one 30-second budget.
  // Forwarded frames keep their original wire bytes and FIFO position.
  const bool bounded_parameter_sender =
      (active() || terminal_hold_active) && !frame.signed_frame &&
      frame.system_id == sender_system_ &&
      frame.component_id == sender_component_;
  const auto target_matches = [this](std::uint8_t system,
                                     std::uint8_t component) noexcept {
    return (system == 0U || system == target_system_) &&
           (component == 0U || component == target_component_);
  };
  const auto background_disposition =
      [this, now_ms](bool immediate,
                     bool command_family) noexcept {
        if (!claim_background_forward(now_ms, immediate)) {
          if (command_family) {
            ++diagnostics_.request_message_frames_coalesced;
          } else {
            ++diagnostics_.periodic_frames_coalesced;
          }
          return GroundParameterProxyDisposition::Consumed;
        }
        if (command_family) {
          ++diagnostics_.request_message_frames_forwarded;
        } else {
          ++diagnostics_.periodic_frames_forwarded;
        }
        return GroundParameterProxyDisposition::Forward;
      };

  if (bounded_parameter_sender &&
      frame.message_id == kRequestDataStreamMessageId &&
      frame.payload_length == 6U &&
      target_matches(frame.payload()[2U], frame.payload()[3U])) {
    const std::uint8_t* payload = frame.payload();
    DataStreamCacheEntry* matching = nullptr;
    DataStreamCacheEntry* empty = nullptr;
    for (DataStreamCacheEntry& entry : data_stream_cache_) {
      if (!entry.used) {
        if (empty == nullptr) {
          empty = &entry;
        }
        continue;
      }
      if (entry.target_system == payload[2U] &&
          entry.target_component == payload[3U] &&
          entry.stream_id == payload[4U]) {
        matching = &entry;
        break;
      }
    }
    const std::uint16_t message_rate = read_u16(payload);
    if (matching != nullptr) {
      // Remember the most recent requested setting even while the shared
      // retry gate is closed. A later Mission Planner retry then forwards the
      // latest value rather than an obsolete one.
      matching->message_rate = message_rate;
      matching->start_stop = payload[5U];
      return background_disposition(false, false);
    }
    if (empty != nullptr) {
      empty->message_rate = message_rate;
      empty->target_system = payload[2U];
      empty->target_component = payload[3U];
      empty->stream_id = payload[4U];
      empty->start_stop = payload[5U];
      empty->used = true;
      return background_disposition(true, false);
    }
    ++diagnostics_.background_cache_full_frames;
    return background_disposition(false, false);
  }

  if (bounded_parameter_sender &&
      frame.message_id == kAutopilotVersionRequestMessageId &&
      frame.payload_length == 2U &&
      target_matches(frame.payload()[0U], frame.payload()[1U])) {
    if (!autopilot_version_request_seen_) {
      autopilot_version_request_seen_ = true;
      return background_disposition(true, false);
    }
    return background_disposition(false, false);
  }

  if (bounded_parameter_sender &&
      frame.message_id == kCommandLongMessageId &&
      frame.payload_length >= 30U) {
    const std::uint16_t command = read_u16(frame.payload() + 28U);
    const bool periodic_command =
        command == kMavCmdSetMessageInterval ||
        command == kMavCmdRequestMessage ||
        command == kMavCmdRequestAutopilotCapabilities;
    const std::uint8_t command_target_system =
        frame.payload_byte_or_zero(30U);
    const std::uint8_t command_target_component =
        frame.payload_byte_or_zero(31U);
    if (periodic_command &&
        target_matches(command_target_system, command_target_component)) {
      std::array<std::uint8_t, 32U> semantic_payload{};
      for (std::size_t index = 0U; index < semantic_payload.size(); ++index) {
        semantic_payload[index] = frame.payload_byte_or_zero(index);
      }
      PeriodicCommandCacheEntry* empty = nullptr;
      for (PeriodicCommandCacheEntry& entry : periodic_command_cache_) {
        if (!entry.used) {
          if (empty == nullptr) {
            empty = &entry;
          }
          continue;
        }
        if (entry.semantic_payload == semantic_payload) {
          return background_disposition(false, true);
        }
      }
      if (empty != nullptr) {
        empty->semantic_payload = semantic_payload;
        empty->used = true;
        return background_disposition(true, true);
      }
      ++diagnostics_.background_cache_full_frames;
      return background_disposition(false, true);
    }
  }

  // Vehicle already injects the same GCS identity HEARTBEAT locally at 1 Hz,
  // so forwarding the Mission Planner copy through a one-frame/TDD-cycle
  // uplink only creates an unbounded queue.
  const bool vehicle_replaces_gcs_heartbeat =
      sender_system_ == 255U && sender_component_ == 190U;
  if (same_sender && vehicle_replaces_gcs_heartbeat &&
      frame.message_id == kHeartbeatMessageId) {
    ++diagnostics_.periodic_frames_coalesced;
    return GroundParameterProxyDisposition::Consumed;
  }

  // PING/TIMESYNC remain available during a long download, but are rate
  // limited independently so their periodic source cadence cannot outrun the
  // one-frame/TDD-cycle uplink.
  if (same_sender && frame.message_id == kPingMessageId &&
      frame.payload_length == 14U &&
      (frame.payload()[12] != 0U || frame.payload()[13] != 0U)) {
    // A targeted PING is a response in a live exchange. Only broadcast
    // periodic requests are eligible for the bounded class-level bucket.
    ++diagnostics_.periodic_frames_forwarded;
    return GroundParameterProxyDisposition::Forward;
  }

  if (same_sender && frame.message_id == kTimesyncMessageId &&
      frame.payload_length == 16U &&
      std::any_of(frame.payload(), frame.payload() + 8U,
                  [](std::uint8_t byte) { return byte != 0U; })) {
    // tc1 != 0 is a response, not a periodic request. It closes a live
    // timesync exchange and therefore remains fully transparent.
    ++diagnostics_.periodic_frames_forwarded;
    return GroundParameterProxyDisposition::Forward;
  }

  if (same_sender && (frame.message_id == kPingMessageId ||
                      frame.message_id == kTimesyncMessageId)) {
    bool& forwarded = frame.message_id == kPingMessageId
                          ? ping_forwarded_
                          : timesync_forwarded_;
    std::uint64_t& next_forward_ms =
        frame.message_id == kPingMessageId ? next_ping_forward_ms_
                                           : next_timesync_forward_ms_;
    if (forwarded && now_ms < next_forward_ms) {
      ++diagnostics_.periodic_frames_coalesced;
      return GroundParameterProxyDisposition::Consumed;
    }
    forwarded = true;
    next_forward_ms =
        deadline_after(now_ms, config_.periodic_forward_interval_ms);
    ++diagnostics_.periodic_frames_forwarded;
    return GroundParameterProxyDisposition::Forward;
  }

  return GroundParameterProxyDisposition::Forward;
}

GroundParameterProxyDisposition
GroundParameterDownloadProxy::preclassify_vehicle_frame(
    const MavlinkFrame& frame,
    std::uint64_t now_ms) noexcept {
  if (!frame_is_valid(frame)) {
    ++diagnostics_.invalid_frames;
    if (config_.list_strategy == GroundParameterListStrategy::NativeStream &&
        active() && frame.message_id == kParamValueMessageId) {
      fail_native_stream(GroundParameterRecoveryReason::InvalidFrame,
                         &frame, now_ms);
    }
    return GroundParameterProxyDisposition::Invalid;
  }
  clear_expired_parameter_set_quarantine(now_ms);
  const bool terminal_hold_active =
      (state_ == GroundParameterProxyState::Complete ||
       state_ == GroundParameterProxyState::Failed) &&
      now_ms < deadline_ms_;
  const bool native_parameter_value =
      config_.list_strategy == GroundParameterListStrategy::NativeStream &&
      frame.message_id == kParamValueMessageId;
  const bool same_native_value =
      native_parameter_value && frame.payload_length == 25U &&
      frame.system_id == target_system_ &&
      frame.component_id == target_component_;
  if (same_native_value && native_stream_poisoned_) {
    ++diagnostics_.native_stream_values_quarantined;
    return GroundParameterProxyDisposition::Consumed;
  }
  if (same_native_value && terminal_hold_active &&
      state_ == GroundParameterProxyState::Complete) {
    ++diagnostics_.native_stream_values_quarantined;
    return GroundParameterProxyDisposition::Consumed;
  }
  if (native_parameter_value && active() && frame.payload_length != 25U) {
    fail_native_stream(GroundParameterRecoveryReason::InvalidFrame,
                       &frame, now_ms);
    ++diagnostics_.native_stream_values_quarantined;
    return GroundParameterProxyDisposition::Consumed;
  }
  if (native_parameter_value && active() &&
      (frame.system_id != target_system_ ||
       frame.component_id != target_component_)) {
    fail_native_stream(GroundParameterRecoveryReason::SourceMismatch,
                       &frame, now_ms);
    ++diagnostics_.native_stream_values_quarantined;
    return GroundParameterProxyDisposition::Consumed;
  }
  if (same_native_value && active()) {
    const std::uint16_t count = read_u16(frame.payload() + 4U);
    const std::uint16_t index = read_u16(frame.payload() + 6U);
    if (!response_expected()) {
      // The original #21 (or a recovery #20) has not crossed its explicit
      // physical commit yet. A complete #22 already in flight therefore
      // belongs to older traffic, even when its unlisted index/count would
      // be invalid for the new stream. Quarantine it before semantic list
      // validation and retain the exact current request lease.
      ++diagnostics_.native_stream_precommit_values_quarantined;
      ++diagnostics_.native_stream_values_quarantined;
      return GroundParameterProxyDisposition::Consumed;
    }
    const bool invalid_count =
        count == 0U || index == kUnlistedParameterIndex || index >= count ||
        (count_known_ && count != param_count_) ||
        (native_stream_recovery_active_ &&
         count > kMaximumIndexAddressableParameterCount);
    if (invalid_count) {
      ++diagnostics_.count_mismatch_failures;
      fail_native_stream(GroundParameterRecoveryReason::CountMismatch,
                         &frame, now_ms);
      ++diagnostics_.native_stream_values_quarantined;
      return GroundParameterProxyDisposition::Consumed;
    }

    if (index < expected_index_) {
      ++diagnostics_.native_stream_old_duplicates_consumed;
      ++diagnostics_.native_stream_values_quarantined;
      return GroundParameterProxyDisposition::Consumed;
    }
    if (index > expected_index_) {
      ++diagnostics_.native_stream_future_values_quarantined;
      ++diagnostics_.native_stream_values_quarantined;
      if (count > kMaximumIndexAddressableParameterCount) {
        ++diagnostics_.count_mismatch_failures;
        fail_native_stream(GroundParameterRecoveryReason::CountMismatch,
                           &frame, now_ms);
        return GroundParameterProxyDisposition::Consumed;
      }
      if (!native_stream_recovery_active_) {
        (void)begin_native_stream_recovery(
            GroundParameterRecoveryReason::FutureIndex, &frame, now_ms);
      }
      return GroundParameterProxyDisposition::Consumed;
    }
  }
  if ((terminal_hold_active ||
       stale_response_quarantine_active(now_ms)) &&
      parameter_set_quarantine_active_ &&
      frame.message_id == kParamValueMessageId &&
      frame.payload_length == 25U &&
      frame.system_id == quarantine_target_system_ &&
      frame.component_id == quarantine_target_component_ &&
      (quarantine_all_parameter_values_ ||
       std::equal(frame.payload() + 8U, frame.payload() + 24U,
                  quarantined_param_id_.begin()))) {
    ++diagnostics_.parameter_values_quarantined;
    return GroundParameterProxyDisposition::Consumed;
  }
  return GroundParameterProxyDisposition::Forward;
}

GroundParameterProxyDisposition
GroundParameterDownloadProxy::on_vehicle_frame(
    const MavlinkFrame& frame, bool usb_queued,
    std::uint64_t now_ms) noexcept {
  const GroundParameterProxyDisposition preclassification =
      preclassify_vehicle_frame(frame, now_ms);
  if (preclassification != GroundParameterProxyDisposition::Forward) {
    return preclassification;
  }
  if (frame.message_id != kParamValueMessageId || !active()) {
    return GroundParameterProxyDisposition::Forward;
  }
  if (frame.payload_length != 25U ||
      frame.system_id != target_system_ ||
      frame.component_id != target_component_) {
    ++diagnostics_.unmatched_values_forwarded;
    return GroundParameterProxyDisposition::Forward;
  }

  const std::uint8_t* payload = frame.payload();
  const std::uint16_t count = read_u16(payload + 4U);
  const std::uint16_t index = read_u16(payload + 6U);
  if (index == kUnlistedParameterIndex ||
      index != expected_index_ ||
      !response_expected()) {
    if (config_.list_strategy == GroundParameterListStrategy::NativeStream) {
      fail_native_stream(GroundParameterRecoveryReason::CountMismatch,
                         &frame, now_ms);
      ++diagnostics_.native_stream_values_quarantined;
      return GroundParameterProxyDisposition::Consumed;
    }
    ++diagnostics_.unmatched_values_forwarded;
    return GroundParameterProxyDisposition::Forward;
  }
  ++diagnostics_.matching_values_seen;

  const bool indexed_read_strategy =
      config_.list_strategy == GroundParameterListStrategy::IndexedRead ||
      native_stream_recovery_active_;
  if (count == 0U ||
      (indexed_read_strategy &&
       count > kMaximumIndexAddressableParameterCount) ||
      index >= count ||
      (count_known_ && count != param_count_)) {
    ++diagnostics_.count_mismatch_failures;
    if (config_.list_strategy == GroundParameterListStrategy::NativeStream) {
      fail_native_stream(GroundParameterRecoveryReason::CountMismatch,
                         &frame, now_ms);
      ++diagnostics_.native_stream_values_quarantined;
      return GroundParameterProxyDisposition::Consumed;
    }
    fail_session(now_ms);
    // The caller has already made the CRC-valid frame visible to the USB
    // admission decision. Preserve normal MAVLink transparency while the
    // proxy independently stops its unsafe session.
    return GroundParameterProxyDisposition::Forward;
  }

  if (native_stream_recovery_active_) {
    ++diagnostics_.native_stream_recovery_values_seen;
  }

  if (!usb_queued) {
    ++diagnostics_.matching_values_usb_rejected;
    if (config_.list_strategy == GroundParameterListStrategy::NativeStream) {
      fail_native_stream(GroundParameterRecoveryReason::UsbRejected,
                         &frame, now_ms);
    }
    return GroundParameterProxyDisposition::Consumed;
  }

  if (!count_known_) {
    param_count_ = count;
    count_known_ = true;
  }
  ++diagnostics_.matching_values_usb_queued;
  if (native_stream_recovery_active_) {
    ++diagnostics_.native_stream_recovery_values_usb_queued;
  }
  if (static_cast<std::uint32_t>(expected_index_) + 1U >= param_count_) {
    ++diagnostics_.sessions_completed;
    clear_session(GroundParameterProxyState::Complete, now_ms);
    return GroundParameterProxyDisposition::Consumed;
  }

  ++expected_index_;
  value_attempts_ = 0U;
  request_ = {};
  request_token_ = 0U;
  request_ready_ = false;
  backoff_is_retry_ = false;
  if (config_.list_strategy == GroundParameterListStrategy::NativeStream &&
      !native_stream_recovery_active_) {
    // Pixhawk owns the remaining stream. Refresh only the bounded inter-value
    // watchdog; never synthesize a per-index uplink request.
    deadline_ms_ = deadline_after(now_ms, config_.value_timeout_ms);
    state_ = GroundParameterProxyState::AwaitingValue;
  } else {
    deadline_ms_ = deadline_after(now_ms, config_.request_pacing_ms);
    state_ = GroundParameterProxyState::Backoff;
  }
  return GroundParameterProxyDisposition::Consumed;
}

std::uint32_t GroundParameterDownloadProxy::allocate_token() noexcept {
  std::uint32_t token = next_token_++;
  if (token == 0U) {
    token = next_token_++;
  }
  return token;
}

bool GroundParameterDownloadProxy::prepare_request(
    std::uint64_t now_ms) noexcept {
  if (request_ready_ || !active()) {
    return request_ready_;
  }
  if (config_.list_strategy == GroundParameterListStrategy::NativeStream &&
      !native_stream_recovery_active_) {
    // Native mode has exactly one original #21 lease, installed by
    // start_session(). Reaching request preparation later would violate that
    // invariant; fail safe instead of creating an indexed #20.
    fail_session(now_ms);
    return false;
  }

  std::array<std::uint8_t, 20U> payload{};
  write_u16(payload.data(), expected_index_);
  payload[2] = target_system_;
  payload[3] = target_component_;
  const bool encoded =
      request_version_ == MavlinkVersion::V1
          ? encode_mavlink_v1(next_sequence_, sender_system_,
                              generated_component_id(),
                              kParamRequestReadMessageId, payload.data(),
                              payload.size(), request_)
          : encode_mavlink_v2(next_sequence_, sender_system_,
                              generated_component_id(),
                              kParamRequestReadMessageId, payload.data(),
                              payload.size(), request_);
  if (!encoded) {
    if (config_.list_strategy == GroundParameterListStrategy::NativeStream) {
      poison_native_stream(now_ms);
    } else {
      fail_session(now_ms);
    }
    return false;
  }
  ++next_sequence_;

  request_token_ = allocate_token();
  request_ready_ = true;
  state_ = GroundParameterProxyState::Ready;
  ++diagnostics_.requests_generated;
  if (native_stream_recovery_active_) {
    ++diagnostics_.native_stream_recovery_requests_generated;
  }
  if (backoff_is_retry_) {
    ++diagnostics_.request_retries;
  }
  backoff_is_retry_ = false;
  return true;
}

void GroundParameterDownloadProxy::tick(std::uint64_t now_ms) noexcept {
  if (admitted_request_token_ != 0U &&
      now_ms >= admitted_request_deadline_ms_) {
    abandoned_admitted_request_token_ = admitted_request_token_;
    admitted_request_token_ = 0U;
    admitted_request_deadline_ms_ = 0U;
    admitted_request_dequeued_ = false;
    ++diagnostics_.request_commit_timeouts;
    if (config_.list_strategy == GroundParameterListStrategy::NativeStream) {
      poison_native_stream(now_ms);
    } else {
      fail_session(now_ms);
    }
    return;
  }

  if (state_ == GroundParameterProxyState::AwaitingValue) {
    if (now_ms < deadline_ms_) {
      return;
    }
    ++diagnostics_.value_timeouts;
    if (config_.list_strategy == GroundParameterListStrategy::NativeStream &&
        !native_stream_recovery_active_) {
      // Never replay #21. A stalled native stream changes once to bounded
      // index-addressed reads beginning at the exact uncommitted index.
      (void)begin_native_stream_recovery(
          GroundParameterRecoveryReason::InterValueTimeout, nullptr,
          now_ms);
      return;
    }
    if (value_attempts_ >= config_.max_value_attempts) {
      if (config_.list_strategy == GroundParameterListStrategy::NativeStream) {
        fail_native_stream(GroundParameterRecoveryReason::InterValueTimeout,
                           nullptr, now_ms);
      } else {
        fail_session(now_ms);
      }
      return;
    }
    request_ = {};
    request_token_ = 0U;
    request_ready_ = false;
    backoff_is_retry_ = true;
    deadline_ms_ = deadline_after(now_ms, config_.retry_backoff_ms);
    state_ = GroundParameterProxyState::Backoff;
    return;
  }

  if ((state_ == GroundParameterProxyState::Ready ||
       state_ == GroundParameterProxyState::Backoff) &&
      !request_ready_ && now_ms >= deadline_ms_) {
    (void)prepare_request(now_ms);
  }
}

bool GroundParameterDownloadProxy::peek_next_request(
    MavlinkFrame& frame, std::uint32_t& token) const noexcept {
  if (!request_ready_ || request_token_ == 0U) {
    return false;
  }
  frame = request_;
  token = request_token_;
  return true;
}

bool GroundParameterDownloadProxy::mark_request_admitted(
    std::uint32_t token, std::uint64_t now_ms) noexcept {
  if (!request_ready_ || token == 0U || token != request_token_ ||
      (admitted_request_token_ != 0U &&
       admitted_request_token_ != token) ||
      abandoned_admitted_request_token_ != 0U) {
    return false;
  }
  admitted_request_token_ = token;
  admitted_request_deadline_ms_ =
      deadline_after(now_ms, config_.value_timeout_ms);
  admitted_request_dequeued_ = false;
  return true;
}

bool GroundParameterDownloadProxy::mark_request_queue_progress(
    std::uint32_t token, std::uint64_t now_ms) noexcept {
  // A PARAM_SET can cancel a lease after its bytes entered the immutable
  // descriptor FIFO. It still has to drain byte-exactly, so its finite prefix
  // receives the same bounded no-progress treatment without reactivating the
  // cancelled logical session.
  if (token != 0U && token == cancelled_admitted_request_token_) {
    if (token != admitted_request_token_ || admitted_request_dequeued_ ||
        abandoned_admitted_request_token_ != 0U) {
      return false;
    }
    if (now_ms > admitted_request_deadline_ms_) {
      abandoned_admitted_request_token_ = admitted_request_token_;
      admitted_request_token_ = 0U;
      admitted_request_deadline_ms_ = 0U;
      admitted_request_dequeued_ = false;
      ++diagnostics_.request_commit_timeouts;
      return false;
    }
    admitted_request_deadline_ms_ =
        deadline_after(now_ms, config_.value_timeout_ms);
    ++diagnostics_.request_queue_progress_observed;
    return true;
  }
  if (!request_ready_ || token == 0U || token != request_token_ ||
      token != admitted_request_token_ || admitted_request_dequeued_ ||
      abandoned_admitted_request_token_ != 0U) {
    return false;
  }
  if (now_ms > admitted_request_deadline_ms_) {
    abandoned_admitted_request_token_ = admitted_request_token_;
    admitted_request_token_ = 0U;
    admitted_request_deadline_ms_ = 0U;
    admitted_request_dequeued_ = false;
    ++diagnostics_.request_commit_timeouts;
    if (config_.list_strategy == GroundParameterListStrategy::NativeStream) {
      poison_native_stream(now_ms);
    } else {
      fail_session(now_ms);
    }
    return false;
  }
  admitted_request_deadline_ms_ =
      deadline_after(now_ms, config_.value_timeout_ms);
  ++diagnostics_.request_queue_progress_observed;
  return true;
}

bool GroundParameterDownloadProxy::mark_request_dequeued(
    std::uint32_t token, std::uint64_t now_ms) noexcept {
  if (token != 0U && token == cancelled_admitted_request_token_) {
    if (token != admitted_request_token_ || admitted_request_dequeued_ ||
        abandoned_admitted_request_token_ != 0U) {
      return false;
    }
    if (now_ms > admitted_request_deadline_ms_) {
      abandoned_admitted_request_token_ = admitted_request_token_;
      admitted_request_token_ = 0U;
      admitted_request_deadline_ms_ = 0U;
      admitted_request_dequeued_ = false;
      ++diagnostics_.request_commit_timeouts;
      return false;
    }
    admitted_request_dequeued_ = true;
    admitted_request_deadline_ms_ =
        deadline_after(now_ms, config_.value_timeout_ms);
    ++diagnostics_.request_dequeues_observed;
    return true;
  }
  if (!request_ready_ || token == 0U || token != request_token_ ||
      token != admitted_request_token_ ||
      abandoned_admitted_request_token_ != 0U) {
    return false;
  }
  if (now_ms > admitted_request_deadline_ms_) {
    abandoned_admitted_request_token_ = admitted_request_token_;
    admitted_request_token_ = 0U;
    admitted_request_deadline_ms_ = 0U;
    admitted_request_dequeued_ = false;
    ++diagnostics_.request_commit_timeouts;
    if (config_.list_strategy == GroundParameterListStrategy::NativeStream) {
      poison_native_stream(now_ms);
    } else {
      fail_session(now_ms);
    }
    return false;
  }
  if (!admitted_request_dequeued_) {
    admitted_request_dequeued_ = true;
    admitted_request_deadline_ms_ =
        deadline_after(now_ms, config_.value_timeout_ms);
    ++diagnostics_.request_dequeues_observed;
  }
  return true;
}

bool GroundParameterDownloadProxy::complete_request_tx(
    std::uint32_t token, TxResult result,
    std::uint64_t now_ms) noexcept {
  if (token != 0U && token == abandoned_admitted_request_token_) {
    // The product bridge fail-closes when this tombstone appears. Keep it
    // until reset even if a late physical callback arrives, so no subsequent
    // #21 can re-arm while an unobservable stale #20/#22 may still exist.
    ++diagnostics_.stale_completions;
    return false;
  }
  if (token != 0U && token == cancelled_admitted_request_token_) {
    cancelled_admitted_request_token_ = 0U;
    admitted_request_token_ = 0U;
    admitted_request_deadline_ms_ = 0U;
    admitted_request_dequeued_ = false;
    stale_response_quarantine_deadline_ms_ =
        deadline_after(now_ms, config_.value_timeout_ms);
    ++diagnostics_.stale_request_dequeues_observed;
    ++diagnostics_.stale_completions;
    return false;
  }
  if (!request_ready_ || token == 0U || token != request_token_) {
    if (token != 0U && token == admitted_request_token_) {
      admitted_request_token_ = 0U;
      admitted_request_deadline_ms_ = 0U;
      admitted_request_dequeued_ = false;
    }
    ++diagnostics_.stale_completions;
    return false;
  }
  if (result == TxResult::Rejected) {
    ++diagnostics_.request_tx_rejected;
    return true;
  }

  ++diagnostics_.request_tx_accepted;
  if (native_stream_recovery_active_ &&
      request_.message_id == kParamRequestReadMessageId) {
    ++diagnostics_.native_stream_recovery_request_tx_accepted;
  }
  if (admitted_request_token_ == token) {
    admitted_request_token_ = 0U;
  }
  request_ = {};
  request_token_ = 0U;
  admitted_request_token_ = 0U;
  admitted_request_deadline_ms_ = 0U;
  admitted_request_dequeued_ = false;
  request_ready_ = false;
  ++value_attempts_;
  deadline_ms_ = deadline_after(now_ms, config_.value_timeout_ms);
  state_ = GroundParameterProxyState::AwaitingValue;
  return true;
}

bool GroundParameterDownloadProxy::active() const noexcept {
  return state_ == GroundParameterProxyState::Ready ||
         state_ == GroundParameterProxyState::AwaitingValue ||
         state_ == GroundParameterProxyState::Backoff;
}

void GroundParameterDownloadProxy::clear_session(
    GroundParameterProxyState terminal_state,
    std::uint64_t now_ms) noexcept {
  request_ = {};
  request_token_ = 0U;
  value_attempts_ = 0U;
  request_ready_ = false;
  backoff_is_retry_ = false;
  if (terminal_state == GroundParameterProxyState::Idle) {
    deadline_ms_ = 0U;
    expected_index_ = 0U;
    param_count_ = 0U;
    count_known_ = false;
    target_system_ = 0U;
    target_component_ = 0U;
    sender_system_ = 0U;
    sender_component_ = 0U;
    request_version_ = MavlinkVersion::V2;
    reset_background_coalescing();
    next_ping_forward_ms_ = 0U;
    next_timesync_forward_ms_ = 0U;
    ping_forwarded_ = false;
    timesync_forwarded_ = false;
    quarantined_param_id_ = {};
    parameter_set_quarantine_active_ = false;
    quarantine_all_parameter_values_ = false;
    quarantine_target_system_ = 0U;
    quarantine_target_component_ = 0U;
    stale_response_quarantine_deadline_ms_ = 0U;
    admitted_request_token_ = 0U;
    cancelled_admitted_request_token_ = 0U;
    abandoned_admitted_request_token_ = 0U;
    admitted_request_deadline_ms_ = 0U;
    admitted_request_dequeued_ = false;
    native_stream_recovery_active_ = false;
  } else {
    deadline_ms_ = deadline_after(now_ms, config_.terminal_hold_ms);
    if (background_retry_armed_ &&
        background_retry_not_before_ms_ < deadline_ms_) {
      // Complete/Failed retain the session fingerprint during the terminal
      // hold. Keep every already-known background retry behind the same
      // boundary even when its active-session retry gate expired earlier.
      background_retry_not_before_ms_ = deadline_ms_;
    }
  }
  state_ = terminal_state;
}

void GroundParameterDownloadProxy::fail_session(
    std::uint64_t now_ms) noexcept {
  ++diagnostics_.sessions_failed;
  clear_session(GroundParameterProxyState::Failed, now_ms);
}

void GroundParameterDownloadProxy::cancel() noexcept {
  if (active()) {
    ++diagnostics_.sessions_cancelled;
  }
  clear_session(GroundParameterProxyState::Idle, 0U);
}

void GroundParameterDownloadProxy::reset() noexcept {
  diagnostics_ = {};
  next_token_ = 1U;
  next_sequence_ = 0U;
  sequence_initialized_ = false;
  native_stream_poisoned_ = false;
  recovery_latch_ = {};
  clear_session(GroundParameterProxyState::Idle, 0U);
}

}  // namespace vc_lora
