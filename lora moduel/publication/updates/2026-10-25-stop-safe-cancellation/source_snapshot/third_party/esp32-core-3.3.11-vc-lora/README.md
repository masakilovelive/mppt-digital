# VC LoRa ESP32 3.3.11 HWCDC patch

The Phase 6 Ground production path uses two result-bearing HWCDC extensions:
`txLossEpoch()` and `flushTxComplete(timeout_ms, expected_loss_epoch)`.
The canonical patched `HWCDC.cpp` and `HWCDC.h` are stored under
`cores/esp32/` so a production build does not depend on unrecorded files in a
developer's Arduino installation.

The patch is accepted only on the exact upstream ESP32 Arduino Core 3.3.11
inputs below:

- `HWCDC.cpp`: `C5ED5FDD05AA0DF9B74D390812643599223F96B459256718D0AD328AEABA6A8A`
- `HWCDC.h`: `9A7D1672193E8F512DCDB020739771D85E98EAAEF090BD080564DDA0FBBF7022`

Install or verify it with:

```powershell
.\tools\install_patched_esp32_hwcdc.ps1
.\tools\install_patched_esp32_hwcdc.ps1 -CheckOnly
```

The installer refuses an unknown Core version or source hash. It accepts only
the exact upstream pair or the recorded preceding canonical pair, preserves or
recovers a complete hash-verified upstream backup pair, copies the canonical
pair, and verifies both resulting SHA-256 values. `compile_arduino.ps1` independently
requires the installed pair to match this canonical pair byte for byte.
Before any upload, run `tools/verify_phase6_firmware_manifest.ps1`; it rejects
stale sources, Core files, contract evidence, binaries, and legacy
`*_flashed.bin` selections.

The retained Espressif source files remain under their original Apache-2.0
license headers.

## Diagnostic read-only CDC bootstrap (2026-10-03)

The R19 diagnostic build adds a third, macro-gated HWCDC extension:
`writeTxBootstrapFrameChecked()`. It is compiled only when
`VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS=1`; the normal `writeTxChecked()` and
`operator bool()` product paths are unchanged.

Native ESP32-S3 HWCDC does not make its cached `connected` state true until
the host has completed an IN transfer or supplied OUT data. A strictly
read-only capture can therefore deadlock if firmware requires that cached
state before publishing its first diagnostic frame. The first bootstrap
extension broke that model-level cold-start cycle. It admitted one exact
63-byte MAVLink frame all-or-zero into an empty software ring while holding
the TX publication mutex, then left the existing ISR to publish at most 32
bytes per FIFO operation.

Physical run `20261003T083253345Z-5fc0094a` still returned zero bytes on both
roles, so cached connection alone was not a sufficient explanation. The
diagnostic-only path does not hard-gate bootstrap enqueue on
`usb_serial_jtag_is_connected()` or `Serial.isPlugged()`. It still rechecks
loss epoch, BUS_RESET, quarantine, ring/stash/FIFO emptiness, interrupt
initialization, and debug-writer exclusion. The later empty-FIFO/ZLP revision
also returned zero bytes in live testing; it is retained below as historical
evidence rather than the current bootstrap implementation.

Canonical patched hashes are:

- `HWCDC.cpp`: `FDD06A57D8B99B20C9A1484E0257BDE82D06DCE97D3C001FA61CD3C71F7F2382`
- `HWCDC.h`: `1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC`

The guarded installer recognizes each recorded preceding VC LoRa pair as a
migration source. When such a pair has no recorded upstream backups, it restores
only the two uniquely named, hash-verified 3.3.11 entries from an explicit or
locally cached official core ZIP before installing the new canonical pair.
Unknown, mixed, incomplete-backup, wrong-version, or wrong-hash states are
rejected. `-CheckOnly` never changes files.

`tests/arduino_compile/check_hwcdc_tx_integrity_contract.ps1` verifies 35
properties, including eight bootstrap-specific publication, reset, and writer
serialization assertions. Diagnostic candidate manifests must seal this
summary and require those eight assertions plus the connected payload-pickup
witness; a missing, false, or tampered assertion makes verification fail.

