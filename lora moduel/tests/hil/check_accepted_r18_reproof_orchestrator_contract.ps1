[CmdletBinding()]
param(
  [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$testId = 'ACCEPTED-R18-REPROOF-ORCHESTRATOR-CONTRACT-001'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $scriptPath = $MyInvocation.MyCommand.Path
  if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    throw "$testId`: script path is unavailable"
  }
  $RepoRoot = Split-Path -Parent `
      (Split-Path -Parent (Split-Path -Parent $scriptPath))
}
$repo = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
$runner = Join-Path $repo 'tools\invoke_accepted_r18_reproof_hil.ps1'

function Assert-Contract([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "$testId`: $Message" }
}

function Get-TextSha256([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    (($sha.ComputeHash($bytes) | ForEach-Object {
      $_.ToString('x2')
    }) -join '').ToUpperInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Invoke-IsolatedPowerShell([string]$Executable,
                                   [string[]]$ArgumentList) {
  $quotedArguments = @($ArgumentList | ForEach-Object {
    '"' + ([string]$_).Replace('"','\"') + '"'
  }) -join ' '
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = $Executable
  $startInfo.Arguments = $quotedArguments
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $child = New-Object Diagnostics.Process
  $child.StartInfo = $startInfo
  try {
    Assert-Contract ($child.Start()) 'could not start isolated PowerShell child'
    $stdout = $child.StandardOutput.ReadToEnd()
    $stderr = $child.StandardError.ReadToEnd()
    $child.WaitForExit()
    [pscustomobject][ordered]@{
      exit_code=[int]$child.ExitCode
      stdout=$stdout
      stderr=$stderr
    }
  } finally {
    $child.Dispose()
  }
}

function Assert-SealedEvidence([string]$Directory) {
  $summaryPath = Join-Path $Directory 'summary.json'
  $sumsPath = Join-Path $Directory 'SHA256SUMS.txt'
  $sealPath = Join-Path $Directory 'final_seal.json'
  foreach ($path in @($summaryPath,$sumsPath,$sealPath)) {
    Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) `
        "sealed evidence file is missing: $path"
  }
  $seal = Get-Content -LiteralPath $sealPath -Raw | ConvertFrom-Json
  Assert-Contract ([string]$seal.summary_sha256 -ceq
      (Get-FileHash -LiteralPath $summaryPath -Algorithm SHA256).Hash) `
      'final seal summary digest mismatch'
  Assert-Contract ([string]$seal.sha256sums_sha256 -ceq
      (Get-FileHash -LiteralPath $sumsPath -Algorithm SHA256).Hash) `
      'final seal SHA256SUMS digest mismatch'
  $sumLines = @(Get-Content -LiteralPath $sumsPath | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
  })
  Assert-Contract ($sumLines.Count -gt 0) 'SHA256SUMS is empty'
  $manifestPaths = New-Object 'Collections.Generic.List[string]'
  $manifestPathSet = New-Object 'Collections.Generic.HashSet[string]' `
      ([StringComparer]::OrdinalIgnoreCase)
  foreach ($line in $sumLines) {
    $match = [regex]::Match($line, '^([A-F0-9]{64})  (.+)$')
    Assert-Contract $match.Success "malformed SHA256SUMS line: $line"
    $manifestRelative = $match.Groups[2].Value.Replace('\','/')
    Assert-Contract (-not [IO.Path]::IsPathRooted($manifestRelative) -and
        $manifestRelative -notmatch '(^|/)\.\.(/|$)') `
        "unsafe SHA256SUMS path: $manifestRelative"
    Assert-Contract ($manifestPathSet.Add($manifestRelative)) `
        "duplicate SHA256SUMS path: $manifestRelative"
    [void]$manifestPaths.Add($manifestRelative)
    $relative = $manifestRelative.Replace('/',
        [IO.Path]::DirectorySeparatorChar)
    $file = Join-Path $Directory $relative
    Assert-Contract (Test-Path -LiteralPath $file -PathType Leaf) `
        "SHA256SUMS target is missing: $relative"
    Assert-Contract ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash `
        -ceq $match.Groups[1].Value) `
        "SHA256SUMS digest mismatch: $relative"
  }
  $root = (Resolve-Path -LiteralPath $Directory).Path.TrimEnd(
      [char[]]@('\','/'))
  $actualPaths = @(Get-ChildItem -LiteralPath $root -File -Recurse |
    ForEach-Object {
      $_.FullName.Substring($root.Length).TrimStart(
          [char[]]@('\','/')).Replace('\','/')
    } | Where-Object {$_ -notin @('SHA256SUMS.txt','final_seal.json')})
  $actualPathSet = New-Object 'Collections.Generic.HashSet[string]' `
      ([StringComparer]::OrdinalIgnoreCase)
  foreach ($relative in $actualPaths) { [void]$actualPathSet.Add($relative) }
  Assert-Contract ($actualPaths.Count -eq $actualPathSet.Count) `
      'actual evidence contains case-insensitive duplicate paths'
  Assert-Contract ($manifestPaths.Count -eq $actualPaths.Count) `
      'manifest and actual evidence file counts differ'
  foreach ($relative in $manifestPaths) {
    Assert-Contract ($actualPathSet.Contains($relative)) `
        "manifest path set differs from actual evidence: $relative"
  }
  $canonicalPaths = [string[]]@($manifestPaths)
  [Array]::Sort($canonicalPaths,[StringComparer]::Ordinal)
  $canonicalPathText = ($canonicalPaths -join "`n") + "`n"
  Assert-Contract ([int]$seal.manifest_entry_count -eq
      $manifestPaths.Count) 'final seal manifest entry count mismatch'
  Assert-Contract ([string]$seal.manifest_path_set_sha256 -ceq
      (Get-TextSha256 $canonicalPathText)) `
      'final seal manifest path-set digest mismatch'
}

Assert-Contract (Test-Path -LiteralPath $runner -PathType Leaf) `
    "missing accepted R18 reproof orchestrator: $runner"
$source = Get-Content -LiteralPath $runner -Raw

foreach ($pattern in @(
    'vc-lora-accepted-r18-reproof-evidence-v1',
    'VERIFY_ACCEPTED_R18_AND_RESTORE_PROVEN_MISMATCH_ONE_RUN',
    'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED',
    'authorization_consumed',
    'authorization_reusable',
    '9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52',
    '30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5',
    '90:70:69:11:81:a4',
    '1c:db:d4:5a:83:80',
    'COM3', 'COM6', '0x10000', '5\.3\.1',
    'A939E28FE2FBB53E65E46F0246A4D71B9FD6C052EF0E046182DF4A4FE8BEC946',
    'read-flash', 'write-flash', 'verify-flash',
    'mismatch_proven', 'restore_attempted', 'restore_succeeded',
    'reenumeration_attempted', 'reenumeration_proven',
    'device_targeting_operation_entered',
    'device_targeting_operation_attempted',
    'application_liveness_proven',
    'application_liveness_required_for_flash_content_reproof',
    'hard_reset_requested',
    'exact_usb_role_present',
    'PASS_EXACT_USB_ROLE_PRESENT_AFTER_HARD_RESET_REQUEST',
    'Invoke-DeviceEspTool',
    'Invoke-CapturedProcess',
    'vc-lora-esptool-process-result-v1',
    'pinned_verify_attempted',
    'pinned_verify_matched',
    '--no-stub',
    '--no-progress',
    '115200',
    'FAIL_EXACT_USB_ROLE_REENUMERATION_UNPROVEN_POWER_OFF_REQUIRED',
    'FAIL_DEVICE_TARGETING_OPERATION_EXACT_USB_ROLE_PROVEN_NO_WRITE',
    'emergency_terminal\.json',
    'process_gate', 'identity', 'SHA256SUMS\.txt', 'final_seal\.json')) {
  Assert-Contract ($source -match $pattern) "missing contract pattern: $pattern"
}
Assert-Contract ($source -notmatch 'erase-flash|bootloader\.bin|partitions\.bin|merged\.bin') `
    'forbidden non-application flash token is present'
Assert-Contract ($source -notmatch 'Invoke-Expression|\biex\b') `
    'constructed shell execution is forbidden'
Assert-Contract ($source -notmatch '\$global:LASTEXITCODE') `
    'native process status must not depend on global LASTEXITCODE'
Assert-Contract ($source -notmatch
    '(?s)if\s*\([^\)]*failure[^\)]*\)\s*\{\s*255\s*\}') `
    'synthetic exit 255 is forbidden'
Assert-Contract ($source -match
    '(?s)if\s*\(\$Kind\s+-ceq\s+''read_flash''\).*?--baud'',''115200''.*?--no-stub.*?read-flash.*?--no-progress') `
    'readback is not pinned to no-stub, 115200, and no-progress'
$writeGateStart = $source.IndexOf('# BEGIN_PROVEN_MISMATCH_WRITE_GATE',
    [StringComparison]::Ordinal)
$writeGateEnd = $source.IndexOf('# END_PROVEN_MISMATCH_WRITE_GATE',
    [StringComparison]::Ordinal)
$writeAttemptFlag = $source.IndexOf(
    '$script:ExternalActions.firmware_write_attempted',
    [StringComparison]::Ordinal)
Assert-Contract ($writeGateStart -ge 0 -and $writeGateEnd -gt $writeGateStart -and
    $writeAttemptFlag -gt $writeGateEnd) `
    'proven-mismatch write gate must run before any write-attempt flag'
$writeGateSource = $source.Substring($writeGateStart,
    ($writeGateEnd - $writeGateStart))
foreach ($gatePattern in @(
    'DeviceRecord\.readback_succeeded',
    'DeviceRecord\.mismatch_proven',
    'DeviceRecord\.readback_sha256',
    'DeviceRecord\.expected_application_sha256',
    'Assert-Condition')) {
  Assert-Contract ($writeGateSource -match $gatePattern) `
      "write gate is missing: $gatePattern"
}
Assert-Contract ($source -notmatch
    '(?i)RETURN_TO_APPLICATION|application[_ -]?return') `
    'USB re-enumeration must not be described as application return'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $runner, [ref]$tokens, [ref]$errors)
Assert-Contract (@($errors).Count -eq 0) 'runner does not parse cleanly'

$readAndProve = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Read-And-ProveRole'
}, $true))
$deviceWrapper = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Invoke-DeviceEspTool'
}, $true))
$argumentConverter = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'ConvertTo-ProcessArgument'
}, $true))
Assert-Contract ($readAndProve.Count -eq 1 -and $deviceWrapper.Count -eq 1) `
    'device-operation safety functions are missing or duplicated'
Assert-Contract ($argumentConverter.Count -eq 1) `
    'process argument converter is missing or duplicated'
$readText = $readAndProve[0].Extent.Text
$wrapperText = $deviceWrapper[0].Extent.Text
Assert-Contract ([regex]::Matches($readText,
    '\bInvoke-DeviceEspTool\b').Count -eq 7 -and
    [regex]::Matches($readText, '\bInvoke-EspTool\b').Count -eq 0) `
    'not every role-targeting esptool operation uses the re-enumeration wrapper'
Assert-Contract ($wrapperText -match
    '(?s)Invoke-EspTool.*Wait-RoleIdentity.*Write-DurableJson.*reenumeration' -and
    $wrapperText -match
      'EXACT_USB_ROLE_REENUMERATION_UNPROVEN_AFTER_DEVICE_TARGETING_OPERATION') `
    'device wrapper does not durably record exact USB role presence before failure'
Assert-Contract ($source -match
    '(?s)function\s+Write-EmergencyTerminal.*emergency_terminal\.json.*emergency_terminal\.sha256' -and
    $source -match
      '(?s)catch\s*\{.*Write-EmergencyTerminal.*exit\s+1' -and
    $source -match
      '(?s)VC_LORA_UNAVOIDABLE_TERMINAL_MARKER.*FAIL_EMERGENCY_TERMINAL_WRITE_POWER_OFF_REQUIRED.*exit\s+2') `
    'normal finalization failure is not protected by an emergency terminal record'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('vc lora R18 spaced contract ' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
  $hostExecutable = if ($PSVersionTable.PSEdition -ceq 'Desktop') {
    Join-Path $PSHOME 'powershell.exe'
  } else {
    Join-Path $PSHOME 'pwsh.exe'
  }
  Assert-Contract (Test-Path -LiteralPath $hostExecutable -PathType Leaf) `
      'current PowerShell host executable is unavailable'
  Invoke-Expression $argumentConverter[0].Extent.Text
  $argumentEcho = Join-Path $fixtureRoot 'argument echo spaced path.ps1'
  $argumentEchoSource = @'
param([Parameter(Position=0,ValueFromRemainingArguments=$true)][string[]]$Values)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.Write((ConvertTo-Json -InputObject @($Values) -Compress))
'@
  [IO.File]::WriteAllText($argumentEcho,$argumentEchoSource,
      [Text.UTF8Encoding]::new($false))
  $quotedProbeValues = [string[]]@('', 'plain',
    'C:\dir with space\file.bin', 'C:\dir with space\tail\',
    'C:\quoted path\a\"b\\tail', 'unicode-free spaced value')
  $quotedProbeArgv = [string[]]@('-NoLogo','-NoProfile','-NonInteractive',
      '-ExecutionPolicy','Bypass','-File',$argumentEcho) +
      $quotedProbeValues
  $probeStart = New-Object Diagnostics.ProcessStartInfo
  $probeStart.FileName = $hostExecutable
  $probeStart.Arguments = (@($quotedProbeArgv | ForEach-Object {
    ConvertTo-ProcessArgument ([string]$_)
  }) -join ' ')
  $probeStart.UseShellExecute = $false
  $probeStart.CreateNoWindow = $true
  $probeStart.RedirectStandardOutput = $true
  $probeStart.RedirectStandardError = $true
  if ($null -ne $probeStart.PSObject.Properties['StandardOutputEncoding']) {
    $probeStart.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $probeStart.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  }
  $probe = New-Object Diagnostics.Process
  $probe.StartInfo = $probeStart
  try {
    Assert-Contract ($probe.Start()) 'could not start quoting probe'
    $probeStdout = $probe.StandardOutput.ReadToEnd()
    $probeStderr = $probe.StandardError.ReadToEnd()
    $probe.WaitForExit()
    Assert-Contract ($probe.ExitCode -eq 0) `
        "quoting probe failed: $probeStderr"
  } finally {
    $probe.Dispose()
  }
  $quotedRoundTrip = @((ConvertFrom-Json $probeStdout) |
    ForEach-Object {[string]$_})
  Assert-Contract ($quotedRoundTrip.Count -eq $quotedProbeValues.Count) `
      "quoted argument round-trip count mismatch: stdout=$probeStdout"
  for ($probeIndex=0;$probeIndex -lt $quotedProbeValues.Count;$probeIndex++) {
    Assert-Contract ($quotedRoundTrip[$probeIndex] -ceq
        $quotedProbeValues[$probeIndex]) `
        "quoted argument round-trip mismatch at $probeIndex"
  }
  $executedScenarioCount = 0
  $bothRoles = @('ground','vehicle')
  $vehicleRole = @('vehicle')
  $noRoles = @()
  $expected = @{
    both_match = @{ status='PASS_R18_ALREADY_ACCEPTED_BOTH'; writes=0; proven=0; ops=$bothRoles; present=$bothRoles }
    vehicle_mismatch = @{ status='PASS_R18_RESTORED_PROVEN_MISMATCH'; writes=1; proven=1; ops=$bothRoles; present=$bothRoles }
    ground_mismatch = @{ status='PASS_R18_RESTORED_PROVEN_MISMATCH'; writes=1; proven=1; ops=$bothRoles; present=$bothRoles }
    both_mismatch = @{ status='PASS_R18_RESTORED_PROVEN_MISMATCH'; writes=2; proven=2; ops=$bothRoles; present=$bothRoles }
    read_failure = @{
      status='FAIL_DEVICE_TARGETING_OPERATION_EXACT_USB_ROLE_PROVEN_NO_WRITE'
      writes=0; proven=0; power=$false; ops=$vehicleRole; present=$vehicleRole
    }
    identity_failure = @{ status='FAIL_IDENTITY_GATE_NO_DEVICE_TARGETING_OPERATION'; writes=0; proven=0; ops=$noRoles; present=$noRoles }
    restore_failure = @{ status='FAIL_RESTORE_PROVEN_MISMATCH_POWER_OFF_REQUIRED'; writes=1; proven=1; power=$true; ops=$vehicleRole; present=$vehicleRole }
    esptool_failure_reenumeration_success = @{
      status='FAIL_DEVICE_TARGETING_OPERATION_EXACT_USB_ROLE_PROVEN_NO_WRITE'
      writes=0; proven=0; power=$false; ops=$vehicleRole; present=$vehicleRole
    }
    esptool_failure_reenumeration_failure = @{
      status='FAIL_EXACT_USB_ROLE_REENUMERATION_UNPROVEN_POWER_OFF_REQUIRED'
      writes=0; proven=0; power=$true; ops=$vehicleRole; present=$noRoles
    }
    marker_failure_reenumeration_success = @{
      status='FAIL_DEVICE_TARGETING_OPERATION_EXACT_USB_ROLE_PROVEN_NO_WRITE'
      writes=0; proven=0; power=$false; ops=$vehicleRole; present=$vehicleRole
    }
    read_mac_mismatch_usb_role_proven = @{
      status='FAIL_DEVICE_TARGETING_OPERATION_EXACT_USB_ROLE_PROVEN_NO_WRITE'
      writes=0; proven=0; power=$false; ops=$vehicleRole; present=$vehicleRole
    }
  }
  foreach ($scenario in $expected.Keys) {
    $out = Join-Path $fixtureRoot $scenario
    $run = Invoke-IsolatedPowerShell $hostExecutable @(
      '-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
      '-File',$runner,
      '-RepoRoot',$repo,
      '-EvidenceDirectory',$out,
      '-Execute',
      '-HilAuthorization','VERIFY_ACCEPTED_R18_AND_RESTORE_PROVEN_MISMATCH_ONE_RUN',
      '-OperatorSafetyAttestation','PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED',
      '-OfflineContractTest','-OfflineScenario',$scenario)
    $want = $expected[$scenario]
    $expectedExit = if ([string]$want.status -match '^PASS_') {0}else{1}
    Assert-Contract ($run.exit_code -eq $expectedExit) `
        "$scenario exit mismatch: $($run.exit_code); stderr=$($run.stderr)"
    $executedScenarioCount++
    $summaryPath = Join-Path $out 'summary.json'
    $sealPath = Join-Path $out 'final_seal.json'
    $sumsPath = Join-Path $out 'SHA256SUMS.txt'
    Assert-Contract (Test-Path -LiteralPath $summaryPath -PathType Leaf) `
        "$scenario did not write summary.json"
    Assert-Contract (Test-Path -LiteralPath $sealPath -PathType Leaf) `
        "$scenario did not write final_seal.json"
    Assert-Contract (Test-Path -LiteralPath $sumsPath -PathType Leaf) `
        "$scenario did not write SHA256SUMS.txt"
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    Assert-Contract ([string]$summary.status -ceq [string]$want.status) `
        "$scenario status mismatch: $($summary.status)"
    Assert-Contract ([bool]$summary.authorization.consumed -and
        -not [bool]$summary.authorization.reusable) `
        "$scenario authorization was not one-run consumed/non-reusable"
    Assert-Contract (-not [bool]$summary.external_actions.device_access_attempted -and
        -not [bool]$summary.external_actions.process_inventory_queried -and
        -not [bool]$summary.external_actions.esptool_executed) `
        "$scenario offline seam reported hardware access"
    $roles = @($summary.roles)
    Assert-Contract ($roles.Count -eq 2 -and
        @($roles | Where-Object {$_.port -ceq 'COM3'}).Count -eq 1 -and
        @($roles | Where-Object {$_.port -ceq 'COM6'}).Count -eq 1) `
        "$scenario did not preserve exact role/port binding"
    Assert-Contract (-not [bool]$summary.application_liveness_proven -and
        -not [bool]$summary.application_liveness_required_for_flash_content_reproof -and
        @($roles | Where-Object {$_.application_liveness_proven}).Count -eq 0) `
        "$scenario overclaims application liveness"
    $anyEntered = @($roles | Where-Object {
      $_.device_targeting_operation_entered
    }).Count -gt 0
    $anyAttempted = @($roles | Where-Object {
      $_.device_targeting_operation_attempted
    }).Count -gt 0
    Assert-Contract ([bool]$summary.device_targeting_operation_entered -eq
        $anyEntered -and
        [bool]$summary.device_targeting_operation_attempted -eq
        $anyAttempted) "$scenario top-level/role operation state mismatch"
    Assert-Contract (@($roles | Where-Object {
          $_.device_targeting_operation_attempted -and
          -not $_.device_targeting_operation_entered
        }).Count -eq 0) "$scenario attempted without entered"
    $enteredRoles = @($roles | Where-Object {
      $_.device_targeting_operation_entered
    } | ForEach-Object {$_.key} | Sort-Object)
    $attemptedRoles = @($roles | Where-Object {
      $_.device_targeting_operation_attempted
    } | ForEach-Object {$_.key} | Sort-Object)
    $hardResetRoles = @($roles | Where-Object {
      $_.hard_reset_requested
    } | ForEach-Object {$_.key} | Sort-Object)
    $reenumerationAttemptedRoles = @($roles | Where-Object {
      $_.reenumeration_attempted
    } | ForEach-Object {$_.key} | Sort-Object)
    $presentRoles = @($roles | Where-Object {
      $_.exact_usb_role_present
    } | ForEach-Object {$_.key} | Sort-Object)
    $reenumerationProvenRoles = @($roles | Where-Object {
      $_.reenumeration_proven
    } | ForEach-Object {$_.key} | Sort-Object)
    $wantedOps = @($want.ops | Sort-Object)
    $wantedPresent = @($want.present | Sort-Object)
    foreach ($actual in @($enteredRoles,$attemptedRoles,$hardResetRoles,
        $reenumerationAttemptedRoles)) {
      Assert-Contract (($actual -join ',') -ceq ($wantedOps -join ',')) `
          "$scenario per-role operation state mismatch"
    }
    foreach ($actual in @($presentRoles,$reenumerationProvenRoles)) {
      Assert-Contract (($actual -join ',') -ceq
          ($wantedPresent -join ',')) `
          "$scenario exact USB role presence mismatch"
    }
    Assert-Contract (@($roles | Where-Object {$_.restore_attempted}).Count -eq
        [int]$want.writes) "$scenario restore-attempt count mismatch"
    Assert-Contract (@($roles | Where-Object {$_.mismatch_proven}).Count -eq
        [int]$want.proven) "$scenario proven-mismatch count mismatch"
    Assert-Contract (@($roles | Where-Object {
          $_.restore_attempted -and -not $_.mismatch_proven
        }).Count -eq 0) "$scenario wrote without a proven mismatch"
    if ($want.ContainsKey('power')) {
      Assert-Contract ([bool]$summary.power_off_required -eq
          [bool]$want.power) "$scenario power-off disposition mismatch"
    }
    Assert-SealedEvidence $out
  }

  $finalizationFailure = Join-Path $fixtureRoot `
      'write_then_finalization_failure'
  $finalizationRun = Invoke-IsolatedPowerShell $hostExecutable @(
    '-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File',$runner,
    '-RepoRoot',$repo,
    '-EvidenceDirectory',$finalizationFailure,
    '-Execute',
    '-HilAuthorization','VERIFY_ACCEPTED_R18_AND_RESTORE_PROVEN_MISMATCH_ONE_RUN',
    '-OperatorSafetyAttestation','PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED',
    '-OfflineContractTest','-OfflineScenario','write_then_finalization_failure')
  Assert-Contract ($finalizationRun.exit_code -eq 1) `
      "finalization failure exit mismatch: $($finalizationRun.exit_code)"
  $executedScenarioCount++
  $emergencyPath = Join-Path $finalizationFailure 'emergency_terminal.json'
  Assert-Contract (Test-Path -LiteralPath $emergencyPath -PathType Leaf) `
      'finalization failure did not preserve emergency_terminal.json'
  $emergency = Get-Content -LiteralPath $emergencyPath -Raw |
      ConvertFrom-Json
  Assert-Contract (
      [string]$emergency.status -ceq
        'FAIL_EVIDENCE_FINALIZATION_POWER_OFF_REQUIRED' -and
      [bool]$emergency.power_off_required -and
      [bool]$emergency.authorization_consumed -and
      -not [bool]$emergency.authorization_reusable -and
      [bool]$emergency.offline_simulated_device_execution -and
      [bool]$emergency.offline_simulated_write -and
      [bool]$emergency.device_targeting_operation_entered -and
      [bool]$emergency.device_targeting_operation_attempted -and
      -not [bool]$emergency.application_liveness_proven -and
      -not [bool]$emergency.application_liveness_required_for_flash_content_reproof -and
      -not [bool]$emergency.external_actions.device_access_attempted -and
      -not [bool]$emergency.external_actions.esptool_executed -and
      -not [bool]$emergency.external_actions.firmware_write_attempted) `
      'emergency terminal record does not preserve fail-closed semantics'
  $emergencyVehicle = @($emergency.roles | Where-Object {
    $_.key -ceq 'vehicle'
  })
  $emergencyGround = @($emergency.roles | Where-Object {
    $_.key -ceq 'ground'
  })
  Assert-Contract ($emergencyVehicle.Count -eq 1 -and
      [bool]$emergencyVehicle[0].hard_reset_requested -and
      [bool]$emergencyVehicle[0].exact_usb_role_present -and
      $emergencyGround.Count -eq 1 -and
      -not [bool]$emergencyGround[0].hard_reset_requested -and
      -not [bool]$emergencyGround[0].exact_usb_role_present) `
      'emergency terminal per-role USB state mismatch'
  Assert-Contract (Test-Path -LiteralPath `
      (Join-Path $finalizationFailure 'emergency_terminal.sha256') `
      -PathType Leaf) 'emergency terminal record is not independently hashed'
  $emergencyHashLine = Get-Content -LiteralPath (Join-Path `
      $finalizationFailure 'emergency_terminal.sha256') -Raw
  $emergencyHash = (Get-FileHash -LiteralPath $emergencyPath `
      -Algorithm SHA256).Hash
  Assert-Contract ($emergencyHashLine.Trim() -ceq
      "$emergencyHash  emergency_terminal.json") `
      'emergency terminal independent digest mismatch'

  $emergencyWriteFailure = Join-Path $fixtureRoot `
      'write_then_emergency_terminal_write_failure'
  $childArguments = @(
    '-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File',$runner,
    '-RepoRoot',$repo,
    '-EvidenceDirectory',$emergencyWriteFailure,
    '-Execute',
    '-HilAuthorization','VERIFY_ACCEPTED_R18_AND_RESTORE_PROVEN_MISMATCH_ONE_RUN',
    '-OperatorSafetyAttestation','PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED',
    '-OfflineContractTest',
    '-OfflineScenario','write_then_emergency_terminal_write_failure')
  $emergencyRun = Invoke-IsolatedPowerShell $hostExecutable $childArguments
  $emergencyExitCode = [int]$emergencyRun.exit_code
  $emergencyOutput = $emergencyRun.stdout + [Environment]::NewLine +
      $emergencyRun.stderr
  $executedScenarioCount++
  # Windows PowerShell 5.1 may hard-wrap native stderr in the middle of a
  # marker token. Whitespace removal preserves the exact semantic marker.
  $compactEmergencyOutput = $emergencyOutput -replace '\s',''
  Assert-Contract ($emergencyExitCode -eq 2) `
      "emergency-terminal write failure exit mismatch: $emergencyExitCode"
  foreach ($marker in @(
      'VC_LORA_UNAVOIDABLE_TERMINAL_MARKER',
      'POWER_OFF_REQUIRED',
      'status=FAIL_EMERGENCY_TERMINAL_WRITE_POWER_OFF_REQUIRED',
      'original_error=<none>',
      'finalization_error=OFFLINE_INJECTED_FINAL_SEAL_FAILURE_AFTER_WRITE',
      'emergency_error=OFFLINE_INJECTED_EMERGENCY_TERMINAL_WRITE_FAILURE')) {
    Assert-Contract ($compactEmergencyOutput.Contains(
        ($marker -replace '\s',''))) `
        "unavoidable emergency console marker lacks: $marker"
  }

  $dry = Join-Path $fixtureRoot 'dry_run'
  $dryRun = Invoke-IsolatedPowerShell $hostExecutable @(
    '-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File',$runner,'-RepoRoot',$repo,'-EvidenceDirectory',$dry)
  Assert-Contract ($dryRun.exit_code -eq 0) `
      "dry-run exit mismatch: $($dryRun.exit_code)"
  $drySummary = Get-Content -LiteralPath (Join-Path $dry 'summary.json') -Raw |
      ConvertFrom-Json
  Assert-Contract ([string]$drySummary.status -ceq 'DRY_RUN_NO_DEVICE_ACCESS' -and
      -not [bool]$drySummary.authorization.consumed -and
      -not [bool]$drySummary.external_actions.device_access_attempted) `
      'default invocation is not a sealed non-consuming dry run'
  Assert-SealedEvidence $dry
  $unmanifestedExtra = Join-Path $dry 'unmanifested extra file.txt'
  [IO.File]::WriteAllText($unmanifestedExtra,'must be rejected',
      [Text.UTF8Encoding]::new($false))
  $extraRejected = $false
  try {
    Assert-SealedEvidence $dry
  } catch {
    $extraRejected = $_.Exception.Message -match
        'manifest and actual evidence file counts differ'
  }
  Assert-Contract $extraRejected `
      'sealed evidence validator accepted an unmanifested extra file'
  Remove-Item -LiteralPath $unmanifestedExtra -Force
  $fakeEspTool = Join-Path $fixtureRoot 'fake_esptool.ps1'
  $fakeSource = @'
param(
  [string]$Scenario,
  [string]$Kind,
  [string]$Role,
  [string]$OutputFile,
  [string]$AcceptedFile,
  [string]$StateFile
)
$ErrorActionPreference = 'Stop'
if ($Kind -ceq 'version') {
  [Console]::Out.WriteLine('esptool v5.3.1')
  exit 0
}
if ($Kind -ceq 'read_mac') {
  $mac = if ($Role -ceq 'vehicle') {
    '90:70:69:11:81:a4'
  } else {
    '1c:db:d4:5a:83:80'
  }
  [Console]::Out.WriteLine("MAC:                $mac")
  [Console]::Out.WriteLine('Hard resetting via RTS pin...')
  exit 0
}
if ($Kind -ceq 'verify') {
  if ($Scenario -ceq 'fake_verify_match' -or
      $Role -ceq 'ground' -or (Test-Path -LiteralPath $StateFile)) {
    [Console]::Out.WriteLine('Verification successful (digest matched).')
    [Console]::Out.WriteLine('Hard resetting via RTS pin...')
    exit 0
  }
  [Console]::Error.WriteLine('A fatal error occurred: verify mismatch or transport failure')
  [Console]::Out.WriteLine('Hard resetting via RTS pin...')
  exit 9
}
if ($Kind -ceq 'write') {
  [IO.File]::WriteAllText($StateFile, 'restored')
  [Console]::Out.WriteLine('Hash of data verified.')
  [Console]::Out.WriteLine('Hard resetting via RTS pin...')
  exit 0
}
if ($Kind -cne 'read_flash') { exit 91 }
$bytes = [IO.File]::ReadAllBytes($AcceptedFile)
if ($Scenario -ceq 'fake_read_midstream_failure') {
  [IO.File]::WriteAllBytes($OutputFile, $bytes[0..102399])
  [Console]::Out.WriteLine('Reading from 0x00029000 [======> ] 26.3% 102400/389280 bytes...')
  [Console]::Out.WriteLine('Hard resetting via RTS pin...')
  [Console]::Error.WriteLine('A fatal error occurred: Serial data stream stopped: Possible serial noise or corruption.')
  exit 17
}
if ($Scenario -ceq 'fake_read_wrong_size_exit0') {
  [IO.File]::WriteAllBytes($OutputFile, $bytes[0..102399])
  [Console]::Out.WriteLine('Reading from 0x00029000 [==============================] 100.0% 102400/389280 bytes...')
  exit 0
}
if ($Scenario -ceq 'fake_read_full_mismatch' -and
    -not (Test-Path -LiteralPath $StateFile)) {
  $bytes[0] = $bytes[0] -bxor 1
}
[IO.File]::WriteAllBytes($OutputFile, $bytes)
[Console]::Out.WriteLine("Reading complete 100.0% $($bytes.Length)/$($bytes.Length) bytes...")
exit 0
'@
  [IO.File]::WriteAllText($fakeEspTool, $fakeSource,
      [Text.UTF8Encoding]::new($false))

  $fakeExpected = [ordered]@{
    fake_verify_match = @{
      status='PASS_R18_ALREADY_ACCEPTED_BOTH'; exit=0; writes=0
      readback=$false; matched=$true
    }
    fake_read_midstream_failure = @{
      status='FAIL_DEVICE_TARGETING_OPERATION_EXACT_USB_ROLE_PROVEN_NO_WRITE'
      exit=1; writes=0; readback=$true; process_exit=17; output_bytes=102400
    }
    fake_read_wrong_size_exit0 = @{
      status='FAIL_DEVICE_TARGETING_OPERATION_EXACT_USB_ROLE_PROVEN_NO_WRITE'
      exit=1; writes=0; readback=$true; process_exit=0; output_bytes=102400
    }
    fake_read_full_match = @{
      status='PASS_R18_ALREADY_ACCEPTED_BOTH'; exit=0; writes=0
      readback=$true; matched=$false; output_bytes=389280
    }
    fake_read_full_mismatch = @{
      status='PASS_R18_RESTORED_PROVEN_MISMATCH'; exit=0; writes=1
      readback=$true; matched=$false; output_bytes=389280
    }
    fake_direct_unproven_write = @{
      status='FAIL_DEVICE_TARGETING_OPERATION_EXACT_USB_ROLE_PROVEN_NO_WRITE'
      exit=1; writes=0; readback=$false; matched=$false
      direct_denied=$true
    }
    fake_read_full_match_spaced_paths = @{
      status='PASS_R18_ALREADY_ACCEPTED_BOTH'; exit=0; writes=0
      readback=$true; matched=$false; output_bytes=389280
    }
  }
  foreach ($scenario in $fakeExpected.Keys) {
    $outLeaf = if ($scenario -ceq 'fake_read_full_match_spaced_paths') {
      'fake evidence output with spaces'
    } else {$scenario}
    $out = Join-Path $fixtureRoot $outLeaf
    $run = Invoke-IsolatedPowerShell $hostExecutable @(
      '-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
      '-File',$runner,
      '-RepoRoot',$repo,
      '-EvidenceDirectory',$out,
      '-Execute',
      '-HilAuthorization','VERIFY_ACCEPTED_R18_AND_RESTORE_PROVEN_MISMATCH_ONE_RUN',
      '-OperatorSafetyAttestation','PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED',
      '-OfflineContractTest','-OfflineScenario',$scenario,
      '-OfflineFakeEspToolScript',$fakeEspTool)
    $want = $fakeExpected[$scenario]
    $executedScenarioCount++
    Assert-Contract ($run.exit_code -eq [int]$want.exit) `
        "$scenario fake-process exit mismatch: $($run.exit_code); stdout=$($run.stdout); stderr=$($run.stderr)"
    $summary = Get-Content -LiteralPath (Join-Path $out 'summary.json') -Raw |
        ConvertFrom-Json
    Assert-Contract ([string]$summary.status -ceq [string]$want.status) `
        "$scenario fake-process status mismatch: $($summary.status)"
    Assert-Contract (-not [bool]$summary.external_actions.device_access_attempted -and
        -not [bool]$summary.external_actions.process_inventory_queried -and
        -not [bool]$summary.external_actions.esptool_executed) `
        "$scenario fake-process touched or claimed hardware"
    Assert-Contract (@($summary.roles | Where-Object {
          $_.restore_attempted
        }).Count -eq [int]$want.writes) `
        "$scenario fake-process write count mismatch"
    Assert-Contract (@($summary.roles | Where-Object {
          $_.restore_attempted -and -not $_.mismatch_proven
        }).Count -eq 0) "$scenario fake-process wrote without proven mismatch"
    $vehicle = @($summary.roles | Where-Object {$_.key -ceq 'vehicle'})[0]
    Assert-Contract ([bool]$vehicle.pinned_verify_attempted) `
        "$scenario did not attempt pinned verify first"
    if ($want.ContainsKey('matched')) {
      Assert-Contract ([bool]$vehicle.pinned_verify_matched -eq
          [bool]$want.matched) "$scenario pinned verify disposition mismatch"
    }
    $readResults = @(Get-ChildItem -LiteralPath $out -File -Filter `
        '*readback.process_result.json' -ErrorAction SilentlyContinue)
    if ([bool]$want.readback) {
      Assert-Contract ($readResults.Count -ge 1) `
          "$scenario did not run fallback readback"
      $processResult = Get-Content -LiteralPath $readResults[0].FullName -Raw |
          ConvertFrom-Json
      Assert-Contract ([string]$processResult.schema -ceq
          'vc-lora-esptool-process-result-v1') `
          "$scenario process result schema mismatch"
      Assert-Contract ([string]$processResult.operation_kind -ceq 'read_flash' -and
          [string]$processResult.stub_mode -ceq 'rom_no_stub' -and
          [string]$processResult.baud -ceq '115200') `
          "$scenario process result transport metadata mismatch"
      Assert-Contract ($processResult.argv_sha256 -match '^[A-F0-9]{64}$' -and
          $processResult.stdout.sha256 -match '^[A-F0-9]{64}$' -and
          $processResult.stderr.sha256 -match '^[A-F0-9]{64}$' -and
          $null -ne $processResult.started_utc -and
          $null -ne $processResult.finished_utc) `
          "$scenario process result lacks durable diagnostics"
      if ($want.ContainsKey('process_exit')) {
        Assert-Contract ([int]$processResult.exit_code -eq
            [int]$want.process_exit) "$scenario true process exit was lost"
      }
      Assert-Contract ([int64]$processResult.output_file.bytes -eq
          [int64]$want.output_bytes) "$scenario output byte accounting mismatch"
      $reenumerationEvidencePath =
          [string]$processResult.reenumeration_evidence_path
      Assert-Contract $(Test-Path -LiteralPath $reenumerationEvidencePath `
          -PathType Leaf) `
          "$scenario process result lacks re-enumeration evidence link"
      $reenumerationEvidenceHash = (Get-FileHash -LiteralPath `
          $reenumerationEvidencePath -Algorithm SHA256).Hash
      Assert-Contract ($reenumerationEvidenceHash -ceq
          [string]$processResult.reenumeration_evidence_sha256) `
          "$scenario re-enumeration evidence hash mismatch"
      $operationResultPath = $readResults[0].FullName.Replace(
          '.process_result.json','.operation_result.json')
      Assert-Contract (Test-Path -LiteralPath $operationResultPath -PathType Leaf) `
          "$scenario operation result is missing"
      $operationResult = Get-Content -LiteralPath $operationResultPath -Raw |
          ConvertFrom-Json
      $processResultHash = (Get-FileHash -LiteralPath `
          $readResults[0].FullName -Algorithm SHA256).Hash
      Assert-Contract ([string]$operationResult.stub_mode -ceq 'rom_no_stub' -and
          [string]$operationResult.baud -ceq '115200' -and
          [string]$operationResult.process_result_sha256 -ceq
            $processResultHash -and
          [string]$operationResult.reenumeration_evidence_sha256 -ceq
            [string]$processResult.reenumeration_evidence_sha256) `
          "$scenario operation result linkage mismatch"
      if ($scenario -ceq 'fake_read_midstream_failure') {
        Assert-Contract ([int64]$processResult.last_progress.completed_bytes -eq
            102400 -and [int64]$processResult.last_progress.total_bytes -eq
            389280 -and [string]$processResult.last_progress.address -ceq
            '0x00029000' -and [int64]$processResult.stderr.bytes -gt 0) `
            'midstream failure diagnostics were not preserved'
      }
    } else {
      Assert-Contract ($readResults.Count -eq 0) `
          "$scenario did not skip bulk read after verify match"
    }
    Assert-Contract (@(Get-ChildItem -LiteralPath $out -File -Filter `
        'process_gate_*.json').Count -gt 0) `
        "$scenario did not preserve process gates"
    if ($want.ContainsKey('direct_denied')) {
      Assert-Contract ([string]$summary.failure_message -match
          'Write is forbidden without a successful full-length readback') `
          'direct unproven write did not fail at the in-function gate'
      $forbiddenProcessResults = @(Get-ChildItem -LiteralPath $out -File `
          -Filter '*forbidden_direct_write.process_result.json')
      $forbiddenWriteIntents = @(Get-ChildItem -LiteralPath $out -File `
          -Filter '*forbidden_direct_write.write_intent.json')
      $fakeRestoredState = Join-Path $out 'fake_vehicle_restored.state'
      Assert-Contract ($forbiddenProcessResults.Count -eq 0 -and
          $forbiddenWriteIntents.Count -eq 0 -and
          -not (Test-Path -LiteralPath $fakeRestoredState)) `
          'direct unproven write started a process or created write state'
    }
    Assert-SealedEvidence $out
  }
  Assert-Contract ($executedScenarioCount -eq 20) `
      "completed scenario count mismatch: $executedScenarioCount"
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
  }
}

[pscustomobject][ordered]@{
  schema='vc-lora-contract-test-result-v1'
  test_id=$testId
  status='PASS'
  scenarios=$executedScenarioCount
  manifest_negative_checks=1
  quoting_probe_values=6
  hardware_accessed=$false
} | ConvertTo-Json -Depth 6
