param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
$wrapperPath = Join-Path $repo 'tools\invoke_phase6_manifest_flash.ps1'
$commonPath = Join-Path $repo 'tools\phase6_firmware_manifest_common.ps1'
$thisRelative = 'tests\hil\check_phase6_manifest_flash_contract.ps1'
$wrapperRelative = 'tools\invoke_phase6_manifest_flash.ps1'
$testId = 'FW-PHASE6-MANIFEST-FLASH-001'
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-Condition([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "$testId`: $Message" }
}

function Write-Utf8([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Get-Sha([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

Assert-Condition (Test-Path -LiteralPath $wrapperPath -PathType Leaf) `
    "missing canonical manifest flash wrapper: $wrapperPath"
Assert-Condition (Test-Path -LiteralPath $commonPath -PathType Leaf) `
    'missing Phase 6 source-inventory implementation'

$commonText = Get-Content -LiteralPath $commonPath -Raw
Assert-Condition ($commonText -match
    [regex]::Escape($wrapperRelative)) `
    'canonical flash wrapper is not in the exact source inventory'
Assert-Condition ($commonText -match
    [regex]::Escape($thisRelative)) `
    'flash contract test is not in the exact source inventory'

$wrapperText = Get-Content -LiteralPath $wrapperPath -Raw
foreach ($required in @(
    '\[switch\]\$Execute',
    'verify_phase6_firmware_manifest\.ps1',
    'vc-lora-phase6-firmware-manifest-v2',
    '0x10000',
    'read-mac',
    'write-flash',
    'verify-flash',
    '90:70:69:11:81:a4',
    '1c:db:d4:5a:83:80',
    '7131F6A',
    '2159A644',
    '5\.3\.1',
    'FileShare\]::Read',
    'final_seal\.json')) {
  Assert-Condition ($wrapperText -match $required) `
      "wrapper lacks required contract pattern: $required"
}
Assert-Condition ($wrapperText -notmatch 'Invoke-Expression|\biex\b') `
    'wrapper must never construct a shell command string'

$fixture = Join-Path ([IO.Path]::GetTempPath()) `
    ('vc_lora_phase6_flash_contract_' + [Guid]::NewGuid().ToString('N'))
$oldScenario = $env:VC_LORA_FLASH_FAKE_SCENARIO
$oldLog = $env:VC_LORA_FLASH_FAKE_LOG
$oldMutate = $env:VC_LORA_FLASH_FAKE_MUTATE_PATH
$oldLockLog = $env:VC_LORA_FLASH_FAKE_LOCK_LOG

try {
  foreach ($directory in @(
      'tools',
      'runs\phase6_arduino_compile\vehicle',
      'runs\phase6_arduino_compile\ground',
      'runs\hil\R18-PHASE6-PRODUCTION-FLASH-001')) {
    New-Item -ItemType Directory -Path (Join-Path $fixture $directory) `
        -Force | Out-Null
  }

  $fixtureWrapper = Join-Path $fixture $wrapperRelative
  Copy-Item -LiteralPath $wrapperPath -Destination $fixtureWrapper

  # Regression: PowerShell does not guarantee that $PSScriptRoot is populated
  # while parameter default expressions are evaluated. Invoke the copied
  # wrapper exactly as an operator will (`powershell -File <wrapper>`) with no
  # RepoRoot or other arguments. This deliberately incomplete fixture must
  # reach the ordinary default DryRun path, resolve its repository from the
  # bound script root, create sealed evidence there, and then fail closed only
  # because the manifest has not been installed yet. It must not reach a
  # device, process inventory, or esptool.
  $defaultProbeOutput = @()
  try {
    $defaultProbeOutput = @(& powershell.exe -NoProfile `
        -ExecutionPolicy Bypass -File $fixtureWrapper 2>&1)
  } catch {
    $defaultProbeOutput += $_.Exception.Message
  }
  $defaultProbeExit = $LASTEXITCODE
  $defaultEvidenceBase = Join-Path $fixture `
      'runs\hil\R18-PHASE6-PRODUCTION-FLASH-001'
  $defaultRuns = @(if (Test-Path -LiteralPath $defaultEvidenceBase `
      -PathType Container) {
    Get-ChildItem -LiteralPath $defaultEvidenceBase -Directory
  })
  Assert-Condition ($defaultProbeExit -ne 0 -and $defaultRuns.Count -eq 1) `
      ('no-argument -File invocation did not enter the isolated default ' +
       "DryRun path: exit=$defaultProbeExit output=" +
       ($defaultProbeOutput -join ' | '))
  $defaultSummaryPath = Join-Path $defaultRuns[0].FullName 'summary.json'
  Assert-Condition (Test-Path -LiteralPath $defaultSummaryPath -PathType Leaf) `
      'no-argument default DryRun produced no sealed summary'
  $defaultSummary = Get-Content -LiteralPath $defaultSummaryPath -Raw |
      ConvertFrom-Json
  Assert-Condition ($defaultSummary.mode -ceq 'DryRun' -and
      $defaultSummary.result -ceq 'FAIL' -and
      [string]$defaultSummary.failure -match 'manifest is missing' -and
      [string]$defaultSummary.evidence_root -like "$fixture\*" -and
      [string]$defaultSummary.runner.path -ceq $fixtureWrapper -and
      -not [bool]$defaultSummary.external_actions.device_access_attempted -and
      -not [bool]$defaultSummary.external_actions.process_inventory_queried -and
      -not [bool]$defaultSummary.external_actions.esptool_executed -and
      -not [bool]$defaultSummary.external_actions.firmware_write_attempted) `
      'no-argument default DryRun path/accounting is incorrect'

  $fakeVerifier = Join-Path $fixture `
      'tools\verify_phase6_firmware_manifest.ps1'
  Write-Utf8 $fakeVerifier @'
param([string]$ManifestPath, [string]$RepoRoot)
$ErrorActionPreference = 'Stop'
$expected = Join-Path $RepoRoot 'runs\phase6_arduino_compile\firmware_manifest.json'
if ((Resolve-Path -LiteralPath $ManifestPath).Path -cne
    (Resolve-Path -LiteralPath $expected).Path) {
  throw 'unexpected manifest path'
}
Write-Output "FW-PHASE6-MANIFEST-VERIFY-001 PASS manifest=$ManifestPath"
'@

  $vehicleBinary = Join-Path $fixture `
      'runs\phase6_arduino_compile\vehicle\vc_lora_vehicle_xiao_esp32s3.ino.bin'
  $groundBinary = Join-Path $fixture `
      'runs\phase6_arduino_compile\ground\vc_lora_ground_xiao_esp32s3.ino.bin'
  [byte[]]$vehicleBytes = 0..127 | ForEach-Object { [byte]($_ -band 0xff) }
  [byte[]]$groundBytes = 0..95 | ForEach-Object {
    [byte](($_ * 7 + 3) -band 0xff)
  }
  [IO.File]::WriteAllBytes($vehicleBinary, $vehicleBytes)
  [IO.File]::WriteAllBytes($groundBinary, $groundBytes)

  $manifestPath = Join-Path $fixture `
      'runs\phase6_arduino_compile\firmware_manifest.json'
  function New-PristineManifest {
    [ordered]@{
      schema = 'vc-lora-phase6-firmware-manifest-v2'
      generated_at = '2026-09-14T00:00:00.0000000Z'
      fqbn = 'esp32:esp32:XIAO_ESP32S3'
      esp32_core = '3.3.11'
      arduino_cli = 'fixture'
      compile_order = @('vehicle', 'ground')
      compile_command = '.\tools\compile_arduino.ps1'
      flash_policy = [ordered]@{
        mode = 'app-only'
        app_only = $true
        offset = '0x10000'
        upload_order = @('vehicle', 'ground')
        erase_flash = $false
        write_bootloader = $false
        write_partition_table = $false
        write_merged_image = $false
        forbidden_selection_patterns = @(
          '*_flashed.bin', '*bootloader*.bin', '*partition*.bin',
          '*merged*.bin', '*boot_app0*.bin')
      }
      binaries = @(
        [ordered]@{
          role = 'vehicle'
          path = 'runs/phase6_arduino_compile/vehicle/vc_lora_vehicle_xiao_esp32s3.ino.bin'
          size_bytes = [int64](Get-Item -LiteralPath $vehicleBinary).Length
          sha256 = Get-Sha $vehicleBinary
        },
        [ordered]@{
          role = 'ground'
          path = 'runs/phase6_arduino_compile/ground/vc_lora_ground_xiao_esp32s3.ino.bin'
          size_bytes = [int64](Get-Item -LiteralPath $groundBinary).Length
          sha256 = Get-Sha $groundBinary
        })
      hwcdc_contract = [ordered]@{result='PASS'}
      source_tree_sha256 = 'A' * 64
      source_file_count = 1
      sources = @([ordered]@{path='fixture';size_bytes=1;sha256=('B' * 64)})
    }
  }
  function Write-Manifest([object]$Manifest) {
    Write-Utf8 $manifestPath (($Manifest | ConvertTo-Json -Depth 12) + "`n")
  }
  Write-Manifest (New-PristineManifest)

  $identityPath = Join-Path $fixture 'identity_fixture.json'
  function Write-IdentityFixture([bool]$WrongVehiclePnp = $false) {
    $vehiclePnp = if ($WrongVehiclePnp) {
      'USB\VID_303A&PID_1001&MI_00\WRONG'
    } else {
      'USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000'
    }
    $identity = [ordered]@{
      vehicle = [ordered]@{
        port='COM3';pnp_device_id=$vehiclePnp
        parent_device_id='USB\VID_303A&PID_1001\90:70:69:11:81:A4'
        status='OK';config_manager_error_code=0;availability=3
        name='fixture Vehicle';description='fixture Vehicle'
        location_paths=@('fixture-vehicle')
      }
      ground = [ordered]@{
        port='COM6'
        pnp_device_id='USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000'
        parent_device_id='USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80'
        status='OK';config_manager_error_code=0;availability=3
        name='fixture Ground';description='fixture Ground'
        location_paths=@('fixture-ground')
      }
    }
    Write-Utf8 $identityPath (($identity | ConvertTo-Json -Depth 8) + "`n")
  }
  Write-IdentityFixture

  $fakeEspTool = Join-Path $fixture 'tools\fake_esptool.ps1'
  Write-Utf8 $fakeEspTool @'
$ErrorActionPreference = 'Stop'
[string[]]$tokens = @($args | ForEach-Object { [string]$_ })
if ($env:VC_LORA_FLASH_FAKE_LOG) {
  [IO.File]::AppendAllText(
      $env:VC_LORA_FLASH_FAKE_LOG,
      (($tokens | ConvertTo-Json -Compress) + [Environment]::NewLine))
}
$scenario = [string]$env:VC_LORA_FLASH_FAKE_SCENARIO
if ($scenario -ceq 'stage_lock') {
  try {
    $self = [IO.File]::Open($PSCommandPath, [IO.FileMode]::Open,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    $self.Dispose()
    [IO.File]::AppendAllText($env:VC_LORA_FLASH_FAKE_LOCK_LOG,
        "TOOL_UNLOCKED`n")
  } catch {
    [IO.File]::AppendAllText($env:VC_LORA_FLASH_FAKE_LOCK_LOG,
        "TOOL_LOCKED`n")
  }
}
if ($tokens.Count -eq 1 -and $tokens[0] -ceq 'version') {
  Write-Output 'esptool v5.3.1'
  Write-Output '5.3.1'
  $global:LASTEXITCODE = 0
  return
}
$port = ''
$portIndex = [Array]::IndexOf($tokens, '--port')
if ($portIndex -ge 0 -and $portIndex + 1 -lt $tokens.Count) {
  $port = $tokens[$portIndex + 1]
}
$kind = @('read-mac','write-flash','verify-flash') |
    Where-Object { $tokens -ccontains $_ } | Select-Object -First 1
if ($kind -ceq 'write-flash') {
  $evidenceRoot = Split-Path -Parent (Split-Path -Parent $tokens[-1])
  $intentLeaf = if ($port -ceq 'COM3') {
    '02_vehicle_write.intent.json'
  } else {'05_ground_write.intent.json'}
  if (-not (Test-Path -LiteralPath (Join-Path $evidenceRoot $intentLeaf) `
      -PathType Leaf)) {
    Write-Output "missing durable write intent: $intentLeaf"
    $global:LASTEXITCODE = 12
    return
  }
}
if ($scenario -ceq 'nonzero_write' -and $kind -ceq 'write-flash') {
  Write-Output 'fixture write failure'
  $global:LASTEXITCODE = 7
  return
}
if ($kind -ceq 'read-mac') {
  $mac = if ($port -ceq 'COM3') {
    if ($scenario -ceq 'bad_mac') {'00:11:22:33:44:55'}
    else {'90:70:69:11:81:a4'}
  } else {'1c:db:d4:5a:83:80'}
  Write-Output "MAC:                $mac"
  if ($scenario -ceq 'mutate_original' -and $port -ceq 'COM3' -and
      $env:VC_LORA_FLASH_FAKE_MUTATE_PATH) {
    [IO.File]::AppendAllText($env:VC_LORA_FLASH_FAKE_MUTATE_PATH, 'X')
  }
  $global:LASTEXITCODE = 0
  return
}
if ($kind -ceq 'write-flash') {
  if ($scenario -ceq 'stage_lock') {
    try {
      $stream = [IO.File]::Open($tokens[-1], [IO.FileMode]::Open,
          [IO.FileAccess]::Write, [IO.FileShare]::None)
      $stream.Dispose()
      [IO.File]::AppendAllText($env:VC_LORA_FLASH_FAKE_LOCK_LOG,
          "BIN_UNLOCKED`n")
    } catch {
      [IO.File]::AppendAllText($env:VC_LORA_FLASH_FAKE_LOCK_LOG,
          "BIN_LOCKED`n")
    }
  }
  if ($scenario -cne 'missing_write_marker') {
    Write-Output 'Hash of data verified.'
  } else {
    Write-Output 'write completed without required marker'
  }
  $global:LASTEXITCODE = 0
  return
}
if ($kind -ceq 'verify-flash') {
  if ($scenario -cne 'missing_verify_marker') {
    Write-Output 'Verification successful (digest matched).'
  } else {
    Write-Output 'verify completed without required marker'
  }
  $global:LASTEXITCODE = 0
  return
}
[Console]::Error.WriteLine('unknown fixture arguments')
$global:LASTEXITCODE = 9
'@

  $evidenceBase = Join-Path $fixture `
      'runs\hil\R18-PHASE6-PRODUCTION-FLASH-001'
  $fakeLog = Join-Path $fixture 'fake_esptool_calls.jsonl'
  $lockLog = Join-Path $fixture 'fake_lock_result.txt'
  $env:VC_LORA_FLASH_FAKE_LOG = $fakeLog
  $env:VC_LORA_FLASH_FAKE_LOCK_LOG = $lockLog

  function Invoke-WrapperCase([string]$Leaf, [bool]$Execute,
                              [string]$Scenario = '',
                              [string]$Identity = '') {
    $evidence = Join-Path $evidenceBase $Leaf
    if (Test-Path -LiteralPath $fakeLog) {
      Remove-Item -LiteralPath $fakeLog -Force
    }
    if (Test-Path -LiteralPath $lockLog) {
      Remove-Item -LiteralPath $lockLog -Force
    }
    $env:VC_LORA_FLASH_FAKE_SCENARIO = $Scenario
    $parameters = @{
      RepoRoot = $fixture
      EvidenceDirectory = $evidence
      TestMode = $true
      TestEspToolPath = $fakeEspTool
    }
    if ($Execute) {
      $parameters.Execute = $true
      $parameters.TestIdentityFixturePath = if ($Identity) {
        $Identity
      } else {$identityPath}
    }
    $caught = $null
    $output = @()
    try {
      $output = @(& $fixtureWrapper @parameters 2>&1)
    } catch {
      $caught = $_.Exception.Message
    }
    [pscustomobject]@{
      evidence=$evidence
      success=($null -eq $caught)
      failure=$caught
      output=$output
      fake_calls=if (Test-Path -LiteralPath $fakeLog) {
        @(Get-Content -LiteralPath $fakeLog | ForEach-Object {
          @($_ | ConvertFrom-Json)
        })
      } else {@()}
    }
  }

  function Resolve-SealedEvidencePath([string]$Evidence,
                                      [string]$RelativePath) {
    Assert-Condition ($RelativePath -match
        '^[^\\/:]+(?:/[^\\/:]+)*$' -and
        @($RelativePath.Split('/') | Where-Object {
          $_ -in @('.','..')}).Count -eq 0) `
        "unsafe sealed evidence path: $RelativePath"
    $root = (Resolve-Path -LiteralPath $Evidence).Path.TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath(
        (Join-Path $root $RelativePath.Replace('/', '\')))
    Assert-Condition ($candidate.StartsWith(
        ($root + '\'), [StringComparison]::OrdinalIgnoreCase)) `
        "sealed evidence path escaped root: $RelativePath"
    return $candidate
  }

  function Assert-SealConsistent([string]$Evidence) {
    $root = (Resolve-Path -LiteralPath $Evidence).Path.TrimEnd('\')
    $summaryPath = Join-Path $root 'summary.json'
    $artifactPath = Join-Path $root 'artifact_manifest.json'
    $sumsPath = Join-Path $root 'SHA256SUMS.txt'
    $sealPath = Join-Path $root 'final_seal.json'
    $sidecarPath = Join-Path $root 'final_seal.sha256'
    foreach ($path in @($summaryPath,$artifactPath,$sumsPath,$sealPath,
        $sidecarPath)) {
      Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) `
          "sealed evidence file is missing: $(Split-Path -Leaf $path)"
    }
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    $artifact = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
    $seal = Get-Content -LiteralPath $sealPath -Raw | ConvertFrom-Json
    Assert-Condition ([string]$summary.result -ceq [string]$artifact.result -and
        [string]$summary.result -ceq [string]$seal.result) `
        'summary/artifact/seal result mismatch'
    Assert-Condition ([string]$seal.summary_sha256 -ceq
        (Get-Sha $summaryPath) -and
        [string]$seal.artifact_manifest_sha256 -ceq
          (Get-Sha $artifactPath) -and
        [string]$seal.sha256sums_sha256 -ceq (Get-Sha $sumsPath)) `
        'final seal hash link mismatch'
    Assert-Condition (([IO.File]::ReadAllText($sidecarPath)).TrimEnd() -ceq
        ((Get-Sha $sealPath) + ' *final_seal.json')) `
        'final seal sidecar mismatch'

    $rows = @($artifact.files)
    Assert-Condition ([int]$artifact.file_count -eq $rows.Count) `
        'artifact manifest file count mismatch'
    $recordedPaths = @($rows | ForEach-Object {[string]$_.path})
    Assert-Condition (@($recordedPaths | Sort-Object -Unique).Count -eq
        $recordedPaths.Count) 'artifact manifest has duplicate paths'
    foreach ($row in $rows) {
      $path = Resolve-SealedEvidencePath $root ([string]$row.path)
      Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) `
          "artifact row is missing: $($row.path)"
      $file = Get-Item -LiteralPath $path
      Assert-Condition ([int64]$row.size_bytes -eq [int64]$file.Length -and
          [string]$row.sha256 -ceq (Get-Sha $path)) `
          "artifact row hash/size mismatch: $($row.path)"
    }
    $excluded = @('artifact_manifest.json','SHA256SUMS.txt',
        'final_seal.json','final_seal.sha256')
    $actualPaths = @(Get-ChildItem -LiteralPath $root -Recurse -File |
      ForEach-Object {
        $_.FullName.Substring($root.Length + 1).Replace('\','/')
      } | Where-Object {$excluded -cnotcontains $_})
    Assert-Condition ($actualPaths.Count -eq $recordedPaths.Count -and
        @($actualPaths | Where-Object {
          $recordedPaths -cnotcontains $_}).Count -eq 0) `
        'artifact manifest omits or invents an evidence file'
    $expectedSums = (@($rows | ForEach-Object {
      "$($_.sha256) *$($_.path)"
    }) -join [Environment]::NewLine) + [Environment]::NewLine
    Assert-Condition ([IO.File]::ReadAllText($sumsPath) -ceq $expectedSums) `
        'SHA256SUMS does not exactly match artifact manifest rows'

    $steps = @($summary.steps)
    Assert-Condition ([int]$summary.recorded_step_count -eq $steps.Count -and
        [int]$summary.completed_step_count -eq @($steps | Where-Object {
          $_.result -ceq 'PASS'}).Count) 'summary step accounting mismatch'
    foreach ($step in $steps) {
      $recordPath = Resolve-SealedEvidencePath $root `
          ([string]$step.record_path)
      Assert-Condition ([string]$step.record_sha256 -ceq
          (Get-Sha $recordPath)) 'summary step record hash mismatch'
      $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
      Assert-Condition ([int]$step.number -eq [int]$record.number -and
          [string]$step.label -ceq [string]$record.label -and
          [string]$step.role -ceq [string]$record.role -and
          [string]$step.kind -ceq [string]$record.kind -and
          [string]$step.result -ceq [string]$record.result -and
          [int]$step.exit_code -eq [int]$record.exit_code) `
          'summary step does not match its sealed record'
    }
    return $summary
  }

  function Assert-FailedSealed([object]$Case, [string]$MessagePattern) {
    Assert-Condition (-not $Case.success) 'expected wrapper failure'
    Assert-Condition ($Case.failure -match $MessagePattern) `
        "unexpected failure: $($Case.failure)"
    foreach ($name in @('summary.json','artifact_manifest.json',
        'SHA256SUMS.txt','final_seal.json','final_seal.sha256')) {
      Assert-Condition (Test-Path -LiteralPath `
          (Join-Path $Case.evidence $name) -PathType Leaf) `
          "failed run lacks sealed evidence file $name"
    }
    $summary = Assert-SealConsistent $Case.evidence
    Assert-Condition ($summary.result -ceq 'FAIL') `
        'failed run summary is not FAIL'
    return $summary
  }

  # The canonical production wrapper must not accept test injection against a
  # crafted temp repository. Only the copied fixture wrapper may enter
  # TestMode, and even that copy accepts only the hash-pinned fake tool.
  $seamFailure = $null
  try {
    & $wrapperPath -RepoRoot $fixture `
        -EvidenceDirectory (Join-Path $evidenceBase 'canonical-seam') `
        -TestMode -TestEspToolPath $fakeEspTool `
        -TestIdentityFixturePath $identityPath -Execute 2>&1 | Out-Null
  } catch {
    $seamFailure = $_.Exception.Message
  }
  Assert-Condition ($seamFailure -match 'fixture wrapper copy') `
      'canonical wrapper accepted executable TestMode injection'
  Assert-Condition (-not (Test-Path -LiteralPath $fakeLog)) `
      'rejected canonical TestMode seam invoked the fake tool'

  # Default/dry mode must remain completely offline: the identity fixture is
  # deliberately not supplied, and the fake esptool call log must stay absent.
  $dry = Invoke-WrapperCase 'dry-pass' $false
  Assert-Condition $dry.success "dry-run failed: $($dry.failure)"
  Assert-Condition ((@($dry.output) -join "`n") -match
      '(?m)^FW-PHASE6-MANIFEST-FLASH-001 PASS mode=DryRun evidence=.+ seal_sha256=[0-9A-F]{64}$') `
      'dry-run PASS line does not render its mode/evidence/seal values'
  Assert-Condition (@($dry.fake_calls).Count -eq 0) `
      'dry-run invoked esptool'
  $drySummary = Get-Content -LiteralPath `
      (Join-Path $dry.evidence 'summary.json') -Raw | ConvertFrom-Json
  Assert-Condition ($drySummary.mode -ceq 'DryRun' -and
      $drySummary.result -ceq 'PASS' -and
      -not [bool]$drySummary.external_actions.device_access_attempted -and
      -not [bool]$drySummary.external_actions.esptool_executed -and
      -not [bool]$drySummary.external_actions.firmware_write_attempted) `
      'dry-run external-action accounting is not all false'
  [void](Assert-SealConsistent $dry.evidence)

  $tamper = Invoke-WrapperCase 'seal-tamper-detection' $false
  Assert-Condition $tamper.success 'seal-tamper fixture dry-run failed'
  [void](Assert-SealConsistent $tamper.evidence)
  $extraPath = Join-Path $tamper.evidence 'unsealed-extra.txt'
  Write-Utf8 $extraPath "extra`n"
  $tamperFailure = $null
  try {[void](Assert-SealConsistent $tamper.evidence)} catch {
    $tamperFailure = $_.Exception.Message
  }
  Assert-Condition ($tamperFailure -match 'omits|evidence file') `
      'independent seal verifier accepted an unsealed extra file'
  Remove-Item -LiteralPath $extraPath -Force
  [IO.File]::AppendAllText((Join-Path $tamper.evidence 'summary.json'),
      " `n")
  $tamperFailure = $null
  try {[void](Assert-SealConsistent $tamper.evidence)} catch {
    $tamperFailure = $_.Exception.Message
  }
  Assert-Condition ($tamperFailure -match 'seal hash') `
      'independent seal verifier accepted mutated sealed content'

  [byte[]]$pinnedFakeBytes = [IO.File]::ReadAllBytes($fakeEspTool)
  [IO.File]::AppendAllText($fakeEspTool, "# mutation`n")
  $case = Invoke-WrapperCase 'untrusted-fake-tool' $false
  [void](Assert-FailedSealed $case 'fake esptool fixture hash|pinned')
  Assert-Condition (@($case.fake_calls).Count -eq 0) `
      'untrusted fake tool was invoked'
  [IO.File]::WriteAllBytes($fakeEspTool, $pinnedFakeBytes)

  $drySummaryHash = Get-Sha (Join-Path $dry.evidence 'summary.json')
  $overwrite = Invoke-WrapperCase 'dry-pass' $false
  Assert-Condition (-not $overwrite.success -and
      $overwrite.failure -match 'already exists|refus') `
      'wrapper did not refuse an existing evidence directory'
  Assert-Condition ((Get-Sha (Join-Path $dry.evidence 'summary.json')) -ceq
      $drySummaryHash) 'overwrite attempt changed existing evidence'

  # Manifest policy and selection are checked again by the wrapper even when
  # the fixture verifier is intentionally permissive.
  $bad = New-PristineManifest
  $bad.flash_policy.offset = '0xe000'
  Write-Manifest $bad
  $case = Invoke-WrapperCase 'bad-offset' $false
  [void](Assert-FailedSealed $case '0x10000|app-only')

  $bad = New-PristineManifest
  $bad.binaries[0].role = 'ground'
  Write-Manifest $bad
  $case = Invoke-WrapperCase 'bad-role' $false
  [void](Assert-FailedSealed $case 'role|order')

  $bad = New-PristineManifest
  $bad.binaries[0].sha256 = '0' * 64
  Write-Manifest $bad
  $case = Invoke-WrapperCase 'bad-hash' $false
  [void](Assert-FailedSealed $case 'SHA-256|hash')

  $forbiddenNames = @(
    'vc_lora_vehicle_xiao_esp32s3.ino_flashed.bin',
    'vc_lora_vehicle_xiao_esp32s3.ino.bootloader.bin',
    'vc_lora_vehicle_xiao_esp32s3.ino.partitions.bin',
    'vc_lora_vehicle_xiao_esp32s3.ino.merged.bin',
    'boot_app0.bin')
  for ($forbiddenIndex = 0; $forbiddenIndex -lt $forbiddenNames.Count;
      ++$forbiddenIndex) {
    $forbiddenName = $forbiddenNames[$forbiddenIndex]
    $forbidden = Join-Path (Split-Path -Parent $vehicleBinary) `
        $forbiddenName
    [IO.File]::WriteAllBytes($forbidden, $vehicleBytes)
    $bad = New-PristineManifest
    $bad.binaries[0].path =
        'runs/phase6_arduino_compile/vehicle/' + $forbiddenName
    $bad.binaries[0].size_bytes = (Get-Item $forbidden).Length
    $bad.binaries[0].sha256 = Get-Sha $forbidden
    Write-Manifest $bad
    $case = Invoke-WrapperCase "forbidden-name-$forbiddenIndex" $false
    [void](Assert-FailedSealed $case 'forbidden|binary path')
  }

  Write-Manifest (New-PristineManifest)
  Write-IdentityFixture -WrongVehiclePnp $true
  $case = Invoke-WrapperCase 'wrong-identity' $true
  $summary = Assert-FailedSealed $case 'PNP|identity'
  Assert-Condition (-not [bool]$summary.external_actions.firmware_write_attempted) `
      'identity mismatch reached a write attempt'
  Write-IdentityFixture

  $case = Invoke-WrapperCase 'wrong-mac' $true 'bad_mac'
  $summary = Assert-FailedSealed $case 'MAC|mac'
  Assert-Condition (-not [bool]$summary.external_actions.firmware_write_attempted) `
      'MAC mismatch reached a write attempt'

  foreach ($failureCase in @(
      [pscustomobject]@{leaf='write-nonzero';scenario='nonzero_write';pattern='exit'},
      [pscustomobject]@{leaf='write-marker';scenario='missing_write_marker';pattern='marker'},
      [pscustomobject]@{leaf='verify-marker';scenario='missing_verify_marker';pattern='marker'}
    )) {
    $case = Invoke-WrapperCase $failureCase.leaf $true $failureCase.scenario
    $failureSummary = Assert-FailedSealed $case $failureCase.pattern
    if ($failureCase.scenario -ceq 'nonzero_write') {
      Assert-Condition ([int]$failureSummary.steps[-1].exit_code -eq 7) `
          'nonzero esptool exit code was not preserved in sealed evidence'
    }
    $groundCalls = @($case.fake_calls | Where-Object { @($_) -contains 'COM6' })
    Assert-Condition ($groundCalls.Count -eq 0) `
        "$($failureCase.leaf) continued to Ground"
  }

  # A manifest-selected source mutation after Vehicle read-mac must be caught
  # before the Vehicle write begins.
  Write-Manifest (New-PristineManifest)
  $env:VC_LORA_FLASH_FAKE_MUTATE_PATH = $vehicleBinary
  $case = Invoke-WrapperCase 'source-mutation' $true 'mutate_original'
  $summary = Assert-FailedSealed $case 'SHA-256|hash|changed'
  Assert-Condition (-not [bool]$summary.external_actions.firmware_write_attempted) `
      'source mutation was not stopped before write'
  [IO.File]::WriteAllBytes($vehicleBinary, $vehicleBytes)
  $env:VC_LORA_FLASH_FAKE_MUTATE_PATH = $null
  Write-Manifest (New-PristineManifest)

  # Successful fake execution establishes exact order/argv and proves staged
  # application binaries are held against mutation throughout esptool access.
  $case = Invoke-WrapperCase 'execute-pass' $true 'stage_lock'
  Assert-Condition $case.success "fake execute failed: $($case.failure)"
  $summary = Get-Content -LiteralPath `
      (Join-Path $case.evidence 'summary.json') -Raw | ConvertFrom-Json
  Assert-Condition ($summary.result -ceq 'PASS' -and
      $summary.mode -ceq 'Execute' -and
      [bool]$summary.external_actions.firmware_write_attempted -and
      [bool]$summary.external_actions.firmware_flash_performed -and
      [int]$summary.completed_step_count -eq 6) `
      'successful execute summary is incomplete'
  [void](Assert-SealConsistent $case.evidence)

  $toolCalls = @($case.fake_calls | Where-Object {
    @($_) -contains 'read-mac' -or @($_) -contains 'write-flash' -or
    @($_) -contains 'verify-flash'
  })
  Assert-Condition ($toolCalls.Count -eq 6) `
      "expected six flash steps, actual=$($toolCalls.Count)"
  $vehicleStage = Join-Path $case.evidence `
      'staged\vehicle.application.bin'
  $groundStage = Join-Path $case.evidence `
      'staged\ground.application.bin'
  $vehicleBase = @('--chip','esp32s3','--port','COM3','--baud','921600',
      '--before','default-reset','--after','hard-reset')
  $groundBase = @('--chip','esp32s3','--port','COM6','--baud','921600',
      '--before','default-reset','--after','hard-reset')
  $expected = @(
    [string[]]($vehicleBase + @('read-mac')),
    [string[]]($vehicleBase + @('write-flash','-z','--flash-mode','keep',
        '--flash-freq','keep','--flash-size','keep','0x10000',$vehicleStage)),
    [string[]]($vehicleBase + @('verify-flash','0x10000',$vehicleStage)),
    [string[]]($groundBase + @('read-mac')),
    [string[]]($groundBase + @('write-flash','-z','--flash-mode','keep',
        '--flash-freq','keep','--flash-size','keep','0x10000',$groundStage)),
    [string[]]($groundBase + @('verify-flash','0x10000',$groundStage)))
  for ($index = 0; $index -lt $expected.Count; ++$index) {
    [string[]]$tokens = @($toolCalls[$index])
    [string[]]$expectedTokens = @($expected[$index])
    Assert-Condition ($tokens.Count -eq $expectedTokens.Count) `
        "step argv count mismatch at $index"
    for ($tokenIndex = 0; $tokenIndex -lt $expectedTokens.Count;
        ++$tokenIndex) {
      Assert-Condition ($tokens[$tokenIndex] -ceq
          $expectedTokens[$tokenIndex]) `
          "step argv mismatch at $index/$tokenIndex"
    }
    Assert-Condition (@($tokens | Where-Object {$_ -match
        '(?i)erase|bootloader|partitions?|merged|_flashed|boot_app0'}).Count `
        -eq 0) `
        "forbidden token in step $index"
    if ($tokens -ccontains 'write-flash' -or
        $tokens -ccontains 'verify-flash') {
      Assert-Condition (@($tokens | Where-Object {$_ -ceq '0x10000'}).Count -eq 1) `
          "step $index does not contain one exact app offset"
      $binTokens = @($tokens | Where-Object {$_.EndsWith('.bin')})
      Assert-Condition ($binTokens.Count -eq 1 -and
          (Split-Path -Leaf $binTokens[0]) -in @(
            'vehicle.application.bin','ground.application.bin')) `
          "step $index selected a non-staged application binary"
    }
  }
  $locks = @(Get-Content -LiteralPath $lockLog)
  Assert-Condition (@($locks | Where-Object {
        $_ -ceq 'BIN_LOCKED'}).Count -eq 2 -and
      @($locks | Where-Object {$_ -ceq 'BIN_UNLOCKED'}).Count -eq 0) `
      'staged application binaries were not read-locked during both writes'
  Assert-Condition (@($locks | Where-Object {
        $_ -ceq 'TOOL_LOCKED'}).Count -eq 7 -and
      @($locks | Where-Object {$_ -ceq 'TOOL_UNLOCKED'}).Count -eq 0) `
      'staged esptool was not read-locked throughout all invocations'
  foreach ($leaf in @(
      '02_vehicle_write.intent.json','02_vehicle_write.terminal.json',
      '05_ground_write.intent.json','05_ground_write.terminal.json')) {
    Assert-Condition (Test-Path -LiteralPath `
        (Join-Path $case.evidence $leaf) -PathType Leaf) `
        "write-ahead journal lacks $leaf"
  }

  foreach ($name in @('preflight.json','summary.json','artifact_manifest.json',
      'SHA256SUMS.txt','final_seal.json','final_seal.sha256')) {
    Assert-Condition (Test-Path -LiteralPath `
        (Join-Path $case.evidence $name) -PathType Leaf) `
        "PASS evidence lacks $name"
  }

  Write-Output "$testId PASS"
} finally {
  $env:VC_LORA_FLASH_FAKE_SCENARIO = $oldScenario
  $env:VC_LORA_FLASH_FAKE_LOG = $oldLog
  $env:VC_LORA_FLASH_FAKE_MUTATE_PATH = $oldMutate
  $env:VC_LORA_FLASH_FAKE_LOCK_LOG = $oldLockLog
  $expectedPrefix = [IO.Path]::GetTempPath()
  if ($fixture.StartsWith($expectedPrefix,
      [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $fixture) -match
        '^vc_lora_phase6_flash_contract_[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $fixture)) {
    Remove-Item -LiteralPath $fixture -Recurse -Force
  }
}
