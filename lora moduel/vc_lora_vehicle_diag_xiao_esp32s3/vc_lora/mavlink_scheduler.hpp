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
  std::size_t max_queue_frames{0};
  std::size_t max_queue_bytes{0};
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

  // peek() makes one frame active and returns a prefix without consuming it.
  // complete_send(Accepted, n) is the only operation that consumes bytes;
  // Rejected keeps the prefix available for an identical retry.
  std::size_t peek(std::uint8_t* output, std::size_t max_size) noexcept;
  bool complete_send(TxResult result, std::size_t byte_count) noexcept;

  bool empty() const noexcept {
    return slot_count_ == 0U && parameter_frame_count_ == 0U;
  }
  std::size_t size() const noexcept {
    return slot_count_ + parameter_frame_count_;
  }
  std::size_t queued_bytes() const noexcept { return queued_bytes_; }
  bool has_active_frame() const noexcept {
    return active_index_ < capacity() || parameter_active_;
  }
  // True only for a CRC-valid, real Pixhawk heartbeat retained by the fixed
  // scheduler. The TDD controller uses this at the nominal downlink boundary;
  // it never synthesizes a replacement heartbeat.
  bool has_pending_heartbeat() const noexcept;
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
    Priority priority{Priority::Normal};
    bool occupied{false};
  };

  static Priority priority_for(std::uint32_t message_id) noexcept;
  static RateBucket rate_bucket_for(std::uint32_t message_id) noexcept;
  static bool is_policy_filtered(std::uint32_t message_id) noexcept;
  MavlinkEnqueueStatus enqueue_impl(const MavlinkFrame& frame,
                                    std::uint64_t now_ms,
                                    bool apply_rate_limit) noexcept;
  MavlinkEnqueueStatus enqueue_parameter_value(
      const MavlinkFrame& frame) noexcept;
  bool parameter_value_precedes(std::size_t slot_index) const noexcept;
  std::size_t find_free_slot() const noexcept;
  std::size_t choose_next_slot() const noexcept;
  std::size_t choose_eviction(Priority incoming) const noexcept;
  void drop_slot(std::size_t index) noexcept;
  void update_high_watermarks() noexcept;

  std::array<Slot, 8U> slots_{};
  std::array<std::uint8_t, 64U * 1024U> parameter_bytes_{};
  std::array<std::uint16_t, 1024U> parameter_lengths_{};
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
  std::size_t last_peek_size_{0};
  std::uint64_t next_order_{0};
  bool heartbeat_seen_{false};
};

}  // namespace vc_lora
