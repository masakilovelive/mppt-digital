#include "integration/uplink_guard_integration_tests.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "fixtures/mavlink_fixtures.hpp"
#include "vc_lora/embedded_io_adapter.hpp"
#include "vc_lora/late_uplink_recovery.hpp"
#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_ground.hpp"
#include "vc_lora/tdd_link_demux.hpp"
#include "vc_lora/tdd_vehicle.hpp"
#include "vc_lora/tx_gate.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint16_t kSession = 0x4102U;
constexpr std::uint16_t kCycle = 7U;

TddInput input_at(std::uint64_t now_ms, std::uint32_t queued_bytes = 0U,
                  std::uint16_t next_application_bytes = 0U,
                  std::uint16_t next_wire_bytes = 0U) noexcept {
  TddInput input{};
  input.now_ms = now_ms;
  input.aux_high = true;
  input.radio_tx_empty = true;
  input.local_tx_empty = true;
  input.queued_bytes = queued_bytes;
  input.next_tx_application_bytes = next_application_bytes;
  input.next_tx_wire_bytes = next_wire_bytes;
  return input;
}

enum class VehicleAdmissionPolicy : std::uint8_t {
  LegacyReceiveStateOnly,
  CurrentControllerWindow,
};

class FirmwareOrderHarness {
 public:
  explicit FirmwareOrderHarness(TestReport& report) noexcept
      : report_(&report), vehicle_(config_, diagnostics_),
        ground_(config_, diagnostics_) {}

  bool prepare_grant_and_guard() {
    // These are the fixed production values.  The regression must reproduce
    // firmware ordering without making the timing profile easier to pass.
    report_->check(config_.downlink_send_ms == 3'000U,
                   "downlink_send_ms changed from the fixed profile");
    report_->check(config_.uplink_guard_ms == 650U,
                   "uplink_guard_ms changed from the fixed profile");
    report_->check(config_.uplink_window_ms == 300U,
                   "uplink_window_ms changed from the fixed profile");
    report_->check(config_.vehicle_receive_timeout_ms == 2'000U,
                   "vehicle_receive_timeout_ms changed from the fixed profile");
    report_->check(config_.return_guard_ms == 650U,
                   "return_guard_ms changed from the fixed profile");
    report_->check(config_.min_tx_gap_ms == 180U &&
                       config_.radio_chunk_bytes == 32U &&
                       config_.uplink_max_bytes == 64U,
                   "fixed E220 chunk/gap/grant values changed");

    vehicle_.reset(kSession, kCycle, 0U);
    ground_.reset(0U);
    (void)vehicle_.tick(input_at(0U));
    (void)vehicle_.tick(input_at(config_.aux_stable_ms));
    (void)vehicle_.tick(input_at(config_.downlink_send_ms));
    (void)vehicle_.tick(input_at(config_.downlink_send_ms + 1U));

    const LinkAction grant =
        vehicle_.tick(input_at(config_.downlink_send_ms + 2U));
    report_->check(grant.type == LinkActionType::SendGrant,
                   "Vehicle did not issue the fixed-profile UL_GRANT");
    if (grant.type != LinkActionType::SendGrant) {
      return false;
    }
    report_->check(TxGate::authorize_vehicle(
                       vehicle_.state(), TxClass::GrantControl, diagnostics_),
                   "Vehicle TX gate rejected its UL_GRANT");
    grant_complete_ms_ = config_.downlink_send_ms + 2U;
    vehicle_.complete_action(grant.token, TxResult::Accepted,
                             grant_complete_ms_);
    report_->check(vehicle_.state() == VehicleTddState::GrantDrain,
                   "Vehicle did not enter GrantDrain after UL_GRANT");

    std::array<std::uint8_t, kTddControlFrameSize> wire{};
    std::size_t wire_size = 0U;
    report_->check(encode_control(grant.control, wire.data(), wire.size(),
                                  wire_size),
                   "UL_GRANT encoding failed");
    bool accepted = false;
    for (std::size_t index = 0U; index < wire_size; ++index) {
      const TddDemuxEvent event = ground_demux_.push(wire[index]);
      diagnostics_.control_bytes_leaked_to_local_uart += event.local_size;
      if (event.has_control) {
        diagnostics_.note_decode_status(event.control.status);
        if (event.control.status == DecodeStatus::Message) {
          accepted = ground_.on_control(event.control.message,
                                        grant_complete_ms_) ==
                     ControlDisposition::Accepted;
        }
      }
    }
    report_->check(accepted, "Ground did not accept the encoded UL_GRANT");
    (void)ground_.tick(input_at(grant_complete_ms_));

    // Model the real firmware loop: the physical GRANT drain completes first,
    // then the Vehicle remains in UplinkGuard until the next scheduled tick.
    grant_drain_complete_ms_ = grant_complete_ms_ + 1U;
    (void)vehicle_.tick(input_at(grant_drain_complete_ms_));
    report_->check(vehicle_.state() == VehicleTddState::UplinkGuard,
                   "Vehicle did not enter UplinkGuard after GrantDrain");
    recovery_.begin(vehicle_.session_id(), vehicle_.cycle_id());
    report_->check(grant_drain_complete_ms_ < ground_.window_deadline_ms(),
                   "grant drain consumed the whole fixed uplink lease");
    return accepted &&
           vehicle_.state() == VehicleTddState::UplinkGuard;
  }

