#include "test_support.hpp"

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <iostream>
#include <string>

namespace vc_lora::test {
namespace {

struct Options {
  std::string test_case{};
  std::uint32_t seed{20260817U};
  std::filesystem::path output_dir{};
  std::filesystem::path trace_path{};
  bool trace_requested{false};
};

std::string json_escape(const std::string& value) {
  std::string output;
  output.reserve(value.size() + 8U);
  for (const char raw_character : value) {
    const auto character = static_cast<unsigned char>(raw_character);
    switch (character) {
      case '"':
        output += "\\\"";
        break;
      case '\\':
        output += "\\\\";
        break;
      case '\n':
        output += "\\n";
        break;
      case '\r':
        output += "\\r";
        break;
      case '\t':
        output += "\\t";
        break;
      default:
        if (character < 0x20U) {
          output += '?';
        } else {
          output += static_cast<char>(character);
        }
        break;
    }
  }
  return output;
}

bool parse_u32(const std::string& value, std::uint32_t& output) {
  try {
    std::size_t consumed = 0;
    const auto parsed = std::stoull(value, &consumed, 10);
    if (consumed != value.size() || parsed > 0xFFFFFFFFULL) {
      return false;
    }
    output = static_cast<std::uint32_t>(parsed);
    return true;
  } catch (...) {
    return false;
  }
}

bool parse_options(int argc, char** argv, Options& options,
                   std::string& error) {
  for (int index = 1; index < argc; ++index) {
    const std::string argument = argv[index];
    const auto split = argument.find('=');
    const std::string key = argument.substr(0, split);
    const std::string value =
        split == std::string::npos ? std::string{} : argument.substr(split + 1U);
    if (key == "--test-case" && !value.empty()) {
      options.test_case = value;
    } else if (key == "--seed" && !value.empty()) {
      if (!parse_u32(value, options.seed)) {
        error = "invalid --seed value";
        return false;
      }
    } else if (key == "--output-dir" && !value.empty()) {
      options.output_dir = value;
    } else if (key == "--trace" && !value.empty()) {
      options.trace_path = value;
      options.trace_requested = true;
    } else if (argument == "--help") {
      error = "usage: vc_lora_host_tests --test-case=ID [--seed=N] "
              "[--output-dir=DIR] [--trace=FILE]";
      return false;
    } else {
      error = "unknown or incomplete argument: " + argument;
      return false;
    }
  }
  if (options.test_case.empty()) {
    error = "--test-case is required";
    return false;
  }
  if (options.output_dir.empty()) {
    options.output_dir = std::filesystem::path("runs") / options.test_case;
  }
  if (!options.trace_requested) {
    options.trace_path = options.output_dir / "trace.csv";
  }
  return true;
}

bool write_summary(const std::filesystem::path& path,
                   const TestReport& report,
                   const std::filesystem::path& output_dir,
                   const std::filesystem::path& trace_path) {
  std::error_code error;
  std::filesystem::create_directories(path.parent_path(), error);
  std::FILE* output = std::fopen(path.string().c_str(), "wb");
  if (output == nullptr) {
    return false;
  }
  const auto& d = report.diagnostics;
  std::string json;
  const auto add_number = [&json](const char* key, std::uint64_t value,
                                  bool comma = true) {
    json += "  \"";
    json += key;
    json += "\": ";
    json += std::to_string(value);
    json += comma ? ",\n" : "\n";
  };
  json += "{\n  \"test\": \"" + json_escape(report.test_id) + "\",\n";
  add_number("seed", report.seed);
  add_number("cycles", report.cycles);
  add_number("grant_tx", d.grant_tx);
  add_number("grant_rx", d.grant_rx);
  add_number("done_tx", d.done_tx);
  add_number("done_rx", d.done_rx);
  add_number("idle_tx", d.idle_tx);
  add_number("idle_rx", d.idle_rx);
  add_number("uplink_transactions", d.uplink_transactions);
  add_number("uplink_payload_bytes", d.uplink_payload_bytes);
  add_number("downlink_transactions", d.downlink_transactions);
  add_number("downlink_payload_bytes", d.downlink_payload_bytes);
  add_number("uplink_timeouts", d.uplink_timeouts);
  add_number("collision_count", d.collision_count);
  add_number("packet_loss_count", d.packet_loss_count);
  add_number("control_crc_errors", d.control_crc_errors);
  add_number("invalid_crc_state_transition",
             d.invalid_crc_state_transition);
  add_number("tx_gate_violation", d.tx_gate_violation);
  add_number("tx_during_rx_window_count", d.tx_during_rx_window_count);
  add_number("ground_tx_without_valid_grant",
             d.ground_tx_without_valid_grant);
  add_number("control_bytes_leaked_to_local_uart",
             d.control_bytes_leaked_to_local_uart);
  add_number("duplicate_grants", d.duplicate_grants);
  add_number("stale_cycles", d.stale_cycles);
  add_number("future_cycles", d.future_cycles);
  add_number("stale_sessions", d.stale_sessions);
  add_number("session_changes", d.session_changes);
  add_number("expired_windows", d.expired_windows);
  add_number("insufficient_window_count", d.insufficient_window_count);
  add_number("action_retries", d.action_retries);
  add_number("abandoned_uplink_transactions",
             d.abandoned_uplink_transactions);
  add_number("turnaround_drop_count", d.turnaround_drop_count);
  add_number("half_duplex_drop_count", d.half_duplex_drop_count);
  add_number("uart_buffer_drop_count", d.uart_buffer_drop_count);
  add_number("uplink_data_outside_receive_window",
             d.uplink_data_outside_receive_window);
  add_number("ground_usb_rx_bytes", d.ground_usb_rx_bytes);
  add_number("ground_usb_accepted_bytes", d.ground_usb_accepted_bytes);
  add_number("ground_usb_dropped_bytes", d.ground_usb_dropped_bytes);
  add_number("ground_usb_dequeued_bytes", d.ground_usb_dequeued_bytes);
  add_number("ground_buffer_overflow_count",
             d.ground_buffer_overflow_count);
  add_number("ground_payload_order_errors",
             d.ground_payload_order_errors);
  add_number("ground_queue_underflow_count",
             d.ground_queue_underflow_count);
  add_number("mavlink_frames_ingested", d.mavlink_frames_ingested);
  add_number("mavlink_frames_forwarded", d.mavlink_frames_forwarded);
  add_number("mavlink_frames_filtered", d.mavlink_frames_filtered);
  add_number("mavlink_msg194_filtered_frames",
             d.mavlink_msg194_filtered_frames);
  add_number("mavlink_msg194_filtered_bytes",
             d.mavlink_msg194_filtered_bytes);
  add_number("mavlink_crc_errors", d.mavlink_crc_errors);
  add_number("mavlink_parser_resets", d.mavlink_parser_resets);
  add_number("mavlink_queue_drop_frames", d.mavlink_queue_drop_frames);
  add_number("mavlink_queue_drop_bytes", d.mavlink_queue_drop_bytes);
  add_number("partial_mavlink_delivered", d.partial_mavlink_delivered);
  add_number("max_mavlink_queue_frames", d.max_mavlink_queue_frames);
  add_number("max_mavlink_queue_bytes", d.max_mavlink_queue_bytes);
  add_number("heartbeat_valid", d.heartbeat_valid);
  add_number("heartbeat_max_gap_ms", d.heartbeat_max_gap_ms);
  add_number("heartbeat_grant_deferrals", d.heartbeat_grant_deferrals);
  add_number("heartbeat_deadline_misses", d.heartbeat_deadline_misses);
  add_number("param_requests_rx", d.param_requests_rx);
  add_number("param_values_rx", d.param_values_rx);
  add_number("param_sets_rx", d.param_sets_rx);
  add_number("param_updates", d.param_updates);
  add_number("command_long_rx", d.command_long_rx);
  add_number("command_ack_rx", d.command_ack_rx);
  add_number("max_vehicle_queue", d.max_vehicle_queue);
  add_number("max_ground_queue", d.max_ground_queue);
  add_number("stress_fault_injections", report.stress.fault_injections);
  add_number("stress_recoveries", report.stress.recoveries);
  add_number("stress_reboot_events", report.stress.reboot_events);
  add_number("stress_aux_busy_events", report.stress.aux_busy_events);
  add_number("stress_max_recovery_cycles",
             report.stress.max_recovery_cycles);
  add_number("stress_max_cycle_runtime_ms",
             report.stress.max_cycle_runtime_ms);
  add_number("stress_trace_retained_events",
             report.stress.trace_retained_events);
  add_number("stress_rf_retained_transmissions",
             report.stress.rf_retained_transmissions);
  add_number("stress_rf_max_retained_transmissions",
             report.stress.rf_max_retained_transmissions);
  add_number("stress_rf_pending_deliveries",
             report.stress.rf_pending_deliveries);
  add_number("stress_rf_max_pending_deliveries",
             report.stress.rf_max_pending_deliveries);
  add_number("stress_mavlink_vehicle_frames",
             report.stress.mavlink_vehicle_frames);
  add_number("stress_mavlink_ground_frames",
             report.stress.mavlink_ground_frames);
  add_number("stress_mavlink_vehicle_stream_hash",
             report.stress.mavlink_vehicle_stream_hash);
  add_number("stress_mavlink_ground_stream_hash",
             report.stress.mavlink_ground_stream_hash);
  add_number("stress_heartbeat_gap_before_rx_ms",
             report.stress.heartbeat_gap_before_rx_ms);
  add_number("stress_heartbeat_gap_after_rx_ms",
             report.stress.heartbeat_gap_after_rx_ms);
  add_number("stress_heartbeat_gap_before_tx_start_ms",
             report.stress.heartbeat_gap_before_tx_start_ms);
  add_number("stress_heartbeat_gap_before_tx_end_ms",
             report.stress.heartbeat_gap_before_tx_end_ms);
  add_number("stress_heartbeat_gap_after_tx_start_ms",
             report.stress.heartbeat_gap_after_tx_start_ms);
  add_number("stress_heartbeat_gap_after_tx_end_ms",
             report.stress.heartbeat_gap_after_tx_end_ms);
  add_number("stress_heartbeat_gap_before_terminal_ms",
             report.stress.heartbeat_gap_before_terminal_ms);
  add_number("stress_heartbeat_gap_after_terminal_ms",
             report.stress.heartbeat_gap_after_terminal_ms);
  add_number("stress_heartbeat_gap_before_wire_count",
             report.stress.heartbeat_gap_before_wire_count);
  add_number("stress_heartbeat_gap_after_wire_count",
             report.stress.heartbeat_gap_after_wire_count);
  add_number("stress_heartbeat_gap_before_cycle",
             report.stress.heartbeat_gap_before_cycle);
  add_number("stress_heartbeat_gap_after_cycle",
             report.stress.heartbeat_gap_after_cycle);
  add_number("stress_heartbeat_gap_before_state",
             report.stress.heartbeat_gap_before_state);
  add_number("stress_heartbeat_gap_after_state",
             report.stress.heartbeat_gap_after_state);
  add_number("vehicle_session", report.vehicle_session);
  add_number("ground_session", report.ground_session);
  add_number("vehicle_cycle", report.vehicle_cycle);
  add_number("ground_cycle", report.ground_cycle);
  json += "  \"final_vehicle_state\": \"" +
          json_escape(report.final_vehicle_state) + "\",\n";
  json += "  \"final_ground_state\": \"" +
          json_escape(report.final_ground_state) + "\",\n";
  json += std::string("  \"expected_failure\": ") +
          (report.expected_failure ? "true" : "false") + ",\n";
  json += "  \"first_failure\": \"" + json_escape(report.first_failure) +
          "\",\n";
  json += "  \"detail\": \"" + json_escape(report.detail) + "\",\n";
  const auto relative_command_path = [](const std::filesystem::path& value) {
    if (!value.is_absolute()) {
      return value.generic_string();
    }
    std::error_code relative_error;
    const std::filesystem::path relative = std::filesystem::relative(
        value, std::filesystem::current_path(), relative_error);
    return relative_error ? value.generic_string() : relative.generic_string();
  };
  const std::string reproduce =
      ".\\build\\host\\tests\\host\\vc_lora_host_tests.exe --test-case=" +
      report.test_id + " --seed=" + std::to_string(report.seed) +
      " --output-dir=" + relative_command_path(output_dir) + " --trace=" +
      relative_command_path(trace_path);
  json += "  \"reproduce\": \"" + json_escape(reproduce) + "\",\n";
  const char* result = report.expected_failure
                           ? (report.passed ? "XPASS" : "XFAIL")
                           : (report.passed ? "PASS" : "FAIL");
  json += std::string("  \"result\": \"") + result + "\"\n}\n";
  const bool wrote =
      std::fwrite(json.data(), 1U, json.size(), output) == json.size();
  return std::fclose(output) == 0 && wrote;
}

TestReport dispatch(const std::string& test_case, std::uint32_t seed) {
  if (test_case == "FW-BUF-001" || test_case == "FW-UART-001" ||
      test_case == "FW-USB-DISCONNECT-001") {
    return run_embedded_adapter_test(test_case, seed);
  }
  if (test_case.rfind("FW-MAV-", 0) == 0U ||
      test_case.rfind("FW-SCHED-", 0) == 0U) {
    return run_mavlink_unit_test(test_case, seed);
  }
  if (test_case == "FW-UPLINK-RESIDUAL-CONTRACT-001") {
    return run_uplink_residual_test(test_case, seed);
  }
  if (test_case == "FW-CONTROL-WIRE-001") {
    return run_control_v2_test(test_case, seed);
  }
  if (test_case == "FW-E220-STARTUP-001") {
    return run_e220_startup_contract_test(test_case, seed);
  }
  if (test_case.rfind("FW-", 0) == 0U) {
    return run_runtime_contract_test(test_case, seed);
  }
  if (test_case.rfind("ST-", 0) == 0U) {
    return run_phase5_stress_test(test_case, seed);
  }
  if (test_case.rfind("E2E-MAV-", 0) == 0U) {
    return run_mavlink_e2e_test(test_case, seed);
  }
  if (test_case.rfind("UT-LINK-ACCOUNT-", 0) == 0U) {
    return run_encoded_accounting_test(test_case, seed);
  }
  if (test_case.rfind("UT-LINK-", 0) == 0U) {
    return run_link_data_codec_test(test_case, seed);
  }
  if (test_case.rfind("UT-BULK-WIRE-", 0) == 0U ||
      test_case.rfind("IT-BULK-", 0) == 0U) {
    return run_bulk_data_codec_test(test_case, seed);
  }
  if (test_case.rfind("UT-BULK-TX-LEASE-", 0) == 0U) {
    return run_bulk_tx_lease_test(test_case, seed);
  }
  if (test_case.rfind("UT-BULK-HB-POLICY-", 0) == 0U) {
    return run_bulk_heartbeat_policy_test(test_case, seed);
  }
  if (test_case.rfind("UT-BULK-HB-SLA-", 0) == 0U) {
    return run_bulk_heartbeat_sla_test(test_case, seed);
  }
  if (test_case.rfind("UT-BULK-TRANSCRIPT-", 0) == 0U) {
    return run_bulk_transcript_test(test_case, seed);
  }
  if (test_case.rfind("UT-BULK-NEG-WIRE-", 0) == 0U) {
    return run_bulk_negotiation_codec_test(test_case, seed);
  }
  if (test_case.rfind("UT-BULK-SESSION-", 0) == 0U) {
    return run_bulk_session_controller_test(test_case, seed);
  }
  if (test_case.rfind("UT-HS-TDD-COORD-", 0) == 0U) {
    return run_high_speed_tdd_coordinator_test(test_case, seed);
  }
  if (test_case.rfind("UT-HS-PHASE6-ADAPTER-", 0) == 0U) {
    return run_high_speed_phase6_adapter_test(test_case, seed);
  }
  if (test_case.rfind("UT-HS-RADIO-WRITER-", 0) == 0U) {
    return run_phase6_radio_writer_arbiter_test(test_case, seed);
  }
  if (test_case.rfind("UT-HS-RADIO-SESSION-", 0) == 0U) {
    return run_phase6_high_speed_radio_session_test(test_case, seed);
  }
  if (test_case.rfind("UT-PEER-COMPLETION-", 0) == 0U ||
      test_case.rfind("UT-HS-PEER-COMPLETION-", 0) == 0U ||
      test_case.rfind("UT-HS-VCRC-", 0) == 0U) {
    return run_peer_completion_receipt_test(test_case, seed);
  }
  if (test_case.rfind("UT-HS-BULK-RX-TAIL-LEDGER-", 0) == 0U) {
    return run_phase6_bulk_rx_tail_ledger_test(test_case, seed);
  }
  if (test_case.rfind("UT-HS-ROLE-CONFIG-", 0) == 0U) {
    return run_phase6_high_speed_role_config_test(test_case, seed);
  }
  if (test_case.rfind("UT-HS-PRODUCT-WRITER-SOURCE-", 0) == 0U) {
    return run_phase6_product_writer_source_contract_test(test_case, seed);
  }
  if (test_case.rfind("UT-HS-PRODUCT-ROUTE-SOURCE-", 0) == 0U) {
    return run_phase6_high_speed_product_route_source_contract_test(test_case,
                                                                    seed);
  }
  if (test_case.rfind("IT-HS-ROUTE-E2E-", 0) == 0U) {
    return run_phase6_high_speed_route_integration_test(test_case, seed);
  }
  if (test_case.rfind("IT-HS-CANDIDATE-STANDARD-", 0) == 0U) {
    return run_r19_candidate_standard_path_test(test_case, seed);
  }
  if (test_case.rfind("UT-MAV-BOUNDARY-", 0) == 0U) {
    return run_vehicle_boundary_test(test_case, seed);
  }
  if (test_case.rfind("IT-UPLINK-GUARD-", 0) == 0U) {
    return run_uplink_guard_integration_test(test_case, seed);
  }
  if (test_case.rfind("IT-UPLINK-LATE-", 0) == 0U) {
    return run_late_uplink_recovery_test(test_case, seed);
  }
  if (test_case.rfind("UT-UPLINK-", 0) == 0U) {
    if (test_case.rfind("UT-UPLINK-RESIDUAL-", 0) == 0U) {
      return run_uplink_residual_test(test_case, seed);
    }
    if (test_case.rfind("UT-UPLINK-LATE-", 0) == 0U) {
      return run_late_uplink_recovery_test(test_case, seed);
    }
    return run_uplink_guard_test(test_case, seed);
  }
  if (test_case.rfind("UT-MAV-", 0) == 0U) {
    return run_mavlink_unit_test(test_case, seed);
  }
  if (test_case.rfind("UT-VEHICLE-PARAM-PRIORITY-", 0) == 0U) {
    return run_vehicle_parameter_priority_test(test_case, seed);
  }
  if (test_case.rfind("UT-BUF-", 0) == 0U) {
    return run_buffer_test(test_case, seed);
  }
  if (test_case.rfind("UT-CONTROL-V2-", 0) == 0U) {
    return run_control_v2_test(test_case, seed);
  }
  if (test_case.rfind("UT-PARAM-PROXY-", 0) == 0U ||
      test_case.rfind("IT-PARAM-PROXY-", 0) == 0U) {
    return run_parameter_proxy_test(test_case, seed);
  }
  if (test_case.rfind("UT-GROUND-USB-HB-PACER-", 0) == 0U ||
      test_case.rfind("IT-GROUND-USB-HB-PACER-", 0) == 0U) {
    return run_ground_usb_heartbeat_pacer_test(test_case, seed);
  }
  if (test_case.rfind("IT-GROUND-USB-HB-PHASE6-", 0) == 0U) {
    return run_ground_usb_heartbeat_phase6_test(test_case, seed);
  }
  if (test_case.rfind("UT-GROUND-USB-HB-BACKLOG-", 0) == 0U) {
    return run_ground_usb_heartbeat_phase6_test(test_case, seed);
  }
  if (test_case.rfind("UT-", 0) == 0U) {
    return run_unit_test(test_case, seed);
  }
  if (test_case.rfind("IT-CONTROL-SUBPACKET-", 0) == 0U) {
    return run_control_subpacket_test(test_case, seed);
  }
  if (test_case.rfind("IT-E220-BUFFERED-", 0) == 0U) {
    return run_buffered_e220_integration_test(test_case, seed);
  }
  if (test_case.rfind("IT-TDD-", 0) == 0U) {
    return run_integration_test(test_case, seed);
  }
  if (test_case.rfind("IT-BUF-", 0) == 0U) {
    return run_buffer_integration_test(test_case, seed);
  }
  if (test_case.rfind("IT-RF-", 0) == 0U) {
    return run_rf_test(test_case, seed);
  }
  if (test_case.rfind("PHASE1-", 0) == 0U) {
    return run_legacy_characterization(test_case, seed);
  }
  TestReport report{};
  report.test_id = test_case;
  report.seed = seed;
  report.check(false, "unknown test case");
  return report;
}

}  // namespace
}  // namespace vc_lora::test

