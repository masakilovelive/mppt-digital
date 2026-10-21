/*
  VC_LoRa Pixhawk TELEM sniff diagnostic for XIAO ESP32-S3.

  Purpose:
    - Isolate Pixhawk TELEM <-> Vehicle XIAO wiring/baud/pin issues.
    - Do not use E220, LoRa, Mission Planner, UI, or MAVProxy.

  Arduino Serial Monitor:
    USB baud: 115200

  Expected wiring:
    XIAO D7 <- Pixhawk TELEM TX
    XIAO D6 -> Pixhawk TELEM RX
    XIAO GND <-> Pixhawk GND
*/

#include <Arduino.h>
#include <string.h>

static constexpr uint32_t USB_BAUD = 115200;
static constexpr uint32_t SCAN_MS = 2500;
static constexpr uint32_t REPORT_MS = 1000;

struct UartCandidate {
  const char *label;
  int rx_pin;
  int tx_pin;
};

static const UartCandidate PIN_CANDIDATES[] = {
  {"expected D7 RX / D6 TX", D7, D6},
  {"alternate D6 RX / D7 TX", D6, D7},
  {"test D3 RX / D2 TX", D3, D2},
  {"test D2 RX / D3 TX", D2, D3},
};

static const uint32_t BAUD_CANDIDATES[] = {57600, 115200, 38400, 9600};

static constexpr uint8_t MAVLINK_MSG_ID_HEARTBEAT = 0;
static constexpr uint8_t MAVLINK_CRC_EXTRA_HEARTBEAT = 50;

HardwareSerial PixhawkSerial(2);

struct SniffStats {
  uint32_t raw_bytes = 0;
  uint32_t sync_fe = 0;
  uint32_t sync_fd = 0;
  uint32_t frame_candidates = 0;
  uint32_t valid_heartbeat = 0;
  uint32_t heartbeat_crc_error = 0;
  uint32_t parser_reset = 0;
  uint32_t last_heartbeat_ms = 0;
  uint32_t last_msgid = 0;
  uint8_t last_sysid = 0;
  uint8_t last_compid = 0;
  uint8_t sample[40] = {};
  uint8_t sample_len = 0;
};

static SniffStats stats;

static uint8_t parser_sync = 0;
static uint8_t parser_buf[300] = {};
static uint8_t parser_len = 0;
static size_t parser_pos = 0;
static size_t parser_need = 0;

static const UartCandidate *active_pin = &PIN_CANDIDATES[0];
static uint32_t active_baud = BAUD_CANDIDATES[0];
static uint32_t last_report_ms = 0;
static uint32_t last_raw_report = 0;
static uint32_t last_hb_report = 0;
static bool led_on = false;

static void crc_accumulate(uint8_t data, uint16_t &crc) {
  data ^= static_cast<uint8_t>(crc & 0xff);
  data ^= static_cast<uint8_t>(data << 4);
  crc = (crc >> 8) ^
        (static_cast<uint16_t>(data) << 8) ^
        (static_cast<uint16_t>(data) << 3) ^
        (static_cast<uint16_t>(data) >> 4);
}

static uint16_t crc_calculate(const uint8_t *buffer, size_t length, uint8_t extra_crc) {
  uint16_t crc = 0xffff;
  for (size_t i = 0; i < length; ++i) {
    crc_accumulate(buffer[i], crc);
  }
  crc_accumulate(extra_crc, crc);
  return crc;
}

static void reset_stats() {
  stats = SniffStats{};
  parser_sync = 0;
  parser_len = 0;
  parser_pos = 0;
  parser_need = 0;
  last_raw_report = 0;
  last_hb_report = 0;
}

static void push_sample(uint8_t byte_value) {
  if (stats.sample_len < sizeof(stats.sample)) {
    stats.sample[stats.sample_len++] = byte_value;
    return;
  }

  memmove(stats.sample, stats.sample + 1, sizeof(stats.sample) - 1);
  stats.sample[sizeof(stats.sample) - 1] = byte_value;
}

static void reset_parser() {
  parser_sync = 0;
  parser_len = 0;
  parser_pos = 0;
  parser_need = 0;
  stats.parser_reset++;
}

static void handle_v1_frame(const uint8_t *frame, size_t frame_len) {
  if (frame_len < 7) {
    return;
  }

  const uint8_t payload_len = frame[0];
  const uint8_t sysid = frame[2];
  const uint8_t compid = frame[3];
  const uint8_t msgid = frame[4];
  const size_t checksum_index = 5U + payload_len;

  stats.frame_candidates++;
  stats.last_msgid = msgid;
  stats.last_sysid = sysid;
  stats.last_compid = compid;

  if (msgid != MAVLINK_MSG_ID_HEARTBEAT || checksum_index + 1 >= frame_len) {
    return;
  }

  const uint16_t calculated = crc_calculate(frame, 5U + payload_len, MAVLINK_CRC_EXTRA_HEARTBEAT);
  const uint16_t received = static_cast<uint16_t>(frame[checksum_index]) |
                            (static_cast<uint16_t>(frame[checksum_index + 1]) << 8);

  if (calculated == received) {
    stats.valid_heartbeat++;
    stats.last_heartbeat_ms = millis();
  } else {
    stats.heartbeat_crc_error++;
  }
}

