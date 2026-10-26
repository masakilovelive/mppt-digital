[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$newline = [Environment]::NewLine

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $OutputDirectory = Join-Path $repo `
      "runs\high_speed\HS-G0-E220-HIL-RUNNER-CONTRACT-001\$stamp"
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite contract evidence: $OutputDirectory"
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)

$checks = [Collections.ArrayList]::new()
function Add-Check([string]$Name, [bool]$Valid, [string]$Detail) {
  [void]$checks.Add([pscustomobject][ordered]@{
    name=$Name;valid=$Valid;detail=$Detail
  })
}

function Get-Sha([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

$runnerPath = Join-Path $repo 'tools\run_e220_inventory_readonly_hil.ps1'
$candidateRoot = Join-Path $repo `
    'runs\candidates\R19-HS-G0-E220-INVENTORY-READONLY-003\20260915T123352981Z'
$sketchPath = Join-Path $repo `
    'vc_lora_e220_inventory_xiao_esp32s3\vc_lora_e220_inventory_xiao_esp32s3.ino'
$firmwareContractPath = Join-Path $repo `
    'tests\arduino_compile\check_e220_inventory_readonly_contract.ps1'
$groundCandidatePath = Join-Path $candidateRoot `
    'ground\firmware\vc_lora_e220_inventory_xiao_esp32s3.ino.bin'
$vehicleCandidatePath = Join-Path $candidateRoot `
    'vehicle\firmware\vc_lora_e220_inventory_xiao_esp32s3.ino.bin'

$pins = [ordered]@{
  sketch=@{path=$sketchPath;bytes=[int64]14399;sha256='55AD068AA520E568F3EEF11BED1F6FC8979CD95DCED35BF04573A2A41D73C7AC'}
  firmware_contract=@{path=$firmwareContractPath;bytes=[int64]12189;sha256='32249990E58B83CD974F70BD14DA7615D22D2D049153C452434E5C355D10E5B0'}
  ground_candidate=@{path=$groundCandidatePath;bytes=[int64]285952;sha256='213FAE16F449C005015D971669DFAD18E53730729DC14382AB81496680EAEAF8'}
  vehicle_candidate=@{path=$vehicleCandidatePath;bytes=[int64]285952;sha256='6DE15CF5085EFB7E66F9C5117E7DA8BFD01C04613129159CB6F87D7D4ADD0382'}
}
$pinFailures = [Collections.ArrayList]::new()
foreach ($entry in $pins.GetEnumerator()) {
  $pin = $entry.Value
  if (-not (Test-Path -LiteralPath $pin.path -PathType Leaf)) {
    [void]$pinFailures.Add("missing:$($entry.Key)")
    continue
  }
  $item = Get-Item -LiteralPath $pin.path
  $sha = Get-Sha $pin.path
  if ($item.Length -ne $pin.bytes -or $sha -cne $pin.sha256) {
    [void]$pinFailures.Add(
        "mismatch:$($entry.Key):$($item.Length):$sha")
  }
}
Add-Check 'candidate003_inputs_are_exact' ($pinFailures.Count -eq 0) `
    (@($pinFailures) -join ';')

if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
  Add-Check 'runner_exists' $false $runnerPath
} else {
  Add-Check 'runner_exists' $true $runnerPath
  $source = [IO.File]::ReadAllText($runnerPath)
  $tokens = $null
  $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile(
      $runnerPath, [ref]$tokens, [ref]$parseErrors)
  Add-Check 'runner_parses_without_error' (@($parseErrors).Count -eq 0) `
      (@($parseErrors) -join '; ')

  function Get-FunctionText([string]$Name) {
    $matches = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -ceq $Name
    }, $true))
    if ($matches.Count -ne 1) { return '' }
    $matches[0].Extent.Text
  }

  $pinText = Get-FunctionText 'Test-StaticPins'
  $stageText = Get-FunctionText 'Copy-ToLockedStage'
  $safeArgvText = Get-FunctionText 'Assert-SafeEspToolArgv'
  $nativeText = Get-FunctionText 'Invoke-BoundedNativeProcess'
  $clientText = Get-FunctionText 'Assert-NoCompetingClients'
  $identityText = Get-FunctionText 'Assert-RoleIdentity'
  $ownershipText = Get-FunctionText 'Test-ExclusiveSerialOwnership'
  $captureText = Get-FunctionText 'Invoke-InventoryCapture'
  $parseText = Get-FunctionText 'Convert-StrictInventoryLine'
  $profileText = Get-FunctionText 'Test-ExactAcceptedProfile'
  $roleText = Get-FunctionText 'Invoke-RoleInventory'
  $restoreText = Get-FunctionText 'Invoke-ProductionRestore'
  $finalVerifyText = Get-FunctionText 'Invoke-FinalDualVerify'
  $finalizeText = Get-FunctionText 'Complete-Evidence'
  $offlineText = Get-FunctionText 'Invoke-OfflineSelfTest'
  $runnerLockText = Get-FunctionText 'Lock-RunnerSource'

  $allRunnerPins = @(
    '55AD068AA520E568F3EEF11BED1F6FC8979CD95DCED35BF04573A2A41D73C7AC',
    '32249990E58B83CD974F70BD14DA7615D22D2D049153C452434E5C355D10E5B0',
    '213FAE16F449C005015D971669DFAD18E53730729DC14382AB81496680EAEAF8',
    '6DE15CF5085EFB7E66F9C5117E7DA8BFD01C04613129159CB6F87D7D4ADD0382',
    '9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52',
    '30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5',
    'A939E28FE2FBB53E65E46F0246A4D71B9FD6C052EF0E046182DF4A4FE8BEC946')
  $pinsPresent = $true
  foreach ($pin in $allRunnerPins) {
    if (-not $source.Contains($pin)) { $pinsPresent = $false }
  }
  Add-Check 'runner_exact_artifact_pins' (
      $pinsPresent -and
      $source -match 'R19-HS-G0-E220-INVENTORY-READONLY-003\\20260915T123352981Z' -and
      $source -match '(?s)groundCandidate.*285952' -and
      $source -match '(?s)vehicleCandidate.*285952' -and
      $source -match '(?s)groundRollback.*360208' -and
      $source -match '(?s)vehicleRollback.*389280' -and
      $source -match '(?s)espTool.*14323136' -and
      $pinText -match 'Assert-PinnedFile') `
      'candidate003 source/contract/apps, R18 dual rollback apps, esptool'

  Add-Check 'dual_device_identity_is_exact' (
      $source.Contains("port='COM3'") -and
      $source.Contains('USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000') -and
      $source.Contains('USB\VID_303A&PID_1001\90:70:69:11:81:A4') -and
      $source.Contains("mac='90:70:69:11:81:a4'") -and
      $source.Contains("port='COM6'") -and
      $source.Contains('USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000') -and
      $source.Contains('USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80') -and
      $source.Contains("mac='1c:db:d4:5a:83:80'") -and
      $identityText -match "status.*'OK'" -and
      $identityText -match 'config_manager_error_code') `
      'COM, interface PNP, parent identity, health, and efuse MAC'

  Add-Check 'inputs_and_runner_are_locked_before_live_path' (
      $stageText -match 'FileShare\]::Read' -and
      $stageText -match 'CreateNew' -and
      $runnerLockText -match 'runner\.executed\.ps1' -and
      $runnerLockText -match 'FileShare\]::Read' -and
      $source -match 'Assert-AllPinned' -and
      $source -match 'RunnerStartSha256') `
      'byte-exact locked stages and immutable executed-runner copy'

  Add-Check 'flash_argv_is_exact_app_only' (
      $safeArgvText -match '0x10000' -and
      $safeArgvText -match 'erase-flash|erase-all' -and
      $safeArgvText -match '0x8000' -and
      $safeArgvText -match '0xe000' -and
      $safeArgvText -match 'bootloader' -and
      $safeArgvText -match 'partitions' -and
      $safeArgvText -match 'merged' -and
      $safeArgvText -match 'exactly one application binary' -and
      $source -match "'write-flash','-z','--flash-mode','keep'" -and
      $source -match "'verify-flash','0x10000'") `
      'only one staged app at 0x10000; destructive/full-image tokens rejected'

  Add-Check 'all_native_processes_are_bounded' (
      $nativeText -match '60000' -and
      $nativeText -match 'RedirectStandardOutput' -and
      $nativeText -match 'RedirectStandardError' -and
      $nativeText -match 'ReadToEndAsync' -and
      $nativeText -match 'WaitForExit\(\$TimeoutMilliseconds\)' -and
      $nativeText -match '\.Kill\(' -and
      $source -notmatch '(?m)^\s*&\s+\$.*(?:espTool|stage_path)') `
      'esptool version/read/write/verify all return control to finally'

  Add-Check 'live_preflight_refuses_contention' (
      $clientText -match 'missionplanner\.exe' -and
      $clientText -match 'qgroundcontrol\.exe' -and
      $clientText -match 'COM3|COM6' -and
      $ownershipText -match 'DtrEnable\s*=\s*\$false' -and
      $ownershipText -match 'RtsEnable\s*=\s*\$false' -and
      $ownershipText -match '\.Open\(') `
      'process inventory plus exclusive-open probes with reset lines disabled'

  Add-Check 'serial_protocol_is_host_armed_and_strict' (
      $captureText -match '115200' -and
      $captureText -match 'RUN\s+\$nonce' -and
      $captureText -match 'ready' -and
      $captureText -match 'ack' -and
      $captureText -match 'configuration' -and
      $captureText -match 'product_information' -and
      $captureText -match 'complete' -and
      $captureText -match 'serial\.raw\.bin' -and
      $captureText -match 'serial\.events\.json' -and
      $parseText -match 'e220_inventory_v1' -and
      $parseText -match 'boot_nonce' -and
      $parseText -match 'nonce') `
      'READY/RUN/ACK and exact nonce/role/event-attributed raw capture'

  Add-Check 'accepted_profile_is_raw_host_verified' (
      $profileText -match 'C100080000E5C346000000' -and
      $profileText -match 'raw_length' -and
      $profileText -match 'request_accepted' -and
      $profileText -match 'aux_before_high' -and
      $profileText -match 'aux_after_high' -and
      $profileText -match 'valid' -and
      $profileText -match '0000E5C346000000') `
      'profile latch derives from exact raw bytes, never decoded claims alone'

  Add-Check 'unproven_profile_requires_physical_isolation' (
      $roleText -match 'profile_exact_proven' -and
      $roleText -match 'PHYSICAL_E220_ISOLATION_REQUIRED_BEFORE_R18_RESTORE' -and
      $roleText -match 'Invoke-ProductionRestore' -and
      $roleText -match '(?s)if\s*\(\$state\.profile_exact_proven\).*?Invoke-ProductionRestore.*?else.*?PHYSICAL_E220_ISOLATION_REQUIRED_BEFORE_R18_RESTORE' -and
      $source -match 'R18_BOOT_MAY_PERSIST_C0_ON_PROFILE_MISMATCH' -and
      $source -match 'physical_isolation_required') `
      'R18 auto-boot is forbidden when exact accepted profile is absent'

  $vehicleIndex = $source.IndexOf("Invoke-RoleInventory `$roles[0]",
      [StringComparison]::Ordinal)
  $groundIndex = $source.IndexOf("Invoke-RoleInventory `$roles[1]",
      [StringComparison]::Ordinal)
  $finalIndex = $source.IndexOf('Invoke-FinalDualVerify',
      [StringComparison]::Ordinal)
  Add-Check 'roles_are_sequential_with_immediate_restore' (
      $vehicleIndex -ge 0 -and $groundIndex -gt $vehicleIndex -and
      $finalIndex -gt $groundIndex -and
      $roleText -match 'FirmwareMayHaveChanged' -and
      $roleText -match 'RestoreVerified' -and
      $roleText -match 'return') `
      'Vehicle completes/restores before Ground mutation; final dual verify last'

  Add-Check 'restore_is_bounded_and_final_dual_verify_is_mandatory' (
      $restoreText -match 'MaxAttempts\s+3' -and
      $restoreText -match 'read_mac' -and
      $restoreText -match "'write'" -and
      $restoreText -match "'verify'" -and
      $restoreText -match 'RecoveryMode' -and
      $finalVerifyText -match 'foreach\s*\(\$role\s+in\s+\$roles\)' -and
      $finalVerifyText -match 'read_mac' -and
      $finalVerifyText -match 'verify' -and
      $source -match 'FINAL_DUAL_R18_VERIFY_PASS') `
      'three bounded recovery attempts per changed role plus final two-board proof'

  Add-Check 'offline_selftest_covers_safety_branches' (
      $offlineText -match 'profile_exact_auto_restore' -and
      $offlineText -match 'profile_mismatch_isolation_no_restore' -and
      $offlineText -match 'profile_unproven_isolation_no_restore' -and
      $offlineText -match 'wrong_nonce_rejected' -and
      $offlineText -match 'wrong_role_rejected' -and
      $offlineText -match 'duplicate_probe_rejected' -and
      $offlineText -match 'restore_retry_then_pass' -and
      $offlineText -match 'all_restore_attempts_fail' -and
      $offlineText -match 'final_dual_verify_required' -and
      $source -match '(?s)if\s*\(\$OfflineSelfTest\.IsPresent\).*?Invoke-OfflineSelfTest.*?exit\s+0.*?# Live device path starts below') `
      'fault fixtures execute before any process/PnP/COM/esptool path'

  Add-Check 'complete_evidence_has_full_seal_chain' (
      $finalizeText -match 'summary\.json' -and
      $finalizeText -match 'artifact_manifest\.json' -and
      $finalizeText -match 'SHA256SUMS\.txt' -and
      $finalizeText -match 'final_seal\.json' -and
      $finalizeText -match 'final_seal\.sha256' -and
      $finalizeText -match 'runner_sha256' -and
      $finalizeText -match 'candidate_source_sha256' -and
      $finalizeText -match 'firmware_contract_sha256' -and
      $finalizeText -match 'ground_candidate_sha256' -and
      $finalizeText -match 'vehicle_candidate_sha256' -and
      $finalizeText -match 'ground_r18_sha256' -and
      $finalizeText -match 'vehicle_r18_sha256' -and
      $finalizeText -match 'esptool_sha256') `
      'summary -> complete artifact list/sums -> pin-rich final seal -> self SHA'
}

