#include "fake_arduino_test_api.hpp"

#define VC_LORA_PHASE6_GROUND 1
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

  // Reproduce the COM6 half of the sealed live read-only capture plus an IDF
  // SOF-watchdog false-negative: the native port is enumerated and its TX
  // ring has room, but both isPlugged() and cached CDC readiness are false.
  // Diagnostic bootstrap must not require host writes or a reliable SOF bit.
  Serial.set_plugged(false);
  Serial.set_endpoint_ready(false);
  Serial.set_available_for_write(256);
  setup_bridge();

  report.check(bridge_ready && !runtime_fail_closed,
               "Ground setup did not reach Ready");
  report.check(!Serial.isPlugged() && !static_cast<bool>(Serial) &&
                   Serial.availableForWrite() >= 63 &&
                   Serial.available() == 0,
               "fixture does not model false-SOF/read-only HWCDC bootstrap");

  // The diagnostic firmware boots before the read-only capture process opens
  // COM6.  Queue the complete R19A at the already-proved empty product
  // boundary, but do not start the Ground product-drain reservation/deadline
  // while host pickup is unavailable.
  for (std::size_t sample = 0U; sample < 20U; ++sample) {
    loop_bridge();
    fake_arduino::advance_time_ms(100U);
  }

  report.check(r19_runtime_fail_diagnostic_staged &&
                   r19_runtime_fail_diagnostic_flush_pending &&
                   r19_runtime_diagnostic_frame_deadline_ms == 0U &&
                   !r19_runtime_alive_ground_reservation_active &&
                   !r19_runtime_fail_diagnostic_transport_failed,
               "Ground did not retain one complete bootstrap frame without "
               "starting its product reservation deadline");
  report.check(Serial.tx_bytes().empty(),
               "Ground claimed host-visible bytes before COM6 opened");

  // Model later cached-endpoint recovery while SOF remains false.  The frame
  // retained during that interval must finish as the same complete wire image.
  Serial.set_endpoint_ready(true);
  Serial.set_flush_failures(1U);
  loop_bridge();
  fake_arduino::advance_time_ms(100U);
  report.check(r19_runtime_fail_diagnostic_flush_pending &&
                   Serial.tx_bytes().empty() &&
                   !r19_runtime_fail_diagnostic_transport_failed,
               "Ground discarded the complete bootstrap after one bounded "
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
               "read-only HWCDC never bootstrapped the first Ground ARMED "
               "frame");
  report.check(!first_frame_valid ||
                   (armed.message_id == 253U &&
                    armed.payload_byte_or_zero(0U) == 6U &&
                    armed.payload_byte_or_zero(1U) ==
                        static_cast<std::uint8_t>('R')),
               "Ground bootstrap did not preserve the R19A MAVLink contract");
  report.check(e220_serial.normal_tx_bytes().empty(),
               "Ground bootstrap leaked diagnostic bytes into E220");
  report.check(!r19_runtime_fail_diagnostic_transport_failed,
               "late COM6 open converted retained bootstrap into failure");

  // Ground must preserve the same no-reservation property across a USB reset
  // while the next complete bootstrap is waiting for host pickup.
  Serial.set_endpoint_ready(false);
  for (std::size_t sample = 0U;
       sample < 20U && !r19_runtime_fail_diagnostic_flush_pending; ++sample) {
    loop_bridge();
    fake_arduino::advance_time_ms(100U);
  }
  report.check(r19_runtime_diagnostic_bootstrap_pending &&
                   r19_runtime_fail_diagnostic_flush_pending &&
                   !r19_runtime_alive_ground_reservation_active &&
                   Serial.tx_bytes().size() == 63U,
               "Ground did not queue reset fixture at a no-reservation "
               "bootstrap boundary");

  Serial.simulate_tx_loss();
  loop_bridge();
  fake_arduino::advance_time_ms(100U);
  report.check(r19_runtime_diagnostic_bootstrap_pending &&
                   !r19_runtime_fail_diagnostic_flush_pending &&
                   r19_runtime_diagnostic_frame_deadline_ms == 0U &&
                   !r19_runtime_alive_ground_reservation_active &&
                   !r19_runtime_fail_diagnostic_transport_failed,
               "Ground reset did not re-arm without starting a reservation");
  loop_bridge();
  fake_arduino::advance_time_ms(100U);
  report.check(r19_runtime_fail_diagnostic_flush_pending &&
                   r19_runtime_diagnostic_frame_deadline_ms == 0U &&
                   !r19_runtime_alive_ground_reservation_active,
               "Ground reset retry did not retain its pre-open boundary");
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
                                                               1U) &&
                   !r19_runtime_alive_ground_reservation_active,
               "Ground reset retry changed the wire image/sequence or left "
               "a product reservation active");

  std::cout
      << "IT-R19-GROUND-RUNTIME-ALIVE-READ-ONLY-BOOTSTRAP-001 checks="
      << report.checks << " failures=" << report.failures
      << " tx_bytes=" << bytes.size() << '\n';
  return report.failures == 0U ? 0 : 1;
}
