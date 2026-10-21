/*
  Read-only Pixhawk TELEM parameter-stream benchmark for XIAO ESP32-S3.

  The benchmark isolates the D6/D7 UART path. It sends exactly one MAVLink 2
  PARAM_REQUEST_LIST after an explicit nonce-bound USB command and never sends
  a parameter mutation or vehicle command. It does not use a radio path.

  Wiring:
    XIAO D7 <- Pixhawk TELEM TX
    XIAO D6 -> Pixhawk TELEM RX
    XIAO GND <-> Pixhawk GND
*/

#include <Arduino.h>
#include <esp_timer.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace {

constexpr std::uint32_t kUsbBaud = 115200U;
constexpr std::uint32_t kPixhawkBaud = 57600U;
constexpr int kPixhawkRxPin = D7;
constexpr int kPixhawkTxPin = D6;
constexpr std::size_t kExpectedParameterCount = 932U;
constexpr std::uint32_t kBenchmarkTimeoutMs = 120000U;
constexpr std::uint32_t kProgressIntervalMs = 5000U;
constexpr std::uint64_t kIndexedQuietUs = 2000000U;
constexpr std::uint64_t kHeartbeatReadyMaxAgeUs = 2500000U;
constexpr std::uint64_t kHeartbeatMaximumGapUs = 2500000U;
constexpr std::uint64_t kTarget10SecondsUs = 10000000U;
constexpr std::uint64_t kTarget30SecondsUs = 30000000U;
constexpr std::size_t kMaximumFrameBytes = 280U;
constexpr std::size_t kNonceCapacity = 49U;
constexpr char kProtocolIdentity[] = "PIXHAWK_D7_PARAM_BENCHMARK_V2";
constexpr std::array<std::uint8_t, 16U> kStatRuntimeId{{
    'S', 'T', 'A', 'T', '_', 'R', 'U', 'N',
    'T', 'I', 'M', 'E', 0U, 0U, 0U, 0U}};

// Golden MAVLink 2 PARAM_REQUEST_LIST: seq=99, sys=255, comp=190,
// target_system=1, target_component=1, CRC_EXTRA=159.
constexpr std::array<std::uint8_t, 14U> kParamRequestList{{
    0xFDU, 0x02U, 0x00U, 0x00U, 0x63U, 0xFFU, 0xBEU,
    0x15U, 0x00U, 0x00U, 0x01U, 0x01U, 0xD5U, 0x07U}};

HardwareSerial pixhawk_serial(2);

std::uint64_t now_us() {
  return static_cast<std::uint64_t>(esp_timer_get_time());
}

std::uint16_t crc_accumulate(std::uint16_t crc, std::uint8_t byte) {
  std::uint8_t mixed =
      static_cast<std::uint8_t>(byte ^ static_cast<std::uint8_t>(crc));
  mixed = static_cast<std::uint8_t>(mixed ^
                                    static_cast<std::uint8_t>(mixed << 4U));
  return static_cast<std::uint16_t>(
      (crc >> 8U) ^ (static_cast<std::uint16_t>(mixed) << 8U) ^
      (static_cast<std::uint16_t>(mixed) << 3U) ^
      (static_cast<std::uint16_t>(mixed) >> 4U));
}

std::uint16_t crc_calculate(const std::uint8_t* bytes, std::size_t size,
                            std::uint8_t extra) {
  std::uint16_t crc = 0xFFFFU;
  for (std::size_t index = 0U; index < size; ++index) {
    crc = crc_accumulate(crc, bytes[index]);
  }
  return crc_accumulate(crc, extra);
}

std::uint16_t load_u16(const std::uint8_t* bytes) {
  return static_cast<std::uint16_t>(bytes[0]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(bytes[1]) << 8U);
}

struct ParserTotals {
  std::uint64_t frames{0U};
  std::uint64_t crc_errors{0U};
  std::uint64_t bad_lengths{0U};
  std::uint64_t unsupported_flags{0U};
  std::uint64_t noise_bytes{0U};
};

struct ParsedFrame {
  std::uint32_t message_id{0U};
  std::uint8_t sequence{0U};
  std::uint8_t system_id{0U};
  std::uint8_t component_id{0U};
  std::uint8_t payload_length{0U};
  const std::uint8_t* payload{nullptr};
  bool crc_valid{false};
};

