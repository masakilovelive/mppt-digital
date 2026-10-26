#include "fake_arduino_test_api.hpp"
#if defined(AGREEMENT_TEST_VEHICLE)
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
#include <array>
#include <iostream>
#include <string>

using namespace vc_lora_phase6_firmware;
using namespace vc_lora;
using namespace vc_lora::experimental;
using Op = R19GrantReservationOpcode;
using Role = R19GrantReservationRole;
namespace {
unsigned checks = 0U;
unsigned failures = 0U;
bool abort_via_loop = false;
constexpr std::uint64_t kNonce = 0x521B000000000001ULL;
constexpr auto kCommit = static_cast<Op>(19U);
constexpr auto kAbort = static_cast<Op>(21U);
std::uint32_t selected_token = 7U;
std::uint32_t selected_generation = 9U;

void check(bool value, const char* name) {
  ++checks;
  if (!value) { ++failures; std::cerr << "FAIL " << name << '\n'; }
}

R19GrantReservationWireMessage command(Op opcode, Role role) {
  R19GrantReservationWireMessage m{};
  m.wire_version = 3U;
  m.opcode = opcode; m.role = role;
  m.reader_session = 17U; m.slot_nonce = kNonce;
  if (opcode != Op::HelloRequest) {
    m.boot_id = r19_grant_reservation_boot_id;
    m.usb_epoch = Serial.txLossEpoch();
  }
  return m;
}

R19GrantReservationWireMessage tuple_command(Op opcode, Role role) {
  auto m = command(opcode, role);
  m.grant_session = 640U; m.grant_cycle = 2U;
  m.action_token = selected_token;
  m.writer_generation = selected_generation;
  return m;
}

// Encode a canonical MAVLink envelope without using the controller's current
// wire-version allowlist. This gives a runtime RED against the old bridge,
// rather than a new-enum compilation failure or a copied protocol model.
MavlinkFrame wire_frame(const R19GrantReservationWireMessage& m) {
  std::array<std::uint8_t, 54U> payload{};
  payload[0] = 'R'; payload[1] = '1'; payload[2] = '9'; payload[3] = 'R';
  payload[4] = m.wire_version; payload[5] = static_cast<std::uint8_t>(m.opcode);
  payload[6] = static_cast<std::uint8_t>(m.role); payload[7] = m.flags;
  auto put = [&payload](std::size_t offset, std::uint64_t value, std::size_t size) {
    for (std::size_t i = 0U; i < size; ++i)
      payload[offset + i] = static_cast<std::uint8_t>(value >> (8U * i));
  };
  put(8U, m.reader_session, 8U); put(16U, m.slot_nonce, 8U);
  put(24U, m.boot_id, 8U); put(32U, m.usb_epoch, 4U);
  put(36U, m.grant_session, 2U); put(38U, m.grant_cycle, 2U);
  put(40U, m.action_token, 4U); put(44U, m.writer_generation, 4U);
  put(48U, m.device_ms, 4U); payload[52U] = 0xA5U; payload[53U] = 0x5AU;
  MavlinkFrame frame{};
  check(encode_mavlink_v2(1U, 249U, 197U, 253U,
                        payload.data(), payload.size(), frame) && frame.size == 66U,
        "canonical private command envelope");
  return frame;
}

void send(const R19GrantReservationWireMessage& m) {
  const auto rf_before = e220_serial.normal_tx_bytes().size();
#if !defined(AGREEMENT_TEST_VEHICLE)
  const auto ingress_before = ground_ingress.queued_bytes();
  const auto proxy_before = ground_parameter_proxy.active();
#endif
  const auto pixhawk_before =
#if defined(AGREEMENT_TEST_VEHICLE)
      pixhawk_serial.normal_tx_bytes().size();
#else
      std::size_t{0U};
#endif
  const auto wire = wire_frame(m);
  if (abort_via_loop && m.opcode == kAbort) {
    Serial.inject_rx(wire.bytes.data(), wire.size);
    for (unsigned i = 0U; i < 100U && Serial.available() != 0; ++i) loop_bridge();
    check(Serial.available() == 0, "actual loop consumed complete private Abort input");
  } else {
    check(r19_intercept_grant_reservation_usb_frame(wire),
          "private command consumed by actual bridge");
  }
  check(e220_serial.normal_tx_bytes().size() == rf_before,
        "private command never leaks onto E220 UART");
#if defined(AGREEMENT_TEST_VEHICLE)
  check(pixhawk_serial.normal_tx_bytes().size() == pixhawk_before,
        "private command never leaks onto Pixhawk UART");
  check(radio_application_endpoint.egress().empty(),
        "private command never enters the deferred Pixhawk output queue");
#else
  (void)pixhawk_before;
  check(ground_ingress.queued_bytes() == ingress_before &&
            ground_parameter_proxy.active() == proxy_before,
        "private command never enters normal GCS request queue");
#endif
}

void drain() {
  for (unsigned i = 0U; i < 40U && r19_grant_reservation.peek_reply() != nullptr; ++i)
    (void)r19_service_grant_reservation_reply();
  check(r19_grant_reservation.peek_reply() == nullptr &&
            !r19_grant_reservation_reply_fault,
        "private whole-frame writer drained with no prefix replay");
}

bool reply_is(unsigned opcode) {
  const auto* reply = r19_grant_reservation.peek_reply();
  return reply != nullptr && static_cast<unsigned>(reply->opcode) == opcode &&
         reply->wire_version == 3U && reply->slot_nonce == kNonce &&
         reply->action_token == selected_token &&
         reply->writer_generation == selected_generation;
}

MavlinkFrame parameter_request() {
  const std::array<std::uint8_t, 2U> payload{{1U, 1U}};
  MavlinkFrame frame{};
  check(encode_mavlink_v2(99U, 255U, 190U, 21U,
                        payload.data(), payload.size(), frame), "canonical PARAM fixture");
  return frame;
}

MavlinkFrame heartbeat() {
  const std::array<std::uint8_t, 9U> payload{{0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U}};
  MavlinkFrame frame{};
  check(encode_mavlink_v2(17U, 1U, 1U, 0U,
                        payload.data(), payload.size(), frame), "canonical Heartbeat fixture");
  return frame;
}

#if !defined(AGREEMENT_TEST_VEHICLE)
void arm_ground_usb() {
  constexpr std::uint64_t clock_nonce = 0x5219000000000021ULL;
  std::array<std::uint8_t, 16U> payload{};
  for (unsigned i = 0U; i < 8U; ++i)
    payload[8U + i] = static_cast<std::uint8_t>(clock_nonce >> (8U * i));
  MavlinkFrame request{};
  check(encode_mavlink_v2(2U, 249U, 193U, 111U,
                        payload.data(), payload.size(), request), "local clock request fixture");
  check(r19_intercept_usb_clock_request(request), "actual local clock request handler");
  for (unsigned i = 0U; i < 8U &&
       (r19_usb_clock_reply_active || r19_usb_clock_reply_pending); ++i)
    (void)r19_service_usb_clock_reply();
  check(r19_usb_ready_publication_complete && !r19_usb_clock_reply_fault,
        "actual Clock and 32+32+2 READY completed before ARM");
  R19HostReadinessCommand arm{};
  check(r19_host_readiness_gate.ready_command(arm), "actual READY binding available");
  arm.opcode = R19HostReadinessOpcode::Arm;
  arm.proof_flags = r19_host_arm_required_proof;
  MavlinkFrame frame{};
  check(r19_encode_host_readiness_frame(4U, arm, frame), "exact ARM fixture");
  check(r19_intercept_usb_clock_request(frame) && r19_product_usb_publication_allowed(),
        "actual explicit ARM enables normal product publication");
}
#endif
}  // namespace

