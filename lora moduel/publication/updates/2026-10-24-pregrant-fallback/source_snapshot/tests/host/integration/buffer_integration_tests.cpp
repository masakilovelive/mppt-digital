#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

#include "integration/tdd_simulation.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint64_t kCycleTimeoutMs = 7'000U;

template <std::size_t Size>
void fill_pattern(std::array<std::uint8_t, Size>& bytes) {
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    bytes[index] = static_cast<std::uint8_t>((index * 29U + 7U) & 0xFFU);
  }
}

void capture(TestReport& report, const TddSimulation& simulation) {
  report.cycles = simulation.stats().cycles_completed;
  report.diagnostics = simulation.diagnostics();
  report.trace = simulation.trace();
  report.final_vehicle_state = vehicle_state_name(simulation.vehicle().state());
  report.final_ground_state = ground_state_name(simulation.ground().state());
  report.vehicle_session = simulation.vehicle().session_id();
  report.ground_session = simulation.ground().session_id();
  report.vehicle_cycle = simulation.vehicle().cycle_id();
  report.ground_cycle = simulation.ground().cycle_id();
}

void check_phase3_invariants(TestReport& report) {
  const auto& d = report.diagnostics;
  report.check(d.tx_gate_violation == 0U, "Phase 3 TX gate violation");
  report.check(d.tx_during_rx_window_count == 0U,
               "Phase 3 vehicle transmitted during its RX window");
  report.check(d.ground_tx_without_valid_grant == 0U,
               "Phase 3 ground TX occurred without a grant");
  report.check(d.control_bytes_leaked_to_local_uart == 0U,
               "Phase 3 control bytes leaked to local UART");
  report.check(d.invalid_crc_state_transition == 0U,
               "Phase 3 invalid control changed protocol state");
  report.check(d.collision_count == 0U, "Phase 3 RF collision");
  report.check(d.packet_loss_count == 0U, "Phase 3 RF packet loss");
  report.check(d.uplink_data_outside_receive_window == 0U,
               "Phase 3 uplink arrived outside the vehicle RX window");
  report.check(d.ground_payload_order_errors == 0U,
               "Phase 3 payload order/content mismatch");
  report.check(d.ground_queue_underflow_count == 0U,
               "Phase 3 Ground queue underflow");
  report.check(d.ground_usb_accepted_bytes + d.ground_usb_dropped_bytes ==
                   d.ground_usb_rx_bytes,
               "Phase 3 USB ingress accounting does not balance");
  report.check(d.ground_usb_dequeued_bytes <= d.ground_usb_accepted_bytes,
               "Phase 3 dequeued more USB bytes than were accepted");
  report.check(d.max_ground_queue <= kGroundUsbBufferCapacity,
               "Phase 3 Ground queue exceeded fixed capacity");
}

}  // namespace

