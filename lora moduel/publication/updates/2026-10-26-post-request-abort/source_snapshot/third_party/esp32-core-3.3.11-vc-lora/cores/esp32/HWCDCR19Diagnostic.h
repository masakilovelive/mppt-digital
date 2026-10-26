#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <type_traits>

namespace vc_lora::experimental {

// Call-local diagnostic value, not a shared/JTAG record. The producer task
// freezes this value with its own product token only after wrapper predicates
// have been evaluated. Later ISR/diagnostic traffic cannot overwrite it.
enum class R19HwcdcFlushTerminalReason : std::uint32_t {
  NotInvoked = 0U,
  Success = 1U,
  NullRing = 2U,
  NullLock = 3U,
  LockTimeout = 4U,
  LoopTimeout = 5U,
  EpochAbort = 6U,
};
enum class R19HwcdcFlushEvidenceFlag : std::uint32_t {
  Initialized = 1U,
  ApiEntered = 2U,
  LockAcquired = 4U,
  SnapshotValid = 8U,
  Completed = 16U,
  HostPresent = 32U,
  IdentityProvided = 64U,
  // This is a coherent observer snapshot under hw_cdc_tx_mux, not proof that
  // the failed caller owned the other task's FIFO/ring publication.
  SnapshotWithoutTxLock = 128U,
};
struct R19HwcdcFlushCallEvidence final {
  std::uint32_t schema{1U};
  std::uint32_t validity_flags{0U};
  std::uint32_t transaction_token{0U};
  std::uint32_t attempt_id{0U};
  std::uint32_t terminal_reason{0U};
  std::uint32_t timeout_ms{0U};
  std::uint32_t expected_loss_epoch{0U};
  // SDK millis() modulo 2^32, NOT the caller's 64-bit esp_timer/PC clock.
  // All elapsed fields use unsigned subtraction across a single wrap.
  std::uint32_t started_ms{0U};
  std::uint32_t finished_ms{0U};
  std::uint32_t lock_wait_ms{0U};
  std::uint32_t elapsed_ms{0U};
  std::uint32_t raw_return{0U};
  std::uint32_t state_flags{0U};
  std::uint32_t observed_loss_epoch{0U};
  std::uint32_t ring_pending_bytes{0U};
  std::uint32_t stash_pending_bytes{0U};
  std::uint32_t publish_generation{0U};
  std::uint32_t pickup_generation{0U};
  std::uint32_t raw_interrupt_status{0U};
  std::uint32_t interrupt_enable_mask{0U};
  std::uint32_t flush_blocker_mask{0U};
  std::uint32_t snapshot_started_ms{0U};
  std::uint32_t snapshot_finished_ms{0U};
  std::uint32_t snapshot_duration_us{0U};
};
static_assert(sizeof(R19HwcdcFlushCallEvidence) == 96U);
static_assert(std::is_standard_layout_v<R19HwcdcFlushCallEvidence>);
static_assert(std::is_trivially_copyable_v<R19HwcdcFlushCallEvidence>);

inline constexpr std::uint32_t r19_hwcdc_fifo_diagnostic_magic =
    0x48313946U;
inline constexpr std::uint32_t r19_hwcdc_fifo_diagnostic_schema = 2U;

enum class R19HwcdcFifoDiagnosticFlag : std::uint32_t {
  Initialized = 1U << 0U,
  // The diagnostic observation window was enabled at this event sample. This
  // is not a continuously live indication between committed events.
  ObservationActive = 1U << 1U,
  Connected = 1U << 2U,
  FifoWritable = 1U << 3U,
  PayloadInFlight = 1U << 4U,
  FifoQuarantined = 1U << 5U,
  ResetPending = 1U << 6U,
  BootstrapFence = 1U << 7U,
  BootstrapAborted = 1U << 8U,
  DebugWriterActive = 1U << 9U,
  // Owned by this record rather than by the caller-supplied live state. It
  // distinguishes the one currently executing flush transaction from prior
  // attempts which terminated through record_flush_abort().
  FlushActive = 1U << 10U,
  // Owned by this record. A positive hardware FIFO write arms this witness;
  // its matching non-ZLP WR_DONE clears it only after the hardware flush
  // callback completes. This prevents a later publish from reusing an older
  // WR_DONE/flush-success snapshot as apparent completion.
  PayloadPublishPending = 1U << 11U,
  // Owned by this record. A task-side queue/stash discard sets this witness
  // while clearing PayloadPublishPending. It prevents that later discard from
  // erasing a BUS_RESET or reusing an older successful flush as completion of
  // the discarded publication. BUS_RESET also sets this persistent barrier;
  // only a new positive publication supersedes it.
  PayloadPublishAborted = 1U << 12U,
  // Owned by this record. A positive FIFO write arms this witness and only a
  // later clean flush success for a fully picked-up publication clears it.
  // WR_DONE, IN_EMPTY pickup, ZLP, and state observation preserve it so a new
  // publication cannot reuse an older flush-success counter.
  PayloadFlushPending = 1U << 13U,
};

[[nodiscard]] constexpr std::uint32_t r19_hwcdc_fifo_diagnostic_flag(
    R19HwcdcFifoDiagnosticFlag flag) noexcept {
  return static_cast<std::uint32_t>(flag);
}

inline constexpr std::uint32_t
    r19_hwcdc_fifo_diagnostic_known_flag_mask = 0x00003FFFU;

enum class R19HwcdcFifoFlushBlocker : std::uint32_t {
  HostAbsent = 1U << 0U,
  EpochMismatch = 1U << 1U,
  SoftwarePending = 1U << 2U,
  FifoNotWritable = 1U << 3U,
  PayloadPickupPending = 1U << 4U,
  Quarantined = 1U << 5U,
  ResetPending = 1U << 6U,
  Uninitialized = 1U << 7U,
};

[[nodiscard]] constexpr std::uint32_t r19_hwcdc_fifo_flush_blocker(
    R19HwcdcFifoFlushBlocker blocker) noexcept {
  return static_cast<std::uint32_t>(blocker);
}

inline constexpr std::uint32_t r19_hwcdc_fifo_flush_known_blocker_mask =
    0x000000FFU;

enum class R19HwcdcFifoFlushOutcome : std::uint32_t {
  None = 0U,
  Active = 1U,
  Success = 2U,
  Timeout = 3U,
  Abort = 4U,
};

// The origin is event metadata only; it does not consume a stored ABI word.
enum class R19HwcdcFifoZlpOrigin : std::uint32_t {
  Task = 0U,
  Isr = 1U,
};

// One post-action observation associated with the last completed diagnostic
// event. Event methods commit all eight words together with their counter
// update; these fields intentionally describe that event, not continuously
// live state between events.
struct R19HwcdcFifoDiagnosticState final {
  std::uint32_t flags{0U};
  std::uint32_t tx_loss_epoch{0U};
  std::uint32_t publish_generation{0U};
  std::uint32_t pickup_generation{0U};
  std::uint32_t ring_pending_bytes{0U};
  std::uint32_t stash_pending_bytes{0U};
  std::uint32_t interrupt_status{0U};
  std::uint32_t flush_blocker_mask{0U};
};

// Callback results are transient event metadata. They do not add words to the
// fixed JTAG ABI; they let the record own the exact hardware-side-effect
// boundary and its matching post-action state.
struct R19HwcdcFifoWriteResult final {
  std::uint32_t written_bytes{0U};
  R19HwcdcFifoDiagnosticState state{};
};

struct R19HwcdcFifoBusResetResult final {
  bool raw_in_empty_pending{false};
  // Preserve the pre-clear interrupt source while the state below describes
  // the completed reset action. This metadata shares an existing ABI word;
  // the transient callback result itself is never exposed to JTAG.
  std::uint32_t source_interrupt_status{0U};
  R19HwcdcFifoDiagnosticState state{};
};

// Stable host-side view of all 28 ABI words. A successful try_snapshot always
// reports active_writer == 0 and an even sequence.
struct R19HwcdcFifoDiagnosticSnapshot final {
  std::uint32_t active_writer{0U};
  std::uint32_t sequence{0U};
  std::uint32_t magic{0U};
  std::uint32_t schema{0U};
  std::uint32_t flags{0U};
  std::uint32_t tx_loss_epoch{0U};
  std::uint32_t fifo_write_attempt_count{0U};
  std::uint32_t fifo_write_bytes{0U};
  std::uint32_t fifo_zero_write_count{0U};
  std::uint32_t last_fifo_write_size{0U};
  std::uint32_t wr_done_count{0U};
  std::uint32_t in_empty_irq_count{0U};
  std::uint32_t payload_in_empty_count{0U};
  std::uint32_t publish_generation{0U};
  std::uint32_t pickup_generation{0U};
  std::uint32_t bus_reset_count{0U};
  std::uint32_t flush_attempt_count{0U};
  std::uint32_t flush_success_count{0U};
  std::uint32_t flush_timeout_count{0U};
  std::uint32_t zlp_flush_count{0U};
  std::uint32_t last_ring_pending_bytes{0U};
  std::uint32_t last_stash_pending_bytes{0U};
  std::uint32_t last_interrupt_status{0U};
  std::uint32_t last_flush_blocker_mask{0U};
  // Schema 2 append-only fields. The first 24 words above retain their schema
  // 1 offsets so older evidence remains mechanically comparable.
  std::uint32_t last_flush_outcome{0U};
  std::uint32_t last_flush_task_zlp_count{0U};
  std::uint32_t last_flush_isr_zlp_count{0U};
  std::uint32_t last_flush_terminal_blocker_mask{0U};

