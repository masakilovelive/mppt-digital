#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

#include "terminal_ack_bridge.hpp"
#include "terminal_ack_producer.hpp"
#include "vc_lora/bulk_data_codec.hpp"
#include "vc_lora/bulk_heartbeat_sla.hpp"
#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/bulk_transcript.hpp"
#include "vc_lora/bulk_tx_lease.hpp"
#include "vc_lora/high_speed_tdd_coordinator.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_control_codec.hpp"

namespace vc_lora::experimental {

// Platform-neutral Phase-6 seam. It owns no UART, AUX pin, USB endpoint,
// scheduler, decoder, transcript, SLA ledger, or terminal codec. Every method
// is one explicit input event and poll() returns at most one explicit output
// action. The accepted production bridge does not instantiate these classes.
enum class HighSpeedPhase6OutputType : std::uint8_t {
  None = 0U,
  RadioWrite,
  PixhawkWrite,
  GroundUsbWrite,
  OpenTerminalAckWindow,
};

struct HighSpeedPhase6Output final {
  HighSpeedPhase6OutputType type{HighSpeedPhase6OutputType::None};
  HighSpeedActionType semantic{HighSpeedActionType::None};
  std::uint32_t token{0U};
  std::uint32_t writer_generation{0U};
  std::array<std::uint8_t, kMavlinkMaxFrameBytes> bytes{};
  std::size_t size{0U};
};

struct GroundUsbHostCommitEvent final {
  std::uint32_t token{0U};
  std::uint64_t tx_loss_epoch{0U};
  std::uint64_t completed_ms{0U};
};

enum class HighSpeedPhase6AdapterStatus : std::uint8_t {
  NoAction = 0U,
  Disabled,
  PassThrough,
  Ready,
  Held,
  ActionReady,
  Accepted,
  RetryRetained,
  TailAccepted,
  BulkEnabled,
  UsbFrameStaged,
  AwaitUsbCommit,
  AwaitPixhawkCommit,
  UsbCommitted,
  TerminalReady,
  WindowOpened,
  Complete,
  Busy,
  InvalidArgument,
  InvalidState,
  OwnerRejected,
  CoordinatorRejected,
  ProducerRejected,
  LeaseRejected,
  ClockRegression,
  DeadlineExceeded,
  FailClosed,
};

struct HighSpeedPhase6AdapterTiming final {
  // Keep the platform seam on the same inclusive local-completion-to-window
  // budget as both semantic owners and the TDD coordinators.  This covers the
  // physical tail, the 100-ms direction guard, and the peer-window commit;
  // there is no longer a weaker adapter-only 2-second tail allowance.
  static constexpr std::uint64_t terminal_transition_timeout_ms =
      BulkSessionTiming::terminal_transition_timeout_ms;
};

namespace detail {

inline bool identity_equal(const BulkNegotiationIdentity& left,
                           const BulkNegotiationIdentity& right) noexcept {
  return left.session_id == right.session_id &&
         left.stream_id == right.stream_id &&
         left.lease_id == right.lease_id &&
         left.ground_request_nonce == right.ground_request_nonce &&
         left.vehicle_challenge_nonce == right.vehicle_challenge_nonce;
}

inline bool terminal_identity_equal(
    const TerminalAckIdentity& left,
    const BulkNegotiationIdentity& right) noexcept {
  return left.session_id == right.session_id &&
         left.stream_id == right.stream_id && left.lease_id == right.lease_id &&
         left.ground_request_nonce == right.ground_request_nonce &&
         left.vehicle_terminal_challenge_nonce ==
             right.vehicle_challenge_nonce;
}

inline bool terminal_record_matches(
    const TerminalAckRecord& record,
    const BulkSessionTerminalEvidence& evidence) noexcept {
  return terminal_identity_equal(record.identity, evidence.identity) &&
         record.final_parameter_count == evidence.parameter_count &&
         record.wire_chunk_count == evidence.parameter_fragment_count &&
         record.raw_mavlink_bytes == evidence.raw_parameter_bytes &&
         record.heartbeat_count == evidence.heartbeat_count &&
         record.first_heartbeat_gap_ms == evidence.first_heartbeat_gap_ms &&
         record.max_heartbeat_gap_ms == evidence.max_heartbeat_gap_ms &&
         record.post_heartbeat_gap_ms == evidence.post_heartbeat_gap_ms;
}

inline bool final_parameter(const MavlinkFrame& frame) noexcept {
  MavlinkFrame validated{};
  if (validate_mavlink_frame(frame.bytes.data(), frame.size, validated) !=
          MavlinkParseStatus::FrameReady ||
      validated.message_id != 22U || validated.payload_length < 8U) {
    return false;
  }
  const std::uint16_t count = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(validated.payload_byte_or_zero(4U)) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(validated.payload_byte_or_zero(5U))
          << 8U));
  const std::uint16_t index = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(validated.payload_byte_or_zero(6U)) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(validated.payload_byte_or_zero(7U))
          << 8U));
  return count == BulkSessionAccounting::parameter_count &&
         index + 1U == count;
}

inline HighSpeedPhase6Output wrap_action(
    const HighSpeedAction& action) noexcept {
  HighSpeedPhase6Output output{};
  if (action.type == HighSpeedActionType::None) {
    return output;
  }
  output.semantic = action.type;
  output.token = action.token;
  output.writer_generation = action.writer_generation;
  output.size = action.size;
  std::copy_n(action.bytes.begin(), action.size, output.bytes.begin());
  if (action.type == HighSpeedActionType::SendPixhawkParameterRequest) {
    output.type = HighSpeedPhase6OutputType::PixhawkWrite;
  } else if (action.type == HighSpeedActionType::OpenTerminalAckWindow) {
    output.type = HighSpeedPhase6OutputType::OpenTerminalAckWindow;
  } else {
    output.type = HighSpeedPhase6OutputType::RadioWrite;
  }
  return output;
}

