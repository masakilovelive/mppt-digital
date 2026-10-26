#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/runtime_contract.hpp"
#include "vc_lora/tdd_ground.hpp"
#include "vc_lora/tdd_vehicle.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <vector>

// Offline verification only. The actual standard controllers decide every
// phase/action; this harness supplies bounded, explicitly synthetic radio
// observations. In particular, a 550-ms local service floor is NOT a measured
// remote RF delivery latency. Those are independent model parameters below.
namespace {
using namespace vc_lora;

struct Checks {
  unsigned total{0U};
  unsigned failures{0U};
  void require(bool value, const char* label) {
    ++total;
    if (!value) {
      ++failures;
      std::cerr << "FAIL " << label << '\n';
    }
  }
};

TddConfig fixed_config() {
  TddConfig c{};
  c.downlink_send_ms = FixedFirmwareContract::downlink_send_ms;
  c.uplink_guard_ms = FixedFirmwareContract::uplink_guard_ms;
  c.uplink_window_ms = FixedFirmwareContract::uplink_window_ms;
  c.vehicle_receive_timeout_ms =
      FixedFirmwareContract::vehicle_receive_timeout_ms;
  c.return_guard_ms = FixedFirmwareContract::return_guard_ms;
  c.late_terminal_wait_ms = FixedFirmwareContract::late_terminal_wait_ms;
  c.aux_stable_ms = FixedFirmwareContract::aux_high_stable_ms;
  c.min_tx_gap_ms = FixedFirmwareContract::min_tx_gap_ms;
  c.radio_uart_bps = FixedFirmwareContract::e220_uart_bps;
  c.radio_air_bps = FixedFirmwareContract::e220_air_bps;
  c.action_retry_timeout_ms = FixedFirmwareContract::aux_transition_timeout_ms;
  c.heartbeat_grant_reserve_ms =
      FixedFirmwareContract::heartbeat_grant_reserve_ms;
  c.radio_chunk_bytes =
      static_cast<std::uint16_t>(FixedFirmwareContract::radio_chunk_bytes);
  return c;
}

enum class TailHint { DisabledLowerBound, AbsentHeartbeat, OneBoundaryHeartbeat };

struct Model {
  const char* name;
  std::uint64_t local_service_ms;
  std::uint64_t remote_delivery_ms;
  TailHint heartbeat;
  bool lose_terminal;
  bool mathematical_only;
};

struct Grant {
  std::uint64_t generated_ms;
  std::uint64_t sender_tail_ms;
  std::uint64_t observed_ms;
  std::uint16_t cycle;
};

struct Event {
  bool to_ground;
  TddControlMessage control;
  std::uint64_t generated_ms;
  std::uint64_t sender_tail_ms;
  std::uint64_t delivery_ms;
  bool delivered{false};
};

struct LocalWriter {
  std::uint64_t end_ms{0U};
  std::uint64_t aux_high_at_ms{0U};
  void accept(std::uint64_t now, std::uint64_t service) {
    end_ms = now + service;
    // A synthetic healthy AUX return 20 ms before the local service boundary
    // permits the real 15-ms controller stability check to overlap the floor.
    // This is neither an E220 waveform measurement nor a guarantee.
    aux_high_at_ms = now + (service > 20U ? service - 20U : 0U);
  }
  bool complete(std::uint64_t now) const { return now >= end_ms; }
  bool aux_high(std::uint64_t now) const { return now >= aux_high_at_ms; }
};

struct Simulation {
  explicit Simulation(Model m, bool one_parameter = false)
      : model(m), config(fixed_config()), vehicle(config, vehicle_diagnostics),
        ground(config, ground_diagnostics), queued(one_parameter ? 14U : 0U) {
    vehicle.reset(1U, 0U, 0U);
    ground.reset(0U);
  }

  Model model;
  TddConfig config;
  LinkDiagnostics vehicle_diagnostics{};
  LinkDiagnostics ground_diagnostics{};
  VehicleTddController vehicle;
  GroundTddController ground;
  LocalWriter vehicle_writer{};
  LocalWriter ground_writer{};
  std::vector<Event> events;
  std::vector<Grant> grants;
  std::uint32_t queued{0U};
  std::uint64_t downlink_started_ms{0U};
  bool heartbeat_tail_sent{false};
  std::uint64_t data_accepted_ms{0U};
  std::uint64_t admission_deadline_ms{0U};
  std::uint64_t transaction_deadline_ms{0U};
  std::uint64_t done_accepted_ms{0U};
  std::uint64_t done_sender_tail_ms{0U};
  std::uint64_t done_observed_ms{0U};
  unsigned accepted_terminals{0U};
  unsigned invalid_grants{0U};

