[CmdletBinding()]
param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ArtifactRoot = '',
  [string]$ManifestPath = '',
  [string]$HandoffPath = '',
  [string]$LatestPath = '',
  [string]$ExpectedLatestSha256 = '',
  [switch]$RuntimeFailDiagnostics,
  [ValidateSet('Disabled','SyncOnly','ExplicitHostArm')][string]$TimedPathMode='Disabled',
  [switch]$AuxReadinessDiagnostics,
  [switch]$DiagnosticUsbFailureDiagnostics
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'r19_candidate_artifact_common.ps1')

$repo = Resolve-R19RepositoryRoot $RepoRoot
$runtimeFailDiagnosticsEnabled = $RuntimeFailDiagnostics.IsPresent
$acceptanceEligible = -not $runtimeFailDiagnosticsEnabled
$auxReadinessEnabled=$AuxReadinessDiagnostics.IsPresent
$diagnosticUsbFailureEnabled=$DiagnosticUsbFailureDiagnostics.IsPresent
$outputLeaf = Get-R19CandidateOutputLeaf $runtimeFailDiagnosticsEnabled $TimedPathMode $auxReadinessEnabled $diagnosticUsbFailureEnabled
$timedPathEnabled=$TimedPathMode-cne'Disabled'
$timedPathContract=Get-R19TimedPathCandidateContract $repo $TimedPathMode
$auxReadinessContract=Get-R19AuxReadinessCandidateContract $repo $auxReadinessEnabled
$diagnosticUsbFailureContract=Get-R19DiagnosticUsbFailureCandidateContract $repo $diagnosticUsbFailureEnabled
$usbRoleCapabilities=$null
if($diagnosticUsbFailureEnabled){$usbRoleCapabilities=Get-R19UsbRoleCapabilities -RepoRoot $repo -Mode $TimedPathMode -Enabled $true}
$outputBase = Join-Path $repo `
  (Join-Path 'runs\candidates' $outputLeaf)
$selectors = @($ArtifactRoot, $ManifestPath, $HandoffPath, $LatestPath) |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
if (@($selectors).Count -gt 1) {
  throw 'Specify only one of ArtifactRoot, ManifestPath, HandoffPath, LatestPath'
}
if (@($selectors).Count -eq 0) {
  $LatestPath = Join-Path $outputBase 'latest.json'
}

function Assert-Condition([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Hash([string]$Actual, [string]$Description) {
  Assert-Condition ($Actual -cmatch '^[0-9A-F]{64}$') `
    "$Description is not a canonical SHA-256"
}

function Assert-ModeContract([object]$Record, [string]$Description) {
  # Definitions-only legacy fixtures have no opt-in variable. Its absence is
  # versioned legacy false, never implicit authorization for the new feature.
  $requireDiagnosticUsbFailure=[bool](Get-Variable -Name diagnosticUsbFailureEnabled -ValueOnly -ErrorAction SilentlyContinue)
  if($requireDiagnosticUsbFailure){
    Assert-Condition ($null-ne$Record.PSObject.Properties['diagnostic_usb_failure_diagnostics']-and
      ($Record.diagnostic_usb_failure_diagnostics|ConvertTo-Json -Depth 15 -Compress)-ceq($diagnosticUsbFailureContract|ConvertTo-Json -Depth 15 -Compress)) "$Description diagnostic USB failure ABI/decoder binding mismatch"
    Assert-Condition ($null-ne$Record.PSObject.Properties['usb_role_capabilities']-and
      ($Record.usb_role_capabilities|ConvertTo-Json -Depth 15 -Compress)-ceq($usbRoleCapabilities|ConvertTo-Json -Depth 15 -Compress)) "$Description USB role capability/source binding mismatch"
    Assert-R19UsbRoleCapabilities -Contract $Record.usb_role_capabilities -RepoRoot $repo -Mode $TimedPathMode
  }else{
    Assert-Condition ($null-eq$Record.PSObject.Properties['diagnostic_usb_failure_diagnostics']-and$null-eq$Record.PSObject.Properties['usb_role_capabilities']) "$Description contains undeclared diagnostic USB failure/role capability metadata"
  }
  if($auxReadinessEnabled){
    Assert-Condition ($null-ne$Record.PSObject.Properties['aux_readiness_diagnostics']-and
      ($Record.aux_readiness_diagnostics|ConvertTo-Json -Depth 12 -Compress)-ceq($auxReadinessContract|ConvertTo-Json -Depth 12 -Compress)) "$Description AUX readiness mode/ABI/decoder binding mismatch"
  }else{Assert-Condition ($null-eq$Record.PSObject.Properties['aux_readiness_diagnostics']) "$Description contains undeclared AUX readiness diagnostics"}
  if($timedPathEnabled){
    Assert-Condition ($null-ne$Record.PSObject.Properties['timed_path_diagnostics']-and
      ($Record.timed_path_diagnostics|ConvertTo-Json -Depth 12 -Compress)-ceq($timedPathContract|ConvertTo-Json -Depth 12 -Compress)) "$Description timed path mode/ABI/decoder binding mismatch"
  }else{Assert-Condition ($null-eq$Record.PSObject.Properties['timed_path_diagnostics']) "$Description contains undeclared timed path diagnostics"}
  Assert-Condition ($null -ne $Record -and
      $Record.PSObject.Properties['runtime_fail_diagnostics_enabled'] -and
      $Record.runtime_fail_diagnostics_enabled -is [bool] -and
      [bool]$Record.runtime_fail_diagnostics_enabled -eq
        $runtimeFailDiagnosticsEnabled) `
    "$Description runtime_fail_diagnostics_enabled is absent or invalid"
  Assert-Condition ($Record.PSObject.Properties['acceptance_authorized'] -and
      $Record.acceptance_authorized -is [bool] -and
      -not [bool]$Record.acceptance_authorized) `
    "$Description acceptance_authorized is absent or invalid"
  Assert-Condition ($Record.PSObject.Properties['acceptance_eligible'] -and
      $Record.acceptance_eligible -is [bool] -and
      [bool]$Record.acceptance_eligible -eq $acceptanceEligible) `
    "$Description acceptance_eligible is absent or invalid"
  Assert-Condition ($Record.PSObject.Properties['deployment_authorized'] -and
      $Record.deployment_authorized -is [bool] -and
      -not [bool]$Record.deployment_authorized) `
    "$Description deployment_authorized is absent or invalid"
}

