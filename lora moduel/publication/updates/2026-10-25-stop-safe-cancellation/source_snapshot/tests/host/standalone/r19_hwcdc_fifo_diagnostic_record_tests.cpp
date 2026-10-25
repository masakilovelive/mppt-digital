#include <array>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <limits>
#include <type_traits>

#include "../../../third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDCR19Diagnostic.h"

namespace vc_lora::experimental {

struct R19HwcdcFifoDiagnosticRecordTestAccess final {
  static std::array<std::size_t, 28U> word_offsets(
      const R19HwcdcFifoDiagnosticRecord& record) noexcept {
    const auto base = reinterpret_cast<std::uintptr_t>(&record);
    const auto offset = [base](const volatile std::uint32_t* field) noexcept {
      return static_cast<std::size_t>(
          reinterpret_cast<std::uintptr_t>(field) - base);
    };
    return {
        offset(&record.active_writer_),
        offset(&record.sequence_),
        offset(&record.magic_),
        offset(&record.schema_),
        offset(&record.flags_),
        offset(&record.tx_loss_epoch_),
        offset(&record.fifo_write_attempt_count_),
        offset(&record.fifo_write_bytes_),
        offset(&record.fifo_zero_write_count_),
        offset(&record.last_fifo_write_size_),
        offset(&record.wr_done_count_),
        offset(&record.in_empty_irq_count_),
        offset(&record.payload_in_empty_count_),
        offset(&record.publish_generation_),
        offset(&record.pickup_generation_),
        offset(&record.bus_reset_count_),
        offset(&record.flush_attempt_count_),
        offset(&record.flush_success_count_),
        offset(&record.flush_timeout_count_),
        offset(&record.zlp_flush_count_),
        offset(&record.last_ring_pending_bytes_),
        offset(&record.last_stash_pending_bytes_),
        offset(&record.last_interrupt_status_),
        offset(&record.last_flush_blocker_mask_),
        offset(&record.last_flush_outcome_),
        offset(&record.last_flush_task_zlp_count_),
        offset(&record.last_flush_isr_zlp_count_),
        offset(&record.last_flush_terminal_blocker_mask_),
    };
  }

  static std::uint32_t active_writer(
      const R19HwcdcFifoDiagnosticRecord& record) noexcept {
    return record.active_writer_;
  }

  static std::uint32_t sequence(
      const R19HwcdcFifoDiagnosticRecord& record) noexcept {
    return record.sequence_;
  }

  static void prime_saturated_counters(
      R19HwcdcFifoDiagnosticRecord& record) noexcept {
    constexpr std::uint32_t maximum =
        std::numeric_limits<std::uint32_t>::max();
    record.begin_write();
    record.fifo_write_attempt_count_ = maximum - 1U;
    record.fifo_write_bytes_ = maximum - 2U;
    record.fifo_zero_write_count_ = 0U;
    record.wr_done_count_ = maximum - 1U;
    record.in_empty_irq_count_ = maximum - 1U;
    record.payload_in_empty_count_ = maximum - 1U;
    record.bus_reset_count_ = maximum;
    record.flush_attempt_count_ = maximum;
    record.flush_success_count_ = maximum;
    record.flush_timeout_count_ = 0U;
    record.zlp_flush_count_ = 0U;
    record.commit_write();
  }

  static void prime_timeout_saturation(
      R19HwcdcFifoDiagnosticRecord& record) noexcept {
    constexpr std::uint32_t maximum =
        std::numeric_limits<std::uint32_t>::max();
    record.begin_write();
    record.flush_attempt_count_ = maximum;
    record.flush_success_count_ = 0U;
    record.flush_timeout_count_ = maximum - 1U;
    record.flags_ = static_cast<std::uint32_t>(
        record.flags_ |
        flag_for_test(R19HwcdcFifoDiagnosticFlag::FlushActive));
    record.commit_write();
  }

  static void prime_active_flush_zlp_saturation(
      R19HwcdcFifoDiagnosticRecord& record) noexcept {
    constexpr std::uint32_t maximum =
        std::numeric_limits<std::uint32_t>::max();
    record.begin_write();
    record.flags_ = static_cast<std::uint32_t>(
        record.flags_ |
        flag_for_test(R19HwcdcFifoDiagnosticFlag::FlushActive));
    record.last_flush_outcome_ = static_cast<std::uint32_t>(
        R19HwcdcFifoFlushOutcome::Active);
    record.wr_done_count_ = maximum;
    record.zlp_flush_count_ = maximum;
    record.last_flush_task_zlp_count_ = maximum;
    record.last_flush_isr_zlp_count_ = maximum;
    record.commit_write();
  }

  static void begin_partial_state_write(
      R19HwcdcFifoDiagnosticRecord& record,
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    record.begin_write();
    record.flags_ = static_cast<std::uint32_t>(
        state.flags | r19_hwcdc_fifo_diagnostic_flag(
                          R19HwcdcFifoDiagnosticFlag::Initialized));
    record.tx_loss_epoch_ = state.tx_loss_epoch;
    record.publish_generation_ = state.publish_generation;
    record.pickup_generation_ = state.pickup_generation;
  }

  static void finish_partial_state_write(
      R19HwcdcFifoDiagnosticRecord& record,
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    record.last_ring_pending_bytes_ = state.ring_pending_bytes;
    record.last_stash_pending_bytes_ = state.stash_pending_bytes;
    record.last_interrupt_status_ = state.interrupt_status;
    record.last_flush_blocker_mask_ = state.flush_blocker_mask;
    record.commit_write();
  }

 private:
  static constexpr std::uint32_t flag_for_test(
      R19HwcdcFifoDiagnosticFlag value) noexcept {
    return r19_hwcdc_fifo_diagnostic_flag(value);
  }
};

struct R19HwcdcRestartDiagnosticRecordTestAccess final {
  static std::array<std::size_t, 12U> offsets(
      const R19HwcdcRestartDiagnosticRecord& record) noexcept {
    const auto base = reinterpret_cast<std::uintptr_t>(&record);
    const auto offset = [base](const volatile void* field) noexcept {
      return static_cast<std::size_t>(
          reinterpret_cast<std::uintptr_t>(field) - base);
    };
    return {offset(&record.active_writer_), offset(&record.sequence_),
            offset(&record.magic_), offset(&record.schema_),
            offset(&record.flags_), offset(&record.event_count_),
            offset(&record.first_phase_), offset(&record.first_state_),
            offset(&record.latest_origin_), offset(&record.latest_event_ordinal_),
            offset(&record.latest_state_), offset(&record.reserved_)};
  }
  static void begin(R19HwcdcRestartDiagnosticRecord& record) noexcept {
    record.begin_write();
  }
  static void commit(R19HwcdcRestartDiagnosticRecord& record) noexcept {
    record.commit_write();
  }
  static void saturate(R19HwcdcRestartDiagnosticRecord& record) noexcept {
    record.begin_write();
    record.event_count_ = std::numeric_limits<std::uint32_t>::max();
    record.blocked_count_ = std::numeric_limits<std::uint32_t>::max();
    record.restart_count_ = std::numeric_limits<std::uint32_t>::max();
    record.commit_write();
  }
};

}  // namespace vc_lora::experimental

