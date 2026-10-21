// VC_LoRa ground-side USB self-test sketch.
// Write this only when checking that the PC COM port and Route Monitor can receive MAVLink.

#define VC_LORA_ROLE VC_LORA_ROLE_GROUND
#define VC_LORA_GROUND_USB_SELFTEST_HEARTBEAT 1
#include "../vc_lora_bridge_xiao_esp32c3/vc_lora_bridge_xiao_esp32c3.ino"
