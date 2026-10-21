# Ground cycle diagnostic firmware

This is an additive XIAO ESP32-S3 Ground diagnostic build. The copied core is
byte-identical to `core/`, and the copied Phase 6 adapter differs from the
canonical adapter only in `VC_LORA_PHASE6_GROUND_DIAGNOSTICS` blocks.
Production Vehicle and Ground sketches are not modified.

This revision is rebased on canonical bridge SHA-256
`097714F3365A3C7CB6C14C8AD0DED41C35A8D2B9BC9EF2393874132FE9EDA3FE`.
It is intended for a single continuously open capture: request a baseline,
send one `PARAM_REQUEST_READ`, then request later snapshots without resetting
either bridge. Counters and the first runtime-stop record remain cumulative
for the boot.

Normal COM6 traffic is the production 57600-bps MAVLink stream. No periodic
text is emitted. At a MAVLink parser boundary, the exact ASCII command
`VCGSTAT?<LF>` is consumed by the observer and never reaches the RF ingress.
The query does not pause egress immediately. In a running bridge, normal
MAVLink egress first drains to an empty/no-active-write frame boundary; only
then are three correlated `GCSTAT1/2/3` lines written and egress held until the
report completes. A startup-stopped or runtime-fail-closed bridge instead uses
an independent exact-query matcher, discards every other received byte, and
can format the report even when the TDD state froze outside `WaitGrant`.

For the decisive HIL, do not invoke `ground_diag_query.ps1` separately for
baseline and post snapshots: that script opens and closes COM6 per invocation
and invalidates the continuous-open premise. Use
`tools/run_dual_diag_continuous_hil.ps1`; it must own COM6 from the initial
boot-prefix capture through baseline, the one exact #20 request, the matching
#22 wait and every post snapshot. It also keeps the Vehicle diagnostic COM
handle open for its baseline/post `VCSTAT?` snapshots during the same run.

Run the offline contract first; it returns before port enumeration or
`SerialPort` construction:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\tools\run_dual_diag_continuous_hil.ps1 -SelfTest
```

For HIL, supply the exact validated 32-byte MAVLink2
`PARAM_REQUEST_READ(SERIAL1_BAUD, index=-1, target=1/1)` fixture and a new
evidence directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\tools\run_dual_diag_continuous_hil.ps1 `
  -VehiclePort COM3 -VehicleBaud 115200 `
  -GroundPort COM6 -GroundBaud 57600 `
  -FixturePath .\path\to\serial1_baud_request_32.bin `
  -OutputDirectory .\runs\hil\my-new-run
```

Start the runner while both XIAO/E220 assemblies are powered off. By default it
requires COM3 and COM6 to remain absent continuously for at least 5000 ms. Do
not reconnect power until it prints
`POWER_OFF_CONFIRMED_WAITING_FOR_PORTS`; it then waits for both fresh port
enumerations and opens each exactly once. This binds the capture to one clean
power cycle. The runner preserves the raw boot prefix and every later byte and
refuses an existing output directory.
Its fixed sequence is 0--3 s boot-prefix capture, 3--15 s live observation,
Vehicle/Ground baselines, 3 s recovery, then M0. One MAVLink analysis state is
kept from M0 through M1: it includes a 5 s heartbeat lead, R0 (the exact #20
final-write timestamp), the exact #22 wait of at most 20 s, and 10 s idle.
At M1 the runner stops only that analysis parser, requests Ground post first
(including the fail-stop collector), then Vehicle post. It writes
`vehicle_rx.raw.bin`, `ground_rx.raw.bin`, event/timeline/ASCII evidence and
`capture_footer.json` with write-through plus `Flush(true)` while both handles
remain open; only after the footer fsync does it close them. Parser resets never
alter the raw files or their separately saved initial 256-byte prefixes.

