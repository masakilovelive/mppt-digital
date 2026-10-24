#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <type_traits>

#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/mavlink_frame.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint32_t kGroundBootId = 0x10203040U;
constexpr std::uint16_t kGroundSessionId = 0x5060U;
constexpr std::uint16_t kRequestSequence = 0x1020U;
constexpr std::uint64_t kGroundNonce = 0x0102030405060708ULL;
constexpr std::uint32_t kVehicleBootId = 0x90A0B0C0U;
constexpr std::uint16_t kLeaseSequence = 0x3040U;
constexpr std::uint64_t kVehicleChallenge = 0x1112131415161718ULL;
constexpr std::uint16_t kGrantSession = 0x4040U;
constexpr std::uint16_t kBaselineCycle = 7U;
constexpr std::uint16_t kFreshCycle = 8U;

GroundBulkSessionConfig ground_config(
    BulkSessionFeature feature = BulkSessionFeature::Enabled) noexcept {
  GroundBulkSessionConfig config{};
  config.feature = feature;
  config.ground_boot_id = kGroundBootId;
  config.ground_session_id = kGroundSessionId;
  config.request_sequence = kRequestSequence;
  config.ground_nonce = kGroundNonce;
  return config;
}

VehicleBulkSessionConfig vehicle_config(
    BulkSessionFeature feature = BulkSessionFeature::Enabled) noexcept {
  VehicleBulkSessionConfig config{};
  config.feature = feature;
  config.vehicle_boot_id = kVehicleBootId;
  config.lease_sequence = kLeaseSequence;
  config.vehicle_challenge_nonce = kVehicleChallenge;
  config.mavlink_sequence = 0x55U;
  config.mavlink_system_id = 255U;
  config.mavlink_component_id = 190U;
  return config;
}

MavlinkFrame parameter_request_list(std::uint8_t sequence = 0x44U,
                                    std::uint8_t target_system = 1U,
                                    std::uint8_t target_component = 1U) {
  const std::array<std::uint8_t, 2U> payload{{target_system,
                                              target_component}};
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 21U, payload.data(),
                          payload.size(), frame);
  return frame;
}

bool same_record(const BulkNegotiationFrame& lhs,
                 const BulkNegotiationFrame& rhs) noexcept {
  for (std::size_t index = 0U; index < lhs.size(); ++index) {
    if (lhs[index] != rhs[index]) {
      return false;
    }
  }
  return true;
}

GroundBulkCompletionEvidence ground_completion(
    std::uint32_t transfer_tag) noexcept {
  GroundBulkCompletionEvidence evidence{};
  evidence.transfer_tag = transfer_tag;
  evidence.parameter_count = BulkSessionAccounting::parameter_count;
  evidence.parameter_fragment_count =
      BulkSessionAccounting::parameter_fragment_count;
  evidence.raw_parameter_bytes = BulkSessionAccounting::raw_parameter_bytes;
  evidence.heartbeat_count = 28U;
  evidence.first_heartbeat_gap_ms = 1'050U;
  evidence.max_heartbeat_gap_ms = 1'200U;
  evidence.post_heartbeat_gap_ms = 900U;
  evidence.stream_complete = true;
  evidence.final_parameter_usb_committed = true;
  return evidence;
}

VehicleBulkCompletionEvidence vehicle_completion(
    std::uint32_t transfer_tag) noexcept {
  VehicleBulkCompletionEvidence evidence{};
  evidence.transfer_tag = transfer_tag;
  evidence.parameter_count = BulkSessionAccounting::parameter_count;
  evidence.parameter_fragment_count =
      BulkSessionAccounting::parameter_fragment_count;
  evidence.raw_parameter_bytes = BulkSessionAccounting::raw_parameter_bytes;
  evidence.heartbeat_count = 28U;
  evidence.owner_sealed = true;
  return evidence;
}

BulkSessionTerminalWindowEvidence terminal_window_ready(
    std::uint64_t window_ms, std::uint64_t tail_ms) noexcept {
  BulkSessionTerminalWindowEvidence evidence{};
  evidence.final_tail_drained = true;
  evidence.final_tail_drained_ms = tail_ms;
  evidence.direction_guard_complete = true;
  evidence.direction_guard_completed_ms =
      tail_ms + BulkSessionTiming::direction_guard_ms;
  (void)window_ms;
  return evidence;
}

struct HandshakeFixture final {
  GroundBulkSessionController ground{ground_config()};
  VehicleBulkSessionController vehicle{vehicle_config()};
  MavlinkFrame request{parameter_request_list()};

  bool prepare_request(TestReport& report, std::uint64_t t0 = 100U) {
    report.check(ground.observe_standard_grant(kGrantSession, kBaselineCycle,
                                               t0 - 10U) ==
                     BulkSessionResult::GrantBaselineCaptured,
                 "Ground did not capture the pre-t0 Grant baseline");
    report.check(ground.on_ground_usb_frame(request, t0) ==
                     BulkSessionResult::ParameterRequestHeld,
                 "Ground did not hold the CRC-valid PARAM_REQUEST_LIST");
    report.check(ground.on_fresh_grant(kGrantSession, kFreshCycle,
                                       t0 + 1U) ==
                     BulkSessionResult::NegotiationRequestReady,
                 "Ground did not bind VCBN to the fresh Grant/cycle");
    report.check(vehicle.arm_fresh_grant(kGrantSession, kFreshCycle,
                                         t0 + 1U) ==
                     BulkSessionResult::GrantArmed,
                 "Vehicle did not arm the matching fresh Grant/cycle");
    return report.passed;
  }

