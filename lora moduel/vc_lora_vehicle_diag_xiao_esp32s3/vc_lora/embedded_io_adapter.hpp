#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/byte_ring_buffer.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_types.hpp"

namespace vc_lora {

constexpr std::size_t kGroundMavlinkIngressBytes = 16U * 1024U;
// MAVLink 1 can be as short as its 8-byte protocol overhead. This count can
// therefore describe every possible complete frame which fits in the 16 KiB
// byte ring, without making descriptors an earlier hidden capacity limit.
constexpr std::size_t kGroundMavlinkDescriptorCapacity =
    kGroundMavlinkIngressBytes / 8U;
constexpr std::size_t kLocalEgressBytes = 4U * 1024U;
constexpr std::size_t kEmbeddedPhysicalWriteBytes = 32U;

enum class FrameIngressStatus : std::uint8_t {
  NeedMore,
  Queued,
  Ignored,
  Invalid,
  DroppedOverflow,
  FailClosed,
};

struct GroundIngressStats {
  std::uint64_t bytes_ingested{0};
  std::uint64_t frames_completed{0};
  std::uint64_t frames_queued{0};
  std::uint64_t bytes_queued{0};
  std::uint64_t frames_dequeued{0};
  std::uint64_t bytes_committed{0};
  std::uint64_t frames_dropped{0};
  std::uint64_t bytes_dropped{0};
  std::uint64_t overflow_events{0};
  std::uint64_t rejected_commits{0};
  std::uint64_t invalid_commits{0};
  std::size_t max_queued_bytes{0};
  std::size_t max_queued_frames{0};
};

// Fixed, frame-atomic Mission Planner ingress for the Ground adapter. Bytes
// do not become visible to the TDD/RF side until the stream parser has
// validated a complete MAVLink frame. A descriptor remains associated with
// the byte ring until all of that frame's application bytes are committed.
//
// Overflow is fail-closed because dropping one complete frame leaves a stream
// which can no longer be claimed lossless. reset() is the explicit recovery
// boundary; a failed-closed instance never emits a partial surviving stream.
class GroundMavlinkIngressAdapter {
 public:
  static constexpr std::size_t byte_capacity() noexcept {
    return kGroundMavlinkIngressBytes;
  }
  static constexpr std::size_t descriptor_capacity() noexcept {
    return kGroundMavlinkDescriptorCapacity;
  }

  FrameIngressStatus ingest_byte(std::uint8_t byte) noexcept {
    ++stats_.bytes_ingested;
    if (fail_closed_) {
      return FrameIngressStatus::FailClosed;
    }

    MavlinkFrame frame{};
    const MavlinkParseStatus status = parser_.push(byte, frame);
    switch (status) {
      case MavlinkParseStatus::NeedMore:
        return FrameIngressStatus::NeedMore;
      case MavlinkParseStatus::FrameReady:
        ++stats_.frames_completed;
        return queue_frame(frame);
      case MavlinkParseStatus::Noise:
        return FrameIngressStatus::Ignored;
      case MavlinkParseStatus::BadLength:
      case MavlinkParseStatus::BadCrc:
      case MavlinkParseStatus::UnsupportedMessage:
      case MavlinkParseStatus::UnsupportedFlags:
        return FrameIngressStatus::Invalid;
    }
    return FrameIngressStatus::Invalid;
  }

  std::size_t ingest(const std::uint8_t* data, std::size_t count) noexcept {
    if (data == nullptr || count == 0U || fail_closed_) {
      return 0U;
    }
    std::size_t consumed = 0U;
    while (consumed < count && !fail_closed_) {
      (void)ingest_byte(data[consumed]);
      ++consumed;
    }
    return consumed;
  }

