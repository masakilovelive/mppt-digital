#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

#include "../../../firmware/high_speed/phase6_high_speed_radio_session.hpp"
#include "../../../firmware/high_speed/peer_completion_receipt.hpp"
#include "test_support.hpp"
#include "vc_lora/bulk_session_controller.hpp"

namespace vc_lora::test {
namespace {

using experimental::AdmissionResult;
using experimental::Direction;
using ::vc_lora::HighSpeedActionType;
using experimental::HighSpeedPhase6Output;
using experimental::HighSpeedPhase6OutputType;
using experimental::Phase6HighSpeedRadioSession;
using experimental::Phase6HighSpeedRadioSessionStatus;
using experimental::Phase6HighSpeedRadioWrite;
using experimental::Phase6HighSpeedStreamLimits;
using experimental::Phase6RadioWriterArbiter;
using experimental::PeerCompletionReceiptError;
using experimental::PeerCompletionReceiptFields;
using experimental::PeerCompletionReceiptFrame;
using experimental::PeerCompletionReceiptKind;
using experimental::PeerCompletionReceiptLedger;
using experimental::PeerCompletionReceiptLedgerStatus;
using experimental::PeerCompletionReceiptProof;
using experimental::PeerCompletionReceiptProducer;
using experimental::PeerCompletionReceiptProducerStatus;
using experimental::PeerCompletionReceiptWireCodec;
using experimental::PeerCompletionReceiptWrite;
using experimental::PeerCompletionReceiptWriteDisposition;
using experimental::TransferToken;
constexpr PeerCompletionReceiptFields kTerminalFields{
    PeerCompletionReceiptKind::TerminalRecordConsumed,
    0x1122334455667788ULL, 0x91A2B3C4U,
    0x8877665544332211ULL};
constexpr PeerCompletionReceiptFields kNegotiationFields{
    PeerCompletionReceiptKind::NegotiationResponseConsumed,
    0x1122334455667788ULL, 0x91A2B3C4U,
    0x1020304050607080ULL};
constexpr Phase6HighSpeedStreamLimits kRadioLimits{8U, 256U, 32U};

std::uint16_t test_crc16(const PeerCompletionReceiptFrame& frame) noexcept {
  std::uint16_t crc = 0xFFFFU;
  for (std::size_t index = 0U; index < 30U; ++index) {
    crc ^= static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(frame[index]) << 8U);
    for (std::uint8_t bit = 0U; bit < 8U; ++bit) {
      const auto shifted = static_cast<std::uint16_t>(crc << 1U);
      crc = (crc & 0x8000U) != 0U
                ? static_cast<std::uint16_t>(shifted ^ 0x1021U)
                : shifted;
    }
  }
  return crc;
}

void refresh_crc(PeerCompletionReceiptFrame& frame) noexcept {
  const std::uint16_t crc = test_crc16(frame);
  frame[30U] = static_cast<std::uint8_t>(crc & 0xFFU);
  frame[31U] = static_cast<std::uint8_t>((crc >> 8U) & 0xFFU);
}

bool frame_zero(const PeerCompletionReceiptFrame& frame) noexcept {
  for (const std::uint8_t byte : frame) {
    if (byte != 0U) {
      return false;
    }
  }
  return true;
}

bool same_write(const PeerCompletionReceiptWrite& left,
                const PeerCompletionReceiptWrite& right) noexcept {
  return left.action_token == right.action_token &&
         left.writer_generation == right.writer_generation &&
         left.size == right.size && left.bytes == right.bytes;
}

TransferToken make_transfer(std::uint64_t session_id, Direction direction,
                            std::uint32_t now_ms = 15U) noexcept {
  experimental::E220UartAdmissionGate gate(session_id);
  gate.observe_aux(0U, true);
  if (gate.assess(now_ms, direction, 32U) != AdmissionResult::Ready) {
    return {};
  }
  const experimental::WriteCommitOutcome outcome =
      gate.commit_write(now_ms, direction, 32U, 32U);
  return outcome.token;
}

TransferToken make_later_transfer(std::uint64_t session_id,
                                  Direction direction) noexcept {
  experimental::E220UartAdmissionGate gate(session_id);
  gate.observe_aux(0U, true);
  if (gate.assess(15U, direction, 32U) != AdmissionResult::Ready ||
      gate.commit_write(15U, direction, 32U, 32U).result !=
          experimental::WriteCommitResult::Committed ||
      gate.assess(200U, direction, 32U) != AdmissionResult::Ready) {
    return {};
  }
  return gate.commit_write(200U, direction, 32U, 32U).token;
}

HighSpeedPhase6Output final_radio_action(std::uint32_t token,
                                         std::uint32_t generation,
                                         std::uint8_t seed) noexcept {
  HighSpeedPhase6Output output{};
  output.type = HighSpeedPhase6OutputType::RadioWrite;
  output.semantic = HighSpeedActionType::SendTerminalEvidence;
  output.token = token;
  output.writer_generation = generation;
  output.size = 32U;
  for (std::size_t index = 0U; index < output.size; ++index) {
    output.bytes[index] =
        static_cast<std::uint8_t>(seed + static_cast<std::uint8_t>(index));
  }
  return output;
}

bool stage_final_radio_write(Phase6HighSpeedRadioSession& session,
                             Direction direction = Direction::Uplink,
                             std::uint32_t now_ms = 15U) noexcept {
  Phase6HighSpeedRadioWrite write{};
  return session.begin(0x7001U, direction, kRadioLimits, 0U) ==
             Phase6HighSpeedRadioSessionStatus::StreamStarted &&
         session.observe_aux(0U, true) ==
             Phase6HighSpeedRadioSessionStatus::StreamActive &&
         session.retain_adapter_action(
             final_radio_action(1U, 1U, 0x20U), true, 1U) ==
             Phase6HighSpeedRadioSessionStatus::ActionRetained &&
         session.assess_write(now_ms, write) ==
             Phase6HighSpeedRadioSessionStatus::WriteReady &&
         session.complete_uart(write.action_token, write.writer_generation,
                               write.wire_ordinal, write.size, now_ms) ==
             Phase6HighSpeedRadioSessionStatus::WriteCommitted;
}

bool release_final_credit(Phase6HighSpeedRadioSession& session,
                          std::uint32_t low_ms) noexcept {
  const TransferToken token = session.last_transfer_token();
  return session.observe_aux(low_ms, false) ==
             Phase6HighSpeedRadioSessionStatus::StreamActive &&
         session.observe_aux(low_ms + 1U, true) ==
             Phase6HighSpeedRadioSessionStatus::StreamActive &&
         (session.release_buffer_credit_from_local_aux(low_ms + 16U, token) ==
              Phase6HighSpeedRadioSessionStatus::BufferCreditReleased ||
          session.last_status() ==
              Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired);
}

bool make_peer_proof(const PeerCompletionReceiptFields& fields,
                     const TransferToken& token, std::uint32_t receipt_ms,
                     PeerCompletionReceiptProof& proof) noexcept {
  PeerCompletionReceiptLedger ledger{};
  PeerCompletionReceiptFrame frame{};
  if (PeerCompletionReceiptWireCodec::encode(fields, frame) !=
          PeerCompletionReceiptError::None ||
      ledger.arm(fields, 500U, 0U) !=
          PeerCompletionReceiptLedgerStatus::Armed ||
      ledger.bind_final_transfer(token, 15U) !=
          PeerCompletionReceiptLedgerStatus::FinalTokenBound ||
      ledger.consume_peer_receipt(frame, receipt_ms) !=
          PeerCompletionReceiptLedgerStatus::ProofReady ||
      ledger.take_proof(proof, receipt_ms) !=
          PeerCompletionReceiptLedgerStatus::ProofIssued) {
    return false;
  }
  return proof.valid() && proof.token() == token;
}

void test_wire_exact_layout_and_round_trip(TestReport& report) {
  PeerCompletionReceiptFrame frame{};
  PeerCompletionReceiptFields decoded{};
  report.check(PeerCompletionReceiptWireCodec::encode(kTerminalFields,
                                                       frame) ==
                       PeerCompletionReceiptError::None,
               "valid terminal VCRC fields did not encode");
  report.check(frame[0U] == 'V' && frame[1U] == 'C' && frame[2U] == 'R' &&
                   frame[3U] == 'C' && frame[4U] == 1U &&
                   frame[5U] == 2U && frame[6U] == 8U &&
                   frame[7U] == 7U &&
                   frame[8U] == 0x88U && frame[9U] == 0x77U &&
                   frame[10U] == 0x66U && frame[11U] == 0x55U &&
                   frame[12U] == 0x44U && frame[13U] == 0x33U &&
                   frame[14U] == 0x22U && frame[15U] == 0x11U &&
                   frame[16U] == 0xC4U && frame[17U] == 0xB3U &&
                   frame[18U] == 0xA2U && frame[19U] == 0x91U &&
                   frame[20U] == 0x11U && frame[21U] == 0x22U &&
                   frame[22U] == 0x33U && frame[23U] == 0x44U &&
                   frame[24U] == 0x55U && frame[25U] == 0x66U &&
                   frame[26U] == 0x77U && frame[27U] == 0x88U &&
                   frame[28U] == 0U &&
                   frame[29U] == 0U &&
                   static_cast<std::uint16_t>(frame[30U]) ==
                       static_cast<std::uint16_t>(test_crc16(frame) & 0xFFU) &&
                   static_cast<std::uint16_t>(frame[31U]) ==
                       static_cast<std::uint16_t>(test_crc16(frame) >> 8U),
               "terminal VCRC exact 32-byte layout or CRC drifted");
  report.check(PeerCompletionReceiptWireCodec::decode(frame, decoded) ==
                       PeerCompletionReceiptError::None &&
                   decoded == kTerminalFields,
               "terminal VCRC round trip lost correlation fields");

  PeerCompletionReceiptFrame duplicate{};
  report.check(PeerCompletionReceiptWireCodec::encode(kTerminalFields,
                                                       duplicate) ==
                       PeerCompletionReceiptError::None &&
                   duplicate == frame,
               "VCRC encoding is not deterministic");

  PeerCompletionReceiptFrame negotiation{};
  PeerCompletionReceiptFields negotiation_decoded{};
  report.check(PeerCompletionReceiptWireCodec::encode(kNegotiationFields,
                                                       negotiation) ==
                       PeerCompletionReceiptError::None &&
                   negotiation[5U] == 1U && negotiation[6U] == 1U &&
                   negotiation[7U] == 0U &&
                   PeerCompletionReceiptWireCodec::decode(
                       negotiation, negotiation_decoded) ==
                       PeerCompletionReceiptError::None &&
                   negotiation_decoded == kNegotiationFields,
               "negotiation VCRC exact kind/count/index contract drifted");

  PeerCompletionReceiptProducer producer{};
  PeerCompletionReceiptWrite first{};
  PeerCompletionReceiptWrite retry_rejected{};
  PeerCompletionReceiptWrite retry_zero{};
  report.check(producer.stage(kTerminalFields, 0U) ==
                       PeerCompletionReceiptProducerStatus::Staged &&
                   producer.poll(1U, first) ==
                       PeerCompletionReceiptProducerStatus::WriteReady &&
                   first.valid(),
               "fixed-storage VCRC write did not stage");
  report.check(producer.complete_write(
                   first.action_token, first.writer_generation,
                   PeerCompletionReceiptWriteDisposition::Rejected, 0U, 1U) ==
                       PeerCompletionReceiptProducerStatus::RetryRetained &&
                   producer.poll(2U, retry_rejected) ==
                       PeerCompletionReceiptProducerStatus::WriteReady &&
                   same_write(first, retry_rejected),
               "rejected VCRC write did not retain byte-identical retry");
  report.check(producer.complete_write(
                   retry_rejected.action_token,
                   retry_rejected.writer_generation,
                   PeerCompletionReceiptWriteDisposition::Accepted, 0U, 2U) ==
                       PeerCompletionReceiptProducerStatus::RetryRetained &&
                   producer.poll(3U, retry_zero) ==
                       PeerCompletionReceiptProducerStatus::WriteReady &&
                   same_write(first, retry_zero),
               "zero-byte VCRC write did not retain byte-identical retry");
  report.check(producer.complete_write(
                   retry_zero.action_token, retry_zero.writer_generation,
                   PeerCompletionReceiptWriteDisposition::Accepted,
                   retry_zero.size, 3U) ==
                       PeerCompletionReceiptProducerStatus::Committed &&
                   producer.committed() && !producer.fail_closed(),
               "full VCRC write did not commit exactly once");
}

void test_wire_strict_rejection_and_partial_fail(TestReport& report) {
  PeerCompletionReceiptFrame baseline{};
  report.check(PeerCompletionReceiptWireCodec::encode(kTerminalFields,
                                                       baseline) ==
                   PeerCompletionReceiptError::None,
               "strict VCRC test could not encode baseline");

  const std::array<std::size_t, 7U> strict_offsets{{
      0U, 4U, 5U, 6U, 7U, 28U, 29U}};
  for (const std::size_t offset : strict_offsets) {
    PeerCompletionReceiptFrame corrupt = baseline;
    corrupt[offset] ^= 0x01U;
    refresh_crc(corrupt);
    PeerCompletionReceiptFields decoded{kTerminalFields};
    report.check(PeerCompletionReceiptWireCodec::decode(corrupt, decoded) !=
                         PeerCompletionReceiptError::None &&
                     !decoded.valid(),
                 "semantic VCRC corruption with valid CRC was accepted");
  }
  PeerCompletionReceiptFrame bad_crc = baseline;
  bad_crc[20U] ^= 0x80U;
  PeerCompletionReceiptFields decoded{kTerminalFields};
  report.check(PeerCompletionReceiptWireCodec::decode(bad_crc, decoded) ==
                       PeerCompletionReceiptError::BadCrc &&
                   !decoded.valid(),
               "VCRC payload corruption did not fail CRC and zero output");

  for (const PeerCompletionReceiptFields invalid :
       std::array<PeerCompletionReceiptFields, 4U>{{
           {PeerCompletionReceiptKind::TerminalRecordConsumed, 0U,
            kTerminalFields.transfer_tag, kTerminalFields.subject_id},
           {PeerCompletionReceiptKind::TerminalRecordConsumed,
            kTerminalFields.session_id, 0U, kTerminalFields.subject_id},
           {PeerCompletionReceiptKind::TerminalRecordConsumed,
            kTerminalFields.session_id, kTerminalFields.transfer_tag, 0U},
           {PeerCompletionReceiptKind::None, kTerminalFields.session_id,
            kTerminalFields.transfer_tag, kTerminalFields.subject_id}}}) {
    PeerCompletionReceiptFrame output{};
    output.fill(0xA5U);
    report.check(PeerCompletionReceiptWireCodec::encode(invalid, output) ==
                         PeerCompletionReceiptError::InvalidFields &&
                     frame_zero(output),
                 "invalid VCRC fields did not fail closed with zero output");
  }

  PeerCompletionReceiptProducer producer{};
  PeerCompletionReceiptWrite write{};
  report.check(producer.stage(kNegotiationFields, 10U) ==
                       PeerCompletionReceiptProducerStatus::Staged &&
                   producer.poll(11U, write) ==
                       PeerCompletionReceiptProducerStatus::WriteReady &&
                   producer.complete_write(
                       write.action_token, write.writer_generation,
                       PeerCompletionReceiptWriteDisposition::Accepted, 17U,
                       12U) ==
                       PeerCompletionReceiptProducerStatus::PartialWrite &&
                   producer.fail_closed(),
               "partial VCRC write did not fail closed");
}

void test_ledger_ack_first_and_token_first(TestReport& report) {
  PeerCompletionReceiptFrame frame{};
  report.check(PeerCompletionReceiptWireCodec::encode(kTerminalFields,
                                                       frame) ==
                   PeerCompletionReceiptError::None,
               "ledger test could not encode terminal VCRC");
  const TransferToken token =
      make_transfer(kTerminalFields.session_id, Direction::Uplink);
  report.check(token.valid(), "ledger test token was invalid");

  {
    PeerCompletionReceiptLedger ledger{};
    PeerCompletionReceiptProof proof{};
    report.check(ledger.arm(kTerminalFields, 100U, 0U) ==
                         PeerCompletionReceiptLedgerStatus::Armed &&
                     ledger.consume_peer_receipt(frame, 10U) ==
                         PeerCompletionReceiptLedgerStatus::ReceiptRetained &&
                     !ledger.proof_ready() && ledger.receipt_received() &&
                     ledger.bind_final_transfer(token, 20U) ==
                         PeerCompletionReceiptLedgerStatus::ProofReady &&
                     ledger.take_proof(proof, 20U) ==
                         PeerCompletionReceiptLedgerStatus::ProofIssued &&
                     proof.valid() && proof.token() == token &&
                     proof.kind() ==
                         PeerCompletionReceiptKind::TerminalRecordConsumed &&
                     proof.session_id() == kTerminalFields.session_id &&
                     proof.transfer_tag() == kTerminalFields.transfer_tag &&
                     proof.subject_id() == kTerminalFields.subject_id &&
                     proof.observed_at_ms() == 10U,
                  "receipt-first ledger path did not issue exact opaque proof");
  }
  {
    PeerCompletionReceiptLedger ledger{};
    PeerCompletionReceiptProof proof{};
    report.check(ledger.arm(kTerminalFields, 100U, 0U) ==
                         PeerCompletionReceiptLedgerStatus::Armed &&
                     ledger.bind_final_transfer(token, 5U) ==
                         PeerCompletionReceiptLedgerStatus::FinalTokenBound &&
                     ledger.consume_peer_receipt(frame, 10U) ==
                         PeerCompletionReceiptLedgerStatus::ProofReady &&
                     ledger.take_proof(proof, 11U) ==
                         PeerCompletionReceiptLedgerStatus::ProofIssued &&
                     proof.valid() && proof.token() == token,
                 "token-first ledger path did not issue exact opaque proof");
  }
}

void test_ledger_mismatch_replay_and_clock_fail(TestReport& report) {
  const TransferToken token =
      make_transfer(kTerminalFields.session_id, Direction::Uplink);
  PeerCompletionReceiptFrame frame{};
  (void)PeerCompletionReceiptWireCodec::encode(kTerminalFields, frame);
  {
    PeerCompletionReceiptLedger ledger{};
    PeerCompletionReceiptFields wrong = kTerminalFields;
    wrong.transfer_tag ^= 1U;
    PeerCompletionReceiptFrame wrong_frame{};
    (void)PeerCompletionReceiptWireCodec::encode(wrong, wrong_frame);
    report.check(ledger.arm(kTerminalFields, 100U, 0U) ==
                         PeerCompletionReceiptLedgerStatus::Armed &&
                     ledger.bind_final_transfer(token, 5U) ==
                         PeerCompletionReceiptLedgerStatus::FinalTokenBound &&
                     ledger.consume_peer_receipt(wrong_frame, 10U) ==
                         PeerCompletionReceiptLedgerStatus::EvidenceMismatch &&
                     ledger.fail_closed(),
                  "wrong-tag peer receipt did not fail closed");
  }
  {
    PeerCompletionReceiptLedger ledger{};
    report.check(ledger.arm(kTerminalFields, 100U, 0U) ==
                         PeerCompletionReceiptLedgerStatus::Armed &&
                     ledger.consume_peer_receipt(frame, 10U) ==
                         PeerCompletionReceiptLedgerStatus::ReceiptRetained &&
                     ledger.consume_peer_receipt(frame, 11U) ==
                         PeerCompletionReceiptLedgerStatus::Replay &&
                     ledger.fail_closed(),
                  "duplicate peer receipt did not latch replay failure");
  }
  {
    PeerCompletionReceiptLedger ledger{};
    report.check(ledger.arm(kTerminalFields, 100U, 0U) ==
                         PeerCompletionReceiptLedgerStatus::Armed &&
                     ledger.bind_final_transfer(token, 5U) ==
                         PeerCompletionReceiptLedgerStatus::FinalTokenBound &&
                     ledger.bind_final_transfer(token, 6U) ==
                         PeerCompletionReceiptLedgerStatus::Replay &&
                     ledger.fail_closed(),
                 "duplicate final VCTA token bind did not fail closed");
  }
  {
    PeerCompletionReceiptLedger ledger{};
    report.check(ledger.arm(kTerminalFields, 100U, 10U) ==
                         PeerCompletionReceiptLedgerStatus::Armed &&
                     ledger.tick(9U) ==
                         PeerCompletionReceiptLedgerStatus::ClockRegression &&
                     ledger.fail_closed(),
                  "ledger clock regression did not fail closed");
  }
  {
    PeerCompletionReceiptLedger ledger{};
    const TransferToken downlink =
        make_transfer(kTerminalFields.session_id, Direction::Downlink);
    report.check(ledger.arm(kTerminalFields, 100U, 0U) ==
                         PeerCompletionReceiptLedgerStatus::Armed &&
                     ledger.bind_final_transfer(downlink, 15U) ==
                         PeerCompletionReceiptLedgerStatus::EvidenceMismatch &&
                     ledger.fail_closed(),
                  "non-uplink final VCTA token did not fail closed");
  }
  {
    PeerCompletionReceiptLedger ledger{};
    const TransferToken uplink =
        make_transfer(kNegotiationFields.session_id, Direction::Uplink);
    report.check(ledger.arm(kNegotiationFields, 100U, 0U) ==
                         PeerCompletionReceiptLedgerStatus::Armed &&
                     ledger.bind_final_transfer(uplink, 15U) ==
                         PeerCompletionReceiptLedgerStatus::EvidenceMismatch &&
                     ledger.fail_closed(),
                 "kind=1 negotiation receipt accepted an Uplink token");
  }
  {
    PeerCompletionReceiptLedger ledger{};
    PeerCompletionReceiptFrame negotiation{};
    (void)PeerCompletionReceiptWireCodec::encode(kNegotiationFields,
                                                 negotiation);
    report.check(ledger.arm(kTerminalFields, 100U, 0U) ==
                         PeerCompletionReceiptLedgerStatus::Armed &&
                     ledger.consume_peer_receipt(negotiation, 10U) ==
                         PeerCompletionReceiptLedgerStatus::EvidenceMismatch &&
                     ledger.fail_closed(),
                 "different-kind VCRC matched terminal ledger");
  }
  {
    PeerCompletionReceiptLedger ledger{};
    PeerCompletionReceiptFields invalid = kTerminalFields;
    invalid.session_id = 0U;
    report.check(ledger.arm(invalid, 100U, 0U) ==
                         PeerCompletionReceiptLedgerStatus::InvalidArgument &&
                     ledger.fail_closed(),
                 "zero session ledger arm did not fail closed");
  }
}

void test_peer_ack_before_and_after_aux_credit(TestReport& report) {
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, kTerminalFields.session_id);
    PeerCompletionReceiptProof proof{};
    report.check(stage_final_radio_write(session) &&
                     make_peer_proof(kTerminalFields,
                                     session.last_transfer_token(), 16U,
                                     proof),
                  "receipt-first radio setup failed");
    report.check(session.complete_stream_from_peer_receipt(proof, 16U) ==
                         Phase6HighSpeedRadioSessionStatus::AwaitBufferCredit &&
                     arbiter.high_speed_stream_active() &&
                     !arbiter.explicit_restore_required(),
                  "peer receipt bypassed mandatory local AUX buffer credit");
    report.check(release_final_credit(session, 17U) &&
                     session.last_status() ==
                         Phase6HighSpeedRadioSessionStatus::
                             ExplicitRestoreRequired &&
                     arbiter.explicit_restore_required() &&
                     session.restore_standard(true, 34U) ==
                         Phase6HighSpeedRadioSessionStatus::StandardRestored,
                  "receipt-first path did not complete on later exact credit");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, kTerminalFields.session_id);
    PeerCompletionReceiptProof proof{};
    report.check(stage_final_radio_write(session) &&
                     release_final_credit(session, 16U) &&
                     arbiter.high_speed_stream_active() &&
                     !arbiter.explicit_restore_required(),
                  "credit-first setup completed without a peer receipt");
    report.check(make_peer_proof(kTerminalFields,
                                 session.last_transfer_token(), 33U, proof) &&
                     session.complete_stream_from_peer_receipt(proof, 33U) ==
                         Phase6HighSpeedRadioSessionStatus::
                             ExplicitRestoreRequired &&
                     session.restore_standard(true, 34U) ==
                         Phase6HighSpeedRadioSessionStatus::StandardRestored,
                  "credit-first path did not complete on exact peer receipt");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter,
                                        kNegotiationFields.session_id);
    PeerCompletionReceiptProof proof{};
    report.check(stage_final_radio_write(session, Direction::Downlink) &&
                     make_peer_proof(kNegotiationFields,
                                     session.last_transfer_token(), 16U,
                                     proof) &&
                     proof.kind() ==
                         PeerCompletionReceiptKind::
                             NegotiationResponseConsumed &&
                     session.complete_stream_from_peer_receipt(proof, 16U) ==
                         Phase6HighSpeedRadioSessionStatus::AwaitBufferCredit &&
                     release_final_credit(session, 17U) &&
                     session.last_status() ==
                         Phase6HighSpeedRadioSessionStatus::
                             ExplicitRestoreRequired &&
                     session.restore_standard(true, 34U) ==
                         Phase6HighSpeedRadioSessionStatus::StandardRestored,
                 "kind=1 Downlink VCBN receipt did not close exact stream");
  }
}