  [[nodiscard]] constexpr bool valid_header() const noexcept {
    return magic == r19_hwcdc_fifo_diagnostic_magic &&
           schema == r19_hwcdc_fifo_diagnostic_schema;
  }
};

struct R19HwcdcFifoDiagnosticRecordTestAccess;

// Fixed 112-byte, JTAG-only evidence record for the USB Serial/JTAG TX FIFO.
// ESP32-S3 Arduino builds use -mdisable-hardware-atomics, so this type uses
// aligned volatile 32-bit words and compiler fences rather than std::atomic.
// The caller must serialize every mutator (HWCDC uses its existing TX mux),
// including ISR callers; this class never allocates, locks, spins, or waits.
// Readers reject active_writer != 0 or an odd/changing sequence.
class alignas(std::uint32_t) R19HwcdcFifoDiagnosticRecord final {
 public:
  static constexpr std::size_t storage_word_count = 28U;
  static constexpr std::uint32_t default_snapshot_attempts = 8U;
  static constexpr std::uint32_t maximum_fifo_write_size = 32U;

  R19HwcdcFifoDiagnosticRecord() noexcept = default;
  R19HwcdcFifoDiagnosticRecord(const R19HwcdcFifoDiagnosticRecord&) = delete;
  R19HwcdcFifoDiagnosticRecord& operator=(
      const R19HwcdcFifoDiagnosticRecord&) = delete;
  R19HwcdcFifoDiagnosticRecord(R19HwcdcFifoDiagnosticRecord&&) = delete;
  R19HwcdcFifoDiagnosticRecord& operator=(
      R19HwcdcFifoDiagnosticRecord&&) = delete;

  [[nodiscard]] bool initialize(
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    if (!valid_state(state)) {
      return false;
    }

    begin_write();
    magic_ = r19_hwcdc_fifo_diagnostic_magic;
    schema_ = r19_hwcdc_fifo_diagnostic_schema;
    fifo_write_attempt_count_ = 0U;
    fifo_write_bytes_ = 0U;
    fifo_zero_write_count_ = 0U;
    last_fifo_write_size_ = 0U;
    wr_done_count_ = 0U;
    in_empty_irq_count_ = 0U;
    payload_in_empty_count_ = 0U;
    bus_reset_count_ = 0U;
    flush_attempt_count_ = 0U;
    flush_success_count_ = 0U;
    flush_timeout_count_ = 0U;
    zlp_flush_count_ = 0U;
    last_flush_outcome_ = static_cast<std::uint32_t>(
        R19HwcdcFifoFlushOutcome::None);
    last_flush_task_zlp_count_ = 0U;
    last_flush_isr_zlp_count_ = 0U;
    last_flush_terminal_blocker_mask_ = 0U;
    write_state(state, false);
    const bool state_valid = accounting_invariants_hold();
    if (!state_valid) {
      poison_current_write();
    }
    commit_write();
    return state_valid;
  }

  void reset() noexcept {
    begin_write();
    magic_ = 0U;
    schema_ = 0U;
    flags_ = 0U;
    tx_loss_epoch_ = 0U;
    fifo_write_attempt_count_ = 0U;
    fifo_write_bytes_ = 0U;
    fifo_zero_write_count_ = 0U;
    last_fifo_write_size_ = 0U;
    wr_done_count_ = 0U;
    in_empty_irq_count_ = 0U;
    payload_in_empty_count_ = 0U;
    publish_generation_ = 0U;
    pickup_generation_ = 0U;
    bus_reset_count_ = 0U;
    flush_attempt_count_ = 0U;
    flush_success_count_ = 0U;
    flush_timeout_count_ = 0U;
    zlp_flush_count_ = 0U;
    last_ring_pending_bytes_ = 0U;
    last_stash_pending_bytes_ = 0U;
    last_interrupt_status_ = 0U;
    last_flush_blocker_mask_ = 0U;
    last_flush_outcome_ = static_cast<std::uint32_t>(
        R19HwcdcFifoFlushOutcome::None);
    last_flush_task_zlp_count_ = 0U;
    last_flush_isr_zlp_count_ = 0U;
    last_flush_terminal_blocker_mask_ = 0U;
    commit_write();
  }

  [[nodiscard]] bool observe_state(
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    if (!can_record(state)) {
      return false;
    }
    begin_write();
    write_state(state);
    const bool state_valid = accounting_invariants_hold();
    if (!state_valid) {
      poison_current_write();
    }
    commit_write();
    return state_valid;
  }

