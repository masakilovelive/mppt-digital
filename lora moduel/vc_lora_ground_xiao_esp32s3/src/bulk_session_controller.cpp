#include "vc_lora/bulk_session_controller.hpp"

#include <algorithm>

namespace vc_lora {
namespace {

bool config_valid(const GroundBulkSessionConfig& config) noexcept {
  return config.ground_boot_id != 0U && config.ground_session_id != 0U &&
         config.request_sequence != 0U && config.ground_nonce != 0U;
}

bool config_valid(const VehicleBulkSessionConfig& config) noexcept {
  return config.vehicle_boot_id != 0U && config.lease_sequence != 0U &&
         config.vehicle_challenge_nonce != 0U &&
         config.mavlink_system_id != 0U &&
         config.mavlink_component_id != 0U;
}

bool grant_is_fresh(std::uint16_t candidate_session,
                    std::uint16_t candidate_cycle,
                    std::uint16_t baseline_session,
                    std::uint16_t baseline_cycle) noexcept {
  if (candidate_session == 0U) {
    return false;
  }
  if (candidate_session == baseline_session) {
    return compare_sequence(candidate_cycle, baseline_cycle) ==
           SequenceOrder::Newer;
  }
  return compare_sequence(candidate_session, baseline_session) ==
         SequenceOrder::Newer;
}

bool same_record(const BulkNegotiationFrame& lhs,
                 const std::uint8_t* rhs, std::size_t size) noexcept {
  return rhs != nullptr && size == lhs.size() &&
         std::equal(lhs.begin(), lhs.end(), rhs);
}

bool active_ground_state(GroundBulkSessionState state) noexcept {
  return state == GroundBulkSessionState::AwaitFreshGrant ||
         state == GroundBulkSessionState::RequestReady ||
         state == GroundBulkSessionState::AwaitResponse ||
         state == GroundBulkSessionState::BulkReceive ||
         state == GroundBulkSessionState::TerminalEvidenceReady ||
         state == GroundBulkSessionState::TerminalAckReady;
}

bool ground_hard_lease_state(GroundBulkSessionState state) noexcept {
  return state == GroundBulkSessionState::AwaitFreshGrant ||
         state == GroundBulkSessionState::RequestReady ||
         state == GroundBulkSessionState::AwaitResponse ||
         state == GroundBulkSessionState::BulkReceive;
}

bool active_vehicle_lease_state(VehicleBulkSessionState state) noexcept {
  return state == VehicleBulkSessionState::ResponseReady ||
         state == VehicleBulkSessionState::PixhawkRequestReady ||
         state == VehicleBulkSessionState::BulkDownlink;
}

bool same_identity(const BulkNegotiationIdentity& lhs,
                   const BulkNegotiationIdentity& rhs) noexcept {
  return lhs.session_id == rhs.session_id &&
         lhs.stream_id == rhs.stream_id && lhs.lease_id == rhs.lease_id &&
         lhs.ground_request_nonce == rhs.ground_request_nonce &&
         lhs.vehicle_challenge_nonce == rhs.vehicle_challenge_nonce;
}

bool heartbeat_evidence_valid(std::uint32_t count, std::uint32_t first_gap,
                              std::uint32_t max_gap,
                              std::uint32_t post_gap) noexcept {
  return count != 0U &&
         first_gap <= BulkSessionAccounting::heartbeat_deadline_ms &&
         max_gap <= BulkSessionAccounting::heartbeat_deadline_ms &&
         post_gap <= BulkSessionAccounting::heartbeat_deadline_ms;
}

bool terminal_window_evidence_valid(
    const BulkSessionTerminalWindowEvidence& evidence,
    std::uint64_t now_ms) noexcept {
  return evidence.final_tail_drained && evidence.direction_guard_complete &&
         evidence.direction_guard_completed_ms >=
             evidence.final_tail_drained_ms &&
         evidence.direction_guard_completed_ms -
                 evidence.final_tail_drained_ms >=
             BulkSessionTiming::direction_guard_ms &&
         now_ms >= evidence.direction_guard_completed_ms;
}

}  // namespace

GroundBulkSessionController::GroundBulkSessionController(
    const GroundBulkSessionConfig& config) noexcept
    : feature_(config.feature),
      ground_boot_id_(config.ground_boot_id),
      ground_session_id_(config.ground_session_id),
      request_sequence_(config.request_sequence),
      ground_nonce_(config.ground_nonce) {
  if (feature_ == BulkSessionFeature::Disabled) {
    state_ = GroundBulkSessionState::Disabled;
    return;
  }
  if (!config_valid(config)) {
    state_ = GroundBulkSessionState::FailClosed;
    last_error_ = BulkSessionResult::InvalidConfiguration;
    return;
  }
  state_ = GroundBulkSessionState::Standard;
}

BulkSessionResult GroundBulkSessionController::observe_standard_grant(
    std::uint16_t session_id, std::uint16_t cycle_id,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != GroundBulkSessionState::Standard) {
    return BulkSessionResult::BusyHold;
  }
  if (session_id == 0U) {
    return BulkSessionResult::InvalidArgument;
  }
  if (have_grant_watermark_ &&
      !grant_is_fresh(session_id, cycle_id, grant_session_, grant_cycle_)) {
    return BulkSessionResult::NoAction;
  }
  have_grant_watermark_ = true;
  grant_session_ = session_id;
  grant_cycle_ = cycle_id;
  return BulkSessionResult::GrantBaselineCaptured;
}

