#include "fake_arduino_test_api.hpp"

namespace {
std::uint64_t aux_reads{0U};
int clock_test_digital_read(int pin) noexcept {
  if (pin == D8) ++aux_reads;
  return digitalRead(pin);
}
}
#define digitalRead clock_test_digital_read
#define VC_LORA_PHASE6_VEHICLE 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#define VC_LORA_R19_TIMED_PATH_DIAGNOSTICS 1
#define VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD 1
#ifndef VC_LORA_R19_USB_READINESS_MODE
#define VC_LORA_R19_USB_READINESS_MODE 2
#endif
#include "phase6/vc_lora_phase6_bridge.hpp"
#undef digitalRead

#include <algorithm>
#include <array>
#include <iostream>
#include <string>

namespace {
using namespace vc_lora;
using namespace vc_lora::experimental;
using namespace vc_lora_phase6_firmware;
struct Report {
  unsigned checks{0U}, failures{0U};
  void check(bool value, const char* name) {
    ++checks;
    if (!value) { ++failures; std::cerr << "FAIL " << name << '\n'; }
  }
};
constexpr std::uint64_t nonce = 5915821819564634567ULL;
MavlinkFrame request(std::uint64_t value = nonce) {
  std::array<std::uint8_t,16U> payload{};
  for (unsigned n=0U;n<8U;++n) payload[8U+n]=static_cast<std::uint8_t>(value>>(8U*n));
  MavlinkFrame out{};
  (void)encode_mavlink_v2(0U,249U,193U,111U,payload.data(),payload.size(),out);
  return out;
}
void inject(const MavlinkFrame& frame) {
  Serial.inject_rx(frame.bytes.data(),frame.size);
}
struct Parsed {
  unsigned clocks{0U}, readies{0U}, diagnostics{0U}, bad_crc{0U};
  std::uint64_t reply_nonce{0U};
};
Parsed parsed_output() {
  Parsed out{};
  MavlinkStreamParser parser{};
  for (const auto byte:Serial.tx_bytes()) {
    MavlinkFrame frame{};
    const auto status=parser.push(byte,frame);
    if (status==MavlinkParseStatus::BadCrc) ++out.bad_crc;
    if (status!=MavlinkParseStatus::FrameReady) continue;
    if(frame.system_id==249U&&frame.component_id==194U&&frame.message_id==111U) {
      ++out.clocks;
      for(unsigned n=0;n<8U;++n) out.reply_nonce|=static_cast<std::uint64_t>(frame.payload()[8U+n])<<(8U*n);
    }
    if(frame.system_id==249U&&(frame.component_id==195U||frame.component_id==196U)) ++out.readies;
    if(frame.message_id==253U&&frame.size==63U) ++out.diagnostics;
  }
  return out;
}
void loops(unsigned count,unsigned step_ms=1U) {
  for(unsigned n=0;n<count;++n) {fake_arduino::advance_time_ms(step_ms);loop_bridge();}
}
bool contains(const std::vector<std::uint8_t>& bytes,const MavlinkFrame& frame) {
  return std::search(bytes.begin(),bytes.end(),frame.bytes.begin(),frame.bytes.begin()+frame.size)!=bytes.end();
}
}

