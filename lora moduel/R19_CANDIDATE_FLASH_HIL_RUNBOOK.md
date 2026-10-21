# R19 candidate application-only flash and one-run HIL

This runbook authorizes an experimental R19 physical acceptance run. It does
not authorize deployment. The candidate builder, flash orchestrator, and HIL
runner each produce a separately sealed evidence set.

## Fixed identities and ownership

| Role | Port | PNP instance | USB parent / MAC |
|---|---|---|---|
| Vehicle | COM3 | `USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000` | `USB\VID_303A&PID_1001\90:70:69:11:81:A4` / `90:70:69:11:81:a4` |
| Ground | COM6 | `USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000` | `USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80` / `1c:db:d4:5a:83:80` |

During flash, the orchestrator has exclusive ownership of COM3 and COM6.
Mission Planner, Arduino IDE/CLI, serial terminals, MAVProxy, QGroundControl,
Python serial programs, and other COM3/COM6 clients must be closed. During the
subsequent automated parameter HIL, the dedicated runner exclusively opens
Ground COM6 at 57600 bit/s, explicitly forbids COM3 access, and requires
Mission Planner to remain closed. Do not run two clients on one port.

## Operator preparation

1. Save a Pixhawk parameter backup before the experiment.
2. Disconnect all power before inspecting wiring. Verify both E220 antennas
   are fitted, common GND is present, and all logic is 3.3 V compatible.
3. Isolate propulsion and actuator power. Keep Pixhawk DISARMED throughout.
4. Reconnect only the power/USB required for the bench test. Confirm that the
   fixed Vehicle device enumerates as COM3 and Ground as COM6.
5. Close Mission Planner and every other serial client before flash. The
   orchestrator independently checks processes and both device identities.

Do not provide the physical-safety attestation until all five items are true.

## Build and offline validation

Build the immutable candidate. This does not open a COM port or flash hardware:

```powershell
Set-Location E:\VESC\TRIAL_LOG\Loreley3_System\06_vc_lora_bridge
.\tools\build_r19_candidate_artifacts.ps1
```

The only accepted input to the flash orchestrator is:

```text
runs/candidates/R19-HS-PRODUCT-CANDIDATE-BUILD-001/latest.json
```

Run the flash preflight without process inventory, device access, or esptool:

```powershell
.\tools\invoke_r19_candidate_app_flash_hil.ps1
```

DryRun must finish with
`PASS_DRY_RUN_NO_PROCESS_DEVICE_OR_ESPTOOL_ACCESS`. Resolve any manifest,
seal, source, candidate binary, or accepted-R18 rollback hash failure before
continuing.

## One candidate flash

After the operator preparation is complete, start the reviewed tool with the
in-box Windows PowerShell 5.1 executable. All reviewed Windows HIL scripts are
qualified on this host. In particular, the runtime-stage outer pins an OpenOCD
tree digest computed with Windows PowerShell 5.1 ordering semantics; do not run
that live outer from `pwsh` / PowerShell 7. Run the candidate flash exactly:

```powershell
& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\invoke_r19_candidate_app_flash_hil.ps1 `
  -Execute `
  -HilAuthorization R19_EXPERIMENTAL_HIL_ONE_RUN_NOT_DEPLOYMENT `
  -OperatorSafetyAttestation PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED
