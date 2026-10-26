param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
$testId = 'FW-HIGH-SPEED-CANDIDATE-PACKAGING-001'
$candidateNames = @(
  'e220_high_speed_transport_model.hpp',
  'high_speed_phase6_adapter.hpp',
  'phase6_bulk_rx_tail_ledger.hpp',
  'phase6_high_speed_radio_session.hpp',
  'phase6_high_speed_role_config.hpp',
  'phase6_radio_writer_arbiter.hpp',
  'peer_completion_receipt.hpp',
  'r19_runtime_fail_diagnostic.hpp',
  'r19_runtime_stage_record.hpp',
  'terminal_ack_bridge.hpp',
  'terminal_ack_producer.hpp',
  'terminal_ack_wire.hpp',
  'vc_lora_high_speed_candidate.hpp'
)
$productionRoles = @(
  'vc_lora_vehicle_xiao_esp32s3',
  'vc_lora_ground_xiao_esp32s3'
)
$diagnosticRoles = @(
  'vc_lora_vehicle_diag_v2_stable_xiao_esp32s3',
  'vc_lora_ground_diag_v2_stable_xiao_esp32s3'
)
$syncScript = Join-Path $RepoRoot 'tools\sync_arduino_sketch_core.ps1'
$canonicalCandidateRoot = Join-Path $RepoRoot 'firmware\high_speed'
$failures = New-Object System.Collections.Generic.List[string]
$fixtureParent = Join-Path ([IO.Path]::GetTempPath()) (
  'vc_lora_candidate_packaging_' + [Guid]::NewGuid().ToString('N'))

function Add-Failure([string]$Message) {
  $script:failures.Add($Message)
  Write-Host "FAIL: $Message"
}

