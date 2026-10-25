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
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Passed,
    [string]$Detail = ''
  )
  $checks.Add([pscustomobject][ordered]@{
      name = $Name
      passed = $Passed
      detail = $Detail
    })
  if (-not $Passed) {
    $failures.Add(('{0}: {1}' -f $Name, $Detail))
  }
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

function Test-HashManifest {
  param(
    [string]$Directory,
    [object]$Manifest,
    [string[]]$ExpectedNames
  )
  $entryNames = New-Object 'System.Collections.Generic.List[string]'
  $valid = $true
  foreach ($entry in @($Manifest.files)) {
    $entryNames.Add([string]$entry.file)
    $path = Join-Path $Directory ([string]$entry.file)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      $valid = $false
      continue
    }
    $item = Get-Item -LiteralPath $path
    if ([long]$item.Length -ne [long]$entry.size_bytes -or
        (Get-Sha256 -Path $path) -ne [string]$entry.sha256) {
      $valid = $false
    }
  }
  $actualNames = @($entryNames.ToArray() | Sort-Object)
  $wantedNames = @($ExpectedNames | Sort-Object)
  if (($actualNames -join "`n") -ne ($wantedNames -join "`n")) {
    $valid = $false
  }
  return $valid
}

function Invoke-WrapperProcess {
  param(
    [string]$PowerShellPath,
    [string]$Wrapper,
    [string]$Executable,
    [string]$ArgumentsFile,
    [string]$ExpectedArgumentsSha256,
    [string]$BoundFile,
    [string]$ExpectedBoundFileSha256,
    [string]$OutputDirectory
  )
  $invokeArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Wrapper,
    '-ExecutablePath', $Executable,
    '-ArgumentsFile', $ArgumentsFile,
    '-ExpectedArgumentsFileSha256', $ExpectedArgumentsSha256,
    '-BoundFilePath', $BoundFile,
    '-ExpectedBoundFileSha256', $ExpectedBoundFileSha256,
    '-OutputDirectory', $OutputDirectory,
    '-Purpose', 'OFFLINE_DUMMY_CHILD_CONTRACT'
  )
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = (& $PowerShellPath @invokeArgs 2>&1 | Out-String)
    $observedExitCode = [int]$LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  return [pscustomobject][ordered]@{
    exit_code = $observedExitCode
    output = $output
  }
}

$wrapperExists = Test-Path -LiteralPath $WrapperPath -PathType Leaf
Add-Check -Name 'wrapper_exists' -Passed $wrapperExists -Detail $WrapperPath

