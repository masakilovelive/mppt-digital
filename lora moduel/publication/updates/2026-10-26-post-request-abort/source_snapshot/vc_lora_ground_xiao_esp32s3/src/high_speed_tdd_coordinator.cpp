#include "vc_lora/high_speed_tdd_coordinator.hpp"

#include <algorithm>
#include <limits>

namespace vc_lora {
namespace {

bool active_ground_lease(GroundHighSpeedTddState state) noexcept {
  return state == GroundHighSpeedTddState::AwaitFreshGrant ||
         state == GroundHighSpeedTddState::RequestGuard ||
         state == GroundHighSpeedTddState::RequestReady ||
         state == GroundHighSpeedTddState::RequestDrain ||
         state == GroundHighSpeedTddState::AwaitResponse ||
         state == GroundHighSpeedTddState::BulkReceive;
}

bool active_vehicle_lease(VehicleHighSpeedTddState state) noexcept {
  return state == VehicleHighSpeedTddState::ResponseGuard ||
         state == VehicleHighSpeedTddState::ResponseReady ||
         state == VehicleHighSpeedTddState::ResponseDrain ||
         state == VehicleHighSpeedTddState::PixhawkReady ||
         state == VehicleHighSpeedTddState::AwaitPixhawkCommit ||
         state == VehicleHighSpeedTddState::BulkTransmit ||
         state == VehicleHighSpeedTddState::BulkActionReady;
}

std::uint16_t get_u16(const HighSpeedWireActionBytes& bytes,
                      std::size_t offset) noexcept {
  return static_cast<std::uint16_t>(bytes[offset]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(bytes[offset + 1U]) << 8U);
}

std::uint32_t get_u32(const HighSpeedWireActionBytes& bytes,
                      std::size_t offset) noexcept {
  return static_cast<std::uint32_t>(bytes[offset]) |
         (static_cast<std::uint32_t>(bytes[offset + 1U]) << 8U) |
         (static_cast<std::uint32_t>(bytes[offset + 2U]) << 16U) |
         (static_cast<std::uint32_t>(bytes[offset + 3U]) << 24U);
}

bool ground_completion_valid(const GroundBulkCompletionEvidence& evidence,
                             std::uint32_t transfer_tag) noexcept {
  return transfer_tag != 0U && evidence.transfer_tag == transfer_tag &&
         evidence.parameter_count == BulkSessionAccounting::parameter_count &&
         evidence.parameter_fragment_count ==
             BulkSessionAccounting::parameter_fragment_count &&
         evidence.raw_parameter_bytes ==
             BulkSessionAccounting::raw_parameter_bytes &&
         evidence.heartbeat_count != 0U &&
         evidence.first_heartbeat_gap_ms <=
             BulkSessionAccounting::heartbeat_deadline_ms &&
         evidence.max_heartbeat_gap_ms <=
             BulkSessionAccounting::heartbeat_deadline_ms &&
         evidence.post_heartbeat_gap_ms <=
             BulkSessionAccounting::heartbeat_deadline_ms &&
         evidence.stream_complete && evidence.final_parameter_usb_committed;
}

bool vehicle_completion_valid(const VehicleBulkCompletionEvidence& evidence,
                              std::uint32_t transfer_tag) noexcept {
  return transfer_tag != 0U && evidence.transfer_tag == transfer_tag &&
         evidence.parameter_count == BulkSessionAccounting::parameter_count &&
         evidence.parameter_fragment_count ==
             BulkSessionAccounting::parameter_fragment_count &&
         evidence.raw_parameter_bytes ==
             BulkSessionAccounting::raw_parameter_bytes &&
         evidence.heartbeat_count != 0U && evidence.owner_sealed;
}

bool terminal_fragments_valid(
    const HighSpeedTerminalFragments& fragments) noexcept {
  std::uint32_t record_tag = 0U;
  for (std::size_t index = 0U; index < fragments.size(); ++index) {
    const auto& fragment = fragments[index];
    if (fragment[0] != static_cast<std::uint8_t>('V') ||
        fragment[1] != static_cast<std::uint8_t>('C') ||
        fragment[2] != static_cast<std::uint8_t>('T') ||
        fragment[3] != static_cast<std::uint8_t>('A') || fragment[4] != 1U ||
        fragment[5] != static_cast<std::uint8_t>(index) ||
        fragment[6] != static_cast<std::uint8_t>(fragments.size()) ||
        fragment[7] != 0U ||
        get_u16(fragment, 30U) !=
            crc16_ccitt_false(fragment.data(), fragment.size() - 2U)) {
      return false;
    }
    const std::uint32_t candidate_tag = get_u32(fragment, 8U);
    if (candidate_tag == 0U || (index != 0U && candidate_tag != record_tag)) {
      return false;
    }
    record_tag = candidate_tag;
  }
  return true;
}

bool parameter_request_valid(const MavlinkFrame& frame) noexcept {
  MavlinkFrame parsed{};
  return frame.size <= kTddControlFrameSize &&
         validate_mavlink_frame(frame.bytes.data(), frame.size, parsed) ==
             MavlinkParseStatus::FrameReady &&
         parsed.message_id == 21U && parsed.payload_length >= 2U &&
         parsed.payload_byte_or_zero(0U) != 0U &&
         parsed.payload_byte_or_zero(1U) != 0U;
}

bool is_bulk_head(BulkDataFragmentKind kind) noexcept {
  return kind == BulkDataFragmentKind::ParameterHead ||
         kind == BulkDataFragmentKind::HeartbeatHead;
}

bool is_bulk_tail(BulkDataFragmentKind kind) noexcept {
  return kind == BulkDataFragmentKind::ParameterTail ||
         kind == BulkDataFragmentKind::HeartbeatTail;
}

bool is_matching_bulk_tail(BulkDataFragmentKind head,
                           BulkDataFragmentKind tail) noexcept {
  return (head == BulkDataFragmentKind::ParameterHead &&
          tail == BulkDataFragmentKind::ParameterTail) ||
         (head == BulkDataFragmentKind::HeartbeatHead &&
          tail == BulkDataFragmentKind::HeartbeatTail);
}

}  // namespace

GroundHighSpeedTddCoordinator::GroundHighSpeedTddCoordinator(
    BulkSessionFeature feature) noexcept
    : feature_(feature),
      state_(feature == BulkSessionFeature::Enabled
                 ? GroundHighSpeedTddState::Idle
                 : GroundHighSpeedTddState::Disabled) {}

bool GroundHighSpeedTddCoordinator::note_time(std::uint64_t now_ms) noexcept {
  if (have_last_time_ && now_ms < last_time_ms_) {
    (void)fail(HighSpeedCoordinatorResult::ClockRegression);
    return false;
  }
  have_last_time_ = true;
  last_time_ms_ = now_ms;
  return true;
}

HighSpeedCoordinatorResult GroundHighSpeedTddCoordinator::fail(
    HighSpeedCoordinatorResult reason) noexcept {
  state_ = GroundHighSpeedTddState::FailClosed;
  action_in_flight_ = false;
  active_action_ = {};
  last_error_ = reason;
  return reason;
}

HighSpeedCoordinatorResult GroundHighSpeedTddCoordinator::check_deadlines(
    std::uint64_t now_ms) noexcept {
  if (state_ == GroundHighSpeedTddState::FailClosed) {
    return HighSpeedCoordinatorResult::Latched;
  }
  if (state_ == GroundHighSpeedTddState::AwaitFreshGrant &&
      now_ms - t0_ms_ > BulkSessionTiming::grant_wait_budget_ms) {
    return fail(HighSpeedCoordinatorResult::GrantDeadlineExceeded);
  }
  if (active_ground_lease(state_) &&
      now_ms - t0_ms_ > BulkSessionTiming::hard_lease_ms) {
    return fail(HighSpeedCoordinatorResult::LeaseExpired);
  }
  if ((state_ == GroundHighSpeedTddState::AwaitBulkTail ||
       state_ == GroundHighSpeedTddState::DirectionGuard) &&
      now_ms - t1_ms_ > BulkSessionTiming::terminal_transition_timeout_ms) {
    return fail(HighSpeedCoordinatorResult::TerminalWindowTimeout);
  }
  if (state_ == GroundHighSpeedTddState::TerminalTransmit &&
       now_ms - terminal_window_ms_ >
           BulkSessionTiming::terminal_ack_timeout_ms) {
    return fail(HighSpeedCoordinatorResult::TerminalWindowTimeout);
  }
  if ((state_ == GroundHighSpeedTddState::AwaitTerminalPhysicalTail ||
       state_ == GroundHighSpeedTddState::AwaitTerminalCommit) &&
      now_ms - accepted_terminal_tail_ms_ >
          BulkSessionTiming::peer_completion_receipt_timeout_ms) {
    return fail(HighSpeedCoordinatorResult::TerminalWindowTimeout);
  }
  return HighSpeedCoordinatorResult::NoAction;
}

HighSpeedAction GroundHighSpeedTddCoordinator::issue(
    HighSpeedActionType type, const std::uint8_t* bytes,
    std::size_t size) noexcept {
  if (action_in_flight_ || size > active_action_.bytes.size() ||
      (size != 0U && bytes == nullptr)) {
    return {};
  }
  if (next_token_ == 0U || next_writer_generation_ == 0U) {
    (void)fail(HighSpeedCoordinatorResult::TokenExhausted);
    return {};
  }
  active_action_ = {};
  active_action_.type = type;
  active_action_.token = next_token_++;
  active_action_.writer_generation = next_writer_generation_++;
  active_action_.size = size;
  if (size != 0U) {
    std::copy_n(bytes, size, active_action_.bytes.begin());
  }
  action_in_flight_ = true;
  return active_action_;
}

HighSpeedCoordinatorResult
GroundHighSpeedTddCoordinator::begin_parameter_request(
    BulkSessionResult owner_result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  if (state_ != GroundHighSpeedTddState::Idle) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (owner_result != BulkSessionResult::ParameterRequestHeld) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  t0_ms_ = now_ms;
  state_ = GroundHighSpeedTddState::AwaitFreshGrant;
  return HighSpeedCoordinatorResult::Ready;
}

HighSpeedCoordinatorResult GroundHighSpeedTddCoordinator::stage_fresh_grant(
    BulkSessionResult owner_result, const BulkNegotiationFrame& request,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != GroundHighSpeedTddState::AwaitFreshGrant) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  BulkNegotiationRequest decoded{};
  if (owner_result != BulkSessionResult::NegotiationRequestReady) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  if (BulkNegotiationWireCodec::decode_request(request, decoded) !=
      BulkNegotiationWireStatus::FrameReady) {
    return fail(HighSpeedCoordinatorResult::InvalidWireRecord);
  }
  request_ = request;
  request_guard_started_ms_ = now_ms;
  state_ = GroundHighSpeedTddState::RequestGuard;
  return HighSpeedCoordinatorResult::Ready;
}

