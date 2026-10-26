// Actual bridge regression: fatal observation must not alter the one-cancellation policy.
#define VC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS 1
#define AGREEMENT_TEST_VEHICLE 1
#define main existing_agreement_fixture_main
#include "phase6_grant_agreement_flow_tests.cpp"
#undef main
#include <fstream>

namespace {
void advance_to(std::uint64_t target) {
  check(target >= monotonic_now_ms(), "probe time is monotonic");
  if (target >= monotonic_now_ms())
    fake_arduino::advance_time_ms(target - monotonic_now_ms());
}

void inject_heartbeat() {
  const auto frame = heartbeat();
  for (std::size_t i = 0U; i < frame.size; ++i)
    (void)vehicle_scheduler.ingest_byte(frame.bytes[i], monotonic_now_ms());
}

R19GrantReservationWireMessage exact(Op opcode, std::uint64_t nonce,
                                     const LinkAction& action,
                                     std::uint32_t generation) {
  auto value = command(opcode, Role::Vehicle);
  value.slot_nonce = nonce;
  value.grant_session = action.control.session_id;
  value.grant_cycle = action.control.cycle_id;
  value.action_token = action.token;
  value.writer_generation = generation;
  return value;
}

R19GrantReservationStopSnapshot stop_snapshot() {
  using Stop = R19GrantReservationStopSnapshot;
  const auto now = monotonic_now_ms();
  const auto input = make_tdd_input(now);
  const auto lease = e220_writer_arbiter.active_lease();
  Stop stop{};
  stop.now_ms = now;
  stop.heartbeat_deadline_ms = input.heartbeat_deadline_ms;
  stop.hold_deadline_ms = r19_grant_reservation.hold_deadline_ms();
  stop.heartbeat_order = input.heartbeat_order;
  stop.reserve_ms = FixedFirmwareContract::heartbeat_grant_reserve_ms;
  stop.expected_token = r19_reserved_grant_action.token;
  stop.expected_generation = standard_radio_writer_lease.writer_generation;
  stop.active_token = lease.action_token;
  stop.active_generation = lease.writer_generation;
  stop.active_owner = static_cast<std::uint32_t>(lease.owner);
  stop.current_usb_epoch = Serial.txLossEpoch();
  stop.predicates = (input.heartbeat_deadline_valid ? Stop::heartbeat_valid : 0U) |
      (input.heartbeat_tail_available ? Stop::heartbeat_available : 0U) |
      (input.aux_high ? Stop::aux_high : 0U) | (lease.valid() ? Stop::lease_valid : 0U) |
      (r19_grant_reservation.failed() ? Stop::reservation_failed : 0U) |
      (radio_busy ? Stop::radio_busy : 0U) |
      (pending_radio_action.active ? Stop::pending_action : 0U) |
      (standard_radio_writer_tail_pending ? Stop::tail_pending : 0U) |
      (r19_grant_reservation.should_release() ? Stop::release_requested : 0U);
  return stop;
}

void event(const char* label) {
  const auto input = make_tdd_input(monotonic_now_ms());
  const auto stop = stop_snapshot();
  const auto& reservation = r19_grant_reservation.snapshot();
  const auto& record = vc_lora_r19_grant_reservation_stop_record;
  const auto lease = e220_writer_arbiter.active_lease();
  std::cout << "{\"event\":\"" << label << "\",\"now_ms\":" << monotonic_now_ms()
      << ",\"hold_deadline_ms\":" << r19_grant_reservation.hold_deadline_ms()
      << ",\"heartbeat_valid\":" << input.heartbeat_deadline_valid
      << ",\"heartbeat_available\":" << input.heartbeat_tail_available
      << ",\"heartbeat_deadline_ms\":" << input.heartbeat_deadline_ms
      << ",\"reserve_ms\":" << stop.reserve_ms
      << ",\"transient_stop_reason\":" << static_cast<unsigned>(r19_grant_reservation_stop_reason(stop))
      << ",\"predicates\":" << stop.predicates
      << ",\"cancellation_available\":" << r19_grant_reservation.cancellation_available()
      << ",\"cancellation_phase\":" << static_cast<unsigned>(r19_grant_reservation.cancellation_phase())
      << ",\"agreement_committed\":" << r19_grant_reservation.agreement_committed()
      << ",\"reservation_state\":" << static_cast<unsigned>(reservation.state)
      << ",\"reservation_reason\":" << static_cast<unsigned>(reservation.reason)
      << ",\"runtime_fail_closed\":" << runtime_fail_closed
      << ",\"reserved_action_valid\":" << r19_reserved_grant_action_valid
      << ",\"grant_uart_accepted\":" << r19_reserved_grant_uart_accepted
      << ",\"radio_busy\":" << radio_busy
      << ",\"pending_radio_action\":" << pending_radio_action.active
      << ",\"tail_pending\":" << standard_radio_writer_tail_pending
      << ",\"lease_valid\":" << lease.valid()
      << ",\"lease_owner\":" << static_cast<unsigned>(lease.owner)
      << ",\"expected_token\":" << stop.expected_token
      << ",\"active_token\":" << lease.action_token
      << ",\"expected_generation\":" << stop.expected_generation
      << ",\"active_generation\":" << lease.writer_generation
      << ",\"rf_uart_bytes\":" << e220_serial.normal_tx_bytes().size()
      << ",\"stop_status\":" << record.words[13U]
      << ",\"stop_first_reason\":" << record.words[15U]
      << ",\"stop_first_time_ms\":" << record.words[16U]
      << ",\"tdd_cycle\":" << tdd_controller.cycle_id()
      << ",\"action_retries\":" << link_diagnostics.action_retries << "}\n";
}
}  // namespace

