#include "vc_lora/link_data_codec.hpp"

#include <algorithm>

namespace vc_lora {
namespace {

bool requires_escape(std::uint8_t byte) noexcept {
  return byte == kLinkDataEscapeByte ||
         byte == kLinkDataControlLeadByte ||
         byte == kLinkDataPaddingByte;
}

}  // namespace

EncodedLinkDataChunk encode_link_data(const std::uint8_t* input,
                                      std::size_t input_size,
                                      std::size_t max_wire_bytes) noexcept {
  EncodedLinkDataChunk encoded{};
  if (input == nullptr || input_size == 0U || max_wire_bytes == 0U) {
    return encoded;
  }

  const std::size_t wire_limit =
      std::min(max_wire_bytes, encoded.wire_bytes.size());
  while (encoded.input_consumed < input_size) {
    const std::uint8_t byte = input[encoded.input_consumed];
    const std::size_t required = requires_escape(byte) ? 2U : 1U;
    if (required > wire_limit - encoded.wire_size) {
      break;
    }
    if (required == 2U) {
      encoded.wire_bytes[encoded.wire_size++] = kLinkDataEscapeByte;
      encoded.wire_bytes[encoded.wire_size++] =
          static_cast<std::uint8_t>(byte ^ kLinkDataEscapeXor);
    } else {
      encoded.wire_bytes[encoded.wire_size++] = byte;
    }
    ++encoded.input_consumed;
  }
  if (encoded.input_consumed > 0U) {
    std::fill(encoded.wire_bytes.begin() + encoded.wire_size,
              encoded.wire_bytes.begin() + wire_limit,
              kLinkDataPaddingByte);
    encoded.wire_size = wire_limit;
  }
  return encoded;
}

}  // namespace vc_lora
