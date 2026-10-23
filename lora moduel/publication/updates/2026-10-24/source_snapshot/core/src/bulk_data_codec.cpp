#include "vc_lora/bulk_data_codec.hpp"

#include <algorithm>
#include <limits>

namespace vc_lora {
namespace {

constexpr std::array<std::uint8_t, 4U> kBulkMagic{{'V', 'C', 'B', '1'}};
constexpr std::uint8_t kPayloadLengthMask = 0x1FU;
constexpr std::uint8_t kKindShift = 5U;
constexpr std::uint8_t kMaximumKind = 3U;

void put_u16(BulkDataFragment& bytes, std::size_t offset,
             std::uint16_t value) noexcept {
  bytes[offset] = static_cast<std::uint8_t>(value & 0xFFU);
  bytes[offset + 1U] = static_cast<std::uint8_t>(value >> 8U);
}

void put_u32(BulkDataFragment& bytes, std::size_t offset,
             std::uint32_t value) noexcept {
  for (std::size_t index = 0U; index < 4U; ++index) {
    bytes[offset + index] = static_cast<std::uint8_t>(
        (value >> static_cast<unsigned int>(index * 8U)) & 0xFFU);
  }
}

std::uint16_t get_u16(const BulkDataFragment& bytes,
                      std::size_t offset) noexcept {
  return static_cast<std::uint16_t>(bytes[offset]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(bytes[offset + 1U]) << 8U);
}

std::uint32_t get_u32(const BulkDataFragment& bytes,
                      std::size_t offset) noexcept {
  std::uint32_t value = 0U;
  for (std::size_t index = 0U; index < 4U; ++index) {
    value |= static_cast<std::uint32_t>(bytes[offset + index])
             << static_cast<unsigned int>(index * 8U);
  }
  return value;
}

bool has_bulk_magic(const BulkDataFragment& fragment) noexcept {
  return std::equal(kBulkMagic.begin(), kBulkMagic.end(), fragment.begin());
}

bool is_head(BulkDataFragmentKind kind) noexcept {
  return kind == BulkDataFragmentKind::ParameterHead ||
         kind == BulkDataFragmentKind::HeartbeatHead;
}

bool is_parameter(BulkDataFragmentKind kind) noexcept {
  return kind == BulkDataFragmentKind::ParameterHead ||
         kind == BulkDataFragmentKind::ParameterTail;
}

BulkDataFragmentKind matching_tail(BulkDataFragmentKind head) noexcept {
  return head == BulkDataFragmentKind::ParameterHead
             ? BulkDataFragmentKind::ParameterTail
             : BulkDataFragmentKind::HeartbeatTail;
}

std::uint16_t payload_u16(const MavlinkFrame& frame,
                          std::size_t offset) noexcept {
  return static_cast<std::uint16_t>(frame.payload_byte_or_zero(offset)) |
         static_cast<std::uint16_t>(static_cast<std::uint16_t>(
                                        frame.payload_byte_or_zero(offset + 1U))
                                    << 8U);
}

}  // namespace

std::uint16_t BulkDataWireCodec::crc16_ccitt_false(
    const std::uint8_t* bytes, std::size_t size) noexcept {
  if (bytes == nullptr && size != 0U) {
    return 0U;
  }
  std::uint16_t crc = 0xFFFFU;
  for (std::size_t index = 0U; index < size; ++index) {
    crc ^= static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(bytes[index]) << 8U);
    for (std::uint8_t bit = 0U; bit < 8U; ++bit) {
      crc = (crc & 0x8000U) != 0U
                ? static_cast<std::uint16_t>(
                      (static_cast<std::uint32_t>(crc) << 1U) ^ 0x1021U)
                : static_cast<std::uint16_t>(
                      static_cast<std::uint32_t>(crc) << 1U);
    }
  }
  return crc;
}

