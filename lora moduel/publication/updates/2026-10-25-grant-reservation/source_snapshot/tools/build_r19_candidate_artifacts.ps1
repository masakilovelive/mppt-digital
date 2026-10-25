[CmdletBinding()]
param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$OutputBase = '',
  [string]$ArduinoCli = '',
  [string]$Fqbn = 'esp32:esp32:XIAO_ESP32S3',
  [string]$ExpectedEsp32CoreVersion = '3.3.11',
  [string]$IdeConfig = (Join-Path $env:USERPROFILE `
    '.arduinoIDE\arduino-cli.yaml'),
  [string]$InstalledEsp32CoreRoot = '',
  [string]$CanonicalPatchedCoreRoot = '',
  [switch]$RuntimeFailDiagnostics,
  [ValidateSet('Disabled','SyncOnly','ExplicitHostArm')][string]$TimedPathMode='Disabled',
  [switch]$AuxReadinessDiagnostics,
  [switch]$DiagnosticUsbFailureDiagnostics,
  [switch]$GrantDiagnostics,
  [switch]$GrantReservationDiagnostics
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'r19_candidate_artifact_common.ps1')

$repo = Resolve-R19RepositoryRoot $RepoRoot
$runtimeFailDiagnosticsEnabled = $RuntimeFailDiagnostics.IsPresent
$acceptanceEligible = -not $runtimeFailDiagnosticsEnabled
$acceptanceAuthorized = $false
$deploymentAuthorized = $false
$auxReadinessEnabled=$AuxReadinessDiagnostics.IsPresent
$diagnosticUsbFailureEnabled=$DiagnosticUsbFailureDiagnostics.IsPresent
$grantDiagnosticsEnabled=$GrantDiagnostics.IsPresent
$grantReservationEnabled=$GrantReservationDiagnostics.IsPresent
$outputLeaf = Get-R19CandidateOutputLeaf $runtimeFailDiagnosticsEnabled $TimedPathMode $auxReadinessEnabled $diagnosticUsbFailureEnabled $grantDiagnosticsEnabled $grantReservationEnabled
$timedPathEnabled=$TimedPathMode-cne'Disabled'
$timedPathContract=Get-R19TimedPathCandidateContract $repo $TimedPathMode
$auxReadinessContract=Get-R19AuxReadinessCandidateContract $repo $auxReadinessEnabled
$diagnosticUsbFailureContract=Get-R19DiagnosticUsbFailureCandidateContract $repo $diagnosticUsbFailureEnabled
$grantDiagnosticContract=Get-R19GrantDiagnosticCandidateContract $repo $grantDiagnosticsEnabled
$grantReservationContract=if($grantReservationEnabled){Get-R19GrantReservationCandidateContract -RepoRoot $repo -Enabled $true}else{$null}
$usbRoleCapabilities=$null
if($diagnosticUsbFailureEnabled){$usbRoleCapabilities=Get-R19UsbRoleCapabilities -RepoRoot $repo -Mode $TimedPathMode -Enabled $true}
$expectedOutputBase = Join-Path $repo `
  (Join-Path 'runs\candidates' $outputLeaf)
if ([string]::IsNullOrWhiteSpace($OutputBase)) {
  $OutputBase = $expectedOutputBase
}
$outputBaseFull = [IO.Path]::GetFullPath($OutputBase).TrimEnd(
  [IO.Path]::DirectorySeparatorChar,
  [IO.Path]::AltDirectorySeparatorChar)
if ($outputBaseFull -cne [IO.Path]::GetFullPath($expectedOutputBase).
    TrimEnd([IO.Path]::DirectorySeparatorChar,
      [IO.Path]::AltDirectorySeparatorChar)) {
  throw "R19 candidate output base must be: $expectedOutputBase"
}
New-Item -ItemType Directory -Path $outputBaseFull -Force | Out-Null

$lockPath = Join-Path $outputBaseFull '.publish.lock'
$publishLock = $null
$tempRoot = $null
$runRoot = $null
$latestPublished = $false

function Get-CompilerSection([object]$CompileResult, [string]$Name) {
  $section = @($CompileResult.builder_result.executable_sections_size |
    Where-Object { $_.name -ceq $Name })
  if ($section.Count -ne 1) {
    throw "Arduino compile did not return one $Name size record"
  }
  return $section[0]
}

function Add-OptionalUsbFailureMetadata([object]$Record) {
  if([bool](Get-Variable -Name grantReservationEnabled -ValueOnly -ErrorAction SilentlyContinue)){
    Add-Member -InputObject $Record -NotePropertyName grant_reservation_diagnostics -NotePropertyValue $grantReservationContract
  }
  if([bool](Get-Variable -Name grantDiagnosticsEnabled -ValueOnly -ErrorAction SilentlyContinue)){
    Add-Member -InputObject $Record -NotePropertyName grant_diagnostics -NotePropertyValue $grantDiagnosticContract
  }
  if(-not$diagnosticUsbFailureEnabled){return}
  Add-Member -InputObject $Record -NotePropertyName diagnostic_usb_failure_diagnostics -NotePropertyValue $diagnosticUsbFailureContract
  Add-Member -InputObject $Record -NotePropertyName usb_role_capabilities -NotePropertyValue $usbRoleCapabilities
}

function Add-DiagnosticAbiMetadata([object]$Record) {
  if (-not $runtimeFailDiagnosticsEnabled) { return }
  Add-Member -InputObject $Record -NotePropertyName 'endpoint_fifo_schema' `
    -NotePropertyValue 2
  Add-Member -InputObject $Record -NotePropertyName 'endpoint_fifo_size_bytes' `
    -NotePropertyValue 112
  Add-Member -InputObject $Record -NotePropertyName 'runtime_stage_size_bytes' `
    -NotePropertyValue 68
  Add-Member -InputObject $Record -NotePropertyName 'reader_schema' `
    -NotePropertyValue $(if([bool](Get-Variable -Name grantReservationEnabled -ValueOnly -ErrorAction SilentlyContinue)){'vc-lora-r19-runtime-stage-jtag-read-v10'}elseif([bool](Get-Variable -Name grantDiagnosticsEnabled -ValueOnly -ErrorAction SilentlyContinue)){'vc-lora-r19-runtime-stage-jtag-read-v9'}elseif($diagnosticUsbFailureEnabled){'vc-lora-r19-runtime-stage-jtag-read-v8'}elseif($auxReadinessEnabled){'vc-lora-r19-runtime-stage-jtag-read-v7'}else{'vc-lora-r19-runtime-stage-jtag-read-v5'})
  Add-Member -InputObject $Record -NotePropertyName 'usb_extended_diagnostics' `
    -NotePropertyValue (Get-R19DiagnosticExtensionContract $true)
  Add-Member -InputObject $Record -NotePropertyName 'first_usb_failure_decoder' `
    -NotePropertyValue (Get-R19FirstFailureDecoderBinding $repo)
  if($timedPathEnabled){Add-Member -InputObject $Record -NotePropertyName 'timed_path_diagnostics' -NotePropertyValue $timedPathContract}
  if($auxReadinessEnabled){Add-Member -InputObject $Record -NotePropertyName 'aux_readiness_diagnostics' -NotePropertyValue $auxReadinessContract}
  Add-OptionalUsbFailureMetadata $Record
}

function Get-CurrentPreservationSnapshot {
  $defaultRoots = @($script:R19CandidateRoles | ForEach-Object {
      Join-Path $repo $_.sketch
    })
  $standardArtifacts = Join-Path $repo 'runs\phase6_arduino_compile'
  return [pscustomobject][ordered]@{
    default_sketches = Get-R19TreeSnapshot $repo $defaultRoots
    standard_artifacts = Get-R19TreeSnapshot $repo @($standardArtifacts)
  }
}

function Assert-Preservation([object]$Expected, [string]$Checkpoint) {
  $actual = Get-CurrentPreservationSnapshot
  Assert-R19SameSnapshot $Expected.default_sketches `
    $actual.default_sketches "Default production sketches at $Checkpoint"
  Assert-R19SameSnapshot $Expected.standard_artifacts `
    $actual.standard_artifacts "Standard Phase 6 artifacts at $Checkpoint"
  return $actual
}

function Copy-CandidateRolePackage([object]$Role) {
  $sourceSketch = Join-Path $repo $Role.sketch
  $targetSketch = Join-Path (Join-Path $runRoot 'package') $Role.sketch
  New-Item -ItemType Directory -Path $targetSketch | Out-Null
  foreach ($directory in @('src', 'vc_lora', 'high_speed')) {
    New-Item -ItemType Directory -Path (Join-Path $targetSketch $directory) |
      Out-Null
  }

  Copy-R19DurableFile `
    (Join-Path $sourceSketch ($Role.sketch + '.ino')) `
    (Join-Path $targetSketch ($Role.sketch + '.ino'))
  Copy-R19DurableFile `
    (Join-Path $repo 'firmware\phase6\vc_lora_phase6_bridge.hpp') `
    (Join-Path $targetSketch 'vc_lora_phase6_bridge.hpp')
  Copy-R19DurableFile `
    (Join-Path $repo `
      'firmware\arduino_libraries\VC_LoRa_Core\src\VC_LoRa_Core.h') `
    (Join-Path $targetSketch 'VC_LoRa_Core.h')
  foreach ($source in @(Get-ChildItem -LiteralPath `
      (Join-Path $repo 'core\src') -File -Filter '*.cpp')) {
    Copy-R19DurableFile $source.FullName `
      (Join-Path (Join-Path $targetSketch 'src') $source.Name)
  }
  foreach ($header in @(Get-ChildItem -LiteralPath `
      (Join-Path $repo 'core\include\vc_lora') -File -Filter '*.hpp')) {
    Copy-R19DurableFile $header.FullName `
      (Join-Path (Join-Path $targetSketch 'vc_lora') $header.Name)
  }
  foreach ($name in $script:R19CandidateHeaderNames) {
    Copy-R19DurableFile `
      (Join-Path (Join-Path $repo 'firmware\high_speed') $name) `
      (Join-Path (Join-Path $targetSketch 'high_speed') $name)
  }
  if($timedPathEnabled){
    New-Item -ItemType Directory -Path (Join-Path $targetSketch 'diagnostics') | Out-Null
    Copy-R19DurableFile (Join-Path $repo 'firmware/high_speed/r19_timed_path_record.hpp') (Join-Path $targetSketch 'high_speed/r19_timed_path_record.hpp')
    Copy-R19DurableFile (Join-Path $repo 'firmware/diagnostics/r19_host_readiness.hpp') (Join-Path $targetSketch 'diagnostics/r19_host_readiness.hpp')
  }
  if($auxReadinessEnabled){Copy-R19DurableFile (Join-Path $repo 'firmware/high_speed/r19_aux_readiness_record.hpp') (Join-Path $targetSketch 'high_speed/r19_aux_readiness_record.hpp')}
  if($diagnosticUsbFailureEnabled){Copy-R19DurableFile (Join-Path $repo 'firmware/high_speed/r19_diagnostic_usb_failure_record.hpp') (Join-Path $targetSketch 'high_speed/r19_diagnostic_usb_failure_record.hpp')}
  if([bool](Get-Variable -Name grantDiagnosticsEnabled -ValueOnly -ErrorAction SilentlyContinue)){Copy-R19DurableFile (Join-Path $repo 'firmware/high_speed/r19_grant_diagnostic_record.hpp') (Join-Path $targetSketch 'high_speed/r19_grant_diagnostic_record.hpp')}
  if([bool](Get-Variable -Name grantReservationEnabled -ValueOnly -ErrorAction SilentlyContinue)){
    foreach($header in @('r19_grant_reservation.hpp','r19_grant_reservation_record.hpp')){Copy-R19DurableFile (Join-Path $repo ('firmware/high_speed/'+$header)) (Join-Path $targetSketch ('high_speed/'+$header))}
  }
  return $targetSketch
}

function Remove-StagedCompilerExports([string]$StagedSketch,
                                      [string]$RoleName) {
  $generatedBuild = Join-Path $StagedSketch 'build'
  if (-not (Test-Path -LiteralPath $generatedBuild)) {
    return
  }
  $resolved = (Resolve-Path -LiteralPath $generatedBuild).Path
  $expected = [IO.Path]::GetFullPath($generatedBuild)
  if ($resolved -cne $expected) {
    throw "$RoleName staged compiler-export path was redirected"
  }
  [void](Assert-R19PathWithin $runRoot $resolved `
    "$RoleName staged compiler exports")
  Remove-Item -LiteralPath $resolved -Recurse -Force
  if (Test-Path -LiteralPath $resolved) {
    throw "$RoleName staged compiler exports were not removed"
  }
}

