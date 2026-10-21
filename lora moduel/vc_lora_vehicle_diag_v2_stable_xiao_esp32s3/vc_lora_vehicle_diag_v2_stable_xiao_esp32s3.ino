// VC LoRa Phase 6 Vehicle uplink diagnostic firmware for XIAO ESP32-S3.
//
// The production transport is included byte-for-byte.  The only additional
// behaviour is a command-driven, USB-CDC-only status observer on Vehicle COM3.
// No diagnostic bytes are written to the E220 or Pixhawk UARTs.

#define VC_LORA_PHASE6_VEHICLE 1
#define VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS 1

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

void setup() {
  vc_lora_phase6_vehicle_setup();
  vc_lora_vehicle_diag::begin();
}

void loop() {
  vc_lora_phase6_vehicle_loop();
  vc_lora_vehicle_diag::service();
}