HighSpeedAction GroundHighSpeedTddCoordinator::poll(
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled || action_in_flight_) {
    return {};
  }
  if (!note_time(now_ms) ||
      check_deadlines(now_ms) != HighSpeedCoordinatorResult::NoAction) {
    return {};
  }
  if (state_ == GroundHighSpeedTddState::RequestGuard) {
    if (now_ms - request_guard_started_ms_ <
        BulkSessionTiming::direction_guard_ms) {
      return {};
    }
    state_ = GroundHighSpeedTddState::RequestReady;
  }
  if (state_ == GroundHighSpeedTddState::RequestReady) {
    return issue(HighSpeedActionType::SendNegotiationRequest, request_.data(),
                 request_.size());
  }
  if (state_ == GroundHighSpeedTddState::TerminalTransmit) {
    const auto& fragment = terminal_fragments_[terminal_fragment_index_];
    return issue(HighSpeedActionType::SendTerminalEvidence, fragment.data(),
                 fragment.size());
  }
  return {};
}

HighSpeedCoordinatorResult GroundHighSpeedTddCoordinator::complete_action(
    std::uint32_t token, TxResult result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (!action_in_flight_ || token == 0U || token != active_action_.token) {
    return fail(HighSpeedCoordinatorResult::InvalidToken);
  }
  const HighSpeedActionType completed_type = active_action_.type;
  if (result == TxResult::Rejected) {
    action_in_flight_ = false;
    return HighSpeedCoordinatorResult::RetryRetained;
  }
  action_in_flight_ = false;
  accepted_action_ms_ = now_ms;
  if (completed_type == HighSpeedActionType::SendNegotiationRequest &&
      state_ == GroundHighSpeedTddState::RequestReady) {
    accepted_request_token_ = token;
    state_ = GroundHighSpeedTddState::RequestDrain;
    return HighSpeedCoordinatorResult::Accepted;
  }
  if (completed_type == HighSpeedActionType::SendTerminalEvidence &&
      state_ == GroundHighSpeedTddState::TerminalTransmit) {
    ++terminal_fragment_index_;
    if (terminal_fragment_index_ == terminal_fragments_.size()) {
      accepted_terminal_tail_token_ = token;
      accepted_terminal_tail_ms_ = now_ms;
      state_ = GroundHighSpeedTddState::AwaitTerminalPhysicalTail;
    } else {
      state_ = GroundHighSpeedTddState::TerminalTransmit;
    }
    return HighSpeedCoordinatorResult::Accepted;
  }
  return fail(HighSpeedCoordinatorResult::InvalidState);
}

