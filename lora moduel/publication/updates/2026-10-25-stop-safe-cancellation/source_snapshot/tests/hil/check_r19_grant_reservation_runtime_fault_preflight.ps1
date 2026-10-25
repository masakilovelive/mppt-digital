[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='', [switch]$BaselineProbe)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent(Split-Path -Parent $PSScriptRoot)}
if(-not$OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('runs/validation/R19-GRANT-RESERVATION-HEARTBEAT-STOP-FIX-OFFLINE-001/20261025T-fix/runner-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$script:checks=0
function Check([bool]$Value,[string]$Message){$script:checks++;if(-not$Value){throw ('FAIL '+$Message)}}
$capture=Join-Path $RepoRoot 'tools/run_r19_timed_path_capture.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($capture,[ref]$tokens,[ref]$errors)
Check (@($errors).Count-eq0) 'Actual capture source parses'
foreach($f in $ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]}){. ([scriptblock]::Create($f.Extent.Text))}
. (Join-Path $RepoRoot 'tools/r19_timed_path_acquisition.ps1') -ImportOnly
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_wire.ps1')
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_workflow.ps1')
. (Join-Path $RepoRoot 'tools/r19_param_list_diagnostics.ps1')
$branches=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Extent.Text.StartsWith('if($ParamListDiagnostics-and$s.spec.role')-and$n.Extent.Text.Contains('$attempted=Invoke-R19ParamListRequest')},$true))
Check ($branches.Count-eq1) 'Exactly one actual PARAM caller branch'
$actualParam=[scriptblock]::Create('[CmdletBinding()]param([switch]$GrantReservationDiagnostics)'+[Environment]::NewLine+$branches[0].Extent.Text)
# Exact immutable 63-byte frame from the observed Vehicle fault. This fixture
# contains no operator identity, credential, executable or live authorization.
[byte[]]$failureBytes=for($i=0;$i-lt126;$i+=2){[Convert]::ToByte('FD33000014FEBEFD000002523139463A563A314237343A303030303030303030303030393942433A3030303130303031303030323A3030303030303031D694'.Substring($i,2),16)}
function Reader([byte[]]$Bytes,[long]$EndTicks){
  $r=[pscustomobject]@{bytes=$Bytes;end=$EndTicks;calls=0}
  $r|Add-Member ScriptMethod GetStatus {[pscustomobject]@{Stopped=$false;Overflow=$false;Failure='';ByteCount=$this.bytes.Length;PendingByteCount=0;LastReadEndTicks=$this.end}}
  $r|Add-Member ScriptMethod GetSnapshot {[pscustomobject]@{Stopped=$false;Overflow=$false;Failure='';ByteCount=$this.bytes.Length;PendingByteCount=0;LastReadEndTicks=$this.end;Blocks=@([pscustomobject]@{Offset=0;Count=$this.bytes.Length;EndTicks=$this.end;BeginTicks=($this.end-100)})}}
  $r|Add-Member ScriptMethod ReadSlice {param([int]$Offset,[int]$Count)$this.calls++;if($Count-eq0){return ,[byte[]]@()};return ,[byte[]]$this.bytes[$Offset..($Offset+$Count-1)]}
  return $r
}
function Fixture {
  $nonce=[Convert]::ToUInt64('521B000000000001',16).ToString()
  $w=New-R19GrantReservationWorkflow -CandidateId SELFCONTAINED-RUNTIME-FAULT -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession 123 -SlotNonce $nonce -ClockDomainId fixture -Frequency 10000000 -StartTicks 190000000
  $w.prerequisites_validated=$true;$w.status='BoundReadyForOneParam'
  $w.hello_ground=ConvertFrom-R19GrantReservationFrame (New-R19GrantReservationFrame -Opcode HelloReply -Role ground -ReaderSession 123 -SlotNonce $nonce -BootId 100 -UsbEpoch 1 -GrantSession 661 -GrantCycle 2 -DeviceMs 20000)
  $w.hello_vehicle=ConvertFrom-R19GrantReservationFrame (New-R19GrantReservationFrame -Opcode HelloReply -Role vehicle -ReaderSession 123 -SlotNonce $nonce -BootId 200 -UsbEpoch 1 -DeviceMs 39000)
  $w.prepared=[pscustomobject]@{grant_session='661';grant_cycle='3';slot_token='77';generation='1'};$w.bound=$w.prepared
  foreach($name in @('Helloground','Hellovehicle','PrepareVehicle','BindPeerVehicle','BindGround','BindPeerGround')){$w.commands.Add([pscustomobject]@{kind=$name;write_success=$true;started_ticks='190000000';returned_ticks='190000001'})}
  $v=[pscustomobject]@{spec=[pscustomobject]@{role='vehicle'};reader=(Reader $failureBytes 200140199);reader_id='fixture-V';workflow=[pscustomobject]@{reply_read_validated=$true;reply=[pscustomobject]@{device_microseconds='39000000'};reply_read_completed_ticks='190000000'};workflow_failure=''}
  $g=[pscustomobject]@{spec=[pscustomobject]@{role='ground'};reader=(Reader ([byte[]]@()) 200140199);reader_id='fixture-G';workflow=[pscustomobject]@{reply_read_validated=$true;arm_write_accepted=$true;reply=[pscustomobject]@{device_microseconds='20000000'};reply_read_completed_ticks='190000000'};workflow_failure='';product_observations=[Collections.Generic.List[object]]::new();port=[pscustomobject]@{writes=0}}
  $g.product_observations.Add([pscustomobject]@{crc_valid=$true;system_id=1;component_id=1})
  $g.port|Add-Member ScriptMethod Write {param([byte[]]$Payload,[int]$Offset,[int]$Count)$this.writes++}
  [pscustomobject]@{reservation=$w;states=@($v,$g);ground=$g}
}
$f=Fixture;$reservationWorkflow=$f.reservation;$states=$f.states;$s=$f.ground
$ParamListDiagnostics=$true;$paramDiagnosticsFailure='';$paramState=New-R19ParamListDiagnosticsState -Frequency 10000000 -ClockDomainId fixture
$paramDeliveredOffset=0L;$deadline=600944377L;$serialWrites=0;$measurementStart='200500009';$clock=[pscustomobject]@{ElapsedTicks=200944377L}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
. $actualParam -GrantReservationDiagnostics
Check ($paramState.write_attempts-eq0-and$s.port.writes-eq0-and$serialWrites-eq0) 'Actual PARAM caller must inspect pending Vehicle R19F before the one OUT; fault precedes request by80.4178ms'
$p=Get-R19ParamListSnapshot $paramState
Check ($p.result-ceq'NOT_ATTEMPTED'-and$null-eq$p.request-and$null-eq$p.deadline_ticks) 'Before-request fault must not invent a request or t0'
Check ($reservationWorkflow.status-ceq'Failed'-and-not[string]::IsNullOrEmpty($reservationWorkflow.failure)) 'Known runtime stop is sticky and explicit, never WaitingVehicleTail with empty failure'
if($BaselineProbe){Write-Output ('RUNTIME_FAULT_PREFLIGHT behavioral PASS checks='+$script:checks);exit 0}
function Reject([scriptblock]$Action,[string]$Message){$threw=$false;try{&$Action|Out-Null}catch{$threw=$true};Check $threw $Message}
function Recrc([byte[]]$Bytes){[uint16]$c=65535;foreach($b in @($Bytes[1..60])+@(83)){$c=Update-R19ParamListCrc $c $b};$Bytes[61]=[byte]($c-band255);$Bytes[62]=[byte](($c-shr8)-band255);return ,$Bytes}
function RunPreflight([object]$F,[string]$Now='200944377'){Invoke-R19GrantReservationRuntimePreflight $F.reservation ([object[]]$F.states) $Now}
$d=ConvertFrom-R19GrantRuntimeFailure $failureBytes
Check ($d.valid-and$d.role-ceq'vehicle'-and$d.source_line-eq7028-and$d.device_ms-ceq'39356'-and$d.usb_epoch-ceq'1'-and-not$d.boot_build_identity_in_frame) 'Exact observed R19F fields and honest missing-identity semantics'
foreach($bad in @('crc','foreign-role','foreign-component','nonfatal-line','alive','unknown')){
  $f=Fixture;$bytes=[byte[]]$failureBytes.Clone()
  switch($bad){'crc'{$bytes[62]=$bytes[62]-bxor1} 'foreign-role'{$bytes[16]=[byte][char]'G';$bytes=Recrc $bytes} 'foreign-component'{$bytes[6]=189;$bytes=Recrc $bytes} 'nonfatal-line'{$bytes[18]=48;$bytes[19]=48;$bytes[20]=48;$bytes[21]=48;$bytes=Recrc $bytes} 'alive'{$bytes[14]=[byte][char]'A';$bytes=Recrc $bytes} 'unknown'{$bytes=[byte[]]@(1,2,3,4)}}
  $f.states[0].reader.bytes=$bytes
  $f.states[0]|Add-Member NoteProperty reservation_parser ([pscustomobject]@{next_raw_offset=$bytes.Length})
  Check (RunPreflight $f) ('Invalid/foreign/nonfatal observation must not fabricate runtime stop '+$bad)
  Check ($null-eq$f.reservation.runtime_fault_first-and$f.reservation.status-ceq'BoundReadyForOneParam') 'Rejected data cannot clear or advance reservation state'
}
$f=Fixture;Check (-not(RunPreflight $f)) 'Both-role native-prefix preflight blocks matching current runtime failure'
$first=$f.reservation.runtime_fault_first;$firstReason=$f.reservation.failure
Check ($first.binding-ceq'PROVENANCE_CONSISTENT_CONTINUOUS_READER'-and$first.hello_boot_id-ceq'200'-and$first.handoff_sha256-ceq('A'*64)-and$first.read_completed_ticks-ceq'200140199') 'Fault binds provenance/Hello/epoch/continuous reader and native completion, not PC-MCU equality'
Reject {Stop-R19GrantReservationWorkflow $f.reservation 'LATER_TIMEOUT'} 'Later timeout cannot resume failed workflow'
Check ($f.reservation.failure-ceq$firstReason-and$f.reservation.runtime_fault_first.frame_sha256-ceq$first.frame_sha256) 'First runtime cause is immutable'
foreach($mode in @('nohello','noclock','epoch','older-device-time')){
  $f=Fixture
  switch($mode){'nohello'{$f.reservation.hello_vehicle=$null} 'noclock'{$f.states[0].workflow.reply_read_validated=$false} 'epoch'{$f.reservation.hello_vehicle.usb_epoch='2'} 'older-device-time'{$f.reservation.hello_vehicle.device_ms='40000'}}
  Check (-not(RunPreflight $f)) ('Unbound/ambiguous same-role fault must deny unsafe writes '+$mode)
  Check ($f.reservation.runtime_fault_first.binding-cne'PROVENANCE_CONSISTENT_CONTINUOUS_READER'-and$f.reservation.param_attempts-eq0) 'Ambiguous evidence is not mislabeled exact current identity'
}
$f=Fixture;$f.states[0].reader.bytes=[byte[]]$failureBytes[0..31]
Check (-not(RunPreflight $f)-and$f.reservation.status-cne'Failed') 'Partial32 bytes defer OUT without fabricating a complete runtime fault'
$f.states[0].reader.bytes=$failureBytes
Check (-not(RunPreflight $f)) 'Immutable suffix completes63-byte fault without PollBytes consumption'
Check ($f.reservation.runtime_fault_monitors.vehicle.next_raw_offset-eq63) 'Native prefix cursor advances exactly once'
$f=Fixture;$f.states[0].reader.bytes=[byte[]]@();$w=$f.reservation
$command=New-R19GrantReservationWorkflowCommand $w 'ReleaseVehicle' ReleaseVehicle vehicle $w.hello_vehicle $w.prepared 26016
$w.status='Failed';$w.failure='FIRST_RUNTIME_STOP';$script:privateWrites=0
Reject {Invoke-R19ReservationPrivateWrite $w $command {'201854678'} {param([byte[]]$Bytes)$script:privateWrites++;return [int]$Bytes.Length}} 'A known stop must reject even an already-built private command'
Check ($script:privateWrites-eq0-and$null-eq$command.started_ticks) 'Known abort must not invoke writer or invent an attempted command'
$f=Fixture;$w=$f.reservation
Begin-R19GrantReservationParamWrite $w ([byte[]]@(253,2,0,0,99,255,190,21,0,0,1,1,213,7)) '200100000'
Set-R19GrantReservationParamWriteResult $w 14 '200110000'
Check (-not(RunPreflight $f)) 'Runtime fault after one realrequest attempt blocksRelease'
$after=Get-R19GrantReservationSnapshot $w
Check ($w.param_attempts-eq1-and$w.param_write_started_ticks-ceq'200100000'-and$after.request_outcome-ceq'ATTEMPTED_ABORT') 'After-attempt failure preserves actual original t0 and never relabelsNOT_ATTEMPTED'
Check ($after.ground_500ms_evaluation.result-ceq'NOT_EVALUATED'-and-not$after.ground_500ms_evaluation.high_speed_success-and$null-eq$after.ground_500ms_evaluation.ground_t0_ms) 'No matchingGroundHeld/actualfreshGrant is neither Ground500PASS nor inferredtimeout'
$f=Fixture;$w=$f.reservation
for($i=0;$i-lt128;$i++){$w.events.Add([pscustomobject]@{kind='synthetic-capacity'})}
Check (-not(RunPreflight $f)) 'Runtime stop remainsclosed evenwhen eventjournal isfull'
Check ($w.failure-ceq'RUNTIME_FAIL_CLOSED_VEHICLE') 'Eventcapacity cannot overwrite first actualruntimecause'
$f=Fixture;$w=$f.reservation;$f.states[0].reader.bytes=[byte[]]$failureBytes[0..31]
$c=New-R19GrantReservationWorkflowCommand $w ReleaseVehicle ReleaseVehicle vehicle $w.hello_vehicle $w.prepared 26016
$script:privateWrites=0
$null=Invoke-R19ReservationPrivateWrite $w $c {'201854678'} {param([byte[]]$Bytes)$script:privateWrites++;return [int]$Bytes.Length} -BeforeWrite {Invoke-R19GrantReservationRuntimePreflight $w ([object[]]$f.states) '201854678'}
Check ($script:privateWrites-eq0-and$null-eq$c.started_ticks-and$w.status-cne'Failed') 'Partialnativeprefix defers SAME pendingcommand without an APIattempt or falsehealth'
$again=Get-R19GrantReservationNextCommand $w '201854678'
Check ($again.index-eq$c.index-and$w.commands.Count-eq7) 'Deferred prefix doesnot create duplicatependingcommand or retry unknownOUT'
$f=Fixture;$reservationWorkflow=$f.reservation;$states=$f.states;$s=$f.ground
$clock=[pscustomobject]@{ElapsedTicks=200944377L};$f.states[0].reader.end=200944400L
$f.states[0].reader|Add-Member NoteProperty clock $clock
$f.states[0].reader|Add-Member -Force ScriptMethod GetSnapshot {$this.clock.ElapsedTicks=200944500L;[pscustomobject]@{Stopped=$false;Overflow=$false;Failure='';ByteCount=$this.bytes.Length;Blocks=@([pscustomobject]@{Offset=0;Count=$this.bytes.Length;EndTicks=$this.end})}}
$paramState=New-R19ParamListDiagnosticsState -Frequency 10000000 -ClockDomainId fixture;$serialWrites=0;$paramDiagnosticsFailure='';$measurementStart='200500009'
. $actualParam -GrantReservationDiagnostics
Check ($paramState.write_attempts-eq0-and$null-ne$reservationWorkflow.runtime_fault_first-and$reservationWorkflow.failure-ceq'RUNTIME_FAIL_CLOSED_VEHICLE') 'actualcaller resamplesclock AFTER snapshots; newlycompletedvalidfault isnot mislabeled futuretime'
$f=Fixture;$f.states[0].reader.end=200950000L
Reject {RunPreflight $f '200944377'} 'trulyfuture nativefault without laterclockproof isstillrejected'
Check ($f.reservation.status-ceq'Failed'-and$f.reservation.param_attempts-eq0) 'futuretimestamp cannot openrequestgate'
# A completed newlypublished product frame is not delivered merely because a
# non-consuming peek inspected it. PendingByteCount may already be zero after
# PollBytes batched removal while ordinary foreach is still behind.
[byte[]]$valueFrame=[byte[]]::new(37);$valueFrame[0]=253;$valueFrame[1]=25;$valueFrame[5]=1;$valueFrame[6]=1;$valueFrame[7]=22
$valueFrame[14]=164;$valueFrame[15]=3;$valueFrame[18]=80;$valueFrame[19]=48;$valueFrame[34]=9
[uint16]$valueCrc=65535;foreach($b in @($valueFrame[1..34])+@(220)){$valueCrc=Update-R19ParamListCrc $valueCrc $b};$valueFrame[35]=[byte]($valueCrc-band255);$valueFrame[36]=[byte]($valueCrc-shr8)
$f=Fixture;$reservationWorkflow=$f.reservation;$states=$f.states;$s=$f.ground;$f.states[0].reader.bytes=[byte[]]@();$s.reader.bytes=$valueFrame
$s|Add-Member NoteProperty reservation_parser ([pscustomobject]@{next_raw_offset=0L})
$clock=[pscustomobject]@{ElapsedTicks=200944377L};$paramState=New-R19ParamListDiagnosticsState -Frequency 10000000 -ClockDomainId fixture;$serialWrites=0;$paramDiagnosticsFailure='';$paramDeliveredOffset=0L
. $actualParam -GrantReservationDiagnostics
Check ($paramState.write_attempts-eq0-and$s.port.writes-eq0-and$reservationWorkflow.write_preflight_pending-and$reservationWorkflow.status-cne'Failed') 'stalePending0 cannot authorizePARAM whennewcompletePARAM_VALUE isnot ordinarilydelivered'
Add-R19ParamListBytes $paramState $valueFrame 200140199 0;$paramDeliveredOffset=37L;$s.reservation_parser.next_raw_offset=37L
. $actualParam -GrantReservationDiagnostics
Check ($paramState.write_attempts-eq1-and$s.port.writes-eq1-and$paramState.request_raw_offset-eq37) 'afterordinarydelivery synchronizedprefix allowsfirstonlyPARAM atactualoffset'
Check ($paramState.final.pre_request_count-eq1-and$paramState.final.unique_count-eq0-and$paramState.request_write_started_ticks-eq200944377L) 'pre-requestPARAM_VALUE never becomesresponse andoriginalactualt0 ispreserved'
Write-Output ('RUNTIME_FAULT_PREFLIGHT PASS checks='+$script:checks+' hardware_interaction=false')