namespace {

using vc_lora::experimental::R19HwcdcFifoDiagnosticFlag;
using vc_lora::experimental::R19HwcdcFifoDiagnosticRecord;
using vc_lora::experimental::R19HwcdcFifoDiagnosticRecordTestAccess;
using vc_lora::experimental::R19HwcdcFifoDiagnosticSnapshot;
using vc_lora::experimental::R19HwcdcFifoDiagnosticState;
using vc_lora::experimental::R19HwcdcFifoBusResetResult;
using vc_lora::experimental::R19HwcdcFifoFlushBlocker;
using vc_lora::experimental::R19HwcdcFifoFlushOutcome;
using vc_lora::experimental::R19HwcdcFifoWriteResult;
using vc_lora::experimental::R19HwcdcFifoZlpOrigin;

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

void test_restart_record_first_blocked_and_latest_outcome(TestReport& report) {
  using namespace vc_lora::experimental;
  static_assert(sizeof(R19HwcdcFifoDiagnosticRecord) == 112U,
                "restart evidence must not change the existing FIFO ABI");
  static_assert(sizeof(R19HwcdcRestartDiagnosticRecord) == 128U &&
                sizeof(R19HwcdcRestartDiagnosticSnapshot) == 128U,
                "restart JTAG ABI must be exactly 32 words");
  R19HwcdcRestartDiagnosticRecord record{};
  R19HwcdcRestartDiagnosticSnapshot snapshot{};
  const std::array<std::size_t, 12U> expected_offsets{
      0U, 4U, 8U, 12U, 16U, 20U, 32U, 40U, 72U, 88U, 92U, 124U};
  report.check(R19HwcdcRestartDiagnosticRecordTestAccess::offsets(record) ==
                   expected_offsets,
               "restart JTAG record offsets differ from its snapshot ABI");
  report.check(record.initialize() && record.try_snapshot(snapshot) &&
                   snapshot.valid_header() && snapshot.flags == 1U &&
                   snapshot.event_count == 0U && snapshot.reserved == 0U,
               "restart record initialization did not publish an empty ABI");
  snapshot.event_count = 123U;
  R19HwcdcRestartDiagnosticRecordTestAccess::begin(record);
  report.check(!record.try_snapshot(snapshot, 1U) && snapshot.event_count == 123U,
               "active restart writer exposed a partial snapshot");
  R19HwcdcRestartDiagnosticRecordTestAccess::commit(record);
  const R19HwcdcRestartDiagnosticState first{
      r19_hwcdc_fifo_diagnostic_flag(R19HwcdcFifoDiagnosticFlag::Connected) |
          r19_hwcdc_fifo_diagnostic_flag(R19HwcdcFifoDiagnosticFlag::FifoWritable),
      7U, 31U, 0U, 15U, 15U, 0xA0U, 0x80U};
  auto second = first;
  second.interrupt_status = 0xB0U;
  second.interrupt_enable_mask = 0U;
  report.check(record.record_blocked(first,
                   R19HwcdcRestartPhase::PostEnqueueIdleTransition) &&
                   record.record_blocked(second,
                   R19HwcdcRestartPhase::FlushIdlePending) &&
                   record.try_snapshot(snapshot) &&
                   snapshot.first_phase == 1U &&
                   snapshot.first_event_ordinal == 1U &&
                   snapshot.blocked_count == 2U &&
                   snapshot.first_state.interrupt_status == 0xA0U &&
                   snapshot.first_state.interrupt_enable_mask == 0x80U &&
                   snapshot.first_state.ring_pending_bytes == 31U,
               "later blocked samples overwrote the immutable first boundary");
  auto published = first;
  published.flags = r19_hwcdc_fifo_diagnostic_flag(
      R19HwcdcFifoDiagnosticFlag::Connected) |
      r19_hwcdc_fifo_diagnostic_flag(R19HwcdcFifoDiagnosticFlag::PayloadInFlight);
  published.ring_pending_bytes = 0U;
  published.publish_generation = 16U;
  report.check(record.record_restart(published,
                   R19HwcdcRestartOrigin::PostEnqueueIdleTransition,
                   R19HwcdcRestartOutcome::Published, 31U, 31U) &&
                   record.try_snapshot(snapshot) && snapshot.flags == 7U &&
                   snapshot.event_count == 3U && snapshot.restart_count == 1U &&
                   snapshot.latest_event_ordinal == 3U &&
                   snapshot.latest_origin == 2U && snapshot.latest_outcome == 1U &&
                   snapshot.latest_requested_bytes == 31U &&
                   snapshot.latest_written_bytes == 31U &&
                   snapshot.latest_state.publish_generation == 16U &&
                   snapshot.first_state.publish_generation == 15U,
               "restart outcome did not preserve before/after publication proof");
  auto invalid = first;
  invalid.publish_generation = 99U;
  report.check(!record.record_blocked(invalid,
                   R19HwcdcRestartPhase::PostEnqueueIdleTransition) &&
                   !record.record_restart(first,
                   R19HwcdcRestartOrigin::EntryCleanIdle,
                   R19HwcdcRestartOutcome::Published, 31U, 0U) &&
                   !record.record_restart(first,
                   R19HwcdcRestartOrigin::EntryCleanIdle,
                   R19HwcdcRestartOutcome::ZeroWriteRejected, 33U, 0U) &&
                   record.try_snapshot(snapshot) && snapshot.event_count == 3U,
               "invalid restart evidence mutated or forged a publication");
  auto reset_state = first;
  reset_state.flags = r19_hwcdc_fifo_diagnostic_flag(
      R19HwcdcFifoDiagnosticFlag::FifoQuarantined);
  ++reset_state.tx_loss_epoch;
  reset_state.ring_pending_bytes = 0U;
  report.check(record.record_restart(reset_state,
                   R19HwcdcRestartOrigin::PostEnqueueIdleTransition,
                   R19HwcdcRestartOutcome::ResetAfterWrite, 31U, 7U) &&
                   record.try_snapshot(snapshot) &&
                   snapshot.latest_outcome == 4U &&
                   snapshot.latest_written_bytes == 7U &&
                   snapshot.latest_state.tx_loss_epoch == 8U &&
                   snapshot.first_state.tx_loss_epoch == 7U,
               "reset evidence lost the quarantined boundary or first sample");
  record.reset();
  report.check(record.try_snapshot(snapshot) && !snapshot.valid_header() &&
                   snapshot.flags == 0U && snapshot.event_count == 0U &&
                   snapshot.first_state.ring_pending_bytes == 0U &&
                   snapshot.latest_state.tx_loss_epoch == 0U,
               "restart record reset retained stale first/latest evidence");
  report.check(!record.record_blocked(first,
                   R19HwcdcRestartPhase::PostEnqueueIdleTransition) &&
                   !record.record_restart(first,
                   R19HwcdcRestartOrigin::EntryCleanIdle,
                   R19HwcdcRestartOutcome::ZeroWriteRejected, 31U, 0U),
               "uninitialized restart record accepted an event");
  report.check(record.initialize(), "restart reinitialization failed");
  R19HwcdcRestartDiagnosticRecordTestAccess::saturate(record);
  report.check(record.record_blocked(first,
                   R19HwcdcRestartPhase::PostEnqueueIdleTransition) &&
                   record.record_restart(published,
                   R19HwcdcRestartOrigin::EntryCleanIdle,
                   R19HwcdcRestartOutcome::Published, 31U, 7U) &&
                   record.try_snapshot(snapshot) &&
                   snapshot.event_count == std::numeric_limits<std::uint32_t>::max() &&
                   snapshot.blocked_count == snapshot.event_count &&
                   snapshot.restart_count == snapshot.event_count &&
                   snapshot.latest_event_ordinal == snapshot.event_count,
               "restart event/counter saturation wrapped into false evidence");
}

constexpr std::uint32_t flag(R19HwcdcFifoDiagnosticFlag value) noexcept {
  return vc_lora::experimental::r19_hwcdc_fifo_diagnostic_flag(value);
}

constexpr std::uint32_t blocker(R19HwcdcFifoFlushBlocker value) noexcept {
  return vc_lora::experimental::r19_hwcdc_fifo_flush_blocker(value);
}

constexpr R19HwcdcFifoDiagnosticState state_a{
    flag(R19HwcdcFifoDiagnosticFlag::ObservationActive) |
        flag(R19HwcdcFifoDiagnosticFlag::Connected) |
        flag(R19HwcdcFifoDiagnosticFlag::FifoWritable),
    7U,
    11U,
    11U,
    63U,
    9U,
    0xA5A50001U,
    0U,
};

constexpr R19HwcdcFifoDiagnosticState state_b{
    flag(R19HwcdcFifoDiagnosticFlag::ObservationActive) |
        flag(R19HwcdcFifoDiagnosticFlag::PayloadInFlight) |
        flag(R19HwcdcFifoDiagnosticFlag::BootstrapFence),
    8U,
    12U,
    11U,
    0U,
    0U,
    0x5A5A0080U,
    blocker(R19HwcdcFifoFlushBlocker::FifoNotWritable),
};

// The post-discard/settled counterpart of state_b. It retains the distinctive
// epoch, status, queue, and blocker fields without claiming an unaccounted
// payload is still in flight.
constexpr R19HwcdcFifoDiagnosticState state_b_settled{
    flag(R19HwcdcFifoDiagnosticFlag::ObservationActive) |
        flag(R19HwcdcFifoDiagnosticFlag::BootstrapFence),
    8U,
    12U,
    12U,
    0U,
    0U,
    0x5A5A0080U,
    blocker(R19HwcdcFifoFlushBlocker::FifoNotWritable),
};

bool snapshot_has_state_with_record_flags(
    const R19HwcdcFifoDiagnosticSnapshot& snapshot,
    const R19HwcdcFifoDiagnosticState& state,
    std::uint32_t record_owned_flags) noexcept {
  return snapshot.flags ==
             (state.flags |
               flag(R19HwcdcFifoDiagnosticFlag::Initialized) |
               record_owned_flags) &&
         snapshot.tx_loss_epoch == state.tx_loss_epoch &&
         snapshot.publish_generation == state.publish_generation &&
         snapshot.pickup_generation == state.pickup_generation &&
         snapshot.last_ring_pending_bytes == state.ring_pending_bytes &&
         snapshot.last_stash_pending_bytes == state.stash_pending_bytes &&
         snapshot.last_interrupt_status == state.interrupt_status &&
         snapshot.last_flush_blocker_mask == state.flush_blocker_mask;
}

bool snapshot_has_state(const R19HwcdcFifoDiagnosticSnapshot& snapshot,
                        const R19HwcdcFifoDiagnosticState& state) noexcept {
  return snapshot_has_state_with_record_flags(snapshot, state, 0U);
}

void test_exact_abi_layout(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  const auto offsets =
      R19HwcdcFifoDiagnosticRecordTestAccess::word_offsets(record);
  bool exact_offsets = true;
  for (std::size_t word = 0U; word < offsets.size(); ++word) {
    if (offsets[word] != word * sizeof(std::uint32_t)) {
      exact_offsets = false;
    }
  }
  report.check(exact_offsets,
               "the 28 diagnostic fields are not in append-only ABI order");
  report.check(sizeof(record) == 112U,
               "the Endpoint FIFO record is not exactly 112 bytes");
  report.check(alignof(R19HwcdcFifoDiagnosticRecord) >=
                   alignof(std::uint32_t),
               "the Endpoint FIFO record lost 32-bit alignment");
}

void test_initialize_and_observe_state(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  report.check(record.try_snapshot(snapshot),
               "a zero-initialized record could not be snapshotted");
  report.check(!snapshot.valid_header() && snapshot.magic == 0U &&
                   snapshot.schema == 0U && snapshot.sequence == 0U,
               "a new record did not expose a coherent invalid zero header");

  report.check(record.initialize(state_a),
               "valid diagnostic initialization was rejected");
  report.check(record.try_snapshot(snapshot) && snapshot.valid_header(),
               "initialized diagnostic header is invalid");
  report.check(snapshot.magic ==
                       vc_lora::experimental::r19_hwcdc_fifo_diagnostic_magic &&
                   snapshot.schema ==
                       vc_lora::experimental::r19_hwcdc_fifo_diagnostic_schema,
               "initialized magic or schema is incorrect");
  report.check(snapshot.active_writer == 0U && snapshot.sequence != 0U &&
                   (snapshot.sequence & 1U) == 0U,
               "initialization did not publish a stable even sequence");
  report.check(snapshot_has_state(snapshot, state_a),
               "initialization did not expose the complete supplied state");
  report.check(snapshot.fifo_write_attempt_count == 0U &&
                   snapshot.fifo_write_bytes == 0U &&
                   snapshot.fifo_zero_write_count == 0U &&
                   snapshot.last_fifo_write_size == 0U &&
                   snapshot.wr_done_count == 0U &&
                   snapshot.in_empty_irq_count == 0U &&
                   snapshot.payload_in_empty_count == 0U &&
                   snapshot.bus_reset_count == 0U &&
                   snapshot.flush_attempt_count == 0U &&
                   snapshot.flush_success_count == 0U &&
                   snapshot.flush_timeout_count == 0U &&
                   snapshot.zlp_flush_count == 0U,
               "initialization did not clear every event counter");

  report.check(record.observe_state(state_b_settled),
               "state-only observation was rejected after initialization");
  report.check(record.try_snapshot(snapshot) &&
                    snapshot_has_state(snapshot, state_b_settled) &&
                   snapshot.fifo_write_attempt_count == 0U &&
                   snapshot.flush_attempt_count == 0U,
               "state-only observation changed counters or exposed stale state");
}

void test_event_accounting(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  report.check(record.initialize(state_a),
               "event-accounting fixture initialization failed");

  report.check(record.record_fifo_write(17U, state_a) &&
                     record.record_wr_done(state_b),
               "FIFO write events were rejected");
  report.check(record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, state_b),
               "wr_done events were rejected");
  report.check(record.record_in_empty(false, state_b) &&
                    record.record_in_empty(true, state_b_settled) &&
                    record.record_fifo_write(0U, state_b_settled),
               "IN_EMPTY events were rejected");
  report.check(record.record_bus_reset(state_a),
               "bus-reset event was rejected");
  report.check(record.record_flush_attempt(state_a) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, state_a),
               "active flush setup or final task ZLP was rejected");
  report.check(record.try_snapshot(snapshot) &&
                   (snapshot.flags &
                    flag(R19HwcdcFifoDiagnosticFlag::FlushActive)) != 0U &&
                   snapshot.flush_attempt_count == 1U,
               "flush attempt did not publish its active transaction flag");
  report.check(record.observe_state(state_a) &&
                   record.try_snapshot(snapshot) &&
                   (snapshot.flags &
                    flag(R19HwcdcFifoDiagnosticFlag::FlushActive)) != 0U,
               "state observation erased an active flush transaction");
  report.check(record.record_flush_success(state_a),
               "flush-success event was rejected");
  report.check(record.record_flush_attempt(state_b_settled) &&
                    record.record_flush_timeout(state_b_settled),
               "flush-timeout event was rejected");

  report.check(record.try_snapshot(snapshot),
               "event-accounting snapshot failed");
  report.check(snapshot.fifo_write_attempt_count == 2U &&
                   snapshot.fifo_write_bytes == 17U &&
                   snapshot.fifo_zero_write_count == 1U &&
                   snapshot.last_fifo_write_size == 0U,
               "FIFO write accounting is not exact");
  report.check(snapshot.wr_done_count == 3U &&
                   snapshot.zlp_flush_count == 2U,
               "wr_done/ZLP accounting is not exact");
  report.check(snapshot.in_empty_irq_count == 2U &&
                   snapshot.payload_in_empty_count == 1U,
               "raw and payload-qualified IN_EMPTY accounting was conflated");
  report.check(snapshot.bus_reset_count == 1U &&
                   snapshot.flush_attempt_count == 2U &&
                   snapshot.flush_success_count == 1U &&
                   snapshot.flush_timeout_count == 1U &&
                   (snapshot.flags &
                    flag(R19HwcdcFifoDiagnosticFlag::FlushActive)) == 0U,
               "reset or flush accounting is not exact");
  report.check(snapshot_has_state_with_record_flags(
                   snapshot, state_b_settled,
                   flag(R19HwcdcFifoDiagnosticFlag::PayloadPublishAborted)),
               "an event did not atomically expose its matching state");
}

