#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_types.hpp"

namespace vc_lora::experimental {

// Diagnostic dual-USB orchestration only. A trusted PC relays peer claims;
// neither CRC nor reader/nonce binding authenticates that PC. This is not a
// product RF reservation protocol or a guaranteed future-latency bound.
enum class R19GrantReservationRole : std::uint8_t { Invalid=0U, Ground=1U, Vehicle=2U };
enum class R19GrantReservationOpcode : std::uint8_t {
  HelloRequest=1U, HelloReply=2U, PrepareVehicle=3U, Prepared=4U,
  BindGround=5U, BindPeerGround=6U, Bound=7U, BindPeerVehicle=8U,
  ReleaseGrant=9U, ReleaseVehicle=9U, GroundHeld=10U, TailReady=11U,
  TailPermitGround=12U, TailPermit=12U, Fault=13U, Started=14U,
  CancelRequest=15U, CancelAck=16U, Withdrawn=17U, CancelPeerConfirmed=18U
};
enum class R19GrantReservationState : std::uint8_t {
  Cold=0U, HelloPending=1U, HelloReady=2U, AwaitVehicleGrant=3U,
  VehiclePrepared=4U, GroundLocalBound=5U, GroundBound=6U, GroundHeld=7U,
  GroundGranted=8U, VehicleReleaseGranted=9U, VehicleGrantWritten=10U,
  VehicleTailReady=11U, GroundTailPermitted=12U, Started=13U, Failed=14U
};
enum class R19GrantReservationReason : std::uint16_t {
  None=0U, InvalidConfiguration=1U, InvalidWire=2U, WrongRole=3U,
  WrongScope=4U, WrongBoot=5U, WrongEpoch=6U, WrongState=7U,
  WrongGrant=8U, WrongToken=9U, Replay=10U, ClockRegression=11U,
  TimeOverflow=12U, PrepareExpired=13U, HoldExpired=14U,
  GrantWaitExpired=15U, TailWaitExpired=16U, VehicleWindowExpired=17U,
  QueueFull=18U, UnsafeHold=19U, CanonicalRequestMismatch=20U,
  ExternalFault=21U
};
enum class R19GrantReservationEvent : std::uint8_t {
  None=0U, Hello=1U, Baseline=2U, Prepare=3U, Prepared=4U,
  BoundLocal=5U, BoundPeer=6U, GroundHeld=7U, ReleaseGrant=8U,
  GrantWritten=9U, GrantObserved=10U, TailObserved=11U, TailPermit=12U,
  Started=13U, ReplyCommitted=14U, Failure=15U
};

struct R19GrantReservationWireMessage final {
  std::uint8_t wire_version{1U};
  R19GrantReservationOpcode opcode{R19GrantReservationOpcode::HelloRequest};
  R19GrantReservationRole role{R19GrantReservationRole::Invalid};
  std::uint8_t flags{0U};
  std::uint64_t reader_session{0U};
  std::uint64_t slot_nonce{0U};
  std::uint64_t boot_id{0U};
  std::uint32_t usb_epoch{0U};
  std::uint16_t grant_session{0U};
  std::uint16_t grant_cycle{0U};
  std::uint32_t action_token{0U};
  std::uint32_t writer_generation{0U};
  std::uint64_t device_ms{0U}; // Encode rejects uptime above UINT32_MAX.
};

namespace r19_grant_reservation_detail {
using Op=R19GrantReservationOpcode;
using Role=R19GrantReservationRole;
constexpr bool response_opcode(Op op) noexcept {
  return op==Op::HelloReply || op==Op::Prepared || op==Op::Bound ||
         op==Op::GroundHeld || op==Op::TailReady || op==Op::Fault ||
         op==Op::CancelAck || op==Op::Withdrawn || op==Op::CancelPeerConfirmed;
}
constexpr bool request_opcode(Op op) noexcept {
  return op==Op::HelloRequest || op==Op::PrepareVehicle || op==Op::BindGround ||
         op==Op::BindPeerGround || op==Op::BindPeerVehicle || op==Op::ReleaseGrant ||
         op==Op::TailPermitGround || op==Op::CancelRequest ||
         op==Op::CancelPeerConfirmed;
}
constexpr bool valid_role(Role role) noexcept { return role==Role::Ground || role==Role::Vehicle; }
constexpr bool complete_tuple(const R19GrantReservationWireMessage& m) noexcept {
  return m.grant_session!=0U && m.grant_cycle!=0U && m.action_token!=0U && m.writer_generation!=0U;
}
constexpr bool semantic(const R19GrantReservationWireMessage& m,bool response) noexcept {
  if((m.wire_version!=1U && m.wire_version!=2U) ||
     (static_cast<std::uint8_t>(m.opcode)>=15U && m.wire_version!=2U) ||
     !valid_role(m.role) || m.flags!=0U || m.reader_session==0U ||
     (m.slot_nonce>>48U)!=0x521BU || (m.slot_nonce&0x0000FFFFFFFFFFFFULL)==0U ||
     m.device_ms>std::numeric_limits<std::uint32_t>::max() ||
     (response ? !response_opcode(m.opcode) : !request_opcode(m.opcode))) return false;
  switch(m.opcode) {
    case Op::HelloRequest:
      return m.boot_id==0U && m.usb_epoch==0U && m.grant_session==0U &&
             m.grant_cycle==0U && m.action_token==0U && m.writer_generation==0U && m.device_ms==0U;
    case Op::HelloReply:
      return m.boot_id!=0U && m.action_token==0U && m.writer_generation==0U &&
             (m.role!=Role::Ground || m.grant_session!=0U);
    case Op::PrepareVehicle:
      return m.role==Role::Vehicle && m.boot_id!=0U && m.grant_session!=0U &&
             m.action_token==0U && m.writer_generation==0U && m.device_ms==0U;
    case Op::BindGround: case Op::BindPeerGround:
      return m.role==Role::Ground && m.boot_id!=0U && complete_tuple(m) && m.device_ms==0U;
    case Op::BindPeerVehicle:
      return m.role==Role::Vehicle && m.boot_id!=0U && complete_tuple(m) && m.device_ms==0U;
    case Op::Prepared: case Op::TailReady: case Op::ReleaseGrant:
      return m.role==Role::Vehicle && m.boot_id!=0U && complete_tuple(m);
    case Op::Bound: case Op::GroundHeld: case Op::TailPermitGround:
      return m.role==Role::Ground && m.boot_id!=0U && complete_tuple(m);
    case Op::Fault: return m.boot_id!=0U;
    case Op::CancelRequest:
      return m.boot_id!=0U && complete_tuple(m) && m.device_ms==0U;
    case Op::CancelAck: case Op::CancelPeerConfirmed:
      return m.boot_id!=0U && complete_tuple(m);
    case Op::Withdrawn:
      return m.role==Role::Vehicle && m.boot_id!=0U && complete_tuple(m);
    default: return false; // Started is record-only, never wire authority.
  }
}
inline void put(std::uint8_t* p,std::uint64_t v,std::size_t n) noexcept {
  for(std::size_t i=0U;i<n;++i) p[i]=static_cast<std::uint8_t>(v>>(8U*i));
}
inline std::uint64_t get(const std::uint8_t* p,std::size_t n) noexcept {
  std::uint64_t v=0U; for(std::size_t i=0U;i<n;++i) v|=static_cast<std::uint64_t>(p[i])<<(8U*i); return v;
}
constexpr bool fresh(std::uint16_t s,std::uint16_t c,std::uint16_t bs,std::uint16_t bc) noexcept {
  return s!=0U && c!=0U && bs!=0U && (s==bs ? compare_sequence(c,bc)==SequenceOrder::Newer : compare_sequence(s,bs)==SequenceOrder::Newer);
}
} // namespace r19_grant_reservation_detail

inline bool r19_is_grant_reservation_namespace(const std::uint8_t* bytes,std::size_t size) noexcept {
  return bytes!=nullptr && size>=10U && bytes[0U]==0xFDU && bytes[5U]==249U &&
         (bytes[6U]==197U || bytes[6U]==198U) && bytes[7U]==253U && bytes[8U]==0U && bytes[9U]==0U;
}
inline bool r19_is_grant_reservation_namespace(const MavlinkFrame& frame) noexcept {
  return r19_is_grant_reservation_namespace(frame.bytes.data(),frame.size);
}
inline bool r19_encode_grant_reservation_frame(const R19GrantReservationWireMessage& m,
    bool response,std::uint8_t sequence,MavlinkFrame& out) noexcept {
  using namespace r19_grant_reservation_detail;
  if(!semantic(m,response)) return false;
  std::array<std::uint8_t,54U> p{};
  p[0U]='R';p[1U]='1';p[2U]='9';p[3U]='R';p[4U]=m.wire_version;
  p[5U]=static_cast<std::uint8_t>(m.opcode);p[6U]=static_cast<std::uint8_t>(m.role);
  put(p.data()+8U,m.reader_session,8U);put(p.data()+16U,m.slot_nonce,8U);
  put(p.data()+24U,m.boot_id,8U);put(p.data()+32U,m.usb_epoch,4U);
  put(p.data()+36U,m.grant_session,2U);put(p.data()+38U,m.grant_cycle,2U);
  put(p.data()+40U,m.action_token,4U);put(p.data()+44U,m.writer_generation,4U);
  put(p.data()+48U,m.device_ms,4U);p[52U]=0xA5U;p[53U]=0x5AU;
  MavlinkFrame candidate{};
  if(!encode_mavlink_v2(sequence,249U,response?198U:197U,253U,p.data(),p.size(),candidate) || candidate.size!=66U) return false;
  out=candidate;return true;
}
inline bool r19_decode_grant_reservation_frame(const std::uint8_t* bytes,std::size_t size,
    bool response,R19GrantReservationWireMessage& out) noexcept {
  using namespace r19_grant_reservation_detail;
  if(!r19_is_grant_reservation_namespace(bytes,size) || size!=66U || bytes[1U]!=54U ||
     bytes[2U]!=0U || bytes[3U]!=0U || bytes[6U]!=(response?198U:197U)) return false;
  MavlinkFrame frame{};
  if(validate_mavlink_frame(bytes,size,frame)!=MavlinkParseStatus::FrameReady || frame.signed_frame || frame.payload_length!=54U) return false;
  const auto* p=frame.payload();
  if(p[0U]!='R' || p[1U]!='1' || p[2U]!='9' || p[3U]!='R' || (p[4U]!=1U && p[4U]!=2U) || p[7U]!=0U || p[52U]!=0xA5U || p[53U]!=0x5AU) return false;
  R19GrantReservationWireMessage m{};
  m.wire_version=p[4U];
  m.opcode=static_cast<Op>(p[5U]);m.role=static_cast<Role>(p[6U]);m.flags=p[7U];
  m.reader_session=get(p+8U,8U);m.slot_nonce=get(p+16U,8U);m.boot_id=get(p+24U,8U);
  m.usb_epoch=static_cast<std::uint32_t>(get(p+32U,4U));m.grant_session=static_cast<std::uint16_t>(get(p+36U,2U));
  m.grant_cycle=static_cast<std::uint16_t>(get(p+38U,2U));m.action_token=static_cast<std::uint32_t>(get(p+40U,4U));
  m.writer_generation=static_cast<std::uint32_t>(get(p+44U,4U));m.device_ms=get(p+48U,4U);
  if(!semantic(m,response)) return false;
  out=m;return true;
}

struct R19GrantReservationJournalEntry final {
  std::uint32_t event{0U};
  std::uint32_t state_reason{0U};
  std::uint64_t timestamp_ms{0U};
  std::uint32_t grant_tuple{0U};
  std::uint32_t action_token{0U};
  std::uint32_t writer_generation{0U};
  std::uint32_t aux{0U};
};
struct R19GrantReservationSnapshot final {
  R19GrantReservationRole role{R19GrantReservationRole::Invalid};
  R19GrantReservationState state{R19GrantReservationState::Cold};
  R19GrantReservationReason reason{R19GrantReservationReason::None};
  bool initialized{false};bool frozen{false};
  std::uint64_t own_boot_id{0U},peer_boot_id{0U};
  std::uint32_t own_epoch{0U},peer_epoch{0U};
  std::uint64_t slot_nonce{0U},reader_session{0U};
  std::uint16_t grant_session{0U},grant_cycle{0U};
  std::uint32_t action_token{0U},writer_generation{0U};
  std::uint64_t ground_t0_ms{0U},ground_grant_ms{0U},grant_write_ms{0U},tail_ms{0U},tail_permit_received_ms{0U};
  std::uint32_t event_count{0U};std::uint16_t journal_count{0U},journal_dropped{0U};
  std::array<R19GrantReservationJournalEntry,12U> journal{};
};

class R19GrantReservationController final {
 public:
  using Role=R19GrantReservationRole;using Op=R19GrantReservationOpcode;
  using State=R19GrantReservationState;using Reason=R19GrantReservationReason;
  using Event=R19GrantReservationEvent;using Message=R19GrantReservationWireMessage;
  enum class CancellationPhase : std::uint8_t {None=0U,LocalCancelled=1U,PeerConfirmed=2U,FreshRound=3U};
  bool initialize(Role role,std::uint64_t own_boot,std::uint32_t epoch,std::uint64_t now) noexcept {
    if(s_.initialized) return fail(Reason::Replay,last_now_);
    s_.role=role;s_.own_boot_id=own_boot;s_.own_epoch=epoch;s_.initialized=true;last_now_=now;
    if(!r19_grant_reservation_detail::valid_role(role) || own_boot==0U) return fail(Reason::InvalidConfiguration,now);
    if(now>std::numeric_limits<std::uint32_t>::max()) return fail(Reason::TimeOverflow,now);
    return true;
  }
  bool initialized() const noexcept {return s_.initialized;}
  State state() const noexcept {return s_.state;}
  bool failed() const noexcept {return s_.state==State::Failed;}
  bool can_prepare() const noexcept {return s_.role==Role::Vehicle && s_.state==State::HelloReady;}
  bool awaiting_grant() const noexcept {return s_.state==State::AwaitVehicleGrant;}
  bool holding() const noexcept {return !cancellation_pending() && (s_.state==State::VehiclePrepared || s_.state==State::VehicleReleaseGranted);}
  bool should_release() const noexcept {return !cancellation_pending() && s_.state==State::VehicleReleaseGranted && peer_bound_ && !failed();}
  std::uint64_t hold_deadline_ms() const noexcept {return hold_deadline_;}
  bool ground_request_allowed() const noexcept {return !cancellation_pending() && s_.role==Role::Ground && s_.state==State::GroundBound && peer_bound_;}
  bool cancellation_supported() const noexcept {return wire_version_==2U;}
  bool cancellation_available() const noexcept {return cancellation_supported() && !cancellation_used_ && !failed();}
  bool cancellation_pending() const noexcept {return cancellation_==CancellationPhase::LocalCancelled || cancellation_==CancellationPhase::PeerConfirmed;}
  bool cancel_request_seen() const noexcept {return cancel_request_seen_;}
  bool inhibit_new_grant() const noexcept {return cancellation_pending() ||
    (cancellation_used_ && cancellation_==CancellationPhase::FreshRound && s_.state==State::HelloReady);}
  CancellationPhase cancellation_phase() const noexcept {return cancellation_;}
  bool cancel_request_matches(const Message& m) const noexcept {
    if(!cancellation_supported() || failed() || m.wire_version!=2U ||
       m.opcode!=Op::CancelRequest || m.role!=s_.role ||
       m.reader_session!=s_.reader_session || m.slot_nonce!=s_.slot_nonce ||
       m.boot_id!=s_.own_boot_id || m.usb_epoch!=s_.own_epoch ||
       !r19_grant_reservation_detail::semantic(m,false)) return false;
    if(s_.role==Role::Ground && s_.state==State::HelloReady)
      return r19_grant_reservation_detail::fresh(m.grant_session,m.grant_cycle,
          baseline_session_,baseline_cycle_);
    return m.grant_session==s_.grant_session && m.grant_cycle==s_.grant_cycle &&
      m.action_token==s_.action_token && m.writer_generation==s_.writer_generation;
  }
  // The bridge calls this only after exact zero-UART action/cycle/lease
  // retirement, or after proving Ground has never admitted its one request.
  bool begin_cancel(std::uint64_t now,bool withdrawn) noexcept {
    if(!tick(now)) return false;
    if(!cancellation_supported() || cancellation_used_ || ground_held_ ||
       grant_written_ || tail_seen_ ||
       (s_.role==Role::Vehicle && !holding()) ||
       (s_.role==Role::Ground && s_.state!=State::HelloReady &&
        s_.state!=State::GroundLocalBound && s_.state!=State::GroundBound))
      return fail(Reason::WrongState,now);
    cancellation_used_=true;cancellation_=CancellationPhase::LocalCancelled;
    retired_nonce_=s_.slot_nonce;retired_session_=s_.grant_session;
    retired_cycle_=s_.grant_cycle;retired_token_=s_.action_token;
    retired_generation_=s_.writer_generation;
    cancel_request_seen_=!withdrawn;
    return reply(withdrawn?Op::Withdrawn:Op::CancelAck,now);
  }
  const R19GrantReservationSnapshot& snapshot() const noexcept {return s_;}
  const Message* peek_reply() const noexcept {return queue_count_==0U?nullptr:&queue_[queue_head_];}
  bool pop_reply() noexcept {
    if(queue_count_==0U) return false;
    queue_head_=(queue_head_+1U)%queue_.size();--queue_count_;return true;
  }
  bool note_reply_completed(Op opcode,std::uint64_t now) noexcept {
    if(failed()) return true;
    if(!tick(now)) return false;
    if(!r19_grant_reservation_detail::response_opcode(opcode)) return fail(Reason::InvalidWire,now);
    if(opcode==Op::CancelAck) {
      if(!cancellation_pending() || !cancel_request_seen_ || cancel_ack_committed_)
        return fail(Reason::WrongState,now);
      cancel_ack_committed_=true;
    }
    journal(Event::ReplyCommitted,now,static_cast<std::uint32_t>(opcode));return true;
  }
  bool abort(Reason reason,std::uint64_t now,std::uint32_t detail=0U) noexcept {
    return fail(reason==Reason::None?Reason::ExternalFault:reason,now,detail);
  }
  bool observe_local_epoch(std::uint32_t epoch,std::uint64_t now) noexcept {
    if(!tick(now)) return false;
    return epoch==s_.own_epoch || fail(Reason::WrongEpoch,now,epoch);
  }
  bool on_ground_baseline(std::uint16_t session,std::uint16_t cycle,std::uint64_t now) noexcept {
    if(!tick(now)) return false;
    if(s_.role!=Role::Ground || (s_.state!=State::Cold && s_.state!=State::HelloPending && s_.state!=State::HelloReady)) return fail(Reason::WrongState,now);
    if(session==0U) return fail(Reason::WrongGrant,now);
    if(baseline_session_!=0U && session==baseline_session_ && cycle==baseline_cycle_) return true;
    if(baseline_session_!=0U && !r19_grant_reservation_detail::fresh(session,cycle,baseline_session_,baseline_cycle_)) return fail(Reason::WrongGrant,now);
    baseline_session_=session;baseline_cycle_=cycle;s_.grant_session=session;s_.grant_cycle=cycle;
    const bool pending_hello=s_.state==State::HelloPending;
    if(pending_hello) s_.state=State::HelloReady;
    journal(Event::Baseline,now);
    if(pending_hello) return reply(Op::HelloReply,now);
    return true;
  }
  bool handle_command(const Message& m,std::uint64_t now) noexcept {
    using namespace r19_grant_reservation_detail;
    // An event must not revive an expired phase merely because the bridge has
    // not run its periodic tick yet. The original phase clocks remain intact.
    if(!tick(now)) return false;
    if(!semantic(m,false)) return fail(Reason::InvalidWire,now);
    if(m.role!=s_.role) return fail(Reason::WrongRole,now);
    if(m.opcode==Op::HelloRequest) {
      if(cancellation_==CancellationPhase::PeerConfirmed) {
        if(m.wire_version!=2U || m.reader_session!=s_.reader_session ||
           m.slot_nonce==retired_nonce_ || !cancel_ack_committed_ ||
           queue_count_!=0U) return fail(Reason::Replay,now);
        s_.slot_nonce=m.slot_nonce;s_.peer_boot_id=0U;s_.peer_epoch=0U;
        s_.action_token=0U;s_.writer_generation=0U;
        s_.grant_session=s_.role==Role::Ground?baseline_session_:0U;
        s_.grant_cycle=s_.role==Role::Ground?baseline_cycle_:0U;
        peer_bound_=false;s_.state=State::HelloReady;
        cancellation_=CancellationPhase::FreshRound;journal(Event::Hello,now);
        return reply(Op::HelloReply,now);
      }
      if(s_.state!=State::Cold || s_.reader_session!=0U) return fail(Reason::Replay,now);
      wire_version_=m.wire_version;
      s_.reader_session=m.reader_session;s_.slot_nonce=m.slot_nonce;
      s_.state=(s_.role==Role::Vehicle || baseline_session_!=0U)?State::HelloReady:State::HelloPending;
      journal(Event::Hello,now);
      if(s_.state==State::HelloReady) return reply(Op::HelloReply,now);
      return true;
    }
    if(m.reader_session!=s_.reader_session || m.slot_nonce!=s_.slot_nonce || s_.reader_session==0U) return fail(Reason::WrongScope,now);
    if(m.wire_version!=wire_version_) return fail(Reason::InvalidWire,now);
    const bool peer=m.opcode==Op::BindPeerGround || m.opcode==Op::BindPeerVehicle || m.opcode==Op::TailPermitGround || m.opcode==Op::CancelPeerConfirmed;
    if(!peer && m.boot_id!=s_.own_boot_id) return fail(Reason::WrongBoot,now);
    if(!peer && m.usb_epoch!=s_.own_epoch) return fail(Reason::WrongEpoch,now);
    switch(m.opcode) {
      case Op::CancelRequest:
        if(!cancel_request_matches(m)) return fail(Reason::WrongScope,now);
        if(cancellation_pending()) {
          if(cancel_request_seen_) return fail(Reason::Replay,now);
          cancel_request_seen_=true;return reply(Op::CancelAck,now);
        }
        if(s_.role==Role::Ground && s_.state==State::HelloReady) set_tuple(m);
        return begin_cancel(now,false);
      case Op::CancelPeerConfirmed:
        if(cancellation_!=CancellationPhase::LocalCancelled || !cancel_ack_committed_ ||
           !tuple(m,now)) return fail_if_healthy(Reason::WrongState,now);
        if(s_.peer_boot_id!=0U && (m.boot_id!=s_.peer_boot_id || m.usb_epoch!=s_.peer_epoch))
          return fail(Reason::WrongBoot,now);
        s_.peer_boot_id=m.boot_id;s_.peer_epoch=m.usb_epoch;
        cancellation_=CancellationPhase::PeerConfirmed;return reply(Op::CancelPeerConfirmed,now);
      case Op::PrepareVehicle:
        if(!can_prepare() || cancellation_pending()) return fail(Reason::WrongState,now);
        baseline_session_=m.grant_session;baseline_cycle_=m.grant_cycle;
        if(!prepare_active_)prepare_start_=now;prepare_active_=true;
        s_.state=State::AwaitVehicleGrant;journal(Event::Prepare,now);return true;
      case Op::BindGround:
        if(cancellation_pending() || s_.state!=State::HelloReady ||
           !fresh(m.grant_session,m.grant_cycle,baseline_session_,baseline_cycle_) ||
           (cancellation_used_ && (!fresh(m.grant_session,m.grant_cycle,retired_session_,retired_cycle_) ||
            m.action_token<=retired_token_ || m.writer_generation<=retired_generation_))) return fail(Reason::WrongGrant,now);
        set_tuple(m);if(!prepare_active_)prepare_start_=now;prepare_active_=true;s_.state=State::GroundLocalBound;
        journal(Event::BoundLocal,now);return true;
      case Op::BindPeerGround:
        if(s_.state!=State::GroundLocalBound || peer_bound_) return fail(Reason::WrongState,now);
        if(!tuple(m,now)) return false;
        s_.peer_boot_id=m.boot_id;s_.peer_epoch=m.usb_epoch;peer_bound_=true;s_.state=State::GroundBound;
        journal(Event::BoundPeer,now);return reply(Op::Bound,now);
      case Op::BindPeerVehicle:
        if(s_.state!=State::VehiclePrepared || peer_bound_) return fail(Reason::WrongState,now);
        if(!tuple(m,now)) return false;
        s_.peer_boot_id=m.boot_id;s_.peer_epoch=m.usb_epoch;peer_bound_=true;journal(Event::BoundPeer,now);return true;
      case Op::ReleaseGrant:
        if(s_.state!=State::VehiclePrepared || !peer_bound_) return fail(Reason::WrongState,now);
        if(!tuple(m,now) || !hold_valid(now)) return false;
        s_.state=State::VehicleReleaseGranted;journal(Event::ReleaseGrant,now,static_cast<std::uint32_t>(m.device_ms));return true;
      case Op::TailPermitGround:
        if(s_.role!=Role::Ground || !ground_held_ || tail_permit_seen_ || !peer_bound_ ||
           (s_.state!=State::GroundHeld && s_.state!=State::GroundGranted)) return fail(Reason::WrongState,now);
        if(m.boot_id!=s_.peer_boot_id) return fail(Reason::WrongBoot,now);
        if(m.usb_epoch!=s_.peer_epoch) return fail(Reason::WrongEpoch,now);
        if(!tuple(m,now)) return false;
        tail_permit_seen_=true;s_.tail_permit_received_ms=now;peer_tail_claim_=m.device_ms;
        if(ground_grant_seen_) s_.state=State::GroundTailPermitted;
        journal(Event::TailPermit,now,static_cast<std::uint32_t>(m.device_ms));return true;
      default: return fail(Reason::InvalidWire,now);
    }
  }
  bool on_prepared(std::uint16_t session,std::uint16_t cycle,std::uint32_t token,
      std::uint32_t generation,std::uint64_t deadline,std::uint64_t now) noexcept {
    if(!tick(now)) return false;
    if(!awaiting_grant()) return fail(Reason::WrongState,now);
    if(!r19_grant_reservation_detail::fresh(session,cycle,baseline_session_,baseline_cycle_) || token==0U || generation==0U) return fail(Reason::WrongGrant,now);
    if(cancellation_used_ && (!r19_grant_reservation_detail::fresh(session,cycle,retired_session_,retired_cycle_) ||
       token<=retired_token_ || generation<=retired_generation_)) return fail(Reason::WrongGrant,now);
    if(deadline<=now || deadline-now>750U) return fail(Reason::UnsafeHold,now);
    s_.grant_session=session;s_.grant_cycle=cycle;s_.action_token=token;s_.writer_generation=generation;
    hold_deadline_=deadline;s_.state=State::VehiclePrepared;journal(Event::Prepared,now);return reply(Op::Prepared,now);
  }
  // Bridge must first validate the exact canonical #21 and actual adapter Held
  // event. This callback never manufactures an adapter request or moves t0.
  bool on_ground_held(std::uint64_t t0,std::uint16_t baseline_session,
      std::uint16_t baseline_cycle,std::uint64_t now) noexcept {
    if(!tick(now)) return false;
    if(!ground_request_allowed() || ground_held_) return fail(Reason::WrongState,now);
    if(baseline_session!=baseline_session_ || baseline_cycle!=baseline_cycle_ ||
       !r19_grant_reservation_detail::fresh(s_.grant_session,s_.grant_cycle,baseline_session,baseline_cycle)) return fail(Reason::WrongGrant,now);
    if(t0>now || t0<last_journal_ms_) return fail(Reason::ClockRegression,now);
    if(now-t0>500U) return fail(Reason::GrantWaitExpired,now);
    s_.ground_t0_ms=t0;ground_held_=true;prepare_active_=false;s_.state=State::GroundHeld;
    journal(Event::GroundHeld,t0);return reply(Op::GroundHeld,t0);
  }
  bool on_ground_grant(std::uint16_t session,std::uint16_t cycle,std::uint64_t now) noexcept {
    if(!tick(now)) return false;
    if(!ground_held_ || ground_grant_seen_ || s_.role!=Role::Ground) return fail(Reason::WrongState,now);
    if(session!=s_.grant_session || cycle!=s_.grant_cycle) return fail(Reason::WrongGrant,now);
    if(now<s_.ground_t0_ms || now-s_.ground_t0_ms>500U) return fail(Reason::GrantWaitExpired,now);
    ground_grant_seen_=true;s_.ground_grant_ms=now;s_.state=tail_permit_seen_?State::GroundTailPermitted:State::GroundGranted;
    journal(Event::GrantObserved,now);return true;
  }
  bool on_grant_write_accepted(std::uint16_t session,std::uint16_t cycle,std::uint32_t token,
      std::uint32_t generation,std::uint64_t now) noexcept {
    if(!tick(now)) return false;
    if(!should_release() || !hold_valid(now)) return fail_if_healthy(Reason::WrongState,now);
    if(!tuple(session,cycle,token,generation,now)) return false;
    s_.grant_write_ms=now;grant_written_=true;prepare_active_=false;s_.state=State::VehicleGrantWritten;
    journal(Event::GrantWritten,now);return true;
  }
  bool on_tail(std::uint16_t session,std::uint16_t cycle,std::uint32_t token,
      std::uint32_t generation,std::uint64_t now) noexcept {
    if(!tick(now)) return false;
    if(s_.role!=Role::Vehicle || s_.state!=State::VehicleGrantWritten || !grant_written_) return fail(Reason::WrongState,now);
    if(!tuple(session,cycle,token,generation,now)) return false;
    if(now<s_.grant_write_ms || now-s_.grant_write_ms<550U) return fail(Reason::UnsafeHold,now);
    s_.tail_ms=now;tail_seen_=true;s_.state=State::VehicleTailReady;journal(Event::TailObserved,now);return reply(Op::TailReady,now);
  }
  // Caller has validated complete canonical VCBN and correlated Grant identity;
  // no raw arrival, prefix, UART acceptance, or PC timestamp may call this.
  bool on_vehicle_vcbn(std::uint16_t session,std::uint16_t cycle,std::uint64_t now) noexcept {
    if(!tick(now)) return false;
    if(s_.role!=Role::Vehicle || s_.state!=State::VehicleTailReady || !tail_seen_) return fail(Reason::WrongState,now);
    if(session!=s_.grant_session || cycle!=s_.grant_cycle) return fail(Reason::WrongGrant,now);
    if(now<s_.tail_ms || now-s_.tail_ms>500U) return fail(Reason::VehicleWindowExpired,now);
    s_.state=State::Started;journal(Event::Started,now);return true;
  }
  bool negotiation_allowed(std::uint64_t now) const noexcept {
    if(!initialized() || failed() || s_.role!=Role::Ground || !ground_grant_seen_ || !tail_permit_seen_ || now<last_now_ ||
       now>std::numeric_limits<std::uint32_t>::max()) return false;
    if(s_.state==State::Started) return true;
    return now>=s_.ground_grant_ms && now-s_.ground_grant_ms>=100U &&
           now>=s_.tail_permit_received_ms && now-s_.tail_permit_received_ms>=100U &&
           now>=s_.ground_t0_ms && now-s_.ground_t0_ms<=28000U &&
           now-s_.ground_grant_ms<=2000U;
  }
  bool on_ground_negotiation_started(std::uint64_t now) noexcept {
    if(!tick(now)) return false;
    if(s_.state==State::Started || !negotiation_allowed(now)) return fail(Reason::WrongState,now);
    s_.state=State::Started;journal(Event::Started,now);return true;
  }
  bool tick(std::uint64_t now) noexcept {
    if(!time(now)) return false;
    if(holding() && !hold_valid(now)) return false;
    if(prepare_active_ && now-prepare_start_>=8000U) return fail(Reason::PrepareExpired,now);
    if(ground_held_ && s_.state!=State::Started) {
      if(now-s_.ground_t0_ms>28000U) return fail(Reason::GrantWaitExpired,now);
      if(!ground_grant_seen_ && now-s_.ground_t0_ms>500U) return fail(Reason::GrantWaitExpired,now);
      if(ground_grant_seen_ && now-s_.ground_grant_ms>2000U) return fail(Reason::TailWaitExpired,now);
    }
    if(tail_seen_ && s_.state!=State::Started && now-s_.tail_ms>500U) return fail(Reason::VehicleWindowExpired,now);
    return true;
  }
 private:
  R19GrantReservationSnapshot s_{};
  std::array<Message,8U> queue_{};std::size_t queue_head_{0U},queue_count_{0U};
  std::uint16_t baseline_session_{0U},baseline_cycle_{0U};
  std::uint64_t last_now_{0U},last_journal_ms_{0U},prepare_start_{0U},hold_deadline_{0U},peer_tail_claim_{0U};
  bool prepare_active_{false},peer_bound_{false},ground_held_{false},ground_grant_seen_{false};
  bool grant_written_{false},tail_seen_{false},tail_permit_seen_{false};
  std::uint8_t wire_version_{1U};CancellationPhase cancellation_{CancellationPhase::None};
  bool cancellation_used_{false},cancel_request_seen_{false},cancel_ack_committed_{false};
  std::uint64_t retired_nonce_{0U};std::uint16_t retired_session_{0U},retired_cycle_{0U};
  std::uint32_t retired_token_{0U},retired_generation_{0U};
  bool time(std::uint64_t now) noexcept {
    if(failed()) return false;
    if(!s_.initialized) return fail(Reason::InvalidConfiguration,now);
    if(now<last_now_) return fail(Reason::ClockRegression,last_now_,static_cast<std::uint32_t>(now));
    last_now_=now;
    if(now>std::numeric_limits<std::uint32_t>::max()) return fail(Reason::TimeOverflow,now);
    return true;
  }
  bool hold_valid(std::uint64_t now) noexcept {return now<hold_deadline_ || fail(Reason::HoldExpired,now);}
  void set_tuple(const Message& m) noexcept {s_.grant_session=m.grant_session;s_.grant_cycle=m.grant_cycle;s_.action_token=m.action_token;s_.writer_generation=m.writer_generation;}
  bool tuple(const Message& m,std::uint64_t now) noexcept {return tuple(m.grant_session,m.grant_cycle,m.action_token,m.writer_generation,now);}
  bool tuple(std::uint16_t session,std::uint16_t cycle,std::uint32_t token,std::uint32_t generation,std::uint64_t now) noexcept {
    if(session!=s_.grant_session || cycle!=s_.grant_cycle) return fail(Reason::WrongGrant,now);
    return (token==s_.action_token && generation==s_.writer_generation) || fail(Reason::WrongToken,now);
  }
  bool reply(Op opcode,std::uint64_t now) noexcept {
    if(queue_count_>=queue_.size()) return fail(Reason::QueueFull,now);
    Message m{};m.wire_version=wire_version_;m.opcode=opcode;m.role=s_.role;m.reader_session=s_.reader_session;m.slot_nonce=s_.slot_nonce;
    m.boot_id=s_.own_boot_id;m.usb_epoch=s_.own_epoch;m.grant_session=s_.grant_session;m.grant_cycle=s_.grant_cycle;
    if(opcode!=Op::HelloReply) {m.action_token=s_.action_token;m.writer_generation=s_.writer_generation;}
    m.device_ms=now;
    if(!r19_grant_reservation_detail::semantic(m,true)) return fail(Reason::InvalidWire,now);
    queue_[(queue_head_+queue_count_)%queue_.size()]=m;++queue_count_;return true;
  }
  bool fail_if_healthy(Reason reason,std::uint64_t now) noexcept {return failed()?false:fail(reason,now);}
  bool fail(Reason reason,std::uint64_t now,std::uint32_t detail=0U) noexcept {
    if(failed()) return false;
    s_.reason=reason;s_.state=State::Failed;
    journal(Event::Failure,now,detail);s_.frozen=true;
    // Generic Fault does not overwrite token/generation with an error code.
    // If scope/time is unavailable, JTAG first-failure evidence remains final.
    if(queue_count_<queue_.size() && s_.reader_session!=0U && (s_.slot_nonce>>48U)==0x521BU &&
       s_.own_boot_id!=0U && now<=std::numeric_limits<std::uint32_t>::max()) {
      Message m{};m.wire_version=wire_version_;m.opcode=Op::Fault;m.role=s_.role;m.reader_session=s_.reader_session;m.slot_nonce=s_.slot_nonce;
      m.boot_id=s_.own_boot_id;m.usb_epoch=s_.own_epoch;m.grant_session=s_.grant_session;m.grant_cycle=s_.grant_cycle;
      m.action_token=s_.action_token;m.writer_generation=s_.writer_generation;m.device_ms=now;
      queue_[(queue_head_+queue_count_)%queue_.size()]=m;++queue_count_;
    }
    return false;
  }
  void journal(Event event,std::uint64_t now,std::uint32_t aux=0U) noexcept {
    if(s_.frozen) return;
    R19GrantReservationJournalEntry entry{};entry.event=static_cast<std::uint32_t>(event);
    entry.state_reason=static_cast<std::uint32_t>(s_.state)|(static_cast<std::uint32_t>(s_.reason)<<16U);
    entry.timestamp_ms=now;entry.grant_tuple=static_cast<std::uint32_t>(s_.grant_session)|(static_cast<std::uint32_t>(s_.grant_cycle)<<16U);
    entry.action_token=s_.action_token;entry.writer_generation=s_.writer_generation;entry.aux=aux;
    if(s_.event_count!=std::numeric_limits<std::uint32_t>::max()) ++s_.event_count;
    if(s_.journal_count<12U) {s_.journal[s_.journal_count]=entry;++s_.journal_count;}
    else {for(std::size_t i=8U;i<11U;++i)s_.journal[i]=s_.journal[i+1U];s_.journal[11U]=entry;
      if(s_.journal_dropped!=std::numeric_limits<std::uint16_t>::max())++s_.journal_dropped;}
    last_journal_ms_=now;
  }
};
static_assert(sizeof(R19GrantReservationJournalEntry)==32U);
static_assert(BulkSessionTiming::grant_wait_budget_ms==500U);
static_assert(BulkSessionTiming::direction_guard_ms==100U);
static_assert(BulkSessionTiming::hard_lease_ms==28000U);
static_assert(BulkSessionAccounting::completion_deadline_ms==30000U);
} // namespace vc_lora::experimental
