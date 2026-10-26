#include "high_speed/r19_usb_clock_sync.hpp"
#include <cstdint>
#include <iostream>

int main() {
  using namespace vc_lora;
  using namespace vc_lora::experimental;
  unsigned checks = 0U, failures = 0U;
  const auto check = [&](bool ok, const char* text) {
    ++checks; if (!ok) { ++failures; std::cerr << text << '\n'; }
  };
  const std::uint64_t nonce = 0x521912345678ABCDULL;
  std::uint8_t payload[16]{};
  for (unsigned i = 0; i < 8U; ++i)
    payload[8U+i] = static_cast<std::uint8_t>(nonce >> (8U*i));
  MavlinkFrame request{}, response{};
  check(encode_mavlink_v2(7U, 249U, 193U, 111U, payload, 16U, request), "encode request");
  std::uint64_t parsed = 0U;
  check(r19_decode_usb_clock_request(request, parsed) && parsed == nonce, "nonce decode");
  check(r19_is_usb_clock_namespace(request), "namespace");
  check(r19_encode_usb_clock_response(8U, nonce, 5335123U, response) &&
        response.size == 28U && response.system_id == 249U &&
        response.component_id == 194U, "response shape");
  std::uint64_t encoded_ns = 0U;
  for (unsigned i = 0; i < 8U; ++i)
    encoded_ns |= static_cast<std::uint64_t>(response.payload()[i]) << (8U*i);
  check(encoded_ns == 5335123000ULL, "TIMESYNC must use nanoseconds");
  check(!r19_decode_usb_clock_request(response, parsed), "response is not a request");
  auto corrupted = request; corrupted.bytes[15] ^= 1U;
  check(!r19_decode_usb_clock_request(corrupted, parsed), "CRC reject");
  check(!r19_encode_usb_clock_response(0U, nonce, UINT64_MAX, response), "timestamp overflow reject");
  check(!r19_encode_usb_clock_response(0U, 0x5219000000000000ULL, 1U, response), "empty nonce reject");
  for (unsigned i = 0U; i < 256U; ++i) {
    MavlinkFrame wrong{};
    check(encode_mavlink_v2(0U, static_cast<std::uint8_t>(i), 193U, 111U,
                           payload, 16U, wrong), "encode source sweep");
    const bool valid = r19_decode_usb_clock_request(wrong, parsed);
    check(valid == (i == 249U), "source sweep isolation");
  }
  std::cout << "UT-R19-USB-CLOCK-SYNC-001 checks=" << checks
            << " failures=" << failures << '\n';
  return failures == 0U ? 0 : 1;
}
