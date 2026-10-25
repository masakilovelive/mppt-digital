#include "fake_arduino_test_api.hpp"
namespace {
class CallLocalUsb final {
 public:
  bool abort_epoch_once{false};
  bool omit_sdk_evidence{false};
  void begin(std::uint32_t baud) noexcept { Serial.begin(baud); }
  bool isPlugged() const noexcept { return Serial.isPlugged(); }
  explicit operator bool() const noexcept { return static_cast<bool>(Serial); }
  int available() const noexcept { return Serial.available(); }
  int read() noexcept { return Serial.read(); }
  int availableForWrite() const noexcept { return Serial.availableForWrite(); }
  std::uint32_t txLossEpoch() const noexcept { return Serial.txLossEpoch(); }
  std::size_t writeTxChecked(const std::uint8_t* p,std::size_t n,std::uint32_t epoch) noexcept {
    return Serial.writeTxChecked(p,n,epoch);
  }
  std::size_t writeTxBootstrapFrameChecked(const std::uint8_t* p,std::size_t n,std::uint32_t epoch) noexcept {
    return Serial.writeTxBootstrapFrameChecked(p,n,epoch);
  }
  bool flushTxComplete(std::uint32_t budget,std::uint32_t epoch) noexcept {
    return Serial.flushTxComplete(budget,epoch);
  }
  bool flushTxCompleteDiagnostic(std::uint32_t budget,std::uint32_t epoch,
      vc_lora::experimental::R19HwcdcFlushCallEvidence& evidence) noexcept {
    if(abort_epoch_once){Serial.simulate_tx_loss();abort_epoch_once=false;}
    const bool result=Serial.flushTxCompleteDiagnostic(budget,epoch,evidence);
    evidence.publish_generation=result?42U:41U;
    evidence.pickup_generation=result?42U:40U;
    if(omit_sdk_evidence) evidence={};
    return result;
  }
};
CallLocalUsb call_local_serial{};
}
#define Serial call_local_serial
#if REPRO_GROUND
#define VC_LORA_PHASE6_GROUND 1
#else
#define VC_LORA_PHASE6_VEHICLE 1
#endif
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#define VC_LORA_R19_USB_READINESS_MODE 2
#define VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD 1
#include "phase6/vc_lora_phase6_bridge.hpp"
#undef Serial
#include "high_speed/r19_diagnostic_usb_failure_record.hpp"
#include <iostream>
#include <string>

