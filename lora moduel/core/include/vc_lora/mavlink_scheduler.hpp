#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_types.hpp"

namespace vc_lora {

enum class MavlinkEnqueueStatus : std::uint8_t {
  NeedMore,
  Queued,
  Filtered,
  DroppedFull,
  Invalid,
};

enum class MavlinkParameterRequestStatus : std::uint8_t {
  Ignored,
  Remembered,
  Duplicate,
  Full,
  Invalid,
  Busy,
};

enum class MavlinkBulkPeekStatus : std::uint8_t {
  FrameReady = 0U,
  Empty,
  NoEligibleFrame,
  BlockedByActiveFrame,
  InvalidArgument,
};

enum class MavlinkBulkHeartbeatPolicyStatus : std::uint8_t {
  Started = 0U,
  Ended,
  AlreadyActive,
  NotActive,
  BlockedByActiveFrame,
};

struct MavlinkSchedulerDiagnostics {
  std::uint64_t frames_ingested{0};
  std::uint64_t frames_queued{0};
  std::uint64_t frames_forwarded{0};
  std::uint64_t bytes_forwarded{0};
  std::uint64_t msg194_frames_filtered{0};
  std::uint64_t msg194_bytes_filtered{0};
  std::uint64_t policy_filtered_frames{0};
  std::uint64_t policy_filtered_bytes{0};
  std::uint64_t rate_limited_frames{0};
  std::uint64_t rate_limited_bytes{0};
  std::uint64_t invalid_frames{0};
  std::uint64_t queue_drop_frames{0};
  std::uint64_t queue_drop_bytes{0};
  std::uint64_t rejected_send_attempts{0};
  std::uint64_t parameter_requests_observed{0};
  std::uint64_t parameter_requests_remembered{0};
  std::uint64_t parameter_request_duplicates{0};
  std::uint64_t parameter_request_tracker_overflows{0};
  std::uint64_t parameter_request_invalid_frames{0};
  std::uint64_t target_parameter_frames_queued{0};
  std::uint64_t target_parameter_duplicate_frames{0};
  std::uint64_t target_parameter_selections{0};
  std::uint64_t target_parameter_chunks_forwarded{0};
  std::uint64_t target_parameter_frames_completed{0};
  std::uint64_t target_parameter_rejected_attempts{0};
  std::uint64_t target_heartbeat_yields{0};
  std::uint64_t native_list_fences_committed{0};
  std::uint64_t native_list_fence_busy{0};
  std::uint64_t native_list_stale_frames_cancelled{0};
  std::uint64_t native_list_stale_bytes_cancelled{0};
  std::uint64_t native_list_stale_frames_filtered{0};
  std::uint64_t native_list_stat_runtime_frames_cancelled{0};
  std::uint64_t native_list_stat_runtime_bytes_cancelled{0};
  std::uint64_t native_list_other_frames_cancelled{0};
  std::uint64_t native_list_other_bytes_cancelled{0};
  std::uint64_t native_list_stat_runtime_frames_filtered{0};
  std::uint64_t native_list_other_frames_filtered{0};
  std::uint64_t native_list_stat_runtime_first_filter_ms{0};
  std::uint64_t native_list_stat_runtime_last_filter_ms{0};
  std::uint64_t native_list_stat_runtime_min_filter_gap_ms{0};
  std::uint64_t native_list_stat_runtime_filter_time_regressions{0};
  std::uint64_t native_list_stale_classification_errors{0};
  std::uint64_t native_list_unexpected_ms{0};
  std::array<std::uint8_t, 16U> native_list_unexpected_parameter_id{};
  std::uint32_t native_list_unexpected_value_bits{0};
  std::uint16_t native_list_unexpected_frame_size{0};
  std::uint16_t native_list_unexpected_index{0};
  std::uint16_t native_list_unexpected_count{0};
  std::uint16_t native_list_unexpected_mismatch_mask{0};
  std::uint8_t native_list_unexpected_latched{0};
  std::uint8_t native_list_unexpected_reason{0};
  std::uint8_t native_list_unexpected_version{0};
  std::uint8_t native_list_unexpected_signed{0};
  std::uint8_t native_list_unexpected_payload_length{0};
  std::uint8_t native_list_unexpected_system_id{0};
  std::uint8_t native_list_unexpected_component_id{0};
  std::uint8_t native_list_unexpected_sequence{0};
  std::uint8_t native_list_unexpected_type{0};
  std::uint64_t native_list_frames_queued{0};
  std::uint64_t native_list_sequence_failures{0};
  std::uint64_t bulk_heartbeat_sessions_started{0};
  std::uint64_t bulk_heartbeat_sessions_ended{0};
  std::uint64_t bulk_heartbeat_start_blocked_active{0};
  std::uint64_t bulk_heartbeat_prestart_seen_frames{0};
  std::uint64_t bulk_heartbeat_prestart_seen_bytes{0};
  std::uint64_t bulk_heartbeat_prestart_retained_frames{0};
  std::uint64_t bulk_heartbeat_prestart_retained_bytes{0};
  std::uint64_t bulk_heartbeat_prestart_coalesced_frames{0};
  std::uint64_t bulk_heartbeat_prestart_coalesced_bytes{0};
  std::uint64_t bulk_heartbeat_input_frames{0};
  std::uint64_t bulk_heartbeat_input_bytes{0};
  std::uint64_t bulk_heartbeat_admitted_frames{0};
  std::uint64_t bulk_heartbeat_admitted_bytes{0};
  std::uint64_t bulk_heartbeat_rate_violation_frames{0};
  std::uint64_t bulk_heartbeat_rate_violation_bytes{0};
  std::uint64_t bulk_heartbeat_filtered_frames{0};
  std::uint64_t bulk_heartbeat_filtered_bytes{0};
  std::uint64_t bulk_heartbeat_runtime_coalesced_frames{0};
  std::uint64_t bulk_heartbeat_runtime_coalesced_bytes{0};
  std::uint64_t bulk_heartbeat_time_regressions{0};
  std::size_t max_queue_frames{0};
  std::size_t max_queue_bytes{0};
};

// Coherent metadata for the oldest retained real heartbeat. The scheduler's
// fixed order is the retry identity; a rejected physical write leaves both
// order and enqueued_ms unchanged.
struct MavlinkHeartbeatCandidate {
  std::uint64_t order{0U};
  std::uint64_t enqueued_ms{0U};
  std::size_t frame_bytes{0U};
  std::size_t remaining_bytes{0U};
  bool present{false};
  bool tail_available{false};
  bool active{false};
  bool active_started{false};
};

class MavlinkFrameScheduler {
 public:
  static constexpr std::size_t capacity() noexcept { return 8U; }
  static constexpr std::size_t parameter_download_frame_capacity() noexcept {
    return 1024U;
  }
  static constexpr std::size_t parameter_download_byte_capacity() noexcept {
    return 64U * 1024U;
  }
  static constexpr std::size_t parameter_request_capacity() noexcept {
    return 8U;
  }
  static constexpr std::size_t target_parameter_capacity() noexcept {
    return parameter_request_capacity();
  }
  static constexpr std::uint64_t
  bulk_heartbeat_admission_interval_ms() noexcept {
    return 1000U;
  }

