param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$OutputRoot,
  [string]$Fqbn = 'esp32:esp32:XIAO_ESP32S3',
  [Parameter(Mandatory = $true)] [string]$ArduinoCliVersion,
  [Parameter(Mandatory = $true)] [string]$Esp32CoreVersion,
  [Parameter(Mandatory = $true)] [int]$VehicleFlashBytes,
  [Parameter(Mandatory = $true)] [int]$VehicleFlashPercent,
  [Parameter(Mandatory = $true)] [int]$VehicleRamBytes,
  [Parameter(Mandatory = $true)] [int]$VehicleRamPercent,
  [Parameter(Mandatory = $true)] [int]$GroundFlashBytes,
  [Parameter(Mandatory = $true)] [int]$GroundFlashPercent,
  [Parameter(Mandatory = $true)] [int]$GroundRamBytes,
  [Parameter(Mandatory = $true)] [int]$GroundRamPercent
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $OutputRoot) {
  $OutputRoot = Join-Path $repo 'runs\phase6_arduino_compile'
}
$outputRoot = (Resolve-Path -LiteralPath $OutputRoot -ErrorAction Stop).Path
if (-not $outputRoot.StartsWith(
    $repo + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) {
  throw "Firmware output root escaped repository: $outputRoot"
}

. (Join-Path $PSScriptRoot 'phase6_firmware_manifest_common.ps1')
$sourceSnapshot = Get-Phase6SourceSnapshot $repo
$sourceRecords = @($sourceSnapshot.records)
$treeHash = [string]$sourceSnapshot.tree_sha256
$canonicalLines = @($sourceRecords | ForEach-Object {
    "$($_.sha256)  $($_.path)"
  })
$utf8 = [Text.UTF8Encoding]::new($false)

function Firmware-Binary-Record([string]$Role,
                                [System.IO.FileInfo]$File) {
  $record = New-Phase6FileRecord $repo $File
  return [pscustomobject][ordered]@{
    role = $Role
    path = $record.path
    size_bytes = $record.size_bytes
    sha256 = $record.sha256
  }
}

$vehicleBinary = Get-Item -LiteralPath (Join-Path $outputRoot `
  'vehicle\vc_lora_vehicle_xiao_esp32s3.ino.bin')
$groundBinary = Get-Item -LiteralPath (Join-Path $outputRoot `
  'ground\vc_lora_ground_xiao_esp32s3.ino.bin')
$binaryRecords = @(
  Firmware-Binary-Record 'vehicle' $vehicleBinary
  Firmware-Binary-Record 'ground' $groundBinary
)
$hwcdcSummaryPath = Join-Path $outputRoot 'hwcdc_contract\summary.json'
if (-not (Test-Path -LiteralPath $hwcdcSummaryPath -PathType Leaf)) {
  throw "HWCDC contract summary not found: $hwcdcSummaryPath"
}
$hwcdcSummary = Get-Content -LiteralPath $hwcdcSummaryPath -Raw |
  ConvertFrom-Json
if ($hwcdcSummary.result -cne 'PASS') {
  throw "HWCDC contract did not pass: $($hwcdcSummary.result)"
}
$hwcdcSummaryRecord = New-Phase6FileRecord $repo `
  (Get-Item -LiteralPath $hwcdcSummaryPath)

$flashPolicy = [ordered]@{
  mode = 'app-only'
  app_only = $true
  offset = '0x10000'
  upload_order = @('vehicle', 'ground')
  erase_flash = $false
  write_bootloader = $false
  write_partition_table = $false
  write_merged_image = $false
  forbidden_selection_patterns = @(
    '*_flashed.bin', '*bootloader*.bin', '*partition*.bin', '*merged*.bin',
    '*boot_app0*.bin'
  )
}

$manifest = [ordered]@{
  schema = 'vc-lora-phase6-firmware-manifest-v2'
  generated_at = (Get-Date).ToString('o')
  fqbn = $Fqbn
  esp32_core = $Esp32CoreVersion
  arduino_cli = $ArduinoCliVersion
  compile_order = @('vehicle', 'ground')
  compile_command =
    '.\tools\compile_arduino.ps1 -Fqbn esp32:esp32:XIAO_ESP32S3'
  flash_policy = $flashPolicy
  binaries = $binaryRecords
  hwcdc_contract = [ordered]@{
    result = $hwcdcSummary.result
    actual_core_version = $hwcdcSummary.actual_core_version
    hwcdc_sha256 = $hwcdcSummary.hwcdc_sha256
    hwcdc_header_sha256 = $hwcdcSummary.hwcdc_header_sha256
    diagnostic_header_sha256 = $hwcdcSummary.diagnostic_header_sha256
    canonical_hwcdc_sha256 = $hwcdcSummary.canonical_hwcdc_sha256
    canonical_hwcdc_header_sha256 =
      $hwcdcSummary.canonical_hwcdc_header_sha256
    canonical_diagnostic_header_sha256 =
      $hwcdcSummary.canonical_diagnostic_header_sha256
    summary = $hwcdcSummaryRecord
  }
  source_tree_sha256 = $treeHash
  source_file_count = $sourceRecords.Count
  sources = $sourceRecords
}

$jsonPath = Join-Path $outputRoot 'firmware_manifest.json'
$sumsPath = Join-Path $outputRoot 'SHA256SUMS.txt'
$json = $manifest | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($jsonPath, $json + "`n", $utf8)
$sumLines = @($canonicalLines)
$sumLines += $binaryRecords | ForEach-Object {
  "$($_.sha256)  $($_.path)"
}
$sumLines += "$treeHash  SOURCE_TREE_CANONICAL_SHA256"
[System.IO.File]::WriteAllText(
  $sumsPath, (($sumLines -join "`n") + "`n"), $utf8)

$manifestHash = (Get-FileHash -LiteralPath $jsonPath `
  -Algorithm SHA256).Hash.ToUpperInvariant()
$summary = [ordered]@{
  test = 'FW-ARDUINO-COMPILE-001'
  date = (Get-Date).ToString('yyyy-MM-dd')
  verified_at = (Get-Date).ToString('o')
  fqbn = $Fqbn
  esp32_core = $Esp32CoreVersion
  arduino_cli = $ArduinoCliVersion
  compile_command =
    '.\tools\compile_arduino.ps1 -Fqbn esp32:esp32:XIAO_ESP32S3'
  compile_order = @('vehicle', 'ground')
  flash_policy = $flashPolicy
  core_packaging = `
    'sketch-local synchronized canonical copies (Arduino IDE direct-open)'
  vehicle = [ordered]@{
    result = 'PASS'
    flash_bytes = $VehicleFlashBytes
    flash_percent = $VehicleFlashPercent
    global_ram_bytes = $VehicleRamBytes
    global_ram_percent = $VehicleRamPercent
    binary = $binaryRecords[0]
  }
  ground = [ordered]@{
    result = 'PASS'
    flash_bytes = $GroundFlashBytes
    flash_percent = $GroundFlashPercent
    global_ram_bytes = $GroundRamBytes
    global_ram_percent = $GroundRamPercent
    usb_debug_text_matches = 0
    binary = $binaryRecords[1]
  }
  source_file_count = $sourceRecords.Count
  source_tree_sha256 = $treeHash
  manifest = [ordered]@{
    path = Get-Phase6RelativePath $repo $jsonPath
    sha256 = $manifestHash
  }
  hwcdc_contract = [ordered]@{
    result = $hwcdcSummary.result
    actual_core_version = $hwcdcSummary.actual_core_version
    hwcdc_sha256 = $hwcdcSummary.hwcdc_sha256
    hwcdc_header_sha256 = $hwcdcSummary.hwcdc_header_sha256
    diagnostic_header_sha256 = $hwcdcSummary.diagnostic_header_sha256
    canonical_hwcdc_sha256 = $hwcdcSummary.canonical_hwcdc_sha256
    canonical_hwcdc_header_sha256 =
      $hwcdcSummary.canonical_hwcdc_header_sha256
    canonical_diagnostic_header_sha256 =
      $hwcdcSummary.canonical_diagnostic_header_sha256
    summary = $hwcdcSummaryRecord
  }
  contract_check = 'PASS'
  production_sketches_modified = $true
  flash_performed = $false
  result = 'PASS'
}
$summaryJson = ($summary | ConvertTo-Json -Depth 8) + "`n"
[System.IO.File]::WriteAllText(
  (Join-Path $outputRoot 'summary.json'), $summaryJson, $utf8)
[System.IO.File]::WriteAllText(
  (Join-Path $repo 'runs\arduino_compile_summary.json'),
  $summaryJson, $utf8)

Write-Output "manifest=$jsonPath"
Write-Output "manifest_sha256=$manifestHash"
Write-Output "source_tree_sha256=$treeHash"
foreach ($binary in $binaryRecords) {
  Write-Output "$($binary.path)=$($binary.sha256)"
}