HighSpeedCoordinatorResult
GroundHighSpeedTddCoordinator::confirm_request_commit(
    BulkSessionResult owner_result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != GroundHighSpeedTddState::RequestDrain) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (owner_result != BulkSessionResult::NegotiationRequestCommitted) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  request_committed_ = true;
  if (request_tail_drained_) {
    state_ = GroundHighSpeedTddState::AwaitResponse;
  }
  return HighSpeedCoordinatorResult::AwaitingPeer;
}

HighSpeedCoordinatorResult
GroundHighSpeedTddCoordinator::observe_action_tail_drained(
    const HighSpeedTailDrainEvidence& evidence, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ == GroundHighSpeedTddState::RequestDrain) {
    if (!evidence.physical_tail_complete ||
        evidence.action_token != accepted_request_token_ ||
        evidence.completed_ms < accepted_action_ms_ ||
        evidence.completed_ms > now_ms) {
      return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
    }
    request_tail_drained_ = true;
    if (request_committed_) {
      state_ = GroundHighSpeedTddState::AwaitResponse;
    }
    return HighSpeedCoordinatorResult::TailDrainAccepted;
  }
  if (state_ == GroundHighSpeedTddState::AwaitTerminalPhysicalTail) {
    if (!terminal_commit_confirmed_ || !evidence.physical_tail_complete ||
        evidence.action_token != accepted_terminal_tail_token_ ||
        evidence.completed_ms < accepted_terminal_tail_ms_ ||
        evidence.completed_ms > now_ms) {
      return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
    }
    state_ = GroundHighSpeedTddState::Complete;
    return HighSpeedCoordinatorResult::SessionComplete;
  }
  return fail(HighSpeedCoordinatorResult::InvalidState);
}