int main(int argc, char** argv) {
  using namespace vc_lora_phase6_firmware;
  using namespace vc_lora::experimental;
  unsigned checks=0U, failures=0U;
  const auto check=[&](bool value,const char* message) {
    ++checks;
    if(!value){++failures;std::cerr << "FAIL " << message << '\n';}
  };
  const std::string scenario=argc==2?argv[1]:"deadline";
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8,HIGH);
  Serial.set_plugged(true);Serial.set_endpoint_ready(true);
  setup_bridge();
  check(bridge_ready && !runtime_fail_closed,"setup ready");
  R19DiagnosticUsbFailureSnapshot initial{};
  check(vc_lora_r19_diagnostic_usb_failure_record.try_snapshot(initial) &&
      initial.valid_header() && !initial.failure_latched(),"boot-bound independent record initialized");
  loop_bridge();loop_bridge();
  check(Serial.tx_bytes().size()==63U &&
      r19_runtime_diagnostic_cadence.diagnostic_sequence()==1U,
      "initial diagnostic completed before injected later failure");
  if(scenario=="no_api") {
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::EpochChangedBeforeWrite,
        monotonic_now_ms(),__LINE__);
  } else {
    const auto due=r19_runtime_diagnostic_cadence.next_due_ms();
    fake_arduino::advance_time_ms(due-monotonic_now_ms());
    Serial.set_flush_failures(10000U);Serial.set_flush_consumes_timeout(true);
    if(scenario=="epoch") call_local_serial.abort_epoch_once=true;
    if(scenario=="bootstrap_epoch") {
      Serial.set_endpoint_ready(false);
      // Hold one complete bootstrap before host-IN, then model BUS_RESET
      // discarding that stream. Reaccept the image into the fresh epoch and
      // only then open host-IN and inject a terminal stable-epoch timeout.
      r19_service_runtime_fail_diagnostic();
      Serial.simulate_tx_loss();
      r19_service_runtime_fail_diagnostic();
      r19_service_runtime_fail_diagnostic();
      Serial.set_endpoint_ready(true);
    }
    if(scenario=="unknown_sdk") call_local_serial.omit_sdk_evidence=true;
    for(unsigned n=0U;n<15U && !r19_runtime_fail_diagnostic_transport_failed;++n)
      loop_bridge();
  }
  R19DiagnosticUsbFailureSnapshot first{};
  std::cout << "scenario=" << scenario << " now_ms=" << monotonic_now_ms()
      << " failed=" << r19_runtime_fail_diagnostic_transport_failed
      << " staged=" << r19_runtime_fail_diagnostic_staged
      << " flush_pending=" << r19_runtime_fail_diagnostic_flush_pending
      << " accepted=" << r19_diagnostic_usb_accepted_frame_bytes
      << " epoch=" << Serial.txLossEpoch() << '\n';
  check(vc_lora_r19_diagnostic_usb_failure_record.try_snapshot(first) &&
      first.failure_latched(),"first diagnostic USB failure latched");
  check(first.role==kR19RuntimeStageRole && first.boot_instance==initial.boot_instance &&
      first.build_fingerprint==initial.build_fingerprint,"role/build/boot identity retained");
  check(first.source_line!=0U,"actual source location preserved");
  if(scenario=="no_api") {
    check(!first.api_called() && !first.sdk_context_matches() &&
        first.sdk.validity_flags==0U && first.budget_ms==0U,
        "pre-API failure cannot inherit prior successful diagnostic SDK evidence");
  } else if(scenario=="unknown_sdk") {
    check(first.api_called() && !first.sdk_context_matches() &&
        first.sdk.validity_flags==0U && (first.wrapper_flags&2U)==0U,
        "missing SDK terminal evidence remains unknown, never fabricated healthy FIFO");
  } else {
    check(first.reason==static_cast<std::uint32_t>(R19RuntimeDiagnosticTransportFailureReason::FlushFailed),
        "same-epoch absolute-deadline flush failure distinguished");
    check(first.api_called() && first.sdk_context_matches() &&
        (first.wrapper_flags&2U)==0U,"false API result tied to exact wire sequence and attempt");
    check(first.sdk.terminal_reason==(scenario=="epoch"?6U:5U) && first.sdk.flush_blocker_mask==0x18U &&
        first.sdk.publish_generation==first.sdk.pickup_generation+1U,
        "terminal FIFO/pickup state frozen at first failing decision");
    check((scenario=="epoch"?first.expected_epoch!=first.observed_epoch:
        first.expected_epoch==first.observed_epoch) && first.budget_ms==100U &&
        first.sdk.transaction_token==first.diagnostic_sequence+1U &&
        first.sdk.attempt_id==first.attempt_id,"epoch, budget and generations are call-local");
    check(first.expected_frame_bytes==63U && first.accepted_frame_bytes==63U &&
        first.failure_observed_us>=first.finished_us &&
        (scenario=="epoch"?first.finished_us<first.deadline_us:
        first.finished_us>=first.deadline_us) &&
        first.finished_us-first.started_us==100000U,
        "full accepted frame and immutable 500ms deadline quantified");
    check(r19_runtime_diagnostic_transport_recovery==(scenario=="epoch"?
        R19RuntimeDiagnosticTransportRecovery::None:R19RuntimeDiagnosticTransportRecovery::FrameFlush),
        "recording does not change existing bounded recovery");
  }
  R19FirstUsbFailureSnapshot product{};
  check(vc_lora_r19_first_usb_failure_record.try_snapshot(product) && !product.failure_latched(),
      "diagnostic failure does not contaminate product Heartbeat first-failure record");
  Serial.set_flush_failures(0U);Serial.set_flush_consumes_timeout(false);
  Serial.set_endpoint_ready(true);
  const auto wire_bytes=Serial.tx_bytes().size();
  const auto write_calls=Serial.tx_write_sizes().size();
  loop_bridge();
  r19_fail_diagnostic_transport(
      R19RuntimeDiagnosticTransportFailureReason::EpochChangedBeforeWrite,
      monotonic_now_ms(),__LINE__);
  R19DiagnosticUsbFailureSnapshot later{};
  check(vc_lora_r19_diagnostic_usb_failure_record.try_snapshot(later) &&
      later.sequence==first.sequence && later.reason==first.reason &&
      later.failure_observed_us==first.failure_observed_us &&
      later.attempt_id==first.attempt_id &&
      later.sdk.publish_generation==first.sdk.publish_generation,
      "recovery and subsequent failure cannot overwrite immutable first failure");
  check(Serial.tx_write_sizes().size()==write_calls &&
      (scenario=="bootstrap_epoch" || Serial.tx_bytes().size()==wire_bytes),
      "flush-only recovery cannot replay payload");
  check(kR19RuntimeDiagnosticFrameBudgetMs==500U &&
      kR19RuntimeFailDiagnosticFlushBudgetMs==100U,"existing diagnostic budgets unchanged");
  std::cout << "checks=" << checks << " failures=" << failures << '\n';
  return failures==0U?0:1;
}
