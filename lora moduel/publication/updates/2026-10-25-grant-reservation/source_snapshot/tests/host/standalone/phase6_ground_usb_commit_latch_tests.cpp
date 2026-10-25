#include "fake_arduino_test_api.hpp"
#include "esp_timer.h"

#include <cstdint>
#include <iostream>
#include <string>

namespace commit_clock {
std::string mode{};
bool armed{false};
std::size_t reads{0U};
}
void r19_commit_test_post_flush_disconnect() noexcept;
std::int64_t r19_commit_test_time() noexcept {
  // Argument clock, observation clock, then flush start precede completion.
  if (commit_clock::armed && commit_clock::reads++ == 3U) {
    if (commit_clock::mode == "endpoint") Serial.set_endpoint_ready(false);
    if (commit_clock::mode == "late") fake_arduino::advance_time_ms(107U);
    if (commit_clock::mode == "postflush_retired")
      r19_commit_test_post_flush_disconnect();
  }
  return static_cast<std::int64_t>(fake_arduino::now_us);
}
#define esp_timer_get_time r19_commit_test_time
#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"
#undef esp_timer_get_time

void r19_commit_test_post_flush_disconnect() noexcept {
  using namespace vc_lora_phase6_firmware;
  // Deterministically make the production post-flush connection refresh
  // confirm a low-host observation. The flush has already returned true;
  // the retirement record must not mislabel that known result as unobserved.
  const auto now_ms = fake_arduino::now_us / 1000U;
  (void)ground_usb_host_presence_filter.observe(
      false, now_ms - kGroundUsbHostLossConfirmMs - 1U);
  Serial.set_plugged(false);
  Serial.set_endpoint_ready(false);
}

