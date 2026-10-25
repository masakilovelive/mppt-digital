param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

# PowerShell 7 does not support Add-Type -OutputType ConsoleApplication on
# Windows.  The fixture below intentionally builds a native-looking fake CLI,
# so hand this contract to the in-box Desktop host before creating it.  CTest
# can still use pwsh for every contract which does not need that CodeDOM path.
if ($PSVersionTable.PSEdition -ne 'Desktop') {
  $desktopPowerShell = Join-Path $env:WINDIR `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (Test-Path -LiteralPath $desktopPowerShell -PathType Leaf) {
    & $desktopPowerShell -NoLogo -NoProfile -NonInteractive `
      -ExecutionPolicy Bypass -File $PSCommandPath -RepoRoot $RepoRoot
    exit $LASTEXITCODE
  }
}

$ErrorActionPreference = 'Stop'
$testId = 'FW-R19-CANDIDATE-ARTIFACT-BUILDER-001'
$buildId = 'FW-R19-CANDIDATE-ARTIFACT-BUILD-001'
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$toolNames = @(
  'r19_candidate_artifact_common.ps1',
  'build_r19_candidate_artifacts.ps1',
  'verify_r19_candidate_artifact.ps1',
  'read_r19_first_usb_failure_record.ps1'
)
$semanticCheckNames = @(
  'diagnostic_bootstrap_api_macro_scoped',
  'diagnostic_bootstrap_exact_63_byte_cold_start_only',
  'diagnostic_bootstrap_requires_clean_empty_boundary',
  'diagnostic_bootstrap_all_or_zero_publication_fence',
  'diagnostic_bootstrap_payload_primes_fifo_before_flush',
  'diagnostic_bootstrap_publishes_before_in_empty_enable',
  'diagnostic_bootstrap_rechecks_epoch_reset_and_presence',
  'diagnostic_bootstrap_isr_fence_before_ring_and_fifo',
  'diagnostic_bootstrap_serializes_debug_writer',
  'diagnostic_connected_requires_payload_pickup_witness',
  'diagnostic_flush_requires_payload_pickup_completion',
  'diagnostic_fifo_record_macro_scoped',
  'diagnostic_fifo_record_fixed_abi',
  'diagnostic_fifo_record_tracks_fifo_write_and_wr_done',
  'diagnostic_fifo_record_distinguishes_raw_in_empty_from_payload_pickup',
  'diagnostic_fifo_record_tracks_generation_reset_and_flush_outcome',
  'diagnostic_fifo_record_tracks_per_attempt_zlp_origins',
  'diagnostic_zlp_wr_done_origin_is_one_seqlock_transaction',
  'diagnostic_zlp_hardware_boundary_is_fail_closed',
  'diagnostic_zlp_invalid_post_state_is_fail_closed',
  'diagnostic_payload_wr_done_hardware_boundary_is_fail_closed',
  'diagnostic_fifo_write_hardware_boundary_is_fail_closed',
  'diagnostic_in_empty_side_effect_boundary_is_fail_closed',
  'diagnostic_bus_reset_and_raw_in_empty_boundary_is_fail_closed',
  'diagnostic_payload_causal_accounting_is_fail_closed',
  'diagnostic_flush_lifecycle_invalid_transition_is_fail_closed',
  'diagnostic_observation_window_matches_isr_lifecycle',
  'diagnostic_payload_publish_pending_closes_fifo_to_wrdone_gap',
  'diagnostic_payload_publish_abort_dominates_historical_success',
  'diagnostic_payload_flush_pending_binds_publication_to_new_flush_success',
  'in_empty_pickup_rechecks_bus_reset_under_mux',
  'late_pickup_reset_uses_raw_only_reset_discard',
  'postwrite_reset_quarantine_requires_positive_fifo_write',
  'zero_fifo_write_does_not_publish_payload'
)
$reproducibilityArtifactNames = @(
  'application.elf',
  'application.map',
  'build.options.json',
  'sdkconfig',
  'partitions.csv',
  'flash_args'
)

function Assert-Contract([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw "$testId $Message"
  }
}

