[CmdletBinding()]
param(
  [string]$WrapperPath = '',
  [string]$EvidenceDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([string]::IsNullOrWhiteSpace($WrapperPath)) {
  $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $WrapperPath = Join-Path $repoRoot 'tools\invoke_evidence_bound_child.ps1'
}
$WrapperPath = [System.IO.Path]::GetFullPath($WrapperPath)

$checks = New-Object 'System.Collections.Generic.List[object]'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Add-Check {
  param([string]$Name, [bool]$Passed, [string]$Detail = '')
  $checks.Add([pscustomobject][ordered]@{
      name = $Name; passed = $Passed; detail = $Detail
    })
  if (-not $Passed) { $failures.Add("$Name`: $Detail") }
}

function Write-Utf8NoBom {
  param([string]$Path, [string]$Text)
  [System.IO.File]::WriteAllText(
      $Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-BytesSha256 {
  param([byte[]]$Bytes)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '')
  } finally { $sha.Dispose() }
}

function ConvertTo-WindowsCommandLineArgument {
  param([AllowEmptyString()][string]$Value)
  if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
  $builder = New-Object Text.StringBuilder
  [void]$builder.Append('"')
  $slashes = 0
  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq '\') { $slashes++; continue }
    if ($character -eq '"') {
      if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
      [void]$builder.Append('\"')
      $slashes = 0
      continue
    }
    if ($slashes -gt 0) {
      [void]$builder.Append(('\' * $slashes)); $slashes = 0
    }
    [void]$builder.Append($character)
  }
  if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Get-WrapperArgs {
  param(
    [string]$PowerShellPath,
    [string]$ExecutableHash,
    [string]$LauncherHash,
    [string]$ArgumentsPath,
    [string]$ArgumentsHash,
    [string]$BoundPath,
    [string]$BoundHash,
    [string]$OutputPath,
    [switch]$FailAfterStart,
    [switch]$FailJobCreationBeforeStart,
    [switch]$FailJobAssignment
  )
  $values = New-Object 'System.Collections.Generic.List[string]'
  foreach ($value in @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WrapperPath,
      '-ExecutablePath', $PowerShellPath,
      '-ExpectedExecutableSha256', $ExecutableHash,
      '-ExpectedLauncherSha256', $LauncherHash,
      '-ArgumentsFile', $ArgumentsPath,
      '-ExpectedArgumentsFileSha256', $ArgumentsHash,
      '-BoundFilePath', $BoundPath,
      '-ExpectedBoundFileSha256', $BoundHash,
      '-OutputDirectory', $OutputPath,
      '-Purpose', 'OFFLINE_V2_CONTRACT')) {
    $values.Add([string]$value)
  }
  if ($FailAfterStart) { $values.Add('-TestFailAfterStart') }
  if ($FailJobCreationBeforeStart) {
    $values.Add('-TestFailJobCreationBeforeStart')
  }
  if ($FailJobAssignment) { $values.Add('-TestFailJobAssignment') }
  return $values.ToArray()
}

function Invoke-WrapperSync {
  param(
    [string]$PowerShellPath,
    [string]$ExecutableHash,
    [string]$LauncherHash,
    [string]$ArgumentsPath,
    [string]$ArgumentsHash,
    [string]$BoundPath,
    [string]$BoundHash,
    [string]$OutputPath,
    [switch]$FailAfterStart,
    [switch]$FailJobCreationBeforeStart,
    [switch]$FailJobAssignment
  )
  $invokeArgs = @(Get-WrapperArgs @PSBoundParameters)
  $previous = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $text = (& $PowerShellPath @invokeArgs 2>&1 | Out-String)
    $code = [int]$LASTEXITCODE
  } finally { $ErrorActionPreference = $previous }
  return [pscustomobject]@{ exit_code = $code; output = $text }
}

function Start-WrapperAsync {
  param(
    [string]$PowerShellPath,
    [string]$ExecutableHash,
    [string]$LauncherHash,
    [string]$ArgumentsPath,
    [string]$ArgumentsHash,
    [string]$BoundPath,
    [string]$BoundHash,
    [string]$OutputPath
  )
  $invokeArgs = @(Get-WrapperArgs @PSBoundParameters)
  $quoted = New-Object 'System.Collections.Generic.List[string]'
  foreach ($argument in $invokeArgs) {
    $quoted.Add((ConvertTo-WindowsCommandLineArgument -Value $argument))
  }
  $start = New-Object Diagnostics.ProcessStartInfo
  $start.FileName = $PowerShellPath
  $start.Arguments = $quoted.ToArray() -join ' '
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $start
  if (-not $process.Start()) { throw 'asynchronous wrapper start failed' }
  return $process
}

function Wait-ForCondition {
  param([scriptblock]$Condition, [int]$TimeoutMs = 10000)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (& $Condition) { return $true }
    Start-Sleep -Milliseconds 25
  }
  return [bool](& $Condition)
}

