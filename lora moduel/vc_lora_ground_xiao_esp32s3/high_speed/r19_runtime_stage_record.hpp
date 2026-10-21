#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <type_traits>

namespace vc_lora::experimental {

inline constexpr std::uint32_t r19_runtime_stage_magic = 0x52313953U;
inline constexpr std::uint32_t r19_runtime_stage_schema = 1U;

enum class R19RuntimeStageRole : std::uint32_t {
  Invalid = 0U,
  Ground = 1U,
  Vehicle = 2U,
};

enum class R19RuntimeStageCounter : std::uint32_t {
  Boot = 0U,
  Loop = 1U,
  PublishAttempt = 2U,
  Retry = 3U,  // Successful exact-frame publisher restart.
  Count = 4U,
};

// Monotonic execution witnesses for the diagnostic-only R19 candidate. Each
// value owns one bit so an attached debugger can distinguish the last reached
// boundary without consuming CDC, RF, or Pixhawk bandwidth.
enum class R19RuntimeStage : std::uint32_t {
  SetupEntered = 1U << 0U,
  SerialBeginReturned = 1U << 1U,
  CadenceStarted = 1U << 2U,
  IdentityReady = 1U << 3U,
  E220ProfileChecked = 1U << 4U,
  StartupAllowed = 1U << 5U,
  E220NormalMode = 1U << 6U,
  AdapterReady = 1U << 7U,
  SetupComplete = 1U << 8U,
  LoopEntered = 1U << 9U,
  HostGateObserved = 1U << 10U,
  FrameStaged = 1U << 11U,
  WriteAttempted = 1U << 12U,
  WriteAccepted = 1U << 13U,
  FlushCompleted = 1U << 14U,
  TransportRecoveryEntered = 1U << 15U,
  TransportRecoveryCompleted = 1U << 16U,
};

[[nodiscard]] constexpr std::uint32_t r19_runtime_stage_bit(
    R19RuntimeStage stage) noexcept {
  return static_cast<std::uint32_t>(stage);
}

using R19RuntimeBuildFingerprint = std::array<std::uint32_t, 4U>;

struct R19RuntimeStageSnapshot final {
  std::uint32_t magic{0U};
  std::uint32_t schema{0U};
  R19RuntimeStageRole role{R19RuntimeStageRole::Invalid};
  R19RuntimeBuildFingerprint build_fingerprint{};
  std::uint32_t stage_mask{0U};
  std::array<std::uint32_t, 4U> counters{};
  std::uint32_t first_failure{0U};
  std::uint32_t first_failure_stage_mask{0U};
  std::uint32_t first_failure_detail{0U};
  std::uint32_t sequence{0U};

  [[nodiscard]] constexpr bool valid_header() const noexcept {
    return magic == r19_runtime_stage_magic &&
           schema == r19_runtime_stage_schema &&
           (role == R19RuntimeStageRole::Ground ||
            role == R19RuntimeStageRole::Vehicle);
  }
};

struct R19RuntimeStageRecordTestAccess;

// Fixed-size diagnostic storage for early boot and transport-boundary
// evidence. The ESP32-S3 Arduino core deliberately compiles with
// -mdisable-hardware-atomics, so this record has one single firmware task writer
// and uses aligned volatile 32-bit evidence words instead of a hidden
// lock or libatomic call. Mutation methods must not be called from an ISR or
// another task. An external JTAG reader treats active_writer != 0 or an odd
// sequence as an in-progress sample and retries after observing an equal even
// sequence with active_writer == 0. No method allocates or waits.
class alignas(std::uint32_t) R19RuntimeStageRecord final {
 public:
  static constexpr std::size_t storage_word_count = 17U;
  static constexpr std::uint32_t default_snapshot_attempts = 8U;

  R19RuntimeStageRecord() noexcept = default;
  R19RuntimeStageRecord(const R19RuntimeStageRecord&) = delete;
  R19RuntimeStageRecord& operator=(const R19RuntimeStageRecord&) = delete;
  R19RuntimeStageRecord(R19RuntimeStageRecord&&) = delete;
  R19RuntimeStageRecord& operator=(R19RuntimeStageRecord&&) = delete;

