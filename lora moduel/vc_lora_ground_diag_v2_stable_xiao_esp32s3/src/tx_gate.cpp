#include "vc_lora/tx_gate.hpp"

namespace vc_lora {

bool TxGate::authorize_vehicle(VehicleTddState state, TxClass tx_class,
                               LinkDiagnostics& diagnostics) noexcept {
  const bool allowed =
      (tx_class == TxClass::DownlinkData &&
       state == VehicleTddState::DownlinkSend) ||
      (tx_class == TxClass::GrantControl &&
       state == VehicleTddState::SendUlGrant);
  if (!allowed) {
    ++diagnostics.tx_gate_violation;
    if (state == VehicleTddState::UplinkReceive) {
      ++diagnostics.tx_during_rx_window_count;
    }
  }
  return allowed;
}

bool TxGate::authorize_ground(GroundTddState state, TxClass tx_class,
                              bool valid_grant, std::uint64_t now_ms,
                              std::uint64_t window_deadline_ms,
                              LinkDiagnostics& diagnostics,
                              bool continuing_started_transaction) noexcept {
  bool allowed = false;
  if (valid_grant) {
    if (tx_class == TxClass::UplinkData) {
      allowed = state == GroundTddState::UplinkSend &&
                (now_ms < window_deadline_ms ||
                 continuing_started_transaction);
    } else if (tx_class == TxClass::DoneControl) {
      allowed = state == GroundTddState::SendUlDone;
    }
  }

  if (!allowed) {
    ++diagnostics.tx_gate_violation;
    if (!valid_grant && (tx_class == TxClass::UplinkData ||
                         tx_class == TxClass::DoneControl)) {
      ++diagnostics.ground_tx_without_valid_grant;
    }
  }
  return allowed;
}

}  // namespace vc_lora
