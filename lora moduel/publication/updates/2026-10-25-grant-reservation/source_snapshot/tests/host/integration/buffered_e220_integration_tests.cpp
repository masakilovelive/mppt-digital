#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>

#include "fixtures/mavlink_fixtures.hpp"
#include "sim/e220_sim.hpp"
#include "sim/rf_medium_sim.hpp"
#include "vc_lora/embedded_io_adapter.hpp"
#include "vc_lora/late_uplink_recovery.hpp"
#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/mavlink_scheduler.hpp"
#include "vc_lora/runtime_contract.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_ground.hpp"
#include "vc_lora/tdd_link_demux.hpp"
#include "vc_lora/tdd_vehicle.hpp"
#include "vc_lora/tx_gate.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint16_t kSession = 0xB220U;
constexpr std::uint16_t kInitialCycle = 41U;
constexpr std::uint16_t kE220BufferBytes = 400U;
constexpr std::uint16_t kSubpacketBytes = 32U;
constexpr std::uint16_t kObservedAirServiceMs = 550U;
constexpr std::uint64_t kHeartbeatPeriodMs = 1'000U;
constexpr std::uint64_t kHeartbeatGapLimitMs = 2'500U;
constexpr std::uint64_t kUsbHeartbeatSupplyWindowMs = 6'200U;
constexpr std::uint64_t kScenarioDurationMs = 16'000U;
// Ten back-to-back downlink subpackets leave a measured-service RF tail in
// front of UL_GRANT.  Ground still admits exact-32 DATA and explicit DONE,
// but current production timing resumes downlink before both reach Vehicle.
constexpr std::uint16_t kDownlinkPacketsPerCycle = 10U;
constexpr std::uint16_t kPriorityOldParameterValues = 18U;
constexpr std::uint64_t kPriorityTargetDeadlineMs = 30'000U;
constexpr std::uint16_t kR2ParameterValues = 932U;
constexpr std::uint64_t kR2DeadlineScenarioDurationMs = 120'000U;

bool same_mavlink_wire(const MavlinkFrame& left,
                       const MavlinkFrame& right) noexcept {
  return left.size == right.size &&
         std::equal(left.bytes.begin(), left.bytes.begin() + left.size,
                    right.bytes.begin());
}

std::uint16_t parameter_value_index(const MavlinkFrame& frame) noexcept {
  if (frame.message_id != 22U || frame.payload_length != 25U) {
    return 0xFFFFU;
  }
  return static_cast<std::uint16_t>(frame.payload()[6U]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(frame.payload()[7U]) << 8U);
}

struct ScenarioStats {
  std::uint64_t ground_data_uart_admissions{0U};
  std::uint64_t ground_done_uart_admissions{0U};
  std::uint64_t request_data_air_bytes{0U};
  std::uint64_t request_receive_window_bytes{0U};
  std::uint64_t ground_done_air_arrivals{0U};
  std::uint64_t exact_request_commits{0U};
  std::uint64_t data_uart_ms{0U};
  std::uint64_t done_uart_ms{0U};
  std::uint64_t data_air_ms{0U};
  std::uint64_t done_air_ms{0U};
  std::uint64_t first_cycle_advance_ms{0U};
  std::uint64_t heartbeat_first_ms{0U};
  std::uint64_t heartbeat_last_ms{0U};
  std::uint64_t max_vehicle_buffered_bytes{0U};
  std::uint64_t max_ground_buffered_bytes{0U};
  std::uint64_t last_vehicle_air_completion_ms{0U};
  std::uint64_t last_ground_air_completion_ms{0U};
  std::uint64_t min_vehicle_air_completion_gap_ms{
      std::numeric_limits<std::uint64_t>::max()};
  std::uint64_t min_ground_air_completion_gap_ms{
      std::numeric_limits<std::uint64_t>::max()};
  std::uint64_t request_grant_air_end_ms{0U};
  std::uint64_t request_data_air_start_ms{0U};
  std::size_t max_vehicle_wire_write{0U};
  std::size_t max_ground_wire_write{0U};
  bool saw_uart_empty_while_air_buffered{false};
};

// This is the same write-completion composition used by phase6: an all-byte
// HardwareSerial acceptance commits the source/controller immediately, while
// radio_tx_empty remains false until the production E220WriteContract emits
// its one-shot completion. The buffered medium deliberately makes raw UART
// empty much earlier than that completion. Its 550-ms service begins after a
// modeled 3-ms UART fill, so a 550-ms admission floor permits a bounded 3-ms
// overlap of two queued subpackets (64 B); it does not claim the E220 buffer is
// completely empty at completion.
class ContractGatedE220 {
 public:
  ContractGatedE220(NodeId node, RfMediumSim& medium) noexcept
      : radio_(node, medium) {}

  void service(std::uint64_t now_ms) noexcept {
    (void)contract_.observe_aux(radio_.aux_high(now_ms), now_ms);
    if (contract_.fail_closed()) {
      fail_closed_ = true;
      return;
    }
    if (contract_.take_write_completion()) {
      if (!radio_busy_) {
        fail_closed_ = true;
        return;
      }
      radio_busy_ = false;
      ++completion_count_;
      last_completion_ms_ = now_ms;
    }
  }

  TxOutcome write(std::uint64_t now_ms, const std::uint8_t* bytes,
                  std::size_t size) {
    service(now_ms);
    if (!radio_tx_empty(now_ms) || !contract_.begin_write(size)) {
      return {};
    }

    const TxOutcome outcome = radio_.write(now_ms, bytes, size);
    const E220WriteDisposition disposition = contract_.report_write_result(
        outcome.accepted ? size : 0U, now_ms, radio_.aux_high(now_ms));
    if (disposition == E220WriteDisposition::AcceptedAll &&
        outcome.accepted) {
      radio_busy_ = true;
      ++admission_count_;
      last_admission_ms_ = now_ms;
      return outcome;
    }
    if (disposition == E220WriteDisposition::ContractViolation ||
        contract_.fail_closed()) {
      fail_closed_ = true;
    }
    return {};
  }

  bool radio_tx_empty(std::uint64_t now_ms) const noexcept {
    return radio_tx_complete() && radio_.tx_empty(now_ms);
  }
  // Physical completion of the previously accepted E220 write is a distinct
  // signal from capacity for a future write.  This mirrors phase6's
  // radio_tx_complete input and lets terminal drain close even if the next
  // 32-byte admission would still be unavailable.
  bool radio_tx_complete() const noexcept {
    return !radio_busy_ && !fail_closed_ && contract_.ready_for_write();
  }
  bool aux_high(std::uint64_t now_ms) const noexcept {
    return radio_.aux_high(now_ms);
  }
  bool raw_uart_empty(std::uint64_t now_ms) const noexcept {
    return radio_.tx_empty(now_ms);
  }
  bool fail_closed() const noexcept {
    return fail_closed_ || contract_.fail_closed();
  }
  std::uint64_t admission_count() const noexcept { return admission_count_; }
  std::uint64_t completion_count() const noexcept {
    return completion_count_;
  }
  std::uint64_t last_admission_ms() const noexcept {
    return last_admission_ms_;
  }
  std::uint64_t last_completion_ms() const noexcept {
    return last_completion_ms_;
  }

 private:
  E220Sim radio_;
  E220WriteContract contract_{};
  bool radio_busy_{false};
  bool fail_closed_{false};
  std::uint64_t admission_count_{0U};
  std::uint64_t completion_count_{0U};
  std::uint64_t last_admission_ms_{0U};
  std::uint64_t last_completion_ms_{0U};
};

class BufferedE220UplinkScenario {
 public:
  explicit BufferedE220UplinkScenario(
      std::uint32_t seed, bool parameter_priority_mode = false,
      bool r2_deadline_mode = false)
      : medium_(rf_config_, seed, diagnostics_),
        vehicle_radio_(NodeId::Vehicle, medium_),
        ground_radio_(NodeId::Ground, medium_),
        vehicle_(tdd_config_, diagnostics_),
        ground_(tdd_config_, diagnostics_),
        parameter_priority_mode_(parameter_priority_mode || r2_deadline_mode),
        r2_deadline_mode_(r2_deadline_mode) {
    request_ = fixtures::param_request_read_v2(
        0x71U, "SERIAL1_BAUD");
    request_wire_ = encode_link_data(request_.bytes.data(), request_.size,
                                     kSubpacketBytes);
    target_response_ = fixtures::param_value_v2(
        0xE0U, "SERIAL1_BAUD", 57.0F, 0xFFFFU, 932U, 6U);
    if (parameter_priority_mode_) {
      downlink_packets_remaining_ = 0U;
    }
  }

