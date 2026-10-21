[CmdletBinding()]
param(
  [switch]$Execute,
  [switch]$Preflight,
  [ValidateSet('ground', 'vehicle')]
  [string]$Role,
  [string]$Address,
  [string]$ArtifactRoot,
  [string]$ArtifactId,
  [string]$ProbeSerial,
  [string]$ProbeUsbLocation,
  [string]$FlashEvidencePath,
  [string]$FlashEvidenceSha256,
  [string]$NmExecutable,
  [string]$NmSha256,
  [string]$OpenOcdExecutable,
  [string]$OpenOcdSha256,
  [string]$InterfaceConfig,
  [string]$InterfaceConfigSha256,
  [string]$TargetConfig,
  [string]$TargetConfigSha256,
  [string]$ScriptsRoot,
  [string]$FixturePath,
  [string]$OutputRoot,
  [switch]$OfflineExtendedRecordFixtureOnly,
  [switch]$OfflineNativeInvocationContractTest,
  [string]$NativeContractScript,
  [ValidateRange(0, 255)]
  [int]$NativeContractExitCode = 0,
  [ValidateRange(0, 60000)]
  [int]$NativeContractHangMilliseconds = 0,
  [ValidateRange(100, 10000)]
  [int]$NativeContractTimeoutMilliseconds = 5000
)

$ErrorActionPreference = 'Stop'
$script:R19FirstFailureDecoderPath=Join-Path $PSScriptRoot 'read_r19_first_usb_failure_record.ps1'
$PinnedOpenOcdSha256 = '7461DBBEC251F1D4A2189C3C57B74A45B2FE64DEC1EC1B9EDDCB348A2AB2EBAB'
$PinnedInterfaceConfigSha256 = '9C2201DDCDB416A471E8D7F8BF309E4F20C364BBF416CA67D6475A8495934722'
$PinnedTargetConfigSha256 = 'D140078D0505475C8D8732CDD57938D0B81AC3E7B770A1BE6EBE5DB29A7DB18B'
$PinnedOpenOcdScriptsTreeSha256 = '3FB3130F7D4B17FE870EA6532B3F8EB5B0F27F506F1953A1A4EC9E1369D7BB84'
$PinnedNmSha256 = 'AC8D55C45DBCAEFE082299357245D7F12786C61A4E3C06A8E21F31D6890FB29E'
$pinnedOpenOcdRoot = Join-Path $env:LOCALAPPDATA `
  'Arduino15\packages\esp32\tools\openocd-esp32\v0.12.0-esp32-20260424'
$pinnedOpenOcdPath = Join-Path $pinnedOpenOcdRoot 'bin\openocd.exe'
$pinnedScriptsRoot = Join-Path $pinnedOpenOcdRoot 'share\openocd\scripts'
$pinnedInterfaceConfigPath = Join-Path $pinnedScriptsRoot 'interface\esp_usb_jtag.cfg'
$pinnedTargetConfigPath = Join-Path $pinnedScriptsRoot 'target\esp32s3.cfg'
$pinnedNmPath = Join-Path $env:LOCALAPPDATA `
  'Arduino15\packages\esp32\tools\esp-x32\2601\bin\xtensa-esp32s3-elf-nm.exe'
$stageRecordBytes = 68
$fifoRecordBytes = 112
$fifoBusResetInterruptMask = [uint32]0x00000200
$stageNames = [ordered]@{
  0x0001 = 'SetupEntered'
  0x0002 = 'SerialBeginReturned'
  0x0004 = 'CadenceStarted'
  0x0008 = 'IdentityReady'
  0x0010 = 'E220ProfileChecked'
  0x0020 = 'StartupAllowed'
  0x0040 = 'E220NormalMode'
  0x0080 = 'AdapterReady'
  0x0100 = 'SetupComplete'
  0x0200 = 'LoopEntered'
  0x0400 = 'HostGateObserved'
  0x0800 = 'FrameStaged'
  0x1000 = 'WriteAttempted'
  0x2000 = 'WriteAccepted'
  0x4000 = 'FlushCompleted'
  0x8000 = 'TransportRecoveryEntered'
  0x10000 = 'TransportRecoveryCompleted'
}
$failureNames = @(
  'None', 'CadenceStartRejected', 'CadenceFailClosedObserved',
  'GroundBoundaryImpossible', 'GroundReservationEpochChanged',
  'GroundReservationDeadlineExpired', 'GroundReservationDeadlineOverflow',
  'GroundReservationFlushFailed', 'GroundReservationFlushEpochChanged',
  'GroundReservationFlushLate', 'FrameDeadlineExpired', 'StageRejected',
  'EpochChangedBeforeWrite', 'AcceptedBeyondRequest',
  'PublisherWriteStateInvalid', 'FlushDeadlineInvalidOrExpired',
  'FlushFailed', 'EpochChangedAfterFlush', 'FlushCompletedLate',
  'CadenceCommitRejected', 'AlivePublisherResetRejected',
  'GroundBoundaryHostLostWhileDraining',
  'GroundBoundaryHostAbsentWithIrreversiblePrefix',
  'GroundBoundaryEpochChanged', 'GroundBoundaryDeadlineExpired',
  'GroundBoundaryOrderedBacklogDiscardFailed',
  'GroundBoundaryHeldHeartbeatDiscardFailed',
  'GroundBoundaryEgressPumpInvalid', 'GroundBoundaryFlushFailed',
  'GroundBoundaryFlushEpochChanged', 'GroundBoundaryFlushLate'
)
$fifoFlushOutcomeNames = @(
  'None', 'Active', 'Success', 'Timeout', 'Abort'
)
$fifoFlagNames = [ordered]@{
  0x00000001 = 'Initialized'
  0x00000002 = 'ObservationActive'
  0x00000004 = 'Connected'
  0x00000008 = 'FifoWritable'
  0x00000010 = 'PayloadInFlight'
  0x00000020 = 'FifoQuarantined'
  0x00000040 = 'ResetPending'
  0x00000080 = 'BootstrapFence'
  0x00000100 = 'BootstrapAborted'
  0x00000200 = 'DebugWriterActive'
  0x00000400 = 'FlushActive'
  0x00000800 = 'PayloadPublishPending'
  0x00001000 = 'PayloadPublishAborted'
  0x00002000 = 'PayloadFlushPending'
}
$fifoFlushBlockerNames = [ordered]@{
  0x00000001 = 'HostAbsent'
  0x00000002 = 'EpochMismatch'
  0x00000004 = 'SoftwarePending'
  0x00000008 = 'FifoNotWritable'
  0x00000010 = 'PayloadPickupPending'
  0x00000020 = 'Quarantined'
  0x00000040 = 'ResetPending'
  0x00000080 = 'Uninitialized'
}

function Get-Sha256 {
  param([Parameter(Mandatory)][string]$LiteralPath)
  $stream = [IO.File]::OpenRead($LiteralPath)
  try {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
      ([BitConverter]::ToString($algorithm.ComputeHash($stream)) -replace '-', '')
    } finally {
      $algorithm.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Assert-Hash {
  param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [Parameter(Mandatory)][string]$Expected,
    [Parameter(Mandatory)][string]$Label
  )
  if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
    throw "$Label does not exist: $LiteralPath"
  }
  if ($Expected -notmatch '^[0-9A-Fa-f]{64}$') {
    throw "$Label expected SHA-256 is invalid"
  }
  $actual = Get-Sha256 $LiteralPath
  if ($actual -ne $Expected.ToUpperInvariant()) {
    throw "$Label SHA-256 mismatch"
  }
  $actual
}

