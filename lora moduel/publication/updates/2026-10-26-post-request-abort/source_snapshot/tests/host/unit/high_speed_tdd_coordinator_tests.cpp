#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <type_traits>

#include "test_support.hpp"
#include "vc_lora/bulk_data_codec.hpp"
#include "vc_lora/high_speed_tdd_coordinator.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_control_codec.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint16_t kGrantSession = 0x4040U;
constexpr std::uint16_t kGrantCycle = 8U;
constexpr std::uint64_t kGroundT0 = 0U;

struct WireFixture final {
  BulkNegotiationFrame request{};
  BulkNegotiationFrame response{};
  BulkNegotiationIdentity identity{};
  std::uint32_t transfer_tag{0U};
  std::array<std::uint8_t, kTddControlFrameSize> grant{};
  MavlinkFrame pixhawk_request{};
  BulkDataFragment bulk_fragment{};
  HighSpeedTerminalFragments terminal{};
  bool valid{false};

  WireFixture() {
    BulkNegotiationRequest request_value{};
    request_value.ground_boot_id = 0x10203040U;
    request_value.ground_session_id = 0x5060U;
    request_value.request_sequence = 0x1020U;
    request_value.ground_nonce = 0x0102030405060708ULL;
    request_value.target_system = 1U;
    request_value.target_component = 1U;
    request_value.captured_vehicle_grant_session = kGrantSession;
    request_value.captured_vehicle_grant_cycle = kGrantCycle;
    if (BulkNegotiationWireCodec::encode_request(request_value, request) !=
        BulkNegotiationWireStatus::FrameReady) {
      return;
    }

    std::uint32_t request_tag = 0U;
    if (BulkNegotiationWireCodec::derive_request_tag(request, request_tag) !=
        BulkNegotiationWireStatus::RequestTagReady) {
      return;
    }
    BulkNegotiationResponse response_value{};
    response_value.status = BulkNegotiationResponseStatus::Accept;
    response_value.vehicle_boot_id = 0x90A0B0C0U;
    response_value.vehicle_session_id = kGrantSession;
    response_value.lease_sequence = 0x3040U;
    response_value.vehicle_challenge_nonce = 0x1112131415161718ULL;
    response_value.request_tag = request_tag;
    response_value.echoed_vehicle_grant_cycle = kGrantCycle;
    if (BulkNegotiationWireCodec::encode_response(response_value, response) !=
            BulkNegotiationWireStatus::FrameReady ||
        BulkNegotiationWireCodec::derive_accepted_transfer(
            request, response, identity, transfer_tag) !=
            BulkNegotiationWireStatus::TransferReady) {
      return;
    }

    TddControlMessage grant_value{};
    grant_value.type = ControlType::UlGrant;
    grant_value.session_id = kGrantSession;
    grant_value.cycle_id = kGrantCycle;
    grant_value.guard_ms = 10U;
    grant_value.window_ms = 500U;
    grant_value.max_bytes = 32U;
    std::size_t grant_size = 0U;
    if (!encode_control(grant_value, grant.data(), grant.size(), grant_size) ||
        grant_size != grant.size()) {
      return;
    }

    const std::array<std::uint8_t, 2U> request_payload{{1U, 1U}};
    if (!encode_mavlink_v2(0x55U, 255U, 190U, 21U, request_payload.data(),
                           request_payload.size(), pixhawk_request)) {
      return;
    }
    const std::array<std::uint8_t, 19U> fragment_payload{};
    if (BulkDataWireCodec::encode_fragment(
            BulkDataFragmentKind::ParameterHead, transfer_tag, 0U,
            fragment_payload.data(), fragment_payload.size(),
            bulk_fragment) != BulkDataWireStatus::FragmentReady) {
      return;
    }

    constexpr std::uint32_t record_tag = 0xA1B2C3D4U;
    for (std::size_t index = 0U; index < terminal.size(); ++index) {
      auto& fragment = terminal[index];
      fragment.fill(0U);
      fragment[0] = 'V';
      fragment[1] = 'C';
      fragment[2] = 'T';
      fragment[3] = 'A';
      fragment[4] = 1U;
      fragment[5] = static_cast<std::uint8_t>(index);
      fragment[6] = static_cast<std::uint8_t>(terminal.size());
      fragment[8] = static_cast<std::uint8_t>(record_tag & 0xFFU);
      fragment[9] = static_cast<std::uint8_t>((record_tag >> 8U) & 0xFFU);
      fragment[10] = static_cast<std::uint8_t>((record_tag >> 16U) & 0xFFU);
      fragment[11] = static_cast<std::uint8_t>((record_tag >> 24U) & 0xFFU);
      fragment[12] = static_cast<std::uint8_t>(index + 1U);
      const std::uint16_t crc =
          crc16_ccitt_false(fragment.data(), fragment.size() - 2U);
      fragment[30] = static_cast<std::uint8_t>(crc & 0xFFU);
      fragment[31] = static_cast<std::uint8_t>((crc >> 8U) & 0xFFU);
    }
    valid = true;
  }
};

GroundBulkCompletionEvidence ground_evidence(std::uint32_t tag) noexcept {
  GroundBulkCompletionEvidence evidence{};
  evidence.transfer_tag = tag;
  evidence.parameter_count = BulkSessionAccounting::parameter_count;
  evidence.parameter_fragment_count =
      BulkSessionAccounting::parameter_fragment_count;
  evidence.raw_parameter_bytes = BulkSessionAccounting::raw_parameter_bytes;
  evidence.heartbeat_count = 28U;
  evidence.first_heartbeat_gap_ms = 1000U;
  evidence.max_heartbeat_gap_ms = 1200U;
  evidence.post_heartbeat_gap_ms = 900U;
  evidence.stream_complete = true;
  evidence.final_parameter_usb_committed = true;
  return evidence;
}

VehicleBulkCompletionEvidence vehicle_evidence(std::uint32_t tag) noexcept {
  VehicleBulkCompletionEvidence evidence{};
  evidence.transfer_tag = tag;
  evidence.parameter_count = BulkSessionAccounting::parameter_count;
  evidence.parameter_fragment_count =
      BulkSessionAccounting::parameter_fragment_count;
  evidence.raw_parameter_bytes = BulkSessionAccounting::raw_parameter_bytes;
  evidence.heartbeat_count = 28U;
  evidence.owner_sealed = true;
  return evidence;
}

HighSpeedTailDrainEvidence action_tail(const HighSpeedAction& action,
                                       std::uint64_t completed_ms) noexcept {
  HighSpeedTailDrainEvidence evidence{};
  evidence.action_token = action.token;
  evidence.physical_tail_complete = true;
  evidence.completed_ms = completed_ms;
  return evidence;
}

HighSpeedStandardGrantEvidence retained_grant_tail(
    std::uint64_t completed_ms,
    std::uint16_t session_id = kGrantSession,
    std::uint16_t cycle_id = kGrantCycle) noexcept {
  HighSpeedStandardGrantEvidence evidence{};
  evidence.grant_session_id = session_id;
  evidence.grant_cycle_id = cycle_id;
  evidence.writer_token = 0xA5A5U;
  evidence.writer_generation = 1U;
  evidence.accepted = true;
  evidence.physical_tail_complete = true;
  evidence.completed_ms = completed_ms;
  return evidence;
}

HighSpeedLocalRxRecordIdentity local_rx_record(
    std::uint32_t transfer_tag, std::uint32_t token,
    std::uint32_t generation) noexcept {
  HighSpeedLocalRxRecordIdentity identity{};
  identity.transfer_tag = transfer_tag;
  identity.final_wire_ordinal = 1919U;
  identity.fragment_count = 1920U;
  identity.rx_record_token = token;
  identity.rx_ledger_generation = generation;
  return identity;
}

HighSpeedStreamTailEvidence stream_tail(std::uint32_t tag,
                                        std::uint32_t writer_token,
                                        std::uint32_t writer_generation,
                                        std::uint64_t completed_ms) noexcept {
  HighSpeedStreamTailEvidence evidence{};
  evidence.transfer_tag = tag;
  evidence.final_wire_ordinal = 1919U;
  evidence.fragment_count = 1920U;
  evidence.writer_token = writer_token;
  evidence.writer_generation = writer_generation;
  evidence.physical_tail_complete = true;
  evidence.completed_ms = completed_ms;
  return evidence;
}

bool same_action_bytes(const HighSpeedAction& lhs,
                       const HighSpeedAction& rhs) noexcept {
  if (lhs.type != rhs.type || lhs.size != rhs.size) {
    return false;
  }
  for (std::size_t index = 0U; index < lhs.size; ++index) {
    if (lhs.bytes[index] != rhs.bytes[index]) {
      return false;
    }
  }
  return true;
}

