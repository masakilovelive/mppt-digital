#include <vc_lora/mavlink_frame.hpp>
#include <vc_lora/mavlink_scheduler.hpp>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace {

bool check(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
  }
  return condition;
}

void store_u16_le(std::uint16_t value, std::uint8_t* output) {
  output[0U] = static_cast<std::uint8_t>(value & 0xFFU);
  output[1U] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
}

vc_lora::MavlinkFrame make_frame(std::uint32_t message_id,
                                 std::uint8_t sequence) {
  std::array<std::uint8_t, vc_lora::kMavlinkMaxPayloadBytes> payload{};
  vc_lora::MavlinkMessageDefinition definition{};
  vc_lora::MavlinkFrame frame{};
  if (!vc_lora::mavlink_message_definition(message_id, definition) ||
      !vc_lora::encode_mavlink_v2(
          sequence, 1U, 1U, message_id, payload.data(),
          definition.minimum_payload_length, frame)) {
    std::fprintf(stderr, "FAIL: could not encode message %lu\n",
                 static_cast<unsigned long>(message_id));
  }
  return frame;
}

vc_lora::MavlinkFrame make_param_value(std::uint16_t parameter_index) {
  std::array<std::uint8_t, 25U> payload{};
  // Use 57.0f wire bits; the queue contract itself is byte-for-byte.
  payload[2U] = 0x64U;
  payload[3U] = 0x42U;
  store_u16_le(2000U, payload.data() + 4U);
  store_u16_le(parameter_index, payload.data() + 6U);
  constexpr std::array<std::uint8_t, 16U> kId{{
      'S', 'E', 'R', 'I', 'A', 'L', '1', '_',
      'B', 'A', 'U', 'D', 0U, 0U, 0U, 0U}};
  std::copy(kId.begin(), kId.end(), payload.begin() + 8U);
  payload[24U] = 2U;
  vc_lora::MavlinkFrame frame{};
  if (!vc_lora::encode_mavlink_v2(
          static_cast<std::uint8_t>(parameter_index & 0xFFU),
          1U, 1U, 22U, payload.data(), payload.size(), frame)) {
    std::fputs("FAIL: could not encode PARAM_VALUE\n", stderr);
  }
  return frame;
}

bool take_frame(vc_lora::MavlinkFrameScheduler& scheduler,
                vc_lora::MavlinkFrame& decoded) {
  std::array<std::uint8_t, vc_lora::kMavlinkMaxFrameBytes> output{};
  const std::size_t count = scheduler.peek(output.data(), output.size());
  if (count == 0U ||
      vc_lora::validate_mavlink_frame(output.data(), count, decoded) !=
          vc_lora::MavlinkParseStatus::FrameReady) {
    return false;
  }
  return scheduler.complete_send(vc_lora::TxResult::Accepted, count);
}

std::uint16_t param_index(const vc_lora::MavlinkFrame& frame) {
  if (frame.message_id != 22U || frame.payload_length != 25U) {
    return 0xFFFFU;
  }
  const std::uint8_t* payload = frame.payload();
  return static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(payload[6U]) |
      (static_cast<std::uint16_t>(payload[7U]) << 8U));
}

