/*
  Read-only E220 inventory probe for Seeed Studio XIAO ESP32-S3.

  This diagnostic sends only the two documented register-read requests below.
  It has no register-write command, configuration mutation, transparent-mode
  forwarding, or persistent storage path. Output is one JSON object per line.
*/

#include <Arduino.h>
#include <esp_system.h>

#ifndef VC_LORA_E220_INVENTORY_ROLE
#error "VC_LORA_E220_INVENTORY_ROLE must be 1 (ground) or 2 (vehicle)"
#endif

#if VC_LORA_E220_INVENTORY_ROLE == 1
static constexpr char INVENTORY_ROLE[] = "ground";
#elif VC_LORA_E220_INVENTORY_ROLE == 2
static constexpr char INVENTORY_ROLE[] = "vehicle";
#else
#error "VC_LORA_E220_INVENTORY_ROLE must be 1 (ground) or 2 (vehicle)"
#endif

static constexpr uint32_t USB_BAUD = 115200U;
static constexpr uint32_t E220_CONFIG_BAUD = 9600U;
static constexpr uint32_t READY_INTERVAL_MS = 250U;
static constexpr uint32_t MODE_SETTLE_MS = 120U;
static constexpr uint32_t MODE_POST_AUX_SETTLE_MS = 2U;
static constexpr uint32_t AUX_TIMEOUT_MS = 1200U;
static constexpr uint32_t RX_DRAIN_MS = 30U;
// Three 8N1 bytes at 9600 bit/s require 3.125 ms. This fixed, bounded delay
// replaces HardwareSerial::flush(), whose implementation has no deadline.
static constexpr uint32_t UART_SHIFT_DRAIN_MS = 6U;
static constexpr uint32_t RESPONSE_TIMEOUT_MS = 500U;
static constexpr size_t RESPONSE_CAPACITY = 32U;
static constexpr size_t RUN_NONCE_HEX_LENGTH = 32U;
static constexpr size_t COMMAND_CAPACITY = 40U;

// Use XIAO D-pin names so the wiring contract is visible and board-correct.
static constexpr int E220_M0_PIN = D0;
static constexpr int E220_M1_PIN = D1;
static constexpr int E220_TX_PIN = D2;   // XIAO TX -> E220 RXD
static constexpr int E220_RX_PIN = D3;   // XIAO RX <- E220 TXD
static constexpr int E220_AUX_PIN = D8;

static constexpr uint8_t READ_CONFIGURATION[3] = {0xC1, 0x00, 0x08};
static constexpr uint8_t READ_PRODUCT_INFORMATION[3] = {0xC1, 0x08, 0x01};

HardwareSerial E220Serial(1);

struct ProbeResult {
  uint8_t response[RESPONSE_CAPACITY];
  size_t response_length;
  bool request_accepted;
  bool response_valid;
  bool aux_before_high;
  bool aux_after_high;
};

static uint32_t boot_nonce = 0U;
static char inventory_nonce[RUN_NONCE_HEX_LENGTH + 1U] = {};
static bool normal_mode_restored = false;
static bool run_started = false;
static bool run_completed = false;
static uint32_t last_ready_ms = 0U;
static char command_buffer[COMMAND_CAPACITY] = {};
static size_t command_length = 0U;
static bool command_overflow = false;

static void print_hex(const uint8_t *bytes, size_t length) {
  static constexpr char HEX_DIGITS[] = "0123456789ABCDEF";
  for (size_t i = 0; i < length; ++i) {
    Serial.print(HEX_DIGITS[(bytes[i] >> 4) & 0x0F]);
    Serial.print(HEX_DIGITS[bytes[i] & 0x0F]);
  }
}

static void print_json_prefix(const char *event) {
  Serial.print("{\"schema\":\"e220_inventory_v1\",\"role\":\"");
  Serial.print(INVENTORY_ROLE);
  Serial.print("\",\"boot_nonce\":");
  Serial.print(static_cast<unsigned long>(boot_nonce));
  Serial.print(",\"nonce\":\"");
  Serial.print(inventory_nonce);
  Serial.print("\",\"event\":\"");
  Serial.print(event);
  Serial.print('"');
}

