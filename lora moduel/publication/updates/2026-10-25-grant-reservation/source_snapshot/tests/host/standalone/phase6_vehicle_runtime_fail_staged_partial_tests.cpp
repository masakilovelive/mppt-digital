#include "fake_arduino_test_api.hpp"

#define VC_LORA_PHASE6_VEHICLE 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"

#include <cstddef>
#include <cstdint>
#include <iostream>
#include <limits>
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

bool parse_frame_at(std::size_t offset, vc_lora::MavlinkFrame& frame) {
  const auto& bytes = Serial.tx_bytes();
  return offset <= bytes.size() && bytes.size() - offset >= 63U &&
         vc_lora::validate_mavlink_frame(bytes.data() + offset, 63U, frame) ==
             vc_lora::MavlinkParseStatus::FrameReady;
}

}  // namespace

int main() {
  Report report{};
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  Serial.set_tx_checked_accept_limit(11U);
  setup_bridge();
  report.check(bridge_ready && !runtime_fail_closed,
               "Vehicle setup did not reach Ready");

  // Once any R19A prefix is accepted, cancellation would corrupt the serial
  // MAVLink stream. The staged frame owns the boundary until its suffix and
  // physical flush complete.
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 11U &&
                   r19_runtime_fail_diagnostic_staged &&
                   r19_runtime_diagnostic_action ==
                       R19RuntimeDiagnosticAction::Armed &&
                   r19_runtime_alive_publisher.remaining() == 52U,
               "partial-accept fixture did not retain the R19A suffix");

  latch_runtime_fail_closed_at(0x5B5BU);
  Serial.set_tx_checked_accept_limit(
      std::numeric_limits<std::size_t>::max());

  loop_bridge();
  report.check(Serial.tx_bytes().size() == 43U &&
                   r19_runtime_diagnostic_action ==
                       R19RuntimeDiagnosticAction::Armed &&
                   !r19_runtime_fail_diagnostic_published &&
                   Serial.flush_count() == 0U,
               "partial R19A was cancelled or interleaved after first failure");
  loop_bridge();

  vc_lora::MavlinkFrame armed{};
  report.check(Serial.tx_bytes().size() == 63U &&
                   parse_frame_at(0U, armed) && Serial.flush_count() == 1U,
               "partial R19A did not finish as one CRC-valid frame");
  const std::string armed_text(
      armed.size == 63U
          ? reinterpret_cast<const char*>(armed.payload() + 1U)
          : "",
      armed.size == 63U ? 47U : 0U);
  report.check(armed_text.rfind("R19A:V:A:00000000:", 0U) == 0U,
               "completed prefix owner was not the original ARMED frame");
  report.check(r19_runtime_diagnostic_action ==
                       R19RuntimeDiagnosticAction::None &&
                   !r19_runtime_fail_diagnostic_published,
               "R19F was marked committed before the partial R19A boundary");

  loop_bridge();
  loop_bridge();

  vc_lora::MavlinkFrame failure{};
  report.check(Serial.tx_bytes().size() == 126U &&
                   parse_frame_at(63U, failure) &&
                   Serial.flush_count() == 2U,
               "R19F did not follow the completed R19A as a whole frame");
  const std::string failure_text(
      failure.size == 63U
          ? reinterpret_cast<const char*>(failure.payload() + 1U)
          : "",
      failure.size == 63U ? 50U : 0U);
  report.check(failure_text.rfind("R19F:V:5B5B:", 0U) == 0U,
               "post-prefix frame is not the first-failure evidence");
  report.check(Serial.tx_write_sizes().size() == 5U &&
                   Serial.tx_write_sizes()[0U] == 11U &&
                   Serial.tx_write_sizes()[1U] == 32U &&
                   Serial.tx_write_sizes()[2U] == 20U &&
                   Serial.tx_write_sizes()[3U] == 32U &&
                   Serial.tx_write_sizes()[4U] == 31U &&
                   r19_runtime_fail_diagnostic_published &&
                   r19_runtime_diagnostic_cadence.fail_transmissions() == 1U,
               "partial-boundary write/commit accounting changed");

  std::cout << "IT-R19-VEHICLE-RUNTIME-FAIL-STAGED-PARTIAL-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
