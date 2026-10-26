#include "fake_arduino_test_api.hpp"

#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"

#include <array>
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

vc_lora::MavlinkFrame product_frame() {
  std::array<std::uint8_t, 51U> payload{};
  payload[0U] = 6U;
  vc_lora::MavlinkFrame frame{};
  (void)vc_lora::encode_mavlink_v2(
      0x44U, 1U, 1U, 253U, payload.data(), payload.size(), frame);
  return frame;
}

}  // namespace

int main() {
  Report report{};
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  setup_bridge();

  // ARMED becomes pending at boot, before a host is necessarily able to open
  // the newly enumerated CDC endpoint.  Absence of a writable host must not
  // consume the bounded convergence budget or permanently disable the
  // diagnostic before capture starts.
  loop_bridge();
  fake_arduino::advance_time_ms(
      kR19RuntimeAliveGroundConvergenceBudgetMs + 1U);
  loop_bridge();
  report.check(!r19_runtime_fail_diagnostic_transport_failed &&
                   !r19_runtime_alive_ground_reservation_active &&
                   r19_runtime_alive_ground_reservation_deadline_ms == 0U &&
                   r19_ground_runtime_alive_reservation_pending(),
               "Ground consumed the ALIVE reservation before USB host-ready");

  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  loop_bridge();
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 63U,
               "Ground ARMED did not complete after late USB host attach");

  const vc_lora::MavlinkFrame product = product_frame();
  report.check(radio_application_endpoint.admit_validated_frame(product) ==
                   vc_lora::ValidatedLocalIngressStatus::QueuedFrame,
               "could not stage the admitted product frame");
  fake_arduino::advance_time_ms(
      vc_lora::experimental::R19RuntimeDiagnosticCadence::period_ms);
  Serial.set_available_for_write(0);
  loop_bridge();
  report.check(!r19_runtime_fail_diagnostic_transport_failed &&
                   !radio_application_endpoint.egress().empty(),
               "ALIVE reservation fixture did not block on USB backpressure");

  fake_arduino::advance_time_ms(500U);
  loop_bridge();
  report.check(r19_runtime_fail_diagnostic_transport_failed &&
                   r19_runtime_diagnostic_transport_trace.
                           first_failure_reason ==
                       R19RuntimeDiagnosticTransportFailureReason::
                           GroundReservationDeadlineExpired,
               "Ground ALIVE reservation did not stop at its hard deadline");
  report.check(Serial.tx_bytes().size() == 63U &&
                   !radio_application_endpoint.egress().empty() &&
                   Serial.flush_count() == 1U,
               "deadline handling wrote a partial product/diagnostic frame");

  std::cout << "IT-R19-GROUND-RUNTIME-ALIVE-BACKPRESSURE-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