void test_payload_causal_accounting_is_fail_closed(TestReport& report) {
  R19HwcdcFifoDiagnosticSnapshot snapshot{};

  R19HwcdcFifoDiagnosticRecord missing_fifo{};
  bool missing_fifo_flush_issued = false;
  report.check(
      missing_fifo.initialize(state_a) &&
          !missing_fifo.record_wr_done([&]() noexcept {
            missing_fifo_flush_issued = true;
            return state_a;
          }) &&
          missing_fifo_flush_issued && missing_fifo.try_snapshot(snapshot) &&
          !snapshot.valid_header(),
      "non-ZLP WR_DONE without a positive FIFO write did not poison the "
      "diagnostic record");

  R19HwcdcFifoDiagnosticRecord zero_fifo{};
  report.check(zero_fifo.initialize(state_a) &&
                   zero_fifo.record_fifo_write(0U, state_a) &&
                   !zero_fifo.record_wr_done(state_a) &&
                   zero_fifo.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "zero-byte FIFO write incorrectly authorized non-ZLP "
               "WR_DONE");

  R19HwcdcFifoDiagnosticRecord pickup_before_done{};
  report.check(pickup_before_done.initialize(state_a) &&
                   pickup_before_done.record_fifo_write(17U, state_a) &&
                   !pickup_before_done.record_in_empty(true, state_a) &&
                   pickup_before_done.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "payload IN_EMPTY before non-ZLP WR_DONE did not poison the "
               "diagnostic record");

  R19HwcdcFifoDiagnosticRecord ordered{};
  report.check(ordered.initialize(state_a) &&
                   ordered.record_fifo_write(17U, state_a) &&
                   ordered.record_wr_done(state_a) &&
                   ordered.record_in_empty(true, state_a) &&
                   ordered.try_snapshot(snapshot) && snapshot.valid_header() &&
                   snapshot.payload_in_empty_count == 1U &&
                   snapshot.wr_done_count - snapshot.zlp_flush_count == 1U &&
                   snapshot.fifo_write_attempt_count -
                           snapshot.fifo_zero_write_count ==
                       1U,
               "ordered FIFO/WR_DONE/payload pickup chain was rejected");
}

void test_payload_publish_pending_closes_historical_success_gap(
    TestReport& report) {
  constexpr std::uint32_t pending =
      flag(R19HwcdcFifoDiagnosticFlag::PayloadPublishPending);
  constexpr std::uint32_t aborted =
      flag(R19HwcdcFifoDiagnosticFlag::PayloadPublishAborted);
  constexpr std::uint32_t flush_pending =
      flag(R19HwcdcFifoDiagnosticFlag::PayloadFlushPending);
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  R19HwcdcFifoDiagnosticState first_in_flight = state_b;
  first_in_flight.flush_blocker_mask = 0U;
  R19HwcdcFifoDiagnosticState first_settled = state_b_settled;
  first_settled.flush_blocker_mask = 0U;
  R19HwcdcFifoDiagnosticState second_in_flight = first_in_flight;
  second_in_flight.publish_generation = 13U;
  second_in_flight.pickup_generation = 12U;
  R19HwcdcFifoDiagnosticState second_settled = first_settled;
  second_settled.publish_generation = 13U;
  second_settled.pickup_generation = 13U;

  // Establish a complete historical payload and successful flush. The next
  // positive FIFO write must not be mistaken for that historical completion.
  report.check(record.initialize(state_a) &&
                   record.record_fifo_write(17U, state_a) &&
                   record.record_wr_done(first_in_flight) &&
                   record.record_in_empty(true, first_settled) &&
                   record.record_flush_attempt(first_settled) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, first_settled) &&
                   record.record_flush_success(first_settled),
               "historical-success pending fixture setup failed");
  report.check(record.record_fifo_write(19U, first_settled) &&
                   record.try_snapshot(snapshot) && snapshot.valid_header() &&
                   (snapshot.flags & pending) != 0U &&
                    (snapshot.flags & flush_pending) != 0U &&
                   snapshot.fifo_write_attempt_count == 2U &&
                   snapshot.fifo_zero_write_count == 0U &&
                   snapshot.wr_done_count - snapshot.zlp_flush_count == 1U &&
                   snapshot.flush_success_count == 1U,
               "second positive FIFO write did not publish an explicit "
               "incomplete payload witness over historical success");

  report.check(record.observe_state(first_settled) &&
                   record.try_snapshot(snapshot) &&
                   (snapshot.flags & pending) != 0U,
               "unrelated state observation erased PayloadPublishPending");

  bool flush_issued = false;
  report.check(record.record_wr_done([&]() noexcept {
                   flush_issued = true;
                    return second_in_flight;
                 }) &&
                   flush_issued && record.try_snapshot(snapshot) &&
                   snapshot.valid_header() &&
                   (snapshot.flags & pending) == 0U &&
                    (snapshot.flags & flush_pending) != 0U &&
                   snapshot.wr_done_count - snapshot.zlp_flush_count == 2U,
               "payload WR_DONE did not clear pending only after the hardware "
               "flush callback completed");

  report.check(record.record_in_empty(true, second_settled) &&
                    record.observe_state(second_settled) &&
                   record.try_snapshot(snapshot) && snapshot.valid_header() &&
                   (snapshot.flags & pending) == 0U &&
                   (snapshot.flags & flush_pending) != 0U &&
                   snapshot.flush_success_count == 1U,
               "payload pickup/observation erased the new-publication flush "
               "witness and exposed historical flush success");
  report.check(record.record_flush_attempt(second_settled) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, second_settled) &&
                   record.record_flush_success(second_settled) &&
                   record.try_snapshot(snapshot) && snapshot.valid_header() &&
                   (snapshot.flags & flush_pending) == 0U &&
                   snapshot.flush_success_count == 2U,
               "a new clean flush success did not close the publication-bound "
               "flush witness");

  R19HwcdcFifoDiagnosticRecord zero{};
  report.check(zero.initialize(state_a) &&
                   zero.record_fifo_write(0U, state_a) &&
                   zero.try_snapshot(snapshot) &&
                   (snapshot.flags & pending) == 0U,
               "zero-byte FIFO write incorrectly armed payload pending");

  R19HwcdcFifoDiagnosticRecord reset_abort{};
  report.check(reset_abort.initialize(state_a) &&
                   reset_abort.record_fifo_write(11U, state_a) &&
                   reset_abort.record_bus_reset(state_a) &&
                   reset_abort.try_snapshot(snapshot) &&
                   snapshot.valid_header() &&
                   (snapshot.flags & pending) == 0U &&
                    (snapshot.flags & flush_pending) == 0U &&
                   (snapshot.flags & aborted) != 0U &&
                   snapshot.fifo_write_attempt_count -
                           snapshot.fifo_zero_write_count ==
                       1U &&
                   snapshot.wr_done_count - snapshot.zlp_flush_count == 0U,
               "BUS_RESET did not clear pending while preserving the "
               "historical reset-aborted positive attempt and barrier");

  report.check(reset_abort.observe_state(state_a) &&
                   reset_abort.record_flush_attempt(state_a) &&
                   reset_abort.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   reset_abort.record_flush_success(state_a) &&
                   reset_abort.try_snapshot(snapshot) &&
                   snapshot.valid_header() &&
                   (snapshot.flags & aborted) != 0U,
               "non-payload observation/ZLP events erased the BUS_RESET "
               "barrier and exposed historical completion");

  R19HwcdcFifoDiagnosticRecord task_abort{};
  bool task_abort_side_effect_ran = false;
  bool task_abort_record_was_odd = false;
  report.check(task_abort.initialize(state_a) &&
                   task_abort.record_fifo_write(13U, state_a) &&
                   task_abort.record_payload_publish_abort([&]() noexcept {
                     task_abort_side_effect_ran = true;
                     task_abort_record_was_odd =
                         R19HwcdcFifoDiagnosticRecordTestAccess::
                             active_writer(task_abort) == 1U &&
                         (R19HwcdcFifoDiagnosticRecordTestAccess::
                              sequence(task_abort) &
                          1U) != 0U;
                      return state_b_settled;
                   }) &&
                   task_abort_side_effect_ran && task_abort_record_was_odd &&
                   task_abort.try_snapshot(snapshot) &&
                   snapshot.valid_header() &&
                   (snapshot.flags & pending) == 0U &&
                    (snapshot.flags & flush_pending) == 0U &&
                   (snapshot.flags & aborted) != 0U &&
                   snapshot.fifo_write_attempt_count == 1U &&
                   snapshot.wr_done_count == 0U,
               "task-side reset/rollback did not clear pending while "
               "publishing an abort witness for the discarded attempt");

  R19HwcdcFifoDiagnosticRecord uninitialized_abort{};
  bool uninitialized_side_effect_ran = false;
  report.check(!uninitialized_abort.record_payload_publish_abort(
                   [&]() noexcept {
                     uninitialized_side_effect_ran = true;
                     return state_a;
                   }) &&
                   uninitialized_side_effect_ran,
               "uninitialized diagnostic record suppressed the production "
               "task-discard side effect");

  R19HwcdcFifoDiagnosticRecord invalid_abort{};
  R19HwcdcFifoDiagnosticState invalid_abort_state = state_a;
  invalid_abort_state.publish_generation =
      static_cast<std::uint32_t>(invalid_abort_state.pickup_generation + 1U);
  report.check(invalid_abort.initialize(state_a) &&
                   invalid_abort.record_fifo_write(3U, state_a) &&
                   !invalid_abort.record_payload_publish_abort(
                       [&]() noexcept { return invalid_abort_state; }) &&
                   invalid_abort.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "invalid post-discard state left a stable stale diagnostic "
               "record after the production side effect");

  // A later task-side discard must not erase a clean ISR BUS_RESET and expose
  // an older successful flush as the apparent completion of the latest
  // attempt. The explicit abort witness remains dominant even though the task
  // state no longer carries the raw reset status.
  R19HwcdcFifoDiagnosticRecord reset_then_task_abort{};
  report.check(reset_then_task_abort.initialize(state_a) &&
                   reset_then_task_abort.record_fifo_write(17U, state_a) &&
                   reset_then_task_abort.record_wr_done(state_a) &&
                   reset_then_task_abort.record_flush_attempt(state_a) &&
                   reset_then_task_abort.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   reset_then_task_abort.record_flush_success(state_a) &&
                   reset_then_task_abort.record_bus_reset(state_a) &&
                   reset_then_task_abort.record_payload_publish_abort(
                       state_b_settled) &&
                   reset_then_task_abort.try_snapshot(snapshot) &&
                   snapshot.valid_header() &&
                   (snapshot.flags & pending) == 0U &&
                    (snapshot.flags & flush_pending) == 0U &&
                   (snapshot.flags & aborted) != 0U &&
                   snapshot.flush_success_count == 1U &&
                   snapshot.bus_reset_count == 1U &&
                    snapshot.last_interrupt_status ==
                        state_b_settled.interrupt_status,
               "task discard after clean BUS_RESET erased the last-event "
               "abort witness and exposed historical success");

  report.check(reset_then_task_abort.record_fifo_write(5U, state_a) &&
                   reset_then_task_abort.try_snapshot(snapshot) &&
                   (snapshot.flags & pending) != 0U &&
                    (snapshot.flags & flush_pending) != 0U &&
                   (snapshot.flags & aborted) == 0U,
               "a new positive FIFO publication did not supersede the prior "
               "task-discard abort witness");

  report.check(reset_then_task_abort.record_wr_done(state_a) &&
                   reset_then_task_abort.record_in_empty(true, state_a) &&
                   reset_then_task_abort.record_flush_attempt(state_a) &&
                   reset_then_task_abort.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   reset_then_task_abort.record_flush_success(state_a) &&
                   reset_then_task_abort.try_snapshot(snapshot) &&
                   snapshot.valid_header() &&
                   (snapshot.flags & pending) == 0U &&
                    (snapshot.flags & flush_pending) == 0U &&
                   (snapshot.flags & aborted) == 0U,
               "a complete new positive publication did not supersede the "
               "BUS_RESET/task-discard barrier");

  R19HwcdcFifoDiagnosticRecord duplicate{};
  report.check(duplicate.initialize(state_a) &&
                   duplicate.record_fifo_write(7U, state_a) &&
                   !duplicate.record_fifo_write(9U, state_a) &&
                   duplicate.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "duplicate positive publish before WR_DONE did not poison the "
               "diagnostic record");
}

