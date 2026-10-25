param(
  [string]$ArduinoCli,
  [string]$Fqbn = 'esp32:esp32:XIAO_ESP32S3',
  [string]$ExpectedEsp32CoreVersion = '3.3.11',
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$IdeConfig = (Join-Path $env:USERPROFILE `
    '.arduinoIDE\arduino-cli.yaml'),
  [switch]$EnableRuntimeFailDiagnostics
)

$ErrorActionPreference = 'Stop'
$testId = if ($EnableRuntimeFailDiagnostics) {
  'FW-R19-RUNTIME-FAIL-DIAGNOSTIC-COMPILE-GATE-001'
} else {
  'FW-R19-CANDIDATE-COMPILE-GATE-001'
}
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
  'terminal_ack_bridge.hpp',
  'terminal_ack_producer.hpp',
  'terminal_ack_wire.hpp',
  'vc_lora_high_speed_candidate.hpp'
)
$roleNames = @(
  'vc_lora_vehicle_xiao_esp32s3',
  'vc_lora_ground_xiao_esp32s3'
)

function Get-TreeSnapshot([string[]]$Roots) {
  $records = New-Object System.Collections.Generic.List[string]
  foreach ($root in $Roots) {
    $resolvedRoot = (Resolve-Path -LiteralPath $root).Path
    foreach ($file in @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse `
        -File | Sort-Object FullName)) {
      $relative = $file.FullName.Substring($resolvedRoot.Length).TrimStart(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
      $hash = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath $file.FullName).Hash
      $records.Add(("{0}|{1}|{2}" -f `
          (Split-Path -Leaf $resolvedRoot), $relative, $hash))
    }
  }
  $joined = [string]::Join("`n", @($records))
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($joined))
  } finally {
    $sha.Dispose()
  }
  return [pscustomobject]@{
    file_count = $records.Count
    tree_sha256 = [BitConverter]::ToString($digest).Replace('-', '')
  }
}

function Assert-NoCandidatePackage([string[]]$Roots, [string]$Checkpoint) {
  foreach ($root in $Roots) {
    $candidateRoot = Join-Path $root 'high_speed'
    if (Test-Path -LiteralPath $candidateRoot) {
      throw "${testId}: default sketch has candidate package at $Checkpoint`: $candidateRoot"
    }
    $wrapper = Join-Path $root ((Split-Path -Leaf $root) + '.ino')
    $wrapperText = Get-Content -Raw -LiteralPath $wrapper
    if ($wrapperText -match `
        'VC_LORA_R19_HIGH_SPEED_CANDIDATE|high_speed[/\\]') {
      throw "${testId}: default wrapper opts into R19 at $Checkpoint`: $wrapper"
    }
  }
}

function Assert-SameSnapshot($Expected, [string[]]$Roots,
                             [string]$Checkpoint) {
  $actual = Get-TreeSnapshot $Roots
  if ($actual.file_count -ne $Expected.file_count -or
      $actual.tree_sha256 -cne $Expected.tree_sha256) {
    throw "${testId}: real production sketches changed during $Checkpoint"
  }
}

