[CmdletBinding()]
param(
  [string]$WrapperPath = '',
  [string]$EvidenceDirectory = '',
  [ValidateSet('RED', 'GREEN_CANDIDATE')]
  [string]$Phase = 'GREEN_CANDIDATE'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([string]::IsNullOrWhiteSpace($WrapperPath)) {
  $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $WrapperPath = Join-Path $repoRoot 'tools\invoke_evidence_bound_child.ps1'
}
$WrapperPath = [IO.Path]::GetFullPath($WrapperPath)
$checkerPath = [IO.Path]::GetFullPath($PSCommandPath)
$systemPowerShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
$checks = New-Object 'Collections.Generic.List[object]'
$failures = New-Object 'Collections.Generic.List[string]'
$scratch = $null

function Add-Check {
  param([string]$Name, [bool]$Passed, [string]$Detail)
  $checks.Add([pscustomobject][ordered]@{
      name = $Name; passed = $Passed; detail = $Detail
    })
  if (-not $Passed) { $failures.Add("$Name`: $Detail") }
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Write-Utf8NoBom {
  param([string]$Path, [string]$Text)
  [IO.File]::WriteAllText(
      $Path, $Text, (New-Object Text.UTF8Encoding($false)))
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
      if ($slashes -gt 0) {
        [void]$builder.Append(('\' * ($slashes * 2)))
      }
      [void]$builder.Append('\"')
      $slashes = 0
      continue
    }
    if ($slashes -gt 0) {
      [void]$builder.Append(('\' * $slashes)); $slashes = 0
    }
    [void]$builder.Append($character)
  }
  if ($slashes -gt 0) {
    [void]$builder.Append(('\' * ($slashes * 2)))
  }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Get-WrapperArguments {
  param(
    [string]$ExecutablePath,
    [string]$ExecutableSha256,
    [string]$LauncherSha256,
    [string]$ArgumentsFile,
    [string]$ArgumentsSha256,
    [string]$BoundFile,
    [string]$BoundSha256,
    [string]$OutputDirectory,
    [string]$PreStartReadyMarker = '',
    [int]$PauseBeforeStartMs = 0
  )
  $result = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WrapperPath,
    '-ExecutablePath', $ExecutablePath,
    '-ExpectedExecutableSha256', $ExecutableSha256,
    '-ExpectedLauncherSha256', $LauncherSha256,
    '-ArgumentsFile', $ArgumentsFile,
    '-ExpectedArgumentsFileSha256', $ArgumentsSha256,
    '-BoundFilePath', $BoundFile,
    '-ExpectedBoundFileSha256', $BoundSha256,
    '-OutputDirectory', $OutputDirectory,
    '-Purpose', 'OFFLINE_V3_CONTRACT')
  if (-not [string]::IsNullOrWhiteSpace($PreStartReadyMarker)) {
    $result += @('-TestPreStartReadyMarker', $PreStartReadyMarker)
  }
  if ($PauseBeforeStartMs -gt 0) {
    $result += @('-TestPauseBeforeProcessStartMs',
      $PauseBeforeStartMs.ToString(
        [Globalization.CultureInfo]::InvariantCulture))
  }
  return $result
}

function Invoke-Wrapper {
  param(
    [string]$ExecutablePath,
    [string]$ExecutableSha256,
    [string]$LauncherSha256,
    [string]$ArgumentsFile,
    [string]$ArgumentsSha256,
    [string]$BoundFile,
    [string]$BoundSha256,
    [string]$OutputDirectory,
    [string]$PreStartReadyMarker = '',
    [int]$PauseBeforeStartMs = 0
  )
  $wrapperArguments = @(Get-WrapperArguments @PSBoundParameters)
  $priorPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $text = (& $systemPowerShell @wrapperArguments 2>&1 | Out-String)
    $exitCode = [int]$LASTEXITCODE
  } finally { $ErrorActionPreference = $priorPreference }
  return [pscustomobject]@{ exit_code = $exitCode; output = $text }
}

function Start-Wrapper {
  param(
    [string]$ExecutablePath,
    [string]$ExecutableSha256,
    [string]$LauncherSha256,
    [string]$ArgumentsFile,
    [string]$ArgumentsSha256,
    [string]$BoundFile,
    [string]$BoundSha256,
    [string]$OutputDirectory,
    [string]$PreStartReadyMarker = '',
    [int]$PauseBeforeStartMs = 0
  )
  $wrapperArguments = @(Get-WrapperArguments @PSBoundParameters)
  $quoted = New-Object 'Collections.Generic.List[string]'
  foreach ($argument in $wrapperArguments) {
    $quoted.Add((ConvertTo-WindowsCommandLineArgument $argument))
  }
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = $systemPowerShell
  $startInfo.Arguments = $quoted.ToArray() -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw 'wrapper start failed' }
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

function Test-Seal {
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

try {
  if (-not (Test-Path -LiteralPath $WrapperPath -PathType Leaf)) {
    throw "wrapper missing: $WrapperPath"
  }
  $source = Get-Content -Raw -LiteralPath $WrapperPath
  $launcherHash = Get-Sha256 $WrapperPath
  Add-Check 'no_hardware_scope' (-not ($source -match
      'System\.IO\.Ports|SerialPort|Get-PnpDevice|Win32_SerialPort|esptool|arduino-cli')) `
      'no COM/PnP/upload API in wrapper'
  Add-Check 'v2_baseline_freeze_preserved' (
    Test-Path -LiteralPath (Join-Path (Split-Path -Parent `
      (Split-Path -Parent $PSScriptRoot)) `
      'runs\validation\EVIDENCE-BOUND-CHILD-LAUNCHER-V2-FREEZE-001\20260827T154000000Z-final19\final_seal.json')) `
      'v2 final19 remains historical input'

  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  $scratch = Join-Path $tempRoot `
      ('vc_launcher_v3_' + [guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Path $scratch)
  $executableCopy = Join-Path $scratch 'powershell.exe'
  [IO.File]::Copy($systemPowerShell, $executableCopy, $false)
  $executableHash = Get-Sha256 $executableCopy

  $dummyPath = Join-Path $scratch 'dummy_child.ps1'
  $dummySource = @'
[CmdletBinding()]
param(
  [int]$ExitCode = 0,
  [int]$DelayMs = 0,
  [string]$StartedMarker = ''
)
if (-not [string]::IsNullOrWhiteSpace($StartedMarker)) {
  [IO.File]::WriteAllText($StartedMarker, $PID.ToString())
}
[Console]::Out.WriteLine('V3_DUMMY_STARTED')
[Console]::Out.Flush()
if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
exit $ExitCode
'@
  Write-Utf8NoBom $dummyPath $dummySource
  $dummyHash = Get-Sha256 $dummyPath

  $normalArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath,
    '-ExitCode', '7', '-DelayMs', '0')
  $normalArgumentsPath = Join-Path $scratch 'normal.argv.json'
  Write-Utf8NoBom $normalArgumentsPath `
      ($normalArguments | ConvertTo-Json -Depth 4)
  $normalArgumentsHash = Get-Sha256 $normalArgumentsPath
  $normalOutput = Join-Path $scratch 'normal.launch'
  $normalRun = Invoke-Wrapper -ExecutablePath $executableCopy `
      -ExecutableSha256 $executableHash -LauncherSha256 $launcherHash `
      -ArgumentsFile $normalArgumentsPath `
      -ArgumentsSha256 $normalArgumentsHash -BoundFile $dummyPath `
      -BoundSha256 $dummyHash -OutputDirectory $normalOutput
  $normalPreflight = if (Test-Path (Join-Path $normalOutput `
        'launch.preflight.json')) {
    Get-Content -Raw (Join-Path $normalOutput 'launch.preflight.json') |
      ConvertFrom-Json
  } else { $null }
  $normalLockEvidence = $false
  if ($null -ne $normalPreflight) {
    $executableEvidence = $normalPreflight.executable
    $requiredExecutableFields = @(
      'lock_share_mode', 'opened_before_hash',
      'lock_held_until_child_exit', 'reparse_path_refused')
    $hasExecutableFields = $true
    foreach ($field in $requiredExecutableFields) {
      if ($null -eq $executableEvidence.PSObject.Properties[$field]) {
        $hasExecutableFields = $false
      }
    }
    if ($hasExecutableFields) {
      $normalLockEvidence = (
        $executableEvidence.opened_before_hash -and
        $executableEvidence.lock_share_mode -eq 'FileShare.Read' -and
        $executableEvidence.lock_held_until_child_exit -and
        $executableEvidence.reparse_path_refused)
    }
  }
  Add-Check 'locked_executable_process_start_succeeds' (
    $normalRun.exit_code -eq 7 -and $normalLockEvidence -and
    @(Get-ChildItem $normalOutput -File).Count -eq 12 -and
    (Test-Seal $normalOutput)) `
      'copied powershell.exe starts while its approved read lock is held'
  $normalSummary = Get-Content -Raw `
      (Join-Path $normalOutput 'summary.json') | ConvertFrom-Json
  $normalManifest = Get-Content -Raw `
      (Join-Path $normalOutput 'manifest.json') | ConvertFrom-Json
  $normalSeal = Get-Content -Raw `
      (Join-Path $normalOutput 'final_seal.json') | ConvertFrom-Json
  $normalArtifact = Get-Content -Raw `
      (Join-Path $normalOutput 'artifact_manifest.json') | ConvertFrom-Json
  $runtimeHashesMatch = $true
  foreach ($record in $normalArtifact.files) {
    if ((Get-Sha256 (Join-Path $normalOutput $record.file)) -ne
        $record.sha256) { $runtimeHashesMatch = $false }
  }
  $prefixReadback = @(
    $normalPreflight.powershell_execution.exact_live_prefix) -join '|'
  Add-Check 'v3_sealed_evidence_independent_fields' (
    $normalPreflight.contract_id -eq 'EVIDENCE-BOUND-CHILD-LAUNCH-003' -and
    $normalPreflight.powershell_execution.exact_live_prefix_match -and
    $prefixReadback -eq '-NoProfile|-ExecutionPolicy|Bypass|-File' -and
    $normalSummary.executable_lock_share_mode -eq 'FileShare.Read' -and
    $normalManifest.executable_lock_share_mode -eq 'FileShare.Read' -and
    $normalSeal.executable_lock_share_mode -eq 'FileShare.Read' -and
    $normalSummary.child_actual_os_exit_code -eq 7 -and
    $normalArtifact.covered_file_count -eq 7 -and $runtimeHashesMatch) `
      'v3 contract id, exact prefix, executable lock, exit7, and 7/7 hashes'

  $disposeCount = [regex]::Matches($source,
      [regex]::Escape('$executableLockStream.Dispose()')).Count
  $disposeIndex = $source.LastIndexOf('$executableLockStream.Dispose()',
      [StringComparison]::Ordinal)
  $outerFinallyIndex = $source.LastIndexOf('} finally {',
      [StringComparison]::Ordinal)
  Add-Check 'executable_opened_before_hash_and_released_only_in_outer_finally' (
    $source -match '(?s)\$executableLockStream\s*=\s*New-Object IO\.FileStream\(.*?\[IO\.FileShare\]::Read' -and
    $source -match 'Get-Sha256FromStream\s+-Stream\s+\$executableLockStream' -and
    $disposeCount -eq 1 -and $disposeIndex -gt $outerFinallyIndex) `
      'one executable handle/hash path and one outer-finally dispose'

  $startedMarker = Join-Path $scratch 'slow.child.started'
  $preStartMarker = Join-Path $scratch 'slow.launcher.prestart'
  $slowArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath,
    '-ExitCode', '0', '-DelayMs', '2500', '-StartedMarker', $startedMarker)
  $slowArgumentsPath = Join-Path $scratch 'slow.argv.json'
  Write-Utf8NoBom $slowArgumentsPath `
      ($slowArguments | ConvertTo-Json -Depth 4)
  $slowArgumentsHash = Get-Sha256 $slowArgumentsPath
  $slowOutput = Join-Path $scratch 'slow.launch'
  $slowWrapper = Start-Wrapper -ExecutablePath $executableCopy `
      -ExecutableSha256 $executableHash -LauncherSha256 $launcherHash `
      -ArgumentsFile $slowArgumentsPath `
      -ArgumentsSha256 $slowArgumentsHash -BoundFile $dummyPath `
      -BoundSha256 $dummyHash -OutputDirectory $slowOutput `
      -PreStartReadyMarker $preStartMarker -PauseBeforeStartMs 2000
  $slowReady = Wait-ForCondition {
    (Test-Path $preStartMarker) -and
    (Test-Path (Join-Path $slowOutput 'launch.preflight.json'))
  } 10000
  $pidAbsentDuringProbe = -not (Test-Path `
      (Join-Path $slowOutput 'launch.pid.txt'))
  $writeDeniedWhileRunning = $false
  try {
    $probe = New-Object IO.FileStream(
        $executableCopy, [IO.FileMode]::Open, [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite)
    $probe.Dispose()
  } catch [IO.IOException] { $writeDeniedWhileRunning = $true }
  $slowWrapper.WaitForExit()
  $slowWrapperExit = [int]$slowWrapper.ExitCode
  $slowWrapper.Dispose()
  $writeAllowedAfterExit = $false
  try {
    $afterProbe = New-Object IO.FileStream(
        $executableCopy, [IO.FileMode]::Open, [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite)
    $writeAllowedAfterExit = $true
    $afterProbe.Dispose()
  } catch {}
  Add-Check 'executable_locked_against_mutation_until_child_exit' (
    $slowReady -and $slowWrapperExit -eq 0 -and
    $pidAbsentDuringProbe -and (Test-Path $startedMarker) -and
    $writeDeniedWhileRunning -and $writeAllowedAfterExit -and
    (Test-Seal $slowOutput)) `
      'write denied before Process.Start, child then runs, write allowed after finally'

  $mutatedExecutable = Join-Path $scratch 'mutated_powershell.exe'
  [IO.File]::Copy($systemPowerShell, $mutatedExecutable, $false)
  $approvedMutatedHash = Get-Sha256 $mutatedExecutable
  $mutationStream = New-Object IO.FileStream(
      $mutatedExecutable, [IO.FileMode]::Append, [IO.FileAccess]::Write,
      [IO.FileShare]::Read)
  try { $mutationStream.WriteByte(0) } finally { $mutationStream.Dispose() }
  $mutationOutput = Join-Path $scratch 'mutation.launch'
  $mutationRun = Invoke-Wrapper -ExecutablePath $mutatedExecutable `
      -ExecutableSha256 $approvedMutatedHash -LauncherSha256 $launcherHash `
      -ArgumentsFile $normalArgumentsPath `
      -ArgumentsSha256 $normalArgumentsHash -BoundFile $dummyPath `
      -BoundSha256 $dummyHash -OutputDirectory $mutationOutput
  Add-Check 'approved_executable_mutation_refused_before_output' (
    $mutationRun.exit_code -eq 125 -and
    -not (Test-Path $mutationOutput)) `
      'stale executable approval cannot create output or start child'

  $realDirectory = Join-Path $scratch 'real_executable'
  $junctionDirectory = Join-Path $scratch 'junction_executable'
  [void](New-Item -ItemType Directory -Path $realDirectory)
  $realExecutable = Join-Path $realDirectory 'powershell.exe'
  [IO.File]::Copy($systemPowerShell, $realExecutable, $false)
  [void](New-Item -ItemType Junction -Path $junctionDirectory `
      -Target $realDirectory)
  $junctionExecutable = Join-Path $junctionDirectory 'powershell.exe'
  $junctionOutput = Join-Path $scratch 'junction.launch'
  $junctionRun = Invoke-Wrapper -ExecutablePath $junctionExecutable `
      -ExecutableSha256 (Get-Sha256 $junctionExecutable) `
      -LauncherSha256 $launcherHash -ArgumentsFile $normalArgumentsPath `
      -ArgumentsSha256 $normalArgumentsHash -BoundFile $dummyPath `
      -BoundSha256 $dummyHash -OutputDirectory $junctionOutput
  Add-Check 'executable_reparse_path_refused_before_output' (
    $junctionRun.exit_code -eq 125 -and
    -not (Test-Path $junctionOutput)) `
      'junction component is rejected before output and child start'

  $wrongFileMarker = Join-Path $scratch 'wrong-file.started'
  $otherChild = Join-Path $scratch 'other_child.ps1'
  Write-Utf8NoBom $otherChild `
      "[IO.File]::WriteAllText('$($wrongFileMarker.Replace("'", "''"))','started')"
  $wrongFileArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $otherChild,
    $dummyPath)
  $wrongFilePath = Join-Path $scratch 'wrong_file.argv.json'
  Write-Utf8NoBom $wrongFilePath ($wrongFileArguments | ConvertTo-Json)
  $wrongFileOutput = Join-Path $scratch 'wrong_file.launch'
  $wrongFileRun = Invoke-Wrapper -ExecutablePath $executableCopy `
      -ExecutableSha256 $executableHash -LauncherSha256 $launcherHash `
      -ArgumentsFile $wrongFilePath `
      -ArgumentsSha256 (Get-Sha256 $wrongFilePath) `
      -BoundFile $dummyPath -BoundSha256 $dummyHash `
      -OutputDirectory $wrongFileOutput
  $duplicateMarker = Join-Path $scratch 'duplicate-file.started'
  $duplicateArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath,
    '-StartedMarker', $duplicateMarker, '-File')
  $duplicatePath = Join-Path $scratch 'duplicate_file.argv.json'
  Write-Utf8NoBom $duplicatePath ($duplicateArguments | ConvertTo-Json)
  $duplicateOutput = Join-Path $scratch 'duplicate_file.launch'
  $duplicateRun = Invoke-Wrapper -ExecutablePath $executableCopy `
      -ExecutableSha256 $executableHash -LauncherSha256 $launcherHash `
      -ArgumentsFile $duplicatePath `
      -ArgumentsSha256 (Get-Sha256 $duplicatePath) `
      -BoundFile $dummyPath -BoundSha256 $dummyHash `
      -OutputDirectory $duplicateOutput
  Add-Check 'powershell_file_exact_one_and_immediate_bound_target' (
    $wrongFileRun.exit_code -eq 125 -and
    -not (Test-Path $wrongFileOutput) -and
    -not (Test-Path $wrongFileMarker) -and
    $duplicateRun.exit_code -eq 125 -and
    -not (Test-Path $duplicateOutput) -and
    -not (Test-Path $duplicateMarker)) `
      'wrong immediate target and duplicate -File both refused before output'

  $encodedExit = [Convert]::ToBase64String(
      [Text.Encoding]::Unicode.GetBytes('exit 0'))
  $competingModes = @(
    @('-Command', 'exit 0'),
    @('-EncodedCommand', $encodedExit),
    @('-c', 'exit 0'),
    @('-e', $encodedExit),
    @('-ec', $encodedExit),
    @('-en', $encodedExit),
    @('-enc', $encodedExit))
  $competingAllRefused = $true
  $competingDetails = New-Object 'Collections.Generic.List[string]'
  $modeIndex = 0
  foreach ($mode in $competingModes) {
    $modeArguments = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', $mode[0], $mode[1],
      '-File', $dummyPath, '-ExitCode', '0')
    $modePath = Join-Path $scratch ("mode_$modeIndex.argv.json")
    Write-Utf8NoBom $modePath ($modeArguments | ConvertTo-Json)
    $modeOutput = Join-Path $scratch ("mode_$modeIndex.launch")
    $modeRun = Invoke-Wrapper -ExecutablePath $executableCopy `
        -ExecutableSha256 $executableHash -LauncherSha256 $launcherHash `
        -ArgumentsFile $modePath -ArgumentsSha256 (Get-Sha256 $modePath) `
        -BoundFile $dummyPath -BoundSha256 $dummyHash `
        -OutputDirectory $modeOutput
    $refused = ($modeRun.exit_code -eq 125 -and
      -not (Test-Path $modeOutput))
    if (-not $refused) { $competingAllRefused = $false }
    $competingDetails.Add("$($mode[0])=$refused")
    $modeIndex++
  }
  Add-Check 'competing_execution_modes_and_abbreviations_refused_before_output' `
      $competingAllRefused ($competingDetails.ToArray() -join ';')

  $badPrefixes = @(
    @('-NoProfile', '-File', $dummyPath, '-ExitCode', '0'),
    @('-NoP', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath,
      '-ExitCode', '0'),
    @('-NoProfile', '-ExecutionPolicy', 'Unrestricted', '-File', $dummyPath,
      '-ExitCode', '0'),
    @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', $dummyPath,
      '-ExitCode', '0'))
  $prefixAllRefused = $true
  $prefixIndex = 0
  foreach ($badPrefix in $badPrefixes) {
    $badPrefixPath = Join-Path $scratch ("prefix_$prefixIndex.argv.json")
    Write-Utf8NoBom $badPrefixPath ($badPrefix | ConvertTo-Json)
    $badPrefixOutput = Join-Path $scratch ("prefix_$prefixIndex.launch")
    $badPrefixRun = Invoke-Wrapper -ExecutablePath $executableCopy `
        -ExecutableSha256 $executableHash -LauncherSha256 $launcherHash `
        -ArgumentsFile $badPrefixPath `
        -ArgumentsSha256 (Get-Sha256 $badPrefixPath) `
        -BoundFile $dummyPath -BoundSha256 $dummyHash `
        -OutputDirectory $badPrefixOutput
    if ($badPrefixRun.exit_code -ne 125 -or
        (Test-Path $badPrefixOutput)) { $prefixAllRefused = $false }
    $prefixIndex++
  }
  Add-Check 'powershell_live_prefix_is_exact_whitelist' `
      $prefixAllRefused 'missing, abbreviated, altered, and reordered prefix refused'
} catch {
  Add-Check 'checker_completed_without_exception' $false $_.Exception.Message
} finally {
  if ($null -ne $scratch -and (Test-Path -LiteralPath $scratch)) {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedScratch.StartsWith($resolvedTemp,
          [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedScratch).StartsWith('vc_launcher_v3_',
          [StringComparison]::Ordinal)) {
      Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
  }
}

$status = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
$summary = [pscustomobject][ordered]@{
  schema_version = 3
  contract_id = 'EVIDENCE-BOUND-CHILD-LAUNCHER-V3-CONTRACT-001'
  phase = $Phase
  status = $status
  checked_utc = [DateTime]::UtcNow.ToString('o')
  wrapper_path = $WrapperPath
  wrapper_sha256 = Get-Sha256 $WrapperPath
  checker_path = $checkerPath
  checker_sha256 = Get-Sha256 $checkerPath
  offline_dummy_only = [bool]$true
  com_accessed = [bool]$false
  pnp_queried = [bool]$false
  live_hil_performed = [bool]$false
  check_count = $checks.Count
  failure_count = $failures.Count
  checks = $checks.ToArray()
  failures = $failures.ToArray()
}

if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
  $EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
  if (Test-Path -LiteralPath $EvidenceDirectory) {
    throw "EvidenceDirectory must be fresh: $EvidenceDirectory"
  }
  $evidenceParent = Split-Path -Parent $EvidenceDirectory
  if (-not (Test-Path -LiteralPath $evidenceParent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $evidenceParent)
  }
  [void](New-Item -ItemType Directory -Path $EvidenceDirectory)
  Write-Utf8NoBom (Join-Path $EvidenceDirectory 'summary.json') `
      ($summary | ConvertTo-Json -Depth 12)
}

$summary | ConvertTo-Json -Depth 10
if ($status -eq 'PASS') { exit 0 }
exit 1