  void run(TestReport& report, bool require_rf_heartbeat_limit) {
    report.check(rf_config_.uart_buffer_bytes == kE220BufferBytes &&
                     rf_config_.sub_packet_bytes == kSubpacketBytes &&
                     rf_config_.buffered_air_subpacket_service_ms ==
                         kObservedAirServiceMs,
                 "buffered E220 assumptions changed from 400B/32B/550ms");
    report.check(request_.message_id == 20U && request_.size == 32U &&
                     request_wire_.input_consumed == request_.size &&
                     request_wire_.wire_size == kSubpacketBytes,
                 "SERIAL1_BAUD fixture is not one exact-32 #20 subpacket");

    vehicle_.reset(kSession, kInitialCycle, 0U);
    ground_.reset(0U);
    request_origin_ms_ = now_ms_;
    last_vehicle_cycle_ = vehicle_.cycle_id();
    record(report, "vehicle", "RESET", 0U, 0U);
    record(report, "ground", "RESET", 0U, 0U);

    const std::uint64_t scenario_duration_ms =
        r2_deadline_mode_
            ? kR2DeadlineScenarioDurationMs
            : (parameter_priority_mode_ ? 600'000U : kScenarioDurationMs);
    for (now_ms_ = 0U; now_ms_ < scenario_duration_ms; ++now_ms_) {
      medium_.advance(now_ms_);
      deliver_all(report);
      vehicle_radio_.service(now_ms_);
      ground_radio_.service(now_ms_);
      update_radio_observations();

      if (r2_deadline_mode_ && protected_heartbeat_air_ms_ > 0U &&
          diagnostics_.idle_rx == 1U) {
        scenario_completed_ = true;
        break;
      }
      if (!r2_deadline_mode_ && parameter_priority_mode_ &&
          target_ground_count_ == 1U &&
          old_parameter_count_ == kPriorityOldParameterValues &&
          old_parameter_drain_ms_ > 0U &&
          last_rf_heartbeat_ms_ > old_parameter_drain_ms_) {
        scenario_completed_ = true;
        break;
      }

      if (parameter_priority_seeded_) {
        while (next_priority_heartbeat_ms_ <= now_ms_) {
          if (r2_deadline_mode_ &&
              r2_heartbeat_sources_enqueued_ >= 5U) {
            next_priority_heartbeat_ms_ =
                std::numeric_limits<std::uint64_t>::max();
            break;
          }
          const MavlinkEnqueueStatus heartbeat_status =
              vehicle_scheduler_.enqueue(
                  fixtures::heartbeat_v2(priority_heartbeat_sequence_++),
                  next_priority_heartbeat_ms_);
          report.check(heartbeat_status == MavlinkEnqueueStatus::Queued,
                       "1-Hz Pixhawk heartbeat overflowed the production "
                       "priority integration fixture");
          if (r2_deadline_mode_ &&
              heartbeat_status == MavlinkEnqueueStatus::Queued) {
            ++r2_heartbeat_sources_enqueued_;
          }
          next_priority_heartbeat_ms_ += kHeartbeatPeriodMs;
        }
      }

      // Reproduce the bounded race that the absolute deadline must resolve:
      // five ordinary 1-Hz samples have drained, the controller has closed
      // admission, but a sixth heartbeat becomes visible before UL_GRANT is
      // issued.  Current production ignores it in DownlinkDrain and grants;
      // the fixed controller must return to downlink, finish this heartbeat,
      // then grant.  No future heartbeat knowledge is part of this fixture.
      if (r2_deadline_mode_ && parameter_priority_seeded_ &&
          !deadline_heartbeat_enqueued_ &&
          r2_heartbeat_sources_enqueued_ == 5U &&
          vehicle_.state() == VehicleTddState::DownlinkDrain) {
        const MavlinkFrame deadline_heartbeat =
            fixtures::heartbeat_v2(priority_heartbeat_sequence_++);
        const MavlinkEnqueueStatus heartbeat_status =
            vehicle_scheduler_.enqueue(deadline_heartbeat, now_ms_);
        report.check(heartbeat_status == MavlinkEnqueueStatus::Queued,
                     "R2 deadline heartbeat did not enter the scheduler in "
                     "DownlinkDrain");
        if (heartbeat_status == MavlinkEnqueueStatus::Queued) {
          deadline_heartbeat_enqueued_ = true;
          deadline_heartbeat_source_ms_ = now_ms_;
          deadline_heartbeat_sequence_ = deadline_heartbeat.sequence;
          ++r2_heartbeat_sources_enqueued_;
          record(report, "vehicle", "R2_ENQUEUE_DEADLINE_HEARTBEAT", 0U,
                 deadline_heartbeat.size);
        }
      }

      TddInput vehicle_input{
          now_ms_, vehicle_radio_.aux_high(now_ms_),
          vehicle_radio_.radio_tx_empty(now_ms_),
          parameter_priority_mode_ ? !vehicle_scheduler_.has_active_frame()
                                   : true,
          parameter_priority_mode_
              ? static_cast<std::uint32_t>(vehicle_scheduler_.queued_bytes())
              : (downlink_packets_remaining_ > 0U ? kSubpacketBytes : 0U)};
      vehicle_input.radio_tx_complete =
          vehicle_radio_.radio_tx_complete();
      if (parameter_priority_mode_) {
        const MavlinkHeartbeatCandidate heartbeat =
            vehicle_scheduler_.heartbeat_candidate();
        vehicle_input.heartbeat_tail_enabled =
            vehicle_scheduler_.has_seen_heartbeat();
        vehicle_input.heartbeat_tail_available =
            heartbeat.tail_available;
        vehicle_input.heartbeat_tail_active = heartbeat.active;
        vehicle_input.heartbeat_tail_active_started =
            heartbeat.active_started;
        if (heartbeat.present && heartbeat.tail_available) {
          vehicle_input.heartbeat_deadline_valid = true;
          vehicle_input.heartbeat_order = heartbeat.order;
          vehicle_input.heartbeat_enqueued_ms = heartbeat.enqueued_ms;
          vehicle_input.heartbeat_deadline_ms =
              heartbeat.enqueued_ms + kHeartbeatGapLimitMs;
        }
      }
      process_vehicle(vehicle_.tick(vehicle_input), report);

      TddInput ground_input{};
      ground_input.now_ms = now_ms_;
      ground_input.aux_high = ground_radio_.aux_high(now_ms_);
      ground_input.radio_tx_empty = ground_radio_.radio_tx_empty(now_ms_);
      ground_input.radio_tx_complete =
          ground_radio_.radio_tx_complete();
      ground_input.local_tx_empty = true;
      if (request_pending_) {
        ground_input.queued_bytes = static_cast<std::uint32_t>(request_.size);
        ground_input.next_tx_application_bytes =
            static_cast<std::uint16_t>(request_.size);
        ground_input.next_tx_wire_bytes =
            static_cast<std::uint16_t>(request_wire_.wire_size);
        ground_input.front_frame_bytes =
            static_cast<std::uint16_t>(request_.size);
      }
      process_ground(ground_.tick(ground_input), report);

      if (vehicle_.cycle_id() != last_vehicle_cycle_) {
        last_vehicle_cycle_ = vehicle_.cycle_id();
        downlink_packets_remaining_ = kDownlinkPacketsPerCycle;
        if (stats_.first_cycle_advance_ms == 0U) {
          stats_.first_cycle_advance_ms = now_ms_;
        }
        record(report, "vehicle", "NEXT_CYCLE", 0U, 0U);
      }
    }

    if (r2_deadline_mode_) {
      validate_r2_deadline(report);
      return;
    }
    if (parameter_priority_mode_) {
      validate_parameter_priority(report);
      return;
    }

    report.check(stats_.saw_uart_empty_while_air_buffered,
                 "test model did not separate UART/AUX admission from air");
    report.check(!vehicle_radio_.fail_closed() &&
                     !ground_radio_.fail_closed(),
                 "production E220WriteContract failed closed in the "
                 "buffered model");
    report.check(stats_.max_vehicle_buffered_bytes <= kE220BufferBytes &&
                     stats_.max_ground_buffered_bytes <= kE220BufferBytes,
                 "test model exceeded the configured 400-byte E220 buffer");
    report.check(stats_.max_vehicle_buffered_bytes <= 64U &&
                     stats_.max_ground_buffered_bytes <= 64U,
                 "550-ms production pacing accumulated more than two E220 "
                 "subpackets");
    report.check(stats_.ground_data_uart_admissions == 1U &&
                     stats_.ground_done_uart_admissions == 1U,
                 "Ground did not UART-admit exact-32 #20 plus explicit DONE");
    report.check(stats_.request_data_air_bytes == request_.size &&
                     stats_.ground_done_air_arrivals == 1U,
                 "buffered model did not complete #20/DONE over-air service");

    // Production transport invariant: the 550-ms E220WriteContract gate must
    // keep the DATA/DONE RF tail inside the same Vehicle receive transaction.
    report.check(stats_.exact_request_commits == 1U,
                 "buffered E220 RF tail lost exact-32 #20/DONE after UART "
                 "admission");
    report.check(diagnostics_.uplink_timeouts == 0U &&
                     diagnostics_.collision_count == 0U &&
                     diagnostics_.half_duplex_drop_count == 0U &&
                     diagnostics_.uplink_data_outside_receive_window == 0U,
                 "production timing overlapped the buffered uplink RF tail");
    report.check(
        stats_.min_vehicle_air_completion_gap_ms >=
                FixedFirmwareContract::e220_subpacket_service_floor_ms &&
            stats_.min_ground_air_completion_gap_ms >=
                FixedFirmwareContract::e220_subpacket_service_floor_ms,
        "same-direction remote completions violated the 550-ms service "
        "spacing floor");
    report.check(
        stats_.request_data_air_start_ms >=
                stats_.request_grant_air_end_ms &&
            stats_.request_data_air_start_ms -
                    stats_.request_grant_air_end_ms >=
                FixedFirmwareContract::uplink_guard_ms - 3U,
        "effective Vehicle-to-Ground direction turnaround fell below 647 "
        "ms");
    if (require_rf_heartbeat_limit) {
      report.check(diagnostics_.heartbeat_valid >= 2U &&
                       diagnostics_.heartbeat_max_gap_ms <=
                           kHeartbeatGapLimitMs,
                   "RF-schedule heartbeat remains above 2500 ms; this RED "
                   "is closed only by the separate Ground USB real-frame "
                   "pacer contract");
    }

    report.diagnostics = diagnostics_;
    report.cycles = static_cast<std::uint64_t>(
        static_cast<std::uint16_t>(vehicle_.cycle_id() - kInitialCycle));
    report.vehicle_session = vehicle_.session_id();
    report.ground_session = ground_.session_id();
    report.vehicle_cycle = vehicle_.cycle_id();
    report.ground_cycle = ground_.cycle_id();
    report.final_vehicle_state = vehicle_state_name(vehicle_.state());
    report.final_ground_state = ground_state_name(ground_.state());
    report.stress.heartbeat_gap_before_rx_ms = stats_.heartbeat_first_ms;
    report.stress.heartbeat_gap_after_rx_ms = stats_.heartbeat_last_ms;
    report.stress.rf_retained_transmissions =
        medium_.retained_transmission_count();
    report.stress.rf_max_retained_transmissions =
        medium_.max_retained_transmission_count();
    report.detail =
        "test-only E220 model: UART=115200, internal=400B, subpacket=32B, "
        "observed air service=550ms; production write-gate completions=" +
        std::to_string(vehicle_radio_.completion_count()) + "/" +
        std::to_string(ground_radio_.completion_count()) +
        ", Ground DATA/DONE UART admissions=" +
        std::to_string(stats_.ground_data_uart_admissions) + "/" +
        std::to_string(stats_.ground_done_uart_admissions) +
        ", request air/window bytes=" +
        std::to_string(stats_.request_data_air_bytes) + "/" +
        std::to_string(stats_.request_receive_window_bytes) +
        ", exact commits=" +
        std::to_string(stats_.exact_request_commits) +
        ", times UART(data/done)=" +
        std::to_string(stats_.data_uart_ms) + "/" +
        std::to_string(stats_.done_uart_ms) +
        "ms AIR(data/done)/cycle-next=" +
        std::to_string(stats_.data_air_ms) + "/" +
        std::to_string(stats_.done_air_ms) + "/" +
        std::to_string(stats_.first_cycle_advance_ms) +
        "ms, max buffered V/G=" +
        std::to_string(stats_.max_vehicle_buffered_bytes) + "/" +
        std::to_string(stats_.max_ground_buffered_bytes) +
        "B, min remote completion gap V/G=" +
        std::to_string(stats_.min_vehicle_air_completion_gap_ms) + "/" +
        std::to_string(stats_.min_ground_air_completion_gap_ms) +
        "ms, reverse quiet=" +
        std::to_string(stats_.request_data_air_start_ms -
                       stats_.request_grant_air_end_ms) +
        "ms, HB max gap=" +
        std::to_string(diagnostics_.heartbeat_max_gap_ms) + "ms";
  }

 private:
  static RfMediumConfig make_rf_config() noexcept {
    RfMediumConfig config{};
    config.uart_rate_bps = 115'200U;
    config.air_rate_bps = 19'200U;
    config.sub_packet_bytes = kSubpacketBytes;
    config.min_tx_gap_ms = 180U;
    config.turnaround_ms = 0U;
    config.uart_buffer_bytes = kE220BufferBytes;
    config.buffered_air_subpacket_service_ms = kObservedAirServiceMs;
    return config;
  }

  void seed_parameter_priority_downlink(TestReport& report) {
    report.check(!parameter_priority_seeded_,
                 "priority response fixture was seeded more than once");
    const std::uint16_t backlog_count =
        r2_deadline_mode_ ? kR2ParameterValues
                          : kPriorityOldParameterValues;
    for (std::uint16_t index = 0U; index < backlog_count; ++index) {
      const MavlinkFrame old = fixtures::param_value_v2(
          static_cast<std::uint8_t>(0xA0U + index),
          r2_deadline_mode_ ? "R2_BACKLOG" : "OLD_BACKLOG",
          static_cast<float>(index), index,
          r2_deadline_mode_ ? kR2ParameterValues : 512U,
          r2_deadline_mode_ ? 6U : 9U);
      if (!r2_deadline_mode_) {
        old_parameter_expected_[index] = old;
      }
      report.check(vehicle_scheduler_.enqueue(old, now_ms_) ==
                       MavlinkEnqueueStatus::Queued,
                   "PARAM_VALUE did not enter the generic FIFO");
    }
    if (r2_deadline_mode_) {
      r2_seeded_parameter_frames_ =
          vehicle_scheduler_.parameter_download_queued_frames();
      r2_seeded_parameter_bytes_ = vehicle_scheduler_.queued_bytes();
      report.check(r2_seeded_parameter_frames_ == kR2ParameterValues &&
                       r2_seeded_parameter_bytes_ ==
                           static_cast<std::size_t>(kR2ParameterValues) *
                               37U,
                   "R2 did not seed the exact 932-frame/34484-byte #22 "
                   "backlog");
    }
    report.check(vehicle_scheduler_.enqueue(target_response_, now_ms_) ==
                     MavlinkEnqueueStatus::Queued,
                 "matching PARAM_VALUE did not enter the target lane");
    if (r2_deadline_mode_) {
      report.check(vehicle_scheduler_.prioritized_parameter_values() == 1U &&
                       vehicle_scheduler_.parameter_download_queued_frames() ==
                           kR2ParameterValues,
                   "target lane changed the R2 generic #22 backlog");
    }
    parameter_priority_seeded_ = true;
    target_enqueued_ms_ = now_ms_;
    next_priority_heartbeat_ms_ = now_ms_;
  }

  void note_parameter_value_at_ground(const MavlinkFrame& frame,
                                      TestReport& report) {
    if (same_mavlink_wire(frame, target_response_)) {
      ++target_ground_count_;
      if (target_ground_ms_ == 0U) {
        target_ground_ms_ = now_ms_;
      }
      report.check(target_ground_count_ == 1U,
                   "matching target reached Ground more than once");
      return;
    }
    if (r2_deadline_mode_) {
      const std::uint8_t* payload = frame.payload();
      const std::uint16_t count = static_cast<std::uint16_t>(payload[4U]) |
                                  static_cast<std::uint16_t>(
                                      static_cast<std::uint16_t>(payload[5U])
                                      << 8U);
      const std::uint16_t index = parameter_value_index(frame);
      report.check(frame.system_id == 1U && frame.component_id == 1U &&
                       frame.payload_length == 25U &&
                       count == kR2ParameterValues && payload[24U] == 6U,
                   "R2 Ground #22 identity/count/type changed");
      report.check(index == r2_parameter_count_,
                   "R2 Ground #22 prefix was duplicated or out of order");
      if (index == r2_parameter_count_) {
        ++r2_parameter_count_;
      }
      return;
    }
    report.check(old_parameter_count_ < old_parameter_order_.size(),
                 "Ground received more than 18 old PARAM_VALUE frames");
    if (old_parameter_count_ < old_parameter_order_.size()) {
      report.check(
          same_mavlink_wire(frame,
                            old_parameter_expected_[old_parameter_count_]),
          "actual Ground old PARAM_VALUE FIFO was not byte-exact");
      old_parameter_order_[old_parameter_count_++] =
          parameter_value_index(frame);
      if (old_parameter_count_ == old_parameter_order_.size()) {
        old_parameter_drain_ms_ = now_ms_;
      }
    }
  }

  void validate_parameter_priority(TestReport& report) {
    report.check(target_response_.message_id == 22U &&
                     target_response_.payload_length == 25U &&
                     target_response_.payload()[4U] == 0xA4U &&
                     target_response_.payload()[5U] == 0x03U &&
                     parameter_value_index(target_response_) == 0xFFFFU &&
                     target_response_.payload()[24U] == 6U,
                 "target fixture is not SERIAL1_BAUD count=932/index=-1/"
                 "type=6");
    report.check(scenario_completed_,
                 "buffered target/HB scenario did not reach its terminal "
                 "evidence point");
    report.check(stats_.exact_request_commits == 1U &&
                     request_remembered_count_ == 1U &&
                     d6_egress_.queued_bytes() == request_.size &&
                     d6_egress_.stats().bytes_committed == 0U,
                 "#20 was not admitted to D6 then remembered exactly once");
    report.check(target_ground_count_ == 1U && target_ground_ms_ >=
                                                    request_origin_ms_ &&
                     target_ground_ms_ - request_origin_ms_ <
                         kPriorityTargetDeadlineMs,
                 "request-origin to matching Ground PARAM_VALUE was not "
                 "exact-once within 30 seconds");
    const std::uint64_t target_era_heartbeat_gap_ms =
        heartbeat_receive_count_ >= 2U
            ? heartbeat_receive_ms_[1U] - heartbeat_receive_ms_[0U]
            : kPriorityTargetDeadlineMs + 1U;
    report.check(heartbeat_receive_count_ >= 2U &&
                     target_era_heartbeat_gap_ms <= kHeartbeatGapLimitMs,
                 "target-era RF heartbeat fairness exceeded 2500 ms");
    report.check(heartbeat_receive_count_ >= 4U &&
                     heartbeat_supply_window_checks_ ==
                         heartbeat_receive_count_ - 3U &&
                     last_rf_heartbeat_ms_ > old_parameter_drain_ms_,
                 "actual RF heartbeat supply did not cover warm-up through "
                 "the post-backlog tail");
    report.check(old_parameter_count_ == kPriorityOldParameterValues,
                 "Ground did not physically receive every old PARAM_VALUE");
    for (std::size_t index = 0U;
         index < std::min(old_parameter_count_, old_parameter_order_.size());
         ++index) {
      report.check(old_parameter_order_[index] ==
                       static_cast<std::uint16_t>(index),
                   "actual Ground old PARAM_VALUE FIFO order changed");
    }

    const MavlinkSchedulerDiagnostics& scheduler_diagnostics =
        vehicle_scheduler_.diagnostics();
    report.check(vehicle_scheduler_.pending_parameter_requests() == 0U &&
                     scheduler_diagnostics.parameter_requests_remembered ==
                         1U &&
                     scheduler_diagnostics.target_parameter_frames_queued ==
                         1U &&
                     scheduler_diagnostics.target_parameter_frames_completed ==
                         1U &&
                     scheduler_diagnostics.queue_drop_frames == 0U &&
                     scheduler_diagnostics.queue_drop_bytes == 0U,
                 "scheduler ownership/drop diagnostics are not exact");
    report.check(!vehicle_radio_.fail_closed() &&
                     !ground_radio_.fail_closed() &&
                     diagnostics_.tx_gate_violation == 0U &&
                     diagnostics_.tx_during_rx_window_count == 0U &&
                     diagnostics_.ground_tx_without_valid_grant == 0U &&
                     diagnostics_.collision_count == 0U &&
                     diagnostics_.packet_loss_count == 0U &&
                     diagnostics_.turnaround_drop_count == 0U &&
                     diagnostics_.half_duplex_drop_count == 0U &&
                     diagnostics_.uart_buffer_drop_count == 0U &&
                     diagnostics_.uplink_data_outside_receive_window == 0U &&
                     diagnostics_.uplink_timeouts == 0U &&
                     diagnostics_.expired_windows == 0U &&
                     diagnostics_.insufficient_window_count == 0U &&
                     diagnostics_.action_retries == 0U &&
                     diagnostics_.abandoned_uplink_transactions == 0U &&
                     diagnostics_.duplicate_grants == 0U &&
                     diagnostics_.stale_cycles == 0U &&
                     diagnostics_.future_cycles == 0U &&
                     diagnostics_.stale_sessions == 0U &&
                     diagnostics_.session_changes == 0U &&
                     diagnostics_.invalid_done == 0U &&
                     diagnostics_.control_crc_errors == 0U &&
                     diagnostics_.control_unknown_version == 0U &&
                     diagnostics_.control_unknown_type == 0U &&
                     diagnostics_.control_malformed == 0U &&
                     diagnostics_.invalid_crc_state_transition == 0U &&
                     diagnostics_.partial_mavlink_delivered == 0U &&
                     diagnostics_.mavlink_crc_errors == 0U &&
                     diagnostics_.mavlink_parser_resets == 0U &&
                     diagnostics_.mavlink_queue_drop_frames == 0U &&
                     diagnostics_.mavlink_queue_drop_bytes == 0U &&
                     diagnostics_.ground_buffer_overflow_count == 0U &&
                     diagnostics_.ground_payload_order_errors == 0U &&
                     diagnostics_.ground_queue_underflow_count == 0U &&
                     diagnostics_.control_bytes_leaked_to_local_uart == 0U,
                 "actual TDD/RF path reported a gate, drop, or collision");
    report.check(rf_config_.buffered_air_subpacket_service_ms ==
                         FixedFirmwareContract::
                             e220_subpacket_service_floor_ms &&
                     vehicle_radio_.admission_count() > 0U &&
                     ground_radio_.admission_count() >= 2U,
                 "test bypassed the ContractGatedE220 550-ms service path");
    report.check(stats_.max_vehicle_buffered_bytes <= 64U &&
                     stats_.max_ground_buffered_bytes <= 64U &&
                     stats_.min_vehicle_air_completion_gap_ms !=
                         std::numeric_limits<std::uint64_t>::max() &&
                     stats_.min_ground_air_completion_gap_ms !=
                         std::numeric_limits<std::uint64_t>::max() &&
                     stats_.min_vehicle_air_completion_gap_ms >=
                         FixedFirmwareContract::
                             e220_subpacket_service_floor_ms &&
                     stats_.min_ground_air_completion_gap_ms >=
                         FixedFirmwareContract::
                             e220_subpacket_service_floor_ms &&
                     stats_.ground_data_uart_admissions == 1U &&
                     stats_.ground_done_uart_admissions == 1U &&
                     stats_.request_data_air_bytes == request_.size &&
                     stats_.request_receive_window_bytes == request_.size &&
                     stats_.max_vehicle_wire_write <= kSubpacketBytes &&
                     stats_.max_ground_wire_write <= kSubpacketBytes,
                 "buffer/service-floor/request/wire production bounds "
                 "were not exercised exactly");
    report.check(
        stats_.request_grant_air_end_ms > 0U &&
            stats_.request_data_air_start_ms > 0U &&
            stats_.request_data_air_start_ms >=
                stats_.request_grant_air_end_ms &&
            stats_.request_data_air_start_ms -
                    stats_.request_grant_air_end_ms >=
                FixedFirmwareContract::uplink_guard_ms - 3U,
        "priority fixture direction reversal fell below the explicit "
        "647-ms receive guard");

    report.diagnostics = diagnostics_;
    report.cycles = static_cast<std::uint64_t>(
        static_cast<std::uint16_t>(vehicle_.cycle_id() - kInitialCycle));
    report.vehicle_session = vehicle_.session_id();
    report.ground_session = ground_.session_id();
    report.vehicle_cycle = vehicle_.cycle_id();
    report.ground_cycle = ground_.cycle_id();
    report.final_vehicle_state = vehicle_state_name(vehicle_.state());
    report.final_ground_state = ground_state_name(ground_.state());
    report.detail =
        "actual Vehicle/Ground TDD + RfMedium + ContractGatedE220(550ms): "
        "#20 D6 admission/remember=1, R0-to-target=" +
        std::to_string(target_ground_ms_ - request_origin_ms_) +
        "ms (D6-to-target=" +
        std::to_string(target_ground_ms_ - target_enqueued_ms_) +
        "ms), Ground target=1, target-era RF HB gap=" +
        std::to_string(target_era_heartbeat_gap_ms) +
        "ms, full-run RF HB max gap=" +
        std::to_string(max_rf_heartbeat_gap_ms_) +
        "ms, max RF four-arrival span=" +
        std::to_string(max_heartbeat_supply_span_ms_) +
        "ms across " +
        std::to_string(heartbeat_supply_window_checks_) +
        " rolling supply checks, actual Ground old generic FIFO=18 "
        "byte-exact order, max "
        "buffered V/G=" +
        std::to_string(stats_.max_vehicle_buffered_bytes) + "/" +
        std::to_string(stats_.max_ground_buffered_bytes) +
        "B, min remote completion gap V/G=" +
        std::to_string(stats_.min_vehicle_air_completion_gap_ms) + "/" +
        std::to_string(stats_.min_ground_air_completion_gap_ms) +
        "ms, reverse quiet=" +
        std::to_string(stats_.request_data_air_start_ms -
                       stats_.request_grant_air_end_ms) +
        "ms, max wire V/G=" +
        std::to_string(stats_.max_vehicle_wire_write) + "/" +
        std::to_string(stats_.max_ground_wire_write) +
        "B, all gate/drop/timeout/CRC/parser diagnostics=0";
  }

  void validate_r2_deadline(TestReport& report) {
    const MavlinkSchedulerDiagnostics& scheduler_diagnostics =
        vehicle_scheduler_.diagnostics();
    report.check(scenario_completed_ && deadline_heartbeat_enqueued_ &&
                     r2_heartbeat_sources_enqueued_ == 6U &&
                     diagnostics_.uplink_timeouts == 0U &&
                     diagnostics_.done_tx == 1U &&
                     diagnostics_.done_rx == 1U &&
                     diagnostics_.idle_tx == 1U &&
                     diagnostics_.idle_rx == 1U,
                 "R2 did not keep normal UL_DONE/UL_IDLE terminal handling");
    report.check(r2_seeded_parameter_frames_ == kR2ParameterValues &&
                     r2_seeded_parameter_bytes_ ==
                         static_cast<std::size_t>(kR2ParameterValues) * 37U,
                 "R2 did not seed the exact 932-frame/34484-byte #22 "
                 "backlog");
    report.check(stats_.exact_request_commits == 1U &&
                     request_remembered_count_ == 1U &&
                     target_ground_count_ == 1U,
                 "R2 changed exact-once request/target handling");
    report.check(scheduler_diagnostics.queue_drop_frames == 0U &&
                     scheduler_diagnostics.queue_drop_bytes == 0U &&
                     scheduler_diagnostics.invalid_frames == 0U &&
                     diagnostics_.mavlink_crc_errors == 0U &&
                     diagnostics_.partial_mavlink_delivered == 0U &&
                     diagnostics_.ground_payload_order_errors == 0U &&
                     diagnostics_.ground_queue_underflow_count == 0U,
                 "R2 deadline path corrupted, dropped, or reordered a "
                 "complete MAVLink frame");
    report.check(stats_.max_vehicle_wire_write <= kSubpacketBytes &&
                     stats_.max_ground_wire_write <= kSubpacketBytes &&
                     stats_.max_vehicle_buffered_bytes <= 64U &&
                     stats_.max_ground_buffered_bytes <= 64U &&
                     stats_.min_vehicle_air_completion_gap_ms >=
                         FixedFirmwareContract::
                             e220_subpacket_service_floor_ms &&
                     stats_.min_ground_air_completion_gap_ms >=
                         FixedFirmwareContract::
                             e220_subpacket_service_floor_ms,
                 "R2 bypassed the fixed 32-byte/550-ms E220 contract");
    report.check(stats_.request_grant_air_end_ms > 0U &&
                     stats_.request_data_air_start_ms >=
                         stats_.request_grant_air_end_ms &&
                     stats_.request_data_air_start_ms -
                             stats_.request_grant_air_end_ms >=
                         FixedFirmwareContract::uplink_guard_ms - 3U,
                 "R2 changed the fixed 650-ms direction guard");
    report.check(diagnostics_.tx_gate_violation == 0U &&
                     diagnostics_.tx_during_rx_window_count == 0U &&
                     diagnostics_.ground_tx_without_valid_grant == 0U &&
                     diagnostics_.collision_count == 0U &&
                     diagnostics_.packet_loss_count == 0U &&
                     diagnostics_.turnaround_drop_count == 0U &&
                     diagnostics_.half_duplex_drop_count == 0U &&
                     diagnostics_.uart_buffer_drop_count == 0U &&
                     diagnostics_.control_crc_errors == 0U &&
                     diagnostics_.control_unknown_version == 0U &&
                     diagnostics_.control_unknown_type == 0U &&
                     diagnostics_.control_malformed == 0U,
                 "R2 introduced an unintended RF/TDD transport fault");

    // Intentional RED contract: after five 1-Hz samples, a bounded sixth
    // heartbeat arrives in DownlinkDrain before Grant issue.  The next Grant
    // must be deferred only until that already-visible heartbeat is admitted.
    // The subsequent normal UL_IDLE proves the implementation did not satisfy
    // the deadline by starving uplink.
    report.check(protected_heartbeat_uart_ms_ > 0U &&
                     protected_heartbeat_air_ms_ > 0U &&
                     second_grant_uart_ms_ >=
                         protected_heartbeat_uart_ms_,
                 "R2 issued the next UL_GRANT before the deadline heartbeat");
    report.check(diagnostics_.heartbeat_grant_deferrals == 1U &&
                     diagnostics_.heartbeat_deadline_misses == 0U,
                 "R2 did not record exactly one on-time pre-Grant heartbeat "
                 "deferral");
    report.check(heartbeat_receive_count_ == 6U &&
                     protected_rf_heartbeat_gap_ms_ > 0U &&
                     protected_rf_heartbeat_gap_ms_ <=
                         kHeartbeatGapLimitMs,
                 "R2 preceding-to-deadline heartbeat RF gap exceeded the "
                 "2500-ms "
                 "heartbeat deadline");

    report.diagnostics = diagnostics_;
    report.cycles = static_cast<std::uint64_t>(
        static_cast<std::uint16_t>(vehicle_.cycle_id() - kInitialCycle));
    report.vehicle_session = vehicle_.session_id();
    report.ground_session = ground_.session_id();
    report.vehicle_cycle = vehicle_.cycle_id();
    report.ground_cycle = ground_.cycle_id();
    report.final_vehicle_state = vehicle_state_name(vehicle_.state());
    report.final_ground_state = ground_state_name(ground_.state());
    report.detail =
        "QUAL-011 R2 model: D7 background=1000ms plus DownlinkDrain "
        "arrival, generic #22 seeded=" +
        std::to_string(r2_seeded_parameter_frames_) +
        "/" + std::to_string(r2_seeded_parameter_bytes_) +
        "B, strict Ground #22 prefix=" +
        std::to_string(r2_parameter_count_) +
        ", protected HB source/UART/RF=" +
        std::to_string(deadline_heartbeat_source_ms_) + "/" +
        std::to_string(protected_heartbeat_uart_ms_) + "/" +
        std::to_string(protected_heartbeat_air_ms_) +
        "ms, second Grant UART=" +
        std::to_string(second_grant_uart_ms_) +
        "ms, protected/max RF heartbeat gap=" +
        std::to_string(protected_rf_heartbeat_gap_ms_) + "/" +
        std::to_string(max_rf_heartbeat_gap_ms_) +
        "ms (limit 2500ms), HB count=" +
        std::to_string(heartbeat_receive_count_) +
        ", max wire V/G=" +
        std::to_string(stats_.max_vehicle_wire_write) + "/" +
        std::to_string(stats_.max_ground_wire_write) + "B";
  }

  void record(TestReport& report, const char* node, const char* event,
              std::uint64_t tx_bytes, std::uint64_t rx_bytes) const {
    const bool is_vehicle = node[0] == 'v';
    report.trace.record(
        {now_ms_, node,
         is_vehicle ? vehicle_state_name(vehicle_.state())
                    : ground_state_name(ground_.state()),
         is_vehicle ? vehicle_.cycle_id() : ground_.cycle_id(), event,
         is_vehicle ? vehicle_radio_.aux_high(now_ms_)
                    : ground_radio_.aux_high(now_ms_),
         request_pending_ ? request_.size : 0U, tx_bytes, rx_bytes,
         is_vehicle ? vehicle_.session_id() : ground_.session_id()});
  }

  void update_radio_observations() noexcept {
    const std::uint64_t vehicle_buffered =
        medium_.buffered_bytes(NodeId::Vehicle);
    const std::uint64_t ground_buffered =
        medium_.buffered_bytes(NodeId::Ground);
    stats_.max_vehicle_buffered_bytes =
        std::max(stats_.max_vehicle_buffered_bytes, vehicle_buffered);
    stats_.max_ground_buffered_bytes =
        std::max(stats_.max_ground_buffered_bytes, ground_buffered);
    stats_.saw_uart_empty_while_air_buffered =
        stats_.saw_uart_empty_while_air_buffered ||
        (vehicle_buffered > 0U &&
         vehicle_radio_.raw_uart_empty(now_ms_)) ||
        (ground_buffered > 0U && ground_radio_.raw_uart_empty(now_ms_));
  }

  std::array<std::uint8_t, kSubpacketBytes> next_downlink_wire(
      bool& heartbeat) noexcept {
    std::array<std::uint8_t, kSubpacketBytes> wire{};
    heartbeat = now_ms_ >= next_heartbeat_ms_;
    if (!heartbeat) {
      std::array<std::uint8_t, kSubpacketBytes> application{};
      for (std::size_t index = 0U; index < application.size(); ++index) {
        application[index] = static_cast<std::uint8_t>(
            0x40U + (index % 0x20U));
      }
      // Even non-MAVLink load must pass through the production link-data
      // escaping layer.  Otherwise its literal 'V' would intentionally open
      // a 32-byte control quarantine and contaminate the following GRANT.
      const EncodedLinkDataChunk encoded = encode_link_data(
          application.data(), application.size(), wire.size());
      if (encoded.wire_size == wire.size()) {
        std::copy_n(encoded.wire_bytes.data(), encoded.wire_size,
                    wire.data());
      }
      return wire;
    }

    const MavlinkFrame frame =
        fixtures::heartbeat_v2(heartbeat_sequence_++);
    const EncodedLinkDataChunk encoded =
        encode_link_data(frame.bytes.data(), frame.size, wire.size());
    if (encoded.wire_size == wire.size()) {
      std::copy_n(encoded.wire_bytes.data(), encoded.wire_size,
                  wire.data());
    }
    do {
      next_heartbeat_ms_ += kHeartbeatPeriodMs;
    } while (next_heartbeat_ms_ <= now_ms_);
    return wire;
  }

  void process_vehicle(const LinkAction& action, TestReport& report) {
    if (action.type == LinkActionType::SendRadioData) {
      report.check(TxGate::authorize_vehicle(
                       vehicle_.state(), TxClass::DownlinkData,
                       diagnostics_),
                   "production Vehicle TX gate rejected buffered downlink");
      if (parameter_priority_mode_) {
        std::array<std::uint8_t, kSubpacketBytes> application{};
        const std::size_t available = vehicle_scheduler_.peek(
            application.data(),
            std::min<std::size_t>(action.byte_budget, application.size()));
        const bool sending_heartbeat =
            vehicle_scheduler_.active_frame_is_heartbeat();
        const EncodedLinkDataChunk encoded = encode_link_data(
            application.data(), available, kSubpacketBytes);
        const TxOutcome outcome =
            encoded.input_consumed > 0U
                ? vehicle_radio_.write(now_ms_, encoded.wire_bytes.data(),
                                       encoded.wire_size)
                : TxOutcome{};
        report.check(vehicle_scheduler_.complete_send(
                         outcome.accepted ? TxResult::Accepted
                                          : TxResult::Rejected,
                         encoded.input_consumed),
                     "priority scheduler did not resolve the physical write");
        vehicle_.complete_action(
            action.token,
            outcome.accepted ? TxResult::Accepted : TxResult::Rejected,
            now_ms_, static_cast<std::uint16_t>(encoded.input_consumed));
        if (outcome.accepted) {
          stats_.max_vehicle_wire_write = std::max(
              stats_.max_vehicle_wire_write, encoded.wire_size);
          if (r2_deadline_mode_ && sending_heartbeat &&
              available > 4U &&
              application[4U] == deadline_heartbeat_sequence_ &&
              protected_heartbeat_uart_ms_ == 0U) {
            protected_heartbeat_uart_ms_ = now_ms_;
          }
        }
        record(report, "vehicle",
               outcome.accepted ? "UART_ACCEPT_PRIORITY_DOWNLINK"
                                : "UART_REJECT_PRIORITY_DOWNLINK",
               outcome.accepted ? encoded.wire_size : 0U, 0U);
        return;
      }
      bool heartbeat = false;
      const auto wire = next_downlink_wire(heartbeat);
      const TxOutcome outcome = vehicle_radio_.write(
          now_ms_, wire.data(), wire.size());
      vehicle_.complete_action(action.token,
                               outcome.accepted ? TxResult::Accepted
                                                : TxResult::Rejected,
                               now_ms_, kSubpacketBytes);
      if (outcome.accepted && downlink_packets_remaining_ > 0U) {
        --downlink_packets_remaining_;
      }
      if (outcome.accepted) {
        stats_.max_vehicle_wire_write =
            std::max(stats_.max_vehicle_wire_write, wire.size());
      }
      record(report, "vehicle",
             outcome.accepted
                 ? (heartbeat ? "UART_ACCEPT_HEARTBEAT"
                              : "UART_ACCEPT_DOWNLINK")
                 : "UART_REJECT_DOWNLINK",
             outcome.accepted ? wire.size() : 0U, 0U);
      return;
    }
    if (action.type != LinkActionType::SendGrant) {
      return;
    }

    report.check(TxGate::authorize_vehicle(
                     vehicle_.state(), TxClass::GrantControl,
                     diagnostics_),
                 "production Vehicle TX gate rejected buffered UL_GRANT");

    std::array<std::uint8_t, kTddControlFrameSize> wire{};
    std::size_t wire_size = 0U;
    const bool encoded = encode_control(action.control, wire.data(),
                                        wire.size(), wire_size);
    const TxOutcome outcome =
        encoded ? vehicle_radio_.write(now_ms_, wire.data(), wire_size)
                : TxOutcome{};
    vehicle_.complete_action(action.token,
                             outcome.accepted ? TxResult::Accepted
                                              : TxResult::Rejected,
                             now_ms_);
    if (outcome.accepted) {
      recovery_.begin(action.control.session_id, action.control.cycle_id);
      stats_.max_vehicle_wire_write =
          std::max(stats_.max_vehicle_wire_write, wire_size);
      if (r2_deadline_mode_) {
        ++r2_grant_uart_admissions_;
        if (r2_grant_uart_admissions_ == 2U) {
          second_grant_uart_ms_ = now_ms_;
        }
      }
    }
    record(report, "vehicle",
           outcome.accepted ? "UART_ACCEPT_GRANT" : "UART_REJECT_GRANT",
           outcome.accepted ? wire_size : 0U, 0U);
  }

  void process_ground(const LinkAction& action, TestReport& report) {
    if (action.type == LinkActionType::SendRadioData) {
      const bool continuing_started_transaction =
          ground_.transaction_target_bytes() > 0U &&
          ground_.actual_bytes() > 0U &&
          ground_.actual_bytes() < ground_.transaction_target_bytes();
      report.check(TxGate::authorize_ground(
                       ground_.state(), TxClass::UplinkData,
                       ground_.has_valid_grant(), now_ms_,
                       ground_.window_deadline_ms(), diagnostics_,
                       continuing_started_transaction),
                   "production Ground TX gate rejected a buffered uplink "
                   "transaction");
      const TxOutcome outcome = ground_radio_.write(
          now_ms_, request_wire_.wire_bytes.data(), request_wire_.wire_size);
      ground_.complete_action(
          action.token,
          outcome.accepted ? TxResult::Accepted : TxResult::Rejected,
          now_ms_, outcome.accepted
                       ? static_cast<std::uint16_t>(request_.size)
                       : 0U);
      if (outcome.accepted) {
        request_pending_ = false;
        ++stats_.ground_data_uart_admissions;
        stats_.max_ground_wire_write = std::max(
            stats_.max_ground_wire_write, request_wire_.wire_size);
        stats_.data_uart_ms = now_ms_;
        stats_.request_data_air_start_ms =
            outcome.end_ms - kObservedAirServiceMs;
      }
      record(report, "ground",
             outcome.accepted ? "UART_ACCEPT_EXACT32_MSG20"
                              : "UART_REJECT_EXACT32_MSG20",
             outcome.accepted ? request_wire_.wire_size : 0U, 0U);
      return;
    }
    if (action.type != LinkActionType::SendDone) {
      return;
    }

    report.check(TxGate::authorize_ground(
                     ground_.state(), TxClass::DoneControl,
                     ground_.has_valid_grant(), now_ms_,
                     ground_.window_deadline_ms(), diagnostics_),
                 "production Ground TX gate rejected buffered UL_DONE");

    std::array<std::uint8_t, kTddControlFrameSize> wire{};
    std::size_t wire_size = 0U;
    const bool encoded = encode_control(action.control, wire.data(),
                                        wire.size(), wire_size);
    const TxOutcome outcome =
        encoded ? ground_radio_.write(now_ms_, wire.data(), wire_size)
                : TxOutcome{};
    ground_.complete_action(action.token,
                            outcome.accepted ? TxResult::Accepted
                                             : TxResult::Rejected,
                            now_ms_);
    if (outcome.accepted &&
        action.control.type == ControlType::UlDone) {
      ++stats_.ground_done_uart_admissions;
      stats_.done_uart_ms = now_ms_;
    }
    if (outcome.accepted) {
      stats_.max_ground_wire_write =
          std::max(stats_.max_ground_wire_write, wire_size);
    }
    record(report, "ground",
           outcome.accepted
               ? (action.control.type == ControlType::UlDone
                      ? "UART_ACCEPT_UL_DONE"
                      : "UART_ACCEPT_UL_IDLE")
               : "UART_REJECT_TERMINAL",
           outcome.accepted ? wire_size : 0U, 0U);
  }

  void deliver_all(TestReport& report) {
    RfDelivery delivery{};
    while (medium_.pop_delivery(NodeId::Ground, now_ms_, delivery)) {
      deliver_ground(delivery, report);
    }
    while (medium_.pop_delivery(NodeId::Vehicle, now_ms_, delivery)) {
      deliver_vehicle(delivery, report);
    }
  }

  void deliver_ground(const RfDelivery& delivery, TestReport& report) {
    if (stats_.last_vehicle_air_completion_ms > 0U) {
      stats_.min_vehicle_air_completion_gap_ms = std::min(
          stats_.min_vehicle_air_completion_gap_ms,
          delivery.ready_ms - stats_.last_vehicle_air_completion_ms);
    }
    stats_.last_vehicle_air_completion_ms = delivery.ready_ms;
    record(report, "ground", "AIR_DELIVERY", 0U, delivery.payload.size);
    for (std::size_t index = 0U; index < delivery.payload.size; ++index) {
      const TddDemuxEvent event =
          ground_demux_.push(delivery.payload.bytes[index]);
      if (event.has_control &&
          event.control.status == DecodeStatus::Message) {
        const ControlDisposition disposition =
            ground_.on_control(event.control.message, now_ms_);
        if (disposition == ControlDisposition::Accepted) {
          if (stats_.ground_data_uart_admissions == 0U) {
            stats_.request_grant_air_end_ms = delivery.ready_ms;
          }
          record(report, "ground", "AIR_RX_GRANT", 0U,
                 kTddControlFrameSize);
        }
      }
      for (std::size_t local = 0U; local < event.local_size; ++local) {
        MavlinkFrame frame{};
        if (ground_parser_.push(event.local_bytes[local], frame) !=
            MavlinkParseStatus::FrameReady) {
          continue;
        }
        if (parameter_priority_mode_ && frame.message_id == 22U) {
          note_parameter_value_at_ground(frame, report);
          continue;
        }
        if (frame.message_id != 0U) {
          continue;
        }
        if (stats_.heartbeat_last_ms > 0U) {
          diagnostics_.heartbeat_max_gap_ms = std::max(
              diagnostics_.heartbeat_max_gap_ms,
              now_ms_ - stats_.heartbeat_last_ms);
        } else {
          stats_.heartbeat_first_ms = now_ms_;
        }
        stats_.heartbeat_last_ms = now_ms_;
        ++diagnostics_.heartbeat_valid;
        if (parameter_priority_mode_) {
          report.check(frame.size > 4U && frame.bytes[0U] == 0xFDU,
                       "actual primary RF heartbeat was not MAVLink 2");
          report.check(frame.system_id == 1U && frame.component_id == 1U,
                       "RF heartbeat supply was not from primary sysid/"
                       "compid 1/1 required by the production USB pacer");
          const std::size_t heartbeat_sequence = frame.sequence;
          report.check(!heartbeat_sequence_seen_[heartbeat_sequence],
                       "actual RF heartbeat sequence/wire was duplicated");
          heartbeat_sequence_seen_[heartbeat_sequence] = true;
          if (heartbeat_receive_count_ < heartbeat_receive_ms_.size()) {
            heartbeat_receive_ms_[heartbeat_receive_count_] = now_ms_;
          }
          const std::size_t supply_slot = heartbeat_receive_count_ %
                                          heartbeat_supply_window_.size();
          if (heartbeat_receive_count_ >=
              heartbeat_supply_window_.size()) {
            const std::uint64_t supply_span_ms =
                now_ms_ - heartbeat_supply_window_[supply_slot];
            max_heartbeat_supply_span_ms_ = std::max(
                max_heartbeat_supply_span_ms_, supply_span_ms);
            ++heartbeat_supply_window_checks_;
            if (!r2_deadline_mode_) {
              report.check(
                  supply_span_ms <= kUsbHeartbeatSupplyWindowMs,
                  "actual RF heartbeat supply fell below three unique frames "
                  "per trailing 6200 ms");
            }
          }
          heartbeat_supply_window_[supply_slot] = now_ms_;
          if (heartbeat_receive_count_ > 0U) {
            max_rf_heartbeat_gap_ms_ = std::max(
                max_rf_heartbeat_gap_ms_, now_ms_ - last_rf_heartbeat_ms_);
          }
          if (r2_deadline_mode_ && deadline_heartbeat_enqueued_ &&
              frame.sequence == deadline_heartbeat_sequence_ &&
              protected_heartbeat_air_ms_ == 0U) {
            protected_heartbeat_air_ms_ = now_ms_;
            if (last_rf_heartbeat_ms_ > 0U) {
              protected_rf_heartbeat_gap_ms_ =
                  now_ms_ - last_rf_heartbeat_ms_;
            }
          }
          ++heartbeat_receive_count_;
          last_rf_heartbeat_ms_ = now_ms_;
        }
        record(report, "ground", "AIR_RX_HEARTBEAT", 0U, frame.size);
      }
    }
  }

  void deliver_vehicle(const RfDelivery& delivery, TestReport& report) {
    if (stats_.last_ground_air_completion_ms > 0U) {
      stats_.min_ground_air_completion_gap_ms = std::min(
          stats_.min_ground_air_completion_gap_ms,
          delivery.ready_ms - stats_.last_ground_air_completion_ms);
    }
    stats_.last_ground_air_completion_ms = delivery.ready_ms;
    record(report, "vehicle", "AIR_DELIVERY", 0U,
           delivery.payload.size);
    for (std::size_t index = 0U; index < delivery.payload.size; ++index) {
      const TddDemuxEvent event =
          vehicle_demux_.push(delivery.payload.bytes[index]);
      if (event.has_control &&
          event.control.status == DecodeStatus::Message) {
        if (event.control.message.type == ControlType::UlDone) {
          ++stats_.ground_done_air_arrivals;
          stats_.done_air_ms = now_ms_;
        }
        handle_vehicle_terminal(event.control.message, report);
      }
      if (event.local_size == 0U) {
        continue;
      }
      stats_.request_data_air_bytes += event.local_size;
      stats_.data_air_ms = now_ms_;
      const bool normal = vehicle_.radio_receive_window();
      const bool late = vehicle_.late_uplink_recovery_window();
      if (!normal && !late) {
        diagnostics_.uplink_data_outside_receive_window +=
            event.local_size;
        continue;
      }
      if (late) {
        (void)vehicle_.note_return_guard_activity(now_ms_);
      }
      stats_.request_receive_window_bytes += event.local_size;
      for (std::size_t local = 0U; local < event.local_size; ++local) {
        (void)recovery_.ingest(event.local_bytes[local]);
      }
    }
  }

  void handle_vehicle_terminal(const TddControlMessage& message,
                               TestReport& report) {
    if (!vehicle_.radio_receive_window() &&
        !vehicle_.late_uplink_recovery_window()) {
      return;
    }
    const LateUplinkTerminalStatus terminal = recovery_.on_terminal(message);
    bool accepted = false;
    if (vehicle_.radio_receive_window()) {
      accepted = vehicle_.on_control(message, now_ms_) ==
                 ControlDisposition::Accepted;
    } else if (vehicle_.late_uplink_recovery_window()) {
      accepted = vehicle_.complete_late_uplink_terminal(
          now_ms_, message.type,
          terminal == LateUplinkTerminalStatus::Ready ||
              terminal == LateUplinkTerminalStatus::Idle);
    }
    if (!accepted || terminal != LateUplinkTerminalStatus::Ready) {
      return;
    }

    std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes> committed{};
    std::size_t committed_size = 0U;
    std::uint16_t committed_frames = 0U;
    if (recovery_.take_commit(committed.data(), committed.size(),
                               committed_size, committed_frames) &&
        committed_size == request_.size && committed_frames == 1U &&
        std::memcmp(committed.data(), request_.bytes.data(),
                    request_.size) == 0) {
      if (!parameter_priority_mode_ ||
          d6_egress_.ingest(committed.data(), committed_size) ==
              committed_size) {
        ++stats_.exact_request_commits;
        record(report, "vehicle", "D6_COMMIT_EXACT32_MSG20", 0U,
               committed_size);
        if (parameter_priority_mode_) {
          const MavlinkParameterRequestStatus remember_status =
              vehicle_scheduler_.remember_parameter_request(request_);
          report.check(remember_status ==
                           MavlinkParameterRequestStatus::Remembered,
                       "D6-admitted #20 identity was not remembered");
          if (remember_status == MavlinkParameterRequestStatus::Remembered) {
            ++request_remembered_count_;
            seed_parameter_priority_downlink(report);
          }
        }
      } else {
        report.check(false, "exact #20 did not enter the modeled D6 queue");
      }
    }
  }

  const TddConfig tdd_config_{};
  const RfMediumConfig rf_config_{make_rf_config()};
  LinkDiagnostics diagnostics_{};
  RfMediumSim medium_;
  ContractGatedE220 vehicle_radio_;
  ContractGatedE220 ground_radio_;
  VehicleTddController vehicle_;
  GroundTddController ground_;
  TddLinkDemux vehicle_demux_{true};
  TddLinkDemux ground_demux_{true};
  MavlinkStreamParser ground_parser_{};
  VehicleLateUplinkRecovery recovery_{};
  VehicleLocalEgressAdapter d6_egress_{};
  MavlinkFrameScheduler vehicle_scheduler_{};
  MavlinkFrame request_{};
  EncodedLinkDataChunk request_wire_{};
  MavlinkFrame target_response_{};
  ScenarioStats stats_{};
  std::array<std::uint16_t, kPriorityOldParameterValues>
      old_parameter_order_{};
  std::array<MavlinkFrame, kPriorityOldParameterValues>
      old_parameter_expected_{};
  std::array<std::uint64_t, 8U> heartbeat_receive_ms_{};
  std::array<std::uint64_t, 3U> heartbeat_supply_window_{};
  std::array<bool, 256U> heartbeat_sequence_seen_{};
  std::uint64_t now_ms_{0U};
  std::uint64_t next_heartbeat_ms_{0U};
  std::uint64_t next_priority_heartbeat_ms_{0U};
  std::uint64_t request_origin_ms_{0U};
  std::uint64_t target_enqueued_ms_{0U};
  std::uint64_t target_ground_ms_{0U};
  std::uint64_t old_parameter_drain_ms_{0U};
  std::uint64_t last_rf_heartbeat_ms_{0U};
  std::uint64_t max_rf_heartbeat_gap_ms_{0U};
  std::uint64_t max_heartbeat_supply_span_ms_{0U};
  std::uint64_t deadline_heartbeat_source_ms_{0U};
  std::uint64_t protected_heartbeat_uart_ms_{0U};
  std::uint64_t protected_heartbeat_air_ms_{0U};
  std::uint64_t protected_rf_heartbeat_gap_ms_{0U};
  std::uint64_t second_grant_uart_ms_{0U};
  std::size_t r2_seeded_parameter_frames_{0U};
  std::size_t r2_seeded_parameter_bytes_{0U};
  std::uint16_t r2_parameter_count_{0U};
  std::uint64_t r2_grant_uart_admissions_{0U};
  std::uint16_t last_vehicle_cycle_{kInitialCycle};
  std::uint16_t downlink_packets_remaining_{kDownlinkPacketsPerCycle};
  std::uint8_t heartbeat_sequence_{0U};
  std::uint8_t priority_heartbeat_sequence_{0xD0U};
  std::uint8_t deadline_heartbeat_sequence_{0U};
  std::size_t r2_heartbeat_sources_enqueued_{0U};
  std::size_t heartbeat_receive_count_{0U};
  std::size_t heartbeat_supply_window_checks_{0U};
  std::size_t old_parameter_count_{0U};
  std::uint64_t target_ground_count_{0U};
  std::uint64_t request_remembered_count_{0U};
  bool request_pending_{true};
  bool parameter_priority_mode_{false};
  bool r2_deadline_mode_{false};
  bool parameter_priority_seeded_{false};
  bool deadline_heartbeat_enqueued_{false};
  bool scenario_completed_{false};
};

void check_two_chunk_service_floor_transaction(TestReport& report,
                                               std::uint32_t seed) {
  RfMediumConfig rf_config{};
  rf_config.uart_rate_bps = FixedFirmwareContract::e220_uart_bps;
  rf_config.air_rate_bps = FixedFirmwareContract::e220_air_bps;
  rf_config.sub_packet_bytes = kSubpacketBytes;
  rf_config.min_tx_gap_ms = FixedFirmwareContract::min_tx_gap_ms;
  rf_config.uart_buffer_bytes = kE220BufferBytes;
  rf_config.buffered_air_subpacket_service_ms = kObservedAirServiceMs;

  LinkDiagnostics diagnostics{};
  RfMediumSim medium{rf_config, seed, diagnostics};
  ContractGatedE220 radio{NodeId::Ground, medium};
  const TddConfig config{};
  GroundTddController ground{config, diagnostics};
  GroundMavlinkIngressAdapter ingress{};
  const MavlinkFrame frame = fixtures::command_long_v2(0x83U);
  report.check(frame.size == 45U &&
                   ingress.admit_validated_frame(frame) ==
                       FrameIngressStatus::Queued &&
                   ingress.front_frame_wire_bytes() == 64U,
               "two-chunk fixture was not one 45B/64-wire MAVLink frame");

  ground.reset(0U);
  TddControlMessage grant{};
  grant.version = kTddProtocolVersion;
  grant.type = ControlType::UlGrant;
  grant.session_id = 0x6202U;
  grant.cycle_id = 7U;
  grant.guard_ms = 0U;
  grant.window_ms = FixedFirmwareContract::uplink_window_ms;
  grant.max_bytes = 64U;
  report.check(ground.on_control(grant, 0U) ==
                   ControlDisposition::Accepted,
               "two-chunk fixture did not accept its v2 grant");

  std::size_t data_writes = 0U;
  std::size_t application_bytes = 0U;
  std::uint64_t first_data_ms = 0U;
  std::uint64_t second_data_ms = 0U;
  std::uint64_t done_uart_ms = 0U;
  std::uint64_t done_air_end_ms = 0U;
  bool saw_immediate_commit_while_busy = false;
  bool done_issued = false;
  TddControlMessage terminal{};

  for (std::uint64_t now_ms = 0U; now_ms < 3'000U; ++now_ms) {
    medium.advance(now_ms);
    radio.service(now_ms);

    TddInput input{};
    input.now_ms = now_ms;
    input.aux_high = radio.aux_high(now_ms);
    input.radio_tx_empty = radio.radio_tx_empty(now_ms);
    input.local_tx_empty = true;
    input.queued_bytes = static_cast<std::uint32_t>(ingress.queued_bytes());
    input.front_frame_bytes =
        static_cast<std::uint16_t>(ingress.front_frame_remaining());

    if (ground.has_valid_grant() && input.queued_bytes > 0U) {
      const std::size_t transaction_limit =
          ground.transaction_target_bytes() > 0U
              ? ground.transaction_target_bytes()
              : ground.granted_bytes();
      const std::size_t remaining =
          ground.actual_bytes() < transaction_limit
              ? transaction_limit - ground.actual_bytes()
              : 0U;
      const std::size_t preview_limit = std::min<std::size_t>(
          {ingress.front_frame_remaining(), kSubpacketBytes, remaining});
      if (preview_limit > 0U) {
        std::array<std::uint8_t, kSubpacketBytes> preview{};
        const std::size_t preview_size =
            ingress.peek(preview.data(), preview_limit);
        const EncodedLinkDataChunk encoded = encode_link_data(
            preview.data(), preview_size, kSubpacketBytes);
        input.next_tx_application_bytes =
            static_cast<std::uint16_t>(encoded.input_consumed);
        input.next_tx_wire_bytes = ingress.front_frame_wire_bytes();
      }
    }

    const LinkAction action = ground.tick(input);
    if (action.type == LinkActionType::SendRadioData) {
      const bool continuing_started_transaction =
          ground.transaction_target_bytes() > 0U &&
          ground.actual_bytes() > 0U &&
          ground.actual_bytes() < ground.transaction_target_bytes();
      const bool authorized = TxGate::authorize_ground(
          ground.state(), TxClass::UplinkData,
          ground.has_valid_grant(), now_ms, ground.window_deadline_ms(),
          diagnostics, continuing_started_transaction);
      report.check(authorized,
                   "production TX gate rejected the second chunk after the "
                   "admission window");
      if (!authorized) {
        break;
      }

      std::array<std::uint8_t, kSubpacketBytes> application{};
      const std::size_t available = ingress.peek(
          application.data(),
          std::min<std::size_t>(application.size(), action.byte_budget));
      const EncodedLinkDataChunk encoded = encode_link_data(
          application.data(), available, kSubpacketBytes);
      const TxOutcome outcome = radio.write(
          now_ms, encoded.wire_bytes.data(), encoded.wire_size);
      report.check(outcome.accepted && encoded.input_consumed > 0U,
                   "contract-gated two-chunk physical write was rejected");
      if (!outcome.accepted || encoded.input_consumed == 0U) {
        ground.complete_action(action.token, TxResult::Rejected, now_ms);
        continue;
      }

      report.check(ingress.complete_send(TxResult::Accepted,
                                         encoded.input_consumed),
                   "two-chunk ingress could not commit an accepted prefix");
      ground.complete_action(
          action.token, TxResult::Accepted, now_ms,
          static_cast<std::uint16_t>(encoded.input_consumed));
      ++data_writes;
      application_bytes += encoded.input_consumed;
      if (data_writes == 1U) {
        first_data_ms = now_ms;
      } else if (data_writes == 2U) {
        second_data_ms = now_ms;
      }
      saw_immediate_commit_while_busy =
          saw_immediate_commit_while_busy ||
          (ground.actual_bytes() > 0U &&
           !radio.radio_tx_empty(now_ms));
      continue;
    }

    if (action.type == LinkActionType::SendDone) {
      const bool authorized = TxGate::authorize_ground(
          ground.state(), TxClass::DoneControl,
          ground.has_valid_grant(), now_ms, ground.window_deadline_ms(),
          diagnostics);
      report.check(authorized,
                   "production TX gate rejected the two-chunk UL_DONE");
      std::array<std::uint8_t, kTddControlFrameSize> wire{};
      std::size_t wire_size = 0U;
      const bool encoded = encode_control(action.control, wire.data(),
                                          wire.size(), wire_size);
      const TxOutcome outcome =
          authorized && encoded
              ? radio.write(now_ms, wire.data(), wire_size)
              : TxOutcome{};
      report.check(outcome.accepted,
                   "two-chunk explicit UL_DONE physical write was rejected");
      if (!outcome.accepted) {
        ground.complete_action(action.token, TxResult::Rejected, now_ms);
        continue;
      }
      terminal = action.control;
      done_issued = true;
      done_uart_ms = now_ms;
      done_air_end_ms = outcome.end_ms;
      ground.complete_action(action.token, TxResult::Accepted, now_ms);
    }

    if (done_issued && ground.state() == GroundTddState::WaitGrant &&
        radio.completion_count() == 3U) {
      break;
    }
  }

  report.check(data_writes == 2U && application_bytes == frame.size &&
                   ingress.empty(),
               "service-floor transaction did not consume exactly two "
               "chunks of the selected frame");
  report.check(first_data_ms < ground.window_deadline_ms() &&
                   second_data_ms >=
                       first_data_ms +
                           FixedFirmwareContract::
                               e220_subpacket_service_floor_ms &&
                   second_data_ms > ground.window_deadline_ms(),
               "second chunk did not prove bounded continuation beyond the "
               "300-ms admission window");
  report.check(done_issued && terminal.type == ControlType::UlDone &&
                   terminal.actual_bytes == frame.size &&
                   done_uart_ms > second_data_ms,
               "two-chunk transaction emitted a partial or missing UL_DONE");
  report.check(saw_immediate_commit_while_busy &&
                   radio.admission_count() == 3U &&
                   radio.completion_count() == 3U &&
                   !radio.fail_closed(),
               "UART commit/radio_busy service-floor composition changed");
  report.check(done_air_end_ms - first_data_ms <=
                   FixedFirmwareContract::vehicle_receive_timeout_ms &&
                   diagnostics.tx_gate_violation == 0U &&
                   diagnostics.collision_count == 0U &&
                   diagnostics.packet_loss_count == 0U,
               "two DATA chunks plus DONE exceeded the bounded Vehicle "
               "receive interval or overlapped RF service");

  report.detail +=
      "; two-chunk gate: DATA=" + std::to_string(first_data_ms) + "/" +
      std::to_string(second_data_ms) + "ms, DONE UART/air-end=" +
      std::to_string(done_uart_ms) + "/" +
      std::to_string(done_air_end_ms) + "ms";
}

void check_two_chunk_vehicle_atomic_commit(TestReport& report,
                                           std::uint32_t seed) {
  RfMediumConfig rf_config{};
  rf_config.uart_rate_bps = FixedFirmwareContract::e220_uart_bps;
  rf_config.air_rate_bps = FixedFirmwareContract::e220_air_bps;
  rf_config.sub_packet_bytes = kSubpacketBytes;
  rf_config.min_tx_gap_ms = FixedFirmwareContract::min_tx_gap_ms;
  rf_config.uart_buffer_bytes = kE220BufferBytes;
  rf_config.buffered_air_subpacket_service_ms = kObservedAirServiceMs;

  LinkDiagnostics diagnostics{};
  RfMediumSim medium{rf_config, seed, diagnostics};
  ContractGatedE220 vehicle_radio{NodeId::Vehicle, medium};
  ContractGatedE220 ground_radio{NodeId::Ground, medium};
  const TddConfig config{};
  VehicleTddController vehicle{config, diagnostics};
  GroundTddController ground{config, diagnostics};
  TddLinkDemux vehicle_demux{true};
  TddLinkDemux ground_demux{true};
  VehicleLateUplinkRecovery recovery{};
  GroundMavlinkIngressAdapter ingress{};
  const MavlinkFrame frame = fixtures::command_long_v2(0x83U);

  report.check(frame.size == 45U &&
                   ingress.admit_validated_frame(frame) ==
                       FrameIngressStatus::Queued &&
                   ingress.front_frame_wire_bytes() == 64U,
               "full Vehicle fixture was not one 45B/64-wire MAVLink "
               "frame");

  constexpr std::uint16_t kVehicleSession = 0x6245U;
  constexpr std::uint16_t kVehicleCycle = 9U;
  vehicle.reset(kVehicleSession, kVehicleCycle, 0U);
  ground.reset(0U);

  std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes> committed{};
  std::array<std::uint64_t, 3U> ground_air_completion_ms{};
  std::size_t ground_air_completion_count = 0U;
  std::size_t committed_size = 0U;
  std::uint16_t committed_frames = 0U;
  std::uint64_t commit_count = 0U;
  std::uint64_t data_writes = 0U;
  std::uint64_t data_air_deliveries = 0U;
  std::uint64_t invalid_or_overflow_ingest = 0U;
  std::uint64_t discarded_terminals = 0U;
  std::uint64_t outside_bytes = 0U;
  std::uint64_t first_data_uart_ms = 0U;
  std::uint64_t second_data_uart_ms = 0U;
  std::uint64_t first_data_air_ms = 0U;
  std::uint64_t second_data_air_ms = 0U;
  std::uint64_t done_uart_ms = 0U;
  std::uint64_t done_air_ms = 0U;
  std::uint64_t grant_air_end_ms = 0U;
  std::uint64_t first_data_air_start_ms = 0U;
  std::uint64_t vehicle_receive_epoch_ms = 0U;
  std::uint64_t max_ground_buffered_bytes = 0U;
  std::uint64_t terminal_count = 0U;
  std::uint16_t terminal_session = 0U;
  std::uint16_t terminal_cycle = 0U;
  std::uint16_t terminal_actual = 0U;
  ControlType terminal_type = ControlType::UlIdle;
  bool terminal_was_normal = false;
  bool terminal_was_late = false;
  bool saw_full_quarantine_before_terminal = false;

  for (std::uint64_t now_ms = 0U; now_ms < 7'000U; ++now_ms) {
    medium.advance(now_ms);
    vehicle_radio.service(now_ms);
    ground_radio.service(now_ms);
    max_ground_buffered_bytes = std::max(
        max_ground_buffered_bytes, medium.buffered_bytes(NodeId::Ground));

    RfDelivery delivery{};
    while (medium.pop_delivery(NodeId::Ground, now_ms, delivery)) {
      for (std::size_t index = 0U; index < delivery.payload.size; ++index) {
        const TddDemuxEvent event =
            ground_demux.push(delivery.payload.bytes[index]);
        diagnostics.control_bytes_leaked_to_local_uart += event.local_size;
        if (!event.has_control) {
          continue;
        }
        diagnostics.note_decode_status(event.control.status);
        if (event.control.status == DecodeStatus::Message &&
            event.control.message.type == ControlType::UlGrant &&
            ground.on_control(event.control.message, now_ms) ==
                ControlDisposition::Accepted) {
          grant_air_end_ms = delivery.ready_ms;
        }
      }
    }

    while (medium.pop_delivery(NodeId::Vehicle, now_ms, delivery)) {
      if (ground_air_completion_count < ground_air_completion_ms.size()) {
        ground_air_completion_ms[ground_air_completion_count++] =
            delivery.ready_ms;
      }
      bool delivery_had_local_data = false;
      for (std::size_t index = 0U; index < delivery.payload.size; ++index) {
        const TddDemuxEvent event =
            vehicle_demux.push(delivery.payload.bytes[index]);
        diagnostics.control_bytes_leaked_to_local_uart +=
            event.has_control ? event.local_size : 0U;
        if (event.has_control) {
          diagnostics.note_decode_status(event.control.status);
          if (event.control.status == DecodeStatus::Message &&
              (event.control.message.type == ControlType::UlDone ||
               event.control.message.type == ControlType::UlIdle)) {
            ++terminal_count;
            done_air_ms = delivery.ready_ms;
            terminal_type = event.control.message.type;
            terminal_session = event.control.message.session_id;
            terminal_cycle = event.control.message.cycle_id;
            terminal_actual = event.control.message.actual_bytes;
            terminal_was_normal = vehicle.radio_receive_window();
            terminal_was_late = vehicle.late_uplink_recovery_window();
            const LateUplinkTerminalStatus terminal =
                recovery.on_terminal(event.control.message);
            if (terminal == LateUplinkTerminalStatus::Discarded) {
              ++discarded_terminals;
            }
            bool accepted = false;
            if (terminal_was_normal) {
              accepted =
                  vehicle.on_control(event.control.message, now_ms) ==
                  ControlDisposition::Accepted;
            } else if (terminal_was_late) {
              accepted = vehicle.complete_late_uplink_terminal(
                  now_ms, event.control.message.type,
                  terminal == LateUplinkTerminalStatus::Ready ||
                      terminal == LateUplinkTerminalStatus::Idle);
            }
            if (accepted && terminal == LateUplinkTerminalStatus::Ready &&
                recovery.take_commit(
                    committed.data(), committed.size(), committed_size,
                    committed_frames)) {
              ++commit_count;
            }
          }
        }

        if (event.local_size == 0U) {
          continue;
        }
        if (!delivery_had_local_data) {
          delivery_had_local_data = true;
          ++data_air_deliveries;
          if (data_air_deliveries == 1U) {
            first_data_air_ms = delivery.ready_ms;
            first_data_air_start_ms = delivery.start_ms;
          } else if (data_air_deliveries == 2U) {
            second_data_air_ms = delivery.ready_ms;
          }
        }
        const bool normal = vehicle.radio_receive_window();
        const bool late = vehicle.late_uplink_recovery_window();
        if (!normal && !late) {
          diagnostics.uplink_data_outside_receive_window += event.local_size;
          outside_bytes += event.local_size;
          continue;
        }
        if (late) {
          (void)vehicle.note_return_guard_activity(now_ms);
        }
        for (std::size_t local = 0U; local < event.local_size; ++local) {
          const LateUplinkIngestStatus status =
              recovery.ingest(event.local_bytes[local]);
          if (status == LateUplinkIngestStatus::Invalid ||
              status == LateUplinkIngestStatus::Overflow) {
            ++invalid_or_overflow_ingest;
          }
        }
        if (recovery.buffered_bytes() == frame.size &&
            terminal_count == 0U && commit_count == 0U) {
          saw_full_quarantine_before_terminal = true;
        }
      }
    }

    TddInput vehicle_input{};
    vehicle_input.now_ms = now_ms;
    vehicle_input.aux_high = vehicle_radio.aux_high(now_ms);
    vehicle_input.radio_tx_complete = vehicle_radio.radio_tx_complete();
    vehicle_input.radio_tx_empty = vehicle_radio.radio_tx_empty(now_ms);
    vehicle_input.local_tx_empty = true;
    const LinkAction vehicle_action = vehicle.tick(vehicle_input);
    if (vehicle.state() == VehicleTddState::UplinkReceive &&
        vehicle_receive_epoch_ms == 0U) {
      vehicle_receive_epoch_ms = now_ms;
    }
    if (vehicle_action.type == LinkActionType::SendGrant) {
      const bool authorized = TxGate::authorize_vehicle(
          vehicle.state(), TxClass::GrantControl, diagnostics);
      std::array<std::uint8_t, kTddControlFrameSize> wire{};
      std::size_t wire_size = 0U;
      const bool encoded = encode_control(vehicle_action.control, wire.data(),
                                          wire.size(), wire_size);
      const TxOutcome outcome =
          authorized && encoded
              ? vehicle_radio.write(now_ms, wire.data(), wire_size)
              : TxOutcome{};
      vehicle.complete_action(vehicle_action.token,
                              outcome.accepted ? TxResult::Accepted
                                               : TxResult::Rejected,
                              now_ms);
      if (outcome.accepted) {
        recovery.begin(vehicle_action.control.session_id,
                       vehicle_action.control.cycle_id);
      }
    }

    TddInput ground_input{};
    ground_input.now_ms = now_ms;
    ground_input.aux_high = ground_radio.aux_high(now_ms);
    ground_input.radio_tx_complete = ground_radio.radio_tx_complete();
    ground_input.radio_tx_empty = ground_radio.radio_tx_empty(now_ms);
    ground_input.local_tx_empty = true;
    ground_input.queued_bytes =
        static_cast<std::uint32_t>(ingress.queued_bytes());
    ground_input.front_frame_bytes = ingress.front_frame_remaining();
    if (ground.has_valid_grant() && !ingress.empty()) {
      const std::size_t transaction_limit =
          ground.transaction_target_bytes() > 0U
              ? ground.transaction_target_bytes()
              : ground.granted_bytes();
      const std::size_t remaining =
          ground.actual_bytes() < transaction_limit
              ? transaction_limit - ground.actual_bytes()
              : 0U;
      const std::size_t preview_limit = std::min<std::size_t>(
          {ingress.front_frame_remaining(), kSubpacketBytes, remaining});
      if (preview_limit > 0U) {
        std::array<std::uint8_t, kSubpacketBytes> preview{};
        const std::size_t preview_size =
            ingress.peek(preview.data(), preview_limit);
        const EncodedLinkDataChunk encoded = encode_link_data(
            preview.data(), preview_size, kSubpacketBytes);
        ground_input.next_tx_application_bytes =
            static_cast<std::uint16_t>(encoded.input_consumed);
        ground_input.next_tx_wire_bytes = ingress.front_frame_wire_bytes();
      }
    }

    const LinkAction ground_action = ground.tick(ground_input);
    if (ground_action.type == LinkActionType::SendRadioData) {
      const bool continuing_started_transaction =
          ground.transaction_target_bytes() > 0U &&
          ground.actual_bytes() > 0U &&
          ground.actual_bytes() < ground.transaction_target_bytes();
      const bool authorized = TxGate::authorize_ground(
          ground.state(), TxClass::UplinkData, ground.has_valid_grant(),
          now_ms, ground.window_deadline_ms(), diagnostics,
          continuing_started_transaction);
      std::array<std::uint8_t, kSubpacketBytes> application{};
      const std::size_t available = ingress.peek(
          application.data(),
          std::min<std::size_t>(application.size(),
                                ground_action.byte_budget));
      const EncodedLinkDataChunk encoded = encode_link_data(
          application.data(), available, kSubpacketBytes);
      const TxOutcome outcome =
          authorized && encoded.input_consumed > 0U
              ? ground_radio.write(now_ms, encoded.wire_bytes.data(),
                                   encoded.wire_size)
              : TxOutcome{};
      if (outcome.accepted) {
        report.check(ingress.complete_send(TxResult::Accepted,
                                           encoded.input_consumed),
                     "full Vehicle fixture could not commit an accepted "
                     "Ground prefix");
      }
      ground.complete_action(
          ground_action.token,
          outcome.accepted ? TxResult::Accepted : TxResult::Rejected,
          now_ms, outcome.accepted
                      ? static_cast<std::uint16_t>(encoded.input_consumed)
                      : 0U);
      if (outcome.accepted) {
        ++data_writes;
        if (data_writes == 1U) {
          first_data_uart_ms = now_ms;
        } else if (data_writes == 2U) {
          second_data_uart_ms = now_ms;
        }
      }
    } else if (ground_action.type == LinkActionType::SendDone) {
      const bool authorized = TxGate::authorize_ground(
          ground.state(), TxClass::DoneControl, ground.has_valid_grant(),
          now_ms, ground.window_deadline_ms(), diagnostics);
      std::array<std::uint8_t, kTddControlFrameSize> wire{};
      std::size_t wire_size = 0U;
      const bool encoded = encode_control(ground_action.control, wire.data(),
                                          wire.size(), wire_size);
      const TxOutcome outcome =
          authorized && encoded
              ? ground_radio.write(now_ms, wire.data(), wire_size)
              : TxOutcome{};
      ground.complete_action(ground_action.token,
                             outcome.accepted ? TxResult::Accepted
                                              : TxResult::Rejected,
                             now_ms);
      if (outcome.accepted) {
        done_uart_ms = now_ms;
      }
    }

    if (commit_count == 1U &&
        ground.state() == GroundTddState::WaitGrant &&
        ground_radio.completion_count() == 3U) {
      break;
    }
  }

  report.check(data_writes == 2U && data_air_deliveries == 2U &&
                   ingress.empty(),
               "full Vehicle path did not carry exactly two DATA chunks");
  report.check(first_data_uart_ms > 0U &&
                   first_data_uart_ms < ground.window_deadline_ms() &&
                   second_data_uart_ms > ground.window_deadline_ms() &&
                   second_data_uart_ms - first_data_uart_ms >=
                       FixedFirmwareContract::
                           e220_subpacket_service_floor_ms,
               "full Vehicle path did not prove admitted continuation past "
               "the 300-ms window");
  report.check(terminal_count == 1U &&
                   terminal_type == ControlType::UlDone &&
                   terminal_session == kVehicleSession &&
                   terminal_cycle == kVehicleCycle &&
                   terminal_actual == frame.size,
               "full Vehicle path terminal did not match v2 session/cycle/"
               "actual=45");
  report.check((terminal_was_normal || terminal_was_late) &&
                   commit_count == 1U && committed_size == frame.size &&
                   committed_frames == 1U &&
                   std::memcmp(committed.data(), frame.bytes.data(),
                               frame.size) == 0 &&
                   saw_full_quarantine_before_terminal,
               "Vehicle did not atomically commit the quarantined 45B frame "
               "exactly once");
  bool duplicate_commit = false;
  if (commit_count == 1U) {
    std::size_t duplicate_size = 0U;
    std::uint16_t duplicate_frames = 0U;
    duplicate_commit = recovery.take_commit(
        committed.data(), committed.size(), duplicate_size,
        duplicate_frames);
  }
  report.check(!duplicate_commit,
               "Vehicle recovery exposed the 45B transaction twice");
  report.check(vehicle_receive_epoch_ms > 0U && done_air_ms > 0U &&
                   done_air_ms >= vehicle_receive_epoch_ms &&
                   done_air_ms - vehicle_receive_epoch_ms <=
                       FixedFirmwareContract::vehicle_receive_timeout_ms,
               "45B terminal did not reach the actual Vehicle controller "
               "inside its receive lease");
  report.check(ground_air_completion_count == 3U &&
                   ground_air_completion_ms[1] -
                           ground_air_completion_ms[0] >=
                       FixedFirmwareContract::
                           e220_subpacket_service_floor_ms &&
                   ground_air_completion_ms[2] -
                           ground_air_completion_ms[1] >=
                       FixedFirmwareContract::
                           e220_subpacket_service_floor_ms,
               "full Vehicle path violated remote 550-ms DATA/DONE "
               "completion spacing");
  report.check(grant_air_end_ms > 0U && first_data_air_start_ms > 0U &&
                   first_data_air_start_ms >= grant_air_end_ms &&
                   first_data_air_start_ms - grant_air_end_ms >=
                       FixedFirmwareContract::uplink_guard_ms - 3U,
               "full Vehicle path violated the effective 647-ms direction "
               "turnaround");
  report.check(max_ground_buffered_bytes <= 64U &&
                   ground_radio.admission_count() == 3U &&
                   ground_radio.completion_count() == 3U &&
                   !vehicle_radio.fail_closed() &&
                   !ground_radio.fail_closed() && !ground.fail_closed(),
               "full Vehicle production gate exceeded bounded buffering or "
               "failed closed");
  report.check(invalid_or_overflow_ingest == 0U &&
                   discarded_terminals == 0U && outside_bytes == 0U &&
                   diagnostics.uplink_data_outside_receive_window == 0U &&
                   diagnostics.uplink_timeouts == 0U &&
                   diagnostics.invalid_done == 0U &&
                   diagnostics.partial_mavlink_delivered == 0U &&
                   diagnostics.collision_count == 0U &&
                   diagnostics.packet_loss_count == 0U &&
                   diagnostics.turnaround_drop_count == 0U &&
                   diagnostics.half_duplex_drop_count == 0U,
               "full Vehicle path reported partial/discard/outside/timeout/"
               "collision/loss");

  const std::uint64_t receive_deadline =
      vehicle_receive_epoch_ms +
      FixedFirmwareContract::vehicle_receive_timeout_ms;
  const std::uint64_t receive_margin =
      receive_deadline >= done_air_ms ? receive_deadline - done_air_ms : 0U;
  report.detail +=
      "; Vehicle-full 45B: RX epoch=" +
      std::to_string(vehicle_receive_epoch_ms) + "ms, DATA UART=" +
      std::to_string(first_data_uart_ms) + "/" +
      std::to_string(second_data_uart_ms) + "ms AIR=" +
      std::to_string(first_data_air_ms) + "/" +
      std::to_string(second_data_air_ms) + "ms, DONE UART/air=" +
      std::to_string(done_uart_ms) + "/" + std::to_string(done_air_ms) +
      "ms, receive margin=" + std::to_string(receive_margin) +
      "ms, terminal=" + (terminal_was_late ? "late" : "normal") +
      ", commit=1";
}

}  // namespace

