#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

#include "../../../firmware/high_speed/high_speed_phase6_adapter.hpp"
#include "../../../firmware/high_speed/peer_completion_receipt.hpp"
#include "../../../firmware/high_speed/phase6_bulk_rx_tail_ledger.hpp"
#include "../../../firmware/high_speed/phase6_high_speed_radio_session.hpp"
#include "../../../firmware/high_speed/phase6_high_speed_role_config.hpp"
#include "../../../firmware/high_speed/phase6_radio_writer_arbiter.hpp"
#include "vc_lora/bulk_data_codec.hpp"
#include "vc_lora/bulk_heartbeat_sla.hpp"
#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/bulk_transcript.hpp"
#include "vc_lora/bulk_tx_lease.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/mavlink_scheduler.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_link_demux.hpp"

#include "test_support.hpp"

namespace {

using namespace vc_lora;
using namespace vc_lora::experimental;

struct Checks final {
  bool passed{true};
  std::string first_failure{};

  void expect(bool condition, const char *message) {
    if (!condition && passed) {
      passed = false;
      first_failure = message;
    }
  }
};

constexpr std::uint16_t kGrantSession = 0x4242U;
constexpr std::uint16_t kBaselineCycle = 0x0030U;
constexpr std::uint16_t kFreshCycle = 0x0031U;
constexpr std::uint64_t kUsbEpoch = 19U;
constexpr std::uint64_t kT0Ms = 1'000U;
constexpr std::uint64_t kGrantTailMs = 1'500U;
constexpr std::uint64_t kRequestArrivalMs = 2'000U;
constexpr std::uint64_t kBulkStartMs = 2'204U;
constexpr std::uint32_t kHeartbeatCount = 5U;
constexpr std::uint32_t kExpectedFragmentCount =
    BulkSessionAccounting::parameter_fragment_count + 2U * kHeartbeatCount;

constexpr BootSessionIdentity kGroundBoot{0x10203040U, 0x5060U};
constexpr BootSessionIdentity kVehicleBoot{0x90A0B0C0U, 0x7080U};
constexpr Phase6HighSpeedRoleEntropy kGroundEntropy{0x0102030405060708ULL,
                                                    0x1112131415161718ULL};
constexpr Phase6HighSpeedRoleEntropy kVehicleEntropy{0x2122232425262728ULL,
                                                     0x3132333435363738ULL};

constexpr GroundBulkSessionConfig kGroundConfig =
    make_r19_ground_bulk_session_config(BulkSessionFeature::Enabled,
                                        kGroundBoot, kGroundEntropy);
constexpr VehicleBulkSessionConfig kVehicleConfig =
    make_r19_vehicle_bulk_session_config(BulkSessionFeature::Enabled,
                                         kVehicleBoot, kVehicleEntropy);

static_assert(kGroundConfig.feature == BulkSessionFeature::Enabled);
static_assert(kVehicleConfig.feature == BulkSessionFeature::Enabled);
static_assert(kExpectedFragmentCount == 1'874U);

MavlinkFrame parameter_request_list() {
  constexpr std::array<std::uint8_t, 2U> payload{{1U, 1U}};
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(0x44U, 255U, 190U, 21U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame parameter_value(std::uint16_t index) {
  std::array<std::uint8_t, 25U> payload{};
  payload[0U] = static_cast<std::uint8_t>(index & 0xFFU);
  payload[1U] = static_cast<std::uint8_t>(index >> 8U);
  payload[4U] =
      static_cast<std::uint8_t>(BulkSessionAccounting::parameter_count & 0xFFU);
  payload[5U] = static_cast<std::uint8_t>(
      (BulkSessionAccounting::parameter_count >> 8U) & 0xFFU);
  payload[6U] = static_cast<std::uint8_t>(index & 0xFFU);
  payload[7U] = static_cast<std::uint8_t>(index >> 8U);
  payload[8U] = static_cast<std::uint8_t>('R');
  payload[9U] = static_cast<std::uint8_t>('1');
  payload[10U] = static_cast<std::uint8_t>('9');
  payload[11U] = static_cast<std::uint8_t>('_');
  payload[12U] = static_cast<std::uint8_t>(index & 0xFFU);
  payload[13U] = static_cast<std::uint8_t>(index >> 8U);
  payload[24U] = 9U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(static_cast<std::uint8_t>(index), 1U, 1U, 22U,
                          payload.data(), payload.size(), frame);
  return frame;
}

MavlinkFrame heartbeat(std::uint8_t sequence) {
  constexpr std::array<std::uint8_t, 9U> payload{
      {0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U}};
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 1U, 1U, 0U, payload.data(), payload.size(),
                          frame);
  return frame;
}

std::uint16_t parameter_index(const MavlinkFrame &frame) {
  return static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(frame.payload_byte_or_zero(6U)) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(frame.payload_byte_or_zero(7U)) << 8U));
}

bool same_frame(const HighSpeedPhase6Output &output,
                const MavlinkFrame &frame) {
  return output.size == frame.size &&
         std::equal(output.bytes.begin(), output.bytes.begin() + output.size,
                    frame.bytes.begin());
}

bool route_control(TddLinkDemux &demux, const std::uint8_t *bytes,
                   std::size_t size, TddControlMessage &output) {
  bool found = false;
  for (std::size_t index = 0U; index < size; ++index) {
    const TddDemuxEvent event = demux.push(bytes[index]);
    if (event.local_size != 0U || event.has_bulk_data ||
        event.has_bulk_negotiation || event.has_terminal_ack ||
        event.has_peer_completion_receipt) {
      return false;
    }
    if (event.has_control) {
      if (found || event.control.status != DecodeStatus::Message) {
        return false;
      }
      found = true;
      output = event.control.message;
    }
  }
  return found && demux.buffered_size() == 0U;
}

bool route_negotiation(TddLinkDemux &demux, const std::uint8_t *bytes,
                       std::size_t size, BulkNegotiationFrame &output) {
  bool found = false;
  for (std::size_t index = 0U; index < size; ++index) {
    const TddDemuxEvent event = demux.push(bytes[index]);
    if (event.local_size != 0U || event.has_control || event.has_bulk_data ||
        event.has_terminal_ack || event.has_peer_completion_receipt) {
      return false;
    }
    if (event.has_bulk_negotiation) {
      if (found) {
        return false;
      }
      found = true;
      output = event.bulk_negotiation_record;
    }
  }
  return found && demux.buffered_size() == 0U;
}

bool route_bulk(TddLinkDemux &demux, const std::uint8_t *bytes,
                std::size_t size, BulkDataFragment &output) {
  bool found = false;
  for (std::size_t index = 0U; index < size; ++index) {
    const TddDemuxEvent event = demux.push(bytes[index]);
    if (event.local_size != 0U || event.has_control ||
        event.has_bulk_negotiation || event.has_terminal_ack ||
        event.has_peer_completion_receipt) {
      return false;
    }
    if (event.has_bulk_data) {
      if (found) {
        return false;
      }
      found = true;
      output = event.bulk_data_fragment;
    }
  }
  return found && demux.buffered_size() == 0U;
}

bool route_terminal(TddLinkDemux &demux, const std::uint8_t *bytes,
                    std::size_t size, TerminalAckFragment &output) {
  bool found = false;
  for (std::size_t index = 0U; index < size; ++index) {
    const TddDemuxEvent event = demux.push(bytes[index]);
    if (event.local_size != 0U || event.has_control || event.has_bulk_data ||
        event.has_bulk_negotiation || event.has_peer_completion_receipt) {
      return false;
    }
    if (event.has_terminal_ack) {
      if (found) {
        return false;
      }
      found = true;
      output = event.terminal_ack_fragment;
    }
  }
  return found && demux.buffered_size() == 0U;
}

bool route_peer_receipt(TddLinkDemux &demux, const std::uint8_t *bytes,
                        std::size_t size, PeerCompletionReceiptFrame &output) {
  bool found = false;
  for (std::size_t index = 0U; index < size; ++index) {
    const TddDemuxEvent event = demux.push(bytes[index]);
    if (event.local_size != 0U || event.has_control || event.has_bulk_data ||
        event.has_bulk_negotiation || event.has_terminal_ack) {
      return false;
    }
    if (event.has_peer_completion_receipt) {
      if (found) {
        return false;
      }
      found = true;
      output = event.peer_completion_receipt;
    }
  }
  return found && demux.buffered_size() == 0U;
}

HighSpeedStandardGrantEvidence
standard_grant_evidence(const Phase6RadioWriterLease &lease,
                        std::uint64_t completed_ms) {
  HighSpeedStandardGrantEvidence evidence{};
  evidence.grant_session_id = kGrantSession;
  evidence.grant_cycle_id = kFreshCycle;
  evidence.writer_token = lease.action_token;
  evidence.writer_generation = lease.writer_generation;
  evidence.accepted = true;
  evidence.physical_tail_complete = true;
  evidence.completed_ms = completed_ms;
  return evidence;
}

bool run_e2e(Checks &checks);
bool run_fail_close_negatives(
    const BulkNegotiationFrame &request_record, const TddControlMessage &grant,
    const HighSpeedStandardGrantEvidence &evidence,
    const TerminalAckExpectedEvidence &terminal_expected,
    const TerminalAckFragments &terminal_fragments, Checks &checks);

} // namespace

