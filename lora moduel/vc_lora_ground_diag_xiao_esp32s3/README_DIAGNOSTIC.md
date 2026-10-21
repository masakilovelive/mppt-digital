# Ground cycle diagnostic firmware

This is an additive XIAO ESP32-S3 Ground diagnostic build. The copied core is
byte-identical to `core/`, and the copied Phase 6 adapter differs from the
canonical adapter only in `VC_LORA_PHASE6_GROUND_DIAGNOSTICS` blocks.
Production Vehicle and Ground sketches are not modified.

Normal COM6 traffic is the production 57600-bps MAVLink stream. No periodic
text is emitted. At a MAVLink parser boundary, the exact ASCII command
`VCGSTAT?<LF>` is consumed by the observer and never reaches the RF ingress.
Only then are three correlated `GCSTAT1/2/3` lines written. While those lines
are emitted, validated RF-to-USB MAVLink frames remain queued in their normal
FIFO so binary data cannot interleave with the report.

Use the two-stage collector after uploading the diagnostic binary to Ground:

```powershell
tools\ground_diag_query.ps1 -Port COM6 -Baud 57600
```

Important fields:

- `GCSTAT1`: `gr`, `dup`, `fut`, `stcy`, `stss` classify received grants;
  `raw` and `ctl` separate raw E220 activity from decoded control messages;
  `st/sid/cy`, `aux/rb/pa`, and `fail/ew/ef` capture controller and runtime
  state.
- `GCSTAT2`: `ubi/uvf/u20`, `uqf/uqfb/uqb`, and `udf/udb/uoe` cover USB
  ingress validation, PARAM_REQUEST_READ, queueing, and loss.
- `GCSTAT3`: `utx/upb`, `itx/dtx`, `ar/ex/ins`, action-issue counts, and
  state/raw/control histograms expose each Ground uplink transaction.

Compare two reports by subtracting monotonic counters. A healthy empty cycle
increments `gr`, `itx`, and `aci` together. If `raw` rises without `ctl`, the
failure is framing/demux. If `ctl/cgr` rises but `gr` does not, the disposition
fields identify duplicate, future, or stale grants. If `gr` rises without
`itx+dtx`, use `ar/ex/ins`, `aux/rb/pa`, and the state-entry counters to locate
the Ground transmit-side stall.
