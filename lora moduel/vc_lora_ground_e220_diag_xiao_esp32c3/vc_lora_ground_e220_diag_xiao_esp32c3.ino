/*
  VC_LoRa ground-side E220 diagnostic sketch
  Board: Seeed Studio XIAO ESP32-S3 or XIAO ESP32-C3

  Purpose:
    - Check the ground XIAO USB CDC.
    - Check XIAO D2/D3 UART wiring.
    - Check whether the local E220 answers in configuration mode.

  This sketch is text debug over USB. Do not use it with Mission Planner or
  Route Monitor as a MAVLink source.
*/

#include <Arduino.h>

static constexpr uint32_t USB_BAUD = 115200;
static constexpr uint32_t DEFAULT_E220_BAUD = 9600;

// Use XIAO D-pin constants, not raw GPIO numbers. XIAO ESP32-S3 and C3 map
// the same D numbers to different GPIO numbers.
static constexpr int E220_M0_PIN = D0;   // XIAO D0 -> E220 M0
static constexpr int E220_M1_PIN = D1;   // XIAO D1 -> E220 M1
static constexpr int E220_TX_PIN = D2;   // XIAO D2 -> E220 RXD
static constexpr int E220_RX_PIN = D3;   // XIAO D3 <- E220 TXD
static constexpr int E220_AUX_PIN = D8;  // XIAO D8 <- E220 AUX

static constexpr uint8_t MAV_SYS_ID = 42;
static constexpr uint8_t MAV_COMP_ID = 191;
static constexpr uint8_t MAV_MSG_ID_HEARTBEAT = 0;
static constexpr uint8_t MAV_CRC_HEARTBEAT = 50;

HardwareSerial E220Serial(1);

static uint32_t e220_baud = DEFAULT_E220_BAUD;
static uint32_t rx_bytes = 0;
static uint32_t tx_bytes = 0;
static uint32_t last_status_ms = 0;
static uint8_t mav_seq = 0;

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

static void print_hex(const uint8_t *data, size_t length) {
  for (size_t i = 0; i < length; ++i) {
    if (data[i] < 0x10) {
      Serial.print('0');
    }
    Serial.print(data[i], HEX);
    if (i + 1 < length) {
      Serial.print(' ');
    }
  }
}

static bool wait_aux_high(uint32_t timeout_ms) {
  const uint32_t start = millis();
  while (digitalRead(E220_AUX_PIN) == LOW) {
    if (millis() - start >= timeout_ms) {
      return false;
    }
    delay(1);
  }
  return true;
}

static void set_e220_mode(bool m0_high, bool m1_high, const char *name) {
  digitalWrite(E220_M0_PIN, m0_high ? HIGH : LOW);
  digitalWrite(E220_M1_PIN, m1_high ? HIGH : LOW);
  delay(120);
  const bool aux_ok = wait_aux_high(1000);

  Serial.print("[MODE] ");
  Serial.print(name);
  Serial.print(" M0=");
  Serial.print(m0_high ? "HIGH" : "LOW");
  Serial.print(" M1=");
  Serial.print(m1_high ? "HIGH" : "LOW");
  Serial.print(" AUX=");
  Serial.println(aux_ok ? "HIGH" : "LOW/TIMEOUT");
}

static void set_normal_mode() {
  set_e220_mode(false, false, "normal transparent");
}

static void set_config_mode() {
  set_e220_mode(true, true, "configuration");
}

static void begin_e220(uint32_t baud) {
  e220_baud = baud;
  E220Serial.end();
  delay(20);
  E220Serial.setRxBufferSize(2048);
  E220Serial.begin(e220_baud, SERIAL_8N1, E220_RX_PIN, E220_TX_PIN);
  E220Serial.setTimeout(20);
  Serial.print("[UART] E220 UART begin ");
  Serial.println(e220_baud);
}

static void flush_e220_rx(uint32_t timeout_ms = 50) {
  const uint32_t start = millis();
  while (millis() - start < timeout_ms) {
    while (E220Serial.available() > 0) {
      E220Serial.read();
    }
    delay(1);
  }
}

