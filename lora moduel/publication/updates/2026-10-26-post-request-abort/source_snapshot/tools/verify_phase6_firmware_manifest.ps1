param(
  [string]$ManifestPath,
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
. (Join-Path $PSScriptRoot 'phase6_firmware_manifest_common.ps1')

$expectedManifestPath = Join-Path $repo `
  'runs\phase6_arduino_compile\firmware_manifest.json'
if (-not $ManifestPath) {
  $ManifestPath = $expectedManifestPath
}
$manifestFile = Get-Item -LiteralPath $ManifestPath -ErrorAction Stop
if ($manifestFile.FullName -cne $expectedManifestPath) {
  throw "Unexpected firmware manifest location: $($manifestFile.FullName)"
}
$manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw |
  ConvertFrom-Json
if ($manifest.schema -cne 'vc-lora-phase6-firmware-manifest-v2') {
  throw "Unsupported firmware manifest schema: $($manifest.schema)"
}
if ($manifest.fqbn -cne 'esp32:esp32:XIAO_ESP32S3') {
  throw "Unexpected firmware FQBN: $($manifest.fqbn)"
}
if ($manifest.esp32_core -cne '3.3.11') {
  throw "Unexpected ESP32 core version: $($manifest.esp32_core)"
}

function Assert-ExactStringArray([object[]]$Actual, [string[]]$Expected,
                                 [string]$Description) {
  $actualArray = @($Actual)
  if ($actualArray.Count -ne $Expected.Count) {
    throw "$Description count mismatch"
  }
  for ($i = 0; $i -lt $Expected.Count; ++$i) {
    if ([string]$actualArray[$i] -cne $Expected[$i]) {
      throw "$Description mismatch at position $i"
    }
  }
}

function Assert-RecordShape($Record, [string[]]$ExpectedProperties,
                            [string]$Description) {
  if ($null -eq $Record) {
    throw "$Description is missing"
  }
  $actual = [string[]]@($Record.PSObject.Properties.Name)
  [Array]::Sort($actual, [StringComparer]::Ordinal)
  $expected = [string[]]@($ExpectedProperties)
  [Array]::Sort($expected, [StringComparer]::Ordinal)
  Assert-ExactStringArray $actual $expected "$Description property set"
}

function Resolve-ManifestFile([string]$RelativePath) {
  if ([string]::IsNullOrWhiteSpace($RelativePath) -or
      [IO.Path]::IsPathRooted($RelativePath)) {
    throw "Manifest path must be repository-relative: $RelativePath"
  }
  $candidate = [IO.Path]::GetFullPath(
    (Join-Path $repo ($RelativePath.Replace('/', '\'))))
  $prefix = $repo + [IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith(
      $prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Manifest path escaped repository: $RelativePath"
  }
  return Get-Item -LiteralPath $candidate -ErrorAction Stop
}

function Verify-Record($Record, [string]$Description) {
  if ([string]$Record.path -cnotmatch '^[^\\]+(?:/[^\\]+)*$') {
    throw "$Description has a non-canonical path: $($Record.path)"
  }
  if ([string]$Record.sha256 -cnotmatch '^[0-9A-F]{64}$') {
    throw "$Description has a non-canonical SHA-256"
  }
  $recordedSize = 0L
  if (-not [int64]::TryParse([string]$Record.size_bytes,
      [Globalization.NumberStyles]::None,
      [Globalization.CultureInfo]::InvariantCulture,
      [ref]$recordedSize) -or $recordedSize -lt 0) {
    throw "$Description has an invalid size"
  }
  $file = Resolve-ManifestFile ([string]$Record.path)
  $actual = New-Phase6FileRecord $repo $file
  if ($actual.path -cne [string]$Record.path) {
    throw "$Description path casing or normalization mismatch"
  }
  if ($actual.size_bytes -ne $recordedSize) {
    throw "$Description size mismatch: $($Record.path)"
  }
  if ($actual.sha256 -cne [string]$Record.sha256) {
    throw "$Description SHA-256 mismatch: $($Record.path)"
  }
  return $file
}

$expectedRoles = @('vehicle', 'ground')
Assert-ExactStringArray @($manifest.compile_order) $expectedRoles `
  'compile order'

$policy = $manifest.flash_policy
$policyFields = @(
  'mode', 'app_only', 'offset', 'upload_order', 'erase_flash',
  'write_bootloader', 'write_partition_table', 'write_merged_image',
  'forbidden_selection_patterns'
)
Assert-RecordShape $policy $policyFields 'flash policy'
if ($policy.mode -cne 'app-only' -or
    $policy.app_only -isnot [bool] -or -not $policy.app_only -or
    $policy.offset -cne '0x10000' -or
    $policy.erase_flash -isnot [bool] -or $policy.erase_flash -or
    $policy.write_bootloader -isnot [bool] -or $policy.write_bootloader -or
    $policy.write_partition_table -isnot [bool] -or
      $policy.write_partition_table -or
    $policy.write_merged_image -isnot [bool] -or
      $policy.write_merged_image) {
  throw 'Manifest does not require an app-only 0x10000 non-erasing flash'
}
Assert-ExactStringArray @($policy.upload_order) $expectedRoles `
  'flash upload order'
$forbiddenPatterns = @(
  '*_flashed.bin', '*bootloader*.bin', '*partition*.bin', '*merged*.bin',
  '*boot_app0*.bin'
)
Assert-ExactStringArray @($policy.forbidden_selection_patterns) `
  $forbiddenPatterns 'forbidden artifact patterns'

$expectedSnapshot = Get-Phase6SourceSnapshot $repo
$sourceRecords = @($manifest.sources)
if ($sourceRecords.Count -ne [int]$manifest.source_file_count -or
    $sourceRecords.Count -ne [int]$expectedSnapshot.file_count) {
  throw 'Manifest source-file count mismatch'
}
for ($i = 0; $i -lt $sourceRecords.Count; ++$i) {
  $record = $sourceRecords[$i]
  $expected = $expectedSnapshot.records[$i]
  Assert-RecordShape $record @('path', 'size_bytes', 'sha256') `
    "source record $i"
  if ($record.path -cne $expected.path -or
      [int64]$record.size_bytes -ne [int64]$expected.size_bytes -or
      $record.sha256 -cne $expected.sha256) {
    throw "Manifest source inventory mismatch at position $i"
  }
  [void](Verify-Record $record "source record $i")
}
$manifestTreeHash = Get-Phase6CanonicalTreeHash $sourceRecords
if ($manifestTreeHash -cne [string]$manifest.source_tree_sha256 -or
    $manifestTreeHash -cne [string]$expectedSnapshot.tree_sha256) {
  throw 'Manifest canonical source-tree hash mismatch'
}

$binaryRecords = @($manifest.binaries)
if ($binaryRecords.Count -ne 2) {
  throw 'Manifest must select exactly Vehicle and Ground binaries'
}
$expectedBinaryPaths = @(
  'runs/phase6_arduino_compile/vehicle/vc_lora_vehicle_xiao_esp32s3.ino.bin',
  'runs/phase6_arduino_compile/ground/vc_lora_ground_xiao_esp32s3.ino.bin'
)
for ($i = 0; $i -lt $binaryRecords.Count; ++$i) {
  $record = $binaryRecords[$i]
  Assert-RecordShape $record @('role', 'path', 'size_bytes', 'sha256') `
    "binary record $i"
  if ($record.role -cne $expectedRoles[$i]) {
    throw "Firmware binary role/order mismatch at position $i"
  }
  if ([string]$record.path -match
      '(?i)(?:_flashed|bootloader|partitions?|merged|boot_app0).*\.bin$') {
    throw "Forbidden firmware artifact selected: $($record.path)"
  }
  if ($record.path -cne $expectedBinaryPaths[$i]) {
    throw "Firmware binary path mismatch for role $($record.role)"
  }
  [void](Verify-Record $record "binary record $i")
}

$hwcdcContract = $manifest.hwcdc_contract
if ($hwcdcContract.result -cne 'PASS' -or
    $hwcdcContract.actual_core_version -cne '3.3.11') {
  throw 'Manifest-bound HWCDC contract did not pass for ESP32 core 3.3.11'
}
$hwcdcSummaryRecord = $hwcdcContract.summary
Assert-RecordShape $hwcdcSummaryRecord @('path', 'size_bytes', 'sha256') `
  'HWCDC summary record'
if ($hwcdcSummaryRecord.path -cne
    'runs/phase6_arduino_compile/hwcdc_contract/summary.json') {
  throw 'Unexpected HWCDC contract summary path'
}
$hwcdcSummaryFile = Verify-Record $hwcdcSummaryRecord `
  'HWCDC summary record'
$hwcdc = Get-Content -LiteralPath $hwcdcSummaryFile.FullName -Raw |
  ConvertFrom-Json
if ([int]$hwcdc.schema_version -ne 1 -or
    $hwcdc.test -cne 'FW-HWCDC-TX-INTEGRITY-001' -or
    $hwcdc.result -cne 'PASS' -or
    $hwcdc.fqbn -cne 'esp32:esp32:XIAO_ESP32S3' -or
    $hwcdc.expected_core_version -cne '3.3.11' -or
    $hwcdc.actual_core_version -cne '3.3.11' -or
    @($hwcdc.failures).Count -ne 0 -or
    @($hwcdc.checks).Count -eq 0 -or
    @($hwcdc.checks | Where-Object { $_.valid -ne $true }).Count -ne 0) {
  throw 'HWCDC contract summary is not a clean exact-version PASS'
}
if ($hwcdc.hwcdc_sha256 -cne $hwcdc.canonical_hwcdc_sha256 -or
    $hwcdc.hwcdc_header_sha256 -cne
      $hwcdc.canonical_hwcdc_header_sha256 -or
    $hwcdc.diagnostic_header_sha256 -cne
      $hwcdc.canonical_diagnostic_header_sha256) {
  throw 'Installed HWCDC implementation does not match the canonical patch'
}
$hwcdcCheckNames = @($hwcdc.checks | ForEach-Object { [string]$_.name })
if (@($hwcdcCheckNames | Sort-Object -Unique).Count -ne
    $hwcdcCheckNames.Count) {
  throw 'HWCDC contract summary contains duplicate check names'
}
foreach ($requiredCheck in @(
    'esp32_core_version_exact',
    'installed_core_matches_canonical_patch',
    'epoch_checked_write_linearization',
    'bus_reset_quarantines_ring_before_tx',
    'diagnostic_bootstrap_api_macro_scoped',
    'diagnostic_bootstrap_exact_63_byte_cold_start_only',
    'diagnostic_bootstrap_requires_clean_empty_boundary',
    'diagnostic_bootstrap_all_or_zero_publication_fence',
    'diagnostic_bootstrap_payload_primes_fifo_before_flush',
    'diagnostic_bootstrap_publishes_before_in_empty_enable',
    'diagnostic_bootstrap_rechecks_epoch_reset_and_presence',
    'diagnostic_bootstrap_isr_fence_before_ring_and_fifo',
    'diagnostic_bootstrap_serializes_debug_writer',
    'diagnostic_flush_requires_payload_pickup_completion',
    'diagnostic_fifo_record_macro_scoped',
    'diagnostic_fifo_record_fixed_abi',
    'diagnostic_fifo_record_tracks_fifo_write_and_wr_done',
    'diagnostic_fifo_record_distinguishes_raw_in_empty_from_payload_pickup',
    'diagnostic_fifo_record_tracks_generation_reset_and_flush_outcome',
    'loss_epoch_api',
    'non_destructive_result_flush'
  )) {
  if ($hwcdcCheckNames -cnotcontains $requiredCheck) {
    throw "HWCDC contract summary lacks required check: $requiredCheck"
  }
}

$canonicalCpp = Join-Path $repo `
  'third_party\esp32-core-3.3.11-vc-lora\cores\esp32\HWCDC.cpp'
$canonicalHeader = Join-Path $repo `
  'third_party\esp32-core-3.3.11-vc-lora\cores\esp32\HWCDC.h'
$canonicalDiagnosticHeader = Join-Path $repo `
  'third_party\esp32-core-3.3.11-vc-lora\cores\esp32\HWCDCR19Diagnostic.h'
if ((Resolve-Path -LiteralPath $hwcdc.canonical_hwcdc_path).Path -cne
      (Resolve-Path -LiteralPath $canonicalCpp).Path -or
    (Resolve-Path -LiteralPath $hwcdc.canonical_hwcdc_header_path).Path -cne
      (Resolve-Path -LiteralPath $canonicalHeader).Path -or
    (Resolve-Path -LiteralPath `
        $hwcdc.canonical_diagnostic_header_path).Path -cne
      (Resolve-Path -LiteralPath $canonicalDiagnosticHeader).Path) {
  throw 'HWCDC summary does not bind the canonical vendored patch'
}

