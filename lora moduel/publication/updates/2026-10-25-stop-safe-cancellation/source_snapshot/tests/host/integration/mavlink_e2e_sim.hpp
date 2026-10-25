#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <vector>

#include "e220_sim.hpp"
#include "rf_medium_sim.hpp"
#include "trace_recorder.hpp"
#include "vc_lora/byte_ring_buffer.hpp"
#include "vc_lora/link_diagnostics.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/mavlink_scheduler.hpp"
#include "vc_lora/tdd_ground.hpp"
#include "vc_lora/tdd_link_demux.hpp"
#include "vc_lora/tdd_vehicle.hpp"

namespace vc_lora::test {

constexpr std::size_t kMavlinkGroundBufferCapacity = 16U * 1024U;

struct TimedMavlinkFrame {
  MavlinkFrame frame{};
  std::uint64_t received_ms{0};
};

struct MavlinkHeartbeatGapPoint {
  std::uint64_t received_ms{0};
  std::uint64_t tx_start_ms{0};
  std::uint64_t tx_end_ms{0};
  std::uint64_t last_terminal_rx_ms{0};
  std::uint64_t wire_write_count{0};
  std::uint16_t cycle_id{0};
  std::uint8_t vehicle_state{0};
};

struct MavlinkE2eStats {
  std::uint64_t cycles_completed{0};
  std::uint64_t ground_data_writes{0};
  std::uint64_t vehicle_data_writes{0};
  std::uint64_t ground_application_bytes_tx{0};
  std::uint64_t vehicle_application_bytes_tx{0};
  std::uint64_t max_ground_wire_write{0};
  std::uint64_t max_vehicle_wire_write{0};
  std::uint64_t vehicle_frames_received{0};
  std::uint64_t ground_frames_received{0};
  std::uint64_t vehicle_frame_bytes_received{0};
  std::uint64_t ground_frame_bytes_received{0};
  std::uint64_t vehicle_stream_hash{0};
  std::uint64_t ground_stream_hash{0};
  std::uint64_t wire_write_count{0};
  std::uint64_t physical_write_oversize_count{0};
  std::uint64_t physical_write_gap_violations{0};
  std::uint64_t ground_window_overrun_count{0};
  std::size_t max_captured_vehicle_frames{0};
  std::size_t max_captured_ground_frames{0};
  std::size_t max_captured_wire_writes{0};
  std::size_t failure_context_pre_events{0};
  std::size_t failure_context_post_events{0};
  std::size_t max_failure_context_pre_events{0};
  std::size_t max_failure_context_trace_events{0};
  MavlinkHeartbeatGapPoint heartbeat_gap_before{};
  MavlinkHeartbeatGapPoint heartbeat_gap_after{};
};

struct MavlinkE2eCaptureConfig {
  bool frames{true};
  bool wire_writes{true};
  std::size_t failure_context_pre_events{0};
  std::size_t failure_context_post_events{0};
  std::uint64_t failure_heartbeat_gap_ms{0};
};

struct WireWriteRecord {
  NodeId sender{NodeId::Vehicle};
  bool control{false};
  std::uint64_t start_ms{0};
  std::uint64_t end_ms{0};
  std::uint64_t window_deadline_ms{0};
  std::size_t application_bytes{0};
  std::size_t wire_bytes{0};
  bool continuing_started_transaction{false};
};

class MavlinkE2eSimulation {
 public:
  MavlinkE2eSimulation(const TddConfig& tdd_config,
                       const RfMediumConfig& rf_config,
                       std::uint32_t seed,
                       MavlinkE2eCaptureConfig capture_config = {});

  void start(std::uint16_t session_id = 1U,
             std::uint16_t initial_cycle = 0U);
  void step();
  void step_event_driven(std::uint64_t quantum_ms = 5U);
  void run_for(std::uint64_t duration_ms);
  bool run_until_vehicle_frames(std::size_t count,
                                std::uint64_t timeout_ms);
  bool run_until_ground_frames(std::size_t count,
                               std::uint64_t timeout_ms);
  bool run_until_vehicle_parser_buffered(std::size_t minimum,
                                         std::uint64_t timeout_ms);
  bool run_until_ground_parser_buffered(std::size_t minimum,
                                        std::uint64_t timeout_ms);

  bool ingest_gcs_frame(const MavlinkFrame& frame) noexcept;
  std::size_t ingest_gcs_stream(const std::uint8_t* bytes,
                                std::size_t size) noexcept;
  bool ingest_pixhawk_frame(const MavlinkFrame& frame) noexcept;
  std::size_t ingest_pixhawk_stream(const std::uint8_t* bytes,
                                    std::size_t size) noexcept;

  std::uint64_t now_ms() const noexcept { return now_ms_; }
  std::uint64_t ground_data_write_count() const noexcept {
    return stats_.ground_data_writes;
  }
  std::size_t ground_queue_bytes() const noexcept {
    return ground_usb_buffer_.size();
  }
  std::size_t vehicle_queue_bytes() const noexcept {
    return vehicle_scheduler_.queued_bytes();
  }
  std::size_t vehicle_queue_frames() const noexcept {
    return vehicle_scheduler_.size();
  }
  std::size_t vehicle_parser_buffered_size() const noexcept {
    return vehicle_endpoint_parser_.buffered_size();
  }
  std::size_t ground_parser_buffered_size() const noexcept {
    return ground_endpoint_parser_.buffered_size();
  }

