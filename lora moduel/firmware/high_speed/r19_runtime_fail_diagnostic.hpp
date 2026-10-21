#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>

#include "vc_lora/mavlink_frame.hpp"

namespace vc_lora::experimental {

inline constexpr bool r19_runtime_fail_diagnostic_deployment_authorized =
    false;

enum class R19RuntimeFailRole : std::uint8_t {
  Invalid = 0U,
  Ground = 1U,
  Vehicle = 2U,
};

struct R19RuntimeFailStatusSnapshot {
  std::uint8_t startup_fault{0U};
  std::uint8_t e220_state{0U};
  std::uint8_t e220_fault{0U};
  std::uint8_t writer_status{0U};
  std::uint8_t radio_session_status{0U};
  bool adapter_fail_closed{false};
  std::uint8_t tdd_state{0U};
  std::uint32_t usb_loss_epoch{0U};

  [[nodiscard]] constexpr bool operator==(
      const R19RuntimeFailStatusSnapshot& other) const noexcept {
    return startup_fault == other.startup_fault &&
           e220_state == other.e220_state &&
           e220_fault == other.e220_fault &&
           writer_status == other.writer_status &&
           radio_session_status == other.radio_session_status &&
           adapter_fail_closed == other.adapter_fail_closed &&
           tdd_state == other.tdd_state &&
           usb_loss_epoch == other.usb_loss_epoch;
  }

  [[nodiscard]] constexpr bool operator!=(
      const R19RuntimeFailStatusSnapshot& other) const noexcept {
    return !(*this == other);
  }
};

struct R19RuntimeFailEvidence {
  R19RuntimeFailRole role{R19RuntimeFailRole::Invalid};
  std::uint16_t source_line{0U};
  std::uint64_t monotonic_ms{0U};
  R19RuntimeFailStatusSnapshot status{};

  [[nodiscard]] constexpr bool valid() const noexcept {
    return (role == R19RuntimeFailRole::Ground ||
            role == R19RuntimeFailRole::Vehicle) &&
           source_line != 0U;
  }
};

// A runtime stop can cascade through several owners. Preserve only the first
// boundary which requested the permanent stop; later observations must never
// rewrite the evidence used to diagnose the original fault.
class R19RuntimeFailLatch final {
 public:
  [[nodiscard]] constexpr bool latch(
      R19RuntimeFailRole role, std::uint16_t source_line,
      std::uint64_t monotonic_ms,
      const R19RuntimeFailStatusSnapshot& status) noexcept {
    if (latched_ || source_line == 0U ||
        (role != R19RuntimeFailRole::Ground &&
         role != R19RuntimeFailRole::Vehicle)) {
      return false;
    }
    evidence_ = {role, source_line, monotonic_ms, status};
    latched_ = true;
    return true;
  }

  [[nodiscard]] constexpr bool latched() const noexcept { return latched_; }

  [[nodiscard]] constexpr const R19RuntimeFailEvidence& evidence()
      const noexcept {
    return evidence_;
  }

 private:
  R19RuntimeFailEvidence evidence_{};
  bool latched_{false};
};

enum class R19RuntimeFailWriteStatus : std::uint8_t {
  Invalid = 0U,
  WouldBlock,
  Progress,
  Complete,
};

struct R19RuntimeFailWriteView {
  const std::uint8_t* bytes{nullptr};
  std::size_t size{0U};
};

enum class R19RuntimeAliveState : std::uint8_t {
  Invalid = 0U,
  Armed,
  Alive,
};

struct R19RuntimeAliveEvidence {
  R19RuntimeFailRole role{R19RuntimeFailRole::Invalid};
  R19RuntimeAliveState state{R19RuntimeAliveState::Invalid};
  std::uint32_t diagnostic_sequence{0U};
  std::uint64_t monotonic_ms{0U};
  R19RuntimeFailStatusSnapshot status{};

