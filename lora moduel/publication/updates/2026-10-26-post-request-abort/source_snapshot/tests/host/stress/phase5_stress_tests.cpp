#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>

#include "fixtures/mavlink_fixtures.hpp"
#include "integration/mavlink_e2e_sim.hpp"
#include "integration/tdd_simulation.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint64_t kCycleTimeoutMs = 8'000U;
constexpr std::size_t kMaxRetainedTraceEvents = 2'048U;
constexpr std::size_t kMaxRetainedRfTransmissions = 16U;
constexpr std::size_t kMaxPendingRfDeliveries = 16U;
constexpr std::uint64_t kFnv1a64Offset = 14'695'981'039'346'656'037ULL;
constexpr std::uint64_t kFnv1a64Prime = 1'099'511'628'211ULL;

class DeterministicRandom final {
 public:
  explicit DeterministicRandom(std::uint32_t seed) noexcept
      : state_(seed == 0U ? 0x6D2B79F5U : seed) {}

  std::uint32_t inclusive(std::uint32_t minimum,
                          std::uint32_t maximum) noexcept {
    state_ ^= state_ << 13U;
    state_ ^= state_ >> 17U;
    state_ ^= state_ << 5U;
    const std::uint32_t span = maximum - minimum + 1U;
    return minimum + state_ % span;
  }

 private:
  std::uint32_t state_{0};
};

struct PendingFaultRecovery {
  std::uint64_t fault_cycle{0};
  std::uint64_t grant_rx_baseline{0};
  std::uint64_t terminal_rx_baseline{0};
};

template <std::size_t Capacity>
void resolve_pending_recoveries(
    TestReport& report, const TddSimulation& simulation,
    std::uint64_t current_cycle, bool normal_cycle,
    std::array<PendingFaultRecovery, Capacity>& pending,
    std::size_t& pending_count) {
  if (!normal_cycle) {
    return;
  }
  const auto& diagnostics = simulation.diagnostics();
  const std::uint64_t terminal_rx =
      diagnostics.done_rx + diagnostics.idle_rx;
  std::size_t retained = 0U;
  for (std::size_t index = 0U; index < pending_count; ++index) {
    const bool recovered =
        diagnostics.grant_rx > pending[index].grant_rx_baseline &&
        terminal_rx > pending[index].terminal_rx_baseline;
    if (recovered) {
      ++report.stress.recoveries;
      report.stress.max_recovery_cycles = std::max(
          report.stress.max_recovery_cycles,
          current_cycle - pending[index].fault_cycle);
    } else {
      pending[retained++] = pending[index];
    }
  }
  pending_count = retained;
}

template <std::size_t Capacity>
void append_pending_recovery(
    TestReport& report, const TddSimulation& simulation,
    std::uint64_t fault_cycle,
    std::array<PendingFaultRecovery, Capacity>& pending,
    std::size_t& pending_count) {
  report.check(pending_count < pending.size(),
               "pending fault recovery storage exhausted");
  if (pending_count >= pending.size()) {
    return;
  }
  const auto& diagnostics = simulation.diagnostics();
  pending[pending_count++] =
      {fault_cycle, diagnostics.grant_rx,
       diagnostics.done_rx + diagnostics.idle_rx};
}

void copy_simulation(TestReport& report, TddSimulation& simulation) {
  report.cycles = simulation.stats().cycles_completed;
  report.diagnostics = simulation.diagnostics();
  report.trace = simulation.trace();
  report.final_vehicle_state = vehicle_state_name(simulation.vehicle().state());
  report.final_ground_state = ground_state_name(simulation.ground().state());
  report.vehicle_session = simulation.vehicle().session_id();
  report.ground_session = simulation.ground().session_id();
  report.vehicle_cycle = simulation.vehicle().cycle_id();
  report.ground_cycle = simulation.ground().cycle_id();
  report.stress.trace_retained_events = simulation.trace().size();
  report.stress.rf_retained_transmissions =
      simulation.medium().retained_transmission_count();
  report.stress.rf_max_retained_transmissions =
      simulation.medium().max_retained_transmission_count();
  report.stress.rf_pending_deliveries =
      simulation.medium().pending_delivery_count();
  report.stress.rf_max_pending_deliveries =
      simulation.medium().max_pending_delivery_count();
}

void check_online_invariants(TestReport& report,
                             const TddSimulation& simulation) {
  const auto& diagnostics = simulation.diagnostics();
  report.check(diagnostics.tx_during_rx_window_count == 0U,
               "online tx_during_rx_window_count != 0");
  report.check(diagnostics.ground_tx_without_valid_grant == 0U,
               "online ground_tx_without_valid_grant != 0");
  report.check(diagnostics.control_bytes_leaked_to_local_uart == 0U,
               "online control_bytes_leaked_to_local_uart != 0");
  report.check(diagnostics.invalid_crc_state_transition == 0U,
               "online invalid_crc_state_transition != 0");
  report.check(diagnostics.collision_count == 0U,
               "online collision_count != 0");
  report.check(diagnostics.tx_gate_violation == 0U,
               "online tx_gate_violation != 0");
  report.check(diagnostics.half_duplex_drop_count == 0U,
               "online half_duplex_drop_count != 0");
  report.check(diagnostics.turnaround_drop_count == 0U,
               "online turnaround_drop_count != 0");
  report.check(diagnostics.uart_buffer_drop_count == 0U,
               "online uart_buffer_drop_count != 0");
  report.check(diagnostics.uplink_data_outside_receive_window == 0U,
               "online uplink_data_outside_receive_window != 0");
  report.check(diagnostics.ground_payload_order_errors == 0U,
               "online ground_payload_order_errors != 0");
  report.check(diagnostics.ground_queue_underflow_count == 0U,
               "online ground_queue_underflow_count != 0");
  report.check(diagnostics.partial_mavlink_delivered == 0U,
               "online partial_mavlink_delivered != 0");
  report.check(diagnostics.action_retries == 0U,
               "online action_retries != 0");
  report.check(diagnostics.max_ground_queue <= kGroundUsbBufferCapacity &&
                   simulation.ground_queue_bytes() <=
                       kGroundUsbBufferCapacity,
               "online ground queue exceeded fixed capacity");
  report.check(simulation.stats().max_ground_data_write_bytes <= 32U,
               "online Ground physical write exceeded 32 bytes");
  report.check(simulation.trace().size() <= kMaxRetainedTraceEvents,
               "online trace retention exceeded its bound");
  report.check(simulation.medium().retained_transmission_count() <=
                   kMaxRetainedRfTransmissions &&
                   simulation.medium().max_retained_transmission_count() <=
                       kMaxRetainedRfTransmissions,
               "online RF transmission retention exceeded its bound");
  report.check(simulation.medium().pending_delivery_count() <=
                   kMaxPendingRfDeliveries &&
                   simulation.medium().max_pending_delivery_count() <=
                       kMaxPendingRfDeliveries,
               "online RF delivery queue exceeded its bound");
}