static size_t collect_e220_response(uint8_t *buffer, size_t capacity, uint32_t timeout_ms) {
  size_t length = 0;
  const uint32_t start = millis();
  while (millis() - start < timeout_ms) {
    while (E220Serial.available() > 0 && length < capacity) {
      buffer[length++] = static_cast<uint8_t>(E220Serial.read());
    }
    delay(1);
  }
  rx_bytes += static_cast<uint32_t>(length);
  return length;
}

static void send_raw_to_e220(const uint8_t *data, size_t length) {
  wait_aux_high(1000);
  const size_t written = E220Serial.write(data, length);
  E220Serial.flush();
  tx_bytes += static_cast<uint32_t>(written);
}

static void print_probe_response(const char *label, const uint8_t *command, size_t command_len) {
  uint8_t response[96] = {};
  flush_e220_rx();

  Serial.print("[PROBE] ");
  Serial.print(label);
  Serial.print(" tx=");
  print_hex(command, command_len);
  Serial.println();

  send_raw_to_e220(command, command_len);
  const size_t length = collect_e220_response(response, sizeof(response), 350);

  Serial.print("[PROBE] ");
  Serial.print(label);
  Serial.print(" rx_len=");
  Serial.print(length);
  Serial.print(" rx=");
  if (length > 0) {
    print_hex(response, length);
  } else {
    Serial.print("--");
  }
  Serial.println();
}

static bool e220_baud_bits(uint32_t baud, uint8_t *bits) {
  switch (baud) {
    case 1200: *bits = 0; return true;
    case 2400: *bits = 1; return true;
    case 4800: *bits = 2; return true;
    case 9600: *bits = 3; return true;
    case 19200: *bits = 4; return true;
    case 38400: *bits = 5; return true;
    case 57600: *bits = 6; return true;
    case 115200: *bits = 7; return true;
    default: return false;
  }
}

static bool read_e220_registers(uint8_t start, uint8_t count, uint8_t *out, size_t out_capacity) {
  if (count == 0 || count > out_capacity) {
    return false;
  }

  const uint8_t command[] = {0xC1, start, count};
  uint8_t response[96] = {};
  flush_e220_rx();
  send_raw_to_e220(command, sizeof(command));
  const size_t length = collect_e220_response(response, sizeof(response), 350);

  Serial.print("[READ] start=0x");
  if (start < 0x10) Serial.print('0');
  Serial.print(start, HEX);
  Serial.print(" len=");
  Serial.print(count);
  Serial.print(" rx_len=");
  Serial.print(length);
  Serial.print(" rx=");
  if (length > 0) {
    print_hex(response, length);
  } else {
    Serial.print("--");
  }
  Serial.println();

  if (length < static_cast<size_t>(count + 3) ||
      response[0] != 0xC1 ||
      response[1] != start ||
      response[2] != count) {
    return false;
  }

  memcpy(out, &response[3], count);
  return true;
}

static bool write_e220_registers(uint8_t start, const uint8_t *data, uint8_t count, bool permanent) {
  uint8_t command[32] = {};
  if (count == 0 || static_cast<size_t>(count + 3) > sizeof(command)) {
    return false;
  }

  command[0] = permanent ? 0xC0 : 0xC2;
  command[1] = start;
  command[2] = count;
  memcpy(&command[3], data, count);

  uint8_t response[96] = {};
  flush_e220_rx();
  send_raw_to_e220(command, static_cast<size_t>(count + 3));
  const size_t length = collect_e220_response(response, sizeof(response), 500);

  Serial.print("[WRITE] ");
  Serial.print(permanent ? "permanent" : "temporary");
  Serial.print(" tx=");
  print_hex(command, static_cast<size_t>(count + 3));
  Serial.print(" rx_len=");
  Serial.print(length);
  Serial.print(" rx=");
  if (length > 0) {
    print_hex(response, length);
  } else {
    Serial.print("--");
  }
  Serial.println();

  return length >= static_cast<size_t>(count + 3) &&
         response[0] == 0xC1 &&
         response[1] == start &&
         response[2] == count;
}

