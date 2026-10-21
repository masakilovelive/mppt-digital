/*
  VC_LoRa MAVLink transparent bridge
  Board: Seeed Studio XIAO ESP32-S3 or XIAO ESP32-C3

  Role:
    GROUND  : PC USB CDC <-> XIAO ESP32-S3/C3 <-> E220 LoRa
    VEHICLE : Pixhawk TELEM <-> XIAO ESP32-S3/C3 <-> E220 LoRa

  Important:
    - Production operation is direct Mission Planner COM, not MAVProxy/UDP/UI.
    - All MAVLink paths are raw binary. Do not print debug text to these ports.
    - Enable "USB CDC On Boot" in Arduino IDE for XIAO ESP32-C3.
    - E220 must be configured separately for transparent mode and matching radio settings.
*/

#include <Arduino.h>

#define VC_LORA_ROLE_GROUND 1
#define VC_LORA_ROLE_VEHICLE 2

// User setting: change this before writing each board.
//   VC_LORA_ROLE_GROUND  : ground module connected to the PC
//   VC_LORA_ROLE_VEHICLE : vehicle module connected to Pixhawk TELEM
#ifndef VC_LORA_ROLE
#define VC_LORA_ROLE VC_LORA_ROLE_VEHICLE 
#endif

#ifndef VC_LORA_MAVLINK_BAUD
#define VC_LORA_MAVLINK_BAUD 57600
#endif
static constexpr uint32_t MAVLINK_BAUD = VC_LORA_MAVLINK_BAUD;
#ifndef VC_LORA_E220_UART_BAUD
#define VC_LORA_E220_UART_BAUD 9600
#endif
static constexpr uint32_t E220_UART_BAUD = VC_LORA_E220_UART_BAUD;

#ifndef VC_LORA_SWAP_PIXHAWK_UART
#define VC_LORA_SWAP_PIXHAWK_UART 0
#endif
static constexpr uint32_t DEBUG_BAUD = 115200;

// VC_LoRa schematic pin assignment.
// Use XIAO D-pin constants, not raw GPIO numbers. XIAO ESP32-S3 and C3 map
// the same D numbers to different GPIO numbers.
static constexpr int E220_M0_PIN = D0;   // XIAO D0 -> E220 M0
static constexpr int E220_M1_PIN = D1;   // XIAO D1 -> E220 M1
static constexpr int E220_TX_PIN = D2;   // XIAO D2 -> E220 RXD
static constexpr int E220_RX_PIN = D3;   // XIAO D3 <- E220 TXD
static constexpr int E220_AUX_PIN = D8;  // XIAO D8 <- E220 AUX

#if VC_LORA_SWAP_PIXHAWK_UART
static constexpr int FC_TX_PIN = D7;     // XIAO D7 -> Pixhawk TELEM RX
static constexpr int FC_RX_PIN = D6;     // XIAO D6 <- Pixhawk TELEM TX
#else
static constexpr int FC_TX_PIN = D6;     // XIAO D6 -> Pixhawk TELEM RX
static constexpr int FC_RX_PIN = D7;     // XIAO D7 <- Pixhawk TELEM TX
#endif

#ifndef VC_LORA_IO_CHUNK_BYTES
#define VC_LORA_IO_CHUNK_BYTES 64
#endif
static constexpr size_t IO_CHUNK_BYTES = VC_LORA_IO_CHUNK_BYTES;
static_assert(IO_CHUNK_BYTES > 0 && IO_CHUNK_BYTES <= 400,
              "E220 I/O chunk must fit in the 400-byte module UART buffer");
static constexpr int SERIAL_RX_BUFFER_BYTES = 4096;
#ifndef VC_LORA_E220_PARTIAL_FLUSH_MS
#define VC_LORA_E220_PARTIAL_FLUSH_MS 100
#endif
static constexpr uint32_t E220_PARTIAL_FLUSH_MS = VC_LORA_E220_PARTIAL_FLUSH_MS;
#ifndef VC_LORA_E220_MIN_TX_GAP_MS
#define VC_LORA_E220_MIN_TX_GAP_MS 0
#endif
static constexpr uint32_t E220_MIN_TX_GAP_MS = VC_LORA_E220_MIN_TX_GAP_MS;
#ifndef VC_LORA_AUX_WAIT_US
#define VC_LORA_AUX_WAIT_US 5000
#endif
static constexpr uint32_t AUX_WAIT_US = VC_LORA_AUX_WAIT_US;
static constexpr uint32_t STATS_INTERVAL_MS = 1000;
static constexpr uint32_t TEST_HEARTBEAT_INTERVAL_MS = 1000;
#ifndef VC_LORA_RESPECT_E220_AUX
#define VC_LORA_RESPECT_E220_AUX 1
#endif
static constexpr bool RESPECT_E220_AUX = VC_LORA_RESPECT_E220_AUX != 0;

