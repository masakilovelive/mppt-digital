#include "fake_arduino_test_api.hpp"
#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#define VC_LORA_R19_USB_READINESS_MODE 2
#define VC_LORA_R19_TIMED_PATH_DIAGNOSTICS 1
#define VC_LORA_R19_AUX_READINESS_DIAGNOSTICS 1
#define VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD 1
#define VC_LORA_R19_GRANT_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <string>

using namespace vc_lora;
using namespace vc_lora::experimental;
using namespace vc_lora_phase6_firmware;

namespace {
unsigned checks = 0U;
unsigned failures = 0U;
void check(bool value, const char* message) {
  ++checks;
  if (!value) {
    ++failures;
    std::cerr << "FAIL " << message << '\n';
  }
}

void at(std::uint64_t ms) {
  check(monotonic_now_ms() <= ms, "test clock is monotonic");
  if (monotonic_now_ms() <= ms)
    fake_arduino::advance_time_ms(ms - monotonic_now_ms());
}

MavlinkFrame make_request(std::uint8_t sequence = 11U,
                         std::uint8_t target = 1U) {
  const std::array<std::uint8_t, 2U> payload{{target, 1U}};
  MavlinkFrame result{};
  check(encode_mavlink_v2(sequence, 255U, 190U, 21U, payload.data(),
                         payload.size(), result), "encode exact PARAM request");
  return result;
}

MavlinkFrame make_heartbeat() {
  constexpr std::array<std::uint8_t, 9U> payload{{0U,0U,0U,0U,2U,3U,0U,4U,3U}};
  MavlinkFrame frame{};
  check(encode_mavlink_v2(31U,255U,190U,0U,payload.data(),payload.size(),frame),
        "encode ordinary non-PARAM frame");
  return frame;
}

void submit(const MavlinkFrame& frame, std::uint64_t ms) {
  at(ms);
  Serial.inject_rx(frame.bytes.data(), frame.size);
  collect_local_ingress(monotonic_now_ms());
}

TddControlMessage grant(std::uint16_t cycle) {
  TddControlMessage value{};
  value.type = ControlType::UlGrant;
  value.session_id = 640U;
  value.cycle_id = cycle;
  return value;
}

void fixture_setup() {
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  setup_bridge();
  check(bridge_ready && !runtime_fail_closed && r19_ground_adapter != nullptr,
        "actual production bridge starts ready with real Ground adapter");
  check(ground_parameter_proxy.list_strategy() == GroundParameterListStrategy::NativeStream,
        "fallback test uses unchanged product native-stream proxy");
  const auto ready_us = fake_arduino::now_us;
  const auto epoch = Serial.txLossEpoch();
  constexpr std::uint64_t nonce = 0x5219000000000123ULL;
  r19_usb_readiness_initialized = r19_host_readiness_gate.begin_session(
      R19HostReadinessMode::ExplicitHostArm,R19HostReadinessRole::Ground,
      r19_usb_readiness_boot_id,epoch,r19_usb_readiness_reader_session,
      ready_us,5000000U);
  check(r19_usb_readiness_initialized &&
            r19_host_readiness_gate.observe_clock_request(nonce,epoch,ready_us+1U) &&
            r19_host_readiness_gate.record_clock_reply(nonce,ready_us+2U,epoch,ready_us+3U),
        "fixture proves actual readiness gate clock-response witnesses");
  R19HostReadinessCommand arm{};
  arm.opcode=R19HostReadinessOpcode::Arm;arm.role=R19HostReadinessRole::Ground;
  arm.proof_flags=r19_host_arm_required_proof;
  arm.reader_session=r19_usb_readiness_reader_session;arm.nonce=nonce;
  arm.boot_id=r19_usb_readiness_boot_id;arm.usb_epoch=epoch;
  arm.reply_device_us=ready_us+2U;
  check(r19_host_readiness_gate.accept_arm(arm,epoch,ready_us+4U),
        "fixture semantically arms the real product publication gate");
  fake_arduino::advance_time_ms(1U);
  at(9233U);
  r19_observe_ground_grant(grant(1U), ControlDisposition::Accepted,
                            monotonic_now_ms());
  check(!runtime_fail_closed, "standard Grant baseline accepted");
  r19_have_ground_usb_heartbeat_commit = true;
  r19_last_ground_usb_heartbeat_commit_ms = 9233U;
}

void hold(const MavlinkFrame& frame) {
  submit(frame, 12351U);
  check(bridge_ready && !runtime_fail_closed && r19_product_route_selected &&
            r19_ground_adapter->hold_standard_uplink(),
        "actual Serial parser intercepts and holds first complete request");
  check(r19_ground_adapter->t0_ms() == 12351U &&
            ground_ingress.queued_frames() == 0U &&
            ground_parameter_proxy.diagnostics().native_list_requests_leased == 0U,
        "held request has original origin and has not entered standard proxy");
}

void service(std::uint64_t ms) {
  at(ms);
  r19_service_high_speed_product_route(monotonic_now_ms());
}

void assert_refused(std::size_t prior_frames, std::size_t prior_usb,
                    std::size_t prior_radio) {
  check(runtime_fail_closed && !bridge_ready,
        "unsafe or unknown failure still closes whole product runtime");
  check(!r19_acceleration_consumed,
        "refused fallback cannot masquerade as safely consumed acceleration");
  check(ground_ingress.queued_frames() == prior_frames &&
            ground_parameter_proxy.diagnostics().native_list_requests_leased == 0U,
        "refused fallback never leases or enqueues held PARAM request");
  check(Serial.tx_bytes().size() == prior_usb &&
            e220_serial.normal_tx_bytes().size() == prior_radio,
        "refusal emits neither debug/control USB bytes nor radio payload");
}

void assert_exact_fallback(const MavlinkFrame& first, std::size_t prior_usb,
                           std::size_t prior_radio) {
  check(bridge_ready && !runtime_fail_closed,
        "clean pre-negotiation deadline preserves product runtime");
  check(r19_acceleration_consumed && !r19_product_route_selected &&
            !r19_standard_tdd_frozen,
        "safe one-shot fallback selects unchanged standard path");
  check(r19_ground_adapter->fail_closed() &&
            r19_ground_adapter->t0_ms() == 12351U,
        "failed high-speed adapter is retained without resetting original origin");
  const auto frozen = r19_ground_adapter->first_failure_diagnostics();
  check(frozen.request_origin_ms == 12351U && frozen.observed_ms == 12852U &&
            frozen.owner_result == BulkSessionResult::GrantDeadlineExceeded &&
            frozen.coordinator_result == HighSpeedCoordinatorResult::GrantDeadlineExceeded &&
            !frozen.fresh_grant_observed_valid && !frozen.coordinator_grant_staged_valid,
        "exact missing-Grant first-failure evidence survives safe fallback");
  // Normal proxy admission is serviced by the same production ingress pump.
  collect_local_ingress(monotonic_now_ms());
  check(ground_parameter_proxy.diagnostics().native_list_requests_leased == 1U &&
            ground_parameter_proxy.diagnostics().sessions_started == 1U &&
            ground_ingress.queued_frames() == 1U &&
            ground_ingress.queued_bytes() == first.size && ground_proxy_request_admitted,
        "the same normal proxy/ingress path owns exactly one native request");
  std::array<std::uint8_t, kMavlinkMaxFrameBytes> bytes{};
  const auto n = ground_ingress.peek(bytes.data(), bytes.size());
  check(n == first.size && std::equal(first.bytes.begin(),
            first.bytes.begin() + static_cast<std::ptrdiff_t>(first.size), bytes.begin()),
        "fallback preserves byte-exact first PARAM frame, not regenerated duplicate");
  check(Serial.tx_bytes().size() == prior_usb &&
            e220_serial.normal_tx_bytes().size() == prior_radio,
        "fallback only queues standard request, never directly writes USB or UART");
}

void publish_primary_heartbeat_after_fallback(std::size_t prior_usb) {
  constexpr std::array<std::uint8_t,9U> payload{{0U,0U,0U,0U,2U,3U,0U,4U,3U}};
  MavlinkFrame heartbeat{};
  check(encode_mavlink_v2(71U,1U,1U,0U,payload.data(),payload.size(),heartbeat),
        "encode primary Vehicle heartbeat after fallback");
  const auto now = monotonic_now_ms();
  check(ground_usb_heartbeat_pacer.ingest(heartbeat,now) ==
            GroundUsbHeartbeatIngestStatus::Held,
        "real primary heartbeat enters unchanged product pacer");
  GroundUsbHeartbeatLease lease{};
  check(ground_usb_heartbeat_pacer.select_before_next_frame(now,lease) ==
            GroundUsbHeartbeatBarrierStatus::LeaseReady &&
            admit_ground_paced_heartbeat(lease,now),
        "primary heartbeat enters real product USB FIFO after fallback");
  pump_ground_usb_egress(now);
  observe_ground_paced_heartbeat_commit(now);
  check(bridge_ready && !runtime_fail_closed &&
            !ground_paced_heartbeat_commit_active &&
            ground_usb_heartbeat_pacer.diagnostics().emitted_heartbeats == 1U &&
            Serial.tx_bytes().size() == prior_usb+heartbeat.size,
        "primary paced heartbeat completes product USB fence after fallback");
  MavlinkStreamParser parser{};MavlinkFrame actual{};unsigned frame_count=0U;
  for(std::size_t i=prior_usb;i<Serial.tx_bytes().size();++i)
    if(parser.push(Serial.tx_bytes()[i],actual) == MavlinkParseStatus::FrameReady)
      ++frame_count;
  check(frame_count == 1U && actual.message_id == 0U && actual.system_id == 1U &&
            actual.component_id == 1U && parser.diagnostics().crc_errors == 0U &&
            parser.buffered_size() == 0U,
        "only one complete primary MAVLink heartbeat, no private/control/debug leakage");
}
}  // namespace

