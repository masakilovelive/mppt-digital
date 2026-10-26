#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_link_demux.hpp"

namespace vc_lora::test {
namespace {

template <std::size_t Capacity>
void append_local_bytes(const TddDemuxEvent& event,
                        std::array<std::uint8_t, Capacity>& output,
                        std::size_t& output_size, TestReport& report) {
  for (std::size_t index = 0; index < event.local_size; ++index) {
    report.check(output_size < output.size(),
                 "demux emitted more local bytes than expected");
    if (output_size < output.size()) {
      output[output_size++] = event.local_bytes[index];
    }
  }
}

std::array<std::uint8_t, kTddControlFrameSize> make_raw_control(
    TestReport& report) {
  TddControlMessage message{};
  message.type = ControlType::UlDone;
  message.session_id = 0x7D34U;
  message.cycle_id = 0x0156U;
  message.guard_ms = 650U;
  message.window_ms = 300U;
  message.max_bytes = 64U;
  message.actual_bytes = 11U;

  std::array<std::uint8_t, kTddControlFrameSize> control{};
  std::size_t encoded_size = 0;
  report.check(encode_control(message, control.data(), control.size(),
                              encoded_size),
               "test control frame could not be encoded");
  report.check(encoded_size == control.size(),
               "test control frame has an unexpected length");
  return control;
}

}  // namespace

TestReport run_link_data_codec_test(const std::string& test_id,
                                    std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-LINK-001") {
    constexpr std::array<std::uint8_t, 6> input{
        {0xFDU, 0x09U, 0x00U, 0x43U, 0x54U, 0x44U}};
    const EncodedLinkDataChunk encoded =
        encode_link_data(input.data(), input.size());
    report.check(encoded.input_consumed == input.size(),
                 "ordinary data was not fully consumed");
    report.check(encoded.wire_size == kLinkDataMaxWireBytes,
                 "ordinary data was not padded to an exact subpacket");
    for (std::size_t index = 0; index < input.size(); ++index) {
      report.check(encoded.wire_bytes[index] == input[index],
                   "ordinary data changed during encoding");
    }
  } else if (test_id == "UT-LINK-002") {
    constexpr std::array<std::uint8_t, 4> input{
        {0x56U, 0x7DU, 0x55U, 0x00U}};
    constexpr std::array<std::uint8_t, 6> expected{
        {0x7DU, 0x76U, 0x7DU, 0x5DU, 0x55U, 0x00U}};
    const EncodedLinkDataChunk encoded =
        encode_link_data(input.data(), input.size());
    report.check(encoded.input_consumed == input.size(),
                 "protected bytes were not fully consumed");
    report.check(encoded.wire_size == kLinkDataMaxWireBytes,
                 "protected bytes have an unexpected wire length");
    for (std::size_t index = 0; index < expected.size(); ++index) {
      report.check(encoded.wire_bytes[index] == expected[index],
                   "protected byte escaping differs from the wire format");
    }
  } else if (test_id == "UT-LINK-003") {
    std::array<std::uint8_t, 33> input{};
    input.fill(0x41U);
    input[31] = kLinkDataControlLeadByte;
    const EncodedLinkDataChunk encoded =
        encode_link_data(input.data(), input.size());
    report.check(encoded.wire_size <= kLinkDataMaxWireBytes,
                 "encoded chunk exceeded the 32-byte physical write limit");
    report.check(encoded.input_consumed == 31U,
                 "encoder emitted a partial escape at the write boundary");
    report.check(encoded.wire_size == kLinkDataMaxWireBytes,
                 "encoder consumed the protected boundary byte incorrectly");

    const EncodedLinkDataChunk too_small =
        encode_link_data(&input[31], 1U, 1U);
    report.check(too_small.input_consumed == 0U &&
                     too_small.wire_size == 0U,
                 "protected byte was split across physical writes");
  } else if (test_id == "UT-LINK-004") {
    const auto application_data = make_raw_control(report);
    std::array<std::uint8_t, kTddControlFrameSize> decoded{};
    std::size_t decoded_size = 0;
    std::uint32_t control_count = 0;
    std::size_t application_offset = 0U;
    std::size_t physical_writes = 0U;
    TddLinkDemux demux{true};

    while (application_offset < application_data.size()) {
      const EncodedLinkDataChunk encoded = encode_link_data(
          application_data.data() + application_offset,
          application_data.size() - application_offset);
      report.check(encoded.input_consumed > 0U &&
                       encoded.wire_size <= kLinkDataMaxWireBytes,
                   "escaped VCTD application data made no bounded progress");
      if (encoded.input_consumed == 0U) {
        break;
      }
      ++physical_writes;
      for (std::size_t index = 0; index < encoded.wire_size; ++index) {
        const TddDemuxEvent event = demux.push(encoded.wire_bytes[index]);
        append_local_bytes(event, decoded, decoded_size, report);
        if (event.has_control) {
          ++control_count;
        }
      }
      application_offset += encoded.input_consumed;
    }
    report.check(application_offset == application_data.size(),
                 "escaped VCTD application data was not fully consumed");
    report.check(physical_writes >= 2U,
                 "32-byte VCTD-shaped application fixture did not exercise "
                 "multi-write escaping");
    report.check(control_count == 0U,
                 "escaped VCTD application data was consumed as control");
    report.check(decoded_size == application_data.size(),
                 "escaped VCTD application data changed length");
    report.check(decoded == application_data,
                 "escaped VCTD application data did not round-trip");
  } else if (test_id == "UT-LINK-005") {
    constexpr std::array<std::uint8_t, 4> local_input{
        {0x56U, 0x7DU, 0xFDU, 0x01U}};
    const EncodedLinkDataChunk encoded =
        encode_link_data(local_input.data(), local_input.size());
    const auto raw_control = make_raw_control(report);
    std::array<std::uint8_t, local_input.size()> decoded{};
    std::size_t decoded_size = 0;
    std::uint32_t control_count = 0;
    TddLinkDemux demux{true};

    report.check(encoded.wire_size >= 2U,
                 "test data did not contain an escape pair");
    append_local_bytes(demux.push(encoded.wire_bytes[0]), decoded,
                       decoded_size, report);
    report.check(demux.buffered_size() == 1U,
                 "escape prefix was not retained across chunks");
    for (std::size_t index = 1; index < encoded.wire_size; ++index) {
      append_local_bytes(demux.push(encoded.wire_bytes[index]), decoded,
                         decoded_size, report);
    }
    for (const auto byte : raw_control) {
      const TddDemuxEvent event = demux.push(byte);
      append_local_bytes(event, decoded, decoded_size, report);
      if (event.has_control) {
        report.check(event.control.status == DecodeStatus::Message,
                     "raw control containing escape-byte values was altered");
        ++control_count;
      }
    }

    report.check(control_count == 1U,
                 "raw VCTD control was not extracted exactly once");
    report.check(decoded_size == local_input.size(),
                 "chunk-split escaped data changed length");
    report.check(decoded == local_input,
                 "chunk-split escaped data did not round-trip");
  } else if (test_id == "UT-LINK-006") {
    constexpr std::array<std::uint8_t, 8> input{
        {'V', 'C', 'X', 0x01U, 'V', 'Y', 0x02U, 0x03U}};
    std::array<std::uint8_t, input.size()> output{};
    std::size_t output_size = 0;
    std::uint32_t control_count = 0;
    TddLinkDemux demux{};
    for (const auto byte : input) {
      const TddDemuxEvent event = demux.push(byte);
      append_local_bytes(event, output, output_size, report);
      if (event.has_control) {
        ++control_count;
      }
    }
    report.check(control_count == 0U,
                 "invalid magic prefix produced a control event");
    report.check(output_size == input.size(),
                 "invalid magic prefix changed local byte count");
    report.check(output == input,
                 "invalid magic prefix changed local byte order");

    TddLinkDemux escaping_demux{true};
    escaping_demux.push(kLinkDataEscapeByte);
    report.check(escaping_demux.buffered_size() == 1U,
                 "trailing escape was not buffered");
    escaping_demux.reset();
    report.check(escaping_demux.buffered_size() == 0U,
                 "reset did not clear a pending escape");

    auto corrupted_control = make_raw_control(report);
    corrupted_control[1] ^= 0x01U;
    std::size_t quarantined_local_bytes = 0U;
    std::size_t rejected_control_frames = 0U;
    for (const std::uint8_t byte : corrupted_control) {
      const TddDemuxEvent event = escaping_demux.push(byte);
      quarantined_local_bytes += event.local_size;
      if (event.has_control) {
        ++rejected_control_frames;
        report.check(event.control.status != DecodeStatus::Message,
                     "corrupted control was accepted as valid");
      }
    }
    report.check(quarantined_local_bytes == 0U,
                 "corrupted raw control prefix leaked to application data");
    report.check(rejected_control_frames == 1U,
                 "corrupted raw control was not quarantined as one frame");
  } else {
    report.check(false, "unknown link data codec test ID");
  }

  report.trace.record({0, "host", "LINK_DATA", 0,
                       report.passed ? "PASS" : "FAIL", true, 0, 0, 0});
  return report;
}

}  // namespace vc_lora::test

#ifdef VC_LORA_LINK_CODEC_STANDALONE
int main() {
  constexpr std::array<const char*, 6> kTestIds{{
      "UT-LINK-001", "UT-LINK-002", "UT-LINK-003",
      "UT-LINK-004", "UT-LINK-005", "UT-LINK-006",
  }};
  for (const char* test_id : kTestIds) {
    if (!vc_lora::test::run_link_data_codec_test(test_id, 20260817U)
             .passed) {
      return 1;
    }
  }
  return 0;
}
#endif