TestReport run_buffered_e220_integration_test(const std::string& test_id,
                                               std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  const bool transport_gate =
      test_id == "IT-E220-BUFFERED-UPLINK-001";
  const bool rf_heartbeat_red =
      test_id == "IT-E220-BUFFERED-RF-HB-RED-001";
  const bool parameter_priority =
      test_id == "IT-E220-BUFFERED-VEHICLE-PARAM-PRIORITY-001";
  const bool r2_heartbeat_deadline =
      test_id == "IT-E220-BUFFERED-R2-HB-DEADLINE-001";
  if (!transport_gate && !rf_heartbeat_red && !parameter_priority &&
      !r2_heartbeat_deadline) {
    report.check(false, "unknown buffered E220 integration test ID");
    return report;
  }

  BufferedE220UplinkScenario scenario{seed, parameter_priority,
                                      r2_heartbeat_deadline};
  scenario.run(report, rf_heartbeat_red);
  if (!parameter_priority && !r2_heartbeat_deadline) {
    check_two_chunk_service_floor_transaction(report, seed ^ 0x220550U);
  }
  if (transport_gate) {
    check_two_chunk_vehicle_atomic_commit(report, seed ^ 0x45220550U);
  }
  report.expected_failure = rf_heartbeat_red;
  return report;
}

}  // namespace vc_lora::test
