#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/bulk_negotiation_codec.hpp"

namespace vc_lora::test {
namespace {

constexpr BulkNegotiationRequest kRequest{
    0x11223344U, 0x5566U, 0x7788U, 0x0102030405060708ULL,
    1U,          1U,       0x99AAU, 0xBBCCU};

constexpr std::uint32_t kRequestTag = 0x9BE4A177U;

constexpr BulkNegotiationResponse kAccept{
    BulkNegotiationResponseStatus::Accept,
    0xA1B2C3D4U,
    0x99AAU,
    0x1357U,
    0x8877665544332211ULL,
    kRequestTag,
    0xBBCCU};

constexpr BulkNegotiationFrame kGoldenRequest{{
    0x56U, 0x43U, 0x42U, 0x4EU, 0x01U, 0x01U, 0x01U, 0x00U,
    0x44U, 0x33U, 0x22U, 0x11U, 0x66U, 0x55U, 0x88U, 0x77U,
    0x08U, 0x07U, 0x06U, 0x05U, 0x04U, 0x03U, 0x02U, 0x01U,
    0x01U, 0x01U, 0xAAU, 0x99U, 0xCCU, 0xBBU, 0xB4U, 0x6EU}};

constexpr BulkNegotiationFrame kGoldenAccept{{
    0x56U, 0x43U, 0x42U, 0x4EU, 0x01U, 0x02U, 0x01U, 0x00U,
    0xD4U, 0xC3U, 0xB2U, 0xA1U, 0xAAU, 0x99U, 0x57U, 0x13U,
    0x11U, 0x22U, 0x33U, 0x44U, 0x55U, 0x66U, 0x77U, 0x88U,
    0x77U, 0xA1U, 0xE4U, 0x9BU, 0xCCU, 0xBBU, 0x65U, 0xA7U}};

bool same_request(const BulkNegotiationRequest& left,
                  const BulkNegotiationRequest& right) {
  return left.ground_boot_id == right.ground_boot_id &&
         left.ground_session_id == right.ground_session_id &&
         left.request_sequence == right.request_sequence &&
         left.ground_nonce == right.ground_nonce &&
         left.target_system == right.target_system &&
         left.target_component == right.target_component &&
         left.captured_vehicle_grant_session ==
             right.captured_vehicle_grant_session &&
         left.captured_vehicle_grant_cycle ==
             right.captured_vehicle_grant_cycle;
}

bool same_response(const BulkNegotiationResponse& left,
                   const BulkNegotiationResponse& right) {
  return left.status == right.status &&
         left.vehicle_boot_id == right.vehicle_boot_id &&
         left.vehicle_session_id == right.vehicle_session_id &&
         left.lease_sequence == right.lease_sequence &&
         left.vehicle_challenge_nonce == right.vehicle_challenge_nonce &&
         left.request_tag == right.request_tag &&
         left.echoed_vehicle_grant_cycle ==
             right.echoed_vehicle_grant_cycle;
}

bool same_identity(const BulkNegotiationIdentity& left,
                   const BulkNegotiationIdentity& right) {
  return left.session_id == right.session_id &&
         left.stream_id == right.stream_id &&
         left.lease_id == right.lease_id &&
         left.ground_request_nonce == right.ground_request_nonce &&
         left.vehicle_challenge_nonce ==
             right.vehicle_challenge_nonce;
}

void repair_crc(BulkNegotiationFrame& frame) {
  const std::uint16_t crc = BulkNegotiationWireCodec::crc16_ccitt_false(
      frame.data(), BulkNegotiationWireCodec::integrity_offset);
  frame[30] = static_cast<std::uint8_t>(crc & 0xFFU);
  frame[31] = static_cast<std::uint8_t>(crc >> 8U);
}

BulkNegotiationRequest request_sentinel() {
  return {0xDEADBEEFU, 0xA55AU, 0x5AA5U, 0xAABBCCDDEEFF0011ULL,
          42U,          77U,      0xCAFEU, 0xBABEU};
}

BulkNegotiationResponse response_sentinel() {
  return {BulkNegotiationResponseStatus::Busy,
          0xDEADBEEFU,
          0xA55AU,
          0U,
          0U,
          0x13579BDFU,
          0xBABEU};
}

BulkNegotiationIdentity identity_sentinel() {
  return {1U, 2U, 3U, 4U, 5U};
}

void test_request_golden_and_request_tag(TestReport& report) {
  constexpr std::array<std::uint8_t, 9U> check{{
      '1', '2', '3', '4', '5', '6', '7', '8', '9'}};
  report.check(BulkNegotiationWireCodec::crc32c(check.data(), check.size()) ==
                   0xE3069283U,
               "CRC32C reference vector changed");

  BulkNegotiationFrame encoded{};
  report.check(BulkNegotiationWireCodec::encode_request(kRequest, encoded) ==
                   BulkNegotiationWireStatus::FrameReady,
               "canonical VCBN request did not encode");
  report.check(encoded == kGoldenRequest,
               "VCBN request golden bytes changed");

  BulkNegotiationRequest decoded{};
  report.check(BulkNegotiationWireCodec::decode_request(encoded, decoded) ==
                   BulkNegotiationWireStatus::FrameReady &&
                   same_request(decoded, kRequest),
               "VCBN request did not round-trip exactly");

  std::uint32_t tag = 0U;
  report.check(BulkNegotiationWireCodec::derive_request_tag(encoded, tag) ==
                       BulkNegotiationWireStatus::RequestTagReady &&
                   tag == kRequestTag,
               "domain-separated request_tag vector changed");
}

void test_accept_golden_identity_and_transfer_tag(TestReport& report) {
  BulkNegotiationFrame encoded{};
  report.check(BulkNegotiationWireCodec::encode_response(kAccept, encoded) ==
                   BulkNegotiationWireStatus::FrameReady,
               "canonical VCBN Accept did not encode");
  report.check(encoded == kGoldenAccept,
               "VCBN Accept golden bytes changed");

  BulkNegotiationResponse decoded{};
  report.check(BulkNegotiationWireCodec::decode_response(encoded, decoded) ==
                       BulkNegotiationWireStatus::FrameReady &&
                   same_response(decoded, kAccept),
               "VCBN Accept did not round-trip exactly");
  report.check(BulkNegotiationWireCodec::validate_response_correlation(
                   kGoldenRequest, encoded) ==
                   BulkNegotiationWireStatus::CorrelatedResponse,
               "Accept did not correlate to the exact pending request");

  BulkNegotiationIdentity identity{};
  std::uint32_t transfer_tag = 0U;
  report.check(BulkNegotiationWireCodec::derive_accepted_transfer(
                   kGoldenRequest, encoded, identity, transfer_tag) ==
                   BulkNegotiationWireStatus::TransferReady,
               "accepted transfer identity was not derived");
  report.check(identity.session_id == 0x0000A1B2C3D499AAULL &&
                   identity.stream_id == 0x1122334455667788ULL &&
                   identity.lease_id == 0xA1B2C3D499AA1357ULL &&
                   identity.ground_request_nonce ==
                       0x0102030405060708ULL &&
                   identity.vehicle_challenge_nonce ==
                       0x8877665544332211ULL,
               "negotiated identity composition changed");
  report.check(transfer_tag == 0x27DA1DA2U,
               "domain-separated transfer_tag vector changed");

  std::uint32_t direct_tag = 0U;
  report.check(BulkNegotiationWireCodec::derive_transfer_tag(
                   identity, direct_tag) ==
                       BulkNegotiationWireStatus::TransferTagReady &&
                   direct_tag == transfer_tag,
               "direct transfer_tag derivation disagreed with handshake");
}

void test_reject_canonical_statuses(TestReport& report) {
  constexpr std::array<BulkNegotiationResponseStatus, 6U> rejects{{
      BulkNegotiationResponseStatus::UnsupportedProfile,
      BulkNegotiationResponseStatus::Busy,
      BulkNegotiationResponseStatus::WrongTarget,
      BulkNegotiationResponseStatus::IdentityExhausted,
      BulkNegotiationResponseStatus::EntropyUnavailable,
      BulkNegotiationResponseStatus::TagDerivationFailure}};

  for (const BulkNegotiationResponseStatus reason : rejects) {
    const BulkNegotiationResponse rejection{
        reason, 0xA1B2C3D4U, 0x99AAU, 0U, 0U, kRequestTag, 0xBBCCU};
    BulkNegotiationFrame frame{};
    BulkNegotiationResponse decoded{};
    report.check(BulkNegotiationWireCodec::encode_response(rejection, frame) ==
                         BulkNegotiationWireStatus::FrameReady &&
                     BulkNegotiationWireCodec::decode_response(
                         frame, decoded) ==
                         BulkNegotiationWireStatus::FrameReady &&
                     same_response(rejection, decoded),
                 "canonical Reject reason did not round-trip");
    report.check(BulkNegotiationWireCodec::validate_response_correlation(
                     kGoldenRequest, frame) ==
                     BulkNegotiationWireStatus::CorrelatedResponse,
                 "canonical Reject did not correlate to its request");
  }

  BulkNegotiationResponse noncanonical{
      BulkNegotiationResponseStatus::Busy,
      0xA1B2C3D4U,
      0x99AAU,
      1U,
      1U,
      kRequestTag,
      0xBBCCU};
  BulkNegotiationFrame unchanged = kGoldenRequest;
  report.check(BulkNegotiationWireCodec::encode_response(
                   noncanonical, unchanged) ==
                       BulkNegotiationWireStatus::InvalidResponse &&
                   unchanged == kGoldenRequest,
               "Reject with lease/challenge was not rejected atomically");

  BulkNegotiationFrame unknown_status = kGoldenAccept;
  unknown_status[7] = 7U;
  repair_crc(unknown_status);
  BulkNegotiationResponse output = response_sentinel();
  const BulkNegotiationResponse sentinel = output;
  report.check(BulkNegotiationWireCodec::decode_response(
                   unknown_status, output) ==
                       BulkNegotiationWireStatus::UnknownResponseStatus &&
                   same_response(output, sentinel),
               "unknown Reject status was accepted or changed output");
}

void test_corruption_unknown_values_and_atomic_outputs(TestReport& report) {
  for (std::size_t index = 0U; index < kGoldenRequest.size(); ++index) {
    BulkNegotiationFrame corrupted = kGoldenRequest;
    corrupted[index] ^= 0x01U;
    BulkNegotiationRequest output = request_sentinel();
    const BulkNegotiationRequest sentinel = output;
    report.check(BulkNegotiationWireCodec::decode_request(
                     corrupted, output) !=
                         BulkNegotiationWireStatus::FrameReady &&
                     same_request(output, sentinel),
                 "single-byte Request corruption escaped or changed output");
  }
  for (std::size_t index = 0U; index < kGoldenAccept.size(); ++index) {
    BulkNegotiationFrame corrupted = kGoldenAccept;
    corrupted[index] ^= 0x01U;
    BulkNegotiationResponse output = response_sentinel();
    const BulkNegotiationResponse sentinel = output;
    report.check(BulkNegotiationWireCodec::decode_response(
                     corrupted, output) !=
                         BulkNegotiationWireStatus::FrameReady &&
                     same_response(output, sentinel),
                 "single-byte Response corruption escaped or changed output");
  }

  struct SemanticMutation final {
    std::size_t offset;
    std::uint8_t value;
    BulkNegotiationWireStatus expected;
  };
  constexpr std::array<SemanticMutation, 4U> request_mutations{{
      {4U, 2U, BulkNegotiationWireStatus::UnknownVersion},
      {5U, 3U, BulkNegotiationWireStatus::UnknownKind},
      {6U, 2U, BulkNegotiationWireStatus::UnsupportedProfile},
      {7U, 1U, BulkNegotiationWireStatus::InvalidFlags}}};
  for (const SemanticMutation& mutation : request_mutations) {
    BulkNegotiationFrame frame = kGoldenRequest;
    frame[mutation.offset] = mutation.value;
    repair_crc(frame);
    BulkNegotiationRequest output = request_sentinel();
    const BulkNegotiationRequest sentinel = output;
    report.check(BulkNegotiationWireCodec::decode_request(frame, output) ==
                         mutation.expected &&
                     same_request(output, sentinel),
                 "unknown Request header value was not fail-closed");
  }

  BulkNegotiationRequest invalid = kRequest;
  invalid.request_sequence = 0U;
  BulkNegotiationFrame unchanged = kGoldenAccept;
  report.check(BulkNegotiationWireCodec::encode_request(invalid, unchanged) ==
                       BulkNegotiationWireStatus::InvalidRequest &&
                   unchanged == kGoldenAccept,
               "invalid Request encoding changed the destination");

  BulkNegotiationResponse invalid_accept = kAccept;
  invalid_accept.vehicle_challenge_nonce = 0U;
  unchanged = kGoldenRequest;
  report.check(BulkNegotiationWireCodec::encode_response(
                   invalid_accept, unchanged) ==
                       BulkNegotiationWireStatus::InvalidResponse &&
                   unchanged == kGoldenRequest,
               "invalid Accept encoding changed the destination");

  BulkNegotiationRequest request_output = request_sentinel();
  const BulkNegotiationRequest request_before = request_output;
  BulkNegotiationResponse response_output = response_sentinel();
  const BulkNegotiationResponse response_before = response_output;
  report.check(BulkNegotiationWireCodec::decode_request(
                   kGoldenAccept, request_output) ==
                       BulkNegotiationWireStatus::WrongKind &&
                   same_request(request_output, request_before),
               "Response was decoded as Request or changed output");
  report.check(BulkNegotiationWireCodec::decode_response(
                   kGoldenRequest, response_output) ==
                       BulkNegotiationWireStatus::WrongKind &&
                   same_response(response_output, response_before),
               "Request was decoded as Response or changed output");
}

void test_correlation_and_identity_fail_closed(TestReport& report) {
  const BulkNegotiationIdentity identity_before = identity_sentinel();
  constexpr std::uint32_t tag_before = 0xCAFEBABEU;

  const auto expect_invalid_request =
      [&](const BulkNegotiationRequest& invalid, const char* message) {
        BulkNegotiationFrame output = kGoldenAccept;
        report.check(BulkNegotiationWireCodec::encode_request(
                         invalid, output) ==
                             BulkNegotiationWireStatus::InvalidRequest &&
                         output == kGoldenAccept,
                     message);
      };
  BulkNegotiationRequest invalid_request = kRequest;
  invalid_request.ground_boot_id = 0U;
  expect_invalid_request(invalid_request,
                         "zero Ground boot identity was accepted");
  invalid_request = kRequest;
  invalid_request.ground_session_id = 0U;
  expect_invalid_request(invalid_request,
                         "zero Ground session identity was accepted");
  invalid_request = kRequest;
  invalid_request.request_sequence = 0U;
  expect_invalid_request(invalid_request,
                         "zero request sequence was accepted");
  invalid_request = kRequest;
  invalid_request.ground_nonce = 0U;
  expect_invalid_request(invalid_request,
                         "zero Ground nonce was accepted");
  invalid_request = kRequest;
  invalid_request.captured_vehicle_grant_session = 0U;
  expect_invalid_request(invalid_request,
                         "zero captured Vehicle session was accepted");

  const auto expect_invalid_response =
      [&](const BulkNegotiationResponse& invalid, const char* message) {
        BulkNegotiationFrame output = kGoldenRequest;
        report.check(BulkNegotiationWireCodec::encode_response(
                         invalid, output) ==
                             BulkNegotiationWireStatus::InvalidResponse &&
                         output == kGoldenRequest,
                     message);
      };
  BulkNegotiationResponse invalid_response = kAccept;
  invalid_response.vehicle_boot_id = 0U;
  expect_invalid_response(invalid_response,
                          "zero Vehicle boot identity was accepted");
  invalid_response = kAccept;
  invalid_response.vehicle_session_id = 0U;
  expect_invalid_response(invalid_response,
                          "zero Vehicle session identity was accepted");
  invalid_response = kAccept;
  invalid_response.lease_sequence = 0U;
  expect_invalid_response(invalid_response,
                          "zero Accept lease sequence was accepted");
  invalid_response = kAccept;
  invalid_response.vehicle_challenge_nonce = 0U;
  expect_invalid_response(invalid_response,
                          "zero Accept challenge nonce was accepted");
  invalid_response = kAccept;
  invalid_response.request_tag = 0U;
  expect_invalid_response(invalid_response,
                          "zero response request_tag was accepted");

  // This canonical-looking Request has a deliberately solved CRC32C result
  // of zero for the request-tag domain. Zero is reserved and must cause the
  // caller to rotate the nonce/sequence rather than activate bulk mode.
  BulkNegotiationRequest zero_request_tag = kRequest;
  zero_request_tag.captured_vehicle_grant_session = 0xEBA2U;
  zero_request_tag.captured_vehicle_grant_cycle = 0x9739U;
  BulkNegotiationFrame unchanged_request_output = kGoldenAccept;
  report.check(BulkNegotiationWireCodec::encode_request(
                   zero_request_tag, unchanged_request_output) ==
                       BulkNegotiationWireStatus::DerivedTagZero &&
                   unchanged_request_output == kGoldenAccept,
               "zero request_tag vector was emitted or changed output");

  BulkNegotiationFrame zero_request_tag_wire = kGoldenRequest;
  zero_request_tag_wire[26] = 0xA2U;
  zero_request_tag_wire[27] = 0xEBU;
  zero_request_tag_wire[28] = 0x39U;
  zero_request_tag_wire[29] = 0x97U;
  repair_crc(zero_request_tag_wire);
  BulkNegotiationRequest decoded_request = request_sentinel();
  const BulkNegotiationRequest decoded_request_before = decoded_request;
  report.check(BulkNegotiationWireCodec::decode_request(
                   zero_request_tag_wire, decoded_request) ==
                       BulkNegotiationWireStatus::DerivedTagZero &&
                   same_request(decoded_request, decoded_request_before),
               "zero request_tag wire vector was accepted or changed output");

  const auto expect_derivation_failure =
      [&](BulkNegotiationFrame response,
          BulkNegotiationWireStatus expected, const char* message) {
        BulkNegotiationIdentity identity = identity_before;
        std::uint32_t tag = tag_before;
        report.check(BulkNegotiationWireCodec::derive_accepted_transfer(
                         kGoldenRequest, response, identity, tag) == expected &&
                         same_identity(identity, identity_before) &&
                         tag == tag_before,
                     message);
      };

  BulkNegotiationFrame wrong_tag = kGoldenAccept;
  wrong_tag[24] ^= 1U;
  repair_crc(wrong_tag);
  expect_derivation_failure(wrong_tag,
                            BulkNegotiationWireStatus::RequestTagMismatch,
                            "wrong request_tag did not fail atomically");

  BulkNegotiationFrame wrong_session = kGoldenAccept;
  wrong_session[12] ^= 1U;
  repair_crc(wrong_session);
  expect_derivation_failure(wrong_session,
                            BulkNegotiationWireStatus::GrantIdentityMismatch,
                            "wrong grant session did not fail atomically");

  BulkNegotiationFrame wrong_cycle = kGoldenAccept;
  wrong_cycle[28] ^= 1U;
  repair_crc(wrong_cycle);
  expect_derivation_failure(wrong_cycle,
                            BulkNegotiationWireStatus::GrantIdentityMismatch,
                            "wrong grant cycle did not fail atomically");

  BulkNegotiationResponse rejection{
      BulkNegotiationResponseStatus::Busy, 0xA1B2C3D4U, 0x99AAU, 0U, 0U,
      kRequestTag, 0xBBCCU};
  BulkNegotiationFrame reject_frame{};
  report.check(BulkNegotiationWireCodec::encode_response(
                   rejection, reject_frame) ==
                   BulkNegotiationWireStatus::FrameReady,
               "Reject fixture did not encode");
  expect_derivation_failure(reject_frame,
                            BulkNegotiationWireStatus::PeerRejected,
                            "Reject incorrectly created a transfer identity");

  BulkNegotiationIdentity invalid_identity{
      0U, 0x1122334455667788ULL, 0xA1B2C3D499AA1357ULL,
      0x0102030405060708ULL, 0x8877665544332211ULL};
  std::uint32_t tag = tag_before;
  report.check(BulkNegotiationWireCodec::derive_transfer_tag(
                   invalid_identity, tag) ==
                       BulkNegotiationWireStatus::InvalidIdentity &&
                   tag == tag_before,
               "zero identity produced a tag or changed output");

  BulkNegotiationIdentity zero_transfer_tag{
      0x0000A1B2C3D499AAULL,
      0x1122334455667788ULL,
      0xA1B2C3D499AA1357ULL,
      0x0102030405060708ULL,
      0x64876F5844332211ULL};
  tag = tag_before;
  report.check(BulkNegotiationWireCodec::derive_transfer_tag(
                   zero_transfer_tag, tag) ==
                       BulkNegotiationWireStatus::DerivedTagZero &&
                   tag == tag_before,
               "zero transfer_tag vector was emitted or changed output");

  std::uint32_t request_tag = tag_before;
  report.check(BulkNegotiationWireCodec::derive_request_tag(
                   kGoldenAccept, request_tag) ==
                       BulkNegotiationWireStatus::WrongKind &&
                   request_tag == tag_before,
               "non-Request produced request_tag or changed output");
}

}  // namespace

TestReport run_bulk_negotiation_codec_test(const std::string& test_id,
                                            std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-BULK-NEG-WIRE-001") {
    test_request_golden_and_request_tag(report);
  } else if (test_id == "UT-BULK-NEG-WIRE-002") {
    test_accept_golden_identity_and_transfer_tag(report);
  } else if (test_id == "UT-BULK-NEG-WIRE-003") {
    test_reject_canonical_statuses(report);
  } else if (test_id == "UT-BULK-NEG-WIRE-004") {
    test_corruption_unknown_values_and_atomic_outputs(report);
  } else if (test_id == "UT-BULK-NEG-WIRE-005") {
    test_correlation_and_identity_fail_closed(report);
  } else {
    report.check(false, "unknown bulk negotiation codec test ID");
  }

  report.trace.record({0U, "host", "BULK_NEG_WIRE", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