HighSpeedCoordinatorResult
GroundHighSpeedTddCoordinator::on_negotiation_response(
    BulkSessionResult owner_result, std::uint32_t transfer_tag,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != GroundHighSpeedTddState::AwaitResponse) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (owner_result != BulkSessionResult::BulkReceiveEnabled ||
      transfer_tag == 0U) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  transfer_tag_ = transfer_tag;
  bulk_receive_started_ms_ = now_ms;
  state_ = GroundHighSpeedTddState::BulkReceive;
  return HighSpeedCoordinatorResult::BulkEnabled;
}

HighSpeedCoordinatorResult GroundHighSpeedTddCoordinator::complete_bulk_receive(
    BulkSessionResult owner_result,
    const GroundBulkCompletionEvidence& evidence,
    const HighSpeedTerminalFragments& terminal_fragments,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != GroundHighSpeedTddState::BulkReceive) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (owner_result != BulkSessionResult::TerminalEvidenceReady ||
      !ground_completion_valid(evidence, transfer_tag_)) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  if (!terminal_fragments_valid(terminal_fragments)) {
    return fail(HighSpeedCoordinatorResult::InvalidWireRecord);
  }
  terminal_fragments_ = terminal_fragments;
  terminal_fragment_index_ = 0U;
  if (evidence.heartbeat_count > (std::numeric_limits<std::uint32_t>::max() -
                                  evidence.parameter_fragment_count) /
                                     2U) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  const std::uint32_t completed_fragment_count =
      evidence.parameter_fragment_count + (evidence.heartbeat_count * 2U);
  if (bulk_rx_identity_bound_ &&
      (bound_bulk_rx_identity_.fragment_count != completed_fragment_count ||
       bound_bulk_rx_identity_.final_wire_ordinal + 1U !=
           completed_fragment_count)) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  if (bulk_tail_observed_ &&
      (expected_fragment_count_ != completed_fragment_count ||
       expected_final_wire_ordinal_ + 1U != completed_fragment_count)) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  expected_fragment_count_ = completed_fragment_count;
  expected_final_wire_ordinal_ = expected_fragment_count_ - 1U;
  t1_ms_ = now_ms;
  state_ = bulk_tail_observed_ ? GroundHighSpeedTddState::DirectionGuard
                               : GroundHighSpeedTddState::AwaitBulkTail;
  return HighSpeedCoordinatorResult::TerminalWindowReady;
}

HighSpeedCoordinatorResult
GroundHighSpeedTddCoordinator::bind_final_bulk_rx_record(
    const HighSpeedLocalRxRecordIdentity& identity,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if ((state_ != GroundHighSpeedTddState::BulkReceive &&
       state_ != GroundHighSpeedTddState::AwaitBulkTail) ||
      bulk_rx_identity_bound_ || bulk_tail_observed_) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  const bool structurally_complete =
      identity.fragment_count >=
          BulkSessionAccounting::parameter_fragment_count &&
      identity.final_wire_ordinal + 1U == identity.fragment_count &&
      (identity.fragment_count -
       BulkSessionAccounting::parameter_fragment_count) %
              2U ==
          0U;
  const bool matches_known_completion =
      expected_fragment_count_ == 0U ||
      (identity.final_wire_ordinal == expected_final_wire_ordinal_ &&
       identity.fragment_count == expected_fragment_count_);
  if (identity.transfer_tag != transfer_tag_ || !structurally_complete ||
      !matches_known_completion || identity.rx_record_token == 0U ||
      identity.rx_ledger_generation == 0U) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  bound_bulk_rx_identity_ = identity;
  bulk_rx_identity_bound_ = true;
  return HighSpeedCoordinatorResult::Ready;
}

HighSpeedCoordinatorResult
GroundHighSpeedTddCoordinator::observe_bulk_tail_drained(
    const HighSpeedStreamTailEvidence& evidence,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != GroundHighSpeedTddState::BulkReceive &&
      state_ != GroundHighSpeedTddState::AwaitBulkTail) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  const bool structurally_complete_tail =
      evidence.fragment_count >=
          BulkSessionAccounting::parameter_fragment_count &&
      evidence.final_wire_ordinal + 1U == evidence.fragment_count &&
      (evidence.fragment_count -
       BulkSessionAccounting::parameter_fragment_count) %
              2U ==
          0U;
  const bool matches_known_completion =
      expected_fragment_count_ == 0U ||
      (evidence.final_wire_ordinal == expected_final_wire_ordinal_ &&
       evidence.fragment_count == expected_fragment_count_);
  const bool matches_bound_rx_identity =
      bulk_rx_identity_bound_ &&
      evidence.transfer_tag == bound_bulk_rx_identity_.transfer_tag &&
      evidence.final_wire_ordinal ==
          bound_bulk_rx_identity_.final_wire_ordinal &&
      evidence.fragment_count == bound_bulk_rx_identity_.fragment_count &&
      evidence.writer_token == bound_bulk_rx_identity_.rx_record_token &&
      evidence.writer_generation ==
          bound_bulk_rx_identity_.rx_ledger_generation;
  if (bulk_tail_observed_ || !matches_bound_rx_identity ||
      !evidence.physical_tail_complete ||
      evidence.transfer_tag != transfer_tag_ || !structurally_complete_tail ||
      !matches_known_completion || evidence.writer_token == 0U ||
      evidence.writer_generation == 0U ||
      evidence.completed_ms < bulk_receive_started_ms_ ||
      evidence.completed_ms > now_ms) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  stream_tail_ms_ = evidence.completed_ms;
  expected_final_wire_ordinal_ = evidence.final_wire_ordinal;
  expected_fragment_count_ = evidence.fragment_count;
  bulk_tail_observed_ = true;
  bound_bulk_rx_identity_ = {};
  bulk_rx_identity_bound_ = false;
  if (state_ == GroundHighSpeedTddState::AwaitBulkTail) {
    state_ = GroundHighSpeedTddState::DirectionGuard;
  }
  return HighSpeedCoordinatorResult::TailDrainAccepted;
}

