#include "fake_arduino_test_api.hpp"
#include "esp_timer.h"

#include <cstddef>
#include <cstdint>
#include <iostream>
#include <string>

namespace recovery_guard_clock {

bool inject_late_flush_completion{false};
std::size_t reads_after_arm{0U};

}  // namespace recovery_guard_clock

std::int64_t r19_recovery_guard_esp_timer_get_time() noexcept {
  if (recovery_guard_clock::inject_late_flush_completion &&
      recovery_guard_clock::reads_after_arm++ == 2U) {
    fake_arduino::now_us += 2'000U;
  }
  return static_cast<std::int64_t>(fake_arduino::now_us);
}

#define esp_timer_get_time r19_recovery_guard_esp_timer_get_time
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

int main(int argc, char** argv) {
  Report report{};
  const std::string scenario = argc == 2 ? argv[1] : std::string{};
  report.check(scenario == "epoch" || scenario == "target" ||
                   scenario == "expiry",
               "expected epoch, target, or expiry scenario");

  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  setup_bridge();

  const vc_lora::MavlinkFrame first = heartbeat(0x81U);
  const vc_lora::MavlinkFrame second = heartbeat(0x82U);
  report.check(radio_application_endpoint.admit_validated_frame(first) ==
                       vc_lora::ValidatedLocalIngressStatus::QueuedFrame &&
                   radio_application_endpoint.admit_validated_frame(second) ==
                       vc_lora::ValidatedLocalIngressStatus::QueuedFrame,
               "could not stage the Ground recovery guard fixture");

  latch_runtime_fail_closed_at(0x8181U);
  report.check(!r19_converge_ground_runtime_fail_boundary(0U) &&
                   Serial.tx_bytes().size() == 32U,
               "first convergence step did not establish the deadline");

  fake_arduino::advance_time_ms(499U);
  recovery_guard_clock::reads_after_arm = 0U;
  recovery_guard_clock::inject_late_flush_completion = true;
  (void)r19_converge_ground_runtime_fail_boundary(499U);
  recovery_guard_clock::inject_late_flush_completion = false;
  report.check(r19_runtime_fail_diagnostic_transport_failed &&
                   r19_runtime_diagnostic_transport_recovery ==
                       R19RuntimeDiagnosticTransportRecovery::
                           GroundBoundaryFlush &&
                   Serial.tx_bytes().size() == first.size + second.size &&
                   Serial.flush_count() == 1U,
               "fixture did not enter Ground boundary flush recovery");

  if (scenario == "epoch") {
    Serial.simulate_tx_loss();
  } else if (scenario == "target") {
    ++r19_runtime_diagnostic_recovery_target_bytes;
  } else {
    fake_arduino::advance_time_ms(
        kR19RuntimeDiagnosticRecoveryBudgetMs);
  }
  loop_bridge();

  report.check(r19_runtime_fail_diagnostic_transport_failed &&
                   r19_runtime_diagnostic_transport_recovery ==
                       R19RuntimeDiagnosticTransportRecovery::None &&
                   r19_runtime_fail_ground_boundary_status ==
                       R19RuntimeFailGroundBoundaryStatus::Impossible,
               "Ground guard violation incorrectly cleared failure");
  report.check(Serial.tx_bytes().size() == first.size + second.size &&
                   Serial.flush_count() == 1U &&
                   r19_runtime_diagnostic_transport_trace.
                           first_failure_reason ==
                       R19RuntimeDiagnosticTransportFailureReason::
                           GroundBoundaryFlushLate,
               "Ground guard violation replayed bytes or overwrote evidence");

  std::cout << "IT-R19-GROUND-RUNTIME-FAIL-RECOVERY-GUARD-001 scenario="
            << scenario << " checks=" << report.checks
            << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