  [[nodiscard]] constexpr bool valid() const noexcept {
    return (role == R19RuntimeFailRole::Ground ||
            role == R19RuntimeFailRole::Vehicle) &&
           (state == R19RuntimeAliveState::Armed ||
            state == R19RuntimeAliveState::Alive);
  }
};

enum class R19RuntimeDiagnosticAction : std::uint8_t {
  None = 0U,
  Armed,
  Alive,
  FailRepeat,
};

// Diagnostic-only evidence for failures in the USB publication path. This
// does not change the R19A/R19F wire contract; it preserves the first local
// observation so a later cascade cannot overwrite the initiating condition.
enum class R19RuntimeDiagnosticTransportFailureReason : std::uint8_t {
  None = 0U,
  CadenceStartRejected,
  CadenceFailClosedObserved,
  GroundBoundaryImpossible,
  GroundReservationEpochChanged,
  GroundReservationDeadlineExpired,
  GroundReservationDeadlineOverflow,
  GroundReservationFlushFailed,
  GroundReservationFlushEpochChanged,
  GroundReservationFlushLate,
  FrameDeadlineExpired,
  StageRejected,
  EpochChangedBeforeWrite,
  AcceptedBeyondRequest,
  PublisherWriteStateInvalid,
  FlushDeadlineInvalidOrExpired,
  FlushFailed,
  EpochChangedAfterFlush,
  FlushCompletedLate,
  CadenceCommitRejected,
  AlivePublisherResetRejected,
  // Append-only: the JTAG reader and saved evidence use these numeric values.
  GroundBoundaryHostLostWhileDraining,
  GroundBoundaryHostAbsentWithIrreversiblePrefix,
  GroundBoundaryEpochChanged,
  GroundBoundaryDeadlineExpired,
  GroundBoundaryOrderedBacklogDiscardFailed,
  GroundBoundaryHeldHeartbeatDiscardFailed,
  GroundBoundaryEgressPumpInvalid,
  GroundBoundaryFlushFailed,
  GroundBoundaryFlushEpochChanged,
  GroundBoundaryFlushLate,
};

struct R19RuntimeDiagnosticTransportTrace final {
  static constexpr std::uint8_t host_gate_plugged = 0x01U;
  static constexpr std::uint8_t host_gate_endpoint_ready = 0x02U;
  static constexpr std::uint8_t host_gate_writable = 0x04U;
  static constexpr std::uint8_t host_gate_full =
      host_gate_plugged | host_gate_endpoint_ready | host_gate_writable;

  bool host_sample_seen{false};
  std::uint8_t first_host_gate_mask{0U};
  std::uint8_t last_host_gate_mask{0U};
  bool full_gate_seen{false};
  std::uint64_t first_full_gate_ms{0U};

  bool first_write_attempt_seen{false};
  std::uint64_t first_write_attempt_ms{0U};
  R19RuntimeDiagnosticAction first_write_action{
      R19RuntimeDiagnosticAction::None};
  int first_write_available{0};
  std::size_t first_write_requested{0U};
  std::size_t first_write_accepted{0U};
  std::uint32_t first_write_expected_epoch{0U};
  std::uint32_t first_write_observed_epoch{0U};

  R19RuntimeDiagnosticTransportFailureReason first_failure_reason{
      R19RuntimeDiagnosticTransportFailureReason::None};
  std::uint64_t first_failure_ms{0U};

  constexpr void observe_host_gate(bool plugged, bool endpoint_ready,
                                   int available_for_write,
                                   std::uint64_t now_ms) noexcept {
    std::uint8_t mask = 0U;
    if (plugged) {
      mask = static_cast<std::uint8_t>(mask | host_gate_plugged);
    }
    if (endpoint_ready) {
      mask = static_cast<std::uint8_t>(mask | host_gate_endpoint_ready);
    }
    if (available_for_write > 0) {
      mask = static_cast<std::uint8_t>(mask | host_gate_writable);
    }
    if (!host_sample_seen) {
      host_sample_seen = true;
      first_host_gate_mask = mask;
    }
    last_host_gate_mask = mask;
    if (!full_gate_seen && mask == host_gate_full) {
      full_gate_seen = true;
      first_full_gate_ms = now_ms;
    }
  }