ParserTotals parser_totals{};
std::uint32_t heartbeat_count{0U};
std::uint64_t previous_primary_heartbeat_us{0U};
std::uint64_t last_primary_heartbeat_us{0U};
std::uint64_t uart_observation_start_us{0U};
std::uint64_t last_primary_indexed_parameter_us{0U};

struct BenchmarkRun {
  bool active{false};
  bool terminal{false};
  char nonce[kNonceCapacity]{};
  std::uint32_t request_write_count{0U};
  std::uint64_t request_enqueue_us{0U};
  std::uint64_t request_tx_complete_us{0U};
  std::uint64_t request_us{0U};
  std::uint64_t first_parameter_us{0U};
  std::uint64_t last_parameter_us{0U};
  std::uint64_t d7_bytes{0U};
  std::uint64_t parameter_frames{0U};
  std::uint32_t stat_runtime_excluded{0U};
  std::uint32_t unique{0U};
  std::uint32_t next_expected{0U};
  std::uint32_t duplicate{0U};
  std::uint32_t out_of_order{0U};
  std::uint32_t out_of_range{0U};
  std::uint32_t wrong_source{0U};
  std::uint32_t count_mismatch{0U};
  std::uint32_t bad_payload{0U};
  std::uint32_t run_heartbeat_count{0U};
  std::uint64_t run_last_heartbeat_us{0U};
  std::uint64_t heartbeat_max_gap_us{0U};
  bool awaiting_post_list_heartbeat{false};
  std::uint64_t list_complete_us{0U};
  std::uint64_t post_list_heartbeat_us{0U};
  std::uint64_t parser_crc_baseline{0U};
  std::uint64_t parser_bad_length_baseline{0U};
  std::uint64_t parser_unsupported_flags_baseline{0U};
  std::uint64_t parser_noise_baseline{0U};
  std::uint32_t last_progress_ms{0U};
  std::array<bool, kExpectedParameterCount> seen{};
};

BenchmarkRun run{};

void print_u64(std::uint64_t value) {
  Serial.print(static_cast<unsigned long long>(value));
}

void print_protocol_prefix(const char* marker) {
  Serial.print(marker);
  Serial.print(" protocol=");
  Serial.print(kProtocolIdentity);
}

std::uint32_t missing_count() {
  return static_cast<std::uint32_t>(kExpectedParameterCount) - run.unique;
}

void account_heartbeat_edge(std::uint64_t observed_us) {
  if (run.run_last_heartbeat_us != 0U &&
      observed_us >= run.run_last_heartbeat_us) {
    const std::uint64_t gap_us = observed_us - run.run_last_heartbeat_us;
    if (gap_us > run.heartbeat_max_gap_us) {
      run.heartbeat_max_gap_us = gap_us;
    }
  }
}