int main(int argc, char** argv) {
  using namespace vc_lora_phase6_firmware;
  using namespace vc_lora::experimental;
  commit_clock::mode = argc > 1 ? argv[1] : "transport";
  std::size_t checks = 0U;
  std::size_t failures = 0U;
  const auto check = [&](bool passed, const char* message) {
    ++checks;
    if (!passed) { ++failures; std::cerr << "FAIL: " << message << '\n'; }
  };
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  setup_bridge();
  check(bridge_ready && !runtime_fail_closed, "Ground setup failed");
  vc_lora::MavlinkFrame frame{};
  constexpr std::uint8_t payload[9U]{0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U};
  check(vc_lora::encode_mavlink_v2(0x72U, 1U, 1U, 0U, payload, 9U, frame),
        "heartbeat encoding failed");
  check(frame.size == 21U, "fixture must retain the physical 21-byte frame");
  const auto started_ms = monotonic_now_ms();
  check(ground_usb_heartbeat_pacer.ingest(frame, started_ms) ==
            vc_lora::GroundUsbHeartbeatIngestStatus::Held,
        "heartbeat ingest failed");
  vc_lora::GroundUsbHeartbeatLease lease{};
  check(ground_usb_heartbeat_pacer.select_before_next_frame(started_ms, lease) ==
            vc_lora::GroundUsbHeartbeatBarrierStatus::LeaseReady &&
            admit_ground_paced_heartbeat(lease, started_ms),
        "heartbeat lease admission failed");
  pump_ground_usb_egress(started_ms);
  check(Serial.tx_bytes().size() == 21U &&
            radio_application_endpoint.egress().stats().bytes_committed == 21U,
        "accepted-byte boundary not reached");
  const auto expected_epoch = Serial.txLossEpoch();
  const auto deadline_ms = ground_paced_heartbeat_commit_deadline_ms;
  if (commit_clock::mode == "transport") Serial.set_flush_failures(1U);
  if (commit_clock::mode == "deadline")
    fake_arduino::advance_time_ms(kGroundUsbHeartbeatCommitDeadlineMs);
  commit_clock::armed = true;
  if (commit_clock::mode == "retired") {
    reject_ground_paced_heartbeat_commit(monotonic_now_ms());
  } else {
    observe_ground_paced_heartbeat_commit(monotonic_now_ms());
  }
  commit_clock::armed = false;
  R19GroundUsbCommitSnapshot snapshot{};
  check(vc_lora_r19_ground_usb_commit_record.try_snapshot(snapshot) &&
            snapshot.valid_header(), "dedicated Ground record unavailable");
  if (commit_clock::mode == "success") {
    check(!snapshot.failure_latched() && !runtime_fail_closed &&
              ground_usb_heartbeat_pacer.diagnostics().emitted_heartbeats == 1U,
          "successful commit generated failure evidence or changed completion");
  } else {
    check(snapshot.failure_latched() && snapshot.token == lease.token &&
              snapshot.expected_epoch == expected_epoch &&
              snapshot.observed_epoch == expected_epoch &&
              snapshot.commit_started_ms == started_ms &&
              snapshot.deadline_ms == deadline_ms &&
              snapshot.committed_base == 0U && snapshot.commit_goal == 21U &&
              snapshot.bytes_committed == 21U &&
              snapshot.expected_frame_bytes == 21U &&
              snapshot.accepted_frame_bytes == 21U && snapshot.source_line != 0U,
          "failed commit did not preserve original clocks, token, epoch, and bytes");
    if (commit_clock::mode == "transport")
      check(snapshot.reason == R19GroundUsbCommitFailureReason::PublicationRejected &&
                snapshot.predicate_observed_mask == 7U &&
                snapshot.predicate_true_mask == 6U,
            "flush failure was not separated from ready/deadline success");
    if (commit_clock::mode == "endpoint")
      check(snapshot.reason == R19GroundUsbCommitFailureReason::PublicationRejected &&
                snapshot.predicate_observed_mask == 7U &&
                snapshot.predicate_true_mask == 5U,
            "post-flush endpoint failure was not separated from USB success");
    if (commit_clock::mode == "late")
      check(snapshot.reason == R19GroundUsbCommitFailureReason::PublicationRejected &&
                snapshot.predicate_observed_mask == 7U &&
                snapshot.predicate_true_mask == 2U &&
                snapshot.completed_ms > snapshot.deadline_ms,
            "late USB result was not separated from endpoint state");
    if (commit_clock::mode == "deadline")
      check(snapshot.reason == R19GroundUsbCommitFailureReason::BeforeFlushDeadline &&
                snapshot.predicate_observed_mask == 6U &&
                snapshot.predicate_true_mask == 6U && Serial.flush_count() == 0U,
            "pre-flush deadline falsely claimed transport was observed");
    if (commit_clock::mode == "retired")
      check(snapshot.reason == R19GroundUsbCommitFailureReason::Retired &&
                snapshot.predicate_observed_mask == 6U,
            "retirement was not distinguished from flush result");
    if (commit_clock::mode == "postflush_retired")
      check(snapshot.reason == R19GroundUsbCommitFailureReason::Retired &&
                snapshot.predicate_observed_mask == 7U &&
                snapshot.predicate_true_mask == 5U &&
                snapshot.flush_started_ms >= snapshot.commit_started_ms &&
                Serial.flush_count() == 1U,
            "post-flush retirement lost the already observed successful USB result");
    const auto first = snapshot;
    latch_runtime_fail_closed_at(0xCDEFU);
    loop_bridge();
    check(vc_lora_r19_ground_usb_commit_record.try_snapshot(snapshot) &&
              snapshot.sequence == first.sequence &&
              snapshot.source_line == first.source_line &&
              snapshot.predicate_true_mask == first.predicate_true_mask &&
              snapshot.completed_ms == first.completed_ms,
          "later runtime diagnostic replaced first product failure evidence");
  }
  std::cout << "IT-R19-GROUND-USB-COMMIT-LATCH-001 " << commit_clock::mode
            << " checks=" << checks << " failures=" << failures << '\n';
  return failures == 0U ? 0 : 1;
}
