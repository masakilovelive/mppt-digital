#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>

#include "terminal_ack_wire.hpp"
#include "vc_lora/bulk_data_codec.hpp"
#include "vc_lora/bulk_heartbeat_sla.hpp"
#include "vc_lora/bulk_negotiation_codec.hpp"
#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/bulk_transcript.hpp"

namespace vc_lora::experimental {

// This experimental producer remains disconnected from both accepted product
// sketches and performs no I/O. The experimental Phase-6 adapter may call it
// only with the concrete ledger/commit owners which observed the transfer;
// callers cannot inject counters or success booleans.
enum class TerminalAckProducerStatus : std::uint8_t {
  BindingReady = 0U,
  RecordReady,
  ExpectedReady,
  InvalidIdentity,
  TransferTagDerivationFailed,
  BindingDerivationFailed,
  IdentityReuse,
  CollisionAlias,
  DecoderNotTerminal,
  DecoderTagMismatch,
  DecoderAccountingMismatch,
  TranscriptNotTerminal,
  TranscriptIdentityMismatch,
  TranscriptTagMismatch,
  TranscriptAccountingMismatch,
  TranscriptDigestMissing,
  SlaNotTerminal,
  SlaTagMismatch,
  SlaDeadlineExceeded,
  HeartbeatMismatch,
  HostCommitNotReady,
  HostCommitMismatch,
  HostCommitConsumed,
  InvalidExpectedEvidence,
  WireEncodeFailed,
};

enum class GroundUsbCommitStatus : std::uint8_t {
  Armed = 0U,
  FinalWriteStaged,
  HostCommitReady,
  Consumed,
  InvalidIdentity,
  TransferTagMismatch,
  IdentityReuse,
  InvalidState,
  InvalidFinalParameter,
  InvalidToken,
  TxLossDetected,
  ClockRegression,
  CompletionDeadlineExceeded,
  Latched,
};

// One-shot owner for the physical Ground USB t1 boundary.  Calling
// complete_host_visible() is the platform adapter's explicit assertion that
// its flush/host-visible completion primitive succeeded; unlike a bool passed
// to the producer, the resulting capability is bound to one identity, tag,
// exact final PARAM_VALUE frame, write token, loss epoch and timestamp, and is
// consumed by GroundTerminalAckProducer exactly once.
class GroundUsbHostCommitOwner final {
 public:
  GroundUsbHostCommitOwner() noexcept = default;
  GroundUsbHostCommitOwner(const GroundUsbHostCommitOwner&) = delete;
  GroundUsbHostCommitOwner& operator=(const GroundUsbHostCommitOwner&) =
      delete;
  GroundUsbHostCommitOwner(GroundUsbHostCommitOwner&&) = delete;
  GroundUsbHostCommitOwner& operator=(GroundUsbHostCommitOwner&&) = delete;

  [[nodiscard]] GroundUsbCommitStatus arm(
      const BulkNegotiationIdentity& identity, std::uint32_t transfer_tag,
      std::uint64_t request_started_ms,
      std::uint64_t tx_loss_epoch) noexcept {
    if (failed_) {
      return GroundUsbCommitStatus::Latched;
    }
    if (state_ != State::Idle && state_ != State::Consumed) {
      return fail(GroundUsbCommitStatus::InvalidState);
    }
    std::uint32_t derived_tag = 0U;
    if (!identity_valid(identity)) {
      return fail(GroundUsbCommitStatus::InvalidIdentity);
    }
    if (BulkNegotiationWireCodec::derive_transfer_tag(identity, derived_tag) !=
            BulkNegotiationWireStatus::TransferTagReady ||
        transfer_tag == 0U || transfer_tag != derived_tag) {
      return fail(GroundUsbCommitStatus::TransferTagMismatch);
    }
    if (have_previous_ &&
        (identities_equal(identity, previous_identity_) ||
         transfer_tag == previous_transfer_tag_)) {
      return fail(GroundUsbCommitStatus::IdentityReuse);
    }
    identity_ = identity;
    transfer_tag_ = transfer_tag;
    request_started_ms_ = request_started_ms;
    tx_loss_epoch_ = tx_loss_epoch;
    write_token_ = 0U;
    write_accepted_ms_ = 0U;
    host_commit_ms_ = 0U;
    state_ = State::Armed;
    last_status_ = GroundUsbCommitStatus::Armed;
    return last_status_;
  }

