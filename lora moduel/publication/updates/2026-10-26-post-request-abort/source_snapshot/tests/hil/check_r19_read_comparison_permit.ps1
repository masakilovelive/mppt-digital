param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $RepoRoot 'tools/r19_timed_path_outer.ps1')
. (Join-Path $RepoRoot 'tools/r19_timed_path_acquisition.ps1') -ImportOnly
$script:checks=0
function Check([bool]$Value,[string]$Name){if(-not$Value){throw "FAIL $Name"};$script:checks++}
function Reject([scriptblock]$Code,[string]$Name){$bad=$false;try{& $Code|Out-Null}catch{$bad=$true};Check $bad $Name}
function CopyFixture($Value){$Value|ConvertTo-Json -Depth 30|ConvertFrom-Json}
$now=[DateTime]::UtcNow
$permit=[pscustomobject]@{schema='vc-lora-r19-timed-path-execution-permit-v1';status='AUTHORIZED_SINGLE_CAPTURE';candidate_id='comparison-test';mode='ExplicitHostArm';handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);issued_utc=$now.AddSeconds(-1).ToString('o');expires_utc=$now.AddSeconds(60).ToString('o');safety_confirmed=$true;one_time=$true;restore_required=$true;capture_seconds=40;ports=@([pscustomobject]@{role='vehicle';port='COM3';baud=115200;pnp_instance_id='USB\VEHICLE';usb_parent_instance_id='USB\PARENT_V'},[pscustomobject]@{role='ground';port='COM6';baud=57600;pnp_instance_id='USB\GROUND';usb_parent_instance_id='USB\PARENT_G'})}
$argsPermit=@{Mode='ExplicitHostArm';CandidateId='comparison-test';HandoffSha256=('A'*64);FlashEvidenceSha256=('B'*64);NowUtc=$now}
Check ((Test-R19TimedPathExecutionPermit -Permit $permit @argsPermit).valid) 'legacy default remains permitted'
Reject {Test-R19TimedPathExecutionPermit -Permit $permit @argsPermit -ReadComparisonMode GroundPauseResume} 'comparison requires explicit permit field'
$cp=CopyFixture $permit;Add-Member -InputObject $cp -NotePropertyName read_comparison_mode -NotePropertyValue GroundPauseResume
Check ((Test-R19TimedPathExecutionPermit -Permit $cp @argsPermit -ReadComparisonMode GroundPauseResume).valid) 'exact comparison permission'
Reject {Test-R19TimedPathExecutionPermit -Permit $cp @argsPermit} 'comparison permit cannot be consumed by legacy capture'
$cp.read_comparison_mode='None'
Reject {Test-R19TimedPathExecutionPermit -Permit $cp @argsPermit -ReadComparisonMode GroundPauseResume} 'permit mismatch blocks comparison'
$cp.read_comparison_mode=$true
Reject {Test-R19TimedPathExecutionPermit -Permit $cp @argsPermit} 'permit enum must be string'
$pin=[pscustomobject]@{schema='vc-lora-r19-timed-path-prepared-run-v1';mode='ExplicitHostArm';candidate_id='comparison-test';latest_sha256=('C'*64);latest_path='runs/candidates/R19-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json';capture_seconds=40;product_budget_ms=106;acceptance_authorized=$false;deployment_authorized=$false;live_authorization_granted=$false;vehicle_runtime_stage_address='0x3fcad7f0';ground_runtime_stage_address='0x3fca4b68';aux_readiness_diagnostics=$true;diagnostic_usb_failure_diagnostics=$true;tools=@(Get-R19TimedPathOuterToolPaths -AuxReadinessDiagnostics $true -DiagnosticUsbFailureDiagnostics $true|ForEach-Object{[pscustomobject]@{path=$_;sha256=('D'*64)}});usb_role_capabilities=[pscustomobject]@{schema='vc-lora-r19-usb-role-capabilities-v1';mode='ExplicitHostArm';implementation_bound=$true;roles=@([pscustomobject]@{role='vehicle';effective_mode='SyncOnly';clock_request_reply=$true;ready=$false;arm=$false},[pscustomobject]@{role='ground';effective_mode='ExplicitHostArm';clock_request_reply=$true;ready=$true;arm=$true});canonical_sources=@('firmware/phase6/vc_lora_phase6_bridge.hpp','firmware/high_speed/r19_diagnostic_usb_failure_record.hpp','tools/r19_usb_role_contract.ps1'|ForEach-Object{[pscustomobject]@{path=$_;sha256=('E'*64)}})}}
$argsPin=@{Mode='ExplicitHostArm';AuxReadinessDiagnostics=$true;DiagnosticUsbFailureDiagnostics=$true}
Check ($null-ne(Assert-R19TimedPathPreparedContract -Pin $pin @argsPin)) 'legacy diagnostic pin remains accepted'
Reject {Assert-R19TimedPathPreparedContract -Pin $pin @argsPin -ReadComparisonMode GroundPauseResume} 'old prepared pin cannot authorize read comparison'
$pp=CopyFixture $pin;Add-Member -InputObject $pp -NotePropertyName read_comparison_mode -NotePropertyValue GroundPauseResume
Check ($null-ne(Assert-R19TimedPathPreparedContract -Pin $pp @argsPin -ReadComparisonMode GroundPauseResume)) 'new prepared pin binds comparison'
Reject {Assert-R19TimedPathPreparedContract -Pin $pp @argsPin} 'new prepared pin cannot be downgraded to default'
$pp.read_comparison_mode='None'
Reject {Assert-R19TimedPathPreparedContract -Pin $pp @argsPin -ReadComparisonMode GroundPauseResume} 'prepared pin mismatch rejected'
$pp.read_comparison_mode=$false
Reject {Assert-R19TimedPathPreparedContract -Pin $pp @argsPin} 'prepared comparison field is typed'
$ev=[pscustomobject]@{schema='vc-lora-r19-read-comparison-evaluation-v1';mode='GroundPauseResume';result='VALID_COMPARISON';valid=$true;causal_disposition='INDETERMINATE';physical_host_in_suppression_proven=$false;acceptance_eligible=$false;deployment_authorized=$false;root_cause_proven=$false}
$result=Get-R19TimedPathOuterOutcome -Evaluation $null -Failure '' -Saved $true -ReadComparisonMode GroundPauseResume -ComparisonEvaluation $ev
Check ($result.result-ceq'PASS'-and$result.status-ceq'PASS_READ_COMPARISON_EVIDENCE_CAPTURED_R18_RESTORED_NOT_ACCEPTANCE'-and-not$result.acceptance_eligible) 'comparison outcome does not impersonate continuous trace'
foreach($field in @('valid','root_cause_proven','physical_host_in_suppression_proven','acceptance_eligible','deployment_authorized')){
  $bad=CopyFixture $ev;$bad.$field=-not[bool]$bad.$field
  Check ((Get-R19TimedPathOuterOutcome -Evaluation $null -Failure '' -Saved $true -ReadComparisonMode GroundPauseResume -ComparisonEvaluation $bad).result-ceq'FAIL') ('reject comparison outcome '+$field)
}
Check ((Get-R19TimedPathOuterOutcome -Evaluation $null -Failure '' -Saved $false -ReadComparisonMode GroundPauseResume -ComparisonEvaluation $ev).result-ceq'FAIL') 'unsaved comparison fails'
Check ((Get-R19TimedPathOuterOutcome -Evaluation $null -Failure 'capture failed' -Saved $true -ReadComparisonMode GroundPauseResume -ComparisonEvaluation $ev).result-ceq'FAIL') 'failure stays failure'
Write-Output "R19_READ_COMPARISON_PERMIT PASS $script:checks checks"
