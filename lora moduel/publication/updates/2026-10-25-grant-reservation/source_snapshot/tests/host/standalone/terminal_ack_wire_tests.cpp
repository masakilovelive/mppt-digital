#include "../../../firmware/high_speed/terminal_ack_wire.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <limits>
#include <type_traits>

namespace {

using vc_lora::experimental::TerminalAckError;
using vc_lora::experimental::TerminalAckExpectedEvidence;
using vc_lora::experimental::TerminalAckFragment;
using vc_lora::experimental::TerminalAckFragments;
using vc_lora::experimental::TerminalAckIdentity;
using vc_lora::experimental::TerminalAckReassembler;
using vc_lora::experimental::TerminalAckRecord;
using vc_lora::experimental::TerminalAckWireCodec;

static_assert(TerminalAckWireCodec::fragment_bytes == 32U);
static_assert(TerminalAckWireCodec::fragment_payload_bytes == 18U);
static_assert(TerminalAckWireCodec::record_bytes == 144U);
static_assert(TerminalAckWireCodec::fragment_count == 8U);
static_assert(TerminalAckWireCodec::raw_fragment_airtime_lower_bound_ms ==
              107U);
static_assert(sizeof(TerminalAckFragment) == 32U);
static_assert(std::is_trivially_copyable_v<TerminalAckRecord>);
static_assert(std::is_trivially_copyable_v<TerminalAckExpectedEvidence>);
static_assert(!std::is_copy_constructible_v<TerminalAckReassembler>);
static_assert(!std::is_copy_assignable_v<TerminalAckReassembler>);
static_assert(!std::is_move_constructible_v<TerminalAckReassembler>);
static_assert(!std::is_move_assignable_v<TerminalAckReassembler>);

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

TerminalAckRecord sample_record(std::uint64_t record_id = 7ULL) {
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
  record.request_to_last_parameter_elapsed_ms = 26775U;
  record.heartbeat_count = 23U;
  record.last_heartbeat_request_id = 23U;
  record.first_heartbeat_gap_ms = 997U;
  record.max_heartbeat_gap_ms = 2199U;
  record.post_heartbeat_gap_ms = 1001U;
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

void put_u16_le(TerminalAckFragment& fragment, std::size_t offset,
                std::uint16_t value) {
  fragment[offset] = static_cast<std::uint8_t>(value & 0xFFU);
  fragment[offset + 1U] =
      static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
}

void put_u32_le(TerminalAckFragment& fragment, std::size_t offset,
                std::uint32_t value) {
  fragment[offset] = static_cast<std::uint8_t>(value & 0xFFU);
  fragment[offset + 1U] =
      static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
  fragment[offset + 2U] =
      static_cast<std::uint8_t>((value >> 16U) & 0xFFU);
  fragment[offset + 3U] =
      static_cast<std::uint8_t>((value >> 24U) & 0xFFU);
}

void repair_fragment_crc(TerminalAckFragment& fragment) {
  put_u16_le(fragment, 30U,
             TerminalAckWireCodec::crc16_ccitt_false(fragment, 30U));
}

void put_record_u32(TerminalAckWireCodec::RecordBytes& bytes,
                    std::size_t offset, std::uint32_t value) {
  bytes[offset] = static_cast<std::uint8_t>(value & 0xFFU);
  bytes[offset + 1U] =
      static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
  bytes[offset + 2U] =
      static_cast<std::uint8_t>((value >> 16U) & 0xFFU);
  bytes[offset + 3U] =
      static_cast<std::uint8_t>((value >> 24U) & 0xFFU);
}

void mutate_record_u32_and_reseal(TerminalAckFragments& fragments,
                                  std::size_t offset,
                                  std::uint32_t value) {
  TerminalAckWireCodec::RecordBytes bytes{};
  for (std::size_t fragment_index = 0U;
       fragment_index < fragments.size(); ++fragment_index) {
    for (std::size_t payload_index = 0U;
         payload_index < TerminalAckWireCodec::fragment_payload_bytes;
         ++payload_index) {
      bytes[fragment_index * TerminalAckWireCodec::fragment_payload_bytes +
            payload_index] = fragments[fragment_index][12U + payload_index];
    }
  }
  put_record_u32(bytes, offset, value);
  put_record_u32(bytes, TerminalAckWireCodec::record_integrity_offset,
                 TerminalAckWireCodec::crc32c(
                     bytes, TerminalAckWireCodec::record_integrity_offset));
  for (std::size_t fragment_index = 0U;
       fragment_index < fragments.size(); ++fragment_index) {
    for (std::size_t payload_index = 0U;
         payload_index < TerminalAckWireCodec::fragment_payload_bytes;
         ++payload_index) {
      fragments[fragment_index][12U + payload_index] =
          bytes[fragment_index *
                    TerminalAckWireCodec::fragment_payload_bytes +
                payload_index];
    }
    repair_fragment_crc(fragments[fragment_index]);
  }
}

TerminalAckError push_all(TerminalAckReassembler& reassembler,
                          const TerminalAckFragments& fragments) {
  TerminalAckError result = TerminalAckError::None;
  for (const TerminalAckFragment& fragment : fragments) {
    result = reassembler.push(fragment);
    if (result != TerminalAckError::None) {
      break;
    }
  }
  return result;
}

bool records_equal(const TerminalAckRecord& left,
                   const TerminalAckRecord& right) {
  return left.record_id == right.record_id &&
         left.identity == right.identity &&
         left.final_parameter_count == right.final_parameter_count &&
         left.final_global_chunk_ordinal ==
             right.final_global_chunk_ordinal &&
         left.raw_mavlink_bytes == right.raw_mavlink_bytes &&
         left.wire_chunk_count == right.wire_chunk_count &&
         left.wire_bytes == right.wire_bytes &&
         left.request_to_last_parameter_elapsed_ms ==
             right.request_to_last_parameter_elapsed_ms &&
         left.heartbeat_count == right.heartbeat_count &&
         left.last_heartbeat_request_id ==
             right.last_heartbeat_request_id &&
         left.first_heartbeat_gap_ms == right.first_heartbeat_gap_ms &&
         left.max_heartbeat_gap_ms == right.max_heartbeat_gap_ms &&
         left.post_heartbeat_gap_ms == right.post_heartbeat_gap_ms &&
         left.receiver_batch == right.receiver_batch &&
         left.receiver_revision == right.receiver_revision &&
         left.transcript_digest == right.transcript_digest;
}

void expect_reassembly_error(const TerminalAckRecord& transmitted,
                             const TerminalAckExpectedEvidence& expected,
                             TerminalAckError wanted) {
  const TerminalAckFragments fragments = encode(transmitted);
  TerminalAckReassembler reassembler(expected, 0U);
  CHECK(push_all(reassembler, fragments) == wanted);
  CHECK(reassembler.failed());
  CHECK(!reassembler.complete());
}

void expect_fragment_error(const TerminalAckFragments& fragments,
                           const TerminalAckExpectedEvidence& expected,
                           TerminalAckError wanted) {
  TerminalAckReassembler reassembler(expected, 0U);
  CHECK(push_all(reassembler, fragments) == wanted);
  CHECK(reassembler.failed());
  CHECK(!reassembler.complete());
}

void test_crc_reference_vectors() {
  const std::array<std::uint8_t, 9U> vector{
      static_cast<std::uint8_t>('1'), static_cast<std::uint8_t>('2'),
      static_cast<std::uint8_t>('3'), static_cast<std::uint8_t>('4'),
      static_cast<std::uint8_t>('5'), static_cast<std::uint8_t>('6'),
      static_cast<std::uint8_t>('7'), static_cast<std::uint8_t>('8'),
      static_cast<std::uint8_t>('9')};
  CHECK(TerminalAckWireCodec::crc16_ccitt_false(vector, vector.size()) ==
        0x29B1U);
  CHECK(TerminalAckWireCodec::crc32c(vector, vector.size()) == 0xE3069283U);
}

void test_exact_layout_little_endian_and_round_trip() {
  const TerminalAckRecord expected_record = sample_record();
  const TerminalAckFragments fragments = encode(expected_record);

  CHECK(fragments[0][0] == static_cast<std::uint8_t>('V'));
  CHECK(fragments[0][1] == static_cast<std::uint8_t>('C'));
  CHECK(fragments[0][2] == static_cast<std::uint8_t>('T'));
  CHECK(fragments[0][3] == static_cast<std::uint8_t>('A'));
  CHECK(fragments[0][4] == 1U);
  CHECK(fragments[0][5] == 0U);
  CHECK(fragments[0][6] == 8U);
  CHECK(fragments[0][7] == 0U);
  CHECK(fragments[0][8] == 7U);
  CHECK(fragments[0][11] == 0U);
  CHECK(fragments[0][12] == 7U);
  CHECK(fragments[0][19] == 0U);
  CHECK(fragments[0][20] == 0x08U);
  CHECK(fragments[0][21] == 0x07U);
  CHECK(fragments[0][29] == 0x17U);
  CHECK(fragments[7][5] == 7U);

  TerminalAckReassembler reassembler(expected_for(expected_record), 6U);
  CHECK(push_all(reassembler, fragments) == TerminalAckError::None);
  CHECK(reassembler.complete());
  CHECK(reassembler.finish() == TerminalAckError::None);
  TerminalAckRecord actual{};
  CHECK(reassembler.take_record(actual));
  CHECK(records_equal(expected_record, actual));
  TerminalAckRecord duplicate{};
  CHECK(!reassembler.take_record(duplicate));
  CHECK(reassembler.last_accepted_record_id() == 7U);
  CHECK(reassembler.finish() == TerminalAckError::AlreadyConsumed);
  CHECK(reassembler.push(fragments[0]) == TerminalAckError::AlreadyConsumed);
}

void test_fragment_crc_covers_every_routed_header_and_payload_bit() {
  const TerminalAckRecord record = sample_record();
  const TerminalAckFragments good = encode(record);
  for (std::size_t byte = 4U; byte < 32U; ++byte) {
    TerminalAckFragment corrupt = good[0];
    corrupt[byte] ^= 0x01U;
    TerminalAckReassembler reassembler(expected_for(record), 0U);
    CHECK(reassembler.push(corrupt) == TerminalAckError::BadFragmentCrc);
  }

  TerminalAckFragment magic = good[0];
  magic[0] = static_cast<std::uint8_t>('X');
  TerminalAckReassembler unknown_magic(expected_for(record), 0U);
  CHECK(unknown_magic.push(magic) == TerminalAckError::UnknownMagic);

  for (std::size_t target = 0U; target < good.size(); ++target) {
    TerminalAckFragments corrupt = good;
    corrupt[target][12] ^= 0x80U;
    TerminalAckReassembler reassembler(expected_for(record), 0U);
    CHECK(push_all(reassembler, corrupt) == TerminalAckError::BadFragmentCrc);
  }
}

void test_whole_record_crc_rejects_crc16_repaired_bit_flip() {
  const TerminalAckRecord record = sample_record();
  TerminalAckFragments fragments = encode(record);
  fragments[5][18] ^= 0x01U;
  repair_fragment_crc(fragments[5]);
  TerminalAckReassembler reassembler(expected_for(record), 0U);
  CHECK(push_all(reassembler, fragments) ==
        TerminalAckError::BadWholeRecordCrc);
  CHECK(reassembler.failed());
}

void test_missing_duplicate_reorder_and_mixed_fail_closed() {
  const TerminalAckRecord record = sample_record();
  const TerminalAckFragments first = encode(record);

  TerminalAckReassembler missing(expected_for(record), 0U);
  for (std::size_t index = 0U; index + 1U < first.size(); ++index) {
    CHECK(missing.push(first[index]) == TerminalAckError::None);
  }
  CHECK(missing.finish() == TerminalAckError::MissingFragment);
  CHECK(missing.push(first.back()) == TerminalAckError::Latched);

  TerminalAckReassembler duplicate(expected_for(record), 0U);
  CHECK(duplicate.push(first[0]) == TerminalAckError::None);
  CHECK(duplicate.push(first[0]) == TerminalAckError::DuplicateFragment);

  TerminalAckReassembler reorder(expected_for(record), 0U);
  CHECK(reorder.push(first[1]) == TerminalAckError::ReorderedFragment);

  const TerminalAckFragments second = encode(sample_record(8ULL));
  TerminalAckReassembler mixed(expected_for(record), 0U);
  CHECK(mixed.push(first[0]) == TerminalAckError::None);
  CHECK(mixed.push(second[1]) == TerminalAckError::MixedRecord);
}

void test_semantic_header_errors_require_valid_crc() {
  const TerminalAckRecord record = sample_record();
  const TerminalAckFragments good = encode(record);

  TerminalAckFragment version = good[0];
  version[4] = 2U;
  repair_fragment_crc(version);
  TerminalAckReassembler unknown_version(expected_for(record), 0U);
  CHECK(unknown_version.push(version) == TerminalAckError::UnknownVersion);

  TerminalAckFragment flags = good[0];
  flags[7] = 1U;
  repair_fragment_crc(flags);
  TerminalAckReassembler invalid_flags(expected_for(record), 0U);
  CHECK(invalid_flags.push(flags) == TerminalAckError::InvalidFlags);

  TerminalAckFragment low_count = good[0];
  low_count[6] = 7U;
  repair_fragment_crc(low_count);
  TerminalAckReassembler bad_count(expected_for(record), 0U);
  CHECK(bad_count.push(low_count) == TerminalAckError::BadFragmentCount);

  TerminalAckFragment high_count = good[0];
  high_count[6] = 9U;
  repair_fragment_crc(high_count);
  TerminalAckReassembler count_overflow(expected_for(record), 0U);
  CHECK(count_overflow.push(high_count) == TerminalAckError::Overflow);

  TerminalAckFragment index_overflow = good[0];
  index_overflow[5] = 8U;
  repair_fragment_crc(index_overflow);
  TerminalAckReassembler bad_index(expected_for(record), 0U);
  CHECK(bad_index.push(index_overflow) == TerminalAckError::Overflow);
}

void test_record_tag_and_body_id_are_both_bound() {
  const TerminalAckRecord expected_record = sample_record(7ULL);
  TerminalAckFragments fragments = encode(sample_record(8ULL));
  const std::uint32_t expected_tag =
      TerminalAckWireCodec::record_tag(expected_record.record_id);
  for (TerminalAckFragment& fragment : fragments) {
    put_u32_le(fragment, 8U, expected_tag);
    repair_fragment_crc(fragment);
  }
  TerminalAckReassembler reassembler(expected_for(expected_record), 0U);
  CHECK(reassembler.push(fragments[0]) == TerminalAckError::MixedRecord);
}

void test_colliding_record_tags_cannot_mix_records() {
  const TerminalAckRecord low_id = sample_record(1ULL);
  const TerminalAckRecord high_id = sample_record(0x0000000100000000ULL);
  CHECK(TerminalAckWireCodec::record_tag(low_id.record_id) ==
        TerminalAckWireCodec::record_tag(high_id.record_id));
  const TerminalAckFragments first = encode(low_id);
  const TerminalAckFragments second = encode(high_id);

  TerminalAckReassembler reassembler(expected_for(low_id), 0U);
  CHECK(reassembler.push(first[0]) == TerminalAckError::None);
  TerminalAckError result = TerminalAckError::None;
  for (std::size_t index = 1U; index < second.size(); ++index) {
    result = reassembler.push(second[index]);
  }
  CHECK(result == TerminalAckError::BadWholeRecordCrc);
  CHECK(reassembler.failed());
}

void test_terminal_window_close_requires_explicit_finish() {
  const TerminalAckRecord record = sample_record();
  const TerminalAckFragments fragments = encode(record);
  TerminalAckReassembler timed_out(expected_for(record), 0U);
  CHECK(timed_out.push(fragments[0]) == TerminalAckError::None);
  CHECK(timed_out.finish() == TerminalAckError::MissingFragment);
  CHECK(timed_out.push(fragments[1]) == TerminalAckError::Latched);
}

void test_wrong_identity_components_are_distinct_failures() {
  const TerminalAckRecord baseline = sample_record();
  const TerminalAckExpectedEvidence expected = expected_for(baseline);

  TerminalAckRecord changed = baseline;
  ++changed.identity.session_id;
  expect_reassembly_error(changed, expected, TerminalAckError::WrongSession);
  changed = baseline;
  ++changed.identity.stream_id;
  expect_reassembly_error(changed, expected, TerminalAckError::WrongStream);
  changed = baseline;
  ++changed.identity.lease_id;
  expect_reassembly_error(changed, expected, TerminalAckError::WrongLease);
  changed = baseline;
  ++changed.identity.ground_request_nonce;
  expect_reassembly_error(changed, expected,
                          TerminalAckError::WrongRequestNonce);
  changed = baseline;
  ++changed.identity.vehicle_terminal_challenge_nonce;
  expect_reassembly_error(changed, expected,
                          TerminalAckError::WrongChallengeNonce);
}

void test_expected_evidence_exact_match_and_deadline_boundaries() {
  TerminalAckRecord baseline = sample_record();

  baseline.request_to_last_parameter_elapsed_ms = 30000U;
  baseline.first_heartbeat_gap_ms = 2500U;
  baseline.max_heartbeat_gap_ms = 2500U;
  baseline.post_heartbeat_gap_ms = 2500U;
  TerminalAckReassembler boundary(expected_for(baseline), 0U);
  CHECK(push_all(boundary, encode(baseline)) == TerminalAckError::None);

  TerminalAckFragments malicious = encode(baseline);
  mutate_record_u32_and_reseal(malicious, 68U, 30001U);
  expect_fragment_error(malicious, expected_for(baseline),
                        TerminalAckError::ParameterDeadlineExceeded);

  malicious = encode(baseline);
  mutate_record_u32_and_reseal(malicious, 80U, 2501U);
  expect_fragment_error(malicious, expected_for(baseline),
                        TerminalAckError::HeartbeatDeadlineExceeded);
  malicious = encode(baseline);
  mutate_record_u32_and_reseal(malicious, 84U, 2501U);
  expect_fragment_error(malicious, expected_for(baseline),
                        TerminalAckError::HeartbeatDeadlineExceeded);
  malicious = encode(baseline);
  mutate_record_u32_and_reseal(malicious, 88U, 2501U);
  expect_fragment_error(malicious, expected_for(baseline),
                        TerminalAckError::HeartbeatDeadlineExceeded);

  malicious = encode(baseline);
  mutate_record_u32_and_reseal(malicious, 48U, 931U);
  expect_fragment_error(malicious, expected_for(baseline),
                        TerminalAckError::ParameterEvidenceMismatch);
  malicious = encode(baseline);
  mutate_record_u32_and_reseal(malicious, 52U, 1862U);
  expect_fragment_error(malicious, expected_for(baseline),
                        TerminalAckError::InvalidRecord);
  malicious = encode(baseline);
  mutate_record_u32_and_reseal(malicious, 56U, 34483U);
  expect_fragment_error(malicious, expected_for(baseline),
                        TerminalAckError::ParameterEvidenceMismatch);
  malicious = encode(baseline);
  mutate_record_u32_and_reseal(malicious, 60U, 1863U);
  expect_fragment_error(malicious, expected_for(baseline),
                        TerminalAckError::InvalidRecord);
  malicious = encode(baseline);
  mutate_record_u32_and_reseal(malicious, 64U, 59616U);
  expect_fragment_error(malicious, expected_for(baseline),
                        TerminalAckError::InvalidRecord);

  TerminalAckRecord changed = baseline;
  changed.heartbeat_count = 24U;
  changed.last_heartbeat_request_id = 24U;
  expect_reassembly_error(changed, expected_for(baseline),
                          TerminalAckError::HeartbeatEvidenceMismatch);
  changed = baseline;
  ++changed.receiver_batch;
  expect_reassembly_error(changed, expected_for(baseline),
                          TerminalAckError::ReceiverBatchMismatch);
  changed = baseline;
  ++changed.receiver_revision;
  expect_reassembly_error(changed, expected_for(baseline),
                          TerminalAckError::ReceiverRevisionMismatch);
  changed = baseline;
  changed.transcript_digest[0] ^= 1U;
  expect_reassembly_error(changed, expected_for(baseline),
                          TerminalAckError::TranscriptDigestMismatch);
}

void test_stale_replay_and_one_shot_challenge() {
  const TerminalAckRecord record = sample_record(77ULL);
  const TerminalAckFragments fragments = encode(record);

  TerminalAckReassembler stale(expected_for(record), 77U);
  CHECK(stale.push(fragments[0]) == TerminalAckError::StaleReplay);

  TerminalAckReassembler accepted(expected_for(record), 76U);
  CHECK(push_all(accepted, fragments) == TerminalAckError::None);
  CHECK(accepted.push(fragments[0]) == TerminalAckError::AlreadyComplete);

  TerminalAckReassembler max_floor(
      expected_for(record), std::numeric_limits<std::uint64_t>::max());
  CHECK(max_floor.push(fragments[0]) == TerminalAckError::StaleReplay);

  const TerminalAckRecord max_record =
      sample_record(std::numeric_limits<std::uint64_t>::max());
  TerminalAckReassembler max_accept(
      expected_for(max_record),
      std::numeric_limits<std::uint64_t>::max() - 1ULL);
  CHECK(push_all(max_accept, encode(max_record)) == TerminalAckError::None);
}

void test_invalid_expectation_and_encoder_overflow_fail_closed() {
  const TerminalAckRecord record = sample_record();
  const TerminalAckFragments fragments = encode(record);

  TerminalAckExpectedEvidence invalid_expected = expected_for(record);
  invalid_expected.identity.session_id = 0U;
  TerminalAckReassembler invalid(invalid_expected, 0U);
  CHECK(invalid.failed());
  CHECK(invalid.error() == TerminalAckError::InvalidRecord);
  CHECK(invalid.push(fragments[0]) == TerminalAckError::Latched);

  invalid_expected = expected_for(record);
  invalid_expected.maximum_request_to_last_parameter_elapsed_ms = 30001U;
  TerminalAckReassembler relaxed_param(invalid_expected, 0U);
  CHECK(relaxed_param.failed());
  invalid_expected = expected_for(record);
  invalid_expected.maximum_heartbeat_gap_ms = 2501U;
  TerminalAckReassembler relaxed_hb(invalid_expected, 0U);
  CHECK(relaxed_hb.failed());
  invalid_expected = expected_for(record);
  invalid_expected.identity.stream_id = 0U;
  TerminalAckReassembler zero_stream(invalid_expected, 0U);
  CHECK(zero_stream.failed());
  invalid_expected = expected_for(record);
  invalid_expected.identity.lease_id = 0U;
  TerminalAckReassembler zero_lease(invalid_expected, 0U);
  CHECK(zero_lease.failed());
  invalid_expected = expected_for(record);
  invalid_expected.identity.ground_request_nonce = 0U;
  TerminalAckReassembler zero_request(invalid_expected, 0U);
  CHECK(zero_request.failed());
  invalid_expected = expected_for(record);
  invalid_expected.identity.vehicle_terminal_challenge_nonce = 0U;
  TerminalAckReassembler zero_challenge(invalid_expected, 0U);
  CHECK(zero_challenge.failed());
  invalid_expected = expected_for(record);
  invalid_expected.receiver_batch = 0U;
  TerminalAckReassembler zero_batch(invalid_expected, 0U);
  CHECK(zero_batch.failed());
  invalid_expected = expected_for(record);
  invalid_expected.receiver_revision = 0U;
  TerminalAckReassembler zero_revision(invalid_expected, 0U);
  CHECK(zero_revision.failed());
  invalid_expected = expected_for(record);
  invalid_expected.transcript_digest.fill(0U);
  TerminalAckReassembler zero_digest(invalid_expected, 0U);
  CHECK(zero_digest.failed());

  TerminalAckFragments output{};
  TerminalAckRecord invalid_record = record;
  invalid_record.record_id = 0U;
  CHECK(TerminalAckWireCodec::encode(invalid_record, output) ==
        TerminalAckError::InvalidRecord);
  invalid_record = record;
  invalid_record.identity.ground_request_nonce = 0U;
  CHECK(TerminalAckWireCodec::encode(invalid_record, output) ==
        TerminalAckError::InvalidRecord);
  invalid_record = record;
  invalid_record.last_heartbeat_request_id = 24U;
  CHECK(TerminalAckWireCodec::encode(invalid_record, output) ==
        TerminalAckError::InvalidRecord);
  invalid_record = record;
  invalid_record.wire_chunk_count =
      (std::numeric_limits<std::uint32_t>::max() / 32U) + 1U;
  invalid_record.final_global_chunk_ordinal =
      invalid_record.wire_chunk_count - 1U;
  invalid_record.wire_bytes = 1U;
  CHECK(TerminalAckWireCodec::encode(invalid_record, output) ==
        TerminalAckError::Overflow);
  invalid_record = record;
  invalid_record.transcript_digest.fill(0U);
  CHECK(TerminalAckWireCodec::encode(invalid_record, output) ==
        TerminalAckError::InvalidRecord);
}

}  // namespace

int main() {
  test_crc_reference_vectors();
  test_exact_layout_little_endian_and_round_trip();
  test_fragment_crc_covers_every_routed_header_and_payload_bit();
  test_whole_record_crc_rejects_crc16_repaired_bit_flip();
  test_missing_duplicate_reorder_and_mixed_fail_closed();
  test_semantic_header_errors_require_valid_crc();
  test_record_tag_and_body_id_are_both_bound();
  test_colliding_record_tags_cannot_mix_records();
  test_terminal_window_close_requires_explicit_finish();
  test_wrong_identity_components_are_distinct_failures();
  test_expected_evidence_exact_match_and_deadline_boundaries();
  test_stale_replay_and_one_shot_challenge();
  test_invalid_expectation_and_encoder_overflow_fail_closed();

  if (failures != 0) {
    std::cerr << failures << " of " << checks << " checks failed\n";
    return 1;
  }
  std::cout << "terminal_ack_wire_tests PASS " << checks << '/' << checks
            << '\n';
  return 0;
}
