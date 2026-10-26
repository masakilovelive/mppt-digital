#include "fake_arduino_test_api.hpp"
#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#define VC_LORA_R19_USB_READINESS_MODE 2
#define VC_LORA_R19_TIMED_PATH_DIAGNOSTICS 1
#define VC_LORA_R19_AUX_READINESS_DIAGNOSTICS 1
#define VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD 1
#define VC_LORA_R19_GRANT_DIAGNOSTICS 1
#define VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"
#include <array>
#include <iostream>

int main() {
  using namespace vc_lora_phase6_firmware;
  using namespace vc_lora;
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8,HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  setup_bridge();
  if (!bridge_ready || runtime_fail_closed || r19_ground_adapter==nullptr)
    return 2;
  const auto now=monotonic_now_ms();
  TddControlMessage baseline{};
  baseline.type=ControlType::UlGrant;
  baseline.session_id=7U;
  baseline.cycle_id=1U;
  r19_observe_ground_grant(baseline,ControlDisposition::Accepted,now);
  constexpr std::array<std::uint8_t,14U> raw{{
      253,2,0,0,99,255,190,21,0,0,1,1,213,7}};
  MavlinkFrame request{};
  if (validate_mavlink_frame(raw.data(),raw.size(),request)!=MavlinkParseStatus::FrameReady)
    return 2;
  r19_have_ground_usb_heartbeat_commit=true;
  r19_last_ground_usb_heartbeat_commit_ms=now;
  const auto radio_before=e220_serial.normal_tx_bytes().size();
  const bool consumed=r19_intercept_ground_usb_frame(request,now);
  const bool safe=consumed && !r19_product_route_selected && runtime_fail_closed &&
      e220_serial.normal_tx_bytes().size()==radio_before;
  std::cout << "reservation-unbound-real-bridge checks=1 failures="
            << (safe?0:1) << " product_route_selected=" << r19_product_route_selected
            << " runtime_fail_closed=" << runtime_fail_closed << '\n';
  return safe?0:1;
}
