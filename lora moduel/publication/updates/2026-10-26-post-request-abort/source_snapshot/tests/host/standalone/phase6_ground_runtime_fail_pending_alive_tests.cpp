#include "fake_arduino_test_api.hpp"

#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"

#include <array>
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
  report.check(bridge_ready && !runtime_fail_closed,
               "Ground setup did not reach Ready");

  loop_bridge();
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 63U,
               "Ground ARMED fixture did not complete");

  fake_arduino::advance_time_ms(
      vc_lora::experimental::R19RuntimeDiagnosticCadence::period_ms);
  report.check(r19_runtime_diagnostic_cadence.due(monotonic_now_ms(), false) ==
                   R19RuntimeDiagnosticAction::Alive,
               "could not stage the pending ALIVE scheduler fixture");

  const vc_lora::MavlinkFrame first = heartbeat(0x61U);
  const vc_lora::MavlinkFrame second = heartbeat(0x62U);
  report.check(radio_application_endpoint.admit_validated_frame(first) ==
                       vc_lora::ValidatedLocalIngressStatus::QueuedFrame &&
                   radio_application_endpoint.admit_validated_frame(second) ==
                       vc_lora::ValidatedLocalIngressStatus::QueuedFrame &&
                   !radio_application_endpoint.egress().empty(),
               "could not stage the dirty Ground boundary fixture");

  latch_runtime_fail_closed_at(0x6161U);
  for (std::size_t attempt = 0U; attempt < 8U &&
                                  !r19_runtime_fail_diagnostic_published;
       ++attempt) {
    loop_bridge();
  }

  report.check(r19_runtime_fail_diagnostic_published &&
                   r19_runtime_diagnostic_cadence.fail_transmissions() == 1U,
               "first failure did not preempt pending ALIVE and publish R19F");
  report.check(radio_application_endpoint.egress().empty() &&
                   !radio_application_endpoint.egress().write_pending() &&
                   r19_runtime_fail_ground_boundary_status ==
                       R19RuntimeFailGroundBoundaryStatus::Clean,
               "Ground did not converge to a clean boundary after preemption");

  const auto& bytes = Serial.tx_bytes();
  vc_lora::MavlinkFrame diagnostic{};
  const bool has_suffix =
      bytes.size() >= 63U &&
      vc_lora::validate_mavlink_frame(bytes.data() + bytes.size() - 63U,
                                      63U, diagnostic) ==
          vc_lora::MavlinkParseStatus::FrameReady;
  const std::string text =
      has_suffix
          ? std::string(reinterpret_cast<const char*>(diagnostic.payload() + 1U),
                        50U)
          : std::string{};
  report.check(has_suffix && text.rfind("R19F:G:6161:", 0U) == 0U,
               "clean-boundary suffix was not the first-failure frame");

  std::cout << "IT-R19-GROUND-RUNTIME-FAIL-PENDING-ALIVE-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
