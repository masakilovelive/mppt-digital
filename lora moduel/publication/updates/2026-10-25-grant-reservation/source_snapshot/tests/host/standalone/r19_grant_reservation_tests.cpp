#if defined(VC_LORA_R19_GRANT_RESERVATION_LEGACY_RED)
#include "vc_lora/tdd_vehicle.hpp"
#include <iostream>
int main() {
  vc_lora::TddConfig config{};
  vc_lora::LinkDiagnostics diagnostics{};
  vc_lora::VehicleTddController vehicle(config, diagnostics);
  vehicle.reset(640U, 2U, 0U);
  vc_lora::TddInput input{};
  input.now_ms = 3000U;
  (void)vehicle.tick(input);
  input.now_ms = 3016U;
  (void)vehicle.tick(input);
  input.now_ms = 3017U;
  const auto action = vehicle.tick(input);
  const bool no_unreleased_grant = action.type != vc_lora::LinkActionType::SendGrant;
  std::cout << "legacy-no-reservation-hold-characterization checks=1 failures="
            << (no_unreleased_grant ? 0 : 1)
            << " grant_issued_before_diagnostic_release=" << !no_unreleased_grant << '\n';
  return no_unreleased_grant ? 0 : 1;
}
#else
#include "../../../firmware/high_speed/r19_grant_reservation.hpp"
#include "../../../firmware/high_speed/r19_grant_reservation_record.hpp"
#include <array>
#include <cstdint>
#include <iostream>
#include <limits>

