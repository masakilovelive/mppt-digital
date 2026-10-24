#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/bulk_negotiation_codec.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_types.hpp"

namespace vc_lora {

// This controller is an inert Phase-6 primitive. The accepted standard TDD
// path does not instantiate it. A future adapter must explicitly select
// Enabled and provide physical-write completion events before any VCBN/VCB1
// transition can occur.
enum class BulkSessionFeature : std::uint8_t {
  Disabled = 0U,
  Enabled,
};

struct BulkSessionTiming final {
  // A fresh Grant which arrives later cannot satisfy the 30-second candidate
  // budget. The boundary is inclusive: t0+500 is valid, t0+501 is not.
  static constexpr std::uint64_t grant_wait_budget_ms = 500U;
  // The hard lease includes negotiation. Ground starts at accepted #21 t0;
  // Vehicle starts when a canonical terminal VCBN request is accepted.
  // The boundary is inclusive and +1 ms fails closed.
  static constexpr std::uint64_t hard_lease_ms = 28'000U;
  static constexpr std::uint64_t direction_guard_ms = 100U;
  static constexpr std::uint64_t terminal_ack_timeout_ms = 350U;
  // Once the final VCTA record has been accepted locally, completion requires
  // the correlated peer VCRC rather than AUX alone.  This inclusive budget
  // covers the 100-ms direction guard, the fixed-profile 550-ms E220 service
  // floor, and a 650-ms receive margin.  It is deliberately separate from the
  // 350-ms terminal-window budget so an unfinished VCTA sequence is not given
  // the longer peer-proof allowance.
  static constexpr std::uint64_t peer_completion_receipt_timeout_ms = 1300U;
  // A completed local stream may not wait forever for its physical tail,
  // direction guard, or peer-window commit.  The inclusive 450-ms budget is
  // the existing 100-ms direction guard plus the 350-ms terminal budget.
  static constexpr std::uint64_t terminal_transition_timeout_ms =
      direction_guard_ms + terminal_ack_timeout_ms;
};

struct BulkSessionAccounting final {
  static constexpr std::uint32_t parameter_count = 932U;
  static constexpr std::uint32_t parameter_fragment_count = 1864U;
  static constexpr std::uint32_t raw_parameter_bytes = 34'484U;
  static constexpr std::uint32_t heartbeat_deadline_ms = 2'500U;
  static constexpr std::uint32_t completion_deadline_ms = 30'000U;
};

// These snapshots must be produced by the active same-tag receiver/sender;
// they are not caller convenience booleans. A controller accepts completion
// only when every fixed-corpus field and the negotiated transfer tag match.
struct GroundBulkCompletionEvidence final {
  std::uint32_t transfer_tag{0U};
  std::uint32_t parameter_count{0U};
  std::uint32_t parameter_fragment_count{0U};
  std::uint32_t raw_parameter_bytes{0U};
  std::uint32_t heartbeat_count{0U};
  std::uint32_t first_heartbeat_gap_ms{0U};
  std::uint32_t max_heartbeat_gap_ms{0U};
  std::uint32_t post_heartbeat_gap_ms{0U};
  bool stream_complete{false};
  bool final_parameter_usb_committed{false};
};

struct VehicleBulkCompletionEvidence final {
  std::uint32_t transfer_tag{0U};
  std::uint32_t parameter_count{0U};
  std::uint32_t parameter_fragment_count{0U};
  std::uint32_t raw_parameter_bytes{0U};
  std::uint32_t heartbeat_count{0U};
  bool owner_sealed{false};
};

// Core-side semantic form of a fully decoded VCTA record. The experimental
// wire reassembler remains outside core; its consumer must populate every
// field from validated record bytes rather than copying local expectations.
struct BulkSessionTerminalEvidence final {
  BulkNegotiationIdentity identity{};
  std::uint32_t transfer_tag{0U};
  std::uint32_t parameter_count{0U};
  std::uint32_t parameter_fragment_count{0U};
  std::uint32_t raw_parameter_bytes{0U};
  std::uint32_t heartbeat_count{0U};
  std::uint32_t first_heartbeat_gap_ms{0U};
  std::uint32_t max_heartbeat_gap_ms{0U};
  std::uint32_t post_heartbeat_gap_ms{0U};
  bool ground_stream_complete{false};
  bool final_parameter_usb_committed{false};
};

struct BulkSessionTerminalWindowEvidence final {
  bool final_tail_drained{false};
  std::uint64_t final_tail_drained_ms{0U};
  bool direction_guard_complete{false};
  std::uint64_t direction_guard_completed_ms{0U};
};

enum class BulkSessionResult : std::uint8_t {
  NoAction = 0U,
  FeatureDisabled,
  PassThrough,
  NotHighSpeedReady,
  GrantBaselineCaptured,
  ParameterRequestHeld,
  BusyHold,
  GrantArmed,
  NegotiationRequestReady,
  NegotiationRequestCommitted,
  NegotiationResponseReady,
  NegotiationResponseCommitted,
  BulkReceiveEnabled,
  BulkDownlinkEnabled,
  TerminalEvidenceReady,
  TerminalWindowOpened,
  TerminalAckCommitted,
  RetryRetained,
  SessionComplete,
  Rearmed,
  InvalidConfiguration,
  InvalidArgument,
  InvalidMavlink,
  InvalidState,
  StaleGrant,
  GrantDeadlineExceeded,
  PartialNegotiationRecord,
  InvalidNegotiationRecord,
  WrongGrantIdentity,
  PeerRejected,
  ReplayDetected,
  IdentityReuse,
  LeaseExpired,
  CompletionEvidenceMismatch,
  TerminalEvidenceMismatch,
  TerminalWindowEvidenceMismatch,
  TerminalWindowTimeout,
  TerminalAckTimeout,
  DecoderIncomplete,
  SenderIncomplete,
  ClockRegression,
  Latched,
};

enum class GroundBulkSessionState : std::uint8_t {
  Disabled = 0U,
  Standard,
  AwaitFreshGrant,
  RequestReady,
  AwaitResponse,
  BulkReceive,
  TerminalEvidenceReady,
  TerminalAckReady,
  Complete,
  FailClosed,
};

enum class VehicleBulkSessionState : std::uint8_t {
  Disabled = 0U,
  AwaitGrant,
  AwaitRequest,
  ResponseReady,
  PixhawkRequestReady,
  BulkDownlink,
  AwaitTerminalWindow,
  AwaitTerminalAck,
  Complete,
  FailClosed,
};

struct GroundBulkSessionConfig final {
  BulkSessionFeature feature{BulkSessionFeature::Disabled};
  std::uint32_t ground_boot_id{0U};
  std::uint16_t ground_session_id{0U};
  std::uint16_t request_sequence{0U};
  std::uint64_t ground_nonce{0U};
};

struct VehicleBulkSessionConfig final {
  BulkSessionFeature feature{BulkSessionFeature::Disabled};
  std::uint32_t vehicle_boot_id{0U};
  std::uint16_t lease_sequence{0U};
  std::uint64_t vehicle_challenge_nonce{0U};
  std::uint8_t mavlink_sequence{0U};
  std::uint8_t mavlink_system_id{0U};
  std::uint8_t mavlink_component_id{0U};
};

// Ground owns the #21 interception and receive-side activation contract. It
// never emits radio/TDD actions; a feature-gated adapter supplies already
// accepted Grant events and exact physical-write completion results.
class GroundBulkSessionController final {
 public:
  explicit GroundBulkSessionController(
      const GroundBulkSessionConfig& config) noexcept;
  GroundBulkSessionController(const GroundBulkSessionController&) = delete;
  GroundBulkSessionController& operator=(
      const GroundBulkSessionController&) = delete;
  GroundBulkSessionController(GroundBulkSessionController&&) = delete;
  GroundBulkSessionController& operator=(GroundBulkSessionController&&) =
      delete;