BulkDataFragment make_bulk_fragment(BulkDataFragmentKind kind,
                                    std::uint32_t transfer_tag,
                                    std::uint16_t wire_ordinal) noexcept {
  BulkDataFragment fragment{};
  std::array<std::uint8_t, BulkDataWireCodec::payload_bytes> payload{};
  for (std::size_t index = 0U; index < payload.size(); ++index) {
    payload[index] = static_cast<std::uint8_t>(index + 1U);
  }
  const std::size_t payload_size =
      BulkDataWireCodec::required_payload_size(kind);
  if (BulkDataWireCodec::encode_fragment(
          kind, transfer_tag, wire_ordinal, payload.data(), payload_size,
          fragment) != BulkDataWireStatus::FragmentReady) {
    fragment = {};
  }
  return fragment;
}

bool start_ground_bulk(GroundHighSpeedTddCoordinator& ground,
                       const WireFixture& wire, TestReport& report,
                       std::uint64_t grant_ms = 1U) {
  report.check(ground.begin_parameter_request(
                   BulkSessionResult::ParameterRequestHeld, kGroundT0) ==
                       HighSpeedCoordinatorResult::Ready &&
                   ground.stage_fresh_grant(
                       BulkSessionResult::NegotiationRequestReady, wire.request,
                       grant_ms) == HighSpeedCoordinatorResult::Ready,
               "Ground did not stage VCBN after held #21 and fresh Grant");
  HighSpeedAction request =
      ground.poll(grant_ms + BulkSessionTiming::direction_guard_ms);
  report.check(
      request.type == HighSpeedActionType::SendNegotiationRequest &&
          ground.complete_action(request.token, TxResult::Accepted,
                                 grant_ms + 101U) ==
              HighSpeedCoordinatorResult::Accepted &&
          ground.confirm_request_commit(
              BulkSessionResult::NegotiationRequestCommitted,
              grant_ms + 101U) == HighSpeedCoordinatorResult::AwaitingPeer &&
          ground.observe_action_tail_drained(
              action_tail(request, grant_ms + 102U), grant_ms + 102U) ==
              HighSpeedCoordinatorResult::TailDrainAccepted &&
          ground.on_negotiation_response(BulkSessionResult::BulkReceiveEnabled,
                                         wire.transfer_tag, grant_ms + 103U) ==
              HighSpeedCoordinatorResult::BulkEnabled,
      "Ground did not commit/drain VCBN before bulk receive");
  return report.passed;
}

bool start_vehicle_bulk(VehicleHighSpeedTddCoordinator& vehicle,
                         const WireFixture& wire, TestReport& report,
                         std::uint64_t grant_ms = 1U) {
  const HighSpeedStandardGrantEvidence grant_evidence =
      retained_grant_tail(grant_ms);
  const std::uint64_t request_tail_ms = grant_ms + 1U;
  report.check(
      vehicle.adopt_retained_grant_on_terminal_request(
          BulkSessionResult::GrantArmed,
          BulkSessionResult::NegotiationResponseReady, wire.grant,
          grant_evidence, wire.request, wire.response, wire.transfer_tag,
          request_tail_ms) ==
              HighSpeedCoordinatorResult::Ready &&
          vehicle.poll(request_tail_ms).type == HighSpeedActionType::None,
      "Vehicle did not atomically adopt the retained Grant at VCBN arrival");
  HighSpeedAction response =
      vehicle.poll(request_tail_ms + BulkSessionTiming::direction_guard_ms);
  report.check(
      response.type == HighSpeedActionType::SendNegotiationResponse &&
          vehicle.complete_action(response.token, TxResult::Accepted,
                                  grant_ms + 102U) ==
              HighSpeedCoordinatorResult::Accepted &&
          vehicle.stage_pixhawk_request(
              BulkSessionResult::NegotiationResponseCommitted,
              wire.pixhawk_request,
              grant_ms + 102U) == HighSpeedCoordinatorResult::AwaitingPeer &&
          vehicle.observe_action_tail_drained(
              action_tail(response, grant_ms + 103U), grant_ms + 103U) ==
              HighSpeedCoordinatorResult::TailDrainAccepted,
      "Vehicle exposed #21 before accepted/drained VCBN response");
  HighSpeedAction pixhawk = vehicle.poll(grant_ms + 103U);
  report.check(
      pixhawk.type == HighSpeedActionType::SendPixhawkParameterRequest &&
          vehicle.complete_action(pixhawk.token, TxResult::Accepted,
                                  grant_ms + 104U) ==
              HighSpeedCoordinatorResult::Accepted &&
          vehicle.confirm_pixhawk_request(
              BulkSessionResult::BulkDownlinkEnabled, grant_ms + 104U) ==
              HighSpeedCoordinatorResult::BulkEnabled,
      "Vehicle did not fence VCB1 behind accepted Pixhawk #21");
  return report.passed;
}

bool send_complete_bulk_stream(VehicleHighSpeedTddCoordinator& vehicle,
                               const WireFixture& wire, TestReport& report,
                               HighSpeedAction& final_action,
                               std::uint64_t now_ms) {
  std::uint32_t next_ordinal = 0U;
  auto send = [&](BulkDataFragmentKind kind) {
    if (next_ordinal >
        static_cast<std::uint32_t>(std::numeric_limits<std::uint16_t>::max())) {
      return false;
    }
    const BulkDataFragment fragment = make_bulk_fragment(
        kind, wire.transfer_tag, static_cast<std::uint16_t>(next_ordinal));
    if (vehicle.stage_bulk_fragment(fragment, now_ms) !=
        HighSpeedCoordinatorResult::ActionReady) {
      return false;
    }
    const HighSpeedAction action = vehicle.poll(now_ms);
    if (action.type != HighSpeedActionType::SendBulkFragment ||
        action.size != fragment.size() || action.bytes != fragment ||
        vehicle.complete_action(action.token, TxResult::Accepted, now_ms) !=
            HighSpeedCoordinatorResult::Accepted) {
      return false;
    }
    final_action = action;
    ++next_ordinal;
    return true;
  };

  bool accepted = true;
  for (std::uint32_t parameter = 0U;
       parameter < BulkSessionAccounting::parameter_count && accepted;
       ++parameter) {
    accepted = send(BulkDataFragmentKind::ParameterHead) &&
               send(BulkDataFragmentKind::ParameterTail);
  }
  for (std::uint32_t heartbeat = 0U; heartbeat < 28U && accepted; ++heartbeat) {
    accepted = send(BulkDataFragmentKind::HeartbeatHead) &&
               send(BulkDataFragmentKind::HeartbeatTail);
  }
  report.check(accepted && final_action.token != 0U && next_ordinal == 1920U,
               "Vehicle did not accept the exact ordered "
               "932-parameter/28-heartbeat stream");
  return report.passed;
}

bool finish_vehicle_to_window(VehicleHighSpeedTddCoordinator& vehicle,
                              const WireFixture& wire, TestReport& report,
                              std::uint64_t bulk_ms = 200U) {
  HighSpeedAction bulk{};
  if (!send_complete_bulk_stream(vehicle, wire, report, bulk, bulk_ms)) {
    return false;
  }
  report.check(
      vehicle.complete_bulk_downlink(BulkSessionResult::TerminalEvidenceReady,
                                     vehicle_evidence(wire.transfer_tag),
                                     bulk_ms + 2U) ==
              HighSpeedCoordinatorResult::TerminalWindowReady &&
          vehicle.observe_bulk_tail_drained(
              stream_tail(wire.transfer_tag, bulk.token, bulk.writer_generation,
                          bulk_ms + 3U),
              bulk_ms + 3U) == HighSpeedCoordinatorResult::TailDrainAccepted,
      "Vehicle did not bind local completion to the final VCB1 tail");
  return report.passed;
}

bool prepare_vehicle_await_bulk_tail(VehicleHighSpeedTddCoordinator& vehicle,
                                     const WireFixture& wire,
                                     TestReport& report,
                                     HighSpeedAction& final_action,
                                     std::uint64_t bulk_ms = 200U) {
  if (!start_vehicle_bulk(vehicle, wire, report) ||
      !send_complete_bulk_stream(vehicle, wire, report, final_action,
                                 bulk_ms)) {
    return false;
  }
  report.check(vehicle.complete_bulk_downlink(
                   BulkSessionResult::TerminalEvidenceReady,
                   vehicle_evidence(wire.transfer_tag), bulk_ms + 2U) ==
                   HighSpeedCoordinatorResult::TerminalWindowReady,
               "Vehicle final-tail fixture did not seal the exact bulk stream");
  return report.passed;
}

