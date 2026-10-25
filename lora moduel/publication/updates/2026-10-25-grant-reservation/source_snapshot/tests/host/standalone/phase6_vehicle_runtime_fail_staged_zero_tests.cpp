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

  // Commit ARMED sequence 0, then stage ALIVE sequence 1 without accepting a
  // prefix. Cancelling that untouched frame must reuse sequence 1 for R19F;
  // otherwise a diagnostic-only cancellation looks like MAVLink packet loss.
  loop_bridge();
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 63U &&
                   Serial.flush_count() == 1U,
               "Vehicle ARMED fixture did not commit sequence zero");
  fake_arduino::advance_time_ms(
      vc_lora::experimental::R19RuntimeDiagnosticCadence::period_ms);
  Serial.set_tx_checked_accept_limit(0U);
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 63U &&
                   r19_runtime_fail_diagnostic_staged &&
                   r19_runtime_diagnostic_action ==
                       R19RuntimeDiagnosticAction::Alive &&
                   r19_runtime_alive_publisher.remaining() == 63U,
               "zero-accept fixture did not hold one untouched R19A frame");

  latch_runtime_fail_closed_at(0x5A5AU);
  Serial.set_tx_checked_accept_limit(
      std::numeric_limits<std::size_t>::max());

  // First-failure evidence must preempt an R19A whose accepted prefix is
  // exactly zero. Starting the obsolete liveness frame here delays the root
  // cause and makes priority depend on two unrelated USB transactions.
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 95U &&
                   r19_runtime_diagnostic_action ==
                       R19RuntimeDiagnosticAction::FailRepeat &&
                   r19_runtime_fail_publisher.pending(),
               "untouched R19A was not cancelled for immediate R19F priority");
  loop_bridge();

  vc_lora::MavlinkFrame frame{};
  const auto& bytes = Serial.tx_bytes();
  report.check(bytes.size() == 126U &&
                   vc_lora::validate_mavlink_frame(
                       bytes.data() + 63U, 63U, frame) ==
                       vc_lora::MavlinkParseStatus::FrameReady,
               "zero-prefix preemption did not emit one complete MAVLink frame");
  const std::string text(
      frame.size == 63U
          ? reinterpret_cast<const char*>(frame.payload() + 1U)
          : "",
      frame.size == 63U ? 50U : 0U);
  report.check(text.rfind("R19F:V:5A5A:", 0U) == 0U,
               "zero-prefix preemption emitted R19A before first R19F");
  report.check(frame.sequence == 1U,
               "cancelled zero-prefix R19A consumed a MAVLink sequence");
  report.check(r19_runtime_fail_diagnostic_published &&
                   r19_runtime_diagnostic_cadence.fail_transmissions() == 1U &&
                   Serial.flush_count() == 2U,
               "zero-prefix R19F did not complete one physical commit");

  std::cout << "IT-R19-VEHICLE-RUNTIME-FAIL-STAGED-ZERO-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