function Write-FixtureText([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-TestSha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.
    ToUpperInvariant()
}

function Assert-ModeContract([object]$Record, [bool]$DiagnosticsEnabled,
                             [bool]$AcceptanceEligible,
                             [string]$Description) {
  Assert-Contract ($null -ne $Record -and
      $Record.PSObject.Properties['runtime_fail_diagnostics_enabled'] -and
      $Record.runtime_fail_diagnostics_enabled -is [bool] -and
      [bool]$Record.runtime_fail_diagnostics_enabled -eq
        $DiagnosticsEnabled) `
    "$Description runtime-fail diagnostic mode is absent or incorrect"
  Assert-Contract ($Record.PSObject.Properties['acceptance_authorized'] -and
      $Record.acceptance_authorized -is [bool] -and
      -not [bool]$Record.acceptance_authorized) `
    "$Description acceptance authorization is absent or incorrect"
  Assert-Contract ($Record.PSObject.Properties['acceptance_eligible'] -and
      $Record.acceptance_eligible -is [bool] -and
      [bool]$Record.acceptance_eligible -eq $AcceptanceEligible) `
    "$Description acceptance eligibility is absent or incorrect"
  Assert-Contract ($Record.PSObject.Properties['deployment_authorized'] -and
      $Record.deployment_authorized -is [bool] -and
      -not [bool]$Record.deployment_authorized) `
    "$Description deployment authorization is absent or not false"
}

function Assert-DiagnosticAbiContract([object]$Record,
                                      [string]$Description) {
  Assert-Contract ($Record.PSObject.Properties['endpoint_fifo_schema'] -and
      $Record.endpoint_fifo_schema -is [int] -and
      [int]$Record.endpoint_fifo_schema -eq 2) `
    "$Description endpoint_fifo_schema is absent or incorrect"
  Assert-Contract ($Record.PSObject.Properties['endpoint_fifo_size_bytes'] -and
      $Record.endpoint_fifo_size_bytes -is [int] -and
      [int]$Record.endpoint_fifo_size_bytes -eq 112) `
    "$Description endpoint_fifo_size_bytes is absent or incorrect"
  Assert-Contract ($Record.PSObject.Properties['runtime_stage_size_bytes'] -and
      $Record.runtime_stage_size_bytes -is [int] -and
      [int]$Record.runtime_stage_size_bytes -eq 68) `
    "$Description runtime_stage_size_bytes is absent or incorrect"
  Assert-Contract ($Record.PSObject.Properties['reader_schema'] -and
      $Record.reader_schema -is [string] -and
      [string]$Record.reader_schema -ceq
        'vc-lora-r19-runtime-stage-jtag-read-v5') `
    "$Description reader_schema is absent or incorrect"
  $extension = $Record.usb_extended_diagnostics
  Assert-Contract ($null -ne $extension -and
      [string]$extension.schema -ceq
        'vc-lora-r19-usb-extended-diagnostics-v2' -and
      $extension.enabled -is [bool] -and $extension.enabled -and
      [string]$extension.records.hwcdc_restart.symbol -ceq
        'vc_lora_r19_hwcdc_restart_diagnostic_record' -and
      [int]$extension.records.hwcdc_restart.schema_version -eq 1 -and
      [int]$extension.records.hwcdc_restart.size_bytes -eq 128 -and
      [string]$extension.records.ground_usb_commit.symbol -ceq
        'vc_lora_r19_ground_usb_commit_record' -and
      [int]$extension.records.ground_usb_commit.schema_version -eq 1 -and
      [int]$extension.records.ground_usb_commit.size_bytes -eq 128 -and
      (@($extension.records.PSObject.Properties.Name) -join ',') -ceq
        'hwcdc_restart,ground_usb_commit,first_usb_failure' -and
      [string]$extension.records.first_usb_failure.symbol -ceq
        'vc_lora_r19_first_usb_failure_record' -and
      [int]$extension.records.first_usb_failure.schema_version -eq 1 -and
      [int]$extension.records.first_usb_failure.size_bytes -eq 384) `
    "$Description extended diagnostic ABI is absent or incorrect"
  Assert-Contract ($Record.first_usb_failure_decoder.path -ceq
      'tools/read_r19_first_usb_failure_record.ps1' -and
      $Record.first_usb_failure_decoder.sha256 -cmatch '^[0-9A-F]{64}$') `
    "$Description first failure decoder dependency is absent or incorrect"
}

function Write-TestJson([string]$Path, [object]$Value) {
  Write-FixtureText $Path (($Value | ConvertTo-Json -Depth 32) + "`n")
}

function Write-TestHashSidecar([string]$Path, [string]$TargetName,
                               [string]$TargetPath) {
  Write-FixtureText $Path ((Get-TestSha256 $TargetPath) +
    " *$TargetName`n")
}

function Update-FixtureArtifactHashes([string]$Root) {
  # Only synthetic fixture data is re-sealed. No real candidate is ever edited.
  . (Join-Path $repo 'tools\r19_candidate_artifact_common.ps1')
  $manifestPath = Join-Path $Root 'candidate_manifest.json'
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  foreach ($role in @($manifest.roles)) {
    foreach ($record in @($role.reproducibility_artifacts.files)) {
      $path = Join-Path $Root ([string]$record.path).Replace('/', '\')
      $record.sha256 = Get-TestSha256 $path
      $record.size_bytes = (Get-Item -LiteralPath $path).Length
    }
    $role.reproducibility_artifacts.tree_sha256 =
      Get-R19CanonicalTreeHash @($role.reproducibility_artifacts.files)
  }
  Write-TestJson $manifestPath $manifest
  $inventoryPath = Join-Path $Root 'artifact_manifest.json'
  $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
  foreach ($record in @($inventory.files)) {
    $path = Join-Path $Root ([string]$record.path).Replace('/', '\')
    $record.sha256 = Get-TestSha256 $path
    $record.size_bytes = (Get-Item -LiteralPath $path).Length
  }
  $inventory.tree_sha256 = Get-R19CanonicalTreeHash @($inventory.files)
  Write-TestJson $inventoryPath $inventory
  $orderedRecords = @(Get-R19OrdinalPathRecords @($inventory.files))
  $sums = (@($orderedRecords | ForEach-Object {
      "$($_.sha256) *$($_.path)"
    }) -join "`n") + "`n"
  $sumsPath = Join-Path $Root 'SHA256SUMS.txt'
  Write-FixtureText $sumsPath $sums
  $sealPath = Join-Path $Root 'final_seal.json'
  $seal = Get-Content -LiteralPath $sealPath -Raw | ConvertFrom-Json
  $seal.candidate_manifest_sha256 = Get-TestSha256 $manifestPath
  $seal.artifact_manifest_sha256 = Get-TestSha256 $inventoryPath
  $seal.sha256s_sha256 = Get-TestSha256 $sumsPath
  Write-TestJson $sealPath $seal
  Write-TestHashSidecar (Join-Path $Root 'final_seal.sha256') `
    'final_seal.json' $sealPath
  $handoffPath = Join-Path $Root 'handoff.json'
  $handoff = Get-Content -LiteralPath $handoffPath -Raw | ConvertFrom-Json
  $handoff.candidate_manifest.sha256 = Get-TestSha256 $manifestPath
  $handoff.final_seal.sha256 = Get-TestSha256 $sealPath
  Write-TestJson $handoffPath $handoff
  Write-TestHashSidecar (Join-Path $Root 'handoff.sha256') `
    'handoff.json' $handoffPath
}

function Assert-ReproducibilityArtifactContract(
    [object]$Role, [string]$ArtifactRoot, [string]$Description) {
  Assert-Contract ($Role.PSObject.Properties[
        'reproducibility_artifacts'] -ne $null) `
    "$Description lacks reproducibility_artifacts"
  $bundle = $Role.reproducibility_artifacts
  $records = @($bundle.files)
  Assert-Contract ([int]$bundle.file_count -eq
      $reproducibilityArtifactNames.Count -and
      $records.Count -eq $reproducibilityArtifactNames.Count) `
    "$Description reproducibility artifact count is not exact"
  $expectedPaths = @($reproducibilityArtifactNames | ForEach-Object {
      "evidence/build/$($Role.role)/$_"
    } | Sort-Object)
  $actualPaths = @($records | ForEach-Object {
      [string]$_.path
    } | Sort-Object)
  Assert-Contract (@(Compare-Object $expectedPaths $actualPaths).Count -eq 0) `
    "$Description reproducibility artifact paths are not exact"
  foreach ($record in $records) {
    $path = Join-Path $ArtifactRoot ([string]$record.path).Replace('/', '\')
    Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) `
      "$Description reproducibility artifact is missing: $($record.path)"
    Assert-Contract ((Get-TestSha256 $path) -ceq [string]$record.sha256) `
      "$Description reproducibility artifact hash mismatch: $($record.path)"
    Assert-Contract ((Get-Item -LiteralPath $path).Length -eq
        [int64]$record.size_bytes) `
      "$Description reproducibility artifact size mismatch: $($record.path)"
  }
  Assert-Contract ([string]$bundle.tree_sha256 -cmatch '^[0-9A-F]{64}$') `
    "$Description reproducibility tree hash is absent"
}

function Assert-ApplicationBindingContract(
    [object]$Role, [object]$CompileEvidence, [string]$Description) {
  $binding = $Role.application_binary_provenance
  Assert-Contract ($null -ne $binding -and
      $binding.exact_match -is [bool] -and [bool]$binding.exact_match) `
    "$Description lacks an exact application-binary provenance binding"
  foreach ($name in @('build_path', 'output_dir', 'published')) {
    $record = $binding.$name
    Assert-Contract ($null -ne $record -and
        [int64]$record.size_bytes -eq [int64]$Role.application.size_bytes -and
        [string]$record.sha256 -ceq [string]$Role.application.sha256) `
      "$Description $name application provenance is not exact"
  }
  Assert-Contract (($binding | ConvertTo-Json -Depth 8 -Compress) -ceq
      ($CompileEvidence.application_binary_provenance |
        ConvertTo-Json -Depth 8 -Compress)) `
    "$Description manifest/compile-evidence provenance differs"

  $layout = $Role.application_flash_layout
  Assert-Contract ($null -ne $layout -and
      [string]$layout.application_file_name -ceq
        "vc_lora_$($Role.role)_xiao_esp32s3.ino.bin" -and
      [int]$layout.flash_args.application_occurrences -eq 1 -and
      [string]$layout.flash_args.application_offset -ceq '0x10000' -and
      [int]$layout.partitions_csv.target_app_occurrences -eq 1 -and
      [string]$layout.partitions_csv.target_app_offset -ceq '0x10000') `
    "$Description application flash layout is not exactly 0x10000"
  Assert-Contract (($layout | ConvertTo-Json -Depth 8 -Compress) -ceq
      ($CompileEvidence.application_flash_layout |
        ConvertTo-Json -Depth 8 -Compress)) `
    "$Description manifest/compile-evidence flash layout differs"
}

foreach ($name in $toolNames) {
  $path = Join-Path (Join-Path $repo 'tools') $name
  Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) `
    "missing required tool: $path"
  $tokens = $null
  $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile(
    $path, [ref]$tokens, [ref]$errors)
  Assert-Contract (@($errors).Count -eq 0) `
    "$name has PowerShell parser errors"
}

$commonTool = Join-Path (Join-Path $repo 'tools') `
  'r19_candidate_artifact_common.ps1'
$commonText = Get-Content -LiteralPath $commonTool -Raw
Assert-Contract ($commonText -match
    'function\s+Get-R19OrdinalPathRecords' -and
    $commonText -match
      '\[StringComparer\]::OrdinalIgnoreCase\.Compare') `
  'candidate tree hashing is not pinned to ordinal path ordering'

$productionSemanticCheckerPath = Join-Path $repo `
  'tests\arduino_compile\check_hwcdc_tx_integrity_contract.ps1'
$productionSemanticCheckerText = Get-Content -LiteralPath `
  $productionSemanticCheckerPath -Raw
$checkerDiagnosticNames = @(
  [regex]::Matches(
      $productionSemanticCheckerText,
      "name\s*=\s*'(?<name>diagnostic_[^']+)'"
    ) | ForEach-Object { $_.Groups['name'].Value } | Select-Object -Unique
)
$checkerCriticalAllBuildNames = @(
  [regex]::Matches(
      $productionSemanticCheckerText,
      "name\s*=\s*'(?<name>(?:in_empty_pickup_rechecks_bus_reset_under_mux|late_pickup_reset_uses_raw_only_reset_discard|postwrite_reset_quarantine_requires_positive_fifo_write|zero_fifo_write_does_not_publish_payload))'"
    ) | ForEach-Object { $_.Groups['name'].Value } | Select-Object -Unique
)
Assert-Contract ($checkerCriticalAllBuildNames.Count -eq 4) `
  'production checker lacks one or more critical all-build CDC checks'
$checkerRequiredNamesSorted = @(
  @($checkerDiagnosticNames + $checkerCriticalAllBuildNames) |
  Sort-Object -CaseSensitive)
$semanticCheckNamesSorted = @($semanticCheckNames |
  Sort-Object -CaseSensitive)
Assert-Contract (($checkerRequiredNamesSorted -join ',') -ceq
    ($semanticCheckNamesSorted -join ',')) `
  'candidate semantic required-check list drifts from the production checker'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
  ('r19c_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$fixturePrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
  [IO.Path]::DirectorySeparatorChar,
  [IO.Path]::AltDirectorySeparatorChar) +
  [IO.Path]::DirectorySeparatorChar + 'r19c_'

try {
  New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
  $fixtureTools = Join-Path $fixtureRoot 'tools'
  New-Item -ItemType Directory -Path $fixtureTools | Out-Null
  foreach ($name in $toolNames) {
    Copy-Item -LiteralPath (Join-Path (Join-Path $repo 'tools') $name) `
      -Destination (Join-Path $fixtureTools $name)
  }
  Write-FixtureText (Join-Path $fixtureRoot `
      'tests\arduino_compile\check_hwcdc_tx_integrity_contract.ps1') @'
param(
  [string]$ArduinoCli,
  [string]$Fqbn,
  [string]$ExpectedCoreVersion,
  [string]$IdeConfig,
  [string]$InstalledEsp32CoreRoot,
  [string]$OutputDir
)
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installed = Join-Path $InstalledEsp32CoreRoot 'cores\esp32'
$canonical = Join-Path $repoRoot `
  'third_party\esp32-core-3.3.11-vc-lora\cores\esp32'
$checkNames = @(
  'diagnostic_bootstrap_api_macro_scoped',
  'diagnostic_bootstrap_exact_63_byte_cold_start_only',
  'diagnostic_bootstrap_requires_clean_empty_boundary',
  'diagnostic_bootstrap_all_or_zero_publication_fence',
  'diagnostic_bootstrap_payload_primes_fifo_before_flush',
  'diagnostic_bootstrap_publishes_before_in_empty_enable',
  'diagnostic_bootstrap_rechecks_epoch_reset_and_presence',
  'diagnostic_bootstrap_isr_fence_before_ring_and_fifo',
  'diagnostic_bootstrap_serializes_debug_writer',
  'diagnostic_connected_requires_payload_pickup_witness',
  'diagnostic_flush_requires_payload_pickup_completion',
  'diagnostic_fifo_record_macro_scoped',
  'diagnostic_fifo_record_fixed_abi',
  'diagnostic_fifo_record_tracks_fifo_write_and_wr_done',
  'diagnostic_fifo_record_distinguishes_raw_in_empty_from_payload_pickup',
  'diagnostic_fifo_record_tracks_generation_reset_and_flush_outcome',
  'diagnostic_fifo_record_tracks_per_attempt_zlp_origins',
  'diagnostic_zlp_wr_done_origin_is_one_seqlock_transaction',
  'diagnostic_zlp_hardware_boundary_is_fail_closed',
  'diagnostic_zlp_invalid_post_state_is_fail_closed',
  'diagnostic_payload_wr_done_hardware_boundary_is_fail_closed',
  'diagnostic_fifo_write_hardware_boundary_is_fail_closed',
  'diagnostic_in_empty_side_effect_boundary_is_fail_closed',
  'diagnostic_bus_reset_and_raw_in_empty_boundary_is_fail_closed',
  'diagnostic_payload_causal_accounting_is_fail_closed',
  'diagnostic_flush_lifecycle_invalid_transition_is_fail_closed',
  'diagnostic_observation_window_matches_isr_lifecycle',
  'diagnostic_payload_publish_pending_closes_fifo_to_wrdone_gap',
  'diagnostic_payload_publish_abort_dominates_historical_success',
  'diagnostic_payload_flush_pending_binds_publication_to_new_flush_success',
  'in_empty_pickup_rechecks_bus_reset_under_mux',
  'late_pickup_reset_uses_raw_only_reset_discard',
  'postwrite_reset_quarantine_requires_positive_fifo_write',
  'zero_fifo_write_does_not_publish_payload'
)
$checks = @($checkNames | ForEach-Object {
    [pscustomobject][ordered]@{ name = $_; valid = $true }
  })
$summary = [pscustomobject][ordered]@{
  schema_version = 1
  test = 'FW-HWCDC-TX-INTEGRITY-001'
  result = 'PASS'
  fqbn = $Fqbn
  expected_core_version = $ExpectedCoreVersion
  actual_core_version = $ExpectedCoreVersion
  hwcdc_sha256 = (Get-FileHash -LiteralPath `
    (Join-Path $installed 'HWCDC.cpp') -Algorithm SHA256).Hash
  hwcdc_header_sha256 = (Get-FileHash -LiteralPath `
    (Join-Path $installed 'HWCDC.h') -Algorithm SHA256).Hash
  diagnostic_header_path = Join-Path $installed `
    'HWCDCR19Diagnostic.h'
  diagnostic_header_sha256 = (Get-FileHash -LiteralPath `
    (Join-Path $installed 'HWCDCR19Diagnostic.h') -Algorithm SHA256).Hash
  canonical_hwcdc_sha256 = (Get-FileHash -LiteralPath `
    (Join-Path $canonical 'HWCDC.cpp') -Algorithm SHA256).Hash
  canonical_hwcdc_header_sha256 = (Get-FileHash -LiteralPath `
    (Join-Path $canonical 'HWCDC.h') -Algorithm SHA256).Hash
  canonical_diagnostic_header_path = Join-Path $canonical `
    'HWCDCR19Diagnostic.h'
  canonical_diagnostic_header_sha256 = (Get-FileHash -LiteralPath `
    (Join-Path $canonical 'HWCDCR19Diagnostic.h') -Algorithm SHA256).Hash
  checks = $checks
  failures = @()
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath `
  (Join-Path $OutputDir 'summary.json') -Encoding UTF8
'PASS FW-HWCDC-TX-INTEGRITY-001 fixture=true'
'@

  Write-FixtureText (Join-Path $fixtureRoot 'core\src\fixture.cpp') `
    "int vc_lora_fixture() { return 19; }`n"
  Write-FixtureText `
    (Join-Path $fixtureRoot 'core\include\vc_lora\fixture.hpp') `
    "#pragma once`n"
  Write-FixtureText (Join-Path $fixtureRoot `
      'firmware\phase6\vc_lora_phase6_bridge.hpp') @'
#pragma once
#ifndef VC_LORA_R19_HIGH_SPEED_CANDIDATE
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 0
#endif
#ifndef VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 0
#endif
'@
  Write-FixtureText (Join-Path $fixtureRoot `
      'firmware\arduino_libraries\VC_LoRa_Core\src\VC_LoRa_Core.h') `
    "#pragma once`n"

  $headerNames = @(
    'e220_high_speed_transport_model.hpp',
    'high_speed_phase6_adapter.hpp',
    'phase6_bulk_rx_tail_ledger.hpp',
    'phase6_high_speed_radio_session.hpp',
    'phase6_high_speed_role_config.hpp',
    'phase6_radio_writer_arbiter.hpp',
    'peer_completion_receipt.hpp',
    'r19_runtime_fail_diagnostic.hpp',
    'r19_runtime_stage_record.hpp',
    'r19_first_usb_failure_record.hpp',
    'r19_usb_clock_sync.hpp',
    'terminal_ack_bridge.hpp',
    'terminal_ack_producer.hpp',
    'terminal_ack_wire.hpp',
    'vc_lora_high_speed_candidate.hpp'
  )
  foreach ($name in $headerNames) {
    Write-FixtureText `
      (Join-Path (Join-Path $fixtureRoot 'firmware\high_speed') $name) `
      "#pragma once // $name`n"
  }

  foreach ($role in @('vehicle', 'ground')) {
    $sketch = "vc_lora_${role}_xiao_esp32s3"
    $macro = if ($role -ceq 'vehicle') {
      'VC_LORA_PHASE6_VEHICLE'
    } else {
      'VC_LORA_PHASE6_GROUND'
    }
    Write-FixtureText `
      (Join-Path (Join-Path $fixtureRoot $sketch) ($sketch + '.ino')) `
      "#define $macro 1`nvoid setup() {}`nvoid loop() {}`n"
  }

  Write-FixtureText (Join-Path $fixtureRoot `
      'runs\phase6_arduino_compile\SENTINEL.txt') `
    "standard artifacts must not change`n"
  $sentinel = Join-Path $fixtureRoot `
    'runs\phase6_arduino_compile\SENTINEL.txt'
  $sentinelBefore = Get-TestSha256 $sentinel
  $wrapperHashesBefore = @{}
  foreach ($role in @('vehicle', 'ground')) {
    $sketch = "vc_lora_${role}_xiao_esp32s3"
    $path = Join-Path (Join-Path $fixtureRoot $sketch) ($sketch + '.ino')
    $wrapperHashesBefore[$role] = Get-TestSha256 $path
  }

  $installedCore = Join-Path $fixtureRoot 'installed-core'
  $canonicalCore = Join-Path $fixtureRoot `
    'third_party\esp32-core-3.3.11-vc-lora'
  foreach ($coreRoot in @($installedCore, $canonicalCore)) {
    Write-FixtureText (Join-Path $coreRoot 'cores\esp32\HWCDC.cpp') `
      "// pinned HWCDC.cpp`n"
    Write-FixtureText (Join-Path $coreRoot 'cores\esp32\HWCDC.h') `
      "// pinned HWCDC.h`n"
    Write-FixtureText (Join-Path $coreRoot `
        'cores\esp32\HWCDCR19Diagnostic.h') `
      "// pinned HWCDCR19Diagnostic.h`n"
  }

  $fakeCli = Join-Path $fixtureRoot 'fake-arduino-cli.exe'
  $fakeCliSource = @'
using System;
using System.IO;
using System.Text;

public static class FakeArduinoCli {
  private static void U16(byte[] bytes, int offset, ushort value) {
    Array.Copy(BitConverter.GetBytes(value), 0, bytes, offset, 2);
  }
  private static void U32(byte[] bytes, int offset, uint value) {
    Array.Copy(BitConverter.GetBytes(value), 0, bytes, offset, 4);
  }
  private static byte[] DiagnosticElf() {
    string[] names = new string[] {
      "vc_lora_r19_runtime_stage_record",
      "vc_lora_r19_hwcdc_fifo_diagnostic_record",
      "vc_lora_r19_hwcdc_restart_diagnostic_record",
      "vc_lora_r19_ground_usb_commit_record",
      "vc_lora_r19_first_usb_failure_record"
    };
    uint[] sizes = new uint[] { 68, 112, 128, 128, 384 };
    uint[] offsets = new uint[] { 0, 80, 192, 320, 448 };
    string mutation = Environment.GetEnvironmentVariable("R19_FAKE_ELF_MUTATION");
    if (mutation == "wrong-size") sizes[3] = 124;
    if (mutation == "unaligned") offsets[3] = 322;
    if (mutation == "overlap") offsets[3] = 256;
    if (mutation == "missing") names[3] += "_missing";
    if (mutation == "duplicate") names[3] = names[2];
    if (mutation == "first-wrong-size") sizes[4] = 380;
    if (mutation == "first-unaligned") offsets[4] = 449;
    if (mutation == "first-overlap") offsets[4] = 320;
    if (mutation == "first-missing") names[4] += "_missing";
    if (mutation == "first-duplicate") names[4] = names[3];
    if (mutation == "first-outside-bss") offsets[4] = 4096;
    byte[] strings = Encoding.ASCII.GetBytes("\0" + String.Join("\0", names) + "\0");
    int symbolOffset = (52 + strings.Length + 3) & ~3;
    int sectionOffset = symbolOffset + 6 * 16;
    byte[] bytes = new byte[sectionOffset + 4 * 40];
    bytes[0]=0x7F; bytes[1]=0x45; bytes[2]=0x4C; bytes[3]=0x46;
    bytes[4]=1; bytes[5]=1; bytes[6]=1;
    U16(bytes,16,2); U16(bytes,18,94); U32(bytes,20,1);
    U32(bytes,32,(uint)sectionOffset); U16(bytes,40,52);
    U16(bytes,46,40); U16(bytes,48,4);
    Array.Copy(strings,0,bytes,52,strings.Length);
    int stringIndex=1;
    for(int i=0; i<5; i++) {
      int sym=symbolOffset+(i+1)*16;
      U32(bytes,sym,(uint)stringIndex);
      U32(bytes,sym+4,0x3FC90000U+offsets[i]);
      U32(bytes,sym+8,sizes[i]); bytes[sym+12]=0x11;
      U16(bytes,sym+14,1);
      if (i == 4 && mutation == "first-undefined") U16(bytes,sym+14,0);
      if (i == 4 && mutation == "first-not-object") bytes[sym+12]=0x12;
      stringIndex+=names[i].Length+1;
    }
    int bss=sectionOffset+40;
    U32(bytes,bss+4,8); U32(bytes,bss+8,3);
    U32(bytes,bss+12,0x3FC90000); U32(bytes,bss+20,1024);
    U32(bytes,bss+32,4);
    int str=sectionOffset+80;
    U32(bytes,str+4,3); U32(bytes,str+16,52);
    U32(bytes,str+20,(uint)strings.Length); U32(bytes,str+32,1);
    int table=sectionOffset+120;
    U32(bytes,table+4,2); U32(bytes,table+16,(uint)symbolOffset);
    U32(bytes,table+20,96); U32(bytes,table+24,2);
    U32(bytes,table+28,1); U32(bytes,table+32,4); U32(bytes,table+36,16);
    if (mutation == "truncated") Array.Resize(ref bytes, 51);
    if (mutation == "wrong-machine") U16(bytes,18,3);
    return bytes;
  }
  public static int Main(string[] args) {
    if (Array.IndexOf(args, "version") >= 0) {
      Console.Write("{\"VersionString\":\"fixture-cli-1.0\"}");
      return 0;
    }
    if (Array.IndexOf(args, "board") >= 0 &&
        Array.IndexOf(args, "details") >= 0) {
      Console.Write("{\"version\":\"3.3.11\"}");
      return 0;
    }
    if (Array.IndexOf(args, "compile") >= 0) {
      try {
      int outputIndex = Array.IndexOf(args, "--output-dir");
      if (outputIndex < 0 || outputIndex + 1 >= args.Length) return 11;
      string output = args[outputIndex + 1];
      int buildIndex = Array.IndexOf(args, "--build-path");
      if (buildIndex < 0 || buildIndex + 1 >= args.Length) return 14;
      string build = args[buildIndex + 1];
      string sketchPath = args[args.Length - 1];
      string sketch = Path.GetFileName(
        sketchPath.TrimEnd(Path.DirectorySeparatorChar,
          Path.AltDirectorySeparatorChar));
      Directory.CreateDirectory(output);
      Directory.CreateDirectory(build);
      byte roleByte = (byte)(sketch.Contains("vehicle") ? 0x56 : 0x47);
      byte[] outputBytes = new byte[] { 0xE9, roleByte, 0x19, 0x01 };
      byte[] buildBytes = (byte[])outputBytes.Clone();
      if (Environment.GetEnvironmentVariable(
          "R19_FAKE_BUILD_BIN_MISMATCH") == "1") {
        buildBytes[3] = 0x02;
      }
      File.WriteAllBytes(Path.Combine(output, sketch + ".ino.bin"),
        outputBytes);
      File.WriteAllBytes(Path.Combine(build, sketch + ".ino.bin"),
        buildBytes);
      File.WriteAllBytes(Path.Combine(build, sketch + ".ino.elf"),
        DiagnosticElf());
      File.WriteAllText(Path.Combine(build, sketch + ".ino.map"),
        "fixture map " + sketch + "\n");
      File.WriteAllText(Path.Combine(build, "build.options.json"),
        "{\"fixture\":true,\"role\":\"" + sketch + "\"}\n");
      File.WriteAllText(Path.Combine(build, "sdkconfig"),
        "CONFIG_IDF_TARGET_ESP32S3=y\n");
      string partitionOffset = Environment.GetEnvironmentVariable(
        "R19_FAKE_PARTITION_OFFSET") ?? "0x10000";
      string flashOffset = Environment.GetEnvironmentVariable(
        "R19_FAKE_FLASH_OFFSET") ?? "0x10000";
      File.WriteAllText(Path.Combine(build, "partitions.csv"),
        "app0,app,ota_0," + partitionOffset + ",0x300000,\n");
      File.WriteAllText(Path.Combine(build, "flash_args"),
        flashOffset + " " + sketch + ".ino.bin\n");
      string implicitBuild = Path.Combine(sketchPath, "build", "fixture");
      Directory.CreateDirectory(implicitBuild);
      File.WriteAllBytes(Path.Combine(implicitBuild, sketch + ".ino.bin"),
        new byte[] { 0xE9, roleByte });
      File.WriteAllBytes(Path.Combine(implicitBuild, sketch + ".ino.merged.bin"),
        new byte[] { 0xE9, 0x00 });
      Console.Write("{\"success\":true," +
        "\"compiler_out\":\"fixture compile\"," +
        "\"compiler_err\":\"\"," +
        "\"builder_result\":{\"executable_sections_size\":[" +
        "{\"name\":\"text\",\"size\":419000}," +
        "{\"name\":\"data\",\"size\":104000}]}}");
      return 0;
      } catch (Exception ex) {
        Console.Write("{\"success\":false," +
          "\"compiler_out\":\"\"," +
          "\"compiler_err\":\"" + ex.GetType().FullName + "\"}");
        return 13;
      }
    }
    return 12;
  }
}
'@
  Add-Type -TypeDefinition $fakeCliSource -OutputAssembly $fakeCli `
    -OutputType ConsoleApplication

  $builder = Join-Path $fixtureTools 'build_r19_candidate_artifacts.ps1'
  $verifier = Join-Path $fixtureTools 'verify_r19_candidate_artifact.ps1'
  $builderArguments = @{
    RepoRoot = $fixtureRoot
    ArduinoCli = $fakeCli
    IdeConfig = ''
    InstalledEsp32CoreRoot = $installedCore
    CanonicalPatchedCoreRoot = $canonicalCore
  }

  $firstOutput = @(& $builder @builderArguments)
  Assert-Contract (($firstOutput -join "`n") -match
      [regex]::Escape("$buildId PASS")) `
    "first builder invocation failed: $($firstOutput -join ' | ')"
  $outputBase = Join-Path $fixtureRoot `
    'runs\candidates\R19-HS-PRODUCT-CANDIDATE-BUILD-001'
  $latestPath = Join-Path $outputBase 'latest.json'
  $firstLatestSha = Get-TestSha256 $latestPath
  $firstLatest = Get-Content -LiteralPath $latestPath -Raw | ConvertFrom-Json
  Assert-ModeContract $firstLatest $false $true 'normal latest pointer'
  $firstRoot = Join-Path $fixtureRoot `
    ([string]$firstLatest.artifact_root).Replace('/', '\')
  $firstHandoffPath = Join-Path $fixtureRoot `
    ([string]$firstLatest.handoff.path).Replace('/', '\')
  $firstHandoffSha = Get-TestSha256 $firstHandoffPath

  $secondOutput = @(& $builder @builderArguments)
  Assert-Contract (($secondOutput -join "`n") -match
      [regex]::Escape("$buildId PASS")) `
    "second builder invocation failed: $($secondOutput -join ' | ')"
  $secondLatestSha = Get-TestSha256 $latestPath
  $secondLatest = Get-Content -LiteralPath $latestPath -Raw | ConvertFrom-Json
  Assert-ModeContract $secondLatest $false $true 'normal latest pointer'
  $secondRoot = Join-Path $fixtureRoot `
    ([string]$secondLatest.artifact_root).Replace('/', '\')
  $manifestPath = Join-Path $fixtureRoot `
    ([string]$secondLatest.candidate_manifest.path).Replace('/', '\')
  $handoffPath = Join-Path $fixtureRoot `
    ([string]$secondLatest.handoff.path).Replace('/', '\')

  Assert-Contract ($firstRoot -cne $secondRoot) `
    'candidate builds did not use unique run roots'
  Assert-Contract ([string]$secondLatest.previous_latest_sha256 -ceq
      $firstLatestSha) 'latest pointer did not bind its previous generation'
  Assert-Contract ((Get-TestSha256 $firstHandoffPath) -ceq $firstHandoffSha) `
    'publishing a new generation changed the prior immutable handoff'

  $selectorRuns = @(
    [pscustomobject]@{
      name = 'ArtifactRoot'
      arguments = @{ ArtifactRoot = $secondRoot }
    },
    [pscustomobject]@{
      name = 'ManifestPath'
      arguments = @{ ManifestPath = $manifestPath }
    },
    [pscustomobject]@{
      name = 'HandoffPath'
      arguments = @{ HandoffPath = $handoffPath }
    },
    [pscustomobject]@{
      name = 'LatestPath'
      arguments = @{
        LatestPath = $latestPath
        ExpectedLatestSha256 = $secondLatestSha
      }
    }
  )
  foreach ($selector in $selectorRuns) {
    $selectorArguments = $selector.arguments
    $verifyOutput = @(& $verifier -RepoRoot $fixtureRoot @selectorArguments)
    Assert-Contract (($verifyOutput -join "`n") -match
        'FW-R19-CANDIDATE-ARTIFACT-VERIFY-001 PASS') `
      "verifier selector failed: $($selector.name)"
  }

  $unknownRootPath = Join-Path $secondRoot 'unexpected-root-file.txt'
  Write-FixtureText $unknownRootPath "must be rejected`n"
  $unknownRootRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -ArtifactRoot $secondRoot |
      Out-Null
  } catch {
    $unknownRootRejected = $_.Exception.Message -match
      'unknown top-level entry'
  }
  Assert-Contract $unknownRootRejected `
    'verifier accepted an unknown artifact-root file'
  Remove-Item -LiteralPath $unknownRootPath -Force

  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $handoff = Get-Content -LiteralPath $handoffPath -Raw | ConvertFrom-Json
  $sealPath = Join-Path $secondRoot 'final_seal.json'
  $seal = Get-Content -LiteralPath $sealPath -Raw | ConvertFrom-Json
  Assert-ModeContract $manifest $false $true 'normal manifest'
  Assert-ModeContract $handoff $false $true 'normal handoff'
  Assert-ModeContract $seal $false $true 'normal final seal'
  Assert-Contract ($manifest.hwcdc_semantic_contract.required -eq $false -and
      [string]$manifest.hwcdc_semantic_contract.result -ceq 'NOT_REQUIRED' -and
      $null -eq $manifest.hwcdc_semantic_contract.summary -and
      [int]$manifest.hwcdc_semantic_contract.check_count -eq 0) `
    'normal manifest improperly contains an HWCDC semantic result'
  Assert-Contract ($seal.hwcdc_semantic_contract_required -eq $false -and
      [string]$seal.hwcdc_semantic_summary_sha256 -ceq '') `
    'normal final seal improperly binds an HWCDC semantic result'
  Assert-Contract ([string]$manifest.candidate_enable.property -ceq
      'compiler.cpp.extra_flags=-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1') `
    'manifest lost candidate-enable provenance'
  Assert-Contract ([string]$manifest.flash_policy.offset -ceq '0x10000' -and
      [string]$manifest.flash_policy.mode -ceq 'app-only') `
    'manifest lost app-only flash policy'
  Assert-Contract ($manifest.toolchain.hwcdc.exact_match -eq $true -and
      [string]$manifest.toolchain.hwcdc.installed_diagnostic_h_sha256 -ceq
        [string]$manifest.toolchain.hwcdc.canonical_diagnostic_h_sha256 -and
      [string]$manifest.toolchain.hwcdc.installed_diagnostic_h_sha256 `
        -cmatch '^[0-9A-F]{64}$' -and
      [string]$manifest.toolchain.hwcdc.installed_diagnostic_h_path -ceq
        (Join-Path $installedCore 'cores\esp32\HWCDCR19Diagnostic.h') -and
      [string]$manifest.toolchain.hwcdc.canonical_diagnostic_h_path -ceq
        (Join-Path $canonicalCore 'cores\esp32\HWCDCR19Diagnostic.h')) `
    'manifest does not seal the exact HWCDC diagnostic header input'
  Assert-Contract (@($manifest.roles).Count -eq 2 -and
      [string]$manifest.roles[0].role -ceq 'vehicle' -and
      [string]$manifest.roles[1].role -ceq 'ground') `
    'manifest role order is not Vehicle then Ground'
  Assert-Contract (@(Get-ChildItem -LiteralPath $secondRoot -Recurse `
      -File -Filter '*.bin').Count -eq 2) `
    'candidate artifact contains non-application binary output'
  foreach ($role in @($manifest.roles)) {
    Assert-ModeContract $role.compile $false $true `
      "normal $($role.role) compile provenance"
    $compileEvidencePath = Join-Path $secondRoot `
      ([string]$role.compile.evidence_path).Replace('/', '\')
    $compileEvidence = Get-Content -LiteralPath $compileEvidencePath -Raw |
      ConvertFrom-Json
    Assert-ModeContract $compileEvidence $false $true `
      "normal $($role.role) compile evidence"
    Assert-Contract (-not ((@($compileEvidence.argv) -join ' ') -match
        'VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS')) `
      "normal $($role.role) compile unexpectedly enabled diagnostics"
    Assert-ApplicationBindingContract $role $compileEvidence `
      "normal $($role.role)"
    Assert-ReproducibilityArtifactContract $role $secondRoot `
      "normal $($role.role)"
  }

  $normalLatestShaBeforeDiagnostic = Get-TestSha256 $latestPath
  $diagnosticBuilderArguments = @{} + $builderArguments
  $diagnosticBuilderArguments['RuntimeFailDiagnostics'] = $true
  $diagnosticOutput = @(& $builder @diagnosticBuilderArguments)
  Assert-Contract (($diagnosticOutput -join "`n") -match
      [regex]::Escape("$buildId PASS")) `
    "diagnostic builder invocation failed: $($diagnosticOutput -join ' | ')"
  $diagnosticBase = Join-Path $fixtureRoot `
    'runs\candidates\R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001'
  $diagnosticLatestPath = Join-Path $diagnosticBase 'latest.json'
  $diagnosticLatest = Get-Content -LiteralPath $diagnosticLatestPath -Raw |
    ConvertFrom-Json
  $diagnosticRoot = Join-Path $fixtureRoot `
    ([string]$diagnosticLatest.artifact_root).Replace('/', '\')
  $diagnosticManifestPath = Join-Path $fixtureRoot `
    ([string]$diagnosticLatest.candidate_manifest.path).Replace('/', '\')
  $diagnosticHandoffPath = Join-Path $fixtureRoot `
    ([string]$diagnosticLatest.handoff.path).Replace('/', '\')
  $diagnosticSealPath = Join-Path $fixtureRoot `
    ([string]$diagnosticLatest.final_seal.path).Replace('/', '\')
  $diagnosticManifest = Get-Content -LiteralPath $diagnosticManifestPath -Raw |
    ConvertFrom-Json
  $diagnosticHandoff = Get-Content -LiteralPath $diagnosticHandoffPath -Raw |
    ConvertFrom-Json
  $diagnosticSeal = Get-Content -LiteralPath $diagnosticSealPath -Raw |
    ConvertFrom-Json
  Assert-ModeContract $diagnosticLatest $true $false `
    'diagnostic latest pointer'
  Assert-ModeContract $diagnosticManifest $true $false `
    'diagnostic manifest'
  Assert-ModeContract $diagnosticHandoff $true $false `
    'diagnostic handoff'
  Assert-ModeContract $diagnosticSeal $true $false `
    'diagnostic final seal'
  Assert-DiagnosticAbiContract $diagnosticManifest 'diagnostic manifest'
  Assert-DiagnosticAbiContract $diagnosticHandoff 'diagnostic handoff'
  Assert-DiagnosticAbiContract $diagnosticSeal 'diagnostic final seal'
  $sealedDecoderPath = Join-Path $diagnosticRoot `
    'evidence\tools\read_r19_first_usb_failure_record.ps1'
  $decoderSha = Get-TestSha256 (Join-Path $fixtureTools `
    'read_r19_first_usb_failure_record.ps1')
  Assert-Contract ((Get-TestSha256 $sealedDecoderPath) -ceq $decoderSha -and
      $diagnosticManifest.first_usb_failure_decoder.sha256 -ceq $decoderSha -and
      ($diagnosticManifest.first_usb_failure_decoder | ConvertTo-Json -Compress) -ceq
      ($diagnosticHandoff.first_usb_failure_decoder | ConvertTo-Json -Compress) -and
      ($diagnosticManifest.first_usb_failure_decoder | ConvertTo-Json -Compress) -ceq
      ($diagnosticSeal.first_usb_failure_decoder | ConvertTo-Json -Compress) -and
      @($diagnosticManifest.canonical_source_snapshot.files | Where-Object {
        $_.path -ceq 'tools/read_r19_first_usb_failure_record.ps1' -and
        $_.sha256 -ceq $decoderSha }).Count -eq 1) `
    'first failure decoder is not sealed with the canonical source dependency'
  foreach ($role in @($diagnosticManifest.roles)) {
    $index = if ([string]$role.role -ceq 'vehicle') { 0 } else { 1 }
    $binding = $role.runtime_diagnostic_symbols
    Assert-Contract ($null -ne $binding -and
        [string]$binding.schema -ceq
          'vc-lora-r19-runtime-diagnostic-symbols-v1' -and
        [string]$binding.application_sha256 -ceq
          [string]$role.application.sha256 -and
        [string]$binding.elf_sha256 -ceq (Get-TestSha256 (Join-Path `
          $diagnosticRoot "evidence\build\$($role.role)\application.elf")) -and
        [string]$binding.map_sha256 -ceq (Get-TestSha256 (Join-Path `
          $diagnosticRoot "evidence\build\$($role.role)\application.map")) -and
        (@($binding.symbols.PSObject.Properties.Name) -join ',') -ceq
          'runtime_stage,endpoint_fifo,hwcdc_restart,ground_usb_commit,first_usb_failure') `
      "diagnostic $($role.role) symbol/ELF/application binding is incomplete"
    Assert-Contract (($binding | ConvertTo-Json -Depth 12 -Compress) -ceq
        ($diagnosticHandoff.roles[$index].runtime_diagnostic_symbols |
          ConvertTo-Json -Depth 12 -Compress) -and
        ($binding | ConvertTo-Json -Depth 12 -Compress) -ceq
        ($diagnosticSeal.roles[$index].runtime_diagnostic_symbols |
          ConvertTo-Json -Depth 12 -Compress)) `
      "diagnostic $($role.role) handoff/seal symbol binding differs"
  }
  $diagnosticSemantic = $diagnosticManifest.hwcdc_semantic_contract
  Assert-Contract ($diagnosticSemantic.required -eq $true -and
      [string]$diagnosticSemantic.result -ceq 'PASS' -and
      [int]$diagnosticSemantic.check_count -eq $semanticCheckNames.Count -and
      (@($diagnosticSemantic.required_checks) -join ',') -ceq
        ($semanticCheckNames -join ',')) `
    'diagnostic manifest lacks the exact HWCDC semantic contract'
  $diagnosticSummaryPath = Join-Path $diagnosticRoot `
    ([string]$diagnosticSemantic.summary.path).Replace('/', '\')
  $diagnosticSummarySha = Get-TestSha256 $diagnosticSummaryPath
  Assert-Contract ([string]$diagnosticSemantic.summary.sha256 -ceq
      $diagnosticSummarySha -and
      [string]$diagnosticSeal.hwcdc_semantic_summary_sha256 -ceq
        $diagnosticSummarySha -and
      $diagnosticSeal.hwcdc_semantic_contract_required -eq $true) `
    'diagnostic manifest/final seal do not bind the semantic summary'
  Assert-Contract ((Get-TestSha256 $latestPath) -ceq
      $normalLatestShaBeforeDiagnostic) `
    'diagnostic build changed the normal candidate latest pointer'
  foreach ($role in @($diagnosticManifest.roles)) {
    Assert-ModeContract $role.compile $true $false `
      "diagnostic $($role.role) compile provenance"
    $compileEvidencePath = Join-Path $diagnosticRoot `
      ([string]$role.compile.evidence_path).Replace('/', '\')
    $compileEvidence = Get-Content -LiteralPath $compileEvidencePath -Raw |
      ConvertFrom-Json
    Assert-ModeContract $compileEvidence $true $false `
      "diagnostic $($role.role) compile evidence"
    Assert-Contract ((@($compileEvidence.argv) -join ' ') -match
        'compiler\.cpp\.extra_flags=-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1 -DVC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS=1') `
      "diagnostic $($role.role) compile lacks the exact diagnostic flag"
    Assert-ApplicationBindingContract $role $compileEvidence `
      "diagnostic $($role.role)"
    Assert-ReproducibilityArtifactContract $role $diagnosticRoot `
      "diagnostic $($role.role)"
  }
  $diagnosticVerifyOutput = @(& $verifier -RepoRoot $fixtureRoot `
    -RuntimeFailDiagnostics -LatestPath $diagnosticLatestPath `
    -ExpectedLatestSha256 (Get-TestSha256 $diagnosticLatestPath))
  Assert-Contract (($diagnosticVerifyOutput -join "`n") -match
      'FW-R19-CANDIDATE-ARTIFACT-VERIFY-001 PASS') `
    'verifier rejected the diagnostic candidate artifact'

  $decoderDependencyManifest = Get-Content -LiteralPath $diagnosticManifestPath -Raw
  $decoderDependencyBytes = [IO.File]::ReadAllBytes($sealedDecoderPath)
  Write-FixtureText $sealedDecoderPath '# deliberately tampered sealed decoder'
  $sealedDecoderRejected = $false
  try { & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ArtifactRoot $diagnosticRoot | Out-Null }
  catch { $sealedDecoderRejected = $_.Exception.Message -match 'first_usb_failure_decoder' }
  Assert-Contract $sealedDecoderRejected 'verifier accepted a changed sealed decoder copy'
  [IO.File]::WriteAllBytes($sealedDecoderPath,$decoderDependencyBytes)

  . (Join-Path $repo 'tools\r19_candidate_artifact_common.ps1')
  $missingDecoderSource = $decoderDependencyManifest | ConvertFrom-Json
  $missingDecoderSource.canonical_source_snapshot.files = @(
    $missingDecoderSource.canonical_source_snapshot.files | Where-Object {
      $_.path -cne 'tools/read_r19_first_usb_failure_record.ps1' })
  $missingDecoderSource.canonical_source_snapshot.file_count =
    @($missingDecoderSource.canonical_source_snapshot.files).Count
  $missingDecoderSource.canonical_source_snapshot.tree_sha256 =
    Get-R19CanonicalTreeHash @($missingDecoderSource.canonical_source_snapshot.files)
  Write-TestJson $diagnosticManifestPath $missingDecoderSource
  $missingDecoderSourceRejected = $false
  try { & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ArtifactRoot $diagnosticRoot | Out-Null }
  catch { $missingDecoderSourceRejected = $_.Exception.Message -match 'first_usb_failure_decoder' }
  Assert-Contract $missingDecoderSourceRejected `
    'verifier accepted a rehashed source snapshot that omits the decoder dependency'
  Write-FixtureText $diagnosticManifestPath $decoderDependencyManifest

  # Compatibility is explicit: four-record v4 and two-record v3 are admitted
  # only after the newer ELF symbols and declarations are actually removed.
  $legacyRestore = @{}
  foreach ($relative in @(
      'candidate_manifest.json', 'artifact_manifest.json', 'SHA256SUMS.txt',
      'final_seal.json', 'final_seal.sha256', 'handoff.json', 'handoff.sha256',
      'evidence/build/vehicle/application.elf',
      'evidence/build/ground/application.elf')) {
    $legacyRestore[$relative] = [IO.File]::ReadAllBytes((Join-Path `
      $diagnosticRoot $relative.Replace('/', '\')))
  }
  . (Join-Path $repo 'tools\r19_candidate_artifact_common.ps1')
  foreach ($documentName in @('candidate_manifest.json','handoff.json','final_seal.json')) {
    $path = Join-Path $diagnosticRoot $documentName
    $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $document.reader_schema = 'vc-lora-r19-runtime-stage-jtag-read-v4'
    $document.usb_extended_diagnostics = Get-R19DiagnosticExtensionContract $false
    [void]$document.PSObject.Properties.Remove('first_usb_failure_decoder')
    foreach ($role in @($document.roles)) {
      [void]$role.runtime_diagnostic_symbols.symbols.PSObject.Properties.Remove('first_usb_failure')
    }
    Write-TestJson $path $document
  }
  Update-FixtureArtifactHashes $diagnosticRoot
  $v4DowngradeRejected = $false
  try { & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ArtifactRoot $diagnosticRoot | Out-Null }
  catch { $v4DowngradeRejected = $_.Exception.Message -match 'undeclared diagnostic extensions' }
  Assert-Contract $v4DowngradeRejected `
    'reader-v4 downgrade accepted an undeclared fifth symbol'
  foreach ($role in @('vehicle','ground')) {
    $path = Join-Path $diagnosticRoot "evidence\build\$role\application.elf"
    [byte[]]$elf = [IO.File]::ReadAllBytes($path)
    $text = [Text.Encoding]::ASCII.GetString($elf)
    $index = $text.IndexOf('vc_lora_r19_first_usb_failure_record',[StringComparison]::Ordinal)
    Assert-Contract ($index -gt 0) 'v4 compatibility fifth symbol was not located'
    $elf[$index] = [byte][char]'_'
    [IO.File]::WriteAllBytes($path,$elf)
  }
  foreach ($documentName in @('candidate_manifest.json','handoff.json','final_seal.json')) {
    $path = Join-Path $diagnosticRoot $documentName
    $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    foreach ($role in @($document.roles)) {
      $role.runtime_diagnostic_symbols.elf_sha256 = Get-TestSha256 `
        (Join-Path $diagnosticRoot "evidence\build\$($role.role)\application.elf")
    }
    Write-TestJson $path $document
  }
  Update-FixtureArtifactHashes $diagnosticRoot
  $v4Verify = @(& $verifier -RepoRoot $fixtureRoot `
    -RuntimeFailDiagnostics -ArtifactRoot $diagnosticRoot)
  Assert-Contract (($v4Verify -join "`n") -match 'FW-R19-CANDIDATE-ARTIFACT-VERIFY-001 PASS') `
    'verifier rejected the exact four-record reader-v4 fixture'
  $v4ManifestOriginal = Get-Content -LiteralPath $diagnosticManifestPath -Raw
  $v4DecoderMutation = $v4ManifestOriginal | ConvertFrom-Json
  Add-Member -InputObject $v4DecoderMutation -NotePropertyName 'first_usb_failure_decoder' `
    -NotePropertyValue $diagnosticManifest.first_usb_failure_decoder
  Write-TestJson $diagnosticManifestPath $v4DecoderMutation
  $v4DecoderRejected = $false
  try { & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ArtifactRoot $diagnosticRoot | Out-Null }
  catch { $v4DecoderRejected = $_.Exception.Message -match 'undeclared first_usb_failure_decoder' }
  Assert-Contract $v4DecoderRejected 'reader-v4 admitted a v5 decoder declaration'
  Write-FixtureText $diagnosticManifestPath $v4ManifestOriginal
  foreach ($relative in @($legacyRestore.Keys)) {
    [IO.File]::WriteAllBytes((Join-Path $diagnosticRoot `
      $relative.Replace('/', '\')), [byte[]]$legacyRestore[$relative])
  }
  foreach ($documentName in @('candidate_manifest.json', 'handoff.json')) {
    $path = Join-Path $diagnosticRoot $documentName
    $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $document.reader_schema = 'vc-lora-r19-runtime-stage-jtag-read-v3'
    [void]$document.PSObject.Properties.Remove('usb_extended_diagnostics')
    [void]$document.PSObject.Properties.Remove('first_usb_failure_decoder')
    foreach ($role in @($document.roles)) {
      [void]$role.PSObject.Properties.Remove('runtime_diagnostic_symbols')
    }
    Write-TestJson $path $document
  }
  $legacySeal = Get-Content -LiteralPath $diagnosticSealPath -Raw |
    ConvertFrom-Json
  foreach ($property in @('usb_extended_diagnostics', 'reader_schema',
      'endpoint_fifo_schema', 'endpoint_fifo_size_bytes',
      'runtime_stage_size_bytes', 'roles', 'first_usb_failure_decoder')) {
    [void]$legacySeal.PSObject.Properties.Remove($property)
  }
  Write-TestJson $diagnosticSealPath $legacySeal
  Update-FixtureArtifactHashes $diagnosticRoot
  $undeclaredSymbolsRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ArtifactRoot $diagnosticRoot | Out-Null
  } catch {
    $undeclaredSymbolsRejected = $_.Exception.Message -match
      'undeclared diagnostic extensions'
  }
  Assert-Contract $undeclaredSymbolsRejected `
    'reader-v3 downgrade accepted unadvertised extension symbols'
  foreach ($role in @('vehicle', 'ground')) {
    $elfPath = Join-Path $diagnosticRoot "evidence\build\$role\application.elf"
    [byte[]]$elf = [IO.File]::ReadAllBytes($elfPath)
    $text = [Text.Encoding]::ASCII.GetString($elf)
    foreach ($symbol in @('vc_lora_r19_hwcdc_restart_diagnostic_record',
        'vc_lora_r19_ground_usb_commit_record',
        'vc_lora_r19_first_usb_failure_record')) {
      $index = $text.IndexOf($symbol, [StringComparison]::Ordinal)
      Assert-Contract ($index -gt 0) 'legacy fixture symbol was not located'
      $elf[$index] = [byte][char]'_'
    }
    [IO.File]::WriteAllBytes($elfPath, $elf)
  }
  Update-FixtureArtifactHashes $diagnosticRoot
  $legacyVerify = @(& $verifier -RepoRoot $fixtureRoot `
    -RuntimeFailDiagnostics -ArtifactRoot $diagnosticRoot)
  Assert-Contract (($legacyVerify -join "`n") -match
      'FW-R19-CANDIDATE-ARTIFACT-VERIFY-001 PASS') `
    'verifier rejected the no-extension reader-v3 legacy fixture'
  $v3ManifestOriginal = Get-Content -LiteralPath $diagnosticManifestPath -Raw
  $v3DecoderMutation = $v3ManifestOriginal | ConvertFrom-Json
  Add-Member -InputObject $v3DecoderMutation -NotePropertyName 'first_usb_failure_decoder' `
    -NotePropertyValue $diagnosticManifest.first_usb_failure_decoder
  Write-TestJson $diagnosticManifestPath $v3DecoderMutation
  $v3DecoderRejected = $false
  try { & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ArtifactRoot $diagnosticRoot | Out-Null }
  catch { $v3DecoderRejected = $_.Exception.Message -match 'undeclared diagnostic extensions' }
  Assert-Contract $v3DecoderRejected 'reader-v3 admitted a v5 decoder declaration'
  Write-FixtureText $diagnosticManifestPath $v3ManifestOriginal
  foreach ($relative in @($legacyRestore.Keys)) {
    [IO.File]::WriteAllBytes((Join-Path $diagnosticRoot `
      $relative.Replace('/', '\')), [byte[]]$legacyRestore[$relative])
  }

  foreach ($documentName in @('handoff.json', 'final_seal.json')) {
    $path = Join-Path $diagnosticRoot $documentName
    $original = Get-Content -LiteralPath $path -Raw
    foreach ($mutation in @('missing-extension', 'wrong-role-binding',
        'missing-decoder', 'wrong-decoder-hash')) {
      $mutant = $original | ConvertFrom-Json
      if ($mutation -ceq 'missing-extension') {
        [void]$mutant.PSObject.Properties.Remove('usb_extended_diagnostics')
      } elseif ($mutation -ceq 'wrong-role-binding') {
        $mutant.roles[1].runtime_diagnostic_symbols.elf_sha256 = ('0' * 64)
      } elseif ($mutation -ceq 'missing-decoder') {
        [void]$mutant.PSObject.Properties.Remove('first_usb_failure_decoder')
      } else {
        $mutant.first_usb_failure_decoder.sha256 = ('0' * 64)
      }
      Write-TestJson $path $mutant
      $sidecarName = if ($documentName -ceq 'handoff.json') {
        'handoff.sha256'
      } else { 'final_seal.sha256' }
      Write-TestHashSidecar (Join-Path $diagnosticRoot $sidecarName) `
        $documentName $path
      $rejected = $false
      try {
        & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
          -ArtifactRoot $diagnosticRoot | Out-Null
      } catch {
        $rejected = $_.Exception.Message -match
          'usb_extended_diagnostics|diagnostic symbol binding|first_usb_failure_decoder'
      }
      Assert-Contract $rejected "$documentName accepted extension mutation: $mutation"
      Write-FixtureText $path $original
      Write-TestHashSidecar (Join-Path $diagnosticRoot $sidecarName) `
        $documentName $path
    }
  }

  # Every mutation retains the original binary/artifact hashes. Metadata is
  # checked before the inventory, so these are semantic rather than CRC tests.
  $extensionManifestOriginal = Get-Content -LiteralPath `
    $diagnosticManifestPath -Raw
  $extensionMutations = @(
    'missing-extension', 'wrong-extension-schema', 'disabled-extension',
    'missing-one-extension', 'wrong-record-size', 'wrong-record-version',
    'wrong-record-symbol', 'legacy-reader-with-extension',
    'missing-role-binding', 'wrong-role-address', 'wrong-role-elf-hash',
    'wrong-role-map-hash', 'wrong-role-application-hash', 'extra-symbol',
    'missing-first-record', 'wrong-first-size', 'string-first-size',
    'wrong-first-version', 'wrong-first-symbol', 'v4-reader-with-v2',
    'v5-reader-with-v1', 'missing-first-symbol-binding',
    'wrong-first-role-address', 'missing-decoder', 'wrong-decoder-path',
    'wrong-decoder-hash', 'extra-decoder-property',
    'wrong-case-reader-property', 'wrong-case-extension-property',
    'wrong-case-decoder-property', 'string-first-version', 'extra-first-property')
  foreach ($mutation in $extensionMutations) {
    $mutant = $extensionManifestOriginal | ConvertFrom-Json
    switch ($mutation) {
      'missing-extension' {
        [void]$mutant.PSObject.Properties.Remove('usb_extended_diagnostics')
      }
      'wrong-extension-schema' { $mutant.usb_extended_diagnostics.schema = 'invalid' }
      'disabled-extension' { $mutant.usb_extended_diagnostics.enabled = $false }
      'missing-one-extension' {
        [void]$mutant.usb_extended_diagnostics.records.PSObject.Properties.Remove(
          'ground_usb_commit')
      }
      'wrong-record-size' {
        $mutant.usb_extended_diagnostics.records.hwcdc_restart.size_bytes = 124
      }
      'wrong-record-version' {
        $mutant.usb_extended_diagnostics.records.hwcdc_restart.schema_version = 2
      }
      'wrong-record-symbol' {
        $mutant.usb_extended_diagnostics.records.ground_usb_commit.symbol = 'invalid'
      }
      'legacy-reader-with-extension' {
        $mutant.reader_schema = 'vc-lora-r19-runtime-stage-jtag-read-v3'
      }
      'missing-role-binding' {
        [void]$mutant.roles[1].PSObject.Properties.Remove('runtime_diagnostic_symbols')
      }
      'wrong-role-address' {
        $mutant.roles[1].runtime_diagnostic_symbols.symbols.hwcdc_restart.address =
          '0x3fc90000'
      }
      'wrong-role-elf-hash' {
        $mutant.roles[1].runtime_diagnostic_symbols.elf_sha256 = ('0' * 64)
      }
      'wrong-role-map-hash' {
        $mutant.roles[1].runtime_diagnostic_symbols.map_sha256 = ('0' * 64)
      }
      'wrong-role-application-hash' {
        $mutant.roles[1].runtime_diagnostic_symbols.application_sha256 = ('0' * 64)
      }
      'extra-symbol' {
        Add-Member -InputObject $mutant.roles[1].runtime_diagnostic_symbols.symbols `
          -NotePropertyName 'invented' -NotePropertyValue @{}
      }
      'missing-first-record' {
        [void]$mutant.usb_extended_diagnostics.records.PSObject.Properties.Remove('first_usb_failure')
      }
      'wrong-first-size' { $mutant.usb_extended_diagnostics.records.first_usb_failure.size_bytes = 380 }
      'string-first-size' { $mutant.usb_extended_diagnostics.records.first_usb_failure.size_bytes = '384' }
      'wrong-first-version' { $mutant.usb_extended_diagnostics.records.first_usb_failure.schema_version = 2 }
      'wrong-first-symbol' { $mutant.usb_extended_diagnostics.records.first_usb_failure.symbol = 'invalid' }
      'v4-reader-with-v2' { $mutant.reader_schema = 'vc-lora-r19-runtime-stage-jtag-read-v4' }
      'v5-reader-with-v1' { $mutant.usb_extended_diagnostics = Get-R19DiagnosticExtensionContract $false }
      'missing-first-symbol-binding' {
        [void]$mutant.roles[1].runtime_diagnostic_symbols.symbols.PSObject.Properties.Remove('first_usb_failure')
      }
      'wrong-first-role-address' { $mutant.roles[1].runtime_diagnostic_symbols.symbols.first_usb_failure.address = '0x3fc90000' }
      'missing-decoder' { [void]$mutant.PSObject.Properties.Remove('first_usb_failure_decoder') }
      'wrong-decoder-path' { $mutant.first_usb_failure_decoder.path = '../read_r19_first_usb_failure_record.ps1' }
      'wrong-decoder-hash' { $mutant.first_usb_failure_decoder.sha256 = '0' * 64 }
      'extra-decoder-property' { Add-Member -InputObject $mutant.first_usb_failure_decoder -NotePropertyName 'execute' -NotePropertyValue $true }
      'wrong-case-reader-property' {
        $value = $mutant.reader_schema
        [void]$mutant.PSObject.Properties.Remove('reader_schema')
        Add-Member -InputObject $mutant -NotePropertyName 'Reader_Schema' -NotePropertyValue $value
      }
      'wrong-case-extension-property' {
        $value = $mutant.usb_extended_diagnostics
        [void]$mutant.PSObject.Properties.Remove('usb_extended_diagnostics')
        Add-Member -InputObject $mutant -NotePropertyName 'USB_Extended_Diagnostics' -NotePropertyValue $value
      }
      'wrong-case-decoder-property' {
        $value = $mutant.first_usb_failure_decoder
        [void]$mutant.PSObject.Properties.Remove('first_usb_failure_decoder')
        Add-Member -InputObject $mutant -NotePropertyName 'First_USB_Failure_Decoder' -NotePropertyValue $value
      }
      'string-first-version' { $mutant.usb_extended_diagnostics.records.first_usb_failure.schema_version = '1' }
      'extra-first-property' { Add-Member -InputObject $mutant.usb_extended_diagnostics.records.first_usb_failure -NotePropertyName 'ignored' -NotePropertyValue $true }
    }
    Write-TestJson $diagnosticManifestPath $mutant
    $rejected = $false
    try {
      & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
        -ManifestPath $diagnosticManifestPath | Out-Null
    } catch {
      $rejected = $_.Exception.Message -match
        'usb_extended_diagnostics|undeclared diagnostic extensions|runtime_diagnostic_symbols|first_usb_failure_decoder|diagnostic ABI field'
    }
    Assert-Contract $rejected "verifier accepted extension mutation: $mutation"
    Write-FixtureText $diagnosticManifestPath $extensionManifestOriginal
  }

  $diagnosticManifestOriginal = Get-Content -LiteralPath `
    $diagnosticManifestPath -Raw
  $invalidDiagnosticManifest = $diagnosticManifestOriginal |
    ConvertFrom-Json
  [void]$invalidDiagnosticManifest.PSObject.Properties.Remove(
    'endpoint_fifo_size_bytes')
  Write-TestJson $diagnosticManifestPath $invalidDiagnosticManifest
  $missingDiagnosticManifestAbiRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ManifestPath $diagnosticManifestPath | Out-Null
  } catch {
    $missingDiagnosticManifestAbiRejected =
      $_.Exception.Message -match 'endpoint_fifo_size_bytes'
  }
  Assert-Contract $missingDiagnosticManifestAbiRejected `
    'verifier accepted a diagnostic manifest without its sealed FIFO ABI'
  Write-FixtureText $diagnosticManifestPath $diagnosticManifestOriginal

  $diagnosticHandoffOriginal = Get-Content -LiteralPath `
    $diagnosticHandoffPath -Raw
  $invalidDiagnosticHandoff = $diagnosticHandoffOriginal | ConvertFrom-Json
  $invalidDiagnosticHandoff.endpoint_fifo_schema = 1
  Write-TestJson $diagnosticHandoffPath $invalidDiagnosticHandoff
  Write-TestHashSidecar (Join-Path $diagnosticRoot 'handoff.sha256') `
    'handoff.json' $diagnosticHandoffPath
  $legacyDiagnosticHandoffAbiRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -HandoffPath $diagnosticHandoffPath | Out-Null
  } catch {
    $legacyDiagnosticHandoffAbiRejected =
      $_.Exception.Message -match 'endpoint_fifo_schema'
  }
  Assert-Contract $legacyDiagnosticHandoffAbiRejected `
    'verifier accepted a diagnostic handoff with the legacy FIFO ABI'
  Write-FixtureText $diagnosticHandoffPath $diagnosticHandoffOriginal
  Write-TestHashSidecar (Join-Path $diagnosticRoot 'handoff.sha256') `
    'handoff.json' $diagnosticHandoffPath

  $diagnosticSummaryOriginal = Get-Content -LiteralPath `
    $diagnosticSummaryPath -Raw
  $invalidSummary = $diagnosticSummaryOriginal | ConvertFrom-Json
  $invalidSummary.checks[0].valid = $false
  Write-TestJson $diagnosticSummaryPath $invalidSummary
  $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
    Get-TestSha256 $diagnosticSummaryPath
  $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
    (Get-Item -LiteralPath $diagnosticSummaryPath).Length
  Write-TestJson $diagnosticManifestPath $diagnosticManifest
  $falseAssertionRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ManifestPath $diagnosticManifestPath | Out-Null
  } catch {
    $falseAssertionRejected = $_.Exception.Message -match
      'semantic assertion is not true'
  }
  Assert-Contract $falseAssertionRejected `
    'verifier accepted a false sealed HWCDC semantic assertion'
  Write-FixtureText $diagnosticSummaryPath $diagnosticSummaryOriginal
  $diagnosticManifest = Get-Content -LiteralPath $diagnosticManifestPath -Raw |
    ConvertFrom-Json
  $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
    Get-TestSha256 $diagnosticSummaryPath
  $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
    (Get-Item -LiteralPath $diagnosticSummaryPath).Length
  Write-TestJson $diagnosticManifestPath $diagnosticManifest

  $missingSummaryCheck = $diagnosticSummaryOriginal | ConvertFrom-Json
  $missingSummaryCheck.checks = @($missingSummaryCheck.checks |
    Where-Object {
      [string]$_.name -cne
        'diagnostic_connected_requires_payload_pickup_witness'
    })
  Write-TestJson $diagnosticSummaryPath $missingSummaryCheck
  $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
    Get-TestSha256 $diagnosticSummaryPath
  $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
    (Get-Item -LiteralPath $diagnosticSummaryPath).Length
  Write-TestJson $diagnosticManifestPath $diagnosticManifest
  $missingSummaryCheckRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ManifestPath $diagnosticManifestPath | Out-Null
  } catch {
    $missingSummaryCheckRejected = $_.Exception.Message -match
      'lacks required assertion: diagnostic_connected_requires_payload_pickup_witness'
  }
  Assert-Contract $missingSummaryCheckRejected `
    'verifier accepted a diagnostic summary without the payload witness check'
  Write-FixtureText $diagnosticSummaryPath $diagnosticSummaryOriginal
  $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
    Get-TestSha256 $diagnosticSummaryPath
  $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
    (Get-Item -LiteralPath $diagnosticSummaryPath).Length
  Write-TestJson $diagnosticManifestPath $diagnosticManifest

  $missingPayloadPrimeCheck = $diagnosticSummaryOriginal | ConvertFrom-Json
  $missingPayloadPrimeCheck.checks = @(
    $missingPayloadPrimeCheck.checks | Where-Object {
      [string]$_.name -cne
        'diagnostic_bootstrap_payload_primes_fifo_before_flush'
    })
  Write-TestJson $diagnosticSummaryPath $missingPayloadPrimeCheck
  $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
    Get-TestSha256 $diagnosticSummaryPath
  $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
    (Get-Item -LiteralPath $diagnosticSummaryPath).Length
  Write-TestJson $diagnosticManifestPath $diagnosticManifest
  $missingPayloadPrimeCheckRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ManifestPath $diagnosticManifestPath | Out-Null
  } catch {
    $missingPayloadPrimeCheckRejected =
      $_.Exception.Message -match
        'lacks required assertion: diagnostic_bootstrap_payload_primes_fifo_before_flush'
  }
  Assert-Contract $missingPayloadPrimeCheckRejected `
    'verifier accepted a diagnostic summary without the FIFO payload-prime check'
  Write-FixtureText $diagnosticSummaryPath $diagnosticSummaryOriginal
  $diagnosticManifest = Get-Content -LiteralPath $diagnosticManifestPath -Raw |
    ConvertFrom-Json
  $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
    Get-TestSha256 $diagnosticSummaryPath
  $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
    (Get-Item -LiteralPath $diagnosticSummaryPath).Length
  Write-TestJson $diagnosticManifestPath $diagnosticManifest

  $missingPublishOrderCheck = $diagnosticSummaryOriginal | ConvertFrom-Json
  $missingPublishOrderCheck.checks = @(
    $missingPublishOrderCheck.checks | Where-Object {
      [string]$_.name -cne
        'diagnostic_bootstrap_publishes_before_in_empty_enable'
    })
  Write-TestJson $diagnosticSummaryPath $missingPublishOrderCheck
  $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
    Get-TestSha256 $diagnosticSummaryPath
  $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
    (Get-Item -LiteralPath $diagnosticSummaryPath).Length
  Write-TestJson $diagnosticManifestPath $diagnosticManifest
  $missingPublishOrderRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ManifestPath $diagnosticManifestPath | Out-Null
  } catch {
    $missingPublishOrderRejected = $_.Exception.Message -match
      'lacks required assertion: diagnostic_bootstrap_publishes_before_in_empty_enable'
  }
  Assert-Contract $missingPublishOrderRejected `
    'verifier accepted a diagnostic summary without publish-before-enable proof'
  Write-FixtureText $diagnosticSummaryPath $diagnosticSummaryOriginal
  $diagnosticManifest = Get-Content -LiteralPath $diagnosticManifestPath -Raw |
    ConvertFrom-Json
  $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
    Get-TestSha256 $diagnosticSummaryPath
  $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
    (Get-Item -LiteralPath $diagnosticSummaryPath).Length
  Write-TestJson $diagnosticManifestPath $diagnosticManifest

  $missingPickupCompletionCheck =
    $diagnosticSummaryOriginal | ConvertFrom-Json
  $missingPickupCompletionCheck.checks = @(
    $missingPickupCompletionCheck.checks | Where-Object {
      [string]$_.name -cne
        'diagnostic_flush_requires_payload_pickup_completion'
    })
  Write-TestJson $diagnosticSummaryPath $missingPickupCompletionCheck
  $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
    Get-TestSha256 $diagnosticSummaryPath
  $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
    (Get-Item -LiteralPath $diagnosticSummaryPath).Length
  Write-TestJson $diagnosticManifestPath $diagnosticManifest
  $missingPickupCompletionRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ManifestPath $diagnosticManifestPath | Out-Null
  } catch {
    $missingPickupCompletionRejected = $_.Exception.Message -match
      'lacks required assertion: diagnostic_flush_requires_payload_pickup_completion'
  }
  Assert-Contract $missingPickupCompletionRejected `
    'verifier accepted a diagnostic summary without final pickup proof'
  Write-FixtureText $diagnosticSummaryPath $diagnosticSummaryOriginal
  $diagnosticManifest = Get-Content -LiteralPath $diagnosticManifestPath -Raw |
    ConvertFrom-Json
  $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
    Get-TestSha256 $diagnosticSummaryPath
  $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
    (Get-Item -LiteralPath $diagnosticSummaryPath).Length
  Write-TestJson $diagnosticManifestPath $diagnosticManifest

  foreach ($requiredNewCheck in @(
      'diagnostic_payload_publish_pending_closes_fifo_to_wrdone_gap',
      'diagnostic_payload_publish_abort_dominates_historical_success',
      'diagnostic_payload_flush_pending_binds_publication_to_new_flush_success',
      'in_empty_pickup_rechecks_bus_reset_under_mux',
      'late_pickup_reset_uses_raw_only_reset_discard',
      'postwrite_reset_quarantine_requires_positive_fifo_write'
    )) {
    $missingNewCheck = $diagnosticSummaryOriginal | ConvertFrom-Json
    $missingNewCheck.checks = @(
      $missingNewCheck.checks | Where-Object {
        [string]$_.name -cne $requiredNewCheck
      })
    Write-TestJson $diagnosticSummaryPath $missingNewCheck
    $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
      Get-TestSha256 $diagnosticSummaryPath
    $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
      (Get-Item -LiteralPath $diagnosticSummaryPath).Length
    Write-TestJson $diagnosticManifestPath $diagnosticManifest
    $missingNewCheckRejected = $false
    try {
      & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
        -ManifestPath $diagnosticManifestPath | Out-Null
    } catch {
      $missingNewCheckRejected = $_.Exception.Message -match
        "lacks required assertion: $([regex]::Escape($requiredNewCheck))"
    }
    Assert-Contract $missingNewCheckRejected `
      "verifier accepted a diagnostic summary without $requiredNewCheck"
    Write-FixtureText $diagnosticSummaryPath $diagnosticSummaryOriginal
    $diagnosticManifest = Get-Content -LiteralPath `
      $diagnosticManifestPath -Raw | ConvertFrom-Json
    $diagnosticManifest.hwcdc_semantic_contract.summary.sha256 =
      Get-TestSha256 $diagnosticSummaryPath
    $diagnosticManifest.hwcdc_semantic_contract.summary.size_bytes =
      (Get-Item -LiteralPath $diagnosticSummaryPath).Length
    Write-TestJson $diagnosticManifestPath $diagnosticManifest
  }

  # Re-sign only the mutable handoff/latest pair after removing the required
  # mode property.  This proves semantic rejection rather than hash rejection.
  [void]$diagnosticHandoff.PSObject.Properties.Remove(
    'runtime_fail_diagnostics_enabled')
  Write-TestJson $diagnosticHandoffPath $diagnosticHandoff
  Write-TestHashSidecar (Join-Path $diagnosticRoot 'handoff.sha256') `
    'handoff.json' $diagnosticHandoffPath
  $diagnosticLatest.handoff.sha256 = Get-TestSha256 $diagnosticHandoffPath
  Write-TestJson $diagnosticLatestPath $diagnosticLatest
  Write-TestHashSidecar (Join-Path $diagnosticBase 'latest.sha256') `
    'latest.json' $diagnosticLatestPath
  $missingModeRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -HandoffPath $diagnosticHandoffPath | Out-Null
  } catch {
    $missingModeRejected = $_.Exception.Message -match
      'runtime_fail_diagnostics_enabled'
  }
  Assert-Contract $missingModeRejected `
    'verifier did not semantically reject a missing diagnostic-mode flag'

  Assert-Contract ((Get-TestSha256 $sentinel) -ceq $sentinelBefore) `
    'normal Phase 6 artifact sentinel was overwritten'
  foreach ($role in @('vehicle', 'ground')) {
    $sketch = "vc_lora_${role}_xiao_esp32s3"
    $path = Join-Path (Join-Path $fixtureRoot $sketch) ($sketch + '.ino')
    Assert-Contract ((Get-TestSha256 $path) -ceq
        $wrapperHashesBefore[$role]) "default $role sketch was modified"
    Assert-Contract (-not (Test-Path -LiteralPath `
        (Join-Path (Join-Path $fixtureRoot $sketch) 'high_speed'))) `
      "candidate headers leaked into default $role sketch"
  }

  $vehicleBinary = Join-Path $secondRoot 'firmware\vehicle.application.bin'
  $stream = [IO.File]::Open($vehicleBinary, [IO.FileMode]::Append,
    [IO.FileAccess]::Write, [IO.FileShare]::Read)
  try {
    $stream.WriteByte(0x00)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
  $tamperRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -ArtifactRoot $secondRoot |
      Out-Null
  } catch {
    $tamperRejected = $true
  }
  Assert-Contract $tamperRejected 'verifier accepted a modified application'

  $diagnosticElf = Join-Path $diagnosticRoot `
    'evidence\build\vehicle\application.elf'
  $stream = [IO.File]::Open($diagnosticElf, [IO.FileMode]::Append,
    [IO.FileAccess]::Write, [IO.FileShare]::Read)
  try {
    $stream.WriteByte(0x00)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
  $debugTamperRejected = $false
  try {
    & $verifier -RepoRoot $fixtureRoot -RuntimeFailDiagnostics `
      -ArtifactRoot $diagnosticRoot | Out-Null
  } catch {
    $debugTamperRejected = $true
  }
  Assert-Contract $debugTamperRejected `
    'verifier accepted a modified reproducibility artifact'

  $negativeLatestSha = Get-TestSha256 $latestPath
  $negativeCases = @(
    [pscustomobject]@{
      name = 'build-output binary mismatch'
      variable = 'R19_FAKE_BUILD_BIN_MISMATCH'
      expected_error = 'build-path/output-dir application binary mismatch'
    },
    [pscustomobject]@{
      name = 'flash_args app offset 0x20000'
      variable = 'R19_FAKE_FLASH_OFFSET'
      value = '0x20000'
      expected_error = 'flash_args application offset'
    },
    [pscustomobject]@{
      name = 'partitions app offset 0x20000'
      variable = 'R19_FAKE_PARTITION_OFFSET'
      value = '0x20000'
      expected_error = 'partitions.csv target app offset'
    }
  )
  foreach ($negative in $negativeCases) {
    $value = if ($negative.PSObject.Properties['value']) {
      [string]$negative.value
    } else {
      '1'
    }
    [Environment]::SetEnvironmentVariable(
      [string]$negative.variable, $value, 'Process')
    $rejected = $false
    try {
      & $builder @builderArguments | Out-Null
    } catch {
      $rejected = $_.Exception.Message -match
        [regex]::Escape([string]$negative.expected_error)
    } finally {
      [Environment]::SetEnvironmentVariable(
        [string]$negative.variable, $null, 'Process')
    }
    Assert-Contract $rejected `
      "builder accepted negative case: $($negative.name)"
    Assert-Contract ((Get-TestSha256 $latestPath) -ceq $negativeLatestSha) `
      "negative case updated latest: $($negative.name)"
  }

  $diagnosticLatestBeforeElfNegatives = Get-TestSha256 $diagnosticLatestPath
  foreach ($mutation in @(
      'wrong-size', 'unaligned', 'overlap', 'missing', 'duplicate',
      'truncated', 'wrong-machine', 'first-wrong-size', 'first-unaligned',
      'first-overlap', 'first-missing', 'first-duplicate', 'first-outside-bss',
      'first-undefined', 'first-not-object')) {
    $env:R19_FAKE_ELF_MUTATION = $mutation
    $rejected = $false
    try {
      & $builder @builderArguments -RuntimeFailDiagnostics | Out-Null
    } catch {
      $rejected = $_.Exception.Message -match 'Diagnostic (symbol|ELF|symbols)'
    } finally {
      Remove-Item Env:R19_FAKE_ELF_MUTATION
    }
    Assert-Contract $rejected "builder accepted diagnostic ELF mutation: $mutation"
    Assert-Contract ((Get-TestSha256 $diagnosticLatestPath) -ceq
        $diagnosticLatestBeforeElfNegatives) `
      "invalid diagnostic ELF updated latest: $mutation"
  }

  Write-Output ("$testId PASS generations=2 selectors=4 " +
    "diagnostic_generation=1 missing_mode_rejected=true " +
    "semantic_false_rejected=true missing_summary_check_rejected=true " +
    "tamper_rejected=true debug_tamper_rejected=true " +
    "negative_publish_rejected=3 unknown_root_rejected=true " +
    "extension_mutations_rejected=32 elf_mutations_rejected=15 " +
    "handoff_seal_extension_mutations_rejected=8 legacy_v3_compatible=true legacy_v4_compatible=true " +
    "v4_undeclared_fifth_symbol_rejected=true decoder_dependency_bound=true " +
    "decoder_dependency_negatives_rejected=4 " +
    "undeclared_extension_symbols_rejected=true " +
    "latest_sha256=$secondLatestSha")
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
    Assert-Contract ($resolvedFixture.StartsWith(
        $fixturePrefix, [StringComparison]::OrdinalIgnoreCase)) `
      "refusing to remove unsafe fixture path: $resolvedFixture"
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
  }
}
