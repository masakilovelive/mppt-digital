#include "fake_arduino_test_api.hpp"
#if defined(RESERVATION_TEST_VEHICLE)
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
#include "phase6/vc_lora_phase6_bridge.hpp"
#include <iostream>
#include <string>

using namespace vc_lora_phase6_firmware;
using namespace vc_lora;
using namespace vc_lora::experimental;
using Op=R19GrantReservationOpcode;
using Role=R19GrantReservationRole;
unsigned checks=0, failures=0;
void check(bool value,const char* name) {
  ++checks;if(!value){++failures;std::cerr<<"FAIL "<<name<<'\n';}
}
constexpr std::uint64_t nonce=0x521B000000000001ULL;
R19GrantReservationWireMessage command(Op op,Role role) {
  R19GrantReservationWireMessage m{};
  m.opcode=op;m.role=role;m.reader_session=17;m.slot_nonce=nonce;
  if(op!=Op::HelloRequest){m.boot_id=r19_grant_reservation_boot_id;m.usb_epoch=Serial.txLossEpoch();}
  return m;
}
void send(const R19GrantReservationWireMessage& m) {
  MavlinkFrame f{};
  check(r19_encode_grant_reservation_frame(m,false,1,f),"encode command");
  check(r19_intercept_grant_reservation_usb_frame(f),"private consumed");
}
void drain() {
  for(unsigned n=0;n<40 && r19_grant_reservation.peek_reply()!=nullptr;++n)
    (void)r19_service_grant_reservation_reply();
  check(r19_grant_reservation.peek_reply()==nullptr &&
      !r19_grant_reservation_reply_fault,"whole66 reply completion");
}
int main(int argc,char** argv) {
  const std::string test=argc>1?argv[1]:"positive";
  fake_arduino::reset_platform();fake_arduino::set_pin_input_level(D8,HIGH);
  Serial.set_plugged(true);Serial.set_endpoint_ready(true);setup_bridge();
  check(bridge_ready&&!runtime_fail_closed,"setup actual bridge");
#if defined(RESERVATION_TEST_VEHICLE)
  // This fixture supplies the prior validated local-clock witness; all new
  // reservation commands, actual issued TDD action and writer/tail callbacks
  // below use the real bridge, not a replacement protocol implementation.
  r19_vehicle_usb_clock_seen=true;
  send(command(Op::HelloRequest,Role::Vehicle));
  if(test=="usb-prefix-expired") {
    const auto before=Serial.tx_bytes().size();Serial.set_tx_checked_accept_limit(16);
    check(r19_service_grant_reservation_reply(),"partial private writer active");
    check(Serial.tx_bytes().size()==before+16,"prefix accepted once");
    fake_arduino::advance_time_ms(106);r19_tick_grant_reservation();
    (void)r19_service_grant_reservation_reply();
    check(r19_grant_reservation_reply_fault && runtime_fail_closed &&
        Serial.tx_bytes().size()==before+16,"106ms expiry no replay no radio");
    std::cout<<"USB prefix checks="<<checks<<" failures="<<failures<<'\n';return failures?1:0;
  }
  drain();
  auto prepare=command(Op::PrepareVehicle,Role::Vehicle);
  prepare.grant_session=640;prepare.grant_cycle=1;
  send(prepare);
  const auto begin=monotonic_now_ms();tdd_controller.reset(640,2,begin);
  fake_arduino::advance_time_ms(3000);
  r19_observe_e220_aux(monotonic_now_ms());
  (void)tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
  fake_arduino::advance_time_ms(16);
  r19_observe_e220_aux(monotonic_now_ms());
  (void)tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
  fake_arduino::advance_time_ms(1);
  r19_observe_e220_aux(monotonic_now_ms());
  const auto action=tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
  const auto before=e220_serial.normal_tx_bytes().size();
  check(action.type==LinkActionType::SendGrant,"real TDD issued Grant");
  check(r19_hold_generated_grant(action,monotonic_now_ms()),"issued Grant intercepted");
  check(r19_reserved_grant_action_valid && e220_writer_arbiter.write_active() &&
      e220_serial.normal_tx_bytes().size()==before,"exclusive real lease zero radio bytes");
  const auto generation=standard_radio_writer_lease.writer_generation;
  drain();
  auto bind=command(Op::BindPeerVehicle,Role::Vehicle);
  bind.boot_id=111;bind.usb_epoch=19;bind.grant_session=640;bind.grant_cycle=2;
  bind.action_token=action.token;bind.writer_generation=generation;send(bind);
  if(test=="epoch-after-prepare") {
    Serial.simulate_tx_loss();r19_tick_grant_reservation();
    (void)r19_service_reserved_grant(monotonic_now_ms());
    check(runtime_fail_closed && e220_serial.normal_tx_bytes().size()==before,
        "epoch change invalidates exact held action before any RF bytes");
  } else if(test=="hold-expired") {
    fake_arduino::advance_time_ms(750);r19_tick_grant_reservation();
    check(runtime_fail_closed && e220_serial.normal_tx_bytes().size()==before,
        "750ms hold is exclusive and cannot emit after expiry");
  } else {
    auto release=command(Op::ReleaseGrant,Role::Vehicle);
    release.grant_session=640;release.grant_cycle=2;release.action_token=action.token;
    release.writer_generation=generation;release.device_ms=123;send(release);
    check(r19_service_reserved_grant(monotonic_now_ms()),"one exact retained action released");
    check(!runtime_fail_closed && r19_reserved_grant_uart_accepted &&
        standard_radio_writer_lease.writer_generation==generation &&
        e220_serial.normal_tx_bytes().size()==before+32,"same lease exact32 UART accepted");
    const auto written=monotonic_now_ms();
    fake_arduino::set_pin_input_level(D8,LOW);observe_radio_completion(monotonic_now_ms());
    fake_arduino::advance_time_ms(530);fake_arduino::set_pin_input_level(D8,HIGH);
    observe_radio_completion(monotonic_now_ms());fake_arduino::advance_time_ms(20);
    observe_radio_completion(monotonic_now_ms());
    check(!runtime_fail_closed && retained_standard_vehicle_grant_tail.valid &&
        r19_grant_reservation.snapshot().tail_ms==written+550 &&
        r19_grant_reservation.peek_reply()!=nullptr,"TailReady only actual550ms physical completion");
    drain();
    const auto count=e220_serial.normal_tx_bytes().size();
    (void)r19_service_reserved_grant(monotonic_now_ms());
    check(e220_serial.normal_tx_bytes().size()==count,"no duplicate release");
  }
#else
  // Prior ARM/post-ARM product witness is independently tested in existing
  // readiness suites. Initialize that boundary as a fixture here.
  check(r19_grant_reservation.initialize(Role::Ground,r19_grant_reservation_boot_id,
      Serial.txLossEpoch(),monotonic_now_ms()),"ground initialization fixture");
  send(command(Op::HelloRequest,Role::Ground));
  check(r19_grant_reservation.peek_reply()==nullptr,"Hello waits real RF baseline callback");
  TddControlMessage grant{};grant.type=ControlType::UlGrant;grant.session_id=640;grant.cycle_id=1;
  r19_observe_ground_grant(grant,ControlDisposition::Accepted,monotonic_now_ms());drain();
  auto bind=command(Op::BindGround,Role::Ground);bind.grant_session=640;bind.grant_cycle=2;
  bind.action_token=7;bind.writer_generation=9;send(bind);
  bind.opcode=Op::BindPeerGround;bind.boot_id=111;bind.usb_epoch=19;send(bind);drain();
  MavlinkFrame request{};const std::array<std::uint8_t,2> payload{{1,1}};
  check(encode_mavlink_v2(99,255,190,21,payload.data(),payload.size(),request),"PARAM fixture");
  r19_have_ground_usb_heartbeat_commit=true;r19_last_ground_usb_heartbeat_commit_ms=monotonic_now_ms();
  const auto t0=monotonic_now_ms();
  if(test=="stale-loop-ms") {
    fake_arduino::advance_time_ms(1);r19_tick_grant_reservation();
    const auto actual_receipt=monotonic_now_ms();
    (void)r19_intercept_ground_usb_frame(request,t0);
    check(!runtime_fail_closed&&r19_product_route_selected&&
        r19_ground_adapter->t0_ms()==actual_receipt,
        "whole request timestamps actual callback not older loop sample");
    std::cout<<"stale loop checks="<<checks<<" failures="<<failures<<'\n';return failures?1:0;
  }
  if(test=="busy-at-request") {
    radio_busy=true;
    (void)r19_intercept_ground_usb_frame(request,t0);
    check(runtime_fail_closed&&!r19_product_route_selected,
        "revalidate actual request boundary, not only prior Bind");
    std::cout<<"busy request checks="<<checks<<" failures="<<failures<<'\n';return failures?1:0;
  }
  check(r19_intercept_ground_usb_frame(request,t0)&&r19_product_route_selected&&
      !runtime_fail_closed,"actual adapter Held after Bound");drain();
  if(test=="duplicate-request") {
    (void)r19_intercept_ground_usb_frame(request,t0);
    check(runtime_fail_closed&&r19_ground_adapter->t0_ms()==t0,
        "duplicate whole request cannot reset owner deadline");
    std::cout<<"duplicate request checks="<<checks<<" failures="<<failures<<'\n';return failures?1:0;
  }
  fake_arduino::advance_time_ms(test=="grant-late"?501:50);
  if(test=="grant-late") {
    r19_service_high_speed_product_route(monotonic_now_ms());
    check(runtime_fail_closed && r19_pre_negotiation_fallback_count==0 &&
        r19_ground_adapter->t0_ms()==t0,"original500 preserved no slow fallback promotion");
  } else {
    grant.cycle_id=2;r19_observe_ground_grant(grant,ControlDisposition::Accepted,monotonic_now_ms());
    fake_arduino::advance_time_ms(100);r19_service_high_speed_product_route(monotonic_now_ms());
    check(r19_radio_session==nullptr&&!runtime_fail_closed,"no VCBN from Grant alone");
    auto tail=command(Op::TailPermit,Role::Ground);tail.boot_id=111;tail.usb_epoch=19;
    tail.grant_session=640;tail.grant_cycle=2;tail.action_token=7;tail.writer_generation=9;
    tail.device_ms=777;send(tail);
    fake_arduino::advance_time_ms(99);r19_service_high_speed_product_route(monotonic_now_ms());
    check(r19_radio_session==nullptr,"second causal100ms guard");
    fake_arduino::advance_time_ms(1);r19_service_high_speed_product_route(monotonic_now_ms());
    // The real high-speed radio session also needs its independent AUX-HIGH
    // admission interval. It is not bypassed by the host tail permit.
    fake_arduino::advance_time_ms(16);r19_service_high_speed_product_route(monotonic_now_ms());
    check(r19_ground_adapter->t0_ms()==t0,"request origin immutable after tail permit");
    check(!runtime_fail_closed && r19_radio_session!=nullptr &&
        r19_grant_reservation_negotiation_started,"actual VCBN writer accepts after both guards");
    if(failures) {
      std::cerr<<"ground debug runtime="<<runtime_fail_closed<<" session="<<(r19_radio_session!=nullptr)
        <<" started="<<r19_grant_reservation_negotiation_started<<" adapter="
        <<static_cast<unsigned>(r19_ground_adapter->diagnostics().adapter_status)
        <<" resstate="<<static_cast<unsigned>(r19_grant_reservation.state())
        <<" reason="<<static_cast<unsigned>(r19_grant_reservation.snapshot().reason)<<'\n';
    }
  }
#endif
  std::cout<<"reservation actual bridge case="<<test<<" checks="<<checks<<" failures="<<failures<<'\n';
  return failures?1:0;
}
