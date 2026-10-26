#include "fake_arduino_test_api.hpp"

#define VC_LORA_PHASE6_VEHICLE 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"

#include <cstddef>
#include <cstdint>
#include <iostream>
#include <string>

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

}  // namespace

int main(int argc, char** argv) {
  Report report{};
  const std::string scenario = argc == 2 ? argv[1] : std::string{};
  report.check(scenario == "epoch" || scenario == "expiry",
               "expected epoch or expiry scenario");

  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  setup_bridge();

  loop_bridge();
  const std::uint64_t deadline_ms =
      r19_runtime_diagnostic_frame_deadline_ms;
  const std::uint64_t staged_ms = monotonic_now_ms();
  fake_arduino::advance_time_ms(deadline_ms - staged_ms - 1U);
  Serial.set_flush_consumes_timeout(true);
  loop_bridge();
  report.check(r19_runtime_fail_diagnostic_transport_failed &&
                   r19_runtime_diagnostic_transport_recovery ==
                       R19RuntimeDiagnosticTransportRecovery::FrameFlush &&
                   Serial.tx_bytes().size() == 63U &&
                   Serial.flush_count() == 1U,
               "fixture did not enter complete-frame flush recovery");

  Serial.set_flush_consumes_timeout(false);
  if (scenario == "epoch") {
    Serial.simulate_tx_loss();
  } else {
    fake_arduino::advance_time_ms(
        kR19RuntimeDiagnosticRecoveryBudgetMs);
  }
  loop_bridge();

  report.check(r19_runtime_fail_diagnostic_transport_failed &&
                   r19_runtime_diagnostic_transport_recovery ==
                       R19RuntimeDiagnosticTransportRecovery::None &&
                   r19_runtime_diagnostic_cadence.diagnostic_sequence() == 0U,
               "epoch drift or recovery expiry incorrectly cleared failure");
  report.check(Serial.tx_bytes().size() == 63U &&
                   Serial.flush_count() == 1U &&
                   r19_runtime_diagnostic_transport_trace.
                           first_failure_reason ==
                       R19RuntimeDiagnosticTransportFailureReason::
                           FlushCompletedLate,
               "guard failure replayed bytes or overwrote first evidence");

  std::cout << "IT-R19-VEHICLE-RUNTIME-FAIL-RECOVERY-GUARD-001 scenario="
            << scenario << " checks=" << report.checks
            << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
