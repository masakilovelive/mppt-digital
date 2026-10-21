#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/mavlink_frame.hpp"

namespace vc_lora {

// High-speed data is carried in exact 32-byte records. This codec is inert
// until a future negotiated bulk-mode consumer explicitly selects it; the
// standard VCTD/TDD data path does not call it.
//
// Wire v1:
//   0..3   ASCII "VCB1"
//   4      kind in bits 7..5, payload length in bits 4..0
//   5..8   non-zero transfer tag, little-endian
//   9..10  transfer-global fragment ordinal, little-endian
//   11..29 payload (unused suffix must be zero)
//   30..31 CRC-16/CCITT-FALSE over bytes 0..29, little-endian
//
// A PARAM_VALUE is exactly 19+18 bytes and a HEARTBEAT is exactly 19+2
// bytes. The transfer-global ordinal includes both kinds so a lost heartbeat
// fragment cannot be hidden by a later parameter fragment. The independent
// parameter-fragment counter remains 0..1863 for terminal accounting.
using BulkDataFragment = std::array<std::uint8_t, 32U>;

enum class BulkDataFragmentKind : std::uint8_t {
  ParameterHead = 0U,
  ParameterTail = 1U,
  HeartbeatHead = 2U,
  HeartbeatTail = 3U,
};

enum class BulkDataWireStatus : std::uint8_t {
  FragmentReady = 0U,
  FrameReady,
  InvalidArgument,
  UnknownMagic,
  InvalidDescriptor,
  InvalidTransferTag,
  OrdinalOverflow,
  BadCrc,
  NonCanonicalPadding,
  InvalidMavlink,
  UnsupportedFrame,
};

struct BulkDataDecodedFragment final {
  BulkDataFragmentKind kind{BulkDataFragmentKind::ParameterHead};
  std::uint32_t transfer_tag{0U};
  std::uint16_t wire_ordinal{0U};
  std::array<std::uint8_t, 19U> payload{};
  std::size_t payload_size{0U};
};

class BulkDataWireCodec final {
 public:
  static constexpr std::size_t fragment_bytes = 32U;
  static constexpr std::size_t payload_offset = 11U;
  static constexpr std::size_t payload_bytes = 19U;
  static constexpr std::size_t integrity_offset = 30U;

  [[nodiscard]] static std::uint16_t crc16_ccitt_false(
      const std::uint8_t* bytes, std::size_t size) noexcept;

  [[nodiscard]] static BulkDataWireStatus encode_fragment(
      BulkDataFragmentKind kind, std::uint32_t transfer_tag,
      std::uint16_t wire_ordinal, const std::uint8_t* payload,
      std::size_t payload_size, BulkDataFragment& output) noexcept;

  [[nodiscard]] static BulkDataWireStatus decode_fragment(
      const BulkDataFragment& fragment,
      BulkDataDecodedFragment& output) noexcept;

  [[nodiscard]] static constexpr std::size_t required_payload_size(
      BulkDataFragmentKind kind) noexcept {
    switch (kind) {
      case BulkDataFragmentKind::ParameterHead:
      case BulkDataFragmentKind::HeartbeatHead:
        return 19U;
      case BulkDataFragmentKind::ParameterTail:
        return 18U;
      case BulkDataFragmentKind::HeartbeatTail:
        return 2U;
    }
    return 0U;
  }
};

struct EncodedBulkDataFrame final {
  std::array<BulkDataFragment, 2U> fragments{};
  std::size_t fragment_count{0U};
};

// Validates and envelopes only the exact product-path frames used during a
// bulk transfer: unsigned MAVLink2 PARAM_VALUE (37 bytes) and HEARTBEAT
// (21 bytes). Output is unchanged unless both fragments are valid.
[[nodiscard]] BulkDataWireStatus encode_bulk_data_frame(
    const MavlinkFrame& frame, std::uint32_t transfer_tag,
    std::uint16_t first_wire_ordinal,
    EncodedBulkDataFrame& output) noexcept;

enum class BulkDataStreamStatus : std::uint8_t {
  NeedMore = 0U,
  FragmentAccepted,
  FrameReady,
  InvalidConfiguration,
  InvalidFragment,
  WrongTransferTag,
  WrongWireOrdinal,
  FrameInterleaving,
  BadMavlink,
  ParameterEvidenceMismatch,
  CounterOverflow,
  TrailingPartial,
  IncompleteParameterSet,
  PostCompleteData,
  Latched,
  SessionSealed,
};

// Lifecycle operations are kept separate from wire/parser results so an
// owner cannot mistake a successful session transition for received data.
enum class BulkDataStreamLifecycleStatus : std::uint8_t {
  Sealed = 0U,
  Rearmed,
  SessionNotSealed,
  TransferTagReuse,
  InvalidConfiguration,
};

// Receiver-side fixed-storage decoder. No application byte is emitted for a
// HEAD fragment. A complete CRC-valid MAVLink frame is returned only after its
// matching TAIL passes tag, ordinal, padding, envelope CRC, MAVLink CRC, and
// PARAM_VALUE order/count checks. Any error permanently latches this instance.
class BulkDataStreamDecoder final {
 public:
  explicit BulkDataStreamDecoder(
      std::uint32_t expected_transfer_tag,
      std::uint16_t expected_parameter_count = 932U) noexcept;
  BulkDataStreamDecoder(const BulkDataStreamDecoder&) = delete;
  BulkDataStreamDecoder& operator=(const BulkDataStreamDecoder&) = delete;
  BulkDataStreamDecoder(BulkDataStreamDecoder&&) = delete;
  BulkDataStreamDecoder& operator=(BulkDataStreamDecoder&&) = delete;
  ~BulkDataStreamDecoder() = default;