BulkDataWireStatus BulkDataWireCodec::encode_fragment(
    BulkDataFragmentKind kind, std::uint32_t transfer_tag,
    std::uint16_t wire_ordinal, const std::uint8_t* payload,
    std::size_t payload_size, BulkDataFragment& output) noexcept {
  const std::size_t required = required_payload_size(kind);
  if (required == 0U || payload == nullptr) {
    return BulkDataWireStatus::InvalidArgument;
  }
  if (payload_size != required) {
    return BulkDataWireStatus::InvalidDescriptor;
  }
  if (transfer_tag == 0U) {
    return BulkDataWireStatus::InvalidTransferTag;
  }

  BulkDataFragment candidate{};
  std::copy(kBulkMagic.begin(), kBulkMagic.end(), candidate.begin());
  const auto kind_value = static_cast<std::uint8_t>(kind);
  candidate[4] = static_cast<std::uint8_t>(
      static_cast<std::uint8_t>(kind_value << kKindShift) |
      static_cast<std::uint8_t>(payload_size));
  put_u32(candidate, 5U, transfer_tag);
  put_u16(candidate, 9U, wire_ordinal);
  std::copy_n(payload, payload_size,
              candidate.begin() + static_cast<std::ptrdiff_t>(payload_offset));
  put_u16(candidate, integrity_offset,
          crc16_ccitt_false(candidate.data(), integrity_offset));
  output = candidate;
  return BulkDataWireStatus::FragmentReady;
}

BulkDataWireStatus BulkDataWireCodec::decode_fragment(
    const BulkDataFragment& fragment,
    BulkDataDecodedFragment& output) noexcept {
  output = {};
  if (!has_bulk_magic(fragment)) {
    return BulkDataWireStatus::UnknownMagic;
  }
  if (get_u16(fragment, integrity_offset) !=
      crc16_ccitt_false(fragment.data(), integrity_offset)) {
    return BulkDataWireStatus::BadCrc;
  }

  const std::uint8_t descriptor = fragment[4];
  const std::uint8_t kind_value =
      static_cast<std::uint8_t>(descriptor >> kKindShift);
  const std::size_t payload_size = descriptor & kPayloadLengthMask;
  if (kind_value > kMaximumKind) {
    return BulkDataWireStatus::InvalidDescriptor;
  }
  const auto kind = static_cast<BulkDataFragmentKind>(kind_value);
  if (payload_size != required_payload_size(kind)) {
    return BulkDataWireStatus::InvalidDescriptor;
  }
  const std::uint32_t transfer_tag = get_u32(fragment, 5U);
  if (transfer_tag == 0U) {
    return BulkDataWireStatus::InvalidTransferTag;
  }
  for (std::size_t index = payload_offset + payload_size;
       index < integrity_offset; ++index) {
    if (fragment[index] != 0U) {
      return BulkDataWireStatus::NonCanonicalPadding;
    }
  }

  BulkDataDecodedFragment candidate{};
  candidate.kind = kind;
  candidate.transfer_tag = transfer_tag;
  candidate.wire_ordinal = get_u16(fragment, 9U);
  candidate.payload_size = payload_size;
  std::copy_n(fragment.begin() + static_cast<std::ptrdiff_t>(payload_offset),
              payload_size, candidate.payload.begin());
  output = candidate;
  return BulkDataWireStatus::FragmentReady;
}

BulkDataWireStatus encode_bulk_data_frame(
    const MavlinkFrame& frame, std::uint32_t transfer_tag,
    std::uint16_t first_wire_ordinal,
    EncodedBulkDataFrame& output) noexcept {
  if (transfer_tag == 0U) {
    return BulkDataWireStatus::InvalidTransferTag;
  }
  if (first_wire_ordinal == std::numeric_limits<std::uint16_t>::max()) {
    return BulkDataWireStatus::OrdinalOverflow;
  }

  MavlinkFrame validated{};
  if (validate_mavlink_frame(frame.bytes.data(), frame.size, validated) !=
      MavlinkParseStatus::FrameReady) {
    return BulkDataWireStatus::InvalidMavlink;
  }

  BulkDataFragmentKind head_kind{};
  BulkDataFragmentKind tail_kind{};
  std::size_t required_size = 0U;
  if (validated.message_id == 22U) {
    head_kind = BulkDataFragmentKind::ParameterHead;
    tail_kind = BulkDataFragmentKind::ParameterTail;
    required_size = 37U;
  } else if (validated.message_id == 0U) {
    head_kind = BulkDataFragmentKind::HeartbeatHead;
    tail_kind = BulkDataFragmentKind::HeartbeatTail;
    required_size = 21U;
  } else {
    return BulkDataWireStatus::UnsupportedFrame;
  }
  if (validated.version != MavlinkVersion::V2 || validated.signed_frame ||
      validated.size != required_size) {
    return BulkDataWireStatus::UnsupportedFrame;
  }

  EncodedBulkDataFrame candidate{};
  const BulkDataWireStatus head = BulkDataWireCodec::encode_fragment(
      head_kind, transfer_tag, first_wire_ordinal, validated.bytes.data(),
      BulkDataWireCodec::payload_bytes, candidate.fragments[0]);
  if (head != BulkDataWireStatus::FragmentReady) {
    return head;
  }
  const std::size_t tail_size =
      validated.size - BulkDataWireCodec::payload_bytes;
  const BulkDataWireStatus tail = BulkDataWireCodec::encode_fragment(
      tail_kind, transfer_tag,
      static_cast<std::uint16_t>(first_wire_ordinal + 1U),
      validated.bytes.data() + BulkDataWireCodec::payload_bytes, tail_size,
      candidate.fragments[1]);
  if (tail != BulkDataWireStatus::FragmentReady) {
    return tail;
  }
  candidate.fragment_count = 2U;
  output = candidate;
  return BulkDataWireStatus::FrameReady;
}

