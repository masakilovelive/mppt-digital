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

static_assert(static_cast<std::uint8_t>(
                  R19RuntimeDiagnosticTransportFailureReason::
                      GroundBoundaryImpossible) == 3U);
static_assert(static_cast<std::uint8_t>(
                  R19RuntimeDiagnosticTransportFailureReason::
                      AlivePublisherResetRejected) == 20U);
static_assert(static_cast<std::uint8_t>(
                  R19RuntimeDiagnosticTransportFailureReason::
                      GroundBoundaryHostLostWhileDraining) == 21U);
static_assert(static_cast<std::uint8_t>(
                  R19RuntimeDiagnosticTransportFailureReason::
                      GroundBoundaryFlushLate) == 30U);

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

  const vc_lora::MavlinkFrame first = heartbeat(0x31U);
  const vc_lora::MavlinkFrame second = heartbeat(0x32U);
  report.check(radio_application_endpoint.admit_validated_frame(first) ==
                       vc_lora::ValidatedLocalIngressStatus::QueuedFrame &&
                   radio_application_endpoint.admit_validated_frame(second) ==
                       vc_lora::ValidatedLocalIngressStatus::QueuedFrame,
               "could not stage the multi-chunk Ground boundary fixture");
  const std::size_t rf_before = e220_serial.normal_tx_bytes().size();
  latch_runtime_fail_closed_at(0x5151U);
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 32U &&
                   r19_runtime_fail_ground_boundary_status ==
                       R19RuntimeFailGroundBoundaryStatus::DrainingAdmitted,
               "Ground did not expose an in-progress admitted drain");

  Serial.simulate_tx_loss();
  loop_bridge();
  report.check(r19_runtime_fail_ground_boundary_status ==
                       R19RuntimeFailGroundBoundaryStatus::Impossible &&
                   r19_runtime_fail_diagnostic_transport_failed &&
                   !r19_runtime_fail_diagnostic_published,
               "Ground epoch loss was not latched as convergence-impossible");
  report.check(r19_runtime_diagnostic_transport_trace.first_failure_reason ==
                   R19RuntimeDiagnosticTransportFailureReason::
                       GroundBoundaryEpochChanged,
               "Ground epoch loss did not retain its branch-specific "
               "transport reason");
  report.check(Serial.tx_bytes().size() == 32U,
               "Ground emitted a diagnostic across an unproved boundary");
  report.check(e220_serial.normal_tx_bytes().size() == rf_before,
               "Ground convergence failure leaked bytes into E220");
  loop_bridge();
  report.check(r19_runtime_fail_diagnostic_transport_failed &&
                   r19_runtime_diagnostic_transport_recovery ==
                       R19RuntimeDiagnosticTransportRecovery::None &&
                   Serial.tx_bytes().size() == 32U,
               "Ground epoch loss was incorrectly recoverable");

  std::cout << "IT-R19-GROUND-RUNTIME-FAIL-BOUNDARY-LOSS-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