void test_happy_path(TestReport& report) {
  static_assert(!std::is_copy_constructible_v<GroundHighSpeedTddCoordinator> &&
                !std::is_copy_assignable_v<GroundHighSpeedTddCoordinator> &&
                !std::is_move_constructible_v<GroundHighSpeedTddCoordinator> &&
                !std::is_move_assignable_v<GroundHighSpeedTddCoordinator>);
  static_assert(!std::is_copy_constructible_v<VehicleHighSpeedTddCoordinator> &&
                !std::is_copy_assignable_v<VehicleHighSpeedTddCoordinator> &&
                !std::is_move_constructible_v<VehicleHighSpeedTddCoordinator> &&
                !std::is_move_assignable_v<VehicleHighSpeedTddCoordinator>);
  WireFixture wire{};
  report.check(wire.valid, "wire fixture generation failed");
  GroundHighSpeedTddCoordinator ground{BulkSessionFeature::Enabled};
  VehicleHighSpeedTddCoordinator vehicle{BulkSessionFeature::Enabled};
  if (!start_ground_bulk(ground, wire, report) ||
      !start_vehicle_bulk(vehicle, wire, report) ||
      !finish_vehicle_to_window(vehicle, wire, report)) {
    return;
  }

  // The receiver observes the final RF tail before it can decode the frame and
  // finish the host-visible USB commit.  Preserve that honest physical order;
  // a coordinator which requires tail >= t1 would force an adapter to invent
  // a timestamp.
  constexpr std::uint64_t ground_tail_ms = 205U;
  constexpr std::uint64_t ground_complete_ms = 210U;
  const HighSpeedLocalRxRecordIdentity ground_rx =
      local_rx_record(wire.transfer_tag, 0x44U, 1U);
  report.check(
      ground.bind_final_bulk_rx_record(ground_rx, ground_tail_ms) ==
              HighSpeedCoordinatorResult::Ready &&
          ground.observe_bulk_tail_drained(
          stream_tail(wire.transfer_tag, 0x44U, 1U, ground_tail_ms),
          ground_tail_ms) == HighSpeedCoordinatorResult::TailDrainAccepted &&
          ground.complete_bulk_receive(BulkSessionResult::TerminalEvidenceReady,
                                       ground_evidence(wire.transfer_tag),
                                       wire.terminal, ground_complete_ms) ==
              HighSpeedCoordinatorResult::TerminalWindowReady,
      "Ground did not preserve RF-tail-before-USB-commit order");

  const std::uint64_t ground_guard =
      ground_tail_ms + BulkSessionTiming::direction_guard_ms;
  report.check(ground.open_terminal_window(
                   BulkSessionResult::TerminalWindowOpened, ground_guard) ==
                   HighSpeedCoordinatorResult::ActionReady,
               "Ground did not open VCTA after the direction guard");
  HighSpeedAction final_terminal{};
  for (std::size_t index = 0U; index < wire.terminal.size(); ++index) {
    HighSpeedAction terminal = ground.poll(ground_guard + index);
    final_terminal = terminal;
    report.check(terminal.type == HighSpeedActionType::SendTerminalEvidence &&
                     terminal.bytes == wire.terminal[index] &&
                     ground.complete_action(terminal.token, TxResult::Accepted,
                                            ground_guard + index) ==
                         HighSpeedCoordinatorResult::Accepted,
                 "Ground changed or reordered a VCTA fragment");
    if (!report.passed) {
      return;
    }
  }
  report.check(
      ground.confirm_terminal_commit(BulkSessionResult::TerminalAckCommitted,
                                     ground_guard + 8U) ==
              HighSpeedCoordinatorResult::AwaitingPeer &&
          ground.observe_action_tail_drained(
              action_tail(final_terminal, ground_guard + 9U),
              ground_guard + 9U) ==
              HighSpeedCoordinatorResult::SessionComplete &&
          ground.state() == GroundHighSpeedTddState::Complete,
      "Ground completed without the final VCTA physical tail");

  constexpr std::uint64_t vehicle_tail_ms = 203U;
  const std::uint64_t vehicle_guard =
      vehicle_tail_ms + BulkSessionTiming::direction_guard_ms;
  HighSpeedAction open_window = vehicle.poll(vehicle_guard);
  report.check(
      open_window.type == HighSpeedActionType::OpenTerminalAckWindow &&
          vehicle.complete_action(open_window.token, TxResult::Accepted,
                                  vehicle_guard) ==
              HighSpeedCoordinatorResult::Accepted &&
          vehicle.confirm_terminal_window(
              BulkSessionResult::TerminalWindowOpened, vehicle_guard) ==
              HighSpeedCoordinatorResult::AwaitingPeer &&
          vehicle.confirm_terminal_ack(BulkSessionResult::SessionComplete,
                                       wire.transfer_tag, vehicle_guard + 1U) ==
              HighSpeedCoordinatorResult::SessionComplete &&
          vehicle.state() == VehicleHighSpeedTddState::Complete,
      "Vehicle did not enforce guard/window/terminal evidence order");

  // The owner-commit callback and the physical AUX/drain observation are
  // independent adapter events. Either arrival order must release exactly one
  // #21, and neither event alone may release it.
  VehicleHighSpeedTddCoordinator drain_first{BulkSessionFeature::Enabled};
  const HighSpeedStandardGrantEvidence drain_first_grant =
      retained_grant_tail(1'001U);
  report.check(drain_first.adopt_retained_grant_on_terminal_request(
                   BulkSessionResult::GrantArmed,
                   BulkSessionResult::NegotiationResponseReady, wire.grant,
                   drain_first_grant, wire.request, wire.response,
                   wire.transfer_tag, 1'004U) ==
                   HighSpeedCoordinatorResult::Ready,
               "drain-first fixture did not accept the complete VCBN request");
  HighSpeedAction response = drain_first.poll(1'104U);
  report.check(
      drain_first.complete_action(response.token, TxResult::Accepted, 1'105U) ==
              HighSpeedCoordinatorResult::Accepted &&
          drain_first.observe_action_tail_drained(action_tail(response, 1'106U),
                                                  1'106U) ==
              HighSpeedCoordinatorResult::TailDrainAccepted &&
          drain_first.poll(1'106U).type == HighSpeedActionType::None &&
          drain_first.stage_pixhawk_request(
              BulkSessionResult::NegotiationResponseCommitted,
              wire.pixhawk_request,
              1'107U) == HighSpeedCoordinatorResult::ActionReady &&
          drain_first.poll(1'107U).type ==
              HighSpeedActionType::SendPixhawkParameterRequest,
      "response drain before owner commit stalled or prematurely exposed #21");
}

void test_disabled_is_inert(TestReport& report) {
  WireFixture wire{};
  GroundHighSpeedTddCoordinator ground{BulkSessionFeature::Disabled};
  VehicleHighSpeedTddCoordinator vehicle{BulkSessionFeature::Disabled};
  report.check(ground.begin_parameter_request(
                   BulkSessionResult::ParameterRequestHeld, 100U) ==
                       HighSpeedCoordinatorResult::NoAction &&
                   vehicle.adopt_retained_grant_on_terminal_request(
                       BulkSessionResult::GrantArmed,
                       BulkSessionResult::NegotiationResponseReady, wire.grant,
                       retained_grant_tail(99U), wire.request, wire.response,
                       wire.transfer_tag, 100U) ==
                       HighSpeedCoordinatorResult::NoAction &&
                   ground.poll(101U).type == HighSpeedActionType::None &&
                   vehicle.poll(101U).type == HighSpeedActionType::None &&
                   ground.state() == GroundHighSpeedTddState::Disabled &&
                   vehicle.state() == VehicleHighSpeedTddState::Disabled &&
                   !ground.fail_closed() && !vehicle.fail_closed(),
               "Disabled coordinator produced work or changed state");
  (void)wire;
}

void test_rejected_writes_retry_exact_bytes(TestReport& report) {
  WireFixture wire{};
  GroundHighSpeedTddCoordinator ground{BulkSessionFeature::Enabled};
  report.check(ground.begin_parameter_request(
                   BulkSessionResult::ParameterRequestHeld, 100U) ==
                       HighSpeedCoordinatorResult::Ready &&
                   ground.stage_fresh_grant(
                       BulkSessionResult::NegotiationRequestReady, wire.request,
                       101U) == HighSpeedCoordinatorResult::Ready,
               "retry fixture did not stage request");
  const HighSpeedAction first = ground.poll(201U);
  report.check(ground.complete_action(first.token, TxResult::Rejected, 202U) ==
                   HighSpeedCoordinatorResult::RetryRetained,
               "rejected request was not retained");
  const HighSpeedAction retry = ground.poll(203U);
  report.check(first.token != retry.token && same_action_bytes(first, retry),
               "request retry was not byte-identical with a fresh token");

  VehicleHighSpeedTddCoordinator vehicle{BulkSessionFeature::Enabled};
  const HighSpeedStandardGrantEvidence passive_grant =
      retained_grant_tail(101U);
  report.check(vehicle.adopt_retained_grant_on_terminal_request(
                   BulkSessionResult::GrantArmed,
                   BulkSessionResult::NegotiationResponseReady, wire.grant,
                   passive_grant, wire.request, wire.response,
                   wire.transfer_tag, 102U) ==
                   HighSpeedCoordinatorResult::Ready,
               "retry fixture did not passively arm the response");
  const HighSpeedAction response = vehicle.poll(202U);
  report.check(
      vehicle.complete_action(response.token, TxResult::Rejected, 203U) ==
          HighSpeedCoordinatorResult::RetryRetained,
      "rejected VCBN response was not retained");
  const HighSpeedAction response_retry = vehicle.poll(204U);
  report.check(response.token != response_retry.token &&
                   same_action_bytes(response, response_retry),
               "VCBN response retry was not byte-identical with a fresh token");

  VehicleHighSpeedTddCoordinator bulk_retry{BulkSessionFeature::Enabled};
  if (!start_vehicle_bulk(bulk_retry, wire, report)) {
    return;
  }
  report.check(bulk_retry.stage_bulk_fragment(wire.bulk_fragment, 200U) ==
                   HighSpeedCoordinatorResult::ActionReady,
               "bulk-retry fixture did not stage ordinal zero");
  const HighSpeedAction first_bulk = bulk_retry.poll(200U);
  report.check(
      bulk_retry.complete_action(first_bulk.token, TxResult::Rejected, 201U) ==
          HighSpeedCoordinatorResult::RetryRetained,
      "rejected VCB1 fragment was not retained");
  const HighSpeedAction retried_bulk = bulk_retry.poll(202U);
  const BulkDataFragment ordinal_one_tail = make_bulk_fragment(
      BulkDataFragmentKind::ParameterTail, wire.transfer_tag, 1U);
  report.check(retried_bulk.token != first_bulk.token &&
                   same_action_bytes(first_bulk, retried_bulk) &&
                   bulk_retry.complete_action(retried_bulk.token,
                                              TxResult::Accepted, 203U) ==
                       HighSpeedCoordinatorResult::Accepted &&
                   bulk_retry.stage_bulk_fragment(ordinal_one_tail, 203U) ==
                       HighSpeedCoordinatorResult::ActionReady,
               "VCB1 rejection advanced accounting or changed retry bytes");
}

void test_premature_wrong_and_regressed_events_fail_closed(TestReport& report) {
  WireFixture wire{};
  {
    GroundHighSpeedTddCoordinator premature{BulkSessionFeature::Enabled};
    report.check(premature.stage_fresh_grant(
                     BulkSessionResult::NegotiationRequestReady, wire.request,
                     100U) == HighSpeedCoordinatorResult::InvalidState &&
                     premature.fail_closed(),
                 "Ground accepted a Grant before held #21/t0");
  }
  {
    GroundHighSpeedTddCoordinator stale{BulkSessionFeature::Enabled};
    report.check(
        stale.begin_parameter_request(BulkSessionResult::ParameterRequestHeld,
                                      100U) ==
                HighSpeedCoordinatorResult::Ready &&
            stale.stage_fresh_grant(BulkSessionResult::NegotiationRequestReady,
                                    wire.request, 601U) ==
                HighSpeedCoordinatorResult::GrantDeadlineExceeded &&
            stale.fail_closed(),
        "Ground accepted a t0+501 ms Grant");
  }
  {
    VehicleHighSpeedTddCoordinator stale{BulkSessionFeature::Enabled};
    report.check(stale.adopt_retained_grant_on_terminal_request(
                     BulkSessionResult::GrantArmed,
                     BulkSessionResult::NegotiationResponseReady, wire.grant,
                     retained_grant_tail(100U), wire.request, wire.response,
                     wire.transfer_tag, 601U) ==
                         HighSpeedCoordinatorResult::GrantDeadlineExceeded &&
                     stale.fail_closed(),
                 "Vehicle accepted a retained Grant at age 501 ms");
  }
  {
    VehicleHighSpeedTddCoordinator wrong_token{BulkSessionFeature::Enabled};
    const HighSpeedStandardGrantEvidence passive_grant =
        retained_grant_tail(101U);
    report.check(
        wrong_token.adopt_retained_grant_on_terminal_request(
            BulkSessionResult::GrantArmed,
            BulkSessionResult::NegotiationResponseReady, wire.grant,
            passive_grant, wire.request, wire.response, wire.transfer_tag,
            102U) == HighSpeedCoordinatorResult::Ready,
        "wrong-token fixture did not arm");
    const HighSpeedAction response = wrong_token.poll(202U);
    report.check(wrong_token.complete_action(response.token + 1U,
                                             TxResult::Accepted, 203U) ==
                         HighSpeedCoordinatorResult::InvalidToken &&
                     wrong_token.fail_closed(),
                 "wrong action token did not fail closed");
  }
  {
    GroundHighSpeedTddCoordinator regressed{BulkSessionFeature::Enabled};
    report.check(regressed.begin_parameter_request(
                     BulkSessionResult::ParameterRequestHeld, 100U) ==
                         HighSpeedCoordinatorResult::Ready &&
                     regressed.tick(99U) ==
                         HighSpeedCoordinatorResult::ClockRegression &&
                     regressed.fail_closed(),
                 "time regression did not fail closed");
  }
  {
    VehicleHighSpeedTddCoordinator swapped{BulkSessionFeature::Enabled};
    if (!start_vehicle_bulk(swapped, wire, report)) {
      return;
    }
    const BulkDataFragment ordinal_one = make_bulk_fragment(
        BulkDataFragmentKind::ParameterTail, wire.transfer_tag, 1U);
    report.check(
        swapped.stage_bulk_fragment(ordinal_one, 200U) ==
                HighSpeedCoordinatorResult::InvalidWireRecord &&
            swapped.fail_closed(),
        "Vehicle accepted a first VCB1 fragment whose wire ordinal was 1");
  }
  {
    VehicleHighSpeedTddCoordinator repeated{BulkSessionFeature::Enabled};
    if (!start_vehicle_bulk(repeated, wire, report)) {
      return;
    }
    report.check(repeated.stage_bulk_fragment(wire.bulk_fragment, 200U) ==
                     HighSpeedCoordinatorResult::ActionReady,
                 "repeat fixture did not stage ordinal zero");
    const HighSpeedAction first = repeated.poll(200U);
    report.check(
        first.type == HighSpeedActionType::SendBulkFragment &&
            repeated.complete_action(first.token, TxResult::Accepted, 201U) ==
                HighSpeedCoordinatorResult::Accepted &&
            repeated.stage_bulk_fragment(wire.bulk_fragment, 201U) ==
                HighSpeedCoordinatorResult::InvalidWireRecord &&
            repeated.fail_closed(),
        "Vehicle accepted an already committed VCB1 wire ordinal");
  }
  {
    VehicleHighSpeedTddCoordinator bad_pair{BulkSessionFeature::Enabled};
    if (!start_vehicle_bulk(bad_pair, wire, report)) {
      return;
    }
    report.check(bad_pair.stage_bulk_fragment(wire.bulk_fragment, 200U) ==
                     HighSpeedCoordinatorResult::ActionReady,
                 "pair fixture did not stage a parameter HEAD");
    const HighSpeedAction head = bad_pair.poll(200U);
    const BulkDataFragment second_head = make_bulk_fragment(
        BulkDataFragmentKind::ParameterHead, wire.transfer_tag, 1U);
    report.check(
        bad_pair.complete_action(head.token, TxResult::Accepted, 201U) ==
                HighSpeedCoordinatorResult::Accepted &&
            bad_pair.stage_bulk_fragment(second_head, 201U) ==
                HighSpeedCoordinatorResult::InvalidWireRecord &&
            bad_pair.fail_closed(),
        "Vehicle accepted HEAD/HEAD instead of a matched HEAD/TAIL pair");
  }
  {
    VehicleHighSpeedTddCoordinator premature{BulkSessionFeature::Enabled};
    if (!start_vehicle_bulk(premature, wire, report)) {
      return;
    }
    report.check(premature.stage_bulk_fragment(wire.bulk_fragment, 200U) ==
                     HighSpeedCoordinatorResult::ActionReady,
                 "premature-completion fixture did not stage VCB1");
    const HighSpeedAction head = premature.poll(200U);
    report.check(
        premature.complete_action(head.token, TxResult::Accepted, 201U) ==
                HighSpeedCoordinatorResult::Accepted &&
            premature.complete_bulk_downlink(
                BulkSessionResult::TerminalEvidenceReady,
                vehicle_evidence(wire.transfer_tag),
                202U) == HighSpeedCoordinatorResult::EvidenceMismatch &&
            premature.fail_closed(),
        "Vehicle accepted unrelated 932-parameter evidence after one HEAD");
  }
}

void test_inclusive_timing_boundaries(TestReport& report) {
  WireFixture wire{};
  {
    GroundHighSpeedTddCoordinator boundary{BulkSessionFeature::Enabled};
    report.check(
        boundary.begin_parameter_request(
            BulkSessionResult::ParameterRequestHeld, 100U) ==
                HighSpeedCoordinatorResult::Ready &&
            boundary.stage_fresh_grant(
                BulkSessionResult::NegotiationRequestReady, wire.request,
                600U) == HighSpeedCoordinatorResult::Ready,
        "Ground rejected the inclusive t0+500 ms Grant boundary");
  }
  {
    GroundHighSpeedTddCoordinator lease{BulkSessionFeature::Enabled};
    if (!start_ground_bulk(lease, wire, report)) {
      return;
    }
    report.check(
        lease.tick(kGroundT0 + BulkSessionTiming::hard_lease_ms) ==
                HighSpeedCoordinatorResult::NoAction &&
            lease.tick(kGroundT0 + BulkSessionTiming::hard_lease_ms + 1U) ==
                HighSpeedCoordinatorResult::LeaseExpired &&
            lease.fail_closed(),
        "Ground hard lease did not allow 28,000 ms and fail at +1 ms");
  }
  {
    VehicleHighSpeedTddCoordinator lease{BulkSessionFeature::Enabled};
    if (!start_vehicle_bulk(lease, wire, report)) {
      return;
    }
    constexpr std::uint64_t vehicle_lease_epoch_ms = 2U;
    report.check(
        lease.tick(vehicle_lease_epoch_ms + BulkSessionTiming::hard_lease_ms) ==
                HighSpeedCoordinatorResult::NoAction &&
            lease.tick(vehicle_lease_epoch_ms +
                       BulkSessionTiming::hard_lease_ms + 1U) ==
                HighSpeedCoordinatorResult::LeaseExpired &&
            lease.fail_closed(),
        "Vehicle hard lease did not allow 28,000 ms and fail at +1 ms");
  }

  constexpr std::uint64_t kGroundCompleteMs = 200U;
  const std::uint64_t ground_transition_boundary =
      kGroundCompleteMs + BulkSessionTiming::terminal_transition_timeout_ms;
  {
    GroundHighSpeedTddCoordinator await_tail{BulkSessionFeature::Enabled};
    if (!start_ground_bulk(await_tail, wire, report)) {
      return;
    }
    report.check(await_tail.complete_bulk_receive(
                     BulkSessionResult::TerminalEvidenceReady,
                     ground_evidence(wire.transfer_tag), wire.terminal,
                     kGroundCompleteMs) ==
                         HighSpeedCoordinatorResult::TerminalWindowReady &&
                     await_tail.bind_final_bulk_rx_record(
                         local_rx_record(wire.transfer_tag, 0x44U, 1U),
                         kGroundCompleteMs) ==
                         HighSpeedCoordinatorResult::Ready,
                 "Ground transition-timeout fixture did not await the RF tail");
    report.check(await_tail.tick(ground_transition_boundary) ==
                         HighSpeedCoordinatorResult::NoAction &&
                     await_tail.observe_bulk_tail_drained(
                         stream_tail(wire.transfer_tag, 0x44U, 1U,
                                     ground_transition_boundary + 1U),
                         ground_transition_boundary + 1U) ==
                         HighSpeedCoordinatorResult::TerminalWindowTimeout &&
                     await_tail.fail_closed(),
                 "Ground AwaitBulkTail was not bounded at completion+450 ms");
  }
  {
    GroundHighSpeedTddCoordinator guard{BulkSessionFeature::Enabled};
    if (!start_ground_bulk(guard, wire, report)) {
      return;
    }
    constexpr std::uint64_t kGroundTailMs = 195U;
    report.check(
        guard.bind_final_bulk_rx_record(
            local_rx_record(wire.transfer_tag, 0x44U, 1U), kGroundTailMs) ==
                HighSpeedCoordinatorResult::Ready &&
            guard.observe_bulk_tail_drained(
                stream_tail(wire.transfer_tag, 0x44U, 1U, kGroundTailMs),
                kGroundTailMs) == HighSpeedCoordinatorResult::TailDrainAccepted &&
            guard.complete_bulk_receive(
                BulkSessionResult::TerminalEvidenceReady,
                ground_evidence(wire.transfer_tag), wire.terminal,
                kGroundCompleteMs) ==
                HighSpeedCoordinatorResult::TerminalWindowReady,
        "Ground transition-timeout fixture did not enter DirectionGuard");
    report.check(
        guard.tick(ground_transition_boundary) ==
                HighSpeedCoordinatorResult::NoAction &&
            guard.open_terminal_window(BulkSessionResult::TerminalWindowOpened,
                                       ground_transition_boundary + 1U) ==
                HighSpeedCoordinatorResult::TerminalWindowTimeout &&
            guard.fail_closed(),
        "Ground DirectionGuard was not bounded from host-visible t1");
  }

  constexpr std::uint64_t kVehicleCompleteMs = 202U;
  const std::uint64_t vehicle_transition_boundary =
      kVehicleCompleteMs + BulkSessionTiming::terminal_transition_timeout_ms;
  {
    VehicleHighSpeedTddCoordinator await_tail{BulkSessionFeature::Enabled};
    if (!start_vehicle_bulk(await_tail, wire, report)) {
      return;
    }
    HighSpeedAction bulk{};
    if (!send_complete_bulk_stream(await_tail, wire, report, bulk, 200U)) {
      return;
    }
    report.check(
        bulk.type == HighSpeedActionType::SendBulkFragment &&
            await_tail.complete_bulk_downlink(
                BulkSessionResult::TerminalEvidenceReady,
                vehicle_evidence(wire.transfer_tag), kVehicleCompleteMs) ==
                HighSpeedCoordinatorResult::TerminalWindowReady,
        "Vehicle transition-timeout fixture did not await the RF tail");
    report.check(await_tail.tick(vehicle_transition_boundary) ==
                         HighSpeedCoordinatorResult::NoAction &&
                     await_tail.observe_bulk_tail_drained(
                         stream_tail(wire.transfer_tag, bulk.token,
                                     bulk.writer_generation,
                                     vehicle_transition_boundary + 1U),
                         vehicle_transition_boundary + 1U) ==
                         HighSpeedCoordinatorResult::TerminalWindowTimeout &&
                     await_tail.fail_closed(),
                 "Vehicle AwaitBulkTail was not bounded at completion+450 ms");
  }
  {
    VehicleHighSpeedTddCoordinator guard{BulkSessionFeature::Enabled};
    if (!start_vehicle_bulk(guard, wire, report) ||
        !finish_vehicle_to_window(guard, wire, report)) {
      return;
    }
    report.check(
        guard.tick(vehicle_transition_boundary) ==
                HighSpeedCoordinatorResult::NoAction &&
            guard.poll(vehicle_transition_boundary + 1U).type ==
                HighSpeedActionType::None &&
            guard.last_error() ==
                HighSpeedCoordinatorResult::TerminalWindowTimeout &&
            guard.fail_closed(),
        "Vehicle DirectionGuard was not bounded from local completion");
  }
  {
    VehicleHighSpeedTddCoordinator ready{BulkSessionFeature::Enabled};
    if (!start_vehicle_bulk(ready, wire, report) ||
        !finish_vehicle_to_window(ready, wire, report)) {
      return;
    }
    const HighSpeedAction open =
        ready.poll(203U + BulkSessionTiming::direction_guard_ms);
    report.check(open.type == HighSpeedActionType::OpenTerminalAckWindow,
                 "Vehicle transition-timeout fixture did not stage window");
    report.check(
        ready.tick(vehicle_transition_boundary) ==
                HighSpeedCoordinatorResult::NoAction &&
            ready.complete_action(open.token, TxResult::Accepted,
                                  vehicle_transition_boundary + 1U) ==
                HighSpeedCoordinatorResult::TerminalWindowTimeout &&
            ready.fail_closed(),
        "Vehicle TerminalWindowReady was not bounded from local completion");
  }
  {
    VehicleHighSpeedTddCoordinator commit{BulkSessionFeature::Enabled};
    if (!start_vehicle_bulk(commit, wire, report) ||
        !finish_vehicle_to_window(commit, wire, report)) {
      return;
    }
    const std::uint64_t guard_ms = 203U + BulkSessionTiming::direction_guard_ms;
    const HighSpeedAction open = commit.poll(guard_ms);
    report.check(
        open.type == HighSpeedActionType::OpenTerminalAckWindow &&
            commit.complete_action(open.token, TxResult::Accepted, guard_ms) ==
                HighSpeedCoordinatorResult::Accepted,
        "Vehicle transition-timeout fixture did not await owner commit");
    report.check(commit.tick(vehicle_transition_boundary) ==
                         HighSpeedCoordinatorResult::NoAction &&
                     commit.confirm_terminal_window(
                         BulkSessionResult::TerminalWindowOpened,
                         vehicle_transition_boundary + 1U) ==
                         HighSpeedCoordinatorResult::TerminalWindowTimeout &&
                     commit.fail_closed(),
                 "Vehicle AwaitTerminalWindowCommit was not bounded");
  }

  VehicleHighSpeedTddCoordinator on_time{BulkSessionFeature::Enabled};
  if (!start_vehicle_bulk(on_time, wire, report) ||
      !finish_vehicle_to_window(on_time, wire, report)) {
    return;
  }
  constexpr std::uint64_t tail_ms = 203U;
  report.check(
      on_time.poll(tail_ms + BulkSessionTiming::direction_guard_ms - 1U).type ==
          HighSpeedActionType::None,
      "Vehicle opened terminal window before the 100 ms guard");
  const std::uint64_t guard_boundary =
      tail_ms + BulkSessionTiming::direction_guard_ms;
  HighSpeedAction open = on_time.poll(guard_boundary);
  report.check(
      open.type == HighSpeedActionType::OpenTerminalAckWindow &&
          on_time.complete_action(open.token, TxResult::Accepted,
                                  guard_boundary) ==
              HighSpeedCoordinatorResult::Accepted &&
          on_time.confirm_terminal_window(
              BulkSessionResult::TerminalWindowOpened, guard_boundary) ==
              HighSpeedCoordinatorResult::AwaitingPeer &&
          on_time.confirm_terminal_ack(
              BulkSessionResult::SessionComplete, wire.transfer_tag,
              guard_boundary + BulkSessionTiming::terminal_ack_timeout_ms) ==
              HighSpeedCoordinatorResult::SessionComplete,
      "inclusive guard/350 ms ACK boundary was rejected");

  VehicleHighSpeedTddCoordinator late{BulkSessionFeature::Enabled};
  if (!start_vehicle_bulk(late, wire, report) ||
      !finish_vehicle_to_window(late, wire, report)) {
    return;
  }
  HighSpeedAction late_open = late.poll(guard_boundary);
  report.check(
      late.complete_action(late_open.token, TxResult::Accepted,
                           guard_boundary) ==
              HighSpeedCoordinatorResult::Accepted &&
          late.confirm_terminal_window(BulkSessionResult::TerminalWindowOpened,
                                       guard_boundary) ==
              HighSpeedCoordinatorResult::AwaitingPeer &&
          late.confirm_terminal_ack(
              BulkSessionResult::SessionComplete, wire.transfer_tag,
              guard_boundary + BulkSessionTiming::terminal_ack_timeout_ms +
                  1U) == HighSpeedCoordinatorResult::TerminalWindowTimeout &&
          late.fail_closed(),
      "terminal ACK +1 ms did not fail closed");
}

void test_passive_grant_handoff_and_initial_guards(TestReport& report) {
  WireFixture wire{};

  GroundHighSpeedTddCoordinator ground{BulkSessionFeature::Enabled};
  report.check(ground.begin_parameter_request(
                   BulkSessionResult::ParameterRequestHeld, 100U) ==
                       HighSpeedCoordinatorResult::Ready &&
                   ground.stage_fresh_grant(
                       BulkSessionResult::NegotiationRequestReady, wire.request,
                       101U) == HighSpeedCoordinatorResult::Ready &&
                   ground.poll(200U).type == HighSpeedActionType::None,
               "Ground released VCBN before Grant-tail+100 ms");
  report.check(
      ground.poll(201U).type == HighSpeedActionType::SendNegotiationRequest,
      "Ground did not release VCBN at Grant-tail+100 ms");

  VehicleHighSpeedTddCoordinator vehicle{BulkSessionFeature::Enabled};
  const HighSpeedStandardGrantEvidence grant_evidence =
      retained_grant_tail(102U);
  report.check(
      vehicle.adopt_retained_grant_on_terminal_request(
          BulkSessionResult::GrantArmed,
          BulkSessionResult::NegotiationResponseReady, wire.grant,
          grant_evidence, wire.request, wire.response, wire.transfer_tag,
          200U) ==
              HighSpeedCoordinatorResult::Ready &&
          vehicle.poll(299U).type == HighSpeedActionType::None,
      "Vehicle did not atomically adopt the retained Grant and VCBN request");
  report.check(vehicle.poll(299U).type == HighSpeedActionType::None,
               "Vehicle released VCBN response before request-tail+100 ms");
  report.check(
      vehicle.poll(300U).type == HighSpeedActionType::SendNegotiationResponse,
      "Vehicle did not release VCBN response at request-tail+100 ms");
}

void test_retained_grant_atomic_chronology(TestReport& report) {
  WireFixture wire{};
  report.check(wire.valid, "atomic retained-Grant fixture generation failed");

  // Natural product chronology: the standard writer finishes the Grant first.
  // Only when the complete VCBN request arrives does the high-speed coordinator
  // atomically adopt that retained evidence and enter the response guard.
  VehicleHighSpeedTddCoordinator boundary{BulkSessionFeature::Enabled};
  const HighSpeedStandardGrantEvidence inclusive = retained_grant_tail(100U);
  report.check(
      boundary.adopt_retained_grant_on_terminal_request(
          BulkSessionResult::GrantArmed,
          BulkSessionResult::NegotiationResponseReady, wire.grant, inclusive,
          wire.request, wire.response, wire.transfer_tag, 600U) ==
              HighSpeedCoordinatorResult::Ready &&
          boundary.poll(699U).type == HighSpeedActionType::None &&
          boundary.poll(700U).type ==
              HighSpeedActionType::SendNegotiationResponse,
      "retained Grant was not atomically adopted at the inclusive 500-ms age");

  VehicleHighSpeedTddCoordinator stale{BulkSessionFeature::Enabled};
  report.check(
      stale.adopt_retained_grant_on_terminal_request(
          BulkSessionResult::GrantArmed,
          BulkSessionResult::NegotiationResponseReady, wire.grant,
          retained_grant_tail(100U), wire.request, wire.response,
          wire.transfer_tag, 601U) ==
              HighSpeedCoordinatorResult::GrantDeadlineExceeded &&
          stale.fail_closed(),
      "retained Grant age 501 ms did not fail closed");

  VehicleHighSpeedTddCoordinator future{BulkSessionFeature::Enabled};
  report.check(
      future.adopt_retained_grant_on_terminal_request(
          BulkSessionResult::GrantArmed,
          BulkSessionResult::NegotiationResponseReady, wire.grant,
          retained_grant_tail(602U), wire.request, wire.response,
          wire.transfer_tag, 601U) ==
              HighSpeedCoordinatorResult::EvidenceMismatch &&
          future.fail_closed(),
      "future retained Grant tail did not fail closed");

  auto reject_invalid_evidence = [&](HighSpeedStandardGrantEvidence evidence,
                                     const char* failure) {
    VehicleHighSpeedTddCoordinator invalid{BulkSessionFeature::Enabled};
    report.check(
        invalid.adopt_retained_grant_on_terminal_request(
            BulkSessionResult::GrantArmed,
            BulkSessionResult::NegotiationResponseReady, wire.grant, evidence,
            wire.request, wire.response, wire.transfer_tag, 200U) ==
                HighSpeedCoordinatorResult::EvidenceMismatch &&
            invalid.fail_closed(),
        failure);
  };
  HighSpeedStandardGrantEvidence invalid = retained_grant_tail(100U);
  invalid.writer_token = 0U;
  reject_invalid_evidence(invalid, "zero retained Grant writer token accepted");
  invalid = retained_grant_tail(100U);
  invalid.writer_generation = 0U;
  reject_invalid_evidence(invalid,
                          "zero retained Grant writer generation accepted");
  invalid = retained_grant_tail(100U);
  invalid.completed_ms = 0U;
  reject_invalid_evidence(invalid, "zero retained Grant tail time accepted");
  invalid = retained_grant_tail(100U);
  invalid.grant_session_id = 0U;
  reject_invalid_evidence(invalid,
                          "zero retained Grant session identity accepted");
  invalid = retained_grant_tail(100U);
  invalid.grant_cycle_id = 0U;
  reject_invalid_evidence(invalid,
                          "zero retained Grant cycle identity accepted");
  invalid = retained_grant_tail(100U);
  invalid.accepted = false;
  reject_invalid_evidence(invalid,
                          "unaccepted retained Grant evidence accepted");
  invalid = retained_grant_tail(100U);
  invalid.physical_tail_complete = false;
  reject_invalid_evidence(invalid,
                          "undrained retained Grant evidence accepted");
  invalid = retained_grant_tail(100U);
  ++invalid.grant_cycle_id;
  reject_invalid_evidence(invalid,
                          "mismatched retained Grant identity accepted");
}

void test_final_bulk_tail_identity_is_exact(TestReport& report) {
  WireFixture wire{};
  auto reject_mutated_tail = [&](std::uint32_t final_ordinal,
                                 std::uint32_t fragment_count,
                                 std::uint32_t token_delta,
                                 std::uint32_t generation_delta,
                                 const char* failure) {
    VehicleHighSpeedTddCoordinator vehicle{BulkSessionFeature::Enabled};
    HighSpeedAction final_action{};
    if (!prepare_vehicle_await_bulk_tail(vehicle, wire, report, final_action)) {
      return;
    }
    const HighSpeedStreamTailEvidence tail{
        wire.transfer_tag,
        final_ordinal,
        fragment_count,
        final_action.token + token_delta,
        final_action.writer_generation + generation_delta,
        true,
        203U};
    report.check(vehicle.observe_bulk_tail_drained(tail, 203U) ==
                         HighSpeedCoordinatorResult::EvidenceMismatch &&
                     vehicle.fail_closed(),
                 failure);
  };

  reject_mutated_tail(1918U, 1920U, 0U, 0U,
                      "Vehicle accepted a stale final VCB1 ordinal");
  reject_mutated_tail(1919U, 1919U, 0U, 0U,
                      "Vehicle accepted a wrong VCB1 fragment count");
  reject_mutated_tail(1919U, 1920U, 1U, 0U,
                      "Vehicle accepted a stale VCB1 writer token");
  reject_mutated_tail(1919U, 1920U, 0U, 1U,
                      "Vehicle accepted a stale VCB1 writer generation");

  VehicleHighSpeedTddCoordinator exact{BulkSessionFeature::Enabled};
  HighSpeedAction exact_final{};
  if (!prepare_vehicle_await_bulk_tail(exact, wire, report, exact_final)) {
    return;
  }
  const HighSpeedStreamTailEvidence exact_tail{wire.transfer_tag,
                                               1919U,
                                               1920U,
                                               exact_final.token,
                                               exact_final.writer_generation,
                                               true,
                                               203U};
  report.check(exact.observe_bulk_tail_drained(exact_tail, 203U) ==
                       HighSpeedCoordinatorResult::TailDrainAccepted &&
                   exact.state() == VehicleHighSpeedTddState::DirectionGuard,
               "Vehicle rejected the exact final VCB1 tail identity");
}

void test_ground_local_rx_identity_is_one_shot(TestReport& report) {
  WireFixture wire{};
  constexpr std::uint64_t tail_ms = 205U;

  GroundHighSpeedTddCoordinator exact{BulkSessionFeature::Enabled};
  if (!start_ground_bulk(exact, wire, report)) {
    return;
  }
  const HighSpeedLocalRxRecordIdentity identity =
      local_rx_record(wire.transfer_tag, 0x4401U, 0x5501U);
  report.check(
      exact.bind_final_bulk_rx_record(identity, tail_ms) ==
              HighSpeedCoordinatorResult::Ready &&
          exact.observe_bulk_tail_drained(
              stream_tail(wire.transfer_tag, identity.rx_record_token,
                          identity.rx_ledger_generation, tail_ms),
              tail_ms) == HighSpeedCoordinatorResult::TailDrainAccepted,
      "Ground rejected the exact one-shot local RX-ledger identity");

  auto reject_mutated_tail = [&](std::uint32_t tag_delta,
                                 std::uint32_t ordinal_delta,
                                 std::uint32_t count_delta,
                                 std::uint32_t token_delta,
                                 std::uint32_t generation_delta,
                                     const char* failure) {
    GroundHighSpeedTddCoordinator ground{BulkSessionFeature::Enabled};
    if (!start_ground_bulk(ground, wire, report)) {
      return;
    }
    const HighSpeedLocalRxRecordIdentity bound =
        local_rx_record(wire.transfer_tag, 0x6601U, 0x7701U);
    if (ground.bind_final_bulk_rx_record(bound, tail_ms) !=
        HighSpeedCoordinatorResult::Ready) {
      report.check(false, "Ground could not bind local RX identity fixture");
      return;
    }
    HighSpeedStreamTailEvidence mutated = stream_tail(
        wire.transfer_tag + tag_delta, bound.rx_record_token + token_delta,
        bound.rx_ledger_generation + generation_delta, tail_ms);
    mutated.final_wire_ordinal += ordinal_delta;
    mutated.fragment_count += count_delta;
    report.check(ground.observe_bulk_tail_drained(mutated, tail_ms) ==
                         HighSpeedCoordinatorResult::EvidenceMismatch &&
                     ground.fail_closed(),
                 failure);
  };
  reject_mutated_tail(1U, 0U, 0U, 0U, 0U,
                      "Ground accepted a different VCB1 transfer tag");
  reject_mutated_tail(0U, 1U, 0U, 0U, 0U,
                      "Ground accepted a different final VCB1 ordinal");
  reject_mutated_tail(0U, 0U, 1U, 0U, 0U,
                      "Ground accepted a different VCB1 fragment count");
  reject_mutated_tail(0U, 0U, 0U, 1U, 0U,
                      "Ground accepted a different local RX-record token");
  reject_mutated_tail(0U, 0U, 0U, 0U, 1U,
                      "Ground accepted a different local RX-ledger generation");

  GroundHighSpeedTddCoordinator rebound{BulkSessionFeature::Enabled};
  if (!start_ground_bulk(rebound, wire, report)) {
    return;
  }
  const HighSpeedLocalRxRecordIdentity first_binding =
      local_rx_record(wire.transfer_tag, 0xAA01U, 0xBB01U);
  report.check(
      rebound.bind_final_bulk_rx_record(first_binding, tail_ms) ==
              HighSpeedCoordinatorResult::Ready &&
          rebound.bind_final_bulk_rx_record(first_binding, tail_ms) ==
              HighSpeedCoordinatorResult::InvalidState &&
          rebound.fail_closed(),
      "Ground accepted a second local RX-ledger identity registration");

  GroundHighSpeedTddCoordinator unbound{BulkSessionFeature::Enabled};
  if (!start_ground_bulk(unbound, wire, report)) {
    return;
  }
  report.check(
      unbound.observe_bulk_tail_drained(
          stream_tail(wire.transfer_tag, 0x8801U, 0x9901U, tail_ms),
          tail_ms) == HighSpeedCoordinatorResult::EvidenceMismatch &&
          unbound.fail_closed(),
      "Ground accepted final VCB1 tail without local RX-ledger binding");
}

void test_terminal_evidence_requires_physical_tail(TestReport& report) {
  WireFixture wire{};
  GroundHighSpeedTddCoordinator ground{BulkSessionFeature::Enabled};
  if (!start_ground_bulk(ground, wire, report)) {
    return;
  }
  constexpr std::uint64_t bulk_tail_ms = 205U;
  constexpr std::uint64_t complete_ms = 210U;
  const HighSpeedStreamTailEvidence bulk_tail{
      wire.transfer_tag, 1919U, 1920U, 0x44U, 9U, true, bulk_tail_ms};
  report.check(
      ground.bind_final_bulk_rx_record(
          local_rx_record(wire.transfer_tag, 0x44U, 9U), bulk_tail_ms) ==
              HighSpeedCoordinatorResult::Ready &&
          ground.observe_bulk_tail_drained(bulk_tail, bulk_tail_ms) ==
              HighSpeedCoordinatorResult::TailDrainAccepted &&
          ground.complete_bulk_receive(BulkSessionResult::TerminalEvidenceReady,
                                       ground_evidence(wire.transfer_tag),
                                       wire.terminal, complete_ms) ==
              HighSpeedCoordinatorResult::TerminalWindowReady &&
          ground.open_terminal_window(
              BulkSessionResult::TerminalWindowOpened,
              bulk_tail_ms + BulkSessionTiming::direction_guard_ms) ==
              HighSpeedCoordinatorResult::ActionReady,
      "Ground terminal-tail fixture did not reach VCTA transmit");

  HighSpeedAction final_terminal{};
  for (std::size_t index = 0U; index < wire.terminal.size(); ++index) {
    final_terminal = ground.poll(310U + index);
    if (final_terminal.type != HighSpeedActionType::SendTerminalEvidence ||
        ground.complete_action(final_terminal.token, TxResult::Accepted,
                               310U + index) !=
            HighSpeedCoordinatorResult::Accepted) {
      report.check(false, "Ground did not accept all eight VCTA fragments");
      return;
    }
  }
  report.check(
      ground.state() == GroundHighSpeedTddState::AwaitTerminalPhysicalTail &&
          ground.confirm_terminal_commit(
              BulkSessionResult::TerminalAckCommitted, 318U) ==
              HighSpeedCoordinatorResult::AwaitingPeer &&
          ground.state() == GroundHighSpeedTddState::AwaitTerminalPhysicalTail,
      "Ground completed VCTA on UART acceptance without physical tail");
  report.check(
      ground.observe_action_tail_drained(action_tail(final_terminal, 319U),
                                         319U) ==
              HighSpeedCoordinatorResult::SessionComplete &&
          ground.state() == GroundHighSpeedTddState::Complete,
      "Ground did not require the correlated final VCTA physical tail");

  GroundHighSpeedTddCoordinator wrong_tail{BulkSessionFeature::Enabled};
  if (!start_ground_bulk(wrong_tail, wire, report)) {
    return;
  }
  report.check(
      wrong_tail.bind_final_bulk_rx_record(
          local_rx_record(wire.transfer_tag, 0x44U, 9U), bulk_tail_ms) ==
              HighSpeedCoordinatorResult::Ready &&
          wrong_tail.observe_bulk_tail_drained(bulk_tail, bulk_tail_ms) ==
              HighSpeedCoordinatorResult::TailDrainAccepted &&
          wrong_tail.complete_bulk_receive(
              BulkSessionResult::TerminalEvidenceReady,
              ground_evidence(wire.transfer_tag), wire.terminal,
              complete_ms) == HighSpeedCoordinatorResult::TerminalWindowReady &&
          wrong_tail.open_terminal_window(
              BulkSessionResult::TerminalWindowOpened,
              bulk_tail_ms + BulkSessionTiming::direction_guard_ms) ==
              HighSpeedCoordinatorResult::ActionReady,
      "Ground wrong-tail fixture did not reach VCTA transmit");
  HighSpeedAction wrong_final{};
  for (std::size_t index = 0U; index < wire.terminal.size(); ++index) {
    wrong_final = wrong_tail.poll(310U + index);
    if (wrong_final.type != HighSpeedActionType::SendTerminalEvidence ||
        wrong_tail.complete_action(wrong_final.token, TxResult::Accepted,
                                   310U + index) !=
            HighSpeedCoordinatorResult::Accepted) {
      report.check(
          false, "Ground wrong-tail fixture did not accept all VCTA fragments");
      return;
    }
  }
  report.check(wrong_tail.confirm_terminal_commit(
                   BulkSessionResult::TerminalAckCommitted, 318U) ==
                   HighSpeedCoordinatorResult::AwaitingPeer,
               "Ground wrong-tail fixture did not latch owner commit");
  HighSpeedTailDrainEvidence mismatched = action_tail(wrong_final, 319U);
  ++mismatched.action_token;
  report.check(wrong_tail.observe_action_tail_drained(mismatched, 319U) ==
                       HighSpeedCoordinatorResult::EvidenceMismatch &&
                   wrong_tail.fail_closed(),
               "Ground accepted an uncorrelated final VCTA physical tail");
}

bool prepare_ground_await_terminal_peer_receipt(
    GroundHighSpeedTddCoordinator& ground, const WireFixture& wire,
    TestReport& report, HighSpeedAction& final_terminal,
    std::uint64_t& final_accepted_ms) {
  if (!start_ground_bulk(ground, wire, report)) {
    return false;
  }
  constexpr std::uint64_t bulk_tail_ms = 205U;
  constexpr std::uint64_t complete_ms = 210U;
  constexpr std::uint64_t terminal_window_ms =
      bulk_tail_ms + BulkSessionTiming::direction_guard_ms;
  const HighSpeedStreamTailEvidence bulk_tail{
      wire.transfer_tag, 1919U, 1920U, 0x44U, 9U, true, bulk_tail_ms};
  report.check(
      ground.bind_final_bulk_rx_record(
          local_rx_record(wire.transfer_tag, 0x44U, 9U), bulk_tail_ms) ==
              HighSpeedCoordinatorResult::Ready &&
          ground.observe_bulk_tail_drained(bulk_tail, bulk_tail_ms) ==
              HighSpeedCoordinatorResult::TailDrainAccepted &&
          ground.complete_bulk_receive(BulkSessionResult::TerminalEvidenceReady,
                                       ground_evidence(wire.transfer_tag),
                                       wire.terminal, complete_ms) ==
              HighSpeedCoordinatorResult::TerminalWindowReady &&
          ground.open_terminal_window(BulkSessionResult::TerminalWindowOpened,
                                      terminal_window_ms) ==
              HighSpeedCoordinatorResult::ActionReady,
      "Ground peer-receipt deadline fixture did not reach VCTA transmit");
  if (!report.passed) {
    return false;
  }
  for (std::size_t index = 0U; index < wire.terminal.size(); ++index) {
    const std::uint64_t accepted_ms = terminal_window_ms + 5U + index;
    final_terminal = ground.poll(accepted_ms);
    if (final_terminal.type != HighSpeedActionType::SendTerminalEvidence ||
        ground.complete_action(final_terminal.token, TxResult::Accepted,
                               accepted_ms) !=
            HighSpeedCoordinatorResult::Accepted) {
      report.check(false,
                   "Ground peer-receipt fixture did not accept all VCTA");
      return false;
    }
    final_accepted_ms = accepted_ms;
  }
  report.check(
      ground.confirm_terminal_commit(BulkSessionResult::TerminalAckCommitted,
                                     final_accepted_ms) ==
              HighSpeedCoordinatorResult::AwaitingPeer &&
          ground.state() ==
              GroundHighSpeedTddState::AwaitTerminalPhysicalTail,
      "Ground peer-receipt fixture did not await exact final VCTA proof");
  return report.passed;
}

void test_terminal_peer_receipt_deadline(TestReport& report) {
  static_assert(BulkSessionTiming::terminal_ack_timeout_ms == 350U);
  static_assert(BulkSessionTiming::peer_completion_receipt_timeout_ms ==
                1300U);
  static_assert(BulkSessionTiming::peer_completion_receipt_timeout_ms <
                BulkSessionAccounting::heartbeat_deadline_ms);

  WireFixture wire{};
  GroundHighSpeedTddCoordinator on_time{BulkSessionFeature::Enabled};
  HighSpeedAction on_time_final{};
  std::uint64_t on_time_accepted_ms = 0U;
  if (!prepare_ground_await_terminal_peer_receipt(
          on_time, wire, report, on_time_final, on_time_accepted_ms)) {
    return;
  }
  const std::uint64_t inclusive_deadline =
      on_time_accepted_ms +
      BulkSessionTiming::peer_completion_receipt_timeout_ms;
  report.check(
      on_time.tick(inclusive_deadline) ==
              HighSpeedCoordinatorResult::NoAction &&
          on_time.observe_action_tail_drained(
              action_tail(on_time_final, inclusive_deadline),
              inclusive_deadline) ==
              HighSpeedCoordinatorResult::SessionComplete &&
          on_time.state() == GroundHighSpeedTddState::Complete,
      "Ground rejected exact 1300-ms final-VCTA peer receipt boundary");

  GroundHighSpeedTddCoordinator late{BulkSessionFeature::Enabled};
  HighSpeedAction late_final{};
  std::uint64_t late_accepted_ms = 0U;
  if (!prepare_ground_await_terminal_peer_receipt(
          late, wire, report, late_final, late_accepted_ms)) {
    return;
  }
  report.check(
      late.tick(late_accepted_ms +
                BulkSessionTiming::peer_completion_receipt_timeout_ms + 1U) ==
              HighSpeedCoordinatorResult::TerminalWindowTimeout &&
          late.fail_closed(),
      "Ground accepted final-VCTA peer receipt after 1300-ms deadline");
}

}  // namespace

TestReport run_high_speed_tdd_coordinator_test(const std::string& test_id,
                                               std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-HS-TDD-COORD-001") {
    test_happy_path(report);
  } else if (test_id == "UT-HS-TDD-COORD-002") {
    test_disabled_is_inert(report);
  } else if (test_id == "UT-HS-TDD-COORD-003") {
    test_rejected_writes_retry_exact_bytes(report);
  } else if (test_id == "UT-HS-TDD-COORD-004") {
    test_premature_wrong_and_regressed_events_fail_closed(report);
  } else if (test_id == "UT-HS-TDD-COORD-005") {
    test_inclusive_timing_boundaries(report);
  } else if (test_id == "UT-HS-TDD-COORD-006") {
    test_passive_grant_handoff_and_initial_guards(report);
    test_retained_grant_atomic_chronology(report);
  } else if (test_id == "UT-HS-TDD-COORD-007") {
    test_final_bulk_tail_identity_is_exact(report);
    test_ground_local_rx_identity_is_one_shot(report);
  } else if (test_id == "UT-HS-TDD-COORD-008") {
    test_terminal_evidence_requires_physical_tail(report);
    test_terminal_peer_receipt_deadline(report);
  } else {
    report.check(false, "unknown high-speed TDD coordinator test ID");
  }

  report.trace.record({0U, "host", "HS_TDD_COORD", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