  // The timestamped overload is the production path: selected display
  // telemetry is admitted at most once per 1000 ms bucket.  The no-timestamp
  // overload is pinned to time zero for legacy frame-boundary tests; recurring
  // telemetry therefore fails closed instead of bypassing the limiter.
  MavlinkEnqueueStatus enqueue(const MavlinkFrame& frame) noexcept;
  MavlinkEnqueueStatus enqueue(const MavlinkFrame& frame,
                               std::uint64_t now_ms) noexcept;
  MavlinkEnqueueStatus ingest_byte(std::uint8_t byte) noexcept;
  MavlinkEnqueueStatus ingest_byte(std::uint8_t byte,
                                   std::uint64_t now_ms) noexcept;

  // Vehicle calls this only after a complete, CRC-valid uplink frame has been
  // admitted to the D6 Pixhawk egress. A later D7 PARAM_VALUE that matches the
  // remembered request is placed in a fixed priority lane instead of behind
  // an older parameter-list download. In index mode param_id is unused;
  // target system/component 0 retain their MAVLink broadcast-wildcard meaning.
  // Duplicate requests and responses are coalesced only after all matching
  // Pending request owners have received one queued response.
  MavlinkParameterRequestStatus remember_parameter_request(
      const MavlinkFrame& frame) noexcept;

  // A native PARAM_REQUEST_LIST has no transaction identifier in its #22
  // responses. At a complete-frame D6 admission boundary, cancel only the
  // unsent generic PARAM_VALUE backlog and establish a fresh ordered generation
  // fence. Heartbeat/urgent slots and the #20 target-response lane are never
  // touched. A partially active generic frame or pending #20 owner makes the
  // fence Busy so an already-started wire frame cannot be split or forgotten.
  bool can_begin_native_parameter_list() const noexcept;
  MavlinkParameterRequestStatus begin_native_parameter_list(
      const MavlinkFrame& frame) noexcept;
  MavlinkParameterRequestStatus begin_native_parameter_list(
      const MavlinkFrame& frame, std::uint64_t now_ms) noexcept;

