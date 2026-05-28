/*
  Boat side ESP32-S3: INA780BIDEKR + VESC CAN -> ESP-NOW telemetry sender.

  Monitor-only telemetry. Do not use this packet path for propulsion, steering,
  arming, or any Pixhawk/RC control function.

  Wiring:
    INA780 VCC -> 3V3
    INA780 GND -> GND
    INA780 SDA -> I2C_SDA_PIN
    INA780 SCL -> I2C_SCL_PIN
    GPIO1 -> SN65HVD230 TXD / CTX
    GPIO2 <- SN65HVD230 RXD / CRX
*/

#include <Arduino.h>
#include <Wire.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <esp_err.h>
#include "driver/twai.h"

static constexpr uint8_t ESPNOW_CHANNEL = 1;
static constexpr uint32_t SEND_INTERVAL_MS = 200;  // 5 Hz, low load for 2.4 GHz coexistence.

static constexpr gpio_num_t CAN_TX_PIN = GPIO_NUM_1;
static constexpr gpio_num_t CAN_RX_PIN = GPIO_NUM_2;
static constexpr uint32_t CAN_BAUD = 500000;
static constexpr uint8_t TARGET_VESC_CAN_ID = 0x78;
static constexpr uint32_t VESC_STATUS_TIMEOUT_MS = 1500;

static constexpr uint8_t I2C_SDA_PIN = 8;   // Change for your ESP32-S3 board.
static constexpr uint8_t I2C_SCL_PIN = 9;   // Change for your ESP32-S3 board.
static constexpr uint8_t INA780_DEVICE_COUNT = 5;
static constexpr uint8_t INA780_ADDRS[INA780_DEVICE_COUNT] = {0x40, 0x43, 0x41, 0x44, 0x45};
static constexpr const char *INA780_NAMES[INA780_DEVICE_COUNT] = {"BATT", "AUX_BATT", "ESC", "PV1", "PV2"};
// Set bits after the final harness is fixed. Zero permits incremental wiring tests.
static constexpr uint8_t REQUIRED_INA780_MASK = 0x00;
static constexpr uint8_t REG_VBUS = 0x05;
static constexpr uint8_t REG_DIETEMP = 0x06;
static constexpr uint8_t REG_CURRENT = 0x07;
static constexpr uint8_t REG_POWER = 0x08;
static constexpr uint8_t REG_MANUFACTURER_ID = 0x3E;

static const uint8_t BASE_MAC[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff}; // Broadcast for first test.

static constexpr uint16_t FLAG_INA780_REQUIRED_MISSING = 0x0001;
static constexpr uint16_t FLAG_VESC_STATUS_STALE = 0x0002;
static constexpr uint16_t FLAG_TWAI_INIT_FAIL = 0x0004;

static constexpr uint8_t VESC_MASK_STATUS = 0x01;
static constexpr uint8_t VESC_MASK_STATUS_4 = 0x02;
static constexpr uint8_t VESC_MASK_STATUS_5 = 0x04;

enum VescCanPacket : uint8_t {
  CAN_PACKET_STATUS = 9,
  CAN_PACKET_STATUS_4 = 16,
  CAN_PACKET_STATUS_5 = 27,
};

struct VescStatusValues {
  uint8_t received_mask;
  uint32_t last_rx_ms;
  float rpm;
  float motor_current_a;
  float duty;
  float input_current_a;
  float voltage_v;
  float temp_fet_c;
  float temp_motor_c;
};

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
static uint32_t seq_no = 0;
static uint32_t last_send_ms = 0;
static bool twai_ready = false;
static VescStatusValues vesc_status = {};

static int16_t be_i16(const uint8_t *data) {
  return static_cast<int16_t>((static_cast<uint16_t>(data[0]) << 8) | data[1]);
}

static int32_t be_i32(const uint8_t *data) {
  return static_cast<int32_t>(
    (static_cast<uint32_t>(data[0]) << 24) |
    (static_cast<uint32_t>(data[1]) << 16) |
    (static_cast<uint32_t>(data[2]) << 8) |
    data[3]
  );
}

static bool read_i2c_u16(uint8_t address, uint8_t reg, uint16_t &value) {
  Wire.beginTransmission(address);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }
  if (Wire.requestFrom(static_cast<int>(address), 2) != 2) {
    return false;
  }
  value = (static_cast<uint16_t>(Wire.read()) << 8) | Wire.read();
  return true;
}

static bool read_i2c_u24(uint8_t address, uint8_t reg, uint32_t &value) {
  Wire.beginTransmission(address);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }
  if (Wire.requestFrom(static_cast<int>(address), 3) != 3) {
    return false;
  }
  value = (static_cast<uint32_t>(Wire.read()) << 16) |
          (static_cast<uint32_t>(Wire.read()) << 8) |
          Wire.read();
  return true;
}

