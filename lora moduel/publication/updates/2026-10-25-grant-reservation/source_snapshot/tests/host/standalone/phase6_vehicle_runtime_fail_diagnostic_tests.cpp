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

int main() {
  Report report{};
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  e220_serial.set_config_responses_enabled(false);
  setup_bridge();
  report.check(!bridge_ready && runtime_fail_closed &&
                   startup_contract.fault() ==
                       vc_lora::FirmwareStartupFault::ProfileReadInvalid,
               "Vehicle startup profile fault was not fail-closed");
  report.check(Serial.baud_rate() == 115200U,
               "Vehicle independent COM3 was not initialized at 115200");

  const std::size_t rf_before = e220_serial.normal_tx_bytes().size();
  const std::size_t pixhawk_before = pixhawk_serial.normal_tx_bytes().size();
  latch_runtime_fail_closed_at(0x4444U);
  report.check(r19_runtime_fail_latch.evidence().source_line != 0U &&
                   r19_runtime_fail_latch.evidence().source_line != 0x4444U &&
                   r19_runtime_fail_latch.evidence().status.startup_fault ==
                       static_cast<std::uint8_t>(
                           vc_lora::FirmwareStartupFault::ProfileReadInvalid),
               "Vehicle startup evidence was absent or overwritten");
  loop_bridge();
  report.check(Serial.tx_bytes().empty() &&
                   !r19_runtime_fail_diagnostic_published,
               "Vehicle published startup evidence before COM3 host-ready");

  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  loop_bridge();
  loop_bridge();

  report.check(runtime_fail_closed && !bridge_ready,
               "Vehicle diagnostic changed fail-close state");
  report.check(r19_runtime_fail_diagnostic_published,
               "Vehicle diagnostic did not complete after early-return loops");
  report.check(Serial.tx_write_sizes().size() == 1U &&
                   Serial.tx_write_sizes()[0U] == 63U,
               "Vehicle did not retain one complete 63-byte bootstrap frame");
  report.check(Serial.flush_count() == 1U,
               "Vehicle diagnostic was not physically flushed once");
  report.check(e220_serial.normal_tx_bytes().size() == rf_before &&
                   pixhawk_serial.normal_tx_bytes().size() == pixhawk_before,
               "Vehicle diagnostic leaked into E220 or Pixhawk UART");

  vc_lora::MavlinkFrame frame{};
  const auto& bytes = Serial.tx_bytes();
  report.check(bytes.size() == 63U &&
                   vc_lora::validate_mavlink_frame(
                       bytes.data(), bytes.size(), frame) ==
                       vc_lora::MavlinkParseStatus::FrameReady,
               "Vehicle diagnostic is not one CRC-valid MAVLink frame");
  report.check(frame.message_id == 253U && frame.system_id == 254U &&
                   frame.component_id == 190U && frame.payload_length == 51U,
               "Vehicle diagnostic MAVLink identity changed");
  const std::string text(
      reinterpret_cast<const char*>(frame.payload() + 1U), 50U);
  report.check(text.rfind("R19F:V:", 0U) == 0U &&
                   text.substr(29U, 2U) == "02",
               "Vehicle diagnostic text does not carry role/source evidence");
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 63U &&
                   Serial.flush_count() == 1U,
               "Vehicle diagnostic repeated before the fixed cadence");

  fake_arduino::advance_time_ms(
      vc_lora::experimental::R19RuntimeDiagnosticCadence::period_ms);
  loop_bridge();
  loop_bridge();
  vc_lora::MavlinkFrame repeated{};
  const auto& repeated_bytes = Serial.tx_bytes();
  report.check(repeated_bytes.size() == 126U &&
                   vc_lora::validate_mavlink_frame(
                       repeated_bytes.data() + 63U, 63U, repeated) ==
                       vc_lora::MavlinkParseStatus::FrameReady,
               "Vehicle did not repeat first-failure evidence on cadence");
  const std::string repeated_text(
      reinterpret_cast<const char*>(repeated.payload() + 1U), 50U);
  report.check(repeated_text == text &&
                   r19_runtime_diagnostic_cadence.fail_transmissions() == 2U,
               "Vehicle repeat replaced first-wins evidence or accounting");
  report.check(e220_serial.normal_tx_bytes().size() == rf_before &&
                   pixhawk_serial.normal_tx_bytes().size() == pixhawk_before,
               "Vehicle repeated failure leaked into E220 or Pixhawk UART");

  std::cout << "IT-R19-VEHICLE-RUNTIME-FAIL-DIAGNOSTIC-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
