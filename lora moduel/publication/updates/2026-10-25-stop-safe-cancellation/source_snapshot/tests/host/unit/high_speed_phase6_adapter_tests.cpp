#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <sstream>
#include <string>
#include <type_traits>

#include "../../../firmware/high_speed/high_speed_phase6_adapter.hpp"
#include "vc_lora/bulk_data_codec.hpp"
#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/mavlink_frame.hpp"

namespace vc_lora::test {
namespace {

using experimental::GroundHighSpeedPhase6Adapter;
using experimental::GroundUsbHostCommitEvent;
using experimental::GroundTerminalAckProducer;
using experimental::HighSpeedPhase6AdapterStatus;
using experimental::HighSpeedPhase6Output;
using experimental::HighSpeedPhase6OutputType;
using experimental::TerminalAckExpectedEvidence;
using experimental::TerminalAckFragment;
using experimental::TerminalAckFragments;
using experimental::TerminalAckReassembler;
using experimental::TerminalAckRecord;
using experimental::TerminalAckWireCodec;
using experimental::VehicleTerminalAckExpectedFactory;
using experimental::VehicleHighSpeedPhase6Adapter;

constexpr std::uint16_t kGrantSession = 0x4242U;
constexpr std::uint16_t kBaselineCycle = 11U;
constexpr std::uint16_t kFreshCycle = 12U;
constexpr std::uint64_t kUsbLossEpoch = 7U;

GroundBulkSessionConfig ground_config(
    BulkSessionFeature feature = BulkSessionFeature::Enabled) noexcept {
  GroundBulkSessionConfig config{};
  config.feature = feature;
  config.ground_boot_id = 0x10203040U;
  config.ground_session_id = 0x5060U;
  config.request_sequence = 0x1020U;
  config.ground_nonce = 0x0102030405060708ULL;
  return config;
}

VehicleBulkSessionConfig vehicle_config(
    BulkSessionFeature feature = BulkSessionFeature::Enabled) noexcept {
  VehicleBulkSessionConfig config{};
  config.feature = feature;
  config.vehicle_boot_id = 0x90A0B0C0U;
  config.lease_sequence = 0x3040U;
  config.vehicle_challenge_nonce = 0x1112131415161718ULL;
  config.mavlink_sequence = 0x55U;
  config.mavlink_system_id = 255U;
  config.mavlink_component_id = 190U;
  return config;
}

MavlinkFrame parameter_request_list() {
  constexpr std::array<std::uint8_t, 2U> payload{{1U, 1U}};
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(0x44U, 255U, 190U, 21U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame parameter_value(std::uint16_t parameter_index) {
  std::array<std::uint8_t, 25U> payload{};
  payload[4U] = static_cast<std::uint8_t>(
      BulkSessionAccounting::parameter_count & 0xFFU);
  payload[5U] = static_cast<std::uint8_t>(
      (BulkSessionAccounting::parameter_count >> 8U) & 0xFFU);
  payload[6U] = static_cast<std::uint8_t>(parameter_index & 0xFFU);
  payload[7U] = static_cast<std::uint8_t>(parameter_index >> 8U);
  constexpr char id[] = "ADAPTER_FINAL";
  for (std::size_t index = 0U; index < sizeof(id) - 1U; ++index) {
    payload[8U + index] = static_cast<std::uint8_t>(id[index]);
  }
  payload[24U] = 9U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(0x31U, 1U, 1U, 22U, payload.data(),
                          payload.size(), frame);
  return frame;
}

TddControlMessage fresh_grant() noexcept {
  TddControlMessage grant{};
  grant.version = kTddProtocolVersion;
  grant.type = ControlType::UlGrant;
  grant.session_id = kGrantSession;
  grant.cycle_id = kFreshCycle;
  grant.guard_ms = 2U;
  grant.window_ms = 300U;
  grant.max_bytes = 64U;
  return grant;
}

MavlinkFrame heartbeat(std::uint8_t sequence = 0x30U) {
  constexpr std::array<std::uint8_t, 9U> payload{{
      0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U}};
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 1U, 1U, 0U, payload.data(),
                          payload.size(), frame);
  return frame;
}

BulkDataStreamStatus feed_fragment(BulkDataStreamDecoder& decoder,
                                   const BulkDataFragment& fragment,
                                   MavlinkFrame& output) {
  BulkDataStreamStatus status = BulkDataStreamStatus::NeedMore;
  for (const std::uint8_t byte : fragment) {
    status = decoder.push_byte(byte, output);
  }
  return status;
}

bool feed_frame(BulkDataStreamDecoder& decoder, const MavlinkFrame& frame,
                std::uint16_t& ordinal, MavlinkFrame& output) {
  EncodedBulkDataFrame encoded{};
  if (encode_bulk_data_frame(frame, decoder.expected_transfer_tag(), ordinal,
                             encoded) != BulkDataWireStatus::FrameReady) {
    return false;
  }
  const BulkDataStreamStatus head =
      feed_fragment(decoder, encoded.fragments[0U], output);
  const BulkDataStreamStatus tail =
      feed_fragment(decoder, encoded.fragments[1U], output);
  ordinal = static_cast<std::uint16_t>(ordinal + 2U);
  return head == BulkDataStreamStatus::FragmentAccepted &&
         tail == BulkDataStreamStatus::FrameReady;
}

TerminalAckRecord terminal_record_from_expected(
    const TerminalAckExpectedEvidence& expected) noexcept {
  TerminalAckRecord record{};
  record.record_id = expected.expected_record_id;
  record.identity = expected.identity;
  record.final_parameter_count = expected.final_parameter_count;
  record.final_global_chunk_ordinal =
      expected.final_global_chunk_ordinal;
  record.raw_mavlink_bytes = expected.raw_mavlink_bytes;
  record.wire_chunk_count = expected.wire_chunk_count;
  record.wire_bytes = expected.wire_bytes;
  record.request_to_last_parameter_elapsed_ms = 1'833U;
  record.heartbeat_count = expected.heartbeat_count;
  record.last_heartbeat_request_id = expected.last_heartbeat_request_id;
  record.first_heartbeat_gap_ms = 900U;
  record.max_heartbeat_gap_ms = 900U;
  record.post_heartbeat_gap_ms = 933U;
  record.receiver_batch = expected.receiver_batch;
  record.receiver_revision = expected.receiver_revision;
  record.transcript_digest = expected.transcript_digest;
  return record;
}

bool same_output_bytes(const HighSpeedPhase6Output& lhs,
                       const HighSpeedPhase6Output& rhs) noexcept {
  if (lhs.size != rhs.size || lhs.semantic != rhs.semantic) {
    return false;
  }
  for (std::size_t index = 0U; index < lhs.size; ++index) {
    if (lhs.bytes[index] != rhs.bytes[index]) {
      return false;
    }
  }
  return true;
}

HighSpeedStandardGrantEvidence standard_grant_tail(
    std::uint64_t completed_ms) noexcept {
  HighSpeedStandardGrantEvidence evidence{};
  evidence.grant_session_id = kGrantSession;
  evidence.grant_cycle_id = kFreshCycle;
  evidence.writer_token = 0xA101U;
  evidence.writer_generation = 0xB101U;
  evidence.accepted = true;
  evidence.physical_tail_complete = true;
  evidence.completed_ms = completed_ms;
  return evidence;
}

HighSpeedLocalRxRecordIdentity final_local_rx_record(
    std::uint32_t transfer_tag, std::uint32_t final_wire_ordinal,
    std::uint32_t fragment_count) noexcept {
  HighSpeedLocalRxRecordIdentity identity{};
  identity.transfer_tag = transfer_tag;
  identity.final_wire_ordinal = final_wire_ordinal;
  identity.fragment_count = fragment_count;
  identity.rx_record_token = 0xCC01U;
  identity.rx_ledger_generation = 0xDD01U;
  return identity;
}

bool prepare_ground_bulk(GroundHighSpeedPhase6Adapter& ground,
                         VehicleBulkSessionController& responder,
                         TestReport& report, std::uint64_t t0 = 100U) {
  const MavlinkFrame list = parameter_request_list();
  report.check(
      ground.observe_standard_grant(kGrantSession, kBaselineCycle,
                                    t0 - 10U) ==
              HighSpeedPhase6AdapterStatus::Ready &&
          ground.on_ground_usb_frame(list, kUsbLossEpoch, t0) ==
               HighSpeedPhase6AdapterStatus::Held &&
          ground.on_fresh_grant(kGrantSession, kFreshCycle, t0 + 1U) ==
              HighSpeedPhase6AdapterStatus::Ready &&
          ground.poll(t0 + 100U).type == HighSpeedPhase6OutputType::None,
      "Ground adapter did not hold #21 and stage VCBN under a fresh Grant");
  HighSpeedPhase6Output request = ground.poll(t0 + 101U);
  report.check(
      request.type == HighSpeedPhase6OutputType::RadioWrite &&
          request.semantic == HighSpeedActionType::SendNegotiationRequest &&
          request.writer_generation != 0U &&
          responder.arm_fresh_grant(kGrantSession, kFreshCycle, t0 + 101U) ==
              BulkSessionResult::GrantArmed &&
          ground.complete_output(request.token, TxResult::Accepted,
                                 t0 + 102U) ==
              HighSpeedPhase6AdapterStatus::Accepted &&
          ground.on_radio_tail(
              HighSpeedTailDrainEvidence{request.token, true, t0 + 103U},
              t0 + 103U) == HighSpeedPhase6AdapterStatus::TailAccepted &&
          responder.on_terminal_request(request.bytes.data(), request.size,
                                        t0 + 104U) ==
              BulkSessionResult::NegotiationResponseReady,
      "Ground VCBN request was not accepted/drained by both owners");
  if (!report.passed) {
    return false;
  }
  const BulkNegotiationFrame* response = responder.pending_response_record();
  report.check(
      response != nullptr &&
          ground.on_negotiation_response(response->data(), response->size(),
                                         t0 + 105U) ==
              HighSpeedPhase6AdapterStatus::BulkEnabled,
      "Ground adapter did not enable VCB1 after correlated VCBN response");
  return report.passed;
}

bool prepare_vehicle_bulk(VehicleHighSpeedPhase6Adapter& vehicle,
                          BulkNegotiationFrame& request_record,
                          TestReport& report, std::uint64_t ready_ms = 100U) {
  GroundBulkSessionController requester{ground_config()};
  const MavlinkFrame list = parameter_request_list();
  report.check(
      requester.observe_standard_grant(kGrantSession, kBaselineCycle,
                                       ready_ms - 10U) ==
              BulkSessionResult::GrantBaselineCaptured &&
          requester.on_ground_usb_frame(list, ready_ms) ==
              BulkSessionResult::ParameterRequestHeld &&
          requester.on_fresh_grant(kGrantSession, kFreshCycle,
                                   ready_ms + 1U) ==
              BulkSessionResult::NegotiationRequestReady,
      "Vehicle fixture could not create canonical VCBN request");
  if (!report.passed || requester.pending_request_record() == nullptr) {
    return false;
  }
  request_record = *requester.pending_request_record();
  report.check(
      vehicle.on_negotiation_request_with_retained_grant(
          fresh_grant(), standard_grant_tail(ready_ms + 1U),
          request_record.data(), request_record.size(), ready_ms + 4U) ==
              HighSpeedPhase6AdapterStatus::Ready &&
          vehicle.poll(ready_ms + 103U).type ==
              HighSpeedPhase6OutputType::None,
      "Vehicle did not atomically adopt the drained Grant at VCBN arrival");
  if (!report.passed) {
    return false;
  }
  HighSpeedPhase6Output response = vehicle.poll(ready_ms + 104U);
  report.check(
      response.semantic == HighSpeedActionType::SendNegotiationResponse &&
          response.writer_generation != 0U &&
          vehicle.complete_output(response.token, TxResult::Accepted,
                                  ready_ms + 105U) ==
              HighSpeedPhase6AdapterStatus::Accepted &&
          vehicle.poll(ready_ms + 105U).type ==
              HighSpeedPhase6OutputType::None &&
          vehicle.on_radio_tail(
              HighSpeedTailDrainEvidence{response.token, true,
                                         ready_ms + 106U},
              ready_ms + 106U) ==
              HighSpeedPhase6AdapterStatus::TailAccepted,
      "Vehicle exposed Pixhawk #21 before response accept+tail fences");
  HighSpeedPhase6Output pixhawk = vehicle.poll(ready_ms + 106U);
  MavlinkFrame validated{};
  report.check(
      pixhawk.type == HighSpeedPhase6OutputType::PixhawkWrite &&
          pixhawk.semantic ==
              HighSpeedActionType::SendPixhawkParameterRequest &&
          validate_mavlink_frame(pixhawk.bytes.data(), pixhawk.size,
                                 validated) ==
              MavlinkParseStatus::FrameReady &&
          validated.message_id == 21U &&
          vehicle.complete_output(pixhawk.token, TxResult::Accepted,
                                  ready_ms + 107U) ==
              HighSpeedPhase6AdapterStatus::AwaitPixhawkCommit &&
          !vehicle.bulk_tx_enabled() &&
          vehicle.on_pixhawk_request_tail(
              HighSpeedTailDrainEvidence{pixhawk.token, true,
                                         ready_ms + 108U},
              ready_ms + 108U) ==
              HighSpeedPhase6AdapterStatus::BulkEnabled,
      "Vehicle did not fence valid Pixhawk #21 behind its UART tail");
  return report.passed;
}

std::string read_file(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  std::ostringstream content;
  content << input.rdbuf();
  return content.str();
}

void test_disabled_and_production_isolation(TestReport& report) {
  static_assert(!std::is_copy_constructible_v<GroundHighSpeedPhase6Adapter> &&
                !std::is_move_constructible_v<GroundHighSpeedPhase6Adapter> &&
                !std::is_copy_constructible_v<VehicleHighSpeedPhase6Adapter> &&
                !std::is_move_constructible_v<VehicleHighSpeedPhase6Adapter>);
  static_assert(
      experimental::HighSpeedPhase6AdapterTiming::
          terminal_transition_timeout_ms ==
      BulkSessionTiming::terminal_transition_timeout_ms);
  GroundHighSpeedPhase6Adapter ground{ground_config(
      BulkSessionFeature::Disabled)};
  VehicleHighSpeedPhase6Adapter vehicle{vehicle_config(
      BulkSessionFeature::Disabled)};
  const MavlinkFrame list = parameter_request_list();
  report.check(
      ground.on_ground_usb_frame(list, kUsbLossEpoch, 100U) ==
              HighSpeedPhase6AdapterStatus::Disabled &&
          ground.poll(99U).type == HighSpeedPhase6OutputType::None &&
          !ground.hold_standard_uplink() &&
          vehicle.on_negotiation_request_with_retained_grant(
              fresh_grant(), standard_grant_tail(99U), nullptr, 0U, 100U) ==
              HighSpeedPhase6AdapterStatus::Disabled &&
          vehicle.poll(98U).type == HighSpeedPhase6OutputType::None,
      "Disabled adapter was not a complete NoAction path");

  GroundHighSpeedPhase6Adapter pass_through{ground_config()};
  report.check(
      pass_through.on_ground_usb_frame(heartbeat(), kUsbLossEpoch, 100U) ==
              HighSpeedPhase6AdapterStatus::PassThrough &&
          !pass_through.hold_standard_uplink() &&
          pass_through.poll(100U).type == HighSpeedPhase6OutputType::None,
      "Enabled adapter changed the standard non-#21 pass-through path");

  const std::string product_bridge = read_file(
      std::string{VC_LORA_SOURCE_ROOT} +
      "/firmware/phase6/vc_lora_phase6_bridge.hpp");
  report.check(
      !product_bridge.empty() &&
          product_bridge.find("#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 0") !=
              std::string::npos &&
          product_bridge.find("#if VC_LORA_R19_HIGH_SPEED_CANDIDATE") <
              product_bridge.find(
                  "#include \"high_speed/high_speed_phase6_adapter.hpp\"") &&
          product_bridge.find("setup_r19_high_speed_role_adapter()") !=
              std::string::npos,
      "production bridge does not keep the adapter behind the default-off "
      "R19 feature gate");

  const std::array<std::string, 2U> production_wrappers{{
      std::string{VC_LORA_SOURCE_ROOT} +
          "/vc_lora_ground_xiao_esp32s3/vc_lora_ground_xiao_esp32s3.ino",
      std::string{VC_LORA_SOURCE_ROOT} +
          "/vc_lora_vehicle_xiao_esp32s3/vc_lora_vehicle_xiao_esp32s3.ino",
  }};
  for (const std::string& path : production_wrappers) {
    const std::string text = read_file(path);
    report.check(!text.empty() &&
                     text.find("VC_LORA_R19_HIGH_SPEED_CANDIDATE") ==
                         std::string::npos &&
                     text.find("high_speed_phase6_adapter") ==
                         std::string::npos,
                 "default production wrapper opts into the R19 adapter");
  }
  const std::string adapter = read_file(
      std::string{VC_LORA_SOURCE_ROOT} +
      "/firmware/high_speed/high_speed_phase6_adapter.hpp");
  report.check(adapter.find("Arduino.h") == std::string::npos &&
                   adapter.find("std::vector") == std::string::npos &&
                   adapter.find("malloc(") == std::string::npos &&
                   adapter.find("new ") == std::string::npos,
               "adapter introduced Arduino or dynamic-allocation dependency");
}

void test_ground_hold_grant_and_retry(TestReport& report) {
  GroundHighSpeedPhase6Adapter ground{ground_config()};
  const MavlinkFrame list = parameter_request_list();
  report.check(
      ground.observe_standard_grant(kGrantSession, kBaselineCycle, 90U) ==
              HighSpeedPhase6AdapterStatus::Ready &&
          ground.on_ground_usb_frame(list, kUsbLossEpoch, 100U) ==
              HighSpeedPhase6AdapterStatus::Held &&
          ground.hold_standard_uplink() && ground.t0_ms() == 100U &&
          ground.on_fresh_grant(kGrantSession, kFreshCycle, 101U) ==
              HighSpeedPhase6AdapterStatus::Ready &&
          ground.poll(200U).type == HighSpeedPhase6OutputType::None,
      "Ground did not intercept #21 at t0 under a fresh Grant");
  HighSpeedPhase6Output first = ground.poll(201U);
  report.check(
      first.semantic == HighSpeedActionType::SendNegotiationRequest &&
          first.writer_generation != 0U &&
          ground.complete_output(first.token, TxResult::Rejected, 202U) ==
              HighSpeedPhase6AdapterStatus::RetryRetained,
      "Ground did not retain rejected VCBN");
  HighSpeedPhase6Output retry = ground.poll(202U);
  report.check(first.token != retry.token && same_output_bytes(first, retry) &&
                   retry.writer_generation != 0U &&
                   retry.writer_generation != first.writer_generation &&
                   ground.complete_output(retry.token, TxResult::Accepted,
                                          203U) ==
                        HighSpeedPhase6AdapterStatus::Accepted &&
                   ground.on_radio_tail(
                       HighSpeedTailDrainEvidence{retry.token, true, 204U},
                       204U) == HighSpeedPhase6AdapterStatus::TailAccepted,
               "Ground VCBN retry changed bytes or skipped physical tail");
}

void test_vehicle_response_pixhawk_fence(TestReport& report) {
  VehicleHighSpeedPhase6Adapter vehicle{vehicle_config()};
  BulkNegotiationFrame request{};
  (void)prepare_vehicle_bulk(vehicle, request, report);
}

void test_vehicle_bulk_tail_guard_and_terminal_window(TestReport& report) {
  VehicleHighSpeedPhase6Adapter vehicle{vehicle_config()};
  BulkNegotiationFrame request{};
  if (!prepare_vehicle_bulk(vehicle, request, report)) {
    return;
  }
  MavlinkFrameScheduler scheduler{};
  report.check(scheduler.enqueue(heartbeat(), 1'000U) ==
                   MavlinkEnqueueStatus::Queued,
               "Vehicle scheduler rejected the real heartbeat");
  for (std::uint16_t index = 0U;
       index < BulkSessionAccounting::parameter_count; ++index) {
    report.check(scheduler.enqueue(parameter_value(index), 1'001U + index) ==
                     MavlinkEnqueueStatus::Queued,
                 "Vehicle scheduler rejected an ordered PARAM_VALUE");
    if (!report.passed) {
      return;
    }
  }

  BulkDataTxLease lease{scheduler, vehicle.transfer_tag()};
  BulkTranscriptLedger sender_transcript{vehicle.identity(),
                                         vehicle.transfer_tag()};
  bool exercised_retry = false;
  for (std::uint16_t frame_number = 0U;
       frame_number <= BulkSessionAccounting::parameter_count;
       ++frame_number) {
    const MavlinkFrame source = frame_number == 0U
                                    ? heartbeat()
                                    : parameter_value(
                                          static_cast<std::uint16_t>(
                                              frame_number - 1U));
    for (std::size_t fragment_index = 0U; fragment_index < 2U;
         ++fragment_index) {
      report.check(vehicle.stage_next_bulk_fragment(lease, 210U) ==
                       HighSpeedPhase6AdapterStatus::ActionReady,
                   "Vehicle did not stage the lease-owned VCB1 fragment");
      HighSpeedPhase6Output output = vehicle.poll(210U);
      report.check(output.type == HighSpeedPhase6OutputType::RadioWrite &&
                       output.semantic ==
                           HighSpeedActionType::SendBulkFragment,
                   "Vehicle exposed a non-VCB1 action during bulk send");
      if (!exercised_retry) {
        report.check(vehicle.complete_output(output.token, TxResult::Rejected,
                                             210U) ==
                         HighSpeedPhase6AdapterStatus::RetryRetained,
                     "Vehicle did not retain the rejected lease fragment");
        const HighSpeedPhase6Output rejected = output;
        // Rejection keeps both the coordinator action and the concrete lease
        // owner active.  Retrying is therefore a direct poll, never a second
        // caller-driven staging operation.
        output = vehicle.poll(210U);
        report.check(output.token != rejected.token &&
                         same_output_bytes(output, rejected),
                     "Vehicle did not directly retry byte-identical VCB1");
        exercised_retry = true;
      }
      report.check(vehicle.complete_output(output.token, TxResult::Accepted,
                                           210U) ==
                       HighSpeedPhase6AdapterStatus::Accepted,
                   "Vehicle did not commit the correlated lease fragment");
      if (!report.passed) {
        return;
      }
    }
    report.check(sender_transcript.append(source) ==
                     BulkTranscriptStatus::EntryAccepted,
                 "Vehicle sender transcript diverged from committed VCB1");
  }
  report.check(sender_transcript.seal_session() ==
                   BulkTranscriptStatus::Sealed,
               "Vehicle sender transcript did not seal");

  const std::uint32_t final_token = vehicle.last_bulk_action_token();
  const std::uint32_t final_writer_generation =
      vehicle.last_bulk_writer_generation();
  const std::uint32_t fragment_count = lease.next_wire_ordinal();
  report.check(
      final_token != 0U && final_writer_generation != 0U &&
          fragment_count != 0U &&
          vehicle.complete_bulk_downlink(lease, 211U) ==
              HighSpeedPhase6AdapterStatus::TerminalReady &&
          vehicle.on_bulk_tail(
              HighSpeedStreamTailEvidence{
                  vehicle.transfer_tag(), fragment_count - 1U, fragment_count,
                  final_token, final_writer_generation, true, 212U},
              212U) == HighSpeedPhase6AdapterStatus::TailAccepted &&
          vehicle.poll(311U).type == HighSpeedPhase6OutputType::None,
      "Vehicle did not bind exact lease completion to the final VCB1 tail");
  HighSpeedPhase6Output open = vehicle.poll(312U);
  report.check(
      open.type == HighSpeedPhase6OutputType::OpenTerminalAckWindow &&
          vehicle.complete_output(open.token, TxResult::Rejected, 312U) ==
              HighSpeedPhase6AdapterStatus::RetryRetained,
      "Vehicle opened terminal window before guard or lost retry");
  HighSpeedPhase6Output retry = vehicle.poll(312U);
  report.check(
      retry.semantic == HighSpeedActionType::OpenTerminalAckWindow &&
          vehicle.complete_output(retry.token, TxResult::Accepted, 312U) ==
              HighSpeedPhase6AdapterStatus::WindowOpened,
      "Vehicle did not open VCTA window at the inclusive 100-ms guard boundary");

  VehicleTerminalAckExpectedFactory factory{};
  TerminalAckExpectedEvidence expected{};
  report.check(factory.make_expected(vehicle.identity(), sender_transcript,
                                     expected) ==
                   experimental::TerminalAckProducerStatus::ExpectedReady,
               "Vehicle could not derive independent VCTA expectations");
  const TerminalAckRecord record = terminal_record_from_expected(expected);
  TerminalAckFragments fragments{};
  report.check(TerminalAckWireCodec::encode(record, fragments) ==
                   experimental::TerminalAckError::None,
               "Vehicle VCTA fixture did not encode");
  TerminalAckReassembler reassembler{expected};
  for (const auto& fragment : fragments) {
    report.check(reassembler.push(fragment) ==
                     experimental::TerminalAckError::None,
                 "Vehicle rejected a correlated VCTA fragment");
  }
  report.check(reassembler.finish() == experimental::TerminalAckError::None &&
                   vehicle.on_terminal_reassembler(reassembler, 313U) ==
                       HighSpeedPhase6AdapterStatus::Complete &&
                   vehicle.complete(),
               "Vehicle rejected the fully validated current-session VCTA");
}

void test_ground_usb_t1_guard_and_vcta(TestReport& report) {
  GroundHighSpeedPhase6Adapter ground{ground_config()};
  VehicleBulkSessionController responder{vehicle_config()};
  if (!prepare_ground_bulk(ground, responder, report)) {
    return;
  }
  BulkDataStreamDecoder decoder{ground.transfer_tag()};
  BulkTranscriptLedger ground_transcript{ground.identity(),
                                         ground.transfer_tag()};
  BulkTranscriptLedger vehicle_transcript{ground.identity(),
                                          ground.transfer_tag()};
  BulkHeartbeatSlaLedger sla{ground.transfer_tag()};
  GroundTerminalAckProducer producer{};
  report.check(
      sla.capture_baseline(90U) ==
              BulkHeartbeatSlaStatus::BaselineCaptured &&
          sla.start_request(100U) == BulkHeartbeatSlaStatus::RequestStarted,
      "Ground SLA owner was not bound to the real t0 epoch");
  if (!report.passed) {
    return;
  }

  std::uint16_t ordinal = 0U;
  MavlinkFrame decoded{};
  const MavlinkFrame hb = heartbeat();
  report.check(feed_frame(decoder, hb, ordinal, decoded) &&
                   vehicle_transcript.append(hb) ==
                       BulkTranscriptStatus::EntryAccepted &&
                   ground.on_decoded_bulk_frame(decoded, ground_transcript,
                                                sla, 1'000U) ==
                       HighSpeedPhase6AdapterStatus::UsbFrameStaged,
               "Ground did not consume the decoder-owned heartbeat");
  HighSpeedPhase6Output usb = ground.poll(1'000U);
  report.check(
      usb.type == HighSpeedPhase6OutputType::GroundUsbWrite &&
          ground.complete_output(usb.token, TxResult::Accepted, 1'000U) ==
              HighSpeedPhase6AdapterStatus::AwaitUsbCommit &&
          ground.on_ground_usb_host_commit(
              GroundUsbHostCommitEvent{usb.token, kUsbLossEpoch, 1'000U}) ==
              HighSpeedPhase6AdapterStatus::UsbCommitted,
      "Ground did not bind the heartbeat USB commit to its output token");
  if (!report.passed) {
    return;
  }

  HighSpeedPhase6Output final_usb{};
  for (std::uint16_t index = 0U;
       index < BulkSessionAccounting::parameter_count; ++index) {
    const MavlinkFrame source = parameter_value(index);
    const std::uint64_t now = 1'001U + index;
    report.check(feed_frame(decoder, source, ordinal, decoded) &&
                     vehicle_transcript.append(source) ==
                         BulkTranscriptStatus::EntryAccepted,
                 "Ground decoder or independent Vehicle transcript diverged");
    if (!report.passed) {
      return;
    }
    if (index + 1U == BulkSessionAccounting::parameter_count) {
      // The receiver's RF tail precedes decoder forwarding and the
      // host-visible USB t1. The local RX ledger identity is deliberately not
      // represented as the remote Vehicle writer identity.
      const HighSpeedLocalRxRecordIdentity rx_identity =
          final_local_rx_record(
              ground.transfer_tag(),
              static_cast<std::uint32_t>(ordinal - 1U),
              static_cast<std::uint32_t>(ordinal));
      report.check(
          decoder.finish() &&
              ground.bind_final_bulk_rx_record(rx_identity, now) ==
                  HighSpeedPhase6AdapterStatus::Ready &&
              ground.on_bulk_tail(
                  HighSpeedStreamTailEvidence{
                      ground.transfer_tag(),
                      static_cast<std::uint32_t>(ordinal - 1U),
                      static_cast<std::uint32_t>(ordinal),
                      rx_identity.rx_record_token,
                      rx_identity.rx_ledger_generation, true, now},
                  now) == HighSpeedPhase6AdapterStatus::TailAccepted,
          "Ground did not latch the honest RF-tail-before-t1 boundary");
    }
    report.check(
        ground.on_decoded_bulk_frame(decoded, ground_transcript, sla, now) ==
            HighSpeedPhase6AdapterStatus::UsbFrameStaged,
        "Ground did not stage an ordered decoder-emitted PARAM_VALUE");
    usb = ground.poll(now);
    report.check(
        usb.type == HighSpeedPhase6OutputType::GroundUsbWrite &&
            ground.complete_output(usb.token, TxResult::Accepted, now) ==
                HighSpeedPhase6AdapterStatus::AwaitUsbCommit,
        "Ground did not fence PARAM_VALUE behind USB acceptance");
    if (!report.passed) {
      return;
    }
    if (index + 1U == BulkSessionAccounting::parameter_count) {
      final_usb = usb;
    } else {
      report.check(
          ground.on_ground_usb_host_commit(
              GroundUsbHostCommitEvent{usb.token, kUsbLossEpoch, now}) ==
              HighSpeedPhase6AdapterStatus::UsbCommitted,
          "Ground rejected a correlated non-final host-visible USB commit");
    }
    if (!report.passed) {
      return;
    }
  }

  constexpr std::uint64_t t1 = 1'934U;
  report.check(
      !ground.has_t1() &&
          ground.on_final_ground_usb_host_commit(
              GroundUsbHostCommitEvent{final_usb.token, kUsbLossEpoch, t1},
              decoder, ground_transcript, sla, producer) ==
              HighSpeedPhase6AdapterStatus::TerminalReady &&
          ground.has_t1() && ground.t1_ms() == t1,
      "Ground did not derive t1/VCTA from the one-shot host commit owner");
  report.check(vehicle_transcript.seal_session() ==
                   BulkTranscriptStatus::Sealed,
               "Independent Vehicle transcript did not seal");
  if (!report.passed) {
    return;
  }

  const std::uint64_t guard_ready =
      1'932U + BulkSessionTiming::direction_guard_ms;
  report.check(
      ground.poll(guard_ready - 1U).type ==
          HighSpeedPhase6OutputType::None,
      "Ground bypassed the 100-ms direction guard");

  VehicleTerminalAckExpectedFactory factory{};
  TerminalAckExpectedEvidence expected{};
  report.check(
      factory.make_expected(ground.identity(), vehicle_transcript, expected) ==
          experimental::TerminalAckProducerStatus::ExpectedReady,
      "Vehicle could not independently derive Ground VCTA expectations");
  TerminalAckReassembler reassembler{expected};
  std::uint32_t final_terminal_token = 0U;
  std::uint64_t final_terminal_accepted_ms = 0U;
  for (std::size_t index = 0U;
       index < TerminalAckWireCodec::fragment_count; ++index) {
    const std::uint64_t now = guard_ready + index;
    const HighSpeedPhase6Output terminal = ground.poll(now);
    TerminalAckFragment fragment{};
    if (terminal.size == fragment.size()) {
      std::copy_n(terminal.bytes.begin(), fragment.size(), fragment.begin());
    }
    report.check(
        terminal.type == HighSpeedPhase6OutputType::RadioWrite &&
            terminal.semantic == HighSpeedActionType::SendTerminalEvidence &&
            terminal.writer_generation != 0U &&
            terminal.size == fragment.size() &&
            reassembler.push(fragment) == experimental::TerminalAckError::None &&
            ground.complete_output(terminal.token, TxResult::Accepted, now) ==
                HighSpeedPhase6AdapterStatus::Accepted,
        "Ground changed VCTA order/bytes or rejected an accepted fragment");
    if (!report.passed) {
      return;
    }
    if (index + 1U == TerminalAckWireCodec::fragment_count) {
      final_terminal_token = terminal.token;
      final_terminal_accepted_ms = now;
      report.check(!ground.complete(),
                   "Ground completed VCTA at UART acceptance before RF tail");
    }
  }
  report.check(
      reassembler.finish() == experimental::TerminalAckError::None &&
          final_terminal_token != 0U &&
          ground.on_radio_tail(
              HighSpeedTailDrainEvidence{final_terminal_token, true,
                                         final_terminal_accepted_ms + 1U},
              final_terminal_accepted_ms + 1U) ==
              HighSpeedPhase6AdapterStatus::Complete &&
          ground.complete(),
      "Ground VCTA did not wait for its correlated final physical RF tail");
}

void test_negative_evidence_and_order_fail_closed(TestReport& report) {
  GroundHighSpeedPhase6Adapter ground{ground_config()};
  VehicleBulkSessionController responder{vehicle_config()};
  if (!prepare_ground_bulk(ground, responder, report, 200U)) {
    return;
  }
  BulkTranscriptLedger transcript{ground.identity(), ground.transfer_tag()};
  BulkHeartbeatSlaLedger sla{ground.transfer_tag()};
  report.check(
      sla.capture_baseline(190U) ==
              BulkHeartbeatSlaStatus::BaselineCaptured &&
          sla.start_request(200U) == BulkHeartbeatSlaStatus::RequestStarted &&
          ground.on_decoded_bulk_frame(parameter_value(0U), transcript, sla,
                                       306U) ==
              HighSpeedPhase6AdapterStatus::UsbFrameStaged,
      "negative Ground fixture did not stage concrete ledger-owned data");
  HighSpeedPhase6Output usb = ground.poll(306U);
  report.check(
      ground.complete_output(usb.token, TxResult::Accepted, 307U) ==
              HighSpeedPhase6AdapterStatus::AwaitUsbCommit &&
          ground.on_ground_usb_host_commit(
              GroundUsbHostCommitEvent{usb.token, kUsbLossEpoch + 1U, 308U}) ==
              HighSpeedPhase6AdapterStatus::FailClosed &&
          ground.fail_closed() &&
                   ground.poll(309U).type == HighSpeedPhase6OutputType::None,
      "Ground accepted a USB commit from a different TX-loss epoch");

  VehicleHighSpeedPhase6Adapter vehicle{vehicle_config()};
  BulkNegotiationFrame request{};
  if (!prepare_vehicle_bulk(vehicle, request, report, 300U)) {
    return;
  }
  MavlinkFrameScheduler scheduler{};
  report.check(
      scheduler.enqueue(parameter_value(0U), 410U) ==
              MavlinkEnqueueStatus::Queued,
      "negative Vehicle fixture did not enqueue PARAM_VALUE");
  BulkDataTxLease lease{scheduler, vehicle.transfer_tag()};
  report.check(vehicle.stage_next_bulk_fragment(lease, 410U) ==
                   HighSpeedPhase6AdapterStatus::ActionReady,
               "negative Vehicle fixture did not stage lease-owned VCB1");
  const HighSpeedPhase6Output action = vehicle.poll(410U);
  report.check(vehicle.complete_output(action.token + 1U, TxResult::Accepted,
                                       411U) ==
                       HighSpeedPhase6AdapterStatus::FailClosed &&
                   vehicle.fail_closed(),
               "wrong output token did not fail closed");

  // The retained standard Grant is adopted only when the complete VCBN
  // request arrives. Age 500 ms is inclusive; stale, future, zero-identity,
  // and mismatched evidence must fail closed before any response is exposed.
  VehicleHighSpeedPhase6Adapter inclusive{vehicle_config()};
  report.check(
      inclusive.on_negotiation_request_with_retained_grant(
          fresh_grant(), standard_grant_tail(100U), request.data(),
          request.size(), 600U) == HighSpeedPhase6AdapterStatus::Ready &&
          inclusive.poll(699U).type == HighSpeedPhase6OutputType::None &&
          inclusive.poll(700U).semantic ==
              HighSpeedActionType::SendNegotiationResponse,
      "adapter rejected the inclusive retained-Grant age or skipped guard");

  VehicleHighSpeedPhase6Adapter stale{vehicle_config()};
  report.check(
      stale.on_negotiation_request_with_retained_grant(
          fresh_grant(), standard_grant_tail(100U), request.data(),
          request.size(), 601U) ==
              HighSpeedPhase6AdapterStatus::FailClosed &&
          stale.fail_closed(),
      "adapter accepted retained-Grant age 501 ms");

  VehicleHighSpeedPhase6Adapter future{vehicle_config()};
  report.check(
      future.on_negotiation_request_with_retained_grant(
          fresh_grant(), standard_grant_tail(101U), request.data(),
          request.size(), 100U) == HighSpeedPhase6AdapterStatus::FailClosed &&
          future.fail_closed(),
      "adapter accepted a future retained-Grant tail");

  HighSpeedStandardGrantEvidence invalid = standard_grant_tail(100U);
  invalid.writer_token = 0U;
  VehicleHighSpeedPhase6Adapter zero_identity{vehicle_config()};
  report.check(
      zero_identity.on_negotiation_request_with_retained_grant(
          fresh_grant(), invalid, request.data(), request.size(), 200U) ==
              HighSpeedPhase6AdapterStatus::FailClosed &&
          zero_identity.fail_closed(),
      "adapter accepted zero retained-Grant writer identity");

  invalid = standard_grant_tail(100U);
  ++invalid.grant_cycle_id;
  VehicleHighSpeedPhase6Adapter mismatched{vehicle_config()};
  report.check(
      mismatched.on_negotiation_request_with_retained_grant(
          fresh_grant(), invalid, request.data(), request.size(), 200U) ==
              HighSpeedPhase6AdapterStatus::FailClosed &&
          mismatched.fail_closed(),
      "adapter accepted mismatched retained-Grant identity");

  GroundHighSpeedPhase6Adapter rx_identity_ground{ground_config()};
  VehicleBulkSessionController rx_identity_responder{vehicle_config()};
  if (!prepare_ground_bulk(rx_identity_ground, rx_identity_responder, report,
                           500U)) {
    return;
  }
  const HighSpeedLocalRxRecordIdentity bound = final_local_rx_record(
      rx_identity_ground.transfer_tag(), 1919U, 1920U);
  HighSpeedStreamTailEvidence mutated_tail{
      bound.transfer_tag,       bound.final_wire_ordinal,
      bound.fragment_count,     bound.rx_record_token + 1U,
      bound.rx_ledger_generation, true,
      700U};
  report.check(
      rx_identity_ground.bind_final_bulk_rx_record(bound, 700U) ==
              HighSpeedPhase6AdapterStatus::Ready &&
          rx_identity_ground.on_bulk_tail(mutated_tail, 700U) ==
              HighSpeedPhase6AdapterStatus::FailClosed &&
          rx_identity_ground.fail_closed(),
      "Ground adapter accepted a different local RX-ledger record identity");
}

void test_ground_negotiation_response_prevalidation_is_non_mutating(
    TestReport& report) {
  GroundHighSpeedPhase6Adapter ground{ground_config()};
  VehicleBulkSessionController responder{vehicle_config()};
  constexpr std::uint64_t t0 = 100U;
  const MavlinkFrame list = parameter_request_list();
  report.check(
      ground.observe_standard_grant(kGrantSession, kBaselineCycle, t0 - 10U) ==
              HighSpeedPhase6AdapterStatus::Ready &&
          ground.on_ground_usb_frame(list, kUsbLossEpoch, t0) ==
              HighSpeedPhase6AdapterStatus::Held &&
          ground.on_fresh_grant(kGrantSession, kFreshCycle, t0 + 1U) ==
              HighSpeedPhase6AdapterStatus::Ready,
      "Ground prevalidation fixture did not stage VCBN request");
  HighSpeedPhase6Output request = ground.poll(t0 + 101U);
  report.check(
      request.type == HighSpeedPhase6OutputType::RadioWrite &&
          responder.arm_fresh_grant(kGrantSession, kFreshCycle, t0 + 101U) ==
              BulkSessionResult::GrantArmed &&
          ground.complete_output(request.token, TxResult::Accepted,
                                 t0 + 102U) ==
              HighSpeedPhase6AdapterStatus::Accepted &&
          responder.on_terminal_request(request.bytes.data(), request.size,
                                        t0 + 102U) ==
              BulkSessionResult::NegotiationResponseReady,
      "Ground prevalidation fixture did not retain committed request");
  const BulkNegotiationFrame* response = responder.pending_response_record();
  if (!report.passed || response == nullptr) {
    report.check(false, "Ground prevalidation fixture has no VCBN response");
    return;
  }

  constexpr std::uint64_t validation_ms = t0 + 103U;
  report.check(
      ground.prevalidate_negotiation_response(
          response->data(), response->size(), validation_ms) &&
          ground.prevalidate_negotiation_response(
              response->data(), response->size(), validation_ms) &&
          ground.coordinator_state() == GroundHighSpeedTddState::RequestDrain &&
          ground.transfer_tag() == 0U && !ground.fail_closed(),
      "valid VCBN prevalidation mutated or rejected the pre-tail state");

  BulkNegotiationFrame bad_crc = *response;
  bad_crc[8U] ^= 0x01U;
  BulkNegotiationResponse decoded{};
  report.check(
      !ground.prevalidate_negotiation_response(
          bad_crc.data(), bad_crc.size(), validation_ms) &&
          BulkNegotiationWireCodec::decode_response(*response, decoded) ==
              BulkNegotiationWireStatus::FrameReady,
      "CRC-bad VCBN response passed non-mutating prevalidation");

  BulkNegotiationFrame wrong_tag{};
  ++decoded.request_tag;
  report.check(
      BulkNegotiationWireCodec::encode_response(decoded, wrong_tag) ==
              BulkNegotiationWireStatus::FrameReady &&
          !ground.prevalidate_negotiation_response(
              wrong_tag.data(), wrong_tag.size(), validation_ms),
      "wrong-request-tag VCBN passed non-mutating prevalidation");

  (void)BulkNegotiationWireCodec::decode_response(*response, decoded);
  BulkNegotiationFrame wrong_session{};
  ++decoded.vehicle_session_id;
  BulkNegotiationFrame zero_challenge = *response;
  std::fill(zero_challenge.begin() + 16U,
            zero_challenge.begin() + 24U, 0U);
  const std::uint16_t zero_challenge_crc =
      BulkNegotiationWireCodec::crc16_ccitt_false(
          zero_challenge.data(), BulkNegotiationWireCodec::integrity_offset);
  zero_challenge[30U] =
      static_cast<std::uint8_t>(zero_challenge_crc & 0xFFU);
  zero_challenge[31U] =
      static_cast<std::uint8_t>((zero_challenge_crc >> 8U) & 0xFFU);
  BulkNegotiationFrame zero_vehicle_identity = *response;
  std::fill(zero_vehicle_identity.begin() + 8U,
            zero_vehicle_identity.begin() + 12U, 0U);
  const std::uint16_t zero_identity_crc =
      BulkNegotiationWireCodec::crc16_ccitt_false(
          zero_vehicle_identity.data(),
          BulkNegotiationWireCodec::integrity_offset);
  zero_vehicle_identity[30U] =
      static_cast<std::uint8_t>(zero_identity_crc & 0xFFU);
  zero_vehicle_identity[31U] =
      static_cast<std::uint8_t>((zero_identity_crc >> 8U) & 0xFFU);
  report.check(
      BulkNegotiationWireCodec::encode_response(decoded, wrong_session) ==
              BulkNegotiationWireStatus::FrameReady &&
          !ground.prevalidate_negotiation_response(
              wrong_session.data(), wrong_session.size(), validation_ms) &&
          !ground.prevalidate_negotiation_response(
              zero_challenge.data(), zero_challenge.size(), validation_ms) &&
          !ground.prevalidate_negotiation_response(
              zero_vehicle_identity.data(), zero_vehicle_identity.size(),
              validation_ms) &&
          !ground.prevalidate_negotiation_response(nullptr, response->size(),
                                                   validation_ms) &&
          !ground.prevalidate_negotiation_response(
              response->data(), response->size() - 1U, validation_ms) &&
          ground.coordinator_state() == GroundHighSpeedTddState::RequestDrain &&
          ground.transfer_tag() == 0U && !ground.fail_closed(),
      "invalid VCBN prevalidation changed Ground request state");

  report.check(
      ground.on_radio_tail(
          HighSpeedTailDrainEvidence{request.token, true, validation_ms},
          validation_ms) == HighSpeedPhase6AdapterStatus::TailAccepted &&
          ground.on_negotiation_response(response->data(), response->size(),
                                         validation_ms) ==
              HighSpeedPhase6AdapterStatus::BulkEnabled &&
          ground.transfer_tag() != 0U,
      "non-mutating prevalidation consumed the later stateful VCBN path");
}

}  // namespace

TestReport run_high_speed_phase6_adapter_test(const std::string& test_id,
                                              std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-HS-PHASE6-ADAPTER-001") {
    test_disabled_and_production_isolation(report);
  } else if (test_id == "UT-HS-PHASE6-ADAPTER-002") {
    test_ground_hold_grant_and_retry(report);
  } else if (test_id == "UT-HS-PHASE6-ADAPTER-003") {
    test_vehicle_response_pixhawk_fence(report);
  } else if (test_id == "UT-HS-PHASE6-ADAPTER-004") {
    test_vehicle_bulk_tail_guard_and_terminal_window(report);
  } else if (test_id == "UT-HS-PHASE6-ADAPTER-005") {
    test_ground_usb_t1_guard_and_vcta(report);
  } else if (test_id == "UT-HS-PHASE6-ADAPTER-006") {
    test_negative_evidence_and_order_fail_closed(report);
  } else if (test_id == "UT-HS-PHASE6-ADAPTER-007") {
    test_ground_negotiation_response_prevalidation_is_non_mutating(report);
  } else {
    report.check(false, "unknown high-speed Phase6 adapter test ID");
  }

  report.trace.record({0U, "host", "HS_PHASE6_ADAPTER", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
