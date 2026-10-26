#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <type_traits>

#include "fixtures/mavlink_fixtures.hpp"
#include "vc_lora/bulk_transcript.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint32_t kTransferTag = 0xB17C0DE1U;

static_assert(!std::is_copy_constructible_v<Sha256Accumulator>);
static_assert(!std::is_copy_assignable_v<Sha256Accumulator>);
static_assert(!std::is_move_constructible_v<Sha256Accumulator>);
static_assert(!std::is_move_assignable_v<Sha256Accumulator>);
static_assert(!std::is_copy_constructible_v<BulkTranscriptLedger>);
static_assert(!std::is_copy_assignable_v<BulkTranscriptLedger>);
static_assert(!std::is_move_constructible_v<BulkTranscriptLedger>);
static_assert(!std::is_move_assignable_v<BulkTranscriptLedger>);
static_assert(std::is_trivially_copyable_v<BulkTranscriptEvidence>);

BulkNegotiationIdentity identity(std::uint64_t delta = 0U) noexcept {
  BulkNegotiationIdentity value{};
  value.session_id = 0x0102030405060708ULL + delta;
  value.stream_id = 0x1112131415161718ULL + delta;
  value.lease_id = 0x2122232425262728ULL + delta;
  value.ground_request_nonce = 0x3132333435363738ULL + delta;
  value.vehicle_challenge_nonce = 0x4142434445464748ULL + delta;
  return value;
}

bool same_identity(const BulkNegotiationIdentity& left,
                   const BulkNegotiationIdentity& right) noexcept {
  return left.session_id == right.session_id &&
         left.stream_id == right.stream_id &&
         left.lease_id == right.lease_id &&
         left.ground_request_nonce == right.ground_request_nonce &&
         left.vehicle_challenge_nonce == right.vehicle_challenge_nonce;
}

bool digest_nonzero(const BulkTranscriptDigest& digest) noexcept {
  std::uint8_t aggregate = 0U;
  for (const std::uint8_t byte : digest) {
    aggregate = static_cast<std::uint8_t>(aggregate | byte);
  }
  return aggregate != 0U;
}

MavlinkFrame signed_heartbeat(std::uint8_t sequence) noexcept {
  const MavlinkFrame source = fixtures::heartbeat_v2(sequence);
  std::array<std::uint8_t, 13U> signature{};
  signature.fill(0xA5U);
  MavlinkFrame output{};
  (void)encode_mavlink_v2(sequence, source.system_id, source.component_id,
                          0U, source.payload(), source.payload_length, output,
                          0x01U, 0U, signature.data());
  return output;
}

MavlinkFrame parameter(std::uint16_t index, float value = 1.0F) noexcept {
  return fixtures::param_value_v2(
      static_cast<std::uint8_t>(index & 0xFFU), "TRANSCRIPT", value, index,
      BulkTranscriptLedger::required_parameter_count());
}

bool append_corpus(BulkTranscriptLedger& ledger,
                   std::uint16_t heartbeat_before_index,
                   TestReport& report) {
  for (std::uint16_t index = 0U;
       index < BulkTranscriptLedger::required_parameter_count(); ++index) {
    if (index == heartbeat_before_index) {
      if (ledger.append(fixtures::heartbeat_v2(201U)) !=
          BulkTranscriptStatus::EntryAccepted) {
        report.check(false, "corpus HEARTBEAT entry was rejected");
        return false;
      }
    }
    if (ledger.append(parameter(index, static_cast<float>(index))) !=
        BulkTranscriptStatus::EntryAccepted) {
      report.check(false, "corpus PARAM_VALUE entry was rejected");
      return false;
    }
  }
  return true;
}

