param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$writerPath = Join-Path $repo 'tools\write_phase6_firmware_manifest.ps1'
$verifierPath = Join-Path $repo 'tools\verify_phase6_firmware_manifest.ps1'
$compilePath = Join-Path $repo 'tools\compile_arduino.ps1'
$commonPath = Join-Path $repo 'tools\phase6_firmware_manifest_common.ps1'

function Read-RequiredFile([string]$Path, [string]$Description) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "FW-PHASE6-MANIFEST-TOOLS-001: missing $Description at $Path"
  }
  return Get-Content -LiteralPath $Path -Raw
}

function Require-Pattern([string]$Text, [string]$Pattern,
                         [string]$Description) {
  if ($Text -notmatch $Pattern) {
    throw "FW-PHASE6-MANIFEST-TOOLS-001: missing $Description"
  }
}

function Reject-Pattern([string]$Text, [string]$Pattern,
                        [string]$Description) {
  if ($Text -match $Pattern) {
    throw "FW-PHASE6-MANIFEST-TOOLS-001: found $Description"
  }
}

$common = Read-RequiredFile $commonPath 'shared source-tree implementation'
$writer = Read-RequiredFile $writerPath 'manifest writer'
$verifier = Read-RequiredFile $verifierPath 'manifest verifier'
$compile = Read-RequiredFile $compilePath 'Arduino compile driver'
. $commonPath

Require-Pattern $common 'function\s+Get-Phase6SourceSnapshot' `
  'one shared source snapshot implementation'
Require-Pattern $writer 'Firmware-Binary-Record\s+''vehicle''' `
  'Vehicle binary role binding'
Require-Pattern $writer 'Firmware-Binary-Record\s+''ground''' `
  'Ground binary role binding'
Require-Pattern $writer '\$flashPolicy\s*=\s*\[ordered\]@\{' `
  'explicit flash policy'
Require-Pattern $writer 'app_only\s*=\s*\$true' `
  'app-only flash policy'
Require-Pattern $writer 'offset\s*=\s*''0x10000''' `
  'application offset policy'
Reject-Pattern $writer 'phase6_host_tests' `
  'unverified fixed host-test count'

Require-Pattern $verifier 'expectedRoles\s*=\s*@\(' `
  'fixed binary-role sequence verification'
Require-Pattern $verifier 'flash_policy' 'flash-policy verification'
Require-Pattern $verifier '0x10000' 'application offset verification'
Require-Pattern $verifier '_flashed|bootloader|partition|merged|boot_app0' `
  'forbidden binary artifact verification'
Require-Pattern $verifier 'Get-Phase6SourceSnapshot' `
  'exact current source inventory verification'

Require-Pattern $compile 'Invalidate-Phase6PublishedMetadata' `
  'precompile stale-manifest invalidation'
Require-Pattern $compile 'Get-Phase6SourceSnapshot' `
  'compile input snapshot verification'
Require-Pattern $compile 'source tree changed during Arduino compile' `
  'source consistency failure'
Require-Pattern $compile 'finally\s*\{' `
  'failure cleanup path'
Require-Pattern $compile 'verify_phase6_firmware_manifest\.ps1' `
  'post-generation manifest verification'
Require-Pattern $compile 'Remove-Item[\s\S]{0,500}expectedBinary' `
  'stale role-binary removal before compile'