HighSpeedCoordinatorResult GroundHighSpeedTddCoordinator::open_terminal_window(
    BulkSessionResult owner_result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != GroundHighSpeedTddState::DirectionGuard) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (now_ms - stream_tail_ms_ < BulkSessionTiming::direction_guard_ms) {
    return fail(HighSpeedCoordinatorResult::DirectionGuardIncomplete);
  }
  if (owner_result != BulkSessionResult::TerminalWindowOpened) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  terminal_window_ms_ = now_ms;
  state_ = GroundHighSpeedTddState::TerminalTransmit;
  return HighSpeedCoordinatorResult::ActionReady;
}

HighSpeedCoordinatorResult
GroundHighSpeedTddCoordinator::confirm_terminal_commit(
    BulkSessionResult owner_result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != GroundHighSpeedTddState::AwaitTerminalPhysicalTail) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (owner_result != BulkSessionResult::TerminalAckCommitted) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  terminal_commit_confirmed_ = true;
  return HighSpeedCoordinatorResult::AwaitingPeer;
}

HighSpeedCoordinatorResult GroundHighSpeedTddCoordinator::tick(
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  return check_deadlines(now_ms);
}

VehicleHighSpeedTddCoordinator::VehicleHighSpeedTddCoordinator(
    BulkSessionFeature feature) noexcept
    : feature_(feature),
      state_(feature == BulkSessionFeature::Enabled
                 ? VehicleHighSpeedTddState::Idle
                 : VehicleHighSpeedTddState::Disabled) {}

bool VehicleHighSpeedTddCoordinator::note_time(std::uint64_t now_ms) noexcept {
  if (have_last_time_ && now_ms < last_time_ms_) {
    (void)fail(HighSpeedCoordinatorResult::ClockRegression);
    return false;
  }
  have_last_time_ = true;
  last_time_ms_ = now_ms;
  return true;
}

HighSpeedCoordinatorResult VehicleHighSpeedTddCoordinator::fail(
    HighSpeedCoordinatorResult reason) noexcept {
  state_ = VehicleHighSpeedTddState::FailClosed;
  action_in_flight_ = false;
  active_action_ = {};
  last_error_ = reason;
  return reason;
}

HighSpeedCoordinatorResult VehicleHighSpeedTddCoordinator::check_deadlines(
    std::uint64_t now_ms) noexcept {
  if (state_ == VehicleHighSpeedTddState::FailClosed) {
    return HighSpeedCoordinatorResult::Latched;
  }
  if (active_vehicle_lease(state_) &&
      now_ms - lease_epoch_ms_ > BulkSessionTiming::hard_lease_ms) {
    return fail(HighSpeedCoordinatorResult::LeaseExpired);
  }
  if ((state_ == VehicleHighSpeedTddState::AwaitBulkTail ||
       state_ == VehicleHighSpeedTddState::DirectionGuard ||
       state_ == VehicleHighSpeedTddState::TerminalWindowReady ||
       state_ == VehicleHighSpeedTddState::AwaitTerminalWindowCommit) &&
      now_ms - terminal_transition_ms_ >
          BulkSessionTiming::terminal_transition_timeout_ms) {
    return fail(HighSpeedCoordinatorResult::TerminalWindowTimeout);
  }
  if (state_ == VehicleHighSpeedTddState::AwaitTerminalAck &&
      now_ms - terminal_window_ms_ >
          BulkSessionTiming::terminal_ack_timeout_ms) {
    return fail(HighSpeedCoordinatorResult::TerminalWindowTimeout);
  }
  return HighSpeedCoordinatorResult::NoAction;
}

HighSpeedAction VehicleHighSpeedTddCoordinator::issue(
    HighSpeedActionType type, const std::uint8_t* bytes,
    std::size_t size) noexcept {
  if (action_in_flight_ || size > active_action_.bytes.size() ||
      (size != 0U && bytes == nullptr)) {
    return {};
  }
  if (next_token_ == 0U || next_writer_generation_ == 0U) {
    (void)fail(HighSpeedCoordinatorResult::TokenExhausted);
    return {};
  }
  active_action_ = {};
  active_action_.type = type;
  active_action_.token = next_token_++;
  active_action_.writer_generation = next_writer_generation_++;
  active_action_.size = size;
  if (size != 0U) {
    std::copy_n(bytes, size, active_action_.bytes.begin());
  }
  action_in_flight_ = true;
  return active_action_;
}

