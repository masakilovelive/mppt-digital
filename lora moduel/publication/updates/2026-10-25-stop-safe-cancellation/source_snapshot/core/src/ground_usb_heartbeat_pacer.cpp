#include "vc_lora/ground_usb_heartbeat_pacer.hpp"

#include <algorithm>
#include <cstring>

namespace vc_lora {

GroundUsbHeartbeatPacer::GroundUsbHeartbeatPacer(
    const GroundUsbHeartbeatPacerConfig& config) noexcept
    : config_(config) {}

bool GroundUsbHeartbeatPacer::stale(
    const Entry& entry, std::uint64_t now_ms) const noexcept {
  return now_ms < entry.rf_received_ms ||
         now_ms - entry.rf_received_ms > config_.hard_max_age_ms;
}

bool GroundUsbHeartbeatPacer::same_wire(
    const MavlinkFrame& left, const MavlinkFrame& right) const noexcept {
  return left.size == right.size && left.size > 0U &&
         left.size <= left.bytes.size() &&
         std::memcmp(left.bytes.data(), right.bytes.data(), left.size) == 0;
}

bool GroundUsbHeartbeatPacer::duplicate_held_or_admitted(
    const MavlinkFrame& frame) const noexcept {
  for (std::size_t index = 0U; index < size_; ++index) {
    if (same_wire(entries_[index].frame, frame)) {
      return true;
    }
  }
  if (admitted_ && same_wire(admitted_entry_.frame, frame)) {
    return true;
  }
  return false;
}

bool GroundUsbHeartbeatPacer::duplicate_recently_emitted(
    const MavlinkFrame& frame, std::uint64_t now_ms) const noexcept {
  if (!have_last_emitted_frame_ ||
      !same_wire(last_emitted_frame_, frame)) {
    return false;
  }
  // Suppress a transport replay only inside the same hard-age window used by
  // held entries. Past that bound an identical wire image can legitimately be
  // the next frame after MAVLink's 8-bit sequence wraps.
  return now_ms < last_emitted_ms_ ||
         now_ms - last_emitted_ms_ <= config_.hard_max_age_ms;
}

void GroundUsbHeartbeatPacer::drop_front() noexcept {
  if (size_ == 0U) {
    return;
  }
  for (std::size_t index = 1U; index < size_; ++index) {
    entries_[index - 1U] = entries_[index];
  }
  entries_[size_ - 1U] = {};
  --size_;
}

void GroundUsbHeartbeatPacer::prune_supply(
    std::uint64_t now_ms) noexcept {
  std::size_t first_valid = 0U;
  while (first_valid < supply_count_ &&
         (now_ms < supply_times_[first_valid] ||
          now_ms - supply_times_[first_valid] > config_.supply_window_ms)) {
    ++first_valid;
  }
  if (first_valid == 0U) {
    return;
  }
  const std::size_t remaining = supply_count_ - first_valid;
  for (std::size_t index = 0U; index < remaining; ++index) {
    supply_times_[index] = supply_times_[first_valid + index];
  }
  for (std::size_t index = remaining; index < supply_count_; ++index) {
    supply_times_[index] = 0U;
  }
  supply_count_ = remaining;
}

void GroundUsbHeartbeatPacer::record_supply(
    std::uint64_t now_ms) noexcept {
  prune_supply(now_ms);
  if (supply_count_ == supply_times_.size()) {
    for (std::size_t index = 1U; index < supply_count_; ++index) {
      supply_times_[index - 1U] = supply_times_[index];
    }
    --supply_count_;
  }
  supply_times_[supply_count_++] = now_ms;
}

void GroundUsbHeartbeatPacer::expire(std::uint64_t now_ms) noexcept {
  while (size_ > 0U && !pending_ && stale(entries_[0U], now_ms)) {
    drop_front();
    ++diagnostics_.expired_heartbeats;
  }
}

GroundUsbHeartbeatIngestStatus GroundUsbHeartbeatPacer::ingest(
    const MavlinkFrame& frame, std::uint64_t rf_received_ms) noexcept {
  MavlinkFrame validated{};
  if (frame.size == 0U || frame.size > frame.bytes.size() ||
      validate_mavlink_frame(frame.bytes.data(), frame.size, validated) !=
          MavlinkParseStatus::FrameReady) {
    ++diagnostics_.invalid_heartbeats;
    return GroundUsbHeartbeatIngestStatus::Invalid;
  }
  if (validated.message_id != 0U) {
    return GroundUsbHeartbeatIngestStatus::PassThrough;
  }
  if (validated.system_id != config_.target_system_id ||
      validated.component_id != config_.target_component_id) {
    ++diagnostics_.foreign_heartbeats_passthrough;
    return GroundUsbHeartbeatIngestStatus::PassThrough;
  }

  ++diagnostics_.valid_real_heartbeats;
  expire(rf_received_ms);
  if (duplicate_held_or_admitted(validated) ||
      duplicate_recently_emitted(validated, rf_received_ms)) {
    ++diagnostics_.duplicate_ingests;
    return GroundUsbHeartbeatIngestStatus::Held;
  }
  record_supply(rf_received_ms);

  Entry incoming{};
  incoming.frame = validated;
  incoming.rf_received_ms = rf_received_ms;
  if (size_ < entries_.size()) {
    entries_[size_++] = incoming;
    diagnostics_.max_fifo_depth =
        std::max(diagnostics_.max_fifo_depth, size_);
    return GroundUsbHeartbeatIngestStatus::Held;
  }

  // A leased head is immutable until completion. In that case discard the
  // oldest non-leased entry and retain the later real heartbeats. Otherwise
  // discard the oldest head. Both paths preserve FIFO order and the newest
  // fixed-capacity reserve without allocation.
  if (pending_) {
    for (std::size_t index = 2U; index < size_; ++index) {
      entries_[index - 1U] = entries_[index];
    }
    entries_[size_ - 1U] = incoming;
  } else {
    drop_front();
    entries_[size_++] = incoming;
  }
  ++diagnostics_.fifo_replacements;
  return GroundUsbHeartbeatIngestStatus::ReplacedOldest;
}

void GroundUsbHeartbeatPacer::set_usb_connected(
    bool connected, std::uint64_t now_ms) noexcept {
  if (connected != usb_connected_) {
    if (connected) {
      ++diagnostics_.usb_connect_events;
    } else {
      ++diagnostics_.usb_disconnect_events;
    }
  }
  usb_connected_ = connected;
  if (connected) {
    expire(now_ms);
  }
}

bool GroundUsbHeartbeatPacer::issue_lease(
    GroundUsbHeartbeatLease& lease) noexcept {
  if (pending_ || admitted_ || size_ == 0U) {
    return false;
  }
  pending_ = true;
  pending_token_ = next_token_++;
  if (pending_token_ == 0U) {
    pending_token_ = next_token_++;
  }
  lease.token = pending_token_;
  lease.frame = entries_[0U].frame;
  lease.rf_received_ms = entries_[0U].rf_received_ms;
  return true;
}

bool GroundUsbHeartbeatPacer::select_due(
    std::uint64_t now_ms, bool normal_frame_active,
    GroundUsbHeartbeatLease& lease) noexcept {
  expire(now_ms);
  if (!usb_connected_ || pending_ || admitted_ || size_ == 0U ||
      normal_frame_active) {
    return false;
  }
  const std::uint64_t completion_budget_ms =
      static_cast<std::uint64_t>(config_.loop_jitter_budget_ms) +
      static_cast<std::uint64_t>(config_.physical_write_budget_ms) +
      static_cast<std::uint64_t>(config_.transport_flush_budget_ms);
  const bool due =
      !have_last_usb_completion_ ||
      (now_ms >= last_usb_completion_ms_ &&
       now_ms - last_usb_completion_ms_ >= config_.soft_due_ms) ||
      (now_ms >= entries_[0U].rf_received_ms &&
       now_ms - entries_[0U].rf_received_ms >=
           (static_cast<std::uint64_t>(config_.hard_max_age_ms) >
                    completion_budget_ms
                ? static_cast<std::uint64_t>(config_.hard_max_age_ms) -
                      completion_budget_ms
                : 0U));
  return due && issue_lease(lease);
}

GroundUsbHeartbeatBarrierStatus
GroundUsbHeartbeatPacer::select_before_next_frame(
    std::uint64_t now_ms, GroundUsbHeartbeatLease& lease) noexcept {
  expire(now_ms);
  if (pending_) {
    ++diagnostics_.order_barrier_blocks;
    return GroundUsbHeartbeatBarrierStatus::BlockedByPendingEmit;
  }
  if (size_ == 0U) {
    return GroundUsbHeartbeatBarrierStatus::Clear;
  }
  if (admitted_) {
    ++diagnostics_.order_barrier_blocks;
    return GroundUsbHeartbeatBarrierStatus::BlockedByPendingEmit;
  }
  if (!usb_connected_) {
    diagnostics_.order_preservation_drops += size_;
    entries_ = {};
    size_ = 0U;
    return GroundUsbHeartbeatBarrierStatus::DroppedForOrder;
  }
  return issue_lease(lease)
             ? GroundUsbHeartbeatBarrierStatus::LeaseReady
             : GroundUsbHeartbeatBarrierStatus::BlockedByPendingEmit;
}

bool GroundUsbHeartbeatPacer::discard_for_order(
    std::uint64_t now_ms) noexcept {
  expire(now_ms);
  if (pending_) {
    ++diagnostics_.order_barrier_blocks;
    return false;
  }
  if (size_ == 0U) {
    return false;
  }
  diagnostics_.order_preservation_drops += size_;
  entries_ = {};
  size_ = 0U;
  return true;
}

bool GroundUsbHeartbeatPacer::mark_emit_admitted(
    std::uint32_t token) noexcept {
  if (!pending_ || admitted_ || size_ == 0U || token == 0U ||
      token != pending_token_) {
    ++diagnostics_.invalid_admissions;
    return false;
  }
  admitted_entry_ = entries_[0U];
  admitted_token_ = pending_token_;
  admitted_ = true;
  pending_ = false;
  pending_token_ = 0U;
  drop_front();
  ++diagnostics_.admitted_emits;
  return true;
}

bool GroundUsbHeartbeatPacer::abort_pending_emit(
    std::uint32_t token) noexcept {
  if (!pending_ || admitted_ || token == 0U || token != pending_token_) {
    ++diagnostics_.invalid_pending_aborts;
    return false;
  }
  pending_ = false;
  pending_token_ = 0U;
  ++diagnostics_.aborted_pending_emits;
  return true;
}

bool GroundUsbHeartbeatPacer::complete_emit(
    std::uint32_t token, TxResult result,
    std::uint64_t completed_ms) noexcept {
  const bool completing_admitted =
      admitted_ && token != 0U && token == admitted_token_;
  const bool completing_pending =
      pending_ && token != 0U && token == pending_token_;
  if (!completing_admitted && !completing_pending) {
    ++diagnostics_.duplicate_completions;
    return false;
  }

  Entry completed_entry{};
  if (completing_admitted) {
    completed_entry = admitted_entry_;
    admitted_ = false;
    admitted_token_ = 0U;
    admitted_entry_ = {};
  } else {
    if (size_ == 0U) {
      ++diagnostics_.duplicate_completions;
      return false;
    }
    completed_entry = entries_[0U];
    pending_ = false;
    pending_token_ = 0U;
  }
  if (result != TxResult::Accepted || !usb_connected_) {
    ++diagnostics_.rejected_emits;
    return true;
  }
  if (stale(completed_entry, completed_ms)) {
    if (completing_pending) {
      drop_front();
    }
    ++diagnostics_.expired_heartbeats;
    return true;
  }

  const std::uint64_t hold_age =
      completed_ms - completed_entry.rf_received_ms;
  diagnostics_.max_hold_age_ms =
      std::max(diagnostics_.max_hold_age_ms, hold_age);
  if (have_last_usb_completion_ &&
      completed_ms >= last_usb_completion_ms_) {
    diagnostics_.max_usb_gap_ms = std::max(
        diagnostics_.max_usb_gap_ms,
        completed_ms - last_usb_completion_ms_);
  }
  have_last_usb_completion_ = true;
  last_usb_completion_ms_ = completed_ms;
  have_last_emitted_frame_ = true;
  last_emitted_frame_ = completed_entry.frame;
  last_emitted_ms_ = completed_ms;
  if (completing_pending) {
    drop_front();
  }
  ++diagnostics_.emitted_heartbeats;
  return true;
}

void GroundUsbHeartbeatPacer::observe_usb_egress(
    std::size_t queued_bytes, bool current_frame_active,
    bool writer_available) noexcept {
  usb_backlog_bytes_ = queued_bytes;
  usb_current_frame_active_ = current_frame_active;
  usb_writer_available_ = writer_available;
  diagnostics_.max_observed_usb_backlog_bytes = std::max(
      diagnostics_.max_observed_usb_backlog_bytes, queued_bytes);
}

bool GroundUsbHeartbeatPacer::guarantee_available(
    std::uint64_t now_ms) noexcept {
  prune_supply(now_ms);
  const bool supply_sufficient =
      config_.minimum_supply_frames > 0U &&
      supply_count_ >= config_.minimum_supply_frames;
  if (!supply_sufficient) {
    if (!supply_shortage_active_) {
      ++diagnostics_.supply_shortage_events;
      supply_shortage_active_ = true;
    }
  } else {
    supply_shortage_active_ = false;
  }
  const bool backlog_clear = usb_backlog_bytes_ == 0U;
  if (!backlog_clear) {
    if (!usb_backlog_active_) {
      ++diagnostics_.usb_backlog_non_guaranteed_events;
      usb_backlog_active_ = true;
    }
  } else {
    usb_backlog_active_ = false;
  }
  if (!usb_writer_available_) {
    if (!usb_writer_unavailable_active_) {
      ++diagnostics_.usb_writer_unavailable_events;
      usb_writer_unavailable_active_ = true;
    }
  } else {
    usb_writer_unavailable_active_ = false;
  }
  // usb_current_frame_active_ is intentionally allowed: the 49-ms maximum
  // non-preemptible frame is already included in the 2455-ms host proof.
  (void)usb_current_frame_active_;
  return usb_connected_ && supply_sufficient && backlog_clear &&
         usb_writer_available_;
}

}  // namespace vc_lora