  [[nodiscard]] BulkDataStreamStatus push_byte(
      std::uint8_t byte, MavlinkFrame& output) noexcept;
  [[nodiscard]] bool finish() noexcept;

  // A fixed-storage/global owner may be reused only across an explicit
  // session boundary. A successful finish() remains an unconsumed completion
  // for lifecycle purposes until seal_session() acknowledges that boundary.
  // seal_session() also permits an explicit abort of a partial or faulted
  // session without erasing its counters/failure evidence. rearm() then
  // accepts only a fresh non-zero tag and atomically clears every
  // session-local field.
  [[nodiscard]] BulkDataStreamLifecycleStatus seal_session() noexcept;
  [[nodiscard]] BulkDataStreamLifecycleStatus rearm(
      std::uint32_t new_transfer_tag) noexcept;

  [[nodiscard]] constexpr bool latched() const noexcept { return latched_; }
  [[nodiscard]] constexpr bool complete() const noexcept { return complete_; }
  [[nodiscard]] constexpr bool sealed() const noexcept { return sealed_; }
  [[nodiscard]] constexpr std::uint32_t expected_transfer_tag() const noexcept {
    return expected_transfer_tag_;
  }
  [[nodiscard]] constexpr std::uint16_t
  expected_parameter_count() const noexcept {
    return expected_parameter_count_;
  }
  [[nodiscard]] constexpr BulkDataStreamStatus last_error() const noexcept {
    return last_error_;
  }
  [[nodiscard]] constexpr std::uint32_t parameter_count() const noexcept {
    return parameter_count_;
  }
  [[nodiscard]] constexpr std::uint32_t heartbeat_count() const noexcept {
    return heartbeat_count_;
  }
  [[nodiscard]] constexpr std::uint32_t
  parameter_fragment_count() const noexcept {
    return parameter_fragment_count_;
  }
  [[nodiscard]] constexpr std::uint32_t
  total_fragment_count() const noexcept {
    return total_fragment_count_;
  }
  [[nodiscard]] constexpr std::uint32_t raw_parameter_bytes() const noexcept {
    return raw_parameter_bytes_;
  }
  [[nodiscard]] constexpr std::uint32_t
  next_wire_ordinal() const noexcept {
    return next_wire_ordinal_;
  }

 private:
  [[nodiscard]] BulkDataStreamStatus accept_fragment(
      const BulkDataFragment& fragment, MavlinkFrame& output) noexcept;
  [[nodiscard]] BulkDataStreamStatus latch(
      BulkDataStreamStatus error) noexcept;
  void clear_active_frame() noexcept;

  std::uint32_t expected_transfer_tag_{0U};
  std::uint16_t expected_parameter_count_{0U};
  std::array<std::uint8_t, 32U> fragment_buffer_{};
  std::size_t fragment_buffer_size_{0U};
  std::array<std::uint8_t, 37U> frame_buffer_{};
  std::size_t frame_size_{0U};
  BulkDataFragmentKind active_head_kind_{
      BulkDataFragmentKind::ParameterHead};
  bool frame_active_{false};
  std::uint32_t next_wire_ordinal_{0U};
  std::uint32_t parameter_count_{0U};
  std::uint32_t heartbeat_count_{0U};
  std::uint32_t parameter_fragment_count_{0U};
  std::uint32_t total_fragment_count_{0U};
  std::uint32_t raw_parameter_bytes_{0U};
  BulkDataStreamStatus last_error_{BulkDataStreamStatus::NeedMore};
  bool latched_{false};
  bool complete_{false};
  bool sealed_{false};
};

}  // namespace vc_lora
