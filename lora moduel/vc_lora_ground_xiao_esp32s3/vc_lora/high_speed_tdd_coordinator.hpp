#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/bulk_data_codec.hpp"
#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/tdd_control_codec.hpp"

namespace vc_lora {

// Pure, feature-gated coordination contract for a future Phase-6 adapter.
// It owns neither a session controller, a stream encoder/decoder, a lease,
// nor a UART/radio.  Production TDD code does not instantiate these classes.
using HighSpeedWireActionBytes = std::array<std::uint8_t, kTddControlFrameSize>;
using HighSpeedTerminalFragments = std::array<HighSpeedWireActionBytes, 8U>;

enum class HighSpeedActionType : std::uint8_t {
  None = 0U,
  SendNegotiationRequest,
  SendNegotiationResponse,
  SendPixhawkParameterRequest,
  SendBulkFragment,
  SendTerminalEvidence,
  OpenTerminalAckWindow,
};

struct HighSpeedAction final {
  HighSpeedActionType type{HighSpeedActionType::None};
  std::uint32_t token{0U};
  std::uint32_t writer_generation{0U};
  HighSpeedWireActionBytes bytes{};
  std::size_t size{0U};
};

// Evidence that a Grant was already accepted and physically drained by the
// standard TDD writer.  The high-speed coordinator adopts this evidence; it
// must never transmit a duplicate Grant of its own.
struct HighSpeedStandardGrantEvidence final {
  std::uint16_t grant_session_id{0U};
  std::uint16_t grant_cycle_id{0U};
  std::uint32_t writer_token{0U};
  std::uint32_t writer_generation{0U};
  bool accepted{false};
  bool physical_tail_complete{false};
  std::uint64_t completed_ms{0U};
};

// Ground cannot authenticate the remote Vehicle writer identity because VCB1
// intentionally carries no writer token. Instead, the local receive ledger
// assigns this one-shot identity to the complete final VCB1 record. The
// coordinator binds it before accepting tail evidence and never represents it
// as a remote-writer claim.
struct HighSpeedLocalRxRecordIdentity final {
  std::uint32_t transfer_tag{0U};
  std::uint32_t final_wire_ordinal{0U};
  std::uint32_t fragment_count{0U};
  std::uint32_t rx_record_token{0U};
  std::uint32_t rx_ledger_generation{0U};
};

struct HighSpeedTailDrainEvidence final {
  std::uint32_t action_token{0U};
  bool physical_tail_complete{false};
  std::uint64_t completed_ms{0U};
};

// The final VCB1 tail is correlated to the complete stream, not merely to its
// transfer tag. On Vehicle, writer_token/generation identify the accepted
// local TX action. VCB1 does not carry that identity over RF, so Ground uses a
// non-zero, locally generated RX-record token/generation from its demux/receive
// ledger; it never presents those fields as unverifiable remote evidence.
struct HighSpeedStreamTailEvidence final {
  std::uint32_t transfer_tag{0U};
  std::uint32_t final_wire_ordinal{0U};
  std::uint32_t fragment_count{0U};
  std::uint32_t writer_token{0U};
  std::uint32_t writer_generation{0U};
  bool physical_tail_complete{false};
  std::uint64_t completed_ms{0U};
};

enum class HighSpeedCoordinatorResult : std::uint8_t {
  NoAction = 0U,
  Ready,
  ActionReady,
  Accepted,
  RetryRetained,
  TailDrainAccepted,
  AwaitingPeer,
  BulkEnabled,
  TerminalWindowReady,
  SessionComplete,
  InvalidArgument,
  InvalidState,
  InvalidToken,
  InvalidWireRecord,
  EvidenceMismatch,
  GrantDeadlineExceeded,
  LeaseExpired,
  DirectionGuardIncomplete,
  TerminalWindowTimeout,
  ClockRegression,
  TokenExhausted,
  Latched,
};

enum class GroundHighSpeedTddState : std::uint8_t {
  Disabled = 0U,
  Idle,
  AwaitFreshGrant,
  RequestGuard,
  RequestReady,
  RequestDrain,
  AwaitResponse,
  BulkReceive,
  AwaitBulkTail,
  DirectionGuard,
  TerminalTransmit,
  AwaitTerminalPhysicalTail,
  AwaitTerminalCommit,
  Complete,
  FailClosed,
};

enum class VehicleHighSpeedTddState : std::uint8_t {
  Disabled = 0U,
  Idle,
  ResponseGuard,
  ResponseReady,
  ResponseDrain,
  PixhawkReady,
  AwaitPixhawkCommit,
  BulkTransmit,
  BulkActionReady,
  AwaitBulkTail,
  DirectionGuard,
  TerminalWindowReady,
  AwaitTerminalWindowCommit,
  AwaitTerminalAck,
  Complete,
  FailClosed,
};

class GroundHighSpeedTddCoordinator final {
 public:
  explicit GroundHighSpeedTddCoordinator(BulkSessionFeature feature) noexcept;
  GroundHighSpeedTddCoordinator(const GroundHighSpeedTddCoordinator&) = delete;
  GroundHighSpeedTddCoordinator& operator=(
      const GroundHighSpeedTddCoordinator&) = delete;
  GroundHighSpeedTddCoordinator(GroundHighSpeedTddCoordinator&&) = delete;
  GroundHighSpeedTddCoordinator& operator=(GroundHighSpeedTddCoordinator&&) =
      delete;

