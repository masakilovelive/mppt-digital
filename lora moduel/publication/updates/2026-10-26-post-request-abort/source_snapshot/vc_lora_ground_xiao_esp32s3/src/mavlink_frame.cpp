#include "vc_lora/mavlink_frame.hpp"

#include <algorithm>

namespace vc_lora {
namespace {

constexpr std::size_t kV1HeaderWithoutMagicBytes = 5U;
constexpr std::size_t kV2HeaderWithoutMagicBytes = 9U;
constexpr std::size_t kV1PacketOverheadBytes = 8U;
constexpr std::size_t kV2PacketOverheadBytes = 12U;

// Explicit ardupilotmega allow-list. Most entries were extracted from Mission
// Planner 1.3.83's locally installed MAVLink.dll (SHA-256 recorded in the
// fixture manifest). PARAM_ERROR was independently verified against a real
// Pixhawk frame and the newer common.xml definition. Unknown IDs remain
// fail-closed because their CRC_EXTRA cannot be verified.
constexpr std::array<MavlinkMessageDefinition, 80U> kMessageDefinitions{{
    {0U, 50U, 9U, 9U},        // HEARTBEAT
    {1U, 124U, 31U, 31U},     // SYS_STATUS
    {2U, 137U, 12U, 12U},     // SYSTEM_TIME
    {4U, 237U, 14U, 14U},     // PING
    {11U, 89U, 6U, 6U},       // SET_MODE
    {20U, 214U, 20U, 20U},    // PARAM_REQUEST_READ
    {21U, 159U, 2U, 2U},      // PARAM_REQUEST_LIST
    {22U, 220U, 25U, 25U},    // PARAM_VALUE
    {23U, 168U, 23U, 23U},    // PARAM_SET
    {24U, 24U, 30U, 52U},     // GPS_RAW_INT
    {27U, 144U, 26U, 29U},    // RAW_IMU
    {29U, 115U, 14U, 16U},    // SCALED_PRESSURE
    {30U, 39U, 28U, 28U},     // ATTITUDE
    {33U, 104U, 28U, 28U},    // GLOBAL_POSITION_INT
    {35U, 244U, 22U, 22U},    // RC_CHANNELS_RAW
    {36U, 222U, 21U, 37U},    // SERVO_OUTPUT_RAW
    {37U, 212U, 6U, 7U},      // MISSION_REQUEST_PARTIAL_LIST
    {38U, 9U, 6U, 7U},        // MISSION_WRITE_PARTIAL_LIST
    {39U, 254U, 37U, 38U},    // MISSION_ITEM
    {40U, 230U, 4U, 5U},      // MISSION_REQUEST
    {41U, 28U, 4U, 4U},       // MISSION_SET_CURRENT
    {42U, 28U, 2U, 6U},       // MISSION_CURRENT
    {43U, 132U, 2U, 3U},      // MISSION_REQUEST_LIST
    {44U, 221U, 4U, 5U},      // MISSION_COUNT
    {45U, 232U, 2U, 3U},      // MISSION_CLEAR_ALL
    {46U, 11U, 2U, 2U},       // MISSION_ITEM_REACHED
    {47U, 153U, 3U, 4U},      // MISSION_ACK
    {51U, 196U, 4U, 5U},      // MISSION_REQUEST_INT
    {53U, 3U, 5U, 5U},        // MISSION_CHECKSUM
    {62U, 183U, 26U, 26U},    // NAV_CONTROLLER_OUTPUT
    {65U, 118U, 42U, 42U},    // RC_CHANNELS
    {66U, 148U, 6U, 6U},      // REQUEST_DATA_STREAM
    {69U, 243U, 11U, 30U},    // MANUAL_CONTROL
    {70U, 124U, 18U, 38U},    // RC_CHANNELS_OVERRIDE
    {73U, 38U, 37U, 38U},     // MISSION_ITEM_INT
    {74U, 20U, 20U, 20U},     // VFR_HUD
    {75U, 158U, 35U, 35U},    // COMMAND_INT
    {76U, 152U, 33U, 33U},    // COMMAND_LONG
    {77U, 143U, 3U, 10U},     // COMMAND_ACK
    {84U, 143U, 53U, 53U},    // SET_POSITION_TARGET_LOCAL_NED
    {86U, 5U, 53U, 53U},      // SET_POSITION_TARGET_GLOBAL_INT
    {109U, 185U, 9U, 9U},     // RADIO_STATUS
    {110U, 84U, 254U, 254U},  // FILE_TRANSFER_PROTOCOL
    {111U, 34U, 16U, 16U},    // TIMESYNC
    {116U, 76U, 22U, 24U},    // SCALED_IMU2
    {117U, 128U, 6U, 6U},     // LOG_REQUEST_LIST
    {118U, 56U, 14U, 14U},    // LOG_ENTRY
    {119U, 116U, 12U, 12U},   // LOG_REQUEST_DATA
    {120U, 134U, 97U, 97U},   // LOG_DATA
    {121U, 237U, 2U, 2U},     // LOG_ERASE
    {122U, 203U, 2U, 2U},     // LOG_REQUEST_END
    {124U, 87U, 35U, 57U},    // GPS2_RAW
    {125U, 203U, 6U, 6U},     // POWER_STATUS
    {147U, 154U, 36U, 54U},   // BATTERY_STATUS
    {148U, 178U, 60U, 78U},   // AUTOPILOT_VERSION
    {150U, 134U, 42U, 42U},   // SENSOR_OFFSETS
    {152U, 208U, 4U, 8U},     // MEMINFO
    {162U, 189U, 8U, 9U},     // FENCE_STATUS
    {163U, 127U, 28U, 28U},   // AHRS
    {165U, 21U, 3U, 3U},      // HWSTATUS
    {166U, 21U, 9U, 9U},      // RADIO
    {168U, 1U, 12U, 12U},     // WIND
    {178U, 47U, 24U, 24U},    // AHRS2
    {182U, 229U, 40U, 40U},   // AHRS3
    {183U, 85U, 2U, 2U},      // AUTOPILOT_VERSION_REQUEST
    {191U, 92U, 27U, 27U},    // MAG_CAL_PROGRESS
    {192U, 36U, 44U, 54U},    // MAG_CAL_REPORT
    {193U, 71U, 22U, 26U},    // EKF_STATUS_REPORT
    {194U, 98U, 25U, 33U},    // PID_TUNING
    {230U, 163U, 42U, 42U},   // ESTIMATOR_STATUS
    {241U, 90U, 32U, 32U},    // VIBRATION
    {242U, 104U, 52U, 60U},   // HOME_POSITION
    {245U, 130U, 2U, 2U},     // EXTENDED_SYS_STATE
    {253U, 83U, 51U, 54U},    // STATUSTEXT
    {320U, 243U, 20U, 20U},   // PARAM_EXT_REQUEST_READ
    {321U, 88U, 2U, 2U},      // PARAM_EXT_REQUEST_LIST
    {322U, 243U, 149U, 149U}, // PARAM_EXT_VALUE
    {323U, 78U, 147U, 147U},  // PARAM_EXT_SET
    {324U, 132U, 146U, 146U}, // PARAM_EXT_ACK
    {345U, 209U, 21U, 21U},   // PARAM_ERROR
}};

void store_checksum(std::uint16_t checksum, std::uint8_t* output) noexcept {
  output[0] = static_cast<std::uint8_t>(checksum & 0xFFU);
  output[1] = static_cast<std::uint8_t>((checksum >> 8U) & 0xFFU);
}

std::uint16_t load_checksum(const std::uint8_t* input) noexcept {
  return static_cast<std::uint16_t>(input[0]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(input[1]) << 8U);
}

std::uint16_t packet_checksum(const std::uint8_t* bytes,
                              std::size_t crc_input_size,
                              std::uint8_t extra) noexcept {
  std::uint16_t crc = mavlink_x25_crc(bytes + 1U, crc_input_size);
  return mavlink_x25_accumulate(crc, extra);
}

void populate_metadata(MavlinkFrame& frame) noexcept {
  frame.payload_length = frame.bytes[1];
  if (frame.bytes[0] == kMavlinkV1Magic) {
    frame.version = MavlinkVersion::V1;
    frame.signed_frame = false;
    frame.sequence = frame.bytes[2];
    frame.system_id = frame.bytes[3];
    frame.component_id = frame.bytes[4];
    frame.message_id = frame.bytes[5];
    return;
  }
  frame.version = MavlinkVersion::V2;
  frame.signed_frame = (frame.bytes[2] & 0x01U) != 0U;
  frame.sequence = frame.bytes[4];
  frame.system_id = frame.bytes[5];
  frame.component_id = frame.bytes[6];
  frame.message_id = static_cast<std::uint32_t>(frame.bytes[7]) |
                     (static_cast<std::uint32_t>(frame.bytes[8]) << 8U) |
                     (static_cast<std::uint32_t>(frame.bytes[9]) << 16U);
}

}  // namespace

bool mavlink_message_definition(
    std::uint32_t message_id,
    MavlinkMessageDefinition& definition) noexcept {
  definition = {};
  definition.message_id = message_id;
  for (const MavlinkMessageDefinition& candidate : kMessageDefinitions) {
    if (candidate.message_id == message_id) {
      definition = candidate;
      return true;
    }
    if (candidate.message_id > message_id) {
      break;
    }
  }
  return false;
}

bool mavlink_crc_extra(std::uint32_t message_id,
                       std::uint8_t& extra) noexcept {
  MavlinkMessageDefinition definition{};
  if (!mavlink_message_definition(message_id, definition)) {
    extra = 0U;
    return false;
  }
  extra = definition.crc_extra;
  return true;
}

std::uint16_t mavlink_x25_accumulate(std::uint16_t crc,
                                     std::uint8_t byte) noexcept {
  std::uint8_t mixed =
      static_cast<std::uint8_t>(byte ^ static_cast<std::uint8_t>(crc));
  mixed = static_cast<std::uint8_t>(mixed ^
                                    static_cast<std::uint8_t>(mixed << 4U));
  return static_cast<std::uint16_t>(
      (crc >> 8U) ^ (static_cast<std::uint16_t>(mixed) << 8U) ^
      (static_cast<std::uint16_t>(mixed) << 3U) ^
      (static_cast<std::uint16_t>(mixed) >> 4U));
}

std::uint16_t mavlink_x25_crc(const std::uint8_t* data,
                              std::size_t size) noexcept {
  std::uint16_t crc = 0xFFFFU;
  if (data == nullptr) {
    return crc;
  }
  for (std::size_t index = 0; index < size; ++index) {
    crc = mavlink_x25_accumulate(crc, data[index]);
  }
  return crc;
}

MavlinkParseStatus validate_mavlink_frame(const std::uint8_t* data,
                                          std::size_t size,
                                          MavlinkFrame& frame) noexcept {
  if (data == nullptr || size < kV1PacketOverheadBytes) {
    return MavlinkParseStatus::BadLength;
  }

  const std::uint8_t magic = data[0];
  const std::size_t payload_size = data[1];
  std::size_t expected_size = 0U;
  std::size_t crc_input_size = 0U;
  std::size_t checksum_offset = 0U;
  std::uint32_t message_id = 0U;

  if (magic == kMavlinkV1Magic) {
    expected_size = payload_size + kV1PacketOverheadBytes;
    crc_input_size = payload_size + kV1HeaderWithoutMagicBytes;
    checksum_offset = payload_size + 6U;
    message_id = data[5];
  } else if (magic == kMavlinkV2Magic) {
    if (size < kV2PacketOverheadBytes) {
      return MavlinkParseStatus::BadLength;
    }
    const std::uint8_t incompatibility_flags = data[2];
    if ((incompatibility_flags & static_cast<std::uint8_t>(~0x01U)) != 0U) {
      return MavlinkParseStatus::UnsupportedFlags;
    }
    const std::size_t signature_size =
        (incompatibility_flags & 0x01U) != 0U ? kMavlinkSignatureBytes : 0U;
    expected_size = payload_size + kV2PacketOverheadBytes + signature_size;
    crc_input_size = payload_size + kV2HeaderWithoutMagicBytes;
    checksum_offset = payload_size + 10U;
    message_id = static_cast<std::uint32_t>(data[7]) |
                 (static_cast<std::uint32_t>(data[8]) << 8U) |
                 (static_cast<std::uint32_t>(data[9]) << 16U);
  } else {
    return MavlinkParseStatus::Noise;
  }

  if (expected_size != size || expected_size > kMavlinkMaxFrameBytes) {
    return MavlinkParseStatus::BadLength;
  }

  MavlinkMessageDefinition definition{};
  if (!mavlink_message_definition(message_id, definition)) {
    return MavlinkParseStatus::UnsupportedMessage;
  }
  std::size_t minimum_wire_payload_length =
      definition.minimum_payload_length;
  if (magic == kMavlinkV2Magic) {
    // These audited Mission Planner messages legally use MAVLink 2 trailing
    // zero truncation. Keep all other message definitions strict.
    if (message_id == 20U) {
      minimum_wire_payload_length = 4U;
    } else if (message_id == 76U) {
      minimum_wire_payload_length = 30U;
    }
  }
  if (payload_size < minimum_wire_payload_length ||
      payload_size > definition.maximum_payload_length ||
      (magic == kMavlinkV1Magic &&
       payload_size != definition.minimum_payload_length)) {
    return MavlinkParseStatus::BadLength;
  }
  const std::uint16_t calculated =
      packet_checksum(data, crc_input_size, definition.crc_extra);
  if (load_checksum(data + checksum_offset) != calculated) {
    return MavlinkParseStatus::BadCrc;
  }

  frame = {};
  std::copy_n(data, size, frame.bytes.begin());
  frame.size = size;
  populate_metadata(frame);
  return MavlinkParseStatus::FrameReady;
}

bool encode_mavlink_v1(std::uint8_t sequence, std::uint8_t system_id,
                       std::uint8_t component_id, std::uint32_t message_id,
                       const std::uint8_t* payload, std::size_t payload_size,
                       MavlinkFrame& frame) noexcept {
  MavlinkMessageDefinition definition{};
  if (message_id > 0xFFU || payload_size > kMavlinkMaxPayloadBytes ||
      (payload_size > 0U && payload == nullptr) ||
      !mavlink_message_definition(message_id, definition) ||
      payload_size != definition.minimum_payload_length) {
    return false;
  }

  frame = {};
  frame.bytes[0] = kMavlinkV1Magic;
  frame.bytes[1] = static_cast<std::uint8_t>(payload_size);
  frame.bytes[2] = sequence;
  frame.bytes[3] = system_id;
  frame.bytes[4] = component_id;
  frame.bytes[5] = static_cast<std::uint8_t>(message_id);
  if (payload_size > 0U) {
    std::copy_n(payload, payload_size, frame.bytes.begin() + 6U);
  }
  const std::uint16_t checksum = packet_checksum(
      frame.bytes.data(), payload_size + kV1HeaderWithoutMagicBytes,
      definition.crc_extra);
  store_checksum(checksum, frame.bytes.data() + payload_size + 6U);
  frame.size = payload_size + kV1PacketOverheadBytes;
  populate_metadata(frame);
  return true;
}

bool encode_mavlink_v2(
    std::uint8_t sequence, std::uint8_t system_id,
    std::uint8_t component_id, std::uint32_t message_id,
    const std::uint8_t* payload, std::size_t payload_size,
    MavlinkFrame& frame, std::uint8_t incompatibility_flags,
    std::uint8_t compatibility_flags,
    const std::uint8_t* signature) noexcept {
  MavlinkMessageDefinition definition{};
  const bool signed_frame = (incompatibility_flags & 0x01U) != 0U;
  if (message_id > 0xFFFFFFU || payload_size > kMavlinkMaxPayloadBytes ||
      (payload_size > 0U && payload == nullptr) ||
      (incompatibility_flags & static_cast<std::uint8_t>(~0x01U)) != 0U ||
      (signed_frame && signature == nullptr) ||
      !mavlink_message_definition(message_id, definition) ||
      payload_size < definition.minimum_payload_length ||
      payload_size > definition.maximum_payload_length) {
    return false;
  }

  frame = {};
  frame.bytes[0] = kMavlinkV2Magic;
  frame.bytes[1] = static_cast<std::uint8_t>(payload_size);
  frame.bytes[2] = incompatibility_flags;
  frame.bytes[3] = compatibility_flags;
  frame.bytes[4] = sequence;
  frame.bytes[5] = system_id;
  frame.bytes[6] = component_id;
  frame.bytes[7] = static_cast<std::uint8_t>(message_id & 0xFFU);
  frame.bytes[8] = static_cast<std::uint8_t>((message_id >> 8U) & 0xFFU);
  frame.bytes[9] = static_cast<std::uint8_t>((message_id >> 16U) & 0xFFU);
  if (payload_size > 0U) {
    std::copy_n(payload, payload_size, frame.bytes.begin() + 10U);
  }
  const std::uint16_t checksum = packet_checksum(
      frame.bytes.data(), payload_size + kV2HeaderWithoutMagicBytes,
      definition.crc_extra);
  const std::size_t checksum_offset = payload_size + 10U;
  store_checksum(checksum, frame.bytes.data() + checksum_offset);
  frame.size = payload_size + kV2PacketOverheadBytes;
  if (signed_frame) {
    std::copy_n(signature, kMavlinkSignatureBytes,
                frame.bytes.begin() + frame.size);
    frame.size += kMavlinkSignatureBytes;
  }
  populate_metadata(frame);
  return true;
}

MavlinkParseStatus MavlinkStreamParser::push(std::uint8_t byte,
                                             MavlinkFrame& frame) noexcept {
  ++diagnostics_.bytes_seen;
  if (buffered_size_ == 0U) {
    if (byte != kMavlinkV1Magic && byte != kMavlinkV2Magic) {
      ++diagnostics_.noise_bytes;
      return MavlinkParseStatus::Noise;
    }
    version_ = byte == kMavlinkV1Magic ? MavlinkVersion::V1
                                       : MavlinkVersion::V2;
    buffer_[0] = byte;
    buffered_size_ = 1U;
    expected_size_ = 0U;
    return MavlinkParseStatus::NeedMore;
  }

  if (buffered_size_ >= buffer_.size()) {
    ++diagnostics_.bad_lengths;
    clear_buffer();
    return MavlinkParseStatus::BadLength;
  }
  buffer_[buffered_size_++] = byte;

  if (buffered_size_ == 2U && version_ == MavlinkVersion::V1) {
    expected_size_ = static_cast<std::size_t>(buffer_[1]) +
                     kV1PacketOverheadBytes;
  } else if (buffered_size_ == 3U && version_ == MavlinkVersion::V2) {
    if ((buffer_[2] & static_cast<std::uint8_t>(~0x01U)) != 0U) {
      ++diagnostics_.unsupported_flags;
      clear_buffer();
      return MavlinkParseStatus::UnsupportedFlags;
    }
    const std::size_t signature_size =
        (buffer_[2] & 0x01U) != 0U ? kMavlinkSignatureBytes : 0U;
    expected_size_ = static_cast<std::size_t>(buffer_[1]) +
                     kV2PacketOverheadBytes + signature_size;
  }

  if (expected_size_ == 0U || buffered_size_ < expected_size_) {
    return MavlinkParseStatus::NeedMore;
  }
  if (buffered_size_ > expected_size_) {
    ++diagnostics_.bad_lengths;
    clear_buffer();
    return MavlinkParseStatus::BadLength;
  }

  const MavlinkParseStatus status =
      validate_mavlink_frame(buffer_.data(), buffered_size_, frame);
  switch (status) {
    case MavlinkParseStatus::FrameReady:
      ++diagnostics_.frames_accepted;
      break;
    case MavlinkParseStatus::BadLength:
      ++diagnostics_.bad_lengths;
      break;
    case MavlinkParseStatus::BadCrc:
      ++diagnostics_.crc_errors;
      break;
    case MavlinkParseStatus::UnsupportedMessage:
      ++diagnostics_.unsupported_messages;
      break;
    case MavlinkParseStatus::UnsupportedFlags:
      ++diagnostics_.unsupported_flags;
      break;
    case MavlinkParseStatus::NeedMore:
    case MavlinkParseStatus::Noise:
      break;
  }
  clear_buffer();
  return status;
}

void MavlinkStreamParser::reset() noexcept {
  clear_buffer();
  ++diagnostics_.explicit_resets;
}

void MavlinkStreamParser::clear_buffer() noexcept {
  buffered_size_ = 0U;
  expected_size_ = 0U;
}

}  // namespace vc_lora
