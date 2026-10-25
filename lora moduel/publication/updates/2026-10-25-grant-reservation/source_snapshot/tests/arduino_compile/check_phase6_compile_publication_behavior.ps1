param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$fixture = Join-Path ([IO.Path]::GetTempPath()) `
  ("vc_lora_phase6_compile_contract_" + [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)

function Write-FixtureFile([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if ($parent) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Assert-MetadataAbsent([string]$FixtureRoot, [string]$CaseName) {
  foreach ($relative in @(
      'runs\phase6_arduino_compile\firmware_manifest.json',
      'runs\phase6_arduino_compile\SHA256SUMS.txt',
      'runs\phase6_arduino_compile\summary.json',
      'runs\arduino_compile_summary.json'
    )) {
    if (Test-Path -LiteralPath (Join-Path $FixtureRoot $relative)) {
      throw "FW-PHASE6-COMPILE-PUBLISH-001: $CaseName retained $relative"
    }
  }
}

function Assert-MetadataPresent([string]$FixtureRoot, [string]$CaseName) {
  foreach ($relative in @(
      'runs\phase6_arduino_compile\firmware_manifest.json',
      'runs\phase6_arduino_compile\SHA256SUMS.txt',
      'runs\phase6_arduino_compile\summary.json',
      'runs\arduino_compile_summary.json'
    )) {
    if (-not (Test-Path -LiteralPath (Join-Path $FixtureRoot $relative) `
        -PathType Leaf)) {
      throw "FW-PHASE6-COMPILE-PUBLISH-001: $CaseName lacks $relative"
    }
  }
}

