[CmdletBinding()]
param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),[string]$OutputDirectory='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not$OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('runs/validation/R19-PC-LIFECYCLE-READ-COMPARISON-FIX-001/20261023T152500Z/capture_contract/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+[Guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$results=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$results.Add([pscustomobject]@{name=$Name;passed=$true;error=''})}catch{$results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message})}}
function Require([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}
function Reject([scriptblock]$Action){Require ($null-ne(Get-Command Get-R19ReadComparisonPlan -ErrorAction SilentlyContinue)) 'Missing plan API cannot count as rejection';$rejected=$false;try{&$Action|Out-Null}catch{$rejected=$true};Require $rejected 'Unsafe selection was not rejected'}
function Clone($Value){$Value|ConvertTo-Json -Depth 40|ConvertFrom-Json}
foreach($forbidden in @('Get-CimInstance','Get-PnpDeviceProperty','Get-PnpDevice','Get-Process','Start-Process','Invoke-Expression','Invoke-Command')){Set-Item -Path ('function:script:'+$forbidden) -Value {throw 'FORBIDDEN comparison contract hardware/process call'}}
$capturePath=Join-Path $RepoRoot 'tools/run_r19_timed_path_capture.ps1'
$outerPath=Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1'
$captureSource=[IO.File]::ReadAllText($capturePath)
$outerSource=[IO.File]::ReadAllText($outerPath)
$captureAst=[Management.Automation.Language.Parser]::ParseInput($captureSource,[ref]$null,[ref]$null)
$outerAst=[Management.Automation.Language.Parser]::ParseInput($outerSource,[ref]$null,[ref]$null)
$comparisonFixtureRepoRoot=$RepoRoot;$comparisonFixtureOutputDirectory=$OutputDirectory
try{. $capturePath -ImportOnly}finally{$RepoRoot=$comparisonFixtureRepoRoot;$OutputDirectory=$comparisonFixtureOutputDirectory}
function New-ComparisonPlan {Get-R19ReadComparisonPlan -ReadComparisonMode GroundPauseResume -Mode ExplicitHostArm -CaptureSeconds 40 -AuxReadinessDiagnostics $true -DiagnosticUsbFailureDiagnostics $true}
function New-Lifecycle {
  [pscustomobject]@{stop_requested_ticks='410000010';worker_stopped_ticks='410000020';close_start_ticks='410000030';close_end_ticks='410000040';close_attempted=$true;close_completed=$true;close_failure=''}
}
function New-Observation {
  [pscustomobject]@{clock_domain_id='fixture-shared-qpc';frequency='10000000';measurement_start_ticks='10000000';measurement_end_ticks='410000000'
    roles=@(
      [pscustomobject]@{role='vehicle';reader_id='fixture-vehicle-owner';reader_continuous=$true;lifecycle=(New-Lifecycle);pause=[pscustomobject]@{requested=$false;requested_ticks=$null;begin_ticks=$null;end_ticks=$null;resumed_read_ticks=$null;begin_calls=0;end_calls=0;duration_ms=0;end_reason=''}},
      [pscustomobject]@{role='ground';reader_id='fixture-ground-owner';reader_continuous=$false;lifecycle=(New-Lifecycle);pause=[pscustomobject]@{requested=$true;requested_ticks='210000000';begin_ticks='210000100';end_ticks='230000100';resumed_read_ticks='230000200';begin_calls=17;end_calls=17;duration_ms=2000;end_reason='Deadline'}})}
}
function Get-Evaluation($Observation){Get-R19ReadComparisonEvaluation -Plan (New-ComparisonPlan) -Evidence $Observation}
function Require-Invalid($Observation){$r=Get-Evaluation $Observation;Require ($r.result-ceq'INVALID_COMPARISON'-and$r.valid-is[bool]-and-not$r.valid-and@($r.reasons).Count-gt0) 'Missing/invalid observations must explicitly invalidate comparison'}
Check 'definitions-only-import-is-not-an-execution-grant' {
  Require ($null-ne(Get-Command Get-R19ReadComparisonPlan -ErrorAction SilentlyContinue)-and$null-ne(Get-Command Get-R19ReadComparisonEvaluation -ErrorAction SilentlyContinue)) 'Missing pure comparison APIs'
}
Check 'None-default-retains-legacy-without-new-ledger' {
  $plan=Get-R19ReadComparisonPlan
  Require ($plan.mode-ceq'None'-and$plan.enabled-is[bool]-and-not$plan.enabled) 'Default must remain no intervention'
  $r=Get-R19ReadComparisonEvaluation -Plan $plan -Evidence $null
  Require ($r.result-ceq'NOT_REQUESTED'-and-not$r.valid) 'Legacy None must not require invented ledger or claim comparison'
}
Check 'active-plan-is-single-ground-pause-in-one-fixed-capture' {
  $plan=New-ComparisonPlan
  Require ($plan.mode-ceq'GroundPauseResume'-and$plan.enabled-and$plan.capture_seconds-eq40-and$plan.pause_after_seconds-eq20-and$plan.pause_ms-eq2000) 'Pause policy is not the fixed single40s/20s/2s plan'
  Require ($plan.semantics-ceq'APPLICATION_READ_PAUSE_NOT_USB_IN_SUPPRESSION') 'Application pause cannot be represented as physical USB IN suppression'
}
foreach($selection in @(
  @{name='unknown-mode';mode='AnythingElse';captureMode='ExplicitHostArm';seconds=40;aux=$true;diag=$true},
  @{name='SyncOnly';mode='GroundPauseResume';captureMode='SyncOnly';seconds=40;aux=$true;diag=$true},
  @{name='missing-AUX';mode='GroundPauseResume';captureMode='ExplicitHostArm';seconds=40;aux=$false;diag=$true},
  @{name='missing-diagnostic-ABI';mode='GroundPauseResume';captureMode='ExplicitHostArm';seconds=40;aux=$true;diag=$false},
  @{name='shorter-capture';mode='GroundPauseResume';captureMode='ExplicitHostArm';seconds=39;aux=$true;diag=$true},
  @{name='longer-capture';mode='GroundPauseResume';captureMode='ExplicitHostArm';seconds=41;aux=$true;diag=$true})){
  Check ('selection-rejects-'+$selection.name) {Reject {Get-R19ReadComparisonPlan -ReadComparisonMode $selection.mode -Mode $selection.captureMode -CaptureSeconds $selection.seconds -AuxReadinessDiagnostics $selection.aux -DiagnosticUsbFailureDiagnostics $selection.diag}}
}
Check 'complete-memory-observation-validates-without-claiming-root-cause' {
  $r=Get-Evaluation (New-Observation)
  Require ($r.result-ceq'VALID_COMPARISON'-and$r.valid-is[bool]-and$r.valid-and@($r.reasons).Count-eq0) 'Complete nested observation did not validate'
  Require ($r.causal_disposition-ceq'INDETERMINATE'-and-not$r.physical_host_in_suppression_proven-and-not$r.root_cause_proven-and-not$r.acceptance_eligible-and-not$r.deployment_authorized) 'Comparison must not grant acceptance or infer host-poll/root-cause proof'
}
function Require-InvalidPlan($Plan){$r=Get-R19ReadComparisonEvaluation -Plan $Plan -Evidence (New-Observation);Require ($r.result-ceq'INVALID_COMPARISON'-and-not$r.valid-and-not$r.acceptance_eligible-and-not$r.root_cause_proven) 'Malformed plan must return invalid, not throw or grant authority'}
Check 'evaluation-rejects-null-or-missing-mode-plan-without-throwing' {
  Require-InvalidPlan $null
  $plan=New-ComparisonPlan;$plan.PSObject.Properties.Remove('mode');Require-InvalidPlan $plan
}
Check 'evaluation-rejects-forged-plan-role' {
  $plan=New-ComparisonPlan;$plan.role='vehicle';Require-InvalidPlan $plan
}
Check 'evaluation-rejects-forged-or-missing-plan-authority-flags' {
  foreach($field in @('acceptance_eligible','root_cause_proven')){
    $plan=New-ComparisonPlan;$plan.$field=$true;Require-InvalidPlan $plan
    $plan=New-ComparisonPlan;$plan.PSObject.Properties.Remove($field);Require-InvalidPlan $plan
  }
}
foreach($mutation in @('missing-begin','missing-end','missing-resumed-read','early-request','begin-before-request','too-short','too-long','resume-before-end','resume-after-measurement','read-call-during-pause','not-deadline','vehicle-paused','ground-claimed-continuous','missing-role','duplicate-role','missing-clock-domain','zero-frequency','noninteger-tick','stop-before-measurement-end','worker-stop-before-request','close-before-worker-stop','close-end-before-start','close-not-attempted','close-not-completed','close-error','vehicle-stop-before-measurement-end','vehicle-close-error')){
  Check ('observation-rejects-'+$mutation) {
    $e=New-Observation;$g=$e.roles[1];$v=$e.roles[0]
    switch($mutation){
      'missing-begin'{$g.pause.begin_ticks=$null}
      'missing-end'{$g.pause.end_ticks=$null}
      'missing-resumed-read'{$g.pause.resumed_read_ticks=$null}
      'early-request'{$g.pause.requested_ticks='209999999'}
      'begin-before-request'{$g.pause.begin_ticks='209999999'}
      'too-short'{$g.pause.end_ticks='229999999'}
      'too-long'{$g.pause.end_ticks='235000101';$g.pause.resumed_read_ticks='235000102'}
      'resume-before-end'{$g.pause.resumed_read_ticks='230000099'}
      'resume-after-measurement'{$g.pause.resumed_read_ticks='410000001'}
      'read-call-during-pause'{$g.pause.end_calls=18}
      'not-deadline'{$g.pause.end_reason='Stop'}
      'vehicle-paused'{$v.pause.requested=$true}
      'ground-claimed-continuous'{$g.reader_continuous=$true}
      'missing-role'{$e.roles=@($g)}
      'duplicate-role'{$e.roles=@($g,(Clone $g))}
      'missing-clock-domain'{$e.clock_domain_id=''}
      'zero-frequency'{$e.frequency='0'}
      'noninteger-tick'{$g.pause.end_ticks='2.3e8'}
      'stop-before-measurement-end'{$g.lifecycle.stop_requested_ticks='409999999'}
      'worker-stop-before-request'{$g.lifecycle.worker_stopped_ticks='410000009'}
      'close-before-worker-stop'{$g.lifecycle.close_start_ticks='410000019'}
      'close-end-before-start'{$g.lifecycle.close_end_ticks='410000029'}
      'close-not-attempted'{$g.lifecycle.close_attempted=$false}
      'close-not-completed'{$g.lifecycle.close_completed=$false}
      'close-error'{$g.lifecycle.close_failure='FIXTURE_CLOSE_FAILURE'}
      'vehicle-stop-before-measurement-end'{$v.lifecycle.stop_requested_ticks='409999999'}
      'vehicle-close-error'{$v.lifecycle.close_failure='FIXTURE_VEHICLE_CLOSE_FAILURE'}
    }
    Require-Invalid $e
  }
}
Check 'evaluation-does-not-rewrite-close-failure-or-missing-end-evidence' {
  $e=New-Observation;$e.roles[1].pause.end_ticks=$null;$e.roles[1].lifecycle.close_completed=$false;$e.roles[1].lifecycle.close_failure='FIXTURE_CLOSE_FAILURE'
  $before=$e|ConvertTo-Json -Depth 30 -Compress
  Require-Invalid $e
  Require (($e|ConvertTo-Json -Depth 30 -Compress)-ceq$before) 'Evaluation changed an unknown time or discarded close failure'
}
Check 'CLI-mode-defaults-and-outer-forwarding-are-explicit' {
  foreach($ast in @($captureAst,$outerAst)){
    $parameters=@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'ReadComparisonMode'})
    Require ($parameters.Count-eq1-and$parameters[0].DefaultValue.Extent.Text-ceq"'None'") 'CLI needs an additive None-default mode'
  }
  Require ($outerSource-match"(?s)captureArguments[^\r\n]*ReadComparisonMode|ReadComparisonMode[^\r\n]*captureArguments") 'Outer does not forward explicit comparison selection to capture'
  Require ($outerSource.Contains('read_comparison_mode')) 'Fresh permit must bind comparison selection'
  $helper=[IO.File]::ReadAllText((Join-Path $RepoRoot 'tools/r19_timed_path_outer.ps1'))
  Require ($helper.Contains('ReadComparisonMode')-and$helper.Contains('read_comparison_mode')) 'Prepared pin must bind exact comparison selection'
}
Check 'capture-keeps-one-owner-uses-pause-not-Close-or-Purge-as-intervention' {
  Require ($captureSource.Contains('RequestDiagnosticReadPause')-and$captureSource.Contains('read_comparison')) 'Native owner pause and additive evidence must be integrated'
  Require ($captureSource.Contains('APPLICATION_READ_PAUSE_NOT_USB_IN_SUPPRESSION')) 'Physical-poll limitation missing'
  Require ($captureSource-notmatch'DiscardInBuffer|DiscardOutBuffer|PurgeComm') 'Comparison cannot purge serial data'
}
Check 'outer-childscope-evaluation-cannot-clobber-live-safety-or-output-options' {
  $calls=@($outerAst.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]-and$n.CommandElements.Count-ge1-and$n.CommandElements[0]-is[Management.Automation.Language.ScriptBlockExpressionAst]-and$n.Extent.Text.Contains('param($comparisonRepo,$capturedComparison)')-and$n.Extent.Text.Contains('Get-R19ReadComparisonEvaluation')},$true))
  Require ($calls.Count-eq1) 'Outer must use exactly one isolated definitions-only evaluation call'
  $actualCall=[scriptblock]::Create($calls[0].Extent.Text)
  & {
    param($Invocation,$FixtureRepo)
    $repo=$FixtureRepo;$Execute=[switch]$true;$OutputDirectory='FIXTURE_OUTER_OUTPUT_MUST_SURVIVE';$Mode='ExplicitHostArm';$ReadComparisonMode='GroundPauseResume'
    $AuxReadinessDiagnostics=[switch]$true;$DiagnosticUsbFailureDiagnostics=[switch]$true
    $HilAuthorization='R19_RUNTIME_FAIL_DIAGNOSTIC_HIL_ONE_RUN_NOT_ACCEPTANCE_NOT_DEPLOYMENT'
    $OperatorSafetyAttestation='PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED'
    $RollbackAuthorization='RESTORE_ACCEPTED_R18_AFTER_R19_HIL'
    $captureDocument=[pscustomobject]@{read_comparison=[pscustomobject]@{plan=(New-ComparisonPlan);evidence=(New-Observation)}}
    $r=. $Invocation
    Require ($r.valid-and$Execute.IsPresent-and$OutputDirectory-ceq'FIXTURE_OUTER_OUTPUT_MUST_SURVIVE'-and$Mode-ceq'ExplicitHostArm'-and$ReadComparisonMode-ceq'GroundPauseResume'-and$AuxReadinessDiagnostics.IsPresent-and$DiagnosticUsbFailureDiagnostics.IsPresent) 'Definitions import leaked capture defaults into outer execution scope'
    Require ($HilAuthorization-ceq'R19_RUNTIME_FAIL_DIAGNOSTIC_HIL_ONE_RUN_NOT_ACCEPTANCE_NOT_DEPLOYMENT'-and$RollbackAuthorization-ceq'RESTORE_ACCEPTED_R18_AFTER_R19_HIL'-and$OperatorSafetyAttestation-ceq'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED') 'Comparison import changed live safety/rollback tokens'
  } $actualCall $RepoRoot
}
. (Join-Path $RepoRoot 'tools/r19_timed_path_outer.ps1')
function New-MemoryPreparedPin {
  [pscustomobject]@{schema='vc-lora-r19-timed-path-prepared-run-v1';mode='ExplicitHostArm';candidate_id='fixture-read-comparison';latest_sha256=('A'*64);latest_path='runs/candidates/R19-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json';capture_seconds=40;product_budget_ms=106;acceptance_authorized=$false;deployment_authorized=$false;live_authorization_granted=$false;aux_readiness_diagnostics=$true;diagnostic_usb_failure_diagnostics=$true;vehicle_runtime_stage_address='0x3fcad390';ground_runtime_stage_address='0x3fca49a8';usb_role_capabilities=(Get-R19UsbRoleCapabilities -RepoRoot $RepoRoot -Mode ExplicitHostArm -Enabled $true);tools=@(Get-R19TimedPathOuterToolPaths -AuxReadinessDiagnostics $true -DiagnosticUsbFailureDiagnostics $true|ForEach-Object{[pscustomobject]@{path=$_;sha256=('B'*64)}})}
}
Check 'prepared-pin-missing-comparison-option-retains-None-only' {
  $pin=New-MemoryPreparedPin
  $null=Assert-R19TimedPathPreparedContract -Pin $pin -Mode ExplicitHostArm -AuxReadinessDiagnostics $true -DiagnosticUsbFailureDiagnostics $true
  $rejected=$false;try{$null=Assert-R19TimedPathPreparedContract -Pin $pin -Mode ExplicitHostArm -AuxReadinessDiagnostics $true -DiagnosticUsbFailureDiagnostics $true -ReadComparisonMode GroundPauseResume}catch{$rejected=$true}
  Require $rejected 'An old prepared pin must not authorize a new intervention'
}
Check 'prepared-pin-explicit-comparison-binding-and-no-authority-widening' {
  $pin=New-MemoryPreparedPin;$pin|Add-Member NoteProperty read_comparison_mode GroundPauseResume
  $null=Assert-R19TimedPathPreparedContract -Pin $pin -Mode ExplicitHostArm -AuxReadinessDiagnostics $true -DiagnosticUsbFailureDiagnostics $true -ReadComparisonMode GroundPauseResume
  foreach($bad in @('None-mode','unknown-mode','authority')){
    $mutated=Clone $pin;$selected='GroundPauseResume'
    if($bad-ceq'None-mode'){$selected='None'}elseif($bad-ceq'unknown-mode'){$mutated.read_comparison_mode='AnythingElse'}else{$mutated.live_authorization_granted=$true}
    $rejected=$false;try{$null=Assert-R19TimedPathPreparedContract -Pin $mutated -Mode ExplicitHostArm -AuxReadinessDiagnostics $true -DiagnosticUsbFailureDiagnostics $true -ReadComparisonMode $selected}catch{$rejected=$true}
    Require $rejected ('Prepared option/authority mismatch not rejected: '+$bad)
  }
}
function New-MemoryPermit {
  [pscustomobject]@{schema='vc-lora-r19-timed-path-execution-permit-v1';status='AUTHORIZED_SINGLE_CAPTURE';candidate_id='fixture-read-comparison';mode='ExplicitHostArm';safety_confirmed=$true;one_time=$true;restore_required=$true;handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);issued_utc='2026-10-23T00:00:00Z';expires_utc='2026-10-23T00:01:00Z';capture_seconds=40;ports=@(
    [pscustomobject]@{role='vehicle';port='COM3';baud=115200;pnp_instance_id='FIXTURE-VEHICLE';usb_parent_instance_id='FIXTURE-PARENT-VEHICLE'},
    [pscustomobject]@{role='ground';port='COM6';baud=57600;pnp_instance_id='FIXTURE-GROUND';usb_parent_instance_id='FIXTURE-PARENT-GROUND'})}
}
function Invoke-MemoryPermitCheck($Permit,[string]$Selection='None') {
  Test-R19TimedPathExecutionPermit -Permit $Permit -Mode ExplicitHostArm -CandidateId fixture-read-comparison -HandoffSha256 ('A'*64) -FlashEvidenceSha256 ('B'*64) -NowUtc ([DateTime]::Parse('2026-10-23T00:00:30Z').ToUniversalTime()) -ReadComparisonMode $Selection
}
Check 'execution-permit-legacy-None-does-not-authorize-pause' {
  $permit=New-MemoryPermit;$null=Invoke-MemoryPermitCheck $permit None
  $rejected=$false;try{$null=Invoke-MemoryPermitCheck $permit GroundPauseResume}catch{$rejected=$true}
  Require $rejected 'An old permit authorized a new pause intervention'
}
Check 'execution-permit-exact-new-mode-binding-is-required' {
  $permit=New-MemoryPermit;$permit|Add-Member NoteProperty read_comparison_mode GroundPauseResume
  $null=Invoke-MemoryPermitCheck $permit GroundPauseResume
  $rejected=$false;try{$null=Invoke-MemoryPermitCheck $permit None}catch{$rejected=$true};Require $rejected 'New-mode permit reused for different capture option'
  $permit.read_comparison_mode='AnythingElse';$rejected=$false;try{$null=Invoke-MemoryPermitCheck $permit GroundPauseResume}catch{$rejected=$true};Require $rejected 'Malformed permit mode accepted'
}
Check 'execution-permit-pause-never-relaxes-freshness-or-rollback' {
  foreach($mutation in @('expired','restore-false')){
    $permit=New-MemoryPermit;$permit|Add-Member NoteProperty read_comparison_mode GroundPauseResume
    if($mutation-ceq'expired'){$permit.expires_utc='2026-10-23T00:00:20Z'}else{$permit.restore_required=$false}
    $rejected=$false;try{$null=Invoke-MemoryPermitCheck $permit GroundPauseResume}catch{$rejected=$true};Require $rejected ('Mode widened authority: '+$mutation)
  }
}
function New-MemoryCaptureState([string]$Role){
  [pscustomobject]@{spec=[pscustomobject]@{role=$Role;port=$(if($Role-ceq'ground'){'COM6'}else{'COM3'});baud=$(if($Role-ceq'ground'){57600}else{115200})};reader_id=('fixture-'+$Role+'-owner');nonce='123';open_before_ticks='1';open_after_ticks='2';read_started_ticks='3';opened=$true;joined=$true;cleanup_close_fallback=$false
    snapshot=[pscustomobject]@{ByteCount=0;Overflow=$false;Failure='';CleanupFailure='';Blocks=@()};raw=[byte[]]@();workflow=$null;workflow_failure='';writes=[Collections.Generic.List[object]]::new();observations=[Collections.Generic.List[object]]::new();product_observations=[Collections.Generic.List[object]]::new()}
}
function New-MemoryCaptureContext {
  [pscustomobject]@{candidate_id='fixture-candidate';mode='ExplicitHostArm';capture_seconds=40;started_utc='2026-10-23T00:00:00Z';clock_domain_id='fixture-shared-qpc';frequency='10000000';measurement_start_ticks='10000000';measurement_end_ticks='410000000';cleanup_proven=$true;hardware_interaction=$false;serial_write_calls=0;failure='';identity_evidence=@();pinned_inputs=@();handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);repo_root=$RepoRoot}
}
Check 'real-snapshot-metadata-maps-lifecycle-pause-duration-and-unobserved-null' {
  $nativeSource=[IO.File]::ReadAllText((Join-Path $RepoRoot 'tools/r19_continuous_reader.cs'))
  $begin=$nativeSource.IndexOf('namespace VcLora.R19 {',[StringComparison]::Ordinal)
  $end=$nativeSource.IndexOf('    public sealed class ContinuousReader {',[StringComparison]::Ordinal)
  Require ($begin-ge0-and$end-gt$begin) 'Real immutable snapshot metadata not found'
  $metadata=$nativeSource.Substring($begin,$end-$begin)+[Environment]::NewLine+'}'
  Require ($metadata-notmatch'SerialPort|Thread|DllImport|Process|IStartupReadSource') 'Only inert C# metadata may be compiled'
  Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $metadata
  $states=@(foreach($role in @('vehicle','ground')){
    $s=New-MemoryCaptureState $role;$n=[VcLora.R19.ContinuousSnapshot]::new();$n.Failure='';$n.CleanupFailure='';$n.CloseAttempted=$true;$n.CloseCompleted=$true;$n.CloseFailure=''
    $n.StopRequestedTicks=410000010;$n.WorkerStoppedTicks=410000020;$n.CloseStartTicks=410000030;$n.CloseEndTicks=410000040
    $n.DiagnosticPauseRequestedTicks=-1;$n.DiagnosticPauseBeginTicks=-1;$n.DiagnosticPauseEndTicks=-1;$n.DiagnosticPauseResumedReadTicks=-1
    $n.DiagnosticPauseBeginCalls=-1;$n.DiagnosticPauseEndCalls=-1;$n.DiagnosticPauseEndReason=''
    if($role-ceq'ground'){$n.DiagnosticPauseRequestedTicks=210000000;$n.DiagnosticPauseBeginTicks=210000100;$n.DiagnosticPauseEndTicks=230000100;$n.DiagnosticPauseResumedReadTicks=230000200;$n.DiagnosticPauseBeginCalls=17;$n.DiagnosticPauseEndCalls=17;$n.DiagnosticPauseMilliseconds=2000;$n.DiagnosticPauseEndReason='Deadline'}
    $s.snapshot=$n;$s
  })
  $e=Get-R19ReadComparisonEvidence -States $states -Context (New-MemoryCaptureContext);$g=$e.roles[1];$v=$e.roles[0]
  Require ($g.pause.duration_ms-eq2000-and$g.pause.begin_calls-eq17-and$g.pause.end_calls-eq17-and$g.pause.resumed_read_ticks-ceq'230000200'-and$g.pause.end_reason-ceq'Deadline') 'Actual native DiagnosticPauseMilliseconds or pause witness was dropped during projection'
  Require ($g.lifecycle.stop_requested_ticks-ceq'410000010'-and$g.lifecycle.worker_stopped_ticks-ceq'410000020'-and$g.lifecycle.close_start_ticks-ceq'410000030'-and$g.lifecycle.close_end_ticks-ceq'410000040'-and$g.lifecycle.close_attempted-and$g.lifecycle.close_completed-and$g.lifecycle.close_failure-ceq'') 'Actual native lifecycle ledger mapping changed'
  Require ($null-eq$v.pause.requested_ticks-and$null-eq$v.pause.begin_ticks-and$null-eq$v.pause.end_ticks-and$null-eq$v.pause.resumed_read_ticks-and-not$v.pause.requested-and$v.reader_continuous-and-not$g.reader_continuous) 'Unobserved native ticks fabricated a timestamp or changed role continuity'
  Require ((Get-Evaluation $e).valid) 'Real metadata projection cannot be validated'
}
Check 'legacy-persistence-without-comparison-ledger-stays-compatible' {
  $directory=Join-Path $OutputDirectory 'persist-legacy';[void][IO.Directory]::CreateDirectory($directory)
  $s=Save-R19TimedPathCaptureEvidence -States @((New-MemoryCaptureState vehicle),(New-MemoryCaptureState ground)) -OutputDirectory $directory -Context (New-MemoryCaptureContext)
  Require ($s.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY'-and-not$s.acceptance_eligible-and-not$s.deployment_authorized-and-not$s.root_cause_proven) 'Legacy metadata became required or authority widened'
}
foreach($persistenceKind in @('missing-pause-end','close-failure')){
  Check ('persistence-retains-'+$persistenceKind+'-without-losing-raw') {
    $context=New-MemoryCaptureContext;$e=New-Observation
    if($persistenceKind-ceq'missing-pause-end'){$e.roles[1].pause.end_ticks=$null}else{
      $e.roles[1].lifecycle.close_completed=$false;$e.roles[1].lifecycle.close_failure='FIXTURE_CLOSE_FAILURE';$context.cleanup_proven=$false;$context.failure='FIXTURE_CLOSE_FAILURE'
    }
    $evaluation=Get-Evaluation $e
    $context|Add-Member NoteProperty read_comparison ([pscustomobject]@{plan=(New-ComparisonPlan);evidence=$e;evaluation=$evaluation})
    $directory=Join-Path $OutputDirectory ('persist-'+$persistenceKind);[void][IO.Directory]::CreateDirectory($directory)
    $s=Save-R19TimedPathCaptureEvidence -States @((New-MemoryCaptureState vehicle),(New-MemoryCaptureState ground)) -OutputDirectory $directory -Context $context
    $saved=[IO.File]::ReadAllText((Join-Path $directory 'summary.json'))|ConvertFrom-Json
    Require ($saved.read_comparison.evaluation.result-ceq'INVALID_COMPARISON'-and-not$saved.read_comparison.evaluation.valid) 'Invalid comparison was lost or converted into success'
    Require ([IO.File]::Exists((Join-Path $directory 'vehicle.raw.bin'))-and[IO.File]::Exists((Join-Path $directory 'ground.raw.bin'))) 'Comparison failure hid a raw role stream'
    Require (-not(@($saved.roles|Where-Object{$_.role-ceq'ground'})[0].reader_continuous)) 'Paused Ground owner was mislabelled continuous'
    Require (-not$saved.acceptance_eligible-and-not$saved.deployment_authorized-and-not$saved.root_cause_proven) 'Persistence widened authority'
    if($persistenceKind-ceq'missing-pause-end'){
      Require ($saved.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY'-and$null-eq$saved.read_comparison.evidence.roles[1].pause.end_ticks) 'Comparison-only invalidity corrupted raw capture or fabricated an end time'
    }else{
      Require ($saved.read_comparison.evidence.roles[1].lifecycle.close_failure-ceq'FIXTURE_CLOSE_FAILURE'-and-not$saved.cleanup_proven) 'Close failure ledger was discarded'
    }
  }
}
foreach($functionName in @('Assert-Condition','Get-Sha256','Read-JsonIfPresent','Get-CaptureDisposition')){
  $definitions=@($outerAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$functionName},$true))
  if($definitions.Count-ne1){throw 'Missing actual outer replay function: '+$functionName}
  . ([scriptblock]::Create($definitions[0].Extent.Text))
}
function Invoke-ActualOuterDispositionFixture([string]$Name,[string]$Selection='GroundPauseResume',[bool]$GroundContinuous=$false,[bool]$VehicleContinuous=$true,[string]$Mutation=''){
  # Only inert files/memory feed the REAL outer Get-CaptureDisposition AST.
  # The fixture's hardware_interaction=true is declared input, never device IO.
  $OutputDirectory=Join-Path $comparisonFixtureOutputDirectory ('actual-outer-'+$Name);[void][IO.Directory]::CreateDirectory($OutputDirectory)
  $captureDirectory=Join-Path $OutputDirectory 'capture';[void][IO.Directory]::CreateDirectory($captureDirectory)
  $utf8=[Text.UTF8Encoding]::new($false);$flashRecordPath=Join-Path $OutputDirectory 'flash.json';[IO.File]::WriteAllText($flashRecordPath,'{"synthetic_flash_evidence":true}',$utf8)
  [IO.File]::WriteAllText((Join-Path $OutputDirectory 'execution-permit.json.consumed'),'SYNTHETIC_CONSUMED_MARKER',$utf8)
  $candidate=[pscustomobject]@{artifact_id='fixture-candidate';handoff_sha256=('A'*64)}
  $timedPathEnabled=$true;$TimedPathMode='ExplicitHostArm';$ReadComparisonMode=$Selection
  $context=New-MemoryCaptureContext;$context.hardware_interaction=$true;$context.flash_evidence_sha256=Get-Sha256 $flashRecordPath
  $plan=if($Selection-ceq'GroundPauseResume'){New-ComparisonPlan}else{Get-R19ReadComparisonPlan}
  $observation=if($Selection-ceq'GroundPauseResume'){New-Observation}else{$null}
  $context|Add-Member NoteProperty read_comparison ([pscustomobject]@{plan=$plan;evidence=$observation;evaluation=(Get-R19ReadComparisonEvaluation -Plan $plan -Evidence $observation)})
  $states=@(foreach($role in @('vehicle','ground')){
    $s=New-MemoryCaptureState $role;if($role-ceq'vehicle'){$s.raw=[byte[]]@(10,11,12)}else{$s.raw=[byte[]]@(253,1,2,3)}
    $s.snapshot.ByteCount=$s.raw.Length;$s.snapshot.Blocks=@([pscustomobject]@{Offset=0;Count=$s.raw.Length;BeginTicks=100;EndTicks=110});$s
  })
  $summary=Save-R19TimedPathCaptureEvidence -States $states -OutputDirectory $captureDirectory -Context $context
  Require ($summary.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY') 'Synthetic raw roundtrip did not pass production persistence'
  @($summary.roles|Where-Object{$_.role-ceq'ground'})[0].reader_continuous=$GroundContinuous
  @($summary.roles|Where-Object{$_.role-ceq'vehicle'})[0].reader_continuous=$VehicleContinuous
  switch($Mutation){
    'raw-sha'{[IO.File]::WriteAllBytes((Join-Path $captureDirectory 'ground.raw.bin'),[byte[]]@(253,1,2,4))}
    'raw-byte-coverage'{@($summary.roles|Where-Object{$_.role-ceq'ground'})[0].raw_bytes=5}
    'comparison-mode'{$summary.read_comparison.plan.mode='None'}
    'nested-reader-id'{$summary.read_comparison.evidence.roles[1].reader_id='DIFFERENT_READER_OWNER'}
    'nested-continuity'{$summary.read_comparison.evidence.roles[1].reader_continuous=$true}
    'nested-clock-domain'{$summary.read_comparison.evidence.clock_domain_id='DIFFERENT_CLOCK_DOMAIN'}
    'nested-frequency'{$summary.read_comparison.evidence.frequency='10000001'}
    'nested-measurement-start'{$summary.read_comparison.evidence.measurement_start_ticks='10000001'}
    'nested-measurement-end'{$summary.read_comparison.evidence.measurement_end_ticks='410000001'}
    'missing-pause-end'{$summary.read_comparison.evidence.roles[1].pause.end_ticks=$null;$summary.read_comparison.evaluation=Get-R19ReadComparisonEvaluation -Plan $summary.read_comparison.plan -Evidence $summary.read_comparison.evidence}
  }
  [IO.File]::WriteAllText((Join-Path $captureDirectory 'summary.json'),($summary|ConvertTo-Json -Depth 50),$utf8)
  $step=[pscustomobject]@{exit_code=0;timed_out=$false;termination_proven=$true;process_tree_termination_proven=$true}
  $disposition=Get-CaptureDisposition $step
  [IO.File]::WriteAllText((Join-Path $OutputDirectory 'disposition.json'),($disposition|ConvertTo-Json -Depth 30),$utf8)
  $disposition
}
Check 'actual-outer-disposition-admits-requested-paused-Ground-with-exact-raw-roundtrip' {
  $r=Invoke-ActualOuterDispositionFixture 'paused-ground'
  Require ($r.acceptable-and$r.evidence_contract_proven) ('Actual outer blocked paused Ground before stage acquisition: '+($r.rejection_reasons-join';'))
  $incomplete=Invoke-ActualOuterDispositionFixture 'incomplete-pause-still-acquires-stage' GroundPauseResume $false $true 'missing-pause-end'
  Require ($incomplete.acceptable-and$incomplete.evidence_contract_proven) 'Comparison-only invalidity blocked stage acquisition despite intact raw/owner/clock evidence'
}
Check 'actual-outer-disposition-preserves-None-continuous-baseline' {
  $r=Invoke-ActualOuterDispositionFixture 'none-continuous' None $true $true
  Require ($r.acceptable-and$r.evidence_contract_proven) ('Actual outer legacy baseline rejected: '+($r.rejection_reasons-join';'))
}
Check 'actual-outer-disposition-rejects-wrong-reader-flags-or-corrupt-raw-coverage' {
  foreach($case in @('Vehicle-false','None-Ground-false','Pause-Ground-true','raw-sha','raw-byte-coverage','comparison-mode')){
    $selection='GroundPauseResume';$groundContinuous=$false;$vehicleContinuous=$true;$mutation=''
    switch($case){'Vehicle-false'{$vehicleContinuous=$false};'None-Ground-false'{$selection='None'};'Pause-Ground-true'{$groundContinuous=$true};default{$mutation=$case}}
    $r=Invoke-ActualOuterDispositionFixture ('reject-'+$case) $selection $groundContinuous $vehicleContinuous $mutation
    Require (-not$r.acceptable-and-not$r.evidence_contract_proven-and@($r.rejection_reasons).Count-gt0) ('Actual outer admitted unsafe reader/raw binding: '+$case)
  }
}
Check 'actual-outer-disposition-binds-nested-owner-and-clock-to-actual-capture' {
  foreach($mutation in @('nested-reader-id','nested-continuity','nested-clock-domain','nested-frequency','nested-measurement-start','nested-measurement-end')){
    $r=Invoke-ActualOuterDispositionFixture ('reject-'+$mutation) GroundPauseResume $false $true $mutation
    Require (-not$r.acceptable-and-not$r.evidence_contract_proven-and@($r.rejection_reasons).Count-gt0) ('Actual outer admitted mismatched comparison/capture binding: '+$mutation)
  }
}
$failed=@($results|Where-Object{-not$_.passed})
$summary=[ordered]@{schema='vc-lora-r19-read-comparison-capture-contract-v1';result=$(if($failed.Count){'FAIL'}else{'PASS'});checks=$results.ToArray();passed_count=$results.Count-$failed.Count;failed_count=$failed.Count;hardware_interaction=$false;child_execute_calls=0;native_process_or_device_inspection=$false;capture_source_sha256=(Get-FileHash -LiteralPath $capturePath).Hash}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'summary.json'),($summary|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
$summary|ConvertTo-Json -Depth 30
if($failed.Count){exit 1}
