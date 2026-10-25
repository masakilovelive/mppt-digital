#include <array>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <limits>
#include <type_traits>

#include "../../../firmware/high_speed/r19_runtime_stage_record.hpp"

namespace vc_lora::experimental {

struct R19RuntimeStageRecordTestAccess final {
  static std::uint32_t active_writer(
      const R19RuntimeStageRecord& record) noexcept {
    return record.active_writer_;
  }

  static std::uint32_t sequence(
      const R19RuntimeStageRecord& record) noexcept {
    return record.sequence_;
  }

  static void begin_partial_reinitialize(
      R19RuntimeStageRecord& record) noexcept {
    record.begin_write();
    record.role_ =
        static_cast<std::uint32_t>(R19RuntimeStageRole::Vehicle);
    record.build_fingerprint_0_ = 0xB0B0B0B0U;
  }

  static void finish_partial_reinitialize(
      R19RuntimeStageRecord& record) noexcept {
    record.build_fingerprint_1_ = 0xB1B1B1B1U;
    record.build_fingerprint_2_ = 0xB2B2B2B2U;
    record.build_fingerprint_3_ = 0xB3B3B3B3U;
    record.stage_mask_ = 0U;
    for (auto& counter : record.counters_) {
      counter = 0U;
    }
    record.first_failure_ = 0U;
    record.first_failure_stage_mask_ = 0U;
    record.first_failure_detail_ = 0U;
    record.commit_write();
  }
};

}  // namespace vc_lora::experimental

namespace {

using vc_lora::experimental::R19RuntimeBuildFingerprint;
using vc_lora::experimental::R19RuntimeStageCounter;
using vc_lora::experimental::R19RuntimeStage;
using vc_lora::experimental::R19RuntimeStageRecord;
using vc_lora::experimental::R19RuntimeStageRecordTestAccess;
using vc_lora::experimental::R19RuntimeStageRole;
using vc_lora::experimental::R19RuntimeStageSnapshot;

struct TestReport final {
  std::size_t checks{0U};
  std::size_t failures{0U};