static void set_e220_transparent_uart_baud(uint32_t target_baud) {
  uint8_t baud_bits = 0;
  if (!e220_baud_bits(target_baud, &baud_bits)) {
    Serial.println("[BAUD] unsupported target baud");
    return;
  }

  // E220 configuration commands are handled at 9600 8N1 in configuration mode.
  if (e220_baud != DEFAULT_E220_BAUD) {
    begin_e220(DEFAULT_E220_BAUD);
  }
  set_config_mode();

  uint8_t registers[8] = {};
  if (!read_e220_registers(0x00, sizeof(registers), registers, sizeof(registers))) {
    Serial.println("[BAUD] abort: failed to read current registers at config baud 9600");
    return;
  }

  const uint8_t old_reg0 = registers[2];
  const uint8_t new_reg0 = static_cast<uint8_t>((old_reg0 & 0x1F) | (baud_bits << 5));

  Serial.print("[BAUD] REG0 old=0x");
  if (old_reg0 < 0x10) Serial.print('0');
  Serial.print(old_reg0, HEX);
  Serial.print(" new=0x");
  if (new_reg0 < 0x10) Serial.print('0');
  Serial.print(new_reg0, HEX);
  Serial.print(" target=");
  Serial.println(target_baud);

  if (old_reg0 == new_reg0) {
    Serial.println("[BAUD] no change needed");
    set_normal_mode();
    return;
  }

  if (!write_e220_registers(0x02, &new_reg0, 1, true)) {
    Serial.println("[BAUD] write response was not confirmed");
  }

  delay(200);
  uint8_t verify[8] = {};
  if (read_e220_registers(0x00, sizeof(verify), verify, sizeof(verify))) {
    Serial.print("[BAUD] verify REG0=0x");
    if (verify[2] < 0x10) Serial.print('0');
    Serial.println(verify[2], HEX);
  } else {
    Serial.println("[BAUD] verify read failed");
  }

  set_normal_mode();
}

static void probe_e220_config_at_current_baud() {
  set_config_mode();
  Serial.print("[PROBE] baud ");
  Serial.println(e220_baud);

  const uint8_t read_registers_8[] = {0xC1, 0x00, 0x08};
  const uint8_t read_registers_9[] = {0xC1, 0x00, 0x09};
  const uint8_t legacy_read[] = {0xC1, 0xC1, 0xC1};
  const uint8_t legacy_version[] = {0xC3, 0xC3, 0xC3};

  print_probe_response("C1 00 08", read_registers_8, sizeof(read_registers_8));
  print_probe_response("C1 00 09", read_registers_9, sizeof(read_registers_9));
  print_probe_response("C1 C1 C1", legacy_read, sizeof(legacy_read));
  print_probe_response("C3 C3 C3", legacy_version, sizeof(legacy_version));
}

static void scan_e220_baud() {
  static const uint32_t candidates[] = {9600, 19200, 38400, 57600, 115200};
  set_config_mode();
  for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i) {
    begin_e220(candidates[i]);
    probe_e220_config_at_current_baud();
  }
  begin_e220(DEFAULT_E220_BAUD);
  set_normal_mode();
}

static void use_transparent_uart_baud(uint32_t baud) {
  begin_e220(baud);
  set_normal_mode();
  Serial.print("[UART] transparent live monitor at ");
  Serial.println(baud);
}

static void send_test_heartbeat_to_e220() {
  uint8_t payload[9] = {};
  payload[4] = 18;
  payload[5] = 8;
  payload[7] = 4;
  payload[8] = 3;

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

  set_normal_mode();
  send_raw_to_e220(packet, sizeof(packet));
  Serial.print("[TX] MAVLink heartbeat to E220 ");
  Serial.print(sizeof(packet));
  Serial.println(" bytes");
}

static void send_loopback_pattern() {
  const uint8_t pattern[] = {
    0x55, 0xAA, 0x12, 0x34, 0xFE, 0x09, 0x00, 0x2A,
    0xBF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x08
  };
  flush_e220_rx();
  send_raw_to_e220(pattern, sizeof(pattern));

  uint8_t response[64] = {};
  const size_t length = collect_e220_response(response, sizeof(response), 300);
  Serial.print("[LOOPBACK] D2->D3 physical short expected. rx_len=");
  Serial.print(length);
  Serial.print(" rx=");
  if (length > 0) {
    print_hex(response, length);
  } else {
    Serial.print("--");
  }
  Serial.println();
}