BulkSessionResult GroundBulkSessionController::on_ground_usb_frame(
    const MavlinkFrame& frame, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (active_ground_state(state_)) {
    if (ground_hard_lease_state(state_) && lease_expired(now_ms)) {
      return fail(BulkSessionResult::LeaseExpired);
    }
    if (state_ == GroundBulkSessionState::TerminalEvidenceReady && has_t1_ &&
        now_ms - t1_ms_ >
            BulkSessionTiming::terminal_transition_timeout_ms) {
      return fail(BulkSessionResult::TerminalWindowTimeout);
    }
    if (state_ == GroundBulkSessionState::TerminalAckReady &&
        has_terminal_wait_epoch_ &&
        now_ms - terminal_wait_epoch_ms_ >
            BulkSessionTiming::terminal_ack_timeout_ms) {
      return fail(BulkSessionResult::TerminalAckTimeout);
    }
    return BulkSessionResult::BusyHold;
  }
  if (state_ == GroundBulkSessionState::Complete) {
    return BulkSessionResult::PassThrough;
  }
  if (state_ != GroundBulkSessionState::Standard) {
    return BulkSessionResult::InvalidState;
  }

  MavlinkFrame validated{};
  const MavlinkParseStatus validation = validate_mavlink_frame(
      frame.bytes.data(), frame.size, validated);
  if (validation != MavlinkParseStatus::FrameReady) {
    return frame.message_id == 21U ? BulkSessionResult::InvalidMavlink
                                   : BulkSessionResult::PassThrough;
  }
  if (validated.message_id != 21U) {
    return BulkSessionResult::PassThrough;
  }
  if (!have_grant_watermark_) {
    return BulkSessionResult::NotHighSpeedReady;
  }

  held_param_request_ = validated;
  held_request_ = true;
  has_t0_ = true;
  t0_ms_ = now_ms;
  state_ = GroundBulkSessionState::AwaitFreshGrant;
  return BulkSessionResult::ParameterRequestHeld;
}

BulkSessionResult GroundBulkSessionController::on_fresh_grant(
    std::uint16_t session_id, std::uint16_t cycle_id,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != GroundBulkSessionState::AwaitFreshGrant || !has_t0_ ||
      !held_request_ || !have_grant_watermark_) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (lease_expired(now_ms)) {
    return fail(BulkSessionResult::LeaseExpired);
  }
  if (now_ms - t0_ms_ > BulkSessionTiming::grant_wait_budget_ms) {
    return fail(BulkSessionResult::GrantDeadlineExceeded);
  }
  if (!grant_is_fresh(session_id, cycle_id, grant_session_, grant_cycle_)) {
    return fail(BulkSessionResult::StaleGrant);
  }

  BulkNegotiationRequest request{};
  request.ground_boot_id = ground_boot_id_;
  request.ground_session_id = ground_session_id_;
  request.request_sequence = request_sequence_;
  request.ground_nonce = ground_nonce_;
  request.target_system = held_param_request_.payload_byte_or_zero(0U);
  request.target_component = held_param_request_.payload_byte_or_zero(1U);
  request.captured_vehicle_grant_session = session_id;
  request.captured_vehicle_grant_cycle = cycle_id;
  BulkNegotiationFrame candidate{};
  if (BulkNegotiationWireCodec::encode_request(request, candidate) !=
      BulkNegotiationWireStatus::FrameReady) {
    return fail(BulkSessionResult::InvalidNegotiationRecord);
  }

  grant_session_ = session_id;
  grant_cycle_ = cycle_id;
  request_record_ = candidate;
  request_record_ready_ = true;
  request_record_committed_ = false;
  state_ = GroundBulkSessionState::RequestReady;
  return BulkSessionResult::NegotiationRequestReady;
}

