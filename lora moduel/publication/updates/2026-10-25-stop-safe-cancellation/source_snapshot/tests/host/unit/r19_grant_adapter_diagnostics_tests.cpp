#include "../../../firmware/high_speed/high_speed_phase6_adapter.hpp"

#include <array>
#include <cstdint>
#include <iostream>
#include <type_traits>

using namespace vc_lora;
using namespace vc_lora::experimental;

namespace {
unsigned checks = 0U;
unsigned failures = 0U;
void check(bool value, const char* message) {
  ++checks;
  if (!value) { ++failures; std::cerr << "FAIL " << message << '\n'; }
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

MavlinkFrame request() {
  constexpr std::array<std::uint8_t, 2U> payload{{1U, 1U}};
  MavlinkFrame value{};
  check(encode_mavlink_v2(1U, 255U, 190U, 21U, payload.data(),
                        payload.size(), value), "encode #21 request");
  return value;
}

void no_grant_deadline() {
  GroundHighSpeedPhase6Adapter value{config()};
  const auto& initial = value.diagnostics();
  check(initial.event == GroundHighSpeedDiagnosticEvent::None,
        "initial event is absent");
  check(!initial.request_origin_valid && !initial.standard_grant_observed_valid &&
        !initial.fresh_grant_observed_valid && !value.failure_latched(),
        "absence is not an invented zero timestamp");
  check(value.observe_standard_grant(7U, 10U, 0U) ==
            HighSpeedPhase6AdapterStatus::Ready, "capture baseline at zero");
  check(value.diagnostics().standard_grant_observed_valid &&
        value.diagnostics().standard_grant_observed_ms == 0U &&
        value.diagnostics().standard_grant_session == 7U &&
        value.diagnostics().standard_grant_cycle == 10U,
        "zero-time actual baseline has explicit presence");
  check(value.on_ground_usb_frame(request(), 1U, 100U) ==
            HighSpeedPhase6AdapterStatus::Held, "hold request");
  const auto& held = value.diagnostics();
  check(held.event == GroundHighSpeedDiagnosticEvent::ParameterRequest &&
        held.owner_state_before == GroundBulkSessionState::Standard &&
        held.owner_state_after == GroundBulkSessionState::AwaitFreshGrant &&
        held.coordinator_state_before == GroundHighSpeedTddState::Idle &&
        held.coordinator_state_after == GroundHighSpeedTddState::AwaitFreshGrant,
        "request entry before and after states are captured");
  check(held.owner_result_valid && held.coordinator_result_valid &&
        held.owner_result == BulkSessionResult::ParameterRequestHeld &&
        held.coordinator_result == HighSpeedCoordinatorResult::Ready,
        "actual request results captured");
  check(held.request_origin_valid && held.request_origin_ms == 100U &&
        held.await_fresh_grant_started_valid &&
        held.await_fresh_grant_started_ms == 100U &&
        !held.fresh_grant_observed_valid &&
        !held.coordinator_grant_staged_valid,
        "request origin and AwaitFreshGrant entry have no fabricated Grant");
  check(value.tick(600U) == HighSpeedPhase6AdapterStatus::NoAction &&
        !value.failure_latched(), "500 ms inclusive boundary unchanged");
  check(value.tick(601U) == HighSpeedPhase6AdapterStatus::FailClosed,
        "501 ms tick retains fail-closed behavior");
  const auto frozen = value.first_failure_diagnostics();
  check(value.failure_latched() && frozen.observed_ms == 601U &&
        frozen.event == GroundHighSpeedDiagnosticEvent::Tick,
        "first failure timestamp and caller event frozen");
  check(frozen.owner_state_before == GroundBulkSessionState::AwaitFreshGrant &&
        frozen.owner_state_after == GroundBulkSessionState::FailClosed &&
        frozen.coordinator_state_before == GroundHighSpeedTddState::AwaitFreshGrant &&
        frozen.coordinator_state_after == GroundHighSpeedTddState::FailClosed,
        "tick before-after states prove transition rather than infer it");
  check(frozen.owner_result_valid && frozen.coordinator_result_valid &&
        frozen.owner_result == BulkSessionResult::GrantDeadlineExceeded &&
        frozen.owner_last_error == BulkSessionResult::GrantDeadlineExceeded &&
        frozen.coordinator_result == HighSpeedCoordinatorResult::GrantDeadlineExceeded &&
        frozen.coordinator_last_error == HighSpeedCoordinatorResult::GrantDeadlineExceeded,
        "underlying deadline errors survive generic adapter FailClosed");
  check(frozen.adapter_failure_reason == HighSpeedPhase6AdapterStatus::FailClosed &&
        frozen.adapter_status == HighSpeedPhase6AdapterStatus::FailClosed &&
        !frozen.fresh_grant_observed_valid,
        "generic return is distinguished from exact owner-coordinator errors");
  check(value.on_fresh_grant(7U, 11U, 5000U) ==
            HighSpeedPhase6AdapterStatus::FailClosed &&
        value.tick(5001U) == HighSpeedPhase6AdapterStatus::FailClosed,
        "late five-second Grant cannot revive failed session");
  const auto& still = value.first_failure_diagnostics();
  check(still.observed_ms == frozen.observed_ms &&
        still.owner_result == frozen.owner_result &&
        !still.fresh_grant_observed_valid,
        "later calls cannot overwrite first missing-Grant evidence");
}

void fresh_grant_boundary() {
  GroundHighSpeedPhase6Adapter value{config()};
  check(value.observe_standard_grant(7U, 10U, 0U) ==
            HighSpeedPhase6AdapterStatus::Ready, "boundary baseline");
  check(value.on_ground_usb_frame(request(), 1U, 0U) ==
            HighSpeedPhase6AdapterStatus::Held, "request origin zero is valid");
  check(value.on_fresh_grant(7U, 11U, 500U) ==
            HighSpeedPhase6AdapterStatus::Ready, "fresh Grant at inclusive 500 ms succeeds");
  const auto& d = value.diagnostics();
  check(d.request_origin_valid && d.request_origin_ms == 0U &&
        d.await_fresh_grant_started_valid && d.await_fresh_grant_started_ms == 0U,
        "zero origin not confused with absent request");
  check(d.fresh_grant_observed_valid && d.fresh_grant_observed_ms == 500U &&
        d.fresh_grant_session == 7U && d.fresh_grant_cycle == 11U &&
        d.coordinator_grant_staged_valid && d.coordinator_grant_staged_ms == 500U,
        "received Grant and coordinator acceptance recorded separately");
  check(d.owner_result == BulkSessionResult::NegotiationRequestReady &&
        d.coordinator_result == HighSpeedCoordinatorResult::Ready &&
        d.owner_state_after == GroundBulkSessionState::RequestReady &&
        d.coordinator_state_after == GroundHighSpeedTddState::RequestGuard,
        "Grant promotes exact owner and coordinator states");
  check(!value.failure_latched(), "no failure invented for valid boundary Grant");
}

void distinct_failure_reasons() {
  GroundHighSpeedPhase6Adapter stale{config()};
  (void)stale.observe_standard_grant(7U, 10U, 0U);
  (void)stale.on_ground_usb_frame(request(), 1U, 10U);
  check(stale.on_fresh_grant(7U, 10U, 20U) ==
            HighSpeedPhase6AdapterStatus::FailClosed, "stale Grant still rejected");
  const auto& s = stale.first_failure_diagnostics();
  check(s.adapter_failure_reason == HighSpeedPhase6AdapterStatus::OwnerRejected &&
        s.owner_result_valid && s.owner_result == BulkSessionResult::StaleGrant &&
        s.owner_last_error == BulkSessionResult::StaleGrant &&
        !s.coordinator_result_valid && !s.coordinator_grant_staged_valid &&
        s.fresh_grant_observed_valid && s.fresh_grant_observed_ms == 20U,
        "arrival does not imply acceptance and StaleGrant is not deadline");

  GroundHighSpeedPhase6Adapter late{config()};
  (void)late.observe_standard_grant(7U, 10U, 0U);
  (void)late.on_ground_usb_frame(request(), 1U, 10U);
  (void)late.on_fresh_grant(7U, 11U, 511U);
  const auto& l = late.first_failure_diagnostics();
  check(l.adapter_failure_reason == HighSpeedPhase6AdapterStatus::DeadlineExceeded &&
        l.owner_result == BulkSessionResult::GrantDeadlineExceeded &&
        l.fresh_grant_observed_valid && !l.coordinator_result_valid,
        "late arrival records owner-specific deadline before collapse");

  GroundHighSpeedPhase6Adapter clock{config()};
  (void)clock.observe_standard_grant(7U, 10U, 10U);
  check(clock.tick(9U) == HighSpeedPhase6AdapterStatus::ClockRegression,
        "clock regression remains original status");
  const auto& c = clock.first_failure_diagnostics();
  check(c.observed_ms == 9U && c.event == GroundHighSpeedDiagnosticEvent::Tick &&
        c.adapter_failure_reason == HighSpeedPhase6AdapterStatus::ClockRegression &&
        !c.owner_result_valid && !c.coordinator_result_valid,
        "adapter clock failure does not fabricate owner execution");
}

void no_new_behavior() {
  GroundHighSpeedPhase6Adapter value{config()};
  check(value.on_ground_usb_frame(request(), 1U, 10U) ==
            HighSpeedPhase6AdapterStatus::PassThrough, "no baseline remains pass-through");
  const auto& d = value.diagnostics();
  check(!d.request_origin_valid && !d.await_fresh_grant_started_valid &&
        d.owner_result_valid && d.owner_result == BulkSessionResult::NotHighSpeedReady &&
        !d.coordinator_result_valid, "pass-through cannot invent active session");
  auto disabled_config = config();
  disabled_config.feature = BulkSessionFeature::Disabled;
  GroundHighSpeedPhase6Adapter disabled{disabled_config};
  check(disabled.tick(10000U) == HighSpeedPhase6AdapterStatus::Disabled &&
        !disabled.failure_latched(), "feature-disabled behavior unchanged");
}
}  // namespace

int main() {
  static_assert(std::is_standard_layout_v<GroundHighSpeedPhase6DiagnosticSnapshot>);
  static_assert(std::is_trivially_copyable_v<GroundHighSpeedPhase6DiagnosticSnapshot>);
  static_assert(sizeof(GroundHighSpeedPhase6DiagnosticSnapshot) <= 128U);
  static_assert(BulkSessionTiming::grant_wait_budget_ms == 500U);
  no_grant_deadline(); fresh_grant_boundary(); distinct_failure_reasons(); no_new_behavior();
  std::cout << "R19_GRANT_ADAPTER_DIAGNOSTICS " << (failures ? "FAIL" : "PASS")
            << " checks=" << checks << " failures=" << failures << '\n';
  return failures ? 1 : 0;
}