void test_sha256_known_answers_and_fail_closed(TestReport& report) {
  constexpr std::array<std::uint8_t, 32U> kAbcDigest{{
      0xBAU, 0x78U, 0x16U, 0xBFU, 0x8FU, 0x01U, 0xCFU, 0xEAU,
      0x41U, 0x41U, 0x40U, 0xDEU, 0x5DU, 0xAEU, 0x22U, 0x23U,
      0xB0U, 0x03U, 0x61U, 0xA3U, 0x96U, 0x17U, 0x7AU, 0x9CU,
      0xB4U, 0x10U, 0xFFU, 0x61U, 0xF2U, 0x00U, 0x15U, 0xADU,
  }};
  const std::array<std::uint8_t, 3U> abc{{'a', 'b', 'c'}};
  Sha256Accumulator sha{};
  BulkTranscriptDigest digest{};
  report.check(sha.update(abc.data(), 1U) == Sha256Status::Accepted &&
                   sha.update(abc.data() + 1U, 2U) ==
                       Sha256Status::Accepted &&
                   sha.finish(digest) == Sha256Status::DigestReady &&
                   digest == kAbcDigest,
               "incremental SHA-256 did not match the NIST abc vector");
  report.check(sha.update(abc.data(), abc.size()) ==
                       Sha256Status::AlreadyFinalized &&
                   sha.finish(digest) == Sha256Status::AlreadyFinalized,
               "finalized SHA-256 accepted post-digest input");

  // Independent .NET SHA-256 known answer for the exact 65-byte domain and
  // LE64 identity prefix printed in terminal_ack_wire.hpp.
  constexpr std::array<std::uint8_t, 65U> kCanonicalPrefix{{
      0x56U, 0x43U, 0x2DU, 0x50U, 0x41U, 0x52U, 0x41U, 0x4DU,
      0x2DU, 0x48U, 0x42U, 0x2DU, 0x54U, 0x52U, 0x41U, 0x4EU,
      0x53U, 0x43U, 0x52U, 0x49U, 0x50U, 0x54U, 0x00U, 0x76U,
      0x31U, 0x08U, 0x07U, 0x06U, 0x05U, 0x04U, 0x03U, 0x02U,
      0x01U, 0x18U, 0x17U, 0x16U, 0x15U, 0x14U, 0x13U, 0x12U,
      0x11U, 0x28U, 0x27U, 0x26U, 0x25U, 0x24U, 0x23U, 0x22U,
      0x21U, 0x38U, 0x37U, 0x36U, 0x35U, 0x34U, 0x33U, 0x32U,
      0x31U, 0x48U, 0x47U, 0x46U, 0x45U, 0x44U, 0x43U, 0x42U,
      0x41U,
  }};
  constexpr BulkTranscriptDigest kCanonicalPrefixDigest{{
      0xD2U, 0x5BU, 0x38U, 0x42U, 0x19U, 0xF3U, 0x4CU, 0x2AU,
      0x8CU, 0xB7U, 0xE9U, 0x22U, 0xD1U, 0xECU, 0xAAU, 0x4DU,
      0xB6U, 0x2EU, 0xBBU, 0x0AU, 0x3EU, 0xBBU, 0x88U, 0xBBU,
      0x5DU, 0x37U, 0x34U, 0xA2U, 0xF6U, 0x89U, 0x63U, 0x0EU,
  }};
  sha.reset();
  report.check(sha.update(kCanonicalPrefix.data(), 63U) ==
                       Sha256Status::Accepted &&
                   sha.update(kCanonicalPrefix.data() + 63U, 2U) ==
                       Sha256Status::Accepted &&
                   sha.finish(digest) == Sha256Status::DigestReady &&
                   digest == kCanonicalPrefixDigest,
               "SHA-256 failed the independent canonical-prefix answer");

  sha.reset();
  report.check(sha.update(nullptr, 1U) == Sha256Status::InvalidArgument &&
                   sha.update(abc.data(), 1U) == Sha256Status::Latched,
               "invalid SHA-256 pointer did not fail closed");
  if constexpr (sizeof(std::size_t) >= sizeof(std::uint64_t)) {
    sha.reset();
    const std::uint8_t byte = 0U;
    report.check(sha.update(&byte, std::numeric_limits<std::size_t>::max()) ==
                         Sha256Status::LengthOverflow &&
                     sha.update(&byte, 1U) == Sha256Status::Latched,
                 "SHA-256 byte-length overflow did not fail before reading");
  }
}

