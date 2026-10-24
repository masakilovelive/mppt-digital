#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

#include "../../../firmware/high_speed/vc_lora_high_speed_candidate.hpp"
#include "fixtures/mavlink_fixtures.hpp"
#include "vc_lora/bulk_tx_lease.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/mavlink_scheduler.hpp"

namespace vc_lora::test {
namespace {

bool same_frame(const MavlinkFrame& expected, const std::uint8_t* actual,
                std::size_t actual_size) {
  return actual != nullptr && actual_size == expected.size &&
         std::equal(expected.bytes.begin(),
                    expected.bytes.begin() + expected.size, actual);
}

MavlinkFrame signed_heartbeat(std::uint8_t sequence) {
  std::array<std::uint8_t, 9U> payload{};
  payload[4U] = 2U;
  payload[5U] = 3U;
  payload[7U] = 4U;
  payload[8U] = 3U;
  std::array<std::uint8_t, kMavlinkSignatureBytes> signature{};
  for (std::size_t index = 0U; index < signature.size(); ++index) {
    signature[index] = static_cast<std::uint8_t>(index + 1U);
  }
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 1U, 1U, 0U, payload.data(),
                          payload.size(), frame, 0x01U, 0U,
                          signature.data());
  return frame;
}

void test_start_guard_and_prestart_coalesce(TestReport& report) {
  MavlinkFrameScheduler blocked{};
  const MavlinkFrame blocked_heartbeat = fixtures::heartbeat_v2(1U);
  report.check(blocked.enqueue(blocked_heartbeat, 10U) ==
                   MavlinkEnqueueStatus::Queued,
               "blocked-start heartbeat was not queued");
  std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
  const std::size_t active_size =
      blocked.peek(output.data(), output.size());
  report.check(active_size == blocked_heartbeat.size &&
                   blocked.begin_bulk_heartbeat_policy(1000U) ==
                       MavlinkBulkHeartbeatPolicyStatus::BlockedByActiveFrame &&
                   !blocked.bulk_heartbeat_policy_active() &&
                   blocked.diagnostics().bulk_heartbeat_start_blocked_active ==
                       1U,
               "bulk policy started while scheduler already owned a frame");

  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame oldest = fixtures::heartbeat_v2(2U);
  const MavlinkFrame middle = fixtures::heartbeat_v2(3U);
  const MavlinkFrame newest = fixtures::heartbeat_v2(4U);
  report.check(scheduler.enqueue(oldest, 10U) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(middle, 20U) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(newest, 30U) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.size() == 3U &&
                   scheduler.queued_bytes() == 3U * newest.size,
               "pre-session heartbeats were not independently retained");

  report.check(scheduler.begin_bulk_heartbeat_policy(1000U) ==
                       MavlinkBulkHeartbeatPolicyStatus::Started &&
                   scheduler.begin_bulk_heartbeat_policy(1001U) ==
                       MavlinkBulkHeartbeatPolicyStatus::AlreadyActive &&
                   scheduler.bulk_heartbeat_policy_active() &&
                   scheduler.size() == 1U &&
                   scheduler.queued_bytes() == newest.size &&
                   !scheduler.has_active_frame(),
               "session start did not retain exactly one complete heartbeat");

  const MavlinkSchedulerDiagnostics& diagnostics = scheduler.diagnostics();
  report.check(diagnostics.frames_queued == 3U &&
                   diagnostics.queue_drop_frames == 0U &&
                   diagnostics.queue_drop_bytes == 0U &&
                   diagnostics.policy_filtered_frames == 0U &&
                   diagnostics.policy_filtered_bytes == 0U &&
                   diagnostics.bulk_heartbeat_sessions_started == 1U &&
                   diagnostics.bulk_heartbeat_prestart_seen_frames == 3U &&
                   diagnostics.bulk_heartbeat_prestart_seen_bytes ==
                       oldest.size + middle.size + newest.size &&
                   diagnostics.bulk_heartbeat_prestart_retained_frames == 1U &&
                   diagnostics.bulk_heartbeat_prestart_retained_bytes ==
                       newest.size &&
                   diagnostics.bulk_heartbeat_prestart_coalesced_frames == 2U &&
                   diagnostics.bulk_heartbeat_prestart_coalesced_bytes ==
                       oldest.size + middle.size,
               "pre-session coalescing diagnostics/accounting diverged");

  const std::size_t selected = scheduler.peek(output.data(), output.size());
  report.check(same_frame(newest, output.data(), selected),
               "session start retained an older heartbeat instead of newest");
}

void test_rolling_admission_and_exact_accounting(TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  report.check(scheduler.begin_bulk_heartbeat_policy(1000U) ==
                   MavlinkBulkHeartbeatPolicyStatus::Started,
               "empty bulk heartbeat policy did not start");

  const MavlinkFrame early = fixtures::heartbeat_v2(10U);
  const MavlinkFrame first = fixtures::heartbeat_v2(11U);
  const MavlinkFrame jitter = fixtures::heartbeat_v2(12U);
  const MavlinkFrame replacement = fixtures::heartbeat_v2(13U);
  const MavlinkFrame regressed = fixtures::heartbeat_v2(14U);
  report.check(scheduler.enqueue(early, 1999U) ==
                       MavlinkEnqueueStatus::Filtered &&
                   scheduler.enqueue(first, 2000U) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(jitter, 2500U) ==
                       MavlinkEnqueueStatus::Filtered &&
                   scheduler.enqueue(replacement, 3000U) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(regressed, 2999U) ==
                       MavlinkEnqueueStatus::Filtered,
               "rolling 1000 ms admission decisions changed");

  const MavlinkSchedulerDiagnostics& diagnostics = scheduler.diagnostics();
  report.check(scheduler.bulk_heartbeat_policy_active() &&
                   scheduler.size() == 1U &&
                   scheduler.queued_bytes() == replacement.size &&
                   diagnostics.frames_ingested == 5U &&
                   diagnostics.frames_queued == 2U &&
                   diagnostics.queue_drop_frames == 0U &&
                   diagnostics.queue_drop_bytes == 0U &&
                   diagnostics.policy_filtered_frames == 3U &&
                   diagnostics.policy_filtered_bytes == 3U * replacement.size &&
                   diagnostics.bulk_heartbeat_input_frames == 5U &&
                   diagnostics.bulk_heartbeat_input_bytes ==
                       5U * replacement.size &&
                   diagnostics.bulk_heartbeat_admitted_frames == 2U &&
                   diagnostics.bulk_heartbeat_admitted_bytes ==
                       2U * replacement.size &&
                   diagnostics.bulk_heartbeat_rate_violation_frames == 3U &&
                   diagnostics.bulk_heartbeat_rate_violation_bytes ==
                       3U * replacement.size &&
                   diagnostics.bulk_heartbeat_filtered_frames == 3U &&
                   diagnostics.bulk_heartbeat_filtered_bytes ==
                       3U * replacement.size &&
                   diagnostics.bulk_heartbeat_runtime_coalesced_frames == 1U &&
                   diagnostics.bulk_heartbeat_runtime_coalesced_bytes ==
                       replacement.size &&
                   diagnostics.bulk_heartbeat_time_regressions == 1U,
               "bulk heartbeat accounting did not conserve every input/frame");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
  const std::size_t size = scheduler.peek(output.data(), output.size());
  report.check(same_frame(replacement, output.data(), size),
               "allowed heartbeat did not replace the older pending candidate");
}

void test_active_heartbeat_is_never_replaced(TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame active = fixtures::heartbeat_v2(20U);
  const MavlinkFrame pending = fixtures::heartbeat_v2(21U);
  const MavlinkFrame newest = fixtures::heartbeat_v2(22U);
  report.check(scheduler.begin_bulk_heartbeat_policy(1000U) ==
                       MavlinkBulkHeartbeatPolicyStatus::Started &&
                   scheduler.enqueue(active, 2000U) ==
                       MavlinkEnqueueStatus::Queued,
               "active-heartbeat policy fixture did not start");

  std::array<std::uint8_t, 10U> prefix{};
  const std::size_t prefix_size = scheduler.peek(prefix.data(), prefix.size());
  report.check(prefix_size == prefix.size() &&
                   scheduler.complete_send(TxResult::Accepted, prefix_size) &&
                   scheduler.active_frame_is_heartbeat() &&
                   scheduler.active_frame_has_progress(),
               "could not establish an active split heartbeat");

  report.check(scheduler.enqueue(pending, 3000U) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(newest, 4000U) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.size() == 2U &&
                   scheduler.queued_bytes() ==
                       (active.size - prefix.size()) + newest.size,
               "pending coalescing replaced or duplicated the active heartbeat");

  const MavlinkSchedulerDiagnostics& diagnostics = scheduler.diagnostics();
  report.check(diagnostics.frames_queued == 3U &&
                   diagnostics.policy_filtered_frames == 0U &&
                   diagnostics.policy_filtered_bytes == 0U &&
                   diagnostics.bulk_heartbeat_runtime_coalesced_frames == 1U &&
                   diagnostics.bulk_heartbeat_runtime_coalesced_bytes ==
                       pending.size &&
                   diagnostics.queue_drop_frames == 0U,
               "active/pending heartbeat accounting changed");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
  const std::size_t remainder = scheduler.peek(output.data(), output.size());
  report.check(remainder == active.size - prefix.size() &&
                   std::equal(active.bytes.begin() + prefix.size(),
                              active.bytes.begin() + active.size,
                              output.begin()) &&
                   scheduler.complete_send(TxResult::Accepted, remainder),
               "active heartbeat bytes were replaced or truncated");
  const std::size_t next = scheduler.peek(output.data(), output.size());
  report.check(same_frame(newest, output.data(), next),
               "pending heartbeat was not the newest complete candidate");
}

void test_end_restores_standard_behavior(TestReport& report) {
  const std::array<MavlinkFrame, 3U> frames{
      fixtures::heartbeat_v2(30U), fixtures::heartbeat_v2(31U),
      fixtures::heartbeat_v2(32U)};

  MavlinkFrameScheduler reference{};
  for (std::size_t index = 0U; index < frames.size(); ++index) {
    report.check(reference.enqueue(frames[index], 1001U + index) ==
                     MavlinkEnqueueStatus::Queued,
                 "reference standard heartbeat was not queued");
  }

  MavlinkFrameScheduler restored{};
  report.check(restored.begin_bulk_heartbeat_policy(1000U) ==
                       MavlinkBulkHeartbeatPolicyStatus::Started &&
                   restored.end_bulk_heartbeat_policy() ==
                       MavlinkBulkHeartbeatPolicyStatus::Ended &&
                   restored.end_bulk_heartbeat_policy() ==
                       MavlinkBulkHeartbeatPolicyStatus::NotActive &&
                   !restored.bulk_heartbeat_policy_active(),
               "bulk heartbeat policy did not end explicitly");
  for (std::size_t index = 0U; index < frames.size(); ++index) {
    report.check(restored.enqueue(frames[index], 1001U + index) ==
                     MavlinkEnqueueStatus::Queued,
                 "post-session standard heartbeat was rate limited");
  }

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> expected{};
  std::array<std::uint8_t, kMavlinkMaxFrameBytes> actual{};
  for (const MavlinkFrame& frame : frames) {
    const std::size_t expected_size =
        reference.peek(expected.data(), expected.size());
    const std::size_t actual_size = restored.peek(actual.data(), actual.size());
    report.check(same_frame(frame, expected.data(), expected_size) &&
                     expected_size == actual_size &&
                     std::equal(expected.begin(), expected.begin() + expected_size,
                                actual.begin()) &&
                     reference.complete_send(TxResult::Accepted,
                                             expected_size) &&
                     restored.complete_send(TxResult::Accepted, actual_size),
                 "standard byte order changed after bulk policy ended");
  }

  const MavlinkSchedulerDiagnostics& reference_diag = reference.diagnostics();
  const MavlinkSchedulerDiagnostics& restored_diag = restored.diagnostics();
  report.check(reference_diag.frames_queued == 3U &&
                   restored_diag.frames_queued == 3U &&
                   reference_diag.frames_forwarded == 3U &&
                   restored_diag.frames_forwarded == 3U &&
                   reference_diag.bytes_forwarded ==
                       restored_diag.bytes_forwarded &&
                   reference_diag.policy_filtered_frames == 0U &&
                   restored_diag.policy_filtered_frames == 0U &&
                   restored_diag.bulk_heartbeat_sessions_started == 1U &&
                   restored_diag.bulk_heartbeat_sessions_ended == 1U,
               "standard accounting changed after policy end");
}

void check_unsupported_fallback(const MavlinkFrame& heartbeat,
                                TestReport& report,
                                const char* description) {
  MavlinkFrameScheduler scheduler{};
  report.check(scheduler.enqueue(heartbeat, 10U) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.begin_bulk_heartbeat_policy(1000U) ==
                       MavlinkBulkHeartbeatPolicyStatus::Started,
               description);
  BulkDataTxLease sender{scheduler, 0x5A4B3C2DU, 0U};
  report.check(sender.begin() == BulkDataTxLeaseStatus::UnsupportedFrame &&
                   sender.latched() && scheduler.size() == 1U &&
                   scheduler.queued_bytes() == heartbeat.size &&
                   scheduler.diagnostics().rejected_send_attempts == 1U,
               "unsupported retained heartbeat did not fail closed");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
  const std::size_t size = scheduler.peek(output.data(), output.size());
  report.check(same_frame(heartbeat, output.data(), size) &&
                   scheduler.complete_send(TxResult::Accepted, size),
               "unsupported retained heartbeat was unavailable to fallback");
}

void test_unsupported_heartbeats_fall_back(TestReport& report) {
  const MavlinkFrame mavlink1 = fixtures::heartbeat_v1(40U);
  const MavlinkFrame signed_frame = signed_heartbeat(41U);
  report.check(mavlink1.version == MavlinkVersion::V1 &&
                   signed_frame.version == MavlinkVersion::V2 &&
                   signed_frame.signed_frame && signed_frame.size == 34U,
               "unsupported heartbeat fixtures were malformed");
  check_unsupported_fallback(mavlink1, report,
                             "MAVLink1 heartbeat policy fixture failed");
  check_unsupported_fallback(signed_frame, report,
                             "signed heartbeat policy fixture failed");
}

void test_burst_keeps_one_pending_and_parameter_progress(TestReport& report) {
  using Contract = vc_lora::experimental::HighSpeedCandidateContract;
  constexpr std::uint64_t kPolicyIntervalMs =
      MavlinkFrameScheduler::bulk_heartbeat_admission_interval_ms();
  constexpr std::uint64_t kMaxHeartbeatFrames =
      1U + Contract::target_completion_ms / kPolicyIntervalMs;
  constexpr std::uint64_t kMaxHeartbeatChunks =
      kMaxHeartbeatFrames * Contract::heartbeat_wire_chunks_per_frame;
  constexpr std::uint64_t kChunkAirCeilingMs =
      (Contract::radio_chunk_bytes * 8U * 1000U +
       Contract::radio_air_bps - 1U) /
      Contract::radio_air_bps;
  // A heartbeat may arrive immediately after a two-chunk frame lease begins;
  // that frame must finish, then the two heartbeat chunks must finish.
  // A source just under 1 Hz (for example 999 ms jitter) can have one sample
  // filtered, so two admission intervals are the conservative scheduler
  // bound. The policy records that violation but does not latch permanently.
  constexpr std::uint64_t kMaxModeledHeartbeatGapMs =
      2U * kPolicyIntervalMs +
      4U * (kChunkAirCeilingMs + Contract::candidate_uart_write_gap_ms);
  static_assert(kPolicyIntervalMs == 1000U);
  static_assert(kMaxHeartbeatFrames ==
                Contract::sla_conservative_heartbeat_frames);
  static_assert(kMaxHeartbeatChunks ==
                Contract::sla_heartbeat_wire_chunks);
  static_assert(kMaxHeartbeatChunks == 62U);
  static_assert(kMaxModeledHeartbeatGapMs == 2068U);
  static_assert(kMaxModeledHeartbeatGapMs <=
                Contract::heartbeat_hard_deadline_ms);
  static_assert(!Contract::physical_30s_proven);

  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame parameter =
      fixtures::param_value_v2(50U, "BULK_PROGRESS", 1.5F, 0U, 932U);
  report.check(scheduler.enqueue(parameter, 0U) ==
                       MavlinkEnqueueStatus::Queued &&
                   scheduler.begin_bulk_heartbeat_policy(0U) ==
                       MavlinkBulkHeartbeatPolicyStatus::Started,
               "burst policy fixture did not start with PARAM_VALUE backlog");

  MavlinkFrame newest{};
  for (std::uint8_t sequence = 1U; sequence <= 30U; ++sequence) {
    newest = fixtures::heartbeat_v2(sequence);
    report.check(scheduler.enqueue(
                     newest, static_cast<std::uint64_t>(sequence) * 1000U) ==
                     MavlinkEnqueueStatus::Queued,
                 "one-per-second heartbeat was not admitted");
  }

  const MavlinkSchedulerDiagnostics& diagnostics = scheduler.diagnostics();
  report.check(scheduler.size() == 2U &&
                   scheduler.queued_bytes() == parameter.size + newest.size &&
                   diagnostics.frames_queued == 31U &&
                   diagnostics.bulk_heartbeat_admitted_frames == 30U &&
                   diagnostics.bulk_heartbeat_runtime_coalesced_frames == 29U &&
                   diagnostics.policy_filtered_frames == 0U &&
                   diagnostics.bulk_heartbeat_rate_violation_frames == 0U &&
                   diagnostics.queue_drop_frames == 0U,
               "30-second heartbeat burst exceeded one pending candidate");
  report.check(kMaxHeartbeatChunks == 62U &&
                   kMaxModeledHeartbeatGapMs <=
                       Contract::heartbeat_hard_deadline_ms &&
                   !Contract::physical_30s_proven,
               "heartbeat chunk/gap model exceeded its 30-second/SLA bound");

  BulkDataTxLease sender{scheduler, 0xC0FFEE01U, 0U};
  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready,
               "burst newest heartbeat was not bulk-selectable");
  BulkDataDecodedFragment decoded{};
  report.check(sender.current_fragment() != nullptr &&
                   BulkDataWireCodec::decode_fragment(
                       *sender.current_fragment(), decoded) ==
                       BulkDataWireStatus::FragmentReady &&
                   decoded.kind == BulkDataFragmentKind::HeartbeatHead &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FrameCommitted &&
                   sender.begin() == BulkDataTxLeaseStatus::Ready,
               "bounded heartbeat did not yield to PARAM_VALUE after commit");
  report.check(sender.current_fragment() != nullptr &&
                   BulkDataWireCodec::decode_fragment(
                       *sender.current_fragment(), decoded) ==
                       BulkDataWireStatus::FragmentReady &&
                   decoded.kind == BulkDataFragmentKind::ParameterHead,
               "PARAM_VALUE remained starved after the sole pending heartbeat");
  report.cycles = kMaxHeartbeatChunks;
}

}  // namespace

TestReport run_bulk_heartbeat_policy_test(const std::string& test_id,
                                          std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-BULK-HB-POLICY-001") {
    test_start_guard_and_prestart_coalesce(report);
  } else if (test_id == "UT-BULK-HB-POLICY-002") {
    test_rolling_admission_and_exact_accounting(report);
  } else if (test_id == "UT-BULK-HB-POLICY-003") {
    test_active_heartbeat_is_never_replaced(report);
  } else if (test_id == "UT-BULK-HB-POLICY-004") {
    test_end_restores_standard_behavior(report);
  } else if (test_id == "UT-BULK-HB-POLICY-005") {
    test_unsupported_heartbeats_fall_back(report);
  } else if (test_id == "UT-BULK-HB-POLICY-006") {
    test_burst_keeps_one_pending_and_parameter_progress(report);
  } else {
    report.check(false, "unknown bulk heartbeat policy test ID");
  }

  report.trace.record({0U, "host", "BULK_HEARTBEAT_POLICY", 0U,
                       report.passed ? "PASS" : "FAIL", true,
                       report.diagnostics.downlink_payload_bytes, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