void print_terminal_result(const char* trigger) {
  if (run.terminal) {
    return;
  }
  const std::uint64_t terminal_us = now_us();
  account_heartbeat_edge(terminal_us);
  run.active = false;
  run.terminal = true;

  const std::uint64_t request_to_first_us =
      run.first_parameter_us >= run.request_us
          ? run.first_parameter_us - run.request_us
          : 0U;
  const std::uint64_t request_to_last_us =
      run.last_parameter_us >= run.request_us
          ? run.last_parameter_us - run.request_us
          : 0U;
  const std::uint64_t first_to_last_us =
      run.last_parameter_us >= run.first_parameter_us
          ? run.last_parameter_us - run.first_parameter_us
          : 0U;
  const std::uint64_t crc_errors =
      parser_totals.crc_errors - run.parser_crc_baseline;
  const std::uint64_t bad_lengths =
      parser_totals.bad_lengths - run.parser_bad_length_baseline;
  const std::uint64_t unsupported_flags =
      parser_totals.unsupported_flags -
      run.parser_unsupported_flags_baseline;
  const std::uint64_t noise_bytes =
      parser_totals.noise_bytes - run.parser_noise_baseline;
  const std::uint64_t request_tx_duration_us =
      run.request_tx_complete_us >= run.request_enqueue_us
          ? run.request_tx_complete_us - run.request_enqueue_us
          : 0U;
  const std::uint64_t list_complete_to_post_heartbeat_us =
      run.post_list_heartbeat_us >= run.list_complete_us
          ? run.post_list_heartbeat_us - run.list_complete_us
          : 0U;
  const bool data_pass =
      run.request_write_count == 1U &&
      run.unique == kExpectedParameterCount &&
      run.next_expected == kExpectedParameterCount &&
      run.duplicate == 0U && run.out_of_order == 0U &&
      run.out_of_range == 0U && run.wrong_source == 0U &&
      run.count_mismatch == 0U && run.bad_payload == 0U &&
      crc_errors == 0U && bad_lengths == 0U &&
      unsupported_flags == 0U && noise_bytes == 0U;
  const bool heartbeat_pass =
      run.post_list_heartbeat_us != 0U &&
      run.run_heartbeat_count >= 2U &&
      run.heartbeat_max_gap_us <= kHeartbeatMaximumGapUs;
  const bool overall_pass = data_pass && heartbeat_pass;
  const bool target_10s_data_pass =
      data_pass && request_to_last_us != 0U &&
      request_to_last_us <= kTarget10SecondsUs;
  const bool target_30s_data_pass =
      data_pass && request_to_last_us != 0U &&
      request_to_last_us <= kTarget30SecondsUs;
  const bool target_10s_pass =
      heartbeat_pass && target_10s_data_pass;
  const bool target_30s_pass =
      heartbeat_pass && target_30s_data_pass;
  const char* reason = overall_pass
                           ? "strict_932_and_post_heartbeat"
                           : (!data_pass ? "strict_data_accounting"
                                         : "heartbeat_sla");

  print_protocol_prefix("[RESULT]");
  Serial.print(" nonce=");
  Serial.print(run.nonce);
  Serial.print(" result=");
  Serial.print(overall_pass ? "PASS" : "FAIL");
  Serial.print(" reason=");
  Serial.print(reason);
  Serial.print(" trigger=");
  Serial.print(trigger);
  Serial.print(" data_result=");
  Serial.print(data_pass ? "PASS" : "FAIL");
  Serial.print(" heartbeat_result=");
  Serial.print(heartbeat_pass ? "PASS" : "FAIL");
  Serial.print(" target_10s_data_result=");
  Serial.print(target_10s_data_pass ? "PASS" : "FAIL");
  Serial.print(" target_30s_data_result=");
  Serial.print(target_30s_data_pass ? "PASS" : "FAIL");
  Serial.print(" target_10s_result=");
  Serial.print(target_10s_pass ? "PASS" : "FAIL");
  Serial.print(" target_30s_result=");
  Serial.print(target_30s_pass ? "PASS" : "FAIL");
  Serial.print(" request_writes=");
  Serial.print(run.request_write_count);
  Serial.print(" expected=932 unique=");
  Serial.print(run.unique);
  Serial.print(" missing=");
  Serial.print(missing_count());
  Serial.print(" duplicate=");
  Serial.print(run.duplicate);
  Serial.print(" out_of_order=");
  Serial.print(run.out_of_order);
  Serial.print(" out_of_range=");
  Serial.print(run.out_of_range);
  Serial.print(" wrong_source=");
  Serial.print(run.wrong_source);
  Serial.print(" count_mismatch=");
  Serial.print(run.count_mismatch);
  Serial.print(" bad_payload=");
  Serial.print(run.bad_payload);
  Serial.print(" parameter_frames=");
  print_u64(run.parameter_frames);
  Serial.print(" stat_runtime_excluded=");
  Serial.print(run.stat_runtime_excluded);
  Serial.print(" d7_bytes=");
  print_u64(run.d7_bytes);
  Serial.print(" request_enqueue_us=");
  print_u64(run.request_enqueue_us);
  Serial.print(" request_tx_complete_us=");
  print_u64(run.request_tx_complete_us);
  Serial.print(" request_tx_duration_us=");
  print_u64(request_tx_duration_us);
  Serial.print(" write_semantics=arduino_length_then_uart_tx_idle");
  Serial.print(" crc_scope=heartbeat_and_param_value_only");
  Serial.print(" request_to_first_us=");
  print_u64(request_to_first_us);
  Serial.print(" request_to_last_us=");
  print_u64(request_to_last_us);
  Serial.print(" first_to_last_us=");
  print_u64(first_to_last_us);
  Serial.print(" heartbeat_count=");
  Serial.print(run.run_heartbeat_count);
  Serial.print(" heartbeat_max_gap_us=");
  print_u64(run.heartbeat_max_gap_us);
  Serial.print(" post_list_heartbeat_us=");
  print_u64(run.post_list_heartbeat_us);
  Serial.print(" list_complete_to_post_heartbeat_us=");
  print_u64(list_complete_to_post_heartbeat_us);
  Serial.print(" crc_errors=");
  print_u64(crc_errors);
  Serial.print(" bad_lengths=");
  print_u64(bad_lengths);
  Serial.print(" unsupported_flags=");
  print_u64(unsupported_flags);
  Serial.print(" noise_bytes=");
  print_u64(noise_bytes);
  Serial.println();
}

