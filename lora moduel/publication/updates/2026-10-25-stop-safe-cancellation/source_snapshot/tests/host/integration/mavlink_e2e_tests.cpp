#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "fixtures/mavlink_fixtures.hpp"
#include "integration/mavlink_e2e_sim.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint64_t kE2eTimeoutMs = 180'000U;
constexpr std::uint64_t kFnv1a64Offset = 14'695'981'039'346'656'037ULL;
constexpr std::uint64_t kFnv1a64Prime = 1'099'511'628'211ULL;

bool same_frame(const MavlinkFrame& left,
                const MavlinkFrame& right) noexcept {
  return left.size == right.size && left.message_id == right.message_id &&
         std::memcmp(left.bytes.data(), right.bytes.data(), left.size) == 0;
}

std::uint64_t append_frame_hash(std::uint64_t hash,
                                const MavlinkFrame& frame) noexcept {
  for (std::size_t index = 0U; index < frame.size; ++index) {
    hash ^= frame.bytes[index];
    hash *= kFnv1a64Prime;
  }
  return hash;
}

void capture(TestReport& report, const MavlinkE2eSimulation& simulation) {
  report.cycles = simulation.stats().cycles_completed;
  report.diagnostics = simulation.diagnostics();
  report.final_vehicle_state = vehicle_state_name(simulation.vehicle().state());
  report.final_ground_state = ground_state_name(simulation.ground().state());
  report.vehicle_session = simulation.vehicle().session_id();
  report.ground_session = simulation.ground().session_id();
  report.vehicle_cycle = simulation.vehicle().cycle_id();
  report.ground_cycle = simulation.ground().cycle_id();
}

void check_invariants(TestReport& report,
                      const MavlinkE2eSimulation& simulation) {
  const auto& d = report.diagnostics;
  report.check(d.tx_gate_violation == 0U, "Phase 4 TX gate violation");
  report.check(d.tx_during_rx_window_count == 0U,
               "vehicle transmitted during uplink receive");
  report.check(d.ground_tx_without_valid_grant == 0U,
               "Ground transmitted without a valid GRANT");
  report.check(d.control_bytes_leaked_to_local_uart == 0U,
               "VCTD control bytes leaked into a MAVLink endpoint");
  report.check(d.invalid_crc_state_transition == 0U,
               "invalid control changed TDD state");
  report.check(d.collision_count == 0U, "normal Phase 4 RF collision");
  report.check(d.packet_loss_count == 0U, "normal Phase 4 RF loss");
  report.check(d.partial_mavlink_delivered == 0U,
               "partial MAVLink frame was delivered to a local UART");
  report.check(d.mavlink_crc_errors == 0U,
               "valid E2E fixture reported a MAVLink CRC error");
  report.check(d.mavlink_parser_resets == 0U,
               "valid E2E stream reset a MAVLink parser");
  report.check(d.mavlink_queue_drop_frames == 0U,
               "in-capacity E2E traffic dropped a MAVLink frame");
  report.check(d.action_retries == 0U,
               "normal E2E traffic required a rejected radio retry");

  std::array<bool, 2> have_previous{{false, false}};
  std::array<std::uint64_t, 2> previous_start{{0U, 0U}};
  for (const auto& write : simulation.wire_writes()) {
    report.check(write.wire_bytes <= 32U,
                 "physical E220 write exceeded 32 bytes");
    const std::size_t node =
        write.sender == NodeId::Vehicle ? 0U : 1U;
    if (have_previous[node]) {
      report.check(write.start_ms - previous_start[node] >= 180U,
                   "physical E220 write start gap was below 180 ms");
    }
    have_previous[node] = true;
    previous_start[node] = write.start_ms;
    if (write.sender == NodeId::Ground && !write.control) {
      report.check(write.end_ms <= write.window_deadline_ms ||
                       write.continuing_started_transaction,
                   "Ground encoded data TX overran its GRANT window without "
                   "a preflight-approved started-frame continuation");
    }
  }
}

std::uint64_t heartbeat_max_gap(
    const std::vector<TimedMavlinkFrame>& frames) noexcept {
  std::uint64_t maximum = 0U;
  std::uint64_t previous = 0U;
  bool have_previous = false;
  for (const auto& entry : frames) {
    if (entry.frame.message_id != 0U || entry.frame.system_id != 1U ||
        entry.frame.component_id != 1U) {
      continue;
    }
    if (have_previous) {
      maximum = std::max(maximum, entry.received_ms - previous);
    }
    previous = entry.received_ms;
    have_previous = true;
  }
  return maximum;
}

