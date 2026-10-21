[CmdletBinding()]
param(
  [switch]$Execute,
  [switch]$OfflineSelfTest,
  [string]$RepoRoot = '',
  [string]$OutputDirectory = '',
  [string]$CandidateHandoffPath = '',
  [string]$CandidateFlashEvidencePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$newline = [Environment]::NewLine
$testId = 'R19-PIXHAWK-PARAM-LIST-E2E-HIL-001'
$candidateManifestSchema = 'vc-lora-r19-candidate-artifact-manifest-v1'
$candidateHandoffSchema = 'vc-lora-r19-candidate-artifact-handoff-v1'
$candidateLatestSchema = 'vc-lora-r19-candidate-artifact-latest-v1'
$candidateSealSchema = 'vc-lora-r19-candidate-final-seal-v1'
$flashEvidenceSchema = 'vc-lora-r19-candidate-flash-evidence-v1'
$flashSealSchema = 'vc-lora-r19-candidate-flash-final-seal-v1'
$provenanceSchema = 'vc-lora-r19-live-acceptance-provenance-v1'
$oneRunAuthorizationText = 'R19_EXPERIMENTAL_HIL_ONE_RUN_NOT_DEPLOYMENT'
$operatorSafetyAttestationText =
    'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED'
$expectedSafetyConditions = @(
  'Pixhawk DISARMED','propulsion and actuator power isolated',
  'both E220 antennas connected','common GND and 3.3 V logic checked',
  'Pixhawk parameter backup saved'
)
$expectedOperations = @(
  'vehicle_read_mac','vehicle_write','vehicle_verify',
  'vehicle_reenumeration','ground_read_mac','ground_write',
  'ground_verify','ground_reenumeration'
)
$expectedRoles = @('vehicle','ground')
$expectedPorts = @('COM3','COM6')
$startedUtc = [DateTime]::UtcNow.ToString('o')

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
$sharedRunner = Join-Path $repo 'tools\run_r18_pixhawk_param_list_e2e_hil.ps1'
$script:Evidence = ''
$script:Completed = $false
$script:RunnerStartSha256 = ''
$script:PinnedInputs = [Collections.ArrayList]::new()
$script:ChildSummary = $null
$script:Provenance = $null
$script:OneRunClaim = $null
$script:Failure = ''
$script:DiagnosticBuildEligibilityContract = $null

function Assert-Condition([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-RuntimeFailDiagnosticsDisabled([object]$Record) {
  Assert-Condition ($null -ne $Record -and $Record.PSObject.Properties[
        'runtime_fail_diagnostics_enabled'] -and
      $Record.runtime_fail_diagnostics_enabled -is [bool] -and
      -not [bool]$Record.runtime_fail_diagnostics_enabled -and
      $Record.PSObject.Properties['acceptance_eligible'] -and
      $Record.acceptance_eligible -is [bool] -and
      [bool]$Record.acceptance_eligible -and
      $Record.PSObject.Properties['acceptance_authorized'] -and
      $Record.acceptance_authorized -is [bool] -and
      -not [bool]$Record.acceptance_authorized -and
      $Record.PSObject.Properties['deployment_authorized'] -and
      $Record.deployment_authorized -is [bool] -and
      -not [bool]$Record.deployment_authorized) `
      ('Acceptance artifacts require diagnostics=false, eligible=true, ' +
       'acceptance_authorized=false, and deployment_authorized=false; ' +
       'operator one-run authorization comes only from separately sealed ' +
       'flash evidence.')
}

function Assert-RuntimeFailDiagnosticArtifactSetDisabled(
    [object[]]$Records) {
  Assert-Condition (@($Records).Count -eq 4) `
      'Diagnostic eligibility requires manifest/handoff/seal/latest records.'
  foreach ($record in @($Records)) {
    Assert-RuntimeFailDiagnosticsDisabled $record
  }
}

function Get-Sha([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash
}

function Get-BytesSha([byte[]]$Bytes) {
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString(
        $algorithm.ComputeHash($Bytes))).Replace('-','')
  } finally {$algorithm.Dispose()}
}

function Get-TextSha([string]$Text) {
  return (Get-BytesSha ($utf8.GetBytes($Text)))
}

function Write-DurableBytes([string]$Path,[byte[]]$Bytes) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($parent)
  }
  $stream = [IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,[IO.FileShare]::Read,4096,
      [IO.FileOptions]::WriteThrough)
  try {
    if ($Bytes.Length -gt 0) {$stream.Write($Bytes,0,$Bytes.Length)}
    $stream.Flush($true)
  } finally {$stream.Dispose()}
}

function Write-Durable([string]$Path,[string]$Text) {
  Write-DurableBytes $Path $utf8.GetBytes($Text)
}

