#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/tdd_control_codec.hpp"

namespace vc_lora {

constexpr std::size_t kTddDemuxMaxLocalBytes = 4;

enum class BulkDataRouteMode : std::uint8_t {
  Disabled = 0U,
  Enabled,
};

struct TddDemuxEvent {
  std::array<std::uint8_t, kTddDemuxMaxLocalBytes> local_bytes{};
  std::size_t local_size{0};
  bool has_control{false};
  DecodeEvent control{};
  // VCTA is an exact 32-byte, control-like high-speed terminal fragment.
  // This layer only performs full-magic routing and byte-exact quarantine;
  // TerminalAckReassembler owns fragment CRC and semantic validation.
  bool has_terminal_ack{false};
  std::array<std::uint8_t, kTddControlFrameSize> terminal_ack_fragment{};
  // VCB1 is routed only after an explicit high-speed-mode selection. The
  // demux preserves the exact record and leaves CRC/tag/ordinal validation to
  // BulkDataStreamDecoder.
  bool has_bulk_data{false};
  std::array<std::uint8_t, kTddControlFrameSize> bulk_data_fragment{};
  // VCBN activation records are reachable before and during bulk mode. The
  // demux only quarantines and routes the exact record; negotiation semantic
  // and integrity checks belong to BulkNegotiationWireCodec.
  bool has_bulk_negotiation{false};
  std::array<std::uint8_t, kTddControlFrameSize> bulk_negotiation_record{};
  // VCRC peer-consumption receipts are priority control records reachable in
  // both standard and negotiated bulk modes. The demux quarantines and
  // preserves all 32 bytes; the receipt owner validates CRC and semantics.
  bool has_peer_completion_receipt{false};
  std::array<std::uint8_t, kTddControlFrameSize> peer_completion_receipt{};
};

// Separates fixed VCTD control frames, exact VCTA terminal fragments, always
// reachable exact VCBN negotiation records, and—only when explicitly
// enabled—exact VCB1 bulk records from a transparent byte stream without
// relying on UART read or RF packet boundaries. A raw-V candidate is consumed
// even when its CRC/version/type is invalid in escaped mode so it cannot reach
// MAVLink UARTs. High-speed record validation is intentionally deferred to
// each owning decoder.
// Exact VCRC peer receipts are an additional always-reachable route in both
// standard and negotiated bulk modes.
class TddLinkDemux {
public:
  explicit TddLinkDemux(bool link_data_escaping = false,
                        BulkDataRouteMode bulk_data_route_mode =
                            BulkDataRouteMode::Disabled) noexcept
      : link_data_escaping_(link_data_escaping),
        bulk_data_route_mode_(bulk_data_route_mode) {}

  TddDemuxEvent push(std::uint8_t byte) noexcept;
  void reset() noexcept;
  void set_link_data_escaping(bool enabled) noexcept {
    reset();
    link_data_escaping_ = enabled;
  }
  bool link_data_escaping() const noexcept { return link_data_escaping_; }
  bool set_bulk_data_route_mode(BulkDataRouteMode mode) noexcept {
    if (mode == bulk_data_route_mode_) {
      return true;
    }
    if (buffered_size() != 0U) {
      return false;
    }
    bulk_data_route_mode_ = mode;
    return true;
  }
  BulkDataRouteMode bulk_data_route_mode() const noexcept {
    return bulk_data_route_mode_;
  }
  bool bulk_data_routing() const noexcept {
    return bulk_data_route_mode_ == BulkDataRouteMode::Enabled;
  }
  std::size_t buffered_size() const noexcept {
    return size_ + (escape_pending_ ? 1U : 0U);
  }

private:
  std::array<std::uint8_t, kTddControlFrameSize> buffer_{};
  std::size_t size_{0};
  bool escape_pending_{false};
  bool link_data_escaping_{false};
  BulkDataRouteMode bulk_data_route_mode_{BulkDataRouteMode::Disabled};
};

} // namespace vc_lora