  template <typename WriteAndSample>
  [[nodiscard]] bool record_fifo_write(
      WriteAndSample write_and_sample) noexcept {
    const bool publish_record = initialized_for_writer();
    if (publish_record) {
      begin_write();
    }
    const bool had_payload_publish_pending =
        publish_record && payload_publish_pending();
    const R19HwcdcFifoWriteResult result = write_and_sample();
    if (!publish_record) {
      return false;
    }
    bool result_valid =
        result.written_bytes <= maximum_fifo_write_size &&
        valid_state(result.state) && !had_payload_publish_pending;
    if (!result_valid) {
      // The hardware write already happened, so stale pre-write state must
      // never be exposed behind a valid header.
      magic_ = 0U;
      schema_ = 0U;
      flags_ = 0U;
    } else {
      saturating_increment(fifo_write_attempt_count_);
      saturating_add(fifo_write_bytes_, result.written_bytes);
      if (result.written_bytes == 0U) {
        saturating_increment(fifo_zero_write_count_);
      }
      last_fifo_write_size_ = result.written_bytes;
      if (result.written_bytes > 0U) {
        clear_payload_publish_aborted();
        set_payload_publish_pending();
        set_payload_flush_pending();
      }
      write_state(result.state);
      if (!accounting_invariants_hold()) {
        result_valid = false;
        poison_current_write();
      }
    }
    commit_write();
    return result_valid;
  }

  [[nodiscard]] bool record_fifo_write(
      std::uint32_t written_bytes,
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    return record_fifo_write([written_bytes, &state]() noexcept {
      return R19HwcdcFifoWriteResult{written_bytes, state};
    });
  }

  template <typename FlushAndSample>
  [[nodiscard]] bool record_wr_done(
      FlushAndSample flush_and_sample) noexcept {
    const bool publish_record = initialized_for_writer();
    if (publish_record) {
      begin_write();
    }
    const bool had_payload_publish_pending =
        publish_record && payload_publish_pending();
    const R19HwcdcFifoDiagnosticState state = flush_and_sample();
    if (!publish_record) {
      return false;
    }
    bool state_valid = valid_state(state);
    if (!had_payload_publish_pending) {
      state_valid = false;
    }
    saturating_increment(wr_done_count_);
    if (had_payload_publish_pending) {
      clear_payload_publish_pending();
    }
    if (state_valid) {
      write_state(state);
      state_valid = accounting_invariants_hold();
    }
    if (!state_valid) {
      magic_ = 0U;
      schema_ = 0U;
      flags_ = 0U;
    }
    commit_write();
    return state_valid;
  }

  [[nodiscard]] bool record_wr_done(
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    return record_wr_done([&state]() noexcept { return state; });
  }

  // A ZLP hardware flush, WR_DONE, and its origin are one logical event. The
  // record is made odd before flush_and_sample() issues the hardware write and
  // stays odd until all counters and the post-write state are committed. A
  // JTAG halt immediately on either side of the hardware call therefore
  // fails closed instead of accepting a stable one-event undercount.
  template <typename FlushAndSample>
  [[nodiscard]] bool record_zlp_wr_done(
      R19HwcdcFifoZlpOrigin origin,
      FlushAndSample flush_and_sample) noexcept {
    if ((origin != R19HwcdcFifoZlpOrigin::Task &&
         origin != R19HwcdcFifoZlpOrigin::Isr)) {
      return false;
    }
    const bool publish_record = initialized_for_writer();
    if (publish_record) {
      begin_write();
    }
    const R19HwcdcFifoDiagnosticState state = flush_and_sample();
    if (!publish_record) {
      return false;
    }
    bool state_valid = valid_state(state);
    saturating_increment(wr_done_count_);
    saturating_increment(zlp_flush_count_);
    if (flush_active()) {
      if (origin == R19HwcdcFifoZlpOrigin::Task) {
        saturating_increment(last_flush_task_zlp_count_);
      } else {
        saturating_increment(last_flush_isr_zlp_count_);
      }
    }
    if (state_valid) {
      write_state(state);
      state_valid = accounting_invariants_hold();
    }
    if (!state_valid) {
      // The hardware action already happened. Do not republish a valid
      // header paired with stale pre-action state; invalidate the record so
      // every reader fails closed until an explicit reinitialization.
      magic_ = 0U;
      schema_ = 0U;
      flags_ = 0U;
    }
    commit_write();
    return state_valid;
  }

  // Record-only adapter retained for host accounting tests. Production ZLP
  // sites use the callable overload so the real hardware side effect is
  // enclosed by the same transaction.
  [[nodiscard]] bool record_zlp_wr_done(
      R19HwcdcFifoZlpOrigin origin,
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    return record_zlp_wr_done(origin, [&state]() noexcept { return state; });
  }

  template <typename ProcessAndSample>
  [[nodiscard]] bool record_in_empty(
      bool payload_pickup,
      ProcessAndSample process_and_sample) noexcept {
    const bool publish_record = initialized_for_writer();
    if (publish_record) {
      begin_write();
    }
    const R19HwcdcFifoDiagnosticState state = process_and_sample();
    if (!publish_record) {
      return false;
    }
    bool state_valid = valid_state(state) &&
                       !(payload_pickup && payload_publish_pending());
    saturating_increment(in_empty_irq_count_);
    if (payload_pickup) {
      saturating_increment(payload_in_empty_count_);
    }
    if (state_valid) {
      write_state(state);
      state_valid = accounting_invariants_hold();
    }
    if (!state_valid) {
      magic_ = 0U;
      schema_ = 0U;
      flags_ = 0U;
    }
    commit_write();
    return state_valid;
  }

  [[nodiscard]] bool record_in_empty(
      bool payload_pickup,
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    return record_in_empty(
        payload_pickup, [&state]() noexcept { return state; });
  }

  template <typename ResetAndSample>
  [[nodiscard]] bool record_bus_reset(
      ResetAndSample reset_and_sample) noexcept {
    const bool publish_record = initialized_for_writer();
    if (publish_record) {
      begin_write();
    }
    const R19HwcdcFifoBusResetResult result = reset_and_sample();
    if (!publish_record) {
      return false;
    }
    bool result_valid = valid_state(result.state);
    saturating_increment(bus_reset_count_);
    if (result.raw_in_empty_pending) {
      saturating_increment(in_empty_irq_count_);
    }
    if (!result_valid) {
      magic_ = 0U;
      schema_ = 0U;
      flags_ = 0U;
    } else {
      write_state(result.state);
      clear_payload_publish_pending();
      clear_payload_flush_pending();
      set_payload_publish_aborted();
      // BUS_RESET is the one event whose causal interrupt sample and
      // post-action state intentionally refer to opposite sides of the
      // hardware status clear. Keep flags/blockers post-action, but retain
      // the exact pre-clear source in the existing status word.
      last_interrupt_status_ = result.source_interrupt_status;
      if (!accounting_invariants_hold()) {
        result_valid = false;
        poison_current_write();
      }
    }
    commit_write();
    return result_valid;
  }

  [[nodiscard]] bool record_bus_reset(
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    return record_bus_reset([&state]() noexcept {
      return R19HwcdcFifoBusResetResult{
          false, state.interrupt_status, state};
    });
  }