HighSpeedCoordinatorResult
VehicleHighSpeedTddCoordinator::adopt_retained_grant_on_terminal_request(
    BulkSessionResult grant_owner_result,
    BulkSessionResult request_owner_result,
    const HighSpeedWireActionBytes& grant_frame,
    const HighSpeedStandardGrantEvidence& evidence,
    const BulkNegotiationFrame& request,
    const BulkNegotiationFrame& response,
    std::uint32_t transfer_tag,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  if (state_ != VehicleHighSpeedTddState::Idle) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  const DecodeEvent decoded =
      decode_control(grant_frame.data(), grant_frame.size());
  if (grant_owner_result != BulkSessionResult::GrantArmed ||
      request_owner_result != BulkSessionResult::NegotiationResponseReady) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  if (evidence.grant_session_id == 0U || evidence.grant_cycle_id == 0U ||
      evidence.writer_token == 0U || evidence.writer_generation == 0U ||
      !evidence.accepted || !evidence.physical_tail_complete ||
      evidence.completed_ms == 0U || evidence.completed_ms > now_ms) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  if (now_ms - evidence.completed_ms >
      BulkSessionTiming::grant_wait_budget_ms) {
    return fail(HighSpeedCoordinatorResult::GrantDeadlineExceeded);
  }
  if (decoded.status != DecodeStatus::Message ||
      decoded.message.type != ControlType::UlGrant ||
      decoded.message.session_id == 0U || decoded.message.cycle_id == 0U) {
    return fail(HighSpeedCoordinatorResult::InvalidWireRecord);
  }
  if (evidence.grant_session_id != decoded.message.session_id ||
      evidence.grant_cycle_id != decoded.message.cycle_id) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  BulkNegotiationRequest decoded_request{};
  BulkNegotiationIdentity identity{};
  std::uint32_t derived_tag = 0U;
  if (BulkNegotiationWireCodec::decode_request(request, decoded_request) !=
          BulkNegotiationWireStatus::FrameReady ||
      decoded_request.captured_vehicle_grant_session !=
          decoded.message.session_id ||
      decoded_request.captured_vehicle_grant_cycle != decoded.message.cycle_id ||
      BulkNegotiationWireCodec::derive_accepted_transfer(
          request, response, identity, derived_tag) !=
          BulkNegotiationWireStatus::TransferReady ||
      transfer_tag == 0U || transfer_tag != derived_tag) {
    return fail(HighSpeedCoordinatorResult::InvalidWireRecord);
  }
  grant_session_ = decoded.message.session_id;
  grant_cycle_ = decoded.message.cycle_id;
  response_ = response;
  transfer_tag_ = transfer_tag;
  retained_grant_tail_ms_ = evidence.completed_ms;
  lease_epoch_ms_ = now_ms;
  negotiation_request_tail_ms_ = now_ms;
  state_ = VehicleHighSpeedTddState::ResponseGuard;
  return HighSpeedCoordinatorResult::Ready;
}

HighSpeedCoordinatorResult
VehicleHighSpeedTddCoordinator::stage_pixhawk_request(
    BulkSessionResult owner_result, const MavlinkFrame& request,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != VehicleHighSpeedTddState::ResponseDrain) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (owner_result != BulkSessionResult::NegotiationResponseCommitted) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  if (!parameter_request_valid(request)) {
    return fail(HighSpeedCoordinatorResult::InvalidWireRecord);
  }
  pixhawk_request_ = request;
  pixhawk_request_staged_ = true;
  if (response_tail_drained_) {
    state_ = VehicleHighSpeedTddState::PixhawkReady;
    return HighSpeedCoordinatorResult::ActionReady;
  }
  return HighSpeedCoordinatorResult::AwaitingPeer;
}

HighSpeedCoordinatorResult
VehicleHighSpeedTddCoordinator::confirm_pixhawk_request(
    BulkSessionResult owner_result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != VehicleHighSpeedTddState::AwaitPixhawkCommit) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (owner_result != BulkSessionResult::BulkDownlinkEnabled) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  state_ = VehicleHighSpeedTddState::BulkTransmit;
  return HighSpeedCoordinatorResult::BulkEnabled;
}

HighSpeedCoordinatorResult VehicleHighSpeedTddCoordinator::stage_bulk_fragment(
    const BulkDataFragment& fragment, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != VehicleHighSpeedTddState::BulkTransmit) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  BulkDataDecodedFragment decoded{};
  if (BulkDataWireCodec::decode_fragment(fragment, decoded) !=
          BulkDataWireStatus::FragmentReady ||
      decoded.transfer_tag != transfer_tag_ ||
      next_bulk_wire_ordinal_ >
          static_cast<std::uint32_t>(
              std::numeric_limits<std::uint16_t>::max()) ||
      decoded.wire_ordinal != next_bulk_wire_ordinal_ ||
      (!bulk_frame_active_ && !is_bulk_head(decoded.kind)) ||
      (bulk_frame_active_ &&
       (!is_bulk_tail(decoded.kind) ||
        !is_matching_bulk_tail(active_bulk_head_kind_, decoded.kind))) ||
      (decoded.kind == BulkDataFragmentKind::ParameterHead &&
       accepted_parameter_count_ >= BulkSessionAccounting::parameter_count)) {
    return fail(HighSpeedCoordinatorResult::InvalidWireRecord);
  }
  bulk_fragment_ = fragment;
  staged_bulk_kind_ = decoded.kind;
  state_ = VehicleHighSpeedTddState::BulkActionReady;
  return HighSpeedCoordinatorResult::ActionReady;
}