  [[nodiscard]] GroundUsbCommitStatus stage_final_write(
      const MavlinkFrame& frame, std::uint32_t write_token,
      std::uint64_t tx_loss_epoch,
      std::uint64_t write_accepted_ms) noexcept {
    if (failed_) {
      return GroundUsbCommitStatus::Latched;
    }
    if (state_ != State::Armed) {
      return fail(GroundUsbCommitStatus::InvalidState);
    }
    if (write_token == 0U) {
      return fail(GroundUsbCommitStatus::InvalidToken);
    }
    if (tx_loss_epoch != tx_loss_epoch_) {
      return fail(GroundUsbCommitStatus::TxLossDetected);
    }
    if (write_accepted_ms < request_started_ms_) {
      return fail(GroundUsbCommitStatus::ClockRegression);
    }
    if (!is_exact_final_parameter(frame)) {
      return fail(GroundUsbCommitStatus::InvalidFinalParameter);
    }
    write_token_ = write_token;
    write_accepted_ms_ = write_accepted_ms;
    state_ = State::WriteStaged;
    last_status_ = GroundUsbCommitStatus::FinalWriteStaged;
    return last_status_;
  }

  [[nodiscard]] GroundUsbCommitStatus complete_host_visible(
      std::uint32_t write_token, std::uint64_t tx_loss_epoch,
      std::uint64_t completed_ms) noexcept {
    if (failed_) {
      return GroundUsbCommitStatus::Latched;
    }
    if (state_ != State::WriteStaged) {
      return fail(GroundUsbCommitStatus::InvalidState);
    }
    if (write_token == 0U || write_token != write_token_) {
      return fail(GroundUsbCommitStatus::InvalidToken);
    }
    if (tx_loss_epoch != tx_loss_epoch_) {
      return fail(GroundUsbCommitStatus::TxLossDetected);
    }
    if (completed_ms < write_accepted_ms_ ||
        completed_ms < request_started_ms_) {
      return fail(GroundUsbCommitStatus::ClockRegression);
    }
    if (completed_ms - request_started_ms_ >
        BulkSessionAccounting::completion_deadline_ms) {
      return fail(GroundUsbCommitStatus::CompletionDeadlineExceeded);
    }
    host_commit_ms_ = completed_ms;
    state_ = State::Ready;
    last_status_ = GroundUsbCommitStatus::HostCommitReady;
    return last_status_;
  }

  [[nodiscard]] constexpr bool ready() const noexcept {
    return state_ == State::Ready && !failed_;
  }
  [[nodiscard]] constexpr bool consumed() const noexcept {
    return state_ == State::Consumed;
  }
  [[nodiscard]] constexpr bool fail_closed() const noexcept { return failed_; }
  [[nodiscard]] constexpr GroundUsbCommitStatus last_status() const noexcept {
    return last_status_;
  }

 private:
  friend class GroundTerminalAckProducer;

  enum class State : std::uint8_t {
    Idle = 0U,
    Armed,
    WriteStaged,
    Ready,
    Consumed,
  };

