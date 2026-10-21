# Phase 6 Ground USB heartbeat pacing contract

This adapter paces only CRC-valid, byte-exact MAVLink HEARTBEAT frames from
the primary vehicle (`sysid=1`, `compid=1`). It never synthesizes, re-encodes,
renumbers, or duplicates a heartbeat. Foreign heartbeats and other validated
frames retain the ordinary pass-through path.

After a primary heartbeat is held, later complete frames enter a fixed
224-byte/28-descriptor, allocation-free ordered backlog. At a deadline the
heartbeat is atomically admitted to the same 4-KiB LocalEgress FIFO first;
following frames remain as complete descriptors until that heartbeat crosses
its physical publication fence. A heartbeat is counted emitted only when
cumulative `bytes_committed` reaches the immutable goal captured at admission
and the pinned HWCDC reports all three conditions: software ring and partial
FIFO stash empty, TX-loss epoch unchanged, and final endpoint packet picked up
by the host. The required short/ZLP boundary is included. Byte-ring acceptance
alone is not host-visible completion.

The heartbeat's entire post-admission path has an absolute 106-ms deadline
(6-ms physical write plus 100-ms publication fence). Endpoint backpressure,
a partial 21-byte write, or a stalled private HWCDC ring may pause progress
only until that deadline; the commit is then rejected and the bridge fails
closed instead of holding the pacer and ordered backlog indefinitely.

