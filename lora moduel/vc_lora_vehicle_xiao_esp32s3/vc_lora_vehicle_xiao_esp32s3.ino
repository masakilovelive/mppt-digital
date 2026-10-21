// VC LoRa Phase 6 vehicle firmware for XIAO ESP32-S3.
// Fixed wiring: E220 D0/D1/D2/D3/D8; Pixhawk TX D6 / RX D7.
// The shared adapter binds the same deterministic core used by host tests.

#define VC_LORA_PHASE6_VEHICLE 1
#include "VC_LoRa_Core.h"
#include "vc_lora_phase6_bridge.hpp"
