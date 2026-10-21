#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/tdd_types.hpp"

namespace vc_lora {

// One complete control frame is exactly one physical E220 write.  Bytes
// 0..19 retain the v1 field layout, bytes 20..29 are reserved zero padding,
// and bytes 30..31 carry the CRC over bytes 0..29.
constexpr std::size_t kTddControlFrameSize = 32U;

enum class DecodeStatus : std::uint8_t {
  NeedMore,
  Message,
  BadCrc,
  UnknownVersion,
  UnknownType,
  Malformed,
};

struct DecodeEvent {
  DecodeStatus status{DecodeStatus::NeedMore};
  TddControlMessage message{};
};

std::uint16_t crc16_ccitt_false(const std::uint8_t* data,
                                std::size_t size) noexcept;

bool encode_control(const TddControlMessage& message, std::uint8_t* output,
                    std::size_t capacity,
                    std::size_t& encoded_size) noexcept;

DecodeEvent decode_control(const std::uint8_t* frame,
                           std::size_t size) noexcept;

class TddControlStreamDecoder {
 public:
  DecodeEvent push(std::uint8_t byte) noexcept;
  void reset() noexcept;
  std::size_t buffered_size() const noexcept { return size_; }

 private:
  std::array<std::uint8_t, kTddControlFrameSize> buffer_{};
  std::size_t size_{0};
};

}  // namespace vc_lora