  [[nodiscard]] static constexpr bool identity_valid(
      const BulkNegotiationIdentity& identity) noexcept {
    return identity.session_id != 0U && identity.stream_id != 0U &&
           identity.lease_id != 0U &&
           identity.ground_request_nonce != 0U &&
           identity.vehicle_challenge_nonce != 0U;
  }
  [[nodiscard]] static constexpr bool identities_equal(
      const BulkNegotiationIdentity& left,
      const BulkNegotiationIdentity& right) noexcept {
    return left.session_id == right.session_id &&
           left.stream_id == right.stream_id &&
           left.lease_id == right.lease_id &&
           left.ground_request_nonce == right.ground_request_nonce &&
           left.vehicle_challenge_nonce == right.vehicle_challenge_nonce;
  }
  [[nodiscard]] static bool is_exact_final_parameter(
      const MavlinkFrame& frame) noexcept {
    MavlinkFrame validated{};
    if (frame.size != 37U ||
        validate_mavlink_frame(frame.bytes.data(), frame.size, validated) !=
            MavlinkParseStatus::FrameReady ||
        validated.message_id != 22U || validated.payload_length != 25U) {
      return false;
    }
    const std::uint16_t count = static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(validated.payload_byte_or_zero(4U)) |
        static_cast<std::uint16_t>(
            static_cast<std::uint16_t>(validated.payload_byte_or_zero(5U))
            << 8U));
    const std::uint16_t index = static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(validated.payload_byte_or_zero(6U)) |
        static_cast<std::uint16_t>(
            static_cast<std::uint16_t>(validated.payload_byte_or_zero(7U))
            << 8U));
    return count == BulkSessionAccounting::parameter_count &&
           index + 1U == count;
  }
  [[nodiscard]] constexpr bool matches(
      const BulkNegotiationIdentity& identity, std::uint32_t transfer_tag,
      std::uint64_t request_started_ms,
      std::uint64_t final_parameter_committed_ms) const noexcept {
    return ready() && identities_equal(identity_, identity) &&
           transfer_tag_ == transfer_tag &&
           request_started_ms_ == request_started_ms &&
           host_commit_ms_ == final_parameter_committed_ms;
  }
  [[nodiscard]] GroundUsbCommitStatus consume() noexcept {
    if (!ready()) {
      return GroundUsbCommitStatus::InvalidState;
    }
    previous_identity_ = identity_;
    previous_transfer_tag_ = transfer_tag_;
    have_previous_ = true;
    state_ = State::Consumed;
    last_status_ = GroundUsbCommitStatus::Consumed;
    return last_status_;
  }
  [[nodiscard]] GroundUsbCommitStatus fail(
      GroundUsbCommitStatus status) noexcept {
    failed_ = true;
    last_status_ = status;
    return status;
  }

  State state_{State::Idle};
  BulkNegotiationIdentity identity_{};
  BulkNegotiationIdentity previous_identity_{};
  std::uint32_t transfer_tag_{0U};
  std::uint32_t previous_transfer_tag_{0U};
  std::uint32_t write_token_{0U};
  std::uint64_t request_started_ms_{0U};
  std::uint64_t write_accepted_ms_{0U};
  std::uint64_t host_commit_ms_{0U};
  std::uint64_t tx_loss_epoch_{0U};
  bool have_previous_{false};
  bool failed_{false};
  GroundUsbCommitStatus last_status_{GroundUsbCommitStatus::InvalidState};
};

// Deterministic values independently derived by Ground and Vehicle from the
// complete negotiated identity. They are correlation/replay epochs, not a
// cryptographic authenticator; the full five-value identity and transcript
// digest remain authoritative.
struct TerminalAckSessionBinding final {
  BulkNegotiationIdentity identity{};
  std::uint32_t transfer_tag{0U};
  std::uint64_t record_id{0U};
  std::uint64_t receiver_batch{0U};
  std::uint64_t receiver_revision{0U};
};

class TerminalAckBindingOwner final {
 public:
  TerminalAckBindingOwner() noexcept = default;
  TerminalAckBindingOwner(const TerminalAckBindingOwner&) = delete;
  TerminalAckBindingOwner& operator=(const TerminalAckBindingOwner&) = delete;
  TerminalAckBindingOwner(TerminalAckBindingOwner&&) = delete;
  TerminalAckBindingOwner& operator=(TerminalAckBindingOwner&&) = delete;

  // A long-lived owner rejects immediate identity reuse and every detected
  // alias with its preceding epoch (32-bit transfer tag, folded record tag, or
  // any of the three uint64 binding values). output is zero on every failure.
  [[nodiscard]] TerminalAckProducerStatus bind(
      const BulkNegotiationIdentity& identity,
      TerminalAckSessionBinding& output) noexcept {
    output = TerminalAckSessionBinding{};
    if (!identity_is_valid(identity)) {
      return TerminalAckProducerStatus::InvalidIdentity;
    }
    if (have_previous_ && identities_equal(identity, previous_.identity)) {
      return TerminalAckProducerStatus::IdentityReuse;
    }

    TerminalAckSessionBinding candidate{};
    candidate.identity = identity;
    const BulkNegotiationWireStatus tag_status =
        BulkNegotiationWireCodec::derive_transfer_tag(
            identity, candidate.transfer_tag);
    if (tag_status != BulkNegotiationWireStatus::TransferTagReady ||
        candidate.transfer_tag == 0U) {
      return TerminalAckProducerStatus::TransferTagDerivationFailed;
    }

    if (!derive_value(kRecordEpochDomain, identity,
                      0x8000000000000001ULL, candidate.record_id) ||
        !derive_value(kReceiverBatchDomain, identity,
                      0x8000000000000002ULL,
                      candidate.receiver_batch) ||
        !derive_value(kReceiverRevisionDomain, identity,
                      0x8000000000000003ULL,
                      candidate.receiver_revision)) {
      return TerminalAckProducerStatus::BindingDerivationFailed;
    }

    // A zero XOR-fold would erase the fragment assembly hint. Canonically
    // toggle one high bit; this preserves nonzero record_id and yields a
    // nonzero folded tag without accepting a caller-provided fallback.
    if (TerminalAckWireCodec::record_tag(candidate.record_id) == 0U) {
      candidate.record_id ^= 0x8000000000000000ULL;
    }
    if (!binding_values_are_distinct(candidate) ||
        (have_previous_ && bindings_alias(candidate, previous_))) {
      return TerminalAckProducerStatus::CollisionAlias;
    }

    previous_ = candidate;
    have_previous_ = true;
    output = candidate;
    return TerminalAckProducerStatus::BindingReady;
  }

