# Evidence-bound child launcher

`invoke_evidence_bound_child.ps1` launches one hash-bound child process and
creates an independently checkable launch-evidence directory. It is generic and
contains no COM, PnP, power-control, upload, or HIL logic.

## Required freeze inputs

Before a live launch, freeze all four approvals:

1. the launcher itself and its SHA-256;
2. the child executable and its SHA-256;
3. the child script, such as the dual-diagnostic HIL runner, and its SHA-256;
4. a strict UTF-8 JSON array containing every exact child argument, and its
   SHA-256.

The launcher reads the argument file once with `ReadAllBytes`. That same byte
array is hashed, strict-UTF-8 decoded, parsed, copied to `launch.argv.json`, and
used to construct the child command line. The bound child path must occur
exactly once in the argument array. For PowerShell, there must be exactly one
explicit `-File`, and its immediately following value must exactly identify the
bound file. A missing or mismatched approval is refused before output creation.

Example invocation after those inputs have been reviewed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  tools\invoke_evidence_bound_child.ps1 `
  -ExecutablePath C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe `
  -ExpectedExecutableSha256 <powershell-exe-sha256> `
  -ExpectedLauncherSha256 <launcher-ps1-sha256> `
  -ArgumentsFile <frozen-argv.json> `
  -ExpectedArgumentsFileSha256 <argv-sha256> `
  -BoundFilePath <frozen-runner.ps1> `
  -ExpectedBoundFileSha256 <runner-sha256> `
  -OutputDirectory <fresh-absent-directory> `
  -Purpose <reviewed-purpose>
```

The output directory must not exist. Pre-output refusals exit with code `125`
and create no output. A completed launch propagates the child's exit code while
also recording the actual child OS exit code after `WaitForExit()`.

The executable and bound file are each opened with `FileShare.Read` before
their hashes are computed. Both approved read handles remain held until the
outer `finally`, after the child has exited and the evidence-seal attempt has
completed. Executable or bound-file paths containing a reparse-point component
are refused. Each path is checked immediately before and after its read handle
is opened, and the final path obtained from that handle must equal the approved
regular path. The child is assigned to a Windows Job
Object configured with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Thus forced
launcher termination closes the job and terminates the child. If job creation
fails before child start, or assignment/finalization fails after start, the
launcher records an accurate sealed failure. A never-started child has a null
actual OS exit code; a started child is killed, waited, and its actual exit is
captured before the launcher returns `125`.

During execution, `launch.stdout.log` and `launch.stderr.log` use
`FileShare.Read`: observers can poll them but cannot open them for writing. On
completion the launcher flushes them to
disk, writes `process_lifecycle.json` and `summary.json`, covers the seven
runtime files in `artifact_manifest.json`, and then writes `manifest.json`,
`final_seal.json`, and both SHA-256 sidecars. A host or launcher crash can leave
an intentionally incomplete, unsealed directory; only a directory with a valid
final seal is complete evidence.

The `launcher_external_actions` booleans apply only to the launcher. Operator
actions and actions performed by the hash-bound child must be established from
their own evidence.

Run the offline contract with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  tests\hil\check_evidence_bound_child_launcher_v2_contract.ps1
```

The v2 checker is offline-only. It uses dummy children and does not enumerate or
open COM ports, query PnP, upload firmware, switch power, or perform HIL.

## PowerShell execution-mode allowlist (v3, retained by v4)

For a `powershell.exe` or `pwsh.exe` child, the first five argv entries must be
exactly:

```text
-NoProfile -ExecutionPolicy Bypass -File <BoundFilePath>
```

The argument array must still contain exactly one `-File` and exactly one bound
file occurrence. Consequently, competing execution modes before `-File`, such
as `-Command`, `-EncodedCommand`, `-c`, `-e`, `-ec`, `-en`, and `-enc`, and
abbreviated, reordered, missing, or altered live-prefix entries are refused
before output creation.

Run the additive v3 High-severity contract with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  tests\hil\check_evidence_bound_child_launcher_v3_contract.ps1
```

The v3 freeze is historical and superseded. The additive v4 contract retains
the v3 execution-mode rules and additionally proves that the bound file has
the same reparse-component and open-handle final-path protection as the child
executable. A directory-junction case must be refused before output creation;
a file-symbolic-link case is also exercised when the Windows account is
permitted to create symbolic links. The sealed preflight, lifecycle, summary,
manifest, and final seal record the bound-file final handle path, exact-match
result, reparse refusal, and lock lifetime.

Run the v4 contract with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  tests\hil\check_evidence_bound_child_launcher_v4_contract.ps1
```