TestReport run_buffer_integration_test(const std::string& test_id,
                                       std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  TddConfig config{};
  RfMediumConfig rf_config{};
  TddSimulation simulation(config, rf_config, seed);
  simulation.start(40U, 0U);

  if (test_id == "IT-BUF-001") {
    std::array<std::uint8_t, 595> burst{};
    fill_pattern(burst);
    report.check(simulation.ingest_ground_usb(burst.data(), 300U) == 300U,
                 "first USB burst segment was not accepted");
    simulation.run_for(1'500U);
    report.check(simulation.ingest_ground_usb(burst.data() + 300U,
                                              burst.size() - 300U) ==
                     burst.size() - 300U,
                 "USB ingress stopped while Ground waited for a grant");
    simulation.run_for(1'499U);
    report.check(simulation.ground_queue_bytes() == burst.size(),
                 "pre-grant USB bytes were not retained");
    report.check(simulation.medium().data_tx_count(NodeId::Ground) == 0U,
                 "Ground transmitted buffered USB bytes before a grant");
    report.check(simulation.run_until_cycles(10U, 10U * kCycleTimeoutMs),
                 "595-byte burst did not drain within ten grants");
    capture(report, simulation);
    report.check(report.diagnostics.ground_usb_rx_bytes == burst.size(),
                 "USB ingress byte accounting is not 595");
    report.check(report.diagnostics.ground_usb_accepted_bytes == burst.size(),
                 "accepted USB byte accounting is not 595");
    report.check(report.diagnostics.ground_usb_dropped_bytes == 0U,
                 "in-capacity USB burst reported dropped bytes");
    report.check(report.diagnostics.ground_buffer_overflow_count == 0U,
                 "in-capacity USB burst reported overflow");
    report.check(report.diagnostics.ground_usb_dequeued_bytes == burst.size(),
                 "dequeued USB byte accounting is not 595");
    report.check(report.diagnostics.uplink_transactions == 10U,
                 "595-byte burst did not use exactly ten grants");
    report.check(simulation.stats().vehicle_payload_rx == burst.size(),
                 "vehicle did not receive the complete 595-byte burst");
    report.check(simulation.ground_queue_bytes() == 0U,
                 "595-byte Ground queue did not drain completely");
  } else if (test_id == "IT-BUF-002") {
    std::array<std::uint8_t, 64> first{};
    std::array<std::uint8_t, 32> second{};
    fill_pattern(first);
    for (std::size_t index = 0; index < second.size(); ++index) {
      second[index] = static_cast<std::uint8_t>(0xE0U + index);
    }
    simulation.faults().reject_ground_data_cycle = 0;
    report.check(simulation.ingest_ground_usb(first.data(), first.size()) ==
                     first.size(),
                  "rejection test burst was not accepted into the queue");
    const std::uint64_t reject_deadline = simulation.now_ms() + kCycleTimeoutMs;
    while (simulation.stats().ground_payload_rejected == 0U &&
           simulation.now_ms() < reject_deadline) {
      simulation.step();
    }
    report.check(simulation.stats().ground_payload_rejected == 1U,
                 "injected Ground radio rejection did not occur");
    report.check(simulation.ingest_ground_usb(second.data(), second.size()) ==
                     second.size(),
                 "USB ingress stopped while the rejected head was retained");
    report.check(simulation.run_until_cycles(2U, 2U * kCycleTimeoutMs),
                 "rejected-write scenario did not drain in two grants");
    capture(report, simulation);
    report.check(simulation.stats().ground_payload_rejected == 1U,
                  "injected Ground radio rejection did not occur once");
    report.check(simulation.stats().queue_bytes_after_rejected_tx ==
                     first.size(),
                  "rejected radio write consumed queued USB bytes");
    report.check(report.diagnostics.action_retries == 1U,
                 "rejected radio write was not retried exactly once");
    report.check(simulation.medium().data_tx_count(NodeId::Ground) == 3U,
                  "A||B recovery was not sent as 32-byte physical writes");
    report.check(report.diagnostics.uplink_transactions == 2U,
                  "A||B recovery did not use exactly two grants");
    report.check(report.diagnostics.ground_usb_dequeued_bytes ==
                     first.size() + second.size(),
                  "accepted retries did not dequeue exactly A||B");
    report.check(simulation.stats().vehicle_payload_rx ==
                     first.size() + second.size(),
                  "accepted retries did not deliver the complete A||B stream");
    report.check(simulation.ground_queue_bytes() == 0U,
                 "recovered Ground queue did not drain");
  } else if (test_id == "IT-BUF-003") {
    constexpr std::size_t kExtraBytes = 32U;
    std::array<std::uint8_t, kGroundUsbBufferCapacity + kExtraBytes> burst{};
    fill_pattern(burst);
    const std::size_t accepted =
        simulation.ingest_ground_usb(burst.data(), burst.size());
    capture(report, simulation);
    report.check(accepted == kGroundUsbBufferCapacity,
                 "overflow did not accept exactly the fixed capacity");
    report.check(simulation.ground_queue_bytes() ==
                     kGroundUsbBufferCapacity,
                 "overflow queue size exceeded/fell below capacity");
    report.check(report.diagnostics.ground_usb_dropped_bytes == kExtraBytes,
                 "overflow did not report 32 dropped newest bytes");
    report.check(report.diagnostics.ground_buffer_overflow_count == 1U,
                 "overflow event was not counted once");
    report.check(report.diagnostics.max_ground_queue ==
                     kGroundUsbBufferCapacity,
                 "overflow high-water mark is not the fixed capacity");
  } else if (test_id == "IT-BUF-004") {
    std::array<std::uint8_t, 64> burst{};
    fill_pattern(burst);
    report.check(simulation.ingest_ground_usb(burst.data(), burst.size()) ==
                     burst.size(),
                 "chunk-boundary burst was not queued");
    report.check(simulation.run_until_cycles(1U, kCycleTimeoutMs),
                 "chunk-boundary scenario did not finish one cycle");
    capture(report, simulation);
    report.check(report.diagnostics.uplink_transactions == 1U,
                 "one GRANT produced more than one logical transaction");
    report.check(report.diagnostics.uplink_payload_bytes == burst.size(),
                 "logical transaction did not account for 64 bytes");
    report.check(simulation.stats().ground_payload_tx == 2U,
                 "64-byte transaction was not split into two physical writes");
    report.check(simulation.stats().max_ground_data_write_bytes == 32U,
                  "physical E220 write exceeded the 32-byte production limit");
    report.check(simulation.stats().last_ground_payload_tx_ms -
                         simulation.stats().first_ground_payload_tx_ms >=
                     config.min_tx_gap_ms,
                  "split physical writes violated the 180-ms minimum gap");
    report.check(simulation.stats().vehicle_payload_rx == burst.size(),
                 "split physical writes did not deliver all 64 bytes");
    report.check(simulation.ground_queue_bytes() == 0U,
                  "split transaction did not consume exactly 64 bytes");
  } else if (test_id == "IT-BUF-005") {
    constexpr std::size_t kBurstBytes = 8U * 1024U;
    std::array<std::uint8_t, kBurstBytes> burst{};
    fill_pattern(burst);
    report.check(simulation.ingest_ground_usb(burst.data(), burst.size()) ==
                     burst.size(),
                 "8 KiB pre-grant burst was not accepted in full");
    simulation.run_for(config.downlink_send_ms - 1U);
    report.check(simulation.ground_queue_bytes() == burst.size(),
                 "8 KiB burst changed while Ground waited for a grant");
    report.check(simulation.medium().data_tx_count(NodeId::Ground) == 0U,
                 "8 KiB burst transmitted before the first grant");
    report.check(simulation.run_until_cycles(128U, 128U * kCycleTimeoutMs),
                 "8 KiB burst did not drain in 128 grants");
    capture(report, simulation);
    report.check(simulation.ground_queue_bytes() == 0U,
                 "8 KiB Ground queue did not drain");
    report.check(report.diagnostics.uplink_transactions == 128U,
                 "8 KiB burst did not use 128 logical transactions");
    report.check(report.diagnostics.ground_usb_dequeued_bytes == kBurstBytes &&
                     simulation.stats().vehicle_payload_rx == kBurstBytes,
                 "8 KiB burst was not delivered byte-for-byte");
    report.check(report.diagnostics.ground_usb_dropped_bytes == 0U &&
                     report.diagnostics.ground_buffer_overflow_count == 0U,
                 "8 KiB in-capacity burst reported overflow");
  } else if (test_id == "IT-BUF-006") {
    constexpr std::size_t kBurstBytes = 16U * 1024U;
    std::array<std::uint8_t, kBurstBytes> burst{};
    fill_pattern(burst);
    const std::uint64_t grant_deadline = simulation.now_ms() + kCycleTimeoutMs;
    while (simulation.ground().state() != GroundTddState::UplinkGuard &&
           simulation.now_ms() < grant_deadline) {
      simulation.step();
    }
    report.check(simulation.ground().state() == GroundTddState::UplinkGuard,
                 "Ground did not enter the granted guard state");
    report.check(simulation.ingest_ground_usb(burst.data(), burst.size()) ==
                     burst.size(),
                 "16 KiB during-GRANT burst was not accepted in full");
    report.check(simulation.run_until_cycles(256U, 256U * kCycleTimeoutMs),
                 "16 KiB burst did not drain in 256 grants");
    capture(report, simulation);
    report.check(simulation.ground_queue_bytes() == 0U,
                 "16 KiB Ground queue did not drain");
    report.check(report.diagnostics.uplink_transactions == 256U,
                 "16 KiB burst did not use 256 logical transactions");
    report.check(simulation.stats().ground_payload_tx == 512U,
                 "16 KiB burst was not split into 512 physical writes");
    report.check(report.diagnostics.ground_usb_dequeued_bytes == kBurstBytes &&
                     simulation.stats().vehicle_payload_rx == kBurstBytes,
                 "16 KiB burst was not delivered byte-for-byte");
    report.check(report.diagnostics.ground_usb_dropped_bytes == 0U &&
                     report.diagnostics.ground_buffer_overflow_count == 0U,
                 "16 KiB exact-capacity burst reported overflow");
    report.check(report.diagnostics.max_ground_queue == kBurstBytes,
                 "16 KiB burst high-water mark was not recorded");
  } else {
    report.check(false, "unknown Phase 3 integration test ID");
    capture(report, simulation);
  }

  check_phase3_invariants(report);
  return report;
}

}  // namespace vc_lora::test