  TddInput input(std::uint64_t now, const LocalWriter& writer) const {
    TddInput in{};
    in.now_ms = now;
    in.aux_high = writer.aux_high(now);
    in.radio_tx_empty = writer.complete(now);
    in.radio_tx_complete = writer.complete(now);
    in.local_tx_empty = true;
    return in;
  }

  void deliver(std::uint64_t now) {
    for (auto& e : events) {
      if (e.delivered || e.delivery_ms > now) continue;
      e.delivered = true;
      if (e.to_ground) {
        if (ground.on_control(e.control, now) == ControlDisposition::Accepted) {
          grants.push_back(
              {e.generated_ms, e.sender_tail_ms, now, e.control.cycle_id});
        } else {
          ++invalid_grants;
        }
      } else if (!model.lose_terminal) {
        if (vehicle.on_control(e.control, now) == ControlDisposition::Accepted) {
          ++accepted_terminals;
          if (e.control.type == ControlType::UlDone &&
              e.control.actual_bytes == 14U && done_observed_ms == 0U) {
            done_observed_ms = now;
          }
        }
      }
    }
  }

  void accept(bool from_vehicle, const LinkAction& action,
              std::uint64_t now) {
    if (action.type == LinkActionType::None) return;
    LocalWriter& writer = from_vehicle ? vehicle_writer : ground_writer;
    writer.accept(now, model.local_service_ms);
    if (from_vehicle) {
      vehicle.complete_action(action.token, TxResult::Accepted, now);
      if (action.type == LinkActionType::SendRadioData) heartbeat_tail_sent = true;
    } else {
      ground.complete_action(action.token, TxResult::Accepted, now);
      if (action.type == LinkActionType::SendRadioData) {
        if (data_accepted_ms == 0U) {
          data_accepted_ms = now;
          admission_deadline_ms = ground.window_deadline_ms();
          transaction_deadline_ms = ground.transaction_deadline_ms();
        }
        queued -= action.byte_budget;
      }
    }
    if (action.type == LinkActionType::SendGrant ||
        action.type == LinkActionType::SendDone) {
      events.push_back({from_vehicle, action.control, now, writer.end_ms,
                        now + model.remote_delivery_ms, false});
      if (!from_vehicle && action.control.type == ControlType::UlDone &&
          action.control.actual_bytes == 14U && done_accepted_ms == 0U) {
        done_accepted_ms = now;
        done_sender_tail_ms = writer.end_ms;
      }
    }
  }

