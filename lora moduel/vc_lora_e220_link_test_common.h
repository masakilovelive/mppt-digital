#pragma once

#include <Arduino.h>

#define VC_LORA_LINK_TEST_SENDER 1
#define VC_LORA_LINK_TEST_RECEIVER 2

#ifndef VC_LORA_LINK_TEST_ROLE
#error "Define VC_LORA_LINK_TEST_ROLE before including this file"
#endif

static constexpr uint32_t USB_BAUD = 115200;
static constexpr uint32_t E220_CONFIG_BAUD = 9600;
static constexpr uint32_t E220_UART_BAUD = 115200;

// XIAO pin map from VC_LoRa.pdf.
static constexpr int E220_M0_PIN = D0;
static constexpr int E220_M1_PIN = D1;
static constexpr int E220_TX_PIN = D2;   // XIAO TX -> E220 RXD
static constexpr int E220_RX_PIN = D3;   // XIAO RX <- E220 TXD
static constexpr int E220_AUX_PIN = D8;

// 115200 8N1, air 19.2 kbps, 32-byte sub-packet, 10 dBm,
// CH70 (920.125 MHz), transparent mode.
static constexpr uint8_t E220_PROFILE[8] = {
  0x00, 0x00, 0xE5, 0xC3, 0x46, 0x00, 0x00, 0x00
};

static constexpr size_t TEST_PACKET_SIZE = 32;
static constexpr uint32_t TEST_INTERVAL_MS = 1000;
static constexpr uint32_t ACK_TIMEOUT_MS = 3500;
static constexpr uint32_t EXCHANGE_GUARD_MS = 500;
// Sweep peer turnaround time automatically. The sequence number selects the
// delay, so both sides can classify a result without extra control bytes.
static constexpr uint32_t ACK_DELAYS_MS[] = {300, 500, 700, 1000};
static constexpr size_t ACK_DELAY_COUNT =
    sizeof(ACK_DELAYS_MS) / sizeof(ACK_DELAYS_MS[0]);
static constexpr uint8_t TEST_VERSION = 1;
static constexpr uint8_t PACKET_DATA = 1;
static constexpr uint8_t PACKET_ACK = 2;
static constexpr uint8_t PACKET_MAGIC[4] = {'V', 'C', 'L', 'T'};

HardwareSerial E220Serial(1);

static bool profile_pass = false;
static bool profile_written = false;
static uint8_t profile_actual[sizeof(E220_PROFILE)] = {};

static uint32_t radio_raw_rx = 0;
static uint32_t radio_tx_bytes = 0;
static uint32_t radio_tx_fail = 0;
static uint32_t last_status_ms = 0;

static uint32_t tx_sequence = 0;
static uint32_t tx_packets = 0;
static uint32_t ack_packets = 0;
static uint32_t ack_timeouts = 0;
static uint32_t unexpected_packets = 0;
static uint32_t last_rtt_ms = 0;
static uint32_t last_send_ms = 0;
static uint32_t last_exchange_end_ms = 0;
static uint32_t pending_since_ms = 0;
static uint32_t pending_sequence = 0;
static bool ack_pending = false;
static uint32_t delay_sent[ACK_DELAY_COUNT] = {};
static uint32_t delay_acked[ACK_DELAY_COUNT] = {};
static uint32_t delay_timed_out[ACK_DELAY_COUNT] = {};
static uint32_t delay_last_rtt[ACK_DELAY_COUNT] = {};

static uint32_t rx_packets = 0;
static uint32_t rx_missing = 0;
static uint32_t rx_duplicates = 0;
static uint32_t rx_out_of_order = 0;
static uint32_t ack_sent = 0;
static uint32_t last_ack_delay_ms = 0;
static uint32_t last_rx_sequence = 0;
static bool have_rx_sequence = false;

struct PacketParser {
  uint8_t data[TEST_PACKET_SIZE];
  size_t length = 0;
  uint32_t crc_errors = 0;
  uint32_t discarded_bytes = 0;
};

static PacketParser parser;

static uint16_t crc16_ccitt(const uint8_t *data, size_t length) {
  uint16_t crc = 0xffff;
  for (size_t i = 0; i < length; ++i) {
    crc ^= static_cast<uint16_t>(data[i]) << 8;
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x1021)
                           : static_cast<uint16_t>(crc << 1);
    }
  }
  return crc;
}

static void write_u32_le(uint8_t *destination, uint32_t value) {
  destination[0] = static_cast<uint8_t>(value);
  destination[1] = static_cast<uint8_t>(value >> 8);
  destination[2] = static_cast<uint8_t>(value >> 16);
  destination[3] = static_cast<uint8_t>(value >> 24);
}