bool check_capacity_and_fifo_wrap() {
  static_assert(
      vc_lora::MavlinkFrameScheduler::parameter_download_frame_capacity() ==
          1024U,
      "PARAM_VALUE FIFO must retain 1024 complete frames");
  static_assert(
      vc_lora::MavlinkFrameScheduler::parameter_download_byte_capacity() ==
          64U * 1024U,
      "PARAM_VALUE FIFO must retain 64 KiB of encoded bytes");

  vc_lora::MavlinkFrameScheduler scheduler{};
  bool passed = true;
  passed &= check(scheduler.parameter_download_queued_frames() == 0U &&
                      !scheduler.parameter_download_active(),
                  "fresh generic PARAM_VALUE lane must be empty/inactive");
  const std::size_t encoded_size = make_param_value(0U).size;
  for (std::uint16_t index = 0U; index < 1024U; ++index) {
    passed &= check(
        scheduler.enqueue(make_param_value(index)) ==
            vc_lora::MavlinkEnqueueStatus::Queued,
        "first 1024 PARAM_VALUE frames must enqueue without eviction");
  }
  passed &= check(scheduler.size() == 1024U,
                  "dedicated queue size must report 1024 frames");
  passed &= check(scheduler.parameter_download_queued_frames() == 1024U &&
                      !scheduler.parameter_download_active(),
                  "generic PARAM_VALUE lane depth/accessor mismatch");
  passed &= check(scheduler.queued_bytes() == 1024U * encoded_size,
                  "dedicated queue byte accounting mismatch at capacity");
  passed &= check(
      scheduler.enqueue(make_param_value(1024U)) ==
          vc_lora::MavlinkEnqueueStatus::DroppedFull,
      "1025th PARAM_VALUE must fail closed at the frame capacity");

  std::array<std::uint8_t, 5U> activation_prefix{};
  const std::size_t activation_size =
      scheduler.peek(activation_prefix.data(), activation_prefix.size());
  passed &= check(activation_size == activation_prefix.size() &&
                      scheduler.parameter_download_active() &&
                      scheduler.parameter_download_queued_frames() == 1024U,
                  "generic PARAM_VALUE active state was not externally visible");
  passed &= check(scheduler.complete_send(vc_lora::TxResult::Accepted,
                                          activation_size),
                  "generic PARAM_VALUE activation prefix did not commit");

  for (std::uint16_t expected = 0U; expected < 512U; ++expected) {
    vc_lora::MavlinkFrame frame{};
    if (expected == 0U) {
      std::array<std::uint8_t, vc_lora::kMavlinkMaxFrameBytes> remainder{};
      const std::size_t remainder_size =
          scheduler.peek(remainder.data(), remainder.size());
      std::array<std::uint8_t, vc_lora::kMavlinkMaxFrameBytes> complete{};
      std::copy(activation_prefix.begin(), activation_prefix.end(),
                complete.begin());
      std::copy_n(remainder.begin(), remainder_size,
                  complete.begin() + activation_size);
      passed &= check(
          vc_lora::validate_mavlink_frame(
              complete.data(), activation_size + remainder_size, frame) ==
              vc_lora::MavlinkParseStatus::FrameReady &&
              scheduler.complete_send(vc_lora::TxResult::Accepted,
                                      remainder_size),
          "could not finish active PARAM_VALUE before FIFO wrap");
    } else {
      passed &= check(take_frame(scheduler, frame),
                      "could not dequeue PARAM_VALUE before FIFO wrap");
    }
    passed &= check(param_index(frame) == expected,
                    "PARAM_VALUE FIFO order changed before wrap");
  }
  for (std::uint16_t index = 1024U; index < 1536U; ++index) {
    passed &= check(
        scheduler.enqueue(make_param_value(index)) ==
            vc_lora::MavlinkEnqueueStatus::Queued,
        "freed PARAM_VALUE FIFO slots must be reusable after wrap");
  }
  for (std::uint16_t expected = 512U; expected < 1536U; ++expected) {
    vc_lora::MavlinkFrame frame{};
    passed &= check(take_frame(scheduler, frame),
                    "could not dequeue PARAM_VALUE after FIFO wrap");
    passed &= check(param_index(frame) == expected,
                    "PARAM_VALUE dedicated queue is not strict FIFO");
  }
  passed &= check(scheduler.empty() && scheduler.queued_bytes() == 0U,
                  "PARAM_VALUE queue must drain to an empty zero-byte state");
  passed &= check(scheduler.parameter_download_queued_frames() == 0U &&
                      !scheduler.parameter_download_active(),
                  "drained generic PARAM_VALUE lane stayed visible as stale");
  const auto& diagnostics = scheduler.diagnostics();
  passed &= check(diagnostics.queue_drop_frames == 1U,
                  "only the deliberate 1025th frame may be dropped");
  passed &= check(diagnostics.frames_forwarded == 1536U,
                  "forwarded frame accounting mismatch");
  passed &= check(diagnostics.max_queue_frames == 1024U,
                  "PARAM_VALUE high watermark must include dedicated FIFO");
  return passed;
}

