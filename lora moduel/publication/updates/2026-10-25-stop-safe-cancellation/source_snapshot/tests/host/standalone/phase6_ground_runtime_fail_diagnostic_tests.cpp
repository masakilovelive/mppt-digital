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
  report.check(Serial.tx_bytes().empty(),
               "Ground emitted USB bytes before fail-close");

  constexpr std::array<std::uint8_t, 9U> heartbeat_payload{
      0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U};
  vc_lora::MavlinkFrame admitted_frame{};
  report.check(vc_lora::encode_mavlink_v2(
                   0x45U, 1U, 1U, 0U, heartbeat_payload.data(),
                   heartbeat_payload.size(), admitted_frame),
               "could not build the admitted Ground frame fixture");
  report.check(radio_application_endpoint.admit_validated_frame(
                   admitted_frame) ==
                   vc_lora::ValidatedLocalIngressStatus::QueuedFrame,
               "could not stage a non-empty Ground LocalEgress boundary");
  r19_ground_usb_commit_active = true;
  r19_ground_usb_commit_token = 0x10203040U;
  r19_ground_usb_commit_loss_epoch = Serial.txLossEpoch();
  r19_ground_usb_commit_goal = admitted_frame.size;
  r19_ground_usb_commit_deadline_ms = monotonic_now_ms() + 200U;

  const std::size_t rf_before = e220_serial.normal_tx_bytes().size();
  latch_runtime_fail_closed_at(0x1111U);
  latch_runtime_fail_closed_at(0x2222U);
  report.check(r19_runtime_fail_latch.evidence().source_line == 0x1111U,
               "later Ground failure replaced first evidence");
  const std::uint32_t boundary_epoch = Serial.txLossEpoch();
  Serial.set_flush_failures(1U);
  Serial.set_flush_consumes_timeout(true);
  loop_bridge();
  const std::uint64_t boundary_deadline =
      r19_runtime_fail_ground_boundary_deadline_ms;
  report.check(r19_runtime_fail_ground_boundary_status ==
                       R19RuntimeFailGroundBoundaryStatus::DrainingAdmitted &&
                   !r19_runtime_fail_diagnostic_transport_failed &&
                   Serial.txLossEpoch() == boundary_epoch &&
                   boundary_deadline > monotonic_now_ms() &&
                   Serial.tx_write_sizes().size() == 1U &&
                   Serial.tx_write_sizes()[0U] == admitted_frame.size &&
                   Serial.flush_count() == 1U,
               "Ground converted one admitted-boundary flush miss into a "
               "permanent stop or duplicated the admitted frame");
  Serial.set_flush_consumes_timeout(false);
  loop_bridge();
  loop_bridge();

  report.check(runtime_fail_closed && !bridge_ready,
               "Ground diagnostic changed fail-close state");
  report.check(r19_runtime_fail_diagnostic_published,
               "Ground diagnostic did not complete after early-return loops");
  report.check(radio_application_endpoint.egress().empty() &&
                   !radio_application_endpoint.egress().write_pending() &&
                   !r19_ground_usb_commit_active,
               "Ground fail-close did not converge admitted/active USB state");
  report.check(Serial.tx_write_sizes().size() == 3U &&
                   Serial.tx_write_sizes()[0U] == admitted_frame.size &&
                   Serial.tx_write_sizes()[1U] == 32U &&
                   Serial.tx_write_sizes()[2U] == 31U,
               "Ground did not retain the exact 32+31 byte suffix sequence");
  report.check(Serial.flush_count() == 3U,
               "Ground admitted retry and diagnostic were not exactly fenced");
  report.check(e220_serial.normal_tx_bytes().size() == rf_before,
               "Ground diagnostic leaked into the E220 UART");

  vc_lora::MavlinkFrame frame{};
  const auto& bytes = Serial.tx_bytes();
  report.check(bytes.size() == admitted_frame.size + 63U &&
                   std::equal(admitted_frame.bytes.begin(),
                              admitted_frame.bytes.begin() +
                                  admitted_frame.size,
                              bytes.begin()) &&
                   vc_lora::validate_mavlink_frame(
                       bytes.data() + admitted_frame.size, 63U, frame) ==
                       vc_lora::MavlinkParseStatus::FrameReady,
               "Ground diagnostic did not follow a complete admitted frame");
  report.check(frame.message_id == 253U && frame.system_id == 254U &&
                   frame.component_id == 190U && frame.payload_length == 51U,
               "Ground diagnostic MAVLink identity changed");
  const std::string text(
      reinterpret_cast<const char*>(frame.payload() + 1U), 50U);
  report.check(text.rfind("R19F:G:1111:", 0U) == 0U,
               "Ground diagnostic text does not carry role/source evidence");

  fake_arduino::advance_time_ms(
      vc_lora::experimental::R19RuntimeDiagnosticCadence::period_ms);
  loop_bridge();
  loop_bridge();
  vc_lora::MavlinkFrame repeated{};
  const auto& repeated_bytes = Serial.tx_bytes();
  const std::size_t repeated_offset = admitted_frame.size + 63U;
  report.check(repeated_bytes.size() == admitted_frame.size + 126U &&
                   vc_lora::validate_mavlink_frame(
                       repeated_bytes.data() + repeated_offset, 63U,
                       repeated) ==
                       vc_lora::MavlinkParseStatus::FrameReady,
               "Ground did not repeat first-failure evidence on cadence");
  const std::string repeated_text(
      reinterpret_cast<const char*>(repeated.payload() + 1U), 50U);
  report.check(repeated_text == text &&
                   r19_runtime_diagnostic_cadence.fail_transmissions() == 2U,
               "Ground repeat replaced first-wins evidence or accounting");
  report.check(e220_serial.normal_tx_bytes().size() == rf_before,
               "Ground repeated failure leaked into the E220 UART");

  std::cout << "IT-R19-GROUND-RUNTIME-FAIL-DIAGNOSTIC-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
