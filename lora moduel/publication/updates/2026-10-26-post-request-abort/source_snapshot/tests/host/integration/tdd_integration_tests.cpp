#include "test_support.hpp"

#include <array>
#include <cstdint>
#include <string>

#include "integration/tdd_simulation.hpp"
#include "vc_lora/legacy_silence_gate.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint64_t kCycleTimeoutMs = 7'000U;

void copy_simulation(TestReport& report, const TddSimulation& simulation) {
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

void check_common_invariants(TestReport& report) {
  const auto& diagnostics = report.diagnostics;
  report.check(diagnostics.tx_during_rx_window_count == 0U,
               "tx_during_rx_window_count != 0");
  report.check(diagnostics.ground_tx_without_valid_grant == 0U,
               "ground_tx_without_valid_grant != 0");
  report.check(diagnostics.control_bytes_leaked_to_local_uart == 0U,
               "control_bytes_leaked_to_local_uart != 0");
  report.check(diagnostics.invalid_crc_state_transition == 0U,
               "invalid_crc_state_transition != 0");
  report.check(diagnostics.collision_count == 0U, "collision_count != 0");
  report.check(diagnostics.tx_gate_violation == 0U,
               "tx_gate_violation != 0");
  report.check(diagnostics.half_duplex_drop_count == 0U,
               "half_duplex_drop_count != 0");
  report.check(diagnostics.uplink_data_outside_receive_window == 0U,
               "uplink_data_outside_receive_window != 0");
}

TddControlMessage grant(std::uint16_t session, std::uint16_t cycle) {
  TddControlMessage message{};
  message.type = ControlType::UlGrant;
  message.session_id = session;
  message.cycle_id = cycle;
  message.guard_ms = 650U;
  message.window_ms = 300U;
  message.max_bytes = 64U;
  return message;
}

}  // namespace

TestReport run_legacy_characterization(const std::string& test_id,
                                       std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id != "PHASE1-LEGACY-COLLISION" &&
      test_id != "PHASE1-LEGACY-INVARIANT") {
    report.check(false, "unknown Phase 1 test ID");
    return report;
  }

  LinkDiagnostics diagnostics{};
  RfMediumConfig rf_config{};
  RfMediumSim medium(rf_config, seed, diagnostics);
  LegacySilenceGroundGate legacy{};
  legacy.reset(0);
  std::array<std::uint8_t, 32> ground_payload{};
  std::array<std::uint8_t, 32> vehicle_payload{};
  ground_payload.fill(0xA5U);
  vehicle_payload.fill(0x5AU);

  const auto sample_link = [&](std::uint64_t sample_ms) {
    report.trace.record({sample_ms, "ground", "LEGACY_SILENCE_WINDOW", 0,
                         "STATE_SAMPLE", true, 0, 0, 0});
    report.trace.record({sample_ms, "vehicle", "DOWNLINK_SEND", 0,
                         "STATE_SAMPLE", true, 0, 0, 0});
  };
  for (std::uint64_t sample_ms = 0; sample_ms < 650U; sample_ms += 25U) {
    sample_link(sample_ms);
  }

  report.check(legacy.transmit_allowed(650U),
               "legacy gate did not open at 650 ms");
  const TxOutcome first = medium.transmit(NodeId::Ground, 650U,
                                          ground_payload.data(),
                                          ground_payload.size());
  if (first.accepted) {
    ++diagnostics.ground_tx_without_valid_grant;
    ++diagnostics.tx_gate_violation;
  }
  report.trace.record({650U, "ground", "LEGACY_SILENCE_WINDOW", 0,
                       "TX_WITHOUT_GRANT", false, 64U,
                       ground_payload.size(), 0});
  for (std::uint64_t sample_ms = 675U; sample_ms < 830U; sample_ms += 25U) {
    sample_link(sample_ms);
  }

  report.check(legacy.transmit_allowed(830U),
               "legacy gate unexpectedly closed inside 650..950 ms");
  const TxOutcome second = medium.transmit(NodeId::Ground, 830U,
                                           ground_payload.data(),
                                           ground_payload.size());
  if (second.accepted) {
    ++diagnostics.ground_tx_without_valid_grant;
    ++diagnostics.tx_gate_violation;
  }
  report.trace.record({830U, "ground", "LEGACY_SILENCE_WINDOW", 0,
                       "TX_WITHOUT_GRANT", false, 32U,
                       ground_payload.size(), 0});

  medium.transmit(NodeId::Vehicle, 840U, vehicle_payload.data(),
                  vehicle_payload.size());
  report.trace.record({840U, "vehicle", "DOWNLINK_SEND", 0,
                       "SPARSE_DOWNLINK_OVERLAP", false, 0,
                       vehicle_payload.size(), 0});
  medium.advance(2'000U);
  for (std::uint64_t sample_ms = 850U; sample_ms <= 2'000U;
       sample_ms += 25U) {
    sample_link(sample_ms);
  }

  report.diagnostics = diagnostics;
  report.final_vehicle_state = "DOWNLINK_SEND";
  report.final_ground_state = "LEGACY_SILENCE_WINDOW";
  if (test_id == "PHASE1-LEGACY-INVARIANT") {
    report.expected_failure = true;
    report.check(diagnostics.ground_tx_without_valid_grant == 0U,
                 "legacy invariant violated: ground transmitted without grant");
    report.check(diagnostics.collision_count == 0U,
                 "legacy invariant violated: sparse downlink collision");
    report.detail =
        "Expected failure: the legacy silence window violates the explicit "
        "grant and collision-free invariants.";
    return report;
  }
  report.check(first.accepted && second.accepted,
               "legacy ground transmissions were not accepted by simulator");
  report.check(diagnostics.ground_tx_without_valid_grant == 2U,
               "legacy ungranted transmissions were not reproduced");
  report.check(diagnostics.collision_count > 0U,
               "sparse-downlink collision was not detected");
  report.detail =
      "Expected defect reproduced: silence was treated as a lease and the "
      "second ground packet overlapped sparse vehicle downlink.";
  return report;
}