  // Task-side queue/stash discard and epoch rollback abort any positive FIFO
  // publication which did not reach non-ZLP WR_DONE. Preserve the historical
  // attempt counters, but clear the record-owned pending witness atomically
  // with the post-discard state so later observations cannot remain stuck.
  template <typename AbortAndSample>
  [[nodiscard]] bool record_payload_publish_abort(
      AbortAndSample abort_and_sample) noexcept {
    const bool publish_record = initialized_for_writer();
    if (publish_record) {
      begin_write();
    }
    // The production discard must run exactly once even when the diagnostic
    // record was never initialized. When initialized, keeping the seqlock odd
    // across this callback makes the queue/stash/epoch mutation and its abort
    // witness one indivisible event to a halted JTAG reader.
    const R19HwcdcFifoDiagnosticState state = abort_and_sample();
    if (!publish_record) {
      return false;
    }
    bool state_valid = valid_state(state);
    if (state_valid) {
      write_state(state);
      clear_payload_publish_pending();
      clear_payload_flush_pending();
      set_payload_publish_aborted();
      state_valid = accounting_invariants_hold();
    }
    if (!state_valid) {
      poison_current_write();
    }
    commit_write();
    return state_valid;
  }

  [[nodiscard]] bool record_payload_publish_abort(
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    return record_payload_publish_abort(
        [&state]() noexcept { return state; });
  }

  [[nodiscard]] bool record_flush_attempt(
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    if (!initialized_for_writer()) {
      return false;
    }
    if (!valid_state(state) || flush_active()) {
      return poison_lifecycle_transition();
    }
    begin_write();
    saturating_increment(flush_attempt_count_);
    write_state(state);
    flags_ = static_cast<std::uint32_t>(
        flags_ | r19_hwcdc_fifo_diagnostic_flag(
                     R19HwcdcFifoDiagnosticFlag::FlushActive));
    last_flush_outcome_ = static_cast<std::uint32_t>(
        R19HwcdcFifoFlushOutcome::Active);
    last_flush_task_zlp_count_ = 0U;
    last_flush_isr_zlp_count_ = 0U;
    last_flush_terminal_blocker_mask_ = 0U;
    const bool state_valid = accounting_invariants_hold();
    if (!state_valid) {
      poison_current_write();
    }
    commit_write();
    return state_valid;
  }

  // Continue the same bounded flush transaction after a timeout without
  // losing ownership of its already-issued task-side terminal ZLP.  This is
  // intentionally stricter than record_flush_attempt(): only the exact
  // epoch/publication/pickup boundary which timed out may inherit the one ZLP
  // witness.  Any lifecycle or identity mismatch poisons the record so a
  // later JTAG reader cannot accept mixed evidence from two transactions.
  [[nodiscard]] bool record_flush_retry_attempt(
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    if (!initialized_for_writer()) {
      return false;
    }
    const bool identity_matches =
        state.tx_loss_epoch == tx_loss_epoch_ &&
        state.publish_generation == publish_generation_ &&
        state.pickup_generation == pickup_generation_;
    if (!valid_state(state) || flush_active() ||
        last_flush_outcome_ != static_cast<std::uint32_t>(
                                   R19HwcdcFifoFlushOutcome::Timeout) ||
        last_flush_task_zlp_count_ != 1U ||
        last_flush_isr_zlp_count_ != 0U || !identity_matches) {
      return poison_lifecycle_transition();
    }
    begin_write();
    saturating_increment(flush_attempt_count_);
    write_state(state);
    flags_ = static_cast<std::uint32_t>(
        flags_ | r19_hwcdc_fifo_diagnostic_flag(
                     R19HwcdcFifoDiagnosticFlag::FlushActive));
    last_flush_outcome_ = static_cast<std::uint32_t>(
        R19HwcdcFifoFlushOutcome::Active);
    // Preserve last_flush_task_zlp_count_ == 1 and the record-owned payload
    // lifecycle flags.  Only the terminal blocker belongs to the old bounded
    // attempt and must be recomputed by the retry.
    last_flush_terminal_blocker_mask_ = 0U;
    const bool state_valid = accounting_invariants_hold();
    if (!state_valid) {
      poison_current_write();
    }
    commit_write();
    return state_valid;
  }

  // A short USB packet already terminates its transfer and therefore must
  // complete with no terminal ZLP.  Keep the explicit policy argument so a
  // future endpoint-sized publication cannot silently reuse that proof.  The
  // one-argument overload below retains the historical strict contract for
  // existing callers and stored-evidence tests.
  [[nodiscard]] bool record_flush_success(
      const R19HwcdcFifoDiagnosticState& state,
      bool terminal_zlp_required) noexcept {
    if (!initialized_for_writer()) {
      return false;
    }
    const bool had_payload_flush_pending = payload_flush_pending();
    const bool state_has_payload_in_flight =
        (state.flags & r19_hwcdc_fifo_diagnostic_flag(
                           R19HwcdcFifoDiagnosticFlag::PayloadInFlight)) != 0U;
    const bool terminal_evidence_valid = terminal_zlp_required
        ? last_flush_task_zlp_count_ == 1U &&
              last_flush_isr_zlp_count_ == 0U
        : last_flush_task_zlp_count_ == 0U &&
              last_flush_isr_zlp_count_ == 0U;
    if (!valid_state(state) || !flush_active() ||
        !terminal_evidence_valid ||
        state.flush_blocker_mask != 0U ||
        (had_payload_flush_pending &&
         (payload_publish_pending() || state_has_payload_in_flight ||
          state.publish_generation != state.pickup_generation))) {
      return poison_lifecycle_transition();
    }
    begin_write();
    saturating_increment(flush_success_count_);
    write_state(state);
    last_flush_outcome_ = static_cast<std::uint32_t>(
        R19HwcdcFifoFlushOutcome::Success);
    last_flush_terminal_blocker_mask_ = state.flush_blocker_mask;
    clear_flush_active();
    if (had_payload_flush_pending) {
      clear_payload_flush_pending();
    }
    const bool final_state_valid = accounting_invariants_hold();
    if (!final_state_valid) {
      poison_current_write();
    }
    commit_write();
    return final_state_valid;
  }

  [[nodiscard]] bool record_flush_success(
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    return record_flush_success(state, true);
  }

  [[nodiscard]] bool record_flush_timeout(
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    if (!initialized_for_writer()) {
      return false;
    }
    if (!valid_state(state) || !flush_active()) {
      return poison_lifecycle_transition();
    }
    begin_write();
    saturating_increment(flush_timeout_count_);
    write_state(state);
    last_flush_outcome_ = static_cast<std::uint32_t>(
        R19HwcdcFifoFlushOutcome::Timeout);
    last_flush_terminal_blocker_mask_ = state.flush_blocker_mask;
    clear_flush_active();
    const bool final_state_valid = accounting_invariants_hold();
    if (!final_state_valid) {
      poison_current_write();
    }
    commit_write();
    return final_state_valid;
  }

