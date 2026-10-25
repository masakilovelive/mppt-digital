#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

namespace {
std::string read_file(const char* path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input), {});
}
std::string function_body(const std::string& source, const std::string& name) {
  const auto start = source.find(name);
  const auto begin = source.find('{', start);
  if (begin == std::string::npos) return {};
  std::size_t depth = 1U;
  for (auto cursor = begin + 1U; cursor < source.size(); ++cursor) {
    if (source[cursor] == '{') ++depth;
    if (source[cursor] == '}' && --depth == 0U)
      return source.substr(begin, cursor - begin + 1U);
  }
  return {};
}
}

int main() {
  const auto bridge = read_file("firmware/phase6/vc_lora_phase6_bridge.hpp");
  const auto record = read_file("firmware/high_speed/r19_runtime_stage_record.hpp");
  std::size_t checks = 0U;
  std::size_t failures = 0U;
  const auto check = [&](bool passed, const char* text) {
    ++checks;
    if (!passed) { ++failures; std::cerr << "FAIL: " << text << '\n'; }
  };
  check(!bridge.empty() && !record.empty(), "record or bridge source missing");
  check(bridge.find("#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\n#include \"high_speed/r19_runtime_fail_diagnostic.hpp\"\n#include \"high_speed/r19_runtime_stage_record.hpp\"") != std::string::npos,
        "Ground commit record include must remain diagnostic-only");
  check(bridge.find("__attribute__((used, aligned(4))) R19GroundUsbCommitRecord\n    vc_lora_r19_ground_usb_commit_record{};") != std::string::npos,
        "unmangled aligned JTAG symbol disappeared");
  const auto init = function_body(bridge, "void r19_initialize_runtime_stage_record()");
  check(init.find("vc_lora_r19_ground_usb_commit_record.initialize(") != std::string::npos &&
            init.find("kR19RuntimeStageRole, kR19RuntimeDiagnosticGenerationFingerprint") != std::string::npos,
        "record must bind both roles and the candidate generation during boot");
  const auto observe = function_body(bridge, "void observe_ground_paced_heartbeat_commit(");
  check(observe.find("R19GroundUsbCommitFailureReason::BeforeFlushDeadline") != std::string::npos &&
            observe.find("R19GroundUsbCommitFailureReason::PublicationRejected") != std::string::npos &&
            observe.find("R19GroundUsbCommitFailureReason::PacerCompletionRejected") != std::string::npos &&
            observe.find("commit_evidence.predicate_true_mask != 7U") != std::string::npos,
        "first product heartbeat branches lack failure-only predicate capture");
  const auto capture = function_body(bridge, "R19GroundUsbCommitEvidence r19_ground_heartbeat_commit_evidence(");
  check(capture.find("transport_observed ? 7U : 6U") != std::string::npos &&
            capture.find("ground_usb_endpoint_ready_state ? 2U : 0U") != std::string::npos &&
            capture.find("completed_ms <= ground_paced_heartbeat_commit_deadline_ms ? 4U : 0U") != std::string::npos &&
            capture.find("evidence.accepted_frame_bytes") != std::string::npos,
        "predicate observation mask or exact-frame acceptance accounting missing");
  check(record.find("sizeof(R19GroundUsbCommitRecord) == 128U") != std::string::npos &&
            record.find("std::atomic_signal_fence") != std::string::npos &&
            record.find("volatile std::uint32_t words_[storage_word_count]") != std::string::npos &&
            record.find("words_[9U] != 0U") != std::string::npos,
        "fixed-size single-writer first-wins record contract changed");
  check(record.find("Serial.") == std::string::npos &&
            record.find("writeTx") == std::string::npos &&
            record.find("Arduino.h") == std::string::npos,
        "JTAG record must never emit CDC/RF/UART bytes or depend on Arduino");
  std::cout << "UT-R19-GROUND-USB-COMMIT-SOURCE-001 checks=" << checks
            << " failures=" << failures << '\n';
  return failures == 0U ? 0 : 1;
}
