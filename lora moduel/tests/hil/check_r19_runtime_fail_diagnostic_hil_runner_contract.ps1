[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
$runner = Join-Path $repo 'tools\run_r19_runtime_fail_diagnostic_hil.ps1'

function Assert-Condition([bool]$Condition,[string]$Message) {
  if (-not $Condition) {throw $Message}
}

function Get-Sha([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

Assert-Condition (Test-Path -LiteralPath $runner -PathType Leaf) `
    "R19 dual-COM diagnostic runner is missing: $runner"
$tokens = $null;$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $runner,[ref]$tokens,[ref]$errors)
Assert-Condition (@($errors).Count -eq 0) `
    ('R19 diagnostic runner parse errors: ' + (@($errors) -join '; '))
$source = [IO.File]::ReadAllText($runner)
foreach ($required in @(
    'R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001',
    'vc-lora-r19-runtime-fail-diagnostic-summary-v1',
    "VehiclePort = 'COM3'", "GroundPort = 'COM6'",
    'CandidateHandoffPath','CandidateFlashEvidencePath',
    '[int]$CaptureSeconds = 40','baud=115200','baud=57600',
    'USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000',
    'USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000',
    'DtrEnable = $false','RtsEnable = $false',
    'PumpServiceLimitUs = [int64]100000',
    'R19F:', 'R19A:', 'FAIL_INVALID_RUNTIME_DIAGNOSTIC',
    'FAIL_NO_DIAGNOSTIC_BEACON','FAIL_ALIVE_NO_PRODUCT_TRAFFIC',
    "classification='NO_BEACON'","classification='ALIVE_NO_TRAFFIC'",
    "classification='ALIVE_WITH_PRODUCT_TRAFFIC'",
    "classification='R19F'",'PASS_DIAGNOSTIC_CAPTURED',
    'PASS_ALIVE_BEACON_CAPTURED','PARTIAL_ALIVE_NO_PRODUCT_TRAFFIC',
    'diagnostic_only=$true',
    'acceptance_eligible=$false','acceptance_authorized=$false',
    'deployment_authorized=$false',
    'PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY',
    'one immediate R19 runtime-fail diagnostic capture only',
    'Run one dual-COM read-only runtime-fail diagnostic capture, then mandatory accepted R18 rollback',
    'R19_RUNTIME_FAIL_DIAGNOSTIC_HIL_ONE_RUN_NOT_ACCEPTANCE_NOT_DEPLOYMENT',
    'candidate.latest.json','candidate.latest.sha256',
    'flash.final_seal.sha256',
    'core.mavlink_frame.cpp','FAIL_PARSER_CORRUPTION',
    'FAIL_INVALID_R19F_REPEAT','noise_bytes','partial_bytes',
    'r19f_repeat_contract','parser_clean',
    'Get-DiagnosticFrameLeaf','OfflineCaptureFailureProbe',
    'serial_write_calls=0',
    'serial_port_open_before_utc','serial_port_open_after_utc',
    'serial_port_open_duration_ms',
    'serial_port_open_utc_evidence_success',
    'serial_port_open_utc_evidence_failure',
    'TerminalTailDrainLimitUs = [int64]500000',
    'Add-DiagnosticStateFrames','Invoke-DiagnosticExactTailDrain',
    'Get-TerminalPartialContract','terminal_partial_contract',
    'R19F_TERMINAL_PREFIX_STALL','FAIL_R19F_TERMINAL_PREFIX_STALL',
    'TIMEOUT_INCOMPLETE_SAME_FRAME','read_batch_id','STARTUP_DRAIN',
    'initial_drain_bytes','initial_drain_remaining',
    'one_role_only','prior_r19f_count','only_parser_defect',
    'terminal_offset_plus_length_equals_raw_bytes',
    'all_other_parser_counters_zero',
    'byte_exact_expected_next_r19f_prefix',
    'failure_snapshot_matches_previous','no_read_exception',
    'last_progress_before_tail_us',
    'age_since_last_progress_before_tail_us',
    'r19a_terminal_partial_contract',
    'R19A_TERMINAL_PREFIX_STALL','FAIL_R19A_TERMINAL_PREFIX_STALL')) {
  Assert-Condition ($source.Contains($required)) `
      "R19 diagnostic runner contract token is missing: $required"
}

$measurementFunctions = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -in @('New-DiagnosticSerialPort','Open-DiagnosticSerialPort',
        'Read-DiagnosticSerial','Add-DiagnosticStateFrames',
        'Invoke-DiagnosticExactTailDrain',
        'Invoke-R19RuntimeFailDiagnosticCapture')
},$true))
$measurementText = ($measurementFunctions | ForEach-Object {$_.Extent.Text}) `
    -join [Environment]::NewLine
$aliveOrderFunction = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Test-R19AliveMonotonic'
},$true))[0]
Assert-Condition ($aliveOrderFunction.Extent.Text -notmatch
      'Sort-Object\s+complete_us') `
    'R19A monotonic validation must preserve parser arrival order on equal timestamps.'
Assert-Condition ($measurementText -notmatch '\$Serial\.Write\s*\(' -and
    $measurementText -notmatch '\$Serial\.BaseStream\.Write\s*\(' -and
    $measurementText -notmatch 'DiscardInBuffer|DiscardOutBuffer') `
    'Diagnostic serial path contains a write/discard operation.'
$captureFunction = @($measurementFunctions | Where-Object {
    $_.Name -ceq 'Invoke-R19RuntimeFailDiagnosticCapture'})[0]
$captureText = $captureFunction.Extent.Text
$readFunction = @($measurementFunctions | Where-Object {
    $_.Name -ceq 'Read-DiagnosticSerial'})[0]
$readText = $readFunction.Extent.Text
$openFunction = @($measurementFunctions | Where-Object {
    $_.Name -ceq 'Open-DiagnosticSerialPort'})[0]
Assert-Condition ($null -ne $openFunction) `
    'The measured SerialPort.Open wrapper is missing.'
$openText = $openFunction.Extent.Text
$openCall = $openText.IndexOf('$Serial.Open()',
    [StringComparison]::Ordinal)
$beforeStamp = $openText.IndexOf('serial_port_open_before_utc',
    [StringComparison]::Ordinal)
$afterStamp = $openText.IndexOf('serial_port_open_after_utc',
    [StringComparison]::Ordinal)
Assert-Condition ($beforeStamp -ge 0 -and $openCall -gt $beforeStamp -and
    $afterStamp -gt $openCall -and
    $openText -match '\[DateTime\]::UtcNow' -and
    $openText -match 'serial_port_open_duration_ms') `
    'Exact UTC evidence does not bracket the measured SerialPort.Open call.'
Assert-Condition ($readText -match '\[IO\.MemoryStream\]\$Raw' -and
    $readText -notmatch '\[IO\.Stream\]\$Raw' -and
    $captureText -match '\$raw\s*=\s*\[IO\.MemoryStream\]::new\(\)') `
    'Live Raw capture is not concretely constrained to a deferred MemoryStream.'
$offlineFunction = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Invoke-OfflineSelfTest'
},$true))[0]
$offlineText = $offlineFunction.Extent.Text
Assert-Condition ($offlineText -match 'New-OfflineBufferedSerial' -and
    $offlineText -match 'Read-DiagnosticSerial' -and
    $offlineText -match 'PumpReadBudgetBytes' -and
    $offlineText -match 'dual_port_buffered_pump_load_fairness' -and
    $offlineText -notmatch '\$fakeService') `
    'Offline fairness proof does not drive the production pump under load.'
$captureStart = $captureText.IndexOf('$clock.Start()',
    [StringComparison]::Ordinal)
$captureStop = $captureText.IndexOf('$clock.Stop()',
    [StringComparison]::Ordinal)
Assert-Condition ($captureStart -ge 0 -and $captureStop -gt $captureStart) `
    'Diagnostic capture clock boundaries are missing or reversed.'
$timedCaptureText = $captureText.Substring($captureStart,
    $captureStop - $captureStart)
Assert-Condition ($timedCaptureText -notmatch 'Write-DurableBytes|' +
      '\[IO\.FileStream\]|FileOptions\]::WriteThrough|Flush\s*\(\s*\$true') `
    'Timed dual-COM capture performs synchronous durable file I/O.'
Assert-Condition ($measurementText -match
      '\$leaf\s*=\s*Get-DiagnosticFrameLeaf' -and
    $measurementText -notmatch
      '\{1:D6\}\.bin[^\r\n]*-f[^\r\n]*\$state\.cursor\s*-\s*1') `
    'Live diagnostic capture does not use the tested ordinal filename helper.'
Assert-Condition ($source -notmatch 'Invoke-RestMethod|Invoke-WebRequest|' +
    'System\.Net\.Http|WebClient') `
    'Diagnostic runner must not contain an API/network path.'
$pinCall = $source.LastIndexOf(
    '$provenance=Get-CandidateProvenance',
    [StringComparison]::Ordinal)
$captureCall = $source.LastIndexOf(
    '$summary=Invoke-R19RuntimeFailDiagnosticCapture',
    [StringComparison]::Ordinal)
Assert-Condition ($pinCall -ge 0 -and $captureCall -gt $pinCall) `
    'Diagnostic inputs are not pinned and validated before COM capture.'

# Replay the immutable failing capture, not a fabricated complete diagnostic.
# Source provenance comes from that capture; no hardware/API calls are made.
foreach($functionName in @('Get-ByteSha','Update-X25Crc',
    'Get-MavlinkDefinitions','New-DiagnosticParser','Add-DiagnosticBytes',
    'Get-SourceBinding','Convert-R19Diagnostic','Test-ExactBytePrefix',
    'Get-R19AliveTerminalPartialContract','Get-R19DiagnosticClassification')){
  $matches=@($ast.FindAll({param($node)
    $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
      $node.Name-ceq$functionName},$true))
  Assert-Condition ($matches.Count-eq1) `
      "Recorded-prefix replay function absent or ambiguous: $functionName"
  . ([scriptblock]::Create($matches[0].Extent.Text))
}
$script:Definitions=Get-MavlinkDefinitions (Join-Path $repo `
    'core\src\mavlink_frame.cpp')
$r19Pattern='^R19F:(?<role>[GV]):(?<line>[0-9A-F]{4}):'+
    '(?<time>[0-9A-F]{16}):(?<status>[0-9A-F]{12}):(?<epoch>[0-9A-F]{8})$'
$r19AlivePattern='^R19A:(?<role>[GV]):(?<state>[AL]):'+
    '(?<ordinal>[0-9A-F]{8}):(?<time>[0-9A-F]{16}):'+
    '(?<status>[0-9A-F]{12})\x00{3}$'
$recordedCapture=Join-Path $repo ('runs\hil\'+
    'R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001\'+
    '20261018T161748244Z-13604e50\capture')
$recordedSummary=Get-Content -LiteralPath (Join-Path $recordedCapture `
    'summary.json') -Raw | ConvertFrom-Json
