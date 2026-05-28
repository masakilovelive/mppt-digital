#include <Arduino.h>
#include <Wire.h>

// INA780BIDEKR MAVLink telemetry / one-by-one checker for ESP32-S3 DevKitC-1.
// Wiring: SDA -> GPIO8, SCL -> GPIO9, 3.3V, GND common.
//
// Serial commands:
//   m: MAVLink telemetry stream for Lorely3 UI (default after boot)
//   1: check BATT     expected 0x40
//   2: check AUX_BATT expected 0x43
//   3: check ESC      expected 0x41
//   4: check PV1      expected 0x44
//   5: check PV2      expected 0x45
//   s: scan all I2C addresses
//   a: auto-detect and read every INA780B found on the bus

static const int I2C_SDA_PIN = 8;
static const int I2C_SCL_PIN = 9;
static const uint32_t SERIAL_BAUD = 115200;
static const uint32_t SAMPLE_INTERVAL_MS = 200;
static const uint32_t HEARTBEAT_INTERVAL_MS = 1000;
static const uint8_t MAV_SYS_ID = 43;
static const uint8_t MAV_COMP_ID = 192;
static const uint8_t MAV_MSG_ID_HEARTBEAT = 0;
static const uint8_t MAV_MSG_ID_NAMED_VALUE_FLOAT = 251;
static const uint8_t MAV_CRC_EXTRA_HEARTBEAT = 50;
static const uint8_t MAV_CRC_EXTRA_NAMED_VALUE_FLOAT = 170;

struct Ina780bDevice {
  char command;
  const char *name;
  const char *mavPrefix;
  uint8_t address;
};

static const Ina780bDevice DEVICES[] = {
  {'1', "BATT", "BATT", 0x40},
  {'2', "AUX_BATT", "AUX", 0x43},
  {'3', "ESC", "ESC", 0x41},
  {'4', "PV1", "PV1", 0x44},
  {'5', "PV2", "PV2", 0x45},
};
static const uint8_t DEVICE_COUNT = sizeof(DEVICES) / sizeof(DEVICES[0]);

static const uint8_t REG_VBUS = 0x05;
static const uint8_t REG_DIETEMP = 0x06;
static const uint8_t REG_CURRENT = 0x07;
static const uint8_t REG_POWER = 0x08;
static const uint8_t REG_MANUFACTURER_ID = 0x3E;

static int8_t selectedIndex = -1;
static bool autoReadAll = false;
static bool mavlinkStream = true;
static uint32_t lastSampleMs = 0;
static uint32_t lastHeartbeatMs = 0;
static uint8_t mavSeq = 0;

static void printHex2(uint8_t value) {
  Serial.print("0x");
  if (value < 0x10) {
    Serial.print('0');
  }
  Serial.print(value, HEX);
}

static void printHex4(uint16_t value) {
  Serial.print("0x");
  if (value < 0x1000) {
    Serial.print('0');
  }
  if (value < 0x0100) {
    Serial.print('0');
  }
  if (value < 0x0010) {
    Serial.print('0');
  }
  Serial.print(value, HEX);
}

static bool readI2cU16(uint8_t address, uint8_t reg, uint16_t &value) {
  Wire.beginTransmission(address);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }

  if (Wire.requestFrom((int)address, 2) != 2) {
    return false;
  }

  value = ((uint16_t)Wire.read() << 8) | Wire.read();
  return true;
}

static bool readI2cU24(uint8_t address, uint8_t reg, uint32_t &value) {
  Wire.beginTransmission(address);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }

  if (Wire.requestFrom((int)address, 3) != 3) {
    return false;
  }

  value = ((uint32_t)Wire.read() << 16) | ((uint32_t)Wire.read() << 8) | Wire.read();
  return true;
}

static float decodeDieTempC(uint16_t raw) {
  int16_t tempRaw = (int16_t)(raw >> 4);
  if (tempRaw & 0x0800) {
    tempRaw |= 0xF000;
  }
  return tempRaw * 0.125f;
}

static void crcAccumulate(uint8_t data, uint16_t *crc) {
  data ^= static_cast<uint8_t>(*crc & 0xff);
  data ^= data << 4;
  *crc = (*crc >> 8) ^ (static_cast<uint16_t>(data) << 8) ^
         (static_cast<uint16_t>(data) << 3) ^ (static_cast<uint16_t>(data) >> 4);
}

static uint16_t mavlinkCrc(const uint8_t *buffer, size_t length, uint8_t crcExtra) {
  uint16_t crc = 0xffff;
  for (size_t i = 0; i < length; i++) {
    crcAccumulate(buffer[i], &crc);
  }
  crcAccumulate(crcExtra, &crc);
  return crc;
}