int main(int argc,char** argv) {
  using namespace vc_lora_phase6_firmware;
  Report report{};
  const std::string scenario=argc>1?argv[1]:"basic";
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8,HIGH);
  Serial.set_plugged(true);Serial.set_endpoint_ready(scenario!="cold_bootstrap");
  if(scenario=="cold") Serial.set_available_for_write(0);
  setup_bridge();
  report.check(bridge_ready&&!runtime_fail_closed,"Vehicle setup succeeds");
  if(scenario!="cold") loops(2U);
  const auto req=request();
  MavlinkFrame validated{};
  report.check(validate_mavlink_frame(req.bytes.data(),req.size,validated)==MavlinkParseStatus::FrameReady,
      "live request image remains a canonical 28-byte frame");
  R19TimedPathSnapshot timed{};
  report.check(vc_lora_r19_timed_path_record.try_snapshot(timed)&&timed.mode==1U,
      "Vehicle effective timed-path mode is SyncOnly even with global mode 2");
  const auto usb_before=Serial.tx_bytes().size();
  const auto aux_before=aux_reads;
  if(scenario=="partial"||scenario=="epoch") Serial.set_tx_checked_accept_limit(7U);
  if(scenario=="zero"||scenario=="deadline") Serial.set_tx_checked_accept_limit(0U);
  if(scenario=="pending_diag") {
    fake_arduino::advance_time_ms(R19RuntimeDiagnosticCadence::period_ms);
    Serial.set_flush_failures(10000U);Serial.set_flush_consumes_timeout(true);
    for(unsigned n=0;n<10U&&!r19_runtime_fail_diagnostic_transport_failed;++n) loop_bridge();
    report.check(r19_runtime_fail_diagnostic_flush_pending,"diagnostic flush owns USB first");
  }
  if(scenario=="runtime_failed") {runtime_fail_closed=true;bridge_ready=false;}
  inject(req);
  if(scenario=="epoch") {
    loop_bridge();
    const auto prefix=Serial.tx_bytes().size();
    report.check(prefix==usb_before+7U,"private accepted prefix exists before epoch loss");
    Serial.simulate_tx_loss();loops(10U,100U);
    report.check(Serial.tx_bytes().size()==prefix&&aux_reads>aux_before,
        "epoch fault retains prefix without replay and still observes AUX");
  } else if(scenario=="deadline") {
    loops(52U,10U);
    const auto stopped=Serial.tx_bytes().size();
    Serial.set_tx_checked_accept_limit(32U);loops(5U);
    report.check(stopped==usb_before&&Serial.tx_bytes().size()==stopped,
        "500ms timeout is permanent and cannot later publish or replay");
    report.check(aux_reads>=aux_before+52U,"AUX observation survives private timeout");
  } else if(scenario=="pending_diag") {
    const auto held=Serial.tx_bytes().size();loops(5U);
    report.check(Serial.tx_bytes().size()==held&&parsed_output().clocks==0U,
        "private reply cannot interleave with held diagnostic prefix or flush");
    Serial.set_flush_failures(0U);Serial.set_flush_consumes_timeout(false);loops(8U);
  } else if(scenario=="cold_bootstrap") {
    loops(5U);
    report.check(Serial.tx_bytes().empty()&&parsed_output().clocks==0U,
        "private reply waits behind cold bootstrap ownership and unavailable host");
    Serial.set_endpoint_ready(true);loops(8U);
  } else if(scenario=="flush_retry") {
    Serial.set_flush_failures(2U);Serial.set_flush_consumes_timeout(true);
    const auto flush_begin=Serial.flush_count();
    loops(2U);
    report.check(Serial.tx_bytes().size()==usb_before+28U,
        "retrying clock flush writes payload once, not once per retry");
    Serial.set_flush_failures(0U);Serial.set_flush_consumes_timeout(false);loops(3U);
    report.check(Serial.flush_count()>=flush_begin+3U&&
        Serial.tx_bytes().size()==usb_before+28U,
        "clock flush-only retry completes without payload replay");
  } else if(scenario=="cold") {
    loops(10U);report.check(Serial.tx_bytes().empty(),"cold unavailable writer publishes nothing");
    Serial.set_available_for_write(256);loops(8U);
  } else if(scenario=="zero") {
    loops(10U,10U);report.check(Serial.tx_bytes().size()==usb_before,"zero acceptance publishes no prefix");
    Serial.set_tx_checked_accept_limit(32U);loops(8U);
  } else {
    loops(10U);
  }
  report.check(Serial.available()==0,"Vehicle consumes its USB-local request");
  R19FirstUsbFailureSnapshot first{};
  report.check(vc_lora_r19_first_usb_failure_record.try_snapshot(first)&&
      first.sync_count==1U&&first.last_sync_nonce==nonce,"Vehicle records its single validated clock request");
  const auto out=parsed_output();
  if(scenario!="epoch"&&scenario!="deadline") {
    report.check(out.clocks==1U&&out.reply_nonce==nonce&&out.bad_crc==0U,
        "exactly one complete nonce-matched CRC-valid ClockResponse is published");
    report.check(vc_lora_r19_timed_path_record.try_snapshot(timed)&&
        (timed.flags&(2U|4U|8U|16U|32U|64U|128U))==0U,
        "Vehicle sync never invents Ground-only timed session/ARM/product witnesses");
  }
  report.check(out.readies==0U,"Vehicle never emits READY or ARM");
  report.check(!contains(pixhawk_serial.normal_tx_bytes(),req)&&
      !contains(e220_serial.normal_tx_bytes(),req),"private clock never leaks to Pixhawk or E220");
  if(scenario=="basic"||scenario=="partial"||scenario=="zero") {
    const auto writes=Serial.tx_bytes().size();inject(req);inject(request(nonce+1U));
    R19HostReadinessCommand arm{};arm.role=R19HostReadinessRole::Ground;
    arm.reader_session=1U;arm.nonce=nonce;arm.boot_id=1U;arm.usb_epoch=Serial.txLossEpoch();
    arm.reply_device_us=1U;arm.proof_flags=r19_host_arm_required_proof;
    MavlinkFrame arm_frame{};(void)r19_encode_host_readiness_frame(0U,arm,arm_frame);inject(arm_frame);
    auto invalid=req;invalid.bytes[invalid.size-1U]^=1U;inject(invalid);
    loops(10U);
    report.check(Serial.available()==0&&Serial.tx_bytes().size()==writes&&parsed_output().clocks==1U,
        "replay, different nonce, ARM, and invalid CRC are consumed without another reply");
    report.check(!contains(pixhawk_serial.normal_tx_bytes(),arm_frame)&&
        !contains(e220_serial.normal_tx_bytes(),arm_frame),"ignored ARM cannot leak to product links");
  }
  std::cout<<"IT-R19-VEHICLE-USB-CLOCK scenario="<<scenario<<" checks="<<report.checks
      <<" failures="<<report.failures<<" clocks="<<out.clocks<<" ready="<<out.readies
      <<" sync_count="<<first.sync_count<<" aux_reads="<<aux_reads-aux_before<<'\n';
  return report.failures==0U?0:1;
}