void test_zlp_wr_done_origin_is_one_transaction(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot before{};
  R19HwcdcFifoDiagnosticSnapshot after{};
  report.check(record.initialize(state_a) &&
                   record.record_flush_attempt(state_a) &&
                   record.try_snapshot(before),
               "atomic ZLP WR_DONE fixture initialization failed");

  report.check(record.record_zlp_wr_done(
                   R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   record.try_snapshot(after),
               "task-origin ZLP WR_DONE event was rejected");
  report.check(after.sequence == before.sequence + 2U &&
                   after.wr_done_count == 1U &&
                   after.zlp_flush_count == 1U &&
                   after.last_flush_task_zlp_count == 1U &&
                   after.last_flush_isr_zlp_count == 0U,
               "task ZLP WR_DONE counters were not one seqlock transaction");

  before = after;
  report.check(record.record_zlp_wr_done(
                   R19HwcdcFifoZlpOrigin::Isr, state_a) &&
                   record.try_snapshot(after),
               "ISR-origin ZLP WR_DONE event was rejected");
  report.check(after.sequence == before.sequence + 2U &&
                   after.wr_done_count == 2U &&
                   after.zlp_flush_count == 2U &&
                   after.last_flush_task_zlp_count == 1U &&
                   after.last_flush_isr_zlp_count == 1U,
               "ISR ZLP WR_DONE counters were not one seqlock transaction");

  R19HwcdcFifoDiagnosticState abort_state = state_a;
  abort_state.flush_blocker_mask =
      blocker(R19HwcdcFifoFlushBlocker::EpochMismatch);
  report.check(record.record_flush_abort(abort_state) &&
                   record.try_snapshot(before) &&
                   record.record_zlp_wr_done(
                        R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   record.try_snapshot(after),
               "out-of-attempt cumulative ZLP WR_DONE event was rejected");
  report.check(after.sequence == before.sequence + 2U &&
                   after.wr_done_count == 3U &&
                   after.zlp_flush_count == 3U &&
                   after.last_flush_task_zlp_count == 1U &&
                   after.last_flush_isr_zlp_count == 1U,
               "out-of-attempt ZLP changed retained attempt-local evidence");

  before = after;
  report.check(!record.record_zlp_wr_done(
                   static_cast<R19HwcdcFifoZlpOrigin>(2U), state_a) &&
                   record.try_snapshot(after) &&
                   after.sequence == before.sequence &&
                   after.wr_done_count == before.wr_done_count &&
                   after.zlp_flush_count == before.zlp_flush_count &&
                   after.last_flush_task_zlp_count ==
                       before.last_flush_task_zlp_count &&
                   after.last_flush_isr_zlp_count ==
                       before.last_flush_isr_zlp_count,
               "invalid ZLP origin mutated the diagnostic record");
}

void test_zlp_hardware_boundary_is_fail_closed(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot before{};
  R19HwcdcFifoDiagnosticSnapshot during{};
  R19HwcdcFifoDiagnosticSnapshot after{};
  bool before_flush_snapshot_rejected = false;
  bool after_flush_snapshot_rejected = false;
  bool flush_issued = false;

  report.check(record.initialize(state_a) &&
                   record.record_flush_attempt(state_a) &&
                   record.try_snapshot(before),
               "ZLP hardware-boundary fixture initialization failed");
  report.check(record.record_zlp_wr_done(
                   R19HwcdcFifoZlpOrigin::Isr,
                   [&]() noexcept {
                     before_flush_snapshot_rejected =
                         !record.try_snapshot(during, 1U) &&
                         R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(
                             record) == 1U &&
                         (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(
                              record) &
                          1U) != 0U;
                     flush_issued = true;
                     after_flush_snapshot_rejected =
                         !record.try_snapshot(during, 1U) &&
                         R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(
                             record) == 1U &&
                         (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(
                              record) &
                          1U) != 0U;
                      return state_a;
                   }) &&
                   record.try_snapshot(after),
               "ZLP hardware-boundary transaction was rejected");
  report.check(before_flush_snapshot_rejected && flush_issued &&
                   after_flush_snapshot_rejected,
               "snapshot did not fail closed immediately around ZLP issue");
  report.check(after.sequence == before.sequence + 2U &&
                   after.wr_done_count == 1U &&
                   after.zlp_flush_count == 1U &&
                   after.last_flush_task_zlp_count == 0U &&
                   after.last_flush_isr_zlp_count == 1U &&
                   after.flags ==
                        (state_a.flags |
                        flag(R19HwcdcFifoDiagnosticFlag::Initialized) |
                        flag(R19HwcdcFifoDiagnosticFlag::FlushActive)) &&
                    after.tx_loss_epoch == state_a.tx_loss_epoch &&
                    after.publish_generation == state_a.publish_generation &&
                    after.pickup_generation == state_a.pickup_generation &&
                   after.last_ring_pending_bytes ==
                        state_a.ring_pending_bytes &&
                   after.last_stash_pending_bytes ==
                        state_a.stash_pending_bytes,
               "ZLP hardware issue and accounting did not commit together");

  R19HwcdcFifoDiagnosticRecord invalid_state_record{};
  R19HwcdcFifoDiagnosticSnapshot invalid_snapshot{};
  R19HwcdcFifoDiagnosticState invalid_state = state_a;
  invalid_state.publish_generation =
      static_cast<std::uint32_t>(invalid_state.pickup_generation + 1U);
  bool invalid_state_flush_issued = false;
  report.check(invalid_state_record.initialize(state_a) &&
                   !invalid_state_record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task,
                       [&]() noexcept {
                         invalid_state_flush_issued = true;
                         return invalid_state;
                       }) &&
                   invalid_state_record.try_snapshot(invalid_snapshot),
               "invalid post-flush state fixture was rejected unexpectedly");
  report.check(invalid_state_flush_issued &&
                   !invalid_snapshot.valid_header(),
               "invalid post-flush state left a stable valid stale record");
}

void test_payload_wr_done_hardware_boundary_is_fail_closed(
    TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot before{};
  R19HwcdcFifoDiagnosticSnapshot during{};
  R19HwcdcFifoDiagnosticSnapshot after{};
  bool before_flush_snapshot_rejected = false;
  bool after_flush_snapshot_rejected = false;
  bool flush_issued = false;

  report.check(record.initialize(state_a) &&
                   record.record_fifo_write(17U, state_a) &&
                   record.try_snapshot(before),
               "payload WR_DONE hardware-boundary fixture initialization "
               "failed");
  report.check(record.record_wr_done([&]() noexcept {
                   before_flush_snapshot_rejected =
                       !record.try_snapshot(during, 1U) &&
                       R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(
                           record) == 1U &&
                       (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(
                            record) &
                        1U) != 0U;
                   flush_issued = true;
                   after_flush_snapshot_rejected =
                       !record.try_snapshot(during, 1U) &&
                       R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(
                           record) == 1U &&
                       (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(
                            record) &
                        1U) != 0U;
                   return state_b;
                 }) &&
                   record.try_snapshot(after),
               "payload WR_DONE hardware-boundary transaction was rejected");
  report.check(before_flush_snapshot_rejected && flush_issued &&
                   after_flush_snapshot_rejected,
               "snapshot did not fail closed immediately around payload "
               "WR_DONE issue");
  report.check(after.sequence == before.sequence + 2U &&
                   after.wr_done_count == 1U &&
                   after.zlp_flush_count == 0U &&
                   snapshot_has_state_with_record_flags(
                       after, state_b,
                       flag(R19HwcdcFifoDiagnosticFlag::PayloadFlushPending)),
               "payload hardware issue and WR_DONE state did not commit "
               "together");

  R19HwcdcFifoDiagnosticRecord invalid_state_record{};
  R19HwcdcFifoDiagnosticSnapshot invalid_snapshot{};
  R19HwcdcFifoDiagnosticState invalid_state = state_a;
  invalid_state.publish_generation =
      static_cast<std::uint32_t>(invalid_state.pickup_generation + 1U);
  bool invalid_state_flush_issued = false;
  report.check(invalid_state_record.initialize(state_a) &&
                   invalid_state_record.record_fifo_write(17U, state_a) &&
                   !invalid_state_record.record_wr_done([&]() noexcept {
                     invalid_state_flush_issued = true;
                     return invalid_state;
                   }) &&
                   invalid_state_record.try_snapshot(invalid_snapshot),
               "invalid payload post-flush state fixture was rejected "
               "unexpectedly");
  report.check(invalid_state_flush_issued &&
                   !invalid_snapshot.valid_header(),
               "invalid payload post-flush state left a stable valid stale "
               "record");

  R19HwcdcFifoDiagnosticRecord uninitialized_record{};
  R19HwcdcFifoDiagnosticSnapshot uninitialized_snapshot{};
  std::uint32_t uninitialized_flush_count = 0U;
  report.check(!uninitialized_record.record_wr_done([&]() noexcept {
                 ++uninitialized_flush_count;
                 return state_a;
               }) &&
                   uninitialized_flush_count == 1U &&
                   uninitialized_record.try_snapshot(uninitialized_snapshot) &&
                   !uninitialized_snapshot.valid_header(),
               "uninitialized diagnostics suppressed or duplicated the "
               "payload hardware flush");
}

void test_fifo_write_hardware_boundary_is_fail_closed(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot before{};
  R19HwcdcFifoDiagnosticSnapshot during{};
  R19HwcdcFifoDiagnosticSnapshot after{};
  bool before_write_snapshot_rejected = false;
  bool after_write_snapshot_rejected = false;
  bool write_issued = false;

  report.check(record.initialize(state_a) && record.try_snapshot(before),
               "FIFO-write hardware-boundary fixture initialization failed");
  report.check(record.record_fifo_write([&]() noexcept {
                   before_write_snapshot_rejected =
                       !record.try_snapshot(during, 1U) &&
                       R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(
                           record) == 1U &&
                       (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(
                            record) &
                        1U) != 0U;
                   write_issued = true;
                   after_write_snapshot_rejected =
                       !record.try_snapshot(during, 1U) &&
                       R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(
                           record) == 1U &&
                       (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(
                            record) &
                        1U) != 0U;
                    return R19HwcdcFifoWriteResult{17U, state_a};
                 }) &&
                   record.try_snapshot(after),
               "FIFO-write hardware-boundary transaction was rejected");
  report.check(before_write_snapshot_rejected && write_issued &&
                   after_write_snapshot_rejected,
               "snapshot did not fail closed immediately around FIFO write");
  report.check(after.sequence == before.sequence + 2U &&
                   after.fifo_write_attempt_count == 1U &&
                   after.fifo_write_bytes == 17U &&
                   after.fifo_zero_write_count == 0U &&
                   after.last_fifo_write_size == 17U &&
                    snapshot_has_state_with_record_flags(
                         after, state_a,
                        flag(R19HwcdcFifoDiagnosticFlag::
                                 PayloadPublishPending) |
                            flag(R19HwcdcFifoDiagnosticFlag::
                                     PayloadFlushPending)),
               "FIFO hardware write and diagnostic accounting did not "
               "commit together");

  R19HwcdcFifoDiagnosticRecord invalid_state_record{};
  R19HwcdcFifoDiagnosticSnapshot invalid_snapshot{};
  R19HwcdcFifoDiagnosticState invalid_state = state_a;
  invalid_state.publish_generation =
      static_cast<std::uint32_t>(invalid_state.pickup_generation + 1U);
  bool invalid_state_write_issued = false;
  report.check(invalid_state_record.initialize(state_a) &&
                   !invalid_state_record.record_fifo_write([&]() noexcept {
                     invalid_state_write_issued = true;
                     return R19HwcdcFifoWriteResult{17U, invalid_state};
                   }) &&
                   invalid_state_record.try_snapshot(invalid_snapshot),
               "invalid FIFO post-write state fixture was rejected "
               "unexpectedly");
  report.check(invalid_state_write_issued &&
                   !invalid_snapshot.valid_header(),
               "invalid FIFO post-write state left a stable valid stale "
               "record");

  R19HwcdcFifoDiagnosticRecord uninitialized_record{};
  R19HwcdcFifoDiagnosticSnapshot uninitialized_snapshot{};
  std::uint32_t uninitialized_write_count = 0U;
  report.check(!uninitialized_record.record_fifo_write([&]() noexcept {
                 ++uninitialized_write_count;
                 return R19HwcdcFifoWriteResult{17U, state_a};
               }) &&
                   uninitialized_write_count == 1U &&
                   uninitialized_record.try_snapshot(uninitialized_snapshot) &&
                   !uninitialized_snapshot.valid_header(),
               "uninitialized diagnostics suppressed or duplicated the "
               "FIFO hardware write");
}

void test_in_empty_hardware_boundary_is_fail_closed(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot before{};
  R19HwcdcFifoDiagnosticSnapshot during{};
  R19HwcdcFifoDiagnosticSnapshot after{};
  bool before_action_snapshot_rejected = false;
  bool after_action_snapshot_rejected = false;
  bool action_issued = false;

  report.check(record.initialize(state_a) &&
                   record.record_fifo_write(17U, state_a) &&
                    record.record_wr_done(state_b) &&
                   record.try_snapshot(before),
               "IN_EMPTY hardware-boundary fixture initialization failed");
  report.check(record.record_in_empty(true, [&]() noexcept {
                   before_action_snapshot_rejected =
                       !record.try_snapshot(during, 1U) &&
                       R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(
                           record) == 1U &&
                       (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(
                            record) &
                        1U) != 0U;
                   action_issued = true;
                   after_action_snapshot_rejected =
                       !record.try_snapshot(during, 1U) &&
                       R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(
                           record) == 1U &&
                       (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(
                            record) &
                        1U) != 0U;
                    return state_b_settled;
                 }) &&
                   record.try_snapshot(after),
               "IN_EMPTY hardware-boundary transaction was rejected");
  report.check(before_action_snapshot_rejected && action_issued &&
                   after_action_snapshot_rejected,
               "snapshot did not fail closed around IN_EMPTY side effects");
  report.check(after.sequence == before.sequence + 2U &&
                   after.in_empty_irq_count == 1U &&
                   after.payload_in_empty_count == 1U &&
                   snapshot_has_state_with_record_flags(
                        after, state_b_settled,
                       flag(R19HwcdcFifoDiagnosticFlag::PayloadFlushPending)),
               "IN_EMPTY side effects and pickup accounting did not commit "
               "together");

  R19HwcdcFifoDiagnosticRecord invalid_state_record{};
  R19HwcdcFifoDiagnosticSnapshot invalid_snapshot{};
  R19HwcdcFifoDiagnosticState invalid_state = state_a;
  invalid_state.publish_generation =
      static_cast<std::uint32_t>(invalid_state.pickup_generation + 1U);
  bool invalid_state_action_issued = false;
  report.check(invalid_state_record.initialize(state_a) &&
                   !invalid_state_record.record_in_empty(
                       false, [&]() noexcept {
                         invalid_state_action_issued = true;
                         return invalid_state;
                       }) &&
                   invalid_state_record.try_snapshot(invalid_snapshot),
               "invalid IN_EMPTY post-action state fixture was rejected "
               "unexpectedly");
  report.check(invalid_state_action_issued &&
                   !invalid_snapshot.valid_header(),
               "invalid IN_EMPTY post-action state left a stable valid stale "
               "record");

  R19HwcdcFifoDiagnosticRecord uninitialized_record{};
  R19HwcdcFifoDiagnosticSnapshot uninitialized_snapshot{};
  std::uint32_t uninitialized_action_count = 0U;
  report.check(!uninitialized_record.record_in_empty(false, [&]() noexcept {
                 ++uninitialized_action_count;
                 return state_a;
               }) &&
                   uninitialized_action_count == 1U &&
                   uninitialized_record.try_snapshot(uninitialized_snapshot) &&
                   !uninitialized_snapshot.valid_header(),
               "uninitialized diagnostics suppressed or duplicated IN_EMPTY "
               "side effects");
}

void test_bus_reset_hardware_boundary_is_fail_closed(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot before{};
  R19HwcdcFifoDiagnosticSnapshot during{};
  R19HwcdcFifoDiagnosticSnapshot after{};
  bool before_reset_snapshot_rejected = false;
  bool after_reset_snapshot_rejected = false;
  bool reset_issued = false;
  constexpr std::uint32_t source_interrupt_status = 0xC0DEC001U;
  R19HwcdcFifoDiagnosticState post_reset_state = state_b_settled;
  post_reset_state.interrupt_status = 0U;

  report.check(record.initialize(state_a) && record.try_snapshot(before),
               "BUS_RESET hardware-boundary fixture initialization failed");
  report.check(record.record_bus_reset([&]() noexcept {
                   before_reset_snapshot_rejected =
                       !record.try_snapshot(during, 1U) &&
                       R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(
                           record) == 1U &&
                       (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(
                            record) &
                        1U) != 0U;
                   reset_issued = true;
                   after_reset_snapshot_rejected =
                       !record.try_snapshot(during, 1U) &&
                       R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(
                           record) == 1U &&
                       (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(
                            record) &
                        1U) != 0U;
                   return R19HwcdcFifoBusResetResult{
                       true, source_interrupt_status, post_reset_state};
                 }) &&
                   record.try_snapshot(after),
               "BUS_RESET hardware-boundary transaction was rejected");
  report.check(before_reset_snapshot_rejected && reset_issued &&
                   after_reset_snapshot_rejected,
               "snapshot did not fail closed around BUS_RESET side effects");
  report.check(after.sequence == before.sequence + 2U &&
                   after.bus_reset_count == 1U &&
                   after.in_empty_irq_count == 1U &&
                   after.payload_in_empty_count == 0U &&
                   after.flags ==
                       (post_reset_state.flags |
                        flag(R19HwcdcFifoDiagnosticFlag::Initialized) |
                        flag(R19HwcdcFifoDiagnosticFlag::
                                 PayloadPublishAborted)) &&
                   after.tx_loss_epoch == post_reset_state.tx_loss_epoch &&
                   after.publish_generation ==
                       post_reset_state.publish_generation &&
                   after.pickup_generation ==
                       post_reset_state.pickup_generation &&
                   after.last_ring_pending_bytes ==
                       post_reset_state.ring_pending_bytes &&
                   after.last_stash_pending_bytes ==
                       post_reset_state.stash_pending_bytes &&
                   after.last_interrupt_status == source_interrupt_status &&
                   after.last_flush_blocker_mask ==
                       post_reset_state.flush_blocker_mask,
               "BUS_RESET source interrupt and fresh post-clear state did "
               "not commit as one event transaction");

  R19HwcdcFifoDiagnosticRecord invalid_state_record{};
  R19HwcdcFifoDiagnosticSnapshot invalid_snapshot{};
  R19HwcdcFifoDiagnosticState invalid_state = state_a;
  invalid_state.publish_generation =
      static_cast<std::uint32_t>(invalid_state.pickup_generation + 1U);
  bool invalid_state_reset_issued = false;
  report.check(invalid_state_record.initialize(state_a) &&
                   !invalid_state_record.record_bus_reset([&]() noexcept {
                     invalid_state_reset_issued = true;
                     return R19HwcdcFifoBusResetResult{
                         false, invalid_state.interrupt_status, invalid_state};
                   }) &&
                   invalid_state_record.try_snapshot(invalid_snapshot),
               "invalid BUS_RESET post-action state fixture was rejected "
               "unexpectedly");
  report.check(invalid_state_reset_issued &&
                   !invalid_snapshot.valid_header(),
               "invalid BUS_RESET post-action state left a stable valid "
               "stale record");

  R19HwcdcFifoDiagnosticRecord uninitialized_record{};
  R19HwcdcFifoDiagnosticSnapshot uninitialized_snapshot{};
  std::uint32_t uninitialized_reset_count = 0U;
  report.check(!uninitialized_record.record_bus_reset([&]() noexcept {
                 ++uninitialized_reset_count;
                 return R19HwcdcFifoBusResetResult{
                     true, state_a.interrupt_status, state_a};
               }) &&
                   uninitialized_reset_count == 1U &&
                   uninitialized_record.try_snapshot(uninitialized_snapshot) &&
                   !uninitialized_snapshot.valid_header(),
               "uninitialized diagnostics suppressed or duplicated BUS_RESET "
               "side effects");
}

void test_flush_abort_accounting(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  R19HwcdcFifoDiagnosticState abort_state = state_b_settled;
  abort_state.flush_blocker_mask =
      blocker(R19HwcdcFifoFlushBlocker::EpochMismatch) |
      blocker(R19HwcdcFifoFlushBlocker::FifoNotWritable);
  report.check(record.initialize(state_a) &&
                   record.record_flush_attempt(state_a) &&
                   record.record_flush_abort(abort_state),
               "flush-abort fixture was rejected");
  report.check(record.try_snapshot(snapshot) &&
                   snapshot.flush_attempt_count == 1U &&
                   snapshot.flush_success_count == 0U &&
                   snapshot.flush_timeout_count == 0U &&
                   (snapshot.flags &
                    flag(R19HwcdcFifoDiagnosticFlag::FlushActive)) == 0U &&
                   snapshot_has_state(snapshot, abort_state),
               "flush abort did not close the active attempt without "
               "misclassifying it as success/timeout");

  const std::uint32_t active =
      (snapshot.flags & flag(R19HwcdcFifoDiagnosticFlag::FlushActive)) != 0U
          ? 1U
          : 0U;
  const std::uint32_t historical_aborts =
      snapshot.flush_attempt_count - snapshot.flush_success_count -
      snapshot.flush_timeout_count - active;
  report.check(historical_aborts == 1U,
               "fixed-ABI historical abort inference is not exact");
}

void test_timeout_latches_boundary_resample_atomically(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot before{};
  R19HwcdcFifoDiagnosticSnapshot after{};
  R19HwcdcFifoDiagnosticState terminal_state = state_b_settled;
  terminal_state.ring_pending_bytes = 31U;
  terminal_state.stash_pending_bytes = 7U;
  terminal_state.interrupt_status = 0x5A5A00C0U;
  terminal_state.flush_blocker_mask =
      blocker(R19HwcdcFifoFlushBlocker::HostAbsent) |
      blocker(R19HwcdcFifoFlushBlocker::ResetPending);

  report.check(record.initialize(state_a) &&
                   record.record_flush_attempt(state_a) &&
                   record.observe_state(state_a) &&
                   record.try_snapshot(before),
               "timeout boundary-resample fixture initialization failed");
  report.check(record.record_flush_timeout(terminal_state) &&
                   record.try_snapshot(after),
               "fresh terminal timeout sample was rejected");
  report.check(after.sequence == before.sequence + 2U &&
                   after.last_flush_outcome == static_cast<std::uint32_t>(
                       R19HwcdcFifoFlushOutcome::Timeout) &&
                   after.last_flush_terminal_blocker_mask ==
                       terminal_state.flush_blocker_mask &&
                   snapshot_has_state(after, terminal_state),
               "timeout outcome and boundary-resampled blockers were not "
               "one terminal transaction");
}

void test_per_attempt_flush_diagnostics(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  R19HwcdcFifoDiagnosticState clean_state = state_a;
  clean_state.flush_blocker_mask = 0U;
  R19HwcdcFifoDiagnosticState blocked_state = state_a;
  blocked_state.flush_blocker_mask =
      blocker(R19HwcdcFifoFlushBlocker::FifoNotWritable);
  R19HwcdcFifoDiagnosticState abort_state = state_a;
  abort_state.flush_blocker_mask =
      blocker(R19HwcdcFifoFlushBlocker::EpochMismatch);

  report.check(record.initialize(state_a) && record.try_snapshot(snapshot) &&
                   snapshot.last_flush_outcome == static_cast<std::uint32_t>(
                       R19HwcdcFifoFlushOutcome::None) &&
                   snapshot.last_flush_task_zlp_count == 0U &&
                   snapshot.last_flush_isr_zlp_count == 0U &&
                   snapshot.last_flush_terminal_blocker_mask == 0U,
               "initialize did not clear per-attempt flush evidence");
  report.check(record.record_zlp_wr_done(
                   R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Isr, state_a) &&
                   record.try_snapshot(snapshot) &&
                   snapshot.last_flush_task_zlp_count == 0U &&
                   snapshot.last_flush_isr_zlp_count == 0U,
               "out-of-attempt ZLP changed attempt-local origin evidence");

  report.check(record.record_flush_attempt(state_a) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   record.record_zlp_wr_done(
                        R19HwcdcFifoZlpOrigin::Isr, blocked_state) &&
                    record.observe_state(blocked_state) &&
                   record.try_snapshot(snapshot),
               "active flush evidence fixture was rejected");
  report.check(snapshot.last_flush_outcome == static_cast<std::uint32_t>(
                       R19HwcdcFifoFlushOutcome::Active) &&
                   snapshot.last_flush_task_zlp_count == 2U &&
                   snapshot.last_flush_isr_zlp_count == 1U &&
                   snapshot.last_flush_terminal_blocker_mask == 0U,
               "active attempt did not preserve task/ISR ZLP accounting");

  report.check(record.record_flush_timeout(blocked_state) &&
                   record.try_snapshot(snapshot),
               "timeout outcome fixture was rejected");
  report.check(snapshot.last_flush_outcome == static_cast<std::uint32_t>(
                       R19HwcdcFifoFlushOutcome::Timeout) &&
                   snapshot.last_flush_task_zlp_count == 2U &&
                   snapshot.last_flush_isr_zlp_count == 1U &&
                   snapshot.last_flush_terminal_blocker_mask ==
                        blocked_state.flush_blocker_mask,
               "timeout did not latch its final blocker and ZLP evidence");

  report.check(record.record_flush_attempt(blocked_state) &&
                   record.try_snapshot(snapshot),
               "second flush attempt was rejected");
  report.check(snapshot.last_flush_outcome == static_cast<std::uint32_t>(
                       R19HwcdcFifoFlushOutcome::Active) &&
                   snapshot.last_flush_task_zlp_count == 0U &&
                   snapshot.last_flush_isr_zlp_count == 0U &&
                   snapshot.last_flush_terminal_blocker_mask == 0U,
               "new attempt retained stale outcome, ZLP, or blocker evidence");
  report.check(record.record_zlp_wr_done(
                    R19HwcdcFifoZlpOrigin::Isr, blocked_state) &&
                   record.record_flush_abort(abort_state) &&
                   record.try_snapshot(snapshot) &&
                   snapshot.last_flush_outcome == static_cast<std::uint32_t>(
                       R19HwcdcFifoFlushOutcome::Abort) &&
                   snapshot.last_flush_task_zlp_count == 0U &&
                   snapshot.last_flush_isr_zlp_count == 1U &&
                   snapshot.last_flush_terminal_blocker_mask ==
                       abort_state.flush_blocker_mask,
               "abort did not latch its attempt-local ISR ZLP and blocker");

  report.check(record.record_flush_attempt(clean_state) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, clean_state) &&
                   record.record_flush_success(clean_state) &&
                   record.try_snapshot(snapshot) &&
                   snapshot.last_flush_outcome == static_cast<std::uint32_t>(
                       R19HwcdcFifoFlushOutcome::Success) &&
                   snapshot.last_flush_task_zlp_count == 1U &&
                   snapshot.last_flush_isr_zlp_count == 0U &&
                   snapshot.last_flush_terminal_blocker_mask == 0U,
               "success did not latch its clean final attempt evidence");
  report.check(record.record_zlp_wr_done(
                   R19HwcdcFifoZlpOrigin::Task, clean_state) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Isr, clean_state) &&
                   record.try_snapshot(snapshot) &&
                   snapshot.last_flush_task_zlp_count == 1U &&
                   snapshot.last_flush_isr_zlp_count == 0U,
               "terminated attempt changed retained ZLP origin evidence");
}

