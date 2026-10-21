#pragma once

#include <cstddef>
#include <cstdint>

#include "vc_lora/bulk_data_codec.hpp"
#include "vc_lora/mavlink_scheduler.hpp"
#include "vc_lora/tdd_types.hpp"

namespace vc_lora {

// Result of one sender-lease operation. Ready exposes fragment zero; an
// accepted head returns FragmentAccepted and exposes fragment one. Only an
// accepted tail may return FrameCommitted and consume the scheduler source.
enum class BulkDataTxLeaseStatus : std::uint8_t {
  Ready = 0U,
  Empty,
  NoEligibleFrame,
  Busy,
  FragmentRejected,
  FragmentAccepted,
  FrameCommitted,
  Sealed,
  Rearmed,
  Aborted,
  NoLease,
  InvalidConfiguration,
  InvalidFrame,
  UnsupportedFrame,
  OrdinalOverflow,
  BlockedByActiveFrame,
  SessionNotSealed,
  TransferTagReuse,
  SchedulerFailure,
  Latched,
};

// Read-only, sender-owned completion accounting for one negotiated transfer
// tag. The product adapter may copy these fields into its terminal evidence,
// but cannot assert completion on the sender's behalf. Counts advance only
// after the cached tail and the complete scheduler source are both accepted.
struct BulkDataTxLeaseEvidence final {
  std::uint32_t transfer_tag{0U};
  std::uint32_t parameter_count{0U};
  std::uint32_t parameter_fragment_count{0U};
  std::uint32_t raw_parameter_bytes{0U};
  std::uint32_t heartbeat_count{0U};
  bool owner_sealed{false};
};

// Fixed-storage transaction adapter between MavlinkFrameScheduler and the
// two-fragment VCB1 encoder. A source frame remains under one scheduler peek
// lease until its cached tail is accepted or abort() rejects that peek.
// Physical fragment rejection never calls complete_send(), so the same 32
// bytes remain available for a byte-identical retry.
class BulkDataTxLease final {
 public:
  // transfer_tag may be zero only for a global owner created before session
  // negotiation. Keep that owner inactive, then seal_session() and rearm() it
  // with the negotiated nonzero tag before the first begin().
  BulkDataTxLease(MavlinkFrameScheduler& scheduler,
                  std::uint32_t transfer_tag,
                  std::uint32_t first_wire_ordinal = 0U) noexcept;
  BulkDataTxLease(const BulkDataTxLease&) = delete;
  BulkDataTxLease& operator=(const BulkDataTxLease&) = delete;
  BulkDataTxLease(BulkDataTxLease&&) = delete;
  BulkDataTxLease& operator=(BulkDataTxLease&&) = delete;

  // The product owner is long-lived/global. Destruction deliberately has no
  // scheduler side effect; a shorter-lived owner must call abort() explicitly
  // so rejection happens at a controlled transport boundary.
  ~BulkDataTxLease() = default;

  [[nodiscard]] BulkDataTxLeaseStatus begin() noexcept;
  [[nodiscard]] BulkDataTxLeaseStatus complete_fragment(
      TxResult result) noexcept;
  [[nodiscard]] BulkDataTxLeaseStatus abort() noexcept;

  // A negotiated download session must be sealed explicitly before its
  // inactive owner can be reused. rearm() also requires the scheduler to have
  // no active peek, resets the wire ordinal to zero, and rejects zero or the
  // immediately previous transfer tag. The negotiation owner must provide a
  // tag that is fresh for the peer's complete transfer-tag lifetime.
  [[nodiscard]] BulkDataTxLeaseStatus seal_session() noexcept;
  [[nodiscard]] BulkDataTxLeaseStatus rearm(
      std::uint32_t new_transfer_tag) noexcept;

  [[nodiscard]] const BulkDataFragment* current_fragment() const noexcept;
  [[nodiscard]] constexpr bool active() const noexcept { return active_; }
  [[nodiscard]] constexpr bool latched() const noexcept { return latched_; }
  [[nodiscard]] constexpr BulkDataTxLeaseStatus last_error() const noexcept {
    return last_error_;
  }
  [[nodiscard]] constexpr std::size_t current_fragment_index() const noexcept {
    return active_ ? fragment_index_ : 0U;
  }
  [[nodiscard]] constexpr std::size_t source_frame_size() const noexcept {
    return active_ ? source_frame_size_ : 0U;
  }
  [[nodiscard]] constexpr std::uint32_t next_wire_ordinal() const noexcept {
    return next_wire_ordinal_;
  }
  [[nodiscard]] constexpr std::uint32_t transfer_tag() const noexcept {
    return transfer_tag_;
  }
  [[nodiscard]] constexpr BulkDataTxLeaseEvidence completion_evidence()
      const noexcept {
    return completion_evidence_;
  }

 private:
  [[nodiscard]] BulkDataTxLeaseStatus latch(
      BulkDataTxLeaseStatus error) noexcept;
  void release_lease() noexcept;
  void reset_completion_evidence() noexcept;

  MavlinkFrameScheduler& scheduler_;
  std::uint32_t transfer_tag_{0U};
  std::uint32_t next_wire_ordinal_{0U};
  BulkDataTxLeaseEvidence completion_evidence_{};
  EncodedBulkDataFrame cached_{};
  std::size_t fragment_index_{0U};
  std::size_t source_frame_size_{0U};
  std::uint32_t source_message_id_{0U};
  BulkDataTxLeaseStatus last_error_{BulkDataTxLeaseStatus::NoLease};
  bool active_{false};
  bool latched_{false};
};

}  // namespace vc_lora
