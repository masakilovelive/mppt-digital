#include "vc_lora/bulk_heartbeat_sla.hpp"

#include "vc_lora/bulk_session_controller.hpp"

#include <algorithm>
#include <limits>

namespace vc_lora {

static_assert(BulkHeartbeatSlaTiming::heartbeat_deadline_ms ==
              BulkSessionAccounting::heartbeat_deadline_ms);
static_assert(BulkHeartbeatSlaTiming::completion_deadline_ms ==
              BulkSessionAccounting::completion_deadline_ms);

BulkHeartbeatSlaLedger::BulkHeartbeatSlaLedger(
    std::uint32_t transfer_tag) noexcept {
  evidence_.transfer_tag = transfer_tag;
  if (transfer_tag == 0U) {
    failed_ = true;
    last_error_ = BulkHeartbeatSlaStatus::InvalidConfiguration;
  }
}

BulkHeartbeatSlaStatus BulkHeartbeatSlaLedger::capture_baseline(
    std::uint64_t now_ms) noexcept {
  if (failed_ || sealed_) {
    return BulkHeartbeatSlaStatus::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != State::Idle && state_ != State::BaselineReady) {
    return fail(state_ == State::Complete
                    ? BulkHeartbeatSlaStatus::PostCompleteData
                    : BulkHeartbeatSlaStatus::InvalidState);
  }

  have_baseline_ = true;
  baseline_ms_ = now_ms;
  state_ = State::BaselineReady;
  return BulkHeartbeatSlaStatus::BaselineCaptured;
}

BulkHeartbeatSlaStatus BulkHeartbeatSlaLedger::start_request(
    std::uint64_t now_ms) noexcept {
  if (failed_ || sealed_) {
    return BulkHeartbeatSlaStatus::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (!have_baseline_) {
    return fail(BulkHeartbeatSlaStatus::MissingBaseline);
  }
  if (state_ != State::BaselineReady) {
    return fail(BulkHeartbeatSlaStatus::InvalidState);
  }
  if (now_ms - baseline_ms_ >
      BulkHeartbeatSlaTiming::heartbeat_deadline_ms) {
    return fail(BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded);
  }

  have_request_epoch_ = true;
  request_epoch_ms_ = now_ms;
  evidence_.request_started_ms = now_ms;
  have_last_heartbeat_ = true;
  last_heartbeat_ms_ = baseline_ms_;
  state_ = State::Active;
  return BulkHeartbeatSlaStatus::RequestStarted;
}

BulkHeartbeatSlaStatus BulkHeartbeatSlaLedger::accept_heartbeat(
    std::uint64_t now_ms) noexcept {
  if (failed_) {
    return BulkHeartbeatSlaStatus::Latched;
  }
  if (sealed_) {
    return fail(BulkHeartbeatSlaStatus::PostCompleteData);
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ == State::Complete) {
    return fail(BulkHeartbeatSlaStatus::PostCompleteData);
  }
  if (state_ != State::Active || !have_request_epoch_ ||
      !have_last_heartbeat_) {
    return fail(BulkHeartbeatSlaStatus::InvalidState);
  }

  const std::uint64_t gap_ms = now_ms - last_heartbeat_ms_;
  if (gap_ms > BulkHeartbeatSlaTiming::heartbeat_deadline_ms) {
    return fail(BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded);
  }
  if (evidence_.heartbeat_count ==
      std::numeric_limits<std::uint32_t>::max()) {
    return fail(BulkHeartbeatSlaStatus::CounterOverflow);
  }

  const std::uint32_t gap = static_cast<std::uint32_t>(gap_ms);
  if (evidence_.heartbeat_count == 0U) {
    evidence_.first_heartbeat_gap_ms = gap;
    evidence_.max_heartbeat_gap_ms = gap;
  } else {
    evidence_.max_heartbeat_gap_ms =
        std::max(evidence_.max_heartbeat_gap_ms, gap);
  }
  ++evidence_.heartbeat_count;
  evidence_.last_heartbeat_request_id = evidence_.heartbeat_count;
  last_heartbeat_ms_ = now_ms;
  return BulkHeartbeatSlaStatus::HeartbeatAccepted;
}

BulkHeartbeatSlaStatus BulkHeartbeatSlaLedger::complete_final_parameter(
    std::uint64_t now_ms) noexcept {
  if (failed_ || sealed_) {
    return BulkHeartbeatSlaStatus::Latched;
  }
  if (!note_time(now_ms)) {
    return last_error_;
  }
  if (state_ != State::Active || !have_request_epoch_ ||
      !have_last_heartbeat_) {
    return fail(BulkHeartbeatSlaStatus::InvalidState);
  }

  const std::uint64_t elapsed_ms = now_ms - request_epoch_ms_;
  if (elapsed_ms > BulkHeartbeatSlaTiming::completion_deadline_ms) {
    return fail(BulkHeartbeatSlaStatus::CompletionDeadlineExceeded);
  }
  if (evidence_.heartbeat_count == 0U) {
    return fail(BulkHeartbeatSlaStatus::MissingHeartbeat);
  }
  const std::uint64_t post_gap_ms = now_ms - last_heartbeat_ms_;
  if (post_gap_ms > BulkHeartbeatSlaTiming::heartbeat_deadline_ms) {
    return fail(BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded);
  }

  evidence_.request_to_last_parameter_ms =
      static_cast<std::uint32_t>(elapsed_ms);
  evidence_.final_parameter_committed_ms = now_ms;
  evidence_.post_heartbeat_gap_ms =
      static_cast<std::uint32_t>(post_gap_ms);
  evidence_.complete = true;
  state_ = State::Complete;
  return BulkHeartbeatSlaStatus::EvidenceReady;
}

BulkHeartbeatSlaStatus BulkHeartbeatSlaLedger::seal_session() noexcept {
  if (sealed_) {
    return BulkHeartbeatSlaStatus::Sealed;
  }
  sealed_ = true;
  state_ = State::Sealed;
  return BulkHeartbeatSlaStatus::Sealed;
}

BulkHeartbeatSlaStatus BulkHeartbeatSlaLedger::rearm(
    std::uint32_t new_transfer_tag, std::uint64_t now_ms) noexcept {
  if (!sealed_) {
    return BulkHeartbeatSlaStatus::SessionNotSealed;
  }
  if (have_last_time_ && now_ms < last_time_ms_) {
    failed_ = true;
    last_error_ = BulkHeartbeatSlaStatus::ClockRegression;
    evidence_.complete = false;
    return last_error_;
  }
  have_last_time_ = true;
  last_time_ms_ = now_ms;
  if (new_transfer_tag == 0U) {
    return BulkHeartbeatSlaStatus::InvalidConfiguration;
  }
  if (new_transfer_tag == evidence_.transfer_tag) {
    return BulkHeartbeatSlaStatus::TransferTagReuse;
  }

  clear_for_tag(new_transfer_tag, now_ms);
  return BulkHeartbeatSlaStatus::Rearmed;
}

bool BulkHeartbeatSlaLedger::note_time(std::uint64_t now_ms) noexcept {
  if (have_last_time_ && now_ms < last_time_ms_) {
    static_cast<void>(fail(BulkHeartbeatSlaStatus::ClockRegression));
    return false;
  }
  have_last_time_ = true;
  last_time_ms_ = now_ms;
  return true;
}

BulkHeartbeatSlaStatus BulkHeartbeatSlaLedger::fail(
    BulkHeartbeatSlaStatus reason) noexcept {
  failed_ = true;
  last_error_ = reason;
  evidence_.complete = false;
  return reason;
}

void BulkHeartbeatSlaLedger::clear_for_tag(
    std::uint32_t transfer_tag, std::uint64_t now_ms) noexcept {
  state_ = State::Idle;
  evidence_ = {};
  evidence_.transfer_tag = transfer_tag;
  have_baseline_ = false;
  baseline_ms_ = 0U;
  have_request_epoch_ = false;
  request_epoch_ms_ = 0U;
  have_last_heartbeat_ = false;
  last_heartbeat_ms_ = 0U;
  have_last_time_ = true;
  last_time_ms_ = now_ms;
  failed_ = false;
  sealed_ = false;
  last_error_ = BulkHeartbeatSlaStatus::InvalidState;
}

}  // namespace vc_lora
