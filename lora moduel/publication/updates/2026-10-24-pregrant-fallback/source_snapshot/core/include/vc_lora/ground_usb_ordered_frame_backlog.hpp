#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/byte_ring_buffer.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/runtime_contract.hpp"

namespace vc_lora {

// A heartbeat can complete part-way through the first already-arriving 32-B
// RF application chunk. Preserve its full largest signed MAVLink2 wire image,
// the remaining 31 bytes of that boundary chunk, and four further chunks that
// can complete during 2200-ms hold + 100-ms loop jitter + 49-ms USB frame tail:
//
//   34 + 31 + floor((2200 + 100 + 49) / 550) * 32 = 193 bytes.
//
// Round that proof upward to the next physical chunk. At the 8-byte minimum
// MAVLink1 frame size, 224 bytes can contain at most 28 complete descriptors.
// A larger single frame cannot complete after the held HB within this fixed
// service interval; its parser tail remains outside this complete-frame FIFO
// while the timer continues to run.
constexpr std::size_t kGroundUsbOrderedHoldMs = 2200U + 100U + 49U;
constexpr std::size_t kGroundUsbMaximumSignedHeartbeatBytes =
    10U + 9U + 2U + kMavlinkSignatureBytes;
constexpr std::size_t kGroundUsbBoundaryTailBytes =
    FixedFirmwareContract::radio_chunk_bytes - 1U;
constexpr std::size_t kGroundUsbFollowingServiceChunks =
    kGroundUsbOrderedHoldMs /
    FixedFirmwareContract::e220_subpacket_service_floor_ms;
constexpr std::size_t kGroundUsbOrderedProofBytes =
    kGroundUsbMaximumSignedHeartbeatBytes + kGroundUsbBoundaryTailBytes +
    kGroundUsbFollowingServiceChunks *
        FixedFirmwareContract::radio_chunk_bytes;
constexpr std::size_t kGroundUsbOrderedBacklogBytes =
    ((kGroundUsbOrderedProofBytes +
      FixedFirmwareContract::radio_chunk_bytes - 1U) /
     FixedFirmwareContract::radio_chunk_bytes) *
    FixedFirmwareContract::radio_chunk_bytes;
constexpr std::size_t kGroundUsbMinimumMavlinkFrameBytes = 8U;
constexpr std::size_t kGroundUsbOrderedBacklogFrames =
    kGroundUsbOrderedBacklogBytes / kGroundUsbMinimumMavlinkFrameBytes;

static_assert(FixedFirmwareContract::radio_chunk_bytes == 32U &&
                  FixedFirmwareContract::
                          e220_subpacket_service_floor_ms == 550U,
              "Ground USB backlog proof requires fixed E220 service");
static_assert(kGroundUsbOrderedProofBytes == 193U &&
                  kGroundUsbOrderedBacklogBytes == 224U &&
                  kGroundUsbOrderedBacklogFrames == 28U,
              "Ground USB ordered backlog capacity proof changed");

enum class GroundUsbOrderedBacklogStatus : std::uint8_t {
  Queued,
  Invalid,
  Overflow,
};

struct GroundUsbOrderedBacklogDiagnostics {
  std::uint64_t frames_queued{0U};
  std::uint64_t frames_released{0U};
  std::uint64_t invalid_frames{0U};
  std::uint64_t overflow_frames{0U};
  std::uint64_t overflow_bytes{0U};
  std::uint64_t discarded_frames{0U};
  std::uint64_t discarded_bytes{0U};
  std::size_t max_bytes{0U};
  std::size_t max_frames{0U};
};

// Byte-exact, allocation-free FIFO for complete RF frames received after a
// paced primary heartbeat. Heartbeat markers occupy their original sequence
// position. Enqueue is frame-atomic: insufficient byte or descriptor capacity
// rejects the whole newest frame and leaves every earlier byte unchanged.
template <std::size_t ByteCapacity = kGroundUsbOrderedBacklogBytes,
          std::size_t FrameCapacity = kGroundUsbOrderedBacklogFrames>
class GroundUsbOrderedFrameBacklog {
  static_assert(ByteCapacity > 0U, "ordered backlog needs byte capacity");
  static_assert(FrameCapacity > 0U, "ordered backlog needs descriptors");

 public:
  static constexpr std::size_t byte_capacity() noexcept {
    return ByteCapacity;
  }
  static constexpr std::size_t frame_capacity() noexcept {
    return FrameCapacity;
  }

  // Non-mutating admission reservation used before the heartbeat pacer takes
  // ownership. enqueue() still performs authoritative CRC validation.
  bool can_enqueue(const MavlinkFrame& frame) const noexcept {
    return frame.size > 0U && frame.size <= frame.bytes.size() &&
           descriptor_count_ < descriptors_.size() &&
           frame.size <= bytes_.free_space();
  }