  // Closes a non-timeout failure (for example a loss-epoch mismatch) without
  // consuming either terminal counter. With no concurrent flush permitted,
  // historical aborts remain inferable as:
  //   attempts - successes - timeouts - (FlushActive ? 1 : 0)
  [[nodiscard]] bool record_flush_abort(
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    if (!initialized_for_writer()) {
      return false;
    }
    if (!valid_state(state) || !flush_active() ||
        (state.flush_blocker_mask &
         r19_hwcdc_fifo_flush_blocker(
             R19HwcdcFifoFlushBlocker::EpochMismatch)) == 0U) {
      return poison_lifecycle_transition();
    }
    begin_write();
    write_state(state);
    last_flush_outcome_ = static_cast<std::uint32_t>(
        R19HwcdcFifoFlushOutcome::Abort);
    last_flush_terminal_blocker_mask_ = state.flush_blocker_mask;
    clear_flush_active();
    const bool final_state_valid = accounting_invariants_hold();
    if (!final_state_valid) {
      poison_current_write();
    }
    commit_write();
    return final_state_valid;
  }

  // Returns false instead of waiting if a writer is active. The caller's
  // output changes only after two matching even sequence reads.
  [[nodiscard]] bool try_snapshot(
      R19HwcdcFifoDiagnosticSnapshot& output,
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

      R19HwcdcFifoDiagnosticSnapshot candidate{};
      candidate.active_writer = 0U;
      candidate.magic = magic_;
      candidate.schema = schema_;
      candidate.flags = flags_;
      candidate.tx_loss_epoch = tx_loss_epoch_;
      candidate.fifo_write_attempt_count = fifo_write_attempt_count_;
      candidate.fifo_write_bytes = fifo_write_bytes_;
      candidate.fifo_zero_write_count = fifo_zero_write_count_;
      candidate.last_fifo_write_size = last_fifo_write_size_;
      candidate.wr_done_count = wr_done_count_;
      candidate.in_empty_irq_count = in_empty_irq_count_;
      candidate.payload_in_empty_count = payload_in_empty_count_;
      candidate.publish_generation = publish_generation_;
      candidate.pickup_generation = pickup_generation_;
      candidate.bus_reset_count = bus_reset_count_;
      candidate.flush_attempt_count = flush_attempt_count_;
      candidate.flush_success_count = flush_success_count_;
      candidate.flush_timeout_count = flush_timeout_count_;
      candidate.zlp_flush_count = zlp_flush_count_;
      candidate.last_ring_pending_bytes = last_ring_pending_bytes_;
      candidate.last_stash_pending_bytes = last_stash_pending_bytes_;
      candidate.last_interrupt_status = last_interrupt_status_;
      candidate.last_flush_blocker_mask = last_flush_blocker_mask_;
      candidate.last_flush_outcome = last_flush_outcome_;
      candidate.last_flush_task_zlp_count = last_flush_task_zlp_count_;
      candidate.last_flush_isr_zlp_count = last_flush_isr_zlp_count_;
      candidate.last_flush_terminal_blocker_mask =
          last_flush_terminal_blocker_mask_;

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
  friend struct R19HwcdcFifoDiagnosticRecordTestAccess;

  [[nodiscard]] static constexpr bool valid_state(
      const R19HwcdcFifoDiagnosticState& state) noexcept {
    if ((state.flags & ~r19_hwcdc_fifo_diagnostic_known_flag_mask) != 0U ||
        (state.flush_blocker_mask &
         ~r19_hwcdc_fifo_flush_known_blocker_mask) != 0U) {
      return false;
    }
    const bool payload_in_flight =
        (state.flags & r19_hwcdc_fifo_diagnostic_flag(
                           R19HwcdcFifoDiagnosticFlag::PayloadInFlight)) !=
        0U;
    const std::uint32_t expected_publish_generation =
        payload_in_flight
            ? static_cast<std::uint32_t>(state.pickup_generation + 1U)
            : state.pickup_generation;
    return state.publish_generation == expected_publish_generation;
  }

  [[nodiscard]] bool initialized_for_writer() const noexcept {
    return magic_ == r19_hwcdc_fifo_diagnostic_magic &&
           schema_ == r19_hwcdc_fifo_diagnostic_schema &&
           (flags_ & r19_hwcdc_fifo_diagnostic_flag(
                         R19HwcdcFifoDiagnosticFlag::Initialized)) != 0U;
  }

  // Every payload pickup must be caused by a completed non-ZLP FIFO write,
  // and every completed non-ZLP write must be caused by a positive FIFO
  // write attempt. Check subtraction preconditions first so corrupted or
  // saturated evidence cannot wrap into an apparently valid ordering.
  [[nodiscard]] bool accounting_invariants_hold() const noexcept {
    const std::uint32_t fifo_write_attempts = fifo_write_attempt_count_;
    const std::uint32_t fifo_zero_writes = fifo_zero_write_count_;
    const std::uint32_t wr_done = wr_done_count_;
    const std::uint32_t zlp_flushes = zlp_flush_count_;
    if (wr_done < zlp_flushes ||
        fifo_write_attempts < fifo_zero_writes) {
      return false;
    }
    const std::uint32_t non_zlp_wr_done = wr_done - zlp_flushes;
    const std::uint32_t positive_fifo_writes =
        fifo_write_attempts - fifo_zero_writes;
    const bool payload_in_flight =
        (flags_ & r19_hwcdc_fifo_diagnostic_flag(
                      R19HwcdcFifoDiagnosticFlag::PayloadInFlight)) != 0U;
    if ((payload_publish_pending() &&
         positive_fifo_writes <= non_zlp_wr_done) ||
        (payload_publish_pending() && !payload_flush_pending()) ||
        (payload_in_flight && !payload_flush_pending()) ||
        (payload_flush_pending() && positive_fifo_writes == 0U) ||
        (payload_publish_aborted() &&
         (payload_publish_pending() || payload_flush_pending()))) {
      return false;
    }
    return payload_in_empty_count_ <= non_zlp_wr_done &&
           non_zlp_wr_done <= positive_fifo_writes;
  }

  [[nodiscard]] bool can_record(
      const R19HwcdcFifoDiagnosticState& state) const noexcept {
    return initialized_for_writer() && valid_state(state);
  }

  [[nodiscard]] bool flush_active() const noexcept {
    return (flags_ & r19_hwcdc_fifo_diagnostic_flag(
                         R19HwcdcFifoDiagnosticFlag::FlushActive)) != 0U;
  }

  [[nodiscard]] bool payload_publish_pending() const noexcept {
    return (flags_ & r19_hwcdc_fifo_diagnostic_flag(
                         R19HwcdcFifoDiagnosticFlag::
                             PayloadPublishPending)) != 0U;
  }

  [[nodiscard]] bool poison_lifecycle_transition() noexcept {
    begin_write();
    magic_ = 0U;
    schema_ = 0U;
    flags_ = 0U;
    commit_write();
    return false;
  }

  void poison_current_write() noexcept {
    magic_ = 0U;
    schema_ = 0U;
    flags_ = 0U;
  }

  void write_state(const R19HwcdcFifoDiagnosticState& state,
                   bool preserve_flush_active = true) noexcept {
    const std::uint32_t flush_active_mask =
        r19_hwcdc_fifo_diagnostic_flag(
            R19HwcdcFifoDiagnosticFlag::FlushActive);
    const std::uint32_t payload_publish_pending_mask =
        r19_hwcdc_fifo_diagnostic_flag(
            R19HwcdcFifoDiagnosticFlag::PayloadPublishPending);
    const std::uint32_t payload_publish_aborted_mask =
        r19_hwcdc_fifo_diagnostic_flag(
            R19HwcdcFifoDiagnosticFlag::PayloadPublishAborted);
    const std::uint32_t payload_flush_pending_mask =
        r19_hwcdc_fifo_diagnostic_flag(
            R19HwcdcFifoDiagnosticFlag::PayloadFlushPending);
    const std::uint32_t record_owned_mask = static_cast<std::uint32_t>(
        flush_active_mask | payload_publish_pending_mask |
        payload_publish_aborted_mask | payload_flush_pending_mask);
    const std::uint32_t internal_flags =
        (preserve_flush_active && flush_active() ? flush_active_mask : 0U) |
        (preserve_flush_active && payload_publish_pending()
             ? payload_publish_pending_mask
             : 0U) |
        (preserve_flush_active && payload_publish_aborted()
             ? payload_publish_aborted_mask
             : 0U) |
        (preserve_flush_active && payload_flush_pending()
             ? payload_flush_pending_mask
             : 0U);
    // All lifecycle flags are record-owned. Ignore them if a caller
    // accidentally supplies one, otherwise observe_state() could forge or
    // erase an incomplete or explicitly discarded hardware publication.
    flags_ = static_cast<std::uint32_t>(
        (state.flags & ~record_owned_mask) | internal_flags |
        r19_hwcdc_fifo_diagnostic_flag(
            R19HwcdcFifoDiagnosticFlag::Initialized));
    tx_loss_epoch_ = state.tx_loss_epoch;
    publish_generation_ = state.publish_generation;
    pickup_generation_ = state.pickup_generation;
    last_ring_pending_bytes_ = state.ring_pending_bytes;
    last_stash_pending_bytes_ = state.stash_pending_bytes;
    last_interrupt_status_ = state.interrupt_status;
    last_flush_blocker_mask_ = state.flush_blocker_mask;
  }

  void clear_flush_active() noexcept {
    flags_ = static_cast<std::uint32_t>(
        flags_ & ~r19_hwcdc_fifo_diagnostic_flag(
                     R19HwcdcFifoDiagnosticFlag::FlushActive));
  }

  void set_payload_publish_pending() noexcept {
    flags_ = static_cast<std::uint32_t>(
        flags_ | r19_hwcdc_fifo_diagnostic_flag(
                     R19HwcdcFifoDiagnosticFlag::PayloadPublishPending));
  }

  void clear_payload_publish_pending() noexcept {
    flags_ = static_cast<std::uint32_t>(
        flags_ & ~r19_hwcdc_fifo_diagnostic_flag(
                      R19HwcdcFifoDiagnosticFlag::PayloadPublishPending));
  }

  [[nodiscard]] bool payload_publish_aborted() const noexcept {
    return (flags_ & r19_hwcdc_fifo_diagnostic_flag(
                         R19HwcdcFifoDiagnosticFlag::
                             PayloadPublishAborted)) != 0U;
  }

  void set_payload_publish_aborted() noexcept {
    flags_ = static_cast<std::uint32_t>(
        flags_ | r19_hwcdc_fifo_diagnostic_flag(
                     R19HwcdcFifoDiagnosticFlag::PayloadPublishAborted));
  }

  void clear_payload_publish_aborted() noexcept {
    flags_ = static_cast<std::uint32_t>(
        flags_ & ~r19_hwcdc_fifo_diagnostic_flag(
                      R19HwcdcFifoDiagnosticFlag::PayloadPublishAborted));
  }

  [[nodiscard]] bool payload_flush_pending() const noexcept {
    return (flags_ & r19_hwcdc_fifo_diagnostic_flag(
                         R19HwcdcFifoDiagnosticFlag::PayloadFlushPending)) !=
           0U;
  }

  void set_payload_flush_pending() noexcept {
    flags_ = static_cast<std::uint32_t>(
        flags_ | r19_hwcdc_fifo_diagnostic_flag(
                     R19HwcdcFifoDiagnosticFlag::PayloadFlushPending));
  }

  void clear_payload_flush_pending() noexcept {
    flags_ = static_cast<std::uint32_t>(
        flags_ & ~r19_hwcdc_fifo_diagnostic_flag(
                      R19HwcdcFifoDiagnosticFlag::PayloadFlushPending));
  }

  static void saturating_increment(volatile std::uint32_t& target) noexcept {
    const std::uint32_t current = target;
    if (current != std::numeric_limits<std::uint32_t>::max()) {
      target = static_cast<std::uint32_t>(current + 1U);
    }
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
    sequence_ = static_cast<std::uint32_t>((stable_sequence & ~1U) + 1U);
    compiler_fence();
  }

  void commit_write() noexcept {
    compiler_fence();
    const std::uint32_t active_sequence = sequence_;
    sequence_ = static_cast<std::uint32_t>((active_sequence | 1U) + 1U);
    compiler_fence();
    active_writer_ = 0U;
  }

  volatile std::uint32_t active_writer_{0U};
  volatile std::uint32_t sequence_{0U};
  volatile std::uint32_t magic_{0U};
  volatile std::uint32_t schema_{0U};
  volatile std::uint32_t flags_{0U};
  volatile std::uint32_t tx_loss_epoch_{0U};
  volatile std::uint32_t fifo_write_attempt_count_{0U};
  volatile std::uint32_t fifo_write_bytes_{0U};
  volatile std::uint32_t fifo_zero_write_count_{0U};
  volatile std::uint32_t last_fifo_write_size_{0U};
  volatile std::uint32_t wr_done_count_{0U};
  volatile std::uint32_t in_empty_irq_count_{0U};
  volatile std::uint32_t payload_in_empty_count_{0U};
  volatile std::uint32_t publish_generation_{0U};
  volatile std::uint32_t pickup_generation_{0U};
  volatile std::uint32_t bus_reset_count_{0U};
  volatile std::uint32_t flush_attempt_count_{0U};
  volatile std::uint32_t flush_success_count_{0U};
  volatile std::uint32_t flush_timeout_count_{0U};
  volatile std::uint32_t zlp_flush_count_{0U};
  volatile std::uint32_t last_ring_pending_bytes_{0U};
  volatile std::uint32_t last_stash_pending_bytes_{0U};
  volatile std::uint32_t last_interrupt_status_{0U};
  volatile std::uint32_t last_flush_blocker_mask_{0U};
  volatile std::uint32_t last_flush_outcome_{0U};
  volatile std::uint32_t last_flush_task_zlp_count_{0U};
  volatile std::uint32_t last_flush_isr_zlp_count_{0U};
  volatile std::uint32_t last_flush_terminal_blocker_mask_{0U};
};

static_assert(sizeof(R19HwcdcFifoDiagnosticState) ==
                  8U * sizeof(std::uint32_t),
              "HWCDC diagnostic state must contain exactly eight words");
static_assert(std::is_standard_layout_v<R19HwcdcFifoDiagnosticState>,
              "HWCDC diagnostic observations require a standard layout");
static_assert(sizeof(R19HwcdcFifoDiagnosticSnapshot) ==
                  R19HwcdcFifoDiagnosticRecord::storage_word_count *
                      sizeof(std::uint32_t),
              "HWCDC diagnostic snapshots must mirror all 28 ABI words");
static_assert(std::is_standard_layout_v<R19HwcdcFifoDiagnosticSnapshot>,
              "HWCDC diagnostic snapshots require a standard layout");
static_assert(std::is_standard_layout_v<R19HwcdcFifoDiagnosticRecord>,
              "JTAG field offsets require a standard-layout FIFO record");
static_assert(alignof(R19HwcdcFifoDiagnosticRecord) >=
                  alignof(std::uint32_t),
              "HWCDC FIFO diagnostic storage requires 32-bit alignment");
static_assert(sizeof(R19HwcdcFifoDiagnosticRecord) ==
                  R19HwcdcFifoDiagnosticRecord::storage_word_count *
                      sizeof(std::uint32_t),
              "R19 HWCDC FIFO diagnostic schema 2 storage must be 28 words");

// Independent, fixed-size restart evidence. The existing 112-byte FIFO record
// and all of its offsets remain unchanged. Samples describe committed events,
// not continuously live USB registers. HWCDC serializes mutators with TX mux.
inline constexpr std::uint32_t r19_hwcdc_restart_diagnostic_magic = 0x48313952U;
inline constexpr std::uint32_t r19_hwcdc_restart_diagnostic_schema = 1U;

enum class R19HwcdcRestartPhase : std::uint32_t {
  PostEnqueueIdleTransition = 1U,
  FlushIdlePending = 2U,
};

enum class R19HwcdcRestartOrigin : std::uint32_t {
  EntryCleanIdle = 1U,
  PostEnqueueIdleTransition = 2U,
};

enum class R19HwcdcRestartOutcome : std::uint32_t {
  Published = 1U,
  ZeroWriteRejected = 2U,
  ResetBeforeWrite = 3U,
  ResetAfterWrite = 4U,
  Invalidated = 5U,
};

enum class R19HwcdcRestartDiagnosticFlag : std::uint32_t {
  Initialized = 1U,
  FirstBlockedLatched = 2U,
  LatestRestartValid = 4U,
};

struct R19HwcdcRestartDiagnosticState final {
  // Uses the FIFO diagnostic flags above, not the independent record flags.
  std::uint32_t flags{0U};
  std::uint32_t tx_loss_epoch{0U};
  std::uint32_t ring_pending_bytes{0U};
  std::uint32_t stash_pending_bytes{0U};
  std::uint32_t publish_generation{0U};
  std::uint32_t pickup_generation{0U};
  std::uint32_t interrupt_status{0U};
  std::uint32_t interrupt_enable_mask{0U};
};

struct R19HwcdcRestartDiagnosticSnapshot final {
  std::uint32_t active_writer{0U};
  std::uint32_t sequence{0U};
  std::uint32_t magic{0U};
  std::uint32_t schema{0U};
  std::uint32_t flags{0U};
  std::uint32_t event_count{0U};
  std::uint32_t blocked_count{0U};
  std::uint32_t restart_count{0U};
  std::uint32_t first_phase{0U};
  std::uint32_t first_event_ordinal{0U};
  R19HwcdcRestartDiagnosticState first_state{};
  std::uint32_t latest_origin{0U};
  std::uint32_t latest_outcome{0U};
  std::uint32_t latest_requested_bytes{0U};
  std::uint32_t latest_written_bytes{0U};
  std::uint32_t latest_event_ordinal{0U};
  R19HwcdcRestartDiagnosticState latest_state{};
  std::uint32_t reserved{0U};

