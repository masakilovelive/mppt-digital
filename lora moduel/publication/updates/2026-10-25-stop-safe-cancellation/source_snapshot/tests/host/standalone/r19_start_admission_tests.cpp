#if defined(VC_LORA_R19_START_ADMISSION_LEGACY_RED)
#include "../../../firmware/high_speed/high_speed_phase6_adapter.hpp"
#include <array>
#include <iostream>

// Deliberate requirement RED, not a defect assertion about the compatible
// legacy API. That API has no reservation/interval argument at all.
int main() {
  using namespace vc_lora;
  using namespace vc_lora::experimental;
  GroundBulkSessionConfig config{};
  config.feature = BulkSessionFeature::Enabled;
  config.ground_boot_id = 1U;
  config.ground_session_id = 2U;
  config.request_sequence = 3U;
  config.ground_nonce = 4U;
  GroundHighSpeedPhase6Adapter adapter{config};
  constexpr std::array<std::uint8_t, 2U> payload{{1U, 1U}};
  MavlinkFrame request{};
  if (!encode_mavlink_v2(1U, 255U, 190U, 21U, payload.data(),
                         payload.size(), request) ||
      adapter.observe_standard_grant(640U, 1U, 9000U) !=
          HighSpeedPhase6AdapterStatus::Ready) {
    std::cerr << "Invalid RED fixture\n";
    return 2;
  }
  const auto status = adapter.on_ground_usb_frame(request, 1U, 10000U);
  const bool requirement = status != HighSpeedPhase6AdapterStatus::Held &&
                           !adapter.diagnostics().request_origin_valid;
  std::cout << "missing-strict-seam-characterization checks=1 failures="
            << (requirement ? 0 : 1) << " legacy_held="
            << (status == HighSpeedPhase6AdapterStatus::Held)
            << " legacy_t0=" << adapter.diagnostics().request_origin_ms
            << " reservation_supplied=0\n";
  return requirement ? 0 : 1;
}
#else
#include "vc_lora/r19_start_admission.hpp"

#include <cstdint>
#include <iostream>
#include <limits>

