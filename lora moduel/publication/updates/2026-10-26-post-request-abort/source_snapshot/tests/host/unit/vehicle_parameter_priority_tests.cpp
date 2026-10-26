#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/embedded_io_adapter.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/mavlink_scheduler.hpp"

namespace vc_lora::test {
namespace {

constexpr std::array<std::uint8_t, 16U> kTargetId{{
    'S', 'E', 'R', 'I', 'A', 'L', '1', '_',
    'B', 'A', 'U', 'D', 0U, 0U, 0U, 0U}};

constexpr std::array<std::uint8_t, 16U> kStatRuntimeId{{
    'S', 'T', 'A', 'T', '_', 'R', 'U', 'N',
    'T', 'I', 'M', 'E', 0U, 0U, 0U, 0U}};

void write_u16(std::uint8_t* output, std::uint16_t value) {
  output[0U] = static_cast<std::uint8_t>(value & 0xFFU);
  output[1U] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
}

void write_u32(std::uint8_t* output, std::uint32_t value) {
  output[0U] = static_cast<std::uint8_t>(value & 0xFFU);
  output[1U] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
  output[2U] = static_cast<std::uint8_t>((value >> 16U) & 0xFFU);
  output[3U] = static_cast<std::uint8_t>((value >> 24U) & 0xFFU);
}

MavlinkFrame make_request(std::uint8_t sequence, std::uint16_t index,
                          const std::array<std::uint8_t, 16U>& id,
                          std::uint8_t target_system = 1U,
                          std::uint8_t target_component = 1U) {
  std::array<std::uint8_t, 20U> payload{};
  write_u16(payload.data(), index);
  payload[2U] = target_system;
  payload[3U] = target_component;
  std::copy(id.begin(), id.end(), payload.begin() + 4U);
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 20U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame make_list_request(std::uint8_t sequence,
                               std::uint8_t target_system = 1U,
                               std::uint8_t target_component = 1U) {
  const std::array<std::uint8_t, 2U> payload{{target_system,
                                              target_component}};
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 21U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame make_value(std::uint8_t sequence, std::uint16_t index,
                         const std::array<std::uint8_t, 16U>& id,
                         std::uint8_t source_system = 1U,
                         std::uint8_t source_component = 1U,
                         std::uint16_t count = 932U,
                         std::uint8_t type = 6U,
                         std::uint32_t value_bits = 0x42640000U,
                         MavlinkVersion version = MavlinkVersion::V2,
                         bool signed_frame = false) {
  std::array<std::uint8_t, 25U> payload{};
  write_u32(payload.data(), value_bits);
  write_u16(payload.data() + 4U, count);
  write_u16(payload.data() + 6U, index);
  std::copy(id.begin(), id.end(), payload.begin() + 8U);
  payload[24U] = type;
  MavlinkFrame frame{};
  if (version == MavlinkVersion::V1) {
    (void)encode_mavlink_v1(sequence, source_system, source_component, 22U,
                            payload.data(), payload.size(), frame);
  } else {
    constexpr std::array<std::uint8_t, kMavlinkSignatureBytes> signature{{
        1U, 2U, 3U, 4U, 5U, 6U, 7U, 8U, 9U, 10U, 11U, 12U, 13U}};
    (void)encode_mavlink_v2(
        sequence, source_system, source_component, 22U, payload.data(),
        payload.size(), frame, signed_frame ? 1U : 0U, 0U,
        signed_frame ? signature.data() : nullptr);
  }
  return frame;
}

MavlinkFrame make_heartbeat(std::uint8_t sequence) {
  constexpr std::array<std::uint8_t, 9U> payload{{
      0U, 0U, 0U, 0U, 2U, 3U, 0x51U, 4U, 3U}};
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 1U, 1U, 0U, payload.data(),
                          payload.size(), frame);
  return frame;
}

bool same_wire(const MavlinkFrame& left, const MavlinkFrame& right) {
  return left.size == right.size &&
         std::equal(left.bytes.begin(), left.bytes.begin() + left.size,
                    right.bytes.begin());
}

bool take_frame(MavlinkFrameScheduler& scheduler, MavlinkFrame& frame,
                TxResult result = TxResult::Accepted) {
  std::array<std::uint8_t, kMavlinkMaxFrameBytes> wire{};
  const std::size_t size = scheduler.peek(wire.data(), wire.size());
  if (size == 0U ||
      validate_mavlink_frame(wire.data(), size, frame) !=
          MavlinkParseStatus::FrameReady) {
    return false;
  }
  return scheduler.complete_send(result, size);
}

struct PhysicalChunkResult {
  bool accepted{false};
  bool completed_heartbeat{false};
  bool completed_target{false};
};

PhysicalChunkResult service_physical_chunk(
    MavlinkFrameScheduler& scheduler) {
  std::array<std::uint8_t, 32U> application{};
  const std::uint64_t frames_before =
      scheduler.diagnostics().frames_forwarded;
  const std::uint64_t targets_before =
      scheduler.diagnostics().target_parameter_frames_completed;
  const std::size_t available =
      scheduler.peek(application.data(), application.size());
  const bool heartbeat = scheduler.active_frame_is_heartbeat();
  const EncodedLinkDataChunk wire =
      encode_link_data(application.data(), available, 32U);
  PhysicalChunkResult result{};
  result.accepted = wire.input_consumed > 0U && wire.wire_size == 32U &&
                    scheduler.complete_send(TxResult::Accepted,
                                            wire.input_consumed);
  result.completed_heartbeat =
      result.accepted && heartbeat &&
      scheduler.diagnostics().frames_forwarded == frames_before + 1U;
  result.completed_target =
      result.accepted &&
      scheduler.diagnostics().target_parameter_frames_completed ==
          targets_before + 1U;
  return result;
}

std::uint16_t value_index(const MavlinkFrame& frame) {
  if (frame.message_id != 22U || frame.payload_length != 25U) {
    return 0xFFFFU;
  }
  return static_cast<std::uint16_t>(frame.payload()[6U]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(frame.payload()[7U]) << 8U);
}

struct D6WriterProbe {
  int availableForWrite() const noexcept { return 256; }

  std::size_t write(const std::uint8_t*, std::size_t count) noexcept {
    ++write_calls;
    accepted_bytes += count;
    return count;
  }

  std::size_t write_calls{0U};
  std::size_t accepted_bytes{0U};
};

void check_backlog_bound(TestReport& report) {
  static_assert(MavlinkFrameScheduler::parameter_request_capacity() == 8U,
                "request tracker must remain fixed and bounded");
  static_assert(MavlinkFrameScheduler::target_parameter_capacity() == 8U,
                "target priority lane must remain fixed and bounded");
  MavlinkFrameScheduler scheduler{};
  constexpr std::uint16_t kOldValues = 18U;
  std::array<std::uint8_t, 16U> old_id{};
  old_id[0U] = 'O';
  for (std::uint16_t index = 0U; index < kOldValues; ++index) {
    old_id[1U] = static_cast<std::uint8_t>(index);
    report.check(scheduler.enqueue(make_value(
                         static_cast<std::uint8_t>(index), index, old_id)) ==
                     MavlinkEnqueueStatus::Queued,
                 "old PARAM_VALUE backlog fixture did not enqueue");
  }

  const MavlinkFrame request = make_request(80U, 0xFFFFU, kTargetId);
  const MavlinkFrame target = make_value(96U, 0xFFFFU, kTargetId);
  report.check(scheduler.remember_parameter_request(request) ==
                       MavlinkParameterRequestStatus::Remembered &&
                   scheduler.enqueue(target) == MavlinkEnqueueStatus::Queued,
               "target request/response was not admitted to the priority lane");

  // Production TDD/service model: the response becomes visible at the uplink
  // terminal, the fixed 650-ms ReturnGuard runs, then the 3000-ms downlink
  // window offers one physically encoded 32-byte E220 write per 550-ms service
  // floor. A real 1-Hz Pixhawk heartbeat continues throughout. A matching
  // response may yield to at most the heartbeat already due when it arrives.
  constexpr std::uint64_t kServiceMs = 550U;
  constexpr std::uint64_t kReturnGuardMs = 650U;
  constexpr std::uint64_t kDownlinkWindowMs = 3000U;
  constexpr std::uint64_t kDeadlineMs = 30'000U;
  std::uint64_t now_ms = kReturnGuardMs;
  std::uint64_t next_heartbeat_ms = 0U;
  std::uint64_t target_completion_ms = kDeadlineMs + 1U;
  std::uint8_t heartbeat_sequence = 0xC0U;
  std::vector<std::uint64_t> heartbeat_completions;
  std::uint64_t frames_before_target = 0U;
  while (now_ms <= kDeadlineMs && target_completion_ms > kDeadlineMs) {
    while (next_heartbeat_ms <= now_ms) {
      report.check(scheduler.enqueue(make_heartbeat(heartbeat_sequence++),
                                     next_heartbeat_ms) ==
                           MavlinkEnqueueStatus::Queued,
                   "1 Hz heartbeat fixture overflowed before target");
      next_heartbeat_ms += 1000U;
    }
    const PhysicalChunkResult service = service_physical_chunk(scheduler);
    report.check(service.accepted,
                 "production service model could not accept an E220 chunk");
    now_ms += kServiceMs;
    if (service.completed_heartbeat) {
      heartbeat_completions.push_back(now_ms);
    }
    if (service.completed_target) {
      target_completion_ms = now_ms;
      frames_before_target = scheduler.diagnostics().frames_forwarded - 1U;
    }
  }
  report.check(target_completion_ms <= kDeadlineMs,
               "matching target exceeded the 30 s completion bound");
  report.check(target_completion_ms <=
                   kReturnGuardMs + kDownlinkWindowMs,
               "matching target escaped the first production downlink window");
  report.check(frames_before_target <= 1U,
               "more than one pending heartbeat preceded the target");

  // Complete the heartbeat that arrived while the target frame was active.
  while (heartbeat_completions.size() < 2U && now_ms <= kDeadlineMs) {
    while (next_heartbeat_ms <= now_ms) {
      report.check(scheduler.enqueue(make_heartbeat(heartbeat_sequence++),
                                     next_heartbeat_ms) ==
                           MavlinkEnqueueStatus::Queued,
                   "1 Hz heartbeat fixture overflowed after target");
      next_heartbeat_ms += 1000U;
    }
    const PhysicalChunkResult service = service_physical_chunk(scheduler);
    report.check(service.accepted,
                 "post-target heartbeat service did not accept a chunk");
    now_ms += kServiceMs;
    if (service.completed_heartbeat) {
      heartbeat_completions.push_back(now_ms);
    }
  }
  const std::uint64_t heartbeat_gap_ms =
      heartbeat_completions.size() >= 2U
          ? heartbeat_completions[1U] - heartbeat_completions[0U]
          : kDeadlineMs + 1U;
  report.check(heartbeat_completions.size() >= 2U &&
                   heartbeat_gap_ms <= 2500U,
               "target priority violated the 2500-ms heartbeat gap bound");

  std::vector<std::uint16_t> old_order;
  while (!scheduler.empty()) {
    MavlinkFrame selected{};
    report.check(take_frame(scheduler, selected),
                 "post-target backlog did not drain");
    if (selected.message_id == 22U) {
      old_order.push_back(value_index(selected));
    }
  }
  report.check(old_order.size() == kOldValues,
               "generic PARAM_VALUE backlog lost or duplicated a frame");
  for (std::uint16_t index = 0U; index < kOldValues; ++index) {
    report.check(old_order[index] == index,
                 "generic PARAM_VALUE FIFO was reordered by target priority");
  }
  report.check(scheduler.diagnostics().target_parameter_frames_queued == 1U &&
                   scheduler.diagnostics().target_parameter_selections == 1U &&
                   scheduler.diagnostics().target_parameter_frames_completed ==
                       1U &&
                   scheduler.diagnostics().target_heartbeat_yields <= 1U,
               "target priority diagnostics do not prove the bounded path");
  report.detail =
      "18 old PARAM_VALUE + 1 Hz HEARTBEAT + target 19th completed within " +
      std::to_string(target_completion_ms) +
      " ms in the fixed TDD/550-ms production service model; heartbeat gap " +
      std::to_string(heartbeat_gap_ms) +
      " ms.";
}

void check_retry_and_duplicate(TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame request = make_request(81U, 0xFFFFU, kTargetId);
  const MavlinkFrame target = make_value(97U, 0xFFFFU, kTargetId);
  report.check(scheduler.remember_parameter_request(request) ==
                       MavlinkParameterRequestStatus::Remembered &&
                   scheduler.enqueue(target) == MavlinkEnqueueStatus::Queued,
               "retry target setup failed");

  std::array<std::uint8_t, 16U> first{};
  const std::size_t first_size = scheduler.peek(first.data(), first.size());
  report.check(first_size == first.size() &&
                   std::equal(first.begin(), first.end(), target.bytes.begin()),
               "target first chunk is not byte exact");
  report.check(scheduler.complete_send(TxResult::Rejected, first_size),
               "target first transmission rejection was not retained");

  std::array<std::uint8_t, 16U> retry{};
  const std::size_t retry_size = scheduler.peek(retry.data(), retry.size());
  report.check(retry_size == first_size && retry == first,
               "rejected target retry changed or advanced bytes");
  report.check(scheduler.enqueue(target) == MavlinkEnqueueStatus::Filtered,
               "duplicate target response was not suppressed while pending");
  report.check(scheduler.complete_send(TxResult::Accepted, retry_size),
               "accepted target retry did not consume its chunk");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> remainder{};
  const std::size_t remainder_size =
      scheduler.peek(remainder.data(), remainder.size());
  report.check(remainder_size == target.size - retry_size &&
                   std::equal(remainder.begin(),
                              remainder.begin() + remainder_size,
                              target.bytes.begin() + retry_size),
               "target retry remainder is not the exact frame suffix");
  report.check(scheduler.complete_send(TxResult::Accepted, remainder_size) &&
                   scheduler.empty(),
               "target did not complete exactly once after retry");

  const auto& diagnostics = scheduler.diagnostics();
  report.check(diagnostics.target_parameter_frames_queued == 1U &&
                   diagnostics.target_parameter_duplicate_frames == 1U &&
                   diagnostics.target_parameter_selections == 1U &&
                   diagnostics.target_parameter_chunks_forwarded == 2U &&
                   diagnostics.target_parameter_frames_completed == 1U &&
                   diagnostics.target_parameter_rejected_attempts == 1U,
               "retry/duplicate target diagnostics are not exact");
  report.detail =
      "First target RF attempt rejected, byte-exact retry accepted in two "
      "chunks, duplicate suppressed, one completion recorded.";
}

void check_identity_match(TestReport& report) {
  MavlinkFrameScheduler bounded{};
  std::array<std::uint8_t, 16U> empty_id{};
  report.check(bounded.remember_parameter_request(
                       make_request(0xF0U, 0xFFFFU, empty_id)) ==
                   MavlinkParameterRequestStatus::Invalid,
               "semantically empty ID-addressed request was remembered");
  for (std::uint16_t index = 0U;
       index < MavlinkFrameScheduler::parameter_request_capacity(); ++index) {
    report.check(bounded.remember_parameter_request(
                         make_request(static_cast<std::uint8_t>(index),
                                      index, empty_id)) ==
                     MavlinkParameterRequestStatus::Remembered,
                 "bounded request tracker rejected an in-capacity identity");
  }
  report.check(bounded.remember_parameter_request(
                       make_request(9U, 0U, empty_id)) ==
                       MavlinkParameterRequestStatus::Duplicate &&
                   bounded.remember_parameter_request(
                       make_request(10U, 100U, empty_id)) ==
                       MavlinkParameterRequestStatus::Full &&
                   bounded.pending_parameter_requests() ==
                       MavlinkFrameScheduler::parameter_request_capacity(),
               "request tracker duplicate/full behavior is not bounded");
  for (std::uint16_t index = 0U;
       index < MavlinkFrameScheduler::target_parameter_capacity(); ++index) {
    report.check(bounded.enqueue(make_value(
                         static_cast<std::uint8_t>(0xA0U + index), index,
                         kTargetId)) == MavlinkEnqueueStatus::Queued,
                 "in-capacity target response was dropped");
  }
  report.check(bounded.prioritized_parameter_values() ==
                       MavlinkFrameScheduler::target_parameter_capacity() &&
                   bounded.pending_parameter_requests() ==
                       MavlinkFrameScheduler::parameter_request_capacity() &&
                   bounded.diagnostics().queue_drop_frames == 0U,
               "equal-sized target lane did not retain every tracked response");
  for (std::uint16_t expected = 0U;
       expected < MavlinkFrameScheduler::target_parameter_capacity();
       ++expected) {
    MavlinkFrame target{};
    report.check(take_frame(bounded, target) &&
                     value_index(target) == expected,
                 "bounded target priority lane changed response order");
  }
  report.check(bounded.pending_parameter_requests() == 0U &&
                   bounded.prioritized_parameter_values() == 0U,
               "completed target lane retained request ownership");
  bounded.reset();
  report.check(bounded.pending_parameter_requests() == 0U &&
                   bounded.prioritized_parameter_values() == 0U &&
                   bounded.diagnostics().parameter_requests_observed == 0U,
               "scheduler reset retained request/target priority state");

  MavlinkFrameScheduler scheduler{};
  std::array<std::uint8_t, 16U> wrong_id = kTargetId;
  wrong_id[0U] = 'X';
  const MavlinkFrame request_by_id =
      make_request(82U, 0xFFFFU, kTargetId, 1U, 1U);
  report.check(scheduler.remember_parameter_request(request_by_id) ==
                   MavlinkParameterRequestStatus::Remembered,
               "ID-addressed request was not remembered");
  report.check(scheduler.enqueue(make_value(1U, 0xFFFFU, wrong_id)) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(make_value(2U, 0xFFFFU, kTargetId,
                                                2U, 1U)) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(make_value(3U, 0xFFFFU, kTargetId,
                                                1U, 2U)) ==
                       MavlinkEnqueueStatus::Queued,
               "nonmatching identity fixtures did not enter generic FIFO");
  const MavlinkFrame exact_by_id =
      make_value(4U, 0xFFFFU, kTargetId, 1U, 1U);
  report.check(scheduler.enqueue(exact_by_id) ==
                   MavlinkEnqueueStatus::Queued,
               "exact ID/sys/comp response did not enter target lane");

  MavlinkFrame selected{};
  report.check(take_frame(scheduler, selected) &&
                   same_wire(selected, exact_by_id),
               "exact ID/sys/comp response was not selected first");

  const MavlinkFrame request_by_index =
      make_request(83U, 321U, empty_id, 1U, 1U);
  const MavlinkFrame exact_by_index =
      make_value(5U, 321U, wrong_id, 1U, 1U);
  report.check(scheduler.remember_parameter_request(request_by_index) ==
                       MavlinkParameterRequestStatus::Remembered &&
                   scheduler.enqueue(exact_by_index) ==
                       MavlinkEnqueueStatus::Queued &&
                   take_frame(scheduler, selected) &&
                   same_wire(selected, exact_by_index),
               "index-addressed response did not match index/sys/comp");
  report.check(scheduler.pending_parameter_requests() == 0U,
               "completed exact responses retained stale request identities");

  // MAVLink defines param_id as unused when param_index addresses the
  // request. Retransmits with the same index/target identity must therefore
  // coalesce even if those unused bytes differ.
  MavlinkFrameScheduler index_duplicates{};
  std::array<std::uint8_t, 16U> unused_id_a{};
  std::array<std::uint8_t, 16U> unused_id_b{};
  unused_id_a[0U] = 'A';
  unused_id_b[0U] = 'B';
  report.check(
      index_duplicates.remember_parameter_request(
          make_request(0x30U, 701U, unused_id_a, 9U, 10U)) ==
              MavlinkParameterRequestStatus::Remembered &&
          index_duplicates.remember_parameter_request(
              make_request(0x31U, 701U, unused_id_b, 9U, 10U)) ==
              MavlinkParameterRequestStatus::Duplicate &&
          index_duplicates.pending_parameter_requests() == 1U,
      "index-addressed duplicate incorrectly depended on unused param_id");

  // One response may legitimately match an older ID-addressed request and a
  // newer index-addressed request. Pending ownership takes precedence over
  // queued-duplicate filtering so two arrivals satisfy the two slots exactly;
  // only the third arrival is a duplicate.
  MavlinkFrameScheduler overlap{};
  std::array<std::uint8_t, 16U> overlap_id{};
  std::array<std::uint8_t, 16U> overlap_unused{};
  overlap_id[0U] = 'O';
  overlap_id[1U] = 'V';
  overlap_unused[0U] = 'X';
  const MavlinkFrame overlapping_response =
      make_value(0x42U, 444U, overlap_id, 1U, 1U);
  report.check(
      overlap.remember_parameter_request(
          make_request(0x40U, 0xFFFFU, overlap_id, 1U, 1U)) ==
              MavlinkParameterRequestStatus::Remembered &&
          overlap.remember_parameter_request(
              make_request(0x41U, 444U, overlap_unused, 1U, 1U)) ==
              MavlinkParameterRequestStatus::Remembered &&
          overlap.enqueue(overlapping_response) ==
              MavlinkEnqueueStatus::Queued &&
          overlap.enqueue(overlapping_response) ==
              MavlinkEnqueueStatus::Queued &&
          overlap.enqueue(overlapping_response) ==
              MavlinkEnqueueStatus::Filtered,
      "mixed ID/index overlap did not assign each pending request before "
      "duplicate filtering");
  MavlinkFrame overlap_first{};
  MavlinkFrame overlap_second{};
  report.check(take_frame(overlap, overlap_first) &&
                   take_frame(overlap, overlap_second) &&
                   same_wire(overlap_first, overlapping_response) &&
                   same_wire(overlap_second, overlapping_response) &&
                   overlap.pending_parameter_requests() == 0U &&
                   overlap.prioritized_parameter_values() == 0U &&
                   overlap.diagnostics().target_parameter_frames_queued ==
                       2U &&
                   overlap.diagnostics().target_parameter_frames_completed ==
                       2U &&
                   overlap.diagnostics().target_parameter_duplicate_frames ==
                       1U,
               "mixed overlap did not complete two owned slots exactly once");

  // target_system/component zero are MAVLink broadcast wildcards. Non-zero
  // targets remain strict and mismatches stay in the unchanged generic FIFO.
  MavlinkFrameScheduler wildcard{};
  const MavlinkFrame wildcard_response =
      make_value(0x52U, 601U, unused_id_a, 77U, 88U);
  const MavlinkFrame strict_mismatch =
      make_value(0x53U, 602U, unused_id_b, 3U, 5U);
  const MavlinkFrame strict_exact =
      make_value(0x54U, 602U, unused_id_b, 3U, 4U);
  report.check(
      wildcard.remember_parameter_request(
          make_request(0x50U, 601U, unused_id_b, 0U, 0U)) ==
              MavlinkParameterRequestStatus::Remembered &&
          wildcard.remember_parameter_request(
              make_request(0x51U, 602U, unused_id_a, 3U, 4U)) ==
              MavlinkParameterRequestStatus::Remembered &&
          wildcard.enqueue(strict_mismatch) == MavlinkEnqueueStatus::Queued &&
          wildcard.enqueue(wildcard_response) == MavlinkEnqueueStatus::Queued &&
          wildcard.enqueue(strict_exact) == MavlinkEnqueueStatus::Queued,
      "wildcard/strict target fixtures were not admitted");
  MavlinkFrame wildcard_selected{};
  report.check(take_frame(wildcard, wildcard_selected) &&
                   same_wire(wildcard_selected, wildcard_response) &&
                   take_frame(wildcard, wildcard_selected) &&
                   same_wire(wildcard_selected, strict_exact) &&
                   take_frame(wildcard, wildcard_selected) &&
                   same_wire(wildcard_selected, strict_mismatch),
               "broadcast wildcard promotion or strict mismatch FIFO failed");
  report.detail =
      "Index mode ignores unused param_id; Pending owns overlapping responses "
      "before duplicate filtering; target 0/0 is a MAVLink broadcast wildcard.";
}

void check_active_boundary(TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  std::array<std::uint8_t, 16U> old_id{};
  old_id[0U] = 'O';
  const MavlinkFrame old_first = make_value(10U, 10U, old_id);
  const MavlinkFrame old_second = make_value(11U, 11U, old_id);
  const MavlinkFrame request = make_request(84U, 0xFFFFU, kTargetId);
  const MavlinkFrame target = make_value(98U, 0xFFFFU, kTargetId);
  report.check(scheduler.enqueue(old_first) == MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(old_second) == MavlinkEnqueueStatus::Queued,
               "active-boundary generic backlog setup failed");

  std::array<std::uint8_t, 7U> prefix{};
  const std::size_t prefix_size = scheduler.peek(prefix.data(), prefix.size());
  report.check(prefix_size == prefix.size() &&
                   scheduler.complete_send(TxResult::Accepted, prefix_size),
               "generic PARAM_VALUE prefix did not become active");
  report.check(scheduler.remember_parameter_request(request) ==
                       MavlinkParameterRequestStatus::Remembered &&
                   scheduler.enqueue(target) == MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(make_heartbeat(0xD0U)) ==
                       MavlinkEnqueueStatus::Queued,
               "target/heartbeat did not enqueue behind active frame");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> suffix{};
  const std::size_t suffix_size = scheduler.peek(suffix.data(), suffix.size());
  report.check(suffix_size == old_first.size - prefix_size &&
                   std::equal(suffix.begin(), suffix.begin() + suffix_size,
                              old_first.bytes.begin() + prefix_size),
               "target split a partially-sent generic frame");
  report.check(scheduler.complete_send(TxResult::Accepted, suffix_size),
               "generic active frame remainder did not complete");

  MavlinkFrame selected{};
  report.check(take_frame(scheduler, selected) && selected.message_id == 0U,
               "one already-pending heartbeat was not allowed before target");
  report.check(scheduler.enqueue(make_heartbeat(0xD1U)) ==
                       MavlinkEnqueueStatus::Queued &&
                   !scheduler.heartbeat_tail_available(),
               "second heartbeat tail remained eligible ahead of target");
  report.check(take_frame(scheduler, selected) && same_wire(selected, target),
               "target did not immediately follow the one heartbeat yield");
  report.check(take_frame(scheduler, selected) && selected.message_id == 0U,
               "heartbeat queued behind target was not retained");
  report.check(take_frame(scheduler, selected) &&
                   same_wire(selected, old_second),
               "remaining generic FIFO frame was dropped or reordered");
  report.detail =
      "A partially-sent generic PARAM_VALUE stayed atomic; one heartbeat then "
      "target priority followed at complete-frame boundaries.";
}

void check_native_list_fence(TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  constexpr std::uint16_t kStaleValues = 18U;
  constexpr std::uint16_t kFreshValues = 932U;
  std::array<std::uint8_t, 16U> stale_id{};
  stale_id[0U] = 'O';
  std::array<std::uint8_t, 16U> first_other_id{};
  first_other_id[0U] = 'O';
  first_other_id[1U] = 1U;
  for (std::uint16_t index = 0U; index < kStaleValues; ++index) {
    stale_id[1U] = static_cast<std::uint8_t>(index);
    const MavlinkFrame stale = index == 0U
                                   ? make_value(0U, 0xFFFFU, kStatRuntimeId)
                                   : make_value(
                                         static_cast<std::uint8_t>(index),
                                         index, stale_id);
    report.check(scheduler.enqueue(stale) == MavlinkEnqueueStatus::Queued,
                 "native fence stale backlog fixture did not enqueue");
  }
  const MavlinkFrame retained_heartbeat = make_heartbeat(0xE0U);
  report.check(scheduler.enqueue(retained_heartbeat, 0U) ==
                   MavlinkEnqueueStatus::Queued,
               "native fence heartbeat fixture did not enqueue");

  const MavlinkFrame list = make_list_request(0xE1U);
  report.check(scheduler.can_begin_native_parameter_list() &&
                   scheduler.begin_native_parameter_list(list, 30'000U) ==
                       MavlinkParameterRequestStatus::Remembered,
               "native list session fence did not commit at a clean frame boundary");
  report.check(scheduler.parameter_download_queued_frames() == 0U &&
                   scheduler.size() == 1U &&
                   scheduler.pending_parameter_requests() == 0U,
               "native fence removed a non-PARAM frame or retained stale PARAM");
  report.check(
      scheduler.diagnostics().native_list_fences_committed == 1U &&
          scheduler.diagnostics().native_list_stale_frames_cancelled ==
              kStaleValues &&
          scheduler.diagnostics().native_list_stale_bytes_cancelled ==
              static_cast<std::uint64_t>(kStaleValues) * 37U &&
          scheduler.diagnostics()
                  .native_list_stat_runtime_frames_cancelled == 1U &&
          scheduler.diagnostics()
                  .native_list_stat_runtime_bytes_cancelled == 37U &&
          scheduler.diagnostics().native_list_other_frames_cancelled ==
              kStaleValues - 1U &&
          scheduler.diagnostics().native_list_other_bytes_cancelled ==
              static_cast<std::uint64_t>(kStaleValues - 1U) * 37U,
      "native fence cancellation diagnostics are not exact");

  report.check(scheduler.enqueue(
                       make_value(0xE2U, 0xFFFFU, kStatRuntimeId),
                       31'000U) == MavlinkEnqueueStatus::Filtered &&
                   scheduler.enqueue(
                       make_value(0xE3U, 0xFFFFU, kStatRuntimeId),
                       62'000U) == MavlinkEnqueueStatus::Filtered &&
                   scheduler.enqueue(make_value(0xE4U, 17U, stale_id),
                                     63'000U) ==
                        MavlinkEnqueueStatus::Filtered &&
                   scheduler.parameter_download_queued_frames() == 0U &&
                   scheduler.diagnostics().native_list_stale_frames_filtered ==
                       3U &&
                   scheduler.diagnostics()
                           .native_list_stat_runtime_frames_filtered == 2U &&
                   scheduler.diagnostics().native_list_other_frames_filtered ==
                       1U &&
                   scheduler.diagnostics()
                           .native_list_stat_runtime_first_filter_ms == 31'000U &&
                   scheduler.diagnostics()
                           .native_list_stat_runtime_last_filter_ms == 62'000U &&
                   scheduler.diagnostics()
                           .native_list_stat_runtime_min_filter_gap_ms == 31'000U &&
                   scheduler.diagnostics()
                           .native_list_stat_runtime_filter_time_regressions ==
                       0U,
               "post-fence nonzero D7 residue entered the fresh list FIFO");
  report.check(
      scheduler.diagnostics().native_list_unexpected_latched == 1U &&
          scheduler.diagnostics().native_list_unexpected_reason == 1U &&
          scheduler.diagnostics().native_list_stale_classification_errors ==
              0U &&
          scheduler.diagnostics().native_list_unexpected_mismatch_mask ==
              0x0300U &&
          scheduler.diagnostics().native_list_unexpected_version == 2U &&
          scheduler.diagnostics().native_list_unexpected_signed == 0U &&
          scheduler.diagnostics().native_list_unexpected_frame_size == 37U &&
          scheduler.diagnostics().native_list_unexpected_payload_length == 25U &&
          scheduler.diagnostics().native_list_unexpected_system_id == 1U &&
          scheduler.diagnostics().native_list_unexpected_component_id == 1U &&
          scheduler.diagnostics().native_list_unexpected_sequence == 1U &&
          scheduler.diagnostics().native_list_unexpected_index == 1U &&
          scheduler.diagnostics().native_list_unexpected_count == 932U &&
          scheduler.diagnostics().native_list_unexpected_type == 6U &&
          scheduler.diagnostics().native_list_unexpected_value_bits ==
              0x42640000U &&
          scheduler.diagnostics().native_list_unexpected_parameter_id ==
              first_other_id &&
          scheduler.diagnostics().native_list_unexpected_ms == 30'000U,
      "first non-STAT native exclusion was not latched byte-exactly");

  std::array<std::uint8_t, 16U> fresh_id{};
  fresh_id[0U] = 'N';
  for (std::uint16_t index = 0U; index < kFreshValues; ++index) {
    fresh_id[1U] = static_cast<std::uint8_t>(index & 0xFFU);
    report.check(scheduler.enqueue(make_value(
                         static_cast<std::uint8_t>(index), index,
                         fresh_id)) == MavlinkEnqueueStatus::Queued,
                  "fresh native PARAM_VALUE did not fit the fixed FIFO");
  }
  report.check(
      scheduler.enqueue(make_value(0xE5U, 17U, stale_id), 92'000U) ==
              MavlinkEnqueueStatus::Filtered &&
          scheduler.enqueue(make_value(0xE6U, 0xFFFFU, kStatRuntimeId),
                            93'000U) == MavlinkEnqueueStatus::Filtered &&
          scheduler.diagnostics().native_list_stale_frames_filtered == 5U &&
          scheduler.diagnostics().native_list_other_frames_filtered == 2U &&
          scheduler.diagnostics().native_list_stat_runtime_frames_filtered ==
              3U &&
          scheduler.diagnostics().native_list_stat_runtime_last_filter_ms ==
              93'000U &&
          scheduler.diagnostics().native_list_stat_runtime_min_filter_gap_ms ==
              31'000U,
      "Complete-state native exclusions escaped exact classification");
  report.check(scheduler.parameter_download_queued_frames() == kFreshValues,
               "fresh native list FIFO depth is not exactly 932");

  MavlinkFrame selected{};
  report.check(take_frame(scheduler, selected) &&
                   same_wire(selected, retained_heartbeat),
               "native fence changed heartbeat-first scheduling");
  for (std::uint16_t index = 0U; index < kFreshValues; ++index) {
    report.check(take_frame(scheduler, selected) &&
                     value_index(selected) == index,
                 "fresh native list lost strict 0..931 FIFO order");
  }
  report.check(scheduler.empty() &&
                   scheduler.diagnostics().queue_drop_frames == 0U,
               "fresh native list did not drain without overflow/drop");

  // Exercise the cancellation classifier with both fixed rings wrapped.  The
  // first 768 dequeues move the heads near the end; 768 replacements cross
  // the frame-array boundary and the 64-KiB byte-array boundary.
  MavlinkFrameScheduler wrapped{};
  bool wrapped_ok = true;
  for (std::size_t index = 0U;
       index < MavlinkFrameScheduler::parameter_download_frame_capacity();
       ++index) {
    wrapped_ok &=
        wrapped.enqueue(make_value(static_cast<std::uint8_t>(index),
                                   0xFFFFU, kStatRuntimeId)) ==
        MavlinkEnqueueStatus::Queued;
  }
  for (std::size_t index = 0U; index < 768U; ++index) {
    MavlinkFrame discarded{};
    wrapped_ok &= take_frame(wrapped, discarded);
  }
  for (std::size_t index = 0U; index < 768U; ++index) {
    wrapped_ok &=
        wrapped.enqueue(make_value(static_cast<std::uint8_t>(index + 17U),
                                   0xFFFFU, kStatRuntimeId)) ==
        MavlinkEnqueueStatus::Queued;
  }
  wrapped_ok &=
      wrapped.begin_native_parameter_list(list, 120'000U) ==
      MavlinkParameterRequestStatus::Remembered;
  const auto& wrapped_diagnostics = wrapped.diagnostics();
  wrapped_ok &= wrapped_diagnostics.native_list_stale_frames_cancelled ==
                    MavlinkFrameScheduler::parameter_download_frame_capacity() &&
                wrapped_diagnostics.native_list_stale_bytes_cancelled ==
                    37U * MavlinkFrameScheduler::
                              parameter_download_frame_capacity() &&
                wrapped_diagnostics.native_list_stat_runtime_frames_cancelled ==
                    MavlinkFrameScheduler::parameter_download_frame_capacity() &&
                wrapped_diagnostics.native_list_stat_runtime_bytes_cancelled ==
                    37U * MavlinkFrameScheduler::
                              parameter_download_frame_capacity() &&
                wrapped_diagnostics.native_list_other_frames_cancelled == 0U &&
                wrapped_diagnostics.native_list_other_bytes_cancelled == 0U &&
                wrapped_diagnostics.native_list_stale_classification_errors ==
                    0U &&
                wrapped_diagnostics.native_list_unexpected_latched == 0U;
  report.check(wrapped_ok,
               "native cancellation classification failed across ring wrap");

  MavlinkFrameScheduler partial{};
  const MavlinkFrame partial_old = make_value(0xE2U, 7U, stale_id);
  report.check(partial.enqueue(partial_old) == MavlinkEnqueueStatus::Queued,
               "partial native fence fixture did not enqueue");
  std::array<std::uint8_t, 7U> prefix{};
  const std::size_t prefix_size = partial.peek(prefix.data(), prefix.size());
  report.check(prefix_size == prefix.size() &&
                   partial.complete_send(TxResult::Accepted, prefix_size) &&
                   !partial.can_begin_native_parameter_list() &&
                   partial.begin_native_parameter_list(list) ==
                       MavlinkParameterRequestStatus::Busy,
               "native fence did not reject a partially active old frame");
  std::array<std::uint8_t, kMavlinkMaxFrameBytes> suffix{};
  const std::size_t suffix_size = partial.peek(suffix.data(), suffix.size());
  report.check(suffix_size == partial_old.size - prefix_size &&
                   std::equal(suffix.begin(), suffix.begin() + suffix_size,
                              partial_old.bytes.begin() + prefix_size) &&
                   partial.complete_send(TxResult::Accepted, suffix_size) &&
                   partial.empty() &&
                   partial.diagnostics().native_list_fence_busy == 1U &&
                   partial.diagnostics().native_list_stale_frames_cancelled ==
                       0U,
               "busy native fence split or discarded the active old frame");

  // The accepted sentinel has two deliberately variable fields.  Neither a
  // different runtime value nor a different MAVLink sequence may turn an
  // otherwise exact STAT_RUNTIME into an exclusion failure.
  MavlinkFrameScheduler dynamic_exact{};
  constexpr std::uint32_t kDynamicValueBits = 0x4A123456U;
  const MavlinkFrame dynamic_stat = make_value(
      0xA7U, 0xFFFFU, kStatRuntimeId, 1U, 1U, 932U, 6U,
      kDynamicValueBits);
  report.check(
      dynamic_stat.size == 37U &&
          dynamic_exact.enqueue(dynamic_stat, 12'000U) ==
              MavlinkEnqueueStatus::Queued &&
          dynamic_exact.begin_native_parameter_list(list, 12'345U) ==
              MavlinkParameterRequestStatus::Remembered &&
          dynamic_exact.diagnostics()
                  .native_list_stat_runtime_frames_cancelled == 1U &&
          dynamic_exact.diagnostics()
                  .native_list_stat_runtime_bytes_cancelled == 37U &&
          dynamic_exact.diagnostics().native_list_other_frames_cancelled ==
              0U &&
          dynamic_exact.diagnostics().native_list_other_bytes_cancelled ==
              0U &&
          dynamic_exact.diagnostics().native_list_unexpected_latched == 0U &&
          dynamic_exact.diagnostics()
                  .native_list_stale_classification_errors == 0U,
      "dynamic STAT_RUNTIME value/sequence was not accepted as exact");

  struct NearMissCase {
    const char* label;
    MavlinkFrame frame;
    std::uint16_t expected_mask;
  };
  std::array<std::uint8_t, 16U> bad_padding = kStatRuntimeId;
  bad_padding[15U] = 0x58U;
  const std::array<NearMissCase, 8U> near_misses{{
      {"source", make_value(0xB0U, 0xFFFFU, kStatRuntimeId, 2U, 1U),
       0x0020U},
      {"component", make_value(0xB1U, 0xFFFFU, kStatRuntimeId, 1U, 2U),
       0x0040U},
      {"count", make_value(0xB2U, 0xFFFFU, kStatRuntimeId, 1U, 1U, 931U),
       0x0080U},
      {"index", make_value(0xB3U, 0xFFFEU, kStatRuntimeId), 0x0100U},
      {"id_padding", make_value(0xB4U, 0xFFFFU, bad_padding), 0x0200U},
      {"type", make_value(0xB5U, 0xFFFFU, kStatRuntimeId, 1U, 1U, 932U,
                           9U),
       0x0400U},
      {"mavlink_v1", make_value(0xB6U, 0xFFFFU, kStatRuntimeId, 1U, 1U,
                                 932U, 6U, 0x42640000U,
                                 MavlinkVersion::V1),
       0x0005U},
      {"signed_size", make_value(0xB7U, 0xFFFFU, kStatRuntimeId, 1U, 1U,
                                  932U, 6U, 0x42640000U,
                                  MavlinkVersion::V2, true),
       0x0006U},
  }};
  for (std::size_t index = 0U; index < near_misses.size(); ++index) {
    MavlinkFrameScheduler near_miss{};
    const NearMissCase& fixture = near_misses[index];
    const std::uint64_t fence_ms = 70'000U + index;
    report.check(
        near_miss.enqueue(fixture.frame, fence_ms - 1U) ==
                MavlinkEnqueueStatus::Queued &&
            near_miss.begin_native_parameter_list(list, fence_ms) ==
                MavlinkParameterRequestStatus::Remembered &&
            near_miss.diagnostics().native_list_stale_frames_cancelled == 1U &&
            near_miss.diagnostics().native_list_stale_bytes_cancelled ==
                fixture.frame.size &&
            near_miss.diagnostics()
                    .native_list_stat_runtime_frames_cancelled == 0U &&
            near_miss.diagnostics().native_list_other_frames_cancelled == 1U &&
            near_miss.diagnostics().native_list_other_bytes_cancelled ==
                fixture.frame.size &&
            near_miss.diagnostics().native_list_stale_classification_errors ==
                0U &&
            near_miss.diagnostics().native_list_unexpected_latched == 1U &&
            near_miss.diagnostics().native_list_unexpected_reason == 1U &&
            near_miss.diagnostics().native_list_unexpected_mismatch_mask ==
                fixture.expected_mask &&
            near_miss.diagnostics().native_list_unexpected_sequence ==
                fixture.frame.sequence &&
            near_miss.diagnostics().native_list_unexpected_frame_size ==
                fixture.frame.size &&
            near_miss.diagnostics().native_list_unexpected_ms == fence_ms,
        std::string("STAT_RUNTIME near-miss escaped classification: ") +
            fixture.label);
  }
  report.check(near_misses[6U].frame.size == 33U &&
                   near_misses[7U].frame.size == 50U,
               "V1/signed fixtures did not exercise the frame-size predicate");

  // No valid unsigned MAVLink2 PARAM_VALUE can differ from 37 bytes.  An
  // explicitly malformed size must fail validation before it can enter either
  // native exclusion class.
  MavlinkFrameScheduler invalid_size{};
  MavlinkFrame truncated = make_value(0xB8U, 0xFFFFU, kStatRuntimeId);
  --truncated.size;
  report.check(
      invalid_size.enqueue(truncated, 80'000U) ==
              MavlinkEnqueueStatus::Invalid &&
          invalid_size.diagnostics().invalid_frames == 1U &&
          invalid_size.diagnostics().native_list_stale_frames_cancelled == 0U &&
          invalid_size.diagnostics().native_list_stale_frames_filtered == 0U &&
          invalid_size.diagnostics().native_list_unexpected_latched == 0U,
      "invalid PARAM_VALUE size reached native exclusion classification");

  // Cadence is evidence, not an assumed Pixhawk rate: retain the first/last
  // times and minimum monotonic gap while making a clock regression explicit.
  MavlinkFrameScheduler cadence{};
  report.check(cadence.begin_native_parameter_list(list, 30'000U) ==
                   MavlinkParameterRequestStatus::Remembered,
               "cadence native fence setup failed");
  report.check(
      cadence.enqueue(make_value(0xC0U, 0xFFFFU, kStatRuntimeId, 1U, 1U,
                                 932U, 6U, 0x41000000U),
                      31'000U) == MavlinkEnqueueStatus::Filtered &&
          cadence.enqueue(make_value(0xC1U, 0xFFFFU, kStatRuntimeId, 1U, 1U,
                                     932U, 6U, 0x42000000U),
                          62'000U) == MavlinkEnqueueStatus::Filtered &&
          cadence.enqueue(make_value(0xC2U, 0xFFFFU, kStatRuntimeId, 1U, 1U,
                                     932U, 6U, 0x43000000U),
                          61'000U) == MavlinkEnqueueStatus::Filtered &&
          cadence.enqueue(make_value(0xC3U, 0xFFFFU, kStatRuntimeId, 1U, 1U,
                                     932U, 6U, 0x44000000U),
                          92'000U) == MavlinkEnqueueStatus::Filtered &&
          cadence.diagnostics().native_list_stale_frames_filtered == 4U &&
          cadence.diagnostics().native_list_stat_runtime_frames_filtered ==
              4U &&
          cadence.diagnostics().native_list_other_frames_filtered == 0U &&
          cadence.diagnostics().native_list_stat_runtime_first_filter_ms ==
              31'000U &&
          cadence.diagnostics().native_list_stat_runtime_last_filter_ms ==
              92'000U &&
          cadence.diagnostics().native_list_stat_runtime_min_filter_gap_ms ==
              31'000U &&
          cadence.diagnostics()
                  .native_list_stat_runtime_filter_time_regressions == 1U &&
          cadence.diagnostics().native_list_unexpected_latched == 0U,
      "STAT_RUNTIME cadence/regression evidence is not exact");

  report.detail =
      "A clean #21 fence classified every cancelled/filtered PARAM_VALUE, "
      "latched the first non-STAT_RUNTIME tuple, retained heartbeat priority, "
      "admitted ordered 0..931, and refused to split an active frame.";
}

void check_phase6_wiring(TestReport& report) {
#if defined(VC_LORA_SOURCE_ROOT)
  const std::filesystem::path bridge_path =
      std::filesystem::path(VC_LORA_SOURCE_ROOT) / "firmware" / "phase6" /
      "vc_lora_phase6_bridge.hpp";
#else
  const std::filesystem::path bridge_path =
      std::filesystem::path("firmware") / "phase6" /
      "vc_lora_phase6_bridge.hpp";
#endif
  std::ifstream input(bridge_path, std::ios::binary);
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());
  report.check(input.good() || input.eof(),
               "canonical Phase 6 adapter could not be read");

  const std::size_t observer =
      source.find("bool remember_vehicle_parameter_requests(");
  const std::size_t preflight_function =
      source.find("bool preflight_vehicle_uplink_transaction(");
  const std::size_t native_can_begin = source.find(
      "vehicle_scheduler.can_begin_native_parameter_list()",
      preflight_function);
  const std::size_t parser =
      source.find("MavlinkStreamParser parser{}", observer);
  const std::size_t remember = source.find(
      "vehicle_scheduler.remember_parameter_request(frame)", parser);
  const std::size_t full_guard = source.find(
      "request_status == MavlinkParameterRequestStatus::Full", remember);
  const std::size_t invalid_guard = source.find(
      "request_status == MavlinkParameterRequestStatus::Invalid", full_guard);
  const std::size_t native_fence = source.find(
      "vehicle_scheduler.begin_native_parameter_list(frame, now_ms)", observer);
  const std::size_t busy_guard = source.find(
      "request_status == MavlinkParameterRequestStatus::Busy", native_fence);
  report.check(preflight_function != std::string::npos &&
                   native_can_begin > preflight_function &&
                   observer != std::string::npos && parser > observer &&
                   remember > parser && full_guard > remember &&
                   invalid_guard > full_guard && native_fence > observer &&
                   busy_guard > native_fence,
               "Phase 6 lacks complete-frame request identity observation "
               "and bounded #20/#21 fail-stop guards");

  const std::size_t commit = source.find(
      "bool vehicle_commit_uplink_transaction(std::uint64_t now_ms) noexcept");
  const std::size_t native_preflight = source.find(
      "preflight_vehicle_uplink_transaction(", commit);
  const std::size_t d6_admission = source.find(
      "radio_application_endpoint.egress().ingest(", commit);
  const std::size_t observe_after_admission = source.find(
      "remember_vehicle_parameter_requests(", d6_admission);
  const std::size_t observe_timestamp =
      source.find("committed_frames, now_ms)", observe_after_admission);
  const std::size_t forward_accounting = source.find(
      "link_diagnostics.mavlink_frames_forwarded += committed_frames",
      observe_after_admission);
  report.check(commit != std::string::npos && native_preflight > commit &&
                    native_preflight < d6_admission && d6_admission > commit &&
                    observe_after_admission > d6_admission &&
                    observe_timestamp > observe_after_admission &&
                    observe_timestamp - observe_after_admission < 220U &&
                    forward_accounting > observe_after_admission,
               "Phase 6 did not preflight #21 before D6 admission, then "
               "commit the #20/#21 tracker fence before forwarding completion");
  report.check(preflight_function < commit && native_can_begin < commit &&
                   native_fence < commit && busy_guard < commit,
               "Phase 6 does not fail-stop a Busy native list fence around "
               "the exact D6 admission boundary");
  const std::size_t failed_commit = source.find(
      "!vehicle_commit_uplink_transaction(now_ms)", forward_accounting);
  const std::size_t failed_commit_latch =
      source.find("latch_runtime_fail_closed();", failed_commit);
  report.check(failed_commit != std::string::npos &&
                   failed_commit_latch > failed_commit &&
                   failed_commit_latch - failed_commit < 240U,
               "Phase 6 did not latch tracker-induced commit failure");
  const std::size_t production_candidate = source.find(
      "vehicle_scheduler.heartbeat_candidate()");
  const std::size_t production_fairness = source.find(
      "input.heartbeat_tail_available = heartbeat.tail_available;",
      production_candidate);
  report.check(production_candidate != std::string::npos &&
                   production_fairness > production_candidate,
               "Phase 6 heartbeat candidate bypasses target fairness");

#if defined(VC_LORA_SOURCE_ROOT)
  const std::filesystem::path e2e_sim_path =
      std::filesystem::path(VC_LORA_SOURCE_ROOT) / "tests" / "host" /
      "integration" / "mavlink_e2e_sim.cpp";
#else
  const std::filesystem::path e2e_sim_path =
      std::filesystem::path("tests") / "host" / "integration" /
      "mavlink_e2e_sim.cpp";
#endif
  std::ifstream e2e_input(e2e_sim_path, std::ios::binary);
  const std::string e2e_source((std::istreambuf_iterator<char>(e2e_input)),
                               std::istreambuf_iterator<char>());
  const std::size_t e2e_heartbeat_assignment = e2e_source.find(
      "vehicle_input.heartbeat_tail_available =");
  const std::size_t e2e_production_hint = e2e_source.find(
      "heartbeat.tail_available;",
      e2e_heartbeat_assignment);
  report.check(
      (e2e_input.good() || e2e_input.eof()) &&
          e2e_heartbeat_assignment != std::string::npos &&
          e2e_production_hint > e2e_heartbeat_assignment &&
          e2e_production_hint - e2e_heartbeat_assignment < 160U,
      "MavlinkE2eSimulation heartbeat-tail hint differs from production");

  const std::size_t vehicle_loop = source.find(
      "#if defined(VC_LORA_PHASE6_VEHICLE)",
      source.find("void loop_bridge() noexcept"));
  const std::size_t deliver =
      source.find("deliver_radio_bytes(now_ms);", vehicle_loop);
  const std::size_t collect =
      source.find("collect_local_ingress(now_ms);", deliver);
  const std::size_t fail_closed_before_d6 = source.find(
      "if (!bridge_ready || runtime_fail_closed)", collect);
  const std::size_t d6_pump = source.find(
      "pump_local_egress(radio_application_endpoint.egress(), "
      "pixhawk_serial);",
      collect);
  report.check(vehicle_loop != std::string::npos && deliver > vehicle_loop &&
                   collect > deliver && fail_closed_before_d6 > collect &&
                   d6_pump > fail_closed_before_d6,
               "Vehicle loop can pump D6 after delivery/ingress latched "
               "fail-closed");

  // Behavioral companion to the source-order regression: Phase6 first owns
  // the committed bytes in its D6 queue, then tracker Full/Invalid latches the
  // runtime stop. The mandatory pre-pump guard must leave both physical write
  // and D6 commit accounting at zero.
  auto check_failed_tracker_d6_gate =
      [&report](MavlinkFrameScheduler& tracker,
                const MavlinkFrame& failing_request,
                MavlinkParameterRequestStatus expected,
                const char* label) {
        VehicleLocalEgressAdapter d6{};
        D6WriterProbe writer{};
        bool bridge_ready = true;
        bool runtime_fail_closed = false;
        std::uint64_t commit_count = 0U;
        report.check(d6.ingest(failing_request.bytes.data(),
                               failing_request.size) == failing_request.size,
                     std::string(label) + " D6 admission fixture failed");
        const MavlinkParameterRequestStatus status =
            tracker.remember_parameter_request(failing_request);
        if (status == MavlinkParameterRequestStatus::Full ||
            status == MavlinkParameterRequestStatus::Invalid) {
          runtime_fail_closed = true;
          bridge_ready = false;
        } else {
          ++commit_count;
        }
        if (bridge_ready && !runtime_fail_closed) {
          (void)pump_local_egress_if_connected(d6, writer, true);
        }
        report.check(status == expected && writer.write_calls == 0U &&
                         writer.accepted_bytes == 0U && commit_count == 0U &&
                         d6.stats().bytes_committed == 0U,
                     std::string(label) +
                         " tracker failure leaked a D6 write/commit");
      };

  std::array<std::uint8_t, 16U> empty_id{};
  MavlinkFrameScheduler full_tracker{};
  for (std::uint16_t index = 0U;
       index < MavlinkFrameScheduler::parameter_request_capacity(); ++index) {
    report.check(full_tracker.remember_parameter_request(make_request(
                     static_cast<std::uint8_t>(0x80U + index), index,
                     empty_id)) == MavlinkParameterRequestStatus::Remembered,
                 "Full-path request tracker setup failed");
  }
  check_failed_tracker_d6_gate(
      full_tracker, make_request(0x90U, 900U, empty_id),
      MavlinkParameterRequestStatus::Full, "Full");

  MavlinkFrameScheduler invalid_tracker{};
  check_failed_tracker_d6_gate(
      invalid_tracker, make_request(0x91U, 0xFFFFU, empty_id),
      MavlinkParameterRequestStatus::Invalid, "Invalid");
  report.detail =
      "Canonical Phase 6 observes each validated uplink frame after D6 FIFO "
      "admission; Full/Invalid stops before a physical D6 write or commit.";
}

}  // namespace

TestReport run_vehicle_parameter_priority_test(const std::string& test_id,
                                               std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id == "UT-VEHICLE-PARAM-PRIORITY-BACKLOG-001") {
    check_backlog_bound(report);
  } else if (test_id == "UT-VEHICLE-PARAM-PRIORITY-RETRY-001") {
    check_retry_and_duplicate(report);
  } else if (test_id == "UT-VEHICLE-PARAM-PRIORITY-MATCH-001") {
    check_identity_match(report);
  } else if (test_id == "UT-VEHICLE-PARAM-PRIORITY-BOUNDARY-001") {
    check_active_boundary(report);
  } else if (test_id ==
             "UT-VEHICLE-PARAM-PRIORITY-NATIVE-FENCE-001") {
    check_native_list_fence(report);
  } else if (test_id == "UT-VEHICLE-PARAM-PRIORITY-PHASE6-001") {
    check_phase6_wiring(report);
  } else {
    report.check(false, "unknown Vehicle target-priority test ID");
  }
  report.trace.record({0U, "host", "VEHICLE_PARAM_PRIORITY", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