  void run(std::uint64_t stop_ms) {
    for (std::uint64_t now = 0U; now <= stop_ms; ++now) {
      deliver(now);
      auto v = input(now, vehicle_writer);
      const bool boundary_tail =
          model.heartbeat == TailHint::OneBoundaryHeartbeat &&
          vehicle.state() == VehicleTddState::DownlinkSend &&
          now - downlink_started_ms >= config.downlink_send_ms &&
          !heartbeat_tail_sent;
      v.heartbeat_tail_enabled =
          model.heartbeat != TailHint::DisabledLowerBound;
      v.heartbeat_tail_available = boundary_tail;
      v.queued_bytes = boundary_tail ? 21U : 0U;
      const auto old_state = vehicle.state();
      accept(true, vehicle.tick(v), now);
      if (old_state == VehicleTddState::ReturnGuard &&
          vehicle.state() == VehicleTddState::DownlinkSend) {
        downlink_started_ms = now;
        heartbeat_tail_sent = false;
      }
      deliver(now);  // Permits the explicitly impossible zero-RF lower bound.
      auto g = input(now, ground_writer);
      g.queued_bytes = queued;
      g.front_frame_bytes = static_cast<std::uint16_t>(queued);
      g.next_tx_application_bytes = static_cast<std::uint16_t>(queued);
      g.next_tx_wire_bytes = queued == 0U ? 0U : 32U;
      accept(false, ground.tick(g), now);
      deliver(now);
    }
  }
};

struct PhaseSummary {
  std::uint64_t interval_ms{0U};
  std::uint64_t phases{0U};
  std::uint64_t within_500{0U};
  std::uint64_t exceed_500{0U};
  std::uint64_t maximum_wait_ms{0U};
  std::uint64_t minimum_wait_ms{std::numeric_limits<std::uint64_t>::max()};
};

PhaseSummary every_request_phase(const Grant& baseline, const Grant& next,
                                 Checks& checks) {
  PhaseSummary s{};
  s.interval_ms = next.observed_ms - baseline.observed_ms;
  // Each PARAM arrival is AFTER the baseline Grant has already been observed.
  // Thus the same session/cycle cannot be relabelled as a fresh Grant.
  for (auto arrival = baseline.observed_ms; arrival < next.observed_ms; ++arrival) {
    const auto wait = next.observed_ms - arrival;
    ++s.phases;
    if (wait <= BulkSessionTiming::grant_wait_budget_ms) ++s.within_500;
    else ++s.exceed_500;
    s.maximum_wait_ms = std::max(s.maximum_wait_ms, wait);
    s.minimum_wait_ms = std::min(s.minimum_wait_ms, wait);
    checks.require(wait > 0U, "strictly fresh next-cycle opportunity");
  }
  checks.require(s.interval_ms > 500U, "standard schedule is longer than500ms");
  checks.require(s.within_500 == 500U && s.exceed_500 == s.phases - 500U,
                 "inclusive500ms accepts exactly final500 request phases");
  checks.require(s.minimum_wait_ms == 1U && s.maximum_wait_ms == s.interval_ms,
                 "phase sweep spans every integer-ms wait");
  checks.require(next.cycle == static_cast<std::uint16_t>(baseline.cycle + 1U),
                 "opportunity is actual accepted next-cycle standard Grant");
  return s;
}

void check_admission_not_completion(Checks& checks, const Model& model,
                                    Simulation& transfer) {
  transfer.run(14000U);
  checks.require(transfer.data_accepted_ms > 0U && transfer.queued == 0U,
                 "one complete14-byte request admitted and consumed");
  checks.require(transfer.data_accepted_ms < transfer.admission_deadline_ms,
                 "first payload starts before300ms admission deadline");
  checks.require(transfer.done_sender_tail_ms > transfer.admission_deadline_ms,
                 "550ms physical service completion legitimately crosses300ms");
  checks.require(transfer.done_observed_ms > transfer.admission_deadline_ms &&
                     transfer.done_observed_ms < transfer.transaction_deadline_ms,
                 "separate DONE reaches Vehicle within bounded2000ms lease");
  checks.require(transfer.done_sender_tail_ms < transfer.transaction_deadline_ms,
                 "Ground physical DONE completion remains within2000ms lease");
  checks.require(!transfer.ground.fail_closed() &&
                     transfer.ground_diagnostics.abandoned_uplink_transactions == 0U,
                 "crossing admission deadline does not abandon started frame");
  checks.require(model.local_service_ms == 550U &&
                     transfer.transaction_deadline_ms - transfer.data_accepted_ms == 2000U,
                 "actual standard transaction budget not replaced with300ms");

  LinkDiagnostics diagnostics{};
  const auto config = fixed_config();
  GroundTddController late(config, diagnostics);
  late.reset(0U);
  TddControlMessage grant{};
  grant.session_id = 1U;
  grant.cycle_id = 1U;
  grant.guard_ms = 650U;
  grant.window_ms = 300U;
  grant.max_bytes = 64U;
  checks.require(late.on_control(grant, 1000U) == ControlDisposition::Accepted,
                 "late-start test accepts real standard Grant");
  TddInput input{};
  input.now_ms = 1000U;
  (void)late.tick(input);  // Observe AUX HIGH early enough for stability.
  input.now_ms = 1950U;  // Exactly guard650 + admission300 after Grant arrival.
  input.queued_bytes = 14U;
  input.front_frame_bytes = 14U;
  input.next_tx_application_bytes = 14U;
  input.next_tx_wire_bytes = 32U;
  const auto at_boundary = late.tick(input);
  checks.require(at_boundary.type == LinkActionType::None &&
                     late.actual_bytes() == 0U &&
                     diagnostics.expired_windows == 1U &&
                     late.state() == GroundTddState::SendUlDone,
                 "unstarted frame cannot be newly admitted at300ms boundary");
  input.now_ms = 1951U;
  const auto terminal = late.tick(input);
  checks.require(terminal.type == LinkActionType::SendDone &&
                     terminal.control.type == ControlType::UlIdle,
                 "missed admission sends IDLE not partial payload or false DONE");
}
}  // namespace

