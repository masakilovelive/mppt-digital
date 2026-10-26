#include "fake_arduino_test_api.hpp"
#include "esp_timer.h"

#include <cstddef>
#include <cstdint>
#include <iostream>

namespace deadline_clock {

bool inject_late_flush_completion{false};
std::size_t reads_after_arm{0U};

}  // namespace deadline_clock

std::int64_t r19_deadline_test_esp_timer_get_time() noexcept {
  if (deadline_clock::inject_late_flush_completion &&
      deadline_clock::reads_after_arm++ == 2U) {
    // The convergence call starts at t0+499 ms.  Its third clock read is the
    // physical-flush completion observation: make that completion t0+501 ms,
    // two milliseconds after the hard 500-ms convergence deadline while
    // remaining well inside the flush operation's own 100-ms budget.
    fake_arduino::now_us += 2'000U;
  }
  return static_cast<std::int64_t>(fake_arduino::now_us);
}

// esp_timer.h is deliberately included before this replacement.  Only the
// production bridge translation unit's clock reads are routed through the
// deterministic late-completion clock above; the shared fake remains
// unchanged for every other host test.
#define esp_timer_get_time r19_deadline_test_esp_timer_get_time
#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"
#undef esp_timer_get_time

#include <array>

namespace {

using namespace vc_lora_phase6_firmware;

struct Report final {
  std::size_t checks{0U};
  std::size_t failures{0U};
  void check(bool condition, const char* message) {
    ++checks;
    if (!condition) {
      ++failures;
      std::cerr << "FAIL: " << message << '\n';
    }
  }
};

vc_lora::MavlinkFrame heartbeat(std::uint8_t sequence) {
  constexpr std::array<std::uint8_t, 9U> payload{
      0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U};
  vc_lora::MavlinkFrame frame{};
  (void)vc_lora::encode_mavlink_v2(sequence, 1U, 1U, 0U,
                                    payload.data(), payload.size(), frame);
  return frame;
}

}  // namespace

int main() {
  Report report{};
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  setup_bridge();

  const vc_lora::MavlinkFrame first = heartbeat(0x71U);
  const vc_lora::MavlinkFrame second = heartbeat(0x72U);
  report.check(radio_application_endpoint.admit_validated_frame(first) ==
                       vc_lora::ValidatedLocalIngressStatus::QueuedFrame &&
                   radio_application_endpoint.admit_validated_frame(second) ==
                       vc_lora::ValidatedLocalIngressStatus::QueuedFrame,
               "could not stage the two-write Ground boundary fixture");

  latch_runtime_fail_closed_at(0x7171U);
  report.check(!r19_converge_ground_runtime_fail_boundary(0U) &&
                   r19_runtime_fail_ground_boundary_status ==
                       R19RuntimeFailGroundBoundaryStatus::DrainingAdmitted &&
                   Serial.tx_bytes().size() == 32U,
               "first convergence step did not establish the 500-ms deadline");

  fake_arduino::advance_time_ms(499U);
  deadline_clock::reads_after_arm = 0U;
  deadline_clock::inject_late_flush_completion = true;
  const bool converged =
      r19_converge_ground_runtime_fail_boundary(499U);
  deadline_clock::inject_late_flush_completion = false;

  report.check(!converged &&
                   r19_runtime_fail_ground_boundary_status ==
                       R19RuntimeFailGroundBoundaryStatus::Impossible &&
                   r19_runtime_fail_diagnostic_transport_failed,
               "Ground classified a USB flush completed after the 500-ms "
               "deadline as Clean");
  report.check(r19_runtime_diagnostic_transport_trace.first_failure_reason ==
                   R19RuntimeDiagnosticTransportFailureReason::
                       GroundBoundaryFlushLate,
               "Ground late flush completion did not retain its "
               "branch-specific transport reason");
  report.check(!r19_runtime_fail_diagnostic_published,
               "Ground published a diagnostic across a late boundary");

  // The two complete product frames have already left LocalEgress and the
  // loss epoch is stable.  A later clean flush must recover the diagnostic
  // boundary without replaying that immutable product prefix.  Keep the
  // original late-completion evidence first-wins.
  Serial.set_flush_consumes_timeout(false);
  loop_bridge();
  report.check(!r19_runtime_fail_diagnostic_transport_failed &&
                   r19_runtime_fail_ground_boundary_status ==
                       R19RuntimeFailGroundBoundaryStatus::Clean &&
                   Serial.flush_count() == 2U &&
                   Serial.tx_bytes().size() == first.size + second.size,
               "Ground did not recover the same-epoch boundary or replayed "
               "the product prefix");
  report.check(r19_runtime_diagnostic_transport_trace.first_failure_reason ==
                   R19RuntimeDiagnosticTransportFailureReason::
                       GroundBoundaryFlushLate,
               "Ground recovery overwrote first failure evidence");

  loop_bridge();
  loop_bridge();
  if (Serial.tx_bytes().size() != first.size + second.size + 63U ||
      r19_runtime_diagnostic_cadence.fail_transmissions() != 1U) {
    std::cerr << "Ground recovery state: tx=" << Serial.tx_bytes().size()
              << " product=" << first.size + second.size
              << " sequence="
              << r19_runtime_diagnostic_cadence.diagnostic_sequence()
              << " fail_tx="
              << r19_runtime_diagnostic_cadence.fail_transmissions()
              << " fail_latched=" << r19_runtime_fail_latch.latched()
              << " staged=" << r19_runtime_fail_diagnostic_staged
              << " flush_pending="
              << r19_runtime_fail_diagnostic_flush_pending
              << " transport_failed="
              << r19_runtime_fail_diagnostic_transport_failed << '\n';
  }
  report.check(Serial.tx_bytes().size() ==
                       first.size + second.size + 63U &&
                   r19_runtime_diagnostic_cadence.fail_transmissions() == 1U,
               "Ground did not publish one diagnostic after boundary "
               "recovery");

  std::cout << "IT-R19-GROUND-RUNTIME-FAIL-DEADLINE-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
