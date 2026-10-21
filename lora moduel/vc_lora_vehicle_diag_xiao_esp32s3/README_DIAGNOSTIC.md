# Vehicle uplink diagnostic firmware

This sketch is an observational build of the Phase 6 Vehicle firmware. It
keeps the production pins, UART rates, E220 profile, TDD protocol and bridge
implementation unchanged.

- Flash only `vc_lora_vehicle_diag_xiao_esp32s3.ino` to the Vehicle XIAO.
- Leave the Ground XIAO on the production firmware.
- Select `XIAO ESP32S3`, `USB Mode: Hardware CDC and JTAG`, and
  `USB CDC On Boot: Enabled` in Arduino IDE before compiling/uploading.
- Vehicle USB COM uses 115200 baud and emits no periodic text.
- Send the exact ASCII command `VCSTAT?` followed by LF to request one atomic
  three-line snapshot (`VCSTAT1`, `VCSTAT2`, `VCSTAT3`).
- The command is read only. There are no reset, injection or configuration
  commands.

Use `tools/vehicle_diag_query.ps1` from the repository root to collect an
immutable JSON/text/binary evidence bundle. Restore the production Vehicle
firmware after the uplink fault has been isolated.

## Recommended measurement

1. Close Arduino Serial Monitor on Vehicle COM3 and Mission Planner on Ground
   COM6.
2. Run `tools/vehicle_diag_query.ps1` once to save the baseline counters.
3. Start Mission Planner on COM6/57600 and request `ARMING_CHECK` once (or run
   the existing PARAM_REQUEST_READ probe), then wait 10 seconds and close it.
4. Run `tools/vehicle_diag_query.ps1` again. Compare the second JSON values
   with the baseline; all counters are cumulative since boot.

Every `VCSTAT1/2/3` line carries the same `q` (query sequence) and `ms`
(device capture time). The collector rejects stale or mixed snapshots.

Important fields:

- `gr`, `done`, `idle`: Vehicle GRANT sent and Ground DONE/IDLE received.
- `raw`, `rwi`, `rwo`: E220 UART bytes received in total, inside the Vehicle
  receive window, and outside it.
- `rib`, `rif`, `r20`, `r23`, `r76`: in-window application bytes, valid
  frames, PARAM_REQUEST_READ, PARAM_SET and COMMAND_LONG seen after demux.
- `rob`, `rof`, `o20`, `o23`, `o76`: the same measurements outside the valid
  receive window.
- `d6b`, `d6f`, `d620`, `d623`, `d676`: bytes/frames and request types the
  ESP32 UART driver accepted for D6 (XIAO TX to Pixhawk RX). This proves the
  driver boundary, not the electrical waveform at the pin.
- `d7b`, `d7f`, `d722`, `d777`: bytes/frames and PARAM_VALUE/COMMAND_ACK seen
  on D7 (Pixhawk TX to XIAO RX).
- `cr` suffixes count MAVLink CRC errors; `out` is the production receive-
  window drop counter; `r`/`f` are bridge-ready/runtime-fail-closed flags.

Numeric state values:

- `st` (Vehicle TDD): 0 DownlinkSend, 1 DownlinkDrain, 2 SendUlGrant,
  3 GrantDrain, 4 UplinkGuard, 5 UplinkReceive, 6 ReturnGuard.
- `ss` (startup): 0 AwaitingChecks, 1 Ready, 2 FailClosed. `sf`: 0 None,
  1 IdentityNotPersisted, 2 ProfileReadInvalid, 3 ProfileMismatch.
- `ew` (E220 write): 0 WaitingForStableHigh, 1 Ready,
  2 AwaitingWriteResult, 3 AwaitingAuxLow, 4 AwaitingAuxHigh, 5 FailClosed.
  `ef`: 0 None, 1 InvalidWriteSize, 2 UnexpectedWriteResult,
  3 PartialWrite, 4 AuxDidNotGoLow (compatibility code),
  5 AuxDidNotReturnHigh, 6 NonMonotonicTime.

Delta interpretation:

- `gr` rises but `raw/rib` and `done/idle` do not: Ground did not answer the
  grant or the Ground-to-Vehicle RF path failed.
- `rwo/rob` rises but `rib` does not: the uplink arrived outside the TDD
  receive window.
- `r20` rises but `d620` does not: Vehicle validation/egress did not reach the
  Pixhawk UART driver.
- `d620` rises but `d722` does not: investigate D6 electrical wiring and the
  Pixhawk TELEM RX protocol/baud configuration.
- `d722` rises but Ground COM6 sees no PARAM_VALUE: investigate Vehicle
  scheduler/downlink RF/Ground USB delivery.