static void emit_ready() {
  Serial.print("{\"schema\":\"e220_inventory_v1\",\"role\":\"");
  Serial.print(INVENTORY_ROLE);
  Serial.print("\",\"boot_nonce\":");
  Serial.print(static_cast<unsigned long>(boot_nonce));
  Serial.println(",\"nonce\":null,\"event\":\"ready\","
                 "\"protocol\":\"RUN_32_HEX\",\"e220_mode\":\"normal\"}");
}

static void emit_ack() {
  print_json_prefix("ack");
  Serial.println('}');
}

static bool is_hex_digit(char value) {
  return (value >= '0' && value <= '9') ||
         (value >= 'a' && value <= 'f') ||
         (value >= 'A' && value <= 'F');
}

static bool parse_run_command(const char *line, char *nonce,
                              size_t nonce_capacity) {
  if (line == nullptr || nonce == nullptr ||
      nonce_capacity != RUN_NONCE_HEX_LENGTH + 1U ||
      strlen(line) != 4U + RUN_NONCE_HEX_LENGTH ||
      strncmp(line, "RUN ", 4U) != 0) {
    return false;
  }
  for (size_t i = 0U; i < RUN_NONCE_HEX_LENGTH; ++i) {
    if (!is_hex_digit(line[4U + i])) {
      return false;
    }
  }
  memcpy(nonce, &line[4], RUN_NONCE_HEX_LENGTH);
  nonce[RUN_NONCE_HEX_LENGTH] = '\0';
  return true;
}

static bool wait_aux_high(uint32_t timeout_ms) {
  const uint32_t start_ms = millis();
  while (digitalRead(E220_AUX_PIN) == LOW) {
    if (millis() - start_ms >= timeout_ms) {
      return false;
    }
    delay(1);
  }
  return true;
}

static void drain_response(uint32_t timeout_ms) {
  const uint32_t start_ms = millis();
  while (millis() - start_ms < timeout_ms) {
    while (E220Serial.available() > 0) {
      (void)E220Serial.read();
    }
    delay(1);
  }
}

static size_t collect_response(uint8_t *response, size_t capacity,
                               uint32_t timeout_ms) {
  size_t length = 0U;
  const uint32_t start_ms = millis();
  while (millis() - start_ms < timeout_ms) {
    while (E220Serial.available() > 0) {
      const int value = E220Serial.read();
      if (value >= 0 && length < capacity) {
        response[length++] = static_cast<uint8_t>(value);
      }
    }
    delay(1);
  }
  return length;
}

static bool is_supported_read_command(const uint8_t (&command)[3]) {
  return command[0] == 0xC1 &&
         ((command[1] == 0x00 && command[2] == 0x08) ||
          (command[1] == 0x08 && command[2] == 0x01));
}

static bool send_read_command(const uint8_t (&command)[3],
                              ProbeResult *result) {
  if (result == nullptr || command[0] != 0xC1 ||
      !is_supported_read_command(command)) {
    return false;
  }

  result->aux_before_high = wait_aux_high(AUX_TIMEOUT_MS);
  if (!result->aux_before_high) {
    return false;
  }

  drain_response(RX_DRAIN_MS);
  const size_t written = E220Serial.write(command, sizeof(command));
  result->request_accepted = written == sizeof(command);
  if (!result->request_accepted) {
    return false;
  }

  // HardwareSerial::write may return once bytes are queued. Allow the exact
  // three-byte request to leave the shifter without an unbounded flush().
  delay(UART_SHIFT_DRAIN_MS);
  result->aux_after_high = wait_aux_high(AUX_TIMEOUT_MS);
  result->response_length = collect_response(
      result->response, sizeof(result->response), RESPONSE_TIMEOUT_MS);
  return true;
}

static ProbeResult probe_registers(const uint8_t (&command)[3]) {
  ProbeResult result = {};
  (void)send_read_command(command, &result);

  const size_t expected_length = static_cast<size_t>(command[2]) + 3U;
  result.response_valid = result.request_accepted && result.aux_after_high &&
                          result.response_length == expected_length &&
                          result.response[0] == 0xC1 &&
                          result.response[1] == command[1] &&
                          result.response[2] == command[2];
  return result;
}

static uint32_t decode_uart_bps(uint8_t reg0) {
  static constexpr uint32_t VALUES[8] = {
      1200U, 2400U, 4800U, 9600U, 19200U, 38400U, 57600U, 115200U};
  return VALUES[(reg0 >> 5) & 0x07];
}

