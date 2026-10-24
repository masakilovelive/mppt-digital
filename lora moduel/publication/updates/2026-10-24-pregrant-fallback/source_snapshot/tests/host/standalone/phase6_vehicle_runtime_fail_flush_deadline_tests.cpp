#include "fake_arduino_test_api.hpp"

#define VC_LORA_PHASE6_VEHICLE 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"

#include <cstddef>
#include <cstdint>
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
  setup_bridge();
  report.check(bridge_ready && !runtime_fail_closed,
               "Vehicle setup did not reach Ready");

  // Stage ARMED and accept only its first 32-byte write. The second service
  // starts one millisecond before the absolute 500-ms frame deadline. The fake
  // consumes the exact timeout passed to flushTxComplete(), so a fixed 100-ms
  // flush budget returns 99 ms late while a remaining-time clamp returns at
  // the deadline and is conservatively rejected rather than committed.
  loop_bridge();
  const std::uint64_t deadline_ms =
      r19_runtime_diagnostic_frame_deadline_ms;
  const std::uint64_t staged_ms = monotonic_now_ms();
  report.check(Serial.tx_bytes().size() == 32U &&
                   r19_runtime_alive_publisher.remaining() == 31U &&
                   deadline_ms == staged_ms + 500U,
               "partial ARMED fixture did not establish a 500-ms deadline");
  fake_arduino::advance_time_ms(deadline_ms - staged_ms - 1U);
  Serial.set_flush_consumes_timeout(true);

  loop_bridge();

  report.check(Serial.last_flush_timeout_ms() == 1U,
               "diagnostic flush budget was not clamped to deadline remainder");
  report.check(monotonic_now_ms() <= deadline_ms,
               "diagnostic service returned after its absolute frame deadline");
  report.check(r19_runtime_fail_diagnostic_transport_failed &&
                   !r19_runtime_fail_diagnostic_published &&
                   r19_runtime_diagnostic_cadence.diagnostic_sequence() == 0U &&
                   r19_runtime_diagnostic_transport_trace.
                           first_failure_reason ==
                       R19RuntimeDiagnosticTransportFailureReason::
                           FlushCompletedLate,
               "deadline-edge flush was incorrectly committed");
  report.check(Serial.tx_bytes().size() == 63U &&
                   Serial.flush_count() == 1U,
               "deadline-edge fixture did not retain one complete wire frame");

  // The complete 63-byte frame is already owned by HWCDC, so a late physical
  // pickup must remain fail-closed for the current service call without
  // becoming a permanent diagnostic blackout.  Once the same loss epoch
  // reaches a clean flush boundary, commit the retained frame without replay.
  Serial.set_flush_consumes_timeout(false);
  loop_bridge();
  report.check(!r19_runtime_fail_diagnostic_transport_failed &&
                   !r19_runtime_fail_diagnostic_staged &&
                   !r19_runtime_fail_diagnostic_flush_pending &&
                   r19_runtime_diagnostic_cadence.diagnostic_sequence() == 1U,
               "deadline-edge frame did not recover after a later clean "
               "same-epoch flush");
  report.check(Serial.tx_bytes().size() == 63U &&
                   Serial.flush_count() == 2U &&
                   r19_runtime_diagnostic_transport_trace.
                           first_failure_reason ==
                       R19RuntimeDiagnosticTransportFailureReason::
                           FlushCompletedLate,
               "recovery replayed bytes or overwrote first failure evidence");

  std::cout << "IT-R19-VEHICLE-RUNTIME-FAIL-FLUSH-DEADLINE-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
