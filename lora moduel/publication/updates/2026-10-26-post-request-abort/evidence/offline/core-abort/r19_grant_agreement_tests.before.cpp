#include "../../../firmware/high_speed/r19_grant_reservation.hpp"
#include "../../../firmware/high_speed/r19_grant_reservation_record.hpp"
#include "../../../firmware/high_speed/r19_grant_reservation_stop_record.hpp"
#include <cstdint>
#include <iostream>
#include <limits>
#include <type_traits>
#include <utility>

namespace {
using namespace vc_lora;
using namespace vc_lora::experimental;
using Controller=R19GrantReservationController;
using Message=R19GrantReservationWireMessage;
using Op=R19GrantReservationOpcode;
using Role=R19GrantReservationRole;
using State=R19GrantReservationState;
using Reason=R19GrantReservationReason;
constexpr auto commit_request=static_cast<Op>(19U);
constexpr auto commit_ack=static_cast<Op>(20U);
constexpr auto abort_request=static_cast<Op>(21U);
constexpr auto abort_ack=static_cast<Op>(22U);
unsigned checks=0U,failures=0U;
void check(bool value,const char* name) {
  ++checks;
  if(!value){++failures;if(failures<30U)std::cerr<<"FAIL "<<name<<'\n';}
}
Message command(Op op,Role role,std::uint8_t version=3U,bool tuple=true) {
  Message m{};m.wire_version=version;m.opcode=op;m.role=role;
  m.reader_session=123U;m.slot_nonce=0x521B000000000123ULL;
  m.boot_id=role==Role::Ground?11U:22U;m.usb_epoch=role==Role::Ground?0U:1U;
  if(tuple){m.grant_session=640U;m.grant_cycle=2U;m.action_token=7U;m.writer_generation=9U;}
  return m;
}
void pop(Controller& c,Op expected) {
  check(c.peek_reply()!=nullptr && c.peek_reply()->opcode==expected,"exact queued reply");
  check(c.pop_reply(),"reply popped without recreating authority");
}
struct Pair {
  Controller ground{},vehicle{};
  explicit Pair(std::uint8_t version=3U) {
    check(ground.initialize(Role::Ground,11U,0U,100U),"Ground initialization");
    check(vehicle.initialize(Role::Vehicle,22U,1U,100U),"Vehicle initialization");
    auto h=command(Op::HelloRequest,Role::Ground,version,false);h.boot_id=0U;h.usb_epoch=0U;
    check(ground.handle_command(h,101U),"Ground Hello");
    check(ground.on_ground_baseline(640U,1U,102U),"actual Ground baseline");pop(ground,Op::HelloReply);
    h.role=Role::Vehicle;
    check(vehicle.handle_command(h,103U),"Vehicle Hello");pop(vehicle,Op::HelloReply);
    auto p=command(Op::PrepareVehicle,Role::Vehicle,version,false);p.grant_session=640U;p.grant_cycle=1U;
    check(vehicle.handle_command(p,104U),"actual prepare starts original clock");
    check(vehicle.on_prepared(640U,2U,7U,9U,850U,110U),"real reserved Grant");pop(vehicle,Op::Prepared);
    auto b=command(Op::BindGround,Role::Ground,version);
    check(ground.handle_command(b,111U),"bind Ground own tuple");
    b=command(Op::BindPeerGround,Role::Ground,version);b.boot_id=22U;b.usb_epoch=1U;
    check(ground.handle_command(b,112U),"bind Vehicle identity at Ground");pop(ground,Op::Bound);
    b=command(Op::BindPeerVehicle,Role::Vehicle,version);b.boot_id=11U;b.usb_epoch=0U;
    check(vehicle.handle_command(b,113U),"bind Ground identity at Vehicle");
  }
  void commit() {
    check(ground.handle_command(command(commit_request,Role::Ground),120U),"Ground local conditional commit");pop(ground,commit_ack);
    check(vehicle.handle_command(command(commit_request,Role::Vehicle),121U),"Vehicle local conditional commit");pop(vehicle,commit_ack);
  }
};
template<class C,class=void>struct HasAgreement:std::false_type{};
template<class C>struct HasAgreement<C,std::void_t<
  decltype(std::declval<C&>().agreement_enabled()),
  decltype(std::declval<C&>().agreement_committed()),
  decltype(std::declval<C&>().agreement_commit_ms()),
  decltype(std::declval<C&>().terminal_aborted()),
  decltype(std::declval<C&>().terminal_abort(std::declval<Message>(),0U,true)),
  decltype(std::declval<C&>().terminal_abort_ack_committed()),
  decltype(std::declval<C&>().terminal_abort_ms())>>:std::true_type{};

void codec() {
  for(unsigned raw=19U;raw<=22U;++raw){
    const bool response=(raw==20U || raw==22U);
    for(auto role:{Role::Ground,Role::Vehicle}){
      auto m=command(static_cast<Op>(raw),role);m.device_ms=response?125U:0U;
      MavlinkFrame frame{};Message decoded{};
      check(r19_encode_grant_reservation_frame(m,response,8U,frame) && frame.size==66U,"v3 exact66 agreement codec");
      check(r19_decode_grant_reservation_frame(frame.bytes.data(),frame.size,response,decoded) &&
        decoded.opcode==m.opcode && decoded.wire_version==3U && decoded.action_token==7U,"v3 canonical agreement roundtrip");
      for(std::uint8_t version:{std::uint8_t{1U},std::uint8_t{2U}}){auto old=m;old.wire_version=version;
        check(!r19_encode_grant_reservation_frame(old,response,8U,frame),"legacy versions cannot acquire new opcodes");}
      for(unsigned bad=0U;bad<10U;++bad){auto malformed=m;
        switch(bad){case 0:malformed.reader_session=0U;break;case 1:malformed.slot_nonce=0U;break;
          case 2:malformed.boot_id=0U;break;case 3:malformed.grant_session=0U;break;
          case 4:malformed.grant_cycle=0U;break;case 5:malformed.action_token=0U;break;
          case 6:malformed.writer_generation=0U;break;case 7:malformed.flags=1U;break;
          case 8:malformed.device_ms=std::uint64_t{1U}<<32U;break;
          default:malformed.role=Role::Invalid;break;}
        check(!r19_encode_grant_reservation_frame(malformed,response,8U,frame),"agreement malformed identity or tuple rejected");
      }
      auto badtime=m;badtime.device_ms=1U;
      if(!response)check(!r19_encode_grant_reservation_frame(badtime,false,8U,frame),"agreement requests require device_ms zero");
      check(!r19_encode_grant_reservation_frame(m,!response,8U,frame),"agreement request response directions exclusive");
    }
  }
  for(std::uint8_t version:{std::uint8_t{1U},std::uint8_t{2U}}){
    auto hello=command(Op::HelloRequest,Role::Ground,version,false);hello.boot_id=0U;hello.usb_epoch=0U;
    MavlinkFrame frame{};Message decoded{};
    check(r19_encode_grant_reservation_frame(hello,false,0U,frame) &&
      r19_decode_grant_reservation_frame(frame.bytes.data(),frame.size,false,decoded) && decoded.wire_version==version,
      "legacy Hello codec unchanged");
  }
}
void cancelled_release() {
  Pair p(2U);
  check(p.vehicle.begin_cancel(130U,true),"existing safe Vehicle cancellation");
  const auto previous=p.vehicle.state();
  check(!p.vehicle.handle_command(command(Op::ReleaseGrant,Role::Vehicle,2U),131U),"cancelpending old Release command rejected");
  check(!p.vehicle.failed() && p.vehicle.state()==previous && p.vehicle.cancellation_pending(),"old Release neither changes displayed state nor destroys cancellation handshake");
  check(!p.vehicle.should_release() && !p.vehicle.ground_request_allowed(),"rejected Release has no old RF authority");
  check(p.vehicle.handle_command(command(Op::CancelRequest,Role::Vehicle,2U),132U),"cancellation acknowledgment route remains available");
}
template<class C>void agreement() {
  if constexpr(!HasAgreement<C>::value){check(false,"controller exposes independent agreement/abort contract");}
  else {
    Pair p;C& g=p.ground;C& v=p.vehicle;
    check(g.agreement_enabled() && v.agreement_enabled(),"wire3 explicitly selects agreement");
    check(!g.ground_request_allowed() && !g.agreement_committed() && !v.agreement_committed(),"binding alone cannot admit v3 PARAM");
    p.commit();
    check(g.agreement_committed() && v.agreement_committed() && g.agreement_commit_ms()==120U && v.agreement_commit_ms()==121U,"per-MCU commit timestamps are exact local facts");
    check(g.ground_request_allowed() && !v.should_release(),"commit does not itself release RF");
    check(g.on_ground_held(200U,640U,1U,200U),"v3 canonical request admitted once with original t0");pop(g,Op::GroundHeld);
    auto release=command(Op::ReleaseGrant,Role::Vehicle);release.device_ms=200U;
    check(v.handle_command(release,210U) && v.should_release(),"matching committed release can proceed");
    check(v.on_grant_write_accepted(640U,2U,7U,9U,211U),"actual grant acceptance remains distinct");
    check(g.snapshot().ground_t0_ms==200U,"commit does not move request origin");
    for(auto role:{Role::Ground,Role::Vehicle}){
      Pair no;C& c=role==Role::Ground?no.ground:no.vehicle;
      check(role==Role::Ground?!c.on_ground_held(200U,640U,1U,200U):!c.handle_command(command(Op::ReleaseGrant,Role::Vehicle),200U),"v3 admission and Release both need local commit");
    }
    for(unsigned field=0U;field<10U;++field){
      Pair no;C& c=no.ground;auto m=command(commit_request,Role::Ground);
      switch(field){case 0:m.reader_session++;break;case 1:m.slot_nonce++;break;case 2:m.boot_id++;break;
        case 3:m.usb_epoch++;break;case 4:m.grant_session++;break;case 5:m.grant_cycle++;break;
        case 6:m.action_token++;break;case 7:m.writer_generation++;break;case 8:m.role=Role::Vehicle;break;
        default:m.device_ms=1U;break;}
      check(!c.handle_command(m,120U) && !c.agreement_committed(),"commit exact identity mismatches never grant authority");
    }
    {
      Pair q;q.commit();C& c=q.vehicle;
      check(c.begin_cancel(130U,true) && !c.agreement_committed(),"safe cancellation revokes committed permission");
      check(!c.handle_command(command(Op::ReleaseGrant,Role::Vehicle),131U) && !c.failed(),"v3 cancellation rejects obsolete Release nonfatally");
    }
    {
      Pair q;C& c=q.ground;
      check(!c.handle_command(command(abort_request,Role::Ground),120U) && !c.terminal_aborted() && c.peek_reply()==nullptr,
        "ordinary command ingress cannot manufacture Abort boundary proof or ACK");
    }
    {
      Pair q;C& c=q.vehicle;
      check(!c.handle_command(command(commit_request,Role::Vehicle),850U) && !c.agreement_committed() &&
        c.snapshot().reason==Reason::HoldExpired,"commit never extends 750ms reserved hold deadline");
    }
    {
      Pair q;q.commit();C& c=q.ground;
      check(!c.handle_command(command(commit_request,Role::Ground),122U) && c.agreement_commit_ms()==120U,
        "duplicate commit is not a new agreement clock or authority");
    }
    for(unsigned field=0U;field<15U;++field){
      Pair q;q.commit();C& c=q.ground;auto m=command(abort_request,Role::Ground);
      bool boundary=true;std::uint64_t now=130U;
      switch(field){case 0:m.reader_session++;break;case 1:m.slot_nonce++;break;case 2:m.boot_id++;break;
        case 3:m.usb_epoch++;break;case 4:m.grant_session++;break;case 5:m.grant_cycle++;break;
        case 6:m.action_token++;break;case 7:m.writer_generation++;break;case 8:m.wire_version=2U;break;
        case 9:m.device_ms=1U;break;case 10:boundary=false;break;case 11:now=119U;break;
        case 12:m.role=Role::Vehicle;break;case 13:m.opcode=commit_request;break;default:m.flags=1U;break;}
      check(!c.terminal_abort(m,now,boundary) && !c.terminal_aborted(),"invalid or unproven Abort cannot claim a proven stop");
      check(c.agreement_committed() && c.agreement_commit_ms()==120U,"rejected Abort cannot fake a completed terminal boundary");
    }
    {
      Pair q;q.commit();C& c=q.ground;
      check(c.on_ground_held(200U,640U,1U,200U),"Held before terminal Abort");pop(c,Op::GroundHeld);
      const auto before=c.snapshot();const auto hold=c.hold_deadline_ms();
      check(c.terminal_abort(command(abort_request,Role::Ground),210U,true),"proof-backed GroundHeld Abort accepted");
      check(c.terminal_aborted() && !c.agreement_committed() && c.terminal_abort_ms()==210U,"independent terminal tombstone revokes agreement");
      check(c.snapshot().state==before.state && c.snapshot().ground_t0_ms==200U && c.snapshot().event_count==before.event_count && c.hold_deadline_ms()==hold,"Abort does not rewrite legacy state t0 journal or phase clocks");
      check(!c.note_reply_completed(abort_ack,209U) && !c.terminal_abort_ack_committed(),"AbortAck cannot be published before terminal latch");
      pop(c,abort_ack);check(c.note_reply_completed(abort_ack,211U) && c.terminal_abort_ack_committed(),"terminal AbortAck can record actual publication");
      check(!c.tick(212U) && !c.ground_request_allowed() && !c.negotiation_allowed(212U),"terminal tombstone inhibits all operational gates");
      check(!c.handle_command(command(commit_request,Role::Ground),212U) && !c.on_ground_grant(640U,2U,212U),"terminal cannot reacquire permission or accept old Grant");
      check(!c.terminal_abort(command(abort_request,Role::Ground),213U,true) && c.peek_reply()==nullptr,"duplicate Abort cannot enqueue repeated authority");
      auto h=command(Op::HelloRequest,Role::Ground,3U,false);h.boot_id=0U;h.usb_epoch=0U;h.slot_nonce++;
      check(!c.handle_command(h,214U),"terminal Abort never permits fresh reservation retry");
    }
    {
      Pair q;q.commit();C& c=q.vehicle;
      check(c.begin_cancel(130U,true),"cancellation can race after last commit");
      const auto prior=c.state();
      check(c.terminal_abort(command(abort_request,Role::Vehicle),140U,true),"post-request runner may converge a previously cancelled Vehicle to terminal Abort");
      check(c.state()==prior && !c.should_release() && !c.holding() && !c.awaiting_grant() && !c.can_prepare(),"terminal supersedes retryable cancellation without restoring old lease");
    }
    {
      Pair q;q.commit();C& g2=q.ground;C& v2=q.vehicle;
      check(v2.begin_cancel(130U,true),"v3 before-request cancellation remains retryable exactly once");pop(v2,Op::Withdrawn);
      check(g2.handle_command(command(Op::CancelRequest,Role::Ground),131U),"Ground v3 local cancellation");pop(g2,Op::CancelAck);
      check(g2.note_reply_completed(Op::CancelAck,132U),"Ground actual cancel ACK publication");
      check(v2.handle_command(command(Op::CancelRequest,Role::Vehicle),133U),"Vehicle v3 cancel acknowledgment");pop(v2,Op::CancelAck);
      check(v2.note_reply_completed(Op::CancelAck,134U),"Vehicle actual cancel ACK publication");
      auto pg=command(Op::CancelPeerConfirmed,Role::Ground);pg.boot_id=22U;pg.usb_epoch=1U;pg.device_ms=134U;
      auto pv=command(Op::CancelPeerConfirmed,Role::Vehicle);pv.boot_id=11U;pv.usb_epoch=0U;pv.device_ms=132U;
      check(g2.handle_command(pg,135U),"Ground bilateral cancel confirmation");pop(g2,Op::CancelPeerConfirmed);
      check(v2.handle_command(pv,136U),"Vehicle bilateral cancel confirmation");pop(v2,Op::CancelPeerConfirmed);
      for(auto role:{Role::Ground,Role::Vehicle}){auto h=command(Op::HelloRequest,role,3U,false);h.boot_id=0U;h.usb_epoch=0U;h.slot_nonce++;
        C& c=role==Role::Ground?g2:v2;
        check(c.handle_command(h,140U),"v3 new nonce only after bilateral cancel");pop(c,Op::HelloReply);
        check(!c.agreement_committed(),"new nonce does not inherit previous commitment");}
      auto prepare=command(Op::PrepareVehicle,Role::Vehicle,3U,false);prepare.slot_nonce++;prepare.grant_session=640U;prepare.grant_cycle=1U;
      check(v2.handle_command(prepare,141U),"fresh round prepare under same MCU preparation clock");
      check(v2.on_prepared(640U,3U,8U,10U,880U,150U),"fresh RF cycle token and generation");pop(v2,Op::Prepared);
      auto fresh=[](Op op,Role role){auto m=command(op,role);m.slot_nonce++;m.grant_cycle=3U;m.action_token=8U;m.writer_generation=10U;return m;};
      check(g2.handle_command(fresh(Op::BindGround,Role::Ground),151U),"new Ground tuple after complete cancellation");
      auto bg=fresh(Op::BindPeerGround,Role::Ground);bg.boot_id=22U;bg.usb_epoch=1U;
      check(g2.handle_command(bg,152U),"new Ground peer binding");pop(g2,Op::Bound);
      auto bv=fresh(Op::BindPeerVehicle,Role::Vehicle);bv.boot_id=11U;bv.usb_epoch=0U;
      check(v2.handle_command(bv,153U),"new Vehicle peer binding");
      check(!g2.ground_request_allowed(),"fresh tuple still needs new local commit");
      check(g2.handle_command(fresh(commit_request,Role::Ground),154U),"new Ground commit exact new tuple");pop(g2,commit_ack);
      check(v2.handle_command(fresh(commit_request,Role::Vehicle),155U),"new Vehicle commit exact new tuple");pop(v2,commit_ack);
      check(g2.agreement_commit_ms()==154U && v2.agreement_commit_ms()==155U && g2.ground_request_allowed(),"new round commitment is a new fact not old permission reuse");
    }
    {
      Pair q;q.commit();C& c=q.ground;
      check(c.on_ground_held(200U,640U,1U,200U),"failure test exact original Held");pop(c,Op::GroundHeld);
      check(!c.abort(Reason::ExternalFault,210U,77U),"first protocol failure saved before Abort");
      const auto before=c.snapshot();
      check(c.terminal_abort(command(abort_request,Role::Ground),220U,true),"proof-backed Abort remains callable after first failure");
      const auto& after=c.snapshot();
      check(c.failed() && after.frozen && after.reason==before.reason && after.state==before.state && after.ground_t0_ms==before.ground_t0_ms && after.event_count==before.event_count && after.journal_count==before.journal_count && after.journal[after.journal_count-1U].aux==77U && after.journal[after.journal_count-1U].timestamp_ms==210U,"terminal agreement does not overwrite any first-fault reason detail or time");
      pop(c,Op::Fault);pop(c,abort_ack);
      check(c.note_reply_completed(abort_ack,221U) && c.terminal_abort_ack_committed(),"failed controller can acknowledge exact terminal completion");
    }
    {
      Pair q;q.commit();C& c=q.ground;
      check(c.on_ground_held(200U,640U,1U,200U),"original one request starts its own fixed clock");pop(c,Op::GroundHeld);
      check(c.tick(700U) && !c.tick(701U) && c.snapshot().reason==Reason::GrantWaitExpired && c.snapshot().ground_t0_ms==200U,
        "v3 commit does not extend Ground 500ms or move t0");
    }
    {
      Pair q;q.commit();C& c=q.vehicle;
      auto release=command(Op::ReleaseGrant,Role::Vehicle);release.device_ms=200U;
      check(c.handle_command(release,210U) && c.on_grant_write_accepted(640U,2U,7U,9U,220U),"actual Vehicle Grant before existing RF tail");
      check(c.on_tail(640U,2U,7U,9U,770U),"unchanged 550ms minimum RF service floor");pop(c,Op::TailReady);
      check(!c.on_vehicle_vcbn(640U,2U,1271U) && c.snapshot().reason==Reason::VehicleWindowExpired,
        "v3 commit does not extend Vehicle tail-to-VCBN 500ms");
    }
    for(std::uint8_t version:{std::uint8_t{1U},std::uint8_t{2U}}){
      Pair q(version);C& c=q.ground;
      check(!c.agreement_enabled() && c.ground_request_allowed(),"v1 v2 existing admission remains unchanged");
      check(!c.terminal_abort(command(abort_request,Role::Ground),130U,true),"legacy session never accepts v3 Abort");
    }
  }
}
} // namespace
int main() {
  codec();cancelled_release();agreement<Controller>();
  check(sizeof(R19GrantReservationRecord)==512U && sizeof(R19GrantReservationStopRecord)==128U,"existing record ABI sizes remain exact");
  std::cout<<"r19-grant-agreement checks="<<checks<<" failures="<<failures<<'\n';
  return failures==0U?0:1;
}