  constexpr void observe_write_attempt(
      R19RuntimeDiagnosticAction action, std::uint64_t now_ms,
      int available_for_write, std::size_t requested,
      std::size_t accepted, std::uint32_t expected_epoch,
      std::uint32_t observed_epoch) noexcept {
    if (first_write_attempt_seen) {
      return;
    }
    first_write_attempt_seen = true;
    first_write_attempt_ms = now_ms;
    first_write_action = action;
    first_write_available = available_for_write;
    first_write_requested = requested;
    first_write_accepted = accepted;
    first_write_expected_epoch = expected_epoch;
    first_write_observed_epoch = observed_epoch;
  }

  constexpr void latch_failure(
      R19RuntimeDiagnosticTransportFailureReason reason,
      std::uint64_t now_ms) noexcept {
    if (reason == R19RuntimeDiagnosticTransportFailureReason::None ||
        first_failure_reason !=
            R19RuntimeDiagnosticTransportFailureReason::None) {
      return;
    }
    first_failure_reason = reason;
    first_failure_ms = now_ms;
  }
};

// Pure scheduling state for the diagnostic-only transport. An action remains
// pending until the caller commits it after the complete frame has reached the
// physical flush boundary. A blocked or absent host therefore cannot consume
// ARMED, ALIVE, or first-failure evidence. Once a first failure is observed,
// normal liveness stops and the immutable R19F snapshot is retried at a fixed
// rate. The fixed upper bound covers the flash-to-capture delay while ensuring
// that even a diagnostic binary cannot transmit forever after fail-close.
class R19RuntimeDiagnosticCadence final {
 public:
  static constexpr std::uint64_t period_ms = 1000U;
  static constexpr std::uint16_t maximum_fail_transmissions = 120U;

  [[nodiscard]] constexpr bool start(std::uint64_t now_ms) noexcept {
    if (started_ || failed_) {
      return false;
    }
    started_ = true;
    last_observed_ms_ = now_ms;
    next_due_ms_ = now_ms;
    return true;
  }

  [[nodiscard]] constexpr R19RuntimeDiagnosticAction
  due(std::uint64_t now_ms, bool first_failure_latched) noexcept {
    if (!started_ || failed_) {
      return R19RuntimeDiagnosticAction::None;
    }
    if (now_ms < last_observed_ms_) {
      fail();
      return R19RuntimeDiagnosticAction::None;
    }
    last_observed_ms_ = now_ms;

    if (first_failure_latched && !fail_mode_) {
      // The production adapter calls due() only while no diagnostic wire
      // image is staged. Therefore an ARMED/ALIVE action held solely by this
      // scheduler may be abandoned safely when immutable first-failure
      // evidence appears. Without this preemption, a liveness action blocked
      // behind a dirty Ground USB boundary would prevent fail-close
      // convergence forever after the normal product loop stops.
      fail_mode_ = true;
      pending_action_ = R19RuntimeDiagnosticAction::None;
      next_due_ms_ = now_ms;
    }
    if (pending_action_ != R19RuntimeDiagnosticAction::None) {
      return pending_action_;
    }
    if (fail_mode_) {
      if (fail_transmissions_ >= maximum_fail_transmissions ||
          now_ms < next_due_ms_) {
        return R19RuntimeDiagnosticAction::None;
      }
      pending_action_ = R19RuntimeDiagnosticAction::FailRepeat;
      return pending_action_;
    }
    if (!armed_committed_) {
      pending_action_ = R19RuntimeDiagnosticAction::Armed;
      return pending_action_;
    }
    if (now_ms >= next_due_ms_) {
      pending_action_ = R19RuntimeDiagnosticAction::Alive;
    }
    return pending_action_;
  }

  [[nodiscard]] constexpr bool commit(R19RuntimeDiagnosticAction action,
                                      std::uint64_t now_ms) noexcept {
    if (!started_ || failed_ || action == R19RuntimeDiagnosticAction::None ||
        action != pending_action_) {
      return false;
    }
    if (now_ms < last_observed_ms_) {
      fail();
      return false;
    }
    last_observed_ms_ = now_ms;
    pending_action_ = R19RuntimeDiagnosticAction::None;

    if (action == R19RuntimeDiagnosticAction::FailRepeat) {
      ++fail_transmissions_;
      if (fail_transmissions_ >= maximum_fail_transmissions) {
        next_due_ms_ = std::numeric_limits<std::uint64_t>::max();
        return true;
      }
      return schedule_next(now_ms);
    }

    if (diagnostic_sequence_ ==
        std::numeric_limits<std::uint32_t>::max()) {
      fail();
      return false;
    }
    ++diagnostic_sequence_;
    if (action == R19RuntimeDiagnosticAction::Armed) {
      armed_committed_ = true;
    }
    return schedule_next(now_ms);
  }