  [[nodiscard]] bool initialize(
      R19RuntimeStageRole role,
      const R19RuntimeBuildFingerprint& build_fingerprint) noexcept {
    if (!valid_role(role)) {
      return false;
    }

    begin_write();
    magic_ = r19_runtime_stage_magic;
    schema_ = r19_runtime_stage_schema;
    role_ = static_cast<std::uint32_t>(role);
    build_fingerprint_0_ = build_fingerprint[0U];
    build_fingerprint_1_ = build_fingerprint[1U];
    build_fingerprint_2_ = build_fingerprint[2U];
    build_fingerprint_3_ = build_fingerprint[3U];
    stage_mask_ = 0U;
    for (auto& counter : counters_) {
      counter = 0U;
    }
    first_failure_ = 0U;
    first_failure_stage_mask_ = 0U;
    first_failure_detail_ = 0U;
    commit_write();
    return true;
  }

  void reset() noexcept {
    begin_write();
    magic_ = 0U;
    schema_ = 0U;
    role_ = 0U;
    build_fingerprint_0_ = 0U;
    build_fingerprint_1_ = 0U;
    build_fingerprint_2_ = 0U;
    build_fingerprint_3_ = 0U;
    stage_mask_ = 0U;
    for (auto& counter : counters_) {
      counter = 0U;
    }
    first_failure_ = 0U;
    first_failure_stage_mask_ = 0U;
    first_failure_detail_ = 0U;
    commit_write();
  }

  [[nodiscard]] bool mark_stage(std::uint32_t stage_bits) noexcept {
    if (stage_bits == 0U || !initialized_for_writer()) {
      return false;
    }
    begin_write();
    stage_mask_ = static_cast<std::uint32_t>(stage_mask_ | stage_bits);
    commit_write();
    return true;
  }

  [[nodiscard]] bool increment_counter(
      R19RuntimeStageCounter counter, std::uint32_t amount = 1U) noexcept {
    const auto slot = static_cast<std::uint32_t>(counter);
    if (slot >= static_cast<std::uint32_t>(R19RuntimeStageCounter::Count) ||
        amount == 0U || !initialized_for_writer()) {
      return false;
    }

    begin_write();
    saturating_add(counters_[slot], amount);
    commit_write();
    return true;
  }

  [[nodiscard]] bool latch_first_failure(std::uint32_t failure,
                                         std::uint32_t detail = 0U) noexcept {
    if (failure == 0U || !initialized_for_writer()) {
      return false;
    }

    if (first_failure_ != 0U) {
      return false;
    }
    begin_write();
    first_failure_stage_mask_ = stage_mask_;
    first_failure_detail_ = detail;
    compiler_fence();
    // Publish the nonzero code last so a raw JTAG read can never pair an old
    // stage/detail tuple with a newly visible failure code.
    first_failure_ = failure;
    commit_write();
    return true;
  }

  // Returns false instead of spinning if an interrupted task writer remains
  // active. The output is changed only after two matching sequence samples
  // with no active writer, so callers retain their last good snapshot.
  [[nodiscard]] bool try_snapshot(
      R19RuntimeStageSnapshot& output,
      std::uint32_t maximum_attempts = default_snapshot_attempts) const
      noexcept {
    for (std::uint32_t attempt = 0U; attempt < maximum_attempts; ++attempt) {
      if (active_writer_ != 0U) {
        continue;
      }
      compiler_fence();
      const std::uint32_t sequence_before = sequence_;
      if ((sequence_before & 1U) != 0U) {
        continue;
      }

      R19RuntimeStageSnapshot candidate{};
      candidate.magic = magic_;
      candidate.schema = schema_;
      candidate.role = static_cast<R19RuntimeStageRole>(role_);
      candidate.build_fingerprint = {
          build_fingerprint_0_, build_fingerprint_1_, build_fingerprint_2_,
          build_fingerprint_3_};
      candidate.stage_mask = stage_mask_;
      for (std::size_t slot = 0U; slot < candidate.counters.size(); ++slot) {
        candidate.counters[slot] = counters_[slot];
      }
      candidate.first_failure = first_failure_;
      candidate.first_failure_stage_mask = first_failure_stage_mask_;
      candidate.first_failure_detail = first_failure_detail_;

      compiler_fence();
      const std::uint32_t sequence_after = sequence_;
      if (sequence_before == sequence_after &&
          (sequence_after & 1U) == 0U && active_writer_ == 0U) {
        candidate.sequence = sequence_after;
        output = candidate;
        return true;
      }
    }
    return false;
  }

