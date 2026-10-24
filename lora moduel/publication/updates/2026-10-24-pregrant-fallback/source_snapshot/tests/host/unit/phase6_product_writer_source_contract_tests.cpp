#include "test_support.hpp"

#include <cstddef>
#include <cstdint>
#include <fstream>
#include <sstream>
#include <string>

#ifndef VC_LORA_SOURCE_ROOT
#define VC_LORA_SOURCE_ROOT "."
#endif

namespace vc_lora::test {
namespace {

std::string read_file(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  std::ostringstream content;
  content << input.rdbuf();
  return content.str();
}

std::size_t count_occurrences(const std::string& text,
                              const std::string& needle) {
  std::size_t count = 0U;
  std::size_t offset = 0U;
  while ((offset = text.find(needle, offset)) != std::string::npos) {
    ++count;
    offset += needle.size();
  }
  return count;
}

bool ordered(const std::string& text, const std::string& first,
             const std::string& second) {
  const std::size_t first_offset = text.find(first);
  const std::size_t second_offset = text.find(second);
  return first_offset != std::string::npos &&
         second_offset != std::string::npos && first_offset < second_offset;
}

void test_product_writer_source_contract(TestReport& report) {
  const std::string bridge = read_file(
      std::string{VC_LORA_SOURCE_ROOT} +
      "/firmware/phase6/vc_lora_phase6_bridge.hpp");
  report.check(!bridge.empty(), "Phase6 product bridge source is unreadable");

  report.check(
      bridge.find("#ifndef VC_LORA_R19_HIGH_SPEED_CANDIDATE") !=
              std::string::npos &&
          bridge.find("#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 0") !=
              std::string::npos &&
          bridge.find("VC_LORA_R19_HIGH_SPEED_CANDIDATE must be 0 or 1") !=
              std::string::npos,
      "R19 product writer is not an explicit default-disabled opt-in");
  report.check(
      bridge.find("high_speed/phase6_radio_writer_arbiter.hpp") !=
              std::string::npos &&
          bridge.find("../high_speed/phase6_radio_writer_arbiter.hpp") ==
              std::string::npos &&
          count_occurrences(bridge,
                            "Phase6RadioWriterArbiter e220_writer_arbiter") ==
              1U,
      "product bridge does not own exactly one physical E220 writer arbiter");

  report.check(
      bridge.find("acquire_standard_radio_writer_lease") !=
              std::string::npos &&
          bridge.find("Phase6RadioWriterOwner::StandardTdd") !=
              std::string::npos &&
          bridge.find("Phase6RadioWriterStatus::LeaseGranted") !=
              std::string::npos &&
          ordered(bridge, "acquire_standard_radio_writer_lease(action)",
                  "e220_serial.write(wire, wire_size)"),
      "standard TDD write is not fenced by a pre-write StandardTdd lease");
  report.check(
      bridge.find("release_rejected_standard_radio_writer_lease") !=
              std::string::npos &&
          bridge.find("Phase6RadioWriterUartResult::Rejected") !=
              std::string::npos &&
          bridge.find("Phase6RadioWriterStatus::RejectedReleased") !=
              std::string::npos,
      "rejected UART writes do not release the exact standard lease");
  report.check(
      bridge.find("retain_accepted_standard_radio_writer_lease") !=
              std::string::npos &&
          bridge.find("Phase6RadioWriterUartResult::Accepted") !=
              std::string::npos &&
          bridge.find("Phase6RadioWriterStatus::AcceptedAwaitingTail") !=
              std::string::npos &&
          bridge.find("standard_radio_writer_tail_pending = true") !=
              std::string::npos,
      "accepted UART write does not retain owner/token/generation to RF tail");
  report.check(
      bridge.find("complete_standard_radio_writer_physical_tail") !=
              std::string::npos &&
          bridge.find("e220_writer_arbiter.observe_physical_tail(") !=
              std::string::npos &&
          ordered(bridge, "e220_write_contract.take_write_completion()",
                  "complete_standard_radio_writer_physical_tail(now_ms)"),
      "physical E220 completion does not release the exact arbiter lease");

  report.check(
      bridge.find("struct R19StandardVehicleGrantTailEvidence") !=
              std::string::npos &&
          bridge.find("Phase6RadioTailEvidence tail{}") !=
              std::string::npos &&
          bridge.find("TddControlMessage grant{}") != std::string::npos &&
          bridge.find("retained_standard_vehicle_grant_tail") !=
              std::string::npos &&
          bridge.find("standard_radio_writer_action_type ==\n"
                      "      LinkActionType::SendGrant") != std::string::npos,
      "accepted and drained Vehicle Grant evidence is not retained");

  report.check(
      bridge.find("activate_r19_high_speed_candidate") !=
              std::string::npos &&
          bridge.find("e220_writer_arbiter.activate_high_speed()") !=
              std::string::npos &&
          bridge.find("complete_r19_high_speed_candidate") !=
              std::string::npos &&
          bridge.find("restore_standard_tdd_after_r19_candidate") !=
              std::string::npos,
      "candidate activation and explicit-restore hooks are absent");
  report.check(
      bridge.find("r19_standard_tdd_tick_allowed") != std::string::npos &&
          bridge.find("e220_writer_arbiter.high_speed_active()") !=
              std::string::npos &&
          bridge.find("e220_writer_arbiter.explicit_restore_required()") !=
              std::string::npos &&
          ordered(bridge, "if (!r19_standard_tdd_tick_allowed())",
                  "tdd_controller.tick(make_tdd_input(now_ms))"),
      "candidate activation does not freeze standard TDD tick/poll");
  report.check(
      count_occurrences(bridge, "latch_runtime_fail_closed();") >= 12U &&
          bridge.find("Phase6RadioWriterStatus::FailClosed") !=
              std::string::npos,
      "writer overlap or mismatched physical tail is not fail-closed");

  const std::size_t candidate_guard =
      bridge.find("#if VC_LORA_R19_HIGH_SPEED_CANDIDATE");
  const std::size_t adapter_include = bridge.find(
      "#include \"high_speed/high_speed_phase6_adapter.hpp\"");
  const std::size_t candidate_route =
      bridge.find("r19_route_bulk_negotiation(");
  report.check(
      candidate_guard != std::string::npos &&
          adapter_include != std::string::npos &&
          candidate_route != std::string::npos &&
          candidate_guard < adapter_include && candidate_guard < candidate_route,
      "R19 adapter/demux route is not isolated by the default-off feature gate");
  for (const std::string& role : {
           std::string{"vc_lora_ground_xiao_esp32s3"},
           std::string{"vc_lora_vehicle_xiao_esp32s3"}}) {
    const std::string wrapper = read_file(
        std::string{VC_LORA_SOURCE_ROOT} + "/" + role + "/" + role +
        ".ino");
    report.check(!wrapper.empty() &&
                     wrapper.find("VC_LORA_R19_HIGH_SPEED_CANDIDATE") ==
                         std::string::npos,
                 "default production wrapper enables the R19 feature gate");
  }
}

}  // namespace

TestReport run_phase6_product_writer_source_contract_test(
    const std::string& test_id, std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id == "UT-HS-PRODUCT-WRITER-SOURCE-001") {
    test_product_writer_source_contract(report);
  } else {
    report.check(false, "unknown Phase6 product writer source test ID");
  }
  return report;
}

}  // namespace vc_lora::test
