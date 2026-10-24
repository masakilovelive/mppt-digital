#include "fake_arduino_test_api.hpp"
#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#define VC_LORA_R19_USB_READINESS_MODE 2
#define VC_LORA_R19_TIMED_PATH_DIAGNOSTICS 1
#define VC_LORA_R19_AUX_READINESS_DIAGNOSTICS 1
#define VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD 1
#define VC_LORA_R19_GRANT_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"
#include <iostream>

int main() {
  using namespace vc_lora_phase6_firmware;
  using namespace vc_lora;
  using namespace vc_lora::experimental;
  unsigned checks=0U,failed=0U;
  const auto check=[&](bool value,const char* name){++checks;if(!value){++failed;std::cerr<<"FAIL "<<name<<'\n';}};
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8,HIGH);
  Serial.set_plugged(true);Serial.set_endpoint_ready(true);
  setup_bridge();
  check(bridge_ready&&!runtime_fail_closed&&r19_ground_adapter!=nullptr,"actual bridge setup");
  R19GrantDiagnosticSnapshot initial{};
  check(vc_lora_r19_grant_diagnostic_record.try_snapshot(initial)&&initial.valid_header()&&!initial.failure_latched(),"sameboot JTAG record initialized");
  const auto start=monotonic_now_ms();
  TddControlMessage grant{};grant.type=ControlType::UlGrant;grant.session_id=7U;grant.cycle_id=1U;
  r19_observe_ground_grant(grant,ControlDisposition::Accepted,start);
  MavlinkFrame frame{};const std::array<std::uint8_t,2U> payload{{1U,1U}};
  check(encode_mavlink_v2(1U,255U,190U,21U,payload.data(),payload.size(),frame),"request fixture");
  r19_have_ground_usb_heartbeat_commit=true;
  r19_last_ground_usb_heartbeat_commit_ms=start;
  const auto usb_bytes_before=Serial.tx_bytes().size();
  check(r19_intercept_ground_usb_frame(frame,start)&&r19_product_route_selected&&!runtime_fail_closed,"actual interception holds request");
  R19GrantDiagnosticSnapshot held{};
  check(vc_lora_r19_grant_diagnostic_record.try_snapshot(held)&&held.latest.request_origin_ms==start&&(held.latest.validity_flags&12U)==12U,"request and waitentry timestamp retained");
  // Preserve this original global-failure regression as the unsafe-epoch
  // case. Only the new clean pre-negotiation case may fall back to R18.
  Serial.simulate_tx_loss();
  fake_arduino::advance_time_ms(501U);
  r19_service_high_speed_product_route(monotonic_now_ms());
  R19GrantDiagnosticSnapshot stopped{};
  check(runtime_fail_closed&&!bridge_ready,"unchanged500ms contract still stops product path");
  check(vc_lora_r19_grant_diagnostic_record.try_snapshot(stopped)&&stopped.failure_latched(),"actual bridge freezes first adapter failure");
  check(stopped.first_failure.owner_last_error==static_cast<std::uint32_t>(BulkSessionResult::GrantDeadlineExceeded),"owner detailed deadline reason retained");
  check(stopped.first_failure.coordinator_last_error==static_cast<std::uint32_t>(HighSpeedCoordinatorResult::GrantDeadlineExceeded),"coordinator detailed deadline reason retained");
  check(stopped.first_failure.observed_ms-start==501U&&stopped.first_failure.request_origin_ms==start,"sameMCU501ms interval exact");
  check(Serial.tx_bytes().size()==usb_bytes_before,"JTAG hooks emit no debug USB bytes");
  fake_arduino::advance_time_ms(5000U);grant.cycle_id=2U;
  r19_observe_ground_grant(grant,ControlDisposition::Accepted,monotonic_now_ms());
  R19GrantDiagnosticSnapshot after{};
  check(vc_lora_r19_grant_diagnostic_record.try_snapshot(after)&&after.sequence==stopped.sequence&&after.first_failure.source_line==stopped.first_failure.source_line,"late Grant cannot overwrite firstfailure");
  std::cout<<"R19_GRANT_BRIDGE_HOOKS checks="<<checks<<" failed="<<failed<<'\n';
  return failed?1:0;
}
