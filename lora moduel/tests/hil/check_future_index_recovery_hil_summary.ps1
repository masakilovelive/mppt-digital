[CmdletBinding()]
param(
  [string]$SummaryPath = '',
  [string]$OutputDirectory = '',
  [switch]$SelfTest,
  [ValidateSet('NONE','POSITIVE','NEGATIVE')]
  [string]$FixtureMode = 'NONE'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testId = 'HIL-FUTURE-INDEX-RECOVERY-SUMMARY-CHECKER-001'
$faultMacro = 'VC_LORA_HIL_DROP_NATIVE_PARAM_INDEX_930'
$expectedFixtureHex = 'FD02000063FFBE1500000101D507'
$expectedFixtureSha256 =
    'FC3A47A83D35D44E96E044A216FDBF082805F9FACCDD5E4B9252E0C7026D4A75'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$repo = [System.IO.Path]::GetFullPath($repo)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $OutputDirectory = Join-Path $repo `
      "runs\validation\$testId\$stamp"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory -PathType Container) {
  $existingEvidence = @(Get-ChildItem -LiteralPath $OutputDirectory -Force)
  if ($existingEvidence.Count -ne 0) {
    throw "Evidence directory is not empty; refusing mixed evidence: $OutputDirectory"
  }
}
[void][System.IO.Directory]::CreateDirectory($OutputDirectory)

function Write-JsonDurable {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  $json = $Value | ConvertTo-Json -Depth 50
  $bytes = $utf8NoBom.GetBytes($json + "`n")
  $stream = New-Object System.IO.FileStream(
      $Path, [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read,
      4096, [System.IO.FileOptions]::WriteThrough)
  try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
}

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-PropertyValue {
  param($Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object) {
    return [pscustomobject]@{found=$false;value=$null}
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return [pscustomobject]@{found=$false;value=$null}
  }
  return [pscustomobject]@{found=$true;value=$property.Value}
}

function Get-PathValue {
  param($Object, [Parameter(Mandatory = $true)][string[]]$Path)
  $current = $Object
  foreach ($part in $Path) {
    $reading = Get-PropertyValue -Object $current -Name $part
    if (-not $reading.found) {
      return [pscustomobject]@{found=$false;value=$null;missing=$part}
    }
    $current = $reading.value
  }
  return [pscustomobject]@{found=$true;value=$current;missing=$null}
}

function Test-BooleanExact {
  param($Value, [bool]$Expected)
  return ($Value -is [bool] -and [bool]$Value -eq $Expected)
}

function Test-IntegerExact {
  param($Value, [long]$Expected)
  if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) {
    return $false
  }
  try {
    [decimal]$numeric = [decimal]$Value
    return ($numeric -eq [decimal]$Expected -and
        [decimal]::Truncate($numeric) -eq $numeric)
  } catch { return $false }
}

function Test-NumberAtMost {
  param($Value, [double]$Maximum, [double]$Minimum = 0.0)
  if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) {
    return $false
  }
  try {
    [double]$numeric = [double]$Value
    return (-not [double]::IsNaN($numeric) -and
        -not [double]::IsInfinity($numeric) -and
        $numeric -ge $Minimum -and $numeric -le $Maximum)
  } catch { return $false }
}

function Test-IntegerAtLeast {
  param($Value, [long]$Minimum)
  if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) {
    return $false
  }
  try {
    [decimal]$numeric = [decimal]$Value
    return ([decimal]::Truncate($numeric) -eq $numeric -and
        $numeric -ge [decimal]$Minimum)
  } catch { return $false }
}

function Test-ExactPropertySet {
  param($Object, [Parameter(Mandatory = $true)][string[]]$Expected)
  if ($null -eq $Object) { return $false }
  [string[]]$actual = @($Object.PSObject.Properties.Name | Sort-Object)
  [string[]]$wanted = @($Expected | Sort-Object)
  return (@(Compare-Object -ReferenceObject $wanted -DifferenceObject $actual).Count -eq 0)
}

function Add-ValidationCheck {
  param(
    [Parameter(Mandatory = $true)]$List,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Passed,
    [Parameter(Mandatory = $true)][string]$Detail,
    $Expected = $null,
    $Actual = $null
  )
  $List.Add([pscustomobject][ordered]@{
    name=$Name;passed=$Passed;detail=$Detail;expected=$Expected;actual=$Actual
  })
}

function Get-NamedAssessmentCheck {
  param($Assessment, [Parameter(Mandatory = $true)][string]$Name)
  $checksReading = Get-PropertyValue -Object $Assessment -Name 'checks'
  if (-not $checksReading.found) {
    return [pscustomobject]@{found=$false;value=$null;count=0}
  }
  $matches = @($checksReading.value | Where-Object {
      $nameReading = Get-PropertyValue -Object $_ -Name 'name'
      $nameReading.found -and [string]$nameReading.value -ceq $Name
    })
  return [pscustomobject]@{
    found=($matches.Count -eq 1)
    value=if($matches.Count -eq 1){$matches[0]}else{$null}
    count=$matches.Count
  }
}

function Test-NamedScalarCheck {
  param(
    $Assessment,
    [Parameter(Mandatory = $true)][string]$Name,
    $Expected,
    [switch]$String
  )
  $match = Get-NamedAssessmentCheck -Assessment $Assessment -Name $Name
  if (-not $match.found) { return $false }
  $valid = Get-PropertyValue $match.value 'valid'
  $expectedReading = Get-PropertyValue $match.value 'expected'
  $actualReading = Get-PropertyValue $match.value 'actual'
  if (-not (Test-BooleanExact $valid.value $true) -or
      -not $expectedReading.found -or -not $actualReading.found) {
    return $false
  }
  if ($String.IsPresent) {
    return ($expectedReading.value -is [string] -and
        $actualReading.value -is [string] -and
        [string]$expectedReading.value -ceq [string]$Expected -and
        [string]$actualReading.value -ceq [string]$Expected)
  }
  return (Test-IntegerExact $expectedReading.value ([long]$Expected)) -and
      (Test-IntegerExact $actualReading.value ([long]$Expected))
}

