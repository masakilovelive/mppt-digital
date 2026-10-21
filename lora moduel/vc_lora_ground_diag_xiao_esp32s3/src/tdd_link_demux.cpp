#include "vc_lora/tdd_link_demux.hpp"

#include <algorithm>

namespace vc_lora {
namespace {

constexpr std::array<std::uint8_t, 4> kMagic{{'V', 'C', 'T', 'D'}};
constexpr std::size_t kV2ReservedPaddingOffset = 20U;
constexpr std::size_t kV2CrcOffset = kTddControlFrameSize - 2U;
constexpr std::uint8_t kLegacyProtocolVersion = 1U;
constexpr std::size_t kLegacyFrameSize = 22U;

static_assert(kV2CrcOffset == 30U,
              "v2 demux resynchronization depends on the fixed CRC offset");

}  // namespace

TddDemuxEvent TddLinkDemux::push(std::uint8_t byte) noexcept {
  TddDemuxEvent event{};

  // Bytes 20..29 of a valid v2 candidate are deterministic zero padding.  A
  // raw 'V' in that region is therefore the unambiguous start of a newer
  // control candidate (not application data in escaped mode).  Restarting
  // here discards complete legacy 22-byte controls without leaking their tail
  // or consuming the following v2 prefix.  CRC bytes 30..31 are excluded
  // because either byte may legitimately equal 'V'.
  const bool legacy_crc_byte =
      size_ >= kV2ReservedPaddingOffset && size_ < kLegacyFrameSize &&
      buffer_[4] == kLegacyProtocolVersion;
  if (size_ >= kV2ReservedPaddingOffset && size_ < kV2CrcOffset &&
      byte == kMagic[0] && !legacy_crc_byte) {
    size_ = 0U;
    buffer_[size_++] = byte;
    return event;
  }

  // In escaped-data mode every application 'V' is protected on wire. A raw
  // 'V' therefore unambiguously starts a control-sized quarantine region,
  // even when corruption changes C/T/D or the CRC. Never flush such a
  // candidate into MAVLink data.
  if (link_data_escaping_) {
    if (escape_pending_) {
      event.local_bytes[event.local_size++] =
          static_cast<std::uint8_t>(byte ^ kLinkDataEscapeXor);
      escape_pending_ = false;
      return event;
    }
    if (size_ > 0U) {
      buffer_[size_++] = byte;
      if (size_ == kTddControlFrameSize) {
        event.has_control = true;
        event.control = decode_control(buffer_.data(), buffer_.size());
        size_ = 0U;
      }
      return event;
    }
    if (byte == kLinkDataEscapeByte) {
      escape_pending_ = true;
    } else if (byte == kLinkDataPaddingByte) {
      // Exact-subpacket padding is transport-only and never reaches MAVLink.
    } else if (byte == kMagic[0]) {
      buffer_[size_++] = byte;
    } else {
      event.local_bytes[event.local_size++] = byte;
    }
    return event;
  }

  // Once the raw VCTD magic has been recognized, every remaining byte belongs
  // to that control frame. Control payload/CRC bytes are never unescaped.
  if (size_ >= kMagic.size()) {
    buffer_[size_++] = byte;
    if (size_ == kTddControlFrameSize) {
      event.has_control = true;
      event.control = decode_control(buffer_.data(), buffer_.size());
      size_ = 0;
    }
    return event;
  }

  // An escaped byte is application data even when it decodes to 'V'. Bypass
  // the control scanner so application data can contain an entire VCTD frame.
  if (link_data_escaping_ && escape_pending_) {
    event.local_bytes[event.local_size++] =
        static_cast<std::uint8_t>(byte ^ kLinkDataEscapeXor);
    escape_pending_ = false;
    return event;
  }

  if (size_ == 0U) {
    if (byte == kMagic[0]) {
      buffer_[size_++] = byte;
    } else if (link_data_escaping_ && byte == kLinkDataEscapeByte) {
      escape_pending_ = true;
    } else {
      event.local_bytes[event.local_size++] = byte;
    }
    return event;
  }

  if (byte == kMagic[size_]) {
    buffer_[size_++] = byte;
    return event;
  }

  std::copy_n(buffer_.begin(), size_, event.local_bytes.begin());
  event.local_size = size_;
  size_ = 0;
  if (byte == kMagic[0]) {
    buffer_[size_++] = byte;
  } else if (link_data_escaping_ && byte == kLinkDataEscapeByte) {
    escape_pending_ = true;
  } else {
    event.local_bytes[event.local_size++] = byte;
  }
  return event;
}

void TddLinkDemux::reset() noexcept {
  size_ = 0;
  escape_pending_ = false;
}

}  // namespace vc_lora
