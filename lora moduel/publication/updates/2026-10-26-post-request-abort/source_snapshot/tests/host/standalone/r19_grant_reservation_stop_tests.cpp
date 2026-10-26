#include "../../../firmware/high_speed/r19_grant_reservation_stop_record.hpp"
#include "vc_lora/tdd_vehicle.hpp"
#include <iostream>

using namespace vc_lora::experimental;
int main() {
  unsigned failures=0;
  auto check=[&](bool value,const char* text){if(!value){++failures;std::cerr<<text<<'\n';}};
  R19GrantReservationStopSnapshot sample{};
  sample.now_ms=3154;sample.heartbeat_deadline_ms=5654;sample.hold_deadline_ms=3750;
  sample.heartbeat_order=7;sample.reserve_ms=5050;sample.expected_token=11;
  sample.expected_generation=19;sample.active_token=11;sample.active_generation=19;
  sample.active_owner=1;sample.current_usb_epoch=0;
  sample.predicates=R19GrantReservationStopSnapshot::heartbeat_valid |
    R19GrantReservationStopSnapshot::heartbeat_available |
    R19GrantReservationStopSnapshot::aux_high |
    R19GrantReservationStopSnapshot::lease_valid;
  check(r19_grant_reservation_stop_reason(sample)==
    R19GrantReservationStopReason::HeartbeatDeadlineConflict,"new HB conflict is distinct");
  R19GrantReservationStopRecord record{};
  check(record.initialize(R19GrantReservationRole::Vehicle,{{1,2,3,4}},{{5,6,7,8}}),"init");
  check(record.latch(sample),"first exact predicate capture");
  check(sizeof(record)==128 && record.words[3]==1 && record.words[15]==2 &&
    record.words[16]==3154 && record.words[18]==5654 && record.words[20]==3750 &&
    record.words[23]==5050 && record.words[29]==7 && record.words[31]==0,"exact ABI and valid zero epoch");
  const auto sequence=record.words[1];sample.now_ms=3200;sample.active_token=99;
  check(!record.latch(sample) && record.words[1]==sequence && record.words[16]==3154,
    "later failure never overwrites first snapshot");
  sample.predicates &= ~(R19GrantReservationStopSnapshot::heartbeat_valid |
    R19GrantReservationStopSnapshot::heartbeat_available);
  sample.active_token=11;
  for(unsigned mode=0;mode<8;++mode){auto altered=sample;
    switch(mode){
      case 0:altered.predicates &= ~R19GrantReservationStopSnapshot::aux_high;break;
      case 1:altered.predicates &= ~R19GrantReservationStopSnapshot::lease_valid;break;
      case 2:altered.active_owner=2;break;
      case 3:altered.active_token=99;break;
      case 4:altered.active_generation=99;break;
      case 5:altered.predicates |= R19GrantReservationStopSnapshot::radio_busy;break;
      case 6:altered.predicates |= R19GrantReservationStopSnapshot::pending_action;break;
      default:altered.predicates |= R19GrantReservationStopSnapshot::tail_pending;break;
    }
    check(static_cast<unsigned>(r19_grant_reservation_stop_reason(altered))==mode+3,
      "non-HB stop predicates have separate immutable reasons");
  }
  sample.predicates |= R19GrantReservationStopSnapshot::reservation_failed;
  check(r19_grant_reservation_stop_reason(sample)==R19GrantReservationStopReason::ReservationFailed,
    "reservation first reason preserves precedence");
  auto safe=sample;safe.predicates=R19GrantReservationStopSnapshot::heartbeat_valid |
    R19GrantReservationStopSnapshot::heartbeat_available |
    R19GrantReservationStopSnapshot::aux_high | R19GrantReservationStopSnapshot::lease_valid;
  R19GrantReservationStopRecord safe_record{};
  safe_record.initialize(R19GrantReservationRole::Vehicle,{{1,2,3,4}},{{5,6,7,8}});
  check(!safe_record.latch(safe,true),"SAFE_CANCEL needs all three independent retirement proofs");
  safe.predicates|=0xE00U;
  check(safe_record.latch(safe,true) && safe_record.words[13]==15,
    "SAFE_CANCEL is explicitly distinct from global runtime failure");
  vc_lora::TddConfig config{};vc_lora::LinkDiagnostics diagnostics{};
  vc_lora::VehicleTddController tdd(config,diagnostics);tdd.reset(640,2,0);
  vc_lora::TddInput input{};input.now_ms=3000;(void)tdd.tick(input);
  input.now_ms=3016;(void)tdd.tick(input);input.now_ms=3017;
  const auto grant=tdd.tick(input);
  check(grant.type==vc_lora::LinkActionType::SendGrant,"real pending Grant core fixture");
  check(!tdd.cancel_unsent_grant(grant.token+1,640,2,3171) && tdd.has_pending_action(),
    "wrong token cannot cancel the pending action");
  check(tdd.cancel_unsent_grant(grant.token,640,2,3171) &&
    tdd.cycle_id()==3 && !tdd.has_pending_action(),"exact cancellation atomically retires RF cycle");
  check(!tdd.cancel_unsent_grant(grant.token,640,2,3172),"cancel replay cannot retire another cycle");
  input.now_ms=3172;input.inhibit_new_grant=true;
  for(unsigned turn=0;turn<5;++turn){input.now_ms+=1200;
    check(tdd.tick(input).type==vc_lora::LinkActionType::None,
      "cancel fence blocks all fresh Grant issue while allowing normal tick");}
  auto prepare=[](){R19GrantReservationController c{};
    c.initialize(R19GrantReservationRole::Vehicle,22,1,100);
    R19GrantReservationWireMessage m{};m.wire_version=2;
    m.role=R19GrantReservationRole::Vehicle;m.reader_session=123;m.slot_nonce=0x521B000000000123ULL;
    c.handle_command(m,101);c.pop_reply();c.note_reply_completed(R19GrantReservationOpcode::HelloReply,101);
    m.opcode=R19GrantReservationOpcode::PrepareVehicle;m.boot_id=22;m.usb_epoch=1;
    m.grant_session=640;m.grant_cycle=1;c.handle_command(m,102);
    c.on_prepared(640,2,7,9,850,110);c.pop_reply();return c;};
  auto wire=[](R19GrantReservationOpcode op){R19GrantReservationWireMessage m{};
    m.wire_version=2;m.opcode=op;m.role=R19GrantReservationRole::Vehicle;
    m.reader_session=123;m.slot_nonce=0x521B000000000123ULL;m.boot_id=22;m.usb_epoch=1;
    m.grant_session=640;m.grant_cycle=2;m.action_token=7;m.writer_generation=9;return m;};
  auto cancelled=prepare();
  check(cancelled.begin_cancel(264,true) && cancelled.cancellation_pending(),"bounded logical cancel follows physical proof");
  cancelled.pop_reply();cancelled.note_reply_completed(R19GrantReservationOpcode::Withdrawn,264);
  check(cancelled.handle_command(wire(R19GrantReservationOpcode::CancelRequest),265),"request acknowledgement follows withdrawal");
  cancelled.pop_reply();cancelled.note_reply_completed(R19GrantReservationOpcode::CancelAck,265);
  auto peer=wire(R19GrantReservationOpcode::CancelPeerConfirmed);peer.boot_id=111;peer.usb_epoch=19;
  check(cancelled.handle_command(peer,266),"peer cancellation claim matches exact retired tuple");
  cancelled.pop_reply();cancelled.note_reply_completed(R19GrantReservationOpcode::CancelPeerConfirmed,266);
  auto fresh=wire(R19GrantReservationOpcode::HelloRequest);
  fresh.boot_id=0;fresh.usb_epoch=0;fresh.grant_session=0;fresh.grant_cycle=0;
  fresh.action_token=0;fresh.writer_generation=0;++fresh.slot_nonce;
  check(cancelled.handle_command(fresh,267),"explicit fresh nonce after both acknowledgements");
  cancelled.pop_reply();
  auto request=wire(R19GrantReservationOpcode::PrepareVehicle);request.slot_nonce=fresh.slot_nonce;
  request.grant_cycle=1;request.action_token=0;request.writer_generation=0;
  check(cancelled.handle_command(request,268),"fresh prepare uses original preparation budget");
  auto copied=cancelled;
  check(!copied.on_prepared(640,2,8,10,850,300),"old RF cycle cannot alias a fresh writer token");
  copied=cancelled;check(!copied.on_prepared(640,3,7,10,850,300),"old action token cannot rebind");
  copied=cancelled;check(!copied.on_prepared(640,3,8,9,850,300),"old writer generation cannot rebind");
  check(cancelled.on_prepared(640,3,8,10,850,300),"strict new cycle/token/generation reprepare");
  check(!cancelled.begin_cancel(301,true),"at most one cancellation per overall preparation");
  auto expired=prepare();expired.begin_cancel(264,true);expired.pop_reply();
  check(!expired.tick(8102) && expired.snapshot().reason==R19GrantReservationReason::PrepareExpired,
    "cancellation cannot extend original eight-second device preparation deadline");
  auto wrong_peer=prepare();wrong_peer.begin_cancel(264,true);
  check(!wrong_peer.handle_command(peer,265),"peer confirmation before local CancelAck cannot authorize fresh scope");
  auto legacy=wire(R19GrantReservationOpcode::CancelRequest);legacy.wire_version=1;
  vc_lora::MavlinkFrame frame{};
  check(!r19_encode_grant_reservation_frame(legacy,false,1,frame),"v1 rejects new cancellation opcodes");
  legacy.wire_version=2;
  check(r19_encode_grant_reservation_frame(legacy,false,1,frame),"v2 cancellation has explicit wire version");
  R19GrantReservationWireMessage decoded{};
  check(r19_decode_grant_reservation_frame(frame.bytes.data(),frame.size,false,decoded) &&
    decoded.wire_version==2,"v2 exact66 codec preserves explicit version");
  std::cout<<"reservation-stop failures="<<failures<<'\n';return failures?1:0;
}
