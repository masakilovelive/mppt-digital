#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "e220_high_speed_transport_model.hpp"

namespace vc_lora::experimental {

// Candidate-only peer-consumption receipt.  VCRC is a one-way, priority
// standard-control record; receiving VCRC never creates an ACK-of-ACK.
enum class PeerCompletionReceiptKind : std::uint8_t {
  None = 0U,
  NegotiationResponseConsumed = 1U,
  TerminalRecordConsumed = 2U,
};

struct PeerCompletionReceiptFields final {
  PeerCompletionReceiptKind kind{PeerCompletionReceiptKind::None};
  std::uint64_t session_id{0U};
  std::uint32_t transfer_tag{0U};
  // NegotiationResponseConsumed: negotiation identity lease_id.
  // TerminalRecordConsumed: terminal record_id.
  std::uint64_t subject_id{0U};

  [[nodiscard]] constexpr bool valid() const noexcept {
    return (kind == PeerCompletionReceiptKind::NegotiationResponseConsumed ||
            kind == PeerCompletionReceiptKind::TerminalRecordConsumed) &&
           session_id != 0U && transfer_tag != 0U && subject_id != 0U;
  }
};

[[nodiscard]] constexpr bool operator==(
    const PeerCompletionReceiptFields& left,
    const PeerCompletionReceiptFields& right) noexcept {
  return left.kind == right.kind && left.session_id == right.session_id &&
         left.transfer_tag == right.transfer_tag &&
         left.subject_id == right.subject_id;
}

[[nodiscard]] constexpr bool operator!=(
    const PeerCompletionReceiptFields& left,
    const PeerCompletionReceiptFields& right) noexcept {
  return !(left == right);
}

using PeerCompletionReceiptFrame = std::array<std::uint8_t, 32U>;

enum class PeerCompletionReceiptError : std::uint8_t {
  None = 0U,
  InvalidFields,
  UnknownMagic,
  UnknownVersion,
  UnknownKind,
  WrongCount,
  WrongFinalIndex,
  ReservedNonZero,
  BadCrc,
};

class PeerCompletionReceiptWireCodec final {
 public:
  static constexpr std::size_t frame_bytes = 32U;
  static constexpr std::uint8_t version = 1U;

  [[nodiscard]] static PeerCompletionReceiptError encode(
      const PeerCompletionReceiptFields& fields,
      PeerCompletionReceiptFrame& output) noexcept {
    output.fill(0U);
    if (!fields.valid()) {
      return PeerCompletionReceiptError::InvalidFields;
    }

    output[0U] = static_cast<std::uint8_t>('V');
    output[1U] = static_cast<std::uint8_t>('C');
    output[2U] = static_cast<std::uint8_t>('R');
    output[3U] = static_cast<std::uint8_t>('C');
    output[4U] = version;
    output[5U] = static_cast<std::uint8_t>(fields.kind);
    output[6U] = expected_count(fields.kind);
    output[7U] = expected_final_index(fields.kind);
    put_u64(output, 8U, fields.session_id);
    put_u32(output, 16U, fields.transfer_tag);
    put_u64(output, 20U, fields.subject_id);
    // 28..29 are reserved and remain zero.
    const std::uint16_t crc = crc16(output);
    output[30U] = static_cast<std::uint8_t>(crc & 0xFFU);
    output[31U] = static_cast<std::uint8_t>((crc >> 8U) & 0xFFU);
    return PeerCompletionReceiptError::None;
  }