static const char *decode_uart_format(uint8_t reg0) {
  static constexpr const char *VALUES[4] = {"8N1", "8O1", "8E1", "8N1"};
  return VALUES[(reg0 >> 3) & 0x03];
}

static uint32_t decode_air_bps(uint8_t reg0) {
  static constexpr uint32_t VALUES[8] = {
      2400U, 2400U, 2400U, 4800U, 9600U, 19200U, 38400U, 62500U};
  return VALUES[reg0 & 0x07];
}

static uint16_t decode_subpacket_bytes(uint8_t reg1) {
  static constexpr uint16_t VALUES[4] = {200U, 128U, 64U, 32U};
  return VALUES[(reg1 >> 6) & 0x03];
}

static void emit_common_probe_fields(const char *probe_name,
                                     const uint8_t (&command)[3],
                                     const ProbeResult &result) {
  Serial.print(",\"probe\":\"");
  Serial.print(probe_name);
  Serial.print("\",\"request_hex\":\"");
  print_hex(command, sizeof(command));
  Serial.print("\",\"raw_hex\":\"");
  print_hex(result.response, result.response_length);
  Serial.print("\",\"raw_length\":");
  Serial.print(static_cast<unsigned int>(result.response_length));
  Serial.print(",\"request_accepted\":");
  Serial.print(result.request_accepted ? "true" : "false");
  Serial.print(",\"aux_before_high\":");
  Serial.print(result.aux_before_high ? "true" : "false");
  Serial.print(",\"aux_after_high\":");
  Serial.print(result.aux_after_high ? "true" : "false");
  Serial.print(",\"valid\":");
  Serial.print(result.response_valid ? "true" : "false");
}

static void emit_configuration(const ProbeResult &result) {
  print_json_prefix("probe");
  emit_common_probe_fields("configuration", READ_CONFIGURATION, result);

  if (!result.response_valid) {
    Serial.println(",\"decode\":null}");
    return;
  }

  const uint8_t *registers = &result.response[3];
  const uint8_t reg0 = registers[2];
  const uint8_t reg1 = registers[3];
  const uint8_t reg3 = registers[5];
  const uint32_t frequency_khz =
      850125UL + static_cast<uint32_t>(registers[4]) * 1000UL;

  Serial.print(",\"decode\":{\"address\":");
  Serial.print((static_cast<uint16_t>(registers[0]) << 8) | registers[1]);
  Serial.print(",\"uart_bps\":");
  Serial.print(decode_uart_bps(reg0));
  Serial.print(",\"uart_format\":\"");
  Serial.print(decode_uart_format(reg0));
  Serial.print("\",\"air_bps\":");
  Serial.print(decode_air_bps(reg0));
  Serial.print(",\"subpacket_bytes\":");
  Serial.print(decode_subpacket_bytes(reg1));
  Serial.print(",\"ambient_noise_rssi_enabled\":");
  Serial.print((reg1 & 0x20) != 0 ? "true" : "false");
  Serial.print(",\"tx_power_code\":");
  Serial.print(reg1 & 0x03);
  // The same two-bit code represents different dBm values across E220 power
  // families. Preserve the code and avoid inventing a model before PID review.
  Serial.print(",\"tx_power_dbm\":null");
  Serial.print(",\"channel\":");
  Serial.print(registers[4]);
  Serial.print(",\"frequency_khz\":");
  Serial.print(frequency_khz);
  Serial.print(",\"rssi_append_enabled\":");
  Serial.print((reg3 & 0x80) != 0 ? "true" : "false");
  Serial.print(",\"fixed_transmission_enabled\":");
  Serial.print((reg3 & 0x40) != 0 ? "true" : "false");
  Serial.print(",\"lbt_enabled\":");
  Serial.print((reg3 & 0x10) != 0 ? "true" : "false");
  Serial.print(",\"wor_cycle_code\":");
  Serial.print(reg3 & 0x07);
  // CRYPT_H/L are write-only. Their documented readback is zero and must not
  // be represented as the configured key.
  Serial.print(",\"crypt_readable\":false");
  Serial.print(",\"crypt_hex\":null");
  Serial.println("}}");
}