function Test-NamedAbsoluteZeroCheck {
  param(
    $Assessment,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $match = Get-NamedAssessmentCheck -Assessment $Assessment -Name $Name
  if (-not $match.found) { return $false }
  $valid = Get-PropertyValue $match.value 'valid'
  $expectedReading = Get-PropertyValue $match.value 'expected'
  $actualReading = Get-PropertyValue $match.value 'actual'
  if (-not (Test-BooleanExact $valid.value $true) -or
      -not $expectedReading.found -or
      -not (Test-IntegerExact $expectedReading.value 0) -or
      -not $actualReading.found) {
    return $false
  }
  $rule = Get-PropertyValue $match.value 'rule'
  if (-not $rule.found -or
      [string]$rule.value -cne 'exact_VCSTAT3_baseline_post_and_delta_zero' -or
      -not (Test-ExactPropertySet $actualReading.value @('before','after','delta'))) {
    return $false
  }
  foreach ($field in @('before','after','delta')) {
    $reading = Get-PropertyValue $actualReading.value $field
    if (-not $reading.found -or -not (Test-IntegerExact $reading.value 0)) {
      return $false
    }
  }
  return $true
}

function Get-SnapshotUInt64 {
  param($Snapshot, [Parameter(Mandatory = $true)][string]$Key)
  $status = Get-PropertyValue $Snapshot 'status'
  $responses = Get-PropertyValue $Snapshot 'responses'
  if (-not $status.found -or [string]$status.value -cne 'COMPLETE' -or
      -not $responses.found) {
    return [pscustomobject]@{found=$false;value=[uint64]0;count=0}
  }
  $values = New-Object 'System.Collections.Generic.List[uint64]'
  foreach ($response in @($responses.value)) {
    $correlation = Get-PropertyValue $response 'valid_correlation'
    $fields = Get-PropertyValue $response 'fields'
    if (-not (Test-BooleanExact $correlation.value $true) -or
        -not $fields.found) { continue }
    $field = Get-PropertyValue $fields.value $Key
    if (-not $field.found -or $field.value -notmatch '^\d+$') { continue }
    [uint64]$parsed = 0
    if ([uint64]::TryParse([string]$field.value, [ref]$parsed)) {
      $values.Add($parsed)
    }
  }
  return [pscustomobject]@{
    found=($values.Count -eq 1)
    value=if($values.Count -eq 1){$values[0]}else{[uint64]0}
    count=$values.Count
  }
}

function Test-SnapshotDeltaExact {
  param($Before, $After, [string]$Key, [uint64]$Expected)
  $beforeValue = Get-SnapshotUInt64 -Snapshot $Before -Key $Key
  $afterValue = Get-SnapshotUInt64 -Snapshot $After -Key $Key
  return ($beforeValue.found -and $afterValue.found -and
      [uint64]$afterValue.value -ge [uint64]$beforeValue.value -and
      ([uint64]$afterValue.value - [uint64]$beforeValue.value) -eq $Expected)
}

function Get-VCStat3UInt64 {
  param($Snapshot, [Parameter(Mandatory = $true)][string]$Key)
  $status = Get-PropertyValue $Snapshot 'status'
  $responses = Get-PropertyValue $Snapshot 'responses'
  if (-not $status.found -or [string]$status.value -cne 'COMPLETE' -or
      -not $responses.found) {
    return [pscustomobject]@{found=$false;value=[uint64]0;count=0}
  }
  $values = New-Object 'System.Collections.Generic.List[uint64]'
  foreach ($response in @($responses.value)) {
    $tag = Get-PropertyValue $response 'tag'
    $correlation = Get-PropertyValue $response 'valid_correlation'
    $fields = Get-PropertyValue $response 'fields'
    if (-not $tag.found -or [string]$tag.value -cne 'VCSTAT3' -or
        -not (Test-BooleanExact $correlation.value $true) -or
        -not $fields.found) { continue }
    $field = Get-PropertyValue $fields.value $Key
    if (-not $field.found -or $field.value -notmatch '^\d+$') { continue }
    [uint64]$parsed = 0
    if ([uint64]::TryParse([string]$field.value, [ref]$parsed)) {
      $values.Add($parsed)
    }
  }
  return [pscustomobject]@{
    found=($values.Count -eq 1)
    value=if($values.Count -eq 1){$values[0]}else{[uint64]0}
    count=$values.Count
  }
}

function Get-VCStat3String {
  param($Snapshot, [Parameter(Mandatory = $true)][string]$Key)
  $status = Get-PropertyValue $Snapshot 'status'
  $responses = Get-PropertyValue $Snapshot 'responses'
  if (-not $status.found -or [string]$status.value -cne 'COMPLETE' -or
      -not $responses.found) {
    return [pscustomobject]@{found=$false;value=$null;count=0}
  }
  $values = New-Object 'System.Collections.Generic.List[string]'
  foreach ($response in @($responses.value)) {
    $tag = Get-PropertyValue $response 'tag'
    $correlation = Get-PropertyValue $response 'valid_correlation'
    $fields = Get-PropertyValue $response 'fields'
    if (-not $tag.found -or [string]$tag.value -cne 'VCSTAT3' -or
        -not (Test-BooleanExact $correlation.value $true) -or
        -not $fields.found) { continue }
    $field = Get-PropertyValue $fields.value $Key
    if ($field.found -and $field.value -is [string]) {
      $values.Add([string]$field.value)
    }
  }
  return [pscustomobject]@{
    found=($values.Count -eq 1)
    value=if($values.Count -eq 1){$values[0]}else{$null}
    count=$values.Count
  }
}

function Get-VCStat3Delta {
  param($Before, $After, [Parameter(Mandatory = $true)][string]$Key)
  $beforeValue = Get-VCStat3UInt64 -Snapshot $Before -Key $Key
  $afterValue = Get-VCStat3UInt64 -Snapshot $After -Key $Key
  [bool]$valid = ($beforeValue.found -and $afterValue.found -and
      [uint64]$afterValue.value -ge [uint64]$beforeValue.value)
  return [pscustomobject][ordered]@{
    key=$Key;found=$valid;monotonic=$valid
    before=if($beforeValue.found){[uint64]$beforeValue.value}else{$null}
    after=if($afterValue.found){[uint64]$afterValue.value}else{$null}
    delta=if($valid){
      [uint64]$afterValue.value - [uint64]$beforeValue.value
    }else{$null}
  }
}

function Test-RecoveryDeltaExact {
  param($Assessment, [string]$Key, [uint64]$Expected)
  $reading = Get-PathValue $Assessment @('recovery_evidence','deltas',$Key)
  if (-not $reading.found) { return $false }
  $found = Get-PropertyValue $reading.value 'found'
  $monotonic = Get-PropertyValue $reading.value 'monotonic'
  $keyReading = Get-PropertyValue $reading.value 'key'
  $before = Get-PropertyValue $reading.value 'before'
  $after = Get-PropertyValue $reading.value 'after'
  $delta = Get-PropertyValue $reading.value 'delta'
  if (-not (Test-BooleanExact $found.value $true) -or
      -not (Test-BooleanExact $monotonic.value $true) -or
      -not (Test-IntegerExact $delta.value ([long]$Expected)) -or
      -not $keyReading.found -or [string]$keyReading.value -cne $Key -or
      -not $before.found -or -not $after.found) { return $false }
  try {
    [decimal]$beforeNumber = [decimal]$before.value
    [decimal]$afterNumber = [decimal]$after.value
    return ($afterNumber -ge $beforeNumber -and
        ($afterNumber - $beforeNumber) -eq [decimal]$Expected)
  } catch { return $false }
}

function Test-RecoveryPostExact {
  param($Assessment, [string]$Key, [uint64]$Expected)
  $reading = Get-PathValue $Assessment @('recovery_evidence','post',$Key)
  if (-not $reading.found) { return $false }
  $found = Get-PropertyValue $reading.value 'found'
  $value = Get-PropertyValue $reading.value 'value'
  return (Test-BooleanExact $found.value $true) -and
      (Test-IntegerExact $value.value ([long]$Expected))
}

function Test-DirectedFutureSummary {
  param([Parameter(Mandatory = $true)]$Summary)
  $result = New-Object 'System.Collections.Generic.List[object]'

  $schema = Get-PropertyValue $Summary 'schema_version'
  Add-ValidationCheck $result 'summary_schema_v1' `
      (Test-IntegerExact $schema.value 1) 'summary schema must be v1' 1 $schema.value
  $id = Get-PropertyValue $Summary 'test_id'
  Add-ValidationCheck $result 'official_test_id' `
      ($id.found -and [string]$id.value -ceq 'HIL-DUAL-DIAG-PARAM-LIST-001') `
      'only the official dual-diagnostic parameter-list summary is accepted' `
      'HIL-DUAL-DIAG-PARAM-LIST-001' $id.value
  $status = Get-PropertyValue $Summary 'status'
  Add-ValidationCheck $result 'summary_status_pass' `
      ($status.found -and [string]$status.value -ceq 'PASS') `
      'run status must be exact PASS' 'PASS' $status.value
  $errors = Get-PropertyValue $Summary 'errors'
  Add-ValidationCheck $result 'summary_errors_empty' `
      ($errors.found -and @($errors.value).Count -eq 0) `
      'PASS run must contain no errors' 0 $(if($errors.found){@($errors.value).Count}else{$null})

  $interventionReading = Get-PropertyValue $Summary 'diagnostic_fault_intervention'
  $intervention = $interventionReading.value
  Add-ValidationCheck $result 'intervention_exact_schema' `
      ($interventionReading.found -and (Test-ExactPropertySet $intervention `
        @('mode','index','macro','requested','one_shot',
          'expected_future_index','expected_missing_tail',
          'runtime_command_used','verified_exact'))) `
      'opt-in intervention must expose exactly nine bound fields'
  foreach ($stringSpec in @(
      @('intervention_mode','mode','FUTURE_INDEX_RECOVERY'),
      @('intervention_macro','macro',$faultMacro))) {
    $reading = Get-PropertyValue $intervention ([string]$stringSpec[1])
    Add-ValidationCheck $result ([string]$stringSpec[0]) `
        ($reading.found -and $reading.value -is [string] -and
          [string]$reading.value -ceq [string]$stringSpec[2]) `
        'directed intervention identity must be exact' $stringSpec[2] $reading.value
  }
  $interventionIndex = Get-PropertyValue $intervention 'index'
  Add-ValidationCheck $result 'intervention_index_930' `
      (Test-IntegerExact $interventionIndex.value 930) `
      'only compile-time drop index 930 is accepted' 930 $interventionIndex.value
  foreach ($booleanName in @('requested','verified_exact')) {
    $reading = Get-PropertyValue $intervention $booleanName
    Add-ValidationCheck $result ('intervention_' + $booleanName) `
        (Test-BooleanExact $reading.value $true) `
        "$booleanName must be exact true" $true $reading.value
  }
  foreach ($interventionInteger in @(
      @('expected_future_index',931),@('expected_missing_tail',2))) {
    $reading = Get-PropertyValue $intervention `
        ([string]$interventionInteger[0])
    Add-ValidationCheck $result `
        ('intervention_' + [string]$interventionInteger[0]) `
        (Test-IntegerExact $reading.value ([long]$interventionInteger[1])) `
        'intervention tail shape must be bound to the index-930 one-shot' `
        $interventionInteger[1] $reading.value
  }
  $oneShot = Get-PropertyValue $intervention 'one_shot'
  Add-ValidationCheck $result 'intervention_one_shot' `
      (Test-BooleanExact $oneShot.value $true) `
      'diagnostic intervention must be one-shot' $true $oneShot.value
  $runtimeCommand = Get-PropertyValue $intervention 'runtime_command_used'
  Add-ValidationCheck $result 'intervention_no_runtime_command' `
      (Test-BooleanExact $runtimeCommand.value $false) `
      'compile-time fault must not consume runtime transport bytes' `
      $false $runtimeCommand.value

  $fixture = (Get-PropertyValue $Summary 'fixture').value
  $strictFixture = (Get-PropertyValue $fixture 'strict_contract').value
  foreach ($fixtureString in @(
      @('fixture_hex','hex',$expectedFixtureHex),
      @('fixture_sha256','sha256',$expectedFixtureSha256),
      @('fixture_disposition','write_disposition','ACKNOWLEDGED_EXACTLY_ONCE'))) {
    $reading = Get-PropertyValue $fixture ([string]$fixtureString[1])
    Add-ValidationCheck $result ([string]$fixtureString[0]) `
        ($reading.found -and $reading.value -is [string] -and
          [string]$reading.value -ceq [string]$fixtureString[2]) `
        'exact PARAM_REQUEST_LIST fixture identity/commit required' `
        $fixtureString[2] $reading.value
  }
  foreach ($fixtureInteger in @(
      @('fixture_size_14','size_bytes',14),
      @('fixture_attempt_once','attempt_count',1),
      @('fixture_write_once','write_count',1))) {
    $reading = Get-PropertyValue $fixture ([string]$fixtureInteger[1])
    Add-ValidationCheck $result ([string]$fixtureInteger[0]) `
        (Test-IntegerExact $reading.value ([long]$fixtureInteger[2])) `
        'exact #21 write cardinality required' $fixtureInteger[2] $reading.value
  }
  $writeUncertain = Get-PropertyValue $fixture 'write_uncertain'
  Add-ValidationCheck $result 'fixture_write_not_uncertain' `
      (Test-BooleanExact $writeUncertain.value $false) `
      'request write must be acknowledged, never uncertain' $false $writeUncertain.value
  $strictFixtureValid = Get-PropertyValue $strictFixture 'valid'
  Add-ValidationCheck $result 'fixture_strict_contract_valid' `
      (Test-BooleanExact $strictFixtureValid.value $true) `
      'fixture CRC and MAVLink identity contract must pass' $true $strictFixtureValid.value
  foreach ($strictInteger in @(
      @('message_id',21),@('sequence',99),@('source_system',255),
      @('source_component',190),@('target_system',1),
      @('target_component',1),@('crc_extra',159))) {
    $reading = Get-PropertyValue $strictFixture ([string]$strictInteger[0])
    Add-ValidationCheck $result ('fixture_strict_' + [string]$strictInteger[0]) `
        (Test-IntegerExact $reading.value ([long]$strictInteger[1])) `
        'frozen MAVLink2 PARAM_REQUEST_LIST field must be exact' `
        $strictInteger[1] $reading.value
  }

  $paramList = (Get-PropertyValue $Summary 'param_list').value
  $paramValid = Get-PropertyValue $paramList 'valid'
  Add-ValidationCheck $result 'param_list_valid' `
      (Test-BooleanExact $paramValid.value $true) `
      'parameter-list semantic assessment must pass' $true $paramValid.value
  foreach ($listInteger in @(
      @('expected_param_count',932),@('expected_last_index',931),
      @('expected_source_system',1),@('expected_source_component',1),
      @('indexed_frame_count',932),@('unique_count',932),
      @('missing_count',0),@('duplicate_count',0),
      @('out_of_order_count',0),@('out_of_range_count',0),
      @('count_mismatch_count',0),@('wrong_source_count',0),
      @('bad_payload_length_count',0),@('invalid_param_id_count',0),
      @('duplicate_param_id_count',0),@('unique_param_ids',932),
      @('invalid_param_type_count',0),@('unknown_sentinel_count',0),
      @('extra_param_value_count',0),@('first_index',0),
      @('last_index',931),@('next_expected_index',932))) {
    $reading = Get-PropertyValue $paramList ([string]$listInteger[0])
    Add-ValidationCheck $result ('param_list_' + [string]$listInteger[0]) `
        (Test-IntegerExact $reading.value ([long]$listInteger[1])) `
        '0..931 list proof is exact, unique, ordered, source-1/1, and complete' `
        $listInteger[1] $reading.value
  }
  $strictAscending = Get-PropertyValue $paramList 'strict_ascending'
  Add-ValidationCheck $result 'param_list_strict_ascending' `
      (Test-BooleanExact $strictAscending.value $true) `
      'aggregate list proof must establish the exact 0..931 sequence' `
      $true $strictAscending.value

  $heartbeat = (Get-PropertyValue $Summary 'heartbeat').value
  $heartbeatValid = Get-PropertyValue $heartbeat 'valid'
  Add-ValidationCheck $result 'heartbeat_valid' `
      (Test-BooleanExact $heartbeatValid.value $true) `
      'Heartbeat edge/consecutive/tail assessment must pass' `
      $true $heartbeatValid.value
  foreach ($hbInteger in @(
      @('source_system',1),@('source_component',1),
      @('heartbeat_max_gap_ms',2500),@('exceedance_count',0))) {
    $reading = Get-PropertyValue $heartbeat ([string]$hbInteger[0])
    Add-ValidationCheck $result ('heartbeat_' + [string]$hbInteger[0]) `
        (Test-IntegerExact $reading.value ([long]$hbInteger[1])) `
        'Heartbeat source and SLA must be exact' $hbInteger[1] $reading.value
  }
  $hbCount = Get-PropertyValue $heartbeat 'count'
  Add-ValidationCheck $result 'heartbeat_count_at_least_two' `
      (Test-IntegerAtLeast $hbCount.value 2) `
      'at least two primary heartbeats required' '>=2' $hbCount.value
  foreach ($hbGap in @('first_edge_ms','maximum_gap_ms','tail_edge_ms')) {
    $reading = Get-PropertyValue $heartbeat $hbGap
    Add-ValidationCheck $result ('heartbeat_' + $hbGap + '_within_2500') `
        (Test-NumberAtMost $reading.value 2500.0 0.0) `
        'every closed and boundary Heartbeat gap must be <=2500 ms' '<=2500' $reading.value
  }

  $parser = (Get-PropertyValue $Summary 'parser_integrity').value
  $parserValid = Get-PropertyValue $parser 'valid'
  Add-ValidationCheck $result 'parser_integrity_valid' `
      (Test-BooleanExact $parserValid.value $true) `
      'official M0-M1 parser assessment must pass' $true $parserValid.value
  foreach ($parserZero in @('unsupported','unsupported_flags','bad_payload_length',
      'bad_crc','noise_bytes','invalid_length','partial_buffer_bytes',
      'expected_length')) {
    $reading = Get-PropertyValue $parser $parserZero
    Add-ValidationCheck $result ('parser_' + $parserZero + '_zero') `
        (Test-IntegerExact $reading.value 0) `
        'parser errors/noise/partial state must be exactly zero' 0 $reading.value
  }

  $fairness = (Get-PropertyValue $Summary 'pump_fairness').value
  foreach ($fairBool in @('measurement_complete','valid')) {
    $reading = Get-PropertyValue $fairness $fairBool
    Add-ValidationCheck $result ('fairness_' + $fairBool) `
        (Test-BooleanExact $reading.value $true) `
        'producer-clock fairness evidence must be complete and valid' $true $reading.value
  }
  $fairSchema = Get-PropertyValue $fairness 'schema_version'
  Add-ValidationCheck $result 'fairness_schema_v4' `
      (Test-IntegerExact $fairSchema.value 4) `
      'live HIL must use producer-thread fairness schema v4' 4 $fairSchema.value
  $hardLimit = Get-PropertyValue $fairness 'hard_limit_ms'
  Add-ValidationCheck $result 'fairness_hard_limit_100' `
      (Test-NumberAtMost $hardLimit.value 100.0 100.0) `
      'fairness hard limit must remain exactly 100 ms' 100 $hardLimit.value
  foreach ($roleName in @('vehicle','ground')) {
    $role = (Get-PropertyValue $fairness $roleName).value
    $serviceCount = Get-PropertyValue $role 'service_count'
    Add-ValidationCheck $result ("fairness_${roleName}_serviced") `
        ($serviceCount.found -and $serviceCount.value -isnot [string] -and
          [decimal]$serviceCount.value -gt 0) 'each role must be serviced' '>0' $serviceCount.value
    foreach ($durationKey in @('max_service_gap_ms','max_read_parse_duration_ms')) {
      $reading = Get-PropertyValue $role $durationKey
      Add-ValidationCheck $result ("fairness_${roleName}_${durationKey}_below_100") `
          ((Test-NumberAtMost $reading.value 99.999999 0.0)) `
          'strict fairness comparison is <100 ms' '<100' $reading.value
    }
    foreach ($zeroKey in @('service_gap_over_hard_limit_count',
        'read_parse_duration_over_hard_limit_count','overflow_count')) {
      $reading = Get-PropertyValue $role $zeroKey
      Add-ValidationCheck $result ("fairness_${roleName}_${zeroKey}_zero") `
          (Test-IntegerExact $reading.value 0) `
          'no fairness/ring hard-limit failure is permitted' 0 $reading.value
    }
    foreach ($trueKey in @('producer_fair','ring_consistent')) {
      $reading = Get-PropertyValue $role $trueKey
      Add-ValidationCheck $result ("fairness_${roleName}_${trueKey}") `
          (Test-BooleanExact $reading.value $true) `
          'producer and ring evidence must independently pass' $true $reading.value
    }
    $overflow = Get-PropertyValue $role 'overflow_latched'
    Add-ValidationCheck $result ("fairness_${roleName}_overflow_not_latched") `
        (Test-BooleanExact $overflow.value $false) `
        'ring overflow must not latch' $false $overflow.value
    $fatal = Get-PropertyValue $role 'fatal_error'
    Add-ValidationCheck $result ("fairness_${roleName}_fatal_error_null") `
        ($fatal.found -and $fatal.value -is [string] -and
          [string]$fatal.value -ceq '') `
        'live reader role must encode no fatal error as an exact empty string' `
        $null $fatal.value
  }

  $assessment = (Get-PropertyValue $Summary 'post_diagnostic_assessment').value
  $assessmentValid = Get-PropertyValue $assessment 'valid'
  $assessmentFailed = Get-PropertyValue $assessment 'failed_count'
  $nativePath = Get-PropertyValue $assessment 'native_stream_path'
  $recoveryComplete = Get-PathValue $assessment @('recovery_evidence','complete')
  Add-ValidationCheck $result 'post_assessment_valid' `
      (Test-BooleanExact $assessmentValid.value $true) `
      'post diagnostic assessment must pass' $true $assessmentValid.value
  Add-ValidationCheck $result 'post_assessment_failed_count_zero' `
      (Test-IntegerExact $assessmentFailed.value 0) `
      'post diagnostic assessment must contain no failed checks' 0 $assessmentFailed.value
  Add-ValidationCheck $result 'post_native_path_future' `
      ($nativePath.found -and $nativePath.value -is [string] -and
        [string]$nativePath.value -ceq 'FUTURE_INDEX_RECOVERY') `
      'normal or timeout recovery cannot satisfy this directed run' `
      'FUTURE_INDEX_RECOVERY' $nativePath.value
  Add-ValidationCheck $result 'post_recovery_evidence_complete' `
      ($recoveryComplete.found -and
        (Test-BooleanExact $recoveryComplete.value $true)) `
      'all mandatory recovery counters and latch gauges must be present' `
      $true $recoveryComplete.value
  $allAssessmentChecks = (Get-PropertyValue $assessment 'checks').value
  $invalidAssessmentChecks = @($allAssessmentChecks | Where-Object {
      $validReading = Get-PropertyValue $_ 'valid'
      -not (Test-BooleanExact $validReading.value $true)
    })
  Add-ValidationCheck $result 'all_post_assessment_checks_valid' `
      ($null -ne $allAssessmentChecks -and $invalidAssessmentChecks.Count -eq 0) `
      'no generic or directed post check may be invalid' 0 $invalidAssessmentChecks.Count

  $expectationReading = Get-PropertyValue $assessment 'diagnostic_fault_expectation'
  $expectation = $expectationReading.value
  Add-ValidationCheck $result 'directed_expectation_exact_schema' `
      ($expectationReading.found -and (Test-ExactPropertySet $expectation @(
        'mode','index','macro','requested','verified_exact',
        'expected_future_index','expected_missing_tail','exact_check_count',
        'failed_check_count'))) `
      'assessment expectation must expose only the nine bound fields'
  foreach ($expectString in @(
      @('mode','FUTURE_INDEX_RECOVERY'),@('macro',$faultMacro))) {
    $reading = Get-PropertyValue $expectation ([string]$expectString[0])
    Add-ValidationCheck $result ('expectation_' + [string]$expectString[0]) `
        ($reading.found -and $reading.value -is [string] -and
          [string]$reading.value -ceq [string]$expectString[1]) `
        'assessment is bound to the requested compile-time intervention' `
        $expectString[1] $reading.value
  }
  foreach ($expectInteger in @(
      @('index',930),@('expected_future_index',931),
      @('expected_missing_tail',2),@('exact_check_count',17),
      @('failed_check_count',0))) {
    $reading = Get-PropertyValue $expectation ([string]$expectInteger[0])
    Add-ValidationCheck $result ('expectation_' + [string]$expectInteger[0]) `
        (Test-IntegerExact $reading.value ([long]$expectInteger[1])) `
        'directed expectation cardinality and indices are exact' `
        $expectInteger[1] $reading.value
  }
  foreach ($expectBoolean in @('requested','verified_exact')) {
    $reading = Get-PropertyValue $expectation $expectBoolean
    Add-ValidationCheck $result ('expectation_' + $expectBoolean) `
        (Test-BooleanExact $reading.value $true) `
        'directed expectation must be requested and exactly verified' $true $reading.value
  }

  [string[]]$directedNames = @(
    'directed_future_path_exact','directed_future_latch_exact',
    'directed_future_pvto_delta_exact','directed_future_prgap_delta_exact',
    'directed_future_prto_delta_exact','directed_future_prfut_delta_exact',
    'directed_future_ppre_delta_exact','directed_future_pnq_delta_exact',
    'directed_future_prold_delta_exact',
    'directed_future_prq_missing_tail_exact',
    'directed_future_prtx_missing_tail_exact',
    'directed_future_prv_missing_tail_exact',
    'directed_future_prusb_missing_tail_exact',
    'directed_future_pgen_missing_tail_exact',
    'directed_future_ptx_native_plus_tail_exact',
    'directed_future_deq_native_plus_tail_exact',
    'directed_future_rf22_exact')
  [string[]]$actualDirectedNames = @($allAssessmentChecks | ForEach-Object {
      $nameReading = Get-PropertyValue $_ 'name'
      if ($nameReading.found -and
          [string]$nameReading.value -clike 'directed_future_*') {
        [string]$nameReading.value
      }
    })
  Add-ValidationCheck $result 'directed_check_name_set_exact_17' `
      ($actualDirectedNames.Count -eq 17 -and
        @(Compare-Object ($directedNames | Sort-Object) `
          ($actualDirectedNames | Sort-Object)).Count -eq 0) `
      'all and only 17 exact directed checks must be present' `
      $directedNames $actualDirectedNames
  Add-ValidationCheck $result 'directed_future_path_named_check' `
      (Test-NamedScalarCheck $assessment 'directed_future_path_exact' `
        'FUTURE_INDEX_RECOVERY' -String) `
      'named path check must compare exact equal strings'
  $latchCheck = Get-NamedAssessmentCheck $assessment 'directed_future_latch_exact'
  [string[]]$latchKeys = @('expected_index','received_index','received_count','reason')
  [bool]$latchCheckValid = $false
  if ($latchCheck.found) {
    $validReading = Get-PropertyValue $latchCheck.value 'valid'
    $expectedLatch = (Get-PropertyValue $latchCheck.value 'expected').value
    $actualLatch = (Get-PropertyValue $latchCheck.value 'actual').value
    $latchCheckValid = ((Test-BooleanExact $validReading.value $true) -and
        (Test-ExactPropertySet $expectedLatch $latchKeys) -and
        (Test-ExactPropertySet $actualLatch $latchKeys))
    foreach ($latchSpec in @(
        @('expected_index',930),@('received_index',931),
        @('received_count',932),@('reason',1))) {
      $expectedValue = Get-PropertyValue $expectedLatch ([string]$latchSpec[0])
      $actualValue = Get-PropertyValue $actualLatch ([string]$latchSpec[0])
      $latchCheckValid = ($latchCheckValid -and
          (Test-IntegerExact $expectedValue.value ([long]$latchSpec[1])) -and
          (Test-IntegerExact $actualValue.value ([long]$latchSpec[1])))
    }
  }
  Add-ValidationCheck $result 'directed_future_latch_named_check' `
      $latchCheckValid 'named latch check must be exact 930/931/932/reason1'

  $directedScalarChecks = [ordered]@{
    directed_future_pvto_delta_exact=0
    directed_future_prgap_delta_exact=1
    directed_future_prto_delta_exact=0
    directed_future_prfut_delta_exact=1
    directed_future_ppre_delta_exact=0
    directed_future_pnq_delta_exact=1
    directed_future_prold_delta_exact=0
    directed_future_prq_missing_tail_exact=2
    directed_future_prtx_missing_tail_exact=2
    directed_future_prv_missing_tail_exact=2
    directed_future_prusb_missing_tail_exact=2
    directed_future_pgen_missing_tail_exact=2
    directed_future_ptx_native_plus_tail_exact=3
    directed_future_deq_native_plus_tail_exact=3
    directed_future_rf22_exact=934
  }
  foreach ($entry in $directedScalarChecks.GetEnumerator()) {
    Add-ValidationCheck $result ('named_' + [string]$entry.Key) `
        (Test-NamedScalarCheck $assessment ([string]$entry.Key) ([long]$entry.Value)) `
        'directed named check must have exact expected==actual and valid=true' `
        $entry.Value $null
  }

  $recoveryExactDeltas = [ordered]@{
    pvto=0;prgap=1;prto=0;prfut=1;ppre=0;pnq=1;prold=0
    prq=2;prtx=2;prv=2;prusb=2;pgen=2;ptx=3;deq=3;rf22=934;punm=0
  }
  foreach ($entry in $recoveryExactDeltas.GetEnumerator()) {
    Add-ValidationCheck $result ('recovery_delta_' + [string]$entry.Key) `
        (Test-RecoveryDeltaExact $assessment ([string]$entry.Key) `
          ([uint64]$entry.Value)) `
        'recovery evidence must independently preserve exact monotonic delta' `
        $entry.Value $null
  }
  foreach ($entry in ([ordered]@{
      pract=1;prlv=1;prlr=1;prlex=930;prlrx=931;prlcnt=932
    }).GetEnumerator()) {
    Add-ValidationCheck $result ('recovery_latch_' + [string]$entry.Key) `
        (Test-RecoveryPostExact $assessment ([string]$entry.Key) `
          ([uint64]$entry.Value)) `
        'first recovery latch must identify the single 930->931 future event' `
        $entry.Value $null
  }

  foreach ($standardCheck in @(
      @('ground_param_request_list_u21',1),
      @('ground_proxy_request_completed_upcon',1),
      @('ground_proxy_native_list_leased_once',1),
      @('ground_proxy_native_poison_zero',0),
      @('ground_matching_USB_param_values_932',932),
      @('vehicle_native_fence_committed_once',1),
      @('vehicle_native_frames_queued_exact',932))) {
    Add-ValidationCheck $result ('post_named_' + [string]$standardCheck[0]) `
        (Test-NamedScalarCheck $assessment ([string]$standardCheck[0]) `
          ([long]$standardCheck[1])) `
        'standard exact request/list/Vehicle accounting check must remain exact' `
        $standardCheck[1] $null
  }
  foreach ($standardAbsoluteZeroCheck in @(
      'vehicle_native_fence_busy_zero',
      'vehicle_native_sequence_failures_zero')) {
    Add-ValidationCheck $result ('post_named_' + $standardAbsoluteZeroCheck) `
        (Test-NamedAbsoluteZeroCheck $assessment $standardAbsoluteZeroCheck) `
        'absolute-zero named check must prove before, after, and delta are zero' `
        0 $null
  }

  $snapshots = (Get-PropertyValue $Summary 'snapshots').value
  $vehicleBefore = (Get-PropertyValue $snapshots 'pre_request_vehicle').value
  $vehicleAfter = (Get-PropertyValue $snapshots 'post_vehicle').value

  # R13-R5 proved that native list completion can legitimately coexist with
  # one queued periodic STAT_RUNTIME at the #21 fence and later periodic
  # STAT_RUNTIME frames rejected by the generation fence. The old aggregate
  # counters cannot distinguish those exact sentinels from an arbitrary valid
  # #22. Require the production classifier fields before evaluating any R5-
  # shaped aggregate accounting; absence is explicitly legacy-insufficient.
  [string[]]$nativeDeltaKeys = @(
    'd722','stqf','stdone','stdup','snf','snbusy','sncf','sncb','snff',
    'snq','snseq','sncsf','sncsb','sncof','sncob','snfsf','snfof',
    'snftr','sncerr')
  [string[]]$nativeAbsoluteNumericKeys = @(
    'snffm','snflm','snfmg','snul','snur','snuv',
    'snusg','snusz','snup','snusy','snucp','snusq','snumask','snuval',
    'snui','snuc','snut','snums')
  $nativeDeltas = [ordered]@{}
  $missingClassification = New-Object 'System.Collections.Generic.List[string]'
  foreach ($key in $nativeDeltaKeys) {
    $beforeReading = Get-VCStat3UInt64 $vehicleBefore $key
    $afterReading = Get-VCStat3UInt64 $vehicleAfter $key
    if (-not $beforeReading.found) { $missingClassification.Add("${key}:before") }
    if (-not $afterReading.found) { $missingClassification.Add("${key}:after") }
    $delta = Get-VCStat3Delta -Before $vehicleBefore -After $vehicleAfter `
        -Key $key
    $nativeDeltas[$key] = $delta
  }
  foreach ($key in $nativeAbsoluteNumericKeys) {
    $beforeReading = Get-VCStat3UInt64 $vehicleBefore $key
    $afterReading = Get-VCStat3UInt64 $vehicleAfter $key
    if (-not $beforeReading.found) { $missingClassification.Add("${key}:before") }
    if (-not $afterReading.found) { $missingClassification.Add("${key}:after") }
  }
  $nativeIdBefore = Get-VCStat3String $vehicleBefore 'snuid'
  $nativeIdAfter = Get-VCStat3String $vehicleAfter 'snuid'
  if (-not $nativeIdBefore.found) { $missingClassification.Add('snuid:before') }
  if (-not $nativeIdAfter.found) { $missingClassification.Add('snuid:after') }
  [bool]$classificationEvidenceComplete = $missingClassification.Count -eq 0
  Add-ValidationCheck $result `
      'vehicle_native_strict_classification_evidence_complete' `
      $classificationEvidenceComplete `
      'exact VCSTAT3 classification fields are mandatory; aggregate-only R5 is insufficient legacy evidence' `
      'all exact/other/cadence/error/latch fields in pre-request and post VCSTAT3' `
      $missingClassification.ToArray()

  $addNativeDeltaExact = {
    param([string]$Name, [string]$Key, [uint64]$Expected)
    $reading = $nativeDeltas[$Key]
    Add-ValidationCheck $result $Name `
        ($null -ne $reading -and $reading.found -and
          [uint64]$reading.delta -eq $Expected) `
        'native accounting delta must be exact and monotonic' `
        $Expected $(if($null -ne $reading){$reading.delta}else{$null})
  }
  foreach ($spec in @(
      @('vehicle_native_strict_target_queued_two','stqf',2),
      @('vehicle_native_strict_target_completed_two','stdone',2),
      @('vehicle_native_strict_fence_once','snf',1),
      @('vehicle_native_strict_native_queued_932','snq',932))) {
    & $addNativeDeltaExact ([string]$spec[0]) ([string]$spec[1]) `
        ([uint64]$spec[2])
  }
  $addNativeAbsoluteZero = {
    param([string]$Name, [string]$Key)
    $beforeReading = Get-VCStat3UInt64 $vehicleBefore $Key
    $afterReading = Get-VCStat3UInt64 $vehicleAfter $Key
    Add-ValidationCheck $result $Name `
        ($beforeReading.found -and $afterReading.found -and
          [uint64]$beforeReading.value -eq 0 -and
          [uint64]$afterReading.value -eq 0) `
        'native error/exclusion counter must be absolute zero in both baseline and post snapshots' `
        ([ordered]@{before=0;after=0}) `
        ([ordered]@{before=$beforeReading.value;after=$afterReading.value})
  }
  foreach ($spec in @(
      @('vehicle_native_strict_target_duplicate_zero','stdup'),
      @('vehicle_native_strict_fence_busy_zero','snbusy'),
      @('vehicle_native_strict_sequence_failures_zero','snseq'),
      @('vehicle_native_strict_other_cancelled_frames_zero','sncof',0),
      @('vehicle_native_strict_other_cancelled_bytes_zero','sncob',0),
      @('vehicle_native_strict_other_filtered_frames_zero','snfof',0),
      @('vehicle_native_strict_classification_errors_zero','sncerr',0),
      @('vehicle_native_strict_filter_time_regressions_zero','snftr',0))) {
    & $addNativeAbsoluteZero ([string]$spec[0]) ([string]$spec[1])
  }

  $sncf = $nativeDeltas['sncf']; $sncsf = $nativeDeltas['sncsf']
  $sncof = $nativeDeltas['sncof']; $sncb = $nativeDeltas['sncb']
  $sncsb = $nativeDeltas['sncsb']; $sncob = $nativeDeltas['sncob']
  $snff = $nativeDeltas['snff']; $snfsf = $nativeDeltas['snfsf']
  $snfof = $nativeDeltas['snfof']; $d722 = $nativeDeltas['d722']
  $snq = $nativeDeltas['snq']; $stqf = $nativeDeltas['stqf']
  [bool]$cancelFramePartition = ($sncf.found -and $sncsf.found -and
      $sncof.found -and [decimal]$sncf.delta -eq
        ([decimal]$sncsf.delta + [decimal]$sncof.delta))
  [bool]$cancelBytePartition = ($sncb.found -and $sncsb.found -and
      $sncob.found -and [decimal]$sncb.delta -eq
        ([decimal]$sncsb.delta + [decimal]$sncob.delta))
  [bool]$cancelledSize = ($sncb.found -and $sncf.found -and
      [decimal]$sncb.delta -eq (37 * [decimal]$sncf.delta))
  [bool]$statCancelledSize = ($sncsf.found -and $sncsb.found -and
      [decimal]$sncsb.delta -eq (37 * [decimal]$sncsf.delta))
  [bool]$filterFramePartition = ($snff.found -and $snfsf.found -and
      $snfof.found -and [decimal]$snff.delta -eq
        ([decimal]$snfsf.delta + [decimal]$snfof.delta))
  [bool]$d722Partition = ($d722.found -and $sncf.found -and $snq.found -and
      $snff.found -and $stqf.found -and [decimal]$d722.delta -eq
        ([decimal]$sncf.delta + [decimal]$snq.delta +
         [decimal]$snff.delta + [decimal]$stqf.delta))
  foreach ($relation in @(
      @('vehicle_native_strict_cancel_frame_partition',$cancelFramePartition,
        'sncf == sncsf + sncof'),
      @('vehicle_native_strict_cancel_byte_partition',$cancelBytePartition,
        'sncb == sncsb + sncob'),
      @('vehicle_native_strict_cancelled_size_37',$cancelledSize,
        'sncb == 37 * sncf'),
      @('vehicle_native_strict_stat_cancelled_size_37',$statCancelledSize,
        'sncsb == 37 * sncsf'),
      @('vehicle_native_strict_filter_frame_partition',$filterFramePartition,
        'snff == snfsf + snfof'),
      @('vehicle_native_strict_d722_partition',$d722Partition,
        'd722 == sncf + snq + snff + stqf'))) {
    Add-ValidationCheck $result ([string]$relation[0]) ([bool]$relation[1]) `
        'independent native exclusion accounting relation must balance exactly' `
        ([string]$relation[2]) $null
  }

  $filterCountBefore = Get-VCStat3UInt64 $vehicleBefore 'snfsf'
  $filterCountAfter = Get-VCStat3UInt64 $vehicleAfter 'snfsf'
  $firstFilterBefore = Get-VCStat3UInt64 $vehicleBefore 'snffm'
  $lastFilterBefore = Get-VCStat3UInt64 $vehicleBefore 'snflm'
  $minimumGapBefore = Get-VCStat3UInt64 $vehicleBefore 'snfmg'
  $firstFilter = Get-VCStat3UInt64 $vehicleAfter 'snffm'
  $lastFilter = Get-VCStat3UInt64 $vehicleAfter 'snflm'
  $minimumGap = Get-VCStat3UInt64 $vehicleAfter 'snfmg'
  $testCadenceSnapshot = {
    param($Count, $First, $Last, $Gap)
    if (-not $Count.found -or -not $First.found -or -not $Last.found -or
        -not $Gap.found) { return $false }
    [uint64]$countValue = [uint64]$Count.value
    [uint64]$firstValue = [uint64]$First.value
    [uint64]$lastValue = [uint64]$Last.value
    [uint64]$gapValue = [uint64]$Gap.value
    if ($countValue -eq 0) {
      return ($firstValue -eq 0 -and $lastValue -eq 0 -and $gapValue -eq 0)
    }
    if ($countValue -eq 1) {
      return ($lastValue -eq $firstValue -and $gapValue -eq 0)
    }
    return ($lastValue -ge $firstValue -and
        $gapValue -le ($lastValue - $firstValue))
  }
  [bool]$beforeCadenceConsistent = & $testCadenceSnapshot `
      $filterCountBefore $firstFilterBefore $lastFilterBefore $minimumGapBefore
  [bool]$afterCadenceConsistent = & $testCadenceSnapshot `
      $filterCountAfter $firstFilter $lastFilter $minimumGap
  [bool]$unchangedWithoutNewFilters = ($snfsf.found -and
      ([uint64]$snfsf.delta -ne 0 -or
       ([uint64]$firstFilter.value -eq [uint64]$firstFilterBefore.value -and
        [uint64]$lastFilter.value -eq [uint64]$lastFilterBefore.value -and
        [uint64]$minimumGap.value -eq [uint64]$minimumGapBefore.value)))
  [bool]$multipleFilterCadence = ($snfsf.found -and
      ([uint64]$snfsf.delta -lt 2 -or
       ([uint64]$lastFilter.value -gt [uint64]$firstFilter.value -and
        [uint64]$minimumGap.value -gt 0 -and
        [uint64]$minimumGap.value -le
          ([uint64]$lastFilter.value - [uint64]$firstFilter.value))))
  [bool]$cadenceValid = ($beforeCadenceConsistent -and
      $afterCadenceConsistent -and $unchangedWithoutNewFilters -and
      $multipleFilterCadence)
  Add-ValidationCheck $result 'vehicle_native_strict_stat_filter_cadence' `
      $cadenceValid `
      'STAT_RUNTIME cadence fields must match their observed count; a positive gap is required only for two or more newly filtered frames' `
      '0 frames => zero fields; 1 => first=last and gap=0; delta >=2 => ordered nonzero cadence' `
      ([ordered]@{delta=$snfsf.delta;before=[ordered]@{
          count=$filterCountBefore.value;first=$firstFilterBefore.value
          last=$lastFilterBefore.value;min_gap=$minimumGapBefore.value
        };after=[ordered]@{count=$filterCountAfter.value;first=$firstFilter.value
          last=$lastFilter.value;min_gap=$minimumGap.value}})

  [string[]]$zeroLatchKeys = @('snul','snur','snuv','snusg','snusz','snup',
      'snusy','snucp','snusq','snumask','snuval','snui','snuc','snut','snums')
  [bool]$latchClean = $true
  foreach ($key in $zeroLatchKeys) {
    $before = Get-VCStat3UInt64 $vehicleBefore $key
    $after = Get-VCStat3UInt64 $vehicleAfter $key
    $latchClean = ($latchClean -and $before.found -and $after.found -and
        [uint64]$before.value -eq 0 -and [uint64]$after.value -eq 0)
  }
  $latchClean = ($latchClean -and $nativeIdBefore.found -and
      $nativeIdAfter.found -and
      [string]$nativeIdBefore.value -ceq
        '00000000000000000000000000000000' -and
      [string]$nativeIdAfter.value -ceq
        '00000000000000000000000000000000')
  Add-ValidationCheck $result 'vehicle_native_strict_unexpected_latch_clean' `
      $latchClean `
      'zero other-class deltas require an entirely clear first-unexpected latch' `
      'all numeric latch fields zero and snuid=32 zero hex digits' `
      ([ordered]@{before=$nativeIdBefore.value;after=$nativeIdAfter.value})

  foreach ($vehicleDelta in @(@('snf',1),@('snq',932))) {
    Add-ValidationCheck $result ('vehicle_snapshot_delta_' + [string]$vehicleDelta[0]) `
        (Test-SnapshotDeltaExact $vehicleBefore $vehicleAfter `
          ([string]$vehicleDelta[0]) ([uint64]$vehicleDelta[1])) `
        'Vehicle pre-request/post diagnostic fields independently prove exact queue deltas' `
        $vehicleDelta[1] $null
  }
  foreach ($errorKey in @('cc','rcr','riv','ocr','oiv','eiv','eov','out',
      'd6cr','d7cr','pvbad','pvov','eo','sc','evo')) {
    $beforeReading = Get-SnapshotUInt64 $vehicleBefore $errorKey
    $afterReading = Get-SnapshotUInt64 $vehicleAfter $errorKey
    Add-ValidationCheck $result ("vehicle_snapshot_absolute_${errorKey}_zero") `
        ($beforeReading.found -and $afterReading.found -and
          [uint64]$beforeReading.value -eq 0 -and
          [uint64]$afterReading.value -eq 0) `
        'Vehicle error counter must be absolute zero in both baseline and post snapshots' `
        ([ordered]@{before=0;after=0}) `
        ([ordered]@{before=$beforeReading.value;after=$afterReading.value})
  }
  foreach ($vehiclePost in @(@('r',1),@('f',0))) {
    $reading = Get-SnapshotUInt64 $vehicleAfter ([string]$vehiclePost[0])
    Add-ValidationCheck $result ('vehicle_post_' + [string]$vehiclePost[0]) `
        ($reading.found -and
          [uint64]$reading.value -eq [uint64]$vehiclePost[1]) `
        'Vehicle must finish ready and not failed' $vehiclePost[1] $reading.value
  }

  [object[]]$array = $result.ToArray()
  [object[]]$strictNativeFailures = @($array | Where-Object {
      [string]$_.name -clike 'vehicle_native_strict_*' -and -not $_.passed
    })
  [string]$nativeClassification = if(-not $classificationEvidenceComplete) {
    'INSUFFICIENT_LEGACY_CLASSIFICATION_EVIDENCE'
  } elseif($strictNativeFailures.Count -eq 0) {
    'STRICT_NATIVE_CLASSIFICATION_ACCEPTED'
  } else {
    'STRICT_NATIVE_CLASSIFICATION_REJECTED'
  }
  return [pscustomobject][ordered]@{
    valid=@($array | Where-Object {-not $_.passed}).Count -eq 0
    check_count=$array.Count
    failed_count=@($array | Where-Object {-not $_.passed}).Count
    first_failed=if(@($array | Where-Object {-not $_.passed}).Count -gt 0){
      @($array | Where-Object {-not $_.passed})[0].name
    }else{$null}
    native_classification=$nativeClassification
    checks=$array
  }
}

function New-DeltaEvidence {
  param([uint64]$Delta, [uint64]$Baseline = 100)
  return [pscustomobject][ordered]@{
    key=$null;found=$true;monotonic=$true;before=$Baseline
    after=([uint64]$Baseline + $Delta);delta=$Delta
  }
}

function New-PostEvidence {
  param([uint64]$Value)
  return [pscustomobject][ordered]@{found=$true;value=$Value}
}

function New-AssessmentScalarCheck {
  param([string]$Name, $Value)
  return [pscustomobject][ordered]@{
    name=$Name;key=$Name;rule='exact';expected=$Value;actual=$Value;valid=$true
  }
}

function New-AssessmentAbsoluteZeroCheck {
  param([string]$Name)
  return [pscustomobject][ordered]@{
    name=$Name;key=$Name;rule='exact_VCSTAT3_baseline_post_and_delta_zero'
    expected=0;actual=[pscustomobject][ordered]@{before=0;after=0;delta=0}
    valid=$true
  }
}

function New-VehicleSnapshot {
  param([switch]$Post)
  $fields = [ordered]@{}
  foreach ($key in @('snbusy','snseq','stdup','cc','rcr','riv',
      'ocr','oiv','eiv','eov','out','d6cr','d7cr','pvbad','pvov','eo','sc','evo')) {
    $fields[$key] = '0'
  }
  foreach ($key in @('sncof','sncob','snfof','sncerr','snftr','snul','snur',
      'snuv','snusg','snusz','snup','snusy','snucp','snusq','snumask',
      'snuval','snui','snuc','snut','snums')) {
    $fields[$key] = '0'
  }
  $fields['snuid'] = '00000000000000000000000000000000'
  foreach ($spec in @(
      @('d722','2','1109'),@('stqf','0','2'),@('stdone','0','2'),
      @('snf','0','1'),@('sncf','0','1'),@('sncb','0','37'),
      @('snff','0','172'),@('snq','0','932'),@('sncsf','0','1'),
      @('sncsb','0','37'),@('snfsf','0','172'),
      @('snffm','0','100000'),@('snflm','0','5230000'),
      @('snfmg','0','30000'))) {
    $fields[[string]$spec[0]] = if($Post.IsPresent){
      [string]$spec[2]
    }else{[string]$spec[1]}
  }
  $fields['r'] = '1'
  $fields['f'] = '0'
  return [pscustomobject][ordered]@{
    status='COMPLETE'
    responses=@([pscustomobject][ordered]@{
      tag='VCSTAT3';valid_correlation=$true;fields=[pscustomobject]$fields
    })
  }
}

function New-PositiveDirectedFixture {
  $deltas = [ordered]@{}
  foreach ($entry in ([ordered]@{
      pvto=0;prgap=1;prto=0;prfut=1;ppre=0;pnq=1;prold=0
      prq=2;prtx=2;prv=2;prusb=2;pgen=2;ptx=3;deq=3;rf22=934;punm=0
    }).GetEnumerator()) {
    $deltaEvidence = New-DeltaEvidence ([uint64]$entry.Value)
    $deltaEvidence.key = [string]$entry.Key
    $deltas[[string]$entry.Key] = $deltaEvidence
  }
  $post = [ordered]@{}
  foreach ($entry in ([ordered]@{
      pract=1;prlv=1;prlr=1;prlex=930;prlrx=931;prlcnt=932
      prlseq=44;prlms=5000;rfpbuf=0;rfdmbuf=0;rfdmesc=1
    }).GetEnumerator()) {
    $post[[string]$entry.Key] = New-PostEvidence ([uint64]$entry.Value)
  }
  $assessmentChecks = New-Object 'System.Collections.Generic.List[object]'
  $assessmentChecks.Add((New-AssessmentScalarCheck `
      'directed_future_path_exact' 'FUTURE_INDEX_RECOVERY'))
  $latch = [pscustomobject][ordered]@{
    expected_index=930;received_index=931;received_count=932;reason=1
  }
  $assessmentChecks.Add([pscustomobject][ordered]@{
    name='directed_future_latch_exact';key='prl*';rule='exact'
    expected=$latch;actual=([pscustomobject][ordered]@{
      expected_index=930;received_index=931;received_count=932;reason=1
    });valid=$true
  })
  foreach ($entry in ([ordered]@{
      directed_future_pvto_delta_exact=0
      directed_future_prgap_delta_exact=1
      directed_future_prto_delta_exact=0
      directed_future_prfut_delta_exact=1
      directed_future_ppre_delta_exact=0
      directed_future_pnq_delta_exact=1
      directed_future_prold_delta_exact=0
      directed_future_prq_missing_tail_exact=2
      directed_future_prtx_missing_tail_exact=2
      directed_future_prv_missing_tail_exact=2
      directed_future_prusb_missing_tail_exact=2
      directed_future_pgen_missing_tail_exact=2
      directed_future_ptx_native_plus_tail_exact=3
      directed_future_deq_native_plus_tail_exact=3
      directed_future_rf22_exact=934
    }).GetEnumerator()) {
    $assessmentChecks.Add((New-AssessmentScalarCheck ([string]$entry.Key) `
      ([uint64]$entry.Value)))
  }
  foreach ($entry in ([ordered]@{
      ground_param_request_list_u21=1
      ground_proxy_request_completed_upcon=1
      ground_proxy_native_list_leased_once=1
      ground_proxy_native_poison_zero=0
      ground_matching_USB_param_values_932=932
      vehicle_native_fence_committed_once=1
      vehicle_native_fence_busy_zero=0
      vehicle_native_stale_frames_cancelled_exact=1
      vehicle_native_stale_bytes_cancelled_exact=37
      vehicle_native_stale_frames_filtered_exact=172
      vehicle_native_frames_queued_exact=932
      vehicle_native_sequence_failures_zero=0
    }).GetEnumerator()) {
    if ([string]$entry.Key -cin @(
        'vehicle_native_fence_busy_zero',
        'vehicle_native_sequence_failures_zero')) {
      $assessmentChecks.Add((New-AssessmentAbsoluteZeroCheck `
        ([string]$entry.Key)))
    } else {
      $assessmentChecks.Add((New-AssessmentScalarCheck ([string]$entry.Key) `
        ([uint64]$entry.Value)))
    }
  }
  foreach ($key in @('ground_same_boot','vehicle_same_boot',
      'ground_recovery_latch_time_inside_snapshot_interval')) {
    $assessmentChecks.Add([pscustomobject][ordered]@{
      name=$key;key=$key;rule='fixture_valid';valid=$true
    })
  }

  $paramList = [ordered]@{
    valid=$true;expected_param_count=932;expected_last_index=931
    expected_source_system=1;expected_source_component=1
    indexed_frame_count=932;unique_count=932;missing_count=0
    duplicate_count=0;out_of_order_count=0;out_of_range_count=0
    count_mismatch_count=0;wrong_source_count=0;bad_payload_length_count=0
    invalid_param_id_count=0;duplicate_param_id_count=0;unique_param_ids=932
    invalid_param_type_count=0;known_stat_runtime_sentinel_count=1
    unknown_sentinel_count=0;extra_param_value_count=0
    first_index=0;last_index=931;next_expected_index=932
    strict_ascending=$true;completion_elapsed_ms=123456.0
  }
  $parser = [ordered]@{
    valid=$true;unsupported=0;unsupported_flags=0;bad_payload_length=0
    bad_crc=0;noise_bytes=0;invalid_length=0;partial_buffer_bytes=0
    expected_length=0
  }
  $newFairRole = {
    param([string]$Role)
    [pscustomobject][ordered]@{
      role=$Role;producer_thread_started=$true;producer_thread_joined=$true
      service_count=1000;max_service_gap_ms=48.0
      max_read_parse_duration_ms=4.0
      service_gap_over_hard_limit_count=0
      read_parse_duration_over_hard_limit_count=0
      overflow_latched=$false;overflow_count=0;producer_fair=$true
      ring_consistent=$true;fatal_error=''
    }
  }
  return [pscustomobject][ordered]@{
    schema_version=1;test_id='HIL-DUAL-DIAG-PARAM-LIST-001';status='PASS'
    errors=@();failure=$null
    diagnostic_fault_intervention=[pscustomobject][ordered]@{
      mode='FUTURE_INDEX_RECOVERY';index=930;macro=$faultMacro
      requested=$true;one_shot=$true;expected_future_index=931
      expected_missing_tail=2;runtime_command_used=$false
      verified_exact=$true
    }
    fixture=[pscustomobject][ordered]@{
      size_bytes=14;hex=$expectedFixtureHex;sha256=$expectedFixtureSha256
      attempt_count=1;write_count=1;write_uncertain=$false
      write_disposition='ACKNOWLEDGED_EXACTLY_ONCE'
      strict_contract=[pscustomobject][ordered]@{
        valid=$true;message_id=21;sequence=99;source_system=255
        source_component=190;target_system=1;target_component=1;crc_extra=159
      }
    }
    param_list=[pscustomobject]$paramList
    heartbeat=[pscustomobject][ordered]@{
      valid=$true;source_system=1;source_component=1
      heartbeat_max_gap_ms=2500;count=5000;first_edge_ms=800.0
      maximum_gap_ms=2200.0;tail_edge_ms=700.0;exceedance_count=0
    }
    parser_integrity=[pscustomobject]$parser
    pump_fairness=[pscustomobject][ordered]@{
      schema_version=4;measurement_complete=$true;valid=$true
      hard_limit_ms=100.0;vehicle=(& $newFairRole 'vehicle')
      ground=(& $newFairRole 'ground')
    }
    post_ground_status='COMPLETE';post_vehicle_status='COMPLETE'
    post_diagnostic_assessment=[pscustomobject][ordered]@{
      valid=$true;failed_count=0;first_failed=$null
      native_stream_path='FUTURE_INDEX_RECOVERY'
      recovery_evidence=[pscustomobject][ordered]@{
        complete=$true;deltas=[pscustomobject]$deltas;post=[pscustomobject]$post
      }
      diagnostic_fault_expectation=[pscustomobject][ordered]@{
        mode='FUTURE_INDEX_RECOVERY';index=930;macro=$faultMacro
        requested=$true;verified_exact=$true;expected_future_index=931
        expected_missing_tail=2;exact_check_count=17;failed_check_count=0
      }
      checks=$assessmentChecks.ToArray()
    }
    snapshots=[pscustomobject][ordered]@{
      pre_request_vehicle=(New-VehicleSnapshot)
      post_vehicle=(New-VehicleSnapshot -Post)
    }
  }
}

function Copy-JsonObject {
  param([Parameter(Mandatory = $true)]$Value)
  return (($Value | ConvertTo-Json -Depth 50) | ConvertFrom-Json)
}

function Write-ArtifactManifest {
  param([Parameter(Mandatory = $true)][string]$Directory)
  $rows = @(Get-ChildItem -LiteralPath $Directory -File -Recurse |
    Where-Object { $_.Name -cne 'artifact_hashes.json' } |
    Sort-Object FullName | ForEach-Object {
      [pscustomobject][ordered]@{
        file=$_.FullName.Substring($Directory.Length).TrimStart('\').Replace('\','/')
        bytes=$_.Length;sha256=(Get-Sha256 $_.FullName)
      }
    })
  Write-JsonDurable -Path (Join-Path $Directory 'artifact_hashes.json') `
      -Value $rows
}

$checkerPath = $MyInvocation.MyCommand.Path

if ($SelfTest.IsPresent) {
  if (-not [string]::IsNullOrWhiteSpace($SummaryPath) -or
      $FixtureMode -cne 'NONE') {
    throw '-SelfTest cannot be combined with -SummaryPath or -FixtureMode.'
  }
  $fixturesDirectory = Join-Path $OutputDirectory 'fixtures'
  [void][System.IO.Directory]::CreateDirectory($fixturesDirectory)
  $positive = New-PositiveDirectedFixture
  $positivePath = Join-Path $fixturesDirectory 'positive.json'
  Write-JsonDurable $positivePath $positive
  $positiveReadback = Get-Content -Raw -LiteralPath $positivePath |
      ConvertFrom-Json
  $positiveAssessment = Test-DirectedFutureSummary $positiveReadback

  $negativeCases = @(
    @('status_not_pass',{param($x)$x.status='FAIL'}),
    @('intervention_not_requested',{param($x)$x.diagnostic_fault_intervention.requested=$false}),
    @('request_written_twice',{param($x)$x.fixture.write_count=2}),
    @('list_missing_index_931',{param($x)$x.param_list.last_index=930}),
    @('heartbeat_gap_over_2500',{param($x)$x.heartbeat.maximum_gap_ms=2500.001}),
    @('parser_bad_crc',{param($x)$x.parser_integrity.bad_crc=1}),
    @('fairness_ground_gap_at_hard_limit',{param($x)$x.pump_fairness.ground.max_service_gap_ms=100.0}),
    @('fairness_vehicle_fatal_error_nonempty',{param($x)$x.pump_fairness.vehicle.fatal_error='reader failed'}),
    @('fairness_vehicle_fatal_error_null_legacy',{param($x)$x.pump_fairness.vehicle.fatal_error=$null}),
    @('native_path_normal',{param($x)$x.post_diagnostic_assessment.native_stream_path='NORMAL'}),
    @('latch_received_index_wrong',{param($x)$x.post_diagnostic_assessment.recovery_evidence.post.prlrx.value=932}),
    @('future_counter_not_exact',{param($x)$x.post_diagnostic_assessment.recovery_evidence.deltas.prfut.after=102;$x.post_diagnostic_assessment.recovery_evidence.deltas.prfut.delta=2}),
    @('recovery_evidence_incomplete',{param($x)$x.post_diagnostic_assessment.recovery_evidence.complete=$false}),
    @('directed_exact_check_missing',{param($x)$x.post_diagnostic_assessment.checks=@($x.post_diagnostic_assessment.checks|Where-Object {$_.name -cne 'directed_future_rf22_exact'})}),
    @('directed_exact_count_not_17',{param($x)$x.post_diagnostic_assessment.diagnostic_fault_expectation.exact_check_count=16}),
    @('vehicle_snq_not_932',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snq='931'}),
    @('vehicle_d7_crc_increased',{param($x)$x.snapshots.post_vehicle.responses[0].fields.d7cr='8'}),
    @('vehicle_error_counters_preexisting',{param($x)
      foreach($key in @('cc','rcr','riv','ocr','oiv','eiv','eov','out','d6cr',
          'd7cr','pvbad','pvov','eo','sc','evo')){
        $x.snapshots.pre_request_vehicle.responses[0].fields.($key)='1'
        $x.snapshots.post_vehicle.responses[0].fields.($key)='1'
      }
    }),
    @('precommit_quarantine_nonzero',{param($x)$x.post_diagnostic_assessment.recovery_evidence.deltas.ppre.after=101;$x.post_diagnostic_assessment.recovery_evidence.deltas.ppre.delta=1}),
    @('legacy_R5_classification_fields_missing',{param($x)
      foreach($snapshotName in @('pre_request_vehicle','post_vehicle')){
        $fields=$x.snapshots.$snapshotName.responses[0].fields
        foreach($key in @('sncsf','sncsb','sncof','sncob','snfsf','snfof',
            'snffm','snflm','snfmg','snftr','sncerr','snul','snur','snuv',
            'snusg','snusz','snup','snusy','snucp','snusq','snumask',
            'snuval','snui','snuc','snut','snums','snuid')){
          $fields.PSObject.Properties.Remove($key)
        }
      }
    }),
    @('native_sncb_not_37_times_sncf',{param($x)$x.snapshots.post_vehicle.responses[0].fields.sncb='38'}),
    @('native_d722_partition_mismatch',{param($x)$x.snapshots.post_vehicle.responses[0].fields.d722='1110'}),
    @('native_stqf_not_two',{param($x)$x.snapshots.post_vehicle.responses[0].fields.stqf='1'}),
    @('native_stdone_not_two',{param($x)$x.snapshots.post_vehicle.responses[0].fields.stdone='1'}),
    @('native_stdup_nonzero',{param($x)$x.snapshots.post_vehicle.responses[0].fields.stdup='1'}),
    @('native_target_duplicate_preexisting',{param($x)
      $x.snapshots.pre_request_vehicle.responses[0].fields.stdup='1'
      $x.snapshots.post_vehicle.responses[0].fields.stdup='1'
    }),
    @('native_snf_not_one',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snf='2'}),
    @('named_native_fence_busy_object_nonzero',{param($x)
      $check=@($x.post_diagnostic_assessment.checks|Where-Object {
          $_.name -ceq 'vehicle_native_fence_busy_zero'})[0]
      $check.rule='exact_VCSTAT3_baseline_post_and_delta_zero'
      $check.actual=[pscustomobject][ordered]@{before=0;after=1;delta=1}
    }),
    @('named_native_fence_busy_scalar_legacy',{param($x)
      $check=@($x.post_diagnostic_assessment.checks|Where-Object {
          $_.name -ceq 'vehicle_native_fence_busy_zero'})[0]
      $check.rule='exact'
      $check.actual=0
    }),
    @('native_snbusy_nonzero',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snbusy='1'}),
    @('native_fence_busy_preexisting',{param($x)
      $x.snapshots.pre_request_vehicle.responses[0].fields.snbusy='1'
      $x.snapshots.post_vehicle.responses[0].fields.snbusy='1'
    }),
    @('native_aggregate_cancel_frame_partition_mismatch',{param($x)$x.snapshots.post_vehicle.responses[0].fields.sncf='2'}),
    @('native_aggregate_filter_frame_partition_mismatch',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snff='173'}),
    @('native_snseq_nonzero',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snseq='1'}),
    @('named_native_sequence_object_missing_delta',{param($x)
      $check=@($x.post_diagnostic_assessment.checks|Where-Object {
          $_.name -ceq 'vehicle_native_sequence_failures_zero'})[0]
      $check.rule='exact_VCSTAT3_baseline_post_and_delta_zero'
      $check.actual=[pscustomobject][ordered]@{before=0;after=0}
    }),
    @('native_sequence_failure_preexisting',{param($x)
      $x.snapshots.pre_request_vehicle.responses[0].fields.snseq='1'
      $x.snapshots.post_vehicle.responses[0].fields.snseq='1'
    }),
    @('native_cancel_frame_partition_mismatch',{param($x)$x.snapshots.post_vehicle.responses[0].fields.sncsf='0'}),
    @('native_cancel_byte_partition_mismatch',{param($x)$x.snapshots.post_vehicle.responses[0].fields.sncsb='36'}),
    @('native_filter_frame_partition_mismatch',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snfsf='171'}),
    @('native_other_cancel_frame_nonzero',{param($x)$x.snapshots.post_vehicle.responses[0].fields.sncof='1'}),
    @('native_other_cancel_frame_preexisting',{param($x)
      $x.snapshots.pre_request_vehicle.responses[0].fields.sncof='1'
      $x.snapshots.post_vehicle.responses[0].fields.sncof='1'
    }),
    @('native_other_cancel_byte_nonzero',{param($x)$x.snapshots.post_vehicle.responses[0].fields.sncob='1'}),
    @('native_other_cancel_byte_preexisting',{param($x)
      $x.snapshots.pre_request_vehicle.responses[0].fields.sncob='1'
      $x.snapshots.post_vehicle.responses[0].fields.sncob='1'
    }),
    @('native_other_filter_frame_nonzero',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snfof='1'}),
    @('native_other_filter_frame_preexisting',{param($x)
      $x.snapshots.pre_request_vehicle.responses[0].fields.snfof='1'
      $x.snapshots.post_vehicle.responses[0].fields.snfof='1'
    }),
    @('native_classification_error_nonzero',{param($x)$x.snapshots.post_vehicle.responses[0].fields.sncerr='1'}),
    @('native_classification_error_preexisting',{param($x)
      $x.snapshots.pre_request_vehicle.responses[0].fields.sncerr='1'
      $x.snapshots.post_vehicle.responses[0].fields.sncerr='1'
    }),
    @('native_classification_counter_regression',{param($x)
      $x.snapshots.pre_request_vehicle.responses[0].fields.sncerr='2'
      $x.snapshots.post_vehicle.responses[0].fields.sncerr='1'
    }),
    @('native_stat_filter_time_regression',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snftr='1'}),
    @('native_stat_filter_time_regression_preexisting',{param($x)
      $x.snapshots.pre_request_vehicle.responses[0].fields.snftr='1'
      $x.snapshots.post_vehicle.responses[0].fields.snftr='1'
    }),
    @('native_stat_filter_first_after_last',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snffm='6000000'}),
    @('native_stat_filter_minimum_gap_zero',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snfmg='0'}),
    @('native_stat_filter_minimum_gap_too_large',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snfmg='6000000'}),
    @('native_zero_filter_with_nonzero_cadence',{param($x)
      $fields=$x.snapshots.post_vehicle.responses[0].fields
      foreach($entry in ([ordered]@{
          d722='936';sncf='0';sncb='0';snff='0';sncsf='0';sncsb='0';
          snfsf='0';snffm='1';snflm='1';snfmg='0'
        }).GetEnumerator()){$fields.([string]$entry.Key)=[string]$entry.Value}
    }),
    @('native_single_filter_with_nonzero_gap',{param($x)
      $fields=$x.snapshots.post_vehicle.responses[0].fields
      foreach($entry in ([ordered]@{
          d722='937';sncf='0';sncb='0';snff='1';sncsf='0';sncsb='0';
          snfsf='1';snffm='100000';snflm='100000';snfmg='1'
        }).GetEnumerator()){$fields.([string]$entry.Key)=[string]$entry.Value}
    }),
    @('native_pre_unexpected_latch_nonzero',{param($x)
      $x.snapshots.pre_request_vehicle.responses[0].fields.snul='1'
      $x.snapshots.post_vehicle.responses[0].fields.snul='1'
    }),
    @('native_unexpected_latch_changed',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snul='1'}),
    @('native_unexpected_latch_payload_nonzero',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snur='2'}),
    @('native_unexpected_latch_id_nonzero',{param($x)$x.snapshots.post_vehicle.responses[0].fields.snuid='01000000000000000000000000000000'})
  )
  $additionalPositiveCases = @(
    @('positive_live_runner_schema',{param($x)
      $x.pump_fairness.vehicle.fatal_error=''
      $x.pump_fairness.ground.fatal_error=''
      foreach($check in @($x.post_diagnostic_assessment.checks)){
        if([string]$check.name -cin @(
            'vehicle_native_fence_busy_zero',
            'vehicle_native_sequence_failures_zero')){
          $check.rule='exact_VCSTAT3_baseline_post_and_delta_zero'
          $check.actual=[pscustomobject][ordered]@{before=0;after=0;delta=0}
        }
      }
    }),
    @('positive_zero_native_exclusions',{param($x)
      $fields=$x.snapshots.post_vehicle.responses[0].fields
      foreach($entry in ([ordered]@{
          d722='936';sncf='0';sncb='0';snff='0';sncsf='0';sncsb='0';
          snfsf='0';snffm='0';snflm='0';snfmg='0'
        }).GetEnumerator()){$fields.([string]$entry.Key)=[string]$entry.Value}
      $named=[ordered]@{
        vehicle_native_stale_frames_cancelled_exact=0
        vehicle_native_stale_bytes_cancelled_exact=0
        vehicle_native_stale_frames_filtered_exact=0
      }
      foreach($check in @($x.post_diagnostic_assessment.checks)){
        if($named.Contains([string]$check.name)){
          $check.expected=$named[[string]$check.name]
          $check.actual=$named[[string]$check.name]
        }
      }
    }),
    @('positive_single_stat_filter_without_gap',{param($x)
      $fields=$x.snapshots.post_vehicle.responses[0].fields
      foreach($entry in ([ordered]@{
          d722='937';sncf='0';sncb='0';snff='1';sncsf='0';sncsb='0';
          snfsf='1';snffm='0';snflm='0';snfmg='0'
        }).GetEnumerator()){$fields.([string]$entry.Key)=[string]$entry.Value}
      $named=[ordered]@{
        vehicle_native_stale_frames_cancelled_exact=0
        vehicle_native_stale_bytes_cancelled_exact=0
        vehicle_native_stale_frames_filtered_exact=1
      }
      foreach($check in @($x.post_diagnostic_assessment.checks)){
        if($named.Contains([string]$check.name)){
          $check.expected=$named[[string]$check.name]
          $check.actual=$named[[string]$check.name]
        }
      }
    }),
    @('positive_different_stat_counts',{param($x)
      $fields=$x.snapshots.post_vehicle.responses[0].fields
      foreach($entry in ([ordered]@{
          d722='944';sncf='3';sncb='111';snff='5';sncsf='3';sncsb='111';
          snfsf='5';snffm='100000';snflm='220000';snfmg='30000'
        }).GetEnumerator()){$fields.([string]$entry.Key)=[string]$entry.Value}
      $named=[ordered]@{
        vehicle_native_stale_frames_cancelled_exact=3
        vehicle_native_stale_bytes_cancelled_exact=111
        vehicle_native_stale_frames_filtered_exact=5
      }
      foreach($check in @($x.post_diagnostic_assessment.checks)){
        if($named.Contains([string]$check.name)){
          $check.expected=$named[[string]$check.name]
          $check.actual=$named[[string]$check.name]
        }
      }
    })
  )
  $expectedFirstFailed = [ordered]@{
    status_not_pass='summary_status_pass'
    intervention_not_requested='intervention_requested'
    request_written_twice='fixture_write_once'
    list_missing_index_931='param_list_last_index'
    heartbeat_gap_over_2500='heartbeat_maximum_gap_ms_within_2500'
    parser_bad_crc='parser_bad_crc_zero'
    fairness_ground_gap_at_hard_limit='fairness_ground_max_service_gap_ms_below_100'
    fairness_vehicle_fatal_error_nonempty='fairness_vehicle_fatal_error_null'
    fairness_vehicle_fatal_error_null_legacy='fairness_vehicle_fatal_error_null'
    native_path_normal='post_native_path_future'
    latch_received_index_wrong='recovery_latch_prlrx'
    future_counter_not_exact='recovery_delta_prfut'
    recovery_evidence_incomplete='post_recovery_evidence_complete'
    directed_exact_check_missing='directed_check_name_set_exact_17'
    directed_exact_count_not_17='expectation_exact_check_count'
    vehicle_snq_not_932='vehicle_native_strict_native_queued_932'
    vehicle_d7_crc_increased='vehicle_snapshot_absolute_d7cr_zero'
    vehicle_error_counters_preexisting='vehicle_snapshot_absolute_cc_zero'
    precommit_quarantine_nonzero='recovery_delta_ppre'
    legacy_R5_classification_fields_missing='vehicle_native_strict_classification_evidence_complete'
    native_sncb_not_37_times_sncf='vehicle_native_strict_cancel_byte_partition'
    native_d722_partition_mismatch='vehicle_native_strict_d722_partition'
    native_stqf_not_two='vehicle_native_strict_target_queued_two'
    native_stdone_not_two='vehicle_native_strict_target_completed_two'
    native_stdup_nonzero='vehicle_native_strict_target_duplicate_zero'
    native_target_duplicate_preexisting='vehicle_native_strict_target_duplicate_zero'
    native_snf_not_one='vehicle_native_strict_fence_once'
    named_native_fence_busy_object_nonzero='post_named_vehicle_native_fence_busy_zero'
    named_native_fence_busy_scalar_legacy='post_named_vehicle_native_fence_busy_zero'
    native_snbusy_nonzero='vehicle_native_strict_fence_busy_zero'
    native_fence_busy_preexisting='vehicle_native_strict_fence_busy_zero'
    native_aggregate_cancel_frame_partition_mismatch='vehicle_native_strict_cancel_frame_partition'
    native_aggregate_filter_frame_partition_mismatch='vehicle_native_strict_filter_frame_partition'
    native_snseq_nonzero='vehicle_native_strict_sequence_failures_zero'
    named_native_sequence_object_missing_delta='post_named_vehicle_native_sequence_failures_zero'
    native_sequence_failure_preexisting='vehicle_native_strict_sequence_failures_zero'
    native_cancel_frame_partition_mismatch='vehicle_native_strict_cancel_frame_partition'
    native_cancel_byte_partition_mismatch='vehicle_native_strict_cancel_byte_partition'
    native_filter_frame_partition_mismatch='vehicle_native_strict_filter_frame_partition'
    native_other_cancel_frame_nonzero='vehicle_native_strict_other_cancelled_frames_zero'
    native_other_cancel_frame_preexisting='vehicle_native_strict_other_cancelled_frames_zero'
    native_other_cancel_byte_nonzero='vehicle_native_strict_other_cancelled_bytes_zero'
    native_other_cancel_byte_preexisting='vehicle_native_strict_other_cancelled_bytes_zero'
    native_other_filter_frame_nonzero='vehicle_native_strict_other_filtered_frames_zero'
    native_other_filter_frame_preexisting='vehicle_native_strict_other_filtered_frames_zero'
    native_classification_error_nonzero='vehicle_native_strict_classification_errors_zero'
    native_classification_error_preexisting='vehicle_native_strict_classification_errors_zero'
    native_classification_counter_regression='vehicle_native_strict_classification_errors_zero'
    native_stat_filter_time_regression='vehicle_native_strict_filter_time_regressions_zero'
    native_stat_filter_time_regression_preexisting='vehicle_native_strict_filter_time_regressions_zero'
    native_stat_filter_first_after_last='vehicle_native_strict_stat_filter_cadence'
    native_stat_filter_minimum_gap_zero='vehicle_native_strict_stat_filter_cadence'
    native_stat_filter_minimum_gap_too_large='vehicle_native_strict_stat_filter_cadence'
    native_zero_filter_with_nonzero_cadence='vehicle_native_strict_stat_filter_cadence'
    native_single_filter_with_nonzero_gap='vehicle_native_strict_stat_filter_cadence'
    native_pre_unexpected_latch_nonzero='vehicle_native_strict_unexpected_latch_clean'
    native_unexpected_latch_changed='vehicle_native_strict_unexpected_latch_clean'
    native_unexpected_latch_payload_nonzero='vehicle_native_strict_unexpected_latch_clean'
    native_unexpected_latch_id_nonzero='vehicle_native_strict_unexpected_latch_clean'
  }
  $acceptedClassification = 'STRICT_NATIVE_CLASSIFICATION_ACCEPTED'
  $rejectedClassification = 'STRICT_NATIVE_CLASSIFICATION_REJECTED'
  $legacyClassification = 'INSUFFICIENT_LEGACY_CLASSIFICATION_EVIDENCE'
  $expectedClassification = [ordered]@{}
  foreach ($case in $negativeCases) {
    $expectedClassification[[string]$case[0]] = $acceptedClassification
  }
  foreach ($caseName in @(
      'vehicle_snq_not_932','native_sncb_not_37_times_sncf',
      'native_d722_partition_mismatch','native_stqf_not_two',
      'native_stdone_not_two','native_stdup_nonzero',
      'native_target_duplicate_preexisting','native_snf_not_one',
      'native_snbusy_nonzero','native_fence_busy_preexisting',
      'native_aggregate_cancel_frame_partition_mismatch',
      'native_aggregate_filter_frame_partition_mismatch',
      'native_snseq_nonzero','native_sequence_failure_preexisting',
      'native_cancel_frame_partition_mismatch',
      'native_cancel_byte_partition_mismatch',
      'native_filter_frame_partition_mismatch',
      'native_other_cancel_frame_nonzero','native_other_cancel_frame_preexisting',
      'native_other_cancel_byte_nonzero','native_other_cancel_byte_preexisting',
      'native_other_filter_frame_nonzero','native_other_filter_frame_preexisting',
      'native_classification_error_nonzero',
      'native_classification_error_preexisting',
      'native_classification_counter_regression',
      'native_stat_filter_time_regression',
      'native_stat_filter_time_regression_preexisting',
      'native_stat_filter_first_after_last',
      'native_stat_filter_minimum_gap_zero',
      'native_stat_filter_minimum_gap_too_large',
      'native_zero_filter_with_nonzero_cadence',
      'native_single_filter_with_nonzero_gap',
      'native_pre_unexpected_latch_nonzero','native_unexpected_latch_changed',
      'native_unexpected_latch_payload_nonzero',
      'native_unexpected_latch_id_nonzero')) {
    $expectedClassification[$caseName] = $rejectedClassification
  }
  $expectedClassification['legacy_R5_classification_fields_missing'] =
      $legacyClassification
  $expectedRelationFailure = [ordered]@{
    native_sncb_not_37_times_sncf='vehicle_native_strict_cancelled_size_37'
    native_d722_partition_mismatch='vehicle_native_strict_d722_partition'
    native_stqf_not_two='vehicle_native_strict_d722_partition'
    native_aggregate_cancel_frame_partition_mismatch='vehicle_native_strict_cancel_frame_partition'
    native_aggregate_filter_frame_partition_mismatch='vehicle_native_strict_filter_frame_partition'
    native_cancel_frame_partition_mismatch='vehicle_native_strict_cancel_frame_partition'
    native_cancel_byte_partition_mismatch='vehicle_native_strict_stat_cancelled_size_37'
    native_filter_frame_partition_mismatch='vehicle_native_strict_filter_frame_partition'
  }
  $caseResults = New-Object 'System.Collections.Generic.List[object]'
  [bool]$positiveCasePassed = ($positiveAssessment.valid -and
      [string]$positiveAssessment.native_classification -ceq
        $acceptedClassification)
  $caseResults.Add([pscustomobject][ordered]@{
    name='positive_exact_directed_summary';expected_valid=$true
    actual_valid=$positiveAssessment.valid
    first_failed=$positiveAssessment.first_failed
    expected_first_failed=$null;specific_failure_valid=$true
    expected_native_classification=$acceptedClassification
    native_classification=$positiveAssessment.native_classification
    classification_valid=([string]$positiveAssessment.native_classification -ceq
      $acceptedClassification)
    case_passed=$positiveCasePassed
    summary_file='fixtures/positive.json'
  })
  foreach ($case in $additionalPositiveCases) {
    $fixture = Copy-JsonObject $positive
    & $case[1] $fixture
    $safeName = [string]$case[0]
    $fixturePath = Join-Path $fixturesDirectory ("${safeName}.json")
    Write-JsonDurable $fixturePath $fixture
    $readback = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
    $assessment = Test-DirectedFutureSummary $readback
    [bool]$classificationValid =
        ([string]$assessment.native_classification -ceq $acceptedClassification)
    [bool]$casePassed = ($assessment.valid -and $classificationValid)
    $caseResults.Add([pscustomobject][ordered]@{
      name=$safeName;expected_valid=$true;actual_valid=$assessment.valid
      first_failed=$assessment.first_failed
      expected_first_failed=$null;specific_failure_valid=$true
      expected_relation_failed=$null;relation_failure_valid=$true
      expected_native_classification=$acceptedClassification
      native_classification=$assessment.native_classification
      classification_valid=$classificationValid;case_passed=$casePassed
      summary_file=("fixtures/${safeName}.json")
    })
  }
  foreach ($case in $negativeCases) {
    $fixture = Copy-JsonObject $positive
    & $case[1] $fixture
    $safeName = [string]$case[0]
    $fixturePath = Join-Path $fixturesDirectory ("negative_${safeName}.json")
    Write-JsonDurable $fixturePath $fixture
    $readback = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
    $assessment = Test-DirectedFutureSummary $readback
    [string]$expectedFailure = $expectedFirstFailed[$safeName]
    [string]$expectedNative = $expectedClassification[$safeName]
    [bool]$specificFailureValid = (@($assessment.checks | Where-Object {
        [string]$_.name -ceq $expectedFailure -and -not [bool]$_.passed
      }).Count -eq 1)
    [bool]$classificationValid =
        ([string]$assessment.native_classification -ceq $expectedNative)
    [string]$expectedRelation = if($expectedRelationFailure.Contains($safeName)){
      [string]$expectedRelationFailure[$safeName]
    }else{''}
    [bool]$relationFailureValid = ([string]::IsNullOrEmpty($expectedRelation) -or
        @($assessment.checks | Where-Object {
          [string]$_.name -ceq $expectedRelation -and -not [bool]$_.passed
        }).Count -eq 1)
    [bool]$casePassed = (-not $assessment.valid -and
        [string]$assessment.first_failed -ceq $expectedFailure -and
        $specificFailureValid -and $relationFailureValid -and
        $classificationValid)
    $caseResults.Add([pscustomobject][ordered]@{
      name=$safeName;expected_valid=$false;actual_valid=$assessment.valid
      first_failed=$assessment.first_failed
      expected_first_failed=$expectedFailure
      specific_failure_valid=$specificFailureValid
      expected_relation_failed=if([string]::IsNullOrEmpty($expectedRelation)){
        $null
      }else{$expectedRelation}
      relation_failure_valid=$relationFailureValid
      expected_native_classification=$expectedNative
      native_classification=$assessment.native_classification
      classification_valid=$classificationValid
      case_passed=$casePassed
      summary_file=("fixtures/negative_${safeName}.json")
    })
  }
  [object[]]$caseArray = $caseResults.ToArray()
  [bool]$selfTestValid =
      (@($caseArray | Where-Object {-not [bool]$_.case_passed}).Count -eq 0)
  Write-JsonDurable (Join-Path $OutputDirectory 'selftest_cases.json') $caseArray
  $selfSummary = [ordered]@{
    schema_version=1;test_id=$testId;mode='SELFTEST';modeled_offline=$true
    status=if($selfTestValid){'PASS'}else{'FAIL'}
    positive_check_count=$positiveAssessment.check_count
    positive_failed_count=$positiveAssessment.failed_count
    positive_case_count=(1 + $additionalPositiveCases.Count)
    negative_case_count=$negativeCases.Count
    failed_case_count=@($caseArray | Where-Object {
      -not [bool]$_.case_passed }).Count
    cases=$caseArray;checker_sha256=(Get-Sha256 $checkerPath)
    finished_utc=[DateTime]::UtcNow.ToString('o')
    external_actions=[ordered]@{
      serial_ports_opened=0;firmware_writes=0;network_calls=0
    }
    durability=[ordered]@{
      file_mode='CreateNew';file_options='WriteThrough';flush='Flush(true)'
    }
  }
  Write-JsonDurable (Join-Path $OutputDirectory 'summary.json') $selfSummary
  Write-ArtifactManifest $OutputDirectory
  Write-Output ("$($selfSummary.status) $testId SELFTEST " +
      "cases=$($caseArray.Count) output=$OutputDirectory")
  if ($selfTestValid) { exit 0 }
  exit 1
}

if ($FixtureMode -cne 'NONE') {
  if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
    throw '-FixtureMode creates its own input and cannot use -SummaryPath.'
  }
  $fixture = New-PositiveDirectedFixture
  if ($FixtureMode -ceq 'NEGATIVE') {
    $fixture.post_diagnostic_assessment.recovery_evidence.deltas.prgap.after = 102
    $fixture.post_diagnostic_assessment.recovery_evidence.deltas.prgap.delta = 2
  }
  $SummaryPath = Join-Path $OutputDirectory `
      $(if($FixtureMode -ceq 'POSITIVE'){
        'fixture_positive.json'
      }else{'fixture_negative.json'})
  Write-JsonDurable $SummaryPath $fixture
}

if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
  throw '-SummaryPath is required unless -SelfTest or -FixtureMode is used.'
}
$SummaryPath = [System.IO.Path]::GetFullPath($SummaryPath)
if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) {
  throw "Directed HIL summary is missing: $SummaryPath"
}

