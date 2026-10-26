#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

#include "e220_high_speed_transport_model.hpp"
#include "high_speed_phase6_adapter.hpp"
#include "peer_completion_receipt.hpp"
#include "phase6_radio_writer_arbiter.hpp"

namespace vc_lora::experimental {

enum class Phase6HighSpeedRadioSessionStatus : std::uint8_t {
  Idle = 0U,
  StreamStarted,
  StreamActive,
  ActionRetained,
  AwaitAdmission,
  WriteReady,
  RetryRetained,
  WriteCommitted,
  AwaitBufferCredit,
  BufferCreditReleased,
  ExplicitRestoreRequired,
  StandardRestored,
  FailClosed,
};

struct Phase6HighSpeedRadioWrite final {
  std::uint32_t action_token{0U};
  std::uint32_t writer_generation{0U};
  std::uint32_t wire_ordinal{0U};
  std::array<std::uint8_t, HighSpeedCandidateContract::radio_chunk_bytes>
      bytes{};
  std::size_t size{0U};

  [[nodiscard]] constexpr bool valid() const noexcept {
    return action_token != 0U && writer_generation != 0U && size != 0U &&
           size <= bytes.size();
  }
};

// Arduino-independent fixed-storage seam for the future product route. The
// bridge remains responsible for sampling AUX, executing the UART write, and
// obtaining remote-arrival or explicit TX-complete events. This class only
// retains one adapter action and consumes those physical observations.
class Phase6HighSpeedRadioSession final {
 public:
  explicit Phase6HighSpeedRadioSession(
      Phase6RadioWriterArbiter& writer_arbiter,
      std::uint64_t session_id) noexcept
      : writer_arbiter_(writer_arbiter),
        uart_gate_(session_id),
        session_id_(session_id) {}