  bool deliver_request(TestReport& report, std::uint64_t now = 102U) {
    const BulkNegotiationFrame* record = ground.pending_request_record();
    report.check(record != nullptr, "Ground did not expose its pending VCBN");
    if (record == nullptr) {
      return false;
    }
    report.check(ground.complete_request_tx(TxResult::Accepted, now) ==
                     BulkSessionResult::NegotiationRequestCommitted,
                 "Ground did not commit the terminal VCBN request");
    report.check(vehicle.on_terminal_request(record->data(), record->size(),
                                             now) ==
                     BulkSessionResult::NegotiationResponseReady,
                 "Vehicle did not validate the terminal VCBN request");
    return report.passed;
  }
};

bool reach_local_completion(HandshakeFixture& fixture, TestReport& report,
                            BulkSessionTerminalEvidence& terminal) {
  if (!fixture.prepare_request(report) ||
      !fixture.deliver_request(report, 103U)) {
    return false;
  }
  const BulkNegotiationFrame response =
      *fixture.vehicle.pending_response_record();
  report.check(
      fixture.vehicle.complete_response_tx(TxResult::Accepted, 104U) ==
              BulkSessionResult::NegotiationResponseCommitted &&
          fixture.ground.on_negotiation_response(
              response.data(), response.size(), 104U) ==
              BulkSessionResult::BulkReceiveEnabled &&
          fixture.vehicle.complete_pixhawk_request(TxResult::Accepted, 105U) ==
              BulkSessionResult::BulkDownlinkEnabled &&
          fixture.ground.complete_bulk_receive(
              ground_completion(fixture.ground.transfer_tag()), 106U) ==
              BulkSessionResult::TerminalEvidenceReady &&
          fixture.vehicle.complete_bulk_downlink(
              vehicle_completion(fixture.vehicle.transfer_tag()), 106U) ==
              BulkSessionResult::TerminalEvidenceReady,
      "terminal fixture did not finish the local streams");
  const BulkSessionTerminalEvidence* evidence =
      fixture.ground.terminal_evidence();
  report.check(evidence != nullptr,
               "terminal fixture did not expose Ground evidence");
  if (!report.passed || evidence == nullptr) {
    return false;
  }
  terminal = *evidence;
  return true;
}

bool reach_terminal_window(HandshakeFixture& fixture, TestReport& report,
                           BulkSessionTerminalEvidence& terminal,
                           std::uint64_t window_ms = 206U) {
  if (!reach_local_completion(fixture, report, terminal)) {
    return false;
  }
  report.check(
      // On Ground the final RF tail is necessarily observed before the
      // decoder can finish and index 931 can become host-visible at t1=106.
      // A valid owner must retain that real timestamp instead of fabricating
      // a post-t1 tail.  Vehicle remains sender ordered: completion, then tail.
      fixture.ground.open_terminal_ack_window(terminal_window_ready(window_ms,
                                                                    105U),
                                              window_ms) ==
              BulkSessionResult::TerminalWindowOpened &&
          fixture.vehicle.open_terminal_ack_window(
              terminal_window_ready(window_ms, 106U),
                                                   window_ms) ==
              BulkSessionResult::TerminalWindowOpened,
      "terminal fixture did not open its post-guard ACK window");
  return report.passed;
}