function Write-FixtureText([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function New-PackagingFixture([string]$Name) {
  $root = Join-Path $fixtureParent $Name
  Write-FixtureText (Join-Path $root 'core\src\fixture.cpp') `
    "// canonical core source`n"
  Write-FixtureText (Join-Path $root 'core\include\vc_lora\fixture.hpp') `
    "#pragma once`n"
  New-Item -ItemType Directory -Force `
    -Path (Join-Path $root 'firmware\phase6') | Out-Null
  Copy-Item -LiteralPath (Join-Path $RepoRoot `
      'firmware\phase6\vc_lora_phase6_bridge.hpp') `
    -Destination (Join-Path $root `
      'firmware\phase6\vc_lora_phase6_bridge.hpp') -Force
  Write-FixtureText (Join-Path $root `
      'firmware\arduino_libraries\VC_LoRa_Core\src\VC_LoRa_Core.h') `
    "#pragma once`n#include <vc_lora/fixture.hpp>`n"

  New-Item -ItemType Directory -Force `
    -Path (Join-Path $root 'firmware\high_speed') | Out-Null
  foreach ($candidateName in $candidateNames) {
    Copy-Item -LiteralPath (Join-Path $canonicalCandidateRoot $candidateName) `
      -Destination (Join-Path $root `
        ("firmware\high_speed\{0}" -f $candidateName)) -Force
  }

  foreach ($role in @($productionRoles + $diagnosticRoles)) {
    $roleRoot = Join-Path $root $role
    New-Item -ItemType Directory -Force -Path $roleRoot | Out-Null
    Write-FixtureText (Join-Path $roleRoot ($role + '.ino')) `
      "// role wrapper sentinel: $role`n"
  }
  return $root
}

function Invoke-Sync([string]$FixtureRoot, [bool]$IncludeCandidate) {
  try {
    if ($IncludeCandidate) {
      $output = @(& $syncScript -RepoRoot $FixtureRoot `
          -IncludeR19HighSpeedCandidate 2>&1)
    } else {
      $output = @(& $syncScript -RepoRoot $FixtureRoot 2>&1)
    }
    return [pscustomobject]@{
      Succeeded = $true
      Output = @($output | ForEach-Object { $_.ToString() })
      Error = $null
    }
  } catch {
    return [pscustomobject]@{
      Succeeded = $false
      Output = @()
      Error = $_.Exception.Message
    }
  }
}

function Assert-CanonicalCandidateCopies([string]$FixtureRoot) {
  foreach ($role in $productionRoles) {
    $candidateTarget = Join-Path (Join-Path $FixtureRoot $role) 'high_speed'
    $actualNames = @(if (Test-Path -LiteralPath $candidateTarget) {
        Get-ChildItem -LiteralPath $candidateTarget -File -Filter '*.hpp' |
          ForEach-Object { $_.Name } | Sort-Object
      })
    $nameDifference = @(Compare-Object `
      -ReferenceObject @($candidateNames | Sort-Object) `
      -DifferenceObject $actualNames)
    if ($nameDifference.Count -ne 0) {
      Add-Failure "$role candidate header set is incomplete or contains extras"
      continue
    }
    foreach ($candidateName in $candidateNames) {
      $canonical = Join-Path $canonicalCandidateRoot $candidateName
      $packaged = Join-Path $candidateTarget $candidateName
      $canonicalHash = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath $canonical).Hash
      $packagedHash = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath $packaged).Hash
      if ($canonicalHash -ne $packagedHash) {
        Add-Failure "$role $candidateName is not byte-identical to canonical"
      }
      if ((Get-Content -Raw -LiteralPath $packaged) -match `
          '#\s*include\s*["<]\s*\.\.') {
        Add-Failure "$role $candidateName escapes the sketch include root"
      }
    }
  }
}

function Assert-DefaultOffBridge([string]$BridgePath, [string]$Role) {
  $text = Get-Content -Raw -LiteralPath $BridgePath
  if ($text -notmatch `
      '#ifndef\s+VC_LORA_R19_HIGH_SPEED_CANDIDATE[\s\S]*?#define\s+VC_LORA_R19_HIGH_SPEED_CANDIDATE\s+0') {
    Add-Failure "$Role bridge does not default the R19 gate to zero"
  }
  if ($text -notmatch `
      '#if\s+VC_LORA_R19_HIGH_SPEED_CANDIDATE[\s\S]*?#include\s+"high_speed/high_speed_phase6_adapter\.hpp"') {
    Add-Failure "$Role bridge adapter include is not candidate-gated"
  }
}

try {
  if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
    throw "missing sync script: $syncScript"
  }
  foreach ($candidateName in $candidateNames) {
    if (-not (Test-Path -LiteralPath `
        (Join-Path $canonicalCandidateRoot $candidateName) -PathType Leaf)) {
      throw "missing canonical candidate header: $candidateName"
    }
  }
  $adapterText = Get-Content -Raw -LiteralPath (Join-Path `
    $canonicalCandidateRoot 'high_speed_phase6_adapter.hpp')
  foreach ($dependency in @('terminal_ack_bridge.hpp',
      'terminal_ack_producer.hpp')) {
    if ($adapterText -notmatch ('#\s*include\s*"{0}"' -f `
        [regex]::Escape($dependency))) {
      Add-Failure "candidate adapter does not declare $dependency"
    }
  }
  foreach ($consumer in @('terminal_ack_bridge.hpp',
      'terminal_ack_producer.hpp')) {
    $consumerText = Get-Content -Raw -LiteralPath `
      (Join-Path $canonicalCandidateRoot $consumer)
    if ($consumerText -notmatch `
        '#\s*include\s*"terminal_ack_wire\.hpp"') {
      Add-Failure "$consumer does not declare terminal_ack_wire.hpp"
    }
  }

  New-Item -ItemType Directory -Force -Path $fixtureParent | Out-Null

  $defaultRoot = New-PackagingFixture 'default'
  $defaultWrapperHashes = @{}
  foreach ($role in $productionRoles) {
    $wrapper = Join-Path (Join-Path $defaultRoot $role) ($role + '.ino')
    $defaultWrapperHashes[$role] =
      (Get-FileHash -Algorithm SHA256 -LiteralPath $wrapper).Hash
  }
  $defaultResult = Invoke-Sync $defaultRoot $false
  if (-not $defaultResult.Succeeded) {
    Add-Failure "default synchronization failed: $($defaultResult.Error)"
  } elseif (($defaultResult.Output -join "`n") -notmatch `
      'candidate_packaging=disabled') {
    Add-Failure 'default synchronization did not report candidate packaging disabled'
  }
  foreach ($role in @($productionRoles + $diagnosticRoles)) {
    if (Test-Path -LiteralPath (Join-Path (Join-Path $defaultRoot $role) `
        'high_speed')) {
      Add-Failure "default synchronization packaged R19 headers into $role"
    }
  }
  foreach ($role in $productionRoles) {
    $wrapper = Join-Path (Join-Path $defaultRoot $role) ($role + '.ino')
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $wrapper).Hash -ne
        $defaultWrapperHashes[$role]) {
      Add-Failure "default synchronization changed $role wrapper"
    }
    $bridge = Join-Path (Join-Path $defaultRoot $role) `
      'vc_lora_phase6_bridge.hpp'
    Assert-DefaultOffBridge $bridge $role
  }

  $candidateRoot = New-PackagingFixture 'candidate'
  $candidateWrapperHashes = @{}
  foreach ($role in $productionRoles) {
    $wrapper = Join-Path (Join-Path $candidateRoot $role) ($role + '.ino')
    $candidateWrapperHashes[$role] =
      (Get-FileHash -Algorithm SHA256 -LiteralPath $wrapper).Hash
  }
  $candidateResult = Invoke-Sync $candidateRoot $true
  if (-not $candidateResult.Succeeded) {
    Add-Failure "opt-in candidate synchronization failed: $($candidateResult.Error)"
  } else {
    if (($candidateResult.Output -join "`n") -notmatch `
        'candidate_packaging=enabled') {
      Add-Failure 'opt-in synchronization did not report candidate packaging enabled'
    }
    Assert-CanonicalCandidateCopies $candidateRoot
  }
  foreach ($role in $diagnosticRoles) {
    if (Test-Path -LiteralPath (Join-Path (Join-Path $candidateRoot $role) `
        'high_speed')) {
      Add-Failure "opt-in candidate synchronization changed diagnostic $role"
    }
  }
  foreach ($role in $productionRoles) {
    $roleRoot = Join-Path $candidateRoot $role
    $wrapper = Join-Path $roleRoot ($role + '.ino')
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $wrapper).Hash -ne
        $candidateWrapperHashes[$role]) {
      Add-Failure "opt-in candidate synchronization changed $role wrapper"
    }
    if ((Get-Content -Raw -LiteralPath $wrapper) -match `
        'VC_LORA_R19_HIGH_SPEED_CANDIDATE|high_speed[/\\]') {
      Add-Failure "opt-in packaging changed runtime selection in $role wrapper"
    }
    Assert-DefaultOffBridge `
      (Join-Path $roleRoot 'vc_lora_phase6_bridge.hpp') $role
  }
} finally {
  if (Test-Path -LiteralPath $fixtureParent) {
    $resolvedFixture = (Resolve-Path -LiteralPath $fixtureParent).Path
    $resolvedTemp = ((Resolve-Path -LiteralPath `
        ([IO.Path]::GetTempPath())).Path).TrimEnd(
          [IO.Path]::DirectorySeparatorChar,
          [IO.Path]::AltDirectorySeparatorChar)
    if (-not $resolvedFixture.StartsWith(
        $resolvedTemp + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
      throw "refusing to remove fixture outside temp root: $resolvedFixture"
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
  }
}

if ($failures.Count -ne 0) {
  throw "$testId FAIL ($($failures.Count)): $($failures -join '; ')"
}

Write-Output "$testId PASS"