  // Peek latches one application prefix. Rejected completion and concurrent
  // ingress cannot change the bytes returned by the next peek.
  std::size_t peek(std::uint8_t* output, std::size_t output_capacity) noexcept {
    if (output == nullptr || output_capacity == 0U || fail_closed_) {
      return 0U;
    }
    if (lease_size_ == 0U) {
      lease_size_ = std::min(
          {bytes_.size(), output_capacity, kEmbeddedPhysicalWriteBytes});
      if (lease_size_ == 0U) {
        return 0U;
      }
      const std::size_t copied =
          bytes_.copy_front(lease_.data(), lease_size_);
      if (copied != lease_size_) {
        fail_closed_ = true;
        ++stats_.invalid_commits;
        lease_size_ = 0U;
        return 0U;
      }
    }
    // A scheduler may first preview a full physical lease, then request the
    // smaller application prefix which fits after link-data escaping.  Keep
    // the original lease latched for retry, but expose any non-empty prefix
    // the caller can hold.
    const std::size_t visible_size =
        std::min(output_capacity, lease_size_);
    std::copy_n(lease_.data(), visible_size, output);
    return visible_size;
  }

  // Only a fully Accepted physical transaction consumes application bytes.
  // A rejection preserves the exact latched prefix for retry.
  bool complete_send(TxResult result,
                     std::size_t application_bytes) noexcept {
    if (fail_closed_ || lease_size_ == 0U) {
      fail_invalid_commit();
      return false;
    }
    if (result == TxResult::Rejected) {
      ++stats_.rejected_commits;
      return false;
    }
    // Link-data escaping can make a 32-byte application lease require more
    // than one 32-byte physical transaction.  Commit only the largest
    // application prefix which actually fit on wire; the uncommitted suffix
    // remains at the front of the source ring and is re-latched on the next
    // peek.  A rejected transaction above still retains the exact full lease
    // for an identical retry.
    if (application_bytes == 0U || application_bytes > lease_size_ ||
        application_bytes > bytes_.size()) {
      fail_invalid_commit();
      return false;
    }

    if (bytes_.discard(application_bytes) != application_bytes ||
        !commit_descriptors(application_bytes)) {
      fail_invalid_commit();
      return false;
    }
    stats_.bytes_committed += application_bytes;
    lease_size_ = 0U;
    return true;
  }

  bool commit(TxResult result, std::size_t application_bytes) noexcept {
    return complete_send(result, application_bytes);
  }

  void reset() noexcept {
    bytes_.reset();
    parser_ = {};
    descriptors_ = {};
    descriptor_head_ = 0U;
    descriptor_tail_ = 0U;
    descriptor_count_ = 0U;
    lease_ = {};
    lease_size_ = 0U;
    fail_closed_ = false;
    stats_ = {};
  }

  bool fail_closed() const noexcept { return fail_closed_; }
  bool empty() const noexcept { return bytes_.empty(); }
  std::size_t queued_bytes() const noexcept { return bytes_.size(); }
  std::size_t queued_frames() const noexcept { return descriptor_count_; }
  std::size_t free_bytes() const noexcept { return bytes_.free_space(); }
  std::uint16_t front_frame_remaining() const noexcept {
    return descriptor_count_ == 0U
               ? 0U
               : descriptors_[descriptor_head_].remaining_bytes;
  }
  std::uint32_t front_message_id() const noexcept {
    return descriptor_count_ == 0U
               ? 0U
               : descriptors_[descriptor_head_].message_id;
  }
  const GroundIngressStats& stats() const noexcept { return stats_; }
  const MavlinkParserDiagnostics& parser_diagnostics() const noexcept {
    return parser_.diagnostics();
  }

 private:
  struct FrameDescriptor {
    std::uint32_t message_id{0};
    std::uint16_t frame_bytes{0};
    std::uint16_t remaining_bytes{0};
  };

  FrameIngressStatus queue_frame(const MavlinkFrame& frame) noexcept {
    if (frame.size == 0U || frame.size > kMavlinkMaxFrameBytes ||
        frame.size > bytes_.free_space() ||
        descriptor_count_ == descriptors_.size()) {
      ++stats_.frames_dropped;
      stats_.bytes_dropped += frame.size;
      ++stats_.overflow_events;
      fail_closed_ = true;
      return FrameIngressStatus::DroppedOverflow;
    }

    const std::size_t written = bytes_.write(frame.bytes.data(), frame.size);
    if (written != frame.size) {
      ++stats_.frames_dropped;
      stats_.bytes_dropped += frame.size;
      ++stats_.overflow_events;
      fail_closed_ = true;
      return FrameIngressStatus::DroppedOverflow;
    }

    descriptors_[descriptor_tail_] = {
        frame.message_id, static_cast<std::uint16_t>(frame.size),
        static_cast<std::uint16_t>(frame.size)};
    descriptor_tail_ = increment_descriptor(descriptor_tail_);
    ++descriptor_count_;
    ++stats_.frames_queued;
    stats_.bytes_queued += frame.size;
    stats_.max_queued_bytes =
        std::max(stats_.max_queued_bytes, bytes_.size());
    stats_.max_queued_frames =
        std::max(stats_.max_queued_frames, descriptor_count_);
    return FrameIngressStatus::Queued;
  }

