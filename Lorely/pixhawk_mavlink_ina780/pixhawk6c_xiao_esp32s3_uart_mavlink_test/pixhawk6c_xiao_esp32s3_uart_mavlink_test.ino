/*
  Pixhawk 6C <-> XIAO ESP32-S3 UART MAVLink smoke test.

  Wiring target:
    Pixhawk TELEM TX -> XIAO D7/RX/GPIO44
    Pixhawk TELEM RX <- XIAO D6/TX/GPIO43
    Pixhawk GND     <-> XIAO GND

  Initial goal:
    1. Confirm Pixhawk -> XIAO by receiving MAVLink HEARTBEAT.
    2. Confirm XIAO -> Pixhawk by sending MAV_CMD_SET_MESSAGE_INTERVAL and
       watching ATTITUDE/GPS/BATTERY frames arrive on the same UART.
*/

#include <Arduino.h>
#include <math.h>
#include <string.h>

// XIAO ESP32-S3: D7/RX = GPIO44, D6/TX = GPIO43.
// HardwareSerial on ESP32 expects GPIO numbers. Some board packages define
// D6/D7 as board indexes, so use the actual GPIO numbers here.
static constexpr int PIXHAWK_RX_PIN = 44;
static constexpr int PIXHAWK_TX_PIN = 43;

static constexpr uint32_t USB_BAUD = 115200;
static constexpr uint32_t DEFAULT_PIXHAWK_BAUD = 115200;

static constexpr uint8_t XIAO_SYS_ID = 42;
static constexpr uint8_t XIAO_COMP_ID = 191;  // MAV_COMP_ID_ONBOARD_COMPUTER-ish monitor node.

static constexpr uint8_t MAV_STX_V1 = 0xFE;
static constexpr uint8_t MAV_STX_V2 = 0xFD;

static constexpr uint32_t MAV_MSG_ID_HEARTBEAT = 0;
static constexpr uint32_t MAV_MSG_ID_SYS_STATUS = 1;
static constexpr uint32_t MAV_MSG_ID_GPS_RAW_INT = 24;
static constexpr uint32_t MAV_MSG_ID_ATTITUDE = 30;
static constexpr uint32_t MAV_MSG_ID_COMMAND_LONG = 76;
static constexpr uint32_t MAV_MSG_ID_COMMAND_ACK = 77;
static constexpr uint32_t MAV_MSG_ID_VFR_HUD = 74;
static constexpr uint32_t MAV_MSG_ID_BATTERY_STATUS = 147;
static constexpr uint32_t MAV_MSG_ID_STATUSTEXT = 253;

static constexpr uint16_t MAV_CMD_SET_MESSAGE_INTERVAL = 511;

static constexpr uint8_t MAV_CRC_HEARTBEAT = 50;
static constexpr uint8_t MAV_CRC_SYS_STATUS = 124;
static constexpr uint8_t MAV_CRC_GPS_RAW_INT = 24;
static constexpr uint8_t MAV_CRC_ATTITUDE = 39;
static constexpr uint8_t MAV_CRC_COMMAND_LONG = 152;
static constexpr uint8_t MAV_CRC_COMMAND_ACK = 143;
static constexpr uint8_t MAV_CRC_VFR_HUD = 20;
static constexpr uint8_t MAV_CRC_BATTERY_STATUS = 154;
static constexpr uint8_t MAV_CRC_STATUSTEXT = 83;

HardwareSerial PixhawkSerial(1);

struct MavFrame {
  bool v2 = false;
  uint8_t len = 0;
  uint8_t seq = 0;
  uint8_t sysid = 0;
  uint8_t compid = 0;
  uint32_t msgid = 0;
  const uint8_t *payload = nullptr;
  bool crc_known = false;
  bool crc_ok = false;
  uint16_t rx_crc = 0;
  uint16_t calc_crc = 0;
};