function Test-SealLayers {
  param([string]$Directory)
  try {
    $manifestHash = Get-Sha256 (Join-Path $Directory 'manifest.json')
    $artifactHash = Get-Sha256 (Join-Path $Directory 'artifact_manifest.json')
    $sealPath = Join-Path $Directory 'final_seal.json'
    $sealHash = Get-Sha256 $sealPath
    $seal = Get-Content -Raw $sealPath | ConvertFrom-Json
    return ($seal.manifest_sha256 -eq $manifestHash -and
      $seal.artifact_manifest_sha256 -eq $artifactHash -and
      (Get-Content -Raw (Join-Path $Directory 'manifest.sha256')).Trim() -eq
        "$manifestHash *manifest.json" -and
      (Get-Content -Raw (Join-Path $Directory 'final_seal.sha256')).Trim() -eq
        "$sealHash *final_seal.json")
  } catch { return $false }
}

$checkerPath = [IO.Path]::GetFullPath($PSCommandPath)
$powerShellPath = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
$requiredRedCases = @(
  'argv_same_snapshot_hash_parse_copy_launch',
  'argv_mutation_never_starts_child',
  'bound_file_locked_until_child_exit',
  'executable_and_launcher_hash_mismatch_refused_before_output',
  'post_start_failure_kills_waits_and_seals_failure',
  'forced_launcher_termination_does_not_orphan_child',
  'pollable_logs_are_read_only_to_observers',
  'invalid_utf8_argv_refused_before_output')
