#pragma once

#include <cstdint>

#include "vc_lora/link_diagnostics.hpp"
#include "vc_lora/tdd_types.hpp"

namespace vc_lora {

enum class VehicleTddState : std::uint8_t {
  DownlinkSend,
  DownlinkDrain,
  SendUlGrant,
  GrantDrain,
  UplinkGuard,
  UplinkReceive,
  ReturnGuard,
};

const char* vehicle_state_name(VehicleTddState state) noexcept;

class VehicleTddController {
 public:
  VehicleTddController(const TddConfig& config,
                       LinkDiagnostics& diagnostics) noexcept;

  void reset(std::uint16_t session_id, std::uint16_t initial_cycle,
             std::uint64_t now_ms) noexcept;
  LinkAction tick(const TddInput& input) noexcept;
  void complete_action(std::uint32_t token, TxResult result,
                       std::uint64_t now_ms,
                       std::uint16_t accepted_bytes = 0xFFFFU) noexcept;
  ControlDisposition on_control(const TddControlMessage& message,
                                std::uint64_t now_ms) noexcept;

  VehicleTddState state() const noexcept { return state_; }
  std::uint16_t session_id() const noexcept { return session_id_; }
  std::uint16_t cycle_id() const noexcept { return cycle_id_; }
  bool has_pending_action() const noexcept { return action_pending_; }
  bool radio_receive_window() const noexcept {
    return state_ == VehicleTddState::UplinkGuard ||
           state_ == VehicleTddState::UplinkReceive;
  }
  // Only a receive-timeout ReturnGuard may recover a delayed same-cycle
  // transaction.  ReturnGuard entered by a normal DONE/IDLE remains closed.
  bool late_uplink_recovery_window() const noexcept {
    return state_ == VehicleTddState::ReturnGuard &&
           late_uplink_recovery_open_;
  }
  bool note_return_guard_activity(std::uint64_t now_ms) noexcept;
  bool complete_late_uplink_terminal(std::uint64_t now_ms,
                                     ControlType type,
                                     bool payload_accepted) noexcept;
  bool discard_current_uplink(std::uint64_t now_ms) noexcept;

 private:
  void set_state(VehicleTddState state, std::uint64_t now_ms) noexcept;
  void update_aux(bool high, std::uint64_t now_ms) noexcept;
  bool aux_stable(std::uint64_t now_ms) const noexcept;
  bool tx_gap_elapsed(std::uint64_t now_ms) const noexcept;
  bool should_defer_grant_for_heartbeat(
      const TddInput& input) const noexcept;
  void reopen_heartbeat_tail(std::uint64_t now_ms,
                             bool deadline_missed) noexcept;
  LinkAction issue_data(std::uint16_t queued_bytes,
                        std::uint64_t now_ms,
                        bool heartbeat_tail = false) noexcept;
  LinkAction issue_grant(std::uint64_t now_ms) noexcept;

  TddConfig config_{};
  LinkDiagnostics* diagnostics_{nullptr};
  VehicleTddState state_{VehicleTddState::DownlinkSend};
  std::uint16_t session_id_{0};
  std::uint16_t cycle_id_{0};
  std::uint64_t state_entered_ms_{0};
  std::uint64_t uplink_guard_deadline_ms_{0};
  std::uint64_t return_guard_deadline_ms_{0};
  std::uint64_t aux_high_since_ms_{0};
  std::uint64_t action_issued_ms_{0};
  bool aux_was_high_{false};
  bool action_pending_{false};
  bool grant_sent_this_cycle_{false};
  bool has_accepted_tx_{false};
  bool heartbeat_tail_selected_{false};
  bool heartbeat_tail_started_{false};
  bool pending_heartbeat_tail_{false};
  bool late_uplink_recovery_open_{false};
  bool uplink_timeout_pending_{false};
  std::uint32_t pending_token_{0};
  std::uint32_t next_token_{1};
  LinkActionType pending_type_{LinkActionType::None};
  std::uint16_t pending_bytes_{0};
  std::uint64_t last_tx_accepted_ms_{0};
};

}  // namespace vc_lora
