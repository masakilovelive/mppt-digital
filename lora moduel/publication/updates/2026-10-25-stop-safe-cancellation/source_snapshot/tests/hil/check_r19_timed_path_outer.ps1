param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:n=0
function Check($v,$name){if(-not$v){throw "FAIL $name"};$script:n++}
function Reject($action,$name){$threw=$false;try{&$action}catch{$threw=$true};Check $threw $name}
function Clone($v){$v|ConvertTo-Json -Depth 30|ConvertFrom-Json}
. (Join-Path $RepoRoot 'tools/r19_timed_path_outer.ps1')
$pin=[pscustomobject]@{schema='vc-lora-r19-timed-path-prepared-run-v1';mode='ExplicitHostArm';candidate_id='test-candidate';latest_sha256=('A'*64);latest_path='runs/candidates/R19-TIMED-PATH-EXPLICIT-HOST-ARM-DIAGNOSTIC-CANDIDATE-BUILD-001/latest.json';capture_seconds=40;product_budget_ms=106;acceptance_authorized=$false;deployment_authorized=$false;live_authorization_granted=$false;vehicle_runtime_stage_address='0x3fcab000';ground_runtime_stage_address='0x3fca2000';tools=@()}
foreach($path in (Get-R19TimedPathOuterToolPaths)){$pin.tools+= [pscustomobject]@{path=$path;sha256=('B'*64)}}
$ok=Assert-R19TimedPathPreparedContract $pin 'ExplicitHostArm'
Check ($ok.candidate_id-ceq'test-candidate') 'valid prepared pin'
foreach($name in @('schema','mode','candidate_id','latest_sha256','latest_path','vehicle_runtime_stage_address')){
  $bad=Clone $pin;$bad.$name='bad value';Reject {Assert-R19TimedPathPreparedContract $bad 'ExplicitHostArm'} "reject $name"
}
foreach($name in @('acceptance_authorized','deployment_authorized','live_authorization_granted')){
  $bad=Clone $pin;$bad.$name=$true;Reject {Assert-R19TimedPathPreparedContract $bad 'ExplicitHostArm'} "reject authorization $name"
  $bad=Clone $pin;$bad.$name='false';Reject {Assert-R19TimedPathPreparedContract $bad 'ExplicitHostArm'} "reject untyped $name"
}
$bad=Clone $pin;$bad.tools=@($pin.tools[0]);Reject {Assert-R19TimedPathPreparedContract $bad 'ExplicitHostArm'} 'missing tools'
$bad=Clone $pin;$bad.tools[0].sha256='x';Reject {Assert-R19TimedPathPreparedContract $bad 'ExplicitHostArm'} 'bad tool sha'
$bad=Clone $pin;$bad.tools[0].path='../outside.ps1';Reject {Assert-R19TimedPathPreparedContract $bad 'ExplicitHostArm'} 'outside tool'
$bad=Clone $pin;$bad.tools[0]=$bad.tools[1];Reject {Assert-R19TimedPathPreparedContract $bad 'ExplicitHostArm'} 'duplicate tool'
$bad=Clone $pin;$bad.product_budget_ms=500;Reject {Assert-R19TimedPathPreparedContract $bad 'ExplicitHostArm'} 'unchanged product budget'
$bad=Clone $pin;$bad.capture_seconds=300;Reject {Assert-R19TimedPathPreparedContract $bad 'ExplicitHostArm'} 'bounded capture'
$bad=Clone $pin;$bad.ground_runtime_stage_address=$bad.vehicle_runtime_stage_address;Reject {Assert-R19TimedPathPreparedContract $bad 'ExplicitHostArm'} 'distinct stage addresses'
Reject {Assert-R19TimedPathPreparedContract $pin 'SyncOnly'} 'cross mode'
$sync=Clone $pin;$sync.mode='SyncOnly';$sync.latest_path='runs/candidates/R19-TIMED-PATH-SYNC-ONLY-DIAGNOSTIC-CANDIDATE-BUILD-001/latest.json';Check ($null-ne(Assert-R19TimedPathPreparedContract $sync 'SyncOnly')) 'sync pin'
$summary=[pscustomobject]@{schema='vc-lora-r19-timed-path-capture-v1';result='CAPTURE_COMPLETE_OBSERVATIONS_ONLY';candidate_id='test-candidate';mode='ExplicitHostArm';capture_seconds=40;cleanup_proven=$true;hardware_interaction=$true;acceptance_eligible=$false;deployment_authorized=$false}
$step=[pscustomobject]@{exit_code=0;timed_out=$false;termination_proven=$true;process_tree_termination_proven=$true}
$d=Get-R19TimedPathOuterCaptureDisposition $summary $step 'test-candidate' 'ExplicitHostArm';Check $d.acceptable 'capture acquisition allowed for JTAG not product pass'
foreach($name in @('candidate_id','mode','schema','result')){$bad=Clone $summary;$bad.$name='bad';Check (-not(Get-R19TimedPathOuterCaptureDisposition $bad $step 'test-candidate' 'ExplicitHostArm').acceptable) "capture reject $name"}
foreach($name in @('cleanup_proven','hardware_interaction')){$bad=Clone $summary;$bad.$name=$false;Check (-not(Get-R19TimedPathOuterCaptureDisposition $bad $step 'test-candidate' 'ExplicitHostArm').acceptable) "capture reject $name"}
$bad=Clone $step;$bad.termination_proven=$false;Check (-not(Get-R19TimedPathOuterCaptureDisposition $summary $bad 'test-candidate' 'ExplicitHostArm').acceptable) 'capture child must terminate'
$bad=Clone $summary;$bad.deployment_authorized=$true;Check (-not(Get-R19TimedPathOuterCaptureDisposition $bad $step 'test-candidate' 'ExplicitHostArm').acceptable) 'never deployment'
Check ((Get-R19TimedPathOuterOutcome -Evaluation $null -Failure '' -Saved $false).result-ceq'FAIL') 'missing normalization never legacy pass'
Check ((Get-R19TimedPathOuterOutcome -Evaluation ([pscustomobject]@{}) -Failure 'JSON write failed' -Saved $false).result-ceq'FAIL') 'failed durable write never pass'
Check ((Get-R19TimedPathOuterOutcome -Evaluation ([pscustomobject]@{schema='vc-lora-r19-timed-path-normalization-v1'}) -Failure '' -Saved $true).result-ceq'PASS') 'acquisition-only terminal'
$source=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1') -Raw
foreach($term in @('TimedPathMode','TimedPathPreparedPinSha256','run_r19_timed_path_capture.ps1','execution-permit.json','ConvertTo-R19TimedPathEvidence','timed_path_evaluation.json')){Check ($source.Contains($term)) "outer integrates $term"}
Write-Output "TIMED_PATH_OUTER PASS $script:n checks"