  [[nodiscard]] static PeerCompletionReceiptError decode(
      const PeerCompletionReceiptFrame& frame,
      PeerCompletionReceiptFields& output) noexcept {
    output = {};
    const std::uint16_t encoded_crc = static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(frame[30U]) |
        static_cast<std::uint16_t>(
            static_cast<std::uint16_t>(frame[31U]) << 8U));
    if (encoded_crc != crc16(frame)) {
      return PeerCompletionReceiptError::BadCrc;
    }
    if (frame[0U] != static_cast<std::uint8_t>('V') ||
        frame[1U] != static_cast<std::uint8_t>('C') ||
        frame[2U] != static_cast<std::uint8_t>('R') ||
        frame[3U] != static_cast<std::uint8_t>('C')) {
      return PeerCompletionReceiptError::UnknownMagic;
    }
    if (frame[4U] != version) {
      return PeerCompletionReceiptError::UnknownVersion;
    }
    const auto kind = static_cast<PeerCompletionReceiptKind>(frame[5U]);
    if (kind != PeerCompletionReceiptKind::NegotiationResponseConsumed &&
        kind != PeerCompletionReceiptKind::TerminalRecordConsumed) {
      return PeerCompletionReceiptError::UnknownKind;
    }
    if (frame[6U] != expected_count(kind)) {
      return PeerCompletionReceiptError::WrongCount;
    }
    if (frame[7U] != expected_final_index(kind)) {
      return PeerCompletionReceiptError::WrongFinalIndex;
    }
    if (frame[28U] != 0U || frame[29U] != 0U) {
      return PeerCompletionReceiptError::ReservedNonZero;
    }

    PeerCompletionReceiptFields decoded{};
    decoded.kind = kind;
    decoded.session_id = get_u64(frame, 8U);
    decoded.transfer_tag = get_u32(frame, 16U);
    decoded.subject_id = get_u64(frame, 20U);
    if (!decoded.valid()) {
      return PeerCompletionReceiptError::InvalidFields;
    }
    output = decoded;
    return PeerCompletionReceiptError::None;
  }

 private:
  [[nodiscard]] static constexpr std::uint8_t expected_count(
      PeerCompletionReceiptKind kind) noexcept {
    return kind == PeerCompletionReceiptKind::NegotiationResponseConsumed
               ? 1U
               : 8U;
  }

  [[nodiscard]] static constexpr std::uint8_t expected_final_index(
      PeerCompletionReceiptKind kind) noexcept {
    return kind == PeerCompletionReceiptKind::NegotiationResponseConsumed
               ? 0U
               : 7U;
  }

  static void put_u32(PeerCompletionReceiptFrame& frame, std::size_t offset,
                      std::uint32_t value) noexcept {
    for (std::size_t index = 0U; index < 4U; ++index) {
      frame[offset + index] = static_cast<std::uint8_t>(
          (value >> static_cast<std::uint32_t>(8U * index)) & 0xFFU);
    }
  }

  static void put_u64(PeerCompletionReceiptFrame& frame, std::size_t offset,
                      std::uint64_t value) noexcept {
    for (std::size_t index = 0U; index < 8U; ++index) {
      frame[offset + index] = static_cast<std::uint8_t>(
          (value >> static_cast<std::uint64_t>(8U * index)) & 0xFFU);
    }
  }

  [[nodiscard]] static std::uint32_t get_u32(
      const PeerCompletionReceiptFrame& frame, std::size_t offset) noexcept {
    std::uint32_t value = 0U;
    for (std::size_t index = 0U; index < 4U; ++index) {
      value |= static_cast<std::uint32_t>(frame[offset + index])
               << static_cast<std::uint32_t>(8U * index);
    }
    return value;
  }

  [[nodiscard]] static std::uint64_t get_u64(
      const PeerCompletionReceiptFrame& frame, std::size_t offset) noexcept {
    std::uint64_t value = 0U;
    for (std::size_t index = 0U; index < 8U; ++index) {
      value |= static_cast<std::uint64_t>(frame[offset + index])
               << static_cast<std::uint64_t>(8U * index);
    }
    return value;
  }

  [[nodiscard]] static std::uint16_t crc16(
      const PeerCompletionReceiptFrame& frame) noexcept {
    std::uint16_t crc = 0xFFFFU;
    for (std::size_t index = 0U; index < 30U; ++index) {
      crc ^= static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(frame[index]) << 8U);
      for (std::uint8_t bit = 0U; bit < 8U; ++bit) {
        const std::uint16_t shifted = static_cast<std::uint16_t>(crc << 1U);
        crc = (crc & 0x8000U) != 0U
                  ? static_cast<std::uint16_t>(shifted ^ 0x1021U)
                  : shifted;
      }
    }
    return crc;
  }
};