static void handle_v2_frame(const uint8_t *frame, size_t frame_len) {
  if (frame_len < 11) {
    return;
  }

  const uint8_t payload_len = frame[0];
  const uint8_t sysid = frame[4];
  const uint8_t compid = frame[5];
  const uint32_t msgid = static_cast<uint32_t>(frame[6]) |
                         (static_cast<uint32_t>(frame[7]) << 8) |
                         (static_cast<uint32_t>(frame[8]) << 16);
  const size_t checksum_index = 9U + payload_len;

  stats.frame_candidates++;
  stats.last_msgid = msgid;
  stats.last_sysid = sysid;
  stats.last_compid = compid;

  if (msgid != MAVLINK_MSG_ID_HEARTBEAT || checksum_index + 1 >= frame_len) {
    return;
  }

  const uint16_t calculated = crc_calculate(frame, 9U + payload_len, MAVLINK_CRC_EXTRA_HEARTBEAT);
  const uint16_t received = static_cast<uint16_t>(frame[checksum_index]) |
                            (static_cast<uint16_t>(frame[checksum_index + 1]) << 8);

  if (calculated == received) {
    stats.valid_heartbeat++;
    stats.last_heartbeat_ms = millis();
  } else {
    stats.heartbeat_crc_error++;
  }
}

static void handle_byte(uint8_t byte_value) {
  stats.raw_bytes++;
  push_sample(byte_value);

  if (parser_sync == 0) {
    if (byte_value == 0xFE || byte_value == 0xFD) {
      parser_sync = byte_value;
      parser_pos = 0;
      parser_need = 0;
      parser_len = 0;
      if (byte_value == 0xFE) {
        stats.sync_fe++;
      } else {
        stats.sync_fd++;
      }
    }
    return;
  }

  if (parser_pos >= sizeof(parser_buf)) {
    reset_parser();
    return;
  }

  if (parser_sync == 0xFE) {
    if (parser_pos == 0) {
      parser_len = byte_value;
      parser_need = 5U + parser_len + 2U;
      if (parser_need > sizeof(parser_buf)) {
        reset_parser();
        return;
      }
    }

    parser_buf[parser_pos++] = byte_value;
    if (parser_pos >= parser_need) {
      handle_v1_frame(parser_buf, parser_pos);
      parser_sync = 0;
      parser_pos = 0;
      parser_need = 0;
    }
    return;
  }

  if (parser_sync == 0xFD) {
    if (parser_pos == 0) {
      parser_len = byte_value;
    } else if (parser_pos == 1) {
      const bool signed_packet = (byte_value & 0x01) != 0;
      parser_need = 9U + parser_len + 2U + (signed_packet ? 13U : 0U);
      if (parser_need > sizeof(parser_buf)) {
        reset_parser();
        return;
      }
    }

    parser_buf[parser_pos++] = byte_value;
    if (parser_need > 0 && parser_pos >= parser_need) {
      handle_v2_frame(parser_buf, parser_pos);
      parser_sync = 0;
      parser_pos = 0;
      parser_need = 0;
    }
  }
}

static void print_hex_byte(uint8_t value) {
  if (value < 0x10) {
    Serial.print('0');
  }
  Serial.print(value, HEX);
}

static void open_pixhawk_uart(const UartCandidate &candidate, uint32_t baud) {
  PixhawkSerial.end();
  delay(80);
  PixhawkSerial.setRxBufferSize(4096);
  PixhawkSerial.begin(baud, SERIAL_8N1, candidate.rx_pin, candidate.tx_pin);
  PixhawkSerial.setTimeout(1);
  delay(120);
  while (PixhawkSerial.available() > 0) {
    PixhawkSerial.read();
  }
}

static void read_for_ms(uint32_t duration_ms) {
  const uint32_t start_ms = millis();
  while (millis() - start_ms < duration_ms) {
    while (PixhawkSerial.available() > 0) {
      handle_byte(static_cast<uint8_t>(PixhawkSerial.read()));
    }
    delay(1);
  }
}

static uint32_t score_stats(const SniffStats &s) {
  return (s.valid_heartbeat * 100000UL) +
         (s.frame_candidates * 1000UL) +
         ((s.sync_fe + s.sync_fd) * 10UL) +
         s.raw_bytes;
}

static void print_sample() {
  for (uint8_t i = 0; i < stats.sample_len; ++i) {
    if (i > 0) {
      Serial.print(' ');
    }
    print_hex_byte(stats.sample[i]);
  }
}

