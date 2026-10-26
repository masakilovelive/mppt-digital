#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace vc_lora {

constexpr std::uint8_t kLinkDataEscapeByte = 0x7DU;
constexpr std::uint8_t kLinkDataEscapeXor = 0x20U;
constexpr std::uint8_t kLinkDataControlLeadByte = 0x56U;  // 'V'
// Raw 0x7E bytes fill the unused suffix of every physical data write.  Real
// application 0x7E bytes are escaped, so an escaped-mode demux can discard
// padding without changing the MAVLink byte stream.
constexpr std::uint8_t kLinkDataPaddingByte = 0x7EU;
constexpr std::size_t kLinkDataMaxWireBytes = 32U;

struct EncodedLinkDataChunk {
  std::array<std::uint8_t, kLinkDataMaxWireBytes> wire_bytes{};
  std::size_t input_consumed{0};
  std::size_t wire_size{0};
};

// Encodes the largest complete input prefix that fits max_wire_bytes. Data
// bytes which could start a raw VCTD control frame, the escape byte, and the
// reserved padding byte are escaped. An escape pair is never split. Every
// non-empty result is padded to max_wire_bytes so E220 never holds a short
// uplink/downlink subpacket waiting for its internal partial-packet timeout.
EncodedLinkDataChunk encode_link_data(
    const std::uint8_t* input, std::size_t input_size,
    std::size_t max_wire_bytes = kLinkDataMaxWireBytes) noexcept;

}  // namespace vc_lora