  bool issue_ground_data(const MavlinkFrame& frame,
                         EncodedLinkDataChunk& encoded) {
    encoded = encode_link_data(frame.bytes.data(), frame.size);
    report_->check(frame.message_id == 20U && frame.size == 32U,
                   "regression fixture is not the exact 32-byte msg20");
    report_->check(encoded.input_consumed == frame.size,
                   "msg20 fixture no longer fits one 32-byte E220 write");
    if (encoded.input_consumed != frame.size) {
      return false;
    }

    arrival_ms_ = grant_complete_ms_ + config_.uplink_guard_ms;
    const TddInput ready = input_at(
        arrival_ms_, static_cast<std::uint32_t>(frame.size),
        static_cast<std::uint16_t>(encoded.input_consumed),
        static_cast<std::uint16_t>(encoded.wire_size));
    (void)ground_.tick(ready);
    const LinkAction data = ground_.tick(ready);
    report_->check(data.type == LinkActionType::SendRadioData,
                   "Ground did not issue msg20 at the fixed guard boundary");
    if (data.type != LinkActionType::SendRadioData) {
      return false;
    }
    report_->check(data.byte_budget == frame.size,
                   "Ground changed the exact msg20 application-byte budget");
    report_->check(TxGate::authorize_ground(
                       ground_.state(), TxClass::UplinkData,
                       ground_.has_valid_grant(), arrival_ms_,
                       ground_.window_deadline_ms(), diagnostics_),
                   "Ground TX gate rejected same-cycle msg20");
    data_action_ = data;
    return true;
  }

  void deliver_data(const EncodedLinkDataChunk& encoded,
                    VehicleAdmissionPolicy policy) {
    // Deliberately deliver before vehicle.tick(arrival_ms_).  At the exact
    // boundary the controller still reports UplinkGuard, matching the Arduino
    // loop ordering that exposed the hardware failure.
    report_->check(vehicle_.state() == VehicleTddState::UplinkGuard,
                   "msg20 was not delivered while Vehicle was in UplinkGuard");
    for (std::size_t index = 0U; index < encoded.wire_size; ++index) {
      const TddDemuxEvent event = vehicle_demux_.push(encoded.wire_bytes[index]);
      if (event.has_control) {
        diagnostics_.note_decode_status(event.control.status);
      }
      for (std::size_t local = 0U; local < event.local_size; ++local) {
        const bool admitted =
            policy == VehicleAdmissionPolicy::CurrentControllerWindow
                ? vehicle_.radio_receive_window()
                : vehicle_.state() == VehicleTddState::UplinkReceive;
        if (!admitted) {
          ++diagnostics_.uplink_data_outside_receive_window;
          continue;
        }
        const LateUplinkIngestStatus status =
            recovery_.ingest(event.local_bytes[local]);
        if (status == LateUplinkIngestStatus::Invalid) {
          ++diagnostics_.mavlink_crc_errors;
        } else if (status == LateUplinkIngestStatus::Overflow) {
          ++diagnostics_.uart_buffer_drop_count;
        }
      }
    }
  }

  void complete_data_and_tick() {
    ground_.complete_action(data_action_.token, TxResult::Accepted,
                            arrival_ms_, data_action_.byte_budget);
    // Delivery precedes this tick.  It advances the Vehicle into the ordinary
    // receive state only after all 32 msg20 bytes have been handled.
    (void)vehicle_.tick(input_at(arrival_ms_));
  }