// E220 is half duplex. Measurements on the target hardware showed that a
// direction change needs at least 500 ms. Production wrappers enable this
// asymmetric TDD schedule so continuous Pixhawk telemetry cannot starve the
// ground-to-vehicle command direction.
#ifndef VC_LORA_TDD_ENABLE
#define VC_LORA_TDD_ENABLE 0
#endif
#ifndef VC_LORA_TDD_VEHICLE_TX_MS
#define VC_LORA_TDD_VEHICLE_TX_MS 3000
#endif
#ifndef VC_LORA_TDD_VEHICLE_RX_MS
#define VC_LORA_TDD_VEHICLE_RX_MS 2000
#endif
#ifndef VC_LORA_TDD_GROUND_TX_START_MS
#define VC_LORA_TDD_GROUND_TX_START_MS 650
#endif
#ifndef VC_LORA_TDD_GROUND_TX_DURATION_MS
#define VC_LORA_TDD_GROUND_TX_DURATION_MS 300
#endif
static constexpr bool TDD_ENABLE = VC_LORA_TDD_ENABLE != 0;
static constexpr uint32_t TDD_VEHICLE_TX_MS = VC_LORA_TDD_VEHICLE_TX_MS;
static constexpr uint32_t TDD_VEHICLE_RX_MS = VC_LORA_TDD_VEHICLE_RX_MS;
static constexpr uint32_t TDD_CYCLE_MS =
    TDD_VEHICLE_TX_MS + TDD_VEHICLE_RX_MS;
static constexpr uint32_t TDD_GROUND_TX_START_MS =
    VC_LORA_TDD_GROUND_TX_START_MS;
static constexpr uint32_t TDD_GROUND_TX_DURATION_MS =
    VC_LORA_TDD_GROUND_TX_DURATION_MS;
static constexpr uint32_t TDD_GROUND_TX_END_MS =
    TDD_GROUND_TX_START_MS + TDD_GROUND_TX_DURATION_MS;
static_assert(TDD_VEHICLE_TX_MS > 0 && TDD_VEHICLE_RX_MS > 0,
              "TDD vehicle windows must be nonzero");
static_assert(TDD_GROUND_TX_START_MS >= 500,
              "Measured E220 turnaround requires at least 500 ms");
static_assert(TDD_GROUND_TX_END_MS < TDD_VEHICLE_RX_MS,
              "Ground TX burst must fit inside the vehicle RX window");

#ifndef VC_LORA_AUTO_CONFIGURE_E220
#define VC_LORA_AUTO_CONFIGURE_E220 0
#endif
#ifndef VC_LORA_E220_PROFILE_REG0
#define VC_LORA_E220_PROFILE_REG0 0xC7
#endif
#ifndef VC_LORA_E220_PROFILE_REG1
#define VC_LORA_E220_PROFILE_REG1 0x00
#endif
#ifndef VC_LORA_E220_PROFILE_CHANNEL
#define VC_LORA_E220_PROFILE_CHANNEL 0x46
#endif
#ifndef VC_LORA_E220_PROFILE_REG3
#define VC_LORA_E220_PROFILE_REG3 0x00
#endif
static constexpr bool AUTO_CONFIGURE_E220 = VC_LORA_AUTO_CONFIGURE_E220 != 0;
static constexpr uint8_t E220_PROFILE[8] = {
    0x00, 0x00, VC_LORA_E220_PROFILE_REG0, VC_LORA_E220_PROFILE_REG1,
    VC_LORA_E220_PROFILE_CHANNEL, VC_LORA_E220_PROFILE_REG3, 0x00, 0x00};

#ifndef VC_LORA_VEHICLE_TEST_HEARTBEAT
#define VC_LORA_VEHICLE_TEST_HEARTBEAT 0
#endif
#ifndef VC_LORA_GROUND_USB_SELFTEST_HEARTBEAT
#define VC_LORA_GROUND_USB_SELFTEST_HEARTBEAT 0
#endif
static constexpr bool VEHICLE_LORA_TEST_HEARTBEAT = VC_LORA_VEHICLE_TEST_HEARTBEAT != 0;
static constexpr bool GROUND_USB_SELFTEST_HEARTBEAT = VC_LORA_GROUND_USB_SELFTEST_HEARTBEAT != 0;

static constexpr uint8_t MAV_SYS_ID = 42;
static constexpr uint8_t MAV_COMP_ID = 191;
static constexpr uint8_t MAV_MSG_ID_HEARTBEAT = 0;
static constexpr uint8_t MAV_CRC_HEARTBEAT = 50;

#ifndef VC_LORA_USB_DEBUG
#define VC_LORA_USB_DEBUG 0
#endif
static constexpr bool USB_DEBUG = VC_LORA_USB_DEBUG != 0;

#ifndef VC_LORA_FILTER_PIXHAWK_MAVLINK
#define VC_LORA_FILTER_PIXHAWK_MAVLINK 0
#endif
#ifndef VC_LORA_DROP_MAVLINK_MSG_ID
#define VC_LORA_DROP_MAVLINK_MSG_ID 194
#endif
static constexpr bool FILTER_PIXHAWK_MAVLINK =
    VC_LORA_FILTER_PIXHAWK_MAVLINK != 0;
static constexpr uint32_t DROP_MAVLINK_MSG_ID = VC_LORA_DROP_MAVLINK_MSG_ID;

HardwareSerial E220Serial(1);

#if VC_LORA_ROLE == VC_LORA_ROLE_VEHICLE
#ifndef VC_LORA_PIXHAWK_UART_NUM
#if defined(CONFIG_IDF_TARGET_ESP32S3) || defined(ARDUINO_XIAO_ESP32S3)
#define VC_LORA_PIXHAWK_UART_NUM 2
#else
#define VC_LORA_PIXHAWK_UART_NUM 0
#endif
#endif
HardwareSerial PixhawkSerial(VC_LORA_PIXHAWK_UART_NUM);
#endif

