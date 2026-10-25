#include "fake_arduino_test_api.hpp"

#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "phase6/vc_lora_phase6_bridge.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>

namespace {

using namespace vc_lora_phase6_firmware;

struct Report final {
  std::size_t checks{0U};
  std::size_t failures{0U};
  void check(bool condition, const char* message) {
    ++checks;
    if (!condition) {
      ++failures;
      std::cerr << "FAIL: " << message << '\n';
    }
  }
};

vc_lora::MavlinkFrame product_frame(std::uint8_t sequence) {
  std::array<std::uint8_t, 51U> payload{};
  payload[0U] = 6U;
  constexpr char text[] = "PRODUCT-STREAM";
  std::memcpy(payload.data() + 1U, text, sizeof(text) - 1U);
  vc_lora::MavlinkFrame frame{};
  (void)vc_lora::encode_mavlink_v2(
      sequence, 1U, 1U, 253U, payload.data(), payload.size(), frame);
  return frame;
}

std::size_t inject_radio_frame(const vc_lora::MavlinkFrame& frame) {
  std::size_t offset = 0U;
  std::size_t injected = 0U;
  while (offset < frame.size) {
    const vc_lora::EncodedLinkDataChunk encoded = vc_lora::encode_link_data(
        frame.bytes.data() + offset, frame.size - offset,
        vc_lora::FixedFirmwareContract::radio_chunk_bytes);
    if (encoded.input_consumed == 0U || encoded.wire_size == 0U) {
      return 0U;
    }
    e220_serial.inject_rx(encoded.wire_bytes.data(), encoded.wire_size);
    offset += encoded.input_consumed;
    injected += encoded.wire_size;
  }
  return injected;
}

struct UsbObservation final {
  bool malformed{false};
  std::size_t complete_frames{0U};
  std::size_t product_frames_before_alive{0U};
  std::size_t alive_offset{0U};
  bool alive_seen{false};
  std::size_t buffered_bytes{0U};
};

UsbObservation observe_usb() {
  UsbObservation observation{};
  vc_lora::MavlinkStreamParser parser{};
  const auto& bytes = Serial.tx_bytes();
  std::size_t frame_start = 0U;
  for (std::size_t index = 0U; index < bytes.size(); ++index) {
    vc_lora::MavlinkFrame frame{};
    const vc_lora::MavlinkParseStatus status = parser.push(bytes[index], frame);
    if (status == vc_lora::MavlinkParseStatus::FrameReady) {
      ++observation.complete_frames;
      const std::string text(
          reinterpret_cast<const char*>(frame.payload() + 1U),
          frame.payload_length > 0U ? frame.payload_length - 1U : 0U);
      if (frame.message_id == 253U && frame.system_id == 254U &&
          frame.component_id == 190U &&
          text.rfind("R19A:G:L:", 0U) == 0U) {
        observation.alive_seen = true;
        observation.alive_offset = frame_start;
        break;
      }
      if (frame.message_id == 253U && frame.system_id == 1U &&
          frame.component_id == 1U) {
        ++observation.product_frames_before_alive;
      }
      frame_start = index + 1U;
    } else if (status != vc_lora::MavlinkParseStatus::NeedMore) {
      observation.malformed = true;
      break;
    }
  }
  observation.buffered_bytes = parser.buffered_size();
  return observation;
}

}  // namespace

int main() {
  Report report{};
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  setup_bridge();
  report.check(bridge_ready && !runtime_fail_closed,
               "Ground setup did not reach Ready");

  loop_bridge();
  loop_bridge();
  report.check(Serial.tx_bytes().size() == 63U,
               "Ground ARMED fixture did not complete");

  // The due instant starts with exactly one whole product frame already
  // admitted to LocalEgress.  A sustained RF backlog is then present before
  // every loop.  The diagnostic must reserve this boundary: drain only the
  // already-admitted frame, stop consuming new RF/product ingress, physically
  // fence the complete product frame, and publish ALIVE within a fixed number
  // of loop turns.
  const vc_lora::MavlinkFrame admitted = product_frame(0x20U);
  report.check(admitted.size == 63U &&
                   radio_application_endpoint.admit_validated_frame(admitted) ==
                       vc_lora::ValidatedLocalIngressStatus::QueuedFrame,
               "could not stage one complete admitted product frame");
  fake_arduino::advance_time_ms(
      vc_lora::experimental::R19RuntimeDiagnosticCadence::period_ms);
  Serial.set_flush_failures(1U);
  Serial.set_flush_consumes_timeout(true);

  constexpr std::size_t kBoundedLoops = 8U;
  std::size_t injected_wire_bytes = 0U;
  std::size_t loop_count = 0U;
  UsbObservation observation{};
  for (; loop_count < kBoundedLoops; ++loop_count) {
    const vc_lora::MavlinkFrame incoming =
        product_frame(static_cast<std::uint8_t>(0x40U + loop_count));
    const std::size_t injected = inject_radio_frame(incoming);
    report.check(injected != 0U,
                 "could not maintain the continuous RF product fixture");
    injected_wire_bytes += injected;
    fake_arduino::advance_time_ms(1U);
    loop_bridge();
    observation = observe_usb();
    if (observation.alive_seen) {
      ++loop_count;
      break;
    }
  }

  report.check(observation.alive_seen && loop_count <= kBoundedLoops,
               "due Ground ALIVE starved behind continuous product ingress");
  report.check(!observation.malformed && observation.buffered_bytes == 0U,
               "Ground split or corrupted a product frame at the ALIVE boundary");
  report.check(observation.product_frames_before_alive == 1U &&
                   observation.alive_offset == 126U,
               "ALIVE did not follow exactly the already-admitted whole frame");

  const auto& bytes = Serial.tx_bytes();
  const bool preserved_admitted =
      bytes.size() >= 126U &&
      std::equal(admitted.bytes.begin(), admitted.bytes.begin() + admitted.size,
                 bytes.begin() + 63U);
  report.check(preserved_admitted,
               "already-admitted product bytes were dropped or reordered");
  report.check(static_cast<std::size_t>(e220_serial.available()) ==
                   injected_wire_bytes,
               "new RF/product ingress was consumed before ALIVE committed");
  report.check(radio_application_endpoint.egress().stats().bytes_dropped == 0U &&
                   radio_application_endpoint.egress().stats().overflow_events ==
                       0U &&
                   !runtime_fail_closed,
               "reservation dropped product data or fail-closed the bridge");

  std::cout << "IT-R19-GROUND-RUNTIME-ALIVE-STARVATION-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