bool known_crc_valid(const std::uint8_t* frame, std::size_t frame_size,
                     std::uint32_t message_id, std::uint8_t payload_length) {
  std::uint8_t extra = 0U;
  if (message_id == 0U) {
    extra = 50U;
  } else if (message_id == 22U) {
    extra = 220U;
  } else {
    return true;
  }

  const bool v1 = frame[0] == 0xFEU;
  const std::size_t checksum_offset =
      (v1 ? 6U : 10U) + static_cast<std::size_t>(payload_length);
  const std::size_t crc_input_size =
      (v1 ? 5U : 9U) + static_cast<std::size_t>(payload_length);
  if (checksum_offset + 2U > frame_size) {
    return false;
  }
  const std::uint16_t calculated =
      crc_calculate(frame + 1U, crc_input_size, extra);
  return load_u16(frame + checksum_offset) == calculated;
}

bool is_exact_stat_runtime(const ParsedFrame& frame) {
  if (frame.system_id != 1U || frame.component_id != 1U ||
      frame.payload_length != 25U || frame.payload == nullptr) {
    return false;
  }
  const std::uint8_t* payload = frame.payload;
  const std::uint16_t count = load_u16(payload + 4U);
  const std::uint16_t index = load_u16(payload + 6U);
  return count == kExpectedParameterCount && index == 0xFFFFU &&
         std::equal(kStatRuntimeId.begin(), kStatRuntimeId.end(),
                    payload + 8U) &&
         payload[24U] == 6U;
}

bool is_primary_indexed_parameter(const ParsedFrame& frame) {
  return frame.system_id == 1U && frame.component_id == 1U &&
         frame.payload_length == 25U && frame.payload != nullptr &&
         load_u16(frame.payload + 6U) != 0xFFFFU;
}

void handle_primary_heartbeat(std::uint64_t observed_us) {
  ++heartbeat_count;
  previous_primary_heartbeat_us = last_primary_heartbeat_us;
  last_primary_heartbeat_us = observed_us;
  if (!run.active) {
    return;
  }
  account_heartbeat_edge(observed_us);
  run.run_last_heartbeat_us = observed_us;
  ++run.run_heartbeat_count;
  if (run.awaiting_post_list_heartbeat &&
      observed_us >= run.list_complete_us) {
    run.post_list_heartbeat_us = observed_us;
    print_terminal_result("post_list_heartbeat");
  }
}

void handle_parameter_value(const ParsedFrame& frame,
                            std::uint64_t observed_us) {
  if (!run.active) {
    return;
  }
  ++run.parameter_frames;
  if (is_exact_stat_runtime(frame)) {
    ++run.stat_runtime_excluded;
    return;
  }
  if (frame.system_id != 1U || frame.component_id != 1U) {
    ++run.wrong_source;
    return;
  }
  if (frame.payload_length != 25U || frame.payload == nullptr) {
    ++run.bad_payload;
    return;
  }

  const std::uint8_t* payload = frame.payload;
  const std::uint16_t param_count =
      static_cast<std::uint16_t>(payload[4]) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(payload[5]) << 8U);
  const std::uint16_t param_index =
      static_cast<std::uint16_t>(payload[6]) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(payload[7]) << 8U);

  if (param_count != kExpectedParameterCount) {
    ++run.count_mismatch;
    return;
  }
  if (param_index >= kExpectedParameterCount) {
    ++run.out_of_range;
    return;
  }
  if (run.seen[param_index]) {
    ++run.duplicate;
    return;
  }
  if (param_index != run.next_expected) {
    ++run.out_of_order;
  }

  run.seen[param_index] = true;
  ++run.unique;
  if (param_index == run.next_expected) {
    ++run.next_expected;
  }
  if (run.first_parameter_us == 0U) {
    run.first_parameter_us = observed_us;
  }
  run.last_parameter_us = observed_us;

  if (run.unique == kExpectedParameterCount) {
    run.awaiting_post_list_heartbeat = true;
    run.list_complete_us = observed_us;
  }
}