 private:
  static constexpr char kRecordEpochDomain[] =
      "VC-VCTA-RECORD-EPOCH\0v1";
  static constexpr char kReceiverBatchDomain[] =
      "VC-VCTA-RECEIVER-BATCH\0v1";
  static constexpr char kReceiverRevisionDomain[] =
      "VC-VCTA-RECEIVER-REVISION\0v1";

  [[nodiscard]] static constexpr bool identity_is_valid(
      const BulkNegotiationIdentity& identity) noexcept {
    return identity.session_id != 0U && identity.stream_id != 0U &&
           identity.lease_id != 0U &&
           identity.ground_request_nonce != 0U &&
           identity.vehicle_challenge_nonce != 0U;
  }

  [[nodiscard]] static constexpr bool identities_equal(
      const BulkNegotiationIdentity& left,
      const BulkNegotiationIdentity& right) noexcept {
    return left.session_id == right.session_id &&
           left.stream_id == right.stream_id &&
           left.lease_id == right.lease_id &&
           left.ground_request_nonce == right.ground_request_nonce &&
           left.vehicle_challenge_nonce == right.vehicle_challenge_nonce;
  }

  static void put_u64(std::array<std::uint8_t, 40U>& bytes,
                      std::size_t offset, std::uint64_t value) noexcept {
    for (std::size_t index = 0U; index < 8U; ++index) {
      bytes[offset + index] = static_cast<std::uint8_t>(
          (value >> static_cast<unsigned int>(index * 8U)) & 0xFFU);
    }
  }

  [[nodiscard]] static std::array<std::uint8_t, 40U>
  canonical_identity(const BulkNegotiationIdentity& identity) noexcept {
    std::array<std::uint8_t, 40U> bytes{};
    put_u64(bytes, 0U, identity.session_id);
    put_u64(bytes, 8U, identity.stream_id);
    put_u64(bytes, 16U, identity.lease_id);
    put_u64(bytes, 24U, identity.ground_request_nonce);
    put_u64(bytes, 32U, identity.vehicle_challenge_nonce);
    return bytes;
  }

  template <std::size_t DomainSize>
  [[nodiscard]] static bool derive_value(
      const char (&domain)[DomainSize],
      const BulkNegotiationIdentity& identity, std::uint64_t zero_fallback,
      std::uint64_t& output) noexcept {
    const std::array<std::uint8_t, 40U> bytes =
        canonical_identity(identity);
    Sha256Accumulator sha{};
    BulkTranscriptDigest digest{};
    if (sha.update(reinterpret_cast<const std::uint8_t*>(domain),
                   DomainSize - 1U) != Sha256Status::Accepted ||
        sha.update(bytes.data(), bytes.size()) != Sha256Status::Accepted ||
        sha.finish(digest) != Sha256Status::DigestReady) {
      return false;
    }
    std::uint64_t value = 0U;
    for (std::size_t index = 0U; index < 8U; ++index) {
      value |= static_cast<std::uint64_t>(digest[index]) <<
               static_cast<unsigned int>(index * 8U);
    }
    // SHA-256 output zero is mapped by a role-specific canonical constant;
    // later distinctness/previous-epoch checks reject any resulting alias.
    output = value == 0U ? zero_fallback : value;
    return true;
  }

