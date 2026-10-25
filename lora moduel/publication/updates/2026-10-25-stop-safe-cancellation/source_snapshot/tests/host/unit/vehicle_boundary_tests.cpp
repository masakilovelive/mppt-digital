#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/mavlink_scheduler.hpp"
#include "vc_lora/tdd_link_demux.hpp"
#include "vc_lora/tdd_vehicle.hpp"

namespace vc_lora::test {
namespace {

TddInput vehicle_input(std::uint64_t now_ms, bool local_tx_empty,
                       std::uint32_t queued_bytes,
                       bool radio_tx_empty = true) noexcept {
  TddInput input{};
  input.now_ms = now_ms;
  input.aux_high = true;
  input.radio_tx_empty = radio_tx_empty;
  input.local_tx_empty = local_tx_empty;
  input.queued_bytes = queued_bytes;
  return input;
}

TddInput heartbeat_tail_input(std::uint64_t now_ms, bool local_tx_empty,
                              std::uint32_t queued_bytes,
                              bool heartbeat_tail_available,
                              bool radio_tx_empty = true) noexcept {
  TddInput input =
      vehicle_input(now_ms, local_tx_empty, queued_bytes, radio_tx_empty);
  input.heartbeat_tail_enabled = true;
  input.heartbeat_tail_available = heartbeat_tail_available;
  return input;
}

TddInput scheduler_tail_input(std::uint64_t now_ms,
                              const MavlinkFrameScheduler& scheduler,
                              bool radio_tx_empty = true,
                              bool aux_high = true) noexcept {
  TddInput input = vehicle_input(
      now_ms, !scheduler.has_active_frame(),
      static_cast<std::uint32_t>(scheduler.queued_bytes()), radio_tx_empty);
  input.aux_high = aux_high;
  input.heartbeat_tail_enabled = scheduler.has_seen_heartbeat();
  input.heartbeat_tail_available = scheduler.has_pending_heartbeat();
  input.heartbeat_tail_active = scheduler.active_frame_is_heartbeat();
  input.heartbeat_tail_active_started =
      scheduler.active_frame_has_progress();
  return input;
}

constexpr std::uint64_t kFnv1a64Offset = 14'695'981'039'346'656'037ULL;
constexpr std::uint64_t kFnv1a64Prime = 1'099'511'628'211ULL;

std::uint64_t hash_bytes(const std::uint8_t* bytes,
                         std::size_t size) noexcept {
  std::uint64_t hash = kFnv1a64Offset;
  for (std::size_t index = 0U; index < size; ++index) {
    hash ^= bytes[index];
    hash *= kFnv1a64Prime;
  }
  return hash;
}

}  // namespace

TestReport run_vehicle_boundary_test(const std::string& test_id,
                                     std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  TddConfig config{};
  LinkDiagnostics diagnostics{};
  VehicleTddController controller{config, diagnostics};
  controller.reset(0x4102U, 7U, 0U);

  // Establish AUX=HIGH before exercising the production 3000 ms boundary.
  (void)controller.tick(vehicle_input(0U, true, 0U));
  (void)controller.tick(vehicle_input(config.aux_stable_ms, true, 0U));

  if (test_id == "UT-MAV-BOUNDARY-001") {
    const LinkAction first = controller.tick(
        vehicle_input(config.downlink_send_ms, false, 45U));
    report.check(controller.state() == VehicleTddState::DownlinkSend,
                 "deadline cut an active local frame and entered drain");
    report.check(first.type == LinkActionType::SendRadioData,
                 "active local frame could not continue at the deadline");
    report.check(first.byte_budget == config.radio_chunk_bytes,
                 "first continuation did not preserve the 32-byte limit");

    if (first.type == LinkActionType::SendRadioData) {
      controller.complete_action(first.token, TxResult::Accepted,
                                 config.downlink_send_ms);
    }
    const std::uint64_t continuation_ms =
        config.downlink_send_ms + config.min_tx_gap_ms;
    const LinkAction tail =
        controller.tick(vehicle_input(continuation_ms, false, 13U));
    report.check(controller.state() == VehicleTddState::DownlinkSend,
                 "controller left send state before the active frame tail");
    report.check(tail.type == LinkActionType::SendRadioData &&
                     tail.byte_budget == 13U,
                 "active frame tail was not offered after the deadline");
  } else if (test_id == "UT-MAV-BOUNDARY-002") {
    const LinkAction active = controller.tick(
        vehicle_input(config.downlink_send_ms, false, 13U));
    report.check(active.type == LinkActionType::SendRadioData,
                 "active frame tail was not offered at the deadline");
    if (active.type == LinkActionType::SendRadioData) {
      controller.complete_action(active.token, TxResult::Accepted,
                                 config.downlink_send_ms);
    }

    // queued_bytes now describes a following frame. local_tx_empty=true is
    // the only permission to close this cycle; the following frame must not
    // start after the deadline.
    const LinkAction after_frame = controller.tick(vehicle_input(
        config.downlink_send_ms + 1U, true, 32U, false));
    report.check(after_frame.type == LinkActionType::None,
                 "a new local frame started after the deadline");
    report.check(controller.state() == VehicleTddState::DownlinkDrain,
                 "completed local frame did not enter radio drain");

    const LinkAction still_draining = controller.tick(vehicle_input(
        config.downlink_send_ms + config.min_tx_gap_ms - 1U, true, 32U,
        true));
    report.check(still_draining.type == LinkActionType::None &&
                     controller.state() == VehicleTddState::DownlinkDrain,
                 "radio drain bypassed the minimum TX gap");

    (void)controller.tick(vehicle_input(
        config.downlink_send_ms + config.min_tx_gap_ms, true, 32U, true));
    report.check(controller.state() == VehicleTddState::SendUlGrant,
                 "radio drain did not finish after AUX/radio/gap conditions");
  } else if (test_id == "UT-MAV-BOUNDARY-003") {
    // A normal frame may remain queued while the MAVLink-aware adapter waits
    // for a heartbeat. heartbeat_tail_available=false is authoritative: the
    // controller must not mistake the normal frame for the optional tail.
    for (std::uint64_t offset_ms = 0U;
         offset_ms <= config.heartbeat_tail_wait_ms; ++offset_ms) {
      const LinkAction waiting = controller.tick(heartbeat_tail_input(
          config.downlink_send_ms + offset_ms, true, 32U, false));
      report.check(waiting.type != LinkActionType::SendRadioData,
                   "normal frame was sent as the heartbeat tail");
      if (offset_ms < config.heartbeat_tail_wait_ms) {
        report.check(controller.state() == VehicleTddState::DownlinkSend,
                     "heartbeat tail wait ended before its fixed timeout");
      }
    }

    report.check(controller.state() == VehicleTddState::DownlinkDrain,
                 "missing heartbeat did not enter bounded downlink drain");
    const std::uint64_t timeout_ms =
        config.downlink_send_ms + config.heartbeat_tail_wait_ms;
    const LinkAction drained = controller.tick(
        heartbeat_tail_input(timeout_ms + 1U, true, 32U, false));
    report.check(drained.type == LinkActionType::None &&
                     controller.state() == VehicleTddState::SendUlGrant,
                 "bounded heartbeat timeout did not advance to grant state");
    const LinkAction grant = controller.tick(
        heartbeat_tail_input(timeout_ms + 2U, true, 32U, false));
    report.check(grant.type == LinkActionType::SendGrant &&
                     grant.control.type == ControlType::UlGrant,
                 "bounded heartbeat timeout did not issue UL_GRANT");
    report.check(diagnostics.downlink_transactions == 0U &&
                     diagnostics.downlink_payload_bytes == 0U,
                 "normal queued bytes were counted as a heartbeat tail");
  } else if (test_id == "UT-MAV-BOUNDARY-004") {
    // Start with only a normal frame queued, then expose one complete 21-byte
    // MAVLink v2 heartbeat exactly at the inclusive wait endpoint.
    const LinkAction normal_wait = controller.tick(heartbeat_tail_input(
        config.downlink_send_ms, true, 32U, false));
    report.check(normal_wait.type == LinkActionType::None,
                 "normal frame was sent before heartbeat became available");

    const std::uint64_t endpoint_ms =
        config.downlink_send_ms + config.heartbeat_tail_wait_ms;
    const LinkAction heartbeat = controller.tick(
        heartbeat_tail_input(endpoint_ms, true, 21U, true));
    report.check(heartbeat.type == LinkActionType::SendRadioData &&
                     heartbeat.byte_budget == 21U,
                 "one complete heartbeat was not selected at wait endpoint");
    if (heartbeat.type == LinkActionType::SendRadioData) {
      controller.complete_action(heartbeat.token, TxResult::Accepted,
                                 endpoint_ms, 21U);
    }

    // The next queued frame is normal data. A completed heartbeat tail closes
    // admission immediately, so this frame must remain unsent.
    const LinkAction after_heartbeat = controller.tick(heartbeat_tail_input(
        endpoint_ms + 1U, true, 32U, false, false));
    report.check(after_heartbeat.type == LinkActionType::None &&
                     controller.state() == VehicleTddState::DownlinkDrain,
                 "second frame started after the one-heartbeat tail");

    const LinkAction before_gap = controller.tick(heartbeat_tail_input(
        endpoint_ms + config.min_tx_gap_ms - 1U, true, 32U, false));
    report.check(before_gap.type == LinkActionType::None &&
                     controller.state() == VehicleTddState::DownlinkDrain,
                 "heartbeat tail drain bypassed the minimum TX gap");
    const LinkAction drained = controller.tick(heartbeat_tail_input(
        endpoint_ms + config.min_tx_gap_ms, true, 32U, false));
    report.check(drained.type == LinkActionType::None &&
                     controller.state() == VehicleTddState::SendUlGrant,
                 "heartbeat tail did not advance from drain to grant state");
    const LinkAction grant = controller.tick(heartbeat_tail_input(
        endpoint_ms + config.min_tx_gap_ms + 1U, true, 32U, false));
    report.check(grant.type == LinkActionType::SendGrant &&
                     grant.control.type == ControlType::UlGrant,
                 "heartbeat tail did not issue UL_GRANT");
    report.check(diagnostics.downlink_transactions == 1U &&
                     diagnostics.downlink_payload_bytes == 21U,
                 "heartbeat tail did not send exactly one real frame");
  } else if (test_id == "UT-MAV-BOUNDARY-005") {
    // Selecting the heartbeat and physically writing it are separate events.
    // Latch availability at the nominal boundary while the UART is busy.
    const LinkAction selected = controller.tick(heartbeat_tail_input(
        config.downlink_send_ms, true, 21U, true, false));
    report.check(selected.type == LinkActionType::None &&
                     controller.state() == VehicleTddState::DownlinkSend,
                 "busy endpoint did not latch heartbeat selection");

    // The real scheduler continues to report the selected heartbeat while it
    // is queued. At the inclusive timeout it must keep waiting while busy.
    const std::uint64_t endpoint_ms =
        config.downlink_send_ms + config.heartbeat_tail_wait_ms;
    const LinkAction endpoint_busy = controller.tick(heartbeat_tail_input(
        endpoint_ms, true, 21U, true, false));
    report.check(endpoint_busy.type == LinkActionType::None &&
                     controller.state() == VehicleTddState::DownlinkSend,
                 "latched heartbeat timed out while UART remained busy");

    // Readiness may arrive after the selection window.  The selected real
    // heartbeat, and only that frame, must then be offered in full.
    const LinkAction ready = controller.tick(heartbeat_tail_input(
        endpoint_ms + 100U, true, 21U, true, true));
    report.check(ready.type == LinkActionType::SendRadioData &&
                     ready.byte_budget == 21U &&
                     controller.state() == VehicleTddState::DownlinkSend,
                 "latched heartbeat was not sent when UART became ready");
    report.check(diagnostics.action_retries == 0U,
                 "endpoint-busy latch caused an unexpected action retry");
  } else if (test_id == "UT-MAV-BOUNDARY-006") {
    const LinkAction selected = controller.tick(heartbeat_tail_input(
        config.downlink_send_ms, true, 21U, true, false));
    report.check(selected.type == LinkActionType::None &&
                     controller.state() == VehicleTddState::DownlinkSend,
                 "busy endpoint did not select the heartbeat");

    // The selected heartbeat disappeared from the scheduler and only a
    // normal 32-byte frame remains. It must never inherit tail permission.
    const std::uint64_t endpoint_ms =
        config.downlink_send_ms + config.heartbeat_tail_wait_ms;
    const LinkAction disappeared = controller.tick(heartbeat_tail_input(
        endpoint_ms, true, 32U, false, true));
    report.check(disappeared.type == LinkActionType::None,
                 "normal frame was sent after selected heartbeat vanished");
    report.check(controller.state() == VehicleTddState::DownlinkDrain,
                 "vanished heartbeat did not close the bounded tail wait");
    report.check(diagnostics.downlink_transactions == 0U &&
                     diagnostics.downlink_payload_bytes == 0U,
                 "vanished heartbeat path counted normal bytes as tail data");
  } else if (test_id == "UT-MAV-BOUNDARY-007") {
    std::array<std::uint8_t, 9> heartbeat_payload{};
    heartbeat_payload[0] = 0x56U;
    heartbeat_payload[1] = 0x7DU;
    heartbeat_payload[4] = 2U;
    heartbeat_payload[5] = 3U;
    heartbeat_payload[7] = 4U;
    heartbeat_payload[8] = 3U;
    std::array<std::uint8_t, kMavlinkSignatureBytes> signature{};
    for (std::size_t index = 0U; index < signature.size(); ++index) {
      signature[index] = static_cast<std::uint8_t>(index + 1U);
    }
    signature[0] = 0x56U;
    signature[1] = 0x7DU;
    MavlinkFrame heartbeat{};
    report.check(encode_mavlink_v2(
                     0x5AU, 1U, 1U, 0U, heartbeat_payload.data(),
                     heartbeat_payload.size(), heartbeat, 0x01U, 0U,
                     signature.data()),
                 "signed adversarial heartbeat encoding failed");
    report.check(heartbeat.size == 34U && heartbeat.signed_frame,
                 "signed MAVLink 2 heartbeat was not exactly 34 bytes");
    report.check(heartbeat.payload()[0] == 0x56U &&
                     heartbeat.payload()[1] == 0x7DU &&
                     heartbeat.bytes[heartbeat.size -
                                     kMavlinkSignatureBytes] == 0x56U &&
                     heartbeat.bytes[heartbeat.size -
                                     kMavlinkSignatureBytes + 1U] == 0x7DU,
                 "signed heartbeat lacks adversarial VCTD/escape bytes");

    std::array<std::uint8_t, 20> ordinary_payload{};
    ordinary_payload[0] = 1U;
    ordinary_payload[1] = 1U;
    MavlinkFrame ordinary{};
    report.check(encode_mavlink_v2(0x5BU, 255U, 190U, 20U,
                                   ordinary_payload.data(),
                                   ordinary_payload.size(), ordinary),
                 "ordinary frame fixture encoding failed");

    MavlinkFrameScheduler scheduler{};
    report.check(scheduler.enqueue(ordinary) == MavlinkEnqueueStatus::Queued &&
                     scheduler.enqueue(heartbeat) ==
                         MavlinkEnqueueStatus::Queued,
                 "signed heartbeat/normal scheduler enqueue failed");

    const LinkAction first = controller.tick(scheduler_tail_input(
        config.downlink_send_ms, scheduler));
    report.check(first.type == LinkActionType::SendRadioData &&
                     first.byte_budget == config.radio_chunk_bytes,
                 "selected signed heartbeat did not issue its first prefix");
    std::array<std::uint8_t, kLinkDataMaxWireBytes> first_application{};
    const std::size_t first_available = scheduler.peek(
        first_application.data(),
        std::min<std::size_t>(first.byte_budget, first_application.size()));
    const EncodedLinkDataChunk rejected_wire = encode_link_data(
        first_application.data(), first_available);
    report.check(rejected_wire.input_consumed > 0U &&
                     rejected_wire.wire_size <= kLinkDataMaxWireBytes,
                 "first signed heartbeat prefix could not be escaped");
    report.check(scheduler.complete_send(TxResult::Rejected,
                                         rejected_wire.input_consumed),
                 "scheduler rejected the rejected-prefix completion");
    controller.complete_action(first.token, TxResult::Rejected,
                               config.downlink_send_ms);

    const LinkAction not_ready = controller.tick(scheduler_tail_input(
        config.downlink_send_ms + config.min_tx_gap_ms - 1U, scheduler,
        false));
    report.check(not_ready.type == LinkActionType::None,
                 "rejected heartbeat retried before readiness/gap boundary");
    const std::uint64_t first_write_ms =
        config.downlink_send_ms + config.min_tx_gap_ms;
    const LinkAction retry =
        controller.tick(scheduler_tail_input(first_write_ms, scheduler));
    report.check(retry.type == LinkActionType::SendRadioData,
                 "rejected signed heartbeat was not reissued");
    std::array<std::uint8_t, kLinkDataMaxWireBytes> retry_application{};
    const std::size_t retry_available = scheduler.peek(
        retry_application.data(),
        std::min<std::size_t>(retry.byte_budget, retry_application.size()));
    const EncodedLinkDataChunk first_wire =
        encode_link_data(retry_application.data(), retry_available);
    report.check(first_available == retry_available &&
                     rejected_wire.input_consumed ==
                         first_wire.input_consumed &&
                     rejected_wire.wire_size == first_wire.wire_size &&
                     std::memcmp(rejected_wire.wire_bytes.data(),
                                 first_wire.wire_bytes.data(),
                                 first_wire.wire_size) == 0,
                 "rejected heartbeat retry changed the exact escaped prefix");
    report.check(scheduler.complete_send(TxResult::Accepted,
                                         first_wire.input_consumed),
                 "accepted first heartbeat prefix was not consumed");
    controller.complete_action(
        retry.token, TxResult::Accepted, first_write_ms,
        static_cast<std::uint16_t>(first_wire.input_consumed));

    const LinkAction before_gap = controller.tick(scheduler_tail_input(
        first_write_ms + config.min_tx_gap_ms - 1U, scheduler));
    report.check(before_gap.type == LinkActionType::None,
                 "signed heartbeat remainder bypassed the fixed TX gap");
    const std::uint64_t second_write_ms =
        first_write_ms + config.min_tx_gap_ms;
    const LinkAction remainder =
        controller.tick(scheduler_tail_input(second_write_ms, scheduler));
    report.check(remainder.type == LinkActionType::SendRadioData,
                 "signed heartbeat remainder was not issued");
    std::array<std::uint8_t, kLinkDataMaxWireBytes> remainder_application{};
    const std::size_t remainder_available = scheduler.peek(
        remainder_application.data(),
        std::min<std::size_t>(remainder.byte_budget,
                              remainder_application.size()));
    const EncodedLinkDataChunk second_wire =
        encode_link_data(remainder_application.data(), remainder_available);
    report.check(second_wire.input_consumed > 0U &&
                     second_wire.wire_size <= kLinkDataMaxWireBytes,
                 "signed heartbeat remainder exceeded the 32-byte wire cap");
    report.check(scheduler.complete_send(TxResult::Accepted,
                                         second_wire.input_consumed),
                 "accepted heartbeat remainder was not consumed");
    controller.complete_action(
        remainder.token, TxResult::Accepted, second_write_ms,
        static_cast<std::uint16_t>(second_wire.input_consumed));

    TddLinkDemux demux{true};
    MavlinkStreamParser parser{};
    MavlinkFrame decoded{};
    std::array<std::uint8_t, kMavlinkMaxFrameBytes> delivered{};
    std::size_t delivered_size = 0U;
    std::size_t decoded_frames = 0U;
    const std::array<EncodedLinkDataChunk, 2> writes{{first_wire,
                                                      second_wire}};
    for (std::size_t write_index = 0U; write_index < writes.size();
         ++write_index) {
      for (std::size_t wire_index = 0U;
           wire_index < writes[write_index].wire_size; ++wire_index) {
        const TddDemuxEvent event =
            demux.push(writes[write_index].wire_bytes[wire_index]);
        report.check(!event.has_control,
                     "escaped signed heartbeat decoded as VCTD control");
        for (std::size_t local = 0U; local < event.local_size; ++local) {
          if (delivered_size < delivered.size()) {
            delivered[delivered_size++] = event.local_bytes[local];
          }
          if (parser.push(event.local_bytes[local], decoded) ==
              MavlinkParseStatus::FrameReady) {
            ++decoded_frames;
          }
        }
      }
      if (write_index == 0U) {
        report.check(decoded_frames == 0U && parser.buffered_size() > 0U,
                     "partial signed heartbeat was exposed as a frame");
      }
    }

    report.check(writes.size() == 2U &&
                     first_wire.wire_size <= 32U &&
                     second_wire.wire_size <= 32U &&
                     first_wire.wire_size + second_wire.wire_size >
                         heartbeat.size,
                 "signed heartbeat was not escaped into two bounded writes");
    report.check(second_write_ms - first_write_ms >= config.min_tx_gap_ms,
                 "accepted signed heartbeat writes violated the 180 ms gap");
    report.check(first_wire.input_consumed + second_wire.input_consumed ==
                     heartbeat.size &&
                     delivered_size == heartbeat.size &&
                     std::memcmp(delivered.data(), heartbeat.bytes.data(),
                                 heartbeat.size) == 0 &&
                     hash_bytes(delivered.data(), delivered_size) ==
                         hash_bytes(heartbeat.bytes.data(), heartbeat.size),
                 "signed heartbeat exact bytes/hash changed across retry");
    report.check(decoded_frames == 1U && decoded.signed_frame &&
                     decoded.size == heartbeat.size,
                 "signed heartbeat did not decode exactly once after remainder");

    const LinkAction after_heartbeat = controller.tick(
        scheduler_tail_input(second_write_ms + 1U, scheduler));
    report.check(after_heartbeat.type == LinkActionType::None &&
                     controller.state() == VehicleTddState::DownlinkDrain,
                 "normal frame was sent after retried heartbeat completed");
    report.check(scheduler.size() == 1U &&
                     scheduler.queued_bytes() == ordinary.size &&
                     scheduler.diagnostics().rejected_send_attempts == 1U &&
                     scheduler.diagnostics().frames_forwarded == 1U &&
                     scheduler.diagnostics().bytes_forwarded == heartbeat.size,
                 "retry duplicated heartbeat or consumed the normal frame");
    report.check(diagnostics.downlink_transactions == 2U &&
                     diagnostics.downlink_payload_bytes == heartbeat.size &&
                     diagnostics.action_retries == 1U &&
                     diagnostics.partial_mavlink_delivered == 0U,
                 "signed heartbeat retry accounting was not exact");
  } else if (test_id == "UT-MAV-BOUNDARY-008") {
    TddInput low_endpoint = heartbeat_tail_input(
        config.downlink_send_ms, true, 21U, true, true);
    low_endpoint.aux_high = false;
    const LinkAction selected = controller.tick(low_endpoint);
    report.check(selected.type == LinkActionType::None &&
                     controller.state() == VehicleTddState::DownlinkSend,
                 "AUX-low endpoint did not retain selected heartbeat");

    const std::uint64_t endpoint_ms =
        config.downlink_send_ms + config.heartbeat_tail_wait_ms;
    TddInput still_low =
        heartbeat_tail_input(endpoint_ms, true, 21U, true, true);
    still_low.aux_high = false;
    const LinkAction held = controller.tick(still_low);
    report.check(held.type == LinkActionType::None &&
                     controller.state() == VehicleTddState::DownlinkSend,
                 "selected heartbeat was lost while AUX stayed low");

    const std::uint64_t high_started_ms = endpoint_ms + 1U;
    const LinkAction high_edge = controller.tick(heartbeat_tail_input(
        high_started_ms, true, 21U, true, true));
    const LinkAction before_stable = controller.tick(heartbeat_tail_input(
        high_started_ms + config.aux_stable_ms - 1U, true, 21U, true,
        true));
    report.check(high_edge.type == LinkActionType::None &&
                     before_stable.type == LinkActionType::None,
                 "AUX-low heartbeat sent before 15 ms stability");
    const LinkAction stable = controller.tick(heartbeat_tail_input(
        high_started_ms + config.aux_stable_ms, true, 21U, true, true));
    report.check(stable.type == LinkActionType::SendRadioData &&
                     stable.byte_budget == 21U,
                 "selected heartbeat was not sent after AUX stabilized");
    report.check(diagnostics.action_retries == 0U,
                  "AUX stability wait caused an unexpected action retry");
  } else {
    report.check(false, "unknown vehicle boundary test ID");
  }

  report.diagnostics = diagnostics;
  report.final_vehicle_state = vehicle_state_name(controller.state());
  report.vehicle_session = controller.session_id();
  report.vehicle_cycle = controller.cycle_id();
  report.trace.record({config.downlink_send_ms, "vehicle",
                       report.final_vehicle_state, controller.cycle_id(),
                       report.passed ? "PASS" : "FAIL", true, 0, 0, 0});
  return report;
}

}  // namespace vc_lora::test
