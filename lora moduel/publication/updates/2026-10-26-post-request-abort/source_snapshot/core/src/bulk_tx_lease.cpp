#include "vc_lora/bulk_tx_lease.hpp"

#include <limits>

namespace vc_lora {
namespace {

BulkDataTxLeaseStatus map_encode_failure(
    BulkDataWireStatus status) noexcept {
  switch (status) {
    case BulkDataWireStatus::InvalidTransferTag:
      return BulkDataTxLeaseStatus::InvalidConfiguration;
    case BulkDataWireStatus::InvalidMavlink:
      return BulkDataTxLeaseStatus::InvalidFrame;
    case BulkDataWireStatus::UnsupportedFrame:
      return BulkDataTxLeaseStatus::UnsupportedFrame;
    case BulkDataWireStatus::OrdinalOverflow:
      return BulkDataTxLeaseStatus::OrdinalOverflow;
    default:
      return BulkDataTxLeaseStatus::InvalidFrame;
  }
}

}  // namespace

BulkDataTxLease::BulkDataTxLease(MavlinkFrameScheduler& scheduler,
                                 std::uint32_t transfer_tag,
                                 std::uint32_t first_wire_ordinal) noexcept
    : scheduler_(scheduler),
      transfer_tag_(transfer_tag),
      next_wire_ordinal_(first_wire_ordinal) {
  reset_completion_evidence();
}

BulkDataTxLeaseStatus BulkDataTxLease::begin() noexcept {
  if (latched_) {
    return BulkDataTxLeaseStatus::Latched;
  }
  if (active_) {
    return BulkDataTxLeaseStatus::Busy;
  }
  if (transfer_tag_ == 0U) {
    return latch(BulkDataTxLeaseStatus::InvalidConfiguration);
  }
  constexpr std::uint32_t kLargestFirstOrdinal =
      static_cast<std::uint32_t>(
          std::numeric_limits<std::uint16_t>::max()) -
      1U;
  if (next_wire_ordinal_ > kLargestFirstOrdinal) {
    return latch(BulkDataTxLeaseStatus::OrdinalOverflow);
  }

  MavlinkFrame source{};
  std::size_t source_size = 0U;
  const MavlinkBulkPeekStatus peek_status = scheduler_.peek_bulk_frame(
      source.bytes.data(), source.bytes.size(), source_size);
  switch (peek_status) {
    case MavlinkBulkPeekStatus::Empty:
      return BulkDataTxLeaseStatus::Empty;
    case MavlinkBulkPeekStatus::NoEligibleFrame:
      return BulkDataTxLeaseStatus::NoEligibleFrame;
    case MavlinkBulkPeekStatus::BlockedByActiveFrame:
      return latch(BulkDataTxLeaseStatus::BlockedByActiveFrame);
    case MavlinkBulkPeekStatus::InvalidArgument:
      return latch(BulkDataTxLeaseStatus::SchedulerFailure);
    case MavlinkBulkPeekStatus::FrameReady:
      break;
  }
  source.size = source_size;

  EncodedBulkDataFrame candidate{};
  const BulkDataWireStatus encoded = encode_bulk_data_frame(
      source, transfer_tag_, static_cast<std::uint16_t>(next_wire_ordinal_),
      candidate);
  if (encoded != BulkDataWireStatus::FrameReady ||
      candidate.fragment_count != candidate.fragments.size()) {
    const BulkDataTxLeaseStatus failure = map_encode_failure(encoded);
    if (!scheduler_.complete_send(TxResult::Rejected, source_size)) {
      return latch(BulkDataTxLeaseStatus::SchedulerFailure);
    }
    return latch(failure);
  }

  cached_ = candidate;
  fragment_index_ = 0U;
  source_frame_size_ = source_size;
  // encode_bulk_data_frame accepts exactly unsigned MAVLink2 PARAM_VALUE
  // (37 bytes) or HEARTBEAT (21 bytes), so the accepted canonical size is a
  // stable source-kind discriminator even though peek_bulk_frame publishes
  // raw bytes rather than decoded MavlinkFrame metadata.
  source_message_id_ = source_size == 37U ? 22U : 0U;
  active_ = true;
  return BulkDataTxLeaseStatus::Ready;
}

BulkDataTxLeaseStatus BulkDataTxLease::complete_fragment(
    TxResult result) noexcept {
  if (latched_) {
    return BulkDataTxLeaseStatus::Latched;
  }
  if (!active_ || fragment_index_ >= cached_.fragment_count) {
    return BulkDataTxLeaseStatus::NoLease;
  }
  if (result == TxResult::Rejected) {
    return BulkDataTxLeaseStatus::FragmentRejected;
  }

  ++next_wire_ordinal_;
  if (fragment_index_ == 0U) {
    fragment_index_ = 1U;
    return BulkDataTxLeaseStatus::FragmentAccepted;
  }

  const std::size_t committed_size = source_frame_size_;
  if (!scheduler_.complete_send(TxResult::Accepted, committed_size)) {
    return latch(BulkDataTxLeaseStatus::SchedulerFailure);
  }
  if (source_message_id_ == 22U) {
    ++completion_evidence_.parameter_count;
    completion_evidence_.parameter_fragment_count += 2U;
    completion_evidence_.raw_parameter_bytes += 37U;
  } else if (source_message_id_ == 0U) {
    ++completion_evidence_.heartbeat_count;
  }
  release_lease();
  return BulkDataTxLeaseStatus::FrameCommitted;
}

BulkDataTxLeaseStatus BulkDataTxLease::abort() noexcept {
  if (latched_) {
    return BulkDataTxLeaseStatus::Latched;
  }
  if (!active_) {
    return BulkDataTxLeaseStatus::NoLease;
  }
  if (!scheduler_.complete_send(TxResult::Rejected, source_frame_size_)) {
    return latch(BulkDataTxLeaseStatus::SchedulerFailure);
  }
  release_lease();
  reset_completion_evidence();
  // A possibly transmitted HEAD cannot be reused under the same transfer tag;
  // fallback continues through the untouched standard scheduler frame.
  latched_ = true;
  last_error_ = BulkDataTxLeaseStatus::Aborted;
  return BulkDataTxLeaseStatus::Aborted;
}

BulkDataTxLeaseStatus BulkDataTxLease::seal_session() noexcept {
  if (active_) {
    return BulkDataTxLeaseStatus::Busy;
  }
  if (latched_) {
    return BulkDataTxLeaseStatus::Latched;
  }
  release_lease();
  completion_evidence_.owner_sealed = true;
  last_error_ = BulkDataTxLeaseStatus::Sealed;
  latched_ = true;
  return BulkDataTxLeaseStatus::Sealed;
}

BulkDataTxLeaseStatus BulkDataTxLease::rearm(
    std::uint32_t new_transfer_tag) noexcept {
  if (active_) {
    return BulkDataTxLeaseStatus::Busy;
  }
  if (scheduler_.has_active_frame()) {
    return BulkDataTxLeaseStatus::BlockedByActiveFrame;
  }
  if (!latched_) {
    return BulkDataTxLeaseStatus::SessionNotSealed;
  }
  if (new_transfer_tag == 0U) {
    return BulkDataTxLeaseStatus::InvalidConfiguration;
  }
  if (new_transfer_tag == transfer_tag_) {
    return BulkDataTxLeaseStatus::TransferTagReuse;
  }

  release_lease();
  transfer_tag_ = new_transfer_tag;
  next_wire_ordinal_ = 0U;
  reset_completion_evidence();
  last_error_ = BulkDataTxLeaseStatus::NoLease;
  latched_ = false;
  return BulkDataTxLeaseStatus::Rearmed;
}

const BulkDataFragment* BulkDataTxLease::current_fragment() const noexcept {
  if (!active_ || fragment_index_ >= cached_.fragment_count) {
    return nullptr;
  }
  return &cached_.fragments[fragment_index_];
}

BulkDataTxLeaseStatus BulkDataTxLease::latch(
    BulkDataTxLeaseStatus error) noexcept {
  release_lease();
  last_error_ = error;
  latched_ = true;
  return error;
}

void BulkDataTxLease::release_lease() noexcept {
  cached_ = {};
  fragment_index_ = 0U;
  source_frame_size_ = 0U;
  source_message_id_ = 0U;
  active_ = false;
}

void BulkDataTxLease::reset_completion_evidence() noexcept {
  completion_evidence_ = {};
  completion_evidence_.transfer_tag = transfer_tag_;
}

}  // namespace vc_lora
