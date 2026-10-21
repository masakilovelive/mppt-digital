#pragma once

#include <cstdint>

#include "vc_lora/link_diagnostics.hpp"
#include "vc_lora/tdd_ground.hpp"
#include "vc_lora/tdd_vehicle.hpp"

namespace vc_lora {

enum class TxClass : std::uint8_t {
  DownlinkData,
  UplinkData,
  GrantControl,
  DoneControl,
};

class TxGate {
 public:
  static bool authorize_vehicle(VehicleTddState state, TxClass tx_class,
                                LinkDiagnostics& diagnostics) noexcept;

  static bool authorize_ground(GroundTddState state, TxClass tx_class,
                               bool valid_grant, std::uint64_t now_ms,
                               std::uint64_t window_deadline_ms,
                               LinkDiagnostics& diagnostics) noexcept;
};

}  // namespace vc_lora