struct DirectionStats {
  uint32_t input_bytes = 0;
  uint32_t bytes = 0;
  uint32_t chunks = 0;
  uint32_t short_writes = 0;
  uint32_t aux_timeouts = 0;
  uint32_t last_ms = 0;
};

static DirectionStats uplink_stats;
static DirectionStats downlink_stats;
static uint8_t io_buf[IO_CHUNK_BYTES];
static uint8_t e220_tx_buf[IO_CHUNK_BYTES];
static size_t e220_tx_len = 0;
static uint32_t e220_tx_last_input_ms = 0;
static uint8_t e220_profile_observed[sizeof(E220_PROFILE)] = {};
static bool e220_profile_read_ok = false;
static bool e220_profile_match = false;
static bool e220_profile_was_written = false;
static uint32_t last_stats_ms = 0;
static uint32_t last_test_heartbeat_ms = 0;
static uint8_t mav_seq = 0;
static uint32_t tdd_epoch_ms = 0;
static uint32_t tdd_last_radio_rx_ms = 0;
static uint32_t tdd_ground_resyncs = 0;

#if VC_LORA_ROLE == VC_LORA_ROLE_VEHICLE
static constexpr size_t MAVLINK_MAX_FRAME_BYTES = 280;
static uint8_t mavlink_collect_buf[MAVLINK_MAX_FRAME_BYTES] = {};
static size_t mavlink_collect_len = 0;
static size_t mavlink_collect_expected = 0;
static uint8_t mavlink_pending_buf[MAVLINK_MAX_FRAME_BYTES] = {};
static size_t mavlink_pending_len = 0;
static size_t mavlink_pending_pos = 0;
struct MavlinkQueuedFrame {
  uint16_t length = 0;
  uint8_t data[MAVLINK_MAX_FRAME_BYTES] = {};
};
static constexpr size_t MAVLINK_QUEUE_SLOTS = 8;
static MavlinkQueuedFrame mavlink_queue[MAVLINK_QUEUE_SLOTS];
static size_t mavlink_queue_head = 0;
static size_t mavlink_queue_tail = 0;
static size_t mavlink_queue_count = 0;
static uint8_t mavlink_heartbeat_buf[MAVLINK_MAX_FRAME_BYTES] = {};
static size_t mavlink_heartbeat_len = 0;
static bool mavlink_heartbeat_queued = false;
static uint32_t mavlink_frames_forwarded = 0;
static uint32_t mavlink_frames_dropped = 0;
static uint32_t mavlink_bytes_dropped = 0;
static uint32_t mavlink_queue_drops = 0;
static uint32_t mavlink_heartbeat_overwrites = 0;
static uint32_t mavlink_noise_bytes = 0;
static uint32_t mavlink_parser_resets = 0;
static uint32_t mavlink_last_sys_status_ms = 0;
static uint32_t mavlink_last_gps_ms = 0;
static uint32_t mavlink_last_attitude_ms = 0;
static uint32_t mavlink_last_global_position_ms = 0;
static uint32_t mavlink_last_vfr_hud_ms = 0;
static uint32_t mavlink_last_power_ms = 0;
static uint32_t mavlink_last_ekf_ms = 0;
#endif

static void crc_accumulate(uint8_t data, uint16_t *crc) {
  data ^= static_cast<uint8_t>(*crc & 0xff);
  data ^= data << 4;
  *crc = (*crc >> 8) ^ (static_cast<uint16_t>(data) << 8) ^
         (static_cast<uint16_t>(data) << 3) ^ (static_cast<uint16_t>(data) >> 4);
}

static uint16_t mavlink_crc(const uint8_t *buffer, size_t length, uint8_t crc_extra) {
  uint16_t crc = 0xffff;
  for (size_t i = 0; i < length; ++i) {
    crc_accumulate(buffer[i], &crc);
  }
  crc_accumulate(crc_extra, &crc);
  return crc;
}

static bool wait_aux_high(uint32_t timeout_us) {
  if (!RESPECT_E220_AUX) {
    return true;
  }

  const uint32_t start = micros();
  while (digitalRead(E220_AUX_PIN) == LOW) {
    if (micros() - start >= timeout_us) {
      return false;
    }
    yield();
  }
  return true;
}

static void set_e220_normal_transparent_mode() {
  pinMode(E220_M0_PIN, OUTPUT);
  pinMode(E220_M1_PIN, OUTPUT);
  pinMode(E220_AUX_PIN, INPUT_PULLUP);

  // M0=0, M1=0: normal transparent transmission mode.
  digitalWrite(E220_M0_PIN, LOW);
  digitalWrite(E220_M1_PIN, LOW);
  delay(50);
  wait_aux_high(200000);
}

static void drain_e220_config_rx(uint32_t duration_ms) {
  const uint32_t start = millis();
  while (millis() - start < duration_ms) {
    while (E220Serial.available() > 0) {
      E220Serial.read();
    }
    delay(1);
  }
}

static size_t collect_e220_config_response(uint8_t *buffer, size_t capacity,
                                           uint32_t timeout_ms) {
  size_t length = 0;
  const uint32_t start = millis();
  while (millis() - start < timeout_ms) {
    while (E220Serial.available() > 0 && length < capacity) {
      buffer[length++] = static_cast<uint8_t>(E220Serial.read());
    }
    delay(1);
  }
  return length;
}

