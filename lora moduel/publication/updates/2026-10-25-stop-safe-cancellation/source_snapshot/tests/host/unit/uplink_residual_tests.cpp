#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "fixtures/mavlink_fixtures.hpp"
#include "vc_lora/embedded_io_adapter.hpp"
#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/tdd_link_demux.hpp"

namespace vc_lora::test {
namespace {

struct IngressBoundaryFixture {
  TddLinkDemux demux{true};
  MavlinkValidatedLocalEgressAdapter<> endpoint{};

  void reset_closed_window() noexcept {
    demux.reset();
    // Deliberately retain complete frames already in the egress FIFO.
    endpoint.reset_parser();
  }

  void push_wire(const std::uint8_t* bytes, std::size_t size,
                 bool window_open) noexcept {
    for (std::size_t index = 0U; index < size; ++index) {
      const TddDemuxEvent event = demux.push(bytes[index]);
      for (std::size_t local = 0U;
           window_open && local < event.local_size; ++local) {
        (void)endpoint.ingest_byte(event.local_bytes[local]);
      }
    }
    if (!window_open) {
      reset_closed_window();
    }
  }

  void push_frame(const MavlinkFrame& frame, bool window_open) noexcept {
    std::size_t offset = 0U;
    while (offset < frame.size) {
      const EncodedLinkDataChunk encoded =
          encode_link_data(frame.bytes.data() + offset, frame.size - offset);
      if (encoded.input_consumed == 0U) {
        return;
      }
      push_wire(encoded.wire_bytes.data(), encoded.wire_size, window_open);
      offset += encoded.input_consumed;
    }
  }
};

std::vector<std::uint8_t> encoded_frame(const MavlinkFrame& frame) {
  std::vector<std::uint8_t> wire;
  std::size_t offset = 0U;
  while (offset < frame.size) {
    const EncodedLinkDataChunk encoded =
        encode_link_data(frame.bytes.data() + offset, frame.size - offset);
    if (encoded.input_consumed == 0U) {
      break;
    }
    wire.insert(wire.end(), encoded.wire_bytes.begin(),
                encoded.wire_bytes.begin() + encoded.wire_size);
    offset += encoded.input_consumed;
  }
  return wire;
}

void check_one_exact_frame(const MavlinkFrame& expected,
                           IngressBoundaryFixture& fixture,
                           TestReport& report) {
  std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> output{};
  const std::size_t size =
      fixture.endpoint.egress().peek(output.data(), output.size());
  report.check(size == expected.size,
               "residual ingress changed the complete-frame count");
  report.check(size == expected.size &&
                   std::equal(output.begin(), output.begin() + size,
                              expected.bytes.begin()),
               "residual ingress changed the queued fresh frame");
}

void check_demux_prefix_isolation(std::uint8_t prefix, TestReport& report) {
  IngressBoundaryFixture fixture{};
  fixture.push_wire(&prefix, 1U, false);  // ReturnGuard residue.
  const MavlinkFrame fresh =
      fixtures::param_request_read_v2(0x62U, "ARMING_CHECK");
  fixture.push_frame(fresh, true);  // Next cycle UplinkGuard.
  check_one_exact_frame(fresh, fixture, report);
}

void check_partial_parser_isolation(bool done_transition,
                                    TestReport& report) {
  IngressBoundaryFixture fixture{};
  const MavlinkFrame old_frame =
      fixtures::param_request_read_v2(0x71U, "SERIAL1_BAUD");
  const std::vector<std::uint8_t> old_wire = encoded_frame(old_frame);
  const std::size_t split = 12U;
  report.check(old_wire.size() > split,
               "partial-frame fixture is unexpectedly short");
  if (old_wire.size() <= split) {
    return;
  }

  // A partial frame is admitted in Guard, then DONE or timeout closes the
  // window. The next-cycle suffix must never complete that old frame.
  fixture.push_wire(old_wire.data(), split, true);
  fixture.reset_closed_window();
  fixture.push_wire(old_wire.data() + split, old_wire.size() - split, true);
  report.check(fixture.endpoint.egress().empty(),
               done_transition
                   ? "DONE boundary allowed an old partial frame to complete"
                   : "timeout boundary allowed an old partial frame to complete");

  const MavlinkFrame fresh =
      fixtures::param_request_read_v2(0x72U, "ARMING_CHECK");
  fixture.push_frame(fresh, true);
  check_one_exact_frame(fresh, fixture, report);
}

void check_complete_egress_survives_reset(TestReport& report) {
  IngressBoundaryFixture fixture{};
  const MavlinkFrame queued = fixtures::heartbeat_v2(0x21U);
  fixture.push_frame(queued, true);
  fixture.reset_closed_window();
  check_one_exact_frame(queued, fixture, report);
}

std::string read_file(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

std::size_t count_text(const std::string& text, const std::string& needle) {
  std::size_t count = 0U;
  std::size_t offset = 0U;
  while ((offset = text.find(needle, offset)) != std::string::npos) {
    ++count;
    offset += needle.size();
  }
  return count;
}

void check_firmware_contract(TestReport& report) {
  const std::filesystem::path adapter =
      std::filesystem::path("firmware") / "phase6" /
      "vc_lora_phase6_bridge.hpp";
  const std::string source = read_file(adapter);
  report.check(!source.empty(), "canonical Phase 6 adapter could not be read");
  report.check(source.find("reset_closed_radio_ingress") != std::string::npos,
               "firmware lacks a closed-window ingress reset helper");
  report.check(source.find("radio_demux.reset();") != std::string::npos,
               "firmware does not clear demux residue at a window boundary");
  report.check(
      source.find("radio_application_endpoint.reset_parser();") !=
          std::string::npos,
      "firmware does not clear partial MAVLink state at a window boundary");
  report.check(count_text(source, "reset_closed_radio_ingress(") >= 4U,
               "firmware does not reset before/after RF receive and after TDD tick");
  report.check(source.find("radio_application_endpoint.reset();") ==
                   std::string::npos,
               "firmware boundary reset incorrectly discards completed egress");
}

}  // namespace

TestReport run_uplink_residual_test(const std::string& test_id,
                                    std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-UPLINK-RESIDUAL-ESCAPE-001") {
    check_demux_prefix_isolation(kLinkDataEscapeByte, report);
    report.detail = "ReturnGuard escape prefix cannot poison next Guard";
  } else if (test_id == "UT-UPLINK-RESIDUAL-CONTROL-001") {
    check_demux_prefix_isolation(kLinkDataControlLeadByte, report);
    report.detail = "ReturnGuard V prefix cannot quarantine next Guard";
  } else if (test_id == "UT-UPLINK-RESIDUAL-DONE-001") {
    check_partial_parser_isolation(true, report);
    report.detail = "DONE clears partial MAVLink parser state only";
  } else if (test_id == "UT-UPLINK-RESIDUAL-TIMEOUT-001") {
    check_partial_parser_isolation(false, report);
    report.detail = "timeout clears partial MAVLink parser state only";
  } else if (test_id == "FW-UPLINK-RESIDUAL-CONTRACT-001") {
    check_complete_egress_survives_reset(report);
    check_firmware_contract(report);
    report.detail = "canonical adapter resets transient ingress, retaining egress";
  } else {
    report.check(false, "unknown uplink residual test case");
  }

  report.final_vehicle_state = "TEST_COMPLETE";
  report.final_ground_state = "TEST_COMPLETE";
  return report;
}

}  // namespace vc_lora::test
