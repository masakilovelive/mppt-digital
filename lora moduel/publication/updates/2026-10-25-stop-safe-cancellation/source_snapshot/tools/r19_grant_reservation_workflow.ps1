# Pure, bounded dual-USB diagnostic workflow. Writer/clock are explicit seams.
# USB OUT acceptance is local only; matching IN observations are distinct facts.
function ConvertFrom-R19GrantRuntimeFailure {
  param([byte[]]$Bytes)
  $invalid=[pscustomobject]@{valid=$false;reason='NotRuntimeFailure';role='';source_line=0;device_ms='';usb_epoch=''}
  if($null-eq$Bytes-or$Bytes.Length-ne63-or$Bytes[0]-ne253-or$Bytes[1]-ne51-or$Bytes[2]-ne0-or$Bytes[3]-ne0-or$Bytes[5]-ne254-or$Bytes[6]-ne190-or$Bytes[7]-ne253-or$Bytes[8]-ne0-or$Bytes[9]-ne0-or$Bytes[10]-ne2){return $invalid}
  $text=[Text.Encoding]::ASCII.GetString($Bytes,11,50)
  if($text-cnotmatch'^R19F:([GV]):([0-9A-F]{4}):([0-9A-F]{16}):([0-9A-F]{12}):([0-9A-F]{8})$'){return $invalid}
  $parts=@($Matches[1],$Matches[2],$Matches[3],$Matches[4],$Matches[5])
  [uint16]$crc=65535
  foreach($value in @($Bytes[1..60])+@(83)){[uint16]$tmp=([uint16]$value-bxor($crc-band255));$tmp=($tmp-bxor(($tmp-shl4)-band255))-band255;$crc=(($crc-shr8)-bxor($tmp-shl8)-bxor($tmp-shl3)-bxor($tmp-shr4))-band65535}
  if($crc-ne([uint16]$Bytes[61]-bor([uint16]$Bytes[62]-shl8))){$invalid.reason='InvalidRuntimeFailureCrc';return $invalid}
  $line=[Convert]::ToUInt16($parts[1],16)
  if($line-eq0){$invalid.reason='ZeroSourceLineNotFatalMarker';return $invalid}
  [pscustomobject]@{valid=$true;reason='';role=$(if($parts[0]-ceq'G'){'ground'}else{'vehicle'});source_line=[int]$line;device_ms=[Convert]::ToUInt64($parts[2],16).ToString();status_hex=$parts[3];usb_epoch=[Convert]::ToUInt32($parts[4],16).ToString();text=$text;boot_build_identity_in_frame=$false}
}
function New-R19GrantRuntimeFailureMonitor {
  [pscustomobject]@{reader_id='';next_raw_offset=0L;buffer_raw_offset=0L;buffer=[Collections.Generic.List[byte]]::new();input_bytes=0L;invalid_crc=0;nonfatal_or_unknown_frames=0;foreign_role_frames=0;noise_bytes=0;observations=0}
}
function Add-R19GrantRuntimeFailureFrame {
  param([object]$State,[object]$RoleState,[byte[]]$Bytes,[string]$ReadCompletedTicks,[string]$NowTicks,[long]$RawOffset)
  $role=[string]$RoleState.spec.role;$monitor=$State.runtime_fault_monitors.$role
  $d=ConvertFrom-R19GrantRuntimeFailure $Bytes
  if(-not$d.valid){if($d.reason-ceq'InvalidRuntimeFailureCrc'){$monitor.invalid_crc++}else{$monitor.nonfatal_or_unknown_frames++};return}
  if($d.role-cne$role){$monitor.foreign_role_frames++;return}
  if($null-ne$State.runtime_faults.$role){return}
  if([Numerics.BigInteger]$ReadCompletedTicks-gt[Numerics.BigInteger]$NowTicks){Stop-R19GrantReservationWorkflow $State 'RUNTIME_FAILURE_READ_IN_FUTURE'}
  $hello=if($role-ceq'ground'){$State.hello_ground}else{$State.hello_vehicle}
  $clockValid=$null-ne$RoleState.workflow-and$RoleState.workflow.reply_read_validated-is[bool]-and$RoleState.workflow.reply_read_validated
  $binding='UNBOUND_RUNTIME_FAILURE';$reason='UNBOUND_RUNTIME_FAILURE_'+$role.ToUpperInvariant()
  if($null-ne$hello-and$clockValid){
    if($d.usb_epoch-ceq$hello.usb_epoch-and[Numerics.BigInteger]$d.device_ms-ge[Numerics.BigInteger]$hello.device_ms){$binding='PROVENANCE_CONSISTENT_CONTINUOUS_READER';$reason='RUNTIME_FAIL_CLOSED_'+$role.ToUpperInvariant()}
    else{$binding='AMBIGUOUS_ROLE_EPOCH_OR_BOOT_TIME';$reason='AMBIGUOUS_RUNTIME_FAILURE_IDENTITY_'+$role.ToUpperInvariant()}
  }
  $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','')}finally{$sha.Dispose()}
  $fault=[pscustomobject]@{kind='R19F_RUNTIME_FAIL_CLOSED';role=$role;decoded=$d;binding=$binding;boot_build_identity_in_frame=$false;candidate_id=$State.candidate_id;handoff_sha256=$State.handoff_sha256;flash_evidence_sha256=$State.flash_evidence_sha256;reader_id=$monitor.reader_id;reader_session=$State.reader_session;slot_nonce=$State.slot_nonce;hello_boot_id=$(if($null-ne$hello){$hello.boot_id}else{$null});hello_epoch=$(if($null-ne$hello){$hello.usb_epoch}else{$null});clock_reply_validated=$clockValid;raw_offset=$RawOffset;raw_last_offset=($RawOffset+62);read_completed_ticks=$ReadCompletedTicks;observed_ticks=$NowTicks;frame_sha256=$hash;frame_base64=[Convert]::ToBase64String($Bytes);binding_limitation='R19F has no boot/build/session identity. Binding is a source/flash-bound uninterrupted physical-role reader chain, not authentication or identity encoded in the frame.'}
  $State.runtime_faults.$role=$fault;$monitor.observations++
  if($null-eq$State.runtime_fault_first){$State.runtime_fault_first=$fault}
  if($State.status-cne'Failed'){try{Stop-R19GrantReservationWorkflow $State $reason}catch{}}
}
function Add-R19GrantReservationRuntimeBlock {
  param([object]$State,[object]$RoleState,[object]$Block,[string]$NowTicks)
  $role=[string]$RoleState.spec.role
  if($role-cnotin@('ground','vehicle')){Stop-R19GrantReservationWorkflow $State 'RUNTIME_FAILURE_UNKNOWN_ROLE_READER'}
  $m=$State.runtime_fault_monitors.$role
  if(-not$m.reader_id){$m.reader_id=[string]$RoleState.reader_id}
  if(-not$m.reader_id-or$m.reader_id-cne[string]$RoleState.reader_id){Stop-R19GrantReservationWorkflow $State 'RUNTIME_FAILURE_READER_IDENTITY_CHANGED'}
  [long]$begin=$Block.Offset;[byte[]]$bytes=$Block.Data;[long]$end=$begin+$bytes.Length
  if($end-le$m.next_raw_offset){return}
  if($begin-gt$m.next_raw_offset-or$bytes.Length-gt8192){Stop-R19GrantReservationWorkflow $State 'RUNTIME_FAILURE_RAW_PREFIX_GAP_OR_CAPACITY'}
  [int]$skip=[int]($m.next_raw_offset-$begin)
  for($i=$skip;$i-lt$bytes.Length;$i++){$m.buffer.Add($bytes[$i]);$m.next_raw_offset++;$m.input_bytes++}
  if($m.buffer.Count-gt16384){Stop-R19GrantReservationWorkflow $State 'RUNTIME_FAILURE_PARSER_CAPACITY'}
  while($m.buffer.Count-gt0){
    $b=$m.buffer
    if($b[0]-ne253-and$b[0]-ne254){$b.RemoveAt(0);$m.buffer_raw_offset++;$m.noise_bytes++;continue}
    $header=if($b[0]-eq253){10}else{6};if($b.Count-lt$header){break}
    $length=$header+[int]$b[1]+2;if($b[0]-eq253-and($b[2]-band1)-ne0){$length+=13};if($b.Count-lt$length){break}
    [byte[]]$frame=$b.GetRange(0,$length).ToArray()
    Add-R19GrantRuntimeFailureFrame $State $RoleState $frame ([string]$Block.EndTicks) $NowTicks $m.buffer_raw_offset
    if($State.status-cne'Failed'){
      $control=ConvertFrom-R19GrantReservationFrame $frame
      if($control.valid-and$control.opcode-ceq'Fault'-and$control.component-eq198-and$control.role-ceq$role){
        Add-R19GrantReservationObservation $State $role $frame ([string]$Block.EndTicks) $NowTicks $m.buffer_raw_offset -Prepeek
      }elseif($State.cancellation_enabled-and$control.valid-and$control.opcode-ceq'Withdrawn'-and$control.component-eq198-and$control.role-ceq$role){
        if($null-eq$State.prepared){
          # Prepared may be earlier in THIS retained native block but not yet at
          # the ordinary parser cursor. Do not reorder Withdrawn ahead of it.
          # Hold all OUT gates closed until normal causal parsing consumes it.
          if($State.deferred_withdrawals.Count-ge2){Stop-R19GrantReservationWorkflow $State 'DEFERRED_WITHDRAWAL_CAPACITY'}
          $State.deferred_withdrawals.Add([pscustomobject]@{role=$role;raw_offset=$m.buffer_raw_offset;read_completed_ticks=[string]$Block.EndTicks;frame_base64=[Convert]::ToBase64String($frame)})
        }else{Add-R19GrantReservationObservation $State $role $frame ([string]$Block.EndTicks) $NowTicks $m.buffer_raw_offset -Prepeek}
      }
    }
    $b.RemoveRange(0,$length);$m.buffer_raw_offset+=$length
  }
}
function Invoke-R19GrantReservationRuntimePreflight {
  param([object]$State,[object[]]$States,[string]$NowTicks,[string]$Purpose='BeforeWrite',[scriptblock]$NowTicksProvider=$null)
  if($null-eq$State-or$State.status-ceq'Failed'){return $false}
  $State.write_preflight_pending=$false
  $snapshots=@{}
  foreach($role in @('vehicle','ground')){
    $rows=@($States|Where-Object{$_.spec.role-ceq$role});if($rows.Count-ne1){Stop-R19GrantReservationWorkflow $State 'RUNTIME_FAILURE_READER_SET_NOT_BOUND'}
    $snapshots[$role]=[pscustomobject]@{state=$rows[0];snapshot=$rows[0].reader.GetSnapshot()}
  }
  # Both immutable prefixes are fixed BEFORE sampling the shared PC clock.
  # Sampling before GetSnapshot can mislabel a newly published native block as
  # future data. The default explicit value remains useful for pure fixtures.
  if($null-ne$NowTicksProvider){$NowTicks=[string](&$NowTicksProvider)}
  foreach($role in @('vehicle','ground')){
    $r=$snapshots[$role].state;$snapshot=$snapshots[$role].snapshot
    if($snapshot.Stopped-or$snapshot.Overflow-or-not[string]::IsNullOrEmpty($snapshot.Failure)){Stop-R19GrantReservationWorkflow $State 'RUNTIME_FAILURE_READER_NOT_CONTINUOUS'}
    if(@($snapshot.Blocks).Count-gt4096-or[long]$snapshot.ByteCount-lt0-or[long]$snapshot.ByteCount-gt1048576){Stop-R19GrantReservationWorkflow $State 'RUNTIME_FAILURE_NATIVE_HISTORY_CAPACITY'}
    $m=$State.runtime_fault_monitors.$role
    foreach($block in @($snapshot.Blocks)){
      [long]$end=[long]$block.Offset+[long]$block.Count
      if($end-le$m.next_raw_offset){continue}
      if([long]$block.Offset-gt$m.next_raw_offset){Stop-R19GrantReservationWorkflow $State 'RUNTIME_FAILURE_NATIVE_BLOCK_GAP'}
      while($m.next_raw_offset-lt$end){
        [long]$offset=$m.next_raw_offset;[int]$count=[int][Math]::Min(8192L,$end-$offset)
        $piece=[pscustomobject]@{Offset=$offset;Data=[byte[]]$r.reader.ReadSlice([int]$offset,$count);EndTicks=$block.EndTicks}
        Add-R19GrantReservationRuntimeBlock $State $r $piece $NowTicks
      }
    }
    if($m.next_raw_offset-ne[long]$snapshot.ByteCount){Stop-R19GrantReservationWorkflow $State 'RUNTIME_FAILURE_NATIVE_PREFIX_UNPROVEN'}
  }
  if($State.status-ceq'Failed'){return $false}
  foreach($role in @('vehicle','ground')){
    $r=$snapshots[$role].state;$snapshot=$snapshots[$role].snapshot
    [long]$delivered=0
    if($null-ne$r.PSObject.Properties['reservation_parser']-and$null-ne$r.reservation_parser){$delivered=[long]$r.reservation_parser.next_raw_offset}
    # A peek is NOT ordinary parser/ledger delivery. Complete but newly
    # published bytes must be causally consumed before sampling request t0.
    if($delivered-ne[long]$snapshot.ByteCount){$State.write_preflight_pending=$true;return $false}
  }
  if($State.runtime_fault_monitors.ground.buffer.Count-gt0-or$State.runtime_fault_monitors.vehicle.buffer.Count-gt0-or$State.deferred_withdrawals.Count-gt0){$State.write_preflight_pending=$true;return $false}
  return $true
}
function Add-R19GrantReservationWorkflowEvent {
  param([object]$State,[string]$Kind,[object]$Details=$null)
  if($State.events.Count-ge128){if($State.status-cne'Failed'){$State.status='Failed';$State.failure='WORKFLOW_EVENT_CAPACITY'};throw $State.failure}
  $State.events.Add([pscustomobject]@{ordinal=$State.events.Count+1;kind=$Kind;pc_ticks=$State.last_ticks;details=$Details})
}
function Stop-R19GrantReservationWorkflow {
  param([object]$State,[string]$Reason)
  if($State.status-cne'Failed'){$State.failure_phase=$State.status;$State.status='Failed';$State.failure=$Reason;$State.not_ready_count=1;Add-R19GrantReservationWorkflowEvent $State 'Failure' $Reason}
  throw $Reason
}
function New-R19GrantReservationWorkflow {
  param([string]$CandidateId,[string]$HandoffSha256,[string]$FlashSha256,[object]$ReaderSession,[object]$SlotNonce,
    [string]$ClockDomainId,[string]$Frequency,[string]$StartTicks,[bool]$CancellationEnabled=$false)
  if($CandidateId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$'-or$HandoffSha256-cnotmatch'^[A-F0-9]{64}$'-or$FlashSha256-cnotmatch'^[A-F0-9]{64}$'-or[string]::IsNullOrWhiteSpace($ClockDomainId)){throw 'Unbound reservation candidate/provenance/clock'}
  [uint64]$reader=ConvertTo-R19GrantReservationUInt $ReaderSession 'reader_session';[uint64]$nonce=ConvertTo-R19GrantReservationUInt $SlotNonce 'slot_nonce'
  [void](New-R19GrantReservationFrame -Opcode HelloRequest -Role ground -ReaderSession $reader -SlotNonce $nonce)
  [uint64]$frequencyValue=ConvertTo-R19GrantReservationUInt $Frequency 'frequency' 1000000000
  [uint64]$start=ConvertTo-R19GrantReservationUInt $StartTicks 'start_ticks' 9223372036854775807 -AllowZero
  if([Numerics.BigInteger]$start+15*[Numerics.BigInteger]$frequencyValue-gt[long]::MaxValue){throw 'Reservation preparation deadline overflow'}
  [pscustomobject]@{schema='vc-lora-r19-grant-reservation-workflow-v1';status='WaitingPrerequisites';failure='';failure_phase='';not_ready_count=0;candidate_id=$CandidateId;handoff_sha256=$HandoffSha256;flash_evidence_sha256=$FlashSha256
    reader_session=$reader.ToString();slot_nonce=$nonce.ToString();clock_domain_id=$ClockDomainId;frequency=$frequencyValue.ToString();start_ticks=$start.ToString();last_ticks=$start.ToString();prepare_deadline_ticks=([Numerics.BigInteger]$start+15*[Numerics.BigInteger]$frequencyValue).ToString()
    prerequisites_validated=$false;hello_ground=$null;hello_vehicle=$null;prepared=$null;bound=$null;held=$null;tail_ready=$null
    cancellation_enabled=$CancellationEnabled;wire_version=$(if($CancellationEnabled){2}else{1});round=1;cancellation_count=0;maximum_cancellations=1;maximum_rounds=2;cancelling=$false;withdrawn=$null;cancel_ground=$null;cancel_vehicle=$null;peer_confirm_ground=$null;peer_confirm_vehicle=$null;retired_slot=$null;retired_nonces=[Collections.Generic.List[string]]::new();prepeeked_withdrawals=[Collections.Generic.List[object]]::new();deferred_withdrawals=[Collections.Generic.List[object]]::new();obsolete_controls=[Collections.Generic.List[object]]::new();control_fault_first=$null
    commands=[Collections.Generic.List[object]]::new();observations=[Collections.Generic.List[object]]::new();events=[Collections.Generic.List[object]]::new();pending_command=$null
    param_attempts=0;param_write_started_ticks=$null;param_write_returned_ticks=$null;param_accepted_bytes=$null;param_write_exception='';param_frame_sha256='FC3A47A83D35D44E96E044A216FDBF082805F9FACCDD5E4B9252E0C7026D4A75'
    runtime_fault_monitors=[pscustomobject]@{ground=(New-R19GrantRuntimeFailureMonitor);vehicle=(New-R19GrantRuntimeFailureMonitor)};runtime_faults=[pscustomobject]@{ground=$null;vehicle=$null};runtime_fault_first=$null;write_preflight_pending=$false
    measurement_start_ticks=$null;ground_request_t0_ms=$null;vehicle_tail_ms=$null;high_speed_success_proven=$false;rf_delivery_proven=$false;acceptance_authorized=$false;deployment_authorized=$false}
}
function Update-R19GrantReservationWorkflow {
  param([object]$State,[string]$NowTicks,[string]$ClockDomainId='')
  if($State.schema-cne'vc-lora-r19-grant-reservation-workflow-v1'-or$State.status-ceq'Failed'){throw 'Invalid or failed reservation workflow'}
  [uint64]$now=ConvertTo-R19GrantReservationUInt $NowTicks 'now_ticks' 9223372036854775807 -AllowZero
  if($ClockDomainId-and$ClockDomainId-cne$State.clock_domain_id){Stop-R19GrantReservationWorkflow $State 'PC_CLOCK_DOMAIN_CHANGED'}
  if([Numerics.BigInteger]$now-lt[Numerics.BigInteger]$State.last_ticks){Stop-R19GrantReservationWorkflow $State 'PC_CLOCK_REGRESSION'}
  $State.last_ticks=$now.ToString()
  if(($null-eq$State.bound-or($State.cancellation_enabled-and$State.param_attempts-eq0))-and[Numerics.BigInteger]$now-gt[Numerics.BigInteger]$State.prepare_deadline_ticks){Stop-R19GrantReservationWorkflow $State 'PREPARATION_15_SECONDS_EXPIRED'}
}
function Set-R19GrantReservationPrerequisites {
  param([object]$State,[bool]$GroundClockReplyValidated,[bool]$VehicleClockReplyValidated,[bool]$GroundArmWriteAccepted,[bool]$PrimaryHeartbeatAfterArm,[string]$NowTicks)
  Update-R19GrantReservationWorkflow $State $NowTicks
  if($State.prerequisites_validated){return}
  if($GroundClockReplyValidated-and$VehicleClockReplyValidated-and$GroundArmWriteAccepted-and$PrimaryHeartbeatAfterArm){$State.prerequisites_validated=$true;$State.status='HelloPending';Add-R19GrantReservationWorkflowEvent $State 'PrerequisitesValidated' 'PC-local clocks/ARM and CRC-valid primary post-ARM Heartbeat; not a reservation.'}
}
function Test-R19GrantReservationCommandCommitted {
  param([object]$State,[string]$Kind)
  return @(Get-R19GrantReservationRoundCommands $State|Where-Object{$_.kind-ceq$Kind-and$_.write_success}).Count-eq1
}
function Get-R19GrantReservationRoundCommands {
  param([object]$State)
  foreach($c in $State.commands){$round=if($null-ne$c.PSObject.Properties['round']){[int]$c.round}else{1};if($round-eq$State.round){$c}}
}
function Assert-R19GrantReservationResponseAfterWrite {
  param([object]$State,[string[]]$Kinds,[string]$ReadCompletedTicks)
  [uint64]$read=ConvertTo-R19GrantReservationUInt $ReadCompletedTicks 'read_completed_ticks' 9223372036854775807 -AllowZero
  foreach($kind in $Kinds){
    $commands=@(Get-R19GrantReservationRoundCommands $State|Where-Object{$_.kind-ceq$kind-and$_.write_success})
    if($commands.Count-ne1-or$null-eq$commands[0].started_ticks-or[Numerics.BigInteger]$read-lt[Numerics.BigInteger]$commands[0].started_ticks){Stop-R19GrantReservationWorkflow $State 'RESPONSE_NATIVE_READ_PRECEDES_MATCHING_OUT'}
  }
}
function New-R19GrantReservationWorkflowCommand {
  param([object]$State,[string]$Kind,[string]$Opcode,[string]$Role,[object]$Identity,[object]$Slot=$null,[string]$DeviceMs='0')
  if($null-ne$State.pending_command-or@(Get-R19GrantReservationRoundCommands $State|Where-Object{$_.kind-ceq$Kind}).Count-ne0-or$State.commands.Count-ge18){Stop-R19GrantReservationWorkflow $State 'COMMAND_REPLAY_OR_PENDING_OR_CAPACITY'}
  $args=@{Opcode=$Opcode;Role=$Role;ReaderSession=$State.reader_session;SlotNonce=$State.slot_nonce;BootId=$Identity.boot_id;UsbEpoch=$Identity.usb_epoch;DeviceMs=$DeviceMs;Version=$State.wire_version}
  if($null-ne$Slot){$args.GrantSession=$Slot.grant_session;$args.GrantCycle=$Slot.grant_cycle;$args.SlotToken=$Slot.slot_token;$args.Generation=$Slot.generation}
  [byte[]]$bytes=New-R19GrantReservationFrame @args
  $command=[pscustomobject]@{index=$State.commands.Count+1;round=$State.round;kind=$Kind;opcode=$Opcode;role=$Role;bytes=$bytes;frame_base64=[Convert]::ToBase64String($bytes);built_ticks=$State.last_ticks;started_ticks=$null;returned_ticks=$null;accepted_bytes=$null;write_success=$false;error='';local_write_api_accepted_only=$true;remote_delivery_proven=$false}
  $State.commands.Add($command);$State.pending_command=$command;Add-R19GrantReservationWorkflowEvent $State 'CommandBuilt' $Kind;return $command
}
function Get-R19GrantReservationNextCommand {
  param([object]$State,[string]$NowTicks)
  Update-R19GrantReservationWorkflow $State $NowTicks
  if(-not$State.prerequisites_validated){return $null}
  if($null-ne$State.pending_command){if($State.write_preflight_pending-and$null-eq$State.pending_command.started_ticks){return $State.pending_command};Stop-R19GrantReservationWorkflow $State 'UNCOMMITTED_COMMAND_NO_RETRY'}
  if($State.cancelling){
    if(-not(Test-R19GrantReservationCommandCommitted $State 'CancelGround')){return New-R19GrantReservationWorkflowCommand $State CancelGround CancelRequest ground $State.hello_ground $State.prepared}
    if($null-eq$State.cancel_ground){return $null}
    if(-not(Test-R19GrantReservationCommandCommitted $State 'CancelVehicle')){return New-R19GrantReservationWorkflowCommand $State CancelVehicle CancelRequest vehicle $State.hello_vehicle $State.prepared}
    if($null-eq$State.cancel_vehicle){return $null}
    if(-not(Test-R19GrantReservationCommandCommitted $State 'CancelPeerGround')){return New-R19GrantReservationWorkflowCommand $State CancelPeerGround CancelPeerConfirmed ground $State.hello_vehicle $State.prepared $State.cancel_vehicle.device_ms}
    if(-not(Test-R19GrantReservationCommandCommitted $State 'CancelPeerVehicle')){return New-R19GrantReservationWorkflowCommand $State CancelPeerVehicle CancelPeerConfirmed vehicle $State.hello_ground $State.prepared $State.cancel_ground.device_ms}
    return $null
  }
  if($State.status-ceq'CancelledReadyForFreshNonce'){return $null}
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
  param([object]$State,[ValidateSet('ground','vehicle')][string]$ChannelRole,[byte[]]$Bytes,[string]$ReadCompletedTicks,[string]$NowTicks,[long]$RawOffset=0,[switch]$Prepeek)
  $frame64=[Convert]::ToBase64String($Bytes)
  if(-not$Prepeek){
    $already=@($State.prepeeked_withdrawals|Where-Object{$_.role-ceq$ChannelRole-and$_.raw_offset-eq$RawOffset-and$_.read_completed_ticks-ceq$ReadCompletedTicks-and$_.frame_base64-ceq$frame64})
    if($already.Count-eq1){return}
  }
  Update-R19GrantReservationWorkflow $State $NowTicks
  $d=ConvertFrom-R19GrantReservationFrame $Bytes
  if(-not$d.valid-or$d.version-ne$State.wire_version-or$d.component-ne198-or$d.role-cne$ChannelRole-or$d.reader_session-cne$State.reader_session-or$d.slot_nonce-cne$State.slot_nonce){Stop-R19GrantReservationWorkflow $State 'INVALID_OR_UNBOUND_RESERVATION_RESPONSE'}
  if([Numerics.BigInteger]$ReadCompletedTicks-gt[Numerics.BigInteger]$NowTicks){Stop-R19GrantReservationWorkflow $State 'RESPONSE_NATIVE_READ_IN_FUTURE'}
  $hello=if($ChannelRole-ceq'ground'){$State.hello_ground}else{$State.hello_vehicle}
  if($d.opcode-ceq'HelloReply'){
    $kind='Hello'+$ChannelRole
    if(-not(Test-R19GrantReservationCommandCommitted $State $kind)-or$null-ne$hello){Stop-R19GrantReservationWorkflow $State 'HELLO_RESPONSE_REPLAY_OR_UNREQUESTED'}
    Assert-R19GrantReservationResponseAfterWrite $State @($kind) $ReadCompletedTicks
    if($ChannelRole-ceq'ground'){$State.hello_ground=$d}else{$State.hello_vehicle=$d}
  }else{
    if($null-eq$hello-or$d.boot_id-cne$hello.boot_id-or$d.usb_epoch-cne$hello.usb_epoch){Stop-R19GrantReservationWorkflow $State 'RESPONSE_BOOT_OR_EPOCH_CHANGED'}
    if(($State.cancelling-or$State.status-ceq'CancelledReadyForFreshNonce')-and$d.opcode-cnotin@('CancelAck','CancelPeerConfirmed','Withdrawn','Fault')){
      if($d.opcode-cnotin@('Prepared','Bound')-or-not(Test-R19GrantReservationTuple $d $State.prepared)){Stop-R19GrantReservationWorkflow $State 'OLD_SLOT_RESPONSE_AFTER_WITHDRAWAL'}
      $required=if($d.opcode-ceq'Prepared'){@('PrepareVehicle')}else{@('BindPeerVehicle','BindGround','BindPeerGround')}
      Assert-R19GrantReservationResponseAfterWrite $State $required $ReadCompletedTicks
      if($State.obsolete_controls.Count-ge8-or$State.observations.Count-ge64){Stop-R19GrantReservationWorkflow $State 'OBSOLETE_CONTROL_CAPACITY'}
      $obsolete=[pscustomobject]@{role=$ChannelRole;decoded=$d;read_completed_ticks=$ReadCompletedTicks;observation_ticks=$NowTicks;raw_offset=$RawOffset;frame_base64=$frame64;disposition='OBSOLETE_OLD_SLOT_NO_AUTHORITY'}
      $State.obsolete_controls.Add($obsolete);$State.observations.Add($obsolete);Add-R19GrantReservationWorkflowEvent $State 'ObsoleteOldSlotResponseDrained' $d.opcode
      return
    }
    switch -CaseSensitive ($d.opcode){
      'Prepared'{
        if(-not(Test-R19GrantReservationCommandCommitted $State 'PrepareVehicle')-or$null-ne$State.prepared-or-not(Test-R19GrantReservationNewerGrant $d $State.hello_ground)){Stop-R19GrantReservationWorkflow $State 'PREPARED_NOT_FRESH_OR_REPLAYED'}
        if($null-ne$State.retired_slot-and(-not(Test-R19GrantReservationNewerGrant $d $State.retired_slot)-or[uint64]$d.slot_token-le[uint64]$State.retired_slot.slot_token-or[uint64]$d.generation-le[uint64]$State.retired_slot.generation)){Stop-R19GrantReservationWorkflow $State 'PREPARED_REUSES_RETIRED_RF_LEASE'}
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
      'Fault'{
        if($null-eq$State.control_fault_first){$State.control_fault_first=[pscustomobject]@{role=$ChannelRole;decoded=$d;read_completed_ticks=$ReadCompletedTicks;observation_ticks=$NowTicks;raw_offset=$RawOffset;frame_base64=$frame64;provenance='CRC-valid typed R19R role/boot/epoch/reader/nonce-bound fault; detail requires JTAG, not cryptographic authentication.'}}
        Stop-R19GrantReservationWorkflow $State 'MCU_RESERVATION_FAULT_REASON_IN_JTAG'
      }
      'Withdrawn'{
        if(-not$State.cancellation_enabled-or$State.wire_version-ne2-or$ChannelRole-cne'vehicle'-or$null-eq$State.prepared-or-not(Test-R19GrantReservationTuple $d $State.prepared)-or$null-ne$State.withdrawn){Stop-R19GrantReservationWorkflow $State 'INVALID_OR_REPLAYED_WITHDRAWAL'}
        if($State.param_attempts-ne0-or$null-ne$State.held){Stop-R19GrantReservationWorkflow $State 'ATTEMPTED_ABORT_WITHDRAWN_AFTER_REQUEST'}
        if($State.cancellation_count-ge1-or$State.round-ge2){Stop-R19GrantReservationWorkflow $State 'CANCELLATION_BUDGET_EXHAUSTED'}
        Assert-R19GrantReservationResponseAfterWrite $State @('PrepareVehicle') $ReadCompletedTicks
        if([uint64]$d.device_ms-lt[uint64]$State.prepared.device_ms){Stop-R19GrantReservationWorkflow $State 'WITHDRAWAL_PRECEDES_PREPARED'}
        if($null-ne$State.pending_command){if($null-ne$State.pending_command.started_ticks){Stop-R19GrantReservationWorkflow $State 'ATTEMPTED_ABORT_WITH_PRIVATE_WRITE_PENDING'};$State.pending_command.error='WITHDRAWN_BEFORE_OUT_ATTEMPT';$State.pending_command=$null}
        $State.withdrawn=$d;$State.cancelling=$true;$State.cancellation_count++;$State.status='CancellationPending';Add-R19GrantReservationWorkflowEvent $State 'OldSlotWithdrawnBeforeRequest' $d
      }
      'CancelAck'{
        if(-not$State.cancellation_enabled-or-not$State.cancelling-or-not(Test-R19GrantReservationTuple $d $State.prepared)){Stop-R19GrantReservationWorkflow $State 'UNEXPECTED_CANCEL_ACK_OR_OLD_TUPLE_MISMATCH'}
        $field='cancel_'+$ChannelRole;$kind=if($ChannelRole-ceq'ground'){'CancelGround'}else{'CancelVehicle'}
        if($null-ne$State.$field-or-not(Test-R19GrantReservationCommandCommitted $State $kind)){Stop-R19GrantReservationWorkflow $State 'CANCEL_ACK_REPLAY_OR_UNREQUESTED'}
        Assert-R19GrantReservationResponseAfterWrite $State @($kind) $ReadCompletedTicks
        if([uint64]$d.device_ms-lt[uint64]$hello.device_ms-or($ChannelRole-ceq'vehicle'-and[uint64]$d.device_ms-lt[uint64]$State.withdrawn.device_ms)){Stop-R19GrantReservationWorkflow $State 'CANCEL_ACK_PRECEDES_OWN_IDENTITY_OR_WITHDRAWAL'}
        $State.$field=$d;$State.status='WaitingBothLocalCancellationAcks'
      }
      'CancelPeerConfirmed'{
        if(-not$State.cancellation_enabled-or-not$State.cancelling-or$null-eq$State.cancel_ground-or$null-eq$State.cancel_vehicle-or-not(Test-R19GrantReservationTuple $d $State.prepared)){Stop-R19GrantReservationWorkflow $State 'PEER_CONFIRM_BEFORE_BOTH_LOCAL_CANCEL_ACKS'}
        $field='peer_confirm_'+$ChannelRole;$kind=if($ChannelRole-ceq'ground'){'CancelPeerGround'}else{'CancelPeerVehicle'}
        if($null-ne$State.$field-or-not(Test-R19GrantReservationCommandCommitted $State $kind)){Stop-R19GrantReservationWorkflow $State 'PEER_CONFIRM_REPLAY_OR_UNREQUESTED'}
        Assert-R19GrantReservationResponseAfterWrite $State @($kind) $ReadCompletedTicks
        if([uint64]$d.device_ms-lt[uint64]$State.('cancel_'+$ChannelRole).device_ms){Stop-R19GrantReservationWorkflow $State 'OWN_PEER_CONFIRM_PRECEDES_LOCAL_RETIREMENT'}
        $State.$field=$d
        if($null-ne$State.peer_confirm_ground-and$null-ne$State.peer_confirm_vehicle){$State.cancelling=$false;$State.status='CancelledReadyForFreshNonce'}
      }
      default{Stop-R19GrantReservationWorkflow $State 'UNEXPECTED_RESERVATION_RESPONSE_OPCODE'}
    }
  }
  if($State.observations.Count-ge64){Stop-R19GrantReservationWorkflow $State 'RESPONSE_CAPACITY'}
  $State.observations.Add([pscustomobject]@{role=$ChannelRole;decoded=$d;read_completed_ticks=$ReadCompletedTicks;observation_ticks=$NowTicks;raw_offset=$RawOffset;frame_base64=[Convert]::ToBase64String($Bytes)})
  if($d.opcode-ceq'Withdrawn'){
    for($i=$State.deferred_withdrawals.Count-1;$i-ge0;$i--){$item=$State.deferred_withdrawals[$i];if($item.role-ceq$ChannelRole-and$item.raw_offset-eq$RawOffset-and$item.read_completed_ticks-ceq$ReadCompletedTicks-and$item.frame_base64-ceq$frame64){$State.deferred_withdrawals.RemoveAt($i)}}
  }
  if($Prepeek){if($State.prepeeked_withdrawals.Count-ge2){Stop-R19GrantReservationWorkflow $State 'WITHDRAWAL_PREPEEK_CAPACITY'};$State.prepeeked_withdrawals.Add([pscustomobject]@{role=$ChannelRole;raw_offset=$RawOffset;read_completed_ticks=$ReadCompletedTicks;frame_base64=$frame64})}
  Add-R19GrantReservationWorkflowEvent $State 'ResponseValidated' $d.opcode
}
function Start-R19GrantReservationNextRound {
  param([object]$State,[object]$NewSlotNonce,[string]$NowTicks)
  Update-R19GrantReservationWorkflow $State $NowTicks
  if(-not$State.cancellation_enabled-or$State.status-cne'CancelledReadyForFreshNonce'-or$State.round-ne1-or$State.cancellation_count-ne1-or$State.param_attempts-ne0-or$null-ne$State.held-or$null-eq$State.peer_confirm_ground-or$null-eq$State.peer_confirm_vehicle-or$null-ne$State.pending_command){Stop-R19GrantReservationWorkflow $State 'FRESH_ROUND_WITHOUT_COMPLETE_CANCELLATION'}
  [uint64]$new=ConvertTo-R19GrantReservationUInt $NewSlotNonce 'new_slot_nonce'
  [void](New-R19GrantReservationFrame -Opcode HelloRequest -Role ground -ReaderSession $State.reader_session -SlotNonce $new -Version 2)
  if($new.ToString()-ceq$State.slot_nonce-or$State.retired_nonces.Contains($new.ToString())){Stop-R19GrantReservationWorkflow $State 'FRESH_NONCE_REUSES_RETIRED_RESERVATION'}
  $State.retired_nonces.Add($State.slot_nonce);$State.retired_slot=$State.prepared;$State.slot_nonce=$new.ToString();$State.round=2
  foreach($field in @('hello_ground','hello_vehicle','prepared','bound','held','tail_ready','withdrawn','cancel_ground','cancel_vehicle','peer_confirm_ground','peer_confirm_vehicle')){$State.$field=$null}
  $State.status='HelloPending';Add-R19GrantReservationWorkflowEvent $State 'FreshRoundAfterBothCancellationConfirmations' 'Original PC15s/MCU8s deadlines and globalPARAM ledger are not reset.'
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
  param([object]$State,[object]$Command,[scriptblock]$NowTicks,[scriptblock]$Writer,[scriptblock]$BeforeWrite=$null)
  if($State.status-ceq'Failed'){throw $State.failure}
  if($null-ne$BeforeWrite){$allowed=&$BeforeWrite;if($allowed-isnot[bool]-or-not$allowed){if($State.write_preflight_pending-and$State.status-cne'Failed'){return $null};if($State.status-cne'Failed'){Stop-R19GrantReservationWorkflow $State 'RUNTIME_FAILURE_PREFLIGHT_NOT_PROVEN'};throw $State.failure}}
  if($Command.error-ceq'WITHDRAWN_BEFORE_OUT_ATTEMPT'-and$null-eq$Command.started_ticks-and$State.cancelling){return $null}
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
  param([object]$State,[switch]$Finalize)
  if($null-eq$State){return $null}
  if($Finalize-and$State.status-cne'Failed'-and$State.status-cne'TailPermitWrittenAwaitingMcuEvidence'){try{Stop-R19GrantReservationWorkflow $State ('CAPTURE_ENDED_BEFORE_RESERVATION_COMPLETED_'+$State.status)}catch{}}
  $copy=$State|ConvertTo-Json -Depth 16 -Compress|ConvertFrom-Json
  $copy|Add-Member NoteProperty actual_negotiation_start_ms $null
  $copy|Add-Member NoteProperty actual_bulk_start_ms $null
  $copy|Add-Member NoteProperty observation_scope 'USB_CONTROL_SEQUENCE_ONLY_ACTUAL_MCU_PROTOCOL_EVIDENCE_REQUIRES_BOUND_JTAG_RECORDS'
  $copy|Add-Member NoteProperty request_outcome $(if($State.param_attempts-eq0){'NOT_ATTEMPTED'}elseif($State.status-ceq'Failed'){'ATTEMPTED_ABORT'}else{'ATTEMPTED_LOCAL_WRITE_ONLY'})
  $copy|Add-Member NoteProperty ground_500ms_evaluation ([pscustomobject]@{result='NOT_EVALUATED';reason='NO_MATCHING_FRESH_GRANT_AND_ACTUAL_MCU_RELEASE_EVIDENCE';request_attempted=($State.param_attempts-eq1);ground_t0_ms=$State.ground_request_t0_ms;release_write_accepted=(Test-R19GrantReservationCommandCommitted $State 'ReleaseVehicle');release_write_is_local_only=$true;fresh_grant_observed=$false;high_speed_success=$false})
  return $copy
}