BulkSessionResult GroundBulkSessionController::complete_request_tx(
    TxResult result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != GroundBulkSessionState::RequestReady ||
      !request_record_ready_) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (lease_expired(now_ms)) {
    return fail(BulkSessionResult::LeaseExpired);
  }
  if (result == TxResult::Rejected) {
    return BulkSessionResult::RetryRetained;
  }
  request_record_committed_ = true;
  state_ = GroundBulkSessionState::AwaitResponse;
  return BulkSessionResult::NegotiationRequestCommitted;
}

BulkSessionResult GroundBulkSessionController::on_negotiation_response(
    const std::uint8_t* record, std::size_t size,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != GroundBulkSessionState::AwaitResponse ||
      !request_record_committed_) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (lease_expired(now_ms)) {
    return fail(BulkSessionResult::LeaseExpired);
  }
  if (record == nullptr) {
    return fail(BulkSessionResult::InvalidArgument);
  }
  if (size < BulkNegotiationWireCodec::frame_bytes) {
    return fail(BulkSessionResult::PartialNegotiationRecord);
  }
  if (size != BulkNegotiationWireCodec::frame_bytes) {
    return fail(BulkSessionResult::InvalidNegotiationRecord);
  }

  BulkNegotiationFrame response{};
  std::copy_n(record, response.size(), response.begin());
  BulkNegotiationIdentity candidate_identity{};
  std::uint32_t candidate_tag = 0U;
  const BulkNegotiationWireStatus decoded =
      BulkNegotiationWireCodec::derive_accepted_transfer(
          request_record_, response, candidate_identity, candidate_tag);
  if (decoded == BulkNegotiationWireStatus::PeerRejected) {
    return fail(BulkSessionResult::PeerRejected);
  }
  if (decoded != BulkNegotiationWireStatus::TransferReady) {
    return fail(BulkSessionResult::InvalidNegotiationRecord);
  }

  identity_ = candidate_identity;
  transfer_tag_ = candidate_tag;
  state_ = GroundBulkSessionState::BulkReceive;
  return BulkSessionResult::BulkReceiveEnabled;
}

BulkSessionResult GroundBulkSessionController::complete_bulk_receive(
    const GroundBulkCompletionEvidence& evidence,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != GroundBulkSessionState::BulkReceive) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (lease_expired(now_ms)) {
    return fail(BulkSessionResult::LeaseExpired);
  }
  if (!evidence.stream_complete) {
    return fail(BulkSessionResult::DecoderIncomplete);
  }
  if (evidence.transfer_tag != transfer_tag_ ||
      evidence.parameter_count != BulkSessionAccounting::parameter_count ||
      evidence.parameter_fragment_count !=
          BulkSessionAccounting::parameter_fragment_count ||
      evidence.raw_parameter_bytes !=
          BulkSessionAccounting::raw_parameter_bytes) {
    return fail(BulkSessionResult::CompletionEvidenceMismatch);
  }
  if (!evidence.final_parameter_usb_committed ||
      !heartbeat_evidence_valid(
          evidence.heartbeat_count, evidence.first_heartbeat_gap_ms,
          evidence.max_heartbeat_gap_ms, evidence.post_heartbeat_gap_ms)) {
    return fail(BulkSessionResult::CompletionEvidenceMismatch);
  }

  terminal_evidence_ = {};
  terminal_evidence_.identity = identity_;
  terminal_evidence_.transfer_tag = transfer_tag_;
  terminal_evidence_.parameter_count = evidence.parameter_count;
  terminal_evidence_.parameter_fragment_count =
      evidence.parameter_fragment_count;
  terminal_evidence_.raw_parameter_bytes = evidence.raw_parameter_bytes;
  terminal_evidence_.heartbeat_count = evidence.heartbeat_count;
  terminal_evidence_.first_heartbeat_gap_ms =
      evidence.first_heartbeat_gap_ms;
  terminal_evidence_.max_heartbeat_gap_ms = evidence.max_heartbeat_gap_ms;
  terminal_evidence_.post_heartbeat_gap_ms =
      evidence.post_heartbeat_gap_ms;
  terminal_evidence_.ground_stream_complete = true;
  terminal_evidence_.final_parameter_usb_committed = true;
  terminal_evidence_ready_ = true;
  has_t1_ = true;
  t1_ms_ = now_ms;
  state_ = GroundBulkSessionState::TerminalEvidenceReady;
  return BulkSessionResult::TerminalEvidenceReady;
}

