#include "../../../firmware/high_speed/terminal_ack_producer.hpp"
#include "../../../firmware/high_speed/terminal_ack_bridge.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <type_traits>

namespace {

using vc_lora::BulkDataFragment;
using vc_lora::BulkDataStreamDecoder;
using vc_lora::BulkDataStreamLifecycleStatus;
using vc_lora::BulkDataStreamStatus;
using vc_lora::BulkDataWireStatus;
using vc_lora::BulkHeartbeatSlaLedger;
using vc_lora::BulkHeartbeatSlaStatus;
using vc_lora::BulkNegotiationIdentity;
using vc_lora::BulkNegotiationWireCodec;
using vc_lora::BulkNegotiationWireStatus;
using vc_lora::BulkSessionTerminalEvidence;
using vc_lora::BulkTranscriptLedger;
using vc_lora::BulkTranscriptStatus;
using vc_lora::EncodedBulkDataFrame;
using vc_lora::MavlinkFrame;
using vc_lora::encode_bulk_data_frame;
using vc_lora::encode_mavlink_v2;
using vc_lora::experimental::GroundTerminalAckProducer;
using vc_lora::experimental::GroundUsbCommitStatus;
using vc_lora::experimental::GroundUsbHostCommitOwner;
using vc_lora::experimental::TerminalAckBindingOwner;
using vc_lora::experimental::TerminalAckBridgeStatus;
using vc_lora::experimental::TerminalAckError;
using vc_lora::experimental::TerminalAckEvidenceBridge;
using vc_lora::experimental::TerminalAckExpectedEvidence;
using vc_lora::experimental::TerminalAckFragment;
using vc_lora::experimental::TerminalAckFragments;
using vc_lora::experimental::TerminalAckProducerStatus;
using vc_lora::experimental::TerminalAckReassembler;
using vc_lora::experimental::TerminalAckRecord;
using vc_lora::experimental::TerminalAckSessionBinding;
using vc_lora::experimental::TerminalAckWireCodec;
using vc_lora::experimental::VehicleTerminalAckExpectedFactory;

using ProduceSignature = TerminalAckProducerStatus (
    GroundTerminalAckProducer::*)(
    const BulkDataStreamDecoder&, const BulkTranscriptLedger&,
    const BulkHeartbeatSlaLedger&, GroundUsbHostCommitOwner&,
    const BulkNegotiationIdentity&,
    TerminalAckRecord&, TerminalAckFragments&) noexcept;
using ExpectedSignature = TerminalAckProducerStatus (
    VehicleTerminalAckExpectedFactory::*)(
    const BulkNegotiationIdentity&, const BulkTranscriptLedger&,
    TerminalAckExpectedEvidence&) noexcept;

static_assert(std::is_same_v<decltype(&GroundTerminalAckProducer::produce),
                             ProduceSignature>);
static_assert(std::is_same_v<
              decltype(&VehicleTerminalAckExpectedFactory::make_expected),
              ExpectedSignature>);
static_assert(!std::is_copy_constructible_v<TerminalAckBindingOwner>);
static_assert(!std::is_move_constructible_v<TerminalAckBindingOwner>);
static_assert(!std::is_copy_constructible_v<GroundTerminalAckProducer>);
static_assert(!std::is_move_constructible_v<GroundTerminalAckProducer>);
static_assert(!std::is_copy_constructible_v<GroundUsbHostCommitOwner>);
static_assert(!std::is_move_constructible_v<GroundUsbHostCommitOwner>);
static_assert(!std::is_copy_constructible_v<
              VehicleTerminalAckExpectedFactory>);
static_assert(!std::is_move_constructible_v<
              VehicleTerminalAckExpectedFactory>);

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

constexpr BulkNegotiationIdentity identity_a() noexcept {
  return BulkNegotiationIdentity{
      0x0102030405060708ULL,
      0x1112131415161718ULL,
      0x2122232425262728ULL,
      0x3132333435363738ULL,
      0x4142434445464748ULL};
}

// Independently solved CRC-32C collision: this full identity differs from A,
// but both canonical identities derive transfer_tag 0x52723680.
constexpr BulkNegotiationIdentity transfer_tag_collision_identity() noexcept {
  return BulkNegotiationIdentity{
      0x0102030405060709ULL,
      0x1112131415161718ULL,
      0x2122232425262728ULL,
      0x3132333435363738ULL,
      0x728EF8F845464748ULL};
}

constexpr BulkNegotiationIdentity zero_tag_identity() noexcept {
  return BulkNegotiationIdentity{
      0x0102030405060708ULL,
      0x1112131415161718ULL,
      0x2122232425262728ULL,
      0x3132333435363738ULL,
      0x32AF69D145464748ULL};
}

bool identities_equal(const BulkNegotiationIdentity& left,
                      const BulkNegotiationIdentity& right) noexcept {
  return left.session_id == right.session_id &&
         left.stream_id == right.stream_id &&
         left.lease_id == right.lease_id &&
         left.ground_request_nonce == right.ground_request_nonce &&
         left.vehicle_challenge_nonce == right.vehicle_challenge_nonce;
}

std::uint32_t tag_for(const BulkNegotiationIdentity& identity) noexcept {
  std::uint32_t tag = 0U;
  const BulkNegotiationWireStatus status =
      BulkNegotiationWireCodec::derive_transfer_tag(identity, tag);
  return status == BulkNegotiationWireStatus::TransferTagReady ? tag : 0U;
}

MavlinkFrame make_parameter(std::uint16_t index, float value = 1.0F,
                            std::uint16_t parameter_count = 932U) {
  std::array<std::uint8_t, 25U> payload{};
  std::uint32_t value_bits = 0U;
  static_assert(sizeof(value_bits) == sizeof(value));
  std::memcpy(&value_bits, &value, sizeof(value_bits));
  for (std::size_t byte = 0U; byte < 4U; ++byte) {
    payload[byte] = static_cast<std::uint8_t>(
        (value_bits >> static_cast<unsigned int>(byte * 8U)) & 0xFFU);
  }
  payload[4] = static_cast<std::uint8_t>(parameter_count & 0xFFU);
  payload[5] = static_cast<std::uint8_t>(parameter_count >> 8U);
  payload[6] = static_cast<std::uint8_t>(index & 0xFFU);
  payload[7] = static_cast<std::uint8_t>(index >> 8U);
  constexpr std::array<std::uint8_t, 8U> marker{{
      'V', 'C', 'T', 'A', '-', 'R', '1', '9'}};
  for (std::size_t byte = 0U; byte < marker.size(); ++byte) {
    payload[8U + byte] = marker[byte];
  }
  payload[24] = 9U;

  MavlinkFrame frame{};
  if (!encode_mavlink_v2(static_cast<std::uint8_t>(index & 0xFFU),
                         1U, 1U, 22U, payload.data(), payload.size(), frame) ||
      frame.size != 37U) {
    frame = MavlinkFrame{};
  }
  return frame;
}

MavlinkFrame make_heartbeat(std::uint8_t sequence) {
  constexpr std::array<std::uint8_t, 9U> payload{{
      0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U}};
  MavlinkFrame frame{};
  if (!encode_mavlink_v2(sequence, 1U, 1U, 0U, payload.data(),
                         payload.size(), frame) ||
      frame.size != 21U) {
    frame = MavlinkFrame{};
  }
  return frame;
}

BulkDataStreamStatus feed_fragment(BulkDataStreamDecoder& decoder,
                                   const BulkDataFragment& fragment,
                                   MavlinkFrame& output) {
  BulkDataStreamStatus status = BulkDataStreamStatus::NeedMore;
  for (const std::uint8_t byte : fragment) {
    status = decoder.push_byte(byte, output);
  }
  return status;
}

bool feed_frame(BulkDataStreamDecoder& decoder, const MavlinkFrame& frame,
                std::uint16_t& ordinal, MavlinkFrame& delivered) {
  EncodedBulkDataFrame encoded{};
  if (frame.size == 0U ||
      encode_bulk_data_frame(frame, decoder.expected_transfer_tag(), ordinal,
                             encoded) != BulkDataWireStatus::FrameReady ||
      encoded.fragment_count != 2U) {
    return false;
  }
  const BulkDataStreamStatus head =
      feed_fragment(decoder, encoded.fragments[0], delivered);
  const BulkDataStreamStatus tail =
      feed_fragment(decoder, encoded.fragments[1], delivered);
  ordinal = static_cast<std::uint16_t>(ordinal + 2U);
  return head == BulkDataStreamStatus::FragmentAccepted &&
         tail == BulkDataStreamStatus::FrameReady;
}

bool build_transcript(BulkTranscriptLedger& ledger,
                      std::uint32_t heartbeat_count,
                      bool mutate_parameter) {
  for (std::uint32_t heartbeat = 0U; heartbeat < heartbeat_count;
       ++heartbeat) {
    if (ledger.append(make_heartbeat(
            static_cast<std::uint8_t>(100U + heartbeat))) !=
        BulkTranscriptStatus::EntryAccepted) {
      return false;
    }
  }
  for (std::uint16_t index = 0U; index < 932U; ++index) {
    const float value = mutate_parameter && index == 456U ? 2.0F : 1.0F;
    if (ledger.append(make_parameter(index, value)) !=
        BulkTranscriptStatus::EntryAccepted) {
      return false;
    }
  }
  return true;
}

bool build_decoder(BulkDataStreamDecoder& decoder,
                   std::uint16_t parameter_count,
                   std::uint32_t heartbeat_count) {
  std::uint16_t ordinal = 0U;
  MavlinkFrame delivered{};
  for (std::uint32_t heartbeat = 0U; heartbeat < heartbeat_count;
       ++heartbeat) {
    if (!feed_frame(decoder,
                    make_heartbeat(static_cast<std::uint8_t>(100U + heartbeat)),
                    ordinal, delivered)) {
      return false;
    }
  }
  for (std::uint16_t index = 0U; index < parameter_count; ++index) {
    if (!feed_frame(decoder, make_parameter(index, 1.0F, parameter_count),
                    ordinal, delivered)) {
      return false;
    }
  }
  return decoder.finish();
}

bool build_decoder_and_transcripts(BulkDataStreamDecoder& decoder,
                                   BulkTranscriptLedger& ground,
                                   BulkTranscriptLedger& vehicle,
                                   std::uint32_t heartbeat_count,
                                   bool mutate_vehicle) {
  std::uint16_t ordinal = 0U;
  MavlinkFrame delivered{};
  for (std::uint32_t heartbeat = 0U; heartbeat < heartbeat_count;
       ++heartbeat) {
    const MavlinkFrame source =
        make_heartbeat(static_cast<std::uint8_t>(100U + heartbeat));
    if (!feed_frame(decoder, source, ordinal, delivered) ||
        ground.append(delivered) != BulkTranscriptStatus::EntryAccepted ||
        vehicle.append(source) != BulkTranscriptStatus::EntryAccepted) {
      return false;
    }
  }
  for (std::uint16_t index = 0U; index < 932U; ++index) {
    const MavlinkFrame source = make_parameter(index);
    const MavlinkFrame vehicle_frame =
        mutate_vehicle && index == 456U ? make_parameter(index, 2.0F)
                                        : source;
    if (!feed_frame(decoder, source, ordinal, delivered) ||
        ground.append(delivered) != BulkTranscriptStatus::EntryAccepted ||
        vehicle.append(vehicle_frame) !=
            BulkTranscriptStatus::EntryAccepted) {
      return false;
    }
  }
  return decoder.finish();
}

enum class SlaScenario : std::uint8_t {
  ExactBoundaries = 0U,
  ValidTwelveHeartbeats,
  FirstGapPlusOne,
  MaximumGapPlusOne,
  PostGapPlusOne,
  ElapsedPlusOne,
};

bool build_sla(BulkHeartbeatSlaLedger& ledger, SlaScenario scenario) {
  bool setup =
      ledger.capture_baseline(0U) ==
          BulkHeartbeatSlaStatus::BaselineCaptured &&
      ledger.start_request(0U) == BulkHeartbeatSlaStatus::RequestStarted;
  if (!setup) {
    return false;
  }
  switch (scenario) {
    case SlaScenario::ExactBoundaries:
      for (std::uint64_t time = 2500U; time <= 27500U; time += 2500U) {
        setup = setup &&
                ledger.accept_heartbeat(time) ==
                    BulkHeartbeatSlaStatus::HeartbeatAccepted;
      }
      return setup &&
             ledger.complete_final_parameter(30000U) ==
                 BulkHeartbeatSlaStatus::EvidenceReady;
    case SlaScenario::ValidTwelveHeartbeats:
      setup = setup &&
              ledger.accept_heartbeat(1000U) ==
                  BulkHeartbeatSlaStatus::HeartbeatAccepted;
      for (std::uint64_t time = 2500U; time <= 27500U; time += 2500U) {
        setup = setup &&
                ledger.accept_heartbeat(time) ==
                    BulkHeartbeatSlaStatus::HeartbeatAccepted;
      }
      return setup &&
             ledger.complete_final_parameter(30000U) ==
                 BulkHeartbeatSlaStatus::EvidenceReady;
    case SlaScenario::FirstGapPlusOne:
      return ledger.accept_heartbeat(2501U) ==
                 BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded &&
             ledger.fail_closed();
    case SlaScenario::MaximumGapPlusOne:
      return ledger.accept_heartbeat(1000U) ==
                 BulkHeartbeatSlaStatus::HeartbeatAccepted &&
             ledger.accept_heartbeat(3501U) ==
                 BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded &&
             ledger.fail_closed();
    case SlaScenario::PostGapPlusOne:
      return ledger.accept_heartbeat(1000U) ==
                 BulkHeartbeatSlaStatus::HeartbeatAccepted &&
             ledger.complete_final_parameter(3501U) ==
                 BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded &&
             ledger.fail_closed();
    case SlaScenario::ElapsedPlusOne:
      for (std::uint64_t time = 2500U; time <= 30000U; time += 2500U) {
        setup = setup &&
                ledger.accept_heartbeat(time) ==
                    BulkHeartbeatSlaStatus::HeartbeatAccepted;
      }
      return setup &&
             ledger.complete_final_parameter(30001U) ==
                 BulkHeartbeatSlaStatus::CompletionDeadlineExceeded &&
             ledger.fail_closed();
  }
  return false;
}

struct CompleteSession final {
  BulkNegotiationIdentity identity;
  std::uint32_t tag;
  BulkDataStreamDecoder decoder;
  BulkTranscriptLedger ground_transcript;
  BulkTranscriptLedger vehicle_transcript;
  BulkHeartbeatSlaLedger sla;
  GroundUsbHostCommitOwner commit;