static void print_scan_line(const UartCandidate &candidate, uint32_t baud) {
  Serial.print("[SCAN] ");
  Serial.print(candidate.label);
  Serial.print(" rx_pin=");
  Serial.print(candidate.rx_pin);
  Serial.print(" tx_pin=");
  Serial.print(candidate.tx_pin);
  Serial.print(" baud=");
  Serial.print(baud);
  Serial.print(" raw=");
  Serial.print(stats.raw_bytes);
  Serial.print(" syncFE=");
  Serial.print(stats.sync_fe);
  Serial.print(" syncFD=");
  Serial.print(stats.sync_fd);
  Serial.print(" frames=");
  Serial.print(stats.frame_candidates);
  Serial.print(" hb=");
  Serial.print(stats.valid_heartbeat);
  Serial.print(" hb_crc_err=");
  Serial.print(stats.heartbeat_crc_error);
  Serial.print(" last_msg=");
  Serial.print(stats.last_msgid);
  Serial.print(" sys=");
  Serial.print(stats.last_sysid);
  Serial.print(" comp=");
  Serial.print(stats.last_compid);
  Serial.print(" sample=");
  print_sample();
  Serial.println();
}

static void perform_scan() {
  uint32_t best_score = 0;
  const UartCandidate *best_pin = &PIN_CANDIDATES[0];
  uint32_t best_baud = BAUD_CANDIDATES[0];

  Serial.println("[SCAN] start. Keep Pixhawk TELEM connected and powered.");
  for (size_t pin_i = 0; pin_i < sizeof(PIN_CANDIDATES) / sizeof(PIN_CANDIDATES[0]); ++pin_i) {
    for (size_t baud_i = 0; baud_i < sizeof(BAUD_CANDIDATES) / sizeof(BAUD_CANDIDATES[0]); ++baud_i) {
      reset_stats();
      open_pixhawk_uart(PIN_CANDIDATES[pin_i], BAUD_CANDIDATES[baud_i]);
      read_for_ms(SCAN_MS);
      print_scan_line(PIN_CANDIDATES[pin_i], BAUD_CANDIDATES[baud_i]);

      const uint32_t score = score_stats(stats);
      if (score > best_score) {
        best_score = score;
        best_pin = &PIN_CANDIDATES[pin_i];
        best_baud = BAUD_CANDIDATES[baud_i];
      }
    }
  }

  active_pin = best_pin;
  active_baud = best_baud;
  reset_stats();
  open_pixhawk_uart(*active_pin, active_baud);

  Serial.print("[SELECT] ");
  Serial.print(active_pin->label);
  Serial.print(" baud=");
  Serial.print(active_baud);
  if (best_score == 0) {
    Serial.print(" score=0. No UART bytes were detected on scanned pins.");
  }
  Serial.println();
  last_report_ms = millis();
}

static void print_report() {
  const uint32_t now_ms = millis();
  const uint32_t raw_delta = stats.raw_bytes - last_raw_report;
  const uint32_t hb_delta = stats.valid_heartbeat - last_hb_report;

  Serial.print("[PIXHAWK_SNIFF] ");
  Serial.print(active_pin->label);
  Serial.print(" baud=");
  Serial.print(active_baud);
  Serial.print(" raw=");
  Serial.print(stats.raw_bytes);
  Serial.print(" raw/s=");
  Serial.print(raw_delta);
  Serial.print(" syncFE=");
  Serial.print(stats.sync_fe);
  Serial.print(" syncFD=");
  Serial.print(stats.sync_fd);
  Serial.print(" frames=");
  Serial.print(stats.frame_candidates);
  Serial.print(" hb=");
  Serial.print(stats.valid_heartbeat);
  Serial.print(" hb/s=");
  Serial.print(hb_delta);
  Serial.print(" hb_crc_err=");
  Serial.print(stats.heartbeat_crc_error);
  Serial.print(" last_msg=");
  Serial.print(stats.last_msgid);
  Serial.print(" sys=");
  Serial.print(stats.last_sysid);
  Serial.print(" comp=");
  Serial.print(stats.last_compid);
  Serial.print(" hb_age_ms=");
  if (stats.last_heartbeat_ms == 0) {
    Serial.print("--");
  } else {
    Serial.print(now_ms - stats.last_heartbeat_ms);
  }
  Serial.print(" sample=");
  print_sample();
  Serial.println();

  last_raw_report = stats.raw_bytes;
  last_hb_report = stats.valid_heartbeat;

#if defined(LED_BUILTIN)
  if (stats.valid_heartbeat > 0) {
    led_on = !led_on;
    digitalWrite(LED_BUILTIN, led_on ? HIGH : LOW);
  }
#endif
}

void setup() {
  Serial.begin(USB_BAUD);
  delay(1000);

#if defined(LED_BUILTIN)
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);
#endif

  Serial.println();
  Serial.println("=== VC LoRa Pixhawk TELEM auto-scan sniff ===");
  Serial.println("No E220 / no Mission Planner / no UI / no MAVProxy.");
  Serial.println("USB Serial Monitor: 115200 baud.");
  Serial.println("Expected wiring: D7 <- Pixhawk TX, D6 -> Pixhawk RX, GND common.");
  Serial.println("Expected result: raw > 0, syncFE or syncFD > 0, hb > 0.");

  perform_scan();
}

void loop() {
  while (PixhawkSerial.available() > 0) {
    handle_byte(static_cast<uint8_t>(PixhawkSerial.read()));
  }

  const uint32_t now_ms = millis();
  if (now_ms - last_report_ms >= REPORT_MS) {
    last_report_ms = now_ms;
    print_report();
  }
}
