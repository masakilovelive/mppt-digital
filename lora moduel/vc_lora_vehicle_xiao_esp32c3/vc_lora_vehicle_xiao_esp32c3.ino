// VC_LoRa vehicle-side sketch.
// Write this to the XIAO ESP32-C3 connected to Pixhawk TELEM.

#define VC_LORA_ROLE VC_LORA_ROLE_VEHICLE
// Change to 57600 only after both E220 modules have been configured to 57600.
#define VC_LORA_E220_UART_BAUD 9600
#include "../vc_lora_bridge_xiao_esp32c3/vc_lora_bridge_xiao_esp32c3.ino"
