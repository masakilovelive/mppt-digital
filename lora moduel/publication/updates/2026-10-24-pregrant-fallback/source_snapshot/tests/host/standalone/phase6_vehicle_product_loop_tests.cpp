#include "fake_arduino_test_api.hpp"

#define VC_LORA_PHASE6_VEHICLE 1
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 1
#include "phase6/vc_lora_phase6_bridge.hpp"

#include <array>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <string>

namespace {

struct Evidence final {
  bool setup_ready{false};
  bool candidate_adapter_ready{false};
  bool pixhawk_heartbeat_ingested{false};
  bool radio_heartbeat_written{false};
  bool writer_tail_released{false};
  bool runtime_fail_closed{false};
  std::size_t config_reads{0U};
  std::size_t radio_tx_bytes{0U};
  std::uint64_t loops{0U};
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
         "IT-R19-VEHICLE-PRODUCT-LOOP-COLD-BOOT-001";
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
  std::FILE* stream =
      std::fopen((directory / "summary.json").string().c_str(), "wb");
  if (stream == nullptr) {
    return false;
  }
  const int written = std::fprintf(
      stream,
      "{\n"
      "  \"test\": \"IT-R19-VEHICLE-PRODUCT-LOOP-COLD-BOOT-001\",\n"
      "  \"result\": \"%s\",\n"
      "  \"production_setup_bridge_called\": true,\n"
      "  \"production_loop_bridge_called\": true,\n"
      "  \"candidate_enabled\": true,\n"
      "  \"setup_ready\": %s,\n"
      "  \"candidate_adapter_ready\": %s,\n"
      "  \"pixhawk_heartbeat_ingested\": %s,\n"
      "  \"radio_heartbeat_written\": %s,\n"
      "  \"writer_tail_released\": %s,\n"
      "  \"runtime_fail_closed\": %s,\n"
      "  \"config_reads\": %zu,\n"
      "  \"radio_tx_bytes\": %zu,\n"
      "  \"loops\": %llu,\n"
      "  \"writer_tail_service_ms\": %llu,\n"
      "  \"first_failure\": \"%s\"\n"
      "}\n",
      evidence.first_failure.empty() ? "PASS" : "FAIL",
      evidence.setup_ready ? "true" : "false",
      evidence.candidate_adapter_ready ? "true" : "false",
      evidence.pixhawk_heartbeat_ingested ? "true" : "false",
      evidence.radio_heartbeat_written ? "true" : "false",
      evidence.writer_tail_released ? "true" : "false",
      evidence.runtime_fail_closed ? "true" : "false",
      evidence.config_reads, evidence.radio_tx_bytes,
      static_cast<unsigned long long>(evidence.loops),
      static_cast<unsigned long long>(evidence.writer_tail_service_ms),
      json_escape(evidence.first_failure).c_str());
  return std::fclose(stream) == 0 && written > 0;
}

vc_lora::MavlinkFrame primary_vehicle_heartbeat() {
  constexpr std::array<std::uint8_t, 9U> payload{
      0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U};
  vc_lora::MavlinkFrame frame{};
  (void)vc_lora::encode_mavlink_v2(0x31U, 1U, 1U, 0U,
                                    payload.data(), payload.size(), frame);
  return frame;
}

Evidence exercise_product_vehicle_bridge() {
  namespace firmware = vc_lora_phase6_firmware;
  Evidence evidence{};
  fake_arduino::reset_platform();
  fake_arduino::set_pin_input_level(D8, HIGH);
  firmware::e220_serial.reset_test_state();
  firmware::pixhawk_serial.reset_test_state();

  firmware::setup_bridge();
  evidence.config_reads = firmware::e220_serial.config_read_count();
  evidence.setup_ready =
      firmware::startup_contract.status() ==
          vc_lora::FirmwareStartupStatus::Ready &&
      firmware::bridge_ready && !firmware::runtime_fail_closed &&
      firmware::e220_serial.baud_rate() == 115200U &&
      firmware::pixhawk_serial.baud_rate() == 57600U;
  evidence.check(evidence.setup_ready,
                 "production Vehicle setup did not reach Ready");
  evidence.check(evidence.config_reads == 1U,
                 "cold boot did not perform exactly one successful profile read");

  evidence.candidate_adapter_ready =
      firmware::r19_role_adapter_constructed &&
      firmware::r19_vehicle_adapter != nullptr &&
      !firmware::r19_vehicle_adapter->fail_closed();
  evidence.check(evidence.candidate_adapter_ready,
                 "R19 Vehicle role adapter was not constructed");

  for (std::uint32_t index = 0U; index < 6U; ++index) {
    fake_arduino::advance_time_ms(1U);
    firmware::loop_bridge();
    ++evidence.loops;
  }

  const vc_lora::MavlinkFrame heartbeat = primary_vehicle_heartbeat();
  firmware::pixhawk_serial.inject_rx(heartbeat.bytes.data(), heartbeat.size);

  std::uint64_t radio_write_at_ms = 0U;
  std::uint64_t writer_release_at_ms = 0U;
  bool saw_writer_tail_pending = false;
  for (std::uint32_t index = 0U; index < 700U; ++index) {
    fake_arduino::advance_time_ms(1U);
    firmware::loop_bridge();
    ++evidence.loops;
    const std::uint64_t now_ms = fake_arduino::now_us / 1000U;
    if (radio_write_at_ms == 0U &&
        !firmware::e220_serial.normal_tx_bytes().empty()) {
      radio_write_at_ms = now_ms;
    }
    if (firmware::standard_radio_writer_tail_pending) {
      saw_writer_tail_pending = true;
    } else if (saw_writer_tail_pending && writer_release_at_ms == 0U &&
               firmware::e220_writer_arbiter.can_poll_standard()) {
      writer_release_at_ms = now_ms;
    }
  }

  const auto& radio_tx = firmware::e220_serial.normal_tx_bytes();
  evidence.radio_tx_bytes = radio_tx.size();
  vc_lora::TddLinkDemux demux{true};
  vc_lora::MavlinkStreamParser parser{};
  vc_lora::MavlinkFrame decoded{};
  bool frame_ready = false;
  bool parse_valid = true;
  for (const std::uint8_t byte : radio_tx) {
    const vc_lora::TddDemuxEvent event = demux.push(byte);
    if (event.has_control || event.has_bulk_negotiation ||
        event.has_bulk_data || event.has_terminal_ack ||
        event.has_peer_completion_receipt) {
      parse_valid = false;
    }
    for (std::size_t index = 0U; index < event.local_size; ++index) {
      const vc_lora::MavlinkParseStatus status =
          parser.push(event.local_bytes[index], decoded);
      if (status == vc_lora::MavlinkParseStatus::FrameReady) {
        frame_ready = true;
      } else if (status != vc_lora::MavlinkParseStatus::NeedMore) {
        parse_valid = false;
      }
    }
  }
  evidence.radio_heartbeat_written =
      parse_valid && frame_ready && radio_tx.size() == 32U &&
      decoded.message_id == 0U && decoded.system_id == 1U &&
      decoded.component_id == 1U && parser.buffered_size() == 0U &&
      demux.buffered_size() == 0U;
  evidence.check(evidence.radio_heartbeat_written,
                 "actual Vehicle loop did not write one complete RF heartbeat");

  evidence.pixhawk_heartbeat_ingested =
      firmware::vehicle_scheduler.queued_bytes() == 0U &&
      firmware::link_diagnostics.mavlink_crc_errors == 0U;
  evidence.check(evidence.pixhawk_heartbeat_ingested,
                 "Pixhawk heartbeat was not consumed by the product scheduler");

  evidence.writer_tail_service_ms =
      writer_release_at_ms >= radio_write_at_ms && radio_write_at_ms != 0U
          ? writer_release_at_ms - radio_write_at_ms
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
                 "Vehicle standard writer did not release the RF tail");

  evidence.runtime_fail_closed = firmware::runtime_fail_closed;
  evidence.check(!firmware::runtime_fail_closed && firmware::bridge_ready,
                 "product Vehicle bridge fail-closed on one heartbeat");
  evidence.check(!firmware::r19_product_route_selected &&
                     !firmware::r19_standard_tdd_frozen,
                 "heartbeat selected the high-speed product route");
  return evidence;
}

}  // namespace

int main(int argc, char** argv) {
  const Evidence evidence = exercise_product_vehicle_bridge();
  if (!write_summary(output_directory(argc, argv), evidence)) {
    std::fprintf(stderr, "failed to write summary.json\n");
    return 2;
  }
  if (!evidence.first_failure.empty()) {
    std::fprintf(stderr, "FAIL: %s\n", evidence.first_failure.c_str());
    return 1;
  }
  std::printf("PASS: production Vehicle setup/loop heartbeat RF path\n");
  return 0;
}
