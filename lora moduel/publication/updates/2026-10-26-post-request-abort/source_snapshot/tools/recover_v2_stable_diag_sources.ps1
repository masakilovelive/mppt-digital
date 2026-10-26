param(
  [Parameter(Mandatory = $true)]
  [string]$VehicleBuildSketch,
  [Parameter(Mandatory = $true)]
  [string]$GroundBuildSketch,
  [Parameter(Mandatory = $true)]
  [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'

function Copy-RecoveredTextFile {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  $text = [IO.File]::ReadAllText($Source)
  if (-not $text.StartsWith('#line 1 ')) {
    throw "Expected Arduino #line prefix in $Source"
  }
  $newline = $text.IndexOf("`n")
  if ($newline -lt 0) {
    throw "Missing source content after #line prefix in $Source"
  }
  $text = $text.Substring($newline + 1)
  $parent = Split-Path -Parent $Destination
  [IO.Directory]::CreateDirectory($parent) | Out-Null
  [IO.File]::WriteAllText(
    $Destination,
    $text,
    [Text.UTF8Encoding]::new($false))
}

function Recover-Sketch {
  param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$TargetRoot,
    [Parameter(Mandatory = $true)][string]$CurrentIno,
    [Parameter(Mandatory = $true)][string]$TargetIno
  )

  if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    throw "Missing Arduino build sketch source: $SourceRoot"
  }
  if (Test-Path -LiteralPath $TargetRoot) {
    throw "Refusing to overwrite recovered source: $TargetRoot"
  }

  [IO.Directory]::CreateDirectory($TargetRoot) | Out-Null
  $relativeFiles = @(
    'README_DIAGNOSTIC.md',
    'VC_LoRa_Core.h',
    'vc_lora_phase6_bridge.hpp'
  )
  $roleFiles = Get-ChildItem -LiteralPath $SourceRoot -File |
    Where-Object { $_.Name -match '^vc_lora_(vehicle|ground)_diag(_observer)?\.hpp$' } |
    ForEach-Object Name
  $relativeFiles += $roleFiles
  $relativeFiles += Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'src') `
      -File -Filter '*.cpp' | ForEach-Object { "src\$($_.Name)" }
  $relativeFiles += Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'vc_lora') `
      -File -Filter '*.hpp' | ForEach-Object { "vc_lora\$($_.Name)" }

  foreach ($relative in $relativeFiles | Sort-Object -Unique) {
    Copy-RecoveredTextFile `
      -Source (Join-Path $SourceRoot $relative) `
      -Destination (Join-Path $TargetRoot $relative)
  }
  Copy-Item -LiteralPath $CurrentIno -Destination (Join-Path $TargetRoot $TargetIno)

  $tddTypes = Join-Path $TargetRoot 'vc_lora\tdd_types.hpp'
  if (-not (Select-String -LiteralPath $tddTypes `
      -Pattern 'kTddProtocolVersion\s*=\s*2' -Quiet)) {
    throw "Recovered source is not TDD protocol v2: $tddTypes"
  }
  if (-not (Select-String -LiteralPath $tddTypes `
      -Pattern 'late_terminal_wait_ms\s*\{\s*1300\s*\}' -Quiet)) {
    throw "Recovered source lacks the final v2 late-terminal wait contract"
  }
  if (Get-ChildItem -LiteralPath $TargetRoot -Recurse -File |
      Where-Object { $_.Extension -in '.o', '.d' -or $_.Name -like '*.ino.cpp' }) {
    throw "Recovered source contains Arduino build products"
  }
}

$vehicleTarget = Join-Path $RepositoryRoot `
  'vc_lora_vehicle_diag_v2_stable_xiao_esp32s3'
$groundTarget = Join-Path $RepositoryRoot `
  'vc_lora_ground_diag_v2_stable_xiao_esp32s3'

Recover-Sketch `
  -SourceRoot $VehicleBuildSketch `
  -TargetRoot $vehicleTarget `
  -CurrentIno (Join-Path $RepositoryRoot `
    'vc_lora_vehicle_diag_xiao_esp32s3\vc_lora_vehicle_diag_xiao_esp32s3.ino') `
  -TargetIno 'vc_lora_vehicle_diag_v2_stable_xiao_esp32s3.ino'
Recover-Sketch `
  -SourceRoot $GroundBuildSketch `
  -TargetRoot $groundTarget `
  -CurrentIno (Join-Path $RepositoryRoot `
    'vc_lora_ground_diag_xiao_esp32s3\vc_lora_ground_diag_xiao_esp32s3.ino') `
  -TargetIno 'vc_lora_ground_diag_v2_stable_xiao_esp32s3.ino'

Write-Host "Recovered protocol-v2 diagnostic sketches:"
Write-Host "  $vehicleTarget"
Write-Host "  $groundTarget"