void test_aux_alone_and_wrong_proof_never_complete(TestReport& report) {
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, kTerminalFields.session_id);
    report.check(stage_final_radio_write(session) &&
                     release_final_credit(session, 16U) &&
                     arbiter.high_speed_stream_active() &&
                     !arbiter.explicit_restore_required() &&
                     !arbiter.can_poll_standard(),
                 "AUX-only buffer credit was treated as remote completion");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, kTerminalFields.session_id);
    const TransferToken wrong =
        make_later_transfer(kTerminalFields.session_id, Direction::Uplink);
    PeerCompletionReceiptProof wrong_proof{};
    report.check(stage_final_radio_write(session) &&
                     release_final_credit(session, 16U) &&
                     make_peer_proof(kTerminalFields, wrong, 33U,
                                     wrong_proof) &&
                     session.complete_stream_from_peer_receipt(
                         wrong_proof, 33U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed(),
                 "peer proof for a different TransferToken was accepted");
  }
}

void test_missing_ack_timeout(TestReport& report) {
  PeerCompletionReceiptLedger ledger{};
  const TransferToken token =
      make_transfer(kTerminalFields.session_id, Direction::Uplink);
  PeerCompletionReceiptProof proof{};
  report.check(ledger.arm(kTerminalFields, 100U, 0U) ==
                       PeerCompletionReceiptLedgerStatus::Armed &&
                   ledger.bind_final_transfer(token, 15U) ==
                       PeerCompletionReceiptLedgerStatus::FinalTokenBound &&
                   ledger.tick(100U) ==
                       PeerCompletionReceiptLedgerStatus::FinalTokenBound &&
                   ledger.tick(101U) ==
                       PeerCompletionReceiptLedgerStatus::Timeout &&
                   ledger.fail_closed() &&
                   ledger.take_proof(proof, 101U) ==
                       PeerCompletionReceiptLedgerStatus::FailClosed &&
                   !proof.valid(),
               "missing peer receipt did not fail closed after deadline");
}

