// VC LoRa Phase 6 Ground cycle diagnostic firmware for XIAO ESP32-S3.
//
// Normal USB CDC traffic remains the production Mission Planner MAVLink
// stream.  The exact ASCII VCGSTAT?<LF> command is intercepted at a MAVLink
// parser boundary and is the only operation which enables diagnostic output.

#define VC_LORA_PHASE6_GROUND 1
#define VC_LORA_PHASE6_GROUND_DIAGNOSTICS 1

#include <Arduino.h>
#include <Preferences.h>
#include <esp_timer.h>

#include "VC_LoRa_Core.h"
#include "vc_lora_ground_diag_observer.hpp"

#define setup vc_lora_phase6_ground_setup
#define loop vc_lora_phase6_ground_loop
#include "vc_lora_phase6_bridge.hpp"
#undef loop
#undef setup

#include "vc_lora_ground_diag.hpp"

void setup() {
  vc_lora_phase6_ground_setup();
  vc_lora_ground_diag::begin();
}

void loop() {
  vc_lora_phase6_ground_loop();
  vc_lora_ground_diag::service();
}
