#include "fake_arduino_test_api.hpp"
#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#define VC_LORA_R19_TIMED_PATH_DIAGNOSTICS 1
#ifndef VC_LORA_R19_USB_READINESS_MODE
#define VC_LORA_R19_USB_READINESS_MODE 2
#endif
#include "phase6/vc_lora_phase6_bridge.hpp"
#include <array>
#include <iostream>
#include <string>

int main(int argc,char** argv) {
  using namespace vc_lora;
  using namespace vc_lora::experimental;
  using namespace vc_lora_phase6_firmware;
  const std::string mode=argc>1?argv[1]:"timeout";
  unsigned checks=0U,failures=0U;
  const auto check=[&](bool value,const char* name){++checks;if(!value){++failures;std::cerr<<"FAIL "<<name<<'\n';}};
  fake_arduino::reset_platform();fake_arduino::set_pin_input_level(D8,HIGH);
  Serial.set_plugged(true);Serial.set_endpoint_ready(true);setup_bridge();
  check(bridge_ready&&!runtime_fail_closed,"setup");
  check(kGroundUsbHeartbeatCommitDeadlineMs==106U,"106 ms unchanged");
  R19TimedPathSnapshot s;
  check(vc_lora_r19_timed_path_record.try_snapshot(s)&&s.valid_header()&&s.flags==1U&&
        s.mode==VC_LORA_R19_USB_READINESS_MODE,"diagnostic-only record initialized");
  const std::array<std::uint8_t,9U> payload{0U,0U,0U,0U,2U,3U,0U,4U,3U};
  MavlinkFrame hb{};
  check(encode_mavlink_v2(61U,1U,1U,0U,payload.data(),payload.size(),hb),"HB fixture");
  constexpr std::uint64_t nonce=0x52190000000000A1ULL;
  const auto clock_request=[&]() {
    std::array<std::uint8_t,16U> p{};
    for(unsigned i=0;i<8U;++i)p[8U+i]=static_cast<std::uint8_t>(nonce>>(i*8U));
    MavlinkFrame req{};(void)encode_mavlink_v2(2U,249U,193U,111U,p.data(),p.size(),req);
    return r19_intercept_usb_clock_request(req);
  };
#if VC_LORA_R19_USB_READINESS_MODE == 2
  check(!r19_product_usb_publication_allowed(),"pre ARM closed");
  check(clock_request(),"private clock consumed");
  check(r19_service_usb_clock_reply()&&Serial.tx_bytes().size()==28U,
        "Clock remains one 28-byte publication");
  check(r19_service_usb_clock_reply()&&Serial.tx_bytes().size()==60U&&
        !r19_usb_ready_publication_complete,"READY first 32-byte prefix");
  check(r19_service_usb_clock_reply()&&Serial.tx_bytes().size()==92U&&
        !r19_usb_ready_publication_complete,"READY second 32-byte prefix");
  check(r19_service_usb_clock_reply()&&Serial.tx_bytes().size()==94U&&
        r19_usb_ready_publication_complete&&
        Serial.tx_write_sizes()==std::vector<std::size_t>{28U,32U,32U,2U},
        "Clock and complete READY preserve exact bounded write history");
  R19HostReadinessCommand command{};
  check(r19_host_readiness_gate.ready_command(command),"same-boot READY binding");
  if(mode=="epoch_aborted") {
    Serial.simulate_tx_loss();
    check(!r19_product_usb_publication_allowed()&&runtime_fail_closed,"epoch change fails closed");
    check(vc_lora_r19_timed_path_record.try_snapshot(s)&&(s.flags&256U)!=0U&&
          (s.flags&(4U|8U|64U|128U))==0U,"epoch abort explicit, no invented ARM/frame/terminal");
    std::cout<<"IT-R19-TIMED-PATH-2-epoch_aborted checks="<<checks<<" failures="<<failures<<'\n';
    return failures==0U?0:1;
  }
  command.opcode=R19HostReadinessOpcode::Arm;command.proof_flags=r19_host_arm_required_proof;
  MavlinkFrame arm{};(void)r19_encode_host_readiness_frame(4U,command,arm);
  check(r19_intercept_usb_clock_request(arm)&&r19_product_usb_publication_allowed(),"ARM accepted");
  check(vc_lora_r19_timed_path_record.try_snapshot(s)&&(s.flags&6U)==6U&&
        s.reader_session==command.reader_session&&s.nonce==nonce&&s.expected_epoch==command.usb_epoch,
        "ARM and session immutable trace binding");
#endif
  const auto before=Serial.tx_bytes().size();
  const auto now=monotonic_now_ms();
  check(ground_usb_heartbeat_pacer.ingest(hb,now)==GroundUsbHeartbeatIngestStatus::Held,"hold");
  GroundUsbHeartbeatLease lease{};
  check(ground_usb_heartbeat_pacer.select_before_next_frame(now,lease)==GroundUsbHeartbeatBarrierStatus::LeaseReady&&
        admit_ground_paced_heartbeat(lease,now),"enqueue real frame");
  check(vc_lora_r19_timed_path_record.try_snapshot(s)&&(s.flags&8U)!=0U&&s.token==lease.token&&
        s.frame_size==hb.size&&s.budget_ms==106U,"first enqueue observed");
  for(std::size_t i=0U;i<hb.size;++i)check(s.frame_bytes[i]==hb.bytes[i],"exact immutable heartbeat image");
  if(mode!="before_deadline")pump_ground_usb_egress(now);
  if(mode=="timeout"){Serial.set_flush_failures(1U);Serial.set_flush_consumes_timeout(true);}
  if(mode=="before_deadline")fake_arduino::advance_time_ms(106U);
  observe_ground_paced_heartbeat_commit(monotonic_now_ms());
  check(vc_lora_r19_timed_path_record.try_snapshot(s),"terminal snapshot");
  if(mode=="success")check(s.completion_latched()&&!s.failure_latched()&&s.accepted_bytes==21U&&
      (s.flags&32U)!=0U&&!runtime_fail_closed,"separate successful local completion");
  else check(s.failure_latched()&&!s.completion_latched()&&runtime_fail_closed&&
      s.accepted_bytes==(mode=="before_deadline"?0U:21U),"failure exact final count no replay");
  if(mode=="before_deadline")check((s.flags&32U)==0U&&s.failure_reason==2U&&s.started_us==s.enqueue_us,
      "uncalled flush has no invented SDK observation");
  else check(s.sdk_snapshot_us>=s.accepted_us&&s.terminal_us>=s.sdk_snapshot_us,
      "snapshot timestamp is observation only");
  const auto frozen=s;
  observe_ground_paced_heartbeat_commit(monotonic_now_ms());
  check(vc_lora_r19_timed_path_record.try_snapshot(s)&&s.sequence==frozen.sequence&&
        Serial.tx_bytes().size()==before+(mode=="before_deadline"?0U:21U),"terminal and bytes not overwritten or retransmitted");
#if VC_LORA_R19_USB_READINESS_MODE == 1
  check((s.flags&6U)==0U,"SyncOnly did not invent session or ARM");
  check(clock_request()&&vc_lora_r19_timed_path_record.try_snapshot(s)&&(s.flags&2U)!=0U&&
        (s.flags&4U)==0U&&s.nonce==nonce&&s.enqueue_us==frozen.enqueue_us,
        "post failure clock can bind without rewriting first frame");
#endif
  std::cout<<"IT-R19-TIMED-PATH-"<<VC_LORA_R19_USB_READINESS_MODE<<'-'<<mode
           <<" checks="<<checks<<" failures="<<failures<<'\n';
  return failures==0U?0:1;
}