  void issue_and_deliver_done() {
    const std::uint64_t done_ms = arrival_ms_ + config_.min_tx_gap_ms;
    (void)ground_.tick(input_at(done_ms));
    const LinkAction done = ground_.tick(input_at(done_ms));
    report_->check(done.type == LinkActionType::SendDone &&
                       done.control.type == ControlType::UlDone,
                   "Ground did not issue UL_DONE after exact msg20 delivery");
    if (done.type != LinkActionType::SendDone) {
      return;
    }
    report_->check(TxGate::authorize_ground(
                       ground_.state(), TxClass::DoneControl,
                       ground_.has_valid_grant(), done_ms,
                       ground_.window_deadline_ms(), diagnostics_),
                   "Ground TX gate rejected UL_DONE");
    ground_.complete_action(done.token, TxResult::Accepted, done_ms);

    std::array<std::uint8_t, kTddControlFrameSize> wire{};
    std::size_t wire_size = 0U;
    report_->check(encode_control(done.control, wire.data(), wire.size(),
                                  wire_size),
                   "UL_DONE encoding failed");
    ControlDisposition disposition = ControlDisposition::Invalid;
    for (std::size_t index = 0U; index < wire_size; ++index) {
      const TddDemuxEvent event = vehicle_demux_.push(wire[index]);
      diagnostics_.control_bytes_leaked_to_local_uart += event.local_size;
      if (event.has_control) {
        diagnostics_.note_decode_status(event.control.status);
        if (event.control.status == DecodeStatus::Message) {
          const LateUplinkTerminalStatus terminal =
              recovery_.on_terminal(event.control.message);
          if (terminal == LateUplinkTerminalStatus::Ready) {
            disposition = vehicle_.on_control(event.control.message, done_ms);
            std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes>
                committed{};
            std::size_t committed_size = 0U;
            std::uint16_t committed_frames = 0U;
            const bool capacity_ready =
                d6_endpoint_.egress().free_bytes() >=
                recovery_.buffered_bytes();
            report_->check(
                capacity_ready &&
                    recovery_.take_commit(
                        committed.data(), committed.size(), committed_size,
                        committed_frames) &&
                    d6_endpoint_.egress().ingest(
                        committed.data(), committed_size) == committed_size,
                "atomic normal-Guard commit failed after UL_DONE");
            diagnostics_.mavlink_frames_forwarded += committed_frames;
          }
        }
      }
    }
    report_->check(disposition == ControlDisposition::Accepted,
                   "Vehicle did not accept same-cycle UL_DONE");
  }

  std::size_t d6_bytes() const noexcept {
    return d6_endpoint_.egress().queued_bytes();
  }

  std::size_t quarantined_bytes() const noexcept {
    return recovery_.buffered_bytes();
  }

  bool d6_equals(const MavlinkFrame& frame) {
    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> bytes{};
    const std::size_t size =
        d6_endpoint_.egress().peek(bytes.data(), bytes.size());
    MavlinkFrame validated{};
    const MavlinkParseStatus status =
        validate_mavlink_frame(bytes.data(), size, validated);
    if (status == MavlinkParseStatus::FrameReady &&
        validated.message_id == 20U) {
      ++diagnostics_.param_requests_rx;
    }
    return size == frame.size &&
           std::memcmp(bytes.data(), frame.bytes.data(), frame.size) == 0;
  }

  std::uint64_t arrival_ms() const noexcept { return arrival_ms_; }
  const TddConfig& config() const noexcept { return config_; }
  const LinkDiagnostics& diagnostics() const noexcept { return diagnostics_; }
  const VehicleTddController& vehicle() const noexcept { return vehicle_; }
  const GroundTddController& ground() const noexcept { return ground_; }
  const MavlinkValidatedLocalEgressAdapter<>& d6_endpoint() const noexcept {
    return d6_endpoint_;
  }

 private:
  TestReport* report_{nullptr};
  TddConfig config_{};
  LinkDiagnostics diagnostics_{};
  VehicleTddController vehicle_;
  GroundTddController ground_;
  TddLinkDemux vehicle_demux_{true};
  TddLinkDemux ground_demux_{true};
  VehicleLateUplinkRecovery recovery_{};
  MavlinkValidatedLocalEgressAdapter<> d6_endpoint_{};
  LinkAction data_action_{};
  std::uint64_t grant_complete_ms_{0U};
  std::uint64_t grant_drain_complete_ms_{0U};
  std::uint64_t arrival_ms_{0U};
};