  [[nodiscard]] constexpr bool started() const noexcept { return started_; }
  [[nodiscard]] constexpr bool fail_closed() const noexcept { return failed_; }
  [[nodiscard]] constexpr std::uint32_t diagnostic_sequence() const noexcept {
    return diagnostic_sequence_;
  }
  [[nodiscard]] constexpr std::uint64_t next_due_ms() const noexcept {
    return next_due_ms_;
  }
  [[nodiscard]] constexpr std::uint16_t fail_transmissions() const noexcept {
    return fail_transmissions_;
  }
  [[nodiscard]] constexpr R19RuntimeDiagnosticAction pending_action()
      const noexcept {
    return pending_action_;
  }
  [[nodiscard]] constexpr bool fail_repeat_exhausted() const noexcept {
    return fail_mode_ &&
           fail_transmissions_ >= maximum_fail_transmissions;
  }

 private:
  [[nodiscard]] constexpr bool schedule_next(std::uint64_t now_ms) noexcept {
    if (now_ms >
        std::numeric_limits<std::uint64_t>::max() - period_ms) {
      fail();
      return false;
    }
    next_due_ms_ = now_ms + period_ms;
    return true;
  }

  constexpr void fail() noexcept {
    failed_ = true;
    pending_action_ = R19RuntimeDiagnosticAction::None;
  }

  std::uint64_t last_observed_ms_{0U};
  std::uint64_t next_due_ms_{0U};
  std::uint32_t diagnostic_sequence_{0U};
  std::uint16_t fail_transmissions_{0U};
  R19RuntimeDiagnosticAction pending_action_{
      R19RuntimeDiagnosticAction::None};
  bool started_{false};
  bool armed_committed_{false};
  bool fail_mode_{false};
  bool failed_{false};
};

// Produces one standard MAVLink2 STATUSTEXT message. The payload is the
// minimum legal 51 bytes, so the complete unsigned wire image is 63 bytes and
// fits one USB CDC full-speed packet. The 50-byte text field has no terminator:
//
// R19F:<role>:<line16>:<time64>:<six status bytes>:<USB epoch32>
//
// The six status bytes are startup fault, E220 state, E220 fault, writer
// status, radio-session status, and (adapter-fail bit 7 | TDD state bits 6:0).
// Every numeric field is fixed-width uppercase hexadecimal. This keeps the
// evidence machine-readable without a custom MAVLink dialect or PARAM_VALUE.
class R19RuntimeFailDiagnosticPublisher final {
 public:
  static constexpr std::uint32_t message_id = 253U;
  static constexpr std::uint8_t system_id = 254U;
  static constexpr std::uint8_t component_id = 190U;
  static constexpr std::uint8_t severity_critical = 2U;
  static constexpr std::size_t text_bytes = 50U;
  static constexpr std::size_t payload_bytes = 51U;
  static constexpr std::size_t wire_bytes = 63U;