  [[nodiscard]] constexpr bool valid_header() const noexcept {
    return magic == r19_hwcdc_restart_diagnostic_magic &&
           schema == r19_hwcdc_restart_diagnostic_schema;
  }
};

struct R19HwcdcRestartDiagnosticRecordTestAccess;

class alignas(std::uint32_t) R19HwcdcRestartDiagnosticRecord final {
 public:
  static constexpr std::size_t storage_word_count = 32U;
  static constexpr std::uint32_t default_snapshot_attempts = 8U;

  R19HwcdcRestartDiagnosticRecord() noexcept = default;
  R19HwcdcRestartDiagnosticRecord(const R19HwcdcRestartDiagnosticRecord&) = delete;
  R19HwcdcRestartDiagnosticRecord& operator=(
      const R19HwcdcRestartDiagnosticRecord&) = delete;
  R19HwcdcRestartDiagnosticRecord(R19HwcdcRestartDiagnosticRecord&&) = delete;
  R19HwcdcRestartDiagnosticRecord& operator=(
      R19HwcdcRestartDiagnosticRecord&&) = delete;

  [[nodiscard]] bool initialize() noexcept {
    begin_write();
    clear_fields();
    magic_ = r19_hwcdc_restart_diagnostic_magic;
    schema_ = r19_hwcdc_restart_diagnostic_schema;
    flags_ = 1U;
    commit_write();
    return true;
  }

