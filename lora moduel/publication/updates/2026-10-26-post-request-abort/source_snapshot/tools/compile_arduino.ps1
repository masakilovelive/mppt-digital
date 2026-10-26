param(
  [string]$ArduinoCli,
  [string]$Fqbn = 'esp32:esp32:XIAO_ESP32S3',
  [string]$ExpectedEsp32CoreVersion = '3.3.11',
  [string]$IdeConfig = (Join-Path $env:USERPROFILE `
    '.arduinoIDE\arduino-cli.yaml')
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
. (Join-Path $PSScriptRoot 'phase6_firmware_manifest_common.ps1')
$vehicle = Join-Path $repo 'vc_lora_vehicle_xiao_esp32s3'
$ground = Join-Path $repo 'vc_lora_ground_xiao_esp32s3'
$vehicleBuild = Join-Path $env:TEMP 'vc_lora_arduino_vehicle'
$groundBuild = Join-Path $env:TEMP 'vc_lora_arduino_ground'
$outputRoot = Join-Path $repo 'runs\phase6_arduino_compile'
$vehicleOutput = Join-Path $outputRoot 'vehicle'
$groundOutput = Join-Path $outputRoot 'ground'
$contractCheck = Join-Path $repo `
  'tests\arduino_compile\check_phase6_firmware_contract.ps1'
$hwcdcContractCheck = Join-Path $repo `
  'tests\arduino_compile\check_hwcdc_tx_integrity_contract.ps1'
$manifestWriter = Join-Path $repo 'tools\write_phase6_firmware_manifest.ps1'
$manifestVerifier = Join-Path $repo 'tools\verify_phase6_firmware_manifest.ps1'
$manifestToolingCheck = Join-Path $repo `
  'tests\arduino_compile\check_phase6_manifest_tooling_contract.ps1'
$compilePublicationCheck = Join-Path $repo `
  'tests\arduino_compile\check_phase6_compile_publication_behavior.ps1'
$hwcdcContractOutput = Join-Path $outputRoot 'hwcdc_contract'
$globalArgs = @()
if ($IdeConfig -and (Test-Path -LiteralPath $IdeConfig -PathType Leaf)) {
  $globalArgs += @('--config-file', $IdeConfig)
}

function Invoke-ArduinoCompile([string]$Sketch, [string]$BuildPath,
                               [string]$OutputPath) {
  New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
  $sketchName = Split-Path -Leaf $Sketch
  $expectedBinary = Assert-OutputPath `
    (Join-Path $OutputPath "$sketchName.ino.bin")
  if (Test-Path -LiteralPath $expectedBinary -PathType Leaf) {
    Remove-Item -LiteralPath $expectedBinary -Force
  }
  $compileOutput = @(& $ArduinoCli @globalArgs compile --fqbn $Fqbn --warnings all --clean `
    --output-dir $OutputPath `
    --build-path $BuildPath --json $Sketch 2>&1)
  $compileExit = $LASTEXITCODE
  $compileText = $compileOutput -join "`n"
  try {
    $compileResult = $compileText | ConvertFrom-Json
  } catch {
    Write-Host $compileText
    throw 'Arduino CLI did not return valid compile JSON'
  }
  if ($compileResult.compiler_out) {
    Write-Host $compileResult.compiler_out.TrimEnd()
  }
  if ($compileResult.compiler_err) {
    Write-Host $compileResult.compiler_err.TrimEnd()
  }
  if ($compileExit -ne 0 -or -not $compileResult.success) {
    throw "Arduino compile failed for $Sketch (exit=$compileExit)"
  }
  if (-not (Test-Path -LiteralPath $expectedBinary -PathType Leaf)) {
    throw "Arduino compile produced no fresh application binary: $expectedBinary"
  }

  $flashSection = @($compileResult.builder_result.executable_sections_size |
    Where-Object { $_.name -eq 'text' })[0]
  $ramSection = @($compileResult.builder_result.executable_sections_size |
    Where-Object { $_.name -eq 'data' })[0]
  if (-not $flashSection -or -not $ramSection -or
      $flashSection.max_size -le 0 -or $ramSection.max_size -le 0) {
    throw 'Arduino CLI compile JSON has no flash/RAM section sizes'
  }
  return [pscustomobject]@{
    flash_bytes = [int]$flashSection.size
    flash_percent = [int][Math]::Floor(
      100.0 * $flashSection.size / $flashSection.max_size)
    ram_bytes = [int]$ramSection.size
    ram_percent = [int][Math]::Floor(
      100.0 * $ramSection.size / $ramSection.max_size)
  }
}

function Assert-OutputPath([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path)
  $prefix = $repo + [IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($prefix,
      [StringComparison]::OrdinalIgnoreCase)) {
    throw "Phase 6 compile output escaped repository: $full"
  }
  return $full
}

function Invalidate-Phase6PublishedMetadata {
  foreach ($path in @(
      (Join-Path $outputRoot 'firmware_manifest.json'),
      (Join-Path $outputRoot 'SHA256SUMS.txt'),
      (Join-Path $outputRoot 'summary.json'),
      (Join-Path $repo 'runs\arduino_compile_summary.json')
    )) {
    $safePath = Assert-OutputPath $path
    if (Test-Path -LiteralPath $safePath) {
      Remove-Item -LiteralPath $safePath -Force
    }
  }
}

function Assert-UnchangedSourceTree($Expected, [string]$Checkpoint) {
  $actual = Get-Phase6SourceSnapshot $repo
  if ($actual.file_count -ne $Expected.file_count -or
      $actual.tree_sha256 -cne $Expected.tree_sha256) {
    throw "source tree changed during Arduino compile ($Checkpoint)"
  }
  return $actual
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
[void](Assert-OutputPath $outputRoot)
$published = $false
Invalidate-Phase6PublishedMetadata
$sourceAtStart = Get-Phase6SourceSnapshot $repo

try {
  if (-not $ArduinoCli) {
    $ArduinoCli = Join-Path $env:TEMP `
      'arduino-cli-vc-lora-check\arduino-cli.exe'
  }
  if (-not (Test-Path -LiteralPath $ArduinoCli -PathType Leaf)) {
    $found = Get-Command arduino-cli -ErrorAction SilentlyContinue
    if (-not $found) { throw 'arduino-cli not found' }
    $ArduinoCli = $found.Source
  }

  & $manifestToolingCheck -RepoRoot $repo
  if (-not $?) { throw 'Phase 6 manifest tooling contract failed' }
  & $compilePublicationCheck -RepoRoot $repo
  if (-not $?) { throw 'Phase 6 compile publication contract failed' }

  & $hwcdcContractCheck -ArduinoCli $ArduinoCli -Fqbn $Fqbn `
    -ExpectedCoreVersion $ExpectedEsp32CoreVersion -IdeConfig $IdeConfig `
    -OutputDir $hwcdcContractOutput
  if (-not $?) { throw 'HWCDC integrity preflight failed' }

  & $contractCheck -RepoRoot $repo
  if (-not $?) { throw 'Phase 6 firmware contract preflight failed' }
  [void](Assert-UnchangedSourceTree $sourceAtStart 'after preflight')

  # Run sequentially: parallel Arduino builds can race in the shared ESP32 cache.
  $vehicleResult = Invoke-ArduinoCompile `
    $vehicle $vehicleBuild $vehicleOutput
  [void](Assert-UnchangedSourceTree $sourceAtStart 'after Vehicle')

  $groundResult = Invoke-ArduinoCompile `
    $ground $groundBuild $groundOutput
  [void](Assert-UnchangedSourceTree $sourceAtStart 'after Ground')

  # Revalidate mutable installed-core and source contracts after both builds.
  & $hwcdcContractCheck -ArduinoCli $ArduinoCli -Fqbn $Fqbn `
    -ExpectedCoreVersion $ExpectedEsp32CoreVersion -IdeConfig $IdeConfig `
    -OutputDir $hwcdcContractOutput
  if (-not $?) { throw 'HWCDC integrity postflight failed' }
  & $contractCheck -RepoRoot $repo
  if (-not $?) { throw 'Phase 6 firmware contract postflight failed' }
  & $manifestToolingCheck -RepoRoot $repo
  if (-not $?) { throw 'Phase 6 manifest tooling postflight failed' }
  [void](Assert-UnchangedSourceTree $sourceAtStart 'after postflight')

  $cliJson = & $ArduinoCli @globalArgs version --format json
  if ($LASTEXITCODE -ne 0) { throw 'Arduino CLI version query failed' }
  $cliDetails = $cliJson | ConvertFrom-Json
  $boardJson = & $ArduinoCli @globalArgs board details --fqbn $Fqbn `
    --format json
  if ($LASTEXITCODE -ne 0) { throw 'Arduino board-details query failed' }
  $boardDetails = $boardJson | ConvertFrom-Json
  if ($boardDetails.version -cne $ExpectedEsp32CoreVersion) {
    throw "expected ESP32 core $ExpectedEsp32CoreVersion, got $($boardDetails.version)"
  }

  & $manifestWriter -RepoRoot $repo -OutputRoot $outputRoot -Fqbn $Fqbn `
    -ArduinoCliVersion $cliDetails.VersionString `
    -Esp32CoreVersion $boardDetails.version `
    -VehicleFlashBytes $vehicleResult.flash_bytes `
    -VehicleFlashPercent $vehicleResult.flash_percent `
    -VehicleRamBytes $vehicleResult.ram_bytes `
    -VehicleRamPercent $vehicleResult.ram_percent `
    -GroundFlashBytes $groundResult.flash_bytes `
    -GroundFlashPercent $groundResult.flash_percent `
    -GroundRamBytes $groundResult.ram_bytes `
    -GroundRamPercent $groundResult.ram_percent
  if (-not $?) { throw 'Phase 6 firmware manifest generation failed' }

  $generatedManifestPath = Join-Path $outputRoot 'firmware_manifest.json'
  $generatedManifest = Get-Content -LiteralPath $generatedManifestPath `
    -Raw | ConvertFrom-Json
  if ($generatedManifest.source_tree_sha256 -cne
      $sourceAtStart.tree_sha256) {
    throw 'source tree changed during Arduino compile (manifest generation)'
  }
  & $manifestVerifier -RepoRoot $repo -ManifestPath $generatedManifestPath
  if (-not $?) { throw 'Phase 6 firmware manifest verification failed' }
  [void](Assert-UnchangedSourceTree $sourceAtStart 'after manifest verification')
  $published = $true
} finally {
  if (-not $published) {
    Invalidate-Phase6PublishedMetadata
  }
}