  [[nodiscard]] bool stage(const R19RuntimeFailEvidence& evidence,
                           std::uint8_t sequence) noexcept {
    if (staged_ || complete_ || failed_ || !evidence.valid() ||
        evidence.status.tdd_state > 0x7FU) {
      return false;
    }

    std::array<std::uint8_t, payload_bytes> payload{};
    payload[0U] = severity_critical;
    std::uint8_t* const text = payload.data() + 1U;
    text[0U] = static_cast<std::uint8_t>('R');
    text[1U] = static_cast<std::uint8_t>('1');
    text[2U] = static_cast<std::uint8_t>('9');
    text[3U] = static_cast<std::uint8_t>('F');
    text[4U] = static_cast<std::uint8_t>(':');
    text[5U] = static_cast<std::uint8_t>(
        evidence.role == R19RuntimeFailRole::Ground ? 'G' : 'V');
    text[6U] = static_cast<std::uint8_t>(':');
    write_hex(evidence.source_line, 4U, text + 7U);
    text[11U] = static_cast<std::uint8_t>(':');
    write_hex(evidence.monotonic_ms, 16U, text + 12U);
    text[28U] = static_cast<std::uint8_t>(':');
    write_hex(evidence.status.startup_fault, 2U, text + 29U);
    write_hex(evidence.status.e220_state, 2U, text + 31U);
    write_hex(evidence.status.e220_fault, 2U, text + 33U);
    write_hex(evidence.status.writer_status, 2U, text + 35U);
    write_hex(evidence.status.radio_session_status, 2U, text + 37U);
    const std::uint8_t packed_adapter_tdd = static_cast<std::uint8_t>(
        (evidence.status.adapter_fail_closed ? 0x80U : 0U) |
        evidence.status.tdd_state);
    write_hex(packed_adapter_tdd, 2U, text + 39U);
    text[41U] = static_cast<std::uint8_t>(':');
    write_hex(evidence.status.usb_loss_epoch, 8U, text + 42U);

    if (!encode_mavlink_v2(sequence, system_id, component_id, message_id,
                           payload.data(), payload.size(), frame_) ||
        frame_.size != wire_bytes) {
      failed_ = true;
      frame_ = {};
      return false;
    }
    offset_ = 0U;
    bound_evidence_ = evidence;
    evidence_bound_ = true;
    staged_ = true;
    return true;
  }

  // Re-encode the exact evidence copied by the first successful stage. The
  // caller may only request a repeat after the prior frame completed, so a
  // retry can neither replace an in-flight suffix nor substitute later state.
  [[nodiscard]] bool stage_repeat(std::uint8_t sequence) noexcept {
    if (!complete_ || failed_ || !evidence_bound_) {
      return false;
    }
    const R19RuntimeFailEvidence first_evidence = bound_evidence_;
    R19RuntimeFailDiagnosticPublisher repeated{};
    if (!repeated.stage(first_evidence, sequence)) {
      return false;
    }
    *this = repeated;
    return true;
  }

  [[nodiscard]] R19RuntimeFailWriteView pending_write() const noexcept {
    if (!pending()) {
      return {};
    }
    return {frame_.bytes.data() + offset_, frame_.size - offset_};
  }

  [[nodiscard]] R19RuntimeFailWriteStatus complete_write(
      std::size_t accepted_bytes) noexcept {
    if (!pending()) {
      return R19RuntimeFailWriteStatus::Invalid;
    }
    const std::size_t remaining_bytes = frame_.size - offset_;
    if (accepted_bytes > remaining_bytes) {
      failed_ = true;
      return R19RuntimeFailWriteStatus::Invalid;
    }
    if (accepted_bytes == 0U) {
      return R19RuntimeFailWriteStatus::WouldBlock;
    }
    offset_ += accepted_bytes;
    if (offset_ == frame_.size) {
      complete_ = true;
      return R19RuntimeFailWriteStatus::Complete;
    }
    return R19RuntimeFailWriteStatus::Progress;
  }

  // A diagnostic-only bootstrap frame may be completely queued but then be
  // destroyed by a USB session reset before physical flush proof.  Rewind the
  // same immutable wire image (including its MAVLink sequence and evidence)
  // so the new session never receives a suffix or a newly sampled snapshot.
  [[nodiscard]] bool restart_complete_write() noexcept {
    if (!staged_ || !complete_ || failed_) {
      return false;
    }
    offset_ = 0U;
    complete_ = false;
    return true;
  }

  [[nodiscard]] bool pending() const noexcept {
    return staged_ && !complete_ && !failed_ && offset_ < frame_.size;
  }

  [[nodiscard]] std::size_t remaining() const noexcept {
    return pending() ? frame_.size - offset_ : 0U;
  }

  [[nodiscard]] bool complete() const noexcept { return complete_; }
  [[nodiscard]] bool fail_closed() const noexcept { return failed_; }
  [[nodiscard]] constexpr const R19RuntimeFailEvidence& bound_evidence()
      const noexcept {
    return bound_evidence_;
  }