void check_zero_fault_invariants(TestReport& report,
                                 const FirmwareOrderHarness& harness) {
  const LinkDiagnostics& d = harness.diagnostics();
  report.check(d.collision_count == 0U,
               "firmware-order regression produced an RF collision");
  report.check(d.half_duplex_drop_count == 0U,
               "firmware-order regression produced a half-duplex drop");
  report.check(d.tx_gate_violation == 0U &&
                   d.ground_tx_without_valid_grant == 0U &&
                   d.tx_during_rx_window_count == 0U,
               "firmware-order regression violated a TX gate");
  report.check(d.control_crc_errors == 0U &&
                   d.mavlink_crc_errors == 0U,
               "valid regression traffic produced a CRC error");
  report.check(d.partial_mavlink_delivered == 0U &&
                   harness.d6_endpoint().parser_buffered_size() == 0U,
               "partial msg20 remained at the Pixhawk D6 boundary");
  report.check(d.control_bytes_leaked_to_local_uart == 0U,
               "UL_GRANT/UL_DONE bytes leaked to a local endpoint");
}

}  // namespace

TestReport run_uplink_guard_integration_test(const std::string& test_id,
                                             std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id != "IT-UPLINK-GUARD-001") {
    report.check(false, "unknown uplink-guard integration test case");
    return report;
  }

  const MavlinkFrame request =
      fixtures::param_request_read_v2(0x5AU, "ARMING_CHECK");

  // Counterfactual RED evidence for the pre-fix predicate.  The old firmware
  // admitted only UplinkReceive, so all exact msg20 bytes were counted outside
  // and the validated D6 queue remained empty.
  FirmwareOrderHarness legacy(report);
  EncodedLinkDataChunk legacy_wire{};
  if (legacy.prepare_grant_and_guard() &&
      legacy.issue_ground_data(request, legacy_wire)) {
    legacy.deliver_data(legacy_wire,
                        VehicleAdmissionPolicy::LegacyReceiveStateOnly);
  }
  report.check(legacy.diagnostics().uplink_data_outside_receive_window ==
                   request.size,
               "legacy receive-only predicate did not reproduce 32 outside bytes");
  report.check(legacy.d6_bytes() == 0U,
               "legacy receive-only predicate unexpectedly queued D6 data");

  // Current production path: the same encoded bytes and deliver-before-tick
  // order are admitted into a transaction quarantine during UplinkGuard.
  // D6 remains empty until a matching same-cycle UL_DONE validates the exact
  // application-byte count.
  FirmwareOrderHarness current(report);
  EncodedLinkDataChunk current_wire{};
  if (current.prepare_grant_and_guard() &&
      current.issue_ground_data(request, current_wire)) {
    current.deliver_data(current_wire,
                         VehicleAdmissionPolicy::CurrentControllerWindow);
    report.check(current.diagnostics()
                         .uplink_data_outside_receive_window == 0U,
                 "current UplinkGuard predicate still counted msg20 outside");
    report.check(current.d6_bytes() == 0U &&
                     current.quarantined_bytes() == request.size,
                 "current Guard path exposed msg20 before UL_DONE");
    current.complete_data_and_tick();
    current.issue_and_deliver_done();
    report.check(current.d6_equals(request),
                 "matching UL_DONE did not atomically queue exact msg20 on D6");
  }

  const LinkDiagnostics& d = current.diagnostics();
  report.check(d.grant_tx == 1U && d.grant_rx == 1U,
               "same-cycle UL_GRANT accounting is not exactly 1/1");
  report.check(d.uplink_transactions == 1U &&
                   d.uplink_payload_bytes == request.size,
               "same-cycle msg20 uplink accounting is not exact");
  report.check(d.param_requests_rx == 1U,
               "validated Pixhawk D6 queue did not contain one msg20");
  report.check(d.done_tx == 1U && d.done_rx == 1U,
               "same-cycle UL_DONE accounting is not exactly 1/1");
  report.check(current.vehicle().state() == VehicleTddState::ReturnGuard,
               "accepted UL_DONE did not move Vehicle to ReturnGuard");
  report.check(current.ground().actual_bytes() == request.size,
               "Ground actual_bytes differs from the exact msg20 length");
  check_zero_fault_invariants(report, current);

  report.cycles = 1U;
  report.vehicle_session = current.vehicle().session_id();
  report.ground_session = current.ground().session_id();
  report.vehicle_cycle = current.vehicle().cycle_id();
  report.ground_cycle = current.ground().cycle_id();
  report.final_vehicle_state = vehicle_state_name(current.vehicle().state());
  report.final_ground_state = ground_state_name(current.ground().state());
  report.diagnostics = current.diagnostics();
  report.detail =
      "deliver-before-tick at fixed 650 ms: legacy outside=32/D6=0; "
      "current msg20 quarantined/DONE-confirmed/atomic D6 commit";
  return report;
}

}  // namespace vc_lora::test