void test_sender_receiver_same_interleaving(TestReport& report) {
  BulkTranscriptLedger sender{identity(), kTransferTag};
  BulkTranscriptLedger receiver{identity(), kTransferTag};
  report.check(sender.active() && receiver.active(),
               "valid transcript owners did not arm");

  for (std::uint16_t index = 0U;
       index < BulkTranscriptLedger::required_parameter_count(); ++index) {
    if (index == 0U || index == 466U || index == 931U) {
      const MavlinkFrame heartbeat =
          fixtures::heartbeat_v2(static_cast<std::uint8_t>(200U + index));
      report.check(sender.append(heartbeat) ==
                           BulkTranscriptStatus::EntryAccepted &&
                       receiver.append(heartbeat) ==
                           BulkTranscriptStatus::EntryAccepted,
                   "sender/receiver rejected an interleaved HEARTBEAT");
    }
    const MavlinkFrame frame = parameter(index, static_cast<float>(index));
    report.check(sender.append(frame) ==
                         BulkTranscriptStatus::EntryAccepted &&
                     receiver.append(frame) ==
                         BulkTranscriptStatus::EntryAccepted,
                 "sender/receiver rejected a sequential PARAM_VALUE");
  }
  report.check(sender.seal_session() == BulkTranscriptStatus::Sealed &&
                   receiver.seal_session() == BulkTranscriptStatus::Sealed,
               "complete sender/receiver transcript did not seal");
  const BulkTranscriptEvidence left = sender.evidence();
  const BulkTranscriptEvidence right = receiver.evidence();
  report.check(left.digest == right.digest && digest_nonzero(left.digest) &&
                   left.parameter_count == 932U &&
                   left.raw_parameter_bytes == 34484U &&
                   left.heartbeat_count == 3U &&
                   left.last_heartbeat_request_id == 3U &&
                   left.owner_sealed && right.owner_sealed &&
                   same_identity(left.identity, identity()) &&
                   left.transfer_tag == kTransferTag,
               "same canonical transcript produced different/incomplete evidence");
}

void test_identity_and_one_bit_mismatch(TestReport& report) {
  BulkTranscriptLedger baseline{identity(), kTransferTag};
  BulkTranscriptLedger changed_identity{identity(1U), kTransferTag + 1U};
  BulkTranscriptLedger changed_payload{identity(), kTransferTag};
  std::uint32_t one_bit = 0x3F800001U;
  float one_bit_value = 0.0F;
  std::memcpy(&one_bit_value, &one_bit, sizeof(one_bit_value));

  for (std::uint16_t index = 0U;
       index < BulkTranscriptLedger::required_parameter_count(); ++index) {
    if (index == 123U) {
      const MavlinkFrame heartbeat = fixtures::heartbeat_v2(77U);
      report.check(baseline.append(heartbeat) ==
                           BulkTranscriptStatus::EntryAccepted &&
                       changed_identity.append(heartbeat) ==
                           BulkTranscriptStatus::EntryAccepted &&
                       changed_payload.append(heartbeat) ==
                           BulkTranscriptStatus::EntryAccepted,
                   "mismatch fixture HEARTBEAT was rejected");
    }
    const MavlinkFrame ordinary = parameter(index, 1.0F);
    const MavlinkFrame changed =
        index == 456U ? parameter(index, one_bit_value) : ordinary;
    report.check(baseline.append(ordinary) ==
                         BulkTranscriptStatus::EntryAccepted &&
                     changed_identity.append(ordinary) ==
                         BulkTranscriptStatus::EntryAccepted &&
                     changed_payload.append(changed) ==
                         BulkTranscriptStatus::EntryAccepted,
                 "mismatch fixture PARAM_VALUE was rejected");
  }
  report.check(baseline.seal_session() == BulkTranscriptStatus::Sealed &&
                   changed_identity.seal_session() ==
                       BulkTranscriptStatus::Sealed &&
                   changed_payload.seal_session() ==
                       BulkTranscriptStatus::Sealed,
               "mismatch transcript did not seal");
  report.check(baseline.evidence().digest !=
                       changed_identity.evidence().digest &&
                   baseline.evidence().digest !=
                       changed_payload.evidence().digest,
               "identity or one-payload-bit change preserved the digest");
}

void test_event_order_mismatch(TestReport& report) {
  BulkTranscriptLedger before{identity(), kTransferTag};
  BulkTranscriptLedger after{identity(), kTransferTag};
  const MavlinkFrame heartbeat = fixtures::heartbeat_v2(88U);
  for (std::uint16_t index = 0U;
       index < BulkTranscriptLedger::required_parameter_count(); ++index) {
    if (index == 400U) {
      report.check(before.append(heartbeat) ==
                       BulkTranscriptStatus::EntryAccepted,
                   "before-order HEARTBEAT was rejected");
    }
    const MavlinkFrame frame = parameter(index, static_cast<float>(index));
    report.check(before.append(frame) ==
                         BulkTranscriptStatus::EntryAccepted &&
                     after.append(frame) ==
                         BulkTranscriptStatus::EntryAccepted,
                 "order fixture PARAM_VALUE was rejected");
    if (index == 400U) {
      report.check(after.append(heartbeat) ==
                       BulkTranscriptStatus::EntryAccepted,
                   "after-order HEARTBEAT was rejected");
    }
  }
  report.check(before.seal_session() == BulkTranscriptStatus::Sealed &&
                   after.seal_session() == BulkTranscriptStatus::Sealed &&
                   before.evidence().parameter_count ==
                       after.evidence().parameter_count &&
                   before.evidence().heartbeat_count ==
                       after.evidence().heartbeat_count &&
                   before.evidence().digest != after.evidence().digest,
               "different accepted event order did not change the digest");
}