void test_product_receipt_deadline_boundary(TestReport& report) {
  static_assert(BulkSessionTiming::peer_completion_receipt_timeout_ms ==
                1300U);
  PeerCompletionReceiptFrame frame{};
  const TransferToken token =
      make_transfer(kTerminalFields.session_id, Direction::Uplink);
  report.check(PeerCompletionReceiptWireCodec::encode(kTerminalFields,
                                                       frame) ==
                       PeerCompletionReceiptError::None &&
                   token.valid(),
               "VCRC deadline fixture setup failed");

  PeerCompletionReceiptLedger on_time{};
  PeerCompletionReceiptProof proof{};
  report.check(
      on_time.arm(kTerminalFields,
                  static_cast<std::uint32_t>(
                      BulkSessionTiming::peer_completion_receipt_timeout_ms),
                  0U) == PeerCompletionReceiptLedgerStatus::Armed &&
          on_time.bind_final_transfer(token, 0U) ==
              PeerCompletionReceiptLedgerStatus::FinalTokenBound &&
          on_time.consume_peer_receipt(
              frame, static_cast<std::uint32_t>(
                         BulkSessionTiming::
                             peer_completion_receipt_timeout_ms)) ==
              PeerCompletionReceiptLedgerStatus::ProofReady &&
          on_time.take_proof(
              proof, static_cast<std::uint32_t>(
                         BulkSessionTiming::
                             peer_completion_receipt_timeout_ms)) ==
              PeerCompletionReceiptLedgerStatus::ProofIssued &&
          proof.valid(),
      "VCRC receipt at the exact 1300-ms boundary was rejected");

  PeerCompletionReceiptLedger late{};
  report.check(
      late.arm(kTerminalFields,
               static_cast<std::uint32_t>(
                   BulkSessionTiming::peer_completion_receipt_timeout_ms),
               0U) == PeerCompletionReceiptLedgerStatus::Armed &&
          late.bind_final_transfer(token, 0U) ==
              PeerCompletionReceiptLedgerStatus::FinalTokenBound &&
          late.tick(static_cast<std::uint32_t>(
                        BulkSessionTiming::
                            peer_completion_receipt_timeout_ms +
                        1U)) == PeerCompletionReceiptLedgerStatus::Timeout &&
          late.fail_closed(),
      "VCRC receipt ledger did not fail closed at 1301 ms");
}

}  // namespace