struct Counters {
  uint32_t raw_bytes = 0;
  uint32_t stx_seen = 0;
  uint32_t frames = 0;
  uint32_t crc_bad = 0;
  uint32_t heartbeat = 0;
  uint32_t sys_status = 0;
  uint32_t attitude = 0;
  uint32_t gps = 0;
  uint32_t battery = 0;
  uint32_t command_ack = 0;
  uint32_t statustext = 0;
  uint32_t vfr_hud = 0;
  uint32_t unknown = 0;
};

static uint8_t rx_buf[300];
static uint16_t rx_index = 0;
static uint16_t rx_expected = 0;
static bool rx_active = false;

static uint8_t tx_seq = 0;
static uint8_t target_sys = 1;
static uint8_t target_comp = 1;
static bool saw_pixhawk_heartbeat = false;
static bool auto_requested = false;
static uint8_t baud_index = 1;
static uint32_t active_pixhawk_baud = DEFAULT_PIXHAWK_BAUD;

static Counters counters;
static uint32_t last_heartbeat_tx_ms = 0;
static uint32_t last_summary_ms = 0;
static uint32_t last_raw_rx_ms = 0;
static uint32_t last_rx_ms = 0;
static uint32_t last_summary_raw = 0;
static uint32_t last_summary_frames = 0;
static uint32_t last_summary_hb = 0;
static uint32_t last_summary_crc_bad = 0;

static float last_roll_deg = 0.0f;
static float last_pitch_deg = 0.0f;
static float last_yaw_deg = 0.0f;
static uint8_t last_gps_fix = 0;
static uint8_t last_gps_sat = 0;
static float last_bat_v = NAN;
static float last_bat_a = NAN;
static int8_t last_bat_remaining = -1;
static uint32_t last_msgid = UINT32_MAX;
static uint32_t last_unknown_msgid = UINT32_MAX;
static uint32_t last_crc_bad_msgid = UINT32_MAX;
static uint8_t last_frame_sys = 0;
static uint8_t last_frame_comp = 0;

static constexpr uint32_t PIXHAWK_BAUDS[] = {
    57600,
    115200,
    230400,
    460800,
    921600,
};

static void resetRxParser();

static void clearCounters() {
  counters = Counters{};
  saw_pixhawk_heartbeat = false;
  auto_requested = false;
  last_raw_rx_ms = 0;
  last_rx_ms = 0;
  last_summary_raw = 0;
  last_summary_frames = 0;
  last_summary_hb = 0;
  last_summary_crc_bad = 0;
  last_roll_deg = 0.0f;
  last_pitch_deg = 0.0f;
  last_yaw_deg = 0.0f;
  last_gps_fix = 0;
  last_gps_sat = 0;
  last_bat_v = NAN;
  last_bat_a = NAN;
  last_bat_remaining = -1;
  last_msgid = UINT32_MAX;
  last_unknown_msgid = UINT32_MAX;
  last_crc_bad_msgid = UINT32_MAX;
  last_frame_sys = 0;
  last_frame_comp = 0;
  resetRxParser();
}

static void beginPixhawkSerial(uint32_t baud) {
  active_pixhawk_baud = baud;
  PixhawkSerial.end();
  delay(20);
  PixhawkSerial.begin(active_pixhawk_baud, SERIAL_8N1, PIXHAWK_RX_PIN, PIXHAWK_TX_PIN);
  clearCounters();
  Serial.print(F("[CFG] Pixhawk UART baud="));
  Serial.println(active_pixhawk_baud);
}

static void crcAccumulate(uint8_t data, uint16_t *crc) {
  data ^= static_cast<uint8_t>(*crc & 0xff);
  data ^= data << 4;
  *crc = (*crc >> 8) ^ (static_cast<uint16_t>(data) << 8) ^
         (static_cast<uint16_t>(data) << 3) ^
         (static_cast<uint16_t>(data) >> 4);
}

static uint16_t mavlinkCrc(const uint8_t *buffer, size_t length, uint8_t crc_extra) {
  uint16_t crc = 0xffff;
  for (size_t i = 0; i < length; ++i) {
    crcAccumulate(buffer[i], &crc);
  }
  crcAccumulate(crc_extra, &crc);
  return crc;
}