void test_flush_retry_inherits_one_terminal_zlp(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  R19HwcdcFifoDiagnosticState blocked_state = state_a;
  blocked_state.flush_blocker_mask =
      blocker(R19HwcdcFifoFlushBlocker::FifoNotWritable);
  R19HwcdcFifoDiagnosticState clean_state = state_a;
  clean_state.flush_blocker_mask = 0U;

  report.check(record.initialize(state_a) &&
                   record.record_flush_attempt(state_a) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, blocked_state) &&
                   record.record_flush_timeout(blocked_state) &&
                   record.record_flush_retry_attempt(blocked_state) &&
                   record.record_flush_success(clean_state) &&
                   record.try_snapshot(snapshot),
               "same-boundary flush retry fixture was rejected");
  report.check(snapshot.valid_header() &&
                   snapshot.flush_attempt_count == 2U &&
                   snapshot.flush_timeout_count == 1U &&
                   snapshot.flush_success_count == 1U &&
                   snapshot.zlp_flush_count == 1U &&
                   snapshot.last_flush_task_zlp_count == 1U &&
                   snapshot.last_flush_isr_zlp_count == 0U &&
                   snapshot.last_flush_outcome == static_cast<std::uint32_t>(
                       R19HwcdcFifoFlushOutcome::Success),
               "flush retry did not preserve exactly one terminal-ZLP owner");

  R19HwcdcFifoDiagnosticRecord no_timeout{};
  report.check(no_timeout.initialize(state_a) &&
                   !no_timeout.record_flush_retry_attempt(state_a),
               "flush retry without a prior timeout was accepted");

  R19HwcdcFifoDiagnosticRecord no_task_zlp{};
  report.check(no_task_zlp.initialize(state_a) &&
                   no_task_zlp.record_flush_attempt(state_a) &&
                   no_task_zlp.record_flush_timeout(blocked_state) &&
                   !no_task_zlp.record_flush_retry_attempt(blocked_state),
               "flush retry without a terminal task ZLP was accepted");

  R19HwcdcFifoDiagnosticRecord wrong_origin{};
  report.check(wrong_origin.initialize(state_a) &&
                   wrong_origin.record_flush_attempt(state_a) &&
                   wrong_origin.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Isr, blocked_state) &&
                   wrong_origin.record_flush_timeout(blocked_state) &&
                   !wrong_origin.record_flush_retry_attempt(blocked_state),
               "flush retry inherited an ISR-origin ZLP");

  R19HwcdcFifoDiagnosticRecord changed_identity{};
  R19HwcdcFifoDiagnosticState changed_epoch = blocked_state;
  changed_epoch.tx_loss_epoch += 1U;
  report.check(changed_identity.initialize(state_a) &&
                   changed_identity.record_flush_attempt(state_a) &&
                   changed_identity.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, blocked_state) &&
                   changed_identity.record_flush_timeout(blocked_state) &&
                   !changed_identity.record_flush_retry_attempt(changed_epoch),
               "flush retry inherited a terminal ZLP across loss epochs");

  R19HwcdcFifoDiagnosticRecord changed_generation{};
  R19HwcdcFifoDiagnosticState next_generation = blocked_state;
  next_generation.publish_generation += 1U;
  next_generation.pickup_generation += 1U;
  report.check(changed_generation.initialize(state_a) &&
                   changed_generation.record_flush_attempt(state_a) &&
                   changed_generation.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, blocked_state) &&
                   changed_generation.record_flush_timeout(blocked_state) &&
                   !changed_generation.record_flush_retry_attempt(
                       next_generation),
               "flush retry inherited a terminal ZLP across generations");
}

