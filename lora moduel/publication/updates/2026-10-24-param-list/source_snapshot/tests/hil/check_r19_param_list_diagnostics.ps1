[CmdletBinding()]
param([string]$RepoRoot='',[string]$OutputDirectory='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('runs/validation/R19-PARAM-LIST-DIAGNOSTICS-OFFLINE-001/20261024T090000JST/ledger/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$results=[Collections.Generic.List[object]]::new()
function Require([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){try{&$Body;$results.Add([pscustomobject]@{name=$Name;passed=$true;error=''})}catch{$results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message})}}
function Reject([scriptblock]$Body){Require ($null-ne(Get-Command New-R19ParamListDiagnosticsState -ErrorAction SilentlyContinue)) 'Missing helper is not a valid rejection';$threw=$false;try{&$Body|Out-Null}catch{$threw=$true};Require $threw 'Expected refusal'}
function Crc([uint16]$C,[byte]$B){$t=($B-bxor($C-band255))-band255;$t=($t-bxor($t-shl4))-band255;[uint16]((($C-shr8)-bxor($t-shl8)-bxor($t-shl3)-bxor($t-shr4))-band65535)}
function Frame([int]$Index=0,[int]$Count=932,[string]$Id='', [int]$System=1,[int]$Component=1,[int]$Version=2,[int]$Type=9,[switch]$BadCrc,[switch]$Signed){
  if(-not$Id){$Id='P{0:D6}'-f$Index}
  $p=if($Version-eq2){10}else{6};$signature=if($Signed){13}else{0};$b=[byte[]]::new($p+25+2+$signature)
  $b[0]=if($Version-eq2){253}else{254};$b[1]=25
  if($Version-eq2){$b[2]=if($Signed){1}else{0};$b[5]=$System;$b[6]=$Component;$b[7]=22}else{$b[3]=$System;$b[4]=$Component;$b[5]=22}
  $b[$p+4]=[byte]($Count-band255);$b[$p+5]=[byte](($Count-shr8)-band255);$b[$p+6]=[byte]($Index-band255);$b[$p+7]=[byte](($Index-shr8)-band255)
  $idb=[Text.Encoding]::ASCII.GetBytes($Id);[Array]::Copy($idb,0,$b,$p+8,[Math]::Min(16,$idb.Length));$b[$p+24]=$Type
  [uint16]$c=65535;for($i=1;$i-lt$p+25;$i++){$c=Crc $c $b[$i]};$c=Crc $c 220;$b[$p+25]=[byte]($c-band255);$b[$p+26]=[byte]($c-shr8)
  if($BadCrc){$b[$p+26]=$b[$p+26]-bxor1};return ,$b
}
function State([int64]$Frequency=1000,[int]$MaximumRawBytes=4194304,[int]$MaximumFrames=8192){$s=New-R19ParamListDiagnosticsState -Frequency $Frequency -MaximumRawBytes $MaximumRawBytes -MaximumFrames $MaximumFrames;Begin-R19ParamListWrite $s 100|Out-Null;Commit-R19ParamListWrite $s 14|Out-Null;return $s}
function Add($s,[byte[]]$b,[int64]$t){Add-R19ParamListBytes -State $s -Bytes $b -ReadCompletedTicks $t -RawOffset $s.next_raw_offset|Out-Null}
function Seal($s){Freeze-R19ParamList30 -State $s -ObservationComplete:$true}
$helper=Join-Path $RepoRoot 'tools/r19_param_list_diagnostics.ps1'
if(Test-Path -LiteralPath $helper){. $helper}
Check 'pure-helper-import-and-fixed-frame' {$s=New-R19ParamListDiagnosticsState -Frequency 1000;$b=Begin-R19ParamListWrite $s 100;Require ($b-is[byte[]]-and([BitConverter]::ToString($b)-replace'-','')-ceq'FD02000063FFBE1500000101D507') 'Canonical request changed';Require ($s.write_attempts-eq1-and$s.request_write_started_ticks-eq100-and$s.deadline_ticks-eq30100) 'Write origin/deadline not latched'}
Check 'one-attempt-is-latched-before-partial-write-result' {$s=New-R19ParamListDiagnosticsState -Frequency 1000;Begin-R19ParamListWrite $s 100|Out-Null;Commit-R19ParamListWrite $s 7|Out-Null;Reject {Begin-R19ParamListWrite $s 200};$r=Get-R19ParamListSnapshot $s;Require ($r.request.accepted_bytes-eq7-and$r.request.local_write_api_accepted_only-and-not$r.request.delivery_proven-and$r.result-ceq'WRITE_INCOMPLETE') 'Partial write misclassified'}
Check 'exception-never-authorizes-second-write' {$s=New-R19ParamListDiagnosticsState -Frequency 1000;Begin-R19ParamListWrite $s 100|Out-Null;Commit-R19ParamListWrite $s -ExceptionType 'IOException'|Out-Null;Reject {Begin-R19ParamListWrite $s 200};Reject {Commit-R19ParamListWrite $s 14};$r=Get-R19ParamListSnapshot $s;Require ($null-eq$r.request.accepted_bytes-and$r.request.exception_type-ceq'IOException') 'Unknown local acceptance fabricated'}
Check 'CRC-valid-v2-ledger-provenance' {$s=State;$b=Frame 12;Add $s $b 200;$r=Get-R19ParamListSnapshot $s;$e=$r.ledger[0];Require ($r.unique_count-eq1-and$e.index-eq12-and$e.raw_offset-eq0-and$e.read_completed_ticks-eq200-and$e.frame_sha256.Length-eq64-and$e.id_16_hex.Length-eq32-and$e.source_system-eq1-and$e.source_component-eq1-and$e.param_count-eq932-and$e.crc_valid) 'Missing PARAM_VALUE provenance'}
Check 'MAVLink1-fragmented-ledger' {$s=State;$b=Frame 13 -Version 1;Add $s $b[0..5] 120;Add $s $b[6..($b.Length-1)] 130;$r=Get-R19ParamListSnapshot $s;Require ($r.unique_count-eq1-and$r.ledger[0].version-eq1-and$r.ledger[0].read_completed_ticks-eq130) 'Fragmented v1 frame not reconstructed'}
Check 'MAVLink2-each-byte-fragmented' {$s=State;$b=Frame 14;for($i=0;$i-lt$b.Length;$i++){Add $s ([byte[]]@($b[$i])) (120+$i)};$r=Get-R19ParamListSnapshot $s;Require ($r.unique_count-eq1-and$r.ledger[0].read_completed_ticks-eq156) 'Incremental v2 frame failed'}
Check 'unknown-frame-payload-magic-is-not-resynchronized' {$s=State;$f=Frame 55;$b=[byte[]]::new(12+$f.Length);$b[0]=253;$b[1]=$f.Length;$b[7]=250;[Array]::Copy($f,0,$b,10,$f.Length);Add $s $b 200;Add $s (Frame 56) 201;$r=Get-R19ParamListSnapshot $s;Require ($r.unique_count-eq1-and$r.ledger[0].index-eq56-and$r.parser.unknown_frames-eq1) 'Unknown payload falsely parsed as nested frame'}
Check 'bad-CRC-is-not-admitted-to-value-ledger' {$s=State;Add $s (Frame 2 -BadCrc) 200;$r=Get-R19ParamListSnapshot $s;Require ($r.unique_count-eq0-and@($r.ledger).Count-eq0-and$r.errors.bad_crc-eq1) 'Corrupt frame counted'}
Check 'signed-frame-is-not-claimed-authenticated' {$s=State;Add $s (Frame 2 -Signed) 200;Add $s (Frame 3) 201;$r=Get-R19ParamListSnapshot $s;Require ($r.unique_count-eq1-and$r.errors.unsupported_signed-eq1) 'Signature incorrectly trusted'}
foreach($case in @(@{name='wrong-count';frame={Frame 2 -Count 931};field='invalid_count'},@{name='wrong-system';frame={Frame 2 -System 2};field='invalid_source'},@{name='wrong-component';frame={Frame 2 -Component 2};field='invalid_source'},@{name='out-of-range';frame={Frame 932};field='invalid_index'})){
  Check ('reject-'+$case.name) {$s=State;Add $s (&$case.frame) 200;$r=Get-R19ParamListSnapshot $s;Require ($r.unique_count-eq0-and$r.errors.($case.field)-eq1-and@($r.ledger).Count-eq1) 'Invalid CRC-valid value not distinguished'}
}
Check 'STAT_RUNTIME-sentinel-is-separate-not-parameter' {$s=State;Add $s (Frame 65535 -Id STAT_RUNTIME -Type 6) 200;$r=Get-R19ParamListSnapshot $s;Require ($r.unique_count-eq0-and$r.sentinel_count-eq1-and$r.ledger[0].classification-ceq'STAT_RUNTIME_SENTINEL'-and$r.errors.invalid_index-eq0) 'Exact sentinel tuple not isolated'}
Check 'STAT_RUNTIME-name-does-not-exempt-wrong-tuple' {$s=State;Add $s (Frame 65535 -Id STAT_RUNTIME -Type 9) 200;$r=Get-R19ParamListSnapshot $s;Require ($r.sentinel_count-eq0-and$r.errors.invalid_index-eq1) 'Name alone exempted invalid index'}
Check 'out-of-order-is-observed-not-lost' {$s=State;Add $s (Frame 2) 200;Add $s (Frame 1) 201;$r=Get-R19ParamListSnapshot $s;Require ($r.unique_count-eq2-and$r.out_of_order_count-eq1-and$r.errors.total-eq0) 'Out-of-order sequence not distinguished'}
Check 'duplicate-index-is-not-unique-and-is-error' {$s=State;Add $s (Frame 2) 200;Add $s (Frame 2) 201;$r=Get-R19ParamListSnapshot $s;Require ($r.unique_count-eq1-and$r.errors.duplicate_index-eq1-and$r.ledger[1].classification-ceq'DUPLICATE_INDEX') 'Duplicate counted unique'}
Check 'exact-deadline-is-inclusive' {$s=State;Add $s (Frame 2) 30100;$r=Seal $s;Require ($r.unique_count-eq1-and$r.snapshot_complete-and$r.sealed) 'Exact deadline rejected'}
Check 'postdeadline-read-is-excluded-despite-early-analysis' {$s=State;Add $s (Frame 2) 30101;$r=Seal $s;Require ($r.unique_count-eq0-and$r.outside_window_count-eq1-and$r.final.unique_count-eq1) 'Postdeadline data entered 30s snapshot'}
Check 'boundary-partial-is-not-acquired' {$s=State;$b=Frame 2;Add $s $b[0..20] 30099;Add $s $b[21..36] 30101;$r=Seal $s;Require ($r.unique_count-eq0-and$r.outside_window_count-eq1) 'Boundary partial counted'}
Check 'pre-request-partial-is-not-owned-by-request' {$s=New-R19ParamListDiagnosticsState -Frequency 1000;$b=Frame 2;Add $s $b[0..9] 99;Begin-R19ParamListWrite $s 100 -RawOffsetAtWriteStart 10|Out-Null;Commit-R19ParamListWrite $s 14|Out-Null;Add $s $b[10..36] 101;$r=Seal $s;Require ($r.unique_count-eq0-and$r.pre_request_count-eq1) 'Pre-request partial attributed to this request'}
Check 'delayed-analysis-of-predeadline-read-is-included-before-seal' {$s=State;Add $s (Frame 2) 30099;$r=Seal $s;Require ($r.unique_count-eq1-and$r.snapshot_complete) 'Native read timestamp ignored'}
Check 'postseal-predeadline-data-invalidates-not-rewrites-snapshot' {$s=State;$first=Seal $s;Add $s (Frame 2) 30099;$r=Get-R19ParamListSnapshot $s;Require ($first.unique_count-eq0-and$r.unique_count-eq0-and-not$r.snapshot_complete-and$r.late_predeadline_data-and$r.result-ceq'INCOMPLETE_EVIDENCE') 'Late data fabricated complete sealed evidence'}
Check 'postseal-postdeadline-data-does-not-invalidate-window' {$s=State;Seal $s|Out-Null;Add $s (Frame 2) 30101;$r=Get-R19ParamListSnapshot $s;Require ($r.snapshot_complete-and-not$r.late_predeadline_data-and$r.unique_count-eq0) 'Unrelated postdeadline drain invalidated snapshot'}
Check 'pending-tail-is-reported-without-claiming-completion' {$s=State;$b=Frame 2;Add $s $b[0..20] 30099;$r=Seal $s;Require ($r.unique_count-eq0-and$r.parser.pending_bytes-eq21-and$r.errors.partial_frame-eq1-and-not$r.snapshot_complete) 'Partial tail concealed'}
Check '932-completion-and-clean-result-are-distinct-from-acceptance' {$s=State;for($i=0;$i-lt932;$i++){Add $s (Frame $i) (200+$i)};$r=Seal $s;Require ($r.unique_count-eq932-and@($r.missing_indexes).Count-eq0-and$r.all_932_received-and$r.errors.total-eq0-and$r.result-ceq'COMPLETE_932_CLEAN'-and-not$r.acceptance_eligible-and-not$r.deployment_authorized) 'Clean completion absent or overclaimed'}
Check '932-plus-error-is-not-clean' {$s=State;for($i=0;$i-lt932;$i++){Add $s (Frame $i) (200+$i)};Add $s (Frame 5) 1200;$r=Seal $s;Require ($r.all_932_received-and$r.result-ceq'COMPLETE_932_WITH_ERRORS'-and$r.errors.total-eq1) 'All unique concealed duplicate error'}
Check 'freeze-default-cannot-fabricate-reader-watermark' {$s=State;$r=Freeze-R19ParamList30 $s;Require (-not$r.snapshot_complete-and$r.result-ceq'INCOMPLETE_EVIDENCE') 'Default freeze claimed native observation complete'}
Check 'missing-indexes-are-exact' {$s=State;Add $s (Frame 0) 200;Add $s (Frame 931) 201;$r=Get-R19ParamListSnapshot $s;Require (@($r.missing_indexes).Count-eq930-and$r.missing_indexes[0]-eq1-and$r.missing_indexes[929]-eq930) 'Missing array incorrect'}
Check 'raw-offset-gap-is-refused' {$s=State;Reject {Add-R19ParamListBytes $s (Frame 0) 200 10}}
Check 'native-time-reversal-is-refused' {$s=State;Add $s (Frame 0) 200;Reject {Add $s (Frame 1) 199}}
Check 'bounded-memory-cap-invalidates-evidence' {$s=State -MaximumRawBytes 40;Add $s (Frame 0) 200;Reject {Add $s (Frame 1) 201};$r=Get-R19ParamListSnapshot $s;Require ($r.capacity_exceeded-and-not$r.snapshot_complete-and$r.result-ceq'INCOMPLETE_EVIDENCE') 'Raw cap not fail-closed'}
Check 'bounded-frame-cap-invalidates-evidence' {$s=State -MaximumFrames 1;Add $s (Frame 0) 200;Reject {Add $s (Frame 1) 201};$r=Get-R19ParamListSnapshot $s;Require ($r.capacity_exceeded-and@($r.ledger).Count-eq1) 'Ledger cap exceeded'}
Check 'unstarted-snapshot-is-not-a-result' {$s=New-R19ParamListDiagnosticsState -Frequency 1000;Reject {Freeze-R19ParamList30 $s}}
Check 'request-wire-clock-and-return-provenance' {$s=New-R19ParamListDiagnosticsState -Frequency 1000 -ClockDomainId 'test-native-clock';Begin-R19ParamListWrite $s 100|Out-Null;Commit-R19ParamListWrite $s 14 -WriteReturnedTicks 102|Out-Null;$r=Get-R19ParamListSnapshot $s;Require ($r.schema-ceq'vc-lora-r19-param-list-diagnostics-v1'-and$r.clock_domain_id-ceq'test-native-clock'-and$r.frequency-eq1000-and$r.deadline_us-ceq'30000000'-and$r.request.write_returned_ticks-eq102-and$r.request.expected_bytes-eq14-and$r.request.frame_sha256-ceq'FC3A47A83D35D44E96E044A216FDBF082805F9FACCDD5E4B9252E0C7026D4A75') 'Request wire/clock/result provenance missing'}
Check 'postdeadline-only-partial-does-not-dirty-30s-prefix' {$s=State;$b=Frame 2;Add $s $b[0..20] 30101;$r=Seal $s;Require ($r.snapshot_complete-and$r.snapshot_30s.parser.pending_bytes-eq0-and$r.snapshot_30s.errors.partial_frame-eq0-and$r.final.parser.pending_bytes-eq21) 'Unrelated future partial invalidated 30s prefix'}
Check 'historical-snapshot-excludes-later-error-and-data' {$s=State;Add $s (Frame 1) 200;Add $s (Frame 2 -BadCrc) 300;Add $s (Frame 3) 400;$r=Get-R19ParamListSnapshot $s -AtTicks 250;Require ($r.unique_count-eq1-and$r.errors.bad_crc-eq0-and@($r.ledger).Count-eq1) 'Historical view contaminated by future error/data'}
Check 'historical-snapshot-retains-earlier-parser-error' {$s=State;Add $s (Frame 2 -BadCrc) 200;Add $s (Frame 1) 300;$r=Get-R19ParamListSnapshot $s -AtTicks 250;Require ($r.unique_count-eq0-and$r.errors.bad_crc-eq1) 'Historical parser error lost'}
Check 'wrong-write-cursor-is-refused-before-attempt' {$s=New-R19ParamListDiagnosticsState -Frequency 1000;Reject {Begin-R19ParamListWrite $s 100 -RawOffsetAtWriteStart 1};Require ($s.write_attempts-eq0) 'Invalid cursor consumed attempt'}
Check 'return-time-before-write-is-refused' {$s=New-R19ParamListDiagnosticsState -Frequency 1000;Begin-R19ParamListWrite $s 100|Out-Null;Reject {Commit-R19ParamListWrite $s 14 -WriteReturnedTicks 99}}
Check 'zero-attempt-schema-is-explicit' {$s=New-R19ParamListDiagnosticsState -Frequency 1000;$r=Get-R19ParamListSnapshot $s;Require ($r.request_attempts-eq0-and$null-eq$r.request-and$r.result-ceq'NOT_ATTEMPTED'-and-not$r.snapshot_complete) 'Unattempted request fabricated'}
Check 'value-bits-and-wire-sequence-are-preserved' {$s=State;Add $s (Frame 2) 200;$r=Get-R19ParamListSnapshot $s;Require ($r.ledger[0].mavlink_sequence-eq0-and$r.ledger[0].param_value_bits_hex-ceq'00000000') 'Wire sequence/value bits missing'}
Check 'completion-time-is-native-time-not-processing-time' {$s=State;for($i=0;$i-lt932;$i++){Add $s (Frame $i) (200+$i)};$r=Seal $s;Require ($r.complete_read_completed_ticks-eq1131-and$r.elapsed_us-eq1031000-and$r.final.complete_read_completed_ticks-eq1131) 'Completion clock/elapsed not exact'}
Check '932-out-of-order-is-not-clean' {$s=State;for($i=931;$i-ge0;$i--){Add $s (Frame $i) (1200-$i)};$r=Seal $s;Require ($r.unique_count-eq932-and$r.out_of_order_count-eq931-and$r.result-ceq'COMPLETE_932_WITH_ERRORS'-and-not$r.clean_conditions_met) 'Out-of-order completion claimed clean'}
Check 'final-is-only-ingested-prefix-not-fabricated-complete-observation' {$s=State;Add $s (Frame 2) 200;$r=Seal $s;Require (-not$r.final.snapshot_complete-and$r.final.coverage-ceq'INGESTED_RAW_PREFIX_ONLY') 'Final prefix claims unobserved terminal coverage'}
Check 'actual-private-wire-codecs-interoperate-with-fragmented-parameter-ledger' {
  . (Join-Path $RepoRoot 'tools/r19_host_readiness_wire.ps1')
  . (Join-Path $RepoRoot 'tools/r19_usb_clock_correlation.ps1')
  [long]$nonce=5915770443393002996
  [byte[]]$reply=New-R19TimesyncRequest -Nonce $nonce;$reply[6]=194;[BitConverter]::GetBytes([long]12345000).CopyTo($reply,10);[BitConverter]::GetBytes([uint16](Get-R19TimesyncCrc $reply)).CopyTo($reply,26)
  Require ((ConvertFrom-R19TimesyncResponse -Bytes $reply -ExpectedNonce $nonce).valid) 'Actual ClockReply codec fixture invalid'
  [byte[]]$ready=New-R19HostReadinessFrame -Opcode Ready -Role Ground -ReaderSession 2 -Nonce $nonce -BootId 3 -UsbEpoch 1 -ReplyDeviceUs 12345
  Require ((ConvertFrom-R19HostReadinessFrame -Bytes $ready).valid) 'Actual READY codec fixture invalid'
  $diagnostics=[Collections.Generic.List[byte[]]]::new()
  foreach($text in @('R19A:G:L:00000001:0000000000000001:000000000000','R19F:G:0001:0000000000000001:000000000000:00000001')){
    $b=[byte[]]::new(63);$b[0]=253;$b[1]=51;$b[5]=254;$b[6]=190;$b[7]=253;$b[10]=if($text.StartsWith('R19F:')){2}else{6}
    $tb=[Text.Encoding]::ASCII.GetBytes($text);[Array]::Copy($tb,0,$b,11,$tb.Length);[uint16]$c=65535;foreach($value in $b[1..60]){$c=Crc $c $value};$c=Crc $c 83;$b[61]=[byte]($c-band255);$b[62]=[byte]($c-shr8);$diagnostics.Add($b)
  }
  [byte[]]$bytes=$reply+$diagnostics[0]+(Frame 2)+$ready+$diagnostics[1]+(Frame 3)
  $s=State
  for($off=0;$off-lt$bytes.Length;$off+=7){$end=[Math]::Min($off+6,$bytes.Length-1);Add $s $bytes[$off..$end] (200+$off)}
  $r=Seal $s;Require ($r.unique_count-eq2-and$r.errors.total-eq0-and$r.parser.unknown_frames-eq4-and@($r.ledger).Count-eq2) 'Clock/READY/ALIVE/FAIL were noise or false PARAM_VALUE'
}
Check 'source-is-pure-and-has-no-live-authority' {$source=[IO.File]::ReadAllText($helper);foreach($token in @('SerialPort','Get-PnpDevice','Get-CimInstance','Start-Process','Invoke-RestMethod','WriteFile','CreateFile')){Require (-not$source.Contains($token)) ('Pure helper contains '+$token)}}
$failed=@($results|Where-Object{-not$_.passed}).Count
$summary=[pscustomobject]@{schema='r19-param-list-diagnostics-offline-tests-v1';tests=$results.Count;passed=$results.Count-$failed;failed=$failed;hardware_operations=0;production_sources_changed=$false;results=@($results)}
$summary|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding UTF8
foreach($r in $results){'{0} {1} {2}'-f $(if($r.passed){'PASS'}else{'FAIL'}),$r.name,$r.error}
'TOTAL tests={0} passed={1} failed={2}'-f$results.Count,($results.Count-$failed),$failed
if($failed){exit 1}