namespace {
using namespace vc_lora;
using namespace vc_lora::experimental;
using Role = R19GrantReservationRole;
using Op = R19GrantReservationOpcode;
using State = R19GrantReservationState;
using Reason = R19GrantReservationReason;
using Message = R19GrantReservationWireMessage;
unsigned checks = 0U;
unsigned failures = 0U;
void check(bool value, const char* label) {
  ++checks;
  if (!value) { ++failures; if (failures <= 25U) std::cerr << "FAIL " << label << '\n'; }
}
Message command(Op opcode, Role role, std::uint64_t boot, std::uint32_t epoch) {
  Message m{};
  m.opcode = opcode; m.role = role; m.reader_session = 123U;
  m.slot_nonce = 0x521B000000000123ULL; m.boot_id = boot; m.usb_epoch = epoch;
  return m;
}
Message tuple_command(Op opcode, Role role, std::uint64_t boot,
                      std::uint32_t epoch) {
  auto m = command(opcode, role, boot, epoch);
  m.grant_session = 640U; m.grant_cycle = 2U;
  m.action_token = 7U; m.writer_generation = 9U;
  return m;
}
void pop(R19GrantReservationController& c, Op expected) {
  check(c.peek_reply() != nullptr && c.peek_reply()->opcode == expected,
        "expected fixed reply is queued");
  check(c.pop_reply(), "whole-frame committed reply may be popped");
}
struct Pair {
  R19GrantReservationController ground{};
  R19GrantReservationController vehicle{};
  Pair() {
    check(ground.initialize(Role::Ground, 11U, 0U, 100U), "Ground initialize epoch zero");
    check(vehicle.initialize(Role::Vehicle, 22U, 1U, 100U), "Vehicle initialize");
    auto g = command(Op::HelloRequest, Role::Ground, 0U, 0U);
    auto v = command(Op::HelloRequest, Role::Vehicle, 0U, 0U);
    check(ground.handle_command(g, 101U) && ground.peek_reply() == nullptr,
          "Ground Hello remains pending before actual RF baseline");
    check(ground.on_ground_baseline(640U, 1U, 102U), "real baseline callback");
    pop(ground, Op::HelloReply);
    check(vehicle.handle_command(v, 103U), "Vehicle Hello accepted once");
    pop(vehicle, Op::HelloReply);
    auto prepare = command(Op::PrepareVehicle, Role::Vehicle, 22U, 1U);
    prepare.grant_session = 640U; prepare.grant_cycle = 1U;
    check(vehicle.handle_command(prepare, 104U) && vehicle.awaiting_grant(),
          "Prepare waits for bridge-observed real issued Grant");
    check(vehicle.on_prepared(640U, 2U, 7U, 9U, 850U, 110U),
          "actual pending action identity and bounded exclusive hold");
    pop(vehicle, Op::Prepared);
    check(!vehicle.should_release() && vehicle.holding(),
          "zero RF writes permitted before explicit release");
    check(ground.handle_command(tuple_command(Op::BindGround, Role::Ground, 11U, 0U), 111U),
          "bind own Ground tuple");
    check(!ground.ground_request_allowed(), "peer binding also mandatory");
    check(ground.handle_command(tuple_command(Op::BindPeerGround, Role::Ground, 22U, 1U), 112U),
          "bind peer Vehicle identity");
    pop(ground, Op::Bound);
    check(vehicle.handle_command(tuple_command(Op::BindPeerVehicle, Role::Vehicle, 11U, 0U), 113U),
          "bind peer Ground on prepared Vehicle");
    check(ground.ground_request_allowed(), "bound Ground permits exact request callback");
  }
  void held(std::uint64_t t0 = 200U) {
    check(ground.on_ground_held(t0, 640U, 1U, t0), "actual original held callback");
    pop(ground, Op::GroundHeld);
  }
  void released() {
    auto release = tuple_command(Op::ReleaseGrant, Role::Vehicle, 22U, 1U);
    release.device_ms = 200U;  // Peer claim, never a Vehicle local timestamp.
    check(vehicle.handle_command(release, 220U) && vehicle.should_release(),
          "matching explicit release authorizes same held action once");
    check(vehicle.on_grant_write_accepted(640U, 2U, 7U, 9U, 230U),
          "actual UART acceptance retires pending release");
    check(!vehicle.should_release() && !vehicle.holding(), "no duplicate physical write");
  }
};

void codec() {
  auto hello = command(Op::HelloRequest, Role::Ground, 0U, 0U);
  MavlinkFrame wire{};
  check(r19_encode_grant_reservation_frame(hello, false, 1U, wire) && wire.size == 66U,
        "reservation exact66 unsigned MAVLink2 frame");
  check(r19_is_grant_reservation_namespace(wire), "exclusive private namespace");
  Message decoded{};
  check(r19_decode_grant_reservation_frame(wire.bytes.data(), wire.size, false, decoded) &&
            decoded.slot_nonce == hello.slot_nonce && decoded.reader_session == 123U,
        "canonical wire roundtrip");
  for (std::size_t index = 0U; index < wire.size; ++index) {
    auto damaged = wire; damaged.bytes[index] ^= 1U;
    Message output{}; output.boot_id = 999U;
    check(!r19_decode_grant_reservation_frame(damaged.bytes.data(), damaged.size, false, output) &&
              output.boot_id == 999U, "every single-bit mutation rejected without output mutation");
  }
  check(!r19_decode_grant_reservation_frame(wire.bytes.data(), wire.size - 1U, false, decoded),
        "partial wire rejected");
  check(!r19_decode_grant_reservation_frame(wire.bytes.data(), wire.size, true, decoded),
        "request component not response component");
  auto changed = hello; changed.flags = 1U;
  check(!r19_encode_grant_reservation_frame(changed, false, 1U, wire), "nonzero flags forbidden");
  changed = hello; changed.slot_nonce = 123U;
  check(!r19_encode_grant_reservation_frame(changed, false, 1U, wire), "nonce namespace tag required");
  changed = hello; changed.slot_nonce = 0x521B000000000000ULL;
  check(!r19_encode_grant_reservation_frame(changed, false, 1U, wire), "tagged nonce requires nonzero private identity");
  changed = hello; changed.opcode = Op::Started;
  check(!r19_encode_grant_reservation_frame(changed, true, 1U, wire), "Started not a wire opcode");
  changed = tuple_command(Op::TailReady, Role::Vehicle, 22U, 1U);
  changed.device_ms = static_cast<std::uint64_t>(std::numeric_limits<std::uint32_t>::max()) + 1U;
  check(!r19_encode_grant_reservation_frame(changed, true, 1U, wire), "wire uptime overflow not truncated");
}

void causal_fences() {
  Pair p{}; p.held(); p.released();
  check(p.ground.on_ground_grant(640U, 2U, 500U), "fresh RF Grant within original500");
  check(!p.ground.negotiation_allowed(601U), "Groundguard alone cannot substitute Vehicle physicaltail");
  check(p.vehicle.on_tail(640U, 2U, 7U, 9U, 780U), "actual550ms local Grant drain callback");
  pop(p.vehicle, Op::TailReady);
  auto permit = tuple_command(Op::TailPermitGround, Role::Ground, 22U, 1U);
  permit.device_ms = 780U;
  check(p.ground.handle_command(permit, 800U), "causal peer-tail permit received");
  check(!p.ground.negotiation_allowed(899U) && p.ground.negotiation_allowed(900U),
        "second causal100ms fence independent of GroundGrant guard");
  check(p.vehicle.on_vehicle_vcbn(640U, 2U, 1280U) && !p.vehicle.failed(),
        "complete canonical VCBN at actualP+500 inclusive");
  check(p.ground.snapshot().ground_t0_ms == 200U,
        "tail permit and guard never rebase original Groundt0");
  Pair late{}; late.held(); late.released();
  check(late.vehicle.on_tail(640U, 2U, 7U, 9U, 780U), "late fixture physicaltail");
  check(!late.vehicle.on_vehicle_vcbn(640U, 2U, 1281U) && late.vehicle.failed(),
        "VehicleP+501 rejected");
  Pair missing{}; missing.held();
  check(!missing.ground.on_ground_grant(640U, 2U, 701U), "Groundt0+501 rejected");
  Pair edge{}; edge.held();
  check(edge.ground.on_ground_grant(640U, 2U, 700U), "Groundt0+500 inclusive");
}

void refusals_and_record() {
  R19GrantReservationController late_prepare{};
  check(late_prepare.initialize(Role::Vehicle,22U,1U,100U), "late prepare init");
  check(late_prepare.handle_command(command(Op::HelloRequest,Role::Vehicle,0U,0U),101U),
        "late prepare hello");
  pop(late_prepare,Op::HelloReply);
  auto preparation=command(Op::PrepareVehicle,Role::Vehicle,22U,1U);
  preparation.grant_session=640U;preparation.grant_cycle=1U;
  check(late_prepare.handle_command(preparation,102U), "late prepare requested");
  check(!late_prepare.on_prepared(640U,2U,7U,9U,8602U,8102U),
        "expired preparation cannot be revived by a later callback");
  Pair stale_tail{};stale_tail.held();
  check(stale_tail.ground.on_ground_grant(640U,2U,500U), "stale tail fixture Grant");
  auto late_permit=tuple_command(Op::TailPermitGround,Role::Ground,22U,1U);
  late_permit.device_ms=780U;
  check(!stale_tail.ground.handle_command(late_permit,2501U),
        "late command cannot skip the original two-second tail wait");
  Pair stale_request{};
  check(!stale_request.ground.on_ground_held(8111U,640U,1U,8111U),
        "expired Ground binding cannot be revived by an actual-held callback");
  Pair expired{};
  check(!expired.vehicle.tick(850U) && !expired.vehicle.should_release(),
        "hold exclusive deadline expires without action reissue");
  Pair epoch{};
  check(!epoch.ground.observe_local_epoch(1U, 120U), "local epoch change fails");
  const auto frozen = epoch.ground.snapshot();
  check(!epoch.ground.tick(121U) && epoch.ground.snapshot().event_count == frozen.event_count,
        "first failure immutable, no postfault journal rewrite");
  Pair replay{}; replay.held(); replay.released();
  auto command_again = tuple_command(Op::ReleaseGrant, Role::Vehicle, 22U, 1U);
  command_again.device_ms = 200U;
  check(!replay.vehicle.handle_command(command_again, 240U), "release replay never writes twice");
  Pair wrong{}; wrong.held();
  auto bad = tuple_command(Op::TailPermitGround, Role::Ground, 22U, 1U);
  ++bad.writer_generation;
  check(!wrong.ground.handle_command(bad, 250U), "changed writer generation rejected");
  Pair order{}; order.held();
  check(!order.vehicle.on_tail(640U, 2U, 7U, 9U, 225U), "tail cannot precede actual UART accept");
  R19GrantReservationRecord record{};
  check(sizeof(record) == 512U, "record512 exact ABI");
  constexpr std::array<std::uint32_t, 4U> build{{1U,2U,3U,4U}};
  constexpr std::array<std::uint32_t, 4U> boot{{11U,0U,7U,8U}};
  check(record.initialize(Role::Ground, build, boot) && record.observe(frozen),
        "record stable identity initialization and controller snapshot");
  check(record.words[2U] == 0x52313952U && record.words[14U] == 512U &&
            record.words[13U] == 7U && record.words[31U] == 0U,
        "record magic, firstfault freeze and reserved bytes");
  const auto sequence = record.words[1U];
  check(record.observe(epoch.ground.snapshot()) && record.words[1U] == sequence,
        "frozen record not rewritten by repeated observer calls");
}
void strict_boundaries_and_record_validation() {
  Pair delayed{};
  check(!delayed.ground.on_ground_held(200U,640U,1U,701U),
        "delayed callback cannot publish an already-expired original held t0");
  Pair near_wrap{};near_wrap.held();near_wrap.released();
  check(near_wrap.ground.on_ground_grant(640U,2U,500U), "gate fixture actual Grant");
  auto permit=tuple_command(Op::TailPermitGround,Role::Ground,22U,1U);
  permit.device_ms=780U;
  check(near_wrap.ground.handle_command(permit,800U), "gate fixture TailPermit");
  check(!near_wrap.ground.negotiation_allowed(
          static_cast<std::uint64_t>(std::numeric_limits<std::uint32_t>::max())+1U),
        "permission query cannot authorize wire-time overflow");
  constexpr std::array<std::uint32_t,4U> build{{1U,2U,3U,4U}};
  constexpr std::array<std::uint32_t,4U> boot{{11U,0U,7U,8U}};
  const auto pristine=near_wrap.ground.snapshot();
  for(unsigned kind=0U;kind<6U;++kind) {
    R19GrantReservationRecord record{};
    check(record.initialize(Role::Ground,build,boot), "malformed record fixture init");
    auto changed=pristine;
    switch(kind) {
      case 0U:changed.state=static_cast<State>(15U);break;
      case 1U:changed.journal[0U].event=16U;break;
      case 2U:changed.journal[0U].state_reason=15U;break;
      case 3U:changed.journal[0U].state_reason=22U<<16U;break;
      case 4U:changed.journal[1U].timestamp_ms=changed.journal[0U].timestamp_ms-1U;break;
      default:changed.journal[0U].event=15U;break;
    }
    check(!record.observe(changed) && record.words[1U]==2U,
          "invalid enum/order/premature fault snapshot rejected without write");
  }
  R19GrantReservationController wrong_reply{};
  check(wrong_reply.initialize(Role::Vehicle,22U,1U,100U), "reply validation init");
  check(!wrong_reply.note_reply_completed(Op::PrepareVehicle,101U),
        "request opcode cannot be reported as USB reply commit");
}
void diagnostic_scope_and_journal() {
  constexpr std::array<std::uint32_t,4U> build{{1U,2U,3U,4U}};
  constexpr std::array<std::uint32_t,4U> boot{{11U,0U,7U,8U}};
  R19GrantReservationController c{};
  check(c.initialize(Role::Ground,11U,0U,100U), "journal epoch-zero init");
  check(c.handle_command(command(Op::HelloRequest,Role::Ground,0U,0U),101U),
        "journal Hello remains pending");
  check(c.tick(14100U) && c.peek_reply()==nullptr,
        "Hello waits real baseline; runner owns preparation timeout, not fake RF event");
  check(c.on_ground_baseline(640U,0U,14101U), "actual baseline cycle zero is valid");
  pop(c,Op::HelloReply);
  for(std::uint64_t now=14102U;now<14122U;++now)
    check(c.note_reply_completed(Op::HelloReply,now), "bounded journal observed reply event");
  check(c.snapshot().event_count==22U && c.snapshot().journal_count==12U &&
        c.snapshot().journal_dropped==10U, "journal counts first8 plus last4 retention");
  for(std::size_t i=0U;i<8U;++i)
    check(c.snapshot().journal[i].timestamp_ms==(i==0U?101U:14100U+i),
          "journal preserves first eight chronological events");
  for(std::size_t i=8U;i<12U;++i)
    check(c.snapshot().journal[i].timestamp_ms==14110U+i,
          "journal retains four most recent events in order");
  check(!c.abort(Reason::ExternalFault,14122U,99U), "external stop freezes first failure");
  const auto frozen=c.snapshot();
  check(frozen.journal[11U].event==15U && frozen.journal[11U].aux==99U &&
        frozen.reason==Reason::ExternalFault && frozen.journal_dropped==11U,
        "first failure is final retained journal entry without reserved-word reuse");
  R19GrantReservationRecord record{};
  check(record.initialize(Role::Ground,build,boot) && record.observe(frozen),
        "retained journal serializes under strict build/boot binding");
  check(record.words[17U]==(12U|(11U<<16U)) && record.words[120U]==15U &&
        record.words[127U]==99U && record.words[1U]%2U==0U && record.words[0U]==0U,
        "512-byte stable seqlock journal matches exact header and final event");
  for(unsigned mutation=0U;mutation<5U;++mutation) {
    Pair p{};
    auto m=tuple_command(Op::TailPermitGround,Role::Ground,22U,1U);
    p.held();m.device_ms=780U;
    switch(mutation) {
      case 0U:++m.reader_session;break;
      case 1U:++m.slot_nonce;break;
      case 2U:++m.boot_id;break;
      case 3U:++m.usb_epoch;break;
      default:++m.action_token;break;
    }
    check(!p.ground.handle_command(m,250U) && p.ground.failed() &&
          !p.ground.negotiation_allowed(500U), "scope/peer/token mutation cannot open negotiation");
  }
  Pair premature{};premature.held();premature.released();
  check(!premature.vehicle.on_tail(640U,2U,7U,9U,779U), "service floor549 never physical completion");
  Pair causal{};causal.held();
  auto permit=tuple_command(Op::TailPermitGround,Role::Ground,22U,1U);
  permit.device_ms=780U;
  check(causal.ground.handle_command(permit,300U), "peer claim may arrive before local RF observation");
  check(!causal.ground.negotiation_allowed(450U), "peer claim alone cannot replace accepted RF Grant");
  check(causal.ground.on_ground_grant(640U,2U,500U) &&
        !causal.ground.negotiation_allowed(599U) && causal.ground.negotiation_allowed(600U),
        "both independent local hundred-ms fences remain mandatory");
  check(causal.ground.on_ground_negotiation_started(600U) && causal.ground.tick(30000U),
        "actual negotiation start retires only reservation phase timers");
  Pair immutable{};
  check(!immutable.vehicle.tick(112U) && immutable.vehicle.snapshot().reason==Reason::ClockRegression,
        "local clock regression fails against original timestamp");
  const auto original=immutable.vehicle.snapshot();
  check(!immutable.vehicle.abort(Reason::ExternalFault,120U,321U) &&
        immutable.vehicle.snapshot().event_count==original.event_count &&
        immutable.vehicle.snapshot().reason==Reason::ClockRegression,
        "later abort cannot overwrite original first failure");
}
}  // namespace
int main() {
  codec(); causal_fences(); refusals_and_record(); strict_boundaries_and_record_validation();
  diagnostic_scope_and_journal();
  std::cout << "r19-grant-reservation checks=" << checks << " failures=" << failures
            << " diagnostic_dual_usb_only=1 product_RF_reservation=0\n";
  return failures == 0U ? 0 : 1;
}
#endif