int main(int argc, char** argv) {
  const std::string test = argc > 1 ? argv[1] : "commit";
  abort_via_loop = test == "loop-abort" || test == "failed-loop-abort";
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true); Serial.set_endpoint_ready(true);
  setup_bridge();
  check(bridge_ready && !runtime_fail_closed, "actual bridge setup ready");
  if (test == "wrong-wire") {
    auto hello = command(Op::HelloRequest,
#if defined(AGREEMENT_TEST_VEHICLE)
                         Role::Vehicle);
#else
                         Role::Ground);
#endif
    hello.wire_version = 2U; send(hello);
    check(runtime_fail_closed && e220_serial.normal_tx_bytes().empty(),
          "agreement opt-in does not silently downgrade to wirev2");
  } else {
#if defined(AGREEMENT_TEST_VEHICLE)
    r19_vehicle_usb_clock_seen = true;
    send(command(Op::HelloRequest, Role::Vehicle)); drain();
    check(!runtime_fail_closed, "wirev3 Vehicle Hello accepted in explicit agreement mode");
    if (runtime_fail_closed) goto done;
    {
      auto prepare = command(Op::PrepareVehicle, Role::Vehicle);
      const auto original_prepare_ms = monotonic_now_ms();
      prepare.grant_session = 640U; prepare.grant_cycle = 1U; send(prepare);
      tdd_controller.reset(640U, 2U, monotonic_now_ms());
      fake_arduino::advance_time_ms(3000U); r19_observe_e220_aux(monotonic_now_ms());
      (void)tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
      fake_arduino::advance_time_ms(16U); r19_observe_e220_aux(monotonic_now_ms());
      (void)tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
      fake_arduino::advance_time_ms(1U); r19_observe_e220_aux(monotonic_now_ms());
      const auto action = tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
      check(action.type == LinkActionType::SendGrant, "actual TDD issued exact Grant action");
      if (test == "defer-prepared-heartbeat" || test == "defer-prepared-budget") {
        const auto frame = heartbeat();
        for (std::size_t i = 0U; i < frame.size; ++i)
          (void)vehicle_scheduler.ingest_byte(frame.bytes[i], monotonic_now_ms());
        check(r19_hold_generated_grant(action, monotonic_now_ms()),
              "late Heartbeat revalidates generated-but-unpublished Grant");
        check(!runtime_fail_closed && r19_grant_reservation.awaiting_grant() &&
                  !r19_reserved_grant_action_valid &&
                  !e220_writer_arbiter.write_active() &&
                  r19_grant_reservation.peek_reply() == nullptr &&
                  r19_grant_reservation.cancellation_available() &&
                  tdd_controller.cycle_id() == 3U &&
                  e220_serial.normal_tx_bytes().empty(),
              "unpublished urgent slot retires without Prepared, UART or cancellation-budget use");
        if (test == "defer-prepared-budget") {
          fake_arduino::advance_time_ms(original_prepare_ms + 8001U - monotonic_now_ms());
          r19_tick_grant_reservation();
          check(runtime_fail_closed && r19_grant_reservation.snapshot().reason ==
                    R19GrantReservationReason::PrepareExpired,
                "deferral never resets original eight-second prepare deadline");
        } else {
          const auto hb_action = tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
          check(hb_action.type == LinkActionType::SendRadioData,
                "late Heartbeat is selected before a replacement Grant");
          process_action(hb_action, monotonic_now_ms());
          fake_arduino::set_pin_input_level(D8, LOW);
          observe_radio_completion(monotonic_now_ms());
          fake_arduino::advance_time_ms(530U);
          fake_arduino::set_pin_input_level(D8, HIGH);
          observe_radio_completion(monotonic_now_ms());
          fake_arduino::advance_time_ms(20U);
          observe_radio_completion(monotonic_now_ms());
          LinkAction fresh{};
          for (unsigned i = 0U; i < 5U && fresh.type == LinkActionType::None; ++i) {
            fake_arduino::advance_time_ms(1U);
            r19_observe_e220_aux(monotonic_now_ms());
            fresh = tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
          }
          check(fresh.type == LinkActionType::SendGrant && fresh.token != action.token &&
                    fresh.control.cycle_id == 3U,
                "replacement Grant uses a new real TDD cycle and token");
          check(r19_hold_generated_grant(fresh, monotonic_now_ms()) &&
                    !runtime_fail_closed && r19_reserved_grant_action_valid &&
                    r19_grant_reservation.hold_deadline_ms() == monotonic_now_ms() + 750U &&
                    r19_grant_reservation.cancellation_available(),
                "only replacement after Heartbeat tail becomes Prepared with unchanged750ms hold");
        }
        goto done;
      }
      check(r19_hold_generated_grant(action, monotonic_now_ms()), "actual bridge holds issued Grant");
      selected_token = action.token;
      selected_generation = standard_radio_writer_lease.writer_generation;
      check(r19_reserved_grant_action_valid && e220_writer_arbiter.write_active(),
            "one real StandardTdd lease owns unsent Grant");
      drain();
      auto bind = tuple_command(Op::BindPeerVehicle, Role::Vehicle);
      bind.boot_id = 111U; bind.usb_epoch = 19U; send(bind);
      const auto before = e220_serial.normal_tx_bytes().size();
      if (test == "release-without-commit") {
        send(tuple_command(Op::ReleaseGrant, Role::Vehicle));
        check(runtime_fail_closed && e220_serial.normal_tx_bytes().size() == before,
              "Bound alone cannot release Grant before Commit");
        goto done;
      }
      send(tuple_command(kCommit, Role::Vehicle));
      check(!runtime_fail_closed && reply_is(20U), "Vehicle exact Commit queues CommitAck");
      drain();
      if (test == "abort-wrong-identity") {
        const auto lease = e220_writer_arbiter.active_lease();
        auto invalid = tuple_command(kAbort, Role::Vehicle); ++invalid.action_token;
        send(invalid);
        check(runtime_fail_closed && !reply_is(22U) && r19_reserved_grant_action_valid &&
                  e220_writer_arbiter.write_active() &&
                  e220_writer_arbiter.active_lease().action_token == lease.action_token &&
                  e220_writer_arbiter.active_lease().writer_generation == lease.writer_generation &&
                  tdd_controller.cycle_id() == 2U,
              "wrong Abort identity is rejected before retiring real Vehicle lease or cycle");
        goto done;
      }
      if (test == "failed-loop-abort") {
        (void)r19_grant_reservation.abort(R19GrantReservationReason::WrongEpoch,
                                        monotonic_now_ms(), 77U);
        latch_runtime_fail_closed_at(0xA910U);
        const auto first = r19_grant_reservation.snapshot();
        const auto first_runtime = r19_runtime_fail_latch.evidence();
        send(tuple_command(kAbort, Role::Vehicle));
        for (unsigned i = 0U; i < 40U; ++i) {
          fake_arduino::advance_time_ms(1U); loop_bridge();
        }
        const auto& after = r19_grant_reservation.snapshot();
        const auto& after_runtime = r19_runtime_fail_latch.evidence();
        check(runtime_fail_closed && !bridge_ready &&
                  r19_grant_reservation.terminal_aborted() &&
                  r19_grant_reservation.terminal_abort_ack_committed() &&
                  first.state == after.state && first.reason == after.reason &&
                  first.event_count == after.event_count && first.journal_count == after.journal_count &&
                  first.ground_t0_ms == after.ground_t0_ms && first.frozen == after.frozen &&
                  first_runtime.source_line == after_runtime.source_line &&
                  first_runtime.monotonic_ms == after_runtime.monotonic_ms &&
                  first_runtime.status == after_runtime.status &&
                  !r19_reserved_grant_action_valid && !e220_writer_arbiter.write_active(),
              "Failed Vehicle actual loop publishes cleanup AbortAck without clearing first fault or restoring runtime");
        goto done;
      }
      if (test == "commit") {
        send(tuple_command(Op::ReleaseGrant, Role::Vehicle));
        (void)r19_service_reserved_grant(monotonic_now_ms());
        check(!runtime_fail_closed && r19_reserved_grant_uart_accepted &&
                  e220_serial.normal_tx_bytes().size() == before + 32U,
              "committed exact Grant can release once, not private bytes");
      } else {
        if (test == "abort-after-withdrawal" ||
            test == "abort-after-withdrawal-data" ||
            test == "abort-after-withdrawal-writer-owner" ||
            test == "abort-after-withdrawal-writer-mismatch") {
          const auto frame = heartbeat();
          fake_arduino::advance_time_ms(154U);
          for (std::size_t i = 0U; i < frame.size; ++i)
            (void)vehicle_scheduler.ingest_byte(frame.bytes[i], monotonic_now_ms());
          (void)r19_service_reserved_grant(monotonic_now_ms());
          check(!runtime_fail_closed && !r19_reserved_grant_action_valid &&
                    r19_grant_reservation.cancellation_pending(),
                "new Heartbeat safely retires committed old Grant before abort reconciliation");
          drain();
          if (test != "abort-after-withdrawal") {
            const auto data = tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
            check(data.type == LinkActionType::SendRadioData,
                  "retired Grant yields to actual retained Heartbeat data action");
            process_action(data, monotonic_now_ms());
            const auto lease = e220_writer_arbiter.active_lease();
            const auto bytes = e220_serial.normal_tx_bytes().size();
            const auto cycle = tdd_controller.cycle_id();
            check(radio_busy && standard_radio_writer_tail_pending && lease.valid() &&
                      lease.action_token != selected_token &&
                      lease.writer_generation != selected_generation && bytes > before,
                  "new standard data has its own real accepted UART and writer lease");
            if (test == "abort-after-withdrawal-writer-mismatch")
              ++standard_radio_writer_lease.writer_generation;
            if (test == "abort-after-withdrawal-writer-owner")
              standard_radio_writer_lease.owner = static_cast<Phase6RadioWriterOwner>(2U);
            send(tuple_command(kAbort, Role::Vehicle));
            if (test == "abort-after-withdrawal-writer-mismatch" ||
                test == "abort-after-withdrawal-writer-owner") {
              check(runtime_fail_closed && !reply_is(22U),
                    "retirement cannot excuse mismatched active standard data lease");
            } else {
              check(!runtime_fail_closed && r19_grant_reservation.terminal_aborted() &&
                        reply_is(22U),
                    "retired exact old Grant can ACK abort while unrelated standard data is active");
              check(radio_busy && standard_radio_writer_tail_pending &&
                        e220_writer_arbiter.active_lease().action_token == lease.action_token &&
                        e220_writer_arbiter.active_lease().writer_generation == lease.writer_generation &&
                        standard_radio_writer_lease.action_token == lease.action_token &&
                        standard_radio_writer_lease.writer_generation == lease.writer_generation &&
                        tdd_controller.cycle_id() == cycle &&
                        e220_serial.normal_tx_bytes().size() == bytes,
                    "abort never retires, completes or modifies the unrelated data writer");
              drain();
              send(tuple_command(kAbort, Role::Vehicle));
              check(!runtime_fail_closed && r19_grant_reservation.peek_reply() == nullptr &&
                        r19_grant_reservation.terminal_abort_ack_committed(),
                    "duplicate abort remains idempotent during unrelated data tail");
              fake_arduino::set_pin_input_level(D8, LOW);
              observe_radio_completion(monotonic_now_ms());
              fake_arduino::advance_time_ms(530U);
              fake_arduino::set_pin_input_level(D8, HIGH);
              observe_radio_completion(monotonic_now_ms());
              fake_arduino::advance_time_ms(20U);
              observe_radio_completion(monotonic_now_ms());
              check(!runtime_fail_closed && !radio_busy &&
                        !e220_writer_arbiter.write_active() &&
                        !r19_grant_reservation.should_release() &&
                        e220_serial.normal_tx_bytes().size() == bytes,
                    "normal data tail completes naturally with old Grant authority still dead");
            }
            goto done;
          }
        }
        if (test == "unsafe-uart") {
          send(tuple_command(Op::ReleaseGrant, Role::Vehicle));
          (void)r19_service_reserved_grant(monotonic_now_ms());
          check(r19_reserved_grant_uart_accepted, "unsafe abort fixture has actual accepted Grant UART bytes");
        }
        if (test == "unsafe-busy") radio_busy = true;
        if (test == "unsafe-tail") standard_radio_writer_tail_pending = true;
        if (test == "unsafe-epoch") Serial.simulate_tx_loss();
        auto abort = tuple_command(kAbort, Role::Vehicle);
        send(abort);
        if (test.rfind("unsafe-", 0U) == 0U) {
          check(runtime_fail_closed && !reply_is(22U),
                "unsafe Vehicle boundary cannot claim AbortAck");
        } else {
          check(!runtime_fail_closed && reply_is(22U) &&
                    !r19_reserved_grant_action_valid && !e220_writer_arbiter.write_active() &&
                    tdd_controller.cycle_id() == 3U &&
                    e220_serial.normal_tx_bytes().size() == before,
                "safe Vehicle abort retires exact old cycle and lease once with zero RF");
          if (test == "abort-prefix-fault") {
            Serial.set_tx_checked_accept_limit(16U);
            const auto usb_before = Serial.tx_bytes().size();
            (void)r19_service_grant_reservation_reply();
            check(Serial.tx_bytes().size() == usb_before + 16U &&
                      !r19_grant_reservation.terminal_abort_ack_committed(),
                  "partial Vehicle AbortAck is not host-publication proof");
            fake_arduino::advance_time_ms(106U);
            (void)r19_service_grant_reservation_reply();
            check(runtime_fail_closed && r19_grant_reservation_reply_fault &&
                      !r19_grant_reservation.terminal_abort_ack_committed() &&
                      Serial.tx_bytes().size() == usb_before + 16U,
                  "Vehicle AbortAck prefix timeout never replays or claims committed ACK");
            goto done;
          }
          drain();
          const auto cycle = tdd_controller.cycle_id();
          fake_arduino::advance_time_ms(8001U); r19_tick_grant_reservation();
          check(!runtime_fail_closed && tdd_controller.cycle_id() == cycle &&
                    !r19_grant_reservation.should_release() &&
                    !r19_grant_reservation.ground_request_allowed(),
                "terminal abort neither expires as old prepare nor revives old permission");
          const auto after = e220_serial.normal_tx_bytes().size();
          send(tuple_command(Op::ReleaseGrant, Role::Vehicle));
          (void)r19_service_reserved_grant(monotonic_now_ms());
          check(e220_serial.normal_tx_bytes().size() == after &&
                    !r19_grant_reservation.should_release(), "post-abort Release cannot revive old RF action");
        }
      }
    }
#else
    arm_ground_usb();
    check(r19_grant_reservation.initialize(Role::Ground,
              r19_grant_reservation_boot_id, Serial.txLossEpoch(), monotonic_now_ms()),
          "independent prior ARM initialization fixture");
    send(command(Op::HelloRequest, Role::Ground));
    TddControlMessage grant{}; grant.type = ControlType::UlGrant;
    grant.session_id = 640U; grant.cycle_id = 1U;
    r19_observe_ground_grant(grant, ControlDisposition::Accepted, monotonic_now_ms()); drain();
    check(!runtime_fail_closed, "wirev3 Ground Hello and actual baseline callback accepted");
    if (runtime_fail_closed) goto done;
    send(tuple_command(Op::BindGround, Role::Ground));
    auto peer = tuple_command(Op::BindPeerGround, Role::Ground);
    peer.boot_id = 111U; peer.usb_epoch = 19U; send(peer); drain();
    check(!r19_grant_reservation.ground_request_allowed(), "Bound alone does not admit PARAM in agreement mode");
    {
      const auto request = parameter_request();
      if (test == "request-without-commit") {
        (void)r19_intercept_ground_usb_frame(request, monotonic_now_ms());
        check(runtime_fail_closed && !r19_product_route_selected &&
                  !r19_held_parameter_request_valid,
              "uncommitted PARAM is consumed without creating Held or a new origin");
        goto done;
      }
      auto commit = tuple_command(kCommit, Role::Ground);
      if (test == "commit-wrong-tuple") ++commit.action_token;
      send(commit);
      if (test == "commit-wrong-tuple") {
        check(runtime_fail_closed && !reply_is(20U), "stale Commit never grants local PARAM authority");
        goto done;
      }
      check(!runtime_fail_closed && reply_is(20U) &&
                r19_grant_reservation.ground_request_allowed(), "Ground exact Commit opens conditional local admission");
      drain();
      r19_have_ground_usb_heartbeat_commit = true;
      r19_last_ground_usb_heartbeat_commit_ms = monotonic_now_ms();
      const auto t0 = monotonic_now_ms();
      if (test != "abort-preheld") {
        check(r19_intercept_ground_usb_frame(request, t0) &&
                  r19_product_route_selected && !runtime_fail_closed &&
                  r19_ground_adapter->t0_ms() == t0,
              "one actual canonical PARAM becomes Held at immutable t0");
        drain();
      }
      if (test == "commit") {
        fake_arduino::advance_time_ms(501U);
        r19_service_high_speed_product_route(monotonic_now_ms());
        check(runtime_fail_closed && r19_ground_adapter->t0_ms() == t0,
              "no fresh Grant still fails at original501ms; Commit is not deadline extension");
        goto done;
      }
      if (test == "abort-after-grant-deadline") {
        fake_arduino::advance_time_ms(501U);
        r19_service_high_speed_product_route(monotonic_now_ms());
        check(runtime_fail_closed && r19_ground_adapter->failure_latched() &&
                  r19_ground_adapter->diagnostics().owner_last_error ==
                      BulkSessionResult::GrantDeadlineExceeded,
              "real no-Grant501ms failure occurs before late cleanup");
        const auto first = r19_grant_reservation.snapshot();
        const auto fault = r19_runtime_fail_latch.evidence();
        const auto adapter = r19_ground_adapter->diagnostics();
        send(tuple_command(kAbort, Role::Ground));
        check(reply_is(22U) && r19_grant_reservation.terminal_aborted() &&
                  !r19_product_route_selected && !r19_held_parameter_request_valid &&
                  r19_acceleration_consumed,
              "late exact abort quarantines never-negotiated expired Ground request and ACKs");
        drain();
        fake_arduino::advance_time_ms(1000U);
        r19_service_high_speed_product_route(monotonic_now_ms());
        const auto& after = r19_grant_reservation.snapshot();
        const auto& fault_after = r19_runtime_fail_latch.evidence();
        check(runtime_fail_closed && !bridge_ready &&
                  after.state == first.state && after.reason == first.reason &&
                  after.event_count == first.event_count &&
                  fault_after.source_line == fault.source_line &&
                  fault_after.monotonic_ms == fault.monotonic_ms &&
                  r19_ground_adapter->diagnostics().observed_ms == adapter.observed_ms &&
                  r19_ground_adapter->t0_ms() == t0 &&
                  r19_held_parameter_request_origin_ms == t0 &&
                  r19_grant_reservation.terminal_abort_ack_committed(),
              "late cleanup preserves first fault, adapter deadline/t0 and permanent failure");
        goto done;
      }
      if (test == "abort-wrong-identity") {
        auto invalid = tuple_command(kAbort, Role::Ground); ++invalid.writer_generation;
        send(invalid);
        check(runtime_fail_closed && !reply_is(22U) &&
                  !r19_grant_reservation.terminal_aborted() &&
                  r19_ground_adapter->t0_ms() == t0 &&
                  r19_held_parameter_request_origin_ms == t0,
              "wrong Abort identity cannot quarantine or change original Ground owner");
        goto done;
      }
      if (test == "failed-loop-abort") {
        (void)r19_grant_reservation.abort(R19GrantReservationReason::WrongEpoch,
                                        monotonic_now_ms(), 77U);
        latch_runtime_fail_closed_at(0xA910U);
        const auto first = r19_grant_reservation.snapshot();
        const auto first_runtime = r19_runtime_fail_latch.evidence();
        send(tuple_command(kAbort, Role::Ground));
        for (unsigned i = 0U; i < 40U; ++i) {
          fake_arduino::advance_time_ms(1U); loop_bridge();
        }
        const auto& after = r19_grant_reservation.snapshot();
        const auto& after_runtime = r19_runtime_fail_latch.evidence();
        check(runtime_fail_closed && !bridge_ready &&
                  r19_grant_reservation.terminal_aborted() &&
                  r19_grant_reservation.terminal_abort_ack_committed() &&
                  first.state == after.state && first.reason == after.reason &&
                  first.event_count == after.event_count && first.journal_count == after.journal_count &&
                  first.ground_t0_ms == after.ground_t0_ms && first.frozen == after.frozen &&
                  first_runtime.source_line == after_runtime.source_line &&
                  first_runtime.monotonic_ms == after_runtime.monotonic_ms &&
                  first_runtime.status == after_runtime.status &&
                  r19_ground_adapter->t0_ms() == t0 &&
                  r19_held_parameter_request_origin_ms == t0,
              "Failed Ground actual loop publishes cleanup AbortAck without clearing first fault or original t0");
        goto done;
      }
      if (test == "unsafe-busy") radio_busy = true;
      if (test == "unsafe-pending") pending_radio_action.active = true;
      if (test == "unsafe-tail") standard_radio_writer_tail_pending = true;
      if (test == "unsafe-frozen") r19_standard_tdd_frozen = true;
      if (test == "unsafe-negotiation") r19_grant_reservation_negotiation_started = true;
      if (test == "unsafe-session") r19_session_owners_constructed = true;
      if (test == "unsafe-usb") r19_ground_usb_commit_active = true;
      if (test == "unsafe-high-speed") (void)e220_writer_arbiter.activate_high_speed();
      if (test == "unsafe-writer") {
        Phase6RadioWriterLease lease{};
        (void)e220_writer_arbiter.request(Phase6RadioWriterOwner::StandardTdd, 91U, lease);
      }
      if (test == "unsafe-ingress") (void)ground_ingress.admit_validated_frame(heartbeat());
      if (test == "unsafe-proxy") ground_proxy_request_admitted = true;
      if (test == "unsafe-origin") ++r19_held_parameter_request_origin_ms;
      if (test == "unsafe-epoch") Serial.simulate_tx_loss();
      const auto before = e220_serial.normal_tx_bytes().size();
      send(tuple_command(kAbort, Role::Ground));
      if (test.rfind("unsafe-", 0U) == 0U) {
        check(runtime_fail_closed && !reply_is(22U), "unsafe Ground boundary cannot claim AbortAck");
        check(e220_serial.normal_tx_bytes().size() == before, "unsafe Abort never emits RF or fallback request");
      } else {
        check(!runtime_fail_closed && reply_is(22U) && !r19_product_route_selected &&
                  r19_acceleration_consumed && !r19_held_parameter_request_valid &&
                  !r19_standard_tdd_frozen && r19_standard_tdd_tick_allowed(),
              "safe Ground abort consumes acceleration without disabling normal TDD");
        if (test == "abort-prefix-fault") {
          Serial.set_tx_checked_accept_limit(16U);
          const auto usb_before = Serial.tx_bytes().size();
          (void)r19_service_grant_reservation_reply();
          check(Serial.tx_bytes().size() == usb_before + 16U &&
                    !r19_grant_reservation.terminal_abort_ack_committed(),
                "partial Ground AbortAck is not host-publication proof");
          fake_arduino::advance_time_ms(106U);
          (void)r19_service_grant_reservation_reply();
          check(runtime_fail_closed && r19_grant_reservation_reply_fault &&
                    !r19_grant_reservation.terminal_abort_ack_committed() &&
                    Serial.tx_bytes().size() == usb_before + 16U,
                "Ground AbortAck prefix timeout never replays or claims committed ACK");
          goto done;
        }
        drain();
        if (test != "abort-preheld")
          check(r19_ground_adapter->t0_ms() == t0 &&
                    r19_held_parameter_request_origin_ms == t0,
                "attempted abort retains original adapter and stored request t0");
        const auto before_tick = r19_ground_adapter->diagnostics().observed_ms;
        fake_arduino::advance_time_ms(8001U);
        r19_tick_grant_reservation(); r19_service_high_speed_product_route(monotonic_now_ms());
        grant.cycle_id = 3U;
        r19_observe_ground_grant(grant, ControlDisposition::Accepted, monotonic_now_ms());
        check(!runtime_fail_closed && r19_ground_adapter->diagnostics().observed_ms == before_tick &&
                  r19_standard_tdd_tick_allowed(),
              "terminal abort prevents old owner tick/grant from causing late501ms failure");
        const auto frame = heartbeat();
        const auto rf = encode_link_data(frame.bytes.data(), frame.size,
                                        FixedFirmwareContract::radio_chunk_bytes);
        e220_serial.inject_rx(rf.wire_bytes.data(), rf.wire_size);
        deliver_radio_bytes(monotonic_now_ms());
        check(!runtime_fail_closed && ground_usb_heartbeat_pacer.queued() == 1U,
              "real normal RF Heartbeat is still validated and retained after abort");
        const auto usb_before = Serial.tx_bytes().size();
        const auto hb_started_ms = monotonic_now_ms();
        for (unsigned i = 0U; i < 4U; ++i) {
          service_ground_usb_heartbeat_pacer(monotonic_now_ms());
          pump_ground_usb_egress(monotonic_now_ms());
          observe_ground_paced_heartbeat_commit(monotonic_now_ms());
        }
        MavlinkStreamParser parser{};
        unsigned public_frames = 0U;
        unsigned parser_errors = 0U;
        for (std::size_t i = usb_before; i < Serial.tx_bytes().size(); ++i) {
          MavlinkFrame public_frame{};
          const auto status = parser.push(Serial.tx_bytes()[i], public_frame);
          if (status == MavlinkParseStatus::FrameReady) {
            ++public_frames;
            check(public_frame.message_id == 0U && public_frame.size == frame.size &&
                      std::equal(frame.bytes.begin(), frame.bytes.begin() + frame.size,
                                 public_frame.bytes.begin()),
                  "post-abort public USB contains only the exact normal Heartbeat");
          } else if (status != MavlinkParseStatus::NeedMore) ++parser_errors;
        }
        check(!runtime_fail_closed && public_frames == 1U && parser_errors == 0U &&
                  !ground_paced_heartbeat_commit_active &&
                  r19_last_ground_usb_heartbeat_commit_ms >= hb_started_ms &&
                  r19_last_ground_usb_heartbeat_commit_ms - hb_started_ms <= 106U &&
                  kGroundUsbHeartbeatCommitDeadlineMs == 106U,
              "actual normal USB Heartbeat completes after abort without weakening106ms");
        (void)r19_intercept_ground_usb_frame(request, monotonic_now_ms());
        check(!r19_product_route_selected && ground_ingress.empty() &&
                  e220_serial.normal_tx_bytes().size() == before,
              "post-abort second PARAM cannot rearm, retry, or enter standard fallback");
      }
    }
#endif
  }
done:
  std::cout << "actual bridge agreement case=" << test
#if defined(AGREEMENT_TEST_VEHICLE)
            << " role=Vehicle"
#else
            << " role=Ground"
#endif
            << " checks=" << checks << " failures=" << failures << '\n';
  return failures == 0U ? 0 : 1;
}