 private:
  static constexpr std::uint8_t hex_digit(std::uint8_t value) noexcept {
    return static_cast<std::uint8_t>(
        value < 10U ? static_cast<std::uint8_t>('0') + value
                    : static_cast<std::uint8_t>('A') +
                          static_cast<std::uint8_t>(value - 10U));
  }

  static constexpr void write_hex(std::uint64_t value, std::size_t digits,
                                  std::uint8_t* output) noexcept {
    for (std::size_t index = 0U; index < digits; ++index) {
      const std::size_t reverse = digits - index - 1U;
      const auto nibble = static_cast<std::uint8_t>(
          (value >> static_cast<unsigned int>(reverse * 4U)) & 0x0FU);
      output[index] = hex_digit(nibble);
    }
  }

  MavlinkFrame frame_{};
  R19RuntimeFailEvidence bound_evidence_{};
  std::size_t offset_{0U};
  bool evidence_bound_{false};
  bool staged_{false};
  bool complete_{false};
  bool failed_{false};
};

// Produces the diagnostic-only setup/liveness STATUSTEXT. The fixed text is:
//
// R19A:<role>:<A|L>:<ordinal32>:<time64>:<six status bytes><NUL><NUL><NUL>
//
// The six status bytes have exactly the same meaning and packing as R19F.
// A means the diagnostic setup is armed; L means bridge-ready liveness. The
// caller-provided ordinal counts successfully flushed R19A emissions.
class R19RuntimeAliveDiagnosticPublisher final {
 public:
  static constexpr std::uint32_t message_id = 253U;
  static constexpr std::uint8_t system_id = 254U;
  static constexpr std::uint8_t component_id = 190U;
  static constexpr std::uint8_t severity_info = 6U;
  static constexpr std::size_t encoded_text_bytes = 47U;
  static constexpr std::size_t text_bytes = 50U;
  static constexpr std::size_t payload_bytes = 51U;
  static constexpr std::size_t wire_bytes = 63U;

  [[nodiscard]] bool stage(const R19RuntimeAliveEvidence& evidence,
                           std::uint8_t mavlink_sequence) noexcept {
    if (staged_ || complete_ || failed_ || !evidence.valid() ||
        evidence.status.tdd_state > 0x7FU) {
      return false;
    }

    std::array<std::uint8_t, payload_bytes> payload{};
    payload[0U] = severity_info;
    std::uint8_t* const text = payload.data() + 1U;
    text[0U] = static_cast<std::uint8_t>('R');
    text[1U] = static_cast<std::uint8_t>('1');
    text[2U] = static_cast<std::uint8_t>('9');
    text[3U] = static_cast<std::uint8_t>('A');
    text[4U] = static_cast<std::uint8_t>(':');
    text[5U] = static_cast<std::uint8_t>(
        evidence.role == R19RuntimeFailRole::Ground ? 'G' : 'V');
    text[6U] = static_cast<std::uint8_t>(':');
    text[7U] = static_cast<std::uint8_t>(
        evidence.state == R19RuntimeAliveState::Armed ? 'A' : 'L');
    text[8U] = static_cast<std::uint8_t>(':');
    write_hex(evidence.diagnostic_sequence, 8U, text + 9U);
    text[17U] = static_cast<std::uint8_t>(':');
    write_hex(evidence.monotonic_ms, 16U, text + 18U);
    text[34U] = static_cast<std::uint8_t>(':');
    write_hex(evidence.status.startup_fault, 2U, text + 35U);
    write_hex(evidence.status.e220_state, 2U, text + 37U);
    write_hex(evidence.status.e220_fault, 2U, text + 39U);
    write_hex(evidence.status.writer_status, 2U, text + 41U);
    write_hex(evidence.status.radio_session_status, 2U, text + 43U);
    const std::uint8_t packed_adapter_tdd = static_cast<std::uint8_t>(
        (evidence.status.adapter_fail_closed ? 0x80U : 0U) |
        evidence.status.tdd_state);
    write_hex(packed_adapter_tdd, 2U, text + 45U);

    if (!encode_mavlink_v2(mavlink_sequence, system_id, component_id,
                           message_id, payload.data(), payload.size(),
                           frame_) ||
        frame_.size != wire_bytes) {
      failed_ = true;
      frame_ = {};
      return false;
    }
    offset_ = 0U;
    staged_ = true;
    return true;
  }

