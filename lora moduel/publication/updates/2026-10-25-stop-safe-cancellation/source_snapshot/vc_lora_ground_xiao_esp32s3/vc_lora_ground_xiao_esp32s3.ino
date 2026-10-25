// VC LoRa Phase 6 ground firmware for XIAO ESP32-S3.
// Mission Planner uses this USB CDC port at 57600 baud. No debug text is
// emitted on that MAVLink stream.

#define VC_LORA_PHASE6_GROUND 1
#include "VC_LoRa_Core.h"
#include "vc_lora_phase6_bridge.hpp"