function Get-DirectoryTreeSha256 {
  param([Parameter(Mandatory)][string]$LiteralPath)
  $resolvedRoot = (Resolve-Path -LiteralPath $LiteralPath).Path
  [string[]]$lines = @(Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse |
    Sort-Object FullName | ForEach-Object {
      $relative = $_.FullName.Substring($resolvedRoot.Length + 1).Replace('\', '/')
      $hash = Get-Sha256 $_.FullName
      "$relative`t$hash"
    })
  $body = [string]::Join([Environment]::NewLine, $lines) + [Environment]::NewLine
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($body)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

function Assert-PinnedPathAndHash {
  param(
    [Parameter(Mandatory)][string]$SuppliedPath,
    [Parameter(Mandatory)][string]$SuppliedSha256,
    [Parameter(Mandatory)][string]$PinnedPath,
    [Parameter(Mandatory)][string]$PinnedSha256,
    [Parameter(Mandatory)][string]$Label
  )
  $actualPath = (Resolve-Path -LiteralPath $SuppliedPath).Path
  $trustedPath = (Resolve-Path -LiteralPath $PinnedPath).Path
  if (-not $actualPath.Equals($trustedPath, [StringComparison]::OrdinalIgnoreCase) -or
      $SuppliedSha256.ToUpperInvariant() -ne $PinnedSha256) {
    throw "$Label is not the reviewed pinned path/hash"
  }
  [void](Assert-Hash $actualPath $PinnedSha256 $Label)
}

function Assert-PinnedToolchain {
  $actualScriptsRoot = (Resolve-Path -LiteralPath $ScriptsRoot).Path
  $trustedScriptsRoot = (Resolve-Path -LiteralPath $pinnedScriptsRoot).Path
  if (-not $actualScriptsRoot.Equals(
      $trustedScriptsRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OpenOCD scripts root is not the reviewed pinned path'
  }
  Assert-PinnedPathAndHash $OpenOcdExecutable $OpenOcdSha256 `
    $pinnedOpenOcdPath $PinnedOpenOcdSha256 'OpenOCD executable'
  Assert-PinnedPathAndHash $InterfaceConfig $InterfaceConfigSha256 `
    $pinnedInterfaceConfigPath $PinnedInterfaceConfigSha256 'OpenOCD interface config'
  Assert-PinnedPathAndHash $TargetConfig $TargetConfigSha256 `
    $pinnedTargetConfigPath $PinnedTargetConfigSha256 'OpenOCD target config'
  Assert-PinnedPathAndHash $NmExecutable $NmSha256 `
    $pinnedNmPath $PinnedNmSha256 'Xtensa nm executable'
  $scriptsTreeSha = Get-DirectoryTreeSha256 $pinnedScriptsRoot
  if ($scriptsTreeSha -ne $PinnedOpenOcdScriptsTreeSha256) {
    throw 'OpenOCD scripts tree differs from the reviewed pinned tree'
  }
}

function Assert-PinnedPreflightToolchain {
  $actualScriptsRoot = (Resolve-Path -LiteralPath $ScriptsRoot).Path
  $trustedScriptsRoot = (Resolve-Path -LiteralPath $pinnedScriptsRoot).Path
  if (-not $actualScriptsRoot.Equals(
      $trustedScriptsRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OpenOCD scripts root is not the reviewed pinned path'
  }
  Assert-PinnedPathAndHash $OpenOcdExecutable $OpenOcdSha256 `
    $pinnedOpenOcdPath $PinnedOpenOcdSha256 'OpenOCD executable'
  Assert-PinnedPathAndHash $InterfaceConfig $InterfaceConfigSha256 `
    $pinnedInterfaceConfigPath $PinnedInterfaceConfigSha256 `
    'OpenOCD interface config'
  $scriptsTreeSha = Get-DirectoryTreeSha256 $pinnedScriptsRoot
  if ($scriptsTreeSha -ne $PinnedOpenOcdScriptsTreeSha256) {
    throw 'OpenOCD scripts tree differs from the reviewed pinned tree'
  }
}

function Require-LiveParameter {
  param([Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "missing live parameter: -$Name"
  }
}

function Assert-ProbeBindingSyntax {
  if ($ProbeSerial -notmatch '^[A-Fa-f0-9]{2}(?::[A-Fa-f0-9]{2}){5}$') {
    throw 'ProbeSerial must be the exact colon-delimited USB serial/MAC'
  }
  if ($ProbeUsbLocation -notmatch '^\d{1,3}-\d{1,3}(?:\.\d{1,3})*$') {
    throw 'ProbeUsbLocation must use OpenOCD bus-port[.port] format'
  }
}

function Convert-HexAddress {
  param([Parameter(Mandatory)][string]$Value)
  if ($Value -notmatch '^0x[0-9A-Fa-f]{8}$') {
    throw 'Address must be an exact 32-bit hexadecimal value such as 0x3fcab470'
  }
  [Convert]::ToUInt32($Value.Substring(2), 16)
}

function Convert-Words {
  param(
    [Parameter(Mandatory)][byte[]]$Bytes,
    [Parameter(Mandatory)][int]$ExpectedBytes,
    [Parameter(Mandatory)][int]$WordCount,
    [Parameter(Mandatory)][string]$Label
  )
  if ($Bytes.Length -ne $ExpectedBytes) {
    throw "$Label record must be exactly $ExpectedBytes bytes"
  }
  [uint32[]]$words = [uint32[]]::new($WordCount)
  for ($index = 0; $index -lt $words.Length; ++$index) {
    $words[$index] = [BitConverter]::ToUInt32($Bytes, $index * 4)
  }
  $words
}

function New-BuiltinFixtureBytes {
  [uint32[]]$words = @(
    0, 24, 0x52313953, 1, 2,
    0x52313944, 0x53544731, 0x32303236, 0x31303033,
    0x7FFF, 1, 11, 2, 3, 0, 0, 0
  )
  $stageBytes = [byte[]]::new($stageRecordBytes)
  for ($index = 0; $index -lt $words.Count; ++$index) {
    [BitConverter]::GetBytes($words[$index]).CopyTo($stageBytes, $index * 4)
  }
  [uint32[]]$fifoWords = @(
    0, 40, 0x48313946, 2, 0x0000000F, 2,
    2, 64, 0, 32, 3, 2, 2, 2, 2, 0,
    2, 2, 0, 1, 0, 0, 0x80, 0,
    2, 1, 0, 0
  )
  $fifoBytes = [byte[]]::new($fifoRecordBytes)
  for ($index = 0; $index -lt $fifoWords.Count; ++$index) {
    [BitConverter]::GetBytes($fifoWords[$index]).CopyTo($fifoBytes, $index * 4)
  }
  [pscustomobject]@{ stage = $stageBytes; endpoint_fifo = $fifoBytes }
}

function Read-OfflineFixture {
  param([string]$LiteralPath)
  if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
    $bytes = New-BuiltinFixtureBytes
    return [pscustomobject]@{
      artifact_id = 'builtin-offline-fixture'
      role = 'vehicle'
      runtime_stage_address = '0x3fcab470'
      endpoint_fifo_address = '0x3fcab4b4'
      stage_first = $bytes.stage
      stage_second = $bytes.stage
      fifo_first = $bytes.endpoint_fifo
      fifo_second = $bytes.endpoint_fifo
    }
  }
  if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
    throw "fixture not found: $LiteralPath"
  }
  $fixture = Get-Content -LiteralPath $LiteralPath -Raw | ConvertFrom-Json
  if ($fixture.schema -cin @('vc-lora-r19-usb-extended-jtag-fixture-v1','vc-lora-r19-usb-extended-jtag-fixture-v2')) {
    return Read-ExtendedDiagnosticFixture -Fixture $fixture
  }
  if ($fixture.schema -ne 'vc-lora-r19-runtime-stage-jtag-fixture-v3') {
    throw 'fixture schema mismatch'
  }
  if ($fixture.role -notin @('ground', 'vehicle')) {
    throw 'fixture role is invalid'
  }
  foreach($name in @('hwcdc_restart_address','ground_usb_commit_address','hwcdc_restart_first_read_base64','ground_usb_commit_first_read_base64','hwcdc_restart_second_read_base64','ground_usb_commit_second_read_base64','first_usb_failure_address','first_usb_failure_first_read_base64','first_usb_failure_second_read_base64')) {
    if($fixture.PSObject.Properties[$name]) {throw 'legacy fixture has undeclared extended diagnostic fields'}
  }
  [uint32]$stageAddress = Convert-HexAddress (
    [string]$fixture.runtime_stage_address)
  [uint32]$fifoAddress = Convert-HexAddress (
    [string]$fixture.endpoint_fifo_address)
  if (($stageAddress -band 3) -ne 0 -or ($fifoAddress -band 3) -ne 0) {
    throw 'fixture diagnostic record addresses must be 32-bit aligned'
  }
  [uint64]$stageEnd = [uint64]$stageAddress + $stageRecordBytes
  [uint64]$fifoEnd = [uint64]$fifoAddress + $fifoRecordBytes
  if ([uint64]$stageAddress -lt $fifoEnd -and
      [uint64]$fifoAddress -lt $stageEnd) {
    throw 'fixture diagnostic record address ranges overlap'
  }
  $stageFirst = [Convert]::FromBase64String(
    [string]$fixture.runtime_stage_first_read_base64)
  $stageSecond = [Convert]::FromBase64String(
    [string]$fixture.runtime_stage_second_read_base64)
  $fifoFirst = [Convert]::FromBase64String(
    [string]$fixture.endpoint_fifo_first_read_base64)
  $fifoSecond = [Convert]::FromBase64String(
    [string]$fixture.endpoint_fifo_second_read_base64)
  [pscustomobject]@{
    artifact_id = [string]$fixture.artifact_id
    role = [string]$fixture.role
    runtime_stage_address = ('0x{0:x8}' -f $stageAddress)
    endpoint_fifo_address = ('0x{0:x8}' -f $fifoAddress)
    stage_first = $stageFirst
    stage_second = $stageSecond
    fifo_first = $fifoFirst
    fifo_second = $fifoSecond
  }
}

function Read-ExtendedDiagnosticFixture {
  param([object]$Fixture)
  if($Fixture.role-notin@('ground','vehicle')-or[string]::IsNullOrWhiteSpace([string]$Fixture.artifact_id)){throw 'extended fixture identity is invalid'}
  $sizes=@{runtime_stage=68;endpoint_fifo=112;hwcdc_restart=128;ground_usb_commit=128}
  $firstEnabled=$Fixture.schema-ceq'vc-lora-r19-usb-extended-jtag-fixture-v2'
  $names=@('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit')
  if($firstEnabled){$sizes.first_usb_failure=384;$names+=@('first_usb_failure')}
  else{foreach($key in @('first_usb_failure_address','first_usb_failure_first_read_base64','first_usb_failure_second_read_base64')){if($Fixture.PSObject.Properties[$key]){throw 'v1 fixture contains undeclared first failure record'}}}
  $ranges=[Collections.Generic.List[object]]::new()
  $result=[ordered]@{artifact_id=$Fixture.artifact_id;role=$Fixture.role;extended_records_enabled=$true;first_usb_failure_enabled=$firstEnabled}
  foreach($name in $names) {
    $address=Convert-HexAddress ([string]$Fixture.($name+'_address')); [uint64]$end=[uint64]$address+$sizes[$name]
    if(($address-band3)-ne0-or$end-gt4294967296){throw 'extended fixture address is unaligned or overflows'}
    foreach($range in $ranges){if([uint64]$address-lt$range.end-and$range.start-lt$end){throw 'extended fixture records overlap'}}
    $ranges.Add([pscustomobject]@{start=[uint64]$address;end=$end})
    $result[$name+'_address']=('0x{0:x8}'-f$address)
    foreach($sample in @('first','second')) {
      $key=$name+'_'+$sample+'_read_base64'
      if(-not$Fixture.PSObject.Properties[$key]){throw "extended fixture lacks $key"}
      $bytes=[Convert]::FromBase64String([string]$Fixture.$key)
      if($bytes.Length-ne$sizes[$name]){throw "extended fixture $key has wrong size"}
      $recordKey=switch($name){'runtime_stage'{'stage'} 'endpoint_fifo'{'fifo'} default{$name}}
      $resultKey=$recordKey+'_'+$sample
      $result[$resultKey]=$bytes
    }
  }
  [pscustomobject]$result
}

function Assert-ArtifactBinding {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$ExpectedArtifactId,
    [Parameter(Mandatory)][string]$ExpectedRole,
    [Parameter(Mandatory)][uint32]$ExpectedAddress
  )
  $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
  $manifestPath = Join-Path $resolvedRoot 'candidate_manifest.json'
  $sealPath = Join-Path $resolvedRoot 'final_seal.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $sealPath -PathType Leaf)) {
    throw 'sealed candidate manifest files are missing'
  }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $seal = Get-Content -LiteralPath $sealPath -Raw | ConvertFrom-Json
  if ($manifest.result -ne 'PASS' -or $seal.result -ne 'PASS' -or
      -not $manifest.runtime_fail_diagnostics_enabled -or
      -not $seal.runtime_fail_diagnostics_enabled -or
      $manifest.artifact_id -ne $ExpectedArtifactId -or
      $seal.artifact_id -ne $ExpectedArtifactId) {
    throw 'candidate identity or diagnostic mode mismatch'
  }
  $manifestSha = Get-Sha256 $manifestPath
  if ($manifestSha -ne ([string]$seal.candidate_manifest_sha256).ToUpperInvariant()) {
    throw 'candidate manifest does not match final seal'
  }
  $matches = @($manifest.roles | Where-Object { $_.role -eq $ExpectedRole })
  if ($matches.Count -ne 1) {
    throw 'candidate role binding is not unique'
  }
  $roleEntry = $matches[0]
  $elfItems = @($roleEntry.reproducibility_artifacts.files | Where-Object {
      $_.path -match '/application\.elf$'
    })
  $mapItems = @($roleEntry.reproducibility_artifacts.files | Where-Object {
      $_.path -match '/application\.map$'
    })
  if ($elfItems.Count -ne 1 -or $mapItems.Count -ne 1) {
    throw 'candidate ELF/MAP binding is not unique'
  }
  $elfPath = Join-Path $resolvedRoot ([string]$elfItems[0].path).Replace('/', '\')
  $mapPath = Join-Path $resolvedRoot ([string]$mapItems[0].path).Replace('/', '\')
  [void](Assert-Hash $elfPath ([string]$elfItems[0].sha256) 'application ELF')
  [void](Assert-Hash $mapPath ([string]$mapItems[0].sha256) 'application MAP')
  [void](Assert-Hash $NmExecutable $NmSha256 'Xtensa nm executable')
  $nmOutput = & $NmExecutable '-S' '--defined-only' $elfPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Xtensa nm failed with exit code $LASTEXITCODE"
  }
  $stageSymbolMatches = [regex]::Matches(
    ($nmOutput -join "`n"),
    '(?m)^([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})\s+[Bb]\s+vc_lora_r19_runtime_stage_record\s*$')
  $fifoSymbolMatches = [regex]::Matches(
    ($nmOutput -join "`n"),
    '(?m)^([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})\s+[Bb]\s+vc_lora_r19_hwcdc_fifo_diagnostic_record\s*$')
  $restartSymbolMatches = [regex]::Matches(($nmOutput -join "`n"),
    '(?m)^([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})\s+[Bb]\s+vc_lora_r19_hwcdc_restart_diagnostic_record\s*$')
  $commitSymbolMatches = [regex]::Matches(($nmOutput -join "`n"),
    '(?m)^([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})\s+[Bb]\s+vc_lora_r19_ground_usb_commit_record\s*$')
  $firstFailureSymbolMatches=[regex]::Matches(($nmOutput-join"`n"),
    '(?m)^([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})\s+[Bb]\s+vc_lora_r19_first_usb_failure_record\s*$')
  $strictBCounts=@{
    vc_lora_r19_hwcdc_restart_diagnostic_record=$restartSymbolMatches.Count
    vc_lora_r19_ground_usb_commit_record=$commitSymbolMatches.Count
    vc_lora_r19_first_usb_failure_record=$firstFailureSymbolMatches.Count
  }
  foreach($symbolName in $strictBCounts.Keys){
    # GNU nm -S may omit a size for defined absolute/zero-size symbols. Such a
    # canonical name still exists and must not vanish from declaration checks.
    $allDefined=[regex]::Matches(($nmOutput-join"`n"),('(?m)^[0-9a-fA-F]{8}\s+(?:[0-9a-fA-F]{8}\s+)?\S\s+'+[regex]::Escape($symbolName)+'\s*$'))
    if($allDefined.Count-ne$strictBCounts[$symbolName]){throw 'defined diagnostic extension symbol has unsupported NM storage/size layout'}
  }
  $extendedBinding = Assert-ExtendedArtifactBinding -Manifest $manifest -Seal $seal `
    -Root $resolvedRoot -RoleEntry $roleEntry -ExpectedRole $ExpectedRole `
    -StageMatches $stageSymbolMatches -FifoMatches $fifoSymbolMatches `
    -RestartMatches $restartSymbolMatches -CommitMatches $commitSymbolMatches -FirstFailureMatches $firstFailureSymbolMatches `
    -ElfSha256 (Get-Sha256 $elfPath) -MapSha256 (Get-Sha256 $mapPath)
  if ($stageSymbolMatches.Count -ne 1) {
    throw 'runtime stage symbol is absent or ambiguous in the sealed ELF'
  }
  if ($fifoSymbolMatches.Count -ne 1) {
    throw 'Endpoint FIFO diagnostic symbol is absent or ambiguous in the sealed ELF'
  }
  $stageSymbolAddress = [Convert]::ToUInt32(
    $stageSymbolMatches[0].Groups[1].Value, 16)
  $stageSymbolSize = [Convert]::ToUInt32(
    $stageSymbolMatches[0].Groups[2].Value, 16)
  $fifoSymbolAddress = [Convert]::ToUInt32(
    $fifoSymbolMatches[0].Groups[1].Value, 16)
  $fifoSymbolSize = [Convert]::ToUInt32(
    $fifoSymbolMatches[0].Groups[2].Value, 16)
  if ($stageSymbolSize -ne 0x44) {
    throw 'runtime stage symbol size is not the required 68 bytes'
  }
  if ($fifoSymbolSize -ne 0x70) {
    throw 'Endpoint FIFO diagnostic symbol size is not the required 112 bytes'
  }
  if (($stageSymbolAddress -band 3) -ne 0 -or
      ($fifoSymbolAddress -band 3) -ne 0) {
    throw 'diagnostic symbol address is not 32-bit aligned'
  }
  [uint64]$stageSymbolEnd = [uint64]$stageSymbolAddress + $stageSymbolSize
  [uint64]$fifoSymbolEnd = [uint64]$fifoSymbolAddress + $fifoSymbolSize
  if ([uint64]$stageSymbolAddress -lt $fifoSymbolEnd -and
      [uint64]$fifoSymbolAddress -lt $stageSymbolEnd) {
    throw 'diagnostic symbols overlap in the sealed ELF'
  }
  if ($stageSymbolAddress -ne $ExpectedAddress) {
    throw 'requested address does not match the sealed runtime stage symbol'
  }
  $sealApplicationProperty = if ($ExpectedRole -eq 'ground') {
    'ground_application_sha256'
  } else {
    'vehicle_application_sha256'
  }
  $applicationSha = ([string]$roleEntry.application.sha256).ToUpperInvariant()
  if ($applicationSha -ne ([string]$seal.$sealApplicationProperty).ToUpperInvariant()) {
    throw 'role application does not match final seal'
  }
  $binding = [pscustomobject]@{
    root = $resolvedRoot
    artifact_id = $ExpectedArtifactId
    role = $ExpectedRole
    address = ('0x{0:x8}' -f $stageSymbolAddress)
    runtime_stage_address = ('0x{0:x8}' -f $stageSymbolAddress)
    endpoint_fifo_address = ('0x{0:x8}' -f $fifoSymbolAddress)
    manifest_path = $manifestPath
    manifest_sha256 = $manifestSha
    final_seal_path = $sealPath
    final_seal_sha256 = Get-Sha256 $sealPath
    application_sha256 = $applicationSha
    application_size_bytes = [int64]$roleEntry.application.size_bytes
    first_usb_failure_enabled = [bool]$extendedBinding.first_usb_failure_enabled
    elf_path = $elfPath
    elf_sha256 = Get-Sha256 $elfPath
    symbol_size_bytes = $stageSymbolSize
    symbols = [ordered]@{
      runtime_stage = [ordered]@{
        name = 'vc_lora_r19_runtime_stage_record'
        address = ('0x{0:x8}' -f $stageSymbolAddress)
        size_bytes = $stageSymbolSize
        aligned_32_bit = $true
      }
      endpoint_fifo = [ordered]@{
        name = 'vc_lora_r19_hwcdc_fifo_diagnostic_record'
        address = ('0x{0:x8}' -f $fifoSymbolAddress)
        size_bytes = $fifoSymbolSize
        aligned_32_bit = $true
      }
    }
    nm_path = (Resolve-Path $NmExecutable).Path
    nm_sha256 = Get-Sha256 $NmExecutable
    map_path = $mapPath
    map_sha256 = Get-Sha256 $mapPath
  }
  if ($extendedBinding.enabled) {
    $binding | Add-Member -NotePropertyName extended_records_enabled -NotePropertyValue $true
    $binding | Add-Member -NotePropertyName extended_record_metadata -NotePropertyValue $extendedBinding.metadata
    $binding | Add-Member -NotePropertyName hwcdc_restart_address -NotePropertyValue $extendedBinding.metadata.symbols.hwcdc_restart.address
    $binding | Add-Member -NotePropertyName ground_usb_commit_address -NotePropertyValue $extendedBinding.metadata.symbols.ground_usb_commit.address
    $binding | Add-Member -NotePropertyName handoff_path -NotePropertyValue $extendedBinding.handoff_path
    $binding | Add-Member -NotePropertyName handoff_sha256 -NotePropertyValue $extendedBinding.handoff_sha256
    $binding.symbols['hwcdc_restart']=$extendedBinding.metadata.symbols.hwcdc_restart
    $binding.symbols['ground_usb_commit']=$extendedBinding.metadata.symbols.ground_usb_commit
    if($extendedBinding.first_usb_failure_enabled){
      $binding|Add-Member -NotePropertyName first_usb_failure_address -NotePropertyValue $extendedBinding.metadata.symbols.first_usb_failure.address
      $binding|Add-Member -NotePropertyName first_usb_failure_decoder -NotePropertyValue $extendedBinding.decoder
      $binding.symbols['first_usb_failure']=$extendedBinding.metadata.symbols.first_usb_failure
    }
  }
  $binding
}

function Assert-ExactProperties {
  param([object]$Object,[string[]]$Names,[string]$Label)
  if ($null -eq $Object -or $Object -is [string] -or $Object -is [array] -or
      @($Object.PSObject.Properties.Name).Count -ne $Names.Count) { throw "$Label properties are incomplete or unexpected" }
  foreach($name in $Names) { if(@($Object.PSObject.Properties.Name)-cnotcontains$name) {throw "$Label lacks exact property $name"} }
}

function Test-ExactDiagnosticInteger {
  param([object]$Value,[uint32]$Expected)
  ($Value-is[int] -or $Value-is[long] -or $Value-is[uint32] -or $Value-is[uint64] -or
   $Value-is[short] -or $Value-is[ushort] -or $Value-is[byte] -or $Value-is[sbyte]) -and
    ([decimal]$Value-eq[decimal]$Expected)
}

function Assert-ExtendedArtifactReference {
  param([object]$Reference,[string]$ExpectedPath,[string]$ExpectedSha256,[string]$Label)
  Assert-ExactProperties $Reference @('path','sha256') $Label
  if($Reference.path-isnot[string]-or$Reference.sha256-isnot[string]-or$Reference.sha256-cne$ExpectedSha256){throw "$Label digest mismatch"}
  $normalized=([string]$Reference.path).Replace('/','\')
  if([IO.Path]::IsPathRooted($normalized)) {
    if(-not[IO.Path]::GetFullPath($normalized).Equals([IO.Path]::GetFullPath($ExpectedPath),[StringComparison]::OrdinalIgnoreCase)){throw "$Label path mismatch"}
  } else {
    if([string]::IsNullOrWhiteSpace($normalized)-or@($normalized.Split('\')|Where-Object{$_-in@('','.','..')}).Count-ne0-or
       -not[IO.Path]::GetFullPath($ExpectedPath).EndsWith(('\'+$normalized),[StringComparison]::OrdinalIgnoreCase)){throw "$Label relative path mismatch"}
  }
}

function Get-VerifiedFirstUsbDecoderText {
  param([string]$ExpectedSha256,[string]$ArtifactRoot)
  $paths=@($script:R19FirstFailureDecoderPath)
  if(-not[string]::IsNullOrWhiteSpace($ArtifactRoot)){$paths+=@(Join-Path $ArtifactRoot 'evidence/tools/read_r19_first_usb_failure_record.ps1')}
  $verifiedText=$null
  foreach($path in $paths){
    # Verify the exact bytes subsequently parsed, not a different reread path.
    [byte[]]$bytes=[IO.File]::ReadAllBytes($path)
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try{$sha=([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','')}finally{$algorithm.Dispose()}
    if(-not[string]::IsNullOrWhiteSpace($ExpectedSha256)-and$sha-cne$ExpectedSha256){throw 'first failure decoder dependency bytes/hash mismatch'}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    if($null-ne$verifiedText-and$verifiedText-cne$text){throw 'canonical and sealed decoder bytes differ'}
    $verifiedText=$text
    $script:R19LastVerifiedDecoderSha256=$sha
  }
  $verifiedText
}

function Assert-ExtendedArtifactBinding {
  param([object]$Manifest,[object]$Seal,[string]$Root,[object]$RoleEntry,[string]$ExpectedRole,
    [object]$StageMatches,[object]$FifoMatches,[object]$RestartMatches,[object]$CommitMatches,[object]$FirstFailureMatches=@(),
    [string]$ElfSha256,[string]$MapSha256)
  $handoffPath=Join-Path $Root 'handoff.json'
  $handoff=if(Test-Path -LiteralPath $handoffPath -PathType Leaf){Get-Content -LiteralPath $handoffPath -Raw|ConvertFrom-Json}else{$null}
  $documents=@($Manifest,$Seal,$handoff)
  $anyExtension=@($documents|Where-Object{$null-ne$_-and$_.PSObject.Properties['usb_extended_diagnostics']}).Count-gt0
  $anyMetadata=@($documents|Where-Object{$null-ne$_}|ForEach-Object{$_.roles}|Where-Object{$null-ne$_-and$_.PSObject.Properties['runtime_diagnostic_symbols']}).Count-gt0
  if(-not $anyExtension) {
    foreach($doc in $documents){if($null-ne$doc-and$doc.PSObject.Properties['reader_schema']-and@($doc.PSObject.Properties.Name)-cnotcontains'reader_schema'){throw 'legacy reader schema property case is invalid'}}
    $nonLegacyDeclared=@($documents|Where-Object{$null-ne$_-and$_.PSObject.Properties['reader_schema']-and$_.reader_schema-cne'vc-lora-r19-runtime-stage-jtag-read-v3'}).Count-gt0
    if($anyMetadata -or $nonLegacyDeclared -or $RestartMatches.Count-ne0 -or $CommitMatches.Count-ne0 -or $FirstFailureMatches.Count-ne0 -or @($documents|Where-Object{$null-ne$_-and$_.PSObject.Properties['first_usb_failure_decoder']}).Count-ne0) {throw 'extended diagnostic symbols or metadata are undeclared'}
    return [pscustomobject]@{enabled=$false;first_usb_failure_enabled=$false}
  }
  if($null-eq$handoff -or $handoff.artifact_id-ne$Manifest.artifact_id) {throw 'extended candidate handoff identity is missing or mismatched'}
  $handoffHashPath=Join-Path $Root 'handoff.sha256'
  if(-not(Test-Path -LiteralPath $handoffHashPath -PathType Leaf)){throw 'extended candidate handoff companion hash is missing'}
  $handoffHashMatch=[regex]::Match([IO.File]::ReadAllText($handoffHashPath),'\A([A-Fa-f0-9]{64}) \*handoff\.json\r?\n?\z')
  if(-not$handoffHashMatch.Success-or$handoffHashMatch.Groups[1].Value.ToUpperInvariant()-cne(Get-Sha256 $handoffPath)){throw 'extended candidate handoff companion hash mismatch'}
  Assert-ExtendedArtifactReference $handoff.candidate_manifest (Join-Path $Root 'candidate_manifest.json') (Get-Sha256 (Join-Path $Root 'candidate_manifest.json')) 'handoff candidate manifest'
  Assert-ExtendedArtifactReference $handoff.final_seal (Join-Path $Root 'final_seal.json') (Get-Sha256 (Join-Path $Root 'final_seal.json')) 'handoff final seal'
  $expected=@{
    runtime_stage=@('vc_lora_r19_runtime_stage_record',68,$StageMatches)
    endpoint_fifo=@('vc_lora_r19_hwcdc_fifo_diagnostic_record',112,$FifoMatches)
    hwcdc_restart=@('vc_lora_r19_hwcdc_restart_diagnostic_record',128,$RestartMatches)
    ground_usb_commit=@('vc_lora_r19_ground_usb_commit_record',128,$CommitMatches)
  }
  $firstEnabled=$Manifest.usb_extended_diagnostics.schema-ceq'vc-lora-r19-usb-extended-diagnostics-v2'
  $recordNames=@('hwcdc_restart','ground_usb_commit')
  $symbolNames=@('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit')
  $extensionSchema='vc-lora-r19-usb-extended-diagnostics-v1';$readerSchema='vc-lora-r19-runtime-stage-jtag-read-v4'
  if($firstEnabled){
    $recordNames+=@('first_usb_failure');$symbolNames+=@('first_usb_failure')
    $expected.first_usb_failure=@('vc_lora_r19_first_usb_failure_record',384,$FirstFailureMatches)
    $extensionSchema='vc-lora-r19-usb-extended-diagnostics-v2';$readerSchema='vc-lora-r19-runtime-stage-jtag-read-v5'
    $sourceFiles=@($Manifest.canonical_source_snapshot.files|Where-Object{$_.path-ceq'tools/read_r19_first_usb_failure_record.ps1'})
    if($sourceFiles.Count-ne1){throw 'first failure decoder canonical source binding is absent or ambiguous'}
    Assert-ExactProperties $sourceFiles[0] @('path','size_bytes','sha256') 'first failure decoder canonical source'
  }elseif($FirstFailureMatches.Count-ne0){throw 'fifth diagnostic symbol is undeclared by v1 contract'}
  $decoder=$null
  $metadataByDocument=[Collections.Generic.List[object]]::new()
  $documentIndex=0
  foreach($document in $documents) {
    $expectedSchema=@('vc-lora-r19-candidate-artifact-manifest-v1','vc-lora-r19-candidate-final-seal-v1','vc-lora-r19-candidate-artifact-handoff-v1')[$documentIndex++]
    if($document.schema-cne$expectedSchema-or$document.result-cne'PASS'-or$document.runtime_fail_diagnostics_enabled-isnot[bool]-or-not$document.runtime_fail_diagnostics_enabled){throw 'extended candidate document identity or diagnostic mode mismatch'}
    if(-not $document.PSObject.Properties['usb_extended_diagnostics']) {throw 'partial extended diagnostic declaration'}
    foreach($property in @('reader_schema','usb_extended_diagnostics','runtime_stage_size_bytes','endpoint_fifo_schema','endpoint_fifo_size_bytes')){
      if(@($document.PSObject.Properties.Name)-cnotcontains$property){throw 'extended top-level property is absent or has incorrect case'}
    }
    if($document.reader_schema-cne$readerSchema){throw 'extended reader schema conflicts with declared version'}
    if($firstEnabled){
      if(@($document.PSObject.Properties.Name)-cnotcontains'first_usb_failure_decoder'){throw 'first failure decoder pin missing or property case is invalid'}
      $pin=$document.first_usb_failure_decoder
      Assert-ExactProperties $pin @('path','sha256') 'first failure decoder pin'
      if($pin.path-cne'tools/read_r19_first_usb_failure_record.ps1'-or$pin.sha256-isnot[string]-or$pin.sha256-cnotmatch'^[A-F0-9]{64}$'){throw 'first failure decoder fixed path/hash invalid'}
      $verifiedText=Get-VerifiedFirstUsbDecoderText $pin.sha256 $Root
      if($sourceFiles[0].sha256-cne$pin.sha256-or-not(Test-ExactDiagnosticInteger $sourceFiles[0].size_bytes ([Text.Encoding]::UTF8.GetByteCount($verifiedText)))){throw 'first failure decoder canonical source digest or size mismatch'}
      if($null-ne$decoder-and$decoder.sha256-cne$pin.sha256){throw 'first failure decoder pins disagree'}
      $decoder=[pscustomobject]@{path=$pin.path;sha256=$pin.sha256}
      $script:R19FirstDecoderVerifiedText=$verifiedText
      $script:R19FirstDecoderVerifiedSha256=$pin.sha256
    }elseif($document.PSObject.Properties['first_usb_failure_decoder']){throw 'legacy contract has undeclared decoder pin'}
    if(-not(Test-ExactDiagnosticInteger $document.runtime_stage_size_bytes 68)-or
       -not(Test-ExactDiagnosticInteger $document.endpoint_fifo_schema 2)-or
       -not(Test-ExactDiagnosticInteger $document.endpoint_fifo_size_bytes 112)){throw 'extended declaration changes the legacy 68/112 ABI'}
    $extension=$document.usb_extended_diagnostics
    Assert-ExactProperties $extension @('schema','enabled','records') 'extended declaration'
    if($extension.schema-cne$extensionSchema -or
        $extension.enabled-isnot[bool] -or -not $extension.enabled) {throw 'extended diagnostic schema or enabled flag is invalid'}
    Assert-ExactProperties $extension.records $recordNames 'extended records'
    foreach($name in $recordNames) {
      $entry=$extension.records.$name
      Assert-ExactProperties $entry @('symbol','schema_version','size_bytes') 'extended record descriptor'
      if($entry.symbol-cne$expected[$name][0] -or -not(Test-ExactDiagnosticInteger $entry.schema_version 1) -or -not(Test-ExactDiagnosticInteger $entry.size_bytes $expected[$name][1])) {throw 'extended record descriptor is contradictory'}
    }
    $roles=@($document.roles|Where-Object{$_.role-eq$ExpectedRole})
    if($roles.Count-ne1 -or -not $roles[0].PSObject.Properties['runtime_diagnostic_symbols']) {throw 'extended role symbol metadata is absent or ambiguous'}
    $metadata=$roles[0].runtime_diagnostic_symbols
    Assert-ExactProperties $metadata @('schema','elf_sha256','map_sha256','application_sha256','symbols') 'extended symbol metadata'
    if($metadata.schema-cne'vc-lora-r19-runtime-diagnostic-symbols-v1' -or
        $metadata.elf_sha256-cne$ElfSha256 -or $metadata.map_sha256-cne$MapSha256 -or
        $metadata.application_sha256-cne([string]$RoleEntry.application.sha256).ToUpperInvariant()) {throw 'extended metadata ELF MAP or application digest mismatch'}
    Assert-ExactProperties $metadata.symbols $symbolNames 'extended symbol set'
    $ranges=[Collections.Generic.List[object]]::new()
    foreach($name in $symbolNames) {
      $symbol=$metadata.symbols.$name; $wanted=$expected[$name]; $nm=$wanted[2]
      Assert-ExactProperties $symbol @('name','address','size_bytes','aligned_32_bit') 'extended symbol'
      if($nm.Count-ne1) {throw "extended symbol $name is absent or ambiguous in sealed ELF"}
      $address=[Convert]::ToUInt32($nm[0].Groups[1].Value,16); $size=[Convert]::ToUInt32($nm[0].Groups[2].Value,16)
      [uint64]$end=[uint64]$address+[uint64]$size
      if($symbol.name-cne$wanted[0] -or $size-ne$wanted[1] -or -not(Test-ExactDiagnosticInteger $symbol.size_bytes $wanted[1]) -or
          $symbol.address-cne('0x{0:x8}'-f$address) -or ($address-band3)-ne0 -or
          $symbol.aligned_32_bit-isnot[bool] -or -not $symbol.aligned_32_bit -or $end-gt4294967296) {throw "extended symbol $name NM address size alignment binding mismatch"}
      foreach($range in $ranges) {if([uint64]$address-lt$range.end -and $range.start-lt$end){throw 'extended diagnostic symbols overlap'}}
      $ranges.Add([pscustomobject]@{start=[uint64]$address;end=$end})
    }
    $metadataByDocument.Add($metadata)
  }
  [pscustomobject]@{enabled=$true;first_usb_failure_enabled=$firstEnabled;decoder=$decoder;metadata=$metadataByDocument[0];handoff_path=$handoffPath;handoff_sha256=Get-Sha256 $handoffPath}
}

function Assert-FlashBinding {
  param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [Parameter(Mandatory)][string]$ExpectedFileSha,
    [Parameter(Mandatory)][object]$Artifact,
    [Parameter(Mandatory)][string]$ExpectedProbeSerial
  )
  if ($ExpectedProbeSerial -notmatch '^[A-Za-z0-9._:-]{4,128}$') {
    throw 'probe serial contains unsupported characters or is too short'
  }
  $fileSha = Assert-Hash $LiteralPath $ExpectedFileSha 'flash evidence'
  $binding = Get-Content -LiteralPath $LiteralPath -Raw | ConvertFrom-Json
  $roleEntries = @($binding.roles | Where-Object { $_.role -eq $Artifact.role })
  $allMacs = @($binding.roles | ForEach-Object {
      ([string]$_.mac).ToLowerInvariant()
    })
  $operationMatches = @($binding.operations | Where-Object {
      $_.role -eq $Artifact.role -and $_.kind -eq 'verify'
    })
  if ($binding.schema -ne 'vc-lora-r19-candidate-flash-evidence-v1' -or
      $binding.result -ne 'PASS' -or
      $binding.status -ne 'PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY' -or
      $binding.mode -ne 'Execute' -or
      -not $binding.runtime_fail_diagnostics_enabled -or
      $binding.acceptance_eligible -ne $false -or
      $binding.deployment_authorized -ne $false -or
      $binding.candidate.artifact_id -ne $Artifact.artifact_id -or
      ([string]$binding.candidate.candidate_manifest_sha256).ToUpperInvariant() -ne
        $Artifact.manifest_sha256 -or
      $binding.flash_policy.offset -ne '0x10000' -or
      $binding.flash_policy.app_only -ne $true -or
      $binding.flash_policy.erase_flash -ne $false -or
      $roleEntries.Count -ne 1 -or $roleEntries[0].write_pass -ne $true -or
      $roleEntries[0].verify_pass -ne $true -or
      $roleEntries[0].reenumeration_pass -ne $true -or
      [int64]$roleEntries[0].size_bytes -ne $Artifact.application_size_bytes -or
      ([string]$roleEntries[0].sha256).ToUpperInvariant() -ne
        $Artifact.application_sha256 -or
      [string]::IsNullOrWhiteSpace([string]$roleEntries[0].parent_device_id) -or
      (@($allMacs | Select-Object -Unique)).Count -ne $allMacs.Count -or
      ([string]$roleEntries[0].mac).ToLowerInvariant() -ne
        $ExpectedProbeSerial.ToLowerInvariant() -or
      -not ([string]$roleEntries[0].parent_device_id).ToLowerInvariant().EndsWith(
        ('\' + $ExpectedProbeSerial.ToLowerInvariant())) -or
      $operationMatches.Count -ne 1 -or $operationMatches[0].result -ne 'PASS') {
    throw 'flash evidence does not bind the exact candidate role/MAC/probe pair'
  }
  [pscustomobject]@{
    path = (Resolve-Path $LiteralPath).Path
    sha256 = $fileSha
    role = $Artifact.role
    port = [string]$roleEntries[0].port
    pnp_device_id = [string]$roleEntries[0].pnp_device_id
    parent_device_id = [string]$roleEntries[0].parent_device_id
    probe_serial = ([string]$roleEntries[0].mac).ToLowerInvariant()
    application_sha256 = ([string]$roleEntries[0].sha256).ToUpperInvariant()
  }
}

function Convert-TclPath {
  param([Parameter(Mandatory)][string]$LiteralPath)
  $resolved = [IO.Path]::GetFullPath($LiteralPath).Replace('\', '/')
  if ($resolved -match '[{}\r\n]') {
    throw 'path cannot be represented safely in the OpenOCD command'
  }
  '{' + $resolved + '}'
}

function ConvertTo-NativeCommandLineArgument {
  param([AllowEmptyString()][string]$Value)
  if ($null -eq $Value -or $Value.Length -eq 0) {
    return '""'
  }
  if ($Value -notmatch '[\s"]') {
    return $Value
  }
  $builder = [Text.StringBuilder]::new()
  [void]$builder.Append('"')
  $backslashes = 0
  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq '\') {
      ++$backslashes
      continue
    }
    if ($character -eq '"') {
      [void]$builder.Append([char]0x5C, (($backslashes * 2) + 1))
      [void]$builder.Append('"')
      $backslashes = 0
      continue
    }
    if ($backslashes -gt 0) {
      [void]$builder.Append([char]0x5C, $backslashes)
      $backslashes = 0
    }
    [void]$builder.Append($character)
  }
  if ($backslashes -gt 0) {
    [void]$builder.Append([char]0x5C, ($backslashes * 2))
  }
  [void]$builder.Append('"')
  $builder.ToString()
}

function Invoke-NativeProcessCapture {
  param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string[]]$Arguments,
    [Parameter(Mandatory)][string]$LogPath,
    [Parameter(Mandatory)][ValidateRange(100, 120000)][int]$TimeoutMilliseconds
  )
  $stdoutPath = $LogPath + '.stdout.log'
  $stderrPath = $LogPath + '.stderr.log'
  $stdout = ''
  $stderr = ''
  $exitCode = 125
  $timedOut = $false
  $started = $false
  $terminationProven = $false
  $launchFailure = ''
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
  $process.StartInfo.FileName = $Executable
  $process.StartInfo.Arguments = (@($Arguments | ForEach-Object {
        ConvertTo-NativeCommandLineArgument ([string]$_)
      }) -join ' ')
  $process.StartInfo.UseShellExecute = $false
  $process.StartInfo.CreateNoWindow = $true
  $process.StartInfo.RedirectStandardOutput = $true
  $process.StartInfo.RedirectStandardError = $true
  $stdoutTask = $null
  $stderrTask = $null
  try {
    $started = $process.Start()
    if (-not $started) {
      throw 'native process did not start'
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
      $timedOut = $true
      try {
        $process.Kill()
      } catch {
        $launchFailure = 'native timeout kill failed: ' + $_.Exception.Message
      }
      $terminationProven = $process.WaitForExit(5000)
      if ($terminationProven) {
        $process.WaitForExit()
        $process.Refresh()
      }
      $exitCode = 124
    } else {
      # The parameterless drain plus Refresh is required on Windows PowerShell
      # before ExitCode is treated as durable when both streams are redirected.
      $process.WaitForExit()
      $process.Refresh()
      $exitCode = [int]$process.ExitCode
      $terminationProven = $true
    }
  } catch {
    $launchFailure = $_.Exception.Message
    $exitCode = 125
    if ($started -and -not $process.HasExited) {
      try { $process.Kill() } catch {}
      try { $terminationProven = $process.WaitForExit(5000) } catch {}
    } elseif ($started) {
      $terminationProven = $true
    }
  } finally {
    if ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
      try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch {
        $launchFailure += ' stdout capture failed: ' + $_.Exception.Message
      }
    }
    if ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
      try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch {
        $launchFailure += ' stderr capture failed: ' + $_.Exception.Message
      }
    }
    $process.Dispose()
  }
  [IO.File]::WriteAllText($stdoutPath, $stdout, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($stderrPath, $stderr, [Text.UTF8Encoding]::new($false))
  $combined = '=== STDOUT ===' + [Environment]::NewLine + $stdout +
    [Environment]::NewLine + '=== STDERR ===' + [Environment]::NewLine +
    $stderr
  [IO.File]::WriteAllText($LogPath, $combined, [Text.UTF8Encoding]::new($false))
  [pscustomobject]@{
    started = $started
    exit_code = $exitCode
    timed_out = $timedOut
    termination_proven = $terminationProven
    launch_failure = $launchFailure.Trim()
    stdout_path = $stdoutPath
    stderr_path = $stderrPath
    combined_log_path = $LogPath
  }
}

function Assert-JtagPreflightLog {
  param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [Parameter(Mandatory)][string]$ExpectedProbeSerial,
    [Parameter(Mandatory)][string]$ExpectedUsbLocation
  )
  $text = [IO.File]::ReadAllText(
    $LiteralPath, [Text.UTF8Encoding]::new($false))
  $serialMatches = [regex]::Matches(
    $text, '(?im)^VC_LORA_JTAG_OPEN_SERIAL=([^\r\n]+)\r?$')
  $locationMatches = [regex]::Matches(
    $text, '(?im)^VC_LORA_JTAG_OPEN_LOCATION=([^\r\n]+)\r?$')
  if ($serialMatches.Count -ne 1 -or $locationMatches.Count -ne 1) {
    throw 'OpenOCD preflight did not report one opened serial and location'
  }
  $openedSerial = $serialMatches[0].Groups[1].Value.Trim()
  $openedLocation = $locationMatches[0].Groups[1].Value.Trim()
  if (-not $openedSerial.Equals(
      $ExpectedProbeSerial, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'opened JTAG serial does not match the role binding'
  }
  if (-not $openedLocation.Equals(
      $ExpectedUsbLocation, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'opened JTAG USB location does not match the role binding'
  }
  if ($text -notmatch '(?m)^VC_LORA_JTAG_PREFLIGHT_OPEN\r?$') {
    throw 'OpenOCD preflight open marker is absent'
  }
  if ($text -notmatch '(?m)^VC_LORA_JTAG_TRANSPORT_INIT_REQUESTED\r?$' -or
      $text -notmatch '(?m)^VC_LORA_JTAG_TRANSPORT_INIT_COMPLETED\r?$') {
    throw 'OpenOCD preflight transport-init markers are incomplete'
  }
  if ($text -notmatch '(?im)^shutdown command invoked\r?$') {
    throw 'OpenOCD preflight log does not prove shutdown'
  }
  [pscustomobject]@{
    serial = $openedSerial
    usb_location = $openedLocation
    open_marker_proven = $true
    transport_init_requested_proven = $true
    transport_init_completed_proven = $true
    shutdown_proven = $true
  }
}

function Invoke-JtagPreflight {
  param(
    [Parameter(Mandatory)][string]$LogPath
  )
  [void](Assert-Hash $OpenOcdExecutable $OpenOcdSha256 'OpenOCD executable')
  [void](Assert-Hash $InterfaceConfig $InterfaceConfigSha256 `
    'OpenOCD interface config')
  $arguments = @(
    '-s', (Resolve-Path $ScriptsRoot).Path,
    '-f', (Resolve-Path $InterfaceConfig).Path,
    '-c', "adapter serial $ProbeSerial",
    '-c', "adapter usb location $ProbeUsbLocation",
    '-c', 'echo VC_LORA_JTAG_PREFLIGHT_POLICY=TAP_INIT_POSSIBLE_NO_TARGET_CONFIG_NO_CPU_HALT_NO_SYSTEM_RESET_COMMAND',
    '-c', 'echo VC_LORA_JTAG_TRANSPORT_INIT_REQUESTED',
    '-c', 'transport init',
    '-c', 'echo VC_LORA_JTAG_TRANSPORT_INIT_COMPLETED',
    '-c', 'set vc_lora_serial [espusbjtag get_serial]; echo VC_LORA_JTAG_OPEN_SERIAL=$vc_lora_serial',
    '-c', 'set vc_lora_location [espusbjtag get_location]; echo VC_LORA_JTAG_OPEN_LOCATION=$vc_lora_location',
    '-c', 'echo VC_LORA_JTAG_PREFLIGHT_OPEN',
    '-c', 'shutdown'
  )
  $native = Invoke-NativeProcessCapture -Executable $OpenOcdExecutable `
    -Arguments $arguments -LogPath $LogPath -TimeoutMilliseconds 15000
  $identity = $null
  $proofError = ''
  if ($native.exit_code -eq 0 -and -not $native.timed_out -and
      $native.termination_proven) {
    try {
      $identity = Assert-JtagPreflightLog -LiteralPath $LogPath `
        -ExpectedProbeSerial $ProbeSerial `
        -ExpectedUsbLocation $ProbeUsbLocation
    } catch {
      $proofError = $_.Exception.Message
    }
  } else {
    $proofError = 'OpenOCD preflight process did not exit cleanly'
  }
  [pscustomobject]@{
    native = $native
    identity = $identity
    proof_error = $proofError
    open_proven = ($null -ne $identity)
    shutdown_proven = ($null -ne $identity -and $identity.shutdown_proven)
  }
}

function Invoke-OpenOcdCleanup {
  param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string[]]$CommonArguments,
    [Parameter(Mandatory)][string]$LogPath
  )
  $arguments = $CommonArguments + @(
    '-c', 'init',
    '-c', 'catch { resume }',
    '-c', 'sleep 20',
    '-c', 'echo VC_LORA_RESUME_CPU0; echo VC_LORA_RESUME_CURSTATE_CPU0=[esp32s3.cpu0 curstate]',
    '-c', 'echo VC_LORA_RESUME_CPU1; echo VC_LORA_RESUME_CURSTATE_CPU1=[esp32s3.cpu1 curstate]',
    '-c', 'shutdown'
  )
  $native = Invoke-NativeProcessCapture -Executable $Executable `
    -Arguments $arguments -LogPath $LogPath -TimeoutMilliseconds 30000
  $proof = $false
  if ($native.exit_code -eq 0 -and -not $native.timed_out -and
      $native.termination_proven) {
    try {
      Assert-SmpCleanupLog $LogPath
      $proof = $true
    } catch {
      $proof = $false
    }
  }
  [pscustomobject]@{
    required = $true
    attempted = $true
    exit_code = [int]$native.exit_code
    timed_out = [bool]$native.timed_out
    process_termination_proven = [bool]$native.termination_proven
    launch_failure = [string]$native.launch_failure
    stdout_path = [string]$native.stdout_path
    stderr_path = [string]$native.stderr_path
    resume_shutdown_proven = $proof
    skipped_due_to_pre_attach_failure = $false
    skipped_due_to_unproven_capture_termination = $false
  }
}

function Assert-SmpCurstate {
  param(
    [Parameter(Mandatory)][string]$Text,
    [Parameter(Mandatory)][ValidateSet('HALT', 'RESUME')][string]$Phase,
    [Parameter(Mandatory)][ValidateSet('halted', 'running')]
    [string]$ExpectedState
  )
  foreach ($cpu in @(0, 1)) {
    $marker = "VC_LORA_${Phase}_CURSTATE_CPU$cpu"
    $matches = [regex]::Matches(
      $Text, '(?m)^' + [regex]::Escape($marker) + '=([^\r\n]+)\r?$')
    if ($matches.Count -ne 1) {
      throw "CPU$cpu $Phase curstate marker count $($matches.Count); expected 1"
    }
    $state = $matches[0].Groups[1].Value.Trim()
    if ($state -cne $ExpectedState) {
      throw "CPU$cpu $Phase curstate expected $ExpectedState but observed $state"
    }
  }
}

function Assert-SmpHaltedCurstate {
  param([Parameter(Mandatory)][string]$Text)
  Assert-SmpCurstate -Text $Text -Phase 'HALT' -ExpectedState 'halted'
}

function Assert-SmpRunningCurstate {
  param([Parameter(Mandatory)][string]$Text)
  Assert-SmpCurstate -Text $Text -Phase 'RESUME' -ExpectedState 'running'
}

function Assert-SmpCaptureLog {
  param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [Parameter(Mandatory)][string]$ExpectedProbeSerial,
    [Parameter(Mandatory)][string]$ExpectedUsbLocation
  )
  $text = [IO.File]::ReadAllText(
    $LiteralPath, [Text.UTF8Encoding]::new($false))
  $serialMatches = [regex]::Matches(
    $text, '(?im)^VC_LORA_JTAG_OPEN_SERIAL=([^\r\n]+)\s*$')
  $locationMatches = [regex]::Matches(
    $text, '(?im)^VC_LORA_JTAG_OPEN_LOCATION=([^\r\n]+)\s*$')
  if ($serialMatches.Count -ne 1 -or $locationMatches.Count -ne 1) {
    throw 'OpenOCD capture did not report one opened serial and location'
  }
  if (-not $serialMatches[0].Groups[1].Value.Trim().Equals(
      $ExpectedProbeSerial, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'capture JTAG serial does not match the role binding'
  }
  if (-not $locationMatches[0].Groups[1].Value.Trim().Equals(
      $ExpectedUsbLocation, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'capture JTAG USB location does not match the role binding'
  }
  $identityMarker = [regex]::Match(
    $text, '(?m)^VC_LORA_JTAG_IDENTITY_MATCHED\s*$')
  $haltMarkerIndex = $text.IndexOf(
    'VC_LORA_HALT_CPU0', [StringComparison]::Ordinal)
  if (-not $identityMarker.Success -or $haltMarkerIndex -lt 0 -or
      $identityMarker.Index -ge $haltMarkerIndex) {
    throw 'opened JTAG identity was not proven before halt'
  }
  Assert-SmpHaltedCurstate $text
  Assert-SmpRunningCurstate $text
  if ($text -notmatch '(?i)shutdown command invoked') {
    throw 'OpenOCD capture log does not prove shutdown'
  }
}

function Assert-SmpCleanupLog {
  param([Parameter(Mandatory)][string]$LiteralPath)
  $text = [IO.File]::ReadAllText(
    $LiteralPath, [Text.UTF8Encoding]::new($false))
  Assert-SmpRunningCurstate $text
  if ($text -notmatch '(?i)shutdown command invoked') {
    throw 'OpenOCD cleanup log does not prove shutdown'
  }
}

function Get-OpenOcdLogStage {
  param([AllowEmptyString()][string]$Text)

  $usbOpenFailure = (
    $Text -match '(?i)esp_usb_jtag:\s*could not find or open device' -or
    ($Text -match '(?i)libusb_open\(\) failed with LIBUSB_ERROR_NOT_FOUND' -and
     $Text -notmatch '(?im)JTAG tap:\s*esp32s3\.cpu[01]\s+tap/device found'))
  $haltCpu0 = $Text -match '(?m)^VC_LORA_HALT_CURSTATE_CPU0='
  $haltCpu1 = $Text -match '(?m)^VC_LORA_HALT_CURSTATE_CPU1='
  $resumeCpu0 = $Text -match '(?m)^VC_LORA_RESUME_CURSTATE_CPU0='
  $resumeCpu1 = $Text -match '(?m)^VC_LORA_RESUME_CURSTATE_CPU1='
  $runningCurstateProven = $false
  try {
    Assert-SmpRunningCurstate $Text
    $runningCurstateProven = $true
  } catch {
    $runningCurstateProven = $false
  }
  $shutdownProven = $Text -match '(?i)shutdown command invoked'
  $targetExamined = (
    $Text -match '(?im)JTAG tap:\s*esp32s3\.cpu[01]\s+tap/device found' -or
    $Text -match '(?im)\[esp32s3\.cpu[01]\].*Examination succeed' -or
    $haltCpu0 -or $haltCpu1 -or $resumeCpu0 -or $resumeCpu1)
  # The capabilities-descriptor line is emitted before libusb_open and is not
  # evidence that Windows actually opened the selected USB-JTAG interface.
  $deviceOpened = (-not $usbOpenFailure) -and (
    $targetExamined -or
    $Text -match '(?im)^\s*Info\s*:\s*clock speed\s+\d+\s+kHz\s*$')
  $resumeProven = $runningCurstateProven -and $shutdownProven
  # Once target examination succeeds, the following `halt` command may have
  # affected either core even if OpenOCD fails before emitting our poll marker.
  $haltPossible = $targetExamined
  $classification = if ($usbOpenFailure -and -not $deviceOpened) {
    'FAIL_JTAG_USB_OPEN'
  } elseif ($targetExamined) {
    'FAIL_JTAG_AFTER_TARGET_EXAMINE'
  } elseif ($deviceOpened) {
    'FAIL_JTAG_AFTER_DEVICE_OPEN'
  } else {
    'FAIL_JTAG_PRE_ATTACH_UNKNOWN'
  }

  [pscustomobject][ordered]@{
    device_opened = $deviceOpened
    target_examined = $targetExamined
    halt_possible = $haltPossible
    resume_proven = $resumeProven
    shutdown_proven = $shutdownProven
    cleanup_required = -not ($usbOpenFailure -and -not $deviceOpened)
    failure_classification = $classification
  }
}

function Read-LiveStageRecord {
  param(
    [Parameter(Mandatory)][object]$Artifact,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidateRange(1, 3)][int]$Attempt
  )
  [void](Assert-Hash $OpenOcdExecutable $OpenOcdSha256 'OpenOCD executable')
  [void](Assert-Hash $InterfaceConfig $InterfaceConfigSha256 'OpenOCD interface config')
  [void](Assert-Hash $TargetConfig $TargetConfigSha256 'OpenOCD target config')

  $stageFirstPath = Join-Path $OutputDirectory `
    ("runtime-stage-attempt-$Attempt-first.bin")
  $fifoFirstPath = Join-Path $OutputDirectory `
    ("endpoint-fifo-attempt-$Attempt-first.bin")
  $stageSecondPath = Join-Path $OutputDirectory `
    ("runtime-stage-attempt-$Attempt-second.bin")
  $fifoSecondPath = Join-Path $OutputDirectory `
    ("endpoint-fifo-attempt-$Attempt-second.bin")
  $restartFirstPath=Join-Path $OutputDirectory ("hwcdc-restart-attempt-$Attempt-first.bin")
  $restartSecondPath=Join-Path $OutputDirectory ("hwcdc-restart-attempt-$Attempt-second.bin")
  $commitFirstPath=Join-Path $OutputDirectory ("ground-usb-commit-attempt-$Attempt-first.bin")
  $commitSecondPath=Join-Path $OutputDirectory ("ground-usb-commit-attempt-$Attempt-second.bin")
  $firstFailureFirstPath=Join-Path $OutputDirectory ("first-usb-failure-attempt-$Attempt-first.bin")
  $firstFailureSecondPath=Join-Path $OutputDirectory ("first-usb-failure-attempt-$Attempt-second.bin")
  $extended=[bool]$Artifact.extended_records_enabled
  $firstEnabled=[bool]$Artifact.first_usb_failure_enabled
  $captureLog = Join-Path $OutputDirectory ("openocd-attempt-$Attempt-capture.log")
  $cleanupLog = Join-Path $OutputDirectory ("openocd-attempt-$Attempt-cleanup.log")
  $commonArguments = @(
    '-s', (Resolve-Path $ScriptsRoot).Path,
    '-f', (Resolve-Path $InterfaceConfig).Path,
    '-c', "adapter usb location $ProbeUsbLocation",
    '-f', (Resolve-Path $TargetConfig).Path
  )
  $captureExitCode = -1
  $captureNative = $null
  $cleanupResult = $null
  $captureStage = Get-OpenOcdLogStage -Text ''
  $serialIdentityCommand =
    'set vc_lora_serial [espusbjtag get_serial]; ' +
    'echo VC_LORA_JTAG_OPEN_SERIAL=$vc_lora_serial; ' +
    'if {![string equal -nocase $vc_lora_serial {' + $ProbeSerial +
    '}]} { error VC_LORA_JTAG_SERIAL_MISMATCH }'
  $locationIdentityCommand =
    'set vc_lora_location [espusbjtag get_location]; ' +
    'echo VC_LORA_JTAG_OPEN_LOCATION=$vc_lora_location; ' +
    'if {![string equal $vc_lora_location {' + $ProbeUsbLocation +
    '}]} { error VC_LORA_JTAG_LOCATION_MISMATCH }'
  try {
    $captureArguments = $commonArguments + @(
      '-c', 'init',
      '-c', $serialIdentityCommand,
      '-c', $locationIdentityCommand,
      '-c', 'echo VC_LORA_JTAG_IDENTITY_MATCHED',
      '-c', 'halt',
      '-c', 'wait_halt 5000',
      '-c', 'echo VC_LORA_HALT_CPU0; echo VC_LORA_HALT_CURSTATE_CPU0=[esp32s3.cpu0 curstate]',
      '-c', 'echo VC_LORA_HALT_CPU1; echo VC_LORA_HALT_CURSTATE_CPU1=[esp32s3.cpu1 curstate]',
      '-c', "dump_image $(Convert-TclPath $stageFirstPath) $($Artifact.runtime_stage_address) $stageRecordBytes",
      '-c', "dump_image $(Convert-TclPath $fifoFirstPath) $($Artifact.endpoint_fifo_address) $fifoRecordBytes"
    )
    if($extended) {
      $captureArguments+=@(
        '-c', "dump_image $(Convert-TclPath $restartFirstPath) $($Artifact.hwcdc_restart_address) 128",
        '-c', "dump_image $(Convert-TclPath $commitFirstPath) $($Artifact.ground_usb_commit_address) 128"
      )
    }
    if($firstEnabled){$captureArguments+=@('-c', "dump_image $(Convert-TclPath $firstFailureFirstPath) $($Artifact.first_usb_failure_address) 384")}
    $captureArguments+=@(
      '-c', "dump_image $(Convert-TclPath $stageSecondPath) $($Artifact.runtime_stage_address) $stageRecordBytes",
      '-c', "dump_image $(Convert-TclPath $fifoSecondPath) $($Artifact.endpoint_fifo_address) $fifoRecordBytes"
    )
    if($extended) {
      $captureArguments+=@(
        '-c', "dump_image $(Convert-TclPath $restartSecondPath) $($Artifact.hwcdc_restart_address) 128",
        '-c', "dump_image $(Convert-TclPath $commitSecondPath) $($Artifact.ground_usb_commit_address) 128"
      )
    }
    if($firstEnabled){$captureArguments+=@('-c', "dump_image $(Convert-TclPath $firstFailureSecondPath) $($Artifact.first_usb_failure_address) 384")}
    $captureArguments+=@(
      '-c', 'catch { resume }',
      '-c', 'sleep 20',
      '-c', 'echo VC_LORA_RESUME_CPU0; echo VC_LORA_RESUME_CURSTATE_CPU0=[esp32s3.cpu0 curstate]',
      '-c', 'echo VC_LORA_RESUME_CPU1; echo VC_LORA_RESUME_CURSTATE_CPU1=[esp32s3.cpu1 curstate]',
      '-c', 'shutdown'
    )
    $script:OpenOcdProcessStarted = $true
    $script:CaptureProcessTerminationProven = $false
    $captureNative = Invoke-NativeProcessCapture `
      -Executable $OpenOcdExecutable -Arguments $captureArguments `
      -LogPath $captureLog -TimeoutMilliseconds 30000
    $captureExitCode = [int]$captureNative.exit_code
    $script:CaptureProcessTerminationProven =
      [bool]$captureNative.termination_proven
    if (Test-Path -LiteralPath $captureLog -PathType Leaf) {
      $captureStage = Get-OpenOcdLogStage -Text (
        [IO.File]::ReadAllText(
          $captureLog, [Text.UTF8Encoding]::new($false)))
    }
  } finally {
    if ($null -ne $captureNative -and
        [bool]$captureNative.termination_proven -and
        [bool]$captureStage.cleanup_required) {
      $cleanupResult = Invoke-OpenOcdCleanup -Executable $OpenOcdExecutable `
        -CommonArguments $commonArguments -LogPath $cleanupLog
    } elseif ($null -ne $captureNative -and
        [bool]$captureNative.termination_proven -and
        -not [bool]$captureStage.cleanup_required) {
      [IO.File]::WriteAllText($cleanupLog,
        'Cleanup skipped: capture failed before the USB-JTAG device opened.',
        [Text.UTF8Encoding]::new($false))
      $cleanupResult = [pscustomobject]@{
        required = $false
        attempted = $false
        exit_code = 0
        timed_out = $false
        process_termination_proven = $true
        launch_failure = ''
        stdout_path = ''
        stderr_path = ''
        resume_shutdown_proven = $false
        skipped_due_to_pre_attach_failure = $true
        skipped_due_to_unproven_capture_termination = $false
      }
    } else {
      [IO.File]::WriteAllText($cleanupLog,
        'Cleanup skipped: capture-process termination is unproven.',
        [Text.UTF8Encoding]::new($false))
      $cleanupResult = [pscustomobject]@{
        required = $true
        attempted = $false
        exit_code = 126
        timed_out = $false
        process_termination_proven = $false
        launch_failure = ''
        stdout_path = ''
        stderr_path = ''
        resume_shutdown_proven = $false
        skipped_due_to_pre_attach_failure = $false
        skipped_due_to_unproven_capture_termination = $true
      }
    }
  }
  $captureProof = $false
  if ($captureExitCode -eq 0) {
    try {
      Assert-SmpCaptureLog -LiteralPath $captureLog `
        -ExpectedProbeSerial $ProbeSerial `
        -ExpectedUsbLocation $ProbeUsbLocation
      $captureProof = $true
    } catch {
      $captureProof = $false
    }
  }
  [pscustomobject]@{
    attempt = $Attempt
    capture_exit_code = $captureExitCode
    capture_timed_out = if ($null -ne $captureNative) {
      [bool]$captureNative.timed_out
    } else { $false }
    capture_process_termination_proven = if ($null -ne $captureNative) {
      [bool]$captureNative.termination_proven
    } else { $false }
    capture_launch_failure = if ($null -ne $captureNative) {
      [string]$captureNative.launch_failure
    } else { '' }
    capture_stdout_path = if ($null -ne $captureNative) {
      [string]$captureNative.stdout_path
    } else { '' }
    capture_stderr_path = if ($null -ne $captureNative) {
      [string]$captureNative.stderr_path
    } else { '' }
    smp_capture_proven = $captureProof
    stage_first = if (Test-Path $stageFirstPath -PathType Leaf) {
      [IO.File]::ReadAllBytes($stageFirstPath)
    } else { $null }
    stage_second = if (Test-Path $stageSecondPath -PathType Leaf) {
      [IO.File]::ReadAllBytes($stageSecondPath)
    } else { $null }
    fifo_first = if (Test-Path $fifoFirstPath -PathType Leaf) {
      [IO.File]::ReadAllBytes($fifoFirstPath)
    } else { $null }
    fifo_second = if (Test-Path $fifoSecondPath -PathType Leaf) {
      [IO.File]::ReadAllBytes($fifoSecondPath)
    } else { $null }
    hwcdc_restart_first=if($extended-and(Test-Path -LiteralPath $restartFirstPath -PathType Leaf)){[IO.File]::ReadAllBytes($restartFirstPath)}else{$null}
    hwcdc_restart_second=if($extended-and(Test-Path -LiteralPath $restartSecondPath -PathType Leaf)){[IO.File]::ReadAllBytes($restartSecondPath)}else{$null}
    ground_usb_commit_first=if($extended-and(Test-Path -LiteralPath $commitFirstPath -PathType Leaf)){[IO.File]::ReadAllBytes($commitFirstPath)}else{$null}
    ground_usb_commit_second=if($extended-and(Test-Path -LiteralPath $commitSecondPath -PathType Leaf)){[IO.File]::ReadAllBytes($commitSecondPath)}else{$null}
    first_usb_failure_first=if($firstEnabled-and(Test-Path -LiteralPath $firstFailureFirstPath -PathType Leaf)){[IO.File]::ReadAllBytes($firstFailureFirstPath)}else{$null}
    first_usb_failure_second=if($firstEnabled-and(Test-Path -LiteralPath $firstFailureSecondPath -PathType Leaf)){[IO.File]::ReadAllBytes($firstFailureSecondPath)}else{$null}
    capture_log = $captureLog
    cleanup_log = $cleanupLog
    cleanup = $cleanupResult
    openocd_stage = $captureStage
  }
}

function Test-TransientSnapshotError {
  param([Parameter(Mandatory)][string]$Message)
  $Message -in @(
    'active_writer is nonzero',
    'sequence is odd or changed between reads',
    'two halted JTAG reads are not identical',
    'Endpoint FIFO active_writer is nonzero',
    'Endpoint FIFO sequence is odd or changed between reads',
    'two halted Endpoint FIFO JTAG reads are not identical',
    'HWCDC restart reads differ',
    'HWCDC restart writer is active or sequence is odd',
    'Ground USB commit reads differ',
    'Ground USB commit writer is active or sequence is odd',
    'Two reads differ', 'Unstable seqlock sample'
  )
}

function Get-TargetMayBeHalted {
  param(
    [bool]$OpenOcdStarted,
    [AllowNull()][object]$OpenOcdStage,
    [bool]$CaptureProcessTerminationProven,
    [bool]$ResumeShutdownCleanupProven
  )
  if (-not $OpenOcdStarted) { return $false }
  if (-not $CaptureProcessTerminationProven) { return $true }
  if ($null -eq $OpenOcdStage) { return $true }
  if (-not [bool]$OpenOcdStage.device_opened) { return $false }
  if ([bool]$OpenOcdStage.resume_proven -or
      $ResumeShutdownCleanupProven) { return $false }
  [bool]$OpenOcdStage.halt_possible
}

function Decode-StableStageRecord {
  param(
    [Parameter(Mandatory)][byte[]]$First,
    [Parameter(Mandatory)][byte[]]$Second,
    [Parameter(Mandatory)][string]$ExpectedRole
  )
  if ($First.Length -ne $stageRecordBytes -or
      $Second.Length -ne $stageRecordBytes) {
    throw 'both JTAG reads must be exactly 68 bytes'
  }
  if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$First, [byte[]]$Second)) {
    throw 'two halted JTAG reads are not identical'
  }
  [uint32[]]$firstWords = Convert-Words -Bytes $First `
    -ExpectedBytes $stageRecordBytes -WordCount 17 -Label 'runtime stage'
  [uint32[]]$secondWords = Convert-Words -Bytes $Second `
    -ExpectedBytes $stageRecordBytes -WordCount 17 -Label 'runtime stage'
  if ($firstWords[0] -ne 0 -or $secondWords[0] -ne 0) {
    throw 'active_writer is nonzero'
  }
  if (($firstWords[1] -band 1) -ne 0 -or ($secondWords[1] -band 1) -ne 0 -or
      $firstWords[1] -ne $secondWords[1]) {
    throw 'sequence is odd or changed between reads'
  }
  if ($firstWords[2] -ne 0x52313953 -or $firstWords[3] -ne 1) {
    throw 'runtime stage header is invalid'
  }
  if (($firstWords[9] -band 0xFFFE0000) -ne 0) {
    throw 'runtime stage mask contains unknown bits'
  }
  [uint32[]]$expectedFingerprint = @(
    0x52313944, 0x53544731, 0x32303236, 0x31303033
  )
  for ($fingerprintIndex = 0; $fingerprintIndex -lt 4; ++$fingerprintIndex) {
    if ($firstWords[5 + $fingerprintIndex] -ne
        $expectedFingerprint[$fingerprintIndex]) {
      throw 'diagnostic generation fingerprint is invalid'
    }
  }
  $recordRole = switch ($firstWords[4]) {
    1 { 'ground' }
    2 { 'vehicle' }
    default { throw 'runtime stage role is invalid' }
  }
  if ($recordRole -ne $ExpectedRole) {
    throw 'runtime stage role does not match the bound device role'
  }

  [string[]]$reached = @()
  foreach ($entry in $stageNames.GetEnumerator()) {
    if (($firstWords[9] -band [uint32]$entry.Key) -ne 0) {
      $reached += [string]$entry.Value
    }
  }
  $lastReached = if ($reached.Count -eq 0) { 'None' } else { $reached[-1] }
  $setupWitnesses = [ordered]@{
    setup_entered = (($firstWords[9] -band 0x0001) -ne 0)
    serial_begin_returned = (($firstWords[9] -band 0x0002) -ne 0)
    cadence_started = (($firstWords[9] -band 0x0004) -ne 0)
    startup_allowed = (($firstWords[9] -band 0x0020) -ne 0)
    e220_normal_mode = (($firstWords[9] -band 0x0040) -ne 0)
    adapter_ready = (($firstWords[9] -band 0x0080) -ne 0)
    setup_complete = (($firstWords[9] -band 0x0100) -ne 0)
  }
  # IdentityReady and E220ProfileChecked are conditional branches. They are
  # reported independently and never treated as mandatory linear setup steps.
  $conditionalSetupWitnesses = [ordered]@{
    IdentityReady = (($firstWords[9] -band 0x0008) -ne 0)
    E220ProfileChecked = (($firstWords[9] -band 0x0010) -ne 0)
  }
  [string[]]$missingMandatorySetup = @()
  foreach ($setupEntry in $setupWitnesses.GetEnumerator()) {
    if (-not $setupEntry.Value) {
      $missingMandatorySetup += [string]$setupEntry.Key
    }
  }
  $failureCode = $firstWords[14]
  $failureName = 'None'
  if (($firstWords[15] -band 0xFFFE0000) -ne 0) {
    throw 'first-failure stage mask contains unknown bits'
  }
  if ($failureCode -eq 0 -and
      ($firstWords[15] -ne 0 -or $firstWords[16] -ne 0)) {
    throw 'first-failure detail exists without a failure code'
  }
  if ($failureCode -ne 0) {
    if (($failureCode -band 0xFFFFFF00) -ne 0x54520000) {
      throw 'first-failure domain or reserved bits are invalid'
    }
    $reason = [int]($failureCode -band 0xFF)
    if ($reason -le 0 -or $reason -ge $failureNames.Count) {
      throw 'first-failure reason is unknown'
    }
    $failureName = $failureNames[$reason]
  }
  $boundary = if (($firstWords[9] -band 0x4000) -ne 0) {
    'flush-completed'
  } elseif (($firstWords[9] -band 0x2000) -ne 0) {
    'write-accepted-before-flush'
  } elseif (($firstWords[9] -band 0x1000) -ne 0) {
    'write-attempted-not-accepted'
  } elseif (($firstWords[9] -band 0x0800) -ne 0) {
    'frame-staged-before-write'
  } elseif (($firstWords[9] -band 0x0400) -ne 0) {
    'host-gate-observed-before-frame-stage'
  } elseif (($firstWords[9] -band 0x0200) -ne 0) {
    'loop-entered-before-host-gate'
  } elseif (($firstWords[9] -band 0x0100) -ne 0) {
    'setup-complete-before-loop'
  } elseif (($firstWords[9] -band 0x0001) -ne 0) {
    'setup-incomplete'
  } else {
    'record-initialized-without-setup-witness'
  }
  [ordered]@{
    active_writer = $firstWords[0]
    sequence = $firstWords[1]
    magic = ('0x{0:x8}' -f $firstWords[2])
    schema = $firstWords[3]
    role = $recordRole
    build_fingerprint = @(
      ('0x{0:x8}' -f $firstWords[5]), ('0x{0:x8}' -f $firstWords[6]),
      ('0x{0:x8}' -f $firstWords[7]), ('0x{0:x8}' -f $firstWords[8])
    )
    stage_mask = ('0x{0:x8}' -f $firstWords[9])
    reached_stages = $reached
    last_reached_stage = $lastReached
    mandatory_setup_witnesses = $setupWitnesses
    conditional_setup_witnesses = $conditionalSetupWitnesses
    missing_mandatory_setup_witnesses = $missingMandatorySetup
    boundary_classification = $boundary
    counters = [ordered]@{
      boot = $firstWords[10]
      loop = $firstWords[11]
      publish_attempt = $firstWords[12]
      exact_frame_restart = $firstWords[13]
    }
    first_failure = [ordered]@{
      code = ('0x{0:x8}' -f $failureCode)
      name = $failureName
      stage_mask = ('0x{0:x8}' -f $firstWords[15])
      detail = $firstWords[16]
    }
  }
}

function Decode-StableFifoRecord {
  param(
    [Parameter(Mandatory)][byte[]]$First,
    [Parameter(Mandatory)][byte[]]$Second
  )
  if ($First.Length -ne $fifoRecordBytes -or
      $Second.Length -ne $fifoRecordBytes) {
    throw 'both Endpoint FIFO JTAG reads must be exactly 112 bytes'
  }
  if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$First, [byte[]]$Second)) {
    throw 'two halted Endpoint FIFO JTAG reads are not identical'
  }
  [uint32[]]$firstWords = Convert-Words -Bytes $First `
    -ExpectedBytes $fifoRecordBytes -WordCount 28 -Label 'Endpoint FIFO'
  [uint32[]]$secondWords = Convert-Words -Bytes $Second `
    -ExpectedBytes $fifoRecordBytes -WordCount 28 -Label 'Endpoint FIFO'
  if ($firstWords[0] -ne 0 -or $secondWords[0] -ne 0) {
    throw 'Endpoint FIFO active_writer is nonzero'
  }
  if (($firstWords[1] -band 1) -ne 0 -or
      ($secondWords[1] -band 1) -ne 0 -or
      $firstWords[1] -ne $secondWords[1]) {
    throw 'Endpoint FIFO sequence is odd or changed between reads'
  }
  if ($firstWords[2] -ne 0x48313946 -or $firstWords[3] -ne 2) {
    throw 'Endpoint FIFO diagnostic header is invalid'
  }
  if (($firstWords[4] -band 0xFFFFC000) -ne 0) {
    throw 'Endpoint FIFO flags contain unknown bits outside 0x00003FFF'
  }
  $initialized = (($firstWords[4] -band 0x00000001) -ne 0)
  if (-not $initialized) {
    throw 'Endpoint FIFO diagnostic record is not initialized'
  }
  $observationActive = (($firstWords[4] -band 0x00000002) -ne 0)
  if (-not $observationActive) {
    throw 'Endpoint FIFO diagnostic observation window was not started'
  }
  if (($firstWords[23] -band 0xFFFFFF00) -ne 0) {
    throw 'Endpoint FIFO flush blockers contain unknown bits outside 0x000000FF'
  }
  if ($firstWords[24] -ge $fifoFlushOutcomeNames.Count) {
    throw 'Endpoint FIFO last flush outcome is unknown'
  }
  if (($firstWords[27] -band 0xFFFFFF00) -ne 0) {
    throw 'Endpoint FIFO last flush terminal blocker mask contains unknown bits outside 0x000000FF'
  }
  if ($firstWords[12] -gt $firstWords[11]) {
    throw 'Endpoint FIFO payload IN_EMPTY count exceeds raw IN_EMPTY count'
  }
  if ($firstWords[8] -gt $firstWords[6]) {
    throw 'Endpoint FIFO zero-write count exceeds FIFO write attempt count'
  }
  if ($firstWords[9] -gt 32) {
    throw 'Endpoint FIFO last FIFO write size exceeds 32 bytes'
  }
  [uint64]$flushTerminalCount =
    [uint64]$firstWords[17] + [uint64]$firstWords[18]
  if ($flushTerminalCount -gt [uint64]$firstWords[16]) {
    throw 'Endpoint FIFO flush success count or timeout count exceeds flush attempt count'
  }
  if ($firstWords[19] -gt $firstWords[10]) {
    throw 'Endpoint FIFO ZLP flush count exceeds wr_done count'
  }
  [uint64]$nonZlpWrDoneCount =
    [uint64]$firstWords[10] - [uint64]$firstWords[19]
  [uint64]$positiveFifoWriteAttemptCount =
    [uint64]$firstWords[6] - [uint64]$firstWords[8]
  if ([uint64]$firstWords[12] -gt $nonZlpWrDoneCount) {
    throw 'Endpoint FIFO payload IN_EMPTY count exceeds non-ZLP wr_done count'
  }
  if ($nonZlpWrDoneCount -gt $positiveFifoWriteAttemptCount) {
    throw 'Endpoint FIFO non-ZLP wr_done count exceeds positive FIFO write attempt count'
  }
  $payloadPublishPending = (($firstWords[4] -band 0x00000800) -ne 0)
  $payloadPublishAborted = (($firstWords[4] -band 0x00001000) -ne 0)
  $payloadFlushPending = (($firstWords[4] -band 0x00002000) -ne 0)
  if ($payloadPublishPending -and
      $positiveFifoWriteAttemptCount -le $nonZlpWrDoneCount) {
    throw ('Endpoint FIFO PayloadPublishPending requires an unmatched ' +
      'positive FIFO write')
  }
  [uint64]$lastFlushZlpCount =
    [uint64]$firstWords[25] + [uint64]$firstWords[26]
  if ($lastFlushZlpCount -gt [uint64]$firstWords[19]) {
    throw 'Endpoint FIFO last flush ZLP count exceeds cumulative ZLP count'
  }
  $flushActive = (($firstWords[4] -band 0x00000400) -ne 0)
  $lastFlushOutcome = [int]$firstWords[24]
  if ($flushActive -ne ($lastFlushOutcome -eq 1)) {
    throw 'Endpoint FIFO last flush outcome disagrees with FlushActive'
  }
  [uint64]$flushOpenCount = if ($flushActive) { 1 } else { 0 }
  [uint64]$flushAccountedCount = $flushTerminalCount + $flushOpenCount
  if ($flushAccountedCount -gt [uint64]$firstWords[16]) {
    throw 'Endpoint FIFO flush terminal and active counts exceed flush attempt count'
  }
  [uint64]$flushAbortCount =
    [uint64]$firstWords[16] - $flushAccountedCount
  if (($lastFlushOutcome -eq 0 -and
       ($firstWords[16] -ne 0 -or $lastFlushZlpCount -ne 0 -or
        $firstWords[27] -ne 0)) -or
      ($lastFlushOutcome -ne 0 -and $firstWords[16] -eq 0) -or
      ($lastFlushOutcome -eq 2 -and $firstWords[17] -eq 0) -or
      ($lastFlushOutcome -eq 3 -and $firstWords[18] -eq 0) -or
      ($lastFlushOutcome -eq 4 -and $flushAbortCount -eq 0) -or
      ($lastFlushOutcome -in @(1, 2) -and $firstWords[27] -ne 0)) {
    throw 'Endpoint FIFO last flush outcome disagrees with flush accounting'
  }
  $shortPacketSuccessWithoutZlp =
    $lastFlushOutcome -eq 2 -and $firstWords[25] -eq 0 -and
    $firstWords[26] -eq 0 -and $firstWords[9] -gt 0 -and
    $firstWords[9] -lt 64
  if ($lastFlushOutcome -eq 2 -and $firstWords[25] -eq 0 -and
      -not $shortPacketSuccessWithoutZlp) {
    throw ('Endpoint FIFO successful flush lacks task-origin final ZLP ' +
      'evidence and has no proven short final packet')
  }
  if ($lastFlushOutcome -eq 4 -and
      ($firstWords[27] -band 0x00000002) -eq 0) {
    throw ('Endpoint FIFO aborted flush lacks EpochMismatch terminal ' +
      'evidence')
  }
  $payloadInFlight = (($firstWords[4] -band 0x00000010) -ne 0)
  [uint32]$expectedPublishGeneration = if (
      $firstWords[14] -eq [uint32]::MaxValue) {
    0
  } else {
    $firstWords[14] + 1
  }
  $generationRelationshipValid = if ($payloadInFlight) {
    $firstWords[13] -eq $expectedPublishGeneration
  } else {
    $firstWords[13] -eq $firstWords[14]
  }
  if (-not $generationRelationshipValid) {
    throw 'Endpoint FIFO payload-in-flight flag disagrees with generation relationship'
  }
  if ($payloadPublishPending -and -not $payloadFlushPending) {
    throw ('Endpoint FIFO PayloadPublishPending requires ' +
      'PayloadFlushPending')
  }
  if ($payloadInFlight -and -not $payloadFlushPending) {
    throw ('Endpoint FIFO PayloadInFlight requires PayloadFlushPending')
  }
  if ($payloadPublishAborted -and
      ($payloadPublishPending -or $payloadFlushPending)) {
    throw ('Endpoint FIFO PayloadPublishAborted is mutually exclusive with ' +
      'payload pending witnesses')
  }
  if ($payloadFlushPending -and $positiveFifoWriteAttemptCount -eq 0) {
    throw ('Endpoint FIFO PayloadFlushPending requires a positive FIFO ' +
      'write attempt')
  }

  [string[]]$flagNames = @()
  foreach ($entry in $fifoFlagNames.GetEnumerator()) {
    if (($firstWords[4] -band [uint32]$entry.Key) -ne 0) {
      $flagNames += [string]$entry.Value
    }
  }
  [string[]]$blockerNames = @()
  foreach ($entry in $fifoFlushBlockerNames.GetEnumerator()) {
    if (($firstWords[23] -band [uint32]$entry.Key) -ne 0) {
      $blockerNames += [string]$entry.Value
    }
  }
  [string[]]$lastFlushTerminalBlockerNames = @()
  foreach ($entry in $fifoFlushBlockerNames.GetEnumerator()) {
    if (($firstWords[27] -band [uint32]$entry.Key) -ne 0) {
      $lastFlushTerminalBlockerNames += [string]$entry.Value
    }
  }
  $lastFlushClassification = if ($firstWords[25] -gt 1) {
    'multiple-task-zlp-during-attempt'
  } elseif ($firstWords[26] -gt 1) {
    'multiple-isr-zlp-during-attempt'
  } elseif ($lastFlushOutcome -eq 3 -and $firstWords[27] -eq 0) {
    'timeout-without-terminal-blocker'
  } elseif ($lastFlushOutcome -eq 0) {
    'no-flush-attempt'
  } elseif ($lastFlushOutcome -eq 1) {
    'flush-attempt-active'
  } elseif ($shortPacketSuccessWithoutZlp) {
    'success-with-short-packet-no-zlp'
  } elseif ($lastFlushOutcome -eq 2 -and $firstWords[25] -gt 0 -and
      $firstWords[26] -gt 0) {
    'success-with-task-and-isr-zlp'
  } elseif ($lastFlushOutcome -eq 2 -and $firstWords[25] -gt 0) {
    'success-with-task-zlp'
  } elseif ($lastFlushOutcome -eq 3) {
    'timeout-with-terminal-blocker'
  } else {
    'abort-epoch-mismatch'
  }

  $fifoQuarantined = (($firstWords[4] -band 0x00000020) -ne 0)
  $resetPending = (($firstWords[4] -band 0x00000040) -ne 0)
  $bootstrapFence = (($firstWords[4] -band 0x00000080) -ne 0)
  $bootstrapAborted = (($firstWords[4] -band 0x00000100) -ne 0)
  $debugWriterActive = (($firstWords[4] -band 0x00000200) -ne 0)
  $lastEventBusReset = (($firstWords[22] -band
      $fifoBusResetInterruptMask) -ne 0)
  if ($lastEventBusReset -and $firstWords[15] -eq 0) {
    throw ('Endpoint FIFO last BUS_RESET event lacks a cumulative reset ' +
      'counter witness')
  }
  $usbTxBoundary = if ($lastEventBusReset) {
    'last-event-bus-reset'
  } elseif ($payloadPublishAborted) {
    'payload-publish-aborted'
  } elseif ($debugWriterActive) {
    'diagnostic-writer-active'
  } elseif ($resetPending -or ($firstWords[23] -band 0x00000040) -ne 0) {
    'usb-reset-pending'
  } elseif ($fifoQuarantined -or
      ($firstWords[23] -band 0x00000020) -ne 0) {
    'fifo-quarantined'
  } elseif ($bootstrapAborted) {
    'bootstrap-aborted'
  } elseif ($bootstrapFence) {
    'bootstrap-fenced'
  } elseif ($flushAbortCount -gt 0 -and
      ($firstWords[23] -band 0x00000002) -ne 0) {
    'flush-aborted-epoch-mismatch'
  } elseif ($firstWords[23] -ne 0) {
    'flush-blocked'
  } elseif ($payloadPublishPending) {
    'payload-publish-pending'
  } elseif ($payloadFlushPending) {
    'payload-flush-pending'
  } elseif ($firstWords[6] -eq 0) {
    'fifo-write-not-attempted'
  } elseif ($firstWords[9] -eq 0) {
    'last-fifo-write-zero'
  } elseif ($firstWords[10] -eq 0) {
    'fifo-written-before-wr-done'
  } elseif ($payloadInFlight) {
    'payload-published-awaiting-pickup'
  } elseif ($firstWords[16] -eq 0) {
    'payload-picked-up-before-flush-attempt'
  } elseif ($flushActive) {
    'flush-attempt-active'
  } elseif ($flushAbortCount -gt 0) {
    'flush-abort-observed'
  } elseif ($firstWords[17] -gt 0) {
    'usb-tx-boundary-complete'
  } elseif ($firstWords[18] -gt 0) {
    'flush-timeout-observed'
  } else {
    'fifo-evidence-observed'
  }
  $usbTxBoundaryCompletionProven =
    ($usbTxBoundary -ceq 'usb-tx-boundary-complete')

  [ordered]@{
    active_writer = $firstWords[0]
    sequence = $firstWords[1]
    magic = ('0x{0:x8}' -f $firstWords[2])
    schema = $firstWords[3]
    state_semantics =
      'last-committed-diagnostic-event-not-live-hardware-state'
    flags = [ordered]@{
      mask = ('0x{0:x8}' -f $firstWords[4])
      names = $flagNames
      initialized = $initialized
      observation_active = $observationActive
      diagnostic_observation_window_started = $observationActive
      fifo_write_attempt_observed = ($firstWords[6] -gt 0)
      positive_fifo_write_observed = ($firstWords[7] -gt 0)
      wr_done_observed = ($firstWords[10] -gt 0)
      payload_pickup_observed = ($firstWords[12] -gt 0)
      connected = (($firstWords[4] -band 0x00000004) -ne 0)
      fifo_writable = (($firstWords[4] -band 0x00000008) -ne 0)
      payload_in_flight = $payloadInFlight
      fifo_quarantined = $fifoQuarantined
      reset_pending = $resetPending
      bootstrap_fence = $bootstrapFence
      bootstrap_aborted = $bootstrapAborted
      debug_writer_active = $debugWriterActive
      last_event_bus_reset = $lastEventBusReset
      flush_active = $flushActive
      payload_publish_pending = $payloadPublishPending
      payload_publish_aborted = $payloadPublishAborted
      payload_flush_pending = $payloadFlushPending
    }
    tx_loss_epoch = $firstWords[5]
    counters = [ordered]@{
      fifo_write_attempt = $firstWords[6]
      fifo_write_bytes = $firstWords[7]
      fifo_zero_write = $firstWords[8]
      wr_done = $firstWords[10]
      in_empty_irq = $firstWords[11]
      payload_in_empty = $firstWords[12]
      bus_reset = $firstWords[15]
      flush_attempt = $firstWords[16]
      flush_success = $firstWords[17]
      flush_timeout = $firstWords[18]
      flush_abort_inferred = $flushAbortCount
      zlp_flush = $firstWords[19]
    }
    last_fifo_write_size = $firstWords[9]
    generations = [ordered]@{
      publish = $firstWords[13]
      pickup = $firstWords[14]
      relationship = if ($payloadInFlight) {
        'publish-is-one-ahead-modulo-uint32'
      } else { 'publish-equals-pickup' }
    }
    pending_bytes = [ordered]@{
      ring = $firstWords[20]
      stash = $firstWords[21]
    }
    last_interrupt_status = ('0x{0:x8}' -f $firstWords[22])
    flush_blockers = [ordered]@{
      mask = ('0x{0:x8}' -f $firstWords[23])
      names = $blockerNames
    }
    last_flush_outcome = $fifoFlushOutcomeNames[$lastFlushOutcome]
    last_flush_outcome_code = $lastFlushOutcome
    last_flush_task_zlp_count = $firstWords[25]
    last_flush_isr_zlp_count = $firstWords[26]
    last_flush_terminal_blocker_mask =
      ('0x{0:x8}' -f $firstWords[27])
    last_flush_terminal_blocker_mask_code = $firstWords[27]
    last_flush_terminal_blocker_names = $lastFlushTerminalBlockerNames
    last_flush_classification = $lastFlushClassification
    boundary_classification = $usbTxBoundary
    usb_tx_boundary_completion_proven = $usbTxBoundaryCompletionProven
  }
}

function Decode-StableDiagnosticRecords {
  param(
    [Parameter(Mandatory)][byte[]]$StageFirst,
    [Parameter(Mandatory)][byte[]]$StageSecond,
    [Parameter(Mandatory)][byte[]]$FifoFirst,
    [Parameter(Mandatory)][byte[]]$FifoSecond,
    [Parameter(Mandatory)][string]$ExpectedRole
  )
  $stage = Decode-StableStageRecord -First $StageFirst -Second $StageSecond `
    -ExpectedRole $ExpectedRole
  $fifo = Decode-StableFifoRecord -First $FifoFirst -Second $FifoSecond
  $stage['endpoint_fifo'] = $fifo
  $stage['usb_tx_boundary_classification'] =
    [string]$fifo.boundary_classification
  $stage['usb_tx_boundary_completion_proven'] =
    [bool]$fifo.usb_tx_boundary_completion_proven
  $stage
}

function Decode-ExtendedStableWords {
  param([byte[]]$First, [byte[]]$Second, [uint32]$Magic, [string]$Label)
  if ($null -eq $First -or $null -eq $Second -or $First.Length -ne 128 -or $Second.Length -ne 128) {
    throw "$Label requires two exact 128-byte records"
  }
  if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$First, [byte[]]$Second)) {
    throw "$Label reads differ"
  }
  [uint32[]]$words = Convert-Words $First 128 32 $Label
  if ($words[0] -ne 0 -or ($words[1] -band 1) -ne 0) {
    throw "$Label writer is active or sequence is odd"
  }
  if ($words[2] -ne $Magic -or $words[3] -ne 1) { throw "$Label header is invalid" }
  return ,$words
}

function Decode-ExtendedRestartState {
  param([uint32[]]$Words, [int]$Offset)
  if (($Words[$Offset] -band 0xffffc000) -ne 0) { throw 'restart state has unknown flags' }
  $inFlight = ($Words[$Offset] -band 0x10) -ne 0
  [uint64]$next = ([uint64]$Words[$Offset + 5] + 1) -band [uint64]4294967295
  if (($inFlight -and [uint64]$Words[$Offset + 4] -ne $next) -or
      (-not $inFlight -and $Words[$Offset + 4] -ne $Words[$Offset + 5])) {
    throw 'restart state payload generations are inconsistent'
  }
  [ordered]@{
    flags = ('0x{0:x8}' -f $Words[$Offset]); epoch = $Words[$Offset + 1]
    ring_pending_bytes = $Words[$Offset + 2]; stash_pending_bytes = $Words[$Offset + 3]
    publish_generation = $Words[$Offset + 4]; pickup_generation = $Words[$Offset + 5]
    raw_interrupt_status = ('0x{0:x8}' -f $Words[$Offset + 6])
    interrupt_enabled_mask = ('0x{0:x8}' -f $Words[$Offset + 7])
  }
}

function Decode-ExtendedRestartRecord {
  param([byte[]]$First, [byte[]]$Second)
  [uint32[]]$w = Decode-ExtendedStableWords $First $Second 0x48313952 'HWCDC restart'
  if (($w[4] -band 0xfffffff8) -ne 0 -or ($w[4] -band 1) -eq 0 -or $w[31] -ne 0) {
    throw 'restart flags or reserved word is invalid'
  }
  $firstValid = ($w[4] -band 2) -ne 0; $latestValid = ($w[4] -band 4) -ne 0
  if ($w[6] -gt $w[5] -or $w[7] -gt $w[5] -or
      $firstValid -ne ($w[6] -gt 0) -or $latestValid -ne ($w[7] -gt 0)) {
    throw 'restart event counters disagree with validity flags'
  }
  if ($firstValid) {
    if ($w[8] -notin @(1,2) -or $w[9] -eq 0 -or $w[9] -gt $w[5]) { throw 'restart first event is invalid' }
    if (($w[10] -band 8) -eq 0 -or ($w[10] -band 0x3f0) -ne 0 -or
        ($w[12] -eq 0 -and $w[13] -eq 0)) { throw 'restart first event is not healthy idle pending' }
  } else {
    for ($i=8; $i-le17; ++$i) { if ($w[$i] -ne 0) { throw 'restart first event exists without validity' } }
  }
  if ($latestValid) {
    if ($w[18] -notin @(1,2) -or $w[19] -notin @(1,2,3,4,5) -or
        $w[20] -eq 0 -or $w[20] -gt 32 -or $w[21] -gt $w[20] -or
        $w[22] -eq 0 -or $w[22] -gt $w[5] -or
        ($w[19] -in @(1,4) -and $w[21] -eq 0) -or
        ($w[19] -in @(2,3,5) -and $w[21] -ne 0) -or
        ($w[19] -eq 1 -and ($w[23] -band 0x10) -eq 0)) { throw 'restart latest event is invalid' }
  } else {
    for ($i=18; $i-le30; ++$i) { if ($w[$i] -ne 0) { throw 'restart latest event exists without validity' } }
  }
  $firstState = Decode-ExtendedRestartState $w 10
  $latestState = Decode-ExtendedRestartState $w 23
  [ordered]@{
    schema = 1; size_bytes = 128; sequence = $w[1]; flags = ('0x{0:x8}' -f $w[4])
    state_semantics = 'latched-diagnostic-events-not-live-hardware-state'
    initialized = $true; first_blocked_latched = $firstValid; latest_restart_valid = $latestValid
    event_count = $w[5]; blocked_count = $w[6]; restart_count = $w[7]
    first = [ordered]@{ phase=$w[8]; ordinal=$w[9]; state=$firstState }
    latest = [ordered]@{ origin=$w[18]; outcome=$w[19]; requested_bytes=$w[20]; written_bytes=$w[21]; ordinal=$w[22]; state=$latestState }
  }
}

function Decode-ExtendedCommitRecord {
  param([byte[]]$First, [byte[]]$Second, [string]$ExpectedRole)
  [uint32[]]$w = Decode-ExtendedStableWords $First $Second 0x52313943 'Ground USB commit'
  $recordRole = switch ($w[4]) { 1 {'ground'} 2 {'vehicle'} default {throw 'commit role is invalid'} }
  if ($recordRole -ne $ExpectedRole) { throw 'commit role does not match fixture role' }
  [uint32[]]$fingerprint = @(0x52313944,0x53544731,0x32303236,0x31303033)
  for ($i=0; $i-lt4; ++$i) { if ($w[5+$i] -ne $fingerprint[$i]) { throw 'commit generation fingerprint is invalid' } }
  if ($w[9] -gt 4 -or ($w[10] -band 0xfffffff8) -ne 0 -or ($w[11] -band 0xfffffff8) -ne 0 -or
      ($w[11] -band $w[10]) -ne $w[11]) { throw 'commit reason or predicate masks are invalid' }
  if ($w[31] -gt $w[30]) { throw 'commit accepted bytes exceed the expected frame' }
  if ($w[9] -eq 0) {
    for ($i=10; $i-lt32; ++$i) { if ($w[$i] -ne 0) { throw 'unlatched commit has failure payload' } }
  } else {
    if ($ExpectedRole -ne 'ground') { throw 'Vehicle cannot latch a Ground commit failure' }
    $allowedObserved = if ($w[9] -in @(1,4)) {@(7)} elseif ($w[9] -eq 3) {@(6,7)} else {@(6)}
    if ($w[10] -notin $allowedObserved -or $w[12] -eq 0) { throw 'commit reason lacks exact predicate observation or source line' }
  }
  $u64 = [ordered]@{}
  foreach ($entry in @(@('commit_started_ms',16),@('flush_started_ms',18),@('completed_ms',20),@('deadline_ms',22),@('committed_base',24),@('commit_goal',26),@('bytes_committed',28))) {
    $offset=[int]$entry[1]
    $u64[[string]$entry[0]] = [uint64]$w[$offset] + ([uint64]$w[$offset+1] * [uint64]4294967296)
  }
  [ordered]@{
    schema=1; size_bytes=128; sequence=$w[1]; role=$recordRole
    state_semantics='first-ground-usb-commit-failure-only-not-live-state'
    failure_latched=($w[9]-ne0); reason=$w[9]; reason_name=@('None','PublicationRejected','BeforeFlushDeadline','Retired','PacerCompletionRejected')[$w[9]]
    observed_mask=$w[10]; true_mask=$w[11]; source_line=$w[12]; token=$w[13]
    expected_epoch=$w[14]; observed_epoch=$w[15]; values=$u64
    expected_frame_bytes=$w[30]; accepted_frame_bytes=$w[31]
    predicates=[ordered]@{
      transport_published=[ordered]@{observed=(($w[10]-band1)-ne0);value=(($w[11]-band1)-ne0)}
      endpoint_ready=[ordered]@{observed=(($w[10]-band2)-ne0);value=(($w[11]-band2)-ne0)}
      completed_within_deadline=[ordered]@{observed=(($w[10]-band4)-ne0);value=(($w[11]-band4)-ne0)}
    }
  }
}

function Decode-FirstUsbFailureRecord {
  param([byte[]]$First,[byte[]]$Second,[string]$ExpectedRole,[string]$ExpectedDecoderSha256)
  # The file path is fixed by this reader, never executed from candidate input.
  # Exact image identity is separately bound through ELF/application/flash hashes;
  # these four expected words are only the supported diagnostic-generation ABI.
  if(-not[string]::IsNullOrWhiteSpace($ExpectedDecoderSha256)){
    if($script:R19FirstDecoderVerifiedSha256-cne$ExpectedDecoderSha256-or[string]::IsNullOrWhiteSpace($script:R19FirstDecoderVerifiedText)){throw 'first failure decoder was not independently bound before capture'}
    $text=$script:R19FirstDecoderVerifiedText
  }else{$text=Get-VerifiedFirstUsbDecoderText}
  . ([scriptblock]::Create($text)) -ImportOnly
  ConvertFrom-R19FirstUsbFailureBytes -First $First -Second $Second -ExpectedRole $ExpectedRole `
    -ExpectedFingerprint @(0x52313944,0x53544731,0x32303236,0x31303033)
}

function Invoke-OfflineExtendedRecordFixture {
  # This decoder intentionally cannot enter a live/native/toolchain path.
  $extendedRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Join-Path ([IO.Path]::GetTempPath()) ('vc-lora-r19-extended-offline-' + [guid]::NewGuid().ToString('N'))
  } else { $OutputRoot }
  New-Item -ItemType Directory -Path $extendedRoot -Force | Out-Null
  $extendedRoot = (Resolve-Path $extendedRoot).Path
  $firstEnabled=$false
  try {
    if ($Execute -or $Preflight -or $OfflineNativeInvocationContractTest) {
      throw 'Extended records are offline fixture only; Execute, Preflight and native invocation are forbidden'
    }
    foreach ($name in @('Role','Address','ArtifactRoot','ArtifactId','ProbeSerial','ProbeUsbLocation','FlashEvidencePath','FlashEvidenceSha256','NmExecutable','NmSha256','OpenOcdExecutable','OpenOcdSha256','InterfaceConfig','InterfaceConfigSha256','TargetConfig','TargetConfigSha256','ScriptsRoot','NativeContractScript')) {
      if ($script:ExtendedBoundParameters.ContainsKey($name)) { throw "Extended offline decoder forbids live parameter: $name" }
    }
    if ([string]::IsNullOrWhiteSpace($FixturePath)) { throw 'Extended decoder requires FixturePath' }
    $f=Get-Content -LiteralPath $FixturePath -Raw|ConvertFrom-Json
    if ($f.schema -cnotin @('vc-lora-r19-usb-extended-jtag-fixture-v1','vc-lora-r19-usb-extended-jtag-fixture-v2') -or $f.role -notin @('ground','vehicle') -or
        [string]::IsNullOrWhiteSpace([string]$f.artifact_id)) { throw 'Extended fixture identity or schema is invalid' }
    $sizes=@{runtime_stage=68;endpoint_fifo=112;hwcdc_restart=128;ground_usb_commit=128}
    $firstEnabled=$f.schema-ceq'vc-lora-r19-usb-extended-jtag-fixture-v2'
    $names=@('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit')
    if($firstEnabled){$sizes.first_usb_failure=384;$names+=@('first_usb_failure')}
    else{foreach($key in @('first_usb_failure_address','first_usb_failure_first_read_base64','first_usb_failure_second_read_base64')){if($f.PSObject.Properties[$key]){throw 'v1 fixture contains undeclared first failure record'}}}
    $ranges=[Collections.Generic.List[object]]::new(); $readMap=@{}; $reads=[Collections.Generic.List[object]]::new()
    foreach ($name in $names) {
      [uint32]$address=Convert-HexAddress ([string]$f.($name+'_address'))
      [uint64]$end=[uint64]$address+[uint64]$sizes[$name]
      if (($address-band3)-ne0 -or $end-gt4294967296) { throw 'Extended record address is unaligned or overflows' }
      foreach ($range in $ranges) { if ([uint64]$address-lt$range.end-and$range.start-lt$end) { throw 'Extended record address ranges overlap' } }
      $ranges.Add([pscustomobject]@{name=$name;start=[uint64]$address;end=$end})
      foreach ($sample in @('first','second')) {
        $key=$name+'_'+$sample+'_read_base64'
        if (-not $f.PSObject.Properties[$key] -or [string]::IsNullOrWhiteSpace([string]$f.$key)) { throw "Extended fixture lacks $key" }
        $bytes=[Convert]::FromBase64String([string]$f.$key)
        if ($bytes.Length-ne$sizes[$name]) { throw "Extended fixture $key has wrong size" }
        $readMap[$key]=$bytes
      }
    }
    $decoded=Decode-StableDiagnosticRecords -StageFirst $readMap.runtime_stage_first_read_base64 -StageSecond $readMap.runtime_stage_second_read_base64 -FifoFirst $readMap.endpoint_fifo_first_read_base64 -FifoSecond $readMap.endpoint_fifo_second_read_base64 -ExpectedRole $f.role
    $decoded['hwcdc_restart']=Decode-ExtendedRestartRecord $readMap.hwcdc_restart_first_read_base64 $readMap.hwcdc_restart_second_read_base64
    $decoded['ground_usb_commit']=Decode-ExtendedCommitRecord $readMap.ground_usb_commit_first_read_base64 $readMap.ground_usb_commit_second_read_base64 $f.role
    if($firstEnabled){$decoded['first_usb_failure']=Decode-FirstUsbFailureRecord $readMap.first_usb_failure_first_read_base64 $readMap.first_usb_failure_second_read_base64 $f.role}
    foreach ($name in $names) {
      $ordinal=0
      foreach ($sample in @('first','second')) {
        ++$ordinal; $path=Join-Path $extendedRoot ($name+'-'+$sample+'.bin')
        [IO.File]::WriteAllBytes($path,[byte[]]$readMap[$name+'_'+$sample+'_read_base64'])
        $reads.Add([ordered]@{record=$name;sample=$ordinal;path=$path;size_bytes=$sizes[$name];sha256=Get-Sha256 $path})
      }
    }
    $summary=[ordered]@{schema='vc-lora-r19-usb-extended-offline-read-v1';result='PASS';mode='offline-extended-fixture';hardware_interaction=$false;live_binding_supported=$false;fixture_sha256=Get-Sha256 $FixturePath;artifact_id=$f.artifact_id;role=$f.role;reads=@($reads);decoded=$decoded;limitations=@('Offline fixtures only; no sealed candidate, flash or live JTAG binding is provided.','The original 68/112-byte ABI and v3 live reader are unchanged.','Records represent committed diagnostic events, not continuous live hardware state.','No communication acceptance or Windows CDC consumption is proven by fixture decoding.')}
    if($firstEnabled){
      $summary.schema='vc-lora-r19-usb-extended-offline-read-v2'
      $orderedReads=[Collections.Generic.List[object]]::new()
      foreach($sample in @(1,2)){foreach($name in $names){foreach($read in $reads){if($read.record-ceq$name-and$read.sample-eq$sample){$orderedReads.Add($read)}}}}
      $summary.reads=@($orderedReads)
    }
    $summary|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $extendedRoot 'summary.json') -Encoding utf8
    $summary|ConvertTo-Json -Depth 14 -Compress
    exit 0
  } catch {
    $summary=[ordered]@{schema=$(if($firstEnabled){'vc-lora-r19-usb-extended-offline-read-v2'}else{'vc-lora-r19-usb-extended-offline-read-v1'});result='FAIL';mode='offline-extended-fixture';hardware_interaction=$false;live_binding_supported=$false;error=$_.Exception.Message}
    $summary|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $extendedRoot 'summary.json') -Encoding utf8
    $summary|ConvertTo-Json -Depth 5 -Compress
    exit 1
  }
}

