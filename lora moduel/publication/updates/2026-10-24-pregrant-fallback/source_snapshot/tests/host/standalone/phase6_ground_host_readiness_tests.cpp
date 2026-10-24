#include "fake_arduino_test_api.hpp"

// The shared fake intentionally models arbitrary partial acceptance. Model the
// patched SDK's additional all-or-zero 32-byte call limit locally: merely
// limiting the number accepted would conceal an oversized READY submission.
namespace {
class Sdk32Usb final {
 public:
  std::vector<std::size_t> requested{};
  std::size_t oversized_rejections{0U};
  void begin(std::uint32_t baud) noexcept { Serial.begin(baud); }
  bool isPlugged() const noexcept { return Serial.isPlugged(); }
  explicit operator bool() const noexcept { return static_cast<bool>(Serial); }
  int available() const noexcept { return Serial.available(); }
  int read() noexcept { return Serial.read(); }
  int availableForWrite() const noexcept { return Serial.availableForWrite(); }
  std::uint32_t txLossEpoch() const noexcept { return Serial.txLossEpoch(); }
  std::size_t writeTxChecked(const std::uint8_t* bytes, std::size_t size,
                            std::uint32_t epoch) noexcept {
    requested.push_back(size);
    if (size > 32U) { ++oversized_rejections; return 0U; }
    return Serial.writeTxChecked(bytes, size, epoch);
  }
  std::size_t writeTxBootstrapFrameChecked(const std::uint8_t* bytes,
      std::size_t size, std::uint32_t epoch) noexcept {
    return Serial.writeTxBootstrapFrameChecked(bytes, size, epoch);
  }
  bool flushTxComplete(std::uint32_t timeout, std::uint32_t epoch) noexcept {
    return Serial.flushTxComplete(timeout, epoch);
  }
  bool flushTxCompleteDiagnostic(std::uint32_t timeout, std::uint32_t epoch,
      vc_lora::experimental::R19HwcdcFlushCallEvidence& evidence) noexcept {
    return Serial.flushTxCompleteDiagnostic(timeout, epoch, evidence);
  }
};
Sdk32Usb sdk32_serial{};
std::size_t aux_gpio_reads{0U};
int observed_digital_read(int pin) noexcept {
  if (pin == D8) ++aux_gpio_reads;
  return digitalRead(pin);
}
}  // namespace

#define Serial sdk32_serial
#define digitalRead observed_digital_read
#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#ifndef VC_LORA_R19_USB_READINESS_MODE
#define VC_LORA_R19_USB_READINESS_MODE 2
#endif
#include "phase6/vc_lora_phase6_bridge.hpp"
#undef digitalRead
#undef Serial

#include <array>
#include <cstdint>
#include <iostream>

