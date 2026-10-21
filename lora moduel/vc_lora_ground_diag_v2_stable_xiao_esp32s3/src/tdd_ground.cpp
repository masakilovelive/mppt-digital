#include "vc_lora/tdd_ground.hpp"

#include <algorithm>
#include <limits>

namespace vc_lora {
namespace {

bool prior_radio_write_completed(const TddInput& input) noexcept {
  return input.radio_tx_complete || input.radio_tx_empty;
}

}  // namespace

const char* ground_state_name(GroundTddState state) noexcept {
  switch (state) {
    case GroundTddState::WaitGrant:
      return "WAIT_GRANT";
    case GroundTddState::UplinkGuard:
      return "UPLINK_GUARD";
    case GroundTddState::UplinkSend:
      return "UPLINK_SEND";
    case GroundTddState::UplinkDrain:
      return "UPLINK_DRAIN";
    case GroundTddState::SendUlDone:
      return "SEND_UL_DONE";
    case GroundTddState::DoneDrain:
      return "DONE_DRAIN";
  }
  return "UNKNOWN";
}

GroundTddController::GroundTddController(
    const TddConfig& config, LinkDiagnostics& diagnostics) noexcept
    : config_(config), diagnostics_(&diagnostics) {}

void GroundTddController::reset(std::uint64_t now_ms) noexcept {
  state_ = GroundTddState::WaitGrant;
  has_session_ = false;
  has_cycle_ = false;
  lease_valid_ = false;
  lease_consumed_ = false;
  send_idle_ = false;
  aux_was_high_ = false;
  action_pending_ = false;
  has_accepted_tx_ = false;
  fail_closed_ = false;
  session_id_ = 0;
  cycle_id_ = 0;
  granted_bytes_ = 0;
  actual_bytes_ = 0;
  transaction_target_bytes_ = 0;
  frame_aware_transaction_ = false;
  state_entered_ms_ = now_ms;
  guard_deadline_ms_ = now_ms;
  window_deadline_ms_ = now_ms;
  transaction_deadline_ms_ = 0U;
  aux_high_since_ms_ = now_ms;
  action_issued_ms_ = now_ms;
  pending_token_ = 0;
  pending_type_ = LinkActionType::None;
  pending_bytes_ = 0;
  last_tx_accepted_ms_ = now_ms;
}

void GroundTddController::latch_started_transaction_failure() noexcept {
  if (fail_closed_) {
    return;
  }
  fail_closed_ = true;
  lease_valid_ = false;
  action_pending_ = false;
  pending_type_ = LinkActionType::None;
  pending_bytes_ = 0U;
  ++diagnostics_->abandoned_uplink_transactions;
}

void GroundTddController::set_state(GroundTddState state,
                                    std::uint64_t now_ms) noexcept {
  state_ = state;
  state_entered_ms_ = now_ms;
}

void GroundTddController::update_aux(bool high,
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

bool GroundTddController::aux_stable(std::uint64_t now_ms) const noexcept {
  return aux_was_high_ &&
         now_ms - aux_high_since_ms_ >= config_.aux_stable_ms;
}

bool GroundTddController::tx_gap_elapsed(std::uint64_t now_ms) const noexcept {
  return !has_accepted_tx_ ||
         now_ms - last_tx_accepted_ms_ >= config_.min_tx_gap_ms;
}

std::uint64_t GroundTddController::estimated_tx_duration_ms(
    std::uint16_t bytes) const noexcept {
  if (bytes == 0U || config_.radio_chunk_bytes == 0U) {
    return 0U;
  }
  const std::uint64_t uart_numerator =
      static_cast<std::uint64_t>(bytes) * 10U * 1000U;
  const std::uint64_t air_numerator =
      static_cast<std::uint64_t>(bytes) * 8U * 1000U;
  const std::uint64_t uart_ms =
      config_.radio_uart_bps == 0U
          ? 0U
          : (uart_numerator + config_.radio_uart_bps - 1U) /
                config_.radio_uart_bps;
  const std::uint64_t air_ms =
      config_.radio_air_bps == 0U
          ? 0U
          : (air_numerator + config_.radio_air_bps - 1U) /
                config_.radio_air_bps;
  const std::uint64_t chunks =
      (bytes + config_.radio_chunk_bytes - 1U) /
      config_.radio_chunk_bytes;
  const std::uint64_t gaps = chunks > 0U ? chunks - 1U : 0U;
  return std::max<std::uint64_t>(
      1U, uart_ms + air_ms + gaps * config_.min_tx_gap_ms);
}

bool GroundTddController::payload_fits_window(
    std::uint64_t now_ms, std::uint16_t queued_bytes,
    std::uint16_t next_application_bytes,
    std::uint16_t next_wire_bytes) const noexcept {
  const std::uint16_t transaction_limit =
      transaction_target_bytes_ > 0U ? transaction_target_bytes_
                                     : granted_bytes_;
  const std::uint16_t remaining =
      actual_bytes_ < transaction_limit
          ? static_cast<std::uint16_t>(transaction_limit - actual_bytes_)
          : 0U;
  const std::uint16_t bytes = std::min(queued_bytes, remaining);
  const bool have_encoded_preview =
      next_application_bytes > 0U && next_wire_bytes > 0U;
  const std::uint16_t estimated_bytes =
      have_encoded_preview ? next_wire_bytes : bytes;
  return now_ms < window_deadline_ms_ &&
         estimated_tx_duration_ms(estimated_bytes) <=
             window_deadline_ms_ - now_ms;
}

void GroundTddController::accept_grant(const TddControlMessage& message,
                                       std::uint64_t now_ms,
                                       bool new_session) noexcept {
  if (new_session && has_session_) {
    ++diagnostics_->session_changes;
  }
  has_session_ = true;
  has_cycle_ = true;
  session_id_ = message.session_id;
  cycle_id_ = message.cycle_id;
  granted_bytes_ = message.max_bytes;
  actual_bytes_ = 0;
  transaction_target_bytes_ = 0;
  frame_aware_transaction_ = false;
  transaction_deadline_ms_ = 0U;
  lease_valid_ = true;
  lease_consumed_ = false;
  send_idle_ = false;
  action_pending_ = false;
  pending_type_ = LinkActionType::None;
  guard_deadline_ms_ = now_ms + message.guard_ms;
  window_deadline_ms_ = guard_deadline_ms_ + message.window_ms;
  ++diagnostics_->grant_rx;
  set_state(GroundTddState::UplinkGuard, now_ms);
}

ControlDisposition GroundTddController::on_control(
    const TddControlMessage& message, std::uint64_t now_ms) noexcept {
  if (fail_closed_) {
    return ControlDisposition::Invalid;
  }
  if (message.version != kTddProtocolVersion ||
      message.type != ControlType::UlGrant || message.max_bytes == 0U ||
      message.window_ms == 0U) {
    return ControlDisposition::Invalid;
  }

  if (!has_session_) {
    accept_grant(message, now_ms, true);
    return ControlDisposition::Accepted;
  }

  if (message.session_id != session_id_) {
    if (compare_sequence(message.session_id, session_id_) !=
        SequenceOrder::Newer) {
      ++diagnostics_->stale_sessions;
      return ControlDisposition::OldSession;
    }
    if (actual_bytes_ > 0U && transaction_deadline_ms_ > 0U) {
      // A consumed prefix cannot be restored to the source queue. Accepting a
      // rebooted Vehicle session here would reinterpret the retained suffix as
      // a fresh frame. Preserve the transaction evidence and fail closed.
      latch_started_transaction_failure();
      return ControlDisposition::Invalid;
    }
    accept_grant(message, now_ms, true);
    return ControlDisposition::Accepted;
  }

  if (!has_cycle_) {
    accept_grant(message, now_ms, false);
    return ControlDisposition::Accepted;
  }

  const SequenceOrder order = compare_sequence(message.cycle_id, cycle_id_);
  if (order == SequenceOrder::Duplicate) {
    ++diagnostics_->duplicate_grants;
    return ControlDisposition::Duplicate;
  }
  if (order == SequenceOrder::Older) {
    ++diagnostics_->stale_cycles;
    return ControlDisposition::OldCycle;
  }
  if (sequence_distance(message.cycle_id, cycle_id_) >
      config_.max_cycle_jump) {
    ++diagnostics_->future_cycles;
    return ControlDisposition::FutureCycle;
  }
  if (state_ != GroundTddState::WaitGrant) {
    ++diagnostics_->future_cycles;
    return ControlDisposition::FutureCycle;
  }

  accept_grant(message, now_ms, false);
  return ControlDisposition::Accepted;
}

LinkAction GroundTddController::issue_data(
                                           std::uint16_t queued_bytes,
                                           std::uint16_t next_application_bytes,
                                           std::uint64_t now_ms) noexcept {
  LinkAction action{};
  action.type = LinkActionType::SendRadioData;
  action.token = next_token_++;
  const std::uint16_t transaction_limit =
      transaction_target_bytes_ > 0U ? transaction_target_bytes_
                                     : granted_bytes_;
  const std::uint16_t remaining =
      actual_bytes_ < transaction_limit
          ? static_cast<std::uint16_t>(transaction_limit - actual_bytes_)
          : 0U;
  const std::uint16_t adapter_budget =
      next_application_bytes > 0U ? next_application_bytes
                                  : config_.radio_chunk_bytes;
  action.byte_budget = std::min(
      {queued_bytes, remaining, config_.radio_chunk_bytes, adapter_budget});
  action_pending_ = true;
  pending_token_ = action.token;
  pending_type_ = action.type;
  pending_bytes_ = action.byte_budget;
  action_issued_ms_ = now_ms;
  return action;
}

LinkAction GroundTddController::issue_done(std::uint64_t now_ms) noexcept {
  LinkAction action{};
  action.type = LinkActionType::SendDone;
  action.token = next_token_++;
  action.control.version = kTddProtocolVersion;
  action.control.type = send_idle_ ? ControlType::UlIdle : ControlType::UlDone;
  action.control.session_id = session_id_;
  action.control.cycle_id = cycle_id_;
  action.control.guard_ms = 0;
  action.control.window_ms = 0;
  action.control.max_bytes = granted_bytes_;
  action.control.actual_bytes = actual_bytes_;
  action_pending_ = true;
  pending_token_ = action.token;
  pending_type_ = action.type;
  pending_bytes_ = 0;
  action_issued_ms_ = now_ms;
  return action;
}

LinkAction GroundTddController::tick(const TddInput& input) noexcept {
  update_aux(input.aux_high, input.now_ms);
  diagnostics_->max_ground_queue =
      std::max<std::uint64_t>(diagnostics_->max_ground_queue,
                              input.queued_bytes);

  if (fail_closed_) {
    return {};
  }

  if (actual_bytes_ > 0U && transaction_deadline_ms_ > 0U &&
      input.now_ms >= transaction_deadline_ms_) {
    // Completion already observable at the exact boundary wins. No other
    // state may begin or continue physical work at/after the absolute lease:
    // a partially dequeued MAVLink frame cannot be restored or acknowledged
    // with a partial DONE, so the only safe outcome is a latched fail-close.
    if (state_ == GroundTddState::DoneDrain && !action_pending_ &&
        prior_radio_write_completed(input) && aux_stable(input.now_ms)) {
      lease_valid_ = false;
      transaction_deadline_ms_ = 0U;
      set_state(GroundTddState::WaitGrant, input.now_ms);
      return {};
    }
    latch_started_transaction_failure();
    return {};
  }

  if (action_pending_) {
    if (input.now_ms - action_issued_ms_ >= config_.action_retry_timeout_ms) {
      action_pending_ = false;
      pending_type_ = LinkActionType::None;
      ++diagnostics_->action_retries;
    } else {
      return {};
    }
  }

  switch (state_) {
    case GroundTddState::WaitGrant:
      break;

    case GroundTddState::UplinkGuard:
      if (input.now_ms < guard_deadline_ms_) {
        break;
      }
      if (input.queued_bytes == 0U) {
        send_idle_ = true;
        set_state(GroundTddState::SendUlDone, input.now_ms);
      } else if (input.now_ms >= window_deadline_ms_) {
        ++diagnostics_->expired_windows;
        send_idle_ = true;
        set_state(GroundTddState::SendUlDone, input.now_ms);
      } else {
        if (transaction_target_bytes_ == 0U) {
          if (input.front_frame_bytes > granted_bytes_) {
            // A complete MAVLink frame which cannot fit one v2 application
            // grant must remain wholly queued. Sending a prefix would make
            // DONE invalidate the entire Vehicle quarantine transaction.
            ++diagnostics_->insufficient_window_count;
            send_idle_ = true;
            set_state(GroundTddState::SendUlDone, input.now_ms);
            break;
          }
          if (input.front_frame_bytes > 0U) {
            const std::uint32_t minimum_wire_bytes =
                config_.radio_chunk_bytes == 0U
                    ? 0U
                    : ((static_cast<std::uint32_t>(
                            input.front_frame_bytes) +
                        config_.radio_chunk_bytes - 1U) /
                       config_.radio_chunk_bytes) *
                          config_.radio_chunk_bytes;
            const bool complete_wire_preview =
                minimum_wire_bytes > 0U &&
                input.next_tx_application_bytes > 0U &&
                input.next_tx_application_bytes <= input.front_frame_bytes &&
                input.next_tx_wire_bytes >= minimum_wire_bytes &&
                input.next_tx_wire_bytes % config_.radio_chunk_bytes == 0U;
            if (!complete_wire_preview) {
              // A frame-aware adapter must prove the whole selected
              // descriptor's padded wire cost before any application prefix
              // is consumed. Missing or one-write-only previews fail idle.
              ++diagnostics_->insufficient_window_count;
              send_idle_ = true;
              set_state(GroundTddState::SendUlDone, input.now_ms);
              break;
            }
          }
          frame_aware_transaction_ = input.front_frame_bytes > 0U;
          transaction_target_bytes_ = frame_aware_transaction_
                                          ? input.front_frame_bytes
                                          : granted_bytes_;
        }
        const auto queued = static_cast<std::uint16_t>(
            std::min<std::uint32_t>(input.queued_bytes, 0xFFFFU));
        if (!payload_fits_window(input.now_ms, queued,
                                 input.next_tx_application_bytes,
                                 input.next_tx_wire_bytes)) {
          ++diagnostics_->insufficient_window_count;
          send_idle_ = true;
          set_state(GroundTddState::SendUlDone, input.now_ms);
          break;
        }
        if (aux_stable(input.now_ms) && input.radio_tx_empty) {
          set_state(GroundTddState::UplinkSend, input.now_ms);
        }
      }
      break;

    case GroundTddState::UplinkSend:
      if (transaction_target_bytes_ > 0U &&
          actual_bytes_ >= transaction_target_bytes_) {
        set_state(GroundTddState::UplinkDrain, input.now_ms);
      } else if (input.queued_bytes == 0U) {
        if (frame_aware_transaction_ && actual_bytes_ > 0U) {
          // A frame-aware source cannot legitimately lose the retained suffix
          // after accepting an irreversible prefix. Never describe that
          // partial MAVLink frame with UL_DONE.
          latch_started_transaction_failure();
          break;
        }
        if (input.now_ms >= window_deadline_ms_) {
          ++diagnostics_->expired_windows;
        }
        send_idle_ = true;
        set_state(GroundTddState::SendUlDone, input.now_ms);
      } else if (actual_bytes_ == 0U &&
                 input.now_ms >= window_deadline_ms_) {
        ++diagnostics_->expired_windows;
        send_idle_ = true;
        set_state(GroundTddState::SendUlDone, input.now_ms);
      } else if (actual_bytes_ < transaction_target_bytes_ &&
                 aux_stable(input.now_ms) &&
                 input.radio_tx_empty && tx_gap_elapsed(input.now_ms)) {
        const auto queued = static_cast<std::uint16_t>(
            std::min<std::uint32_t>(input.queued_bytes, 0xFFFFU));
        // The window is a whole-transaction admission deadline. Once the
        // first prefix of a preflight-approved complete frame was accepted,
        // E220 service-floor pacing may carry its bounded remaining prefix
        // beyond that deadline; cutting it here would make the explicit DONE
        // invalidate the Vehicle quarantine.
        if (actual_bytes_ == 0U &&
            !payload_fits_window(input.now_ms, queued,
                                 input.next_tx_application_bytes,
                                 input.next_tx_wire_bytes)) {
          ++diagnostics_->insufficient_window_count;
          send_idle_ = actual_bytes_ == 0U;
          set_state(GroundTddState::SendUlDone, input.now_ms);
          break;
        }
        return issue_data(queued, input.next_tx_application_bytes,
                          input.now_ms);
      }
      break;

    case GroundTddState::UplinkDrain:
      if (prior_radio_write_completed(input) && aux_stable(input.now_ms) &&
          tx_gap_elapsed(input.now_ms)) {
        if (transaction_target_bytes_ > 0U &&
            actual_bytes_ >= transaction_target_bytes_) {
          // Unlike v3's removed implicit terminal, completing the selected
          // frame only ends application transmission. Protocol v2 always
          // proceeds to a separately encoded and physically written UL_DONE.
          set_state(GroundTddState::SendUlDone, input.now_ms);
        } else if (frame_aware_transaction_ && actual_bytes_ > 0U &&
                   input.queued_bytes == 0U) {
          // The selected descriptor's suffix disappeared after prefix
          // acceptance. It is no longer possible to roll back or send a
          // truthful terminal, so preserve the evidence and fail closed.
          latch_started_transaction_failure();
        } else if (input.queued_bytes > 0U &&
                   actual_bytes_ < transaction_target_bytes_) {
          const auto queued = static_cast<std::uint16_t>(
              std::min<std::uint32_t>(input.queued_bytes, 0xFFFFU));
          if (actual_bytes_ > 0U ||
              payload_fits_window(input.now_ms, queued,
                                  input.next_tx_application_bytes,
                                  input.next_tx_wire_bytes)) {
            set_state(GroundTddState::UplinkSend, input.now_ms);
          } else {
            ++diagnostics_->insufficient_window_count;
            set_state(GroundTddState::SendUlDone, input.now_ms);
          }
        } else {
          set_state(GroundTddState::SendUlDone, input.now_ms);
        }
      }
      break;

    case GroundTddState::SendUlDone:
      if (input.radio_tx_empty && aux_stable(input.now_ms) &&
          tx_gap_elapsed(input.now_ms)) {
        return issue_done(input.now_ms);
      }
      break;

    case GroundTddState::DoneDrain:
      if (prior_radio_write_completed(input) && aux_stable(input.now_ms)) {
        lease_valid_ = false;
        transaction_deadline_ms_ = 0U;
        set_state(GroundTddState::WaitGrant, input.now_ms);
      }
      break;
  }
  return {};
}

void GroundTddController::complete_action(std::uint32_t token,
                                          TxResult result,
                                          std::uint64_t now_ms,
                                          std::uint16_t accepted_bytes) noexcept {
  if (!action_pending_ || token != pending_token_) {
    return;
  }
  const LinkActionType completed_type = pending_type_;
  const std::uint16_t completed_bytes =
      accepted_bytes == 0xFFFFU
          ? pending_bytes_
          : std::min(accepted_bytes, pending_bytes_);
  action_pending_ = false;
  pending_type_ = LinkActionType::None;
  pending_bytes_ = 0;
  if (result != TxResult::Accepted) {
    ++diagnostics_->action_retries;
    return;
  }

  has_accepted_tx_ = true;
  last_tx_accepted_ms_ = now_ms;

  if (completed_type == LinkActionType::SendRadioData &&
      state_ == GroundTddState::UplinkSend) {
    const bool starts_transaction = actual_bytes_ == 0U && completed_bytes > 0U;
    actual_bytes_ = static_cast<std::uint16_t>(actual_bytes_ + completed_bytes);
    if (starts_transaction) {
      const std::uint64_t remaining =
          std::numeric_limits<std::uint64_t>::max() - now_ms;
      transaction_deadline_ms_ =
          config_.vehicle_receive_timeout_ms > remaining
              ? std::numeric_limits<std::uint64_t>::max()
              : now_ms + config_.vehicle_receive_timeout_ms;
    }
    if (!lease_consumed_) {
      lease_consumed_ = true;
      ++diagnostics_->uplink_transactions;
    }
    diagnostics_->uplink_payload_bytes += completed_bytes;
    set_state(GroundTddState::UplinkDrain, now_ms);
  } else if (completed_type == LinkActionType::SendDone &&
             state_ == GroundTddState::SendUlDone) {
    if (send_idle_) {
      ++diagnostics_->idle_tx;
    } else {
      ++diagnostics_->done_tx;
    }
    set_state(GroundTddState::DoneDrain, now_ms);
  }
}

}  // namespace vc_lora
