#include "../../../firmware/high_speed/high_speed_phase6_adapter.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <iostream>

using namespace vc_lora;
using namespace vc_lora::experimental;

namespace {
unsigned checks = 0U;
unsigned failures = 0U;
unsigned scenarios = 0U;

void check(bool value, const char* message) {
  ++checks;
  if (!value) {
    ++failures;
    if (failures <= 20U) {
      std::cerr << "FAIL " << message << '\n';
    }
  }
}

GroundBulkSessionConfig config() {
  GroundBulkSessionConfig value{};
  value.feature = BulkSessionFeature::Enabled;
  value.ground_boot_id = 1U;
  value.ground_session_id = 2U;
  value.request_sequence = 3U;
  value.ground_nonce = 4U;
  return value;
}

MavlinkFrame parameter_request() {
  constexpr std::array<std::uint8_t, 2U> payload{{1U, 1U}};
  MavlinkFrame frame{};
  check(encode_mavlink_v2(1U, 255U, 190U, 21U, payload.data(),
                         payload.size(), frame),
        "encode canonical PARAM_REQUEST_LIST");
  return frame;
}

void prime(GroundHighSpeedPhase6Adapter& adapter, const MavlinkFrame& request,
           std::uint64_t baseline_ms, std::uint64_t request_ms) {
  check(adapter.observe_standard_grant(640U, 1U, baseline_ms) ==
            HighSpeedPhase6AdapterStatus::Ready,
        "standard Grant watermark accepted");
  check(adapter.on_ground_usb_frame(request, 1U, request_ms) ==
            HighSpeedPhase6AdapterStatus::Held,
        "request is held before fresh Grant");
  const auto d = adapter.diagnostics();
  check(d.request_origin_valid && d.request_origin_ms == request_ms &&
            d.await_fresh_grant_started_valid &&
            d.await_fresh_grant_started_ms == request_ms,
        "owner/coordinator use the same request-origin deadline");
  check(d.owner_state_after == GroundBulkSessionState::AwaitFreshGrant &&
            d.coordinator_state_after == GroundHighSpeedTddState::AwaitFreshGrant,
        "both semantic state machines await fresh Grant");
  check(!d.fresh_grant_observed_valid && !d.coordinator_grant_staged_valid,
        "old baseline is not fresh-Grant arrival or admission");
  check(adapter.hold_standard_uplink(),
        "standard uplink remains held before fresh Grant");
  check(adapter.poll(request_ms).type == HighSpeedPhase6OutputType::None,
        "no radio/UART action at request acceptance");
}

void historical_absent_grant(const MavlinkFrame& request) {
  ++scenarios;
  GroundHighSpeedPhase6Adapter adapter{config()};
  prime(adapter, request, 9233U, 12351U);
  check(adapter.tick(12850U) == HighSpeedPhase6AdapterStatus::NoAction,
        "historical replay remains pending at499ms");
  check(adapter.poll(12850U).type == HighSpeedPhase6OutputType::None,
        "no negotiation UART action without fresh Grant at499ms");
  check(adapter.tick(12851U) == HighSpeedPhase6AdapterStatus::NoAction &&
            !adapter.fail_closed(),
        "historical replay remains pending at inclusive500ms");
  check(adapter.poll(12851U).type == HighSpeedPhase6OutputType::None,
        "no negotiation UART action without fresh Grant at500ms");
  check(adapter.tick(12852U) == HighSpeedPhase6AdapterStatus::FailClosed,
        "historical replay fails at501ms");
  const auto first = adapter.first_failure_diagnostics();
  check(first.event == GroundHighSpeedDiagnosticEvent::Tick &&
            first.observed_ms == 12852U && first.request_origin_ms == 12351U &&
            first.standard_grant_observed_ms == 9233U,
        "replayed first-failure source and timestamps match saved run");
  check(first.owner_state_before == GroundBulkSessionState::AwaitFreshGrant &&
            first.coordinator_state_before == GroundHighSpeedTddState::AwaitFreshGrant &&
            first.owner_state_after == GroundBulkSessionState::FailClosed &&
            first.coordinator_state_after == GroundHighSpeedTddState::FailClosed,
        "historical replay preserves both pre/post states");
  check(first.owner_result_valid && first.coordinator_result_valid &&
            first.owner_result == BulkSessionResult::GrantDeadlineExceeded &&
            first.owner_last_error == BulkSessionResult::GrantDeadlineExceeded &&
            first.coordinator_result == HighSpeedCoordinatorResult::GrantDeadlineExceeded &&
            first.coordinator_last_error == HighSpeedCoordinatorResult::GrantDeadlineExceeded,
        "both real semantic owners independently report deadline exceeded");
  check(!first.fresh_grant_observed_valid && !first.coordinator_grant_staged_valid,
        "absence of Grant remains explicit, not a zero-time Grant");
  check(adapter.poll(12852U).type == HighSpeedPhase6OutputType::None,
        "failure emits no negotiation action");
  check(adapter.on_fresh_grant(640U, 2U, 14233U) ==
            HighSpeedPhase6AdapterStatus::FailClosed,
        "late fixture Grant cannot silently reopen failed admission");
  const auto still = adapter.first_failure_diagnostics();
  check(still.observed_ms == first.observed_ms &&
            still.owner_result == first.owner_result &&
            !still.fresh_grant_observed_valid,
        "late arrival does not replace immutable missing-Grant failure");
  std::cout << "CASE historical baseline_ms=9233 request_ms=12351 "
               "first_failure_ms=12852 owner=GrantDeadlineExceeded "
               "coordinator=GrantDeadlineExceeded negotiation_actions=0\n";
}

void fresh_boundary(const MavlinkFrame& request, std::uint64_t age_ms,
                    bool tick_first) {
  ++scenarios;
  constexpr std::uint64_t t0 = 12351U;
  const std::uint64_t arrival = t0 + age_ms;
  GroundHighSpeedPhase6Adapter adapter{config()};
  prime(adapter, request, 9233U, t0);
  check(adapter.tick(t0 + 498U) == HighSpeedPhase6AdapterStatus::NoAction,
        "boundary fixture starts without previous deadline failure");
  check(adapter.poll(t0 + 498U).type == HighSpeedPhase6OutputType::None,
        "no negotiation action before the boundary Grant");

  HighSpeedPhase6AdapterStatus before = HighSpeedPhase6AdapterStatus::NoAction;
  HighSpeedPhase6AdapterStatus received = HighSpeedPhase6AdapterStatus::NoAction;
  HighSpeedPhase6AdapterStatus after = HighSpeedPhase6AdapterStatus::NoAction;
  GroundHighSpeedPhase6DiagnosticSnapshot arrival_snapshot{};
  if (tick_first) {
    before = adapter.tick(arrival);
    received = adapter.on_fresh_grant(640U, 2U, arrival);
    arrival_snapshot = adapter.diagnostics();
  } else {
    received = adapter.on_fresh_grant(640U, 2U, arrival);
    arrival_snapshot = adapter.diagnostics();
    after = adapter.tick(arrival);
  }

  if (age_ms <= BulkSessionTiming::grant_wait_budget_ms) {
    check(before == HighSpeedPhase6AdapterStatus::NoAction &&
              after == HighSpeedPhase6AdapterStatus::NoAction &&
              received == HighSpeedPhase6AdapterStatus::Ready &&
              !adapter.fail_closed() && !adapter.failure_latched(),
          "499/500ms fresh arrival succeeds under both dispatch orders");
    check(arrival_snapshot.event == GroundHighSpeedDiagnosticEvent::FreshGrant &&
              arrival_snapshot.fresh_grant_observed_valid &&
              arrival_snapshot.fresh_grant_observed_ms == arrival &&
              arrival_snapshot.coordinator_grant_staged_valid &&
              arrival_snapshot.coordinator_grant_staged_ms == arrival,
          "fresh observation and coordinator staging times agree");
    check(arrival_snapshot.owner_result_valid &&
              arrival_snapshot.owner_result == BulkSessionResult::NegotiationRequestReady &&
              arrival_snapshot.owner_state_after == GroundBulkSessionState::RequestReady &&
              arrival_snapshot.coordinator_result_valid &&
              arrival_snapshot.coordinator_result == HighSpeedCoordinatorResult::Ready &&
              arrival_snapshot.coordinator_state_after == GroundHighSpeedTddState::RequestGuard,
          "accepted arrival enters real owner RequestReady and coordinator RequestGuard");
    check(adapter.poll(arrival).type == HighSpeedPhase6OutputType::None &&
              adapter.poll(arrival + 99U).type == HighSpeedPhase6OutputType::None,
          "Grant reception alone cannot bypass100ms negotiation direction guard");
    const auto output = adapter.poll(arrival + 100U);
    check(output.type == HighSpeedPhase6OutputType::RadioWrite &&
              output.semantic == HighSpeedActionType::SendNegotiationRequest &&
              output.size == BulkNegotiationWireCodec::frame_bytes &&
              output.size == 32U && output.token != 0U,
          "first negotiation UART action is canonical32bytes after guard");
    BulkNegotiationFrame wire{};
    std::copy_n(output.bytes.begin(), wire.size(), wire.begin());
    BulkNegotiationRequest decoded{};
    check(BulkNegotiationWireCodec::decode_request(wire, decoded) ==
              BulkNegotiationWireStatus::FrameReady &&
              decoded.captured_vehicle_grant_session == 640U &&
              decoded.captured_vehicle_grant_cycle == 2U,
          "negotiation action binds the actual accepted fresh Grant identity");
  } else {
    check(received == HighSpeedPhase6AdapterStatus::FailClosed &&
              adapter.fail_closed() && adapter.failure_latched(),
          "501ms arrival is rejected under both dispatch orders");
    check(adapter.poll(arrival).type == HighSpeedPhase6OutputType::None,
          "late Grant failure never emits negotiation UART action");
    const auto first = adapter.first_failure_diagnostics();
    check(first.observed_ms == arrival &&
              first.request_origin_ms == t0 &&
              first.owner_result == BulkSessionResult::GrantDeadlineExceeded &&
              first.owner_last_error == BulkSessionResult::GrantDeadlineExceeded &&
              first.owner_state_before == GroundBulkSessionState::AwaitFreshGrant &&
              first.owner_state_after == GroundBulkSessionState::FailClosed,
          "late Grant preserves exact origin, deadline and owner transition");
    if (tick_first) {
      check(before == HighSpeedPhase6AdapterStatus::FailClosed &&
                first.event == GroundHighSpeedDiagnosticEvent::Tick &&
                first.coordinator_result_valid &&
                first.coordinator_result == HighSpeedCoordinatorResult::GrantDeadlineExceeded &&
                first.coordinator_state_after == GroundHighSpeedTddState::FailClosed &&
                !first.fresh_grant_observed_valid,
            "tick-before-arrival first failure is missing-Grant in both owners");
    } else {
      check(after == HighSpeedPhase6AdapterStatus::FailClosed &&
                first.event == GroundHighSpeedDiagnosticEvent::FreshGrant &&
                first.adapter_failure_reason == HighSpeedPhase6AdapterStatus::DeadlineExceeded &&
                first.fresh_grant_observed_valid &&
                first.fresh_grant_observed_ms == arrival &&
                !first.coordinator_result_valid &&
                first.coordinator_state_after == GroundHighSpeedTddState::AwaitFreshGrant &&
                !first.coordinator_grant_staged_valid,
            "arrival-before-tick fails at owner before coordinator is invoked");
    }
  }
  std::cout << "CASE fresh age_ms=" << age_ms
            << " order=" << (tick_first ? "tick-first" : "arrival-first")
            << " outcome=" << (age_ms <= 500U ? "admitted" : "fail-closed")
            << '\n';
}

void no_baseline(const MavlinkFrame& request) {
  ++scenarios;
  GroundHighSpeedPhase6Adapter adapter{config()};
  check(adapter.on_ground_usb_frame(request, 1U, 12351U) ==
            HighSpeedPhase6AdapterStatus::PassThrough,
        "no baseline does not silently start FreshGrant deadline");
  check(!adapter.diagnostics().request_origin_valid &&
            !adapter.diagnostics().await_fresh_grant_started_valid,
        "no-baseline pass-through has no active request origin");
  check(adapter.tick(12852U) == HighSpeedPhase6AdapterStatus::NoAction &&
            !adapter.fail_closed() &&
            adapter.poll(12852U).type == HighSpeedPhase6OutputType::None,
        "no-baseline path is distinct from active admission deadline");
}

void equal_timestamp_request_grant_order(const MavlinkFrame& request) {
  constexpr std::uint64_t shared_ms = 12351U;
  ++scenarios;
  GroundHighSpeedPhase6Adapter request_first{config()};
  prime(request_first, request, 9233U, shared_ms);
  check(request_first.on_fresh_grant(640U, 2U, shared_ms) ==
            HighSpeedPhase6AdapterStatus::Ready &&
            !request_first.fail_closed(),
        "same timestamp request-before-fresh arrival admits zero-age Grant");
  const auto admitted = request_first.diagnostics();
  check(admitted.request_origin_ms == shared_ms &&
            admitted.fresh_grant_observed_valid &&
            admitted.fresh_grant_observed_ms == shared_ms &&
            admitted.coordinator_grant_staged_valid &&
            admitted.coordinator_grant_staged_ms == shared_ms,
        "equal-time admission has distinct request and fresh event witnesses");
  check(request_first.poll(shared_ms).type == HighSpeedPhase6OutputType::None,
        "zero-age admission still cannot bypass direction guard");

  ++scenarios;
  GroundHighSpeedPhase6Adapter grant_first{config()};
  check(grant_first.observe_standard_grant(640U, 1U, 9233U) ==
            HighSpeedPhase6AdapterStatus::Ready &&
            grant_first.observe_standard_grant(640U, 2U, shared_ms) ==
                HighSpeedPhase6AdapterStatus::Ready,
        "same timestamp Grant-before-request advances standard watermark first");
  check(grant_first.on_ground_usb_frame(request, 1U, shared_ms) ==
            HighSpeedPhase6AdapterStatus::Held,
        "request after observed Grant starts a new fresh-Grant wait");
  const auto waiting = grant_first.diagnostics();
  check(waiting.standard_grant_cycle == 2U &&
            waiting.standard_grant_observed_ms == shared_ms &&
            waiting.request_origin_ms == shared_ms &&
            waiting.owner_state_after == GroundBulkSessionState::AwaitFreshGrant &&
            waiting.coordinator_state_after == GroundHighSpeedTddState::AwaitFreshGrant &&
            !waiting.fresh_grant_observed_valid &&
            !waiting.coordinator_grant_staged_valid,
        "already-observed same-time Grant is baseline, not a fresh witness");
  check(grant_first.poll(shared_ms).type == HighSpeedPhase6OutputType::None &&
            grant_first.tick(shared_ms + 500U) == HighSpeedPhase6AdapterStatus::NoAction &&
            grant_first.tick(shared_ms + 501U) == HighSpeedPhase6AdapterStatus::FailClosed,
        "no later Grant cannot reuse same-time baseline and fails at501ms");
  const auto failed = grant_first.first_failure_diagnostics();
  check(failed.owner_result == BulkSessionResult::GrantDeadlineExceeded &&
            failed.coordinator_result == HighSpeedCoordinatorResult::GrantDeadlineExceeded &&
            !failed.fresh_grant_observed_valid,
        "same-time watermark reuse is not invented after deadline");
  std::cout << "CASE equal-timestamp request-first=admitted "
               "Grant-as-baseline-first=await-newer-then-deadline "
               "timestamp_ms=12351\n";
}

// Deliberately conditional geometry, NOT a replacement for the real standard
// TDD scheduler test. The test supplies a next fresh Grant every5000ms and
// exercises each integer request phase through the real R19 adapter. It does
// not claim a physical Grant is actually received at this timestamp.
void conditional_periodic_phase_sweep(const MavlinkFrame& request) {
  constexpr std::uint64_t period_ms = 5000U;
  constexpr std::uint64_t baseline_ms = 10000U;
  constexpr std::uint64_t fresh_ms = baseline_ms + period_ms;
  unsigned admitted = 0U;
  unsigned rejected = 0U;
  for (std::uint64_t phase = 0U; phase < period_ms; ++phase) {
    GroundHighSpeedPhase6Adapter adapter{config()};
    const auto request_ms = baseline_ms + phase;
    const auto wait_ms = fresh_ms - request_ms;
    prime(adapter, request, baseline_ms, request_ms);
    if (wait_ms > BulkSessionTiming::grant_wait_budget_ms) {
      check(adapter.tick(request_ms + 501U) == HighSpeedPhase6AdapterStatus::FailClosed,
            "conditional phase expires before later next Grant");
      check(adapter.on_fresh_grant(640U, 2U, fresh_ms) ==
                HighSpeedPhase6AdapterStatus::FailClosed,
            "conditional late Grant does not revive admission");
      ++rejected;
    } else {
      check(adapter.tick(fresh_ms) == HighSpeedPhase6AdapterStatus::NoAction &&
                adapter.on_fresh_grant(640U, 2U, fresh_ms) ==
                    HighSpeedPhase6AdapterStatus::Ready,
            "conditional phase inside inclusive500ms admits Grant");
      check(!adapter.fail_closed(), "conditional admitted phase stays active");
      ++admitted;
    }
  }
  check(admitted == 500U && rejected == 4500U,
        "conditional5000ms geometry has500 integer phases within deadline");
  std::cout << "CONDITIONAL_PHASE_SWEEP period_ms=5000 integer_phases=5000 "
            << "admitted=" << admitted << " rejected=" << rejected
            << " source=synthetic-next-Grant-fixture-not-RF-measurement\n";
}

bool unresolved_alignment_probe(const MavlinkFrame& request) {
  // A requirement probe, not a production fix: an otherwise-valid normal
  // request should be deferred or gracefully declined if the next eligible
  // Grant lies outside the500ms admission window, rather than raising the
  // adapter's fatal status before that Grant. The current implementation
  // violates this desired property. No deadline or production code is changed.
  GroundHighSpeedPhase6Adapter adapter{config()};
  prime(adapter, request, 9233U, 12351U);
  const auto at_501 = adapter.tick(12852U);
  const bool met = at_501 != HighSpeedPhase6AdapterStatus::FailClosed &&
                   !adapter.fail_closed();
  std::cout << "ALIGNMENT_REQUIREMENT_PROBE "
            << (met ? "PASS" : "FAIL_UNRESOLVED")
            << " baseline_ms=9233 request_ms=12351 check_ms=12852 "
               "fixture_next_fresh_ms=14233 next_source=conditional5000ms-period "
               "scope=adapter-fatal-boundary-not-whole-system-HIL\n";
  if (!met) {
    std::cerr << "UNRESOLVED adapter fails closed before the conditional "
                 "next eligible Grant; default characterization passing is "
                 "not proof of admission/scheduler alignment.\n";
  }
  return met;
}
}  // namespace

