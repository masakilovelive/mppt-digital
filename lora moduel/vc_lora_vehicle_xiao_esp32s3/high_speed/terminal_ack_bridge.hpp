#pragma once

#include <cstdint>

#include "terminal_ack_wire.hpp"
#include "vc_lora/bulk_negotiation_codec.hpp"
#include "vc_lora/bulk_session_controller.hpp"

namespace vc_lora::experimental {

// Fail-closed result for the one-way boundary from a fully validated VCTA
// reassembler into core controller evidence. This adapter performs no radio,
// UART, profile, COM, flash, timing, or physical-coordinator operation.
enum class TerminalAckBridgeStatus : std::uint8_t {
  EvidenceReady = 0U,
  InvalidExpectedIdentity,
  ReassemblerFailed,
  ReassemblerIncomplete,
  RecordUnavailable,
  IdentityMismatch,
  InvalidTerminalEvidence,
  TransferTagDerivationFailed,
};

class TerminalAckEvidenceBridge final {
 public:
  TerminalAckEvidenceBridge() = delete;

  // The raw TerminalAckRecord is intentionally not accepted by this API.
  // Ownership crosses the boundary only through take_record(), exactly once,
  // after TerminalAckReassembler has verified record CRC, identity, accounting,
  // deadlines, batch, revision, and transcript digest against its independently
  // supplied expectation. Every rejection zeroes output. A consumed record is
  // never restored, including identity or transfer-tag rejection.
  [[nodiscard]] static TerminalAckBridgeStatus consume(
      TerminalAckReassembler& reassembler,
      const BulkNegotiationIdentity& expected_identity,
      BulkSessionTerminalEvidence& output) noexcept {
    // Preserve the expectation before clearing output so passing
    // output.identity as the expected identity remains well-defined.
    const BulkNegotiationIdentity expected = expected_identity;
    output = BulkSessionTerminalEvidence{};

    if (!identity_is_valid(expected)) {
      return TerminalAckBridgeStatus::InvalidExpectedIdentity;
    }
    if (reassembler.failed()) {
      return TerminalAckBridgeStatus::ReassemblerFailed;
    }
    if (!reassembler.complete()) {
      return TerminalAckBridgeStatus::ReassemblerIncomplete;
    }

    TerminalAckRecord record{};
    if (!reassembler.take_record(record)) {
      return TerminalAckBridgeStatus::RecordUnavailable;
    }

    const BulkNegotiationIdentity record_identity{
        record.identity.session_id,
        record.identity.stream_id,
        record.identity.lease_id,
        record.identity.ground_request_nonce,
        record.identity.vehicle_terminal_challenge_nonce};
    if (!identities_equal(record_identity, expected)) {
      return TerminalAckBridgeStatus::IdentityMismatch;
    }

    if (!terminal_evidence_is_valid(record)) {
      return TerminalAckBridgeStatus::InvalidTerminalEvidence;
    }

    std::uint32_t transfer_tag = 0U;
    const BulkNegotiationWireStatus tag_status =
        BulkNegotiationWireCodec::derive_transfer_tag(record_identity,
                                                       transfer_tag);
    if (tag_status != BulkNegotiationWireStatus::TransferTagReady ||
        transfer_tag == 0U) {
      return TerminalAckBridgeStatus::TransferTagDerivationFailed;
    }

    BulkSessionTerminalEvidence candidate{};
    candidate.identity = record_identity;
    candidate.transfer_tag = transfer_tag;
    candidate.parameter_count = record.final_parameter_count;
    candidate.parameter_fragment_count = record.wire_chunk_count;
    candidate.raw_parameter_bytes = record.raw_mavlink_bytes;
    candidate.heartbeat_count = record.heartbeat_count;
    candidate.first_heartbeat_gap_ms = record.first_heartbeat_gap_ms;
    candidate.max_heartbeat_gap_ms = record.max_heartbeat_gap_ms;
    candidate.post_heartbeat_gap_ms = record.post_heartbeat_gap_ms;
    candidate.ground_stream_complete = true;
    // VCTA v1's elapsed endpoint is the Ground USB commit of the final complete
    // PARAM frame. Therefore a validated success-only record attests this core
    // semantic; mere RF arrival is not sufficient to create such a record.
    candidate.final_parameter_usb_committed = true;

    output = candidate;
    return TerminalAckBridgeStatus::EvidenceReady;
  }

 private:
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

  [[nodiscard]] static constexpr bool terminal_evidence_is_valid(
      const TerminalAckRecord& record) noexcept {
    return record.record_id != 0U &&
           record.final_parameter_count ==
               TerminalAckWireCodec::required_parameter_count &&
           record.final_global_chunk_ordinal ==
               TerminalAckWireCodec::required_final_global_chunk_ordinal &&
           record.raw_mavlink_bytes ==
               TerminalAckWireCodec::required_raw_mavlink_bytes &&
           record.wire_chunk_count ==
               TerminalAckWireCodec::required_wire_chunk_count &&
           record.wire_bytes == TerminalAckWireCodec::required_wire_bytes &&
           record.request_to_last_parameter_elapsed_ms <=
               TerminalAckWireCodec::parameter_deadline_ms &&
           record.heartbeat_count != 0U &&
           record.last_heartbeat_request_id == record.heartbeat_count &&
           record.first_heartbeat_gap_ms <=
               TerminalAckWireCodec::heartbeat_deadline_ms &&
           record.max_heartbeat_gap_ms <=
               TerminalAckWireCodec::heartbeat_deadline_ms &&
           record.post_heartbeat_gap_ms <=
               TerminalAckWireCodec::heartbeat_deadline_ms;
  }
};

static_assert(TerminalAckWireCodec::required_parameter_count == 932U);
static_assert(TerminalAckWireCodec::required_final_global_chunk_ordinal ==
              1863U);
static_assert(TerminalAckWireCodec::required_raw_mavlink_bytes == 34484U);
static_assert(TerminalAckWireCodec::required_wire_chunk_count == 1864U);
static_assert(TerminalAckWireCodec::required_wire_bytes == 59648U);
static_assert(TerminalAckWireCodec::required_wire_bytes ==
              TerminalAckWireCodec::required_wire_chunk_count * 32U);
static_assert(TerminalAckWireCodec::parameter_deadline_ms == 30000U);
static_assert(TerminalAckWireCodec::heartbeat_deadline_ms == 2500U);
static_assert(TerminalAckWireCodec::required_parameter_count ==
              BulkSessionAccounting::parameter_count);
static_assert(TerminalAckWireCodec::required_wire_chunk_count ==
              BulkSessionAccounting::parameter_fragment_count);
static_assert(TerminalAckWireCodec::required_raw_mavlink_bytes ==
              BulkSessionAccounting::raw_parameter_bytes);
static_assert(TerminalAckWireCodec::heartbeat_deadline_ms ==
              BulkSessionAccounting::heartbeat_deadline_ms);
static_assert(TerminalAckWireCodec::parameter_deadline_ms ==
              BulkSessionAccounting::completion_deadline_ms);

}  // namespace vc_lora::experimental