void test_happy_path_and_activation_order(TestReport& report) {
  static_assert(
      !std::is_copy_constructible_v<GroundBulkSessionController> &&
      !std::is_copy_assignable_v<GroundBulkSessionController> &&
      !std::is_move_constructible_v<GroundBulkSessionController> &&
      !std::is_move_assignable_v<GroundBulkSessionController>);
  static_assert(
      !std::is_copy_constructible_v<VehicleBulkSessionController> &&
      !std::is_copy_assignable_v<VehicleBulkSessionController> &&
      !std::is_move_constructible_v<VehicleBulkSessionController> &&
      !std::is_move_assignable_v<VehicleBulkSessionController>);
  HandshakeFixture fixture{};
  if (!fixture.prepare_request(report)) {
    return;
  }

  const BulkNegotiationFrame first_request =
      *fixture.ground.pending_request_record();
  report.check(fixture.ground.complete_request_tx(TxResult::Rejected, 102U) ==
                       BulkSessionResult::RetryRetained &&
                   fixture.ground.pending_request_record() != nullptr &&
                   same_record(first_request,
                               *fixture.ground.pending_request_record()),
               "rejected Ground write did not retain a byte-identical VCBN");
  if (!fixture.deliver_request(report, 103U)) {
    return;
  }

  const BulkNegotiationFrame first_response =
      *fixture.vehicle.pending_response_record();
  report.check(!fixture.vehicle.pixhawk_request_ready() &&
                   !fixture.vehicle.bulk_tx_enabled(),
               "Vehicle exposed Pixhawk/bulk work before response acceptance");
  report.check(
      fixture.vehicle.complete_response_tx(TxResult::Rejected, 104U) ==
              BulkSessionResult::RetryRetained &&
          fixture.vehicle.pending_response_record() != nullptr &&
          same_record(first_response,
                      *fixture.vehicle.pending_response_record()) &&
          !fixture.vehicle.pixhawk_request_ready(),
      "rejected Vehicle write did not retain response or leaked #21");
  report.check(
      fixture.vehicle.complete_response_tx(TxResult::Accepted, 105U) ==
              BulkSessionResult::NegotiationResponseCommitted &&
          fixture.vehicle.pixhawk_request_ready() &&
          !fixture.vehicle.bulk_tx_enabled(),
      "Vehicle did not synthesize #21 strictly after response acceptance");

  const MavlinkFrame* synthesized = fixture.vehicle.pending_pixhawk_request();
  MavlinkFrame validated{};
  report.check(synthesized != nullptr &&
                   validate_mavlink_frame(synthesized->bytes.data(),
                                          synthesized->size, validated) ==
                       MavlinkParseStatus::FrameReady &&
                   validated.message_id == 21U &&
                   validated.payload_byte_or_zero(0U) == 1U &&
                   validated.payload_byte_or_zero(1U) == 1U,
               "Vehicle synthesized an invalid or wrongly targeted #21");

  report.check(!fixture.ground.bulk_receive_enabled(),
               "Ground enabled VCB1 before a correlated Accept");
  report.check(
      fixture.ground.on_negotiation_response(
          first_response.data(), first_response.size(), 106U) ==
              BulkSessionResult::BulkReceiveEnabled &&
          fixture.ground.bulk_receive_enabled(),
      "Ground did not enable VCB1 after the complete correlated Accept");
  report.check(fixture.ground.transfer_tag() != 0U &&
                   fixture.ground.transfer_tag() ==
                       fixture.vehicle.transfer_tag() &&
                   fixture.ground.identity().session_id ==
                       fixture.vehicle.identity().session_id &&
                   fixture.ground.identity().stream_id ==
                       fixture.vehicle.identity().stream_id &&
                   fixture.ground.identity().lease_id ==
                       fixture.vehicle.identity().lease_id,
               "Ground/Vehicle derived different transfer identities");

  const std::uint32_t active_tag = fixture.ground.transfer_tag();
  const MavlinkFrame second_list = parameter_request_list(0x45U, 2U, 3U);
  const std::array<std::uint8_t, 9U> heartbeat_payload{};
  MavlinkFrame other_uplink{};
  (void)encode_mavlink_v2(0x46U, 255U, 190U, 0U,
                          heartbeat_payload.data(), heartbeat_payload.size(),
                          other_uplink);
  report.check(
      fixture.ground.on_ground_usb_frame(second_list, 106U) ==
              BulkSessionResult::BusyHold &&
          fixture.ground.on_ground_usb_frame(other_uplink, 106U) ==
              BulkSessionResult::BusyHold &&
          fixture.ground.transfer_tag() == active_tag &&
          fixture.ground.state() == GroundBulkSessionState::BulkReceive,
      "active session leaked/accepted a second uplink or replaced identity");

  report.check(
      fixture.vehicle.complete_pixhawk_request(TxResult::Accepted, 107U) ==
              BulkSessionResult::BulkDownlinkEnabled &&
          fixture.vehicle.bulk_tx_enabled(),
      "Vehicle enabled bulk TX before the synthesized #21 committed");
  report.check(
      fixture.ground.complete_bulk_receive(
          ground_completion(fixture.ground.transfer_tag()), 108U) ==
              BulkSessionResult::TerminalEvidenceReady &&
          fixture.vehicle.complete_bulk_downlink(
              vehicle_completion(fixture.vehicle.transfer_tag()), 108U) ==
              BulkSessionResult::TerminalEvidenceReady &&
          fixture.ground.has_t1() && fixture.ground.t1_ms() == 108U &&
          fixture.ground.hold_standard_uplink() &&
          !fixture.ground.bulk_receive_enabled() &&
          !fixture.vehicle.bulk_tx_enabled(),
      "local completion bypassed t1 evidence or terminal-ACK wait");
  const BulkSessionTerminalEvidence* terminal =
      fixture.ground.terminal_evidence();
  report.check(terminal != nullptr,
               "Ground did not expose VCTA semantic evidence after t1");
  if (terminal == nullptr) {
    return;
  }
  const BulkSessionTerminalEvidence terminal_copy = *terminal;
  report.check(
      fixture.ground.open_terminal_ack_window(terminal_window_ready(208U,
                                                                    108U),
                                              208U) ==
              BulkSessionResult::TerminalWindowOpened &&
          fixture.vehicle.open_terminal_ack_window(
              terminal_window_ready(208U, 108U),
                                                   208U) ==
              BulkSessionResult::TerminalWindowOpened &&
          fixture.ground.complete_terminal_ack_tx(TxResult::Accepted, 209U) ==
              BulkSessionResult::TerminalAckCommitted &&
          fixture.vehicle.confirm_terminal_ack(terminal_copy, 209U) ==
              BulkSessionResult::SessionComplete &&
          !fixture.ground.hold_standard_uplink(),
      "validated post-t1 terminal evidence did not close both controllers");
}