void test_per_attempt_zlp_counters_saturate(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  report.check(record.initialize(state_a),
               "per-attempt ZLP saturation initialization failed");
  R19HwcdcFifoDiagnosticRecordTestAccess::prime_active_flush_zlp_saturation(
      record);
  report.check(record.record_zlp_wr_done(
                   R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Isr, state_a),
               "saturated per-attempt ZLP events were rejected");
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  report.check(record.try_snapshot(snapshot) &&
                   snapshot.last_flush_task_zlp_count ==
                       std::numeric_limits<std::uint32_t>::max() &&
                   snapshot.last_flush_isr_zlp_count ==
                       std::numeric_limits<std::uint32_t>::max(),
               "per-attempt ZLP counters wrapped instead of saturating");
}

void test_reinitialize_clears_active_flush(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  report.check(record.initialize(state_a) &&
                   record.record_flush_attempt(state_a) &&
                   record.record_fifo_write(7U, state_a),
               "active-flush reinitialization fixture was rejected");
  report.check(record.initialize(state_b_settled) &&
                   record.try_snapshot(snapshot),
               "record could not be reinitialized during an active flush");
  report.check(
      (snapshot.flags & flag(R19HwcdcFifoDiagnosticFlag::FlushActive)) == 0U &&
          snapshot.flush_attempt_count == 0U &&
          snapshot.flush_success_count == 0U &&
          snapshot.flush_timeout_count == 0U &&
          snapshot.fifo_write_attempt_count == 0U &&
          snapshot.fifo_write_bytes == 0U &&
          snapshot.last_flush_outcome == static_cast<std::uint32_t>(
              R19HwcdcFifoFlushOutcome::None) &&
          snapshot.last_flush_task_zlp_count == 0U &&
          snapshot.last_flush_isr_zlp_count == 0U &&
          snapshot.last_flush_terminal_blocker_mask == 0U &&
          snapshot_has_state(snapshot, state_b_settled),
      "reinitialize retained stale active state, counters, or prior state");
  report.check(record.record_flush_attempt(state_b_settled),
               "stale FlushActive blocked the first post-reinitialize attempt");
}