  [[nodiscard]] static constexpr bool binding_values_are_distinct(
      const TerminalAckSessionBinding& binding) noexcept {
    return binding.record_id != 0U && binding.receiver_batch != 0U &&
           binding.receiver_revision != 0U &&
           binding.record_id != binding.receiver_batch &&
           binding.record_id != binding.receiver_revision &&
           binding.receiver_batch != binding.receiver_revision &&
           TerminalAckWireCodec::record_tag(binding.record_id) != 0U;
  }

  [[nodiscard]] static constexpr bool bindings_alias(
      const TerminalAckSessionBinding& left,
      const TerminalAckSessionBinding& right) noexcept {
    if (left.transfer_tag == right.transfer_tag ||
        TerminalAckWireCodec::record_tag(left.record_id) ==
            TerminalAckWireCodec::record_tag(right.record_id)) {
      return true;
    }
    const std::array<std::uint64_t, 3U> left_values{{
        left.record_id, left.receiver_batch, left.receiver_revision}};
    const std::array<std::uint64_t, 3U> right_values{{
        right.record_id, right.receiver_batch, right.receiver_revision}};
    for (const std::uint64_t left_value : left_values) {
      for (const std::uint64_t right_value : right_values) {
        if (left_value == right_value) {
          return true;
        }
      }
    }
    return false;
  }

  TerminalAckSessionBinding previous_{};
  bool have_previous_{false};
};

class GroundTerminalAckProducer final {
 public:
  GroundTerminalAckProducer() noexcept = default;
  GroundTerminalAckProducer(const GroundTerminalAckProducer&) = delete;
  GroundTerminalAckProducer& operator=(const GroundTerminalAckProducer&) =
      delete;
  GroundTerminalAckProducer(GroundTerminalAckProducer&&) = delete;
  GroundTerminalAckProducer& operator=(GroundTerminalAckProducer&&) = delete;