void test_disabled_gate_and_crc_acceptance(TestReport& report) {
  GroundBulkSessionController disabled_ground{
      ground_config(BulkSessionFeature::Disabled)};
  VehicleBulkSessionController disabled_vehicle{
      vehicle_config(BulkSessionFeature::Disabled)};
  const MavlinkFrame list = parameter_request_list();
  const std::array<std::uint8_t, 4U> junk{{'V', 'C', 'B', 'N'}};
  report.check(disabled_ground.state() == GroundBulkSessionState::Disabled &&
                   disabled_ground.on_ground_usb_frame(list, 1U) ==
                       BulkSessionResult::FeatureDisabled &&
                   !disabled_ground.hold_standard_uplink() &&
                   !disabled_ground.bulk_receive_enabled(),
               "disabled Ground controller changed the standard path");
  report.check(disabled_vehicle.state() == VehicleBulkSessionState::Disabled &&
                   disabled_vehicle.on_terminal_request(junk.data(),
                                                        junk.size(), 1U) ==
                       BulkSessionResult::FeatureDisabled &&
                   !disabled_vehicle.pixhawk_request_ready() &&
                   !disabled_vehicle.bulk_tx_enabled(),
               "disabled Vehicle controller changed the standard path");

  GroundBulkSessionController not_ready{ground_config()};
  report.check(not_ready.on_ground_usb_frame(list, 10U) ==
                       BulkSessionResult::NotHighSpeedReady &&
                   not_ready.state() == GroundBulkSessionState::Standard &&
                   !not_ready.hold_standard_uplink(),
               "Ground intercepted #21 without a pre-t0 Grant baseline");

  GroundBulkSessionController invalid{ground_config()};
  report.check(invalid.observe_standard_grant(kGrantSession, kBaselineCycle,
                                              10U) ==
                   BulkSessionResult::GrantBaselineCaptured,
               "invalid-frame fixture did not become ready");
  MavlinkFrame corrupted = list;
  corrupted.bytes[corrupted.size - 1U] ^= 0x01U;
  report.check(invalid.on_ground_usb_frame(corrupted, 11U) ==
                       BulkSessionResult::InvalidMavlink &&
                   invalid.state() == GroundBulkSessionState::Standard &&
                   !invalid.hold_standard_uplink(),
               "CRC-invalid #21 was held or changed controller state");

  const std::array<std::uint8_t, 9U> heartbeat_payload{};
  MavlinkFrame heartbeat{};
  (void)encode_mavlink_v2(1U, 255U, 190U, 0U, heartbeat_payload.data(),
                          heartbeat_payload.size(), heartbeat);
  report.check(invalid.on_ground_usb_frame(heartbeat, 12U) ==
                       BulkSessionResult::PassThrough &&
                   invalid.state() == GroundBulkSessionState::Standard,
               "non-#21 frame did not remain on the standard path");
}