inline GroundBulkCompletionEvidence ground_completion(
    const BulkDataStreamDecoder& decoder,
    const BulkHeartbeatSlaLedger& sla) noexcept {
  const BulkHeartbeatSlaEvidence sla_evidence = sla.evidence();
  GroundBulkCompletionEvidence evidence{};
  evidence.transfer_tag = decoder.expected_transfer_tag();
  evidence.parameter_count = decoder.parameter_count();
  evidence.parameter_fragment_count = decoder.parameter_fragment_count();
  evidence.raw_parameter_bytes = decoder.raw_parameter_bytes();
  evidence.heartbeat_count = decoder.heartbeat_count();
  evidence.first_heartbeat_gap_ms = sla_evidence.first_heartbeat_gap_ms;
  evidence.max_heartbeat_gap_ms = sla_evidence.max_heartbeat_gap_ms;
  evidence.post_heartbeat_gap_ms = sla_evidence.post_heartbeat_gap_ms;
  evidence.stream_complete = decoder.complete() && decoder.sealed();
  evidence.final_parameter_usb_committed = sla_evidence.complete &&
                                            sla.sealed();
  return evidence;
}

inline VehicleBulkCompletionEvidence vehicle_completion(
    const BulkDataTxLease& lease) noexcept {
  const BulkDataTxLeaseEvidence source = lease.completion_evidence();
  VehicleBulkCompletionEvidence evidence{};
  evidence.transfer_tag = source.transfer_tag;
  evidence.parameter_count = source.parameter_count;
  evidence.parameter_fragment_count = source.parameter_fragment_count;
  evidence.raw_parameter_bytes = source.raw_parameter_bytes;
  evidence.heartbeat_count = source.heartbeat_count;
  evidence.owner_sealed = source.owner_sealed;
  return evidence;
}

}  // namespace detail

class GroundHighSpeedPhase6Adapter final {
 public:
  explicit GroundHighSpeedPhase6Adapter(
      const GroundBulkSessionConfig& config) noexcept
      : feature_(config.feature), owner_(config), coordinator_(config.feature) {}
  GroundHighSpeedPhase6Adapter(const GroundHighSpeedPhase6Adapter&) = delete;
  GroundHighSpeedPhase6Adapter& operator=(
      const GroundHighSpeedPhase6Adapter&) = delete;
  GroundHighSpeedPhase6Adapter(GroundHighSpeedPhase6Adapter&&) = delete;
  GroundHighSpeedPhase6Adapter& operator=(GroundHighSpeedPhase6Adapter&&) =
      delete;