  const std::vector<TimedMavlinkFrame>& vehicle_frames() const noexcept {
    return vehicle_frames_;
  }
  const std::vector<TimedMavlinkFrame>& ground_frames() const noexcept {
    return ground_frames_;
  }
  const MavlinkE2eStats& stats() const noexcept { return stats_; }
  const std::vector<WireWriteRecord>& wire_writes() const noexcept {
    return wire_writes_;
  }
  const TraceRecorder& failure_context_trace() const noexcept {
    return failure_context_trace_;
  }
  bool failure_context_triggered() const noexcept {
    return failure_context_triggered_;
  }
  bool failure_context_complete() const noexcept {
    return failure_context_triggered_ && failure_context_post_remaining_ == 0U;
  }
  const LinkDiagnostics& diagnostics() const noexcept { return diagnostics_; }
  LinkDiagnostics& diagnostics() noexcept { return diagnostics_; }
  const VehicleTddController& vehicle() const noexcept { return vehicle_; }
  VehicleTddController& vehicle() noexcept { return vehicle_; }
  const GroundTddController& ground() const noexcept { return ground_; }
  GroundTddController& ground() noexcept { return ground_; }
  const RfMediumSim& medium() const noexcept { return medium_; }

 private:
  void deliver_radio();
  void deliver_one(const RfDelivery& delivery);
  void deliver_application_byte(NodeId receiver, std::uint8_t byte);
  void deliver_control(NodeId receiver, const DecodeEvent& event);
  void note_complete_frame(NodeId receiver, const MavlinkFrame& frame);
  void note_parser_status(MavlinkParseStatus status) noexcept;
  void process_vehicle_action(const LinkAction& action,
                              std::uint64_t now_ms);
  void process_ground_action(const LinkAction& action,
                             std::uint64_t now_ms);
  void record_wire_write(const WireWriteRecord& record);
  void record_context_event(NodeId node, const char* event,
                            std::uint64_t event_ms,
                            std::uint64_t radio_tx_bytes = 0U,
                            std::uint64_t radio_rx_bytes = 0U);
  void trigger_failure_context(std::uint64_t gap_ms);
  void record_state_cycle_changes();
  void sync_scheduler_diagnostics() noexcept;

  TddConfig config_{};
  LinkDiagnostics diagnostics_{};
  RfMediumSim medium_;
  E220Sim vehicle_radio_;
  E220Sim ground_radio_;
  VehicleTddController vehicle_;
  GroundTddController ground_;
  TddLinkDemux vehicle_demux_{true};
  TddLinkDemux ground_demux_{true};
  MavlinkFrameScheduler vehicle_scheduler_{};
  MavlinkStreamParser ground_ingress_parser_{};
  MavlinkStreamParser vehicle_endpoint_parser_{};
  MavlinkStreamParser ground_endpoint_parser_{};
  ByteRingBuffer<kMavlinkGroundBufferCapacity> ground_usb_buffer_{};
  std::vector<TimedMavlinkFrame> vehicle_frames_{};
  std::vector<TimedMavlinkFrame> ground_frames_{};
  std::vector<WireWriteRecord> wire_writes_{};
  std::deque<std::size_t> ground_frame_lengths_{};
  std::deque<TraceEvent> failure_context_pre_events_{};
  TraceRecorder failure_context_trace_{};
  MavlinkE2eStats stats_{};
  MavlinkE2eCaptureConfig capture_config_{};
  std::array<std::uint64_t, 2> previous_write_start_ms_{{0U, 0U}};
  std::array<bool, 2> have_previous_write_{{false, false}};
  std::uint64_t now_ms_{0};
  std::uint64_t ground_ingested_valid_frames_{0};
  std::uint64_t ground_ingested_valid_bytes_{0};
  std::uint64_t ground_queue_drop_frames_{0};
  std::uint64_t ground_queue_drop_bytes_{0};
  std::size_t max_ground_queued_frames_{0};
  std::uint64_t last_heartbeat_ms_{0};
  MavlinkHeartbeatGapPoint last_heartbeat_point_{};
  std::uint64_t last_vehicle_data_tx_start_ms_{0};
  std::uint64_t last_vehicle_data_tx_end_ms_{0};
  std::uint64_t last_terminal_rx_ms_{0};
  std::uint16_t last_vehicle_cycle_{0};
  std::uint16_t last_ground_cycle_{0};
  VehicleTddState last_vehicle_state_{VehicleTddState::DownlinkSend};
  GroundTddState last_ground_state_{GroundTddState::WaitGrant};
  std::size_t failure_context_post_remaining_{0};
  bool have_heartbeat_{false};
  bool failure_context_triggered_{false};
  bool started_{false};
};

}  // namespace vc_lora::test
