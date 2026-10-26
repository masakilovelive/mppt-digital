#include "fake_arduino_test_api.hpp"
#if defined(AGREEMENT_CAPABILITY_VEHICLE)
#define VC_LORA_PHASE6_VEHICLE 1
#else
#define VC_LORA_PHASE6_GROUND 1
#endif
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#define VC_LORA_R19_USB_READINESS_MODE 2
#define VC_LORA_R19_TIMED_PATH_DIAGNOSTICS 1
#define VC_LORA_R19_AUX_READINESS_DIAGNOSTICS 1
#define VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD 1
#define VC_LORA_R19_GRANT_DIAGNOSTICS 1
#define VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS 1
#define VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS 1
#define VC_LORA_R19_GRANT_AGREEMENT_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"
#include <iostream>
int main() {
  using namespace vc_lora_phase6_firmware;
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true); Serial.set_endpoint_ready(true);
  setup_bridge();
  // This marker only binds the compiled wire-v3 capability. It is never an
  // assertion that a reservation, RF transfer or terminal abort succeeded.
  const bool okay = bridge_ready && !runtime_fail_closed &&
      sizeof(vc_lora_r19_grant_agreement_capability) == 4U &&
      vc_lora_r19_grant_agreement_capability == 0x52313903U;
  std::cout << "agreement compile-capability marker " << (okay ? "PASS" : "FAIL") << '\n';
  return okay ? 0 : 1;
}