void test_stale_wrong_crc_and_partial_fail_closed(TestReport& report) {
  {
    GroundBulkSessionController ground{ground_config()};
    const MavlinkFrame list = parameter_request_list();
    report.check(ground.observe_standard_grant(kGrantSession, kBaselineCycle,
                                               1U) ==
                         BulkSessionResult::GrantBaselineCaptured &&
                     ground.on_ground_usb_frame(list, 2U) ==
                         BulkSessionResult::ParameterRequestHeld &&
                     ground.on_fresh_grant(kGrantSession, kBaselineCycle,
                                           3U) ==
                         BulkSessionResult::StaleGrant &&
                     ground.fail_closed() && ground.hold_standard_uplink(),
                 "stale Grant replay did not fail closed with #21 retained");
  }

  {
    HandshakeFixture fixture{};
    if (!fixture.prepare_request(report) ||
        !fixture.deliver_request(report, 103U)) {
      return;
    }
    const BulkNegotiationFrame response =
        *fixture.vehicle.pending_response_record();
    report.check(fixture.ground.on_negotiation_response(
                     response.data(), response.size() - 1U, 104U) ==
                         BulkSessionResult::PartialNegotiationRecord &&
                     fixture.ground.fail_closed() &&
                     !fixture.ground.bulk_receive_enabled() &&
                     fixture.ground.tick(1'000'000U) ==
                         BulkSessionResult::Latched &&
                     fixture.ground.hold_standard_uplink(),
                 "partial response did not latch without timer fallback");
  }

  {
    HandshakeFixture fixture{};
    if (!fixture.prepare_request(report) ||
        !fixture.deliver_request(report, 103U)) {
      return;
    }
    BulkNegotiationFrame corrupt = *fixture.vehicle.pending_response_record();
    corrupt[30U] ^= 0x01U;
    report.check(fixture.ground.on_negotiation_response(
                     corrupt.data(), corrupt.size(), 104U) ==
                         BulkSessionResult::InvalidNegotiationRecord &&
                     fixture.ground.fail_closed(),
                 "CRC-corrupt response did not fail closed");
  }

  {
    HandshakeFixture fixture{};
    if (!fixture.prepare_request(report) ||
        !fixture.deliver_request(report, 103U)) {
      return;
    }
    BulkNegotiationResponse wrong{};
    report.check(
        BulkNegotiationWireCodec::decode_response(
            *fixture.vehicle.pending_response_record(), wrong) ==
            BulkNegotiationWireStatus::FrameReady,
        "wrong-correlation fixture response did not decode");
    ++wrong.request_tag;
    BulkNegotiationFrame wrong_frame{};
    report.check(
        BulkNegotiationWireCodec::encode_response(wrong, wrong_frame) ==
                BulkNegotiationWireStatus::FrameReady &&
            fixture.ground.on_negotiation_response(
                wrong_frame.data(), wrong_frame.size(), 104U) ==
                BulkSessionResult::InvalidNegotiationRecord &&
            fixture.ground.fail_closed(),
        "valid-CRC wrong-correlation response did not fail closed");
  }

  {
    HandshakeFixture fixture{};
    if (!fixture.prepare_request(report) ||
        !fixture.deliver_request(report, 103U)) {
      return;
    }
    BulkNegotiationResponse rejected{};
    report.check(
        BulkNegotiationWireCodec::decode_response(
            *fixture.vehicle.pending_response_record(), rejected) ==
            BulkNegotiationWireStatus::FrameReady,
        "peer-reject fixture response did not decode");
    rejected.status = BulkNegotiationResponseStatus::Busy;
    rejected.lease_sequence = 0U;
    rejected.vehicle_challenge_nonce = 0U;
    BulkNegotiationFrame reject_frame{};
    report.check(
        BulkNegotiationWireCodec::encode_response(rejected, reject_frame) ==
                BulkNegotiationWireStatus::FrameReady &&
            fixture.ground.on_negotiation_response(
                reject_frame.data(), reject_frame.size(), 104U) ==
                BulkSessionResult::PeerRejected &&
            fixture.ground.fail_closed(),
        "correlated peer Reject did not fail Ground closed");
  }

  {
    HandshakeFixture fixture{};
    if (!fixture.prepare_request(report)) {
      return;
    }
    const BulkNegotiationFrame request =
        *fixture.ground.pending_request_record();
    report.check(fixture.vehicle.on_terminal_request(
                     request.data(), request.size() - 1U, 102U) ==
                         BulkSessionResult::PartialNegotiationRecord &&
                     fixture.vehicle.fail_closed() &&
                     !fixture.vehicle.pixhawk_request_ready() &&
                     !fixture.vehicle.bulk_tx_enabled(),
                 "partial terminal request did not fail Vehicle closed");
  }

  {
    HandshakeFixture fixture{};
    if (!fixture.prepare_request(report)) {
      return;
    }
    const BulkNegotiationFrame request =
        *fixture.ground.pending_request_record();
    VehicleBulkSessionController wrong_vehicle{vehicle_config()};
    report.check(wrong_vehicle.arm_fresh_grant(kGrantSession,
                                               kFreshCycle + 1U, 101U) ==
                         BulkSessionResult::GrantArmed &&
                     wrong_vehicle.on_terminal_request(
                         request.data(), request.size(), 102U) ==
                         BulkSessionResult::WrongGrantIdentity &&
                     wrong_vehicle.fail_closed(),
                 "wrong Grant identity did not fail Vehicle closed");
  }
}

void test_hard_lease_and_explicit_rearm(TestReport& report) {
  HandshakeFixture fixture{};
  if (!fixture.prepare_request(report) ||
      !fixture.deliver_request(report, 103U)) {
    return;
  }
  const BulkNegotiationFrame response =
      *fixture.vehicle.pending_response_record();
  report.check(
      fixture.vehicle.complete_response_tx(TxResult::Accepted, 105U) ==
              BulkSessionResult::NegotiationResponseCommitted &&
          fixture.ground.on_negotiation_response(
              response.data(), response.size(), 105U) ==
              BulkSessionResult::BulkReceiveEnabled &&
          fixture.vehicle.complete_pixhawk_request(TxResult::Accepted, 106U) ==
              BulkSessionResult::BulkDownlinkEnabled,
      "lease fixture did not enter bulk mode");

  report.check(fixture.ground.has_t0() && fixture.ground.t0_ms() == 100U &&
                   fixture.ground.lease_epoch_ms() == 100U &&
                   fixture.vehicle.has_lease_epoch() &&
                   fixture.vehicle.lease_epoch_ms() == 103U,
               "hard-lease epochs excluded negotiation time");

  const std::uint64_t ground_boundary =
      100U + BulkSessionTiming::hard_lease_ms;
  const std::uint64_t vehicle_boundary =
      103U + BulkSessionTiming::hard_lease_ms;
  report.check(fixture.ground.tick(ground_boundary) ==
                       BulkSessionResult::NoAction &&
                   fixture.vehicle.tick(ground_boundary) ==
                       BulkSessionResult::NoAction,
               "28-second inclusive boundary expired early");
  report.check(fixture.ground.tick(ground_boundary + 1U) ==
                       BulkSessionResult::LeaseExpired &&
                   fixture.vehicle.tick(vehicle_boundary) ==
                       BulkSessionResult::NoAction &&
                   fixture.vehicle.tick(vehicle_boundary + 1U) ==
                       BulkSessionResult::LeaseExpired &&
                   fixture.ground.fail_closed() &&
                   fixture.vehicle.fail_closed(),
               "28-second hard lease did not fail closed at +1 ms");

  report.check(fixture.ground.rearm(kRequestSequence, kGroundNonce,
                                    vehicle_boundary + 2U) ==
                       BulkSessionResult::IdentityReuse &&
                   fixture.ground.fail_closed(),
               "Ground rearm accepted reused request identity");
  report.check(fixture.ground.rearm(kRequestSequence + 1U,
                                    kGroundNonce + 1U,
                                    vehicle_boundary + 3U) ==
                       BulkSessionResult::Rearmed &&
                   fixture.ground.state() ==
                       GroundBulkSessionState::Standard &&
                   !fixture.ground.hold_standard_uplink(),
               "Ground explicit fresh rearm failed");
  report.check(fixture.vehicle.rearm(kLeaseSequence, kVehicleChallenge,
                                     0x56U, vehicle_boundary + 2U) ==
                       BulkSessionResult::IdentityReuse &&
                   fixture.vehicle.fail_closed(),
               "Vehicle rearm accepted reused lease identity");
  report.check(fixture.vehicle.rearm(kLeaseSequence + 1U,
                                     kVehicleChallenge + 1U, 0x56U,
                                     vehicle_boundary + 3U) ==
                       BulkSessionResult::Rearmed &&
                   fixture.vehicle.state() ==
                       VehicleBulkSessionState::AwaitGrant,
               "Vehicle explicit fresh rearm failed");
}

