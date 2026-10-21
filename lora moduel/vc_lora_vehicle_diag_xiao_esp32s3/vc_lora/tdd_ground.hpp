#pragma once

#include <cstdint>

#include "vc_lora/link_diagnostics.hpp"
#include "vc_lora/tdd_types.hpp"

namespace vc_lora {

enum class GroundTddState : std::uint8_t {
  WaitGrant,
  UplinkGuard,
  UplinkSend,
  UplinkDrain,
  SendUlDone,
  DoneDrain,
};

const char* ground_state_name(GroundTddState state) noexcept;

class GroundTddController {
 public:
  GroundTddController(const TddConfig& config,
                      LinkDiagnostics& diagnostics) noexcept;

  void reset(std::uint64_t now_ms) noexcept;
  LinkAction tick(const TddInput& input) noexcept;
  void complete_action(std::uint32_t token, TxResult result,
                       std::uint64_t now_ms,
                       std::uint16_t accepted_bytes = 0xFFFFU) noexcept;
  ControlDisposition on_control(const TddControlMessage& message,
                                std::uint64_t now_ms) noexcept;

  GroundTddState state() const noexcept { return state_; }
  bool has_valid_grant() const noexcept { return lease_valid_; }
  bool has_session() const noexcept { return has_session_; }
  std::uint16_t session_id() const noexcept { return session_id_; }
  std::uint16_t cycle_id() const noexcept { return cycle_id_; }
  std::uint16_t granted_bytes() const noexcept { return granted_bytes_; }
  std::uint16_t actual_bytes() const noexcept { return actual_bytes_; }
  std::uint16_t transaction_target_bytes() const noexcept {
    return transaction_target_bytes_;
  }
  std::uint64_t window_deadline_ms() const noexcept {
    return window_deadline_ms_;
  }

 private:
  void set_state(GroundTddState state, std::uint64_t now_ms) noexcept;
  void update_aux(bool high, std::uint64_t now_ms) noexcept;
  bool aux_stable(std::uint64_t now_ms) const noexcept;
  bool tx_gap_elapsed(std::uint64_t now_ms) const noexcept;
  std::uint64_t estimated_tx_duration_ms(
      std::uint16_t bytes) const noexcept;
  bool payload_fits_window(std::uint64_t now_ms,
                           std::uint16_t queued_bytes,
                           std::uint16_t next_application_bytes,
                           std::uint16_t next_wire_bytes) const noexcept;
  LinkAction issue_data(std::uint16_t queued_bytes,
                        std::uint16_t next_application_bytes,
                        std::uint64_t now_ms) noexcept;
  LinkAction issue_done(std::uint64_t now_ms) noexcept;
  void accept_grant(const TddControlMessage& message,
                    std::uint64_t now_ms, bool new_session) noexcept;

  TddConfig config_{};
  LinkDiagnostics* diagnostics_{nullptr};
  GroundTddState state_{GroundTddState::WaitGrant};
  bool has_session_{false};
  bool has_cycle_{false};
  bool lease_valid_{false};
  bool lease_consumed_{false};
  bool send_idle_{false};
  bool aux_was_high_{false};
  bool action_pending_{false};
  bool has_accepted_tx_{false};
  std::uint16_t session_id_{0};
  std::uint16_t cycle_id_{0};
  std::uint16_t granted_bytes_{0};
  std::uint16_t actual_bytes_{0};
  std::uint16_t transaction_target_bytes_{0};
  bool implicit_frame_terminal_{false};
  std::uint64_t state_entered_ms_{0};
  std::uint64_t guard_deadline_ms_{0};
  std::uint64_t window_deadline_ms_{0};
  std::uint64_t aux_high_since_ms_{0};
  std::uint64_t action_issued_ms_{0};
  std::uint32_t pending_token_{0};
  std::uint32_t next_token_{1};
  LinkActionType pending_type_{LinkActionType::None};
  std::uint16_t pending_bytes_{0};
  std::uint64_t last_tx_accepted_ms_{0};
};

}  // namespace vc_lora