  // This policy is opt-in and affects only real HEARTBEAT ingress while a
  // negotiated bulk session is active. Session start is allowed only without
  // a scheduler-owned frame. It retains the newest complete pre-session
  // heartbeat, caps later pending heartbeats at one, and leaves active bytes
  // untouched. Ending the policy restores the existing enqueue behavior.
  MavlinkBulkHeartbeatPolicyStatus begin_bulk_heartbeat_policy(
      std::uint64_t now_ms) noexcept;
  MavlinkBulkHeartbeatPolicyStatus end_bulk_heartbeat_policy() noexcept;
  bool bulk_heartbeat_policy_active() const noexcept {
    return bulk_heartbeat_policy_active_;
  }

  // peek() makes one frame active and returns a prefix without consuming it.
  // complete_send(Accepted, n) is the only operation that consumes bytes;
  // Rejected keeps the prefix available for an identical retry.
  std::size_t peek(std::uint8_t* output, std::size_t max_size) noexcept;
  // Bulk mode has a separate selector and does not alter peek() ordering.
  // When no standard frame is already active, select only one complete real
  // HEARTBEAT, target PARAM_VALUE, or generic/native PARAM_VALUE in that
  // order. Unsupported queued traffic remains inactive for standard mode.
  // A caller must supply full MAVLink-frame storage so this API never exposes
  // a prefix as a bulk candidate.
  MavlinkBulkPeekStatus peek_bulk_frame(
      std::uint8_t* output, std::size_t max_size,
      std::size_t& output_size) noexcept;
  bool complete_send(TxResult result, std::size_t byte_count) noexcept;

  bool empty() const noexcept {
    return slot_count_ == 0U && parameter_frame_count_ == 0U &&
           target_parameter_count_ == 0U;
  }
  std::size_t size() const noexcept {
    return slot_count_ + parameter_frame_count_ + target_parameter_count_;
  }
  std::size_t queued_bytes() const noexcept { return queued_bytes_; }
  bool has_active_frame() const noexcept {
    return active_index_ < capacity() || parameter_active_ ||
           target_parameter_active_;
  }
  std::size_t pending_parameter_requests() const noexcept {
    return parameter_request_count_;
  }
  std::size_t prioritized_parameter_values() const noexcept {
    return target_parameter_count_;
  }
  // Introspection for diagnostic stale-backlog gates. These expose only the
  // dedicated generic PARAM_VALUE FIFO; target-priority responses remain
  // separately visible through prioritized_parameter_values().
  std::size_t parameter_download_queued_frames() const noexcept {
    return parameter_frame_count_;
  }
  bool parameter_download_active() const noexcept {
    return parameter_active_;
  }
  // True only for a CRC-valid, real Pixhawk heartbeat retained by the fixed
  // scheduler. The TDD controller uses this at the nominal downlink boundary;
  // it never synthesizes a replacement heartbeat.
  bool has_pending_heartbeat() const noexcept;
  // True when a retained heartbeat is eligible as the next complete-frame
  // tail. Once one heartbeat has yielded ahead of a waiting target response,
  // a second queued heartbeat is not advertised until that target is active.
  bool heartbeat_tail_available() const noexcept;
  MavlinkHeartbeatCandidate heartbeat_candidate() const noexcept;
  bool active_frame_is_heartbeat() const noexcept;
  bool active_frame_has_progress() const noexcept;
  bool has_seen_heartbeat() const noexcept { return heartbeat_seen_; }
  const MavlinkSchedulerDiagnostics& diagnostics() const noexcept {
    return diagnostics_;
  }
  const MavlinkParserDiagnostics& parser_diagnostics() const noexcept {
    return parser_.diagnostics();
  }
  void reset() noexcept;

 private:
  enum class Priority : std::uint8_t {
    Heartbeat = 0U,
    Urgent = 1U,
    Normal = 2U,
  };

  enum class RateBucket : std::uint8_t {
    SysStatus = 0U,
    SystemTime,
    TimeSync,
    Gps,
    Attitude,
    GlobalPosition,
    VfrHud,
    Power,
    Estimator,
    VehicleStatus,
    Count,
    None = 0xFFU,
  };

  struct RateBucketState {
    std::uint64_t last_queued_ms{0};
    bool initialized{false};
  };

  struct Slot {
    MavlinkFrame frame{};
    std::uint64_t order{0};
    std::uint64_t enqueued_ms{0};
    Priority priority{Priority::Normal};
    bool occupied{false};
  };

  enum class ParameterRequestState : std::uint8_t {
    Empty,
    Pending,
    ResponseQueued,
  };

  enum class NativeParameterListState : std::uint8_t {
    Idle,
    AwaitingFirst,
    Streaming,
    Complete,
  };