[[nodiscard]] constexpr Direction peer_completion_receipt_direction(
    PeerCompletionReceiptKind kind) noexcept {
  return kind == PeerCompletionReceiptKind::NegotiationResponseConsumed
             ? Direction::Downlink
         : kind == PeerCompletionReceiptKind::TerminalRecordConsumed
             ? Direction::Uplink
             : Direction::Mixed;
}

class PeerCompletionReceiptLedger;

// This proof cannot be manufactured by a scheduler.  Only a ledger that has
// correlated a strict VCRC and the exact final physical transfer can issue it.
class PeerCompletionReceiptProof final {
 public:
  constexpr PeerCompletionReceiptProof() noexcept = default;

  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }
  [[nodiscard]] constexpr PeerCompletionReceiptKind kind() const noexcept {
    return fields_.kind;
  }
  [[nodiscard]] constexpr std::uint64_t session_id() const noexcept {
    return fields_.session_id;
  }
  [[nodiscard]] constexpr std::uint32_t transfer_tag() const noexcept {
    return fields_.transfer_tag;
  }
  [[nodiscard]] constexpr std::uint64_t subject_id() const noexcept {
    return fields_.subject_id;
  }
  [[nodiscard]] constexpr const TransferToken& token() const noexcept {
    return token_;
  }
  [[nodiscard]] constexpr std::uint32_t observed_at_ms() const noexcept {
    return observed_at_ms_;
  }

 private:
  friend class PeerCompletionReceiptLedger;
  constexpr PeerCompletionReceiptProof(
      const PeerCompletionReceiptFields& fields, const TransferToken& token,
      std::uint32_t observed_at_ms) noexcept
      : fields_(fields),
        token_(token),
        observed_at_ms_(observed_at_ms),
        valid_(fields.valid() && token.valid() && token.tail_known() &&
               token.direction() ==
                   peer_completion_receipt_direction(fields.kind) &&
               token.session_id() == fields.session_id) {}

  PeerCompletionReceiptFields fields_{};
  TransferToken token_{};
  std::uint32_t observed_at_ms_{0U};
  bool valid_{false};
};

enum class PeerCompletionReceiptLedgerStatus : std::uint8_t {
  Idle = 0U,
  Armed,
  ReceiptRetained,
  FinalTokenBound,
  ProofReady,
  ProofIssued,
  InvalidArgument,
  InvalidState,
  DecodeRejected,
  EvidenceMismatch,
  Replay,
  Timeout,
  ClockRegression,
  FailClosed,
};

// Direction is derived from the receipt kind, never supplied by the caller:
// kind=1 closes a Downlink negotiation response; kind=2 closes an Uplink
// terminal record. Receipt-first and token-first event delivery are both safe.
// Local AUX is intentionally absent from this opaque peer proof.
class PeerCompletionReceiptLedger final {
 public:
  [[nodiscard]] PeerCompletionReceiptLedgerStatus arm(
      const PeerCompletionReceiptFields& expected, std::uint32_t deadline_ms,
      std::uint32_t now_ms) noexcept {
    if (failed_) {
      return PeerCompletionReceiptLedgerStatus::FailClosed;
    }
    if (!accept_time(now_ms)) {
      return fail(PeerCompletionReceiptLedgerStatus::ClockRegression);
    }
    if (armed_ || !expected.valid() || deadline_ms < now_ms) {
      return fail(PeerCompletionReceiptLedgerStatus::InvalidArgument);
    }
    expected_ = expected;
    deadline_ms_ = deadline_ms;
    armed_ = true;
    return set_status(PeerCompletionReceiptLedgerStatus::Armed);
  }

