#include "fake_arduino_test_api.hpp"

#define VC_LORA_PHASE6_VEHICLE 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"

#include <algorithm>
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

bool parse_diagnostic_at(const std::size_t offset,
                         vc_lora::MavlinkFrame& frame) {
  const auto& bytes = Serial.tx_bytes();
  return offset <= bytes.size() && bytes.size() - offset >= 63U &&
         vc_lora::validate_mavlink_frame(bytes.data() + offset, 63U,
                                         frame) ==
             vc_lora::MavlinkParseStatus::FrameReady;
}

template <typename ByteRange>
bool contains_wire_frame(const ByteRange& bytes,
                         const vc_lora::MavlinkFrame& frame) {
  return frame.size != 0U &&
         std::search(bytes.begin(), bytes.end(), frame.bytes.begin(),
                     frame.bytes.begin() + frame.size) != bytes.end();
}

}  // namespace

int main() {
  Report report{};
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  Serial.set_available_for_write(0);
  setup_bridge();
  report.check(bridge_ready && !runtime_fail_closed,
               "Vehicle setup did not reach Ready");

  // A newly opened CDC endpoint may report host-present/connected before it
  // has any TX capacity.  Do not stage the diagnostic or start its 500 ms
  // frame deadline until the first bounded write can actually be attempted.
  loop_bridge();
  fake_arduino::advance_time_ms(kR19RuntimeDiagnosticFrameBudgetMs + 1U);
  loop_bridge();
  report.check(!r19_runtime_fail_diagnostic_transport_failed &&
                   !r19_runtime_fail_diagnostic_staged &&
                   r19_runtime_diagnostic_frame_deadline_ms == 0U &&
                   r19_runtime_diagnostic_cadence.pending_action() ==
                       R19RuntimeDiagnosticAction::Armed,
               "Vehicle started the frame deadline before USB TX capacity");
  report.check(r19_runtime_diagnostic_transport_trace.host_sample_seen &&
                   r19_runtime_diagnostic_transport_trace.
                           first_host_gate_mask == 0x03U &&
                   r19_runtime_diagnostic_transport_trace.
                           last_host_gate_mask == 0x03U &&
                   !r19_runtime_diagnostic_transport_trace.full_gate_seen &&
                   !r19_runtime_diagnostic_transport_trace.
                       first_write_attempt_seen,
               "Vehicle did not preserve the pre-writable host-gate state");

  // Capacity may disappear between two back-to-back observations even though
  // the epoch and endpoint remain stable.  A positive acquisition must lead
  // directly to the bounded checked write instead of a second racy probe.
  Serial.set_available_for_write_sequence(256, 0);
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 32U &&
                   r19_runtime_fail_diagnostic_staged &&
                   r19_runtime_diagnostic_transport_trace.
                       first_write_attempt_seen &&
                   r19_runtime_diagnostic_transport_trace.
                           first_write_available == 256 &&
                   r19_runtime_diagnostic_transport_trace.
                           first_write_requested == 32U &&
                   r19_runtime_diagnostic_transport_trace.
                           first_write_accepted == 32U,
               "Vehicle re-probed USB capacity after acquiring the write gate");
  Serial.set_available_for_write(256);
  loop_bridge();
  vc_lora::MavlinkFrame armed{};
  report.check(Serial.tx_bytes().size() == 63U &&
                   parse_diagnostic_at(0U, armed),
               "Vehicle did not emit one CRC-valid ARMED frame");
  report.check(armed.payload_byte_or_zero(0U) == 6U,
               "Vehicle ARMED severity is not INFO");
  const std::string armed_text(
      reinterpret_cast<const char*>(armed.payload() + 1U), 47U);
  report.check(armed_text.rfind("R19A:V:A:00000000:", 0U) == 0U,
               "Vehicle ARMED identity/ordinal changed");

  fake_arduino::advance_time_ms(999U);
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 63U,
               "Vehicle ALIVE was emitted before the fixed cadence");
  const std::uint32_t alive_epoch = Serial.txLossEpoch();
  const std::uint32_t committed_sequence =
      r19_runtime_diagnostic_cadence.diagnostic_sequence();
  Serial.set_flush_failures(1U);
  Serial.set_flush_consumes_timeout(true);
  fake_arduino::advance_time_ms(1U);
  loop_bridge();
  const std::uint64_t alive_deadline =
      r19_runtime_diagnostic_frame_deadline_ms;
  loop_bridge();
  report.check(!r19_runtime_fail_diagnostic_transport_failed &&
                   r19_runtime_fail_diagnostic_staged &&
                   r19_runtime_fail_diagnostic_flush_pending &&
                   Serial.txLossEpoch() == alive_epoch &&
                   r19_runtime_diagnostic_frame_deadline_ms ==
                       alive_deadline &&
                   r19_runtime_diagnostic_cadence.diagnostic_sequence() ==
                       committed_sequence &&
                   Serial.tx_write_sizes().size() == 4U &&
                   Serial.flush_count() == 2U,
               "Vehicle converted one stable-epoch flush miss into a "
               "permanent stop or replayed payload bytes");
  Serial.set_flush_consumes_timeout(false);
  loop_bridge();

  vc_lora::MavlinkFrame alive{};
  report.check(Serial.tx_bytes().size() == 126U &&
                   parse_diagnostic_at(63U, alive),
               "Vehicle did not emit one periodic CRC-valid ALIVE frame");
  const std::string alive_text(
      reinterpret_cast<const char*>(alive.payload() + 1U), 47U);
  report.check(alive.payload_byte_or_zero(0U) == 6U &&
                   alive_text.rfind("R19A:V:L:00000001:", 0U) == 0U,
               "Vehicle ALIVE identity/ordinal changed");
  report.check(Serial.tx_write_sizes().size() == 4U &&
                   Serial.tx_write_sizes()[0U] == 32U &&
                   Serial.tx_write_sizes()[1U] == 31U &&
                   Serial.tx_write_sizes()[2U] == 32U &&
                   Serial.tx_write_sizes()[3U] == 31U &&
                   Serial.flush_count() == 3U,
               "Vehicle R19A frames were not exact 32+31 flush transactions");
  report.check(r19_runtime_diagnostic_transport_trace.full_gate_seen &&
                   r19_runtime_diagnostic_transport_trace.
                           first_write_attempt_seen &&
                   r19_runtime_diagnostic_transport_trace.
                           first_write_action ==
                       R19RuntimeDiagnosticAction::Armed &&
                   r19_runtime_diagnostic_transport_trace.
                           first_write_available == 256 &&
                   r19_runtime_diagnostic_transport_trace.
                           first_write_requested == 32U &&
                   r19_runtime_diagnostic_transport_trace.
                           first_write_accepted == 32U &&
                   r19_runtime_diagnostic_transport_trace.
                           first_failure_reason ==
                       R19RuntimeDiagnosticTransportFailureReason::None,
               "Vehicle first-write transport trace is incomplete");
  report.check(!contains_wire_frame(e220_serial.normal_tx_bytes(), armed) &&
                   !contains_wire_frame(e220_serial.normal_tx_bytes(), alive) &&
                   !contains_wire_frame(pixhawk_serial.normal_tx_bytes(),
                                        armed) &&
                   !contains_wire_frame(pixhawk_serial.normal_tx_bytes(),
                                        alive),
               "Vehicle R19A bytes leaked into E220 or Pixhawk UART");

  std::cout << "IT-R19-VEHICLE-RUNTIME-ALIVE-DIAGNOSTIC-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
