# Vehicle uplink diagnostic firmware

This sketch is an observational build of the Phase 6 Vehicle firmware. It
keeps the production pins, UART rates, E220 profile, TDD protocol and bridge
implementation unchanged.

This revision is rebased on canonical bridge SHA-256
`097714F3365A3C7CB6C14C8AD0DED41C35A8D2B9BC9EF2393874132FE9EDA3FE`.
Together with the matching Ground diagnostic it supports one continuously
open measurement from Ground USB #20 through Vehicle RF quarantine, explicit
UL_DONE, atomic commit, D6 and the matching D7 PARAM_VALUE response.

- Flash `vc_lora_vehicle_diag_v2_stable_xiao_esp32s3.ino` to the Vehicle XIAO
  and the matching stable-v2 Ground diagnostic to the Ground XIAO for this
  two-ended measurement.
- Select `XIAO ESP32S3`, `USB Mode: Hardware CDC and JTAG`, and
  `USB CDC On Boot: Enabled` in Arduino IDE before compiling/uploading.
- Vehicle USB COM uses 115200 baud and emits no periodic text.
- Send the exact ASCII command `VCSTAT?` followed by LF to request one atomic
  three-line snapshot (`VCSTAT1`, `VCSTAT2`, `VCSTAT3`).
- The command is read only. There are no reset, injection or configuration
  commands.

As on Ground, ESP32-S3 Hardware CDC state is not proof that a Windows process
owns an open COM handle. The Vehicle diagnostic USB is only the query/report
channel; stage conclusions must come from counter deltas in one capture, not
from the mere continued presence of the COM device.

Do not use separate invocations of `tools/vehicle_diag_query.ps1` or
`tools/ground_diag_query.ps1` for the decisive run: each invocation reopens a
COM handle. Use `tools/run_dual_diag_continuous_hil.ps1`, which owns both
handles from boot-prefix capture through every baseline and post snapshot.
Restore the production firmware on both bridges after the fault has been
isolated.

Run the collector's `-SelfTest` before HIL. The complete command line,
validated 32-byte fixture contract, M0/R0/M1 timeline and immutable raw
evidence layout are documented in the matching Ground diagnostic README.

## Recommended measurement

1. Close Arduino Serial Monitor and Mission Planner so one collector can take
   exclusive ownership of Vehicle COM3 and Ground COM6.
2. Power off both XIAO/E220 assemblies, start the collector, and reconnect
   power only after it prints `POWER_OFF_CONFIRMED_WAITING_FOR_PORTS` following
   the mandatory 5000 ms continuous-absence check.
3. Let the collector open both freshly enumerated ports once and preserve the
   complete boot prefix. Keep the same two handles open for the entire run.
4. Collect correlated Vehicle and Ground baseline snapshots, settle, and send
   exactly one `PARAM_REQUEST_READ` for `SERIAL1_BAUD` on the Ground handle.
5. Wait for the exact matching `PARAM_VALUE`, then collect Ground and Vehicle
   post snapshots on those same handles before either port is closed.
6. Compare cumulative counter deltas. Do not discard the initial 256 bytes or
   reset either firmware parser; parser resets are analysis-only boundaries in
   the saved evidence. The collector fsyncs `vehicle_rx.raw.bin`,
   `ground_rx.raw.bin`, and `capture_footer.json` before closing either handle;
   its final `PASS` also requires a clean pre-R0 causal gate, canonical
   all-message parser CRC/length/noise integrity, strictly newer post-snapshot times,
   full heartbeat continuity, zero invalid/drop/overflow/backlog diagnostic
   deltas, and every Ground/Vehicle strict target-stage delta documented by the
   Ground README.

Every `VCSTAT1/2/3` line carries the same `q` (query sequence) and `ms`
(device capture time). The collector rejects stale or mixed snapshots.
This build emits Vehicle diagnostic schema `v=6`.

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
- `trseq/trsys/trcomp/tridx/trts/trtc/trlen`: the MAVLink sequence/source,
  requested parameter index, target tuple, and exact byte length of the first
  latched #20. `td6ex` counts full byte-for-byte matches between that RF #20
  and the complete frame accepted by D6. The D6 event records the controller
  state observed at the actual UART write, which may be later than the
  ReturnGuard commit.
- `d7b`, `d7f`, `d722`, `d777`: bytes/frames and PARAM_VALUE/COMMAND_ACK seen
  on D7 (Pixhawk TX to XIAO RX).