 private:
  friend struct R19RuntimeStageRecordTestAccess;

  [[nodiscard]] static constexpr bool valid_role(
      R19RuntimeStageRole role) noexcept {
    return role == R19RuntimeStageRole::Ground ||
           role == R19RuntimeStageRole::Vehicle;
  }

  [[nodiscard]] bool initialized_for_writer() const noexcept {
    const auto role = static_cast<R19RuntimeStageRole>(role_);
    return magic_ == r19_runtime_stage_magic &&
           schema_ == r19_runtime_stage_schema &&
           valid_role(role);
  }

  static void saturating_add(volatile std::uint32_t& target,
                             std::uint32_t amount) noexcept {
    const std::uint32_t current = target;
    const std::uint32_t room =
        std::numeric_limits<std::uint32_t>::max() - current;
    target = amount > room ? std::numeric_limits<std::uint32_t>::max()
                           : static_cast<std::uint32_t>(current + amount);
  }

  static void compiler_fence() noexcept {
    std::atomic_signal_fence(std::memory_order_seq_cst);
  }

  void begin_write() noexcept {
    active_writer_ = 1U;
    compiler_fence();
    const std::uint32_t stable_sequence = sequence_;
    sequence_ = static_cast<std::uint32_t>(
        (stable_sequence & ~1U) + 1U);
    compiler_fence();
  }

  void commit_write() noexcept {
    compiler_fence();
    const std::uint32_t active_sequence = sequence_;
    sequence_ = static_cast<std::uint32_t>(
        (active_sequence | 1U) + 1U);
    compiler_fence();
    active_writer_ = 0U;
  }

  volatile std::uint32_t active_writer_{0U};
  volatile std::uint32_t sequence_{0U};
  volatile std::uint32_t magic_{0U};
  volatile std::uint32_t schema_{0U};
  volatile std::uint32_t role_{0U};
  volatile std::uint32_t build_fingerprint_0_{0U};
  volatile std::uint32_t build_fingerprint_1_{0U};
  volatile std::uint32_t build_fingerprint_2_{0U};
  volatile std::uint32_t build_fingerprint_3_{0U};
  volatile std::uint32_t stage_mask_{0U};
  volatile std::uint32_t counters_[4U]{0U, 0U, 0U, 0U};
  volatile std::uint32_t first_failure_{0U};
  volatile std::uint32_t first_failure_stage_mask_{0U};
  volatile std::uint32_t first_failure_detail_{0U};
};

static_assert(alignof(R19RuntimeStageRecord) >= alignof(std::uint32_t),
              "R19 runtime stage storage requires aligned 32-bit words");
static_assert(std::is_standard_layout_v<R19RuntimeStageRecord>,
              "JTAG field offsets require a standard-layout stage record");
static_assert(sizeof(R19RuntimeStageRecord) ==
                  R19RuntimeStageRecord::storage_word_count *
                      sizeof(std::uint32_t),
              "R19 runtime stage storage must remain fixed-size words");


inline constexpr std::uint32_t r19_ground_usb_commit_magic = 0x52313943U;
inline constexpr std::uint32_t r19_ground_usb_commit_schema = 1U;
inline constexpr std::uint32_t r19_ground_usb_commit_transport_observed = 1U;
inline constexpr std::uint32_t r19_ground_usb_commit_endpoint_observed = 2U;
inline constexpr std::uint32_t r19_ground_usb_commit_deadline_observed = 4U;

enum class R19GroundUsbCommitFailureReason : std::uint32_t {
  None = 0U,
  PublicationRejected = 1U,
  BeforeFlushDeadline = 2U,
  Retired = 3U,
  PacerCompletionRejected = 4U,
};

struct R19GroundUsbCommitEvidence {
  R19GroundUsbCommitFailureReason reason{R19GroundUsbCommitFailureReason::None};
  std::uint32_t predicate_observed_mask{0U};
  std::uint32_t predicate_true_mask{0U};
  std::uint32_t source_line{0U};
  std::uint32_t token{0U};
  std::uint32_t expected_epoch{0U};
  std::uint32_t observed_epoch{0U};
  std::uint64_t commit_started_ms{0U};
  std::uint64_t flush_started_ms{0U};
  std::uint64_t completed_ms{0U};
  std::uint64_t deadline_ms{0U};
  std::uint64_t committed_base{0U};
  std::uint64_t commit_goal{0U};
  std::uint64_t bytes_committed{0U};
  std::uint32_t expected_frame_bytes{0U};
  std::uint32_t accepted_frame_bytes{0U};
};

struct R19GroundUsbCommitSnapshot final : R19GroundUsbCommitEvidence {
  std::uint32_t magic{0U};
  std::uint32_t schema{0U};
  R19RuntimeStageRole role{R19RuntimeStageRole::Invalid};
  R19RuntimeBuildFingerprint build_fingerprint{};
  std::uint32_t sequence{0U};

