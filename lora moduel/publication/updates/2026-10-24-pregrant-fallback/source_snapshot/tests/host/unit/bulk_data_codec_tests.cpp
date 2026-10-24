#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <type_traits>
#include <vector>

#include "../../../firmware/high_speed/vc_lora_high_speed_candidate.hpp"
#include "vc_lora/bulk_data_codec.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_link_demux.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint32_t kTransferTag = 0xA1B2C3D4U;

MavlinkFrame make_parameter_frame(std::uint16_t parameter_index,
                                  std::uint16_t parameter_count,
                                  std::uint8_t sequence,
                                  const char* marker,
                                  TestReport& report) {
  std::array<std::uint8_t, 25U> payload{};
  payload[4] = static_cast<std::uint8_t>(parameter_count & 0xFFU);
  payload[5] = static_cast<std::uint8_t>(parameter_count >> 8U);
  payload[6] = static_cast<std::uint8_t>(parameter_index & 0xFFU);
  payload[7] = static_cast<std::uint8_t>(parameter_index >> 8U);
  for (std::size_t index = 0U;
       marker[index] != '\0' && index < 16U; ++index) {
    payload[8U + index] = static_cast<std::uint8_t>(marker[index]);
  }
  payload[24] = 9U;

  MavlinkFrame frame{};
  report.check(encode_mavlink_v2(sequence, 1U, 1U, 22U, payload.data(),
                                 payload.size(), frame),
               "could not encode PARAM_VALUE fixture");
  report.check(frame.size == 37U,
               "PARAM_VALUE fixture is not exactly 37 bytes");
  return frame;
}

MavlinkFrame make_heartbeat_frame(std::uint8_t sequence,
                                  TestReport& report) {
  constexpr std::array<std::uint8_t, 9U> payload{{
      0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U}};
  MavlinkFrame frame{};
  report.check(encode_mavlink_v2(sequence, 1U, 1U, 0U, payload.data(),
                                 payload.size(), frame),
               "could not encode HEARTBEAT fixture");
  report.check(frame.size == 21U,
               "HEARTBEAT fixture is not exactly 21 bytes");
  return frame;
}