  struct ParameterRequestIdentity {
    std::array<std::uint8_t, 16U> parameter_id{};
    std::uint16_t parameter_index{0xFFFFU};
    std::uint8_t target_system{0U};
    std::uint8_t target_component{0U};
    ParameterRequestState state{ParameterRequestState::Empty};
  };

  struct TargetParameterFrame {
    MavlinkFrame frame{};
    std::size_t request_slot{parameter_request_capacity()};
  };

  static Priority priority_for(std::uint32_t message_id) noexcept;
  static RateBucket rate_bucket_for(std::uint32_t message_id) noexcept;
  static bool is_policy_filtered(std::uint32_t message_id) noexcept;
  MavlinkEnqueueStatus enqueue_impl(const MavlinkFrame& frame,
                                    std::uint64_t now_ms,
                                    bool apply_rate_limit) noexcept;
  MavlinkEnqueueStatus enqueue_bulk_heartbeat(
      const MavlinkFrame& frame, std::uint64_t now_ms) noexcept;
  MavlinkEnqueueStatus enqueue_parameter_value(
      const MavlinkFrame& frame) noexcept;
  MavlinkEnqueueStatus enqueue_target_parameter_value(
      const MavlinkFrame& frame, std::size_t request_slot) noexcept;
  MavlinkEnqueueStatus enqueue_native_parameter_value(
      const MavlinkFrame& frame, std::uint64_t now_ms) noexcept;
  static bool is_exact_stat_runtime(
      const MavlinkFrame& frame) noexcept;
  static std::uint16_t stat_runtime_mismatch_mask(
      const MavlinkFrame& frame) noexcept;
  void latch_native_list_unexpected(const MavlinkFrame& frame,
                                    std::uint8_t reason,
                                    std::uint64_t now_ms) noexcept;
  void classify_cancelled_native_backlog(std::uint64_t now_ms) noexcept;
  void record_native_list_filtered(const MavlinkFrame& frame,
                                   std::uint64_t now_ms) noexcept;
  std::size_t find_parameter_request(
      const MavlinkFrame& response,
      ParameterRequestState state) const noexcept;
  static bool same_parameter_request(
      const ParameterRequestIdentity& left,
      const ParameterRequestIdentity& right) noexcept;
  static bool parameter_response_matches(
      const ParameterRequestIdentity& request,
      const MavlinkFrame& response) noexcept;
  void release_parameter_request(std::size_t request_slot) noexcept;
  bool parameter_value_precedes(std::size_t slot_index) const noexcept;
  std::size_t find_free_slot() const noexcept;
  std::size_t choose_next_slot() const noexcept;
  std::size_t choose_eviction(Priority incoming) const noexcept;
  void drop_slot(std::size_t index) noexcept;
  void update_high_watermarks() noexcept;

  std::array<Slot, 8U> slots_{};
  std::array<std::uint8_t, 64U * 1024U> parameter_bytes_{};
  std::array<std::uint16_t, 1024U> parameter_lengths_{};
  std::array<ParameterRequestIdentity, 8U> parameter_requests_{};
  std::array<TargetParameterFrame, 8U> target_parameter_frames_{};
  std::array<RateBucketState,
             static_cast<std::size_t>(RateBucket::Count)>
      rate_buckets_{};
  MavlinkStreamParser parser_{};
  MavlinkSchedulerDiagnostics diagnostics_{};
  std::size_t slot_count_{0};
  std::size_t queued_bytes_{0};
  std::size_t active_index_{capacity()};
  std::size_t active_offset_{0};
  std::size_t parameter_byte_head_{0U};
  std::size_t parameter_byte_tail_{0U};
  std::size_t parameter_byte_count_{0U};
  std::size_t parameter_frame_head_{0U};
  std::size_t parameter_frame_tail_{0U};
  std::size_t parameter_frame_count_{0U};
  std::size_t parameter_active_offset_{0U};
  bool parameter_active_{false};
  std::size_t parameter_request_count_{0U};
  std::size_t target_parameter_head_{0U};
  std::size_t target_parameter_tail_{0U};
  std::size_t target_parameter_count_{0U};
  std::size_t target_parameter_active_offset_{0U};
  bool target_parameter_active_{false};
  bool target_heartbeat_yielded_{false};
  NativeParameterListState native_list_state_{
      NativeParameterListState::Idle};
  std::uint16_t native_list_expected_index_{0U};
  std::uint16_t native_list_parameter_count_{0U};
  std::uint8_t native_list_target_system_{0U};
  std::uint8_t native_list_target_component_{0U};
  std::size_t last_peek_size_{0};
  std::uint64_t next_order_{0};
  std::uint64_t bulk_heartbeat_last_admitted_ms_{0U};
  bool heartbeat_seen_{false};
  bool bulk_heartbeat_policy_active_{false};
};

}  // namespace vc_lora
