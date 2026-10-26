#pragma once

#include <cstdint>
#include <limits>
#include <vc_lora/mavlink_frame.hpp>

namespace vc_lora::experimental {

// Reserved for the explicitly non-deployable USB cause diagnostic. Nothing
// from this namespace is forwarded to the radio/Pixhawk. Production builds
// never instantiate the diagnostic handler.
inline constexpr std::uint8_t r19_clock_system_id = 249U;
inline constexpr std::uint8_t r19_clock_request_component = 193U;
inline constexpr std::uint8_t r19_clock_response_component = 194U;

inline bool r19_is_usb_clock_namespace(const MavlinkFrame& frame) noexcept {
  return frame.system_id == r19_clock_system_id &&
         frame.component_id == r19_clock_request_component &&
         frame.message_id == 111U;
}

inline bool r19_valid_clock_nonce(std::uint64_t nonce) noexcept {
  return (nonce >> 48U) == 0x5219U &&
         (nonce & 0x0000FFFFFFFFFFFFULL) != 0U;
}

inline bool r19_decode_usb_clock_request(const MavlinkFrame& frame,
                                          std::uint64_t& nonce) noexcept {
  if (!r19_is_usb_clock_namespace(frame) ||
      frame.version != MavlinkVersion::V2 || frame.signed_frame ||
      frame.bytes[2U] != 0U || frame.bytes[3U] != 0U ||
      frame.payload_length != 16U || frame.size != 28U) return false;
  MavlinkFrame validated{};
  if (validate_mavlink_frame(frame.bytes.data(), frame.size, validated) !=
          MavlinkParseStatus::FrameReady ||
      !r19_is_usb_clock_namespace(validated)) return false;
  std::uint64_t tc1 = 0U, ts1 = 0U;
  for (unsigned i = 0U; i < 8U; ++i) {
    tc1 |= static_cast<std::uint64_t>(validated.payload()[i]) << (8U*i);
    ts1 |= static_cast<std::uint64_t>(validated.payload()[8U+i]) << (8U*i);
  }
  if (tc1 != 0U || !r19_valid_clock_nonce(ts1)) return false;
  nonce = ts1;
  return true;
}

inline bool r19_encode_usb_clock_response(std::uint8_t sequence,
                                           std::uint64_t nonce,
                                           std::uint64_t device_us,
                                           MavlinkFrame& frame) noexcept {
  if (!r19_valid_clock_nonce(nonce) || device_us == 0U ||
      device_us > static_cast<std::uint64_t>(
          std::numeric_limits<std::int64_t>::max()) / 1000U) return false;
  const std::uint64_t ns = device_us * 1000U;
  std::uint8_t payload[16]{};
  for (unsigned i = 0U; i < 8U; ++i) {
    payload[i] = static_cast<std::uint8_t>(ns >> (8U*i));
    payload[8U+i] = static_cast<std::uint8_t>(nonce >> (8U*i));
  }
  return encode_mavlink_v2(sequence, r19_clock_system_id,
      r19_clock_response_component, 111U, payload, 16U, frame);
}

}  // namespace vc_lora::experimental
