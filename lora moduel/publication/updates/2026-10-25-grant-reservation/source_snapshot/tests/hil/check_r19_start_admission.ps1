[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='', [switch]$RedProbe)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$capturePath=Join-Path $RepoRoot 'tools/run_r19_timed_path_capture.ps1'
$savedRepo=$RepoRoot
try{. $capturePath -ImportOnly -ParamListDiagnostics -Mode ExplicitHostArm -AuxReadinessDiagnostics -DiagnosticUsbFailureDiagnostics}finally{$RepoRoot=$savedRepo}
$script:checks=0
function Check([bool]$Value,[string]$Name){$script:checks++;if(-not$Value){throw ('FAIL '+$Name)}}
$script:writerCalls=0
$state=New-R19ParamListDiagnosticsState -Frequency 1000 -ClockDomainId 'strict-test-clock'
$arguments=@{State=$state;Role='ground';Workflow=[pscustomobject]@{arm_write_accepted=$true};HeartbeatCount=1;CaptureDeadlineTicks='40000';RawOffset=0L;ReaderPendingBytes=0;NowTicks={'100'};Writer={param([byte[]]$Bytes)$script:writerCalls++;return [int]$Bytes.Length}}
# The requested scenario is always high-speed-only. On the baseline, exercise
# the existing real helper without inventing a missing-parameter failure.
if((Get-Command Invoke-R19ParamListRequest).Parameters.ContainsKey('RequireHighSpeedStart')){$arguments.RequireHighSpeedStart=$true}
$attempted=Invoke-R19ParamListRequest @arguments
Check ($script:writerCalls-eq0-and-not$attempted-and$state.write_attempts-eq0) 'ARM+Heartbeat alone cannot authorize a high-speed-only PARAM write'
if($RedProbe){Write-Output "check_r19_start_admission behavioral probe PASS checks=$script:checks hardware_interaction=false";exit 0}
. (Join-Path $RepoRoot 'tools/r19_start_admission.ps1')
function CopyValue([object]$Value){return ($Value|ConvertTo-Json -Depth 20|ConvertFrom-Json)}
function Interval([string]$Low,[string]$High=$Low){[pscustomobject]@{earliest_ms=$Low;latest_ms=$High;bounded=$true}}
function Binding {
  [pscustomobject]@{candidate_id='SYNTHETIC-NOT-HARDWARE';build_fingerprint=('A'*32);boot_id=('B'*32);reader_session='9';usb_epoch='7';ground_clock_id=('C'*32)
    slot_token=11;slot_generation=2;grant_session=1;grant_cycle=2;baseline_session=1;baseline_cycle=1;baseline_slot_generation=1}
}
function Fixture {
  $binding=Binding
  $param=New-R19ParamListDiagnosticsState -Frequency 1000 -ClockDomainId 'strict-test-clock'
  $admission=New-R19StartAdmissionState -ExpectedBinding $binding -Frequency 1000 -ClockDomainId 'strict-test-clock' -OriginalT0GroundMs '1000' -OfflineSimulation $true
  $param|Add-Member NoteProperty start_admission $admission
  $slotIdentity=$binding|Select-Object candidate_id,build_fingerprint,boot_id,reader_session,usb_epoch,ground_clock_id,slot_token,slot_generation,grant_session,grant_cycle
  $e=[pscustomobject]@{schema='vc-lora-r19-start-admission-plan-evidence-v1';mode='OFFLINE_SIMULATION';identity=$slotIdentity
    producer_bound=$true;unused=$true;request_before_grant_at_equal_timestamp=$false;issued_ground_ms='900';expires_ground_ms='1500';original_t0_ground_ms='1000'
    clock_correlation=[pscustomobject]@{schema='vc-lora-r19-bounded-pc-ground-clock-v1';clock_domain_id='strict-test-clock';frequency='1000';ground_clock_id=('C'*32);pc_anchor_ticks='100';ground_at_anchor=(Interval '1000');valid_until_ticks='1100';max_age_ms=1000;maximum_drift_ppm=0}
    ground_request_accept=(Interval '1000');ground_next_grant=(Interval '1400');vehicle_grant_physical_tail=(Interval '9000');vehicle_complete_vcbn=(Interval '9320' '9330')
    vehicle_clock_at_ground_grant=(Interval '9200');transport_after_ground_guard=(Interval '20' '30')}
  [pscustomobject]@{state=$param;admission=$admission;evidence=$e;binding=$binding}
}
function Evaluate([object]$Fixture,[string]$Now='100'){Test-R19StartAdmissionEvidence -State $Fixture.admission -Evidence $Fixture.evidence -NowTicks $Now}
function CallHelper([object]$Fixture,[hashtable]$Overrides=@{},[switch]$Legacy){
  $args=@{State=$Fixture.state;Role='ground';Workflow=[pscustomobject]@{arm_write_accepted=$true};HeartbeatCount=1;CaptureDeadlineTicks='40000';RawOffset=0L;ReaderPendingBytes=0;NowTicks={'100'}
    Writer={param([byte[]]$Payload)$script:writerCalls++;return [int]$Payload.Length}}
  if(-not$Legacy){$args.RequireHighSpeedStart=$true;$args.StartAdmissionEvidence=$Fixture.evidence}
  foreach($key in $Overrides.Keys){$args[$key]=$Overrides[$key]}
  Invoke-R19ParamListRequest @args
}
function RejectPlan([scriptblock]$Change,[string]$Name){
  $f=Fixture;&$Change $f.evidence $f.admission
  $d=Evaluate $f
  Check (-not$d.feasible_plan-and$d.result-ceq'NOT_READY_NO_WRITE'-and-not$d.live_start_authorized-and-not$d.reservation_proven) $Name
  Check ($f.admission.events.Count-eq1-and$f.admission.events[0].now_ticks-ceq'100'-and$f.admission.events[0].reason-ceq$d.reason) ($Name+' preserves reason and PC time')
}
$f=Fixture;$d=Evaluate $f
Check ($d.feasible_plan-and$d.result-ceq'FEASIBLE_PLAN_NOT_RESERVATION'-and-not$d.reservation_proven-and-not$d.live_start_authorized) 'feasible synthetic arithmetic never claims a reservation or live authority'
Check ($d.ground_wait_max_ms-ceq'400'-and$d.vehicle_age_max_ms-ceq'330'-and$d.projected_vehicle_complete.earliest_ms-ceq'9320'-and$d.projected_vehicle_complete.latest_ms-ceq'9330') 'separate MCU clocks and explicit100ms guard plus bounded transport projection'
Check ($d.ground_now.earliest_ms-ceq'1000'-and$d.ground_now.latest_ms-ceq'1000') 'PC-to-Ground comparison uses declared bounded interval'
$f=Fixture;$f.admission.expected_binding.baseline_session=0;$d=Evaluate $f
Check (-not$d.feasible_plan) 'uninitialized baseline session cannot prove a fresh eligible Grant'
$f=Fixture;$f.evidence.expires_ground_ms='1100';$d=Evaluate $f
Check (-not$d.feasible_plan) 'slot validity must cover the entire future Ground Grant interval'
$f=Fixture;$f.evidence.ground_request_accept=Interval '999' '1001';$f.evidence.issued_ground_ms='1000';$d=Evaluate $f
Check (-not$d.feasible_plan) 'slot must already exist for the earliest possible Ground request acceptance'
$f=Fixture;$f.admission.expected_binding.baseline_cycle=0;$d=Evaluate $f
Check $d.feasible_plan 'initialized baseline session can retain cycle0 before first Grant'
$f=Fixture;$null=Evaluate $f;$view=Get-R19StartAdmissionSnapshot $f.admission;$originalReason=$f.admission.events[0].reason;$view.events[0].reason='CALLER_MUTATION'
Check ($f.admission.events[0].reason-ceq$originalReason) 'returned history snapshot cannot mutate retained state evidence'
$f=Fixture;$f.evidence.identity.grant_cycle=65535;$f.admission.expected_binding.grant_cycle=65535;$d=Evaluate $f
Check (-not$d.feasible_plan) 'older cyclic Grant cannot satisfy freshness merely by being different'
foreach($field in @('grant_cycle','grant_session')){
  $baselineField=if($field-ceq'grant_cycle'){'baseline_cycle'}else{'baseline_session'}
  foreach($case in @(@{baseline=65535;next=1;ready=$true},@{baseline=1;next=2;ready=$true},@{baseline=2;next=1;ready=$false},@{baseline=1;next=32769;ready=$false},@{baseline=32769;next=1;ready=$false},@{baseline=1;next=0;ready=$false})){
    $f=Fixture;$f.evidence.identity.$field=$case.next;$f.admission.expected_binding.$field=$case.next;$f.admission.expected_binding.$baselineField=$case.baseline
    $d=Evaluate $f;Check ($d.feasible_plan-eq$case.ready) ('bounded16bit Grant sequence '+$field+' '+$case.baseline+'->'+$case.next)
  }
}
foreach($wait in @(499,500,501)){
  $f=Fixture;$f.evidence.ground_next_grant=Interval ([string](1000+$wait))
  $d=Evaluate $f;Check ($d.feasible_plan-eq($wait-le500)) ('Ground inclusive500ms boundary '+$wait)
  $f=Fixture;$end=9000+$wait;$f.evidence.vehicle_complete_vcbn=Interval ([string]$end);$f.evidence.vehicle_clock_at_ground_grant=Interval ([string]($end-120));$f.evidence.transport_after_ground_guard=Interval '20'
  $d=Evaluate $f;Check ($d.feasible_plan-eq($wait-le500)) ('Vehicle independent inclusive500ms boundary '+$wait)
}
$f=Fixture;$f.evidence.ground_next_grant=Interval '1000';$d=Evaluate $f
Check (-not$d.feasible_plan-and$d.reason-ceq'EQUAL_TIMESTAMP_ORDER_UNPROVEN') 'same timestamp without request-before witness cannot reuse Grant'
$f=Fixture;$f.evidence.ground_next_grant=Interval '1000';$f.evidence.request_before_grant_at_equal_timestamp=$true;$d=Evaluate $f
Check $d.feasible_plan 'same timestamp is feasible only with explicit order witness in simulation'
foreach($field in @('ground_request_accept','ground_next_grant','vehicle_grant_physical_tail','vehicle_complete_vcbn','vehicle_clock_at_ground_grant','transport_after_ground_guard')){
  $f=Fixture;$f.evidence.$field.bounded=$false;$d=Evaluate $f;Check (-not$d.feasible_plan-and$d.reason-like'UNBOUNDED_*') ('missing bound '+$field)
  $f=Fixture;$f.evidence.$field.earliest_ms='2';$f.evidence.$field.latest_ms='1';$d=Evaluate $f;Check (-not$d.feasible_plan) ('reversed interval '+$field)
}
foreach($field in @('candidate_id','build_fingerprint','boot_id','reader_session','usb_epoch','ground_clock_id','slot_token','slot_generation','grant_session','grant_cycle')){
  $f=Fixture
  if($field-cin@('slot_token','slot_generation','grant_session','grant_cycle')){$f.evidence.identity.$field++}
  elseif($field-cin@('build_fingerprint','boot_id','ground_clock_id')){$f.evidence.identity.$field=('D'*32)}
  elseif($field-cin@('reader_session','usb_epoch')){$f.evidence.identity.$field='10'}else{$f.evidence.identity.$field='OTHER-CANDIDATE'}
  $d=Evaluate $f;Check (-not$d.feasible_plan-and$d.reason-like'SLOT_IDENTITY_MISMATCH_*') ('independent expected binding '+$field)
}
RejectPlan {param($e,$a)$e.identity.grant_cycle=1;$a.expected_binding.grant_cycle=1} 'baseline Grant cannot become fresh by unchanged identity'
RejectPlan {param($e,$a)$e.identity.slot_generation=1;$a.expected_binding.slot_generation=1} 'generation not newer than baseline is stale'
RejectPlan {param($e,$a)$e.producer_bound=$false} 'unbound producer assertion'
RejectPlan {param($e,$a)$e.unused=$false} 'consumed slot'
RejectPlan {param($e,$a)$e.producer_bound='true'} 'string is not Boolean authority'
RejectPlan {param($e,$a)$e.unused=1} 'integer is not Boolean unused'
RejectPlan {param($e,$a)$e.original_t0_ground_ms='1001'} 'original MCU request origin cannot reset'
RejectPlan {param($e,$a)$e.ground_request_accept=Interval '1001' '1002'} 'actual t0 and mapped Ground now must lie in request interval'
RejectPlan {param($e,$a)$e.ground_next_grant=Interval '999' '1400'} 'interval overlap can place Grant before request'
RejectPlan {param($e,$a)$e.vehicle_complete_vcbn=Interval '8999' '9330'} 'complete cannot precede Vehicle physical tail'
RejectPlan {param($e,$a)$e.vehicle_complete_vcbn=Interval '9321' '9330'} 'declared completion must contain full earliest guard projection'
RejectPlan {param($e,$a)$e.vehicle_complete_vcbn=Interval '9320' '9329'} 'declared completion must contain full latest transport projection'
RejectPlan {param($e,$a)$e.vehicle_grant_physical_tail=Interval '18446744073709551415';$e.vehicle_complete_vcbn=Interval '18446744073709551615';$e.vehicle_clock_at_ground_grant=Interval '18446744073709551565'} 'checked guard-transport addition overflow'
RejectPlan {param($e,$a)$e.ground_next_grant.latest_ms='01400'} 'noncanonical integer string'
RejectPlan {param($e,$a)$e.identity.slot_token=11.5} 'fractional identity'
RejectPlan {param($e,$a)$e|Add-Member NoteProperty extra $true} 'unknown evidence fields'
RejectPlan {param($e,$a)$v=$e.identity.slot_token;$e.identity.PSObject.Properties.Remove('slot_token');$e.identity|Add-Member NoteProperty Slot_Token $v} 'wrong field case'
RejectPlan {param($e,$a)$e.clock_correlation.clock_domain_id='another-clock'} 'PC clock domain mismatch'
RejectPlan {param($e,$a)$e.clock_correlation.ground_clock_id=('D'*32)} 'Ground clock mapping identity mismatch'
RejectPlan {param($e,$a)$e.clock_correlation.frequency='10000000'} 'PC frequency mismatch'
RejectPlan {param($e,$a)$e.clock_correlation.pc_anchor_ticks='101'} 'future clock sample'
RejectPlan {param($e,$a)$e.clock_correlation.valid_until_ticks='99'} 'expired clock sample'
RejectPlan {param($e,$a)$e.clock_correlation.ground_at_anchor=Interval '999' '1001'} 'clock uncertainty cannot be silently collapsed to midpoint'
RejectPlan {param($e,$a)$e.issued_ground_ms='1001'} 'slot not yet issued'
RejectPlan {param($e,$a)$e.expires_ground_ms='999'} 'expired slot'
RejectPlan {param($e,$a)$a.offline_simulation=$false} 'real writer remains forbidden even with feasible numeric fixture'
RejectPlan {param($e,$a)$a.offline_simulation='true'} 'simulation permission requires exact Boolean'
RejectPlan {param($e,$a)$a.expected_binding=$null} 'no self-declared expected identity'
RejectPlan {param($e,$a)$a.simulation_writer_attempted=$true} 'simulated slot cannot be consumed twice'
$f=Fixture;$f.binding.candidate_id='MUTATED';Check (Evaluate $f).feasible_plan 'constructor freezes expected scalar binding independently of caller object'
$f=Fixture;$f.evidence.clock_correlation.pc_anchor_ticks='0';$f.evidence.clock_correlation.max_age_ms=99;$d=Evaluate $f
Check (-not$d.feasible_plan-and$d.reason-ceq'CLOCK_MAPPING_TOO_OLD') 'freshness maximum age is independently enforced'
$f=Fixture;$null=Evaluate $f;$d=Evaluate $f '99'
Check (-not$d.feasible_plan-and$d.reason-ceq'PC_CLOCK_REGRESSION') 'PC sample regression is not an interval estimate'
$f=Fixture;$f.evidence.clock_correlation.pc_anchor_ticks='0';$f.evidence.clock_correlation.ground_at_anchor=Interval '900';$f.evidence.clock_correlation.maximum_drift_ppm=10000
$d=Evaluate $f;Check (-not$d.feasible_plan-and$d.ground_now.earliest_ms-ceq'999'-and$d.ground_now.latest_ms-ceq'1001') 'bounded clock drift expands instead of reducing uncertainty'
$f=Fixture;$f.evidence.clock_correlation.frequency='3000';$f.admission.frequency='3000';$f.evidence.clock_correlation.pc_anchor_ticks='99';$f.evidence.ground_request_accept=Interval '1000' '1001'
$d=Evaluate $f;Check ($d.feasible_plan-and$d.ground_now.earliest_ms-ceq'1000'-and$d.ground_now.latest_ms-ceq'1001') 'fractional QPC conversion uses outward rounding'
$f=Fixture;$script:writerCalls=0
Check (CallHelper $f) 'explicit offline simulation can invoke injected fake writer after feasible plan'
Check ($script:writerCalls-eq1-and$f.state.write_attempts-eq1-and$f.state.request_write_started_ticks-eq100-and$f.state.deadline_ticks-eq30100-and$f.admission.simulation_writer_attempted) 'original PC write t0 and30-second deadline remain unchanged'
Check (-not(CallHelper $f)-and$script:writerCalls-eq1) 'strict helper never repeats request'
foreach($test in @(
  @{name='missing-evidence';changes=@{StartAdmissionEvidence=$null}},
  @{name='ARM-not-accepted';changes=@{Workflow=[pscustomobject]@{arm_write_accepted=$false}}},
  @{name='HB-missing';changes=@{HeartbeatCount=0}},
  @{name='reader-pending';changes=@{ReaderPendingBytes=1}},
  @{name='capture-budget-short';changes=@{CaptureDeadlineTicks='31099'}})){
  $f=Fixture;$script:writerCalls=0;$ok=CallHelper $f $test.changes
  Check (-not$ok-and$script:writerCalls-eq0-and$f.state.write_attempts-eq0-and$f.admission.events.Count-gt0) ('closed strict gate has reason/time and does not consume request '+$test.name)
}
$f=Fixture;$f.admission.offline_simulation=$false;$script:writerCalls=0
Check (-not(CallHelper $f)-and$script:writerCalls-eq0) 'strict helper refuses actual operation despite internally consistent slot fixture'
foreach($writer in @(
  {param([byte[]]$Payload)$script:writerCalls++;return [int]7},
  {param([byte[]]$Payload)$script:writerCalls++;return [int]0},
  {param([byte[]]$Payload)$script:writerCalls++;throw 'SIMULATED_WRITE_FAILURE'})){
  $f=Fixture;$script:writerCalls=0;$ok=CallHelper $f @{Writer=$writer}
  Check ($ok-and$f.state.write_attempts-eq1-and$f.state.write_committed-and$f.admission.simulation_writer_attempted) 'partial/zero/exception still consume immutable one write attempt'
  Check (-not(CallHelper $f)-and$script:writerCalls-eq1) 'partial/zero/exception never retry'
}
$f=Fixture;$script:writerCalls=0
Check (CallHelper $f -Legacy) 'legacy diagnostics still sends one readiness-gated request without slot planning'
Check ($script:writerCalls-eq1-and$f.admission.evaluation_count-eq0) 'legacy mode neither requires nor evaluates future slot'
$f=Fixture;$f.admission.maximum_events=4
for($i=0;$i-lt20;$i++){$null=Evaluate $f}
$history=Get-R19StartAdmissionSnapshot $f.admission
Check ($history.evaluation_count-eq20-and$history.events.Count-eq4-and$history.events_dropped-eq16-and-not$history.history_complete) 'bounded first-half/last-half history reports dropped evidence'
Check ($history.events[0].ordinal-eq1-and$history.events[1].ordinal-eq2-and$history.events[2].ordinal-eq19-and$history.events[3].ordinal-eq20) 'bounded history retains first and last observations'
$roundTrip=$history|ConvertTo-Json -Depth 10|ConvertFrom-Json
Check ($roundTrip.events.Count-eq4-and$roundTrip.live_start_authorized-is[bool]-and-not$roundTrip.live_start_authorized) 'history round-trip preserves explicit no-authority typing'
$f=Fixture;$null=Evaluate $f;$before=Get-R19StartAdmissionSnapshot $f.admission
$f.evidence.identity.slot_token=99;$f.admission.expected_binding.slot_token=98
Check ($before.events[0].expected_binding.slot_token-eq11-and$before.events[0].evaluated_slot_identity.slot_token-eq11-and$before.events[0].evidence_sha256-cmatch'^[A-F0-9]{64}$') 'recorded binding, slot and non-authenticating digest are immutable'
Check ($before.events[0].original_t0_ground_ms-ceq'1000'-and$before.events[0].ground_wait_max_ms-ceq'400'-and$before.events[0].vehicle_age_max_ms-ceq'330'-and$before.events[0].projected_vehicle_complete.latest_ms-ceq'9330') 'history contains evaluated origin and both timing boundaries'
if(-not$OutputDirectory){$OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('r19-start-admission-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$historyPath=Join-Path $OutputDirectory 'admission-history.json'
[IO.File]::WriteAllText($historyPath,($before|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
$saved=Get-Content -LiteralPath $historyPath -Raw|ConvertFrom-Json
Check (($saved|ConvertTo-Json -Depth 16 -Compress)-ceq($before|ConvertTo-Json -Depth 16 -Compress)) 'actual saved history JSON readback retains bound immutable evidence'
foreach($claim in @($null,[pscustomobject]@{heartbeat_count=37;param_count=932;high_speed_success=$true},[pscustomobject]@{fallback=$true;provenance_verified=$true;reservation_proven=$true},[pscustomobject]@{result='FEASIBLE_PLAN_NOT_RESERVATION';feasible_plan=$true})){
  $route=Get-R19TransferRouteClassification $claim
  Check ($route.classification-ceq'UNKNOWN_ROUTE_NOT_HIGH_SPEED_SUCCESS'-and-not$route.high_speed_success_proven-and-not$route.r18_fallback_proven-and-not$route.acceptance_authorized) 'counts, Boolean claims and plan arithmetic never identify actual route'
  Check ($route.observation_status-ceq'NOT_OBSERVED'-and$null-eq$route.actual_negotiation_start_ms-and$null-eq$route.actual_bulk_start_ms) 'unobserved protocol timestamps remain null, not fabricated measurements'
}
# Execute the real CLI's earliest refusal branch, with all dangerous command
# names replaced. It must fail before importing/claiming/querying/opening anything.
$script:forbiddenCalls=0
foreach($name in @('Get-CimInstance','Get-PnpDevice','Get-PnpDeviceProperty','Get-Process','Start-Process')){Set-Item -Path ('function:script:'+$name) -Value {$script:forbiddenCalls++;throw 'FORBIDDEN_TEST_OPERATION'}}
$tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($capturePath,[ref]$tokens,[ref]$parseErrors)
Check (@($parseErrors).Count-eq0) 'capture AST parses with new CLI opt-in'
$gate=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.IfStatementAst]-and$_.Extent.Text.Contains('Future-slot producer unavailable; no live high-speed admission.')})
Check ($gate.Count-eq1) 'live refusal is one top-level branch'
$imports=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]-and$n.InvocationOperator-eq[Management.Automation.Language.TokenKind]::Dot},$true))
Check (@($imports|Where-Object{$_.Extent.StartOffset-lt$gate[0].Extent.EndOffset}).Count-eq0) 'live strict refusal precedes imports and all capture operations'
$rejected='';try{&$capturePath -RequireHighSpeedStart -Execute -RepoRoot $RepoRoot}catch{$rejected=$_.Exception.Message}
Check ($rejected-like'Future-slot producer unavailable; no live high-speed admission.*'-and$script:forbiddenCalls-eq0) 'real strict CLI refuses before device/process/permit actions'
$savedRepo=$RepoRoot;try{. $capturePath -ImportOnly -RequireHighSpeedStart}finally{$RepoRoot=$savedRepo}
Check ($null-ne(Get-Command Invoke-R19ParamListRequest -ErrorAction SilentlyContinue)) 'strict ImportOnly remains definitions-only'
Write-Output "check_r19_start_admission PASS checks=$script:checks hardware_interaction=false live_start_authorized=false future_slot_producer=false"
