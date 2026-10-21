#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

#include "fixtures/mavlink/golden_frames.hpp"
#include "vc_lora/embedded_io_adapter.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/mavlink_scheduler.hpp"

namespace vc_lora::test {
namespace {

MavlinkFrame make_v2(std::uint8_t sequence, std::uint32_t message_id,
                     const std::uint8_t* payload, std::size_t payload_size,
                     TestReport& report) {
  MavlinkFrame frame{};
  report.check(encode_mavlink_v2(sequence, 1U, 1U, message_id, payload,
                                 payload_size, frame),
               "MAVLink 2 fixture encoding failed");
  return frame;
}

MavlinkParseStatus feed(const MavlinkFrame& input,
                        MavlinkStreamParser& parser, MavlinkFrame& output,
                        TestReport& report) {
  MavlinkParseStatus status = MavlinkParseStatus::NeedMore;
  for (std::size_t index = 0; index < input.size; ++index) {
    status = parser.push(input.bytes[index], output);
    if (index + 1U < input.size) {
      report.check(status == MavlinkParseStatus::NeedMore,
                   "parser exposed a partial MAVLink frame");
    }
  }
  return status;
}

bool same_bytes(const MavlinkFrame& left, const MavlinkFrame& right) {
  if (left.size != right.size) {
    return false;
  }
  for (std::size_t index = 0; index < left.size; ++index) {
    if (left.bytes[index] != right.bytes[index]) {
      return false;
    }
  }
  return true;
}

template <std::size_t Size>
void check_golden_fixture(const std::array<std::uint8_t, Size>& bytes,
                          std::uint32_t expected_message_id,
                          TestReport& report) {
  MavlinkStreamParser parser{};
  MavlinkFrame decoded{};
  MavlinkParseStatus status = MavlinkParseStatus::NeedMore;
  for (const std::uint8_t byte : bytes) {
    status = parser.push(byte, decoded);
  }
  report.check(status == MavlinkParseStatus::FrameReady &&
                   decoded.size == bytes.size() &&
                   decoded.message_id == expected_message_id,
               "Mission Planner golden fixture failed validation");
  if (status != MavlinkParseStatus::FrameReady) {
    return;
  }
  MavlinkFrame encoded{};
  const bool encoded_ok =
      decoded.version == MavlinkVersion::V1
          ? encode_mavlink_v1(
                decoded.sequence, decoded.system_id, decoded.component_id,
                decoded.message_id, decoded.payload(), decoded.payload_length,
                encoded)
          : encode_mavlink_v2(
                decoded.sequence, decoded.system_id, decoded.component_id,
                decoded.message_id, decoded.payload(), decoded.payload_length,
                encoded);
  report.check(encoded_ok && same_bytes(decoded, encoded),
               "encoder output differs from Mission Planner golden bytes");
}

std::array<std::uint8_t, 9> heartbeat_payload(std::uint32_t custom_mode) {
  return {{static_cast<std::uint8_t>(custom_mode & 0xFFU),
           static_cast<std::uint8_t>((custom_mode >> 8U) & 0xFFU),
           static_cast<std::uint8_t>((custom_mode >> 16U) & 0xFFU),
           static_cast<std::uint8_t>((custom_mode >> 24U) & 0xFFU),
           2U, 3U, 0x51U, 4U, 3U}};
}

std::array<std::uint8_t, 3> command_ack_payload(std::uint16_t command,
                                                std::uint8_t result) {
  return {{static_cast<std::uint8_t>(command & 0xFFU),
           static_cast<std::uint8_t>((command >> 8U) & 0xFFU), result}};
}

void drain_frame(MavlinkFrameScheduler& scheduler,
                 std::array<std::uint8_t, kMavlinkMaxFrameBytes>& bytes,
                 std::size_t& size, TestReport& report) {
  size = scheduler.peek(bytes.data(), bytes.size());
  report.check(size > 0U, "scheduler returned no active frame");
  report.check(scheduler.complete_send(TxResult::Accepted, size),
               "scheduler did not accept a complete active-frame send");
}

struct ExpectedMessageDefinition {
  std::uint32_t message_id;
  std::uint8_t crc_extra;
  std::uint8_t minimum_payload_length;
  std::uint8_t maximum_payload_length;
};

template <std::size_t Size>
void check_message_definitions(
    const std::array<ExpectedMessageDefinition, Size>& expected,
    TestReport& report) {
  for (const ExpectedMessageDefinition& item : expected) {
    MavlinkMessageDefinition actual{};
    report.check(mavlink_message_definition(item.message_id, actual) &&
                     actual.message_id == item.message_id &&
                     actual.crc_extra == item.crc_extra &&
                     actual.minimum_payload_length ==
                         item.minimum_payload_length &&
                     actual.maximum_payload_length ==
                         item.maximum_payload_length,
                 "Mission Planner MAVLink.dll definition mismatch for msgid=" +
                     std::to_string(item.message_id));
  }
}

MavlinkFrame make_minimum_v2(std::uint8_t sequence,
                             std::uint32_t message_id,
                             TestReport& report) {
  MavlinkMessageDefinition definition{};
  std::array<std::uint8_t, kMavlinkMaxPayloadBytes> payload{};
  MavlinkFrame frame{};
  report.check(mavlink_message_definition(message_id, definition) &&
                   encode_mavlink_v2(
                       sequence, 1U, 1U, message_id, payload.data(),
                       definition.minimum_payload_length, frame),
               "minimum-length MAVLink 2 fixture encoding failed for msgid=" +
                   std::to_string(message_id));
  return frame;
}

}  // namespace

TestReport run_mavlink_unit_test(const std::string& test_id,
                                 std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-MAV-001") {
    MavlinkStreamParser parser{};
    MavlinkFrame actual{};
    MavlinkParseStatus status = MavlinkParseStatus::NeedMore;
    for (std::size_t index = 0; index < fixtures::kGcsHeartbeatV1.size();
         ++index) {
      status = parser.push(fixtures::kGcsHeartbeatV1[index], actual);
      if (index + 1U < fixtures::kGcsHeartbeatV1.size()) {
        report.check(status == MavlinkParseStatus::NeedMore,
                     "parser exposed a partial MAVLink 1 frame");
      }
    }
    report.check(status == MavlinkParseStatus::FrameReady,
                 "valid MAVLink 1 heartbeat was not accepted");
    report.check(actual.version == MavlinkVersion::V1 &&
                     actual.message_id == 0U && actual.sequence == 0U &&
                     actual.system_id == 0xFFU &&
                     actual.component_id == 0xBEU &&
                     actual.payload_length == 9U,
                 "MAVLink 1 metadata was decoded incorrectly");
    MavlinkFrame encoded{};
    report.check(encode_mavlink_v1(
                     actual.sequence, actual.system_id, actual.component_id,
                     actual.message_id, actual.payload(),
                     actual.payload_length, encoded),
                 "golden MAVLink 1 heartbeat could not be re-encoded");
    report.check(same_bytes(actual, encoded),
                 "MAVLink 1 encoder differs from independent golden CRC");
  } else if (test_id == "UT-MAV-002") {
    MavlinkStreamParser parser{};
    MavlinkFrame actual{};
    MavlinkParseStatus status = MavlinkParseStatus::NeedMore;
    for (std::size_t index = 0;
         index < fixtures::kAdversarialParamSet.size(); ++index) {
      status = parser.push(fixtures::kAdversarialParamSet[index], actual);
      if (index + 1U < fixtures::kAdversarialParamSet.size()) {
        report.check(status == MavlinkParseStatus::NeedMore,
                     "MAVLink 2 parser emitted an incomplete frame");
      }
    }
    report.check(status == MavlinkParseStatus::FrameReady,
                 "golden MAVLink 2 PARAM_SET failed CRC validation");
    report.check(actual.version == MavlinkVersion::V2 &&
                     actual.message_id == 23U && actual.sequence == 0x39U &&
                     actual.system_id == 0xFFU &&
                     actual.component_id == 0xBEU,
                 "golden MAVLink 2 metadata was decoded incorrectly");
    report.check(actual.size == fixtures::kAdversarialParamSet.size(),
                 "golden MAVLink 2 length changed");
  } else if (test_id == "UT-MAV-003") {
    const auto hb_payload = heartbeat_payload(1U);
    const auto ack_payload = command_ack_payload(400U, 0U);
    const MavlinkFrame first =
        make_v2(1U, 0U, hb_payload.data(), hb_payload.size(), report);
    const MavlinkFrame second =
        make_v2(2U, 77U, ack_payload.data(), ack_payload.size(), report);
    MavlinkStreamParser parser{};
    MavlinkFrame actual{};
    report.check(feed(first, parser, actual, report) ==
                     MavlinkParseStatus::FrameReady &&
                     same_bytes(first, actual),
                 "first adjacent MAVLink frame was not separated");
    report.check(feed(second, parser, actual, report) ==
                     MavlinkParseStatus::FrameReady &&
                     same_bytes(second, actual),
                 "second adjacent MAVLink frame was not separated");
    report.check(parser.diagnostics().frames_accepted == 2U,
                 "parser accepted-frame accounting is incorrect");
  } else if (test_id == "UT-MAV-004") {
    const auto payload = heartbeat_payload(2U);
    MavlinkFrame corrupted =
        make_v2(3U, 0U, payload.data(), payload.size(), report);
    corrupted.bytes[10] ^= 0x01U;
    MavlinkStreamParser parser{};
    MavlinkFrame actual{};
    report.check(feed(corrupted, parser, actual, report) ==
                     MavlinkParseStatus::BadCrc,
                 "one-bit MAVLink payload corruption was accepted");
    const MavlinkFrame valid =
        make_v2(4U, 0U, payload.data(), payload.size(), report);
    report.check(feed(valid, parser, actual, report) ==
                     MavlinkParseStatus::FrameReady &&
                     same_bytes(valid, actual),
                 "parser did not recover after a bad CRC frame");
    report.check(parser.diagnostics().crc_errors == 1U,
                 "MAVLink CRC error was not counted exactly once");
  } else if (test_id == "UT-MAV-005") {
    const auto payload = heartbeat_payload(3U);
    MavlinkFrame signed_frame{};
    std::array<std::uint8_t, kMavlinkSignatureBytes> signature{};
    for (std::size_t index = 0; index < signature.size(); ++index) {
      signature[index] = static_cast<std::uint8_t>(index + 1U);
    }
    report.check(encode_mavlink_v2(5U, 1U, 1U, 0U, payload.data(),
                                   payload.size(), signed_frame, 0x01U, 0U,
                                   signature.data()),
                 "signed MAVLink 2 fixture encoding failed");
    MavlinkStreamParser parser{};
    MavlinkFrame actual{};
    report.check(feed(signed_frame, parser, actual, report) ==
                     MavlinkParseStatus::FrameReady &&
                     actual.signed_frame && same_bytes(signed_frame, actual),
                 "signed MAVLink 2 frame length/CRC was parsed incorrectly");

    MavlinkFrame unsupported = signed_frame;
    unsupported.bytes[2] = 0x02U;
    parser.reset();
    report.check(parser.push(unsupported.bytes[0], actual) ==
                     MavlinkParseStatus::NeedMore &&
                     parser.push(unsupported.bytes[1], actual) ==
                         MavlinkParseStatus::NeedMore &&
                     parser.push(unsupported.bytes[2], actual) ==
                         MavlinkParseStatus::UnsupportedFlags,
                 "unknown MAVLink 2 incompatibility flag was accepted");
  } else if (test_id == "UT-MAV-006") {
    constexpr std::array<std::uint32_t, 7> message_ids{{
        0U, 20U, 22U, 23U, 76U, 77U, 194U,
    }};
    constexpr std::array<std::uint8_t, 7> expected_extras{{
        50U, 214U, 220U, 168U, 152U, 143U, 98U,
    }};
    for (std::size_t index = 0; index < message_ids.size(); ++index) {
      std::uint8_t actual_extra = 0U;
      report.check(mavlink_crc_extra(message_ids[index], actual_extra) &&
                       actual_extra == expected_extras[index],
                   "known MAVLink CRC extra is incorrect");
    }
    MavlinkStreamParser parser{};
    MavlinkFrame frame{};
    MavlinkParseStatus status = MavlinkParseStatus::NeedMore;
    for (const auto byte : fixtures::kAdversarialParamSet) {
      status = parser.push(byte, frame);
    }
    report.check(status == MavlinkParseStatus::FrameReady,
                 "golden fixture could not be decoded before re-encoding");
    MavlinkFrame encoded{};
    report.check(encode_mavlink_v2(
                     frame.sequence, frame.system_id, frame.component_id,
                     frame.message_id, frame.payload(), frame.payload_length,
                     encoded),
                 "golden fixture could not be re-encoded");
    report.check(same_bytes(frame, encoded),
                 "encoder does not match independent golden bytes/CRC");
    report.check(!encode_mavlink_v2(0U, 1U, 1U, 999U, nullptr, 0U,
                                    encoded),
                 "encoder accepted a message without a known CRC extra");
    check_golden_fixture(fixtures::kPixhawkHeartbeatV2, 0U, report);
    check_golden_fixture(fixtures::kGcsHeartbeatV1, 0U, report);
    check_golden_fixture(fixtures::kParamRequestReadV2, 20U, report);
    check_golden_fixture(fixtures::kParamValueV2, 22U, report);
    check_golden_fixture(fixtures::kParamSetV1, 23U, report);
    check_golden_fixture(fixtures::kParamValueV1, 22U, report);
    check_golden_fixture(fixtures::kCommandLongV2, 76U, report);
    check_golden_fixture(fixtures::kCommandAckV2Full, 77U, report);
    check_golden_fixture(fixtures::kPidTuning194V2, 194U, report);
    std::array<std::uint8_t, 33> wrong_length_payload{};
    report.check(!encode_mavlink_v2(0U, 1U, 1U, 0U,
                                    wrong_length_payload.data(), 0U,
                                    encoded),
                 "zero-length HEARTBEAT was accepted");
    report.check(!encode_mavlink_v2(0U, 1U, 1U, 76U,
                                    wrong_length_payload.data(), 32U,
                                    encoded),
                 "short COMMAND_LONG was accepted");
    report.check(!encode_mavlink_v2(0U, 1U, 1U, 77U,
                                    wrong_length_payload.data(), 11U,
                                    encoded),
                 "oversized COMMAND_ACK was accepted");
    report.check(!encode_mavlink_v2(0U, 1U, 1U, 194U,
                                    wrong_length_payload.data(), 24U,
                                    encoded),
                 "short PID_TUNING was accepted");
  } else if (test_id == "UT-MAV-007") {
    MavlinkFrameScheduler scheduler{};
    std::array<std::uint8_t, 20> ordinary_payload{};
    ordinary_payload[0] = 1U;
    ordinary_payload[1] = 2U;
    ordinary_payload[2] = 1U;
    ordinary_payload[3] = 1U;
    const auto hb_payload_a = heartbeat_payload(10U);
    const auto hb_payload_b = heartbeat_payload(11U);
    const auto ack_payload = command_ack_payload(401U, 0U);
    const MavlinkFrame ordinary = make_v2(
        10U, 20U, ordinary_payload.data(), ordinary_payload.size(), report);
    const MavlinkFrame hb_a = make_v2(
        11U, 0U, hb_payload_a.data(), hb_payload_a.size(), report);
    const MavlinkFrame ack = make_v2(
        12U, 77U, ack_payload.data(), ack_payload.size(), report);
    const MavlinkFrame hb_b = make_v2(
        13U, 0U, hb_payload_b.data(), hb_payload_b.size(), report);
    report.check(scheduler.enqueue(ordinary) == MavlinkEnqueueStatus::Queued &&
                     scheduler.enqueue(hb_a) == MavlinkEnqueueStatus::Queued &&
                     scheduler.enqueue(ack) == MavlinkEnqueueStatus::Queued &&
                     scheduler.enqueue(hb_b) == MavlinkEnqueueStatus::Queued,
                 "scheduler rejected an in-capacity frame");

    std::array<std::uint8_t, kMavlinkMaxFrameBytes> bytes{};
    std::size_t size = 0U;
    drain_frame(scheduler, bytes, size, report);
    report.check(size == hb_a.size && bytes[4] == hb_a.sequence,
                 "oldest heartbeat was not scheduled first");
    drain_frame(scheduler, bytes, size, report);
    report.check(size == hb_b.size && bytes[4] == hb_b.sequence,
                 "multiple heartbeats were collapsed or reordered");
    drain_frame(scheduler, bytes, size, report);
    report.check(size == ack.size && bytes[4] == ack.sequence,
                 "response priority was not ahead of ordinary traffic");
    drain_frame(scheduler, bytes, size, report);
    report.check(size == ordinary.size && bytes[4] == ordinary.sequence,
                 "ordinary frame was lost after priority scheduling");
  } else if (test_id == "UT-MAV-008") {
    MavlinkFrameScheduler scheduler{};
    const std::array<std::uint8_t, 20> request_payload{};
    const auto hb_payload = heartbeat_payload(12U);
    const MavlinkFrame ordinary = make_v2(
        21U, 20U, request_payload.data(), request_payload.size(), report);
    const MavlinkFrame hb =
        make_v2(22U, 0U, hb_payload.data(), hb_payload.size(), report);
    report.check(scheduler.enqueue(ordinary) == MavlinkEnqueueStatus::Queued,
                 "active-frame fixture enqueue failed");
    std::array<std::uint8_t, 8> first{};
    const std::size_t first_size = scheduler.peek(first.data(), first.size());
    report.check(first_size == first.size(),
                 "scheduler did not expose the requested prefix");
    report.check(scheduler.enqueue(hb) == MavlinkEnqueueStatus::Queued,
                 "high-priority enqueue failed while ordinary frame active");
    report.check(scheduler.complete_send(TxResult::Rejected, first_size),
                 "scheduler rejected a valid rejection completion");
    std::array<std::uint8_t, 8> retry{};
    report.check(scheduler.peek(retry.data(), retry.size()) == retry.size() &&
                     retry == first,
                 "rejected bytes were consumed or active frame preempted");
    report.check(scheduler.complete_send(TxResult::Accepted, retry.size()),
                 "accepted prefix was not consumed");
    std::array<std::uint8_t, kMavlinkMaxFrameBytes> remainder{};
    const std::size_t remainder_size =
        scheduler.peek(remainder.data(), remainder.size());
    report.check(remainder_size == ordinary.size - retry.size() &&
                     remainder[0] == ordinary.bytes[retry.size()],
                 "active frame did not resume at the accepted offset");
    report.check(scheduler.complete_send(TxResult::Accepted, remainder_size),
                 "active frame remainder was not accepted");
    report.check(scheduler.peek(remainder.data(), remainder.size()) == hb.size &&
                     remainder[4] == hb.sequence,
                 "queued heartbeat did not follow completed active frame");
  } else if (test_id == "UT-MAV-009") {
    std::array<std::uint8_t, 25> pid_payload{};
    pid_payload[24] = 1U;
    MavlinkFrame pid =
        make_v2(31U, 194U, pid_payload.data(), pid_payload.size(), report);
    MavlinkFrameScheduler scheduler{};
    report.check(scheduler.enqueue(pid) == MavlinkEnqueueStatus::Filtered,
                 "valid PID_TUNING was not intentionally filtered");
    report.check(scheduler.empty() &&
                     scheduler.diagnostics().msg194_frames_filtered == 1U &&
                     scheduler.diagnostics().msg194_bytes_filtered == pid.size,
                 "PID_TUNING filter accounting is incorrect");
    pid.bytes[10] ^= 0x80U;
    report.check(scheduler.enqueue(pid) == MavlinkEnqueueStatus::Invalid,
                 "bad-CRC PID_TUNING was classified as an intentional filter");
    report.check(scheduler.diagnostics().msg194_frames_filtered == 1U &&
                     scheduler.diagnostics().invalid_frames == 1U,
                 "invalid PID_TUNING corrupted filter diagnostics");
  } else if (test_id == "UT-MAV-010") {
    MavlinkFrameScheduler scheduler{};
    const std::array<std::uint8_t, 20> ordinary_payload{};
    for (std::uint8_t sequence = 0U;
         sequence < MavlinkFrameScheduler::capacity(); ++sequence) {
      const MavlinkFrame frame = make_v2(sequence, 20U,
                                         ordinary_payload.data(),
                                         ordinary_payload.size(), report);
      report.check(scheduler.enqueue(frame) == MavlinkEnqueueStatus::Queued,
                   "scheduler filled fewer than eight slots");
    }
    const auto hb_payload = heartbeat_payload(20U);
    const MavlinkFrame heartbeat =
        make_v2(99U, 0U, hb_payload.data(), hb_payload.size(), report);
    report.check(scheduler.enqueue(heartbeat) == MavlinkEnqueueStatus::Queued,
                 "heartbeat could not evict oldest ordinary queued frame");
    report.check(scheduler.size() == MavlinkFrameScheduler::capacity() &&
                     scheduler.diagnostics().queue_drop_frames == 1U,
                 "priority eviction queue/drop accounting is incorrect");
    const MavlinkFrame ordinary = make_v2(
        100U, 20U, ordinary_payload.data(), ordinary_payload.size(), report);
    report.check(scheduler.enqueue(ordinary) ==
                     MavlinkEnqueueStatus::DroppedFull,
                 "full scheduler accepted a newest ordinary frame");
    report.check(scheduler.diagnostics().queue_drop_frames == 2U &&
                     scheduler.diagnostics().max_queue_frames ==
                         MavlinkFrameScheduler::capacity(),
                 "full-queue diagnostics are incorrect");
  } else if (test_id == "UT-MAV-011") {
    // Real Pixhawk response to a read of nonexistent ARMING_CHECK. This
    // regression protects the newer PARAM_ERROR response from being silently
    // rejected by the explicit allow-list or demoted behind telemetry.
    MavlinkMessageDefinition definition{};
    std::uint8_t crc_extra = 0U;
    report.check(mavlink_message_definition(345U, definition) &&
                     definition.message_id == 345U &&
                     definition.crc_extra == 209U &&
                     definition.minimum_payload_length == 21U &&
                     definition.maximum_payload_length == 21U &&
                     mavlink_crc_extra(345U, crc_extra) &&
                     crc_extra == 209U,
                 "PARAM_ERROR definition is absent or incorrect");

    MavlinkFrame param_error{};
    const MavlinkParseStatus decode_status = validate_mavlink_frame(
        fixtures::kPixhawkParamErrorV2.data(),
        fixtures::kPixhawkParamErrorV2.size(), param_error);
    report.check(decode_status == MavlinkParseStatus::FrameReady &&
                     param_error.message_id == 345U &&
                     param_error.payload_length == 21U &&
                     param_error.size == fixtures::kPixhawkParamErrorV2.size(),
                 "captured Pixhawk PARAM_ERROR did not validate exactly");

    if (decode_status == MavlinkParseStatus::FrameReady) {
      MavlinkFrameScheduler scheduler{};
      const MavlinkFrame ordinary = make_minimum_v2(0xA0U, 1U, report);
      report.check(scheduler.enqueue(ordinary, 0U) ==
                           MavlinkEnqueueStatus::Queued &&
                       scheduler.enqueue(param_error, 0U) ==
                           MavlinkEnqueueStatus::Queued,
                   "PARAM_ERROR scheduler setup was rejected");
      std::array<std::uint8_t, kMavlinkMaxFrameBytes> scheduled{};
      std::size_t scheduled_size = 0U;
      drain_frame(scheduler, scheduled, scheduled_size, report);
      report.check(
          scheduled_size == fixtures::kPixhawkParamErrorV2.size() &&
              std::equal(scheduled.begin(),
                         scheduled.begin() + scheduled_size,
                         fixtures::kPixhawkParamErrorV2.begin()),
          "PARAM_ERROR was not scheduled urgently and byte-exactly");

      MavlinkValidatedLocalEgressAdapter<64U, 64U> ground_egress{};
      ValidatedLocalIngressStatus egress_status =
          ValidatedLocalIngressStatus::NeedMore;
      for (const std::uint8_t byte : fixtures::kPixhawkParamErrorV2) {
        egress_status = ground_egress.ingest_byte(byte);
      }
      std::array<std::uint8_t, 64U> forwarded{};
      const std::size_t forwarded_size =
          ground_egress.egress().peek(forwarded.data(), forwarded.size());
      report.check(
          egress_status == ValidatedLocalIngressStatus::QueuedFrame &&
              forwarded_size == fixtures::kPixhawkParamErrorV2.size() &&
              std::equal(forwarded.begin(),
                         forwarded.begin() + forwarded_size,
                         fixtures::kPixhawkParamErrorV2.begin()) &&
              ground_egress.stats().frames_validated == 1U &&
              ground_egress.stats().frames_queued == 1U &&
              !ground_egress.fail_closed(),
          "PARAM_ERROR did not reach Ground local egress byte-exactly");
    } else {
      report.check(false, "PARAM_ERROR could not enter the scheduler");
      report.check(false, "PARAM_ERROR could not enter Ground local egress");
    }
    report.detail =
        "Captured msg345 payload=21 CRC_EXTRA=209; urgent scheduler and "
        "validated Ground egress preserved all 33 wire bytes.";
  } else if (test_id == "UT-MAV-012") {
    // A PARAM_REQUEST_LIST response is a burst of roughly one thousand
    // PARAM_VALUE frames. Preserve the entire bounded burst compactly while
    // keeping HEARTBEAT and unrelated urgent traffic ahead of the download.
    constexpr std::uint16_t kParameterCount = 932U;
    MavlinkFrameScheduler scheduler{};
    for (std::uint16_t index = 0U; index < kParameterCount; ++index) {
      std::array<std::uint8_t, 25U> payload{};
      payload[4] = static_cast<std::uint8_t>(kParameterCount & 0xFFU);
      payload[5] = static_cast<std::uint8_t>(kParameterCount >> 8U);
      payload[6] = static_cast<std::uint8_t>(index & 0xFFU);
      payload[7] = static_cast<std::uint8_t>(index >> 8U);
      payload[8] = 'P';
      payload[9] = static_cast<std::uint8_t>('0' + ((index / 100U) % 10U));
      payload[10] = static_cast<std::uint8_t>('0' + ((index / 10U) % 10U));
      payload[11] = static_cast<std::uint8_t>('0' + (index % 10U));
      payload[24] = 6U;  // MAV_PARAM_TYPE_INT32
      const MavlinkFrame frame = make_v2(
          static_cast<std::uint8_t>(index), 22U, payload.data(),
          payload.size(), report);
      report.check(scheduler.enqueue(frame, index) ==
                       MavlinkEnqueueStatus::Queued,
                   "full PARAM_VALUE burst was not retained");
    }

    const auto hb_payload = heartbeat_payload(0U);
    const MavlinkFrame heartbeat = make_v2(
        0xF0U, 0U, hb_payload.data(), hb_payload.size(), report);
    const auto ack_payload = command_ack_payload(512U, 0U);
    const MavlinkFrame command_ack = make_v2(
        0xF1U, 77U, ack_payload.data(), ack_payload.size(), report);
    constexpr std::array<std::uint8_t, 2U> mission_current_payload{};
    const MavlinkFrame mission_current = make_v2(
        0xF2U, 42U, mission_current_payload.data(),
        mission_current_payload.size(), report);
    report.check(scheduler.enqueue(heartbeat, kParameterCount) ==
                         MavlinkEnqueueStatus::Queued &&
                     scheduler.enqueue(command_ack, kParameterCount) ==
                         MavlinkEnqueueStatus::Queued &&
                     scheduler.enqueue(mission_current, kParameterCount) ==
                         MavlinkEnqueueStatus::Queued,
                 "heartbeat/urgent traffic could not coexist with download");
    report.check(scheduler.size() == kParameterCount + 3U &&
                     scheduler.diagnostics().queue_drop_frames == 0U,
                 "parameter download queue lost a frame before draining");

    std::array<std::uint8_t, kMavlinkMaxFrameBytes> bytes{};
    std::uint16_t expected_index = 0U;
    std::size_t drained_frames = 0U;
    while (!scheduler.empty()) {
      const std::size_t size = scheduler.peek(bytes.data(), bytes.size());
      MavlinkFrame decoded{};
      report.check(size > 0U &&
                       validate_mavlink_frame(bytes.data(), size, decoded) ==
                           MavlinkParseStatus::FrameReady,
                   "download scheduler exposed a partial/invalid frame");
      if (drained_frames == 0U) {
        report.check(decoded.message_id == 0U,
                     "heartbeat was not kept ahead of parameter download");
      } else if (drained_frames == 1U) {
        report.check(decoded.message_id == 77U,
                     "urgent ACK was not kept ahead of parameter download");
      } else if (drained_frames < kParameterCount + 2U) {
        const std::uint16_t actual_index = static_cast<std::uint16_t>(
            static_cast<std::uint16_t>(decoded.payload()[6]) |
            static_cast<std::uint16_t>(
                static_cast<std::uint16_t>(decoded.payload()[7]) << 8U));
        report.check(decoded.message_id == 22U &&
                         actual_index == expected_index,
                     "PARAM_VALUE FIFO order/index changed");
        ++expected_index;
      } else {
        report.check(decoded.message_id == 42U,
                     "periodic MISSION_CURRENT was not deferred until after "
                     "the bounded parameter download");
      }
      report.check(scheduler.complete_send(TxResult::Accepted, size),
                   "download scheduler could not commit a complete frame");
      ++drained_frames;
    }
    report.check(drained_frames == kParameterCount + 3U &&
                     expected_index == kParameterCount &&
                     scheduler.diagnostics().frames_forwarded ==
                         kParameterCount + 3U &&
                     scheduler.diagnostics().queue_drop_frames == 0U,
                 "full parameter download did not drain exactly once");
    report.detail =
        "932 PARAM_VALUE frames retained and drained FIFO-exactly; heartbeat "
        "and COMMAND_ACK remained ahead while periodic MISSION_CURRENT was "
        "deferred until the bounded download completed.";
  } else if (test_id == "UT-MAV-013") {
    MavlinkFrameScheduler scheduler{};
    const auto first_payload = heartbeat_payload(31U);
    const auto second_payload = heartbeat_payload(32U);
    const MavlinkFrame first = make_v2(
        0x31U, 0U, first_payload.data(), first_payload.size(), report);
    const MavlinkFrame second = make_v2(
        0x32U, 0U, second_payload.data(), second_payload.size(), report);
    report.check(scheduler.enqueue(first, 1234U) ==
                         MavlinkEnqueueStatus::Queued &&
                     scheduler.enqueue(second, 2234U) ==
                         MavlinkEnqueueStatus::Queued,
                 "timestamped heartbeat candidates were not retained");

    const MavlinkHeartbeatCandidate queued =
        scheduler.heartbeat_candidate();
    report.check(queued.present && queued.tail_available && !queued.active &&
                     queued.order == 0U && queued.enqueued_ms == 1234U &&
                     queued.frame_bytes == first.size &&
                     queued.remaining_bytes == first.size,
                 "oldest heartbeat candidate metadata was incoherent");

    std::array<std::uint8_t, 8U> prefix{};
    const std::size_t prefix_size =
        scheduler.peek(prefix.data(), prefix.size());
    report.check(prefix_size == prefix.size(),
                 "heartbeat candidate prefix was not selectable");
    report.check(scheduler.complete_send(TxResult::Rejected, prefix_size),
                 "heartbeat candidate rejection was not accepted");
    const MavlinkHeartbeatCandidate rejected =
        scheduler.heartbeat_candidate();
    report.check(rejected.present && rejected.active &&
                     !rejected.active_started &&
                     rejected.order == queued.order &&
                     rejected.enqueued_ms == queued.enqueued_ms &&
                     rejected.remaining_bytes == first.size,
                 "rejected heartbeat identity/deadline was refreshed");

    report.check(scheduler.peek(prefix.data(), prefix.size()) == prefix.size() &&
                     scheduler.complete_send(TxResult::Accepted,
                                             prefix.size()),
                 "heartbeat candidate retry was not consumed");
    const MavlinkHeartbeatCandidate progressed =
        scheduler.heartbeat_candidate();
    report.check(progressed.present && progressed.active &&
                     progressed.active_started &&
                     progressed.order == queued.order &&
                     progressed.enqueued_ms == queued.enqueued_ms &&
                     progressed.remaining_bytes == first.size - prefix.size(),
                 "partial heartbeat progress changed its timing identity");

    std::array<std::uint8_t, kMavlinkMaxFrameBytes> remainder{};
    const std::size_t remainder_size =
        scheduler.peek(remainder.data(), remainder.size());
    report.check(remainder_size == first.size - prefix.size() &&
                     scheduler.complete_send(TxResult::Accepted,
                                             remainder_size),
                 "heartbeat candidate remainder did not complete");
    const MavlinkHeartbeatCandidate next =
        scheduler.heartbeat_candidate();
    report.check(next.present && next.order == 1U &&
                     next.enqueued_ms == 2234U &&
                     next.frame_bytes == second.size,
                 "candidate did not advance to the next retained heartbeat");
    report.detail =
        "Oldest heartbeat order/enqueue timestamp survived a rejected prefix "
        "and accepted partial progress without deadline refresh.";
  } else if (test_id == "FW-MAV-001") {
    // Most entries were extracted through reflection from the locally
    // installed Mission Planner 1.3.83 MAVLink.dll identified in
    // fixtures/mavlink/MANIFEST.md. PARAM_ERROR is backed by the separately
    // recorded live-Pixhawk/current-common.xml evidence there. This remains an
    // explicit allow-list, not an accept-unknown fallback.
    constexpr std::array<ExpectedMessageDefinition, 46> expected{{
        {0U, 50U, 9U, 9U},       // HEARTBEAT
        {4U, 237U, 14U, 14U},    // PING
        {11U, 89U, 6U, 6U},      // SET_MODE
        {20U, 214U, 20U, 20U},   // PARAM_REQUEST_READ
        {21U, 159U, 2U, 2U},     // PARAM_REQUEST_LIST
        {22U, 220U, 25U, 25U},   // PARAM_VALUE
        {23U, 168U, 23U, 23U},   // PARAM_SET
        {37U, 212U, 6U, 7U},     // MISSION_REQUEST_PARTIAL_LIST
        {38U, 9U, 6U, 7U},       // MISSION_WRITE_PARTIAL_LIST
        {39U, 254U, 37U, 38U},   // MISSION_ITEM
        {40U, 230U, 4U, 5U},     // MISSION_REQUEST
        {41U, 28U, 4U, 4U},      // MISSION_SET_CURRENT
        {42U, 28U, 2U, 6U},      // MISSION_CURRENT
        {43U, 132U, 2U, 3U},     // MISSION_REQUEST_LIST
        {44U, 221U, 4U, 5U},     // MISSION_COUNT
        {45U, 232U, 2U, 3U},     // MISSION_CLEAR_ALL
        {46U, 11U, 2U, 2U},      // MISSION_ITEM_REACHED
        {47U, 153U, 3U, 4U},     // MISSION_ACK
        {51U, 196U, 4U, 5U},     // MISSION_REQUEST_INT
        {53U, 3U, 5U, 5U},       // MISSION_CHECKSUM
        {66U, 148U, 6U, 6U},     // REQUEST_DATA_STREAM
        {69U, 243U, 11U, 30U},   // MANUAL_CONTROL
        {70U, 124U, 18U, 38U},   // RC_CHANNELS_OVERRIDE
        {73U, 38U, 37U, 38U},    // MISSION_ITEM_INT
        {75U, 158U, 35U, 35U},   // COMMAND_INT
        {76U, 152U, 33U, 33U},   // COMMAND_LONG
        {77U, 143U, 3U, 10U},    // COMMAND_ACK
        {84U, 143U, 53U, 53U},   // SET_POSITION_TARGET_LOCAL_NED
        {86U, 5U, 53U, 53U},     // SET_POSITION_TARGET_GLOBAL_INT
        {110U, 84U, 254U, 254U}, // FILE_TRANSFER_PROTOCOL
        {117U, 128U, 6U, 6U},    // LOG_REQUEST_LIST
        {118U, 56U, 14U, 14U},   // LOG_ENTRY
        {119U, 116U, 12U, 12U},  // LOG_REQUEST_DATA
        {120U, 134U, 97U, 97U},  // LOG_DATA
        {121U, 237U, 2U, 2U},    // LOG_ERASE
        {122U, 203U, 2U, 2U},    // LOG_REQUEST_END
        {148U, 178U, 60U, 78U},  // AUTOPILOT_VERSION
        {183U, 85U, 2U, 2U},     // AUTOPILOT_VERSION_REQUEST
        {242U, 104U, 52U, 60U},  // HOME_POSITION
        {253U, 83U, 51U, 54U},   // STATUSTEXT
        {320U, 243U, 20U, 20U},  // PARAM_EXT_REQUEST_READ
        {321U, 88U, 2U, 2U},     // PARAM_EXT_REQUEST_LIST
        {322U, 243U, 149U, 149U},  // PARAM_EXT_VALUE
        {323U, 78U, 147U, 147U},   // PARAM_EXT_SET
        {324U, 132U, 146U, 146U},  // PARAM_EXT_ACK
        {345U, 209U, 21U, 21U},    // PARAM_ERROR
    }};
    check_message_definitions(expected, report);

    for (const ExpectedMessageDefinition& item : expected) {
      MavlinkFrame minimum = make_minimum_v2(
          static_cast<std::uint8_t>(item.message_id), item.message_id, report);
      MavlinkFrame decoded{};
      report.check(validate_mavlink_frame(minimum.bytes.data(), minimum.size,
                                          decoded) ==
                           MavlinkParseStatus::FrameReady &&
                       same_bytes(minimum, decoded),
                   "startup/mission frame did not round-trip exactly");
    }

    constexpr std::array<std::uint32_t, 12> operator_and_log_ids{{
        4U, 11U, 69U, 70U, 84U, 86U,
        117U, 118U, 119U, 120U, 121U, 122U,
    }};
    GroundMavlinkIngressAdapter ground_ingress{};
    for (std::size_t item_index = 0U;
         item_index < operator_and_log_ids.size(); ++item_index) {
      const MavlinkFrame frame = make_minimum_v2(
          static_cast<std::uint8_t>(0xA0U + item_index),
          operator_and_log_ids[item_index], report);
      FrameIngressStatus status = FrameIngressStatus::NeedMore;
      for (std::size_t byte_index = 0U; byte_index < frame.size;
           ++byte_index) {
        status = ground_ingress.ingest_byte(frame.bytes[byte_index]);
      }
      report.check(status == FrameIngressStatus::Queued,
                   "valid operator/log frame did not pass Ground ingress");
    }
    report.check(ground_ingress.queued_frames() ==
                         operator_and_log_ids.size() &&
                     !ground_ingress.fail_closed(),
                 "operator/log Ground ingress count or state is incorrect");

    MavlinkMessageDefinition unknown{};
    std::uint8_t unknown_extra = 0xA5U;
    report.check(!mavlink_message_definition(999U, unknown) &&
                     !mavlink_crc_extra(999U, unknown_extra) &&
                     unknown_extra == 0U,
                 "unknown MAVLink message was not rejected fail-closed");
    MavlinkFrame unknown_wire = make_minimum_v2(0xE0U, 4U, report);
    unknown_wire.bytes[7] = 0xE7U;
    unknown_wire.bytes[8] = 0x03U;
    unknown_wire.bytes[9] = 0x00U;  // unknown msgid 999
    GroundMavlinkIngressAdapter unknown_ingress{};
    FrameIngressStatus unknown_status = FrameIngressStatus::NeedMore;
    for (std::size_t index = 0U; index < unknown_wire.size; ++index) {
      unknown_status = unknown_ingress.ingest_byte(unknown_wire.bytes[index]);
    }
    report.check(unknown_status == FrameIngressStatus::Invalid &&
                     unknown_ingress.queued_bytes() == 0U &&
                     unknown_ingress.queued_frames() == 0U,
                 "unknown msgid escaped Ground ingress fail-close parsing");
    report.detail =
        "46 connection/operator/parameter/command/mission/log definitions "
        "matched their recorded sources; unknown msgid remained closed.";
  } else if (test_id == "FW-MAV-002") {
    constexpr std::array<ExpectedMessageDefinition, 34> expected{{
        {1U, 124U, 31U, 31U},    // SYS_STATUS
        {2U, 137U, 12U, 12U},    // SYSTEM_TIME
        {24U, 24U, 30U, 52U},    // GPS_RAW_INT
        {27U, 144U, 26U, 29U},   // RAW_IMU
        {29U, 115U, 14U, 16U},   // SCALED_PRESSURE
        {30U, 39U, 28U, 28U},    // ATTITUDE
        {33U, 104U, 28U, 28U},   // GLOBAL_POSITION_INT
        {35U, 244U, 22U, 22U},   // RC_CHANNELS_RAW
        {36U, 222U, 21U, 37U},   // SERVO_OUTPUT_RAW
        {62U, 183U, 26U, 26U},   // NAV_CONTROLLER_OUTPUT
        {65U, 118U, 42U, 42U},   // RC_CHANNELS
        {74U, 20U, 20U, 20U},    // VFR_HUD
        {109U, 185U, 9U, 9U},    // RADIO_STATUS
        {111U, 34U, 16U, 16U},   // TIMESYNC
        {116U, 76U, 22U, 24U},   // SCALED_IMU2
        {124U, 87U, 35U, 57U},   // GPS2_RAW
        {125U, 203U, 6U, 6U},    // POWER_STATUS
        {147U, 154U, 36U, 54U},  // BATTERY_STATUS
        {150U, 134U, 42U, 42U},  // SENSOR_OFFSETS
        {152U, 208U, 4U, 8U},    // MEMINFO
        {162U, 189U, 8U, 9U},    // FENCE_STATUS
        {163U, 127U, 28U, 28U},  // AHRS
        {165U, 21U, 3U, 3U},     // HWSTATUS
        {166U, 21U, 9U, 9U},     // RADIO
        {168U, 1U, 12U, 12U},    // WIND
        {178U, 47U, 24U, 24U},   // AHRS2
        {182U, 229U, 40U, 40U},  // AHRS3
        {191U, 92U, 27U, 27U},   // MAG_CAL_PROGRESS
        {192U, 36U, 44U, 54U},   // MAG_CAL_REPORT
        {193U, 71U, 22U, 26U},   // EKF_STATUS_REPORT
        {194U, 98U, 25U, 33U},   // PID_TUNING
        {230U, 163U, 42U, 42U},  // ESTIMATOR_STATUS
        {241U, 90U, 32U, 32U},   // VIBRATION
        {245U, 130U, 2U, 2U},    // EXTENDED_SYS_STATE
    }};
    check_message_definitions(expected, report);
    for (const ExpectedMessageDefinition& item : expected) {
      const MavlinkFrame frame = make_minimum_v2(
          static_cast<std::uint8_t>(item.message_id + 1U),
          item.message_id, report);
      MavlinkStreamParser parser{};
      MavlinkFrame decoded{};
      report.check(feed(frame, parser, decoded, report) ==
                           MavlinkParseStatus::FrameReady &&
                       same_bytes(frame, decoded),
                   "Pixhawk telemetry/status frame was not parsed exactly");
    }
    report.detail =
        "34 Pixhawk telemetry/status definitions matched the local Mission "
        "Planner MAVLink.dll and round-tripped as complete frames.";
  } else if (test_id == "FW-SCHED-001") {
    constexpr std::array<std::uint32_t, 12> operator_and_log_ids{{
        4U, 11U, 69U, 70U, 84U, 86U,
        117U, 118U, 119U, 120U, 121U, 122U,
    }};
    for (std::size_t index = 0U; index < operator_and_log_ids.size();
         ++index) {
      MavlinkFrameScheduler operator_scheduler{};
      const MavlinkFrame frame = make_minimum_v2(
          static_cast<std::uint8_t>(0xC0U + index),
          operator_and_log_ids[index], report);
      report.check(operator_scheduler.enqueue(frame, 0U) ==
                           MavlinkEnqueueStatus::Queued &&
                       operator_scheduler.diagnostics()
                               .policy_filtered_frames == 0U &&
                       operator_scheduler.diagnostics()
                               .rate_limited_frames == 0U,
                   "operator/log message was filtered by the scheduler");
    }

    MavlinkFrameScheduler time_scheduler{};
    const MavlinkFrame system_time0 = make_minimum_v2(0xD0U, 2U, report);
    const MavlinkFrame system_time999 = make_minimum_v2(0xD1U, 2U, report);
    const MavlinkFrame system_time1000 = make_minimum_v2(0xD2U, 2U, report);
    const MavlinkFrame timesync0 = make_minimum_v2(0xD3U, 111U, report);
    const MavlinkFrame timesync999 = make_minimum_v2(0xD4U, 111U, report);
    const MavlinkFrame timesync1000 = make_minimum_v2(0xD5U, 111U, report);
    report.check(time_scheduler.enqueue(system_time0, 0U) ==
                         MavlinkEnqueueStatus::Queued &&
                     time_scheduler.enqueue(timesync0, 0U) ==
                         MavlinkEnqueueStatus::Queued,
                 "SYSTEM_TIME and TIMESYNC did not use independent buckets");
    report.check(time_scheduler.enqueue(system_time999, 999U) ==
                         MavlinkEnqueueStatus::Filtered &&
                     time_scheduler.enqueue(timesync999, 999U) ==
                         MavlinkEnqueueStatus::Filtered &&
                     time_scheduler.enqueue(system_time1000, 1000U) ==
                         MavlinkEnqueueStatus::Queued &&
                     time_scheduler.enqueue(timesync1000, 1000U) ==
                         MavlinkEnqueueStatus::Queued,
                 "SYSTEM_TIME/TIMESYNC 1 Hz boundaries are incorrect");
    report.check(time_scheduler.diagnostics().rate_limited_frames == 2U &&
                     time_scheduler.diagnostics().policy_filtered_frames ==
                         0U,
                 "time messages were completely policy-filtered");

    MavlinkFrameScheduler rate_scheduler{};
    const MavlinkFrame sys0 = make_minimum_v2(1U, 1U, report);
    const MavlinkFrame sys999 = make_minimum_v2(2U, 1U, report);
    const MavlinkFrame sys1000 = make_minimum_v2(3U, 1U, report);
    const MavlinkFrame power0 = make_minimum_v2(4U, 125U, report);
    const MavlinkFrame battery999 = make_minimum_v2(5U, 147U, report);
    const MavlinkFrame battery1000 = make_minimum_v2(6U, 147U, report);
    const MavlinkFrame pid = make_minimum_v2(7U, 194U, report);
    report.check(rate_scheduler.enqueue(sys0, 0U) ==
                         MavlinkEnqueueStatus::Queued &&
                     rate_scheduler.enqueue(sys999, 999U) ==
                         MavlinkEnqueueStatus::Filtered &&
                     rate_scheduler.enqueue(sys1000, 1000U) ==
                         MavlinkEnqueueStatus::Queued,
                 "SYS_STATUS 1 Hz inclusive boundary policy is incorrect");
    report.check(rate_scheduler.enqueue(power0, 0U) ==
                         MavlinkEnqueueStatus::Queued &&
                     rate_scheduler.enqueue(battery999, 999U) ==
                         MavlinkEnqueueStatus::Filtered &&
                     rate_scheduler.enqueue(battery1000, 1000U) ==
                         MavlinkEnqueueStatus::Queued,
                 "POWER/BATTERY shared 1 Hz bucket policy is incorrect");
    report.check(rate_scheduler.enqueue(pid, 1000U) ==
                         MavlinkEnqueueStatus::Filtered &&
                     rate_scheduler.diagnostics().rate_limited_frames == 2U &&
                     rate_scheduler.diagnostics().policy_filtered_frames ==
                         1U,
                 "rate/filter diagnostics are not exact");

    MavlinkFrameScheduler stream_scheduler{};
    MavlinkEnqueueStatus stream_status = MavlinkEnqueueStatus::NeedMore;
    for (std::size_t index = 0U; index < sys0.size; ++index) {
      stream_status = stream_scheduler.ingest_byte(sys0.bytes[index], 50U);
      if (index + 1U < sys0.size) {
        report.check(stream_status == MavlinkEnqueueStatus::NeedMore,
                     "timestamped ingest exposed a partial frame");
      }
    }
    report.check(stream_status == MavlinkEnqueueStatus::Queued,
                 "timestamped ingest did not queue a complete frame");
    for (std::size_t index = 0U; index < sys999.size; ++index) {
      stream_status =
          stream_scheduler.ingest_byte(sys999.bytes[index], 1049U);
    }
    report.check(stream_status == MavlinkEnqueueStatus::Filtered &&
                     stream_scheduler.diagnostics().rate_limited_frames == 1U,
                 "timestamped ingest bypassed the 1 Hz limiter");

    MavlinkFrameScheduler full_scheduler{};
    constexpr std::array<std::uint32_t, 8> telemetry_ids{{
        1U, 24U, 30U, 33U, 74U, 125U, 193U, 245U,
    }};
    for (std::size_t index = 0U; index < telemetry_ids.size(); ++index) {
      const MavlinkFrame telemetry = make_minimum_v2(
          static_cast<std::uint8_t>(20U + index), telemetry_ids[index],
          report);
      report.check(full_scheduler.enqueue(telemetry, 0U) ==
                       MavlinkEnqueueStatus::Queued,
                   "telemetry fixture did not fill all eight slots");
    }
    const MavlinkFrame urgent = make_minimum_v2(80U, 77U, report);
    const auto heartbeat_data = heartbeat_payload(0x12345678U);
    const MavlinkFrame heartbeat = make_v2(
        81U, 0U, heartbeat_data.data(), heartbeat_data.size(), report);
    const MavlinkFrame newest_telemetry =
        make_minimum_v2(82U, 74U, report);
    report.check(full_scheduler.enqueue(urgent, 0U) ==
                         MavlinkEnqueueStatus::Queued &&
                     full_scheduler.enqueue(heartbeat, 0U) ==
                         MavlinkEnqueueStatus::Queued &&
                     full_scheduler.enqueue(newest_telemetry, 1000U) ==
                         MavlinkEnqueueStatus::DroppedFull,
                 "full queue did not preserve heartbeat/urgent over telemetry");
    report.check(full_scheduler.size() ==
                         MavlinkFrameScheduler::capacity() &&
                     full_scheduler.diagnostics().queue_drop_frames == 3U,
                 "full queue drop/eviction accounting is incorrect");
    std::array<std::uint8_t, kMavlinkMaxFrameBytes> drained{};
    std::size_t drained_size = 0U;
    drain_frame(full_scheduler, drained, drained_size, report);
    report.check(drained_size == heartbeat.size && drained[4] == 81U,
                 "heartbeat did not remain first under a full queue");
    drain_frame(full_scheduler, drained, drained_size, report);
    report.check(drained_size == urgent.size && drained[4] == 80U,
                 "urgent response did not remain ahead of telemetry");
    report.detail =
        "Heartbeat > urgent > telemetry priority, shared 1 Hz buckets, "
        "policy filtering, and eight-slot full-queue eviction were exact.";
  } else {
    report.check(false, "unknown MAVLink unit test ID");
  }

  report.trace.record({0, "host", "MAVLINK_UNIT", 0,
                       report.passed ? "PASS" : "FAIL", true, 0, 0, 0});
  return report;
}

}  // namespace vc_lora::test
