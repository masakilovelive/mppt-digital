#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

namespace vc_lora {

struct ByteRingBufferStats {
  std::uint64_t bytes_written{0};
  std::uint64_t bytes_read{0};
  std::uint64_t bytes_dropped{0};
  std::uint64_t overflow_events{0};
  std::size_t high_watermark{0};
};

// Fixed-capacity FIFO for embedded/host use. When full, the newest incoming
// bytes are rejected so bytes already queued retain their original order.
template <std::size_t Capacity>
class ByteRingBuffer {
  static_assert(Capacity > 0U, "ByteRingBuffer capacity must be non-zero");

 public:
  constexpr std::size_t capacity() const noexcept { return Capacity; }
  std::size_t size() const noexcept { return size_; }
  std::size_t free_space() const noexcept { return Capacity - size_; }
  bool empty() const noexcept { return size_ == 0U; }
  bool full() const noexcept { return size_ == Capacity; }
  const ByteRingBufferStats& stats() const noexcept { return stats_; }

  bool push(std::uint8_t byte) noexcept { return write(&byte, 1U) == 1U; }

  std::size_t write(const std::uint8_t* data, std::size_t count) noexcept {
    if (data == nullptr || count == 0U) {
      return 0U;
    }
    const std::size_t accepted = std::min(count, free_space());
    for (std::size_t index = 0; index < accepted; ++index) {
      storage_[tail_] = data[index];
      tail_ = increment(tail_);
    }
    size_ += accepted;
    stats_.bytes_written += accepted;
    stats_.high_watermark = std::max(stats_.high_watermark, size_);
    if (accepted < count) {
      ++stats_.overflow_events;
      stats_.bytes_dropped += count - accepted;
    }
    return accepted;
  }

  bool pop(std::uint8_t& output) noexcept {
    return read(&output, 1U) == 1U;
  }

  std::size_t read(std::uint8_t* output, std::size_t count) noexcept {
    if (output == nullptr || count == 0U) {
      return 0U;
    }
    const std::size_t available = std::min(count, size_);
    for (std::size_t index = 0; index < available; ++index) {
      output[index] = storage_[head_];
      head_ = increment(head_);
    }
    size_ -= available;
    stats_.bytes_read += available;
    return available;
  }

  bool peek(std::size_t offset, std::uint8_t& output) const noexcept {
    if (offset >= size_) {
      return false;
    }
    output = storage_[(head_ + offset) % Capacity];
    return true;
  }

  std::size_t copy_front(std::uint8_t* output,
                         std::size_t count) const noexcept {
    if (output == nullptr || count == 0U) {
      return 0U;
    }
    const std::size_t available = std::min(count, size_);
    for (std::size_t index = 0; index < available; ++index) {
      output[index] = storage_[(head_ + index) % Capacity];
    }
    return available;
  }

  std::size_t discard(std::size_t count) noexcept {
    const std::size_t discarded = std::min(count, size_);
    head_ = (head_ + discarded) % Capacity;
    size_ -= discarded;
    stats_.bytes_read += discarded;
    return discarded;
  }

  void clear() noexcept {
    head_ = 0U;
    tail_ = 0U;
    size_ = 0U;
  }

  void reset() noexcept {
    clear();
    stats_ = {};
  }

 private:
  static constexpr std::size_t increment(std::size_t index) noexcept {
    return index + 1U == Capacity ? 0U : index + 1U;
  }

  std::array<std::uint8_t, Capacity> storage_{};
  std::size_t head_{0};
  std::size_t tail_{0};
  std::size_t size_{0};
  ByteRingBufferStats stats_{};
};

}  // namespace vc_lora