bool check_heartbeat_precedence() {
  vc_lora::MavlinkFrameScheduler scheduler{};
  const auto parameter = make_param_value(65535U);
  const auto heartbeat = make_frame(0U, 11U);
  bool passed = true;
  passed &= check(
      scheduler.enqueue(parameter) == vc_lora::MavlinkEnqueueStatus::Queued &&
          scheduler.enqueue(heartbeat) ==
              vc_lora::MavlinkEnqueueStatus::Queued,
      "heartbeat/parameter setup enqueue failed");
  vc_lora::MavlinkFrame first{};
  vc_lora::MavlinkFrame second{};
  passed &= check(take_frame(scheduler, first) && first.message_id == 0U,
                  "pending heartbeat must precede PARAM_VALUE");
  passed &= check(take_frame(scheduler, second) && second.message_id == 22U,
                  "PARAM_VALUE must follow the retained heartbeat");
  return passed;
}

bool check_parameter_precedes_normal() {
  vc_lora::MavlinkFrameScheduler scheduler{};
  const auto attitude = make_frame(30U, 12U);
  const auto parameter = make_param_value(77U);
  bool passed = true;
  passed &= check(
      scheduler.enqueue(attitude, 5000U) ==
              vc_lora::MavlinkEnqueueStatus::Queued &&
          scheduler.enqueue(parameter, 5000U) ==
              vc_lora::MavlinkEnqueueStatus::Queued,
      "normal/parameter setup enqueue failed");
  vc_lora::MavlinkFrame first{};
  vc_lora::MavlinkFrame second{};
  passed &= check(take_frame(scheduler, first) && first.message_id == 22U,
                  "PARAM_VALUE must precede normal display telemetry");
  passed &= check(take_frame(scheduler, second) && second.message_id == 30U,
                  "normal display telemetry must remain queued after PARAM_VALUE");
  return passed;
}

bool check_active_parameter_is_not_interrupted() {
  vc_lora::MavlinkFrameScheduler scheduler{};
  const auto parameter = make_param_value(88U);
  const auto heartbeat = make_frame(0U, 13U);
  bool passed = true;
  passed &= check(scheduler.enqueue(parameter) ==
                      vc_lora::MavlinkEnqueueStatus::Queued,
                  "active PARAM_VALUE setup enqueue failed");

  std::array<std::uint8_t, 5U> prefix{};
  const std::size_t prefix_size = scheduler.peek(prefix.data(), prefix.size());
  passed &= check(prefix_size == prefix.size() &&
                      std::equal(prefix.begin(), prefix.end(),
                                 parameter.bytes.begin()),
                  "PARAM_VALUE prefix activation mismatch");
  passed &= check(scheduler.complete_send(vc_lora::TxResult::Accepted,
                                          prefix_size),
                  "PARAM_VALUE prefix completion failed");
  passed &= check(scheduler.enqueue(heartbeat) ==
                      vc_lora::MavlinkEnqueueStatus::Queued,
                  "heartbeat enqueue during active PARAM_VALUE failed");

  std::array<std::uint8_t, vc_lora::kMavlinkMaxFrameBytes> remainder{};
  const std::size_t remainder_size =
      scheduler.peek(remainder.data(), remainder.size());
  passed &= check(
      remainder_size == parameter.size - prefix_size &&
          std::equal(remainder.begin(), remainder.begin() + remainder_size,
                     parameter.bytes.begin() + prefix_size),
      "heartbeat must not split an already active PARAM_VALUE frame");
  passed &= check(scheduler.complete_send(vc_lora::TxResult::Accepted,
                                          remainder_size),
                  "PARAM_VALUE remainder completion failed");

  vc_lora::MavlinkFrame final{};
  passed &= check(take_frame(scheduler, final) && final.message_id == 0U,
                  "heartbeat must transmit immediately after active PARAM_VALUE");
  return passed;
}

}  // namespace

int main() {
  bool passed = check_capacity_and_fifo_wrap();
  passed &= check_heartbeat_precedence();
  passed &= check_parameter_precedes_normal();
  passed &= check_active_parameter_is_not_interrupted();
  if (!passed) {
    return 1;
  }
  std::puts("PASS FW-VEHICLE-DIAG-SCHED-SYNC-001");
  return 0;
}
