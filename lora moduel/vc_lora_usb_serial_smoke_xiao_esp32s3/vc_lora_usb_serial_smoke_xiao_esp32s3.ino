/*
  XIAO ESP32-S3 USB Serial smoke test.

  Use this before E220 diagnostics when the Arduino Serial Monitor is blank.
*/

#include <Arduino.h>

static constexpr uint32_t USB_BAUD = 115200;
static uint32_t boot_ms = 0;
static uint32_t count = 0;

void setup() {
  Serial.begin(USB_BAUD);
  delay(1000);
  boot_ms = millis();

  Serial.println();
  Serial.println("=== XIAO ESP32-S3 USB Serial smoke test ===");
  Serial.println("If this text is visible, USB Serial and COM selection are OK.");
  Serial.println("Baud: 115200");
}

void loop() {
  Serial.print("[USB] alive count=");
  Serial.print(count++);
  Serial.print(" uptime_ms=");
  Serial.println(millis() - boot_ms);
  delay(1000);
}
