#include "vc_lora/tdd_vehicle.hpp"

#include <algorithm>
#include <limits>

namespace vc_lora {
namespace {

bool prior_radio_write_completed(const TddInput& input) noexcept {
  return input.radio_tx_complete || input.radio_tx_empty;
}

}  // namespace
namespace {

std::uint16_t narrow_ms(std::uint32_t value) noexcept {
  return static_cast<std::uint16_t>(
      std::min<std::uint32_t>(value, std::numeric_limits<std::uint16_t>::max()));
}

}  // namespace

const char* vehicle_state_name(VehicleTddState state) noexcept {
  switch (state) {
    case VehicleTddState::DownlinkSend:
      return "DOWNLINK_SEND";
    case VehicleTddState::DownlinkDrain:
      return "DOWNLINK_DRAIN";
    case VehicleTddState::SendUlGrant:
      return "SEND_UL_GRANT";
    case VehicleTddState::GrantDrain:
      return "GRANT_DRAIN";
    case VehicleTddState::UplinkGuard:
      return "UPLINK_GUARD";
    case VehicleTddState::UplinkReceive:
      return "UPLINK_RECEIVE";
    case VehicleTddState::ReturnGuard:
      return "RETURN_GUARD";
  }
  return "UNKNOWN";
}

VehicleTddController::VehicleTddController(
    const TddConfig& config, LinkDiagnostics& diagnostics) noexcept
    : config_(config), diagnostics_(&diagnostics) {}

void VehicleTddController::reset(std::uint16_t session_id,
                                 std::uint16_t initial_cycle,
                                 std::uint64_t now_ms) noexcept {
  session_id_ = session_id;
  cycle_id_ = initial_cycle;
  state_ = VehicleTddState::DownlinkSend;
  state_entered_ms_ = now_ms;
  uplink_guard_deadline_ms_ = now_ms;
  return_guard_deadline_ms_ = now_ms;
  aux_high_since_ms_ = now_ms;
  action_issued_ms_ = now_ms;
  aux_was_high_ = false;
  action_pending_ = false;
  grant_sent_this_cycle_ = false;
  has_accepted_tx_ = false;
  heartbeat_tail_selected_ = false;
  heartbeat_tail_started_ = false;
  pending_heartbeat_tail_ = false;
  late_uplink_recovery_open_ = false;
  uplink_timeout_pending_ = false;
  pending_token_ = 0;
  pending_type_ = LinkActionType::None;
  pending_bytes_ = 0;
  last_tx_accepted_ms_ = now_ms;
}

void VehicleTddController::set_state(VehicleTddState state,
                                     std::uint64_t now_ms) noexcept {
  state_ = state;
  state_entered_ms_ = now_ms;
}

void VehicleTddController::update_aux(bool high,
                                      std::uint64_t now_ms) noexcept {
  if (!high) {
    aux_was_high_ = false;
    return;
  }
  if (!aux_was_high_) {
    aux_was_high_ = true;
    aux_high_since_ms_ = now_ms;
  }
}

bool VehicleTddController::aux_stable(std::uint64_t now_ms) const noexcept {
  return aux_was_high_ &&
         now_ms - aux_high_since_ms_ >= config_.aux_stable_ms;
}

bool VehicleTddController::tx_gap_elapsed(
    std::uint64_t now_ms) const noexcept {
  return !has_accepted_tx_ ||
         now_ms - last_tx_accepted_ms_ >= config_.min_tx_gap_ms;
}

bool VehicleTddController::should_defer_grant_for_heartbeat(
    const TddInput& input) const noexcept {
  if (!input.heartbeat_deadline_valid ||
      !input.heartbeat_tail_available) {
    return false;
  }
  if (input.now_ms >= input.heartbeat_deadline_ms) {
    return true;
  }
  return input.heartbeat_deadline_ms - input.now_ms <=
         config_.heartbeat_grant_reserve_ms;
}

void VehicleTddController::reopen_heartbeat_tail(
    std::uint64_t now_ms, bool deadline_missed) noexcept {
  // DownlinkDrain/SendUlGrant are reached after the nominal downlink interval.
  // Keep that boundary closed so ordinary telemetry is not re-admitted; the
  // existing selected-tail path emits only the retained complete heartbeat.
  state_ = VehicleTddState::DownlinkSend;
  state_entered_ms_ =
      now_ms >= config_.downlink_send_ms
          ? now_ms - config_.downlink_send_ms
          : 0U;
  heartbeat_tail_selected_ = true;
  heartbeat_tail_started_ = false;
  pending_heartbeat_tail_ = false;
  ++diagnostics_->heartbeat_grant_deferrals;
  if (deadline_missed) {
    ++diagnostics_->heartbeat_deadline_misses;
  }
}

LinkAction VehicleTddController::issue_data(
    std::uint16_t queued_bytes, std::uint64_t now_ms,
    bool heartbeat_tail) noexcept {
  LinkAction action{};
  action.type = LinkActionType::SendRadioData;
  action.token = next_token_++;
  action.byte_budget = std::min(queued_bytes, config_.radio_chunk_bytes);
  action_pending_ = true;
  pending_token_ = action.token;
  pending_type_ = action.type;
  pending_bytes_ = action.byte_budget;
  pending_heartbeat_tail_ = heartbeat_tail;
  action_issued_ms_ = now_ms;
  return action;
}

LinkAction VehicleTddController::issue_grant(
    std::uint64_t now_ms) noexcept {
  LinkAction action{};
  action.type = LinkActionType::SendGrant;
  action.token = next_token_++;
  action.control.version = kTddProtocolVersion;
  action.control.type = ControlType::UlGrant;
  action.control.session_id = session_id_;
  action.control.cycle_id = cycle_id_;
  action.control.guard_ms = narrow_ms(config_.uplink_guard_ms);
  action.control.window_ms = narrow_ms(config_.uplink_window_ms);
  action.control.max_bytes = config_.uplink_max_bytes;
  action.control.actual_bytes = 0;
  action.byte_budget = config_.uplink_max_bytes;

  action_pending_ = true;
  pending_token_ = action.token;
  pending_type_ = action.type;
  pending_bytes_ = 0;
  action_issued_ms_ = now_ms;
  return action;
}

LinkAction VehicleTddController::tick(const TddInput& input) noexcept {
  update_aux(input.aux_high, input.now_ms);
  diagnostics_->max_vehicle_queue =
      std::max<std::uint64_t>(diagnostics_->max_vehicle_queue,
                              input.queued_bytes);

  if (action_pending_) {
    if (input.now_ms - action_issued_ms_ >= config_.action_retry_timeout_ms) {
      action_pending_ = false;
      pending_type_ = LinkActionType::None;
      pending_bytes_ = 0;
      pending_heartbeat_tail_ = false;
      ++diagnostics_->action_retries;
    } else {
      return {};
    }
  }

  switch (state_) {
    case VehicleTddState::DownlinkSend:
      // The time boundary closes admission of the next local frame.  An
      // already-active frame may still need more 32-byte radio transactions;
      // do not cut it into a CRC-invalid prefix at the boundary.
      if (input.now_ms - state_entered_ms_ >= config_.downlink_send_ms) {
        const std::uint64_t heartbeat_tail_wait_elapsed =
            input.now_ms - state_entered_ms_ - config_.downlink_send_ms;
        const bool heartbeat_selection_open =
            input.heartbeat_tail_enabled &&
            heartbeat_tail_wait_elapsed <= config_.heartbeat_tail_wait_ms;

        // Selection is independent of UART/AUX readiness.  Once a real
        // heartbeat is visible inside the absolute nominal-boundary window,
        // keep that intent across gaps and rejected physical writes.
        if (!heartbeat_tail_selected_ && heartbeat_selection_open &&
            input.heartbeat_tail_available) {
          heartbeat_tail_selected_ = true;
        }

        // A heartbeat that had already put bytes on air before crossing the
        // boundary is an exact active-frame continuation, not a new tail.
        if (heartbeat_tail_selected_ && input.heartbeat_tail_active &&
            input.heartbeat_tail_active_started) {
          heartbeat_tail_started_ = true;
        }

        if (!input.local_tx_empty) {
          const bool active_heartbeat_tail =
              heartbeat_tail_selected_ && input.heartbeat_tail_active;
          if (input.queued_bytes > 0U && input.radio_tx_empty &&
              aux_stable(input.now_ms) && tx_gap_elapsed(input.now_ms)) {
            const auto queued = static_cast<std::uint16_t>(
                std::min<std::uint32_t>(input.queued_bytes, 0xFFFFU));
            return issue_data(queued, input.now_ms, active_heartbeat_tail);
          }
          break;
        }

        // Once a selected heartbeat tail has completed, do not admit a
        // second frame. Drain and grant exactly as for any completed active
        // MAVLink frame.
        if (heartbeat_tail_started_) {
          set_state(VehicleTddState::DownlinkDrain, input.now_ms);
          break;
        }

        if (!input.heartbeat_tail_enabled) {
          set_state(VehicleTddState::DownlinkDrain, input.now_ms);
          break;
        }

        if (heartbeat_tail_selected_ && input.heartbeat_tail_available &&
            input.queued_bytes > 0U && input.radio_tx_empty &&
            aux_stable(input.now_ms) && tx_gap_elapsed(input.now_ms)) {
          const auto queued = static_cast<std::uint16_t>(
              std::min<std::uint32_t>(input.queued_bytes, 0xFFFFU));
          return issue_data(queued, input.now_ms, true);
        }
        if ((!heartbeat_tail_selected_ ||
             !input.heartbeat_tail_available) &&
            heartbeat_tail_wait_elapsed >=
            config_.heartbeat_tail_wait_ms) {
          heartbeat_tail_selected_ = false;
          set_state(VehicleTddState::DownlinkDrain, input.now_ms);
        }
      } else if (input.queued_bytes > 0U && input.radio_tx_empty &&
                 aux_stable(input.now_ms) && tx_gap_elapsed(input.now_ms)) {
        const auto queued = static_cast<std::uint16_t>(
            std::min<std::uint32_t>(input.queued_bytes, 0xFFFFU));
        return issue_data(queued, input.now_ms);
      }
      break;

    case VehicleTddState::DownlinkDrain:
      if (input.local_tx_empty && prior_radio_write_completed(input) &&
          aux_stable(input.now_ms) && tx_gap_elapsed(input.now_ms)) {
        if (should_defer_grant_for_heartbeat(input)) {
          reopen_heartbeat_tail(
              input.now_ms,
              input.now_ms >= input.heartbeat_deadline_ms);
        } else if (!input.inhibit_new_grant) {
          set_state(VehicleTddState::SendUlGrant, input.now_ms);
        }
      }
      break;

    case VehicleTddState::SendUlGrant:
      if (!grant_sent_this_cycle_) {
        if (should_defer_grant_for_heartbeat(input)) {
          reopen_heartbeat_tail(
              input.now_ms,
              input.now_ms >= input.heartbeat_deadline_ms);
          break;
        }
        if (!input.inhibit_new_grant) return issue_grant(input.now_ms);
      }
      break;

    case VehicleTddState::GrantDrain:
      if (prior_radio_write_completed(input) && aux_stable(input.now_ms)) {
        // The fixed direction guard starts only after the accepted GRANT has
        // physically drained.  Starting it at UART acceptance lets the E220
        // high-only completion dwell consume part of the 650-ms guard and can
        // advance the cycle before a queued same-cycle terminal arrives.
        uplink_guard_deadline_ms_ = input.now_ms + config_.uplink_guard_ms;
        set_state(VehicleTddState::UplinkGuard, input.now_ms);
      }
      break;

    case VehicleTddState::UplinkGuard:
      if (input.now_ms >= uplink_guard_deadline_ms_) {
        set_state(VehicleTddState::UplinkReceive, input.now_ms);
      }
      break;

    case VehicleTddState::UplinkReceive:
      if (input.now_ms - state_entered_ms_ >=
          config_.vehicle_receive_timeout_ms) {
        // E220 delivery can lag the UART-accepted grant.  Keep the same-cycle
        // lease open until this absolute timeout-originated deadline; raw
        // activity may extend it, but cannot shorten it.
        uplink_timeout_pending_ = true;
        late_uplink_recovery_open_ = true;
        return_guard_deadline_ms_ =
            input.now_ms + std::max(config_.late_terminal_wait_ms,
                                    config_.return_guard_ms);
        set_state(VehicleTddState::ReturnGuard, input.now_ms);
      }
      break;

    case VehicleTddState::ReturnGuard:
      if (input.now_ms >= return_guard_deadline_ms_) {
        if (uplink_timeout_pending_) {
          ++diagnostics_->uplink_timeouts;
          uplink_timeout_pending_ = false;
        }
        cycle_id_ = static_cast<std::uint16_t>(cycle_id_ + 1U);
        grant_sent_this_cycle_ = false;
        heartbeat_tail_selected_ = false;
        heartbeat_tail_started_ = false;
        pending_heartbeat_tail_ = false;
        late_uplink_recovery_open_ = false;
        set_state(VehicleTddState::DownlinkSend, input.now_ms);
      }
      break;
  }
  return {};
}

bool VehicleTddController::cancel_unsent_grant(std::uint32_t token,
    std::uint16_t session,std::uint16_t cycle,std::uint64_t now_ms) noexcept {
  if(!action_pending_ || pending_type_!=LinkActionType::SendGrant ||
     state_!=VehicleTddState::SendUlGrant || grant_sent_this_cycle_ ||
     token==0U || token!=pending_token_ || session!=session_id_ ||
     cycle!=cycle_id_ || cycle_id_==std::numeric_limits<std::uint16_t>::max() ||
     now_ms<action_issued_ms_) return false;
  action_pending_=false;pending_token_=0U;pending_type_=LinkActionType::None;
  pending_bytes_=0U;pending_heartbeat_tail_=false;
  ++cycle_id_;++diagnostics_->action_retries;
  reopen_heartbeat_tail(now_ms,false);
  return true;
}

void VehicleTddController::complete_action(std::uint32_t token,
                                           TxResult result,
                                           std::uint64_t now_ms,
                                           std::uint16_t accepted_bytes) noexcept {
  if (!action_pending_ || token != pending_token_) {
    return;
  }
  const LinkActionType completed_type = pending_type_;
  const bool completed_heartbeat_tail = pending_heartbeat_tail_;
  const std::uint16_t completed_bytes =
      accepted_bytes == 0xFFFFU
          ? pending_bytes_
          : std::min(accepted_bytes, pending_bytes_);
  action_pending_ = false;
  pending_type_ = LinkActionType::None;
  pending_bytes_ = 0;
  pending_heartbeat_tail_ = false;
  if (result != TxResult::Accepted) {
    ++diagnostics_->action_retries;
    return;
  }
  has_accepted_tx_ = true;
  last_tx_accepted_ms_ = now_ms;
  if (completed_type == LinkActionType::SendRadioData &&
      state_ == VehicleTddState::DownlinkSend) {
    if (completed_heartbeat_tail && completed_bytes > 0U) {
      heartbeat_tail_started_ = true;
    }
    ++diagnostics_->downlink_transactions;
    diagnostics_->downlink_payload_bytes += completed_bytes;
  } else if (completed_type == LinkActionType::SendGrant &&
      state_ == VehicleTddState::SendUlGrant) {
    grant_sent_this_cycle_ = true;
    ++diagnostics_->grant_tx;
    set_state(VehicleTddState::GrantDrain, now_ms);
  }
}

ControlDisposition VehicleTddController::on_control(
    const TddControlMessage& message, std::uint64_t now_ms) noexcept {
  if (message.version != kTddProtocolVersion ||
      (message.type != ControlType::UlDone &&
       message.type != ControlType::UlIdle)) {
    return ControlDisposition::Invalid;
  }
  if (message.session_id != session_id_) {
    ++diagnostics_->stale_sessions;
    return ControlDisposition::OldSession;
  }
  if (message.cycle_id != cycle_id_) {
    ++diagnostics_->stale_cycles;
    return ControlDisposition::OldCycle;
  }
  if (!radio_receive_window()) {
    return ControlDisposition::Ignored;
  }
  if (message.actual_bytes > config_.uplink_max_bytes) {
    ++diagnostics_->invalid_done;
    return ControlDisposition::Invalid;
  }

  if (message.type == ControlType::UlIdle) {
    ++diagnostics_->idle_rx;
  } else {
    ++diagnostics_->done_rx;
  }
  late_uplink_recovery_open_ = false;
  uplink_timeout_pending_ = false;
  return_guard_deadline_ms_ = now_ms + config_.return_guard_ms;
  set_state(VehicleTddState::ReturnGuard, now_ms);
  return ControlDisposition::Accepted;
}

bool VehicleTddController::note_return_guard_activity(
    std::uint64_t now_ms) noexcept {
  if (state_ != VehicleTddState::ReturnGuard) {
    return false;
  }
  // Raw activity can only lengthen a pending lease.  Before a terminal, keep
  // the absolute timeout-originated wait as a floor; after a terminal, this
  // is the ordinary fixed no-transmit guard from the most recent byte.
  return_guard_deadline_ms_ = std::max(
      return_guard_deadline_ms_, now_ms + config_.return_guard_ms);
  return true;
}

bool VehicleTddController::discard_current_uplink(
    std::uint64_t now_ms) noexcept {
  if (!radio_receive_window()) {
    return false;
  }
  ++diagnostics_->invalid_done;
  late_uplink_recovery_open_ = false;
  uplink_timeout_pending_ = false;
  return_guard_deadline_ms_ = now_ms + config_.return_guard_ms;
  set_state(VehicleTddState::ReturnGuard, now_ms);
  return true;
}

bool VehicleTddController::complete_late_uplink_terminal(
    std::uint64_t now_ms, ControlType type,
    bool payload_accepted) noexcept {
  if (!late_uplink_recovery_window()) {
    return false;
  }
  late_uplink_recovery_open_ = false;
  return_guard_deadline_ms_ = now_ms + config_.return_guard_ms;
  if (payload_accepted && type == ControlType::UlDone) {
    ++diagnostics_->done_rx;
    uplink_timeout_pending_ = false;
  } else if (payload_accepted && type == ControlType::UlIdle) {
    ++diagnostics_->idle_rx;
    uplink_timeout_pending_ = false;
  } else {
    ++diagnostics_->invalid_done;
  }
  return true;
}

}  // namespace vc_lora
