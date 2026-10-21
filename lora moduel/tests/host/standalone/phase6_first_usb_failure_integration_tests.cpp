#include "fake_arduino_test_api.hpp"
#include "esp_timer.h"
std::int64_t first_failure_test_clock() noexcept;
const char* first_failure_mode = "transport";
bool first_failure_clock_armed = false;
unsigned first_failure_clock_reads = 0U;
#define esp_timer_get_time first_failure_test_clock
#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"
#undef esp_timer_get_time
#include <iostream>
#include <string>

std::int64_t first_failure_test_clock() noexcept {
  if (first_failure_clock_armed && first_failure_clock_reads++ == 2U) {
    const std::string mode(first_failure_mode);
    if (mode == "endpoint") Serial.set_endpoint_ready(false);
    if (mode == "wrapper_late") fake_arduino::advance_time_ms(107U);
  }
  return static_cast<std::int64_t>(fake_arduino::now_us);
}

int main(int argc, char** argv) {
  using namespace vc_lora;
  using namespace vc_lora::experimental;
  using namespace vc_lora_phase6_firmware;
  unsigned checks = 0U, failures = 0U;
  const auto check = [&](bool ok, const char* text) {
    ++checks; if (!ok) { ++failures; std::cerr << text << '\n'; }
  };
  if (argc > 1) first_failure_mode = argv[1];
  const std::string mode(first_failure_mode);
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true); Serial.set_endpoint_ready(true);
  setup_bridge();
  check(bridge_ready && !runtime_fail_closed, "setup");
  const std::uint8_t payload[9]{0U,0U,0U,0U,2U,3U,0U,4U,3U};
  MavlinkFrame hb{};
  check(encode_mavlink_v2(1U,1U,1U,0U,payload,9U,hb), "hb encode");
  const auto now = monotonic_now_ms();
  check(ground_usb_heartbeat_pacer.ingest(hb,now)==GroundUsbHeartbeatIngestStatus::Held, "hold");
  GroundUsbHeartbeatLease lease{};
  check(ground_usb_heartbeat_pacer.select_before_next_frame(now,lease)==GroundUsbHeartbeatBarrierStatus::LeaseReady &&
        admit_ground_paced_heartbeat(lease,now), "admit");
  pump_ground_usb_egress(now);
  if (mode == "transport" || mode == "sync_partial") {
    Serial.set_flush_failures(1U); Serial.set_flush_consumes_timeout(true);
  }
  if (mode == "before_deadline") fake_arduino::advance_time_ms(106U);
  first_failure_clock_armed = true;
  observe_ground_paced_heartbeat_commit(now);
  first_failure_clock_armed = false;
  Serial.set_flush_consumes_timeout(false);
  Serial.set_endpoint_ready(true);
  R19FirstUsbFailureSnapshot first{};
  check(vc_lora_r19_first_usb_failure_record.try_snapshot(first), "first snapshot");
  check(runtime_fail_closed && first.failure_latched(), "failure not frozen");
  check(first.token==lease.token && first.budget_ms==(mode=="before_deadline"?0U:106U) &&
        first.expected_frame_bytes==21U && first.accepted_frame_bytes==21U,
        "exact product attempt identity");
  if (mode == "before_deadline")
    check(!first.api_called() && first.reason==2U && first.sdk.terminal_reason==0U,
          "API not called must not invent FIFO state");
  else if (mode == "endpoint" || mode == "wrapper_late")
    check(first.sdk.terminal_reason==1U && first.sdk.raw_return==1U,
          "successful raw API confused with wrapper/predicate failure");
  else check(first.sdk.terminal_reason==5U && first.sdk.raw_return==0U,
             "first flush timeout lost");
  check(first.failure_observed_us>=first.finished_us, "failure clock precedes API return");
  const auto radio_before = e220_serial.normal_tx_bytes().size();
  std::uint8_t clock_payload[16]{};
  const std::uint64_t nonce = 0x5219000000000123ULL;
  for (unsigned i=0;i<8U;++i) clock_payload[8U+i]=static_cast<std::uint8_t>(nonce>>(i*8U));
  MavlinkFrame request{};
  check(encode_mavlink_v2(9U,249U,193U,111U,clock_payload,16U,request), "clock request");
  if(mode=="sync_partial") {
    for(unsigned i=0;i<10U;++i){fake_arduino::advance_time_ms(20U);loop_bridge();}
    Serial.set_tx_checked_accept_limit(7U);
  }
  Serial.inject_rx(request.bytes.data(),request.size);
  for (unsigned i=0;i<40U;++i) { fake_arduino::advance_time_ms(50U); loop_bridge(); }
  for(unsigned i=0;i<64U && (r19_runtime_fail_diagnostic_staged || r19_usb_clock_reply_active);++i) {
    fake_arduino::advance_time_ms(1U);loop_bridge();
  }
  R19FirstUsbFailureSnapshot after{};
  check(vc_lora_r19_first_usb_failure_record.try_snapshot(after), "after snapshot");
  check(after.token==first.token && after.started_us==first.started_us &&
        after.sdk.terminal_reason==first.sdk.terminal_reason,
        "later diagnostics overwrote first failure");
  check(after.last_sync_nonce==nonce && after.last_sync_device_us>0U,
        "post-failure diagnostic request was not timestamped");
  check(runtime_fail_closed && e220_serial.normal_tx_bytes().size()==radio_before,
        "diagnostic revived product or leaked to RF");
  MavlinkStreamParser parser{}; MavlinkFrame got{}; bool replied=false;
  for (auto b:Serial.tx_bytes()) if(parser.push(b,got)==MavlinkParseStatus::FrameReady &&
      got.message_id==111U && got.system_id==249U && got.component_id==194U) replied=true;
  check(replied, "no local clock response after failure");
  check(parser.diagnostics().crc_errors==0U && parser.buffered_size()==0U,
        "clock response interleaved with diagnostics");
  std::cout << "IT-R19-FIRST-USB-FAILURE-001 mode=" << mode << " checks=" << checks << " failures=" << failures << '\n';
  return failures==0U?0:1;
}