int main() {
  using namespace vc_lora_phase6_firmware;
  using namespace vc_lora::experimental;
  unsigned checks=0U, failures=0U;
  const auto check=[&](bool value,const char* message) {
    ++checks;
    if(!value){++failures;std::cerr<<message<<'\n';}
  };
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8,HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  setup_bridge();
  check(bridge_ready && !runtime_fail_closed,"setup failed");
  check(kGroundUsbHeartbeatCommitDeadlineMs==106U,"product budget changed");
  check(!r19_product_usb_publication_allowed() &&
        r19_usb_readiness_configured && !r19_usb_readiness_initialized,
        "default gate leaked before first diagnostic request");

  // Enumeration can advance the epoch before the host's first request. The
  // wrapper remains closed and the request binds the actual current epoch.
  for(unsigned i=0U;i<7U;++i) Serial.simulate_tx_loss();
  ground_usb_observed_loss_epoch=7U;
  std::array<std::uint8_t,9U> heartbeat_payload{
      0U,0U,0U,0U,2U,3U,0U,4U,3U};
  vc_lora::MavlinkFrame heartbeat{}, status{};
  (void)vc_lora::encode_mavlink_v2(41U,1U,1U,0U,
      heartbeat_payload.data(),heartbeat_payload.size(),heartbeat);
  std::array<std::uint8_t,31U> status_payload{};
  (void)vc_lora::encode_mavlink_v2(42U,1U,1U,1U,
      status_payload.data(),status_payload.size(),status);
  handle_ground_validated_frame(heartbeat,monotonic_now_ms());
  handle_ground_validated_frame(status,monotonic_now_ms());
  service_ground_usb_heartbeat_pacer(monotonic_now_ms());
  pump_ground_usb_egress(monotonic_now_ms());
  check(radio_application_endpoint.egress().empty() && Serial.tx_bytes().empty(),
        "product bytes entered egress before HostArm");
  check(ground_usb_heartbeat_pacer.queued()==1U &&
        !ground_usb_ordered_backlog.empty(),"complete RF backlog not retained");

  constexpr std::uint64_t nonce=0x5219000000000021ULL;
  std::array<std::uint8_t,16U> request_payload{};
  for(unsigned i=0;i<8U;++i)
    request_payload[8U+i]=static_cast<std::uint8_t>(nonce>>(8U*i));
  vc_lora::MavlinkFrame request{};
  (void)vc_lora::encode_mavlink_v2(2U,249U,193U,111U,
      request_payload.data(),request_payload.size(),request);
  check(r19_intercept_usb_clock_request(request),"clock request escaped local demux");
  check(r19_usb_readiness_initialized &&
        r19_host_readiness_gate.snapshot().usb_epoch==7U,
        "request did not bind current post-enumeration epoch");
  check(r19_service_usb_clock_reply() && Serial.tx_bytes().size()==28U &&
        r19_usb_clock_reply_pending && !r19_usb_ready_publication_complete,
        "clock publication did not retain exclusive READY continuation");
  const auto expected_ready = r19_usb_clock_reply;
  check(expected_ready.size==66U,"READY fixture no longer exercises 66 bytes");
  check(r19_service_usb_clock_reply() && Serial.tx_bytes().size()==60U &&
        r19_usb_clock_reply_offset==32U &&
        !r19_usb_ready_publication_complete,
        "READY did not publish exactly its first 32-byte prefix");
  R19HostReadinessCommand early_command{};
  vc_lora::MavlinkFrame early_arm{};
  check(r19_decode_host_readiness_frame(expected_ready,early_command),
        "READY partial-publication fixture could not decode ARM binding");
  early_command.opcode=R19HostReadinessOpcode::Arm;
  early_command.proof_flags=r19_host_arm_required_proof;
  (void)r19_encode_host_readiness_frame(4U,early_command,early_arm);
  check(r19_intercept_usb_clock_request(early_arm) &&
        !r19_product_usb_publication_allowed(),
        "matching ARM was accepted before the READY suffix/flush completed");
  check(r19_service_usb_clock_reply() && Serial.tx_bytes().size()==92U &&
        r19_usb_clock_reply_offset==64U &&
        !r19_usb_ready_publication_complete,
        "READY did not retain its second 32-byte prefix");
  check(r19_service_usb_clock_reply() && Serial.tx_bytes().size()==94U &&
        r19_usb_ready_publication_complete &&
        !r19_product_usb_publication_allowed(),
        "READY publication incorrectly armed product output");
  check(sdk32_serial.oversized_rejections==0U &&
        sdk32_serial.requested==std::vector<std::size_t>{28U,32U,32U,2U} &&
        Serial.tx_write_sizes()==std::vector<std::size_t>{28U,32U,32U,2U},
        "Clock/READY calls did not obey the real SDK's 32-byte contract");
  check(Serial.tx_bytes().size()==94U && std::equal(expected_ready.bytes.begin(),
        expected_ready.bytes.begin()+expected_ready.size,
        Serial.tx_bytes().begin()+28U),
        "READY accepted bytes were reordered, duplicated, or omitted");
  vc_lora::MavlinkStreamParser private_parser{};
  std::array<vc_lora::MavlinkFrame,2U> private_frames{};
  std::size_t private_frame_count=0U, private_parser_errors=0U;
  for(const auto byte:Serial.tx_bytes()) {
    vc_lora::MavlinkFrame parsed{};
    const auto result=private_parser.push(byte,parsed);
    if(result==vc_lora::MavlinkParseStatus::FrameReady) {
      if(private_frame_count<private_frames.size())
        private_frames[private_frame_count]=parsed;
      ++private_frame_count;
    } else if(result!=vc_lora::MavlinkParseStatus::NeedMore) {
      ++private_parser_errors;
    }
  }
  check(private_frame_count==2U && private_parser_errors==0U &&
        private_frames[0].message_id==111U && private_frames[0].size==28U &&
        private_frames[1].size==66U,
        "split READY did not preserve complete Clock/READY MAVLink CRC/order");
  for(unsigned i=0U;i<5U;++i) {
    fake_arduino::advance_time_ms(100U);
    (void)r19_service_usb_clock_reply();
  }
  check(r19_usb_ready_publication_complete && !r19_usb_clock_reply_fault,
        "66-byte READY stalled with available=256 until its 500-ms fault");
  R19HostReadinessCommand command{};
  check(r19_host_readiness_gate.ready_command(command),"READY binding unavailable");
  command.opcode=R19HostReadinessOpcode::Arm;
  command.proof_flags=r19_host_arm_required_proof;
  vc_lora::MavlinkFrame arm{};
  (void)r19_encode_host_readiness_frame(4U,command,arm);
  auto stale=arm;
  stale.bytes[20U]^=1U;
  check(r19_intercept_usb_clock_request(stale) &&
        !r19_product_usb_publication_allowed(),"invalid ARM escaped or armed gate");
  check(r19_intercept_usb_clock_request(arm) &&
        r19_product_usb_publication_allowed(),"matching explicit ARM was not accepted");

  service_ground_usb_heartbeat_pacer(monotonic_now_ms());
  check(ground_paced_heartbeat_commit_active &&
        radio_application_endpoint.egress().queued_bytes()==21U,
        "first real heartbeat was not admitted only after ARM");
  pump_ground_usb_egress(monotonic_now_ms());
  const auto accepted_bytes=Serial.tx_bytes().size();
  Serial.set_flush_failures(1U);
  observe_ground_paced_heartbeat_commit(monotonic_now_ms());
  observe_ground_paced_heartbeat_commit(monotonic_now_ms());
  check(accepted_bytes==115U && Serial.tx_bytes().size()==accepted_bytes &&
        runtime_fail_closed && !ground_paced_heartbeat_commit_active,
        "fully accepted 21 bytes were replayed after Rejected publication");

  // Expiry is serviced while the experiment waits. Expired wire images must
  // not be made fresh by a late ARM or left with stale paired FIFO markers.
  runtime_fail_closed=false; bridge_ready=true;
  r19_host_readiness_gate={}; r19_usb_readiness_initialized=false;
  ground_usb_ordered_backlog.reset();
  ground_usb_heartbeat_pacer=vc_lora::GroundUsbHeartbeatPacer{
      product_ground_usb_heartbeat_pacer_config()};
  ground_usb_heartbeat_pacer.set_usb_connected(true,monotonic_now_ms());
  handle_ground_validated_frame(heartbeat,monotonic_now_ms());
  fake_arduino::advance_time_ms(2500U);
  service_ground_usb_heartbeat_pacer(monotonic_now_ms());
  check(ground_usb_heartbeat_pacer.queued()==0U &&
        ground_usb_ordered_backlog.empty() &&
        ground_usb_heartbeat_pacer.diagnostics().expired_heartbeats==1U &&
        Serial.tx_bytes().size()==accepted_bytes,
        "waiting gate retained/replayed expired heartbeat or stale marker");
  runtime_fail_closed=false; bridge_ready=true;
  fake_arduino::advance_time_ms(120001U);
  check(!r19_product_usb_publication_allowed() && runtime_fail_closed,
        "absence of any first nonce left the acquisition wait unbounded");

  // Exercise accepted prefixes, zero-write retry, stale epoch, and the exact
  // 500-ms deadline without resetting or replaying an accepted byte.
  const auto reset_private=[&]() {
    runtime_fail_closed=false; bridge_ready=true;
    r19_usb_clock_reply=expected_ready;
    r19_usb_private_reply_kind=R19UsbPrivateReplyKind::Ready;
    r19_usb_clock_reply_pending=false;
    r19_usb_clock_reply_active=true;
    r19_usb_clock_reply_fault=false;
    r19_usb_ready_publication_complete=false;
    r19_usb_clock_reply_offset=0U;
    r19_usb_clock_reply_epoch=Serial.txLossEpoch();
    r19_usb_clock_reply_deadline_ms=monotonic_now_ms()+500U;
    Serial.set_tx_checked_accept_limit(std::numeric_limits<std::size_t>::max());
    Serial.set_available_for_write(256);
  };
  reset_private();
  const auto partial_begin=Serial.tx_bytes().size();
  Serial.set_tx_checked_accept_limit(7U);
  check(r19_service_usb_clock_reply() && r19_usb_clock_reply_offset==7U,
        "partial READY prefix was not retained");
  Serial.set_tx_checked_accept_limit(0U);
  check(r19_service_usb_clock_reply() && r19_usb_clock_reply_offset==7U &&
        Serial.tx_bytes().size()==partial_begin+7U,
        "zero READY retry replayed or discarded an accepted prefix");
  Serial.set_tx_checked_accept_limit(std::numeric_limits<std::size_t>::max());
  for(unsigned i=0U;i<3U;++i) (void)r19_service_usb_clock_reply();
  check(r19_usb_ready_publication_complete &&
        Serial.tx_bytes().size()==partial_begin+66U &&
        std::equal(expected_ready.bytes.begin(),
            expected_ready.bytes.begin()+expected_ready.size,
            Serial.tx_bytes().begin()+static_cast<std::ptrdiff_t>(partial_begin)),
        "partial/zero READY continuation was not exact-once");

  reset_private();
  (void)r19_service_usb_clock_reply();
  const auto stale_prefix_size=Serial.tx_bytes().size();
  const auto stale_prefix_offset=r19_usb_clock_reply_offset;
  Serial.simulate_tx_loss();
  check(r19_service_usb_clock_reply() && r19_usb_clock_reply_fault &&
        !r19_usb_ready_publication_complete &&
        Serial.tx_bytes().size()==stale_prefix_size &&
        r19_usb_clock_reply_offset==stale_prefix_offset,
        "epoch change replayed READY or released failed ownership");
  fake_arduino::advance_time_ms(501U);
  check(r19_service_usb_clock_reply() && r19_usb_clock_reply_fault &&
        Serial.tx_bytes().size()==stale_prefix_size,
        "faulted private writer resumed after epoch/deadline loss");
  reset_private();
  Serial.set_tx_checked_accept_limit(0U);
  const auto zero_begin=Serial.tx_bytes().size();
  for(unsigned i=0U;i<5U;++i) {
    (void)r19_service_usb_clock_reply();
    fake_arduino::advance_time_ms(100U);
  }
  check(!r19_usb_clock_reply_fault && r19_usb_clock_reply_offset==0U,
        "private writer consumed its deadline early");
  check(r19_service_usb_clock_reply() && r19_usb_clock_reply_fault &&
        Serial.tx_bytes().size()==zero_begin &&
        !r19_usb_ready_publication_complete,
        "zero-acceptance READY did not fault at the original 500-ms deadline");

  // An exclusive USB private writer must not starve the independent AUX
  // observer. Use the actual bridge loop, with product/RF work deliberately
  // queued. Observation may set a completion flag; it must not consume that
  // completion, release the RF writer, drain egress, or tick normal traffic.
  for(unsigned mode=0U;mode<4U;++mode) {
    reset_private();
    Serial.set_available_for_write(0);
    r19_usb_clock_reply_active=mode==0U;
    r19_usb_clock_reply_pending=mode==1U;
    r19_usb_clock_reply_fault=mode>=2U;
    runtime_fail_closed=mode==3U;
    radio_application_endpoint.reset();
    check(radio_application_endpoint.admit_validated_frame(status)==
              vc_lora::ValidatedLocalIngressStatus::QueuedFrame,
          "observe-only fixture could not queue normal egress");
    const auto egress_before=radio_application_endpoint.egress().queued_bytes();
    const auto egress_pending_before=radio_application_endpoint.egress().write_pending();
    const auto egress_accepted_before=
        radio_application_endpoint.egress().stats().bytes_physically_accepted;
    const auto radio_before=e220_serial.normal_tx_bytes().size();
    const auto usb_before=Serial.tx_bytes().size();
    const auto flush_before=Serial.flush_count();
    const auto tdd_before=tdd_controller.state();
    const auto time_begin=monotonic_now_ms();
    e220_write_contract={};
    (void)e220_write_contract.observe_aux(true,time_begin);
    fake_arduino::advance_time_ms(15U);
    (void)e220_write_contract.observe_aux(true,monotonic_now_ms());
    check(e220_write_contract.begin_write(32U),
          "observe-only fixture could not start radio contract");
    check(e220_write_contract.report_write_result(32U,monotonic_now_ms(),false)==
              vc_lora::E220WriteDisposition::AcceptedAll,
          "observe-only fixture could not accept radio block");
    e220_writer_arbiter={};
    clear_standard_radio_writer_lease();
    vc_lora::LinkAction retained_action{};
    retained_action.type=vc_lora::LinkActionType::SendRadioData;
    retained_action.token=100U+mode;
    check(acquire_standard_radio_writer_lease(retained_action) &&
          retain_accepted_standard_radio_writer_lease(monotonic_now_ms()),
          "observe-only fixture could not retain the accepted UART writer lease");
    const auto retained_lease=standard_radio_writer_lease;
    radio_busy=true; pending_radio_action={};
    fake_arduino::set_pin_input_level(D8,LOW);
    const auto sample_begin=aux_gpio_reads;
    loop_bridge();
    check(aux_gpio_reads==sample_begin+1U,
          "private active/pending/fault loop starved LOW AUX observation");
    fake_arduino::advance_time_ms(530U);
    fake_arduino::set_pin_input_level(D8,HIGH);
    loop_bridge();
    fake_arduino::advance_time_ms(20U);
    loop_bridge();
    check(aux_gpio_reads==sample_begin+3U &&
          e220_write_contract.ready_for_write() &&
          e220_write_contract.take_write_completion() && radio_busy,
          "private USB ownership failed to observe HIGH/floor or consumed RF completion");
    check(standard_radio_writer_lease.owner==retained_lease.owner &&
          standard_radio_writer_lease.action_token==retained_lease.action_token &&
          standard_radio_writer_lease.writer_generation==retained_lease.writer_generation &&
          standard_radio_writer_tail_pending && e220_writer_arbiter.write_active() &&
          e220_writer_arbiter.last_status()==Phase6RadioWriterStatus::AcceptedAwaitingTail,
          "observe-only AUX path released or replaced the retained UART/RF tail lease");
    check(radio_application_endpoint.egress().queued_bytes()==egress_before &&
          radio_application_endpoint.egress().write_pending()==egress_pending_before &&
          radio_application_endpoint.egress().stats().bytes_physically_accepted==
              egress_accepted_before &&
          e220_serial.normal_tx_bytes().size()==radio_before &&
          Serial.tx_bytes().size()==usb_before &&
          Serial.flush_count()==flush_before && tdd_controller.state()==tdd_before,
          "observe-only AUX path advanced normal egress, USB/RF output, or TDD");
    check(runtime_fail_closed==(mode==3U) &&
          (mode<2U || r19_usb_clock_reply_fault),
          "AUX observation cleared a latched stop/private ownership fault");

    // A real AUX timeout remains a permanent safety stop. Observation during
    // a private USB fault must neither suppress it nor repair it implicitly.
    e220_write_contract={};
    (void)e220_write_contract.observe_aux(true,monotonic_now_ms());
    fake_arduino::advance_time_ms(15U);
    (void)e220_write_contract.observe_aux(true,monotonic_now_ms());
    (void)e220_write_contract.begin_write(32U);
    (void)e220_write_contract.report_write_result(32U,monotonic_now_ms(),false);
    fake_arduino::set_pin_input_level(D8,LOW);
    fake_arduino::advance_time_ms(2000U);
    loop_bridge();
    check(e220_write_contract.fail_closed() && runtime_fail_closed &&
          e220_write_contract.fault()==vc_lora::E220WriteFault::AuxDidNotReturnHigh,
          "private USB ownership suppressed the unchanged 2-second AUX stop");
    fake_arduino::set_pin_input_level(D8,HIGH);
    fake_arduino::advance_time_ms(15U);
    loop_bridge();
    check(e220_write_contract.fail_closed() && runtime_fail_closed &&
          radio_busy && e220_serial.normal_tx_bytes().size()==radio_before &&
          standard_radio_writer_lease.owner==retained_lease.owner &&
          standard_radio_writer_lease.action_token==retained_lease.action_token &&
          standard_radio_writer_lease.writer_generation==retained_lease.writer_generation &&
          standard_radio_writer_tail_pending && e220_writer_arbiter.write_active(),
          "later AUX HIGH cleared a permanent fault or released RF traffic");
  }
  std::cout<<"R19-GROUND-HOST-READINESS-001 checks="<<checks
           <<" failures="<<failures<<'\n';
  return failures==0U?0:1;
}