static bool e220_config_command(const uint8_t *command, size_t command_len,
                                uint8_t *response, size_t response_capacity,
                                size_t expected_len) {
  drain_e220_config_rx(30);
  if (!wait_aux_high(200000)) {
    return false;
  }
  if (E220Serial.write(command, command_len) != command_len) {
    return false;
  }
  E220Serial.flush();
  const size_t response_len =
      collect_e220_config_response(response, response_capacity, 500);
  return response_len >= expected_len;
}

static bool read_e220_profile(uint8_t *profile) {
  const uint8_t command[] = {0xC1, 0x00, sizeof(E220_PROFILE)};
  uint8_t response[sizeof(E220_PROFILE) + 3] = {};
  if (!e220_config_command(command, sizeof(command), response,
                           sizeof(response), sizeof(response))) {
    return false;
  }
  if (response[0] != 0xC1 || response[1] != 0x00 ||
      response[2] != sizeof(E220_PROFILE)) {
    return false;
  }
  memcpy(profile, response + 3, sizeof(E220_PROFILE));
  return true;
}

static bool write_e220_profile() {
  uint8_t command[sizeof(E220_PROFILE) + 3] = {
      0xC0, 0x00, sizeof(E220_PROFILE)};
  memcpy(command + 3, E220_PROFILE, sizeof(E220_PROFILE));
  uint8_t response[sizeof(command)] = {};
  return e220_config_command(command, sizeof(command), response,
                             sizeof(response), sizeof(response)) &&
         response[0] == 0xC1 && response[1] == 0x00 &&
         response[2] == sizeof(E220_PROFILE);
}

static bool ensure_e220_profile() {
  if (!AUTO_CONFIGURE_E220) {
    return true;
  }

  // E220 configuration mode always uses 9600 8N1, independently of REG0.
  pinMode(E220_M0_PIN, OUTPUT);
  pinMode(E220_M1_PIN, OUTPUT);
  pinMode(E220_AUX_PIN, INPUT_PULLUP);
  digitalWrite(E220_M0_PIN, HIGH);
  digitalWrite(E220_M1_PIN, HIGH);
  delay(120);

  E220Serial.setRxBufferSize(SERIAL_RX_BUFFER_BYTES);
  E220Serial.begin(9600, SERIAL_8N1, E220_RX_PIN, E220_TX_PIN);
  E220Serial.setTimeout(20);

  uint8_t actual[sizeof(E220_PROFILE)] = {};
  bool ready = read_e220_profile(actual);
  e220_profile_read_ok = ready;
  if (ready) {
    memcpy(e220_profile_observed, actual, sizeof(actual));
  }
  if (ready && memcmp(actual, E220_PROFILE, sizeof(E220_PROFILE)) != 0) {
    ready = write_e220_profile();
    e220_profile_was_written = ready;
    delay(200);
    memset(actual, 0, sizeof(actual));
    ready = ready && read_e220_profile(actual) &&
            memcmp(actual, E220_PROFILE, sizeof(E220_PROFILE)) == 0;
    if (ready) {
      memcpy(e220_profile_observed, actual, sizeof(actual));
    }
  }
  e220_profile_match = ready &&
                       memcmp(e220_profile_observed, E220_PROFILE,
                              sizeof(E220_PROFILE)) == 0;

  E220Serial.end();
  delay(20);
  return ready;
}

// Send one contiguous UART block only while AUX is ready. Source bytes are
// accumulated in RAM first, because several short writes cause the E220 to
// close separate radio packets and discard the following bytes while busy.
static size_t flush_e220_tx(DirectionStats &stats) {
  if (e220_tx_len == 0) {
    return 0;
  }
  if (E220_MIN_TX_GAP_MS > 0 && stats.last_ms != 0 &&
      millis() - stats.last_ms < E220_MIN_TX_GAP_MS) {
    return 0;
  }
  if (!wait_aux_high(AUX_WAIT_US)) {
    stats.aux_timeouts++;
    return 0;
  }

  const size_t requested = e220_tx_len;
  const size_t written = E220Serial.write(e220_tx_buf, requested);
  E220Serial.flush();
  stats.bytes += static_cast<uint32_t>(written);
  stats.chunks++;
  stats.last_ms = millis();
  if (written != requested) {
    stats.short_writes++;
  }

  if (written < requested) {
    memmove(e220_tx_buf, e220_tx_buf + written, requested - written);
  }
  e220_tx_len = requested - written;
  return written;
}

static size_t queue_e220_tx(const uint8_t *data, size_t length) {
  const size_t space = sizeof(e220_tx_buf) - e220_tx_len;
  const size_t queued = min(length, space);
  if (queued > 0) {
    memcpy(e220_tx_buf + e220_tx_len, data, queued);
    e220_tx_len += queued;
    e220_tx_last_input_ms = millis();
  }
  return queued;
}

static size_t pump_to_e220(Stream &input, DirectionStats &stats) {
  const int available = input.available();
  if (available > 0 && e220_tx_len < sizeof(e220_tx_buf)) {
    const size_t read_target = min(static_cast<size_t>(available),
                                   sizeof(e220_tx_buf) - e220_tx_len);
    const int read_len = input.readBytes(e220_tx_buf + e220_tx_len, read_target);
    if (read_len > 0) {
      e220_tx_len += static_cast<size_t>(read_len);
      stats.input_bytes += static_cast<uint32_t>(read_len);
      e220_tx_last_input_ms = millis();
    }
  }

  if (e220_tx_len == 0) {
    return 0;
  }

  const bool full_packet = e220_tx_len == sizeof(e220_tx_buf);
  const bool partial_timed_out =
      millis() - e220_tx_last_input_ms >= E220_PARTIAL_FLUSH_MS;
  if (!full_packet && !partial_timed_out) {
    return 0;
  }

  return flush_e220_tx(stats);
}