  bool commit_descriptors(std::size_t count) noexcept {
    std::size_t remaining = count;
    while (remaining > 0U) {
      if (descriptor_count_ == 0U) {
        return false;
      }
      FrameDescriptor& descriptor = descriptors_[descriptor_head_];
      const std::size_t consumed =
          std::min<std::size_t>(remaining, descriptor.remaining_bytes);
      descriptor.remaining_bytes = static_cast<std::uint16_t>(
          descriptor.remaining_bytes - consumed);
      remaining -= consumed;
      if (descriptor.remaining_bytes == 0U) {
        descriptor = {};
        descriptor_head_ = increment_descriptor(descriptor_head_);
        --descriptor_count_;
        ++stats_.frames_dequeued;
      }
    }
    return true;
  }

  void fail_invalid_commit() noexcept {
    ++stats_.invalid_commits;
    fail_closed_ = true;
  }

  static constexpr std::size_t increment_descriptor(
      std::size_t index) noexcept {
    return index + 1U == kGroundMavlinkDescriptorCapacity ? 0U : index + 1U;
  }

  ByteRingBuffer<kGroundMavlinkIngressBytes> bytes_{};
  MavlinkStreamParser parser_{};
  std::array<FrameDescriptor, kGroundMavlinkDescriptorCapacity>
      descriptors_{};
  std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> lease_{};
  GroundIngressStats stats_{};
  std::size_t descriptor_head_{0};
  std::size_t descriptor_tail_{0};
  std::size_t descriptor_count_{0};
  std::size_t lease_size_{0};
  bool fail_closed_{false};
};

enum class UartWriteProgress : std::uint8_t {
  Zero,
  Partial,
  Complete,
  Invalid,
};

struct LocalEgressStats {
  std::uint64_t bytes_ingested{0};
  std::uint64_t bytes_queued{0};
  std::uint64_t bytes_dropped{0};
  std::uint64_t bytes_physically_accepted{0};
  std::uint64_t bytes_committed{0};
  std::uint64_t writes_completed{0};
  std::uint64_t zero_write_events{0};
  std::uint64_t short_write_events{0};
  std::uint64_t overflow_events{0};
  std::uint64_t invalid_completion_events{0};
  std::size_t max_queued_bytes{0};
};

// Reusable backpressure ring for Vehicle->Pixhawk and Ground->USB local UARTs.
// A staged prefix is copied out of the ring but not consumed until every byte
// has been accepted by the physical writer. Zero writes retry the full prefix;
// short writes retry the exact unaccepted suffix. New ingress remains ordered
// behind the staged data.
template <std::size_t Capacity = kLocalEgressBytes,
          std::size_t MaxWrite = kEmbeddedPhysicalWriteBytes>
class LocalEgressAdapter {
  static_assert(Capacity > 0U, "Local egress capacity must be non-zero");
  static_assert(MaxWrite > 0U, "Local egress write size must be non-zero");

 public:
  static constexpr std::size_t capacity() noexcept { return Capacity; }
  static constexpr std::size_t write_capacity() noexcept { return MaxWrite; }

  std::size_t ingest(const std::uint8_t* data, std::size_t count) noexcept {
    stats_.bytes_ingested += count;
    if (data == nullptr || count == 0U) {
      return 0U;
    }
    if (fail_closed_ || count > bytes_.free_space()) {
      stats_.bytes_dropped += count;
      ++stats_.overflow_events;
      fail_closed_ = true;
      return 0U;
    }
    const std::size_t written = bytes_.write(data, count);
    if (written != count) {
      stats_.bytes_dropped += count;
      ++stats_.overflow_events;
      fail_closed_ = true;
      return 0U;
    }
    stats_.bytes_queued += count;
    stats_.max_queued_bytes =
        std::max(stats_.max_queued_bytes, bytes_.size());
    return written;
  }