  [[nodiscard]] PeerCompletionReceiptLedgerStatus bind_final_transfer(
      const TransferToken& token, std::uint32_t now_ms) noexcept {
    const PeerCompletionReceiptLedgerStatus ready = prepare_event(now_ms);
    if (ready != PeerCompletionReceiptLedgerStatus::Armed) {
      return ready;
    }
    if (token_bound_) {
      return fail(PeerCompletionReceiptLedgerStatus::Replay);
    }
    if (!token.valid() || !token.tail_known() ||
        token.direction() != peer_completion_receipt_direction(expected_.kind) ||
        token.session_id() != expected_.session_id) {
      return fail(PeerCompletionReceiptLedgerStatus::EvidenceMismatch);
    }
    final_token_ = token;
    token_bound_ = true;
    if (receipt_received_) {
      return set_status(PeerCompletionReceiptLedgerStatus::ProofReady);
    }
    return set_status(PeerCompletionReceiptLedgerStatus::FinalTokenBound);
  }

  [[nodiscard]] PeerCompletionReceiptLedgerStatus consume_peer_receipt(
      const PeerCompletionReceiptFrame& frame,
      std::uint32_t now_ms) noexcept {
    const PeerCompletionReceiptLedgerStatus ready = prepare_event(now_ms);
    if (ready != PeerCompletionReceiptLedgerStatus::Armed) {
      return ready;
    }
    if (receipt_received_) {
      return fail(PeerCompletionReceiptLedgerStatus::Replay);
    }
    PeerCompletionReceiptFields decoded{};
    if (PeerCompletionReceiptWireCodec::decode(frame, decoded) !=
        PeerCompletionReceiptError::None) {
      return fail(PeerCompletionReceiptLedgerStatus::DecodeRejected);
    }
    if (decoded != expected_) {
      return fail(PeerCompletionReceiptLedgerStatus::EvidenceMismatch);
    }
    receipt_received_ = true;
    receipt_observed_at_ms_ = now_ms;
    if (token_bound_) {
      return set_status(PeerCompletionReceiptLedgerStatus::ProofReady);
    }
    return set_status(PeerCompletionReceiptLedgerStatus::ReceiptRetained);
  }

  [[nodiscard]] PeerCompletionReceiptLedgerStatus take_proof(
      PeerCompletionReceiptProof& output, std::uint32_t now_ms) noexcept {
    output = {};
    const PeerCompletionReceiptLedgerStatus ready = prepare_event(now_ms);
    if (ready != PeerCompletionReceiptLedgerStatus::Armed) {
      return ready;
    }
    if (proof_issued_) {
      return fail(PeerCompletionReceiptLedgerStatus::Replay);
    }
    if (!receipt_received_ || !token_bound_) {
      return fail(PeerCompletionReceiptLedgerStatus::InvalidState);
    }
    output = PeerCompletionReceiptProof(expected_, final_token_,
                                        receipt_observed_at_ms_);
    if (!output.valid()) {
      output = {};
      return fail(PeerCompletionReceiptLedgerStatus::EvidenceMismatch);
    }
    proof_issued_ = true;
    return set_status(PeerCompletionReceiptLedgerStatus::ProofIssued);
  }

  [[nodiscard]] PeerCompletionReceiptLedgerStatus tick(
      std::uint32_t now_ms) noexcept {
    const PeerCompletionReceiptLedgerStatus ready = prepare_event(now_ms);
    if (ready != PeerCompletionReceiptLedgerStatus::Armed) {
      return ready;
    }
    return last_status_;
  }

  [[nodiscard]] constexpr bool proof_ready() const noexcept {
    return !failed_ && armed_ && receipt_received_ && token_bound_ &&
           !proof_issued_;
  }
  [[nodiscard]] constexpr bool receipt_received() const noexcept {
    return receipt_received_;
  }
  [[nodiscard]] constexpr bool token_bound() const noexcept {
    return token_bound_;
  }
  [[nodiscard]] constexpr bool fail_closed() const noexcept { return failed_; }
  [[nodiscard]] constexpr PeerCompletionReceiptLedgerStatus last_status()
      const noexcept {
    return last_status_;
  }

