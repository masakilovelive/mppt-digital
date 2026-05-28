/*
  Base station XIAO ESP32-C3: ESP-NOW INA780/VESC receiver -> USB Serial MAVLink bridge.

  Monitor-only telemetry. Pixhawk/RC 2.4 GHz communication remains highest
  priority. Keep telemetry rate low and log RSSI/loss for outdoor tests.
*/

#include <Arduino.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <esp_err.h>

#if __has_include(<esp_arduino_version.h>)
#include <esp_arduino_version.h>
#endif

static constexpr uint32_t SERIAL_BAUD = 115200;
static constexpr uint8_t ESPNOW_CHANNEL = 1;
static constexpr uint8_t MAV_SYS_ID = 42;
static constexpr uint8_t MAV_COMP_ID = 191;

static constexpr uint8_t MAV_MSG_ID_HEARTBEAT = 0;
static constexpr uint8_t MAV_MSG_ID_NAMED_VALUE_FLOAT = 251;
static constexpr uint8_t MAV_MSG_ID_STATUSTEXT = 253;
static constexpr uint8_t MAV_CRC_EXTRA_HEARTBEAT = 50;
static constexpr uint8_t MAV_CRC_EXTRA_NAMED_VALUE_FLOAT = 170;
static constexpr uint8_t MAV_CRC_EXTRA_STATUSTEXT = 83;

static constexpr uint16_t FLAG_INA780_REQUIRED_MISSING = 0x0001;
static constexpr uint16_t FLAG_VESC_STATUS_STALE = 0x0002;
static constexpr uint16_t FLAG_TWAI_INIT_FAIL = 0x0004;
static constexpr uint8_t VESC_MASK_STATUS = 0x01;
static constexpr uint8_t VESC_MASK_STATUS_4 = 0x02;
static constexpr uint8_t VESC_MASK_STATUS_5 = 0x04;
static constexpr uint8_t INA780_DEVICE_COUNT = 5;
static constexpr const char *INA780_PREFIXES[INA780_DEVICE_COUNT] = {"BATT", "AUX", "ESC", "PV1", "PV2"};

struct __attribute__((packed)) BoatTelemetryPacket {
  uint32_t magic;
  uint8_t version;
  uint8_t source_id;
  uint16_t flags;
  uint32_t seq;
  uint32_t tx_ms;
  uint8_t ina_valid_mask;
  uint8_t ina_reserved[3];
  float ina_current_a[INA780_DEVICE_COUNT];
  float ina_bus_v[INA780_DEVICE_COUNT];
  float ina_temp_c[INA780_DEVICE_COUNT];
  float ina_power_w[INA780_DEVICE_COUNT];
  uint8_t vesc_id;
  uint8_t vesc_status_mask;
  uint16_t reserved;
  uint32_t vesc_age_ms;
  float vesc_rpm;
  float vesc_motor_current_a;
  float vesc_duty;
  float vesc_input_current_a;
  float vesc_voltage_v;
  float vesc_power_w;
  float vesc_temp_fet_c;
  float vesc_temp_motor_c;
};

static constexpr uint32_t PACKET_MAGIC = 0x49373830; // "I780" little-endian marker.
static uint8_t mav_seq = 0;
static uint32_t last_heartbeat_ms = 0;
static uint32_t last_status_ms = 0;
static uint32_t last_rx_ms = 0;
static uint32_t last_seq = 0;
static uint32_t rx_count = 0;
static uint32_t lost_count = 0;
static float last_dt_ms = 0.0f;
static int8_t last_rssi = 0;
static bool have_seq = false;
static bool have_rssi = false;

static portMUX_TYPE packet_mux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool packet_pending = false;
static BoatTelemetryPacket pending_packet = {};
static int8_t pending_rssi = 0;
static bool pending_has_rssi = false;

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

static void send_mavlink_v1(uint8_t msg_id, const uint8_t *payload, uint8_t payload_len, uint8_t crc_extra) {
  uint8_t header[6] = {0xFE, payload_len, mav_seq++, MAV_SYS_ID, MAV_COMP_ID, msg_id};
  uint8_t crc_input[5 + 255];
  memcpy(crc_input, &header[1], 5);
  if (payload_len > 0) {
    memcpy(&crc_input[5], payload, payload_len);
  }
  const uint16_t crc = mavlink_crc(crc_input, 5 + payload_len, crc_extra);
  Serial.write(header, sizeof(header));
  Serial.write(payload, payload_len);
  Serial.write(static_cast<uint8_t>(crc & 0xff));
  Serial.write(static_cast<uint8_t>(crc >> 8));
}