`PASS` is deliberately strict. Both baseline reports must be complete and show
ready/no-fail state or the runner suppresses #20 entirely. After the 5 s lead,
the R0 causal gate also requires a clean parser boundary, no prior strict
target since M0, and no parser-error delta; otherwise it suppresses #20.
From M0 through M1, source 1/1 HEARTBEAT must have at least two frames and
every first, consecutive, and tail boundary gap must be at most 2500 ms. The
runner loads and hashes the authoritative 80-message table from canonical
`core/src/mavlink_frame.cpp`; unsupported IDs/flags, invalid payload lengths,
bad CRCs, non-frame noise, and an M1 partial candidate must all remain zero.
Exactly one strict `SERIAL1_BAUD` #22 must occur after R0 within 20 s and none
may occur in the M0-to-R0 causal window. Post snapshots must have strictly
newer `ms`, retain the same nonzero boot IDs, and prove exact +1 deltas through
the Ground `uv20/upfwd/uqf/ufdq/utx/dtx` stages with `upb` exactly 32 bytes,
Vehicle
`r20/d620/td6ex/pvs1/td7mi`, Vehicle atomic commit
`tpf/ttk/tei` transitions from 0 to success value 2 with `tcb=32` and
`tcf=1`, and Ground strict
`s1rx/s1ok/s1q/s1ega/s1egc` direct path. All listed invalid, drop, overflow,
ordered-backlog, and pending-buffer diagnostics must have zero delta (and
current queue/backlog fields remain zero), while fail/runtime-stop remain
zero. `summary.json` records `first_missing` for the first failed stage.
The zero-delta set deliberately excludes `dlf`, because the expected valid
#22 advances the downlink validated-frame counter. It also excludes Vehicle
`tto`, which may continue to observe later empty uplink windows after the
successful atomic commit.

Important fields:

- `GCSTAT1`: `gr`, `dup`, `fut`, `stcy`, `stss` classify received grants;
  `raw` and `ctl` separate raw E220 activity from decoded control messages;
  `st/sid/cy`, `aux/rb/pa`, and `fail/ew/ef` capture controller and runtime
  state. `cdcp` is the current Arduino HWCDC connectivity predicate;
  `cdcs/cdct/cdcup/cdcdn/cdcms` show samples and transitions. `rse` is the
  number of runtime-stop latch calls, while `rsr/rsms/rsst/rscy/rsrdy`
  preserve the first observed reason, time, TDD state/cycle and prior-ready
  value.
- `GCSTAT2`: `ubi/uvf/u20`, `uqf/uqfb/uqb`, and `udf/udb/uoe` cover USB
  ingress validation, PARAM_REQUEST_READ, queueing, and loss. `uv20/u21`
  identify CRC-valid direct #20 and list #21 inputs; `upcon/upfwd/upinv`
  identify whether the parameter proxy consumed, forwarded, or rejected the
  request. `rfv/rf20/rf22` count complete CRC-valid RF frames before Ground
  USB admission; `rfdc/rfq/rfd/rfbq/rfpc/rfinv` distinguish disconnected
  rejection, endpoint queueing/drop, ordered-backlog queueing, proxy consume
  and invalid preclassification. `obf/obb` are the current ordered-backlog
  frames/bytes; `obfq/obfr/obif/obof/obdf/obdb` retain its cumulative
  diagnostics. `epc/epdis/epwait/epprog/epinv` classify every
  USB egress pump, and `eplqb/eplqa/eplcb/eplca` retain its last queued-byte
  and committed-byte before/after values. `s1rx` and `s1ok` count only the
  same strict expected `SERIAL1_BAUD` response: exact padded 16-byte ID,
  source 1/1, value bits `42640000`, nonzero count, index 65535 and type 6.
  `s1q/s1bq/s1dc/s1d/s1pc/s1iv` apply that identical predicate to each
  disposition. `s1ega/s1egc/s1egp` tie only that same target's endpoint
  admission to its
  cumulative physical USB commit goal. `s1val/s1cnt/s1idx/s1ty/s1seq/s1sys`,
  `s1cmp/s1ms` retain the target tuple even after later `STAT_RUNTIME` frames.
  A `STAT_RUNTIME` frame cannot advance any `s1*` stage even if every field
  except `param_id` happens to match the target.
- `GCSTAT3`: `utx/upb`, `itx/dtx`, `ar/ex/ins`, action-issue counts, and
  state/raw/control histograms expose each Ground uplink transaction.
  `pst/pact/pidx/pcnt/padm/pdeq/ptok` freeze the proxy transaction identity;
  `front/wire/deq/data/done/idle/actual` localize its queued #20 through the
  explicit-DONE RF stages. `pgen/ptx/pwto/psfail/prej` and the per-terminal
  counters expose generation, timeout, watchdog/failure, and rejection paths.
  `pnq` counts all native-stream PARAM_VALUE quarantines; `ppre` is its
  causal precommit subset while no response can yet belong to the current
  #21/#20 because explicit UL_DONE has not completed. A clean full-list run
  may have `pnq>0` only when its complete delta is accounted for by `ppre`,
  while `ppois=0` and the recovery latch remains idle.
  `dacc/dnak`, `xacc/xnak` and `iacc/inak` are E220 physical UART acceptance
  results for DATA, UL_DONE and UL_IDLE. `pwe/pwr/pwtok/pwms` retain the most
  recent proxy admission-watchdog event and numeric reason.