if ($OfflineExtendedRecordFixtureOnly) {
  $script:ExtendedBoundParameters=$PSBoundParameters
  Invoke-OfflineExtendedRecordFixture
}

if ($Preflight) {
  $preflightMode = 'live-jtag-preflight'
  if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
      ('vc-lora-r19-jtag-preflight-' + [guid]::NewGuid().ToString('N'))
  }
  New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
  $preflightOutput = (Resolve-Path -LiteralPath $OutputRoot).Path
  $preflightSummaryPath = Join-Path $preflightOutput 'summary.json'
  $preflightLog = Join-Path $preflightOutput 'openocd-preflight.log'
  $preflightRun = $null
  $preflightHardwareInteraction = $false
  try {
    if (-not $Execute) {
      throw 'Preflight requires the explicit -Execute switch'
    }
    if ($OfflineNativeInvocationContractTest -or
        $PSBoundParameters.ContainsKey('FixturePath')) {
      throw 'Preflight cannot be combined with an offline mode'
    }
    foreach ($required in @(
      'Role', 'ProbeSerial', 'ProbeUsbLocation', 'OpenOcdExecutable',
      'OpenOcdSha256', 'InterfaceConfig', 'InterfaceConfigSha256',
      'ScriptsRoot')) {
      Require-LiveParameter $required (Get-Variable -Name $required -ValueOnly)
    }
    foreach ($forbidden in @(
      'Address', 'ArtifactRoot', 'ArtifactId', 'FlashEvidencePath',
      'FlashEvidenceSha256', 'NmExecutable', 'NmSha256', 'TargetConfig',
      'TargetConfigSha256')) {
      if ($PSBoundParameters.ContainsKey($forbidden)) {
        throw "Preflight rejects stage-read parameter: -$forbidden"
      }
    }
    Assert-ProbeBindingSyntax
    Assert-PinnedPreflightToolchain
    $preflightHardwareInteraction = $true
    $preflightRun = Invoke-JtagPreflight -LogPath $preflightLog
    if (-not $preflightRun.native.termination_proven) {
      throw 'OpenOCD preflight process termination is unproven'
    }
    if ($preflightRun.native.exit_code -ne 0 -or
        $preflightRun.native.timed_out) {
      throw "OpenOCD preflight failed with exit code $($preflightRun.native.exit_code)"
    }
    if (-not $preflightRun.open_proven -or
        -not $preflightRun.shutdown_proven) {
      throw $preflightRun.proof_error
    }
    $preflightSummary = [ordered]@{
      schema = 'vc-lora-r19-jtag-preflight-v1'
      result = 'PASS'
      status = 'PASS_JTAG_PREFLIGHT_TAP_RESET_SCAN_POSSIBLE_NO_CPU_HALT_OR_SYSTEM_RESET_COMMAND'
      mode = $preflightMode
      generated_at_utc = [DateTime]::UtcNow.ToString('o')
      hardware_interaction = $preflightHardwareInteraction
      safety = [ordered]@{
        com_opened = $false
        flash_written = $false
        target_config_loaded = $false
        cpu_halt_command_issued = $false
        system_reset_command_issued = $false
        transport_init_requested = $true
        transport_init_completion_proven = $true
        jtag_clock_activity_possible = $true
        tap_reset_or_scan_possible = $true
        target_state_modified = $null
        target_state_modification_known = $false
        process_termination_proven =
          [bool]$preflightRun.native.termination_proven
        shutdown_proven = [bool]$preflightRun.shutdown_proven
      }
      binding = [ordered]@{
        role = $Role
        requested_serial = $ProbeSerial.ToLowerInvariant()
        requested_usb_location = $ProbeUsbLocation
        opened_serial = $preflightRun.identity.serial.ToLowerInvariant()
        opened_usb_location = $preflightRun.identity.usb_location
      }
      native = $preflightRun.native
      limitations = @(
        'This gate proves the bound USB-JTAG adapter can be opened.',
        'It deliberately loads no target configuration and reads no target memory.',
        'transport init can clock, initialize, reset, or scan the JTAG TAP even without a target configuration.',
        'No CPU halt command or system reset command is issued.',
        'target_state_modified is null because TAP-state effects are possible but not proven by this preflight.',
        'It does not prove that a later target attach or runtime-stage read will succeed.'
      )
    }
    $preflightSummary | ConvertTo-Json -Depth 10 |
      Set-Content -LiteralPath $preflightSummaryPath -Encoding utf8
    $preflightSummary | ConvertTo-Json -Depth 10 -Compress
    exit 0
  } catch {
    $preflightFailure = [ordered]@{
      schema = 'vc-lora-r19-jtag-preflight-v1'
      result = 'FAIL'
      status = 'FAIL_JTAG_PREFLIGHT'
      mode = $preflightMode
      generated_at_utc = [DateTime]::UtcNow.ToString('o')
      hardware_interaction = $preflightHardwareInteraction
      safety = [ordered]@{
        com_opened = $false
        flash_written = $false
        target_config_loaded = $false
        cpu_halt_command_issued = $false
        system_reset_command_issued = $false
        transport_init_requested = [bool]$preflightHardwareInteraction
        transport_init_completion_proven = if ($null -ne $preflightRun -and
            $null -ne $preflightRun.identity) {
          [bool]$preflightRun.identity.transport_init_completed_proven
        } else { $false }
        jtag_clock_activity_possible = [bool]$preflightHardwareInteraction
        tap_reset_or_scan_possible = [bool]$preflightHardwareInteraction
        target_state_modified = if ($preflightHardwareInteraction) {
          $null
        } else { $false }
        target_state_modification_known = -not $preflightHardwareInteraction
        process_termination_proven = if ($null -ne $preflightRun) {
          [bool]$preflightRun.native.termination_proven
        } else { $true }
        shutdown_proven = if ($null -ne $preflightRun) {
          [bool]$preflightRun.shutdown_proven
        } else { $false }
      }
      binding = [ordered]@{
        role = $Role
        requested_serial = $ProbeSerial
        requested_usb_location = $ProbeUsbLocation
      }
      native = if ($null -ne $preflightRun) {
        $preflightRun.native
      } else { $null }
      limitations = @(
        'If hardware interaction began, transport init may have clocked, initialized, reset, or scanned the JTAG TAP.',
        'No target configuration, CPU halt command, system reset command, flash write, or COM open is issued.',
        'When TAP activity is possible but unproven, target_state_modified is null rather than false.'
      )
      error = $_.Exception.Message
      fail_closed = $true
    }
    $preflightFailure | ConvertTo-Json -Depth 10 |
      Set-Content -LiteralPath $preflightSummaryPath -Encoding utf8
    [Console]::Error.WriteLine(
      ($preflightFailure | ConvertTo-Json -Depth 10 -Compress))
    exit 1
  }
}