  void reset() noexcept {
    begin_write();
    clear_fields();
    commit_write();
  }

  [[nodiscard]] bool record_blocked(
      const R19HwcdcRestartDiagnosticState& state,
      R19HwcdcRestartPhase phase) noexcept {
    const auto phase_value = static_cast<std::uint32_t>(phase);
    constexpr std::uint32_t unsafe_flags = (1U << 4U) | (1U << 5U) |
        (1U << 6U) | (1U << 7U) | (1U << 8U) | (1U << 9U);
    if (!initialized() || !valid_state(state) || phase_value < 1U ||
        phase_value > 2U ||
        (state.ring_pending_bytes == 0U && state.stash_pending_bytes == 0U) ||
        (state.flags & (1U << 3U)) == 0U ||
        (state.flags & unsafe_flags) != 0U) {
      return false;
    }
    begin_write();
    increment(event_count_);
    increment(blocked_count_);
    if ((flags_ & 2U) == 0U) {
      first_phase_ = phase_value;
      first_event_ordinal_ = event_count_;
      write_state(first_state_, state);
      flags_ = static_cast<std::uint32_t>(flags_ | 2U);
    }
    commit_write();
    return true;
  }

  [[nodiscard]] bool record_restart(
      const R19HwcdcRestartDiagnosticState& state,
      R19HwcdcRestartOrigin origin, R19HwcdcRestartOutcome outcome,
      std::uint32_t requested_bytes, std::uint32_t written_bytes) noexcept {
    const auto origin_value = static_cast<std::uint32_t>(origin);
    const auto outcome_value = static_cast<std::uint32_t>(outcome);
    const bool published = outcome == R19HwcdcRestartOutcome::Published;
    const bool reset_after = outcome == R19HwcdcRestartOutcome::ResetAfterWrite;
    if (!initialized() || !valid_state(state) || origin_value < 1U ||
        origin_value > 2U || outcome_value < 1U || outcome_value > 5U ||
        requested_bytes == 0U || requested_bytes > 32U ||
        written_bytes > requested_bytes ||
        ((published || reset_after) ? written_bytes == 0U : written_bytes != 0U) ||
        (published && (state.flags & (1U << 4U)) == 0U)) {
      return false;
    }
    begin_write();
    increment(event_count_);
    increment(restart_count_);
    latest_origin_ = origin_value;
    latest_outcome_ = outcome_value;
    latest_requested_bytes_ = requested_bytes;
    latest_written_bytes_ = written_bytes;
    latest_event_ordinal_ = event_count_;
    write_state(latest_state_, state);
    flags_ = static_cast<std::uint32_t>(flags_ | 4U);
    commit_write();
    return true;
  }