int main(int argc, char** argv) {
  const std::string scenario = argc > 1 ? argv[1] : "repeat-heartbeat";
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true); Serial.set_endpoint_ready(true);
  setup_bridge();
  check(bridge_ready && !runtime_fail_closed, "actual bridge is ready");
  r19_vehicle_usb_clock_seen = true;
  send(command(Op::HelloRequest, Role::Vehicle)); drain();
  advance_to(32949U);
  auto prepare = command(Op::PrepareVehicle, Role::Vehicle);
  prepare.grant_session = 640U; prepare.grant_cycle = 2U; send(prepare);
  tdd_controller.reset(640U, 3U, monotonic_now_ms());
  fake_arduino::advance_time_ms(3000U); r19_observe_e220_aux(monotonic_now_ms());
  (void)tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
  fake_arduino::advance_time_ms(16U); r19_observe_e220_aux(monotonic_now_ms());
  (void)tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
  fake_arduino::advance_time_ms(1U); r19_observe_e220_aux(monotonic_now_ms());
  const auto old_action = tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
  check(old_action.type == LinkActionType::SendGrant && old_action.control.cycle_id == 3U,
        "old real TDD Grant action issued at35966");
  check(r19_hold_generated_grant(old_action, monotonic_now_ms()), "actual old Grant held");
  const auto old_generation = standard_radio_writer_lease.writer_generation;
  const auto old_deadline = r19_grant_reservation.hold_deadline_ms(); drain();
  auto bind = exact(Op::BindPeerVehicle, kNonce, old_action, old_generation);
  bind.boot_id = 111U; bind.usb_epoch = 19U; send(bind); drain();
  send(exact(kCommit, kNonce, old_action, old_generation)); drain();
  event("old-committed");
  advance_to(36099U); inject_heartbeat();
  event("before-first-heartbeat-service");
  (void)r19_service_reserved_grant(monotonic_now_ms());
  check(!runtime_fail_closed && !r19_reserved_grant_action_valid &&
        r19_grant_reservation.cancellation_pending() &&
        vc_lora_r19_grant_reservation_stop_record.words[13U] == 15U &&
        e220_serial.normal_tx_bytes().empty(), "first Heartbeat safely cancels with zero RF UART");
  event("first-safe-cancel"); drain();
  send(exact(Op::CancelRequest, kNonce, old_action, old_generation)); drain();
  auto peer = exact(Op::CancelPeerConfirmed, kNonce, old_action, old_generation);
  peer.boot_id = 111U; peer.usb_epoch = 19U; peer.device_ms = 123U; send(peer); drain();
  constexpr auto fresh_nonce = kNonce + 1U;
  auto hello = command(Op::HelloRequest, Role::Vehicle); hello.slot_nonce = fresh_nonce;
  send(hello); drain();
  auto fresh_prepare = command(Op::PrepareVehicle, Role::Vehicle);
  fresh_prepare.slot_nonce = fresh_nonce; fresh_prepare.grant_session = 640U;
  fresh_prepare.grant_cycle = 3U; send(fresh_prepare);
  check(r19_grant_reservation.awaiting_grant() && !runtime_fail_closed,
        "fresh nonce prepares without resetting original preparation clock");
  std::array<std::uint8_t, 32U> selected{};
  check(vehicle_scheduler.peek(selected.data(), selected.size()) == heartbeat().size,
        "retained real Heartbeat selected before fresh Grant");
  const auto hb_action = tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
  check(hb_action.type == LinkActionType::SendRadioData, "actual TDD selects Heartbeat tail");
  process_action(hb_action, monotonic_now_ms());
  fake_arduino::set_pin_input_level(D8, LOW); observe_radio_completion(monotonic_now_ms());
  fake_arduino::advance_time_ms(530U); fake_arduino::set_pin_input_level(D8, HIGH);
  observe_radio_completion(monotonic_now_ms());
  fake_arduino::advance_time_ms(20U); observe_radio_completion(monotonic_now_ms());
  LinkAction fresh_action{};
  for (unsigned i = 0U; i < 5U && fresh_action.type == LinkActionType::None; ++i) {
    fake_arduino::advance_time_ms(1U); r19_observe_e220_aux(monotonic_now_ms());
    fresh_action = tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
  }
  check(fresh_action.type == LinkActionType::SendGrant &&
        fresh_action.control.cycle_id == 4U && fresh_action.token > old_action.token,
        "fresh actual TDD Grant strictly advances cycle and token");
  check(monotonic_now_ms() == 36652U, "fresh Grant timing matches observed36652");
  check(r19_hold_generated_grant(fresh_action, monotonic_now_ms()), "actual fresh Grant held");
  const auto fresh_generation = standard_radio_writer_lease.writer_generation;
  const auto fresh_deadline = r19_grant_reservation.hold_deadline_ms();
  check(fresh_deadline == 37402U && fresh_deadline > old_deadline,
        "fresh hold overwrites old deadline36716 with37402");
  check(!r19_grant_reservation.cancellation_available(),
        "one-cancellation budget remains consumed after fresh nonce");
  event("fresh-prepared"); drain();
  advance_to(36698U);
  auto fresh_bind = exact(Op::BindPeerVehicle, fresh_nonce, fresh_action, fresh_generation);
  fresh_bind.boot_id = 111U; fresh_bind.usb_epoch = 19U; send(fresh_bind); drain();
  advance_to(36823U); send(exact(kCommit, fresh_nonce, fresh_action, fresh_generation)); drain();
  check(!runtime_fail_closed && r19_grant_reservation.agreement_committed(),
        "fresh exact agreement commits before later Heartbeat");
  event("fresh-committed");
  advance_to(37100U);
  const auto rf_before = e220_serial.normal_tx_bytes().size();
  const auto retries_before = link_diagnostics.action_retries;
  if (scenario == "repeat-heartbeat" || scenario == "heartbeat-aux-fault" || scenario == "heartbeat-lease-fault") inject_heartbeat();
  if (scenario == "aux-fault" || scenario == "heartbeat-aux-fault") fake_arduino::set_pin_input_level(D8, LOW);
  if (scenario == "lease-fault" || scenario == "heartbeat-lease-fault") e220_writer_arbiter = {};
  event("before-second-service");
  (void)r19_service_reserved_grant(monotonic_now_ms());
  event("after-second-service");
  if (scenario == "repeat-heartbeat" || scenario == "aux-fault" || scenario == "lease-fault" ||
      scenario == "heartbeat-aux-fault" || scenario == "heartbeat-lease-fault") {
    const auto& fatal = vc_lora_r19_grant_reservation_fatal_record;
    const auto expected_reason = (scenario == "repeat-heartbeat" || scenario.rfind("heartbeat-",0U)==0U) ? 2U : (scenario == "aux-fault" ? 3U : 4U);
    check(fatal.words[1U] == 4U && (fatal.words[15U] & 0xFFU) == expected_reason &&
          ((fatal.words[15U] >> 8U) & 0xFFU) == 13U && fatal.words[16U] == 37100U &&
          fatal.words[20U] == 37402U, "first fatal captures original predicate before abort");
    if (scenario == "repeat-heartbeat")
      check(((fatal.words[13U] >> 8U) & 2U) == 0U && (fatal.words[15U] >> 24U) == 3U &&
            ((fatal.words[15U] >> 16U) & 0xFFU) == 1U &&
            ((fatal.words[13U] >> 8U) & 32U) == 0U,
            "next Heartbeat records unavailable cancellation FreshRound and no Grant UART");
    if (scenario.rfind("heartbeat-",0U)==0U)
      check(((fatal.words[15U]>>16U)&0xFFU)==18U &&
            ((scenario=="heartbeat-aux-fault" && (fatal.words[22U]&4U)==0U) ||
             (scenario=="heartbeat-lease-fault" && (fatal.words[22U]&8U)==0U)),
            "compound HB fault retains HB priority but rejects heartbeat-only cancellation");
    const auto& snapshot = r19_grant_reservation.snapshot();
    check(runtime_fail_closed && snapshot.reason == R19GrantReservationReason::ExternalFault &&
          snapshot.journal[snapshot.journal_count - 1U].aux == 13U &&
          e220_serial.normal_tx_bytes().size() == rf_before,
          "second Heartbeat alone produces ExternalFault detail13 with zero fresh Grant UART");
    check(vc_lora_r19_grant_reservation_stop_record.words[13U] == 15U &&
          vc_lora_r19_grant_reservation_stop_record.words[16U] == 36099U,
          "first-wins STOP still shows old SAFE_CANCEL rather than second fatal predicate");
  } else {
    check(vc_lora_r19_grant_reservation_fatal_record.words[1U] == 2U &&
          vc_lora_r19_grant_reservation_fatal_record.words[13U] == 1U,
          "no second conflict leaves independent fatal record unlatched");
    check(!runtime_fail_closed && r19_grant_reservation.holding() &&
          r19_reserved_grant_action_valid && e220_serial.normal_tx_bytes().size() == rf_before,
          "without second Heartbeat no fault at37100 after old deadline has passed");
    if (scenario == "pending-tick") {
      const auto action = tdd_controller.tick(make_tdd_input(monotonic_now_ms()));
      check(link_diagnostics.action_retries == retries_before + 1U &&
            action.type == LinkActionType::SendGrant && action.token > fresh_action.token,
            "explicit TDD tick observes aged pending action and reissues after300ms");
      event("after-counterfactual-tdd-tick");
    } else if (scenario == "release-after448") {
      send(exact(Op::ReleaseGrant, fresh_nonce, fresh_action, fresh_generation));
      (void)r19_service_reserved_grant(monotonic_now_ms());
      check(!runtime_fail_closed && r19_reserved_grant_uart_accepted &&
            e220_serial.normal_tx_bytes().size() == rf_before + 32U,
            "withheld TDD tick permits actual Grant UART admission at action age448");
      event("after-counterfactual-release");
    }
  }
  if (argc > 2) {
    const std::string out = argv[2];
    const auto write_record = [&out](const char* name, const volatile std::uint32_t* words, std::size_t count) {
      std::ofstream file(out + "/" + name, std::ios::binary);
      for (std::size_t i = 0U; i < count; ++i) {
        const auto word = words[i];
        for (unsigned b = 0U; b < 4U; ++b) file.put(static_cast<char>(word >> (b * 8U)));
      }
      check(file.good(), "raw record fixture written");
    };
    write_record("fatal.bin", vc_lora_r19_grant_reservation_fatal_record.words, 32U);
    write_record("stop.bin", vc_lora_r19_grant_reservation_stop_record.words, 32U);
    write_record("reservation.bin", vc_lora_r19_grant_reservation_record.words, 128U);
  }
  std::cout << "{\"scenario\":\"" << scenario << "\",\"checks\":" << checks
      << ",\"failures\":" << failures << ",\"scope\":\"pure-host-actual-bridge-not-hardware\"}\n";
  return failures == 0U ? 0 : 1;
}


