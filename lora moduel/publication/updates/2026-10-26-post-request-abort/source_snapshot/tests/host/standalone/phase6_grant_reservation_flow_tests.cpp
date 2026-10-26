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
#if defined(RESERVATION_TEST_STOP)
#define VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS 1
#else
#define VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS 0
#endif
#include "phase6/vc_lora_phase6_bridge.hpp"
#include <iostream>
#include <string>

using namespace vc_lora_phase6_firmware;
using namespace vc_lora;
using namespace vc_lora::experimental;
using Op=R19GrantReservationOpcode;
using Role=R19GrantReservationRole;
unsigned checks=0, failures=0;
bool cancellation_mode=false;
void check(bool value,const char* name) {
  ++checks;if(!value){++failures;std::cerr<<"FAIL "<<name<<'\n';}
}
constexpr std::uint64_t nonce=0x521B000000000001ULL;
std::uint64_t active_nonce=nonce;
R19GrantReservationWireMessage command(Op op,Role role) {
  R19GrantReservationWireMessage m{};
  m.wire_version=VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS?2U:1U;
  m.opcode=op;m.role=role;m.reader_session=17;m.slot_nonce=active_nonce;
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
  cancellation_mode=test.rfind("cancel-",0)==0;
  fake_arduino::reset_platform();fake_arduino::set_pin_input_level(D8,HIGH);
  Serial.set_plugged(true);Serial.set_endpoint_ready(true);setup_bridge();
  check(bridge_ready&&!runtime_fail_closed,"setup actual bridge");
  if(test=="wrong-wire-version") {
    auto hello=command(Op::HelloRequest,
#if defined(RESERVATION_TEST_VEHICLE)
        Role::Vehicle
#else
        Role::Ground
#endif
    );
    hello.wire_version=VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS?1U:2U;
    const auto before=e220_serial.normal_tx_bytes().size();send(hello);
    check(runtime_fail_closed && e220_serial.normal_tx_bytes().size()==before,
        "legacy mode rejects v2 and explicit new mode rejects v1 before any RF");
    return failures?1:0;
  }
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
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
  if(test=="new-heartbeat-held154" || test=="new-heartbeat-diagnostic154" ||
     cancellation_mode) {
    fake_arduino::advance_time_ms(154);
    const std::array<std::uint8_t,9> payload{{0,0,0,0,2,3,0,4,3}};
    MavlinkFrame heartbeat{};
    check(encode_mavlink_v2(17,1,1,0,payload.data(),payload.size(),heartbeat),
        "new real Heartbeat encodes");
    for(std::size_t index=0;index<heartbeat.size;++index)
      (void)vehicle_scheduler.ingest_byte(heartbeat.bytes[index],monotonic_now_ms());
    const auto input=make_tdd_input(monotonic_now_ms());
    check(input.heartbeat_deadline_valid && input.heartbeat_deadline_ms==
        monotonic_now_ms()+2500,"new Heartbeat keeps absolute2500 deadline");
    (void)r19_service_reserved_grant(monotonic_now_ms());
    if(cancellation_mode) {
      const auto& stop=vc_lora_r19_grant_reservation_stop_record;
      check(!runtime_fail_closed && !r19_grant_reservation.failed() &&
          !r19_reserved_grant_action_valid && !e220_writer_arbiter.write_active() &&
          e220_serial.normal_tx_bytes().size()==before &&
          tdd_controller.cycle_id()==3 && stop.words[13]==15 && stop.words[15]==2 &&
          (stop.words[22]&0xE00U)==0xE00U,
          "new HB154 safely retires exact untransmitted old cycle/lease, not runtime fault");
      check(make_tdd_input(monotonic_now_ms()).inhibit_new_grant,
          "cancelled Grant cannot be replaced before both cancellation confirmations");
      drain();
      auto cancel=command(Op::CancelRequest,Role::Vehicle);
      cancel.grant_session=640;cancel.grant_cycle=2;cancel.action_token=action.token;
      cancel.writer_generation=generation;send(cancel);drain();
      auto peer=command(Op::CancelPeerConfirmed,Role::Vehicle);
      peer.boot_id=111;peer.usb_epoch=19;peer.grant_session=640;peer.grant_cycle=2;
      peer.action_token=action.token;peer.writer_generation=generation;peer.device_ms=123;
      send(peer);drain();
      if(test=="cancel-replay") {
        send(cancel);
        check(runtime_fail_closed && e220_serial.normal_tx_bytes().size()==before,
            "cancel replay never revives or writes the retired old action");
        return failures?1:0;
      }
      auto hello=command(Op::HelloRequest,Role::Vehicle);hello.slot_nonce=nonce+1;
      send(hello);drain();active_nonce=nonce+1;
      auto fresh_prepare=command(Op::PrepareVehicle,Role::Vehicle);
      fresh_prepare.grant_session=640;fresh_prepare.grant_cycle=1;send(fresh_prepare);
      check(r19_grant_reservation.awaiting_grant() && !runtime_fail_closed,
          "fresh nonce explicitly reparses without resetting original preparation clock");
      std::array<std::uint8_t,32> selected{};
      check(vehicle_scheduler.peek(selected.data(),selected.size())==heartbeat.size,
          "retained real HB is selected before any new Grant");
      auto hb_action=tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
      check(hb_action.type==LinkActionType::SendRadioData,"existing TDD selects real HB tail");
      process_action(hb_action,monotonic_now_ms());
      check(!runtime_fail_closed && e220_serial.normal_tx_bytes().size()>before,
          "HB physically uses a fresh data writer lease after old Grant was retired");
      fake_arduino::set_pin_input_level(D8,LOW);observe_radio_completion(monotonic_now_ms());
      fake_arduino::advance_time_ms(530);fake_arduino::set_pin_input_level(D8,HIGH);
      observe_radio_completion(monotonic_now_ms());fake_arduino::advance_time_ms(20);
      observe_radio_completion(monotonic_now_ms());
      check(monotonic_now_ms()<=input.heartbeat_deadline_ms,
          "real HB RF tail completes without extending its absolute2500 deadline");
      LinkAction new_action{};
      for(unsigned turn=0;turn<5 && new_action.type==LinkActionType::None;++turn) {
        fake_arduino::advance_time_ms(1);r19_observe_e220_aux(monotonic_now_ms());
        new_action=tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
      }
      check(new_action.type==LinkActionType::SendGrant &&
          new_action.control.cycle_id==3 && new_action.token>action.token,
          "fresh Grant has strictly new cycle and action token");
      check(r19_hold_generated_grant(new_action,monotonic_now_ms()) &&
          !runtime_fail_closed && standard_radio_writer_lease.writer_generation>generation,
          "reprepare owns a strictly fresh writer generation");
      drain();
      auto fresh_bind=command(Op::BindPeerVehicle,Role::Vehicle);
      fresh_bind.boot_id=111;fresh_bind.usb_epoch=19;fresh_bind.grant_session=640;
      fresh_bind.grant_cycle=3;fresh_bind.action_token=new_action.token;
      fresh_bind.writer_generation=standard_radio_writer_lease.writer_generation;send(fresh_bind);
      auto fresh_release=command(Op::ReleaseGrant,Role::Vehicle);
      fresh_release.grant_session=640;fresh_release.grant_cycle=3;
      fresh_release.action_token=new_action.token;fresh_release.writer_generation=fresh_bind.writer_generation;
      fresh_release.device_ms=1;send(fresh_release);
      const auto after_hb=e220_serial.normal_tx_bytes().size();
      (void)r19_service_reserved_grant(monotonic_now_ms());
      check(!runtime_fail_closed && r19_reserved_grant_uart_accepted &&
          e220_serial.normal_tx_bytes().size()==after_hb+32 && stop.words[13]==15,
          "only the fresh bound Grant is written exactly once after HB priority");
      std::cout<<"cancel integration checks="<<checks<<" failures="<<failures<<'\n';
      return failures?1:0;
    }
    if(test=="new-heartbeat-diagnostic154") {
      const auto& stop=vc_lora_r19_grant_reservation_stop_record;
      check(runtime_fail_closed && r19_grant_reservation.failed() &&
          e220_serial.normal_tx_bytes().size()==before && stop.words[15]==2 &&
          stop.words[16]==monotonic_now_ms() &&
          stop.words[18]==input.heartbeat_deadline_ms &&
          stop.words[20]==r19_grant_reservation.hold_deadline_ms() &&
          stop.words[23]==5050 && stop.words[24]==action.token &&
          stop.words[25]==generation && stop.words[26]==action.token &&
          stop.words[27]==generation && stop.words[28]==1 &&
          (stop.words[22]&R19GrantReservationStopSnapshot::release_requested)==0,
          "new Heartbeat conflict is immutable pre-release evidence, zero RF, no SLA weakening");
      const auto oldSequence=stop.words[1];
      fake_arduino::set_pin_input_level(D8,LOW);
      (void)r19_service_reserved_grant(monotonic_now_ms());
      check(stop.words[1]==oldSequence && stop.words[15]==2,
          "later AUX/reservation failure cannot overwrite initiating Heartbeat reason");
      std::cout<<"new-HB diagnostic checks="<<checks<<" failures="<<failures<<'\n';
      return failures?1:0;
    }
    check(!runtime_fail_closed && !r19_grant_reservation.failed() &&
        r19_reserved_grant_action_valid &&
        standard_radio_writer_lease.writer_generation==generation &&
        e220_serial.normal_tx_bytes().size()==before,
        "new Heartbeat154ms into unreleased hold is not automatic generic abort");
    std::cout<<"new-HB hold checks="<<checks<<" failures="<<failures<<'\n';
    return failures?1:0;
  }
  if(test.rfind("stop-",0)==0) {
    unsigned expected=0;
    if(test=="stop-aux"){fake_arduino::set_pin_input_level(D8,LOW);expected=3;}
    else if(test=="stop-lease"){e220_writer_arbiter={};expected=4;}
    else if(test=="stop-token"){++r19_reserved_grant_action.token;expected=6;}
    else if(test=="stop-generation"){++standard_radio_writer_lease.writer_generation;expected=7;}
    else if(test=="stop-busy"){radio_busy=true;expected=8;}
    else if(test=="stop-pending"){pending_radio_action.active=true;expected=9;}
    else if(test=="stop-tail"){standard_radio_writer_tail_pending=true;expected=10;}
    else if(test=="stop-reservation"){
      (void)r19_grant_reservation.abort(R19GrantReservationReason::WrongEpoch,
          monotonic_now_ms(),91U);expected=1;
    }
    (void)r19_service_reserved_grant(monotonic_now_ms());
    check(expected!=0 && runtime_fail_closed &&
        vc_lora_r19_grant_reservation_stop_record.words[15]==expected &&
        vc_lora_r19_grant_reservation_stop_record.words[13]==7 &&
        e220_serial.normal_tx_bytes().size()==before,
        "distinct exact held-Grant stop predicate is frozen before zero-byte abort");
    if(test=="stop-reservation")check(r19_grant_reservation.snapshot().reason==
        R19GrantReservationReason::WrongEpoch,"original reservation first reason preserved");
    std::cout<<"stop predicate checks="<<checks<<" failures="<<failures<<'\n';
    return failures?1:0;
  }
#endif
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
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
  if(cancellation_mode && test!="cancel-ground-after-held") {
    auto cancel=command(Op::CancelRequest,Role::Ground);
    cancel.grant_session=640;cancel.grant_cycle=2;cancel.action_token=7;cancel.writer_generation=9;
    send(cancel);drain();
    check(!runtime_fail_closed && r19_grant_reservation.cancellation_pending() &&
        !r19_grant_reservation.ground_request_allowed(),"pre-PARAM Ground binding retires without a request");
    auto peer=command(Op::CancelPeerConfirmed,Role::Ground);
    peer.boot_id=111;peer.usb_epoch=19;peer.grant_session=640;peer.grant_cycle=2;
    peer.action_token=7;peer.writer_generation=9;peer.device_ms=123;send(peer);drain();
    auto fresh=command(Op::HelloRequest,Role::Ground);
    if(test!="cancel-ground-same-nonce")fresh.slot_nonce=nonce+1;
    send(fresh);
    if(test=="cancel-ground-same-nonce") {
      check(runtime_fail_closed,"cancelled nonce cannot be silently reused");
      return failures?1:0;
    }
    drain();active_nonce=nonce+1;
    auto rebound=command(Op::BindGround,Role::Ground);
    rebound.grant_session=640;rebound.grant_cycle=3;rebound.action_token=8;rebound.writer_generation=10;
    send(rebound);rebound.opcode=Op::BindPeerGround;rebound.boot_id=111;rebound.usb_epoch=19;
    send(rebound);drain();
    check(!runtime_fail_closed && r19_grant_reservation.ground_request_allowed() &&
        r19_grant_reservation.snapshot().grant_cycle==3,
        "new nonce only binds strict new cycle/token/generation after both confirmations");
    std::cout<<"ground cancellation checks="<<checks<<" failures="<<failures<<'\n';
    return failures?1:0;
  }
#endif
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
  if(test=="cancel-ground-after-held") {
    auto cancel=command(Op::CancelRequest,Role::Ground);
    cancel.grant_session=640;cancel.grant_cycle=2;cancel.action_token=7;cancel.writer_generation=9;
    const auto before_cancel=e220_serial.normal_tx_bytes().size();send(cancel);
    check(runtime_fail_closed && r19_ground_adapter->t0_ms()==t0 &&
        e220_serial.normal_tx_bytes().size()==before_cancel &&
        !r19_grant_reservation.cancellation_pending(),
        "actual PARAM/Held forbids cancel or reprepare and preserves original t0");
    return failures?1:0;
  }
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