  [[nodiscard]] TerminalAckProducerStatus produce(
      const BulkDataStreamDecoder& decoder,
      const BulkTranscriptLedger& transcript,
      const BulkHeartbeatSlaLedger& sla,
      GroundUsbHostCommitOwner& host_commit,
      const BulkNegotiationIdentity& negotiated_identity,
      TerminalAckRecord& record_output,
      TerminalAckFragments& fragments_output) noexcept {
    record_output = TerminalAckRecord{};
    fragments_output = TerminalAckFragments{};

    std::uint32_t transfer_tag = 0U;
    const TerminalAckProducerStatus identity_status =
        validate_identity_and_tag(negotiated_identity, transfer_tag);
    if (identity_status != TerminalAckProducerStatus::BindingReady) {
      return identity_status;
    }
    if (decoder.latched() || !decoder.complete() || !decoder.sealed()) {
      return TerminalAckProducerStatus::DecoderNotTerminal;
    }
    if (decoder.expected_transfer_tag() != transfer_tag) {
      return TerminalAckProducerStatus::DecoderTagMismatch;
    }
    if (decoder.expected_parameter_count() !=
            TerminalAckWireCodec::required_parameter_count ||
        decoder.parameter_count() !=
            TerminalAckWireCodec::required_parameter_count ||
        decoder.parameter_fragment_count() !=
            TerminalAckWireCodec::required_wire_chunk_count ||
        decoder.raw_parameter_bytes() !=
            TerminalAckWireCodec::required_raw_mavlink_bytes) {
      return TerminalAckProducerStatus::DecoderAccountingMismatch;
    }
    constexpr std::uint32_t chunks_per_frame = 2U;
    constexpr std::uint32_t fixed_parameter_chunks =
        TerminalAckWireCodec::required_wire_chunk_count;
    constexpr std::uint32_t maximum_heartbeat_count =
        (std::numeric_limits<std::uint32_t>::max() -
         fixed_parameter_chunks) /
        chunks_per_frame;
    if (decoder.heartbeat_count() > maximum_heartbeat_count) {
      return TerminalAckProducerStatus::DecoderAccountingMismatch;
    }
    const std::uint32_t decoder_expected_chunks =
        fixed_parameter_chunks +
        decoder.heartbeat_count() * chunks_per_frame;
    if (decoder.total_fragment_count() != decoder_expected_chunks ||
        decoder.next_wire_ordinal() != decoder_expected_chunks) {
      return TerminalAckProducerStatus::DecoderAccountingMismatch;
    }

    const BulkTranscriptEvidence transcript_evidence =
        transcript.evidence();
    if (!transcript.sealed() || transcript.latched() || transcript.active() ||
        !transcript_evidence.owner_sealed) {
      return TerminalAckProducerStatus::TranscriptNotTerminal;
    }
    if (!identities_equal(transcript_evidence.identity,
                          negotiated_identity)) {
      return TerminalAckProducerStatus::TranscriptIdentityMismatch;
    }
    if (transcript_evidence.transfer_tag != transfer_tag) {
      return TerminalAckProducerStatus::TranscriptTagMismatch;
    }
    if (transcript_evidence.parameter_count !=
            TerminalAckWireCodec::required_parameter_count ||
        transcript_evidence.raw_parameter_bytes !=
            TerminalAckWireCodec::required_raw_mavlink_bytes ||
        transcript_evidence.heartbeat_count == 0U ||
        transcript_evidence.last_heartbeat_request_id !=
            transcript_evidence.heartbeat_count) {
      return TerminalAckProducerStatus::TranscriptAccountingMismatch;
    }
    if (!digest_is_nonzero(transcript_evidence.digest)) {
      return TerminalAckProducerStatus::TranscriptDigestMissing;
    }
    if (transcript_evidence.heartbeat_count > maximum_heartbeat_count) {
      return TerminalAckProducerStatus::DecoderAccountingMismatch;
    }
    const std::uint32_t transcript_expected_chunks =
        fixed_parameter_chunks +
        transcript_evidence.heartbeat_count * chunks_per_frame;
    if (decoder.total_fragment_count() != transcript_expected_chunks ||
        decoder.next_wire_ordinal() != transcript_expected_chunks) {
      return TerminalAckProducerStatus::DecoderAccountingMismatch;
    }

    const BulkHeartbeatSlaEvidence sla_evidence = sla.evidence();
    if (!sla.sealed() || sla.fail_closed() || !sla_evidence.complete) {
      return TerminalAckProducerStatus::SlaNotTerminal;
    }
    if (sla_evidence.transfer_tag != transfer_tag) {
      return TerminalAckProducerStatus::SlaTagMismatch;
    }
    if (sla_evidence.request_to_last_parameter_ms >
            TerminalAckWireCodec::parameter_deadline_ms ||
        sla_evidence.first_heartbeat_gap_ms >
            TerminalAckWireCodec::heartbeat_deadline_ms ||
        sla_evidence.max_heartbeat_gap_ms >
            TerminalAckWireCodec::heartbeat_deadline_ms ||
        sla_evidence.post_heartbeat_gap_ms >
            TerminalAckWireCodec::heartbeat_deadline_ms) {
      return TerminalAckProducerStatus::SlaDeadlineExceeded;
    }
    if (decoder.heartbeat_count() == 0U ||
        decoder.heartbeat_count() != transcript_evidence.heartbeat_count ||
        decoder.heartbeat_count() != sla_evidence.heartbeat_count ||
        sla_evidence.last_heartbeat_request_id !=
            sla_evidence.heartbeat_count) {
      return TerminalAckProducerStatus::HeartbeatMismatch;
    }
    if (!host_commit.ready()) {
      return TerminalAckProducerStatus::HostCommitNotReady;
    }
    if (sla_evidence.final_parameter_committed_ms <
            sla_evidence.request_started_ms ||
        sla_evidence.final_parameter_committed_ms -
                sla_evidence.request_started_ms !=
            sla_evidence.request_to_last_parameter_ms ||
        !host_commit.matches(negotiated_identity, transfer_tag,
                             sla_evidence.request_started_ms,
                             sla_evidence.final_parameter_committed_ms)) {
      return TerminalAckProducerStatus::HostCommitMismatch;
    }

    TerminalAckSessionBinding binding{};
    const TerminalAckProducerStatus binding_status =
        binding_owner_.bind(negotiated_identity, binding);
    if (binding_status != TerminalAckProducerStatus::BindingReady) {
      return binding_status;
    }
    if (binding.transfer_tag != transfer_tag) {
      return TerminalAckProducerStatus::CollisionAlias;
    }

    TerminalAckRecord candidate{};
    candidate.record_id = binding.record_id;
    candidate.identity = to_terminal_identity(negotiated_identity);
    candidate.final_parameter_count =
        TerminalAckWireCodec::required_parameter_count;
    candidate.final_global_chunk_ordinal =
        TerminalAckWireCodec::required_final_global_chunk_ordinal;
    candidate.raw_mavlink_bytes =
        TerminalAckWireCodec::required_raw_mavlink_bytes;
    candidate.wire_chunk_count =
        TerminalAckWireCodec::required_wire_chunk_count;
    candidate.wire_bytes = TerminalAckWireCodec::required_wire_bytes;
    candidate.request_to_last_parameter_elapsed_ms =
        sla_evidence.request_to_last_parameter_ms;
    candidate.heartbeat_count = sla_evidence.heartbeat_count;
    candidate.last_heartbeat_request_id =
        sla_evidence.last_heartbeat_request_id;
    candidate.first_heartbeat_gap_ms =
        sla_evidence.first_heartbeat_gap_ms;
    candidate.max_heartbeat_gap_ms = sla_evidence.max_heartbeat_gap_ms;
    candidate.post_heartbeat_gap_ms = sla_evidence.post_heartbeat_gap_ms;
    candidate.receiver_batch = binding.receiver_batch;
    candidate.receiver_revision = binding.receiver_revision;
    candidate.transcript_digest = transcript_evidence.digest;

    TerminalAckFragments candidate_fragments{};
    if (TerminalAckWireCodec::encode(candidate, candidate_fragments) !=
        TerminalAckError::None) {
      return TerminalAckProducerStatus::WireEncodeFailed;
    }
    if (host_commit.consume() != GroundUsbCommitStatus::Consumed) {
      return TerminalAckProducerStatus::HostCommitConsumed;
    }
    record_output = candidate;
    fragments_output = candidate_fragments;
    return TerminalAckProducerStatus::RecordReady;
  }