HighSpeedCoordinatorResult
VehicleHighSpeedTddCoordinator::complete_bulk_downlink(
    BulkSessionResult owner_result,
    const VehicleBulkCompletionEvidence& evidence,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != VehicleHighSpeedTddState::BulkTransmit) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (owner_result != BulkSessionResult::TerminalEvidenceReady ||
      !vehicle_completion_valid(evidence, transfer_tag_) ||
      last_bulk_action_token_ == 0U || bulk_frame_active_ ||
      accepted_parameter_count_ != evidence.parameter_count ||
      accepted_parameter_fragment_count_ != evidence.parameter_fragment_count ||
      accepted_raw_parameter_bytes_ != evidence.raw_parameter_bytes ||
      accepted_heartbeat_count_ != evidence.heartbeat_count ||
      next_bulk_wire_ordinal_ != accepted_parameter_fragment_count_ +
                                     (accepted_heartbeat_count_ * 2U)) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  terminal_transition_ms_ = now_ms;
  state_ = VehicleHighSpeedTddState::AwaitBulkTail;
  return HighSpeedCoordinatorResult::TerminalWindowReady;
}

HighSpeedCoordinatorResult
VehicleHighSpeedTddCoordinator::observe_bulk_tail_drained(
    const HighSpeedStreamTailEvidence& evidence,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != VehicleHighSpeedTddState::AwaitBulkTail) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (!evidence.physical_tail_complete ||
      evidence.transfer_tag != transfer_tag_ || evidence.fragment_count == 0U ||
      evidence.final_wire_ordinal != evidence.fragment_count - 1U ||
      evidence.final_wire_ordinal + 1U != next_bulk_wire_ordinal_ ||
      evidence.fragment_count != next_bulk_wire_ordinal_ ||
      evidence.writer_token != last_bulk_action_token_ ||
      evidence.writer_generation != last_bulk_writer_generation_ ||
      evidence.completed_ms < last_bulk_action_ms_ ||
      evidence.completed_ms > now_ms) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  stream_tail_ms_ = evidence.completed_ms;
  state_ = VehicleHighSpeedTddState::DirectionGuard;
  return HighSpeedCoordinatorResult::TailDrainAccepted;
}

HighSpeedAction VehicleHighSpeedTddCoordinator::poll(
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled || action_in_flight_) {
    return {};
  }
  if (!note_time(now_ms) ||
      check_deadlines(now_ms) != HighSpeedCoordinatorResult::NoAction) {
    return {};
  }
  switch (state_) {
    case VehicleHighSpeedTddState::ResponseGuard:
      if (now_ms - negotiation_request_tail_ms_ <
          BulkSessionTiming::direction_guard_ms) {
        return {};
      }
      state_ = VehicleHighSpeedTddState::ResponseReady;
      return issue(HighSpeedActionType::SendNegotiationResponse,
                   response_.data(), response_.size());
    case VehicleHighSpeedTddState::ResponseReady:
      return issue(HighSpeedActionType::SendNegotiationResponse,
                   response_.data(), response_.size());
    case VehicleHighSpeedTddState::PixhawkReady:
      return issue(HighSpeedActionType::SendPixhawkParameterRequest,
                   pixhawk_request_.bytes.data(), pixhawk_request_.size);
    case VehicleHighSpeedTddState::BulkActionReady:
      return issue(HighSpeedActionType::SendBulkFragment, bulk_fragment_.data(),
                   bulk_fragment_.size());
    case VehicleHighSpeedTddState::DirectionGuard:
      if (now_ms - stream_tail_ms_ < BulkSessionTiming::direction_guard_ms) {
        return {};
      }
      state_ = VehicleHighSpeedTddState::TerminalWindowReady;
      return issue(HighSpeedActionType::OpenTerminalAckWindow, nullptr, 0U);
    case VehicleHighSpeedTddState::TerminalWindowReady:
      return issue(HighSpeedActionType::OpenTerminalAckWindow, nullptr, 0U);
    default:
      return {};
  }
}