  void check(bool condition, const char* message) noexcept {
    ++checks;
    if (!condition) {
      ++failures;
      std::cerr << "FAIL: " << message << '\n';
    }
  }
};

constexpr R19RuntimeBuildFingerprint fingerprint_a{
    0xA0A0A0A0U, 0xA1A1A1A1U, 0xA2A2A2A2U, 0xA3A3A3A3U};
constexpr R19RuntimeBuildFingerprint fingerprint_b{
    0xB0B0B0B0U, 0xB1B1B1B1U, 0xB2B2B2B2U, 0xB3B3B3B3U};

constexpr std::array<R19RuntimeStage, 17U> runtime_stages{
    R19RuntimeStage::SetupEntered,
    R19RuntimeStage::SerialBeginReturned,
    R19RuntimeStage::CadenceStarted,
    R19RuntimeStage::IdentityReady,
    R19RuntimeStage::E220ProfileChecked,
    R19RuntimeStage::StartupAllowed,
    R19RuntimeStage::E220NormalMode,
    R19RuntimeStage::AdapterReady,
    R19RuntimeStage::SetupComplete,
    R19RuntimeStage::LoopEntered,
    R19RuntimeStage::HostGateObserved,
    R19RuntimeStage::FrameStaged,
    R19RuntimeStage::WriteAttempted,
    R19RuntimeStage::WriteAccepted,
    R19RuntimeStage::FlushCompleted,
    R19RuntimeStage::TransportRecoveryEntered,
    R19RuntimeStage::TransportRecoveryCompleted,
};

void test_stage_vocabulary(TestReport& report) {
  std::uint32_t combined = 0U;
  bool all_single_unique_bits = true;
  for (const R19RuntimeStage stage : runtime_stages) {
    const std::uint32_t bit =
        vc_lora::experimental::r19_runtime_stage_bit(stage);
    if (bit == 0U || (bit & (bit - 1U)) != 0U ||
        (combined & bit) != 0U) {
      all_single_unique_bits = false;
    }
    combined = static_cast<std::uint32_t>(combined | bit);
  }
  report.check(all_single_unique_bits,
               "runtime stage values are not unique single bits");
  report.check(combined == 0x0001FFFFU,
               "runtime stage vocabulary no longer occupies bits 0..16");
}

bool is_clean_identity(const R19RuntimeStageSnapshot& snapshot,
                       R19RuntimeStageRole role,
                       const R19RuntimeBuildFingerprint& fingerprint) {
  return snapshot.valid_header() && snapshot.role == role &&
         snapshot.build_fingerprint == fingerprint &&
         snapshot.stage_mask == 0U &&
         snapshot.counters == std::array<std::uint32_t, 4U>{} &&
         snapshot.first_failure == 0U &&
         snapshot.first_failure_stage_mask == 0U &&
         snapshot.first_failure_detail == 0U;
}

void test_initialize_and_reset(TestReport& report) {
  R19RuntimeStageRecord record{};
  R19RuntimeStageSnapshot snapshot{};

  report.check(record.try_snapshot(snapshot),
               "a new record could not be snapshotted");
  report.check(!snapshot.valid_header() && snapshot.magic == 0U &&
                   snapshot.schema == 0U &&
                   snapshot.role == R19RuntimeStageRole::Invalid,
               "a new record was not reset to an invalid zero header");
  report.check(record.initialize(R19RuntimeStageRole::Vehicle,
                                 fingerprint_a),
               "valid Vehicle initialization was rejected");
  report.check(record.try_snapshot(snapshot) &&
                   is_clean_identity(snapshot, R19RuntimeStageRole::Vehicle,
                                     fingerprint_a),
               "initialized identity was not captured exactly");
  report.check(snapshot.sequence != 0U,
               "initialization did not publish a committed sequence");

  record.reset();
  report.check(record.try_snapshot(snapshot) && !snapshot.valid_header() &&
                   snapshot.magic == 0U && snapshot.schema == 0U &&
                   snapshot.stage_mask == 0U &&
                   snapshot.counters == std::array<std::uint32_t, 4U>{} &&
                   snapshot.first_failure == 0U,
               "reset did not clear the complete record");
  report.check(!record.initialize(R19RuntimeStageRole::Invalid,
                                  fingerprint_b),
               "an invalid role was accepted");
  report.check(record.try_snapshot(snapshot) && !snapshot.valid_header(),
               "rejected initialization changed the reset record");
}

void test_monotonic_stage_mask(TestReport& report) {
  R19RuntimeStageRecord record{};
  R19RuntimeStageSnapshot snapshot{};
  report.check(record.initialize(R19RuntimeStageRole::Ground, fingerprint_a),
               "stage fixture initialization failed");
  report.check(!record.mark_stage(0U), "an empty stage update was accepted");
  report.check(record.mark_stage(0x00000005U) &&
                   record.mark_stage(0x80000002U) &&
                   record.mark_stage(0x00000001U),
               "a valid stage update was rejected");
  report.check(record.try_snapshot(snapshot) &&
                   snapshot.stage_mask == 0x80000007U,
               "stage bits did not accumulate monotonically");
}

void test_saturating_counters(TestReport& report) {
  R19RuntimeStageRecord record{};
  R19RuntimeStageSnapshot snapshot{};
  report.check(record.initialize(R19RuntimeStageRole::Ground, fingerprint_a),
               "counter fixture initialization failed");
  report.check(record.increment_counter(R19RuntimeStageCounter::Boot, 7U),
               "valid counter increment was rejected");
  report.check(record.increment_counter(
                   R19RuntimeStageCounter::PublishAttempt,
                   std::numeric_limits<std::uint32_t>::max() - 1U),
               "large counter increment was rejected");
  report.check(record.increment_counter(
                   R19RuntimeStageCounter::PublishAttempt, 9U),
               "saturating counter increment was rejected");
  report.check(record.increment_counter(R19RuntimeStageCounter::Retry,
                                        std::numeric_limits<std::uint32_t>::max()) &&
                   record.increment_counter(R19RuntimeStageCounter::Retry, 1U),
               "maximum counter update was rejected");
  report.check(!record.increment_counter(R19RuntimeStageCounter::Boot, 0U),
               "zero counter increment was accepted");
  report.check(!record.increment_counter(
                   static_cast<R19RuntimeStageCounter>(99U), 1U),
               "out-of-range counter slot was accepted");
  report.check(record.try_snapshot(snapshot) && snapshot.counters[0U] == 7U &&
                   snapshot.counters[1U] == 0U &&
                   snapshot.counters[2U] ==
                       std::numeric_limits<std::uint32_t>::max() &&
                   snapshot.counters[3U] ==
                       std::numeric_limits<std::uint32_t>::max(),
               "counters did not preserve slots and saturate at UINT32_MAX");
}

void test_first_failure_latches_once(TestReport& report) {
  R19RuntimeStageRecord record{};
  R19RuntimeStageSnapshot snapshot{};
  report.check(record.initialize(R19RuntimeStageRole::Vehicle, fingerprint_b),
               "failure fixture initialization failed");
  report.check(record.mark_stage(0x00000120U),
               "failure fixture stage update failed");
  report.check(!record.latch_first_failure(0U, 0xDEADU),
               "zero failure code was accepted");
  report.check(record.latch_first_failure(0x12345678U, 0xABCDEF01U),
               "first failure was rejected");
  report.check(record.mark_stage(0x80000000U),
               "post-failure stage update failed");
  report.check(!record.latch_first_failure(0x87654321U, 0x10U),
               "later failure overwrote the first failure");
  report.check(record.try_snapshot(snapshot) &&
                   snapshot.first_failure == 0x12345678U &&
                   snapshot.first_failure_stage_mask == 0x00000120U &&
                   snapshot.first_failure_detail == 0xABCDEF01U &&
                   snapshot.stage_mask == 0x80000120U,
               "first failure code, stage, or detail was not latched exactly");
}

void test_snapshot_never_exposes_partial_reinitialize(TestReport& report) {
  R19RuntimeStageRecord record{};
  report.check(record.initialize(R19RuntimeStageRole::Ground, fingerprint_a),
               "snapshot fixture initialization failed");
  R19RuntimeStageSnapshot snapshot{};
  report.check(record.try_snapshot(snapshot) &&
                   is_clean_identity(snapshot, R19RuntimeStageRole::Ground,
                                     fingerprint_a),
               "snapshot fixture did not begin as complete identity A");

  const R19RuntimeStageSnapshot sentinel = snapshot;
  R19RuntimeStageRecordTestAccess::begin_partial_reinitialize(record);
  report.check(
      R19RuntimeStageRecordTestAccess::active_writer(record) == 1U &&
          (R19RuntimeStageRecordTestAccess::sequence(record) & 1U) != 0U,
      "writer-active evidence did not publish an odd sequence");
  report.check(!record.try_snapshot(snapshot, 1U),
               "snapshot accepted a writer-active partial identity");
  report.check(snapshot.magic == sentinel.magic &&
                   snapshot.role == sentinel.role &&
                   snapshot.build_fingerprint == sentinel.build_fingerprint,
               "failed snapshot modified the caller's last good snapshot");

  R19RuntimeStageRecordTestAccess::finish_partial_reinitialize(record);
  report.check(
      R19RuntimeStageRecordTestAccess::active_writer(record) == 0U &&
          (R19RuntimeStageRecordTestAccess::sequence(record) & 1U) == 0U,
      "writer completion did not publish an even stable sequence");
  report.check(record.try_snapshot(snapshot) &&
                   is_clean_identity(snapshot, R19RuntimeStageRole::Vehicle,
                                     fingerprint_b),
               "committed reinitialization was not exposed as complete B");
}

}  // namespace

int main() {
  static_assert(std::is_standard_layout_v<R19RuntimeStageRecord>,
                "JTAG stage record must keep a standard layout");
  static_assert(alignof(R19RuntimeStageRecord) >= alignof(std::uint32_t),
                "JTAG stage record must keep 32-bit alignment");
  static_assert(sizeof(R19RuntimeStageRecord) == 68U,
                "JTAG stage record must remain exactly 17 words");

  TestReport report{};
  test_stage_vocabulary(report);
  test_initialize_and_reset(report);
  test_monotonic_stage_mask(report);
  test_saturating_counters(report);
  test_first_failure_latches_once(report);
  test_snapshot_never_exposes_partial_reinitialize(report);

  if (report.failures != 0U) {
    std::cerr << "r19 runtime stage record tests: " << report.failures
              << " failure(s), " << report.checks << " checks\n";
    return 1;
  }
  std::cout << "r19 runtime stage record tests: PASS (" << report.checks
            << " checks)\n";
  return 0;
}