Require-Pattern $compile 'fresh application binary' `
  'fresh role-binary postcondition'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if ($parent) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) `
  ("vc_lora_phase6_manifest_contract_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
  foreach ($directory in @(
      'tools', 'tests\arduino_compile', 'tests\hil', 'core\src',
      'core\include\vc_lora', 'firmware\phase6',
      'third_party\esp32-core-3.3.11-vc-lora\cores\esp32',
      'vc_lora_vehicle_xiao_esp32s3\src',
      'vc_lora_vehicle_xiao_esp32s3\vc_lora',
      'vc_lora_ground_xiao_esp32s3\src',
      'vc_lora_ground_xiao_esp32s3\vc_lora',
      'runs\phase6_arduino_compile\vehicle',
      'runs\phase6_arduino_compile\ground',
      'runs\phase6_arduino_compile\hwcdc_contract',
      'installed_core'
    )) {
    New-Item -ItemType Directory -Path (Join-Path $fixture $directory) `
      -Force | Out-Null
  }

  Copy-Item -LiteralPath $commonPath -Destination `
    (Join-Path $fixture 'tools\phase6_firmware_manifest_common.ps1')
  Copy-Item -LiteralPath $writerPath -Destination `
    (Join-Path $fixture 'tools\write_phase6_firmware_manifest.ps1')
  Copy-Item -LiteralPath $verifierPath -Destination `
    (Join-Path $fixture 'tools\verify_phase6_firmware_manifest.ps1')

  foreach ($relative in @(
      'tools\compile_arduino.ps1',
      'tools\install_patched_esp32_hwcdc.ps1',
      'tools\invoke_phase6_manifest_flash.ps1',
      'tools\sync_arduino_sketch_core.ps1',
      'tests\arduino_compile\check_phase6_firmware_contract.ps1',
      'tests\arduino_compile\check_phase6_ide_compile.ps1',
      'tests\arduino_compile\check_hwcdc_tx_integrity_contract.ps1',
      'tests\arduino_compile\check_phase6_compile_publication_behavior.ps1',
      'tests\arduino_compile\check_phase6_manifest_tooling_contract.ps1',
      'tests\hil\check_phase6_manifest_flash_contract.ps1',
      'core\src\fixture.cpp',
      'core\include\vc_lora\fixture.hpp',
      'firmware\phase6\fixture.hpp'
    )) {
    Write-Utf8NoBom (Join-Path $fixture $relative) "fixture:$relative`n"
  }
  foreach ($role in @(
      'vc_lora_vehicle_xiao_esp32s3',
      'vc_lora_ground_xiao_esp32s3'
    )) {
    foreach ($relative in @(
        "$role.ino", 'VC_LoRa_Core.h', 'vc_lora_phase6_bridge.hpp',
        'src\fixture.cpp', 'vc_lora\fixture.hpp'
      )) {
      Write-Utf8NoBom (Join-Path $fixture "$role\$relative") `
        "fixture:$role/$relative`n"
    }
  }

  $canonicalCpp = Join-Path $fixture `
    'third_party\esp32-core-3.3.11-vc-lora\cores\esp32\HWCDC.cpp'
  $canonicalHeader = Join-Path $fixture `
    'third_party\esp32-core-3.3.11-vc-lora\cores\esp32\HWCDC.h'
  $canonicalDiagnosticHeader = Join-Path $fixture `
    'third_party\esp32-core-3.3.11-vc-lora\cores\esp32\HWCDCR19Diagnostic.h'
  $installedCpp = Join-Path $fixture 'installed_core\HWCDC.cpp'
  $installedHeader = Join-Path $fixture 'installed_core\HWCDC.h'
  $installedDiagnosticHeader = Join-Path $fixture `
    'installed_core\HWCDCR19Diagnostic.h'
  Write-Utf8NoBom $canonicalCpp "canonical-cpp`n"
  Write-Utf8NoBom $canonicalHeader "canonical-header`n"
  Write-Utf8NoBom $canonicalDiagnosticHeader `
    "canonical-r19-diagnostic-header`n"
  Copy-Item -LiteralPath $canonicalCpp -Destination $installedCpp -Force
  Copy-Item -LiteralPath $canonicalHeader -Destination $installedHeader -Force
  Copy-Item -LiteralPath $canonicalDiagnosticHeader `
    -Destination $installedDiagnosticHeader -Force

  $vehicleBinary = Join-Path $fixture `
    'runs\phase6_arduino_compile\vehicle\vc_lora_vehicle_xiao_esp32s3.ino.bin'
  $groundBinary = Join-Path $fixture `
    'runs\phase6_arduino_compile\ground\vc_lora_ground_xiao_esp32s3.ino.bin'
  Write-Utf8NoBom $vehicleBinary 'vehicle-app'
  Write-Utf8NoBom $groundBinary 'ground-app'

  $canonicalCppHash = (Get-FileHash -LiteralPath $canonicalCpp `
    -Algorithm SHA256).Hash
  $canonicalHeaderHash = (Get-FileHash -LiteralPath $canonicalHeader `
    -Algorithm SHA256).Hash
  $canonicalDiagnosticHeaderHash = (Get-FileHash `
    -LiteralPath $canonicalDiagnosticHeader -Algorithm SHA256).Hash
  $summaryPath = Join-Path $fixture `
    'runs\phase6_arduino_compile\hwcdc_contract\summary.json'
  $hwcdcSummaryObject = [ordered]@{
    schema_version = 1
    test = 'FW-HWCDC-TX-INTEGRITY-001'
    result = 'PASS'
    fqbn = 'esp32:esp32:XIAO_ESP32S3'
    expected_core_version = '3.3.11'
    actual_core_version = '3.3.11'
    hwcdc_path = $installedCpp
    hwcdc_sha256 = $canonicalCppHash
    hwcdc_header_path = $installedHeader
    hwcdc_header_sha256 = $canonicalHeaderHash
    diagnostic_header_path = $installedDiagnosticHeader
    diagnostic_header_sha256 = $canonicalDiagnosticHeaderHash
    canonical_hwcdc_path = $canonicalCpp
    canonical_hwcdc_sha256 = $canonicalCppHash
    canonical_hwcdc_header_path = $canonicalHeader
    canonical_hwcdc_header_sha256 = $canonicalHeaderHash
    canonical_diagnostic_header_path = $canonicalDiagnosticHeader
    canonical_diagnostic_header_sha256 =
      $canonicalDiagnosticHeaderHash
    checks = @(
      [ordered]@{ name = 'esp32_core_version_exact'; valid = $true },
      [ordered]@{
        name = 'installed_core_matches_canonical_patch'; valid = $true
      },
      [ordered]@{ name = 'epoch_checked_write_linearization'; valid = $true },
      [ordered]@{
        name = 'bus_reset_quarantines_ring_before_tx'; valid = $true
      },
      [ordered]@{
        name = 'diagnostic_bootstrap_api_macro_scoped'; valid = $true
      },
      [ordered]@{
        name = 'diagnostic_bootstrap_exact_63_byte_cold_start_only'
        valid = $true
      },
      [ordered]@{
        name = 'diagnostic_bootstrap_requires_clean_empty_boundary'
        valid = $true
      },
      [ordered]@{
        name = 'diagnostic_bootstrap_all_or_zero_publication_fence'
        valid = $true
      },
      [ordered]@{
        name = 'diagnostic_bootstrap_payload_primes_fifo_before_flush'
        valid = $true
      },
      [ordered]@{
        name = 'diagnostic_bootstrap_publishes_before_in_empty_enable'
        valid = $true
      },
      [ordered]@{
        name = 'diagnostic_bootstrap_rechecks_epoch_reset_and_presence'
        valid = $true
      },
      [ordered]@{
        name = 'diagnostic_bootstrap_isr_fence_before_ring_and_fifo'
        valid = $true
      },
      [ordered]@{
        name = 'diagnostic_bootstrap_serializes_debug_writer'; valid = $true
      },
      [ordered]@{
        name = 'diagnostic_flush_requires_payload_pickup_completion'
        valid = $true
      },
      [ordered]@{
        name = 'diagnostic_fifo_record_macro_scoped'; valid = $true
      },
      [ordered]@{
        name = 'diagnostic_fifo_record_fixed_abi'; valid = $true
      },
      [ordered]@{
        name = 'diagnostic_fifo_record_tracks_fifo_write_and_wr_done'
        valid = $true
      },
      [ordered]@{
        name = 'diagnostic_fifo_record_distinguishes_raw_in_empty_from_payload_pickup'
        valid = $true
      },
      [ordered]@{
        name = 'diagnostic_fifo_record_tracks_generation_reset_and_flush_outcome'
        valid = $true
      },
      [ordered]@{ name = 'loss_epoch_api'; valid = $true },
      [ordered]@{ name = 'non_destructive_result_flush'; valid = $true }
    )
    failures = @()
  }
  $hwcdcSummaryJson = ($hwcdcSummaryObject | ConvertTo-Json -Depth 8) + "`n"
  Write-Utf8NoBom $summaryPath $hwcdcSummaryJson

  $fixtureWriter = Join-Path $fixture `
    'tools\write_phase6_firmware_manifest.ps1'
  $fixtureVerifier = Join-Path $fixture `
    'tools\verify_phase6_firmware_manifest.ps1'
  & $fixtureWriter -RepoRoot $fixture -ArduinoCliVersion 'fixture' `
    -Esp32CoreVersion '3.3.11' `
    -VehicleFlashBytes 1 -VehicleFlashPercent 1 `
    -VehicleRamBytes 1 -VehicleRamPercent 1 `
    -GroundFlashBytes 1 -GroundFlashPercent 1 `
    -GroundRamBytes 1 -GroundRamPercent 1 | Out-Null
  & $fixtureVerifier -RepoRoot $fixture | Out-Null

  $fixtureManifestPath = Join-Path $fixture `
    'runs\phase6_arduino_compile\firmware_manifest.json'
  $pristineManifestJson = Get-Content -LiteralPath $fixtureManifestPath -Raw

  function Reset-FixtureState {
    Copy-Item -LiteralPath $canonicalCpp -Destination $installedCpp -Force
    Copy-Item -LiteralPath $canonicalHeader -Destination $installedHeader -Force
    Copy-Item -LiteralPath $canonicalDiagnosticHeader `
      -Destination $installedDiagnosticHeader -Force
    Write-Utf8NoBom $summaryPath $hwcdcSummaryJson
  }

  function Assert-ManifestRejected([string]$Name, [scriptblock]$Mutate,
                                   [string]$ExpectedMessage) {
    Reset-FixtureState
    $candidate = $pristineManifestJson | ConvertFrom-Json
    & $Mutate $candidate
    Write-Utf8NoBom $fixtureManifestPath `
      (($candidate | ConvertTo-Json -Depth 12) + "`n")
    $caught = $null
    try {
      & $fixtureVerifier -RepoRoot $fixture | Out-Null
    } catch {
      $caught = $_.Exception.Message
    }
    if ($null -eq $caught) {
      throw "FW-PHASE6-MANIFEST-TOOLS-001: verifier accepted $Name"
    }
    if ($caught -notmatch $ExpectedMessage) {
      throw ("FW-PHASE6-MANIFEST-TOOLS-001: $Name produced unexpected " +
        "failure: $caught")
    }
  }

  function Assert-HwcdcSummaryRejected([string]$Name,
                                       [scriptblock]$Mutate,
                                       [string]$ExpectedMessage) {
    Reset-FixtureState
    $candidate = $pristineManifestJson | ConvertFrom-Json
    $summary = $hwcdcSummaryJson | ConvertFrom-Json
    & $Mutate $summary
    Write-Utf8NoBom $summaryPath `
      (($summary | ConvertTo-Json -Depth 12) + "`n")
    $summaryRecord = New-Phase6FileRecord $fixture `
      (Get-Item -LiteralPath $summaryPath)
    $candidate.hwcdc_contract.summary.path = $summaryRecord.path
    $candidate.hwcdc_contract.summary.size_bytes = $summaryRecord.size_bytes
    $candidate.hwcdc_contract.summary.sha256 = $summaryRecord.sha256
    Write-Utf8NoBom $fixtureManifestPath `
      (($candidate | ConvertTo-Json -Depth 12) + "`n")
    $caught = $null
    try {
      & $fixtureVerifier -RepoRoot $fixture | Out-Null
    } catch {
      $caught = $_.Exception.Message
    }
    if ($null -eq $caught) {
      throw "FW-PHASE6-MANIFEST-TOOLS-001: verifier accepted $Name"
    }
    if ($caught -notmatch $ExpectedMessage) {
      throw ("FW-PHASE6-MANIFEST-TOOLS-001: $Name produced unexpected " +
        "failure: $caught")
    }
  }

  Assert-ManifestRejected 'reordered source inventory' {
    param($manifest)
    $first = $manifest.sources[0]
    $manifest.sources[0] = $manifest.sources[1]
    $manifest.sources[1] = $first
    $manifest.source_tree_sha256 = Get-Phase6CanonicalTreeHash `
      @($manifest.sources)
  } 'source inventory mismatch'

  Assert-ManifestRejected 'swapped compile order' {
    param($manifest)
    $manifest.compile_order = @('ground', 'vehicle')
  } 'compile order mismatch'

  Assert-ManifestRejected 'binary role mismatch' {
    param($manifest)
    $manifest.binaries[0].role = 'ground'
  } 'binary role/order mismatch'

  Assert-ManifestRejected 'string-valued app-only policy' {
    param($manifest)
    $manifest.flash_policy.app_only = 'true'
  } 'app-only 0x10000'

  Assert-ManifestRejected 'wrong application offset' {
    param($manifest)
    $manifest.flash_policy.offset = '0xe000'
  } 'app-only 0x10000'

  foreach ($forbiddenName in @(
      'vehicle_flashed.bin', 'vehicle.bootloader.bin',
      'vehicle.partitions.bin', 'vehicle.merged.bin', 'boot_app0.bin'
    )) {
    $forbiddenPath = Join-Path (Split-Path -Parent $vehicleBinary) `
      $forbiddenName
    Copy-Item -LiteralPath $vehicleBinary -Destination $forbiddenPath -Force
    Assert-ManifestRejected "forbidden selection $forbiddenName" {
      param($manifest)
      $record = New-Phase6FileRecord $fixture `
        (Get-Item -LiteralPath $forbiddenPath)
      $manifest.binaries[0].path = $record.path
      $manifest.binaries[0].size_bytes = $record.size_bytes
      $manifest.binaries[0].sha256 = $record.sha256
    } 'Forbidden firmware artifact selected'
  }

  Assert-ManifestRejected 'manifest/summary HWCDC hash mismatch' {
    param($manifest)
    $manifest.hwcdc_contract.hwcdc_sha256 = 'A' * 64
  } 'manifest/summary hash binding mismatch'

  Assert-ManifestRejected 'manifest/summary diagnostic-header hash mismatch' {
    param($manifest)
    $manifest.hwcdc_contract.diagnostic_header_sha256 = 'A' * 64
  } 'manifest/summary hash binding mismatch'

  Assert-ManifestRejected 'installed/canonical HWCDC mismatch' {
    param($manifest)
    Write-Utf8NoBom $installedCpp "different-installed-cpp`n"
    $changedHash = (Get-FileHash -LiteralPath $installedCpp `
      -Algorithm SHA256).Hash
    $summary = $hwcdcSummaryJson | ConvertFrom-Json
    $summary.hwcdc_sha256 = $changedHash
    Write-Utf8NoBom $summaryPath `
      (($summary | ConvertTo-Json -Depth 8) + "`n")
    $summaryRecord = New-Phase6FileRecord $fixture `
      (Get-Item -LiteralPath $summaryPath)
    $manifest.hwcdc_contract.hwcdc_sha256 = $changedHash
    $manifest.hwcdc_contract.summary.path = $summaryRecord.path
    $manifest.hwcdc_contract.summary.size_bytes = $summaryRecord.size_bytes
    $manifest.hwcdc_contract.summary.sha256 = $summaryRecord.sha256
  } 'does not match the canonical patch'

  Assert-HwcdcSummaryRejected 'missing diagnostic bootstrap semantic check' {
    param($summary)
    $summary.checks = @($summary.checks | Where-Object {
        $_.name -cne 'diagnostic_bootstrap_isr_fence_before_ring_and_fifo'
      })
  } 'lacks required check: diagnostic_bootstrap_isr_fence_before_ring_and_fifo'

  Assert-HwcdcSummaryRejected 'missing FIFO payload-prime semantic check' {
    param($summary)
    $summary.checks = @($summary.checks | Where-Object {
        $_.name -cne 'diagnostic_bootstrap_payload_primes_fifo_before_flush'
      })
  } 'lacks required check: diagnostic_bootstrap_payload_primes_fifo_before_flush'

  Assert-HwcdcSummaryRejected 'missing publish-before-enable semantic check' {
    param($summary)
    $summary.checks = @($summary.checks | Where-Object {
        $_.name -cne
          'diagnostic_bootstrap_publishes_before_in_empty_enable'
      })
  } 'lacks required check: diagnostic_bootstrap_publishes_before_in_empty_enable'

  Assert-HwcdcSummaryRejected 'missing final payload-pickup semantic check' {
    param($summary)
    $summary.checks = @($summary.checks | Where-Object {
        $_.name -cne
          'diagnostic_flush_requires_payload_pickup_completion'
      })
  } 'lacks required check: diagnostic_flush_requires_payload_pickup_completion'

  Assert-HwcdcSummaryRejected 'missing FIFO record semantic check' {
    param($summary)
    $summary.checks = @($summary.checks | Where-Object {
        $_.name -cne 'diagnostic_fifo_record_fixed_abi'
      })
  } 'lacks required check: diagnostic_fifo_record_fixed_abi'

  Assert-HwcdcSummaryRejected 'false diagnostic bootstrap semantic check' {
    param($summary)
    @($summary.checks | Where-Object {
        $_.name -ceq 'diagnostic_bootstrap_all_or_zero_publication_fence'
      })[0].valid = $false
  } 'not a clean exact-version PASS'

  Assert-HwcdcSummaryRejected 'duplicate diagnostic bootstrap semantic check' {
    param($summary)
    $summary.checks = @($summary.checks) + @(
      [pscustomobject]@{
        name = 'diagnostic_bootstrap_api_macro_scoped'; valid = $true
      })
  } 'duplicate check names'

  Write-Utf8NoBom $fixtureManifestPath $pristineManifestJson
  Reset-FixtureState
  & $fixtureVerifier -RepoRoot $fixture | Out-Null
} finally {
  $expectedPrefix = [IO.Path]::GetTempPath()
  if ($fixture.StartsWith($expectedPrefix,
      [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $fixture) -match
        '^vc_lora_phase6_manifest_contract_[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $fixture)) {
    Remove-Item -LiteralPath $fixture -Recurse -Force
  }
}

Write-Output 'FW-PHASE6-MANIFEST-TOOLS-001 PASS'
