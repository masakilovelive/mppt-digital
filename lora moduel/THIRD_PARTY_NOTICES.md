# Third-party notices

## Modified Espressif HWCDC sources

- Upstream: [Espressif Arduino-ESP32](https://github.com/espressif/arduino-esp32), ESP32 Arduino Core 3.3.11.
- Files: `third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDC.cpp` and `HWCDC.h`.
- Copyright 2015–2026 Espressif Systems (Shanghai) PTE LTD, as retained in each source header.
- License: Apache License, Version 2.0. The complete license is included in [third_party/licenses/Apache-2.0.txt](third_party/licenses/Apache-2.0.txt).

**These files have been modified for VC LoRa; they are not unmodified upstream files.**
Project changes include result-bearing write/completion contracts, loss-epoch accounting,
publication/interrupt synchronization, and macro-gated R19 bootstrap and diagnostic hooks.
The accompanying `HWCDCR19Diagnostic.h` provides project-specific diagnostic definitions.
See [the patch README](third_party/esp32-core-3.3.11-vc-lora/README.md) and the retained source for details.
Original source bytes are preserved in this publication so that existing hashes and diagnostic references remain meaningful.

The Apache-2.0 license text was copied from the license supplied with the locally installed official ESP32 Arduino Core 3.3.11.
No BLE library code or its separate component-specific notice is redistributed by this snapshot.
This notice does not grant a new blanket license to the VC LoRa project or the containing repository.

## Protocol fixtures and local tools

MAVLink fixture data and local DLL hash references are retained as test provenance.
No Mission Planner DLL, Windows driver distribution, OpenOCD executable, compiler, SDK installation, or third-party API credential is included.
External tools must be obtained and used under their respective licenses.