namespace {

bool run_e2e(Checks &checks) {
  GroundHighSpeedPhase6Adapter ground{kGroundConfig};
  VehicleHighSpeedPhase6Adapter vehicle{kVehicleConfig};
  Phase6RadioWriterArbiter ground_writer{};
  Phase6RadioWriterArbiter vehicle_writer{};
  TddLinkDemux ground_demux{};
  TddLinkDemux vehicle_demux{};

  const MavlinkFrame request = parameter_request_list();
  checks.expect(
      ground.observe_standard_grant(kGrantSession, kBaselineCycle, 900U) ==
              HighSpeedPhase6AdapterStatus::Ready &&
          ground.on_ground_usb_frame(request, kUsbEpoch, kT0Ms) ==
              HighSpeedPhase6AdapterStatus::Held &&
          ground.hold_standard_uplink() && ground.t0_ms() == kT0Ms &&
          ground.on_ground_usb_frame(request, kUsbEpoch, kT0Ms) ==
              HighSpeedPhase6AdapterStatus::Busy &&
          !ground.fail_closed(),
      "Ground #21 was not intercepted/Held with Busy no-fallthrough");
  if (!checks.passed) {
    return false;
  }

  TddControlMessage grant{};
  grant.version = kTddProtocolVersion;
  grant.type = ControlType::UlGrant;
  grant.session_id = kGrantSession;
  grant.cycle_id = kFreshCycle;
  grant.guard_ms = 650U;
  grant.window_ms = 300U;
  grant.max_bytes = 64U;
  std::array<std::uint8_t, kTddControlFrameSize> grant_wire{};
  std::size_t grant_size = 0U;
  Phase6RadioWriterLease grant_lease{};
  checks.expect(
      encode_control(grant, grant_wire.data(), grant_wire.size(), grant_size) &&
          grant_size == grant_wire.size() &&
          vehicle_writer.request(Phase6RadioWriterOwner::StandardTdd, 0x7001U,
                                 grant_lease) ==
              Phase6RadioWriterStatus::LeaseGranted &&
          vehicle_writer.complete_uart(grant_lease,
                                       Phase6RadioWriterUartResult::Accepted,
                                       kGrantTailMs - 1U) ==
              Phase6RadioWriterStatus::AcceptedAwaitingTail &&
          vehicle_writer.observe_physical_tail(
              Phase6RadioTailEvidence{grant_lease, true, kGrantTailMs},
              kGrantTailMs) == Phase6RadioWriterStatus::TailReleased,
      "standard Grant writer did not retain ownership through physical tail");
  TddControlMessage routed_grant{};
  checks.expect(
      route_control(ground_demux, grant_wire.data(), grant_size,
                    routed_grant) &&
          routed_grant.type == ControlType::UlGrant &&
          routed_grant.session_id == kGrantSession &&
          routed_grant.cycle_id == kFreshCycle &&
          ground.on_fresh_grant(routed_grant.session_id, routed_grant.cycle_id,
                                kGrantTailMs) ==
              HighSpeedPhase6AdapterStatus::Ready &&
          ground.poll(kGrantTailMs + 99U).type ==
              HighSpeedPhase6OutputType::None,
      "Ground did not route the retained Grant or hold the first +99 ms guard");
  HighSpeedPhase6Output request_output = ground.poll(kGrantTailMs + 100U);
  checks.expect(request_output.type == HighSpeedPhase6OutputType::RadioWrite &&
                    request_output.semantic ==
                        HighSpeedActionType::SendNegotiationRequest &&
                    request_output.size ==
                        BulkNegotiationWireCodec::frame_bytes,
                "Ground did not release VCBN at the inclusive +100 ms guard");
  if (!checks.passed) {
    return false;
  }

  Phase6RadioWriterLease request_lease{};
  checks.expect(
      ground_writer.request(Phase6RadioWriterOwner::StandardTdd,
                            request_output.token, request_lease) ==
              Phase6RadioWriterStatus::LeaseGranted &&
          ground_writer.complete_uart(request_lease,
                                      Phase6RadioWriterUartResult::Accepted,
                                      kGrantTailMs + 101U) ==
              Phase6RadioWriterStatus::AcceptedAwaitingTail &&
          ground.complete_output(request_output.token, TxResult::Accepted,
                                 kGrantTailMs + 101U) ==
              HighSpeedPhase6AdapterStatus::Accepted &&
          ground_writer.observe_physical_tail(
              Phase6RadioTailEvidence{request_lease, true, kRequestArrivalMs},
              kRequestArrivalMs) == Phase6RadioWriterStatus::TailReleased &&
          ground.on_radio_tail(
              HighSpeedTailDrainEvidence{request_output.token, true,
                                         kRequestArrivalMs},
              kRequestArrivalMs) == HighSpeedPhase6AdapterStatus::TailAccepted,
      "Ground VCBN did not preserve writer/action ownership to RF tail");
  BulkNegotiationFrame request_record{};
  checks.expect(route_negotiation(vehicle_demux, request_output.bytes.data(),
                                  request_output.size, request_record),
                "Vehicle demux did not route the exact VCBN request");
  const HighSpeedStandardGrantEvidence grant_evidence =
      standard_grant_evidence(grant_lease, kGrantTailMs);
  checks.expect(
      vehicle.on_negotiation_request_with_retained_grant(
          routed_grant, grant_evidence, request_record.data(),
          request_record.size(),
          kRequestArrivalMs) == HighSpeedPhase6AdapterStatus::Ready &&
          vehicle.poll(kRequestArrivalMs + 99U).type ==
              HighSpeedPhase6OutputType::None,
      "Vehicle did not atomically adopt the exact-age-500 retained Grant");
  HighSpeedPhase6Output response_output =
      vehicle.poll(kRequestArrivalMs + 100U);
  checks.expect(
      response_output.type == HighSpeedPhase6OutputType::RadioWrite &&
          response_output.semantic ==
              HighSpeedActionType::SendNegotiationResponse &&
          response_output.size == BulkNegotiationWireCodec::frame_bytes,
      "Vehicle did not release VCBN response at the second +100 ms guard");
  if (!checks.passed) {
    return false;
  }

  constexpr std::uint64_t response_uart_ms = kRequestArrivalMs + 101U;
  constexpr std::uint64_t response_tail_ms = kRequestArrivalMs + 102U;
  constexpr Phase6HighSpeedStreamLimits response_limits{1U, 32U, 32U};
  Phase6HighSpeedRadioSession response_radio_session{
      vehicle_writer, vehicle.identity().session_id};
  Phase6HighSpeedRadioWrite response_write{};
  checks.expect(
      response_radio_session.begin(
          0xC001U, Direction::Downlink, response_limits,
          static_cast<std::uint32_t>(kRequestArrivalMs)) ==
              Phase6HighSpeedRadioSessionStatus::StreamStarted &&
          response_radio_session.observe_aux(
              static_cast<std::uint32_t>(kRequestArrivalMs), true) ==
              Phase6HighSpeedRadioSessionStatus::StreamActive &&
          response_radio_session.retain_adapter_action(
              response_output, true,
              static_cast<std::uint32_t>(kRequestArrivalMs + 100U)) ==
              Phase6HighSpeedRadioSessionStatus::ActionRetained &&
          response_radio_session.assess_write(
              static_cast<std::uint32_t>(response_uart_ms), response_write) ==
              Phase6HighSpeedRadioSessionStatus::WriteReady &&
          response_write.size == response_output.size &&
          std::equal(response_write.bytes.begin(),
                     response_write.bytes.begin() + response_write.size,
                     response_output.bytes.begin()) &&
          response_radio_session.complete_uart(
              response_write.action_token, response_write.writer_generation,
              response_write.wire_ordinal, response_write.size,
              static_cast<std::uint32_t>(response_uart_ms)) ==
              Phase6HighSpeedRadioSessionStatus::WriteCommitted &&
          vehicle.complete_output(response_output.token, TxResult::Accepted,
                                  response_uart_ms) ==
              HighSpeedPhase6AdapterStatus::Accepted &&
          vehicle.on_radio_tail(
              HighSpeedTailDrainEvidence{response_output.token, true,
                                         response_tail_ms},
              response_tail_ms) == HighSpeedPhase6AdapterStatus::TailAccepted,
      "Vehicle VCBN response did not enter a receipt-gated radio stream");
  BulkNegotiationFrame response_record{};
  checks.expect(
      route_negotiation(ground_demux, response_output.bytes.data(),
                        response_output.size, response_record) &&
          ground.on_negotiation_response(
              response_record.data(), response_record.size(),
              response_tail_ms) == HighSpeedPhase6AdapterStatus::BulkEnabled &&
          ground.transfer_tag() != 0U &&
          ground.transfer_tag() == vehicle.transfer_tag() &&
          ground_demux.set_bulk_data_route_mode(BulkDataRouteMode::Enabled),
      "Ground did not correlate VCBN response/enable VCB1 routing");
  const PeerCompletionReceiptFields response_receipt_fields{
      PeerCompletionReceiptKind::NegotiationResponseConsumed,
      vehicle.identity().session_id, vehicle.transfer_tag(),
      vehicle.identity().lease_id};
  PeerCompletionReceiptLedger response_receipt_ledger{};
  checks.expect(response_receipt_fields.valid() &&
                    response_receipt_ledger.arm(
                        response_receipt_fields,
                        static_cast<std::uint32_t>(kBulkStartMs - 1U),
                        static_cast<std::uint32_t>(response_tail_ms)) ==
                        PeerCompletionReceiptLedgerStatus::Armed &&
                    response_receipt_ledger.bind_final_transfer(
                        response_radio_session.last_transfer_token(),
                        static_cast<std::uint32_t>(response_tail_ms)) ==
                        PeerCompletionReceiptLedgerStatus::FinalTokenBound,
                "Vehicle did not bind the VCBN response token to kind1 VCRC");
  HighSpeedPhase6Output pixhawk = vehicle.poll(response_tail_ms);
  MavlinkFrame pixhawk_frame{};
  checks.expect(
      pixhawk.type == HighSpeedPhase6OutputType::PixhawkWrite &&
          validate_mavlink_frame(pixhawk.bytes.data(), pixhawk.size,
                                 pixhawk_frame) ==
              MavlinkParseStatus::FrameReady &&
          pixhawk_frame.message_id == 21U &&
          vehicle.complete_output(pixhawk.token, TxResult::Accepted,
                                  response_tail_ms + 1U) ==
              HighSpeedPhase6AdapterStatus::AwaitPixhawkCommit &&
          !vehicle.bulk_tx_enabled() &&
          vehicle.on_pixhawk_request_tail(
              HighSpeedTailDrainEvidence{pixhawk.token, true,
                                         response_tail_ms + 2U},
              response_tail_ms + 2U) ==
              HighSpeedPhase6AdapterStatus::BulkEnabled &&
          vehicle.bulk_tx_enabled(),
      "Pixhawk #21 UART acceptance was not separated from exact physical tail");
  if (!checks.passed) {
    return false;
  }

  constexpr std::uint64_t response_receipt_uart_ms = response_tail_ms + 1U;
  constexpr std::uint64_t response_receipt_arrival_ms = kBulkStartMs - 2U;
  PeerCompletionReceiptProducer response_receipt_producer{};
  PeerCompletionReceiptWrite response_receipt_write{};
  Phase6RadioWriterLease response_receipt_writer_lease{};
  checks.expect(
      response_radio_session.observe_aux(
          static_cast<std::uint32_t>(response_tail_ms), false) ==
              Phase6HighSpeedRadioSessionStatus::StreamActive &&
          response_radio_session.observe_aux(
              static_cast<std::uint32_t>(response_tail_ms + 1U), true) ==
              Phase6HighSpeedRadioSessionStatus::StreamActive &&
          response_radio_session.release_buffer_credit_from_local_aux(
              static_cast<std::uint32_t>(response_tail_ms + 16U),
              response_radio_session.last_transfer_token()) ==
              Phase6HighSpeedRadioSessionStatus::BufferCreditReleased &&
          vehicle_writer.high_speed_stream_active() &&
          !vehicle_writer.can_poll_standard(),
      "Vehicle response stream restored from AUX without kind1 VCRC");
  checks.expect(
      response_receipt_producer.stage(
          response_receipt_fields,
          static_cast<std::uint32_t>(response_tail_ms)) ==
              PeerCompletionReceiptProducerStatus::Staged &&
          response_receipt_producer.poll(
              static_cast<std::uint32_t>(response_receipt_uart_ms),
              response_receipt_write) ==
              PeerCompletionReceiptProducerStatus::WriteReady &&
          response_receipt_write.valid() &&
          ground_writer.request(Phase6RadioWriterOwner::StandardTdd,
                                response_receipt_write.action_token,
                                response_receipt_writer_lease) ==
              Phase6RadioWriterStatus::LeaseGranted &&
          ground_writer.complete_uart(response_receipt_writer_lease,
                                      Phase6RadioWriterUartResult::Accepted,
                                      response_receipt_uart_ms) ==
              Phase6RadioWriterStatus::AcceptedAwaitingTail &&
          response_receipt_producer.complete_write(
              response_receipt_write.action_token,
              response_receipt_write.writer_generation,
              PeerCompletionReceiptWriteDisposition::Accepted,
              response_receipt_write.size,
              static_cast<std::uint32_t>(response_receipt_uart_ms)) ==
              PeerCompletionReceiptProducerStatus::Committed &&
          vehicle_writer.high_speed_stream_active(),
      "Ground did not produce kind1 VCRC without treating UART accept as "
      "receipt");
  PeerCompletionReceiptFrame routed_response_receipt{};
  PeerCompletionReceiptProof response_receipt_proof{};
  checks.expect(
      ground_writer.observe_physical_tail(
          Phase6RadioTailEvidence{response_receipt_writer_lease, true,
                                  response_receipt_arrival_ms},
          response_receipt_arrival_ms) ==
              Phase6RadioWriterStatus::TailReleased &&
          route_peer_receipt(vehicle_demux, response_receipt_write.bytes.data(),
                             response_receipt_write.size,
                             routed_response_receipt) &&
          response_receipt_ledger.consume_peer_receipt(
              routed_response_receipt,
              static_cast<std::uint32_t>(response_receipt_arrival_ms)) ==
              PeerCompletionReceiptLedgerStatus::ProofReady &&
          response_receipt_ledger.take_proof(
              response_receipt_proof,
              static_cast<std::uint32_t>(response_receipt_arrival_ms)) ==
              PeerCompletionReceiptLedgerStatus::ProofIssued &&
          response_receipt_proof.kind() ==
              PeerCompletionReceiptKind::NegotiationResponseConsumed &&
          response_radio_session.complete_stream_from_peer_receipt(
              response_receipt_proof,
              static_cast<std::uint32_t>(response_receipt_arrival_ms)) ==
              Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired &&
          response_radio_session.restore_standard(
              true,
              static_cast<std::uint32_t>(response_receipt_arrival_ms + 1U)) ==
              Phase6HighSpeedRadioSessionStatus::StandardRestored &&
          vehicle_writer.can_poll_standard(),
      "exact kind1 VCRC did not close and cleanly restore response stream");
  if (!checks.passed) {
    return false;
  }

  MavlinkFrameScheduler scheduler{};
  checks.expect(scheduler.enqueue(heartbeat(0x80U), response_tail_ms + 3U) ==
                    MavlinkEnqueueStatus::Queued,
                "scheduler rejected initial real HEARTBEAT");
  for (std::uint16_t index = 0U; index < BulkSessionAccounting::parameter_count;
       ++index) {
    checks.expect(
        scheduler.enqueue(parameter_value(index), response_tail_ms + 3U) ==
            MavlinkEnqueueStatus::Queued,
        "scheduler rejected ordered PARAM_VALUE corpus");
    if (!checks.passed) {
      return false;
    }
  }
  checks.expect(scheduler.begin_bulk_heartbeat_policy(response_tail_ms + 4U) ==
                    MavlinkBulkHeartbeatPolicyStatus::Started,
                "scheduler did not start real-heartbeat bulk policy");

  BulkDataTxLease tx_lease{scheduler, vehicle.transfer_tag()};
  BulkDataStreamDecoder decoder{ground.transfer_tag()};
  R19BulkRxTailLedger rx_ledger{};
  BulkTranscriptLedger vehicle_transcript{vehicle.identity(),
                                          vehicle.transfer_tag()};
  BulkTranscriptLedger ground_transcript{ground.identity(),
                                         ground.transfer_tag()};
  BulkHeartbeatSlaLedger sla{ground.transfer_tag()};
  GroundTerminalAckProducer terminal_producer{};
  checks.expect(rx_ledger.arm(ground.transfer_tag(), kBulkStartMs) ==
                        R19BulkRxTailLedgerStatus::Armed &&
                    sla.capture_baseline(900U) ==
                        BulkHeartbeatSlaStatus::BaselineCaptured &&
                    sla.start_request(kT0Ms) ==
                        BulkHeartbeatSlaStatus::RequestStarted,
                "Ground decoder/transcript/SLA owners did not arm");

  Phase6RadioWriterLease bulk_stream_lease{};
  constexpr Phase6HighSpeedStreamLimits bulk_limits{
      kExpectedFragmentCount + 10U,
      static_cast<std::uint64_t>(kExpectedFragmentCount + 10U) * 32U, 32U};
  checks.expect(vehicle_writer.begin_high_speed_stream(0xD001U, bulk_limits,
                                                       bulk_stream_lease) ==
                        Phase6RadioWriterStatus::HighSpeedStreamLeaseGranted &&
                    !vehicle_writer.can_poll_standard(),
                "Vehicle did not freeze standard writer for the VCB1 stream");
  if (!checks.passed) {
    return false;
  }

  constexpr std::array<std::uint16_t, 4U> heartbeat_after_parameter{
      {249U, 499U, 749U, 919U}};
  std::size_t heartbeat_trigger = 0U;
  std::uint8_t next_heartbeat_sequence = 0x81U;
  std::uint32_t expected_parameter_index = 0U;
  std::uint32_t observed_heartbeat_count = 0U;
  std::uint32_t fragment_ordinal = 0U;
  std::uint64_t final_tail_ms = 0U;
  std::uint64_t t1_ms = 0U;
  HighSpeedLocalRxRecordIdentity final_rx_identity{};

  while (!scheduler.empty() || tx_lease.active()) {
    const std::uint64_t tx_ms =
        kBulkStartMs + static_cast<std::uint64_t>(fragment_ordinal) * 3U;
    const std::uint64_t rx_ms = tx_ms + 1U;
    checks.expect(vehicle.stage_next_bulk_fragment(tx_lease, tx_ms) ==
                      HighSpeedPhase6AdapterStatus::ActionReady,
                  "Vehicle failed to stage a lease-owned VCB1 fragment");
    const HighSpeedPhase6Output output = vehicle.poll(tx_ms);
    checks.expect(
        output.type == HighSpeedPhase6OutputType::RadioWrite &&
            output.semantic == HighSpeedActionType::SendBulkFragment &&
            output.size == BulkDataWireCodec::fragment_bytes &&
            vehicle_writer.record_high_speed_uart(
                bulk_stream_lease, output.token, output.writer_generation,
                fragment_ordinal, static_cast<std::uint32_t>(output.size),
                tx_ms) ==
                Phase6RadioWriterStatus::HighSpeedStreamUartRecorded &&
            vehicle.complete_output(output.token, TxResult::Accepted, tx_ms) ==
                HighSpeedPhase6AdapterStatus::Accepted,
        "VCB1 UART record/action identity did not advance monotonically");
    if (!checks.passed) {
      return false;
    }

    BulkDataFragment routed_fragment{};
    BulkDataDecodedFragment fragment_evidence{};
    checks.expect(route_bulk(ground_demux, output.bytes.data(), output.size,
                             routed_fragment) &&
                      BulkDataWireCodec::decode_fragment(routed_fragment,
                                                         fragment_evidence) ==
                          BulkDataWireStatus::FragmentReady &&
                      fragment_evidence.transfer_tag == ground.transfer_tag() &&
                      fragment_evidence.wire_ordinal == fragment_ordinal,
                  "Ground demux changed VCB1 tag/ordinal/bytes");
    MavlinkFrame decoded{};
    const R19BulkRxTailLedgerStatus ledger_status =
        rx_ledger.accept_decoder_fragment(decoder, routed_fragment, decoded,
                                          rx_ms);
    checks.expect(
        ledger_status == R19BulkRxTailLedgerStatus::FragmentAccepted ||
            ledger_status == R19BulkRxTailLedgerStatus::FinalIdentityReady,
        "local RX ledger rejected decoder-accepted VCB1");
    ++fragment_ordinal;
    if (!checks.passed) {
      return false;
    }

    if (decoded.size == 0U) {
      continue;
    }
    checks.expect(vehicle_transcript.append(decoded) ==
                      BulkTranscriptStatus::EntryAccepted,
                  "Vehicle transcript rejected its committed source frame");
    if (decoded.message_id == 0U) {
      ++observed_heartbeat_count;
    } else {
      checks.expect(decoded.message_id == 22U &&
                        parameter_index(decoded) == expected_parameter_index,
                    "PARAM_VALUE order/count diverged from index 0..931");
      ++expected_parameter_index;
      if (heartbeat_trigger < heartbeat_after_parameter.size() &&
          parameter_index(decoded) ==
              heartbeat_after_parameter[heartbeat_trigger]) {
        const MavlinkEnqueueStatus heartbeat_status =
            scheduler.enqueue(heartbeat(next_heartbeat_sequence++), rx_ms);
        checks.expect(
            heartbeat_status == MavlinkEnqueueStatus::Queued,
            "runtime real HEARTBEAT was not admitted at >=1000 ms interval");
        ++heartbeat_trigger;
      }
    }

    const bool final =
        ledger_status == R19BulkRxTailLedgerStatus::FinalIdentityReady;
    if (final) {
      checks.expect(
          expected_parameter_index == BulkSessionAccounting::parameter_count &&
              observed_heartbeat_count == kHeartbeatCount &&
              fragment_ordinal == kExpectedFragmentCount &&
              vehicle.complete_bulk_downlink(tx_lease, rx_ms) ==
                  HighSpeedPhase6AdapterStatus::TerminalReady &&
              scheduler.end_bulk_heartbeat_policy() ==
                  MavlinkBulkHeartbeatPolicyStatus::Ended,
          "Vehicle did not seal exact 932-parameter/5-heartbeat owners");
      const Phase6HighSpeedStreamTailEvidence stream_tail{
          bulk_stream_lease,
          output.token,
          output.writer_generation,
          fragment_ordinal - 1U,
          fragment_ordinal,
          static_cast<std::uint64_t>(fragment_ordinal) * output.size,
          true,
          true,
          rx_ms};
      checks.expect(
          vehicle_writer.observe_high_speed_stream_tail(stream_tail, rx_ms) ==
                  Phase6RadioWriterStatus::ExplicitRestoreRequired &&
              vehicle_writer.explicit_restore_required() &&
              vehicle.on_bulk_tail(
                  HighSpeedStreamTailEvidence{
                      vehicle.transfer_tag(), fragment_ordinal - 1U,
                      fragment_ordinal, output.token, output.writer_generation,
                      true, rx_ms},
                  rx_ms) == HighSpeedPhase6AdapterStatus::TailAccepted &&
              rx_ledger.issue_final_identity(final_rx_identity, rx_ms) ==
                  R19BulkRxTailLedgerStatus::IdentityIssued &&
              final_rx_identity.rx_record_token != output.token &&
              final_rx_identity.rx_ledger_generation !=
                  output.writer_generation &&
              ground.bind_final_bulk_rx_record(final_rx_identity, rx_ms) ==
                  HighSpeedPhase6AdapterStatus::Ready &&
              ground.on_bulk_tail(
                  HighSpeedStreamTailEvidence{
                      final_rx_identity.transfer_tag,
                      final_rx_identity.final_wire_ordinal,
                      final_rx_identity.fragment_count,
                      final_rx_identity.rx_record_token,
                      final_rx_identity.rx_ledger_generation, true, rx_ms},
                  rx_ms) == HighSpeedPhase6AdapterStatus::TailAccepted,
          "final VCB1 physical tail/local RX identity was fabricated or "
          "mismatched");
      final_tail_ms = rx_ms;
    }

    checks.expect(
        ground.on_decoded_bulk_frame(decoded, ground_transcript, sla, rx_ms) ==
            HighSpeedPhase6AdapterStatus::UsbFrameStaged,
        "Ground did not route decoder-owned frame to transcript/SLA/USB");
    const HighSpeedPhase6Output usb = ground.poll(rx_ms);
    checks.expect(
        usb.type == HighSpeedPhase6OutputType::GroundUsbWrite &&
            same_frame(usb, decoded) &&
            ground.complete_output(usb.token, TxResult::Accepted, rx_ms) ==
                HighSpeedPhase6AdapterStatus::AwaitUsbCommit,
        "Ground USB output was not the exact decoder frame");
    if (final) {
      t1_ms = rx_ms + 1U;
      checks.expect(ground.on_final_ground_usb_host_commit(
                        GroundUsbHostCommitEvent{usb.token, kUsbEpoch, t1_ms},
                        decoder, ground_transcript, sla, terminal_producer) ==
                            HighSpeedPhase6AdapterStatus::TerminalReady &&
                        ground.has_t1() && ground.t1_ms() == t1_ms,
                    "final PARAM_VALUE host-visible t1 did not produce VCTA");
    } else {
      checks.expect(ground.on_ground_usb_host_commit(GroundUsbHostCommitEvent{
                        usb.token, kUsbEpoch, rx_ms}) ==
                        HighSpeedPhase6AdapterStatus::UsbCommitted,
                    "non-final Ground USB host commit was rejected");
    }
    if (!checks.passed) {
      return false;
    }
  }

  checks.expect(vehicle_transcript.seal_session() ==
                    BulkTranscriptStatus::Sealed,
                "Vehicle transcript did not seal after exact corpus");
  const BulkDataTxLeaseEvidence tx_evidence = tx_lease.completion_evidence();
  const BulkTranscriptEvidence vehicle_evidence = vehicle_transcript.evidence();
  const BulkTranscriptEvidence ground_evidence = ground_transcript.evidence();
  const BulkHeartbeatSlaEvidence sla_evidence = sla.evidence();
  checks.expect(
      tx_evidence.owner_sealed &&
          tx_evidence.parameter_count ==
              BulkSessionAccounting::parameter_count &&
          tx_evidence.parameter_fragment_count ==
              BulkSessionAccounting::parameter_fragment_count &&
          tx_evidence.heartbeat_count == kHeartbeatCount &&
          decoder.complete() && decoder.sealed() && !decoder.latched() &&
          decoder.parameter_count() == BulkSessionAccounting::parameter_count &&
          decoder.heartbeat_count() == kHeartbeatCount &&
          decoder.total_fragment_count() == kExpectedFragmentCount &&
          ground_evidence.owner_sealed && vehicle_evidence.owner_sealed &&
          ground_evidence.digest == vehicle_evidence.digest &&
          sla_evidence.complete &&
          sla_evidence.heartbeat_count == kHeartbeatCount &&
          sla_evidence.first_heartbeat_gap_ms <=
              BulkSessionAccounting::heartbeat_deadline_ms &&
          sla_evidence.max_heartbeat_gap_ms <=
              BulkSessionAccounting::heartbeat_deadline_ms &&
          sla_evidence.post_heartbeat_gap_ms <=
              BulkSessionAccounting::heartbeat_deadline_ms &&
          t1_ms >= kT0Ms &&
          t1_ms - kT0Ms <= BulkSessionAccounting::completion_deadline_ms,
      "932/count/order/digest/Heartbeat/30s terminal accounting mismatch");
  if (!checks.passed) {
    return false;
  }

  checks.expect(
      ground.poll(final_tail_ms + 99U).type ==
              HighSpeedPhase6OutputType::None &&
          vehicle.poll(final_tail_ms + 99U).type ==
              HighSpeedPhase6OutputType::None,
      "terminal direction changed before the final-tail +100 ms guard");
  const HighSpeedPhase6Output open = vehicle.poll(final_tail_ms + 100U);
  checks.expect(open.type == HighSpeedPhase6OutputType::OpenTerminalAckWindow &&
                    vehicle.complete_output(open.token, TxResult::Accepted,
                                            final_tail_ms + 100U) ==
                        HighSpeedPhase6AdapterStatus::WindowOpened,
                "Vehicle did not open VCTA receive window at +100 ms");

  VehicleTerminalAckExpectedFactory expected_factory{};
  TerminalAckExpectedEvidence terminal_expected{};
  checks.expect(
      expected_factory.make_expected(vehicle.identity(), vehicle_transcript,
                                     terminal_expected) ==
              TerminalAckProducerStatus::ExpectedReady &&
          terminal_expected.transcript_digest == ground_evidence.digest,
      "Vehicle did not independently derive terminal digest/evidence");
  TerminalAckReassembler reassembler{terminal_expected};
  TerminalAckFragments terminal_fragments{};
  constexpr Phase6HighSpeedStreamLimits terminal_limits{
      static_cast<std::uint32_t>(TerminalAckWireCodec::fragment_count),
      TerminalAckWireCodec::fragment_count *
          TerminalAckWireCodec::fragment_bytes,
      static_cast<std::uint32_t>(TerminalAckWireCodec::fragment_bytes)};
  Phase6HighSpeedRadioSession terminal_radio_session{
      ground_writer, ground.identity().session_id};
  const PeerCompletionReceiptFields terminal_receipt_fields{
      PeerCompletionReceiptKind::TerminalRecordConsumed,
      ground.identity().session_id, ground.transfer_tag(),
      terminal_expected.expected_record_id};
  PeerCompletionReceiptLedger terminal_receipt_ledger{};
  checks.expect(ground.terminal_record_id() ==
                        terminal_expected.expected_record_id &&
                    terminal_receipt_fields.valid() &&
                    terminal_radio_session.begin(
                        0xE001U, Direction::Uplink, terminal_limits,
                        static_cast<std::uint32_t>(final_tail_ms)) ==
                        Phase6HighSpeedRadioSessionStatus::StreamStarted &&
                    terminal_radio_session.observe_aux(
                        static_cast<std::uint32_t>(final_tail_ms), true) ==
                        Phase6HighSpeedRadioSessionStatus::StreamActive &&
                    terminal_receipt_ledger.arm(
                        terminal_receipt_fields,
                        static_cast<std::uint32_t>(final_tail_ms + 1'000U),
                        static_cast<std::uint32_t>(final_tail_ms)) ==
                        PeerCompletionReceiptLedgerStatus::Armed,
                "Ground did not arm receipt-gated VCTA writer/terminal owner");

  std::uint32_t final_terminal_token = 0U;
  std::uint64_t final_terminal_uart_ms = 0U;
  TransferToken final_terminal_transfer{};
  for (std::size_t index = 0U; index < TerminalAckWireCodec::fragment_count;
       ++index) {
    const std::uint64_t now =
        final_tail_ms + 100U + static_cast<std::uint64_t>(index) * 3U;
    const HighSpeedPhase6Output terminal = ground.poll(now);
    Phase6HighSpeedRadioWrite terminal_write{};
    checks.expect(
        terminal.type == HighSpeedPhase6OutputType::RadioWrite &&
            terminal.semantic == HighSpeedActionType::SendTerminalEvidence &&
            terminal.size == TerminalAckWireCodec::fragment_bytes &&
            terminal_radio_session.retain_adapter_action(
                terminal, index + 1U == TerminalAckWireCodec::fragment_count,
                static_cast<std::uint32_t>(now)) ==
                Phase6HighSpeedRadioSessionStatus::ActionRetained &&
            terminal_radio_session.assess_write(static_cast<std::uint32_t>(now),
                                                terminal_write) ==
                Phase6HighSpeedRadioSessionStatus::WriteReady &&
            terminal_write.wire_ordinal == index &&
            terminal_write.size == terminal.size &&
            std::equal(terminal_write.bytes.begin(),
                       terminal_write.bytes.begin() + terminal_write.size,
                       terminal.bytes.begin()) &&
            terminal_radio_session.complete_uart(
                terminal_write.action_token, terminal_write.writer_generation,
                terminal_write.wire_ordinal, terminal_write.size,
                static_cast<std::uint32_t>(now)) ==
                Phase6HighSpeedRadioSessionStatus::WriteCommitted &&
            ground.complete_output(terminal.token, TxResult::Accepted, now) ==
                HighSpeedPhase6AdapterStatus::Accepted,
        "Ground VCTA action/writer identity did not advance monotonically");
    TerminalAckFragment routed{};
    checks.expect(route_terminal(vehicle_demux, terminal.bytes.data(),
                                 terminal.size, routed) &&
                      reassembler.push(routed) == TerminalAckError::None,
                  "Vehicle demux/reassembler rejected exact VCTA fragment");
    terminal_fragments[index] = routed;
    if (index + 1U == TerminalAckWireCodec::fragment_count) {
      final_terminal_token = terminal.token;
      final_terminal_uart_ms = now;
      final_terminal_transfer = terminal_radio_session.last_transfer_token();
      checks.expect(
          !ground.complete() && final_terminal_transfer.valid() &&
              terminal_receipt_ledger.bind_final_transfer(
                  final_terminal_transfer, static_cast<std::uint32_t>(now)) ==
                  PeerCompletionReceiptLedgerStatus::FinalTokenBound,
          "Ground completed or failed terminal token bind at VCTA UART "
          "acceptance");
    }
    if (!checks.passed) {
      return false;
    }
  }
  const std::uint64_t terminal_tail_ms = final_terminal_uart_ms + 1U;
  checks.expect(
      reassembler.finish() == TerminalAckError::None &&
          ground.on_radio_tail(
              HighSpeedTailDrainEvidence{final_terminal_token, true,
                                         terminal_tail_ms},
              terminal_tail_ms) == HighSpeedPhase6AdapterStatus::Complete &&
          ground.complete() &&
          vehicle.on_terminal_reassembler(reassembler, terminal_tail_ms) ==
              HighSpeedPhase6AdapterStatus::Complete &&
          vehicle.complete() &&
          vehicle_writer.restore_standard(true) ==
              Phase6RadioWriterStatus::StandardRestored &&
          vehicle_writer.can_poll_standard(),
      "VCTA consume did not complete adapters/restore Vehicle VCB1 owner");
  checks.expect(
      terminal_radio_session.observe_aux(
          static_cast<std::uint32_t>(terminal_tail_ms), false) ==
              Phase6HighSpeedRadioSessionStatus::StreamActive &&
          terminal_radio_session.observe_aux(
              static_cast<std::uint32_t>(terminal_tail_ms + 1U), true) ==
              Phase6HighSpeedRadioSessionStatus::StreamActive &&
          terminal_radio_session.release_buffer_credit_from_local_aux(
              static_cast<std::uint32_t>(terminal_tail_ms + 16U),
              final_terminal_transfer) ==
              Phase6HighSpeedRadioSessionStatus::BufferCreditReleased &&
          ground_writer.high_speed_stream_active() &&
          !ground_writer.can_poll_standard(),
      "Ground terminal stream restored from local AUX without kind2 VCRC");

  constexpr std::uint64_t terminal_receipt_tx_offset_ms = 1U;
  constexpr std::uint64_t terminal_receipt_arrival_offset_ms = 100U;
  const std::uint64_t terminal_receipt_uart_ms =
      terminal_tail_ms + terminal_receipt_tx_offset_ms;
  const std::uint64_t terminal_receipt_arrival_ms =
      terminal_tail_ms + terminal_receipt_arrival_offset_ms;
  PeerCompletionReceiptProducer terminal_receipt_producer{};
  PeerCompletionReceiptWrite terminal_receipt_write{};
  Phase6RadioWriterLease terminal_receipt_writer_lease{};
  checks.expect(
      terminal_receipt_producer.stage(
          terminal_receipt_fields,
          static_cast<std::uint32_t>(terminal_tail_ms)) ==
              PeerCompletionReceiptProducerStatus::Staged &&
          terminal_receipt_producer.poll(
              static_cast<std::uint32_t>(terminal_receipt_uart_ms),
              terminal_receipt_write) ==
              PeerCompletionReceiptProducerStatus::WriteReady &&
          terminal_receipt_write.valid() &&
          vehicle_writer.request(Phase6RadioWriterOwner::StandardTdd,
                                 terminal_receipt_write.action_token,
                                 terminal_receipt_writer_lease) ==
              Phase6RadioWriterStatus::LeaseGranted &&
          vehicle_writer.complete_uart(terminal_receipt_writer_lease,
                                       Phase6RadioWriterUartResult::Accepted,
                                       terminal_receipt_uart_ms) ==
              Phase6RadioWriterStatus::AcceptedAwaitingTail &&
          terminal_receipt_producer.complete_write(
              terminal_receipt_write.action_token,
              terminal_receipt_write.writer_generation,
              PeerCompletionReceiptWriteDisposition::Accepted,
              terminal_receipt_write.size,
              static_cast<std::uint32_t>(terminal_receipt_uart_ms)) ==
              PeerCompletionReceiptProducerStatus::Committed &&
          ground_writer.high_speed_stream_active(),
      "Vehicle did not produce kind2 VCRC without treating UART accept as "
      "receipt");
  PeerCompletionReceiptFrame routed_terminal_receipt{};
  PeerCompletionReceiptProof terminal_receipt_proof{};
  checks.expect(
      vehicle_writer.observe_physical_tail(
          Phase6RadioTailEvidence{terminal_receipt_writer_lease, true,
                                  terminal_receipt_arrival_ms},
          terminal_receipt_arrival_ms) ==
              Phase6RadioWriterStatus::TailReleased &&
          route_peer_receipt(ground_demux, terminal_receipt_write.bytes.data(),
                             terminal_receipt_write.size,
                             routed_terminal_receipt) &&
          terminal_receipt_ledger.consume_peer_receipt(
              routed_terminal_receipt,
              static_cast<std::uint32_t>(terminal_receipt_arrival_ms)) ==
              PeerCompletionReceiptLedgerStatus::ProofReady &&
          terminal_receipt_ledger.take_proof(
              terminal_receipt_proof,
              static_cast<std::uint32_t>(terminal_receipt_arrival_ms)) ==
              PeerCompletionReceiptLedgerStatus::ProofIssued &&
          terminal_receipt_proof.kind() ==
              PeerCompletionReceiptKind::TerminalRecordConsumed &&
          terminal_radio_session.complete_stream_from_peer_receipt(
              terminal_receipt_proof,
              static_cast<std::uint32_t>(terminal_receipt_arrival_ms)) ==
              Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired &&
          terminal_radio_session.restore_standard(
              true,
              static_cast<std::uint32_t>(terminal_receipt_arrival_ms + 1U)) ==
              Phase6HighSpeedRadioSessionStatus::StandardRestored &&
          ground_writer.can_poll_standard(),
      "exact kind2 VCRC did not close and cleanly restore terminal stream");
  if (!checks.passed) {
    return false;
  }

  return run_fail_close_negatives(request_record, routed_grant, grant_evidence,
                                  terminal_expected, terminal_fragments,
                                  checks);
}

bool run_fail_close_negatives(
    const BulkNegotiationFrame &request_record, const TddControlMessage &grant,
    const HighSpeedStandardGrantEvidence &evidence,
    const TerminalAckExpectedEvidence &terminal_expected,
    const TerminalAckFragments &terminal_fragments, Checks &checks) {
  {
    GroundHighSpeedPhase6Adapter ground{kGroundConfig};
    const MavlinkFrame request = parameter_request_list();
    checks.expect(
        ground.observe_standard_grant(kGrantSession, kBaselineCycle, 10U) ==
                HighSpeedPhase6AdapterStatus::Ready &&
            ground.on_ground_usb_frame(request, kUsbEpoch, 20U) ==
                HighSpeedPhase6AdapterStatus::Held &&
            ground.on_fresh_grant(kGrantSession, kFreshCycle, 21U) ==
                HighSpeedPhase6AdapterStatus::Ready &&
            ground.poll(120U).type == HighSpeedPhase6OutputType::None,
        "negative token fixture failed to reach +99 guard boundary");
    const HighSpeedPhase6Output action = ground.poll(121U);
    checks.expect(action.type == HighSpeedPhase6OutputType::RadioWrite &&
                      ground.complete_output(action.token + 1U,
                                             TxResult::Accepted, 122U) ==
                          HighSpeedPhase6AdapterStatus::FailClosed &&
                      ground.fail_closed(),
                  "mutated action token did not fail closed");
  }
  {
    VehicleHighSpeedPhase6Adapter stale{kVehicleConfig};
    checks.expect(stale.on_negotiation_request_with_retained_grant(
                      grant, evidence, request_record.data(),
                      request_record.size(), evidence.completed_ms + 501U) ==
                          HighSpeedPhase6AdapterStatus::FailClosed &&
                      stale.fail_closed(),
                  "retained Grant age +501 ms did not fail closed");
  }
  {
    constexpr std::uint32_t tag = 0x11223344U;
    R19BulkRxTailLedger ledger{};
    BulkDataStreamDecoder decoder{tag};
    TddLinkDemux demux{false, BulkDataRouteMode::Enabled};
    EncodedBulkDataFrame encoded{};
    checks.expect(
        ledger.arm(tag, 1U) == R19BulkRxTailLedgerStatus::Armed &&
            encode_bulk_data_frame(heartbeat(1U), tag + 1U, 0U, encoded) ==
                BulkDataWireStatus::FrameReady,
        "wrong-tag fixture setup failed");
    BulkDataFragment routed{};
    MavlinkFrame decoded{};
    checks.expect(
        route_bulk(demux, encoded.fragments[0U].data(),
                   encoded.fragments[0U].size(), routed) &&
            ledger.accept_decoder_fragment(decoder, routed, decoded, 2U) ==
                R19BulkRxTailLedgerStatus::EvidenceMismatch &&
            ledger.fail_closed(),
        "mutated VCB1 tag did not fail closed");
  }
  {
    constexpr std::uint32_t tag = 0x22334455U;
    R19BulkRxTailLedger ledger{};
    BulkDataStreamDecoder decoder{tag};
    TddLinkDemux demux{false, BulkDataRouteMode::Enabled};
    EncodedBulkDataFrame encoded{};
    checks.expect(ledger.arm(tag, 1U) == R19BulkRxTailLedgerStatus::Armed &&
                      encode_bulk_data_frame(heartbeat(2U), tag, 2U, encoded) ==
                          BulkDataWireStatus::FrameReady,
                  "wrong-ordinal fixture setup failed");
    BulkDataFragment routed{};
    MavlinkFrame decoded{};
    checks.expect(
        route_bulk(demux, encoded.fragments[0U].data(),
                   encoded.fragments[0U].size(), routed) &&
            ledger.accept_decoder_fragment(decoder, routed, decoded, 2U) ==
                R19BulkRxTailLedgerStatus::EvidenceMismatch &&
            ledger.fail_closed(),
        "skipped VCB1 ordinal did not fail closed");
  }
  {
    Phase6RadioWriterArbiter writer{};
    Phase6RadioWriterLease lease{};
    constexpr Phase6HighSpeedStreamLimits limits{1U, 32U, 32U};
    checks.expect(
        writer.begin_high_speed_stream(0x501U, limits, lease) ==
                Phase6RadioWriterStatus::HighSpeedStreamLeaseGranted &&
            writer.record_high_speed_uart(lease, 0x601U, 0x701U, 0U, 32U, 1U) ==
                Phase6RadioWriterStatus::HighSpeedStreamUartRecorded &&
            writer.awaiting_physical_tail(),
        "final-tail fixture did not retain its stream lease");
    const Phase6HighSpeedStreamTailEvidence tail{lease, 0x602U, 0x701U, 0U, 1U,
                                                 32U,   true,   true,   2U};
    checks.expect(writer.observe_high_speed_stream_tail(tail, 2U) ==
                          Phase6RadioWriterStatus::FailClosed &&
                      writer.fail_closed(),
                  "mutated final action identity did not fail closed");
  }
  {
    Phase6RadioWriterArbiter writer{};
    Phase6RadioWriterLease lease{};
    constexpr Phase6HighSpeedStreamLimits limits{1U, 32U, 32U};
    checks.expect(
        writer.begin_high_speed_stream(0x502U, limits, lease) ==
                Phase6RadioWriterStatus::HighSpeedStreamLeaseGranted &&
            writer.record_high_speed_uart(lease, 0x603U, 0x703U, 0U, 32U, 1U) ==
                Phase6RadioWriterStatus::HighSpeedStreamUartRecorded,
        "AUX-only fixture did not record UART admission");
    const Phase6HighSpeedStreamTailEvidence aux_only{
        lease, 0x603U, 0x703U, 0U, 1U, 32U, true, false, 2U};
    checks.expect(writer.observe_high_speed_stream_tail(aux_only, 2U) ==
                          Phase6RadioWriterStatus::FailClosed &&
                      writer.fail_closed(),
                  "UART/AUX-only evidence was misclassified as RF tail");
  }
  {
    TerminalAckFragments mutated = terminal_fragments;
    mutated[0U][20U] ^= 0x01U;
    TerminalAckReassembler reassembler{terminal_expected};
    checks.expect(reassembler.push(mutated[0U]) ==
                          TerminalAckError::BadFragmentCrc &&
                      reassembler.failed(),
                  "mutated VCTA payload/CRC did not fail closed");
  }
  {
    const PeerCompletionReceiptFields expected{
        PeerCompletionReceiptKind::TerminalRecordConsumed,
        0x0102030405060708ULL, 0x11223344U, 0x8877665544332211ULL};
    PeerCompletionReceiptFields wrong = expected;
    ++wrong.transfer_tag;
    PeerCompletionReceiptFrame frame{};
    PeerCompletionReceiptLedger ledger{};
    checks.expect(PeerCompletionReceiptWireCodec::encode(wrong, frame) ==
                          PeerCompletionReceiptError::None &&
                      ledger.arm(expected, 100U, 1U) ==
                          PeerCompletionReceiptLedgerStatus::Armed &&
                      ledger.consume_peer_receipt(frame, 2U) ==
                          PeerCompletionReceiptLedgerStatus::EvidenceMismatch &&
                      ledger.fail_closed(),
                  "mutated VCRC transfer identity did not fail closed");
  }
  return checks.passed;
}

} // namespace

namespace vc_lora::test {

TestReport
run_phase6_high_speed_route_integration_test(const std::string &test_id,
                                             std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id == "IT-HS-ROUTE-E2E-001") {
    Checks checks{};
    const bool completed = run_e2e(checks);
    report.check(completed && checks.passed,
                 checks.first_failure.empty()
                     ? "R19 high-speed route did not complete"
                     : checks.first_failure);
  } else {
    report.check(false, "unknown R19 high-speed route integration test ID");
  }
  report.trace.record({0U, "host", "HS_ROUTE_E2E", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

} // namespace vc_lora::test