int main(int argc, char** argv) {
  const std::string scenario = argc == 2 ? argv[1] : "success";
  static_assert(BulkSessionTiming::grant_wait_budget_ms == 500U);
  static_assert(sizeof(R19GrantDiagnosticRecord) == 1024U);
  fixture_setup();
  const auto first = make_request();
  const auto initial_epoch = ground_usb_observed_loss_epoch;
  const auto usb_before = Serial.tx_bytes().size();
  const auto radio_before = e220_serial.normal_tx_bytes().size();
  bool primary_published = false;

  if (scenario == "nonparam") {
    const auto hb = make_heartbeat();
    submit(hb,12351U);
    check(bridge_ready && !runtime_fail_closed && !r19_product_route_selected &&
              !r19_acceleration_consumed && ground_ingress.queued_frames() == 1U &&
              ground_ingress.queued_bytes() == hb.size,
          "ordinary non-PARAM remains unchanged before acceleration admission");
  } else {
    hold(first);
    if (scenario == "duplicate") {
      submit(make_request(12U,2U),12400U);
      check(r19_ground_adapter->t0_ms() == 12351U &&
                ground_ingress.queued_frames() == 0U,
            "second held PARAM is Busy and cannot replace first origin/frame");
    }
    if (scenario == "epoch") Serial.simulate_tx_loss();
    if (scenario == "frozen") r19_standard_tdd_frozen = true;
    if (scenario == "session") {
      r19_radio_session = ::new(static_cast<void*>(r19_radio_session_storage.data()))
          Phase6HighSpeedRadioSession(e220_writer_arbiter,1U);
    }
    if (scenario == "staged") r19_session_owners_constructed = true;
    Phase6RadioWriterLease existing{};
    if (scenario == "writer" || scenario == "standard-writer") {
      const auto owner = scenario == "standard-writer"
          ? Phase6RadioWriterOwner::StandardTdd : Phase6RadioWriterOwner::HighSpeed;
      if (owner == Phase6RadioWriterOwner::HighSpeed)
        check(e220_writer_arbiter.activate_high_speed() ==
                  Phase6RadioWriterStatus::HighSpeedActivated, "select unsafe high-speed writer mode");
      check(e220_writer_arbiter.request(owner,77U,existing) ==
                Phase6RadioWriterStatus::LeaseGranted, "reserve existing writer lease");
      if (scenario == "standard-writer") {
        standard_radio_writer_lease = existing;
        standard_radio_writer_action_type = LinkActionType::SendDone;
      }
    }
    if (scenario == "partial-prefix") {
      const auto hb = make_heartbeat();
      check(ground_ingress.admit_validated_frame(hb) == FrameIngressStatus::Queued,
            "setup existing ordinary frame");
      std::array<std::uint8_t,32U> prefix{};
      check(ground_ingress.peek(prefix.data(),prefix.size()) == hb.size &&
                ground_ingress.complete_send(TxResult::Accepted,1U),
            "setup an immutable partially committed standard frame");
    }
    if (scenario == "occupied-proxy")
      (void)ground_parameter_proxy.on_gcs_frame(first,12400U);
    if (scenario == "queue-full") {
      const auto filler=make_heartbeat();
      while(ground_ingress.free_bytes() >= filler.size)
        check(ground_ingress.admit_validated_frame(filler) == FrameIngressStatus::Queued,
              "fill actual normal ingress without overflow before fallback");
      check(ground_ingress.free_bytes() < first.size && !ground_ingress.fail_closed(),
            "full ingress cannot fit original request but was healthy before fallback");
    }
    if (scenario == "late-fresh") {
      at(12852U);
      (void)r19_ground_adapter->on_fresh_grant(640U,2U,12852U);
    }
    if (scenario == "unknown-error")
      (void)r19_ground_adapter->tick(12350U);

    if (scenario == "negotiation-success") {
      at(12400U);
      r19_observe_ground_grant(grant(2U),ControlDisposition::Accepted,12400U);
      check(bridge_ready && !runtime_fail_closed && r19_standard_tdd_frozen &&
                !r19_ground_adapter->fail_closed() && !r19_acceleration_consumed &&
                ground_parameter_proxy.diagnostics().native_list_requests_leased == 0U,
            "accepted fresh Grant keeps negotiation path instead of fallback");
    } else {
      const auto prior_frames = ground_ingress.queued_frames();
      if (scenario == "success" || scenario == "duplicate" ||
          scenario == "standard-writer" || scenario == "boundary500") {
        service(12851U);
        check(bridge_ready && !runtime_fail_closed &&
                  !r19_acceleration_consumed && ground_ingress.queued_frames() == prior_frames,
              "inclusive500ms boundary neither fails nor falls back early");
      }
      if (scenario != "boundary500") {
        if (scenario == "epoch-during-admission")
          Serial.simulate_tx_loss_after_epoch_sample(1U);
        service(12852U);
        const bool safe = scenario == "success" || scenario == "duplicate" ||
                          scenario == "standard-writer";
        if (safe) {
          assert_exact_fallback(first,usb_before,radio_before);
          check(ground_usb_observed_loss_epoch == initial_epoch &&
                    Serial.txLossEpoch() == initial_epoch,
                "original held epoch was not silently rebound");
          if (scenario == "standard-writer") {
            const auto actual = e220_writer_arbiter.active_lease();
            check(e220_writer_arbiter.write_active() &&
                      actual.owner == existing.owner &&
                      actual.action_token == existing.action_token &&
                      actual.writer_generation == existing.writer_generation,
                  "fallback does not reset or steal an existing standard writer lease");
          } else {
            check(e220_writer_arbiter.can_poll_standard() &&
                      !e220_writer_arbiter.high_speed_active(),
                  "idle standard writer remains owned by unchanged standard path");
          }
          service(12853U);
          collect_local_ingress(monotonic_now_ms());
          check(ground_ingress.queued_frames() == 1U &&
                    ground_parameter_proxy.diagnostics().native_list_requests_leased == 1U,
                "repeated service cannot enqueue fallback twice");
          submit(first,12854U);
          check(ground_ingress.queued_frames() == 1U &&
                    ground_parameter_proxy.diagnostics().native_list_requests_leased == 1U &&
                    ground_parameter_proxy.diagnostics().list_requests_coalesced == 1U,
                "later same-target duplicate uses normal proxy coalescing, not second send");
          at(14233U);
          r19_observe_ground_grant(grant(2U),ControlDisposition::Accepted,14233U);
          check(bridge_ready && !runtime_fail_closed &&
                    r19_ground_adapter->fail_closed() && !r19_product_route_selected &&
                    r19_acceleration_consumed,
                "later Grant cannot reactivate failed accelerated adapter");
          publish_primary_heartbeat_after_fallback(usb_before);
          primary_published = true;
        } else {
          if (scenario == "epoch-during-admission") {
            check(Serial.epoch_sample_loss_triggered() &&
                      Serial.txLossEpoch() == initial_epoch+1U,
                  "epoch changes immediately after helper entry samples old epoch");
            check(runtime_fail_closed && !bridge_ready && !r19_acceleration_consumed,
                  "epoch change during fallback admission cannot be committed as success");
            check(r19_held_parameter_request_origin_ms == 12351U &&
                      r19_held_parameter_request_loss_epoch == initial_epoch &&
                      r19_ground_adapter->first_failure_diagnostics().request_origin_ms == 12351U,
                  "asynchronous epoch loss cannot rebind original request time or epoch");
            check(ground_ingress.queued_frames() <= 1U &&
                      ground_parameter_proxy.diagnostics().native_list_requests_leased <= 1U &&
                      ground_ingress.stats().bytes_committed == 0U &&
                      Serial.tx_bytes().size() == usb_before &&
                      e220_serial.normal_tx_bytes().size() == radio_before,
                  "late loss stops before physical write, without retry or retraction claim");
          } else if (scenario == "occupied-proxy" || scenario == "queue-full") {
            check(runtime_fail_closed && !bridge_ready && !r19_acceleration_consumed &&
                      ground_ingress.queued_frames() == prior_frames,
                  "failed proxy/queue admission is not misreported as successful fallback");
          } else {
            assert_refused(prior_frames,usb_before,radio_before);
          }
        }
      }
    }
  }
  check(Serial.tx_bytes().size() == usb_before+(primary_published?21U:0U),
        "test path emits no private/control/debug bytes to product USB");
  std::cout << "R19_PRENEGOTIATION_FALLBACK scenario=" << scenario
            << " checks=" << checks << " failures=" << failures
            << " runtime_fail_closed=" << runtime_fail_closed
            << " native_leases=" << ground_parameter_proxy.diagnostics().native_list_requests_leased
            << " queued_frames=" << ground_ingress.queued_frames() << '\n';
  return failures ? 1 : 0;
}
