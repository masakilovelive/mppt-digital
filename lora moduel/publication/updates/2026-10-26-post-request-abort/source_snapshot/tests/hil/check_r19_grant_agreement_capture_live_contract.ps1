[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
$script:checks=0
function Check([bool]$Value,[string]$Name){$script:checks++;if(-not$Value){throw ('FAIL '+$Name)}}
function Reject([scriptblock]$Body,[string]$Name){$rejected=$false;try{&$Body|Out-Null}catch{$rejected=$true};Check $rejected $Name}
function Clone($Value){$Value|ConvertTo-Json -Depth 45|ConvertFrom-Json}
function Ast([string]$Relative){$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $Relative),[ref]$t,[ref]$e);Check (@($e).Count-eq0) ('Syntax '+$Relative);return $a}
# Definitions only: no CLI tail, process, PnP, serial owner or physical reader.
foreach($relative in @('tools/run_r19_timed_path_capture.ps1','tools/r19_timed_path_acquisition.ps1','tools/r19_timed_path_outer.ps1')){
  $a=Ast $relative
  if($relative-ceq'tools/run_r19_timed_path_capture.ps1'){
    $p=@($a.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantAgreementDiagnostics'})
    Check ($p.Count-eq1-and$p[0].StaticType-eq[Management.Automation.SwitchParameter]) 'Canonical agreement capture flag exists'
    Check ($p[0].Extent.Text.Contains("Alias('GrantAgreementDiagnosticsEnabled')")) 'Previous offline flag is explicit alias, not a separate conflicting switch'
    Check (-not$a.Extent.Text.Contains('Grant agreement is offline-only until candidate')) 'Live agreement uses trusted contracts rather than blanket offline guard'
  }
}
. (Join-Path $repo 'tools/r19_timed_path_acquisition.ps1') -ImportOnly
. (Join-Path $repo 'tools/r19_timed_path_outer.ps1')
. (Join-Path $repo 'tools/r19_candidate_artifact_common.ps1')
. (Join-Path $repo 'tools/r19_grant_reservation_wire.ps1')
. (Join-Path $repo 'tools/r19_grant_reservation_workflow.ps1')
foreach($name in @('Get-CimInstance','Get-PnpDevice','Get-PnpDeviceProperty','Get-Process','Start-Process','Invoke-Expression')){Set-Item -Path ('function:script:'+$name) -Value {throw 'FORBIDDEN_OFFLINE_OPERATION'}}
$flags=@{AuxReadinessDiagnostics=$true;DiagnosticUsbFailureDiagnostics=$true;ParamListDiagnostics=$true;GrantDiagnostics=$true;GrantReservationDiagnostics=$true;GrantReservationStopDiagnostics=$true;GrantAgreementDiagnostics=$true}
$base=Get-R19GrantReservationCandidateContract -RepoRoot $repo -Enabled $true -CancellationEnabled $true -AgreementEnabled $true
$stop=Get-R19GrantReservationStopCandidateContract -RepoRoot $repo -Enabled $true -AgreementEnabled $true
$agreement=Get-R19GrantAgreementCandidateContract -RepoRoot $repo -Enabled $true
$roles=Get-R19UsbRoleCapabilities -RepoRoot $repo -Enabled $true
$ports=@([pscustomobject]@{role='vehicle';port='COM3';baud=115200;pnp_instance_id='SYNTHETIC-V';usb_parent_instance_id='SYNTHETIC-PV'},[pscustomobject]@{role='ground';port='COM6';baud=57600;pnp_instance_id='SYNTHETIC-G';usb_parent_instance_id='SYNTHETIC-PG'})
$handoff=[pscustomobject]@{schema='vc-lora-r19-candidate-artifact-handoff-v1';result='PASS';artifact_id='SYNTHETIC-AGREEMENT-NOT-HARDWARE';runtime_fail_diagnostics_enabled=$true;reader_schema='vc-lora-r19-runtime-stage-jtag-read-v11';timed_path_diagnostics=(Get-R19TimedPathCandidateContract $repo ExplicitHostArm);aux_readiness_diagnostics=(Get-R19AuxReadinessCandidateContract $repo $true);diagnostic_usb_failure_diagnostics=(Get-R19DiagnosticUsbFailureCandidateContract $repo $true);grant_diagnostics=(Get-R19GrantDiagnosticCandidateContract $repo $true);grant_reservation_diagnostics=$base;grant_reservation_stop_diagnostics=$stop;grant_agreement_diagnostics=$agreement;usb_role_capabilities=$roles}
$flash=Clone $handoff;$flash.schema='vc-lora-r19-candidate-flash-evidence-v1';$flash|Add-Member NoteProperty status 'PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY';$flash|Add-Member NoteProperty candidate ([pscustomobject]@{handoff_sha256=('A'*64)});$flash|Add-Member NoteProperty one_run_hil_authorized $true;$flash|Add-Member NoteProperty roles @($ports|ForEach-Object{[pscustomobject]@{role=$_.role;port=$_.port;pnp_device_id=$_.pnp_instance_id;parent_device_id=$_.usb_parent_instance_id;write_pass=$true;verify_pass=$true;reenumeration_pass=$true}})
$now=[DateTime]::Parse('2026-10-25T10:00:00Z').ToUniversalTime()
$permit=[pscustomobject]@{schema='vc-lora-r19-timed-path-execution-permit-v1';status='AUTHORIZED_SINGLE_CAPTURE';candidate_id=$handoff.artifact_id;mode='ExplicitHostArm';safety_confirmed=$true;one_time=$true;restore_required=$true;handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);issued_utc=$now.AddSeconds(-1).ToString('o');expires_utc=$now.AddSeconds(90).ToString('o');capture_seconds=40;ports=$ports;param_list_diagnostics=$true;grant_diagnostics=$true;grant_reservation_diagnostics=$true;grant_reservation_contract=$base;grant_reservation_stop_diagnostics=$true;grant_reservation_stop_contract=$stop;grant_agreement_diagnostics=$true;grant_agreement_contract=$agreement;reservation_prepare_seconds=15}
$argsPlan=$flags.Clone();$argsPlan+=@{Handoff=$handoff;FlashEvidence=$flash;Permit=$permit;Mode='ExplicitHostArm';HandoffSha256=('A'*64);FlashEvidenceSha256=('B'*64);NowUtc=$now;RepoRoot=$repo}
Check ((Get-R19TimedPathCapturePlan @argsPlan).valid) 'Only full source-bound v3 chain admits a plan before permit consumption/device access'
foreach($bad in @('omitted-mode','missing-handoff','missing-flash','missing-permit','string-permit','case-permit','false-permit','contract-hash','wire-downgrade','stop-downgrade','reader','role','undeclared-contract')){
  $a=$argsPlan.Clone();$a.Handoff=Clone $handoff;$a.FlashEvidence=Clone $flash;$a.Permit=Clone $permit
  switch($bad){
    'omitted-mode'{$a.GrantAgreementDiagnostics=$false}
    'missing-handoff'{$a.Handoff.PSObject.Properties.Remove('grant_agreement_diagnostics')}
    'missing-flash'{$a.FlashEvidence.PSObject.Properties.Remove('grant_agreement_diagnostics')}
    'missing-permit'{$a.Permit.PSObject.Properties.Remove('grant_agreement_contract')}
    'string-permit'{$a.Permit.grant_agreement_diagnostics='true'}
    'case-permit'{$a.Permit.PSObject.Properties.Remove('grant_agreement_diagnostics');$a.Permit|Add-Member NoteProperty Grant_Agreement_Diagnostics $true}
    'false-permit'{$a.Permit.grant_agreement_diagnostics=$false}
    'contract-hash'{$a.Permit.grant_agreement_contract.source_bindings[0].sha256='0'*64}
    'wire-downgrade'{$a.FlashEvidence.grant_reservation_diagnostics.usb_control.schema='vc-lora-r19-grant-reservation-usb-v2'}
    'stop-downgrade'{$a.FlashEvidence.grant_reservation_stop_diagnostics.usb_control_schema='vc-lora-r19-grant-reservation-usb-v2'}
    'reader'{$a.Handoff.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v10'}
    'role'{$a.FlashEvidence.roles[0].parent_device_id='WRONG-USB'}
    'undeclared-contract'{$a.GrantAgreementDiagnostics=$false;$a.Permit.grant_agreement_diagnostics=$false}
  }
  Reject {Get-R19TimedPathCapturePlan @a} ('Trusted live plan rejects '+$bad)
}
$paths=@(Get-R19TimedPathOuterToolPaths @flags)
Check ($paths.Count-eq27-and@($paths|Select-Object -Unique).Count-eq27) 'No hidden reader or unpinned tool introduced'
$pin=[pscustomobject]@{schema='vc-lora-r19-timed-path-prepared-run-v1';mode='ExplicitHostArm';candidate_id=$handoff.artifact_id;latest_sha256=('A'*64);latest_path='runs/candidates/R19-GRANT-AGREEMENT-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json';capture_seconds=40;product_budget_ms=106;acceptance_authorized=$false;deployment_authorized=$false;live_authorization_granted=$false;vehicle_runtime_stage_address='0x3fcad7f0';ground_runtime_stage_address='0x3fca4b68';aux_readiness_diagnostics=$true;diagnostic_usb_failure_diagnostics=$true;param_list_diagnostics=$true;grant_diagnostics=$true;grant_reservation_diagnostics=$true;grant_reservation_stop_diagnostics=$true;grant_agreement_diagnostics=$true;grant_reservation_contract=$base;grant_reservation_stop_contract=$stop;grant_agreement_contract=$agreement;reservation_prepare_seconds=15;usb_role_capabilities=$roles;tools=@($paths|ForEach-Object{[pscustomobject]@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $repo $_) -Algorithm SHA256).Hash}})}
Check ($null-ne(Assert-R19TimedPathPreparedContract -Pin $pin -Mode ExplicitHostArm -RepoRoot $repo @flags)) 'Prepared chain admits exact v3 source/file contracts'
foreach($bad in @('missing','false','hash','case','latest','tool-hash')){
  $p=Clone $pin
  switch($bad){'missing'{$p.PSObject.Properties.Remove('grant_agreement_contract')};'false'{$p.grant_agreement_diagnostics=$false};'hash'{$p.grant_agreement_contract.source_bindings[0].sha256='0'*64};'case'{$p.PSObject.Properties.Remove('grant_agreement_diagnostics');$p|Add-Member NoteProperty Grant_Agreement_Diagnostics $true};'latest'{$p.latest_path='runs/candidates/R19-GRANT-RESERVATION-STOP-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json'};'tool-hash'{$p.tools[0].sha256='0'*64}}
  Reject {Assert-R19TimedPathPreparedContract -Pin $p -Mode ExplicitHostArm -RepoRoot $repo @flags} ('Prepared rejects '+$bad)
}
Check ($null-ne(Get-Command Assert-R19GrantAgreementCaptureContract -CommandType Function -ErrorAction SilentlyContinue)) 'Independent persisted agreement evidence validator exists'
$nonce=[Convert]::ToUInt64('521B000000000001',16).ToString()
$wf=New-R19GrantReservationWorkflow -CandidateId $handoff.artifact_id -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession 123 -SlotNonce $nonce -ClockDomainId fixture -Frequency 1000 -StartTicks 0 -CancellationEnabled $true -AgreementEnabled $true
try{Stop-R19GrantReservationWorkflow $wf 'SYNTHETIC_PREPARATION_ABORT'}catch{}
$s=[pscustomobject]@{grant_agreement_diagnostics=$true;grant_agreement_contract=$agreement;grant_reservation_workflow=(Get-R19GrantReservationSnapshot $wf);roles=@();candidate_id=$handoff.artifact_id;handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);clock_domain_id='fixture';frequency='1000'}
Assert-R19GrantAgreementCaptureContract -Summary $s -Enabled $true -Contract $agreement -RepoRoot $repo
Check ($s.grant_reservation_workflow.terminal_abort.phase-ceq'ABORT_UNCONFIRMED') 'An unconfirmed abort remains an observation, never a successful retirement'
foreach($bad in @('wire','claims-rf','claims-speed','irrevocable','ack-without-raw','missing-contract','missing-flag','false-flag')){
  $x=Clone $s
  switch($bad){'wire'{$x.grant_reservation_workflow.wire_version=2};'claims-rf'{$x.grant_reservation_workflow.rf_delivery_proven=$true};'claims-speed'{$x.grant_reservation_workflow.high_speed_success_proven=$true};'irrevocable'{$x.grant_reservation_workflow.commit_is_irrevocable=$true};'ack-without-raw'{$x.grant_reservation_workflow.terminal_abort.phase='ABORTED_CONFIRMED'};'missing-contract'{$x.PSObject.Properties.Remove('grant_agreement_contract')};'missing-flag'{$x.PSObject.Properties.Remove('grant_agreement_diagnostics')};'false-flag'{$x.grant_agreement_diagnostics=$false}}
  Reject {Assert-R19GrantAgreementCaptureContract -Summary $x -Enabled $true -Contract $agreement -RepoRoot $repo} ('Persisted v3 contract rejects '+$bad)
}
# Build actual CRC-valid private replies with production codec and cleanup API.
# Even both replies prove only local retirement, not RF/PARAM completion.
$wf=New-R19GrantReservationWorkflow -CandidateId $handoff.artifact_id -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession 123 -SlotNonce $nonce -ClockDomainId fixture -Frequency 1000 -StartTicks 0 -CancellationEnabled $true -AgreementEnabled $true
foreach($role in @('vehicle','ground')){
  $identity=@{Role=$role;ReaderSession=123;SlotNonce=$nonce;BootId=$(if($role-ceq'ground'){100}else{200});UsbEpoch=1;DeviceMs=100;Version=3;GrantSession=661;GrantCycle=2}
  $wf.('hello_'+$role)=ConvertFrom-R19GrantReservationFrame (New-R19GrantReservationFrame -Opcode HelloReply @identity) -AgreementEnabled $true
}
$wf.prepared=ConvertFrom-R19GrantReservationFrame (New-R19GrantReservationFrame -Opcode Prepared -Role vehicle -ReaderSession 123 -SlotNonce $nonce -BootId 200 -UsbEpoch 1 -DeviceMs 110 -Version 3 -GrantSession 661 -GrantCycle 3 -SlotToken 77 -Generation 1) -AgreementEnabled $true
try{Stop-R19GrantReservationWorkflow $wf 'SYNTHETIC_PREPARAM_WITHDRAWAL'}catch{}
$rawRoles=@();$script:tick=200
foreach($role in @('vehicle','ground')){
  $c=Get-R19GrantReservationTerminalAbortCommand -State $wf -Role $role -NowTicks ([string]$script:tick) -CaptureDeadlineTicks 40000
  $null=Invoke-R19ReservationTerminalAbortWrite -State $wf -Command $c -NowTicks {[string]$script:tick} -Writer {param([byte[]]$Bytes)return [int]$Bytes.Length}
  [byte[]]$ack=New-R19GrantReservationFrame -Opcode AbortAck -Role $role -ReaderSession 123 -SlotNonce $nonce -BootId $(if($role-ceq'ground'){100}else{200}) -UsbEpoch 1 -DeviceMs 120 -Version 3 -GrantSession 661 -GrantCycle 3 -SlotToken 77 -Generation 1
  $script:tick+=10
  Add-R19GrantReservationTerminalAbortObservation $wf $role $ack ([string]$script:tick) ([string]$script:tick) 0
  $rawRoles+=,[pscustomobject]@{role=$role;raw_available=$true;raw_saved=$true;reader_continuous=$true;raw_base64=[Convert]::ToBase64String($ack);raw_bytes=66;raw_sha256=(Get-R19AcquisitionSha256 $ack);blocks=@([pscustomobject]@{offset=0;count=66;end_ticks=[string]$script:tick;clock_domain_id='fixture';frequency='1000'})}
  $script:tick+=10
}
$confirmed=Clone $s;$confirmed.grant_reservation_workflow=Get-R19GrantReservationSnapshot $wf;$confirmed.roles=$rawRoles
Assert-R19GrantAgreementCaptureContract -Summary $confirmed -Enabled $true -Contract $agreement -RepoRoot $repo
Check ($confirmed.grant_reservation_workflow.terminal_abort.phase-ceq'ABORTED_CONFIRMED'-and-not$confirmed.grant_reservation_workflow.rf_delivery_proven) 'Both production AbortAck frames replay from exact role raw blocks without claiming RF success'
foreach($bad in @('raw-hash','raw-byte','raw-offset','native-time','missing-role','wrong-direction','forged-decoded','out-prefix','out-ledger','cleanup-ledger','one-ack')){
  $x=Clone $confirmed
  switch($bad){
    'raw-hash'{$x.roles[0].raw_sha256='0'*64}
    'raw-byte'{$raw=[Convert]::FromBase64String($x.roles[0].raw_base64);$raw[20]=$raw[20]-bxor1;$x.roles[0].raw_base64=[Convert]::ToBase64String($raw);$x.roles[0].raw_sha256=Get-R19AcquisitionSha256 $raw}
    'raw-offset'{$x.grant_reservation_workflow.terminal_abort.roles.vehicle.ack.raw_offset=1}
    'native-time'{$x.roles[0].blocks[0].end_ticks='209'}
    'missing-role'{$x.roles=@($x.roles[1])}
    'wrong-direction'{$x.grant_reservation_workflow.terminal_abort.roles.vehicle.ack.frame_base64=$x.grant_reservation_workflow.terminal_abort.roles.vehicle.command.frame_base64}
    'forged-decoded'{$x.grant_reservation_workflow.terminal_abort.roles.vehicle.ack.decoded.device_ms='999'}
    'out-prefix'{$x.grant_reservation_workflow.terminal_abort.roles.vehicle.command.accepted_bytes=32}
    'out-ledger'{$x.grant_reservation_workflow.commands=@($x.grant_reservation_workflow.commands[1])}
    'cleanup-ledger'{$x.grant_reservation_workflow.terminal_abort.roles.vehicle.write_success=$false}
    'one-ack'{$x.grant_reservation_workflow.terminal_abort.roles.ground.ack=$null}
  }
  Reject {Assert-R19GrantAgreementCaptureContract -Summary $x -Enabled $true -Contract $agreement -RepoRoot $repo} ('Raw replay rejects '+$bad)
}
# Reuse only the existing offline fixture function bodies, then call the real
# production workflow to obtain bilateral CommitAck and one attempted PARAM.
$fixtureAst=Ast 'tests/hil/check_r19_grant_agreement_workflow.ps1'
foreach($node in $fixtureAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-cin@('Tick','Fixture','WriteNext','Frame','Observe','BoundFixture','Commit')}){. ([scriptblock]::Create($node.Extent.Text))}
$script:writes=0;$committed=BoundFixture;Commit $committed
[byte[]]$param=@(253,2,0,0,99,255,190,21,0,0,1,1,213,7)
Begin-R19GrantReservationParamWrite $committed $param (Tick);Set-R19GrantReservationParamWriteResult $committed 14 (Tick)
try{Stop-R19GrantReservationWorkflow $committed 'SYNTHETIC_POSTPARAM_FAILURE'}catch{}
$commitRoles=@()
foreach($role in @('vehicle','ground')){
  $bytes=[Collections.Generic.List[byte]]::new();$blocks=@()
  foreach($observation in $committed.observations|Where-Object{$_.role-ceq$role}){
    [byte[]]$frame=[Convert]::FromBase64String($observation.frame_base64);$offset=$bytes.Count;$observation.raw_offset=[long]$offset;$bytes.AddRange($frame)
    $blocks+=,[pscustomobject]@{offset=$offset;count=$frame.Length;end_ticks=$observation.read_completed_ticks;clock_domain_id='fixture';frequency='1000'}
  }
  $commitRoles+=,[pscustomobject]@{role=$role;raw_available=$true;raw_saved=$true;reader_continuous=$true;raw_base64=[Convert]::ToBase64String($bytes.ToArray());raw_bytes=$bytes.Count;raw_sha256=(Get-R19AcquisitionSha256 $bytes.ToArray());blocks=$blocks}
}
$commitSummary=Clone $s;$commitSummary.candidate_id=$committed.candidate_id;$commitSummary.grant_reservation_workflow=Get-R19GrantReservationSnapshot $committed;$commitSummary.roles=$commitRoles
Assert-R19GrantAgreementCaptureContract -Summary $commitSummary -Enabled $true -Contract $agreement -RepoRoot $repo
Check ($commitSummary.grant_reservation_workflow.param_attempts-eq1-and$commitSummary.grant_reservation_workflow.status-ceq'Failed') 'Actual bilateral CommitAck raw evidence precedes one PARAM without reviving its later failure'
foreach($bad in @('missing-commit','missing-observation','old-nonce','bad-native-time','partial-out','premature-param')){
  $x=Clone $commitSummary
  switch($bad){
    'missing-commit'{$x.grant_reservation_workflow.commit_vehicle=$null}
    'missing-observation'{$x.grant_reservation_workflow.observations=@($x.grant_reservation_workflow.observations|Where-Object{-not($_.role-ceq'vehicle'-and$_.decoded.opcode-ceq'CommitAck')})}
    'old-nonce'{$x.grant_reservation_workflow.slot_nonce=[Convert]::ToUInt64('521B000000000002',16).ToString()}
    'bad-native-time'{$row=@($x.grant_reservation_workflow.observations|Where-Object{$_.role-ceq'vehicle'-and$_.decoded.opcode-ceq'CommitAck'})[0];$row.read_completed_ticks='0'}
    'partial-out'{$row=@($x.grant_reservation_workflow.commands|Where-Object{$_.role-ceq'vehicle'-and$_.opcode-ceq'CommitRequest'})[0];$row.accepted_bytes=32}
    'premature-param'{$x.grant_reservation_workflow.param_write_started_ticks='0'}
  }
  Reject {Assert-R19GrantAgreementCaptureContract -Summary $x -Enabled $true -Contract $agreement -RepoRoot $repo} ('Commit evidence rejects '+$bad)
}
$captureAst=Ast 'tools/run_r19_timed_path_capture.ps1'
foreach($node in $captureAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-cin@('Write-R19TimedPathJson','Write-R19TimedPathRaw','Get-R19TimedPathRawRole','Get-R19TimedPathRoleMetadata','Save-R19TimedPathCaptureEvidence')}){. ([scriptblock]::Create($node.Extent.Text))}
$saveRoot=if($OutputDirectory){Join-Path $OutputDirectory 'actual-persistence'}else{Join-Path ([IO.Path]::GetTempPath()) ('r19-save-agreement-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($saveRoot)
$saveStates=@();$phaseRoles=@()
foreach($r in $confirmed.roles){
  [byte[]]$raw=[Convert]::FromBase64String($r.raw_base64)
  $saveStates+=,[pscustomobject]@{spec=[pscustomobject]@{role=$r.role;port='SYNTHETIC-NOT-HARDWARE';baud=57600};raw=$raw;reader_id=('synthetic-'+$r.role);nonce='1';opened=$true;joined=$true;cleanup_close_fallback=$false;open_before_ticks='0';open_after_ticks='1';read_started_ticks='2';snapshot=[pscustomobject]@{ByteCount=66;Overflow=$false;Failure='';Blocks=@([pscustomobject]@{Offset=0;Count=66;BeginTicks=100;EndTicks=[long]$r.blocks[0].end_ticks})};workflow=$null;workflow_failure='';writes=[Collections.Generic.List[object]]::new();observations=[Collections.Generic.List[object]]::new();product_observations=[Collections.Generic.List[object]]::new()}
  $phaseRoles+=,[pscustomobject]@{role=$r.role;preparation_bytes=$raw;measurement_bytes=[byte[]]::new(0)}
}
$context=[pscustomobject]@{candidate_id=$handoff.artifact_id;mode='ExplicitHostArm';capture_seconds=40;started_utc='2026-10-25T10:00:00Z';clock_domain_id='fixture';frequency='1000';measurement_start_ticks='100';measurement_end_ticks='40100';cleanup_proven=$true;hardware_interaction=$false;serial_write_calls=2;failure='';identity_evidence=@();pinned_inputs=@();handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);repo_root=$repo;grant_reservation_diagnostics=$true;grant_reservation_contract=$base;grant_reservation_stop_diagnostics=$true;grant_reservation_stop_contract=$stop;grant_agreement_diagnostics=$true;grant_agreement_contract=$agreement;grant_reservation_workflow=$confirmed.grant_reservation_workflow;reservation_raw_phases=[pscustomobject]@{roles=$phaseRoles}}
$saved=Save-R19TimedPathCaptureEvidence $saveStates $saveRoot $context
Check ($saved.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY'-and$saved.grant_agreement_diagnostics-and$saved.grant_reservation_workflow.terminal_abort.phase-ceq'ABORTED_CONFIRMED'-and-not$saved.acceptance_eligible) 'Actual Save durably preserves v3 raw-backed retirement without product acceptance'
$disk=Get-Content -LiteralPath (Join-Path $saveRoot 'summary.json') -Raw|ConvertFrom-Json
Assert-R19GrantAgreementCaptureContract -Summary $disk -Enabled $true -Contract $agreement -RepoRoot $repo
Check ($disk.grant_agreement_contract.wire_version-eq3-and$disk.grant_reservation_workflow.param_attempts-eq0) 'Actual disk JSON replays the same agreement and zero PARAM facts'
$captureAst=Ast 'tools/run_r19_timed_path_capture.ps1'
foreach($node in $captureAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-cin@('Start-R19ReservationMeasurement','Start-R19FailedPreparationPassiveMeasurement','Get-R19GrantReservationAbortCaptureDeadline')}){. ([scriptblock]::Create($node.Extent.Text))}
Check ($null-ne(Get-Command Start-R19FailedPreparationPassiveMeasurement -CommandType Function -ErrorAction SilentlyContinue)) 'Failed v3 preparation has a separate explicit passive capture path'
Check ($null-ne(Get-Command Get-R19GrantReservationAbortCaptureDeadline -CommandType Function -ErrorAction SilentlyContinue)) 'Preparation and actual measurement use one consistent bounded abort deadline'
$expiryBranches=@($captureAst.FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Extent.Text.StartsWith('if($GrantReservationDiagnostics-and-not$measurementStart-and')},$true))
Check ($expiryBranches.Count-eq1) 'Actual CLI preparation expiry branch is unique'
$actualExpiry=[scriptblock]::Create($expiryBranches[0].Extent.Text)
$GrantReservationDiagnostics=$true;$GrantAgreementDiagnostics=$true;$frequency='1000';$preparationDeadlineTicks='15000';$measurementStart='';$deadline=[Numerics.BigInteger]15000;$clock=[pscustomobject]@{ElapsedTicks=15005L}
$reservationWorkflow=New-R19GrantReservationWorkflow -CandidateId SYNTHETIC-PASSIVE -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession 123 -SlotNonce $nonce -ClockDomainId fixture -Frequency 1000 -StartTicks 0 -CancellationEnabled $true -AgreementEnabled $true
try{Stop-R19GrantReservationWorkflow $reservationWorkflow 'FIRST_SYNTHETIC_FAILURE'}catch{}
$firstFailure=$reservationWorkflow.failure
$abortDeadline=Get-R19GrantReservationAbortCaptureDeadline -Workflow $reservationWorkflow -PreparationDeadlineTicks $preparationDeadlineTicks -MeasurementDeadlineTicks '15000'
Check ($abortDeadline-ceq'55000') 'Before measurement, cleanup deadline binds the original planned 15s preparation plus 40s passive capture end'
Check (Test-R19GrantReservationTerminalAbortClock $reservationWorkflow '100' $abortDeadline) 'Initial preparation cleanup may progress without changing the 15s prepare deadline'
$states=[Collections.Generic.List[object]]::new();$script:passiveMarkers=0
foreach($role in @('vehicle','ground')){$reader=[pscustomobject]@{};$reader|Add-Member ScriptMethod MarkPhase {param($Name)$script:passiveMarkers++;[pscustomobject]@{ByteCount=0L;Ticks=15005L}};$states.Add([pscustomobject]@{reader=$reader;preparation_cut_offset=0L;preparation_cut_ticks=''})}
. $actualExpiry
Check ($measurementStart-ceq'15000'-and[string]$deadline-ceq'55000'-and$script:passiveMarkers-eq2) 'Actual expiry branch captures passive 40s from planned boundary, not from delayed observer time'
Check ($reservationWorkflow.failure-ceq$firstFailure-and$reservationWorkflow.param_attempts-eq0-and$reservationWorkflow.status-ceq'Failed'-and$reservationWorkflow.measurement_kind-ceq'PASSIVE_AFTER_FAILED_PREPARATION') 'Passive capture preserves first failure and NOT_ATTEMPTED product request'
Check ($reservationWorkflow.passive_boundary_observed_ticks-ceq'15005'-and$reservationWorkflow.prepare_deadline_ticks-ceq'15000') 'Delayed observation is separate from the original preparation clock'
$after=Get-R19GrantReservationAbortCaptureDeadline -Workflow $reservationWorkflow -PreparationDeadlineTicks '15000' -MeasurementDeadlineTicks '55000'
Check ($after-ceq$abortDeadline-and(Test-R19GrantReservationTerminalAbortClock $reservationWorkflow '15005' $after)) 'Preparation and passive measurement share the same immutable cleanup deadline'
Reject {Start-R19ReservationMeasurement $reservationWorkflow $states.ToArray() {'15006'}} 'Failed preparation cannot migrate into successful committed measurement'
Reject {Start-R19FailedPreparationPassiveMeasurement $reservationWorkflow $states.ToArray() '15000' {'15006'}} 'Passive capture boundary cannot restart'
Reject {Get-R19GrantReservationAbortCaptureDeadline $reservationWorkflow '15001' '55001'} 'Caller cannot extend the planned preparation boundary'
Check (-not(Test-R19GrantReservationTerminalAbortClock $reservationWorkflow '55000' $after)) 'Terminal cleanup remains closed at the unchanged capture deadline'
Reject {Get-R19GrantReservationNextCommand $reservationWorkflow '15006'} 'Passive mode cannot reopen the normal failed-state OUT path'
$attempted=Clone $commitSummary.grant_reservation_workflow;$attempted.measurement_start_ticks=$null
Reject {Start-R19FailedPreparationPassiveMeasurement $attempted $states.ToArray() '15000' {'15005'}} 'An already attempted PARAM cannot be relabeled failed-preparation NOT_ATTEMPTED'
$early=New-R19GrantReservationWorkflow -CandidateId SYNTHETIC-PASSIVE-EARLY -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession 123 -SlotNonce $nonce -ClockDomainId fixture -Frequency 1000 -StartTicks 0 -CancellationEnabled $true -AgreementEnabled $true
try{Stop-R19GrantReservationWorkflow $early 'EARLY_FAILURE'}catch{}
Reject {Start-R19FailedPreparationPassiveMeasurement $early $states.ToArray() '15000' {'14999'}} 'Passive capture cannot be mislabeled before the original preparation end'
$product=Clone $commitSummary.grant_reservation_workflow;$product.measurement_start_ticks='1000'
Check ((Get-R19GrantReservationAbortCaptureDeadline $product '15000' '41000')-ceq'41000') 'Actual committed measurement cleanup uses its own unchanged 40s end, not the preparation end'
$passiveRoot=$saveRoot+'-passive';[void][IO.Directory]::CreateDirectory($passiveRoot)
$passiveContext=Clone $context;$passiveContext.candidate_id=$reservationWorkflow.candidate_id;$passiveContext.grant_reservation_workflow=Get-R19GrantReservationSnapshot $reservationWorkflow;$passiveContext.measurement_start_ticks='15000';$passiveContext.measurement_end_ticks='55000';$passiveContext.serial_write_calls=0
foreach($phase in $passiveContext.reservation_raw_phases.roles){$phase.preparation_bytes=[byte[]]$phase.preparation_bytes;$phase.measurement_bytes=[byte[]]$phase.measurement_bytes}
$passiveSaved=Save-R19TimedPathCaptureEvidence $saveStates $passiveRoot $passiveContext
Check ($passiveSaved.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY'-and$passiveSaved.grant_reservation_workflow.request_outcome-ceq'NOT_ATTEMPTED'-and$passiveSaved.measurement_start_ticks-ceq'15000'-and$passiveSaved.measurement_end_ticks-ceq'55000') 'Actual passive Save preserves 40s observations and NOT_ATTEMPTED without hiding preparation failure'
$passiveDisk=Get-Content -LiteralPath (Join-Path $passiveRoot 'summary.json') -Raw|ConvertFrom-Json
Assert-R19GrantAgreementCaptureContract -Summary $passiveDisk -Enabled $true -Contract $agreement -RepoRoot $repo
foreach($bad in @('planned-end-extended','start-reset','observed-before-preparation','observed-after-window','successful-status')){
  $x=Clone $passiveDisk
  switch($bad){'planned-end-extended'{$x.grant_reservation_workflow.planned_passive_capture_end_ticks='56000'};'start-reset'{$x.grant_reservation_workflow.measurement_start_ticks='15005'};'observed-before-preparation'{$x.grant_reservation_workflow.passive_boundary_observed_ticks='14999'};'observed-after-window'{$x.grant_reservation_workflow.passive_boundary_observed_ticks='55000'};'successful-status'{$x.grant_reservation_workflow.status='TailPermitWrittenAwaitingMcuEvidence'}}
  Reject {Assert-R19GrantAgreementCaptureContract -Summary $x -Enabled $true -Contract $agreement -RepoRoot $repo} ('Passive persisted evidence rejects '+$bad)
}
# Exercise the actual live entry with synthetic files and a malformed trusted
# permit. Any device/process call is an error, and no consumed marker/output
# directory may be created. The test is not a live authorization or HIL run.
$fixtureRoot=if($OutputDirectory){Join-Path $OutputDirectory 'invalid-live-entry'}else{Join-Path ([IO.Path]::GetTempPath()) ('r19-invalid-agreement-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$hPath=Join-Path $fixtureRoot 'synthetic-handoff.json';$fPath=Join-Path $fixtureRoot 'synthetic-flash.json';$pPath=Join-Path $fixtureRoot 'synthetic-permit.json';$captureOut=Join-Path $fixtureRoot 'MUST-NOT-BE-CREATED'
[IO.File]::WriteAllText($hPath,($handoff|ConvertTo-Json -Depth 45),[Text.UTF8Encoding]::new($false))
$f=Clone $flash;$f.candidate.handoff_sha256=(Get-FileHash -LiteralPath $hPath).Hash
[IO.File]::WriteAllText($fPath,($f|ConvertTo-Json -Depth 45),[Text.UTF8Encoding]::new($false))
$p=Clone $permit;$p.handoff_sha256=(Get-FileHash -LiteralPath $hPath).Hash;$p.flash_evidence_sha256=(Get-FileHash -LiteralPath $fPath).Hash;$p.grant_agreement_contract.source_bindings[0].sha256='0'*64
[IO.File]::WriteAllText($pPath,($p|ConvertTo-Json -Depth 45),[Text.UTF8Encoding]::new($false))
$script:unexpectedDeviceCalls=0
foreach($name in @('Get-CimInstance','Get-PnpDevice','Get-PnpDeviceProperty','Get-Process','Start-Process','Invoke-Expression')){Set-Item -Path ('function:script:'+$name) -Value {$script:unexpectedDeviceCalls++;throw 'FORBIDDEN_OFFLINE_OPERATION'}}
$entryArgs=$flags.Clone();$entryArgs+=@{Execute=$true;Mode='ExplicitHostArm';RepoRoot=$repo;OutputDirectory=$captureOut;CandidateHandoffPath=$hPath;CandidateFlashEvidencePath=$fPath;ExecutionPermitPath=$pPath}
$entryError='';try{& (Join-Path $repo 'tools/run_r19_timed_path_capture.ps1') @entryArgs}catch{$entryError=$_.Exception.Message}
Check ($entryError-ceq'Agreement permit does not bind candidate contract') 'Actual entry rejects malformed exact contract before the live claim boundary'
Check ($script:unexpectedDeviceCalls-eq0-and-not(Test-Path -LiteralPath ($pPath+'.consumed'))-and-not(Test-Path -LiteralPath $captureOut)) 'Actual invalid live entry makes zero device/process calls, consumes zero permits and creates no capture output'
if($OutputDirectory){[void][IO.Directory]::CreateDirectory($OutputDirectory);[pscustomobject]@{schema='vc-lora-r19-grant-agreement-live-capture-contract-test-v1';result='PASS';checks=$script:checks;hardware_interaction=$false;deadline_changes=0}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding utf8}
Write-Output "R19_GRANT_AGREEMENT_CAPTURE_LIVE PASS checks=$script:checks hardware_interaction=false"
