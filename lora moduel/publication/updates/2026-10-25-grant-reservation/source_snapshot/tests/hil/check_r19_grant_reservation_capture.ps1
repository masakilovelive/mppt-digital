[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent(Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not$OutputDirectory){$OutputDirectory=Join-Path $repo ('runs/validation/R19-GRANT-RESERVATION-CAPTURE-TEST-001/'+[guid]::NewGuid().ToString('N'))}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if(-not$OutputDirectory.StartsWith((Join-Path $repo 'runs/validation/'),[StringComparison]::OrdinalIgnoreCase)){throw 'Offline evidence output must stay within validation'}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$script:checks=0
function Check([bool]$Value,[string]$Name){$script:checks++;if(-not$Value){throw ('FAIL '+$Name)}}
function Reject([scriptblock]$Body,[string]$Name){$rejected=$false;try{&$Body|Out-Null}catch{$rejected=$true};Check $rejected $Name}
function Clone($Value){$Value|ConvertTo-Json -Depth 40|ConvertFrom-Json}
$capturePath=Join-Path $repo 'tools/run_r19_timed_path_capture.ps1';$source=[IO.File]::ReadAllText($capturePath)
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($capturePath,[ref]$tokens,[ref]$errors)
Check (@($errors).Count-eq0) 'capture source parses'
# Real definitions only, never the device-owning CLI tail.
$names=@('Write-R19TimedPathJson','Write-R19TimedPathRaw','Get-R19TimedPathRawRole','Get-R19TimedPathRoleMetadata','Save-R19TimedPathCaptureEvidence','Start-R19ReservationMeasurement','Get-R19ReservationRawPhases','Invoke-R19ParamListRequest','Update-R19ParamListCheckpoint')
foreach($node in $ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-cin$names}){. ([scriptblock]::Create($node.Extent.Text))}
$savedOutput=$OutputDirectory
. (Join-Path $repo 'tools/r19_timed_path_acquisition.ps1') -ImportOnly
$OutputDirectory=$savedOutput
. (Join-Path $repo 'tools/r19_grant_reservation_contract.ps1')
. (Join-Path $repo 'tools/r19_grant_reservation_wire.ps1')
. (Join-Path $repo 'tools/r19_grant_reservation_workflow.ps1')
. (Join-Path $repo 'tools/r19_param_list_diagnostics.ps1')
# Only named filesystem constructors are called. All device/process operations
# are forbidden stubs; no port, native reader, candidate build, or Execute path.
foreach($name in @('Get-CimInstance','Get-PnpDevice','Get-PnpDeviceProperty','Get-Process','Start-Process','Invoke-Expression')){Set-Item -Path ('function:script:'+$name) -Value {throw 'FORBIDDEN_OFFLINE_OPERATION'}}
function NewState([string]$Role){
  [byte[]]$bytes=if($Role-ceq'ground'){@(4,5,6,7)}else{@(1,2,3,4)}
  $reader=[pscustomobject]@{calls=0;offset=2L}
  $reader|Add-Member ScriptMethod MarkPhase {param($Phase)if($Phase-cne'RESERVATION_MEASUREMENT'){throw 'bad phase'};$this.calls++;[pscustomobject]@{ByteCount=$this.offset;Ticks='101'}}
  [pscustomobject]@{spec=[pscustomobject]@{role=$Role;port=($Role+'-NOT-HARDWARE');baud=57600};reader=$reader;reader_id=($Role+'-fixture');nonce='1';opened=$true;joined=$true;cleanup_close_fallback=$false;open_before_ticks='1';open_after_ticks='2';read_started_ticks='3';snapshot=[pscustomobject]@{ByteCount=4;Blocks=@([pscustomobject]@{Offset=0;Count=4;BeginTicks=90L;EndTicks=110L});Overflow=$false;Failure='';LastReadEndTicks=110L};raw=$bytes;preparation_cut_offset=0L;preparation_cut_ticks='';workflow=$null;workflow_failure='';writes=[Collections.Generic.List[object]]::new();observations=[Collections.Generic.List[object]]::new();product_observations=[Collections.Generic.List[object]]::new()}
}
$states=@((NewState vehicle),(NewState ground));$workflow=[pscustomobject]@{measurement_start_ticks=$null}
$start=Start-R19ReservationMeasurement $workflow $states {'100'}
Check ($start-ceq'100'-and$workflow.measurement_start_ticks-ceq'100') 'realphase helper fixes global measurement start once'
foreach($s in $states){Check ($s.reader.calls-eq1-and$s.preparation_cut_offset-eq2-and$s.preparation_cut_ticks-ceq'101') 'marker does not stop/reopen/purge continuous owner'}
Reject {Start-R19ReservationMeasurement $workflow $states {'101'}} 'measurement cannot restart'
$phases=Get-R19ReservationRawPhases $states '0' '100' '40100'
foreach($r in $phases.roles){Check ($r.preparation_raw_bytes-eq2-and$r.measurement_raw_bytes-eq2-and$r.full_raw_bytes-eq4-and$r.boundary_semantics-match'NOT_PHYSICAL_WIRE_TIME') 'crossing native read is labeled and everybyte retained';Check ((Get-R19AcquisitionSha256 ([byte[]]($r.preparation_bytes+$r.measurement_bytes)))-ceq(Get-R19AcquisitionSha256 @($states|Where-Object{$_.spec.role-ceq$r.role})[0].raw)) 'phase concatenation equals exact fullnative raw'}
function Context {
  [pscustomobject]@{candidate_id='RESERVATION-CAPTURE-SYNTHETIC-NOT-HARDWARE';mode='ExplicitHostArm';capture_seconds=40;started_utc='2026-10-25T00:00:00Z';clock_domain_id='fixture';frequency='1000';measurement_start_ticks='100';measurement_end_ticks='40100';cleanup_proven=$true;hardware_interaction=$false;serial_write_calls=0;failure='';identity_evidence=@();pinned_inputs=@();handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);repo_root=$repo}
}
$contract=Get-R19GrantReservationCandidateContract -RepoRoot $repo -Enabled $true
function SaveCase([string]$Name,[object]$Context){
  $directory=Join-Path $OutputDirectory $Name;[void][IO.Directory]::CreateDirectory($directory)
  $return=Save-R19TimedPathCaptureEvidence $states $directory $Context
  $disk=Get-Content -LiteralPath (Join-Path $directory 'summary.json') -Raw|ConvertFrom-Json
  foreach($role in @('vehicle','ground')){Check ((Get-Item -LiteralPath (Join-Path $directory ($role+'.raw.bin'))).Length-eq4) 'allfullraw survive optionalmetadata failures'}
  return [pscustomobject]@{saved=$return;disk=$disk;directory=$directory}
}
function ReservationContext {
  $c=Context;$c|Add-Member NoteProperty grant_reservation_diagnostics $true;$c|Add-Member NoteProperty grant_reservation_contract $contract
  $c|Add-Member NoteProperty grant_reservation_workflow ([pscustomobject]@{schema='vc-lora-r19-grant-reservation-workflow-v1';status='Failed';failure='SYNTHETIC_NOT_READY';commands=@();param_attempts=0;high_speed_success_proven=$false})
  $c|Add-Member NoteProperty reservation_raw_phases $phases;return $c
}
$case=SaveCase 'actual-mode' (ReservationContext)
foreach($value in @($case.saved,$case.disk)){Check ($value.grant_reservation_diagnostics-is[bool]-and$value.grant_reservation_diagnostics-and$value.reservation_prepare_seconds-eq15-and$value.measurement_seconds-eq40-and$value.grant_reservation_workflow.param_attempts-eq0) 'realSave anddisk retainmode/passive40withzeroPARAM';Check (-not$value.acceptance_eligible-and-not$value.grant_reservation_workflow.high_speed_success_proven) 'failedpreparation rawcapture isnever highspeedpass'}
foreach($role in @('vehicle','ground')){foreach($phase in @('preparation','measurement')){Check ((Get-Item -LiteralPath (Join-Path $case.directory ($role+'.'+$phase+'.raw.bin'))).Length-eq2) 'actualSave writes separatephase raw'}}
$legacy=SaveCase 'legacy' (Context);Check ($null-eq$legacy.disk.PSObject.Properties['grant_reservation_diagnostics']) 'defaultlegacy mode omission retained'
foreach($bad in @('stringflag','wrongcase','primitiveworkflow','primitivephases','missingroles')){
  $c=ReservationContext
  switch($bad){'stringflag'{$c.grant_reservation_diagnostics='true'} 'wrongcase'{$c.PSObject.Properties.Remove('grant_reservation_diagnostics');$c|Add-Member NoteProperty Grant_Reservation_Diagnostics $true} 'primitiveworkflow'{$c.grant_reservation_workflow='bad'} 'primitivephases'{$c.reservation_raw_phases='bad'} 'missingroles'{$c.reservation_raw_phases=[pscustomobject]@{schema='bad'}}}
  $case=SaveCase $bad $c;Check ($case.disk.result-ceq'INVALID_CAPTURE'-and@($case.disk.preservation_errors).Count-gt0) ('invalidmode '+$bad+' failsclosed after durable raw')
}
# The exact early CLI mode-selection branch is evaluated alone before any
# imports, permit reads, serial construction, identity queries, or native thread.
$early=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.IfStatementAst]-and$_.Extent.Text.Contains('Grant reservation requires full')})
Check ($early.Count-eq1) 'actualpredevice reservation selection gate found'
$earlyGate=[scriptblock]::Create($early[0].Extent.Text)
foreach($missing in @('GrantDiagnostics','ParamListDiagnostics','AuxReadinessDiagnostics','DiagnosticUsbFailureDiagnostics','Mode','ReadComparisonMode')){
  $GrantReservationDiagnostics=$true;$GrantDiagnostics=$true;$ParamListDiagnostics=$true;$AuxReadinessDiagnostics=$true;$DiagnosticUsbFailureDiagnostics=$true;$Mode='ExplicitHostArm';$ReadComparisonMode='None'
  if($missing-ceq'Mode'){$Mode='SyncOnly'}elseif($missing-ceq'ReadComparisonMode'){$ReadComparisonMode='GroundPauseResume'}else{Set-Variable $missing $false}
  Reject {. $earlyGate} ('modecannot escalate without '+$missing)
}
# Real pure capture admission, using source-bound declarations and only fake
# flash/USB identities. This is not a device observation or live authorization.
. (Join-Path $repo 'tools/r19_candidate_artifact_common.ps1')
$timed=Get-R19TimedPathCandidateContract $repo ExplicitHostArm
$aux=Get-R19AuxReadinessCandidateContract $repo $true
$diag=Get-R19DiagnosticUsbFailureCandidateContract $repo $true
$grant=Get-R19GrantDiagnosticCandidateContract $repo $true
$rolecap=Get-R19UsbRoleCapabilities -RepoRoot $repo -Enabled $true
$nowUtc=[DateTime]::Parse('2026-10-25T00:00:00Z').ToUniversalTime()
$ports=@([pscustomobject]@{role='vehicle';port='COM3';baud=115200;pnp_instance_id='NOT-HARDWARE-V';usb_parent_instance_id='NOT-HARDWARE-PARENT-V'},[pscustomobject]@{role='ground';port='COM6';baud=57600;pnp_instance_id='NOT-HARDWARE-G';usb_parent_instance_id='NOT-HARDWARE-PARENT-G'})
$handoff=[pscustomobject]@{schema='vc-lora-r19-candidate-artifact-handoff-v1';result='PASS';artifact_id='RESERVATION-SYNTHETIC-NOT-HARDWARE';runtime_fail_diagnostics_enabled=$true;reader_schema='vc-lora-r19-runtime-stage-jtag-read-v10';timed_path_diagnostics=$timed;aux_readiness_diagnostics=$aux;diagnostic_usb_failure_diagnostics=$diag;grant_diagnostics=$grant;grant_reservation_diagnostics=$contract;usb_role_capabilities=$rolecap}
$flashRoles=@(foreach($p in $ports){[pscustomobject]@{role=$p.role;port=$p.port;pnp_device_id=$p.pnp_instance_id;parent_device_id=$p.usb_parent_instance_id;write_pass=$true;verify_pass=$true;reenumeration_pass=$true}})
$flash=[pscustomobject]@{schema='vc-lora-r19-candidate-flash-evidence-v1';result='PASS';status='PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY';candidate=[pscustomobject]@{handoff_sha256=('A'*64)};runtime_fail_diagnostics_enabled=$true;reader_schema='vc-lora-r19-runtime-stage-jtag-read-v10';timed_path_diagnostics=$timed;aux_readiness_diagnostics=$aux;diagnostic_usb_failure_diagnostics=$diag;grant_diagnostics=$grant;grant_reservation_diagnostics=$contract;usb_role_capabilities=$rolecap;one_run_hil_authorized=$true;roles=$flashRoles}
$permit=[pscustomobject]@{schema='vc-lora-r19-timed-path-execution-permit-v1';status='AUTHORIZED_SINGLE_CAPTURE';candidate_id=$handoff.artifact_id;mode='ExplicitHostArm';safety_confirmed=$true;one_time=$true;restore_required=$true;handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);issued_utc=$nowUtc.AddSeconds(-1).ToString('o');expires_utc=$nowUtc.AddSeconds(90).ToString('o');capture_seconds=40;ports=$ports;param_list_diagnostics=$true;grant_diagnostics=$true;grant_reservation_diagnostics=$true;grant_reservation_contract=$contract;reservation_prepare_seconds=15}
$planArgs=@{Handoff=$handoff;FlashEvidence=$flash;Permit=$permit;Mode='ExplicitHostArm';HandoffSha256=('A'*64);FlashEvidenceSha256=('B'*64);NowUtc=$nowUtc;DiagnosticUsbFailureDiagnostics=$true;AuxReadinessDiagnostics=$true;GrantDiagnostics=$true;ParamListDiagnostics=$true;GrantReservationDiagnostics=$true;RepoRoot=$repo}
Check ((Get-R19TimedPathCapturePlan @planArgs).valid) 'realGetPlan admits exactsourcebound mode and provenance before devices'
$jsonPermit=Clone $permit;$jsonArgs=$planArgs.Clone();$jsonArgs.Permit=$jsonPermit
Check ((Get-R19TimedPathCapturePlan @jsonArgs).valid) 'realGetPlan accepts PS JSON integer materialization without type coercion'
foreach($bad in @('permit-false','permit-string','permit-case','permit-duration','permit-contract','handoff-reader','flash-reader','flash-contract','missing-mode','missing-contract','role-escalation')){
  $a=$planArgs.Clone();$a.Permit=Clone $permit;$a.Handoff=Clone $handoff;$a.FlashEvidence=Clone $flash
  switch($bad){
    'permit-false'{$a.Permit.grant_reservation_diagnostics=$false}
    'permit-string'{$a.Permit.grant_reservation_diagnostics='true'}
    'permit-case'{$a.Permit.PSObject.Properties.Remove('grant_reservation_diagnostics');$a.Permit|Add-Member NoteProperty Grant_Reservation_Diagnostics $true}
    'permit-duration'{$a.Permit.reservation_prepare_seconds='15'}
    'permit-contract'{$a.Permit.grant_reservation_contract.capture.prepare_seconds=16}
    'handoff-reader'{$a.Handoff.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9'}
    'flash-reader'{$a.FlashEvidence.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9'}
    'flash-contract'{$a.FlashEvidence.grant_reservation_diagnostics.record.size_bytes=516}
    'missing-mode'{$a.GrantReservationDiagnostics=$false}
    'missing-contract'{$a.Handoff.PSObject.Properties.Remove('grant_reservation_diagnostics')}
    'role-escalation'{$a.FlashEvidence.usb_role_capabilities.roles[0].arm=$true}
  }
  Reject {Get-R19TimedPathCapturePlan @a} ('realGetPlan rejects '+$bad)
}
$branches=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Extent.Text.StartsWith('if($ParamListDiagnostics-and$s.spec.role')-and$n.Extent.Text.Contains('$attempted=Invoke-R19ParamListRequest')},$true))
Check ($branches.Count-eq1) 'exactactualproductPARAMcaller found'
$actualRequestBranch=[scriptblock]::Create('[CmdletBinding()]param([switch]$GrantReservationDiagnostics)'+[Environment]::NewLine+$branches[0].Extent.Text)
foreach($writeOutcome in @('throw','exact')){
  $ParamListDiagnostics=$true;$paramDiagnosticsFailure='';$paramState=New-R19ParamListDiagnosticsState -Frequency 1000 -ClockDomainId fixture
  $paramDeliveredOffset=0L;$deadline=40100L;$serialWrites=3;$measurementStart='100';$clock=[pscustomobject]@{ElapsedTicks=100L}
  $reservationWorkflow=New-R19GrantReservationWorkflow -CandidateId SYNTHETIC-CALLER-NOT-HARDWARE -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession '123' -SlotNonce ([Convert]::ToUInt64('521B000000000001',16).ToString()) -ClockDomainId fixture -Frequency 1000 -StartTicks 0
  $reservationWorkflow.status='BoundReadyForOneParam';$reservationWorkflow.bound=[pscustomobject]@{offline_fixture=$true};$reservationWorkflow.prepared=[pscustomobject]@{offline_fixture=$true}
  $s=NewState ground;$s.workflow=[pscustomobject]@{arm_write_accepted=$true};$s.product_observations.Add([pscustomobject]@{crc_valid=$true})
  $s.reader|Add-Member ScriptMethod GetStatus {return [pscustomobject]@{LastReadEndTicks=200L;PendingByteCount=0}}
  $s|Add-Member NoteProperty port ([pscustomobject]@{calls=0;outcome=$writeOutcome})
  $s.port|Add-Member ScriptMethod Write {param([byte[]]$Payload,[int]$Offset,[int]$Count)$this.calls++;if($this.outcome-ceq'throw'){throw [IO.IOException]::new('SYNTHETIC_WRITE_THROW')} }
  # The real writer returns exact14 after a void SerialPort.Write. To exercise
  # a helper-level partial count separately, the throw case is the real caller
  # failure; partial is tested by the workflow suite's injected helper seam.
  . $actualRequestBranch -GrantReservationDiagnostics
  Check ($serialWrites-eq4-and$s.port.calls-eq1-and$paramState.write_attempts-eq1) ('actualcaller countsoneattempt evenwhenreservationhelper '+$writeOutcome)
  . $actualRequestBranch -GrantReservationDiagnostics
  Check ($serialWrites-eq4-and$s.port.calls-eq1) 'actualcaller never recountsorretrieslatchedattempt'
  if($writeOutcome-ceq'throw'){Check ($reservationWorkflow.status-ceq'Failed'-and$null-eq$reservationWorkflow.held-and$reservationWorkflow.commands.Count-eq0) 'throwingPARAMcannot authorizeHeldorRelease'}
}
Write-Output "R19_GRANT_RESERVATION_CAPTURE PASS checks=$script:checks hardware_interaction=false output=$OutputDirectory"