`cdcp/cdcs/cdct/cdcup/cdcdn/cdcms` report HWCDC endpoint readiness
(`bool(Serial)`), not physical USB presence or an open Windows COM handle.
<!-- Obsolete pre-host-presence wording retained only for legacy encoding: 
COM handle. Therefore `cdcp=1` must not be interpreted as “COM is open”, and
-->
`usjp/usjps/usjpt/usjpup/usjpdn/usjpms` independently report USB SOF/host
presence from raw `Serial.isPlugged()`. A raw loss pauses physical writes
immediately, but admission, pacer disconnect (`hpdis`), parser reset, and
whole-frame discard change only after raw loss remains continuous for 50 ms.
Recovery before 50 ms retains the ordered frames; confirmed reconnect is
immediate. Boot-time raw absence has no grace period. Thus raw `usjp*`
transitions may rise without `hpdis` or discard growth. `cdcp=0,usjp=1` also
pauses writes and retains ordered frames.
Use the continuous capture plus `ep*` queued/committed deltas to prove actual
host-facing byte progress.

Runtime-stop reason values (`rsr`) are: 0 unclassified, 1 USB egress invalid,
2 ordered-downlink invariant, 3 heartbeat-pacer invariant, 4 proxy admission
abandoned, 5 proxy admission marking failed, 6 generated request ingress
rejected, 7 Ground ingress fault, 8 E220 write fault, 9 TDD controller fault;
255 is the nonzero defensive fallback for any future unarmed callsite. The
source contract currently verifies explicit family coverage at all 36
Ground-reachable runtime fail-stop calls.
Proxy-watchdog reason values (`pwr`) are: 0 none, 1 admission abandoned,
2 admission/dequeue marking failed, 3 generated request ingress rejected.

Compare two reports by subtracting monotonic counters. A healthy empty cycle
increments `gr`, `itx`, and `aci` together. If `raw` rises without `ctl`, the
failure is framing/demux. If `ctl/cgr` rises but `gr` does not, the disposition
fields identify duplicate, future, or stale grants. If `gr` rises without
`itx+dtx`, use `ar/ex/ins`, `aux/rb/pa`, and the state-entry counters to locate
the Ground transmit-side stall.

Heartbeat-correlation extension:

- `hre/hro/hrv` and `hue/huo/huv` are respectively RF-ingress and physical
  USB-commit heartbeat event/observation/>2500-ms violation counters.
  RF ingress is latched immediately after CRC validation even while USB is
  disconnected or rejecting downlink, so RF supply remains separable from
  host-facing USB delivery.
  `hrl*/hrm*/hrv*` and `hul*/hum*/huv*` retain latest, maximum, and latest
  violation events with TDD/AUX/radio, pacer, ordered-backlog, and USB context.
- `hp*` is the complete heartbeat-pacer diagnostic set; specifically `hpblk`
  is the order-barrier block count and `hpdrop` is order-preservation loss.
- `obp22` is only the instantaneous number of complete CRC-valid msgid #22
  descriptors still in the ordered backlog. It intentionally excludes parser
  partials and frames already admitted to byte-only LocalEgress; pair it with
  `dlq=0` when proving a clean baseline.

The report buffer is 10240 bytes. The conservative source contract proves a
maximum below that bound and a 10239-byte valid report drains in 160 64-byte
calls (16.0 s at the 100-ms service cadence), within the 20-s query contract.

Core parity plan: `core/include/vc_lora` and `core/src` remain authoritative.
After any core change, run `tools/sync_arduino_sketch_core.ps1`, update both
stable diagnostic core copies from the same canonical files, and require
`check_v2_stage_diag_latest_contract.ps1` plus the scheduler sync contract to
pass before packaging. Diagnostic bridge hooks must remain removable by the
diagnostic preprocessor normalization, leaving the canonical Phase-6 bridge.