static size_t pump_bytes(Stream &input, Print &output, DirectionStats &stats, bool output_is_radio) {
  if (output_is_radio) {
    return pump_to_e220(input, stats);
  }

  const int available = input.available();
  if (available <= 0) {
    return 0;
  }

  const size_t read_target = min(static_cast<size_t>(available), sizeof(io_buf));
  const int read_len = input.readBytes(io_buf, read_target);
  if (read_len <= 0) {
    return 0;
  }

  const size_t written = output.write(io_buf, static_cast<size_t>(read_len));
  stats.input_bytes += static_cast<uint32_t>(read_len);
  stats.bytes += static_cast<uint32_t>(written);
  stats.chunks++;
  stats.last_ms = millis();
  if (written != static_cast<size_t>(read_len)) {
    stats.short_writes++;
  }
  return written;
}

static void tdd_note_radio_receive(size_t received_bytes) {
  if (received_bytes > 0) {
    tdd_last_radio_rx_ms = millis();
  }
}

static bool tdd_vehicle_tx_allowed(uint32_t now) {
  if (!TDD_ENABLE) {
    return true;
  }
  const uint32_t phase = (now - tdd_epoch_ms) % TDD_CYCLE_MS;
  return phase < TDD_VEHICLE_TX_MS;
}

static bool tdd_ground_tx_allowed(uint32_t now) {
  if (!TDD_ENABLE) {
    return true;
  }

  uint32_t silence_ms = now - tdd_last_radio_rx_ms;
  // If no telemetry was received for a complete cycle, start another search
  // window. Normal operation re-synchronizes on every received telemetry byte.
  if (silence_ms >= TDD_CYCLE_MS) {
    tdd_last_radio_rx_ms = now;
    ++tdd_ground_resyncs;
    silence_ms = 0;
  }
  return silence_ms >= TDD_GROUND_TX_START_MS &&
         silence_ms < TDD_GROUND_TX_END_MS;
}

#if VC_LORA_ROLE == VC_LORA_ROLE_VEHICLE
static void reset_mavlink_collector() {
  mavlink_collect_len = 0;
  mavlink_collect_expected = 0;
}

static uint32_t collected_mavlink_message_id() {
  if (mavlink_collect_buf[0] == 0xFD && mavlink_collect_len >= 10) {
    return static_cast<uint32_t>(mavlink_collect_buf[7]) |
           (static_cast<uint32_t>(mavlink_collect_buf[8]) << 8) |
           (static_cast<uint32_t>(mavlink_collect_buf[9]) << 16);
  }
  if (mavlink_collect_buf[0] == 0xFE && mavlink_collect_len >= 6) {
    return mavlink_collect_buf[5];
  }
  return 0xFFFFFFFFUL;
}

static void drop_collected_mavlink_frame(bool queue_drop = false) {
  ++mavlink_frames_dropped;
  mavlink_bytes_dropped += static_cast<uint32_t>(mavlink_collect_len);
  if (queue_drop) {
    ++mavlink_queue_drops;
  }
}

static bool mavlink_is_urgent_response(uint32_t message_id) {
  switch (message_id) {
    case 40:   // MISSION_REQUEST
    case 42:   // MISSION_CURRENT
    case 44:   // MISSION_COUNT
    case 47:   // MISSION_ACK
    case 51:   // MISSION_REQUEST_INT
    case 73:   // MISSION_ITEM_INT
    case 77:   // COMMAND_ACK
    case 110:  // FILE_TRANSFER_PROTOCOL
    case 148:  // AUTOPILOT_VERSION
    case 242:  // HOME_POSITION
    case 253:  // STATUSTEXT
    case 320:  // PARAM_EXT_REQUEST_READ
    case 321:  // PARAM_EXT_REQUEST_LIST
    case 322:  // PARAM_EXT_VALUE
    case 323:  // PARAM_EXT_SET
    case 324:  // PARAM_EXT_ACK
      return true;
    default:
      return false;
  }
}

static bool mavlink_low_rate_telemetry_due(uint32_t message_id) {
  uint32_t *last_ms = nullptr;
  switch (message_id) {
    case 1:   // SYS_STATUS
      last_ms = &mavlink_last_sys_status_ms;
      break;
    case 24:  // GPS_RAW_INT
      last_ms = &mavlink_last_gps_ms;
      break;
    case 30:  // ATTITUDE
      last_ms = &mavlink_last_attitude_ms;
      break;
    case 33:  // GLOBAL_POSITION_INT
      last_ms = &mavlink_last_global_position_ms;
      break;
    case 74:  // VFR_HUD
      last_ms = &mavlink_last_vfr_hud_ms;
      break;
    case 125: // POWER_STATUS
    case 147: // BATTERY_STATUS
      last_ms = &mavlink_last_power_ms;
      break;
    case 193: // EKF_STATUS_REPORT
    case 230: // ESTIMATOR_STATUS
    case 241: // VIBRATION
      last_ms = &mavlink_last_ekf_ms;
      break;
    default:
      return false;
  }

  const uint32_t now = millis();
  if (*last_ms != 0 && now - *last_ms < 1000) {
    return false;
  }
  *last_ms = now;
  return true;
}