$failed = @($checks | Where-Object {-not $_.valid})
$summary = [ordered]@{
  schema_version=1
  test_id='HS-G0-E220-HIL-RUNNER-CONTRACT-001'
  checked_utc=[DateTime]::UtcNow.ToString('o')
  result=if ($failed.Count -eq 0) {'PASS'} else {'FAIL'}
  runner_path=$runnerPath
  check_count=$checks.Count
  failed_count=$failed.Count
  checks=@($checks)
  external_actions=[ordered]@{
    device_access_attempted=$false
    process_inventory_queried=$false
    pnp_queried=$false
    com_ports_enumerated=$false
    com_ports_opened=$false
    esptool_executed=$false
    firmware_write_attempted=$false
  }
}
$summaryPath = Join-Path $OutputDirectory 'summary.json'
[IO.File]::WriteAllText($summaryPath,
    (ConvertTo-Json -InputObject $summary -Depth 16) + $newline, $utf8)

if ($failed.Count -ne 0) {
  foreach ($failure in $failed) {
    Write-Error "CONTRACT FAIL: $($failure.name): $($failure.detail)"
  }
  exit 1
}
Write-Output ("E220 INVENTORY READONLY HIL RUNNER CONTRACT PASS " +
    "checks=$($checks.Count) evidence=$OutputDirectory")
exit 0