static void send_heartbeat() {
  uint8_t payload[9] = {};
  payload[4] = 6;  // MAV_TYPE_GCS.
  payload[5] = 8;  // MAV_AUTOPILOT_INVALID.
  payload[7] = 4;  // MAV_STATE_ACTIVE.
  payload[8] = 3;
  send_mavlink_v1(MAV_MSG_ID_HEARTBEAT, payload, sizeof(payload), MAV_CRC_EXTRA_HEARTBEAT);
}

static void send_named_value_float(const char *name, float value) {
  uint8_t payload[18] = {};
  const uint32_t now = millis();
  payload[0] = static_cast<uint8_t>(now & 0xff);
  payload[1] = static_cast<uint8_t>((now >> 8) & 0xff);
  payload[2] = static_cast<uint8_t>((now >> 16) & 0xff);
  payload[3] = static_cast<uint8_t>((now >> 24) & 0xff);
  memcpy(&payload[4], &value, sizeof(float));
  strncpy(reinterpret_cast<char *>(&payload[8]), name, 10);
  send_mavlink_v1(MAV_MSG_ID_NAMED_VALUE_FLOAT, payload, sizeof(payload), MAV_CRC_EXTRA_NAMED_VALUE_FLOAT);
}

static void send_statustext(uint8_t severity, const char *text) {
  uint8_t payload[51] = {};
  payload[0] = severity;
  strncpy(reinterpret_cast<char *>(&payload[1]), text, 50);
  send_mavlink_v1(MAV_MSG_ID_STATUSTEXT, payload, sizeof(payload), MAV_CRC_EXTRA_STATUSTEXT);
}

static void send_ina780_values(const char *prefix, float bus_v, float current_a, float power_w, float temp_c) {
  char name[11] = {};
  snprintf(name, sizeof(name), "%s_V", prefix);
  send_named_value_float(name, bus_v);
  snprintf(name, sizeof(name), "%s_I", prefix);
  send_named_value_float(name, current_a);
  snprintf(name, sizeof(name), "%s_P", prefix);
  send_named_value_float(name, power_w);
  snprintf(name, sizeof(name), "%s_T", prefix);
  send_named_value_float(name, temp_c);
}

static void handle_packet(const BoatTelemetryPacket &packet, int8_t rssi, bool has_rssi) {
  if (packet.magic != PACKET_MAGIC || packet.version != 3) {
    return;
  }

  const uint32_t now = millis();
  if (last_rx_ms != 0) {
    last_dt_ms = static_cast<float>(now - last_rx_ms);
  }
  last_rx_ms = now;

  if (have_seq) {
    const uint32_t expected = last_seq + 1;
    if (packet.seq > expected) {
      lost_count += packet.seq - expected;
    }
  }
  last_seq = packet.seq;
  have_seq = true;
  rx_count++;
  last_rssi = rssi;
  have_rssi = has_rssi;

  for (uint8_t i = 0; i < INA780_DEVICE_COUNT; i++) {
    if (packet.ina_valid_mask & static_cast<uint8_t>(1U << i)) {
      send_ina780_values(
        INA780_PREFIXES[i],
        packet.ina_bus_v[i],
        packet.ina_current_a[i],
        packet.ina_power_w[i],
        packet.ina_temp_c[i]);
    }
  }
  send_named_value_float("INA_MASK", static_cast<float>(packet.ina_valid_mask));

  const bool can_ok =
    (packet.flags & (FLAG_VESC_STATUS_STALE | FLAG_TWAI_INIT_FAIL)) == 0 &&
    packet.vesc_status_mask != 0;
  send_named_value_float("CAN_OK", can_ok ? 1.0f : 0.0f);
  send_named_value_float("CAN_ID", static_cast<float>(packet.vesc_id));
  send_named_value_float("CAN_AGE", packet.vesc_age_ms == 0xffffffffUL ? -1.0f : static_cast<float>(packet.vesc_age_ms));
  if (packet.vesc_status_mask & VESC_MASK_STATUS) {
    send_named_value_float("VESC_RPM", packet.vesc_rpm);
    send_named_value_float("VESC_IMOT", packet.vesc_motor_current_a);
    send_named_value_float("VESC_DUTY", packet.vesc_duty);
  }
  if (packet.vesc_status_mask & VESC_MASK_STATUS_4) {
    send_named_value_float("VESC_IIN", packet.vesc_input_current_a);
    send_named_value_float("VESC_TFET", packet.vesc_temp_fet_c);
    send_named_value_float("VESC_TMOT", packet.vesc_temp_motor_c);
  }
  if (packet.vesc_status_mask & VESC_MASK_STATUS_5) {
    send_named_value_float("VESC_VIN", packet.vesc_voltage_v);
  }
  if ((packet.vesc_status_mask & (VESC_MASK_STATUS_4 | VESC_MASK_STATUS_5)) ==
      (VESC_MASK_STATUS_4 | VESC_MASK_STATUS_5)) {
    send_named_value_float("VESC_PWR", packet.vesc_power_w);
  }
  send_named_value_float("RSSI", has_rssi ? static_cast<float>(rssi) : 0.0f);
  send_named_value_float("RX_DT", last_dt_ms);
  send_named_value_float("SEQ", static_cast<float>(packet.seq));
  send_named_value_float("LOSS", static_cast<float>(lost_count));
  send_named_value_float("FAULT", static_cast<float>(packet.flags));
}

