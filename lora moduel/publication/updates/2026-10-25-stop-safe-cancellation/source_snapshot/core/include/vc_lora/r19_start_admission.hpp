#pragma once

#include <cstdint>
#include <limits>

#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/tdd_types.hpp"

namespace vc_lora {

// Offline arithmetic seam only; NOT a reservation producer, authentication,
// or permission to start a live session. In particular, producer_bound is a
// caller assertion, not evidence that a reservation actually exists. The
// product has no producer for these future-slot/clock-correspondence bounds
// and must not manufacture them from a nominal five-second TDD period.
//
// All values are finite uint64 MCU milliseconds. Ground intervals share one
// Ground boot/clock; Vehicle intervals share one Vehicle boot/clock. The
// vehicle_clock_at_ground_grant interval explicitly asserts the Vehicle clock
// reading at the Ground Grant-observation event. It must be independently
// bounded; directly subtracting Ground and Vehicle clock values is invalid.
struct R19StartAdmissionInterval final {
  std::uint64_t earliest_ms{0U};
  std::uint64_t latest_ms{0U};
  bool bounded{false};
};

struct R19StartAdmissionIdentity final {
  std::uint32_t slot_token{0U};
  std::uint64_t usb_epoch{0U};
  std::uint16_t grant_session{0U};
  std::uint16_t grant_cycle{0U};
};

struct R19StartAdmissionSlot final {
  R19StartAdmissionIdentity identity{};
  bool producer_bound{false};
  bool unused{false};
  bool request_before_grant_at_equal_timestamp{false};
  R19StartAdmissionInterval ground_request_accept{};
  R19StartAdmissionInterval ground_next_grant{};
  R19StartAdmissionInterval vehicle_grant_physical_tail{};
  R19StartAdmissionInterval vehicle_complete_vcbn{};
  R19StartAdmissionInterval vehicle_clock_at_ground_grant{};
  // Includes ALL delay after the mandatory 100-ms Ground direction guard:
  // polling/guard overshoot, writer availability, UART/RF delivery and complete
  // canonical-record parsing. A local 550-ms service floor is neither this
  // remote delay's maximum nor proof of its minimum. Unknown is bounded=false.
  R19StartAdmissionInterval transport_after_ground_guard{};
};

struct R19StartAdmissionContext final {
  R19StartAdmissionIdentity expected_identity{};
  std::uint16_t baseline_session{0U};
  std::uint16_t baseline_cycle{0U};
  // Actual complete #21 acceptance time, never shifted to the planned Grant.
  std::uint64_t original_t0_ms{0U};
};

enum class R19StartAdmissionStatus : std::uint8_t {
  NotReady = 0U,
  FeasiblePlan,
};

enum class R19StartAdmissionReason : std::uint8_t {
  None = 0U,
  ProducerUnavailable,
  SlotConsumed,
  InvalidIdentity,
  IdentityMismatch,
  StaleGrant,
  MissingBound,
  ReversedBound,
  RequestOutsideBound,
  RequestAfterGrant,
  EqualTimestampOrderUnknown,
  GroundWaitExceeded,
  VehicleOrderInvalid,
  VehicleWaitExceeded,
  TimeOverflow,
  TransportProjectionNotCovered,
  GrantOutsideBound,
  TailOutsideBound,
  VcbnOutsideBound,
};

struct R19StartAdmissionResult final {
  R19StartAdmissionStatus status{R19StartAdmissionStatus::NotReady};
  R19StartAdmissionReason reason{R19StartAdmissionReason::ProducerUnavailable};
  std::uint64_t original_t0_ms{0U};
};

// This witnesses ONE local-clock boundary against supplied assertions, not
// joint RF delivery, 932 parameters, acceptance, or permission to deploy.
// Observation APIs accept caller-validated canonical/CRC-checked events only;
// timestamp arguments alone are not a parser, packet, or acquisition proof.
struct R19StartObservationResult final {
  bool boundary_satisfied{false};
  R19StartAdmissionReason reason{R19StartAdmissionReason::ProducerUnavailable};
  std::uint64_t original_t0_ms{0U};
};

namespace r19_start_admission_detail {
constexpr bool valid_identity(const R19StartAdmissionIdentity& id) noexcept {
  // The retained Vehicle-Grant contract also rejects session/cycle zero.
  // Epoch zero is a legitimate observed loss counter. Presence/provenance
  // comes from the slot contract, never from treating a zero counter as absent.
  return id.slot_token != 0U && id.grant_session != 0U && id.grant_cycle != 0U;
}

constexpr bool same_identity(const R19StartAdmissionIdentity& a,
                              const R19StartAdmissionIdentity& b) noexcept {
  return a.slot_token == b.slot_token && a.usb_epoch == b.usb_epoch &&
         a.grant_session == b.grant_session && a.grant_cycle == b.grant_cycle;
}

constexpr bool contains(const R19StartAdmissionInterval& interval,
                        std::uint64_t value) noexcept {
  return interval.bounded && interval.earliest_ms <= value &&
         value <= interval.latest_ms;
}

constexpr bool fresh(const R19StartAdmissionIdentity& id,
                     const R19StartAdmissionContext& context) noexcept {
  return context.baseline_session != 0U &&
         (id.grant_session == context.baseline_session
              ? compare_sequence(id.grant_cycle, context.baseline_cycle) ==
                    SequenceOrder::Newer
              : compare_sequence(id.grant_session, context.baseline_session) ==
                    SequenceOrder::Newer);
}

constexpr bool checked_add(std::uint64_t a, std::uint64_t b,
                           std::uint64_t& result) noexcept {
  if (b > std::numeric_limits<std::uint64_t>::max() - a) return false;
  result = a + b;
  return true;
}

constexpr bool project_complete_vcbn(const R19StartAdmissionSlot& slot,
                                     std::uint64_t& first,
                                     std::uint64_t& last) noexcept {
  return checked_add(slot.vehicle_clock_at_ground_grant.earliest_ms,
                     BulkSessionTiming::direction_guard_ms, first) &&
         checked_add(first, slot.transport_after_ground_guard.earliest_ms,
                     first) &&
         checked_add(slot.vehicle_clock_at_ground_grant.latest_ms,
                     BulkSessionTiming::direction_guard_ms, last) &&
         checked_add(last, slot.transport_after_ground_guard.latest_ms, last);
}
}  // namespace r19_start_admission_detail

[[nodiscard]] constexpr R19StartAdmissionResult EvaluateR19StartAdmission(
    const R19StartAdmissionSlot& slot,
    const R19StartAdmissionContext& context) noexcept {
  using namespace r19_start_admission_detail;
  const auto reject = [&context](R19StartAdmissionReason reason) constexpr {
    return R19StartAdmissionResult{R19StartAdmissionStatus::NotReady, reason,
                                   context.original_t0_ms};
  };
  if (!slot.producer_bound) return reject(R19StartAdmissionReason::ProducerUnavailable);
  if (!slot.unused) return reject(R19StartAdmissionReason::SlotConsumed);
  if (!valid_identity(slot.identity) || !valid_identity(context.expected_identity))
    return reject(R19StartAdmissionReason::InvalidIdentity);
  if (!same_identity(slot.identity, context.expected_identity))
    return reject(R19StartAdmissionReason::IdentityMismatch);
  if (!fresh(slot.identity, context)) return reject(R19StartAdmissionReason::StaleGrant);
  const R19StartAdmissionInterval* const bounds[]{
      &slot.ground_request_accept, &slot.ground_next_grant,
      &slot.vehicle_grant_physical_tail, &slot.vehicle_complete_vcbn,
      &slot.vehicle_clock_at_ground_grant, &slot.transport_after_ground_guard};
  for (const auto* bound : bounds) {
    if (!bound->bounded) return reject(R19StartAdmissionReason::MissingBound);
    if (bound->earliest_ms > bound->latest_ms)
      return reject(R19StartAdmissionReason::ReversedBound);
  }
  if (!contains(slot.ground_request_accept, context.original_t0_ms))
    return reject(R19StartAdmissionReason::RequestOutsideBound);
  if (slot.ground_request_accept.latest_ms > slot.ground_next_grant.earliest_ms)
    return reject(R19StartAdmissionReason::RequestAfterGrant);
  if (slot.ground_request_accept.latest_ms == slot.ground_next_grant.earliest_ms &&
      !slot.request_before_grant_at_equal_timestamp)
    return reject(R19StartAdmissionReason::EqualTimestampOrderUnknown);
  if (slot.ground_next_grant.latest_ms - slot.ground_request_accept.earliest_ms >
      BulkSessionTiming::grant_wait_budget_ms)
    return reject(R19StartAdmissionReason::GroundWaitExceeded);
  if (slot.vehicle_complete_vcbn.earliest_ms <
      slot.vehicle_grant_physical_tail.latest_ms)
    return reject(R19StartAdmissionReason::VehicleOrderInvalid);
  if (slot.vehicle_complete_vcbn.latest_ms -
          slot.vehicle_grant_physical_tail.earliest_ms >
      BulkSessionTiming::grant_wait_budget_ms)
    return reject(R19StartAdmissionReason::VehicleWaitExceeded);
  std::uint64_t projected_first = 0U;
  std::uint64_t projected_last = 0U;
  if (!project_complete_vcbn(slot, projected_first, projected_last))
    return reject(R19StartAdmissionReason::TimeOverflow);
  if (slot.vehicle_complete_vcbn.earliest_ms > projected_first ||
      slot.vehicle_complete_vcbn.latest_ms < projected_last)
    return reject(R19StartAdmissionReason::TransportProjectionNotCovered);
  return {R19StartAdmissionStatus::FeasiblePlan, R19StartAdmissionReason::None,
          context.original_t0_ms};
}

[[nodiscard]] constexpr R19StartObservationResult EvaluateR19GroundStartObservation(
    const R19StartAdmissionSlot& slot,
    const R19StartAdmissionContext& context,
    const R19StartAdmissionIdentity& observed_identity,
    std::uint64_t actual_grant_ms) noexcept {
  using namespace r19_start_admission_detail;
  const auto plan = EvaluateR19StartAdmission(slot, context);
  if (plan.status != R19StartAdmissionStatus::FeasiblePlan)
    return {false, plan.reason, context.original_t0_ms};
  if (!same_identity(slot.identity, observed_identity))
    return {false, R19StartAdmissionReason::IdentityMismatch, context.original_t0_ms};
  if (!contains(slot.ground_next_grant, actual_grant_ms))
    return {false, R19StartAdmissionReason::GrantOutsideBound, context.original_t0_ms};
  if (actual_grant_ms < context.original_t0_ms)
    return {false, R19StartAdmissionReason::RequestAfterGrant, context.original_t0_ms};
  if (actual_grant_ms == context.original_t0_ms &&
      !slot.request_before_grant_at_equal_timestamp)
    return {false, R19StartAdmissionReason::EqualTimestampOrderUnknown,
            context.original_t0_ms};
  if (actual_grant_ms - context.original_t0_ms > BulkSessionTiming::grant_wait_budget_ms)
    return {false, R19StartAdmissionReason::GroundWaitExceeded, context.original_t0_ms};
  return {true, R19StartAdmissionReason::None, context.original_t0_ms};
}

[[nodiscard]] constexpr R19StartObservationResult EvaluateR19VehicleStartObservation(
    const R19StartAdmissionSlot& slot,
    const R19StartAdmissionContext& context,
    const R19StartAdmissionIdentity& observed_identity,
    std::uint64_t actual_physical_tail_ms,
    std::uint64_t actual_complete_vcbn_ms) noexcept {
  using namespace r19_start_admission_detail;
  const auto plan = EvaluateR19StartAdmission(slot, context);
  if (plan.status != R19StartAdmissionStatus::FeasiblePlan)
    return {false, plan.reason, context.original_t0_ms};
  if (!same_identity(slot.identity, observed_identity))
    return {false, R19StartAdmissionReason::IdentityMismatch, context.original_t0_ms};
  if (!contains(slot.vehicle_grant_physical_tail, actual_physical_tail_ms))
    return {false, R19StartAdmissionReason::TailOutsideBound, context.original_t0_ms};
  if (!contains(slot.vehicle_complete_vcbn, actual_complete_vcbn_ms))
    return {false, R19StartAdmissionReason::VcbnOutsideBound, context.original_t0_ms};
  if (actual_complete_vcbn_ms < actual_physical_tail_ms)
    return {false, R19StartAdmissionReason::VehicleOrderInvalid, context.original_t0_ms};
  if (actual_complete_vcbn_ms - actual_physical_tail_ms >
      BulkSessionTiming::grant_wait_budget_ms)
    return {false, R19StartAdmissionReason::VehicleWaitExceeded, context.original_t0_ms};
  std::uint64_t projected_first = 0U;
  std::uint64_t projected_last = 0U;
  if (!project_complete_vcbn(slot, projected_first, projected_last))
    return {false, R19StartAdmissionReason::TimeOverflow, context.original_t0_ms};
  if (actual_complete_vcbn_ms < projected_first || actual_complete_vcbn_ms > projected_last)
    return {false, R19StartAdmissionReason::TransportProjectionNotCovered,
            context.original_t0_ms};
  return {true, R19StartAdmissionReason::None, context.original_t0_ms};
}

static_assert(BulkSessionTiming::grant_wait_budget_ms == 500U);
static_assert(BulkSessionTiming::direction_guard_ms == 100U);
static_assert(BulkSessionTiming::hard_lease_ms == 28000U);
static_assert(BulkSessionAccounting::completion_deadline_ms == 30000U);
// This seam does not start or reset a lease, enqueue #21, schedule a Grant,
// drive a writer, or implement a private slot reservation protocol. The PC's
// original request-origin 30-second accounting remains a separate obligation.
}  // namespace vc_lora