HighSpeedCoordinatorResult VehicleHighSpeedTddCoordinator::complete_action(
    std::uint32_t token, TxResult result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (!action_in_flight_ || token == 0U || token != active_action_.token) {
    return fail(HighSpeedCoordinatorResult::InvalidToken);
  }
  const HighSpeedActionType completed_type = active_action_.type;
  if (result == TxResult::Rejected) {
    action_in_flight_ = false;
    return HighSpeedCoordinatorResult::RetryRetained;
  }
  action_in_flight_ = false;
  accepted_action_ms_ = now_ms;
  accepted_tail_token_ = token;
  switch (completed_type) {
    case HighSpeedActionType::SendNegotiationResponse:
      if (state_ != VehicleHighSpeedTddState::ResponseReady) {
        return fail(HighSpeedCoordinatorResult::InvalidState);
      }
      state_ = VehicleHighSpeedTddState::ResponseDrain;
      return HighSpeedCoordinatorResult::Accepted;
    case HighSpeedActionType::SendPixhawkParameterRequest:
      if (state_ != VehicleHighSpeedTddState::PixhawkReady) {
        return fail(HighSpeedCoordinatorResult::InvalidState);
      }
      state_ = VehicleHighSpeedTddState::AwaitPixhawkCommit;
      return HighSpeedCoordinatorResult::Accepted;
    case HighSpeedActionType::SendBulkFragment:
      if (state_ != VehicleHighSpeedTddState::BulkActionReady) {
        return fail(HighSpeedCoordinatorResult::InvalidState);
      }
      ++next_bulk_wire_ordinal_;
      switch (staged_bulk_kind_) {
        case BulkDataFragmentKind::ParameterHead:
          ++accepted_parameter_fragment_count_;
          active_bulk_head_kind_ = staged_bulk_kind_;
          bulk_frame_active_ = true;
          break;
        case BulkDataFragmentKind::ParameterTail:
          ++accepted_parameter_fragment_count_;
          ++accepted_parameter_count_;
          accepted_raw_parameter_bytes_ += 37U;
          bulk_frame_active_ = false;
          break;
        case BulkDataFragmentKind::HeartbeatHead:
          active_bulk_head_kind_ = staged_bulk_kind_;
          bulk_frame_active_ = true;
          break;
        case BulkDataFragmentKind::HeartbeatTail:
          ++accepted_heartbeat_count_;
          bulk_frame_active_ = false;
          break;
      }
      last_bulk_action_token_ = token;
      last_bulk_writer_generation_ = active_action_.writer_generation;
      last_bulk_action_ms_ = now_ms;
      state_ = VehicleHighSpeedTddState::BulkTransmit;
      return HighSpeedCoordinatorResult::Accepted;
    case HighSpeedActionType::OpenTerminalAckWindow:
      if (state_ != VehicleHighSpeedTddState::TerminalWindowReady) {
        return fail(HighSpeedCoordinatorResult::InvalidState);
      }
      state_ = VehicleHighSpeedTddState::AwaitTerminalWindowCommit;
      return HighSpeedCoordinatorResult::Accepted;
    default:
      return fail(HighSpeedCoordinatorResult::InvalidState);
  }
}

HighSpeedCoordinatorResult
VehicleHighSpeedTddCoordinator::observe_action_tail_drained(
    const HighSpeedTailDrainEvidence& evidence, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != VehicleHighSpeedTddState::ResponseDrain) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (!evidence.physical_tail_complete ||
      evidence.action_token != accepted_tail_token_ ||
      evidence.completed_ms < accepted_action_ms_ ||
      evidence.completed_ms > now_ms) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  response_tail_drained_ = true;
  if (pixhawk_request_staged_) {
    state_ = VehicleHighSpeedTddState::PixhawkReady;
  }
  return HighSpeedCoordinatorResult::TailDrainAccepted;
}

HighSpeedCoordinatorResult
VehicleHighSpeedTddCoordinator::confirm_terminal_window(
    BulkSessionResult owner_result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != VehicleHighSpeedTddState::AwaitTerminalWindowCommit) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (owner_result != BulkSessionResult::TerminalWindowOpened) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  terminal_window_ms_ = now_ms;
  state_ = VehicleHighSpeedTddState::AwaitTerminalAck;
  return HighSpeedCoordinatorResult::AwaitingPeer;
}

HighSpeedCoordinatorResult VehicleHighSpeedTddCoordinator::confirm_terminal_ack(
    BulkSessionResult owner_result, std::uint32_t transfer_tag,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  const HighSpeedCoordinatorResult deadline = check_deadlines(now_ms);
  if (deadline != HighSpeedCoordinatorResult::NoAction) {
    return deadline;
  }
  if (state_ != VehicleHighSpeedTddState::AwaitTerminalAck) {
    return fail(HighSpeedCoordinatorResult::InvalidState);
  }
  if (owner_result != BulkSessionResult::SessionComplete ||
      transfer_tag == 0U || transfer_tag != transfer_tag_) {
    return fail(HighSpeedCoordinatorResult::EvidenceMismatch);
  }
  state_ = VehicleHighSpeedTddState::Complete;
  return HighSpeedCoordinatorResult::SessionComplete;
}

HighSpeedCoordinatorResult VehicleHighSpeedTddCoordinator::tick(
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return HighSpeedCoordinatorResult::NoAction;
  }
  if (!note_time(now_ms)) {
    return HighSpeedCoordinatorResult::ClockRegression;
  }
  return check_deadlines(now_ms);
}

}  // namespace vc_lora