BulkSessionResult GroundBulkSessionController::open_terminal_ack_window(
    const BulkSessionTerminalWindowEvidence& evidence,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != GroundBulkSessionState::TerminalEvidenceReady ||
      !terminal_evidence_ready_) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (!has_t1_ ||
      now_ms - t1_ms_ >
          BulkSessionTiming::terminal_transition_timeout_ms) {
    return fail(BulkSessionResult::TerminalWindowTimeout);
  }
  // Ground is the receiver: the final physical RF tail necessarily precedes
  // decode and the host-visible index-931 USB commit (t1).  Opening remains
  // ordered after t1 by state and monotonic now_ms, while the 100-ms direction
  // guard is measured from the honest RF-tail timestamp.
  if (!terminal_window_evidence_valid(evidence, now_ms)) {
    return fail(BulkSessionResult::TerminalWindowEvidenceMismatch);
  }
  has_terminal_wait_epoch_ = true;
  terminal_wait_epoch_ms_ = now_ms;
  state_ = GroundBulkSessionState::TerminalAckReady;
  return BulkSessionResult::TerminalWindowOpened;
}

BulkSessionResult GroundBulkSessionController::complete_terminal_ack_tx(
    TxResult result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != GroundBulkSessionState::TerminalAckReady ||
      !terminal_evidence_ready_ || !has_terminal_wait_epoch_) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (now_ms - terminal_wait_epoch_ms_ >
      BulkSessionTiming::terminal_ack_timeout_ms) {
    return fail(BulkSessionResult::TerminalAckTimeout);
  }
  if (result == TxResult::Rejected) {
    return BulkSessionResult::RetryRetained;
  }
  state_ = GroundBulkSessionState::Complete;
  held_request_ = false;
  return BulkSessionResult::TerminalAckCommitted;
}

BulkSessionResult GroundBulkSessionController::tick(
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (!active_ground_state(state_)) {
    return BulkSessionResult::NoAction;
  }
  if (ground_hard_lease_state(state_) && lease_expired(now_ms)) {
    return fail(BulkSessionResult::LeaseExpired);
  }
  if (state_ == GroundBulkSessionState::TerminalEvidenceReady && has_t1_ &&
      now_ms - t1_ms_ >
          BulkSessionTiming::terminal_transition_timeout_ms) {
    return fail(BulkSessionResult::TerminalWindowTimeout);
  }
  if (state_ == GroundBulkSessionState::TerminalAckReady &&
      has_terminal_wait_epoch_ &&
      now_ms - terminal_wait_epoch_ms_ >
          BulkSessionTiming::terminal_ack_timeout_ms) {
    return fail(BulkSessionResult::TerminalAckTimeout);
  }
  if (state_ == GroundBulkSessionState::AwaitFreshGrant && has_t0_ &&
      now_ms - t0_ms_ > BulkSessionTiming::grant_wait_budget_ms) {
    return fail(BulkSessionResult::GrantDeadlineExceeded);
  }
  return BulkSessionResult::NoAction;
}

BulkSessionResult GroundBulkSessionController::rearm(
    std::uint16_t new_request_sequence, std::uint64_t new_ground_nonce,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (state_ != GroundBulkSessionState::Complete &&
      state_ != GroundBulkSessionState::FailClosed) {
    return BulkSessionResult::InvalidState;
  }
  if (have_last_time_ && now_ms < last_time_ms_) {
    state_ = GroundBulkSessionState::FailClosed;
    last_error_ = BulkSessionResult::ClockRegression;
    return last_error_;
  }
  last_time_ms_ = now_ms;
  have_last_time_ = true;
  if (new_request_sequence == 0U || new_ground_nonce == 0U) {
    return BulkSessionResult::InvalidArgument;
  }
  if (new_request_sequence == request_sequence_ ||
      new_ground_nonce == ground_nonce_) {
    return BulkSessionResult::IdentityReuse;
  }
  request_sequence_ = new_request_sequence;
  ground_nonce_ = new_ground_nonce;
  clear_session();
  have_grant_watermark_ = false;
  grant_session_ = 0U;
  grant_cycle_ = 0U;
  state_ = GroundBulkSessionState::Standard;
  last_error_ = BulkSessionResult::NoAction;
  return BulkSessionResult::Rearmed;
}