void handle_complete_frame(const std::uint8_t* frame,
                           std::size_t frame_size) {
  ParsedFrame parsed{};
  const bool v1 = frame[0] == 0xFEU;
  parsed.payload_length = frame[1];
  if (v1) {
    parsed.sequence = frame[2];
    parsed.system_id = frame[3];
    parsed.component_id = frame[4];
    parsed.message_id = frame[5];
    parsed.payload = frame + 6U;
  } else {
    parsed.sequence = frame[4];
    parsed.system_id = frame[5];
    parsed.component_id = frame[6];
    parsed.message_id = static_cast<std::uint32_t>(frame[7]) |
                        (static_cast<std::uint32_t>(frame[8]) << 8U) |
                        (static_cast<std::uint32_t>(frame[9]) << 16U);
    parsed.payload = frame + 10U;
  }

  ++parser_totals.frames;
  parsed.crc_valid = known_crc_valid(frame, frame_size, parsed.message_id,
                                     parsed.payload_length);
  if (!parsed.crc_valid) {
    ++parser_totals.crc_errors;
    return;
  }

  const std::uint64_t observed_us = now_us();
  if (parsed.message_id == 0U && parsed.system_id == 1U &&
      parsed.component_id == 1U) {
    handle_primary_heartbeat(observed_us);
  } else if (parsed.message_id == 22U) {
    if (is_primary_indexed_parameter(parsed)) {
      last_primary_indexed_parameter_us = observed_us;
    }
    handle_parameter_value(parsed, observed_us);
  }
}

class StreamParser {
 public:
  void push(std::uint8_t byte) {
    if (size_ == 0U) {
      if (byte != 0xFEU && byte != 0xFDU) {
        ++parser_totals.noise_bytes;
        return;
      }
      buffer_[size_++] = byte;
      expected_ = 0U;
      return;
    }

    if (size_ >= buffer_.size()) {
      ++parser_totals.bad_lengths;
      reset();
      return;
    }
    buffer_[size_++] = byte;

    if (buffer_[0] == 0xFEU && size_ == 2U) {
      expected_ = static_cast<std::size_t>(buffer_[1]) + 8U;
    } else if (buffer_[0] == 0xFDU && size_ == 3U) {
      if ((buffer_[2] & static_cast<std::uint8_t>(~0x01U)) != 0U) {
        ++parser_totals.unsupported_flags;
        reset();
        return;
      }
      expected_ = static_cast<std::size_t>(buffer_[1]) + 12U +
                  ((buffer_[2] & 0x01U) != 0U ? 13U : 0U);
    }

    if (expected_ > buffer_.size() ||
        (expected_ != 0U && expected_ < 8U)) {
      ++parser_totals.bad_lengths;
      reset();
      return;
    }
    if (expected_ != 0U && size_ == expected_) {
      handle_complete_frame(buffer_.data(), size_);
      reset();
    }
  }

  void reset() {
    size_ = 0U;
    expected_ = 0U;
  }

  bool idle() const {
    return size_ == 0U && expected_ == 0U;
  }

 private:
  std::array<std::uint8_t, kMaximumFrameBytes> buffer_{};
  std::size_t size_{0U};
  std::size_t expected_{0U};
};

StreamParser parser{};
char usb_line[80]{};
std::size_t usb_line_size{0U};

std::uint64_t indexed_quiet_age_us(std::uint64_t observed_us) {
  const std::uint64_t reference_us =
      last_primary_indexed_parameter_us == 0U
          ? uart_observation_start_us
          : last_primary_indexed_parameter_us;
  return observed_us >= reference_us ? observed_us - reference_us : 0U;
}