 private:
  friend class VehicleTerminalAckExpectedFactory;

  [[nodiscard]] static constexpr bool identities_equal(
      const BulkNegotiationIdentity& left,
      const BulkNegotiationIdentity& right) noexcept {
    return left.session_id == right.session_id &&
           left.stream_id == right.stream_id &&
           left.lease_id == right.lease_id &&
           left.ground_request_nonce == right.ground_request_nonce &&
           left.vehicle_challenge_nonce == right.vehicle_challenge_nonce;
  }

  [[nodiscard]] static TerminalAckProducerStatus validate_identity_and_tag(
      const BulkNegotiationIdentity& identity,
      std::uint32_t& transfer_tag) noexcept {
    transfer_tag = 0U;
    if (identity.session_id == 0U || identity.stream_id == 0U ||
        identity.lease_id == 0U || identity.ground_request_nonce == 0U ||
        identity.vehicle_challenge_nonce == 0U) {
      return TerminalAckProducerStatus::InvalidIdentity;
    }
    const BulkNegotiationWireStatus status =
        BulkNegotiationWireCodec::derive_transfer_tag(identity, transfer_tag);
    return status == BulkNegotiationWireStatus::TransferTagReady &&
                   transfer_tag != 0U
               ? TerminalAckProducerStatus::BindingReady
               : TerminalAckProducerStatus::TransferTagDerivationFailed;
  }

  [[nodiscard]] static constexpr TerminalAckIdentity to_terminal_identity(
      const BulkNegotiationIdentity& identity) noexcept {
    return TerminalAckIdentity{
        identity.session_id,
        identity.stream_id,
        identity.lease_id,
        identity.ground_request_nonce,
        identity.vehicle_challenge_nonce};
  }

  [[nodiscard]] static bool digest_is_nonzero(
      const BulkTranscriptDigest& digest) noexcept {
    std::uint8_t aggregate = 0U;
    for (const std::uint8_t byte : digest) {
      aggregate = static_cast<std::uint8_t>(aggregate | byte);
    }
    return aggregate != 0U;
  }

  TerminalAckBindingOwner binding_owner_{};
};

class VehicleTerminalAckExpectedFactory final {
 public:
  VehicleTerminalAckExpectedFactory() noexcept = default;
  VehicleTerminalAckExpectedFactory(
      const VehicleTerminalAckExpectedFactory&) = delete;
  VehicleTerminalAckExpectedFactory& operator=(
      const VehicleTerminalAckExpectedFactory&) = delete;
  VehicleTerminalAckExpectedFactory(
      VehicleTerminalAckExpectedFactory&&) = delete;
  VehicleTerminalAckExpectedFactory& operator=(
      VehicleTerminalAckExpectedFactory&&) = delete;

