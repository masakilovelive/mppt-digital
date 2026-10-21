// VC LoRa Phase 6 Vehicle uplink diagnostic firmware for XIAO ESP32-S3.
//
// The production transport is included byte-for-byte.  The only additional
// behaviour is a command-driven, USB-CDC-only status observer on Vehicle COM3.
// No diagnostic bytes are written to the E220 or Pixhawk UARTs.

#define VC_LORA_PHASE6_VEHICLE 1
#define VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS 1
#define VC_LORA_PHASE6_VEHICLE_HEARTBEAT_AB 1

#include <Arduino.h>
#include <Preferences.h>
#include <esp_timer.h>

#include "VC_LoRa_Core.h"
#include "vc_lora_vehicle_diag_observer.hpp"

// Keep the canonical bridge unchanged. Rename only its Arduino entry points
// so this diagnostic wrapper can run the bridge first on every iteration.
#define setup vc_lora_phase6_vehicle_setup
#define loop vc_lora_phase6_vehicle_loop
#include "vc_lora_phase6_bridge.hpp"
#undef loop
#undef setup

#include "vc_lora_vehicle_diag.hpp"

namespace {

constexpr std::uint64_t kHeartbeatIntervalMs = 1000U;
constexpr std::array<std::uint8_t, 21U> kDiagnosticHeartbeat{
    0xFD, 0x09, 0x00, 0x00, 0x00, 0xFF, 0xBE,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x06, 0x08, 0x00, 0x04, 0x03, 0x3D, 0x48};

void service_pixhawk_heartbeat_ab() {
  static std::uint64_t next_heartbeat_ms = 0U;
  static std::size_t heartbeat_offset = 0U;
  const std::uint64_t now_ms =
      static_cast<std::uint64_t>(esp_timer_get_time()) / 1000U;
  if (heartbeat_offset == 0U && now_ms < next_heartbeat_ms) {
    return;
  }

  const int available =
      vc_lora_phase6_firmware::pixhawk_serial.availableForWrite();
  if (available <= 0) {
    return;
  }
  const std::size_t remaining =
      kDiagnosticHeartbeat.size() - heartbeat_offset;
  const std::size_t requested = std::min<std::size_t>(
      remaining, static_cast<std::size_t>(available));
  const std::size_t written =
      vc_lora_phase6_firmware::pixhawk_serial.write(
      kDiagnosticHeartbeat.data() + heartbeat_offset, requested);
  if (written > requested) {
    return;
  }
  vc_lora_vehicle_diag_observer::observe_pixhawk_write(
      kDiagnosticHeartbeat.data() + heartbeat_offset, written, now_ms);
  heartbeat_offset += written;
  if (heartbeat_offset == kDiagnosticHeartbeat.size()) {
    heartbeat_offset = 0U;
    next_heartbeat_ms = now_ms + kHeartbeatIntervalMs;
  }
}

}  // namespace

void setup() {
  vc_lora_phase6_vehicle_setup();
  vc_lora_vehicle_diag::begin();
}

void loop() {
  vc_lora_phase6_vehicle_loop();
  service_pixhawk_heartbeat_ab();
  vc_lora_vehicle_diag::service();
}