  [[nodiscard]] bool try_snapshot(
      R19HwcdcRestartDiagnosticSnapshot& output,
      std::uint32_t maximum_attempts = default_snapshot_attempts) const noexcept {
    for (std::uint32_t attempt = 0U; attempt < maximum_attempts; ++attempt) {
      if (active_writer_ != 0U) {
        continue;
      }
      fence();
      const std::uint32_t before = sequence_;
      if ((before & 1U) != 0U) {
        continue;
      }
      R19HwcdcRestartDiagnosticSnapshot candidate{};
      candidate.sequence = before;
      candidate.magic = magic_;
      candidate.schema = schema_;
      candidate.flags = flags_;
      candidate.event_count = event_count_;
      candidate.blocked_count = blocked_count_;
      candidate.restart_count = restart_count_;
      candidate.first_phase = first_phase_;
      candidate.first_event_ordinal = first_event_ordinal_;
      candidate.first_state = read_state(first_state_);
      candidate.latest_origin = latest_origin_;
      candidate.latest_outcome = latest_outcome_;
      candidate.latest_requested_bytes = latest_requested_bytes_;
      candidate.latest_written_bytes = latest_written_bytes_;
      candidate.latest_event_ordinal = latest_event_ordinal_;
      candidate.latest_state = read_state(latest_state_);
      candidate.reserved = reserved_;
      fence();
      if (before == sequence_ && (before & 1U) == 0U && active_writer_ == 0U) {
        output = candidate;
        return true;
      }
    }
    return false;
  }

 private:
  friend struct R19HwcdcRestartDiagnosticRecordTestAccess;

  [[nodiscard]] bool initialized() const noexcept {
    return magic_ == r19_hwcdc_restart_diagnostic_magic &&
        schema_ == r19_hwcdc_restart_diagnostic_schema && (flags_ & 1U) != 0U;
  }

  [[nodiscard]] static bool valid_state(
      const R19HwcdcRestartDiagnosticState& state) noexcept {
    if ((state.flags & ~r19_hwcdc_fifo_diagnostic_known_flag_mask) != 0U) {
      return false;
    }
    const bool in_flight = (state.flags & (1U << 4U)) != 0U;
    return state.publish_generation == static_cast<std::uint32_t>(
        state.pickup_generation + (in_flight ? 1U : 0U));
  }

  static void write_state(volatile R19HwcdcRestartDiagnosticState& target,
                          const R19HwcdcRestartDiagnosticState& source) noexcept {
    target.flags = source.flags;
    target.tx_loss_epoch = source.tx_loss_epoch;
    target.ring_pending_bytes = source.ring_pending_bytes;
    target.stash_pending_bytes = source.stash_pending_bytes;
    target.publish_generation = source.publish_generation;
    target.pickup_generation = source.pickup_generation;
    target.interrupt_status = source.interrupt_status;
    target.interrupt_enable_mask = source.interrupt_enable_mask;
  }

  [[nodiscard]] static R19HwcdcRestartDiagnosticState read_state(
      const volatile R19HwcdcRestartDiagnosticState& state) noexcept {
    return {state.flags, state.tx_loss_epoch, state.ring_pending_bytes,
            state.stash_pending_bytes, state.publish_generation,
            state.pickup_generation, state.interrupt_status,
            state.interrupt_enable_mask};
  }

  void clear_fields() noexcept {
    magic_ = 0U;
    schema_ = 0U;
    flags_ = 0U;
    event_count_ = 0U;
    blocked_count_ = 0U;
    restart_count_ = 0U;
    first_phase_ = 0U;
    first_event_ordinal_ = 0U;
    write_state(first_state_, {});
    latest_origin_ = 0U;
    latest_outcome_ = 0U;
    latest_requested_bytes_ = 0U;
    latest_written_bytes_ = 0U;
    latest_event_ordinal_ = 0U;
    write_state(latest_state_, {});
    reserved_ = 0U;
  }

  static void increment(volatile std::uint32_t& value) noexcept {
    if (value != std::numeric_limits<std::uint32_t>::max()) {
      value = static_cast<std::uint32_t>(value + 1U);
    }
  }
  static void fence() noexcept {
    std::atomic_signal_fence(std::memory_order_seq_cst);
  }
  void begin_write() noexcept {
    active_writer_ = 1U;
    fence();
    sequence_ = static_cast<std::uint32_t>((sequence_ & ~1U) + 1U);
    fence();
  }
  void commit_write() noexcept {
    fence();
    sequence_ = static_cast<std::uint32_t>((sequence_ | 1U) + 1U);
    fence();
    active_writer_ = 0U;
  }

  volatile std::uint32_t active_writer_{0U};
  volatile std::uint32_t sequence_{0U};
  volatile std::uint32_t magic_{0U};
  volatile std::uint32_t schema_{0U};
  volatile std::uint32_t flags_{0U};
  volatile std::uint32_t event_count_{0U};
  volatile std::uint32_t blocked_count_{0U};
  volatile std::uint32_t restart_count_{0U};
  volatile std::uint32_t first_phase_{0U};
  volatile std::uint32_t first_event_ordinal_{0U};
  volatile R19HwcdcRestartDiagnosticState first_state_{};
  volatile std::uint32_t latest_origin_{0U};
  volatile std::uint32_t latest_outcome_{0U};
  volatile std::uint32_t latest_requested_bytes_{0U};
  volatile std::uint32_t latest_written_bytes_{0U};
  volatile std::uint32_t latest_event_ordinal_{0U};
  volatile R19HwcdcRestartDiagnosticState latest_state_{};
  volatile std::uint32_t reserved_{0U};
};

static_assert(sizeof(R19HwcdcRestartDiagnosticState) == 8U * sizeof(std::uint32_t));
static_assert(sizeof(R19HwcdcRestartDiagnosticSnapshot) == 128U);
static_assert(sizeof(R19HwcdcRestartDiagnosticRecord) == 128U);
static_assert(std::is_standard_layout_v<R19HwcdcRestartDiagnosticSnapshot>);
static_assert(std::is_standard_layout_v<R19HwcdcRestartDiagnosticRecord>);
static_assert(offsetof(R19HwcdcRestartDiagnosticSnapshot, first_state) == 40U);
static_assert(offsetof(R19HwcdcRestartDiagnosticSnapshot, latest_origin) == 72U);
static_assert(offsetof(R19HwcdcRestartDiagnosticSnapshot, latest_state) == 92U);
static_assert(offsetof(R19HwcdcRestartDiagnosticSnapshot, reserved) == 124U);

}  // namespace vc_lora::experimental