Assert-Condition ((Get-Sha (Join-Path $recordedCapture 'ground.raw.bin'))-ceq
    '889DCA240FA7424DF7B7E489D96161E283A08BEF1A9ECCB25E9C715329741136'-and
    (Get-Sha (Join-Path $recordedCapture 'vehicle.raw.bin'))-ceq
    '80EFBFE58C76B4D3237EA88C35F71F9DC465C9B0667F9224B2D71D17352F3E3F') `
    'Recorded terminal-prefix replay bytes changed.'
function New-RecordedPrefixReplayStates([scriptblock]$GroundMutation=$null){
  $states=@()
  foreach($role in @('vehicle','ground')){
    $roleSummary=@($recordedSummary.ports|Where-Object{$_.role-ceq$role})[0]
    [byte[]]$bytes=[IO.File]::ReadAllBytes((Join-Path $recordedCapture `
        ($role+'.raw.bin')))
    if($role-ceq'ground'-and$null-ne$GroundMutation){& $GroundMutation $bytes}
    $parser=New-DiagnosticParser $role
    Add-DiagnosticBytes $parser $bytes 40000000
    $raw=[IO.MemoryStream]::new()
    $raw.Write($bytes,0,$bytes.Length)
    $diagnostics=[Collections.ArrayList]::new()
    $code=if($role-ceq'ground'){'G'}else{'V'}
    foreach($frame in $parser.frames){
      $decoded=Convert-R19Diagnostic $frame $code `
          $recordedSummary.candidate_provenance
      if($decoded.candidate){[void]$diagnostics.Add($decoded)}
    }
    $states+=,[pscustomobject]@{spec=[pscustomobject]@{
      role=$role;port=if($role-ceq'ground'){'COM6'}else{'COM3'}}
      parser=$parser;raw=$raw;diagnostics=$diagnostics
      tail_drain=$roleSummary.tail_drain}
  }
  return $states
}
function Close-RecordedPrefixReplayStates([object[]]$States){
  foreach($state in $States){$state.raw.Dispose()}
}
$replayStates=New-RecordedPrefixReplayStates
try{
  $replayContract=Get-R19AliveTerminalPartialContract $replayStates $true
  $replayDiagnostics=@($replayStates|ForEach-Object{@($_.diagnostics)})
  $replayClassification=Get-R19DiagnosticClassification `
      $replayDiagnostics 7 $true $false $true $null $replayContract
  Assert-Condition ([bool]$replayContract.valid-and
      [bool]$replayContract.fail_only-and
      -not[bool]$replayContract.reconstruction_performed-and
      -not[bool]$replayContract.missing_crc_verified-and
      [int]$replayContract.partial_bytes-eq32-and
      [int]$replayContract.remaining-eq31-and
      [int]$replayContract.prior_alive_count-eq10-and
      [int64]$replayContract.raw_offset-eq777-and
      [int64]$replayContract.raw_bytes-eq809-and
      [string]$replayContract.raw_sha256-ceq
        '889DCA240FA7424DF7B7E489D96161E283A08BEF1A9ECCB25E9C715329741136'-and
      [string]$replayClassification.result-ceq'FAIL'-and
      [string]$replayClassification.classification-ceq
        'R19A_TERMINAL_PREFIX_STALL'-and
      [string]$replayClassification.status-ceq'FAIL_R19A_TERMINAL_PREFIX_STALL'-and
      [int]$replayStates[1].parser.partial_bytes-eq32-and
      [int]$replayStates[1].parser.frames.Count-eq17) `
      'Recorded Ground 32/63 replay was not fail-only or fabricated a complete frame.'
}finally{Close-RecordedPrefixReplayStates $replayStates}
$recordedPrefixMutations=@(
  [pscustomobject]@{name='wrong_sequence';apply={param($b)$b[781]=11}},
  [pscustomobject]@{name='unknown_message';apply={param($b)$b[784]=252}},
  [pscustomobject]@{name='wrong_role';apply={param($b)$b[793]=[byte][char]'V'}},
  [pscustomobject]@{name='wrong_state';apply={param($b)$b[795]=[byte][char]'A'}},
  [pscustomobject]@{name='stale_ordinal';apply={param($b)$b[802]=[byte][char]'B'}},
  [pscustomobject]@{name='mixed_failure_prefix';apply={param($b)$b[791]=[byte][char]'F'}},
  [pscustomobject]@{name='invalid_time_prefix';apply={param($b)$b[806]=[byte][char]'Z'}},
  [pscustomobject]@{name='prior_crc_corrupt';apply={param($b)$b[61]=$b[61]-bxor1}}
)
foreach($mutation in $recordedPrefixMutations){
  $states=New-RecordedPrefixReplayStates $mutation.apply
  try{
    $contract=Get-R19AliveTerminalPartialContract $states $true
    Assert-Condition (-not[bool]$contract.valid) `
        "Recorded terminal-prefix mutation was admitted: $($mutation.name)"
  }finally{Close-RecordedPrefixReplayStates $states}
}
Write-Output 'Recorded R19A replay PASS: unchanged 809/2709 bytes; 32-byte prefix remains incomplete; 8 mutations rejected.'