static bool enqueue_mavlink_frame(bool urgent) {
  if (mavlink_queue_count >= MAVLINK_QUEUE_SLOTS) {
    if (!urgent) {
      drop_collected_mavlink_frame(true);
      return false;
    }
    // Make room for command/status responses by discarding the oldest queued
    // non-transmitting frame. The active frame is never truncated.
    mavlink_frames_dropped++;
    mavlink_bytes_dropped += mavlink_queue[mavlink_queue_head].length;
    ++mavlink_queue_drops;
    mavlink_queue_head = (mavlink_queue_head + 1) % MAVLINK_QUEUE_SLOTS;
    --mavlink_queue_count;
  }

  MavlinkQueuedFrame &slot = mavlink_queue[mavlink_queue_tail];
  slot.length = static_cast<uint16_t>(mavlink_collect_len);
  memcpy(slot.data, mavlink_collect_buf, mavlink_collect_len);
  mavlink_queue_tail = (mavlink_queue_tail + 1) % MAVLINK_QUEUE_SLOTS;
  ++mavlink_queue_count;
  return true;
}

static void finish_collected_mavlink_frame() {
  const uint32_t message_id = collected_mavlink_message_id();
  if (message_id == 0) {
    if (mavlink_heartbeat_queued) {
      ++mavlink_heartbeat_overwrites;
    }
    memcpy(mavlink_heartbeat_buf, mavlink_collect_buf, mavlink_collect_len);
    mavlink_heartbeat_len = mavlink_collect_len;
    mavlink_heartbeat_queued = true;
  } else if (message_id == DROP_MAVLINK_MSG_ID) {
    drop_collected_mavlink_frame(false);
  } else if (message_id == 22) {  // PARAM_VALUE
    enqueue_mavlink_frame(false);
  } else if (mavlink_is_urgent_response(message_id)) {
    enqueue_mavlink_frame(true);
  } else if (mavlink_low_rate_telemetry_due(message_id)) {
    enqueue_mavlink_frame(false);
  } else {
    drop_collected_mavlink_frame(false);
  }
  reset_mavlink_collector();
}

static void collect_pixhawk_mavlink() {
  // Parse continuously, even while radio frames are queued, so high-rate
  // excluded telemetry cannot fill and corrupt the Pixhawk UART buffer.
  size_t read_budget = 2048;
  while (PixhawkSerial.available() > 0 && read_budget-- > 0) {
    const int raw = PixhawkSerial.read();
    if (raw < 0) {
      break;
    }
    const uint8_t value = static_cast<uint8_t>(raw);
    ++uplink_stats.input_bytes;

    if (mavlink_collect_len == 0) {
      if (value != 0xFD && value != 0xFE) {
        ++mavlink_noise_bytes;
        continue;
      }
      mavlink_collect_buf[mavlink_collect_len++] = value;
      continue;
    }

    if (mavlink_collect_len >= sizeof(mavlink_collect_buf)) {
      ++mavlink_parser_resets;
      reset_mavlink_collector();
      continue;
    }
    mavlink_collect_buf[mavlink_collect_len++] = value;

    if (mavlink_collect_buf[0] == 0xFE && mavlink_collect_len == 2) {
      mavlink_collect_expected =
          8 + static_cast<size_t>(mavlink_collect_buf[1]);
    } else if (mavlink_collect_buf[0] == 0xFD &&
               mavlink_collect_len == 3) {
      const size_t signature_bytes =
          (mavlink_collect_buf[2] & 0x01) != 0 ? 13 : 0;
      mavlink_collect_expected =
          12 + static_cast<size_t>(mavlink_collect_buf[1]) + signature_bytes;
    }

    if (mavlink_collect_expected > sizeof(mavlink_collect_buf)) {
      ++mavlink_parser_resets;
      reset_mavlink_collector();
      continue;
    }
    if (mavlink_collect_expected > 0 &&
        mavlink_collect_len == mavlink_collect_expected) {
      finish_collected_mavlink_frame();
    }
  }
}

static void load_next_mavlink_frame() {
  if (mavlink_pending_len != 0) {
    return;
  }
  if (mavlink_heartbeat_queued) {
    memcpy(mavlink_pending_buf, mavlink_heartbeat_buf, mavlink_heartbeat_len);
    mavlink_pending_len = mavlink_heartbeat_len;
    mavlink_pending_pos = 0;
    mavlink_heartbeat_queued = false;
    return;
  }
  if (mavlink_queue_count == 0) {
    return;
  }

  MavlinkQueuedFrame &slot = mavlink_queue[mavlink_queue_head];
  memcpy(mavlink_pending_buf, slot.data, slot.length);
  mavlink_pending_len = slot.length;
  mavlink_pending_pos = 0;
  mavlink_queue_head = (mavlink_queue_head + 1) % MAVLINK_QUEUE_SLOTS;
  --mavlink_queue_count;
}

