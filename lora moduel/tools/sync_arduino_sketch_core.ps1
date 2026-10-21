param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [switch]$IncludeR19HighSpeedCandidate,
  [switch]$IncludeR19UsbReadinessDiagnostics
)

$ErrorActionPreference = 'Stop'
if ($IncludeR19UsbReadinessDiagnostics -and -not $IncludeR19HighSpeedCandidate) {
  throw 'USB readiness diagnostics require explicit R19 high-speed dependencies'
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$coreSources = Get-ChildItem -LiteralPath (Join-Path $repo 'core\src') `
  -File -Filter '*.cpp'
$coreHeaders = Get-ChildItem -LiteralPath `
  (Join-Path $repo 'core\include\vc_lora') -File -Filter '*.hpp'
$bridge = Join-Path $repo 'firmware\phase6\vc_lora_phase6_bridge.hpp'
$umbrella = Join-Path $repo `
  'firmware\arduino_libraries\VC_LoRa_Core\src\VC_LoRa_Core.h'
$candidateHeaderNames = @(
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
$candidateHeaders = @()
if ($IncludeR19HighSpeedCandidate) {
  $candidateSourceRoot = (Resolve-Path -LiteralPath (Join-Path $repo `
      'firmware\high_speed')).Path
  foreach ($candidateName in $candidateHeaderNames) {
    $candidateHeaders += Get-Item -LiteralPath `
      (Join-Path $candidateSourceRoot $candidateName)
  }
}

foreach ($role in @(
    'vc_lora_vehicle_xiao_esp32s3',
    'vc_lora_ground_xiao_esp32s3',
    'vc_lora_vehicle_diag_v2_stable_xiao_esp32s3',
    'vc_lora_ground_diag_v2_stable_xiao_esp32s3'
  )) {
  $sketch = (Resolve-Path -LiteralPath (Join-Path $repo $role)).Path
  if (-not $sketch.StartsWith($repo + [IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase)) {
    throw "Sketch target escaped repository: $sketch"
  }
  $sourceTarget = Join-Path $sketch 'src'
  $headerTarget = Join-Path $sketch 'vc_lora'
  New-Item -ItemType Directory -Force -Path $sourceTarget, $headerTarget |
    Out-Null

  foreach ($source in $coreSources) {
    Copy-Item -LiteralPath $source.FullName `
      -Destination (Join-Path $sourceTarget $source.Name) -Force
  }
  foreach ($header in $coreHeaders) {
    Copy-Item -LiteralPath $header.FullName `
      -Destination (Join-Path $headerTarget $header.Name) -Force
  }
}

# Diagnostic sketches carry instrumented adapters and must retain them. Only
# the two production sketches receive the canonical Arduino adapter/umbrella.
foreach ($role in @(
    'vc_lora_vehicle_xiao_esp32s3',
    'vc_lora_ground_xiao_esp32s3'
  )) {
  $sketch = (Resolve-Path -LiteralPath (Join-Path $repo $role)).Path
  Copy-Item -LiteralPath $bridge `
    -Destination (Join-Path $sketch 'vc_lora_phase6_bridge.hpp') -Force
  Copy-Item -LiteralPath $umbrella `
    -Destination (Join-Path $sketch 'VC_LoRa_Core.h') -Force

  # R19 remains a default-off product feature. The bridge compiles its normal
  # byte-for-byte route with the macro's default value zero. This switch only
  # packages the exact candidate dependency closure; role wrappers still do
  # not define the macro or opt into candidate runtime.
  if ($IncludeR19HighSpeedCandidate) {
    $candidateTarget = Join-Path $sketch 'high_speed'
    New-Item -ItemType Directory -Force -Path $candidateTarget | Out-Null
    foreach ($candidateHeader in $candidateHeaders) {
      Copy-Item -LiteralPath $candidateHeader.FullName `
        -Destination (Join-Path $candidateTarget $candidateHeader.Name) -Force
    }
    # Deliberately outside the frozen candidate header allowlist. No existing
    # candidate/seal/flash tool thereby claims to support active A/B variants.
    if ($IncludeR19UsbReadinessDiagnostics) {
      $diagnosticTarget = Join-Path $sketch 'diagnostics'
      New-Item -ItemType Directory -Force -Path $diagnosticTarget | Out-Null
      Copy-Item -LiteralPath (Join-Path $repo `
          'firmware\diagnostics\r19_host_readiness.hpp') `
        -Destination (Join-Path $diagnosticTarget 'r19_host_readiness.hpp') -Force
    }
  }
}

$candidateMode = if ($IncludeR19HighSpeedCandidate) { 'enabled' } else {
  'disabled'
}
Write-Output "FW-ARDUINO-SYNC-001 PASS candidate_packaging=$candidateMode"