TestReport run_integration_test(const std::string& test_id,
                                std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  TddConfig config{};
  RfMediumConfig rf_config{};

  if (test_id == "IT-TDD-014") {
    TddSimulation simulation(config, rf_config, seed,
                             LocalClock(120, -500),
                             LocalClock(5'000, 500));
    simulation.start(20U, 0U);
    simulation.queue_ground_bytes(640U);
    report.check(simulation.run_until_cycles(10U, 10U * kCycleTimeoutMs),
                 "clock-skew scenario did not complete 10 cycles");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.grant_rx == 10U,
                 "clock-skew grant count is not 10");
    report.check(report.diagnostics.done_rx == 10U,
                 "clock-skew done count is not 10");
    report.check(simulation.stats().vehicle_payload_rx == 640U,
                 "clock-skew uplink payload was not delivered byte-for-byte");
    check_common_invariants(report);
    return report;
  }

  TddSimulation simulation(config, rf_config, seed);

  if (test_id == "IT-TDD-015") {
    simulation.start(30U, 0xFFFEU);
    simulation.queue_ground_bytes(256U);
    report.check(simulation.run_until_cycles(4U, 4U * kCycleTimeoutMs),
                 "cycle-wrap scenario did not complete four cycles");
    report.check(simulation.vehicle().cycle_id() == 0x0002U,
                 "vehicle cycle did not wrap through zero");
    report.check(simulation.ground().cycle_id() == 0x0001U,
                 "ground did not accept wrapped cycle sequence");
    const ControlDisposition stale =
        simulation.inject_ground_control(grant(30U, 0xFFFFU));
    report.check(stale == ControlDisposition::OldCycle,
                 "pre-wrap old cycle was not rejected");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.grant_rx == 4U,
                 "wrapped grant count is not four");
    report.check(report.diagnostics.uplink_transactions == 4U,
                 "wrapped cycles did not produce four transactions");
    report.check(simulation.stats().vehicle_payload_rx == 256U,
                 "wrapped-cycle payload was not delivered byte-for-byte");
    check_common_invariants(report);
    return report;
  }

  simulation.start(10U, 0U);

  if (test_id == "IT-TDD-001") {
    simulation.set_vehicle_downlink_per_cycle(32U);
    simulation.queue_ground_bytes(6'400U);
    report.check(simulation.run_until_cycles(100U, 100U * kCycleTimeoutMs),
                 "normal scenario did not complete 100 cycles");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.grant_tx == 100U,
                 "grant_tx is not 100");
    report.check(report.diagnostics.grant_rx == 100U,
                 "grant_rx is not 100");
    report.check(report.diagnostics.done_tx == 100U,
                 "done_tx is not 100");
    report.check(report.diagnostics.done_rx == 100U,
                 "done_rx is not 100");
    report.check(report.diagnostics.uplink_transactions == 100U,
                 "one uplink transaction per grant was not maintained");
    report.check(report.diagnostics.uplink_payload_bytes == 6'400U,
                 "uplink accounting is not 6400 bytes");
    report.check(simulation.stats().vehicle_payload_rx == 6'400U,
                 "vehicle did not receive all 6400 uplink bytes");
    report.check(simulation.ground_queue_bytes() == 0U,
                 "ground queue did not drain exactly");
    report.check(report.diagnostics.downlink_transactions == 100U,
                 "vehicle did not send one downlink payload per cycle");
    report.check(report.diagnostics.downlink_payload_bytes == 3'200U,
                 "downlink accounting is not 3200 bytes");
    report.check(simulation.stats().ground_payload_rx == 3'200U,
                 "ground did not receive all downlink bytes");
    report.check(report.diagnostics.uplink_timeouts == 0U,
                 "normal scenario had an uplink timeout");
  } else if (test_id == "IT-TDD-002") {
    simulation.queue_ground_bytes(64U);
    simulation.run_for(800U);
    simulation.queue_vehicle_bytes(32U);
    simulation.run_for(2'199U);
    copy_simulation(report, simulation);
    report.check(report.diagnostics.grant_rx == 0U,
                 "a grant arrived before the downlink phase ended");
    report.check(simulation.medium().data_tx_count(NodeId::Ground) == 0U,
                 "ground transmitted after silence but before a grant");
    report.check(simulation.stats().ground_payload_rx == 32U,
                 "sparse vehicle downlink was not actually delivered");
    report.check(simulation.ground_queue_bytes() == 64U,
                 "pre-grant ground queue changed unexpectedly");
  } else if (test_id == "IT-TDD-003") {
    report.check(simulation.run_until_cycles(1U, kCycleTimeoutMs),
                 "empty-uplink cycle did not complete");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.idle_tx == 1U,
                 "ground did not send UL_IDLE");
    report.check(report.diagnostics.idle_rx == 1U,
                 "vehicle did not receive UL_IDLE");
    report.check(report.diagnostics.uplink_timeouts == 0U,
                 "empty uplink waited for timeout");
  } else if (test_id == "IT-TDD-004") {
    simulation.faults().drop_grant_cycle = 0;
    simulation.queue_ground_bytes(128U);
    report.check(simulation.run_until_cycles(2U, 2U * kCycleTimeoutMs),
                 "grant-loss scenario did not recover in the next cycle");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.grant_tx == 2U,
                 "vehicle did not issue two grants");
    report.check(report.diagnostics.grant_rx == 1U,
                 "dropped grant was unexpectedly accepted");
    report.check(report.diagnostics.uplink_transactions == 1U,
                 "ground transmitted in the dropped-grant cycle");
    report.check(simulation.stats().vehicle_payload_rx == 64U,
                 "recovery-cycle payload was not delivered");
    report.check(report.diagnostics.uplink_timeouts == 1U,
                 "vehicle did not time out exactly once");
  } else if (test_id == "IT-TDD-005") {
    simulation.faults().drop_done_cycle = 0;
    simulation.queue_ground_bytes(128U);
    report.check(simulation.run_until_cycles(2U, 2U * kCycleTimeoutMs),
                 "done-loss scenario did not recover in the next cycle");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.uplink_transactions == 2U,
                 "DONE loss caused missing or duplicate payload transaction");
    report.check(report.diagnostics.done_tx == 2U,
                 "ground did not send one DONE per grant");
    report.check(report.diagnostics.done_rx == 1U,
                 "dropped DONE was unexpectedly received");
    report.check(report.diagnostics.uplink_timeouts == 1U,
                 "DONE loss did not cause exactly one timeout");
    report.check(simulation.stats().vehicle_payload_rx == 128U,
                 "DONE-loss payload delivery count is incorrect");
  } else if (test_id == "IT-TDD-006") {
    simulation.faults().duplicate_grant_cycle = 0;
    simulation.queue_ground_bytes(64U);
    report.check(simulation.run_until_cycles(1U, kCycleTimeoutMs),
                 "duplicate-grant scenario did not complete");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.grant_rx == 1U,
                 "duplicate grant was accepted more than once");
    report.check(report.diagnostics.duplicate_grants == 1U,
                 "duplicate grant was not diagnosed");
    report.check(report.diagnostics.uplink_transactions == 1U,
                 "duplicate grant restarted payload transmission");
    report.check(simulation.stats().vehicle_payload_rx == 64U,
                 "duplicate-grant payload was not delivered exactly once");
  } else if (test_id == "IT-TDD-007") {
    simulation.queue_ground_bytes(128U);
    report.check(simulation.run_until_cycles(2U, 2U * kCycleTimeoutMs),
                 "setup cycles did not complete");
    const std::uint64_t before =
        simulation.medium().data_tx_count(NodeId::Ground);
    simulation.queue_ground_bytes(64U);
    const ControlDisposition disposition =
        simulation.inject_ground_control(grant(10U, 0U));
    simulation.run_for(1'000U);
    report.check(disposition == ControlDisposition::OldCycle,
                 "old cycle was not rejected");
    report.check(simulation.medium().data_tx_count(NodeId::Ground) == before,
                 "old cycle triggered a ground retransmission");
    report.check(simulation.ground_queue_bytes() == 64U,
                 "old cycle consumed queued payload");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.stale_cycles == 1U,
                 "old cycle diagnostic was not incremented");
  } else if (test_id == "IT-TDD-008") {
    simulation.faults().reset_ground_on_grant_cycle = 0;
    simulation.queue_ground_bytes(128U);
    report.check(simulation.run_until_cycles(2U, 2U * kCycleTimeoutMs),
                 "ground reboot did not recover within two cycles");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.uplink_transactions == 1U,
                 "ground transmitted using the grant held before reboot");
    report.check(report.diagnostics.grant_rx == 2U,
                 "ground did not accept the next grant after reboot");
    report.check(simulation.stats().vehicle_payload_rx == 64U,
                 "ground reboot recovery payload was not delivered");
  } else if (test_id == "IT-TDD-009") {
    simulation.queue_ground_bytes(64U);
    report.check(simulation.run_until_cycles(1U, kCycleTimeoutMs),
                 "pre-reboot cycle did not complete");
    simulation.restart_vehicle(11U, 0U);
    simulation.queue_ground_bytes(64U);
    const std::uint64_t deadline = simulation.now_ms() + kCycleTimeoutMs;
    while (simulation.diagnostics().grant_rx < 2U &&
           simulation.now_ms() < deadline) {
      simulation.step();
    }
    report.check(simulation.diagnostics().grant_rx == 2U,
                 "ground did not accept the new vehicle session");
    const ControlDisposition stale =
        simulation.inject_ground_control(grant(10U, 1U));
    report.check(stale == ControlDisposition::OldSession,
                 "old-session grant was not rejected");
    report.check(simulation.run_until_cycles(2U, kCycleTimeoutMs),
                 "new vehicle session did not finish within two cycles");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.session_changes == 1U,
                 "new session was not diagnosed");
    report.check(report.diagnostics.stale_sessions == 1U,
                 "old session rejection was not diagnosed");
    report.check(report.diagnostics.uplink_transactions == 2U,
                 "new session did not restore payload transactions");
    report.check(report.diagnostics.uplink_payload_bytes == 128U,
                 "new session did not deliver both payload budgets");
    report.check(simulation.stats().vehicle_payload_rx == 128U,
                 "new-session payload did not reach the vehicle");
  } else if (test_id == "IT-TDD-010" || test_id == "IT-TDD-011" ||
             test_id == "IT-TDD-012") {
    simulation.faults().busy_ground_on_grant_cycle = 0;
    simulation.faults().ground_aux_busy_ms =
        test_id == "IT-TDD-010" ? 500U
        : test_id == "IT-TDD-011" ? 650U
                                    : 900U;
    const bool long_payload_near_deadline = test_id == "IT-TDD-012";
    simulation.queue_ground_bytes(long_payload_near_deadline ? 64U : 32U);
    report.check(simulation.run_until_cycles(1U, 2U * kCycleTimeoutMs),
                 "AUX Busy scenario did not make bounded progress");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.grant_rx == 1U,
                 "AUX Busy prevented grant reception");
    report.check(report.diagnostics.done_rx + report.diagnostics.idle_rx == 1U,
                 "AUX Busy cycle did not terminate explicitly");
    report.check(report.diagnostics.uplink_timeouts == 0U,
                 "AUX Busy completion fell back to vehicle timeout");
    if (long_payload_near_deadline) {
      report.check(report.diagnostics.uplink_transactions == 0U,
                   "64-byte payload started without enough window time");
      report.check(simulation.stats().vehicle_payload_rx == 0U,
                   "late 64-byte payload reached the vehicle");
      report.check(report.diagnostics.idle_rx == 1U,
                   "insufficient window did not terminate with UL_IDLE");
      report.check(report.diagnostics.insufficient_window_count == 1U,
                   "insufficient-window decision was not diagnosed");
      report.check(simulation.ground_queue_bytes() == 64U,
                   "deferred 64-byte payload was removed from the queue");
    } else {
      report.check(report.diagnostics.uplink_transactions == 1U,
                   "AUX Busy did not produce exactly one transaction");
      report.check(report.diagnostics.uplink_payload_bytes == 32U,
                   "AUX Busy payload accounting is not 32 bytes");
      report.check(simulation.stats().vehicle_payload_rx == 32U,
                   "AUX Busy payload did not reach the vehicle");
      report.check(report.diagnostics.done_rx == 1U,
                   "AUX Busy sent IDLE instead of completing queued data");
      report.check(simulation.stats().first_ground_payload_tx_ms >=
                       simulation.stats().first_grant_rx_ms +
                           simulation.faults().ground_aux_busy_ms +
                           config.aux_stable_ms,
                   "ground transmitted before AUX was stably high");
    }
  } else if (test_id == "IT-TDD-013") {
    simulation.faults().corrupt_grant_cycle = 0;
    simulation.queue_ground_bytes(128U);
    report.check(simulation.run_until_cycles(2U, 2U * kCycleTimeoutMs),
                 "CRC recovery scenario did not finish two cycles");
    copy_simulation(report, simulation);
    report.check(report.diagnostics.control_crc_errors == 1U,
                 "corrupt control frame did not produce one CRC error");
    report.check(report.diagnostics.grant_rx == 1U,
                 "corrupt grant changed state or normal retry was not accepted");
    report.check(report.diagnostics.uplink_transactions == 1U,
                 "corrupt grant triggered a payload transmission");
    report.check(simulation.stats().vehicle_payload_rx == 64U,
                 "CRC recovery payload was not delivered");
  } else {
    report.check(false, "unknown integration test ID");
    copy_simulation(report, simulation);
  }

  check_common_invariants(report);
  return report;
}