const BulkNegotiationFrame*
GroundBulkSessionController::pending_request_record() const noexcept {
  return state_ == GroundBulkSessionState::RequestReady &&
                 request_record_ready_
             ? &request_record_
             : nullptr;
}

const BulkNegotiationFrame*
GroundBulkSessionController::committed_request_record() const noexcept {
  return request_record_committed_ ? &request_record_ : nullptr;
}

const BulkSessionTerminalEvidence*
GroundBulkSessionController::terminal_evidence() const noexcept {
  return (state_ == GroundBulkSessionState::TerminalEvidenceReady ||
          state_ == GroundBulkSessionState::TerminalAckReady) &&
                 terminal_evidence_ready_
             ? &terminal_evidence_
             : nullptr;
}

bool GroundBulkSessionController::note_time(std::uint64_t now_ms) noexcept {
  if (have_last_time_ && now_ms < last_time_ms_) {
    (void)fail(BulkSessionResult::ClockRegression);
    return false;
  }
  have_last_time_ = true;
  last_time_ms_ = now_ms;
  return true;
}

bool GroundBulkSessionController::lease_expired(
    std::uint64_t now_ms) const noexcept {
  return has_t0_ && now_ms >= t0_ms_ &&
         now_ms - t0_ms_ > BulkSessionTiming::hard_lease_ms;
}

BulkSessionResult GroundBulkSessionController::fail(
    BulkSessionResult reason) noexcept {
  state_ = GroundBulkSessionState::FailClosed;
  last_error_ = reason;
  return reason;
}

void GroundBulkSessionController::clear_session() noexcept {
  held_param_request_ = {};
  held_request_ = false;
  request_record_ = {};
  request_record_ready_ = false;
  request_record_committed_ = false;
  identity_ = {};
  transfer_tag_ = 0U;
  terminal_evidence_ = {};
  terminal_evidence_ready_ = false;
  has_terminal_wait_epoch_ = false;
  terminal_wait_epoch_ms_ = 0U;
  has_t0_ = false;
  t0_ms_ = 0U;
  has_t1_ = false;
  t1_ms_ = 0U;
}

VehicleBulkSessionController::VehicleBulkSessionController(
    const VehicleBulkSessionConfig& config) noexcept
    : feature_(config.feature),
      vehicle_boot_id_(config.vehicle_boot_id),
      lease_sequence_(config.lease_sequence),
      vehicle_challenge_nonce_(config.vehicle_challenge_nonce),
      mavlink_sequence_(config.mavlink_sequence),
      mavlink_system_id_(config.mavlink_system_id),
      mavlink_component_id_(config.mavlink_component_id) {
  if (feature_ == BulkSessionFeature::Disabled) {
    state_ = VehicleBulkSessionState::Disabled;
    return;
  }
  if (!config_valid(config)) {
    state_ = VehicleBulkSessionState::FailClosed;
    last_error_ = BulkSessionResult::InvalidConfiguration;
    return;
  }
  state_ = VehicleBulkSessionState::AwaitGrant;
}

BulkSessionResult VehicleBulkSessionController::arm_fresh_grant(
    std::uint16_t session_id, std::uint16_t cycle_id,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != VehicleBulkSessionState::AwaitGrant) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (session_id == 0U) {
    return fail(BulkSessionResult::InvalidArgument);
  }
  if (have_grant_watermark_ &&
      !grant_is_fresh(session_id, cycle_id, last_grant_session_,
                      last_grant_cycle_)) {
    return fail(BulkSessionResult::StaleGrant);
  }
  have_grant_watermark_ = true;
  last_grant_session_ = session_id;
  last_grant_cycle_ = cycle_id;
  active_grant_session_ = session_id;
  active_grant_cycle_ = cycle_id;
  state_ = VehicleBulkSessionState::AwaitRequest;
  return BulkSessionResult::GrantArmed;
}

