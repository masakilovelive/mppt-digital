#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

#include "e220_sim.hpp"
#include "trace_recorder.hpp"
#include "virtual_clock.hpp"
#include "vc_lora/byte_ring_buffer.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_ground.hpp"
#include "vc_lora/tdd_link_demux.hpp"
#include "vc_lora/tdd_vehicle.hpp"

namespace vc_lora::test {

constexpr std::size_t kGroundUsbBufferCapacity = 16U * 1024U;

struct ScenarioFaults {
  int drop_grant_cycle{-1};
  int drop_done_cycle{-1};
  int duplicate_grant_cycle{-1};
  int corrupt_grant_cycle{-1};
  int reset_ground_on_grant_cycle{-1};
  int busy_ground_on_grant_cycle{-1};
  int reject_ground_data_cycle{-1};
  std::uint32_t ground_aux_busy_ms{0};
};

struct SimulationStats {
  std::uint64_t cycles_completed{0};
  std::uint64_t ground_payload_tx{0};
  std::uint64_t vehicle_payload_tx{0};
  std::uint64_t vehicle_payload_rx{0};
  std::uint64_t ground_payload_rx{0};
  std::uint64_t vehicle_control_rx{0};
  std::uint64_t ground_control_rx{0};
  std::uint64_t first_grant_rx_ms{0};
  std::uint64_t first_ground_payload_tx_ms{0};
  std::uint64_t last_ground_payload_tx_ms{0};
  std::uint64_t ground_payload_rejected{0};
  std::uint64_t queue_bytes_after_rejected_tx{0};
  std::uint64_t max_ground_data_write_bytes{0};
};

class TddSimulation {
 public:
  TddSimulation(const TddConfig& tdd_config,
                const RfMediumConfig& rf_config, std::uint32_t seed,
                LocalClock vehicle_clock = {}, LocalClock ground_clock = {});

  void start(std::uint16_t session_id = 1,
             std::uint16_t initial_cycle = 0);
  void step();
  void run_for(std::uint64_t duration_ms);
  bool run_until_cycles(std::uint64_t cycles, std::uint64_t timeout_ms);
  bool run_until_cycles_event_driven(std::uint64_t target_cycles,
                                     std::uint64_t timeout_ms);
  bool run_until_grants(std::uint64_t grants, std::uint64_t timeout_ms);

  std::size_t ingest_ground_usb(const std::uint8_t* bytes,
                                std::size_t size) noexcept;
  void queue_ground_bytes(std::uint32_t bytes) noexcept;
  void queue_vehicle_bytes(std::uint32_t bytes) noexcept {
    vehicle_queue_bytes_ += bytes;
  }
  void set_vehicle_downlink_per_cycle(std::uint32_t bytes) noexcept {
    vehicle_downlink_per_cycle_ = bytes;
    if (started_) {
      vehicle_queue_bytes_ += bytes;
    }
  }
  void clear_ground_queue() noexcept;
  void restart_ground();
  void restart_vehicle(std::uint16_t new_session,
                       std::uint16_t initial_cycle = 0);
  ControlDisposition inject_ground_control(
      const TddControlMessage& message);

  ScenarioFaults& faults() noexcept { return faults_; }
  LinkDiagnostics& diagnostics() noexcept { return diagnostics_; }
  const LinkDiagnostics& diagnostics() const noexcept { return diagnostics_; }
  VehicleTddController& vehicle() noexcept { return vehicle_; }
  const VehicleTddController& vehicle() const noexcept { return vehicle_; }
  GroundTddController& ground() noexcept { return ground_; }
  const GroundTddController& ground() const noexcept { return ground_; }
  RfMediumSim& medium() noexcept { return medium_; }
  const RfMediumSim& medium() const noexcept { return medium_; }
  E220Sim& vehicle_radio() noexcept { return vehicle_radio_; }
  E220Sim& ground_radio() noexcept { return ground_radio_; }
  TraceRecorder& trace() noexcept { return trace_; }
  const TraceRecorder& trace() const noexcept { return trace_; }
  const SimulationStats& stats() const noexcept { return stats_; }
  std::uint64_t now_ms() const noexcept { return clock_.now_ms(); }
  std::uint32_t ground_queue_bytes() const noexcept {
    return static_cast<std::uint32_t>(ground_usb_buffer_.size());
  }
  std::uint32_t vehicle_queue_bytes() const noexcept {
    return vehicle_queue_bytes_;
  }

 private:
  void deliver_radio();
  void deliver_one(const RfDelivery& delivery);
  void process_vehicle_action(const LinkAction& action,
                              std::uint64_t vehicle_now);
  void process_ground_action(const LinkAction& action,
                             std::uint64_t ground_now);
  void record(const char* node, const char* state, std::uint16_t cycle,
              const std::string& event, bool aux_high,
              std::uint64_t queue_bytes, std::uint64_t tx_bytes,
              std::uint64_t rx_bytes);

  TddConfig config_{};
  LinkDiagnostics diagnostics_{};
  RfMediumSim medium_;
  E220Sim vehicle_radio_;
  E220Sim ground_radio_;
  VehicleTddController vehicle_;
  GroundTddController ground_;
  VirtualClock clock_{};
  LocalClock vehicle_clock_{};
  LocalClock ground_clock_{};
  TddLinkDemux vehicle_demux_{};
  TddLinkDemux ground_demux_{};
  TddControlStreamDecoder vehicle_local_leak_detector_{};
  TddControlStreamDecoder ground_local_leak_detector_{};
  TraceRecorder trace_{};
  ScenarioFaults faults_{};
  SimulationStats stats_{};
  ByteRingBuffer<kGroundUsbBufferCapacity> ground_usb_buffer_{};
  ByteRingBuffer<kGroundUsbBufferCapacity + kMaxSimFrameBytes>
      expected_vehicle_uplink_{};
  std::uint8_t next_ground_generated_byte_{0xA0U};
  std::uint32_t vehicle_queue_bytes_{0};
  std::uint32_t vehicle_downlink_per_cycle_{0};
  std::uint16_t last_vehicle_cycle_{0};
  VehicleTddState last_vehicle_state_{VehicleTddState::DownlinkSend};
  GroundTddState last_ground_state_{GroundTddState::WaitGrant};
  bool started_{false};
};

}  // namespace vc_lora::test
