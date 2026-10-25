#include "fake_arduino_test_api.hpp"

// Count physical D8 samples in the actual bridge loop, independently of the
// opt-in diagnostic record. This must remain live with AUX diagnostics off.
namespace {
std::uint64_t aux_gpio_reads{0U};
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

#include <array>
#include <iostream>
#include <string>

namespace {
using namespace vc_lora_phase6_firmware;
struct Report {
  unsigned checks{0U}, failures{0U};
  void check(bool value, const char* message) {
    ++checks;
    if (!value) { ++failures; std::cerr << "FAIL " << message << '\n'; }
  }
};

vc_lora::MavlinkFrame product_frame() {
  std::array<std::uint8_t, 31U> payload{};
  vc_lora::MavlinkFrame frame{};
  (void)vc_lora::encode_mavlink_v2(42U, 1U, 1U, 1U,
      payload.data(), payload.size(), frame);
  return frame;
}

void initial_armed(Report& report) {
  loop_bridge();
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 63U &&
      !r19_runtime_fail_diagnostic_staged &&
      r19_runtime_diagnostic_cadence.diagnostic_sequence() == 1U,
      "initial complete ARMED diagnostic is committed");
}

void retain_radio_tail(Report& report) {
  e220_write_contract = {};
  (void)e220_write_contract.observe_aux(true, monotonic_now_ms());
  fake_arduino::advance_time_ms(15U);
  (void)e220_write_contract.observe_aux(true, monotonic_now_ms());
  report.check(e220_write_contract.begin_write(32U) &&
      e220_write_contract.report_write_result(32U, monotonic_now_ms(), false) ==
          vc_lora::E220WriteDisposition::AcceptedAll,
      "retained radio transaction accepted");
  e220_writer_arbiter = {};
  clear_standard_radio_writer_lease();
  vc_lora::LinkAction action{};
  action.type = vc_lora::LinkActionType::SendRadioData;
  action.token = 0x7219U;
  report.check(acquire_standard_radio_writer_lease(action) &&
      retain_accepted_standard_radio_writer_lease(monotonic_now_ms()),
      "retained radio writer lease accepted");
  radio_busy = true;
  pending_radio_action = {};
  pending_radio_action.token = action.token;
  fake_arduino::set_pin_input_level(D8, LOW);
}
}