static uint32_t read_u32_le(const uint8_t *source) {
  return static_cast<uint32_t>(source[0]) |
         (static_cast<uint32_t>(source[1]) << 8) |
         (static_cast<uint32_t>(source[2]) << 16) |
         (static_cast<uint32_t>(source[3]) << 24);
}

static void print_hex_byte(uint8_t value) {
  if (value < 0x10) {
    Serial.print('0');
  }
  Serial.print(value, HEX);
}

static void print_profile(const uint8_t *profile) {
  for (size_t i = 0; i < sizeof(E220_PROFILE); ++i) {
    print_hex_byte(profile[i]);
    if (i + 1 < sizeof(E220_PROFILE)) {
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

static void clear_radio_input(uint32_t quiet_ms = 30) {
  const uint32_t start = millis();
  while (millis() - start < quiet_ms) {
    while (E220Serial.available() > 0) {
      E220Serial.read();
    }
    delay(1);
  }
}

static size_t read_radio_response(uint8_t *response, size_t capacity,
                                  uint32_t timeout_ms) {
  size_t length = 0;
  const uint32_t start = millis();
  while (millis() - start < timeout_ms && length < capacity) {
    while (E220Serial.available() > 0 && length < capacity) {
      response[length++] = static_cast<uint8_t>(E220Serial.read());
    }
    delay(1);
  }
  return length;
}

static bool read_e220_profile(uint8_t *profile) {
  const uint8_t command[] = {0xC1, 0x00, sizeof(E220_PROFILE)};
  uint8_t response[sizeof(E220_PROFILE) + 3] = {};
  clear_radio_input();
  E220Serial.write(command, sizeof(command));
  E220Serial.flush();
  const size_t length = read_radio_response(response, sizeof(response), 500);
  if (length != sizeof(response) || response[0] != 0xC1 ||
      response[1] != 0x00 || response[2] != sizeof(E220_PROFILE)) {
    return false;
  }
  memcpy(profile, response + 3, sizeof(E220_PROFILE));
  return true;
}

static bool write_e220_profile() {
  uint8_t command[sizeof(E220_PROFILE) + 3] = {
    0xC0, 0x00, sizeof(E220_PROFILE)
  };
  uint8_t response[sizeof(command)] = {};
  memcpy(command + 3, E220_PROFILE, sizeof(E220_PROFILE));
  clear_radio_input();
  E220Serial.write(command, sizeof(command));
  E220Serial.flush();
  const size_t length = read_radio_response(response, sizeof(response), 700);
  return length == sizeof(response) && response[0] == 0xC1 &&
         response[1] == 0x00 && response[2] == sizeof(E220_PROFILE);
}

static void configure_e220() {
  digitalWrite(E220_M0_PIN, HIGH);
  digitalWrite(E220_M1_PIN, HIGH);
  delay(120);
  const bool aux_config = wait_aux_high(1200);

  E220Serial.setRxBufferSize(4096);
  E220Serial.begin(E220_CONFIG_BAUD, SERIAL_8N1, E220_RX_PIN, E220_TX_PIN);
  delay(80);

  bool read_ok = aux_config && read_e220_profile(profile_actual);
  if (read_ok && memcmp(profile_actual, E220_PROFILE, sizeof(E220_PROFILE)) != 0) {
    profile_written = write_e220_profile();
    delay(150);
    read_ok = read_e220_profile(profile_actual);
  }
  profile_pass = read_ok &&
                 memcmp(profile_actual, E220_PROFILE, sizeof(E220_PROFILE)) == 0;

  Serial.print("[PROFILE] target=");
  print_profile(E220_PROFILE);
  Serial.print(" actual=");
  if (read_ok) {
    print_profile(profile_actual);
  } else {
    Serial.print("READ_FAIL");
  }
  Serial.print(" result=");
  Serial.print(profile_pass ? "PASS" : "FAIL");
  Serial.print(" written=");
  Serial.println(profile_written ? "YES" : "NO");

  E220Serial.end();
  digitalWrite(E220_M0_PIN, LOW);
  digitalWrite(E220_M1_PIN, LOW);
  delay(120);
  wait_aux_high(1200);
  E220Serial.begin(E220_UART_BAUD, SERIAL_8N1, E220_RX_PIN, E220_TX_PIN);
}

static void build_packet(uint8_t type, uint32_t sequence, uint32_t timestamp,
                         uint8_t *packet) {
  memcpy(packet, PACKET_MAGIC, sizeof(PACKET_MAGIC));
  packet[4] = TEST_VERSION;
  packet[5] = type;
  write_u32_le(packet + 6, sequence);
  write_u32_le(packet + 10, timestamp);
  for (size_t i = 14; i < TEST_PACKET_SIZE - 2; ++i) {
    packet[i] = static_cast<uint8_t>(0xA5 ^ type ^ sequence ^ (i * 17));
  }
  const uint16_t crc = crc16_ccitt(packet, TEST_PACKET_SIZE - 2);
  packet[TEST_PACKET_SIZE - 2] = static_cast<uint8_t>(crc);
  packet[TEST_PACKET_SIZE - 1] = static_cast<uint8_t>(crc >> 8);
}

static bool send_packet(uint8_t type, uint32_t sequence, uint32_t timestamp) {
  uint8_t packet[TEST_PACKET_SIZE] = {};
  build_packet(type, sequence, timestamp, packet);
  if (!wait_aux_high(1000)) {
    ++radio_tx_fail;
    return false;
  }
  const size_t written = E220Serial.write(packet, sizeof(packet));
  E220Serial.flush();
  radio_tx_bytes += static_cast<uint32_t>(written);
  if (written != sizeof(packet)) {
    ++radio_tx_fail;
    return false;
  }
  return true;
}

static bool packet_magic_matches(const uint8_t *packet) {
  return memcmp(packet, PACKET_MAGIC, sizeof(PACKET_MAGIC)) == 0;
}

static bool packet_crc_matches(const uint8_t *packet) {
  const uint16_t expected = crc16_ccitt(packet, TEST_PACKET_SIZE - 2);
  const uint16_t received = static_cast<uint16_t>(packet[TEST_PACKET_SIZE - 2]) |
                            (static_cast<uint16_t>(packet[TEST_PACKET_SIZE - 1]) << 8);
  return expected == received;
}

static void handle_packet(const uint8_t *packet) {
  const uint8_t version = packet[4];
  const uint8_t type = packet[5];
  const uint32_t sequence = read_u32_le(packet + 6);

  if (version != TEST_VERSION) {
    ++unexpected_packets;
    return;
  }

#if VC_LORA_LINK_TEST_ROLE == VC_LORA_LINK_TEST_SENDER
  if (type != PACKET_ACK) {
    ++unexpected_packets;
    return;
  }
  if (ack_pending && sequence == pending_sequence) {
    ++ack_packets;
    last_rtt_ms = millis() - pending_since_ms;
    const size_t bucket = sequence % ACK_DELAY_COUNT;
    ++delay_acked[bucket];
    delay_last_rtt[bucket] = last_rtt_ms;
    ack_pending = false;
    last_exchange_end_ms = millis();
  } else {
    ++unexpected_packets;
  }
#else
  if (type != PACKET_DATA) {
    ++unexpected_packets;
    return;
  }

  ++rx_packets;
  if (!have_rx_sequence) {
    last_rx_sequence = sequence;
    have_rx_sequence = true;
  } else {
    const uint32_t delta = sequence - last_rx_sequence;
    if (delta == 0) {
      ++rx_duplicates;
    } else if (delta < 0x80000000UL) {
      if (delta > 1) {
        rx_missing += delta - 1;
      }
      last_rx_sequence = sequence;
    } else {
      ++rx_out_of_order;
    }
  }

  last_ack_delay_ms = ACK_DELAYS_MS[sequence % ACK_DELAY_COUNT];
  delay(last_ack_delay_ms);
  if (send_packet(PACKET_ACK, sequence, millis())) {
    ++ack_sent;
  }
#endif
}

static void parser_shift_left(PacketParser &state) {
  memmove(state.data, state.data + 1, state.length - 1);
  --state.length;
  ++state.discarded_bytes;
}

static void parser_feed(PacketParser &state, uint8_t value) {
  if (state.length >= TEST_PACKET_SIZE) {
    state.length = 0;
  }
  state.data[state.length++] = value;

  while (state.length >= sizeof(PACKET_MAGIC) &&
         !packet_magic_matches(state.data)) {
    parser_shift_left(state);
  }

  if (state.length == TEST_PACKET_SIZE) {
    if (packet_crc_matches(state.data)) {
      handle_packet(state.data);
      state.length = 0;
    } else {
      ++state.crc_errors;
      parser_shift_left(state);
      while (state.length >= sizeof(PACKET_MAGIC) &&
             !packet_magic_matches(state.data)) {
        parser_shift_left(state);
      }
    }
  }
}

static void receive_radio_bytes() {
  while (E220Serial.available() > 0) {
    const int value = E220Serial.read();
    if (value >= 0) {
      ++radio_raw_rx;
      parser_feed(parser, static_cast<uint8_t>(value));
    }
  }
}

static void run_sender() {
  const uint32_t now = millis();
  if (ack_pending && now - pending_since_ms >= ACK_TIMEOUT_MS) {
    ++ack_timeouts;
    ++delay_timed_out[pending_sequence % ACK_DELAY_COUNT];
    ack_pending = false;
    last_exchange_end_ms = now;
  }
  if (!ack_pending && now - last_send_ms >= TEST_INTERVAL_MS &&
      now - last_exchange_end_ms >= EXCHANGE_GUARD_MS) {
    const uint32_t sequence = tx_sequence++;
    last_send_ms = now;
    if (send_packet(PACKET_DATA, sequence, now)) {
      ++tx_packets;
      ++delay_sent[sequence % ACK_DELAY_COUNT];
      pending_sequence = sequence;
      pending_since_ms = millis();
      ack_pending = true;
    }
  }
}

static void print_status() {
  const uint32_t now = millis();
  if (now - last_status_ms < 1000) {
    return;
  }
  last_status_ms = now;

#if VC_LORA_LINK_TEST_ROLE == VC_LORA_LINK_TEST_SENDER
  Serial.print("[LINK_TX] profile=");
  Serial.print(profile_pass ? "PASS" : "FAIL");
  Serial.print(" reg0=0x");
  print_hex_byte(profile_actual[2]);
  Serial.print(" reg1=0x");
  print_hex_byte(profile_actual[3]);
  Serial.print(" sent=");
  Serial.print(tx_packets);
  Serial.print(" ack=");
  Serial.print(ack_packets);
  Serial.print(" timeout=");
  Serial.print(ack_timeouts);
  Serial.print(" raw_rx=");
  Serial.print(radio_raw_rx);
  Serial.print(" crc_err=");
  Serial.print(parser.crc_errors);
  Serial.print(" unexpected=");
  Serial.print(unexpected_packets);
  Serial.print(" rtt_ms=");
  Serial.print(last_rtt_ms);
  // Per delay: sent/ACK/timeout/last RTT.
  for (size_t i = 0; i < ACK_DELAY_COUNT; ++i) {
    Serial.print(" d");
    Serial.print(ACK_DELAYS_MS[i]);
    Serial.print('=');
    Serial.print(delay_sent[i]);
    Serial.print('/');
    Serial.print(delay_acked[i]);
    Serial.print('/');
    Serial.print(delay_timed_out[i]);
    Serial.print('/');
    Serial.print(delay_last_rtt[i]);
  }
#else
  Serial.print("[LINK_RX] profile=");
  Serial.print(profile_pass ? "PASS" : "FAIL");
  Serial.print(" reg0=0x");
  print_hex_byte(profile_actual[2]);
  Serial.print(" reg1=0x");
  print_hex_byte(profile_actual[3]);
  Serial.print(" raw_rx=");
  Serial.print(radio_raw_rx);
  Serial.print(" valid=");
  Serial.print(rx_packets);
  Serial.print(" missing=");
  Serial.print(rx_missing);
  Serial.print(" crc_err=");
  Serial.print(parser.crc_errors);
  Serial.print(" duplicate=");
  Serial.print(rx_duplicates);
  Serial.print(" out_of_order=");
  Serial.print(rx_out_of_order);
  Serial.print(" ack_sent=");
  Serial.print(ack_sent);
  Serial.print(" last_ack_delay_ms=");
  Serial.print(last_ack_delay_ms);
#endif
  Serial.print(" tx_fail=");
  Serial.print(radio_tx_fail);
  Serial.print(" discarded=");
  Serial.print(parser.discarded_bytes);
  Serial.print(" aux=");
  Serial.println(digitalRead(E220_AUX_PIN) == HIGH ? "HIGH" : "LOW");
}

void setup() {
  pinMode(E220_M0_PIN, OUTPUT);
  pinMode(E220_M1_PIN, OUTPUT);
  pinMode(E220_AUX_PIN, INPUT);
  digitalWrite(E220_M0_PIN, LOW);
  digitalWrite(E220_M1_PIN, LOW);

  Serial.begin(USB_BAUD);
  delay(1200);
  Serial.println();
#if VC_LORA_LINK_TEST_ROLE == VC_LORA_LINK_TEST_SENDER
  Serial.println("[BOOT] VC_LoRa E220 isolated link test: SENDER");
#else
  Serial.println("[BOOT] VC_LoRa E220 isolated link test: RECEIVER/ACK");
#endif
  Serial.println("[BOOT] USB monitor=115200, radio profile=E5/C3, packet=32 bytes");

  configure_e220();
  if (!profile_pass) {
    Serial.println("[FATAL] E220 profile verification failed");
  }
  last_send_ms = millis() - TEST_INTERVAL_MS;
  last_exchange_end_ms = millis() - EXCHANGE_GUARD_MS;
}

void loop() {
  receive_radio_bytes();
  if (profile_pass) {
#if VC_LORA_LINK_TEST_ROLE == VC_LORA_LINK_TEST_SENDER
    run_sender();
#endif
  }
  print_status();
  delay(1);
}