BulkSessionResult VehicleBulkSessionController::on_terminal_request(
    const std::uint8_t* record, std::size_t size,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (has_lease_epoch_ && lease_expired(now_ms)) {
    return fail(BulkSessionResult::LeaseExpired);
  }
  if (record == nullptr) {
    return fail(BulkSessionResult::InvalidArgument);
  }
  if (size < BulkNegotiationWireCodec::frame_bytes) {
    return fail(BulkSessionResult::PartialNegotiationRecord);
  }
  if (size != BulkNegotiationWireCodec::frame_bytes) {
    return fail(BulkSessionResult::InvalidNegotiationRecord);
  }
  if (state_ == VehicleBulkSessionState::ResponseReady &&
      request_record_ready_ && same_record(request_record_, record, size)) {
    return BulkSessionResult::NegotiationResponseReady;
  }
  if (state_ != VehicleBulkSessionState::AwaitRequest) {
    return fail(BulkSessionResult::ReplayDetected);
  }

  BulkNegotiationFrame request_frame{};
  std::copy_n(record, request_frame.size(), request_frame.begin());
  BulkNegotiationRequest request{};
  if (BulkNegotiationWireCodec::decode_request(request_frame, request) !=
      BulkNegotiationWireStatus::FrameReady) {
    return fail(BulkSessionResult::InvalidNegotiationRecord);
  }
  if (request.captured_vehicle_grant_session != active_grant_session_ ||
      request.captured_vehicle_grant_cycle != active_grant_cycle_) {
    return fail(BulkSessionResult::WrongGrantIdentity);
  }

  std::uint32_t request_tag = 0U;
  if (BulkNegotiationWireCodec::derive_request_tag(request_frame,
                                                   request_tag) !=
          BulkNegotiationWireStatus::RequestTagReady ||
      request_tag == 0U) {
    return fail(BulkSessionResult::InvalidNegotiationRecord);
  }
  if (request_tag == last_committed_request_tag_) {
    return fail(BulkSessionResult::ReplayDetected);
  }

  // The hard lease begins with canonical terminal request acceptance, so
  // response/Pixhawk delays cannot silently extend the 28-second transfer.
  has_lease_epoch_ = true;
  lease_epoch_ms_ = now_ms;

  BulkNegotiationResponse response{};
  response.status = BulkNegotiationResponseStatus::Accept;
  response.vehicle_boot_id = vehicle_boot_id_;
  response.vehicle_session_id = active_grant_session_;
  response.lease_sequence = lease_sequence_;
  response.vehicle_challenge_nonce = vehicle_challenge_nonce_;
  response.request_tag = request_tag;
  response.echoed_vehicle_grant_cycle = active_grant_cycle_;
  BulkNegotiationFrame response_frame{};
  if (BulkNegotiationWireCodec::encode_response(response, response_frame) !=
      BulkNegotiationWireStatus::FrameReady) {
    return fail(BulkSessionResult::InvalidNegotiationRecord);
  }

  BulkNegotiationIdentity candidate_identity{};
  std::uint32_t candidate_tag = 0U;
  if (BulkNegotiationWireCodec::derive_accepted_transfer(
          request_frame, response_frame, candidate_identity,
          candidate_tag) != BulkNegotiationWireStatus::TransferReady) {
    return fail(BulkSessionResult::InvalidNegotiationRecord);
  }

  request_record_ = request_frame;
  request_record_ready_ = true;
  response_record_ = response_frame;
  response_record_ready_ = true;
  active_request_tag_ = request_tag;
  identity_ = candidate_identity;
  transfer_tag_ = candidate_tag;
  state_ = VehicleBulkSessionState::ResponseReady;
  return BulkSessionResult::NegotiationResponseReady;
}

BulkSessionResult VehicleBulkSessionController::complete_response_tx(
    TxResult result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != VehicleBulkSessionState::ResponseReady ||
      !response_record_ready_ || !request_record_ready_) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (lease_expired(now_ms)) {
    return fail(BulkSessionResult::LeaseExpired);
  }
  if (result == TxResult::Rejected) {
    return BulkSessionResult::RetryRetained;
  }

  BulkNegotiationRequest request{};
  if (BulkNegotiationWireCodec::decode_request(request_record_, request) !=
      BulkNegotiationWireStatus::FrameReady) {
    return fail(BulkSessionResult::InvalidNegotiationRecord);
  }
  const std::array<std::uint8_t, 2U> payload{{request.target_system,
                                              request.target_component}};
  MavlinkFrame candidate{};
  if (!encode_mavlink_v2(mavlink_sequence_, mavlink_system_id_,
                         mavlink_component_id_, 21U, payload.data(),
                         payload.size(), candidate)) {
    return fail(BulkSessionResult::InvalidMavlink);
  }

  pixhawk_request_ = candidate;
  pixhawk_request_valid_ = true;
  last_committed_request_tag_ = active_request_tag_;
  state_ = VehicleBulkSessionState::PixhawkRequestReady;
  return BulkSessionResult::NegotiationResponseCommitted;
}