  explicit CompleteSession(
      const BulkNegotiationIdentity& value,
      std::uint32_t decoder_tag = 0U,
      std::uint32_t transcript_tag = 0U,
      std::uint32_t sla_tag = 0U) noexcept
      : identity(value),
        tag(tag_for(value)),
        decoder(decoder_tag == 0U ? tag : decoder_tag),
        ground_transcript(value,
                          transcript_tag == 0U ? tag : transcript_tag),
        vehicle_transcript(value,
                           transcript_tag == 0U ? tag : transcript_tag),
        sla(sla_tag == 0U ? tag : sla_tag) {}

  bool build(bool seal_decoder = true, bool seal_ground = true,
             bool seal_vehicle = true, bool seal_sla = true,
             bool mutate_vehicle = false) {
    if (tag == 0U ||
        !build_decoder_and_transcripts(decoder, ground_transcript,
                                       vehicle_transcript, 11U,
                                       mutate_vehicle) ||
        !build_sla(sla, SlaScenario::ExactBoundaries)) {
      return false;
    }
    bool okay = true;
    if (seal_decoder) {
      okay = decoder.seal_session() ==
                 BulkDataStreamLifecycleStatus::Sealed &&
             okay;
    }
    if (seal_ground) {
      okay = ground_transcript.seal_session() ==
                 BulkTranscriptStatus::Sealed &&
             okay;
    }
    if (seal_vehicle) {
      okay = vehicle_transcript.seal_session() ==
                 BulkTranscriptStatus::Sealed &&
             okay;
    }
    if (seal_sla) {
      okay = sla.seal_session() == BulkHeartbeatSlaStatus::Sealed && okay;
    }
    if (okay) {
      okay = commit.arm(identity, tag, 0U, 7U) ==
                 GroundUsbCommitStatus::Armed &&
             commit.stage_final_write(make_parameter(931U), 42U, 7U,
                                      29'999U) ==
                 GroundUsbCommitStatus::FinalWriteStaged &&
             commit.complete_host_visible(42U, 7U, 30'000U) ==
                 GroundUsbCommitStatus::HostCommitReady;
    }
    return okay;
  }
};

void dirty(TerminalAckRecord& record, TerminalAckFragments& fragments) {
  record.record_id = 1U;
  record.identity.session_id = 2U;
  record.final_parameter_count = 3U;
  record.receiver_batch = 4U;
  record.transcript_digest.fill(5U);
  for (TerminalAckFragment& fragment : fragments) {
    fragment.fill(0xA5U);
  }
}

bool is_zero(const TerminalAckRecord& record,
             const TerminalAckFragments& fragments) {
  bool zero =
      record.record_id == 0U && record.identity.session_id == 0U &&
      record.identity.stream_id == 0U && record.identity.lease_id == 0U &&
      record.identity.ground_request_nonce == 0U &&
      record.identity.vehicle_terminal_challenge_nonce == 0U &&
      record.final_parameter_count == 0U &&
      record.final_global_chunk_ordinal == 0U &&
      record.raw_mavlink_bytes == 0U && record.wire_chunk_count == 0U &&
      record.wire_bytes == 0U &&
      record.request_to_last_parameter_elapsed_ms == 0U &&
      record.heartbeat_count == 0U &&
      record.last_heartbeat_request_id == 0U &&
      record.first_heartbeat_gap_ms == 0U &&
      record.max_heartbeat_gap_ms == 0U &&
      record.post_heartbeat_gap_ms == 0U && record.receiver_batch == 0U &&
      record.receiver_revision == 0U;
  for (const std::uint8_t byte : record.transcript_digest) {
    zero = zero && byte == 0U;
  }
  for (const TerminalAckFragment& fragment : fragments) {
    for (const std::uint8_t byte : fragment) {
      zero = zero && byte == 0U;
    }
  }
  return zero;
}

void dirty(TerminalAckExpectedEvidence& expected) {
  expected.expected_record_id = 1U;
  expected.identity.session_id = 2U;
  expected.final_parameter_count = 3U;
  expected.receiver_batch = 4U;
  expected.transcript_digest.fill(5U);
}

bool is_zero(const TerminalAckExpectedEvidence& expected) {
  bool zero =
      expected.expected_record_id == 0U &&
      expected.identity.session_id == 0U &&
      expected.identity.stream_id == 0U &&
      expected.identity.lease_id == 0U &&
      expected.identity.ground_request_nonce == 0U &&
      expected.identity.vehicle_terminal_challenge_nonce == 0U &&
      expected.final_parameter_count == 0U &&
      expected.final_global_chunk_ordinal == 0U &&
      expected.raw_mavlink_bytes == 0U &&
      expected.wire_chunk_count == 0U && expected.wire_bytes == 0U &&
      expected.maximum_request_to_last_parameter_elapsed_ms == 0U &&
      expected.heartbeat_count == 0U &&
      expected.last_heartbeat_request_id == 0U &&
      expected.maximum_heartbeat_gap_ms == 0U &&
      expected.receiver_batch == 0U && expected.receiver_revision == 0U;
  for (const std::uint8_t byte : expected.transcript_digest) {
    zero = zero && byte == 0U;
  }
  return zero;
}

bool binding_is_zero(const TerminalAckSessionBinding& binding) {
  return binding.identity.session_id == 0U &&
         binding.identity.stream_id == 0U &&
         binding.identity.lease_id == 0U &&
         binding.identity.ground_request_nonce == 0U &&
         binding.identity.vehicle_challenge_nonce == 0U &&
         binding.transfer_tag == 0U && binding.record_id == 0U &&
         binding.receiver_batch == 0U && binding.receiver_revision == 0U;
}

TerminalAckError push_all(TerminalAckReassembler& reassembler,
                          const TerminalAckFragments& fragments) {
  TerminalAckError status = TerminalAckError::None;
  for (const TerminalAckFragment& fragment : fragments) {
    status = reassembler.push(fragment);
    if (status != TerminalAckError::None) {
      break;
    }
  }
  return status;
}

void expect_producer_failure(
    GroundTerminalAckProducer& producer,
    const BulkDataStreamDecoder& decoder,
    const BulkTranscriptLedger& transcript,
    const BulkHeartbeatSlaLedger& sla,
    GroundUsbHostCommitOwner& commit,
    const BulkNegotiationIdentity& identity,
    TerminalAckProducerStatus wanted) {
  TerminalAckRecord record{};
  TerminalAckFragments fragments{};
  dirty(record, fragments);
  CHECK(producer.produce(decoder, transcript, sla, commit, identity, record,
                         fragments) == wanted);
  CHECK(is_zero(record, fragments));
}

void expect_factory_failure(
    VehicleTerminalAckExpectedFactory& factory,
    const BulkNegotiationIdentity& identity,
    const BulkTranscriptLedger& transcript,
    TerminalAckProducerStatus wanted) {
  TerminalAckExpectedEvidence expected{};
  dirty(expected);
  CHECK(factory.make_expected(identity, transcript, expected) == wanted);
  CHECK(is_zero(expected));
}

void test_deterministic_binding_and_alias_rejection() {
  const BulkNegotiationIdentity first = identity_a();
  const BulkNegotiationIdentity collision =
      transfer_tag_collision_identity();
  CHECK(!identities_equal(first, collision));
  CHECK(tag_for(first) == 0x52723680U);
  CHECK(tag_for(collision) == tag_for(first));

  TerminalAckBindingOwner ground_owner{};
  TerminalAckBindingOwner vehicle_owner{};
  TerminalAckSessionBinding ground{};
  TerminalAckSessionBinding vehicle{};
  CHECK(ground_owner.bind(first, ground) ==
        TerminalAckProducerStatus::BindingReady);
  CHECK(vehicle_owner.bind(first, vehicle) ==
        TerminalAckProducerStatus::BindingReady);
  CHECK(ground.transfer_tag == vehicle.transfer_tag);
  CHECK(ground.record_id == vehicle.record_id);
  CHECK(ground.receiver_batch == vehicle.receiver_batch);
  CHECK(ground.receiver_revision == vehicle.receiver_revision);
  CHECK(ground.record_id != 0U && ground.receiver_batch != 0U &&
        ground.receiver_revision != 0U);
  CHECK(ground.record_id != ground.receiver_batch &&
        ground.record_id != ground.receiver_revision &&
        ground.receiver_batch != ground.receiver_revision);
  CHECK(TerminalAckWireCodec::record_tag(ground.record_id) != 0U);

  ground = TerminalAckSessionBinding{};
  ground.record_id = 9U;
  CHECK(ground_owner.bind(first, ground) ==
        TerminalAckProducerStatus::IdentityReuse);
  CHECK(binding_is_zero(ground));

  TerminalAckBindingOwner invalid_owner{};
  ground.record_id = 9U;
  CHECK(invalid_owner.bind(BulkNegotiationIdentity{}, ground) ==
        TerminalAckProducerStatus::InvalidIdentity);
  CHECK(binding_is_zero(ground));
  CHECK(invalid_owner.bind(zero_tag_identity(), ground) ==
        TerminalAckProducerStatus::TransferTagDerivationFailed);
  CHECK(binding_is_zero(ground));

  TerminalAckBindingOwner collision_owner{};
  CHECK(collision_owner.bind(first, ground) ==
        TerminalAckProducerStatus::BindingReady);
  ground.record_id = 9U;
  CHECK(collision_owner.bind(collision, ground) ==
        TerminalAckProducerStatus::CollisionAlias);
  CHECK(binding_is_zero(ground));
}

void test_one_shot_ground_usb_host_commit_owner() {
  const BulkNegotiationIdentity identity = identity_a();
  const std::uint32_t tag = tag_for(identity);
  GroundUsbHostCommitOwner owner{};
  CHECK(owner.arm(identity, tag, 100U, 9U) ==
        GroundUsbCommitStatus::Armed);
  CHECK(owner.stage_final_write(make_parameter(930U), 7U, 9U, 200U) ==
        GroundUsbCommitStatus::InvalidFinalParameter);
  CHECK(owner.fail_closed());

  GroundUsbHostCommitOwner loss{};
  CHECK(loss.arm(identity, tag, 100U, 9U) ==
        GroundUsbCommitStatus::Armed);
  CHECK(loss.stage_final_write(make_parameter(931U), 7U, 10U, 200U) ==
        GroundUsbCommitStatus::TxLossDetected);
  CHECK(loss.fail_closed());

  GroundUsbHostCommitOwner wrong_token{};
  CHECK(wrong_token.arm(identity, tag, 100U, 9U) ==
        GroundUsbCommitStatus::Armed);
  CHECK(wrong_token.stage_final_write(make_parameter(931U), 7U, 9U, 200U) ==
        GroundUsbCommitStatus::FinalWriteStaged);
  CHECK(wrong_token.complete_host_visible(8U, 9U, 201U) ==
        GroundUsbCommitStatus::InvalidToken);
  CHECK(wrong_token.fail_closed());

  GroundUsbHostCommitOwner late{};
  CHECK(late.arm(identity, tag, 100U, 9U) ==
        GroundUsbCommitStatus::Armed);
  CHECK(late.stage_final_write(make_parameter(931U), 7U, 9U, 30'100U) ==
        GroundUsbCommitStatus::FinalWriteStaged);
  CHECK(late.complete_host_visible(7U, 9U, 30'101U) ==
        GroundUsbCommitStatus::CompletionDeadlineExceeded);
  CHECK(late.fail_closed());

  CompleteSession complete{identity};
  CHECK(complete.build());
  GroundTerminalAckProducer producer{};
  GroundUsbHostCommitOwner mismatched_epoch{};
  CHECK(mismatched_epoch.arm(identity, tag, 1U, 9U) ==
        GroundUsbCommitStatus::Armed);
  CHECK(mismatched_epoch.stage_final_write(make_parameter(931U), 7U, 9U,
                                           29'999U) ==
        GroundUsbCommitStatus::FinalWriteStaged);
  CHECK(mismatched_epoch.complete_host_visible(7U, 9U, 30'000U) ==
        GroundUsbCommitStatus::HostCommitReady);
  expect_producer_failure(producer, complete.decoder,
                          complete.ground_transcript, complete.sla,
                          mismatched_epoch, identity,
                          TerminalAckProducerStatus::HostCommitMismatch);
  CHECK(mismatched_epoch.ready() && !mismatched_epoch.consumed());
}

void test_full_932_round_trip_and_exact_boundaries() {
  CompleteSession session{identity_a()};
  CHECK(session.build());
  CHECK(session.decoder.parameter_count() == 932U);
  CHECK(session.decoder.parameter_fragment_count() == 1864U);
  CHECK(session.decoder.raw_parameter_bytes() == 34484U);
  CHECK(session.decoder.heartbeat_count() == 11U);
  CHECK(session.decoder.total_fragment_count() == 1886U);
  CHECK(session.decoder.next_wire_ordinal() == 1886U);

  GroundTerminalAckProducer producer{};
  VehicleTerminalAckExpectedFactory factory{};
  TerminalAckRecord record{};
  TerminalAckFragments fragments{};
  TerminalAckExpectedEvidence expected{};
  CHECK(producer.produce(session.decoder, session.ground_transcript,
                         session.sla, session.commit, session.identity, record,
                         fragments) == TerminalAckProducerStatus::RecordReady);
  CHECK(factory.make_expected(session.identity, session.vehicle_transcript,
                              expected) ==
        TerminalAckProducerStatus::ExpectedReady);

  CHECK(record.record_id == expected.expected_record_id);
  CHECK(record.receiver_batch == expected.receiver_batch);
  CHECK(record.receiver_revision == expected.receiver_revision);
  CHECK(record.transcript_digest == expected.transcript_digest);
  CHECK(record.final_parameter_count == 932U);
  CHECK(record.wire_chunk_count == 1864U);
  CHECK(record.raw_mavlink_bytes == 34484U);
  CHECK(record.wire_bytes == 59648U);
  CHECK(record.final_global_chunk_ordinal == 1863U);
  CHECK(record.request_to_last_parameter_elapsed_ms == 30000U);
  CHECK(record.first_heartbeat_gap_ms == 2500U);
  CHECK(record.max_heartbeat_gap_ms == 2500U);
  CHECK(record.post_heartbeat_gap_ms == 2500U);
  CHECK(record.heartbeat_count == 11U &&
        record.last_heartbeat_request_id == 11U);

  TerminalAckReassembler reassembler(expected);
  CHECK(push_all(reassembler, fragments) == TerminalAckError::None);
  CHECK(reassembler.finish() == TerminalAckError::None);
  BulkSessionTerminalEvidence core{};
  CHECK(TerminalAckEvidenceBridge::consume(reassembler, session.identity,
                                           core) ==
        TerminalAckBridgeStatus::EvidenceReady);
  CHECK(core.transfer_tag == session.tag && core.parameter_count == 932U &&
        core.parameter_fragment_count == 1864U &&
        core.raw_parameter_bytes == 34484U &&
        core.heartbeat_count == 11U && core.ground_stream_complete &&
        core.final_parameter_usb_committed);

  TerminalAckExpectedEvidence wrong_record_epoch = expected;
  wrong_record_epoch.expected_record_id ^= 1ULL;
  TerminalAckReassembler wrong_epoch(wrong_record_epoch);
  CHECK(push_all(wrong_epoch, fragments) == TerminalAckError::WrongRecordId);
  CHECK(wrong_epoch.failed());

  const BulkNegotiationIdentity other_identity =
      transfer_tag_collision_identity();
  BulkTranscriptLedger other_transcript{other_identity, session.tag};
  CHECK(build_transcript(other_transcript, 11U, false));
  CHECK(other_transcript.seal_session() == BulkTranscriptStatus::Sealed);
  VehicleTerminalAckExpectedFactory other_factory{};
  TerminalAckExpectedEvidence other_expected{};
  CHECK(other_factory.make_expected(other_identity, other_transcript,
                                     other_expected) ==
        TerminalAckProducerStatus::ExpectedReady);
  CHECK(other_expected.expected_record_id != record.record_id);
  TerminalAckReassembler other_session(other_expected);
  CHECK(push_all(other_session, fragments) == TerminalAckError::WrongRecordId);
  CHECK(other_session.failed());

  dirty(record, fragments);
  CHECK(producer.produce(session.decoder, session.ground_transcript,
                         session.sla, session.commit, session.identity, record,
                         fragments) ==
        TerminalAckProducerStatus::HostCommitNotReady);
  CHECK(is_zero(record, fragments));
  dirty(expected);
  CHECK(factory.make_expected(session.identity, session.vehicle_transcript,
                              expected) ==
        TerminalAckProducerStatus::IdentityReuse);
  CHECK(is_zero(expected));
}

void test_ground_rejects_identity_tag_count_and_heartbeat_mismatch() {
  CompleteSession good{identity_a()};
  CHECK(good.build());
  GroundTerminalAckProducer producer{};

  expect_producer_failure(producer, good.decoder, good.ground_transcript,
                          good.sla, good.commit, BulkNegotiationIdentity{},
                          TerminalAckProducerStatus::InvalidIdentity);
  expect_producer_failure(
      producer, good.decoder, good.ground_transcript, good.sla, good.commit,
      zero_tag_identity(),
      TerminalAckProducerStatus::TransferTagDerivationFailed);

  BulkDataStreamDecoder wrong_decoder_tag{good.tag + 1U};
  CHECK(build_decoder(wrong_decoder_tag, 932U, 11U));
  CHECK(wrong_decoder_tag.seal_session() ==
        BulkDataStreamLifecycleStatus::Sealed);
  expect_producer_failure(producer, wrong_decoder_tag,
                          good.ground_transcript, good.sla, good.commit,
                          good.identity,
                          TerminalAckProducerStatus::DecoderTagMismatch);

  BulkTranscriptLedger wrong_transcript_tag{good.identity, good.tag + 1U};
  CHECK(build_transcript(wrong_transcript_tag, 11U, false));
  CHECK(wrong_transcript_tag.seal_session() ==
        BulkTranscriptStatus::Sealed);
  expect_producer_failure(producer, good.decoder, wrong_transcript_tag,
                          good.sla, good.commit, good.identity,
                          TerminalAckProducerStatus::TranscriptTagMismatch);

  BulkHeartbeatSlaLedger wrong_sla_tag{good.tag + 1U};
  CHECK(build_sla(wrong_sla_tag, SlaScenario::ExactBoundaries));
  CHECK(wrong_sla_tag.seal_session() == BulkHeartbeatSlaStatus::Sealed);
  expect_producer_failure(producer, good.decoder, good.ground_transcript,
                          wrong_sla_tag, good.commit, good.identity,
                          TerminalAckProducerStatus::SlaTagMismatch);

  BulkDataStreamDecoder count_decoder{good.tag, 931U};
  CHECK(build_decoder(count_decoder, 931U, 11U));
  CHECK(count_decoder.seal_session() ==
        BulkDataStreamLifecycleStatus::Sealed);
  expect_producer_failure(
      producer, count_decoder, good.ground_transcript, good.sla,
      good.commit, good.identity,
      TerminalAckProducerStatus::DecoderAccountingMismatch);

  // A real, internally consistent decoder with one extra heartbeat still has
  // the wrong total chunk count and next ordinal for the sealed transcript.
  BulkDataStreamDecoder extra_decoder{good.tag};
  CHECK(build_decoder(extra_decoder, 932U, 12U));
  CHECK(extra_decoder.seal_session() ==
        BulkDataStreamLifecycleStatus::Sealed);
  CHECK(extra_decoder.total_fragment_count() == 1888U &&
        extra_decoder.next_wire_ordinal() == 1888U);
  expect_producer_failure(producer, extra_decoder, good.ground_transcript,
                          good.sla, good.commit, good.identity,
                          TerminalAckProducerStatus::DecoderAccountingMismatch);

  BulkTranscriptLedger extra_transcript{good.identity, good.tag};
  CHECK(build_transcript(extra_transcript, 12U, false));
  CHECK(extra_transcript.seal_session() == BulkTranscriptStatus::Sealed);
  expect_producer_failure(producer, good.decoder, extra_transcript, good.sla,
                          good.commit, good.identity,
                          TerminalAckProducerStatus::DecoderAccountingMismatch);

  BulkHeartbeatSlaLedger twelve_heartbeats{good.tag};
  CHECK(build_sla(twelve_heartbeats,
                  SlaScenario::ValidTwelveHeartbeats));
  CHECK(twelve_heartbeats.seal_session() ==
        BulkHeartbeatSlaStatus::Sealed);
  expect_producer_failure(producer, good.decoder, good.ground_transcript,
                          twelve_heartbeats, good.commit, good.identity,
                          TerminalAckProducerStatus::HeartbeatMismatch);

  const BulkNegotiationIdentity collision =
      transfer_tag_collision_identity();
  CHECK(tag_for(collision) == good.tag);
  BulkTranscriptLedger collision_transcript{collision, good.tag};
  CHECK(build_transcript(collision_transcript, 11U, false));
  CHECK(collision_transcript.seal_session() ==
        BulkTranscriptStatus::Sealed);
  expect_producer_failure(
      producer, good.decoder, collision_transcript, good.sla, good.commit,
      good.identity,
      TerminalAckProducerStatus::TranscriptIdentityMismatch);
}

void test_unsealed_incomplete_and_all_plus_one_deadlines() {
  CompleteSession good{identity_a()};
  CHECK(good.build());
  GroundTerminalAckProducer producer{};

  BulkDataStreamDecoder incomplete{good.tag};
  expect_producer_failure(producer, incomplete, good.ground_transcript,
                          good.sla, good.commit, good.identity,
                          TerminalAckProducerStatus::DecoderNotTerminal);

  BulkDataStreamDecoder unsealed_decoder{good.tag};
  CHECK(build_decoder(unsealed_decoder, 932U, 11U));
  expect_producer_failure(producer, unsealed_decoder,
                          good.ground_transcript, good.sla, good.commit,
                          good.identity,
                          TerminalAckProducerStatus::DecoderNotTerminal);

  BulkTranscriptLedger unsealed_transcript{good.identity, good.tag};
  CHECK(build_transcript(unsealed_transcript, 11U, false));
  expect_producer_failure(producer, good.decoder, unsealed_transcript,
                          good.sla, good.commit, good.identity,
                          TerminalAckProducerStatus::TranscriptNotTerminal);

  BulkHeartbeatSlaLedger unsealed_sla{good.tag};
  CHECK(build_sla(unsealed_sla, SlaScenario::ExactBoundaries));
  expect_producer_failure(producer, good.decoder, good.ground_transcript,
                          unsealed_sla, good.commit, good.identity,
                          TerminalAckProducerStatus::SlaNotTerminal);

  for (const SlaScenario scenario :
       std::array<SlaScenario, 4U>{{
           SlaScenario::FirstGapPlusOne,
           SlaScenario::MaximumGapPlusOne,
           SlaScenario::PostGapPlusOne,
           SlaScenario::ElapsedPlusOne}}) {
    BulkHeartbeatSlaLedger failed_sla{good.tag};
    CHECK(build_sla(failed_sla, scenario));
    CHECK(failed_sla.fail_closed());
    CHECK(failed_sla.seal_session() == BulkHeartbeatSlaStatus::Sealed);
    expect_producer_failure(producer, good.decoder,
                            good.ground_transcript, failed_sla, good.commit,
                            good.identity,
                            TerminalAckProducerStatus::SlaNotTerminal);
  }
}

void test_vehicle_factory_and_digest_mismatch_fail_closed() {
  CompleteSession good{identity_a()};
  CHECK(good.build());
  VehicleTerminalAckExpectedFactory factory{};
  expect_factory_failure(factory, BulkNegotiationIdentity{},
                         good.vehicle_transcript,
                         TerminalAckProducerStatus::InvalidIdentity);
  expect_factory_failure(
      factory, zero_tag_identity(), good.vehicle_transcript,
      TerminalAckProducerStatus::TransferTagDerivationFailed);

  BulkTranscriptLedger unsealed{good.identity, good.tag};
  CHECK(build_transcript(unsealed, 11U, false));
  expect_factory_failure(factory, good.identity, unsealed,
                         TerminalAckProducerStatus::TranscriptNotTerminal);

  BulkTranscriptLedger wrong_tag{good.identity, good.tag + 1U};
  CHECK(build_transcript(wrong_tag, 11U, false));
  CHECK(wrong_tag.seal_session() == BulkTranscriptStatus::Sealed);
  expect_factory_failure(factory, good.identity, wrong_tag,
                         TerminalAckProducerStatus::TranscriptTagMismatch);

  const BulkNegotiationIdentity collision =
      transfer_tag_collision_identity();
  BulkTranscriptLedger wrong_identity{collision, good.tag};
  CHECK(build_transcript(wrong_identity, 11U, false));
  CHECK(wrong_identity.seal_session() == BulkTranscriptStatus::Sealed);
  expect_factory_failure(
      factory, good.identity, wrong_identity,
      TerminalAckProducerStatus::TranscriptIdentityMismatch);

  CompleteSession changed{identity_a()};
  CHECK(changed.build(true, true, true, true, true));
  GroundTerminalAckProducer producer{};
  VehicleTerminalAckExpectedFactory changed_factory{};
  TerminalAckRecord record{};
  TerminalAckFragments fragments{};
  TerminalAckExpectedEvidence expected{};
  CHECK(producer.produce(changed.decoder, changed.ground_transcript,
                         changed.sla, changed.commit, changed.identity, record,
                         fragments) == TerminalAckProducerStatus::RecordReady);
  CHECK(changed_factory.make_expected(changed.identity,
                                      changed.vehicle_transcript,
                                      expected) ==
        TerminalAckProducerStatus::ExpectedReady);
  CHECK(record.record_id == expected.expected_record_id);
  CHECK(record.receiver_batch == expected.receiver_batch);
  CHECK(record.receiver_revision == expected.receiver_revision);
  CHECK(record.transcript_digest != expected.transcript_digest);
  TerminalAckReassembler mismatch(expected);
  CHECK(push_all(mismatch, fragments) ==
        TerminalAckError::TranscriptDigestMismatch);
  CHECK(mismatch.failed());
}

}  // namespace

int main() {
  test_deterministic_binding_and_alias_rejection();
  test_one_shot_ground_usb_host_commit_owner();
  test_full_932_round_trip_and_exact_boundaries();
  test_ground_rejects_identity_tag_count_and_heartbeat_mismatch();
  test_unsealed_incomplete_and_all_plus_one_deadlines();
  test_vehicle_factory_and_digest_mismatch_fail_closed();

  std::cout << "terminal_ack_producer_tests checks=" << checks
            << " failures=" << failures << '\n';
  return failures == 0 ? 0 : 1;
}
