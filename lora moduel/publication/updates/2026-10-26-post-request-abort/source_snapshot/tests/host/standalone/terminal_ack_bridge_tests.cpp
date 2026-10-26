#include "../../../firmware/high_speed/terminal_ack_bridge.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <type_traits>

namespace {

using vc_lora::BulkNegotiationIdentity;
using vc_lora::BulkNegotiationWireCodec;
using vc_lora::BulkNegotiationWireStatus;
using vc_lora::BulkSessionTerminalEvidence;
using vc_lora::experimental::TerminalAckBridgeStatus;
using vc_lora::experimental::TerminalAckEvidenceBridge;
using vc_lora::experimental::TerminalAckError;
using vc_lora::experimental::TerminalAckExpectedEvidence;
using vc_lora::experimental::TerminalAckFragment;
using vc_lora::experimental::TerminalAckFragments;
using vc_lora::experimental::TerminalAckIdentity;
using vc_lora::experimental::TerminalAckReassembler;
using vc_lora::experimental::TerminalAckRecord;
using vc_lora::experimental::TerminalAckWireCodec;

using ConsumeSignature = TerminalAckBridgeStatus (*)(
    TerminalAckReassembler&, const BulkNegotiationIdentity&,
    BulkSessionTerminalEvidence&) noexcept;

// The bridge deliberately exposes no overload which accepts an unverified
// TerminalAckRecord. Evidence can only cross the boundary through the
// reassembler's one-shot take_record() ownership path.
static_assert(std::is_same_v<decltype(&TerminalAckEvidenceBridge::consume),
                             ConsumeSignature>);
static_assert(!std::is_copy_constructible_v<TerminalAckReassembler>);
static_assert(!std::is_move_constructible_v<TerminalAckReassembler>);

int failures = 0;
int checks = 0;

void check(bool condition, const char* expression, int line) {
  ++checks;
  if (!condition) {
    std::cerr << "FAIL line " << line << ": " << expression << '\n';
    ++failures;
  }
}

#define CHECK(expression) check((expression), #expression, __LINE__)

TerminalAckRecord sample_record(std::uint64_t record_id = 17ULL) {
  TerminalAckRecord record{};
  record.record_id = record_id;
  record.identity = TerminalAckIdentity{
      0x0102030405060708ULL,
      0x1112131415161718ULL,
      0x2122232425262728ULL,
      0x3132333435363738ULL,
      0x4142434445464748ULL};
  record.final_parameter_count = 932U;
  record.final_global_chunk_ordinal = 1863U;
  record.raw_mavlink_bytes = 34484U;
  record.wire_chunk_count = 1864U;
  record.wire_bytes = 59648U;
  record.request_to_last_parameter_elapsed_ms = 30000U;
  record.heartbeat_count = 23U;
  record.last_heartbeat_request_id = 23U;
  record.first_heartbeat_gap_ms = 2500U;
  record.max_heartbeat_gap_ms = 2500U;
  record.post_heartbeat_gap_ms = 2500U;
  record.receiver_batch = 0x5152535455565758ULL;
  record.receiver_revision = 0x6162636465666768ULL;
  for (std::size_t index = 0U; index < record.transcript_digest.size();
       ++index) {
    record.transcript_digest[index] =
        static_cast<std::uint8_t>(0x80U + index);
  }
  return record;
}

TerminalAckExpectedEvidence expected_for(const TerminalAckRecord& record) {
  TerminalAckExpectedEvidence expected{};
  expected.expected_record_id = record.record_id;
  expected.identity = record.identity;
  expected.final_parameter_count = 932U;
  expected.final_global_chunk_ordinal = 1863U;
  expected.raw_mavlink_bytes = 34484U;
  expected.wire_chunk_count = 1864U;
  expected.wire_bytes = 59648U;
  expected.maximum_request_to_last_parameter_elapsed_ms = 30000U;
  expected.heartbeat_count = record.heartbeat_count;
  expected.last_heartbeat_request_id = record.last_heartbeat_request_id;
  expected.maximum_heartbeat_gap_ms = 2500U;
  expected.receiver_batch = record.receiver_batch;
  expected.receiver_revision = record.receiver_revision;
  expected.transcript_digest = record.transcript_digest;
  return expected;
}

TerminalAckFragments encode(const TerminalAckRecord& record) {
  TerminalAckFragments fragments{};
  CHECK(TerminalAckWireCodec::encode(record, fragments) ==
        TerminalAckError::None);
  return fragments;
}

TerminalAckError push_all(TerminalAckReassembler& reassembler,
                          const TerminalAckFragments& fragments,
                          std::size_t first = 0U) {
  TerminalAckError result = TerminalAckError::None;
  for (std::size_t index = first; index < fragments.size(); ++index) {
    result = reassembler.push(fragments[index]);
    if (result != TerminalAckError::None) {
      break;
    }
  }
  return result;
}

BulkNegotiationIdentity core_identity(const TerminalAckIdentity& identity) {
  return BulkNegotiationIdentity{
      identity.session_id,
      identity.stream_id,
      identity.lease_id,
      identity.ground_request_nonce,
      identity.vehicle_terminal_challenge_nonce};
}

void dirty(BulkSessionTerminalEvidence& output) {
  output.identity = BulkNegotiationIdentity{1U, 2U, 3U, 4U, 5U};
  output.transfer_tag = 6U;
  output.parameter_count = 7U;
  output.parameter_fragment_count = 8U;
  output.raw_parameter_bytes = 9U;
  output.heartbeat_count = 10U;
  output.first_heartbeat_gap_ms = 11U;
  output.max_heartbeat_gap_ms = 12U;
  output.post_heartbeat_gap_ms = 13U;
  output.ground_stream_complete = true;
  output.final_parameter_usb_committed = true;
}

bool is_zero(const BulkSessionTerminalEvidence& output) {
  return output.identity.session_id == 0U &&
         output.identity.stream_id == 0U &&
         output.identity.lease_id == 0U &&
         output.identity.ground_request_nonce == 0U &&
         output.identity.vehicle_challenge_nonce == 0U &&
         output.transfer_tag == 0U && output.parameter_count == 0U &&
         output.parameter_fragment_count == 0U &&
         output.raw_parameter_bytes == 0U && output.heartbeat_count == 0U &&
         output.first_heartbeat_gap_ms == 0U &&
         output.max_heartbeat_gap_ms == 0U &&
         output.post_heartbeat_gap_ms == 0U &&
         !output.ground_stream_complete &&
         !output.final_parameter_usb_committed;
}

void check_identity(const BulkNegotiationIdentity& actual,
                    const TerminalAckIdentity& expected) {
  CHECK(actual.session_id == expected.session_id);
  CHECK(actual.stream_id == expected.stream_id);
  CHECK(actual.lease_id == expected.lease_id);
  CHECK(actual.ground_request_nonce == expected.ground_request_nonce);
  CHECK(actual.vehicle_challenge_nonce ==
        expected.vehicle_terminal_challenge_nonce);
}

void test_complete_validated_record_maps_once_at_inclusive_boundaries() {
  const TerminalAckRecord record = sample_record();
  const TerminalAckFragments fragments = encode(record);
  TerminalAckReassembler reassembler(expected_for(record));
  CHECK(push_all(reassembler, fragments) == TerminalAckError::None);
  CHECK(reassembler.complete());

  const BulkNegotiationIdentity identity = core_identity(record.identity);
  std::uint32_t expected_tag = 0U;
  CHECK(BulkNegotiationWireCodec::derive_transfer_tag(identity, expected_tag) ==
        BulkNegotiationWireStatus::TransferTagReady);
  CHECK(expected_tag != 0U);

  BulkSessionTerminalEvidence output{};
  dirty(output);
  CHECK(TerminalAckEvidenceBridge::consume(reassembler, identity, output) ==
        TerminalAckBridgeStatus::EvidenceReady);
  check_identity(output.identity, record.identity);
  CHECK(output.transfer_tag == expected_tag);
  CHECK(output.parameter_count == 932U);
  CHECK(output.parameter_fragment_count == 1864U);
  CHECK(output.raw_parameter_bytes == 34484U);
  CHECK(output.heartbeat_count == record.heartbeat_count);
  CHECK(output.first_heartbeat_gap_ms == 2500U);
  CHECK(output.max_heartbeat_gap_ms == 2500U);
  CHECK(output.post_heartbeat_gap_ms == 2500U);
  CHECK(output.ground_stream_complete);
  CHECK(output.final_parameter_usb_committed);

  dirty(output);
  CHECK(TerminalAckEvidenceBridge::consume(reassembler, identity, output) ==
        TerminalAckBridgeStatus::RecordUnavailable);
  CHECK(is_zero(output));
}

void test_zero_expected_identity_rejects_without_consuming() {
  const TerminalAckRecord record = sample_record(18ULL);
  const TerminalAckFragments fragments = encode(record);
  TerminalAckReassembler reassembler(expected_for(record));
  CHECK(push_all(reassembler, fragments) == TerminalAckError::None);

  BulkSessionTerminalEvidence output{};
  dirty(output);
  CHECK(TerminalAckEvidenceBridge::consume(
            reassembler, BulkNegotiationIdentity{}, output) ==
        TerminalAckBridgeStatus::InvalidExpectedIdentity);
  CHECK(is_zero(output));

  const BulkNegotiationIdentity identity = core_identity(record.identity);
  CHECK(TerminalAckEvidenceBridge::consume(reassembler, identity, output) ==
        TerminalAckBridgeStatus::EvidenceReady);
}

void test_expected_identity_may_alias_zeroed_output() {
  const TerminalAckRecord record = sample_record(180ULL);
  const TerminalAckFragments fragments = encode(record);
  TerminalAckReassembler reassembler(expected_for(record));
  CHECK(push_all(reassembler, fragments) == TerminalAckError::None);

  BulkSessionTerminalEvidence output{};
  dirty(output);
  output.identity = core_identity(record.identity);
  CHECK(TerminalAckEvidenceBridge::consume(reassembler, output.identity,
                                           output) ==
        TerminalAckBridgeStatus::EvidenceReady);
  check_identity(output.identity, record.identity);
}

void test_wrong_expected_identity_consumes_and_fails_closed() {
  for (std::size_t field = 0U; field < 5U; ++field) {
    const TerminalAckRecord record =
        sample_record(19ULL + static_cast<std::uint64_t>(field));
    const TerminalAckFragments fragments = encode(record);
    TerminalAckReassembler reassembler(expected_for(record));
    CHECK(push_all(reassembler, fragments) == TerminalAckError::None);

    const BulkNegotiationIdentity correct = core_identity(record.identity);
    BulkNegotiationIdentity wrong = correct;
    switch (field) {
      case 0U:
        ++wrong.session_id;
        break;
      case 1U:
        ++wrong.stream_id;
        break;
      case 2U:
        ++wrong.lease_id;
        break;
      case 3U:
        ++wrong.ground_request_nonce;
        break;
      default:
        ++wrong.vehicle_challenge_nonce;
        break;
    }
    BulkSessionTerminalEvidence output{};
    dirty(output);
    CHECK(TerminalAckEvidenceBridge::consume(reassembler, wrong, output) ==
          TerminalAckBridgeStatus::IdentityMismatch);
    CHECK(is_zero(output));

    dirty(output);
    CHECK(TerminalAckEvidenceBridge::consume(reassembler, correct, output) ==
          TerminalAckBridgeStatus::RecordUnavailable);
    CHECK(is_zero(output));
  }
}

void test_partial_reassembler_rejects_without_consuming() {
  const TerminalAckRecord record = sample_record(20ULL);
  const TerminalAckFragments fragments = encode(record);
  TerminalAckReassembler reassembler(expected_for(record));
  CHECK(reassembler.push(fragments[0]) == TerminalAckError::None);

  const BulkNegotiationIdentity identity = core_identity(record.identity);
  BulkSessionTerminalEvidence output{};
  dirty(output);
  CHECK(TerminalAckEvidenceBridge::consume(reassembler, identity, output) ==
        TerminalAckBridgeStatus::ReassemblerIncomplete);
  CHECK(is_zero(output));

  CHECK(push_all(reassembler, fragments, 1U) == TerminalAckError::None);
  CHECK(TerminalAckEvidenceBridge::consume(reassembler, identity, output) ==
        TerminalAckBridgeStatus::EvidenceReady);
}

void test_failed_reassembler_rejects_and_zeroes_output() {
  const TerminalAckRecord record = sample_record(21ULL);
  TerminalAckFragments fragments = encode(record);
  fragments[0][0] = static_cast<std::uint8_t>('X');
  TerminalAckReassembler reassembler(expected_for(record));
  CHECK(reassembler.push(fragments[0]) == TerminalAckError::UnknownMagic);
  CHECK(reassembler.failed());

  BulkSessionTerminalEvidence output{};
  dirty(output);
  CHECK(TerminalAckEvidenceBridge::consume(
            reassembler, core_identity(record.identity), output) ==
        TerminalAckBridgeStatus::ReassemblerFailed);
  CHECK(is_zero(output));
}

void test_zero_derived_tag_fails_closed_after_one_shot_take() {
  TerminalAckRecord record = sample_record(22ULL);
  // Independent CRC-32C residue construction for the canonical five-value
  // transfer identity. All five identity members remain nonzero while the
  // derived transfer tag is exactly zero.
  record.identity.vehicle_terminal_challenge_nonce =
      0x32AF69D145464748ULL;
  const TerminalAckFragments fragments = encode(record);
  TerminalAckReassembler reassembler(expected_for(record));
  CHECK(push_all(reassembler, fragments) == TerminalAckError::None);

  const BulkNegotiationIdentity identity = core_identity(record.identity);
  std::uint32_t tag_sentinel = 0xA5A5A5A5U;
  CHECK(BulkNegotiationWireCodec::derive_transfer_tag(identity, tag_sentinel) ==
        BulkNegotiationWireStatus::DerivedTagZero);
  CHECK(tag_sentinel == 0xA5A5A5A5U);

  BulkSessionTerminalEvidence output{};
  dirty(output);
  CHECK(TerminalAckEvidenceBridge::consume(reassembler, identity, output) ==
        TerminalAckBridgeStatus::TransferTagDerivationFailed);
  CHECK(is_zero(output));

  CHECK(TerminalAckEvidenceBridge::consume(reassembler, identity, output) ==
        TerminalAckBridgeStatus::RecordUnavailable);
  CHECK(is_zero(output));
}

}  // namespace

int main() {
  test_complete_validated_record_maps_once_at_inclusive_boundaries();
  test_zero_expected_identity_rejects_without_consuming();
  test_expected_identity_may_alias_zeroed_output();
  test_wrong_expected_identity_consumes_and_fails_closed();
  test_partial_reassembler_rejects_without_consuming();
  test_failed_reassembler_rejects_and_zeroes_output();
  test_zero_derived_tag_fails_closed_after_one_shot_take();

  std::cout << "terminal_ack_bridge_tests checks=" << checks
            << " failures=" << failures << '\n';
  return failures == 0 ? 0 : 1;
}
