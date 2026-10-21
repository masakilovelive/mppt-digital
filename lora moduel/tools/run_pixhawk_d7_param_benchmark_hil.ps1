[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$EvidenceRoot,
  [string]$RepoRoot = '',
  [switch]$Execute,
  [switch]$OfflineSelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$newline = [Environment]::NewLine
$startedUtc = [DateTime]::UtcNow.ToString('o')

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
$allowedEvidenceBase = Join-Path $repo `
    'runs\high_speed\R19-HS-G1-D7-DIRECT-HIL-001'

$candidate = [ordered]@{
  name='D7 direct benchmark';key='candidate'
  source=Join-Path $repo `
      'runs\candidates\R19-HS-G1-D7-BENCHMARK-004\20260915T114743494Z\firmware\vc_lora_vehicle_pixhawk_param_benchmark_xiao_esp32s3.ino.bin'
  bytes=[int64]288864
  sha256='493DA28D328E6F6DBBEE457887B81F29674F44A987E6A2879277BE686C1CF897'
  stage_path=''
}
$candidateSource = [ordered]@{
  name='D7 direct benchmark frozen source';key='candidate_source'
  source=Join-Path $repo `
      'runs\candidates\R19-HS-G1-D7-BENCHMARK-004\20260915T114743494Z\source\vc_lora_vehicle_pixhawk_param_benchmark_xiao_esp32s3.ino'
  bytes=[int64]24999
  sha256='5328C86DC88F403802D2F9521DA016D9DC39AE74BCBD5A2518B84ED2EC20E5EB'
  stage_path=''
}
$rollback = [ordered]@{
  name='R18 accepted Vehicle production application';key='rollback'
  source=Join-Path $repo `
      'runs\baselines\R18-PRODUCTION-R4-ACCEPTED\20260914T225054625Z\artifacts\vehicle.application.bin'
  bytes=[int64]389280
  sha256='9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52'
  stage_path=''
}
$espTool = [ordered]@{
  name='R18 staged esptool 5.3.1';key='esptool'
  source=Join-Path $repo `
      'runs\hil\R18-PHASE6-PRODUCTION-FLASH-001\20260914T131232863Z-f70bdf89\staged\esptool-5.3.1.exe'
  bytes=[int64]14323136
  sha256='A939E28FE2FBB53E65E46F0246A4D71B9FD6C052EF0E046182DF4A4FE8BEC946'
  version='5.3.1'
  stage_path=''
}
$vehicle = [ordered]@{
  name='Vehicle';port='COM3';vid='303A';pid='1001'
  pnp='USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000'
  parent='USB\VID_303A&PID_1001\90:70:69:11:81:A4'
  mac='90:70:69:11:81:a4'
}

$script:DeviceAccessAttempted = $false
$script:ProcessInventoryQueried = $false
$script:PnpQueried = $false
$script:ComPortsEnumerated = $false
$script:ComPortsOpened = $false
$script:EspToolExecuted = $false
$script:FirmwareWriteAttempted = $false
$script:FirmwareMayHaveChanged = $false
$script:RestoreAttempted = $false
$script:RestoreVerified = $false
$script:RestoreAttempts = [Collections.ArrayList]::new()
$script:RecoveryEvidenceFailures = [Collections.ArrayList]::new()
$script:RestoreFailure = ''
$script:MainFailure = ''
$script:FlashSteps = [Collections.ArrayList]::new()
$script:MeasurementRuns = [Collections.ArrayList]::new()
$script:ProtocolIdentity = $null
$script:StageLocks = [Collections.ArrayList]::new()
$script:RunnerStartSha256 = ''
$script:RunnerStagePath = ''
$script:RunnerStageSha256 = ''
$script:RunnerBytes = [int64]0
$script:RunnerLock = $null
$script:Result = 'FAIL'
$script:Status = 'NOT_STARTED'
$evidence = $null

function Assert-Condition([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Get-Sha([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Lock-RunnerSource {
  Assert-Condition (Test-Path -LiteralPath $PSCommandPath -PathType Leaf) `
      'Runner source path is unavailable.'
  $before = Get-Sha $PSCommandPath
  $lock = [IO.FileStream]::new(
      $PSCommandPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,
      [IO.FileShare]::Read,4096,[IO.FileOptions]::SequentialScan)
  try {
    $after = Get-Sha $PSCommandPath
    Assert-Condition ($before -ceq $after) `
        'Runner source changed while acquiring its immutable run lock.'
    $stageDirectory = Join-Path $evidence 'staged'
    [void][IO.Directory]::CreateDirectory($stageDirectory)
    $stagePath = Join-Path $stageDirectory 'runner.executed.ps1'
    $lock.Position = 0
    $target = [IO.FileStream]::new(
        $stagePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,
        [IO.FileShare]::Read,65536,[IO.FileOptions]::WriteThrough)
    try {
      $lock.CopyTo($target,65536)
      $target.Flush($true)
    } finally {
      $target.Dispose()
    }
    $stageSha = Get-Sha $stagePath
    Assert-Condition ($stageSha -ceq $after) `
        'Sealed runner copy is not byte-exact with the locked source.'
    $stageLock = [IO.FileStream]::new(
        $stagePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,
        [IO.FileShare]::Read,4096,[IO.FileOptions]::SequentialScan)
    [void]$script:StageLocks.Add($stageLock)
    $script:RunnerStartSha256 = $after
    $script:RunnerStagePath = (Resolve-Path -LiteralPath $stagePath).Path
    $script:RunnerStageSha256 = $stageSha
    $script:RunnerBytes = (Get-Item -LiteralPath $PSCommandPath).Length
    $script:RunnerLock = $lock
    $lock = $null
  } finally {
    if ($null -ne $lock) {$lock.Dispose()}
  }
}

function Assert-RunnerStagePinned([string]$Checkpoint) {
  Assert-Condition ($null -ne $script:RunnerLock) `
      "Runner source lock is absent at $Checkpoint"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace(
      $script:RunnerStartSha256)) "Runner start SHA is absent at $Checkpoint"
  Assert-Condition (Test-Path -LiteralPath $script:RunnerStagePath `
      -PathType Leaf) "Sealed runner copy disappeared at $Checkpoint"
  $stage = Get-Item -LiteralPath $script:RunnerStagePath
  Assert-Condition ([int64]$stage.Length -eq $script:RunnerBytes) `
      "Sealed runner copy size drift at $Checkpoint"
  $stageSha = Get-Sha $stage.FullName
  Assert-Condition ($stageSha -ceq $script:RunnerStageSha256 -and
      $stageSha -ceq $script:RunnerStartSha256) `
      "Sealed runner copy SHA drift at $Checkpoint"
}

function Assert-RunnerPinned([string]$Checkpoint) {
  Assert-RunnerStagePinned $Checkpoint
  Assert-Condition (Test-Path -LiteralPath $PSCommandPath -PathType Leaf) `
      "Runner source disappeared at $Checkpoint"
  $actual = Get-Sha $PSCommandPath
  Assert-Condition ($actual -ceq $script:RunnerStartSha256) `
      ("Runner source SHA drift at {0}: expected={1} actual={2}" -f
       $Checkpoint,$script:RunnerStartSha256,$actual)
}

