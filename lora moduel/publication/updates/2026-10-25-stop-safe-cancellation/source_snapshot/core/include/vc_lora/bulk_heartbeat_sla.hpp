#pragma once

#include <cstdint>

namespace vc_lora {

struct BulkHeartbeatSlaTiming final {
  static constexpr std::uint64_t heartbeat_deadline_ms = 2'500U;
  static constexpr std::uint64_t completion_deadline_ms = 30'000U;
};

struct BulkHeartbeatSlaEvidence final {
  std::uint32_t transfer_tag{0U};
  std::uint32_t heartbeat_count{0U};
  std::uint32_t last_heartbeat_request_id{0U};
  // Absolute event epochs are retained so a terminal producer can cross-bind
  // the SLA ledger to the independent Ground USB host-commit owner.  The
  // elapsed field alone cannot detect two callers using different t0/t1 pairs.
  std::uint64_t request_started_ms{0U};
  std::uint64_t final_parameter_committed_ms{0U};
  std::uint32_t request_to_last_parameter_ms{0U};
  std::uint32_t first_heartbeat_gap_ms{0U};
  std::uint32_t max_heartbeat_gap_ms{0U};
  std::uint32_t post_heartbeat_gap_ms{0U};
  bool complete{false};
};

enum class BulkHeartbeatSlaStatus : std::uint8_t {
  BaselineCaptured = 0U,
  RequestStarted,
  HeartbeatAccepted,
  EvidenceReady,
  Sealed,
  Rearmed,
  InvalidConfiguration,
  InvalidState,
  MissingBaseline,
  MissingHeartbeat,
  HeartbeatDeadlineExceeded,
  CompletionDeadlineExceeded,
  PostCompleteData,
  ClockRegression,
  CounterOverflow,
  SessionNotSealed,
  TransferTagReuse,
  Latched,
};

// Owns the exact real-heartbeat timeline for one negotiated bulk transfer.
// The caller supplies timestamps only for complete, validated MAVLink #0
// frames and supplies t1 only after parameter index 931 is committed to USB.
class BulkHeartbeatSlaLedger final {
 public:
  explicit BulkHeartbeatSlaLedger(std::uint32_t transfer_tag) noexcept;
  BulkHeartbeatSlaLedger(const BulkHeartbeatSlaLedger&) = delete;
  BulkHeartbeatSlaLedger& operator=(const BulkHeartbeatSlaLedger&) = delete;
  BulkHeartbeatSlaLedger(BulkHeartbeatSlaLedger&&) = delete;
  BulkHeartbeatSlaLedger& operator=(BulkHeartbeatSlaLedger&&) = delete;

  [[nodiscard]] BulkHeartbeatSlaStatus capture_baseline(
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkHeartbeatSlaStatus start_request(
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkHeartbeatSlaStatus accept_heartbeat(
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkHeartbeatSlaStatus complete_final_parameter(
      std::uint64_t now_ms) noexcept;

  // An explicit seal is required before evidence storage can be reused. It is
  // also the abort boundary for a failed or partial session.
  [[nodiscard]] BulkHeartbeatSlaStatus seal_session() noexcept;
  [[nodiscard]] BulkHeartbeatSlaStatus rearm(
      std::uint32_t new_transfer_tag, std::uint64_t now_ms) noexcept;

  [[nodiscard]] constexpr const BulkHeartbeatSlaEvidence& evidence()
      const noexcept {
    return evidence_;
  }
  [[nodiscard]] constexpr bool fail_closed() const noexcept {
    return failed_;
  }
  [[nodiscard]] constexpr bool sealed() const noexcept { return sealed_; }
  [[nodiscard]] constexpr BulkHeartbeatSlaStatus last_error() const noexcept {
    return last_error_;
  }

 private:
  enum class State : std::uint8_t {
    Idle = 0U,
    BaselineReady,
    Active,
    Complete,
    Sealed,
  };

  [[nodiscard]] bool note_time(std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkHeartbeatSlaStatus fail(
      BulkHeartbeatSlaStatus reason) noexcept;
  void clear_for_tag(std::uint32_t transfer_tag,
                     std::uint64_t now_ms) noexcept;

  State state_{State::Idle};
  BulkHeartbeatSlaEvidence evidence_{};
  bool have_baseline_{false};
  std::uint64_t baseline_ms_{0U};
  bool have_request_epoch_{false};
  std::uint64_t request_epoch_ms_{0U};
  bool have_last_heartbeat_{false};
  std::uint64_t last_heartbeat_ms_{0U};
  bool have_last_time_{false};
  std::uint64_t last_time_ms_{0U};
  bool failed_{false};
  bool sealed_{false};
  BulkHeartbeatSlaStatus last_error_{BulkHeartbeatSlaStatus::InvalidState};
};

}  // namespace vc_lora