New-Item -ItemType Directory -Path $fixture | Out-Null
try {
  foreach ($directory in @(
      'tools', 'tests\arduino_compile', 'tests\hil', 'core\src',
      'core\include\vc_lora', 'firmware\phase6',
      'third_party\esp32-core-3.3.11-vc-lora',
      'vc_lora_vehicle_xiao_esp32s3\src',
      'vc_lora_vehicle_xiao_esp32s3\vc_lora',
      'vc_lora_ground_xiao_esp32s3\src',
      'vc_lora_ground_xiao_esp32s3\vc_lora',
      'runs\phase6_arduino_compile\vehicle',
      'runs\phase6_arduino_compile\ground'
    )) {
    New-Item -ItemType Directory -Path (Join-Path $fixture $directory) `
      -Force | Out-Null
  }

  Copy-Item -LiteralPath (Join-Path $repo 'tools\compile_arduino.ps1') `
    -Destination (Join-Path $fixture 'tools\compile_arduino.ps1')
  Copy-Item -LiteralPath `
    (Join-Path $repo 'tools\phase6_firmware_manifest_common.ps1') `
    -Destination `
      (Join-Path $fixture 'tools\phase6_firmware_manifest_common.ps1')

  foreach ($relative in @(
      'tools\install_patched_esp32_hwcdc.ps1',
      'tools\invoke_phase6_manifest_flash.ps1',
      'tools\sync_arduino_sketch_core.ps1',
      'tests\arduino_compile\check_phase6_ide_compile.ps1',
      'third_party\esp32-core-3.3.11-vc-lora\fixture.txt',
      'core\src\fixture.cpp', 'core\include\vc_lora\fixture.hpp',
      'firmware\phase6\fixture.hpp'
    )) {
    Write-FixtureFile (Join-Path $fixture $relative) "fixture:$relative`n"
  }
  Write-FixtureFile (Join-Path $fixture `
      'tests\hil\check_phase6_manifest_flash_contract.ps1') `
      "Write-Output 'fixture contract PASS'`n"
  foreach ($testName in @(
      'check_phase6_firmware_contract.ps1',
      'check_hwcdc_tx_integrity_contract.ps1',
      'check_phase6_manifest_tooling_contract.ps1',
      'check_phase6_compile_publication_behavior.ps1'
    )) {
    Write-FixtureFile `
      (Join-Path $fixture "tests\arduino_compile\$testName") `
      "Write-Output 'fixture contract PASS'`n"
  }
  foreach ($role in @(
      'vc_lora_vehicle_xiao_esp32s3',
      'vc_lora_ground_xiao_esp32s3'
    )) {
    foreach ($relative in @(
        "$role.ino", 'VC_LoRa_Core.h', 'vc_lora_phase6_bridge.hpp',
        'src\fixture.cpp', 'vc_lora\fixture.hpp'
      )) {
      Write-FixtureFile (Join-Path $fixture "$role\$relative") `
        "fixture:$role/$relative`n"
    }
  }

  $writerStub = @'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'phase6_firmware_manifest_common.ps1')
$output = Join-Path $repo 'runs\phase6_arduino_compile'
$snapshot = Get-Phase6SourceSnapshot $repo
$manifest = [ordered]@{ source_tree_sha256 = $snapshot.tree_sha256 }
$json = ($manifest | ConvertTo-Json) + "`n"
[IO.File]::WriteAllText((Join-Path $output 'firmware_manifest.json'), $json)
[IO.File]::WriteAllText((Join-Path $output 'SHA256SUMS.txt'), "fixture`n")
[IO.File]::WriteAllText((Join-Path $output 'summary.json'), "{}`n")
[IO.File]::WriteAllText((Join-Path $repo 'runs\arduino_compile_summary.json'), "{}`n")
'fixture writer PASS'
'@
  Write-FixtureFile (Join-Path $fixture `
      'tools\write_phase6_firmware_manifest.ps1') $writerStub

  $verifierStub = @'
$repo = Split-Path -Parent $PSScriptRoot
$modePath = Join-Path $repo 'fake_mode.txt'
$mode = (Get-Content -LiteralPath $modePath -Raw).Trim()
if ($mode -eq 'verifier_fail') { throw 'fixture verifier rejection' }
[IO.File]::WriteAllText((Join-Path $repo 'verifier_seen.txt'), "seen`n")
'fixture verifier PASS'
'@
  Write-FixtureFile (Join-Path $fixture `
      'tools\verify_phase6_firmware_manifest.ps1') $verifierStub

  $fakeCli = @'
param([Parameter(ValueFromRemainingArguments = $true)][object[]]$CliArgs)
$root = $PSScriptRoot
$mode = (Get-Content -LiteralPath (Join-Path $root 'fake_mode.txt') -Raw).Trim()
$command = [string]$CliArgs[0]
if ($command -eq 'compile') {
  $countPath = Join-Path $root 'compile_count.txt'
  $count = if (Test-Path -LiteralPath $countPath) {
    [int](Get-Content -LiteralPath $countPath -Raw)
  } else { 0 }
  ++$count
  [IO.File]::WriteAllText($countPath, [string]$count)
  $outputIndex = [Array]::IndexOf($CliArgs, '--output-dir')
  $output = [string]$CliArgs[$outputIndex + 1]
  $sketch = [string]$CliArgs[$CliArgs.Count - 1]
  $role = Split-Path -Leaf $sketch
  if (-not ($mode -eq 'no_vehicle_output' -and $count -eq 1)) {
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    [IO.File]::WriteAllText(
      (Join-Path $output "$role.ino.bin"), "fresh-$role-$count")
  }
  if ($mode -eq 'mutate_after_vehicle' -and $count -eq 1) {
    [IO.File]::AppendAllText(
      (Join-Path $root 'core\src\fixture.cpp'), "mutation`n")
  }
  [pscustomobject]@{
    success = $true
    compiler_out = ''
    compiler_err = ''
    builder_result = [pscustomobject]@{
      executable_sections_size = @(
        [pscustomobject]@{ name = 'text'; size = 1; max_size = 10 },
        [pscustomobject]@{ name = 'data'; size = 1; max_size = 10 }
      )
    }
  } | ConvertTo-Json -Depth 6 -Compress
  exit 0
}
if ($command -eq 'version') {
  [pscustomobject]@{ VersionString = 'fixture-cli' } |
    ConvertTo-Json -Compress
  exit 0
}
if ($command -eq 'board' -and [string]$CliArgs[1] -eq 'details') {
  [pscustomobject]@{ version = '3.3.11' } | ConvertTo-Json -Compress
  exit 0
}
throw "unexpected fake CLI invocation: $($CliArgs -join ' ')"
'@
  $fakeCliPath = Join-Path $fixture 'fake_cli.ps1'
  Write-FixtureFile $fakeCliPath $fakeCli

  $compileScript = Join-Path $fixture 'tools\compile_arduino.ps1'
  $eligibleSource = Join-Path $fixture 'core\src\fixture.cpp'
  $eligibleSourceOriginal = Get-Content -LiteralPath $eligibleSource -Raw

  function Reset-CompileCase([string]$Mode) {
    Write-FixtureFile $eligibleSource $eligibleSourceOriginal
    foreach ($relative in @(
        'compile_count.txt', 'verifier_seen.txt',
        'runs\phase6_arduino_compile\vehicle\vc_lora_vehicle_xiao_esp32s3.ino.bin',
        'runs\phase6_arduino_compile\ground\vc_lora_ground_xiao_esp32s3.ino.bin'
      )) {
      $path = Join-Path $fixture $relative
      if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
      }
    }
    Write-FixtureFile (Join-Path $fixture 'fake_mode.txt') "$Mode`n"
    foreach ($relative in @(
        'runs\phase6_arduino_compile\firmware_manifest.json',
        'runs\phase6_arduino_compile\SHA256SUMS.txt',
        'runs\phase6_arduino_compile\summary.json',
        'runs\arduino_compile_summary.json'
      )) {
      Write-FixtureFile (Join-Path $fixture $relative) "stale:$Mode`n"
    }
  }

  function Invoke-CompileExpectFailure([string]$CaseName,
                                       [string]$ExpectedMessage) {
    $caught = $null
    try {
      & $compileScript -ArduinoCli $fakeCliPath -IdeConfig '' | Out-Null
    } catch {
      $caught = $_.Exception.Message
    }
    if ($null -eq $caught) {
      throw "FW-PHASE6-COMPILE-PUBLISH-001: $CaseName unexpectedly passed"
    }
    if ($caught -notmatch $ExpectedMessage) {
      throw ("FW-PHASE6-COMPILE-PUBLISH-001: $CaseName returned " +
        "unexpected failure: $caught")
    }
    Assert-MetadataAbsent $fixture $CaseName
  }

  Reset-CompileCase 'no_vehicle_output'
  $oldVehicle = Join-Path $fixture `
    'runs\phase6_arduino_compile\vehicle\vc_lora_vehicle_xiao_esp32s3.ino.bin'
  Write-FixtureFile $oldVehicle 'stale-but-canonical-path'
  Invoke-CompileExpectFailure 'missing fresh Vehicle binary' `
    'no fresh application binary'

  Reset-CompileCase 'mutate_after_vehicle'
  Invoke-CompileExpectFailure 'source mutation after Vehicle' `
    'source tree changed during Arduino compile \(after Vehicle\)'
  if ((Get-Content -LiteralPath (Join-Path $fixture 'compile_count.txt') `
      -Raw).Trim() -ne '1') {
    throw 'FW-PHASE6-COMPILE-PUBLISH-001: Ground ran after source mutation'
  }

  Reset-CompileCase 'verifier_fail'
  Invoke-CompileExpectFailure 'final verifier rejection' `
    'fixture verifier rejection'

  Reset-CompileCase 'success'
  & $compileScript -ArduinoCli $fakeCliPath -IdeConfig '' | Out-Null
  Assert-MetadataPresent $fixture 'successful compile'
  if (-not (Test-Path -LiteralPath (Join-Path $fixture 'verifier_seen.txt') `
      -PathType Leaf)) {
    throw 'FW-PHASE6-COMPILE-PUBLISH-001: success did not run verifier'
  }
} finally {
  $expectedPrefix = [IO.Path]::GetTempPath()
  if ($fixture.StartsWith($expectedPrefix,
      [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $fixture) -match
        '^vc_lora_phase6_compile_contract_[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $fixture)) {
    Remove-Item -LiteralPath $fixture -Recurse -Force
  }
}

Write-Output 'FW-PHASE6-COMPILE-PUBLISH-001 PASS'