static void store_packet_from_callback(const uint8_t *data, int len, int8_t rssi, bool has_rssi) {
  if (len != static_cast<int>(sizeof(BoatTelemetryPacket))) {
    return;
  }
  BoatTelemetryPacket packet = {};
  memcpy(&packet, data, sizeof(packet));
  portENTER_CRITICAL_ISR(&packet_mux);
  pending_packet = packet;
  pending_rssi = rssi;
  pending_has_rssi = has_rssi;
  packet_pending = true;
  portEXIT_CRITICAL_ISR(&packet_mux);
}

#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
static void on_espnow_recv(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  int8_t rssi = 0;
  bool has_rssi = false;
  if (info && info->rx_ctrl) {
    rssi = static_cast<int8_t>(info->rx_ctrl->rssi);
    has_rssi = true;
  }
  store_packet_from_callback(data, len, rssi, has_rssi);
}
#else
static void on_espnow_recv(const uint8_t *mac, const uint8_t *data, int len) {
  (void)mac;
  store_packet_from_callback(data, len, 0, false);
}
#endif

static void setup_espnow() {
  WiFi.mode(WIFI_STA);
  WiFi.disconnect(false, true);
  delay(100);
  esp_wifi_set_promiscuous(true);
  esp_wifi_set_channel(ESPNOW_CHANNEL, WIFI_SECOND_CHAN_NONE);
  esp_wifi_set_promiscuous(false);

  esp_err_t result = esp_now_init();
  if (result != ESP_OK) {
    Serial.print("ESP_NOW_INIT_FAIL err=");
    Serial.print(static_cast<int>(result));
    Serial.print(" ");
    Serial.println(esp_err_to_name(result));
    return;
  }
  esp_now_register_recv_cb(on_espnow_recv);
}

void setup() {
  Serial.begin(SERIAL_BAUD);
  delay(1000);
  WiFi.mode(WIFI_STA);
  Serial.println();
  Serial.println("BASE XIAO ESP32-C3 ESP-NOW to MAVLink bridge");
  Serial.print("STA MAC: ");
  Serial.println(WiFi.macAddress());
  Serial.print("ESP-NOW channel: ");
  Serial.println(ESPNOW_CHANNEL);
  setup_espnow();
  send_statustext(6, "base bridge boot");
}

void loop() {
  const uint32_t now = millis();
  if (now - last_heartbeat_ms >= 1000) {
    last_heartbeat_ms = now;
    send_heartbeat();
  }

  BoatTelemetryPacket packet = {};
  int8_t rssi = 0;
  bool has_rssi = false;
  bool take_packet = false;
  portENTER_CRITICAL(&packet_mux);
  if (packet_pending) {
    packet = pending_packet;
    rssi = pending_rssi;
    has_rssi = pending_has_rssi;
    packet_pending = false;
    take_packet = true;
  }
  portEXIT_CRITICAL(&packet_mux);

  if (take_packet) {
    handle_packet(packet, rssi, has_rssi);
  }

  if (now - last_status_ms >= 5000) {
    last_status_ms = now;
    char text[50];
    snprintf(text, sizeof(text), "rx=%lu loss=%lu rssi=%d", static_cast<unsigned long>(rx_count),
             static_cast<unsigned long>(lost_count), have_rssi ? last_rssi : 0);
    send_statustext(6, text);
  }
}