  GroundUsbOrderedBacklogStatus enqueue(
      const MavlinkFrame& frame, bool paced_heartbeat) noexcept {
    MavlinkFrame validated{};
    if (frame.size == 0U || frame.size > frame.bytes.size() ||
        validate_mavlink_frame(frame.bytes.data(), frame.size, validated) !=
            MavlinkParseStatus::FrameReady) {
      ++diagnostics_.invalid_frames;
      return GroundUsbOrderedBacklogStatus::Invalid;
    }
    if (descriptor_count_ >= descriptors_.size() ||
        validated.size > bytes_.free_space()) {
      ++diagnostics_.overflow_frames;
      diagnostics_.overflow_bytes += validated.size;
      return GroundUsbOrderedBacklogStatus::Overflow;
    }
    if (bytes_.write(validated.bytes.data(), validated.size) !=
        validated.size) {
      ++diagnostics_.overflow_frames;
      diagnostics_.overflow_bytes += validated.size;
      return GroundUsbOrderedBacklogStatus::Overflow;
    }
    descriptors_[descriptor_tail_].length =
        static_cast<std::uint16_t>(validated.size);
    descriptors_[descriptor_tail_].paced_heartbeat = paced_heartbeat;
    descriptor_tail_ = increment(descriptor_tail_);
    ++descriptor_count_;
    ++diagnostics_.frames_queued;
    diagnostics_.max_bytes =
        std::max(diagnostics_.max_bytes, bytes_.size());
    diagnostics_.max_frames =
        std::max(diagnostics_.max_frames, descriptor_count_);
    return GroundUsbOrderedBacklogStatus::Queued;
  }

  bool peek(MavlinkFrame& frame,
            bool& paced_heartbeat) const noexcept {
    if (descriptor_count_ == 0U) {
      return false;
    }
    const Descriptor& descriptor = descriptors_[descriptor_head_];
    if (descriptor.length == 0U ||
        descriptor.length > frame.bytes.size() ||
        bytes_.copy_front(frame.bytes.data(), descriptor.length) !=
            descriptor.length) {
      return false;
    }
    MavlinkFrame validated{};
    if (validate_mavlink_frame(frame.bytes.data(), descriptor.length,
                               validated) !=
        MavlinkParseStatus::FrameReady) {
      return false;
    }
    frame = validated;
    paced_heartbeat = descriptor.paced_heartbeat;
    return true;
  }

  bool pop_front() noexcept {
    if (descriptor_count_ == 0U) {
      return false;
    }
    const std::size_t length = descriptors_[descriptor_head_].length;
    if (length == 0U || bytes_.discard(length) != length) {
      return false;
    }
    descriptors_[descriptor_head_] = {};
    descriptor_head_ = increment(descriptor_head_);
    --descriptor_count_;
    ++diagnostics_.frames_released;
    return true;
  }

  // Deliberate whole-frame rejection (disconnect, stale/order mismatch, or
  // synchronized pacer overflow). Unlike pop_front(), this records loss and
  // never lets the caller mistake an abandoned PARAM_VALUE for USB delivery.
  bool discard_front() noexcept {
    if (descriptor_count_ == 0U) {
      return false;
    }
    const std::size_t length = descriptors_[descriptor_head_].length;
    if (length == 0U || bytes_.discard(length) != length) {
      return false;
    }
    descriptors_[descriptor_head_] = {};
    descriptor_head_ = increment(descriptor_head_);
    --descriptor_count_;
    ++diagnostics_.discarded_frames;
    diagnostics_.discarded_bytes += length;
    return true;
  }

  // Disconnect/consistency loss boundary. This records all complete frames
  // intentionally abandoned while retaining prior diagnostics.
  void discard_all() noexcept {
    diagnostics_.discarded_frames += descriptor_count_;
    diagnostics_.discarded_bytes += bytes_.size();
    clear_storage();
  }

  // Reboot/test boundary.
  void reset() noexcept {
    clear_storage();
    bytes_.reset();
    diagnostics_ = {};
  }

  bool empty() const noexcept { return descriptor_count_ == 0U; }
  std::size_t queued_bytes() const noexcept { return bytes_.size(); }
  std::size_t queued_frames() const noexcept { return descriptor_count_; }
  const GroundUsbOrderedBacklogDiagnostics& diagnostics() const noexcept {
    return diagnostics_;
  }

 private:
  struct Descriptor {
    std::uint16_t length{0U};
    bool paced_heartbeat{false};
  };

  static constexpr std::size_t increment(std::size_t index) noexcept {
    return index + 1U == FrameCapacity ? 0U : index + 1U;
  }

  void clear_storage() noexcept {
    bytes_.clear();
    descriptors_ = {};
    descriptor_head_ = 0U;
    descriptor_tail_ = 0U;
    descriptor_count_ = 0U;
  }

  ByteRingBuffer<ByteCapacity> bytes_{};
  std::array<Descriptor, FrameCapacity> descriptors_{};
  std::size_t descriptor_head_{0U};
  std::size_t descriptor_tail_{0U};
  std::size_t descriptor_count_{0U};
  GroundUsbOrderedBacklogDiagnostics diagnostics_{};
};

}  // namespace vc_lora