void check_common_invariants(TestReport& report,
                             const TddSimulation& simulation) {
  const auto& diagnostics = report.diagnostics;
  report.check(diagnostics.tx_during_rx_window_count == 0U,
               "tx_during_rx_window_count != 0");
  report.check(diagnostics.ground_tx_without_valid_grant == 0U,
               "ground_tx_without_valid_grant != 0");
  report.check(diagnostics.control_bytes_leaked_to_local_uart == 0U,
               "control_bytes_leaked_to_local_uart != 0");
  report.check(diagnostics.invalid_crc_state_transition == 0U,
               "invalid_crc_state_transition != 0");
  report.check(diagnostics.collision_count == 0U,
               "collision_count != 0");
  report.check(diagnostics.tx_gate_violation == 0U,
               "tx_gate_violation != 0");
  report.check(diagnostics.half_duplex_drop_count == 0U,
               "half_duplex_drop_count != 0");
  report.check(diagnostics.turnaround_drop_count == 0U,
               "turnaround_drop_count != 0");
  report.check(diagnostics.uart_buffer_drop_count == 0U,
               "uart_buffer_drop_count != 0");
  report.check(diagnostics.uplink_data_outside_receive_window == 0U,
               "uplink_data_outside_receive_window != 0");
  report.check(diagnostics.ground_payload_order_errors == 0U,
               "ground_payload_order_errors != 0");
  report.check(diagnostics.ground_queue_underflow_count == 0U,
               "ground_queue_underflow_count != 0");
  report.check(diagnostics.partial_mavlink_delivered == 0U,
               "partial_mavlink_delivered != 0");
  report.check(diagnostics.action_retries == 0U,
               "action_retries != 0");
  report.check(diagnostics.max_ground_queue <= kGroundUsbBufferCapacity,
               "ground queue exceeded fixed capacity");
  report.check(simulation.ground_queue_bytes() <= kGroundUsbBufferCapacity,
               "current ground queue exceeded fixed capacity");
  report.check(simulation.stats().max_ground_data_write_bytes <= 32U,
               "ground physical write exceeded 32 bytes");
  report.check(report.stress.trace_retained_events <=
                   kMaxRetainedTraceEvents,
               "trace retention is unbounded");
  report.check(report.stress.rf_retained_transmissions <=
                   kMaxRetainedRfTransmissions,
               "RF history retention is unbounded");
  report.check(report.stress.rf_max_retained_transmissions <=
                   kMaxRetainedRfTransmissions,
               "RF history high-water exceeded its bound");
  report.check(report.stress.rf_pending_deliveries <=
                   kMaxPendingRfDeliveries,
               "RF pending delivery queue is unbounded");
  report.check(report.stress.rf_max_pending_deliveries <=
                   kMaxPendingRfDeliveries,
               "RF pending delivery high-water exceeded its bound");
}

bool run_one_cycle(TestReport& report, TddSimulation& simulation,
                   std::uint64_t target_cycle) {
  const std::uint64_t started_ms = simulation.now_ms();
  const bool completed = simulation.run_until_cycles_event_driven(
      target_cycle, kCycleTimeoutMs);
  const std::uint64_t elapsed_ms = simulation.now_ms() - started_ms;
  report.stress.max_cycle_runtime_ms =
      std::max(report.stress.max_cycle_runtime_ms, elapsed_ms);
  report.check(completed, "TDD cycle did not complete within 8000 ms");
  report.check(elapsed_ms <= kCycleTimeoutMs,
               "TDD cycle exceeded its recovery deadline");
  check_online_invariants(report, simulation);
  return completed;
}

bool run_through_cycle(TestReport& report, TddSimulation& simulation,
                       std::uint64_t target_cycle) {
  while (report.passed &&
         simulation.stats().cycles_completed < target_cycle) {
    if (!run_one_cycle(report, simulation,
                       simulation.stats().cycles_completed + 1U)) {
      return false;
    }
  }
  return report.passed &&
         simulation.stats().cycles_completed >= target_cycle;
}

std::uint64_t append_expected_hash(std::uint64_t hash,
                                   const MavlinkFrame& frame) noexcept {
  for (std::size_t index = 0U; index < frame.size; ++index) {
    hash ^= frame.bytes[index];
    hash *= kFnv1a64Prime;
  }
  return hash;
}

void copy_mavlink_simulation(TestReport& report,
                             const MavlinkE2eSimulation& simulation) {
  report.cycles = simulation.stats().cycles_completed;
  report.diagnostics = simulation.diagnostics();
  report.final_vehicle_state = vehicle_state_name(simulation.vehicle().state());
  report.final_ground_state = ground_state_name(simulation.ground().state());
  report.vehicle_session = simulation.vehicle().session_id();
  report.ground_session = simulation.ground().session_id();
  report.vehicle_cycle = simulation.vehicle().cycle_id();
  report.ground_cycle = simulation.ground().cycle_id();
  report.stress.rf_retained_transmissions =
      simulation.medium().retained_transmission_count();
  report.stress.rf_max_retained_transmissions =
      simulation.medium().max_retained_transmission_count();
  report.stress.rf_pending_deliveries =
      simulation.medium().pending_delivery_count();
  report.stress.rf_max_pending_deliveries =
      simulation.medium().max_pending_delivery_count();
  report.stress.mavlink_vehicle_frames =
      simulation.stats().vehicle_frames_received;
  report.stress.mavlink_ground_frames =
      simulation.stats().ground_frames_received;
  report.stress.mavlink_vehicle_stream_hash =
      simulation.stats().vehicle_stream_hash;
  report.stress.mavlink_ground_stream_hash =
      simulation.stats().ground_stream_hash;
  const MavlinkHeartbeatGapPoint& before =
      simulation.stats().heartbeat_gap_before;
  const MavlinkHeartbeatGapPoint& after =
      simulation.stats().heartbeat_gap_after;
  report.stress.heartbeat_gap_before_rx_ms = before.received_ms;
  report.stress.heartbeat_gap_after_rx_ms = after.received_ms;
  report.stress.heartbeat_gap_before_tx_start_ms = before.tx_start_ms;
  report.stress.heartbeat_gap_before_tx_end_ms = before.tx_end_ms;
  report.stress.heartbeat_gap_after_tx_start_ms = after.tx_start_ms;
  report.stress.heartbeat_gap_after_tx_end_ms = after.tx_end_ms;
  report.stress.heartbeat_gap_before_terminal_ms =
      before.last_terminal_rx_ms;
  report.stress.heartbeat_gap_after_terminal_ms =
      after.last_terminal_rx_ms;
  report.stress.heartbeat_gap_before_wire_count = before.wire_write_count;
  report.stress.heartbeat_gap_after_wire_count = after.wire_write_count;
  report.stress.heartbeat_gap_before_cycle = before.cycle_id;
  report.stress.heartbeat_gap_after_cycle = after.cycle_id;
  report.stress.heartbeat_gap_before_state = before.vehicle_state;
  report.stress.heartbeat_gap_after_state = after.vehicle_state;
  report.trace = simulation.failure_context_trace();
  report.stress.trace_retained_events = report.trace.size();
}