  Phase6HighSpeedRadioSession(const Phase6HighSpeedRadioSession&) = delete;
  Phase6HighSpeedRadioSession& operator=(
      const Phase6HighSpeedRadioSession&) = delete;
  Phase6HighSpeedRadioSession(Phase6HighSpeedRadioSession&&) = delete;
  Phase6HighSpeedRadioSession& operator=(
      Phase6HighSpeedRadioSession&&) = delete;

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus begin(
      std::uint32_t stream_token, Direction direction,
      const Phase6HighSpeedStreamLimits& limits,
      std::uint32_t now_ms) noexcept {
    if (!accept_time(now_ms) || stream_started_ || session_id_ == 0U ||
        stream_token == 0U ||
        (direction != Direction::Downlink && direction != Direction::Uplink) ||
        !limits.valid() ||
        limits.maximum_record_bytes >
            HighSpeedCandidateContract::radio_chunk_bytes) {
      return fail();
    }
    Phase6RadioWriterLease lease{};
    if (writer_arbiter_.begin_high_speed_stream(stream_token, limits,
                                                lease) !=
            Phase6RadioWriterStatus::HighSpeedStreamLeaseGranted ||
        !lease.valid()) {
      return fail();
    }
    stream_started_ = true;
    direction_ = direction;
    stream_limits_ = limits;
    stream_lease_ = lease;
    return set_status(Phase6HighSpeedRadioSessionStatus::StreamStarted);
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus observe_aux(
      std::uint32_t now_ms, bool high) noexcept {
    if (!active_stream() || !accept_time(now_ms)) {
      return fail();
    }
    uart_gate_.observe_aux(now_ms, high);
    return set_status(Phase6HighSpeedRadioSessionStatus::StreamActive);
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus retain_adapter_action(
      const HighSpeedPhase6Output& action, bool final_action,
      std::uint32_t now_ms) noexcept {
    if (!active_stream() || !accept_time(now_ms) || pending_action_ ||
        write_admitted_ || final_action_committed_ ||
        action.type != HighSpeedPhase6OutputType::RadioWrite ||
        action.semantic == HighSpeedActionType::None || action.token == 0U ||
        action.writer_generation == 0U || action.size == 0U ||
        action.size > HighSpeedCandidateContract::radio_chunk_bytes ||
        action.size > stream_limits_.maximum_record_bytes ||
        uart_record_count_ >= stream_limits_.maximum_uart_records ||
        static_cast<std::uint64_t>(action.size) >
            stream_limits_.maximum_accepted_bytes ||
        accepted_bytes_ >
            stream_limits_.maximum_accepted_bytes -
                static_cast<std::uint64_t>(action.size) ||
        (uart_record_count_ != 0U &&
         (action.token <= last_action_token_ ||
          action.writer_generation <= last_action_writer_generation_))) {
      return fail();
    }

    pending_bytes_.fill(0U);
    for (std::size_t index = 0U; index < action.size; ++index) {
      pending_bytes_[index] = action.bytes[index];
    }
    pending_action_token_ = action.token;
    pending_action_writer_generation_ = action.writer_generation;
    pending_size_ = action.size;
    pending_final_action_ = final_action;
    pending_action_ = true;
    return set_status(Phase6HighSpeedRadioSessionStatus::ActionRetained);
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus assess_write(
      std::uint32_t now_ms,
      Phase6HighSpeedRadioWrite& output) noexcept {
    output = {};
    if (!active_stream() || !accept_time(now_ms) || !pending_action_ ||
        write_admitted_) {
      return fail();
    }
    last_admission_result_ =
        uart_gate_.assess(now_ms, direction_, pending_size_);
    if (last_admission_result_ == AdmissionResult::Ready) {
      write_admitted_ = true;
      output.action_token = pending_action_token_;
      output.writer_generation = pending_action_writer_generation_;
      output.wire_ordinal = uart_record_count_;
      output.size = pending_size_;
      output.bytes = pending_bytes_;
      return set_status(Phase6HighSpeedRadioSessionStatus::WriteReady);
    }
    if (last_admission_result_ == AdmissionResult::AuxLow ||
        last_admission_result_ == AdmissionResult::AuxNotStable ||
        last_admission_result_ == AdmissionResult::GapActive ||
        last_admission_result_ == AdmissionResult::Backpressure) {
      return set_status(Phase6HighSpeedRadioSessionStatus::AwaitAdmission);
    }
    return fail();
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus complete_uart(
      std::uint32_t action_token, std::uint32_t writer_generation,
      std::uint32_t wire_ordinal, std::size_t written,
      std::uint32_t now_ms) noexcept {
    if (!active_stream() || !accept_time(now_ms) || !pending_action_ ||
        !write_admitted_ ||
        action_token != pending_action_token_ ||
        writer_generation != pending_action_writer_generation_ ||
        wire_ordinal != uart_record_count_) {
      return fail();
    }

    const WriteCommitOutcome committed = uart_gate_.commit_write(
        now_ms, direction_, pending_size_, written);
    write_admitted_ = false;
    if (committed.result == WriteCommitResult::NoProgress && written == 0U) {
      return set_status(Phase6HighSpeedRadioSessionStatus::RetryRetained);
    }
    if (committed.result != WriteCommitResult::Committed ||
        written != pending_size_ || !committed.token.valid() ||
        !committed.token.tail_known()) {
      return fail();
    }
    if (!drain_fence_.record_accepted(committed.token)) {
      return fail();
    }
    if (writer_arbiter_.record_high_speed_uart(
            stream_lease_, pending_action_token_,
            pending_action_writer_generation_, uart_record_count_,
            static_cast<std::uint32_t>(pending_size_), now_ms) !=
        Phase6RadioWriterStatus::HighSpeedStreamUartRecorded) {
      return fail();
    }

    if (accepted_bytes_ >
        stream_limits_.maximum_accepted_bytes - pending_size_) {
      return fail();
    }
    accepted_bytes_ += pending_size_;
    last_transfer_token_ = committed.token;
    last_action_token_ = pending_action_token_;
    last_action_writer_generation_ =
        pending_action_writer_generation_;
    last_wire_ordinal_ = uart_record_count_;
    ++uart_record_count_;
    if (pending_final_action_) {
      final_action_committed_ = true;
      final_transfer_token_ = committed.token;
      final_uart_committed_ms_ = now_ms;
      final_action_token_ = pending_action_token_;
      final_action_writer_generation_ =
          pending_action_writer_generation_;
      final_wire_ordinal_ = last_wire_ordinal_;
    }
    clear_pending_action();
    return set_status(Phase6HighSpeedRadioSessionStatus::WriteCommitted);
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus
  release_buffer_credit_from_local_aux(
      std::uint32_t now_ms, const TransferToken& token) noexcept {
    if (!active_stream() || !accept_time(now_ms) ||
        !last_transfer_token_.valid() || token != last_transfer_token_ ||
        (have_last_credited_token_ && token == last_credited_token_)) {
      return fail();
    }
    if (!uart_gate_.release_buffer_credit_from_local_aux(now_ms, token)) {
      return set_status(
          Phase6HighSpeedRadioSessionStatus::AwaitBufferCredit);
    }
    have_last_credited_token_ = true;
    last_credited_token_ = token;
    if (final_action_committed_ && token == final_transfer_token_) {
      final_local_aux_release_observed_ = true;
    }
    if (final_local_aux_release_observed_ && peer_receipt_observed_) {
      return commit_peer_receipt_tail(now_ms);
    }
    return set_status(
        Phase6HighSpeedRadioSessionStatus::BufferCreditReleased);
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus observe_local_radio_status(
      std::uint32_t now_ms, bool tx_empty, bool tx_complete,
      bool aux_high) noexcept {
    if (!active_stream() || !accept_time(now_ms)) {
      return fail();
    }
    drain_fence_.observe_local_radio_status(tx_empty, tx_complete, aux_high);
    return set_status(Phase6HighSpeedRadioSessionStatus::StreamActive);
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus
  complete_stream_from_peer_receipt(
      const PeerCompletionReceiptProof& proof,
      std::uint32_t now_ms) noexcept {
    if (!active_stream() || !accept_time(now_ms) || pending_action_ ||
        write_admitted_ || !final_action_committed_ ||
        peer_receipt_observed_ || !proof.valid() ||
        proof.token() != final_transfer_token_ ||
        proof.session_id() != session_id_ ||
        proof.observed_at_ms() < final_uart_committed_ms_ ||
        proof.observed_at_ms() > now_ms) {
      return fail();
    }
    peer_receipt_proof_ = proof;
    peer_receipt_observed_ = true;
    if (!final_local_aux_release_observed_) {
      return set_status(
          Phase6HighSpeedRadioSessionStatus::AwaitBufferCredit);
    }
    return commit_peer_receipt_tail(now_ms);
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus
  complete_stream_from_remote_arrival(
      const TransferToken& final_token,
      std::uint32_t now_ms) noexcept {
    if (!ready_for_final_tail(final_token, now_ms)) {
      return fail();
    }
    const std::optional<DrainProof> proof =
        drain_fence_.observe_remote_tail(final_token, now_ms);
    if (!proof.has_value() ||
        proof->source() != EvidenceSource::RemoteArrival) {
      return fail();
    }
    return commit_final_tail(*proof, now_ms);
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus
  complete_stream_from_explicit_tx_complete(
      const TransferToken& final_token,
      std::uint32_t now_ms) noexcept {
    if (!ready_for_final_tail(final_token, now_ms)) {
      return fail();
    }
    const std::optional<DrainProof> proof =
        drain_fence_.observe_explicit_tail(final_token, now_ms);
    if (!proof.has_value() ||
        proof->source() != EvidenceSource::ExplicitTxComplete) {
      return fail();
    }
    return commit_final_tail(*proof, now_ms);
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus restore_standard(
      bool clean_session_confirmed, std::uint32_t now_ms) noexcept {
    if (failed_ || !accept_time(now_ms) || !stream_tail_complete_ ||
        standard_restored_) {
      return fail();
    }
    const Phase6RadioWriterStatus restored =
        writer_arbiter_.restore_standard(clean_session_confirmed);
    if (!clean_session_confirmed) {
      if (restored != Phase6RadioWriterStatus::ExplicitRestoreRequired) {
        return fail();
      }
      return set_status(
          Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired);
    }
    if (restored != Phase6RadioWriterStatus::StandardRestored) {
      return fail();
    }
    standard_restored_ = true;
    return set_status(Phase6HighSpeedRadioSessionStatus::StandardRestored);
  }

  [[nodiscard]] constexpr bool fail_closed() const noexcept {
    return failed_ || writer_arbiter_.fail_closed();
  }
  [[nodiscard]] constexpr bool pending_action() const noexcept {
    return pending_action_;
  }
  [[nodiscard]] constexpr bool write_admitted() const noexcept {
    return write_admitted_;
  }
  [[nodiscard]] std::size_t buffered_bytes() const noexcept {
    return uart_gate_.buffered_bytes();
  }
  [[nodiscard]] constexpr std::uint64_t accepted_bytes() const noexcept {
    return accepted_bytes_;
  }
  [[nodiscard]] constexpr std::uint32_t uart_record_count() const noexcept {
    return uart_record_count_;
  }
  [[nodiscard]] constexpr AdmissionResult last_admission_result()
      const noexcept {
    return last_admission_result_;
  }
  [[nodiscard]] constexpr const TransferToken& last_transfer_token()
      const noexcept {
    return last_transfer_token_;
  }
  [[nodiscard]] constexpr const Phase6RadioWriterLease& stream_lease()
      const noexcept {
    return stream_lease_;
  }
  [[nodiscard]] constexpr Phase6HighSpeedRadioSessionStatus last_status()
      const noexcept {
    return last_status_;
  }

 private:
  [[nodiscard]] constexpr bool active_stream() const noexcept {
    return stream_started_ && !stream_tail_complete_ && !standard_restored_ &&
           !failed_;
  }

  [[nodiscard]] bool accept_time(std::uint32_t now_ms) noexcept {
    if (failed_ || (have_last_time_ && now_ms < last_time_ms_)) {
      return false;
    }
    have_last_time_ = true;
    last_time_ms_ = now_ms;
    return true;
  }

  [[nodiscard]] bool ready_for_final_tail(
      const TransferToken& final_token, std::uint32_t now_ms) noexcept {
    return active_stream() && accept_time(now_ms) && !pending_action_ &&
           !write_admitted_ && final_action_committed_ &&
           final_local_aux_release_observed_ && final_token.valid() &&
           final_token == final_transfer_token_;
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus commit_peer_receipt_tail(
      std::uint32_t now_ms) noexcept {
    if (!peer_receipt_observed_ || !peer_receipt_proof_.valid() ||
        !final_local_aux_release_observed_ ||
        peer_receipt_proof_.token() != final_transfer_token_) {
      return fail();
    }
    const std::optional<DrainProof> proof = drain_fence_.observe_remote_tail(
        final_transfer_token_, peer_receipt_proof_.observed_at_ms());
    if (!proof.has_value() ||
        proof->source() != EvidenceSource::RemoteArrival) {
      return fail();
    }
    return commit_final_tail(*proof, now_ms);
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus commit_final_tail(
      const DrainProof& proof, std::uint32_t now_ms) noexcept {
    if (!proof.valid() || proof.token() != final_transfer_token_ ||
        !drain_fence_.direction_drained() ||
        !uart_gate_.unlock_direction(proof)) {
      return fail();
    }
    Phase6HighSpeedStreamTailEvidence evidence{};
    evidence.lease = stream_lease_;
    evidence.final_action_token = final_action_token_;
    evidence.final_action_writer_generation =
        final_action_writer_generation_;
    evidence.final_wire_ordinal = final_wire_ordinal_;
    evidence.uart_record_count = uart_record_count_;
    evidence.accepted_bytes = accepted_bytes_;
    evidence.local_aux_release_observed =
        final_local_aux_release_observed_;
    evidence.physical_tail_complete = true;
    evidence.completed_ms = proof.observed_at_ms();
    if (writer_arbiter_.observe_high_speed_stream_tail(evidence, now_ms) !=
        Phase6RadioWriterStatus::ExplicitRestoreRequired) {
      return fail();
    }
    stream_tail_complete_ = true;
    return set_status(
        Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired);
  }

  void clear_pending_action() noexcept {
    pending_bytes_.fill(0U);
    pending_action_token_ = 0U;
    pending_action_writer_generation_ = 0U;
    pending_size_ = 0U;
    pending_final_action_ = false;
    pending_action_ = false;
    write_admitted_ = false;
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus set_status(
      Phase6HighSpeedRadioSessionStatus status) noexcept {
    last_status_ = status;
    return status;
  }

  [[nodiscard]] Phase6HighSpeedRadioSessionStatus fail() noexcept {
    if (!failed_) {
      failed_ = true;
      (void)writer_arbiter_.abort_high_speed();
    }
    last_status_ = Phase6HighSpeedRadioSessionStatus::FailClosed;
    return last_status_;
  }

  Phase6RadioWriterArbiter& writer_arbiter_;
  E220UartAdmissionGate uart_gate_;
  E220DirectionDrainFence drain_fence_{};
  Phase6HighSpeedStreamLimits stream_limits_{};
  Phase6RadioWriterLease stream_lease_{};
  std::array<std::uint8_t, HighSpeedCandidateContract::radio_chunk_bytes>
      pending_bytes_{};
  TransferToken last_transfer_token_{};
  TransferToken final_transfer_token_{};
  TransferToken last_credited_token_{};
  PeerCompletionReceiptProof peer_receipt_proof_{};
  std::uint64_t session_id_{0U};
  std::uint64_t accepted_bytes_{0U};
  std::uint32_t pending_action_token_{0U};
  std::uint32_t pending_action_writer_generation_{0U};
  std::uint32_t last_action_token_{0U};
  std::uint32_t last_action_writer_generation_{0U};
  std::uint32_t final_action_token_{0U};
  std::uint32_t final_action_writer_generation_{0U};
  std::uint32_t uart_record_count_{0U};
  std::uint32_t last_wire_ordinal_{0U};
  std::uint32_t final_wire_ordinal_{0U};
  std::uint32_t final_uart_committed_ms_{0U};
  std::uint32_t last_time_ms_{0U};
  std::size_t pending_size_{0U};
  Direction direction_{Direction::Mixed};
  AdmissionResult last_admission_result_{AdmissionResult::InvalidSession};
  bool stream_started_{false};
  bool pending_action_{false};
  bool pending_final_action_{false};
  bool write_admitted_{false};
  bool final_action_committed_{false};
  bool have_last_credited_token_{false};
  bool final_local_aux_release_observed_{false};
  bool peer_receipt_observed_{false};
  bool stream_tail_complete_{false};
  bool standard_restored_{false};
  bool have_last_time_{false};
  bool failed_{false};
  Phase6HighSpeedRadioSessionStatus last_status_{
      Phase6HighSpeedRadioSessionStatus::Idle};
};

}  // namespace vc_lora::experimental