void test_saturating_counters(TestReport& report) {
  constexpr std::uint32_t maximum =
      std::numeric_limits<std::uint32_t>::max();
  R19HwcdcFifoDiagnosticRecord record{};
  report.check(record.initialize(state_a),
               "counter saturation fixture initialization failed");
  R19HwcdcFifoDiagnosticRecordTestAccess::prime_saturated_counters(record);

  report.check(record.record_fifo_write(9U, state_a) &&
                   record.record_wr_done(state_b) &&
                   record.record_in_empty(true, state_b_settled) &&
                   record.record_bus_reset(state_b_settled),
               "saturation fixture event was rejected");

  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  report.check(record.try_snapshot(snapshot),
               "saturated record could not be snapshotted");
  report.check(snapshot.fifo_write_attempt_count == maximum &&
                   snapshot.fifo_write_bytes == maximum &&
                   snapshot.fifo_zero_write_count == 0U &&
                   snapshot.wr_done_count == maximum &&
                   snapshot.in_empty_irq_count == maximum &&
                   snapshot.payload_in_empty_count == maximum &&
                   snapshot.bus_reset_count == maximum &&
                   snapshot.flush_attempt_count == maximum &&
                   snapshot.flush_success_count == maximum &&
                   snapshot.flush_timeout_count == 0U &&
                   snapshot.zlp_flush_count == 0U,
               "one or more diagnostic counters wrapped instead of saturating");
  report.check(snapshot.last_fifo_write_size == 9U,
               "last FIFO write size did not retain the latest write");

  R19HwcdcFifoDiagnosticRecord timeout_record{};
  report.check(timeout_record.initialize(state_a),
               "timeout saturation fixture initialization failed");
  R19HwcdcFifoDiagnosticRecordTestAccess::prime_timeout_saturation(
      timeout_record);
  report.check(timeout_record.record_flush_timeout(state_b_settled),
               "last available flush timeout was rejected");
  report.check(timeout_record.try_snapshot(snapshot) &&
                   snapshot.flush_attempt_count == maximum &&
                   snapshot.flush_success_count == 0U &&
                   snapshot.flush_timeout_count == maximum,
               "flush timeout counter wrapped instead of saturating");
}

void test_rejects_inconsistent_state(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  R19HwcdcFifoDiagnosticState invalid_generation = state_a;
  invalid_generation.publish_generation =
      static_cast<std::uint32_t>(invalid_generation.pickup_generation + 1U);
  report.check(!record.initialize(invalid_generation),
               "non-flight mismatched generations were accepted");
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  report.check(record.try_snapshot(snapshot) && !snapshot.valid_header(),
               "rejected initialization modified the invalid zero record");

  R19HwcdcFifoDiagnosticState unknown_flag = state_a;
  unknown_flag.flags = static_cast<std::uint32_t>(unknown_flag.flags |
                                                  (1U << 31U));
  report.check(!record.initialize(unknown_flag),
               "an unknown diagnostic flag was accepted");

  R19HwcdcFifoDiagnosticState unknown_blocker = state_a;
  unknown_blocker.flush_blocker_mask =
      static_cast<std::uint32_t>(unknown_blocker.flush_blocker_mask |
                                 (1U << 31U));
  report.check(!record.initialize(unknown_blocker),
               "an unknown flush blocker was accepted");

  R19HwcdcFifoDiagnosticState invalid_in_flight = state_b;
  invalid_in_flight.publish_generation =
      invalid_in_flight.pickup_generation;
  report.check(!record.initialize(invalid_in_flight),
               "in-flight equal generations were accepted");

  R19HwcdcFifoDiagnosticState wrapped = state_b;
  wrapped.pickup_generation =
      std::numeric_limits<std::uint32_t>::max();
  wrapped.publish_generation = 0U;
  R19HwcdcFifoDiagnosticState wrapped_pre_publish = state_b_settled;
  wrapped_pre_publish.publish_generation =
      std::numeric_limits<std::uint32_t>::max();
  wrapped_pre_publish.pickup_generation =
      std::numeric_limits<std::uint32_t>::max();
  R19HwcdcFifoDiagnosticRecord wrapped_record{};
  report.check(wrapped_record.initialize(state_a) &&
                   wrapped_record.record_fifo_write(1U, wrapped_pre_publish) &&
                   wrapped_record.record_wr_done(wrapped) &&
                   wrapped_record.try_snapshot(snapshot) &&
                   snapshot.valid_header() &&
                   snapshot.publish_generation == 0U &&
                   snapshot.pickup_generation ==
                       std::numeric_limits<std::uint32_t>::max() &&
                   (snapshot.flags &
                    flag(R19HwcdcFifoDiagnosticFlag::PayloadFlushPending)) !=
                       0U,
               "wrap-safe in-flight generations were rejected");

  R19HwcdcFifoDiagnosticRecord rejected_events{};
  report.check(rejected_events.initialize(state_a) &&
                   !rejected_events.record_fifo_write(33U, state_a),
               "a FIFO write larger than the 32-byte hardware FIFO was accepted");
  report.check(!rejected_events.record_flush_success(state_a) &&
                    !rejected_events.record_flush_timeout(state_a),
               "a flush terminal outcome without an open attempt was accepted");
  report.check(rejected_events.try_snapshot(snapshot) &&
                   snapshot.fifo_write_attempt_count == 0U &&
                   snapshot.flush_success_count == 0U &&
                   snapshot.flush_timeout_count == 0U &&
                    snapshot.publish_generation == state_a.publish_generation &&
                    snapshot.pickup_generation == state_a.pickup_generation,
               "a rejected event changed counters or lost wrapped generations");

  R19HwcdcFifoDiagnosticRecord impossible_observation{};
  report.check(impossible_observation.initialize(state_a) &&
                   !impossible_observation.observe_state(state_b) &&
                   impossible_observation.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "unaccounted PayloadInFlight observation remained readable");

  R19HwcdcFifoDiagnosticRecord terminal_record{};
  report.check(terminal_record.initialize(state_a) &&
                   terminal_record.record_flush_attempt(state_a) &&
                   terminal_record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   terminal_record.record_flush_success(state_a) &&
                   !terminal_record.record_flush_timeout(state_a),
               "one flush attempt accepted more than one terminal outcome");
  report.check(terminal_record.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "duplicate terminal outcome left an old valid record");
}

void test_short_packet_flush_success_does_not_require_zlp(
    TestReport& report) {
  // The immutable 63-byte R19 diagnostic frame is published as 32 + 31
  // bytes.  The final USB packet is short, so payload pickup is the terminal
  // witness and no task/ISR ZLP is permitted or required.
  constexpr R19HwcdcFifoDiagnosticState idle{
      flag(R19HwcdcFifoDiagnosticFlag::ObservationActive) |
          flag(R19HwcdcFifoDiagnosticFlag::Connected) |
          flag(R19HwcdcFifoDiagnosticFlag::FifoWritable),
      3U, 0U, 0U, 0U, 0U, 0U, 0U};
  constexpr R19HwcdcFifoDiagnosticState published{
      flag(R19HwcdcFifoDiagnosticFlag::ObservationActive) |
          flag(R19HwcdcFifoDiagnosticFlag::Connected) |
          flag(R19HwcdcFifoDiagnosticFlag::PayloadInFlight),
      3U, 1U, 0U, 0U, 0U, 0U,
      blocker(R19HwcdcFifoFlushBlocker::FifoNotWritable)};
  constexpr R19HwcdcFifoDiagnosticState picked_up{
      flag(R19HwcdcFifoDiagnosticFlag::ObservationActive) |
          flag(R19HwcdcFifoDiagnosticFlag::Connected) |
          flag(R19HwcdcFifoDiagnosticFlag::FifoWritable),
      3U, 1U, 1U, 0U, 0U, 0U, 0U};

  R19HwcdcFifoDiagnosticRecord short_packet{};
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  report.check(short_packet.initialize(idle) &&
                   short_packet.record_fifo_write(31U, idle) &&
                   short_packet.record_wr_done(published) &&
                   short_packet.record_in_empty(true, picked_up) &&
                   short_packet.record_flush_attempt(picked_up) &&
                   short_packet.record_flush_success(picked_up, false) &&
                   short_packet.try_snapshot(snapshot),
               "a picked-up short final packet required a terminal ZLP");
  report.check(snapshot.valid_header() &&
                   snapshot.last_fifo_write_size == 31U &&
                   snapshot.flush_success_count == 1U &&
                   snapshot.last_flush_outcome == static_cast<std::uint32_t>(
                       R19HwcdcFifoFlushOutcome::Success) &&
                   snapshot.last_flush_task_zlp_count == 0U &&
                   snapshot.last_flush_isr_zlp_count == 0U &&
                   snapshot.zlp_flush_count == 0U,
               "short-packet success did not retain exact zero-ZLP evidence");

  // A full-size or otherwise unknown final packet keeps the historical,
  // fail-closed rule: its success needs a task-owned terminal ZLP.
  R19HwcdcFifoDiagnosticRecord full_without_zlp{};
  report.check(full_without_zlp.initialize(idle) &&
                   full_without_zlp.record_flush_attempt(idle) &&
                   !full_without_zlp.record_flush_success(idle, true) &&
                   full_without_zlp.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "a full/unknown final packet succeeded without a task ZLP");

  // The explicit strict policy and the legacy one-argument call must both
  // continue accepting historical records with one task-origin final ZLP.
  R19HwcdcFifoDiagnosticRecord strict_with_zlp{};
  report.check(strict_with_zlp.initialize(idle) &&
                   strict_with_zlp.record_flush_attempt(idle) &&
                   strict_with_zlp.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, idle) &&
                   strict_with_zlp.record_flush_success(idle, true) &&
                   strict_with_zlp.try_snapshot(snapshot) &&
                   snapshot.valid_header() &&
                   snapshot.last_flush_task_zlp_count == 1U,
               "strict full-packet policy broke task-ZLP history");
}

void test_invalid_lifecycle_transition_poison(TestReport& report) {
  R19HwcdcFifoDiagnosticSnapshot snapshot{};

  R19HwcdcFifoDiagnosticRecord duplicate_attempt{};
  report.check(duplicate_attempt.initialize(state_a) &&
                   duplicate_attempt.record_flush_attempt(state_a) &&
                   !duplicate_attempt.record_flush_attempt(state_b) &&
                   duplicate_attempt.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "nested flush attempt left the previous active record valid");

  R19HwcdcFifoDiagnosticRecord success_without_task_zlp{};
  report.check(success_without_task_zlp.initialize(state_a) &&
                   success_without_task_zlp.record_flush_attempt(state_a) &&
                   !success_without_task_zlp.record_flush_success(state_a) &&
                   success_without_task_zlp.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "flush success without a task ZLP left the record valid");

  R19HwcdcFifoDiagnosticRecord success_with_blocker{};
  report.check(success_with_blocker.initialize(state_a) &&
                   success_with_blocker.record_flush_attempt(state_a) &&
                   success_with_blocker.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   !success_with_blocker.record_flush_success(state_b) &&
                   success_with_blocker.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "flush success with a terminal blocker left the record valid");

  R19HwcdcFifoDiagnosticRecord abort_without_epoch_mismatch{};
  report.check(abort_without_epoch_mismatch.initialize(state_a) &&
                   abort_without_epoch_mismatch.record_flush_attempt(state_a) &&
                   !abort_without_epoch_mismatch.record_flush_abort(state_a) &&
                   abort_without_epoch_mismatch.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "flush abort without EpochMismatch left the record valid");

  R19HwcdcFifoDiagnosticRecord terminal_without_attempt{};
  report.check(terminal_without_attempt.initialize(state_a) &&
                   !terminal_without_attempt.record_flush_timeout(state_a) &&
                   terminal_without_attempt.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "terminal transition without an active attempt left the "
               "record valid");

  R19HwcdcFifoDiagnosticState invalid_state = state_a;
  invalid_state.publish_generation =
      static_cast<std::uint32_t>(invalid_state.pickup_generation + 1U);
  R19HwcdcFifoDiagnosticRecord invalid_terminal_state{};
  report.check(invalid_terminal_state.initialize(state_a) &&
                   invalid_terminal_state.record_flush_attempt(state_a) &&
                   !invalid_terminal_state.record_flush_timeout(invalid_state) &&
                   invalid_terminal_state.try_snapshot(snapshot) &&
                   !snapshot.valid_header(),
               "invalid terminal state left the prior lifecycle record valid");
}