- `td722` and `td7mi` count only the strict expected `SERIAL1_BAUD` response
  after the latched #20 has reached D6 byte-for-byte; `td7ms` is that target's
  first observed timestamp. A request index of -1 is treated as the ID-request
  sentinel, not as proof that an unrelated #22 with index 65535 is a match.
- `pvok`: cumulative D7 PARAM_VALUE payloads decoded after CRC validation.
  `pvs1`: cumulative strict expected responses whose full 16-byte `param_id`
  is exactly `SERIAL1_BAUD` plus NUL padding, source is 1/1, value bits are
  `42640000`, count is nonzero, index is 65535 and type is 6. Unlike the
  last-value fields, `pvs1` persists when a later `STAT_RUNTIME` response
  arrives, and that periodic response cannot advance `td722`, `td7mi` or
  `td7ms` even if all of its non-ID tuple fields match.
- `pvs1val`, `pvs1cnt`, `pvs1idx`, `pvs1type`, `pvs1seq`, `pvs1sys`,
  `pvs1comp`, and `pvs1ms` preserve the most recent exact `SERIAL1_BAUD`
  tuple independently of the generic last-value fields. For the requested
  57.0 response, `pvs1val` is `42640000`; the expected source is system 1,
  component 1.
- `pvid`, `pvval`, `pvcnt`, `pvidx`, `pvtype`: the most recently decoded
  PARAM_VALUE ID, value, parameter count/index and type. `pvval` is the
  locale-independent IEEE754 value bits as exactly eight uppercase hex digits
  (`42640000` means 57.0). `pvid` is held in a fixed 17-byte POD buffer
  (16 wire bytes plus a forced NUL terminator).
- `pvseq`, `pvsys`, `pvcomp`, `pvms`: MAVLink sequence/system/component and
  local receive time of that most recent PARAM_VALUE. These generic last-value
  fields are overwritten by every later CRC-valid PARAM_VALUE.
- `pvbad`, `pvov`: payload revalidation failures and saturated diagnostic
  counter overflow events. `d7iv` and `d7pb` expose the D7 parser invalid-frame
  total and its buffered-byte count at the same atomic snapshot.
- `tpf`, `ttk`, `tei`: tri-state atomic-commit observations (0 unseen,
  1 failed, 2 succeeded). A passing continuous run requires each to move from
  baseline 0 to post value 2, with `tcb` increasing by exactly 32 and `tcf`
  by exactly one frame. `tar` must remain zero. `tto` is observational and is
  not a zero gate because later empty uplink windows can increase it after a
  successful commit.
- `cr` suffixes count MAVLink CRC errors; `out` is the production receive-
  window drop counter; `r`/`f` are bridge-ready/runtime-fail-closed flags.

Heartbeat/scheduler correlation extension:

- `sqf/sqb/sact` snapshot total scheduler occupancy and active state;
  `pgq/pga` are generic PARAM_VALUE queue frames/active, while `prq/ptq` are
  pending proxy requests and target-priority lane occupancy.
- `hbp/hbta/hbac/hbpr/hbseen` snapshot the heartbeat lane. `hgd` counts
  uplink Grants deferred to protect a pending heartbeat deadline, and `hdm`
  counts defer decisions made only after that deadline had already expired.
  The following `s*` fields retain the complete scheduler diagnostics without
  changing its production priority or timing.
- `d7he/d7ho/d7hv` are primary source-1/1 D7 heartbeat
  event/observation/>2500-ms violation counters. `d7hl*`, `d7hm*`, and
  `d7hv*` retain latest, maximum, and latest-violation events with TDD/AUX,
  scheduler, generic PARAM, target-lane, and heartbeat state.

The report buffer is 10240 bytes. The conservative source contract proves a
7997-byte worst case, while a 10239-byte valid report drains in 160 64-byte
calls (16.0 s at the 100-ms service cadence), within the 20-s query contract.

Core parity plan: `core/include/vc_lora` and `core/src` remain authoritative.
After any core change, run `tools/sync_arduino_sketch_core.ps1`, update both
stable diagnostic core copies from those same canonical files, and require
the Stage-v2 parity and scheduler sync contracts to pass before packaging.
Diagnostic-only D7 observation must remain removable by preprocessor
normalization, leaving the canonical Phase-6 bridge behavior unchanged.

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