void check_mavlink_online_invariants(
    TestReport& report, const MavlinkE2eSimulation& simulation) {
  const auto& diagnostics = simulation.diagnostics();
  const auto& stats = simulation.stats();
  report.check(diagnostics.tx_during_rx_window_count == 0U,
               "MAVLink stress vehicle TX occurred during uplink RX");
  report.check(diagnostics.ground_tx_without_valid_grant == 0U,
               "MAVLink stress Ground TX occurred without valid GRANT");
  report.check(diagnostics.control_bytes_leaked_to_local_uart == 0U,
               "MAVLink stress control bytes leaked to endpoint UART");
  report.check(diagnostics.invalid_crc_state_transition == 0U,
               "MAVLink stress invalid control changed state");
  report.check(diagnostics.collision_count == 0U &&
                   diagnostics.packet_loss_count == 0U,
               "MAVLink stress normal RF path collided or lost a packet");
  report.check(diagnostics.tx_gate_violation == 0U &&
                   diagnostics.half_duplex_drop_count == 0U &&
                   diagnostics.turnaround_drop_count == 0U,
               "MAVLink stress violated TX/half-duplex/turnaround gate");
  report.check(diagnostics.uart_buffer_drop_count == 0U &&
                   diagnostics.uplink_data_outside_receive_window == 0U,
               "MAVLink stress violated UART or receive-window boundary");
  report.check(diagnostics.control_crc_errors == 0U &&
                   diagnostics.mavlink_crc_errors == 0U &&
                   diagnostics.mavlink_parser_resets == 0U,
               "valid MAVLink stress input caused CRC/parser error");
  report.check(diagnostics.partial_mavlink_delivered == 0U,
               "MAVLink stress delivered a partial frame");
  report.check(diagnostics.mavlink_queue_drop_frames == 0U &&
                   diagnostics.mavlink_queue_drop_bytes == 0U &&
                   diagnostics.ground_usb_dropped_bytes == 0U,
               "in-capacity MAVLink stress traffic was dropped");
  report.check(diagnostics.ground_queue_underflow_count == 0U &&
                   diagnostics.action_retries == 0U,
               "MAVLink stress underflowed or retried an action");
  report.check(stats.physical_write_oversize_count == 0U &&
                   stats.physical_write_gap_violations == 0U &&
                   stats.ground_window_overrun_count == 0U,
               "MAVLink stress violated 32-byte/gap/window write limits");
  report.check(simulation.ground_queue_bytes() <=
                   kMavlinkGroundBufferCapacity &&
                   diagnostics.max_ground_queue <=
                       kMavlinkGroundBufferCapacity,
               "MAVLink Ground ring exceeded fixed capacity");
  report.check(simulation.vehicle_queue_frames() <=
                   MavlinkFrameScheduler::capacity(),
               "MAVLink scheduler exceeded fixed frame capacity");
  report.check(simulation.vehicle_frames().empty() &&
                   simulation.ground_frames().empty() &&
                   simulation.wire_writes().empty() &&
                   stats.max_captured_vehicle_frames == 0U &&
                   stats.max_captured_ground_frames == 0U &&
                   stats.max_captured_wire_writes == 0U,
               "MAVLink stress capture unexpectedly retained history");
  report.check(stats.max_failure_context_pre_events <= 100U &&
                   stats.max_failure_context_trace_events <= 201U &&
                   simulation.failure_context_trace().size() <= 201U,
               "MAVLink failure-context capture exceeded fixed bounds");
  report.check(simulation.medium().retained_transmission_count() <=
                   kMaxRetainedRfTransmissions &&
                   simulation.medium().max_retained_transmission_count() <=
                       kMaxRetainedRfTransmissions,
               "MAVLink stress RF transmission history exceeded bound");
  report.check(simulation.medium().pending_delivery_count() <=
                   kMaxPendingRfDeliveries &&
                   simulation.medium().max_pending_delivery_count() <=
                       kMaxPendingRfDeliveries,
               "MAVLink stress RF delivery queue exceeded bound");
}

void ingest_gcs_stress_frame(TestReport& report,
                             MavlinkE2eSimulation& simulation,
                             const MavlinkFrame& frame) {
  constexpr std::array<std::size_t, 5> chunks{{1U, 7U, 3U, 11U, 29U}};
  std::size_t offset = 0U;
  std::size_t chunk_index = 0U;
  while (offset < frame.size) {
    const std::size_t count = std::min(
        chunks[chunk_index++ % chunks.size()], frame.size - offset);
    report.check(simulation.ingest_gcs_stream(frame.bytes.data() + offset,
                                              count) == count,
                 "Ground MAVLink stress parser did not consume its chunk");
    offset += count;
  }
}