$scratch = $null
try {
  $wrapperExists = Test-Path -LiteralPath $WrapperPath -PathType Leaf
  Add-Check 'wrapper_exists' $wrapperExists $WrapperPath
  if (-not $wrapperExists) { throw 'wrapper missing' }
  $source = Get-Content -Raw -LiteralPath $WrapperPath
  $launcherHash = Get-Sha256 $WrapperPath
  $executableHash = Get-Sha256 $powerShellPath

  Add-Check 'mandatory_hash_interface_present' (
    $source -match 'ExpectedExecutableSha256' -and
    $source -match 'ExpectedLauncherSha256') 'launcher and executable hashes'
  Add-Check 'hardware_scope_absent' (-not ($source -match
    'System\.IO\.Ports|SerialPort|Get-PnpDevice|Win32_SerialPort|esptool|arduino-cli')) `
    'no COM/PnP/upload APIs'

  $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  $scratch = Join-Path $tempBase `
      ('vc_launch_v2_contract_' + [guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Path $scratch)
  $dummyPath = Join-Path $scratch 'dummy_child.ps1'
  $dummySource = @'
[CmdletBinding(PositionalBinding = $false)]
param(
  [int]$ExitCode = 0,
  [int]$DelayMs = 0,
  [string]$StartedMarker = '',
  [string]$CompletedMarker = '',
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Remaining
)
[Console]::Out.WriteLine('DUMMY_STARTED')
[Console]::Out.Flush()
if (-not [string]::IsNullOrWhiteSpace($StartedMarker)) {
  [IO.File]::WriteAllText($StartedMarker, $PID.ToString())
}
if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
[Console]::Out.WriteLine(($Remaining | ConvertTo-Json -Compress))
[Console]::Error.WriteLine('DUMMY_STDERR')
if (-not [string]::IsNullOrWhiteSpace($CompletedMarker)) {
  [IO.File]::WriteAllText($CompletedMarker, 'completed')
}
exit $ExitCode
'@
  Write-Utf8NoBom $dummyPath $dummySource
  $dummyHash = Get-Sha256 $dummyPath

  # Same immutable byte snapshot drives SHA, strict parse, copy, and launch.
  $normalArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath,
    '-ExitCode', '7', '-DelayMs', '0',
    'alpha', 'space value', 'quote"value', 'trailing\')
  $normalArgsPath = Join-Path $scratch 'normal_args.json'
  Write-Utf8NoBom $normalArgsPath ($normalArgs | ConvertTo-Json -Depth 4)
  $normalArgsHash = Get-Sha256 $normalArgsPath
  $normalRoot = Join-Path $scratch 'normal.launch'
  $normalPreflightPath = Join-Path $normalRoot 'launch.preflight.json'
  $normal = Invoke-WrapperSync -PowerShellPath $powerShellPath `
      -ExecutableHash $executableHash -LauncherHash $launcherHash `
      -ArgumentsPath $normalArgsPath -ArgumentsHash $normalArgsHash `
      -BoundPath $dummyPath -BoundHash $dummyHash -OutputPath $normalRoot
  $snapshotValid = $false
  if (Test-Path -LiteralPath $normalPreflightPath) {
    $preflight = Get-Content -Raw $normalPreflightPath | ConvertFrom-Json
    $stdout = Get-Content -Raw (Join-Path $normalRoot 'launch.stdout.log')
    $stdoutLines = @($stdout -split "`r?`n" | Where-Object { $_ -ne '' })
    $received = if ($stdoutLines.Count -ge 2) {
      @($stdoutLines[1] | ConvertFrom-Json)
    } else { @() }
    $expectedRemaining = @('alpha', 'space value', 'quote"value', 'trailing\')
    $snapshotValid = ($normal.exit_code -eq 7 -and
      $preflight.arguments_snapshot.source_read_operation -eq
        'ReadAllBytes exactly once' -and
      $preflight.arguments_snapshot.strict_utf8 -and
      $preflight.arguments_snapshot.sha256 -eq $normalArgsHash -and
      (Get-Sha256 (Join-Path $normalRoot 'launch.argv.json')) -eq
        $normalArgsHash -and
      ($received -join "`n") -eq ($expectedRemaining -join "`n"))
  }
  Add-Check 'argv_same_snapshot_hash_parse_copy_launch' $snapshotValid `
      'one byte[] SHA/strict parse/exact copy/effective launch'
  Add-Check 'normal_evidence_sealed' (
    @(Get-ChildItem $normalRoot -File).Count -eq 12 -and
    (Test-SealLayers $normalRoot)) '12 files and valid seal layers'
  $normalSummary = Get-Content -Raw (Join-Path $normalRoot 'summary.json') |
      ConvertFrom-Json
  $normalManifest = Get-Content -Raw (Join-Path $normalRoot 'manifest.json') |
      ConvertFrom-Json
  $normalSeal = Get-Content -Raw (Join-Path $normalRoot 'final_seal.json') |
      ConvertFrom-Json
  $normalLifecycle = Get-Content -Raw `
      (Join-Path $normalRoot 'process_lifecycle.json') | ConvertFrom-Json
  $normalArtifact = Get-Content -Raw `
      (Join-Path $normalRoot 'artifact_manifest.json') | ConvertFrom-Json
  $normalRuntimeHashesMatch = $true
  foreach ($record in $normalArtifact.files) {
    $recordPath = Join-Path $normalRoot $record.file
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf) -or
        (Get-Sha256 $recordPath) -ne $record.sha256) {
      $normalRuntimeHashesMatch = $false
    }
  }
  $externalActionProperties = @(
    $normalSummary.launcher_external_actions.psobject.Properties)
  $externalActionsTypedFalse = ($externalActionProperties.Count -eq 3)
  foreach ($property in $externalActionProperties) {
    if (-not ($property.Value -is [bool]) -or $property.Value) {
      $externalActionsTypedFalse = $false
    }
  }
  Add-Check 'normal_exact_coverage_booleans_and_actual_exit' (
    $normalArtifact.covered_file_count -eq 7 -and
    $normalArtifact.files.Count -eq 7 -and
    $normalRuntimeHashesMatch -and $externalActionsTypedFalse -and
    $normalSummary.child_actual_os_exit_code -eq 7 -and
    $normalSummary.child_exit_code_captured_after_wait -and
    $normalLifecycle.actual_os_exit_code_captured -and
    $normalLifecycle.actual_os_exit_code -eq 7) `
      '7/7 hashes, three Boolean false values, captured child exit 7'
  Add-Check 'independent_preflight_contract_readback' (
    $preflight.arguments_snapshot.strict_utf8 -and
    $preflight.arguments_snapshot.source_read_operation -eq
      'ReadAllBytes exactly once' -and
    $preflight.bound_file.powershell_file_launch -and
    $preflight.bound_file.effective_argument_index -eq 4 -and
    $preflight.bound_file.lock_share_mode -eq 'FileShare.Read' -and
    $normalSummary.bound_file_lock_release_stage -eq
      'outer finally after sealed evidence attempt' -and
    $normalManifest.bound_file_lock_release_stage -eq
      'outer finally after sealed evidence attempt' -and
    $normalSeal.bound_file_lock_release_stage -eq
      'outer finally after sealed evidence attempt') `
      'strict UTF-8, effective -File, lock lifetime in sealed artifacts'

  # An existing output root must be refused without mutation or child start.
  $freshMarker = Join-Path $scratch 'existing-output-child.started'
  $freshArgs = @(
    '-NoProfile', '-File', $dummyPath, '-ExitCode', '0',
    '-StartedMarker', $freshMarker)
  $freshArgsPath = Join-Path $scratch 'existing_output_args.json'
  Write-Utf8NoBom $freshArgsPath ($freshArgs | ConvertTo-Json)
  $freshArgsHash = Get-Sha256 $freshArgsPath
  $beforeExisting = @(
    Get-ChildItem -LiteralPath $normalRoot -File | Sort-Object Name |
      ForEach-Object { $_.Name + ':' + (Get-Sha256 $_.FullName) }) -join "`n"
  $existingRun = Invoke-WrapperSync -PowerShellPath $powerShellPath `
      -ExecutableHash $executableHash -LauncherHash $launcherHash `
      -ArgumentsPath $freshArgsPath -ArgumentsHash $freshArgsHash `
      -BoundPath $dummyPath -BoundHash $dummyHash -OutputPath $normalRoot
  $afterExisting = @(
    Get-ChildItem -LiteralPath $normalRoot -File | Sort-Object Name |
      ForEach-Object { $_.Name + ':' + (Get-Sha256 $_.FullName) }) -join "`n"
  Add-Check 'existing_output_refused_without_mutation_or_child_start' (
    $existingRun.exit_code -eq 125 -and
    $beforeExisting -ceq $afterExisting -and
    -not (Test-Path -LiteralPath $freshMarker)) `
      'exit125, identical 12-file hash set, no child marker'

  # Mutation after approval hash must fail before output and before child start.
  $mutationStarted = Join-Path $scratch 'mutation.started'
  $mutationArgs = @(
    '-NoProfile', '-File', $dummyPath, '-ExitCode', '0',
    '-StartedMarker', $mutationStarted)
  $mutationPath = Join-Path $scratch 'mutation_args.json'
  Write-Utf8NoBom $mutationPath ($mutationArgs | ConvertTo-Json)
  $mutationApprovedHash = Get-Sha256 $mutationPath
  Write-Utf8NoBom $mutationPath (($mutationArgs + 'tampered') | ConvertTo-Json)
  $mutationRoot = Join-Path $scratch 'mutation.launch'
  $mutation = Invoke-WrapperSync -PowerShellPath $powerShellPath `
      -ExecutableHash $executableHash -LauncherHash $launcherHash `
      -ArgumentsPath $mutationPath -ArgumentsHash $mutationApprovedHash `
      -BoundPath $dummyPath -BoundHash $dummyHash -OutputPath $mutationRoot
  Add-Check 'argv_mutation_never_starts_child' (
    $mutation.exit_code -eq 125 -and
    -not (Test-Path $mutationRoot) -and
    -not (Test-Path $mutationStarted)) 'stale approved hash refused'

  # Slow child proves bound-file lock and pollable read-only logs.
  $slowArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath,
    '-ExitCode', '0',
    '-DelayMs', '2200', 'slow-case')
  $slowPath = Join-Path $scratch 'slow_args.json'
  Write-Utf8NoBom $slowPath ($slowArgs | ConvertTo-Json)
  $slowHash = Get-Sha256 $slowPath
  $slowRoot = Join-Path $scratch 'slow.launch'
  $slowProcess = Start-WrapperAsync -PowerShellPath $powerShellPath `
      -ExecutableHash $executableHash -LauncherHash $launcherHash `
      -ArgumentsPath $slowPath -ArgumentsHash $slowHash `
      -BoundPath $dummyPath -BoundHash $dummyHash -OutputPath $slowRoot
  $slowLog = Join-Path $slowRoot 'launch.stdout.log'
  $logReady = Wait-ForCondition -TimeoutMs 10000 -Condition {
    if (-not (Test-Path $slowLog -PathType Leaf)) { return $false }
    try { return (Get-Content -Raw $slowLog) -match 'DUMMY_STARTED' }
    catch { return $false }
  }
  $observerReadWorked = $logReady
  $observerWriteDenied = $false
  if ($logReady) {
    try {
      $probe = New-Object IO.FileStream(
          $slowLog, [IO.FileMode]::Open, [IO.FileAccess]::Write,
          [IO.FileShare]::ReadWrite)
      $probe.Dispose()
    } catch [IO.IOException] { $observerWriteDenied = $true }
  }
  $boundWriteDenied = $false
  try {
    $probe = New-Object IO.FileStream(
        $dummyPath, [IO.FileMode]::Open, [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite)
    $probe.Dispose()
  } catch [IO.IOException] { $boundWriteDenied = $true }
  $slowProcess.WaitForExit()
  $boundReleased = $false
  try {
    $probe = New-Object IO.FileStream(
        $dummyPath, [IO.FileMode]::Open, [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite)
    $probe.Dispose(); $boundReleased = $true
  } catch {}
  Add-Check 'bound_file_locked_until_child_exit' (
    $boundWriteDenied -and $boundReleased -and $slowProcess.ExitCode -eq 0) `
    'write denied while child lives and allowed after exit'
  Add-Check 'pollable_logs_are_read_only_to_observers' (
    $observerReadWorked -and $observerWriteDenied) `
    'observer read succeeded and observer write was sharing-denied'

  # Executable and launcher hashes are both mandatory pre-output gates.
  $wrongHash = '0' * 64
  $hashMarker = Join-Path $scratch 'hash-mismatch.started'
  $hashArgs = @('-NoProfile', '-File', $dummyPath,
    '-StartedMarker', $hashMarker)
  $hashArgsPath = Join-Path $scratch 'hash_args.json'
  Write-Utf8NoBom $hashArgsPath ($hashArgs | ConvertTo-Json)
  $hashArgsSha = Get-Sha256 $hashArgsPath
  $badExeRoot = Join-Path $scratch 'bad-exe.launch'
  $badExe = Invoke-WrapperSync -PowerShellPath $powerShellPath `
      -ExecutableHash $wrongHash -LauncherHash $launcherHash `
      -ArgumentsPath $hashArgsPath -ArgumentsHash $hashArgsSha `
      -BoundPath $dummyPath -BoundHash $dummyHash -OutputPath $badExeRoot
  $badLauncherRoot = Join-Path $scratch 'bad-launcher.launch'
  $badLauncher = Invoke-WrapperSync -PowerShellPath $powerShellPath `
      -ExecutableHash $executableHash -LauncherHash $wrongHash `
      -ArgumentsPath $hashArgsPath -ArgumentsHash $hashArgsSha `
      -BoundPath $dummyPath -BoundHash $dummyHash `
      -OutputPath $badLauncherRoot
  Add-Check 'executable_and_launcher_hash_mismatch_refused_before_output' (
    $badExe.exit_code -eq 125 -and $badLauncher.exit_code -eq 125 -and
    -not (Test-Path $badExeRoot) -and
    -not (Test-Path $badLauncherRoot) -and
    -not (Test-Path $hashMarker)) 'both mismatches fail closed'

  # A valid hash with invalid UTF-8 must be refused before output.
  $invalidUtf8Path = Join-Path $scratch 'invalid_utf8_args.json'
  [byte[]]$invalidBytes = @(0x5B, 0x22, 0xC3, 0x28, 0x22, 0x5D)
  [IO.File]::WriteAllBytes($invalidUtf8Path, $invalidBytes)
  $invalidHash = Get-BytesSha256 $invalidBytes
  $invalidRoot = Join-Path $scratch 'invalid-utf8.launch'
  $invalid = Invoke-WrapperSync -PowerShellPath $powerShellPath `
      -ExecutableHash $executableHash -LauncherHash $launcherHash `
      -ArgumentsPath $invalidUtf8Path -ArgumentsHash $invalidHash `
      -BoundPath $dummyPath -BoundHash $dummyHash -OutputPath $invalidRoot
  Add-Check 'invalid_utf8_argv_refused_before_output' (
    $invalid.exit_code -eq 125 -and -not (Test-Path $invalidRoot)) `
    'strict decoder rejects malformed bytes'

  # The only effective PowerShell -File target must be BoundFilePath.
  $wrongTargetMarker = Join-Path $scratch 'wrong-target.started'
  $otherPath = Join-Path $scratch 'other_child.ps1'
  Write-Utf8NoBom $otherPath "[IO.File]::WriteAllText('$($wrongTargetMarker.Replace("'", "''"))','started')"
  $positionArgs = @('-NoProfile', '-File', $otherPath, $dummyPath)
  $positionPath = Join-Path $scratch 'position_args.json'
  Write-Utf8NoBom $positionPath ($positionArgs | ConvertTo-Json)
  $positionHash = Get-Sha256 $positionPath
  $positionRoot = Join-Path $scratch 'position.launch'
  $position = Invoke-WrapperSync -PowerShellPath $powerShellPath `
      -ExecutableHash $executableHash -LauncherHash $launcherHash `
      -ArgumentsPath $positionPath -ArgumentsHash $positionHash `
      -BoundPath $dummyPath -BoundHash $dummyHash -OutputPath $positionRoot
  Add-Check 'powershell_effective_file_position_exact' (
    $position.exit_code -eq 125 -and -not (Test-Path $positionRoot) -and
    -not (Test-Path $wrongTargetMarker)) '-File next token must equal bound file'

  # Injected post-start failure must kill, wait, and seal failure evidence.
  $failureStarted = Join-Path $scratch 'failure.started'
  $failureCompleted = Join-Path $scratch 'failure.completed'
  $failureArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath,
    '-ExitCode', '0',
    '-DelayMs', '30000', '-StartedMarker', $failureStarted,
    '-CompletedMarker', $failureCompleted)
  $failurePath = Join-Path $scratch 'failure_args.json'
  Write-Utf8NoBom $failurePath ($failureArgs | ConvertTo-Json)
  $failureHash = Get-Sha256 $failurePath
  $failureRoot = Join-Path $scratch 'post-start-failure.launch'
  $failureSummaryPath = Join-Path $failureRoot 'summary.json'
  $failureLifecyclePath = Join-Path $failureRoot 'process_lifecycle.json'
  $failureSealPath = Join-Path $failureRoot 'final_seal.json'
  $failureRun = Invoke-WrapperSync -PowerShellPath $powerShellPath `
      -ExecutableHash $executableHash -LauncherHash $launcherHash `
      -ArgumentsPath $failurePath -ArgumentsHash $failureHash `
      -BoundPath $dummyPath -BoundHash $dummyHash -OutputPath $failureRoot `
      -FailAfterStart
  $failureValid = $false
  if (Test-Path $failureSummaryPath) {
    $failureSummary = Get-Content -Raw $failureSummaryPath | ConvertFrom-Json
    $failureLife = Get-Content -Raw $failureLifecyclePath |
        ConvertFrom-Json
    $failureSeal = Get-Content -Raw $failureSealPath | ConvertFrom-Json
    $failurePidAlive = $null -ne (Get-Process -Id $failureSummary.pid `
        -ErrorAction SilentlyContinue)
    $failureValid = ($failureRun.exit_code -eq 125 -and
      $failureSummary.status -eq 'LAUNCHER_FAILURE_AFTER_START' -and
      $failureSummary.child_killed_and_waited -and
      $failureLife.kill_requested_after_start_failure -and
      $failureLife.child_waited_after_start_failure -and
      $failureSeal.status -eq 'SEALED_LAUNCHER_FAILURE' -and
      -not $failurePidAlive -and -not (Test-Path $failureCompleted) -and
      (Test-SealLayers $failureRoot))
  }
  Add-Check 'post_start_failure_kills_waits_and_seals_failure' `
      $failureValid 'exit125, kill/wait, failure seal'

  # Assignment failure is also a post-start path and must be sealed.
  $assignRoot = Join-Path $scratch 'job-assignment-failure.launch'
  $assignLifecyclePath = Join-Path $assignRoot 'process_lifecycle.json'
  $assignSummaryPath = Join-Path $assignRoot 'summary.json'
  $assignRun = Invoke-WrapperSync -PowerShellPath $powerShellPath `
      -ExecutableHash $executableHash -LauncherHash $launcherHash `
      -ArgumentsPath $failurePath -ArgumentsHash $failureHash `
      -BoundPath $dummyPath -BoundHash $dummyHash -OutputPath $assignRoot `
      -FailJobAssignment
  $assignValid = $false
  if (Test-Path $assignLifecyclePath) {
    $assignLife = Get-Content -Raw $assignLifecyclePath | ConvertFrom-Json
    $assignSummary = Get-Content -Raw $assignSummaryPath |
        ConvertFrom-Json
    $assignValid = ($assignRun.exit_code -eq 125 -and
      -not $assignLife.job_assignment_completed -and
      $assignLife.kill_requested_after_start_failure -and
      $assignLife.child_waited_after_start_failure -and
      $assignSummary.child_killed_and_waited -and
      (Test-SealLayers $assignRoot))
  }
  Add-Check 'job_assignment_failure_kills_waits_and_seals_failure' `
      $assignValid 'direct child kill/wait and sealed failure'

  # Job construction failure occurs before Process.Start and still gets a
  # durable failure seal without claiming a child OS exit code.
  $creationRoot = Join-Path $scratch 'job-creation-failure.launch'
  $creationRun = Invoke-WrapperSync -PowerShellPath $powerShellPath `
      -ExecutableHash $executableHash -LauncherHash $launcherHash `
      -ArgumentsPath $failurePath -ArgumentsHash $failureHash `
      -BoundPath $dummyPath -BoundHash $dummyHash -OutputPath $creationRoot `
      -FailJobCreationBeforeStart
  $creationValid = $false
  if (Test-Path (Join-Path $creationRoot 'process_lifecycle.json')) {
    $creationLife = Get-Content -Raw `
        (Join-Path $creationRoot 'process_lifecycle.json') | ConvertFrom-Json
    $creationSummary = Get-Content -Raw `
        (Join-Path $creationRoot 'summary.json') | ConvertFrom-Json
    $creationSeal = Get-Content -Raw `
        (Join-Path $creationRoot 'final_seal.json') | ConvertFrom-Json
    $creationValid = ($creationRun.exit_code -eq 125 -and
      $creationLife.status -eq 'LAUNCHER_FAILURE_BEFORE_START' -and
      -not $creationLife.process_started -and
      -not $creationLife.actual_os_exit_code_captured -and
      $null -eq $creationLife.actual_os_exit_code -and
      $creationSummary.child_not_started -and
      -not $creationSummary.child_exit_code_captured_after_wait -and
      $null -eq $creationSummary.child_actual_os_exit_code -and
      $creationSeal.status -eq 'SEALED_LAUNCHER_FAILURE' -and
      (Get-Content -Raw (Join-Path $creationRoot 'launch.pid.txt')).Trim() -eq
        'NOT_STARTED' -and
      (Test-SealLayers $creationRoot))
  }
  Add-Check 'job_creation_failure_before_start_seals_without_fake_exit' `
      $creationValid 'exit125, NOT_STARTED, null child exit, sealed failure'

  $wrapperText = Get-Content -Raw -LiteralPath $WrapperPath
  $disposeMatches = [regex]::Matches($wrapperText,
      [regex]::Escape('$boundFileLockStream.Dispose()'))
  $finallyIndex = $wrapperText.LastIndexOf('} finally {',
      [StringComparison]::Ordinal)
  $disposeIndex = $wrapperText.LastIndexOf('$boundFileLockStream.Dispose()',
      [StringComparison]::Ordinal)
  Add-Check 'bound_file_lock_released_only_in_outer_finally' (
    $disposeMatches.Count -eq 1 -and $finallyIndex -ge 0 -and
    $disposeIndex -gt $finallyIndex) `
      'single dispose site located in outer finally'

  # Killing the launcher closes its Job Object and must kill the child.
  $forcedStarted = Join-Path $scratch 'forced.started'
  $forcedCompleted = Join-Path $scratch 'forced.completed'
  $forcedArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath,
    '-ExitCode', '0',
    '-DelayMs', '30000', '-StartedMarker', $forcedStarted,
    '-CompletedMarker', $forcedCompleted)
  $forcedPath = Join-Path $scratch 'forced_args.json'
  Write-Utf8NoBom $forcedPath ($forcedArgs | ConvertTo-Json)
  $forcedHash = Get-Sha256 $forcedPath
  $forcedRoot = Join-Path $scratch 'forced.launch'
  $launcherProcess = Start-WrapperAsync -PowerShellPath $powerShellPath `
      -ExecutableHash $executableHash -LauncherHash $launcherHash `
      -ArgumentsPath $forcedPath -ArgumentsHash $forcedHash `
      -BoundPath $dummyPath -BoundHash $dummyHash -OutputPath $forcedRoot
  $forcedPidPath = Join-Path $forcedRoot 'launch.pid.txt'
  $forcedReady = Wait-ForCondition -TimeoutMs 15000 -Condition {
    (Test-Path $forcedPidPath -PathType Leaf) -and
    (Test-Path $forcedStarted -PathType Leaf)
  }
  $forcedChildPid = if ($forcedReady) {
    [int](Get-Content -Raw $forcedPidPath).Trim()
  } else { 0 }
  if (-not $launcherProcess.HasExited) { $launcherProcess.Kill() }
  $launcherProcess.WaitForExit()
  $childGone = if ($forcedChildPid -gt 0) {
    Wait-ForCondition -TimeoutMs 10000 -Condition {
      $null -eq (Get-Process -Id $forcedChildPid -ErrorAction SilentlyContinue)
    }
  } else { $false }
  Add-Check 'forced_launcher_termination_does_not_orphan_child' (
    $forcedReady -and $childGone -and -not (Test-Path $forcedCompleted)) `
    ('ready={0}, child_pid={1}, gone={2}' -f
      $forcedReady, $forcedChildPid, $childGone)
} catch {
  Add-Check 'checker_unhandled_exception' $false $_.Exception.ToString()
} finally {
  if ($null -ne $scratch -and (Test-Path $scratch)) {
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ($resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved).StartsWith('vc_launch_v2_contract_')) {
      [IO.Directory]::Delete($resolved, $true)
    } else {
      Add-Check 'scratch_cleanup_scope' $false $resolved
    }
  }
}

$status = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
$summary = [pscustomobject][ordered]@{
  schema_version = 2
  contract_id = 'EVIDENCE-BOUND-CHILD-LAUNCHER-V2-CONTRACT-001'
  phase = 'GREEN_CANDIDATE'
  status = $status
  checked_utc = [DateTime]::UtcNow.ToString('o')
  wrapper_path = $WrapperPath
  wrapper_sha256 = if (Test-Path $WrapperPath) { Get-Sha256 $WrapperPath } else { $null }
  checker_path = $checkerPath
  checker_sha256 = Get-Sha256 $checkerPath
  executable_path = $powerShellPath
  executable_sha256 = Get-Sha256 $powerShellPath
  required_red_case_count = $requiredRedCases.Count
  required_red_cases = $requiredRedCases
  offline_dummy_only = $true
  com_accessed = $false
  pnp_queried = $false
  live_hil_performed = $false
  check_count = $checks.Count
  failure_count = $failures.Count
  checks = $checks.ToArray()
  failures = $failures.ToArray()
}

if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
  $EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
  if (Test-Path $EvidenceDirectory) {
    throw "EvidenceDirectory must be fresh: $EvidenceDirectory"
  }
  $parent = Split-Path -Parent $EvidenceDirectory
  if (-not (Test-Path $parent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $parent)
  }
  [void](New-Item -ItemType Directory -Path $EvidenceDirectory)
  Write-Utf8NoBom (Join-Path $EvidenceDirectory 'summary.json') `
      ($summary | ConvertTo-Json -Depth 12)
}

$summary | ConvertTo-Json -Depth 8
if ($status -eq 'PASS') { exit 0 }
exit 1
