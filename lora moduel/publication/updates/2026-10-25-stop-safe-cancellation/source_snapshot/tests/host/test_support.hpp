#pragma once

#include <cstdint>
#include <string>

#include "sim/trace_recorder.hpp"
#include "vc_lora/link_diagnostics.hpp"

namespace vc_lora::test {

struct StressMetrics {
  std::uint64_t fault_injections{0};
  std::uint64_t recoveries{0};
  std::uint64_t reboot_events{0};
  std::uint64_t aux_busy_events{0};
  std::uint64_t max_recovery_cycles{0};
  std::uint64_t max_cycle_runtime_ms{0};
  std::uint64_t trace_retained_events{0};
  std::uint64_t rf_retained_transmissions{0};
  std::uint64_t rf_max_retained_transmissions{0};
  std::uint64_t rf_pending_deliveries{0};
  std::uint64_t rf_max_pending_deliveries{0};
  std::uint64_t mavlink_vehicle_frames{0};
  std::uint64_t mavlink_ground_frames{0};
  std::uint64_t mavlink_vehicle_stream_hash{0};
  std::uint64_t mavlink_ground_stream_hash{0};
  std::uint64_t heartbeat_gap_before_rx_ms{0};
  std::uint64_t heartbeat_gap_after_rx_ms{0};
  std::uint64_t heartbeat_gap_before_tx_start_ms{0};
  std::uint64_t heartbeat_gap_before_tx_end_ms{0};
  std::uint64_t heartbeat_gap_after_tx_start_ms{0};
  std::uint64_t heartbeat_gap_after_tx_end_ms{0};
  std::uint64_t heartbeat_gap_before_terminal_ms{0};
  std::uint64_t heartbeat_gap_after_terminal_ms{0};
  std::uint64_t heartbeat_gap_before_wire_count{0};
  std::uint64_t heartbeat_gap_after_wire_count{0};
  std::uint64_t heartbeat_gap_before_cycle{0};
  std::uint64_t heartbeat_gap_after_cycle{0};
  std::uint64_t heartbeat_gap_before_state{0};
  std::uint64_t heartbeat_gap_after_state{0};
};

struct TestReport {
  std::string test_id{};
  std::uint32_t seed{20260817U};
  std::uint64_t cycles{0};
  bool passed{true};
  bool expected_failure{false};
  std::string first_failure{};
  std::string detail{};
  std::string final_vehicle_state{};
  std::string final_ground_state{};
  std::uint16_t vehicle_session{0};
  std::uint16_t ground_session{0};
  std::uint16_t vehicle_cycle{0};
  std::uint16_t ground_cycle{0};
  LinkDiagnostics diagnostics{};
  StressMetrics stress{};
  TraceRecorder trace{};

  void check(bool condition, const std::string& message) {
    if (!condition && passed) {
      passed = false;
      first_failure = message;
    }
  }
};

TestReport run_unit_test(const std::string& test_id, std::uint32_t seed);
TestReport run_buffer_test(const std::string& test_id, std::uint32_t seed);
TestReport run_encoded_accounting_test(const std::string& test_id,
                                       std::uint32_t seed);
TestReport run_link_data_codec_test(const std::string& test_id,
                                    std::uint32_t seed);
TestReport run_bulk_data_codec_test(const std::string& test_id,
                                    std::uint32_t seed);
TestReport run_bulk_tx_lease_test(const std::string& test_id,
                                  std::uint32_t seed);
TestReport run_bulk_heartbeat_policy_test(const std::string& test_id,
                                          std::uint32_t seed);
TestReport run_bulk_heartbeat_sla_test(const std::string& test_id,
                                       std::uint32_t seed);
TestReport run_bulk_transcript_test(const std::string& test_id,
                                    std::uint32_t seed);
TestReport run_bulk_negotiation_codec_test(const std::string& test_id,
                                           std::uint32_t seed);
TestReport run_bulk_session_controller_test(const std::string& test_id,
                                            std::uint32_t seed);
TestReport run_high_speed_tdd_coordinator_test(const std::string& test_id,
                                               std::uint32_t seed);
TestReport run_high_speed_phase6_adapter_test(const std::string& test_id,
                                               std::uint32_t seed);
TestReport run_phase6_radio_writer_arbiter_test(const std::string& test_id,
                                                 std::uint32_t seed);
TestReport run_phase6_high_speed_radio_session_test(
    const std::string& test_id, std::uint32_t seed);
TestReport run_peer_completion_receipt_test(const std::string& test_id,
                                            std::uint32_t seed);
TestReport run_phase6_bulk_rx_tail_ledger_test(
    const std::string& test_id, std::uint32_t seed);
TestReport run_phase6_high_speed_role_config_test(const std::string& test_id,
                                                   std::uint32_t seed);
TestReport run_phase6_product_writer_source_contract_test(
    const std::string& test_id, std::uint32_t seed);
TestReport run_phase6_high_speed_product_route_source_contract_test(
    const std::string& test_id, std::uint32_t seed);
TestReport run_phase6_high_speed_route_integration_test(
    const std::string& test_id, std::uint32_t seed);
TestReport run_r19_candidate_standard_path_test(
    const std::string& test_id, std::uint32_t seed);
TestReport run_mavlink_unit_test(const std::string& test_id,
                                std::uint32_t seed);
TestReport run_vehicle_parameter_priority_test(const std::string& test_id,
                                               std::uint32_t seed);
TestReport run_mavlink_e2e_test(const std::string& test_id,
                               std::uint32_t seed);
TestReport run_vehicle_boundary_test(const std::string& test_id,
                                     std::uint32_t seed);
TestReport run_uplink_guard_test(const std::string& test_id,
                                 std::uint32_t seed);
TestReport run_uplink_residual_test(const std::string& test_id,
                                    std::uint32_t seed);
TestReport run_late_uplink_recovery_test(const std::string& test_id,
                                         std::uint32_t seed);
TestReport run_uplink_guard_integration_test(const std::string& test_id,
                                             std::uint32_t seed);
TestReport run_buffer_integration_test(const std::string& test_id,
                                       std::uint32_t seed);
TestReport run_integration_test(const std::string& test_id,
                                std::uint32_t seed);
TestReport run_legacy_characterization(const std::string& test_id,
                                       std::uint32_t seed);
TestReport run_rf_test(const std::string& test_id, std::uint32_t seed);
TestReport run_phase5_stress_test(const std::string& test_id,
                                  std::uint32_t seed);
TestReport run_embedded_adapter_test(const std::string& test_id,
                                     std::uint32_t seed);
TestReport run_runtime_contract_test(const std::string& test_id,
                                     std::uint32_t seed);
TestReport run_e220_startup_contract_test(const std::string& test_id,
                                          std::uint32_t seed);
TestReport run_control_v2_test(const std::string& test_id,
                               std::uint32_t seed);
TestReport run_control_subpacket_test(const std::string& test_id,
                                      std::uint32_t seed);
TestReport run_parameter_proxy_test(const std::string& test_id,
                                    std::uint32_t seed);
TestReport run_buffered_e220_integration_test(const std::string& test_id,
                                               std::uint32_t seed);
TestReport run_ground_usb_heartbeat_pacer_test(const std::string& test_id,
                                               std::uint32_t seed);
TestReport run_ground_usb_heartbeat_phase6_test(const std::string& test_id,
                                                std::uint32_t seed);

}  // namespace vc_lora::test