  [[nodiscard]] bool valid_header() const noexcept {
    return magic == r19_ground_usb_commit_magic &&
           schema == r19_ground_usb_commit_schema &&
           (role == R19RuntimeStageRole::Ground ||
            role == R19RuntimeStageRole::Vehicle);
  }
  [[nodiscard]] bool failure_latched() const noexcept {
    return valid_header() && reason != R19GroundUsbCommitFailureReason::None;
  }
};

struct R19GroundUsbCommitRecordTestAccess;

// Diagnostic-only, JTAG-only, first failed Ground heartbeat publication.
// One firmware task owns every mutation. Never write this record from an ISR
// or a second task. Aligned volatile words plus compiler fences deliberately
// avoid hardware atomics/libatomic on the ESP32-S3 Arduino toolchain.
// JTAG accepts only two identical reads with active_writer=0 and equal even
// sequence values. All 64-bit values are explicit low/high word pairs.
// Existing 68-byte runtime and 112-byte FIFO records are independent ABIs.
class alignas(std::uint32_t) R19GroundUsbCommitRecord final {
 public:
  static constexpr std::size_t storage_word_count = 32U;
  static constexpr std::uint32_t default_snapshot_attempts = 8U;
  R19GroundUsbCommitRecord() noexcept = default;
  R19GroundUsbCommitRecord(const R19GroundUsbCommitRecord&) = delete;
  R19GroundUsbCommitRecord& operator=(const R19GroundUsbCommitRecord&) = delete;

  [[nodiscard]] bool initialize(
      R19RuntimeStageRole role,
      const R19RuntimeBuildFingerprint& fingerprint) noexcept {
    if (role != R19RuntimeStageRole::Ground &&
        role != R19RuntimeStageRole::Vehicle) return false;
    begin_write();
    clear_payload();
    words_[2U] = r19_ground_usb_commit_magic;
    words_[3U] = r19_ground_usb_commit_schema;
    words_[4U] = static_cast<std::uint32_t>(role);
    for (std::size_t slot = 0U; slot < fingerprint.size(); ++slot)
      words_[5U + slot] = fingerprint[slot];
    commit_write();
    return true;
  }

  void reset() noexcept {
    begin_write();
    clear_payload();
    commit_write();
  }

  [[nodiscard]] bool latch_first_failure(
      const R19GroundUsbCommitEvidence& evidence) noexcept {
    const auto reason = static_cast<std::uint32_t>(evidence.reason);
    if (words_[2U] != r19_ground_usb_commit_magic ||
        words_[3U] != r19_ground_usb_commit_schema ||
        words_[4U] != static_cast<std::uint32_t>(R19RuntimeStageRole::Ground) ||
        words_[9U] != 0U || reason == 0U || reason > 4U ||
        (evidence.predicate_observed_mask & ~7U) != 0U ||
        (evidence.predicate_true_mask & ~evidence.predicate_observed_mask) != 0U ||
        evidence.accepted_frame_bytes > evidence.expected_frame_bytes)
      return false;
    begin_write();
    words_[10U] = evidence.predicate_observed_mask;
    words_[11U] = evidence.predicate_true_mask;
    words_[12U] = evidence.source_line;
    words_[13U] = evidence.token;
    words_[14U] = evidence.expected_epoch;
    words_[15U] = evidence.observed_epoch;
    write_u64(16U, evidence.commit_started_ms);
    write_u64(18U, evidence.flush_started_ms);
    write_u64(20U, evidence.completed_ms);
    write_u64(22U, evidence.deadline_ms);
    write_u64(24U, evidence.committed_base);
    write_u64(26U, evidence.commit_goal);
    write_u64(28U, evidence.bytes_committed);
    words_[30U] = evidence.expected_frame_bytes;
    words_[31U] = evidence.accepted_frame_bytes;
    compiler_fence();
    words_[9U] = reason;  // Publish first-failure identity last.
    commit_write();
    return true;
  }

