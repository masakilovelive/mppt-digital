param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $RepoRoot 'tools/r19_timed_path_outer.ps1')
. (Join-Path $RepoRoot 'tools/r19_timed_path_acquisition.ps1') -ImportOnly
$script:checks=0
function Check([bool]$Value,[string]$Name){if(-not$Value){throw "FAIL $Name"};$script:checks++}
function Reject([scriptblock]$Action,[string]$Name){$bad=$false;try{& $Action|Out-Null}catch{$bad=$true};Check $bad $Name}
function Clone($Value){$copy=$Value|ConvertTo-Json -Depth 30|ConvertFrom-Json;foreach($name in @('issued_utc','expires_utc')){if($null-ne$Value.PSObject.Properties[$name]){$copy.$name=[string]$Value.$name}};return $copy}
$base=@{AuxReadinessDiagnostics=$true;DiagnosticUsbFailureDiagnostics=$true}
Check (@(Get-R19TimedPathOuterToolPaths @base).Count-eq20) 'legacy twenty-tool set remains unchanged'
$paths=@(Get-R19TimedPathOuterToolPaths @base -ParamListDiagnostics $true)
Check ($paths.Count-eq21-and@($paths|Where-Object{$_-ceq'tools/r19_param_list_diagnostics.ps1'}).Count-eq1) 'opt-in pins twenty-one tools including exact helper'
Reject {Get-R19TimedPathOuterToolPaths -ParamListDiagnostics $true} 'tool set requires full diagnostics'
$now=[DateTime]::UtcNow
$permit=[pscustomobject]@{schema='vc-lora-r19-timed-path-execution-permit-v1';status='AUTHORIZED_SINGLE_CAPTURE';candidate_id='param-list-test';mode='ExplicitHostArm';handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);issued_utc=$now.AddSeconds(-1).ToString('o');expires_utc=$now.AddSeconds(60).ToString('o');safety_confirmed=$true;one_time=$true;restore_required=$true;capture_seconds=40;ports=@([pscustomobject]@{role='vehicle';port='COM3';baud=115200;pnp_instance_id='USB\V';usb_parent_instance_id='USB\PV'},[pscustomobject]@{role='ground';port='COM6';baud=57600;pnp_instance_id='USB\G';usb_parent_instance_id='USB\PG'})}
$permitArgs=@{Mode='ExplicitHostArm';CandidateId='param-list-test';HandoffSha256=('A'*64);FlashEvidenceSha256=('B'*64);NowUtc=$now}
Check ((Test-R19TimedPathExecutionPermit -Permit $permit @permitArgs).valid) 'legacy permit defaults false'
Reject {Test-R19TimedPathExecutionPermit -Permit $permit @permitArgs -ParamListDiagnostics $true} 'legacy permit cannot escalate to parameter load'
$enabled=Clone $permit;Add-Member -InputObject $enabled -NotePropertyName param_list_diagnostics -NotePropertyValue $true
Check ((Test-R19TimedPathExecutionPermit -Permit $enabled @permitArgs -ParamListDiagnostics $true).valid) 'new permit authorizes only exact option'
Reject {Test-R19TimedPathExecutionPermit -Permit $enabled @permitArgs} 'permit cannot downgrade to no-load capture'
Reject {Test-R19TimedPathExecutionPermit -Permit $enabled @permitArgs -ParamListDiagnostics $true -ReadComparisonMode GroundPauseResume} 'parameter load and reader pause cannot combine'
foreach($value in @('true',1,$null)){$bad=Clone $enabled;$bad.param_list_diagnostics=$value;Reject {Test-R19TimedPathExecutionPermit -Permit $bad @permitArgs -ParamListDiagnostics $true} 'permit option must be typed boolean'}
$pin=[pscustomobject]@{schema='vc-lora-r19-timed-path-prepared-run-v1';mode='ExplicitHostArm';candidate_id='param-list-test';latest_sha256=('C'*64);latest_path='runs/candidates/R19-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json';capture_seconds=40;product_budget_ms=106;acceptance_authorized=$false;deployment_authorized=$false;live_authorization_granted=$false;vehicle_runtime_stage_address='0x3fcad7f0';ground_runtime_stage_address='0x3fca4b68';aux_readiness_diagnostics=$true;diagnostic_usb_failure_diagnostics=$true;tools=@(Get-R19TimedPathOuterToolPaths @base|ForEach-Object{[pscustomobject]@{path=$_;sha256=('D'*64)}});usb_role_capabilities=[pscustomobject]@{schema='vc-lora-r19-usb-role-capabilities-v1';mode='ExplicitHostArm';implementation_bound=$true;roles=@([pscustomobject]@{role='vehicle';effective_mode='SyncOnly';clock_request_reply=$true;ready=$false;arm=$false},[pscustomobject]@{role='ground';effective_mode='ExplicitHostArm';clock_request_reply=$true;ready=$true;arm=$true});canonical_sources=@('firmware/phase6/vc_lora_phase6_bridge.hpp','firmware/high_speed/r19_diagnostic_usb_failure_record.hpp','tools/r19_usb_role_contract.ps1'|ForEach-Object{[pscustomobject]@{path=$_;sha256=('E'*64)}})}}
Check ($null-ne(Assert-R19TimedPathPreparedContract -Pin $pin -Mode ExplicitHostArm @base)) 'legacy twenty-tool pin remains accepted'
Reject {Assert-R19TimedPathPreparedContract -Pin $pin -Mode ExplicitHostArm @base -ParamListDiagnostics $true} 'old pin cannot escalate'
$prepared=Clone $pin;Add-Member -InputObject $prepared -NotePropertyName param_list_diagnostics -NotePropertyValue $true
$prepared.tools=@($paths|ForEach-Object{[pscustomobject]@{path=$_;sha256=('D'*64)}})
Check ($null-ne(Assert-R19TimedPathPreparedContract -Pin $prepared -Mode ExplicitHostArm @base -ParamListDiagnostics $true)) 'fresh twenty-one-tool pin exact opt-in'
Reject {Assert-R19TimedPathPreparedContract -Pin $prepared -Mode ExplicitHostArm @base} 'pin cannot downgrade'
Reject {Assert-R19TimedPathPreparedContract -Pin $prepared -Mode ExplicitHostArm @base -ParamListDiagnostics $true -ReadComparisonMode GroundPauseResume} 'pin cannot combine interventions'
foreach($value in @('true',1,$null)){$bad=Clone $prepared;$bad.param_list_diagnostics=$value;Reject {Assert-R19TimedPathPreparedContract -Pin $bad -Mode ExplicitHostArm @base -ParamListDiagnostics $true} 'pin option must be typed boolean'}
$bad=Clone $prepared;$bad.tools=@($bad.tools|Where-Object{$_.path-cne'tools/r19_param_list_diagnostics.ps1'});Reject {Assert-R19TimedPathPreparedContract -Pin $bad -Mode ExplicitHostArm @base -ParamListDiagnostics $true} 'missing helper hash rejected'
$capture=[pscustomobject]@{schema='vc-lora-r19-timed-path-capture-v1';result='CAPTURE_COMPLETE_OBSERVATIONS_ONLY';candidate_id='param-list-test';mode='ExplicitHostArm';capture_seconds=40;cleanup_proven=$true;hardware_interaction=$true;acceptance_eligible=$false;deployment_authorized=$false;clock_domain_id='fixture-qpc';frequency='10000000';measurement_start_ticks='10000000';measurement_end_ticks='410000000'}
$step=[pscustomobject]@{exit_code=0;timed_out=$false;termination_proven=$true;process_tree_termination_proven=$true}
Check ((Get-R19TimedPathOuterCaptureDisposition -Summary $capture -Step $step -CandidateId param-list-test -Mode ExplicitHostArm).acceptable) 'legacy capture remains acceptable'
Check (-not(Get-R19TimedPathOuterCaptureDisposition -Summary $capture -Step $step -CandidateId param-list-test -Mode ExplicitHostArm -ParamListDiagnostics $true).acceptable) 'enabled capture requires additive ledger'
$load=Clone $capture;Add-Member -InputObject $load -NotePropertyName param_list_diagnostics_enabled -NotePropertyValue $true
Add-Member -InputObject $load -NotePropertyName serial_write_calls -NotePropertyValue 4
Add-Member -InputObject $load -NotePropertyName roles -NotePropertyValue @([pscustomobject]@{role='vehicle';writes=@([pscustomobject]@{kind='ClockRequest'})},[pscustomobject]@{role='ground';writes=@([pscustomobject]@{kind='ClockRequest'},[pscustomobject]@{kind='Arm'})})
Add-Member -InputObject $load -NotePropertyName param_list_diagnostics -NotePropertyValue ([pscustomobject]@{schema='vc-lora-r19-param-list-diagnostics-v1';target_count=932;deadline_us='30000000';clock_domain_id='fixture-qpc';frequency='10000000';request_attempts=1;request=[pscustomobject]@{write_started_ticks='20000000';write_returned_ticks='20001000';accepted_bytes=14;api_exception_type='';local_write_api_accepted_only=$true;delivery_proven=$false;expected_bytes=14;frame_sha256='FC3A47A83D35D44E96E044A216FDBF082805F9FACCDD5E4B9252E0C7026D4A75'};snapshot_30s=[pscustomobject]@{all_932_received=$false;result='TARGET_NOT_MET'};final=[pscustomobject]@{all_932_received=$false;result='TARGET_NOT_MET'};acceptance_eligible=$false;deployment_authorized=$false})
function Disposition($Value){Get-R19TimedPathOuterCaptureDisposition -Summary $Value -Step $step -CandidateId param-list-test -Mode ExplicitHostArm -ParamListDiagnostics $true}
Check ((Disposition $load).acceptable) 'thirty-second target miss admits raw and JTAG evidence'
Check (-not(Get-R19TimedPathOuterCaptureDisposition -Summary $load -Step $step -CandidateId param-list-test -Mode ExplicitHostArm).acceptable) 'capture ledger cannot downgrade enabled operation'
foreach($field in @('target_count','deadline_us','request_attempts','acceptance_eligible','deployment_authorized')){
  $bad=Clone $load
  switch($field){'target_count'{$bad.param_list_diagnostics.target_count=931};'deadline_us'{$bad.param_list_diagnostics.deadline_us='30000001'};'request_attempts'{$bad.param_list_diagnostics.request_attempts=2};default{$bad.param_list_diagnostics.$field=$true}}
  Check (-not(Disposition $bad).acceptable) ('reject ledger '+$field)
}
foreach($field in @('delivery_proven','local_write_api_accepted_only')){$bad=Clone $load;$bad.param_list_diagnostics.request.$field=-not$bad.param_list_diagnostics.request.$field;Check (-not(Disposition $bad).acceptable) ('reject request claim '+$field)}
$bad=Clone $load;$bad.param_list_diagnostics.request.frame_sha256=('F'*64);Check (-not(Disposition $bad).acceptable) 'request must bind frozen exact bytes'
$bad=Clone $load;$bad.param_list_diagnostics.request.expected_bytes=15;Check (-not(Disposition $bad).acceptable) 'request expected byte length cannot change'
foreach($count in @(0,7,14)){$partial=Clone $load;$partial.param_list_diagnostics.request.accepted_bytes=$count;Check ((Disposition $partial).acceptable) 'local partial write is diagnostic not acquired-data rejection'}
$bad=Clone $load;$bad.param_list_diagnostics.frequency='1000';Check (-not(Disposition $bad).acceptable) 'ledger must bind same PC frequency'
$bad=Clone $load;$bad.param_list_diagnostics.request.write_started_ticks='9000000';Check (-not(Disposition $bad).acceptable) 'request cannot precede measurement window'
$bad=Clone $load;$bad.param_list_diagnostics_enabled='true';Check (-not(Disposition $bad).acceptable) 'capture enable field must be boolean'
$bad=Clone $load;$bad.serial_write_calls=3;Check (-not(Disposition $bad).acceptable) 'request attempt binds actual serial write ledger count'
$notAttempted=Clone $load;$notAttempted.param_list_diagnostics.request_attempts=0;$notAttempted.param_list_diagnostics.request=$null
$notAttempted.serial_write_calls=3
Check ((Disposition $notAttempted).acceptable) 'unmet readiness no-request diagnostic still permits internal records'
$normalized=[pscustomobject]@{schema='vc-lora-r19-timed-path-normalization-v1'}
$outcome=Get-R19TimedPathOuterOutcome -Evaluation $normalized -Failure '' -Saved $true -ParamListDiagnostics $true -ParamListEvaluation $load.param_list_diagnostics
Check ($outcome.result-ceq'PASS'-and$outcome.status-ceq'PASS_PARAM_LIST_DIAGNOSTICS_CAPTURED_R18_RESTORED_NOT_ACCEPTANCE'-and-not$outcome.acceptance_eligible) 'target miss is acquired diagnostics not product acceptance'
Check ((Get-R19TimedPathOuterOutcome -Evaluation $normalized -Failure '' -Saved $true -ParamListDiagnostics $true -ParamListEvaluation $null).result-ceq'FAIL') 'missing ledger cannot yield diagnostic acquisition PASS'
Check ((Get-R19TimedPathOuterOutcome -Evaluation $normalized -Failure 'stage read failure' -Saved $true -ParamListDiagnostics $true -ParamListEvaluation $load.param_list_diagnostics).result-ceq'FAIL') 'new diagnostic mode cannot erase primary failure'
$outerPath=Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1'
$tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($outerPath,[ref]$tokens,[ref]$parseErrors)
Check ($parseErrors.Count-eq0) 'parent outer parses'
$nodes=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Get-CaptureDisposition'},$true))
Check ($nodes.Count-eq1) 'actual parent disposition exists exactly once'
& {
  param($FunctionText,$Fixture,$StepFixture)
  . ([scriptblock]::Create($FunctionText))
  function Assert-Condition([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}
  function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
  function Read-JsonIfPresent([string]$Path){Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}
  $OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('r19-param-outer-'+[Guid]::NewGuid().ToString('N'))
  $captureDirectory=Join-Path $OutputDirectory 'capture';[void][IO.Directory]::CreateDirectory($captureDirectory)
  $flashRecordPath=Join-Path $OutputDirectory 'flash_record.json';[IO.File]::WriteAllText($flashRecordPath,'{}')
  [IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'execution-permit.json.consumed'),[byte[]]@())
  $candidate=[pscustomobject]@{artifact_id='param-list-test';handoff_sha256=('A'*64)}
  $timedPathEnabled=$true;$TimedPathMode='ExplicitHostArm';$ReadComparisonMode='None';$ParamListDiagnostics=[switch]$true
  $summary=Clone $Fixture
  Add-Member -InputObject $summary -NotePropertyName handoff_sha256 -NotePropertyValue $candidate.handoff_sha256
  Add-Member -InputObject $summary -NotePropertyName flash_evidence_sha256 -NotePropertyValue (Get-Sha256 $flashRecordPath)
  foreach($row in $summary.roles){$rawPath=Join-Path $captureDirectory ($row.role+'.raw.bin');[IO.File]::WriteAllBytes($rawPath,[byte[]]@());foreach($field in @{raw_bytes=0;raw_sha256=(Get-Sha256 $rawPath);raw_base64='';reader_continuous=$true;overflow=$false;clock_domain_id=$summary.clock_domain_id;frequency=$summary.frequency}.GetEnumerator()){Add-Member -InputObject $row -NotePropertyName $field.Key -NotePropertyValue $field.Value}}
  $summaryPath=Join-Path $captureDirectory 'summary.json';[IO.File]::WriteAllText($summaryPath,($summary|ConvertTo-Json -Depth 30))
  Check ((Get-CaptureDisposition $StepFixture).acceptable) 'actual parent admits incomplete target for internal JTAG records'
  $ParamListDiagnostics=[switch]$false
  Check (-not(Get-CaptureDisposition $StepFixture).acceptable) 'actual parent rejects unrequested load ledger'
  $ParamListDiagnostics=[switch]$true;$summary.serial_write_calls=3;[IO.File]::WriteAllText($summaryPath,($summary|ConvertTo-Json -Depth 30))
  Check (-not(Get-CaptureDisposition $StepFixture).acceptable) 'actual parent rejects forged request count'
} $nodes[0].Extent.Text $load $step
Write-Output "R19_PARAM_LIST_OUTER_CONTRACT PASS $script:checks checks"