$inputSummary = Get-Content -Raw -LiteralPath $SummaryPath | ConvertFrom-Json
$assessment = Test-DirectedFutureSummary $inputSummary
[string]$failureClassification = if($assessment.valid){
  ''
} elseif([string]$assessment.native_classification -ceq
    'INSUFFICIENT_LEGACY_CLASSIFICATION_EVIDENCE') {
  'INSUFFICIENT_LEGACY_CLASSIFICATION_EVIDENCE'
} elseif([string]$assessment.native_classification -ceq
    'STRICT_NATIVE_CLASSIFICATION_REJECTED') {
  'STRICT_NATIVE_CLASSIFICATION_REJECTED'
} else {
  'SUMMARY_VALIDATION_FAILED'
}
$checkerSummary = [ordered]@{
  schema_version=1;test_id=$testId;mode=if($FixtureMode -ceq 'NONE'){
    'SUMMARY'
  }else{'FIXTURE_' + $FixtureMode}
  status=if($assessment.valid){'PASS'}else{'FAIL'}
  input_summary_path=$SummaryPath
  input_summary_sha256=(Get-Sha256 $SummaryPath)
  modeled_offline=($FixtureMode -cne 'NONE')
  native_classification=$assessment.native_classification
  failure_classification=if([string]::IsNullOrEmpty($failureClassification)){
    $null
  }else{$failureClassification}
  validation=$assessment
  checker_sha256=(Get-Sha256 $checkerPath)
  finished_utc=[DateTime]::UtcNow.ToString('o')
  external_actions=[ordered]@{
    serial_ports_opened=0;firmware_writes=0;network_calls=0
  }
  durability=[ordered]@{
    file_mode='CreateNew';file_options='WriteThrough';flush='Flush(true)'
  }
}
Write-JsonDurable (Join-Path $OutputDirectory 'summary.json') $checkerSummary
Write-ArtifactManifest $OutputDirectory
Write-Output ("$($checkerSummary.status) $testId " +
    "checks=$($assessment.check_count) failed=$($assessment.failed_count) " +
    "classification=$($assessment.native_classification) " +
    "output=$OutputDirectory")
if ($assessment.valid) { exit 0 }
exit 1