BulkDataStreamDecoder::BulkDataStreamDecoder(
    std::uint32_t expected_transfer_tag,
    std::uint16_t expected_parameter_count) noexcept
    : expected_transfer_tag_(expected_transfer_tag),
      expected_parameter_count_(expected_parameter_count),
      last_error_(expected_transfer_tag == 0U ||
                          expected_parameter_count == 0U
                      ? BulkDataStreamStatus::InvalidConfiguration
                      : BulkDataStreamStatus::NeedMore),
      latched_(expected_transfer_tag == 0U ||
               expected_parameter_count == 0U) {}

BulkDataStreamStatus BulkDataStreamDecoder::push_byte(
    std::uint8_t byte, MavlinkFrame& output) noexcept {
  // A caller can publish output only for FrameReady. Clearing it on every
  // byte also prevents a previously completed frame from remaining visible
  // while a new HEAD, partial fragment, or failure is being processed.
  output = {};
  if (sealed_) {
    return BulkDataStreamStatus::SessionSealed;
  }
  if (latched_) {
    return BulkDataStreamStatus::Latched;
  }
  if (complete_) {
    return latch(BulkDataStreamStatus::PostCompleteData);
  }
  if (fragment_buffer_size_ >= fragment_buffer_.size()) {
    return latch(BulkDataStreamStatus::CounterOverflow);
  }
  fragment_buffer_[fragment_buffer_size_++] = byte;
  if (fragment_buffer_size_ < fragment_buffer_.size()) {
    return BulkDataStreamStatus::NeedMore;
  }

  const BulkDataFragment fragment = fragment_buffer_;
  fragment_buffer_ = {};
  fragment_buffer_size_ = 0U;
  return accept_fragment(fragment, output);
}

bool BulkDataStreamDecoder::finish() noexcept {
  if (sealed_ || latched_ || complete_) {
    return false;
  }
  if (fragment_buffer_size_ != 0U || frame_active_) {
    static_cast<void>(latch(BulkDataStreamStatus::TrailingPartial));
    return false;
  }
  if (parameter_count_ != expected_parameter_count_) {
    static_cast<void>(latch(BulkDataStreamStatus::IncompleteParameterSet));
    return false;
  }
  complete_ = true;
  return true;
}

BulkDataStreamLifecycleStatus BulkDataStreamDecoder::seal_session() noexcept {
  sealed_ = true;
  return BulkDataStreamLifecycleStatus::Sealed;
}

BulkDataStreamLifecycleStatus BulkDataStreamDecoder::rearm(
    std::uint32_t new_transfer_tag) noexcept {
  if (!sealed_) {
    return BulkDataStreamLifecycleStatus::SessionNotSealed;
  }
  if (new_transfer_tag == 0U || expected_parameter_count_ == 0U) {
    return BulkDataStreamLifecycleStatus::InvalidConfiguration;
  }
  if (new_transfer_tag == expected_transfer_tag_) {
    return BulkDataStreamLifecycleStatus::TransferTagReuse;
  }

  expected_transfer_tag_ = new_transfer_tag;
  fragment_buffer_ = {};
  fragment_buffer_size_ = 0U;
  clear_active_frame();
  next_wire_ordinal_ = 0U;
  parameter_count_ = 0U;
  heartbeat_count_ = 0U;
  parameter_fragment_count_ = 0U;
  total_fragment_count_ = 0U;
  raw_parameter_bytes_ = 0U;
  last_error_ = BulkDataStreamStatus::NeedMore;
  latched_ = false;
  complete_ = false;
  sealed_ = false;
  return BulkDataStreamLifecycleStatus::Rearmed;
}