The candidate preceding the 2026-10-03 false-SOF/ZLP revision did not contain
that change and cannot be reused as its evidence. At that time, the revised source passed the
targeted false-SOF tests, normal 301/301, fresh ASan/UBSan 301/301, HWCDC
semantic 33/33, installer check-only, and both role compiles. It is sealed as
historical diagnostic artifact `20261003T091702033Z-e3aa5200`; the independent
verifier passes. Its manifest SHA-256 is
`0836246D655F1F03CF391DC0C7BC1D74C858A4F508ED12F5F33842825318515A`
and final-seal SHA-256 is
`A2D1433442E9A6BD4D0A242E4F491C46F9898E405FB3FF84E1A1C8DB40254B71`.

The artifact package was built and sealed offline, so its manifest correctly
records no hardware interaction, zero opened COM ports, and no flash for that
build step. A separate one-time HIL operation subsequently installed it and
captured COM3/COM6 read-only for 40 seconds as run
`20261003T094504443Z-32368ca4`. Both roles still produced zero raw bytes, zero
frames, and zero R19A/R19F. The patch therefore passes its offline contract but
is not a sufficient physical correction for the live zero-byte boundary.

The operation unconditionally restored both devices to accepted R18 on the
first attempt with readback and re-enumeration PASS. Acceptance and deployment
authorization remain false, and that one-time authorization is consumed. The
next diagnostic revision must isolate common early boot, publisher, ring/FIFO,
and USB IN stages using evidence that does not depend on the same CDC output;
this artifact must not simply be reflashed as a repeat attempt.

## Diagnostic direct-payload bootstrap (2026-10-10)

Live runtime-stage evidence from both roles reached `WriteAccepted` and then
latched `FlushFailed`, while each 40-second CDC capture remained at zero raw
bytes. An offline software liveness gap consistent with that boundary was
identified: the complete 63-byte frame was accepted into the software ring,
but its first transfer depended on one empty-FIFO/ZLP request producing a later
`IN_EMPTY` interrupt.

The current diagnostic-only implementation now removes at most 32 bytes from
the fenced BYTEBUF and primes those real payload bytes into the hardware FIFO.
It samples BUS_RESET immediately before and after the FIFO write, retains a
short-write suffix in the existing fixed 64-byte stash, marks
`tx_payload_in_flight`, then enables `IN_EMPTY` and publishes with `wr_done`.
The remaining bytes stay in the ring and are drained by the existing ISR only
after the host picks up that first payload packet.

Reset, epoch, quarantine, debug-writer exclusion, exact 63-byte admission, and
all-or-zero caller acceptance remain fail-closed. A zero FIFO write or a reset
racing the write returns the outstanding BYTEBUF item, discards the ambiguous
software stream, and reports zero accepted bytes; a possibly written FIFO is
quarantined until a later clean bus reset. The ordinary product
`writeTxChecked()` path and `flushTxComplete()` success predicate are unchanged.

Offline RED/GREEN evidence is stored under
`runs/validation/R19-HWCDC-DIRECT-PAYLOAD-PRIME-OFFLINE-001`. This correction
has not yet been flashed or proved on physical CDC, so it does not authorize
R19 acceptance or deployment.

The current offline-only diagnostic candidate is
`20261010T090523384Z-93c6076d`. Its semantic summary contains 35 passing
checks and its manifest requires the exact nine-check diagnostic subset,
including `diagnostic_bootstrap_payload_primes_fifo_before_flush`. Vehicle and
Ground were compiled in that order; the independent verifier passed. Manifest
SHA-256 is
`C2E06148A0F274FE13D43FA2635A831BA06F5A7145A714C81A28B04B03ABBDCD`
and final-seal SHA-256 is
`390ACB1A5A0FBC64F194A4F9B1E63144E3F16B0C80321C6999B94603E7E78459`.
The package records zero hardware interaction and leaves the accepted R18
default sketches unchanged.