  [[nodiscard]] R19RuntimeFailWriteView pending_write() const noexcept {
    if (!pending()) {
      return {};
    }
    return {frame_.bytes.data() + offset_, frame_.size - offset_};
  }

  [[nodiscard]] R19RuntimeFailWriteStatus complete_write(
      std::size_t accepted_bytes) noexcept {
    if (!pending()) {
      return R19RuntimeFailWriteStatus::Invalid;
    }
    const std::size_t remaining_bytes = frame_.size - offset_;
    if (accepted_bytes > remaining_bytes) {
      failed_ = true;
      return R19RuntimeFailWriteStatus::Invalid;
    }
    if (accepted_bytes == 0U) {
      return R19RuntimeFailWriteStatus::WouldBlock;
    }
    offset_ += accepted_bytes;
    if (offset_ == frame_.size) {
      complete_ = true;
      return R19RuntimeFailWriteStatus::Complete;
    }
    return R19RuntimeFailWriteStatus::Progress;
  }

  [[nodiscard]] bool restart_complete_write() noexcept {
    if (!staged_ || !complete_ || failed_) {
      return false;
    }
    offset_ = 0U;
    complete_ = false;
    return true;
  }

  [[nodiscard]] bool reset() noexcept {
    if (!complete_ || failed_) {
      return false;
    }
    frame_ = {};
    offset_ = 0U;
    staged_ = false;
    complete_ = false;
    return true;
  }

  // A first-failure snapshot has higher diagnostic priority than an R19A
  // image which has not placed any byte on the wire.  Cancellation is safe
  // only at offset zero: once even one byte was accepted, the complete
  // MAVLink frame must finish before R19F can start or the shared byte stream
  // would lose its frame boundary.
  [[nodiscard]] bool cancel_if_unwritten() noexcept {
    if (!staged_ || complete_ || failed_ || offset_ != 0U) {
      return false;
    }
    frame_ = {};
    staged_ = false;
    return true;
  }

  [[nodiscard]] bool pending() const noexcept {
    return staged_ && !complete_ && !failed_ && offset_ < frame_.size;
  }
  [[nodiscard]] std::size_t remaining() const noexcept {
    return pending() ? frame_.size - offset_ : 0U;
  }
  [[nodiscard]] bool complete() const noexcept { return complete_; }
  [[nodiscard]] bool fail_closed() const noexcept { return failed_; }

 private:
  static constexpr std::uint8_t hex_digit(std::uint8_t value) noexcept {
    return static_cast<std::uint8_t>(
        value < 10U ? static_cast<std::uint8_t>('0') + value
                    : static_cast<std::uint8_t>('A') +
                          static_cast<std::uint8_t>(value - 10U));
  }

  static constexpr void write_hex(std::uint64_t value, std::size_t digits,
                                  std::uint8_t* output) noexcept {
    for (std::size_t index = 0U; index < digits; ++index) {
      const std::size_t reverse = digits - index - 1U;
      const auto nibble = static_cast<std::uint8_t>(
          (value >> static_cast<unsigned int>(reverse * 4U)) & 0x0FU);
      output[index] = hex_digit(nibble);
    }
  }

  MavlinkFrame frame_{};
  std::size_t offset_{0U};
  bool staged_{false};
  bool complete_{false};
  bool failed_{false};
};

static_assert(R19RuntimeFailDiagnosticPublisher::wire_bytes == 63U,
              "diagnostic STATUSTEXT must fit one 64-byte USB packet");
static_assert(R19RuntimeAliveDiagnosticPublisher::encoded_text_bytes == 47U,
              "alive diagnostic text contract must remain fixed");
static_assert(R19RuntimeAliveDiagnosticPublisher::wire_bytes == 63U,
              "alive STATUSTEXT must fit one 64-byte USB packet");

}  // namespace vc_lora::experimental
