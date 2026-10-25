# Pure, bounded dual-USB diagnostic workflow. Writer/clock are explicit seams.
# USB OUT acceptance is local only; matching IN observations are distinct facts.
function Add-R19GrantReservationWorkflowEvent {
  param([object]$State,[string]$Kind,[object]$Details=$null)
  if($State.events.Count-ge128){$State.status='Failed';$State.failure='WORKFLOW_EVENT_CAPACITY';throw $State.failure}
  $State.events.Add([pscustomobject]@{ordinal=$State.events.Count+1;kind=$Kind;pc_ticks=$State.last_ticks;details=$Details})
}
function Stop-R19GrantReservationWorkflow {
  param([object]$State,[string]$Reason)
  if($State.status-cne'Failed'){$State.failure_phase=$State.status;$State.status='Failed';$State.failure=$Reason;$State.not_ready_count=1;Add-R19GrantReservationWorkflowEvent $State 'Failure' $Reason}
  throw $Reason
}
function New-R19GrantReservationWorkflow {
  param([string]$CandidateId,[string]$HandoffSha256,[string]$FlashSha256,[object]$ReaderSession,[object]$SlotNonce,
    [string]$ClockDomainId,[string]$Frequency,[string]$StartTicks)
  if($CandidateId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$'-or$HandoffSha256-cnotmatch'^[A-F0-9]{64}$'-or$FlashSha256-cnotmatch'^[A-F0-9]{64}$'-or[string]::IsNullOrWhiteSpace($ClockDomainId)){throw 'Unbound reservation candidate/provenance/clock'}
  [uint64]$reader=ConvertTo-R19GrantReservationUInt $ReaderSession 'reader_session';[uint64]$nonce=ConvertTo-R19GrantReservationUInt $SlotNonce 'slot_nonce'
  [void](New-R19GrantReservationFrame -Opcode HelloRequest -Role ground -ReaderSession $reader -SlotNonce $nonce)
  [uint64]$frequencyValue=ConvertTo-R19GrantReservationUInt $Frequency 'frequency' 1000000000
  [uint64]$start=ConvertTo-R19GrantReservationUInt $StartTicks 'start_ticks' 9223372036854775807 -AllowZero
  if([Numerics.BigInteger]$start+15*[Numerics.BigInteger]$frequencyValue-gt[long]::MaxValue){throw 'Reservation preparation deadline overflow'}
  [pscustomobject]@{schema='vc-lora-r19-grant-reservation-workflow-v1';status='WaitingPrerequisites';failure='';failure_phase='';not_ready_count=0;candidate_id=$CandidateId;handoff_sha256=$HandoffSha256;flash_evidence_sha256=$FlashSha256
    reader_session=$reader.ToString();slot_nonce=$nonce.ToString();clock_domain_id=$ClockDomainId;frequency=$frequencyValue.ToString();start_ticks=$start.ToString();last_ticks=$start.ToString();prepare_deadline_ticks=([Numerics.BigInteger]$start+15*[Numerics.BigInteger]$frequencyValue).ToString()
    prerequisites_validated=$false;hello_ground=$null;hello_vehicle=$null;prepared=$null;bound=$null;held=$null;tail_ready=$null
    commands=[Collections.Generic.List[object]]::new();observations=[Collections.Generic.List[object]]::new();events=[Collections.Generic.List[object]]::new();pending_command=$null
    param_attempts=0;param_write_started_ticks=$null;param_write_returned_ticks=$null;param_accepted_bytes=$null;param_write_exception='';param_frame_sha256='FC3A47A83D35D44E96E044A216FDBF082805F9FACCDD5E4B9252E0C7026D4A75'
    measurement_start_ticks=$null;ground_request_t0_ms=$null;vehicle_tail_ms=$null;high_speed_success_proven=$false;rf_delivery_proven=$false;acceptance_authorized=$false;deployment_authorized=$false}
}
function Update-R19GrantReservationWorkflow {
  param([object]$State,[string]$NowTicks,[string]$ClockDomainId='')
  if($State.schema-cne'vc-lora-r19-grant-reservation-workflow-v1'-or$State.status-ceq'Failed'){throw 'Invalid or failed reservation workflow'}
  [uint64]$now=ConvertTo-R19GrantReservationUInt $NowTicks 'now_ticks' 9223372036854775807 -AllowZero
  if($ClockDomainId-and$ClockDomainId-cne$State.clock_domain_id){Stop-R19GrantReservationWorkflow $State 'PC_CLOCK_DOMAIN_CHANGED'}
  if([Numerics.BigInteger]$now-lt[Numerics.BigInteger]$State.last_ticks){Stop-R19GrantReservationWorkflow $State 'PC_CLOCK_REGRESSION'}
  $State.last_ticks=$now.ToString()
  if($null-eq$State.bound-and[Numerics.BigInteger]$now-gt[Numerics.BigInteger]$State.prepare_deadline_ticks){Stop-R19GrantReservationWorkflow $State 'PREPARATION_15_SECONDS_EXPIRED'}
}
function Set-R19GrantReservationPrerequisites {
  param([object]$State,[bool]$GroundClockReplyValidated,[bool]$VehicleClockReplyValidated,[bool]$GroundArmWriteAccepted,[bool]$PrimaryHeartbeatAfterArm,[string]$NowTicks)
  Update-R19GrantReservationWorkflow $State $NowTicks
  if($State.prerequisites_validated){return}
  if($GroundClockReplyValidated-and$VehicleClockReplyValidated-and$GroundArmWriteAccepted-and$PrimaryHeartbeatAfterArm){$State.prerequisites_validated=$true;$State.status='HelloPending';Add-R19GrantReservationWorkflowEvent $State 'PrerequisitesValidated' 'PC-local clocks/ARM and CRC-valid primary post-ARM Heartbeat; not a reservation.'}
}
function Test-R19GrantReservationCommandCommitted {
  param([object]$State,[string]$Kind)
  return @($State.commands|Where-Object{$_.kind-ceq$Kind-and$_.write_success}).Count-eq1
}
function Assert-R19GrantReservationResponseAfterWrite {
  param([object]$State,[string[]]$Kinds,[string]$ReadCompletedTicks)
  [uint64]$read=ConvertTo-R19GrantReservationUInt $ReadCompletedTicks 'read_completed_ticks' 9223372036854775807 -AllowZero
  foreach($kind in $Kinds){
    $commands=@($State.commands|Where-Object{$_.kind-ceq$kind-and$_.write_success})
    if($commands.Count-ne1-or$null-eq$commands[0].started_ticks-or[Numerics.BigInteger]$read-lt[Numerics.BigInteger]$commands[0].started_ticks){Stop-R19GrantReservationWorkflow $State 'RESPONSE_NATIVE_READ_PRECEDES_MATCHING_OUT'}
  }
}
function New-R19GrantReservationWorkflowCommand {
  param([object]$State,[string]$Kind,[string]$Opcode,[string]$Role,[object]$Identity,[object]$Slot=$null,[string]$DeviceMs='0')
  if($null-ne$State.pending_command-or@($State.commands|Where-Object{$_.kind-ceq$Kind}).Count-ne0){Stop-R19GrantReservationWorkflow $State 'COMMAND_REPLAY_OR_PENDING'}
  $args=@{Opcode=$Opcode;Role=$Role;ReaderSession=$State.reader_session;SlotNonce=$State.slot_nonce;BootId=$Identity.boot_id;UsbEpoch=$Identity.usb_epoch;DeviceMs=$DeviceMs}
  if($null-ne$Slot){$args.GrantSession=$Slot.grant_session;$args.GrantCycle=$Slot.grant_cycle;$args.SlotToken=$Slot.slot_token;$args.Generation=$Slot.generation}
  [byte[]]$bytes=New-R19GrantReservationFrame @args
  $command=[pscustomobject]@{index=$State.commands.Count+1;kind=$Kind;opcode=$Opcode;role=$Role;bytes=$bytes;frame_base64=[Convert]::ToBase64String($bytes);built_ticks=$State.last_ticks;started_ticks=$null;returned_ticks=$null;accepted_bytes=$null;write_success=$false;error='';local_write_api_accepted_only=$true;remote_delivery_proven=$false}
  $State.commands.Add($command);$State.pending_command=$command;Add-R19GrantReservationWorkflowEvent $State 'CommandBuilt' $Kind;return $command
}
function Get-R19GrantReservationNextCommand {
  param([object]$State,[string]$NowTicks)
  Update-R19GrantReservationWorkflow $State $NowTicks
  if(-not$State.prerequisites_validated){return $null}
  if($null-ne$State.pending_command){Stop-R19GrantReservationWorkflow $State 'UNCOMMITTED_COMMAND_NO_RETRY'}
  foreach($role in @('ground','vehicle')){
    $kind='Hello'+$role
    if(-not(Test-R19GrantReservationCommandCommitted $State $kind)){
      return New-R19GrantReservationWorkflowCommand $State $kind HelloRequest $role ([pscustomobject]@{boot_id='0';usb_epoch='0'})
    }
  }
  if($null-eq$State.hello_ground-or$null-eq$State.hello_vehicle){return $null}
  if(-not(Test-R19GrantReservationCommandCommitted $State 'PrepareVehicle')){
    return New-R19GrantReservationWorkflowCommand $State 'PrepareVehicle' PrepareVehicle vehicle $State.hello_vehicle ([pscustomobject]@{grant_session=$State.hello_ground.grant_session;grant_cycle=$State.hello_ground.grant_cycle;slot_token='0';generation='0'})
  }
  if($null-eq$State.prepared){return $null}
  foreach($spec in @(@('BindPeerVehicle','BindPeerVehicle','vehicle','ground'),@('BindGround','BindGround','ground','ground'),@('BindPeerGround','BindPeerGround','ground','vehicle'))){
    if(-not(Test-R19GrantReservationCommandCommitted $State $spec[0])){$identity=if($spec[3]-ceq'ground'){$State.hello_ground}else{$State.hello_vehicle};return New-R19GrantReservationWorkflowCommand $State $spec[0] $spec[1] $spec[2] $identity $State.prepared}
  }
  if($null-eq$State.held){return $null}
  if(-not(Test-R19GrantReservationCommandCommitted $State 'ReleaseVehicle')){return New-R19GrantReservationWorkflowCommand $State 'ReleaseVehicle' ReleaseVehicle vehicle $State.hello_vehicle $State.prepared $State.ground_request_t0_ms}
  if($null-eq$State.tail_ready){return $null}
  if(-not(Test-R19GrantReservationCommandCommitted $State 'TailPermitGround')){return New-R19GrantReservationWorkflowCommand $State 'TailPermitGround' TailPermitGround ground $State.hello_vehicle $State.prepared $State.vehicle_tail_ms}
  return $null
}
function Set-R19GrantReservationWriteResult {
  param([object]$State,[object]$AcceptedBytes,[string]$StartedTicks,[string]$ReturnedTicks,[string]$ExceptionType='')
  Update-R19GrantReservationWorkflow $State $ReturnedTicks
  $c=$State.pending_command;if($null-eq$c){Stop-R19GrantReservationWorkflow $State 'WRITE_WITHOUT_PENDING_COMMAND'}
  $c.started_ticks=$StartedTicks;$c.returned_ticks=$ReturnedTicks;$c.accepted_bytes=$AcceptedBytes;$c.error=$ExceptionType
  if([Numerics.BigInteger]$StartedTicks-lt[Numerics.BigInteger]$c.built_ticks-or[Numerics.BigInteger]$ReturnedTicks-lt[Numerics.BigInteger]$StartedTicks){Stop-R19GrantReservationWorkflow $State 'INVALID_PRIVATE_WRITE_ORDER'}
  if(($AcceptedBytes-isnot[int]-and$AcceptedBytes-isnot[long])-or$AcceptedBytes-ne66-or$ExceptionType){Stop-R19GrantReservationWorkflow $State 'PRIVATE_WRITE_INCOMPLETE_NO_RETRY'}
  $c.write_success=$true;$State.pending_command=$null
  if($c.kind-ceq'ReleaseVehicle'){$State.status='WaitingVehicleTail'}
  elseif($c.kind-ceq'TailPermitGround'){$State.status='TailPermitWrittenAwaitingMcuEvidence'}
  Add-R19GrantReservationWorkflowEvent $State 'CommandWriteAccepted' $c.kind
}
function Test-R19GrantReservationTuple {
  param([object]$A,[object]$B)
  foreach($f in @('grant_session','grant_cycle','slot_token','generation')){if([string]$A.$f-cne[string]$B.$f){return $false}};return $true
}
function Test-R19GrantReservationNewerGrant {
  param([object]$Current,[object]$Baseline)
  $s=([long]$Current.grant_session-[long]$Baseline.grant_session+65536)%65536
  if($s-ne0){return $s-lt32768};$c=([long]$Current.grant_cycle-[long]$Baseline.grant_cycle+65536)%65536;return $c-gt0-and$c-lt32768
}
function Add-R19GrantReservationObservation {
  param([object]$State,[ValidateSet('ground','vehicle')][string]$ChannelRole,[byte[]]$Bytes,[string]$ReadCompletedTicks,[string]$NowTicks,[long]$RawOffset=0)
  Update-R19GrantReservationWorkflow $State $NowTicks
  $d=ConvertFrom-R19GrantReservationFrame $Bytes
  if(-not$d.valid-or$d.component-ne198-or$d.role-cne$ChannelRole-or$d.reader_session-cne$State.reader_session-or$d.slot_nonce-cne$State.slot_nonce){Stop-R19GrantReservationWorkflow $State 'INVALID_OR_UNBOUND_RESERVATION_RESPONSE'}
  if([Numerics.BigInteger]$ReadCompletedTicks-gt[Numerics.BigInteger]$NowTicks){Stop-R19GrantReservationWorkflow $State 'RESPONSE_NATIVE_READ_IN_FUTURE'}
  $hello=if($ChannelRole-ceq'ground'){$State.hello_ground}else{$State.hello_vehicle}
  if($d.opcode-ceq'HelloReply'){
    $kind='Hello'+$ChannelRole
    if(-not(Test-R19GrantReservationCommandCommitted $State $kind)-or$null-ne$hello){Stop-R19GrantReservationWorkflow $State 'HELLO_RESPONSE_REPLAY_OR_UNREQUESTED'}
    Assert-R19GrantReservationResponseAfterWrite $State @($kind) $ReadCompletedTicks
    if($ChannelRole-ceq'ground'){$State.hello_ground=$d}else{$State.hello_vehicle=$d}
  }else{
    if($null-eq$hello-or$d.boot_id-cne$hello.boot_id-or$d.usb_epoch-cne$hello.usb_epoch){Stop-R19GrantReservationWorkflow $State 'RESPONSE_BOOT_OR_EPOCH_CHANGED'}
    switch -CaseSensitive ($d.opcode){
      'Prepared'{
        if(-not(Test-R19GrantReservationCommandCommitted $State 'PrepareVehicle')-or$null-ne$State.prepared-or-not(Test-R19GrantReservationNewerGrant $d $State.hello_ground)){Stop-R19GrantReservationWorkflow $State 'PREPARED_NOT_FRESH_OR_REPLAYED'}
        Assert-R19GrantReservationResponseAfterWrite $State @('PrepareVehicle') $ReadCompletedTicks
        $State.prepared=$d;$State.status='BindingGroundAndVehicle'
      }
      'Bound'{
        foreach($kind in @('BindPeerVehicle','BindGround','BindPeerGround')){if(-not(Test-R19GrantReservationCommandCommitted $State $kind)){Stop-R19GrantReservationWorkflow $State 'BOUND_BEFORE_MATCHING_BIND_WRITES'}}
        if($null-ne$State.bound-or-not(Test-R19GrantReservationTuple $d $State.prepared)){Stop-R19GrantReservationWorkflow $State 'BOUND_SLOT_REPLAY_OR_MISMATCH'}
        Assert-R19GrantReservationResponseAfterWrite $State @('BindPeerVehicle','BindGround','BindPeerGround') $ReadCompletedTicks
        $State.bound=$d;$State.status='BoundReadyForOneParam'
      }
      'GroundHeld'{
        if($State.param_attempts-ne1-or$State.param_accepted_bytes-ne14-or$State.param_write_exception-or$null-ne$State.held-or-not(Test-R19GrantReservationTuple $d $State.prepared)){Stop-R19GrantReservationWorkflow $State 'HELD_WITHOUT_ONE_EXACT_REQUEST_OR_WRONG_SLOT'}
        if([Numerics.BigInteger]$ReadCompletedTicks-lt[Numerics.BigInteger]$State.param_write_started_ticks){Stop-R19GrantReservationWorkflow $State 'HELD_PRECEDES_REQUEST'}
        $State.held=$d;$State.ground_request_t0_ms=$d.device_ms;$State.status='GroundHeldReadyToRelease'
      }
      'TailReady'{
        if(-not(Test-R19GrantReservationCommandCommitted $State 'ReleaseVehicle')-or$null-ne$State.tail_ready-or-not(Test-R19GrantReservationTuple $d $State.prepared)){Stop-R19GrantReservationWorkflow $State 'TAIL_WITHOUT_RELEASE_OR_WRONG_SLOT'}
        Assert-R19GrantReservationResponseAfterWrite $State @('ReleaseVehicle') $ReadCompletedTicks
        $State.tail_ready=$d;$State.vehicle_tail_ms=$d.device_ms;$State.status='VehicleTailObservedReadyToPermit'
      }
      'Fault'{Stop-R19GrantReservationWorkflow $State 'MCU_RESERVATION_FAULT_REASON_IN_JTAG'}
      default{Stop-R19GrantReservationWorkflow $State 'UNEXPECTED_RESERVATION_RESPONSE_OPCODE'}
    }
  }
  if($State.observations.Count-ge32){Stop-R19GrantReservationWorkflow $State 'RESPONSE_CAPACITY'}
  $State.observations.Add([pscustomobject]@{role=$ChannelRole;decoded=$d;read_completed_ticks=$ReadCompletedTicks;observation_ticks=$NowTicks;raw_offset=$RawOffset;frame_base64=[Convert]::ToBase64String($Bytes)})
  Add-R19GrantReservationWorkflowEvent $State 'ResponseValidated' $d.opcode
}
function Test-R19GrantReservationRequestAllowed {
  param([object]$State,[string]$NowTicks)
  if($null-eq$State){return $false};Update-R19GrantReservationWorkflow $State $NowTicks
  return $State.status-ceq'BoundReadyForOneParam'-and$null-ne$State.bound-and$null-ne$State.prepared-and$State.param_attempts-eq0-and$null-eq$State.pending_command
}
function Begin-R19GrantReservationParamWrite {
  param([object]$State,[byte[]]$Bytes,[string]$StartedTicks)
  if(-not(Test-R19GrantReservationRequestAllowed $State $StartedTicks)){Stop-R19GrantReservationWorkflow $State 'PARAM_NOT_BOUND_OR_REPLAYED'}
  if($null-eq$Bytes-or([BitConverter]::ToString($Bytes).Replace('-',''))-cne'FD02000063FFBE1500000101D507'){Stop-R19GrantReservationWorkflow $State 'PARAM_NOT_EXACT_FROZEN_FRAME'}
  $State.param_attempts=1;$State.param_write_started_ticks=$StartedTicks;$State.status='ParamWritePending';Add-R19GrantReservationWorkflowEvent $State 'ParamWriteAttempt' 'exact14 bytes; one attempt latched before writer'
}
function Set-R19GrantReservationParamWriteResult {
  param([object]$State,[object]$AcceptedBytes,[string]$ReturnedTicks,[string]$ExceptionType='')
  Update-R19GrantReservationWorkflow $State $ReturnedTicks
  if($State.status-cne'ParamWritePending'-or$State.param_attempts-ne1){Stop-R19GrantReservationWorkflow $State 'PARAM_COMMIT_WITHOUT_ATTEMPT'}
  $State.param_write_returned_ticks=$ReturnedTicks;$State.param_accepted_bytes=$AcceptedBytes;$State.param_write_exception=$ExceptionType
  if(($AcceptedBytes-isnot[int]-and$AcceptedBytes-isnot[long])-or$AcceptedBytes-ne14-or$ExceptionType){Stop-R19GrantReservationWorkflow $State 'PARAM_WRITE_INCOMPLETE_NO_RETRY'}
  $State.status='WaitingGroundHeld';Add-R19GrantReservationWorkflowEvent $State 'ParamWriteAccepted' 'PC-local acceptance only'
}
function Invoke-R19ReservationPrivateWrite {
  param([object]$State,[object]$Command,[scriptblock]$NowTicks,[scriptblock]$Writer)
  $start=[string](&$NowTicks);$accepted=$null;$errorType=''
  if($null-eq$State.pending_command-or$State.pending_command.index-ne$Command.index-or$null-ne$Command.started_ticks){Stop-R19GrantReservationWorkflow $State 'PRIVATE_WRITE_NOT_PENDING_OR_REPLAYED'}
  # Fix the attempt evidence before the callback: a throw has an unknown prefix,
  # and a built but unattempted command must not count as an OUT API invocation.
  $Command.started_ticks=$start
  try{$accepted=&$Writer ([byte[]]$Command.bytes)}catch{$errorType=$_.Exception.GetType().FullName}
  Set-R19GrantReservationWriteResult $State $accepted $start ([string](&$NowTicks)) $errorType
  return $Command
}
function Get-R19GrantReservationSnapshot {
  param([object]$State)
  if($null-eq$State){return $null}
  $copy=$State|ConvertTo-Json -Depth 16 -Compress|ConvertFrom-Json
  $copy|Add-Member NoteProperty actual_negotiation_start_ms $null
  $copy|Add-Member NoteProperty actual_bulk_start_ms $null
  $copy|Add-Member NoteProperty observation_scope 'USB_CONTROL_SEQUENCE_ONLY_ACTUAL_MCU_PROTOCOL_EVIDENCE_REQUIRES_BOUND_JTAG_RECORDS'
  return $copy
}