void test_invalid_mavlink_fails_closed(TestReport& report) {
  {
    BulkTranscriptLedger ledger{identity(), kTransferTag};
    MavlinkFrame partial = parameter(0U);
    --partial.size;
    report.check(ledger.append(partial) ==
                         BulkTranscriptStatus::InvalidMavlink &&
                     ledger.latched() && !ledger.evidence().owner_sealed,
                 "partial PARAM_VALUE did not fail closed");
  }
  {
    BulkTranscriptLedger ledger{identity(), kTransferTag};
    MavlinkFrame bad_crc = parameter(0U);
    bad_crc.bytes[bad_crc.size - 1U] ^= 0x01U;
    report.check(ledger.append(bad_crc) ==
                         BulkTranscriptStatus::InvalidMavlink &&
                     ledger.latched(),
                 "bad-CRC PARAM_VALUE did not fail closed");
  }
  {
    BulkTranscriptLedger ledger{identity(), kTransferTag};
    report.check(ledger.append(fixtures::heartbeat_v1(1U)) ==
                         BulkTranscriptStatus::UnsupportedFrame &&
                     ledger.latched(),
                 "MAVLink1 HEARTBEAT entered the canonical transcript");
  }
  {
    BulkTranscriptLedger ledger{identity(), kTransferTag};
    report.check(ledger.append(signed_heartbeat(2U)) ==
                         BulkTranscriptStatus::UnsupportedFrame &&
                     ledger.latched(),
                 "signed MAVLink2 HEARTBEAT entered the transcript");
  }
  {
    BulkTranscriptLedger ledger{identity(), kTransferTag};
    report.check(ledger.append(fixtures::command_ack_v2(3U)) ==
                         BulkTranscriptStatus::UnsupportedFrame &&
                     ledger.latched(),
                 "unsupported MAVLink message entered the transcript");
  }
}

void test_parameter_index_count_and_overflow(TestReport& report) {
  {
    BulkTranscriptLedger ledger{identity(), kTransferTag};
    report.check(ledger.append(parameter(1U)) ==
                         BulkTranscriptStatus::WrongParameterIndex &&
                     ledger.latched(),
                 "out-of-order first parameter did not fail closed");
  }
  {
    BulkTranscriptLedger ledger{identity(), kTransferTag};
    const MavlinkFrame wrong_count =
        fixtures::param_value_v2(1U, "COUNT", 1.0F, 0U, 931U);
    report.check(ledger.append(wrong_count) ==
                         BulkTranscriptStatus::WrongParameterCount &&
                     ledger.latched(),
                 "wrong PARAM_VALUE count did not fail closed");
  }
  {
    BulkTranscriptLedger ledger{identity(), kTransferTag};
    for (std::uint16_t index = 0U;
         index < BulkTranscriptLedger::required_parameter_count(); ++index) {
      report.check(ledger.append(parameter(index)) ==
                       BulkTranscriptStatus::EntryAccepted,
                   "overflow fixture rejected a legal parameter");
    }
    report.check(ledger.append(parameter(0U)) ==
                         BulkTranscriptStatus::ParameterOverflow &&
                     ledger.latched() && !ledger.evidence().owner_sealed,
                 "parameter beyond index 931 did not fail as overflow");
  }
}

void test_seal_and_post_seal_fail_closed(TestReport& report) {
  {
    BulkTranscriptLedger missing_heartbeat{identity(), kTransferTag};
    for (std::uint16_t index = 0U;
         index < BulkTranscriptLedger::required_parameter_count(); ++index) {
      report.check(missing_heartbeat.append(parameter(index)) ==
                       BulkTranscriptStatus::EntryAccepted,
                   "incomplete-seal fixture rejected a parameter");
    }
    report.check(missing_heartbeat.seal_session() ==
                         BulkTranscriptStatus::IncompleteCorpus &&
                     missing_heartbeat.latched() &&
                     !missing_heartbeat.evidence().owner_sealed,
                 "transcript without HEARTBEAT sealed successfully");
  }
  {
    BulkTranscriptLedger ledger{identity(), kTransferTag};
    report.check(append_corpus(ledger, 500U, report) &&
                     ledger.seal_session() == BulkTranscriptStatus::Sealed &&
                     ledger.evidence().owner_sealed,
                 "complete post-seal fixture did not seal");
    report.check(ledger.append(fixtures::heartbeat_v2(9U)) ==
                         BulkTranscriptStatus::PostSealData &&
                     ledger.latched() && !ledger.sealed() &&
                     !ledger.evidence().owner_sealed,
                 "post-seal data did not revoke terminal evidence");
  }
}