  // Called for Grants already accepted by the standard controller before t0.
  // It establishes the watermark needed to prove that the negotiation Grant
  // is fresh. Old/duplicate observations in Standard are ignored.
  [[nodiscard]] BulkSessionResult observe_standard_grant(
      std::uint16_t session_id, std::uint16_t cycle_id,
      std::uint64_t now_ms) noexcept;

  // Revalidates complete MAVLink bytes. A valid #21 is retained at t0 and all
  // later GCS uplink frames receive BusyHold until success or explicit rearm.
  [[nodiscard]] BulkSessionResult on_ground_usb_frame(
      const MavlinkFrame& frame, std::uint64_t now_ms) noexcept;

  [[nodiscard]] BulkSessionResult on_fresh_grant(
      std::uint16_t session_id, std::uint16_t cycle_id,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult complete_request_tx(
      TxResult result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult on_negotiation_response(
      const std::uint8_t* record, std::size_t size,
      std::uint64_t now_ms) noexcept;

  // decoder_complete must come from a same-tag BulkDataStreamDecoder which
  // has accepted the exact expected corpus. The decoder is not owned here.
  [[nodiscard]] BulkSessionResult complete_bulk_receive(
      const GroundBulkCompletionEvidence& evidence,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult open_terminal_ack_window(
      const BulkSessionTerminalWindowEvidence& evidence,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult complete_terminal_ack_tx(
      TxResult result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult tick(std::uint64_t now_ms) noexcept;

  // Explicit operator action is the only path out of Complete/FailClosed.
  // Both sequence and nonce must be fresh. Rearm deliberately clears the
  // Grant watermark, requiring a new standard Grant observation before #21.
  [[nodiscard]] BulkSessionResult rearm(
      std::uint16_t new_request_sequence, std::uint64_t new_ground_nonce,
      std::uint64_t now_ms) noexcept;

  [[nodiscard]] const BulkNegotiationFrame* pending_request_record()
      const noexcept;
  [[nodiscard]] const BulkNegotiationFrame* committed_request_record()
      const noexcept;
  [[nodiscard]] const BulkSessionTerminalEvidence* terminal_evidence()
      const noexcept;
  [[nodiscard]] constexpr GroundBulkSessionState state() const noexcept {
    return state_;
  }
  [[nodiscard]] constexpr bool fail_closed() const noexcept {
    return state_ == GroundBulkSessionState::FailClosed;
  }
  [[nodiscard]] constexpr bool hold_standard_uplink() const noexcept {
    return held_request_;
  }
  [[nodiscard]] constexpr bool bulk_receive_enabled() const noexcept {
    return state_ == GroundBulkSessionState::BulkReceive;
  }
  [[nodiscard]] constexpr bool has_t0() const noexcept { return has_t0_; }
  [[nodiscard]] constexpr std::uint64_t t0_ms() const noexcept {
    return t0_ms_;
  }
  [[nodiscard]] constexpr bool has_lease_epoch() const noexcept {
    return has_t0_;
  }
  [[nodiscard]] constexpr std::uint64_t lease_epoch_ms() const noexcept {
    return t0_ms_;
  }
  [[nodiscard]] constexpr bool has_t1() const noexcept { return has_t1_; }
  [[nodiscard]] constexpr std::uint64_t t1_ms() const noexcept {
    return t1_ms_;
  }
  [[nodiscard]] constexpr std::uint32_t transfer_tag() const noexcept {
    return transfer_tag_;
  }
  [[nodiscard]] constexpr const BulkNegotiationIdentity& identity()
      const noexcept {
    return identity_;
  }
  [[nodiscard]] constexpr BulkSessionResult last_error() const noexcept {
    return last_error_;
  }

 private:
  [[nodiscard]] bool note_time(std::uint64_t now_ms) noexcept;
  [[nodiscard]] bool lease_expired(std::uint64_t now_ms) const noexcept;
  [[nodiscard]] BulkSessionResult fail(BulkSessionResult reason) noexcept;
  void clear_session() noexcept;

  BulkSessionFeature feature_{BulkSessionFeature::Disabled};
  GroundBulkSessionState state_{GroundBulkSessionState::Disabled};
  std::uint32_t ground_boot_id_{0U};
  std::uint16_t ground_session_id_{0U};
  std::uint16_t request_sequence_{0U};
  std::uint64_t ground_nonce_{0U};
  bool have_grant_watermark_{false};
  std::uint16_t grant_session_{0U};
  std::uint16_t grant_cycle_{0U};
  MavlinkFrame held_param_request_{};
  bool held_request_{false};
  BulkNegotiationFrame request_record_{};
  bool request_record_ready_{false};
  bool request_record_committed_{false};
  BulkNegotiationIdentity identity_{};
  std::uint32_t transfer_tag_{0U};
  BulkSessionTerminalEvidence terminal_evidence_{};
  bool terminal_evidence_ready_{false};
  bool has_terminal_wait_epoch_{false};
  std::uint64_t terminal_wait_epoch_ms_{0U};
  bool has_t0_{false};
  std::uint64_t t0_ms_{0U};
  bool has_t1_{false};
  std::uint64_t t1_ms_{0U};
  bool have_last_time_{false};
  std::uint64_t last_time_ms_{0U};
  BulkSessionResult last_error_{BulkSessionResult::NoAction};
};

// Vehicle owns terminal-request validation and the ordering fence between its
// VCBN response and the synthesized Pixhawk #21. No #21 or VCB1 permission is
// exposed until the adapter reports that the complete response was accepted.
class VehicleBulkSessionController final {
 public:
  explicit VehicleBulkSessionController(
      const VehicleBulkSessionConfig& config) noexcept;
  VehicleBulkSessionController(const VehicleBulkSessionController&) = delete;
  VehicleBulkSessionController& operator=(
      const VehicleBulkSessionController&) = delete;
  VehicleBulkSessionController(VehicleBulkSessionController&&) = delete;
  VehicleBulkSessionController& operator=(VehicleBulkSessionController&&) =
      delete;

  [[nodiscard]] BulkSessionResult arm_fresh_grant(
      std::uint16_t session_id, std::uint16_t cycle_id,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult on_terminal_request(
      const std::uint8_t* record, std::size_t size,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult complete_response_tx(
      TxResult result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult complete_pixhawk_request(
      TxResult result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult complete_bulk_downlink(
      const VehicleBulkCompletionEvidence& evidence,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult open_terminal_ack_window(
      const BulkSessionTerminalWindowEvidence& evidence,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult confirm_terminal_ack(
      const BulkSessionTerminalEvidence& evidence,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] BulkSessionResult tick(std::uint64_t now_ms) noexcept;

  // A failed or completed owner may be reused only with a fresh lease
  // sequence and challenge. Grant freshness and request-replay watermarks are
  // retained across rearm.
  [[nodiscard]] BulkSessionResult rearm(
      std::uint16_t new_lease_sequence,
      std::uint64_t new_vehicle_challenge_nonce,
      std::uint8_t new_mavlink_sequence,
      std::uint64_t now_ms) noexcept;

  [[nodiscard]] const BulkNegotiationFrame* pending_response_record()
      const noexcept;
  [[nodiscard]] const MavlinkFrame* pending_pixhawk_request() const noexcept;
  [[nodiscard]] constexpr VehicleBulkSessionState state() const noexcept {
    return state_;
  }
  [[nodiscard]] constexpr bool fail_closed() const noexcept {
    return state_ == VehicleBulkSessionState::FailClosed;
  }
  [[nodiscard]] constexpr bool pixhawk_request_ready() const noexcept {
    return state_ == VehicleBulkSessionState::PixhawkRequestReady;
  }
  [[nodiscard]] constexpr bool bulk_tx_enabled() const noexcept {
    return state_ == VehicleBulkSessionState::BulkDownlink;
  }
  [[nodiscard]] constexpr bool has_lease_epoch() const noexcept {
    return has_lease_epoch_;
  }
  [[nodiscard]] constexpr std::uint64_t lease_epoch_ms() const noexcept {
    return lease_epoch_ms_;
  }
  [[nodiscard]] constexpr std::uint32_t transfer_tag() const noexcept {
    return transfer_tag_;
  }
  [[nodiscard]] constexpr const BulkNegotiationIdentity& identity()
      const noexcept {
    return identity_;
  }
  [[nodiscard]] constexpr BulkSessionResult last_error() const noexcept {
    return last_error_;
  }

 private:
  [[nodiscard]] bool note_time(std::uint64_t now_ms) noexcept;
  [[nodiscard]] bool lease_expired(std::uint64_t now_ms) const noexcept;
  [[nodiscard]] BulkSessionResult fail(BulkSessionResult reason) noexcept;
  void clear_session() noexcept;

  BulkSessionFeature feature_{BulkSessionFeature::Disabled};
  VehicleBulkSessionState state_{VehicleBulkSessionState::Disabled};
  std::uint32_t vehicle_boot_id_{0U};
  std::uint16_t lease_sequence_{0U};
  std::uint64_t vehicle_challenge_nonce_{0U};
  std::uint8_t mavlink_sequence_{0U};
  std::uint8_t mavlink_system_id_{0U};
  std::uint8_t mavlink_component_id_{0U};
  bool have_grant_watermark_{false};
  std::uint16_t last_grant_session_{0U};
  std::uint16_t last_grant_cycle_{0U};
  std::uint16_t active_grant_session_{0U};
  std::uint16_t active_grant_cycle_{0U};
  BulkNegotiationFrame request_record_{};
  bool request_record_ready_{false};
  BulkNegotiationFrame response_record_{};
  bool response_record_ready_{false};
  MavlinkFrame pixhawk_request_{};
  bool pixhawk_request_valid_{false};
  BulkNegotiationIdentity identity_{};
  std::uint32_t transfer_tag_{0U};
  std::uint32_t active_request_tag_{0U};
  std::uint32_t last_committed_request_tag_{0U};
  std::uint32_t committed_heartbeat_count_{0U};
  bool has_local_completion_{false};
  std::uint64_t local_completion_ms_{0U};
  bool has_terminal_wait_epoch_{false};
  std::uint64_t terminal_wait_epoch_ms_{0U};
  bool has_lease_epoch_{false};
  std::uint64_t lease_epoch_ms_{0U};
  bool have_last_time_{false};
  std::uint64_t last_time_ms_{0U};
  BulkSessionResult last_error_{BulkSessionResult::NoAction};
};

static_assert(BulkSessionTiming::grant_wait_budget_ms == 500U);
static_assert(BulkSessionTiming::hard_lease_ms == 28'000U);
static_assert(BulkSessionTiming::direction_guard_ms == 100U);
static_assert(BulkSessionTiming::terminal_transition_timeout_ms == 450U);
static_assert(BulkSessionTiming::terminal_ack_timeout_ms == 350U);
static_assert(BulkSessionTiming::peer_completion_receipt_timeout_ms == 1300U);
static_assert(BulkSessionTiming::peer_completion_receipt_timeout_ms <
              BulkSessionAccounting::heartbeat_deadline_ms);
static_assert(BulkSessionAccounting::parameter_count == 932U);
static_assert(BulkSessionAccounting::parameter_fragment_count == 1864U);
static_assert(BulkSessionAccounting::raw_parameter_bytes == 34'484U);
static_assert(BulkSessionAccounting::heartbeat_deadline_ms == 2'500U);

}  // namespace vc_lora