function Write-CompileEvidence([object]$Role, [object[]]$Arguments,
                               [int]$ExitCode, [object]$CompileResult,
                               [object]$ApplicationRecord,
                               [object]$ApplicationBinaryProvenance,
                               [object]$ApplicationFlashLayout) {
  $text = [string]($CompileResult.compiler_out)
  $errorText = [string]($CompileResult.compiler_err)
  $flash = Get-CompilerSection $CompileResult 'text'
  $ram = Get-CompilerSection $CompileResult 'data'
  $record = [pscustomobject][ordered]@{
    schema = 'vc-lora-r19-candidate-compile-evidence-v1'
    role = $Role.role
    result = 'PASS'
    exit_code = $ExitCode
    argv = @($Arguments)
    candidate_enable_flag = '-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1'
    runtime_fail_diagnostics_enabled = $runtimeFailDiagnosticsEnabled
    acceptance_eligible = $acceptanceEligible
    acceptance_authorized = $acceptanceAuthorized
    deployment_authorized = $deploymentAuthorized
    flash_bytes = [int64]$flash.size
    ram_bytes = [int64]$ram.size
    compiler_out = $text
    compiler_err = $errorText
    application = $ApplicationRecord
    application_binary_provenance = $ApplicationBinaryProvenance
    application_flash_layout = $ApplicationFlashLayout
  }
  $path = Join-Path (Join-Path $runRoot 'evidence') `
    ("compile-{0}.json" -f $Role.role)
  if($timedPathEnabled){Add-Member -InputObject $record -NotePropertyName timed_path_diagnostics -NotePropertyValue $timedPathContract}
  if($auxReadinessEnabled){Add-Member -InputObject $record -NotePropertyName aux_readiness_diagnostics -NotePropertyValue $auxReadinessContract}
  Add-OptionalUsbFailureMetadata $record
  Write-R19DurableJson $path $record
  $compileBinding=[pscustomobject][ordered]@{
    argv = @($Arguments)
    runtime_fail_diagnostics_enabled = $runtimeFailDiagnosticsEnabled
    acceptance_eligible = $acceptanceEligible
    acceptance_authorized = $acceptanceAuthorized
    deployment_authorized = $deploymentAuthorized
    flash_bytes = [int64]$flash.size
    ram_bytes = [int64]$ram.size
    evidence_path = Get-R19RelativePath $runRoot $path
    evidence_sha256 = Get-R19Sha256 $path
  }
  if($timedPathEnabled){Add-Member -InputObject $compileBinding -NotePropertyName timed_path_diagnostics -NotePropertyValue $timedPathContract}
  if($auxReadinessEnabled){Add-Member -InputObject $compileBinding -NotePropertyName aux_readiness_diagnostics -NotePropertyValue $auxReadinessContract}
  Add-OptionalUsbFailureMetadata $compileBinding
  return $compileBinding
}

function New-ApplicationOriginRecord([string]$Origin, [string]$Path) {
  $file = Get-Item -LiteralPath $Path -ErrorAction Stop
  if ($file.PSIsContainer) {
    throw "Application binary origin is not a file: $Path"
  }
  return [pscustomobject][ordered]@{
    origin = $Origin
    file_name = $file.Name
    size_bytes = [int64]$file.Length
    sha256 = Get-R19Sha256 $file.FullName
  }
}

function Publish-ReproducibilityArtifacts([object]$Role,
                                           [string]$BuildPath) {
  $targetRoot = Join-Path (Join-Path (Join-Path $runRoot 'evidence') `
    'build') $Role.role
  New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
  $sourceByPublishedName = [ordered]@{
    'application.elf' = Join-Path $BuildPath ($Role.sketch + '.ino.elf')
    'application.map' = Join-Path $BuildPath ($Role.sketch + '.ino.map')
    'build.options.json' = Join-Path $BuildPath 'build.options.json'
    'sdkconfig' = Join-Path $BuildPath 'sdkconfig'
    'partitions.csv' = Join-Path $BuildPath 'partitions.csv'
    'flash_args' = Join-Path $BuildPath 'flash_args'
  }
  $actualNames = @($sourceByPublishedName.Keys)
  if ((@($actualNames) -join ',') -cne
      (@($script:R19CandidateReproducibilityArtifactNames) -join ',')) {
    throw "$($Role.name) reproducibility artifact mapping is not exact"
  }
  $records = [Collections.Generic.List[object]]::new()
  foreach ($name in $script:R19CandidateReproducibilityArtifactNames) {
    $source = [string]$sourceByPublishedName[$name]
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      throw "$($Role.name) compile omitted reproducibility artifact: $source"
    }
    $destination = Join-Path $targetRoot $name
    Copy-R19DurableFile $source $destination
    $records.Add((New-R19FileRecord $runRoot $destination))
  }
  $ordered = @(Get-R19OrdinalPathRecords $records.ToArray())
  return [pscustomobject][ordered]@{
    file_count = $ordered.Count
    tree_sha256 = Get-R19CanonicalTreeHash $ordered
    files = $ordered
  }
}

