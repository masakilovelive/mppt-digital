#include "test_support.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <regex>
#include <sstream>
#include <string>

namespace vc_lora::test {
namespace {

std::string read_text(const std::filesystem::path& path) {
  std::ifstream input{path, std::ios::binary};
  if (!input) {
    return {};
  }
  std::ostringstream text;
  text << input.rdbuf();
  return text.str();
}

std::string function_section(const std::string& text,
                             const std::string& begin_marker) {
  const std::size_t begin = text.find(begin_marker);
  if (begin == std::string::npos) {
    return {};
  }
  const std::size_t open = text.find('{', begin + begin_marker.size());
  if (open == std::string::npos) {
    return {};
  }
  std::size_t depth = 0U;
  for (std::size_t offset = open; offset < text.size(); ++offset) {
    if (text[offset] == '{') {
      ++depth;
    } else if (text[offset] == '}') {
      if (depth == 0U) {
        return {};
      }
      --depth;
      if (depth == 0U) {
        return text.substr(begin, offset - begin + 1U);
      }
    }
  }
  return {};
}

bool matches(const std::string& text, const char* pattern) {
  return std::regex_search(text, std::regex{pattern});
}

std::size_t match_count(const std::string& text, const char* pattern) {
  const std::regex expression{pattern};
  return static_cast<std::size_t>(std::distance(
      std::sregex_iterator{text.begin(), text.end(), expression},
      std::sregex_iterator{}));
}

void finish_report(TestReport& report,
                   const std::filesystem::path& adapter_path) {
  report.detail =
      "E220 setup waits for 5 ms continuous AUX HIGH, performs at most "
      "three independent profile reads, and reports ProfileReadInvalid only "
      "after every attempt fails; bridge_under_test=" +
      adapter_path.generic_string();
  report.trace.record({0, "host", "FW_E220_STARTUP_CONTRACT", 0,
                       report.passed ? "PASS" : "FAIL", true, 0, 0, 0});
}

void test_e220_startup_source_contract(TestReport& report) {
  const char* override_path =
      std::getenv("VC_LORA_PHASE6_BRIDGE_UNDER_TEST");
  const std::filesystem::path adapter_path =
      override_path != nullptr && override_path[0] != '\0'
          ? std::filesystem::path{override_path}
          : std::filesystem::path{VC_LORA_SOURCE_ROOT} / "firmware" /
                "phase6" / "vc_lora_phase6_bridge.hpp";
  const std::string adapter = read_text(adapter_path);
  report.check(!adapter.empty(),
               "production Phase 6 bridge source could not be read");
  if (adapter.empty()) {
    finish_report(report, adapter_path);
    return;
  }

  report.check(matches(adapter,
                       R"(kConfigAuxHighStableMs\s*=\s*5U\s*;)"),
               "setup AUX continuous-HIGH contract is not fixed at 5 ms");
  report.check(matches(adapter,
                       R"(kProfileReadMaxAttempts\s*=\s*3U\s*;)"),
               "profile-read attempt contract is not fixed at three");
  report.check(matches(adapter, R"(kConfigRxQuietMs\s*=\s*5U\s*;)") &&
                   matches(adapter,
                           R"(kConfigRxDrainTimeoutMs\s*=\s*30U\s*;)"),
               "configuration RX quiet/drain bounds are not fixed at 5/30 ms");
  report.check(matches(adapter,
                       R"(kConfigRxDrainReadBudget\s*=\s*64U\s*;)"),
               "configuration RX drain byte budget is not fixed at 64");
  report.check(matches(adapter,
                       R"(kConfigModeSettleMs\s*=\s*200U\s*;)"),
               "E220 mode-pin transition settle time is not fixed at 200 ms");
  const std::string usb_fence = function_section(
      adapter, "bool flush_ground_usb_transport");
  report.check(adapter.find("e220_serial.flush(") == std::string::npos &&
                   adapter.find("pixhawk_serial.flush(") ==
                       std::string::npos,
               "startup contains an unbounded HardwareSerial flush");
  report.check(!usb_fence.empty() &&
                   match_count(adapter,
                               R"(Serial\.flush\(\)\s*;)") == 0U &&
                   match_count(usb_fence,
                               R"(Serial\.flushTxComplete\()") == 1U &&
                   usb_fence.find("budget_ms") != std::string::npos &&
                   adapter.find("kGroundUsbTransportFlushBudgetMs") !=
                       std::string::npos,
               "Ground HWCDC publication fence is not bounded, "
               "result-bearing, and non-destructive");

  const std::string aux_wait =
      function_section(adapter, "bool wait_aux_high_during_setup");
  report.check(!aux_wait.empty(),
               "setup AUX wait helper is missing or no longer bounded");
  report.check(aux_wait.find("kConfigAuxHighStableMs") != std::string::npos,
               "setup AUX wait does not consume the 5-ms stability contract");
  report.check(matches(aux_wait,
                       R"(if\s*\(\s*!aux_high\(\)\s*\)[\s\S]*tracking_high\s*=\s*false)"),
               "AUX LOW does not reset continuous-HIGH tracking");
  report.check(matches(aux_wait,
                       R"(now_ms\s*-\s*high_since_ms\s*>=\s*kConfigAuxHighStableMs[\s\S]*return\s+true)"),
               "setup AUX wait can succeed before 5 ms of continuous HIGH");

  const std::string quiet_drain =
      function_section(adapter, "bool drain_config_rx_until_quiet");
  report.check(!quiet_drain.empty(),
               "bounded configuration RX quiet-drain helper is missing");
  report.check(quiet_drain.find("kConfigRxDrainTimeoutMs") !=
                       std::string::npos &&
                   quiet_drain.find("kConfigRxQuietMs") != std::string::npos,
               "configuration RX drain does not enforce its quiet/timeout bounds");
  report.check(matches(
                   quiet_drain,
                   R"(std::size_t\s+read_budget\s*=\s*kConfigRxDrainReadBudget\s*;)"),
               "configuration RX drain does not reset a bounded byte budget");
  report.check(matches(
                   quiet_drain,
                   R"(while\s*\(\s*read_budget\s*>\s*0U\s*&&\s*monotonic_now_ms\(\)\s*-\s*started_ms\s*<\s*kConfigRxDrainTimeoutMs\s*&&\s*e220_serial\.available\(\)\s*>\s*0\s*\))"),
               "configuration RX inner drain can bypass its byte/time budget");
  report.check(matches(quiet_drain, R"(--read_budget\s*;)"),
               "configuration RX inner drain does not consume its byte budget");
  report.check(!matches(
                   quiet_drain,
                   R"(while\s*\(\s*e220_serial\.available\(\)\s*>\s*0\s*\))"),
               "configuration RX drain retains an unbounded available loop");

  const std::string uart_start =
      function_section(adapter, "bool start_e220_config_uart");
  report.check(!uart_start.empty(),
               "checked configuration UART start helper is missing");
  report.check(matches(
                   uart_start,
                   R"(setRxBufferSize\s*\(\s*kSerialRxBytes\s*\)\s*!=\s*kSerialRxBytes)"),
               "configuration UART start does not verify RX buffer allocation");
  report.check(uart_start.find("static_cast<bool>(e220_serial)") !=
                       std::string::npos &&
                   uart_start.find("drain_config_rx_until_quiet") !=
                       std::string::npos,
               "configuration UART start does not verify driver and RX quiet state");

  const std::string mode_restart =
      function_section(adapter, "bool restart_e220_config_mode");
  report.check(!mode_restart.empty(),
               "complete E220 mode/UART recovery helper is missing");
  report.check(match_count(
                   mode_restart,
                   R"(delay\s*\(\s*kConfigModeSettleMs\s*\))") == 3U,
               "normal/config/failure-recovery transitions do not each receive a 200-ms settle hold");
  report.check(matches(
                   mode_restart,
                   R"(digitalWrite\s*\(\s*kE220M0Pin\s*,\s*LOW\s*\)[\s\S]*digitalWrite\s*\(\s*kE220M1Pin\s*,\s*LOW\s*\)[\s\S]*delay\s*\(\s*kConfigModeSettleMs\s*\)[\s\S]*wait_aux_high_during_setup)"),
               "normal-mode transition is checked before the fixed settle hold");
  report.check(matches(
                   mode_restart,
                   R"(digitalWrite\s*\(\s*kE220M0Pin\s*,\s*HIGH\s*\)[\s\S]*digitalWrite\s*\(\s*kE220M1Pin\s*,\s*HIGH\s*\)[\s\S]*delay\s*\(\s*kConfigModeSettleMs\s*\)[\s\S]*wait_aux_high_during_setup)"),
               "configuration-mode transition is checked before the fixed settle hold");
  report.check(matches(
                   mode_restart,
                   R"(if\s*\(\s*!wait_aux_high_during_setup\s*\(\s*kConfigAuxTimeoutMs\s*\)\s*\)\s*\{\s*digitalWrite\s*\(\s*kE220M0Pin\s*,\s*HIGH\s*\)\s*;\s*digitalWrite\s*\(\s*kE220M1Pin\s*,\s*HIGH\s*\)\s*;\s*delay\s*\(\s*kConfigModeSettleMs\s*\)\s*;\s*return\s+false\s*;\s*\})"),
               "normal-stage AUX timeout does not hold fail-safe HIGH/HIGH for 200 ms");

  const std::string retry =
      function_section(adapter, "bool read_e220_profile_with_retry");
  report.check(!retry.empty(),
               "independent E220 profile-read retry helper is missing");
  report.check(matches(retry,
                       R"(for\s*\([\s\S]*attempt[\s\S]*<\s*kProfileReadMaxAttempts[\s\S]*\+\+attempt)"),
               "profile-read retry loop is not bounded by three attempts");
  report.check(match_count(
                   retry,
                   R"(restart_e220_config_mode\s*\(\s*\))") == 1U,
               "each profile-read attempt does not perform one complete mode/UART recovery");
  report.check(!matches(retry, R"(if\s*\(\s*attempt\s*>\s*0U\s*\))"),
               "the first profile-read attempt bypasses complete mode/UART recovery");
  report.check(matches(
                   retry,
                   R"(restart_e220_config_mode\s*\(\s*\)[\s\S]*observed\s*=\s*\{\}[\s\S]*read_e220_profile\s*\(\s*observed\s*\))"),
               "mode/UART recovery is not completed before every independent read");
  report.check(matches(retry,
                       R"((observed\s*=\s*\{\}|observed\.fill\(0U\))[\s\S]*read_e220_profile\s*\(\s*observed\s*\))"),
               "each profile-read attempt does not start with cleared output");
  report.check(match_count(
                   retry,
                   R"(read_e220_profile\s*\(\s*observed\s*\))") == 1U,
               "retry helper does not issue exactly one independent read per loop iteration");
  report.check(retry.find("verify_e220_profile") == std::string::npos,
               "retry helper reports a transient read failure too early");

  const std::string prepare =
      function_section(adapter, "bool prepare_and_verify_e220_profile");
  report.check(!prepare.empty(),
               "E220 profile preparation helper is missing");
  report.check(matches(
                   prepare,
                   R"(read_e220_profile_with_retry\s*\(\s*observed\s*\))"),
               "profile preparation bypasses the bounded retry helper");
  report.check(match_count(
                   prepare,
                   R"(read_e220_profile\s*\(\s*observed\s*\))") == 0U,
               "profile preparation still performs an unbounded/direct read");
  report.check(match_count(
                   prepare,
                   R"(startup_contract\.verify_e220_profile\s*\()") == 2U,
               "startup profile verification is not confined to one success and one exhaustion branch");
  report.check(match_count(
                   prepare,
                   R"(startup_contract\.verify_e220_profile\s*\(\s*nullptr\s*,\s*0U\s*\))") == 1U,
               "ProfileReadInvalid is not reported exactly once after exhaustion");
  report.check(match_count(
                   prepare,
                   R"(startup_contract\.verify_e220_profile\s*\(\s*observed\.data\(\)\s*,)") ==
                   1U,
               "successful profile data is not verified exactly once");
  report.check(matches(
                   prepare,
                   R"(if\s*\(\s*!valid\s*\)\s*\{\s*return\s+startup_contract\.verify_e220_profile\(nullptr,\s*0U\);\s*\}[\s\S]*return\s+startup_contract\.verify_e220_profile\(observed\.data\(\),)"),
               "startup contract can be notified before all profile reads fail");
  report.check(prepare.find("start_e220_config_uart()") == std::string::npos,
               "profile preparation can fail before entering the bounded retry loop");
  report.check(matches(
                   prepare,
                   R"(e220_serial\.end\(\)\s*;[\s\S]*digitalWrite\s*\(\s*kE220M0Pin\s*,\s*HIGH\s*\)\s*;\s*digitalWrite\s*\(\s*kE220M1Pin\s*,\s*HIGH\s*\)\s*;\s*delay\s*\(\s*kConfigModeSettleMs\s*\)\s*;)"),
               "profile preparation does not hold terminal HIGH/HIGH for 200 ms");

  finish_report(report, adapter_path);
}

}  // namespace

TestReport run_e220_startup_contract_test(const std::string& test_id,
                                          std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "FW-E220-STARTUP-001") {
    test_e220_startup_source_contract(report);
  } else {
    report.check(false, "unknown E220 startup contract test ID");
    finish_report(report, {});
  }
  return report;
}

}  // namespace vc_lora::test
