[CmdletBinding()]
param([string]$RepoRoot='',[string]$OutputDirectory='',[switch]$OmittedFatalContractBaselineProbe)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
. (Join-Path $RepoRoot 'tools/r19_timed_path_acquisition.ps1') -ImportOnly
. (Join-Path $RepoRoot 'tools/r19_timed_path_outer.ps1')
. (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')
$script:checks=0
function Check([bool]$Value,[string]$Label){$script:checks++;if(-not$Value){throw ('FAIL '+$Label)}}
function Reject([scriptblock]$Body,[string]$Label){$caught=$false;try{&$Body|Out-Null}catch{$caught=$true};Check $caught $Label}
function Clone($Value){$Value|ConvertTo-Json -Depth 45|ConvertFrom-Json}
foreach($command in @('Get-CimInstance','Get-PnpDevice','Get-Process','Start-Process')){Set-Item ('function:script:'+$command) {throw 'FORBIDDEN_OFFLINE_OPERATION'}}
$flags=@{AuxReadinessDiagnostics=$true;DiagnosticUsbFailureDiagnostics=$true;ParamListDiagnostics=$true;GrantDiagnostics=$true;GrantReservationDiagnostics=$true;GrantReservationStopDiagnostics=$true;GrantAgreementDiagnostics=$true;GrantReservationFatalDiagnostics=$true}
$paths=@(Get-R19TimedPathOuterToolPaths @flags)
Check ($paths.Count-eq28-and@($paths|Select-Object -Unique).Count-eq28-and@($paths|Where-Object{$_-ceq'tools/read_r19_grant_reservation_fatal_record.ps1'}).Count-eq1) 'New decoder belongs to an exact28-tool closure'
$base=Get-R19GrantReservationCandidateContract -RepoRoot $RepoRoot -Enabled $true -CancellationEnabled $true -AgreementEnabled $true -FatalEnabled $true
$stop=Get-R19GrantReservationStopCandidateContract -RepoRoot $RepoRoot -Enabled $true -AgreementEnabled $true -FatalEnabled $true
$agreement=Get-R19GrantAgreementCandidateContract -RepoRoot $RepoRoot -Enabled $true -FatalEnabled $true
$fatal=Get-R19GrantReservationFatalCandidateContract -RepoRoot $RepoRoot -Enabled $true
$roles=Get-R19UsbRoleCapabilities -RepoRoot $RepoRoot -Enabled $true
$ports=@([pscustomobject]@{role='vehicle';port='COM3';baud=115200;pnp_instance_id='SYNTHETIC-V';usb_parent_instance_id='SYNTHETIC-PV'},[pscustomobject]@{role='ground';port='COM6';baud=57600;pnp_instance_id='SYNTHETIC-G';usb_parent_instance_id='SYNTHETIC-PG'})
$handoff=[pscustomobject]@{schema='vc-lora-r19-candidate-artifact-handoff-v1';result='PASS';artifact_id='SYNTHETIC-FATAL-NOT-HARDWARE';runtime_fail_diagnostics_enabled=$true;reader_schema='vc-lora-r19-runtime-stage-jtag-read-v12';timed_path_diagnostics=(Get-R19TimedPathCandidateContract $RepoRoot ExplicitHostArm);aux_readiness_diagnostics=(Get-R19AuxReadinessCandidateContract $RepoRoot $true);diagnostic_usb_failure_diagnostics=(Get-R19DiagnosticUsbFailureCandidateContract $RepoRoot $true);grant_diagnostics=(Get-R19GrantDiagnosticCandidateContract $RepoRoot $true);grant_reservation_diagnostics=$base;grant_reservation_stop_diagnostics=$stop;grant_agreement_diagnostics=$agreement;grant_reservation_fatal_diagnostics=$fatal;usb_role_capabilities=$roles}
$flash=Clone $handoff;$flash.schema='vc-lora-r19-candidate-flash-evidence-v1'
$flash|Add-Member NoteProperty status 'PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY'
$flash|Add-Member NoteProperty candidate ([pscustomobject]@{handoff_sha256=('A'*64)})
$flash|Add-Member NoteProperty one_run_hil_authorized $true
$flash|Add-Member NoteProperty roles @($ports|ForEach-Object{[pscustomobject]@{role=$_.role;port=$_.port;pnp_device_id=$_.pnp_instance_id;parent_device_id=$_.usb_parent_instance_id;write_pass=$true;verify_pass=$true;reenumeration_pass=$true}})
$now=[DateTime]::Parse('2026-10-25T12:00:00Z').ToUniversalTime()
$permit=[pscustomobject]@{schema='vc-lora-r19-timed-path-execution-permit-v1';status='AUTHORIZED_SINGLE_CAPTURE';candidate_id=$handoff.artifact_id;mode='ExplicitHostArm';safety_confirmed=$true;one_time=$true;restore_required=$true;handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);issued_utc=$now.AddSeconds(-1).ToString('o');expires_utc=$now.AddSeconds(90).ToString('o');capture_seconds=40;ports=$ports;param_list_diagnostics=$true;grant_diagnostics=$true;grant_reservation_diagnostics=$true;grant_reservation_contract=$base;grant_reservation_stop_diagnostics=$true;grant_reservation_stop_contract=$stop;grant_agreement_diagnostics=$true;grant_agreement_contract=$agreement;grant_reservation_fatal_diagnostics=$true;grant_reservation_fatal_contract=$fatal;reservation_prepare_seconds=15}
$argsPlan=$flags.Clone();$argsPlan+=@{Handoff=$handoff;FlashEvidence=$flash;Permit=$permit;Mode='ExplicitHostArm';HandoffSha256=('A'*64);FlashEvidenceSha256=('B'*64);NowUtc=$now;RepoRoot=$RepoRoot}
Check ((Get-R19TimedPathCapturePlan @argsPlan).valid) 'Actual plan accepts a complete source-bound fatal chain'
foreach($mutation in @('omit-mode','missing-handoff','missing-flash','missing-permit-contract','missing-permit-flag','string-permit','case-permit','reader','reads','scope','decoder','extra')){
  $a=$argsPlan.Clone();$a.Handoff=Clone $handoff;$a.FlashEvidence=Clone $flash;$a.Permit=Clone $permit
  switch($mutation){
    'omit-mode'{$a.GrantReservationFatalDiagnostics=$false}
    'missing-handoff'{$a.Handoff.PSObject.Properties.Remove('grant_reservation_fatal_diagnostics')}
    'missing-flash'{$a.FlashEvidence.PSObject.Properties.Remove('grant_reservation_fatal_diagnostics')}
    'missing-permit-contract'{$a.Permit.PSObject.Properties.Remove('grant_reservation_fatal_contract')}
    'missing-permit-flag'{$a.Permit.PSObject.Properties.Remove('grant_reservation_fatal_diagnostics')}
    'string-permit'{$a.Permit.grant_reservation_fatal_diagnostics='true'}
    'case-permit'{$a.Permit.PSObject.Properties.Remove('grant_reservation_fatal_diagnostics');$a.Permit|Add-Member NoteProperty Grant_Reservation_Fatal_Diagnostics $true}
    'reader'{$a.Handoff.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v11'}
    'reads'{$a.FlashEvidence.grant_reservation_fatal_diagnostics.paired_raw_reads=22}
    'scope'{$a.Permit.grant_reservation_fatal_contract.scope='all-runtime-faults'}
    'decoder'{$a.Handoff.grant_reservation_fatal_diagnostics.decoder.sha256='0'*64}
    'extra'{$a.FlashEvidence.grant_reservation_fatal_diagnostics|Add-Member NoteProperty extra $true}
  }
  Reject {Get-R19TimedPathCapturePlan @a} ('Actual plan rejects '+$mutation)
}
$pin=[pscustomobject]@{schema='vc-lora-r19-timed-path-prepared-run-v1';mode='ExplicitHostArm';candidate_id=$handoff.artifact_id;latest_sha256=('A'*64);latest_path='runs/candidates/R19-GRANT-FATAL-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json';capture_seconds=40;product_budget_ms=106;acceptance_authorized=$false;deployment_authorized=$false;live_authorization_granted=$false;vehicle_runtime_stage_address='0x3fcad7f0';ground_runtime_stage_address='0x3fca4b68';aux_readiness_diagnostics=$true;diagnostic_usb_failure_diagnostics=$true;param_list_diagnostics=$true;grant_diagnostics=$true;grant_reservation_diagnostics=$true;grant_reservation_stop_diagnostics=$true;grant_agreement_diagnostics=$true;grant_reservation_contract=$base;grant_reservation_stop_contract=$stop;grant_agreement_contract=$agreement;grant_reservation_fatal_diagnostics=$true;grant_reservation_fatal_contract=$fatal;reservation_prepare_seconds=15;usb_role_capabilities=$roles;tools=@($paths|ForEach-Object{[pscustomobject]@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $_) -Algorithm SHA256).Hash}})}
Check ($null-ne(Assert-R19TimedPathPreparedContract -Pin $pin -Mode ExplicitHostArm -RepoRoot $RepoRoot @flags)) 'Actual prepared contract accepts the complete fatal closure'
foreach($mutation in @('missing','false','string','case','contract','latest','decoder-tool','tool-hash')){
  $bad=Clone $pin
  switch($mutation){
    'missing'{$bad.PSObject.Properties.Remove('grant_reservation_fatal_contract')}
    'false'{$bad.grant_reservation_fatal_diagnostics=$false}
    'string'{$bad.grant_reservation_fatal_diagnostics='true'}
    'case'{$bad.PSObject.Properties.Remove('grant_reservation_fatal_diagnostics');$bad|Add-Member NoteProperty Grant_Reservation_Fatal_Diagnostics $true}
    'contract'{$bad.grant_reservation_fatal_contract.paired_raw_reads=22}
    'latest'{$bad.latest_path='runs/candidates/R19-GRANT-AGREEMENT-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json'}
    'decoder-tool'{$bad.tools=@($bad.tools|Where-Object{$_.path-cne'tools/read_r19_grant_reservation_fatal_record.ps1'})}
    'tool-hash'{$bad.tools[0].sha256='0'*64}
  }
  Reject {Assert-R19TimedPathPreparedContract -Pin $bad -Mode ExplicitHostArm -RepoRoot $RepoRoot @flags} ('Prepared contract rejects '+$mutation)
}
$summary=[pscustomobject]@{grant_reservation_fatal_diagnostics=$true;grant_reservation_fatal_contract=$fatal}
Assert-R19GrantReservationFatalCaptureContract -Summary $summary -Enabled $true -Contract $fatal -RepoRoot $RepoRoot
Check $true 'Persisted capture selection is independently validated'
foreach($mutation in @('flag','contract','scope','downgrade')){
  $bad=Clone $summary;$enabled=$true
  switch($mutation){'flag'{$bad.grant_reservation_fatal_diagnostics='true'};'contract'{$bad.grant_reservation_fatal_contract=$null};'scope'{$bad.grant_reservation_fatal_contract.scope='all-runtime-faults'};'downgrade'{$enabled=$false}}
  Reject {Assert-R19GrantReservationFatalCaptureContract -Summary $bad -Enabled $enabled -Contract $fatal -RepoRoot $RepoRoot} ('Persisted capture rejects '+$mutation)
}
Assert-R19GrantReservationFatalCaptureContract -Summary ([pscustomobject]@{}) -Enabled $false
Check $true 'Legacy capture without fatal fields stays valid'

