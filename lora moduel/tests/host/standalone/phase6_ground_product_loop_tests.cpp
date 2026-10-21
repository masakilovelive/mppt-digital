#include "fake_arduino_test_api.hpp"

#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#include "phase6/vc_lora_phase6_bridge.hpp"

#include <array>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

namespace {

using vc_lora::EncodedLinkDataChunk;
using vc_lora::FirmwareStartupStatus;
using vc_lora::GroundTddState;
using vc_lora::MavlinkFrame;

struct Evidence final {
  bool setup_ready{false};
  bool candidate_adapter_ready{false};
  bool standard_route_retained{false};
  bool heartbeat_forwarded{false};
  bool grant_observer_ready{false};
  bool ul_idle_written{false};
  bool writer_tail_released{false};
  bool runtime_fail_closed{false};
  std::size_t config_reads{0U};
  std::size_t radio_rx_wire_bytes{0U};
  std::size_t usb_tx_bytes{0U};
  std::uint64_t elapsed_ms{0U};
  std::uint64_t loops{0U};
  std::uint64_t heartbeat_injected{0U};
  std::uint64_t heartbeat_usb_rx{0U};
  std::uint64_t heartbeat_max_gap_ms{0U};
  std::uint64_t grant_rx{0U};
  std::uint64_t ul_idle_tx{0U};
  std::uint64_t radio_tx_bytes{0U};
  std::uint64_t writer_tail_service_ms{0U};
  std::string first_failure{};

