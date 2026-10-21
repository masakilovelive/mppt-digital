#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/tdd_control_codec.hpp"

namespace vc_lora {

constexpr std::size_t kTddDemuxMaxLocalBytes = 4;

struct TddDemuxEvent {
  std::array<std::uint8_t, kTddDemuxMaxLocalBytes> local_bytes{};
  std::size_t local_size{0};
  bool has_control{false};
  DecodeEvent control{};
};

// Separates fixed VCTD control frames from a transparent byte stream without
// relying on UART read or RF packet boundaries. A VCTD candidate is consumed
// even when its CRC/version/type is invalid so it cannot reach MAVLink UARTs.
class TddLinkDemux {
 public:
  explicit TddLinkDemux(bool link_data_escaping = false) noexcept
      : link_data_escaping_(link_data_escaping) {}

  TddDemuxEvent push(std::uint8_t byte) noexcept;
  void reset() noexcept;
  void set_link_data_escaping(bool enabled) noexcept {
    reset();
    link_data_escaping_ = enabled;
  }
  bool link_data_escaping() const noexcept { return link_data_escaping_; }
  std::size_t buffered_size() const noexcept {
    return size_ + (escape_pending_ ? 1U : 0U);
  }

 private:
  std::array<std::uint8_t, kTddControlFrameSize> buffer_{};
  std::size_t size_{0};
  bool escape_pending_{false};
  bool link_data_escaping_{false};
};

}  // namespace vc_lora