# Exercise the complete actual disposition call, not only its small selection
# validator. A zero-PARAM failed preparation is legitimate diagnostic evidence.
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_wire.ps1')
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_workflow.ps1')
$nonce=[Convert]::ToUInt64('521B000000000001',16).ToString()
$workflow=New-R19GrantReservationWorkflow -CandidateId $handoff.artifact_id -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession 123 -SlotNonce $nonce -ClockDomainId fixture -Frequency 1000 -StartTicks 0 -CancellationEnabled $true -AgreementEnabled $true
try{Stop-R19GrantReservationWorkflow $workflow SYNTHETIC_FAILED_PREPARATION}catch{}
$emptySha='E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
$capture=[pscustomobject]@{schema='vc-lora-r19-timed-path-capture-v1';result='CAPTURE_COMPLETE_OBSERVATIONS_ONLY';candidate_id=$handoff.artifact_id;mode='ExplicitHostArm';capture_seconds=40;cleanup_proven=$true;hardware_interaction=$true;acceptance_eligible=$false;deployment_authorized=$false;clock_domain_id='fixture';frequency='1000';measurement_start_ticks='15000';measurement_end_ticks='55000';handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);serial_write_calls=0;grant_diagnostics_enabled=$true;grant_reservation_diagnostics=$true;grant_reservation_contract=$base;grant_reservation_stop_diagnostics=$true;grant_reservation_stop_contract=$stop;grant_agreement_diagnostics=$true;grant_agreement_contract=$agreement;grant_reservation_fatal_diagnostics=$true;grant_reservation_fatal_contract=$fatal;reservation_prepare_seconds=15;measurement_seconds=40;grant_reservation_workflow=(Get-R19GrantReservationSnapshot $workflow);roles=@('vehicle','ground'|ForEach-Object{[pscustomobject]@{role=$_;writes=@();raw_available=$true;raw_saved=$true;reader_continuous=$true;overflow=$false;raw_bytes=0;raw_sha256=$emptySha;raw_base64='';blocks=@();clock_domain_id='fixture';frequency='1000'}});param_list_diagnostics_enabled=$true;param_list_diagnostics=[pscustomobject]@{schema='vc-lora-r19-param-list-diagnostics-v1';target_count=932;deadline_us='30000000';clock_domain_id='fixture';frequency='1000';request_attempts=0;request=$null;snapshot_30s=[pscustomobject]@{all_932_received=$false;result='NOT_ATTEMPTED'};final=[pscustomobject]@{all_932_received=$false;result='NOT_ATTEMPTED'};acceptance_eligible=$false;deployment_authorized=$false}}
$step=[pscustomobject]@{exit_code=0;timed_out=$false;termination_proven=$true;process_tree_termination_proven=$true}
$dispositionArgs=@{Step=$step;CandidateId=$handoff.artifact_id;Mode='ExplicitHostArm';ParamListDiagnostics=$true;GrantReservationDiagnostics=$true;GrantReservationContract=$base;GrantReservationStopDiagnostics=$true;GrantReservationStopContract=$stop;GrantAgreementDiagnostics=$true;GrantAgreementContract=$agreement;GrantReservationFatalDiagnostics=$true;GrantReservationFatalContract=$fatal;RepoRoot=$RepoRoot}
Check ((Get-R19TimedPathOuterCaptureDisposition -Summary $capture @dispositionArgs).acceptable) 'Actual full outer disposition accepts valid zero-PARAM fatal capture'
$withoutContract=$dispositionArgs.Clone();$withoutContract.Remove('GrantReservationFatalContract')
Check (-not(Get-R19TimedPathOuterCaptureDisposition -Summary $capture @withoutContract).acceptable) 'Actual full disposition rejects fatal flag without its separately passed contract'
foreach($mutation in @('flag-string','flag-case','contract-absent')){
  $bad=Clone $capture
  switch($mutation){
    'flag-string'{$bad.grant_reservation_fatal_diagnostics='true'}
    'flag-case'{$bad.PSObject.Properties.Remove('grant_reservation_fatal_diagnostics');$bad|Add-Member NoteProperty Grant_Reservation_Fatal_Diagnostics $true}
    'contract-absent'{$bad.PSObject.Properties.Remove('grant_reservation_fatal_contract')}
  }
  Check (-not(Get-R19TimedPathOuterCaptureDisposition -Summary $bad @dispositionArgs).acceptable) ('Actual full disposition rejects '+$mutation)
}
$tokens=$null;$errors=$null;$parentAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1'),[ref]$tokens,[ref]$errors)
Check (@($errors).Count-eq0) 'Actual parent parses for definitions-only call-boundary fixture'
$parentDefinitions=@($parentAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Get-CaptureDisposition'},$true))
Check ($parentDefinitions.Count-eq1) 'One actual parent disposition function is extracted without CLI execution'
$parentFunctionText=$parentDefinitions[0].Extent.Text
if($OmittedFatalContractBaselineProbe){
  Check ($parentFunctionText.Contains(' -GrantReservationFatalContract $fatalContract')) 'Mutation baseline is bound to the exact newly required argument'
  $parentFunctionText=$parentFunctionText.Replace(' -GrantReservationFatalContract $fatalContract','')
}
& {
  param($FunctionText,$Fixture,$StepFixture,$PreparedPin)
  . ([scriptblock]::Create($FunctionText))
  function Assert-Condition([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}
  function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
  function Read-JsonIfPresent([string]$Path){Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}
  $repo=$RepoRoot
  $fixtureRoot=if($OutputDirectory){Join-Path $OutputDirectory 'actual-parent-disposition'}else{Join-Path ([IO.Path]::GetTempPath()) ('r19-fatal-timed-path-'+[Guid]::NewGuid().ToString('N'))}
  [void][IO.Directory]::CreateDirectory($fixtureRoot)
  $OutputDirectory=$fixtureRoot;$captureDirectory=Join-Path $fixtureRoot capture;[void][IO.Directory]::CreateDirectory($captureDirectory)
  $flashRecordPath=Join-Path $fixtureRoot flash_record.json;[IO.File]::WriteAllText($flashRecordPath,'{}')
  [IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'execution-permit.json.consumed'),[byte[]]@())
  $candidate=[pscustomobject]@{artifact_id=$Fixture.candidate_id;handoff_sha256=$Fixture.handoff_sha256}
  $timedPathEnabled=$true;$TimedPathMode='ExplicitHostArm';$ReadComparisonMode='None';$ParamListDiagnostics=$true;$GrantDiagnostics=$true;$GrantReservationDiagnostics=$true;$GrantReservationStopDiagnostics=$true;$GrantAgreementDiagnostics=$true;$GrantReservationFatalDiagnostics=$true
  $timedPathPreparedPin=Clone $PreparedPin
  $valid=Clone $Fixture;$valid.flash_evidence_sha256=Get-Sha256 $flashRecordPath;$valid.grant_reservation_workflow.flash_evidence_sha256=$valid.flash_evidence_sha256
  foreach($row in $valid.roles){[IO.File]::WriteAllBytes((Join-Path $captureDirectory ($row.role+'.raw.bin')),[byte[]]@())}
  $summaryPath=Join-Path $captureDirectory summary.json
  [IO.File]::WriteAllText($summaryPath,($valid|ConvertTo-Json -Depth 45))
  $actual=Get-CaptureDisposition $StepFixture
  Check ($actual.acceptable) ('Actual parent propagates fatal flag AND contract into full disposition: '+($actual.rejection_reasons-join'; '))
  $originalFatal=$timedPathPreparedPin.grant_reservation_fatal_contract;$timedPathPreparedPin.PSObject.Properties.Remove('grant_reservation_fatal_contract')
  Reject {Get-CaptureDisposition $StepFixture} 'Actual parent cannot infer missing prepared fatal contract from summary'
  $timedPathPreparedPin|Add-Member NoteProperty grant_reservation_fatal_contract $originalFatal
  foreach($mutation in @('flag-case','flag-string','raw-hash-missing','raw-base64-missing','raw-clock-missing','reader-discontinuous')){
    $bad=Clone $valid
    switch($mutation){
      'flag-case'{$bad.PSObject.Properties.Remove('grant_reservation_fatal_diagnostics');$bad|Add-Member NoteProperty Grant_Reservation_Fatal_Diagnostics $true}
      'flag-string'{$bad.grant_reservation_fatal_diagnostics='true'}
      'raw-hash-missing'{$bad.roles[0].PSObject.Properties.Remove('raw_sha256')}
      'raw-base64-missing'{$bad.roles[0].PSObject.Properties.Remove('raw_base64')}
      'raw-clock-missing'{$bad.roles[0].PSObject.Properties.Remove('clock_domain_id')}
      'reader-discontinuous'{$bad.roles[0].reader_continuous=$false}
    }
    [IO.File]::WriteAllText($summaryPath,($bad|ConvertTo-Json -Depth 45))
    Check (-not(Get-CaptureDisposition $StepFixture).acceptable) ('Actual parent rejects '+$mutation)
  }
} $parentFunctionText $capture $step $pin
$outerSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1') -Raw
foreach($binding in @(
  @('expectedStageReaderSha256','tools/read_r19_runtime_stage_jtag.ps1'),
  @('expectedJtagPreflightGateSha256','tools/invoke_r19_jtag_preflash_gate.ps1'),
  @('expectedFlashToolSha256','tools/invoke_r19_candidate_app_flash_hil.ps1'),
  @('expectedCaptureToolSha256','tools/run_r19_runtime_fail_diagnostic_hil.ps1'))){
  $pattern='(?m)^\$'+[regex]::Escape($binding[0])+"\s*=\s*'([A-F0-9]{64})'"
  $literal=[regex]::Match($outerSource,$pattern)
  Check ($literal.Success-and$literal.Groups[1].Value-ceq(Get-FileHash -LiteralPath (Join-Path $RepoRoot $binding[1]) -Algorithm SHA256).Hash) ('Reviewed static dependency pin matches '+$binding[1])
}
# The initial literal belongs to the legacy default child. Timed mode does not
# inherit it: run the parent's actual prepared-pin gate, which must bind the
# separate timed capture child to a reviewed pin and the current exact bytes.
$preparedGate=@($parentAst.EndBlock.Statements|Where-Object{
  $_-is[Management.Automation.Language.IfStatementAst]-and
  $_.Clauses[0].Item1.Extent.Text-ceq'$timedPathEnabled'-and
  $_.Extent.Text.Contains('Prepared outer helper digest differs')
})
Check ($preparedGate.Count-eq1) 'One actual timed prepared-pin gate is extracted without parent main'
$preparedGateText=$preparedGate[0].Extent.Text
$pinFixtureRoot=if($OutputDirectory){Join-Path $OutputDirectory 'actual-prepared-capture-pin'}else{Join-Path ([IO.Path]::GetTempPath()) ('r19-prepared-capture-pin-'+[Guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($pinFixtureRoot)
foreach($mutation in @('none','pin-file-sha','legacy-capture-sha','missing-capture','duplicate-capture','mode')){
  $casePin=Clone $pin
  switch($mutation){
    'legacy-capture-sha'{@($casePin.tools|Where-Object{$_.path-ceq'tools/run_r19_timed_path_capture.ps1'})[0].sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot 'tools/run_r19_runtime_fail_diagnostic_hil.ps1') -Algorithm SHA256).Hash}
    'missing-capture'{$casePin.tools=@($casePin.tools|Where-Object{$_.path-cne'tools/run_r19_timed_path_capture.ps1'})}
    'duplicate-capture'{$casePin.tools+=@(Clone (@($casePin.tools|Where-Object{$_.path-ceq'tools/run_r19_timed_path_capture.ps1'})[0]))}
    'mode'{$casePin.mode='SyncOnly'}
  }
  $casePath=Join-Path $pinFixtureRoot ($mutation+'.json')
  [IO.File]::WriteAllText($casePath,($casePin|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
  $caseHash=(Get-FileHash -LiteralPath $casePath -Algorithm SHA256).Hash
  if($mutation-ceq'pin-file-sha'){$caseHash='0'*64}
  & {
    param($GateText,$PinPath,$PinSha,$Case)
    $repo=(Resolve-Path -LiteralPath $RepoRoot).Path
    $timedPathEnabled=$true;$TimedPathMode='ExplicitHostArm';$OfflineContractTest=$false;$ReadOnlyToolDiscoveryPreflight=$false
    $AuxReadinessDiagnostics=$true;$DiagnosticUsbFailureDiagnostics=$true;$ReadComparisonMode='None';$ParamListDiagnostics=$true
    $GrantDiagnostics=$true;$GrantReservationDiagnostics=$true;$GrantReservationStopDiagnostics=$true;$GrantAgreementDiagnostics=$true;$GrantReservationFatalDiagnostics=$true
    $TimedPathPreparedPinPath=$PinPath;$TimedPathPreparedPinSha256=$PinSha
    $script:timedPathToolLocks=[Collections.Generic.List[IO.FileStream]]::new()
    $expectedCaptureToolSha256=(Get-FileHash -LiteralPath (Join-Path $repo 'tools/run_r19_runtime_fail_diagnostic_hil.ps1') -Algorithm SHA256).Hash
    $caught=$false
    try{
      . ([scriptblock]::Create($GateText))
      if($Case-ceq'none'){
        $timedSha=(Get-FileHash -LiteralPath (Join-Path $repo 'tools/run_r19_timed_path_capture.ps1') -Algorithm SHA256).Hash
        $legacySha=(Get-FileHash -LiteralPath (Join-Path $repo 'tools/run_r19_runtime_fail_diagnostic_hil.ps1') -Algorithm SHA256).Hash
        Check ($expectedCaptureToolSha256-ceq$timedSha-and$expectedCaptureToolSha256-cne$legacySha) 'Actual timed prepared gate replaces the legacy capture pin with the exact separate timed child'
      }
    }catch{
      $caught=$true
      if($Case-ceq'none'){throw}
    }finally{
      foreach($handle in $script:timedPathToolLocks){$handle.Dispose()}
    }
    Check ($caught-eq($Case-cne'none')) ('Actual prepared capture pin disposition '+$Case)
  } $preparedGateText $casePath $caseHash $mutation
}
Write-Output ('FATAL_TIMED_PATH PASS checks='+$script:checks+' hardware_interaction=false')