  [[nodiscard]] HighSpeedCoordinatorResult begin_parameter_request(
      BulkSessionResult owner_result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult stage_fresh_grant(
      BulkSessionResult owner_result, const BulkNegotiationFrame& request,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedAction poll(std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult complete_action(
      std::uint32_t token, TxResult result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult confirm_request_commit(
      BulkSessionResult owner_result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult observe_action_tail_drained(
      const HighSpeedTailDrainEvidence& evidence,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult on_negotiation_response(
      BulkSessionResult owner_result, std::uint32_t transfer_tag,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult complete_bulk_receive(
      BulkSessionResult owner_result,
      const GroundBulkCompletionEvidence& evidence,
      const HighSpeedTerminalFragments& terminal_fragments,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult bind_final_bulk_rx_record(
      const HighSpeedLocalRxRecordIdentity& identity,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult observe_bulk_tail_drained(
      const HighSpeedStreamTailEvidence& evidence,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult open_terminal_window(
      BulkSessionResult owner_result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult confirm_terminal_commit(
      BulkSessionResult owner_result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult tick(std::uint64_t now_ms) noexcept;

  [[nodiscard]] constexpr GroundHighSpeedTddState state() const noexcept {
    return state_;
  }
  [[nodiscard]] constexpr bool fail_closed() const noexcept {
    return state_ == GroundHighSpeedTddState::FailClosed;
  }
  [[nodiscard]] constexpr std::uint64_t t0_ms() const noexcept {
    return t0_ms_;
  }
  [[nodiscard]] constexpr std::uint64_t t1_ms() const noexcept {
    return t1_ms_;
  }
  [[nodiscard]] constexpr HighSpeedCoordinatorResult last_error()
      const noexcept {
    return last_error_;
  }

 private:
  [[nodiscard]] bool note_time(std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult check_deadlines(
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult fail(
      HighSpeedCoordinatorResult reason) noexcept;
  [[nodiscard]] HighSpeedAction issue(HighSpeedActionType type,
                                      const std::uint8_t* bytes,
                                      std::size_t size) noexcept;

  BulkSessionFeature feature_{BulkSessionFeature::Disabled};
  GroundHighSpeedTddState state_{GroundHighSpeedTddState::Disabled};
  BulkNegotiationFrame request_{};
  HighSpeedTerminalFragments terminal_fragments_{};
  std::size_t terminal_fragment_index_{0U};
  std::uint32_t transfer_tag_{0U};
  std::uint64_t t0_ms_{0U};
  std::uint64_t t1_ms_{0U};
  std::uint64_t request_guard_started_ms_{0U};
  std::uint64_t bulk_receive_started_ms_{0U};
  std::uint64_t accepted_action_ms_{0U};
  std::uint64_t stream_tail_ms_{0U};
  std::uint64_t terminal_window_ms_{0U};
  std::uint32_t accepted_request_token_{0U};
  std::uint32_t expected_final_wire_ordinal_{0U};
  std::uint32_t expected_fragment_count_{0U};
  std::uint32_t accepted_terminal_tail_token_{0U};
  std::uint64_t accepted_terminal_tail_ms_{0U};
  bool request_committed_{false};
  bool request_tail_drained_{false};
  bool bulk_tail_observed_{false};
  HighSpeedLocalRxRecordIdentity bound_bulk_rx_identity_{};
  bool bulk_rx_identity_bound_{false};
  bool terminal_commit_confirmed_{false};
  HighSpeedAction active_action_{};
  bool action_in_flight_{false};
  std::uint32_t next_token_{1U};
  std::uint32_t next_writer_generation_{1U};
  bool have_last_time_{false};
  std::uint64_t last_time_ms_{0U};
  HighSpeedCoordinatorResult last_error_{HighSpeedCoordinatorResult::NoAction};
};

class VehicleHighSpeedTddCoordinator final {
 public:
  explicit VehicleHighSpeedTddCoordinator(BulkSessionFeature feature) noexcept;
  VehicleHighSpeedTddCoordinator(const VehicleHighSpeedTddCoordinator&) =
      delete;
  VehicleHighSpeedTddCoordinator& operator=(
      const VehicleHighSpeedTddCoordinator&) = delete;
  VehicleHighSpeedTddCoordinator(VehicleHighSpeedTddCoordinator&&) = delete;
  VehicleHighSpeedTddCoordinator& operator=(VehicleHighSpeedTddCoordinator&&) =
      delete;

  [[nodiscard]] HighSpeedCoordinatorResult
  adopt_retained_grant_on_terminal_request(
      BulkSessionResult grant_owner_result,
      BulkSessionResult request_owner_result,
      const HighSpeedWireActionBytes& grant_frame,
      const HighSpeedStandardGrantEvidence& evidence,
      const BulkNegotiationFrame& request,
      const BulkNegotiationFrame& response,
      std::uint32_t transfer_tag,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult stage_pixhawk_request(
      BulkSessionResult owner_result, const MavlinkFrame& request,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult confirm_pixhawk_request(
      BulkSessionResult owner_result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult stage_bulk_fragment(
      const BulkDataFragment& fragment, std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult complete_bulk_downlink(
      BulkSessionResult owner_result,
      const VehicleBulkCompletionEvidence& evidence,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult observe_bulk_tail_drained(
      const HighSpeedStreamTailEvidence& evidence,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedAction poll(std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult complete_action(
      std::uint32_t token, TxResult result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult observe_action_tail_drained(
      const HighSpeedTailDrainEvidence& evidence,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult confirm_terminal_window(
      BulkSessionResult owner_result, std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult confirm_terminal_ack(
      BulkSessionResult owner_result, std::uint32_t transfer_tag,
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult tick(std::uint64_t now_ms) noexcept;

  [[nodiscard]] constexpr VehicleHighSpeedTddState state() const noexcept {
    return state_;
  }
  [[nodiscard]] constexpr bool fail_closed() const noexcept {
    return state_ == VehicleHighSpeedTddState::FailClosed;
  }
  [[nodiscard]] constexpr std::uint64_t retained_grant_tail_ms()
      const noexcept {
    return retained_grant_tail_ms_;
  }
  [[nodiscard]] constexpr std::uint64_t terminal_window_ms() const noexcept {
    return terminal_window_ms_;
  }
  [[nodiscard]] constexpr HighSpeedCoordinatorResult last_error()
      const noexcept {
    return last_error_;
  }

 private:
  [[nodiscard]] bool note_time(std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult check_deadlines(
      std::uint64_t now_ms) noexcept;
  [[nodiscard]] HighSpeedCoordinatorResult fail(
      HighSpeedCoordinatorResult reason) noexcept;
  [[nodiscard]] HighSpeedAction issue(HighSpeedActionType type,
                                      const std::uint8_t* bytes,
                                      std::size_t size) noexcept;

  BulkSessionFeature feature_{BulkSessionFeature::Disabled};
  VehicleHighSpeedTddState state_{VehicleHighSpeedTddState::Disabled};
  BulkNegotiationFrame response_{};
  MavlinkFrame pixhawk_request_{};
  BulkDataFragment bulk_fragment_{};
  BulkDataFragmentKind staged_bulk_kind_{BulkDataFragmentKind::ParameterHead};
  BulkDataFragmentKind active_bulk_head_kind_{
      BulkDataFragmentKind::ParameterHead};
  bool pixhawk_request_staged_{false};
  bool response_tail_drained_{false};
  bool bulk_frame_active_{false};
  std::uint16_t grant_session_{0U};
  std::uint16_t grant_cycle_{0U};
  std::uint32_t transfer_tag_{0U};
  std::uint32_t next_bulk_wire_ordinal_{0U};
  std::uint32_t accepted_parameter_count_{0U};
  std::uint32_t accepted_parameter_fragment_count_{0U};
  std::uint32_t accepted_raw_parameter_bytes_{0U};
  std::uint32_t accepted_heartbeat_count_{0U};
  std::uint32_t accepted_tail_token_{0U};
  std::uint32_t last_bulk_action_token_{0U};
  std::uint32_t last_bulk_writer_generation_{0U};
  std::uint64_t retained_grant_tail_ms_{0U};
  std::uint64_t negotiation_request_tail_ms_{0U};
  std::uint64_t lease_epoch_ms_{0U};
  std::uint64_t accepted_action_ms_{0U};
  std::uint64_t last_bulk_action_ms_{0U};
  std::uint64_t terminal_transition_ms_{0U};
  std::uint64_t stream_tail_ms_{0U};
  std::uint64_t terminal_window_ms_{0U};
  HighSpeedAction active_action_{};
  bool action_in_flight_{false};
  std::uint32_t next_token_{1U};
  std::uint32_t next_writer_generation_{1U};
  bool have_last_time_{false};
  std::uint64_t last_time_ms_{0U};
  HighSpeedCoordinatorResult last_error_{HighSpeedCoordinatorResult::NoAction};
};

static_assert(HighSpeedTerminalFragments{}.size() == 8U);
static_assert(sizeof(HighSpeedWireActionBytes) == kTddControlFrameSize);

}  // namespace vc_lora