function Copy-CanonicalPackage([string]$Repo, [string]$Role,
                               [string]$StageRoot) {
  $sourceRole = Join-Path $Repo $Role
  $targetRole = Join-Path $StageRoot $Role
  New-Item -ItemType Directory -Force -Path $targetRole | Out-Null
  Copy-Item -LiteralPath (Join-Path $sourceRole ($Role + '.ino')) `
    -Destination (Join-Path $targetRole ($Role + '.ino')) -Force
  Copy-Item -LiteralPath (Join-Path $Repo `
      'firmware\phase6\vc_lora_phase6_bridge.hpp') `
    -Destination (Join-Path $targetRole 'vc_lora_phase6_bridge.hpp') -Force
  Copy-Item -LiteralPath (Join-Path $Repo `
      'firmware\arduino_libraries\VC_LoRa_Core\src\VC_LoRa_Core.h') `
    -Destination (Join-Path $targetRole 'VC_LoRa_Core.h') -Force

  $sourceTarget = Join-Path $targetRole 'src'
  $headerTarget = Join-Path $targetRole 'vc_lora'
  $candidateTarget = Join-Path $targetRole 'high_speed'
  New-Item -ItemType Directory -Force `
    -Path $sourceTarget, $headerTarget, $candidateTarget | Out-Null
  foreach ($source in @(Get-ChildItem -LiteralPath (Join-Path $Repo `
      'core\src') -File -Filter '*.cpp')) {
    Copy-Item -LiteralPath $source.FullName `
      -Destination (Join-Path $sourceTarget $source.Name) -Force
  }
  foreach ($header in @(Get-ChildItem -LiteralPath (Join-Path $Repo `
      'core\include\vc_lora') -File -Filter '*.hpp')) {
    Copy-Item -LiteralPath $header.FullName `
      -Destination (Join-Path $headerTarget $header.Name) -Force
  }
  foreach ($candidateName in $candidateHeaderNames) {
    $canonical = Join-Path $Repo `
      ("firmware\high_speed\{0}" -f $candidateName)
    $packaged = Join-Path $candidateTarget $candidateName
    Copy-Item -LiteralPath $canonical -Destination $packaged -Force
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $canonical).Hash -cne
        (Get-FileHash -Algorithm SHA256 -LiteralPath $packaged).Hash) {
      throw "${testId}: staged candidate differs from canonical: $candidateName"
    }
    if ((Get-Content -Raw -LiteralPath $packaged) -match `
        '#\s*include\s*["<]\s*\.\.') {
      throw "${testId}: staged candidate escapes sketch: $candidateName"
    }
  }
  $actualCandidateNames = @(Get-ChildItem -LiteralPath $candidateTarget `
      -File -Filter '*.hpp' | ForEach-Object { $_.Name } | Sort-Object)
  $candidateDifference = @(Compare-Object `
      -ReferenceObject @($candidateHeaderNames | Sort-Object) `
      -DifferenceObject $actualCandidateNames)
  if ($candidateDifference.Count -ne 0) {
    throw "${testId}: staged candidate header set is not the exact allowlisted package"
  }
  $stagedWrapperHash = (Get-FileHash -Algorithm SHA256 -LiteralPath `
      (Join-Path $targetRole ($Role + '.ino'))).Hash
  $realWrapperHash = (Get-FileHash -Algorithm SHA256 -LiteralPath `
      (Join-Path $sourceRole ($Role + '.ino'))).Hash
  if ($stagedWrapperHash -cne $realWrapperHash) {
    throw "${testId}: staging changed the $Role wrapper"
  }
  return $targetRole
}

function Invoke-CandidateCompile([string]$Role, [string]$Sketch,
                                 [string]$BuildRoot,
                                 [string]$OutputRoot) {
  $buildPath = Join-Path $BuildRoot $Role
  $outputPath = Join-Path $OutputRoot $Role
  New-Item -ItemType Directory -Force -Path $buildPath, $outputPath |
    Out-Null
  $extraFlags = '-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1'
  if ($EnableRuntimeFailDiagnostics) {
    $extraFlags += ' -DVC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS=1'
  }
  $compileOutput = @(& $ArduinoCli @globalArgs compile --fqbn $Fqbn `
    --warnings all --clean --build-path $buildPath --output-dir $outputPath `
    --build-property ("compiler.cpp.extra_flags={0}" -f $extraFlags) `
    --json $Sketch 2>&1)
  $compileExit = $LASTEXITCODE
  $compileText = $compileOutput -join "`n"
  try {
    $compileResult = $compileText | ConvertFrom-Json
  } catch {
    Write-Host $compileText
    throw "${testId}: $Role compile returned invalid JSON"
  }
  if ($compileExit -ne 0 -or -not $compileResult.success) {
    if ($compileResult.compiler_out) {
      Write-Host $compileResult.compiler_out.TrimEnd()
    }
    if ($compileResult.compiler_err) {
      Write-Host $compileResult.compiler_err.TrimEnd()
    }
    throw "${testId}: $Role candidate compile failed (exit=$compileExit)"
  }
  $sketchName = Split-Path -Leaf $Sketch
  $binary = Join-Path $outputPath ($sketchName + '.ino.bin')
  if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "${testId}: $Role candidate compile produced no application binary"
  }
  $flash = @($compileResult.builder_result.executable_sections_size |
    Where-Object { $_.name -eq 'text' })[0]
  $ram = @($compileResult.builder_result.executable_sections_size |
    Where-Object { $_.name -eq 'data' })[0]
  if (-not $flash -or -not $ram) {
    throw "${testId}: $Role candidate compile returned no size data"
  }
  Write-Output ("$testId {0} PASS flash={1} ram={2}" -f `
      $Role, $flash.size, $ram.size)
}

$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$realRoleRoots = @($roleNames | ForEach-Object {
    (Resolve-Path -LiteralPath (Join-Path $repo $_)).Path
  })
Assert-NoCandidatePackage $realRoleRoots 'preflight'
$sourceAtStart = Get-TreeSnapshot $realRoleRoots

if (-not $ArduinoCli) {
  $ArduinoCli = Join-Path $env:TEMP `
    'arduino-cli-vc-lora-check\arduino-cli.exe'
}
if (-not (Test-Path -LiteralPath $ArduinoCli -PathType Leaf)) {
  $found = Get-Command arduino-cli -ErrorAction SilentlyContinue
  if (-not $found) {
    throw "${testId}: arduino-cli not found"
  }
  $ArduinoCli = $found.Source
}
$globalArgs = @()
if ($IdeConfig -and (Test-Path -LiteralPath $IdeConfig -PathType Leaf)) {
  $globalArgs += @('--config-file', $IdeConfig)
}
$boardJson = & $ArduinoCli @globalArgs board details --fqbn $Fqbn `
  --format json
if ($LASTEXITCODE -ne 0) {
  throw "${testId}: board-details query failed"
}
$board = $boardJson | ConvertFrom-Json
if ($board.version -cne $ExpectedEsp32CoreVersion) {
  throw "${testId}: expected ESP32 core $ExpectedEsp32CoreVersion, got $($board.version)"
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
  'vc_lora_r19_candidate_compile_' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  $stageRoot = Join-Path $tempRoot 'stage'
  $buildRoot = Join-Path $tempRoot 'build'
  $outputRoot = Join-Path $tempRoot 'output'
  New-Item -ItemType Directory -Force `
    -Path $stageRoot, $buildRoot, $outputRoot | Out-Null

  $vehicleStage = Copy-CanonicalPackage $repo $roleNames[0] $stageRoot
  $groundStage = Copy-CanonicalPackage $repo $roleNames[1] $stageRoot
  Assert-SameSnapshot $sourceAtStart $realRoleRoots 'candidate staging'

  # Sequential by contract: the ESP32 Arduino cache is shared between roles.
  Invoke-CandidateCompile 'Vehicle' $vehicleStage $buildRoot $outputRoot
  Assert-SameSnapshot $sourceAtStart $realRoleRoots 'Vehicle compile'
  Invoke-CandidateCompile 'Ground' $groundStage $buildRoot $outputRoot
  Assert-SameSnapshot $sourceAtStart $realRoleRoots 'Ground compile'
} finally {
  try {
    Assert-NoCandidatePackage $realRoleRoots 'postflight'
    Assert-SameSnapshot $sourceAtStart $realRoleRoots 'postflight'
  } finally {
    if (Test-Path -LiteralPath $tempRoot) {
      $resolvedTempRoot = (Resolve-Path -LiteralPath $tempRoot).Path
      $resolvedSystemTemp = ((Resolve-Path -LiteralPath `
          ([IO.Path]::GetTempPath())).Path).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar)
      $expectedPrefix = $resolvedSystemTemp + `
        [IO.Path]::DirectorySeparatorChar + 'vc_lora_r19_candidate_compile_'
      if (-not $resolvedTempRoot.StartsWith(
          $expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "${testId}: refusing to remove unsafe temp path: $resolvedTempRoot"
      }
      Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
  }
}

$diagnosticMode = if ($EnableRuntimeFailDiagnostics) { 'enabled' } else {
  'disabled'
}
Write-Output "$testId PASS fqbn=$Fqbn candidate_headers=$($candidateHeaderNames.Count) source_unchanged=true runtime_fail_diagnostics=$diagnosticMode deployment_authorized=false"