BulkSessionResult VehicleBulkSessionController::complete_pixhawk_request(
    TxResult result, std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != VehicleBulkSessionState::PixhawkRequestReady ||
      !pixhawk_request_valid_) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (lease_expired(now_ms)) {
    return fail(BulkSessionResult::LeaseExpired);
  }
  if (result == TxResult::Rejected) {
    return BulkSessionResult::RetryRetained;
  }
  state_ = VehicleBulkSessionState::BulkDownlink;
  return BulkSessionResult::BulkDownlinkEnabled;
}

BulkSessionResult VehicleBulkSessionController::complete_bulk_downlink(
    const VehicleBulkCompletionEvidence& evidence,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != VehicleBulkSessionState::BulkDownlink) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (lease_expired(now_ms)) {
    return fail(BulkSessionResult::LeaseExpired);
  }
  if (!evidence.owner_sealed) {
    return fail(BulkSessionResult::SenderIncomplete);
  }
  if (evidence.transfer_tag != transfer_tag_ ||
      evidence.parameter_count != BulkSessionAccounting::parameter_count ||
      evidence.parameter_fragment_count !=
          BulkSessionAccounting::parameter_fragment_count ||
      evidence.raw_parameter_bytes !=
          BulkSessionAccounting::raw_parameter_bytes) {
    return fail(BulkSessionResult::CompletionEvidenceMismatch);
  }
  if (evidence.heartbeat_count == 0U) {
    return fail(BulkSessionResult::CompletionEvidenceMismatch);
  }
  committed_heartbeat_count_ = evidence.heartbeat_count;
  has_local_completion_ = true;
  local_completion_ms_ = now_ms;
  has_terminal_wait_epoch_ = false;
  terminal_wait_epoch_ms_ = 0U;
  state_ = VehicleBulkSessionState::AwaitTerminalWindow;
  return BulkSessionResult::TerminalEvidenceReady;
}

BulkSessionResult VehicleBulkSessionController::open_terminal_ack_window(
    const BulkSessionTerminalWindowEvidence& evidence,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != VehicleBulkSessionState::AwaitTerminalWindow) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (!has_local_completion_ ||
      now_ms - local_completion_ms_ >
          BulkSessionTiming::terminal_transition_timeout_ms) {
    return fail(BulkSessionResult::TerminalWindowTimeout);
  }
  // Vehicle is the sender: its physical tail must follow sender-owner local
  // completion, unlike the Ground receive-side ordering above.
  if (evidence.final_tail_drained_ms < local_completion_ms_ ||
      !terminal_window_evidence_valid(evidence, now_ms)) {
    return fail(BulkSessionResult::TerminalWindowEvidenceMismatch);
  }
  has_terminal_wait_epoch_ = true;
  terminal_wait_epoch_ms_ = now_ms;
  state_ = VehicleBulkSessionState::AwaitTerminalAck;
  return BulkSessionResult::TerminalWindowOpened;
}

BulkSessionResult VehicleBulkSessionController::confirm_terminal_ack(
    const BulkSessionTerminalEvidence& evidence,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != VehicleBulkSessionState::AwaitTerminalAck ||
      !has_terminal_wait_epoch_) {
    return fail(BulkSessionResult::InvalidState);
  }
  if (now_ms - terminal_wait_epoch_ms_ >
      BulkSessionTiming::terminal_ack_timeout_ms) {
    return fail(BulkSessionResult::TerminalAckTimeout);
  }
  if (!same_identity(evidence.identity, identity_) ||
      evidence.transfer_tag != transfer_tag_ ||
      evidence.parameter_count != BulkSessionAccounting::parameter_count ||
      evidence.parameter_fragment_count !=
          BulkSessionAccounting::parameter_fragment_count ||
      evidence.raw_parameter_bytes !=
          BulkSessionAccounting::raw_parameter_bytes ||
      evidence.heartbeat_count != committed_heartbeat_count_ ||
      !heartbeat_evidence_valid(
          evidence.heartbeat_count, evidence.first_heartbeat_gap_ms,
          evidence.max_heartbeat_gap_ms, evidence.post_heartbeat_gap_ms) ||
      !evidence.ground_stream_complete ||
      !evidence.final_parameter_usb_committed) {
    return fail(BulkSessionResult::TerminalEvidenceMismatch);
  }
  state_ = VehicleBulkSessionState::Complete;
  return BulkSessionResult::SessionComplete;
}