function Assert-DiagnosticAbiContract([object]$Record,
                                      [string]$Description) {
  if (-not $runtimeFailDiagnosticsEnabled) {
    return
  }
  $expectedNumericFields = [ordered]@{
    endpoint_fifo_schema = 2
    endpoint_fifo_size_bytes = 112
    runtime_stage_size_bytes = 68
  }
  [Type[]]$integralTypes = @(
    [byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
  foreach ($entry in $expectedNumericFields.GetEnumerator()) {
    $property = $Record.PSObject.Properties[[string]$entry.Key]
    Assert-Condition ($null -ne $property -and
        $property.Name -ceq [string]$entry.Key -and
        $null -ne $property.Value -and
        $integralTypes -contains $property.Value.GetType() -and
        [int64]$property.Value -eq [int64]$entry.Value) `
      "$Description diagnostic ABI field is absent or invalid: $($entry.Key)"
  }
  $readerProperty = $Record.PSObject.Properties['reader_schema']
  Assert-Condition ($null -ne $readerProperty -and
      $readerProperty.Name -ceq 'reader_schema' -and
      $readerProperty.Value -is [string] -and
      [string]$readerProperty.Value -cin @(
        'vc-lora-r19-runtime-stage-jtag-read-v3',
        'vc-lora-r19-runtime-stage-jtag-read-v4',
        'vc-lora-r19-runtime-stage-jtag-read-v5',
        'vc-lora-r19-runtime-stage-jtag-read-v7',
        'vc-lora-r19-runtime-stage-jtag-read-v8')) `
    "$Description diagnostic ABI field is absent or invalid: reader_schema"
  $extension = $Record.PSObject.Properties['usb_extended_diagnostics']
  $decoder = $Record.PSObject.Properties['first_usb_failure_decoder']
  if ([string]$readerProperty.Value -ceq
      'vc-lora-r19-runtime-stage-jtag-read-v3') {
    Assert-Condition ($null -eq $extension -and $null -eq $decoder) `
      "$Description reader-v3 contains undeclared diagnostic extensions"
    return
  }
  Assert-Condition (($diagnosticUsbFailureEnabled-and$readerProperty.Value-ceq'vc-lora-r19-runtime-stage-jtag-read-v8')-or
    (-not$diagnosticUsbFailureEnabled-and$auxReadinessEnabled-and$readerProperty.Value-ceq'vc-lora-r19-runtime-stage-jtag-read-v7')-or
    (-not$diagnosticUsbFailureEnabled-and-not$auxReadinessEnabled-and$readerProperty.Value-cnotin@('vc-lora-r19-runtime-stage-jtag-read-v7','vc-lora-r19-runtime-stage-jtag-read-v8'))) "$Description AUX/diagnostic USB reader v7/v8 declaration mismatch"
  $firstFailure = [string]$readerProperty.Value -cin @(
    'vc-lora-r19-runtime-stage-jtag-read-v5','vc-lora-r19-runtime-stage-jtag-read-v7','vc-lora-r19-runtime-stage-jtag-read-v8')
  Assert-Condition ($null -ne $extension -and
      $extension.Name -ceq 'usb_extended_diagnostics' -and
      ($extension.Value | ConvertTo-Json -Depth 12 -Compress) -ceq
      ((Get-R19DiagnosticExtensionContract $firstFailure) |
        ConvertTo-Json -Depth 12 -Compress)) `
    "$Description usb_extended_diagnostics contract is absent or invalid"
  if ($firstFailure) {
    Assert-Condition ($null -ne $decoder -and
        $decoder.Name -ceq 'first_usb_failure_decoder' -and
        ($decoder.Value | ConvertTo-Json -Depth 4 -Compress) -ceq
        ((Get-R19FirstFailureDecoderBinding $repo) |
          ConvertTo-Json -Depth 4 -Compress)) `
      "$Description first_usb_failure_decoder binding is absent or invalid"
  } else {
    Assert-Condition ($null -eq $decoder) `
      "$Description reader-v4 contains undeclared first_usb_failure_decoder"
  }
}

function Resolve-RepoOutputPath([string]$RelativePath,
                                [string]$Description) {
  Assert-Condition ($RelativePath -cmatch '^[^\\/]+(?:/[^\\/]+)*$') `
    "$Description is not a canonical repository-relative path"
  $segments = @($RelativePath -split '/')
  Assert-Condition (@($segments | Where-Object { $_ -in @('.', '..', '') }).Count `
      -eq 0) "$Description contains a prohibited path segment"
  $candidate = Join-Path $repo ($RelativePath.Replace('/', '\'))
  [void](Assert-R19PathWithin $outputBase $candidate $Description)
  return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
}

function Assert-FileRecord([object]$Record, [string]$Root,
                           [string]$Description) {
  Assert-Condition ($null -ne $Record) "$Description is absent"
  Assert-Hash ([string]$Record.sha256) "$Description SHA-256"
  $relative = [string]$Record.path
  Assert-Condition ($relative -cmatch '^[^\\/]+(?:/[^\\/]+)*$') `
    "$Description path is not canonical"
  $segments = @($relative -split '/')
  Assert-Condition (@($segments | Where-Object { $_ -in @('.', '..', '') }).Count `
      -eq 0) "$Description contains a prohibited path segment"
  [int64]$recordedSize = 0
  $sizeValid = [int64]::TryParse([string]$Record.size_bytes,
    [ref]$recordedSize)
  Assert-Condition ($sizeValid -and $recordedSize -ge 0) `
    "$Description size is invalid"
  $path = Join-Path $Root $relative.Replace('/', '\')
  [void](Assert-R19PathWithin $Root $path $Description)
  $file = Get-Item -LiteralPath $path -ErrorAction Stop
  Assert-Condition (-not $file.PSIsContainer) "$Description is not a file"
  Assert-Condition ($file.Length -eq $recordedSize) `
    "$Description size mismatch"
  Assert-Condition ((Get-R19Sha256 $file.FullName) -ceq
      [string]$Record.sha256) "$Description SHA-256 mismatch"
  return $file.FullName
}

function Assert-RecordTree([object]$Snapshot, [string]$Root,
                           [string]$Description, [bool]$VerifyFiles) {
  $records = @($Snapshot.files)
  Assert-Condition ($records.Count -eq [int]$Snapshot.file_count) `
    "$Description file count mismatch"
  $paths = @($records | ForEach-Object { [string]$_.path })
  Assert-Condition (@($paths | Sort-Object -Unique).Count -eq $paths.Count) `
    "$Description contains duplicate paths"
  foreach ($record in $records) {
    Assert-Hash ([string]$record.sha256) "$Description record SHA-256"
    if ($VerifyFiles) {
      [void](Assert-FileRecord $record $Root `
        "$Description file $($record.path)")
    }
  }
  $tree = Get-R19CanonicalTreeHash $records
  Assert-Condition ($tree -ceq [string]$Snapshot.tree_sha256) `
    "$Description tree SHA-256 mismatch"
  return $records
}

function Assert-HandoffIdentity([object]$Value) {
  Assert-Condition ([string]$Value.schema -ceq
      $script:R19CandidateHandoffSchema) 'Unsupported candidate handoff schema'
  Assert-Condition ([string]$Value.result -ceq 'PASS') `
    'Candidate handoff is not PASS'
  Assert-ModeContract $Value 'Candidate handoff'
  Assert-DiagnosticAbiContract $Value 'Candidate handoff'
}

$latestStartSha = ''
$latest = $null
$handoff = $null
$handoffSha = ''

if (-not [string]::IsNullOrWhiteSpace($LatestPath)) {
  $expectedLatestPath = [IO.Path]::GetFullPath(
    (Join-Path $outputBase 'latest.json'))
  $latestFile = Get-Item -LiteralPath $LatestPath -ErrorAction Stop
  Assert-Condition ($latestFile.FullName -ceq $expectedLatestPath) `
    "Unexpected R19 latest pointer path: $($latestFile.FullName)"
  $latestHashPath = Join-Path $outputBase 'latest.sha256'
  $latestStartSha = Get-R19Sha256 $latestFile.FullName
  Assert-Condition ((Read-R19HashFile $latestHashPath 'latest.json') -ceq
      $latestStartSha) 'R19 latest pointer hash mismatch'
  if (-not [string]::IsNullOrWhiteSpace($ExpectedLatestSha256)) {
    Assert-Hash $ExpectedLatestSha256 'Expected latest SHA-256'
    Assert-Condition ($latestStartSha -ceq
        $ExpectedLatestSha256.ToUpperInvariant()) `
      'R19 latest pointer changed from the caller-pinned value'
  }
  $latest = Get-Content -LiteralPath $latestFile.FullName -Raw |
    ConvertFrom-Json
  Assert-Condition ([string]$latest.schema -ceq
      $script:R19CandidateLatestSchema) 'Unsupported R19 latest schema'
  Assert-Condition ([string]$latest.result -ceq 'PASS') `
    'R19 latest pointer is not PASS'
  Assert-ModeContract $latest 'R19 latest pointer'
  $HandoffPath = Resolve-RepoOutputPath ([string]$latest.handoff.path) `
    'Latest handoff path'
  Assert-Condition ((Get-R19Sha256 $HandoffPath) -ceq
      [string]$latest.handoff.sha256) 'Latest handoff hash mismatch'
}

if (-not [string]::IsNullOrWhiteSpace($HandoffPath)) {
  $handoffFile = Get-Item -LiteralPath $HandoffPath -ErrorAction Stop
  [void](Assert-R19PathWithin $outputBase $handoffFile.FullName `
    'Candidate handoff')
  Assert-Condition ($handoffFile.Name -ceq 'handoff.json') `
    'Candidate handoff filename is invalid'
  $handoffHashPath = Join-Path $handoffFile.DirectoryName 'handoff.sha256'
  $handoffSha = Get-R19Sha256 $handoffFile.FullName
  Assert-Condition ((Read-R19HashFile $handoffHashPath 'handoff.json') -ceq
      $handoffSha) 'Candidate handoff companion hash mismatch'
  $handoff = Get-Content -LiteralPath $handoffFile.FullName -Raw |
    ConvertFrom-Json
  Assert-HandoffIdentity $handoff
  $ArtifactRoot = Resolve-RepoOutputPath ([string]$handoff.artifact_root) `
    'Handoff artifact root'
  $ManifestPath = Resolve-RepoOutputPath `
    ([string]$handoff.candidate_manifest.path) 'Handoff manifest path'
  Assert-Condition ((Get-R19Sha256 $ManifestPath) -ceq
      [string]$handoff.candidate_manifest.sha256) `
    'Handoff candidate manifest hash mismatch'
}

if (-not [string]::IsNullOrWhiteSpace($ManifestPath) -and
    [string]::IsNullOrWhiteSpace($ArtifactRoot)) {
  $manifestSelector = Get-Item -LiteralPath $ManifestPath -ErrorAction Stop
  $ArtifactRoot = $manifestSelector.DirectoryName
}
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
  throw 'No R19 candidate artifact root was selected'
}
$artifactRootFull = (Resolve-Path -LiteralPath $ArtifactRoot `
  -ErrorAction Stop).Path
[void](Assert-R19PathWithin $outputBase $artifactRootFull `
  'R19 candidate artifact root')
$allowedRootDirectories = @('package', 'firmware', 'evidence')
$allowedRootFiles = @(
  'candidate_manifest.json',
  'artifact_manifest.json',
  'SHA256SUMS.txt',
  'final_seal.json',
  'final_seal.sha256',
  'handoff.json',
  'handoff.sha256'
)
foreach ($entry in @(Get-ChildItem -LiteralPath $artifactRootFull -Force)) {
  $allowed = if ($entry.PSIsContainer) {
    $allowedRootDirectories -ccontains $entry.Name
  } else {
    $allowedRootFiles -ccontains $entry.Name
  }
  Assert-Condition $allowed `
    "Candidate artifact contains unknown top-level entry: $($entry.Name)"
}
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  $ManifestPath = Join-Path $artifactRootFull 'candidate_manifest.json'
}
$manifestFile = Get-Item -LiteralPath $ManifestPath -ErrorAction Stop
Assert-Condition ($manifestFile.DirectoryName -ceq $artifactRootFull) `
  'Candidate manifest is not directly inside the artifact root'
$manifestSha = Get-R19Sha256 $manifestFile.FullName
$manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw |
  ConvertFrom-Json

Assert-Condition ([string]$manifest.schema -ceq
    $script:R19CandidateArtifactSchema) 'Unsupported candidate manifest schema'
Assert-Condition ([string]$manifest.test_id -ceq
    $script:R19CandidateTestId) 'Unexpected candidate manifest test ID'
Assert-Condition ([string]$manifest.result -ceq 'PASS') `
  'Candidate manifest is not PASS'
Assert-ModeContract $manifest 'Candidate manifest'
Assert-DiagnosticAbiContract $manifest 'Candidate manifest'
$extendedDiagnosticsEnabled = $runtimeFailDiagnosticsEnabled -and
  [string]$manifest.reader_schema -cin @(
    'vc-lora-r19-runtime-stage-jtag-read-v4',
    'vc-lora-r19-runtime-stage-jtag-read-v5',
    'vc-lora-r19-runtime-stage-jtag-read-v7',
    'vc-lora-r19-runtime-stage-jtag-read-v8')
$firstFailureDiagnosticsEnabled = $runtimeFailDiagnosticsEnabled -and
  [string]$manifest.reader_schema -cin @('vc-lora-r19-runtime-stage-jtag-read-v5','vc-lora-r19-runtime-stage-jtag-read-v7','vc-lora-r19-runtime-stage-jtag-read-v8')
Assert-Condition ([string]$manifest.artifact_id -ceq
    (Split-Path -Leaf $artifactRootFull)) 'Candidate artifact ID mismatch'
Assert-Condition ([string]$manifest.artifact_root -ceq
    (Get-R19RelativePath $repo $artifactRootFull)) `
  'Candidate artifact-root binding mismatch'
Assert-Condition ($manifest.hardware_interaction.performed -eq $false -and
    @($manifest.hardware_interaction.com_ports_opened).Count -eq 0 -and
    $manifest.hardware_interaction.upload_performed -eq $false -and
    $manifest.hardware_interaction.flash_performed -eq $false) `
  'Candidate build claims hardware interaction'
Assert-Condition ($manifest.deployment.authorized -eq $false -and
    $manifest.deployment.physical_30s_proven -eq $false) `
  'Candidate build improperly authorizes deployment'

Assert-Condition ([string]$manifest.toolchain.fqbn -ceq
    'esp32:esp32:XIAO_ESP32S3') 'Unexpected candidate FQBN'
Assert-Condition ([string]$manifest.toolchain.esp32_core.version -ceq
    '3.3.11') 'Unexpected candidate ESP32 core version'
Assert-Hash ([string]$manifest.toolchain.arduino_cli.sha256) `
  'Arduino CLI SHA-256'
Assert-Condition ($manifest.toolchain.hwcdc.exact_match -eq $true -and
    [string]$manifest.toolchain.hwcdc.installed_cpp_sha256 -ceq
      [string]$manifest.toolchain.hwcdc.canonical_cpp_sha256 -and
    [string]$manifest.toolchain.hwcdc.installed_h_sha256 -ceq
      [string]$manifest.toolchain.hwcdc.canonical_h_sha256 -and
    [string]$manifest.toolchain.hwcdc.installed_diagnostic_h_sha256 -ceq
      [string]$manifest.toolchain.hwcdc.canonical_diagnostic_h_sha256 -and
    [string]$manifest.toolchain.hwcdc.installed_diagnostic_h_sha256 `
      -cmatch '^[0-9A-F]{64}$') `
  'Candidate HWCDC build inputs are not exact'
$expectedInstalledDiagnosticHeader = Join-Path `
  ([string]$manifest.toolchain.esp32_core.installed_root) `
  'cores\esp32\HWCDCR19Diagnostic.h'
$expectedCanonicalDiagnosticHeader = Join-Path $repo `
  'third_party\esp32-core-3.3.11-vc-lora\cores\esp32\HWCDCR19Diagnostic.h'
Assert-Condition ([IO.Path]::GetFullPath(
      [string]$manifest.toolchain.hwcdc.installed_diagnostic_h_path) -ceq
      [IO.Path]::GetFullPath($expectedInstalledDiagnosticHeader) -and
    [IO.Path]::GetFullPath(
      [string]$manifest.toolchain.hwcdc.canonical_diagnostic_h_path) -ceq
      [IO.Path]::GetFullPath($expectedCanonicalDiagnosticHeader)) `
  'Candidate HWCDC diagnostic-header paths are not exact'
Assert-Condition ((Get-R19Sha256 $expectedInstalledDiagnosticHeader) -ceq
      [string]$manifest.toolchain.hwcdc.installed_diagnostic_h_sha256 -and
    (Get-R19Sha256 $expectedCanonicalDiagnosticHeader) -ceq
      [string]$manifest.toolchain.hwcdc.canonical_diagnostic_h_sha256) `
  'Candidate HWCDC diagnostic-header hashes do not match their paths'

$semantic = $manifest.hwcdc_semantic_contract
Assert-Condition ($null -ne $semantic -and
    $semantic.PSObject.Properties['required'] -and
    $semantic.required -is [bool] -and
    [bool]$semantic.required -eq $runtimeFailDiagnosticsEnabled -and
    (@($semantic.required_checks) -join ',') -ceq
      ($script:R19CandidateHwcdcSemanticChecks -join ',')) `
  'Candidate HWCDC semantic-contract mode or required checks are invalid'
$hwcdcSemanticSummarySha = ''
if ($runtimeFailDiagnosticsEnabled) {
  Assert-Condition ([string]$semantic.result -ceq 'PASS' -and
      $null -ne $semantic.summary) `
    'Diagnostic candidate lacks a PASS HWCDC semantic summary'
  $hwcdcSummaryPath = Assert-FileRecord $semantic.summary $artifactRootFull `
    'Diagnostic candidate HWCDC semantic summary'
  Assert-Condition ([string]$semantic.summary.path -ceq
      'evidence/hwcdc_semantic_contract/summary.json') `
    'Diagnostic candidate HWCDC semantic summary path is not canonical'
  $hwcdcSummary = Get-Content -LiteralPath $hwcdcSummaryPath -Raw |
    ConvertFrom-Json
  $semanticChecks = @(Assert-R19HwcdcSemanticSummary $hwcdcSummary `
    $manifest.toolchain.hwcdc ([string]$manifest.toolchain.fqbn) `
    ([string]$manifest.toolchain.esp32_core.version))
  Assert-Condition ([int]$semantic.check_count -eq $semanticChecks.Count) `
    'Diagnostic candidate HWCDC semantic assertion count mismatch'
  $hwcdcSemanticSummarySha = [string]$semantic.summary.sha256
} else {
  Assert-Condition ([string]$semantic.result -ceq 'NOT_REQUIRED' -and
      $null -eq $semantic.summary -and [int]$semantic.check_count -eq 0) `
    'Normal candidate improperly claims an HWCDC semantic summary'
}

$enable = $manifest.candidate_enable
$expectedCompileProperty =
  'compiler.cpp.extra_flags=-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1'
if ($runtimeFailDiagnosticsEnabled) {
  $expectedCompileProperty +=
    ' -DVC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS=1'
}
if($timedPathEnabled){$expectedCompileProperty+=" -DVC_LORA_R19_TIMED_PATH_DIAGNOSTICS=1 -DVC_LORA_R19_USB_READINESS_MODE=$($timedPathContract.mode_value)"}
if($auxReadinessEnabled){$expectedCompileProperty+=' -DVC_LORA_R19_AUX_READINESS_DIAGNOSTICS=1'}
if($diagnosticUsbFailureEnabled){$expectedCompileProperty+=' -DVC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD=1'}
Assert-Condition ([string]$enable.macro -ceq
    'VC_LORA_R19_HIGH_SPEED_CANDIDATE' -and
    [int]$enable.value -eq 1 -and
    [string]$enable.compile_flag -ceq
      '-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1' -and
    [string]$enable.property -ceq $expectedCompileProperty -and
    [int]$enable.bridge_default -eq 0 -and
    [string]$enable.mechanism -ceq 'arduino-cli-build-property') `
  'Candidate enable provenance is invalid'
Assert-Condition ((@($manifest.compile_order) -join ',') -ceq
    'vehicle,ground') 'Candidate compile order is invalid'

$policy = $manifest.flash_policy
Assert-Condition ([string]$policy.mode -ceq 'app-only' -and
    $policy.app_only -eq $true -and
    [string]$policy.offset -ceq '0x10000' -and
    (@($policy.upload_order) -join ',') -ceq 'vehicle,ground' -and
    $policy.erase_flash -eq $false -and
    $policy.write_bootloader -eq $false -and
    $policy.write_partition_table -eq $false -and
    $policy.write_merged_image -eq $false) `
  'Candidate flash policy is not exact app-only Vehicle-then-Ground'

$expectedHeaders = @($script:R19CandidateHeaderNames)
if($timedPathEnabled){$expectedHeaders+=@('r19_timed_path_record.hpp')}
if($auxReadinessEnabled){$expectedHeaders+=@('r19_aux_readiness_record.hpp')}
if($diagnosticUsbFailureEnabled){$expectedHeaders+=@('r19_diagnostic_usb_failure_record.hpp')}
$candidatePackage = $manifest.candidate_package
Assert-Condition ([int]$candidatePackage.header_count -eq
      $expectedHeaders.Count -and
    (@($candidatePackage.header_names) -join ',') -ceq
      ($expectedHeaders -join ',')) 'Candidate header package is not exact'
$candidateRecords = @($candidatePackage.files)
$expectedCandidatePaths = @($expectedHeaders | ForEach-Object {
    'firmware/high_speed/' + $_
  } | Sort-Object)
$actualCandidatePaths = @($candidateRecords | ForEach-Object {
    [string]$_.path
  } | Sort-Object)
Assert-Condition ($candidateRecords.Count -eq $expectedHeaders.Count -and
    @(Compare-Object $expectedCandidatePaths $actualCandidatePaths).Count -eq 0) `
  'Candidate package does not contain the exact source allowlist records'
Assert-Condition ((Get-R19CanonicalTreeHash $candidateRecords) -ceq
    [string]$candidatePackage.canonical_tree_sha256) `
  'Candidate package canonical tree hash mismatch'

[void](Assert-RecordTree $manifest.canonical_source_snapshot $repo `
  'Canonical source snapshot' $false)
if ($firstFailureDiagnosticsEnabled) {
  $decoderBinding = Get-R19FirstFailureDecoderBinding $repo
  $sourceDecoder = @($manifest.canonical_source_snapshot.files |
    Where-Object { [string]$_.path -ceq [string]$decoderBinding.path })
  $sealedDecoder = Join-Path $artifactRootFull `
    'evidence\tools\read_r19_first_usb_failure_record.ps1'
  Assert-Condition ($sourceDecoder.Count -eq 1 -and
      [string]$sourceDecoder[0].sha256 -ceq [string]$decoderBinding.sha256 -and
      (Test-Path -LiteralPath $sealedDecoder -PathType Leaf) -and
      (Get-R19Sha256 $sealedDecoder) -ceq [string]$decoderBinding.sha256) `
    'Candidate first_usb_failure_decoder is not bound to canonical source and sealed evidence'
}
if($timedPathEnabled){
  $timedSource=@($manifest.canonical_source_snapshot.files|Where-Object{$_.path-ceq'tools/read_r19_timed_path_record.ps1'})
  $timedDecoder=Join-Path $artifactRootFull 'evidence/tools/read_r19_timed_path_record.ps1'
  Assert-Condition ($timedSource.Count-eq1-and$timedSource[0].sha256-ceq$timedPathContract.decoder.sha256-and
    (Test-Path -LiteralPath $timedDecoder -PathType Leaf)-and(Get-R19Sha256 $timedDecoder)-ceq$timedPathContract.decoder.sha256) 'Timed path decoder is not source/sealed fingerprint bound'
  foreach($roleName in @('ground','vehicle')){
    foreach($relative in @('diagnostics/r19_host_readiness.hpp','high_speed/r19_timed_path_record.hpp')){
      $sourceRelative=if($relative.StartsWith('diagnostics/')){'firmware/'+$relative}else{'firmware/'+$relative}
      $source=@($manifest.canonical_source_snapshot.files|Where-Object{$_.path-ceq$sourceRelative})
      $staged=Join-Path $artifactRootFull "package/vc_lora_$($roleName)_xiao_esp32s3/$relative"
      Assert-Condition ($source.Count-eq1-and(Test-Path -LiteralPath $staged -PathType Leaf)-and(Get-R19Sha256 $staged)-ceq$source[0].sha256) 'Timed path diagnostic header staging differs from canonical source'
    }
  }
}
if($auxReadinessEnabled){
  $auxSource=@($manifest.canonical_source_snapshot.files|Where-Object{$_.path-ceq'tools/read_r19_aux_readiness_record.ps1'})
  $auxDecoder=Join-Path $artifactRootFull 'evidence/tools/read_r19_aux_readiness_record.ps1'
  Assert-Condition ($auxSource.Count-eq1-and$auxSource[0].sha256-ceq$auxReadinessContract.decoder.sha256-and
    (Test-Path -LiteralPath $auxDecoder -PathType Leaf)-and(Get-R19Sha256 $auxDecoder)-ceq$auxReadinessContract.decoder.sha256) 'AUX readiness decoder is not source/sealed fingerprint bound'
  foreach($roleName in @('ground','vehicle')){
    $source=@($manifest.canonical_source_snapshot.files|Where-Object{$_.path-ceq'firmware/high_speed/r19_aux_readiness_record.hpp'})
    $staged=Join-Path $artifactRootFull "package/vc_lora_$($roleName)_xiao_esp32s3/high_speed/r19_aux_readiness_record.hpp"
    Assert-Condition ($source.Count-eq1-and(Test-Path -LiteralPath $staged -PathType Leaf)-and(Get-R19Sha256 $staged)-ceq$source[0].sha256) 'AUX readiness header staging differs from canonical source'
  }
}
if($diagnosticUsbFailureEnabled){
  foreach($relative in @('tools/read_r19_diagnostic_usb_failure_record.ps1','tools/r19_usb_role_contract.ps1')){
    $source=@($manifest.canonical_source_snapshot.files|Where-Object{$_.path-ceq$relative})
    $staged=Join-Path $artifactRootFull ('evidence/'+$relative)
    Assert-Condition ($source.Count-eq1-and(Test-Path -LiteralPath $staged -PathType Leaf)-and(Get-R19Sha256 $staged)-ceq$source[0].sha256) 'Diagnostic USB decoder/role contract is not source/sealed fingerprint bound'
  }
  foreach($roleName in @('ground','vehicle')){
    $source=@($manifest.canonical_source_snapshot.files|Where-Object{$_.path-ceq'firmware/high_speed/r19_diagnostic_usb_failure_record.hpp'})
    $staged=Join-Path $artifactRootFull "package/vc_lora_$($roleName)_xiao_esp32s3/high_speed/r19_diagnostic_usb_failure_record.hpp"
    Assert-Condition ($source.Count-eq1-and(Test-Path -LiteralPath $staged -PathType Leaf)-and(Get-R19Sha256 $staged)-ceq$source[0].sha256) 'Diagnostic USB header staging differs from canonical source'
  }
}
[void](Assert-RecordTree $manifest.staged_package_snapshot $artifactRootFull `
  'Staged package snapshot' $true)

$roles = @($manifest.roles)
Assert-Condition ($roles.Count -eq 2 -and
    [string]$roles[0].role -ceq 'vehicle' -and
    [string]$roles[1].role -ceq 'ground') `
  'Candidate role records are not exact Vehicle then Ground'
foreach ($role in $roles) {
  $expectedMacro = if ([string]$role.role -ceq 'vehicle') {
    'VC_LORA_PHASE6_VEHICLE=1'
  } else {
    'VC_LORA_PHASE6_GROUND=1'
  }
  Assert-Condition ([string]$role.role_macro -ceq $expectedMacro) `
    "Candidate $($role.role) role macro mismatch"
  $applicationPath = Assert-FileRecord $role.application $artifactRootFull `
    "Candidate $($role.role) application"
  Assert-Condition ([IO.Path]::GetFileName($applicationPath) -ceq
      ($role.role + '.application.bin')) `
    "Candidate $($role.role) application name mismatch"
  Assert-ModeContract $role.compile `
    "Candidate $($role.role) compile provenance"
  Assert-Condition (@($role.compile.argv) -contains
      $expectedCompileProperty) `
    "Candidate $($role.role) compile argv lacks the enable flag"
  $evidencePath = Join-Path $artifactRootFull `
    ([string]$role.compile.evidence_path).Replace('/', '\')
  [void](Assert-R19PathWithin $artifactRootFull $evidencePath `
    "Candidate $($role.role) compile evidence")
  Assert-Condition ((Get-R19Sha256 $evidencePath) -ceq
      [string]$role.compile.evidence_sha256) `
    "Candidate $($role.role) compile evidence hash mismatch"
  $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
  Assert-Condition ([string]$evidence.schema -ceq
      'vc-lora-r19-candidate-compile-evidence-v1' -and
      [string]$evidence.role -ceq [string]$role.role -and
      [string]$evidence.result -ceq 'PASS' -and
      [int]$evidence.exit_code -eq 0 -and
      [string]$evidence.candidate_enable_flag -ceq
        '-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1' -and
      @($evidence.argv) -contains $expectedCompileProperty) `
    "Candidate $($role.role) compile evidence identity is invalid"
  Assert-ModeContract $evidence `
    "Candidate $($role.role) compile evidence"

  $expectedApplicationFileName =
    "vc_lora_$($role.role)_xiao_esp32s3.ino.bin"
  $binaryProvenance = $role.application_binary_provenance
  Assert-Condition ($null -ne $binaryProvenance -and
      [string]$binaryProvenance.schema -ceq
        'vc-lora-r19-application-binary-provenance-v1' -and
      $binaryProvenance.exact_match -is [bool] -and
      [bool]$binaryProvenance.exact_match) `
    "Candidate $($role.role) binary provenance is absent or invalid"
  foreach ($originName in @('build_path', 'output_dir')) {
    $origin = $binaryProvenance.$originName
    Assert-Condition ($null -ne $origin -and
        [string]$origin.file_name -ceq $expectedApplicationFileName -and
        [int64]$origin.size_bytes -eq [int64]$role.application.size_bytes -and
        [string]$origin.sha256 -ceq [string]$role.application.sha256) `
      "Candidate $($role.role) $originName binary provenance mismatch"
  }
  $publishedOrigin = $binaryProvenance.published
  Assert-Condition ($null -ne $publishedOrigin -and
      [string]$publishedOrigin.path -ceq [string]$role.application.path -and
      [int64]$publishedOrigin.size_bytes -eq
        [int64]$role.application.size_bytes -and
      [string]$publishedOrigin.sha256 -ceq
        [string]$role.application.sha256) `
    "Candidate $($role.role) published binary provenance mismatch"
  Assert-Condition ($null -ne $evidence.application -and
      [string]$evidence.application.path -ceq
        [string]$role.application.path -and
      [int64]$evidence.application.size_bytes -eq
        [int64]$role.application.size_bytes -and
      [string]$evidence.application.sha256 -ceq
        [string]$role.application.sha256 -and
      ($evidence.application_binary_provenance |
        ConvertTo-Json -Depth 8 -Compress) -ceq
      ($binaryProvenance | ConvertTo-Json -Depth 8 -Compress)) `
    "Candidate $($role.role) compile evidence binary binding mismatch"

  $reproducibility = $role.reproducibility_artifacts
  Assert-Condition ($null -ne $reproducibility) `
    "Candidate $($role.role) lacks reproducibility artifacts"
  $reproducibilityRecords = @(Assert-RecordTree $reproducibility `
    $artifactRootFull "Candidate $($role.role) reproducibility artifacts" `
    $true)
  $expectedReproducibilityPaths = @(
    $script:R19CandidateReproducibilityArtifactNames | ForEach-Object {
      "evidence/build/$($role.role)/$_"
    } | Sort-Object)
  $actualReproducibilityPaths = @($reproducibilityRecords |
    ForEach-Object { [string]$_.path } | Sort-Object)
  Assert-Condition ($reproducibilityRecords.Count -eq
      $script:R19CandidateReproducibilityArtifactNames.Count -and
      @(Compare-Object $expectedReproducibilityPaths `
        $actualReproducibilityPaths).Count -eq 0) `
    "Candidate $($role.role) reproducibility artifact set is not exact"

  if ($runtimeFailDiagnosticsEnabled) {
    $elfPath = Join-Path $artifactRootFull `
      "evidence\build\$($role.role)\application.elf"
    $bindingProperty = $role.PSObject.Properties['runtime_diagnostic_symbols']
    if ($extendedDiagnosticsEnabled) {
      $expectedBinding = Get-R19DiagnosticSymbolBinding $elfPath `
        (Join-Path $artifactRootFull `
          "evidence\build\$($role.role)\application.map") `
        ([string]$role.application.sha256) $firstFailureDiagnosticsEnabled $timedPathEnabled $auxReadinessEnabled $diagnosticUsbFailureEnabled
      Assert-Condition ($null -ne $bindingProperty -and
          ($bindingProperty.Value | ConvertTo-Json -Depth 12 -Compress) -ceq
          ($expectedBinding | ConvertTo-Json -Depth 12 -Compress)) `
        "Candidate $($role.role) runtime_diagnostic_symbols differs from sealed ELF/MAP/application"
    } else {
      Assert-Condition ($null -eq $bindingProperty) `
        "Candidate $($role.role) reader-v3 contains undeclared symbol bindings"
      [void](Get-R19ElfDiagnosticSymbols $elfPath $false)
    }
  }

  $flashLayout = $role.application_flash_layout
  Assert-Condition ($null -ne $flashLayout -and
      [string]$flashLayout.schema -ceq
        'vc-lora-r19-application-flash-layout-v1' -and
      [string]$flashLayout.application_file_name -ceq
        $expectedApplicationFileName -and
      [int]$flashLayout.flash_args.application_occurrences -eq 1 -and
      [string]$flashLayout.flash_args.application_offset -ceq '0x10000' -and
      [int]$flashLayout.partitions_csv.target_app_occurrences -eq 1 -and
      [string]$flashLayout.partitions_csv.target_app_offset -ceq '0x10000') `
    "Candidate $($role.role) application flash layout is invalid"
  Assert-Condition (($evidence.application_flash_layout |
        ConvertTo-Json -Depth 8 -Compress) -ceq
      ($flashLayout | ConvertTo-Json -Depth 8 -Compress)) `
    "Candidate $($role.role) compile evidence flash layout mismatch"
  $sealedFlashLayout = Get-R19ApplicationFlashLayout `
    "Candidate $($role.role)" $expectedApplicationFileName `
    (Join-Path $artifactRootFull `
      "evidence\build\$($role.role)\flash_args") `
    (Join-Path $artifactRootFull `
      "evidence\build\$($role.role)\partitions.csv")
  Assert-Condition (($sealedFlashLayout |
        ConvertTo-Json -Depth 8 -Compress) -ceq
      ($flashLayout | ConvertTo-Json -Depth 8 -Compress)) `
    "Candidate $($role.role) sealed flash layout differs from provenance"
}

$allApplicationBins = @(Get-ChildItem -LiteralPath $artifactRootFull -Recurse `
  -File -Filter '*.bin')
Assert-Condition ($allApplicationBins.Count -eq 2 -and
    (@($allApplicationBins.Name | Sort-Object) -join ',') -ceq
      'ground.application.bin,vehicle.application.bin') `
  'Candidate artifact must contain exactly two app-only binaries'

$inventoryPath = Join-Path $artifactRootFull 'artifact_manifest.json'
$inventorySha = Get-R19Sha256 $inventoryPath
$inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
Assert-Condition ([string]$inventory.schema -ceq
    $script:R19CandidateArtifactInventorySchema -and
    [string]$inventory.result -ceq 'PASS' -and
    [string]$inventory.artifact_id -ceq [string]$manifest.artifact_id) `
  'Candidate artifact inventory identity is invalid'
Assert-ModeContract $inventory 'Candidate artifact inventory'
$inventoryRecords = @(Assert-RecordTree $inventory $artifactRootFull `
  'Artifact inventory' $true)
$expectedInventoryPaths = @(Get-ChildItem -LiteralPath $artifactRootFull `
    -Recurse -File | Where-Object {
      $relative = Get-R19RelativePath $artifactRootFull $_.FullName
      $relative -eq 'candidate_manifest.json' -or
        $relative.StartsWith('package/', [StringComparison]::Ordinal) -or
        $relative.StartsWith('firmware/', [StringComparison]::Ordinal) -or
        $relative.StartsWith('evidence/', [StringComparison]::Ordinal)
    } | ForEach-Object {
      Get-R19RelativePath $artifactRootFull $_.FullName
    } | Sort-Object)
$recordedInventoryPaths = @($inventoryRecords | ForEach-Object {
    [string]$_.path
  } | Sort-Object)
Assert-Condition (@(Compare-Object $expectedInventoryPaths `
      $recordedInventoryPaths).Count -eq 0) `
  'Candidate artifact inventory omits or invents build files'

$sumsPath = Join-Path $artifactRootFull 'SHA256SUMS.txt'
$orderedInventoryRecords = @(
  Get-R19OrdinalPathRecords $inventoryRecords)
$expectedSums = (@($orderedInventoryRecords | ForEach-Object {
      "$($_.sha256) *$($_.path)"
    }) -join "`n") + "`n"
Assert-Condition ((Get-Content -LiteralPath $sumsPath -Raw) -ceq
    $expectedSums) 'Candidate SHA256SUMS does not match its inventory'

$sealPath = Join-Path $artifactRootFull 'final_seal.json'
$sealSha = Get-R19Sha256 $sealPath
Assert-Condition ((Read-R19HashFile `
      (Join-Path $artifactRootFull 'final_seal.sha256') `
      'final_seal.json') -ceq $sealSha) `
  'Candidate final-seal companion hash mismatch'
$seal = Get-Content -LiteralPath $sealPath -Raw | ConvertFrom-Json
Assert-ModeContract $seal 'Candidate final seal'
if ($extendedDiagnosticsEnabled) {
  Assert-DiagnosticAbiContract $seal 'Candidate final seal'
  Assert-Condition ([string]$seal.reader_schema -ceq
      [string]$manifest.reader_schema -and
      ($seal.usb_extended_diagnostics | ConvertTo-Json -Depth 12 -Compress) -ceq
      ($manifest.usb_extended_diagnostics | ConvertTo-Json -Depth 12 -Compress)) `
    'Candidate final seal diagnostic extension binding differs from manifest'
  $sealRoles = @($seal.roles)
  Assert-Condition ($sealRoles.Count -eq 2) `
    'Candidate final seal diagnostic role bindings are incomplete'
  for ($index = 0; $index -lt 2; $index++) {
    Assert-Condition ([string]$sealRoles[$index].role -ceq
        [string]$roles[$index].role -and
        ($sealRoles[$index].runtime_diagnostic_symbols |
          ConvertTo-Json -Depth 12 -Compress) -ceq
        ($roles[$index].runtime_diagnostic_symbols |
          ConvertTo-Json -Depth 12 -Compress)) `
      'Candidate final seal diagnostic symbol binding differs from manifest'
  }
} elseif ($runtimeFailDiagnosticsEnabled) {
  Assert-Condition ($null -eq $seal.PSObject.Properties['usb_extended_diagnostics'] -and
      $null -eq $seal.PSObject.Properties['first_usb_failure_decoder'] -and
      $null -eq $seal.PSObject.Properties['roles']) `
    'Legacy candidate final seal contains undeclared diagnostic extensions'
}
Assert-Condition ($seal.PSObject.Properties[
      'hwcdc_semantic_contract_required'] -and
    $seal.hwcdc_semantic_contract_required -is [bool] -and
    [bool]$seal.hwcdc_semantic_contract_required -eq
      $runtimeFailDiagnosticsEnabled -and
    [string]$seal.hwcdc_semantic_summary_sha256 -ceq
      $hwcdcSemanticSummarySha) `
  'Candidate final seal does not bind the HWCDC semantic summary'
Assert-Condition ([string]$seal.schema -ceq $script:R19CandidateSealSchema -and
    [string]$seal.result -ceq 'PASS' -and
    [string]$seal.artifact_id -ceq [string]$manifest.artifact_id -and
    [string]$seal.candidate_manifest_sha256 -ceq $manifestSha -and
    [string]$seal.artifact_manifest_sha256 -ceq $inventorySha -and
    [string]$seal.sha256s_sha256 -ceq (Get-R19Sha256 $sumsPath) -and
    [string]$seal.canonical_source_tree_sha256 -ceq
      [string]$manifest.canonical_source_snapshot.tree_sha256 -and
    [string]$seal.staged_package_tree_sha256 -ceq
      [string]$manifest.staged_package_snapshot.tree_sha256 -and
    [string]$seal.vehicle_application_sha256 -ceq
      [string]$roles[0].application.sha256 -and
    [string]$seal.ground_application_sha256 -ceq
      [string]$roles[1].application.sha256 -and
    $seal.deployment_authorized -eq $false -and
    $seal.hardware_interaction -eq $false) `
  'Candidate final seal does not bind the exact build'

if ($null -eq $handoff) {
  $HandoffPath = Join-Path $artifactRootFull 'handoff.json'
  $handoffSha = Get-R19Sha256 $HandoffPath
  Assert-Condition ((Read-R19HashFile `
      (Join-Path $artifactRootFull 'handoff.sha256') `
      'handoff.json') -ceq $handoffSha) `
    'Candidate handoff companion hash mismatch'
  $handoff = Get-Content -LiteralPath $HandoffPath -Raw | ConvertFrom-Json
  Assert-HandoffIdentity $handoff
}
$handoffRoles = @($handoff.roles)
if ($runtimeFailDiagnosticsEnabled) {
  Assert-Condition ([string]$handoff.reader_schema -ceq
      [string]$manifest.reader_schema -and
      ($handoff.usb_extended_diagnostics | ConvertTo-Json -Depth 12 -Compress) -ceq
      ($manifest.usb_extended_diagnostics | ConvertTo-Json -Depth 12 -Compress)) `
    'Candidate handoff diagnostic extension binding differs from manifest'
}
Assert-Condition ($handoffRoles.Count -eq 2 -and
    [string]$handoffRoles[0].role -ceq 'vehicle' -and
    [string]$handoffRoles[1].role -ceq 'ground') `
  'Candidate handoff role order is invalid'
$manifestRepoPath = Get-R19RelativePath $repo $manifestFile.FullName
$sealRepoPath = Get-R19RelativePath $repo $sealPath
Assert-Condition ([string]$handoff.artifact_id -ceq
    [string]$manifest.artifact_id -and
    [string]$handoff.artifact_root -ceq
      (Get-R19RelativePath $repo $artifactRootFull) -and
    [string]$handoff.candidate_manifest.path -ceq $manifestRepoPath -and
    [string]$handoff.candidate_manifest.sha256 -ceq $manifestSha -and
    [string]$handoff.final_seal.path -ceq $sealRepoPath -and
    [string]$handoff.final_seal.sha256 -ceq $sealSha) `
  'Candidate handoff does not bind manifest, seal, and artifact root'
for ($index = 0; $index -lt 2; $index++) {
  $manifestRole = $roles[$index]
  $handoffRole = $handoffRoles[$index]
  $expectedApplicationPath = Get-R19RelativePath $repo `
    (Join-Path $artifactRootFull ([string]$manifestRole.application.path))
  Assert-Condition ([string]$handoffRole.role -ceq
      [string]$manifestRole.role -and
      [string]$handoffRole.application.path -ceq $expectedApplicationPath -and
      [int64]$handoffRole.application.size_bytes -eq
        [int64]$manifestRole.application.size_bytes -and
      [string]$handoffRole.application.sha256 -ceq
        [string]$manifestRole.application.sha256) `
    "Candidate handoff $($manifestRole.role) application binding mismatch"
  if ($runtimeFailDiagnosticsEnabled) {
    if ($extendedDiagnosticsEnabled) {
      Assert-Condition (($handoffRole.runtime_diagnostic_symbols |
          ConvertTo-Json -Depth 12 -Compress) -ceq
          ($manifestRole.runtime_diagnostic_symbols |
            ConvertTo-Json -Depth 12 -Compress)) `
        "Candidate handoff $($manifestRole.role) diagnostic symbol binding mismatch"
    } else {
      Assert-Condition ($null -eq $handoffRole.PSObject.Properties[
          'runtime_diagnostic_symbols']) `
        'Legacy candidate handoff contains undeclared diagnostic symbol bindings'
    }
  }
}

if ($null -ne $latest) {
  Assert-Condition ([string]$latest.artifact_id -ceq
      [string]$manifest.artifact_id -and
      [string]$latest.artifact_root -ceq
        (Get-R19RelativePath $repo $artifactRootFull) -and
      [string]$latest.handoff.path -ceq
        (Get-R19RelativePath $repo $HandoffPath) -and
      [string]$latest.handoff.sha256 -ceq $handoffSha -and
      [string]$latest.candidate_manifest.path -ceq $manifestRepoPath -and
      [string]$latest.candidate_manifest.sha256 -ceq $manifestSha -and
      [string]$latest.final_seal.path -ceq $sealRepoPath -and
      [string]$latest.final_seal.sha256 -ceq $sealSha) `
    'Latest pointer does not bind the selected candidate artifact'
  $latestEndSha = Get-R19Sha256 $LatestPath
  Assert-Condition ($latestEndSha -ceq $latestStartSha -and
      (Read-R19HashFile (Join-Path $outputBase 'latest.sha256') `
        'latest.json') -ceq $latestStartSha) `
    'Latest pointer changed during verification'
}

Write-Output ("FW-R19-CANDIDATE-ARTIFACT-VERIFY-001 PASS " +
  "artifact_id=$($manifest.artifact_id) manifest_sha256=$manifestSha " +
  "seal_sha256=$sealSha " +
  "runtime_fail_diagnostics_enabled=$runtimeFailDiagnosticsEnabled")
Write-Output ("vehicle_application_sha256=" +
  [string]$roles[0].application.sha256)
Write-Output ("ground_application_sha256=" +
  [string]$roles[1].application.sha256)