static void emit_product_information(const ProbeResult &result) {
  print_json_prefix("probe");
  emit_common_probe_fields(
      "product_information", READ_PRODUCT_INFORMATION, result);
  Serial.print(",\"product_information_hex\":");
  if (result.response_valid) {
    Serial.print('"');
    print_hex(&result.response[3], 1U);
    Serial.print('"');
  } else {
    Serial.print("null");
  }
  // Register 08H is a version byte. The official manual publishes no mapping
  // from that byte to the T22S/T30D power family, so the physical label/BOM is
  // still authoritative.
  Serial.print(",\"model\":null");
  Serial.println(",\"model_identification\":\"physical_label_required\"}");
}

static bool set_configuration_mode() {
  if (!wait_aux_high(AUX_TIMEOUT_MS)) {
    return false;
  }
  digitalWrite(E220_M0_PIN, HIGH);
  digitalWrite(E220_M1_PIN, HIGH);
  delay(MODE_SETTLE_MS);
  if (!wait_aux_high(AUX_TIMEOUT_MS)) {
    return false;
  }
  delay(MODE_POST_AUX_SETTLE_MS);
  return digitalRead(E220_AUX_PIN) == HIGH;
}

static void set_normal_mode() {
  digitalWrite(E220_M0_PIN, LOW);
  digitalWrite(E220_M1_PIN, LOW);
  delay(MODE_SETTLE_MS);
  if (!wait_aux_high(AUX_TIMEOUT_MS)) {
    normal_mode_restored = false;
    return;
  }
  // The E220 manual requires at least 2 ms after AUX rises for a mode change.
  delay(MODE_POST_AUX_SETTLE_MS);
  normal_mode_restored = digitalRead(E220_AUX_PIN) == HIGH;
}

static void emit_completion(bool configuration_mode_ready) {
  print_json_prefix("complete");
  Serial.print(",\"configuration_mode_ready\":");
  Serial.print(configuration_mode_ready ? "true" : "false");
  Serial.print(",\"normal_mode_restored\":");
  Serial.print(normal_mode_restored ? "true" : "false");
  Serial.println('}');
}

static void run_inventory() {
  emit_ack();
  ProbeResult configuration = {};
  ProbeResult product_information = {};
  const bool configuration_mode_ready = set_configuration_mode();
  if (configuration_mode_ready) {
    configuration = probe_registers(READ_CONFIGURATION);
    product_information = probe_registers(READ_PRODUCT_INFORMATION);
  }
  emit_configuration(configuration);
  emit_product_information(product_information);

  set_normal_mode();
  emit_completion(configuration_mode_ready);
  run_completed = true;
}

void setup() {
  pinMode(E220_M0_PIN, OUTPUT);
  pinMode(E220_M1_PIN, OUTPUT);
  pinMode(E220_AUX_PIN, INPUT);
  digitalWrite(E220_M0_PIN, LOW);
  digitalWrite(E220_M1_PIN, LOW);

  Serial.begin(USB_BAUD);
  E220Serial.begin(E220_CONFIG_BAUD, SERIAL_8N1, E220_RX_PIN, E220_TX_PIN);
  boot_nonce = esp_random();
  emit_ready();
  last_ready_ms = millis();
}

void loop() {
  if (!run_started) {
    if (millis() - last_ready_ms >= READY_INTERVAL_MS) {
      emit_ready();
      last_ready_ms = millis();
    }

    while (Serial.available() > 0 && !run_started) {
      const int input = Serial.read();
      if (input < 0) {
        break;
      }
      const char value = static_cast<char>(input);
      if (value == '\r') {
        continue;
      }
      if (value == '\n') {
        if (!command_overflow &&
            parse_run_command(command_buffer, inventory_nonce,
                              sizeof(inventory_nonce))) {
          run_started = true;
          run_inventory();
        }
        command_length = 0U;
        command_buffer[0] = '\0';
        command_overflow = false;
        continue;
      }
      if (!command_overflow && command_length + 1U < COMMAND_CAPACITY) {
        command_buffer[command_length++] = value;
        command_buffer[command_length] = '\0';
      } else {
        command_overflow = true;
      }
    }
  }

  if (run_completed) {
    delay(10U);
  } else {
    delay(1U);
  }
}
