#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace vc_lora {

constexpr std::uint8_t kMavlinkV1Magic = 0xFEU;
constexpr std::uint8_t kMavlinkV2Magic = 0xFDU;
constexpr std::size_t kMavlinkMaxPayloadBytes = 255U;
constexpr std::size_t kMavlinkSignatureBytes = 13U;
constexpr std::size_t kMavlinkMaxFrameBytes = 280U;

enum class MavlinkVersion : std::uint8_t {
  V1 = 1U,
  V2 = 2U,
};

enum class MavlinkParseStatus : std::uint8_t {
  NeedMore,
  FrameReady,
  Noise,
  BadLength,
  BadCrc,
  UnsupportedMessage,
  UnsupportedFlags,
};

struct MavlinkParserDiagnostics {
  std::uint64_t bytes_seen{0};
  std::uint64_t frames_accepted{0};
  std::uint64_t noise_bytes{0};
  std::uint64_t bad_lengths{0};
  std::uint64_t crc_errors{0};
  std::uint64_t unsupported_messages{0};
  std::uint64_t unsupported_flags{0};
  std::uint64_t explicit_resets{0};
};

struct MavlinkMessageDefinition {
  std::uint32_t message_id{0};
  std::uint8_t crc_extra{0};
  std::uint8_t minimum_payload_length{0};
  std::uint8_t maximum_payload_length{0};
};

struct MavlinkFrame {
  std::array<std::uint8_t, kMavlinkMaxFrameBytes> bytes{};
  std::size_t size{0};
  std::uint32_t message_id{0};
  std::uint8_t sequence{0};
  std::uint8_t system_id{0};
  std::uint8_t component_id{0};
  std::uint8_t payload_length{0};
  MavlinkVersion version{MavlinkVersion::V2};
  bool signed_frame{false};

  const std::uint8_t* payload() const noexcept {
    return bytes.data() + (version == MavlinkVersion::V1 ? 6U : 10U);
  }
  std::uint8_t* payload() noexcept {
    return bytes.data() + (version == MavlinkVersion::V1 ? 6U : 10U);
  }

  // MAVLink 2 may omit trailing zero payload bytes on the wire. Preserve the
  // wire length and raw bytes while exposing omitted bytes as logical zeros.
  std::uint8_t payload_byte_or_zero(std::size_t index) const noexcept {
    return index < static_cast<std::size_t>(payload_length) ? payload()[index]
                                                            : 0U;
  }
};

bool mavlink_crc_extra(std::uint32_t message_id,
                       std::uint8_t& extra) noexcept;
bool mavlink_message_definition(
    std::uint32_t message_id,
    MavlinkMessageDefinition& definition) noexcept;
std::uint16_t mavlink_x25_crc(const std::uint8_t* data,
                              std::size_t size) noexcept;
std::uint16_t mavlink_x25_accumulate(std::uint16_t crc,
                                     std::uint8_t byte) noexcept;

MavlinkParseStatus validate_mavlink_frame(const std::uint8_t* data,
                                          std::size_t size,
                                          MavlinkFrame& frame) noexcept;

bool encode_mavlink_v1(std::uint8_t sequence, std::uint8_t system_id,
                       std::uint8_t component_id, std::uint32_t message_id,
                       const std::uint8_t* payload, std::size_t payload_size,
                       MavlinkFrame& frame) noexcept;

bool encode_mavlink_v2(
    std::uint8_t sequence, std::uint8_t system_id,
    std::uint8_t component_id, std::uint32_t message_id,
    const std::uint8_t* payload, std::size_t payload_size,
    MavlinkFrame& frame, std::uint8_t incompatibility_flags = 0U,
    std::uint8_t compatibility_flags = 0U,
    const std::uint8_t* signature = nullptr) noexcept;

class MavlinkStreamParser {
 public:
  MavlinkParseStatus push(std::uint8_t byte, MavlinkFrame& frame) noexcept;
  void reset() noexcept;

  std::size_t buffered_size() const noexcept { return buffered_size_; }
  const MavlinkParserDiagnostics& diagnostics() const noexcept {
    return diagnostics_;
  }

 private:
  void clear_buffer() noexcept;

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> buffer_{};
  std::size_t buffered_size_{0};
  std::size_t expected_size_{0};
  MavlinkVersion version_{MavlinkVersion::V2};
  MavlinkParserDiagnostics diagnostics_{};
};

}  // namespace vc_lora
