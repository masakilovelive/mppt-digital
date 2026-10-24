#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

#include "vc_lora/embedded_io_adapter.hpp"
#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tdd_ground.hpp"
#include "vc_lora/tdd_link_demux.hpp"

namespace vc_lora::test {
namespace {

struct MockUsbWriter {
  int available{256};
  std::size_t write_calls{0U};
  std::array<std::uint8_t, 64U> accepted{};
  std::size_t accepted_size{0U};

  int availableForWrite() const noexcept { return available; }

  std::size_t write(const std::uint8_t* bytes,
                    std::size_t count) noexcept {
    ++write_calls;
    const std::size_t copied =
        std::min(count, accepted.size() - accepted_size);
    std::copy_n(bytes, copied, accepted.data() + accepted_size);
    accepted_size += copied;
    return copied;
  }
};

MavlinkFrame make_heartbeat(std::uint8_t sequence, TestReport& report) {
  constexpr std::array<std::uint8_t, 9> payload{
      {0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U}};
  MavlinkFrame frame{};
  report.check(encode_mavlink_v2(sequence, 1U, 1U, 0U, payload.data(),
                                 payload.size(), frame),
               "failed to construct adapter heartbeat fixture");
  return frame;
}

FrameIngressStatus ingest_frame(GroundMavlinkIngressAdapter& adapter,
                                 const MavlinkFrame& frame,
                                 TestReport& report,
                                 bool check_prefix_atomicity = false) {
  FrameIngressStatus status = FrameIngressStatus::NeedMore;
  for (std::size_t index = 0; index < frame.size; ++index) {
    status = adapter.ingest_byte(frame.bytes[index]);
    if (check_prefix_atomicity && index + 1U < frame.size) {
      report.check(adapter.queued_bytes() == 0U,
                   "partial MAVLink frame became visible to RF output");
      report.check(adapter.queued_frames() == 0U,
                   "partial MAVLink frame acquired a descriptor");
    }
  }
  return status;
}

template <typename Adapter>
void exercise_local_egress(Adapter& adapter, const char* side,
                           TestReport& report) {
  std::array<std::uint8_t, 96> first{};
  std::array<std::uint8_t, 32> later{};
  for (std::size_t index = 0; index < first.size(); ++index) {
    first[index] = static_cast<std::uint8_t>((index * 31U + 7U) & 0xFFU);
  }
  for (std::size_t index = 0; index < later.size(); ++index) {
    later[index] = static_cast<std::uint8_t>(0xD0U + index);
  }

  report.check(adapter.ingest(first.data(), first.size()) == first.size(),
               std::string(side) + " local egress rejected initial data");

  std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> initial_prefix{};
  const std::size_t initial_size =
      adapter.peek(initial_prefix.data(), initial_prefix.size());
  report.check(initial_size == initial_prefix.size(),
               std::string(side) + " did not stage a 32-byte prefix");
  report.check(std::equal(initial_prefix.begin(), initial_prefix.end(),
                          first.begin()),
               std::string(side) + " staged the wrong prefix");

  report.check(adapter.complete_write(0U) == UartWriteProgress::Zero,
               std::string(side) + " zero write was not retained");
  std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> retry{};
  report.check(adapter.peek(retry.data(), retry.size()) == retry.size() &&
                   retry == initial_prefix,
               std::string(side) +
                   " zero-write retry did not reproduce the same prefix");

  report.check(adapter.complete_write(7U) == UartWriteProgress::Partial,
               std::string(side) + " short write was not reported partial");
  report.check(adapter.queued_bytes() == first.size(),
               std::string(side) +
                   " source bytes were consumed before the prefix completed");
  report.check(adapter.ingest(later.data(), later.size()) == later.size(),
               std::string(side) +
                   " ingress stopped while a short write was pending");

  std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> suffix{};
  const std::size_t suffix_size = adapter.peek(suffix.data(), suffix.size());
  report.check(suffix_size == 25U,
               std::string(side) + " short-write suffix size is not 25");
  report.check(std::equal(suffix.begin(), suffix.begin() + 25U,
                          first.begin() + 7U),
               std::string(side) + " short-write retry changed the suffix");
  report.check(adapter.complete_write(9U) == UartWriteProgress::Partial,
               std::string(side) + " second short write was not partial");
  const std::size_t final_suffix_size =
      adapter.peek(suffix.data(), suffix.size());
  report.check(final_suffix_size == 16U &&
                   std::equal(suffix.begin(), suffix.begin() + 16U,
                              first.begin() + 16U),
               std::string(side) + " second retry changed the suffix");
  report.check(adapter.complete_write(final_suffix_size) ==
                   UartWriteProgress::Complete,
               std::string(side) + " staged prefix did not complete");
  report.check(adapter.queued_bytes() == first.size() + later.size() - 32U,
               std::string(side) +
                   " completed prefix consumed the wrong source byte count");

  std::array<std::uint8_t, 128> drained{};
  std::copy(initial_prefix.begin(), initial_prefix.end(), drained.begin());
  std::size_t drained_size = initial_prefix.size();
  while (adapter.queued_bytes() > 0U) {
    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> chunk{};
    const std::size_t chunk_size = adapter.peek(chunk.data(), chunk.size());
    report.check(chunk_size > 0U,
                 std::string(side) + " egress stalled while data remained");
    if (chunk_size == 0U) {
      break;
    }
    std::copy_n(chunk.data(), chunk_size, drained.data() + drained_size);
    drained_size += chunk_size;
    report.check(adapter.complete_write(chunk_size) ==
                     UartWriteProgress::Complete,
                 std::string(side) + " full UART write did not commit");
  }

  std::array<std::uint8_t, 128> expected{};
  std::copy(first.begin(), first.end(), expected.begin());
  std::copy(later.begin(), later.end(), expected.begin() + first.size());
  report.check(drained_size == expected.size() && drained == expected,
               std::string(side) +
                   " short/zero writes duplicated, dropped, or reordered data");
  report.check(adapter.stats().zero_write_events == 1U &&
                   adapter.stats().short_write_events == 2U,
               std::string(side) + " UART retry diagnostics are incorrect");
  report.check(adapter.stats().bytes_committed == expected.size(),
               std::string(side) + " UART committed-byte count is incorrect");
  report.check(!adapter.fail_closed(),
               std::string(side) + " healthy retries caused fail-close");
}

void feed_validated_endpoint(TddLinkDemux& demux,
                             MavlinkValidatedLocalEgressAdapter<>& endpoint,
                             const std::uint8_t* wire,
                             std::size_t wire_size,
                             TestReport& report) {
  for (std::size_t wire_index = 0U; wire_index < wire_size; ++wire_index) {
    const TddDemuxEvent event = demux.push(wire[wire_index]);
    for (std::size_t local_index = 0U; local_index < event.local_size;
         ++local_index) {
      (void)endpoint.ingest_byte(event.local_bytes[local_index]);
    }
  }
  report.check(!endpoint.fail_closed(),
               "validated endpoint failed closed without overflow");
}

void feed_windowed_validated_endpoint(
    TddLinkDemux& demux,
    MavlinkValidatedLocalEgressAdapter<>& endpoint,
    const std::uint8_t* wire,
    std::size_t wire_size,
    bool receive_window_open,
    LinkDiagnostics& diagnostics,
    TestReport& report) {
  for (std::size_t wire_index = 0U; wire_index < wire_size; ++wire_index) {
    const TddDemuxEvent event = demux.push(wire[wire_index]);
    if (!receive_window_open && event.local_size > 0U) {
      diagnostics.uplink_data_outside_receive_window += event.local_size;
      continue;
    }
    for (std::size_t local_index = 0U; local_index < event.local_size;
         ++local_index) {
      (void)endpoint.ingest_byte(event.local_bytes[local_index]);
    }
  }
  report.check(!endpoint.fail_closed(),
               "window-gated endpoint failed closed without overflow");
}

}  // namespace

TestReport run_embedded_adapter_test(const std::string& test_id,
                                     std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "FW-BUF-001") {
    GroundMavlinkIngressAdapter adapter{};
    LinkDiagnostics tdd_diagnostics{};
    GroundTddController ground(TddConfig{}, tdd_diagnostics);
    ground.reset(0U);
    report.check(ground.state() == GroundTddState::WaitGrant,
                 "Ground did not begin in WAIT_GRANT");

    const MavlinkFrame first = make_heartbeat(1U, report);
    report.check(ingest_frame(adapter, first, report, true) ==
                     FrameIngressStatus::Queued,
                 "complete WAIT_GRANT frame was not queued");
    const MavlinkFrame second = make_heartbeat(2U, report);
    report.check(ingest_frame(adapter, second, report) ==
                     FrameIngressStatus::Queued,
                 "WAIT_GRANT did not continue ingesting frames");
    report.check(ground.state() == GroundTddState::WaitGrant,
                 "adapter ingress mutated the TDD state");
    report.check(adapter.queued_frames() == 2U &&
                     adapter.queued_bytes() == first.size + second.size,
                 "frame descriptors do not match WAIT_GRANT ingress");

    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> prefix{};
    const std::size_t prefix_size = adapter.peek(prefix.data(), prefix.size());
    report.check(prefix_size == prefix.size(),
                 "Ground ingress did not expose a bounded prefix");
    report.check(!adapter.complete_send(TxResult::Rejected, 0U),
                 "Rejected write was reported committed");
    const MavlinkFrame third = make_heartbeat(3U, report);
    report.check(ingest_frame(adapter, third, report) ==
                     FrameIngressStatus::Queued,
                 "ingress stopped while a rejected prefix was retained");
    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> retry{};
    report.check(adapter.peek(retry.data(), retry.size()) == prefix_size &&
                     retry == prefix,
                 "Rejected RF write did not retry the exact same prefix");
    report.check(adapter.complete_send(TxResult::Accepted, prefix_size),
                 "Accepted RF prefix was not committed");
    report.check(adapter.queued_bytes() ==
                     first.size + second.size + third.size - prefix_size,
                 "Accepted commit consumed the wrong application bytes");
    report.check(adapter.queued_frames() == 2U &&
                     adapter.front_frame_remaining() == 10U,
                 "frame descriptor progress is inconsistent with commit");

    // A 32-byte application lease can encode to more than 32 wire bytes when
    // it contains the VCTD lead byte or the escape byte.  The physical writer
    // must be able to accept the largest prefix that fits one 32-byte E220
    // transaction without losing the unencoded suffix of the lease.
    adapter.reset();
    std::array<std::uint8_t, 33> command_payload{};
    command_payload[0] = kLinkDataControlLeadByte;
    command_payload[1] = kLinkDataEscapeByte;
    MavlinkFrame escaped_command{};
    report.check(encode_mavlink_v2(4U, 255U, 190U, 76U,
                                   command_payload.data(),
                                   command_payload.size(), escaped_command),
                 "failed to construct escaped Ground ingress fixture");
    report.check(ingest_frame(adapter, escaped_command, report) ==
                     FrameIngressStatus::Queued,
                 "escaped Ground ingress fixture was not queued");
    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> escaped_lease{};
    const std::size_t escaped_lease_size =
        adapter.peek(escaped_lease.data(), escaped_lease.size());
    const EncodedLinkDataChunk encoded_prefix = encode_link_data(
        escaped_lease.data(), escaped_lease_size,
        kEmbeddedPhysicalWriteBytes);
    report.check(escaped_lease_size == kEmbeddedPhysicalWriteBytes &&
                     encoded_prefix.input_consumed > 0U &&
                     encoded_prefix.input_consumed < escaped_lease_size &&
                     encoded_prefix.wire_size == kEmbeddedPhysicalWriteBytes,
                 "escape fixture did not require a shorter application prefix");
    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> action_prefix{};
    const std::size_t action_prefix_size = adapter.peek(
        action_prefix.data(), encoded_prefix.input_consumed);
    report.check(action_prefix_size == encoded_prefix.input_consumed &&
                     std::equal(action_prefix.begin(),
                                action_prefix.begin() + action_prefix_size,
                                escaped_lease.begin()),
                 "preview lease could not be narrowed to the scheduled prefix");
    report.check(adapter.complete_send(TxResult::Accepted,
                                       encoded_prefix.input_consumed),
                 "accepted escaped prefix was rejected by the ingress lease");
    report.check(!adapter.fail_closed(),
                 "valid escaped-prefix commit caused fail-close");
    report.check(adapter.queued_bytes() ==
                     escaped_command.size - encoded_prefix.input_consumed &&
                     adapter.front_frame_remaining() ==
                         escaped_command.size - encoded_prefix.input_consumed,
                 "escaped-prefix commit consumed the wrong application bytes");
    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> escaped_suffix{};
    const std::size_t escaped_suffix_size =
        adapter.peek(escaped_suffix.data(), escaped_suffix.size());
    const std::size_t expected_suffix_size = std::min<std::size_t>(
        escaped_suffix.size(),
        escaped_command.size - encoded_prefix.input_consumed);
    report.check(escaped_suffix_size == expected_suffix_size &&
                     std::equal(escaped_suffix.begin(),
                                escaped_suffix.begin() + escaped_suffix_size,
                                escaped_command.bytes.begin() +
                                    encoded_prefix.input_consumed),
                 "escaped-prefix remainder was duplicated, dropped, or reordered");

    adapter.reset();
    constexpr std::size_t kFramesThatFit =
        kGroundMavlinkIngressBytes / 21U;
    for (std::size_t index = 0; index < kFramesThatFit; ++index) {
      const MavlinkFrame frame =
          make_heartbeat(static_cast<std::uint8_t>(index), report);
      report.check(ingest_frame(adapter, frame, report) ==
                       FrameIngressStatus::Queued,
                   "in-capacity frame was not atomically queued");
    }
    const std::size_t bytes_before_overflow = adapter.queued_bytes();
    const std::size_t frames_before_overflow = adapter.queued_frames();
    const MavlinkFrame overflow = make_heartbeat(0xEEU, report);
    report.check(ingest_frame(adapter, overflow, report) ==
                     FrameIngressStatus::DroppedOverflow,
                 "capacity overflow was not diagnosed");
    report.check(adapter.fail_closed(),
                 "loss of a complete frame did not latch fail-close");
    report.check(adapter.queued_bytes() == bytes_before_overflow &&
                     adapter.queued_frames() == frames_before_overflow,
                 "overflow partially inserted a MAVLink frame/descriptor");
    report.check(adapter.peek(prefix.data(), prefix.size()) == 0U,
                 "fail-closed ingress still permitted RF output");
    report.check(adapter.stats().frames_dropped == 1U &&
                     adapter.stats().bytes_dropped == overflow.size &&
                     adapter.stats().overflow_events == 1U,
                 "frame-atomic overflow accounting is incorrect");
    report.check(adapter.queued_bytes() <= kGroundMavlinkIngressBytes &&
                     adapter.queued_frames() <=
                         kGroundMavlinkDescriptorCapacity,
                 "fixed Ground adapter capacity was exceeded");
    report.diagnostics.ground_usb_rx_bytes = adapter.stats().bytes_ingested;
    report.diagnostics.ground_usb_accepted_bytes = adapter.stats().bytes_queued;
    report.diagnostics.ground_usb_dropped_bytes = adapter.stats().bytes_dropped;
    report.diagnostics.ground_usb_dequeued_bytes =
        adapter.stats().bytes_committed;
    report.diagnostics.ground_buffer_overflow_count =
        adapter.stats().overflow_events;
    report.diagnostics.max_ground_queue = adapter.stats().max_queued_bytes;
    report.detail = "GroundIngress sizeof=" +
                    std::to_string(sizeof(GroundMavlinkIngressAdapter)) +
                    " bytes; byte_capacity=16384; descriptor_capacity=" +
                    std::to_string(kGroundMavlinkDescriptorCapacity);
  } else if (test_id == "FW-UART-001") {
    LocalEgressAdapter<> vehicle{};
    LocalEgressAdapter<> ground{};
    exercise_local_egress(vehicle, "Vehicle", report);
    exercise_local_egress(ground, "Ground", report);

    LocalEgressAdapter<64U> overflow{};
    std::array<std::uint8_t, 48> first{};
    std::array<std::uint8_t, 17> too_much{};
    report.check(overflow.ingest(first.data(), first.size()) == first.size(),
                 "local overflow setup failed");
    report.check(overflow.ingest(too_much.data(), too_much.size()) == 0U,
                 "local overflow inserted a partial RF delivery");
    report.check(overflow.queued_bytes() == first.size() &&
                     overflow.fail_closed(),
                 "local overflow did not retain FIFO and fail closed");
    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> blocked{};
    report.check(overflow.peek(blocked.data(), blocked.size()) == 0U,
                 "failed-closed local egress still wrote to UART");

    // Endpoint UARTs are behind a second MAVLink parser, not directly behind
    // the VCTD demux. If the first control-magic byte is corrupted, the demux
    // deliberately treats it as application data; CRC-valid frame gating must
    // still prevent every control/noise/partial byte from reaching Pixhawk or
    // Mission Planner.
    TddLinkDemux demux(true);
    MavlinkValidatedLocalEgressAdapter<> endpoint{};
    TddControlMessage grant{};
    grant.type = ControlType::UlGrant;
    grant.session_id = 7U;
    grant.cycle_id = 9U;
    grant.guard_ms = 650U;
    grant.window_ms = 300U;
    grant.max_bytes = 64U;
    std::array<std::uint8_t, kTddControlFrameSize> damaged_control{};
    std::size_t damaged_size = 0U;
    report.check(encode_control(grant, damaged_control.data(),
                                damaged_control.size(), damaged_size),
                 "failed to construct damaged-control endpoint fixture");
    damaged_control[0] ^= 0x01U;
    feed_validated_endpoint(demux, endpoint,
                            damaged_control.data(), damaged_size, report);
    report.check(endpoint.egress().empty(),
                 "damaged control/noise bytes reached the local endpoint");

    const MavlinkFrame endpoint_heartbeat = make_heartbeat(0x44U, report);
    const std::size_t partial_size = endpoint_heartbeat.size / 2U;
    const EncodedLinkDataChunk partial_wire = encode_link_data(
        endpoint_heartbeat.bytes.data(), partial_size);
    feed_validated_endpoint(demux, endpoint,
                            partial_wire.wire_bytes.data(),
                            partial_wire.wire_size, report);
    report.check(endpoint.egress().empty(),
                 "partial MAVLink frame became visible at the local endpoint");
    const EncodedLinkDataChunk remainder_wire = encode_link_data(
        endpoint_heartbeat.bytes.data() + partial_size,
        endpoint_heartbeat.size - partial_size);
    feed_validated_endpoint(demux, endpoint,
                            remainder_wire.wire_bytes.data(),
                            remainder_wire.wire_size, report);
    report.check(endpoint.egress().queued_bytes() == endpoint_heartbeat.size,
                 "complete validated MAVLink frame was not atomically queued");
    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> endpoint_bytes{};
    const std::size_t endpoint_size =
        endpoint.egress().peek(endpoint_bytes.data(), endpoint_bytes.size());
    report.check(endpoint_size == endpoint_heartbeat.size &&
                     std::equal(endpoint_bytes.begin(),
                                endpoint_bytes.begin() + endpoint_size,
                                endpoint_heartbeat.bytes.begin()),
                 "validated endpoint changed the MAVLink frame bytes");

    // A long MAVLink frame may span two receive windows. Bytes observed while
    // the RF role is outside its receive window must be counted and skipped,
    // without resetting or contaminating the valid in-window parser prefix.
    TddLinkDemux window_demux(true);
    MavlinkValidatedLocalEgressAdapter<> window_endpoint{};
    LinkDiagnostics window_diagnostics{};
    const MavlinkFrame window_heartbeat = make_heartbeat(0x45U, report);
    const std::size_t window_prefix_size = window_heartbeat.size / 2U;
    const EncodedLinkDataChunk window_prefix = encode_link_data(
        window_heartbeat.bytes.data(), window_prefix_size);
    feed_windowed_validated_endpoint(
        window_demux, window_endpoint, window_prefix.wire_bytes.data(),
        window_prefix.wire_size, true, window_diagnostics, report);
    report.check(window_endpoint.egress().empty() &&
                     window_endpoint.parser_buffered_size() ==
                         window_prefix_size,
                 "in-window MAVLink prefix was not retained atomically");

    constexpr std::array<std::uint8_t, 3> kOutsideWindowNoise{
        {0xA5U, kLinkDataControlLeadByte, kLinkDataEscapeByte}};
    const EncodedLinkDataChunk outside_wire = encode_link_data(
        kOutsideWindowNoise.data(), kOutsideWindowNoise.size());
    feed_windowed_validated_endpoint(
        window_demux, window_endpoint, outside_wire.wire_bytes.data(),
        outside_wire.wire_size, false, window_diagnostics, report);
    report.check(window_diagnostics.uplink_data_outside_receive_window ==
                     kOutsideWindowNoise.size(),
                 "out-of-window application bytes were not counted");
    report.check(window_endpoint.parser_buffered_size() ==
                     window_prefix_size &&
                     window_endpoint.egress().empty(),
                 "out-of-window bytes contaminated the MAVLink parser");

    const EncodedLinkDataChunk window_remainder = encode_link_data(
        window_heartbeat.bytes.data() + window_prefix_size,
        window_heartbeat.size - window_prefix_size);
    feed_windowed_validated_endpoint(
        window_demux, window_endpoint, window_remainder.wire_bytes.data(),
        window_remainder.wire_size, true, window_diagnostics, report);
    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> window_output{};
    const std::size_t window_output_size = window_endpoint.egress().peek(
        window_output.data(), window_output.size());
    report.check(window_output_size == window_heartbeat.size &&
                     std::equal(window_output.begin(),
                                window_output.begin() + window_output_size,
                                window_heartbeat.bytes.begin()),
                 "next-window MAVLink remainder did not complete the exact "
                 "frame");
    report.diagnostics.uart_buffer_drop_count =
        overflow.stats().overflow_events;
    report.diagnostics.uplink_data_outside_receive_window =
        window_diagnostics.uplink_data_outside_receive_window;
    report.detail = "LocalEgress sizeof=" +
                    std::to_string(sizeof(LocalEgressAdapter<>)) +
                    " bytes; byte_capacity=4096; write_capacity=32";
  } else if (test_id == "FW-USB-DISCONNECT-001") {
    // Frames already admitted before a mid-disconnect remain in this bounded
    // queue. If it fills, only the newly completed MAVLink frame drops; it
    // must not permanently stop TDD/radio processing. Frames first observed
    // while disconnected are rejected earlier in the production path.
    using GroundUsbEndpoint = MavlinkValidatedLocalEgressAdapter<
        64U, kEmbeddedPhysicalWriteBytes,
        LocalEgressOverflowPolicy::DropNewestFrame>;

    // ESP32-S3 HWCDC reports its private ring capacity and accepts writes even
    // without a live host consumer. The production pump must consult the
    // explicit connection predicate first, leaving bridge-owned bytes and
    // physical-commit accounting untouched until reconnect.
    GroundUsbEndpoint gated_endpoint{};
    const MavlinkFrame gated_frame = make_heartbeat(0x5FU, report);
    report.check(gated_endpoint.admit_validated_frame(gated_frame) ==
                     ValidatedLocalIngressStatus::QueuedFrame,
                 "Ground USB gate setup rejected a valid frame");
    MockUsbWriter disconnected_writer{};
    const LocalEgressPumpStatus disconnected_status =
        pump_local_egress_if_connected(gated_endpoint.egress(),
                                       disconnected_writer, false);
    report.check(disconnected_status ==
                         LocalEgressPumpStatus::Disconnected &&
                     disconnected_writer.write_calls == 0U &&
                     gated_endpoint.egress().queued_bytes() ==
                         gated_frame.size &&
                     gated_endpoint.egress().stats().bytes_committed == 0U &&
                     !gated_endpoint.egress().write_pending(),
                 "disconnected HWCDC retired bridge-owned USB bytes");

    const LocalEgressPumpStatus reconnect_status =
        pump_local_egress_if_connected(gated_endpoint.egress(),
                                       disconnected_writer, true);
    report.check(reconnect_status == LocalEgressPumpStatus::Progress &&
                     disconnected_writer.write_calls == 1U &&
                     disconnected_writer.accepted_size == gated_frame.size &&
                     std::equal(disconnected_writer.accepted.begin(),
                                disconnected_writer.accepted.begin() +
                                    gated_frame.size,
                                gated_frame.bytes.begin()) &&
                     gated_endpoint.egress().empty() &&
                     gated_endpoint.egress().stats().bytes_committed ==
                         gated_frame.size,
                 "Ground USB reconnect did not drain the retained frame once");

    GroundUsbEndpoint endpoint{};

    std::array<MavlinkFrame, 4> initial{};
    for (std::size_t index = 0U; index < initial.size(); ++index) {
      initial[index] =
          make_heartbeat(static_cast<std::uint8_t>(0x60U + index), report);
    }

    for (std::size_t frame_index = 0U; frame_index < 3U; ++frame_index) {
      ValidatedLocalIngressStatus status =
          ValidatedLocalIngressStatus::NeedMore;
      for (std::size_t byte_index = 0U;
           byte_index < initial[frame_index].size; ++byte_index) {
        status = endpoint.ingest_byte(initial[frame_index].bytes[byte_index]);
      }
      report.check(status == ValidatedLocalIngressStatus::QueuedFrame,
                   "Ground USB disconnect setup rejected a valid frame");
    }
    report.check(endpoint.egress().queued_bytes() == 63U,
                 "Ground USB disconnect setup did not fill the queue");

    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> pending_prefix{};
    const std::size_t pending_prefix_size =
        endpoint.egress().peek(pending_prefix.data(), pending_prefix.size());
    report.check(pending_prefix_size == pending_prefix.size() &&
                     endpoint.egress().complete_write(7U) ==
                         UartWriteProgress::Partial,
                 "Ground USB partial-write disconnect setup failed");

    constexpr std::size_t kDroppedFrames = 100U;
    for (std::size_t iteration = 0U; iteration < kDroppedFrames; ++iteration) {
      const MavlinkFrame& frame = initial[3];
      ValidatedLocalIngressStatus status =
          ValidatedLocalIngressStatus::NeedMore;
      for (std::size_t byte_index = 0U; byte_index < frame.size; ++byte_index) {
        status = endpoint.ingest_byte(frame.bytes[byte_index]);
      }
      report.check(status == ValidatedLocalIngressStatus::DroppedOverflow,
                   "full Ground USB queue did not drop the newest frame");
      report.check(!endpoint.fail_closed(),
                   "backpressured Ground USB permanently stopped the endpoint");
    }
    report.check(endpoint.egress().queued_bytes() == 63U,
                 "overflow changed the complete-frame FIFO prefix");
    report.check(endpoint.stats().overflow_events == kDroppedFrames &&
                     endpoint.stats().frames_dropped_overflow ==
                         kDroppedFrames &&
                     endpoint.stats().bytes_dropped_overflow ==
                         kDroppedFrames * initial[3].size,
                 "recoverable Ground USB overflow diagnostics are incorrect");

    std::array<std::uint8_t, 63> drained{};
    std::copy_n(pending_prefix.data(), 7U, drained.data());
    std::size_t drained_size = 7U;
    while (!endpoint.egress().empty()) {
      std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> chunk{};
      const std::size_t chunk_size =
          endpoint.egress().peek(chunk.data(), chunk.size());
      report.check(chunk_size > 0U,
                   "Ground USB queue stalled after reconnect");
      if (chunk_size == 0U) {
        break;
      }
      std::copy_n(chunk.data(), chunk_size, drained.data() + drained_size);
      drained_size += chunk_size;
      report.check(endpoint.egress().complete_write(chunk_size) ==
                       UartWriteProgress::Complete,
                   "Ground USB queue did not commit after reconnect");
    }
    std::array<std::uint8_t, 63> expected{};
    std::size_t expected_offset = 0U;
    for (std::size_t frame_index = 0U; frame_index < 3U; ++frame_index) {
      std::copy_n(initial[frame_index].bytes.data(), initial[frame_index].size,
                  expected.data() + expected_offset);
      expected_offset += initial[frame_index].size;
    }
    report.check(drained_size == expected.size() && drained == expected,
                 "Ground USB reconnect changed the preserved frame stream");

    const MavlinkFrame resumed = make_heartbeat(0xA5U, report);
    ValidatedLocalIngressStatus resumed_status =
        ValidatedLocalIngressStatus::NeedMore;
    for (std::size_t index = 0U; index < resumed.size; ++index) {
      resumed_status = endpoint.ingest_byte(resumed.bytes[index]);
    }
    report.check(resumed_status == ValidatedLocalIngressStatus::QueuedFrame &&
                     endpoint.egress().queued_bytes() == resumed.size &&
                     !endpoint.fail_closed(),
                 "Ground USB endpoint did not resume after reconnect");
    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> resumed_bytes{};
    const std::size_t resumed_size =
        endpoint.egress().peek(resumed_bytes.data(), resumed_bytes.size());
    report.check(resumed_size == resumed.size &&
                     std::equal(resumed_bytes.begin(),
                                resumed_bytes.begin() + resumed_size,
                                resumed.bytes.begin()),
                 "post-reconnect MAVLink frame was not byte-exact");

    // Exact capacity is admitted; one byte less than a complete frame drops
    // the entire new frame without changing the retained FIFO.
    MavlinkValidatedLocalEgressAdapter<
        42U, kEmbeddedPhysicalWriteBytes,
        LocalEgressOverflowPolicy::DropNewestFrame>
        exact_capacity{};
    for (std::size_t frame_index = 0U; frame_index < 2U; ++frame_index) {
      ValidatedLocalIngressStatus status =
          ValidatedLocalIngressStatus::NeedMore;
      for (std::size_t byte_index = 0U;
           byte_index < initial[frame_index].size; ++byte_index) {
        status =
            exact_capacity.ingest_byte(initial[frame_index].bytes[byte_index]);
      }
      report.check(status == ValidatedLocalIngressStatus::QueuedFrame,
                   "exact-capacity Ground USB frame was not admitted");
    }
    report.check(exact_capacity.egress().queued_bytes() == 42U,
                 "exact-capacity admission was not atomic");

    MavlinkValidatedLocalEgressAdapter<
        41U, kEmbeddedPhysicalWriteBytes,
        LocalEgressOverflowPolicy::DropNewestFrame>
        one_byte_short{};
    for (std::size_t frame_index = 0U; frame_index < 2U; ++frame_index) {
      ValidatedLocalIngressStatus status =
          ValidatedLocalIngressStatus::NeedMore;
      for (std::size_t byte_index = 0U;
           byte_index < initial[frame_index].size; ++byte_index) {
        status =
            one_byte_short.ingest_byte(initial[frame_index].bytes[byte_index]);
      }
      report.check(
          status == (frame_index == 0U
                         ? ValidatedLocalIngressStatus::QueuedFrame
                         : ValidatedLocalIngressStatus::DroppedOverflow),
          "one-byte-short Ground USB boundary returned the wrong status");
    }
    report.check(one_byte_short.egress().queued_bytes() == 21U &&
                     !one_byte_short.fail_closed(),
                 "one-byte-short overflow changed the admitted frame");

    // The default policy remains strict for Vehicle -> Pixhawk delivery.
    MavlinkValidatedLocalEgressAdapter<64U> vehicle_strict{};
    for (std::size_t frame_index = 0U; frame_index < 4U; ++frame_index) {
      ValidatedLocalIngressStatus status =
          ValidatedLocalIngressStatus::NeedMore;
      for (std::size_t byte_index = 0U;
           byte_index < initial[frame_index].size; ++byte_index) {
        status =
            vehicle_strict.ingest_byte(initial[frame_index].bytes[byte_index]);
      }
      if (frame_index == 3U) {
        report.check(status == ValidatedLocalIngressStatus::DroppedOverflow &&
                         vehicle_strict.fail_closed(),
                     "Vehicle/Pixhawk overflow lost its fail-closed policy");
      }
    }

    report.diagnostics.uart_buffer_drop_count = kDroppedFrames;
    report.detail =
        "Ground USB disconnected: retained 3 complete frames/63 bytes, "
        "dropped 100 newest frames atomically, then resumed without reset";
  } else {
    report.check(false, "unknown Phase 6 embedded-adapter test ID");
  }

  report.trace.record({0U, "host", "EMBEDDED_ADAPTER", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
