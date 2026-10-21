#include "vc_lora/tdd_control_codec.hpp"

#include <algorithm>

namespace vc_lora {
namespace {

constexpr std::array<std::uint8_t, 4> kMagic{{'V', 'C', 'T', 'D'}};
constexpr std::uint8_t kPayloadLength = 12;
constexpr std::size_t kFieldBytes = 20U;
constexpr std::size_t kReservedPaddingOffset = kFieldBytes;
constexpr std::size_t kReservedPaddingBytes = 10U;
constexpr std::size_t kCrcOffset =
    kReservedPaddingOffset + kReservedPaddingBytes;
constexpr std::size_t kCrcCoveredBytes = kCrcOffset;
constexpr std::uint8_t kLegacyProtocolVersion = 1U;
constexpr std::size_t kLegacyFrameSize = 22U;

static_assert(kCrcOffset + sizeof(std::uint16_t) ==
                  kTddControlFrameSize,
              "control layout must fill the exact physical frame");

void put_u16(std::uint8_t* output, std::size_t offset,
             std::uint16_t value) noexcept {
  output[offset] = static_cast<std::uint8_t>(value & 0xFFU);
  output[offset + 1] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
}

std::uint16_t get_u16(const std::uint8_t* input,
                      std::size_t offset) noexcept {
  return static_cast<std::uint16_t>(input[offset]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(input[offset + 1]) << 8U);
}

bool has_magic(const std::uint8_t* frame) noexcept {
  return std::equal(kMagic.begin(), kMagic.end(), frame);
}

}  // namespace

std::uint16_t crc16_ccitt_false(const std::uint8_t* data,
                                std::size_t size) noexcept {
  std::uint16_t crc = 0xFFFFU;
  for (std::size_t index = 0; index < size; ++index) {
    crc ^= static_cast<std::uint16_t>(data[index]) << 8U;
    for (std::uint8_t bit = 0; bit < 8U; ++bit) {
      const auto shifted = static_cast<std::uint16_t>(crc << 1U);
      crc = (crc & 0x8000U) != 0U
                ? static_cast<std::uint16_t>(
                      shifted ^ static_cast<std::uint16_t>(0x1021U))
                : shifted;
    }
  }
  return crc;
}

bool encode_control(const TddControlMessage& message, std::uint8_t* output,
                    std::size_t capacity,
                    std::size_t& encoded_size) noexcept {
  encoded_size = 0;
  if (output == nullptr || capacity < kTddControlFrameSize ||
      message.version != kTddProtocolVersion ||
      !valid_control_type(message.type)) {
    return false;
  }

  std::copy(kMagic.begin(), kMagic.end(), output);
  output[4] = message.version;
  output[5] = static_cast<std::uint8_t>(message.type);
  output[6] = kPayloadLength;
  output[7] = 0;
  put_u16(output, 8, message.session_id);
  put_u16(output, 10, message.cycle_id);
  put_u16(output, 12, message.guard_ms);
  put_u16(output, 14, message.window_ms);
  put_u16(output, 16, message.max_bytes);
  put_u16(output, 18, message.actual_bytes);
  std::fill_n(output + kReservedPaddingOffset,
              kReservedPaddingBytes, 0U);
  put_u16(output, kCrcOffset,
          crc16_ccitt_false(output, kCrcCoveredBytes));
  encoded_size = kTddControlFrameSize;
  return true;
}

DecodeEvent decode_control(const std::uint8_t* frame,
                           std::size_t size) noexcept {
  DecodeEvent event{};
  if (frame == nullptr || size != kTddControlFrameSize ||
      !has_magic(frame) || frame[6] != kPayloadLength || frame[7] != 0U) {
    event.status = DecodeStatus::Malformed;
    return event;
  }
  if (get_u16(frame, kCrcOffset) !=
      crc16_ccitt_false(frame, kCrcCoveredBytes)) {
    event.status = DecodeStatus::BadCrc;
    return event;
  }
  if (!std::all_of(frame + kReservedPaddingOffset,
                   frame + kCrcOffset,
                   [](std::uint8_t byte) { return byte == 0U; })) {
    event.status = DecodeStatus::Malformed;
    return event;
  }
  if (frame[4] != kTddProtocolVersion) {
    event.status = DecodeStatus::UnknownVersion;
    return event;
  }
  const auto type = static_cast<ControlType>(frame[5]);
  if (!valid_control_type(type)) {
    event.status = DecodeStatus::UnknownType;
    return event;
  }

  event.status = DecodeStatus::Message;
  event.message.version = frame[4];
  event.message.type = type;
  event.message.session_id = get_u16(frame, 8);
  event.message.cycle_id = get_u16(frame, 10);
  event.message.guard_ms = get_u16(frame, 12);
  event.message.window_ms = get_u16(frame, 14);
  event.message.max_bytes = get_u16(frame, 16);
  event.message.actual_bytes = get_u16(frame, 18);
  return event;
}

DecodeEvent TddControlStreamDecoder::push(std::uint8_t byte) noexcept {
  if (size_ == 0U) {
    if (byte == kMagic[0]) {
      buffer_[size_++] = byte;
    }
    return {};
  }

  // A valid v2 frame contains only zeroes at offsets 20..29.  A raw control
  // lead byte received while the candidate is in that region therefore
  // cannot belong to the current frame.  Restarting here lets a v2-only
  // decoder recover immediately from one or more complete legacy 22-byte
  // candidates without consuming the prefix of the first valid v2 frame.
  // Offsets 30..31 are CRC and may legitimately contain 'V'.
  const bool legacy_crc_byte =
      size_ >= kReservedPaddingOffset && size_ < kLegacyFrameSize &&
      buffer_[4] == kLegacyProtocolVersion;
  if (size_ >= kReservedPaddingOffset && size_ < kCrcOffset &&
      byte == kMagic[0] && !legacy_crc_byte) {
    size_ = 0U;
    buffer_[size_++] = byte;
    return {};
  }

  if (size_ < kMagic.size() && byte != kMagic[size_]) {
    size_ = 0;
    if (byte == kMagic[0]) {
      buffer_[size_++] = byte;
    }
    return {};
  }

  buffer_[size_++] = byte;
  if (size_ < kTddControlFrameSize) {
    return {};
  }

  const DecodeEvent event = decode_control(buffer_.data(), buffer_.size());
  size_ = 0;
  return event;
}

void TddControlStreamDecoder::reset() noexcept { size_ = 0; }

}  // namespace vc_lora
