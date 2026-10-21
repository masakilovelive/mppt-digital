#include <cstddef>
#include <cstdint>
#include <iostream>
#include <limits>
#include <type_traits>

#include "../../../firmware/high_speed/r19_runtime_stage_record.hpp"

namespace vc_lora::experimental {
struct R19GroundUsbCommitRecordTestAccess final {
  static std::uint32_t word(const R19GroundUsbCommitRecord& record,
                            std::size_t slot) noexcept {
    return record.words_[slot];
  }
  static void begin_partial_write(R19GroundUsbCommitRecord& record) noexcept {
    record.begin_write();
    record.words_[20U] = 0xDEADBEEFU;
  }
  static void end_partial_write(R19GroundUsbCommitRecord& record) noexcept {
    record.commit_write();
  }
};
}  // namespace vc_lora::experimental

int main() {
  using namespace vc_lora::experimental;
  static_assert(sizeof(R19GroundUsbCommitRecord) == 128U);
  static_assert(std::is_standard_layout_v<R19GroundUsbCommitRecord>);
  static_assert(alignof(R19GroundUsbCommitRecord) == 4U);
  std::size_t checks = 0U;
  std::size_t failures = 0U;
  const auto check = [&](bool passed, const char* text) {
    ++checks;
    if (!passed) { ++failures; std::cerr << "FAIL: " << text << '\n'; }
  };
  constexpr R19RuntimeBuildFingerprint fingerprint{1U, 2U, 3U, 4U};
  R19GroundUsbCommitRecord record{};
  R19GroundUsbCommitSnapshot snapshot{};
  check(record.try_snapshot(snapshot) && !snapshot.valid_header(),
        "zero record must not claim an initialized identity");
  check(!record.initialize(R19RuntimeStageRole::Invalid, fingerprint),
        "invalid role must be rejected");
  check(record.initialize(R19RuntimeStageRole::Ground, fingerprint),
        "Ground identity rejected");
  check(record.try_snapshot(snapshot) && snapshot.valid_header() &&
            !snapshot.failure_latched() && snapshot.build_fingerprint == fingerprint,
        "initialized empty record must be unlatched");

  R19GroundUsbCommitEvidence evidence{};
  evidence.reason = R19GroundUsbCommitFailureReason::PublicationRejected;
  evidence.predicate_observed_mask = 7U;
  evidence.predicate_true_mask = 6U;
  evidence.source_line = 3178U;
  evidence.token = 0x12345678U;
  evidence.expected_epoch = 9U;
  evidence.observed_epoch = 9U;
  evidence.commit_started_ms = 0x1234567800000001ULL;
  evidence.flush_started_ms = 0x1234567800000007ULL;
  evidence.completed_ms = 0x123456780000006BULL;
  evidence.deadline_ms = 0x123456780000006BULL;
  evidence.committed_base = 0xABCDEF0100000000ULL;
  evidence.commit_goal = evidence.committed_base + 21U;
  evidence.bytes_committed = evidence.commit_goal;
  evidence.expected_frame_bytes = 21U;
  evidence.accepted_frame_bytes = 21U;
  auto malformed = evidence;
  malformed.predicate_observed_mask = 8U;
  check(!record.latch_first_failure(malformed), "unknown predicate bit accepted");
  malformed = evidence;
  malformed.predicate_observed_mask = 6U;
  malformed.predicate_true_mask = 7U;
  check(!record.latch_first_failure(malformed), "unobserved predicate marked true");
  malformed = evidence;
  malformed.accepted_frame_bytes = 22U;
  check(!record.latch_first_failure(malformed), "impossible accepted-byte count accepted");
  check(record.latch_first_failure(evidence), "first failure rejected");
  check(record.try_snapshot(snapshot) && snapshot.failure_latched() &&
            snapshot.reason == evidence.reason &&
            snapshot.predicate_observed_mask == 7U &&
            snapshot.predicate_true_mask == 6U &&
            snapshot.commit_started_ms == evidence.commit_started_ms &&
            snapshot.flush_started_ms == evidence.flush_started_ms &&
            snapshot.completed_ms == evidence.completed_ms &&
            snapshot.deadline_ms == evidence.deadline_ms &&
            snapshot.committed_base == evidence.committed_base &&
            snapshot.commit_goal == evidence.commit_goal &&
            snapshot.bytes_committed == evidence.bytes_committed &&
            snapshot.expected_frame_bytes == 21U &&
            snapshot.accepted_frame_bytes == 21U &&
            snapshot.expected_epoch == 9U && snapshot.observed_epoch == 9U,
        "first failed predicates, full-width clocks, or acceptance accounting lost");
  check(R19GroundUsbCommitRecordTestAccess::word(record, 2U) == 0x52313943U &&
            R19GroundUsbCommitRecordTestAccess::word(record, 9U) == 1U &&
            R19GroundUsbCommitRecordTestAccess::word(record, 10U) == 7U &&
            R19GroundUsbCommitRecordTestAccess::word(record, 11U) == 6U &&
            R19GroundUsbCommitRecordTestAccess::word(record, 16U) == 1U &&
            R19GroundUsbCommitRecordTestAccess::word(record, 17U) == 0x12345678U &&
            R19GroundUsbCommitRecordTestAccess::word(record, 24U) == 0U &&
            R19GroundUsbCommitRecordTestAccess::word(record, 25U) == 0xABCDEF01U &&
            R19GroundUsbCommitRecordTestAccess::word(record, 30U) == 21U &&
            R19GroundUsbCommitRecordTestAccess::word(record, 31U) == 21U,
        "raw JTAG word offsets or low/high field ordering changed");
  const auto stable_sequence = snapshot.sequence;
  evidence.source_line = 9999U;
  evidence.predicate_true_mask = 0U;
  evidence.completed_ms = std::numeric_limits<std::uint64_t>::max();
  check(!record.latch_first_failure(evidence) && record.try_snapshot(snapshot) &&
            snapshot.source_line == 3178U &&
            snapshot.sequence == stable_sequence && snapshot.predicate_true_mask == 6U,
        "later diagnostic overwrote the first product failure");

  record.reset();
  check(record.initialize(R19RuntimeStageRole::Vehicle, fingerprint) &&
            !record.latch_first_failure(evidence) &&
            record.try_snapshot(snapshot) && !snapshot.failure_latched(),
        "Vehicle must expose identity but must never latch Ground evidence");
  record.reset();
  check(record.initialize(R19RuntimeStageRole::Ground, fingerprint),
        "Ground reinitialization rejected");
  evidence.reason = R19GroundUsbCommitFailureReason::None;
  check(!record.latch_first_failure(evidence), "zero failure reason accepted");
  evidence.reason = R19GroundUsbCommitFailureReason::BeforeFlushDeadline;
  evidence.predicate_observed_mask = 6U;
  evidence.predicate_true_mask = 2U;
  evidence.completed_ms = evidence.deadline_ms + 1U;
  check(record.latch_first_failure(evidence) && record.try_snapshot(snapshot) &&
            snapshot.predicate_observed_mask == 6U &&
            snapshot.predicate_true_mask == 2U,
        "unobserved transport predicate confused with a failed USB flush");
  const auto sentinel = snapshot;
  R19GroundUsbCommitRecordTestAccess::begin_partial_write(record);
  check(!record.try_snapshot(snapshot, 1U) &&
            snapshot.completed_ms == sentinel.completed_ms &&
            snapshot.sequence == sentinel.sequence,
        "writer-active partial sample escaped the seqlock");
  R19GroundUsbCommitRecordTestAccess::end_partial_write(record);
  check(!record.try_snapshot(snapshot, 0U), "zero-attempt snapshot must not read");
  std::cout << "UT-R19-GROUND-USB-COMMIT-RECORD-001 checks=" << checks
            << " failures=" << failures << '\n';
  return failures == 0U ? 0 : 1;
}