function Get-RunnerSourceIntegrity {
  try {
    Assert-Condition (Test-Path -LiteralPath $PSCommandPath -PathType Leaf) `
        'Runner source disappeared before evidence finalization.'
    $item = Get-Item -LiteralPath $PSCommandPath
    $actual = Get-Sha $item.FullName
    Assert-Condition ([int64]$item.Length -eq $script:RunnerBytes) `
        'Runner source size changed before evidence finalization.'
    Assert-Condition ($actual -ceq $script:RunnerStartSha256) `
        'Runner source SHA changed before evidence finalization.'
    [pscustomobject][ordered]@{
      result='PASS';path=$item.FullName;bytes=[int64]$item.Length
      sha256=$actual;expected_sha256=$script:RunnerStartSha256;failure=''
    }
  } catch {
    [pscustomobject][ordered]@{
      result='FAIL';path=$PSCommandPath;bytes=$null;sha256=$null
      expected_sha256=$script:RunnerStartSha256
      failure=$_.Exception.Message
    }
  }
}

function Write-Durable([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($parent)) `
      "Durable output has no parent: $Path"
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($parent)
  }
  $bytes = $utf8.GetBytes($Text)
  $stream = [IO.FileStream]::new(
      $Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
      [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
  try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
}

function Write-DurableJson([string]$Path, [object]$Value) {
  Write-Durable $Path ((ConvertTo-Json -InputObject $Value -Depth 32) +
      $newline)
  [void]([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Invoke-BestEffortEvidenceWrite(
    [string]$Label, [scriptblock]$Writer) {
  try {
    [void](& $Writer)
    [pscustomobject][ordered]@{
      label=$Label;result='PASS';failure=''
    }
  } catch {
    [pscustomobject][ordered]@{
      label=$Label;result='FAIL';failure=$_.Exception.Message
    }
  }
}

function Add-RecoveryEvidenceFailure([object]$Failure) {
  [void]$script:RecoveryEvidenceFailures.Add([pscustomobject][ordered]@{
    captured_utc=[DateTime]::UtcNow.ToString('o')
    label=[string]$Failure.label;failure=[string]$Failure.failure
  })
}

function Invoke-BoundedRecoveryOrchestration(
    [scriptblock]$AttemptExecutor, [scriptblock]$AttemptEvidenceWriter,
    [int]$MaxAttempts = 3, [int]$RetryDelayMilliseconds = 0,
    [switch]$UpdateGlobalRestoreState) {
  Assert-Condition ($MaxAttempts -eq 3) `
      'Production recovery must have exactly three bounded attempts.'
  Assert-Condition ($RetryDelayMilliseconds -ge 0 -and
      $RetryDelayMilliseconds -le 5000) `
      'Recovery retry delay is outside 0..5000 ms.'
  $attempts = [Collections.ArrayList]::new()
  $evidenceFailures = [Collections.ArrayList]::new()
  $executorFailures = [Collections.ArrayList]::new()
  $hardwareVerified = $false
  for ($attempt = 1; $attempt -le $MaxAttempts; ++$attempt) {
    $started = [DateTime]::UtcNow.ToString('o')
    try {
      $outcome = & $AttemptExecutor $attempt
      Assert-Condition ($null -ne $outcome) `
          "Recovery executor returned no outcome for attempt $attempt."
      Assert-Condition ([string]$outcome.result -in @('PASS','FAIL')) `
          "Recovery executor result is invalid for attempt $attempt."
    } catch {
      $outcome = [pscustomobject][ordered]@{
        result='FAIL';failure=$_.Exception.Message
        process_inventory=$null;flash_steps=@()
      }
    }
    $passed = [string]$outcome.result -ceq 'PASS'
    $failure = if ($passed) {''} else {[string]$outcome.failure}
    if (-not $passed) {
      if ([string]::IsNullOrWhiteSpace($failure)) {
        $failure = 'Recovery executor returned FAIL without a reason.'
      }
      [void]$executorFailures.Add("attempt_${attempt}:$failure")
    }
    $record = [pscustomobject][ordered]@{
      attempt=$attempt;result=if ($passed) {'PASS'} else {'FAIL'}
      failure=$failure;started_utc=$started
      finished_utc=[DateTime]::UtcNow.ToString('o')
      process_inventory=$outcome.process_inventory
      flash_steps=@($outcome.flash_steps)
      evidence_write_result='PASS';evidence_write_failure=''
    }
    [void]$attempts.Add($record)
    if ($passed) {
      # This in-memory state transition intentionally precedes all attempt-log
      # persistence. Evidence I/O can never turn verified hardware into an
      # additional flash attempt.
      $hardwareVerified = $true
      if ($UpdateGlobalRestoreState.IsPresent) {
        $script:RestoreVerified = $true
      }
    }
    try {
      [void](& $AttemptEvidenceWriter $record $attempt `
          $(if ($passed) {'pass'} else {'fail'}))
    } catch {
      $record.evidence_write_result = 'FAIL'
      $record.evidence_write_failure = $_.Exception.Message
      [void]$evidenceFailures.Add([pscustomobject][ordered]@{
        label="restore_attempt_${attempt}_record"
        result='FAIL';failure=$_.Exception.Message
      })
    }
    if ($hardwareVerified) { break }
    if ($attempt -lt $MaxAttempts -and $RetryDelayMilliseconds -gt 0) {
      Start-Sleep -Milliseconds $RetryDelayMilliseconds
    }
  }
  [pscustomobject][ordered]@{
    hardware_verified=$hardwareVerified
    attempts=@($attempts);evidence_write_failures=@($evidenceFailures)
    executor_failures=@($executorFailures)
  }
}

function Flush-Existing([string]$Path) {
  $stream = [IO.FileStream]::new(
      $Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
      [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
  try { $stream.Flush($true) } finally { $stream.Dispose() }
}

function Get-RelativeEvidencePath([string]$Path) {
  $absolute = (Resolve-Path -LiteralPath $Path).Path
  $prefix = $evidence.TrimEnd('\') + '\'
  Assert-Condition ($absolute.StartsWith(
      $prefix, [StringComparison]::OrdinalIgnoreCase)) `
      "Evidence path escaped run root: $absolute"
  $absolute.Substring($prefix.Length).Replace('\', '/')
}

function Initialize-EvidenceRoot([string]$Requested) {
  [void][IO.Directory]::CreateDirectory($allowedEvidenceBase)
  $allowed = [IO.Path]::GetFullPath($allowedEvidenceBase).TrimEnd('\')
  $candidatePath = [IO.Path]::GetFullPath($Requested).TrimEnd('\')
  $prefix = $allowed + '\'
  Assert-Condition ($candidatePath.StartsWith(
      $prefix, [StringComparison]::OrdinalIgnoreCase)) `
      "EvidenceRoot must be a new child of $allowed"
  Assert-Condition (-not (Test-Path -LiteralPath $candidatePath)) `
      "EvidenceRoot already exists; refusing overwrite: $candidatePath"
  $parent = Split-Path -Parent $candidatePath
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($parent)) `
      'EvidenceRoot has no parent.'
  [void][IO.Directory]::CreateDirectory($parent)
  [void][IO.Directory]::CreateDirectory($candidatePath)
  (Resolve-Path -LiteralPath $candidatePath).Path.TrimEnd('\')
}

function Assert-PinnedFile([object]$Pin, [string]$Checkpoint) {
  Assert-Condition (Test-Path -LiteralPath $Pin.source -PathType Leaf) `
      "$($Pin.name) is missing at $Checkpoint"
  $item = Get-Item -LiteralPath $Pin.source
  Assert-Condition ([int64]$item.Length -eq [int64]$Pin.bytes) `
      ("{0} size mismatch at {1}: expected={2} actual={3}" -f
       $Pin.name,$Checkpoint,$Pin.bytes,$item.Length)
  $sha = Get-Sha $item.FullName
  Assert-Condition ($sha -ceq [string]$Pin.sha256) `
      ("{0} SHA-256 mismatch at {1}: expected={2} actual={3}" -f
       $Pin.name,$Checkpoint,$Pin.sha256,$sha)
  [pscustomobject][ordered]@{
    path=$item.FullName;bytes=[int64]$item.Length;sha256=$sha
  }
}

function Test-StaticPins {
  $candidatePin = Assert-PinnedFile $candidate 'static_preflight'
  $candidateSourcePin = Assert-PinnedFile $candidateSource 'static_preflight'
  $rollbackPin = Assert-PinnedFile $rollback 'static_preflight'
  $espToolPin = Assert-PinnedFile $espTool 'static_preflight'
  Assert-Condition ([string]$vehicle.port -ceq 'COM3' `
      -and [string]$vehicle.vid -ceq '303A' `
      -and [string]$vehicle.pid -ceq '1001') `
      'Vehicle COM/VID/PID static pin changed.'
  Assert-Condition ([string]$vehicle.pnp -ceq
      'USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000') `
      'Vehicle interface PNP static pin changed.'
  Assert-Condition ([string]$vehicle.parent -ceq
      'USB\VID_303A&PID_1001\90:70:69:11:81:A4') `
      'Vehicle parent identity static pin changed.'
  Assert-Condition ([string]$vehicle.mac -ceq '90:70:69:11:81:a4') `
      'Vehicle efuse MAC static pin changed.'
  [pscustomobject][ordered]@{
    result='PASS';candidate=$candidatePin
    candidate_frozen_source=$candidateSourcePin;rollback=$rollbackPin
    esptool=$espToolPin;vehicle=$vehicle
  }
}

function New-BaseEspToolArgv {
  @('--chip','esp32s3','--port',[string]$vehicle.port,
    '--baud','921600','--before','default-reset','--after','hard-reset')
}

function New-EspToolArgv([ValidateSet('read_mac','write','verify')]
                         [string]$Kind, [string]$ApplicationPath = '') {
  [string[]]$base = @(New-BaseEspToolArgv)
  if ($Kind -ceq 'read_mac') { return [string[]]($base + @('read-mac')) }
  if ($Kind -ceq 'write') {
    return [string[]]($base + @(
      'write-flash','-z','--flash-mode','keep','--flash-freq','keep',
      '--flash-size','keep','0x10000',$ApplicationPath))
  }
  [string[]]($base + @('verify-flash','0x10000',$ApplicationPath))
}

function Assert-SafeEspToolArgv(
    [ValidateSet('read_mac','write','verify')][string]$Kind,
    [string[]]$Tokens, [string]$ExpectedApplication = '') {
  Assert-Condition ($Tokens.Count -ge 11) 'esptool argv is too short.'
  $expectedBase = @('--chip','esp32s3','--port','COM3','--baud','921600',
    '--before','default-reset','--after','hard-reset')
  for ($index = 0; $index -lt $expectedBase.Count; ++$index) {
    Assert-Condition ($Tokens[$index] -ceq $expectedBase[$index]) `
        "esptool base argv mismatch at token $index"
  }
  foreach ($token in $Tokens) {
    $lower = $token.ToLowerInvariant()
    Assert-Condition ($lower -notin @(
        'erase-flash','erase-all','0x0','0x8000','0xe000')) `
        "forbidden esptool token: $token"
    Assert-Condition (-not $lower.EndsWith('.merged.bin')) `
        'merged application images are forbidden.'
    Assert-Condition ($lower -notmatch 'bootloader|partitions') `
        'bootloader and partitions image paths are forbidden.'
  }
  if ($Kind -ceq 'read_mac') {
    Assert-Condition ($Tokens.Count -eq 11 -and
        $Tokens[10] -ceq 'read-mac') 'read-mac argv is not exact.'
    return
  }
  Assert-Condition (@($Tokens | Where-Object {$_ -ceq '0x10000'}).Count `
      -eq 1) 'application offset must be exactly one 0x10000.'
  Assert-Condition (@($Tokens | Where-Object {
      $_.EndsWith('.bin',[StringComparison]::OrdinalIgnoreCase)}).Count `
      -eq 1) 'esptool argv must contain exactly one application binary.'
  Assert-Condition (@($Tokens | Where-Object {
      $_ -ceq $ExpectedApplication}).Count -eq 1) `
      'esptool argv does not select the exact pinned staged application.'
  if ($Kind -ceq 'write') {
    Assert-Condition ($Tokens.Count -eq 20 -and
        $Tokens[10] -ceq 'write-flash') 'write-flash argv is not exact.'
    $expectedTail = @('-z','--flash-mode','keep','--flash-freq','keep',
      '--flash-size','keep','0x10000',$ExpectedApplication)
    for ($index = 0; $index -lt $expectedTail.Count; ++$index) {
      Assert-Condition ($Tokens[$index + 11] -ceq $expectedTail[$index]) `
          "write-flash tail mismatch at token $index"
    }
  } else {
    Assert-Condition ($Tokens.Count -eq 13 -and
        $Tokens[10] -ceq 'verify-flash' -and
        $Tokens[11] -ceq '0x10000' -and
        $Tokens[12] -ceq $ExpectedApplication) `
        'verify-flash argv is not exact.'
  }
}

function Convert-ResultLine([string]$Line) {
  Assert-Condition ($Line.StartsWith('[RESULT] ',
      [StringComparison]::Ordinal)) 'Line is not a RESULT record.'
  $body = $Line.Substring(9)
  $fields = [ordered]@{}
  foreach ($token in @($body -split ' ' | Where-Object {$_ -ne ''})) {
    $match = [regex]::Match($token, '^(?<key>[a-z0-9_]+)=(?<value>[^\s=]+)$')
    Assert-Condition $match.Success "Malformed RESULT token: $token"
    $key = $match.Groups['key'].Value
    Assert-Condition (-not $fields.Contains($key)) `
        "Duplicate RESULT key: $key"
    $fields[$key] = $match.Groups['value'].Value
  }
  $fields
}

function Convert-StrictUnsigned([object]$Fields, [string]$Name) {
  Assert-Condition $Fields.Contains($Name) "Missing RESULT field: $Name"
  [uint64]$value = 0
  Assert-Condition ([uint64]::TryParse(
      [string]$Fields[$Name], [ref]$value)) `
      "RESULT field is not uint64: $Name=$($Fields[$Name])"
  $value
}

function Assert-StrictResult([string]$Line, [string]$ExpectedNonce) {
  $fields = Convert-ResultLine $Line
  $expectedFields = @(
    'protocol','nonce','result','reason','trigger','data_result','heartbeat_result',
    'target_10s_data_result','target_30s_data_result','target_10s_result',
    'target_30s_result','request_writes','expected','unique','missing',
    'duplicate','out_of_order','out_of_range','wrong_source',
    'count_mismatch','bad_payload','parameter_frames','stat_runtime_excluded',
    'd7_bytes','request_enqueue_us','request_tx_complete_us',
    'request_tx_duration_us','write_semantics','crc_scope',
    'request_to_first_us','request_to_last_us','first_to_last_us',
    'heartbeat_count','heartbeat_max_gap_us','post_list_heartbeat_us',
    'list_complete_to_post_heartbeat_us','crc_errors','bad_lengths',
    'unsupported_flags','noise_bytes')
  Assert-Condition ($fields.Count -eq $expectedFields.Count) `
      "RESULT field count mismatch: expected=$($expectedFields.Count) actual=$($fields.Count)"
  $actualFields = @($fields.Keys)
  for ($fieldIndex = 0; $fieldIndex -lt $expectedFields.Count;
       ++$fieldIndex) {
    $name = $expectedFields[$fieldIndex]
    Assert-Condition $fields.Contains($name) "Missing RESULT field: $name"
    Assert-Condition ([string]$actualFields[$fieldIndex] -ceq $name) `
        ("RESULT field order mismatch at {0}: expected={1} actual={2}" -f
         $fieldIndex,$name,$actualFields[$fieldIndex])
  }
  Assert-Condition ([string]$fields.protocol -ceq
      'PIXHAWK_D7_PARAM_BENCHMARK_V2') `
      "RESULT protocol identity mismatch: $($fields.protocol)"
  Assert-Condition ([string]$fields.nonce -ceq $ExpectedNonce) `
      'RESULT nonce mismatch.'
  Assert-Condition ([string]$fields.result -ceq 'PASS') `
      "Device RESULT is not PASS: $($fields.result)"
  Assert-Condition ([string]$fields.reason -ceq
      'strict_932_and_post_heartbeat') `
      "Device RESULT reason is not strict_932_and_post_heartbeat: $($fields.reason)"
  Assert-Condition ([string]$fields.trigger -ceq 'post_list_heartbeat') `
      "Device RESULT trigger is not post_list_heartbeat: $($fields.trigger)"
  Assert-Condition ([string]$fields.data_result -ceq 'PASS') `
      "Device strict data result is not PASS: $($fields.data_result)"
  Assert-Condition ([string]$fields.heartbeat_result -ceq 'PASS') `
      "Device heartbeat result is not PASS: $($fields.heartbeat_result)"
  Assert-Condition ([string]$fields.write_semantics -ceq
      'arduino_length_then_uart_tx_idle') `
      "Unexpected request write semantics: $($fields.write_semantics)"
  Assert-Condition ([string]$fields.crc_scope -ceq
      'heartbeat_and_param_value_only') `
      "Unexpected CRC scope: $($fields.crc_scope)"

  foreach ($pair in @(
      @('request_writes',[uint64]1),@('expected',[uint64]932),
      @('unique',[uint64]932))) {
    $actual = Convert-StrictUnsigned $fields $pair[0]
    Assert-Condition ($actual -eq [uint64]$pair[1]) `
        "RESULT $($pair[0]) mismatch: $actual"
  }
  foreach ($name in @(
      'missing','duplicate','out_of_order','out_of_range','wrong_source',
      'count_mismatch','bad_payload','crc_errors','bad_lengths',
      'unsupported_flags','noise_bytes')) {
    $actual = Convert-StrictUnsigned $fields $name
    Assert-Condition ($actual -eq 0) "RESULT anomaly is nonzero: $name=$actual"
  }
  $d7Bytes = Convert-StrictUnsigned $fields 'd7_bytes'
  $parameterFrames = Convert-StrictUnsigned $fields 'parameter_frames'
  $statRuntimeExcluded = Convert-StrictUnsigned $fields 'stat_runtime_excluded'
  $requestEnqueue = Convert-StrictUnsigned $fields 'request_enqueue_us'
  $requestTxComplete = Convert-StrictUnsigned $fields 'request_tx_complete_us'
  $requestTxDuration = Convert-StrictUnsigned $fields 'request_tx_duration_us'
  $toFirst = Convert-StrictUnsigned $fields 'request_to_first_us'
  $toLast = Convert-StrictUnsigned $fields 'request_to_last_us'
  $firstToLast = Convert-StrictUnsigned $fields 'first_to_last_us'
  $heartbeatCount = Convert-StrictUnsigned $fields 'heartbeat_count'
  $heartbeatMaxGap = Convert-StrictUnsigned $fields 'heartbeat_max_gap_us'
  $postListHeartbeat = Convert-StrictUnsigned $fields 'post_list_heartbeat_us'
  $listToHeartbeat = Convert-StrictUnsigned $fields `
      'list_complete_to_post_heartbeat_us'
  Assert-Condition ($d7Bytes -gt 0) 'RESULT d7_bytes must be positive.'
  Assert-Condition ($parameterFrames -eq 932 + $statRuntimeExcluded) `
      ("RESULT #22 accounting mismatch: frames={0} indexed=932 sentinel={1}" -f
       $parameterFrames,$statRuntimeExcluded)
  Assert-Condition ($requestEnqueue -gt 0 -and
      $requestTxComplete -ge $requestEnqueue -and
      $requestTxDuration -eq ($requestTxComplete - $requestEnqueue)) `
      'RESULT enqueue/TX-idle request timing is inconsistent.'
  Assert-Condition ($toFirst -gt 0 -and $toFirst -le $toLast) `
      'RESULT request_to_first_us is outside request/last bounds.'
  Assert-Condition ($toLast -gt 0 -and $toLast -le 120000000) `
      'RESULT request_to_last_us exceeds the 120000000 us device bound.'
  Assert-Condition ($firstToLast -le $toLast) `
      'RESULT first_to_last_us exceeds request_to_last_us.'
  Assert-Condition ($heartbeatCount -ge 2) `
      'RESULT contains fewer than two in-run primary heartbeats.'
  Assert-Condition ($heartbeatMaxGap -le 2500000) `
      'RESULT heartbeat_max_gap_us exceeds 2500000 us.'
  Assert-Condition ($postListHeartbeat -gt 0 -and
      $listToHeartbeat -le 2500000) `
      'RESULT post-list heartbeat is absent or later than 2500000 us.'

  $target10 = if ($toLast -le 10000000) {'PASS'} else {'FAIL'}
  $target30 = if ($toLast -le 30000000) {'PASS'} else {'FAIL'}
  foreach ($name in @('target_10s_data_result','target_10s_result')) {
    Assert-Condition ([string]$fields[$name] -ceq $target10) `
        "RESULT $name is inconsistent with request_to_last_us=$toLast"
  }
  foreach ($name in @('target_30s_data_result','target_30s_result')) {
    Assert-Condition ([string]$fields[$name] -ceq $target30) `
        "RESULT $name is inconsistent with request_to_last_us=$toLast"
  }

  [pscustomobject][ordered]@{
    protocol=[string]$fields.protocol
    nonce=[string]$fields.nonce
    result=[string]$fields.result
    reason=[string]$fields.reason
    trigger=[string]$fields.trigger
    data_result=[string]$fields.data_result
    heartbeat_result=[string]$fields.heartbeat_result
    target_10s_data_result=[string]$fields.target_10s_data_result
    target_30s_data_result=[string]$fields.target_30s_data_result
    target_10s_result=[string]$fields.target_10s_result
    target_30s_result=[string]$fields.target_30s_result
    target_10s_met=($target10 -ceq 'PASS')
    target_30s_met=($target30 -ceq 'PASS')
    request_writes=[uint64]$fields.request_writes
    expected=[uint64]$fields.expected
    unique=[uint64]$fields.unique
    missing=[uint64]$fields.missing
    duplicate=[uint64]$fields.duplicate
    out_of_order=[uint64]$fields.out_of_order
    out_of_range=[uint64]$fields.out_of_range
    wrong_source=[uint64]$fields.wrong_source
    count_mismatch=[uint64]$fields.count_mismatch
    bad_payload=[uint64]$fields.bad_payload
    parameter_frames=[uint64]$fields.parameter_frames
    stat_runtime_excluded=[uint64]$fields.stat_runtime_excluded
    d7_bytes=[uint64]$fields.d7_bytes
    request_enqueue_us=[uint64]$fields.request_enqueue_us
    request_tx_complete_us=[uint64]$fields.request_tx_complete_us
    request_tx_duration_us=[uint64]$fields.request_tx_duration_us
    write_semantics=[string]$fields.write_semantics
    crc_scope=[string]$fields.crc_scope
    request_to_first_us=[uint64]$fields.request_to_first_us
    request_to_last_us=[uint64]$fields.request_to_last_us
    first_to_last_us=[uint64]$fields.first_to_last_us
    heartbeat_count=[uint64]$fields.heartbeat_count
    heartbeat_max_gap_us=[uint64]$fields.heartbeat_max_gap_us
    post_list_heartbeat_us=[uint64]$fields.post_list_heartbeat_us
    list_complete_to_post_heartbeat_us=
        [uint64]$fields.list_complete_to_post_heartbeat_us
    crc_errors=[uint64]$fields.crc_errors
    bad_lengths=[uint64]$fields.bad_lengths
    unsupported_flags=[uint64]$fields.unsupported_flags
    noise_bytes=[uint64]$fields.noise_bytes
  }
}

function Convert-StrictReadyLine([string]$Line) {
  Assert-Condition ($Line.StartsWith('[READY]',
      [StringComparison]::Ordinal)) 'Line is not a READY record.'
  $match = [regex]::Match($Line,
      '^\[READY\] protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 role=vehicle uart=2 rx=D7 tx=D6 baud=57600 expected=932 heartbeat_count=(?<count>[0-9]+) heartbeat_age_us=(?<age>NA|[0-9]+) indexed_quiet_age_us=(?<quiet>[0-9]+) heartbeat_last_gap_us=(?<lastgap>NA|[0-9]+) parser_idle=(?<idle>[01]) command=START <nonce>$')
  Assert-Condition $match.Success "Malformed or foreign READY: $Line"
  [uint64]$count = [uint64]$match.Groups['count'].Value
  [uint64]$quiet = [uint64]$match.Groups['quiet'].Value
  $age = if ($match.Groups['age'].Value -ceq 'NA') {$null} else {
    [uint64]$match.Groups['age'].Value
  }
  $lastGap = if ($match.Groups['lastgap'].Value -ceq 'NA') {$null} else {
    [uint64]$match.Groups['lastgap'].Value
  }
  [pscustomobject][ordered]@{
    protocol='PIXHAWK_D7_PARAM_BENCHMARK_V2'
    heartbeat_count=$count;heartbeat_age_us=$age
    indexed_quiet_age_us=$quiet;heartbeat_last_gap_us=$lastGap
    parser_idle=($match.Groups['idle'].Value -ceq '1');line=$Line
  }
}

function Convert-StrictStartAckLine(
    [string]$Line, [string]$ExpectedNonce) {
  $match = [regex]::Match($Line,
      '^\[START_ACK\] protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 nonce=(?<nonce>[a-f0-9]{32}) request_writes=1 target=1/1$')
  Assert-Condition $match.Success "Malformed or foreign START_ACK: $Line"
  Assert-Condition ($match.Groups['nonce'].Value -ceq $ExpectedNonce) `
      "START_ACK nonce mismatch: $Line"
  [pscustomobject][ordered]@{
    protocol='PIXHAWK_D7_PARAM_BENCHMARK_V2'
    nonce=$match.Groups['nonce'].Value;request_writes=1;target='1/1'
  }
}

function Assert-ProgressProtocol([string]$Line, [string]$ExpectedNonce) {
  $match = [regex]::Match($Line,
      '^\[PROGRESS\] protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 nonce=(?<nonce>[A-Za-z0-9_.-]+) unique=(?<unique>[0-9]+) expected=932 elapsed_us=(?<elapsed>[0-9]+) d7_bytes=(?<bytes>[0-9]+)$')
  Assert-Condition $match.Success "Malformed or foreign PROGRESS: $Line"
  Assert-Condition ($match.Groups['nonce'].Value -ceq $ExpectedNonce) `
      "PROGRESS nonce mismatch: $Line"
  [uint64]$unique = [uint64]$match.Groups['unique'].Value
  [uint64]$elapsed = [uint64]$match.Groups['elapsed'].Value
  [uint64]$bytes = [uint64]$match.Groups['bytes'].Value
  Assert-Condition ($unique -le 932) `
      "PROGRESS unique exceeds 932: $unique"
  Assert-Condition ($elapsed -le 120000000) `
      "PROGRESS elapsed exceeds device timeout: $elapsed"
  [pscustomobject][ordered]@{
    protocol='PIXHAWK_D7_PARAM_BENCHMARK_V2'
    nonce=$match.Groups['nonce'].Value;unique=$unique;expected=932
    elapsed_us=$elapsed;d7_bytes=$bytes
  }
}

function Assert-NoStrayRequestRecord([string]$Line, [string]$Context) {
  foreach ($marker in @(
      '[START_ACK]','[START_REJECT]','[PROGRESS]','[RESULT]',
      '[COMMAND_REJECT]')) {
    if ($Line.StartsWith($marker,[StringComparison]::Ordinal)) {
      throw "Unexpected request-phase record during ${Context}: $Line"
    }
  }
}

function Assert-ExpectedParserFailure(
    [string]$CaseName, [scriptblock]$Action) {
  try {
    [void](& $Action)
  } catch {
    return [pscustomobject][ordered]@{
      case=$CaseName;result='PASS_REJECTED';message=$_.Exception.Message
    }
  }
  throw "Negative parser case was accepted: $CaseName"
}

function Complete-Evidence([string]$Mode) {
  # Restoration must never depend on the mutable source pathname. The locked
  # evidence copy remains mandatory here; source drift is recorded and turns
  # the run into FAIL after restoration rather than suppressing restoration.
  Assert-RunnerStagePinned 'before_evidence_finalization'
  if ($script:RecoveryEvidenceFailures.Count -gt 0) {
    $evidenceFailure = ('recovery_evidence_write_failures=' +
        $script:RecoveryEvidenceFailures.Count)
    if ([string]::IsNullOrWhiteSpace($script:MainFailure)) {
      $script:MainFailure = $evidenceFailure
    } else {
      $script:MainFailure += " | $evidenceFailure"
    }
    $script:Result = 'FAIL'
    $script:Status = if ($script:RestoreVerified) {
      'FAIL_R18_PRODUCTION_RESTORED_EVIDENCE_INCOMPLETE'
    } else {
      'FAIL_RECOVERY_EVIDENCE_INCOMPLETE_AND_RESTORE_NOT_VERIFIED'
    }
  }
  $runnerSourceIntegrity = Get-RunnerSourceIntegrity
  if ($runnerSourceIntegrity.result -cne 'PASS') {
    $driftFailure = "runner_source_integrity=$($runnerSourceIntegrity.failure)"
    if ([string]::IsNullOrWhiteSpace($script:MainFailure)) {
      $script:MainFailure = $driftFailure
    } else {
      $script:MainFailure += " | $driftFailure"
    }
    $script:Result = 'FAIL'
    $script:Status = 'FAIL_RUNNER_SOURCE_DRIFT_AFTER_MANDATORY_RESTORE'
  }
  $summaryPath = Join-Path $evidence 'summary.json'
  $summary = [ordered]@{
    schema_version=1;test_id='R19-HS-G1-D7-DIRECT-HIL-001'
    mode=$Mode;started_utc=$startedUtc
    finished_utc=[DateTime]::UtcNow.ToString('o')
    result=$script:Result;status=$script:Status
    main_failure=$script:MainFailure
    restore_failure=$script:RestoreFailure
    restore_attempts=@($script:RestoreAttempts)
    recovery_evidence_failures=@($script:RecoveryEvidenceFailures)
    protocol_identity=$script:ProtocolIdentity
    evidence_root=$evidence
    safety=[ordered]@{
      app_offset='0x10000';erase_allowed=$false;merged_allowed=$false
      bootloader_write_allowed=$false;partition_write_allowed=$false
      candidate_write_attempted=$script:FirmwareWriteAttempted
      firmware_may_have_changed=$script:FirmwareMayHaveChanged
      production_restore_attempted=$script:RestoreAttempted
      production_restore_verified=$script:RestoreVerified
    }
    external_actions=[ordered]@{
      device_access_attempted=$script:DeviceAccessAttempted
      process_inventory_queried=$script:ProcessInventoryQueried
      pnp_queried=$script:PnpQueried
      com_ports_enumerated=$script:ComPortsEnumerated
      com_ports_opened=$script:ComPortsOpened
      esptool_executed=$script:EspToolExecuted
      firmware_write_attempted=$script:FirmwareWriteAttempted
    }
    pins=[ordered]@{
      candidate=[ordered]@{path=$candidate.source;bytes=$candidate.bytes;sha256=$candidate.sha256}
      candidate_frozen_source=[ordered]@{path=$candidateSource.source
        bytes=$candidateSource.bytes;sha256=$candidateSource.sha256}
      rollback=[ordered]@{path=$rollback.source;bytes=$rollback.bytes;sha256=$rollback.sha256}
      esptool=[ordered]@{path=$espTool.source;bytes=$espTool.bytes;
        sha256=$espTool.sha256;version=$espTool.version}
      vehicle=$vehicle
    }
    flash_steps=@($script:FlashSteps)
    measurement_runs=@($script:MeasurementRuns)
    runner=[ordered]@{path=$PSCommandPath;bytes=$script:RunnerBytes
      sha256=$script:RunnerStartSha256;locked_for_entire_run=$true
      sealed_copy_path=$script:RunnerStagePath
      sealed_copy_sha256=$script:RunnerStageSha256
      source_integrity=$runnerSourceIntegrity}
  }
  Write-DurableJson $summaryPath $summary

  $excluded = @('artifact_manifest.json','SHA256SUMS.txt',
    'final_seal.json','final_seal.sha256')
  $rows = @(Get-ChildItem -LiteralPath $evidence -Recurse -File |
    Where-Object {$excluded -notcontains $_.Name} |
    Sort-Object FullName | ForEach-Object {
      [ordered]@{path=Get-RelativeEvidencePath $_.FullName
        bytes=$_.Length;sha256=Get-Sha $_.FullName}
    })
  $manifestPath = Join-Path $evidence 'artifact_manifest.json'
  Write-DurableJson $manifestPath ([ordered]@{
    schema_version=1;result=$script:Result
    coverage='all files present before artifact manifest, sums, and seal'
    file_count=$rows.Count;files=$rows
  })
  $sumsPath = Join-Path $evidence 'SHA256SUMS.txt'
  Write-Durable $sumsPath ((@($rows | ForEach-Object {
      "$($_.sha256) *$($_.path)"}) -join $newline) + $newline)
  $sealPath = Join-Path $evidence 'final_seal.json'
  Write-DurableJson $sealPath ([ordered]@{
    schema_version=1;test_id='R19-HS-G1-D7-DIRECT-HIL-001'
    mode=$Mode;finalized_utc=[DateTime]::UtcNow.ToString('o')
    result=$script:Result;status=$script:Status
    summary_sha256=Get-Sha $summaryPath
    artifact_manifest_sha256=Get-Sha $manifestPath
    sha256sums_sha256=Get-Sha $sumsPath
    runner_sha256=$script:RunnerStartSha256
    runner_stage_sha256=$script:RunnerStageSha256
    candidate_app_sha256=$candidate.sha256
    candidate_frozen_source_sha256=$candidateSource.sha256
    rollback_app_sha256=$rollback.sha256
    esptool_sha256=$espTool.sha256
    production_restore_attempted=$script:RestoreAttempted
    production_restore_verified=$script:RestoreVerified
    production_restore_attempt_count=$script:RestoreAttempts.Count
    recovery_evidence_failure_count=$script:RecoveryEvidenceFailures.Count
  })
  Write-Durable (Join-Path $evidence 'final_seal.sha256') `
      ("$(Get-Sha $sealPath) *final_seal.json" + $newline)
}

$evidence = Initialize-EvidenceRoot $EvidenceRoot
Lock-RunnerSource
Assert-RunnerPinned 'run_start'

if ($OfflineSelfTest.IsPresent) {
  Assert-Condition (-not $Execute.IsPresent) `
      'OfflineSelfTest and Execute are mutually exclusive.'
  try {
    $pins = Test-StaticPins
    Assert-SafeEspToolArgv 'read_mac' (New-EspToolArgv 'read_mac')
    Assert-SafeEspToolArgv 'write' `
        (New-EspToolArgv 'write' $candidate.source) $candidate.source
    Assert-SafeEspToolArgv 'verify' `
        (New-EspToolArgv 'verify' $rollback.source) $rollback.source
    $canonicalReadyLine = (
      '[READY] protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 role=vehicle ' +
      'uart=2 rx=D7 tx=D6 baud=57600 expected=932 heartbeat_count=3 ' +
      'heartbeat_age_us=500000 indexed_quiet_age_us=2500000 ' +
      'heartbeat_last_gap_us=1000000 parser_idle=1 ' +
      'command=START <nonce>')
    $canonicalReady = Convert-StrictReadyLine $canonicalReadyLine
    Assert-Condition ($canonicalReady.protocol -ceq
        'PIXHAWK_D7_PARAM_BENCHMARK_V2' -and
        $canonicalReady.heartbeat_count -eq 3 -and
        $canonicalReady.heartbeat_age_us -eq 500000 -and
        $canonicalReady.indexed_quiet_age_us -eq 2500000 -and
        $canonicalReady.heartbeat_last_gap_us -eq 1000000 -and
        $canonicalReady.parser_idle) `
        'Canonical V2 READY parser self-test failed.'
    $canonicalAck = Convert-StrictStartAckLine (
      '[START_ACK] protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 ' +
      'nonce=0123456789abcdef0123456789abcdef request_writes=1 target=1/1') `
      '0123456789abcdef0123456789abcdef'
    $canonicalProgress = Assert-ProgressProtocol (
      '[PROGRESS] protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 ' +
      'nonce=0123456789abcdef0123456789abcdef unique=500 expected=932 ' +
      'elapsed_us=4000000 d7_bytes=19000') `
      '0123456789abcdef0123456789abcdef'
    $synthetic = ('[RESULT] protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 ' +
      'nonce=0123456789abcdef0123456789abcdef ' +
      'result=PASS reason=strict_932_and_post_heartbeat ' +
      'trigger=post_list_heartbeat data_result=PASS heartbeat_result=PASS ' +
      'target_10s_data_result=PASS target_30s_data_result=PASS ' +
      'target_10s_result=PASS target_30s_result=PASS ' +
      'request_writes=1 expected=932 ' +
      'unique=932 missing=0 duplicate=0 out_of_order=0 out_of_range=0 ' +
      'wrong_source=0 count_mismatch=0 bad_payload=0 parameter_frames=932 ' +
      'stat_runtime_excluded=0 d7_bytes=35000 request_enqueue_us=100000 ' +
      'request_tx_complete_us=102500 request_tx_duration_us=2500 ' +
      'write_semantics=arduino_length_then_uart_tx_idle ' +
      'crc_scope=heartbeat_and_param_value_only ' +
      'request_to_first_us=1000 request_to_last_us=6000000 ' +
      'first_to_last_us=5999000 heartbeat_count=6 heartbeat_max_gap_us=1100000 ' +
      'post_list_heartbeat_us=7100000 ' +
      'list_complete_to_post_heartbeat_us=1100000 ' +
      'crc_errors=0 bad_lengths=0 unsupported_flags=0 noise_bytes=0')
    $parsed = Assert-StrictResult $synthetic `
        '0123456789abcdef0123456789abcdef'
    $syntheticTenSecondMiss = (
      '[RESULT] protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 ' +
      'nonce=fedcba9876543210fedcba9876543210 ' +
      'result=PASS reason=strict_932_and_post_heartbeat ' +
      'trigger=post_list_heartbeat data_result=PASS heartbeat_result=PASS ' +
      'target_10s_data_result=FAIL target_30s_data_result=PASS ' +
      'target_10s_result=FAIL target_30s_result=PASS ' +
      'request_writes=1 expected=932 unique=932 missing=0 duplicate=0 ' +
      'out_of_order=0 out_of_range=0 wrong_source=0 count_mismatch=0 ' +
      'bad_payload=0 parameter_frames=934 stat_runtime_excluded=2 ' +
      'd7_bytes=35100 request_enqueue_us=100000 ' +
      'request_tx_complete_us=102500 request_tx_duration_us=2500 ' +
      'write_semantics=arduino_length_then_uart_tx_idle ' +
      'crc_scope=heartbeat_and_param_value_only request_to_first_us=1000 ' +
      'request_to_last_us=15000000 first_to_last_us=14999000 ' +
      'heartbeat_count=15 heartbeat_max_gap_us=1100000 ' +
      'post_list_heartbeat_us=16100000 ' +
      'list_complete_to_post_heartbeat_us=1100000 crc_errors=0 ' +
      'bad_lengths=0 unsupported_flags=0 noise_bytes=0')
    $parsedTenSecondMiss = Assert-StrictResult $syntheticTenSecondMiss `
        'fedcba9876543210fedcba9876543210'
    Assert-Condition (-not $parsedTenSecondMiss.target_10s_met -and
        $parsedTenSecondMiss.target_30s_met) `
        'A strict 15-second run must remain valid while recording 10 s FAIL.'
    $negativeParserCases = [Collections.ArrayList]::new()
    [void]$negativeParserCases.Add((Assert-ExpectedParserFailure `
      'ready_v1_protocol' {
        Convert-StrictReadyLine ($canonicalReadyLine.Replace(
          'protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2',
          'protocol=PIXHAWK_D7_PARAM_BENCHMARK_V1'))
      }))
    [void]$negativeParserCases.Add((Assert-ExpectedParserFailure `
      'ready_missing_protocol' {
        Convert-StrictReadyLine ($canonicalReadyLine.Replace(
          'protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 ',''))
      }))
    [void]$negativeParserCases.Add((Assert-ExpectedParserFailure `
      'ready_wrong_order' {
        Convert-StrictReadyLine ($canonicalReadyLine.Replace(
          'indexed_quiet_age_us=2500000 heartbeat_last_gap_us=1000000',
          'heartbeat_last_gap_us=1000000 indexed_quiet_age_us=2500000'))
      }))
    [void]$negativeParserCases.Add((Assert-ExpectedParserFailure `
      'result_missing_protocol' {
        Assert-StrictResult ($synthetic.Replace(
          '[RESULT] protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 ',
          '[RESULT] ')) '0123456789abcdef0123456789abcdef'
      }))
    [void]$negativeParserCases.Add((Assert-ExpectedParserFailure `
      'stray_result_during_ready' {
        Assert-NoStrayRequestRecord $synthetic 'READY wait'
      }))
    $recoveryEvidenceFault = Invoke-BestEffortEvidenceWrite `
        'offline_injected_recovery_evidence_io_fault' {
          throw 'INJECTED_RECOVERY_EVIDENCE_IO_FAILURE'
        }
    Assert-Condition ($recoveryEvidenceFault.result -ceq 'FAIL' -and
        $recoveryEvidenceFault.failure -match
            'INJECTED_RECOVERY_EVIDENCE_IO_FAILURE') `
        'Best-effort recovery evidence fault did not remain non-throwing.'
    $recoverySimulationCounters = [pscustomobject][ordered]@{
      executor_calls=0;writer_calls=0
    }
    $restoreVerifiedBeforeSimulation = $script:RestoreVerified
    $script:RestoreVerified = $false
    try {
      $recoverySimulation = Invoke-BoundedRecoveryOrchestration `
          -MaxAttempts 3 -RetryDelayMilliseconds 0 `
          -UpdateGlobalRestoreState `
          -AttemptExecutor {
            param($attempt)
            ++$recoverySimulationCounters.executor_calls
            if ($attempt -eq 1) {
              return [pscustomobject][ordered]@{
                result='FAIL';failure='INJECTED_ATTEMPT_1_FAILURE'
                process_inventory=$null;flash_steps=@()
              }
            }
            [pscustomobject][ordered]@{
              result='PASS';failure='';process_inventory=$null;flash_steps=@()
            }
          } `
          -AttemptEvidenceWriter {
            param($record,$attempt,$suffix)
            ++$recoverySimulationCounters.writer_calls
            throw "INJECTED_ATTEMPT_${attempt}_EVIDENCE_FAILURE"
          }
      Assert-Condition ($recoverySimulation.hardware_verified -and
          $recoverySimulation.attempts.Count -eq 2 -and
          $recoverySimulation.evidence_write_failures.Count -eq 2 -and
          $recoverySimulationCounters.executor_calls -eq 2 -and
          $recoverySimulationCounters.writer_calls -eq 2 -and
          $script:RestoreVerified) `
          'Recovery simulation did not continue to attempt 2 and latch RestoreVerified despite writer faults.'
    } finally {
      $script:RestoreVerified = $restoreVerifiedBeforeSimulation
    }
    $allFailureCounters = [pscustomobject][ordered]@{
      executor_calls=0;writer_calls=0
    }
    $allFailureSimulation = Invoke-BoundedRecoveryOrchestration `
        -MaxAttempts 3 -RetryDelayMilliseconds 0 `
        -AttemptExecutor {
          param($attempt)
          ++$allFailureCounters.executor_calls
          [pscustomobject][ordered]@{
            result='FAIL';failure="INJECTED_ATTEMPT_${attempt}_FAILURE"
            process_inventory=$null;flash_steps=@()
          }
        } `
        -AttemptEvidenceWriter {
          param($record,$attempt,$suffix)
          ++$allFailureCounters.writer_calls
          throw "INJECTED_ATTEMPT_${attempt}_EVIDENCE_FAILURE"
        }
    Assert-Condition (-not $allFailureSimulation.hardware_verified -and
        $allFailureSimulation.attempts.Count -eq 3 -and
        $allFailureSimulation.evidence_write_failures.Count -eq 3 -and
        $allFailureCounters.executor_calls -eq 3 -and
        $allFailureCounters.writer_calls -eq 3) `
        'Recovery simulation did not reach bounded attempt 3 across writer faults.'
    $offlineExternalActions = [ordered]@{
      device_access_attempted=$script:DeviceAccessAttempted
      process_inventory_queried=$script:ProcessInventoryQueried
      pnp_queried=$script:PnpQueried
      com_ports_enumerated=$script:ComPortsEnumerated
      com_ports_opened=$script:ComPortsOpened
      esptool_executed=$script:EspToolExecuted
      firmware_write_attempted=$script:FirmwareWriteAttempted
    }
    foreach ($offlineFlag in $offlineExternalActions.GetEnumerator()) {
      Assert-Condition (-not [bool]$offlineFlag.Value) `
          "Offline self-test performed external action: $($offlineFlag.Key)"
    }
    Write-DurableJson (Join-Path $evidence 'offline_self_test.json') `
        ([ordered]@{schema_version=1;result='PASS';pins=$pins
          canonical_ready=$canonicalReady;canonical_ack=$canonicalAck
          canonical_progress=$canonicalProgress
          synthetic_result=$parsed
          synthetic_10s_miss_result=$parsedTenSecondMiss
          negative_parser_cases=@($negativeParserCases)
          recovery_evidence_fault_injection=[ordered]@{
            result='PASS_CONTINUED';captured_fault=$recoveryEvidenceFault
            hardware_action_simulated=$false
            fail_then_verified_simulation=$recoverySimulation
            all_three_fail_simulation=$allFailureSimulation
          }
          external_actions=$offlineExternalActions})
    $script:Result = 'PASS'
    $script:Status = 'PASS_OFFLINE_STATIC_PINS_ARGV_RESULT_SCHEMA'
  } catch {
    $script:MainFailure = $_.Exception.Message
    $script:Status = 'FAIL_OFFLINE_STATIC_PREFLIGHT'
  }
  Complete-Evidence 'OfflineSelfTest'
  $script:RunnerLock.Dispose()
  $script:RunnerLock = $null
  foreach ($lock in @($script:StageLocks)) {
    try {$lock.Dispose()} catch {}
  }
  $script:StageLocks.Clear()
  if ($script:Result -cne 'PASS') {
    throw "D7 benchmark offline self-test failed: $($script:MainFailure)"
  }
  Write-Output ("PIXHAWK D7 BENCHMARK OFFLINE PASS evidence=$evidence")
  exit 0
}

# Live device path starts below. It is unreachable in OfflineSelfTest mode.
Assert-Condition $Execute.IsPresent `
    'Live HIL requires explicit -Execute; use -OfflineSelfTest for offline checks.'

function Assert-AllPinned([string]$Checkpoint, [bool]$IncludeStage,
                          [bool]$RequireSources = $true) {
  if ($RequireSources) {
    Assert-RunnerPinned $Checkpoint
  } else {
    Assert-RunnerStagePinned $Checkpoint
  }
  if ($RequireSources) {
    [void](Assert-PinnedFile $candidate $Checkpoint)
    [void](Assert-PinnedFile $candidateSource $Checkpoint)
    [void](Assert-PinnedFile $rollback $Checkpoint)
    [void](Assert-PinnedFile $espTool $Checkpoint)
  }
  if ($IncludeStage) {
    foreach ($pin in @($candidate,$candidateSource,$rollback,$espTool)) {
      Assert-Condition (-not [string]::IsNullOrWhiteSpace(
          [string]$pin.stage_path)) `
          "$($pin.name) has no locked stage at $Checkpoint"
      $stage = Get-Item -LiteralPath $pin.stage_path -ErrorAction Stop
      Assert-Condition ([int64]$stage.Length -eq [int64]$pin.bytes) `
          "$($pin.name) staged size changed at $Checkpoint"
      Assert-Condition ((Get-Sha $stage.FullName) -ceq [string]$pin.sha256) `
          "$($pin.name) staged SHA changed at $Checkpoint"
    }
  }
}

function Copy-ToLockedStage([object]$Pin, [string]$Leaf) {
  $stageDirectory = Join-Path $evidence 'staged'
  [void][IO.Directory]::CreateDirectory($stageDirectory)
  $destination = Join-Path $stageDirectory $Leaf
  $source = [IO.FileStream]::new(
      [string]$Pin.source, [IO.FileMode]::Open, [IO.FileAccess]::Read,
      [IO.FileShare]::Read, 65536, [IO.FileOptions]::SequentialScan)
  try {
    $target = [IO.FileStream]::new(
        $destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::Read, 65536, [IO.FileOptions]::WriteThrough)
    try {
      $source.CopyTo($target, 65536)
      $target.Flush($true)
    } finally {
      $target.Dispose()
    }
  } finally {
    $source.Dispose()
  }
  Assert-Condition ((Get-Item -LiteralPath $destination).Length -eq
      [int64]$Pin.bytes) "$($Pin.name) staged size mismatch."
  Assert-Condition ((Get-Sha $destination) -ceq [string]$Pin.sha256) `
      "$($Pin.name) staged SHA mismatch."
  $Pin.stage_path = (Resolve-Path -LiteralPath $destination).Path
  $lock = [IO.FileStream]::new(
      $Pin.stage_path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
      [IO.FileShare]::Read, 4096, [IO.FileOptions]::SequentialScan)
  [void]$script:StageLocks.Add($lock)
}

function Get-PortIdentity {
  $script:DeviceAccessAttempted = $true
  $script:PnpQueried = $true
  $script:ComPortsEnumerated = $true
  $matches = @(Get-CimInstance Win32_SerialPort | Where-Object {
    [string]$_.DeviceID -ieq [string]$vehicle.port
  })
  Assert-Condition ($matches.Count -eq 1) `
      "COM3 must resolve to exactly one Win32_SerialPort row; actual=$($matches.Count)"
  $row = $matches[0]
  $properties = @(Get-PnpDeviceProperty `
      -InstanceId ([string]$row.PNPDeviceID) -ErrorAction Stop)
  $parents = @($properties | Where-Object {
    $_.KeyName -ceq 'DEVPKEY_Device_Parent'
  })
  Assert-Condition ($parents.Count -eq 1) 'COM3 parent PNP property unavailable.'
  [pscustomobject][ordered]@{
    captured_utc=[DateTime]::UtcNow.ToString('o')
    port=[string]$row.DeviceID;name=[string]$row.Name
    description=[string]$row.Description
    pnp_device_id=[string]$row.PNPDeviceID
    parent_device_id=[string]$parents[0].Data
    status=[string]$row.Status
    config_manager_error_code=[int]$row.ConfigManagerErrorCode
  }
}

function Assert-RoleIdentity([object]$Identity) {
  Assert-Condition ([string]$Identity.port -ceq 'COM3') `
      "Vehicle port identity changed: $($Identity.port)"
  Assert-Condition ([string]$Identity.pnp_device_id -ceq [string]$vehicle.pnp) `
      "Vehicle PNP identity mismatch: $($Identity.pnp_device_id)"
  Assert-Condition ([string]$Identity.parent_device_id -ceq
      [string]$vehicle.parent) `
      "Vehicle parent identity mismatch: $($Identity.parent_device_id)"
  Assert-Condition ([string]$Identity.pnp_device_id -match
      '(?i)^USB\\VID_303A&PID_1001&MI_00\\') `
      'Vehicle VID/PID identity mismatch.'
  Assert-Condition ([string]$Identity.status -ceq 'OK' -and
      [int]$Identity.config_manager_error_code -eq 0) `
      'Vehicle PNP status is not healthy.'
}

function Wait-RoleIdentity([int]$TimeoutSeconds = 25) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $lastFailure = ''
  do {
    try {
      $identity = Get-PortIdentity
      Assert-RoleIdentity $identity
      return $identity
    } catch {
      $lastFailure = $_.Exception.Message
      Start-Sleep -Milliseconds 500
    }
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Pinned Vehicle identity did not recover: $lastFailure"
}

function Get-CompetingClients {
  $script:DeviceAccessAttempted = $true
  $script:ProcessInventoryQueried = $true
  $knownNames = @(
    'missionplanner.exe','qgroundcontrol.exe','mavproxy.exe',
    'arduino-cli.exe','arduino-ide.exe','esptool.exe','python.exe',
    'pythonw.exe','py.exe','putty.exe','ttermpro.exe','coolterm.exe',
    'platformio.exe','serialstudio.exe','plink.exe')
  $all = @(Get-CimInstance Win32_Process)
  $known = @($all | Where-Object {
    $_.ProcessId -ne $PID -and
    $knownNames -contains ([string]$_.Name).ToLowerInvariant()
  } | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine)
  $explicitCom3 = @($all | Where-Object {
    $_.ProcessId -ne $PID -and
    -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
    [string]$_.CommandLine -match '(?i)(^|[^A-Z0-9_])COM3([^0-9]|$)'
  } | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine)
  [pscustomobject][ordered]@{
    captured_utc=[DateTime]::UtcNow.ToString('o')
    known_serial_clients=$known;explicit_com3_references=$explicitCom3
  }
}

function Assert-NoCompetingClients {
  $snapshot = Get-CompetingClients
  Assert-Condition (@($snapshot.known_serial_clients).Count -eq 0) `
      'Known serial client (including missionplanner.exe) is running.'
  Assert-Condition (@($snapshot.explicit_com3_references).Count -eq 0) `
      'Another process command line references COM3.'
  $snapshot
}

function Assert-RecoveryCom3Available {
  # Recovery must not be vetoed merely because a tool is running for COM6 or
  # another device. Preserve the full inventory as evidence, but block only an
  # explicit COM3 reference. Actual exclusive ownership is then decided by
  # the bounded esptool recovery attempt itself.
  try {
    $snapshot = Get-CompetingClients
  } catch {
    return [pscustomobject][ordered]@{
      inventory_result='FAIL_CONTINUE_TO_COM3_CLAIM'
      inventory_failure=$_.Exception.Message
      captured_utc=[DateTime]::UtcNow.ToString('o')
      known_serial_clients=@();explicit_com3_references=@()
    }
  }
  Assert-Condition (@($snapshot.explicit_com3_references).Count -eq 0) `
      'Another process command line explicitly references COM3.'
  [pscustomobject][ordered]@{
    inventory_result='PASS';inventory_failure=''
    captured_utc=$snapshot.captured_utc
    known_serial_clients=@($snapshot.known_serial_clients)
    explicit_com3_references=@($snapshot.explicit_com3_references)
  }
}

function New-ConfiguredSerialPort {
  $serial = New-Object System.IO.Ports.SerialPort
  $serial.PortName = 'COM3'
  $serial.BaudRate = 115200
  $serial.DataBits = 8
  $serial.Parity = [IO.Ports.Parity]::None
  $serial.StopBits = [IO.Ports.StopBits]::One
  $serial.Handshake = [IO.Ports.Handshake]::None
  $serial.DtrEnable = $false
  $serial.RtsEnable = $false
  $serial.ReadTimeout = 100
  $serial.WriteTimeout = 2000
  $serial.NewLine = "`n"
  $serial
}

function Test-ExclusiveSerialOwnership {
  [void](Assert-NoCompetingClients)
  [void](Wait-RoleIdentity)
  $serial = New-ConfiguredSerialPort
  $script:DeviceAccessAttempted = $true
  try {
    $serial.Open()
    $script:ComPortsOpened = $true
    Assert-Condition $serial.IsOpen 'COM3 exclusive ownership probe did not open.'
    [pscustomobject][ordered]@{
      result='PASS';port='COM3';dtr_enabled=$serial.DtrEnable
      rts_enabled=$serial.RtsEnable;checked_utc=[DateTime]::UtcNow.ToString('o')
    }
  } catch {
    throw "COM3 exclusive-open probe failed (port may be owned): $($_.Exception.Message)"
  } finally {
    try { if ($serial.IsOpen) { $serial.Close() } } finally {
      $serial.Dispose()
    }
  }
}

function ConvertTo-NativeArgumentString([string[]]$Tokens) {
  @($Tokens | ForEach-Object {
    $token = [string]$_
    Assert-Condition ($token.IndexOfAny([char[]]@([char]0,[char]10,
        [char]13,[char]34)) -lt 0) `
        'Native argument contains a forbidden NUL/newline/quote.'
    if ($token -match '\s') {'"' + $token + '"'} else {$token}
  }) -join ' '
}

function Invoke-RecoveryEspToolMemoryCapture([string[]]$Tokens) {
  $timeoutMilliseconds = 60000
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = [string]$espTool.stage_path
  $startInfo.Arguments = ConvertTo-NativeArgumentString $Tokens
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $started = $false
  try {
    Assert-Condition $process.Start() `
        'Recovery esptool Process.Start returned false.'
    $started = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($timeoutMilliseconds)) {
      try {$process.Kill()} catch {}
      try {[void]$process.WaitForExit(5000)} catch {}
      try {[void]$stdoutTask.Wait(5000)} catch {}
      try {[void]$stderrTask.Wait(5000)} catch {}
      return [pscustomobject][ordered]@{
        exit_code=124
        invoke_failure="timeout_${timeoutMilliseconds}ms"
        stdout_text=if ($stdoutTask.IsCompleted) {
          [string]$stdoutTask.Result
        } else {''}
        stderr_text=if ($stderrTask.IsCompleted) {
          [string]$stderrTask.Result
        } else {''}
        timed_out=$true;timeout_ms=$timeoutMilliseconds
      }
    }
    $stdoutComplete = $stdoutTask.Wait(5000)
    $stderrComplete = $stderrTask.Wait(5000)
    if (-not $stdoutComplete -or -not $stderrComplete) {
      return [pscustomobject][ordered]@{
        exit_code=125;invoke_failure='capture_drain_timeout_5000ms'
        stdout_text=if ($stdoutComplete) {[string]$stdoutTask.Result} else {''}
        stderr_text=if ($stderrComplete) {[string]$stderrTask.Result} else {''}
        timed_out=$true;timeout_ms=$timeoutMilliseconds
      }
    }
    [pscustomobject][ordered]@{
      exit_code=[int]$process.ExitCode;invoke_failure=''
      stdout_text=[string]$stdoutTask.Result
      stderr_text=[string]$stderrTask.Result
      timed_out=$false;timeout_ms=$timeoutMilliseconds
    }
  } catch {
    if ($started) {
      try {if (-not $process.HasExited) {$process.Kill()}} catch {}
    }
    [pscustomobject][ordered]@{
      exit_code=255;invoke_failure=$_.Exception.Message
      stdout_text='';stderr_text=''
      timed_out=$false;timeout_ms=$timeoutMilliseconds
    }
  } finally {
    $process.Dispose()
  }
}

function Invoke-CapturedEspTool([string]$Prefix, [string[]]$Tokens,
                                [switch]$RecoveryMode) {
  Assert-AllPinned "before_$Prefix" $true (-not $RecoveryMode.IsPresent)
  $stdoutPath = Join-Path $evidence "$Prefix.stdout.log"
  $stderrPath = Join-Path $evidence "$Prefix.stderr.log"
  $exitPath = Join-Path $evidence "$Prefix.exit.txt"
  $script:EspToolExecuted = $true
  $evidenceWriteFailures = [Collections.ArrayList]::new()
  # Every esptool invocation is process-bounded. In particular, a hung
  # candidate write/verify must return control to the outer finally so the
  # mandatory R18 restore can run. Normal mode persists the in-memory capture
  # fail-closed; recovery mode makes only that persistence best-effort.
  $memoryCapture = Invoke-RecoveryEspToolMemoryCapture $Tokens
  $exitCode = [int]$memoryCapture.exit_code
  $failure = [string]$memoryCapture.invoke_failure
  $stdoutText = [string]$memoryCapture.stdout_text
  $stderrText = [string]$memoryCapture.stderr_text
  $timedOut = [bool]$memoryCapture.timed_out
  $timeoutMs = [int]$memoryCapture.timeout_ms
  if ($RecoveryMode.IsPresent) {
    # In mandatory recovery, capture in memory first. Evidence persistence is
    # deliberately downstream and best-effort so filesystem/OneDrive faults
    # cannot suppress the R18 write, verify, or a later recovery attempt.
    foreach ($write in @(
        (Invoke-BestEffortEvidenceWrite "$Prefix.stdout" {
          Write-Durable $stdoutPath $stdoutText
        }),
        (Invoke-BestEffortEvidenceWrite "$Prefix.stderr" {
          Write-Durable $stderrPath $stderrText
        }),
        (Invoke-BestEffortEvidenceWrite "$Prefix.exit" {
          Write-Durable $exitPath ([string]$exitCode + $newline)
        }))) {
      if ($write.result -cne 'PASS') {
        [void]$evidenceWriteFailures.Add($write)
        Add-RecoveryEvidenceFailure $write
      }
    }
  } else {
    Write-Durable $stdoutPath $stdoutText
    Write-Durable $stderrPath $stderrText
    Write-Durable $exitPath ([string]$exitCode + $newline)
  }
  Assert-AllPinned "after_$Prefix" $true (-not $RecoveryMode.IsPresent)
  [pscustomobject][ordered]@{
    exit_code=$exitCode;invoke_failure=$failure
    stdout_path=$stdoutPath;stderr_path=$stderrPath;exit_path=$exitPath
    stdout_text=$stdoutText;stderr_text=$stderrText
    timed_out=$timedOut;timeout_ms=$timeoutMs
    evidence_write_failures=@($evidenceWriteFailures)
  }
}

function Invoke-EspToolVersion {
  $capture = Invoke-CapturedEspTool '00_esptool_version' @('version')
  Assert-Condition ($capture.exit_code -eq 0) `
      "esptool version exit=$($capture.exit_code)"
  Assert-Condition ((Get-Item $capture.stderr_path).Length -eq 0) `
      'esptool version wrote stderr.'
  Assert-Condition ($capture.stdout_text -match '(?m)^\s*5\.3\.1\s*$') `
      'Pinned esptool did not report exact version 5.3.1.'
}

function Invoke-FlashStep(
    [int]$Number, [string]$Label,
    [ValidateSet('read_mac','write','verify')][string]$Kind,
    [object]$Application = $null, [switch]$RecoveryMode) {
  $clients = if ($RecoveryMode.IsPresent) {
    Assert-RecoveryCom3Available
  } else {
    Assert-NoCompetingClients
  }
  $identityBefore = Wait-RoleIdentity
  $applicationPath = if ($null -eq $Application) {''} else {
    [string]$Application.stage_path
  }
  [string[]]$argv = @(New-EspToolArgv $Kind $applicationPath)
  Assert-SafeEspToolArgv $Kind $argv $applicationPath
  $prefix = '{0:D2}_{1}' -f $Number,$Label
  $evidenceWriteFailures = [Collections.ArrayList]::new()
  $argvPath = Join-Path $evidence "$prefix.argv.json"
  if ($RecoveryMode.IsPresent) {
    $write = Invoke-BestEffortEvidenceWrite "$prefix.argv" {
      Write-DurableJson $argvPath ([object[]]$argv)
    }
    if ($write.result -cne 'PASS') {
      [void]$evidenceWriteFailures.Add($write)
      Add-RecoveryEvidenceFailure $write
    }
  } else {
    Write-DurableJson $argvPath ([object[]]$argv)
  }
  if ($Kind -ceq 'write') {
    $intentPath = Join-Path $evidence "$prefix.intent.json"
    $intent = [ordered]@{
      schema_version=1;created_utc=[DateTime]::UtcNow.ToString('o')
      state='PRELAUNCH_FIRMWARE_MAY_CHANGE';port='COM3';offset='0x10000'
      application_key=[string]$Application.key
      application_sha256=[string]$Application.sha256
    }
    if ($RecoveryMode.IsPresent) {
      $write = Invoke-BestEffortEvidenceWrite "$prefix.intent" {
        Write-DurableJson $intentPath $intent
      }
      if ($write.result -cne 'PASS') {
        [void]$evidenceWriteFailures.Add($write)
        Add-RecoveryEvidenceFailure $write
      }
    } else {
      Write-DurableJson $intentPath $intent
    }
    if ([string]$Application.key -ceq 'candidate') {
      $script:FirmwareWriteAttempted = $true
      $script:FirmwareMayHaveChanged = $true
    }
  }
  $stepStarted = [DateTime]::UtcNow.ToString('o')
  $capture = Invoke-CapturedEspTool $prefix $argv `
      -RecoveryMode:$RecoveryMode.IsPresent
  $issues = [Collections.ArrayList]::new()
  if ($capture.exit_code -ne 0) {[void]$issues.Add("exit=$($capture.exit_code)")}
  if (-not [string]::IsNullOrWhiteSpace([string]$capture.invoke_failure)) {
    [void]$issues.Add("invoke=$($capture.invoke_failure)")
  }
  if (-not [string]::IsNullOrEmpty([string]$capture.stderr_text)) {
    [void]$issues.Add('stderr_not_empty')
  }
  foreach ($writeFailure in @($capture.evidence_write_failures)) {
    [void]$evidenceWriteFailures.Add($writeFailure)
  }
  $parsedMac = $null
  if ($Kind -ceq 'read_mac') {
    $matches = [regex]::Matches($capture.stdout_text,
        '(?im)^\s*MAC:\s*([0-9a-f]{2}(?::[0-9a-f]{2}){5})\s*$')
    $macs = @($matches | ForEach-Object {
      $_.Groups[1].Value.ToLowerInvariant()
    } | Sort-Object -Unique)
    if ($macs.Count -ne 1) {[void]$issues.Add("mac_count=$($macs.Count)")} else {
      $parsedMac = $macs[0]
      if ($parsedMac -cne [string]$vehicle.mac) {
        [void]$issues.Add("mac_mismatch=$parsedMac")
      }
    }
  } elseif ($Kind -ceq 'write') {
    if (-not $capture.stdout_text.Contains('Hash of data verified.')) {
      [void]$issues.Add('write_hash_marker_missing')
    }
  } elseif (-not $capture.stdout_text.Contains(
      'Verification successful (digest matched).')) {
    [void]$issues.Add('explicit_verify_marker_missing')
  }
  $identityAfter = $null
  try { $identityAfter = Wait-RoleIdentity } catch {
    [void]$issues.Add("post_identity=$($_.Exception.Message)")
  }
  $record = [pscustomobject][ordered]@{
    number=$Number;label=$Label;kind=$Kind
    started_utc=$stepStarted;finished_utc=[DateTime]::UtcNow.ToString('o')
    result=if ($issues.Count -eq 0) {'PASS'} else {'FAIL'}
    exit_code=$capture.exit_code;issues=@($issues);parsed_mac=$parsedMac
    identity_before=$identityBefore;identity_after=$identityAfter
    competing_clients=$clients
    argv_file="$prefix.argv.json"
    stdout_file="$prefix.stdout.log";stderr_file="$prefix.stderr.log"
    evidence_write_failures=@($evidenceWriteFailures)
    application=if ($null -eq $Application) {$null} else {
      [ordered]@{key=$Application.key;path=$Application.stage_path
        bytes=$Application.bytes;sha256=$Application.sha256}
    }
  }
  [void]$script:FlashSteps.Add($record)
  $recordPath = Join-Path $evidence "$prefix.record.json"
  if ($RecoveryMode.IsPresent) {
    $write = Invoke-BestEffortEvidenceWrite "$prefix.record" {
      Write-DurableJson $recordPath $record
    }
    if ($write.result -cne 'PASS') {
      [void]$evidenceWriteFailures.Add($write)
      $record.evidence_write_failures = @($evidenceWriteFailures)
      Add-RecoveryEvidenceFailure $write
    }
  } else {
    Write-DurableJson $recordPath $record
  }
  Assert-Condition ($issues.Count -eq 0) `
      "$Label failed: $(@($issues) -join '; ')"
}

function Read-CapturedLine(
    [IO.Ports.SerialPort]$Serial, [IO.FileStream]$Raw,
    [IO.StreamWriter]$TextWriter, [Text.StringBuilder]$LineBuffer,
    [DateTime]$Deadline) {
  while ([DateTime]::UtcNow -lt $Deadline) {
    try {
      $value = $Serial.ReadByte()
    } catch [TimeoutException] {
      continue
    }
    Assert-Condition ($value -ge 0 -and $value -le 255) `
        "Serial ReadByte returned invalid value: $value"
    $byte = [byte]$value
    $Raw.WriteByte($byte)
    $TextWriter.Write([char]$byte)
    if ($byte -eq 10) {
      $Raw.Flush($true)
      $TextWriter.Flush()
      $line = $LineBuffer.ToString()
      [void]$LineBuffer.Clear()
      return [pscustomobject][ordered]@{
        received_utc=[DateTime]::UtcNow.ToString('o');line=$line
      }
    }
    if ($byte -ne 13) {
      Assert-Condition ($LineBuffer.Length -lt 4096) `
          'Device emitted a line longer than 4096 characters.'
      [void]$LineBuffer.Append([char]$byte)
    }
  }
  $null
}

function Register-ProtocolLine([object]$Event, [object]$ProtocolState) {
  if (-not $Event.line.StartsWith('[BOOT]',
      [StringComparison]::Ordinal)) {
    return
  }
  if ([bool]$ProtocolState.accepted_ready -or
      [bool]$ProtocolState.start_transmitted) {
    throw ('Device reboot after protocol lock; run attribution is invalid: ' +
        $Event.line)
  }
  $expected = ('[BOOT] protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 ' +
      'diagnostic=PIXHAWK_D7_PARAM_BENCHMARK_V2 mutation=none')
  Assert-Condition ($Event.line -ceq $expected) `
      "Unexpected BOOT protocol identity: $($Event.line)"
  $ProtocolState.boot_count = [int]$ProtocolState.boot_count + 1
  Assert-Condition ([int]$ProtocolState.boot_count -le 1) `
      'Duplicate pre-ready V2 BOOT observed; reset attribution is ambiguous.'
  $ProtocolState.boot_line = $Event.line
  $ProtocolState.boot_utc = $Event.received_utc
}

function Wait-BenchmarkReady(
    [IO.Ports.SerialPort]$Serial, [IO.FileStream]$Raw,
    [IO.StreamWriter]$TextWriter, [Text.StringBuilder]$LineBuffer,
    [Collections.ArrayList]$Events, [object]$ProtocolState,
    [int]$TimeoutSeconds = 30,
    [DateTime]$AbsoluteDeadline = [DateTime]::MaxValue) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  if ($AbsoluteDeadline -lt $deadline) {$deadline = $AbsoluteDeadline}
  # On the first protocol wait, do not queue STATUS while setup() is still in
  # its one-second startup delay.  If BOOT is observed, drain from that record;
  # if BOOT was emitted before COM opened, the longer fallback covers setup.
  # This prevents BOOT and the longer READY record from sharing a full CDC TX
  # ring, where an unchecked device-side Serial.print() call could be dropped.
  $firstProtocolWait = -not [bool]$ProtocolState.accepted_ready
  $initialDrainMs = if ($firstProtocolWait) { 2000 } else { 500 }
  $nextStatus = [DateTime]::UtcNow.AddMilliseconds($initialDrainMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ([DateTime]::UtcNow -ge $nextStatus) {
      $Serial.Write("STATUS`n")
      [void]$Events.Add([pscustomobject][ordered]@{
        direction='tx';utc=[DateTime]::UtcNow.ToString('o');line='STATUS'
      })
      $nextStatus = [DateTime]::UtcNow.AddMilliseconds(750)
    }
    $slice = [DateTime]::UtcNow.AddMilliseconds(250)
    if ($slice -gt $deadline) {$slice = $deadline}
    $event = Read-CapturedLine $Serial $Raw $TextWriter $LineBuffer $slice
    if ($null -eq $event) { continue }
    [void]$Events.Add([pscustomobject][ordered]@{
      direction='rx';utc=$event.received_utc;line=$event.line
    })
    $bootCountBefore = [int]$ProtocolState.boot_count
    Register-ProtocolLine $event $ProtocolState
    if ($firstProtocolWait -and
        [int]$ProtocolState.boot_count -gt $bootCountBefore) {
      $nextStatus = [DateTime]::UtcNow.AddMilliseconds(500)
    }
    Assert-NoStrayRequestRecord $event.line 'READY wait'
    if (-not $event.line.StartsWith('[READY]',
        [StringComparison]::Ordinal)) { continue }
    $parsedReady = Convert-StrictReadyLine $event.line
    [uint64]$count = $parsedReady.heartbeat_count
    if ($count -lt 2 -or $null -eq $parsedReady.heartbeat_age_us -or
        $null -eq $parsedReady.heartbeat_last_gap_us) { continue }
    [uint64]$age = $parsedReady.heartbeat_age_us
    [uint64]$lastGap = $parsedReady.heartbeat_last_gap_us
    [uint64]$quiet = $parsedReady.indexed_quiet_age_us
    Assert-Condition ($age -le 2500000) `
        "READY heartbeat age exceeds 2500000 us: $age"
    Assert-Condition ($lastGap -le 2500000) `
        "READY heartbeat last gap exceeds 2500000 us: $lastGap"
    if ($quiet -lt 2000000 -or -not $parsedReady.parser_idle) {
      continue
    }
    $ProtocolState.accepted_ready = $true
    $ProtocolState.protocol = 'PIXHAWK_D7_PARAM_BENCHMARK_V2'
    return [pscustomobject][ordered]@{
      observed_utc=$event.received_utc;heartbeat_count=$count
      heartbeat_age_us=$age;heartbeat_last_gap_us=$lastGap
      indexed_quiet_age_us=$quiet
      parser_idle=$true;protocol=$parsedReady.protocol;line=$event.line
    }
  }
  throw ('Timed out waiting for exact READY with >=2 fresh primary ' +
      'heartbeats, >=2 s indexed quiet, and an idle parser.')
}

function Assert-PostResultLineQuiet(
    [IO.Ports.SerialPort]$Serial, [IO.FileStream]$Raw,
    [IO.StreamWriter]$TextWriter, [Text.StringBuilder]$LineBuffer,
    [Collections.ArrayList]$Events, [object]$ProtocolState,
    [int]$QuietMilliseconds = 400) {
  Assert-Condition ($QuietMilliseconds -ge 250 -and
      $QuietMilliseconds -le 500) `
      'Post-RESULT quiet drain must remain within 250..500 ms.'
  $started = [DateTime]::UtcNow
  $deadline = $started.AddMilliseconds($QuietMilliseconds)
  $lineCount = 0
  while ([DateTime]::UtcNow -lt $deadline) {
    $event = Read-CapturedLine $Serial $Raw $TextWriter $LineBuffer $deadline
    if ($null -eq $event) { continue }
    ++$lineCount
    [void]$Events.Add([pscustomobject][ordered]@{
      direction='rx';utc=$event.received_utc;line=$event.line
      phase='post_result_quiet'
    })
    Register-ProtocolLine $event $ProtocolState
    if ($event.line.StartsWith('[READY]',[StringComparison]::Ordinal)) {
      throw "Unexpected READY during post-RESULT quiet drain: $($event.line)"
    }
    Assert-NoStrayRequestRecord $event.line 'post-RESULT quiet drain'
  }
  Assert-Condition ($LineBuffer.Length -eq 0) `
      "Partial serial line remained after post-RESULT quiet drain: chars=$($LineBuffer.Length)"
  [pscustomobject][ordered]@{
    result='PASS';required_quiet_ms=$QuietMilliseconds
    observed_line_count=$lineCount;partial_buffer_chars=$LineBuffer.Length
    started_utc=$started.ToString('o')
    finished_utc=[DateTime]::UtcNow.ToString('o')
  }
}

function Get-StartRetryDelayMilliseconds([string]$Reason, [string]$Line) {
  if ($Reason -in @(
      'heartbeat_not_ready','heartbeat_stale','heartbeat_pair_not_ready')) {
    return 1200
  }
  if ($Reason -ceq 'indexed_stream_not_quiet') {
    $match = [regex]::Match($Line,'(?:^| )age_us=(?<age>[0-9]+)(?: |$)')
    if ($match.Success) {
      [uint64]$age = [uint64]$match.Groups['age'].Value
      if ($age -lt 2000000) {
        return [int][math]::Min(2000,[math]::Max(100,
            [math]::Ceiling((2000000 - [double]$age) / 1000.0) + 25))
      }
    }
    return 100
  }
  100
}

function Invoke-ThreeRunMeasurement {
  $rawPath = Join-Path $evidence 'serial.raw.bin'
  $textPath = Join-Path $evidence 'serial.text.log'
  $eventsPath = Join-Path $evidence 'serial.events.json'
  $events = [Collections.ArrayList]::new()
  $lineBuffer = [Text.StringBuilder]::new()
  $protocolState = [pscustomobject][ordered]@{
    protocol='';accepted_ready=$false;start_transmitted=$false
    boot_count=0;boot_line=$null;boot_utc=$null
  }
  $serial = New-ConfiguredSerialPort
  $raw = $null
  $textStream = $null
  $textWriter = $null
  $nonces = [Collections.Generic.HashSet[string]]::new(
      [StringComparer]::Ordinal)
  try {
    $raw = [IO.FileStream]::new(
        $rawPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,
        [IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
    $textStream = [IO.FileStream]::new(
        $textPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,
        [IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
    $textWriter = [IO.StreamWriter]::new($textStream,$utf8,4096,$true)
    # candidate_verify already performed the final process/identity gate.
    # BOOT is optional because it may have been emitted before COM opens;
    # every actionable machine record carries the mandatory V2 identity.
    $script:DeviceAccessAttempted = $true
    $serial.Open()
    $script:ComPortsOpened = $true
    Assert-Condition $serial.IsOpen 'COM3 did not open for measurement.'
    for ($runNumber = 1; $runNumber -le 3; ++$runNumber) {
      $nonce = [Guid]::NewGuid().ToString('N')
      Assert-Condition ($nonces.Add($nonce)) 'Generated duplicate run nonce.'
      $command = "START $nonce"
      $strictResult = $null
      $ready = $null
      $hostStarted = [DateTime]::MinValue
      $ackCount = 0
      $resultCount = 0
      $startAttempt = 0
      $startRetryDeadline = [DateTime]::MaxValue
      $startRejects = [Collections.ArrayList]::new()
      $postResultQuiet = $null
      while ($null -eq $strictResult -and $startAttempt -lt 3 -and
          ($startAttempt -eq 0 -or
           [DateTime]::UtcNow -lt $startRetryDeadline)) {
        if ($startAttempt -eq 0) {
          $ready = Wait-BenchmarkReady $serial $raw $textWriter `
              $lineBuffer $events $protocolState
        } else {
          $ready = Wait-BenchmarkReady $serial $raw $textWriter `
              $lineBuffer $events $protocolState `
              -AbsoluteDeadline $startRetryDeadline
        }
        ++$startAttempt
        $hostStarted = [DateTime]::UtcNow
        if ($startAttempt -eq 1) {
          $startRetryDeadline = $hostStarted.AddSeconds(15)
        }
        Assert-Condition ([bool]$protocolState.accepted_ready -and
            [string]$protocolState.protocol -ceq
                'PIXHAWK_D7_PARAM_BENCHMARK_V2') `
            'START transmission requires an accepted V2 READY.'
        $protocolState.start_transmitted = $true
        $serial.Write($command + "`n")
        [void]$events.Add([pscustomobject][ordered]@{
          direction='tx';utc=$hostStarted.ToString('o');line=$command
          run_number=$runNumber;start_attempt=$startAttempt;nonce=$nonce
        })
        $deadline = $startRetryDeadline
        $retryableReject = $null
        $ackCount = 0
        $resultCount = 0
        while ([DateTime]::UtcNow -lt $deadline -and
            $null -eq $strictResult -and $null -eq $retryableReject) {
          $event = Read-CapturedLine $serial $raw $textWriter `
              $lineBuffer $deadline
          if ($null -eq $event) { continue }
          [void]$events.Add([pscustomobject][ordered]@{
            direction='rx';utc=$event.received_utc;line=$event.line
          })
          Register-ProtocolLine $event $protocolState
          if ($event.line.StartsWith('[READY]',
              [StringComparison]::Ordinal)) {
            throw "Unexpected READY during active run ${runNumber}: $($event.line)"
          }
          if ($event.line.StartsWith('[COMMAND_REJECT]',
              [StringComparison]::Ordinal)) {
            throw "Device command rejection in run ${runNumber}: $($event.line)"
          }
          if ($event.line.StartsWith('[START_REJECT]',
              [StringComparison]::Ordinal)) {
            Assert-Condition ($ackCount -eq 0) `
                'START_REJECT arrived after START_ACK; request state is ambiguous.'
            $reject = [regex]::Match($event.line,
              '^\[START_REJECT\] reason=(?<reason>heartbeat_not_ready|heartbeat_stale|heartbeat_pair_not_ready|indexed_stream_not_quiet|parser_not_idle|uart_rx_pending|uart_backpressure)(?: .*)?$')
            Assert-Condition $reject.Success `
                "Non-retryable START_REJECT in run ${runNumber}: $($event.line)"
            $retryableReject = $reject.Groups['reason'].Value
            [void]$startRejects.Add([pscustomobject][ordered]@{
              attempt=$startAttempt;reason=$retryableReject
              received_utc=$event.received_utc;line=$event.line
            })
            continue
          }
          if ($event.line.StartsWith('[START_ACK]',
              [StringComparison]::Ordinal)) {
            $ack = Convert-StrictStartAckLine $event.line $nonce
            ++$ackCount
            Assert-Condition ($ackCount -eq 1) 'Duplicate START_ACK received.'
            $deadline = $hostStarted.AddSeconds(125)
          }
          if ($event.line.StartsWith('[PROGRESS]',
              [StringComparison]::Ordinal)) {
            [void](Assert-ProgressProtocol $event.line $nonce)
          }
          if ($event.line.StartsWith('[RESULT]',
              [StringComparison]::Ordinal)) {
            ++$resultCount
            Assert-Condition ($resultCount -eq 1) 'Duplicate RESULT received.'
            Assert-Condition ($ackCount -eq 1) `
                'RESULT arrived without exactly one nonce-bound START_ACK.'
            $strictResult = Assert-StrictResult $event.line $nonce
          }
        }
        if ($null -eq $strictResult -and $null -eq $retryableReject) {
          throw "Host timeout waiting for RESULT in run $runNumber"
        }
        if ($null -ne $strictResult) {
          $postResultQuiet = Assert-PostResultLineQuiet `
              $serial $raw $textWriter $lineBuffer $events $protocolState 400
        }
        if ($null -ne $retryableReject) {
          $delayMs = Get-StartRetryDelayMilliseconds `
              $retryableReject $event.line
          $remainingMs = ($startRetryDeadline - [DateTime]::UtcNow).TotalMilliseconds
          if ($remainingMs -gt 0) {
            Start-Sleep -Milliseconds ([int][math]::Min($delayMs,$remainingMs))
          }
        }
      }
      Assert-Condition ($null -ne $strictResult) `
          ("Run {0} exhausted bounded pre-request START retries " +
           "(max=3 window_s=15)." -f $runNumber)
      $hostFinished = [DateTime]::UtcNow
      $record = [pscustomobject][ordered]@{
        run_number=$runNumber;nonce=$nonce;result='PASS'
        host_started_utc=$hostStarted.ToString('o')
        host_finished_utc=$hostFinished.ToString('o')
        host_elapsed_ms=[math]::Round(
          ($hostFinished-$hostStarted).TotalMilliseconds,3)
        ready=$ready;start_attempt_count=$startAttempt
        start_rejects=@($startRejects)
        start_ack_count=$ackCount;result_count=$resultCount
        post_result_quiet=$postResultQuiet
        device_result=$strictResult
      }
      [void]$script:MeasurementRuns.Add($record)
    }
    Assert-Condition ($script:MeasurementRuns.Count -eq 3) `
        'Measurement did not produce exactly three strict run records.'
    Assert-Condition ([int]$protocolState.boot_count -le 1 -and
        [bool]$protocolState.accepted_ready -and
        [bool]$protocolState.start_transmitted -and
        [string]$protocolState.protocol -ceq
            'PIXHAWK_D7_PARAM_BENCHMARK_V2') `
        'Measurement protocol identity/optional pre-ready BOOT state is invalid.'
    $script:ProtocolIdentity = [pscustomobject][ordered]@{
      result='PASS';protocol=[string]$protocolState.protocol
      accepted_ready=[bool]$protocolState.accepted_ready
      start_transmitted=[bool]$protocolState.start_transmitted
      boot_optional_before_ready=$true
      boot_count=[int]$protocolState.boot_count
      boot_line=[string]$protocolState.boot_line
      boot_utc=[string]$protocolState.boot_utc
    }
  } finally {
    if ($null -eq $script:ProtocolIdentity) {
      $script:ProtocolIdentity = [pscustomobject][ordered]@{
        result='FAIL';protocol=[string]$protocolState.protocol
        accepted_ready=[bool]$protocolState.accepted_ready
        start_transmitted=[bool]$protocolState.start_transmitted
        boot_optional_before_ready=$true
        boot_count=[int]$protocolState.boot_count
        boot_line=$protocolState.boot_line;boot_utc=$protocolState.boot_utc
      }
    }
    try { if ($null -ne $raw) {$raw.Flush($true)} } catch {}
    try { if ($null -ne $textWriter) {$textWriter.Flush()} } catch {}
    try { if ($serial.IsOpen) {$serial.Close()} } catch {}
    try {$serial.Dispose()} catch {}
    try {if ($null -ne $textWriter) {$textWriter.Dispose()}} catch {}
    try {if ($null -ne $textStream) {$textStream.Dispose()}} catch {}
    try {if ($null -ne $raw) {$raw.Dispose()}} catch {}
    if (-not (Test-Path -LiteralPath $rawPath)) { Write-Durable $rawPath '' }
    if (-not (Test-Path -LiteralPath $textPath)) { Write-Durable $textPath '' }
    Write-DurableJson $eventsPath ([ordered]@{
      schema_version=1;event_count=$events.Count;events=@($events)
    })
    Write-DurableJson (Join-Path $evidence 'measurement_runs.json') `
        ([ordered]@{schema_version=1;required_runs=3
          completed_runs=$script:MeasurementRuns.Count
          protocol_identity=$script:ProtocolIdentity
          runs=@($script:MeasurementRuns)})
  }
}

function Invoke-ProductionRestore {
  $script:RestoreAttempted = $true
  Assert-RunnerStagePinned 'production_restore_entry'
  # Recovery deliberately depends only on the already-hashed, deny-write
  # staged copies. Drift in an original input must not strand the diagnostic
  # application on hardware after the candidate write has started.
  Assert-AllPinned 'before_production_restore' $true $false
  $recoveryState = Invoke-BoundedRecoveryOrchestration `
      -MaxAttempts 3 -RetryDelayMilliseconds 1000 `
      -UpdateGlobalRestoreState `
      -AttemptExecutor {
        param($attempt)
        $firstStep = $script:FlashSteps.Count
        $recoveryInventory = $null
        try {
          # Inventory is best-effort if CIM itself fails, but an observed
          # explicit COM3 reference is still a hard gate. PnP identity and the
          # nonce-independent efuse read-MAC step remain mandatory.
          $recoveryInventory = Assert-RecoveryCom3Available
          [void](Wait-RoleIdentity)
          $baseNumber = 90 + (($attempt - 1) * 10)
          Invoke-FlashStep $baseNumber "restore_a${attempt}_read_mac" `
              'read_mac' -RecoveryMode
          Invoke-FlashStep ($baseNumber + 1) "restore_a${attempt}_r18_write" `
              'write' $rollback -RecoveryMode
          Invoke-FlashStep ($baseNumber + 2) "restore_a${attempt}_r18_verify" `
              'verify' $rollback -RecoveryMode
          Assert-AllPinned "after_production_restore_attempt_$attempt" `
              $true $false
          [pscustomobject][ordered]@{
            result='PASS';failure='';process_inventory=$recoveryInventory
            flash_steps=@($script:FlashSteps | Select-Object -Skip $firstStep)
          }
        } catch {
          [pscustomobject][ordered]@{
            result='FAIL';failure=$_.Exception.Message
            process_inventory=$recoveryInventory
            flash_steps=@($script:FlashSteps | Select-Object -Skip $firstStep)
          }
        }
      } `
      -AttemptEvidenceWriter {
        param($record,$attempt,$suffix)
        Write-DurableJson (Join-Path $evidence `
            ('restore_attempt_{0:D2}_{1}.json' -f $attempt,$suffix)) $record
      }
  foreach ($attemptRecord in @($recoveryState.attempts)) {
    [void]$script:RestoreAttempts.Add($attemptRecord)
  }
  foreach ($writeFailure in @($recoveryState.evidence_write_failures)) {
    Add-RecoveryEvidenceFailure $writeFailure
  }
  if ($recoveryState.hardware_verified) { return }
  throw ('R18 production restore failed after three bounded attempts: ' +
      (@($recoveryState.executor_failures) -join ' | '))
}

try {
  [void](Test-StaticPins)
  Copy-ToLockedStage $candidate 'candidate.application.bin'
  Copy-ToLockedStage $candidateSource 'candidate.frozen_source.ino'
  Copy-ToLockedStage $rollback 'rollback.r18.vehicle.application.bin'
  Copy-ToLockedStage $espTool 'esptool-5.3.1.exe'
  Assert-AllPinned 'after_staging' $true
  Invoke-EspToolVersion
  $clients = Assert-NoCompetingClients
  $identity = Wait-RoleIdentity
  $ownership = Test-ExclusiveSerialOwnership
  Write-DurableJson (Join-Path $evidence 'live_preflight.json') `
      ([ordered]@{schema_version=1;result='PASS';clients=$clients
        identity=$identity;exclusive_open=$ownership})
  Invoke-FlashStep 1 'candidate_read_mac' 'read_mac'
  Invoke-FlashStep 2 'baseline_r18_verify' 'verify' $rollback
  Invoke-FlashStep 3 'candidate_write' 'write' $candidate
  Invoke-FlashStep 4 'candidate_verify' 'verify' $candidate
  Invoke-ThreeRunMeasurement
  $script:Status = 'MEASUREMENT_PASS_PENDING_MANDATORY_RESTORE'
} catch {
  $script:MainFailure = $_.Exception.Message
  $script:Status = 'MEASUREMENT_OR_PREFLIGHT_FAIL_PENDING_RESTORE_DECISION'
} finally {
  try {
    if ($script:FirmwareMayHaveChanged) {
      try {
        Invoke-ProductionRestore
      } catch {
        $script:RestoreFailure = $_.Exception.Message
        $script:RestoreVerified = $false
      }
    }
    if (-not $script:FirmwareMayHaveChanged) {
      $script:Result = 'FAIL'
      $script:Status = 'FAIL_STOP_BEFORE_CANDIDATE_WRITE_NO_RESTORE_REQUIRED'
    } elseif (-not $script:RestoreVerified) {
      $script:Result = 'FAIL'
      $script:Status = 'FAIL_PRODUCTION_RESTORE_NOT_VERIFIED'
    } elseif (-not [string]::IsNullOrWhiteSpace($script:MainFailure)) {
      $script:Result = 'FAIL'
      $script:Status = 'FAIL_MEASUREMENT_R18_PRODUCTION_RESTORED_VERIFIED'
    } elseif ($script:MeasurementRuns.Count -ne 3) {
      $script:Result = 'FAIL'
      $script:Status = 'FAIL_NOT_EXACTLY_THREE_RUNS_R18_PRODUCTION_RESTORED'
    } else {
      $script:Result = 'PASS'
      $script:Status = 'PASS_THREE_STRICT_RUNS_R18_PRODUCTION_RESTORED_VERIFIED'
    }
    Complete-Evidence 'Execute'
  } finally {
    foreach ($lock in @($script:StageLocks)) {
      try {$lock.Dispose()} catch {}
    }
    $script:StageLocks.Clear()
    if ($null -ne $script:RunnerLock) {
      try {$script:RunnerLock.Dispose()} catch {}
      $script:RunnerLock = $null
    }
  }
}

if ($script:Result -cne 'PASS') {
  throw (("PIXHAWK D7 BENCHMARK HIL STOP status={0} main={1} restore={2} " +
      "evidence={3}") -f $script:Status,$script:MainFailure,
      $script:RestoreFailure,$evidence)
}
Write-Output ("PIXHAWK D7 BENCHMARK HIL PASS runs=3 restored=true " +
    "evidence=$evidence")
exit 0