function Publish-LatestPointer([object]$Pointer) {
  $latestPath = Join-Path $outputBaseFull 'latest.json'
  $latestHashPath = Join-Path $outputBaseFull 'latest.sha256'
  $previousHash = ''
  $latestExists = Test-Path -LiteralPath $latestPath -PathType Leaf
  $hashExists = Test-Path -LiteralPath $latestHashPath -PathType Leaf
  if ($latestExists -ne $hashExists) {
    throw 'R19 latest pointer pair is incomplete; refusing to publish'
  }
  if ($latestExists) {
    $previousHash = Read-R19HashFile $latestHashPath 'latest.json'
    if ((Get-R19Sha256 $latestPath) -cne $previousHash) {
      throw 'R19 latest pointer hash mismatch; refusing to publish'
    }
  }
  $Pointer.previous_latest_sha256 = $previousHash

  $nonce = [Guid]::NewGuid().ToString('N')
  $pendingJson = Join-Path $outputBaseFull ".latest-$nonce.json"
  $pendingHash = Join-Path $outputBaseFull ".latest-$nonce.sha256"
  $backupJson = Join-Path $outputBaseFull ".latest-$nonce.backup.json"
  $backupHash = Join-Path $outputBaseFull ".latest-$nonce.backup.sha256"
  try {
    Write-R19DurableJson $pendingJson $Pointer
    $newHash = Get-R19Sha256 $pendingJson
    Write-R19DurableText $pendingHash "$newHash *latest.json`n"
    if ($latestExists) {
      [IO.File]::Replace($pendingJson, $latestPath, $backupJson, $true)
      try {
        [IO.File]::Replace($pendingHash, $latestHashPath, $backupHash, $true)
      } catch {
        [IO.File]::Copy($backupJson, $latestPath, $true)
        throw
      }
    } else {
      [IO.File]::Move($pendingJson, $latestPath)
      [IO.File]::Move($pendingHash, $latestHashPath)
    }
    if ((Get-R19Sha256 $latestPath) -cne $newHash -or
        (Read-R19HashFile $latestHashPath 'latest.json') -cne $newHash) {
      throw 'Published R19 latest pointer did not verify'
    }
    return $newHash
  } finally {
    foreach ($path in @($pendingJson, $pendingHash, $backupJson, $backupHash)) {
      if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
      }
    }
  }
}