int main(int argc, char** argv) {
  using namespace vc_lora::test;
  Options options{};
  std::string parse_error;
  if (!parse_options(argc, argv, options, parse_error)) {
    std::cerr << parse_error << '\n';
    return 2;
  }

  TestReport report = dispatch(options.test_case, options.seed);
  const std::filesystem::path summary_path =
      options.output_dir / "summary.json";
  if (!write_summary(summary_path, report, options.output_dir,
                     options.trace_path)) {
    std::cerr << "failed to write " << summary_path.string() << '\n';
    return 3;
  }

  const bool write_trace = options.trace_requested || !report.passed ||
                           options.test_case.rfind("PHASE1-", 0) == 0U;
  if (write_trace && !report.trace.write_csv(options.trace_path)) {
    std::cerr << "failed to write " << options.trace_path.string() << '\n';
    return 4;
  }

  const char* result = report.expected_failure
                           ? (report.passed ? "XPASS " : "XFAIL ")
                           : (report.passed ? "PASS " : "FAIL ");
  std::cout << result << report.test_id
            << " seed=" << report.seed << " summary="
            << summary_path.string();
  if (!report.passed) {
    std::cout << " first_failure=\"" << report.first_failure << '"';
  }
  std::cout << '\n';
  return report.passed ? 0 : 1;
}