```

The fixed sequence is:

```text
Vehicle COM3: identity + read MAC -> app write 0x10000 -> read-back verify -> re-enumeration
Ground  COM6: identity + read MAC -> app write 0x10000 -> read-back verify -> re-enumeration
```

Only one staged application image is passed to each write. Full erase,
bootloader, partition-table, merged-image, and non-`0x10000` writes are never
generated. Allow about two to five minutes for preflight, two flashes,
read-back, and re-enumeration; identity recovery has bounded waits.

The competing-client gate records every known serial client and every exact
`COM3` / `COM6` command-line reference. A PowerShell process is ignored only
for the explicit-COM heuristic when all of these are true: it is an actual
ancestor of the flash child, its executable is `powershell.exe` or `pwsh.exe`,
and its command line contains the canonical reviewed outer basename as a full
token. Known serial clients are never ignored, even when they are ancestors.
Non-ancestors, siblings, lookalike names, unknown ancestry, cycles, duplicate
PIDs, and a missing current PID remain fail-closed. Trusted ancestors are saved
in `trusted_launcher_ancestors` for audit.

Complete all PnP/process inventory before launching the live outer. From the
first active-JTAG action until final accepted-R18 rollback completes, do not
start parallel agents, audits, terminals, or read-only inventory commands whose
command line contains the literal `COM3` or `COM6`. A non-ancestor is
intentionally rejected even when it never opens a COM port. This is an HIL
orchestration rule, not a product-runtime requirement.

When this gate rejects a process, it writes an immutable, monotonically named
`competing_client_gate_01.json`, `_02.json`, and so on before throwing. Each
record preserves `PID`, `ParentPID`, `Name`, `ExecutablePath`, and `CommandLine`
for every blocker, together with trusted ancestors, counts, status, current PID,
and timestamps. `flash_record.json.competing_client_gate_failures` references
each record by path and SHA-256, and normal evidence sealing includes the files.
A clean gate creates no failure record. The known-client and exact-COM checks
remain fail-closed; evidence capture does not relax either check.

Success is only:

```text
PASS_CANDIDATE_INSTALLED_HIL_ONE_RUN_ONLY
```

The emitted `flash_record.json` and sibling `final_seal.json` authorize one
immediate, hash-bound HIL acceptance run. They do not authorize a second run
or deployment.

Keep Mission Planner closed. Select the immutable `handoff.json` named by the
current candidate `latest.json`, and the immutable `flash_record.json` printed
by the successful flash invocation. Then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\run_r19_pixhawk_param_list_e2e_hil.ps1 `
  -Execute `
  -RepoRoot 'E:\VESC\TRIAL_LOG\Loreley3_System\06_vc_lora_bridge' `
  -CandidateHandoffPath '<immutable candidate run\handoff.json>' `
  -CandidateFlashEvidencePath '<immutable flash run\flash_record.json>'
```

The runner exclusively opens COM6 and rejects COM3 access. Candidate
`latest.json` must still select the supplied handoff. Claiming the flash record
is atomic: a preflight or run failure consumes that one-run authorization, so
do not retry with the same flash evidence. Restore R18 or perform a fresh,
fully validated candidate flash to obtain new one-run evidence.

## Failure and rollback

Before the first candidate write, any mismatch stops without a firmware write.
After any candidate write may have started, every failure triggers a paired
restore of the pinned accepted R18 Vehicle and Ground application binaries.
Each role gets at most three write/read-back/re-enumeration attempts.

If the terminal status is
`FAIL_CANDIDATE_FLASH_R18_ROLLBACK_PASS`, the candidate test is rejected but
both accepted R18 applications were restored. Do not continue to R19 HIL.

If the terminal status is
`FAIL_ROLLBACK_UNPROVEN_POWER_OFF_REQUIRED`, disconnect all power immediately.
Do not operate the bridge until accepted R18 has been restored and explicitly
verified on both roles.

After the one HIL run, restore accepted R18 unless a separate reviewed release
process explicitly authorizes something else:

```powershell
& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\invoke_r19_candidate_app_flash_hil.ps1 `
  -Execute `
  -RollbackOnly `
  -RollbackAuthorization RESTORE_ACCEPTED_R18_AFTER_R19_HIL
```

Rollback success is only `PASS_R18_ROLLBACK_COMPLETE`. The rollback remains
application-only at `0x10000` and preserves bootloader and partition data.

## Evidence locations

Candidate build evidence:

```text
runs/candidates/R19-HS-PRODUCT-CANDIDATE-BUILD-001/<UTC-guid>/
```

Each dry, flash, or rollback invocation writes a non-overwriting run beneath:

```text
runs/validation/R19-CANDIDATE-APP-FLASH-HIL-001/<UTC-guid>/
```

The acceptance handoff is `flash_record.json`; its sibling `final_seal.json`,
`artifact_manifest.json`, `SHA256SUMS.txt`, terminal status, command arguments,
stdout/stderr, identity snapshots, and staged application hashes are required
parts of the evidence set.