static float decode_die_temp_c(uint16_t raw) {
  int16_t temp_raw = static_cast<int16_t>(raw >> 4);
  if (temp_raw & 0x0800) {
    temp_raw |= 0xf000;
  }
  return temp_raw * 0.125f;
}

static bool read_ina780b(uint8_t address, float &current_a, float &bus_v, float &temp_c, float &power_w) {
  uint16_t manufacturer_id = 0;
  uint16_t raw_current = 0;
  uint16_t raw_bus = 0;
  uint16_t raw_temp = 0;
  uint32_t raw_power = 0;
  if (!read_i2c_u16(address, REG_MANUFACTURER_ID, manufacturer_id) || manufacturer_id != 0x5449) {
    return false;
  }
  if (!read_i2c_u16(address, REG_CURRENT, raw_current) ||
      !read_i2c_u16(address, REG_VBUS, raw_bus) ||
      !read_i2c_u16(address, REG_DIETEMP, raw_temp) ||
      !read_i2c_u24(address, REG_POWER, raw_power)) {
    return false;
  }
  current_a = static_cast<int16_t>(raw_current) * 0.0024f;
  bus_v = raw_bus * 0.003125f;
  temp_c = decode_die_temp_c(raw_temp);
  power_w = raw_power * 0.000480f;
  return true;
}

static bool setup_twai() {
  twai_general_config_t general = TWAI_GENERAL_CONFIG_DEFAULT(CAN_TX_PIN, CAN_RX_PIN, TWAI_MODE_NORMAL);
  general.rx_queue_len = 32;
  general.tx_queue_len = 0;
  twai_timing_config_t timing = TWAI_TIMING_CONFIG_500KBITS();
  twai_filter_config_t filter = TWAI_FILTER_CONFIG_ACCEPT_ALL();
  esp_err_t result = twai_driver_install(&general, &timing, &filter);
  if (result != ESP_OK) {
    Serial.print("TWAI_INSTALL_FAIL err=");
    Serial.println(static_cast<int>(result));
    return false;
  }
  result = twai_start();
  if (result != ESP_OK) {
    Serial.print("TWAI_START_FAIL err=");
    Serial.println(static_cast<int>(result));
    twai_driver_uninstall();
    return false;
  }
  Serial.print("TWAI_READY TX=GPIO");
  Serial.print(static_cast<int>(CAN_TX_PIN));
  Serial.print(" RX=GPIO");
  Serial.print(static_cast<int>(CAN_RX_PIN));
  Serial.print(" baud=");
  Serial.print(CAN_BAUD);
  Serial.print(" VESC_ID=");
  Serial.println(TARGET_VESC_CAN_ID);
  return true;
}

static void receive_vesc_status(uint32_t now) {
  if (!twai_ready) {
    return;
  }

  twai_message_t message = {};
  uint8_t processed = 0;
  while (processed < 32 && twai_receive(&message, 0) == ESP_OK) {
    processed++;
    if (!message.extd) {
      continue;
    }
    const uint8_t command = static_cast<uint8_t>((message.identifier >> 8) & 0xff);
    const uint8_t controller_id = static_cast<uint8_t>(message.identifier & 0xff);
    if (controller_id != TARGET_VESC_CAN_ID) {
      continue;
    }

    const uint8_t *data = message.data;
    switch (command) {
      case CAN_PACKET_STATUS:
        if (message.data_length_code >= 8) {
          vesc_status.rpm = static_cast<float>(be_i32(&data[0]));
          vesc_status.motor_current_a = be_i16(&data[4]) / 10.0f;
          vesc_status.duty = be_i16(&data[6]) / 1000.0f;
          vesc_status.received_mask |= VESC_MASK_STATUS;
        }
        break;
      case CAN_PACKET_STATUS_4:
        if (message.data_length_code >= 6) {
          vesc_status.temp_fet_c = be_i16(&data[0]) / 10.0f;
          vesc_status.temp_motor_c = be_i16(&data[2]) / 10.0f;
          vesc_status.input_current_a = be_i16(&data[4]) / 10.0f;
          vesc_status.received_mask |= VESC_MASK_STATUS_4;
        }
        break;
      case CAN_PACKET_STATUS_5:
        if (message.data_length_code >= 6) {
          vesc_status.voltage_v = be_i16(&data[4]) / 10.0f;
          vesc_status.received_mask |= VESC_MASK_STATUS_5;
        }
        break;
      default:
        continue;
    }
    vesc_status.last_rx_ms = now;
  }
}

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

  esp_now_peer_info_t peer = {};
  memcpy(peer.peer_addr, BASE_MAC, 6);
  peer.ifidx = WIFI_IF_STA;
  peer.channel = ESPNOW_CHANNEL;
  peer.encrypt = false;
  result = esp_now_add_peer(&peer);
  if (result == ESP_ERR_ESPNOW_EXIST) {
    result = ESP_OK;
  }
  if (result != ESP_OK) {
    Serial.print("ESP_NOW_ADD_PEER_FAIL err=");
    Serial.print(static_cast<int>(result));
    Serial.print(" ");
    Serial.println(esp_err_to_name(result));
  } else {
    Serial.println("ESP_NOW_READY broadcast peer added");
  }
}