static bool crcExtraForMessage(uint32_t msgid, uint8_t *crc_extra) {
  switch (msgid) {
    case MAV_MSG_ID_HEARTBEAT:
      *crc_extra = MAV_CRC_HEARTBEAT;
      return true;
    case MAV_MSG_ID_SYS_STATUS:
      *crc_extra = MAV_CRC_SYS_STATUS;
      return true;
    case MAV_MSG_ID_GPS_RAW_INT:
      *crc_extra = MAV_CRC_GPS_RAW_INT;
      return true;
    case MAV_MSG_ID_ATTITUDE:
      *crc_extra = MAV_CRC_ATTITUDE;
      return true;
    case MAV_MSG_ID_COMMAND_ACK:
      *crc_extra = MAV_CRC_COMMAND_ACK;
      return true;
    case MAV_MSG_ID_VFR_HUD:
      *crc_extra = MAV_CRC_VFR_HUD;
      return true;
    case MAV_MSG_ID_BATTERY_STATUS:
      *crc_extra = MAV_CRC_BATTERY_STATUS;
      return true;
    case MAV_MSG_ID_STATUSTEXT:
      *crc_extra = MAV_CRC_STATUSTEXT;
      return true;
    default:
      return false;
  }
}

static uint16_t getU16(const uint8_t *p) {
  return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

static int16_t getI16(const uint8_t *p) {
  return static_cast<int16_t>(getU16(p));
}

static uint32_t getU32(const uint8_t *p) {
  return static_cast<uint32_t>(p[0]) |
         (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

static int32_t getI32(const uint8_t *p) {
  return static_cast<int32_t>(getU32(p));
}

static float getFloat(const uint8_t *p) {
  float value = 0.0f;
  memcpy(&value, p, sizeof(value));
  return value;
}

static void putU16(uint8_t *p, uint16_t value) {
  p[0] = static_cast<uint8_t>(value & 0xff);
  p[1] = static_cast<uint8_t>((value >> 8) & 0xff);
}

static void putFloat(uint8_t *p, float value) {
  memcpy(p, &value, sizeof(value));
}

static void sendMavlinkV1(uint8_t msgid, const uint8_t *payload, uint8_t payload_len, uint8_t crc_extra) {
  uint8_t header[6] = {
      MAV_STX_V1,
      payload_len,
      tx_seq++,
      XIAO_SYS_ID,
      XIAO_COMP_ID,
      msgid,
  };

  uint8_t crc_input[5 + 255];
  memcpy(crc_input, &header[1], 5);
  if (payload_len > 0) {
    memcpy(&crc_input[5], payload, payload_len);
  }

  const uint16_t crc = mavlinkCrc(crc_input, 5 + payload_len, crc_extra);

  PixhawkSerial.write(header, sizeof(header));
  PixhawkSerial.write(payload, payload_len);
  PixhawkSerial.write(static_cast<uint8_t>(crc & 0xff));
  PixhawkSerial.write(static_cast<uint8_t>((crc >> 8) & 0xff));
}

static void sendGcsHeartbeat() {
  uint8_t payload[9] = {};
  payload[4] = 6;  // MAV_TYPE_GCS
  payload[5] = 8;  // MAV_AUTOPILOT_INVALID
  payload[6] = 0;
  payload[7] = 4;  // MAV_STATE_ACTIVE
  payload[8] = 3;  // MAVLink version marker for v1 heartbeat

  sendMavlinkV1(MAV_MSG_ID_HEARTBEAT, payload, sizeof(payload), MAV_CRC_HEARTBEAT);
}

static void sendStatustext(const char *text) {
  uint8_t payload[51] = {};
  payload[0] = 6;  // MAV_SEVERITY_INFO
  strncpy(reinterpret_cast<char *>(&payload[1]), text, 50);
  sendMavlinkV1(MAV_MSG_ID_STATUSTEXT, payload, sizeof(payload), MAV_CRC_STATUSTEXT);
  Serial.print(F("[TX] STATUSTEXT: "));
  Serial.println(text);
}

static void sendSetMessageInterval(uint32_t msgid, float hz) {
  uint8_t payload[33] = {};
  const float interval_us = (hz <= 0.0f) ? -1.0f : (1000000.0f / hz);

  putFloat(&payload[0], static_cast<float>(msgid));  // param1: message ID
  putFloat(&payload[4], interval_us);                // param2: interval in us
  putFloat(&payload[8], 0.0f);
  putFloat(&payload[12], 0.0f);
  putFloat(&payload[16], 0.0f);
  putFloat(&payload[20], 0.0f);
  putFloat(&payload[24], 0.0f);
  putU16(&payload[28], MAV_CMD_SET_MESSAGE_INTERVAL);
  payload[30] = target_sys;
  payload[31] = target_comp;
  payload[32] = 0;

  sendMavlinkV1(MAV_MSG_ID_COMMAND_LONG, payload, sizeof(payload), MAV_CRC_COMMAND_LONG);

  Serial.print(F("[TX] SET_MESSAGE_INTERVAL msgid="));
  Serial.print(msgid);
  Serial.print(F(" hz="));
  Serial.println(hz, 2);
}

static void requestUsefulStreams() {
  sendSetMessageInterval(MAV_MSG_ID_ATTITUDE, 4.0f);
  delay(20);
  sendSetMessageInterval(MAV_MSG_ID_GPS_RAW_INT, 1.0f);
  delay(20);
  sendSetMessageInterval(MAV_MSG_ID_SYS_STATUS, 1.0f);
  delay(20);
  sendSetMessageInterval(MAV_MSG_ID_BATTERY_STATUS, 1.0f);
  delay(20);
  sendStatustext("XIAO ESP32-S3 UART test connected");
}

static bool parseCompleteFrame(MavFrame *frame) {
  const uint8_t stx = rx_buf[0];
  const uint8_t len = rx_buf[1];

  frame->v2 = (stx == MAV_STX_V2);
  frame->len = len;

  uint16_t crc_offset = 0;
  uint16_t crc_input_offset = 1;
  uint16_t crc_input_len = 0;

  if (stx == MAV_STX_V1) {
    frame->seq = rx_buf[2];
    frame->sysid = rx_buf[3];
    frame->compid = rx_buf[4];
    frame->msgid = rx_buf[5];
    frame->payload = &rx_buf[6];
    crc_offset = 6 + len;
    crc_input_len = 5 + len;
  } else if (stx == MAV_STX_V2) {
    frame->seq = rx_buf[4];
    frame->sysid = rx_buf[5];
    frame->compid = rx_buf[6];
    frame->msgid = static_cast<uint32_t>(rx_buf[7]) |
                   (static_cast<uint32_t>(rx_buf[8]) << 8) |
                   (static_cast<uint32_t>(rx_buf[9]) << 16);
    frame->payload = &rx_buf[10];
    crc_offset = 10 + len;
    crc_input_len = 9 + len;
  } else {
    return false;
  }

  const uint16_t rx_crc = static_cast<uint16_t>(rx_buf[crc_offset]) |
                          (static_cast<uint16_t>(rx_buf[crc_offset + 1]) << 8);
  frame->rx_crc = rx_crc;

  uint8_t crc_extra = 0;
  frame->crc_known = crcExtraForMessage(frame->msgid, &crc_extra);
  if (frame->crc_known) {
    const uint16_t calc_crc = mavlinkCrc(&rx_buf[crc_input_offset], crc_input_len, crc_extra);
    frame->calc_crc = calc_crc;
    frame->crc_ok = (rx_crc == calc_crc);
  } else {
    frame->crc_ok = false;
  }

  return true;
}

static void resetRxParser() {
  rx_active = false;
  rx_index = 0;
  rx_expected = 0;
}

static void handleHeartbeat(const MavFrame &frame) {
  if (frame.len < 9) {
    return;
  }

  counters.heartbeat++;
  target_sys = frame.sysid;
  target_comp = frame.compid;

  if (!saw_pixhawk_heartbeat) {
    saw_pixhawk_heartbeat = true;
    Serial.print(F("[OK] HEARTBEAT from Pixhawk/ArduPilot sys="));
    Serial.print(frame.sysid);
    Serial.print(F(" comp="));
    Serial.print(frame.compid);
    Serial.print(F(" mav="));
    Serial.println(frame.v2 ? F("v2") : F("v1"));
  }
}

static void handleAttitude(const MavFrame &frame) {
  if (frame.len < 28) {
    return;
  }
  counters.attitude++;
  last_roll_deg = getFloat(&frame.payload[4]) * 57.2957795f;
  last_pitch_deg = getFloat(&frame.payload[8]) * 57.2957795f;
  last_yaw_deg = getFloat(&frame.payload[12]) * 57.2957795f;
}

static void handleGpsRawInt(const MavFrame &frame) {
  if (frame.len < 30) {
    return;
  }
  counters.gps++;
  last_gps_fix = frame.payload[28];
  last_gps_sat = frame.payload[29];
}

static void handleSysStatus(const MavFrame &frame) {
  if (frame.len < 31) {
    return;
  }
  counters.sys_status++;
  const uint16_t mv = getU16(&frame.payload[14]);
  const int16_t ca = getI16(&frame.payload[16]);
  last_bat_v = (mv == UINT16_MAX) ? NAN : (static_cast<float>(mv) / 1000.0f);
  last_bat_a = (ca == -1) ? NAN : (static_cast<float>(ca) / 100.0f);
  last_bat_remaining = static_cast<int8_t>(frame.payload[30]);
}

static void handleBatteryStatus(const MavFrame &frame) {
  if (frame.len < 36) {
    return;
  }
  counters.battery++;
  const uint16_t first_cell_mv = getU16(&frame.payload[10]);
  const int16_t ca = getI16(&frame.payload[30]);
  last_bat_v = (first_cell_mv == UINT16_MAX) ? last_bat_v : (static_cast<float>(first_cell_mv) / 1000.0f);
  last_bat_a = (ca == -1) ? last_bat_a : (static_cast<float>(ca) / 100.0f);
  last_bat_remaining = static_cast<int8_t>(frame.payload[35]);
}

static void handleCommandAck(const MavFrame &frame) {
  if (frame.len < 3) {
    return;
  }
  counters.command_ack++;
  const uint16_t command = getU16(&frame.payload[0]);
  const uint8_t result = frame.payload[2];
  Serial.print(F("[RX] COMMAND_ACK command="));
  Serial.print(command);
  Serial.print(F(" result="));
  Serial.println(result);
}

static void handleStatustext(const MavFrame &frame) {
  if (frame.len < 1) {
    return;
  }
  counters.statustext++;
}

static void handleVfrHud(const MavFrame &frame) {
  if (frame.len < 20) {
    return;
  }
  counters.vfr_hud++;
}

static void handleFrame(const MavFrame &frame) {
  counters.frames++;
  last_rx_ms = millis();
  last_msgid = frame.msgid;
  last_frame_sys = frame.sysid;
  last_frame_comp = frame.compid;

  if (frame.crc_known && !frame.crc_ok) {
    counters.crc_bad++;
    last_crc_bad_msgid = frame.msgid;
    return;
  }

  switch (frame.msgid) {
    case MAV_MSG_ID_HEARTBEAT:
      handleHeartbeat(frame);
      break;
    case MAV_MSG_ID_ATTITUDE:
      handleAttitude(frame);
      break;
    case MAV_MSG_ID_GPS_RAW_INT:
      handleGpsRawInt(frame);
      break;
    case MAV_MSG_ID_SYS_STATUS:
      handleSysStatus(frame);
      break;
    case MAV_MSG_ID_BATTERY_STATUS:
      handleBatteryStatus(frame);
      break;
    case MAV_MSG_ID_COMMAND_ACK:
      handleCommandAck(frame);
      break;
    case MAV_MSG_ID_STATUSTEXT:
      handleStatustext(frame);
      break;
    case MAV_MSG_ID_VFR_HUD:
      handleVfrHud(frame);
      break;
    default:
      counters.unknown++;
      last_unknown_msgid = frame.msgid;
      break;
  }
}

static void processRxByte(uint8_t b) {
  counters.raw_bytes++;
  last_raw_rx_ms = millis();

  if (!rx_active) {
    if (b == MAV_STX_V1 || b == MAV_STX_V2) {
      counters.stx_seen++;
      rx_active = true;
      rx_index = 0;
      rx_expected = 0;
      rx_buf[rx_index++] = b;
    }
    return;
  }

  if (rx_index >= sizeof(rx_buf)) {
    resetRxParser();
    return;
  }

  rx_buf[rx_index++] = b;

  if (rx_index == 2) {
    const uint8_t len = rx_buf[1];
    if (rx_buf[0] == MAV_STX_V1) {
      rx_expected = static_cast<uint16_t>(6 + len + 2);
    }
  } else if (rx_index == 3 && rx_buf[0] == MAV_STX_V2) {
    const uint8_t len = rx_buf[1];
    const uint8_t incompat_flags = rx_buf[2];
    const uint8_t signature_len = (incompat_flags & 0x01) ? 13 : 0;
    rx_expected = static_cast<uint16_t>(10 + len + 2 + signature_len);
  }

  if (rx_expected > sizeof(rx_buf)) {
    resetRxParser();
    return;
  }

  if (rx_expected > 0 && rx_index >= rx_expected) {
    MavFrame frame;
    if (parseCompleteFrame(&frame)) {
      handleFrame(frame);
    }
    resetRxParser();
  }
}

static void handleUsbCommand() {
  while (Serial.available()) {
    const char c = static_cast<char>(Serial.read());
    if (c == 'r' || c == 'R') {
      requestUsefulStreams();
    } else if (c == 't' || c == 'T') {
      sendStatustext("XIAO manual STATUSTEXT test");
    } else if (c == 'b' || c == 'B') {
      baud_index = static_cast<uint8_t>((baud_index + 1) % (sizeof(PIXHAWK_BAUDS) / sizeof(PIXHAWK_BAUDS[0])));
      beginPixhawkSerial(PIXHAWK_BAUDS[baud_index]);
    } else if (c == 'c' || c == 'C') {
      clearCounters();
      Serial.println(F("[CFG] counters cleared"));
    } else if (c == 'h' || c == 'H' || c == '?') {
      Serial.println(F("Commands: r=request streams, t=send STATUSTEXT, b=next baud, c=clear, h=help"));
    }
  }
}

static void printSummary() {
  const uint32_t d_raw = counters.raw_bytes - last_summary_raw;
  const uint32_t d_frames = counters.frames - last_summary_frames;
  const uint32_t d_hb = counters.heartbeat - last_summary_hb;
  const uint32_t d_crc_bad = counters.crc_bad - last_summary_crc_bad;
  last_summary_raw = counters.raw_bytes;
  last_summary_frames = counters.frames;
  last_summary_hb = counters.heartbeat;
  last_summary_crc_bad = counters.crc_bad;

  Serial.print(F("[STAT] raw="));
  Serial.print(counters.raw_bytes);
  Serial.print(F("(+"));
  Serial.print(d_raw);
  Serial.print(F(")"));
  Serial.print(F(" stx="));
  Serial.print(counters.stx_seen);
  Serial.print(F(" frames="));
  Serial.print(counters.frames);
  Serial.print(F("(+"));
  Serial.print(d_frames);
  Serial.print(F(")"));
  Serial.print(F(" hb="));
  Serial.print(counters.heartbeat);
  Serial.print(F("(+"));
  Serial.print(d_hb);
  Serial.print(F(")"));
  Serial.print(F(" att="));
  Serial.print(counters.attitude);
  Serial.print(F(" gps="));
  Serial.print(counters.gps);
  Serial.print(F(" sys="));
  Serial.print(counters.sys_status);
  Serial.print(F(" bat="));
  Serial.print(counters.battery);
  Serial.print(F(" ack="));
  Serial.print(counters.command_ack);
  Serial.print(F(" text="));
  Serial.print(counters.statustext);
  Serial.print(F(" vfr="));
  Serial.print(counters.vfr_hud);
  Serial.print(F(" unk="));
  Serial.print(counters.unknown);
  Serial.print(F(" crc_bad="));
  Serial.print(counters.crc_bad);
  Serial.print(F("(+"));
  Serial.print(d_crc_bad);
  Serial.print(F(")"));
  Serial.print(F(" baud="));
  Serial.print(active_pixhawk_baud);

  Serial.print(F(" | last_id="));
  if (last_msgid == UINT32_MAX) {
    Serial.print(F("--"));
  } else {
    Serial.print(last_msgid);
    Serial.print(F("@"));
    Serial.print(last_frame_sys);
    Serial.print(F("."));
    Serial.print(last_frame_comp);
  }

  Serial.print(F(" unk_id="));
  if (last_unknown_msgid == UINT32_MAX) {
    Serial.print(F("--"));
  } else {
    Serial.print(last_unknown_msgid);
  }

  Serial.print(F(" bad_id="));
  if (last_crc_bad_msgid == UINT32_MAX) {
    Serial.print(F("--"));
  } else {
    Serial.print(last_crc_bad_msgid);
  }

  Serial.print(F(" | r/p/y="));
  Serial.print(last_roll_deg, 1);
  Serial.print('/');
  Serial.print(last_pitch_deg, 1);
  Serial.print('/');
  Serial.print(last_yaw_deg, 1);

  Serial.print(F(" gps_fix="));
  Serial.print(last_gps_fix);
  Serial.print(F(" sat="));
  Serial.print(last_gps_sat);

  Serial.print(F(" bat="));
  if (isnan(last_bat_v)) {
    Serial.print(F("--"));
  } else {
    Serial.print(last_bat_v, 2);
    Serial.print(F("V"));
  }
  Serial.print(F("/"));
  if (isnan(last_bat_a)) {
    Serial.print(F("--"));
  } else {
    Serial.print(last_bat_a, 2);
    Serial.print(F("A"));
  }
  Serial.print(F(" rem="));
  Serial.print(last_bat_remaining);

  if (last_raw_rx_ms == 0) {
    Serial.print(F(" | no_raw"));
  } else if (last_rx_ms == 0) {
    Serial.print(F(" | raw_ms_ago="));
    Serial.print(millis() - last_raw_rx_ms);
    Serial.print(F(" no_mav_frame"));
  } else {
    Serial.print(F(" | last_rx_ms_ago="));
    Serial.print(millis() - last_rx_ms);
  }

  Serial.println();
}

void setup() {
  Serial.begin(USB_BAUD);
  delay(1000);

  active_pixhawk_baud = DEFAULT_PIXHAWK_BAUD;
  PixhawkSerial.begin(active_pixhawk_baud, SERIAL_8N1, PIXHAWK_RX_PIN, PIXHAWK_TX_PIN);

  Serial.println();
  Serial.println(F("=== Pixhawk 6C <-> XIAO ESP32-S3 UART MAVLink test ==="));
  Serial.print(F("USB baud     : "));
  Serial.println(USB_BAUD);
  Serial.print(F("Pixhawk baud : "));
  Serial.println(active_pixhawk_baud);
  Serial.print(F("XIAO RX pin  : GPIO"));
  Serial.println(PIXHAWK_RX_PIN);
  Serial.print(F("XIAO TX pin  : GPIO"));
  Serial.println(PIXHAWK_TX_PIN);
  Serial.println(F("Commands: r=request streams, t=send STATUSTEXT, b=next baud, c=clear, h=help"));
  Serial.println(F("Waiting for Pixhawk HEARTBEAT..."));
}

void loop() {
  handleUsbCommand();

  while (PixhawkSerial.available()) {
    processRxByte(static_cast<uint8_t>(PixhawkSerial.read()));
  }

  const uint32_t now = millis();

  if (now - last_heartbeat_tx_ms >= 1000) {
    last_heartbeat_tx_ms = now;
    sendGcsHeartbeat();
  }

  if (saw_pixhawk_heartbeat && !auto_requested && now > 3000) {
    auto_requested = true;
    Serial.println(F("[TX] First Pixhawk heartbeat seen. Requesting telemetry streams..."));
    requestUsefulStreams();
  }

  if (now - last_summary_ms >= 1000) {
    last_summary_ms = now;
    printSummary();
  }
}