try {
  $publishLock = [IO.FileStream]::new(
    $lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::None, 1, [IO.FileOptions]::WriteThrough)

  $preservationBefore = Get-CurrentPreservationSnapshot
  $sourceBefore = Get-R19CandidateSourceSnapshot $repo $TimedPathMode $auxReadinessEnabled $diagnosticUsbFailureEnabled $grantDiagnosticsEnabled $grantReservationEnabled

  $bridgePath = Join-Path $repo `
    'firmware\phase6\vc_lora_phase6_bridge.hpp'
  $bridgeText = Get-Content -LiteralPath $bridgePath -Raw
  if ($bridgeText -notmatch `
      '#define\s+VC_LORA_R19_HIGH_SPEED_CANDIDATE\s+0') {
    throw 'The canonical bridge no longer defaults the R19 candidate to zero'
  }
  if ($bridgeText -notmatch `
      '#define\s+VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s+0') {
    throw 'The canonical bridge no longer defaults runtime diagnostics to zero'
  }
  foreach ($role in $script:R19CandidateRoles) {
    $wrapperPath = Join-Path (Join-Path $repo $role.sketch) `
      ($role.sketch + '.ino')
    $wrapperText = Get-Content -LiteralPath $wrapperPath -Raw
    if ($wrapperText -match 'VC_LORA_R19_HIGH_SPEED_CANDIDATE') {
      throw "Default $($role.name) wrapper opts into the R19 candidate"
    }
  }

  if ([string]::IsNullOrWhiteSpace($ArduinoCli)) {
    $ArduinoCli = Join-Path $env:TEMP `
      'arduino-cli-vc-lora-check\arduino-cli.exe'
  }
  if (-not (Test-Path -LiteralPath $ArduinoCli -PathType Leaf)) {
    $found = Get-Command arduino-cli -ErrorAction SilentlyContinue
    if ($null -eq $found) {
      throw 'arduino-cli not found'
    }
    $ArduinoCli = $found.Source
  }
  $arduinoCliFile = Get-Item -LiteralPath $ArduinoCli
  $arduinoCliSha = Get-R19Sha256 $arduinoCliFile.FullName

  $globalArgs = @()
  $ideConfigRecord = [pscustomobject][ordered]@{ path = ''; sha256 = '' }
  if (-not [string]::IsNullOrWhiteSpace($IdeConfig)) {
    if (-not (Test-Path -LiteralPath $IdeConfig -PathType Leaf)) {
      throw "Arduino IDE config not found: $IdeConfig"
    }
    $ideConfigFile = Get-Item -LiteralPath $IdeConfig
    $globalArgs += @('--config-file', $ideConfigFile.FullName)
    $ideConfigRecord.path = $ideConfigFile.FullName
    $ideConfigRecord.sha256 = Get-R19Sha256 $ideConfigFile.FullName
  }

  $cliVersionText = (& $arduinoCliFile.FullName @globalArgs version `
      --format json 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw "arduino-cli version failed: $cliVersionText"
  }
  $cliVersion = $cliVersionText | ConvertFrom-Json
  $boardText = (& $arduinoCliFile.FullName @globalArgs board details `
      --fqbn $Fqbn --format json 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw "arduino-cli board details failed: $boardText"
  }
  $board = $boardText | ConvertFrom-Json
  if ([string]$board.version -cne $ExpectedEsp32CoreVersion) {
    throw ("Expected ESP32 core $ExpectedEsp32CoreVersion, got " +
      [string]$board.version)
  }

  if ([string]::IsNullOrWhiteSpace($InstalledEsp32CoreRoot)) {
    $InstalledEsp32CoreRoot = Join-Path $env:LOCALAPPDATA `
      "Arduino15\packages\esp32\hardware\esp32\$ExpectedEsp32CoreVersion"
  }
  if ([string]::IsNullOrWhiteSpace($CanonicalPatchedCoreRoot)) {
    $CanonicalPatchedCoreRoot = Join-Path $repo `
      'third_party\esp32-core-3.3.11-vc-lora'
  }
  $installedCore = (Resolve-Path -LiteralPath $InstalledEsp32CoreRoot).
    Path
  $canonicalCore = (Resolve-Path -LiteralPath $CanonicalPatchedCoreRoot).
    Path
  $installedHwcdcCpp = Join-Path $installedCore 'cores\esp32\HWCDC.cpp'
  $installedHwcdcHeader = Join-Path $installedCore 'cores\esp32\HWCDC.h'
  $installedHwcdcDiagnosticHeader = Join-Path $installedCore `
    'cores\esp32\HWCDCR19Diagnostic.h'
  $canonicalHwcdcCpp = Join-Path $canonicalCore 'cores\esp32\HWCDC.cpp'
  $canonicalHwcdcHeader = Join-Path $canonicalCore 'cores\esp32\HWCDC.h'
  $canonicalHwcdcDiagnosticHeader = Join-Path $canonicalCore `
    'cores\esp32\HWCDCR19Diagnostic.h'
  $hwcdcHashes = [pscustomobject][ordered]@{
    installed_cpp_sha256 = Get-R19Sha256 $installedHwcdcCpp
    installed_h_sha256 = Get-R19Sha256 $installedHwcdcHeader
    installed_diagnostic_h_path =
      (Get-Item -LiteralPath $installedHwcdcDiagnosticHeader).FullName
    installed_diagnostic_h_sha256 =
      Get-R19Sha256 $installedHwcdcDiagnosticHeader
    canonical_cpp_sha256 = Get-R19Sha256 $canonicalHwcdcCpp
    canonical_h_sha256 = Get-R19Sha256 $canonicalHwcdcHeader
    canonical_diagnostic_h_path =
      (Get-Item -LiteralPath $canonicalHwcdcDiagnosticHeader).FullName
    canonical_diagnostic_h_sha256 =
      Get-R19Sha256 $canonicalHwcdcDiagnosticHeader
    exact_match = $false
  }
  $hwcdcHashes.exact_match =
    $hwcdcHashes.installed_cpp_sha256 -ceq `
      $hwcdcHashes.canonical_cpp_sha256 -and
    $hwcdcHashes.installed_h_sha256 -ceq `
      $hwcdcHashes.canonical_h_sha256 -and
    $hwcdcHashes.installed_diagnostic_h_sha256 -ceq `
      $hwcdcHashes.canonical_diagnostic_h_sha256
  if (-not $hwcdcHashes.exact_match) {
    throw 'Installed ESP32 HWCDC does not match the pinned canonical patch'
  }

  $artifactId = (Get-Date).ToUniversalTime().ToString(
    'yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $runRoot = Join-Path $outputBaseFull $artifactId
  New-Item -ItemType Directory -Path $runRoot | Out-Null
  foreach ($directory in @('package', 'firmware', 'evidence')) {
    New-Item -ItemType Directory -Path (Join-Path $runRoot $directory) |
      Out-Null
  }

  $hwcdcSemanticContract = [pscustomobject][ordered]@{
    required = $false
    result = 'NOT_REQUIRED'
    summary = $null
    required_checks = @($script:R19CandidateHwcdcSemanticChecks)
    check_count = 0
  }
  $hwcdcSemanticSummarySha = ''
  if ($runtimeFailDiagnosticsEnabled) {
    $decoderEvidenceDir = Join-Path $runRoot 'evidence\tools'
    New-Item -ItemType Directory -Path $decoderEvidenceDir | Out-Null
    Copy-R19DurableFile (Join-Path $repo `
      'tools\read_r19_first_usb_failure_record.ps1') `
      (Join-Path $decoderEvidenceDir 'read_r19_first_usb_failure_record.ps1')
    if($timedPathEnabled){Copy-R19DurableFile (Join-Path $repo 'tools/read_r19_timed_path_record.ps1') (Join-Path $decoderEvidenceDir 'read_r19_timed_path_record.ps1')}
    if($auxReadinessEnabled){Copy-R19DurableFile (Join-Path $repo 'tools/read_r19_aux_readiness_record.ps1') (Join-Path $decoderEvidenceDir 'read_r19_aux_readiness_record.ps1')}
    if($diagnosticUsbFailureEnabled){
      Copy-R19DurableFile (Join-Path $repo 'tools/read_r19_diagnostic_usb_failure_record.ps1') (Join-Path $decoderEvidenceDir 'read_r19_diagnostic_usb_failure_record.ps1')
      Copy-R19DurableFile (Join-Path $repo 'tools/r19_usb_role_contract.ps1') (Join-Path $decoderEvidenceDir 'r19_usb_role_contract.ps1')
    }
    if($grantDiagnosticsEnabled){Copy-R19DurableFile (Join-Path $repo 'tools/read_r19_grant_diagnostic_record.ps1') (Join-Path $decoderEvidenceDir 'read_r19_grant_diagnostic_record.ps1')}
    if($grantReservationEnabled){foreach($tool in @('read_r19_grant_reservation_record.ps1','r19_grant_reservation_contract.ps1','r19_grant_reservation_wire.ps1','r19_grant_reservation_workflow.ps1')){Copy-R19DurableFile (Join-Path $repo ('tools/'+$tool)) (Join-Path $decoderEvidenceDir $tool)}}
    $hwcdcContractCheck = Join-Path $repo `
      'tests\arduino_compile\check_hwcdc_tx_integrity_contract.ps1'
    if (-not (Test-Path -LiteralPath $hwcdcContractCheck -PathType Leaf)) {
      throw "HWCDC semantic contract checker is missing: $hwcdcContractCheck"
    }
    $hwcdcContractOutput = Join-Path $runRoot `
      'evidence\hwcdc_semantic_contract'
    $contractArguments = @{
      ArduinoCli = $arduinoCliFile.FullName
      Fqbn = $Fqbn
      ExpectedCoreVersion = $ExpectedEsp32CoreVersion
      IdeConfig = $IdeConfig
      InstalledEsp32CoreRoot = $installedCore
      OutputDir = $hwcdcContractOutput
    }
    $contractText = @(& $hwcdcContractCheck @contractArguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw ("HWCDC semantic contract failed: " +
        ($contractText -join ' | '))
    }
    $hwcdcSummaryPath = Join-Path $hwcdcContractOutput 'summary.json'
    if (-not (Test-Path -LiteralPath $hwcdcSummaryPath -PathType Leaf)) {
      throw 'HWCDC semantic contract produced no summary'
    }
    $hwcdcSummary = Get-Content -LiteralPath $hwcdcSummaryPath -Raw |
      ConvertFrom-Json
    $semanticChecks = @(Assert-R19HwcdcSemanticSummary $hwcdcSummary `
      $hwcdcHashes $Fqbn $ExpectedEsp32CoreVersion)
    $hwcdcSummaryRecord = New-R19FileRecord $runRoot $hwcdcSummaryPath
    $hwcdcSemanticSummarySha = [string]$hwcdcSummaryRecord.sha256
    $hwcdcSemanticContract = [pscustomobject][ordered]@{
      required = $true
      result = 'PASS'
      summary = $hwcdcSummaryRecord
      required_checks = @($script:R19CandidateHwcdcSemanticChecks)
      check_count = $semanticChecks.Count
    }
  }

  $stagedRoles = @{}
  foreach ($role in $script:R19CandidateRoles) {
    $stagedRoles[$role.role] = Copy-CandidateRolePackage $role
  }
  $sourceAfterStage = Get-R19CandidateSourceSnapshot $repo $TimedPathMode $auxReadinessEnabled $diagnosticUsbFailureEnabled $grantDiagnosticsEnabled $grantReservationEnabled
  Assert-R19SameSnapshot $sourceBefore $sourceAfterStage `
    'Canonical R19 candidate source after staging'
  [void](Assert-Preservation $preservationBefore 'candidate staging')

  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('vc_lora_r19_candidate_artifact_' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  $roleManifestRecords = [Collections.Generic.List[object]]::new()
  $extraFlags = '-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1'
  if ($runtimeFailDiagnosticsEnabled) {
    $extraFlags += ' -DVC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS=1'
  }
  if($timedPathEnabled){$extraFlags+=" -DVC_LORA_R19_TIMED_PATH_DIAGNOSTICS=1 -DVC_LORA_R19_USB_READINESS_MODE=$($timedPathContract.mode_value)"}
  if($auxReadinessEnabled){$extraFlags+=' -DVC_LORA_R19_AUX_READINESS_DIAGNOSTICS=1'}
  if($diagnosticUsbFailureEnabled){$extraFlags+=' -DVC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD=1'}
  if($grantDiagnosticsEnabled){$extraFlags+=' -DVC_LORA_R19_GRANT_DIAGNOSTICS=1'}
  if($grantReservationEnabled){$extraFlags+=' -DVC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS=1'}
  $compileProperty = "compiler.cpp.extra_flags=$extraFlags"
  foreach ($role in $script:R19CandidateRoles) {
    $buildPath = Join-Path (Join-Path $tempRoot 'build') $role.role
    $outputPath = Join-Path (Join-Path $tempRoot 'output') $role.role
    New-Item -ItemType Directory -Path $buildPath, $outputPath -Force |
      Out-Null
    $compileArguments = @($globalArgs) + @(
      'compile', '--fqbn', $Fqbn, '--warnings', 'all', '--clean',
      '--build-path', $buildPath, '--output-dir', $outputPath,
      '--build-property', $compileProperty,
      '--json', [string]$stagedRoles[$role.role]
    )
    $compileText = (& $arduinoCliFile.FullName @compileArguments 2>&1) -join `
      "`n"
    $compileExit = $LASTEXITCODE
    try {
      $compileResult = $compileText | ConvertFrom-Json
    } catch {
      throw "$($role.name) compile returned invalid JSON: $compileText"
    }
    if ($compileExit -ne 0 -or -not [bool]$compileResult.success) {
      throw "$($role.name) R19 candidate compile failed: $compileText"
    }
    $applicationFileName = $role.sketch + '.ino.bin'
    $outputBinary = Join-Path $outputPath $applicationFileName
    $buildBinary = Join-Path $buildPath $applicationFileName
    if (-not (Test-Path -LiteralPath $outputBinary -PathType Leaf) -or
        -not (Test-Path -LiteralPath $buildBinary -PathType Leaf)) {
      throw ("$($role.name) compile did not produce the application binary " +
        'in both build-path and output-dir')
    }
    $buildBinaryRecord = New-ApplicationOriginRecord 'build-path' $buildBinary
    $outputBinaryRecord = New-ApplicationOriginRecord 'output-dir' $outputBinary
    if ([int64]$buildBinaryRecord.size_bytes -ne
          [int64]$outputBinaryRecord.size_bytes -or
        [string]$buildBinaryRecord.sha256 -cne
          [string]$outputBinaryRecord.sha256) {
      throw ("$($role.name) build-path/output-dir application binary " +
        'mismatch')
    }
    $applicationFlashLayout = Get-R19ApplicationFlashLayout $role.name `
      $applicationFileName (Join-Path $buildPath 'flash_args') `
      (Join-Path $buildPath 'partitions.csv')
    $publishedBinary = Join-Path (Join-Path $runRoot 'firmware') `
      ($role.role + '.application.bin')
    Copy-R19DurableFile $outputBinary $publishedBinary
    $applicationRecord = New-R19FileRecord $runRoot $publishedBinary
    $applicationBinaryProvenance = [pscustomobject][ordered]@{
      schema = 'vc-lora-r19-application-binary-provenance-v1'
      exact_match = $true
      build_path = $buildBinaryRecord
      output_dir = $outputBinaryRecord
      published = $applicationRecord
    }
    $reproducibilityArtifacts = Publish-ReproducibilityArtifacts $role `
      $buildPath
    $compileRecord = Write-CompileEvidence $role $compileArguments `
      $compileExit $compileResult $applicationRecord `
      $applicationBinaryProvenance $applicationFlashLayout
    Remove-StagedCompilerExports $stagedRoles[$role.role] $role.name
    $roleManifestRecord = [pscustomobject][ordered]@{
      role = $role.role
      name = $role.name
      role_macro = $role.role_macro
      source_sketch = Get-R19RelativePath $repo `
        (Join-Path (Join-Path $repo $role.sketch) ($role.sketch + '.ino'))
      staged_sketch = Get-R19RelativePath $runRoot `
        (Join-Path $stagedRoles[$role.role] ($role.sketch + '.ino'))
      compile = $compileRecord
      application = $applicationRecord
      application_binary_provenance = $applicationBinaryProvenance
      application_flash_layout = $applicationFlashLayout
      reproducibility_artifacts = $reproducibilityArtifacts
    }
    if ($runtimeFailDiagnosticsEnabled) {
      $symbolBinding = Get-R19DiagnosticSymbolBinding `
        (Join-Path $runRoot "evidence\build\$($role.role)\application.elf") `
        (Join-Path $runRoot "evidence\build\$($role.role)\application.map") `
        ([string]$applicationRecord.sha256) $true $timedPathEnabled $auxReadinessEnabled $diagnosticUsbFailureEnabled $grantDiagnosticsEnabled $grantReservationEnabled
      Add-Member -InputObject $roleManifestRecord -NotePropertyName `
        'runtime_diagnostic_symbols' -NotePropertyValue $symbolBinding
    }
    $roleManifestRecords.Add($roleManifestRecord)
    $sourceNow = Get-R19CandidateSourceSnapshot $repo $TimedPathMode $auxReadinessEnabled $diagnosticUsbFailureEnabled $grantDiagnosticsEnabled $grantReservationEnabled
    Assert-R19SameSnapshot $sourceBefore $sourceNow `
      "Canonical source after $($role.name) compile"
    [void](Assert-Preservation $preservationBefore `
      "$($role.name) candidate compile")
  }

  $preservationAfter = Assert-Preservation $preservationBefore `
    'candidate build completion'
  $sourceAfter = Get-R19CandidateSourceSnapshot $repo $TimedPathMode $auxReadinessEnabled $diagnosticUsbFailureEnabled $grantDiagnosticsEnabled $grantReservationEnabled
  Assert-R19SameSnapshot $sourceBefore $sourceAfter `
    'Canonical source at candidate build completion'

  $packageSnapshot = Get-R19TreeSnapshot $runRoot @(
    (Join-Path $runRoot 'package'))
  $candidateHeaderRecords = @($sourceBefore.records | Where-Object {
      $_.path -like 'firmware/high_speed/*.hpp'
    })
  $candidateHeaderTree = Get-R19CanonicalTreeHash $candidateHeaderRecords
  $manifest = [pscustomobject][ordered]@{
    schema = $script:R19CandidateArtifactSchema
    test_id = $script:R19CandidateTestId
    artifact_id = $artifactId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    result = 'PASS'
    runtime_fail_diagnostics_enabled = $runtimeFailDiagnosticsEnabled
    acceptance_eligible = $acceptanceEligible
    acceptance_authorized = $acceptanceAuthorized
    deployment_authorized = $deploymentAuthorized
    artifact_root = Get-R19RelativePath $repo $runRoot
    hardware_interaction = [pscustomobject][ordered]@{
      performed = $false
      com_ports_opened = @()
      upload_performed = $false
      flash_performed = $false
    }
    deployment = [pscustomobject][ordered]@{
      authorized = $false
      physical_30s_proven = $false
    }
    toolchain = [pscustomobject][ordered]@{
      fqbn = $Fqbn
      arduino_cli = [pscustomobject][ordered]@{
        version = [string]$cliVersion.VersionString
        path = $arduinoCliFile.FullName
        sha256 = $arduinoCliSha
      }
      esp32_core = [pscustomobject][ordered]@{
        version = [string]$board.version
        installed_root = $installedCore
      }
      ide_config = $ideConfigRecord
      hwcdc = $hwcdcHashes
    }
    hwcdc_semantic_contract = $hwcdcSemanticContract
    candidate_enable = [pscustomobject][ordered]@{
      macro = 'VC_LORA_R19_HIGH_SPEED_CANDIDATE'
      value = 1
      compile_flag = '-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1'
      property = $compileProperty
      bridge_default = 0
      mechanism = 'arduino-cli-build-property'
    }
    compile_order = @($script:R19CandidateRoles | ForEach-Object {
        $_.role
      })
    flash_policy = [pscustomobject][ordered]@{
      mode = 'app-only'
      app_only = $true
      offset = '0x10000'
      upload_order = @('vehicle', 'ground')
      erase_flash = $false
      write_bootloader = $false
      write_partition_table = $false
      write_merged_image = $false
    }
    candidate_package = [pscustomobject][ordered]@{
      header_count = $script:R19CandidateHeaderNames.Count + $(if($timedPathEnabled){1}else{0}) + $(if($auxReadinessEnabled){1}else{0}) + $(if($diagnosticUsbFailureEnabled){1}else{0}) + $(if([bool](Get-Variable -Name grantDiagnosticsEnabled -ValueOnly -ErrorAction SilentlyContinue)){1}else{0}) + $(if($grantReservationEnabled){2}else{0})
      header_names = @($script:R19CandidateHeaderNames)+@(if($timedPathEnabled){'r19_timed_path_record.hpp'})+@(if($auxReadinessEnabled){'r19_aux_readiness_record.hpp'})+@(if($diagnosticUsbFailureEnabled){'r19_diagnostic_usb_failure_record.hpp'})+@(if($grantDiagnosticsEnabled){'r19_grant_diagnostic_record.hpp'})+@(if($grantReservationEnabled){'r19_grant_reservation.hpp';'r19_grant_reservation_record.hpp'})
      canonical_tree_sha256 = $candidateHeaderTree
      files = $candidateHeaderRecords
    }
    canonical_source_snapshot = [pscustomobject][ordered]@{
      file_count = $sourceBefore.file_count
      tree_sha256 = $sourceBefore.tree_sha256
      files = @($sourceBefore.records)
    }
    staged_package_snapshot = [pscustomobject][ordered]@{
      file_count = $packageSnapshot.file_count
      tree_sha256 = $packageSnapshot.tree_sha256
      files = @($packageSnapshot.records)
    }
    roles = @($roleManifestRecords)
    preservation = [pscustomobject][ordered]@{
      default_sketches_before = [pscustomobject][ordered]@{
        file_count = $preservationBefore.default_sketches.file_count
        tree_sha256 = $preservationBefore.default_sketches.tree_sha256
      }
      default_sketches_after = [pscustomobject][ordered]@{
        file_count = $preservationAfter.default_sketches.file_count
        tree_sha256 = $preservationAfter.default_sketches.tree_sha256
      }
      standard_artifacts_before = [pscustomobject][ordered]@{
        file_count = $preservationBefore.standard_artifacts.file_count
        tree_sha256 = $preservationBefore.standard_artifacts.tree_sha256
      }
      standard_artifacts_after = [pscustomobject][ordered]@{
        file_count = $preservationAfter.standard_artifacts.file_count
        tree_sha256 = $preservationAfter.standard_artifacts.tree_sha256
      }
      unchanged = $true
    }
  }
  Add-DiagnosticAbiMetadata $manifest

  $manifestPath = Join-Path $runRoot 'candidate_manifest.json'
  Write-R19DurableJson $manifestPath $manifest
  $manifestSha = Get-R19Sha256 $manifestPath

  $inventoryFiles = @(Get-ChildItem -LiteralPath $runRoot -Recurse -File |
    Sort-Object FullName)
  $inventoryRecordsUnordered = @($inventoryFiles | ForEach-Object {
      New-R19FileRecord $runRoot $_.FullName
    })
  $inventoryRecords = @(
    Get-R19OrdinalPathRecords $inventoryRecordsUnordered)
  $inventory = [pscustomobject][ordered]@{
    schema = $script:R19CandidateArtifactInventorySchema
    result = 'PASS'
    runtime_fail_diagnostics_enabled = $runtimeFailDiagnosticsEnabled
    acceptance_eligible = $acceptanceEligible
    acceptance_authorized = $acceptanceAuthorized
    deployment_authorized = $deploymentAuthorized
    artifact_id = $artifactId
    coverage = 'all immutable build files present before inventory and seal'
    file_count = $inventoryRecords.Count
    tree_sha256 = Get-R19CanonicalTreeHash $inventoryRecords
    files = $inventoryRecords
  }
  $inventoryPath = Join-Path $runRoot 'artifact_manifest.json'
  if($timedPathEnabled){Add-Member -InputObject $inventory -NotePropertyName timed_path_diagnostics -NotePropertyValue $timedPathContract}
  if($auxReadinessEnabled){Add-Member -InputObject $inventory -NotePropertyName aux_readiness_diagnostics -NotePropertyValue $auxReadinessContract}
  Add-OptionalUsbFailureMetadata $inventory
  Write-R19DurableJson $inventoryPath $inventory
  $inventorySha = Get-R19Sha256 $inventoryPath

  $sumLines = @($inventoryRecords | ForEach-Object {
      "$($_.sha256) *$($_.path)"
    })
  $sumsPath = Join-Path $runRoot 'SHA256SUMS.txt'
  Write-R19DurableText $sumsPath (($sumLines -join "`n") + "`n")
  $sumsSha = Get-R19Sha256 $sumsPath

  $vehicleRole = @($roleManifestRecords | Where-Object {
      $_.role -ceq 'vehicle'
    })[0]
  $groundRole = @($roleManifestRecords | Where-Object {
      $_.role -ceq 'ground'
    })[0]
  $seal = [pscustomobject][ordered]@{
    schema = $script:R19CandidateSealSchema
    artifact_id = $artifactId
    result = 'PASS'
    runtime_fail_diagnostics_enabled = $runtimeFailDiagnosticsEnabled
    acceptance_eligible = $acceptanceEligible
    acceptance_authorized = $acceptanceAuthorized
    candidate_manifest_sha256 = $manifestSha
    artifact_manifest_sha256 = $inventorySha
    sha256s_sha256 = $sumsSha
    canonical_source_tree_sha256 = $sourceBefore.tree_sha256
    staged_package_tree_sha256 = $packageSnapshot.tree_sha256
    vehicle_application_sha256 = $vehicleRole.application.sha256
    ground_application_sha256 = $groundRole.application.sha256
    hwcdc_semantic_contract_required = $runtimeFailDiagnosticsEnabled
    hwcdc_semantic_summary_sha256 = $hwcdcSemanticSummarySha
    deployment_authorized = $deploymentAuthorized
    hardware_interaction = $false
  }
  Add-DiagnosticAbiMetadata $seal
  if ($runtimeFailDiagnosticsEnabled) {
    Add-Member -InputObject $seal -NotePropertyName 'roles' `
      -NotePropertyValue @($roleManifestRecords | ForEach-Object {
        [pscustomobject][ordered]@{
          role = $_.role
          runtime_diagnostic_symbols = $_.runtime_diagnostic_symbols
        }
      })
  }
  $sealPath = Join-Path $runRoot 'final_seal.json'
  Write-R19DurableJson $sealPath $seal
  $sealSha = Get-R19Sha256 $sealPath
  Write-R19DurableText (Join-Path $runRoot 'final_seal.sha256') `
    "$sealSha *final_seal.json`n"

  $handoff = [pscustomobject][ordered]@{
    schema = $script:R19CandidateHandoffSchema
    artifact_id = $artifactId
    result = 'PASS'
    runtime_fail_diagnostics_enabled = $runtimeFailDiagnosticsEnabled
    acceptance_eligible = $acceptanceEligible
    acceptance_authorized = $acceptanceAuthorized
    deployment_authorized = $deploymentAuthorized
    artifact_root = Get-R19RelativePath $repo $runRoot
    candidate_manifest = [pscustomobject][ordered]@{
      path = Get-R19RelativePath $repo $manifestPath
      sha256 = $manifestSha
    }
    final_seal = [pscustomobject][ordered]@{
      path = Get-R19RelativePath $repo $sealPath
      sha256 = $sealSha
    }
    roles = @(
      [pscustomobject][ordered]@{
        role = 'vehicle'
        application = [pscustomobject][ordered]@{
          path = Get-R19RelativePath $repo `
            (Join-Path $runRoot $vehicleRole.application.path)
          size_bytes = $vehicleRole.application.size_bytes
          sha256 = $vehicleRole.application.sha256
        }
      },
      [pscustomobject][ordered]@{
        role = 'ground'
        application = [pscustomobject][ordered]@{
          path = Get-R19RelativePath $repo `
            (Join-Path $runRoot $groundRole.application.path)
          size_bytes = $groundRole.application.size_bytes
          sha256 = $groundRole.application.sha256
        }
      }
    )
    flash_policy = $manifest.flash_policy
    candidate_enable = $manifest.candidate_enable
  }
  Add-DiagnosticAbiMetadata $handoff
  if ($runtimeFailDiagnosticsEnabled) {
    for ($roleIndex = 0; $roleIndex -lt 2; $roleIndex++) {
      Add-Member -InputObject $handoff.roles[$roleIndex] -NotePropertyName `
        'runtime_diagnostic_symbols' -NotePropertyValue `
        $roleManifestRecords[$roleIndex].runtime_diagnostic_symbols
    }
  }
  $handoffPath = Join-Path $runRoot 'handoff.json'
  Write-R19DurableJson $handoffPath $handoff
  $handoffSha = Get-R19Sha256 $handoffPath
  Write-R19DurableText (Join-Path $runRoot 'handoff.sha256') `
    "$handoffSha *handoff.json`n"

  $latest = [pscustomobject][ordered]@{
    schema = $script:R19CandidateLatestSchema
    result = 'PASS'
    runtime_fail_diagnostics_enabled = $runtimeFailDiagnosticsEnabled
    acceptance_eligible = $acceptanceEligible
    acceptance_authorized = $acceptanceAuthorized
    deployment_authorized = $deploymentAuthorized
    published_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    artifact_id = $artifactId
    artifact_root = Get-R19RelativePath $repo $runRoot
    handoff = [pscustomobject][ordered]@{
      path = Get-R19RelativePath $repo $handoffPath
      sha256 = $handoffSha
    }
    candidate_manifest = [pscustomobject][ordered]@{
      path = Get-R19RelativePath $repo $manifestPath
      sha256 = $manifestSha
    }
    final_seal = [pscustomobject][ordered]@{
      path = Get-R19RelativePath $repo $sealPath
      sha256 = $sealSha
    }
    previous_latest_sha256 = ''
  }

  $verifier = Join-Path $repo 'tools\verify_r19_candidate_artifact.ps1'
  if($timedPathEnabled){Add-Member -InputObject $latest -NotePropertyName timed_path_diagnostics -NotePropertyValue $timedPathContract}
  if($auxReadinessEnabled){Add-Member -InputObject $latest -NotePropertyName aux_readiness_diagnostics -NotePropertyValue $auxReadinessContract}
  Add-OptionalUsbFailureMetadata $latest
  $verifyModeArguments = @{}
  if ($runtimeFailDiagnosticsEnabled) {
    $verifyModeArguments.RuntimeFailDiagnostics = $true
  }
  if($timedPathEnabled){$verifyModeArguments.TimedPathMode=$TimedPathMode}
  if($auxReadinessEnabled){$verifyModeArguments.AuxReadinessDiagnostics=$true}
  if($diagnosticUsbFailureEnabled){$verifyModeArguments.DiagnosticUsbFailureDiagnostics=$true}
  if($grantDiagnosticsEnabled){$verifyModeArguments.GrantDiagnostics=$true}
  if($grantReservationEnabled){$verifyModeArguments.GrantReservationDiagnostics=$true}
  & $verifier -RepoRoot $repo -ArtifactRoot $runRoot @verifyModeArguments |
    Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'R19 candidate verifier rejected the unpublished artifact'
  }
  $latestSha = Publish-LatestPointer $latest
  $latestPublished = $true

  & $verifier -RepoRoot $repo `
    -LatestPath (Join-Path $outputBaseFull 'latest.json') `
    -ExpectedLatestSha256 $latestSha @verifyModeArguments | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'R19 candidate verifier returned a non-zero exit code'
  }

  Write-Output ("$($script:R19CandidateTestId) PASS " +
    "artifact_id=$artifactId latest_sha256=$latestSha " +
    "runtime_fail_diagnostics_enabled=$runtimeFailDiagnosticsEnabled")
  Write-Output "artifact_root=$runRoot"
  Write-Output "candidate_manifest=$manifestPath"
  Write-Output "candidate_manifest_sha256=$manifestSha"
  Write-Output "handoff=$handoffPath"
  Write-Output "handoff_sha256=$handoffSha"
  Write-Output "final_seal=$sealPath"
  Write-Output "final_seal_sha256=$sealSha"
  Write-Output ("vehicle_application_sha256=" +
    [string]$vehicleRole.application.sha256)
  Write-Output ("ground_application_sha256=" +
    [string]$groundRole.application.sha256)
} catch {
  if ($null -ne $runRoot -and -not $latestPublished -and
      (Test-Path -LiteralPath $runRoot -PathType Container)) {
    $failurePath = Join-Path $runRoot 'BUILD_FAILED.txt'
    if (-not (Test-Path -LiteralPath $failurePath)) {
      try {
        Write-R19DurableText $failurePath ($_.Exception.Message + "`n")
      } catch {
        # Preserve the original build failure.
      }
    }
  }
  throw
} finally {
  if ($null -ne $tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
    $resolvedTemp = (Resolve-Path -LiteralPath $tempRoot).Path
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
      [IO.Path]::DirectorySeparatorChar,
      [IO.Path]::AltDirectorySeparatorChar)
    $expectedPrefix = $tempBase + [IO.Path]::DirectorySeparatorChar +
      'vc_lora_r19_candidate_artifact_'
    if (-not $resolvedTemp.StartsWith(
        $expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove unsafe candidate temp path: $resolvedTemp"
    }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
  if ($null -ne $publishLock) {
    $publishLock.Dispose()
  }
}