  [[nodiscard]] bool try_snapshot(
      R19GroundUsbCommitSnapshot& output,
      std::uint32_t maximum_attempts = default_snapshot_attempts) const noexcept {
    for (std::uint32_t attempt = 0U; attempt < maximum_attempts; ++attempt) {
      if (words_[0U] != 0U) continue;
      compiler_fence();
      const std::uint32_t before = words_[1U];
      if ((before & 1U) != 0U) continue;
      R19GroundUsbCommitSnapshot snapshot{};
      snapshot.magic = words_[2U];
      snapshot.schema = words_[3U];
      snapshot.role = static_cast<R19RuntimeStageRole>(words_[4U]);
      for (std::size_t slot = 0U; slot < 4U; ++slot)
        snapshot.build_fingerprint[slot] = words_[5U + slot];
      snapshot.reason = static_cast<R19GroundUsbCommitFailureReason>(words_[9U]);
      snapshot.predicate_observed_mask = words_[10U];
      snapshot.predicate_true_mask = words_[11U];
      snapshot.source_line = words_[12U];
      snapshot.token = words_[13U];
      snapshot.expected_epoch = words_[14U];
      snapshot.observed_epoch = words_[15U];
      snapshot.commit_started_ms = read_u64(16U);
      snapshot.flush_started_ms = read_u64(18U);
      snapshot.completed_ms = read_u64(20U);
      snapshot.deadline_ms = read_u64(22U);
      snapshot.committed_base = read_u64(24U);
      snapshot.commit_goal = read_u64(26U);
      snapshot.bytes_committed = read_u64(28U);
      snapshot.expected_frame_bytes = words_[30U];
      snapshot.accepted_frame_bytes = words_[31U];
      compiler_fence();
      const std::uint32_t after = words_[1U];
      if (before == after && (after & 1U) == 0U && words_[0U] == 0U) {
        snapshot.sequence = after;
        output = snapshot;
        return true;
      }
    }
    return false;
  }

 private:
  friend struct R19GroundUsbCommitRecordTestAccess;
  static void compiler_fence() noexcept {
    std::atomic_signal_fence(std::memory_order_seq_cst);
  }
  void begin_write() noexcept {
    words_[0U] = 1U;
    compiler_fence();
    words_[1U] = static_cast<std::uint32_t>((words_[1U] & ~1U) + 1U);
    compiler_fence();
  }
  void commit_write() noexcept {
    compiler_fence();
    words_[1U] = static_cast<std::uint32_t>((words_[1U] | 1U) + 1U);
    compiler_fence();
    words_[0U] = 0U;
  }
  void clear_payload() noexcept {
    for (std::size_t slot = 2U; slot < storage_word_count; ++slot) words_[slot] = 0U;
  }
  void write_u64(std::size_t low_word, std::uint64_t value) noexcept {
    words_[low_word] = static_cast<std::uint32_t>(value);
    words_[low_word + 1U] = static_cast<std::uint32_t>(value >> 32U);
  }
  [[nodiscard]] std::uint64_t read_u64(std::size_t low_word) const noexcept {
    return static_cast<std::uint64_t>(words_[low_word]) |
           (static_cast<std::uint64_t>(words_[low_word + 1U]) << 32U);
  }
  // Byte offsets: 0 active, 4 sequence, 8 magic, 12 schema, 16 role,
  // 20..32 fingerprint, 36 reason, 40 observed mask, 44 true mask,
  // 48 source, 52 token, 56 expected epoch, 60 observed epoch,
  // 64 commit start, 72 flush start, 80 completed, 88 deadline,
  // 96 committed base, 104 goal, 112 committed bytes, 120 expected frame
  // bytes, 124 accepted frame bytes. Each 64-bit field occupies low then high.
  volatile std::uint32_t words_[storage_word_count]{};
};

static_assert(std::is_standard_layout_v<R19GroundUsbCommitRecord>);
static_assert(alignof(R19GroundUsbCommitRecord) == alignof(std::uint32_t));
static_assert(sizeof(R19GroundUsbCommitRecord) == 128U);

}  // namespace vc_lora::experimental
