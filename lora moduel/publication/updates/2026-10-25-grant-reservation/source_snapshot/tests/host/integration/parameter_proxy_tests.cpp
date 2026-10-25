#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include "fixtures/mavlink_fixtures.hpp"
#include "vc_lora/embedded_io_adapter.hpp"
#include "vc_lora/ground_parameter_download_proxy.hpp"
#include "vc_lora/ground_usb_ordered_frame_backlog.hpp"
#include "vc_lora/late_uplink_recovery.hpp"
#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/mavlink_scheduler.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_ground.hpp"

namespace vc_lora::test {
namespace {

MavlinkFrame param_request_list(std::uint8_t sequence,
                                std::uint8_t target_system = 1U,
                                std::uint8_t target_component = 1U) {
  const std::array<std::uint8_t, 2U> payload{{target_system,
                                             target_component}};
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 21U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame signed_param_request_list(std::uint8_t sequence) {
  const std::array<std::uint8_t, 2U> payload{{1U, 1U}};
  std::array<std::uint8_t, kMavlinkSignatureBytes> signature{};
  for (std::size_t index = 0U; index < signature.size(); ++index) {
    signature[index] = static_cast<std::uint8_t>(0x90U + index);
  }
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 21U, payload.data(),
                          payload.size(), frame, 0x01U, 0U,
                          signature.data());
  return frame;
}

MavlinkFrame param_request_read_from(std::uint8_t sequence,
                                     std::uint8_t sender_system,
                                     std::uint8_t sender_component,
                                     std::uint8_t target_system,
                                     std::uint8_t target_component) {
  std::array<std::uint8_t, 20U> payload{};
  payload[0] = 0xFFU;
  payload[1] = 0xFFU;
  payload[2] = target_system;
  payload[3] = target_component;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, sender_system, sender_component, 20U,
                          payload.data(), payload.size(), frame);
  return frame;
}

MavlinkFrame timesync_from(std::uint8_t sequence,
                           std::uint64_t token) {
  std::array<std::uint8_t, 16U> payload{};
  for (std::size_t index = 0U; index < 8U; ++index) {
    payload[8U + index] = static_cast<std::uint8_t>(
        (token >> static_cast<unsigned>(index * 8U)) & 0xFFU);
  }
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 111U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame timesync_response_from(std::uint8_t sequence,
                                    std::uint64_t token) {
  std::array<std::uint8_t, 16U> payload{};
  for (std::size_t index = 0U; index < 8U; ++index) {
    payload[index] = static_cast<std::uint8_t>(
        (token >> static_cast<unsigned>(index * 8U)) & 0xFFU);
  }
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 111U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame ping_from(std::uint8_t sequence,
                       std::uint8_t target_system,
                       std::uint8_t target_component) {
  std::array<std::uint8_t, 14U> payload{};
  payload[8] = sequence;
  payload[12] = target_system;
  payload[13] = target_component;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 4U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame request_message_259(std::uint8_t sequence) {
  std::array<std::uint8_t, 33U> payload{};
  const float requested_message = 259.0F;
  std::memcpy(payload.data(), &requested_message,
              sizeof(requested_message));
  payload[28] = 0x00U;
  payload[29] = 0x02U;  // MAV_CMD_REQUEST_MESSAGE = 512
  payload[30] = 1U;
  payload[31] = 1U;
  payload[32] = 0U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 76U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame request_data_stream_from(
    std::uint8_t sequence, std::uint8_t stream_id,
    std::uint16_t message_rate, std::uint8_t start_stop,
    MavlinkVersion version = MavlinkVersion::V2) {
  std::array<std::uint8_t, 6U> payload{{
      static_cast<std::uint8_t>(message_rate & 0xFFU),
      static_cast<std::uint8_t>(message_rate >> 8U),
      1U, 1U, stream_id, start_stop}};
  MavlinkFrame frame{};
  if (version == MavlinkVersion::V1) {
    (void)encode_mavlink_v1(sequence, 255U, 190U, 66U,
                            payload.data(), payload.size(), frame);
  } else {
    (void)encode_mavlink_v2(sequence, 255U, 190U, 66U,
                            payload.data(), payload.size(), frame);
  }
  return frame;
}

MavlinkFrame autopilot_version_request_from(std::uint8_t sequence) {
  const std::array<std::uint8_t, 2U> payload{{1U, 1U}};
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 183U,
                          payload.data(), payload.size(), frame);
  return frame;
}

MavlinkFrame request_message_from(
    std::uint8_t sequence, float requested_message,
    std::uint8_t target_system, std::uint8_t target_component,
    MavlinkVersion version = MavlinkVersion::V2,
    std::uint16_t command = 512U, std::uint8_t confirmation = 0U,
    std::uint8_t sender_system = 255U,
    std::uint8_t sender_component = 190U,
    bool signed_frame = false) {
  std::array<std::uint8_t, 33U> payload{};
  std::memcpy(payload.data(), &requested_message,
              sizeof(requested_message));
  payload[28] = static_cast<std::uint8_t>(command & 0xFFU);
  payload[29] = static_cast<std::uint8_t>(command >> 8U);
  payload[30] = target_system;
  payload[31] = target_component;
  payload[32] = confirmation;
  MavlinkFrame frame{};
  if (version == MavlinkVersion::V1) {
    (void)encode_mavlink_v1(sequence, sender_system, sender_component, 76U,
                            payload.data(), payload.size(), frame);
  } else {
    std::array<std::uint8_t, kMavlinkSignatureBytes> signature{};
    for (std::size_t index = 0U; index < signature.size(); ++index) {
      signature[index] = static_cast<std::uint8_t>(0x60U + index);
    }
    (void)encode_mavlink_v2(
        sequence, sender_system, sender_component, 76U,
        payload.data(), payload.size(), frame,
        signed_frame ? 0x01U : 0U, 0U,
        signed_frame ? signature.data() : nullptr);
  }
  return frame;
}

MavlinkFrame shortened_mavlink_v2_from(
    std::uint8_t sequence, std::uint8_t sender_system,
    std::uint8_t sender_component, std::uint32_t message_id,
    const std::uint8_t* payload, std::size_t payload_size) {
  MavlinkFrame frame{};
  std::uint8_t crc_extra = 0U;
  if (payload_size > kMavlinkMaxPayloadBytes ||
      (payload_size > 0U && payload == nullptr) ||
      !mavlink_crc_extra(message_id, crc_extra)) {
    return frame;
  }
  frame.bytes[0] = kMavlinkV2Magic;
  frame.bytes[1] = static_cast<std::uint8_t>(payload_size);
  frame.bytes[2] = 0U;
  frame.bytes[3] = 0U;
  frame.bytes[4] = sequence;
  frame.bytes[5] = sender_system;
  frame.bytes[6] = sender_component;
  frame.bytes[7] = static_cast<std::uint8_t>(message_id & 0xFFU);
  frame.bytes[8] =
      static_cast<std::uint8_t>((message_id >> 8U) & 0xFFU);
  frame.bytes[9] =
      static_cast<std::uint8_t>((message_id >> 16U) & 0xFFU);
  if (payload_size > 0U) {
    std::copy_n(payload, payload_size, frame.bytes.begin() + 10U);
  }
  std::uint16_t crc = mavlink_x25_crc(
      frame.bytes.data() + 1U, payload_size + 9U);
  crc = mavlink_x25_accumulate(crc, crc_extra);
  frame.bytes[payload_size + 10U] =
      static_cast<std::uint8_t>(crc & 0xFFU);
  frame.bytes[payload_size + 11U] =
      static_cast<std::uint8_t>(crc >> 8U);
  frame.size = payload_size + 12U;
  frame.message_id = message_id;
  frame.sequence = sequence;
  frame.system_id = sender_system;
  frame.component_id = sender_component;
  frame.payload_length = static_cast<std::uint8_t>(payload_size);
  frame.version = MavlinkVersion::V2;
  frame.signed_frame = false;
  return frame;
}

MavlinkFrame short_param_request_read_from(
    std::uint8_t sequence, std::uint16_t parameter_index,
    std::uint8_t target_system = 1U,
    std::uint8_t target_component = 1U) {
  const std::array<std::uint8_t, 4U> payload{{
      static_cast<std::uint8_t>(parameter_index & 0xFFU),
      static_cast<std::uint8_t>(parameter_index >> 8U),
      target_system, target_component}};
  return shortened_mavlink_v2_from(
      sequence, 255U, 190U, 20U, payload.data(), payload.size());
}

MavlinkFrame short_request_message_from(
    std::uint8_t sequence, float requested_message,
    std::uint8_t target_system = 1U,
    std::uint8_t target_component = 1U,
    std::uint16_t command = 512U) {
  std::array<std::uint8_t, 32U> payload{};
  std::memcpy(payload.data(), &requested_message,
              sizeof(requested_message));
  payload[28] = static_cast<std::uint8_t>(command & 0xFFU);
  payload[29] = static_cast<std::uint8_t>(command >> 8U);
  payload[30] = target_system;
  payload[31] = target_component;
  return shortened_mavlink_v2_from(
      sequence, 255U, 190U, 76U, payload.data(), payload.size());
}

MavlinkFrame gcs_heartbeat_from(
    std::uint8_t sequence, MavlinkVersion version) {
  const std::array<std::uint8_t, 9U> payload{{
      0U, 0U, 0U, 0U, 6U, 8U, 0U, 0U, 3U}};
  MavlinkFrame frame{};
  if (version == MavlinkVersion::V1) {
    (void)encode_mavlink_v1(sequence, 255U, 190U, 0U,
                            payload.data(), payload.size(), frame);
  } else {
    (void)encode_mavlink_v2(sequence, 255U, 190U, 0U,
                            payload.data(), payload.size(), frame);
  }
  return frame;
}

MavlinkFrame param_value_from(std::uint8_t sequence,
                              std::uint8_t source_system,
                              std::uint8_t source_component,
                              const char* id, float value,
                              std::uint16_t index,
                              std::uint16_t count,
                              std::uint8_t param_type = 9U) {
  std::array<std::uint8_t, 25U> payload{};
  fixtures::put_float(payload.data(), value);
  fixtures::put_u16(payload.data() + 4U, count);
  fixtures::put_u16(payload.data() + 6U, index);
  fixtures::put_id(payload.data() + 8U, id);
  payload[24] = param_type;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, source_system, source_component, 22U,
                          payload.data(), payload.size(), frame);
  return frame;
}

std::uint16_t get_u16(const std::uint8_t* bytes) noexcept {
  return static_cast<std::uint16_t>(bytes[0]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(bytes[1]) << 8U);
}

std::int16_t request_index(const MavlinkFrame& frame) noexcept {
  return static_cast<std::int16_t>(get_u16(frame.payload()));
}

bool same_frame(const MavlinkFrame& lhs,
                const MavlinkFrame& rhs) noexcept {
  return lhs.size == rhs.size && lhs.message_id == rhs.message_id &&
         std::equal(lhs.bytes.begin(), lhs.bytes.begin() + lhs.size,
                    rhs.bytes.begin());
}

GroundParameterDownloadProxyConfig fast_config() noexcept {
  GroundParameterDownloadProxyConfig config{};
  config.value_timeout_ms = 100U;
  config.retry_backoff_ms = 20U;
  config.request_pacing_ms = 10U;
  config.terminal_hold_ms = 50U;
  config.max_value_attempts = 3U;
  return config;
}

struct RequestLease {
  MavlinkFrame frame{};
  std::uint32_t token{0U};
};

void check_index_request(const MavlinkFrame& frame,
                         std::uint16_t expected_index,
                         TestReport& report) {
  MavlinkFrame validated{};
  report.check(frame.message_id == 20U && frame.payload_length == 20U &&
                   validate_mavlink_frame(frame.bytes.data(), frame.size,
                                          validated) ==
                       MavlinkParseStatus::FrameReady,
               "proxy did not emit one valid PARAM_REQUEST_READ");
  report.check(request_index(frame) ==
                   static_cast<std::int16_t>(expected_index),
               "proxy emitted the wrong parameter index");
  report.check(frame.payload()[2] == 1U && frame.payload()[3] == 1U,
               "proxy changed target system/component");
  report.check(
      frame.system_id == 255U &&
          frame.component_id ==
              GroundParameterDownloadProxy::generated_component_id(),
      "proxy did not isolate its generated sequence component");
  report.check(std::all_of(frame.payload() + 4U, frame.payload() + 20U,
                           [](std::uint8_t byte) { return byte == 0U; }),
               "index request did not clear param_id");
}

RequestLease peek_request(GroundParameterDownloadProxy& proxy,
                          std::uint16_t expected_index,
                          TestReport& report) {
  RequestLease lease{};
  report.check(proxy.peek_next_request(lease.frame, lease.token),
               "proxy exposed no pending parameter read");
  report.check(lease.token != 0U, "request lease token was zero");
  check_index_request(lease.frame, expected_index, report);

  RequestLease repeated{};
  report.check(proxy.peek_next_request(repeated.frame, repeated.token) &&
                   repeated.token == lease.token &&
                   same_frame(repeated.frame, lease.frame),
               "peek did not retain one byte-exact outstanding lease");
  return lease;
}

RequestLease start_list(GroundParameterDownloadProxy& proxy,
                        std::uint64_t now_ms, TestReport& report,
                        std::uint8_t sequence = 1U) {
  const MavlinkFrame list = param_request_list(sequence);
  report.check(proxy.on_gcs_frame(list, now_ms) ==
                   GroundParameterProxyDisposition::Consumed,
               "PARAM_REQUEST_LIST was not terminated at Ground");
  proxy.tick(now_ms);
  return peek_request(proxy, 0U, report);
}

void check_no_request(GroundParameterDownloadProxy& proxy,
                      TestReport& report, const char* reason) {
  MavlinkFrame frame{};
  std::uint32_t token = 0U;
  report.check(!proxy.peek_next_request(frame, token), reason);
}

void drain_scheduler_frame(MavlinkFrameScheduler& scheduler,
                           MavlinkFrame& frame, TestReport& report) {
  std::array<std::uint8_t, kMavlinkMaxFrameBytes> bytes{};
  const std::size_t size = scheduler.peek(bytes.data(), bytes.size());
  report.check(size > 0U &&
                   validate_mavlink_frame(bytes.data(), size, frame) ==
                       MavlinkParseStatus::FrameReady,
               "scheduler exposed no complete MAVLink frame");
  if (size > 0U) {
    report.check(scheduler.complete_send(TxResult::Accepted, size),
                 "scheduler could not commit frame");
  }
}

void check_mission_planner_v2_truncation(TestReport& report) {
  // Exact R15 Mission Planner wire images. MAVLink 2 permits trailing zero
  // payload bytes to be omitted: #20 retains index/target in four bytes and
  // #76 retains every REQUEST_MESSAGE identity byte in 32 bytes while its
  // zero confirmation byte is absent. CRC is over the shortened wire image.
  constexpr std::array<std::uint8_t, 16U> kShortParamRequestRead{{
      0xFDU, 0x04U, 0x00U, 0x00U, 0xA2U, 0xFFU, 0xBEU, 0x14U,
      0x00U, 0x00U, 0x00U, 0x00U, 0x01U, 0x01U, 0x9FU, 0xF4U}};
  constexpr std::array<std::uint8_t, 44U> kShortRequestMessage{{
      0xFDU, 0x20U, 0x00U, 0x00U, 0x40U, 0xFFU, 0xBEU, 0x4CU,
      0x00U, 0x00U, 0x00U, 0x00U, 0x14U, 0x43U, 0x00U, 0x00U,
      0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
      0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
      0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x02U,
      0x01U, 0x01U, 0xD1U, 0x05U}};

  const auto parse_exact = [&report](const auto& wire,
                                     std::uint32_t message_id,
                                     std::uint8_t payload_length,
                                     MavlinkFrame& decoded) {
    MavlinkStreamParser parser{};
    MavlinkParseStatus status = MavlinkParseStatus::NeedMore;
    for (std::size_t index = 0U; index < wire.size(); ++index) {
      status = parser.push(wire[index], decoded);
      if (index + 1U < wire.size()) {
        report.check(status == MavlinkParseStatus::NeedMore,
                     "short MAVLink 2 frame escaped before its CRC");
      }
    }
    const bool ready = status == MavlinkParseStatus::FrameReady;
    report.check(ready,
                 "legal trailing-zero-truncated MAVLink 2 frame was rejected");
    if (ready) {
      report.check(
          decoded.version == MavlinkVersion::V2 &&
              decoded.message_id == message_id &&
              decoded.payload_length == payload_length &&
              decoded.size == wire.size() &&
              std::equal(wire.begin(), wire.end(), decoded.bytes.begin()) &&
              std::all_of(decoded.bytes.begin() + decoded.size,
                          decoded.bytes.end(),
                          [](std::uint8_t byte) { return byte == 0U; }) &&
              parser.diagnostics().frames_accepted == 1U &&
              parser.diagnostics().bad_lengths == 0U &&
              parser.diagnostics().crc_errors == 0U,
          "short MAVLink 2 metadata/raw bytes were not retained exactly");
    }
    return ready;
  };

  MavlinkFrame short_read{};
  MavlinkFrame short_request_message{};
  const bool read_ready = parse_exact(
      kShortParamRequestRead, 20U, 4U, short_read);
  const bool request_message_ready = parse_exact(
      kShortRequestMessage, 76U, 32U, short_request_message);

  // Audit the exact lower boundaries used by the product parser. Bytes
  // omitted from a MAVLink 2 payload are logical zeros, never the checksum
  // bytes that immediately follow the shortened payload on the wire.
  std::array<std::uint8_t, 20U> read_boundary_payload{};
  read_boundary_payload[2U] = 1U;
  read_boundary_payload[3U] = 1U;
  const MavlinkFrame read_len3 = shortened_mavlink_v2_from(
      0xA4U, 255U, 190U, 20U, read_boundary_payload.data(), 3U);
  MavlinkFrame boundary_decoded{};
  report.check(validate_mavlink_frame(read_len3.bytes.data(),
                                      read_len3.size,
                                      boundary_decoded) ==
                       MavlinkParseStatus::BadLength,
               "MAVLink 2 #20 payload shorter than four bytes was accepted");

  std::array<std::uint8_t, 33U> command_boundary_payload{};
  const float boundary_requested_message = 259.0F;
  std::memcpy(command_boundary_payload.data(), &boundary_requested_message,
              sizeof(boundary_requested_message));
  command_boundary_payload[28U] = 0x00U;
  command_boundary_payload[29U] = 0x02U;
  command_boundary_payload[30U] = 1U;
  const MavlinkFrame command_len29 = shortened_mavlink_v2_from(
      0xA5U, 255U, 190U, 76U, command_boundary_payload.data(), 29U);
  const MavlinkFrame command_len30 = shortened_mavlink_v2_from(
      0xA6U, 255U, 190U, 76U, command_boundary_payload.data(), 30U);
  const MavlinkFrame command_len31 = shortened_mavlink_v2_from(
      0xA7U, 255U, 190U, 76U, command_boundary_payload.data(), 31U);
  MavlinkFrame decoded_len30{};
  MavlinkFrame decoded_len31{};
  const bool len30_ready =
      validate_mavlink_frame(command_len30.bytes.data(), command_len30.size,
                             decoded_len30) ==
      MavlinkParseStatus::FrameReady;
  const bool len31_ready =
      validate_mavlink_frame(command_len31.bytes.data(), command_len31.size,
                             decoded_len31) ==
      MavlinkParseStatus::FrameReady;
  report.check(validate_mavlink_frame(command_len29.bytes.data(),
                                      command_len29.size,
                                      boundary_decoded) ==
                       MavlinkParseStatus::BadLength &&
                   len30_ready && len31_ready,
               "MAVLink 2 #76 lower payload boundaries were not 30/31 valid, "
               "29 invalid");
  if (len30_ready && len31_ready) {
    const bool len30_crc_nonzero =
        decoded_len30.bytes[40U] != 0U || decoded_len30.bytes[41U] != 0U;
    const bool len31_crc_nonzero =
        decoded_len31.bytes[41U] != 0U || decoded_len31.bytes[42U] != 0U;
    report.check(
        len30_crc_nonzero && len31_crc_nonzero &&
            decoded_len30.payload_byte_or_zero(29U) == 0x02U &&
            decoded_len30.payload_byte_or_zero(30U) == 0U &&
            decoded_len30.payload_byte_or_zero(31U) == 0U &&
            decoded_len30.payload_byte_or_zero(32U) == 0U &&
            decoded_len31.payload_byte_or_zero(30U) == 1U &&
            decoded_len31.payload_byte_or_zero(31U) == 0U &&
            decoded_len31.payload_byte_or_zero(32U) == 0U,
        "logical zero extension exposed shortened #76 CRC bytes as payload");
  }

  // MAVLink 1 has no trailing-zero truncation rule. This wire image has a
  // correct checksum for its four-byte payload, but must still be rejected
  // on schema length rather than being zero-extended implicitly.
  std::array<std::uint8_t, 12U> short_v1_read{{
      0xFEU, 0x04U, 0xA3U, 0xFFU, 0xBEU, 0x14U,
      0x00U, 0x00U, 0x01U, 0x01U, 0x00U, 0x00U}};
  std::uint8_t read_crc_extra = 0U;
  report.check(mavlink_crc_extra(20U, read_crc_extra),
               "PARAM_REQUEST_READ CRC extra is unavailable");
  std::uint16_t short_v1_crc = mavlink_x25_crc(
      short_v1_read.data() + 1U, 9U);
  short_v1_crc = mavlink_x25_accumulate(short_v1_crc, read_crc_extra);
  short_v1_read[10U] =
      static_cast<std::uint8_t>(short_v1_crc & 0xFFU);
  short_v1_read[11U] =
      static_cast<std::uint8_t>(short_v1_crc >> 8U);
  MavlinkFrame rejected_v1{};
  report.check(validate_mavlink_frame(short_v1_read.data(),
                                      short_v1_read.size(), rejected_v1) ==
                       MavlinkParseStatus::BadLength,
               "MAVLink 1 shortened #20 was accepted as zero-truncated");
  MavlinkStreamParser short_v1_parser{};
  MavlinkParseStatus short_v1_status = MavlinkParseStatus::NeedMore;
  for (const std::uint8_t byte : short_v1_read) {
    short_v1_status = short_v1_parser.push(byte, rejected_v1);
  }
  report.check(short_v1_status == MavlinkParseStatus::BadLength &&
                   short_v1_parser.diagnostics().bad_lengths == 1U &&
                   short_v1_parser.diagnostics().frames_accepted == 0U,
               "stream parser did not reject one valid-CRC MAVLink 1 "
               "shortened #20");

  const auto reject_bad_crc = [&report](const auto& wire) {
    auto corrupted = wire;
    corrupted[10U] ^= 0x01U;
    MavlinkFrame direct{};
    report.check(validate_mavlink_frame(corrupted.data(), corrupted.size(),
                                        direct) ==
                     MavlinkParseStatus::BadCrc,
                 "short MAVLink 2 corruption was not rejected by CRC");
    MavlinkStreamParser parser{};
    MavlinkFrame streamed{};
    MavlinkParseStatus status = MavlinkParseStatus::NeedMore;
    for (const std::uint8_t byte : corrupted) {
      status = parser.push(byte, streamed);
    }
    report.check(status == MavlinkParseStatus::BadCrc &&
                     parser.diagnostics().crc_errors == 1U &&
                     parser.diagnostics().frames_accepted == 0U,
                 "stream parser did not account one shortened-frame CRC error");
  };
  reject_bad_crc(kShortParamRequestRead);
  reject_bad_crc(kShortRequestMessage);

  const auto schedule_exact = [&report](const MavlinkFrame& frame,
                                        const auto& wire) {
    MavlinkFrameScheduler scheduler{};
    const MavlinkEnqueueStatus enqueue_status = scheduler.enqueue(frame, 1U);
    report.check(enqueue_status == MavlinkEnqueueStatus::Queued,
                 "validated short MAVLink 2 frame was rejected by scheduler");
    if (enqueue_status != MavlinkEnqueueStatus::Queued) {
      return;
    }
    std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
    const std::size_t output_size =
        scheduler.peek(output.data(), output.size());
    report.check(output_size == wire.size() &&
                     std::equal(wire.begin(), wire.end(), output.begin()) &&
                     scheduler.complete_send(TxResult::Accepted,
                                             output_size) &&
                     scheduler.empty(),
                 "scheduler changed or split shortened MAVLink 2 wire bytes");
  };
  if (read_ready) {
    schedule_exact(short_read, kShortParamRequestRead);

    // The Vehicle request tracker is the safety boundary used by missing-read
    // recovery. A four-byte index-mode request must never read the absent
    // param_id tail, and its matching #22 must release the owner only after
    // the exact response frame has completed physical transmission.
    MavlinkFrameScheduler tracker{};
    const MavlinkParameterRequestStatus remember_status =
        tracker.remember_parameter_request(short_read);
    report.check(remember_status ==
                     MavlinkParameterRequestStatus::Remembered &&
                     tracker.pending_parameter_requests() == 1U,
                 "short #20 was not safely remembered as an index request");
    if (remember_status == MavlinkParameterRequestStatus::Remembered) {
      const MavlinkFrame response =
          param_value_from(0xD0U, 1U, 1U, "ZERO", 0.0F, 0U, 932U);
      report.check(tracker.enqueue(response, 2U) ==
                           MavlinkEnqueueStatus::Queued &&
                       tracker.prioritized_parameter_values() == 1U &&
                       tracker.pending_parameter_requests() == 1U,
                   "matching #22 did not enter the target response lane");
      std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
      const std::size_t output_size =
          tracker.peek(output.data(), output.size());
      report.check(output_size == response.size &&
                       std::equal(response.bytes.begin(),
                                  response.bytes.begin() + response.size,
                                  output.begin()) &&
                       tracker.complete_send(TxResult::Accepted,
                                             output_size) &&
                       tracker.pending_parameter_requests() == 0U &&
                       tracker.prioritized_parameter_values() == 0U,
                   "short #20 tracker did not complete its byte-exact #22");
      const MavlinkSchedulerDiagnostics& diagnostics =
          tracker.diagnostics();
      report.check(diagnostics.parameter_requests_remembered == 1U &&
                       diagnostics.target_parameter_frames_queued == 1U &&
                       diagnostics.target_parameter_frames_completed == 1U &&
                       diagnostics.queue_drop_frames == 0U,
                   "short #20/#22 tracker accounting was not exact");
    }
  }
  if (request_message_ready) {
    schedule_exact(short_request_message, kShortRequestMessage);
  }

  const MavlinkFrame short_request_message_retry =
      short_request_message_from(0x41U, 148.0F, 1U, 1U);
  const MavlinkFrame short_request_message_deadline =
      short_request_message_from(0x42U, 148.0F, 1U, 1U);
  MavlinkFrame decoded_retry{};
  const bool retry_ready =
      validate_mavlink_frame(short_request_message_retry.bytes.data(),
                             short_request_message_retry.size,
                             decoded_retry) ==
      MavlinkParseStatus::FrameReady;
  report.check(retry_ready &&
                   short_request_message_retry.size ==
                       kShortRequestMessage.size() &&
                   std::equal(kShortRequestMessage.begin() + 10U,
                              kShortRequestMessage.begin() + 42U,
                              short_request_message_retry.bytes.begin() +
                                  10U) &&
                   short_request_message_retry.sequence !=
                       short_request_message.sequence &&
                   !std::equal(kShortRequestMessage.begin() + 42U,
                               kShortRequestMessage.end(),
                               short_request_message_retry.bytes.begin() +
                                   42U),
               "short #76 semantic retry did not vary sequence/CRC only");

  if (read_ready && request_message_ready && retry_ready) {
    GroundParameterDownloadProxyConfig config = fast_config();
    config.list_strategy = GroundParameterListStrategy::NativeStream;
    config.periodic_forward_interval_ms = 30000U;
    GroundParameterDownloadProxy proxy{config};
    const MavlinkFrame list = param_request_list(0x90U);
    report.check(proxy.on_gcs_frame(list, 0U) ==
                         GroundParameterProxyDisposition::Consumed &&
                     proxy.active(),
                 "short-frame proxy fixture did not start a native session");

    const MavlinkFrame original_read = short_read;
    const MavlinkFrame original_request_message = short_request_message;
    report.check(
        proxy.on_gcs_frame(short_read, 1U) ==
                GroundParameterProxyDisposition::Consumed &&
            proxy.on_gcs_frame(short_request_message, 2U) ==
                GroundParameterProxyDisposition::Forward &&
            proxy.on_gcs_frame(short_request_message_retry, 3U) ==
                GroundParameterProxyDisposition::Consumed &&
            proxy.on_gcs_frame(short_request_message_deadline, 30002U) ==
                GroundParameterProxyDisposition::Forward &&
            same_frame(short_read, original_read) &&
            same_frame(short_request_message, original_request_message),
        "proxy did not arm one shared gate for semantic short #76 retries");
  }

  if (len30_ready && len31_ready) {
    GroundParameterDownloadProxyConfig config = fast_config();
    config.list_strategy = GroundParameterListStrategy::NativeStream;
    config.periodic_forward_interval_ms = 30000U;
    GroundParameterDownloadProxy boundary_proxy{config};
    report.check(
        boundary_proxy.on_gcs_frame(param_request_list(0xA8U), 0U) ==
                GroundParameterProxyDisposition::Consumed &&
            boundary_proxy.on_gcs_frame(decoded_len30, 1U) ==
                GroundParameterProxyDisposition::Forward &&
            boundary_proxy.on_gcs_frame(decoded_len30, 2U) ==
                GroundParameterProxyDisposition::Consumed &&
            boundary_proxy.on_gcs_frame(decoded_len31, 3U) ==
                GroundParameterProxyDisposition::Forward &&
            boundary_proxy.on_gcs_frame(decoded_len31, 4U) ==
                GroundParameterProxyDisposition::Consumed,
        "valid #76 len30/31 frames did not use safe semantic coalescing");
  }

  report.detail =
      "Exact R15 MAVLink2 len=4 #20 and len=30..32 #76 were accepted, kept "
      "wire-exact through tracking/scheduling/proxy policy, retained "
      "MAVLink1 strict lengths, and kept corrupt variants CRC-closed.";
}

void check_full_list(TestReport& report) {
  GroundParameterDownloadProxyConfig config = fast_config();
  config.request_pacing_ms = 5U;
  config.value_timeout_ms = 1000U;
  GroundParameterDownloadProxy proxy{config};

  std::uint64_t request_time = 0U;
  RequestLease request = start_list(proxy, request_time, report);
  constexpr std::uint16_t kCount = 932U;
  for (std::uint16_t index = 0U; index < kCount; ++index) {
    check_index_request(request.frame, index, report);
    report.check(proxy.complete_request_tx(
                     request.token, TxResult::Accepted, request_time),
                 "accepted RF request lease did not complete");
    check_no_request(proxy, report,
                     "RF Accepted created a second outstanding read");
    report.check(proxy.expected_index() == index,
                 "RF Accepted advanced index without response/USB queue");

    char id[17]{};
    (void)std::snprintf(id, sizeof(id), "P%04u",
                        static_cast<unsigned>(index));
    const MavlinkFrame response = param_value_from(
        static_cast<std::uint8_t>(index), 1U, 1U, id,
        static_cast<float>(index), index, kCount);
    const MavlinkFrame original = response;
    report.check(proxy.on_vehicle_frame(response, true, request_time + 1U) ==
                     GroundParameterProxyDisposition::Consumed,
                 "matching CRC-valid PARAM_VALUE was not observed");
    report.check(same_frame(response, original),
                 "proxy mutated the frame atomically queued to USB");

    if (index + 1U == kCount) {
      break;
    }
    proxy.tick(request_time + config.request_pacing_ms);
    check_no_request(proxy, report,
                     "next index bypassed post-USB pacing");
    request_time += config.request_pacing_ms + 1U;
    proxy.tick(request_time);
    request = peek_request(proxy, static_cast<std::uint16_t>(index + 1U),
                           report);
  }

  proxy.tick(request_time + 10'000U);
  check_no_request(proxy, report,
                   "932-entry completion emitted an out-of-range read");
  report.check(!proxy.active() &&
                   proxy.state() == GroundParameterProxyState::Complete,
               "932-entry session did not complete at exact count");
  report.detail =
      "Ground terminated #21 and completed exactly 932 ordered index reads; "
      "each advance required matching #22 plus successful atomic USB queue.";
}

void check_native_list_stream(TestReport& report) {
  GroundParameterDownloadProxyConfig config = fast_config();
  config.list_strategy =
      GroundParameterListStrategy::NativeStream;
  config.value_timeout_ms = 1000U;
  GroundParameterDownloadProxy proxy{config};

  const MavlinkFrame list = param_request_list(0x31U);
  report.check(proxy.on_gcs_frame(list, 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "native #21 was not retained by the Ground lease");
  proxy.tick(0U);

  MavlinkFrame leased{};
  std::uint32_t token = 0U;
  report.check(proxy.peek_next_request(leased, token) && token != 0U &&
                   leased.message_id == 21U && same_frame(leased, list),
               "native lease did not preserve the original #21 byte-exactly");
  report.check(proxy.diagnostics().requests_generated == 0U,
               "native list incorrectly generated an indexed #20");

  const MavlinkFrame duplicate = param_request_list(0x32U);
  report.check(proxy.on_gcs_frame(duplicate, 1U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   proxy.diagnostics().list_requests_coalesced == 1U,
               "same-target #21 retry was not coalesced");
  MavlinkFrame repeated{};
  std::uint32_t repeated_token = 0U;
  report.check(proxy.peek_next_request(repeated, repeated_token) &&
                   repeated_token == token && same_frame(repeated, list),
               "coalesced retry changed or duplicated the native lease");

  report.check(proxy.mark_request_admitted(token, 2U) &&
                   proxy.mark_request_dequeued(token, 3U) &&
                   proxy.complete_request_tx(token, TxResult::Accepted, 4U) &&
                   proxy.state() ==
                       GroundParameterProxyState::AwaitingValue,
               "native #21 did not cross admission/dequeue/UL_DONE once");
  check_no_request(proxy, report,
                   "native stream exposed an indexed request after #21");

  constexpr std::uint16_t kCount = 932U;
  for (std::uint16_t index = 0U; index < kCount; ++index) {
    char id[17]{};
    (void)std::snprintf(id, sizeof(id), "N%04u",
                        static_cast<unsigned>(index));
    const MavlinkFrame value = param_value_from(
        static_cast<std::uint8_t>(index), 1U, 1U, id,
        static_cast<float>(index), index, kCount);
    report.check(proxy.on_vehicle_frame(
                     value, true, 5U + static_cast<std::uint64_t>(index)) ==
                     GroundParameterProxyDisposition::Consumed,
                 "native PARAM_VALUE did not advance after USB admission");
    check_no_request(proxy, report,
                     "native response generated a per-index uplink request");
  }

  const auto& diagnostics = proxy.diagnostics();
  report.check(proxy.state() == GroundParameterProxyState::Complete &&
                   !proxy.active() && proxy.expected_index() == 931U &&
                   proxy.param_count() == kCount,
               "native 932-frame stream did not complete exactly at index 931");
  report.check(diagnostics.requests_generated == 0U &&
                   diagnostics.request_tx_accepted == 1U &&
                   diagnostics.request_dequeues_observed == 1U &&
                   diagnostics.matching_values_seen == kCount &&
                   diagnostics.matching_values_usb_queued == kCount &&
                   diagnostics.sessions_completed == 1U &&
                   diagnostics.sessions_failed == 0U,
               "native stream retained a one-request-per-cycle dependency");

  GroundParameterDownloadProxy rejected{config};
  const MavlinkFrame rejected_list = param_request_list(0x41U);
  report.check(rejected.on_gcs_frame(rejected_list, 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "native rejection fixture did not start");
  MavlinkFrame rejected_lease{};
  std::uint32_t rejected_token = 0U;
  report.check(rejected.peek_next_request(rejected_lease, rejected_token) &&
                   rejected.mark_request_admitted(rejected_token, 1U) &&
                   rejected.mark_request_dequeued(rejected_token, 2U) &&
                   rejected.complete_request_tx(
                       rejected_token, TxResult::Accepted, 3U),
               "native rejection fixture did not commit #21");
  const MavlinkFrame rejected_value =
      param_value_from(0x42U, 1U, 1U, "REJECTED", 1.0F, 0U, 2U);
  report.check(rejected.on_vehicle_frame(rejected_value, false, 4U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   rejected.expected_index() == 0U &&
                   rejected.state() == GroundParameterProxyState::Failed &&
                   rejected.native_stream_poisoned() &&
                   rejected.diagnostics().matching_values_usb_rejected == 1U &&
                   rejected.diagnostics().native_stream_poison_events == 1U,
               "USB rejection did not poison native progress immediately");
  rejected.tick(100'003U);
  const MavlinkFrame retry_after_hold = param_request_list(0x43U);
  report.check(rejected.on_gcs_frame(retry_after_hold, 100'004U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   rejected.state() == GroundParameterProxyState::Failed &&
                   rejected.native_stream_poisoned(),
               "poisoned native stream re-armed after terminal hold");
  report.check(rejected.preclassify_vehicle_frame(
                   rejected_value, 100'005U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   rejected.diagnostics().native_stream_values_quarantined ==
                       1U,
                "poisoned native stream leaked a same-target PARAM_VALUE");

  GroundParameterDownloadProxy precommit_future{config};
  const MavlinkFrame precommit_list = param_request_list(0x48U);
  report.check(precommit_future.on_gcs_frame(precommit_list, 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "precommit-future fixture did not start");
  MavlinkFrame original_precommit_lease{};
  std::uint32_t original_precommit_token = 0U;
  report.check(precommit_future.peek_next_request(
                   original_precommit_lease, original_precommit_token),
               "precommit-future fixture exposed no #21 lease");
  const MavlinkFrame stale_precommit_future =
      param_value_from(0x49U, 1U, 1U, "STALE", 1.0F, 1U, 4U);
  report.check(precommit_future.on_vehicle_frame(
                   stale_precommit_future, true, 1U) ==
                   GroundParameterProxyDisposition::Consumed,
               "precommit future value was not quarantined");
  MavlinkFrame retained_precommit_lease{};
  std::uint32_t retained_precommit_token = 0U;
  report.check(
      precommit_future.peek_next_request(retained_precommit_lease,
                                         retained_precommit_token) &&
          retained_precommit_token == original_precommit_token &&
          same_frame(retained_precommit_lease, original_precommit_lease) &&
          retained_precommit_lease.message_id == 21U &&
          !precommit_future.native_stream_recovery_active() &&
          !precommit_future.recovery_latch().valid &&
          !precommit_future.native_stream_poisoned() &&
          precommit_future.diagnostics()
                  .native_stream_precommit_values_quarantined == 1U &&
          precommit_future.diagnostics().native_stream_values_quarantined ==
              1U &&
          precommit_future.diagnostics()
                  .native_stream_future_values_quarantined == 0U &&
          precommit_future.diagnostics()
                  .native_stream_old_duplicates_consumed == 0U &&
          precommit_future.diagnostics().native_stream_gap_recoveries == 0U &&
          precommit_future.diagnostics().count_mismatch_failures == 0U &&
          precommit_future.diagnostics().requests_generated == 0U,
      "future #22 replaced the unsent exactly-once native #21 lease");

  // R4 regression: the exact #21 had entered Ground's descriptor FIFO, but
  // before its UL_DONE a periodic same-target STAT_RUNTIME response arrived.
  // No #22 can be causally attributed to a request whose physical commit has
  // not completed, so retain the byte-exact lease without poisoning it.
  GroundParameterDownloadProxy precommit_unlisted{config};
  const MavlinkFrame precommit_unlisted_list = param_request_list(0x63U);
  report.check(precommit_unlisted.on_gcs_frame(
                   precommit_unlisted_list, 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "precommit-unlisted fixture did not start");
  MavlinkFrame precommit_unlisted_lease{};
  std::uint32_t precommit_unlisted_token = 0U;
  report.check(precommit_unlisted.peek_next_request(
                   precommit_unlisted_lease,
                   precommit_unlisted_token) &&
                   precommit_unlisted_token != 0U &&
                   precommit_unlisted.mark_request_admitted(
                       precommit_unlisted_token, 1U),
               "precommit-unlisted #21 was not admitted exactly once");
  const MavlinkFrame stat_runtime = param_value_from(
      119U, 1U, 1U, "STAT_RUNTIME", 933'456.0F, 0xFFFFU, 932U, 6U);
  report.check(precommit_unlisted.preclassify_vehicle_frame(
                   stat_runtime, 2U) ==
                   GroundParameterProxyDisposition::Consumed,
               "pre-UL_DONE unlisted #22 was not quarantined");
  MavlinkFrame retained_unlisted_lease{};
  std::uint32_t retained_unlisted_token = 0U;
  const auto& precommit_unlisted_diagnostics =
      precommit_unlisted.diagnostics();
  report.check(
      precommit_unlisted.peek_next_request(retained_unlisted_lease,
                                            retained_unlisted_token) &&
          retained_unlisted_token == precommit_unlisted_token &&
          same_frame(retained_unlisted_lease, precommit_unlisted_lease) &&
          precommit_unlisted.state() == GroundParameterProxyState::Ready &&
          precommit_unlisted.active() &&
          !precommit_unlisted.native_stream_poisoned() &&
          !precommit_unlisted.native_stream_recovery_active() &&
          !precommit_unlisted.recovery_latch().valid &&
          precommit_unlisted_diagnostics.sessions_failed == 0U &&
          precommit_unlisted_diagnostics.count_mismatch_failures == 0U &&
          precommit_unlisted_diagnostics.native_stream_poison_events == 0U &&
          precommit_unlisted_diagnostics
                  .native_stream_precommit_values_quarantined == 1U &&
          precommit_unlisted_diagnostics.native_stream_values_quarantined ==
              1U &&
          precommit_unlisted_diagnostics.requests_generated == 0U &&
          precommit_unlisted_diagnostics.request_tx_accepted == 0U,
      "pre-UL_DONE STAT_RUNTIME destroyed or advanced the original #21 lease");
  report.check(
      precommit_unlisted.mark_request_dequeued(
          precommit_unlisted_token, 3U) &&
          precommit_unlisted.complete_request_tx(
              precommit_unlisted_token, TxResult::Accepted, 4U) &&
          precommit_unlisted.state() ==
              GroundParameterProxyState::AwaitingValue,
      "quarantined precommit #22 prevented the original #21 UL_DONE commit");
  report.check(
      precommit_unlisted.preclassify_vehicle_frame(stat_runtime, 5U) ==
              GroundParameterProxyDisposition::Consumed &&
          precommit_unlisted.state() == GroundParameterProxyState::Failed &&
          precommit_unlisted.native_stream_poisoned() &&
          precommit_unlisted.recovery_latch().valid &&
          precommit_unlisted.recovery_latch().reason ==
              GroundParameterRecoveryReason::CountMismatch &&
          precommit_unlisted.diagnostics().count_mismatch_failures == 1U,
      "post-UL_DONE unlisted #22 did not retain strict CountMismatch failure");

  GroundParameterDownloadProxy precommit_expected{config};
  const MavlinkFrame precommit_expected_list = param_request_list(0x64U);
  MavlinkFrame precommit_expected_lease{};
  std::uint32_t precommit_expected_token = 0U;
  report.check(
      precommit_expected.on_gcs_frame(precommit_expected_list, 0U) ==
              GroundParameterProxyDisposition::Consumed &&
          precommit_expected.peek_next_request(precommit_expected_lease,
                                                precommit_expected_token) &&
          precommit_expected.mark_request_admitted(precommit_expected_token,
                                                   1U),
      "precommit expected-index fixture was not admitted");
  const MavlinkFrame stale_precommit_expected =
      param_value_from(0x65U, 1U, 1U, "STALE_ZERO", 0.0F, 0U, 932U);
  report.check(
      precommit_expected.on_vehicle_frame(stale_precommit_expected, true,
                                           2U) ==
              GroundParameterProxyDisposition::Consumed &&
          precommit_expected.expected_index() == 0U &&
          precommit_expected.state() == GroundParameterProxyState::Ready &&
          !precommit_expected.native_stream_poisoned() &&
          !precommit_expected.recovery_latch().valid &&
          precommit_expected.diagnostics().matching_values_seen == 0U &&
          precommit_expected.diagnostics().count_mismatch_failures == 0U &&
          precommit_expected.diagnostics()
                  .native_stream_precommit_values_quarantined == 1U,
      "precommit expected index advanced or poisoned the native stream");
  report.check(
      precommit_expected.on_vehicle_frame(stale_precommit_expected, false,
                                           3U) ==
              GroundParameterProxyDisposition::Consumed &&
          precommit_expected.expected_index() == 0U &&
          precommit_expected.diagnostics().matching_values_usb_rejected ==
              0U &&
          precommit_expected.diagnostics()
                  .native_stream_precommit_values_quarantined == 2U &&
          precommit_expected.diagnostics().native_stream_values_quarantined ==
              2U,
      "precommit usb_queued=false escaped causal quarantine");

  GroundParameterDownloadProxy precommit_invalid_count{config};
  const MavlinkFrame precommit_invalid_list = param_request_list(0x66U);
  MavlinkFrame precommit_invalid_lease{};
  std::uint32_t precommit_invalid_token = 0U;
  report.check(
      precommit_invalid_count.on_gcs_frame(precommit_invalid_list, 0U) ==
              GroundParameterProxyDisposition::Consumed &&
          precommit_invalid_count.peek_next_request(precommit_invalid_lease,
                                                     precommit_invalid_token) &&
          precommit_invalid_count.mark_request_admitted(
              precommit_invalid_token, 1U),
      "precommit invalid-count fixture was not admitted");
  const MavlinkFrame stale_zero_count =
      param_value_from(0x67U, 1U, 1U, "ZERO_COUNT", 0.0F, 0U, 0U);
  const MavlinkFrame stale_index_at_count =
      param_value_from(0x68U, 1U, 1U, "AT_COUNT", 0.0F, 4U, 4U);
  report.check(
      precommit_invalid_count.preclassify_vehicle_frame(stale_zero_count,
                                                         2U) ==
              GroundParameterProxyDisposition::Consumed &&
          precommit_invalid_count.preclassify_vehicle_frame(
              stale_index_at_count, 3U) ==
              GroundParameterProxyDisposition::Consumed &&
          precommit_invalid_count.state() == GroundParameterProxyState::Ready &&
          precommit_invalid_count.expected_index() == 0U &&
          !precommit_invalid_count.native_stream_poisoned() &&
          !precommit_invalid_count.recovery_latch().valid &&
          precommit_invalid_count.diagnostics().count_mismatch_failures == 0U &&
          precommit_invalid_count.diagnostics()
                  .native_stream_precommit_values_quarantined == 2U &&
          precommit_invalid_count.diagnostics()
                  .native_stream_values_quarantined == 2U,
      "causally stale invalid-count #22 reached semantic validation");

  GroundParameterDownloadProxy postcommit_zero_count{config};
  const MavlinkFrame postcommit_zero_list = param_request_list(0xD0U);
  MavlinkFrame postcommit_zero_lease{};
  std::uint32_t postcommit_zero_token = 0U;
  report.check(
      postcommit_zero_count.on_gcs_frame(postcommit_zero_list, 0U) ==
              GroundParameterProxyDisposition::Consumed &&
          postcommit_zero_count.peek_next_request(postcommit_zero_lease,
                                                   postcommit_zero_token) &&
          postcommit_zero_count.mark_request_admitted(postcommit_zero_token,
                                                       1U) &&
          postcommit_zero_count.mark_request_dequeued(postcommit_zero_token,
                                                       2U) &&
          postcommit_zero_count.complete_request_tx(
              postcommit_zero_token, TxResult::Accepted, 3U),
      "postcommit zero-count fixture did not commit #21");
  const MavlinkFrame postcommit_zero_value =
      param_value_from(0xD1U, 1U, 1U, "ZERO_COUNT", 0.0F, 0U, 0U);
  report.check(
      postcommit_zero_count.on_vehicle_frame(postcommit_zero_value, true,
                                              4U) ==
              GroundParameterProxyDisposition::Consumed &&
          postcommit_zero_count.state() ==
              GroundParameterProxyState::Failed &&
          postcommit_zero_count.native_stream_poisoned() &&
          postcommit_zero_count.recovery_latch().valid &&
          postcommit_zero_count.recovery_latch().reason ==
              GroundParameterRecoveryReason::CountMismatch &&
          postcommit_zero_count.expected_index() == 0U &&
          postcommit_zero_count.diagnostics().count_mismatch_failures == 1U &&
          postcommit_zero_count.diagnostics().native_stream_poison_events ==
              1U &&
          postcommit_zero_count.diagnostics()
                  .native_stream_values_quarantined == 1U &&
          postcommit_zero_count.diagnostics()
                  .native_stream_precommit_values_quarantined == 0U,
      "post-UL_DONE count zero did not fail closed as CountMismatch");

  GroundParameterDownloadProxy postcommit_index_at_count{config};
  const MavlinkFrame postcommit_index_list = param_request_list(0xD2U);
  MavlinkFrame postcommit_index_lease{};
  std::uint32_t postcommit_index_token = 0U;
  report.check(
      postcommit_index_at_count.on_gcs_frame(postcommit_index_list, 0U) ==
              GroundParameterProxyDisposition::Consumed &&
          postcommit_index_at_count.peek_next_request(postcommit_index_lease,
                                                       postcommit_index_token) &&
          postcommit_index_at_count.mark_request_admitted(
              postcommit_index_token, 1U) &&
          postcommit_index_at_count.mark_request_dequeued(
              postcommit_index_token, 2U) &&
          postcommit_index_at_count.complete_request_tx(
              postcommit_index_token, TxResult::Accepted, 3U),
      "postcommit index-at-count fixture did not commit #21");
  const MavlinkFrame postcommit_index_value =
      param_value_from(0xD3U, 1U, 1U, "AT_COUNT", 0.0F, 4U, 4U);
  report.check(
      postcommit_index_at_count.on_vehicle_frame(postcommit_index_value, true,
                                                  4U) ==
              GroundParameterProxyDisposition::Consumed &&
          postcommit_index_at_count.state() ==
              GroundParameterProxyState::Failed &&
          postcommit_index_at_count.native_stream_poisoned() &&
          postcommit_index_at_count.recovery_latch().valid &&
          postcommit_index_at_count.recovery_latch().reason ==
              GroundParameterRecoveryReason::CountMismatch &&
          postcommit_index_at_count.expected_index() == 0U &&
          postcommit_index_at_count.diagnostics().count_mismatch_failures ==
              1U &&
          postcommit_index_at_count.diagnostics().native_stream_poison_events ==
              1U &&
          postcommit_index_at_count.diagnostics()
                  .native_stream_values_quarantined == 1U &&
          postcommit_index_at_count.diagnostics()
                  .native_stream_precommit_values_quarantined == 0U,
      "post-UL_DONE index equal to count did not fail closed as CountMismatch");

  GroundParameterDownloadProxy precommit_wrong_source{config};
  const MavlinkFrame precommit_wrong_source_list = param_request_list(0x69U);
  MavlinkFrame precommit_wrong_source_lease{};
  std::uint32_t precommit_wrong_source_token = 0U;
  report.check(
      precommit_wrong_source.on_gcs_frame(precommit_wrong_source_list, 0U) ==
              GroundParameterProxyDisposition::Consumed &&
          precommit_wrong_source.peek_next_request(
              precommit_wrong_source_lease, precommit_wrong_source_token) &&
          precommit_wrong_source.mark_request_admitted(
              precommit_wrong_source_token, 1U),
      "precommit wrong-source fixture was not admitted");
  const MavlinkFrame wrong_source_value =
      param_value_from(0x6AU, 2U, 1U, "WRONG_SOURCE", 0.0F, 0U, 932U);
  report.check(
      precommit_wrong_source.preclassify_vehicle_frame(wrong_source_value,
                                                       2U) ==
              GroundParameterProxyDisposition::Consumed &&
          precommit_wrong_source.state() == GroundParameterProxyState::Failed &&
          precommit_wrong_source.native_stream_poisoned() &&
          precommit_wrong_source.recovery_latch().valid &&
          precommit_wrong_source.recovery_latch().reason ==
              GroundParameterRecoveryReason::SourceMismatch &&
          precommit_wrong_source.diagnostics()
                  .native_stream_precommit_values_quarantined == 0U &&
          !precommit_wrong_source.mark_request_dequeued(
              precommit_wrong_source_token, 3U),
      "precommit wrong-source #22 weakened strict SourceMismatch failure");

  GroundParameterDownloadProxy precommit_bad_crc{config};
  const MavlinkFrame precommit_bad_crc_list = param_request_list(0x6BU);
  MavlinkFrame precommit_bad_crc_lease{};
  std::uint32_t precommit_bad_crc_token = 0U;
  report.check(
      precommit_bad_crc.on_gcs_frame(precommit_bad_crc_list, 0U) ==
              GroundParameterProxyDisposition::Consumed &&
          precommit_bad_crc.peek_next_request(precommit_bad_crc_lease,
                                               precommit_bad_crc_token) &&
          precommit_bad_crc.mark_request_admitted(precommit_bad_crc_token,
                                                  1U),
      "precommit bad-CRC fixture was not admitted");
  MavlinkFrame bad_crc_value =
      param_value_from(0x6CU, 1U, 1U, "BAD_CRC", 0.0F, 0U, 932U);
  bad_crc_value.bytes[bad_crc_value.size - 1U] ^= 0x01U;
  report.check(
      precommit_bad_crc.preclassify_vehicle_frame(bad_crc_value, 2U) ==
              GroundParameterProxyDisposition::Invalid &&
          precommit_bad_crc.state() == GroundParameterProxyState::Failed &&
          precommit_bad_crc.native_stream_poisoned() &&
          precommit_bad_crc.recovery_latch().valid &&
          precommit_bad_crc.recovery_latch().reason ==
              GroundParameterRecoveryReason::InvalidFrame &&
          precommit_bad_crc.diagnostics().invalid_frames == 1U &&
          precommit_bad_crc.diagnostics()
                  .native_stream_precommit_values_quarantined == 0U,
      "precommit bad-CRC #22 weakened strict InvalidFrame failure");

  GroundParameterDownloadProxy precommit_deadline{config};
  const MavlinkFrame precommit_deadline_list = param_request_list(0x6DU);
  MavlinkFrame precommit_deadline_lease{};
  std::uint32_t precommit_deadline_token = 0U;
  report.check(
      precommit_deadline.on_gcs_frame(precommit_deadline_list, 0U) ==
              GroundParameterProxyDisposition::Consumed &&
          precommit_deadline.peek_next_request(precommit_deadline_lease,
                                                precommit_deadline_token) &&
          precommit_deadline.mark_request_admitted(precommit_deadline_token,
                                                   1U) &&
          precommit_deadline.preclassify_vehicle_frame(stat_runtime, 900U) ==
              GroundParameterProxyDisposition::Consumed,
      "precommit deadline fixture did not reach causal quarantine");
  precommit_deadline.tick(1'002U);
  report.check(
      precommit_deadline.state() == GroundParameterProxyState::Failed &&
          precommit_deadline.native_stream_poisoned() &&
          precommit_deadline.diagnostics().request_commit_timeouts == 1U &&
          precommit_deadline.diagnostics().sessions_failed == 1U &&
          precommit_deadline.diagnostics()
                  .native_stream_precommit_values_quarantined == 1U &&
          precommit_deadline.request_admission_abandoned(
              precommit_deadline_token),
      "precommit quarantine refreshed or bypassed the admission deadline");

  GroundParameterDownloadProxy out_of_order{config};
  const MavlinkFrame out_of_order_list = param_request_list(0x51U);
  report.check(out_of_order.on_gcs_frame(out_of_order_list, 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "native out-of-order poison fixture did not start");
  MavlinkFrame out_of_order_lease{};
  std::uint32_t out_of_order_token = 0U;
  report.check(out_of_order.peek_next_request(out_of_order_lease,
                                               out_of_order_token) &&
                   out_of_order.mark_request_admitted(out_of_order_token, 1U) &&
                   out_of_order.mark_request_dequeued(out_of_order_token, 2U) &&
                   out_of_order.complete_request_tx(
                       out_of_order_token, TxResult::Accepted, 3U),
                "native out-of-order poison lease did not commit");
  std::array<std::uint16_t, 4U> recovered_usb_order{};
  std::size_t recovered_usb_size = 0U;
  const MavlinkFrame first_value =
      param_value_from(0x52U, 1U, 1U, "FIRST", 0.0F, 0U, 4U);
  report.check(out_of_order.on_vehicle_frame(first_value, true, 4U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   out_of_order.expected_index() == 1U,
               "native recovery fixture did not commit index zero");
  recovered_usb_order[recovered_usb_size++] = 0U;
  const MavlinkFrame old_duplicate =
      param_value_from(0x53U, 1U, 1U, "FIRST", 0.0F, 0U, 4U);
  report.check(out_of_order.on_vehicle_frame(old_duplicate, true, 5U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   out_of_order.expected_index() == 1U &&
                   out_of_order.state() ==
                       GroundParameterProxyState::AwaitingValue &&
                   !out_of_order.native_stream_poisoned() &&
                   out_of_order.diagnostics()
                           .native_stream_old_duplicates_consumed == 1U,
               "old native duplicate was not consumed benignly");
  const MavlinkFrame future_value =
      param_value_from(0x54U, 1U, 1U, "FUTURE", 2.0F, 2U, 4U);
  report.check(out_of_order.on_vehicle_frame(future_value, true, 6U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   out_of_order.state() == GroundParameterProxyState::Ready &&
                   out_of_order.expected_index() == 1U &&
                   !out_of_order.native_stream_poisoned() &&
                   out_of_order.native_stream_recovery_active() &&
                   out_of_order.diagnostics().native_stream_gap_recoveries ==
                       1U &&
                   out_of_order.diagnostics()
                           .native_stream_future_values_quarantined == 1U &&
                   out_of_order.diagnostics()
                           .native_stream_recovery_requests_generated == 1U,
               "native future index did not enter bounded indexed recovery");
  const GroundParameterRecoveryLatch first_gap_latch =
      out_of_order.recovery_latch();
  report.check(first_gap_latch.valid &&
                   first_gap_latch.reason ==
                       GroundParameterRecoveryReason::FutureIndex &&
                   first_gap_latch.expected_index == 1U &&
                   first_gap_latch.received_index == 2U &&
                   first_gap_latch.received_count == 4U &&
                   first_gap_latch.received_sequence == 0x54U &&
                   first_gap_latch.observed_at_ms == 6U,
               "future-index recovery did not latch its first evidence");
  const RequestLease gap_read = peek_request(out_of_order, 1U, report);
  const MavlinkFrame later_future =
      param_value_from(0x56U, 1U, 1U, "LATER", 3.0F, 3U, 4U);
  report.check(out_of_order.on_vehicle_frame(later_future, true, 7U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   out_of_order.diagnostics()
                           .native_stream_future_values_quarantined == 1U &&
                   out_of_order.diagnostics()
                           .native_stream_precommit_values_quarantined == 1U &&
                   out_of_order.diagnostics()
                           .native_stream_recovery_requests_generated == 1U &&
                   out_of_order.recovery_latch().received_index ==
                       first_gap_latch.received_index &&
                   out_of_order.recovery_latch().received_sequence ==
                       first_gap_latch.received_sequence &&
                   out_of_order.recovery_latch().observed_at_ms ==
                       first_gap_latch.observed_at_ms,
               "later future value replaced the first recovery latch");
  report.check(out_of_order.mark_request_admitted(gap_read.token, 8U) &&
                   out_of_order.mark_request_dequeued(gap_read.token, 9U) &&
                   out_of_order.complete_request_tx(
                       gap_read.token, TxResult::Accepted, 10U) &&
                   out_of_order.diagnostics()
                           .native_stream_recovery_request_tx_accepted == 1U,
               "native gap recovery #20 did not cross the physical lease");
  const MavlinkFrame recovered_value =
      param_value_from(0x55U, 1U, 1U, "RECOVERED", 1.0F, 1U, 4U);
  report.check(out_of_order.preclassify_vehicle_frame(
                   recovered_value, 11U) ==
                   GroundParameterProxyDisposition::Forward,
               "valid recovery response failed pre-admission classification");
  report.check(out_of_order.on_vehicle_frame(recovered_value, true, 11U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   out_of_order.expected_index() == 2U &&
                   out_of_order.state() == GroundParameterProxyState::Backoff &&
                   out_of_order.diagnostics()
                           .native_stream_recovery_values_seen == 1U &&
                   out_of_order.diagnostics()
                           .native_stream_recovery_values_usb_queued == 1U,
               "USB-committed recovery value did not advance exactly once");
  recovered_usb_order[recovered_usb_size++] = 1U;
  out_of_order.tick(21U);
  const RequestLease read_two = peek_request(out_of_order, 2U, report);
  report.check(out_of_order.mark_request_admitted(read_two.token, 22U) &&
                   out_of_order.mark_request_dequeued(read_two.token, 23U) &&
                   out_of_order.complete_request_tx(
                       read_two.token, TxResult::Accepted, 24U),
               "second recovery #20 did not cross the physical lease");
  const MavlinkFrame value_two =
      param_value_from(0x57U, 1U, 1U, "TWO", 2.0F, 2U, 4U);
  report.check(out_of_order.preclassify_vehicle_frame(value_two, 25U) ==
                   GroundParameterProxyDisposition::Forward,
               "second recovery response failed preclassification");
  report.check(out_of_order.on_vehicle_frame(value_two, true, 25U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   out_of_order.expected_index() == 3U,
               "second recovery USB commit did not advance to index three");
  recovered_usb_order[recovered_usb_size++] = 2U;
  out_of_order.tick(35U);
  const RequestLease read_three = peek_request(out_of_order, 3U, report);
  report.check(out_of_order.mark_request_admitted(read_three.token, 36U) &&
                   out_of_order.mark_request_dequeued(read_three.token, 37U) &&
                   out_of_order.complete_request_tx(
                       read_three.token, TxResult::Accepted, 38U),
               "third recovery #20 did not cross the physical lease");
  const MavlinkFrame value_three =
      param_value_from(0x58U, 1U, 1U, "THREE", 3.0F, 3U, 4U);
  report.check(out_of_order.preclassify_vehicle_frame(value_three, 39U) ==
                   GroundParameterProxyDisposition::Forward,
               "final recovery response failed preclassification");
  report.check(out_of_order.on_vehicle_frame(value_three, true, 39U) ==
                   GroundParameterProxyDisposition::Consumed,
               "final recovery USB commit was not consumed");
  recovered_usb_order[recovered_usb_size++] = 3U;
  report.check(out_of_order.state() == GroundParameterProxyState::Complete &&
                   !out_of_order.active() &&
                   !out_of_order.native_stream_poisoned() &&
                   out_of_order.native_stream_recovery_active() &&
                   recovered_usb_size == recovered_usb_order.size() &&
                   recovered_usb_order ==
                       std::array<std::uint16_t, 4U>{{0U, 1U, 2U, 3U}} &&
                   out_of_order.diagnostics().requests_generated == 3U &&
                   out_of_order.diagnostics()
                           .native_stream_recovery_requests_generated == 3U &&
                   out_of_order.diagnostics()
                           .native_stream_recovery_request_tx_accepted == 3U &&
                   out_of_order.diagnostics()
                           .native_stream_recovery_values_seen == 3U &&
                   out_of_order.diagnostics()
                           .native_stream_recovery_values_usb_queued == 3U &&
                   out_of_order.diagnostics().unmatched_values_forwarded ==
                       0U &&
                   out_of_order.diagnostics().sessions_completed == 1U &&
                   out_of_order.diagnostics().sessions_failed == 0U,
               "indexed recovery did not finish the ordered four-value list");
  const GroundParameterRecoveryLatch completed_gap_latch =
      out_of_order.recovery_latch();
  report.check(out_of_order.on_gcs_frame(param_request_list(0x59U), 90U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   out_of_order.active() &&
                   !out_of_order.native_stream_recovery_active() &&
                   out_of_order.recovery_latch().valid &&
                   out_of_order.recovery_latch().received_sequence ==
                       completed_gap_latch.received_sequence,
               "new session did not clear runtime recovery or retained latch");
  out_of_order.cancel();
  report.check(!out_of_order.native_stream_recovery_active() &&
                   out_of_order.recovery_latch().valid,
               "soft cancel cleared the boot-lifetime first-fault latch");
  out_of_order.reset();
  report.check(!out_of_order.recovery_latch().valid &&
                   out_of_order.recovery_latch().reason ==
                       GroundParameterRecoveryReason::None &&
                   !out_of_order.native_stream_recovery_active() &&
                   !out_of_order.native_stream_poisoned() &&
                   out_of_order.diagnostics().sessions_started == 0U,
               "reset did not clear recovery state, latch, and diagnostics");

  GroundParameterDownloadProxy unaddressable{config};
  const MavlinkFrame unaddressable_list = param_request_list(0x59U);
  report.check(unaddressable.on_gcs_frame(unaddressable_list, 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "unaddressable native fixture did not start");
  MavlinkFrame unaddressable_lease{};
  std::uint32_t unaddressable_token = 0U;
  report.check(unaddressable.peek_next_request(unaddressable_lease,
                                                unaddressable_token) &&
                   unaddressable.mark_request_admitted(
                       unaddressable_token, 1U) &&
                   unaddressable.mark_request_dequeued(
                       unaddressable_token, 2U) &&
                   unaddressable.complete_request_tx(
                       unaddressable_token, TxResult::Accepted, 3U),
               "unaddressable native fixture did not commit #21");
  const MavlinkFrame large_first =
      param_value_from(0x5AU, 1U, 1U, "LARGE0", 0.0F, 0U, 32769U);
  report.check(unaddressable.on_vehicle_frame(large_first, true, 4U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   unaddressable.expected_index() == 1U,
               "native stream could not observe an otherwise valid large list");
  const MavlinkFrame large_gap =
      param_value_from(0x5BU, 1U, 1U, "LARGE2", 2.0F, 2U, 32769U);
  report.check(unaddressable.on_vehicle_frame(large_gap, true, 5U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   unaddressable.state() ==
                       GroundParameterProxyState::Failed &&
                   unaddressable.native_stream_poisoned() &&
                   !unaddressable.native_stream_recovery_active() &&
                   unaddressable.diagnostics().requests_generated == 0U &&
                   unaddressable.diagnostics().native_stream_gap_recoveries ==
                       0U &&
                   unaddressable.recovery_latch().reason ==
                       GroundParameterRecoveryReason::CountMismatch,
               "count beyond int16 recovery range generated an unsafe #20");

  GroundParameterDownloadProxy timed_out{config};
  const MavlinkFrame timed_out_list = param_request_list(0x61U);
  report.check(timed_out.on_gcs_frame(timed_out_list, 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "native timeout poison fixture did not start");
  MavlinkFrame timed_out_lease{};
  std::uint32_t timed_out_token = 0U;
  report.check(timed_out.peek_next_request(timed_out_lease,
                                           timed_out_token) &&
                   timed_out.mark_request_admitted(timed_out_token, 1U) &&
                   timed_out.mark_request_dequeued(timed_out_token, 2U) &&
                   timed_out.complete_request_tx(
                       timed_out_token, TxResult::Accepted, 3U),
               "native timeout poison lease did not commit");
  timed_out.tick(1002U);
  report.check(timed_out.state() ==
                   GroundParameterProxyState::AwaitingValue,
               "native inter-value watchdog expired before its boundary");
  timed_out.tick(1003U);
  report.check(timed_out.state() == GroundParameterProxyState::Ready &&
                   !timed_out.native_stream_poisoned() &&
                   timed_out.native_stream_recovery_active() &&
                   timed_out.diagnostics().value_timeouts == 1U &&
                   timed_out.diagnostics().native_stream_timeout_recoveries ==
                       1U &&
                   timed_out.diagnostics().requests_generated == 1U &&
                   timed_out.diagnostics().request_tx_accepted == 1U,
               "native stall did not transition to one indexed recovery read");
  (void)peek_request(timed_out, 0U, report);
  const GroundParameterRecoveryLatch timeout_latch =
      timed_out.recovery_latch();
  report.check(timeout_latch.valid &&
                   timeout_latch.reason ==
                       GroundParameterRecoveryReason::InterValueTimeout &&
                   timeout_latch.expected_index == 0U &&
                   timeout_latch.received_index == 0xFFFFU &&
                   timeout_latch.received_count == 0U &&
                   timeout_latch.received_sequence == 0U &&
                   timeout_latch.observed_at_ms == 1003U,
               "timeout recovery did not latch its sentinel evidence");
  MavlinkFrame timeout_read_frame{};
  std::uint32_t timeout_read_token = 0U;
  report.check(timed_out.peek_next_request(timeout_read_frame,
                                            timeout_read_token) &&
                   timed_out.mark_request_admitted(timeout_read_token, 1004U) &&
                   timed_out.mark_request_dequeued(timeout_read_token, 1005U) &&
                   timed_out.complete_request_tx(
                       timeout_read_token, TxResult::Accepted, 1006U),
               "timeout recovery #20 did not cross the physical lease");
  const MavlinkFrame timeout_value =
      param_value_from(0x62U, 1U, 1U, "ZERO", 0.0F, 0U, 3U);
  report.check(timed_out.on_vehicle_frame(timeout_value, true, 1007U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   timed_out.expected_index() == 1U &&
                   timed_out.state() == GroundParameterProxyState::Backoff,
               "timeout recovery response did not advance after USB commit");
  timed_out.tick(1017U);
  (void)peek_request(timed_out, 1U, report);

  const auto recovery_failure_fixture =
      [&config, &report](std::uint8_t list_sequence) {
        GroundParameterDownloadProxy proxy{config};
        const MavlinkFrame list_frame = param_request_list(list_sequence);
        report.check(proxy.on_gcs_frame(list_frame, 0U) ==
                         GroundParameterProxyDisposition::Consumed,
                     "native fail-closed fixture did not start");
        MavlinkFrame lease_frame{};
        std::uint32_t lease_token = 0U;
        report.check(proxy.peek_next_request(lease_frame, lease_token) &&
                         proxy.mark_request_admitted(lease_token, 1U) &&
                         proxy.mark_request_dequeued(lease_token, 2U) &&
                         proxy.complete_request_tx(
                             lease_token, TxResult::Accepted, 3U),
                     "native fail-closed fixture did not commit #21");
        const MavlinkFrame first = param_value_from(
            static_cast<std::uint8_t>(list_sequence + 1U), 1U, 1U,
            "FIRST", 0.0F, 0U, 4U);
        report.check(proxy.on_vehicle_frame(first, true, 4U) ==
                         GroundParameterProxyDisposition::Consumed,
                     "native fail-closed fixture did not commit index zero");
        const MavlinkFrame gap = param_value_from(
            static_cast<std::uint8_t>(list_sequence + 2U), 1U, 1U,
            "GAP", 2.0F, 2U, 4U);
        report.check(proxy.on_vehicle_frame(gap, true, 5U) ==
                         GroundParameterProxyDisposition::Consumed,
                     "native fail-closed fixture did not enter recovery");
        RequestLease read = peek_request(proxy, 1U, report);
        report.check(proxy.mark_request_admitted(read.token, 6U) &&
                         proxy.mark_request_dequeued(read.token, 7U) &&
                         proxy.complete_request_tx(
                             read.token, TxResult::Accepted, 8U),
                     "native fail-closed recovery read did not commit");
        return proxy;
      };

  GroundParameterDownloadProxy count_failed =
      recovery_failure_fixture(0x70U);
  const MavlinkFrame changed_count =
      param_value_from(0x73U, 1U, 1U, "COUNT", 1.0F, 1U, 5U);
  report.check(count_failed.on_vehicle_frame(changed_count, true, 9U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   count_failed.state() == GroundParameterProxyState::Failed &&
                   count_failed.native_stream_poisoned() &&
                   count_failed.expected_index() == 1U &&
                   count_failed.recovery_latch().reason ==
                       GroundParameterRecoveryReason::FutureIndex,
               "recovery count mismatch did not fail closed or overwrote latch");

  GroundParameterDownloadProxy source_failed =
      recovery_failure_fixture(0x80U);
  const MavlinkFrame wrong_source =
      param_value_from(0x83U, 2U, 1U, "SOURCE", 1.0F, 1U, 4U);
  report.check(source_failed.on_vehicle_frame(wrong_source, true, 9U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   source_failed.state() == GroundParameterProxyState::Failed &&
                   source_failed.native_stream_poisoned() &&
                   source_failed.expected_index() == 1U &&
                   source_failed.diagnostics().unmatched_values_forwarded ==
                       0U,
               "wrong-source recovery response did not fail closed");

  GroundParameterDownloadProxy invalid_failed =
      recovery_failure_fixture(0x90U);
  MavlinkFrame invalid_response =
      param_value_from(0x93U, 1U, 1U, "INVALID", 1.0F, 1U, 4U);
  invalid_response.bytes[invalid_response.size - 1U] ^= 0x01U;
  report.check(invalid_failed.on_vehicle_frame(invalid_response, true, 9U) ==
                   GroundParameterProxyDisposition::Invalid &&
                   invalid_failed.state() == GroundParameterProxyState::Failed &&
                   invalid_failed.native_stream_poisoned() &&
                   invalid_failed.expected_index() == 1U,
               "CRC-invalid recovery response did not fail closed");

  GroundParameterDownloadProxy usb_failed =
      recovery_failure_fixture(0xA0U);
  const MavlinkFrame usb_response =
      param_value_from(0xA3U, 1U, 1U, "USB", 1.0F, 1U, 4U);
  report.check(usb_failed.on_vehicle_frame(usb_response, false, 9U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   usb_failed.state() == GroundParameterProxyState::Failed &&
                   usb_failed.native_stream_poisoned() &&
                   usb_failed.expected_index() == 1U &&
                   usb_failed.diagnostics()
                           .native_stream_recovery_values_seen == 1U &&
                   usb_failed.diagnostics()
                           .native_stream_recovery_values_usb_queued == 0U,
               "USB-rejected recovery response advanced or did not fail closed");

  GroundParameterDownloadProxy late_recovery =
      recovery_failure_fixture(0xB0U);
  late_recovery.tick(1008U);
  report.check(late_recovery.state() == GroundParameterProxyState::Backoff &&
                   late_recovery.diagnostics().value_timeouts == 1U,
               "recovery timeout did not enter bounded retry backoff");
  late_recovery.tick(1028U);
  const RequestLease queued_retry =
      peek_request(late_recovery, 1U, report);
  report.check(late_recovery.mark_request_admitted(
                   queued_retry.token, 1029U),
               "late-response fixture did not admit its retry lease");
  const MavlinkFrame late_recovered_value =
      param_value_from(0xB3U, 1U, 1U, "LATE", 1.0F, 1U, 4U);
  report.check(late_recovery.on_vehicle_frame(
                   late_recovered_value, true, 1030U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   late_recovery.expected_index() == 2U &&
                   late_recovery.state() == GroundParameterProxyState::Backoff &&
                   !late_recovery.native_stream_poisoned() &&
                   late_recovery.diagnostics().request_retries == 1U &&
                   late_recovery.diagnostics()
                           .native_stream_recovery_requests_generated == 2U &&
                   late_recovery.diagnostics()
                           .native_stream_recovery_request_tx_accepted == 1U &&
                   late_recovery.diagnostics()
                           .native_stream_recovery_values_usb_queued == 1U &&
                   !late_recovery.complete_request_tx(
                       queued_retry.token, TxResult::Accepted, 1031U) &&
                   late_recovery.diagnostics().stale_completions == 1U,
               "late recovery value did not retire a queued retry safely");

  GroundParameterDownloadProxy set_recovery{config};
  const MavlinkFrame set_list = param_request_list(0xC0U);
  report.check(set_recovery.on_gcs_frame(set_list, 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "PARAM_SET recovery fixture did not start");
  MavlinkFrame set_list_lease{};
  std::uint32_t set_list_token = 0U;
  report.check(set_recovery.peek_next_request(set_list_lease,
                                               set_list_token) &&
                   set_recovery.mark_request_admitted(set_list_token, 1U) &&
                   set_recovery.mark_request_dequeued(set_list_token, 2U) &&
                   set_recovery.complete_request_tx(
                       set_list_token, TxResult::Accepted, 3U),
               "PARAM_SET recovery fixture did not commit #21");
  const MavlinkFrame set_first =
      param_value_from(0xC1U, 1U, 1U, "ZERO", 0.0F, 0U, 4U);
  const MavlinkFrame set_gap =
      param_value_from(0xC2U, 1U, 1U, "GAP", 2.0F, 2U, 4U);
  report.check(set_recovery.on_vehicle_frame(set_first, true, 4U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   set_recovery.on_vehicle_frame(set_gap, true, 5U) ==
                   GroundParameterProxyDisposition::Consumed,
               "PARAM_SET recovery fixture did not enter recovery");
  MavlinkFrame admitted_recovery{};
  std::uint32_t admitted_recovery_token = 0U;
  report.check(set_recovery.peek_next_request(admitted_recovery,
                                               admitted_recovery_token) &&
                   set_recovery.mark_request_admitted(
                       admitted_recovery_token, 6U),
               "PARAM_SET recovery fixture did not admit #20");
  const GroundParameterRecoveryLatch set_first_latch =
      set_recovery.recovery_latch();
  const MavlinkFrame active_set =
      fixtures::param_set_v2(0xC3U, "FIRST", 10.0F);
  report.check(set_recovery.on_gcs_frame(active_set, 7U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   set_recovery.state() == GroundParameterProxyState::Failed &&
                   set_recovery.native_stream_poisoned() &&
                   set_recovery.native_stream_recovery_active() &&
                   set_recovery.expected_index() == 1U &&
                   set_recovery.recovery_latch().reason ==
                       set_first_latch.reason &&
                   set_recovery.recovery_latch().received_sequence ==
                       set_first_latch.received_sequence &&
                   set_recovery.diagnostics().parameter_sets_rejected == 1U &&
                   set_recovery.diagnostics()
                           .parameter_sets_cancelled_session == 1U &&
                   !set_recovery.complete_request_tx(
                       admitted_recovery_token, TxResult::Accepted, 8U) &&
                   set_recovery.diagnostics()
                           .stale_request_dequeues_observed == 1U,
               "PARAM_SET did not quarantine an admitted recovery read");
  const MavlinkFrame stale_set_response =
      param_value_from(0xC4U, 1U, 1U, "FIRST", 1.0F, 1U, 4U);
  report.check(set_recovery.preclassify_vehicle_frame(
                   stale_set_response, 9U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   set_recovery.expected_index() == 1U,
               "cancelled recovery response escaped PARAM_SET quarantine");

  GroundParameterDownloadProxy saturated{config};
  const std::uint64_t maximum_time =
      std::numeric_limits<std::uint64_t>::max();
  const std::uint64_t near_maximum = maximum_time - 10U;
  const MavlinkFrame saturated_list = param_request_list(0xD0U);
  report.check(saturated.on_gcs_frame(saturated_list, near_maximum) ==
                   GroundParameterProxyDisposition::Consumed,
               "saturated deadline fixture did not start");
  MavlinkFrame saturated_lease{};
  std::uint32_t saturated_token = 0U;
  report.check(saturated.peek_next_request(saturated_lease, saturated_token) &&
                   saturated.mark_request_admitted(
                       saturated_token, near_maximum + 1U) &&
                   saturated.mark_request_dequeued(
                       saturated_token, near_maximum + 2U) &&
                   saturated.complete_request_tx(
                       saturated_token, TxResult::Accepted,
                       near_maximum + 3U),
               "saturated deadline fixture did not commit #21");
  saturated.tick(maximum_time - 1U);
  report.check(saturated.state() ==
                   GroundParameterProxyState::AwaitingValue,
               "saturated inter-value deadline expired before UINT64_MAX");
  saturated.tick(maximum_time);
  report.check(saturated.state() == GroundParameterProxyState::Ready &&
                   saturated.native_stream_recovery_active() &&
                   saturated.recovery_latch().reason ==
                       GroundParameterRecoveryReason::InterValueTimeout &&
                   saturated.recovery_latch().observed_at_ms == maximum_time,
               "UINT64_MAX deadline did not fail safely into recovery");
  (void)peek_request(saturated, 0U, report);

  // A frame can be classified while it is placed behind a paced heartbeat,
  // then reach the actual USB admission point in a later loop. Revalidate at
  // that final boundary: proxy state may have changed in the meantime.
  const auto commit_native_list = [&report](GroundParameterDownloadProxy& p,
                                             std::uint8_t sequence) {
    const MavlinkFrame request = param_request_list(sequence);
    MavlinkFrame request_lease{};
    std::uint32_t request_token = 0U;
    report.check(
        p.on_gcs_frame(request, 0U) ==
                GroundParameterProxyDisposition::Consumed &&
            p.peek_next_request(request_lease, request_token) &&
            p.mark_request_admitted(request_token, 1U) &&
            p.mark_request_dequeued(request_token, 2U) &&
            p.complete_request_tx(request_token, TxResult::Accepted, 3U),
        "backlog revalidation fixture did not commit native #21");
  };

  GroundParameterDownloadProxy direct_native{config};
  commit_native_list(direct_native, 0xD1U);
  const MavlinkFrame direct_value =
      param_value_from(0xD2U, 1U, 1U, "DIRECT", 1.0F, 0U, 1U);
  MavlinkValidatedLocalEgressAdapter<> direct_endpoint{};
  const GroundParameterProxyDisposition direct_preclassification =
      direct_native.preclassify_vehicle_frame(direct_value, 4U);
  const ValidatedLocalIngressStatus direct_admission =
      direct_preclassification == GroundParameterProxyDisposition::Forward
          ? direct_endpoint.admit_validated_frame(direct_value)
          : ValidatedLocalIngressStatus::Invalid;
  report.check(
      direct_preclassification == GroundParameterProxyDisposition::Forward &&
          direct_admission == ValidatedLocalIngressStatus::QueuedFrame &&
          direct_native.on_vehicle_frame(direct_value, true, 4U) ==
              GroundParameterProxyDisposition::Consumed &&
          direct_native.state() == GroundParameterProxyState::Complete &&
          direct_endpoint.egress().queued_bytes() == direct_value.size &&
          direct_endpoint.stats().frames_queued == 1U &&
          direct_native.diagnostics().matching_values_usb_queued == 1U,
      "ordinary direct #22 was not committed to USB exactly once");

  GroundParameterDownloadProxy delayed_direct{config};
  commit_native_list(delayed_direct, 0xD3U);
  const MavlinkFrame delayed_value =
      param_value_from(0xD4U, 1U, 1U, "DELAYED", 1.0F, 0U, 1U);
  GroundUsbOrderedFrameBacklog<> delayed_backlog{};
  report.check(
      delayed_direct.preclassify_vehicle_frame(delayed_value, 4U) ==
              GroundParameterProxyDisposition::Forward &&
          delayed_backlog.enqueue(delayed_value, false) ==
              GroundUsbOrderedBacklogStatus::Queued,
      "ordinary delayed #22 did not enter the ordered backlog");
  MavlinkFrame delayed_front{};
  bool delayed_marker = true;
  MavlinkValidatedLocalEgressAdapter<> delayed_endpoint{};
  report.check(
      delayed_backlog.peek(delayed_front, delayed_marker) && !delayed_marker &&
          delayed_direct.preclassify_vehicle_frame(delayed_front, 50U) ==
              GroundParameterProxyDisposition::Forward &&
          delayed_endpoint.admit_validated_frame(delayed_front) ==
              ValidatedLocalIngressStatus::QueuedFrame &&
          delayed_backlog.pop_front() &&
          delayed_direct.on_vehicle_frame(delayed_front, true, 50U) ==
              GroundParameterProxyDisposition::Consumed &&
          delayed_direct.state() == GroundParameterProxyState::Complete &&
          delayed_endpoint.egress().queued_bytes() == delayed_value.size &&
          delayed_direct.diagnostics().matching_values_usb_queued == 1U,
      "ordinary delayed #22 was not committed to USB exactly once");

  GroundParameterDownloadProxy crossed_timeout{config};
  commit_native_list(crossed_timeout, 0xD5U);
  const MavlinkFrame pretimeout_value =
      param_value_from(0xD6U, 1U, 1U, "CROSSED", 1.0F, 0U, 1U);
  GroundUsbOrderedFrameBacklog<> timeout_backlog{};
  report.check(
      crossed_timeout.preclassify_vehicle_frame(pretimeout_value, 1002U) ==
              GroundParameterProxyDisposition::Forward &&
          timeout_backlog.enqueue(pretimeout_value, false) ==
              GroundUsbOrderedBacklogStatus::Queued,
      "pre-timeout #22 did not enter the ordered backlog");
  crossed_timeout.tick(1003U);
  MavlinkFrame timeout_front{};
  bool timeout_marker = true;
  MavlinkValidatedLocalEgressAdapter<> timeout_endpoint{};
  report.check(
      crossed_timeout.native_stream_recovery_active() &&
          timeout_backlog.peek(timeout_front, timeout_marker) &&
          !timeout_marker &&
          crossed_timeout.preclassify_vehicle_frame(timeout_front, 1004U) ==
              GroundParameterProxyDisposition::Consumed &&
          timeout_backlog.discard_front() && timeout_endpoint.egress().empty() &&
          crossed_timeout.expected_index() == 0U,
      "timeout-crossed preclassified #22 leaked to USB or advanced progress");
  const RequestLease crossed_read = peek_request(crossed_timeout, 0U, report);
  report.check(crossed_timeout.mark_request_admitted(crossed_read.token, 1005U) &&
                   crossed_timeout.mark_request_dequeued(crossed_read.token,
                                                         1006U) &&
                   crossed_timeout.complete_request_tx(
                       crossed_read.token, TxResult::Accepted, 1007U),
               "timeout-crossed recovery #20 did not commit");
  const MavlinkFrame recovered_once =
      param_value_from(0xD7U, 1U, 1U, "CROSSED", 1.0F, 0U, 1U);
  const GroundParameterProxyDisposition recovered_preclassification =
      crossed_timeout.preclassify_vehicle_frame(recovered_once, 1008U);
  const ValidatedLocalIngressStatus recovered_admission =
      recovered_preclassification == GroundParameterProxyDisposition::Forward
          ? timeout_endpoint.admit_validated_frame(recovered_once)
          : ValidatedLocalIngressStatus::Invalid;
  report.check(
      recovered_preclassification == GroundParameterProxyDisposition::Forward &&
          recovered_admission == ValidatedLocalIngressStatus::QueuedFrame &&
          crossed_timeout.on_vehicle_frame(recovered_once, true, 1008U) ==
              GroundParameterProxyDisposition::Consumed &&
          crossed_timeout.state() == GroundParameterProxyState::Complete &&
          timeout_endpoint.egress().queued_bytes() == recovered_once.size &&
          crossed_timeout.diagnostics().matching_values_usb_queued == 1U &&
          crossed_timeout.diagnostics().native_stream_recovery_values_usb_queued ==
              1U,
      "timeout recovery exposed zero or duplicate USB PARAM_VALUE frames");

  GroundParameterDownloadProxy crossed_set{config};
  commit_native_list(crossed_set, 0xD8U);
  const MavlinkFrame preset_value =
      param_value_from(0xD9U, 1U, 1U, "SET_GUARD", 1.0F, 0U, 1U);
  GroundUsbOrderedFrameBacklog<> set_backlog{};
  report.check(
      crossed_set.preclassify_vehicle_frame(preset_value, 4U) ==
              GroundParameterProxyDisposition::Forward &&
          set_backlog.enqueue(preset_value, false) ==
              GroundUsbOrderedBacklogStatus::Queued,
      "pre-PARAM_SET #22 did not enter the ordered backlog");
  const MavlinkFrame crossed_param_set =
      fixtures::param_set_v2(0xDAU, "SET_GUARD", 2.0F);
  report.check(crossed_set.on_gcs_frame(crossed_param_set, 5U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   crossed_set.native_stream_poisoned(),
               "PARAM_SET did not poison the pending native session");
  MavlinkFrame set_front{};
  bool set_marker = true;
  MavlinkValidatedLocalEgressAdapter<> set_endpoint{};
  report.check(
      set_backlog.peek(set_front, set_marker) && !set_marker &&
          crossed_set.preclassify_vehicle_frame(set_front, 6U) ==
              GroundParameterProxyDisposition::Consumed &&
          set_backlog.discard_front() && set_endpoint.egress().empty() &&
          crossed_set.expected_index() == 0U &&
          crossed_set.diagnostics().matching_values_usb_queued == 0U,
      "PARAM_SET-poisoned preclassified #22 escaped backlog quarantine");

  // If k is already in the retractable backlog, native k+1 is conservatively
  // still a future index because logical progress is USB-commit-gated. The
  // current bounded policy may therefore fall back early, but it must discard
  // the preclassified k before USB and retrieve k..tail exactly once.
  GroundParameterDownloadProxy crossed_future{config};
  commit_native_list(crossed_future, 0xDBU);
  constexpr std::uint16_t kFutureCount = 3U;
  const MavlinkFrame reserved_zero =
      param_value_from(0xDCU, 1U, 1U, "FUTURE0", 0.0F, 0U, kFutureCount);
  GroundUsbOrderedFrameBacklog<> future_backlog{};
  report.check(
      crossed_future.preclassify_vehicle_frame(reserved_zero, 4U) ==
              GroundParameterProxyDisposition::Forward &&
          future_backlog.enqueue(reserved_zero, false) ==
              GroundUsbOrderedBacklogStatus::Queued,
      "reserved expected #22 did not enter the ordered backlog");
  const MavlinkFrame native_one =
      param_value_from(0xDDU, 1U, 1U, "FUTURE1", 1.0F, 1U, kFutureCount);
  report.check(
      crossed_future.preclassify_vehicle_frame(native_one, 5U) ==
              GroundParameterProxyDisposition::Consumed &&
          crossed_future.native_stream_recovery_active() &&
          crossed_future.recovery_latch().reason ==
              GroundParameterRecoveryReason::FutureIndex &&
          crossed_future.recovery_latch().expected_index == 0U &&
          crossed_future.recovery_latch().received_index == 1U,
      "future index beside a reserved expected frame did not enter fallback");
  MavlinkFrame reserved_front{};
  bool reserved_marker = true;
  MavlinkValidatedLocalEgressAdapter<> future_endpoint{};
  report.check(
      future_backlog.peek(reserved_front, reserved_marker) &&
          !reserved_marker &&
          crossed_future.preclassify_vehicle_frame(reserved_front, 6U) ==
              GroundParameterProxyDisposition::Consumed &&
          future_backlog.discard_front() && future_endpoint.egress().empty() &&
          crossed_future.expected_index() == 0U,
      "reserved expected #22 leaked after conservative future fallback");

  std::array<std::uint16_t, kFutureCount> future_usb_order{};
  std::size_t future_usb_size = 0U;
  std::size_t future_usb_bytes = 0U;
  std::uint64_t future_time = 10U;
  for (std::uint16_t index = 0U; index < kFutureCount; ++index) {
    const RequestLease read = peek_request(crossed_future, index, report);
    report.check(crossed_future.mark_request_admitted(read.token, future_time) &&
                     crossed_future.mark_request_dequeued(read.token,
                                                          future_time + 1U) &&
                     crossed_future.complete_request_tx(
                         read.token, TxResult::Accepted, future_time + 2U),
                 "future-fallback indexed #20 did not commit");
    char recovered_id[17]{};
    (void)std::snprintf(recovered_id, sizeof(recovered_id), "FUTURE%u",
                        static_cast<unsigned>(index));
    const MavlinkFrame value = param_value_from(
        static_cast<std::uint8_t>(0xDEU + index), 1U, 1U, recovered_id,
        static_cast<float>(index), index, kFutureCount);
    const GroundParameterProxyDisposition preclassification =
        crossed_future.preclassify_vehicle_frame(value, future_time + 3U);
    const ValidatedLocalIngressStatus admission =
        preclassification == GroundParameterProxyDisposition::Forward
            ? future_endpoint.admit_validated_frame(value)
            : ValidatedLocalIngressStatus::Invalid;
    report.check(
        preclassification == GroundParameterProxyDisposition::Forward &&
            admission == ValidatedLocalIngressStatus::QueuedFrame &&
            crossed_future.on_vehicle_frame(value, true, future_time + 3U) ==
                GroundParameterProxyDisposition::Consumed,
        "future-fallback recovery value did not commit to USB");
    future_usb_order[future_usb_size++] = index;
    future_usb_bytes += value.size;
    if (index + 1U < kFutureCount) {
      future_time += 13U;
      crossed_future.tick(future_time);
    }
  }
  report.check(
      crossed_future.state() == GroundParameterProxyState::Complete &&
          future_usb_size == future_usb_order.size() &&
          future_usb_order ==
              std::array<std::uint16_t, kFutureCount>{{0U, 1U, 2U}} &&
          future_endpoint.stats().frames_queued == kFutureCount &&
          future_endpoint.egress().queued_bytes() == future_usb_bytes &&
          crossed_future.diagnostics().requests_generated == kFutureCount &&
          crossed_future.diagnostics()
                  .native_stream_recovery_values_usb_queued == kFutureCount &&
          crossed_future.diagnostics().matching_values_usb_queued ==
              kFutureCount,
      "conservative future fallback did not complete k..tail exactly once");
  report.detail =
      "One byte-exact #21 crossed the existing lease exactly once; 932 ordered "
      "USB-committed #22 values completed with zero generated #20 requests; "
      "a future index or timeout switched only the missing tail to #20 reads.";
}

void check_native_recovery_exhaustion(TestReport& report) {
  GroundParameterDownloadProxyConfig config = fast_config();
  config.list_strategy = GroundParameterListStrategy::NativeStream;
  config.value_timeout_ms = 100U;
  config.retry_backoff_ms = 20U;
  config.max_value_attempts = 3U;
  GroundParameterDownloadProxy proxy{config};

  const MavlinkFrame list = param_request_list(0xE0U);
  report.check(proxy.on_gcs_frame(list, 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "native recovery-exhaustion fixture did not retain #21");
  MavlinkFrame list_lease{};
  std::uint32_t list_token = 0U;
  report.check(
      proxy.peek_next_request(list_lease, list_token) && list_token != 0U &&
          list_lease.message_id == 21U && same_frame(list_lease, list) &&
          proxy.mark_request_admitted(list_token, 1U) &&
          proxy.mark_request_dequeued(list_token, 2U) &&
          proxy.complete_request_tx(list_token, TxResult::Accepted, 3U),
      "native recovery-exhaustion fixture did not commit #21 exactly once");

  constexpr std::uint16_t kExpectedIndex = 1U;
  constexpr std::uint16_t kCount = 4U;
  const MavlinkFrame first =
      param_value_from(0xE1U, 1U, 1U, "FIRST", 0.0F, 0U, kCount);
  report.check(proxy.on_vehicle_frame(first, true, 4U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   proxy.expected_index() == kExpectedIndex &&
                   proxy.state() == GroundParameterProxyState::AwaitingValue,
               "recovery-exhaustion fixture did not commit index zero");

  const MavlinkFrame future =
      param_value_from(0xE2U, 1U, 1U, "FUTURE", 2.0F, 2U, kCount);
  report.check(proxy.on_vehicle_frame(future, true, 5U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   proxy.state() == GroundParameterProxyState::Ready &&
                   proxy.expected_index() == kExpectedIndex &&
                   proxy.native_stream_recovery_active() &&
                   !proxy.native_stream_poisoned(),
               "future index did not enter bounded recovery at missing index");

  const GroundParameterRecoveryLatch first_latch = proxy.recovery_latch();
  const auto latch_is_immutable = [&proxy, &first_latch]() noexcept {
    const GroundParameterRecoveryLatch& current = proxy.recovery_latch();
    return current.valid == first_latch.valid &&
           current.reason == first_latch.reason &&
           current.expected_index == first_latch.expected_index &&
           current.received_index == first_latch.received_index &&
           current.received_count == first_latch.received_count &&
           current.received_sequence == first_latch.received_sequence &&
           current.observed_at_ms == first_latch.observed_at_ms;
  };
  report.check(first_latch.valid &&
                   first_latch.reason ==
                       GroundParameterRecoveryReason::FutureIndex &&
                   first_latch.expected_index == kExpectedIndex &&
                   first_latch.received_index == 2U &&
                   first_latch.received_count == kCount &&
                   first_latch.received_sequence == 0xE2U &&
                   first_latch.observed_at_ms == 5U,
               "future-index first-recovery latch captured wrong evidence");

  constexpr std::array<std::uint64_t, 3U> kAdmitTimes{{10U, 140U, 270U}};
  constexpr std::array<std::uint64_t, 3U> kDequeueTimes{{11U, 141U, 271U}};
  constexpr std::array<std::uint64_t, 3U> kAcceptedTimes{{12U, 142U, 272U}};
  constexpr std::array<std::uint64_t, 3U> kResponseDeadlines{{112U, 242U,
                                                              372U}};
  constexpr std::array<std::uint64_t, 2U> kBackoffDeadlines{{132U, 262U}};
  std::array<MavlinkFrame, 3U> recovery_requests{};
  std::array<std::uint32_t, 3U> recovery_tokens{};
  std::size_t admitted_stages = 0U;
  std::size_t dequeued_stages = 0U;
  std::size_t accepted_stages = 0U;

  for (std::size_t attempt = 0U; attempt < recovery_requests.size();
       ++attempt) {
    const RequestLease lease = peek_request(proxy, kExpectedIndex, report);
    recovery_requests[attempt] = lease.frame;
    recovery_tokens[attempt] = lease.token;
    report.check(
        lease.frame.message_id == 20U &&
            request_index(lease.frame) ==
                static_cast<std::int16_t>(kExpectedIndex) &&
            (attempt == 0U ||
             (lease.token != recovery_tokens[attempt - 1U] &&
              std::equal(lease.frame.payload(),
                         lease.frame.payload() + lease.frame.payload_length,
                         recovery_requests[0U].payload()) &&
              lease.frame.sequence == static_cast<std::uint8_t>(
                                          recovery_requests[attempt - 1U]
                                              .sequence +
                                          1U))),
        "recovery retry changed the missing index/payload or duplicated its "
        "lease identity");

    const bool admitted =
        proxy.mark_request_admitted(lease.token, kAdmitTimes[attempt]);
    admitted_stages += admitted ? 1U : 0U;
    const bool dequeued =
        proxy.mark_request_dequeued(lease.token, kDequeueTimes[attempt]);
    dequeued_stages += dequeued ? 1U : 0U;
    const bool accepted = proxy.complete_request_tx(
        lease.token, TxResult::Accepted, kAcceptedTimes[attempt]);
    accepted_stages += accepted ? 1U : 0U;
    report.check(
        admitted && dequeued && accepted &&
            proxy.state() == GroundParameterProxyState::AwaitingValue &&
            proxy.expected_index() == kExpectedIndex &&
            proxy.diagnostics().native_stream_recovery_request_tx_accepted ==
                attempt + 1U &&
            proxy.diagnostics().request_dequeues_observed == attempt + 2U &&
            proxy.diagnostics().request_tx_accepted == attempt + 2U &&
            latch_is_immutable(),
        "recovery lease did not cross admitted/dequeued/accepted stages "
        "exactly once");

    proxy.tick(kResponseDeadlines[attempt] - 1U);
    report.check(
        proxy.state() == GroundParameterProxyState::AwaitingValue &&
            proxy.diagnostics().value_timeouts == attempt &&
            proxy.expected_index() == kExpectedIndex &&
            latch_is_immutable(),
        "recovery response timeout fired before its exact boundary");

    proxy.tick(kResponseDeadlines[attempt]);
    if (attempt + 1U < recovery_requests.size()) {
      report.check(
          proxy.state() == GroundParameterProxyState::Backoff &&
              !proxy.native_stream_poisoned() &&
              proxy.diagnostics().value_timeouts == attempt + 1U &&
              proxy.diagnostics().native_stream_recovery_requests_generated ==
                  attempt + 1U &&
              proxy.expected_index() == kExpectedIndex &&
              latch_is_immutable(),
          "nonterminal recovery timeout did not enter one bounded backoff");
      check_no_request(proxy, report,
                       "recovery request appeared before retry backoff");

      proxy.tick(kBackoffDeadlines[attempt] - 1U);
      report.check(
          proxy.state() == GroundParameterProxyState::Backoff &&
              proxy.diagnostics().native_stream_recovery_requests_generated ==
                  attempt + 1U &&
              proxy.diagnostics().request_retries == attempt &&
              latch_is_immutable(),
          "recovery retry appeared before the exact backoff boundary");
      check_no_request(proxy, report,
                       "recovery lease was exposed one millisecond early");

      proxy.tick(kBackoffDeadlines[attempt]);
      report.check(
          proxy.state() == GroundParameterProxyState::Ready &&
              proxy.diagnostics().native_stream_recovery_requests_generated ==
                  attempt + 2U &&
              proxy.diagnostics().request_retries == attempt + 1U &&
              proxy.expected_index() == kExpectedIndex &&
              latch_is_immutable(),
          "recovery retry was not generated at the exact backoff boundary");
    } else {
      report.check(
          proxy.state() == GroundParameterProxyState::Failed &&
              !proxy.active() && proxy.native_stream_poisoned() &&
              proxy.diagnostics().value_timeouts ==
                  recovery_requests.size() &&
              proxy.expected_index() == kExpectedIndex &&
              latch_is_immutable(),
          "third recovery timeout did not fail and poison the native stream");
    }
  }

  check_no_request(proxy, report,
                   "failed recovery exposed an unsafe fourth request");
  proxy.tick(10'000U);
  report.check(proxy.on_gcs_frame(param_request_list(0xE3U), 10'001U) ==
                   GroundParameterProxyDisposition::Consumed,
               "poisoned recovery did not suppress a repeated #21");
  check_no_request(proxy, report,
                   "poisoned recovery re-armed after terminal hold");

  const auto& diagnostics = proxy.diagnostics();
  report.check(
      admitted_stages == config.max_value_attempts &&
          dequeued_stages == config.max_value_attempts &&
          accepted_stages == config.max_value_attempts &&
          recovery_tokens[0U] != recovery_tokens[1U] &&
          recovery_tokens[1U] != recovery_tokens[2U] &&
          recovery_tokens[0U] != recovery_tokens[2U] &&
          proxy.state() == GroundParameterProxyState::Failed &&
          proxy.native_stream_poisoned() &&
          proxy.expected_index() == kExpectedIndex && latch_is_immutable() &&
          diagnostics.sessions_started == 1U &&
          diagnostics.sessions_completed == 0U &&
          diagnostics.sessions_failed == 1U &&
          diagnostics.native_list_requests_leased == 1U &&
          diagnostics.native_stream_poison_events == 1U &&
          diagnostics.native_stream_values_quarantined == 1U &&
          diagnostics.native_stream_precommit_values_quarantined == 0U &&
          diagnostics.native_stream_future_values_quarantined == 1U &&
          diagnostics.native_stream_gap_recoveries == 1U &&
          diagnostics.native_stream_timeout_recoveries == 0U &&
          diagnostics.native_stream_recovery_requests_generated == 3U &&
          diagnostics.native_stream_recovery_request_tx_accepted == 3U &&
          diagnostics.native_stream_recovery_values_seen == 0U &&
          diagnostics.native_stream_recovery_values_usb_queued == 0U &&
          diagnostics.requests_generated == 3U &&
          diagnostics.request_retries == 2U &&
          diagnostics.request_tx_accepted == 4U &&
          diagnostics.request_tx_rejected == 0U &&
          diagnostics.request_commit_timeouts == 0U &&
          diagnostics.request_dequeues_observed == 4U &&
          diagnostics.value_timeouts == 3U &&
          diagnostics.matching_values_seen == 1U &&
          diagnostics.matching_values_usb_queued == 1U &&
          diagnostics.matching_values_usb_rejected == 0U &&
          diagnostics.stale_completions == 0U,
      "recovery exhaustion counters, index, or first latch were not exact");
  report.detail =
      "Future index 2 at expected index 1 latched once; the proxy emitted "
      "exactly three index-1 PARAM_REQUEST_READ leases, honored 100 ms "
      "response and 20 ms backoff boundaries, then failed/poisoned without "
      "a fourth request.";
}

void check_matching_guards(TestReport& report) {
  const auto verify_nonadvance = [&report](const MavlinkFrame& wrong,
                                           const char* reason) {
    GroundParameterDownloadProxy proxy{fast_config()};
    const RequestLease lease = start_list(proxy, 0U, report);
    proxy.complete_request_tx(lease.token, TxResult::Accepted, 0U);
    const auto disposition = proxy.on_vehicle_frame(wrong, true, 1U);
    report.check(disposition != GroundParameterProxyDisposition::Consumed &&
                     proxy.expected_index() == 0U,
                 reason);
  };

  verify_nonadvance(param_value_from(10U, 1U, 1U, "STAT_RUNTIME", 1.0F,
                                     65535U, 932U),
                    "index 65535 advanced list progress");
  verify_nonadvance(param_value_from(11U, 1U, 1U, "FUTURE", 1.0F, 1U,
                                     932U),
                    "out-of-order index advanced list progress");
  verify_nonadvance(param_value_from(12U, 2U, 1U, "WRONG_SYS", 1.0F, 0U,
                                     932U),
                    "wrong source system advanced list progress");
  verify_nonadvance(param_value_from(13U, 1U, 2U, "WRONG_COMP", 1.0F, 0U,
                                     932U),
                    "wrong source component advanced list progress");
  verify_nonadvance(param_value_from(14U, 1U, 1U, "ZERO_COUNT", 1.0F, 0U,
                                     0U),
                    "zero param_count advanced list progress");

  GroundParameterDownloadProxy signed_index_guard{fast_config()};
  RequestLease signed_lease =
      start_list(signed_index_guard, 5U, report, 15U);
  const std::uint8_t first_generated_sequence = signed_lease.frame.sequence;
  std::uint64_t boundary_time_ms = 5U;
  bool boundary_ok = true;
  for (std::uint32_t index = 0U;
       index < 32768U && boundary_ok; ++index) {
    boundary_ok =
        request_index(signed_lease.frame) ==
            static_cast<std::int16_t>(index) &&
        signed_index_guard.complete_request_tx(
            signed_lease.token, TxResult::Accepted, boundary_time_ms);
    const MavlinkFrame value = param_value_from(
        static_cast<std::uint8_t>(index), 1U, 1U, "MAX_OK", 1.0F,
        static_cast<std::uint16_t>(index), 32768U);
    boundary_ok =
        boundary_ok &&
        signed_index_guard.on_vehicle_frame(
            value, true, boundary_time_ms + 1U) ==
            GroundParameterProxyDisposition::Consumed;
    if (index + 1U == 32768U) {
      break;
    }
    boundary_time_ms += 11U;
    signed_index_guard.tick(boundary_time_ms);
    boundary_ok =
        boundary_ok &&
        signed_index_guard.peek_next_request(signed_lease.frame,
                                              signed_lease.token);
  }
  MavlinkFrame no_boundary_overflow{};
  std::uint32_t no_boundary_token = 0U;
  report.check(
      boundary_ok && signed_lease.frame.payload()[0] == 0xFFU &&
          signed_lease.frame.payload()[1] == 0x7FU &&
          signed_lease.frame.sequence ==
              static_cast<std::uint8_t>(first_generated_sequence - 1U) &&
          signed_index_guard.state() ==
              GroundParameterProxyState::Complete &&
          !signed_index_guard.peek_next_request(no_boundary_overflow,
                                                 no_boundary_token),
      "count 32768 did not reach int16 index 32767, wrap sequence, and stop");

  GroundParameterDownloadProxy overflow_guard{fast_config()};
  RequestLease overflow_lease = start_list(overflow_guard, 7U, report, 17U);
  (void)overflow_guard.complete_request_tx(
      overflow_lease.token, TxResult::Accepted, 7U);
  const MavlinkFrame unaddressable = param_value_from(
      18U, 1U, 1U, "TOO_MANY", 1.0F, 0U, 32769U);
  report.check(overflow_guard.on_vehicle_frame(unaddressable, true, 8U) ==
                       GroundParameterProxyDisposition::Forward &&
                   overflow_guard.state() ==
                       GroundParameterProxyState::Failed,
               "param_count beyond positive int16 index range was accepted");

  GroundParameterDownloadProxy count_guard{fast_config()};
  RequestLease lease = start_list(count_guard, 10U, report, 20U);
  report.check(count_guard.complete_request_tx(
                   lease.token, TxResult::Accepted, 10U),
               "count-guard request completion failed");
  const MavlinkFrame first =
      param_value_from(21U, 1U, 1U, "ZERO", 0.0F, 0U, 2U);
  report.check(count_guard.on_vehicle_frame(first, true, 11U) ==
                   GroundParameterProxyDisposition::Consumed,
               "valid first count was not established");
  count_guard.tick(21U);
  lease = peek_request(count_guard, 1U, report);
  report.check(count_guard.complete_request_tx(
                   lease.token, TxResult::Accepted, 21U),
               "count-change request completion failed");
  const MavlinkFrame changed =
      param_value_from(22U, 1U, 1U, "ONE", 1.0F, 1U, 3U);
  report.check(count_guard.on_vehicle_frame(changed, true, 22U) ==
                       GroundParameterProxyDisposition::Forward &&
                   count_guard.state() == GroundParameterProxyState::Failed,
               "mid-session count change did not fail proxy transparently");
  report.detail =
      "index 65535, wrong order/source, zero/>INT16_MAX count and changing "
      "count never advanced the Ground-owned session.";
}

void check_timeout_retry(TestReport& report) {
  GroundParameterDownloadProxyConfig config = fast_config();
  config.value_timeout_ms = 100U;
  config.retry_backoff_ms = 20U;
  config.max_value_attempts = 2U;
  GroundParameterDownloadProxy proxy{config};
  RequestLease first = start_list(proxy, 0U, report);

  report.check(proxy.complete_request_tx(
                   first.token, TxResult::Rejected, 0U),
               "valid rejected lease token was not accepted");
  const RequestLease after_reject = peek_request(proxy, 0U, report);
  report.check(after_reject.token == first.token &&
                   same_frame(after_reject.frame, first.frame),
               "local RF rejection changed/consumed request lease");
  report.check(proxy.complete_request_tx(
                   after_reject.token, TxResult::Accepted, 0U),
               "accepted first request attempt did not complete");

  proxy.tick(99U);
  check_no_request(proxy, report, "retry occurred before value timeout");
  proxy.tick(100U);
  check_no_request(proxy, report, "retry bypassed stable backoff");
  proxy.tick(119U);
  check_no_request(proxy, report, "retry backoff ended early");
  proxy.tick(120U);
  const RequestLease retry = peek_request(proxy, 0U, report);
  report.check(proxy.complete_request_tx(
                   retry.token, TxResult::Accepted, 120U),
               "accepted retry request did not complete");
  proxy.tick(220U);
  proxy.tick(1000U);
  check_no_request(proxy, report,
                   "retry continued beyond max_value_attempts");
  report.check(!proxy.active(),
               "bounded timeout exhaustion left session active");

  const auto verify_late_response = [&report](bool after_backoff) {
    GroundParameterDownloadProxyConfig late_config = fast_config();
    late_config.value_timeout_ms = 100U;
    late_config.retry_backoff_ms = 20U;
    GroundParameterDownloadProxy late_proxy{late_config};
    RequestLease late_lease = start_list(late_proxy, 0U, report, 19U);
    (void)late_proxy.complete_request_tx(late_lease.token,
                                         TxResult::Accepted, 0U);
    late_proxy.tick(100U);
    if (after_backoff) {
      late_proxy.tick(120U);
      late_lease = peek_request(late_proxy, 0U, report);
    }
    const MavlinkFrame late_value =
        param_value_from(20U, 1U, 1U, "LATE", 1.0F, 0U, 2U);
    report.check(late_proxy.on_vehicle_frame(
                     late_value, true, after_backoff ? 121U : 110U) ==
                         GroundParameterProxyDisposition::Consumed &&
                     late_proxy.expected_index() == 1U,
                 after_backoff
                     ? "late value was rejected while retry lease was Ready"
                     : "late value was rejected during retry backoff");
    if (after_backoff) {
      report.check(!late_proxy.complete_request_tx(
                       late_lease.token, TxResult::Accepted, 122U),
                   "stale retry completion survived a late response");
    }
  };
  verify_late_response(false);
  verify_late_response(true);
  report.detail =
      "Rejected local lease retried byte-exactly; value timeout waited 20 ms "
      "and stopped after two accepted RF attempts; late responses remained "
      "valid during backoff and retry queueing.";
}

void check_duplicate_coalescing(TestReport& report) {
  GroundParameterDownloadProxyConfig config = fast_config();
  config.value_timeout_ms = 100'000U;
  GroundParameterDownloadProxy proxy{config};
  RequestLease lease = start_list(proxy, 0U, report, 30U);
  report.check(proxy.complete_request_tx(
                   lease.token, TxResult::Accepted, 0U),
               "coalescing fixture request completion failed");

  for (std::uint32_t second = 0U; second < 5U; ++second) {
    const MavlinkFrame duplicate_list =
        param_request_list(static_cast<std::uint8_t>(31U + second));
    report.check(proxy.on_gcs_frame(duplicate_list, second * 1000U) ==
                     GroundParameterProxyDisposition::Consumed,
                 "duplicate #21 escaped Ground termination");
    for (std::uint32_t request = 0U; request < 10U; ++request) {
      const std::int16_t index = static_cast<std::int16_t>(request % 3U);
      const MavlinkFrame missing = fixtures::param_request_read_v2(
          static_cast<std::uint8_t>(40U + second * 10U + request),
          "MISSING", index);
      report.check(proxy.on_gcs_frame(missing,
                                      second * 1000U + request * 100U) ==
                       GroundParameterProxyDisposition::Consumed,
                   "Mission Planner missing-read retry escaped coalescing");
    }
  }
  const MavlinkFrame other_target = param_request_list(91U, 2U, 1U);
  const MavlinkFrame other_sender = param_request_list(92U, 1U, 1U);
  MavlinkFrame other_sender_wire{};
  (void)encode_mavlink_v2(
      other_sender.sequence, 254U, other_sender.component_id, 21U,
      other_sender.payload(), other_sender.payload_length,
      other_sender_wire);
  const MavlinkFrame other_target_read =
      param_request_read_from(93U, 255U, 190U, 2U, 1U);
  const MavlinkFrame other_sender_read =
      param_request_read_from(94U, 254U, 190U, 1U, 1U);
  report.check(
      proxy.on_gcs_frame(other_target, 4501U) ==
              GroundParameterProxyDisposition::Forward &&
          proxy.on_gcs_frame(other_sender_wire, 4502U) ==
              GroundParameterProxyDisposition::Forward &&
          proxy.on_gcs_frame(other_target_read, 4503U) ==
              GroundParameterProxyDisposition::Forward &&
          proxy.on_gcs_frame(other_sender_read, 4504U) ==
              GroundParameterProxyDisposition::Forward,
      "different sender/target traffic was incorrectly coalesced");
  check_no_request(proxy, report,
                   "duplicate #21/#20 created another outstanding read");
  report.check(proxy.expected_index() == 0U,
               "duplicate requests changed index progress");

  const MavlinkFrame response =
      param_value_from(100U, 1U, 1U, "ZERO", 0.0F, 0U, 2U);
  (void)proxy.on_vehicle_frame(response, true, 5000U);
  report.check(proxy.expected_index() == 1U,
               "coalesced session did not resume at index 1");
  report.detail =
      "Five same-session duplicate #21 plus 50 #20 retries at 10/s were "
      "consumed; different sender/target requests remained passthrough.";
}

void check_usb_gate_and_bound(TestReport& report) {
  GroundParameterDownloadProxyConfig config = fast_config();
  config.retry_backoff_ms = 25U;
  GroundParameterDownloadProxy proxy{config};
  RequestLease lease = start_list(proxy, 0U, report);
  report.check(GroundParameterDownloadProxy::request_capacity() == 1U,
               "Ground proxy request capacity is not statically one");
  report.check(proxy.complete_request_tx(
                   lease.token, TxResult::Accepted, 0U),
               "USB-gate fixture request completion failed");
  check_no_request(proxy, report,
                   "RF Accepted alone advanced to another request");

  const MavlinkFrame response =
      param_value_from(110U, 1U, 1U, "ZERO", 0.0F, 0U, 2U);
  report.check(proxy.on_vehicle_frame(response, false, 1U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   proxy.expected_index() == 0U,
               "failed USB atomic queue advanced parameter index");
  proxy.tick(99U);
  check_no_request(proxy, report,
                   "USB queue failure retried before value timeout");
  proxy.tick(100U);
  check_no_request(proxy, report,
                   "USB queue failure bypassed retry backoff");
  proxy.tick(124U);
  check_no_request(proxy, report,
                   "USB queue retry backoff ended early");
  proxy.tick(125U);
  lease = peek_request(proxy, 0U, report);
  report.check(proxy.complete_request_tx(
                   lease.token, TxResult::Accepted, 125U),
               "USB queue retry request completion failed");
  report.check(proxy.on_vehicle_frame(response, true, 126U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   proxy.expected_index() == 1U,
               "successful USB atomic queue did not advance exactly once");
  proxy.tick(136U);
  lease = peek_request(proxy, 1U, report);
  RequestLease duplicate{};
  report.check(proxy.peek_next_request(duplicate.frame, duplicate.token) &&
                   duplicate.token == lease.token &&
                   same_frame(duplicate.frame, lease.frame),
               "one-outstanding request storage was not bounded");
  report.detail =
      "RF Accepted and USB queue failure did not advance; one successful "
      "atomic USB queue advanced exactly once with one leased request.";
}

void check_cancel_reset(TestReport& report) {
  GroundParameterDownloadProxy proxy{fast_config()};
  RequestLease lease = start_list(proxy, 0U, report);
  const std::uint8_t first_generated_sequence = lease.frame.sequence;
  proxy.complete_request_tx(lease.token, TxResult::Accepted, 0U);
  proxy.cancel();
  check_no_request(proxy, report, "cancel retained request lease");
  report.check(!proxy.active(), "cancel left session active");
  const MavlinkFrame late =
      param_value_from(120U, 1U, 1U, "LATE", 0.0F, 0U, 2U);
  report.check(proxy.on_vehicle_frame(late, true, 1U) ==
                   GroundParameterProxyDisposition::Forward,
               "late response after cancel was not ordinary telemetry");

  lease = start_list(proxy, 10U, report, 121U);
  report.check(
      lease.frame.sequence ==
          static_cast<std::uint8_t>(first_generated_sequence + 1U),
      "dedicated component sequence restarted across cancel/new session");
  proxy.complete_request_tx(lease.token, TxResult::Accepted, 10U);
  proxy.reset();  // setup()/reboot boundary.
  check_no_request(proxy, report, "reboot/reset retained request lease");
  report.check(!proxy.active(), "reboot/reset left session active");
  (void)start_list(proxy, 20U, report, 122U);

  GroundParameterDownloadProxyConfig hold_config = fast_config();
  hold_config.terminal_hold_ms = 50U;
  GroundParameterDownloadProxy hold_proxy{hold_config};
  RequestLease hold_lease = start_list(hold_proxy, 0U, report, 123U);
  (void)hold_proxy.complete_request_tx(hold_lease.token,
                                       TxResult::Accepted, 0U);
  const MavlinkFrame only =
      param_value_from(124U, 1U, 1U, "ONLY", 1.0F, 0U, 1U);
  (void)hold_proxy.on_vehicle_frame(only, true, 1U);
  report.check(hold_proxy.state() == GroundParameterProxyState::Complete,
               "one-entry cooldown fixture did not complete");
  bool fixed_hold_ok = true;
  for (std::uint64_t retry_ms = 10U; retry_ms <= 50U;
       retry_ms += 10U) {
    fixed_hold_ok =
        fixed_hold_ok &&
        hold_proxy.on_gcs_frame(
            param_request_list(static_cast<std::uint8_t>(125U + retry_ms)),
            retry_ms) == GroundParameterProxyDisposition::Consumed &&
        !hold_proxy.active();
  }
  report.check(fixed_hold_ok,
               "terminal #21 retry escaped the fixed cooldown");
  report.check(hold_proxy.on_gcs_frame(param_request_list(181U), 51U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   hold_proxy.active(),
               "sustained retries extended terminal cooldown indefinitely");
  report.detail =
      "Cancel/reset cleared state; component 191 sequence stayed monotonic, "
      "and terminal retries could re-arm only after a fixed cooldown.";
}

void check_passthrough_policy(TestReport& report) {
  GroundParameterDownloadProxy proxy{fast_config()};
  const MavlinkFrame single =
      fixtures::param_request_read_v2(130U, "SERIAL1_BAUD");
  const MavlinkFrame response = fixtures::param_value_v2(
      131U, "SERIAL1_BAUD", 57.0F, 10U, 932U);
  const MavlinkFrame heartbeat = fixtures::heartbeat_v2(132U);
  const MavlinkFrame set =
      fixtures::param_set_v2(134U, "SERIAL1_BAUD", 57.0F);
  report.check(proxy.on_gcs_frame(single, 0U) ==
                   GroundParameterProxyDisposition::Forward &&
               proxy.on_vehicle_frame(response, true, 1U) ==
                       GroundParameterProxyDisposition::Forward &&
               proxy.on_gcs_frame(set, 1U) ==
                       GroundParameterProxyDisposition::Forward,
               "idle single #20/#22/#23 regression was intercepted");

  RequestLease lease = start_list(proxy, 2U, report, 133U);
  const MavlinkFrame active_gcs_heartbeat =
      fixtures::heartbeat_v2(133U, 255U, 190U);
  report.check(proxy.on_gcs_frame(heartbeat, 3U) ==
                       GroundParameterProxyDisposition::Forward &&
                   proxy.on_gcs_frame(active_gcs_heartbeat, 3U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   proxy.active(),
               "active heartbeat sender policy was not selective");
  GroundMavlinkIngressAdapter stale_ingress{};
  report.check(stale_ingress.admit_validated_frame(lease.frame) ==
                       FrameIngressStatus::Queued &&
                   proxy.mark_request_admitted(lease.token, 3U),
               "stale-read fixture could not admit one generated #20");
  report.check(proxy.on_gcs_frame(set, 4U) ==
                        GroundParameterProxyDisposition::Consumed &&
                    !proxy.active() &&
                    proxy.state() == GroundParameterProxyState::Failed &&
                    proxy.diagnostics().parameter_sets_rejected == 1U &&
                    proxy.diagnostics().parameter_sets_cancelled_session ==
                        1U &&
                    proxy.diagnostics().
                            parameter_set_preexisting_usb_race_windows ==
                        1U,
               "active PARAM_SET was not rejected without execution");
  check_no_request(proxy, report,
                   "PARAM_SET cancellation exposed a deferred write");
  const MavlinkFrame duplicate_set =
      fixtures::param_set_v2(135U, "SERIAL1_BAUD", 57.0F);
  report.check(proxy.on_gcs_frame(duplicate_set, 4U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   proxy.diagnostics().parameter_sets_rejected == 2U,
               "same-param PARAM_SET retry escaped terminal rejection");
  const MavlinkFrame unrelated_value =
      param_value_from(138U, 1U, 1U, "OTHER", 2.0F, 9U, 932U);
  report.check(proxy.preclassify_vehicle_frame(unrelated_value, 55U) ==
                       GroundParameterProxyDisposition::Forward,
               "PARAM_SET quarantine suppressed an unrelated #22");
  report.check(proxy.on_gcs_frame(set, 53U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   proxy.on_gcs_frame(set, 54U) ==
                       GroundParameterProxyDisposition::Consumed,
               "pending stale #20 did not guard PARAM_SET past terminal hold");
  report.check(proxy.on_gcs_frame(param_request_list(143U, 2U, 1U), 55U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   !proxy.active(),
               "different-target session replaced a pending quarantine");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> stale_bytes{};
  const std::size_t stale_size = stale_ingress.peek(
      stale_bytes.data(), stale_ingress.front_frame_remaining());
  report.check(stale_ingress.complete_send(TxResult::Accepted, stale_size) &&
                   !proxy.complete_request_tx(
                       lease.token, TxResult::Accepted, 100U) &&
                   proxy.diagnostics().stale_request_dequeues_observed == 1U,
               "stale #20 dequeue did not re-arm response quarantine");
  const MavlinkFrame settled =
      param_value_from(137U, 1U, 1U, "SERIAL1_BAUD", 57.0F, 0U, 2U);
  MavlinkValidatedLocalEgressAdapter<> usb_endpoint{};
  const GroundParameterProxyDisposition preclassification =
      proxy.preclassify_vehicle_frame(settled, 101U);
  if (preclassification == GroundParameterProxyDisposition::Forward) {
    (void)usb_endpoint.admit_validated_frame(settled);
  }
  report.check(preclassification ==
                       GroundParameterProxyDisposition::Consumed &&
                   usb_endpoint.egress().empty() &&
                   proxy.diagnostics().parameter_values_quarantined == 1U,
               "late same-param #22 reached USB after stale #20 dequeue");
  check_no_request(proxy, report,
                   "late #22 released a hidden PARAM_SET write");
  report.check(proxy.on_gcs_frame(set, 199U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   proxy.on_gcs_frame(set, 200U) ==
                       GroundParameterProxyDisposition::Forward,
               "stale-response quarantine retry extended its fixed timeout");

  GroundParameterDownloadProxy escalation_proxy{fast_config()};
  (void)start_list(escalation_proxy, 0U, report, 138U);
  const MavlinkFrame conflicting_set =
      fixtures::param_set_v2(139U, "OTHER", 115.0F);
  const MavlinkFrame another_value =
      param_value_from(140U, 1U, 1U, "THIRD", 3.0F, 10U, 932U);
  report.check(
      escalation_proxy.on_gcs_frame(set, 1U) ==
              GroundParameterProxyDisposition::Consumed &&
          escalation_proxy.on_gcs_frame(conflicting_set, 2U) ==
              GroundParameterProxyDisposition::Consumed &&
          escalation_proxy.diagnostics().
                  parameter_set_quarantine_escalations == 1U &&
          escalation_proxy.preclassify_vehicle_frame(another_value, 3U) ==
              GroundParameterProxyDisposition::Consumed,
      "fixed quarantine did not fail safe for a second parameter ID");
  escalation_proxy.reset();
  report.check(escalation_proxy.preclassify_vehicle_frame(settled, 4U) ==
                   GroundParameterProxyDisposition::Forward,
               "reset retained stale PARAM_VALUE quarantine");

  const MavlinkFrame signed_list = signed_param_request_list(140U);
  const MavlinkFrame broadcast_system = param_request_list(141U, 0U, 1U);
  const MavlinkFrame broadcast_component = param_request_list(142U, 1U, 0U);
  report.check(signed_list.signed_frame &&
                   proxy.on_gcs_frame(signed_list, 201U) ==
                       GroundParameterProxyDisposition::Forward &&
                   proxy.on_gcs_frame(broadcast_system, 202U) ==
                       GroundParameterProxyDisposition::Forward &&
                   proxy.on_gcs_frame(broadcast_component, 203U) ==
                       GroundParameterProxyDisposition::Forward,
               "signed/broadcast #21 was unsafely rewritten");
  report.detail =
      "Idle #20/#22/#23 stayed transparent; active #23 cancelled the list "
      "and was rejected, the admitted #20 drained stale, and no delayed "
      "write was ever exposed.";
}

void check_heartbeat_priority(TestReport& report) {
  GroundParameterDownloadProxy proxy{fast_config()};
  const RequestLease lease = start_list(proxy, 0U, report);
  const MavlinkFrame heartbeat = fixtures::heartbeat_v2(140U);

  GroundMavlinkIngressAdapter long_run_uplink{};
  report.check(long_run_uplink.admit_validated_frame(lease.frame) ==
                   FrameIngressStatus::Queued,
               "long-run proxy request did not enter Ground ingress");
  std::size_t maximum_queued_frames = long_run_uplink.queued_frames();
  for (std::uint64_t second = 0U; second < 7200U; ++second) {
    const std::uint64_t now_ms = second * 1000U;
    const MavlinkFrame gcs_heartbeat = fixtures::heartbeat_v2(
        static_cast<std::uint8_t>(second), 255U, 190U);
    const MavlinkFrame timesync = timesync_from(
        static_cast<std::uint8_t>(second + 1U), second);
    report.check(proxy.on_gcs_frame(gcs_heartbeat, now_ms) ==
                         GroundParameterProxyDisposition::Consumed,
                 "periodic GCS heartbeat escaped active coalescing");
    if (proxy.on_gcs_frame(timesync, now_ms) ==
        GroundParameterProxyDisposition::Forward) {
      report.check(long_run_uplink.admit_validated_frame(timesync) ==
                       FrameIngressStatus::Queued,
                   "rate-limited TIMESYNC did not queue");
    }
    const MavlinkFrame request_message = request_message_259(
        static_cast<std::uint8_t>(second + 2U));
    if (proxy.on_gcs_frame(request_message, now_ms) ==
        GroundParameterProxyDisposition::Forward) {
      report.check(long_run_uplink.admit_validated_frame(request_message) ==
                       FrameIngressStatus::Queued,
                   "rate-limited REQUEST_MESSAGE did not queue");
    }
    if (second % 7U == 0U && !long_run_uplink.empty()) {
      std::array<std::uint8_t, kMavlinkMaxFrameBytes> frame_bytes{};
      const std::size_t frame_size = long_run_uplink.peek(
          frame_bytes.data(), long_run_uplink.front_frame_remaining());
      report.check(frame_size > 0U && long_run_uplink.complete_send(
                                          TxResult::Accepted, frame_size),
                   "long-run model could not drain one TDD frame");
    }
    maximum_queued_frames = std::max(maximum_queued_frames,
                                     long_run_uplink.queued_frames());
  }
  report.check(!long_run_uplink.fail_closed() &&
                   maximum_queued_frames <= 2U,
               "two-hour 1 Hz GCS trace caused Ground queue growth");
  const MavlinkFrame timesync_response =
      timesync_response_from(200U, 0x0102030405060708ULL);
  const MavlinkFrame ping_request = ping_from(201U, 0U, 0U);
  const MavlinkFrame ping_retry = ping_from(202U, 0U, 0U);
  const MavlinkFrame ping_response = ping_from(203U, 1U, 1U);
  report.check(
      proxy.on_gcs_frame(timesync_response, 7'200'000U) ==
              GroundParameterProxyDisposition::Forward &&
          proxy.on_gcs_frame(ping_request, 7'200'000U) ==
              GroundParameterProxyDisposition::Forward &&
          proxy.on_gcs_frame(ping_retry, 7'200'001U) ==
              GroundParameterProxyDisposition::Consumed &&
          proxy.on_gcs_frame(ping_response, 7'200'001U) ==
              GroundParameterProxyDisposition::Forward,
      "TIMESYNC/PING response transparency or request limiting regressed");
  const MavlinkFrame critical_a =
      fixtures::command_long_v2(201U, 400U, 1.0F);
  const MavlinkFrame critical_b =
      fixtures::command_long_v2(202U, 400U, 2.0F);
  report.check(proxy.on_gcs_frame(critical_a, 7'200'001U) ==
                       GroundParameterProxyDisposition::Forward &&
                   proxy.on_gcs_frame(critical_b, 7'200'002U) ==
                       GroundParameterProxyDisposition::Forward,
               "differing critical COMMAND_LONG frames were coalesced");

  // Ground uplink ingress already prioritizes complete-frame atomicity. The
  // generated request remains exactly one frame while the Vehicle downlink
  // scheduler continues to put HEARTBEAT ahead of PARAM_VALUE.
  GroundMavlinkIngressAdapter uplink{};
  for (std::size_t index = 0U; index < lease.frame.size; ++index) {
    (void)uplink.ingest_byte(lease.frame.bytes[index]);
  }
  report.check(uplink.queued_frames() == 1U &&
                   uplink.front_message_id() == 20U &&
                   uplink.front_frame_remaining() == lease.frame.size,
               "proxy request lost existing atomic Ground TDD ingress");

  const MavlinkFrame response =
      param_value_from(141U, 1U, 1U, "ZERO", 0.0F, 0U, 1U);
  MavlinkFrameScheduler scheduler{};
  report.check(scheduler.enqueue(response, 1U) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(heartbeat, 1U) ==
                       MavlinkEnqueueStatus::Queued,
               "heartbeat/parameter fixtures did not enqueue");
  MavlinkFrame first{};
  MavlinkFrame second{};
  drain_scheduler_frame(scheduler, first, report);
  drain_scheduler_frame(scheduler, second, report);
  report.check(first.message_id == 0U && same_frame(first, heartbeat) &&
                   second.message_id == 22U && same_frame(second, response),
               "Ground-owned proxy regressed Vehicle heartbeat priority");
  report.detail =
      "Two-hour 1 Hz GCS heartbeat/TIMESYNC/REQUEST_MESSAGE traffic stayed "
      "bounded while Vehicle HEARTBEAT still preceded PARAM_VALUE.";
}

void check_r15_periodic_uplink_bound(TestReport& report) {
  GroundParameterDownloadProxyConfig config = fast_config();
  config.list_strategy = GroundParameterListStrategy::NativeStream;
  config.value_timeout_ms = 30000U;
  config.periodic_forward_interval_ms = 30000U;

  // Coalescing is a scoped download policy. With no active native parameter
  // session, even exact repetitions remain a transparent bridge operation.
  GroundParameterDownloadProxy idle{config};
  const MavlinkFrame idle_stream =
      request_data_stream_from(0x10U, 2U, 2U, 1U);
  const MavlinkFrame idle_version =
      autopilot_version_request_from(0x11U);
  const MavlinkFrame idle_request = request_message_from(
      0x12U, 259.0F, 1U, 1U);
  const MavlinkFrame idle_command =
      fixtures::command_long_v2(0x13U, 400U, 1.0F);
  report.check(
      idle.on_gcs_frame(idle_stream, 0U) ==
              GroundParameterProxyDisposition::Forward &&
          idle.on_gcs_frame(idle_stream, 1U) ==
              GroundParameterProxyDisposition::Forward &&
          idle.on_gcs_frame(idle_version, 2U) ==
              GroundParameterProxyDisposition::Forward &&
          idle.on_gcs_frame(idle_version, 3U) ==
              GroundParameterProxyDisposition::Forward &&
          idle.on_gcs_frame(idle_request, 4U) ==
              GroundParameterProxyDisposition::Forward &&
          idle.on_gcs_frame(idle_request, 5U) ==
              GroundParameterProxyDisposition::Forward &&
          idle.on_gcs_frame(idle_command, 6U) ==
              GroundParameterProxyDisposition::Forward &&
          idle.on_gcs_frame(idle_command, 7U) ==
              GroundParameterProxyDisposition::Forward,
      "periodic repair changed idle transparent forwarding");

  // IndexedRead is also a long-lived parameter session and shares the same
  // finite Ground ingress. Preserve its existing bounded background policy;
  // only the completely Idle bridge is transparent to repeated setup frames.
  GroundParameterDownloadProxy indexed{fast_config()};
  (void)start_list(indexed, 0U, report, 0x14U);
  report.check(indexed.active() &&
                    indexed.on_gcs_frame(idle_stream, 1U) ==
                        GroundParameterProxyDisposition::Forward &&
                    indexed.on_gcs_frame(idle_stream, 2U) ==
                        GroundParameterProxyDisposition::Consumed &&
                    indexed.on_gcs_frame(idle_version, 3U) ==
                        GroundParameterProxyDisposition::Forward &&
                    indexed.on_gcs_frame(idle_version, 4U) ==
                        GroundParameterProxyDisposition::Consumed &&
                    indexed.on_gcs_frame(idle_request, 5U) ==
                        GroundParameterProxyDisposition::Forward &&
                    indexed.on_gcs_frame(idle_request, 6U) ==
                        GroundParameterProxyDisposition::Consumed,
                "periodic repair escaped an active parameter-session scope");

  GroundParameterDownloadProxy policy{config};
  report.check(policy.on_gcs_frame(param_request_list(0x20U), 0U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   policy.active(),
               "periodic-policy fixture did not start a native session");
  const MavlinkFrame stream_initial =
      request_data_stream_from(0x21U, 2U, 2U, 1U);
  const MavlinkFrame stream_duplicate =
      request_data_stream_from(0x22U, 2U, 2U, 1U);
  const MavlinkFrame stream_changed =
      request_data_stream_from(0x23U, 2U, 4U, 1U);
  const MavlinkFrame stream_changed_duplicate =
      request_data_stream_from(0x24U, 2U, 4U, 1U);
  const MavlinkFrame version_initial =
      autopilot_version_request_from(0x25U);
  const MavlinkFrame version_duplicate =
      autopilot_version_request_from(0x26U);
  const MavlinkFrame request_259 = request_message_from(
      0x27U, 259.0F, 1U, 1U);
  const MavlinkFrame request_280 = request_message_from(
      0x28U, 280.0F, 0U, 0U, MavlinkVersion::V1);
  const MavlinkFrame non_request =
      fixtures::command_long_v2(0x29U, 400U, 7.0F);
  report.check(
      policy.on_gcs_frame(stream_initial, 1U) ==
              GroundParameterProxyDisposition::Forward &&
          policy.on_gcs_frame(stream_duplicate, 2U) ==
              GroundParameterProxyDisposition::Consumed &&
          policy.on_gcs_frame(stream_changed, 3U) ==
              GroundParameterProxyDisposition::Consumed &&
          policy.on_gcs_frame(stream_changed, 30001U) ==
              GroundParameterProxyDisposition::Forward &&
          policy.on_gcs_frame(stream_changed_duplicate, 30002U) ==
              GroundParameterProxyDisposition::Consumed,
      "#66 cache miss did not arm the shared gate at an exact deadline");
  report.check(
      policy.on_gcs_frame(version_initial, 30003U) ==
              GroundParameterProxyDisposition::Forward &&
          policy.on_gcs_frame(version_duplicate, 30004U) ==
              GroundParameterProxyDisposition::Consumed,
      "#183 exact duplicate was not scoped to one active session");
  report.check(
      policy.on_gcs_frame(request_259, 30005U) ==
              GroundParameterProxyDisposition::Forward &&
          policy.on_gcs_frame(request_280, 30006U) ==
              GroundParameterProxyDisposition::Forward &&
          policy.on_gcs_frame(request_259, 30007U) ==
              GroundParameterProxyDisposition::Consumed &&
          policy.on_gcs_frame(request_280, 30008U) ==
              GroundParameterProxyDisposition::Consumed,
      "alternating REQUEST_MESSAGE identities bypassed duplicate suppression");
  report.check(
      policy.on_gcs_frame(stream_changed_duplicate, 60005U) ==
              GroundParameterProxyDisposition::Consumed &&
          policy.on_gcs_frame(version_duplicate, 60006U) ==
              GroundParameterProxyDisposition::Forward &&
          policy.on_gcs_frame(request_259, 60007U) ==
              GroundParameterProxyDisposition::Consumed,
      "#66/#183/#76 did not share one exact 30-second retry gate");
  report.check(
      policy.on_gcs_frame(non_request, 60008U) ==
              GroundParameterProxyDisposition::Forward &&
          policy.on_gcs_frame(non_request, 60009U) ==
              GroundParameterProxyDisposition::Forward,
      "non-REQUEST_MESSAGE COMMAND_LONG lost transparent forwarding");

  // REQUEST_MESSAGE-family semantic identities comprise the first 32 payload
  // bytes only. Confirmation changes and sequence/CRC changes are retries;
  // commands 511, 512, and 520 all use the same bounded cache policy.
  GroundParameterDownloadProxy command_policy{config};
  report.check(command_policy.on_gcs_frame(
                   param_request_list(0x30U), 0U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   command_policy.active(),
               "COMMAND_LONG policy fixture did not start a native session");
  const MavlinkFrame command_511 = request_message_from(
      0x31U, 259.0F, 1U, 1U, MavlinkVersion::V2, 511U, 0U);
  const MavlinkFrame command_511_confirmation = request_message_from(
      0x32U, 259.0F, 1U, 1U, MavlinkVersion::V2, 511U, 7U);
  const MavlinkFrame command_512 = request_message_from(
      0x33U, 259.0F, 1U, 1U, MavlinkVersion::V2, 512U, 0U);
  const MavlinkFrame command_512_confirmation = request_message_from(
      0x34U, 259.0F, 1U, 1U, MavlinkVersion::V2, 512U, 9U);
  const MavlinkFrame command_520 = request_message_from(
      0x35U, 259.0F, 1U, 1U, MavlinkVersion::V2, 520U, 0U);
  const MavlinkFrame command_520_confirmation = request_message_from(
      0x36U, 259.0F, 1U, 1U, MavlinkVersion::V2, 520U, 1U);
  report.check(
      std::equal(command_511.payload(), command_511.payload() + 32U,
                 command_511_confirmation.payload()) &&
          command_511.payload()[32U] !=
              command_511_confirmation.payload()[32U] &&
          command_policy.on_gcs_frame(command_511, 1U) ==
              GroundParameterProxyDisposition::Forward &&
          command_policy.on_gcs_frame(command_511_confirmation, 2U) ==
              GroundParameterProxyDisposition::Consumed &&
          command_policy.on_gcs_frame(command_512, 3U) ==
              GroundParameterProxyDisposition::Forward &&
          command_policy.on_gcs_frame(command_512_confirmation, 4U) ==
              GroundParameterProxyDisposition::Consumed &&
          command_policy.on_gcs_frame(command_520, 5U) ==
              GroundParameterProxyDisposition::Forward &&
          command_policy.on_gcs_frame(command_520_confirmation, 6U) ==
              GroundParameterProxyDisposition::Consumed &&
          command_policy.on_gcs_frame(command_520_confirmation, 30005U) ==
              GroundParameterProxyDisposition::Forward,
      "#76 commands 511/512/520 did not ignore confirmation and arm the gate");

  const MavlinkFrame wrong_sender = request_message_from(
      0x37U, 259.0F, 1U, 1U, MavlinkVersion::V2, 512U, 0U, 42U, 17U);
  const MavlinkFrame wrong_target = request_message_from(
      0x38U, 259.0F, 2U, 2U);
  const MavlinkFrame signed_request = request_message_from(
      0x39U, 259.0F, 1U, 1U, MavlinkVersion::V2, 512U, 0U,
      255U, 190U, true);
  report.check(
      command_policy.on_gcs_frame(wrong_sender, 30006U) ==
              GroundParameterProxyDisposition::Forward &&
          command_policy.on_gcs_frame(wrong_sender, 30007U) ==
              GroundParameterProxyDisposition::Forward &&
          command_policy.on_gcs_frame(wrong_target, 30008U) ==
              GroundParameterProxyDisposition::Forward &&
          command_policy.on_gcs_frame(wrong_target, 30009U) ==
              GroundParameterProxyDisposition::Forward &&
          command_policy.on_gcs_frame(signed_request, 30010U) ==
              GroundParameterProxyDisposition::Forward &&
          command_policy.on_gcs_frame(signed_request, 30011U) ==
              GroundParameterProxyDisposition::Forward,
      "wrong-sender/target or signed #76 lost transparent forwarding");

  // Both fixed eight-entry caches fail closed when full. The ninth identity
  // cannot evict an established entry or use an immediate cache-miss path;
  // it is eligible only through the already-armed shared gate.
  GroundParameterDownloadProxy request_capacity{config};
  report.check(request_capacity.on_gcs_frame(
                   param_request_list(0x40U), 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "#76 cache-capacity fixture did not start");
  bool request_cache_filled = true;
  for (std::uint8_t index = 0U; index < 8U; ++index) {
    request_cache_filled =
        request_cache_filled &&
        request_capacity.on_gcs_frame(
            request_message_from(
                static_cast<std::uint8_t>(0x41U + index),
                1000.0F + static_cast<float>(index), 1U, 1U),
            static_cast<std::uint64_t>(index + 1U)) ==
            GroundParameterProxyDisposition::Forward;
  }
  const MavlinkFrame ninth_request =
      request_message_from(0x49U, 1008.0F, 1U, 1U);
  const MavlinkFrame first_request_retry =
      request_message_from(0x4AU, 1000.0F, 1U, 1U);
  report.check(request_cache_filled &&
                   request_capacity.on_gcs_frame(ninth_request, 9U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   request_capacity.on_gcs_frame(ninth_request, 30008U) ==
                       GroundParameterProxyDisposition::Forward &&
                   request_capacity.on_gcs_frame(first_request_retry,
                                                 30009U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   request_capacity.diagnostics()
                           .background_cache_full_frames == 2U,
               "#76 cache8 overflow evicted an identity or bypassed the gate");

  GroundParameterDownloadProxy stream_capacity{config};
  report.check(stream_capacity.on_gcs_frame(
                   param_request_list(0x50U), 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "#66 cache-capacity fixture did not start");
  bool stream_cache_filled = true;
  for (std::uint8_t stream_id = 1U; stream_id <= 8U; ++stream_id) {
    stream_cache_filled =
        stream_cache_filled &&
        stream_capacity.on_gcs_frame(
            request_data_stream_from(
                static_cast<std::uint8_t>(0x50U + stream_id), stream_id,
                2U, 1U),
            stream_id) == GroundParameterProxyDisposition::Forward;
  }
  const MavlinkFrame ninth_stream =
      request_data_stream_from(0x59U, 9U, 2U, 1U);
  const MavlinkFrame first_stream_retry =
      request_data_stream_from(0x5AU, 1U, 2U, 1U);
  report.check(stream_cache_filled &&
                   stream_capacity.on_gcs_frame(ninth_stream, 9U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   stream_capacity.on_gcs_frame(ninth_stream, 30008U) ==
                       GroundParameterProxyDisposition::Forward &&
                   stream_capacity.on_gcs_frame(first_stream_retry,
                                                30009U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   stream_capacity.diagnostics()
                           .background_cache_full_frames == 2U,
               "#66 cache8 overflow evicted an identity or bypassed the gate");

  // Session boundaries are explicit cache ownership boundaries. Idle remains
  // transparent, while the first identity in each newly-started session is a
  // fresh immediate miss which arms a new gate.
  GroundParameterDownloadProxy boundaries{config};
  const MavlinkFrame boundary_request =
      request_message_from(0x60U, 280.0F, 1U, 1U);
  report.check(boundaries.on_gcs_frame(param_request_list(0x61U), 0U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   boundaries.on_gcs_frame(boundary_request, 1U) ==
                       GroundParameterProxyDisposition::Forward &&
                   boundaries.on_gcs_frame(boundary_request, 2U) ==
                       GroundParameterProxyDisposition::Consumed,
               "boundary fixture did not establish a cached #76");
  boundaries.cancel();
  report.check(boundaries.on_gcs_frame(boundary_request, 3U) ==
                       GroundParameterProxyDisposition::Forward &&
                   boundaries.on_gcs_frame(param_request_list(0x62U), 4U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   boundaries.on_gcs_frame(boundary_request, 5U) ==
                       GroundParameterProxyDisposition::Forward &&
                   boundaries.on_gcs_frame(boundary_request, 6U) ==
                       GroundParameterProxyDisposition::Consumed,
               "cancel/new-session did not release the periodic caches");
  boundaries.reset();
  report.check(boundaries.on_gcs_frame(boundary_request, 7U) ==
                       GroundParameterProxyDisposition::Forward &&
                   boundaries.on_gcs_frame(param_request_list(0x63U), 8U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   boundaries.on_gcs_frame(boundary_request, 9U) ==
                       GroundParameterProxyDisposition::Forward,
               "reset/new-session did not release the periodic caches");

  // Complete/Failed retain the session identity for a bounded terminal hold.
  // Background retries already seen by that session must remain coalesced
  // until the hold expires; otherwise Mission Planner can refill the fixed
  // ingress FIFO immediately after either terminal transition.
  GroundParameterDownloadProxyConfig terminal_config = config;
  terminal_config.terminal_hold_ms = 50U;
  terminal_config.periodic_forward_interval_ms = 10U;

  GroundParameterDownloadProxy complete_hold{terminal_config};
  const MavlinkFrame complete_list = param_request_list(0x64U);
  const MavlinkFrame complete_stream =
      request_data_stream_from(0x65U, 2U, 2U, 1U);
  report.check(complete_hold.on_gcs_frame(complete_list, 0U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   complete_hold.on_gcs_frame(complete_stream, 1U) ==
                       GroundParameterProxyDisposition::Forward,
               "complete-hold fixture did not cache active #66");
  MavlinkFrame complete_lease{};
  std::uint32_t complete_token = 0U;
  report.check(complete_hold.peek_next_request(complete_lease,
                                               complete_token) &&
                   complete_hold.complete_request_tx(
                       complete_token, TxResult::Accepted, 2U) &&
                   complete_hold.on_vehicle_frame(
                       param_value_from(0x66U, 1U, 1U, "ONLY", 1.0F,
                                        0U, 1U),
                       true, 3U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   complete_hold.state() ==
                       GroundParameterProxyState::Complete &&
                   complete_hold.on_gcs_frame(complete_stream, 12U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   complete_hold.on_gcs_frame(complete_stream, 53U) ==
                       GroundParameterProxyDisposition::Forward,
               "Complete terminal hold released cached background retries");

  GroundParameterDownloadProxy failed_hold{terminal_config};
  const MavlinkFrame failed_list = param_request_list(0x67U);
  const MavlinkFrame failed_request =
      request_message_from(0x68U, 259.0F, 1U, 1U);
  report.check(failed_hold.on_gcs_frame(failed_list, 0U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   failed_hold.on_gcs_frame(failed_request, 1U) ==
                       GroundParameterProxyDisposition::Forward,
               "failed-hold fixture did not cache active #76");
  MavlinkFrame failed_lease{};
  std::uint32_t failed_token = 0U;
  report.check(failed_hold.peek_next_request(failed_lease, failed_token) &&
                   failed_hold.complete_request_tx(
                       failed_token, TxResult::Accepted, 2U) &&
                   failed_hold.on_vehicle_frame(
                       param_value_from(0x69U, 2U, 1U, "WRONG", 1.0F,
                                        0U, 1U),
                       true, 3U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   failed_hold.state() ==
                       GroundParameterProxyState::Failed &&
                   failed_hold.on_gcs_frame(failed_request, 12U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   failed_hold.on_gcs_frame(failed_request, 53U) ==
                       GroundParameterProxyDisposition::Forward,
               "Failed terminal hold released cached background retries");

  GroundParameterDownloadProxy proxy{config};
  GroundMavlinkIngressAdapter ingress{};
  std::vector<MavlinkFrame> admitted_frames{};
  std::size_t next_frame_to_drain = 0U;
  bool overflowed = false;
  std::size_t active_background_forwarded = 0U;
  std::size_t invalid_background_frames = 0U;

  const auto admit = [&](const MavlinkFrame& frame,
                         std::uint64_t now_ms,
                         bool active_background) {
    const GroundParameterProxyDisposition disposition =
        proxy.on_gcs_frame(frame, now_ms);
    if (disposition == GroundParameterProxyDisposition::Invalid) {
      ++invalid_background_frames;
    }
    if (disposition != GroundParameterProxyDisposition::Forward) {
      return disposition;
    }
    if (active_background) {
      ++active_background_forwarded;
    }
    if (ingress.fail_closed()) {
      overflowed = true;
      return disposition;
    }
    const FrameIngressStatus status =
        ingress.admit_validated_frame(frame);
    if (status != FrameIngressStatus::Queued) {
      overflowed = true;
      return disposition;
    }
    admitted_frames.push_back(frame);
    return disposition;
  };

  const auto drain_one_frame = [&]() {
    if (ingress.fail_closed() || ingress.empty()) {
      return;
    }
    const std::size_t expected_frame_bytes =
        ingress.front_frame_remaining();
    std::array<std::uint8_t, kMavlinkMaxFrameBytes> actual{};
    std::size_t actual_bytes = 0U;
    while (!ingress.fail_closed() &&
           actual_bytes < expected_frame_bytes) {
      std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> chunk{};
      const std::size_t remaining = expected_frame_bytes - actual_bytes;
      const std::size_t chunk_size = ingress.peek(
          chunk.data(), std::min(chunk.size(), remaining));
      if (chunk_size == 0U) {
        report.check(false,
                     "R15 service model exposed an empty frame prefix");
        return;
      }
      std::copy_n(chunk.begin(), chunk_size,
                  actual.begin() + actual_bytes);
      actual_bytes += chunk_size;
      if (!ingress.complete_send(TxResult::Accepted, chunk_size)) {
        report.check(false,
                     "R15 service model could not commit a frame prefix");
        return;
      }
    }
    report.check(
        next_frame_to_drain < admitted_frames.size() &&
            actual_bytes == expected_frame_bytes &&
            actual_bytes == admitted_frames[next_frame_to_drain].size &&
            std::equal(actual.begin(), actual.begin() + actual_bytes,
                       admitted_frames[next_frame_to_drain].bytes.begin()),
        "R15 service model changed FIFO frame order or raw bytes");
    ++next_frame_to_drain;
  };

  std::uint8_t sequence = 0U;
  // Exact pre-#21 R15 admissible backlog: 14 MAVLink1 #66, four #183,
  // three MAVLink1 and six MAVLink2 GCS heartbeats (27 frames / 429 bytes).
  for (std::size_t index = 0U; index < 14U; ++index) {
    (void)admit(request_data_stream_from(
                    sequence++, 2U, 2U, 1U, MavlinkVersion::V1),
                index, false);
  }
  for (std::size_t index = 0U; index < 4U; ++index) {
    (void)admit(autopilot_version_request_from(sequence++),
                20U + index, false);
  }
  for (std::size_t index = 0U; index < 3U; ++index) {
    (void)admit(gcs_heartbeat_from(sequence++, MavlinkVersion::V1),
                30U + index, false);
  }
  for (std::size_t index = 0U; index < 6U; ++index) {
    (void)admit(gcs_heartbeat_from(sequence++, MavlinkVersion::V2),
                40U + index, false);
  }
  report.check(ingress.queued_frames() == 27U &&
                   ingress.queued_bytes() == 429U &&
                   !ingress.fail_closed(),
               "R15 pre-request backlog is not exact 27/429");

  const MavlinkFrame list = param_request_list(sequence++);
  report.check(proxy.on_gcs_frame(list, 50U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   proxy.active(),
               "R15 load model did not enter an active native session");
  MavlinkFrame leased_list{};
  std::uint32_t leased_token = 0U;
  report.check(proxy.peek_next_request(leased_list, leased_token) &&
                   leased_token != 0U && same_frame(leased_list, list) &&
                   ingress.admit_validated_frame(leased_list) ==
                       FrameIngressStatus::Queued,
               "R15 model did not append one byte-exact native #21 lease");
  admitted_frames.push_back(leased_list);

  constexpr std::size_t kServiceCycles = 354U;
  constexpr std::size_t kStreamBursts = 64U;
  constexpr std::size_t kVersionRequests = 98U;
  constexpr std::size_t kShortReadRequests = 15190U;
  constexpr std::size_t kShortRequestMessages = 325U;
  constexpr std::size_t kFullRequestMessageGroups = 65U;
  constexpr std::uint64_t kCycleMs = 6967U;
  constexpr std::array<std::uint8_t, 7U> kStreamIds{{
      2U, 6U, 10U, 11U, 12U, 1U, 3U}};
  std::size_t stream_bursts_emitted = 0U;
  std::size_t version_requests_emitted = 0U;
  std::size_t short_reads_emitted = 0U;
  std::size_t short_reads_consumed = 0U;
  std::size_t short_request_messages_emitted = 0U;
  std::size_t full_request_message_groups_emitted = 0U;

  for (std::size_t cycle = 0U; cycle < kServiceCycles; ++cycle) {
    const std::uint64_t now_ms =
        100U + static_cast<std::uint64_t>(cycle + 1U) * kCycleMs;
    const std::size_t stream_burst_goal =
        ((cycle + 1U) * kStreamBursts) / kServiceCycles;
    while (stream_bursts_emitted < stream_burst_goal) {
      for (const std::uint8_t stream_id : kStreamIds) {
        const std::uint16_t rate =
            stream_id == 10U || stream_id == 11U ? 4U : 2U;
        (void)admit(request_data_stream_from(
                        sequence++, stream_id, rate, 1U),
                    now_ms, true);
        (void)admit(request_data_stream_from(
                        sequence++, stream_id, rate, 1U),
                    now_ms + 1U, true);
      }
      ++stream_bursts_emitted;
    }

    const std::size_t version_goal =
        ((cycle + 1U) * kVersionRequests) / kServiceCycles;
    while (version_requests_emitted < version_goal) {
      (void)admit(autopilot_version_request_from(sequence++),
                  now_ms + 2U, true);
      ++version_requests_emitted;
    }

    const std::size_t short_read_goal =
        ((cycle + 1U) * kShortReadRequests) / kServiceCycles;
    while (short_reads_emitted < short_read_goal) {
      const GroundParameterProxyDisposition disposition = admit(
          short_param_request_read_from(
              sequence++, static_cast<std::uint16_t>(
                              short_reads_emitted % 932U)),
          now_ms + 3U, true);
      if (disposition == GroundParameterProxyDisposition::Consumed) {
        ++short_reads_consumed;
      }
      ++short_reads_emitted;
    }

    const std::size_t short_request_goal =
        ((cycle + 1U) * kShortRequestMessages) / kServiceCycles;
    while (short_request_messages_emitted < short_request_goal) {
      const bool broadcast =
          (short_request_messages_emitted & 1U) == 0U;
      (void)admit(short_request_message_from(
                      sequence++, broadcast ? 280.0F : 259.0F,
                      broadcast ? 0U : 1U, broadcast ? 0U : 1U),
                  now_ms + 4U, true);
      ++short_request_messages_emitted;
    }

    const std::size_t full_request_group_goal =
        ((cycle + 1U) * kFullRequestMessageGroups) / kServiceCycles;
    while (full_request_message_groups_emitted < full_request_group_goal) {
      // Remaining captured R15 #76 traffic: one MAVLink1 broadcast request
      // for message 280 followed by three MAVLink2 confirmation retries for
      // message 259. Confirmation is transport metadata and must not create
      // three semantic cache identities.
      (void)admit(request_message_from(
                      sequence++, 280.0F, 0U, 0U,
                      MavlinkVersion::V1, 512U, 0U),
                  now_ms + 5U, true);
      for (std::uint8_t confirmation = 1U; confirmation <= 3U;
           ++confirmation) {
        (void)admit(request_message_from(
                        sequence++, 259.0F, 1U, 1U,
                        MavlinkVersion::V2, 512U, confirmation),
                    now_ms + 5U + confirmation, true);
      }
      ++full_request_message_groups_emitted;
    }

    // GCS heartbeat is present at much higher cadence in R15, but the
    // existing Vehicle replacement policy must continue consuming it.
    (void)proxy.on_gcs_frame(
        gcs_heartbeat_from(sequence++, MavlinkVersion::V2), now_ms + 8U);
    drain_one_frame();
  }

  report.check(stream_bursts_emitted == kStreamBursts &&
                   version_requests_emitted == kVersionRequests &&
                   short_reads_emitted == kShortReadRequests &&
                   short_reads_consumed == kShortReadRequests &&
                    short_request_messages_emitted ==
                        kShortRequestMessages &&
                    full_request_message_groups_emitted ==
                        kFullRequestMessageGroups &&
                    invalid_background_frames == 0U,
               "R15 background fixture cardinality changed");

  // The real outage followed 182 ms after the final Vehicle heartbeat with
  // one more 14-frame #66 burst. Every command is an already-seen setting.
  const std::uint64_t terminal_ms =
      100U + static_cast<std::uint64_t>(kServiceCycles) * kCycleMs + 182U;
  for (const std::uint8_t stream_id : kStreamIds) {
    const std::uint16_t rate =
        stream_id == 10U || stream_id == 11U ? 4U : 2U;
    (void)admit(request_data_stream_from(
                    sequence++, stream_id, rate, 1U),
                terminal_ms, true);
    (void)admit(request_data_stream_from(
                    sequence++, stream_id, rate, 1U),
                terminal_ms + 1U, true);
  }

  constexpr std::size_t kImmediateCacheMissForwards =
      kStreamIds.size() + 1U + 2U;
  const std::size_t shared_gate_forward_bound =
      1U + static_cast<std::size_t>(terminal_ms / 30000U);
  report.check(!overflowed && !ingress.fail_closed() &&
                   active_background_forwarded <=
                       kImmediateCacheMissForwards +
                           shared_gate_forward_bound &&
                   ingress.stats().max_queued_bytes <= 1024U,
               "R15 periodic background load exceeded the fixed ingress "
               "service envelope");

  if (!ingress.fail_closed()) {
    while (!ingress.empty()) {
      drain_one_frame();
    }
    report.check(next_frame_to_drain == admitted_frames.size() &&
                     ingress.stats().frames_dequeued ==
                         admitted_frames.size() &&
                     ingress.stats().overflow_events == 0U,
                 "bounded R15 backlog did not drain FIFO-exactly");
  }

  report.detail =
      "R15-equivalent active background forwarded=" +
      std::to_string(active_background_forwarded) +
      ", max_ingress_bytes=" +
      std::to_string(ingress.stats().max_queued_bytes) +
      ", overflow_events=" +
      std::to_string(ingress.stats().overflow_events) +
      ", invalid_background=" +
      std::to_string(invalid_background_frames) +
      "; included short#20=15190/short#76=325/full#76=260 and preserved "
      "idle/Indexed/critical-command transparency.";
}

void check_admission_watchdog(TestReport& report) {
  GroundParameterDownloadProxyConfig config = fast_config();
  config.value_timeout_ms = 100U;
  config.terminal_hold_ms = 1000U;
  GroundParameterDownloadProxy proxy{config};
  const RequestLease lease = start_list(proxy, 0U, report, 0x71U);
  GroundMavlinkIngressAdapter ingress{};
  report.check(ingress.admit_validated_frame(lease.frame) ==
                       FrameIngressStatus::Queued &&
                   proxy.mark_request_admitted(lease.token, 0U),
               "watchdog fixture did not admit the generated #20 lease");
  const std::size_t queued_before_timeout = ingress.queued_frames();
  proxy.tick(config.value_timeout_ms - 1U);
  report.check(proxy.state() == GroundParameterProxyState::Ready,
               "generated #20 admission watchdog expired before boundary");

  proxy.tick(config.value_timeout_ms);
  MavlinkFrame duplicate{};
  std::uint32_t duplicate_token = 0U;
  report.check(proxy.state() == GroundParameterProxyState::Failed &&
                   !proxy.active() &&
                   !proxy.peek_next_request(duplicate, duplicate_token) &&
                   ingress.stats().frames_dequeued == 0U &&
                   ingress.queued_frames() == queued_before_timeout &&
                   proxy.diagnostics().request_commit_timeouts == 1U,
               "stalled generated #20 did not fail/release its logical lease "
               "without duplicating the immutable FIFO frame");
  proxy.tick(1500U);
  report.check(proxy.on_gcs_frame(param_request_list(0x72U), 1500U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   !proxy.active() &&
                   !proxy.peek_next_request(duplicate, duplicate_token) &&
                   !proxy.complete_request_tx(lease.token,
                                              TxResult::Accepted,
                                              1501U) &&
                   proxy.state() == GroundParameterProxyState::Failed &&
                   proxy.diagnostics().requests_generated == 1U &&
                   proxy.diagnostics().request_tx_accepted == 0U,
               "late dequeue completion re-armed or duplicated a timed-out "
               "generated #20 lease");
  report.check(proxy.on_gcs_frame(param_request_list(0x73U), 2000U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   !proxy.active() &&
                   !proxy.peek_next_request(duplicate, duplicate_token),
               "late dequeue callback released the fail-close tombstone");

  GroundParameterDownloadProxy done_wait_proxy{config};
  const RequestLease done_wait =
      start_list(done_wait_proxy, 0U, report, 0x74U);
  report.check(done_wait_proxy.mark_request_admitted(done_wait.token, 0U) &&
                   done_wait_proxy.mark_request_dequeued(
                       done_wait.token, config.value_timeout_ms),
               "deadline-boundary dequeue progress was not admitted first");
  done_wait_proxy.tick(config.value_timeout_ms);
  done_wait_proxy.tick(config.value_timeout_ms * 2U - 1U);
  report.check(done_wait_proxy.state() ==
                   GroundParameterProxyState::Ready,
               "explicit-DONE watchdog expired before its re-armed boundary");
  done_wait_proxy.tick(config.value_timeout_ms * 2U);
  report.check(done_wait_proxy.state() ==
                       GroundParameterProxyState::Failed &&
                   done_wait_proxy.diagnostics().request_dequeues_observed ==
                       1U &&
                   done_wait_proxy.diagnostics().request_commit_timeouts ==
                       1U &&
                   !done_wait_proxy.peek_next_request(duplicate,
                                                      duplicate_token),
               "dequeued #20 without explicit UL_DONE was not bounded and "
               "failed exactly once");

  GroundParameterDownloadProxy exact_done_proxy{config};
  const RequestLease exact_done =
      start_list(exact_done_proxy, 0U, report, 0x76U);
  report.check(exact_done_proxy.mark_request_admitted(exact_done.token, 0U) &&
                   exact_done_proxy.mark_request_dequeued(
                       exact_done.token, config.value_timeout_ms),
               "exact-DONE deadline fixture did not enter stage two");
  const std::uint64_t exact_done_deadline =
      static_cast<std::uint64_t>(config.value_timeout_ms) * 2U;
  report.check(exact_done_proxy.complete_request_tx(
                   exact_done.token, TxResult::Accepted,
                   exact_done_deadline),
               "visible UL_DONE was not completed at the inclusive deadline");
  exact_done_proxy.tick(exact_done_deadline);
  report.check(exact_done_proxy.state() ==
                       GroundParameterProxyState::AwaitingValue &&
                   exact_done_proxy.diagnostics().request_tx_accepted == 1U &&
                   exact_done_proxy.diagnostics().request_commit_timeouts ==
                       0U,
               "completion-before-tick false-failed at the exact DONE "
               "deadline");

  GroundParameterDownloadProxy late_progress_proxy{config};
  const RequestLease late_progress =
      start_list(late_progress_proxy, 0U, report, 0x75U);
  report.check(late_progress_proxy.mark_request_admitted(
                   late_progress.token, 0U) &&
                   !late_progress_proxy.mark_request_dequeued(
                       late_progress.token, config.value_timeout_ms + 1U) &&
                   late_progress_proxy.state() ==
                       GroundParameterProxyState::Failed &&
                   late_progress_proxy.request_admission_abandoned(
                       late_progress.token) &&
                   late_progress_proxy.diagnostics().request_commit_timeouts ==
                       1U,
               "late descriptor progress bypassed the fixed admission bound");
  report.detail =
      "Generated #20 admission made no frames_dequeued progress: fixed "
      "watchdog failed the session; deadline-boundary dequeue re-armed one "
      "bounded UL_DONE stage, and neither path admitted a duplicate.";
}

void check_mission_planner_startup_backlog(TestReport& report) {
  GroundParameterDownloadProxyConfig config = fast_config();
  config.list_strategy = GroundParameterListStrategy::NativeStream;
  config.value_timeout_ms = 100U;
  config.terminal_hold_ms = 1000U;
  GroundParameterDownloadProxy proxy{config};
  GroundMavlinkIngressAdapter ingress{};

  // The first product Mission Planner capture placed 50 frames / 1,033
  // MAVLink bytes ahead of #21. Message identity is irrelevant to FIFO
  // service, so use an equivalent all-valid fixture: 47 x 21-byte HEARTBEAT,
  // 2 x 14-byte AUTOPILOT_VERSION_REQUEST, and 1 x 18-byte
  // REQUEST_DATA_STREAM.
  constexpr std::size_t kStartupFrames = 50U;
  constexpr std::size_t kStartupBytes = 1033U;
  std::size_t startup_bytes = 0U;
  for (std::size_t index = 0U; index < kStartupFrames; ++index) {
    MavlinkFrame frame{};
    if (index < 47U) {
      frame = fixtures::heartbeat_v2(static_cast<std::uint8_t>(index),
                                     255U, 190U);
    } else if (index < 49U) {
      const std::array<std::uint8_t, 2U> payload{{1U, 1U}};
      (void)encode_mavlink_v2(static_cast<std::uint8_t>(index), 255U,
                              190U, 183U, payload.data(), payload.size(),
                              frame);
    } else {
      const std::array<std::uint8_t, 6U> payload{{1U, 1U, 1U, 1U, 1U, 1U}};
      (void)encode_mavlink_v2(static_cast<std::uint8_t>(index), 255U,
                              190U, 66U, payload.data(), payload.size(),
                              frame);
    }
    startup_bytes += frame.size;
    report.check(ingress.admit_validated_frame(frame) ==
                     FrameIngressStatus::Queued,
                 "Mission Planner startup fixture was not queued atomically");
  }
  report.check(ingress.queued_frames() == kStartupFrames &&
                   ingress.queued_bytes() == kStartupBytes &&
                   startup_bytes == kStartupBytes,
               "Mission Planner startup fixture is not exactly 50/1033");

  const MavlinkFrame list = param_request_list(0x50U);
  report.check(proxy.on_gcs_frame(list, 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "Mission Planner #21 did not start a native stream");
  MavlinkFrame leased{};
  std::uint32_t token = 0U;
  report.check(proxy.peek_next_request(leased, token) && token != 0U &&
                   same_frame(leased, list) &&
                   ingress.admit_validated_frame(leased) ==
                       FrameIngressStatus::Queued &&
                   proxy.mark_request_admitted(token, 0U),
               "native #21 was not appended as one byte-exact FIFO lease");
  const std::uint64_t dequeue_goal =
      ingress.stats().frames_dequeued + ingress.queued_frames();
  report.check(dequeue_goal == kStartupFrames + 1U,
               "native #21 dequeue goal did not include the startup backlog");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> application{};
  std::uint64_t now_ms = 0U;
  for (std::size_t index = 0U; index < kStartupFrames; ++index) {
    const std::size_t front_size = ingress.front_frame_remaining();
    const std::size_t frame_size =
        ingress.peek(application.data(), front_size);
    MavlinkFrame front{};
    report.check(frame_size > 0U &&
                     validate_mavlink_frame(application.data(), frame_size,
                                            front) ==
                         MavlinkParseStatus::FrameReady &&
                     front.message_id != 21U &&
                     ingress.complete_send(TxResult::Accepted, frame_size),
                 "startup FIFO did not retire one complete preceding frame");
    now_ms += 90U;
    report.check(proxy.mark_request_queue_progress(token, now_ms),
                 "physical FIFO progress did not refresh the wait stage");
    proxy.tick(now_ms);
    report.check(proxy.state() == GroundParameterProxyState::Ready &&
                     !proxy.native_stream_poisoned() &&
                     proxy.diagnostics().request_commit_timeouts == 0U,
                 "advancing startup FIFO falsely expired the #21 lease");

    if ((index + 1U) % 10U == 0U) {
      const MavlinkFrame duplicate = param_request_list(
          static_cast<std::uint8_t>(0x50U + (index + 1U) / 10U));
      report.check(proxy.on_gcs_frame(duplicate, now_ms) ==
                       GroundParameterProxyDisposition::Consumed,
                   "Mission Planner repeated #21 was not coalesced");
    }
  }
  report.check(now_ms > config.value_timeout_ms &&
                   proxy.diagnostics().request_queue_progress_observed ==
                       kStartupFrames &&
                   proxy.diagnostics().list_requests_coalesced == 5U &&
                   ingress.stats().frames_dequeued == kStartupFrames,
               "long startup drain changed lease identity or progress accounting");

  MavlinkFrame retained{};
  std::uint32_t retained_token = 0U;
  const std::size_t request_front_size = ingress.front_frame_remaining();
  const std::size_t request_size =
      ingress.peek(application.data(), request_front_size);
  report.check(proxy.peek_next_request(retained, retained_token) &&
                   retained_token == token && same_frame(retained, list) &&
                   request_size == list.size &&
                   std::equal(application.begin(),
                              application.begin() + request_size,
                              list.bytes.begin()) &&
                   ingress.complete_send(TxResult::Accepted, request_size),
               "startup drain did not expose the original #21 exactly once");
  now_ms += 90U;
  report.check(ingress.stats().frames_dequeued == dequeue_goal &&
                   proxy.mark_request_dequeued(token, now_ms) &&
                   proxy.complete_request_tx(token, TxResult::Accepted,
                                             now_ms + 1U) &&
                   proxy.state() ==
                       GroundParameterProxyState::AwaitingValue,
               "#21 did not cross dequeue and explicit-DONE after the backlog");

  const MavlinkFrame first_value =
      param_value_from(0x51U, 1U, 1U, "FIRST", 1.0F, 0U, 932U);
  report.check(proxy.on_vehicle_frame(first_value, true, now_ms + 2U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   proxy.expected_index() == 1U &&
                   proxy.diagnostics().matching_values_usb_queued == 1U &&
                   proxy.diagnostics().request_tx_accepted == 1U &&
                   proxy.diagnostics().request_dequeues_observed == 1U,
               "first PARAM_VALUE did not follow the repaired startup path");

  GroundParameterDownloadProxy stalled{config};
  const MavlinkFrame stalled_list = param_request_list(0x70U);
  MavlinkFrame stalled_lease{};
  std::uint32_t stalled_token = 0U;
  report.check(stalled.on_gcs_frame(stalled_list, 0U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   stalled.peek_next_request(stalled_lease, stalled_token) &&
                   stalled.mark_request_admitted(stalled_token, 0U),
               "no-progress watchdog fixture did not start");
  stalled.tick(config.value_timeout_ms);
  report.check(stalled.state() == GroundParameterProxyState::Failed &&
                   stalled.native_stream_poisoned() &&
                   stalled.request_admission_abandoned(stalled_token) &&
                   stalled.diagnostics().request_queue_progress_observed == 0U &&
                   stalled.diagnostics().request_commit_timeouts == 1U,
               "repair removed the bounded no-progress fail-close");

  GroundParameterDownloadProxy boundary{config};
  const MavlinkFrame boundary_list = param_request_list(0x71U);
  MavlinkFrame boundary_lease{};
  std::uint32_t boundary_token = 0U;
  report.check(boundary.on_gcs_frame(boundary_list, 0U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   boundary.peek_next_request(boundary_lease,
                                              boundary_token) &&
                   boundary.mark_request_admitted(boundary_token, 0U) &&
                   boundary.mark_request_queue_progress(
                       boundary_token, config.value_timeout_ms),
               "exact-boundary FIFO progress was not observed before tick");
  boundary.tick(config.value_timeout_ms);
  boundary.tick(config.value_timeout_ms * 2U - 1U);
  report.check(boundary.state() == GroundParameterProxyState::Ready &&
                   boundary.diagnostics().request_queue_progress_observed ==
                       1U &&
                   boundary.diagnostics().request_commit_timeouts == 0U,
               "one progress event did not create one bounded wait stage");
  boundary.tick(config.value_timeout_ms * 2U);
  boundary.tick(config.value_timeout_ms * 3U);
  report.check(boundary.state() == GroundParameterProxyState::Failed &&
                   boundary.native_stream_poisoned() &&
                   boundary.request_admission_abandoned(boundary_token) &&
                   boundary.diagnostics().request_queue_progress_observed ==
                       1U &&
                   boundary.diagnostics().request_commit_timeouts == 1U,
               "progress refresh disabled or duplicated the no-progress timeout");

  GroundParameterDownloadProxy cancelled{config};
  const MavlinkFrame cancelled_list = param_request_list(0x72U);
  MavlinkFrame cancelled_lease{};
  std::uint32_t cancelled_token = 0U;
  const MavlinkFrame parameter_set =
      fixtures::param_set_v2(0x73U, "CANCEL", 2.0F);
  report.check(cancelled.on_gcs_frame(cancelled_list, 0U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   cancelled.peek_next_request(cancelled_lease,
                                               cancelled_token) &&
                   cancelled.mark_request_admitted(cancelled_token, 0U) &&
                   cancelled.on_gcs_frame(parameter_set, 10U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   cancelled.state() == GroundParameterProxyState::Failed &&
                   cancelled.native_stream_poisoned(),
               "PARAM_SET did not cancel the immutable admitted #21 lease");
  report.check(cancelled.mark_request_queue_progress(
                   cancelled_token, config.value_timeout_ms) &&
                   cancelled.mark_request_dequeued(
                       cancelled_token, config.value_timeout_ms * 2U) &&
                   !cancelled.mark_request_queue_progress(
                       cancelled_token, config.value_timeout_ms * 2U),
               "cancelled lease did not transition from FIFO wait to DONE wait");
  report.check(!cancelled.complete_request_tx(
                   cancelled_token, TxResult::Accepted,
                   config.value_timeout_ms * 2U + 1U) &&
                   !cancelled.request_admission_abandoned(cancelled_token) &&
                   cancelled.diagnostics().request_commit_timeouts == 0U &&
                   cancelled.diagnostics().stale_request_dequeues_observed ==
                       1U &&
                   cancelled.diagnostics().stale_completions == 1U,
               "cancelled drain did not close as one bounded stale completion");
  cancelled.tick(config.value_timeout_ms * 4U);
  report.check(cancelled.diagnostics().request_commit_timeouts == 0U,
               "completed cancelled drain left a live admission watchdog");

  report.detail =
      "An exact 50-frame/1,033-byte startup FIFO drained for 4.5 seconds "
      "under a 100 ms no-progress bound; #21 remained byte-exact and crossed "
      "dequeue/DONE once, while stalled waits still failed once at boundary.";
}

template <typename Input, typename = void>
struct HasFrontFrameBytes : std::false_type {};

template <typename Input>
struct HasFrontFrameBytes<
    Input, std::void_t<decltype(std::declval<Input&>().front_frame_bytes)>>
    : std::true_type {};

template <typename Input>
void set_front_frame_bytes(Input& input, std::uint16_t bytes) noexcept {
  if constexpr (HasFrontFrameBytes<Input>::value) {
    input.front_frame_bytes = bytes;
  } else {
    (void)input;
    (void)bytes;
  }
}

template <typename Ingress, typename = void>
struct HasFrontFrameWireBytes : std::false_type {};

template <typename Ingress>
struct HasFrontFrameWireBytes<
    Ingress,
    std::void_t<decltype(
        std::declval<const Ingress&>().front_frame_wire_bytes())>>
    : std::true_type {};

template <typename Ingress>
std::uint16_t front_frame_wire_bytes_or_next_write(
    const Ingress& ingress, std::size_t next_write_bytes) noexcept {
  if constexpr (HasFrontFrameWireBytes<Ingress>::value) {
    return ingress.front_frame_wire_bytes();
  }
  (void)ingress;
  return static_cast<std::uint16_t>(next_write_bytes);
}

struct V2GroundTransaction {
  std::array<std::uint8_t, 64U> application{};
  std::size_t application_size{0U};
  TddControlMessage terminal{};
  std::size_t terminal_wire_size{0U};
  bool terminal_issued{false};
  bool data_issued{false};
};

V2GroundTransaction run_v2_ground_transaction(
    GroundMavlinkIngressAdapter& ingress, std::uint16_t cycle,
    TestReport& report) {
  TddConfig config{};
  config.uplink_guard_ms = 0U;
  config.uplink_window_ms = 300U;
  config.aux_stable_ms = 0U;
  config.min_tx_gap_ms = 180U;
  LinkDiagnostics diagnostics{};
  GroundTddController ground{config, diagnostics};
  ground.reset(0U);

  TddControlMessage grant{};
  grant.version = kTddProtocolVersion;
  grant.type = ControlType::UlGrant;
  grant.session_id = 0x7102U;
  grant.cycle_id = cycle;
  grant.guard_ms = 0U;
  grant.window_ms = 300U;
  grant.max_bytes = 64U;
  report.check(ground.on_control(grant, 0U) ==
                   ControlDisposition::Accepted,
               "frame-boundary fixture did not accept its v2 grant");

  V2GroundTransaction result{};
  for (std::uint64_t now_ms = 0U; now_ms < 1'000U; ++now_ms) {
    TddInput input{};
    input.now_ms = now_ms;
    input.aux_high = true;
    input.radio_tx_empty = true;
    input.local_tx_empty = true;
    input.queued_bytes = static_cast<std::uint32_t>(ingress.queued_bytes());
    set_front_frame_bytes(
        input, static_cast<std::uint16_t>(ingress.front_frame_remaining()));

    if (ground.has_valid_grant() && input.queued_bytes > 0U) {
      const std::size_t transaction_limit =
          ground.transaction_target_bytes() > 0U
              ? ground.transaction_target_bytes()
              : ground.granted_bytes();
      const std::size_t remaining =
          ground.actual_bytes() < transaction_limit
              ? static_cast<std::size_t>(transaction_limit -
                                         ground.actual_bytes())
              : 0U;
      const std::size_t preview_limit = std::min<std::size_t>(
          {ingress.front_frame_remaining(), kEmbeddedPhysicalWriteBytes,
           remaining});
      if (preview_limit > 0U) {
        std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> preview{};
        const std::size_t preview_size =
            ingress.peek(preview.data(), preview_limit);
        const EncodedLinkDataChunk encoded = encode_link_data(
            preview.data(), preview_size, kEmbeddedPhysicalWriteBytes);
        input.next_tx_application_bytes =
            static_cast<std::uint16_t>(encoded.input_consumed);
        input.next_tx_wire_bytes = front_frame_wire_bytes_or_next_write(
            ingress, encoded.wire_size);
      }
    }

    const LinkAction action = ground.tick(input);
    if (action.type == LinkActionType::SendRadioData) {
      result.data_issued = true;
      std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> application{};
      const std::size_t available = ingress.peek(
          application.data(),
          std::min<std::size_t>(application.size(), action.byte_budget));
      const EncodedLinkDataChunk encoded = encode_link_data(
          application.data(), available, kEmbeddedPhysicalWriteBytes);
      report.check(encoded.input_consumed > 0U &&
                       result.application_size + encoded.input_consumed <=
                           result.application.size(),
                   "frame-boundary transaction made invalid data progress");
      if (encoded.input_consumed == 0U ||
          result.application_size + encoded.input_consumed >
              result.application.size()) {
        break;
      }
      std::copy_n(application.data(), encoded.input_consumed,
                  result.application.data() + result.application_size);
      result.application_size += encoded.input_consumed;
      report.check(ingress.complete_send(TxResult::Accepted,
                                         encoded.input_consumed),
                   "frame-boundary ingress rejected an accepted prefix");
      ground.complete_action(action.token, TxResult::Accepted, now_ms,
                             static_cast<std::uint16_t>(
                                 encoded.input_consumed));
      continue;
    }

    if (action.type == LinkActionType::SendDone) {
      result.terminal = action.control;
      result.terminal_issued = true;
      std::array<std::uint8_t, kTddControlFrameSize> wire{};
      report.check(encode_control(result.terminal, wire.data(), wire.size(),
                                  result.terminal_wire_size),
                   "frame-boundary terminal did not encode");
      ground.complete_action(action.token, TxResult::Accepted, now_ms);
      break;
    }
  }
  return result;
}

void check_vehicle_transaction_commit(const V2GroundTransaction& transaction,
                                      const MavlinkFrame& expected,
                                      std::uint16_t cycle,
                                      TestReport& report) {
  VehicleLateUplinkRecovery recovery{};
  recovery.begin(0x7102U, cycle);
  for (std::size_t index = 0U; index < transaction.application_size; ++index) {
    (void)recovery.ingest(transaction.application[index]);
  }
  report.check(recovery.on_terminal(transaction.terminal) ==
                   LateUplinkTerminalStatus::Ready,
               "Vehicle rejected a supposedly complete frame transaction");
  std::array<std::uint8_t, 64U> committed{};
  std::size_t committed_size = 0U;
  std::uint16_t committed_frames = 0U;
  report.check(recovery.take_commit(committed.data(), committed.size(),
                                    committed_size, committed_frames),
               "Vehicle did not expose the DONE-confirmed atomic commit");
  report.check(committed_size == expected.size && committed_frames == 1U &&
                   std::equal(committed.begin(),
                              committed.begin() + committed_size,
                              expected.bytes.begin()),
               "Vehicle atomic commit was partial, combined, or reordered");
}

void check_v2_ground_frame_boundary(TestReport& report) {
  std::array<std::uint8_t, 33U> command_payload{};
  command_payload[28U] = 1U;
  command_payload[29U] = 1U;
  MavlinkFrame command{};
  report.check(encode_mavlink_v2(0x91U, 255U, 190U, 76U,
                                 command_payload.data(),
                                 command_payload.size(), command) &&
                   command.size == 45U,
               "frame-boundary #76 fixture is not exactly 45 bytes");

  GroundParameterDownloadProxy proxy{fast_config()};
  const RequestLease generated = start_list(proxy, 0U, report, 0x92U);
  report.check(generated.frame.message_id == 20U &&
                   generated.frame.size == 32U,
               "proxy did not generate an exact 32-byte #20 fixture");

  GroundMavlinkIngressAdapter ingress{};
  report.check(ingress.admit_validated_frame(command) ==
                       FrameIngressStatus::Queued &&
                   ingress.admit_validated_frame(generated.frame) ==
                       FrameIngressStatus::Queued &&
                   ingress.queued_bytes() == 77U &&
                   ingress.front_frame_remaining() == 45U,
               "45-byte #76 plus generated #20 did not queue atomically");

  const V2GroundTransaction first =
      run_v2_ground_transaction(ingress, 1U, report);
  report.check(first.data_issued && first.terminal_issued &&
                   first.application_size == command.size &&
                   first.terminal.version == 2U &&
                   first.terminal.type == ControlType::UlDone &&
                   first.terminal.actual_bytes == command.size &&
                   first.terminal_wire_size == kTddControlFrameSize,
               "first v2 grant crossed into #20 or omitted explicit UL_DONE");
  report.check(ingress.queued_frames() == 1U &&
                   ingress.queued_bytes() == generated.frame.size &&
                   ingress.front_frame_remaining() == generated.frame.size,
               "first UL_DONE consumed a partial prefix of generated #20");
  check_vehicle_transaction_commit(first, command, 1U, report);

  const V2GroundTransaction second =
      run_v2_ground_transaction(ingress, 2U, report);
  report.check(second.data_issued && second.terminal_issued &&
                   second.application_size == generated.frame.size &&
                   second.terminal.version == 2U &&
                   second.terminal.type == ControlType::UlDone &&
                   second.terminal.actual_bytes == generated.frame.size &&
                   second.terminal_wire_size == kTddControlFrameSize,
               "second v2 grant did not carry exact #20 plus explicit DONE");
  report.check(ingress.empty() && ingress.queued_frames() == 0U &&
                   ingress.stats().frames_dequeued == 2U,
               "two explicit-DONE cycles did not dequeue exactly two frames");
  check_vehicle_transaction_commit(second, generated.frame, 2U, report);

  std::array<std::uint8_t, 33U> escaped_payload{};
  escaped_payload.fill(kLinkDataControlLeadByte);
  MavlinkFrame escape_heavy{};
  report.check(encode_mavlink_v2(0x94U, 255U, 190U, 76U,
                                 escaped_payload.data(),
                                 escaped_payload.size(), escape_heavy) &&
                   escape_heavy.size == 45U,
               "escape-heavy #76 fixture is not exactly 45 bytes");
  GroundMavlinkIngressAdapter escape_ingress{};
  report.check(escape_ingress.admit_validated_frame(escape_heavy) ==
                       FrameIngressStatus::Queued &&
                   escape_ingress.front_frame_wire_bytes() == 96U,
               "escape-heavy frame did not require exactly three writes");
  const V2GroundTransaction escape_blocked =
      run_v2_ground_transaction(escape_ingress, 3U, report);
  report.check(!escape_blocked.data_issued &&
                   escape_blocked.application_size == 0U &&
                   escape_blocked.terminal_issued &&
                   escape_blocked.terminal.version == 2U &&
                   escape_blocked.terminal.type == ControlType::UlIdle &&
                   escape_blocked.terminal.actual_bytes == 0U &&
                   escape_ingress.queued_bytes() == escape_heavy.size &&
                   escape_ingress.front_frame_remaining() ==
                       escape_heavy.size,
               "escape-heavy front frame began without a whole-frame "
               "production-window fit proof");

  std::array<std::uint8_t, 54U> status_payload{};
  MavlinkFrame oversized{};
  report.check(encode_mavlink_v2(0x93U, 255U, 190U, 253U,
                                 status_payload.data(), status_payload.size(),
                                 oversized) &&
                   oversized.size > 64U,
               "oversized front-frame fixture does not exceed one grant");
  GroundMavlinkIngressAdapter oversized_ingress{};
  report.check(oversized_ingress.admit_validated_frame(oversized) ==
                   FrameIngressStatus::Queued,
               "oversized complete frame did not enter the test FIFO");
  const V2GroundTransaction blocked =
      run_v2_ground_transaction(oversized_ingress, 4U, report);
  report.check(!blocked.data_issued && blocked.application_size == 0U &&
                   blocked.terminal_issued &&
                   blocked.terminal.version == 2U &&
                   blocked.terminal.type == ControlType::UlIdle &&
                   blocked.terminal.actual_bytes == 0U &&
                   blocked.terminal_wire_size == kTddControlFrameSize &&
                   oversized_ingress.queued_bytes() == oversized.size &&
                   oversized_ingress.front_frame_remaining() ==
                       oversized.size,
               "front frame larger than the grant leaked a partial prefix");
  report.check(HasFrontFrameBytes<TddInput>::value,
               "TddInput lacks a complete-front-frame transaction hint");
}

void check_tdd_v2_transport(TestReport& report) {
  check_v2_ground_frame_boundary(report);
  report.check(kTddProtocolVersion == 2U,
               "Ground-owned proxy transport is not explicit-DONE v2");
  const auto obsolete_ack = static_cast<ControlType>(5U);
  report.check(!valid_control_type(obsolete_ack),
               "obsolete remote parameter ACK opcode was added");
  TddControlMessage invalid{};
  invalid.version = kTddProtocolVersion;
  invalid.type = obsolete_ack;
  std::array<std::uint8_t, kTddControlFrameSize> wire{};
  std::size_t wire_size = 99U;
  report.check(!encode_control(invalid, wire.data(), wire.size(), wire_size) &&
                   wire_size == 0U,
               "protocol v2 encoded an unneeded DlParamAck control");

  TddControlMessage grant{};
  grant.version = kTddProtocolVersion;
  grant.type = ControlType::UlGrant;
  grant.session_id = 0x5102U;
  grant.cycle_id = 19U;
  grant.guard_ms = 650U;
  grant.window_ms = 300U;
  grant.max_bytes = 64U;
  wire_size = 0U;
  report.check(encode_control(grant, wire.data(), wire.size(), wire_size) &&
                   wire_size == kTddControlFrameSize,
                "existing v2 UL_GRANT no longer encoded to 32 bytes");
  const DecodeEvent decoded = decode_control(wire.data(), wire_size);
  report.check(decoded.status == DecodeStatus::Message &&
                   decoded.message.type == ControlType::UlGrant &&
                   decoded.message.session_id == grant.session_id &&
                   decoded.message.cycle_id == grant.cycle_id &&
                   decoded.message.guard_ms == grant.guard_ms &&
                   decoded.message.window_ms == grant.window_ms &&
                   decoded.message.max_bytes == grant.max_bytes,
                 "existing v2 UL_GRANT round-trip changed");

  // Mirror the production Ground admission/dequeue-goal ordering. Select a
  // deterministic generated sequence whose 32-byte #20 contains at least one
  // link-data reserved byte, forcing a multi-chunk physical write.
  std::array<std::uint8_t, 20U> request_payload{};
  request_payload[2] = 1U;
  request_payload[3] = 1U;
  std::uint8_t list_sequence = 0U;
  bool escape_sequence_found = false;
  for (std::uint16_t sequence = 0U; sequence <= 255U; ++sequence) {
    MavlinkFrame candidate{};
    (void)encode_mavlink_v2(
        static_cast<std::uint8_t>(sequence), 255U,
        GroundParameterDownloadProxy::generated_component_id(), 20U,
        request_payload.data(), request_payload.size(), candidate);
    const EncodedLinkDataChunk candidate_chunk = encode_link_data(
        candidate.bytes.data(), candidate.size,
        kEmbeddedPhysicalWriteBytes);
    if (candidate_chunk.input_consumed < candidate.size) {
      list_sequence = static_cast<std::uint8_t>(sequence - 1U);
      escape_sequence_found = true;
      break;
    }
  }
  report.check(escape_sequence_found,
               "no escaped generated #20 sequence fixture was found");
  GroundParameterDownloadProxyConfig config = fast_config();
  config.value_timeout_ms = 100U;
  GroundParameterDownloadProxy proxy{config};
  const RequestLease lease = start_list(proxy, 0U, report, list_sequence);
  GroundMavlinkIngressAdapter ingress{};
  const MavlinkFrame ahead = fixtures::heartbeat_v2(10U, 255U, 190U);
  report.check(ingress.admit_validated_frame(ahead) ==
                       FrameIngressStatus::Queued &&
                   ingress.admit_validated_frame(lease.frame) ==
                       FrameIngressStatus::Queued &&
                   proxy.mark_request_admitted(lease.token, 0U),
               "production-order ingress fixtures did not queue atomically");
  const std::uint64_t dequeue_goal =
      ingress.stats().frames_dequeued + ingress.queued_frames();
  std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> application{};
  std::size_t application_size =
      ingress.peek(application.data(), ahead.size);
  report.check(application_size == ahead.size &&
                   !ingress.complete_send(TxResult::Rejected,
                                          application_size) &&
                   ingress.stats().frames_dequeued == 0U,
               "rejected frame ahead changed dequeue progress");
  report.check(ingress.complete_send(TxResult::Accepted,
                                     application_size) &&
                   ingress.stats().frames_dequeued == 1U &&
                   ingress.stats().frames_dequeued < dequeue_goal,
               "frame ahead did not preserve generated-request goal");
  proxy.tick(99U);
  report.check(proxy.state() == GroundParameterProxyState::Ready,
                "admission watchdog expired before its fixed boundary");

  application_size = ingress.peek(application.data(), application.size());
  const EncodedLinkDataChunk first_chunk =
      encode_link_data(application.data(), application_size,
                       kEmbeddedPhysicalWriteBytes);
  report.check(application_size == lease.frame.size &&
                   first_chunk.input_consumed > 0U &&
                   first_chunk.input_consumed < application_size,
               "escape fixture did not split the 32-byte request");
  report.check(!ingress.complete_send(TxResult::Rejected,
                                      first_chunk.input_consumed) &&
                   ingress.stats().frames_dequeued == 1U,
               "rejected generated chunk consumed request bytes");
  report.check(ingress.complete_send(TxResult::Accepted,
                                     first_chunk.input_consumed) &&
                   ingress.stats().frames_dequeued == 1U &&
                   ingress.stats().frames_dequeued < dequeue_goal,
               "partial Accepted incorrectly completed generated frame");
  application_size = ingress.peek(application.data(), application.size());
  const EncodedLinkDataChunk second_chunk =
      encode_link_data(application.data(), application_size,
                       kEmbeddedPhysicalWriteBytes);
  report.check(second_chunk.input_consumed == application_size &&
                   ingress.complete_send(TxResult::Accepted,
                                          second_chunk.input_consumed) &&
                   ingress.stats().frames_dequeued == dequeue_goal,
               "final escaped suffix did not reach exact dequeue goal");
  report.check(proxy.mark_request_dequeued(lease.token, 99U) &&
                   proxy.state() == GroundParameterProxyState::Ready,
               "exact generated #20 dequeue did not enter DONE-wait stage");
  report.check(proxy.complete_request_tx(lease.token, TxResult::Accepted,
                                         100U) &&
                   proxy.state() ==
                        GroundParameterProxyState::AwaitingValue &&
                   !proxy.complete_request_tx(lease.token,
                                              TxResult::Accepted, 101U),
                "explicit-DONE completion did not consume request token once");

  const std::filesystem::path bridge_path =
      std::filesystem::path("firmware") / "phase6" /
      "vc_lora_phase6_bridge.hpp";
  std::ifstream bridge_input(bridge_path, std::ios::binary);
  const std::string bridge_source{
      std::istreambuf_iterator<char>(bridge_input),
      std::istreambuf_iterator<char>()};
  const std::size_t ground_receive = bridge_source.find(
      "ground_radio_application_parser.push");
  const std::size_t ground_frame_ready = bridge_source.find(
      "if (parse_status == MavlinkParseStatus::FrameReady)",
      ground_receive);
  const std::size_t validated_handler_call = bridge_source.find(
      "handle_ground_validated_frame(frame, now_ms)", ground_frame_ready);
  const std::size_t validated_handler = bridge_source.find(
      "void handle_ground_validated_frame");
  const std::size_t preclassify = bridge_source.find(
      "preclassify_vehicle_frame", validated_handler);
  const std::size_t ordered_admission = bridge_source.find(
      "ground_usb_ordered_backlog.enqueue", preclassify);
  const std::size_t usb_admission = bridge_source.find(
      "radio_application_endpoint.admit_validated_frame(frame)",
      preclassify);
  const std::size_t post_commit = bridge_source.find(
      "note_ground_usb_admission(frame, status, now_ms)", usb_admission);
  const std::size_t admission_note = bridge_source.find(
      "void note_ground_usb_admission");
  const std::size_t proxy_commit = bridge_source.find(
      "ground_parameter_proxy.on_vehicle_frame(frame, usb_queued, now_ms)",
      admission_note);
  const std::size_t backlog_replay = bridge_source.find(
      "bool replay_ground_usb_ordered_backlog");
  const std::size_t replay_preclassify = bridge_source.find(
      "ground_parameter_proxy.preclassify_vehicle_frame", backlog_replay);
  const std::size_t replay_usb_admission = bridge_source.find(
      "radio_application_endpoint.admit_validated_frame(frame)",
      backlog_replay);
  const std::size_t loop_ground_branch = bridge_source.find(
      "Classify a newly arrived GCS PARAM_SET");
  const std::size_t loop_collect = bridge_source.find(
      "collect_local_ingress(now_ms);", loop_ground_branch);
  const std::size_t loop_deliver = bridge_source.find(
      "deliver_radio_bytes(now_ms);", loop_collect);
  const std::size_t proxy_service = bridge_source.find(
      "void service_ground_parameter_proxy");
  const std::size_t request_admission = bridge_source.find(
      "ground_ingress.admit_validated_frame(request)", proxy_service);
  const std::size_t request_mark = bridge_source.find(
      "mark_request_admitted(token, now_ms)", request_admission);
  const std::size_t request_tracking = bridge_source.find(
      "ground_proxy_request_admitted = true", request_mark);
  const std::size_t request_dequeue = bridge_source.find(
      "mark_request_dequeued", proxy_service);
  const std::size_t request_progress_sample = bridge_source.find(
      "const std::uint64_t committed_bytes =", request_dequeue);
  const std::size_t request_progress_sample_source = bridge_source.find(
      "ground_ingress.stats().bytes_committed", request_progress_sample);
  const std::size_t request_progress_not_dequeued = bridge_source.find(
      "!ground_proxy_request_dequeued", request_progress_sample_source);
  const std::size_t request_progress_gate = bridge_source.find(
      "committed_bytes > ground_proxy_request_progress_bytes",
      request_dequeue);
  const std::size_t request_progress = bridge_source.find(
      "mark_request_queue_progress", request_progress_gate);
  const std::size_t request_progress_advance = bridge_source.find(
      "ground_proxy_request_progress_bytes = committed_bytes;",
      request_progress);
  const std::size_t done_goal = bridge_source.find(
      "ground_proxy_request_done_goal", request_dequeue);
  const std::size_t request_complete = bridge_source.find(
      "complete_request_tx", done_goal);
  const std::size_t proxy_tick = bridge_source.find(
      "ground_parameter_proxy.tick(now_ms)", request_dequeue);
  const std::size_t abandoned_check = bridge_source.find(
      "request_admission_abandoned", proxy_service);
  const std::size_t abandoned_fail_close = bridge_source.find(
      "latch_runtime_fail_closed()", abandoned_check);
  const std::size_t request_progress_snapshot = bridge_source.find(
      "ground_proxy_request_progress_bytes =", request_tracking);
  const std::size_t request_progress_snapshot_source = bridge_source.find(
      "ground_ingress.stats().bytes_committed", request_progress_snapshot);
  const std::size_t request_complete_progress_reset = bridge_source.find(
      "ground_proxy_request_progress_bytes = 0U;", request_complete);
  const std::size_t abandoned_progress_reset = bridge_source.find(
      "ground_proxy_request_progress_bytes = 0U;", abandoned_check);
  const std::size_t setup_proxy_reset = bridge_source.find(
      "ground_parameter_proxy.reset();");
  const std::size_t setup_progress_reset = bridge_source.find(
      "ground_proxy_request_progress_bytes = 0U;", setup_proxy_reset);
  report.check(
      ground_receive != std::string::npos &&
          ground_frame_ready != std::string::npos &&
          validated_handler_call != std::string::npos &&
          validated_handler != std::string::npos &&
          preclassify != std::string::npos &&
          ordered_admission != std::string::npos &&
          usb_admission != std::string::npos &&
          post_commit != std::string::npos &&
          admission_note != std::string::npos &&
          proxy_commit != std::string::npos &&
          ground_receive < ground_frame_ready &&
          ground_frame_ready < validated_handler_call &&
          validated_handler < preclassify &&
          preclassify < ordered_admission &&
          preclassify < usb_admission && usb_admission < post_commit &&
          admission_note < proxy_commit &&
          loop_ground_branch != std::string::npos &&
          loop_collect != std::string::npos &&
          loop_deliver != std::string::npos && loop_collect < loop_deliver,
      "Phase 6 Ground did not preclassify #22 before USB admission/commit");
  report.check(
      backlog_replay != std::string::npos &&
          replay_preclassify != std::string::npos &&
          replay_usb_admission != std::string::npos &&
          backlog_replay < replay_preclassify &&
          replay_preclassify < replay_usb_admission,
      "Phase 6 Ground replay admitted a stale preclassified backlog frame "
      "before authoritative proxy revalidation");
  report.check(
      proxy_service != std::string::npos &&
          request_admission != std::string::npos &&
           request_mark != std::string::npos &&
           request_tracking != std::string::npos &&
           request_dequeue != std::string::npos &&
           request_progress_sample != std::string::npos &&
           request_progress_sample_source != std::string::npos &&
           request_progress_not_dequeued != std::string::npos &&
           request_progress_gate != std::string::npos &&
           request_progress != std::string::npos &&
           request_progress_advance != std::string::npos &&
           done_goal != std::string::npos &&
           request_complete != std::string::npos &&
           proxy_tick != std::string::npos &&
           request_admission < request_mark && request_mark < request_tracking &&
           request_dequeue < request_progress_sample &&
           request_progress_sample < request_progress_sample_source &&
           request_progress_sample_source < request_progress_not_dequeued &&
           request_progress_not_dequeued < request_progress_gate &&
           request_progress_gate < request_progress &&
           request_progress < request_progress_advance &&
           request_progress_advance < proxy_tick && request_dequeue < done_goal &&
           done_goal < request_complete &&
           request_complete < proxy_tick,
       "Phase 6 Ground did not order #20 admission, dequeue, UL_DONE, and "
       "deadline-safe proxy completion stages");
  report.check(
      request_progress_snapshot != std::string::npos &&
          request_progress_snapshot_source != std::string::npos &&
          request_tracking < request_progress_snapshot &&
          request_progress_snapshot < request_progress_snapshot_source &&
          request_complete_progress_reset != std::string::npos &&
          request_complete < request_complete_progress_reset &&
          request_complete_progress_reset < proxy_tick &&
          abandoned_progress_reset != std::string::npos &&
          abandoned_check < abandoned_progress_reset &&
          abandoned_progress_reset < abandoned_fail_close &&
          setup_proxy_reset != std::string::npos &&
          setup_progress_reset != std::string::npos &&
          setup_proxy_reset < setup_progress_reset,
      "Phase 6 Ground did not gate progress by committed bytes or reset its "
      "admission watermark at every terminal boundary");
  report.check(
      abandoned_check != std::string::npos &&
          abandoned_fail_close != std::string::npos &&
          abandoned_check < abandoned_fail_close &&
          bridge_source.find(
              "link_diagnostics.done_tx >= ground_proxy_request_done_goal",
              proxy_service) != std::string::npos,
      "Phase 6 Ground did not fail-close an abandoned FIFO lease or wait for "
      "the matching explicit UL_DONE");
  report.check(bridge_source.find(
                   "input.front_frame_bytes = "
                   "ground_ingress.front_frame_remaining()") !=
                       std::string::npos &&
                   bridge_source.find("transaction_target_bytes()") !=
                       std::string::npos &&
                   bridge_source.find(
                       "ground_ingress.front_frame_wire_bytes()") !=
                       std::string::npos &&
                   bridge_source.find("complete_uplink_frame") ==
                       std::string::npos &&
                   bridge_source.find("complete_frame()") ==
                       std::string::npos,
               "Phase 6 lacks frame-target wiring or retained an implicit "
               "v3 terminal call path");
  report.detail =
       "Explicit-DONE v2/exact-32 wire preserved: 45-byte #76 and generated "
       "32-byte #20 used two grants/two DONEs and two atomic Vehicle commits; "
       "an oversized front frame sent no prefix, and DONE progress is checked "
       "before the inclusive proxy watchdog tick.";
}

}  // namespace

TestReport run_parameter_proxy_test(const std::string& test_id,
                                    std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id == "UT-PARAM-PROXY-MP-V2-TRUNCATION-001") {
    check_mission_planner_v2_truncation(report);
  } else if (test_id == "UT-PARAM-PROXY-LIST-001") {
    check_full_list(report);
  } else if (test_id == "UT-PARAM-PROXY-NATIVE-STREAM-001") {
    check_native_list_stream(report);
  } else if (test_id ==
             "UT-PARAM-PROXY-NATIVE-RECOVERY-EXHAUSTION-001") {
    check_native_recovery_exhaustion(report);
  } else if (test_id == "UT-PARAM-PROXY-MATCH-001") {
    check_matching_guards(report);
  } else if (test_id == "UT-PARAM-PROXY-RETRY-001") {
    check_timeout_retry(report);
  } else if (test_id == "UT-PARAM-PROXY-DUPLICATE-001") {
    check_duplicate_coalescing(report);
  } else if (test_id == "UT-PARAM-PROXY-BOUNDS-001") {
    check_usb_gate_and_bound(report);
  } else if (test_id == "UT-PARAM-PROXY-RESET-001") {
    check_cancel_reset(report);
  } else if (test_id == "UT-PARAM-PROXY-REGRESSION-001") {
    check_passthrough_policy(report);
  } else if (test_id == "IT-PARAM-PROXY-HEARTBEAT-001") {
    check_heartbeat_priority(report);
  } else if (test_id == "IT-PARAM-PROXY-R15-PERIODIC-BOUND-001") {
    check_r15_periodic_uplink_bound(report);
  } else if (test_id == "IT-PARAM-PROXY-ADMISSION-WATCHDOG-001") {
    check_admission_watchdog(report);
  } else if (test_id ==
             "IT-PARAM-PROXY-MP-STARTUP-BACKLOG-001") {
    check_mission_planner_startup_backlog(report);
  } else if (test_id == "IT-PARAM-PROXY-TDD-V2-001") {
    check_tdd_v2_transport(report);
  } else {
    report.check(false, "unknown Ground parameter proxy test ID");
  }
  report.trace.record({0U, "host", "GROUND_PARAM_PROXY", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