void test_rejects_partial_write_snapshot(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  report.check(record.initialize(state_a),
               "partial-write fixture initialization failed");
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  report.check(record.try_snapshot(snapshot) &&
                   snapshot_has_state(snapshot, state_a),
               "partial-write fixture did not start from state A");
  const R19HwcdcFifoDiagnosticSnapshot sentinel = snapshot;

  R19HwcdcFifoDiagnosticRecordTestAccess::begin_partial_state_write(record,
                                                                     state_b_settled);
  report.check(
      R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(record) == 1U &&
          (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(record) & 1U) !=
              0U,
      "partial write did not publish active-writer and odd-sequence evidence");
  report.check(!record.try_snapshot(snapshot, 1U),
               "try_snapshot accepted a partially written state");
  report.check(snapshot.sequence == sentinel.sequence &&
                   snapshot.flags == sentinel.flags &&
                   snapshot.tx_loss_epoch == sentinel.tx_loss_epoch &&
                   snapshot.publish_generation ==
                       sentinel.publish_generation &&
                   snapshot.pickup_generation == sentinel.pickup_generation &&
                   snapshot.last_ring_pending_bytes ==
                       sentinel.last_ring_pending_bytes,
               "a rejected partial snapshot modified the caller output");

  R19HwcdcFifoDiagnosticRecordTestAccess::finish_partial_state_write(record,
                                                                      state_b_settled);
  report.check(
      R19HwcdcFifoDiagnosticRecordTestAccess::active_writer(record) == 0U &&
          (R19HwcdcFifoDiagnosticRecordTestAccess::sequence(record) & 1U) ==
              0U,
      "completed write did not restore a stable even sequence");
  report.check(record.try_snapshot(snapshot) &&
                    snapshot_has_state(snapshot, state_b_settled),
               "completed state B was not exposed consistently");
}

void test_uninitialized_events_are_rejected(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  bool uninitialized_zlp_flush_issued = false;
  report.check(!record.observe_state(state_a) &&
                   !record.record_fifo_write(1U, state_a) &&
                   !record.record_wr_done(state_a) &&
                   !record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task,
                       [&]() noexcept {
                         uninitialized_zlp_flush_issued = true;
                         return state_a;
                       }) &&
                   !record.record_in_empty(false, state_a) &&
                   !record.record_bus_reset(state_a) &&
                   !record.record_flush_attempt(state_a) &&
                   !record.record_flush_success(state_a) &&
                   !record.record_flush_timeout(state_a) &&
                   !record.record_flush_abort(state_a),
               "an event mutated an uninitialized diagnostic record");
  report.check(uninitialized_zlp_flush_issued,
               "uninitialized diagnostics suppressed the hardware ZLP");
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  report.check(record.try_snapshot(snapshot) && !snapshot.valid_header() &&
                   snapshot.sequence == 0U &&
                   snapshot.fifo_write_attempt_count == 0U &&
                   snapshot.in_empty_irq_count == 0U &&
                   snapshot.flush_attempt_count == 0U,
               "rejected uninitialized events changed the zero record");
}

void test_reset_clears_complete_record(TestReport& report) {
  R19HwcdcFifoDiagnosticRecord record{};
  report.check(record.initialize(state_a) &&
                   record.record_fifo_write(0U, state_a) &&
                   record.record_fifo_write(16U, state_a) &&
                   record.record_wr_done(state_a) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   record.record_in_empty(true, state_a) &&
                   record.record_bus_reset(state_a) &&
                   record.record_flush_attempt(state_a) &&
                   record.record_zlp_wr_done(
                       R19HwcdcFifoZlpOrigin::Task, state_a) &&
                   record.record_flush_success(state_a) &&
                   record.record_flush_attempt(state_a) &&
                   record.record_flush_timeout(state_a),
               "reset fixture setup failed");
  record.reset();
  R19HwcdcFifoDiagnosticSnapshot snapshot{};
  report.check(record.try_snapshot(snapshot) && !snapshot.valid_header() &&
                   snapshot.active_writer == 0U &&
                   (snapshot.sequence & 1U) == 0U &&
                   snapshot.magic == 0U && snapshot.schema == 0U &&
                   snapshot.flags == 0U && snapshot.tx_loss_epoch == 0U &&
                   snapshot.fifo_write_attempt_count == 0U &&
                   snapshot.fifo_write_bytes == 0U &&
                   snapshot.fifo_zero_write_count == 0U &&
                   snapshot.last_fifo_write_size == 0U &&
                   snapshot.wr_done_count == 0U &&
                   snapshot.in_empty_irq_count == 0U &&
                   snapshot.payload_in_empty_count == 0U &&
                   snapshot.publish_generation == 0U &&
                   snapshot.pickup_generation == 0U &&
                   snapshot.bus_reset_count == 0U &&
                   snapshot.flush_attempt_count == 0U &&
                   snapshot.flush_success_count == 0U &&
                   snapshot.flush_timeout_count == 0U &&
                   snapshot.zlp_flush_count == 0U &&
                   snapshot.last_ring_pending_bytes == 0U &&
                   snapshot.last_stash_pending_bytes == 0U &&
                   snapshot.last_interrupt_status == 0U &&
                   snapshot.last_flush_blocker_mask == 0U &&
                   snapshot.last_flush_outcome == static_cast<std::uint32_t>(
                       R19HwcdcFifoFlushOutcome::None) &&
                   snapshot.last_flush_task_zlp_count == 0U &&
                   snapshot.last_flush_isr_zlp_count == 0U &&
                   snapshot.last_flush_terminal_blocker_mask == 0U,
               "reset did not clear the complete diagnostic payload");
}

}  // namespace

int main() {
  static_assert(std::is_standard_layout_v<R19HwcdcFifoDiagnosticRecord>,
                "JTAG diagnostic record must keep a standard layout");
  static_assert(sizeof(R19HwcdcFifoDiagnosticRecord) == 112U,
                "JTAG diagnostic record schema 2 must be exactly 28 words");
  static_assert(
      R19HwcdcFifoDiagnosticRecord::storage_word_count == 28U,
      "JTAG diagnostic record word count changed");
  static_assert(vc_lora::experimental::r19_hwcdc_fifo_diagnostic_schema == 2U,
                "per-attempt diagnostic ABI requires schema 2");
  static_assert(
      vc_lora::experimental::r19_hwcdc_fifo_diagnostic_known_flag_mask ==
          0x00003FFFU,
      "diagnostic flag ABI changed");
  static_assert(
      vc_lora::experimental::r19_hwcdc_fifo_flush_known_blocker_mask ==
          0x000000FFU,
      "flush blocker ABI changed");
  static_assert(
      static_cast<std::uint32_t>(R19HwcdcFifoFlushOutcome::None) == 0U &&
          static_cast<std::uint32_t>(R19HwcdcFifoFlushOutcome::Active) == 1U &&
          static_cast<std::uint32_t>(R19HwcdcFifoFlushOutcome::Success) == 2U &&
          static_cast<std::uint32_t>(R19HwcdcFifoFlushOutcome::Timeout) == 3U &&
          static_cast<std::uint32_t>(R19HwcdcFifoFlushOutcome::Abort) == 4U,
      "flush outcome ABI changed");
  static_assert(flag(R19HwcdcFifoDiagnosticFlag::Initialized) == (1U << 0U) &&
                    flag(R19HwcdcFifoDiagnosticFlag::ObservationActive) ==
                        (1U << 1U) &&
                    flag(R19HwcdcFifoDiagnosticFlag::Connected) ==
                        (1U << 2U) &&
                    flag(R19HwcdcFifoDiagnosticFlag::FifoWritable) ==
                        (1U << 3U) &&
                    flag(R19HwcdcFifoDiagnosticFlag::PayloadInFlight) ==
                        (1U << 4U) &&
                    flag(R19HwcdcFifoDiagnosticFlag::FifoQuarantined) ==
                        (1U << 5U) &&
                    flag(R19HwcdcFifoDiagnosticFlag::ResetPending) ==
                        (1U << 6U) &&
                    flag(R19HwcdcFifoDiagnosticFlag::BootstrapFence) ==
                        (1U << 7U) &&
                    flag(R19HwcdcFifoDiagnosticFlag::BootstrapAborted) ==
                        (1U << 8U) &&
                    flag(R19HwcdcFifoDiagnosticFlag::DebugWriterActive) ==
                        (1U << 9U) &&
                    flag(R19HwcdcFifoDiagnosticFlag::FlushActive) ==
                         (1U << 10U) &&
                     flag(R19HwcdcFifoDiagnosticFlag::PayloadPublishPending) ==
                         (1U << 11U) &&
                     flag(R19HwcdcFifoDiagnosticFlag::PayloadPublishAborted) ==
                         (1U << 12U),
                "diagnostic flag bit assignments changed");
  static_assert(
      flag(R19HwcdcFifoDiagnosticFlag::PayloadFlushPending) == (1U << 13U),
      "payload flush witness bit assignment changed");
  static_assert(blocker(R19HwcdcFifoFlushBlocker::HostAbsent) ==
                            (1U << 0U) &&
                        blocker(R19HwcdcFifoFlushBlocker::EpochMismatch) ==
                            (1U << 1U) &&
                        blocker(R19HwcdcFifoFlushBlocker::SoftwarePending) ==
                            (1U << 2U) &&
                        blocker(R19HwcdcFifoFlushBlocker::FifoNotWritable) ==
                            (1U << 3U) &&
                        blocker(
                            R19HwcdcFifoFlushBlocker::PayloadPickupPending) ==
                            (1U << 4U) &&
                        blocker(R19HwcdcFifoFlushBlocker::Quarantined) ==
                            (1U << 5U) &&
                        blocker(R19HwcdcFifoFlushBlocker::ResetPending) ==
                            (1U << 6U) &&
                        blocker(R19HwcdcFifoFlushBlocker::Uninitialized) ==
                            (1U << 7U),
                "flush blocker bit assignments changed");

  TestReport report{};
  test_restart_record_first_blocked_and_latest_outcome(report);
  test_exact_abi_layout(report);
  test_initialize_and_observe_state(report);
  test_event_accounting(report);
  test_payload_causal_accounting_is_fail_closed(report);
  test_payload_publish_pending_closes_historical_success_gap(report);
  test_zlp_wr_done_origin_is_one_transaction(report);
  test_zlp_hardware_boundary_is_fail_closed(report);
  test_payload_wr_done_hardware_boundary_is_fail_closed(report);
  test_fifo_write_hardware_boundary_is_fail_closed(report);
  test_in_empty_hardware_boundary_is_fail_closed(report);
  test_bus_reset_hardware_boundary_is_fail_closed(report);
  test_flush_abort_accounting(report);
  test_timeout_latches_boundary_resample_atomically(report);
  test_per_attempt_flush_diagnostics(report);
  test_flush_retry_inherits_one_terminal_zlp(report);
  test_per_attempt_zlp_counters_saturate(report);
  test_reinitialize_clears_active_flush(report);
  test_saturating_counters(report);
  test_rejects_inconsistent_state(report);
  test_short_packet_flush_success_does_not_require_zlp(report);
  test_invalid_lifecycle_transition_poison(report);
  test_rejects_partial_write_snapshot(report);
  test_uninitialized_events_are_rejected(report);
  test_reset_clears_complete_record(report);

  if (report.failures != 0U) {
    std::cerr << "r19 HWCDC FIFO diagnostic record tests: " << report.failures
              << " failure(s), " << report.checks << " checks\n";
    return 1;
  }
  std::cout << "r19 HWCDC FIFO diagnostic record tests: PASS ("
            << report.checks << " checks)\n";
  return 0;
}
