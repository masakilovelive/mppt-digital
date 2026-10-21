#include "vc_lora/tdd_link_demux.hpp"

#include <algorithm>

namespace vc_lora {
namespace {

constexpr std::array<std::uint8_t, 4> kControlMagic{{'V', 'C', 'T', 'D'}};
constexpr std::array<std::uint8_t, 4> kTerminalAckMagic{{'V', 'C', 'T', 'A'}};
constexpr std::array<std::uint8_t, 4> kBulkDataMagic{{'V', 'C', 'B', '1'}};
constexpr std::array<std::uint8_t, 4> kBulkNegotiationMagic{
    {'V', 'C', 'B', 'N'}};
constexpr std::array<std::uint8_t, 4> kPeerCompletionReceiptMagic{
    {'V', 'C', 'R', 'C'}};
constexpr std::size_t kV2ReservedPaddingOffset = 20U;
constexpr std::size_t kV2CrcOffset = kTddControlFrameSize - 2U;
constexpr std::uint8_t kLegacyProtocolVersion = 1U;
constexpr std::size_t kLegacyFrameSize = 22U;

static_assert(kV2CrcOffset == 30U,
              "v2 demux resynchronization depends on the fixed CRC offset");

bool has_magic(const std::array<std::uint8_t, kTddControlFrameSize> &candidate,
               const std::array<std::uint8_t, 4U> &magic) noexcept {
  return std::equal(magic.begin(), magic.end(), candidate.begin());
}

bool is_opaque_high_speed_candidate(
    const std::array<std::uint8_t, kTddControlFrameSize> &candidate,
    std::size_t size, bool bulk_data_routing) noexcept {
  return size >= kTerminalAckMagic.size() &&
         (has_magic(candidate, kTerminalAckMagic) ||
          has_magic(candidate, kBulkNegotiationMagic) ||
          has_magic(candidate, kPeerCompletionReceiptMagic) ||
          (bulk_data_routing && has_magic(candidate, kBulkDataMagic)));
}

void emit_candidate(
    const std::array<std::uint8_t, kTddControlFrameSize> &candidate,
    bool bulk_data_routing, TddDemuxEvent &event) noexcept {
  if (has_magic(candidate, kTerminalAckMagic)) {
    event.has_terminal_ack = true;
    event.terminal_ack_fragment = candidate;
    return;
  }
  if (has_magic(candidate, kBulkNegotiationMagic)) {
    event.has_bulk_negotiation = true;
    event.bulk_negotiation_record = candidate;
    return;
  }
  if (has_magic(candidate, kPeerCompletionReceiptMagic)) {
    event.has_peer_completion_receipt = true;
    event.peer_completion_receipt = candidate;
    return;
  }
  if (bulk_data_routing && has_magic(candidate, kBulkDataMagic)) {
    event.has_bulk_data = true;
    event.bulk_data_fragment = candidate;
    return;
  }
  event.has_control = true;
  event.control = decode_control(candidate.data(), candidate.size());
}

} // namespace

TddDemuxEvent TddLinkDemux::push(std::uint8_t byte) noexcept {
  TddDemuxEvent event{};

  // Bytes 20..29 of a valid v2 candidate are deterministic zero padding.  A
  // raw 'V' in that region is therefore the unambiguous start of a newer
  // control candidate (not application data in escaped mode).  Restarting
  // here discards complete legacy 22-byte controls without leaking their tail
  // or consuming the following v2 prefix.  CRC bytes 30..31 are excluded
  // because either byte may legitimately equal 'V'.
  const bool legacy_crc_byte = size_ >= kV2ReservedPaddingOffset &&
                               size_ < kLegacyFrameSize &&
                               buffer_[4] == kLegacyProtocolVersion;
  if (size_ >= kV2ReservedPaddingOffset && size_ < kV2CrcOffset &&
      byte == kControlMagic[0] && !legacy_crc_byte &&
      !is_opaque_high_speed_candidate(buffer_, size_, bulk_data_routing())) {
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
        emit_candidate(buffer_, bulk_data_routing(), event);
        size_ = 0U;
      }
      return event;
    }
    if (byte == kLinkDataEscapeByte) {
      escape_pending_ = true;
    } else if (byte == kLinkDataPaddingByte) {
      // Exact-subpacket padding is transport-only and never reaches MAVLink.
    } else if (byte == kControlMagic[0]) {
      buffer_[size_++] = byte;
    } else {
      event.local_bytes[event.local_size++] = byte;
    }
    return event;
  }

  // Once either full raw magic has been recognized, every remaining byte
  // belongs to that exact 32-byte frame. Payload/CRC bytes are never
  // unescaped. VCTA payload V bytes must not enter the VCTD legacy resync.
  if (size_ >= kControlMagic.size()) {
    buffer_[size_++] = byte;
    if (size_ == kTddControlFrameSize) {
      emit_candidate(buffer_, bulk_data_routing(), event);
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
    if (byte == kControlMagic[0]) {
      buffer_[size_++] = byte;
    } else if (link_data_escaping_ && byte == kLinkDataEscapeByte) {
      escape_pending_ = true;
    } else {
      event.local_bytes[event.local_size++] = byte;
    }
    return event;
  }

  bool matches_magic = false;
  if (size_ < 2U) {
    matches_magic = byte == kControlMagic[size_];
  } else if (size_ == 2U) {
    // VCB is shared by always-reachable VCBN negotiation and mode-gated VCB1
    // data. VCR begins the always-reachable VCRC receipt route. The third byte
    // remains quarantined until byte four resolves the exact record type.
    matches_magic = byte == kControlMagic[2U] ||
                    byte == kBulkNegotiationMagic[2U] ||
                    byte == kPeerCompletionReceiptMagic[2U];
  } else if (size_ == 3U) {
    matches_magic =
        (buffer_[2U] == kControlMagic[2U] &&
         (byte == kControlMagic[3U] || byte == kTerminalAckMagic[3U])) ||
        (buffer_[2U] == kBulkNegotiationMagic[2U] &&
         (byte == kBulkNegotiationMagic[3U] ||
          (bulk_data_routing() && byte == kBulkDataMagic[3U]))) ||
        (buffer_[2U] == kPeerCompletionReceiptMagic[2U] &&
         byte == kPeerCompletionReceiptMagic[3U]);
  }
  if (matches_magic) {
    buffer_[size_++] = byte;
    return event;
  }

  std::copy_n(buffer_.begin(), size_, event.local_bytes.begin());
  event.local_size = size_;
  size_ = 0;
  if (byte == kControlMagic[0]) {
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

} // namespace vc_lora