std::size_t count_message(const std::vector<TimedMavlinkFrame>& frames,
                          std::uint32_t message_id) noexcept {
  return static_cast<std::size_t>(std::count_if(
      frames.begin(), frames.end(), [message_id](const auto& entry) {
        return entry.frame.message_id == message_id;
      }));
}

template <typename ResponseFactory>
void run_request_response(MavlinkE2eSimulation& simulation,
                          const std::vector<MavlinkFrame>& requests,
                          const std::vector<MavlinkFrame>& responses,
                          ResponseFactory validate_request,
                          TestReport& report) {
  for (const auto& request : requests) {
    report.check(simulation.ingest_gcs_frame(request),
                 "valid GCS request was not accepted atomically");
  }
  std::size_t responded = 0U;
  const std::uint64_t deadline = simulation.now_ms() + kE2eTimeoutMs;
  while ((responded < requests.size() ||
          simulation.ground_frames().size() < responses.size()) &&
         simulation.now_ms() < deadline) {
    simulation.step();
    while (responded < simulation.vehicle_frames().size() &&
           responded < requests.size()) {
      report.check(validate_request(
                       simulation.vehicle_frames()[responded].frame,
                       requests[responded]),
                   "PixhawkSim received a mismatched request");
      report.check(simulation.ingest_pixhawk_frame(responses[responded]),
                   "PixhawkSim response was not queued");
      ++responded;
    }
  }
  report.check(responded == requests.size(),
               "PixhawkSim did not receive 20/20 requests");
  report.check(simulation.ground_frames().size() == responses.size(),
               "GCS did not receive 20/20 correlated responses");
  const std::size_t comparable =
      std::min(simulation.ground_frames().size(), responses.size());
  for (std::size_t index = 0; index < comparable; ++index) {
    report.check(same_frame(simulation.ground_frames()[index].frame,
                            responses[index]),
                 "GCS response bytes/order did not match the request");
  }
}

}  // namespace