$scratch = $null
try {
  if ($wrapperExists) {
    $source = Get-Content -Raw -LiteralPath $WrapperPath
    Add-Check -Name 'wrapper_uses_create_new' `
        -Passed ($source -match 'FileMode\]::CreateNew') `
        -Detail 'evidence writes must refuse overwrite'
    Add-Check -Name 'wrapper_waits_before_exit_capture' `
        -Passed ($source -match '\.WaitForExit\(' -and
                 $source -match 'actual_os_exit_code') `
        -Detail 'actual child exit must be captured after wait'
    Add-Check -Name 'wrapper_streams_pollable_logs_hidden' `
        -Passed ($source -match 'CopyToAsync' -and
                 $source -match 'RedirectStandardOutput' -and
                 $source -match 'RedirectStandardError' -and
                 $source -match 'ProcessWindowStyle\]::Hidden' -and
                 $source -match 'CreateNoWindow\s*=\s*\$true' -and
                 $source -match 'logs_streamed_during_child_lifetime') `
        -Detail 'live coordinator can poll stdout/stderr without a visible window'
    Add-Check -Name 'wrapper_has_explicit_false_booleans' `
        -Passed ($source -match '\[bool\]\$false') `
        -Detail 'PS5.1 JSON booleans must not be nested script blocks'
    Add-Check -Name 'wrapper_has_manifest_and_seal' `
        -Passed ($source -match 'artifact_manifest\.json' -and
                 $source -match 'manifest\.json' -and
                 $source -match 'final_seal\.json' -and
                 $source -match 'final_seal\.sha256') `
        -Detail 'summary/manifest/seal/sidecar lifecycle'
    Add-Check -Name 'wrapper_has_no_hardware_api' `
        -Passed (-not ($source -match
            'System\.IO\.Ports|SerialPort|Get-PnpDevice|Win32_SerialPort|esptool|arduino-cli|Disable-PnpDevice|Enable-PnpDevice')) `
        -Detail 'wrapper itself must not touch COM, PnP, upload, or power APIs'
    Add-Check -Name 'wrapper_is_runner_independent' `
        -Passed (-not ($source -match
            'run_dual_diag_param_list_hil|check_dual_diag_param_list_runner_contract')) `
        -Detail 'runner/checker are supplied only as hash-bound external inputs'

    $powerShellPath = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    Add-Check -Name 'windows_powershell_5_available' `
        -Passed (Test-Path -LiteralPath $powerShellPath -PathType Leaf) `
        -Detail $powerShellPath

    $tempBase = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $scratch = Join-Path $tempBase `
        ('vc_launch_contract_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $scratch -ErrorAction Stop)

    $dummyPath = Join-Path $scratch 'dummy_child.ps1'
    $dummySource = @'
param(
  [int]$ExitCode = 0,
  [int]$DelayMs = 0,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Remaining
)
[Console]::Out.WriteLine('DUMMY_STDOUT_BEGIN')
[Console]::Out.Flush()
if ($DelayMs -gt 0) {
  Start-Sleep -Milliseconds $DelayMs
}
[Console]::Out.WriteLine(($Remaining | ConvertTo-Json -Compress))
[Console]::Error.WriteLine('DUMMY_STDERR_EXACT')
exit $ExitCode
'@
    Write-Utf8NoBom -Path $dummyPath -Text $dummySource
    $dummyHash = Get-Sha256 -Path $dummyPath

    $trickyArguments = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath,
      '-ExitCode', '7', '-DelayMs', '0',
      'alpha', 'space value', 'quote"value', 'trailing\'
    )
    $argumentsPath = Join-Path $scratch 'child_arguments.json'
    Write-Utf8NoBom -Path $argumentsPath `
        -Text ($trickyArguments | ConvertTo-Json -Depth 4)
    $argumentsHash = Get-Sha256 -Path $argumentsPath

    $nonzeroRoot = Join-Path $scratch 'nonzero.launch'
    $nonzero = Invoke-WrapperProcess -PowerShellPath $powerShellPath `
        -Wrapper $WrapperPath -Executable $powerShellPath `
        -ArgumentsFile $argumentsPath `
        -ExpectedArgumentsSha256 $argumentsHash -BoundFile $dummyPath `
        -ExpectedBoundFileSha256 $dummyHash -OutputDirectory $nonzeroRoot
    Add-Check -Name 'child_nonzero_propagated' `
        -Passed ($nonzero.exit_code -eq 7) `
        -Detail ('wrapper exit={0}' -f $nonzero.exit_code)

    $expectedRootFiles = @(
      'artifact_manifest.json', 'final_seal.json', 'final_seal.sha256',
      'launch.argv.json', 'launch.pid.txt', 'launch.preflight.json',
      'launch.stderr.log', 'launch.stdout.log', 'manifest.json',
      'manifest.sha256', 'process_lifecycle.json', 'summary.json'
    )
    $actualRootFiles = @(
      Get-ChildItem -LiteralPath $nonzeroRoot -File |
        Select-Object -ExpandProperty Name | Sort-Object)
    Add-Check -Name 'exact_root_inventory' `
        -Passed (($actualRootFiles -join "`n") -eq
                 (@($expectedRootFiles | Sort-Object) -join "`n")) `
        -Detail ('files={0}' -f $actualRootFiles.Count)

    $preflightRaw = Get-Content -Raw `
        (Join-Path $nonzeroRoot 'launch.preflight.json')
    $preflight = $preflightRaw | ConvertFrom-Json
    $booleansValid = (
      $preflight.launcher_external_actions.power_cycle -is [bool] -and
      -not $preflight.launcher_external_actions.power_cycle -and
      $preflight.launcher_external_actions.upload -is [bool] -and
      -not $preflight.launcher_external_actions.upload -and
      $preflight.launcher_external_actions.com_open_by_launcher -is [bool] -and
      -not $preflight.launcher_external_actions.com_open_by_launcher -and
      $preflightRaw -match '"power_cycle"\s*:\s*false' -and
      $preflightRaw -match '"upload"\s*:\s*false' -and
      $preflightRaw -match '"com_open_by_launcher"\s*:\s*false')
    Add-Check -Name 'ps51_external_actions_are_false_booleans' `
        -Passed $booleansValid `
        -Detail 'raw JSON and ConvertFrom-Json runtime types checked'

    $lifecycle = Get-Content -Raw `
        (Join-Path $nonzeroRoot 'process_lifecycle.json') |
        ConvertFrom-Json
    $summary = Get-Content -Raw (Join-Path $nonzeroRoot 'summary.json') |
        ConvertFrom-Json
    $exitDurable = (
      $lifecycle.wait_completed -and
      $lifecycle.actual_os_exit_code_captured -and
      [int]$lifecycle.actual_os_exit_code -eq 7 -and
      [int]$summary.child_actual_os_exit_code -eq 7)
    Add-Check -Name 'actual_os_exit_code_durable_after_wait' `
        -Passed $exitDurable `
        -Detail ('lifecycle={0}, summary={1}' -f
          $lifecycle.actual_os_exit_code, $summary.child_actual_os_exit_code)

    $stdout = Get-Content -Raw (Join-Path $nonzeroRoot 'launch.stdout.log')
    $stderr = Get-Content -Raw (Join-Path $nonzeroRoot 'launch.stderr.log')
    $stdoutLines = @($stdout -split "`r?`n" | Where-Object { $_ -ne '' })
    $receivedArgs = if ($stdoutLines.Count -ge 2) {
      @($stdoutLines[1] | ConvertFrom-Json)
    } else {
      @()
    }
    $expectedRemaining = @('alpha', 'space value', 'quote"value', 'trailing\')
    Add-Check -Name 'stdout_stderr_and_argument_transport' `
        -Passed ($stdoutLines[0] -eq 'DUMMY_STDOUT_BEGIN' -and
                 $stderr.Trim() -eq 'DUMMY_STDERR_EXACT' -and
                 ($receivedArgs -join "`n") -eq
                 ($expectedRemaining -join "`n")) `
        -Detail 'spaces, quote, and trailing backslash preserved'

    $pidText = (Get-Content -Raw (Join-Path $nonzeroRoot 'launch.pid.txt')).Trim()
    Add-Check -Name 'pid_is_durable_integer' `
        -Passed ($pidText -match '^\d+$' -and [int64]$pidText -gt 0) `
        -Detail $pidText

    $artifactManifest = Get-Content -Raw `
        (Join-Path $nonzeroRoot 'artifact_manifest.json') |
        ConvertFrom-Json
    $coveredNames = @(
      'launch.argv.json', 'launch.pid.txt', 'launch.preflight.json',
      'launch.stderr.log', 'launch.stdout.log',
      'process_lifecycle.json', 'summary.json')
    Add-Check -Name 'runtime_artifact_coverage_7_of_7' `
        -Passed ([int]$artifactManifest.covered_file_count -eq 7 -and
          (Test-HashManifest -Directory $nonzeroRoot `
            -Manifest $artifactManifest -ExpectedNames $coveredNames)) `
        -Detail 'argv/preflight/PID/stdout/stderr/lifecycle/summary'

    $manifestPath = Join-Path $nonzeroRoot 'manifest.json'
    $artifactManifestPath = Join-Path $nonzeroRoot 'artifact_manifest.json'
    $sealPath = Join-Path $nonzeroRoot 'final_seal.json'
    $manifestHash = Get-Sha256 -Path $manifestPath
    $artifactManifestHash = Get-Sha256 -Path $artifactManifestPath
    $sealHash = Get-Sha256 -Path $sealPath
    $seal = Get-Content -Raw $sealPath | ConvertFrom-Json
    $manifestSidecar = (Get-Content -Raw `
        (Join-Path $nonzeroRoot 'manifest.sha256')).Trim()
    $sealSidecar = (Get-Content -Raw `
        (Join-Path $nonzeroRoot 'final_seal.sha256')).Trim()
    $layeringValid = (
      $seal.manifest_sha256 -eq $manifestHash -and
      $seal.artifact_manifest_sha256 -eq $artifactManifestHash -and
      $manifestSidecar -eq "$manifestHash *manifest.json" -and
      $sealSidecar -eq "$sealHash *final_seal.json")
    Add-Check -Name 'manifest_seal_sidecars_exact' `
        -Passed $layeringValid `
        -Detail $sealHash

    $writtenArgvPath = Join-Path $nonzeroRoot 'launch.argv.json'
    $writtenArgvHash = Get-Sha256 -Path $writtenArgvPath
    $currentWrapperHash = Get-Sha256 -Path $WrapperPath
    Add-Check -Name 'runner_and_argv_hash_binding' `
        -Passed ($preflight.launcher.sha256 -eq $currentWrapperHash -and
                 $preflight.bound_file.sha256 -eq $dummyHash -and
                 [int]$preflight.bound_file.argument_occurrence_count -eq 1 -and
                 $preflight.arguments_file.sha256 -eq $argumentsHash -and
                 $writtenArgvHash -eq $argumentsHash) `
        -Detail 'bound file and exact argv source are hash checked before start'

    $sentinelRoot = Join-Path $scratch 'existing.launch'
    [void](New-Item -ItemType Directory -Path $sentinelRoot)
    $sentinelPath = Join-Path $sentinelRoot 'sentinel.bin'
    [System.IO.File]::WriteAllBytes($sentinelPath, [byte[]](1, 2, 3, 4))
    $sentinelBefore = Get-Sha256 -Path $sentinelPath
    $beforeNames = @(
      Get-ChildItem -LiteralPath $sentinelRoot -File |
        Select-Object -ExpandProperty Name | Sort-Object)
    $refusal = Invoke-WrapperProcess -PowerShellPath $powerShellPath `
        -Wrapper $WrapperPath -Executable $powerShellPath `
        -ArgumentsFile $argumentsPath `
        -ExpectedArgumentsSha256 $argumentsHash -BoundFile $dummyPath `
        -ExpectedBoundFileSha256 $dummyHash -OutputDirectory $sentinelRoot
    $afterNames = @(
      Get-ChildItem -LiteralPath $sentinelRoot -File |
        Select-Object -ExpandProperty Name | Sort-Object)
    Add-Check -Name 'fresh_output_refusal_is_nonmutating' `
        -Passed ($refusal.exit_code -ne 0 -and
                 (Get-Sha256 -Path $sentinelPath) -eq $sentinelBefore -and
                 ($beforeNames -join "`n") -eq ($afterNames -join "`n")) `
        -Detail ('exit={0}' -f $refusal.exit_code)

    $mismatchRoot = Join-Path $scratch 'mismatch.launch'
    $wrongHash = ('0' * 64)
    $mismatch = Invoke-WrapperProcess -PowerShellPath $powerShellPath `
        -Wrapper $WrapperPath -Executable $powerShellPath `
        -ArgumentsFile $argumentsPath `
        -ExpectedArgumentsSha256 $argumentsHash -BoundFile $dummyPath `
        -ExpectedBoundFileSha256 $wrongHash -OutputDirectory $mismatchRoot
    Add-Check -Name 'bound_hash_mismatch_refused_before_output' `
        -Passed ($mismatch.exit_code -ne 0 -and
                 -not (Test-Path -LiteralPath $mismatchRoot)) `
        -Detail ('exit={0}' -f $mismatch.exit_code)

    $argumentsMismatchRoot = Join-Path $scratch 'arguments-mismatch.launch'
    $argumentsMismatch = Invoke-WrapperProcess `
        -PowerShellPath $powerShellPath -Wrapper $WrapperPath `
        -Executable $powerShellPath -ArgumentsFile $argumentsPath `
        -ExpectedArgumentsSha256 $wrongHash -BoundFile $dummyPath `
        -ExpectedBoundFileSha256 $dummyHash `
        -OutputDirectory $argumentsMismatchRoot
    Add-Check -Name 'arguments_hash_mismatch_refused_before_output' `
        -Passed ($argumentsMismatch.exit_code -ne 0 -and
                 -not (Test-Path -LiteralPath $argumentsMismatchRoot)) `
        -Detail ('exit={0}' -f $argumentsMismatch.exit_code)

    $unboundArguments = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'exit 0')
    $unboundArgumentsPath = Join-Path $scratch 'unbound_arguments.json'
    Write-Utf8NoBom -Path $unboundArgumentsPath `
        -Text ($unboundArguments | ConvertTo-Json -Depth 4)
    $unboundArgumentsHash = Get-Sha256 -Path $unboundArgumentsPath
    $unboundRoot = Join-Path $scratch 'unbound.launch'
    $unbound = Invoke-WrapperProcess -PowerShellPath $powerShellPath `
        -Wrapper $WrapperPath -Executable $powerShellPath `
        -ArgumentsFile $unboundArgumentsPath `
        -ExpectedArgumentsSha256 $unboundArgumentsHash -BoundFile $dummyPath `
        -ExpectedBoundFileSha256 $dummyHash -OutputDirectory $unboundRoot
    Add-Check -Name 'bound_file_must_be_referenced_exactly_once' `
        -Passed ($unbound.exit_code -ne 0 -and
                 -not (Test-Path -LiteralPath $unboundRoot)) `
        -Detail ('exit={0}' -f $unbound.exit_code)

    $slowArguments = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath,
      '-ExitCode', '0', '-DelayMs', '2000', 'pollable-case')
    $slowArgumentsPath = Join-Path $scratch 'slow_arguments.json'
    Write-Utf8NoBom -Path $slowArgumentsPath `
        -Text ($slowArguments | ConvertTo-Json -Depth 4)
    $slowArgumentsHash = Get-Sha256 -Path $slowArgumentsPath
    $slowRoot = Join-Path $scratch 'slow.launch'
    $driverPath = Join-Path $scratch 'slow_driver.ps1'
    $escapeLiteral = {
      param([string]$Value)
      return "'" + $Value.Replace("'", "''") + "'"
    }
    $driverFormat = '& {0} -NoProfile -ExecutionPolicy Bypass -File {1} -ExecutablePath {0} -ArgumentsFile {2} -ExpectedArgumentsFileSha256 ''{3}'' -BoundFilePath {4} -ExpectedBoundFileSha256 ''{5}'' -OutputDirectory {6} -Purpose ''OFFLINE_POLLABLE_LOG_CONTRACT''; exit $LASTEXITCODE'
    $driverSource = $driverFormat -f
      (& $escapeLiteral $powerShellPath),
      (& $escapeLiteral $WrapperPath),
      (& $escapeLiteral $slowArgumentsPath),
      $slowArgumentsHash,
      (& $escapeLiteral $dummyPath),
      $dummyHash,
      (& $escapeLiteral $slowRoot)
    Write-Utf8NoBom -Path $driverPath -Text $driverSource
    $driverProcess = Start-Process -FilePath $powerShellPath `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass',
          '-File', $driverPath) -WindowStyle Hidden -PassThru
    $slowStdoutPath = Join-Path $slowRoot 'launch.stdout.log'
    $pollDeadline = [DateTime]::UtcNow.AddMilliseconds(1500)
    $observedBeforeExit = $false
    while ([DateTime]::UtcNow -lt $pollDeadline -and
           -not $driverProcess.HasExited) {
      if (Test-Path -LiteralPath $slowStdoutPath -PathType Leaf) {
        $pollText = Get-Content -Raw -LiteralPath $slowStdoutPath `
            -ErrorAction SilentlyContinue
        if ($pollText -match 'DUMMY_STDOUT_BEGIN') {
          $observedBeforeExit = $true
          break
        }
      }
      Start-Sleep -Milliseconds 25
    }
    $driverProcess.WaitForExit()
    Add-Check -Name 'stdout_pollable_before_child_exit' `
        -Passed ($observedBeforeExit -and $driverProcess.ExitCode -eq 0) `
        -Detail ('observed={0}, wrapper_exit={1}' -f
          $observedBeforeExit, $driverProcess.ExitCode)

    $zeroArguments = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath,
      '-ExitCode', '0', '-DelayMs', '0', 'zero-case')
    $zeroArgumentsPath = Join-Path $scratch 'zero_arguments.json'
    Write-Utf8NoBom -Path $zeroArgumentsPath `
        -Text ($zeroArguments | ConvertTo-Json -Depth 4)
    $zeroArgumentsHash = Get-Sha256 -Path $zeroArgumentsPath
    $zeroRoot = Join-Path $scratch 'zero.launch'
    $zero = Invoke-WrapperProcess -PowerShellPath $powerShellPath `
        -Wrapper $WrapperPath -Executable $powerShellPath `
        -ArgumentsFile $zeroArgumentsPath `
        -ExpectedArgumentsSha256 $zeroArgumentsHash -BoundFile $dummyPath `
        -ExpectedBoundFileSha256 $dummyHash -OutputDirectory $zeroRoot
    $zeroLifecyclePath = Join-Path $zeroRoot 'process_lifecycle.json'
    $zeroLife = if (Test-Path -LiteralPath $zeroLifecyclePath) {
      Get-Content -Raw $zeroLifecyclePath |
        ConvertFrom-Json
    } else {
      $null
    }
    Add-Check -Name 'child_zero_success_path' `
        -Passed ($zero.exit_code -eq 0 -and $null -ne $zeroLife -and
                 $zeroLife.actual_os_exit_code_captured -and
                 [int]$zeroLife.actual_os_exit_code -eq 0) `
        -Detail ('wrapper exit={0}' -f $zero.exit_code)
  }
} catch {
  Add-Check -Name 'checker_unhandled_exception' -Passed $false `
      -Detail $_.Exception.ToString()
} finally {
  if ($null -ne $scratch -and (Test-Path -LiteralPath $scratch)) {
    $tempBaseForDelete = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedScratch = [System.IO.Path]::GetFullPath($scratch)
    $leaf = Split-Path -Leaf $resolvedScratch
    if ($resolvedScratch.StartsWith(
          $tempBaseForDelete, [System.StringComparison]::OrdinalIgnoreCase) -and
        $leaf.StartsWith('vc_launch_contract_')) {
      [System.IO.Directory]::Delete($resolvedScratch, $true)
    } else {
      Add-Check -Name 'scratch_cleanup_scope' -Passed $false `
          -Detail $resolvedScratch
    }
  }
}

$status = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
$summary = [pscustomobject][ordered]@{
  schema_version = 1
  contract_id = 'EVIDENCE-BOUND-CHILD-LAUNCHER-CONTRACT-001'
  status = $status
  checked_utc = [DateTime]::UtcNow.ToString('o')
  wrapper_path = $WrapperPath
  wrapper_exists = $wrapperExists
  wrapper_sha256 = if ($wrapperExists) { Get-Sha256 -Path $WrapperPath } else { $null }
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
  $EvidenceDirectory = [System.IO.Path]::GetFullPath($EvidenceDirectory)
  if (Test-Path -LiteralPath $EvidenceDirectory) {
    throw "EvidenceDirectory must be fresh: $EvidenceDirectory"
  }
  $parent = Split-Path -Parent $EvidenceDirectory
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $parent -ErrorAction Stop)
  }
  [void](New-Item -ItemType Directory -Path $EvidenceDirectory `
      -ErrorAction Stop)
  Write-Utf8NoBom -Path (Join-Path $EvidenceDirectory 'summary.json') `
      -Text ($summary | ConvertTo-Json -Depth 12)
}

$summary | ConvertTo-Json -Depth 5
if ($status -eq 'PASS') { exit 0 }
exit 1