  [[nodiscard]] TerminalAckProducerStatus make_expected(
      const BulkNegotiationIdentity& negotiated_identity,
      const BulkTranscriptLedger& sender_transcript,
      TerminalAckExpectedEvidence& output) noexcept {
    output = TerminalAckExpectedEvidence{};
    std::uint32_t transfer_tag = 0U;
    const TerminalAckProducerStatus identity_status =
        GroundTerminalAckProducer::validate_identity_and_tag(
            negotiated_identity, transfer_tag);
    if (identity_status != TerminalAckProducerStatus::BindingReady) {
      return identity_status;
    }

    const BulkTranscriptEvidence evidence = sender_transcript.evidence();
    if (!sender_transcript.sealed() || sender_transcript.latched() ||
        sender_transcript.active() || !evidence.owner_sealed) {
      return TerminalAckProducerStatus::TranscriptNotTerminal;
    }
    if (!GroundTerminalAckProducer::identities_equal(
            evidence.identity, negotiated_identity)) {
      return TerminalAckProducerStatus::TranscriptIdentityMismatch;
    }
    if (evidence.transfer_tag != transfer_tag) {
      return TerminalAckProducerStatus::TranscriptTagMismatch;
    }
    if (evidence.parameter_count !=
            TerminalAckWireCodec::required_parameter_count ||
        evidence.raw_parameter_bytes !=
            TerminalAckWireCodec::required_raw_mavlink_bytes ||
        evidence.heartbeat_count == 0U ||
        evidence.last_heartbeat_request_id != evidence.heartbeat_count) {
      return TerminalAckProducerStatus::TranscriptAccountingMismatch;
    }
    if (!GroundTerminalAckProducer::digest_is_nonzero(evidence.digest)) {
      return TerminalAckProducerStatus::TranscriptDigestMissing;
    }

    TerminalAckSessionBinding binding{};
    const TerminalAckProducerStatus binding_status =
        binding_owner_.bind(negotiated_identity, binding);
    if (binding_status != TerminalAckProducerStatus::BindingReady) {
      return binding_status;
    }
    if (binding.transfer_tag != transfer_tag) {
      return TerminalAckProducerStatus::CollisionAlias;
    }

    TerminalAckExpectedEvidence candidate{};
    candidate.expected_record_id = binding.record_id;
    candidate.identity =
        GroundTerminalAckProducer::to_terminal_identity(negotiated_identity);
    candidate.final_parameter_count =
        TerminalAckWireCodec::required_parameter_count;
    candidate.final_global_chunk_ordinal =
        TerminalAckWireCodec::required_final_global_chunk_ordinal;
    candidate.raw_mavlink_bytes =
        TerminalAckWireCodec::required_raw_mavlink_bytes;
    candidate.wire_chunk_count =
        TerminalAckWireCodec::required_wire_chunk_count;
    candidate.wire_bytes = TerminalAckWireCodec::required_wire_bytes;
    candidate.maximum_request_to_last_parameter_elapsed_ms =
        TerminalAckWireCodec::parameter_deadline_ms;
    candidate.heartbeat_count = evidence.heartbeat_count;
    candidate.last_heartbeat_request_id =
        evidence.last_heartbeat_request_id;
    candidate.maximum_heartbeat_gap_ms =
        TerminalAckWireCodec::heartbeat_deadline_ms;
    candidate.receiver_batch = binding.receiver_batch;
    candidate.receiver_revision = binding.receiver_revision;
    candidate.transcript_digest = evidence.digest;
    if (!TerminalAckWireCodec::expected_evidence_is_valid(candidate)) {
      return TerminalAckProducerStatus::InvalidExpectedEvidence;
    }
    output = candidate;
    return TerminalAckProducerStatus::ExpectedReady;
  }

 private:
  TerminalAckBindingOwner binding_owner_{};
};

static_assert(TerminalAckWireCodec::required_parameter_count == 932U);
static_assert(TerminalAckWireCodec::required_wire_chunk_count == 1864U);
static_assert(TerminalAckWireCodec::required_raw_mavlink_bytes == 34484U);
static_assert(TerminalAckWireCodec::required_wire_bytes == 59648U);
static_assert(TerminalAckWireCodec::required_final_global_chunk_ordinal ==
              1863U);
static_assert(TerminalAckWireCodec::parameter_deadline_ms == 30000U);
static_assert(TerminalAckWireCodec::heartbeat_deadline_ms == 2500U);

}  // namespace vc_lora::experimental