TestReport run_mavlink_e2e_test(const std::string& test_id,
                               std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  TddConfig config{};
  RfMediumConfig rf_config{};
  MavlinkE2eSimulation simulation(config, rf_config, seed);
  simulation.start(80U, 0U);

  if (test_id == "E2E-MAV-001") {
    constexpr std::size_t kHeartbeatCount = 60U;
    for (std::size_t second = 0U; second < kHeartbeatCount; ++second) {
      report.check(simulation.ingest_pixhawk_frame(fixtures::heartbeat_v2(
                       static_cast<std::uint8_t>(second))),
                   "Pixhawk heartbeat was not accepted");
      simulation.run_for(1'000U);
    }
    simulation.run_for(5'000U);
    capture(report, simulation);
    report.check(count_message(simulation.ground_frames(), 0U) ==
                     kHeartbeatCount,
                 "Ground did not receive all 60 valid Pixhawk heartbeats");
    report.check(heartbeat_max_gap(simulation.ground_frames()) <= 2'500U,
                 "Pixhawk heartbeat gap exceeded 2.5 seconds");
    report.check(report.diagnostics.heartbeat_valid >= kHeartbeatCount,
                 "valid heartbeat diagnostic is incomplete");
  } else if (test_id == "E2E-MAV-002") {
    std::vector<MavlinkFrame> expected;
    for (std::uint8_t index = 0U; index < 20U; ++index) {
      expected.push_back(fixtures::heartbeat_v1(index));
      report.check(simulation.ingest_gcs_frame(expected.back()),
                   "GCS heartbeat was not accepted");
    }
    report.check(simulation.run_until_vehicle_frames(20U, kE2eTimeoutMs),
                 "GCS heartbeat did not reach Pixhawk 20/20");
    capture(report, simulation);
    report.check(simulation.vehicle_frames().size() == expected.size(),
                 "GCS heartbeat count was not exactly 20");
    for (std::size_t index = 0U;
         index < std::min(expected.size(), simulation.vehicle_frames().size());
         ++index) {
      report.check(same_frame(expected[index],
                              simulation.vehicle_frames()[index].frame),
                   "GCS heartbeat raw bytes or sequence changed");
    }
  } else if (test_id == "E2E-MAV-003") {
    std::vector<MavlinkFrame> requests;
    std::vector<MavlinkFrame> responses;
    for (std::uint8_t index = 0U; index < 20U; ++index) {
      char id[17]{};
      (void)std::snprintf(id, sizeof(id), "READ_%02u",
                          static_cast<unsigned>(index));
      requests.push_back(fixtures::param_request_read_v2(index, id));
      responses.push_back(fixtures::param_value_v2(
          index, id, 100.0F + static_cast<float>(index), index));
    }
    run_request_response(simulation, requests, responses, same_frame, report);
    capture(report, simulation);
    report.check(report.diagnostics.param_requests_rx == 20U &&
                     report.diagnostics.param_values_rx == 20U,
                 "PARAM_REQUEST_READ/PARAM_VALUE accounting is not 20/20");
  } else if (test_id == "E2E-MAV-004") {
    std::vector<MavlinkFrame> requests;
    std::vector<MavlinkFrame> responses;
    for (std::uint8_t index = 0U; index < 20U; ++index) {
      char id[17]{};
      (void)std::snprintf(id, sizeof(id), "SET_%02u",
                          static_cast<unsigned>(index));
      const float value = 0.5F + static_cast<float>(index);
      requests.push_back(fixtures::param_set_v1(index, id, value));
      responses.push_back(fixtures::param_value_v2(index, id, value, index));
    }
    run_request_response(simulation, requests, responses, same_frame, report);
    capture(report, simulation);
    report.check(report.diagnostics.param_sets_rx == 20U &&
                     report.diagnostics.param_updates == 20U &&
                     report.diagnostics.param_values_rx == 20U,
                 "PARAM_SET/store/PARAM_VALUE accounting is not 20/20");
  } else if (test_id == "E2E-MAV-005") {
    std::vector<MavlinkFrame> requests;
    std::vector<MavlinkFrame> responses;
    for (std::uint8_t index = 0U; index < 20U; ++index) {
      requests.push_back(fixtures::command_long_v2(
          index, 400U, 1.0F + static_cast<float>(index)));
      responses.push_back(
          fixtures::command_ack_v2(index, 400U, index));
    }
    run_request_response(simulation, requests, responses, same_frame, report);
    capture(report, simulation);
    report.check(report.diagnostics.command_long_rx == 20U &&
                     report.diagnostics.command_ack_rx == 20U,
                 "COMMAND_LONG/COMMAND_ACK accounting is not 20/20");
  } else if (test_id == "E2E-MAV-006") {
    const MavlinkFrame uplink = fixtures::command_long_v2(3U);
    report.check(uplink.size > 32U && simulation.ingest_gcs_frame(uplink),
                 "32-byte-plus uplink fixture was not queued");
    report.check(simulation.run_until_vehicle_parser_buffered(
                     1U, kE2eTimeoutMs),
                 "first uplink fragment never reached the MAVLink parser");
    report.check(simulation.vehicle_frames().empty(),
                 "partial uplink frame reached Pixhawk UART");
    report.check(simulation.run_until_vehicle_frames(1U, kE2eTimeoutMs),
                 "complete uplink frame did not reach Pixhawk UART");
    report.check(same_frame(simulation.vehicle_frames()[0].frame, uplink),
                 "reassembled uplink frame differs from source");

    const MavlinkFrame downlink = fixtures::command_long_v2(4U, 401U, 2.0F);
    report.check(simulation.ingest_pixhawk_frame(downlink),
                 "32-byte-plus downlink fixture was not queued");
    report.check(simulation.run_until_ground_parser_buffered(
                     1U, kE2eTimeoutMs),
                 "first downlink fragment never reached the MAVLink parser");
    report.check(simulation.ground_frames().empty(),
                 "partial downlink frame reached GCS UART");
    report.check(simulation.run_until_ground_frames(1U, kE2eTimeoutMs),
                 "complete downlink frame did not reach GCS UART");
    report.check(same_frame(simulation.ground_frames()[0].frame, downlink),
                 "reassembled downlink frame differs from source");
    capture(report, simulation);
    report.check(simulation.stats().max_ground_wire_write <= 32U &&
                     simulation.stats().max_vehicle_wire_write <= 32U,
                 "physical E220 write exceeded 32 bytes");
  } else if (test_id == "E2E-MAV-007") {
    const MavlinkFrame adversarial =
        fixtures::adversarial_vctd_param_set();
    const MavlinkFrame heartbeat = fixtures::heartbeat_v2(7U);
    report.check(adversarial.size == 35U &&
                     simulation.ingest_gcs_frame(adversarial),
                 "valid MAVLink payload containing VCTD was not queued");
    report.check(simulation.ingest_pixhawk_frame(heartbeat),
                 "control-mix heartbeat was not queued");
    report.check(simulation.run_until_vehicle_frames(1U, kE2eTimeoutMs) &&
                     simulation.run_until_ground_frames(1U, kE2eTimeoutMs),
                 "bidirectional control-mix traffic did not arrive");
    const std::uint64_t done_deadline = simulation.now_ms() + 5'000U;
    while (simulation.diagnostics().done_rx == 0U &&
           simulation.now_ms() < done_deadline) {
      simulation.step();
    }
    capture(report, simulation);
    report.check(same_frame(simulation.vehicle_frames()[0].frame,
                            adversarial),
                 "payload VCTD bytes were consumed as link control");
    report.check(same_frame(simulation.ground_frames()[0].frame, heartbeat),
                 "downlink bytes changed while controls were mixed");
    report.check(report.diagnostics.grant_rx > 0U &&
                     report.diagnostics.done_rx > 0U,
                 "test did not actually mix GRANT/DONE controls");
  } else if (test_id == "E2E-MAV-008") {
    constexpr std::size_t kSeconds = 60U;
    constexpr std::size_t kPidPerSecond = 32U;
    std::uint16_t generated_pid = 0U;
    for (std::size_t second = 0U; second < kSeconds; ++second) {
      report.check(simulation.ingest_pixhawk_frame(fixtures::heartbeat_v2(
                       static_cast<std::uint8_t>(second))),
                   "heartbeat was rejected during msg194 flood");
      for (std::size_t sample = 0U; sample < kPidPerSecond; ++sample) {
        const auto sequence = static_cast<std::uint8_t>(generated_pid++);
        report.check(simulation.ingest_pixhawk_frame(
                         fixtures::pid_tuning_v2(sequence,
                                                 static_cast<float>(sample))),
                     "valid msg194 fixture was not classified");
      }
      simulation.run_for(1'000U);
    }
    simulation.run_for(5'000U);
    capture(report, simulation);
    const std::uint64_t expected_pid = kSeconds * kPidPerSecond;
    report.check(report.diagnostics.mavlink_msg194_filtered_frames ==
                     expected_pid,
                 "msg194 filter accounting does not equal generated input");
    report.check(count_message(simulation.ground_frames(), 194U) == 0U,
                 "msg194 reached the GCS endpoint");
    report.check(count_message(simulation.ground_frames(), 0U) == kSeconds,
                 "heartbeat was lost during msg194 filtering");
    report.check(heartbeat_max_gap(simulation.ground_frames()) <= 2'500U,
                 "heartbeat gap exceeded 2.5 seconds during msg194 flood");
  } else if (test_id == "E2E-MAV-009") {
    const auto burst = fixtures::mission_planner_burst();
    constexpr std::array<std::uint16_t, 17> expected_crc{{
        0xE914U, 0x521AU, 0x1379U, 0x3A7AU, 0xD21FU, 0x7422U,
        0x9674U, 0x3049U, 0x5C66U, 0xBDC4U, 0x21E8U, 0xC04AU,
        0x64AAU, 0x8508U, 0xBF53U, 0x5EF1U, 0xEE2EU,
    }};
    for (std::size_t index = 0U; index < expected_crc.size(); ++index) {
      const std::size_t checksum = index * 35U + 33U;
      const std::uint16_t actual_crc =
          static_cast<std::uint16_t>(burst[checksum]) |
          static_cast<std::uint16_t>(
              static_cast<std::uint16_t>(burst[checksum + 1U]) << 8U);
      report.check(actual_crc == expected_crc[index],
                   "595-byte fixture differs from independent golden CRC");
    }
    constexpr std::array<std::size_t, 7> chunks{{1U, 7U, 31U, 64U,
                                                 3U, 127U, 67U}};
    std::size_t offset = 0U;
    std::size_t chunk_index = 0U;
    while (offset < 300U) {
      const std::size_t count =
          std::min(chunks[chunk_index++ % chunks.size()], 300U - offset);
      report.check(simulation.ingest_gcs_stream(burst.data() + offset,
                                                count) == count,
                   "pre-GRANT stream chunk was not consumed");
      offset += count;
    }
    simulation.run_for(config.downlink_send_ms - 1U);
    report.check(simulation.ground_data_write_count() == 0U,
                 "595-byte burst transmitted before GRANT");
    const std::uint64_t guard_deadline = simulation.now_ms() + 10'000U;
    while (simulation.ground().state() != GroundTddState::UplinkGuard &&
           simulation.now_ms() < guard_deadline) {
      simulation.step();
    }
    report.check(simulation.ground().state() == GroundTddState::UplinkGuard,
                 "Ground never reached UPLINK_GUARD for burst injection");
    while (offset < burst.size()) {
      const std::size_t count = std::min(
          chunks[chunk_index++ % chunks.size()], burst.size() - offset);
      report.check(simulation.ingest_gcs_stream(burst.data() + offset,
                                                count) == count,
                   "during-GRANT stream chunk was not consumed");
      offset += count;
    }
    report.check(simulation.run_until_vehicle_frames(17U, kE2eTimeoutMs),
                 "595-byte valid MAVLink burst did not reach Pixhawk");
    simulation.run_for(1'000U);
    capture(report, simulation);
    std::array<std::uint8_t, 595> received{};
    std::size_t received_size = 0U;
    for (const auto& entry : simulation.vehicle_frames()) {
      if (received_size + entry.frame.size <= received.size()) {
        std::memcpy(received.data() + received_size, entry.frame.bytes.data(),
                    entry.frame.size);
        received_size += entry.frame.size;
      }
    }
    report.check(received_size == burst.size() &&
                     std::memcmp(received.data(), burst.data(), burst.size()) ==
                         0,
                 "595-byte MAVLink burst order/content changed");
    report.check(simulation.vehicle_frames().size() == 17U &&
                     simulation.ground_queue_bytes() == 0U,
                 "595-byte burst produced duplicates or remained queued");
    report.check(report.diagnostics.ground_usb_accepted_bytes == 595U &&
                     report.diagnostics.ground_usb_dropped_bytes == 0U,
                 "Ground frame-aware ring did not retain all 595 bytes");
    report.check(report.diagnostics.max_ground_queue == 595U,
                 "595-byte ring high-water mark was not observed");
    report.check(report.diagnostics.max_mavlink_queue_frames == 17U,
                 "Ground MAVLink frame high-water mark is not 17");
  } else if (test_id == "E2E-MAV-010") {
    const MavlinkFrame heartbeat_before = fixtures::heartbeat_v2(0x70U);
    const MavlinkFrame heartbeat_after = fixtures::heartbeat_v2(0x71U);
    report.check(simulation.ingest_pixhawk_frame(heartbeat_before),
                 "initial heartbeat was not observed by the scheduler");
    report.check(simulation.run_until_ground_frames(1U, kE2eTimeoutMs),
                 "initial heartbeat did not reach Ground");
    report.check(simulation.ground_frames().size() == 1U &&
                     same_frame(simulation.ground_frames()[0].frame,
                                heartbeat_before),
                 "initial heartbeat exact bytes changed");

    std::array<std::uint64_t, 2> stopped_cycle_starts{{0U, 0U}};
    std::array<std::uint64_t, 2> stopped_grant_starts{{0U, 0U}};
    std::uint64_t cycle_start_ms = 0U;
    for (std::size_t stopped = 0U; stopped < stopped_cycle_starts.size();
         ++stopped) {
      stopped_cycle_starts[stopped] = cycle_start_ms;
      const std::uint16_t cycle_id = simulation.vehicle().cycle_id();
      const std::size_t writes_before = simulation.wire_writes().size();
      const std::uint64_t deadline = simulation.now_ms() + 20'000U;
      while (simulation.vehicle().cycle_id() == cycle_id &&
             simulation.now_ms() < deadline) {
        simulation.step();
      }
      report.check(simulation.vehicle().cycle_id() != cycle_id,
                   "heartbeat-stop cycle deadlocked");

      const std::uint64_t bounded_grant_min =
          cycle_start_ms + config.downlink_send_ms +
          config.heartbeat_tail_wait_ms;
      const std::uint64_t bounded_grant_max = bounded_grant_min + 3U;
      std::uint64_t grant_start_ms = 0U;
      bool sent_vehicle_data = false;
      for (std::size_t index = writes_before;
           index < simulation.wire_writes().size(); ++index) {
        const WireWriteRecord& write = simulation.wire_writes()[index];
        if (write.sender != NodeId::Vehicle) {
          continue;
        }
        if (!write.control) {
          sent_vehicle_data = true;
        } else if (grant_start_ms == 0U &&
                   write.start_ms >= bounded_grant_min) {
          grant_start_ms = write.start_ms;
        }
      }
      stopped_grant_starts[stopped] = grant_start_ms;
      report.check(!sent_vehicle_data,
                   "heartbeat-stop cycle synthesized downlink data");
      report.check(grant_start_ms >= bounded_grant_min &&
                       grant_start_ms <= bounded_grant_max,
                   "no-heartbeat cycle did not grant at nominal+1100 bound");
      report.check(simulation.ground_frames().size() == 1U,
                   "heartbeat-stop cycle delivered an unexpected frame");

      // step() observes the cycle transition at physical time now_ms-1.
      cycle_start_ms = simulation.now_ms() - 1U;
    }

    report.check(simulation.stats().cycles_completed == 2U &&
                     simulation.stats().vehicle_data_writes == 1U,
                 "two heartbeat-stop cycles did not complete exactly");
    const std::uint64_t resume_nominal_ms =
        cycle_start_ms + config.downlink_send_ms;
    while (simulation.now_ms() < resume_nominal_ms) {
      simulation.step();
    }
    report.check(simulation.now_ms() == resume_nominal_ms,
                 "resume fixture missed the nominal tail boundary");
    const std::size_t writes_before_resume =
        simulation.wire_writes().size();
    const std::uint64_t resume_ingest_ms = simulation.now_ms();
    report.check(simulation.ingest_pixhawk_frame(heartbeat_after),
                 "resumed heartbeat was not accepted at tail boundary");
    report.check(simulation.run_until_ground_frames(2U, 5'000U),
                 "resumed heartbeat did not reach Ground");

    std::uint64_t resumed_tx_ms = 0U;
    std::size_t resumed_data_writes = 0U;
    for (std::size_t index = writes_before_resume;
         index < simulation.wire_writes().size(); ++index) {
      const WireWriteRecord& write = simulation.wire_writes()[index];
      if (write.sender == NodeId::Vehicle && !write.control) {
        if (resumed_tx_ms == 0U) {
          resumed_tx_ms = write.start_ms;
        }
        ++resumed_data_writes;
      }
    }
    report.check(resumed_tx_ms >= resume_nominal_ms &&
                     resumed_tx_ms <= resume_nominal_ms +
                                          config.heartbeat_tail_wait_ms,
                 "resumed heartbeat was not transmitted in the tail window");
    report.check(simulation.ground_frames()[1].received_ms -
                         resume_ingest_ms <=
                     config.heartbeat_tail_wait_ms + config.min_tx_gap_ms,
                 "resumed heartbeat delivery latency was not bounded");
    report.check(resumed_data_writes == 1U &&
                     simulation.stats().vehicle_data_writes == 2U,
                 "resumed heartbeat was duplicated or fragmented unexpectedly");
    report.check(simulation.ground_frames().size() == 2U &&
                     same_frame(simulation.ground_frames()[1].frame,
                                heartbeat_after),
                 "resumed heartbeat exact bytes/count changed");
    std::uint64_t expected_hash = kFnv1a64Offset;
    expected_hash = append_frame_hash(expected_hash, heartbeat_before);
    expected_hash = append_frame_hash(expected_hash, heartbeat_after);
    report.check(simulation.stats().ground_frame_bytes_received ==
                         heartbeat_before.size + heartbeat_after.size &&
                     simulation.stats().ground_stream_hash == expected_hash,
                 "stopped/resumed heartbeat exact byte hash changed");
    report.check(stopped_grant_starts[0] != 0U &&
                     stopped_grant_starts[1] != 0U &&
                     simulation.diagnostics().uplink_timeouts == 0U,
                 "heartbeat stop/restart caused timeout or TDD deadlock");
    capture(report, simulation);
  } else {
    report.check(false, "unknown MAVLink E2E test ID");
    capture(report, simulation);
  }

  if (report.final_vehicle_state.empty()) {
    capture(report, simulation);
  }
  check_invariants(report, simulation);
  return report;
}

}  // namespace vc_lora::test
