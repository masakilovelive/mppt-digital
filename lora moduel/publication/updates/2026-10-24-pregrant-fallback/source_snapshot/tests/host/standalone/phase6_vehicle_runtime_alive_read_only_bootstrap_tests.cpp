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

  // Reproduce the live read-only capture plus the documented IDF SOF-watchdog
  // false-negative: Windows has enumerated the native HWCDC port and the TX
  // ring has capacity, but isPlugged() and the cached endpoint bit are both
  // false.  Bootstrap must not wait for a host OUT transfer or a reliable SOF
  // sample before retaining the first complete frame.
  Serial.set_plugged(false);
  Serial.set_endpoint_ready(false);
  Serial.set_available_for_write(256);
  setup_bridge();

  report.check(bridge_ready && !runtime_fail_closed,
               "Vehicle setup did not reach Ready");
  report.check(!Serial.isPlugged() && !static_cast<bool>(Serial) &&
                   Serial.availableForWrite() > 0 && Serial.available() == 0,
               "fixture does not model false-SOF/read-only HWCDC bootstrap");

  // The diagnostic firmware boots before the read-only capture process opens
  // COM3.  A complete bootstrap frame must therefore remain queued without a
  // frame deadline or a permanent transport failure while the cached endpoint
  // bit is still false.  No host-visible byte is claimed during that interval.
  for (std::size_t sample = 0U; sample < 20U; ++sample) {
    loop_bridge();
    fake_arduino::advance_time_ms(100U);
  }

  report.check(r19_runtime_fail_diagnostic_staged &&
                   r19_runtime_fail_diagnostic_flush_pending &&
                   r19_runtime_diagnostic_frame_deadline_ms == 0U &&
                   !r19_runtime_fail_diagnostic_transport_failed,
               "Vehicle did not retain one complete bootstrap frame while "
               "the read-only COM endpoint was late-open");
  report.check(Serial.tx_bytes().empty(),
               "Vehicle claimed host-visible bytes before COM3 opened");

  // A host IN pickup can make the endpoint ready while the SOF watchdog still
  // reads false.  The already-retained frame must then complete without being
  // restaged or changing its MAVLink sequence.
  Serial.set_endpoint_ready(true);
  Serial.set_flush_failures(1U);
  loop_bridge();
  fake_arduino::advance_time_ms(100U);
  report.check(r19_runtime_fail_diagnostic_flush_pending &&
                   Serial.tx_bytes().empty() &&
                   !r19_runtime_fail_diagnostic_transport_failed,
               "Vehicle discarded the complete bootstrap after one bounded "
               "post-open flush miss");
  for (std::size_t sample = 0U;
       sample < 20U && Serial.tx_bytes().size() < 63U; ++sample) {
    loop_bridge();
    fake_arduino::advance_time_ms(100U);
  }

  vc_lora::MavlinkFrame armed{};
  const auto& bytes = Serial.tx_bytes();
  const bool first_frame_valid =
      bytes.size() >= 63U &&
      vc_lora::validate_mavlink_frame(bytes.data(), 63U, armed) ==
          vc_lora::MavlinkParseStatus::FrameReady;
  report.check(first_frame_valid,
               "read-only HWCDC never bootstrapped the first ARMED frame");
  report.check(!r19_runtime_fail_diagnostic_transport_failed,
               "late COM3 open converted retained bootstrap into failure");

  // A USB session reset after all 63 bytes were accepted but before flush
  // proof must re-arm the exact same wire image/sequence for the new session.
  Serial.set_endpoint_ready(false);
  for (std::size_t sample = 0U;
       sample < 20U && !r19_runtime_fail_diagnostic_flush_pending; ++sample) {
    loop_bridge();
    fake_arduino::advance_time_ms(100U);
  }
  report.check(r19_runtime_diagnostic_bootstrap_pending &&
                   r19_runtime_fail_diagnostic_flush_pending &&
                   Serial.tx_bytes().size() == 63U,
               "Vehicle did not queue the next complete bootstrap before "
               "the reset fixture");

  Serial.simulate_tx_loss();
  loop_bridge();
  fake_arduino::advance_time_ms(100U);
  report.check(r19_runtime_diagnostic_bootstrap_pending &&
                   !r19_runtime_fail_diagnostic_flush_pending &&
                   r19_runtime_diagnostic_frame_deadline_ms == 0U &&
                   !r19_runtime_fail_diagnostic_transport_failed,
               "Vehicle did not re-arm the same bootstrap after epoch reset");

  loop_bridge();
  fake_arduino::advance_time_ms(100U);
  report.check(r19_runtime_fail_diagnostic_flush_pending &&
                   r19_runtime_diagnostic_frame_deadline_ms == 0U,
               "Vehicle did not re-enqueue the reset bootstrap without a "
               "pre-open deadline");
  Serial.set_endpoint_ready(true);
  for (std::size_t sample = 0U;
       sample < 20U && Serial.tx_bytes().size() < 126U; ++sample) {
    loop_bridge();
    fake_arduino::advance_time_ms(100U);
  }
  vc_lora::MavlinkFrame alive{};
  report.check(Serial.tx_bytes().size() >= 126U &&
                   vc_lora::validate_mavlink_frame(
                       Serial.tx_bytes().data() + 63U, 63U, alive) ==
                       vc_lora::MavlinkParseStatus::FrameReady &&
                   alive.sequence == static_cast<std::uint8_t>(armed.sequence +
                                                               1U),
               "Vehicle reset retry did not preserve one complete next "
               "MAVLink frame/sequence");

  std::cout
      << "IT-R19-VEHICLE-RUNTIME-ALIVE-READ-ONLY-BOOTSTRAP-001 checks="
      << report.checks << " failures=" << report.failures
      << " tx_bytes=" << bytes.size() << '\n';
  return report.failures == 0U ? 0 : 1;
}