TestReport run_peer_completion_receipt_test(const std::string& test_id,
                                            std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-PEER-COMPLETION-WIRE-001") {
    test_wire_exact_layout_and_round_trip(report);
  } else if (test_id == "UT-PEER-COMPLETION-WIRE-002") {
    test_wire_strict_rejection_and_partial_fail(report);
  } else if (test_id == "UT-PEER-COMPLETION-LEDGER-001") {
    test_ledger_ack_first_and_token_first(report);
  } else if (test_id == "UT-PEER-COMPLETION-LEDGER-002") {
    test_ledger_mismatch_replay_and_clock_fail(report);
  } else if (test_id == "UT-HS-PEER-COMPLETION-001") {
    test_peer_ack_before_and_after_aux_credit(report);
  } else if (test_id == "UT-HS-VCRC-AUX-NOT-PROOF-001") {
    test_aux_alone_and_wrong_proof_never_complete(report);
  } else if (test_id == "UT-HS-VCRC-MISSING-TIMEOUT-001") {
    test_missing_ack_timeout(report);
  } else if (test_id == "UT-PEER-COMPLETION-DEADLINE-001") {
    test_product_receipt_deadline_boundary(report);
  } else {
    report.check(false, "unknown peer completion receipt test ID");
  }

  report.trace.record({0U, "host", "PEER_COMPLETION_RECEIPT", 0U,
                       report.passed ? "PASS" : "FAIL", true,
                       0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