namespace {
using namespace vc_lora;
unsigned checks = 0U;
unsigned failures = 0U;

void check(bool value, const char* label) {
  ++checks;
  if (!value) {
    ++failures;
    if (failures <= 25U) std::cerr << "FAIL " << label << '\n';
  }
}

R19StartAdmissionInterval interval(std::uint64_t first,
                                    std::uint64_t last) {
  return {first, last, true};
}

struct Fixture {
  R19StartAdmissionSlot slot{};
  R19StartAdmissionContext context{};
  Fixture() {
    slot.identity = {7U, 1U, 640U, 2U};
    slot.producer_bound = true;  // Synthetic assertion, NOT a live producer.
    slot.unused = true;
    slot.ground_request_accept = interval(10000U, 10000U);
    slot.ground_next_grant = interval(10400U, 10500U);
    slot.vehicle_grant_physical_tail = interval(20000U, 20010U);
    slot.vehicle_clock_at_ground_grant = interval(20100U, 20120U);
    slot.transport_after_ground_guard = interval(80U, 100U);
    slot.vehicle_complete_vcbn = interval(20280U, 20320U);
    context.expected_identity = slot.identity;
    context.baseline_session = 640U;
    context.baseline_cycle = 1U;
    context.original_t0_ms = 10000U;
  }
};

bool feasible(const Fixture& f) {
  const auto r = EvaluateR19StartAdmission(f.slot, f.context);
  check(r.original_t0_ms == f.context.original_t0_ms,
        "plan never resets original request origin");
  return r.status == R19StartAdmissionStatus::FeasiblePlan;
}

void missing_and_identity() {
  Fixture valid{};
  check(feasible(valid), "bounded synthetic dual-clock plan is feasible");
  check(EvaluateR19StartAdmission({}, {}).status ==
            R19StartAdmissionStatus::NotReady,
        "default/missing producer cannot become an eligible plan");
  auto f = valid;
  f.slot.producer_bound = false;
  check(!feasible(f), "missing producer assertion is not ready");
  check(f.context.original_t0_ms == 10000U &&
            f.slot.ground_request_accept.earliest_ms == 10000U &&
            f.slot.ground_next_grant.latest_ms == 10500U,
        "new no-start seam leaves request origin and slot unmodified");
  f = valid; f.slot.unused = false;
  check(!feasible(f), "consumed slot cannot be replayed");
  f = valid; ++f.context.expected_identity.slot_token;
  check(!feasible(f), "wrong token rejected");
  f = valid; ++f.context.expected_identity.usb_epoch;
  check(!feasible(f), "wrong USB epoch rejected");
  f = valid; ++f.context.expected_identity.grant_session;
  check(!feasible(f), "wrong Grant session rejected");
  f = valid; ++f.context.expected_identity.grant_cycle;
  check(!feasible(f), "wrong Grant cycle rejected");
  f = valid; f.slot.identity.slot_token = 0U;
  f.context.expected_identity = f.slot.identity;
  check(!feasible(f), "zero token is not evidence");
  f = valid; f.slot.identity.usb_epoch = 0U;
  f.context.expected_identity = f.slot.identity;
  check(feasible(f), "observed epoch zero is valid when exactly identity-bound");
  f.context.expected_identity.usb_epoch = 1U;
  check(!feasible(f), "observed zero epoch still rejects mismatched epoch one");
  f = valid; f.slot.identity.grant_session = 0U;
  f.context.expected_identity = f.slot.identity;
  check(!feasible(f), "zero session rejected");
  f = valid; f.slot.identity.grant_cycle = 0U;
  f.context.expected_identity = f.slot.identity;
  check(!feasible(f), "cycle zero cannot meet retained Vehicle evidence");
  f = valid; f.context.baseline_session = 0U;
  check(!feasible(f), "missing baseline rejected");
  f = valid; f.context.baseline_cycle = 2U;
  check(!feasible(f), "already-observed Grant is not future/fresh");
  f = valid; f.context.baseline_cycle = 3U;
  check(!feasible(f), "older cycle rejected");
  f = valid; f.context.baseline_cycle = 32770U;
  check(!feasible(f), "half-range cycle ambiguity rejected");
  f = valid; f.context.baseline_session = 641U;
  check(!feasible(f), "older session rejected");
  f = valid; f.context.baseline_session = 639U;
  check(feasible(f), "strictly newer session uses canonical wrap order");
}

void all_interval_validation() {
  for (unsigned index = 0U; index < 6U; ++index) {
    Fixture f{};
    R19StartAdmissionInterval* fields[]{
        &f.slot.ground_request_accept, &f.slot.ground_next_grant,
        &f.slot.vehicle_grant_physical_tail, &f.slot.vehicle_complete_vcbn,
        &f.slot.vehicle_clock_at_ground_grant,
        &f.slot.transport_after_ground_guard};
    fields[index]->bounded = false;
    check(!feasible(f), "every missing/unbounded interval is not ready");
    *fields[index] = interval(2U, 1U);
    check(!feasible(f), "every reversed interval is not ready");
  }
  Fixture f{};
  f.context.original_t0_ms = 9999U;
  check(!feasible(f), "actual original t0 before asserted interval rejected");
  f.context.original_t0_ms = 10001U;
  check(!feasible(f), "actual original t0 after asserted interval rejected");
  f = Fixture{};
  f.slot.ground_request_accept = interval(9999U, 10000U);
  check(!feasible(f), "request uncertainty is charged, not only actual t0");
  f = Fixture{};
  f.slot.ground_next_grant = interval(9990U, 9999U);
  check(!feasible(f), "expired/already-observed opportunity rejected");
  f = Fixture{};
  f.slot.ground_request_accept = interval(10000U, 10001U);
  f.slot.ground_next_grant = interval(10000U, 10500U);
  f.slot.request_before_grant_at_equal_timestamp = true;
  check(!feasible(f), "overlapping intervals cannot invent event order");
}

void boundaries_and_transport() {
  for (std::uint64_t age = 0U; age <= 501U; ++age) {
    Fixture f{};
    f.slot.ground_next_grant = interval(10000U + age, 10000U + age);
    f.slot.request_before_grant_at_equal_timestamp = true;
    check(feasible(f) == (age <= 500U),
          "Ground inclusive500 and first invalid501 boundary");
  }
  Fixture f{};
  f.slot.ground_next_grant = interval(10000U, 10000U);
  check(!feasible(f), "equal timestamps need explicit request-before witness");
  f.slot.request_before_grant_at_equal_timestamp = true;
  check(feasible(f), "equal timestamps with explicit order have zero wait");
  for (std::uint64_t age = 100U; age <= 501U; ++age) {
    f = Fixture{};
    f.slot.vehicle_grant_physical_tail = interval(20000U, 20000U);
    f.slot.vehicle_clock_at_ground_grant = interval(20000U, 20000U);
    f.slot.transport_after_ground_guard = interval(age - 100U, age - 100U);
    f.slot.vehicle_complete_vcbn = interval(20000U + age, 20000U + age);
    check(feasible(f) == (age <= 500U),
          "Vehicle independent inclusive500 and first invalid501 boundary");
  }
  f = Fixture{};
  f.slot.vehicle_complete_vcbn.latest_ms = 20319U;
  check(!feasible(f), "canonical-complete upper bound cannot omit transport");
  f = Fixture{};
  f.slot.vehicle_complete_vcbn.earliest_ms = 20281U;
  check(!feasible(f), "canonical-complete lower bound cannot omit uncertainty");
  f = Fixture{};
  f.slot.vehicle_grant_physical_tail = interval(20300U, 20310U);
  check(!feasible(f), "Vehicle cannot accept before retained physical tail");
  f = Fixture{};
  f.slot.transport_after_ground_guard = interval(80U, 281U);
  f.slot.vehicle_complete_vcbn = interval(20280U, 20501U);
  check(!feasible(f), "transport uncertainty consumes Vehicle500 budget");
  f = Fixture{};
  f.slot.vehicle_clock_at_ground_grant.latest_ms = 20301U;
  f.slot.vehicle_complete_vcbn.latest_ms = 20501U;
  check(!feasible(f), "clock mapping uncertainty consumes Vehicle500 budget");
  f = Fixture{};
  f.slot.vehicle_clock_at_ground_grant = interval(20100U, 20100U);
  f.slot.transport_after_ground_guard = interval(0U, 0U);
  f.slot.vehicle_complete_vcbn = interval(20199U, 20199U);
  check(!feasible(f), "100ms direction guard cannot be reduced to99ms");
}

void overflow_and_independent_clocks() {
  Fixture f{};
  const auto top = std::numeric_limits<std::uint64_t>::max();
  f.slot.vehicle_grant_physical_tail = interval(top - 500U, top - 500U);
  f.slot.vehicle_clock_at_ground_grant = interval(top - 99U, top - 99U);
  f.slot.transport_after_ground_guard = interval(0U, 0U);
  f.slot.vehicle_complete_vcbn = interval(top, top);
  check(!feasible(f) && EvaluateR19StartAdmission(f.slot, f.context).reason ==
                            R19StartAdmissionReason::TimeOverflow,
        "guard addition overflow is specifically rejected without wrapping");
  f = Fixture{};
  f.slot.transport_after_ground_guard = interval(top, top);
  check(!feasible(f) && EvaluateR19StartAdmission(f.slot, f.context).reason ==
                            R19StartAdmissionReason::TimeOverflow,
        "transport addition overflow is specifically rejected without wrapping");
  f = Fixture{};
  f.slot.vehicle_grant_physical_tail = interval(top - 500U, top - 500U);
  f.slot.vehicle_clock_at_ground_grant = interval(top - 200U, top - 200U);
  f.slot.transport_after_ground_guard = interval(100U, 100U);
  f.slot.vehicle_complete_vcbn = interval(top, top);
  check(feasible(f), "exact UINT64_MAX finite projection is valid without overflow");
  // Shift only the Ground clock epoch. Vehicle-clock projection is unchanged.
  f = Fixture{};
  f.slot.ground_request_accept = interval(top - 500U, top - 500U);
  f.slot.ground_next_grant = interval(top - 100U, top);
  f.context.original_t0_ms = top - 500U;
  check(feasible(f), "large independent Ground epoch needs no cross subtraction");
  // Shift only the Vehicle clock epoch, keeping every same-clock delta.
  f = Fixture{};
  const std::uint64_t shift = 1000000000000ULL;
  f.slot.vehicle_grant_physical_tail.earliest_ms += shift;
  f.slot.vehicle_grant_physical_tail.latest_ms += shift;
  f.slot.vehicle_clock_at_ground_grant.earliest_ms += shift;
  f.slot.vehicle_clock_at_ground_grant.latest_ms += shift;
  f.slot.vehicle_complete_vcbn.earliest_ms += shift;
  f.slot.vehicle_complete_vcbn.latest_ms += shift;
  check(feasible(f), "independent Vehicle epoch cannot change feasibility");
}

void individual_observations() {
  Fixture f{};
  auto ground = EvaluateR19GroundStartObservation(
      f.slot, f.context, f.slot.identity, 10500U);
  check(ground.boundary_satisfied && ground.original_t0_ms == 10000U,
        "actual Ground500 boundary preserves t0");
  check(!EvaluateR19GroundStartObservation(
              f.slot, f.context, f.slot.identity, 10501U).boundary_satisfied,
        "actual Ground501 cannot use projected success");
  auto changed = f.slot.identity; ++changed.usb_epoch;
  check(!EvaluateR19GroundStartObservation(
              f.slot, f.context, changed, 10500U).boundary_satisfied,
        "actual changed epoch invalidates planned admission");
  check(!EvaluateR19GroundStartObservation(
              f.slot, f.context, f.slot.identity, 10399U).boundary_satisfied,
        "actual Grant outside planned interval is not certified");
  auto vehicle = EvaluateR19VehicleStartObservation(
      f.slot, f.context, f.slot.identity, 20010U, 20320U);
  check(vehicle.boundary_satisfied && vehicle.original_t0_ms == 10000U,
        "actual Vehicle own-clock observation retains original Ground t0");
  check(!EvaluateR19VehicleStartObservation(
              f.slot, f.context, changed, 20010U, 20320U).boundary_satisfied,
        "actual Vehicle identity must match the same reservation");
  check(!EvaluateR19VehicleStartObservation(
              f.slot, f.context, f.slot.identity, 19999U, 20320U).boundary_satisfied,
        "actual tail outside plan not certified");
  check(!EvaluateR19VehicleStartObservation(
              f.slot, f.context, f.slot.identity, 20010U, 20321U).boundary_satisfied,
        "actual complete record outside plan not certified");
  Fixture vehicle_edge{};
  vehicle_edge.slot.vehicle_grant_physical_tail = interval(20000U, 20000U);
  vehicle_edge.slot.vehicle_clock_at_ground_grant = interval(20000U, 20000U);
  vehicle_edge.slot.transport_after_ground_guard = interval(400U, 400U);
  vehicle_edge.slot.vehicle_complete_vcbn = interval(20500U, 20500U);
  check(EvaluateR19VehicleStartObservation(
              vehicle_edge.slot, vehicle_edge.context, vehicle_edge.slot.identity,
              20000U, 20500U).boundary_satisfied,
        "actual Vehicle exactly500 boundary is observed");
  check(!EvaluateR19VehicleStartObservation(
              vehicle_edge.slot, vehicle_edge.context, vehicle_edge.slot.identity,
              20000U, 20501U).boundary_satisfied,
        "actual Vehicle501 cannot borrow the feasible500 plan");
  f.slot.producer_bound = false;
  check(!EvaluateR19GroundStartObservation(
              f.slot, f.context, f.slot.identity, 10500U).boundary_satisfied &&
            !EvaluateR19VehicleStartObservation(
              f.slot, f.context, f.slot.identity, 20010U, 20320U).boundary_satisfied,
        "actual-looking numbers cannot repair absent plan provenance");
}
}  // namespace

int main() {
  static_assert(BulkSessionTiming::grant_wait_budget_ms == 500U);
  static_assert(BulkSessionTiming::direction_guard_ms == 100U);
  static_assert(BulkSessionTiming::hard_lease_ms == 28000U);
  static_assert(BulkSessionAccounting::completion_deadline_ms == 30000U);
  missing_and_identity();
  all_interval_validation();
  boundaries_and_transport();
  overflow_and_independent_clocks();
  individual_observations();
  std::cout << "r19-start-admission checks=" << checks
            << " failures=" << failures
            << " product_integrated=0 real_reservation_producer=0\n";
  return failures == 0U ? 0 : 1;
}
#endif
