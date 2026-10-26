#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "vc_lora/mavlink_frame.hpp"

namespace vc_lora::test::fixtures {

inline void put_u16(std::uint8_t* output, std::uint16_t value) noexcept {
  output[0] = static_cast<std::uint8_t>(value & 0xFFU);
  output[1] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
}

inline void put_u32(std::uint8_t* output, std::uint32_t value) noexcept {
  output[0] = static_cast<std::uint8_t>(value & 0xFFU);
  output[1] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
  output[2] = static_cast<std::uint8_t>((value >> 16U) & 0xFFU);
  output[3] = static_cast<std::uint8_t>((value >> 24U) & 0xFFU);
}

inline void put_float(std::uint8_t* output, float value) noexcept {
  std::uint32_t bits = 0U;
  static_assert(sizeof(bits) == sizeof(value), "32-bit float required");
  std::memcpy(&bits, &value, sizeof(bits));
  put_u32(output, bits);
}

inline void put_id(std::uint8_t* output, const char* id) noexcept {
  std::memset(output, 0, 16U);
  if (id != nullptr) {
    std::strncpy(reinterpret_cast<char*>(output), id, 16U);
  }
}

inline MavlinkFrame heartbeat_v2(std::uint8_t sequence,
                                 std::uint8_t system_id = 1U,
                                 std::uint8_t component_id = 1U,
                                 std::uint8_t type = 2U,
                                 std::uint8_t autopilot = 3U) noexcept {
  std::array<std::uint8_t, 9> payload{};
  payload[4] = type;
  payload[5] = autopilot;
  payload[6] = 0U;
  payload[7] = 4U;
  payload[8] = 3U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, system_id, component_id, 0U,
                          payload.data(), payload.size(), frame);
  return frame;
}

inline MavlinkFrame heartbeat_v1(std::uint8_t sequence) noexcept {
  std::array<std::uint8_t, 9> payload{};
  payload[4] = 6U;
  payload[5] = 8U;
  payload[7] = 4U;
  payload[8] = 3U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v1(sequence, 255U, 190U, 0U, payload.data(),
                          payload.size(), frame);
  return frame;
}

inline MavlinkFrame param_request_read_v2(std::uint8_t sequence,
                                          const char* id,
                                          std::int16_t index = -1) noexcept {
  std::array<std::uint8_t, 20> payload{};
  put_u16(payload.data(), static_cast<std::uint16_t>(index));
  payload[2] = 1U;
  payload[3] = 1U;
  put_id(payload.data() + 4U, id);
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 20U, payload.data(),
                          payload.size(), frame);
  return frame;
}

inline MavlinkFrame param_value_v2(std::uint8_t sequence, const char* id,
                                   float value, std::uint16_t index,
                                   std::uint16_t count = 512U,
                                   std::uint8_t parameter_type = 9U) noexcept {
  std::array<std::uint8_t, 25> payload{};
  put_float(payload.data(), value);
  put_u16(payload.data() + 4U, count);
  put_u16(payload.data() + 6U, index);
  put_id(payload.data() + 8U, id);
  payload[24] = parameter_type;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 1U, 1U, 22U, payload.data(),
                          payload.size(), frame);
  return frame;
}

inline MavlinkFrame param_set_v1(std::uint8_t sequence, const char* id,
                                 float value) noexcept {
  std::array<std::uint8_t, 23> payload{};
  put_float(payload.data(), value);
  payload[4] = 1U;
  payload[5] = 1U;
  put_id(payload.data() + 6U, id);
  payload[22] = 9U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v1(sequence, 255U, 190U, 23U, payload.data(),
                          payload.size(), frame);
  return frame;
}

inline MavlinkFrame param_set_v2(std::uint8_t sequence, const char* id,
                                 float value) noexcept {
  std::array<std::uint8_t, 23> payload{};
  put_float(payload.data(), value);
  payload[4] = 1U;
  payload[5] = 1U;
  put_id(payload.data() + 6U, id);
  payload[22] = 9U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 23U, payload.data(),
                          payload.size(), frame);
  return frame;
}

inline MavlinkFrame command_long_v2(std::uint8_t sequence,
                                    std::uint16_t command = 400U,
                                    float marker = 1.0F) noexcept {
  std::array<std::uint8_t, 33> payload{};
  put_float(payload.data(), marker);
  put_float(payload.data() + 4U, marker + 0.25F);
  put_u16(payload.data() + 28U, command);
  payload[30] = 1U;
  payload[31] = 1U;
  payload[32] = sequence;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 76U, payload.data(),
                          payload.size(), frame);
  return frame;
}

inline MavlinkFrame command_ack_v2(std::uint8_t sequence,
                                   std::uint16_t command = 400U,
                                   std::int32_t marker = 0) noexcept {
  std::array<std::uint8_t, 10> payload{};
  put_u16(payload.data(), command);
  payload[2] = 0U;
  payload[3] = 100U;
  put_u32(payload.data() + 4U, static_cast<std::uint32_t>(marker));
  payload[8] = 255U;
  payload[9] = 190U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 1U, 1U, 77U, payload.data(),
                          payload.size(), frame);
  return frame;
}

inline MavlinkFrame pid_tuning_v2(std::uint8_t sequence,
                                  float desired) noexcept {
  std::array<std::uint8_t, 25> payload{};
  put_float(payload.data(), desired);
  put_float(payload.data() + 4U, desired - 0.1F);
  payload[24] = 0U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 1U, 1U, 194U, payload.data(),
                          payload.size(), frame);
  return frame;
}

inline MavlinkFrame adversarial_vctd_param_set() noexcept {
  constexpr std::array<std::uint8_t, 35> raw{{
      0xFD, 0x17, 0x00, 0x00, 0x39, 0xFF, 0xBE, 0x17, 0x00,
      0x00, 0x00, 0x00, 0x80, 0x3F, 0x01, 0x01, 0x56, 0x43,
      0x54, 0x44, 0x5F, 0x43, 0x4F, 0x4C, 0x4C, 0x49, 0x53,
      0x49, 0x4F, 0x4E, 0x00, 0x00, 0x09, 0x95, 0x58}};
  MavlinkFrame frame{};
  (void)validate_mavlink_frame(raw.data(), raw.size(), frame);
  return frame;
}

inline std::array<std::uint8_t, 595> mission_planner_burst() noexcept {
  std::array<std::uint8_t, 595> output{};
  std::size_t offset = 0U;
  for (std::uint8_t index = 0U; index < 17U; ++index) {
    char id[17]{};
    (void)std::snprintf(id, sizeof(id), "TEST_PARAM_%02u",
                        static_cast<unsigned>(index));
    const MavlinkFrame frame =
        param_set_v2(static_cast<std::uint8_t>(40U + index), id,
                     static_cast<float>(index));
    if (frame.size == 35U && offset + frame.size <= output.size()) {
      std::memcpy(output.data() + offset, frame.bytes.data(), frame.size);
      offset += frame.size;
    }
  }
  return output;
}

}  // namespace vc_lora::test::fixtures
