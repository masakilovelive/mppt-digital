#include "fake_arduino_test_api.hpp"

// Isolated diagnostic harness: production logic, shared fakes, and registered
// tests are not edited. The GPIO wrapper observes actual loop_bridge() reads.
namespace {
std::uint64_t aux_gpio_reads = 0U;
int counted_digital_read(int pin) noexcept {
  if (pin == D8) ++aux_gpio_reads;
  return digitalRead(pin);
}
}
#define digitalRead counted_digital_read
#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#define VC_LORA_R19_USB_READINESS_MODE 2
#define VC_LORA_R19_AUX_READINESS_DIAGNOSTICS 0
#include "phase6/vc_lora_phase6_bridge.hpp"
#undef digitalRead
#include <iostream>

int main() {
  using namespace vc_lora_phase6_firmware;
  unsigned checks = 0U, failures = 0U;
  const auto check = [&](bool condition, const char* description) {
    ++checks;
    if (!condition) { ++failures; std::cerr << "FAIL " << description << '\n'; }
  };
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  setup_bridge();
  check(bridge_ready && !runtime_fail_closed, "setup ready");
  loop_bridge();
  loop_bridge();
  check(Serial.tx_bytes().size() == 63U &&
        !r19_runtime_fail_diagnostic_staged &&
        r19_runtime_diagnostic_cadence.diagnostic_sequence() == 1U,
        "first ARMED diagnostic committed without HostArm product gate");
  const auto after_armed_reads = aux_gpio_reads;
  for (unsigned index = 0U; index < 10U; ++index) {
    fake_arduino::advance_time_ms(10U);
    loop_bridge();
  }
  const auto baseline_reads = aux_gpio_reads;
  check(baseline_reads > after_armed_reads, "normal loop actually samples AUX");
  const auto pre_block_bytes = Serial.tx_bytes().size();
  const auto pre_block_writes = Serial.tx_write_sizes().size();
  const auto pre_block_rf = e220_serial.normal_tx_bytes().size();
  const auto stable_epoch = Serial.txLossEpoch();
  const auto next_due = r19_runtime_diagnostic_cadence.next_due_ms();
  fake_arduino::advance_time_ms(next_due - monotonic_now_ms());

  // Counterfactual USB-host-no-pickup model: cached endpoint readiness and
  // loss epoch stay valid, but all flush completions fail and consume their
  // original time budget. This does NOT assert why the real host stopped INs.
  Serial.set_flush_failures(10000U);
  Serial.set_flush_consumes_timeout(true);
  const auto block_start_ms = monotonic_now_ms();
  const auto block_start_reads = aux_gpio_reads;
  unsigned blocked_loop_calls = 0U;
  while (monotonic_now_ms() - block_start_ms < 10800U &&
         blocked_loop_calls < 500U) {
    loop_bridge();
    ++blocked_loop_calls;
  }
  const auto block_end_ms = monotonic_now_ms();
  const auto block_end_reads = aux_gpio_reads;
  const auto blocked_bytes = Serial.tx_bytes().size();
  const auto blocked_writes = Serial.tx_write_sizes().size();
  const auto blocked_flushes = Serial.flush_count();
  const auto held_staged = r19_runtime_fail_diagnostic_staged;
  const auto held_flush = r19_runtime_fail_diagnostic_flush_pending;
  const auto held_failed = r19_runtime_fail_diagnostic_transport_failed;
  const auto held_recovery = r19_runtime_diagnostic_transport_recovery;
  const auto held_failure_reason =
      r19_runtime_diagnostic_transport_trace.first_failure_reason;
  const auto held_recovery_until = r19_runtime_diagnostic_recovery_until_ms;
  const auto held_runtime_fail = runtime_fail_closed;
  check(blocked_loop_calls < 500U, "bounded flush calls advanced 10800 ms");
  check(block_end_ms - block_start_ms == 10800U, "exact 10800-ms reproduction");
  check(block_end_reads == block_start_reads, "AUX starved during all held loops");
  check(held_staged && held_flush && held_failed &&
        held_recovery == R19RuntimeDiagnosticTransportRecovery::FrameFlush,
        "complete diagnostic owns boundary in FrameFlush recovery");
  check(Serial.txLossEpoch() == stable_epoch && static_cast<bool>(Serial),
        "stable epoch and cached endpoint readiness retained");
  check(blocked_bytes - pre_block_bytes == 63U &&
        blocked_writes - pre_block_writes == 2U &&
        Serial.tx_write_sizes()[pre_block_writes] == 32U &&
        Serial.tx_write_sizes()[pre_block_writes + 1U] == 31U,
        "only one exact 32+31-byte ALIVE admitted; no replay");
  check(e220_serial.normal_tx_bytes().size() == pre_block_rf,
        "held loop emitted no E220 UART bytes");
  check(!held_runtime_fail, "diagnostic stop independent of runtime fail-close");
  check(kR19RuntimeDiagnosticRecoveryBudgetMs == 120000U,
        "original recovery budget unchanged");

  // Only the fake completion result changes. No real COM or PC action occurs.
  Serial.set_flush_failures(0U);
  Serial.set_flush_consumes_timeout(false);
  loop_bridge();
  const auto first_recovery_reads = aux_gpio_reads;
  const auto recovery_released = !r19_runtime_fail_diagnostic_staged &&
      !r19_runtime_fail_diagnostic_flush_pending &&
      !r19_runtime_fail_diagnostic_transport_failed &&
      r19_runtime_diagnostic_transport_recovery ==
          R19RuntimeDiagnosticTransportRecovery::None;
  check(recovery_released, "same-epoch successful flush released ownership");
  check(first_recovery_reads == block_end_reads,
        "committed-this-service still returns without AUX");
  loop_bridge();
  const auto after_recovery_reads = aux_gpio_reads;
  check(after_recovery_reads > first_recovery_reads,
        "next normal loop resumes AUX after flush-only recovery");
  check(Serial.tx_bytes().size() == blocked_bytes &&
        Serial.tx_write_sizes().size() == blocked_writes,
        "recovery does not replay any byte");

  std::cout << "{\n"
      << "  \"fixture\": \"unchanged real loop_bridge, fake USB no-pickup\",\n"
      << "  \"readiness_mode\": 2,\n"
      << "  \"aux_diagnostics_enabled\": false,\n"
      << "  \"armed_initial_bytes\": " << pre_block_bytes << ",\n"
      << "  \"aux_reads_after_armed\": " << after_armed_reads << ",\n"
      << "  \"aux_reads_after_ten_normal_loops\": " << baseline_reads << ",\n"
      << "  \"block_start_ms\": " << block_start_ms << ",\n"
      << "  \"block_end_ms\": " << block_end_ms << ",\n"
      << "  \"unobserved_duration_ms\": " << block_end_ms-block_start_ms << ",\n"
      << "  \"blocked_loop_calls\": " << blocked_loop_calls << ",\n"
      << "  \"aux_reads_before_block\": " << block_start_reads << ",\n"
      << "  \"aux_reads_after_block\": " << block_end_reads << ",\n"
      << "  \"pending_alive_bytes\": " << blocked_bytes-pre_block_bytes << ",\n"
      << "  \"pending_alive_write_calls\": " << blocked_writes-pre_block_writes << ",\n"
      << "  \"total_flush_calls_at_block_end\": " << blocked_flushes << ",\n"
      << "  \"held_staged\": " << (held_staged ? "true" : "false") << ",\n"
      << "  \"held_flush_pending\": " << (held_flush ? "true" : "false") << ",\n"
      << "  \"held_transport_failed\": " << (held_failed ? "true" : "false") << ",\n"
      << "  \"held_recovery_enum\": " << static_cast<unsigned>(held_recovery) << ",\n"
      << "  \"held_first_failure_reason_enum\": " << static_cast<unsigned>(held_failure_reason) << ",\n"
      << "  \"held_recovery_until_ms\": " << held_recovery_until << ",\n"
      << "  \"held_runtime_fail_closed\": " << (held_runtime_fail ? "true" : "false") << ",\n"
      << "  \"epoch\": " << stable_epoch << ",\n"
      << "  \"recovery_released\": " << (recovery_released ? "true" : "false") << ",\n"
      << "  \"aux_reads_after_first_recovery_loop\": " << first_recovery_reads << ",\n"
      << "  \"aux_reads_after_next_normal_loop\": " << after_recovery_reads << ",\n"
      << "  \"checks\": " << checks << ",\n"
      << "  \"failures\": " << failures << ",\n"
      << "  \"limitation\": \"Mechanism reproduction only, not physical AUX/USB waveform or proof of real PC-close cause. Explicit HostArm product negotiation is not exercised; diagnostic liveness is independent.\"\n"
      << "}\n";
  return failures == 0U ? 0 : 1;
}