  void check(bool condition, const char* failure) {
    if (!condition && first_failure.empty()) {
      first_failure = failure;
    }
  }
};

std::filesystem::path output_directory(int argc, char** argv) {
  constexpr const char kPrefix[] = "--output-dir=";
  for (int index = 1; index < argc; ++index) {
    const std::string argument = argv[index];
    if (argument.rfind(kPrefix, 0U) == 0U) {
      return argument.substr(sizeof(kPrefix) - 1U);
    }
  }
  return std::filesystem::path{"runs"} /
         "IT-R19-GROUND-PRODUCT-LOOP-COLD-BOOT-001";
}

std::string json_escape(const std::string& value) {
  std::string output{};
  for (const char character : value) {
    if (character == '"' || character == '\\') {
      output.push_back('\\');
    }
    output.push_back(character);
  }
  return output;
}

bool write_summary(const std::filesystem::path& directory,
                   const Evidence& evidence) {
  std::error_code error{};
  std::filesystem::create_directories(directory, error);
  if (error) {
    return false;
  }
  const std::filesystem::path path = directory / "summary.json";
  std::FILE* stream = std::fopen(path.string().c_str(), "wb");
  if (stream == nullptr) {
    return false;
  }
  const bool passed = evidence.first_failure.empty();
  const int written = std::fprintf(
      stream,
      "{\n"
      "  \"test\": \"IT-R19-GROUND-PRODUCT-LOOP-COLD-BOOT-001\",\n"
      "  \"result\": \"%s\",\n"
      "  \"production_setup_bridge_called\": true,\n"
      "  \"production_loop_bridge_called\": true,\n"
      "  \"candidate_enabled\": true,\n"
      "  \"setup_ready\": %s,\n"
      "  \"candidate_adapter_ready\": %s,\n"
      "  \"standard_route_retained\": %s,\n"
      "  \"heartbeat_forwarded\": %s,\n"
      "  \"grant_observer_ready\": %s,\n"
      "  \"ul_idle_written\": %s,\n"
      "  \"writer_tail_released\": %s,\n"
      "  \"runtime_fail_closed\": %s,\n"
      "  \"config_reads\": %zu,\n"
      "  \"radio_rx_wire_bytes\": %zu,\n"
      "  \"usb_tx_bytes\": %zu,\n"
      "  \"elapsed_ms\": %llu,\n"
      "  \"loops\": %llu,\n"
      "  \"heartbeat_injected\": %llu,\n"
      "  \"heartbeat_usb_rx\": %llu,\n"
      "  \"heartbeat_max_gap_ms\": %llu,\n"
      "  \"grant_rx\": %llu,\n"
      "  \"ul_idle_tx\": %llu,\n"
      "  \"radio_tx_bytes\": %llu,\n"
      "  \"writer_tail_service_ms\": %llu,\n"
      "  \"first_failure\": \"%s\"\n"
      "}\n",
      passed ? "PASS" : "FAIL",
      evidence.setup_ready ? "true" : "false",
      evidence.candidate_adapter_ready ? "true" : "false",
      evidence.standard_route_retained ? "true" : "false",
      evidence.heartbeat_forwarded ? "true" : "false",
      evidence.grant_observer_ready ? "true" : "false",
      evidence.ul_idle_written ? "true" : "false",
      evidence.writer_tail_released ? "true" : "false",
      evidence.runtime_fail_closed ? "true" : "false",
      evidence.config_reads, evidence.radio_rx_wire_bytes,
      evidence.usb_tx_bytes,
      static_cast<unsigned long long>(evidence.elapsed_ms),
      static_cast<unsigned long long>(evidence.loops),
      static_cast<unsigned long long>(evidence.heartbeat_injected),
      static_cast<unsigned long long>(evidence.heartbeat_usb_rx),
      static_cast<unsigned long long>(evidence.heartbeat_max_gap_ms),
      static_cast<unsigned long long>(evidence.grant_rx),
      static_cast<unsigned long long>(evidence.ul_idle_tx),
      static_cast<unsigned long long>(evidence.radio_tx_bytes),
      static_cast<unsigned long long>(evidence.writer_tail_service_ms),
      json_escape(evidence.first_failure).c_str());
  return std::fclose(stream) == 0 && written > 0;
}

MavlinkFrame make_primary_vehicle_heartbeat(std::uint8_t sequence) {
  constexpr std::array<std::uint8_t, 9U> payload{
      0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U};
  MavlinkFrame frame{};
  (void)vc_lora::encode_mavlink_v2(sequence, 1U, 1U, 0U,
                                    payload.data(), payload.size(), frame);
  return frame;
}

Evidence exercise_product_ground_bridge() {
  namespace firmware = vc_lora_phase6_firmware;
  Evidence evidence{};
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  Serial.set_plugged(true);
  Serial.set_endpoint_ready(true);
  firmware::e220_serial.reset_test_state();

  firmware::setup_bridge();
  evidence.config_reads = firmware::e220_serial.config_read_count();
  evidence.setup_ready =
      firmware::startup_contract.status() == FirmwareStartupStatus::Ready &&
      firmware::bridge_ready && !firmware::runtime_fail_closed &&
      firmware::e220_serial.baud_rate() == 115200U;
  evidence.check(evidence.setup_ready,
                 "production Ground setup did not reach Ready");

  evidence.candidate_adapter_ready =
      firmware::r19_role_adapter_constructed &&
      firmware::r19_ground_adapter != nullptr &&
      !firmware::r19_ground_adapter->fail_closed();
  evidence.check(evidence.candidate_adapter_ready,
                 "R19 Ground role adapter was not constructed");
  evidence.check(evidence.config_reads == 1U,
                 "cold boot did not perform exactly one successful profile read");

  for (std::uint32_t index = 0U; index < 6U; ++index) {
    fake_arduino::advance_time_ms(1U);
    firmware::loop_bridge();
    ++evidence.loops;
  }

  constexpr std::uint64_t kExerciseMs = 40'000U;
  constexpr std::uint64_t kHeartbeatPeriodMs = 1'000U;
  constexpr std::uint64_t kGrantAtMs = 5'000U;
  vc_lora::MavlinkStreamParser usb_parser{};
  std::size_t usb_consumed = 0U;
  std::vector<std::uint64_t> usb_heartbeat_times{};
  std::uint64_t idle_write_at_ms = 0U;
  std::uint64_t writer_release_at_ms = 0U;
  bool saw_writer_tail_pending = false;

  for (std::uint64_t elapsed = 1U; elapsed <= kExerciseMs; ++elapsed) {
    fake_arduino::advance_time_ms(1U);

    if (elapsed % kHeartbeatPeriodMs == 0U) {
      const MavlinkFrame heartbeat = make_primary_vehicle_heartbeat(
          static_cast<std::uint8_t>(evidence.heartbeat_injected));
      const EncodedLinkDataChunk encoded = vc_lora::encode_link_data(
          heartbeat.bytes.data(), heartbeat.size,
          vc_lora::FixedFirmwareContract::radio_chunk_bytes);
      evidence.check(
          encoded.input_consumed == heartbeat.size &&
              encoded.wire_size ==
                  vc_lora::FixedFirmwareContract::radio_chunk_bytes,
          "heartbeat was not encoded as one production RF chunk");
      firmware::e220_serial.inject_rx(encoded.wire_bytes.data(),
                                      encoded.wire_size);
      evidence.radio_rx_wire_bytes += encoded.wire_size;
      ++evidence.heartbeat_injected;
    }

    if (elapsed == kGrantAtMs) {
      vc_lora::TddControlMessage grant{};
      grant.version = vc_lora::kTddProtocolVersion;
      grant.type = vc_lora::ControlType::UlGrant;
      grant.session_id = 0x4242U;
      grant.cycle_id = 1U;
      grant.guard_ms = 650U;
      grant.window_ms = 300U;
      grant.max_bytes = 64U;
      std::array<std::uint8_t, vc_lora::kTddControlFrameSize> wire{};
      std::size_t wire_size = 0U;
      evidence.check(vc_lora::encode_control(
                         grant, wire.data(), wire.size(), wire_size) &&
                         wire_size == wire.size(),
                     "fresh UL_GRANT encoding failed");
      firmware::e220_serial.inject_rx(wire.data(), wire_size);
      evidence.radio_rx_wire_bytes += wire_size;
    }

    firmware::loop_bridge();
    ++evidence.loops;

    const std::uint64_t now_ms = fake_arduino::now_us / 1000U;
    const auto& radio_tx = firmware::e220_serial.normal_tx_bytes();
    if (idle_write_at_ms == 0U && !radio_tx.empty()) {
      idle_write_at_ms = now_ms;
    }
    if (firmware::standard_radio_writer_tail_pending) {
      saw_writer_tail_pending = true;
    } else if (saw_writer_tail_pending && writer_release_at_ms == 0U &&
               firmware::e220_writer_arbiter.can_poll_standard()) {
      writer_release_at_ms = now_ms;
    }

    const auto& usb_tx = Serial.tx_bytes();
    while (usb_consumed < usb_tx.size()) {
      MavlinkFrame decoded{};
      const vc_lora::MavlinkParseStatus status =
          usb_parser.push(usb_tx[usb_consumed++], decoded);
      if (status == vc_lora::MavlinkParseStatus::FrameReady) {
        evidence.check(decoded.message_id == 0U &&
                           decoded.system_id == 1U &&
                           decoded.component_id == 1U,
                       "USB emitted a non-primary-heartbeat frame");
        usb_heartbeat_times.push_back(now_ms);
      } else {
        evidence.check(status == vc_lora::MavlinkParseStatus::NeedMore,
                       "USB emitted a malformed MAVLink frame");
      }
    }
  }

  const auto& usb_tx = Serial.tx_bytes();
  evidence.usb_tx_bytes = usb_tx.size();
  evidence.elapsed_ms = kExerciseMs;
  evidence.heartbeat_usb_rx = usb_heartbeat_times.size();
  for (std::size_t index = 1U; index < usb_heartbeat_times.size(); ++index) {
    evidence.heartbeat_max_gap_ms = std::max(
        evidence.heartbeat_max_gap_ms,
        usb_heartbeat_times[index] - usb_heartbeat_times[index - 1U]);
  }
  evidence.heartbeat_forwarded = evidence.heartbeat_usb_rx >= 2U &&
                                 evidence.heartbeat_max_gap_ms <= 2'500U &&
                                 usb_parser.buffered_size() == 0U;
  evidence.check(evidence.heartbeat_forwarded,
                 "40-second product loop violated the heartbeat USB SLA");

  const auto& radio_tx = firmware::e220_serial.normal_tx_bytes();
  evidence.radio_tx_bytes = radio_tx.size();
  vc_lora::DecodeEvent terminal{};
  if (radio_tx.size() == vc_lora::kTddControlFrameSize) {
    terminal = vc_lora::decode_control(radio_tx.data(), radio_tx.size());
  }
  evidence.ul_idle_written =
      terminal.status == vc_lora::DecodeStatus::Message &&
      terminal.message.type == vc_lora::ControlType::UlIdle &&
      terminal.message.session_id == 0x4242U &&
      terminal.message.cycle_id == 1U &&
      terminal.message.actual_bytes == 0U;
  evidence.check(evidence.ul_idle_written,
                 "fresh empty Grant did not produce one complete UL_IDLE");

  evidence.writer_tail_service_ms =
      writer_release_at_ms >= idle_write_at_ms && idle_write_at_ms != 0U
          ? writer_release_at_ms - idle_write_at_ms
          : 0U;
  evidence.writer_tail_released =
      saw_writer_tail_pending && writer_release_at_ms != 0U &&
      evidence.writer_tail_service_ms >=
          vc_lora::FixedFirmwareContract::e220_subpacket_service_floor_ms &&
      !firmware::standard_radio_writer_lease.valid() &&
      !firmware::standard_radio_writer_tail_pending &&
      !firmware::radio_busy &&
      firmware::e220_writer_arbiter.can_poll_standard();
  evidence.check(evidence.writer_tail_released,
                 "standard writer did not retain and release the RF tail");

  evidence.grant_rx = firmware::link_diagnostics.grant_rx;
  evidence.ul_idle_tx = firmware::link_diagnostics.idle_tx;
  evidence.grant_observer_ready =
      evidence.grant_rx == 1U && evidence.ul_idle_tx == 1U &&
      firmware::r19_ground_adapter != nullptr &&
      !firmware::r19_ground_adapter->fail_closed() &&
      !firmware::r19_ground_adapter->hold_standard_uplink();
  evidence.check(evidence.grant_observer_ready,
                 "R19 Grant observer rejected the standard Grant lifecycle");

  evidence.standard_route_retained =
      !firmware::r19_product_route_selected &&
      !firmware::r19_standard_tdd_frozen &&
      !firmware::r19_acceleration_consumed &&
      firmware::tdd_controller.state() == GroundTddState::WaitGrant &&
      firmware::e220_writer_arbiter.can_poll_standard();
  evidence.check(evidence.standard_route_retained,
                 "no-#21 heartbeat disturbed the standard TDD route");

  evidence.runtime_fail_closed = firmware::runtime_fail_closed;
  evidence.check(!firmware::runtime_fail_closed && firmware::bridge_ready,
                 "product bridge fail-closed during standard heartbeat path");
  evidence.check(firmware::link_diagnostics.mavlink_frames_forwarded ==
                     evidence.heartbeat_usb_rx,
                 "product diagnostics did not match forwarded frames");
  evidence.check(firmware::link_diagnostics.mavlink_crc_errors == 0U,
                 "product diagnostics reported a MAVLink CRC error");
  evidence.check(firmware::link_diagnostics.control_crc_errors == 0U,
                 "product diagnostics reported a control CRC error");
  return evidence;
}

}  // namespace

int main(int argc, char** argv) {
  const Evidence evidence = exercise_product_ground_bridge();
  if (!write_summary(output_directory(argc, argv), evidence)) {
    std::fprintf(stderr, "failed to write summary.json\n");
    return 2;
  }
  if (!evidence.first_failure.empty()) {
    std::fprintf(stderr, "FAIL: %s\n", evidence.first_failure.c_str());
    return 1;
  }
  std::printf("PASS: production Ground setup/loop cold boot heartbeat path\n");
  return 0;
}