void run_st_mav_001(TestReport& report, std::uint32_t seed,
                    std::uint64_t event_quantum_ms) {
  constexpr std::uint64_t kCycles = 10'000U;
  constexpr std::uint64_t kHeartbeatPeriodMs = 1'000U;
  TddConfig config{};
  RfMediumConfig rf_config{};
  MavlinkE2eCaptureConfig capture{};
  capture.frames = false;
  capture.wire_writes = false;
  capture.failure_context_pre_events = 100U;
  capture.failure_context_post_events = 100U;
  capture.failure_heartbeat_gap_ms = 2'500U;
  MavlinkE2eSimulation simulation(config, rf_config, seed, capture);
  simulation.start(100U, 0U);

  std::uint64_t expected_vehicle_hash = kFnv1a64Offset;
  std::uint64_t expected_ground_hash = kFnv1a64Offset;
  std::uint64_t expected_vehicle_bytes = 0U;
  std::uint64_t expected_ground_bytes = 0U;
  std::uint64_t expected_heartbeats = 0U;
  std::uint64_t expected_pid_frames = 0U;
  std::uint64_t expected_pid_bytes = 0U;
  std::uint64_t next_heartbeat_ms = 0U;
  std::uint64_t adversarial_frames = 0U;
  std::uint8_t heartbeat_sequence = 0U;
  const std::uint64_t event_quantum =
      std::max<std::uint64_t>(1U, event_quantum_ms);

  for (std::uint64_t target = 1U;
       target <= kCycles && report.passed; ++target) {
    char id[17]{};
    const bool adversarial = target % 32U == 0U;
    if (adversarial) {
      (void)std::snprintf(id, sizeof(id), "VCTD}STRESS_%02u",
                          static_cast<unsigned>(target % 100U));
      ++adversarial_frames;
    } else {
      (void)std::snprintf(id, sizeof(id), "STRESS_%05u",
                          static_cast<unsigned>(target % 100'000U));
    }
    const MavlinkFrame uplink = fixtures::param_set_v2(
        static_cast<std::uint8_t>(target), id,
        static_cast<float>(target % 1'000U));
    if (adversarial) {
      bool saw_escape = false;
      bool saw_vctd = false;
      for (std::size_t index = 0U; index < uplink.size; ++index) {
        saw_escape = saw_escape || uplink.bytes[index] == 0x7DU;
        if (index + 3U < uplink.size && uplink.bytes[index] == 0x56U &&
            uplink.bytes[index + 1U] == 0x43U &&
            uplink.bytes[index + 2U] == 0x54U &&
            uplink.bytes[index + 3U] == 0x44U) {
          saw_vctd = true;
        }
      }
      report.check(saw_escape && saw_vctd,
                   "adversarial MAVLink frame lacks VCTD/0x7D payload");
    }
    ingest_gcs_stress_frame(report, simulation, uplink);
    expected_vehicle_hash =
        append_expected_hash(expected_vehicle_hash, uplink);
    expected_vehicle_bytes += uplink.size;

    const MavlinkFrame pid = fixtures::pid_tuning_v2(
        static_cast<std::uint8_t>(target),
        static_cast<float>(target % 100U));
    report.check(simulation.ingest_pixhawk_stream(pid.bytes.data(), pid.size) ==
                     pid.size,
                 "Pixhawk msg194 stress parser did not consume frame");
    ++expected_pid_frames;
    expected_pid_bytes += pid.size;

    const std::uint64_t cycle_deadline = simulation.now_ms() +
                                         kCycleTimeoutMs;
    while (simulation.stats().cycles_completed < target &&
           simulation.now_ms() < cycle_deadline && report.passed) {
      if (target < kCycles) {
        while (simulation.now_ms() >= next_heartbeat_ms) {
          const MavlinkFrame heartbeat =
              fixtures::heartbeat_v2(heartbeat_sequence++);
          report.check(simulation.ingest_pixhawk_stream(
                           heartbeat.bytes.data(), heartbeat.size) ==
                           heartbeat.size,
                       "Pixhawk heartbeat stress parser did not consume frame");
          expected_ground_hash =
              append_expected_hash(expected_ground_hash, heartbeat);
          expected_ground_bytes += heartbeat.size;
          ++expected_heartbeats;
          next_heartbeat_ms += kHeartbeatPeriodMs;
        }
      }
      std::uint64_t quantum = event_quantum;
      if (target < kCycles && next_heartbeat_ms > simulation.now_ms()) {
        quantum = std::min<std::uint64_t>(
            quantum, next_heartbeat_ms - simulation.now_ms());
      }
      simulation.step_event_driven(std::max<std::uint64_t>(1U, quantum));
    }
    report.check(simulation.stats().cycles_completed >= target,
                 "MAVLink production-timing cycle exceeded 8000 ms");
    check_mavlink_online_invariants(report, simulation);
  }

  copy_mavlink_simulation(report, simulation);
  const auto& stats = simulation.stats();
  const auto& diagnostics = report.diagnostics;
  report.check(report.cycles == kCycles,
               "ST-MAV-001 did not complete 10000 cycles");
  report.check(simulation.now_ms() >= 40'000'000U,
               "ST-MAV-001 did not use production timing");
  report.check(adversarial_frames == kCycles / 32U,
               "periodic VCTD/0x7D fixture count is not exact");
  report.check(stats.vehicle_frames_received == kCycles &&
                   stats.vehicle_frame_bytes_received ==
                       expected_vehicle_bytes &&
                   stats.vehicle_stream_hash == expected_vehicle_hash,
               "10k Ground-to-Pixhawk MAVLink stream count/hash changed");
  report.check(stats.ground_frames_received == expected_heartbeats &&
                   stats.ground_frame_bytes_received ==
                       expected_ground_bytes &&
                   stats.ground_stream_hash == expected_ground_hash,
               "Pixhawk heartbeat stream count/hash changed");
  const TraceEvent* context_before =
      simulation.failure_context_trace().event_at(99U);
  const TraceEvent* context_marker =
      simulation.failure_context_trace().event_at(100U);
  const TraceEvent* context_after =
      simulation.failure_context_trace().event_at(101U);
  const bool gap_violation = diagnostics.heartbeat_max_gap_ms > 2'500U;
  if (gap_violation) {
    report.check(simulation.failure_context_triggered() &&
                     simulation.failure_context_complete() &&
                     stats.failure_context_pre_events == 100U &&
                     stats.failure_context_post_events == 100U &&
                     simulation.failure_context_trace().size() == 201U,
                 "heartbeat failure context is not exactly 100+marker+100");
    report.check(context_before != nullptr && context_marker != nullptr &&
                     context_after != nullptr &&
                     context_marker->event.find(
                         "HEARTBEAT_GAP_VIOLATION") != std::string::npos &&
                     context_before->time_ms <= context_marker->time_ms &&
                     context_marker->time_ms <= context_after->time_ms,
                 "heartbeat failure marker is not ordered at trace index 100");
  } else {
    report.check(!simulation.failure_context_triggered() &&
                     stats.failure_context_pre_events == 0U &&
                     stats.failure_context_post_events == 0U &&
                     simulation.failure_context_trace().size() == 0U,
                 "passing heartbeat run retained a failure-only trace");
  }
  report.check(diagnostics.heartbeat_valid == expected_heartbeats &&
                   diagnostics.heartbeat_max_gap_ms <= 2'500U,
               "Pixhawk heartbeat cadence exceeded 2500 ms");
  report.check(diagnostics.mavlink_msg194_filtered_frames ==
                       expected_pid_frames &&
                   diagnostics.mavlink_msg194_filtered_bytes ==
                       expected_pid_bytes,
               "msg194 stress filtering count/bytes changed");
  report.check(diagnostics.mavlink_frames_ingested ==
                       kCycles + expected_heartbeats +
                           expected_pid_frames &&
                   diagnostics.mavlink_frames_forwarded ==
                       kCycles + expected_heartbeats,
               "MAVLink stress ingress/forward accounting is incomplete");
  report.check(diagnostics.ground_usb_rx_bytes == expected_vehicle_bytes &&
                   diagnostics.ground_usb_accepted_bytes ==
                       expected_vehicle_bytes &&
                   diagnostics.ground_usb_dequeued_bytes ==
                       expected_vehicle_bytes,
               "Ground parser/ring/dequeue byte accounting changed");
  report.check(diagnostics.grant_tx == kCycles &&
                   diagnostics.grant_rx == kCycles &&
                   diagnostics.done_tx == kCycles &&
                   diagnostics.done_rx == kCycles,
               "ST-MAV-001 GRANT/DONE count is not 10000/10000");
  report.check(simulation.ground_queue_bytes() == 0U &&
                   simulation.vehicle_queue_bytes() == 0U &&
                   simulation.vehicle_queue_frames() == 0U,
               "MAVLink stress queues did not drain by cycle 10000");
  check_mavlink_online_invariants(report, simulation);
  report.detail =
      "10000 production-timing MAVLink cycles through parsers, scheduler, "
      "frame-aware ring and escaped TDD link; bulk frame/wire capture "
      "disabled, bounded failure context enabled, exact rolling hashes, "
      "1 Hz heartbeat and periodic VCTD/0x7D payloads verified. "
      "Maximum heartbeat gap endpoints are recorded in summary; " +
      std::string(simulation.failure_context_triggered()
                      ? "trace holds 100 actual events before and after the "
                        "first breach marker. "
                      : "no breach occurred and the failure-only trace is "
                        "empty. ") +
      "Event "
      "quantum=" +
      std::to_string(event_quantum) + " ms. Endpoints: "
      "rx=" +
      std::to_string(stats.heartbeat_gap_before.received_ms) + "->" +
      std::to_string(stats.heartbeat_gap_after.received_ms) +
      " ms, vehicle TX=" +
      std::to_string(stats.heartbeat_gap_before.tx_start_ms) + ".." +
      std::to_string(stats.heartbeat_gap_before.tx_end_ms) + "->" +
      std::to_string(stats.heartbeat_gap_after.tx_start_ms) + ".." +
      std::to_string(stats.heartbeat_gap_after.tx_end_ms) + " ms, DONE=" +
      std::to_string(stats.heartbeat_gap_before.last_terminal_rx_ms) +
      "->" +
      std::to_string(stats.heartbeat_gap_after.last_terminal_rx_ms) + " ms.";
}

void run_st_mav_phase_001(TestReport& report, std::uint32_t seed) {
  constexpr std::uint64_t kPhaseCount = 1'000U;
  constexpr std::uint64_t kActiveCycles = 4U;
  constexpr std::uint64_t kTailCycles = 2U;
  constexpr std::uint64_t kCyclesPerPhase =
      kActiveCycles + kTailCycles;
  constexpr std::uint64_t kHeartbeatPeriodMs = 1'000U;
  constexpr std::uint64_t kHeartbeatGapLimitMs = 2'500U;
  TddConfig config{};
  RfMediumConfig rf_config{};
  LinkDiagnostics aggregate{};
  TraceRecorder worst_trace{};
  MavlinkHeartbeatGapPoint worst_before{};
  MavlinkHeartbeatGapPoint worst_after{};
  std::uint64_t completed_phases = 0U;
  std::uint64_t failing_phases = 0U;
  std::uint64_t worst_gap_ms = 0U;
  std::uint64_t worst_phase_ms = 0U;
  std::uint64_t total_expected_heartbeats = 0U;
  std::uint64_t total_vehicle_frames = 0U;
  std::uint64_t total_ground_frames = 0U;

  for (std::uint64_t phase_ms = 0U;
       phase_ms < kPhaseCount && report.passed; ++phase_ms) {
    MavlinkE2eCaptureConfig capture{};
    capture.frames = false;
    capture.wire_writes = false;
    capture.failure_context_pre_events = 100U;
    capture.failure_context_post_events = 100U;
    capture.failure_heartbeat_gap_ms = kHeartbeatGapLimitMs;
    MavlinkE2eSimulation simulation(
        config, rf_config,
        seed ^ static_cast<std::uint32_t>(phase_ms * 0x9E37U), capture);
    simulation.start(static_cast<std::uint16_t>(200U + phase_ms), 0U);

    std::uint64_t expected_vehicle_hash = kFnv1a64Offset;
    std::uint64_t expected_ground_hash = kFnv1a64Offset;
    std::uint64_t expected_vehicle_bytes = 0U;
    std::uint64_t expected_ground_bytes = 0U;
    std::uint64_t expected_heartbeats = 0U;
    std::uint64_t next_heartbeat_ms = phase_ms;
    std::uint8_t heartbeat_sequence = 0U;

    for (std::uint64_t target = 1U;
         target <= kCyclesPerPhase && report.passed; ++target) {
      char id[17]{};
      (void)std::snprintf(
          id, sizeof(id), "PH%03u_C%02u",
          static_cast<unsigned>(phase_ms), static_cast<unsigned>(target));
      const MavlinkFrame uplink = fixtures::param_set_v2(
          static_cast<std::uint8_t>(target), id,
          static_cast<float>(phase_ms) + static_cast<float>(target) / 10.0F);
      report.check(uplink.size == 35U,
                   "phase-sweep uplink fixture is not 35 bytes");
      ingest_gcs_stress_frame(report, simulation, uplink);
      expected_vehicle_hash =
          append_expected_hash(expected_vehicle_hash, uplink);
      expected_vehicle_bytes += uplink.size;

      const bool heartbeat_active = target <= kActiveCycles;
      const std::uint64_t cycle_deadline =
          simulation.now_ms() + kCycleTimeoutMs;
      while (simulation.stats().cycles_completed < target &&
             simulation.now_ms() < cycle_deadline && report.passed) {
        if (heartbeat_active) {
          while (simulation.now_ms() >= next_heartbeat_ms) {
            const MavlinkFrame heartbeat =
                fixtures::heartbeat_v2(heartbeat_sequence++);
            report.check(simulation.ingest_pixhawk_stream(
                             heartbeat.bytes.data(), heartbeat.size) ==
                             heartbeat.size,
                         "phase-sweep heartbeat parser rejected valid input");
            expected_ground_hash =
                append_expected_hash(expected_ground_hash, heartbeat);
            expected_ground_bytes += heartbeat.size;
            ++expected_heartbeats;
            next_heartbeat_ms += kHeartbeatPeriodMs;
          }
        }
        std::uint64_t quantum = 5U;
        if (heartbeat_active && next_heartbeat_ms > simulation.now_ms()) {
          quantum = std::min<std::uint64_t>(
              quantum, next_heartbeat_ms - simulation.now_ms());
        }
        simulation.step_event_driven(std::max<std::uint64_t>(1U, quantum));
      }
      report.check(simulation.stats().cycles_completed >= target,
                   "phase-sweep TDD cycle exceeded 8000 ms");
      check_mavlink_online_invariants(report, simulation);
    }

    const auto& stats = simulation.stats();
    const auto& diagnostics = simulation.diagnostics();
    report.check(stats.cycles_completed == kCyclesPerPhase,
                 "heartbeat-stop tail did not complete two TDD cycles");
    report.check(stats.vehicle_frames_received == kCyclesPerPhase &&
                     stats.vehicle_frame_bytes_received ==
                         expected_vehicle_bytes &&
                     stats.vehicle_stream_hash == expected_vehicle_hash,
                 "phase-sweep uplink count/bytes/hash changed");
    report.check(stats.ground_frames_received == expected_heartbeats &&
                     stats.ground_frame_bytes_received ==
                         expected_ground_bytes &&
                     stats.ground_stream_hash == expected_ground_hash,
                 "phase-sweep heartbeat count/bytes/hash changed");
    report.check(diagnostics.heartbeat_valid == expected_heartbeats &&
                     diagnostics.mavlink_frames_ingested ==
                         kCyclesPerPhase + expected_heartbeats &&
                     diagnostics.mavlink_frames_forwarded ==
                         kCyclesPerPhase + expected_heartbeats,
                 "phase-sweep MAVLink frame accounting changed");
    report.check(diagnostics.uplink_timeouts == 0U &&
                     diagnostics.done_rx == kCyclesPerPhase &&
                     simulation.ground_queue_bytes() == 0U &&
                     simulation.vehicle_queue_bytes() == 0U &&
                     simulation.vehicle_queue_frames() == 0U,
                 "heartbeat-stop tail timed out, deadlocked, or failed to drain");
    const bool gap_violation =
        diagnostics.heartbeat_max_gap_ms > kHeartbeatGapLimitMs;
    if (gap_violation) {
      ++failing_phases;
      report.check(simulation.failure_context_triggered() &&
                       simulation.failure_context_complete() &&
                       simulation.failure_context_trace().size() == 201U,
                   "phase-sweep failure trace is not 100+marker+100");
    } else {
      report.check(!simulation.failure_context_triggered() &&
                       simulation.failure_context_trace().size() == 0U,
                   "passing phase retained a failure-only trace");
    }
    if (diagnostics.heartbeat_max_gap_ms > worst_gap_ms) {
      worst_gap_ms = diagnostics.heartbeat_max_gap_ms;
      worst_phase_ms = phase_ms;
      worst_trace = simulation.failure_context_trace();
      worst_before = stats.heartbeat_gap_before;
      worst_after = stats.heartbeat_gap_after;
    }

    aggregate.grant_tx += diagnostics.grant_tx;
    aggregate.grant_rx += diagnostics.grant_rx;
    aggregate.done_tx += diagnostics.done_tx;
    aggregate.done_rx += diagnostics.done_rx;
    aggregate.uplink_transactions += diagnostics.uplink_transactions;
    aggregate.uplink_payload_bytes += diagnostics.uplink_payload_bytes;
    aggregate.downlink_transactions += diagnostics.downlink_transactions;
    aggregate.downlink_payload_bytes += diagnostics.downlink_payload_bytes;
    aggregate.ground_usb_rx_bytes += diagnostics.ground_usb_rx_bytes;
    aggregate.ground_usb_accepted_bytes +=
        diagnostics.ground_usb_accepted_bytes;
    aggregate.ground_usb_dequeued_bytes +=
        diagnostics.ground_usb_dequeued_bytes;
    aggregate.mavlink_frames_ingested += diagnostics.mavlink_frames_ingested;
    aggregate.mavlink_frames_forwarded +=
        diagnostics.mavlink_frames_forwarded;
    aggregate.heartbeat_valid += diagnostics.heartbeat_valid;
    aggregate.heartbeat_max_gap_ms =
        std::max(aggregate.heartbeat_max_gap_ms,
                 diagnostics.heartbeat_max_gap_ms);
    aggregate.max_mavlink_queue_frames = std::max(
        aggregate.max_mavlink_queue_frames,
        diagnostics.max_mavlink_queue_frames);
    aggregate.max_mavlink_queue_bytes = std::max(
        aggregate.max_mavlink_queue_bytes,
        diagnostics.max_mavlink_queue_bytes);
    aggregate.max_vehicle_queue = std::max(
        aggregate.max_vehicle_queue, diagnostics.max_vehicle_queue);
    aggregate.max_ground_queue = std::max(
        aggregate.max_ground_queue, diagnostics.max_ground_queue);
    total_expected_heartbeats += expected_heartbeats;
    total_vehicle_frames += stats.vehicle_frames_received;
    total_ground_frames += stats.ground_frames_received;
    ++completed_phases;
  }

  report.cycles = completed_phases * kCyclesPerPhase;
  report.diagnostics = aggregate;
  report.trace = worst_trace;
  report.stress.trace_retained_events = report.trace.size();
  report.stress.mavlink_vehicle_frames = total_vehicle_frames;
  report.stress.mavlink_ground_frames = total_ground_frames;
  report.stress.heartbeat_gap_before_rx_ms = worst_before.received_ms;
  report.stress.heartbeat_gap_after_rx_ms = worst_after.received_ms;
  report.stress.heartbeat_gap_before_tx_start_ms = worst_before.tx_start_ms;
  report.stress.heartbeat_gap_before_tx_end_ms = worst_before.tx_end_ms;
  report.stress.heartbeat_gap_after_tx_start_ms = worst_after.tx_start_ms;
  report.stress.heartbeat_gap_after_tx_end_ms = worst_after.tx_end_ms;
  report.stress.heartbeat_gap_before_terminal_ms =
      worst_before.last_terminal_rx_ms;
  report.stress.heartbeat_gap_after_terminal_ms =
      worst_after.last_terminal_rx_ms;
  report.final_vehicle_state = "PHASE_SWEEP_COMPLETE";
  report.final_ground_state = "PHASE_SWEEP_COMPLETE";
  report.check(completed_phases == kPhaseCount,
               "heartbeat phase sweep did not cover all 0..999 ms phases");
  report.check(total_vehicle_frames == kPhaseCount * kCyclesPerPhase,
               "phase-sweep total uplink frame count is not exact");
  report.check(aggregate.heartbeat_valid == total_expected_heartbeats &&
                   total_ground_frames == total_expected_heartbeats,
               "phase-sweep total heartbeat count is not exact");
  report.check(worst_gap_ms <= kHeartbeatGapLimitMs,
               "heartbeat phase sweep exceeded 2500 ms maximum gap");
  report.detail =
      "Swept heartbeat phase 0..999 ms against the TDD boundary with six "
      "continuous 35-byte uplink cycles per phase (four heartbeat-active plus "
      "two heartbeat-stop tail cycles). Exact frame hashes/counts and fixed "
      "write/gap/window constraints passed. Failing phases=" +
      std::to_string(failing_phases) + "/1000, worst phase=" +
      std::to_string(worst_phase_ms) + " ms, worst gap=" +
      std::to_string(worst_gap_ms) + " ms.";
}

void run_st_001(TestReport& report, std::uint32_t seed) {
  constexpr std::uint64_t kCycles = 10'000U;
  TddConfig config{};
  RfMediumConfig rf_config{};
  TddSimulation simulation(config, rf_config, seed);
  simulation.set_vehicle_downlink_per_cycle(32U);
  simulation.start(40U, 0U);

  std::array<std::size_t, 3> trace_checkpoints{};
  std::array<std::size_t, 3> rf_checkpoints{};
  std::size_t checkpoint_index = 0U;
  for (std::uint64_t target = 1U; target <= kCycles; ++target) {
    simulation.queue_ground_bytes(64U);
    if (!run_one_cycle(report, simulation, target)) {
      break;
    }
    if (target == 1'000U || target == 5'000U || target == kCycles) {
      trace_checkpoints[checkpoint_index] = simulation.trace().size();
      rf_checkpoints[checkpoint_index] =
          simulation.medium().retained_transmission_count();
      report.check(trace_checkpoints[checkpoint_index] <=
                       kMaxRetainedTraceEvents,
                   "trace storage did not plateau by checkpoint");
      report.check(rf_checkpoints[checkpoint_index] <=
                       kMaxRetainedRfTransmissions,
                   "RF history did not plateau by checkpoint");
      ++checkpoint_index;
    }
    if (!report.passed) {
      break;
    }
  }

  copy_simulation(report, simulation);
  report.check(report.cycles == kCycles,
               "10000 production-timing cycles were not completed");
  report.check(simulation.now_ms() >= 40'000'000U,
               "ST-001 did not use production timing");
  report.check(report.diagnostics.grant_tx == kCycles &&
                   report.diagnostics.grant_rx == kCycles,
               "ST-001 GRANT count is not 10000/10000");
  report.check(report.diagnostics.done_tx == kCycles &&
                   report.diagnostics.done_rx == kCycles,
               "ST-001 DONE count is not 10000/10000");
  report.check(report.diagnostics.uplink_transactions == kCycles,
               "ST-001 did not maintain one uplink transaction per cycle");
  report.check(report.diagnostics.uplink_payload_bytes == 640'000U &&
                   simulation.stats().vehicle_payload_rx == 640'000U,
               "ST-001 uplink payload accounting is not 640000 bytes");
  report.check(report.diagnostics.downlink_payload_bytes == 320'000U &&
                   simulation.stats().ground_payload_rx == 320'000U,
               "ST-001 downlink payload accounting is not 320000 bytes");
  report.check(report.diagnostics.ground_usb_dropped_bytes == 0U &&
                   report.diagnostics.ground_buffer_overflow_count == 0U,
               "ST-001 had an unexpected Ground USB drop");
  report.check(report.diagnostics.ground_usb_accepted_bytes == 640'000U &&
                   report.diagnostics.ground_usb_dequeued_bytes == 640'000U,
               "ST-001 Ground USB accounting is not exact");
  report.check(simulation.ground_queue_bytes() == 0U,
               "ST-001 Ground queue did not drain");
  report.check(report.diagnostics.uplink_timeouts == 0U,
               "ST-001 normal run had an uplink timeout");
  report.check(checkpoint_index == trace_checkpoints.size(),
               "ST-001 storage checkpoints were not all reached");
  check_common_invariants(report, simulation);
  report.detail =
      "10000 production-timing cycles with 64-byte uplink and 32-byte "
      "downlink per cycle; trace and RF retained storage must plateau.";
}

void run_st_002(TestReport& report, std::uint32_t seed) {
  constexpr std::uint64_t kCycles = 2'000U;
  TddConfig config{};
  RfMediumConfig rf_config{};
  rf_config.loss_permyriad = 100U;
  TddSimulation simulation(config, rf_config, seed);
  simulation.start(50U, 0U);
  std::array<PendingFaultRecovery, kCycles> pending{};
  std::size_t pending_count = 0U;

  for (std::uint64_t target = 1U; target <= kCycles; ++target) {
    const std::uint64_t before = simulation.diagnostics().packet_loss_count;
    if (!run_one_cycle(report, simulation, target)) {
      break;
    }
    const std::uint64_t injected =
        simulation.diagnostics().packet_loss_count - before;
    report.check(injected <= 1U,
                  "more than one loss was injected in one empty-uplink cycle");
    resolve_pending_recoveries(report, simulation, target, injected == 0U,
                               pending, pending_count);
    if (injected != 0U) {
      report.stress.fault_injections += injected;
      append_pending_recovery(report, simulation, target, pending,
                              pending_count);
    }
    if (!report.passed) {
      break;
    }
  }

  copy_simulation(report, simulation);
  report.check(report.cycles == kCycles,
               "1% packet-loss scenario did not complete 2000 cycles");
  report.check(report.stress.fault_injections > 0U,
               "fixed seed did not inject packet loss");
  report.check(report.stress.recoveries == report.stress.fault_injections,
                "not every packet-loss event reached a later valid cycle");
  report.check(pending_count == 0U,
               "packet-loss scenario ended with pending recovery");
  report.check(report.stress.max_recovery_cycles <= 2U,
               "packet-loss recovery exceeded two completed cycles");
  report.check(report.diagnostics.packet_loss_count ==
                   report.stress.fault_injections,
               "packet-loss injection accounting mismatch");
  report.check(report.diagnostics.uplink_timeouts ==
                   report.stress.fault_injections,
               "control loss did not produce exactly one bounded timeout");
  report.check(report.diagnostics.idle_rx +
                       report.stress.fault_injections ==
                   kCycles,
               "loss/recovery cycle accounting is incomplete");
  report.check(report.diagnostics.control_crc_errors == 0U,
               "packet loss was misreported as control corruption");
  check_common_invariants(report, simulation);
  report.detail =
      "Frame-level deterministic 1% RF loss on empty-uplink cycles; each "
      "lost GRANT/IDLE must recover without unauthorized transmission.";
}

void run_st_003(TestReport& report, std::uint32_t seed) {
  constexpr std::uint64_t kCycles = 2'000U;
  TddConfig config{};
  RfMediumConfig rf_config{};
  rf_config.corruption_permyriad = 10U;
  TddSimulation simulation(config, rf_config, seed);
  simulation.start(60U, 0U);
  std::array<PendingFaultRecovery, kCycles> pending{};
  std::size_t pending_count = 0U;

  for (std::uint64_t target = 1U; target <= kCycles; ++target) {
    const std::uint64_t crc_before =
        simulation.diagnostics().control_crc_errors;
    const std::uint64_t injections_before =
        simulation.medium().random_corruption_injection_count();
    if (!run_one_cycle(report, simulation, target)) {
      break;
    }
    const std::uint64_t injected =
        simulation.medium().random_corruption_injection_count() -
        injections_before;
    const std::uint64_t observed_crc =
        simulation.diagnostics().control_crc_errors - crc_before;
    report.check(
        injected <= 1U,
        "more than one corruption was injected in one empty-uplink cycle");
    report.check(observed_crc == injected,
                 "RF corruption injection and decoder CRC observation differ");
    resolve_pending_recoveries(report, simulation, target, injected == 0U,
                               pending, pending_count);
    if (injected != 0U) {
      report.stress.fault_injections += injected;
      append_pending_recovery(report, simulation, target, pending,
                              pending_count);
    }
    if (!report.passed) {
      break;
    }
  }

  copy_simulation(report, simulation);
  report.check(report.cycles == kCycles,
               "0.1% corruption scenario did not complete 2000 cycles");
  report.check(report.stress.fault_injections > 0U,
               "fixed seed did not inject control corruption");
  report.check(report.stress.recoveries == report.stress.fault_injections,
                "not every corruption reached a later valid cycle");
  report.check(pending_count == 0U,
               "corruption scenario ended with pending recovery");
  report.check(report.stress.max_recovery_cycles <= 2U,
               "control-corruption recovery exceeded two completed cycles");
  report.check(report.diagnostics.control_crc_errors ==
                       report.stress.fault_injections &&
                   simulation.medium().random_corruption_injection_count() ==
                       report.stress.fault_injections &&
                   simulation.medium().targeted_corruption_injection_count() ==
                       0U,
               "independent RF injection/decoder CRC accounting mismatch");
  report.check(report.diagnostics.invalid_crc_state_transition == 0U,
               "corrupt control frame changed TDD state");
  report.check(report.diagnostics.uplink_timeouts ==
                   report.stress.fault_injections,
               "corrupt control did not produce exactly one bounded timeout");
  report.check(report.diagnostics.idle_rx +
                       report.stress.fault_injections ==
                   kCycles,
               "corruption/recovery cycle accounting is incomplete");
  report.check(report.diagnostics.packet_loss_count == 0U,
               "corruption scenario unexpectedly lost an RF frame");
  check_common_invariants(report, simulation);
  report.detail =
      "Frame-level deterministic 0.1% bit corruption on control-only "
      "traffic; independent RF injections must match decoder CRC errors 1:1, "
      "must never change state, and must recover.";
}

void run_st_004(TestReport& report, std::uint32_t seed) {
  constexpr std::uint64_t kCycles = 1'100U;
  TddConfig config{};
  RfMediumConfig rf_config{};
  TddSimulation simulation(config, rf_config, seed);
  std::uint16_t vehicle_session = 70U;
  simulation.start(vehicle_session, 0U);

  std::uint64_t reboot_ordinal = 0U;
  for (std::uint64_t reboot_at = 100U; reboot_at <= 1'000U;
       reboot_at += 100U) {
    if (!run_through_cycle(report, simulation, reboot_at)) {
      report.check(false, "period before scheduled reboot did not complete");
      break;
    }
    ++reboot_ordinal;
    ++report.stress.reboot_events;
    if ((reboot_ordinal & 1U) != 0U) {
      simulation.restart_ground();
    } else {
      vehicle_session = static_cast<std::uint16_t>(vehicle_session + 1U);
      simulation.restart_vehicle(vehicle_session, 0U);
    }

    const std::uint64_t grant_before = simulation.diagnostics().grant_rx;
    const std::uint64_t terminal_before =
        simulation.diagnostics().done_rx + simulation.diagnostics().idle_rx;
    const std::uint64_t recovery_target = reboot_at + 1U;
    const bool recovered =
        run_through_cycle(report, simulation, recovery_target);
    report.check(recovered, "reboot did not recover within two cycles");
    report.check(simulation.ground().session_id() ==
                     simulation.vehicle().session_id(),
                 "vehicle/ground session did not converge after reboot");
    report.check(simulation.diagnostics().grant_rx > grant_before,
                 "no valid GRANT was accepted after reboot");
    report.check(simulation.diagnostics().done_rx +
                         simulation.diagnostics().idle_rx >
                     terminal_before,
                 "no terminal control was received after reboot");
    if (recovered) {
      ++report.stress.recoveries;
      report.stress.max_recovery_cycles =
          std::max<std::uint64_t>(report.stress.max_recovery_cycles, 1U);
    }
  }
  if (report.passed) {
    report.check(run_through_cycle(report, simulation, kCycles),
                 "post-reboot observation period did not complete");
  }

  copy_simulation(report, simulation);
  report.check(report.cycles == kCycles,
               "periodic reboot scenario did not complete 1100 cycles");
  report.check(report.stress.reboot_events == 10U &&
                   report.stress.recoveries == 10U,
               "periodic reboot/recovery count is not 10/10");
  report.check(report.stress.max_recovery_cycles <= 2U,
               "a periodic reboot exceeded the two-cycle recovery limit");
  report.check(report.diagnostics.session_changes == 5U,
               "five vehicle session changes were not diagnosed");
  report.check(report.diagnostics.stale_sessions == 0U,
               "periodic reboot accepted or generated stale-session state");
  report.check(report.diagnostics.packet_loss_count == 0U &&
                   report.diagnostics.control_crc_errors == 0U,
               "reboot-only scenario injected an unrelated RF fault");
  check_common_invariants(report, simulation);
  report.detail =
      "Alternating Ground/Vehicle reboot every 100 cycles, ten events; "
      "each side must resynchronize within two cycles.";
}

void run_st_005(TestReport& report, std::uint32_t seed) {
  constexpr std::uint64_t kJitterCycles = 1'000U;
  TddConfig config{};
  RfMediumConfig rf_config{};
  TddSimulation simulation(config, rf_config, seed);
  DeterministicRandom random(seed ^ 0xA5A55A5AU);
  simulation.start(80U, 0U);
  std::uint32_t minimum_busy = 1'000U;
  std::uint32_t maximum_busy = 0U;

  for (std::uint64_t target = 1U; target <= kJitterCycles; ++target) {
    const std::uint32_t busy_ms = random.inclusive(400U, 1'000U);
    minimum_busy = std::min(minimum_busy, busy_ms);
    maximum_busy = std::max(maximum_busy, busy_ms);
    simulation.faults().busy_ground_on_grant_cycle =
        static_cast<int>(simulation.vehicle().cycle_id());
    simulation.faults().ground_aux_busy_ms = busy_ms;
    ++report.stress.aux_busy_events;
    simulation.queue_ground_bytes(32U);
    if (!run_one_cycle(report, simulation, target)) {
      break;
    }
    ++report.stress.recoveries;
    report.stress.max_recovery_cycles = 1U;
  }

  simulation.faults().busy_ground_on_grant_cycle = -1;
  std::uint64_t drain_target = simulation.stats().cycles_completed;
  while (report.passed && simulation.ground_queue_bytes() != 0U &&
         drain_target < kJitterCycles + 1'000U) {
    ++drain_target;
    if (!run_one_cycle(report, simulation, drain_target)) {
      break;
    }
  }

  copy_simulation(report, simulation);
  report.check(report.stress.aux_busy_events == kJitterCycles,
               "AUX jitter was not injected for 1000 cycles");
  report.check(report.stress.recoveries == kJitterCycles,
               "not every AUX Busy injection made bounded progress");
  report.check(minimum_busy >= 400U && maximum_busy <= 1'000U &&
                   minimum_busy < maximum_busy,
               "AUX jitter is outside the inclusive 400..1000 ms range");
  report.check(report.cycles >= kJitterCycles,
               "AUX jitter scenario did not complete all injection cycles");
  report.check(report.diagnostics.uplink_timeouts == 0U,
               "AUX jitter caused a deadlock/vehicle receive timeout");
  report.check(report.diagnostics.ground_usb_accepted_bytes == 32'000U &&
                   report.diagnostics.ground_usb_dequeued_bytes == 32'000U,
               "AUX jitter payload accounting is not 32000 bytes");
  report.check(report.diagnostics.ground_usb_dropped_bytes == 0U,
               "AUX jitter unexpectedly overflowed the Ground ring");
  report.check(simulation.stats().vehicle_payload_rx == 32'000U,
               "AUX jitter did not eventually deliver every accepted byte");
  report.check(simulation.ground_queue_bytes() == 0U,
               "AUX jitter queue did not drain after faults stopped");
  report.check(report.diagnostics.done_rx + report.diagnostics.idle_rx ==
                   report.cycles,
               "AUX jitter left a cycle without DONE/IDLE termination");
  report.check(report.diagnostics.packet_loss_count == 0U &&
                   report.diagnostics.control_crc_errors == 0U,
               "AUX jitter scenario injected an unrelated RF fault");
  check_common_invariants(report, simulation);
  report.detail =
      "1000 deterministic per-cycle Ground AUX Busy injections in the "
      "inclusive 400..1000 ms range, followed by a complete FIFO drain.";
}

void run_st_006(TestReport& report, std::uint32_t seed) {
  constexpr std::uint64_t kBurstDurationMs = 60'000U;
  constexpr std::uint64_t kIngressIntervalMs = 10U;
  constexpr std::uint32_t kIngressBytes = 115U;
  constexpr std::uint64_t kExpectedInputBytes =
      (kBurstDurationMs / kIngressIntervalMs) * kIngressBytes;
  TddConfig config{};
  RfMediumConfig rf_config{};
  TddSimulation simulation(config, rf_config, seed);
  simulation.start(90U, 0U);
  std::uint64_t last_checked_cycle = 0U;

  while (report.passed && simulation.now_ms() < kBurstDurationMs) {
    if (simulation.now_ms() % kIngressIntervalMs == 0U) {
      simulation.queue_ground_bytes(kIngressBytes);
    }
    simulation.step();
    if (simulation.stats().cycles_completed != last_checked_cycle) {
      last_checked_cycle = simulation.stats().cycles_completed;
      check_online_invariants(report, simulation);
    }
  }
  std::uint64_t drain_target = simulation.stats().cycles_completed;
  const std::uint64_t maximum_drain_target = drain_target + 512U;
  while (report.passed && simulation.ground_queue_bytes() != 0U &&
         drain_target < maximum_drain_target) {
    ++drain_target;
    if (!run_one_cycle(report, simulation, drain_target)) {
      break;
    }
  }

  copy_simulation(report, simulation);
  report.check(report.diagnostics.ground_usb_rx_bytes == kExpectedInputBytes,
               "continuous burst input byte count is not 690000");
  report.check(report.diagnostics.ground_usb_accepted_bytes +
                       report.diagnostics.ground_usb_dropped_bytes ==
                   report.diagnostics.ground_usb_rx_bytes,
               "continuous burst accepted/drop accounting is incomplete");
  report.check(report.diagnostics.ground_usb_dropped_bytes > 0U &&
                   report.diagnostics.ground_buffer_overflow_count > 0U,
               "continuous overload did not exercise defined drop-newest");
  report.check(report.diagnostics.max_ground_queue ==
                   kGroundUsbBufferCapacity,
               "continuous overload did not reach the fixed ring boundary");
  report.check(report.diagnostics.ground_usb_dequeued_bytes ==
                   report.diagnostics.ground_usb_accepted_bytes,
               "not every accepted burst byte was dequeued");
  report.check(simulation.stats().vehicle_payload_rx ==
                   report.diagnostics.ground_usb_accepted_bytes,
               "accepted burst bytes were lost or duplicated after drain");
  report.check(simulation.ground_queue_bytes() == 0U,
               "continuous burst queue did not drain");
  report.check(report.diagnostics.packet_loss_count == 0U &&
                   report.diagnostics.control_crc_errors == 0U,
               "continuous burst scenario injected an unrelated RF fault");
  check_common_invariants(report, simulation);
  report.detail =
      "115 bytes every 10 ms for 60 s (690000 bytes), then full drain; "
      "only explicitly counted drop-newest loss is permitted.";
}

}  // namespace

TestReport run_phase5_stress_test(const std::string& test_id,
                                  std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id == "ST-MAV-PHASE-001") {
    run_st_mav_phase_001(report, seed);
  } else if (test_id == "ST-MAV-001-Q1") {
    run_st_mav_001(report, seed, 1U);
  } else if (test_id == "ST-MAV-001") {
    run_st_mav_001(report, seed, 5U);
  } else if (test_id == "ST-001") {
    run_st_001(report, seed);
  } else if (test_id == "ST-002") {
    run_st_002(report, seed);
  } else if (test_id == "ST-003") {
    run_st_003(report, seed);
  } else if (test_id == "ST-004") {
    run_st_004(report, seed);
  } else if (test_id == "ST-005") {
    run_st_005(report, seed);
  } else if (test_id == "ST-006") {
    run_st_006(report, seed);
  } else {
    report.check(false, "unknown Phase 5 stress test ID");
  }
  return report;
}

}  // namespace vc_lora::test