static size_t pump_filtered_pixhawk_mavlink_to_e220() {
  collect_pixhawk_mavlink();
  load_next_mavlink_frame();
  if (mavlink_pending_len == 0) {
    return 0;
  }

  if (e220_tx_len == 0 && mavlink_pending_pos < mavlink_pending_len) {
    const size_t remaining = mavlink_pending_len - mavlink_pending_pos;
    const size_t chunk = min(remaining, sizeof(e220_tx_buf));
    queue_e220_tx(mavlink_pending_buf + mavlink_pending_pos, chunk);
    mavlink_pending_pos += chunk;
  }

  const size_t written = flush_e220_tx(uplink_stats);
  if (written > 0 && e220_tx_len == 0 &&
      mavlink_pending_pos >= mavlink_pending_len) {
    ++mavlink_frames_forwarded;
    mavlink_pending_len = 0;
    mavlink_pending_pos = 0;
  }
  return written;
}
#endif

static size_t write_counted(Print &output, const uint8_t *data, size_t length,
                            DirectionStats &stats, bool output_is_radio) {
  if (output_is_radio) {
    const size_t queued = queue_e220_tx(data, length);
    stats.input_bytes += static_cast<uint32_t>(queued);
    if (queued != length) {
      stats.short_writes++;
    }
    return queued;
  }

  const size_t written = output.write(data, length);
  stats.input_bytes += static_cast<uint32_t>(length);
  stats.bytes += static_cast<uint32_t>(written);
  stats.chunks++;
  stats.last_ms = millis();
  if (written != length) {
    stats.short_writes++;
  }
  return written;
}

static void send_test_heartbeat(Print &output, DirectionStats &stats, bool output_is_radio) {
  uint8_t payload[9] = {};
  payload[4] = 18;  // MAV_TYPE_ONBOARD_CONTROLLER.
  payload[5] = 8;   // MAV_AUTOPILOT_INVALID.
  payload[7] = 4;   // MAV_STATE_ACTIVE.
  payload[8] = 3;   // MAVLink v1 marker.

  uint8_t packet[6 + sizeof(payload) + 2] = {};
  packet[0] = 0xFE;
  packet[1] = sizeof(payload);
  packet[2] = mav_seq++;
  packet[3] = MAV_SYS_ID;
  packet[4] = MAV_COMP_ID;
  packet[5] = MAV_MSG_ID_HEARTBEAT;
  memcpy(&packet[6], payload, sizeof(payload));

  uint8_t crc_input[5 + sizeof(payload)] = {};
  memcpy(crc_input, &packet[1], 5);
  memcpy(&crc_input[5], payload, sizeof(payload));
  const uint16_t crc = mavlink_crc(crc_input, sizeof(crc_input), MAV_CRC_HEARTBEAT);
  packet[6 + sizeof(payload)] = static_cast<uint8_t>(crc & 0xff);
  packet[7 + sizeof(payload)] = static_cast<uint8_t>((crc >> 8) & 0xff);

  write_counted(output, packet, sizeof(packet), stats, output_is_radio);
}

static void send_periodic_test_heartbeat() {
  const uint32_t now = millis();
  if (now - last_test_heartbeat_ms < TEST_HEARTBEAT_INTERVAL_MS) {
    return;
  }
  last_test_heartbeat_ms = now;

#if VC_LORA_ROLE == VC_LORA_ROLE_GROUND
  if (GROUND_USB_SELFTEST_HEARTBEAT) {
    send_test_heartbeat(Serial, downlink_stats, false);
  }
#else
  if (VEHICLE_LORA_TEST_HEARTBEAT) {
    send_test_heartbeat(E220Serial, uplink_stats, true);
  }
#endif
}

static void debug_print_stats() {
  if (!USB_DEBUG) {
    return;
  }

  const uint32_t now = millis();
  if (now - last_stats_ms < STATS_INTERVAL_MS) {
    return;
  }
  last_stats_ms = now;

  Serial.print("[VC_LoRa] role=");
#if VC_LORA_ROLE == VC_LORA_ROLE_VEHICLE
  Serial.print("VEHICLE");
#else
  Serial.print("GROUND");
#endif
  Serial.print(" up_in=");
  Serial.print(uplink_stats.input_bytes);
  Serial.print(" up_tx=");
  Serial.print(uplink_stats.bytes);
  Serial.print(" down_in=");
  Serial.print(downlink_stats.input_bytes);
  Serial.print(" down_tx=");
  Serial.print(downlink_stats.bytes);
  Serial.print(" up_aux_to=");
  Serial.print(uplink_stats.aux_timeouts);
  Serial.print(" down_aux_to=");
  Serial.print(downlink_stats.aux_timeouts);
  Serial.print(" aux_wait=");
  Serial.print(RESPECT_E220_AUX ? "ON" : "OFF");
  Serial.print(" min_gap_ms=");
  Serial.print(E220_MIN_TX_GAP_MS);
  Serial.print(" stage=");
  Serial.print(e220_tx_len);
#if VC_LORA_ROLE == VC_LORA_ROLE_VEHICLE
  Serial.print(" mav_fwd=");
  Serial.print(mavlink_frames_forwarded);
  Serial.print(" mav_drop=");
  Serial.print(mavlink_frames_dropped);
  Serial.print(" mav_drop_bytes=");
  Serial.print(mavlink_bytes_dropped);
  Serial.print(" mav_pending=");
  Serial.print(mavlink_pending_len > mavlink_pending_pos
                   ? mavlink_pending_len - mavlink_pending_pos
                   : 0);
  Serial.print(" mav_q=");
  Serial.print(mavlink_queue_count);
  Serial.print(" mav_q_drop=");
  Serial.print(mavlink_queue_drops);
  Serial.print(" hb_wait=");
  Serial.print(mavlink_heartbeat_queued ? 1 : 0);
  Serial.print(" hb_replace=");
  Serial.print(mavlink_heartbeat_overwrites);
  Serial.print(" mav_noise=");
  Serial.print(mavlink_noise_bytes);
  Serial.print(" mav_reset=");
  Serial.print(mavlink_parser_resets);
#endif
  Serial.print(" cfg=");
  if (!e220_profile_read_ok) {
    Serial.print("READ_FAIL");
  } else {
    Serial.print(e220_profile_match ? "PASS" : "MISMATCH");
  }
  Serial.print(" cfg_write=");
  Serial.print(e220_profile_was_written ? "YES" : "NO");
  Serial.print(" reg0=0x");
  if (e220_profile_observed[2] < 0x10) Serial.print('0');
  Serial.print(e220_profile_observed[2], HEX);
  Serial.print(" reg1=0x");
  if (e220_profile_observed[3] < 0x10) Serial.print('0');
  Serial.print(e220_profile_observed[3], HEX);
  Serial.print(" tdd=");
  Serial.print(TDD_ENABLE ? "ON" : "OFF");
#if VC_LORA_ROLE == VC_LORA_ROLE_VEHICLE
  if (TDD_ENABLE) {
    const uint32_t phase = (now - tdd_epoch_ms) % TDD_CYCLE_MS;
    Serial.print(" phase=");
    Serial.print(phase < TDD_VEHICLE_TX_MS ? "TX" : "RX");
    Serial.print(" phase_ms=");
    Serial.print(phase);
    Serial.print(" fc_wait=");
    Serial.print(PixhawkSerial.available());
  }
#else
  if (TDD_ENABLE) {
    Serial.print(" silence_ms=");
    Serial.print(now - tdd_last_radio_rx_ms);
    Serial.print(" resync=");
    Serial.print(tdd_ground_resyncs);
  }
#endif
  Serial.print(" aux=");
  Serial.println(digitalRead(E220_AUX_PIN) == HIGH ? "HIGH" : "LOW");
}