 private:
  [[nodiscard]] PeerCompletionReceiptLedgerStatus prepare_event(
      std::uint32_t now_ms) noexcept {
    if (failed_) {
      return PeerCompletionReceiptLedgerStatus::FailClosed;
    }
    if (!accept_time(now_ms)) {
      return fail(PeerCompletionReceiptLedgerStatus::ClockRegression);
    }
    if (!armed_) {
      return fail(PeerCompletionReceiptLedgerStatus::InvalidState);
    }
    if (now_ms > deadline_ms_) {
      return fail(PeerCompletionReceiptLedgerStatus::Timeout);
    }
    return PeerCompletionReceiptLedgerStatus::Armed;
  }

  [[nodiscard]] bool accept_time(std::uint32_t now_ms) noexcept {
    if (have_last_time_ && now_ms < last_time_ms_) {
      return false;
    }
    have_last_time_ = true;
    last_time_ms_ = now_ms;
    return true;
  }

  [[nodiscard]] PeerCompletionReceiptLedgerStatus set_status(
      PeerCompletionReceiptLedgerStatus status) noexcept {
    last_status_ = status;
    return status;
  }

  [[nodiscard]] PeerCompletionReceiptLedgerStatus fail(
      PeerCompletionReceiptLedgerStatus status) noexcept {
    failed_ = true;
    last_status_ = status;
    return status;
  }

  PeerCompletionReceiptFields expected_{};
  TransferToken final_token_{};
  std::uint32_t deadline_ms_{0U};
  std::uint32_t receipt_observed_at_ms_{0U};
  std::uint32_t last_time_ms_{0U};
  bool armed_{false};
  bool receipt_received_{false};
  bool token_bound_{false};
  bool proof_issued_{false};
  bool have_last_time_{false};
  bool failed_{false};
  PeerCompletionReceiptLedgerStatus last_status_{
      PeerCompletionReceiptLedgerStatus::Idle};
};

enum class PeerCompletionReceiptWriteDisposition : std::uint8_t {
  Rejected = 0U,
  Accepted,
};

struct PeerCompletionReceiptWrite final {
  std::uint32_t action_token{0U};
  std::uint32_t writer_generation{0U};
  PeerCompletionReceiptFrame bytes{};
  std::size_t size{0U};

  [[nodiscard]] constexpr bool valid() const noexcept {
    return action_token != 0U && writer_generation != 0U &&
           size == bytes.size();
  }
};

enum class PeerCompletionReceiptProducerStatus : std::uint8_t {
  Idle = 0U,
  Staged,
  WriteReady,
  RetryRetained,
  Committed,
  Busy,
  InvalidArgument,
  InvalidState,
  PartialWrite,
  ClockRegression,
  FailClosed,
};

// Role-neutral fixed-storage producer: Vehicle uses kind=2 after consuming the
// terminal VCTA set; Ground may use kind=1 after consuming a VCBN response.
// Rejected/zero-progress writes retain byte-identical identity and bytes.
class PeerCompletionReceiptProducer final {
 public:
  [[nodiscard]] PeerCompletionReceiptProducerStatus stage(
      const PeerCompletionReceiptFields& fields,
      std::uint32_t now_ms) noexcept {
    if (failed_) {
      return PeerCompletionReceiptProducerStatus::FailClosed;
    }
    if (!accept_time(now_ms)) {
      return fail(PeerCompletionReceiptProducerStatus::ClockRegression);
    }
    if (staged_ || write_outstanding_ || committed_) {
      return fail(PeerCompletionReceiptProducerStatus::InvalidState);
    }
    if (PeerCompletionReceiptWireCodec::encode(fields, bytes_) !=
        PeerCompletionReceiptError::None) {
      bytes_.fill(0U);
      return fail(PeerCompletionReceiptProducerStatus::InvalidArgument);
    }
    fields_ = fields;
    action_token_ = 1U;
    writer_generation_ = 1U;
    staged_ = true;
    return set_status(PeerCompletionReceiptProducerStatus::Staged);
  }