bool nonce_valid(const char* nonce) {
  const std::size_t size = std::strlen(nonce);
  if (size == 0U || size >= kNonceCapacity) {
    return false;
  }
  for (std::size_t index = 0U; index < size; ++index) {
    const char byte = nonce[index];
    const bool allowed =
        (byte >= 'A' && byte <= 'Z') ||
        (byte >= 'a' && byte <= 'z') ||
        (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' ||
        byte == '.';
    if (!allowed) {
      return false;
    }
  }
  return true;
}

void print_ready() {
  const std::uint64_t observed_us = now_us();
  print_protocol_prefix("[READY]");
  Serial.print(" role=vehicle uart=2 rx=D7 tx=D6 baud=57600 ");
  Serial.print("expected=932 heartbeat_count=");
  Serial.print(heartbeat_count);
  Serial.print(" heartbeat_age_us=");
  if (last_primary_heartbeat_us == 0U) {
    Serial.print("NA");
  } else {
    print_u64(observed_us - last_primary_heartbeat_us);
  }
  Serial.print(" indexed_quiet_age_us=");
  print_u64(indexed_quiet_age_us(observed_us));
  Serial.print(" heartbeat_last_gap_us=");
  if (previous_primary_heartbeat_us == 0U) {
    Serial.print("NA");
  } else {
    print_u64(last_primary_heartbeat_us - previous_primary_heartbeat_us);
  }
  Serial.print(" parser_idle=");
  Serial.print(parser.idle() ? 1 : 0);
  Serial.println(" command=START <nonce>");
}

void reset_run(const char* nonce) {
  run = BenchmarkRun{};
  std::strncpy(run.nonce, nonce, sizeof(run.nonce) - 1U);
  run.parser_crc_baseline = parser_totals.crc_errors;
  run.parser_bad_length_baseline = parser_totals.bad_lengths;
  run.parser_unsupported_flags_baseline = parser_totals.unsupported_flags;
  run.parser_noise_baseline = parser_totals.noise_bytes;
  run.run_last_heartbeat_us = last_primary_heartbeat_us;
}

void start_benchmark(const char* nonce) {
  if (nonce == nullptr || !nonce_valid(nonce)) {
    Serial.println("[START_REJECT] reason=invalid_nonce");
    return;
  }
  if (run.active) {
    Serial.println("[START_REJECT] reason=already_active");
    return;
  }
  const std::uint64_t observed_us = now_us();
  if (heartbeat_count < 2U || last_primary_heartbeat_us == 0U) {
    Serial.print("[START_REJECT] reason=heartbeat_not_ready count=");
    Serial.println(heartbeat_count);
    return;
  }
  const std::uint64_t heartbeat_age_us =
      observed_us - last_primary_heartbeat_us;
  if (heartbeat_age_us > kHeartbeatReadyMaxAgeUs) {
    Serial.print("[START_REJECT] reason=heartbeat_stale age_us=");
    print_u64(heartbeat_age_us);
    Serial.println();
    return;
  }
  if (previous_primary_heartbeat_us == 0U ||
      last_primary_heartbeat_us - previous_primary_heartbeat_us >
          kHeartbeatMaximumGapUs) {
    Serial.println("[START_REJECT] reason=heartbeat_pair_not_ready");
    return;
  }
  const std::uint64_t quiet_age_us = indexed_quiet_age_us(observed_us);
  if (quiet_age_us < kIndexedQuietUs) {
    Serial.print("[START_REJECT] reason=indexed_stream_not_quiet age_us=");
    print_u64(quiet_age_us);
    Serial.println();
    return;
  }
  if (!parser.idle()) {
    Serial.println("[START_REJECT] reason=parser_not_idle");
    return;
  }
  if (pixhawk_serial.available() != 0) {
    Serial.println("[START_REJECT] reason=uart_rx_pending");
    return;
  }
  parser.reset();
  if (!static_cast<bool>(pixhawk_serial)) {
    Serial.println("[START_REJECT] reason=uart_not_ready");
    return;
  }

  reset_run(nonce);
  if (run.request_write_count != 0U) {
    Serial.println("[START_REJECT] reason=request_already_written");
    return;
  }
  if (pixhawk_serial.availableForWrite() <
      static_cast<int>(kParamRequestList.size())) {
    Serial.println("[START_REJECT] reason=uart_backpressure");
    return;
  }

  run.request_write_count = 1U;
  run.request_enqueue_us = now_us();
  const std::size_t written =
      pixhawk_serial.write(kParamRequestList.data(), kParamRequestList.size());
  if (written != kParamRequestList.size()) {
    run.request_tx_complete_us = now_us();
    run.request_us = run.request_tx_complete_us;
    print_terminal_result("api_length_mismatch");
    return;
  }
  pixhawk_serial.flush();
  run.request_tx_complete_us = now_us();
  run.request_us = run.request_tx_complete_us;
  run.last_progress_ms = millis();
  run.active = true;
  print_protocol_prefix("[START_ACK]");
  Serial.print(" nonce=");
  Serial.print(run.nonce);
  Serial.println(" request_writes=1 target=1/1");
}

void handle_usb_command(char* line) {
  while (*line == ' ') {
    ++line;
  }
  if (std::strncmp(line, "START ", 6U) == 0) {
    char* nonce = line + 6U;
    while (*nonce == ' ') {
      ++nonce;
    }
    start_benchmark(nonce);
    return;
  }
  if (std::strcmp(line, "STATUS") == 0) {
    print_ready();
    return;
  }
  Serial.println("[COMMAND_REJECT] expected=START <nonce>|STATUS");
}

void service_usb() {
  while (Serial.available() > 0) {
    const int value = Serial.read();
    if (value < 0) {
      return;
    }
    const char byte = static_cast<char>(value);
    if (byte == '\r' || byte == '\n') {
      if (usb_line_size > 0U) {
        usb_line[usb_line_size] = '\0';
        handle_usb_command(usb_line);
        usb_line_size = 0U;
      }
    } else if (usb_line_size + 1U < sizeof(usb_line)) {
      usb_line[usb_line_size++] = byte;
    } else {
      usb_line_size = 0U;
      Serial.println("[COMMAND_REJECT] reason=line_too_long");
    }
  }
}

void service_pixhawk() {
  std::size_t budget = 1024U;
  while (budget > 0U && pixhawk_serial.available() > 0) {
    const int value = pixhawk_serial.read();
    --budget;
    if (value < 0) {
      continue;
    }
    if (run.active) {
      ++run.d7_bytes;
    }
    parser.push(static_cast<std::uint8_t>(value));
  }
}

void service_run_deadlines() {
  if (!run.active) {
    return;
  }
  const std::uint64_t elapsed_us = now_us() - run.request_us;
  if (elapsed_us >=
      static_cast<std::uint64_t>(kBenchmarkTimeoutMs) * 1000U) {
    print_terminal_result(run.awaiting_post_list_heartbeat
                              ? "post_list_heartbeat_timeout"
                              : "parameter_timeout");
    return;
  }
  const std::uint32_t now_ms = millis();
  if (now_ms - run.last_progress_ms >= kProgressIntervalMs) {
    run.last_progress_ms = now_ms;
    print_protocol_prefix("[PROGRESS]");
    Serial.print(" nonce=");
    Serial.print(run.nonce);
    Serial.print(" unique=");
    Serial.print(run.unique);
    Serial.print(" expected=932 elapsed_us=");
    print_u64(elapsed_us);
    Serial.print(" d7_bytes=");
    print_u64(run.d7_bytes);
    Serial.println();
  }
}

}  // namespace

void setup() {
  Serial.begin(kUsbBaud);
  Serial.setTimeout(20U);
  pixhawk_serial.setRxBufferSize(8192U);
  pixhawk_serial.begin(kPixhawkBaud, SERIAL_8N1, kPixhawkRxPin,
                       kPixhawkTxPin);
  uart_observation_start_us = now_us();
  delay(1000U);
  print_protocol_prefix("[BOOT]");
  Serial.println(" diagnostic=PIXHAWK_D7_PARAM_BENCHMARK_V2 mutation=none");
}

void loop() {
  service_pixhawk();
  service_usb();
  service_run_deadlines();
}