static void sendMavlinkV1(uint8_t msgId, const uint8_t *payload, uint8_t payloadLen, uint8_t crcExtra) {
  uint8_t header[6] = {0xFE, payloadLen, mavSeq++, MAV_SYS_ID, MAV_COMP_ID, msgId};
  uint8_t crcInput[5 + 255];
  memcpy(crcInput, &header[1], 5);
  if (payloadLen > 0) {
    memcpy(&crcInput[5], payload, payloadLen);
  }
  const uint16_t crc = mavlinkCrc(crcInput, 5 + payloadLen, crcExtra);
  Serial.write(header, sizeof(header));
  Serial.write(payload, payloadLen);
  Serial.write(static_cast<uint8_t>(crc & 0xff));
  Serial.write(static_cast<uint8_t>(crc >> 8));
}

static void sendHeartbeat() {
  uint8_t payload[9] = {};
  payload[4] = 6;  // MAV_TYPE_GCS.
  payload[5] = 8;  // MAV_AUTOPILOT_INVALID.
  payload[7] = 4;  // MAV_STATE_ACTIVE.
  payload[8] = 3;
  sendMavlinkV1(MAV_MSG_ID_HEARTBEAT, payload, sizeof(payload), MAV_CRC_EXTRA_HEARTBEAT);
}

static void sendNamedValueFloat(const char *name, float value) {
  uint8_t payload[18] = {};
  const uint32_t now = millis();
  payload[0] = static_cast<uint8_t>(now & 0xff);
  payload[1] = static_cast<uint8_t>((now >> 8) & 0xff);
  payload[2] = static_cast<uint8_t>((now >> 16) & 0xff);
  payload[3] = static_cast<uint8_t>((now >> 24) & 0xff);
  memcpy(&payload[4], &value, sizeof(float));
  strncpy(reinterpret_cast<char *>(&payload[8]), name, 10);
  sendMavlinkV1(MAV_MSG_ID_NAMED_VALUE_FLOAT, payload, sizeof(payload), MAV_CRC_EXTRA_NAMED_VALUE_FLOAT);
}

static void sendIna780Values(const char *prefix, float busV, float currentA, float powerW, float tempC) {
  char name[11] = {};
  snprintf(name, sizeof(name), "%s_V", prefix);
  sendNamedValueFloat(name, busV);
  snprintf(name, sizeof(name), "%s_I", prefix);
  sendNamedValueFloat(name, currentA);
  snprintf(name, sizeof(name), "%s_P", prefix);
  sendNamedValueFloat(name, powerW);
  snprintf(name, sizeof(name), "%s_T", prefix);
  sendNamedValueFloat(name, tempC);
}

static bool readIna780b(uint8_t address, float &currentA, float &busV, float &tempC, float &powerW, uint16_t &manufacturerId) {
  uint16_t rawCurrent = 0;
  uint16_t rawBus = 0;
  uint16_t rawTemp = 0;
  uint32_t rawPower = 0;

  if (!readI2cU16(address, REG_MANUFACTURER_ID, manufacturerId)) {
    return false;
  }
  if (manufacturerId != 0x5449) {
    return false;
  }
  if (!readI2cU16(address, REG_CURRENT, rawCurrent) ||
      !readI2cU16(address, REG_VBUS, rawBus) ||
      !readI2cU16(address, REG_DIETEMP, rawTemp) ||
      !readI2cU24(address, REG_POWER, rawPower)) {
    return false;
  }

  currentA = (int16_t)rawCurrent * 0.0024f;
  busV = rawBus * 0.003125f;
  tempC = decodeDieTempC(rawTemp);
  powerW = rawPower * 0.000480f;
  return true;
}

static void sendMavlinkIna780Samples() {
  uint8_t validMask = 0;
  for (uint8_t i = 0; i < DEVICE_COUNT; i++) {
    float currentA = 0.0f;
    float busV = 0.0f;
    float tempC = 0.0f;
    float powerW = 0.0f;
    uint16_t manufacturerId = 0;
    if (readIna780b(DEVICES[i].address, currentA, busV, tempC, powerW, manufacturerId)) {
      validMask |= static_cast<uint8_t>(1U << i);
      sendIna780Values(DEVICES[i].mavPrefix, busV, currentA, powerW, tempC);
    }
  }
  sendNamedValueFloat("INA_MASK", static_cast<float>(validMask));
  sendNamedValueFloat("RSSI", 0.0f);  // USB direct connection has no radio RSSI.
  sendNamedValueFloat("RX_DT", static_cast<float>(SAMPLE_INTERVAL_MS));
  sendNamedValueFloat("LOSS", 0.0f);
  sendNamedValueFloat("FAULT", 0.0f);
}