int main(int argc, char** argv) {
  static_assert(BulkSessionTiming::grant_wait_budget_ms == 500U);
  static_assert(BulkSessionTiming::direction_guard_ms == 100U);
  static_assert(BulkSessionTiming::hard_lease_ms == 28000U);
  static_assert(BulkSessionAccounting::completion_deadline_ms == 30000U);
  bool require_alignment = false;
  if (argc == 2 && std::strcmp(argv[1], "--require-alignment") == 0) {
    require_alignment = true;
  } else if (argc != 1) {
    std::cerr << "usage: r19_grant_admission_timing_tests [--require-alignment]\n";
    return 2;
  }
  const auto request = parameter_request();
  historical_absent_grant(request);
  for (const auto age : {499U, 500U, 501U}) {
    fresh_boundary(request, age, true);
    fresh_boundary(request, age, false);
  }
  no_baseline(request);
  equal_timestamp_request_grant_order(request);
  conditional_periodic_phase_sweep(request);
  std::cout << "R19_GRANT_ADMISSION_CHARACTERIZATION "
            << (failures ? "FAIL" : "PASS") << " checks=" << checks
            << " scenarios=" << scenarios << " phase_cases=5000 failures="
            << failures << '\n';
  if (failures) {
    return 1;
  }
  if (require_alignment && !unresolved_alignment_probe(request)) {
    return 1;
  }
  return 0;
}