void repair_fragment_crc(BulkDataFragment& fragment) {
  const std::uint16_t crc = BulkDataWireCodec::crc16_ccitt_false(
      fragment.data(), BulkDataWireCodec::integrity_offset);
  fragment[30] = static_cast<std::uint8_t>(crc & 0xFFU);
  fragment[31] = static_cast<std::uint8_t>(crc >> 8U);
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

struct DemuxDecoderCounters final {
  std::size_t local_bytes{0U};
  std::size_t control_events{0U};
  std::size_t terminal_ack_events{0U};
  std::size_t bulk_data_events{0U};
};

BulkDataStreamStatus feed_bulk_fragment_via_demux(
    TddLinkDemux& demux, BulkDataStreamDecoder& decoder,
    const BulkDataFragment& wire_fragment, MavlinkFrame& output,
    DemuxDecoderCounters& counters, TestReport& report) {
  BulkDataStreamStatus status = BulkDataStreamStatus::NeedMore;
  const std::size_t bulk_events_before = counters.bulk_data_events;
  for (const std::uint8_t byte : wire_fragment) {
    const TddDemuxEvent event = demux.push(byte);
    counters.local_bytes += event.local_size;
    counters.control_events += event.has_control ? 1U : 0U;
    counters.terminal_ack_events += event.has_terminal_ack ? 1U : 0U;
    counters.bulk_data_events += event.has_bulk_data ? 1U : 0U;
    report.check(event.local_size == 0U && !event.has_control &&
                     !event.has_terminal_ack,
                 "VCB1 record leaked or entered a non-bulk demux route");
    if (event.has_bulk_data) {
      report.check(std::equal(wire_fragment.begin(), wire_fragment.end(),
                              event.bulk_data_fragment.begin()),
                   "demux changed a routed VCB1 record");
      status = feed_fragment(decoder, event.bulk_data_fragment, output);
    }
  }
  report.check(counters.bulk_data_events == bulk_events_before + 1U,
               "demux did not emit exactly one bulk event per VCB1 record");
  report.check(demux.buffered_size() == 0U,
               "demux retained bytes after an exact VCB1 record");
  return status;
}

std::array<BulkDataFragment, 2U> encode_unchecked_frame_bytes(
    const MavlinkFrame& frame, BulkDataFragmentKind head_kind,
    BulkDataFragmentKind tail_kind, std::uint16_t first_wire_ordinal,
    TestReport& report) {
  std::array<BulkDataFragment, 2U> fragments{};
  report.check(frame.size > BulkDataWireCodec::payload_bytes &&
                   frame.size <= 2U * BulkDataWireCodec::payload_bytes,
               "unchecked frame fixture has unsupported size");
  const std::size_t tail_size =
      frame.size - BulkDataWireCodec::payload_bytes;
  report.check(BulkDataWireCodec::encode_fragment(
                   head_kind, kTransferTag, first_wire_ordinal,
                   frame.bytes.data(), BulkDataWireCodec::payload_bytes,
                   fragments[0]) == BulkDataWireStatus::FragmentReady,
               "could not encode unchecked head fragment");
  report.check(BulkDataWireCodec::encode_fragment(
                   tail_kind, kTransferTag,
                   static_cast<std::uint16_t>(first_wire_ordinal + 1U),
                   frame.bytes.data() + BulkDataWireCodec::payload_bytes,
                   tail_size, fragments[1]) ==
                   BulkDataWireStatus::FragmentReady,
               "could not encode unchecked tail fragment");
  return fragments;
}

void test_wire_schema(TestReport& report) {
  constexpr std::array<std::uint8_t, 9U> reference{{
      '1', '2', '3', '4', '5', '6', '7', '8', '9'}};
  report.check(BulkDataWireCodec::crc16_ccitt_false(
                   reference.data(), reference.size()) == 0x29B1U,
               "CRC-16/CCITT-FALSE reference vector changed");

  const MavlinkFrame parameter =
      make_parameter_frame(0U, 1U, 7U, "VCB1-VCTA", report);
  EncodedBulkDataFrame encoded{};
  report.check(encode_bulk_data_frame(parameter, kTransferTag, 0U,
                                      encoded) ==
                   BulkDataWireStatus::FrameReady,
               "PARAM_VALUE frame encoding failed");
  report.check(encoded.fragment_count == 2U,
               "PARAM_VALUE did not use exactly two fragments");

  const BulkDataFragment& head = encoded.fragments[0];
  const BulkDataFragment& tail = encoded.fragments[1];
  report.check(head[0] == 'V' && head[1] == 'C' && head[2] == 'B' &&
                   head[3] == '1',
               "bulk magic/version changed");
  report.check(head[4] == 19U,
               "PARAM head descriptor is not kind=0,length=19");
  report.check(tail[4] == static_cast<std::uint8_t>((1U << 5U) | 18U),
               "PARAM tail descriptor is not kind=1,length=18");
  report.check(head[5] == 0xD4U && head[6] == 0xC3U &&
                   head[7] == 0xB2U && head[8] == 0xA1U,
               "transfer tag is not little-endian");
  report.check(head[9] == 0U && head[10] == 0U &&
                   tail[9] == 1U && tail[10] == 0U,
               "wire ordinal is not little-endian and contiguous");
  report.check(tail[29] == 0U,
               "unused tail payload byte is not canonical zero padding");

  BulkDataDecodedFragment decoded_head{};
  BulkDataDecodedFragment decoded_tail{};
  report.check(BulkDataWireCodec::decode_fragment(head, decoded_head) ==
                   BulkDataWireStatus::FragmentReady &&
                   BulkDataWireCodec::decode_fragment(tail, decoded_tail) ==
                       BulkDataWireStatus::FragmentReady,
               "encoded PARAM fragments did not decode");
  report.check(decoded_head.kind == BulkDataFragmentKind::ParameterHead &&
                   decoded_tail.kind ==
                       BulkDataFragmentKind::ParameterTail &&
                   decoded_head.payload_size == 19U &&
                   decoded_tail.payload_size == 18U,
               "decoded PARAM fragment metadata changed");
  for (std::size_t index = 0U; index < parameter.size; ++index) {
    const std::uint8_t actual =
        index < 19U ? decoded_head.payload[index]
                    : decoded_tail.payload[index - 19U];
    report.check(actual == parameter.bytes[index],
                 "PARAM payload changed across the bulk envelope");
  }

  const MavlinkFrame heartbeat = make_heartbeat_frame(8U, report);
  EncodedBulkDataFrame heartbeat_encoded{};
  report.check(encode_bulk_data_frame(heartbeat, kTransferTag, 2U,
                                      heartbeat_encoded) ==
                   BulkDataWireStatus::FrameReady &&
                   heartbeat_encoded.fragment_count == 2U,
               "HEARTBEAT frame encoding failed");
  report.check(heartbeat_encoded.fragments[0][4] ==
                       static_cast<std::uint8_t>((2U << 5U) | 19U) &&
                   heartbeat_encoded.fragments[1][4] ==
                       static_cast<std::uint8_t>((3U << 5U) | 2U),
               "HEARTBEAT descriptors are not canonical 19+2");
}

void test_corruption_and_canonical_rejection(TestReport& report) {
  const MavlinkFrame parameter =
      make_parameter_frame(0U, 1U, 9U, "CORRUPTION", report);
  EncodedBulkDataFrame encoded{};
  report.check(encode_bulk_data_frame(parameter, kTransferTag, 0U,
                                      encoded) ==
                   BulkDataWireStatus::FrameReady,
               "corruption fixture could not be encoded");

  for (const BulkDataFragment& original : encoded.fragments) {
    for (std::size_t byte_index = 0U; byte_index < original.size();
         ++byte_index) {
      for (std::uint8_t bit = 0U; bit < 8U; ++bit) {
        BulkDataFragment corrupted = original;
        corrupted[byte_index] ^= static_cast<std::uint8_t>(1U << bit);
        BulkDataDecodedFragment decoded{};
        report.check(BulkDataWireCodec::decode_fragment(corrupted, decoded) !=
                         BulkDataWireStatus::FragmentReady,
                     "single-bit fragment corruption was accepted");
      }
    }
  }

  BulkDataFragment output{};
  constexpr std::array<std::uint8_t, 19U> payload{};
  report.check(BulkDataWireCodec::encode_fragment(
                   BulkDataFragmentKind::ParameterHead, 0U, 0U,
                   payload.data(), payload.size(), output) ==
                   BulkDataWireStatus::InvalidTransferTag,
               "zero transfer tag was accepted");
  report.check(BulkDataWireCodec::encode_fragment(
                   BulkDataFragmentKind::ParameterHead, kTransferTag, 0U,
                   payload.data(), payload.size() - 1U, output) ==
                   BulkDataWireStatus::InvalidDescriptor,
               "noncanonical PARAM head length was accepted");

  BulkDataFragment invalid = encoded.fragments[1];
  invalid[4] = static_cast<std::uint8_t>((4U << 5U) | 18U);
  repair_fragment_crc(invalid);
  BulkDataDecodedFragment decoded{};
  report.check(BulkDataWireCodec::decode_fragment(invalid, decoded) ==
                   BulkDataWireStatus::InvalidDescriptor,
               "reserved fragment kind was accepted with valid CRC");

  invalid = encoded.fragments[1];
  invalid[5] = 0U;
  invalid[6] = 0U;
  invalid[7] = 0U;
  invalid[8] = 0U;
  repair_fragment_crc(invalid);
  report.check(BulkDataWireCodec::decode_fragment(invalid, decoded) ==
                   BulkDataWireStatus::InvalidTransferTag,
               "zero transfer tag was accepted with valid CRC");

  invalid = encoded.fragments[1];
  invalid[29] = 0x55U;
  repair_fragment_crc(invalid);
  report.check(BulkDataWireCodec::decode_fragment(invalid, decoded) ==
                   BulkDataWireStatus::NonCanonicalPadding,
               "nonzero tail padding was accepted with valid CRC");
}

void test_stream_fail_closed(TestReport& report) {
  const MavlinkFrame first =
      make_parameter_frame(0U, 2U, 10U, "FIRST", report);
  const MavlinkFrame heartbeat = make_heartbeat_frame(11U, report);
  const MavlinkFrame second =
      make_parameter_frame(1U, 2U, 12U, "SECOND", report);
  EncodedBulkDataFrame first_encoded{};
  EncodedBulkDataFrame heartbeat_encoded{};
  EncodedBulkDataFrame second_encoded{};
  report.check(encode_bulk_data_frame(first, kTransferTag, 0U,
                                      first_encoded) ==
                       BulkDataWireStatus::FrameReady &&
                   encode_bulk_data_frame(heartbeat, kTransferTag, 2U,
                                          heartbeat_encoded) ==
                       BulkDataWireStatus::FrameReady &&
                   encode_bulk_data_frame(second, kTransferTag, 4U,
                                          second_encoded) ==
                       BulkDataWireStatus::FrameReady,
               "stream fixture encoding failed");

  BulkDataStreamDecoder decoder{kTransferTag, 2U};
  MavlinkFrame output{};
  for (const EncodedBulkDataFrame* frame :
       {&first_encoded, &heartbeat_encoded, &second_encoded}) {
    report.check(feed_fragment(decoder, frame->fragments[0], output) ==
                     BulkDataStreamStatus::FragmentAccepted,
                 "valid head fragment was not accepted");
    report.check(feed_fragment(decoder, frame->fragments[1], output) ==
                     BulkDataStreamStatus::FrameReady,
                 "valid tail fragment did not emit one frame");
  }
  report.check(decoder.finish(), "complete valid stream did not finish");
  report.check(decoder.parameter_count() == 2U &&
                   decoder.parameter_fragment_count() == 4U &&
                   decoder.heartbeat_count() == 1U &&
                   decoder.total_fragment_count() == 6U &&
                   decoder.raw_parameter_bytes() == 74U,
               "valid stream accounting changed");

  BulkDataStreamDecoder no_head_output_decoder{kTransferTag, 2U};
  MavlinkFrame stale_output = heartbeat;
  report.check(feed_fragment(no_head_output_decoder,
                             first_encoded.fragments[0], stale_output) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                   stale_output.size == 0U,
               "HEAD fragment left stale application output visible");

  EncodedBulkDataFrame wrong_tag{};
  report.check(encode_bulk_data_frame(first, 0x01020304U, 0U, wrong_tag) ==
                   BulkDataWireStatus::FrameReady,
               "wrong-tag fixture encoding failed");
  BulkDataStreamDecoder tag_decoder{kTransferTag, 2U};
  report.check(feed_fragment(tag_decoder, wrong_tag.fragments[0], output) ==
                       BulkDataStreamStatus::WrongTransferTag &&
                   tag_decoder.latched(),
               "wrong transfer tag did not latch fail-closed");
  report.check(feed_fragment(tag_decoder, first_encoded.fragments[0], output) ==
                   BulkDataStreamStatus::Latched,
               "latched decoder accepted later valid data");

  BulkDataStreamDecoder ordinal_decoder{kTransferTag, 2U};
  report.check(feed_fragment(ordinal_decoder, first_encoded.fragments[0],
                             output) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "ordinal fixture head was rejected");
  report.check(feed_fragment(ordinal_decoder, first_encoded.fragments[0],
                             output) ==
                       BulkDataStreamStatus::WrongWireOrdinal &&
                   ordinal_decoder.latched(),
               "duplicate wire ordinal did not latch fail-closed");

  BulkDataFragment wrong_kind = first_encoded.fragments[1];
  wrong_kind[4] = static_cast<std::uint8_t>((3U << 5U) | 2U);
  wrong_kind[11] = first.bytes[19];
  wrong_kind[12] = first.bytes[20];
  std::fill(wrong_kind.begin() + 13U, wrong_kind.begin() + 30U, 0U);
  repair_fragment_crc(wrong_kind);
  BulkDataStreamDecoder kind_decoder{kTransferTag, 2U};
  report.check(feed_fragment(kind_decoder, first_encoded.fragments[0],
                             output) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "kind fixture head was rejected");
  report.check(feed_fragment(kind_decoder, wrong_kind, output) ==
                       BulkDataStreamStatus::FrameInterleaving &&
                   kind_decoder.latched(),
               "kind change inside a frame did not latch fail-closed");

  BulkDataStreamDecoder partial_decoder{kTransferTag, 2U};
  report.check(feed_fragment(partial_decoder, first_encoded.fragments[0],
                             output) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "partial fixture head was rejected");
  report.check(!partial_decoder.finish() && partial_decoder.latched() &&
                   partial_decoder.last_error() ==
                       BulkDataStreamStatus::TrailingPartial,
               "partial stream finish did not latch fail-closed");

  MavlinkFrame bad_mavlink = first;
  bad_mavlink.bytes[15] ^= 0x01U;
  const auto bad_fragments = encode_unchecked_frame_bytes(
      bad_mavlink, BulkDataFragmentKind::ParameterHead,
      BulkDataFragmentKind::ParameterTail, 0U, report);
  BulkDataStreamDecoder mavlink_decoder{kTransferTag, 2U};
  report.check(feed_fragment(mavlink_decoder, bad_fragments[0], output) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "bad-MAVLink fixture head was rejected too early");
  report.check(feed_fragment(mavlink_decoder, bad_fragments[1], output) ==
                       BulkDataStreamStatus::BadMavlink &&
                   mavlink_decoder.latched(),
               "valid envelope with invalid MAVLink CRC was accepted");
}

void test_parameter_evidence_matrix(TestReport& report) {
  MavlinkFrame output{};

  const MavlinkFrame wrong_count =
      make_parameter_frame(0U, 3U, 30U, "COUNT", report);
  EncodedBulkDataFrame wrong_count_encoded{};
  report.check(encode_bulk_data_frame(wrong_count, kTransferTag, 0U,
                                      wrong_count_encoded) ==
                   BulkDataWireStatus::FrameReady,
               "count-mismatch fixture encoding failed");
  BulkDataStreamDecoder count_decoder{kTransferTag, 2U};
  report.check(feed_fragment(count_decoder,
                             wrong_count_encoded.fragments[0], output) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "count-mismatch head was rejected too early");
  report.check(feed_fragment(count_decoder,
                             wrong_count_encoded.fragments[1], output) ==
                       BulkDataStreamStatus::ParameterEvidenceMismatch &&
                   count_decoder.latched() &&
                   count_decoder.parameter_count() == 0U,
               "CRC-valid PARAM count mismatch was not rejected");

  const MavlinkFrame first_of_three =
      make_parameter_frame(0U, 3U, 31U, "FIRST", report);
  const MavlinkFrame skipped =
      make_parameter_frame(2U, 3U, 32U, "SKIP", report);
  EncodedBulkDataFrame first_of_three_encoded{};
  EncodedBulkDataFrame skipped_encoded{};
  report.check(encode_bulk_data_frame(first_of_three, kTransferTag, 0U,
                                      first_of_three_encoded) ==
                       BulkDataWireStatus::FrameReady &&
                   encode_bulk_data_frame(skipped, kTransferTag, 2U,
                                          skipped_encoded) ==
                       BulkDataWireStatus::FrameReady,
               "index-skip fixtures could not be encoded");
  BulkDataStreamDecoder skip_decoder{kTransferTag, 3U};
  report.check(feed_fragment(skip_decoder,
                             first_of_three_encoded.fragments[0], output) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                   feed_fragment(skip_decoder,
                                 first_of_three_encoded.fragments[1],
                                 output) == BulkDataStreamStatus::FrameReady,
               "index-skip prefix was not accepted");
  report.check(feed_fragment(skip_decoder, skipped_encoded.fragments[0],
                             output) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "index-skip head was rejected before evidence validation");
  report.check(feed_fragment(skip_decoder, skipped_encoded.fragments[1],
                             output) ==
                       BulkDataStreamStatus::ParameterEvidenceMismatch &&
                   skip_decoder.latched() &&
                   skip_decoder.parameter_count() == 1U,
               "CRC-valid PARAM index skip was not rejected");

  const MavlinkFrame duplicate =
      make_parameter_frame(0U, 3U, 33U, "DUPLICATE", report);
  EncodedBulkDataFrame duplicate_encoded{};
  report.check(encode_bulk_data_frame(duplicate, kTransferTag, 2U,
                                      duplicate_encoded) ==
                   BulkDataWireStatus::FrameReady,
               "duplicate-index fixture could not be encoded");
  BulkDataStreamDecoder duplicate_decoder{kTransferTag, 3U};
  report.check(feed_fragment(duplicate_decoder,
                             first_of_three_encoded.fragments[0], output) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                   feed_fragment(duplicate_decoder,
                                 first_of_three_encoded.fragments[1],
                                 output) == BulkDataStreamStatus::FrameReady &&
                   feed_fragment(duplicate_decoder,
                                 duplicate_encoded.fragments[0], output) ==
                       BulkDataStreamStatus::FragmentAccepted,
               "duplicate-index prefix was not accepted");
  report.check(feed_fragment(duplicate_decoder,
                             duplicate_encoded.fragments[1], output) ==
                       BulkDataStreamStatus::ParameterEvidenceMismatch &&
                   duplicate_decoder.latched() &&
                   duplicate_decoder.parameter_count() == 1U,
               "CRC-valid duplicate PARAM index was not rejected");

  const MavlinkFrame reverse =
      make_parameter_frame(1U, 2U, 34U, "REVERSE", report);
  EncodedBulkDataFrame reverse_encoded{};
  report.check(encode_bulk_data_frame(reverse, kTransferTag, 0U,
                                      reverse_encoded) ==
                   BulkDataWireStatus::FrameReady,
               "reverse-index fixture could not be encoded");
  BulkDataStreamDecoder reverse_decoder{kTransferTag, 2U};
  report.check(feed_fragment(reverse_decoder, reverse_encoded.fragments[0],
                             output) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "reverse-index head was rejected too early");
  report.check(feed_fragment(reverse_decoder, reverse_encoded.fragments[1],
                             output) ==
                       BulkDataStreamStatus::ParameterEvidenceMismatch &&
                   reverse_decoder.latched() &&
                   reverse_decoder.parameter_count() == 0U,
               "CRC-valid reverse-first PARAM index was not rejected");

  BulkDataStreamDecoder extra_decoder{kTransferTag, 932U};
  std::uint16_t wire_ordinal = 0U;
  for (std::uint16_t index = 0U; index < 932U; ++index) {
    const MavlinkFrame parameter = make_parameter_frame(
        index, 932U, static_cast<std::uint8_t>(index), "BOUND", report);
    EncodedBulkDataFrame encoded{};
    report.check(encode_bulk_data_frame(parameter, kTransferTag,
                                        wire_ordinal, encoded) ==
                     BulkDataWireStatus::FrameReady,
                 "932-prefix PARAM fixture could not be encoded");
    report.check(feed_fragment(extra_decoder, encoded.fragments[0], output) ==
                         BulkDataStreamStatus::FragmentAccepted &&
                     feed_fragment(extra_decoder, encoded.fragments[1],
                                   output) ==
                         BulkDataStreamStatus::FrameReady,
                 "932-prefix PARAM fixture was not accepted");
    wire_ordinal = static_cast<std::uint16_t>(wire_ordinal + 2U);
  }
  const MavlinkFrame extra =
      make_parameter_frame(932U, 932U, 35U, "EXTRA933", report);
  EncodedBulkDataFrame extra_encoded{};
  report.check(wire_ordinal == 1864U &&
                   encode_bulk_data_frame(extra, kTransferTag,
                                          wire_ordinal, extra_encoded) ==
                       BulkDataWireStatus::FrameReady,
               "933rd PARAM fixture could not be encoded");
  report.check(feed_fragment(extra_decoder, extra_encoded.fragments[0],
                             output) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "933rd PARAM head was rejected before evidence validation");
  report.check(feed_fragment(extra_decoder, extra_encoded.fragments[1],
                             output) ==
                       BulkDataStreamStatus::ParameterEvidenceMismatch &&
                   extra_decoder.latched() &&
                   extra_decoder.parameter_count() == 932U,
               "CRC-valid 933rd PARAM_VALUE was accepted");
}

void test_heartbeat_global_ordinal_loss_matrix(TestReport& report) {
  const MavlinkFrame heartbeat = make_heartbeat_frame(40U, report);
  const MavlinkFrame parameter =
      make_parameter_frame(0U, 1U, 41U, "AFTER-HB", report);
  EncodedBulkDataFrame heartbeat_at_zero{};
  EncodedBulkDataFrame parameter_at_two{};
  report.check(encode_bulk_data_frame(heartbeat, kTransferTag, 0U,
                                      heartbeat_at_zero) ==
                       BulkDataWireStatus::FrameReady &&
                   encode_bulk_data_frame(parameter, kTransferTag, 2U,
                                          parameter_at_two) ==
                       BulkDataWireStatus::FrameReady,
               "heartbeat-loss fixtures could not be encoded");
  MavlinkFrame output{};

  BulkDataStreamDecoder head_loss_decoder{kTransferTag, 1U};
  report.check(feed_fragment(head_loss_decoder,
                             heartbeat_at_zero.fragments[1], output) ==
                       BulkDataStreamStatus::WrongWireOrdinal &&
                   head_loss_decoder.latched(),
               "lost heartbeat HEAD was not detected by global ordinal");

  BulkDataStreamDecoder tail_loss_decoder{kTransferTag, 1U};
  report.check(feed_fragment(tail_loss_decoder,
                             heartbeat_at_zero.fragments[0], output) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "heartbeat tail-loss HEAD was rejected");
  report.check(feed_fragment(tail_loss_decoder,
                             parameter_at_two.fragments[0], output) ==
                       BulkDataStreamStatus::WrongWireOrdinal &&
                   tail_loss_decoder.latched(),
               "lost heartbeat TAIL was not detected by global ordinal");

  const MavlinkFrame first =
      make_parameter_frame(0U, 2U, 42U, "BEFORE-HB", report);
  const MavlinkFrame second =
      make_parameter_frame(1U, 2U, 43U, "AFTER-HB", report);
  EncodedBulkDataFrame first_encoded{};
  EncodedBulkDataFrame skipped_heartbeat{};
  EncodedBulkDataFrame second_encoded{};
  report.check(encode_bulk_data_frame(first, kTransferTag, 0U,
                                      first_encoded) ==
                       BulkDataWireStatus::FrameReady &&
                   encode_bulk_data_frame(heartbeat, kTransferTag, 2U,
                                          skipped_heartbeat) ==
                       BulkDataWireStatus::FrameReady &&
                   encode_bulk_data_frame(second, kTransferTag, 4U,
                                          second_encoded) ==
                       BulkDataWireStatus::FrameReady,
               "whole-heartbeat-loss fixtures could not be encoded");
  BulkDataStreamDecoder both_loss_decoder{kTransferTag, 2U};
  report.check(feed_fragment(both_loss_decoder, first_encoded.fragments[0],
                             output) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                   feed_fragment(both_loss_decoder,
                                 first_encoded.fragments[1], output) ==
                       BulkDataStreamStatus::FrameReady,
               "whole-heartbeat-loss prefix was rejected");
  report.check(feed_fragment(both_loss_decoder, second_encoded.fragments[0],
                             output) ==
                       BulkDataStreamStatus::WrongWireOrdinal &&
                   both_loss_decoder.latched(),
               "loss of both heartbeat fragments was hidden by PARAM data");

  BulkDataStreamDecoder head_duplicate_decoder{kTransferTag, 1U};
  report.check(feed_fragment(head_duplicate_decoder,
                             heartbeat_at_zero.fragments[0], output) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "heartbeat duplicate-HEAD prefix was rejected");
  report.check(feed_fragment(head_duplicate_decoder,
                             heartbeat_at_zero.fragments[0], output) ==
                       BulkDataStreamStatus::WrongWireOrdinal &&
                   head_duplicate_decoder.latched(),
               "duplicate heartbeat HEAD was not detected");

  BulkDataStreamDecoder tail_duplicate_decoder{kTransferTag, 1U};
  report.check(feed_fragment(tail_duplicate_decoder,
                             heartbeat_at_zero.fragments[0], output) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                   feed_fragment(tail_duplicate_decoder,
                                 heartbeat_at_zero.fragments[1], output) ==
                       BulkDataStreamStatus::FrameReady,
               "heartbeat duplicate-TAIL prefix was rejected");
  report.check(feed_fragment(tail_duplicate_decoder,
                             heartbeat_at_zero.fragments[1], output) ==
                       BulkDataStreamStatus::WrongWireOrdinal &&
                   tail_duplicate_decoder.latched(),
               "duplicate heartbeat TAIL was not detected");
}

void test_finish_lifecycle_matrix(TestReport& report) {
  const MavlinkFrame parameter =
      make_parameter_frame(0U, 1U, 50U, "FINISH", report);
  EncodedBulkDataFrame encoded{};
  report.check(encode_bulk_data_frame(parameter, kTransferTag, 0U,
                                      encoded) ==
                   BulkDataWireStatus::FrameReady,
               "finish-lifecycle fixture could not be encoded");
  MavlinkFrame output{};

  BulkDataStreamDecoder empty_decoder{kTransferTag, 1U};
  report.check(!empty_decoder.finish() && empty_decoder.latched() &&
                   empty_decoder.last_error() ==
                       BulkDataStreamStatus::IncompleteParameterSet,
               "empty incomplete stream did not fail closed at finish");
  report.check(!empty_decoder.finish() &&
                   empty_decoder.last_error() ==
                       BulkDataStreamStatus::IncompleteParameterSet,
               "finish after incomplete latch changed terminal evidence");

  BulkDataStreamDecoder partial_fragment_decoder{kTransferTag, 1U};
  report.check(partial_fragment_decoder.push_byte(encoded.fragments[0][0],
                                                  output) ==
                   BulkDataStreamStatus::NeedMore,
               "partial-fragment fixture was rejected before finish");
  report.check(!partial_fragment_decoder.finish() &&
                   partial_fragment_decoder.latched() &&
                   partial_fragment_decoder.last_error() ==
                       BulkDataStreamStatus::TrailingPartial,
               "partial wire fragment did not fail closed at finish");

  BulkDataStreamDecoder head_only_decoder{kTransferTag, 1U};
  report.check(feed_fragment(head_only_decoder, encoded.fragments[0],
                             output) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "head-only fixture was rejected before finish");
  report.check(!head_only_decoder.finish() && head_only_decoder.latched() &&
                   head_only_decoder.last_error() ==
                       BulkDataStreamStatus::TrailingPartial,
               "head-only MAVLink frame did not fail closed at finish");

  BulkDataStreamDecoder double_finish_decoder{kTransferTag, 1U};
  report.check(feed_fragment(double_finish_decoder, encoded.fragments[0],
                             output) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                   feed_fragment(double_finish_decoder,
                                 encoded.fragments[1], output) ==
                       BulkDataStreamStatus::FrameReady &&
                   double_finish_decoder.finish(),
               "complete stream did not finish once");
  report.check(!double_finish_decoder.finish() &&
                   double_finish_decoder.complete() &&
                   !double_finish_decoder.latched() &&
                   double_finish_decoder.last_error() ==
                       BulkDataStreamStatus::NeedMore,
               "double finish mutated a sealed complete stream");

  BulkDataStreamDecoder post_complete_decoder{kTransferTag, 1U};
  report.check(feed_fragment(post_complete_decoder, encoded.fragments[0],
                             output) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                   feed_fragment(post_complete_decoder,
                                 encoded.fragments[1], output) ==
                       BulkDataStreamStatus::FrameReady &&
                   post_complete_decoder.finish(),
               "post-complete fixture did not seal");
  output = parameter;
  report.check(post_complete_decoder.push_byte(encoded.fragments[0][0],
                                               output) ==
                       BulkDataStreamStatus::PostCompleteData &&
                   post_complete_decoder.latched() &&
                   !post_complete_decoder.complete() && output.size == 0U,
               "post-complete data was not rejected and cleared");
  report.check(!post_complete_decoder.finish() &&
                   post_complete_decoder.last_error() ==
                       BulkDataStreamStatus::PostCompleteData,
               "finish after post-complete data changed the latched cause");
}

void test_unsupported_mavlink_and_wrong_envelope_kind(TestReport& report) {
  const MavlinkFrame parameter =
      make_parameter_frame(0U, 1U, 60U, "UNSUPPORTED", report);
  EncodedBulkDataFrame output{};
  output.fragment_count = 7U;

  MavlinkFrame mavlink1{};
  report.check(encode_mavlink_v1(60U, 1U, 1U, 22U, parameter.payload(),
                                 parameter.payload_length, mavlink1),
               "MAVLink1 PARAM_VALUE fixture could not be encoded");
  report.check(encode_bulk_data_frame(mavlink1, kTransferTag, 0U, output) ==
                       BulkDataWireStatus::UnsupportedFrame &&
                   output.fragment_count == 7U,
               "MAVLink1 PARAM_VALUE entered the bulk wire format");

  std::array<std::uint8_t, kMavlinkSignatureBytes> signature{};
  for (std::size_t index = 0U; index < signature.size(); ++index) {
    signature[index] = static_cast<std::uint8_t>(index + 1U);
  }
  MavlinkFrame signed_parameter{};
  report.check(encode_mavlink_v2(
                   61U, 1U, 1U, 22U, parameter.payload(),
                   parameter.payload_length, signed_parameter, 0x01U, 0U,
                   signature.data()),
               "signed PARAM_VALUE fixture could not be encoded");
  report.check(encode_bulk_data_frame(signed_parameter, kTransferTag, 0U,
                                      output) ==
                       BulkDataWireStatus::UnsupportedFrame &&
                   output.fragment_count == 7U,
               "signed PARAM_VALUE entered the bulk wire format");

  constexpr std::array<std::uint8_t, 10U> ack_payload{};
  MavlinkFrame non_bulk_message{};
  report.check(encode_mavlink_v2(62U, 1U, 1U, 77U, ack_payload.data(),
                                 ack_payload.size(), non_bulk_message),
               "non-bulk MAVLink fixture could not be encoded");
  report.check(encode_bulk_data_frame(non_bulk_message, kTransferTag, 0U,
                                      output) ==
                       BulkDataWireStatus::UnsupportedFrame &&
                   output.fragment_count == 7U,
               "non-PARAM/non-HEARTBEAT message entered the bulk wire format");

  const MavlinkFrame heartbeat = make_heartbeat_frame(63U, report);
  MavlinkFrame heartbeat_padded_as_parameter = heartbeat;
  heartbeat_padded_as_parameter.size = 37U;
  const auto heartbeat_in_parameter_envelope = encode_unchecked_frame_bytes(
      heartbeat_padded_as_parameter, BulkDataFragmentKind::ParameterHead,
      BulkDataFragmentKind::ParameterTail, 0U, report);
  BulkDataStreamDecoder wrong_parameter_kind_decoder{kTransferTag, 1U};
  MavlinkFrame delivered{};
  report.check(feed_fragment(wrong_parameter_kind_decoder,
                             heartbeat_in_parameter_envelope[0],
                             delivered) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "wrong PARAM envelope HEAD was rejected too early");
  report.check(feed_fragment(wrong_parameter_kind_decoder,
                             heartbeat_in_parameter_envelope[1],
                             delivered) ==
                       BulkDataStreamStatus::BadMavlink &&
                   wrong_parameter_kind_decoder.latched(),
               "HEARTBEAT bytes in PARAM envelope were accepted");

  MavlinkFrame parameter_truncated_as_heartbeat = parameter;
  parameter_truncated_as_heartbeat.size = 21U;
  const auto parameter_in_heartbeat_envelope = encode_unchecked_frame_bytes(
      parameter_truncated_as_heartbeat,
      BulkDataFragmentKind::HeartbeatHead,
      BulkDataFragmentKind::HeartbeatTail, 0U, report);
  BulkDataStreamDecoder wrong_heartbeat_kind_decoder{kTransferTag, 1U};
  report.check(feed_fragment(wrong_heartbeat_kind_decoder,
                             parameter_in_heartbeat_envelope[0],
                             delivered) ==
                   BulkDataStreamStatus::FragmentAccepted,
               "wrong HEARTBEAT envelope HEAD was rejected too early");
  report.check(feed_fragment(wrong_heartbeat_kind_decoder,
                             parameter_in_heartbeat_envelope[1],
                             delivered) ==
                       BulkDataStreamStatus::BadMavlink &&
                   wrong_heartbeat_kind_decoder.latched(),
               "PARAM bytes in HEARTBEAT envelope were accepted");
}

void test_payload_magic_and_read_splits(TestReport& report) {
  const MavlinkFrame frame =
      make_parameter_frame(0U, 1U, 21U, "VCB1VCTA-RAW", report);
  EncodedBulkDataFrame encoded{};
  report.check(encode_bulk_data_frame(frame, kTransferTag, 0U, encoded) ==
                   BulkDataWireStatus::FrameReady,
               "payload-magic fixture encoding failed");

  std::array<std::uint8_t, 64U> wire{};
  std::copy(encoded.fragments[0].begin(), encoded.fragments[0].end(),
            wire.begin());
  std::copy(encoded.fragments[1].begin(), encoded.fragments[1].end(),
            wire.begin() + 32U);

  constexpr std::array<std::size_t, 8U> read_sizes{{1U, 7U, 3U, 16U,
                                                    2U, 11U, 5U, 19U}};
  BulkDataStreamDecoder decoder{kTransferTag, 1U};
  MavlinkFrame output{};
  std::size_t offset = 0U;
  std::size_t read_index = 0U;
  std::size_t emitted = 0U;
  while (offset < wire.size()) {
    const std::size_t count = std::min(
        read_sizes[read_index % read_sizes.size()], wire.size() - offset);
    for (std::size_t index = 0U; index < count; ++index) {
      const BulkDataStreamStatus status =
          decoder.push_byte(wire[offset + index], output);
      if (status == BulkDataStreamStatus::FrameReady) {
        ++emitted;
      }
    }
    offset += count;
    ++read_index;
  }
  report.check(emitted == 1U && decoder.finish(),
               "arbitrary UART read splits did not emit one complete frame");
  report.check(output.size == frame.size &&
                   std::equal(frame.bytes.begin(),
                              frame.bytes.begin() + frame.size,
                              output.bytes.begin()),
               "VCB1/VCTA payload bytes caused resynchronization or mutation");
}

void test_demux_decoder_integration(TestReport& report) {
  const MavlinkFrame parameter =
      make_parameter_frame(0U, 1U, 81U, "XVCB1VCTA", report);
  const MavlinkFrame heartbeat = make_heartbeat_frame(82U, report);
  EncodedBulkDataFrame encoded_parameter{};
  EncodedBulkDataFrame encoded_heartbeat{};
  report.check(encode_bulk_data_frame(parameter, kTransferTag, 0U,
                                      encoded_parameter) ==
                       BulkDataWireStatus::FrameReady &&
                   encode_bulk_data_frame(heartbeat, kTransferTag, 2U,
                                          encoded_heartbeat) ==
                       BulkDataWireStatus::FrameReady,
               "demux/decoder fixtures could not enter the bulk envelope");

  constexpr std::array<std::uint8_t, 8U> embedded_magic{{
      'V', 'C', 'B', '1', 'V', 'C', 'T', 'A'}};
  const auto tail_payload_begin =
      encoded_parameter.fragments[1].begin() +
      static_cast<std::ptrdiff_t>(BulkDataWireCodec::payload_offset);
  const auto tail_payload_end =
      tail_payload_begin + static_cast<std::ptrdiff_t>(18U);
  report.check(std::search(tail_payload_begin, tail_payload_end,
                           embedded_magic.begin(), embedded_magic.end()) !=
                   tail_payload_end,
               "embedded VCB1/VCTA payload fixture is not exact");

  TddLinkDemux demux{false, BulkDataRouteMode::Enabled};
  BulkDataStreamDecoder decoder{kTransferTag, 1U};
  DemuxDecoderCounters counters{};
  MavlinkFrame delivered = heartbeat;
  report.check(feed_bulk_fragment_via_demux(
                   demux, decoder, encoded_parameter.fragments[0], delivered,
                   counters, report) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                   delivered.size == 0U,
               "PARAM HEAD emitted application data through the demux");
  report.check(feed_bulk_fragment_via_demux(
                   demux, decoder, encoded_parameter.fragments[1], delivered,
                   counters, report) == BulkDataStreamStatus::FrameReady &&
                   delivered.size == parameter.size &&
                   std::equal(parameter.bytes.begin(),
                              parameter.bytes.begin() + parameter.size,
                              delivered.bytes.begin()),
               "PARAM TAIL did not emit the exact source frame");

  delivered = parameter;
  report.check(feed_bulk_fragment_via_demux(
                   demux, decoder, encoded_heartbeat.fragments[0], delivered,
                   counters, report) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                   delivered.size == 0U,
               "HEARTBEAT HEAD emitted application data through the demux");
  report.check(feed_bulk_fragment_via_demux(
                   demux, decoder, encoded_heartbeat.fragments[1], delivered,
                   counters, report) == BulkDataStreamStatus::FrameReady &&
                   delivered.size == heartbeat.size &&
                   std::equal(heartbeat.bytes.begin(),
                              heartbeat.bytes.begin() + heartbeat.size,
                              delivered.bytes.begin()),
               "HEARTBEAT TAIL did not emit the exact source frame");
  report.check(decoder.finish() && decoder.parameter_count() == 1U &&
                   decoder.heartbeat_count() == 1U &&
                   decoder.total_fragment_count() == 4U &&
                   counters.bulk_data_events == 4U &&
                   counters.local_bytes == 0U && counters.control_events == 0U &&
                   counters.terminal_ack_events == 0U,
               "demux/decoder happy-path accounting changed");

  std::array<std::uint8_t, kTddControlFrameSize> terminal_ack{};
  terminal_ack[0] = 'V';
  terminal_ack[1] = 'C';
  terminal_ack[2] = 'T';
  terminal_ack[3] = 'A';
  std::copy_n(embedded_magic.begin(), 4U, terminal_ack.begin() + 12U);
  TddLinkDemux terminal_demux{false, BulkDataRouteMode::Enabled};
  std::size_t terminal_events = 0U;
  for (const std::uint8_t byte : terminal_ack) {
    const TddDemuxEvent event = terminal_demux.push(byte);
    report.check(event.local_size == 0U && !event.has_control &&
                     !event.has_bulk_data,
                 "VCTA record with embedded VCB1 entered the wrong route");
    if (event.has_terminal_ack) {
      ++terminal_events;
      report.check(std::equal(terminal_ack.begin(), terminal_ack.end(),
                              event.terminal_ack_fragment.begin()),
                   "demux changed VCTA bytes containing embedded VCB1");
    }
  }
  report.check(terminal_events == 1U &&
                   terminal_demux.buffered_size() == 0U,
               "VCTA record was not routed exactly once");

  const std::filesystem::path fixture =
      std::filesystem::path(VC_LORA_SOURCE_ROOT) / "runs" / "high_speed" /
      "R19-HS-G2-FROZEN-932-REPLAY-FIXTURE-001" /
      "OFFLINE-R18-ACCEPTED-V1" / "param_value_932.mavlink.bin";
  std::ifstream input(fixture, std::ios::binary);
  const bool fixture_opened = input.is_open();
  const std::vector<std::uint8_t> bytes{
      std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
  report.check(fixture_opened && bytes.size() == 34484U,
               "demux/decoder frozen 932 fixture is missing or changed size");

  TddLinkDemux frozen_demux{false, BulkDataRouteMode::Enabled};
  BulkDataStreamDecoder frozen_decoder{kTransferTag, 932U};
  DemuxDecoderCounters frozen_counters{};
  MavlinkStreamParser parser{};
  MavlinkFrame source{};
  MavlinkFrame frozen_delivered{};
  std::uint16_t next_wire_ordinal = 0U;
  std::size_t source_frames = 0U;
  std::size_t delivered_frames = 0U;
  for (const std::uint8_t byte : bytes) {
    const MavlinkParseStatus parse_status = parser.push(byte, source);
    if (parse_status != MavlinkParseStatus::FrameReady) {
      report.check(parse_status == MavlinkParseStatus::NeedMore,
                   "demux/decoder fixture contains invalid MAVLink");
      continue;
    }
    EncodedBulkDataFrame encoded{};
    report.check(encode_bulk_data_frame(source, kTransferTag,
                                        next_wire_ordinal, encoded) ==
                     BulkDataWireStatus::FrameReady,
                 "demux/decoder fixture frame could not be enveloped");
    next_wire_ordinal = static_cast<std::uint16_t>(next_wire_ordinal + 2U);
    ++source_frames;
    report.check(feed_bulk_fragment_via_demux(
                     frozen_demux, frozen_decoder, encoded.fragments[0],
                     frozen_delivered, frozen_counters, report) ==
                         BulkDataStreamStatus::FragmentAccepted &&
                     frozen_delivered.size == 0U,
                 "frozen PARAM HEAD emitted or was rejected");
    const BulkDataStreamStatus tail_status = feed_bulk_fragment_via_demux(
        frozen_demux, frozen_decoder, encoded.fragments[1], frozen_delivered,
        frozen_counters, report);
    if (tail_status == BulkDataStreamStatus::FrameReady) {
      ++delivered_frames;
      report.check(frozen_delivered.size == source.size &&
                       std::equal(source.bytes.begin(),
                                  source.bytes.begin() + source.size,
                                  frozen_delivered.bytes.begin()),
                   "frozen PARAM changed across demux and decoder");
    } else {
      report.check(false, "frozen PARAM TAIL did not emit one frame");
    }
  }
  report.check(source_frames == 932U && delivered_frames == 932U &&
                   frozen_decoder.finish(),
               "frozen corpus was not delivered exactly 932/932");
  report.check(next_wire_ordinal == 1864U &&
                   frozen_decoder.parameter_count() == 932U &&
                   frozen_decoder.parameter_fragment_count() == 1864U &&
                   frozen_decoder.total_fragment_count() == 1864U &&
                   frozen_decoder.raw_parameter_bytes() == 34484U &&
                   frozen_counters.bulk_data_events == 1864U &&
                   frozen_counters.local_bytes == 0U &&
                   frozen_counters.control_events == 0U &&
                   frozen_counters.terminal_ack_events == 0U,
               "frozen demux/decoder exact accounting changed");

  const MavlinkFrame first =
      make_parameter_frame(0U, 2U, 91U, "DROP-FIRST", report);
  const MavlinkFrame second =
      make_parameter_frame(1U, 2U, 92U, "DROP-SECOND", report);
  EncodedBulkDataFrame first_encoded{};
  EncodedBulkDataFrame second_encoded{};
  report.check(encode_bulk_data_frame(first, kTransferTag, 0U,
                                      first_encoded) ==
                       BulkDataWireStatus::FrameReady &&
                   encode_bulk_data_frame(second, kTransferTag, 2U,
                                          second_encoded) ==
                       BulkDataWireStatus::FrameReady,
               "dropped-fragment fixtures could not be encoded");
  TddLinkDemux loss_demux{false, BulkDataRouteMode::Enabled};
  BulkDataStreamDecoder loss_decoder{kTransferTag, 2U};
  DemuxDecoderCounters loss_counters{};
  MavlinkFrame negative_output = heartbeat;
  report.check(feed_bulk_fragment_via_demux(
                   loss_demux, loss_decoder, first_encoded.fragments[0],
                   negative_output, loss_counters, report) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                   negative_output.size == 0U,
               "dropped-fragment HEAD setup failed");
  report.check(feed_bulk_fragment_via_demux(
                   loss_demux, loss_decoder, second_encoded.fragments[0],
                   negative_output, loss_counters, report) ==
                       BulkDataStreamStatus::WrongWireOrdinal &&
                   loss_decoder.latched() && negative_output.size == 0U,
               "dropped fragment was not detected through the demux");

  BulkDataFragment bad_crc = first_encoded.fragments[0];
  bad_crc[BulkDataWireCodec::payload_offset] ^= 0x01U;
  TddLinkDemux crc_demux{false, BulkDataRouteMode::Enabled};
  BulkDataStreamDecoder crc_decoder{kTransferTag, 2U};
  DemuxDecoderCounters crc_counters{};
  negative_output = heartbeat;
  report.check(feed_bulk_fragment_via_demux(
                   crc_demux, crc_decoder, bad_crc, negative_output,
                   crc_counters, report) ==
                       BulkDataStreamStatus::InvalidFragment &&
                   crc_decoder.latched() && negative_output.size == 0U,
               "bad envelope CRC was not rejected through the demux");

  EncodedBulkDataFrame wrong_tag{};
  report.check(encode_bulk_data_frame(first, 0x01020304U, 0U, wrong_tag) ==
                   BulkDataWireStatus::FrameReady,
               "wrong-tag demux fixture could not be encoded");
  TddLinkDemux tag_demux{false, BulkDataRouteMode::Enabled};
  BulkDataStreamDecoder tag_decoder{kTransferTag, 2U};
  DemuxDecoderCounters tag_counters{};
  negative_output = heartbeat;
  report.check(feed_bulk_fragment_via_demux(
                   tag_demux, tag_decoder, wrong_tag.fragments[0],
                   negative_output, tag_counters, report) ==
                       BulkDataStreamStatus::WrongTransferTag &&
                   tag_decoder.latched() && negative_output.size == 0U,
               "wrong transfer tag was not rejected through the demux");

  report.cycles = frozen_counters.bulk_data_events;
  report.diagnostics.param_values_rx = delivered_frames;
  report.diagnostics.downlink_transactions =
      frozen_counters.bulk_data_events;
  report.diagnostics.downlink_payload_bytes =
      frozen_counters.bulk_data_events * BulkDataWireCodec::fragment_bytes;
}

void test_frozen_932_corpus(TestReport& report) {
  const std::filesystem::path fixture =
      std::filesystem::path(VC_LORA_SOURCE_ROOT) / "runs" / "high_speed" /
      "R19-HS-G2-FROZEN-932-REPLAY-FIXTURE-001" /
      "OFFLINE-R18-ACCEPTED-V1" / "param_value_932.mavlink.bin";
  std::ifstream input(fixture, std::ios::binary);
  const bool fixture_opened = input.is_open();
  const std::vector<std::uint8_t> bytes{
      std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
  report.check(fixture_opened && bytes.size() == 34484U,
               "frozen 932 fixture is missing or changed size");

  BulkDataStreamDecoder decoder{kTransferTag, 932U};
  MavlinkStreamParser parser{};
  MavlinkFrame source{};
  MavlinkFrame delivered{};
  std::uint16_t next_wire_ordinal = 0U;
  std::size_t source_frames = 0U;
  std::size_t delivered_frames = 0U;
  for (const std::uint8_t byte : bytes) {
    const MavlinkParseStatus parse_status = parser.push(byte, source);
    if (parse_status != MavlinkParseStatus::FrameReady) {
      report.check(parse_status == MavlinkParseStatus::NeedMore,
                   "frozen fixture contains an invalid MAVLink frame");
      continue;
    }
    report.check(source.message_id == 22U && source.size == 37U,
                 "frozen fixture contains a noncanonical PARAM_VALUE");
    EncodedBulkDataFrame encoded{};
    report.check(encode_bulk_data_frame(source, kTransferTag,
                                        next_wire_ordinal, encoded) ==
                     BulkDataWireStatus::FrameReady,
                 "frozen PARAM_VALUE could not enter bulk envelope");
    next_wire_ordinal = static_cast<std::uint16_t>(next_wire_ordinal + 2U);
    ++source_frames;
    for (const BulkDataFragment& fragment : encoded.fragments) {
      const BulkDataStreamStatus status =
          feed_fragment(decoder, fragment, delivered);
      if (status == BulkDataStreamStatus::FrameReady) {
        ++delivered_frames;
        report.check(delivered.size == source.size &&
                         std::equal(source.bytes.begin(),
                                    source.bytes.begin() + source.size,
                                    delivered.bytes.begin()),
                     "frozen PARAM_VALUE changed across bulk transport");
      } else {
        report.check(status == BulkDataStreamStatus::FragmentAccepted,
                     "frozen bulk fragment was rejected");
      }
    }
  }
  report.check(source_frames == 932U && delivered_frames == 932U,
               "frozen corpus was not delivered exactly 932/932");
  report.check(decoder.finish(),
               "frozen 932 decoder did not seal complete");
  report.check(next_wire_ordinal == 1864U &&
                   decoder.parameter_count() == 932U &&
                   decoder.parameter_fragment_count() == 1864U &&
                   decoder.total_fragment_count() == 1864U &&
                   decoder.raw_parameter_bytes() == 34484U,
               "frozen 932 exact accounting changed");

  MavlinkStreamParser loss_parser{};
  BulkDataStreamDecoder loss_decoder{kTransferTag, 932U};
  std::uint16_t loss_ordinal = 0U;
  std::size_t fragment_index = 0U;
  bool loss_detected = false;
  for (const std::uint8_t byte : bytes) {
    if (loss_parser.push(byte, source) != MavlinkParseStatus::FrameReady) {
      continue;
    }
    EncodedBulkDataFrame encoded{};
    report.check(encode_bulk_data_frame(source, kTransferTag, loss_ordinal,
                                        encoded) ==
                     BulkDataWireStatus::FrameReady,
                 "loss fixture encoding failed");
    loss_ordinal = static_cast<std::uint16_t>(loss_ordinal + 2U);
    for (const BulkDataFragment& fragment : encoded.fragments) {
      if (fragment_index++ == 247U) {
        continue;
      }
      const BulkDataStreamStatus status =
          feed_fragment(loss_decoder, fragment, delivered);
      if (status == BulkDataStreamStatus::WrongWireOrdinal) {
        loss_detected = true;
        break;
      }
    }
    if (loss_detected) {
      break;
    }
  }
  report.check(loss_detected && loss_decoder.latched(),
               "missing frozen-corpus fragment was not detected immediately");
  report.diagnostics.param_values_rx = delivered_frames;
  report.diagnostics.downlink_transactions =
      decoder.total_fragment_count();
  report.diagnostics.downlink_payload_bytes =
      decoder.total_fragment_count() * BulkDataWireCodec::fragment_bytes;
}

void test_receiver_session_rearm_lifecycle(TestReport& report) {
  constexpr std::uint32_t kSecondTransferTag = 0x10203040U;
  constexpr std::uint32_t kThirdTransferTag = 0x50607080U;
  static_assert(!std::is_copy_constructible_v<BulkDataStreamDecoder>);
  static_assert(!std::is_copy_assignable_v<BulkDataStreamDecoder>);
  static_assert(!std::is_move_constructible_v<BulkDataStreamDecoder>);
  static_assert(!std::is_move_assignable_v<BulkDataStreamDecoder>);

  BulkDataStreamDecoder unarmed_owner{0U};
  report.check(unarmed_owner.latched() &&
                   unarmed_owner.last_error() ==
                       BulkDataStreamStatus::InvalidConfiguration &&
                   unarmed_owner.expected_transfer_tag() == 0U &&
                   unarmed_owner.expected_parameter_count() == 932U,
               "zero-tag constructor no longer preserves fail-closed behavior");
  report.check(unarmed_owner.rearm(kSecondTransferTag) ==
                   BulkDataStreamLifecycleStatus::SessionNotSealed &&
                   unarmed_owner.latched(),
               "unarmed global owner bypassed its explicit seal boundary");
  report.check(unarmed_owner.seal_session() ==
                       BulkDataStreamLifecycleStatus::Sealed &&
                   unarmed_owner.rearm(kSecondTransferTag) ==
                       BulkDataStreamLifecycleStatus::Rearmed &&
                   unarmed_owner.expected_transfer_tag() ==
                       kSecondTransferTag &&
                   unarmed_owner.expected_parameter_count() == 932U &&
                   !unarmed_owner.latched() && !unarmed_owner.complete() &&
                   !unarmed_owner.sealed() &&
                   unarmed_owner.last_error() ==
                       BulkDataStreamStatus::NeedMore,
               "pre-negotiation global receiver owner did not rearm cleanly");

  BulkDataStreamDecoder default_owner{kTransferTag};
  report.check(default_owner.expected_parameter_count() == 932U,
               "product decoder default is not fixed at 932 parameters");
  report.check(default_owner.rearm(kSecondTransferTag) ==
                   BulkDataStreamLifecycleStatus::SessionNotSealed &&
                   default_owner.expected_transfer_tag() == kTransferTag,
               "an unsealed receiver session accepted rearm");

  MavlinkFrame output{};
  report.check(default_owner.push_byte('V', output) ==
                   BulkDataStreamStatus::NeedMore &&
                   default_owner.rearm(kSecondTransferTag) ==
                       BulkDataStreamLifecycleStatus::SessionNotSealed &&
                   default_owner.next_wire_ordinal() == 0U,
               "a partial VCB1 record did not block direct rearm");
  report.check(default_owner.seal_session() ==
                   BulkDataStreamLifecycleStatus::Sealed &&
                   default_owner.rearm(kSecondTransferTag) ==
                       BulkDataStreamLifecycleStatus::Rearmed,
               "explicitly sealed partial session could not be rearmed");
  report.check(default_owner.expected_transfer_tag() == kSecondTransferTag &&
                   default_owner.expected_parameter_count() == 932U &&
                   default_owner.parameter_count() == 0U &&
                   default_owner.heartbeat_count() == 0U &&
                   default_owner.parameter_fragment_count() == 0U &&
                   default_owner.total_fragment_count() == 0U &&
                   default_owner.raw_parameter_bytes() == 0U &&
                   default_owner.next_wire_ordinal() == 0U &&
                   !default_owner.latched() && !default_owner.complete() &&
                   !default_owner.sealed() &&
                   default_owner.last_error() ==
                       BulkDataStreamStatus::NeedMore,
               "rearm did not fully reset receiver session state");

  const MavlinkFrame product_frame =
      make_parameter_frame(0U, 932U, 30U, "RX-FIXED-932", report);
  EncodedBulkDataFrame product_encoded{};
  report.check(encode_bulk_data_frame(product_frame, kSecondTransferTag, 0U,
                                      product_encoded) ==
                   BulkDataWireStatus::FrameReady &&
                   feed_fragment(default_owner, product_encoded.fragments[0],
                                 output) ==
                       BulkDataStreamStatus::FragmentAccepted,
               "rearmed owner retained the pre-seal partial record");
  report.check(default_owner.rearm(kThirdTransferTag) ==
                   BulkDataStreamLifecycleStatus::SessionNotSealed,
               "an active HEAD accepted direct rearm");
  report.check(default_owner.seal_session() ==
                   BulkDataStreamLifecycleStatus::Sealed,
               "active HEAD session could not be explicitly sealed");
  output = product_frame;
  report.check(default_owner.push_byte(0U, output) ==
                       BulkDataStreamStatus::SessionSealed &&
                   output.size == 0U && default_owner.total_fragment_count() == 1U,
               "sealed receiver accepted data or erased retained evidence");
  report.check(default_owner.rearm(kThirdTransferTag) ==
                   BulkDataStreamLifecycleStatus::Rearmed,
               "sealed active-frame session could not be rearmed");
  report.check(encode_bulk_data_frame(product_frame, kThirdTransferTag, 0U,
                                      product_encoded) ==
                       BulkDataWireStatus::FrameReady &&
                   feed_fragment(default_owner, product_encoded.fragments[0],
                                 output) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                   feed_fragment(default_owner, product_encoded.fragments[1],
                                 output) == BulkDataStreamStatus::FrameReady &&
                   default_owner.parameter_count() == 1U &&
                   default_owner.total_fragment_count() == 2U &&
                   default_owner.next_wire_ordinal() == 2U,
               "rearm did not clear the active-frame buffer and counters");

  const MavlinkFrame one =
      make_parameter_frame(0U, 1U, 31U, "RX-REARM", report);
  EncodedBulkDataFrame encoded{};
  report.check(encode_bulk_data_frame(one, kSecondTransferTag, 0U,
                                      encoded) ==
                   BulkDataWireStatus::FrameReady,
               "receiver rearm fixture could not be encoded");
  BulkDataStreamDecoder complete_owner{kSecondTransferTag, 1U};
  report.check(feed_fragment(complete_owner, encoded.fragments[0], output) ==
                   BulkDataStreamStatus::FragmentAccepted &&
                   feed_fragment(complete_owner, encoded.fragments[1], output) ==
                       BulkDataStreamStatus::FrameReady &&
                   complete_owner.finish() && complete_owner.complete(),
               "complete-unconsumed receiver fixture did not finish");
  report.check(complete_owner.rearm(kThirdTransferTag) ==
                   BulkDataStreamLifecycleStatus::SessionNotSealed &&
                   complete_owner.complete(),
               "complete-unconsumed session accepted direct rearm");
  report.check(complete_owner.seal_session() ==
                   BulkDataStreamLifecycleStatus::Sealed &&
                   complete_owner.rearm(kSecondTransferTag) ==
                       BulkDataStreamLifecycleStatus::TransferTagReuse &&
                   complete_owner.sealed(),
               "immediately previous transfer tag was not rejected");
  report.check(complete_owner.rearm(0U) ==
                   BulkDataStreamLifecycleStatus::InvalidConfiguration &&
                   complete_owner.sealed(),
               "zero transfer tag changed a sealed receiver owner");
  report.check(complete_owner.rearm(kThirdTransferTag) ==
                   BulkDataStreamLifecycleStatus::Rearmed &&
                   !complete_owner.complete() && !complete_owner.sealed() &&
                   complete_owner.parameter_count() == 0U,
               "fresh transfer tag did not rearm completed receiver owner");

  BulkDataStreamDecoder fault_owner{kTransferTag, 1U};
  EncodedBulkDataFrame wrong_tag{};
  report.check(encode_bulk_data_frame(one, kSecondTransferTag, 0U,
                                      wrong_tag) ==
                   BulkDataWireStatus::FrameReady &&
                   feed_fragment(fault_owner, wrong_tag.fragments[0], output) ==
                       BulkDataStreamStatus::WrongTransferTag &&
                   fault_owner.latched(),
               "latched receiver fixture did not fail closed");
  report.check(fault_owner.rearm(kThirdTransferTag) ==
                   BulkDataStreamLifecycleStatus::SessionNotSealed &&
                   fault_owner.latched(),
               "latched error accepted direct rearm");
  report.check(fault_owner.seal_session() ==
                   BulkDataStreamLifecycleStatus::Sealed &&
                   fault_owner.rearm(kThirdTransferTag) ==
                       BulkDataStreamLifecycleStatus::Rearmed &&
                   !fault_owner.latched() &&
                   fault_owner.last_error() ==
                       BulkDataStreamStatus::NeedMore,
               "sealed faulted receiver could not start a fresh session");
}

void test_receiver_two_frozen_sessions(TestReport& report) {
  constexpr std::uint32_t kSecondTransferTag = 0x10203040U;
  const std::filesystem::path fixture =
      std::filesystem::path(VC_LORA_SOURCE_ROOT) / "runs" / "high_speed" /
      "R19-HS-G2-FROZEN-932-REPLAY-FIXTURE-001" /
      "OFFLINE-R18-ACCEPTED-V1" / "param_value_932.mavlink.bin";
  std::ifstream input(fixture, std::ios::binary);
  const std::vector<std::uint8_t> bytes{
      std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
  report.check(input.is_open() && bytes.size() == 34484U,
               "two-session frozen fixture is missing or changed size");

  BulkDataStreamDecoder decoder{kTransferTag};
  const std::array<std::uint32_t, 2U> tags{{kTransferTag,
                                           kSecondTransferTag}};
  std::size_t total_delivered = 0U;
  for (std::size_t session = 0U; session < tags.size(); ++session) {
    if (session != 0U) {
      report.check(decoder.seal_session() ==
                       BulkDataStreamLifecycleStatus::Sealed &&
                       decoder.rearm(tags[session]) ==
                           BulkDataStreamLifecycleStatus::Rearmed,
                   "frozen receiver owner did not rearm between sessions");
    }
    MavlinkStreamParser parser{};
    MavlinkFrame source{};
    MavlinkFrame delivered{};
    std::uint16_t ordinal = 0U;
    std::size_t session_delivered = 0U;
    for (const std::uint8_t byte : bytes) {
      const MavlinkParseStatus parsed = parser.push(byte, source);
      if (parsed != MavlinkParseStatus::FrameReady) {
        report.check(parsed == MavlinkParseStatus::NeedMore,
                     "two-session fixture contains invalid MAVLink");
        continue;
      }
      EncodedBulkDataFrame encoded{};
      report.check(encode_bulk_data_frame(source, tags[session], ordinal,
                                          encoded) ==
                       BulkDataWireStatus::FrameReady,
                   "two-session PARAM_VALUE could not be enveloped");
      ordinal = static_cast<std::uint16_t>(ordinal + 2U);
      report.check(feed_fragment(decoder, encoded.fragments[0], delivered) ==
                       BulkDataStreamStatus::FragmentAccepted &&
                       feed_fragment(decoder, encoded.fragments[1], delivered) ==
                           BulkDataStreamStatus::FrameReady,
                   "two-session receiver rejected a frozen frame");
      ++session_delivered;
    }
    report.check(session_delivered == 932U && decoder.finish() &&
                     decoder.parameter_count() == 932U &&
                     decoder.parameter_fragment_count() == 1864U &&
                     decoder.total_fragment_count() == 1864U &&
                     decoder.raw_parameter_bytes() == 34484U &&
                     decoder.next_wire_ordinal() == 1864U,
                 "receiver state leaked or accounting changed across rearm");
    total_delivered += session_delivered;
  }
  report.cycles = total_delivered;
  report.diagnostics.param_values_rx = total_delivered;
  report.diagnostics.downlink_transactions = 2U * 1864U;
  report.diagnostics.downlink_payload_bytes = 2U * 1864U * 32U;
}

void test_30_second_budget(TestReport& report) {
  using Contract = vc_lora::experimental::HighSpeedCandidateContract;

  // The SLA clock is Ground-visible: t0 is acceptance of a complete MAVLink
  // PARAM_REQUEST_LIST (#21), and t1 is the USB commit of PARAM_VALUE index
  // 931. VCTA terminal evidence is deliberately outside that interval.
  static_assert(Contract::sla_start_message_id == 21U);
  static_assert(Contract::sla_terminal_message_id == 22U);
  static_assert(Contract::sla_terminal_parameter_index == 931U);
  static_assert(Contract::sla_ends_at_ground_usb_commit);
  static_assert(Contract::sla_grant_wire_chunks == 1U);
  static_assert(Contract::sla_negotiation_wire_chunks == 2U);
  static_assert(Contract::sla_negotiation_receipt_wire_chunks == 1U);
  static_assert(Contract::sla_parameter_wire_chunks == 1864U);
  static_assert(Contract::sla_conservative_heartbeat_frames == 31U);
  static_assert(Contract::sla_heartbeat_wire_chunks == 62U);
  static_assert(Contract::sla_critical_wire_chunks == 1930U);
  static_assert(Contract::sla_critical_wire_bytes == 61760U);
  static_assert(Contract::sla_air_payload_lower_bound_ms == 25734U);

  static_assert(Contract::current_grant_wait_ms == 4600U);
  static_assert(Contract::candidate_grant_wait_budget_ms == 500U);
  static_assert(Contract::sla_direction_guard_count == 4U);
  static_assert(Contract::sla_direction_guard_budget_ms == 400U);
  static_assert(Contract::ground_usb_commit_budget_ms == 100U);
  static_assert(Contract::current_schedule_lower_bound_ms == 30834U);
  static_assert(Contract::integration_candidate_lower_bound_ms == 26734U);
  static_assert(Contract::integration_candidate_unproven_margin_ms == 3266U);

  static_assert(Contract::post_sla_vcta_wire_chunks == 8U);
  static_assert(Contract::post_sla_terminal_receipt_wire_chunks == 1U);
  static_assert(Contract::post_sla_direction_guard_count == 2U);
  static_assert(Contract::post_sla_direction_guard_budget_ms == 200U);
  static_assert(Contract::full_session_direction_guard_budget_ms == 600U);
  static_assert(Contract::full_session_wire_chunks == 1939U);
  static_assert(Contract::full_session_wire_bytes == 62048U);
  static_assert(Contract::full_session_air_payload_lower_bound_ms == 25854U);
  static_assert(Contract::integration_full_session_lower_bound_ms == 27054U);
  static_assert(Contract::vcta_is_post_sla);

  report.check(Contract::current_schedule_30s_impossible,
               "current 4.6-second Grant wait must remain classified as "
               "30-second infeasible");
  report.check(Contract::integration_candidate_feasible,
               "500-ms Grant integration candidate lost its arithmetic "
               "30-second feasibility");
  report.check(!Contract::physical_30s_proven &&
                   !Contract::live_flash_authorized,
               "offline lower-bound accounting must not claim physical proof");
  report.check(Contract::bulk_heartbeat_policy_required &&
                   !Contract::bulk_heartbeat_policy_proven,
               "31-heartbeat allowance requires a still-unproven bulk policy");
  report.check(Contract::uart_feed_must_overlap_air,
               "30-second candidate silently assumes serial UART and air time");

  report.cycles = Contract::sla_critical_wire_chunks;
  report.diagnostics.downlink_transactions =
      Contract::sla_critical_wire_chunks;
  report.diagnostics.downlink_payload_bytes =
      Contract::sla_critical_wire_bytes;
}

}  // namespace

TestReport run_bulk_data_codec_test(const std::string& test_id,
                                    std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-BULK-WIRE-001") {
    test_wire_schema(report);
  } else if (test_id == "UT-BULK-WIRE-002") {
    test_corruption_and_canonical_rejection(report);
  } else if (test_id == "UT-BULK-WIRE-003") {
    test_stream_fail_closed(report);
  } else if (test_id == "UT-BULK-WIRE-004") {
    test_payload_magic_and_read_splits(report);
  } else if (test_id == "UT-BULK-WIRE-005") {
    test_parameter_evidence_matrix(report);
  } else if (test_id == "UT-BULK-WIRE-006") {
    test_heartbeat_global_ordinal_loss_matrix(report);
  } else if (test_id == "UT-BULK-WIRE-007") {
    test_finish_lifecycle_matrix(report);
  } else if (test_id == "UT-BULK-WIRE-008") {
    test_unsupported_mavlink_and_wrong_envelope_kind(report);
  } else if (test_id == "UT-BULK-WIRE-009") {
    test_receiver_session_rearm_lifecycle(report);
  } else if (test_id == "IT-BULK-RX-REARM-001") {
    test_receiver_two_frozen_sessions(report);
  } else if (test_id == "IT-BULK-DEMUX-DECODER-001") {
    test_demux_decoder_integration(report);
  } else if (test_id == "IT-BULK-WIRE-PARAM-932-001") {
    test_frozen_932_corpus(report);
  } else if (test_id == "IT-BULK-BUDGET-001") {
    test_30_second_budget(report);
  } else {
    report.check(false, "unknown bulk data codec test ID");
  }
  report.trace.record({0U, "host", "BULK_DATA", 0U,
                       report.passed ? "PASS" : "FAIL", true,
                       report.diagnostics.downlink_payload_bytes, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