int main(int argc, char** argv) {
  Checks checks{};
  const bool counterfactual =
      argc == 2 && std::strcmp(argv[1], "--expect-all-phases-fit-500") == 0;
  checks.require(argc == 1 || counterfactual, "known bounded offline CLI only");
  const auto config = fixed_config();
  const TddConfig defaults{};
  checks.require(config.downlink_send_ms == 3000U && config.uplink_guard_ms == 650U &&
                     config.uplink_window_ms == 300U &&
                     config.vehicle_receive_timeout_ms == 2000U &&
                     config.return_guard_ms == 650U && config.late_terminal_wait_ms == 1300U,
                 "real fixed product standard phase constants");
  checks.require(defaults.downlink_send_ms == config.downlink_send_ms &&
                     defaults.uplink_guard_ms == config.uplink_guard_ms &&
                     defaults.vehicle_receive_timeout_ms == config.vehicle_receive_timeout_ms &&
                     defaults.min_tx_gap_ms == config.min_tx_gap_ms &&
                     defaults.aux_stable_ms == config.aux_stable_ms,
                 "default core TDD timing matches fixed product configuration");
  static_assert(BulkSessionTiming::grant_wait_budget_ms == 500U);
  const Model models[]{
      {"zero_RF_mathematical_lower_bound_not_physical", 0U, 0U,
       TailHint::DisabledLowerBound, false, true},
      {"service550_delivery550_tail_hint_disabled", 550U, 550U,
       TailHint::DisabledLowerBound, false, false},
      {"service550_delivery180_tail_hint_disabled", 550U, 180U,
       TailHint::DisabledLowerBound, false, false},
      {"service550_delivery550_heartbeat_absent", 550U, 550U,
       TailHint::AbsentHeartbeat, false, false},
      {"service550_delivery550_one_boundary_heartbeat", 550U, 550U,
       TailHint::OneBoundaryHeartbeat, false, false},
      {"service550_delivery550_terminal_lost", 550U, 550U,
       TailHint::DisabledLowerBound, true, false}};
  std::cout << "{\"schema\":\"r19-standard-grant-phase-offline-v1\","
               "\"hardware_interaction\":false,\"firmware_changed\":false,"
               "\"tick_resolution_ms\":1,\"fresh_wait_budget_ms\":500,"
               "\"models\":[";
  bool first = true;
  for (const auto& model : models) {
    Simulation sim(model);
    sim.run(40000U);
    checks.require(sim.grants.size() >= 3U && sim.invalid_grants == 0U,
                   "actual paired controllers produce accepted repeat Grants");
    if (sim.grants.size() < 3U) continue;
    const auto phase = every_request_phase(sim.grants[0], sim.grants[1], checks);
    checks.require(sim.grants[2].observed_ms - sim.grants[1].observed_ms ==
                       phase.interval_ms,
                   "repeated Grant interval stable in stated deterministic model");
    if (model.lose_terminal) {
      checks.require(sim.vehicle_diagnostics.uplink_timeouts > 0U,
                     "lost terminal invokes actual2000ms timeout plus1300ms recovery");
    } else {
      checks.require(sim.accepted_terminals > 0U &&
                         sim.vehicle_diagnostics.uplink_timeouts == 0U,
                     "normal IDLE terminal closes controller lease without timeout");
    }
    if (counterfactual) {
      checks.require(phase.exceed_500 == 0U,
                     "counterfactual arbitrary PARAM phase always fits500ms");
    }
    if (!first) std::cout << ',';
    first = false;
    std::cout << "{\"name\":\"" << model.name << "\",\"mathematical_only\":"
              << (model.mathematical_only ? "true" : "false")
              << ",\"local_service_ms\":" << model.local_service_ms
              << ",\"assumed_remote_delivery_ms\":" << model.remote_delivery_ms
              << ",\"first_grant_generated_ms\":" << sim.grants[0].generated_ms
              << ",\"first_grant_sender_tail_ms\":" << sim.grants[0].sender_tail_ms
              << ",\"first_grant_observed_ms\":" << sim.grants[0].observed_ms
              << ",\"next_grant_observed_ms\":" << sim.grants[1].observed_ms
              << ",\"interval_ms\":" << phase.interval_ms
              << ",\"request_phases\":" << phase.phases
              << ",\"within500_phases\":" << phase.within_500
              << ",\"exceed500_phases\":" << phase.exceed_500
              << ",\"exceed500_fraction\":" << std::setprecision(10)
              << static_cast<double>(phase.exceed_500) /
                     static_cast<double>(phase.phases)
              << ",\"minimum_wait_ms\":" << phase.minimum_wait_ms
              << ",\"maximum_wait_ms\":" << phase.maximum_wait_ms << '}';
  }
  Simulation transfer(models[1], true);
  check_admission_not_completion(checks, models[1], transfer);
  std::cout << "],\"admission_vs_completion\":{\"payload_started_ms\":"
            << transfer.data_accepted_ms << ",\"admission_deadline_ms\":"
            << transfer.admission_deadline_ms << ",\"done_uart_accepted_ms\":"
            << transfer.done_accepted_ms << ",\"done_sender_tail_ms\":"
            << transfer.done_sender_tail_ms << ",\"done_observed_ms\":"
            << transfer.done_observed_ms << ",\"transaction_deadline_ms\":"
            << transfer.transaction_deadline_ms << "},\"checks\":" << checks.total
            << ",\"failures\":" << checks.failures
            << ",\"counterfactual_all_phases_fit\":"
            << (counterfactual ? "true" : "false") << "}\n";
  return checks.failures == 0U ? 0 : 1;
}