A matching proxied `PARAM_VALUE` (#22) receives the same exclusive publication
boundary. Its exact frame, cumulative byte goal, HWCDC loss epoch, and absolute
100-ms deadline occupy one fixed slot. The proxy index advances only after the
result-bearing fence succeeds. A following #22 remains in the ordered backlog
and is not preclassified until the active value commits. Timeout, confirmed
disconnect with uncertain bytes, an unsafe loss-epoch change, or an invalid
egress pump reports `usb_queued=false` and latches the bridge fail-stop;
uncertain partial data is never treated as a successful parameter.

The capacity proof assumes the fixed 550-ms E220 subpacket service floor and
32-byte RF chunk: one maximum signed MAVLink2 heartbeat (34 bytes), the
remaining first-chunk tail (31 bytes), and four following chunks during
2100-ms hold + 200-ms combined loop/PARAM budget + 49-ms current-frame tail
total 193 bytes,
rounded to 224 bytes. Together with LocalEgress the bounded Ground USB storage
is 4320 bytes. RF supply shortage, an unavailable USB writer, or overflow is
diagnosed; under those conditions the 2500-ms gap guarantee is unavailable.
The time proof is 2100-ms soft deadline + 100-ms ordinary loop jitter + 100-ms
possible preceding PARAM publication + 49-ms current frame + 6-ms 32-byte HB
write + 100-ms HWCDC publication fence = 2455 ms.

Confirmed disconnect rejects every newly completed RF frame before
LocalEgress admission, plus all complete frames still in the ordered backlog.
A matching PARAM_VALUE is therefore reported `usb_queued=false` and cannot
advance the proxy. The production Ground path samples HWCDC host/SOF presence with
`Serial.isPlugged()` and checks endpoint write readiness with `bool(Serial)`
before each product `Serial.write`; HWCDC's disconnected private 256-byte ring is not
treated as physical delivery. A raw host-present false pauses writes
immediately. Destructive disconnect handling occurs only after the raw signal
has remained false continuously for 50 ms; recovery before that boundary
cancels the pending loss and retains exact queued frames. Boot-time raw absence
has no grace period, and raw true reconnects immediately. The existing
byte-only LocalEgress cannot retract a frame after atomic admission.
Consequently a confirmed mid-disconnect can leave already admitted bytes to
drain after reconnect; the loss epoch prevents them from being credited as a
successful commit, the bridge stops, and recovery requires a device/session
restart.

`BUS_RESET` is a byte-stream discontinuity even when no HB/#22 commit happens
to be active. The patched HWCDC handles reset before a simultaneous IN_EMPTY,
discards both its ring and ISR stash, advances the TX-loss epoch, and refuses
publication while reset status is pending. Ground tracks a separate physical
publication watermark which advances only after `flushTxComplete()` succeeds.
An epoch change is recoverable only when no commit, pending write, queued byte,
or committed-but-unpublished byte exists. At that clean boundary Ground drains
retained USB RX bytes, discards only retractable ordered/heartbeat backlog,
resets its GCS MAVLink parser, adopts the new epoch, and ends the current loop.
Any uncertain byte still stops the bridge permanently, so an old LocalEgress
suffix cannot prefix a new post-reset MAVLink frame. The FIFO-replacement write
path reports only the bytes actually retained.

In ESP32-S3 Hardware CDC/JTAG mode, `Serial.isPlugged()` is a raw host/SOF
signal, not a stable cable/COM-handle truth value. The sealed Hardware CDC HIL
run observed seven short false pulses while Windows kept COM6 open once for the
entire run. For an established production connection, `bool(Serial)` remains
only the cached current endpoint-ready predicate. Before the first host IN
pickup or OUT RX it may remain false even after a read-only host has opened the
port, so it is not by itself a cold-start bootstrap proof.
Either a short endpoint-ready dip or a sub-50-ms raw-presence dip therefore
retains complete queued frames and any active partial-frame commit. Neither
predicate proves that a Windows process has the COM handle open, because DTR
is not an application-open signal in this mode. Production promotion still
requires an application-liveness contract (for example, MAVLink host arming
with timeout) or a CDC mode/control-line contract which Mission Planner
demonstrably uses.

RF framing, TDD timing, the 650-ms guards, UART rates, and the E220 profile are
unchanged. Only the Ground USB publication/commit boundary is stricter.

## R18 PARAM_VALUE USB publication commit

The R17 production Mission Planner capture delivered indexes 0..246 and
248..931 in the initial stream, while index 247 appeared only during later GCS
recovery. Ground-side proxy accounting had already advanced past 247 and the
RF/parser CRC counters stayed clean. The byte timing matched a 32-byte HWCDC
write containing a 21-byte heartbeat plus the first 11 bytes of the 37-byte
`PARAM_VALUE`; a destructive flush could preserve the heartbeat, discard that
11-byte prefix, and let the parser resynchronize at the next complete frame
without a CRC error.

R18 prevents that mixed publication. Heartbeat and tracked `PARAM_VALUE`
frames each own the physical USB path until result-bearing completion. The
pinned ESP32 3.3.11 HWCDC adds `txLossEpoch()` and non-destructive
`flushTxComplete(timeout, epoch)`, which checks both its ring and ISR stash and
never clears them on timeout. The firmware stores no dynamic data and adds only
fixed commit state. Offline host/contract/Arduino results must pass before the
R18 binary is uploaded; final acceptance still requires a low-speed Mission
Planner 932/932 run with primary-heartbeat maximum gap <=2500 ms.

The exact patched ESP32 3.3.11 `HWCDC.cpp` and `HWCDC.h` are canonical build
inputs under `third_party/esp32-core-3.3.11-vc-lora/`. The guarded installer
`tools/install_patched_esp32_hwcdc.ps1` accepts only the recorded upstream
hashes, preserves the originals, and verifies the installed result. Every
Arduino compile independently requires both installed files to match those
canonical copies and records both hashes in the firmware manifest.

## R17 pre-Grant heartbeat reserve

The R16 Mission Planner run retrieved all 932 ordered `PARAM_VALUE` frames but
exposed one 2951.354-ms primary-heartbeat completion gap. The fixed empty-uplink
path is 550-ms Grant service + 650-ms uplink guard + 550-ms `UL_IDLE` service +
650-ms return guard + 550-ms next-heartbeat service = 2950 ms. With two older
age-paced heartbeats already held, the former two-entry pacer could reject the
fresh real heartbeat immediately preceding that interval.

R17 expands only this allocation-free real-heartbeat reserve from two entries
to three. A leased head remains immutable; if the standalone pacer is full,
replacement removes the oldest non-leased entry and preserves FIFO order. No
synthetic, re-encoded, or replayed heartbeat is introduced. TDD timing, the
650-ms guards, RF framing, and `PARAM_VALUE` ordering remain unchanged.

`IT-GROUND-USB-HB-PHASE6-PREGRANT-RESERVE-001` fixes the former 2951-ms
failure and verifies a 2401-ms USB completion maximum after the change, with
exact heartbeat/parameter pairing, hold age <=2400 ms, and zero overflow,
expiry, replacement, order-drop, CRC, or partial-frame errors.

## Vehicle target PARAM_VALUE priority lane

The canonical Vehicle adapter observes every complete, CRC-valid uplink frame
only after that immutable transaction has been admitted to the D6 Pixhawk
egress. For each `PARAM_REQUEST_READ` it retains `param_index`, `param_id`, and
target system/component in an allocation-free eight-entry tracker. In index
mode `param_id` is unused and does not distinguish retransmits. A zero target
system or component retains its MAVLink broadcast-wildcard meaning.

A D7 `PARAM_VALUE` matching that identity enters a separate fixed eight-frame
priority lane. It does not enter, remove, or reorder the existing 1024-frame /
64-KiB generic `PARAM_VALUE` FIFO. A partially sent frame is never preempted.
At a complete-frame boundary, at most one already-pending real heartbeat may
precede the target; after that yield the target is selected before another
heartbeat. Once the target is active, following heartbeats remain retained.

Rejected E220 writes consume no application bytes and expose the identical
target prefix on retry. If one response overlaps distinct ID- and index-owned
requests, each still-Pending owner receives one queued response before a later
arrival is filtered as a duplicate. Request identity is released only after
its owned frame completes. Scheduler diagnostics expose request observation,
duplicate/full/invalid outcomes, target enqueue/selection/accepted chunks,
completion/rejection, and heartbeat yields.

The production-equivalent transport test carries all 18 retained generic
responses through the actual Vehicle/Ground controllers, 550-ms gated RF
medium, link demux, and Ground MAVLink parser in byte-exact FIFO order. It also
fixes the 32-byte physical-write ceiling, 550-ms same-direction completion
floor, at least 647 ms of direction-reversal quiet, and zero gate/timeout/CRC
or parser violations. Every actual primary-RF heartbeat is sequence/wire
unique, and every four-arrival span after warm-up is at most 6200 ms (observed
maximum 5159 ms), providing at least three unique frames per trailing 6200 ms
to the separately tested Ground USB pacer and ordered-commit path.

The 2026-08-25 target-priority baseline passed all 167 host tests in both the
normal build and a new Clang 22.1.8 ASan/UBSan build. R17 superseded that
software baseline with 179/179 normal CTest success and the three-entry
pre-Grant reserve test. R18 adds the publication-loss regression, absolute
commit deadlines, reset-epoch quarantine, and reproducible HWCDC contracts.
At that historical milestone its normal offline suite was 180/180; deployment
remained NO-GO until the
Mission Planner 932-frame/Heartbeat acceptance also passes. The post-R18
clean-epoch recovery candidate adds `FW-USB-EPOCH-RECOVERY-001` and passes
181/181 normal CTest cases; it still requires a fresh device flash and the same
Mission Planner acceptance before promotion.

## R19 diagnostic read-only bootstrap (2026-10-03 pre-HIL hypothesis)

The 2026-09-30 read-only dual-COM diagnostic capture returned zero bytes on
both Vehicle and Ground even though both applications had been written and
read back successfully. A later repeat produced the same empty producer
boundary. The offline hypothesis was that the native ESP32-S3 HWCDC cached
connection state is established by host traffic, while the diagnostic writer
required that cached state before sending its first frame. The runner
deliberately performs no serial write, so this formed a real model-level
cycle; the later physical result below shows that it was not sufficient to
explain the live zero-byte boundary.

The correction is diagnostic-only. Before cached connection is established,
the bridge may publish only its exact 63-byte initial R19A/R19F frame through
`writeTxBootstrapFrameChecked()`. Publication is all-or-zero into a clean
HWCDC software ring; the ISR retains the existing maximum 32-byte hardware
FIFO transaction. The TX mutex fences the ISR and debug writer until plug,
loss epoch, reset, quarantine, ring, stash, and FIFO postconditions have been
rechecked. Product MAVLink data never uses this entry point.

Ground and Vehicle keep a late-open bootstrap pending with no running 500-ms
deadline. Ground also keeps its diagnostic reservation inactive. Once the CDC
endpoint becomes ready, normal checked-write and physical-flush accounting
take over and the original deadline applies. A BUS_RESET while pending
discards any uncertain publication, adopts the new epoch at a clean boundary,
and rearms the same immutable frame with the same MAVLink sequence.

The default macro remains zero, so accepted R18 behavior, normal R19 product
builds, TDD timing, UART assignments, E220 settings, MAVLink routing, parameter
ordering, and deployment policy are unchanged. Offline verification on
2026-10-03 passed all 301 registered host tests in both the normal and
ASan/UBSan builds, with zero sanitizer reports. Installed-core semantic checks
passed 33/33. The sealed diagnostic artifact
`20261003T081053916Z-1a760fe3` compiled to 431101 flash / 106232 RAM bytes for
Vehicle and 402757 flash / 69832 RAM bytes for Ground. It is explicitly
`acceptance_eligible=false`, `acceptance_authorized=false`, and
`deployment_authorized=false`.

No COM port, firmware flash, reset, or RF operation was performed while this
pre-HIL addendum was written. The one-time operation described here was later
performed and is superseded by the physical result below.

## R19 diagnostic physical result and false-SOF/ZLP correction

The sealed artifact `20261003T081053916Z-1a760fe3` was subsequently installed
under one-time authorization, captured read-only on COM3 and COM6 for 40
seconds, and unconditionally rolled back. Run
`20261003T083253345Z-5fc0094a` again returned zero raw bytes, zero complete
frames, and zero R19A/R19F on both roles. Maximum service gaps were 66,228 us
for Vehicle and 62,095 us for Ground; serial writes were zero, parser state
was clean, and cleanup passed. The earlier cached-connection correction was
therefore a valid offline bug fix but not a sufficient physical fix.

Both devices were restored on the first attempt to accepted R18 applications:
Vehicle `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`
and Ground `30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`.
The one-time authorization was consumed. R19 acceptance and deployment remain
unauthorized.

The next diagnostic-only correction removes raw SOF presence as a bootstrap
hard gate. A false `Serial.isPlugged()` sample cannot prevent the exact
63-byte bootstrap while reset, quarantine, epoch, writer exclusion, and clean
ring/stash/FIFO conditions remain mandatory. The permitted IN_EMPTY ISR's
cached `connected` bit becomes the post-reset host-pickup witness for
diagnostic completion. After the bootstrap postcheck, HWCDC releases the
publication fence, enables IN_EMPTY, and explicitly calls
`usb_serial_jtag_ll_txfifo_flush()` to start a fresh empty-FIFO/ZLP IN
transaction instead of relying on a previously cleared interrupt edge.

The bridge now samples `bool(Serial)` and `availableForWrite()` independently
of raw SOF presence for this macro-gated path. No-host and reset cases retain
or discard the complete frame without claiming publication. False-SOF
cold-start Vehicle/Ground tests, the 301/301 normal suite, fresh 301/301
ASan/UBSan suite, 33/33 HWCDC semantic contract, installer check-only, both
role compiles, and the independent candidate verifier pass.

The resulting sealed diagnostic artifact is
`20261003T091702033Z-e3aa5200`. Its manifest SHA-256 is
`0836246D655F1F03CF391DC0C7BC1D74C858A4F508ED12F5F33842825318515A`
and final-seal SHA-256 is
`A2D1433442E9A6BD4D0A242E4F491C46F9898E405FB3FF84E1A1C8DB40254B71`.
Vehicle application SHA-256 is
`9B4D559C105EDB5A12F657FAC9AC0F631E0EE1379B29A6C86A9A8FF04E19A2CE`;
Ground is
`D191D50F38A5CBD87F1995DD83754EB727CE68EEB8E92EC4D7C6FBA8FEF619EF`.
The artifact package itself was produced and sealed offline; its manifest's
no-hardware-interaction statement describes that build step. It was later
installed once under separate one-time authorization. Physical run
`20261003T094504443Z-32368ca4` again returned zero raw bytes, zero complete
frames, and zero R19A/R19F on both roles during the 40-second read-only
capture. Vehicle's maximum service gap was 98,532 us and Ground's was
50,185 us; serial writes were zero and cleanup passed. Thus the false-SOF/ZLP
revision is not a sufficient physical fix for the zero-byte boundary.

Both applications were restored on the first attempt to accepted R18 and
verified by readback and re-enumeration. R19 acceptance and deployment remain
false, and the one-time authorization is consumed. The next change must first
separate common early boot, diagnostic publication, the HWCDC ring/FIFO, and
USB IN visibility with evidence that does not itself depend on CDC output; the
same artifact is not a valid repeat candidate.

If request observation returns `Full` or `Invalid`, Phase 6 latches the
permanent runtime stop. The Vehicle loop rechecks both `bridge_ready` and
`runtime_fail_closed` after radio/local ingress service and before the D6 pump,
so an already retained D6 byte cannot become a physical Pixhawk write or
commit after that failure.

The host production model covers 18 older `PARAM_VALUE` frames, 1-Hz
heartbeats, a target response arriving nineteenth, the fixed 650-ms return
guard, 3000-ms downlink window, escaped 32-byte writes, and the 550-ms E220
service floor. The target completed at 2300 ms (limit 30000 ms) and the
observed heartbeat gap was 1650 ms (limit 2500 ms).

`IT-E220-BUFFERED-VEHICLE-PARAM-PRIORITY-001` additionally traverses actual
Vehicle/Ground TDD controllers, `RfMediumSim`, and the production-equivalent
`E220WriteContract` 550-ms gate. It sends #20 over RF, admits it to modeled D6
before remembering it, then injects 18 old values, the target, and 1-Hz real
heartbeats. Ground received the target exactly once in 7614 ms from request
origin (2304 ms from D6/target enqueue). All 18 old frames traversed 39 actual
TDD/RF cycles and the Ground parser in exact FIFO order; no synthetic drain was
credited as delivery. The target-era RF heartbeat gap was 1650 ms and the
full-run RF maximum was 2959 ms; gate/drop/collision counts were zero. This
target-era RF fairness observation is separate from the
Ground USB 2500-ms SLA, which remains covered by the USB heartbeat pacer and
ordered-commit integration tests.

The canonical core is synchronized into all four production/diagnostic sketch
copies. Production Vehicle and Ground clean builds must pass with the pinned,
hash-verified ESP32 core 3.3.11 pair. The historical R18 promotion rule required
manifest-selected binaries and a passing low-speed HIL; stale `_flashed.bin`
outputs were never valid selections. R18 has since passed its Mission Planner
932/932 and Heartbeat acceptance and is the current rollback image. R19 remains
unaccepted and undeployable until its separate physical criteria pass.