BulkSessionResult VehicleBulkSessionController::tick(
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (fail_closed()) {
    return BulkSessionResult::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (active_vehicle_lease_state(state_) && lease_expired(now_ms)) {
    return fail(BulkSessionResult::LeaseExpired);
  }
  if (state_ == VehicleBulkSessionState::AwaitTerminalWindow &&
      has_local_completion_ &&
      now_ms - local_completion_ms_ >
          BulkSessionTiming::terminal_transition_timeout_ms) {
    return fail(BulkSessionResult::TerminalWindowTimeout);
  }
  if (state_ == VehicleBulkSessionState::AwaitTerminalAck &&
      has_terminal_wait_epoch_ &&
      now_ms - terminal_wait_epoch_ms_ >
          BulkSessionTiming::terminal_ack_timeout_ms) {
    return fail(BulkSessionResult::TerminalAckTimeout);
  }
  return BulkSessionResult::NoAction;
}

BulkSessionResult VehicleBulkSessionController::rearm(
    std::uint16_t new_lease_sequence,
    std::uint64_t new_vehicle_challenge_nonce,
    std::uint8_t new_mavlink_sequence,
    std::uint64_t now_ms) noexcept {
  if (feature_ == BulkSessionFeature::Disabled) {
    return BulkSessionResult::FeatureDisabled;
  }
  if (state_ != VehicleBulkSessionState::Complete &&
      state_ != VehicleBulkSessionState::FailClosed) {
    return BulkSessionResult::InvalidState;
  }
  if (have_last_time_ && now_ms < last_time_ms_) {
    state_ = VehicleBulkSessionState::FailClosed;
    last_error_ = BulkSessionResult::ClockRegression;
    return last_error_;
  }
  last_time_ms_ = now_ms;
  have_last_time_ = true;
  if (new_lease_sequence == 0U || new_vehicle_challenge_nonce == 0U) {
    return BulkSessionResult::InvalidArgument;
  }
  if (new_lease_sequence == lease_sequence_ ||
      new_vehicle_challenge_nonce == vehicle_challenge_nonce_) {
    return BulkSessionResult::IdentityReuse;
  }
  lease_sequence_ = new_lease_sequence;
  vehicle_challenge_nonce_ = new_vehicle_challenge_nonce;
  mavlink_sequence_ = new_mavlink_sequence;
  clear_session();
  state_ = VehicleBulkSessionState::AwaitGrant;
  last_error_ = BulkSessionResult::NoAction;
  return BulkSessionResult::Rearmed;
}

const BulkNegotiationFrame*
VehicleBulkSessionController::pending_response_record() const noexcept {
  return state_ == VehicleBulkSessionState::ResponseReady &&
                 response_record_ready_
             ? &response_record_
             : nullptr;
}

const MavlinkFrame*
VehicleBulkSessionController::pending_pixhawk_request() const noexcept {
  return state_ == VehicleBulkSessionState::PixhawkRequestReady &&
                 pixhawk_request_valid_
             ? &pixhawk_request_
             : nullptr;
}

bool VehicleBulkSessionController::note_time(std::uint64_t now_ms) noexcept {
  if (have_last_time_ && now_ms < last_time_ms_) {
    (void)fail(BulkSessionResult::ClockRegression);
    return false;
  }
  have_last_time_ = true;
  last_time_ms_ = now_ms;
  return true;
}

bool VehicleBulkSessionController::lease_expired(
    std::uint64_t now_ms) const noexcept {
  return has_lease_epoch_ && now_ms >= lease_epoch_ms_ &&
         now_ms - lease_epoch_ms_ > BulkSessionTiming::hard_lease_ms;
}

BulkSessionResult VehicleBulkSessionController::fail(
    BulkSessionResult reason) noexcept {
  state_ = VehicleBulkSessionState::FailClosed;
  last_error_ = reason;
  return reason;
}

void VehicleBulkSessionController::clear_session() noexcept {
  active_grant_session_ = 0U;
  active_grant_cycle_ = 0U;
  request_record_ = {};
  request_record_ready_ = false;
  response_record_ = {};
  response_record_ready_ = false;
  pixhawk_request_ = {};
  pixhawk_request_valid_ = false;
  identity_ = {};
  transfer_tag_ = 0U;
  active_request_tag_ = 0U;
  committed_heartbeat_count_ = 0U;
  has_local_completion_ = false;
  local_completion_ms_ = 0U;
  has_terminal_wait_epoch_ = false;
  terminal_wait_epoch_ms_ = 0U;
  has_lease_epoch_ = false;
  lease_epoch_ms_ = 0U;
}

}  // namespace vc_lora