function Write-DurableJson([string]$Path,[object]$Value) {
  Write-Durable $Path ((ConvertTo-Json -InputObject $Value -Depth 40) +
      $newline)
  [void](Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Initialize-Evidence {
  $runsRoot = [IO.Path]::GetFullPath((Join-Path $repo 'runs')).TrimEnd('\')
  if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $base = Join-Path $runsRoot "hil\$testId"
    if (-not (Test-Path -LiteralPath $base -PathType Container)) {
      [void][IO.Directory]::CreateDirectory($base)
    }
    $leaf = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' +
        [Guid]::NewGuid().ToString('N').Substring(0,8)
    $script:Evidence = Join-Path $base $leaf
  } else {
    $script:Evidence = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
  }
  Assert-Condition ($script:Evidence.StartsWith(
      $runsRoot + '\',[StringComparison]::OrdinalIgnoreCase)) `
      'OutputDirectory must be a new descendant of the repository runs directory.'
  Assert-Condition (-not (Test-Path -LiteralPath $script:Evidence)) `
      "Refusing to overwrite evidence: $($script:Evidence)"
  [void][IO.Directory]::CreateDirectory($script:Evidence)
}

function Resolve-RepoPath([string]$Path,[string]$Description) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($Path)) `
      "$Description path is empty."
  $candidate = if ([IO.Path]::IsPathRooted($Path)) {
    [IO.Path]::GetFullPath($Path)
  } else {[IO.Path]::GetFullPath((Join-Path $repo $Path))}
  Assert-Condition ($candidate.StartsWith(
      $repo + '\',[StringComparison]::OrdinalIgnoreCase)) `
      "$Description path escaped the repository: $candidate"
  Assert-Condition (Test-Path -LiteralPath $candidate -PathType Leaf) `
      "$Description is missing: $candidate"
  return (Resolve-Path -LiteralPath $candidate).Path
}

function Resolve-WithinRootPath([string]$Root,[string]$Path,
    [string]$Description) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($Path)) `
      "$Description path is empty."
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $candidate = if ([IO.Path]::IsPathRooted($Path)) {
    [IO.Path]::GetFullPath($Path)
  } else {[IO.Path]::GetFullPath((Join-Path $rootFull $Path))}
  Assert-Condition ($candidate.StartsWith(
      $rootFull + '\',[StringComparison]::OrdinalIgnoreCase)) `
      "$Description path escaped its immutable artifact root: $candidate"
  Assert-Condition (Test-Path -LiteralPath $candidate -PathType Leaf) `
      "$Description is missing: $candidate"
  return (Resolve-Path -LiteralPath $candidate).Path
}

function Read-JsonSnapshot([string]$Path,[string]$Description) {
  [byte[]]$first = [IO.File]::ReadAllBytes($Path)
  [byte[]]$second = [IO.File]::ReadAllBytes($Path)
  Assert-Condition ((Get-BytesSha $first) -ceq (Get-BytesSha $second)) `
      "$Description changed while being read."
  $value = $utf8.GetString($first) | ConvertFrom-Json
  return [pscustomobject][ordered]@{
    path=(Resolve-Path -LiteralPath $Path).Path
    bytes=[int64]$first.Length
    sha256=Get-BytesSha $first
    raw=$first
    value=$value
  }
}

function Read-HashSidecar([string]$JsonPath,[string]$SidecarName,
    [string]$ExpectedFileName,[string]$Description) {
  $sidecarPath = Join-Path (Split-Path -Parent $JsonPath) $SidecarName
  Assert-Condition (Test-Path -LiteralPath $sidecarPath -PathType Leaf) `
      "$Description is missing: $sidecarPath"
  [byte[]]$first = [IO.File]::ReadAllBytes($sidecarPath)
  [byte[]]$second = [IO.File]::ReadAllBytes($sidecarPath)
  Assert-Condition ((Get-BytesSha $first) -ceq (Get-BytesSha $second)) `
      "$Description changed while being read."
  $text = $utf8.GetString($first).Trim()
  $pattern = '^([0-9A-F]{64}) \*' + [regex]::Escape($ExpectedFileName) + '$'
  Assert-Condition ($text -cmatch $pattern) "$Description is malformed."
  $declared = $Matches[1]
  Assert-Condition ($declared -ceq (Get-Sha $JsonPath)) `
      "$Description does not bind $ExpectedFileName."
  return [pscustomobject][ordered]@{
    path=(Resolve-Path -LiteralPath $sidecarPath).Path
    bytes=[int64]$first.Length;sha256=Get-BytesSha $first
    declared_sha256=$declared;raw=$first
  }
}

function Copy-PinnedSnapshot([object]$Snapshot,[string]$Name) {
  $target = Join-Path (Join-Path $script:Evidence 'inputs') $Name
  Write-DurableBytes $target ([byte[]]$Snapshot.raw)
  Assert-Condition ((Get-Sha $target) -ceq [string]$Snapshot.sha256) `
      "Pinned snapshot changed: $Name"
  [void]$script:PinnedInputs.Add([pscustomobject][ordered]@{
    name=$Name;source=[string]$Snapshot.path
    bytes=[int64]$Snapshot.bytes;sha256=[string]$Snapshot.sha256
    staged=$target
  })
}

function Assert-ExactArray([object[]]$Actual,[string[]]$Expected,
    [string]$Description) {
  $values = @($Actual)
  Assert-Condition ($values.Count -eq $Expected.Count) `
      "$Description count mismatch."
  for ($index = 0; $index -lt $Expected.Count; ++$index) {
    Assert-Condition ([string]$values[$index] -ceq $Expected[$index]) `
        "$Description mismatch at position $index."
  }
}

function Assert-CanonicalSha([string]$Value,[string]$Description) {
  Assert-Condition ($Value -cmatch '^[0-9A-F]{64}$') `
      "$Description is not canonical uppercase SHA-256."
}

function Get-RoleApplication([object]$Manifest,[string]$Role) {
  $matches = @($Manifest.roles | Where-Object {
    [string]$_.role -ceq $Role
  })
  Assert-Condition ($matches.Count -eq 1) `
      "Candidate manifest must contain exactly one $Role role."
  $application = $matches[0].application
  Assert-Condition ($null -ne $application) `
      "Candidate manifest $Role application is missing."
  return $application
}

function Assert-ApplicationFile([object]$Application,[string]$Role,
    [string]$BaseRoot) {
  $path = Resolve-WithinRootPath $BaseRoot ([string]$Application.path) `
      "$Role candidate application"
  [int64]$size = 0
  Assert-Condition ([int64]::TryParse([string]$Application.size_bytes,
      [Globalization.NumberStyles]::None,
      [Globalization.CultureInfo]::InvariantCulture,[ref]$size) -and
      $size -gt 0) "$Role candidate application size is invalid."
  Assert-CanonicalSha ([string]$Application.sha256) `
      "$Role candidate application hash"
  Assert-Condition ((Get-Item -LiteralPath $path).Length -eq $size -and
      (Get-Sha $path) -ceq [string]$Application.sha256) `
      "$Role candidate application bytes do not match its manifest."
  return [pscustomobject][ordered]@{
    role=$Role;path=$path;size_bytes=$size
    sha256=[string]$Application.sha256
  }
}

function Get-RoleBridgeSourceBindings([object]$Manifest,
    [string]$ArtifactRoot,[object[]]$Applications) {
  $snapshot = $Manifest.staged_package_snapshot
  Assert-Condition ($null -ne $snapshot -and
      @($snapshot.files).Count -gt 0) `
      'Candidate manifest has no staged package source snapshot.'
  $bindings = [Collections.Generic.List[object]]::new()
  foreach ($role in $expectedRoles) {
    $expectedPath = ('package/vc_lora_{0}_xiao_esp32s3/' +
        'vc_lora_phase6_bridge.hpp') -f $role
    $matches = @($snapshot.files | Where-Object {
      [string]$_.path -ceq $expectedPath
    })
    Assert-Condition ($matches.Count -eq 1) `
        "Candidate $role bridge source mapping is not unique."
    $record = $matches[0]
    Assert-CanonicalSha ([string]$record.sha256) `
        "$role bridge source hash"
    [int64]$size = 0
    Assert-Condition ([int64]::TryParse([string]$record.size_bytes,
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,[ref]$size) -and
        $size -gt 0) "$role bridge source size is invalid."
    $sourcePath = Resolve-WithinRootPath $ArtifactRoot $expectedPath `
        "$role staged bridge source"
    $verifiedSha = Get-Sha $sourcePath
    Assert-Condition ((Get-Item -LiteralPath $sourcePath).Length -eq $size -and
        $verifiedSha -ceq [string]$record.sha256) `
        "$role staged bridge source does not match the sealed manifest."
    $applicationsForRole = @($Applications | Where-Object {
      [string]$_.role -ceq $role
    })
    Assert-Condition ($applicationsForRole.Count -eq 1) `
        "$role application mapping is not unique."
    $bindings.Add([pscustomobject][ordered]@{
      role=$role;source_path=$expectedPath;source_size_bytes=$size
      resolved_source_path=$sourcePath
      source_sha256=[string]$record.sha256
      verified_source_sha256=$verifiedSha;source_verified=$true
      application_sha256=[string]$applicationsForRole[0].sha256
    })
  }
  return @($bindings)
}

function Assert-CandidateManifest([object]$Manifest,[string]$ArtifactRoot) {
  Assert-Condition ([string]$Manifest.schema -ceq $candidateManifestSchema) `
      'Candidate manifest schema mismatch.'
  Assert-Condition ([string]$Manifest.result -ceq 'PASS') `
      'Candidate manifest is not PASS.'
  Assert-RuntimeFailDiagnosticsDisabled $Manifest
  $hardware = $Manifest.hardware_interaction
  Assert-Condition ($null -ne $hardware -and
      $hardware.performed -is [bool] -and -not [bool]$hardware.performed -and
      @($hardware.com_ports_opened).Count -eq 0 -and
      $hardware.upload_performed -is [bool] -and
        -not [bool]$hardware.upload_performed -and
      $hardware.flash_performed -is [bool] -and
        -not [bool]$hardware.flash_performed) `
      'Candidate build manifest must be hardware-interaction-free.'
  Assert-Condition ([string]$Manifest.candidate_enable.macro -ceq
      'VC_LORA_R19_HIGH_SPEED_CANDIDATE' -and
      [int]$Manifest.candidate_enable.value -eq 1 -and
      [string]$Manifest.candidate_enable.compile_flag -ceq
        '-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1' -and
      [int]$Manifest.candidate_enable.bridge_default -eq 0) `
      'Candidate manifest did not compile with the exact R19 enable macro.'
  Assert-Condition ($Manifest.deployment.authorized -is [bool] -and
      -not [bool]$Manifest.deployment.authorized -and
      $Manifest.deployment.physical_30s_proven -is [bool] -and
      -not [bool]$Manifest.deployment.physical_30s_proven) `
      'Candidate build must remain non-deployment and physically unproven.'
  Assert-ExactArray @($Manifest.compile_order) $expectedRoles `
      'candidate compile order'
  $policy = $Manifest.flash_policy
  Assert-Condition ([string]$policy.mode -ceq 'app-only' -and
      $policy.app_only -is [bool] -and
      [bool]$policy.app_only -and [string]$policy.offset -ceq '0x10000' -and
      $policy.erase_flash -is [bool] -and -not [bool]$policy.erase_flash -and
      $policy.write_bootloader -is [bool] -and
        -not [bool]$policy.write_bootloader -and
      $policy.write_partition_table -is [bool] -and
        -not [bool]$policy.write_partition_table -and
      $policy.write_merged_image -is [bool] -and
        -not [bool]$policy.write_merged_image) `
      'Candidate manifest flash policy is not app-only 0x10000.'
  Assert-ExactArray @($policy.upload_order) $expectedRoles `
      'candidate upload order'
  $vehicle = Assert-ApplicationFile (Get-RoleApplication $Manifest 'vehicle') `
      'vehicle' $ArtifactRoot
  $ground = Assert-ApplicationFile (Get-RoleApplication $Manifest 'ground') `
      'ground' $ArtifactRoot
  Assert-Condition ([string]$vehicle.sha256 -cne [string]$ground.sha256) `
      'Vehicle and Ground candidate applications must be distinct.'
  return @($vehicle,$ground)
}

function Assert-CandidateHandoff([string]$HandoffPath) {
  $handoffPathResolved = Resolve-RepoPath $HandoffPath 'candidate handoff'
  $handoffSnapshot = Read-JsonSnapshot $handoffPathResolved 'candidate handoff'
  $handoff = $handoffSnapshot.value
  Assert-Condition ([string]$handoff.schema -ceq $candidateHandoffSchema -and
      [string]$handoff.result -ceq 'PASS') `
      'Candidate handoff schema/result mismatch.'
  Assert-RuntimeFailDiagnosticsDisabled $handoff
  $buildRun = (Resolve-Path -LiteralPath (Split-Path -Parent `
      $handoffPathResolved)).Path
  $declaredArtifactRoot = [IO.Path]::GetFullPath((Join-Path $repo `
      ([string]$handoff.artifact_root).Replace('/','\'))).TrimEnd('\')
  Assert-Condition ($declaredArtifactRoot -ceq $buildRun) `
      'Candidate handoff artifact_root does not identify its immutable run.'
  $handoffSidecar = Read-HashSidecar $handoffPathResolved 'handoff.sha256' `
      'handoff.json' 'candidate handoff SHA-256 sidecar'
  $manifestPath = Resolve-RepoPath ([string]$handoff.candidate_manifest.path) `
      'candidate manifest'
  Assert-Condition ((Split-Path -Parent $manifestPath) -ceq $buildRun) `
      'Candidate manifest is outside the selected immutable run.'
  $manifestSnapshot = Read-JsonSnapshot $manifestPath 'candidate manifest'
  Assert-CanonicalSha ([string]$handoff.candidate_manifest.sha256) `
      'handoff candidate manifest hash'
  Assert-Condition ([string]$handoff.candidate_manifest.sha256 -ceq
      [string]$manifestSnapshot.sha256) `
      'Handoff candidate manifest hash mismatch.'
  $candidateSealPath = Resolve-RepoPath ([string]$handoff.final_seal.path) `
      'candidate final seal'
  Assert-Condition ((Split-Path -Parent $candidateSealPath) -ceq $buildRun) `
      'Candidate final seal is outside the selected immutable run.'
  $candidateSealSnapshot = Read-JsonSnapshot $candidateSealPath `
      'candidate final seal'
  Assert-CanonicalSha ([string]$handoff.final_seal.sha256) `
      'handoff final seal hash'
  Assert-Condition ([string]$handoff.final_seal.sha256 -ceq
      [string]$candidateSealSnapshot.sha256) `
      'Handoff candidate final seal hash mismatch.'
  $candidateSealSidecar = Read-HashSidecar $candidateSealPath `
      'final_seal.sha256' 'final_seal.json' `
      'candidate final seal SHA-256 sidecar'
  $candidateSeal = $candidateSealSnapshot.value
  Assert-Condition ([string]$candidateSeal.schema -ceq $candidateSealSchema -and
      [string]$candidateSeal.result -ceq 'PASS' -and
      [string]$candidateSeal.candidate_manifest_sha256 -ceq
        [string]$manifestSnapshot.sha256) `
      'Candidate final seal does not bind the PASS manifest.'
  Assert-RuntimeFailDiagnosticsDisabled $candidateSeal
  Assert-Condition ([string]$manifestSnapshot.value.artifact_root -ceq
      [string]$handoff.artifact_root) `
      'Candidate manifest artifact_root mismatch.'
  $manifestRoles = @(Assert-CandidateManifest $manifestSnapshot.value `
      $buildRun)
  $sourceBindings = @(Get-RoleBridgeSourceBindings `
      $manifestSnapshot.value $buildRun $manifestRoles)
  Assert-Condition ([string]$handoff.artifact_id -ceq
      [string]$manifestSnapshot.value.artifact_id) `
      'Candidate handoff artifact_id mismatch.'
  Assert-Condition ([string]$candidateSeal.artifact_id -ceq
        [string]$handoff.artifact_id -and
      [string]$candidateSeal.vehicle_application_sha256 -ceq
        [string]$manifestRoles[0].sha256 -and
      [string]$candidateSeal.ground_application_sha256 -ceq
        [string]$manifestRoles[1].sha256 -and
      $candidateSeal.deployment_authorized -is [bool] -and
        -not [bool]$candidateSeal.deployment_authorized -and
      $candidateSeal.hardware_interaction -is [bool] -and
        -not [bool]$candidateSeal.hardware_interaction) `
      'Candidate final seal identity/application/safety binding mismatch.'
  Assert-Condition ([string]$handoff.candidate_enable.compile_flag -ceq
        [string]$manifestSnapshot.value.candidate_enable.compile_flag -and
      [int]$handoff.candidate_enable.value -eq 1 -and
      [string]$handoff.flash_policy.mode -ceq 'app-only' -and
      [string]$handoff.flash_policy.offset -ceq '0x10000') `
      'Candidate handoff did not preserve enable/flash policy.'

  $handoffRoles = @($handoff.roles)
  Assert-Condition ($handoffRoles.Count -eq 2) `
      'Candidate handoff must contain exactly two ordered roles.'
  $roles = [Collections.Generic.List[object]]::new()
  for ($index = 0; $index -lt 2; ++$index) {
    $handoffRole = $handoffRoles[$index]
    $manifestRole = $manifestRoles[$index]
    Assert-Condition ([string]$handoffRole.role -ceq $expectedRoles[$index]) `
        "Candidate handoff role order mismatch at position $index."
    $handoffApplication = Assert-ApplicationFile $handoffRole.application `
        $expectedRoles[$index] $repo
    Assert-Condition ([int64]$handoffApplication.size_bytes -eq
        [int64]$manifestRole.size_bytes -and
        [string]$handoffApplication.sha256 -ceq
          [string]$manifestRole.sha256 -and
        [string]$handoffApplication.path -ceq [string]$manifestRole.path) `
        "Candidate handoff application mismatch: $($expectedRoles[$index])"
    $roles.Add($handoffApplication)
  }

  $buildBase = Split-Path -Parent $buildRun
  $latestPath = Join-Path $buildBase 'latest.json'
  $latestSnapshot = Read-JsonSnapshot `
      (Resolve-RepoPath $latestPath 'candidate latest pointer') `
      'candidate latest pointer'
  $latest = $latestSnapshot.value
  Assert-Condition ([string]$latest.schema -ceq $candidateLatestSchema -and
      [string]$latest.result -ceq 'PASS') `
      'Candidate latest pointer schema/result mismatch.'
  Assert-RuntimeFailDiagnosticsDisabled $latest
  Assert-RuntimeFailDiagnosticArtifactSetDisabled @(
      $manifestSnapshot.value,$handoff,$candidateSeal,$latest)
  $latestHandoffPath = Resolve-RepoPath ([string]$latest.handoff.path) `
      'latest handoff target'
  Assert-CanonicalSha ([string]$latest.handoff.sha256) `
      'latest handoff hash'
  Assert-Condition ($latestHandoffPath -ceq $handoffPathResolved -and
      [string]$latest.handoff.sha256 -ceq [string]$handoffSnapshot.sha256) `
      'Candidate latest pointer does not bind the selected handoff.'
  Assert-Condition ([string]$latest.artifact_id -ceq
        [string]$handoff.artifact_id -and
      [string]$latest.artifact_root -ceq [string]$handoff.artifact_root -and
      [string]$latest.candidate_manifest.path -ceq
        [string]$handoff.candidate_manifest.path -and
      [string]$latest.candidate_manifest.sha256 -ceq
        [string]$manifestSnapshot.sha256 -and
      [string]$latest.final_seal.path -ceq [string]$handoff.final_seal.path -and
      [string]$latest.final_seal.sha256 -ceq
        [string]$candidateSealSnapshot.sha256) `
      'Candidate latest pointer does not bind all selected immutable inputs.'
  $latestSidecar = Read-HashSidecar $latestPath 'latest.sha256' `
      'latest.json' 'candidate latest SHA-256 sidecar'

  Copy-PinnedSnapshot $latestSnapshot 'candidate.latest.json'
  Copy-PinnedSnapshot $latestSidecar 'candidate.latest.sha256'
  Copy-PinnedSnapshot $handoffSnapshot 'candidate.handoff.json'
  Copy-PinnedSnapshot $handoffSidecar 'candidate.handoff.sha256'
  Copy-PinnedSnapshot $manifestSnapshot 'candidate.manifest.json'
  Copy-PinnedSnapshot $candidateSealSnapshot 'candidate.final_seal.json'
  Copy-PinnedSnapshot $candidateSealSidecar 'candidate.final_seal.sha256'
  return [pscustomobject][ordered]@{
    result='PASS';artifact_id=[string]$handoff.artifact_id
    runtime_fail_diagnostics_enabled=$false
    acceptance_eligible=$true;acceptance_authorized=$false
    deployment_authorized=$false
    latest_path=[string]$latestSnapshot.path
    latest_sha256=[string]$latestSnapshot.sha256
    handoff_path=[string]$handoffSnapshot.path
    handoff_sha256=[string]$handoffSnapshot.sha256
    candidate_manifest_path=[string]$manifestSnapshot.path
    candidate_manifest_sha256=[string]$manifestSnapshot.sha256
    final_seal_path=[string]$candidateSealSnapshot.path
    final_seal_sha256=[string]$candidateSealSnapshot.sha256
    latest_sidecar_path=[string]$latestSidecar.path
    latest_sidecar_sha256=[string]$latestSidecar.sha256
    handoff_sidecar_path=[string]$handoffSidecar.path
    handoff_sidecar_sha256=[string]$handoffSidecar.sha256
    final_seal_sidecar_path=[string]$candidateSealSidecar.path
    final_seal_sidecar_sha256=[string]$candidateSealSidecar.sha256
    roles=@($roles)
    source_bindings=@($sourceBindings)
  }
}

function Assert-FlashEvidence([string]$FlashPath,[object]$Candidate) {
  $recordPath = Resolve-RepoPath $FlashPath 'candidate flash evidence'
  $recordSnapshot = Read-JsonSnapshot $recordPath 'candidate flash evidence'
  $record = $recordSnapshot.value
  Assert-Condition ([string]$record.schema -ceq $flashEvidenceSchema -and
      [string]$record.test_id -ceq 'R19-CANDIDATE-APP-FLASH-HIL-001' -and
      [string]$record.result -ceq 'PASS' -and
      [string]$record.status -ceq
        'PASS_CANDIDATE_INSTALLED_HIL_ONE_RUN_ONLY' -and
      [string]$record.mode -ceq 'Execute') `
      'Candidate flash evidence is not an Execute-mode installation PASS.'
  Assert-Condition ($record.one_run_hil_authorized -is [bool] -and
      [bool]$record.one_run_hil_authorized -and
      $record.deployment_authorized -is [bool] -and
      -not [bool]$record.deployment_authorized) `
      'Candidate flash evidence authorization scope mismatch.'
  $authorization = $record.authorization
  Assert-Condition ($null -ne $authorization -and
      [string]$authorization.scope -ceq
        'one immediate R19 physical acceptance run only' -and
      $authorization.reusable -is [bool] -and
        -not [bool]$authorization.reusable -and
      $authorization.deployment_authorization -is [bool] -and
        -not [bool]$authorization.deployment_authorization -and
      [string]$authorization.attestation_sha256 -ceq
        (Get-TextSha $oneRunAuthorizationText) -and
      [string]$authorization.operator_safety_attestation_sha256 -ceq
        (Get-TextSha $operatorSafetyAttestationText)) `
      'Candidate flash authorization/physical safety attestation mismatch.'
  Assert-ExactArray @($authorization.operator_safety_conditions) `
      $expectedSafetyConditions 'operator safety conditions'
  foreach ($field in @('latest_sha256','handoff_sha256',
      'candidate_manifest_sha256','candidate_final_seal_sha256')) {
    Assert-CanonicalSha ([string]$record.candidate.$field) `
        "flash candidate $field"
  }
  Assert-Condition ([string]$record.candidate.artifact_id -ceq
      [string]$Candidate.artifact_id -and
      [string]$record.candidate.latest_sha256 -ceq
        [string]$Candidate.latest_sha256 -and
      [string]$record.candidate.handoff_sha256 -ceq
        [string]$Candidate.handoff_sha256 -and
      [string]$record.candidate.candidate_manifest_sha256 -ceq
        [string]$Candidate.candidate_manifest_sha256 -and
      [string]$record.candidate.candidate_final_seal_sha256 -ceq
        [string]$Candidate.final_seal_sha256) `
      'Flash evidence is not bound to the selected candidate handoff.'
  $policy = $record.flash_policy
  Assert-Condition ($policy.app_only -is [bool] -and
      [bool]$policy.app_only -and [string]$policy.offset -ceq '0x10000' -and
      $policy.erase_flash -is [bool] -and -not [bool]$policy.erase_flash -and
      $policy.write_bootloader -is [bool] -and
        -not [bool]$policy.write_bootloader -and
      $policy.write_partition_table -is [bool] -and
        -not [bool]$policy.write_partition_table -and
      $policy.write_merged_image -is [bool] -and
        -not [bool]$policy.write_merged_image) `
      'Flash evidence policy is not app-only 0x10000.'
  Assert-ExactArray @($policy.upload_order) $expectedRoles `
      'flash upload order'
  $flashRoles = @($record.roles)
  Assert-Condition ($flashRoles.Count -eq 2) `
      'Flash evidence must contain exactly two ordered roles.'
  for ($index = 0; $index -lt 2; ++$index) {
    $actual = $flashRoles[$index]
    $expected = $Candidate.roles[$index]
    Assert-Condition ([string]$actual.role -ceq $expectedRoles[$index] -and
        [string]$actual.port -ceq $expectedPorts[$index] -and
        [int64]$actual.size_bytes -eq [int64]$expected.size_bytes -and
        [string]$actual.sha256 -ceq [string]$expected.sha256 -and
        $actual.write_pass -is [bool] -and [bool]$actual.write_pass -and
        $actual.verify_pass -is [bool] -and [bool]$actual.verify_pass -and
        $actual.reenumeration_pass -is [bool] -and
          [bool]$actual.reenumeration_pass) `
        "Flash evidence role mismatch: $($expectedRoles[$index])"
  }
  $operations = @($record.operations)
  Assert-Condition ($operations.Count -eq $expectedOperations.Count) `
      'Flash evidence operation count mismatch.'
  for ($index = 0; $index -lt $expectedOperations.Count; ++$index) {
    Assert-Condition ([string]$operations[$index].label -ceq
        $expectedOperations[$index] -and
        [string]$operations[$index].result -ceq 'PASS') `
        "Flash operation mismatch at position $index."
  }
  $sealPath = Join-Path (Split-Path -Parent $recordPath) 'final_seal.json'
  $sealSnapshot = Read-JsonSnapshot `
      (Resolve-RepoPath $sealPath 'candidate flash final seal') `
      'candidate flash final seal'
  $seal = $sealSnapshot.value
  Assert-Condition ([string]$seal.schema -ceq $flashSealSchema -and
      [string]$seal.test_id -ceq 'R19-CANDIDATE-APP-FLASH-HIL-001' -and
      [string]$seal.result -ceq 'PASS' -and
      [string]$seal.status -ceq
        'PASS_CANDIDATE_INSTALLED_HIL_ONE_RUN_ONLY' -and
      [string]$seal.flash_record_sha256 -ceq [string]$recordSnapshot.sha256 -and
      [string]$seal.candidate_manifest_sha256 -ceq
        [string]$Candidate.candidate_manifest_sha256 -and
      [string]$seal.final_seal_sha256 -ceq
        [string]$Candidate.final_seal_sha256 -and
      $seal.one_run_hil_authorized -is [bool] -and
        [bool]$seal.one_run_hil_authorized -and
      $seal.deployment_authorized -is [bool] -and
        -not [bool]$seal.deployment_authorized) `
      'Candidate flash final seal does not bind record and manifest.'
  $sealSidecar = Read-HashSidecar $sealSnapshot.path 'final_seal.sha256' `
      'final_seal.json' 'candidate flash final seal SHA-256 sidecar'
  Copy-PinnedSnapshot $recordSnapshot 'candidate.flash_record.json'
  Copy-PinnedSnapshot $sealSnapshot 'candidate.flash_final_seal.json'
  Copy-PinnedSnapshot $sealSidecar 'candidate.flash_final_seal.sha256'
  return [pscustomobject][ordered]@{
    result='PASS';record_path=[string]$recordSnapshot.path
    record_sha256=[string]$recordSnapshot.sha256
    final_seal_path=[string]$sealSnapshot.path
    final_seal_sha256=[string]$sealSnapshot.sha256
    final_seal_sidecar_path=[string]$sealSidecar.path
    final_seal_sidecar_sha256=[string]$sealSidecar.sha256
    status=[string]$record.status;mode=[string]$record.mode
    one_run_hil_authorized=$true;deployment_authorized=$false
    authorization=[pscustomobject][ordered]@{
      result='PASS';scope=[string]$authorization.scope
      reusable=$false;deployment_authorization=$false
      attestation_sha256=[string]$authorization.attestation_sha256
      operator_safety_attestation_sha256=
        [string]$authorization.operator_safety_attestation_sha256
      operator_safety_conditions=@($authorization.operator_safety_conditions)
    }
    roles=@($flashRoles)
  }
}

function New-OneRunClaim([object]$Flash,[object]$Candidate,
    [string]$ClaimRoot) {
  $runsRoot = [IO.Path]::GetFullPath((Join-Path $repo 'runs')).TrimEnd('\')
  $claimRootFull = [IO.Path]::GetFullPath($ClaimRoot).TrimEnd('\')
  Assert-Condition ($claimRootFull.StartsWith(
      $runsRoot + '\',[StringComparison]::OrdinalIgnoreCase)) `
      'One-run claim registry must remain inside the repository runs tree.'
  if (-not (Test-Path -LiteralPath $claimRootFull -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($claimRootFull)
  }
  Assert-CanonicalSha ([string]$Flash.record_sha256) `
      'one-run claim flash record hash'
  $claimPath = Join-Path $claimRootFull `
      (([string]$Flash.record_sha256) + '.claim.json')
  $claimValue = [ordered]@{
    schema='vc-lora-r19-live-one-run-claim-v1';result='CLAIMED'
    claimed_at_utc=[DateTime]::UtcNow.ToString('o')
    flash_record_sha256=[string]$Flash.record_sha256
    flash_final_seal_sha256=[string]$Flash.final_seal_sha256
    candidate_manifest_sha256=[string]$Candidate.candidate_manifest_sha256
    candidate_artifact_id=[string]$Candidate.artifact_id
    acceptance_test_id=$testId
    acceptance_evidence_path=$script:Evidence
    wrapper_sha256=$script:RunnerStartSha256
    authorization_scope='one immediate R19 physical acceptance run only'
    reusable=$false;deployment_authorized=$false
  }
  [byte[]]$claimBytes = $utf8.GetBytes(
      ((ConvertTo-Json -InputObject $claimValue -Depth 12) + $newline))
  try {
    Write-DurableBytes $claimPath $claimBytes
  } catch {
    if (Test-Path -LiteralPath $claimPath -PathType Leaf) {
      throw ('R19 one-run flash authorization was already claimed: ' +
          [string]$Flash.record_sha256)
    }
    throw
  }
  $claimSnapshot = Read-JsonSnapshot $claimPath 'R19 one-run claim'
  $claim = [pscustomobject][ordered]@{
    result='PASS';atomic_create_new=$true
    flash_record_sha256=[string]$Flash.record_sha256
    claim_path=[string]$claimSnapshot.path
    claim_sha256=[string]$claimSnapshot.sha256
    replay_attempt_result='NOT_RUN'
    authorization_scope='one immediate R19 physical acceptance run only'
    reusable=$false;deployment_authorized=$false
  }
  $script:OneRunClaim = $claim

  $replayRejected = $false
  try {
    Write-DurableBytes $claimPath $claimBytes
  } catch {
    $replayRejected = Test-Path -LiteralPath $claimPath -PathType Leaf
  }
  Assert-Condition $replayRejected `
      'Atomic one-run claim replay was not rejected.'
  $claim.replay_attempt_result = 'REJECTED'
  Assert-Condition ((Get-Sha $claimPath) -ceq [string]$claim.claim_sha256) `
      'One-run claim changed during replay rejection proof.'
  Copy-PinnedSnapshot $claimSnapshot 'one_run_claim.json'
  return $claim
}

function New-OfflineProvenanceFixtures {
  $fixture = Join-Path $script:Evidence 'offline_fixture'
  $buildBase = Join-Path $fixture 'candidate_builds'
  $buildRun = Join-Path $buildBase 'RUN-001'
  $flashRun = Join-Path $fixture 'flash_RUN-001'
  [void][IO.Directory]::CreateDirectory($buildRun)
  [void][IO.Directory]::CreateDirectory($flashRun)
  $vehiclePath = Join-Path $buildRun 'vehicle.application.bin'
  $groundPath = Join-Path $buildRun 'ground.application.bin'
  Write-DurableBytes $vehiclePath ([byte[]](1,2,3,4,5))
  Write-DurableBytes $groundPath ([byte[]](6,7,8,9,10,11))
  $vehicleBridgeRelative =
      'package/vc_lora_vehicle_xiao_esp32s3/vc_lora_phase6_bridge.hpp'
  $groundBridgeRelative =
      'package/vc_lora_ground_xiao_esp32s3/vc_lora_phase6_bridge.hpp'
  $vehicleBridgePath = Join-Path $buildRun $vehicleBridgeRelative.Replace('/','\')
  $groundBridgePath = Join-Path $buildRun $groundBridgeRelative.Replace('/','\')
  Write-DurableBytes $vehicleBridgePath `
      ($utf8.GetBytes('offline sealed vehicle bridge source'))
  Write-DurableBytes $groundBridgePath `
      ($utf8.GetBytes('offline sealed ground bridge source'))
  $relative = {
    param([string]$Path)
    $Path.Substring($repo.Length + 1).Replace('\','/')
  }
  $artifactRelative = {
    param([string]$Path)
    $Path.Substring($buildRun.Length + 1).Replace('\','/')
  }
  $manifestPath = Join-Path $buildRun 'candidate_manifest.json'
  $artifactId = 'OFFLINE-R19-CANDIDATE-001'
  $artifactRootRelative = & $relative $buildRun
  $manifest = [ordered]@{
    schema=$candidateManifestSchema;artifact_id=$artifactId;result='PASS'
    runtime_fail_diagnostics_enabled=$false
    acceptance_eligible=$true;acceptance_authorized=$false
    deployment_authorized=$false
    artifact_root=$artifactRootRelative
    hardware_interaction=[ordered]@{
      performed=$false;com_ports_opened=@();upload_performed=$false
      flash_performed=$false
    }
    deployment=[ordered]@{authorized=$false;physical_30s_proven=$false}
    candidate_enable=[ordered]@{
      macro='VC_LORA_R19_HIGH_SPEED_CANDIDATE';value=1
      compile_flag='-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1'
      bridge_default=0;mechanism='offline_contract_fixture'
    }
    compile_order=@('vehicle','ground')
    flash_policy=[ordered]@{
      mode='app-only';app_only=$true;offset='0x10000'
      upload_order=@('vehicle','ground')
      erase_flash=$false;write_bootloader=$false
      write_partition_table=$false;write_merged_image=$false
    }
    staged_package_snapshot=[ordered]@{
      file_count=2;tree_sha256=('C' * 64)
      files=@(
        [ordered]@{path=$vehicleBridgeRelative
          size_bytes=(Get-Item $vehicleBridgePath).Length
          sha256=Get-Sha $vehicleBridgePath},
        [ordered]@{path=$groundBridgeRelative
          size_bytes=(Get-Item $groundBridgePath).Length
          sha256=Get-Sha $groundBridgePath}
      )
    }
    roles=@(
      [ordered]@{role='vehicle';application=[ordered]@{
        path=& $artifactRelative $vehiclePath;size_bytes=5
        sha256=Get-Sha $vehiclePath}},
      [ordered]@{role='ground';application=[ordered]@{
        path=& $artifactRelative $groundPath;size_bytes=6
        sha256=Get-Sha $groundPath}}
    )
  }
  Write-DurableJson $manifestPath $manifest
  $candidateSealPath = Join-Path $buildRun 'final_seal.json'
  Write-DurableJson $candidateSealPath ([ordered]@{
    schema=$candidateSealSchema;result='PASS';artifact_id=$artifactId
    runtime_fail_diagnostics_enabled=$false
    acceptance_eligible=$true;acceptance_authorized=$false
    deployment_authorized=$false
    candidate_manifest_sha256=Get-Sha $manifestPath
    vehicle_application_sha256=Get-Sha $vehiclePath
    ground_application_sha256=Get-Sha $groundPath
    hardware_interaction=$false
  })
  Write-Durable (Join-Path $buildRun 'final_seal.sha256') `
      ((Get-Sha $candidateSealPath) + ' *final_seal.json' + $newline)
  $handoffPath = Join-Path $buildRun 'handoff.json'
  Write-DurableJson $handoffPath ([ordered]@{
    schema=$candidateHandoffSchema;result='PASS';artifact_id=$artifactId
    runtime_fail_diagnostics_enabled=$false
    acceptance_eligible=$true;acceptance_authorized=$false
    deployment_authorized=$false
    artifact_root=$artifactRootRelative
    candidate_manifest=[ordered]@{
      path=& $relative $manifestPath;sha256=Get-Sha $manifestPath}
    final_seal=[ordered]@{
      path=& $relative $candidateSealPath;sha256=Get-Sha $candidateSealPath}
    roles=@(
      [ordered]@{role='vehicle';application=[ordered]@{
        path=& $relative $vehiclePath;size_bytes=5
        sha256=Get-Sha $vehiclePath}},
      [ordered]@{role='ground';application=[ordered]@{
        path=& $relative $groundPath;size_bytes=6
        sha256=Get-Sha $groundPath}}
    )
    flash_policy=$manifest.flash_policy;candidate_enable=$manifest.candidate_enable
  })
  Write-Durable (Join-Path $buildRun 'handoff.sha256') `
      ((Get-Sha $handoffPath) + ' *handoff.json' + $newline)
  $latestPath = Join-Path $buildBase 'latest.json'
  Write-DurableJson $latestPath ([ordered]@{
    schema=$candidateLatestSchema;result='PASS';artifact_id=$artifactId
    runtime_fail_diagnostics_enabled=$false
    acceptance_eligible=$true;acceptance_authorized=$false
    deployment_authorized=$false
    artifact_root=$artifactRootRelative
    handoff=[ordered]@{
      path=& $relative $handoffPath;sha256=Get-Sha $handoffPath}
    candidate_manifest=[ordered]@{
      path=& $relative $manifestPath;sha256=Get-Sha $manifestPath}
    final_seal=[ordered]@{
      path=& $relative $candidateSealPath;sha256=Get-Sha $candidateSealPath}
    previous_latest_sha256=''
  })
  Write-Durable (Join-Path $buildBase 'latest.sha256') `
      ((Get-Sha $latestPath) + ' *latest.json' + $newline)
  $candidate = [pscustomobject][ordered]@{
    artifact_id=$artifactId
    latest_sha256=Get-Sha $latestPath
    handoff_sha256=Get-Sha $handoffPath
    candidate_manifest_sha256=Get-Sha $manifestPath
    final_seal_sha256=Get-Sha $candidateSealPath
    roles=@(
      [pscustomobject][ordered]@{role='vehicle';size_bytes=[int64]5
        sha256=Get-Sha $vehiclePath},
      [pscustomobject][ordered]@{role='ground';size_bytes=[int64]6
        sha256=Get-Sha $groundPath}
    )
  }
  $flashRecordPath = Join-Path $flashRun 'flash_record.json'
  $roleRows = @(
    [ordered]@{role='vehicle';port='COM3'
      size_bytes=$candidate.roles[0].size_bytes
      sha256=$candidate.roles[0].sha256;write_pass=$true
      verify_pass=$true;reenumeration_pass=$true},
    [ordered]@{role='ground';port='COM6'
      size_bytes=$candidate.roles[1].size_bytes
      sha256=$candidate.roles[1].sha256;write_pass=$true
      verify_pass=$true;reenumeration_pass=$true}
  )
  Write-DurableJson $flashRecordPath ([ordered]@{
    schema=$flashEvidenceSchema;test_id='R19-CANDIDATE-APP-FLASH-HIL-001'
    result='PASS';status='PASS_CANDIDATE_INSTALLED_HIL_ONE_RUN_ONLY'
    mode='Execute';one_run_hil_authorized=$true
    deployment_authorized=$false
    authorization=[ordered]@{
      scope='one immediate R19 physical acceptance run only';reusable=$false
      deployment_authorization=$false
      attestation_sha256=Get-TextSha $oneRunAuthorizationText
      operator_safety_attestation_sha256=
        Get-TextSha $operatorSafetyAttestationText
      operator_safety_conditions=@($expectedSafetyConditions)
    }
    candidate=[ordered]@{
      artifact_id=$candidate.artifact_id
      latest_sha256=$candidate.latest_sha256
      handoff_sha256=$candidate.handoff_sha256
      candidate_manifest_sha256=$candidate.candidate_manifest_sha256
      candidate_final_seal_sha256=$candidate.final_seal_sha256
    }
    flash_policy=[ordered]@{
      app_only=$true;offset='0x10000';upload_order=@('vehicle','ground')
      erase_flash=$false;write_bootloader=$false
      write_partition_table=$false;write_merged_image=$false
    }
    roles=$roleRows
    operations=@($expectedOperations | ForEach-Object {
      [ordered]@{label=$_;result='PASS'}
    })
  })
  Write-DurableJson (Join-Path $flashRun 'final_seal.json') ([ordered]@{
    schema=$flashSealSchema;test_id='R19-CANDIDATE-APP-FLASH-HIL-001'
    result='PASS';status='PASS_CANDIDATE_INSTALLED_HIL_ONE_RUN_ONLY'
    flash_record_sha256=Get-Sha $flashRecordPath
    candidate_manifest_sha256=$candidate.candidate_manifest_sha256
    final_seal_sha256=$candidate.final_seal_sha256
    one_run_hil_authorized=$true;deployment_authorized=$false
  })
  $flashSealPath = Join-Path $flashRun 'final_seal.json'
  Write-Durable (Join-Path $flashRun 'final_seal.sha256') `
      ((Get-Sha $flashSealPath) + ' *final_seal.json' + $newline)
  return [pscustomobject][ordered]@{
    handoff=$handoffPath;flash=$flashRecordPath
  }
}

function Assert-LatestUnchanged([object]$Candidate) {
  Assert-Condition ((Get-Sha ([string]$Candidate.latest_path)) -ceq
      [string]$Candidate.latest_sha256) `
      'Candidate latest pointer changed before measurement launch.'
  Assert-Condition ((Get-Sha ([string]$Candidate.handoff_path)) -ceq
      [string]$Candidate.handoff_sha256 -and
      (Get-Sha ([string]$Candidate.candidate_manifest_path)) -ceq
        [string]$Candidate.candidate_manifest_sha256 -and
      (Get-Sha ([string]$Candidate.final_seal_path)) -ceq
        [string]$Candidate.final_seal_sha256) `
      'Candidate immutable handoff inputs changed before measurement launch.'
  Assert-Condition ((Get-Sha ([string]$Candidate.latest_sidecar_path)) -ceq
        [string]$Candidate.latest_sidecar_sha256 -and
      (Get-Sha ([string]$Candidate.handoff_sidecar_path)) -ceq
        [string]$Candidate.handoff_sidecar_sha256 -and
      (Get-Sha ([string]$Candidate.final_seal_sidecar_path)) -ceq
        [string]$Candidate.final_seal_sidecar_sha256) `
      'Candidate SHA-256 sidecar changed before measurement launch.'
  foreach ($role in @($Candidate.roles)) {
    Assert-Condition ((Get-Item -LiteralPath ([string]$role.path)).Length -eq
          [int64]$role.size_bytes -and
        (Get-Sha ([string]$role.path)) -ceq [string]$role.sha256) `
        "Candidate application changed before measurement: $($role.role)"
  }
  foreach ($binding in @($Candidate.source_bindings)) {
    Assert-Condition ((Get-Item -LiteralPath `
          ([string]$binding.resolved_source_path)).Length -eq
          [int64]$binding.source_size_bytes -and
        (Get-Sha ([string]$binding.resolved_source_path)) -ceq
          [string]$binding.source_sha256) `
        "Candidate bridge source changed before measurement: $($binding.role)"
  }
}

function Assert-FlashUnchanged([object]$Flash) {
  Assert-Condition ((Get-Sha ([string]$Flash.record_path)) -ceq
        [string]$Flash.record_sha256 -and
      (Get-Sha ([string]$Flash.final_seal_path)) -ceq
        [string]$Flash.final_seal_sha256 -and
      (Get-Sha ([string]$Flash.final_seal_sidecar_path)) -ceq
        [string]$Flash.final_seal_sidecar_sha256) `
      'Candidate flash evidence changed before measurement launch.'
}

function Assert-OneRunClaimUnchanged([object]$Claim) {
  Assert-Condition ($null -ne $Claim -and
      (Get-Sha ([string]$Claim.claim_path)) -ceq
        [string]$Claim.claim_sha256) `
      'One-run authorization claim changed before measurement launch.'
}

function Get-PowerShellHostPath {
  $name = if ($PSVersionTable.PSEdition -ceq 'Core') {'pwsh.exe'} else {
    'powershell.exe'
  }
  $path = Join-Path $PSHOME $name
  Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) `
      "PowerShell child host is missing: $path"
  return $path
}

function Assert-ChildSeal([string]$ChildRoot) {
  $summaryPath = Join-Path $ChildRoot 'summary.json'
  $manifestPath = Join-Path $ChildRoot 'artifact_manifest.json'
  $sumsPath = Join-Path $ChildRoot 'SHA256SUMS.txt'
  $sealPath = Join-Path $ChildRoot 'final_seal.json'
  foreach ($path in @($summaryPath,$manifestPath,$sumsPath,$sealPath)) {
    Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) `
        "Shared runner evidence is incomplete: $path"
  }
  $seal = Get-Content -LiteralPath $sealPath -Raw | ConvertFrom-Json
  Assert-Condition ([string]$seal.summary_sha256 -ceq (Get-Sha $summaryPath) -and
      [string]$seal.artifact_manifest_sha256 -ceq (Get-Sha $manifestPath) -and
      [string]$seal.sha256sums_sha256 -ceq (Get-Sha $sumsPath) -and
      [string]$seal.runner_integrity -ceq 'PASS') `
      'Shared runner final seal verification failed.'
  $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
  Assert-Condition ([string]$summary.test_id -ceq $testId -and
      [string]$summary.acceptance_profile -ceq 'R19') `
      'Shared runner returned a non-R19 summary.'
  return $summary
}

function Invoke-SharedStrictRunner([string]$ProvenancePath) {
  Assert-Condition (Test-Path -LiteralPath $sharedRunner -PathType Leaf) `
      "Shared strict runner is missing: $sharedRunner"
  $childRoot = Join-Path $script:Evidence 'measurement'
  $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$sharedRunner)
  if ($OfflineSelfTest.IsPresent) {$arguments += '-OfflineSelfTest'} else {
    $arguments += '-Execute'
  }
  $arguments += @('-RepoRoot',$repo,'-OutputDirectory',$childRoot,
      '-R19SharedMode','-R19ProvenancePath',$ProvenancePath)
  $hostPath = Get-PowerShellHostPath
  $output = @(& $hostPath @arguments 2>&1)
  $exitCode = $LASTEXITCODE
  Write-Durable (Join-Path $script:Evidence 'shared_runner_console.txt') `
      ((($output | ForEach-Object {[string]$_}) -join $newline) + $newline)
  $summary = Assert-ChildSeal $childRoot
  Assert-Condition (($exitCode -eq 0) -eq
      ([string]$summary.result -ceq 'PASS')) `
      "Shared runner exit/result mismatch: exit=$exitCode result=$($summary.result)"
  return $summary
}

function Complete-Evidence([object]$Summary) {
  Assert-Condition (-not $script:Completed) 'Evidence may only be completed once.'
  $script:Completed = $true
  $runnerEndSha = Get-Sha $PSCommandPath
  $runnerStable = $runnerEndSha -ceq $script:RunnerStartSha256
  if (-not $runnerStable) {
    $Summary.result = 'FAIL'
    $Summary.failure = (([string]$Summary.failure +
        ' | R19 wrapper source changed during execution').Trim(' ','|'))
  }
  $Summary.finished_utc = [DateTime]::UtcNow.ToString('o')
  $Summary.runner_integrity = [pscustomobject][ordered]@{
    result=if ($runnerStable) {'PASS'} else {'FAIL'}
    start_sha256=$script:RunnerStartSha256;end_sha256=$runnerEndSha
  }
  $summaryPath = Join-Path $script:Evidence 'summary.json'
  Write-DurableJson $summaryPath $Summary
  $excluded = @('artifact_manifest.json','SHA256SUMS.txt','final_seal.json')
  $files = @(Get-ChildItem -LiteralPath $script:Evidence -Recurse -File |
      Where-Object {$excluded -notcontains $_.Name} | Sort-Object FullName)
  $records = @($files | ForEach-Object {
    [pscustomobject][ordered]@{
      path=$_.FullName.Substring($script:Evidence.Length + 1).Replace('\','/')
      bytes=[int64]$_.Length;sha256=Get-Sha $_.FullName
    }
  })
  $manifestPath = Join-Path $script:Evidence 'artifact_manifest.json'
  Write-DurableJson $manifestPath ([ordered]@{
    schema_version=1;test_id=$testId;result=[string]$Summary.result
    artifact_count=$records.Count;artifacts=$records
  })
  $sumItems = @(Get-ChildItem -LiteralPath $script:Evidence -Recurse -File |
      Where-Object {$_.Name -notin @('SHA256SUMS.txt','final_seal.json')} |
      Sort-Object FullName)
  $lines = @($sumItems | ForEach-Object {
    '{0} *{1}' -f (Get-Sha $_.FullName),
        $_.FullName.Substring($script:Evidence.Length + 1).Replace('\','/')
  })
  $sumsPath = Join-Path $script:Evidence 'SHA256SUMS.txt'
  Write-Durable $sumsPath (($lines -join $newline) + $newline)
  Write-DurableJson (Join-Path $script:Evidence 'final_seal.json') ([ordered]@{
    schema_version=1;test_id=$testId;result=[string]$Summary.result
    sealed_utc=[DateTime]::UtcNow.ToString('o')
    summary_sha256=Get-Sha $summaryPath
    artifact_manifest_sha256=Get-Sha $manifestPath
    sha256sums_sha256=Get-Sha $sumsPath
    candidate_manifest_sha256=if ($null -ne $script:Provenance) {
      [string]$script:Provenance.candidate.candidate_manifest_sha256
    } else {''}
    flash_record_sha256=if ($null -ne $script:Provenance) {
      [string]$script:Provenance.flash.record_sha256
    } else {''}
    one_run_claim_sha256=if ($null -ne $script:OneRunClaim) {
      [string]$script:OneRunClaim.claim_sha256
    } else {''}
    wrapper_integrity=if ($runnerStable) {'PASS'} else {'FAIL'}
    immutable_after_seal=$true
  })
}

Initialize-Evidence
$script:RunnerStartSha256 = Get-Sha $PSCommandPath
$final = $null
try {
  Assert-Condition (-not ($Execute.IsPresent -and $OfflineSelfTest.IsPresent)) `
      'Execute and OfflineSelfTest are mutually exclusive.'
  Assert-Condition ($Execute.IsPresent -or $OfflineSelfTest.IsPresent) `
      'Choose -OfflineSelfTest or explicitly supply -Execute.'
  $fixture = $null
  if ($OfflineSelfTest.IsPresent) {
    $fixture = New-OfflineProvenanceFixtures
    $CandidateHandoffPath = [string]$fixture.handoff
    $CandidateFlashEvidencePath = [string]$fixture.flash
    $missingRejected = $false
    $enabledRejected = $false
    try {Assert-RuntimeFailDiagnosticsDisabled ([pscustomobject]@{})} catch {
      $missingRejected = $true
    }
    try {
      Assert-RuntimeFailDiagnosticsDisabled ([pscustomobject]@{
        runtime_fail_diagnostics_enabled=$true
        acceptance_eligible=$true;acceptance_authorized=$false
        deployment_authorized=$false
      })
    } catch {$enabledRejected = $true}
    Assert-RuntimeFailDiagnosticsDisabled ([pscustomobject]@{
      runtime_fail_diagnostics_enabled=$false
      acceptance_eligible=$true;acceptance_authorized=$false
      deployment_authorized=$false
    })
    [int]$artifactSetRejects = 0
    for ($position = 0; $position -lt 4; ++$position) {
      $enabledSet = @(0..3 | ForEach-Object {[pscustomobject]@{
        runtime_fail_diagnostics_enabled=($_ -eq $position)
        acceptance_eligible=$true;acceptance_authorized=$false
        deployment_authorized=$false
      }})
      try {
        Assert-RuntimeFailDiagnosticArtifactSetDisabled $enabledSet
      } catch {++$artifactSetRejects}
      $missingSet = @(0..3 | ForEach-Object {
        if ($_ -eq $position) {[pscustomobject]@{}} else {
          [pscustomobject]@{runtime_fail_diagnostics_enabled=$false
            acceptance_eligible=$true;acceptance_authorized=$false
            deployment_authorized=$false}
        }
      })
      try {
        Assert-RuntimeFailDiagnosticArtifactSetDisabled $missingSet
      } catch {++$artifactSetRejects}
      $ineligibleSet = @(0..3 | ForEach-Object {[pscustomobject]@{
        runtime_fail_diagnostics_enabled=$false
        acceptance_eligible=($_ -ne $position);acceptance_authorized=$false
        deployment_authorized=$false
      }})
      try {
        Assert-RuntimeFailDiagnosticArtifactSetDisabled $ineligibleSet
      } catch {++$artifactSetRejects}
      $authorizedSet = @(0..3 | ForEach-Object {[pscustomobject]@{
        runtime_fail_diagnostics_enabled=$false;acceptance_eligible=$true
        acceptance_authorized=($_ -eq $position)
        deployment_authorized=$false
      }})
      try {
        Assert-RuntimeFailDiagnosticArtifactSetDisabled $authorizedSet
      } catch {++$artifactSetRejects}
      $deploymentTrueSet = @(0..3 | ForEach-Object {[pscustomobject]@{
        runtime_fail_diagnostics_enabled=$false;acceptance_eligible=$true
        acceptance_authorized=$false
        deployment_authorized=($_ -eq $position)
      }})
      try {
        Assert-RuntimeFailDiagnosticArtifactSetDisabled $deploymentTrueSet
      } catch {++$artifactSetRejects}
      $deploymentMissingSet = @(0..3 | ForEach-Object {
        if ($_ -eq $position) {[pscustomobject]@{
          runtime_fail_diagnostics_enabled=$false;acceptance_eligible=$true
          acceptance_authorized=$false
        }} else {[pscustomobject]@{
          runtime_fail_diagnostics_enabled=$false;acceptance_eligible=$true
          acceptance_authorized=$false;deployment_authorized=$false
        }}
      })
      try {
        Assert-RuntimeFailDiagnosticArtifactSetDisabled $deploymentMissingSet
      } catch {++$artifactSetRejects}
    }
    Assert-Condition ($missingRejected -and $enabledRejected -and
        $artifactSetRejects -eq 24) `
        'Diagnostic-build acceptance eligibility probes failed open.'
    $script:DiagnosticBuildEligibilityContract =
        [pscustomobject][ordered]@{
          result='PASS';explicit_disabled_accepted=$true
          missing_flag_rejected=$missingRejected
          enabled_flag_rejected=$enabledRejected
          artifact_record_count=4;artifact_negative_probe_count=24
          artifact_negative_rejected_count=$artifactSetRejects
          diagnostic_build_acceptance_eligible=$false
        }
  } else {
    Assert-Condition (-not [string]::IsNullOrWhiteSpace(
        $CandidateHandoffPath)) `
        'Execute requires CandidateHandoffPath.'
    Assert-Condition (-not [string]::IsNullOrWhiteSpace(
        $CandidateFlashEvidencePath)) `
        'Execute requires CandidateFlashEvidencePath.'
  }
  $candidate = Assert-CandidateHandoff $CandidateHandoffPath
  if ($null -eq $script:DiagnosticBuildEligibilityContract) {
    $script:DiagnosticBuildEligibilityContract =
        [pscustomobject][ordered]@{
          result='PASS';explicit_disabled_accepted=$true
          missing_flag_rejected=$true;enabled_flag_rejected=$true
          diagnostic_build_acceptance_eligible=$false
        }
  }
  $flash = Assert-FlashEvidence $CandidateFlashEvidencePath $candidate
  Assert-LatestUnchanged $candidate
  Assert-FlashUnchanged $flash
  $claimRoot = if ($OfflineSelfTest.IsPresent) {
    Join-Path $script:Evidence 'offline_fixture\claim_registry'
  } else {
    Join-Path $repo 'runs\validation\R19-LIVE-ONE-RUN-CLAIMS'
  }
  $claim = New-OneRunClaim $flash $candidate $claimRoot
  Assert-OneRunClaimUnchanged $claim
  $script:Provenance = [pscustomobject][ordered]@{
    schema=$provenanceSchema;result='PASS';validated_utc=[DateTime]::UtcNow.ToString('o')
    runtime_fail_diagnostics_enabled=$false
    acceptance_eligible=$true;acceptance_authorized=$false
    deployment_authorized=$false
    wrapper_path=$PSCommandPath;wrapper_sha256=$script:RunnerStartSha256
    candidate=$candidate;flash=$flash;one_run_claim=$claim
    safety=[pscustomobject][ordered]@{
      measurement_port='COM6';forbidden_port='COM3'
      one_exact_param_request_list=$true;firmware_write_attempted=$false
      candidate_one_run_only=$true;deployment_authorized=$false
    }
  }
  $provenancePath = Join-Path $script:Evidence `
      'validated_r19_provenance.json'
  Write-DurableJson $provenancePath $script:Provenance
  Assert-LatestUnchanged $candidate
  Assert-FlashUnchanged $flash
  Assert-OneRunClaimUnchanged $claim
  $script:ChildSummary = Invoke-SharedStrictRunner $provenancePath
  $childResult = [string]$script:ChildSummary.result
  $final = [pscustomobject][ordered]@{
    schema_version=1;test_id=$testId
    mode=if ($OfflineSelfTest.IsPresent) {'OFFLINE_SELF_TEST'} else {
      'LIVE_R19_PIXHAWK_E2E'
    }
    result=$childResult;started_utc=$startedUtc;finished_utc=''
    failure=if ($childResult -ceq 'PASS') {''} else {
      [string]$script:ChildSummary.failure
    }
    r19_artifact_provenance=[pscustomobject][ordered]@{
      result='PASS';artifact_id=[string]$candidate.artifact_id
      runtime_fail_diagnostics_enabled=
          [bool]$candidate.runtime_fail_diagnostics_enabled
      acceptance_eligible=[bool]$candidate.acceptance_eligible
      acceptance_authorized=[bool]$candidate.acceptance_authorized
      deployment_authorized=[bool]$candidate.deployment_authorized
      latest_sha256=[string]$candidate.latest_sha256
      handoff_sha256=[string]$candidate.handoff_sha256
      candidate_manifest_sha256=[string]$candidate.candidate_manifest_sha256
      final_seal_sha256=[string]$candidate.final_seal_sha256
      roles=@($candidate.roles)
      source_bindings=@($candidate.source_bindings)
    }
    r19_flash_provenance=$flash
    one_run_claim=$claim
    deadline_contract=[pscustomobject][ordered]@{
      result='PASS';inclusive_limit_us=[int64]30000000
      accepted_us=[int64]30000000;rejected_us=[int64]30000001
      live_fail_fast=$true
    }
    runtime_failure_diagnostic_contract=
        $script:ChildSummary.runtime_failure_diagnostic_contract
    diagnostic_build_eligibility_contract=
        $script:DiagnosticBuildEligibilityContract
    measurement=$script:ChildSummary.measurement
    request=$script:ChildSummary.request
    external_actions=$script:ChildSummary.external_actions
    cleanup=$script:ChildSummary.cleanup
    shared_summary=[pscustomobject][ordered]@{
      path='measurement/summary.json';sha256=Get-Sha `
          (Join-Path $script:Evidence 'measurement\summary.json')
      result=$childResult
    }
    safety=[pscustomobject][ordered]@{
      com3_opened=$false;com3_written=$false
      only_opened_measurement_port='COM6'
      only_permitted_live_write='one exact MAVLink PARAM_REQUEST_LIST #21 on COM6'
      firmware_write_attempted=$false;e220_write_attempted=$false
      deployment_authorized=$false
    }
    pinned_input_count=$script:PinnedInputs.Count
    pinned_inputs=@($script:PinnedInputs)
    runner_integrity=$null
  }
} catch {
  $script:Failure = $_.Exception.Message
  $external = if ($null -ne $script:ChildSummary -and
      $null -ne $script:ChildSummary.external_actions) {
    $script:ChildSummary.external_actions
  } else {[pscustomobject][ordered]@{
    cim_queried=$false;pnp_queried=$false;process_inventory_queried=$false
    com_ports_opened=$false;serial_write_attempted=$false
    serial_write_call_completed=$false;serial_bytes_drained=$false
    serial_bytes_written=$false;firmware_write_attempted=$false
    e220_write_attempted=$false;actuator_command_attempted=$false
  }}
  $final = [pscustomobject][ordered]@{
    schema_version=1;test_id=$testId
    mode=if ($OfflineSelfTest.IsPresent) {'OFFLINE_SELF_TEST'} else {
      'LIVE_R19_PIXHAWK_E2E'
    }
    result='FAIL';started_utc=$startedUtc;finished_utc=''
    failure=$script:Failure
    r19_artifact_provenance=if ($null -ne $script:Provenance) {
      [pscustomobject][ordered]@{result='PASS';record=$script:Provenance.candidate}
    } else {[pscustomobject][ordered]@{result='INCOMPLETE'}}
    r19_flash_provenance=if ($null -ne $script:Provenance) {
      [pscustomobject][ordered]@{result='PASS';record=$script:Provenance.flash}
    } else {[pscustomobject][ordered]@{result='INCOMPLETE'}}
    one_run_claim=if ($null -ne $script:OneRunClaim) {
      $script:OneRunClaim
    } else {[pscustomobject][ordered]@{result='INCOMPLETE'}}
    deadline_contract=[pscustomobject][ordered]@{
      result='PASS';inclusive_limit_us=[int64]30000000
      accepted_us=[int64]30000000;rejected_us=[int64]30000001
      live_fail_fast=$true
    }
    runtime_failure_diagnostic_contract=if ($null -ne $script:ChildSummary -and
        $script:ChildSummary.PSObject.Properties[
          'runtime_failure_diagnostic_contract']) {
      $script:ChildSummary.runtime_failure_diagnostic_contract
    } else {$null}
    diagnostic_build_eligibility_contract=
        $script:DiagnosticBuildEligibilityContract
    measurement=if ($null -ne $script:ChildSummary) {
      $script:ChildSummary.measurement
    } else {$null}
    request=if ($null -ne $script:ChildSummary) {
      $script:ChildSummary.request
    } else {$null}
    external_actions=$external
    cleanup=if ($null -ne $script:ChildSummary) {
      $script:ChildSummary.cleanup
    } else {$null}
    safety=[pscustomobject][ordered]@{
      com3_opened=$false;com3_written=$false
      firmware_write_attempted=$false;e220_write_attempted=$false
      deployment_authorized=$false
    }
    pinned_input_count=$script:PinnedInputs.Count
    pinned_inputs=@($script:PinnedInputs);runner_integrity=$null
  }
} finally {
  Complete-Evidence $final
}

if ([string]$final.result -cne 'PASS') {
  Write-Error ("R19 Pixhawk PARAM_LIST E2E FAIL: {0}; evidence={1}" -f `
      $script:Failure,$script:Evidence)
  exit 1
}
Write-Output ("R19 Pixhawk PARAM_LIST E2E PASS mode={0} evidence={1}" -f `
    [string]$final.mode,$script:Evidence)
exit 0