  std::size_t peek(std::uint8_t* output, std::size_t output_capacity) noexcept {
    if (output == nullptr || output_capacity == 0U || fail_closed_) {
      return 0U;
    }
    if (pending_size_ == 0U) {
      pending_size_ = std::min(bytes_.size(), MaxWrite);
      if (pending_size_ == 0U) {
        return 0U;
      }
      if (bytes_.copy_front(pending_.data(), pending_size_) != pending_size_) {
        fail_invalid_completion();
        return 0U;
      }
      pending_offset_ = 0U;
    }
    const std::size_t remaining = pending_size_ - pending_offset_;
    if (output_capacity < remaining) {
      return 0U;
    }
    std::copy_n(pending_.data() + pending_offset_, remaining, output);
    return remaining;
  }

  UartWriteProgress complete_write(std::size_t accepted_bytes) noexcept {
    if (fail_closed_ || pending_size_ == 0U) {
      fail_invalid_completion();
      return UartWriteProgress::Invalid;
    }
    const std::size_t remaining = pending_size_ - pending_offset_;
    if (accepted_bytes > remaining) {
      fail_invalid_completion();
      return UartWriteProgress::Invalid;
    }
    if (accepted_bytes == 0U) {
      ++stats_.zero_write_events;
      return UartWriteProgress::Zero;
    }

    stats_.bytes_physically_accepted += accepted_bytes;
    pending_offset_ += accepted_bytes;
    if (pending_offset_ < pending_size_) {
      ++stats_.short_write_events;
      return UartWriteProgress::Partial;
    }

    if (bytes_.discard(pending_size_) != pending_size_) {
      fail_invalid_completion();
      return UartWriteProgress::Invalid;
    }
    stats_.bytes_committed += pending_size_;
    ++stats_.writes_completed;
    pending_ = {};
    pending_size_ = 0U;
    pending_offset_ = 0U;
    return UartWriteProgress::Complete;
  }

  UartWriteProgress commit(std::size_t accepted_bytes) noexcept {
    return complete_write(accepted_bytes);
  }

  void reset() noexcept {
    bytes_.reset();
    pending_ = {};
    pending_size_ = 0U;
    pending_offset_ = 0U;
    fail_closed_ = false;
    stats_ = {};
  }

  bool fail_closed() const noexcept { return fail_closed_; }
  bool empty() const noexcept { return bytes_.empty(); }
  bool write_pending() const noexcept { return pending_size_ != 0U; }
  std::size_t queued_bytes() const noexcept { return bytes_.size(); }
  std::size_t free_bytes() const noexcept { return bytes_.free_space(); }
  std::size_t pending_bytes() const noexcept {
    return pending_size_ - pending_offset_;
  }
  const LocalEgressStats& stats() const noexcept { return stats_; }

 private:
  void fail_invalid_completion() noexcept {
    ++stats_.invalid_completion_events;
    fail_closed_ = true;
  }