static void print_menu() {
  Serial.println();
  Serial.println("=== VC_LoRa Ground E220 Diagnostic ===");
  Serial.println("USB baud: 115200");
  Serial.println("E220 UART: RX D3 / TX D2");
  Serial.println("Commands:");
  Serial.println("  s : status");
  Serial.println("  n : E220 normal mode M0=LOW M1=LOW");
  Serial.println("  c : E220 config mode M0=HIGH M1=HIGH");
  Serial.println("  r : read/probe E220 config at current baud");
  Serial.println("  b : scan E220 config baud 9600..115200");
  Serial.println("  5 : set transparent UART baud to 57600 permanently");
  Serial.println("  9 : set transparent UART baud to 9600 permanently");
  Serial.println("  v : use 57600 UART and print live E220 RX bytes");
  Serial.println("  p : use 9600 UART and print live E220 RX bytes");
  Serial.println("  h : send MAVLink heartbeat to E220");
  Serial.println("  l : D2/D3 physical loopback test");
  Serial.println("  ? : menu");
  Serial.println();
}

static void print_status() {
  Serial.print("[STATUS] baud=");
  Serial.print(e220_baud);
  Serial.print(" AUX=");
  Serial.print(digitalRead(E220_AUX_PIN) == HIGH ? "HIGH" : "LOW");
  Serial.print(" M0=");
  Serial.print(digitalRead(E220_M0_PIN) == HIGH ? "HIGH" : "LOW");
  Serial.print(" M1=");
  Serial.print(digitalRead(E220_M1_PIN) == HIGH ? "HIGH" : "LOW");
  Serial.print(" tx_bytes=");
  Serial.print(tx_bytes);
  Serial.print(" rx_bytes=");
  Serial.println(rx_bytes);
}

static void drain_live_e220_rx() {
  uint8_t buffer[96] = {};
  size_t length = 0;
  while (E220Serial.available() > 0 && length < sizeof(buffer)) {
    buffer[length++] = static_cast<uint8_t>(E220Serial.read());
  }
  if (length == 0) {
    return;
  }
  rx_bytes += static_cast<uint32_t>(length);
  Serial.print("[RX] ");
  Serial.print(length);
  Serial.print(" bytes ");
  print_hex(buffer, length);
  Serial.println();
}

void setup() {
  pinMode(E220_M0_PIN, OUTPUT);
  pinMode(E220_M1_PIN, OUTPUT);
  pinMode(E220_AUX_PIN, INPUT);

  Serial.begin(USB_BAUD);
  Serial.setTimeout(20);
  delay(800);

  begin_e220(DEFAULT_E220_BAUD);
  set_normal_mode();
  print_menu();
  print_status();
}

void loop() {
  drain_live_e220_rx();

  while (Serial.available() > 0) {
    const char command = static_cast<char>(Serial.read());
    switch (command) {
      case 's':
      case 'S':
        print_status();
        break;
      case 'n':
      case 'N':
        set_normal_mode();
        break;
      case 'c':
      case 'C':
        set_config_mode();
        break;
      case 'r':
      case 'R':
        probe_e220_config_at_current_baud();
        break;
      case 'b':
      case 'B':
        scan_e220_baud();
        break;
      case '5':
        set_e220_transparent_uart_baud(57600);
        break;
      case '9':
        set_e220_transparent_uart_baud(9600);
        break;
      case 'v':
      case 'V':
        use_transparent_uart_baud(57600);
        break;
      case 'p':
      case 'P':
        use_transparent_uart_baud(9600);
        break;
      case 'h':
      case 'H':
        send_test_heartbeat_to_e220();
        break;
      case 'l':
      case 'L':
        send_loopback_pattern();
        break;
      case '?':
        print_menu();
        break;
      case '\r':
      case '\n':
      case ' ':
        break;
      default:
        Serial.print("[WARN] unknown command: ");
        Serial.println(command);
        break;
    }
  }

  const uint32_t now = millis();
  if (now - last_status_ms >= 2000) {
    last_status_ms = now;
    print_status();
  }
}
