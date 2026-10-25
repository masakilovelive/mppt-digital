#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

#include "../../../firmware/high_speed/high_speed_phase6_adapter.hpp"
#include "../../../firmware/high_speed/phase6_radio_writer_arbiter.hpp"
#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_link_demux.hpp"

namespace vc_lora::test {
namespace {

using experimental::GroundHighSpeedPhase6Adapter;
using experimental::HighSpeedPhase6AdapterStatus;
using experimental::HighSpeedPhase6OutputType;
using experimental::Phase6RadioTailEvidence;
using experimental::Phase6RadioWriterArbiter;
using experimental::Phase6RadioWriterLease;
using experimental::Phase6RadioWriterOwner;
using experimental::Phase6RadioWriterStatus;
using experimental::Phase6RadioWriterUartResult;

constexpr std::uint32_t kCycleCount = 100U;
constexpr std::uint64_t kCyclePeriodMs = 1'000U;
constexpr std::uint16_t kGrantSession = 0x4242U;

enum class StandbyVerdict : std::uint8_t {
  Pass = 0U,
  RxZero,
  ProtocolFailure,
};

struct StandbyEvidence final {
  StandbyVerdict verdict{StandbyVerdict::ProtocolFailure};
  std::uint32_t cycles{0U};
  std::uint32_t heartbeat_rx{0U};
  std::uint32_t grant_ready{0U};
  std::uint32_t standard_tail_released{0U};
  std::uint32_t product_route_events{0U};
  std::uint32_t ground_usb_pass_through{0U};
  std::uint64_t elapsed_ms{0U};
  bool adapter_fail_closed{false};
  bool writer_fail_closed{false};
  bool writer_idle{false};
  bool standard_uplink_held{false};
};

GroundBulkSessionConfig candidate_ground_config() noexcept {
  GroundBulkSessionConfig config{};
  config.feature = BulkSessionFeature::Enabled;
  config.ground_boot_id = 0x10203040U;
  config.ground_session_id = 0x5060U;
  config.request_sequence = 0x1020U;
  config.ground_nonce = 0x0102030405060708ULL;
  return config;
}

MavlinkFrame heartbeat(std::uint8_t sequence, std::uint8_t system_id,
                       std::uint8_t component_id) noexcept {
  constexpr std::array<std::uint8_t, 9U> payload{
      0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U};
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, system_id, component_id, 0U,
                          payload.data(), payload.size(), frame);
  return frame;
}

void note_product_route(const TddDemuxEvent& event,
                        StandbyEvidence& evidence) noexcept {
  if (event.has_bulk_negotiation || event.has_bulk_data ||
      event.has_terminal_ack || event.has_peer_completion_receipt) {
    ++evidence.product_route_events;
  }
}

bool deliver_standard_heartbeat(TddLinkDemux& demux,
                                MavlinkStreamParser& parser,
                                const MavlinkFrame& frame,
                                StandbyEvidence& evidence) noexcept {
  const EncodedLinkDataChunk encoded =
      encode_link_data(frame.bytes.data(), frame.size);
  if (encoded.input_consumed != frame.size ||
      encoded.wire_size != kLinkDataMaxWireBytes) {
    return false;
  }

  for (std::size_t index = 0U; index < encoded.wire_size; ++index) {
    const TddDemuxEvent event = demux.push(encoded.wire_bytes[index]);
    note_product_route(event, evidence);
    if (event.has_control || event.has_bulk_negotiation ||
        event.has_bulk_data || event.has_terminal_ack ||
        event.has_peer_completion_receipt) {
      return false;
    }
    for (std::size_t local = 0U; local < event.local_size; ++local) {
      MavlinkFrame decoded{};
      const MavlinkParseStatus status =
          parser.push(event.local_bytes[local], decoded);
      if (status == MavlinkParseStatus::FrameReady) {
        if (decoded.message_id != 0U || decoded.system_id != 1U ||
            decoded.component_id != 1U) {
          return false;
        }
        ++evidence.heartbeat_rx;
      } else if (status != MavlinkParseStatus::NeedMore) {
        return false;
      }
    }
  }
  return true;
}

bool deliver_standard_grant(TddLinkDemux& demux,
                            GroundHighSpeedPhase6Adapter& adapter,
                            std::uint16_t cycle_id, std::uint64_t now_ms,
                            StandbyEvidence& evidence) noexcept {
  TddControlMessage grant{};
  grant.version = kTddProtocolVersion;
  grant.type = ControlType::UlGrant;
  grant.session_id = kGrantSession;
  grant.cycle_id = cycle_id;
  grant.guard_ms = 650U;
  grant.window_ms = 300U;
  grant.max_bytes = 64U;

  std::array<std::uint8_t, kTddControlFrameSize> wire{};
  std::size_t wire_size = 0U;
  if (!encode_control(grant, wire.data(), wire.size(), wire_size) ||
      wire_size != wire.size()) {
    return false;
  }

  bool observed = false;
  for (std::size_t index = 0U; index < wire_size; ++index) {
    const TddDemuxEvent event = demux.push(wire[index]);
    note_product_route(event, evidence);
    if (event.local_size != 0U || event.has_bulk_negotiation ||
        event.has_bulk_data || event.has_terminal_ack ||
        event.has_peer_completion_receipt) {
      return false;
    }
    if (!event.has_control) {
      continue;
    }
    if (observed || event.control.status != DecodeStatus::Message ||
        event.control.message.type != ControlType::UlGrant ||
        event.control.message.session_id != kGrantSession ||
        event.control.message.cycle_id != cycle_id ||
        adapter.observe_standard_grant(
            event.control.message.session_id,
            event.control.message.cycle_id, now_ms) !=
            HighSpeedPhase6AdapterStatus::Ready) {
      return false;
    }
    observed = true;
    ++evidence.grant_ready;
  }
  return observed;
}

bool complete_standard_writer_cycle(Phase6RadioWriterArbiter& writer,
                                    std::uint32_t action_token,
                                    std::uint64_t accepted_ms,
                                    StandbyEvidence& evidence) noexcept {
  Phase6RadioWriterLease lease{};
  if (writer.request(Phase6RadioWriterOwner::StandardTdd, action_token,
                     lease) != Phase6RadioWriterStatus::LeaseGranted ||
      !lease.valid() ||
      writer.complete_uart(lease, Phase6RadioWriterUartResult::Accepted,
                           accepted_ms) !=
          Phase6RadioWriterStatus::AcceptedAwaitingTail ||
      !writer.awaiting_physical_tail()) {
    return false;
  }

  const std::uint64_t tail_ms = accepted_ms + 1U;
  if (writer.observe_physical_tail(
          Phase6RadioTailEvidence{lease, true, tail_ms}, tail_ms) !=
          Phase6RadioWriterStatus::TailReleased ||
      !writer.can_poll_standard() || writer.write_active() ||
      writer.awaiting_physical_tail()) {
    return false;
  }
  ++evidence.standard_tail_released;
  return true;
}

StandbyEvidence run_standard_standby(bool drop_all_downlink) noexcept {
  GroundHighSpeedPhase6Adapter adapter{candidate_ground_config()};
  Phase6RadioWriterArbiter writer{};
  TddLinkDemux radio_demux{true, BulkDataRouteMode::Disabled};
  MavlinkStreamParser radio_parser{};
  StandbyEvidence evidence{};

  bool protocol_ok = true;
  for (std::uint32_t cycle = 0U; cycle < kCycleCount && protocol_ok; ++cycle) {
    const std::uint64_t base_ms =
        static_cast<std::uint64_t>(cycle) * kCyclePeriodMs;
    const MavlinkFrame vehicle_heartbeat =
        heartbeat(static_cast<std::uint8_t>(cycle), 1U, 1U);
    if (!drop_all_downlink) {
      protocol_ok = deliver_standard_heartbeat(
          radio_demux, radio_parser, vehicle_heartbeat, evidence);
    }

    // The product bridge offers each validated USB frame to the enabled R19
    // adapter first. A normal GCS Heartbeat (no #21) must pass through without
    // selecting or freezing the candidate route.
    const MavlinkFrame gcs_heartbeat = heartbeat(
        static_cast<std::uint8_t>(cycle + 1U), 255U, 190U);
    if (protocol_ok &&
        adapter.on_ground_usb_frame(gcs_heartbeat, 0U, base_ms + 10U) ==
            HighSpeedPhase6AdapterStatus::PassThrough) {
      ++evidence.ground_usb_pass_through;
    } else {
      protocol_ok = false;
    }
    if (protocol_ok &&
        adapter.poll(base_ms + 11U).type !=
            HighSpeedPhase6OutputType::None) {
      protocol_ok = false;
    }

    const std::uint16_t cycle_id =
        static_cast<std::uint16_t>(cycle + 1U);
    protocol_ok = protocol_ok &&
                  deliver_standard_grant(radio_demux, adapter, cycle_id,
                                         base_ms + 20U, evidence) &&
                  complete_standard_writer_cycle(writer, cycle + 1U,
                                                 base_ms + 30U, evidence);
    if (protocol_ok &&
        adapter.tick(base_ms + 40U) !=
            HighSpeedPhase6AdapterStatus::NoAction) {
      protocol_ok = false;
    }
    ++evidence.cycles;
  }

  evidence.elapsed_ms =
      static_cast<std::uint64_t>(evidence.cycles) * kCyclePeriodMs;
  evidence.adapter_fail_closed = adapter.fail_closed();
  evidence.writer_fail_closed = writer.fail_closed();
  evidence.writer_idle = writer.can_poll_standard() &&
                         !writer.write_active() &&
                         !writer.awaiting_physical_tail();
  evidence.standard_uplink_held = adapter.hold_standard_uplink();

  if (!protocol_ok || evidence.cycles != kCycleCount ||
      evidence.grant_ready != kCycleCount ||
      evidence.standard_tail_released != kCycleCount ||
      evidence.product_route_events != 0U ||
      evidence.ground_usb_pass_through != kCycleCount ||
      evidence.adapter_fail_closed || evidence.writer_fail_closed ||
      !evidence.writer_idle || evidence.standard_uplink_held ||
      radio_demux.buffered_size() != 0U ||
      radio_parser.buffered_size() != 0U) {
    evidence.verdict = StandbyVerdict::ProtocolFailure;
  } else if (evidence.heartbeat_rx == 0U) {
    evidence.verdict = StandbyVerdict::RxZero;
  } else if (evidence.heartbeat_rx != kCycleCount) {
    evidence.verdict = StandbyVerdict::ProtocolFailure;
  } else {
    evidence.verdict = StandbyVerdict::Pass;
  }
  return evidence;
}

void test_candidate_standard_path(TestReport& report) {
  const StandbyEvidence injected = run_standard_standby(true);
  report.check(
      injected.verdict == StandbyVerdict::RxZero &&
          injected.heartbeat_rx == 0U &&
          injected.grant_ready == kCycleCount &&
          injected.standard_tail_released == kCycleCount &&
          !injected.adapter_fail_closed && !injected.writer_fail_closed,
      "RX0 fault injection was not detected independently of the healthy "
      "Grant/writer path");

  const StandbyEvidence normal = run_standard_standby(false);
  report.check(
      normal.verdict == StandbyVerdict::Pass &&
          normal.cycles == kCycleCount &&
          normal.elapsed_ms >= 40'000U &&
          normal.heartbeat_rx == kCycleCount &&
          normal.grant_ready == kCycleCount &&
          normal.standard_tail_released == kCycleCount &&
          normal.product_route_events == 0U &&
          normal.ground_usb_pass_through == kCycleCount &&
          !normal.adapter_fail_closed && !normal.writer_fail_closed &&
          normal.writer_idle && !normal.standard_uplink_held,
      "enabled R19 candidate disturbed the no-#21 standard Heartbeat/Grant "
      "path");

  report.cycles = normal.cycles;
  report.diagnostics.heartbeat_valid = normal.heartbeat_rx;
  report.diagnostics.grant_rx = normal.grant_ready;
  report.detail =
      "candidate=enabled no_param_request_list=true cycles=" +
      std::to_string(normal.cycles) +
      " elapsed_ms=" + std::to_string(normal.elapsed_ms) +
      " heartbeat_rx=" + std::to_string(normal.heartbeat_rx) +
      " grant_ready=" + std::to_string(normal.grant_ready) +
      " standard_tail_released=" +
      std::to_string(normal.standard_tail_released) +
      " product_route_events=" +
      std::to_string(normal.product_route_events) +
      " injected_verdict=RX0";
}

}  // namespace

TestReport run_r19_candidate_standard_path_test(const std::string& test_id,
                                                std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id == "IT-HS-CANDIDATE-STANDARD-001") {
    test_candidate_standard_path(report);
  } else {
    report.check(false, "unknown R19 candidate standard-path test ID");
  }
  return report;
}

}  // namespace vc_lora::test