if ($OfflineNativeInvocationContractTest) {
  if ($Execute -or [string]::IsNullOrWhiteSpace($NativeContractScript) -or
      -not (Test-Path -LiteralPath $NativeContractScript -PathType Leaf)) {
    throw 'offline native invocation contract requires an existing mock script and rejects -Execute'
  }
  if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
      ('vc-lora-r19-native-contract-' + [guid]::NewGuid().ToString('N'))
  }
  New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
  $nativeContractOutput = (Resolve-Path -LiteralPath $OutputRoot).Path
  $nativeContractLog = Join-Path $nativeContractOutput 'native-contract.log'
  $nativeContractArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Resolve-Path -LiteralPath $NativeContractScript).Path,
    '-ExitCode', [string]$NativeContractExitCode,
    '-HangMilliseconds', [string]$NativeContractHangMilliseconds
  )
  $nativeContract = Invoke-NativeProcessCapture `
    -Executable (Join-Path $PSHOME 'powershell.exe') `
    -Arguments $nativeContractArguments -LogPath $nativeContractLog `
    -TimeoutMilliseconds $NativeContractTimeoutMilliseconds
  $nativeContractSummary = [ordered]@{
    schema = 'vc-lora-r19-native-process-contract-v1'
    result = if ($nativeContract.exit_code -eq 0) { 'PASS' } else { 'OBSERVED' }
    mode = 'OFFLINE_NATIVE_INVOCATION_CONTRACT'
    hardware_interaction = $false
    native = $nativeContract
  }
  $nativeContractSummary | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $nativeContractOutput 'summary.json') `
      -Encoding utf8
  $nativeContractSummary | ConvertTo-Json -Depth 8 -Compress
  exit ([int]$nativeContract.exit_code)
}