int main(int argc, char** argv) {
  using namespace vc_lora_phase6_firmware;
  Report report{};
  const std::string scenario = argc == 2 ? argv[1] : "hold";
  report.check(scenario == "hold" || scenario == "expiry" ||
      scenario == "alive" || scenario == "runtime" || scenario == "notready",
      "valid scenario selected");
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  setup_bridge();
  report.check(bridge_ready && !runtime_fail_closed, "setup ready");
  initial_armed(report);
  report.check(kGroundUsbHeartbeatCommitDeadlineMs == 106U &&
      kR19RuntimeDiagnosticRecoveryBudgetMs == 120000U,
      "product and diagnostic recovery budgets unchanged");

  if (scenario == "hold" || scenario == "expiry") {
    const auto due = r19_runtime_diagnostic_cadence.next_due_ms();
    fake_arduino::advance_time_ms(due - monotonic_now_ms());
    const auto usb_begin = Serial.tx_bytes().size();
    const auto writes_begin = Serial.tx_write_sizes().size();
    const auto rf_begin = e220_serial.normal_tx_bytes().size();
    const auto epoch = Serial.txLossEpoch();
    const auto tdd_begin = tdd_controller.state();
    Serial.set_flush_failures(10000U);
    Serial.set_flush_consumes_timeout(true);
    for (unsigned stage = 0U;
         stage < 10U && !r19_runtime_fail_diagnostic_transport_failed; ++stage) {
      loop_bridge();
    }
    report.check(r19_runtime_fail_diagnostic_flush_pending &&
        r19_runtime_diagnostic_transport_recovery ==
            R19RuntimeDiagnosticTransportRecovery::FrameFlush,
        "complete diagnostic owns USB before unrelated radio tail is retained");
    retain_radio_tail(report);
    const auto lease = standard_radio_writer_lease;
    report.check(radio_application_endpoint.admit_validated_frame(product_frame()) ==
        vc_lora::ValidatedLocalIngressStatus::QueuedFrame,
        "complete product egress remains queued behind held diagnostic");
    const auto start = monotonic_now_ms();
    const auto reads_begin = aux_gpio_reads;
    unsigned loops = 0U;
    while (monotonic_now_ms() - start < 10800U && loops < 500U) {
      loop_bridge();
      ++loops;
      if (loops == 1U) {
        fake_arduino::set_pin_input_level(D8, HIGH);
      }
    }
    std::cout << "hold elapsed_ms=" << monotonic_now_ms() - start
        << " loops=" << loops << " aux_reads=" << aux_gpio_reads - reads_begin
        << " staged=" << r19_runtime_fail_diagnostic_staged
        << " flush=" << r19_runtime_fail_diagnostic_flush_pending
        << " failed=" << r19_runtime_fail_diagnostic_transport_failed
        << " recovery=" << static_cast<unsigned>(r19_runtime_diagnostic_transport_recovery)
        << " reason=" << static_cast<unsigned>(r19_runtime_diagnostic_transport_trace.first_failure_reason)
        << '\n';
    report.check(loops < 500U && monotonic_now_ms() - start == 10800U,
        "bounded no-pickup model reproduces exact 10.8-second interval");
    report.check(aux_gpio_reads - reads_begin == loops,
        "every held diagnostic loop observes AUX once during 10.8 seconds");
    report.check(e220_write_contract.ready_for_write() &&
        e220_write_contract.take_write_completion(),
        "fresh AUX samples reach ready while completion remains unconsumed");
    report.check(r19_runtime_fail_diagnostic_staged &&
        r19_runtime_fail_diagnostic_flush_pending &&
        r19_runtime_fail_diagnostic_transport_failed &&
        r19_runtime_diagnostic_transport_recovery ==
            R19RuntimeDiagnosticTransportRecovery::FrameFlush,
        "held complete diagnostic retains FrameFlush ownership");
    report.check(Serial.txLossEpoch() == epoch &&
        Serial.tx_bytes().size() - usb_begin == 63U &&
        Serial.tx_write_sizes().size() - writes_begin == 2U &&
        Serial.tx_write_sizes()[writes_begin] == 32U &&
        Serial.tx_write_sizes()[writes_begin + 1U] == 31U,
        "only one exact 32+31-byte diagnostic is written without replay");
    report.check(e220_serial.normal_tx_bytes().size() == rf_begin &&
        tdd_controller.state() == tdd_begin && radio_busy &&
        pending_radio_action.token == 0x7219U &&
        !radio_application_endpoint.egress().empty() &&
        radio_application_endpoint.egress().stats().bytes_physically_accepted == 0U,
        "AUX observation cannot progress normal RF, TDD, action, or USB egress");
    report.check(standard_radio_writer_lease.owner == lease.owner &&
        standard_radio_writer_lease.action_token == lease.action_token &&
        standard_radio_writer_lease.writer_generation == lease.writer_generation &&
        standard_radio_writer_tail_pending && e220_writer_arbiter.write_active() &&
        e220_writer_arbiter.last_status() == Phase6RadioWriterStatus::AcceptedAwaitingTail,
        "AUX observation cannot release the retained physical tail lease");
    const auto held_bytes = Serial.tx_bytes().size();
    const auto held_writes = Serial.tx_write_sizes().size();
    if (scenario == "expiry") {
      fake_arduino::advance_time_ms(kR19RuntimeDiagnosticRecoveryBudgetMs);
      const auto before = aux_gpio_reads;
      loop_bridge();
      report.check(r19_runtime_fail_diagnostic_transport_failed &&
          r19_runtime_diagnostic_transport_recovery ==
              R19RuntimeDiagnosticTransportRecovery::None,
          "expired 120-second recovery remains permanently failed");
      report.check(aux_gpio_reads == before + 1U,
          "expired recovery still samples AUX");
      const auto first_failed = aux_gpio_reads;
      fake_arduino::advance_time_ms(100U);
      loop_bridge();
      report.check(aux_gpio_reads == first_failed + 1U &&
          r19_runtime_fail_diagnostic_transport_failed,
          "permanent diagnostic failure cannot permanently stop AUX observation");
    } else {
      Serial.set_flush_failures(0U);
      Serial.set_flush_consumes_timeout(false);
      const auto before = aux_gpio_reads;
      loop_bridge();
      report.check(!r19_runtime_fail_diagnostic_staged &&
          !r19_runtime_fail_diagnostic_flush_pending &&
          !r19_runtime_fail_diagnostic_transport_failed &&
          r19_runtime_diagnostic_transport_recovery ==
              R19RuntimeDiagnosticTransportRecovery::None,
          "same-epoch successful flush releases diagnostic ownership normally");
      report.check(aux_gpio_reads == before + 1U,
          "committed-this-service exit also observes AUX");
    }
    report.check(Serial.tx_bytes().size() == held_bytes &&
        Serial.tx_write_sizes().size() == held_writes && radio_busy &&
        standard_radio_writer_tail_pending,
        "recovery or expiry never replays bytes or releases radio ownership");
  } else if (scenario == "alive") {
    report.check(radio_application_endpoint.admit_validated_frame(product_frame()) ==
        vc_lora::ValidatedLocalIngressStatus::QueuedFrame,
        "ALIVE boundary fixture queues complete product");
    fake_arduino::advance_time_ms(
        vc_lora::experimental::R19RuntimeDiagnosticCadence::period_ms);
    Serial.set_available_for_write(0);
    const auto first_reads = aux_gpio_reads;
    const auto rf_bytes = e220_serial.normal_tx_bytes().size();
    const auto tdd = tdd_controller.state();
    loop_bridge();
    report.check(r19_ground_runtime_alive_reservation_pending() &&
        r19_runtime_alive_ground_reservation_active &&
        !r19_runtime_fail_diagnostic_transport_failed,
        "ALIVE drain holds a backpressured clean boundary");
    report.check(aux_gpio_reads == first_reads + 1U,
        "blocked ALIVE drain does not starve AUX");
    fake_arduino::advance_time_ms(500U);
    const auto before_timeout = aux_gpio_reads;
    loop_bridge();
    report.check(aux_gpio_reads == before_timeout + 1U &&
        r19_runtime_fail_diagnostic_transport_failed &&
        r19_runtime_diagnostic_transport_trace.first_failure_reason ==
            R19RuntimeDiagnosticTransportFailureReason::GroundReservationDeadlineExpired,
        "ALIVE deadline stays hard and its failed gate still observes AUX");
    report.check(Serial.tx_bytes().size() == 63U &&
        !radio_application_endpoint.egress().empty() &&
        radio_application_endpoint.egress().stats().bytes_physically_accepted == 0U &&
        e220_serial.normal_tx_bytes().size() == rf_bytes &&
        tdd_controller.state() == tdd,
        "ALIVE observation cannot bypass blocked product or RF boundaries");
  } else {
    retain_radio_tail(report);
    // Keep the independent USB diagnostic publisher backpressured when its
    // cadence becomes due during the 2-second LOW. The invariant below is
    // specifically about observe-only code, not permission to emit ALIVE.
    Serial.set_available_for_write(0);
    const auto lease = standard_radio_writer_lease;
    const auto usb_bytes = Serial.tx_bytes().size();
    const auto rf_bytes = e220_serial.normal_tx_bytes().size();
    const auto tdd = tdd_controller.state();
    runtime_fail_closed = scenario == "runtime";
    bridge_ready = scenario != "notready";
    const auto before = aux_gpio_reads;
    loop_bridge();
    report.check(aux_gpio_reads == before + 1U,
        "pre-normal runtime-failed or not-ready guard still observes AUX");
    fake_arduino::advance_time_ms(2000U);
    const auto before_low_timeout = aux_gpio_reads;
    loop_bridge();
    report.check(aux_gpio_reads == before_low_timeout + 1U &&
        e220_write_contract.fail_closed() && runtime_fail_closed && !bridge_ready &&
        e220_write_contract.fault() == vc_lora::E220WriteFault::AuxDidNotReturnHigh,
        "observe-only guard preserves the 2-second LOW permanent safety stop");
    fake_arduino::set_pin_input_level(D8, HIGH);
    fake_arduino::advance_time_ms(15U);
    const auto before_high = aux_gpio_reads;
    // A diagnostic failure owns USB independently from the underlying AUX
    // stop and cannot suppress continued physical observation of a later HIGH.
    r19_runtime_fail_diagnostic_transport_failed = true;
    r19_runtime_diagnostic_transport_recovery =
        R19RuntimeDiagnosticTransportRecovery::None;
    loop_bridge();
    report.check(aux_gpio_reads == before_high + 1U &&
        e220_write_contract.fail_closed() && runtime_fail_closed && !bridge_ready,
        "later HIGH is observed but cannot clear a permanent AUX/runtime fault");
    report.check(Serial.tx_bytes().size() == usb_bytes &&
        e220_serial.normal_tx_bytes().size() == rf_bytes &&
        tdd_controller.state() == tdd && radio_busy &&
        standard_radio_writer_tail_pending && e220_writer_arbiter.write_active() &&
        standard_radio_writer_lease.owner == lease.owner &&
        standard_radio_writer_lease.action_token == lease.action_token &&
        standard_radio_writer_lease.writer_generation == lease.writer_generation,
        "failed observer never clears a fault or releases USB/RF/TDD work");
  }
  std::cout << "IT-R19-GROUND-AUX-INDEPENDENCE-001 scenario=" << scenario
      << " checks=" << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