BulkDataStreamStatus BulkDataStreamDecoder::accept_fragment(
    const BulkDataFragment& fragment, MavlinkFrame& output) noexcept {
  BulkDataDecodedFragment decoded{};
  const BulkDataWireStatus wire_status =
      BulkDataWireCodec::decode_fragment(fragment, decoded);
  if (wire_status != BulkDataWireStatus::FragmentReady) {
    return latch(BulkDataStreamStatus::InvalidFragment);
  }
  if (decoded.transfer_tag != expected_transfer_tag_) {
    return latch(BulkDataStreamStatus::WrongTransferTag);
  }
  if (next_wire_ordinal_ >
          static_cast<std::uint32_t>(
              std::numeric_limits<std::uint16_t>::max()) ||
      decoded.wire_ordinal != next_wire_ordinal_) {
    return latch(BulkDataStreamStatus::WrongWireOrdinal);
  }
  if (total_fragment_count_ ==
      std::numeric_limits<std::uint32_t>::max()) {
    return latch(BulkDataStreamStatus::CounterOverflow);
  }

  if (!frame_active_) {
    if (!is_head(decoded.kind)) {
      return latch(BulkDataStreamStatus::FrameInterleaving);
    }
    frame_buffer_ = {};
    std::copy_n(decoded.payload.begin(), decoded.payload_size,
                frame_buffer_.begin());
    frame_size_ = decoded.payload_size;
    active_head_kind_ = decoded.kind;
    frame_active_ = true;
    ++total_fragment_count_;
    if (is_parameter(decoded.kind)) {
      ++parameter_fragment_count_;
    }
    ++next_wire_ordinal_;
    return BulkDataStreamStatus::FragmentAccepted;
  }

  if (decoded.kind != matching_tail(active_head_kind_)) {
    return latch(BulkDataStreamStatus::FrameInterleaving);
  }
  if (decoded.payload_size > frame_buffer_.size() - frame_size_) {
    return latch(BulkDataStreamStatus::CounterOverflow);
  }
  std::copy_n(decoded.payload.begin(), decoded.payload_size,
              frame_buffer_.begin() + static_cast<std::ptrdiff_t>(frame_size_));
  frame_size_ += decoded.payload_size;
  ++total_fragment_count_;
  if (is_parameter(decoded.kind)) {
    ++parameter_fragment_count_;
  }
  ++next_wire_ordinal_;

  MavlinkFrame validated{};
  if (validate_mavlink_frame(frame_buffer_.data(), frame_size_, validated) !=
      MavlinkParseStatus::FrameReady) {
    return latch(BulkDataStreamStatus::BadMavlink);
  }

  if (active_head_kind_ == BulkDataFragmentKind::ParameterHead) {
    if (validated.message_id != 22U ||
        validated.version != MavlinkVersion::V2 || validated.signed_frame ||
        validated.size != 37U || validated.payload_length != 25U ||
        payload_u16(validated, 4U) != expected_parameter_count_ ||
        payload_u16(validated, 6U) != parameter_count_ ||
        parameter_count_ >= expected_parameter_count_) {
      return latch(BulkDataStreamStatus::ParameterEvidenceMismatch);
    }
    if (raw_parameter_bytes_ >
        std::numeric_limits<std::uint32_t>::max() - validated.size) {
      return latch(BulkDataStreamStatus::CounterOverflow);
    }
    raw_parameter_bytes_ += static_cast<std::uint32_t>(validated.size);
    ++parameter_count_;
  } else {
    if (validated.message_id != 0U ||
        validated.version != MavlinkVersion::V2 || validated.signed_frame ||
        validated.size != 21U || validated.payload_length != 9U ||
        heartbeat_count_ == std::numeric_limits<std::uint32_t>::max()) {
      return latch(BulkDataStreamStatus::BadMavlink);
    }
    ++heartbeat_count_;
  }

  output = validated;
  clear_active_frame();
  return BulkDataStreamStatus::FrameReady;
}

BulkDataStreamStatus BulkDataStreamDecoder::latch(
    BulkDataStreamStatus error) noexcept {
  last_error_ = error;
  latched_ = true;
  complete_ = false;
  return error;
}

void BulkDataStreamDecoder::clear_active_frame() noexcept {
  frame_buffer_ = {};
  frame_size_ = 0U;
  active_head_kind_ = BulkDataFragmentKind::ParameterHead;
  frame_active_ = false;
}

}  // namespace vc_lora