void setup() {
  ensure_e220_profile();
  set_e220_normal_transparent_mode();

  E220Serial.setRxBufferSize(SERIAL_RX_BUFFER_BYTES);
  E220Serial.begin(E220_UART_BAUD, SERIAL_8N1, E220_RX_PIN, E220_TX_PIN);
  E220Serial.setTimeout(1);

#if VC_LORA_ROLE == VC_LORA_ROLE_GROUND
  // USB CDC is the Mission Planner raw MAVLink port.
  Serial.begin(MAVLINK_BAUD);
  Serial.setTimeout(1);
#else
  // USB CDC is debug only in vehicle role. Pixhawk uses a separate UART on D6/D7.
  if (USB_DEBUG) {
    Serial.begin(DEBUG_BAUD);
    Serial.setTimeout(1);
    delay(500);
    Serial.println();
    Serial.println("=== VC_LoRa vehicle bridge boot ===");
    Serial.print("E220 UART: RX GPIO");
    Serial.print(E220_RX_PIN);
    Serial.print(" TX GPIO");
    Serial.print(E220_TX_PIN);
    Serial.print(" baud ");
    Serial.println(E220_UART_BAUD);
    Serial.print("Pixhawk UART: RX GPIO");
    Serial.print(FC_RX_PIN);
    Serial.print(" TX GPIO");
    Serial.print(FC_TX_PIN);
    Serial.print(" uart ");
    Serial.print(VC_LORA_PIXHAWK_UART_NUM);
    Serial.print(" baud ");
    Serial.println(MAVLINK_BAUD);
  }

  PixhawkSerial.setRxBufferSize(SERIAL_RX_BUFFER_BYTES);
  PixhawkSerial.begin(MAVLINK_BAUD, SERIAL_8N1, FC_RX_PIN, FC_TX_PIN);
  PixhawkSerial.setTimeout(1);
#endif

  tdd_epoch_ms = millis();
  tdd_last_radio_rx_ms = tdd_epoch_ms;
}

void loop() {
#if VC_LORA_ROLE == VC_LORA_ROLE_GROUND
  // LoRa -> PC is always drained. PC -> LoRa is restricted to a short window
  // detected from the end of the vehicle telemetry burst.
  const size_t radio_rx =
      pump_bytes(E220Serial, Serial, downlink_stats, false);
  tdd_note_radio_receive(radio_rx);
  if (tdd_ground_tx_allowed(millis())) {
    pump_bytes(Serial, E220Serial, uplink_stats, true);
  }
  send_periodic_test_heartbeat();
#else
  // LoRa -> Pixhawk is always drained. Pixhawk -> LoRa is stopped for the RX
  // window, leaving enough time for the ground command burst and both radio
  // direction changes.
  const size_t radio_rx =
      pump_bytes(E220Serial, PixhawkSerial, downlink_stats, false);
  tdd_note_radio_receive(radio_rx);
  if (FILTER_PIXHAWK_MAVLINK) {
    collect_pixhawk_mavlink();
  }
  if (tdd_vehicle_tx_allowed(millis())) {
    if (FILTER_PIXHAWK_MAVLINK) {
      pump_filtered_pixhawk_mavlink_to_e220();
    } else {
      pump_bytes(PixhawkSerial, E220Serial, uplink_stats, true);
    }
  }
  send_periodic_test_heartbeat();
  debug_print_stats();
#endif
}