# This separate fail-only contract must not weaken the existing clean-prefix
# contract. The recorded stream begins inside one R19F and ends inside another.
$boundaryFunction=@($ast.FindAll({param($node)
  $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
    $node.Name-ceq'Get-R19FailureBoundaryPartialContract'},$true))
Assert-Condition ($boundaryFunction.Count-eq1) `
    'R19F capture-boundary partial cause contract is missing.'
. ([scriptblock]::Create($boundaryFunction[0].Extent.Text))
foreach($functionName in @('Get-ExpectedNextR19FailureFrame',
    'Get-R19FailureSnapshotKey','Test-DiagnosticParserClean')){
  $matches=@($ast.FindAll({param($node)
    $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
      $node.Name-ceq$functionName},$true))
  Assert-Condition ($matches.Count-eq1) "Missing boundary dependency: $functionName"
  . ([scriptblock]::Create($matches[0].Extent.Text))
}
$boundaryCapture=Join-Path $repo ('runs\hil\'+
    'R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001\'+
    '20261018T171157707Z-e0e2304d\capture')
$boundarySummary=Get-Content -LiteralPath (Join-Path $boundaryCapture `
    'summary.json') -Raw | ConvertFrom-Json
Assert-Condition ((Get-Sha (Join-Path $boundaryCapture 'ground.raw.bin'))-ceq
    '8DD5417C6309A4003760D30FDFC17EBB1FE07BAB01A311CE2E359DAB15C271A7'-and
    (Get-Sha (Join-Path $boundaryCapture 'vehicle.raw.bin'))-ceq
    '6740EB36ADA929A34A86C43CB6F02F3C492EFFE132A10E83AF96EF190FBC77B2') `
    'Recorded R19F capture-boundary bytes changed.'
function New-RecordedFailureBoundaryStates([scriptblock]$Mutation=$null){
  $states=@()
  foreach($role in @('vehicle','ground')){
    $row=@($boundarySummary.ports|Where-Object{$_.role-ceq$role})[0]
    [byte[]]$bytes=[IO.File]::ReadAllBytes((Join-Path $boundaryCapture `
        ($role+'.raw.bin')))
    $provenance=$boundarySummary.candidate_provenance|ConvertTo-Json -Depth 20|
        ConvertFrom-Json
    if($null-ne$Mutation){& $Mutation $role $bytes $provenance}
    $parser=New-DiagnosticParser $role
    Add-DiagnosticBytes $parser $bytes 40000000
    $raw=[IO.MemoryStream]::new();$raw.Write($bytes,0,$bytes.Length)
    $diagnostics=[Collections.ArrayList]::new()
    foreach($frame in $parser.frames){
      $decoded=Convert-R19Diagnostic $frame `
          $(if($role-ceq'ground'){'G'}else{'V'}) $provenance
      if($decoded.candidate){[void]$diagnostics.Add($decoded)}
    }
    $states+=,[pscustomobject]@{spec=[pscustomobject]@{
        role=$role;port=if($role-ceq'ground'){'COM6'}else{'COM3'}}
      parser=$parser;raw=$raw;diagnostics=$diagnostics
      tail_drain=($row.tail_drain|ConvertTo-Json -Depth 10|ConvertFrom-Json)}
  }
  return $states
}
$states=New-RecordedFailureBoundaryStates
try{
  $contract=Get-R19FailureBoundaryPartialContract $states $true
  $classification=Get-R19DiagnosticClassification `
      @($states|ForEach-Object{@($_.diagnostics)}) 0 $true $false $true `
      $null $null $contract
  Assert-Condition ([bool]$contract.valid-and[bool]$contract.fail_only-and
      -not[bool]$contract.reconstruction_performed-and
      -not[bool]$contract.missing_prefix_received-and
      -not[bool]$contract.missing_terminal_crc_verified-and
      [int]$contract.leading_bytes-eq31-and
      [int]$contract.leading_prior_sequence-eq2-and
      [bool]$contract.leading_sequence_unique-and
      [bool]$contract.leading_suffix_exact-and
      [int]$contract.prior_r19f_count-eq6-and
      [int]$contract.terminal_partial_bytes-eq32-and
      [int64]$contract.terminal_raw_offset-eq409-and
      [int]$contract.terminal_sequence-eq9-and
      [int64]$contract.raw_bytes-eq441-and
      [string]$contract.raw_sha256-ceq
        '8DD5417C6309A4003760D30FDFC17EBB1FE07BAB01A311CE2E359DAB15C271A7'-and
      [int]$states[1].parser.noise_bytes-eq31-and
      [int]$states[1].parser.partial_bytes-eq32-and
      [int]$states[1].parser.frames.Count-eq6-and
      [string]$classification.result-ceq'FAIL'-and
      [string]$classification.classification-ceq'R19F_CAPTURE_BOUNDARY_PARTIAL'-and
      [string]$classification.status-ceq'FAIL_R19F_CAPTURE_BOUNDARY_PARTIAL') `
      'Recorded R19F boundary replay was not admitted strictly fail-only.'
  # Independent all-sequence CRC proof; this is derived expected data, never
  # fabricated reception of the missing first 32 bytes.
  [byte[]]$bytes=$states[1].raw.ToArray();$matchingSequences=@()
  for($sequence=0;$sequence-le255;++$sequence){
    [byte[]]$derived=$bytes[31..93];$derived[4]=[byte]$sequence
    [uint16]$crc=0xffff
    for($offset=1;$offset-lt61;++$offset){
      $crc=Update-X25Crc $crc $derived[$offset]}
    $crc=Update-X25Crc $crc 83
    $derived[61]=[byte]($crc-band255)
    $derived[62]=[byte](($crc-shr8)-band255)
    if(Test-ExactBytePrefix ([byte[]]$bytes[0..30]) `
        ([byte[]]$derived[32..62])){$matchingSequences+=,$sequence}
  }
  Assert-Condition ($matchingSequences.Count-eq1-and
      [int]$matchingSequences[0]-eq2) `
      'Recorded leading suffix does not uniquely match the preceding sequence.'
}finally{Close-RecordedPrefixReplayStates $states}
$boundaryMutations=@(
  [pscustomobject]@{name='leading_unknown_noise';apply={param($r,$b,$p)
    if($r-ceq'ground'){$b[0]=$b[0]-bxor1}}},
  [pscustomobject]@{name='leading_crc';apply={param($r,$b,$p)
    if($r-ceq'ground'){$b[30]=$b[30]-bxor1}}},
  [pscustomobject]@{name='complete_crc';apply={param($r,$b,$p)
    if($r-ceq'ground'){$b[92]=$b[92]-bxor1}}},
  [pscustomobject]@{name='complete_sequence';apply={param($r,$b,$p)
    if($r-ceq'ground'){$b[98]=17}}},
  [pscustomobject]@{name='terminal_sequence';apply={param($r,$b,$p)
    if($r-ceq'ground'){$b[413]=8}}},
  [pscustomobject]@{name='terminal_role';apply={param($r,$b,$p)
    if($r-ceq'ground'){$b[425]=[byte][char]'V'}}},
  [pscustomobject]@{name='terminal_unknown_message';apply={param($r,$b,$p)
    if($r-ceq'ground'){$b[416]=252}}},
  [pscustomobject]@{name='vehicle_crc';apply={param($r,$b,$p)
    if($r-ceq'vehicle'){$b[61]=$b[61]-bxor1}}},
  [pscustomobject]@{name='source_hash';apply={param($r,$b,$p)
    if($r-ceq'ground'){$p.source_bindings[1].source_sha256='0'*64}}}
)
foreach($mutation in $boundaryMutations){
  $states=New-RecordedFailureBoundaryStates $mutation.apply
  try{
    Assert-Condition (-not[bool](Get-R19FailureBoundaryPartialContract `
        $states $true).valid) `
        "Recorded R19F boundary mutation admitted: $($mutation.name)"
  }finally{Close-RecordedPrefixReplayStates $states}
}
foreach($mutation in @('tail_read_exception','tail_progress','wrong_port',
    'source_mapping','capture_invalid')){
  $states=New-RecordedFailureBoundaryStates
  try{
    switch($mutation){
      'tail_read_exception'{$states[1].tail_drain.no_read_exception=$false}
      'tail_progress'{$states[1].tail_drain.bytes_read=1}
      'wrong_port'{$states[1].spec.port='COM3'}
      'source_mapping'{$states[1].diagnostics[0].source_mapping_verified=$false}
    }
    Assert-Condition (-not[bool](Get-R19FailureBoundaryPartialContract `
        $states ($mutation-cne'capture_invalid')).valid) `
        "Recorded R19F boundary metadata mutation admitted: $mutation"
  }finally{Close-RecordedPrefixReplayStates $states}
}
Write-Output 'Recorded R19F boundary replay PASS: unchanged 441/2646 bytes; leading31 uniquely seq2 CRC-derived; terminal32 remains incomplete; 14 unsafe mutations rejected.'

$output = Join-Path $repo ('runs\validation\' +
    'R19-RUNTIME-FAIL-DIAGNOSTIC-RUNNER-CONTRACT-001\' +
    [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' +
    [Guid]::NewGuid().ToString('N').Substring(0,8))
& $runner -OfflineSelfTest -RepoRoot $repo -OutputDirectory $output
Assert-Condition ($LASTEXITCODE -eq 0) `
    "R19 diagnostic offline self-test exited $LASTEXITCODE"
$summaryPath = Join-Path $output 'summary.json'
Assert-Condition (Test-Path -LiteralPath $summaryPath -PathType Leaf) `
    'R19 diagnostic offline summary is missing.'
$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
Assert-Condition ([string]$summary.schema -ceq
      'vc-lora-r19-runtime-fail-diagnostic-summary-v1' -and
    [string]$summary.result -ceq 'PASS' -and
    [string]$summary.mode -ceq 'OFFLINE_SELF_TEST' -and
    -not [bool]$summary.hardware_interaction -and
    [bool]$summary.diagnostic_only -and
    -not [bool]$summary.acceptance_eligible -and
    -not [bool]$summary.acceptance_authorized -and
    -not [bool]$summary.deployment_authorized -and
    [int]$summary.serial_write_calls -eq 0 -and
    -not [bool]$summary.external_actions.com_ports_opened -and
    -not [bool]$summary.external_actions.cim_queried -and
    -not [bool]$summary.external_actions.pnp_queried -and
    -not [bool]$summary.external_actions.process_inventory_queried -and
    -not [bool]$summary.external_actions.firmware_write_attempted -and
    -not [bool]$summary.external_actions.e220_write_attempted -and
    @($summary.external_actions.opened_ports).Count -eq 0 -and
    @($summary.external_actions.serial_port_open_evidence).Count -eq 0) `
    'R19 diagnostic offline safety/result contract failed.'
Assert-Condition ([int]$summary.canonical_wire.r19f.severity -eq 2 -and
    [int]$summary.canonical_wire.r19f.text_length -eq 50 -and
    [int]$summary.canonical_wire.r19a.severity -eq 6 -and
    [int]$summary.canonical_wire.r19a.text_length -eq 47 -and
    [int]$summary.canonical_wire.r19a.trailing_nul_bytes -eq 3 -and
    [int]$summary.canonical_wire.r19a.payload_length -eq 51 -and
    [int]$summary.canonical_wire.r19a.wire_length -eq 63) `
    'R19F/R19A canonical wire contract is not exact.'
$testNames = @($summary.tests | Where-Object {$_.result -ceq 'PASS'} |
    ForEach-Object {[string]$_.name})
foreach ($name in @('dual_port_read_only_zero_write',
    'dual_port_100ms_fairness','valid_ground_r19f_decode',
    'valid_vehicle_r19f_decode','bad_crc_not_success',
    'valid_ground_r19a_armed_decode','valid_ground_r19a_alive_decode',
    'valid_vehicle_r19a_armed_decode','valid_vehicle_r19a_alive_decode',
    'r19a_bad_crc_not_success','r19a_bad_padding_not_success',
    'r19a_wrong_severity_not_success','r19a_role_mismatch_not_success',
    'r19a_source_hash_mismatch_not_success','r19a_sequence_time_monotonic',
    'r19a_same_read_capture_order_monotonic',
    'dual_port_buffered_pump_load_fairness',
    'deferred_capture_evidence_complete_after_close',
    'capture_cleanup_zero_error_array_contract',
    'classification_no_beacon','classification_alive_no_traffic',
    'classification_alive_with_product_traffic',
    'classification_partial_alive_role','classification_invalid_precedence',
    'classification_armed_only_no_beacon','classification_r19f',
    'valid_non_diagnostic_crc_counted_as_product_traffic',
    'bad_crc_non_diagnostic_not_product_traffic',
    'parser_noise_strict_failure','parser_partial_strict_failure',
    'r19f_repeat_exact_snapshot','r19f_repeat_mutation_rejected',
    'r19f_repeat_sequence_may_advance',
    'r19f_repeat_count_bound','r19f_repeat_cadence_sanity',
    'serial_read_batch_identity_preserved',
    'startup_drain_uses_one_time_byte_snapshot',
    'r19f_startup_coalescing_cadence_unobservable',
    'r19f_startup_spanning_frame_cadence_unobservable',
    'r19f_live_coalescing_still_rejected',
    'r19f_repeat_sequence_contiguous_modulo_256',
    'terminal_exact_tail_drain_one_frame',
    'terminal_incomplete_tail_preserves_failure',
    'terminal_bad_crc_preserves_failure',
    'terminal_expected_next_frame_derivation',
    'terminal_read_exception_distinct_failure',
    'r19a_terminal_ground_32_prefix_cause_only',
    'r19a_terminal_prefix_mutations_rejected',
    'r19a_terminal_prefix_never_complete_or_acceptance',
    'serial_port_open_utc_evidence_success',
    'serial_port_open_utc_evidence_failure',
    'diagnostic_frame_filename_ordinal_contract',
    'source_hash_mismatch_not_success','source_line_zero_not_success',
    'diagnostic_chain_latest_and_inputs_pinned',
    'diagnostic_artifact_chain_requires_true',
    'diagnostic_scope_status_contract','flash_readback_binding_contract',
    'role_baud_contract')) {
  Assert-Condition ($testNames -ccontains $name) `
      "R19 diagnostic offline proof missing: $name"
}
$pumpLoadProof = @($summary.tests | Where-Object {
    [string]$_.name -ceq 'dual_port_buffered_pump_load_fairness'})
Assert-Condition ($pumpLoadProof.Count -eq 1 -and
    [string]$pumpLoadProof[0].detail -match 'not a hardware timing proof' -and
    [string]$pumpLoadProof[0].detail -match 'live capture measures') `
    'Synthetic pump fairness is not clearly scoped as an offline-only proof.'
Assert-Condition ((Test-Path -LiteralPath (Join-Path $output `
        'offline_raw\ground.r19f.bin') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $output `
        'offline_raw\vehicle.r19f.bin') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $output `
        'offline_raw\ground.r19a-armed.bin') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $output `
        'offline_raw\ground.r19a-alive.bin') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $output `
        'offline_raw\vehicle.r19a-armed.bin') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $output `
        'offline_raw\vehicle.r19a-alive.bin') -PathType Leaf)) `
    'R19 diagnostic offline raw-frame evidence is missing.'
foreach ($leaf in @('offline_raw\vehicle.frame-000001.bin',
    'offline_raw\ground.frame-000001.bin')) {
  $path = Join-Path $output $leaf
  Assert-Condition ((Test-Path -LiteralPath $path -PathType Leaf) -and
      (Get-Item -LiteralPath $path).Length -eq 63) `
      "R19 live-shape frame filename regression artifact is missing: $leaf"
}
$manifestPath = Join-Path $output 'artifact_manifest.json'
$sumsPath = Join-Path $output 'SHA256SUMS.txt'
$sealPath = Join-Path $output 'final_seal.json'
$sealSidecarPath = Join-Path $output 'final_seal.sha256'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$seal = Get-Content -LiteralPath $sealPath -Raw | ConvertFrom-Json
Assert-Condition ([string]$seal.result -ceq 'PASS' -and
    [bool]$seal.diagnostic_only -and
    -not [bool]$seal.acceptance_eligible -and
    -not [bool]$seal.acceptance_authorized -and
    -not [bool]$seal.deployment_authorized -and
    [string]$seal.summary_sha256 -ceq (Get-Sha $summaryPath) -and
    [string]$seal.artifact_manifest_sha256 -ceq (Get-Sha $manifestPath) -and
    [string]$seal.sha256sums_sha256 -ceq (Get-Sha $sumsPath)) `
    'R19 diagnostic offline final seal did not verify.'
Assert-Condition ((Test-Path -LiteralPath $sealSidecarPath -PathType Leaf) -and
    ([IO.File]::ReadAllText($sealSidecarPath).Trim() -ceq
      ((Get-Sha $sealPath) + ' *final_seal.json'))) `
    'R19 diagnostic final-seal SHA-256 sidecar is missing or invalid.'
foreach ($artifact in @($manifest.artifacts)) {
  $path = [IO.Path]::GetFullPath((Join-Path $output `
      ([string]$artifact.path).Replace('/','\')))
  Assert-Condition ($path.StartsWith($output+'\',
      [StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $path -PathType Leaf) -and
      (Get-Item -LiteralPath $path).Length -eq [int64]$artifact.bytes -and
      (Get-Sha $path) -ceq [string]$artifact.sha256) `
      "R19 diagnostic artifact did not verify: $($artifact.path)"
}

$failureOutput = Join-Path $repo ('runs\validation\' +
    'R19-RUNTIME-FAIL-DIAGNOSTIC-RUNNER-CONTRACT-001\' +
    [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' +
    [Guid]::NewGuid().ToString('N').Substring(0,8) + '-failure-probe')
$savedErrorActionPreference = $ErrorActionPreference
try {
  $ErrorActionPreference = 'Continue'
  $failureConsole = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass `
      -File $runner -OfflineSelfTest -OfflineCaptureFailureProbe `
      -RepoRoot $repo -OutputDirectory $failureOutput 2>&1)
  $failureExitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $savedErrorActionPreference
}
$failureSummaryPath = Join-Path $failureOutput 'summary.json'
$failureSealPath = Join-Path $failureOutput 'final_seal.json'
Assert-Condition ($failureExitCode -eq 1 -and
    (Test-Path -LiteralPath $failureSummaryPath -PathType Leaf) -and
    (Test-Path -LiteralPath $failureSealPath -PathType Leaf)) `
    ('Injected exceptional capture did not fail and seal evidence as expected: ' +
      (@($failureConsole) -join ' | '))
$failureSummary = Get-Content -LiteralPath $failureSummaryPath -Raw |
    ConvertFrom-Json
$failureSeal = Get-Content -LiteralPath $failureSealPath -Raw |
    ConvertFrom-Json
$failureErrors = @($failureSummary.cleanup.errors | ForEach-Object {[string]$_})
$failureSteps = @($failureSummary.cleanup.steps)
$failureConsoleText = @($failureConsole | ForEach-Object {[string]$_}) -join ' | '
$failureConsoleCompact = $failureConsoleText -replace '\s',''
Assert-Condition ([string]$failureSummary.result -ceq 'FAIL' -and
    [string]$failureSummary.failure -match 'injected capture body failure' -and
    [string]$failureSummary.failure -match 'injected serial close failure' -and
    [string]$failureSummary.failure -match
      'injected deferred persistence failure' -and
    [string]$failureSummary.capture_failure -ceq
      'injected capture body failure' -and
    [string]$failureSummary.cleanup.result -ceq 'FAIL' -and
    [int]$failureSummary.cleanup.error_count -eq 6 -and
    @($failureErrors | Where-Object {
      $_ -match 'injected serial close failure'}).Count -eq 1 -and
    @($failureErrors | Where-Object {
      $_ -match 'injected serial dispose failure'}).Count -eq 1 -and
    @($failureErrors | Where-Object {
      $_ -match 'injected deferred persistence failure'}).Count -eq 1 -and
    @($failureErrors | Where-Object {
      $_ -match 'injected pending frame one failure'}).Count -eq 1 -and
    @($failureErrors | Where-Object {
      $_ -match 'injected pending frame two failure'}).Count -eq 1 -and
    @($failureErrors | Where-Object {
      $_ -match 'injected raw dispose failure'}).Count -eq 1 -and
    @($failureSteps | Where-Object {
      [string]$_.name -ceq 'serial_close:offline-injected' -and
      [string]$_.result -ceq 'FAIL'}).Count -eq 1 -and
    @($failureSteps | Where-Object {
      [string]$_.name -ceq 'deferred_evidence_persistence' -and
      [string]$_.result -ceq 'FAIL'}).Count -eq 1 -and
    -not [bool]$failureSummary.hardware_interaction -and
    -not [bool]$failureSummary.external_actions.com_ports_opened -and
    -not [bool]$failureSummary.external_actions.cim_queried -and
    -not [bool]$failureSummary.external_actions.pnp_queried -and
    -not [bool]$failureSummary.external_actions.process_inventory_queried -and
    -not [bool]$failureSummary.external_actions.firmware_write_attempted -and
    -not [bool]$failureSummary.external_actions.e220_write_attempted -and
    @($failureSummary.external_actions.opened_ports).Count -eq 0 -and
    $failureConsoleCompact -match 'injectedcapturebodyfailure' -and
    $failureConsoleCompact -match 'injectedserialclosefailure' -and
    $failureConsoleCompact -match 'injecteddeferredpersistencefailure' -and
    $failureConsoleCompact -match 'injectedpendingframeonefailure' -and
    $failureConsoleCompact -match 'injectedpendingframetwofailure' -and
    [string]$failureSeal.result -ceq 'FAIL' -and
    [string]$failureSeal.summary_sha256 -ceq (Get-Sha $failureSummaryPath)) `
    'Capture-body plus cleanup/persistence failures were not preserved top-level.'

Write-Output ("R19-RUNTIME-FAIL-DIAGNOSTIC-RUNNER-CONTRACT-001 PASS " +
    "evidence=$output")
exit 0