void test_no_timer_fallback_and_replay(TestReport& report) {
  HandshakeFixture fixture{};
  if (!fixture.prepare_request(report) ||
      !fixture.deliver_request(report, 103U)) {
    return;
  }
  const BulkNegotiationFrame request =
      *fixture.ground.committed_request_record();
  report.check(fixture.ground.tick(1'100U) ==
                       BulkSessionResult::NoAction &&
                   fixture.ground.state() ==
                       GroundBulkSessionState::AwaitResponse &&
                   fixture.ground.hold_standard_uplink(),
               "negotiation timer silently fell back to standard uplink");

  report.check(
      fixture.vehicle.on_terminal_request(request.data(), request.size(),
                                          104U) ==
              BulkSessionResult::NegotiationResponseReady,
      "exact request retry before response commit was not idempotent");
  report.check(
      fixture.vehicle.complete_response_tx(TxResult::Accepted, 105U) ==
              BulkSessionResult::NegotiationResponseCommitted &&
          fixture.vehicle.on_terminal_request(request.data(), request.size(),
                                              106U) ==
              BulkSessionResult::ReplayDetected &&
          fixture.vehicle.fail_closed() &&
          !fixture.vehicle.bulk_tx_enabled(),
      "post-commit request replay did not fail Vehicle closed");

  {
    GroundBulkSessionController on_boundary{ground_config()};
    GroundBulkSessionController late{ground_config()};
    const MavlinkFrame list = parameter_request_list();
    report.check(
        on_boundary.observe_standard_grant(kGrantSession, kBaselineCycle,
                                           2'000U) ==
                BulkSessionResult::GrantBaselineCaptured &&
            on_boundary.on_ground_usb_frame(list, 2'010U) ==
                BulkSessionResult::ParameterRequestHeld &&
            on_boundary.on_fresh_grant(
                kGrantSession, kFreshCycle,
                2'010U + BulkSessionTiming::grant_wait_budget_ms) ==
                BulkSessionResult::NegotiationRequestReady,
        "t0+500ms fresh Grant was not accepted inclusively");
    report.check(
        late.observe_standard_grant(kGrantSession, kBaselineCycle, 3'000U) ==
                BulkSessionResult::GrantBaselineCaptured &&
            late.on_ground_usb_frame(list, 3'010U) ==
                BulkSessionResult::ParameterRequestHeld &&
            late.on_fresh_grant(
                kGrantSession, kFreshCycle,
                3'011U + BulkSessionTiming::grant_wait_budget_ms) ==
                BulkSessionResult::GrantDeadlineExceeded &&
            late.fail_closed() && late.hold_standard_uplink(),
        "t0+501ms fresh Grant did not fail closed");
  }

  {
    GroundBulkSessionController clock_ground{ground_config()};
    VehicleBulkSessionController clock_vehicle{vehicle_config()};
    report.check(clock_ground.observe_standard_grant(
                     kGrantSession, kBaselineCycle, 5'000U) ==
                         BulkSessionResult::GrantBaselineCaptured &&
                     clock_ground.on_ground_usb_frame(
                         parameter_request_list(), 4'999U) ==
                         BulkSessionResult::ClockRegression &&
                     clock_ground.fail_closed(),
                 "Ground clock regression did not fail closed");
    report.check(clock_vehicle.arm_fresh_grant(kGrantSession, kFreshCycle,
                                               5'000U) ==
                         BulkSessionResult::GrantArmed &&
                     clock_vehicle.tick(4'999U) ==
                         BulkSessionResult::ClockRegression &&
                     clock_vehicle.fail_closed(),
                 "Vehicle clock regression did not fail closed");
  }

  {
    HandshakeFixture wrong_ground{};
    if (!wrong_ground.prepare_request(report) ||
        !wrong_ground.deliver_request(report, 103U)) {
      return;
    }
    const BulkNegotiationFrame response =
        *wrong_ground.vehicle.pending_response_record();
    report.check(
        wrong_ground.vehicle.complete_response_tx(TxResult::Accepted, 104U) ==
                BulkSessionResult::NegotiationResponseCommitted &&
            wrong_ground.ground.on_negotiation_response(
                response.data(), response.size(), 104U) ==
                BulkSessionResult::BulkReceiveEnabled,
        "Ground evidence mismatch fixture did not activate");
    GroundBulkCompletionEvidence wrong =
        ground_completion(wrong_ground.ground.transfer_tag());
    --wrong.parameter_count;
    report.check(
        wrong_ground.ground.complete_bulk_receive(wrong, 105U) ==
                BulkSessionResult::CompletionEvidenceMismatch &&
            wrong_ground.ground.fail_closed(),
        "Ground accepted completion without exact tag/932 accounting");
  }

  {
    HandshakeFixture wrong_vehicle{};
    if (!wrong_vehicle.prepare_request(report) ||
        !wrong_vehicle.deliver_request(report, 103U)) {
      return;
    }
    report.check(
        wrong_vehicle.vehicle.complete_response_tx(TxResult::Accepted, 104U) ==
                BulkSessionResult::NegotiationResponseCommitted &&
            wrong_vehicle.vehicle.complete_pixhawk_request(TxResult::Accepted,
                                                           105U) ==
                BulkSessionResult::BulkDownlinkEnabled,
        "Vehicle evidence mismatch fixture did not activate");
    VehicleBulkCompletionEvidence wrong =
        vehicle_completion(wrong_vehicle.vehicle.transfer_tag() ^ 1U);
    report.check(
        wrong_vehicle.vehicle.complete_bulk_downlink(wrong, 106U) ==
                BulkSessionResult::CompletionEvidenceMismatch &&
            wrong_vehicle.vehicle.fail_closed(),
        "Vehicle accepted completion with the wrong transfer tag");
  }

  {
    HandshakeFixture missing_usb_commit{};
    if (!missing_usb_commit.prepare_request(report) ||
        !missing_usb_commit.deliver_request(report, 103U)) {
      return;
    }
    const BulkNegotiationFrame response =
        *missing_usb_commit.vehicle.pending_response_record();
    report.check(
        missing_usb_commit.vehicle.complete_response_tx(TxResult::Accepted,
                                                        104U) ==
                BulkSessionResult::NegotiationResponseCommitted &&
            missing_usb_commit.ground.on_negotiation_response(
                response.data(), response.size(), 104U) ==
                BulkSessionResult::BulkReceiveEnabled,
        "USB-commit evidence fixture did not activate");
    GroundBulkCompletionEvidence incomplete =
        ground_completion(missing_usb_commit.ground.transfer_tag());
    incomplete.final_parameter_usb_committed = false;
    report.check(
        missing_usb_commit.ground.complete_bulk_receive(incomplete, 105U) ==
                BulkSessionResult::CompletionEvidenceMismatch &&
            missing_usb_commit.ground.fail_closed() &&
            !missing_usb_commit.ground.has_t1(),
        "decoder completion without final host USB commit created t1");
  }

  // Every terminal identity/accounting/heartbeat field is consumed from the
  // decoded VCTA semantic record. A locally reconstructed or partly matching
  // record must not close Vehicle.
  for (std::uint8_t variant = 0U; variant < 15U; ++variant) {
    HandshakeFixture terminal_fixture{};
    BulkSessionTerminalEvidence wrong{};
    if (!reach_terminal_window(terminal_fixture, report, wrong)) {
      return;
    }
    switch (variant) {
      case 0U:
        ++wrong.identity.session_id;
        break;
      case 1U:
        ++wrong.identity.stream_id;
        break;
      case 2U:
        ++wrong.identity.lease_id;
        break;
      case 3U:
        ++wrong.identity.ground_request_nonce;
        break;
      case 4U:
        ++wrong.identity.vehicle_challenge_nonce;
        break;
      case 5U:
        wrong.transfer_tag ^= 1U;
        break;
      case 6U:
        --wrong.parameter_count;
        break;
      case 7U:
        --wrong.parameter_fragment_count;
        break;
      case 8U:
        --wrong.raw_parameter_bytes;
        break;
      case 9U:
        --wrong.heartbeat_count;
        break;
      case 10U:
        wrong.first_heartbeat_gap_ms =
            BulkSessionAccounting::heartbeat_deadline_ms + 1U;
        break;
      case 11U:
        wrong.max_heartbeat_gap_ms =
            BulkSessionAccounting::heartbeat_deadline_ms + 1U;
        break;
      case 12U:
        wrong.post_heartbeat_gap_ms =
            BulkSessionAccounting::heartbeat_deadline_ms + 1U;
        break;
      case 13U:
        wrong.final_parameter_usb_committed = false;
        break;
      case 14U:
        wrong.ground_stream_complete = false;
        break;
      default:
        break;
    }
    report.check(
        terminal_fixture.vehicle.confirm_terminal_ack(wrong, 207U) ==
                BulkSessionResult::TerminalEvidenceMismatch &&
            terminal_fixture.vehicle.fail_closed(),
        "Vehicle accepted a VCTA record with one wrong semantic field");
    if (!report.passed) {
      return;
    }
  }

  {
    HandshakeFixture transition_timeout{};
    BulkSessionTerminalEvidence terminal{};
    if (!reach_local_completion(transition_timeout, report, terminal)) {
      return;
    }
    constexpr std::uint64_t kLocalCompletionMs = 106U;
    const std::uint64_t boundary =
        kLocalCompletionMs +
        BulkSessionTiming::terminal_transition_timeout_ms;
    report.check(
        transition_timeout.ground.tick(boundary) ==
                BulkSessionResult::NoAction &&
            transition_timeout.vehicle.tick(boundary) ==
                BulkSessionResult::NoAction,
        "terminal transition expired at its inclusive boundary");
    report.check(
        transition_timeout.ground.tick(boundary + 1U) ==
                BulkSessionResult::TerminalWindowTimeout &&
            transition_timeout.vehicle.tick(boundary + 1U) ==
                BulkSessionResult::TerminalWindowTimeout &&
            transition_timeout.ground.fail_closed() &&
            transition_timeout.vehicle.fail_closed(),
        "local completion could wait indefinitely for the terminal window");
  }

  {
    HandshakeFixture late_window{};
    BulkSessionTerminalEvidence terminal{};
    if (!reach_local_completion(late_window, report, terminal)) {
      return;
    }
    constexpr std::uint64_t kLateWindowMs =
        106U + BulkSessionTiming::terminal_transition_timeout_ms + 1U;
    report.check(
        late_window.ground.open_terminal_ack_window(
            terminal_window_ready(kLateWindowMs, 105U), kLateWindowMs) ==
                BulkSessionResult::TerminalWindowTimeout &&
            late_window.vehicle.open_terminal_ack_window(
                terminal_window_ready(kLateWindowMs, 106U), kLateWindowMs) ==
                BulkSessionResult::TerminalWindowTimeout &&
            late_window.ground.fail_closed() &&
            late_window.vehicle.fail_closed(),
        "a late terminal-window event bypassed the transition deadline");
  }

  {
    HandshakeFixture timeout{};
    BulkSessionTerminalEvidence terminal{};
    constexpr std::uint64_t kWindowOpenedMs = 206U;
    if (!reach_terminal_window(timeout, report, terminal,
                               kWindowOpenedMs)) {
      return;
    }
    const std::uint64_t boundary =
        kWindowOpenedMs + BulkSessionTiming::terminal_ack_timeout_ms;
    report.check(
        timeout.ground.tick(boundary) == BulkSessionResult::NoAction &&
            timeout.vehicle.tick(boundary) == BulkSessionResult::NoAction,
        "terminal ACK window expired at its inclusive boundary");
    report.check(
        timeout.ground.tick(boundary + 1U) ==
                BulkSessionResult::TerminalAckTimeout &&
            timeout.vehicle.tick(boundary + 1U) ==
                BulkSessionResult::TerminalAckTimeout &&
            timeout.ground.fail_closed() && timeout.vehicle.fail_closed(),
        "terminal ACK window did not fail closed at +1 ms");
  }

  {
    HandshakeFixture premature_window{};
    if (!premature_window.prepare_request(report) ||
        !premature_window.deliver_request(report, 103U)) {
      return;
    }
    const BulkNegotiationFrame response =
        *premature_window.vehicle.pending_response_record();
    report.check(
        premature_window.vehicle.complete_response_tx(TxResult::Accepted,
                                                       104U) ==
                BulkSessionResult::NegotiationResponseCommitted &&
            premature_window.ground.on_negotiation_response(
                response.data(), response.size(), 104U) ==
                BulkSessionResult::BulkReceiveEnabled &&
            premature_window.vehicle.complete_pixhawk_request(
                TxResult::Accepted, 105U) ==
                BulkSessionResult::BulkDownlinkEnabled &&
            premature_window.ground.complete_bulk_receive(
                ground_completion(premature_window.ground.transfer_tag()),
                106U) == BulkSessionResult::TerminalEvidenceReady &&
            premature_window.vehicle.complete_bulk_downlink(
                vehicle_completion(premature_window.vehicle.transfer_tag()),
                106U) == BulkSessionResult::TerminalEvidenceReady,
        "premature-window fixture did not reach local completion");
    BulkSessionTerminalWindowEvidence incomplete =
        terminal_window_ready(206U, 106U);
    incomplete.direction_guard_complete = false;
    report.check(
        premature_window.ground.open_terminal_ack_window(incomplete, 107U) ==
                BulkSessionResult::TerminalWindowEvidenceMismatch &&
            premature_window.vehicle.open_terminal_ack_window(incomplete,
                                                              107U) ==
                BulkSessionResult::TerminalWindowEvidenceMismatch &&
            premature_window.ground.fail_closed() &&
            premature_window.vehicle.fail_closed(),
        "terminal window opened before tail drain/direction guard evidence");
  }
}

}  // namespace

TestReport run_bulk_session_controller_test(const std::string& test_id,
                                            std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-BULK-SESSION-001") {
    test_happy_path_and_activation_order(report);
  } else if (test_id == "UT-BULK-SESSION-002") {
    test_disabled_gate_and_crc_acceptance(report);
  } else if (test_id == "UT-BULK-SESSION-003") {
    test_stale_wrong_crc_and_partial_fail_closed(report);
  } else if (test_id == "UT-BULK-SESSION-004") {
    test_hard_lease_and_explicit_rearm(report);
  } else if (test_id == "UT-BULK-SESSION-005") {
    test_no_timer_fallback_and_replay(report);
  } else {
    report.check(false, "unknown bulk session controller test ID");
  }

  report.trace.record({0U, "host", "BULK_SESSION", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