$mode = if ($Execute) { 'live-jtag' } else { 'offline-fixture' }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('vc-lora-r19-stage-read-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$resolvedOutput = (Resolve-Path -LiteralPath $OutputRoot).Path
$summaryPath = Join-Path $resolvedOutput 'summary.json'
$hardwareInteractionAttempted = $false
$script:OpenOcdProcessStarted = $false
$script:ResumeShutdownCleanupProven = $false
$script:CaptureProcessTerminationProven = $true
$script:NativeProcessesTerminationProven = $true
$script:OpenOcdStage = Get-OpenOcdLogStage -Text ''
$script:JtagFailureClassification = 'FAIL_JTAG_STAGE_READ'

try {
  $artifactBinding = $null
  $flashBinding = $null
  $capture = $null
  $captureAttempts = [System.Collections.Generic.List[object]]::new()
  $decoded = $null
  $extendedRecordsEnabled=$false
  $firstFailureEnabled=$false
  if ($Execute) {
    foreach ($required in @(
      'Role', 'Address', 'ArtifactRoot', 'ArtifactId', 'ProbeSerial',
      'ProbeUsbLocation', 'FlashEvidencePath', 'FlashEvidenceSha256',
      'NmExecutable', 'NmSha256', 'OpenOcdExecutable', 'OpenOcdSha256',
      'InterfaceConfig', 'InterfaceConfigSha256', 'TargetConfig',
      'TargetConfigSha256', 'ScriptsRoot')) {
      Require-LiveParameter $required (Get-Variable -Name $required -ValueOnly)
    }
    Assert-ProbeBindingSyntax
    Assert-PinnedToolchain
    $numericAddress = Convert-HexAddress $Address
    $artifactBinding = Assert-ArtifactBinding -Root $ArtifactRoot `
      -ExpectedArtifactId $ArtifactId -ExpectedRole $Role `
      -ExpectedAddress $numericAddress
    $extendedRecordsEnabled=[bool]$artifactBinding.extended_records_enabled
    $firstFailureEnabled=[bool]$artifactBinding.first_usb_failure_enabled
    $flashBinding = Assert-FlashBinding -LiteralPath $FlashEvidencePath `
      -ExpectedFileSha $FlashEvidenceSha256 -Artifact $artifactBinding `
      -ExpectedProbeSerial $ProbeSerial
    $expectedRole = $Role
    $effectiveArtifactId = $ArtifactId
    $effectiveAddress = $artifactBinding.address
    $effectiveFifoAddress = $artifactBinding.endpoint_fifo_address
    for ($attempt = 1; $attempt -le 3; ++$attempt) {
      $hardwareInteractionAttempted = $true
      $script:NativeProcessesTerminationProven = $false
      $capture = Read-LiveStageRecord -Artifact $artifactBinding `
        -OutputDirectory $resolvedOutput -Attempt $attempt
      $script:OpenOcdStage = $capture.openocd_stage
      $script:NativeProcessesTerminationProven =
        ([bool]$capture.capture_process_termination_proven -and
         (-not [bool]$capture.cleanup.required -or
          ([bool]$capture.cleanup.attempted -and
           [bool]$capture.cleanup.process_termination_proven)))
      if (-not $capture.capture_process_termination_proven) {
        $script:JtagFailureClassification =
          'FAIL_CAPTURE_TERMINATION_UNPROVEN'
        $captureAttempts.Add([ordered]@{
          attempt = $attempt
          result = 'FAIL_CAPTURE_TERMINATION_UNPROVEN'
          capture_exit_code = $capture.capture_exit_code
          capture_timed_out = $capture.capture_timed_out
          capture_process_termination_proven = $false
          cleanup_exit_code = $capture.cleanup.exit_code
          resume_shutdown_cleanup_proven =
            [bool]$capture.cleanup.resume_shutdown_proven
          capture_log = $capture.capture_log
          cleanup_log = $capture.cleanup_log
        })
        throw 'OpenOCD capture-process termination was not proven'
      }
      if ([bool]$capture.cleanup.required -and
          ($capture.cleanup.exit_code -ne 0 -or
           -not $capture.cleanup.resume_shutdown_proven)) {
        $script:JtagFailureClassification = 'FAIL_CLEANUP_UNPROVEN'
        $captureAttempts.Add([ordered]@{
          attempt = $attempt
          result = 'FAIL_CLEANUP_UNPROVEN'
          capture_exit_code = $capture.capture_exit_code
          smp_capture_proven = $capture.smp_capture_proven
          openocd_stage = $capture.openocd_stage
          cleanup_required = $true
          cleanup_exit_code = $capture.cleanup.exit_code
          resume_shutdown_cleanup_proven = $false
          capture_log = $capture.capture_log
          cleanup_log = $capture.cleanup_log
        })
        throw 'OpenOCD cleanup did not prove both cores resumed and shutdown'
      }
      $script:ResumeShutdownCleanupProven =
        [bool]$capture.cleanup.resume_shutdown_proven
      if ($capture.capture_exit_code -ne 0) {
        $script:JtagFailureClassification = if ($capture.capture_timed_out) {
          'FAIL_CAPTURE_TIMEOUT'
        } else {
          [string]$capture.openocd_stage.failure_classification
        }
        $captureAttempts.Add([ordered]@{
          attempt = $attempt
          result = $script:JtagFailureClassification
          capture_exit_code = $capture.capture_exit_code
          capture_timed_out = $capture.capture_timed_out
          capture_process_termination_proven =
            $capture.capture_process_termination_proven
          capture_launch_failure = $capture.capture_launch_failure
          capture_stdout_path = $capture.capture_stdout_path
          capture_stderr_path = $capture.capture_stderr_path
          cleanup_exit_code = $capture.cleanup.exit_code
          cleanup_required = [bool]$capture.cleanup.required
          cleanup_attempted = [bool]$capture.cleanup.attempted
          openocd_stage = $capture.openocd_stage
          resume_shutdown_cleanup_proven =
            [bool]$capture.cleanup.resume_shutdown_proven
          capture_log = $capture.capture_log
          cleanup_log = $capture.cleanup_log
        })
        throw "$($script:JtagFailureClassification): OpenOCD capture failed with exit code $($capture.capture_exit_code)"
      }
      if (-not $capture.smp_capture_proven) {
        throw 'OpenOCD capture log did not prove both cores halted and resumed'
      }
      if ($null -eq $capture.stage_first -or
          $null -eq $capture.stage_second -or
          $null -eq $capture.fifo_first -or
          $null -eq $capture.fifo_second) {
        throw 'OpenOCD did not produce both reads of both diagnostic records'
      }
      $stageFirstBytes = $capture.stage_first
      $stageSecondBytes = $capture.stage_second
      $fifoFirstBytes = $capture.fifo_first
      $fifoSecondBytes = $capture.fifo_second
      if($extendedRecordsEnabled) {
        $restartFirstBytes=$capture.hwcdc_restart_first; $restartSecondBytes=$capture.hwcdc_restart_second
        $commitFirstBytes=$capture.ground_usb_commit_first; $commitSecondBytes=$capture.ground_usb_commit_second
      }
      if($firstFailureEnabled){$firstFailureFirstBytes=$capture.first_usb_failure_first;$firstFailureSecondBytes=$capture.first_usb_failure_second}
      try {
        $decoded = Decode-StableDiagnosticRecords `
          -StageFirst $stageFirstBytes -StageSecond $stageSecondBytes `
          -FifoFirst $fifoFirstBytes -FifoSecond $fifoSecondBytes `
          -ExpectedRole $expectedRole
        if($extendedRecordsEnabled) {
          $decoded['hwcdc_restart']=Decode-ExtendedRestartRecord $restartFirstBytes $restartSecondBytes
          $decoded['ground_usb_commit']=Decode-ExtendedCommitRecord $commitFirstBytes $commitSecondBytes $expectedRole
        }
        if($firstFailureEnabled){$decoded['first_usb_failure']=Decode-FirstUsbFailureRecord $firstFailureFirstBytes $firstFailureSecondBytes $expectedRole $artifactBinding.first_usb_failure_decoder.sha256}
        $captureAttempts.Add([ordered]@{
          attempt = $attempt
          result = 'STABLE'
          capture_log = $capture.capture_log
          cleanup_log = $capture.cleanup_log
          cleanup_attempted = [bool]$capture.cleanup.attempted
          cleanup_exit_code = $capture.cleanup.exit_code
          resume_shutdown_cleanup_proven =
            [bool]$capture.cleanup.resume_shutdown_proven
          smp_capture_proven = [bool]$capture.smp_capture_proven
        })
        break
      } catch {
        $isTransient = Test-TransientSnapshotError $_.Exception.Message
        $captureAttempts.Add([ordered]@{
          attempt = $attempt
          result = if ($isTransient) { 'RETRY_AFTER_RESUME' } else { 'FAIL' }
          error = $_.Exception.Message
          capture_log = $capture.capture_log
          cleanup_log = $capture.cleanup_log
          cleanup_attempted = [bool]$capture.cleanup.attempted
          cleanup_exit_code = $capture.cleanup.exit_code
          resume_shutdown_cleanup_proven =
            [bool]$capture.cleanup.resume_shutdown_proven
          smp_capture_proven = [bool]$capture.smp_capture_proven
        })
        if (-not $isTransient -or $attempt -eq 3) {
          throw
        }
        # Read-LiveStageRecord always resumes and shuts down before this bounded
        # retry, allowing a firmware writer halted mid-update to finish.
      }
    }
    if ($null -eq $decoded) {
      throw 'no stable runtime stage snapshot was obtained in three attempts'
    }
  } else {
    if ($PSBoundParameters.ContainsKey('Role') -or
        $PSBoundParameters.ContainsKey('Address') -or
        $PSBoundParameters.ContainsKey('ArtifactRoot') -or
        $PSBoundParameters.ContainsKey('ProbeSerial') -or
        $PSBoundParameters.ContainsKey('ProbeUsbLocation')) {
      throw 'live binding parameters require the explicit -Execute switch'
    }
    $fixture = Read-OfflineFixture $FixturePath
    $stageFirstBytes = $fixture.stage_first
    $stageSecondBytes = $fixture.stage_second
    $fifoFirstBytes = $fixture.fifo_first
    $fifoSecondBytes = $fixture.fifo_second
    $expectedRole = $fixture.role
    $effectiveArtifactId = $fixture.artifact_id
    $effectiveAddress = $fixture.runtime_stage_address
    $effectiveFifoAddress = $fixture.endpoint_fifo_address
    $extendedRecordsEnabled=[bool]$fixture.extended_records_enabled
    $firstFailureEnabled=[bool]$fixture.first_usb_failure_enabled
    if($extendedRecordsEnabled) {
      $restartFirstBytes=$fixture.hwcdc_restart_first; $restartSecondBytes=$fixture.hwcdc_restart_second
      $commitFirstBytes=$fixture.ground_usb_commit_first; $commitSecondBytes=$fixture.ground_usb_commit_second
    }
    if($firstFailureEnabled){$firstFailureFirstBytes=$fixture.first_usb_failure_first;$firstFailureSecondBytes=$fixture.first_usb_failure_second}
  }

  if ($null -eq $decoded) {
    $decoded = Decode-StableDiagnosticRecords `
      -StageFirst $stageFirstBytes -StageSecond $stageSecondBytes `
      -FifoFirst $fifoFirstBytes -FifoSecond $fifoSecondBytes `
      -ExpectedRole $expectedRole
    if($extendedRecordsEnabled) {
      $decoded['hwcdc_restart']=Decode-ExtendedRestartRecord $restartFirstBytes $restartSecondBytes
      $decoded['ground_usb_commit']=Decode-ExtendedCommitRecord $commitFirstBytes $commitSecondBytes $expectedRole
    }
    if($firstFailureEnabled){$decoded['first_usb_failure']=Decode-FirstUsbFailureRecord $firstFailureFirstBytes $firstFailureSecondBytes $expectedRole}
  }
  $stageFirstPath = Join-Path $resolvedOutput 'runtime-stage-first.bin'
  $stageSecondPath = Join-Path $resolvedOutput 'runtime-stage-second.bin'
  $fifoFirstPath = Join-Path $resolvedOutput 'endpoint-fifo-first.bin'
  $fifoSecondPath = Join-Path $resolvedOutput 'endpoint-fifo-second.bin'
  [IO.File]::WriteAllBytes($stageFirstPath, $stageFirstBytes)
  [IO.File]::WriteAllBytes($stageSecondPath, $stageSecondBytes)
  [IO.File]::WriteAllBytes($fifoFirstPath, $fifoFirstBytes)
  [IO.File]::WriteAllBytes($fifoSecondPath, $fifoSecondBytes)
  $summary = [ordered]@{
    schema = 'vc-lora-r19-runtime-stage-jtag-read-v3'
    result = 'PASS'
    mode = $mode
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    hardware_interaction = $hardwareInteractionAttempted
    safety = [ordered]@{
      com_opened = $false
      flash_written = $false
      target_restart_issued = $false
      halted_for_reads = $Execute.IsPresent
      two_identical_reads = $true
      resume_shutdown_cleanup_attempted = if ($capture) {
        [bool]$capture.cleanup.attempted
      } else { $false }
      resume_shutdown_cleanup_proven = if ($Execute) {
        [bool]$script:ResumeShutdownCleanupProven
      } else { $false }
      capture_process_termination_proven = if ($Execute) {
        [bool]$script:CaptureProcessTerminationProven
      } else { $true }
      native_processes_termination_proven = if ($Execute) {
        [bool]$script:NativeProcessesTerminationProven
      } else { $true }
      target_may_be_halted = Get-TargetMayBeHalted `
        ([bool]$script:OpenOcdProcessStarted) `
        $script:OpenOcdStage `
        ([bool]$script:CaptureProcessTerminationProven) `
        ([bool]$script:ResumeShutdownCleanupProven)
      bounded_snapshot_attempts = if ($Execute) { $captureAttempts.Count } else { 0 }
    }
    binding = [ordered]@{
      artifact_id = $effectiveArtifactId
      role = $expectedRole
      address = $effectiveAddress
      runtime_stage_address = $effectiveAddress
      endpoint_fifo_address = $effectiveFifoAddress
      probe = if ($Execute) {
        [ordered]@{
          requested_serial = $ProbeSerial.ToLowerInvariant()
          requested_usb_location = $ProbeUsbLocation
          opened_identity_proven_before_halt = $true
        }
      } else { $null }
      artifact = $artifactBinding
      flash = $flashBinding
    }
    reads = @(
      [ordered]@{ record = 'runtime_stage'; sample = 1; path = $stageFirstPath; size_bytes = $stageFirstBytes.Length; sha256 = Get-Sha256 $stageFirstPath },
      [ordered]@{ record = 'endpoint_fifo'; sample = 1; path = $fifoFirstPath; size_bytes = $fifoFirstBytes.Length; sha256 = Get-Sha256 $fifoFirstPath },
      [ordered]@{ record = 'runtime_stage'; sample = 2; path = $stageSecondPath; size_bytes = $stageSecondBytes.Length; sha256 = Get-Sha256 $stageSecondPath },
      [ordered]@{ record = 'endpoint_fifo'; sample = 2; path = $fifoSecondPath; size_bytes = $fifoSecondBytes.Length; sha256 = Get-Sha256 $fifoSecondPath }
    )
    decoded = $decoded
    openocd_stage = if ($Execute) {$script:OpenOcdStage} else {$null}
    capture_attempts = @($captureAttempts)
    limitations = @(
      'The build fingerprint is a diagnostic generation marker, not an artifact digest.',
      'Live exact-image identity depends on the supplied installer verify evidence remaining current.',
      'Endpoint FIFO evidence reaches the native USB transaction boundary but does not prove Windows user-space CDC consumption.'
    )
  }
  if($extendedRecordsEnabled) {
    $summary.schema='vc-lora-r19-runtime-stage-jtag-read-v4'
    $summary['extended_records_required']=$true
    $summary.binding['hwcdc_restart_address']=if($Execute){$artifactBinding.hwcdc_restart_address}else{$fixture.hwcdc_restart_address}
    $summary.binding['ground_usb_commit_address']=if($Execute){$artifactBinding.ground_usb_commit_address}else{$fixture.ground_usb_commit_address}
    if($Execute) {
      # Assert-SmpCaptureLog already checked the exact opened identity before halt.
      $summary.binding.probe['opened_serial']=$ProbeSerial.ToLowerInvariant()
      $summary.binding.probe['opened_usb_location']=$ProbeUsbLocation
    }
    $extendedReads=@{}
    foreach($name in @('hwcdc_restart','ground_usb_commit')) {
      foreach($sample in @('first','second')) {
        $bytes=if($name-eq'hwcdc_restart'){if($sample-eq'first'){$restartFirstBytes}else{$restartSecondBytes}}else{if($sample-eq'first'){$commitFirstBytes}else{$commitSecondBytes}}
        $path=Join-Path $resolvedOutput (($name-replace'_','-')+'-'+$sample+'.bin')
        [IO.File]::WriteAllBytes($path,[byte[]]$bytes)
        $extendedReads[$name+'-'+$sample]=[ordered]@{record=$name;sample=$(if($sample-eq'first'){1}else{2});path=$path;size_bytes=128;sha256=Get-Sha256 $path}
      }
    }
    $legacyReads=@($summary.reads)
    $summary.reads=@($legacyReads[0],$legacyReads[1],$extendedReads['hwcdc_restart-first'],$extendedReads['ground_usb_commit-first'],$legacyReads[2],$legacyReads[3],$extendedReads['hwcdc_restart-second'],$extendedReads['ground_usb_commit-second'])
    $summary.limitations+=@('Extended restart and first Ground USB commit records are latched diagnostic events, not continuous hardware state.','Record acquisition PASS does not establish USB completion, communication acceptance, or the 932-parameter throughput goal.')
  }
  if($firstFailureEnabled){
    $summary.schema='vc-lora-r19-runtime-stage-jtag-read-v5'
    $summary['first_usb_failure_required']=$true
    $summary.binding['first_usb_failure_address']=if($Execute){$artifactBinding.first_usb_failure_address}else{$fixture.first_usb_failure_address}
    $summary.binding['first_usb_failure_decoder']=[ordered]@{path='tools/read_r19_first_usb_failure_record.ps1';sha256=$(if($Execute){$artifactBinding.first_usb_failure_decoder.sha256}else{$script:R19LastVerifiedDecoderSha256})}
    $firstPair=@{}
    foreach($sample in @('first','second')){
      [byte[]]$bytes=if($sample-eq'first'){$firstFailureFirstBytes}else{$firstFailureSecondBytes}
      $path=Join-Path $resolvedOutput ('first-usb-failure-'+$sample+'.bin');[IO.File]::WriteAllBytes($path,$bytes)
      $firstPair[$sample]=[ordered]@{record='first_usb_failure';sample=$(if($sample-eq'first'){1}else{2});path=$path;size_bytes=384;sha256=Get-Sha256 $path}
    }
    $old=@($summary.reads)
    $summary.reads=@($old[0],$old[1],$old[2],$old[3],$firstPair.first,$old[4],$old[5],$old[6],$old[7],$firstPair.second)
    $summary.limitations+=@('Boot instance comes from the raw record; matching a later PC exchange requires its exact nonce/device sample and independent clock continuity/error bounds.','PC/device causal time ordering is UNKNOWN until the independently bounded exchange is supplied.')
  }
  $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding utf8
  $summary | ConvertTo-Json -Depth 12 -Compress
} catch {
  $failure = [ordered]@{
    schema = if($firstFailureEnabled){'vc-lora-r19-runtime-stage-jtag-read-v5'}elseif($extendedRecordsEnabled){'vc-lora-r19-runtime-stage-jtag-read-v4'}else{'vc-lora-r19-runtime-stage-jtag-read-v3'}
    result = 'FAIL'
    status = $script:JtagFailureClassification
    mode = $mode
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    hardware_interaction = $hardwareInteractionAttempted
    safety = [ordered]@{
      resume_shutdown_cleanup_proven =
        [bool]$script:ResumeShutdownCleanupProven
      target_may_be_halted =
        (Get-TargetMayBeHalted `
          ([bool]$script:OpenOcdProcessStarted) `
          $script:OpenOcdStage `
          ([bool]$script:CaptureProcessTerminationProven) `
          ([bool]$script:ResumeShutdownCleanupProven))
      capture_process_termination_proven =
        [bool]$script:CaptureProcessTerminationProven
      native_processes_termination_proven =
        [bool]$script:NativeProcessesTerminationProven
      device_opened = [bool]$script:OpenOcdStage.device_opened
      target_examined = [bool]$script:OpenOcdStage.target_examined
      halt_possible = [bool]$script:OpenOcdStage.halt_possible
      resume_proven = ([bool]$script:OpenOcdStage.resume_proven -or
        [bool]$script:ResumeShutdownCleanupProven)
    }
    binding = [ordered]@{
      role = $Role
      requested_serial = $ProbeSerial
      requested_usb_location = $ProbeUsbLocation
    }
    openocd_stage = $script:OpenOcdStage
    capture_attempts = if ($null -ne $captureAttempts) {
      @($captureAttempts)
    } else { @() }
    error = $_.Exception.Message
    fail_closed = $true
  }
  $failure | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
  [Console]::Error.WriteLine(($failure | ConvertTo-Json -Depth 8 -Compress))
  exit 1
}