foreach ($binding in @(
    @('hwcdc_path', 'hwcdc_sha256'),
    @('hwcdc_header_path', 'hwcdc_header_sha256'),
    @('diagnostic_header_path', 'diagnostic_header_sha256'),
    @('canonical_hwcdc_path', 'canonical_hwcdc_sha256'),
    @('canonical_hwcdc_header_path', 'canonical_hwcdc_header_sha256'),
    @('canonical_diagnostic_header_path',
      'canonical_diagnostic_header_sha256')
  )) {
  $pathProperty = $binding[0]
  $hashProperty = $binding[1]
  $summaryHash = [string]$hwcdc.$hashProperty
  $manifestHash = [string]$hwcdcContract.$hashProperty
  if ($summaryHash -cnotmatch '^[0-9A-F]{64}$' -or
      $manifestHash -cne $summaryHash) {
    throw "HWCDC manifest/summary hash binding mismatch: $hashProperty"
  }
  $file = Get-Item -LiteralPath ([string]$hwcdc.$pathProperty) `
    -ErrorAction Stop
  $actualHash = (Get-FileHash -LiteralPath $file.FullName `
    -Algorithm SHA256).Hash.ToUpperInvariant()
  if ($actualHash -cne $manifestHash) {
    throw "HWCDC build-input SHA-256 mismatch: $($file.FullName)"
  }
}

Write-Output ('FW-PHASE6-MANIFEST-VERIFY-001 PASS ' +
  "manifest=$($manifestFile.FullName)")
foreach ($record in $binaryRecords) {
  Write-Output "$($record.role):$($record.path)=$($record.sha256)"
}