  [[nodiscard]] HighSpeedPhase6AdapterStatus observe_standard_grant(
      std::uint16_t session_id, std::uint16_t cycle_id,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    const BulkSessionResult result =
        owner_.observe_standard_grant(session_id, cycle_id, now_ms);
    if (result == BulkSessionResult::GrantBaselineCaptured ||
        result == BulkSessionResult::NoAction) {
      return set_status(HighSpeedPhase6AdapterStatus::Ready);
    }
    return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus on_ground_usb_frame(
      const MavlinkFrame& frame, std::uint64_t tx_loss_epoch,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    const BulkSessionResult owner_result =
        owner_.on_ground_usb_frame(frame, now_ms);
    if (owner_result == BulkSessionResult::PassThrough ||
        owner_result == BulkSessionResult::NotHighSpeedReady) {
      return set_status(HighSpeedPhase6AdapterStatus::PassThrough);
    }
    if (owner_result == BulkSessionResult::BusyHold) {
      return set_status(HighSpeedPhase6AdapterStatus::Busy);
    }
    if (owner_result != BulkSessionResult::ParameterRequestHeld) {
      return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
    }
    t0_tx_loss_epoch_ = tx_loss_epoch;
    have_t0_tx_loss_epoch_ = true;
    const HighSpeedCoordinatorResult coordinated =
        coordinator_.begin_parameter_request(owner_result, now_ms);
    return coordinated == HighSpeedCoordinatorResult::Ready
               ? set_status(HighSpeedPhase6AdapterStatus::Held)
               : fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus on_fresh_grant(
      std::uint16_t session_id, std::uint16_t cycle_id,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    const BulkSessionResult owner_result =
        owner_.on_fresh_grant(session_id, cycle_id, now_ms);
    const BulkNegotiationFrame* request = owner_.pending_request_record();
    if (owner_result != BulkSessionResult::NegotiationRequestReady ||
        request == nullptr) {
      return fail(owner_result == BulkSessionResult::GrantDeadlineExceeded
                      ? HighSpeedPhase6AdapterStatus::DeadlineExceeded
                      : HighSpeedPhase6AdapterStatus::OwnerRejected);
    }
    const HighSpeedCoordinatorResult coordinated =
        coordinator_.stage_fresh_grant(owner_result, *request, now_ms);
    return coordinated == HighSpeedCoordinatorResult::Ready
               ? set_status(HighSpeedPhase6AdapterStatus::Ready)
               : fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
  }

  // Pure pre-tail check used by the product bridge before treating reception
  // of a VCBN response as remote-arrival evidence for the request stream.
  // It deliberately does not advance time, consume the response, set status,
  // or alter either semantic owner.  The stateful transition remains
  // on_negotiation_response(), after the exact request tail has been closed.
  [[nodiscard]] bool prevalidate_negotiation_response(
      const std::uint8_t* record, std::size_t size,
      std::uint64_t now_ms) const noexcept {
    if (disabled() || fail_closed() || record == nullptr ||
        size != BulkNegotiationWireCodec::frame_bytes || !have_last_time_ ||
        now_ms < last_time_ms_ || !owner_.has_t0() ||
        now_ms - owner_.t0_ms() > BulkSessionTiming::hard_lease_ms ||
        owner_.state() != GroundBulkSessionState::AwaitResponse ||
        coordinator_.state() != GroundHighSpeedTddState::RequestDrain) {
      return false;
    }
    const BulkNegotiationFrame* request =
        owner_.committed_request_record();
    if (request == nullptr) {
      return false;
    }
    BulkNegotiationFrame response{};
    std::copy_n(record, response.size(), response.begin());
    BulkNegotiationIdentity identity{};
    std::uint32_t transfer_tag = 0U;
    return BulkNegotiationWireCodec::derive_accepted_transfer(
               *request, response, identity, transfer_tag) ==
               BulkNegotiationWireStatus::TransferReady &&
           identity.session_id != 0U && identity.stream_id != 0U &&
           identity.lease_id != 0U && identity.ground_request_nonce != 0U &&
           identity.vehicle_challenge_nonce != 0U && transfer_tag != 0U;
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus on_negotiation_response(
      const std::uint8_t* record, std::size_t size,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    const BulkSessionResult owner_result =
        owner_.on_negotiation_response(record, size, now_ms);
    if (owner_result != BulkSessionResult::BulkReceiveEnabled) {
      return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
    }
    const HighSpeedCoordinatorResult coordinated =
        coordinator_.on_negotiation_response(owner_result,
                                             owner_.transfer_tag(), now_ms);
    if (coordinated != HighSpeedCoordinatorResult::BulkEnabled) {
      return fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
    }
    if (!have_t0_tx_loss_epoch_ ||
        host_commit_owner_.arm(owner_.identity(), owner_.transfer_tag(),
                               owner_.t0_ms(), t0_tx_loss_epoch_) !=
            GroundUsbCommitStatus::Armed) {
      return fail(HighSpeedPhase6AdapterStatus::ProducerRejected);
    }
    return set_status(HighSpeedPhase6AdapterStatus::BulkEnabled);
  }

  // `frame` must be the decoder-emitted complete frame. The transcript and
  // SLA owners are concrete ledgers, not caller-supplied counters.
  [[nodiscard]] HighSpeedPhase6AdapterStatus on_decoded_bulk_frame(
      const MavlinkFrame& frame, BulkTranscriptLedger& transcript,
      BulkHeartbeatSlaLedger& sla, std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    if (!owner_.bulk_receive_enabled() || usb_pending_ || usb_in_flight_ ||
        usb_awaiting_commit_) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidState);
    }
    MavlinkFrame validated{};
    if (validate_mavlink_frame(frame.bytes.data(), frame.size, validated) !=
        MavlinkParseStatus::FrameReady) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidArgument);
    }
    if (transcript.append(validated) != BulkTranscriptStatus::EntryAccepted) {
      return fail(HighSpeedPhase6AdapterStatus::ProducerRejected);
    }
    if (validated.message_id == 0U &&
        sla.accept_heartbeat(now_ms) !=
            BulkHeartbeatSlaStatus::HeartbeatAccepted) {
      return fail(HighSpeedPhase6AdapterStatus::ProducerRejected);
    }
    usb_frame_ = validated;
    usb_pending_ = true;
    usb_is_final_parameter_ = detail::final_parameter(validated);
    return set_status(HighSpeedPhase6AdapterStatus::UsbFrameStaged);
  }

  // Non-final USB host-visible commit. Final PARAM index 931 is rejected here;
  // it must use on_final_ground_usb_host_commit so one immutable physical
  // timestamp is passed to SLA, owner, coordinator and terminal producer.
  [[nodiscard]] HighSpeedPhase6AdapterStatus on_ground_usb_host_commit(
      const GroundUsbHostCommitEvent& event) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(event.completed_ms)) {
      return last_status_;
    }
    if (!usb_awaiting_commit_ || event.token != usb_commit_token_ ||
        !have_t0_tx_loss_epoch_ ||
        event.tx_loss_epoch != t0_tx_loss_epoch_ || usb_is_final_parameter_) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidState);
    }
    clear_usb_frame();
    return set_status(HighSpeedPhase6AdapterStatus::UsbCommitted);
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus
  on_final_ground_usb_host_commit(
      const GroundUsbHostCommitEvent& event,
      BulkDataStreamDecoder& decoder, BulkTranscriptLedger& transcript,
      BulkHeartbeatSlaLedger& sla, GroundTerminalAckProducer& producer) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(event.completed_ms)) {
      return last_status_;
    }
    if (!usb_awaiting_commit_ || event.token != usb_commit_token_ ||
        !have_t0_tx_loss_epoch_ ||
        event.tx_loss_epoch != t0_tx_loss_epoch_ ||
        !usb_is_final_parameter_ || !have_bulk_tail_ ||
        decoder.expected_transfer_tag() != owner_.transfer_tag()) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidState);
    }
    if (!decoder.complete() ||
        decoder.seal_session() != BulkDataStreamLifecycleStatus::Sealed ||
        transcript.seal_session() != BulkTranscriptStatus::Sealed ||
        sla.complete_final_parameter(event.completed_ms) !=
            BulkHeartbeatSlaStatus::EvidenceReady ||
        sla.seal_session() != BulkHeartbeatSlaStatus::Sealed) {
      return fail(HighSpeedPhase6AdapterStatus::ProducerRejected);
    }
    if (host_commit_owner_.stage_final_write(
            usb_frame_, event.token, event.tx_loss_epoch,
            usb_write_accepted_ms_) !=
            GroundUsbCommitStatus::FinalWriteStaged ||
        host_commit_owner_.complete_host_visible(
            event.token, event.tx_loss_epoch, event.completed_ms) !=
            GroundUsbCommitStatus::HostCommitReady) {
      return fail(HighSpeedPhase6AdapterStatus::ProducerRejected);
    }

    TerminalAckRecord record{};
    TerminalAckFragments fragments{};
    if (producer.produce(decoder, transcript, sla, host_commit_owner_,
                         owner_.identity(), record, fragments) !=
        TerminalAckProducerStatus::RecordReady) {
      return fail(HighSpeedPhase6AdapterStatus::ProducerRejected);
    }
    const GroundBulkCompletionEvidence completion =
        detail::ground_completion(decoder, sla);
    const BulkSessionResult owner_result =
        owner_.complete_bulk_receive(completion, event.completed_ms);
    const BulkSessionTerminalEvidence* semantic = owner_.terminal_evidence();
    if (owner_result != BulkSessionResult::TerminalEvidenceReady ||
        semantic == nullptr ||
        !detail::terminal_record_matches(record, *semantic)) {
      return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
    }
    const HighSpeedCoordinatorResult coordinated =
        coordinator_.complete_bulk_receive(owner_result, completion, fragments,
                                           event.completed_ms);
    if (coordinated != HighSpeedCoordinatorResult::TerminalWindowReady) {
      return fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
    }
    t1_ms_ = event.completed_ms;
    have_t1_ = true;
    terminal_record_id_ = record.record_id;
    clear_usb_frame();
    return set_status(HighSpeedPhase6AdapterStatus::TerminalReady);
  }

  // Ground RX tail is the timestamp of the final complete VCB1 radio record,
  // which causally precedes decoder emission and USB t1. The coordinator must
  // therefore accept and latch this event while still in BulkReceive. The
  // local demux/RX ledger first binds its one-shot record identity here; this
  // is deliberately not represented as the remote Vehicle writer identity.
  [[nodiscard]] HighSpeedPhase6AdapterStatus bind_final_bulk_rx_record(
      const HighSpeedLocalRxRecordIdentity& identity,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    return coordinator_.bind_final_bulk_rx_record(identity, now_ms) ==
                   HighSpeedCoordinatorResult::Ready
               ? set_status(HighSpeedPhase6AdapterStatus::Ready)
               : fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus on_bulk_tail(
      const HighSpeedStreamTailEvidence& evidence,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    const HighSpeedCoordinatorResult result =
        coordinator_.observe_bulk_tail_drained(evidence, now_ms);
    if (result != HighSpeedCoordinatorResult::TailDrainAccepted) {
      return fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
    }
    have_bulk_tail_ = true;
    bulk_tail_ms_ = evidence.completed_ms;
    return set_status(HighSpeedPhase6AdapterStatus::TailAccepted);
  }

  [[nodiscard]] HighSpeedPhase6Output poll(std::uint64_t now_ms) noexcept {
    HighSpeedPhase6Output none{};
    if (disabled() || failed_ || !accept_time(now_ms)) {
      return none;
    }
    if (deadline_failed(now_ms)) {
      return none;
    }
    if (usb_pending_) {
      if (usb_in_flight_ || usb_awaiting_commit_) {
        return none;
      }
      if (next_usb_token_ == 0U) {
        (void)fail(HighSpeedPhase6AdapterStatus::FailClosed);
        return none;
      }
      active_output_type_ = HighSpeedActionType::None;
      active_output_token_ = next_usb_token_++;
      usb_in_flight_ = true;
      HighSpeedPhase6Output output{};
      output.type = HighSpeedPhase6OutputType::GroundUsbWrite;
      output.token = active_output_token_;
      output.size = usb_frame_.size;
      std::copy_n(usb_frame_.bytes.begin(), usb_frame_.size,
                  output.bytes.begin());
      return output;
    }
    if (coordinator_.state() == GroundHighSpeedTddState::DirectionGuard &&
        have_t1_ && have_bulk_tail_) {
      const std::uint64_t guard_ready =
          bulk_tail_ms_ > UINT64_MAX - BulkSessionTiming::direction_guard_ms
              ? UINT64_MAX
              : bulk_tail_ms_ + BulkSessionTiming::direction_guard_ms;
      if (now_ms >= guard_ready && now_ms >= t1_ms_) {
        BulkSessionTerminalWindowEvidence evidence{};
        evidence.final_tail_drained = true;
        evidence.final_tail_drained_ms = bulk_tail_ms_;
        evidence.direction_guard_complete = true;
        evidence.direction_guard_completed_ms = now_ms;
        const BulkSessionResult owner_result =
            owner_.open_terminal_ack_window(evidence, now_ms);
        if (owner_result != BulkSessionResult::TerminalWindowOpened ||
            coordinator_.open_terminal_window(owner_result, now_ms) !=
                HighSpeedCoordinatorResult::ActionReady) {
          (void)fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
          return none;
        }
      }
    }
    const HighSpeedAction action = coordinator_.poll(now_ms);
    HighSpeedPhase6Output output = detail::wrap_action(action);
    if (output.type != HighSpeedPhase6OutputType::None) {
      active_output_type_ = output.semantic;
      active_output_token_ = output.token;
    }
    return output;
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus complete_output(
      std::uint32_t token, TxResult result,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    if (failed_ || token == 0U || token != active_output_token_) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidArgument);
    }
    if (usb_in_flight_) {
      usb_in_flight_ = false;
      if (result == TxResult::Rejected) {
        active_output_token_ = 0U;
        return set_status(HighSpeedPhase6AdapterStatus::RetryRetained);
      }
      usb_awaiting_commit_ = true;
      usb_commit_token_ = token;
      usb_write_accepted_ms_ = now_ms;
      return set_status(HighSpeedPhase6AdapterStatus::AwaitUsbCommit);
    }

    const HighSpeedActionType completed = active_output_type_;
    const HighSpeedCoordinatorResult coordinated =
        coordinator_.complete_action(token, result, now_ms);
    active_output_token_ = 0U;
    active_output_type_ = HighSpeedActionType::None;
    if (result == TxResult::Rejected) {
      if (coordinated != HighSpeedCoordinatorResult::RetryRetained) {
        return fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
      }
      if (completed == HighSpeedActionType::SendNegotiationRequest &&
          owner_.complete_request_tx(result, now_ms) !=
              BulkSessionResult::RetryRetained) {
        return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
      }
      return set_status(HighSpeedPhase6AdapterStatus::RetryRetained);
    }
    if (coordinated != HighSpeedCoordinatorResult::Accepted) {
      return fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
    }
    if (completed == HighSpeedActionType::SendNegotiationRequest) {
      const BulkSessionResult owner_result =
          owner_.complete_request_tx(result, now_ms);
      if (owner_result != BulkSessionResult::NegotiationRequestCommitted ||
          coordinator_.confirm_request_commit(owner_result, now_ms) !=
              HighSpeedCoordinatorResult::AwaitingPeer) {
        return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
      }
    } else if (completed == HighSpeedActionType::SendTerminalEvidence &&
               coordinator_.state() ==
                   GroundHighSpeedTddState::AwaitTerminalPhysicalTail) {
      const BulkSessionResult owner_result =
          owner_.complete_terminal_ack_tx(result, now_ms);
      if (owner_result != BulkSessionResult::TerminalAckCommitted ||
          coordinator_.confirm_terminal_commit(owner_result, now_ms) !=
              HighSpeedCoordinatorResult::AwaitingPeer) {
        return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
      }
      return set_status(HighSpeedPhase6AdapterStatus::Accepted);
    }
    return set_status(HighSpeedPhase6AdapterStatus::Accepted);
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus on_radio_tail(
      const HighSpeedTailDrainEvidence& evidence,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    const HighSpeedCoordinatorResult result =
        coordinator_.observe_action_tail_drained(evidence, now_ms);
    if (result == HighSpeedCoordinatorResult::SessionComplete) {
      return set_status(HighSpeedPhase6AdapterStatus::Complete);
    }
    return result == HighSpeedCoordinatorResult::TailDrainAccepted
               ? set_status(HighSpeedPhase6AdapterStatus::TailAccepted)
               : fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus tick(
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    if (deadline_failed(now_ms)) {
      return last_status_;
    }
    const BulkSessionResult owner_result = owner_.tick(now_ms);
    const HighSpeedCoordinatorResult coordinator_result =
        coordinator_.tick(now_ms);
    if (owner_.fail_closed() || coordinator_.fail_closed() ||
        owner_result == BulkSessionResult::ClockRegression ||
        coordinator_result == HighSpeedCoordinatorResult::ClockRegression) {
      return fail(HighSpeedPhase6AdapterStatus::FailClosed);
    }
    return set_status(HighSpeedPhase6AdapterStatus::NoAction);
  }

  [[nodiscard]] constexpr bool hold_standard_uplink() const noexcept {
    return !disabled() && owner_.hold_standard_uplink();
  }
  [[nodiscard]] constexpr bool fail_closed() const noexcept {
    return failed_ || owner_.fail_closed() || coordinator_.fail_closed();
  }
  [[nodiscard]] constexpr bool complete() const noexcept {
    return owner_.state() == GroundBulkSessionState::Complete &&
           coordinator_.state() == GroundHighSpeedTddState::Complete;
  }
  [[nodiscard]] constexpr std::uint64_t t0_ms() const noexcept {
    return owner_.t0_ms();
  }
  [[nodiscard]] constexpr bool has_t1() const noexcept { return have_t1_; }
  [[nodiscard]] constexpr std::uint64_t t1_ms() const noexcept {
    return t1_ms_;
  }
  [[nodiscard]] constexpr std::uint64_t terminal_record_id() const noexcept {
    return terminal_record_id_;
  }
  [[nodiscard]] constexpr std::uint32_t transfer_tag() const noexcept {
    return owner_.transfer_tag();
  }
  [[nodiscard]] constexpr const BulkNegotiationIdentity& identity()
      const noexcept {
    return owner_.identity();
  }
  [[nodiscard]] constexpr GroundHighSpeedTddState coordinator_state()
      const noexcept {
    return coordinator_.state();
  }

 private:
  [[nodiscard]] constexpr bool disabled() const noexcept {
    return feature_ == BulkSessionFeature::Disabled;
  }
  [[nodiscard]] bool accept_time(std::uint64_t now_ms) noexcept {
    if (failed_) {
      return false;
    }
    if (have_last_time_ && now_ms < last_time_ms_) {
      (void)fail(HighSpeedPhase6AdapterStatus::ClockRegression);
      return false;
    }
    have_last_time_ = true;
    last_time_ms_ = now_ms;
    return true;
  }
  [[nodiscard]] HighSpeedPhase6AdapterStatus set_status(
      HighSpeedPhase6AdapterStatus status) noexcept {
    last_status_ = status;
    return status;
  }
  [[nodiscard]] HighSpeedPhase6AdapterStatus fail(
      HighSpeedPhase6AdapterStatus status) noexcept {
    failed_ = true;
    last_status_ = status == HighSpeedPhase6AdapterStatus::ClockRegression
                       ? status
                       : HighSpeedPhase6AdapterStatus::FailClosed;
    return last_status_;
  }
  [[nodiscard]] bool deadline_failed(std::uint64_t now_ms) noexcept {
    if (have_t1_ &&
        coordinator_.state() == GroundHighSpeedTddState::DirectionGuard &&
        now_ms - t1_ms_ >
            HighSpeedPhase6AdapterTiming::terminal_transition_timeout_ms) {
      (void)fail(HighSpeedPhase6AdapterStatus::DeadlineExceeded);
      return true;
    }
    return false;
  }
  void clear_usb_frame() noexcept {
    usb_frame_ = {};
    usb_pending_ = false;
    usb_in_flight_ = false;
    usb_awaiting_commit_ = false;
    usb_is_final_parameter_ = false;
    usb_commit_token_ = 0U;
    usb_write_accepted_ms_ = 0U;
    active_output_token_ = 0U;
  }

  BulkSessionFeature feature_{BulkSessionFeature::Disabled};
  GroundBulkSessionController owner_;
  GroundHighSpeedTddCoordinator coordinator_;
  GroundUsbHostCommitOwner host_commit_owner_{};
  MavlinkFrame usb_frame_{};
  bool usb_pending_{false};
  bool usb_in_flight_{false};
  bool usb_awaiting_commit_{false};
  bool usb_is_final_parameter_{false};
  std::uint32_t usb_commit_token_{0U};
  std::uint64_t usb_write_accepted_ms_{0U};
  std::uint32_t next_usb_token_{0x80000000U};
  HighSpeedActionType active_output_type_{HighSpeedActionType::None};
  std::uint32_t active_output_token_{0U};
  bool have_bulk_tail_{false};
  std::uint64_t bulk_tail_ms_{0U};
  bool have_t1_{false};
  std::uint64_t t1_ms_{0U};
  std::uint64_t terminal_record_id_{0U};
  std::uint64_t t0_tx_loss_epoch_{0U};
  bool have_t0_tx_loss_epoch_{false};
  bool have_last_time_{false};
  std::uint64_t last_time_ms_{0U};
  bool failed_{false};
  HighSpeedPhase6AdapterStatus last_status_{
      HighSpeedPhase6AdapterStatus::NoAction};
};

class VehicleHighSpeedPhase6Adapter final {
 public:
  explicit VehicleHighSpeedPhase6Adapter(
      const VehicleBulkSessionConfig& config) noexcept
      : feature_(config.feature), owner_(config), coordinator_(config.feature) {}
  VehicleHighSpeedPhase6Adapter(const VehicleHighSpeedPhase6Adapter&) = delete;
  VehicleHighSpeedPhase6Adapter& operator=(
      const VehicleHighSpeedPhase6Adapter&) = delete;
  VehicleHighSpeedPhase6Adapter(VehicleHighSpeedPhase6Adapter&&) = delete;
  VehicleHighSpeedPhase6Adapter& operator=(
      VehicleHighSpeedPhase6Adapter&&) = delete;

  // Called only after a complete VCBN request has arrived. The already-drained
  // standard Grant, its local writer evidence, and that request are validated
  // and adopted in this one fail-closed transition. No high-speed Grant is
  // generated and standard TDD need not be frozen speculatively.
  [[nodiscard]] HighSpeedPhase6AdapterStatus
  on_negotiation_request_with_retained_grant(
      const TddControlMessage& grant,
      const HighSpeedStandardGrantEvidence& evidence,
      const std::uint8_t* record, std::size_t size,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    HighSpeedWireActionBytes encoded_grant{};
    std::size_t encoded_size = 0U;
    if (grant.type != ControlType::UlGrant ||
        !encode_control(grant, encoded_grant.data(), encoded_grant.size(),
                        encoded_size) ||
        encoded_size != encoded_grant.size() || record == nullptr ||
        size != BulkNegotiationWireCodec::frame_bytes) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidArgument);
    }
    if (evidence.grant_session_id == 0U || evidence.grant_cycle_id == 0U ||
        evidence.grant_session_id != grant.session_id ||
        evidence.grant_cycle_id != grant.cycle_id ||
        evidence.writer_token == 0U || evidence.writer_generation == 0U ||
        !evidence.accepted || !evidence.physical_tail_complete ||
        evidence.completed_ms == 0U || evidence.completed_ms > now_ms) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidArgument);
    }
    if (now_ms - evidence.completed_ms >
        BulkSessionTiming::grant_wait_budget_ms) {
      return fail(HighSpeedPhase6AdapterStatus::DeadlineExceeded);
    }
    BulkNegotiationFrame request{};
    std::copy_n(record, request.size(), request.begin());
    BulkNegotiationRequest decoded_request{};
    if (BulkNegotiationWireCodec::decode_request(request, decoded_request) !=
            BulkNegotiationWireStatus::FrameReady ||
        decoded_request.captured_vehicle_grant_session != grant.session_id ||
        decoded_request.captured_vehicle_grant_cycle != grant.cycle_id) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidArgument);
    }

    const BulkSessionResult grant_owner_result = owner_.arm_fresh_grant(
        grant.session_id, grant.cycle_id, evidence.completed_ms);
    if (grant_owner_result != BulkSessionResult::GrantArmed) {
      return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
    }
    const BulkSessionResult request_owner_result =
        owner_.on_terminal_request(record, size, now_ms);
    const BulkNegotiationFrame* response = owner_.pending_response_record();
    if (request_owner_result != BulkSessionResult::NegotiationResponseReady ||
        response == nullptr) {
      return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
    }
    return coordinator_.adopt_retained_grant_on_terminal_request(
               grant_owner_result, request_owner_result, encoded_grant,
               evidence, request, *response, owner_.transfer_tag(), now_ms) ==
                   HighSpeedCoordinatorResult::Ready
               ? set_status(HighSpeedPhase6AdapterStatus::Ready)
               : fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
  }

  // The only VCB1 staging entry point accepts a concrete TxLease owner. The
  // adapter copies exactly current_fragment() and completes that same owner
  // only when the correlated physical action result arrives.
  [[nodiscard]] HighSpeedPhase6AdapterStatus stage_next_bulk_fragment(
      BulkDataTxLease& lease, std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    if (!owner_.bulk_tx_enabled() || active_lease_ != nullptr ||
        lease.transfer_tag() != owner_.transfer_tag()) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidState);
    }
    if (!lease.active() && lease.begin() != BulkDataTxLeaseStatus::Ready) {
      return fail(HighSpeedPhase6AdapterStatus::LeaseRejected);
    }
    const BulkDataFragment* fragment = lease.current_fragment();
    if (fragment == nullptr ||
        coordinator_.stage_bulk_fragment(*fragment, now_ms) !=
            HighSpeedCoordinatorResult::ActionReady) {
      return fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
    }
    active_lease_ = &lease;
    active_lease_fragment_ = *fragment;
    return set_status(HighSpeedPhase6AdapterStatus::ActionReady);
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus complete_bulk_downlink(
      BulkDataTxLease& lease, std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    if (active_lease_ != nullptr || lease.active() ||
        lease.transfer_tag() != owner_.transfer_tag() ||
        lease.seal_session() != BulkDataTxLeaseStatus::Sealed) {
      return fail(HighSpeedPhase6AdapterStatus::LeaseRejected);
    }
    const VehicleBulkCompletionEvidence evidence =
        detail::vehicle_completion(lease);
    const BulkSessionResult owner_result =
        owner_.complete_bulk_downlink(evidence, now_ms);
    if (owner_result != BulkSessionResult::TerminalEvidenceReady ||
        coordinator_.complete_bulk_downlink(owner_result, evidence, now_ms) !=
            HighSpeedCoordinatorResult::TerminalWindowReady) {
      return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
    }
    bulk_complete_ms_ = now_ms;
    have_bulk_completion_ = true;
    return set_status(HighSpeedPhase6AdapterStatus::TerminalReady);
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus on_bulk_tail(
      const HighSpeedStreamTailEvidence& evidence,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    if (!have_bulk_completion_ ||
        now_ms - bulk_complete_ms_ >
            HighSpeedPhase6AdapterTiming::terminal_transition_timeout_ms ||
        coordinator_.observe_bulk_tail_drained(evidence, now_ms) !=
            HighSpeedCoordinatorResult::TailDrainAccepted) {
      return fail(HighSpeedPhase6AdapterStatus::DeadlineExceeded);
    }
    bulk_tail_ms_ = evidence.completed_ms;
    have_bulk_tail_ = true;
    return set_status(HighSpeedPhase6AdapterStatus::TailAccepted);
  }

  [[nodiscard]] HighSpeedPhase6Output poll(std::uint64_t now_ms) noexcept {
    HighSpeedPhase6Output none{};
    if (disabled() || failed_ || !accept_time(now_ms) ||
        deadline_failed(now_ms)) {
      return none;
    }
    const HighSpeedAction action = coordinator_.poll(now_ms);
    HighSpeedPhase6Output output = detail::wrap_action(action);
    if (output.type != HighSpeedPhase6OutputType::None) {
      active_output_type_ = output.semantic;
      active_output_token_ = output.token;
      if (output.semantic == HighSpeedActionType::SendBulkFragment) {
        active_output_token_snapshot_ = output.token;
        active_output_writer_generation_snapshot_ =
            output.writer_generation;
      }
    }
    return output;
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus complete_output(
      std::uint32_t token, TxResult result,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    if (failed_ || token == 0U || token != active_output_token_) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidArgument);
    }
    const HighSpeedActionType completed = active_output_type_;
    const HighSpeedCoordinatorResult coordinated =
        coordinator_.complete_action(token, result, now_ms);
    active_output_token_ = 0U;
    active_output_type_ = HighSpeedActionType::None;
    if (result == TxResult::Rejected) {
      if (coordinated != HighSpeedCoordinatorResult::RetryRetained) {
        return fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
      }
      if (completed == HighSpeedActionType::SendNegotiationResponse &&
          owner_.complete_response_tx(result, now_ms) !=
              BulkSessionResult::RetryRetained) {
        return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
      }
      if (completed == HighSpeedActionType::SendBulkFragment) {
        if (!complete_active_lease(result,
                                   BulkDataTxLeaseStatus::FragmentRejected)) {
          return fail(HighSpeedPhase6AdapterStatus::LeaseRejected);
        }
      }
      return set_status(HighSpeedPhase6AdapterStatus::RetryRetained);
    }
    if (coordinated != HighSpeedCoordinatorResult::Accepted) {
      return fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
    }
    if (completed == HighSpeedActionType::SendNegotiationResponse) {
      const BulkSessionResult owner_result =
          owner_.complete_response_tx(result, now_ms);
      const MavlinkFrame* request = owner_.pending_pixhawk_request();
      if (owner_result != BulkSessionResult::NegotiationResponseCommitted ||
          request == nullptr) {
        return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
      }
      const HighSpeedCoordinatorResult staged =
          coordinator_.stage_pixhawk_request(owner_result, *request, now_ms);
      if (staged != HighSpeedCoordinatorResult::AwaitingPeer &&
          staged != HighSpeedCoordinatorResult::ActionReady) {
        return fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
      }
    } else if (completed ==
               HighSpeedActionType::SendPixhawkParameterRequest) {
      pixhawk_commit_pending_ = true;
      pixhawk_action_token_ = token;
      pixhawk_write_accepted_ms_ = now_ms;
      return set_status(HighSpeedPhase6AdapterStatus::AwaitPixhawkCommit);
    } else if (completed == HighSpeedActionType::SendBulkFragment) {
      if (!complete_active_lease(result,
                                 BulkDataTxLeaseStatus::FragmentAccepted)) {
        return fail(HighSpeedPhase6AdapterStatus::LeaseRejected);
      }
    } else if (completed == HighSpeedActionType::OpenTerminalAckWindow) {
      if (!have_bulk_tail_) {
        return fail(HighSpeedPhase6AdapterStatus::InvalidState);
      }
      BulkSessionTerminalWindowEvidence evidence{};
      evidence.final_tail_drained = true;
      evidence.final_tail_drained_ms = bulk_tail_ms_;
      evidence.direction_guard_complete = true;
      evidence.direction_guard_completed_ms = now_ms;
      const BulkSessionResult owner_result =
          owner_.open_terminal_ack_window(evidence, now_ms);
      if (owner_result != BulkSessionResult::TerminalWindowOpened ||
          coordinator_.confirm_terminal_window(owner_result, now_ms) !=
              HighSpeedCoordinatorResult::AwaitingPeer) {
        return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
      }
      terminal_window_ms_ = now_ms;
      have_terminal_window_ = true;
      return set_status(HighSpeedPhase6AdapterStatus::WindowOpened);
    }
    return set_status(HighSpeedPhase6AdapterStatus::Accepted);
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus on_radio_tail(
      const HighSpeedTailDrainEvidence& evidence,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    return coordinator_.observe_action_tail_drained(evidence, now_ms) ==
                   HighSpeedCoordinatorResult::TailDrainAccepted
               ? set_status(HighSpeedPhase6AdapterStatus::TailAccepted)
               : fail(HighSpeedPhase6AdapterStatus::CoordinatorRejected);
  }

  // UART admission of synthesized #21 is not the boundary which permits
  // Pixhawk #22 traffic.  The platform reports the complete UART2 tail here;
  // only this correlated event commits the owner and enables VCB1.
  [[nodiscard]] HighSpeedPhase6AdapterStatus on_pixhawk_request_tail(
      const HighSpeedTailDrainEvidence& evidence,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    if (!pixhawk_commit_pending_ || !evidence.physical_tail_complete ||
        evidence.action_token != pixhawk_action_token_ ||
        evidence.completed_ms < pixhawk_write_accepted_ms_ ||
        evidence.completed_ms > now_ms) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidState);
    }
    const BulkSessionResult owner_result =
        owner_.complete_pixhawk_request(TxResult::Accepted, now_ms);
    if (owner_result != BulkSessionResult::BulkDownlinkEnabled ||
        coordinator_.confirm_pixhawk_request(owner_result, now_ms) !=
            HighSpeedCoordinatorResult::BulkEnabled) {
      return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
    }
    pixhawk_commit_pending_ = false;
    pixhawk_action_token_ = 0U;
    pixhawk_write_accepted_ms_ = 0U;
    return set_status(HighSpeedPhase6AdapterStatus::BulkEnabled);
  }

  // Only this concrete bridge-consumption event can complete Vehicle. A raw
  // record, arbitrary semantic struct, or caller success boolean is not an API.
  [[nodiscard]] HighSpeedPhase6AdapterStatus on_terminal_reassembler(
      TerminalAckReassembler& reassembler,
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    if (!have_terminal_window_) {
      return fail(HighSpeedPhase6AdapterStatus::InvalidState);
    }
    BulkSessionTerminalEvidence evidence{};
    if (TerminalAckEvidenceBridge::consume(reassembler, owner_.identity(),
                                           evidence) !=
        TerminalAckBridgeStatus::EvidenceReady) {
      return fail(HighSpeedPhase6AdapterStatus::ProducerRejected);
    }
    const BulkSessionResult owner_result =
        owner_.confirm_terminal_ack(evidence, now_ms);
    if (owner_result != BulkSessionResult::SessionComplete ||
        coordinator_.confirm_terminal_ack(owner_result, evidence.transfer_tag,
                                          now_ms) !=
            HighSpeedCoordinatorResult::SessionComplete) {
      return fail(HighSpeedPhase6AdapterStatus::OwnerRejected);
    }
    return set_status(HighSpeedPhase6AdapterStatus::Complete);
  }

  [[nodiscard]] HighSpeedPhase6AdapterStatus tick(
      std::uint64_t now_ms) noexcept {
    if (disabled()) {
      return HighSpeedPhase6AdapterStatus::Disabled;
    }
    if (!accept_time(now_ms)) {
      return last_status_;
    }
    if (deadline_failed(now_ms)) {
      return last_status_;
    }
    const BulkSessionResult owner_result = owner_.tick(now_ms);
    const HighSpeedCoordinatorResult coordinator_result =
        coordinator_.tick(now_ms);
    if (owner_.fail_closed() || coordinator_.fail_closed() ||
        owner_result == BulkSessionResult::ClockRegression ||
        coordinator_result == HighSpeedCoordinatorResult::ClockRegression) {
      return fail(HighSpeedPhase6AdapterStatus::FailClosed);
    }
    return set_status(HighSpeedPhase6AdapterStatus::NoAction);
  }

  [[nodiscard]] constexpr bool fail_closed() const noexcept {
    return failed_ || owner_.fail_closed() || coordinator_.fail_closed();
  }
  [[nodiscard]] constexpr bool complete() const noexcept {
    return owner_.state() == VehicleBulkSessionState::Complete &&
           coordinator_.state() == VehicleHighSpeedTddState::Complete;
  }
  [[nodiscard]] constexpr bool bulk_tx_enabled() const noexcept {
    return owner_.bulk_tx_enabled();
  }
  [[nodiscard]] constexpr std::uint32_t transfer_tag() const noexcept {
    return owner_.transfer_tag();
  }
  [[nodiscard]] constexpr const BulkNegotiationIdentity& identity()
      const noexcept {
    return owner_.identity();
  }
  [[nodiscard]] constexpr std::uint32_t last_bulk_action_token()
      const noexcept {
    return last_bulk_action_token_;
  }
  [[nodiscard]] constexpr std::uint32_t last_bulk_writer_generation()
      const noexcept {
    return last_bulk_writer_generation_;
  }

 private:
  [[nodiscard]] constexpr bool disabled() const noexcept {
    return feature_ == BulkSessionFeature::Disabled;
  }
  [[nodiscard]] bool accept_time(std::uint64_t now_ms) noexcept {
    if (failed_) {
      return false;
    }
    if (have_last_time_ && now_ms < last_time_ms_) {
      (void)fail(HighSpeedPhase6AdapterStatus::ClockRegression);
      return false;
    }
    have_last_time_ = true;
    last_time_ms_ = now_ms;
    return true;
  }
  [[nodiscard]] HighSpeedPhase6AdapterStatus set_status(
      HighSpeedPhase6AdapterStatus status) noexcept {
    last_status_ = status;
    return status;
  }
  [[nodiscard]] HighSpeedPhase6AdapterStatus fail(
      HighSpeedPhase6AdapterStatus status) noexcept {
    failed_ = true;
    last_status_ = status == HighSpeedPhase6AdapterStatus::ClockRegression
                       ? status
                       : HighSpeedPhase6AdapterStatus::FailClosed;
    return last_status_;
  }
  [[nodiscard]] bool complete_active_lease(
      TxResult result, BulkDataTxLeaseStatus expected_head) noexcept {
    if (active_lease_ == nullptr ||
        active_lease_->current_fragment() == nullptr ||
        *active_lease_->current_fragment() != active_lease_fragment_) {
      active_lease_ = nullptr;
      return false;
    }
    const BulkDataTxLeaseStatus lease_result =
        active_lease_->complete_fragment(result);
    // A rejected physical write is a retry of the same coordinator action,
    // not another staging event. BulkDataTxLease deliberately keeps the same
    // cached fragment active, so retain its pointer and byte snapshot until a
    // later poll()/complete_output(Accepted) pair commits that exact fragment.
    if (result == TxResult::Rejected) {
      return lease_result == expected_head;
    }
    if (result == TxResult::Accepted) {
      last_bulk_action_token_ = active_output_token_snapshot_;
      last_bulk_writer_generation_ =
          active_output_writer_generation_snapshot_;
    }
    const bool accepted =
        lease_result == expected_head ||
        lease_result == BulkDataTxLeaseStatus::FrameCommitted;
    active_lease_ = nullptr;
    active_lease_fragment_ = {};
    active_output_token_snapshot_ = 0U;
    active_output_writer_generation_snapshot_ = 0U;
    return accepted;
  }
  [[nodiscard]] bool deadline_failed(std::uint64_t now_ms) noexcept {
    if (have_bulk_completion_ && !have_terminal_window_ &&
        now_ms - bulk_complete_ms_ >
            HighSpeedPhase6AdapterTiming::terminal_transition_timeout_ms) {
      (void)fail(HighSpeedPhase6AdapterStatus::DeadlineExceeded);
      return true;
    }
    return false;
  }

  BulkSessionFeature feature_{BulkSessionFeature::Disabled};
  VehicleBulkSessionController owner_;
  VehicleHighSpeedTddCoordinator coordinator_;
  BulkDataTxLease* active_lease_{nullptr};
  BulkDataFragment active_lease_fragment_{};
  HighSpeedActionType active_output_type_{HighSpeedActionType::None};
  std::uint32_t active_output_token_{0U};
  std::uint32_t active_output_token_snapshot_{0U};
  std::uint32_t active_output_writer_generation_snapshot_{0U};
  std::uint32_t last_bulk_action_token_{0U};
  std::uint32_t last_bulk_writer_generation_{0U};
  bool pixhawk_commit_pending_{false};
  std::uint32_t pixhawk_action_token_{0U};
  std::uint64_t pixhawk_write_accepted_ms_{0U};
  bool have_bulk_completion_{false};
  std::uint64_t bulk_complete_ms_{0U};
  bool have_bulk_tail_{false};
  std::uint64_t bulk_tail_ms_{0U};
  bool have_terminal_window_{false};
  std::uint64_t terminal_window_ms_{0U};
  bool have_last_time_{false};
  std::uint64_t last_time_ms_{0U};
  bool failed_{false};
  HighSpeedPhase6AdapterStatus last_status_{
      HighSpeedPhase6AdapterStatus::NoAction};
};

static_assert(
    HighSpeedPhase6AdapterTiming::terminal_transition_timeout_ms == 450U);

}  // namespace vc_lora::experimental