void setup() {
  Serial.begin(115200);
  delay(800);
  WiFi.mode(WIFI_STA);
  Serial.println();
  Serial.println("BOAT ESP32-S3 INA780 + VESC CAN ESP-NOW sender");
  Serial.print("STA MAC: ");
  Serial.println(WiFi.macAddress());
  Serial.print("ESP-NOW channel: ");
  Serial.println(ESPNOW_CHANNEL);

  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.setClock(400000);

  twai_ready = setup_twai();
  setup_espnow();
}

void loop() {
  const uint32_t now = millis();
  receive_vesc_status(now);
  if (now - last_send_ms < SEND_INTERVAL_MS) {
    return;
  }
  last_send_ms = now;

  BoatTelemetryPacket packet = {};
  packet.magic = PACKET_MAGIC;
  packet.version = 3;
  packet.source_id = 1;
  packet.seq = seq_no++;
  packet.tx_ms = now;

  for (uint8_t i = 0; i < INA780_DEVICE_COUNT; i++) {
    if (read_ina780b(
          INA780_ADDRS[i],
          packet.ina_current_a[i],
          packet.ina_bus_v[i],
          packet.ina_temp_c[i],
          packet.ina_power_w[i])) {
      packet.ina_valid_mask |= static_cast<uint8_t>(1U << i);
    }
  }
  if ((packet.ina_valid_mask & REQUIRED_INA780_MASK) != REQUIRED_INA780_MASK) {
    packet.flags |= FLAG_INA780_REQUIRED_MISSING;
  }

  packet.vesc_id = TARGET_VESC_CAN_ID;
  packet.vesc_status_mask = vesc_status.received_mask;
  if (!twai_ready) {
    packet.flags |= FLAG_TWAI_INIT_FAIL;
  }
  if (vesc_status.last_rx_ms == 0 || now - vesc_status.last_rx_ms > VESC_STATUS_TIMEOUT_MS) {
    packet.flags |= FLAG_VESC_STATUS_STALE;
    packet.vesc_age_ms = 0xffffffffUL;
  } else {
    packet.vesc_age_ms = now - vesc_status.last_rx_ms;
  }
  packet.vesc_rpm = vesc_status.rpm;
  packet.vesc_motor_current_a = vesc_status.motor_current_a;
  packet.vesc_duty = vesc_status.duty;
  packet.vesc_input_current_a = vesc_status.input_current_a;
  packet.vesc_voltage_v = vesc_status.voltage_v;
  packet.vesc_power_w = vesc_status.voltage_v * vesc_status.input_current_a;
  packet.vesc_temp_fet_c = vesc_status.temp_fet_c;
  packet.vesc_temp_motor_c = vesc_status.temp_motor_c;

  const esp_err_t result = esp_now_send(BASE_MAC, reinterpret_cast<const uint8_t *>(&packet), sizeof(packet));
  if (result != ESP_OK) {
    Serial.print("ESP_NOW_SEND_FAIL err=");
    Serial.print(static_cast<int>(result));
    Serial.print(" ");
    Serial.println(esp_err_to_name(result));
  } else if ((packet.seq % 25) == 0) {
    Serial.print("TX seq=");
    Serial.print(packet.seq);
    Serial.print(" ina_mask=0x");
    Serial.print(packet.ina_valid_mask, HEX);
    for (uint8_t i = 0; i < INA780_DEVICE_COUNT; i++) {
      if (packet.ina_valid_mask & static_cast<uint8_t>(1U << i)) {
        Serial.print(" ");
        Serial.print(INA780_NAMES[i]);
        Serial.print("_w=");
        Serial.print(packet.ina_power_w[i], 1);
      }
    }
    Serial.print(" vesc_rpm=");
    Serial.print(packet.vesc_rpm, 0);
    Serial.print(" vesc_power_w=");
    Serial.print(packet.vesc_power_w, 1);
    Serial.print(" flags=0x");
    Serial.println(packet.flags, HEX);
  }
}