static void printMenu() {
  Serial.println();
  Serial.println("INA780BIDEKR text diagnostic mode");
  Serial.println("Commands:");
  Serial.println("  m: return to MAVLink telemetry stream");
  for (uint8_t i = 0; i < DEVICE_COUNT; i++) {
    Serial.print("  ");
    Serial.print(DEVICES[i].command);
    Serial.print(": ");
    Serial.print(DEVICES[i].name);
    Serial.print(" expected ");
    printHex2(DEVICES[i].address);
    Serial.println();
  }
  Serial.println("  s: scan all I2C addresses");
  Serial.println("  a: auto-read every INA780B found");
  Serial.println();
}

static void scanI2cBus() {
  uint8_t found = 0;

  Serial.println("I2C_SCAN_BEGIN");
  for (uint8_t address = 1; address < 127; address++) {
    Wire.beginTransmission(address);
    if (Wire.endTransmission() == 0) {
      found++;
      Serial.print("I2C_FOUND addr=");
      printHex2(address);

      uint16_t manufacturerId = 0;
      if (readI2cU16(address, REG_MANUFACTURER_ID, manufacturerId)) {
        Serial.print(" manufacturer=");
        printHex4(manufacturerId);
        if (manufacturerId == 0x5449) {
          Serial.print(" INA780B_OK");
        }
      }
      Serial.println();
    }
  }
  if (found == 0) {
    Serial.println("I2C_FOUND none");
  }
  Serial.println("I2C_SCAN_END");
}

static void printIna780bSample(const char *name, uint8_t address) {
  float currentA = 0.0f;
  float busV = 0.0f;
  float tempC = 0.0f;
  float powerW = 0.0f;
  uint16_t manufacturerId = 0;

  if (!readIna780b(address, currentA, busV, tempC, powerW, manufacturerId)) {
    Serial.print("INA780B_CHECK name=");
    Serial.print(name);
    Serial.print(" addr=");
    printHex2(address);
    Serial.println(" result=read_failed");
    return;
  }

  Serial.print("INA780B_CHECK name=");
  Serial.print(name);
  Serial.print(" addr=");
  printHex2(address);
  Serial.print(" result=ok current=");
  Serial.print(currentA, 4);
  Serial.print("A bus=");
  Serial.print(busV, 4);
  Serial.print("V temp=");
  Serial.print(tempC, 3);
  Serial.print("C power=");
  Serial.print(powerW, 4);
  Serial.print("W manufacturer=");
  printHex4(manufacturerId);
  Serial.println();
}

static void autoReadFoundIna780b() {
  for (uint8_t address = 1; address < 127; address++) {
    uint16_t manufacturerId = 0;
    if (!readI2cU16(address, REG_MANUFACTURER_ID, manufacturerId) || manufacturerId != 0x5449) {
      continue;
    }

    const char *name = "UNKNOWN";
    for (uint8_t i = 0; i < DEVICE_COUNT; i++) {
      if (DEVICES[i].address == address) {
        name = DEVICES[i].name;
        break;
      }
    }
    printIna780bSample(name, address);
  }
}

static void handleCommand(char command) {
  if (command == '\r' || command == '\n' || command == ' ') {
    return;
  }

  if (command == 'm' || command == 'M') {
    selectedIndex = -1;
    autoReadAll = false;
    mavlinkStream = true;
    lastSampleMs = 0;
    lastHeartbeatMs = 0;
    return;
  }

  if (command == 's' || command == 'S') {
    mavlinkStream = false;
    scanI2cBus();
    return;
  }

  if (command == 'a' || command == 'A') {
    mavlinkStream = false;
    selectedIndex = -1;
    autoReadAll = true;
    Serial.println("Mode: auto-read every INA780B found");
    return;
  }

  for (uint8_t i = 0; i < DEVICE_COUNT; i++) {
    if (command == DEVICES[i].command) {
      mavlinkStream = false;
      selectedIndex = i;
      autoReadAll = false;
      Serial.print("Mode: check ");
      Serial.print(DEVICES[i].name);
      Serial.print(" at ");
      printHex2(DEVICES[i].address);
      Serial.println();
      return;
    }
  }

  printMenu();
}

void setup() {
  Serial.begin(SERIAL_BAUD);
  delay(1000);

  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.setClock(400000);
}

void loop() {
  while (Serial.available() > 0) {
    handleCommand((char)Serial.read());
  }

  const uint32_t nowMs = millis();
  if (mavlinkStream && nowMs - lastHeartbeatMs >= HEARTBEAT_INTERVAL_MS) {
    sendHeartbeat();
    lastHeartbeatMs = nowMs;
  }
  if (nowMs - lastSampleMs >= SAMPLE_INTERVAL_MS) {
    if (mavlinkStream) {
      sendMavlinkIna780Samples();
    } else if (selectedIndex >= 0) {
      const Ina780bDevice &device = DEVICES[selectedIndex];
      printIna780bSample(device.name, device.address);
    } else if (autoReadAll) {
      autoReadFoundIna780b();
    }
    lastSampleMs = nowMs;
  }

  delay(1);
}
