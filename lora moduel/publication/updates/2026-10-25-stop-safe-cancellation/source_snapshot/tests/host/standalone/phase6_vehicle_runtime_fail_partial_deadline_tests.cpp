#include "fake_arduino_test_api.hpp"

#define VC_LORA_PHASE6_VEHICLE 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"

#include <cstddef>
#include <iostream>

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

int main() {
  Report report{};
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  Serial.set_tx_checked_accept_limit(11U);
  setup_bridge();
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 11U &&
                   r19_runtime_fail_diagnostic_staged &&
                   r19_runtime_alive_publisher.remaining() == 52U,
               "partial R19A fixture did not retain its accepted prefix");

  latch_runtime_fail_closed_at(0x6D6DU);
  Serial.set_available_for_write(0);
  fake_arduino::advance_time_ms(500U);
  loop_bridge();
  report.check(r19_runtime_fail_diagnostic_transport_failed &&
                   r19_runtime_diagnostic_transport_trace.
                           first_failure_reason ==
                       R19RuntimeDiagnosticTransportFailureReason::
                           FrameDeadlineExpired,
               "partial diagnostic frame had no hard progress deadline");
  report.check(Serial.tx_bytes().size() == 11U &&
                   Serial.flush_count() == 0U &&
                   !r19_runtime_fail_diagnostic_published,
               "deadline handling crossed an unproved partial boundary");

  Serial.set_available_for_write(64);
  loop_bridge();
  report.check(r19_runtime_fail_diagnostic_transport_failed &&
                   r19_runtime_diagnostic_transport_recovery ==
                       R19RuntimeDiagnosticTransportRecovery::None &&
                   Serial.tx_bytes().size() == 11U &&
                   Serial.flush_count() == 0U,
               "partial diagnostic prefix was incorrectly recoverable");

  std::cout << "IT-R19-VEHICLE-RUNTIME-FAIL-PARTIAL-DEADLINE-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