TestReport run_rf_test(const std::string& test_id, std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id != "IT-RF-HDX-001") {
    report.check(false, "unknown RF integration test ID");
    return report;
  }

  LinkDiagnostics diagnostics{};
  RfMediumConfig config{};
  config.turnaround_ms = 0U;
  config.propagation_delay_ms = 50U;
  RfMediumSim medium(config, seed, diagnostics);
  std::array<std::uint8_t, 32> vehicle_payload{};
  std::array<std::uint8_t, 32> ground_payload{};
  vehicle_payload.fill(0x51U);
  ground_payload.fill(0xA1U);

  const TxOutcome vehicle_tx = medium.transmit(
      NodeId::Vehicle, 0U, vehicle_payload.data(), vehicle_payload.size());
  const TxOutcome ground_tx = medium.transmit(
      NodeId::Ground, 60U, ground_payload.data(), ground_payload.size());
  for (std::uint64_t sample_ms = 0; sample_ms <= 100U; ++sample_ms) {
    medium.advance(sample_ms);
    const bool transmitting =
        sample_ms >= 60U && sample_ms < ground_tx.end_ms;
    const bool receiving = medium.rx_active(NodeId::Ground, sample_ms);
    report.trace.record(
        {sample_ms,
         "ground",
         transmitting ? "TX_ACTIVE" : receiving ? "RX_ACTIVE" : "IDLE",
         0,
         "RF_STATE_SAMPLE",
         !transmitting && !receiving,
         0,
         0,
         0});
  }
  RfDelivery delivery{};
  const bool delivered_to_ground =
      medium.pop_delivery(NodeId::Ground, 100U, delivery);

  report.diagnostics = diagnostics;
  report.check(vehicle_tx.accepted && ground_tx.accepted,
               "RF half-duplex setup transmission was rejected");
  report.check(!delivered_to_ground,
               "ground received while its own transmitter was active");
  report.check(diagnostics.half_duplex_drop_count == 1U,
               "receive-while-transmit drop was not diagnosed");
  report.check(diagnostics.packet_loss_count == 1U,
               "half-duplex loss was not counted");
  report.check(diagnostics.collision_count == 0U,
               "non-overlapping RF transmissions were called a collision");
  report.detail =
      "A frame arriving during the receiver's own TX interval was dropped "
      "from the on-wire timing model.";
  return report;
}

}  // namespace vc_lora::test