  [[nodiscard]] PeerCompletionReceiptProducerStatus poll(
      std::uint32_t now_ms, PeerCompletionReceiptWrite& output) noexcept {
    output = {};
    if (failed_) {
      return PeerCompletionReceiptProducerStatus::FailClosed;
    }
    if (!accept_time(now_ms)) {
      return fail(PeerCompletionReceiptProducerStatus::ClockRegression);
    }
    if (!staged_) {
      return fail(PeerCompletionReceiptProducerStatus::InvalidState);
    }
    if (write_outstanding_) {
      return set_status(PeerCompletionReceiptProducerStatus::Busy);
    }
    output.action_token = action_token_;
    output.writer_generation = writer_generation_;
    output.bytes = bytes_;
    output.size = bytes_.size();
    write_outstanding_ = true;
    return set_status(PeerCompletionReceiptProducerStatus::WriteReady);
  }

  [[nodiscard]] PeerCompletionReceiptProducerStatus complete_write(
      std::uint32_t action_token, std::uint32_t writer_generation,
      PeerCompletionReceiptWriteDisposition disposition, std::size_t written,
      std::uint32_t now_ms) noexcept {
    if (failed_) {
      return PeerCompletionReceiptProducerStatus::FailClosed;
    }
    if (!accept_time(now_ms)) {
      return fail(PeerCompletionReceiptProducerStatus::ClockRegression);
    }
    if (!staged_ || !write_outstanding_ || action_token != action_token_ ||
        writer_generation != writer_generation_) {
      return fail(PeerCompletionReceiptProducerStatus::InvalidState);
    }
    if (disposition != PeerCompletionReceiptWriteDisposition::Rejected &&
        disposition != PeerCompletionReceiptWriteDisposition::Accepted) {
      return fail(PeerCompletionReceiptProducerStatus::InvalidArgument);
    }
    write_outstanding_ = false;
    if (written == 0U) {
      return set_status(PeerCompletionReceiptProducerStatus::RetryRetained);
    }
    if (disposition != PeerCompletionReceiptWriteDisposition::Accepted ||
        written != bytes_.size()) {
      return fail(PeerCompletionReceiptProducerStatus::PartialWrite);
    }
    staged_ = false;
    committed_ = true;
    return set_status(PeerCompletionReceiptProducerStatus::Committed);
  }

  [[nodiscard]] constexpr bool committed() const noexcept {
    return committed_;
  }
  [[nodiscard]] constexpr bool fail_closed() const noexcept { return failed_; }
  [[nodiscard]] constexpr const PeerCompletionReceiptFields& fields()
      const noexcept {
    return fields_;
  }
  [[nodiscard]] constexpr PeerCompletionReceiptProducerStatus last_status()
      const noexcept {
    return last_status_;
  }

 private:
  [[nodiscard]] bool accept_time(std::uint32_t now_ms) noexcept {
    if (have_last_time_ && now_ms < last_time_ms_) {
      return false;
    }
    have_last_time_ = true;
    last_time_ms_ = now_ms;
    return true;
  }

  [[nodiscard]] PeerCompletionReceiptProducerStatus set_status(
      PeerCompletionReceiptProducerStatus status) noexcept {
    last_status_ = status;
    return status;
  }

  [[nodiscard]] PeerCompletionReceiptProducerStatus fail(
      PeerCompletionReceiptProducerStatus status) noexcept {
    failed_ = true;
    last_status_ = status;
    return status;
  }

  PeerCompletionReceiptFields fields_{};
  PeerCompletionReceiptFrame bytes_{};
  std::uint32_t action_token_{0U};
  std::uint32_t writer_generation_{0U};
  std::uint32_t last_time_ms_{0U};
  bool staged_{false};
  bool write_outstanding_{false};
  bool committed_{false};
  bool have_last_time_{false};
  bool failed_{false};
  PeerCompletionReceiptProducerStatus last_status_{
      PeerCompletionReceiptProducerStatus::Idle};
};

}  // namespace vc_lora::experimental