  ByteRingBuffer<Capacity> bytes_{};
  std::array<std::uint8_t, MaxWrite> pending_{};
  LocalEgressStats stats_{};
  std::size_t pending_size_{0};
  std::size_t pending_offset_{0};
  bool fail_closed_{false};
};

using VehicleLocalEgressAdapter = LocalEgressAdapter<>;
using GroundLocalEgressAdapter = LocalEgressAdapter<>;

enum class ValidatedLocalIngressStatus : std::uint8_t {
  NeedMore,
  QueuedFrame,
  Ignored,
  Invalid,
  DroppedOverflow,
  FailClosed,
};

struct ValidatedLocalIngressStats {
  std::uint64_t bytes_ingested{0U};
  std::uint64_t frames_validated{0U};
  std::uint64_t frames_queued{0U};
  std::uint64_t bytes_queued{0U};
  std::uint64_t invalid_events{0U};
  std::uint64_t overflow_events{0U};
  std::uint64_t frames_dropped_overflow{0U};
  std::uint64_t bytes_dropped_overflow{0U};
};

enum class LocalEgressOverflowPolicy : std::uint8_t {
  FailClosed,
  DropNewestFrame,
};

// Final RF-to-local endpoint gate. Demux output is still untrusted: a bit
// error in the first VCTD magic byte makes a damaged control candidate look
// like application data. Only a complete, CRC-valid, allow-listed MAVLink
// frame is atomically admitted to the local UART/USB backpressure ring.
template <std::size_t Capacity = kLocalEgressBytes,
          std::size_t MaxWrite = kEmbeddedPhysicalWriteBytes,
          LocalEgressOverflowPolicy OverflowPolicy =
              LocalEgressOverflowPolicy::FailClosed>
class MavlinkValidatedLocalEgressAdapter {
 public:
  ValidatedLocalIngressStatus ingest_byte(std::uint8_t byte) noexcept {
    ++stats_.bytes_ingested;
    if (fail_closed()) {
      return ValidatedLocalIngressStatus::FailClosed;
    }

    MavlinkFrame frame{};
    const MavlinkParseStatus status = parser_.push(byte, frame);
    switch (status) {
      case MavlinkParseStatus::FrameReady:
        ++stats_.frames_validated;
        if (frame.size > egress_.free_bytes()) {
          ++stats_.overflow_events;
          ++stats_.frames_dropped_overflow;
          stats_.bytes_dropped_overflow += frame.size;
          if constexpr (OverflowPolicy ==
                        LocalEgressOverflowPolicy::FailClosed) {
            // Preserve the strict Vehicle/Pixhawk contract and the underlying
            // LocalEgressAdapter diagnostics. The Ground USB specialization
            // deliberately skips this call so its existing FIFO/pending
            // prefix remains usable when Mission Planner reconnects.
            (void)egress_.ingest(frame.bytes.data(), frame.size);
            fail_closed_ = true;
          }
          return ValidatedLocalIngressStatus::DroppedOverflow;
        }
        if (egress_.ingest(frame.bytes.data(), frame.size) != frame.size) {
          ++stats_.overflow_events;
          ++stats_.frames_dropped_overflow;
          stats_.bytes_dropped_overflow += frame.size;
          fail_closed_ = true;
          return ValidatedLocalIngressStatus::DroppedOverflow;
        }
        ++stats_.frames_queued;
        stats_.bytes_queued += frame.size;
        return ValidatedLocalIngressStatus::QueuedFrame;

      case MavlinkParseStatus::NeedMore:
        return ValidatedLocalIngressStatus::NeedMore;

      case MavlinkParseStatus::Noise:
        return ValidatedLocalIngressStatus::Ignored;

      case MavlinkParseStatus::BadLength:
      case MavlinkParseStatus::BadCrc:
      case MavlinkParseStatus::UnsupportedMessage:
      case MavlinkParseStatus::UnsupportedFlags:
        ++stats_.invalid_events;
        return ValidatedLocalIngressStatus::Invalid;
    }
    ++stats_.invalid_events;
    return ValidatedLocalIngressStatus::Invalid;
  }

  void reset_parser() noexcept { parser_.reset(); }

  void reset() noexcept {
    parser_ = {};
    egress_.reset();
    stats_ = {};
    fail_closed_ = false;
  }

  bool fail_closed() const noexcept {
    return fail_closed_ || egress_.fail_closed();
  }
  LocalEgressAdapter<Capacity, MaxWrite>& egress() noexcept {
    return egress_;
  }
  const LocalEgressAdapter<Capacity, MaxWrite>& egress() const noexcept {
    return egress_;
  }
  const MavlinkParserDiagnostics& parser_diagnostics() const noexcept {
    return parser_.diagnostics();
  }
  std::size_t parser_buffered_size() const noexcept {
    return parser_.buffered_size();
  }
  const ValidatedLocalIngressStats& stats() const noexcept { return stats_; }

 private:
  MavlinkStreamParser parser_{};
  LocalEgressAdapter<Capacity, MaxWrite> egress_{};
  ValidatedLocalIngressStats stats_{};
  bool fail_closed_{false};
};

}  // namespace vc_lora
