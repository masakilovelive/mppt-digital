#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/runtime_contract.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_link_demux.hpp"

namespace vc_lora::test {
namespace {

constexpr std::size_t kV2FieldBytes = 20U;
constexpr std::size_t kV2PaddingBegin = 20U;
constexpr std::size_t kV2PaddingEnd = 30U;
constexpr std::size_t kV2CrcOffset = 30U;
constexpr std::size_t kLegacyV1FrameSize = 22U;

TddControlMessage
sample_control(ControlType type = ControlType::UlGrant) noexcept {
  TddControlMessage message{};
  message.type = type;
  message.session_id = 0x3412U;
  message.cycle_id = 0x7856U;
  message.guard_ms = type == ControlType::UlGrant ? 650U : 0U;
  message.window_ms = type == ControlType::UlGrant ? 300U : 0U;
  message.max_bytes = 64U;
  message.actual_bytes = type == ControlType::UlDone ? 32U : 0U;
  return message;
}

std::array<std::uint8_t, 32U>
encoded_control(TestReport &report,
                ControlType type = ControlType::UlGrant) noexcept {
  std::array<std::uint8_t, 32U> wire{};
  wire.fill(0xA5U);
  std::size_t encoded_size = 0U;
  report.check(encode_control(sample_control(type), wire.data(), wire.size(),
                              encoded_size),
               "v2 control encoding failed");
  report.check(encoded_size == 32U,
               "v2 control was not encoded as one exact 32-byte write");
  return wire;
}

std::uint16_t get_u16(const std::uint8_t *bytes, std::size_t offset) noexcept {
  return static_cast<std::uint16_t>(bytes[offset]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(bytes[offset + 1U]) << 8U);
}

void put_u16(std::uint8_t *bytes, std::size_t offset,
             std::uint16_t value) noexcept {
  bytes[offset] = static_cast<std::uint8_t>(value & 0xFFU);
  bytes[offset + 1U] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
}

template <std::size_t Size>
void rewrite_v2_crc(std::array<std::uint8_t, Size> &wire) noexcept {
  static_assert(Size >= kV2CrcOffset + 2U);
  put_u16(wire.data(), kV2CrcOffset,
          crc16_ccitt_false(wire.data(), kV2CrcOffset));
}

void test_exact_wire_layout(TestReport &report) {
  report.check(kTddProtocolVersion == 2U,
               "production control protocol is not explicit-DONE v2");
  report.check(kTddControlFrameSize == 32U,
               "production control wire is not exactly 32 bytes");

  const auto wire = encoded_control(report);
  report.check(wire[4] == 2U, "encoded control does not advertise v2");
  report.check(std::all_of(wire.begin() + kV2PaddingBegin,
                           wire.begin() + kV2PaddingEnd,
                           [](std::uint8_t byte) { return byte == 0U; }),
               "reserved bytes 20..29 are not deterministic zero padding");
  const std::uint16_t expected_crc =
      crc16_ccitt_false(wire.data(), kV2CrcOffset);
  report.check(get_u16(wire.data(), kV2CrcOffset) == expected_crc,
               "bytes 30..31 are not CRC16 over bytes 0..29");

  std::array<std::uint8_t, 31U> undersized{};
  std::size_t encoded_size = 99U;
  report.check(!encode_control(sample_control(), undersized.data(),
                               undersized.size(), encoded_size),
               "encoder accepted a buffer smaller than one physical chunk");
  report.check(encoded_size == 0U,
               "failed short-buffer encode exposed a partial wire length");
}

void test_corruption_fail_closed(TestReport &report) {
  constexpr std::array<std::size_t, 2U> kIdentityOffsets{{4U, 5U}};
  for (const std::size_t offset : kIdentityOffsets) {
    auto wire = encoded_control(report);
    wire[offset] ^= 0x01U;
    report.check(decode_control(wire.data(), wire.size()).status ==
                     DecodeStatus::BadCrc,
                 "version/type bit corruption was not rejected by CRC");
  }

  for (std::size_t offset = kV2PaddingBegin; offset < kV2PaddingEnd; ++offset) {
    auto wire = encoded_control(report);
    wire[offset] = 0x01U;
    report.check(decode_control(wire.data(), wire.size()).status ==
                     DecodeStatus::BadCrc,
                 "padding corruption without a new CRC was not rejected");

    rewrite_v2_crc(wire);
    report.check(decode_control(wire.data(), wire.size()).status ==
                     DecodeStatus::Malformed,
                 "nonzero authenticated padding was not rejected");
  }

  for (std::size_t offset = kV2CrcOffset; offset < kV2CrcOffset + 2U;
       ++offset) {
    auto wire = encoded_control(report);
    wire[offset] ^= 0x01U;
    report.check(decode_control(wire.data(), wire.size()).status ==
                     DecodeStatus::BadCrc,
                 "CRC corruption was not rejected");
  }

  auto version = encoded_control(report);
  version[4] = 1U;
  rewrite_v2_crc(version);
  report.check(decode_control(version.data(), version.size()).status ==
                   DecodeStatus::UnknownVersion,
               "authenticated v1-on-v2 wire was not rejected");

  auto type = encoded_control(report);
  type[5] = 0xFFU;
  rewrite_v2_crc(type);
  report.check(decode_control(type.data(), type.size()).status ==
                   DecodeStatus::UnknownType,
               "authenticated unknown control type was not rejected");
}

void test_stream_consumes_exact_frame(TestReport &report) {
  const auto wire = encoded_control(report);
  TddControlStreamDecoder decoder{};
  for (std::size_t index = 0U; index + 1U < wire.size(); ++index) {
    report.check(decoder.push(wire[index]).status == DecodeStatus::NeedMore,
                 "stream decoder emitted before all 32 bytes arrived");
  }
  report.check(decoder.buffered_size() == 31U,
               "stream decoder did not retain the complete 31-byte prefix");
  report.check(decoder.push(wire.back()).status == DecodeStatus::Message,
               "stream decoder did not emit at the exact 32-byte boundary");
  report.check(decoder.buffered_size() == 0U,
               "stream decoder retained bytes after one complete control");

  auto corrupted = wire;
  corrupted[kV2PaddingBegin] = 1U;
  std::size_t events = 0U;
  DecodeStatus final_status = DecodeStatus::NeedMore;
  for (const std::uint8_t byte : corrupted) {
    const DecodeEvent event = decoder.push(byte);
    if (event.status != DecodeStatus::NeedMore) {
      ++events;
      final_status = event.status;
    }
  }
  report.check(events == 1U && final_status != DecodeStatus::Message,
               "corrupted 32-byte candidate did not fail closed once");
  report.check(decoder.buffered_size() == 0U,
               "corrupted candidate was only partially consumed");
}

void append_local(const TddDemuxEvent &event,
                  std::array<std::uint8_t, 16U> &local, std::size_t &local_size,
                  TestReport &report) {
  for (std::size_t index = 0U; index < event.local_size; ++index) {
    report.check(local_size < local.size(),
                 "demux emitted more application bytes than expected");
    if (local_size < local.size()) {
      local[local_size++] = event.local_bytes[index];
    }
  }
}

void test_demux_and_escaped_data(TestReport &report) {
  const auto wire = encoded_control(report, ControlType::UlDone);
  TddLinkDemux demux{true};
  std::array<std::uint8_t, 16U> local{};
  std::size_t local_size = 0U;
  std::size_t control_events = 0U;
  for (std::size_t index = 0U; index < wire.size(); ++index) {
    const TddDemuxEvent event = demux.push(wire[index]);
    append_local(event, local, local_size, report);
    if (event.has_control) {
      ++control_events;
      report.check(index == 31U,
                   "demux emitted control before consuming all 32 bytes");
      report.check(event.control.status == DecodeStatus::Message,
                   "valid v2 control did not survive demux");
    }
  }
  report.check(control_events == 1U,
               "demux did not emit exactly one v2 control");
  report.check(local_size == 0U,
               "control padding or CRC leaked to the application stream");
  report.check(demux.buffered_size() == 0U,
               "demux retained part of a complete control frame");

  constexpr std::array<std::uint8_t, 7U> application{
      {0x56U, 0x7DU, 0x01U, 0x56U, 0x7DU, 0xFDU, 0x00U}};
  const EncodedLinkDataChunk encoded =
      encode_link_data(application.data(), application.size());
  report.check(encoded.input_consumed == application.size(),
               "V/7D application fixture did not fit one physical write");
  for (std::size_t index = 0U; index < encoded.wire_size; ++index) {
    const TddDemuxEvent event = demux.push(encoded.wire_bytes[index]);
    append_local(event, local, local_size, report);
    report.check(!event.has_control && !event.has_peer_completion_receipt,
                 "escaped application V entered a reserved control route");
  }
  report.check(local_size == application.size(),
               "escaped V/7D application bytes changed length");
  report.check(
      std::equal(application.begin(), application.end(), local.begin()),
      "escaped V/7D application bytes changed value or order");
}

void test_vcta_demux_route(TestReport &report) {
  std::array<std::uint8_t, kTddControlFrameSize> fragment{};
  for (std::size_t index = 0U; index < fragment.size(); ++index) {
    fragment[index] = static_cast<std::uint8_t>(0x30U + index);
  }
  fragment[0U] = static_cast<std::uint8_t>('V');
  fragment[1U] = static_cast<std::uint8_t>('C');
  fragment[2U] = static_cast<std::uint8_t>('T');
  fragment[3U] = static_cast<std::uint8_t>('A');
  fragment[4U] = 1U;
  fragment[5U] = 0U;
  fragment[6U] = 8U;
  fragment[7U] = 0U;
  // A raw V in the VCTA payload must not trigger the legacy VCTD
  // reserved-padding resynchronizer.
  fragment[24U] = static_cast<std::uint8_t>('V');

  const auto check_raw_route = [&](bool escaping) {
    TddLinkDemux demux{escaping};
    std::size_t terminal_events = 0U;
    for (std::size_t index = 0U; index < fragment.size(); ++index) {
      const TddDemuxEvent event = demux.push(fragment[index]);
      report.check(event.local_size == 0U,
                   "raw VCTA bytes leaked to the application route");
      report.check(!event.has_control && !event.has_peer_completion_receipt,
                   "raw VCTA fragment entered another reserved route");
      if (event.has_terminal_ack) {
        ++terminal_events;
        report.check(index + 1U == fragment.size(),
                     "VCTA route fired before the exact 32-byte boundary");
        report.check(event.terminal_ack_fragment == fragment,
                     "VCTA route changed fragment bytes");
      }
    }
    report.check(terminal_events == 1U,
                 "demux did not emit exactly one VCTA fragment");
    report.check(demux.buffered_size() == 0U,
                 "demux retained bytes after a complete VCTA fragment");
  };

  check_raw_route(false);
  check_raw_route(true);

  // CRC validation belongs to TerminalAckReassembler. The demux must still
  // quarantine and route a corrupted VCTA fragment byte-exactly rather than
  // leaking it into MAVLink data.
  auto corrupted = fragment;
  corrupted.back() ^= 0x80U;
  TddLinkDemux corrupted_demux{true};
  std::size_t corrupted_events = 0U;
  for (const std::uint8_t byte : corrupted) {
    const TddDemuxEvent event = corrupted_demux.push(byte);
    report.check(event.local_size == 0U,
                 "corrupt VCTA bytes leaked to the application route");
    if (event.has_terminal_ack) {
      ++corrupted_events;
      report.check(event.terminal_ack_fragment == corrupted,
                   "corrupt VCTA route changed fragment bytes");
    }
  }
  report.check(corrupted_events == 1U,
               "corrupt VCTA fragment escaped quarantine");

  // The same byte sequence is ordinary application data when link-data
  // escaping protects its leading V. It must remain byte-exact and must not
  // enter either control route.
  TddLinkDemux application_demux{true};
  std::array<std::uint8_t, kTddControlFrameSize> decoded{};
  std::size_t decoded_size = 0U;
  std::size_t source_offset = 0U;
  while (source_offset < fragment.size()) {
    const EncodedLinkDataChunk encoded = encode_link_data(
        fragment.data() + source_offset, fragment.size() - source_offset);
    report.check(encoded.input_consumed > 0U,
                 "VCTA application fixture made no encoder progress");
    for (std::size_t wire_index = 0U; wire_index < encoded.wire_size;
         ++wire_index) {
      const TddDemuxEvent event =
          application_demux.push(encoded.wire_bytes[wire_index]);
      report.check(!event.has_control && !event.has_terminal_ack &&
                       !event.has_peer_completion_receipt,
                   "escaped VCTA application data entered a control route");
      for (std::size_t local_index = 0U; local_index < event.local_size;
           ++local_index) {
        report.check(decoded_size < decoded.size(),
                     "escaped VCTA application data overflowed fixture");
        if (decoded_size < decoded.size()) {
          decoded[decoded_size++] = event.local_bytes[local_index];
        }
      }
    }
    source_offset += encoded.input_consumed;
  }
  report.check(decoded_size == fragment.size() && decoded == fragment,
               "escaped VCTA application data changed value or order");

  TddLinkDemux reset_demux{true};
  for (std::size_t index = 0U; index < 11U; ++index) {
    const TddDemuxEvent event = reset_demux.push(fragment[index]);
    report.check(event.local_size == 0U && !event.has_control &&
                     !event.has_terminal_ack &&
                     !event.has_peer_completion_receipt,
                 "partial VCTA produced an early route event");
  }
  report.check(reset_demux.buffered_size() == 11U,
               "partial VCTA buffered size is wrong");
  reset_demux.reset();
  report.check(reset_demux.buffered_size() == 0U,
               "reset retained a partial VCTA fragment");
}

void test_vcb1_demux_route(TestReport &report) {
  std::array<std::uint8_t, kTddControlFrameSize> fragment{};
  for (std::size_t index = 0U; index < fragment.size(); ++index) {
    fragment[index] = static_cast<std::uint8_t>(0x60U + index);
  }
  fragment[0U] = static_cast<std::uint8_t>('V');
  fragment[1U] = static_cast<std::uint8_t>('C');
  fragment[2U] = static_cast<std::uint8_t>('B');
  fragment[3U] = static_cast<std::uint8_t>('1');
  // Bulk payload is opaque to the demux. In particular, a raw V in the
  // payload must not trigger the legacy VCTD reserved-padding resynchronizer.
  fragment[24U] = static_cast<std::uint8_t>('V');

  const auto check_enabled_raw_route = [&](bool escaping) {
    TddLinkDemux demux{escaping, BulkDataRouteMode::Enabled};
    std::size_t bulk_events = 0U;
    for (std::size_t index = 0U; index < fragment.size(); ++index) {
      const TddDemuxEvent event = demux.push(fragment[index]);
      report.check(event.local_size == 0U,
                   "raw VCB1 bytes leaked to the application route");
      report.check(!event.has_control && !event.has_terminal_ack &&
                       !event.has_peer_completion_receipt,
                   "raw VCB1 fragment entered a legacy control route");
      if (event.has_bulk_data) {
        ++bulk_events;
        report.check(index + 1U == fragment.size(),
                     "VCB1 route fired before the exact 32-byte boundary");
        report.check(event.bulk_data_fragment == fragment,
                     "VCB1 route changed fragment bytes");
      }
    }
    report.check(bulk_events == 1U,
                 "bulk-enabled demux did not emit exactly one VCB1 fragment");
    report.check(demux.buffered_size() == 0U,
                 "demux retained bytes after a complete VCB1 fragment");
  };

  check_enabled_raw_route(false);
  check_enabled_raw_route(true);

  // Standard mode stays unaware of VCB1. In escaped transport a raw leading
  // V is still quarantined, but it must not become a bulk-data event.
  TddLinkDemux disabled{true};
  std::size_t disabled_bulk_events = 0U;
  std::size_t disabled_local_bytes = 0U;
  for (const std::uint8_t byte : fragment) {
    const TddDemuxEvent event = disabled.push(byte);
    disabled_bulk_events += event.has_bulk_data ? 1U : 0U;
    disabled_local_bytes += event.local_size;
  }
  report.check(disabled_bulk_events == 0U && disabled_local_bytes == 0U,
               "standard demux enabled or leaked raw VCB1 data");

  // Escaped application data remains transparent even while bulk routing is
  // enabled. Only a raw VCB1 prefix is reserved for the negotiated mode.
  TddLinkDemux application_demux{true, BulkDataRouteMode::Enabled};
  std::array<std::uint8_t, kTddControlFrameSize> decoded{};
  std::size_t decoded_size = 0U;
  std::size_t source_offset = 0U;
  while (source_offset < fragment.size()) {
    const EncodedLinkDataChunk encoded = encode_link_data(
        fragment.data() + source_offset, fragment.size() - source_offset);
    report.check(encoded.input_consumed > 0U,
                 "VCB1 application fixture made no encoder progress");
    for (std::size_t wire_index = 0U; wire_index < encoded.wire_size;
         ++wire_index) {
      const TddDemuxEvent event =
          application_demux.push(encoded.wire_bytes[wire_index]);
      report.check(!event.has_control && !event.has_terminal_ack &&
                       !event.has_bulk_data &&
                       !event.has_peer_completion_receipt,
                   "escaped VCB1 application data entered a reserved route");
      for (std::size_t local_index = 0U; local_index < event.local_size;
           ++local_index) {
        report.check(decoded_size < decoded.size(),
                     "escaped VCB1 application data overflowed fixture");
        if (decoded_size < decoded.size()) {
          decoded[decoded_size++] = event.local_bytes[local_index];
        }
      }
    }
    source_offset += encoded.input_consumed;
  }
  report.check(decoded_size == fragment.size() && decoded == fragment,
               "escaped VCB1 application data changed value or order");

  TddLinkDemux reset_demux{true, BulkDataRouteMode::Enabled};
  for (std::size_t index = 0U; index < 17U; ++index) {
    const TddDemuxEvent event = reset_demux.push(fragment[index]);
    report.check(event.local_size == 0U && !event.has_control &&
                     !event.has_terminal_ack && !event.has_bulk_data &&
                     !event.has_peer_completion_receipt,
                 "partial VCB1 produced an early route event");
  }
  report.check(reset_demux.buffered_size() == 17U,
               "partial VCB1 buffered size is wrong");
  reset_demux.reset();
  report.check(reset_demux.buffered_size() == 0U,
               "reset retained a partial VCB1 fragment");

  TddLinkDemux mode_switch{true};
  for (std::size_t index = 0U; index < 5U; ++index) {
    static_cast<void>(mode_switch.push(fragment[index]));
  }
  report.check(
      !mode_switch.set_bulk_data_route_mode(BulkDataRouteMode::Enabled) &&
          mode_switch.bulk_data_route_mode() == BulkDataRouteMode::Disabled &&
          mode_switch.buffered_size() == 5U,
      "bulk mode switch discarded or reclassified a partial candidate");
  mode_switch.reset();
  report.check(
      mode_switch.set_bulk_data_route_mode(BulkDataRouteMode::Enabled) &&
          mode_switch.bulk_data_route_mode() == BulkDataRouteMode::Enabled,
      "bulk mode did not enable at a clean byte-stream boundary");
}

void test_vcbn_demux_route(TestReport &report) {
  std::array<std::uint8_t, kTddControlFrameSize> record{};
  for (std::size_t index = 0U; index < record.size(); ++index) {
    record[index] = static_cast<std::uint8_t>(0x20U + index);
  }
  record[0U] = static_cast<std::uint8_t>('V');
  record[1U] = static_cast<std::uint8_t>('C');
  record[2U] = static_cast<std::uint8_t>('B');
  record[3U] = static_cast<std::uint8_t>('N');
  // Negotiation contents are opaque at this layer. Embedded V bytes must not
  // invoke the legacy VCTD reserved-padding resynchronizer.
  record[11U] = static_cast<std::uint8_t>('V');
  record[24U] = static_cast<std::uint8_t>('V');

  const auto check_raw_route = [&](bool escaping, BulkDataRouteMode bulk_mode) {
    TddLinkDemux demux{escaping, bulk_mode};
    std::size_t negotiation_events = 0U;
    for (std::size_t index = 0U; index < record.size(); ++index) {
      const TddDemuxEvent event = demux.push(record[index]);
      report.check(event.local_size == 0U,
                   "raw VCBN bytes leaked to the application route");
      report.check(!event.has_control && !event.has_terminal_ack &&
                       !event.has_bulk_data &&
                       !event.has_peer_completion_receipt,
                   "raw VCBN record entered another reserved route");
      if (event.has_bulk_negotiation) {
        ++negotiation_events;
        report.check(index + 1U == record.size(),
                     "VCBN route fired before the exact 32-byte boundary");
        report.check(event.bulk_negotiation_record == record,
                     "VCBN route changed negotiation bytes");
      }
    }
    report.check(negotiation_events == 1U,
                 "demux did not emit exactly one VCBN record");
    report.check(demux.buffered_size() == 0U,
                 "demux retained bytes after a complete VCBN record");
  };

  // Negotiation remains reachable before and during negotiated bulk mode.
  check_raw_route(false, BulkDataRouteMode::Disabled);
  check_raw_route(true, BulkDataRouteMode::Disabled);
  check_raw_route(false, BulkDataRouteMode::Enabled);
  check_raw_route(true, BulkDataRouteMode::Enabled);

  // Link-data escaping makes the same bytes ordinary application data, even
  // while the VCB1 bulk route is enabled.
  for (const BulkDataRouteMode bulk_mode :
       {BulkDataRouteMode::Disabled, BulkDataRouteMode::Enabled}) {
    TddLinkDemux application_demux{true, bulk_mode};
    std::array<std::uint8_t, kTddControlFrameSize> decoded{};
    std::size_t decoded_size = 0U;
    std::size_t source_offset = 0U;
    while (source_offset < record.size()) {
      const EncodedLinkDataChunk encoded = encode_link_data(
          record.data() + source_offset, record.size() - source_offset);
      report.check(encoded.input_consumed > 0U,
                   "VCBN application fixture made no encoder progress");
      for (std::size_t wire_index = 0U; wire_index < encoded.wire_size;
           ++wire_index) {
        const TddDemuxEvent event =
            application_demux.push(encoded.wire_bytes[wire_index]);
        report.check(!event.has_control && !event.has_terminal_ack &&
                         !event.has_bulk_data && !event.has_bulk_negotiation &&
                         !event.has_peer_completion_receipt,
                     "escaped VCBN application data entered a reserved route");
        for (std::size_t local_index = 0U; local_index < event.local_size;
             ++local_index) {
          report.check(decoded_size < decoded.size(),
                       "escaped VCBN application data overflowed fixture");
          if (decoded_size < decoded.size()) {
            decoded[decoded_size++] = event.local_bytes[local_index];
          }
        }
      }
      source_offset += encoded.input_consumed;
    }
    report.check(decoded_size == record.size() && decoded == record,
                 "escaped VCBN application data changed value or order");
  }

  // A partial raw negotiation record is retained for receive-window-close
  // accounting. It must neither emit early nor silently become MAVLink data.
  for (const BulkDataRouteMode bulk_mode :
       {BulkDataRouteMode::Disabled, BulkDataRouteMode::Enabled}) {
    TddLinkDemux partial_demux{false, bulk_mode};
    for (std::size_t index = 0U; index + 1U < record.size(); ++index) {
      const TddDemuxEvent event = partial_demux.push(record[index]);
      report.check(event.local_size == 0U && !event.has_control &&
                       !event.has_terminal_ack && !event.has_bulk_data &&
                       !event.has_bulk_negotiation &&
                       !event.has_peer_completion_receipt,
                   "partial VCBN record produced an early route event");
    }
    report.check(partial_demux.buffered_size() == record.size() - 1U,
                 "partial VCBN buffered size is wrong");
    partial_demux.reset();
    report.check(partial_demux.buffered_size() == 0U,
                 "reset retained a partial VCBN record");
  }

  // Malformed overlapping prefixes must be returned byte-exactly while the
  // following complete raw VCBN candidate remains quarantined and routed.
  constexpr std::array<std::array<std::uint8_t, 3U>, 4U> prefixes{{
      {{'x', 0U, 0U}},
      {{'V', 0U, 0U}},
      {{'V', 'C', 0U}},
      {{'V', 'C', 'B'}},
  }};
  constexpr std::array<std::size_t, 4U> prefix_sizes{{1U, 1U, 2U, 3U}};
  for (std::size_t case_index = 0U; case_index < prefixes.size();
       ++case_index) {
    TddLinkDemux demux{false, BulkDataRouteMode::Disabled};
    std::array<std::uint8_t, 3U> local{};
    std::size_t local_size = 0U;
    std::size_t events = 0U;
    const auto consume_event = [&](const TddDemuxEvent &event) {
      for (std::size_t index = 0U; index < event.local_size; ++index) {
        report.check(local_size < local.size(),
                     "VCBN adversarial prefix overflowed fixture");
        if (local_size < local.size()) {
          local[local_size++] = event.local_bytes[index];
        }
      }
      if (event.has_bulk_negotiation) {
        ++events;
        report.check(event.bulk_negotiation_record == record,
                     "VCBN after adversarial prefix changed bytes");
      }
    };
    for (std::size_t index = 0U; index < prefix_sizes[case_index]; ++index) {
      consume_event(demux.push(prefixes[case_index][index]));
    }
    for (const std::uint8_t byte : record) {
      consume_event(demux.push(byte));
    }
    report.check(events == 1U,
                 "VCBN after adversarial prefix was not routed exactly once");
    report.check(
        local_size == prefix_sizes[case_index] &&
            std::equal(prefixes[case_index].begin(),
                       prefixes[case_index].begin() + prefix_sizes[case_index],
                       local.begin()),
        "VCBN adversarial prefix was not returned byte-exactly");
  }
}

void test_vcrc_demux_route(TestReport &report) {
  std::array<std::uint8_t, kTddControlFrameSize> receipt{};
  for (std::size_t index = 0U; index < receipt.size(); ++index) {
    receipt[index] = static_cast<std::uint8_t>(0x40U + index);
  }
  receipt[0U] = static_cast<std::uint8_t>('V');
  receipt[1U] = static_cast<std::uint8_t>('C');
  receipt[2U] = static_cast<std::uint8_t>('R');
  receipt[3U] = static_cast<std::uint8_t>('C');
  receipt[4U] = 1U;
  receipt[5U] = 2U;
  receipt[6U] = 8U;
  receipt[7U] = 7U;
  // VCRC is opaque at the demux. Embedded raw V bytes must never trigger the
  // legacy VCTD reserved-padding resynchronizer.
  receipt[11U] = static_cast<std::uint8_t>('V');
  receipt[24U] = static_cast<std::uint8_t>('V');
  receipt[28U] = 0U;
  receipt[29U] = 0U;
  rewrite_v2_crc(receipt);

  const auto check_raw_route = [&](bool escaping, BulkDataRouteMode bulk_mode,
                                   const auto &candidate) {
    TddLinkDemux demux{escaping, bulk_mode};
    std::size_t receipt_events = 0U;
    for (std::size_t index = 0U; index < candidate.size(); ++index) {
      const TddDemuxEvent event = demux.push(candidate[index]);
      report.check(event.local_size == 0U,
                   "raw VCRC bytes leaked to the application route");
      report.check(!event.has_control && !event.has_terminal_ack &&
                       !event.has_bulk_data && !event.has_bulk_negotiation,
                   "raw VCRC record entered another reserved route");
      if (event.has_peer_completion_receipt) {
        ++receipt_events;
        report.check(index + 1U == candidate.size(),
                     "VCRC route fired before the exact 32-byte boundary");
        report.check(event.peer_completion_receipt == candidate,
                     "VCRC route changed receipt bytes");
      }
    }
    report.check(receipt_events == 1U,
                 "demux did not emit exactly one VCRC receipt");
    report.check(demux.buffered_size() == 0U,
                 "demux retained bytes after a complete VCRC receipt");
  };

  // VCRC is priority control and remains reachable before and during VCB1.
  for (const BulkDataRouteMode bulk_mode :
       {BulkDataRouteMode::Disabled, BulkDataRouteMode::Enabled}) {
    check_raw_route(false, bulk_mode, receipt);
    check_raw_route(true, bulk_mode, receipt);
  }

  // Integrity and semantic validation belong to the VCRC owner. The demux
  // must quarantine and route a bad-CRC receipt byte-exactly.
  auto bad_crc = receipt;
  bad_crc.back() ^= 0x80U;
  check_raw_route(false, BulkDataRouteMode::Disabled, bad_crc);
  check_raw_route(true, BulkDataRouteMode::Enabled, bad_crc);

  // An escaped application byte stream that happens to equal VCRC remains
  // transparent and must not enter any reserved route.
  for (const BulkDataRouteMode bulk_mode :
       {BulkDataRouteMode::Disabled, BulkDataRouteMode::Enabled}) {
    TddLinkDemux application_demux{true, bulk_mode};
    std::array<std::uint8_t, kTddControlFrameSize> decoded{};
    std::size_t decoded_size = 0U;
    std::size_t source_offset = 0U;
    while (source_offset < receipt.size()) {
      const EncodedLinkDataChunk encoded = encode_link_data(
          receipt.data() + source_offset, receipt.size() - source_offset);
      report.check(encoded.input_consumed > 0U,
                   "VCRC application fixture made no encoder progress");
      for (std::size_t wire_index = 0U; wire_index < encoded.wire_size;
           ++wire_index) {
        const TddDemuxEvent event =
            application_demux.push(encoded.wire_bytes[wire_index]);
        report.check(!event.has_control && !event.has_terminal_ack &&
                         !event.has_bulk_data && !event.has_bulk_negotiation &&
                         !event.has_peer_completion_receipt,
                     "escaped VCRC application data entered a reserved route");
        for (std::size_t local_index = 0U; local_index < event.local_size;
             ++local_index) {
          report.check(decoded_size < decoded.size(),
                       "escaped VCRC application data overflowed fixture");
          if (decoded_size < decoded.size()) {
            decoded[decoded_size++] = event.local_bytes[local_index];
          }
        }
      }
      source_offset += encoded.input_consumed;
    }
    report.check(decoded_size == receipt.size() && decoded == receipt,
                 "escaped VCRC application data changed value or order");
  }

  // A partial raw receipt is quarantined until reset and emits no early
  // route event.
  TddLinkDemux partial_demux{false, BulkDataRouteMode::Enabled};
  for (std::size_t index = 0U; index + 1U < receipt.size(); ++index) {
    const TddDemuxEvent event = partial_demux.push(receipt[index]);
    report.check(event.local_size == 0U && !event.has_control &&
                     !event.has_terminal_ack && !event.has_bulk_data &&
                     !event.has_bulk_negotiation &&
                     !event.has_peer_completion_receipt,
                 "partial VCRC produced an early route event");
  }
  report.check(partial_demux.buffered_size() == receipt.size() - 1U,
               "partial VCRC buffered size is wrong");
  partial_demux.reset();
  report.check(partial_demux.buffered_size() == 0U,
               "reset retained a partial VCRC receipt");

  // Mixed controls must remain disjoint and byte exact. VCB1 is enabled only
  // for this sequence; VCRC itself does not depend on that mode.
  std::array<std::uint8_t, kTddControlFrameSize> terminal{};
  terminal[0U] = static_cast<std::uint8_t>('V');
  terminal[1U] = static_cast<std::uint8_t>('C');
  terminal[2U] = static_cast<std::uint8_t>('T');
  terminal[3U] = static_cast<std::uint8_t>('A');
  std::array<std::uint8_t, kTddControlFrameSize> negotiation{};
  negotiation[0U] = static_cast<std::uint8_t>('V');
  negotiation[1U] = static_cast<std::uint8_t>('C');
  negotiation[2U] = static_cast<std::uint8_t>('B');
  negotiation[3U] = static_cast<std::uint8_t>('N');
  std::array<std::uint8_t, kTddControlFrameSize> bulk{};
  bulk[0U] = static_cast<std::uint8_t>('V');
  bulk[1U] = static_cast<std::uint8_t>('C');
  bulk[2U] = static_cast<std::uint8_t>('B');
  bulk[3U] = static_cast<std::uint8_t>('1');
  const auto control = encoded_control(report, ControlType::UlDone);
  const std::array<std::array<std::uint8_t, kTddControlFrameSize>, 5U> mixed{
      {control, terminal, negotiation, bulk, receipt}};
  TddLinkDemux mixed_demux{false, BulkDataRouteMode::Enabled};
  std::array<std::size_t, 5U> event_counts{};
  for (const auto &frame : mixed) {
    for (const std::uint8_t byte : frame) {
      const TddDemuxEvent event = mixed_demux.push(byte);
      const std::size_t route_count =
          static_cast<std::size_t>(event.has_control) +
          static_cast<std::size_t>(event.has_terminal_ack) +
          static_cast<std::size_t>(event.has_bulk_negotiation) +
          static_cast<std::size_t>(event.has_bulk_data) +
          static_cast<std::size_t>(event.has_peer_completion_receipt);
      report.check(route_count <= 1U,
                   "mixed stream emitted overlapping reserved routes");
      event_counts[0U] += event.has_control ? 1U : 0U;
      event_counts[1U] += event.has_terminal_ack ? 1U : 0U;
      event_counts[2U] += event.has_bulk_negotiation ? 1U : 0U;
      event_counts[3U] += event.has_bulk_data ? 1U : 0U;
      event_counts[4U] += event.has_peer_completion_receipt ? 1U : 0U;
    }
  }
  report.check(std::all_of(event_counts.begin(), event_counts.end(),
                           [](std::size_t count) { return count == 1U; }),
               "mixed VCTD/VCTA/VCBN/VCB1/VCRC route counts drifted");
}

std::array<std::uint8_t, kLegacyV1FrameSize>
legacy_v1_wire(std::uint16_t cycle_id = 0x7856U) noexcept {
  TddControlMessage message = sample_control();
  message.cycle_id = cycle_id;
  std::array<std::uint8_t, kLegacyV1FrameSize> wire{};
  wire[0] = 'V';
  wire[1] = 'C';
  wire[2] = 'T';
  wire[3] = 'D';
  wire[4] = 1U;
  wire[5] = static_cast<std::uint8_t>(message.type);
  wire[6] = 12U;
  wire[7] = 0U;
  put_u16(wire.data(), 8U, message.session_id);
  put_u16(wire.data(), 10U, message.cycle_id);
  put_u16(wire.data(), 12U, message.guard_ms);
  put_u16(wire.data(), 14U, message.window_ms);
  put_u16(wire.data(), 16U, message.max_bytes);
  put_u16(wire.data(), 18U, message.actual_bytes);
  put_u16(wire.data(), kV2FieldBytes,
          crc16_ccitt_false(wire.data(), kV2FieldBytes));
  return wire;
}

std::array<std::uint8_t, kLegacyV1FrameSize>
legacy_with_crc_v(TestReport &report, std::size_t crc_offset) noexcept {
  std::array<std::uint8_t, kLegacyV1FrameSize> wire{};
  bool found = false;
  for (std::uint32_t cycle = 0U; cycle <= 0xFFFFU; ++cycle) {
    wire = legacy_v1_wire(static_cast<std::uint16_t>(cycle));
    if (wire[crc_offset] == static_cast<std::uint8_t>('V')) {
      found = true;
      break;
    }
  }
  report.check(found, "could not construct a legacy control with CRC byte V");
  return wire;
}

std::array<std::uint8_t, 32U>
control_with_crc_v(TestReport &report, std::size_t crc_offset) noexcept {
  std::array<std::uint8_t, 32U> wire{};
  TddControlMessage message = sample_control(ControlType::UlDone);
  bool found = false;
  for (std::uint32_t cycle = 0U; cycle <= 0xFFFFU; ++cycle) {
    message.cycle_id = static_cast<std::uint16_t>(cycle);
    std::size_t encoded_size = 0U;
    if (!encode_control(message, wire.data(), wire.size(), encoded_size) ||
        encoded_size != wire.size()) {
      break;
    }
    if (wire[crc_offset] == static_cast<std::uint8_t>('V')) {
      found = true;
      break;
    }
  }
  report.check(found, "could not construct a valid control with CRC byte V");
  return wire;
}

void test_mixed_versions_rejected(TestReport &report) {
  const auto legacy = legacy_v1_wire();
  report.check(decode_control(legacy.data(), legacy.size()).status ==
                   DecodeStatus::Malformed,
               "legacy 22-byte v1 control was accepted by the v2 decoder");

  TddControlMessage v1_message = sample_control();
  v1_message.version = 1U;
  std::array<std::uint8_t, 32U> output{};
  std::size_t output_size = 99U;
  report.check(
      !encode_control(v1_message, output.data(), output.size(), output_size),
      "v2 encoder emitted a mixed-version v1 control");
  report.check(output_size == 0U,
               "rejected mixed-version encode exposed partial output");

  auto v1_in_v2_envelope = encoded_control(report);
  v1_in_v2_envelope[4] = 1U;
  rewrite_v2_crc(v1_in_v2_envelope);
  report.check(
      decode_control(v1_in_v2_envelope.data(), v1_in_v2_envelope.size())
              .status == DecodeStatus::UnknownVersion,
      "v1 control in a 32-byte envelope was accepted as v2");

  TddLinkDemux demux{true};
  std::size_t local_bytes = 0U;
  std::size_t rejected_controls = 0U;
  for (const std::uint8_t byte : v1_in_v2_envelope) {
    const TddDemuxEvent event = demux.push(byte);
    local_bytes += event.local_size;
    if (event.has_control) {
      ++rejected_controls;
      report.check(event.control.status == DecodeStatus::UnknownVersion,
                   "demux reported the wrong mixed-version rejection");
    }
  }
  report.check(rejected_controls == 1U && local_bytes == 0U,
               "mixed-version control was not quarantined fail-closed");

  // A rolling/mismatched peer can present complete legacy frames immediately
  // before a valid v2 control.  The reserved-zero region in v2 gives the
  // scanners an unambiguous place to abandon the legacy-sized candidate and
  // restart at the next raw control lead byte.  No legacy tail may enter the
  // application parser and the first valid v2 frame must remain recoverable.
  const auto v2 = encoded_control(report, ControlType::UlDone);
  TddLinkDemux mixed_demux{true};
  std::size_t mixed_local_bytes = 0U;
  std::size_t mixed_control_events = 0U;
  std::size_t mixed_v2_messages = 0U;
  const auto push_demux = [&](std::uint8_t byte) {
    const TddDemuxEvent event = mixed_demux.push(byte);
    mixed_local_bytes += event.local_size;
    if (event.has_control) {
      ++mixed_control_events;
      if (event.control.status == DecodeStatus::Message) {
        ++mixed_v2_messages;
        report.check(event.control.message.version == kTddProtocolVersion &&
                         event.control.message.type == ControlType::UlDone &&
                         event.control.message.session_id ==
                             sample_control(ControlType::UlDone).session_id &&
                         event.control.message.cycle_id ==
                             sample_control(ControlType::UlDone).cycle_id,
                     "mixed stream changed the recovered v2 control");
      }
    }
  };
  for (const std::uint8_t byte : legacy) {
    push_demux(byte);
  }
  for (const std::uint8_t byte : legacy) {
    push_demux(byte);
  }
  for (const std::uint8_t byte : v2) {
    push_demux(byte);
  }
  report.check(mixed_local_bytes == 0U,
               "legacy control tail leaked into escaped application data");
  report.check(mixed_control_events == 1U && mixed_v2_messages == 1U,
               "legacy stream was not discarded at the v2-safe boundary");
  report.check(mixed_demux.buffered_size() == 0U,
               "mixed demux retained bytes after the recovered v2 control");

  TddControlStreamDecoder mixed_decoder{};
  std::size_t decoder_events = 0U;
  std::size_t decoder_v2_messages = 0U;
  const auto push_decoder = [&](std::uint8_t byte) {
    const DecodeEvent event = mixed_decoder.push(byte);
    if (event.status != DecodeStatus::NeedMore) {
      ++decoder_events;
      if (event.status == DecodeStatus::Message) {
        ++decoder_v2_messages;
        report.check(event.message.version == kTddProtocolVersion &&
                         event.message.type == ControlType::UlDone,
                     "stream decoder changed the recovered v2 control");
      }
    }
  };
  for (const std::uint8_t byte : legacy) {
    push_decoder(byte);
  }
  for (const std::uint8_t byte : legacy) {
    push_decoder(byte);
  }
  for (const std::uint8_t byte : v2) {
    push_decoder(byte);
  }
  report.check(decoder_events == 1U && decoder_v2_messages == 1U,
               "stream decoder did not resynchronize directly to v2");
  report.check(mixed_decoder.buffered_size() == 0U,
               "mixed stream decoder retained bytes after v2 recovery");

  // Exercise every incoming offset in the reserved-padding interval.  A
  // truncated candidate followed by a fresh v2 lead must restart without an
  // invalid event or application leakage.
  for (std::size_t restart_offset = kV2PaddingBegin;
       restart_offset < kV2PaddingEnd; ++restart_offset) {
    TddLinkDemux restart_demux{true};
    std::size_t restart_local_bytes = 0U;
    std::size_t restart_messages = 0U;
    for (std::size_t index = 0U; index < restart_offset; ++index) {
      const TddDemuxEvent event = restart_demux.push(v2[index]);
      restart_local_bytes += event.local_size;
      restart_messages +=
          event.has_control && event.control.status == DecodeStatus::Message
              ? 1U
              : 0U;
    }
    for (const std::uint8_t byte : v2) {
      const TddDemuxEvent event = restart_demux.push(byte);
      restart_local_bytes += event.local_size;
      restart_messages +=
          event.has_control && event.control.status == DecodeStatus::Message
              ? 1U
              : 0U;
    }
    report.check(restart_local_bytes == 0U && restart_messages == 1U &&
                     restart_demux.buffered_size() == 0U,
                 "escaped demux did not restart inside reserved padding");

    TddControlStreamDecoder restart_decoder{};
    std::size_t restart_decoder_events = 0U;
    std::size_t restart_decoder_messages = 0U;
    const auto push_restart_decoder = [&](std::uint8_t byte) {
      const DecodeEvent event = restart_decoder.push(byte);
      if (event.status != DecodeStatus::NeedMore) {
        ++restart_decoder_events;
        restart_decoder_messages +=
            event.status == DecodeStatus::Message ? 1U : 0U;
      }
    };
    for (std::size_t index = 0U; index < restart_offset; ++index) {
      push_restart_decoder(v2[index]);
    }
    for (const std::uint8_t byte : v2) {
      push_restart_decoder(byte);
    }
    report.check(restart_decoder_events == 1U &&
                     restart_decoder_messages == 1U &&
                     restart_decoder.buffered_size() == 0U,
                 "stream decoder did not restart inside reserved padding");
  }

  // Offsets 20..21 are padding in v2 but CRC in a real legacy frame.  A
  // legacy CRC byte equal to 'V' must not create a false boundary before the
  // complete 22-byte legacy candidate; the following v2 control still wins.
  for (const std::size_t legacy_crc_offset :
       std::array<std::size_t, 2U>{{kV2PaddingBegin, kV2PaddingBegin + 1U}}) {
    const auto crc_v_legacy = legacy_with_crc_v(report, legacy_crc_offset);
    TddLinkDemux legacy_crc_demux{true};
    std::size_t legacy_crc_local = 0U;
    std::size_t legacy_crc_messages = 0U;
    for (const std::uint8_t byte : crc_v_legacy) {
      const TddDemuxEvent event = legacy_crc_demux.push(byte);
      legacy_crc_local += event.local_size;
      legacy_crc_messages +=
          event.has_control && event.control.status == DecodeStatus::Message
              ? 1U
              : 0U;
    }
    for (const std::uint8_t byte : v2) {
      const TddDemuxEvent event = legacy_crc_demux.push(byte);
      legacy_crc_local += event.local_size;
      legacy_crc_messages +=
          event.has_control && event.control.status == DecodeStatus::Message
              ? 1U
              : 0U;
    }
    report.check(legacy_crc_local == 0U && legacy_crc_messages == 1U &&
                     legacy_crc_demux.buffered_size() == 0U,
                 "legacy CRC byte V prevented escaped-demux v2 recovery");

    TddControlStreamDecoder legacy_crc_decoder{};
    std::size_t legacy_crc_decoder_events = 0U;
    std::size_t legacy_crc_decoder_messages = 0U;
    const auto push_legacy_crc_decoder = [&](std::uint8_t byte) {
      const DecodeEvent event = legacy_crc_decoder.push(byte);
      if (event.status != DecodeStatus::NeedMore) {
        ++legacy_crc_decoder_events;
        legacy_crc_decoder_messages +=
            event.status == DecodeStatus::Message ? 1U : 0U;
      }
    };
    for (const std::uint8_t byte : crc_v_legacy) {
      push_legacy_crc_decoder(byte);
    }
    for (const std::uint8_t byte : v2) {
      push_legacy_crc_decoder(byte);
    }
    report.check(legacy_crc_decoder_events == 1U &&
                     legacy_crc_decoder_messages == 1U &&
                     legacy_crc_decoder.buffered_size() == 0U,
                 "legacy CRC byte V prevented stream-decoder v2 recovery");
  }

  // The restart range must stop before CRC.  Prove both CRC byte positions
  // can contain the raw control lead value without damaging a valid frame.
  for (const std::size_t crc_offset :
       std::array<std::size_t, 2U>{{kV2CrcOffset, kV2CrcOffset + 1U}}) {
    const auto crc_v = control_with_crc_v(report, crc_offset);
    TddLinkDemux crc_demux{true};
    std::size_t crc_local_bytes = 0U;
    std::size_t crc_messages = 0U;
    for (const std::uint8_t byte : crc_v) {
      const TddDemuxEvent event = crc_demux.push(byte);
      crc_local_bytes += event.local_size;
      if (event.has_control && event.control.status == DecodeStatus::Message) {
        ++crc_messages;
      }
    }
    report.check(crc_local_bytes == 0U && crc_messages == 1U &&
                     crc_demux.buffered_size() == 0U,
                 "CRC byte V incorrectly restarted the escaped demux");

    TddControlStreamDecoder crc_decoder{};
    std::size_t crc_decoder_messages = 0U;
    for (const std::uint8_t byte : crc_v) {
      if (crc_decoder.push(byte).status == DecodeStatus::Message) {
        ++crc_decoder_messages;
      }
    }
    report.check(crc_decoder_messages == 1U &&
                     crc_decoder.buffered_size() == 0U,
                 "CRC byte V incorrectly restarted the stream decoder");
  }

  report.detail =
      "mixed legacy/v2: demux local=" + std::to_string(mixed_local_bytes) +
      ", control_events=" + std::to_string(mixed_control_events) +
      ", v2_messages=" + std::to_string(mixed_v2_messages) +
      "; stream_events=" + std::to_string(decoder_events) +
      ", v2_messages=" + std::to_string(decoder_v2_messages);
}

void test_physical_control_write(TestReport &report) {
  constexpr std::array<ControlType, 4U> kTypes{
      {ControlType::UlGrant, ControlType::UlDone, ControlType::UlIdle,
       ControlType::LinkStatus}};
  for (const ControlType type : kTypes) {
    std::array<std::uint8_t, 32U> wire{};
    wire.fill(0xA5U);
    std::size_t encoded_size = 0U;
    report.check(encode_control(sample_control(type), wire.data(), wire.size(),
                                encoded_size),
                 "physical control fixture could not be encoded");
    report.check(encoded_size == 32U,
                 "physical control encoder returned a non-32-byte write");
    E220WriteContract write{};
    report.check(!write.observe_aux(true, 0U),
                 "E220 write gate opened before AUX stability dwell");
    report.check(
        write.observe_aux(true, FixedFirmwareContract::aux_high_stable_ms),
        "E220 write gate did not open after AUX stability dwell");
    report.check(write.begin_write(encoded_size),
                 "exact 32-byte control physical write was rejected");
    report.check(write.requested_bytes() == 32U,
                 "physical control write length was not exactly 32 bytes");
    report.check(write.report_write_result(
                     encoded_size,
                     FixedFirmwareContract::aux_high_stable_ms + 1U,
                     true) == E220WriteDisposition::AcceptedAll,
                 "exact 32-byte control write was not atomically accepted");
    report.check(!write.fail_closed(),
                 "valid exact control write latched fail-close");
  }
}

} // namespace

TestReport run_control_v2_test(const std::string &test_id, std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-CONTROL-V2-WIRE-001") {
    test_exact_wire_layout(report);
  } else if (test_id == "UT-CONTROL-V2-CORRUPTION-001") {
    test_corruption_fail_closed(report);
  } else if (test_id == "UT-CONTROL-V2-STREAM-001") {
    test_stream_consumes_exact_frame(report);
  } else if (test_id == "UT-CONTROL-V2-DEMUX-001") {
    test_demux_and_escaped_data(report);
  } else if (test_id == "UT-CONTROL-V2-VCTA-DEMUX-001") {
    test_vcta_demux_route(report);
  } else if (test_id == "UT-CONTROL-V2-VCB1-DEMUX-001") {
    test_vcb1_demux_route(report);
  } else if (test_id == "UT-CONTROL-V2-VCBN-DEMUX-001") {
    test_vcbn_demux_route(report);
  } else if (test_id == "UT-CONTROL-V2-VCRC-DEMUX-001") {
    test_vcrc_demux_route(report);
  } else if (test_id == "UT-CONTROL-V2-MIXED-001") {
    test_mixed_versions_rejected(report);
  } else if (test_id == "FW-CONTROL-WIRE-001") {
    test_physical_control_write(report);
  } else {
    report.check(false, "unknown control-v2 test ID");
  }

  report.trace.record({0U, "host", "CONTROL_V2", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

} // namespace vc_lora::test