void test_long_lived_owner_rearm(TestReport& report) {
  constexpr std::uint32_t kSecondTag = 0xC20D1EF2U;
  BulkTranscriptLedger owner{};
  report.check(!owner.active() && !owner.sealed() && !owner.latched() &&
                   owner.append(parameter(0U)) ==
                       BulkTranscriptStatus::InvalidConfiguration &&
                   owner.latched(),
               "unarmed global transcript owner accepted data");
  report.check(owner.rearm(identity(), kTransferTag) ==
                       BulkTranscriptStatus::Rearmed &&
                   owner.active() && !owner.latched(),
               "failed global owner did not arm a valid first session");
  report.check(owner.rearm(identity(1U), kSecondTag) ==
                       BulkTranscriptStatus::SessionNotSealed &&
                   owner.active() && !owner.latched(),
               "active transcript session was silently replaced");
  report.check(owner.append(parameter(0U)) ==
                       BulkTranscriptStatus::EntryAccepted &&
                   owner.abort() == BulkTranscriptStatus::Aborted &&
                   owner.latched(),
               "active transcript did not abort explicitly");
  const BulkTranscriptEvidence aborted = owner.evidence();
  report.check(aborted.parameter_count == 0U &&
                   aborted.raw_parameter_bytes == 0U &&
                   aborted.heartbeat_count == 0U &&
                   aborted.last_heartbeat_request_id == 0U &&
                   !digest_nonzero(aborted.digest) && !aborted.owner_sealed,
               "aborted transcript retained reusable completion evidence");
  report.check(owner.rearm(identity(), kSecondTag) ==
                       BulkTranscriptStatus::IdentityReuse &&
                   owner.rearm(identity(1U), kTransferTag) ==
                       BulkTranscriptStatus::TransferTagReuse,
               "rearm accepted an immediately reused identity or tag");
  report.check(owner.rearm(identity(1U), kSecondTag) ==
                       BulkTranscriptStatus::Rearmed &&
                   owner.active() &&
                   same_identity(owner.evidence().identity, identity(1U)) &&
                   owner.evidence().transfer_tag == kSecondTag,
               "fresh identity/tag did not start a clean transcript epoch");
  report.check(owner.seal_session() ==
                       BulkTranscriptStatus::IncompleteCorpus &&
                   owner.rearm(identity(2U), kSecondTag + 1U) ==
                       BulkTranscriptStatus::Rearmed,
               "failed incomplete session could not rearm explicitly");
}

}  // namespace

TestReport run_bulk_transcript_test(const std::string& test_id,
                                    std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-BULK-TRANSCRIPT-001") {
    test_sha256_known_answers_and_fail_closed(report);
  } else if (test_id == "UT-BULK-TRANSCRIPT-002") {
    test_sender_receiver_same_interleaving(report);
  } else if (test_id == "UT-BULK-TRANSCRIPT-003") {
    test_identity_and_one_bit_mismatch(report);
  } else if (test_id == "UT-BULK-TRANSCRIPT-004") {
    test_event_order_mismatch(report);
  } else if (test_id == "UT-BULK-TRANSCRIPT-005") {
    test_invalid_mavlink_fails_closed(report);
  } else if (test_id == "UT-BULK-TRANSCRIPT-006") {
    test_parameter_index_count_and_overflow(report);
  } else if (test_id == "UT-BULK-TRANSCRIPT-007") {
    test_seal_and_post_seal_fail_closed(report);
  } else if (test_id == "UT-BULK-TRANSCRIPT-008") {
    test_long_lived_owner_rearm(report);
  } else {
    report.check(false, "unknown bulk transcript test ID");
  }

  report.trace.record({0U, "host", "BULK_TRANSCRIPT", 0U,
                       report.passed ? "PASS" : "FAIL", true,
                       report.diagnostics.downlink_payload_bytes, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
