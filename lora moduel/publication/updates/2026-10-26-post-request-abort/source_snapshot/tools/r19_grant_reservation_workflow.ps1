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
    try{if($State.status-cne'Failed'){
      $control=ConvertFrom-R19GrantReservationFrame $frame -AgreementEnabled $State.agreement_enabled
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
    }}catch{if($State.status-cne'Failed'){throw}}
    # A typed prepeek can latch Failed and throw. Retire that COMPLETE frame
    # now: waiting for another native byte would leave cleanup behind its own
    # already-consumed withdrawal. The first failure and normal OUT gate stay closed.
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
function Add-R19GrantReservationDeliveredBlock {
  param([object]$State,[object]$RoleState,[object]$Block,[string]$NowTicks)
  # The priority path reads retained native bytes, not PollBytes. Every normal
  # consumer still receives its full PollBytes stream later. Only this shared
  # reservation parser suppresses an already causally delivered prefix.
  Add-R19GrantReservationRuntimeBlock $State $RoleState $Block $NowTicks
  [byte[]]$bytes=$Block.Data;[long]$begin=$Block.Offset;[long]$end=$begin+$bytes.Length
  [long]$delivered=$RoleState.reservation_parser.next_raw_offset
  if($end-le$delivered){return}
  if($begin-gt$delivered-or$bytes.Length-gt8192){Stop-R19GrantReservationWorkflow $State 'CONTROL_PUMP_RAW_PREFIX_GAP_OR_CAPACITY'}
  [int]$skip=[int]($delivered-$begin);[byte[]]$suffix=New-Object byte[] ($bytes.Length-$skip)
  [Array]::Copy($bytes,$skip,$suffix,0,$suffix.Length)
  foreach($r in (Add-R19GrantReservationBytes -Parser $RoleState.reservation_parser -Bytes $suffix -RawOffset $delivered -ReadCompletedTicks ([string]$Block.EndTicks))){
    if($State.status-cne'Failed'){
      try{Add-R19GrantReservationObservation -State $State -ChannelRole $RoleState.spec.role -Bytes $r.bytes -ReadCompletedTicks $r.read_completed_ticks -NowTicks $NowTicks -RawOffset $r.raw_offset}catch{}
    }elseif($State.agreement_enabled-and$r.decoded.opcode-ceq'AbortAck'){
      try{Add-R19GrantReservationTerminalAbortObservation -State $State -ChannelRole $RoleState.spec.role -Bytes $r.bytes -ReadCompletedTicks $r.read_completed_ticks -NowTicks $NowTicks -RawOffset $r.raw_offset}catch{}
    }
  }
}
function Receive-R19GrantReservationControlPrefixes {
  param([object]$State,[object[]]$States,[scriptblock]$NowTicks)
  $prefixes=@{}
  foreach($role in @('vehicle','ground')){
    $rows=@($States|Where-Object{$_.spec.role-ceq$role})
    if($rows.Count-ne1){Stop-R19GrantReservationWorkflow $State 'CONTROL_PUMP_READER_SET_NOT_BOUND'}
    $prefixes[$role]=[pscustomobject]@{state=$rows[0];snapshot=$rows[0].reader.GetSnapshot()}
  }
  # Fix both immutable prefixes before sampling their common PC clock.
  $observed=[string](&$NowTicks)
  foreach($role in @('vehicle','ground')){
    $r=$prefixes[$role].state;$snapshot=$prefixes[$role].snapshot
    if($snapshot.Stopped-or$snapshot.Overflow-or-not[string]::IsNullOrEmpty($snapshot.Failure)) {Stop-R19GrantReservationWorkflow $State 'CONTROL_PUMP_READER_NOT_CONTINUOUS'}
    if(@($snapshot.Blocks).Count-gt4096-or[long]$snapshot.ByteCount-lt0-or[long]$snapshot.ByteCount-gt1048576-or[long]$r.reservation_parser.next_raw_offset-gt[long]$snapshot.ByteCount){Stop-R19GrantReservationWorkflow $State 'CONTROL_PUMP_NATIVE_HISTORY_CAPACITY_OR_REGRESSION'}
    foreach($block in @($snapshot.Blocks)){
      [long]$end=[long]$block.Offset+[long]$block.Count
      if($end-le[long]$r.reservation_parser.next_raw_offset){continue}
      if([long]$block.Offset-gt[long]$r.reservation_parser.next_raw_offset){Stop-R19GrantReservationWorkflow $State 'CONTROL_PUMP_NATIVE_BLOCK_GAP'}
      while([long]$r.reservation_parser.next_raw_offset-lt$end){
        [long]$offset=$r.reservation_parser.next_raw_offset;[int]$count=[int][Math]::Min(8192L,$end-$offset)
        $piece=[pscustomobject]@{Offset=$offset;Data=[byte[]]$r.reader.ReadSlice([int]$offset,$count);EndTicks=$block.EndTicks}
        Add-R19GrantReservationDeliveredBlock $State $r $piece $observed
      }
    }
    if([long]$r.reservation_parser.next_raw_offset-ne[long]$snapshot.ByteCount){Stop-R19GrantReservationWorkflow $State 'CONTROL_PUMP_NATIVE_PREFIX_UNPROVEN'}
  }
}
function Invoke-R19GrantReservationControlPump {
  param([object]$State,[scriptblock]$NowTicks,[scriptblock]$Drain,[scriptblock]$BeforeWrite,[scriptblock]$Writer,
    [ValidateRange(1,24)][int]$MaximumCommands=8,[ValidateRange(1,106)][int]$MaximumPumpMilliseconds=25)
  # A bounded priority slice, never a deadline extension or a retry. ACKs and
  # every original one-shot/state guard remain in the existing workflow.
  if($null-eq$State.PSObject.Properties['control_pump_metrics']){
    $State|Add-Member NoteProperty control_pump_metrics ([pscustomobject]@{schema='vc-lora-r19-control-pump-metrics-v1';clock_domain_id=$State.clock_domain_id;frequency=$State.frequency;invocations=0L;total_commands_written=0L;total_write_attempts=0L;max_slice_elapsed_ticks='0';last_slice_elapsed_ticks='0';last_stop_reason='NONE';await_observation=0L;time_budget=0L;command_budget=0L;preflight_pending=0L;failed=0L;timing_guarantee=$false})
  }
  $metrics=$State.control_pump_metrics;$metrics.invocations++
  $attemptsBefore=@($State.commands|Where-Object{$null-ne$_.started_ticks}).Count
  $start=[string](&$NowTicks)
  $written=0;$reason='FAILED';$pumpWriter=$Writer;$pumpPreflight=$BeforeWrite
  try{
    Update-R19GrantReservationWorkflow $State $start
    $limit=[Numerics.BigInteger]$start+([Numerics.BigInteger]$State.frequency*$MaximumPumpMilliseconds/1000)
    $reason='COMMAND_BUDGET'
    for($iteration=0;$iteration-lt$MaximumCommands;$iteration++){
      &$Drain $State
      $now=[string](&$NowTicks);Update-R19GrantReservationWorkflow $State $now
      if([Numerics.BigInteger]$now-ge$limit){$reason='TIME_BUDGET';break}
      $pumpCommand=Get-R19GrantReservationNextCommand $State $now
      if($null-eq$pumpCommand){$reason='AWAIT_OBSERVATION';break}
      $slice=[pscustomobject]@{expired=$false}
      $sent=Invoke-R19ReservationPrivateWrite -State $State -Command $pumpCommand -NowTicks $NowTicks -Writer {param([byte[]]$payload)&$pumpWriter $pumpCommand $payload} -BeforeWrite {
        $allowed=&$pumpPreflight $State $pumpCommand
        if($allowed-isnot[bool]-or-not$allowed){return $allowed}
        # A slow prefix check must not start a new OUT after this slice expired.
        # The built command remains unattempted and resumes only via normal guards.
        if([Numerics.BigInteger]([string](&$NowTicks))-ge$limit){$slice.expired=$true;$State.write_preflight_pending=$true;return $false}
        return $true
      }
      if($null-eq$sent){$reason=if($slice.expired){'TIME_BUDGET'}else{'PREFLIGHT_PENDING'};break}
      $written++
    }
  }catch{$reason='FAILED';throw}
  finally{
    $end=[string](&$NowTicks);$elapsed=[Numerics.BigInteger]$end-[Numerics.BigInteger]$start
    $metrics.total_commands_written+=$written
    $metrics.total_write_attempts+=@($State.commands|Where-Object{$null-ne$_.started_ticks}).Count-$attemptsBefore
    $metrics.last_slice_elapsed_ticks=$elapsed.ToString();$metrics.last_stop_reason=$reason
    if($elapsed-gt[Numerics.BigInteger]$metrics.max_slice_elapsed_ticks){$metrics.max_slice_elapsed_ticks=$elapsed.ToString()}
    switch -CaseSensitive ($reason){'AWAIT_OBSERVATION'{$metrics.await_observation++};'TIME_BUDGET'{$metrics.time_budget++};'COMMAND_BUDGET'{$metrics.command_budget++};'PREFLIGHT_PENDING'{$metrics.preflight_pending++};default{$metrics.failed++}}
  }
  [pscustomobject]@{commands_written=$written;stop_reason=$reason;start_ticks=$start;end_ticks=$end;maximum_commands=$MaximumCommands;maximum_pump_ms=$MaximumPumpMilliseconds;timing_guarantee=$false}
}
function Add-R19GrantReservationWorkflowEvent {
  param([object]$State,[string]$Kind,[object]$Details=$null)
  if($State.events.Count-ge128){if($State.status-cne'Failed'){$State.status='Failed';$State.failure='WORKFLOW_EVENT_CAPACITY'};throw $State.failure}
  $State.events.Add([pscustomobject]@{ordinal=$State.events.Count+1;kind=$Kind;pc_ticks=$State.last_ticks;details=$Details})
}
function Stop-R19GrantReservationWorkflow {
  param([object]$State,[string]$Reason)
  if($State.status-cne'Failed'){
    $State.failure_phase=$State.status;$State.status='Failed';$State.failure=$Reason;$State.not_ready_count=1
    if($State.PSObject.Properties['agreement_enabled']-and$State.agreement_enabled){
      $State.terminal_abort.phase='ABORT_UNCONFIRMED';$State.terminal_abort.first_reason=$Reason;$State.terminal_abort.started_ticks=$State.last_ticks;$State.terminal_abort.last_ticks=$State.last_ticks
    }
    Add-R19GrantReservationWorkflowEvent $State 'Failure' $Reason
  }
  throw $Reason
}
function New-R19GrantReservationWorkflow {
  param([string]$CandidateId,[string]$HandoffSha256,[string]$FlashSha256,[object]$ReaderSession,[object]$SlotNonce,
    [string]$ClockDomainId,[string]$Frequency,[string]$StartTicks,[bool]$CancellationEnabled=$false,[bool]$AgreementEnabled=$false)
  if($AgreementEnabled-and-not$CancellationEnabled){throw 'Agreement requires explicit cancellation capability'}
  if($CandidateId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$'-or$HandoffSha256-cnotmatch'^[A-F0-9]{64}$'-or$FlashSha256-cnotmatch'^[A-F0-9]{64}$'-or[string]::IsNullOrWhiteSpace($ClockDomainId)){throw 'Unbound reservation candidate/provenance/clock'}
  [uint64]$reader=ConvertTo-R19GrantReservationUInt $ReaderSession 'reader_session';[uint64]$nonce=ConvertTo-R19GrantReservationUInt $SlotNonce 'slot_nonce'
  [void](New-R19GrantReservationFrame -Opcode HelloRequest -Role ground -ReaderSession $reader -SlotNonce $nonce)
  [uint64]$frequencyValue=ConvertTo-R19GrantReservationUInt $Frequency 'frequency' 1000000000
  [uint64]$start=ConvertTo-R19GrantReservationUInt $StartTicks 'start_ticks' 9223372036854775807 -AllowZero
  if([Numerics.BigInteger]$start+15*[Numerics.BigInteger]$frequencyValue-gt[long]::MaxValue){throw 'Reservation preparation deadline overflow'}
  [pscustomobject]@{schema='vc-lora-r19-grant-reservation-workflow-v1';status='WaitingPrerequisites';failure='';failure_phase='';not_ready_count=0;candidate_id=$CandidateId;handoff_sha256=$HandoffSha256;flash_evidence_sha256=$FlashSha256
    reader_session=$reader.ToString();slot_nonce=$nonce.ToString();clock_domain_id=$ClockDomainId;frequency=$frequencyValue.ToString();start_ticks=$start.ToString();last_ticks=$start.ToString();prepare_deadline_ticks=([Numerics.BigInteger]$start+15*[Numerics.BigInteger]$frequencyValue).ToString()
    prerequisites_validated=$false;hello_ground=$null;hello_vehicle=$null;prepared=$null;bound=$null;held=$null;tail_ready=$null
    cancellation_enabled=$CancellationEnabled;agreement_enabled=$AgreementEnabled;wire_version=$(if($AgreementEnabled){3}elseif($CancellationEnabled){2}else{1});round=1;cancellation_count=0;maximum_cancellations=1;maximum_rounds=2;cancelling=$false;withdrawn=$null;cancel_ground=$null;cancel_vehicle=$null;peer_confirm_ground=$null;peer_confirm_vehicle=$null;retired_slot=$null;retired_nonces=[Collections.Generic.List[string]]::new();prepeeked_withdrawals=[Collections.Generic.List[object]]::new();deferred_withdrawals=[Collections.Generic.List[object]]::new();obsolete_controls=[Collections.Generic.List[object]]::new();control_fault_first=$null
    commit_ground=$null;commit_vehicle=$null;commit_is_irrevocable=$false;maximum_commands=$(if($AgreementEnabled){24}else{18})
    terminal_abort=[pscustomobject]@{phase='NOT_REQUIRED';first_reason='';trigger=$null;started_ticks=$null;last_ticks=$null;capture_deadline_ticks=$null;blocked_reason='';roles=[pscustomobject]@{ground=(New-R19GrantReservationTerminalAbortRole);vehicle=(New-R19GrantReservationTerminalAbortRole)}}
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
  if($null-ne$State.pending_command-or@(Get-R19GrantReservationRoundCommands $State|Where-Object{$_.kind-ceq$Kind}).Count-ne0-or$State.commands.Count-ge$State.maximum_commands){Stop-R19GrantReservationWorkflow $State 'COMMAND_REPLAY_OR_PENDING_OR_CAPACITY'}
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
  if($State.agreement_enabled){
    if($null-eq$State.bound){return $null}
    if(-not(Test-R19GrantReservationCommandCommitted $State 'CommitVehicle')){return New-R19GrantReservationWorkflowCommand $State CommitVehicle CommitRequest vehicle $State.hello_vehicle $State.prepared}
    if($null-eq$State.commit_vehicle){return $null}
    if(-not(Test-R19GrantReservationCommandCommitted $State 'CommitGround')){return New-R19GrantReservationWorkflowCommand $State CommitGround CommitRequest ground $State.hello_ground $State.prepared}
    if($null-eq$State.commit_ground){return $null}
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
  $d=ConvertFrom-R19GrantReservationFrame $Bytes -AgreementEnabled $State.agreement_enabled
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
        $State.bound=$d;$State.status=$(if($State.agreement_enabled){'BoundAwaitingBilateralCommit'}else{'BoundReadyForOneParam'})
      }
      'CommitAck'{
        if(-not$State.agreement_enabled-or$State.cancelling-or$null-eq$State.bound-or-not(Test-R19GrantReservationTuple $d $State.prepared)){Stop-R19GrantReservationWorkflow $State 'COMMIT_ACK_WITHOUT_CURRENT_BOUND_TUPLE'}
        $field='commit_'+$ChannelRole;$kind=if($ChannelRole-ceq'vehicle'){'CommitVehicle'}else{'CommitGround'}
        if($null-ne$State.$field-or-not(Test-R19GrantReservationCommandCommitted $State $kind)-or($ChannelRole-ceq'ground'-and$null-eq$State.commit_vehicle)){Stop-R19GrantReservationWorkflow $State 'COMMIT_ACK_REPLAY_UNREQUESTED_OR_OUT_OF_ORDER'}
        Assert-R19GrantReservationResponseAfterWrite $State @($kind) $ReadCompletedTicks
        $minimum=if($ChannelRole-ceq'vehicle'){$State.prepared.device_ms}else{$State.bound.device_ms}
        if([uint64]$d.device_ms-lt[uint64]$minimum-or[uint64]$d.device_ms-lt[uint64]$hello.device_ms){Stop-R19GrantReservationWorkflow $State 'COMMIT_ACK_PRECEDES_OWN_BOUND_RESERVATION'}
        $State.$field=$d
        if($null-ne$State.commit_ground-and$null-ne$State.commit_vehicle){$State.status='CommittedReadyForOneParam'}
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
        if(-not$State.cancellation_enabled-or$State.wire_version-lt2-or$ChannelRole-cne'vehicle'-or$null-eq$State.prepared-or-not(Test-R19GrantReservationTuple $d $State.prepared)-or$null-ne$State.withdrawn){Stop-R19GrantReservationWorkflow $State 'INVALID_OR_REPLAYED_WITHDRAWAL'}
        if($State.param_attempts-ne0-or$null-ne$State.held){
          if($State.agreement_enabled-and$null-eq$State.terminal_abort.trigger){$State.terminal_abort.trigger=[pscustomobject]@{role=$ChannelRole;decoded=$d;read_completed_ticks=$ReadCompletedTicks;observation_ticks=$NowTicks;raw_offset=$RawOffset;frame_base64=$frame64}}
          Stop-R19GrantReservationWorkflow $State 'ATTEMPTED_ABORT_WITHDRAWN_AFTER_REQUEST'
        }
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
  [void](New-R19GrantReservationFrame -Opcode HelloRequest -Role ground -ReaderSession $State.reader_session -SlotNonce $new -Version $State.wire_version)
  if($new.ToString()-ceq$State.slot_nonce-or$State.retired_nonces.Contains($new.ToString())){Stop-R19GrantReservationWorkflow $State 'FRESH_NONCE_REUSES_RETIRED_RESERVATION'}
  $State.retired_nonces.Add($State.slot_nonce);$State.retired_slot=$State.prepared;$State.slot_nonce=$new.ToString();$State.round=2
  foreach($field in @('hello_ground','hello_vehicle','prepared','bound','held','tail_ready','withdrawn','cancel_ground','cancel_vehicle','peer_confirm_ground','peer_confirm_vehicle','commit_ground','commit_vehicle')){$State.$field=$null}
  $State.status='HelloPending';Add-R19GrantReservationWorkflowEvent $State 'FreshRoundAfterBothCancellationConfirmations' 'Original PC15s/MCU8s deadlines and globalPARAM ledger are not reset.'
}
function Test-R19GrantReservationRequestAllowed {
  param([object]$State,[string]$NowTicks)
  if($null-eq$State){return $false};Update-R19GrantReservationWorkflow $State $NowTicks
  if($State.agreement_enabled){
    if(-not($State.status-ceq'CommittedReadyForOneParam'-and$null-ne$State.commit_ground-and$null-ne$State.commit_vehicle-and$null-ne$State.bound-and$null-ne$State.prepared-and-not$State.cancelling-and$State.param_attempts-eq0-and$null-eq$State.pending_command)){return $false}
    foreach($pair in @(@($State.prepared,'vehicle'),@($State.bound,'ground'),@($State.commit_vehicle,'vehicle'),@($State.commit_ground,'ground'))){
      $current=$pair[0];$role=$pair[1];$hello=if($role-ceq'ground'){$State.hello_ground}else{$State.hello_vehicle}
      if($null-eq$hello-or-not(Test-R19GrantReservationTuple $current $State.prepared)-or$current.role-cne$role-or$current.reader_session-cne$State.reader_session-or$current.slot_nonce-cne$State.slot_nonce-or$current.boot_id-cne$hello.boot_id-or$current.usb_epoch-cne$hello.usb_epoch){return $false}
    }
    return $true
  }
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
function New-R19GrantReservationTerminalAbortRole {
  [pscustomobject]@{command=$null;attempts=0;started_ticks=$null;returned_ticks=$null;accepted_bytes=$null;write_success=$false;exception_type='';ack=$null;blocked_reason=''}
}
function Test-R19GrantReservationTerminalAbortClock {
  param([object]$State,[string]$NowTicks,[string]$CaptureDeadlineTicks='')
  if($null-eq$State-or-not$State.agreement_enabled-or$State.status-cne'Failed'-or$State.terminal_abort.phase-ceq'NOT_REQUIRED'){return $false}
  [uint64]$now=ConvertTo-R19GrantReservationUInt $NowTicks 'terminal_now_ticks' 9223372036854775807 -AllowZero
  if($null-ne$State.terminal_abort.last_ticks-and[Numerics.BigInteger]$now-lt[Numerics.BigInteger]$State.terminal_abort.last_ticks){$State.terminal_abort.blocked_reason='PC_CLOCK_REGRESSION';throw 'TERMINAL_ABORT_PC_CLOCK_REGRESSION'}
  $State.terminal_abort.last_ticks=$now.ToString()
  if($CaptureDeadlineTicks){
    [uint64]$deadline=ConvertTo-R19GrantReservationUInt $CaptureDeadlineTicks 'capture_deadline_ticks' 9223372036854775807 -AllowZero
    if($null-eq$State.terminal_abort.capture_deadline_ticks){$State.terminal_abort.capture_deadline_ticks=$deadline.ToString()}
    elseif($State.terminal_abort.capture_deadline_ticks-cne$deadline.ToString()){$State.terminal_abort.blocked_reason='CAPTURE_DEADLINE_CHANGED';throw 'TERMINAL_ABORT_CAPTURE_DEADLINE_CHANGED'}
  }
  if($null-eq$State.terminal_abort.capture_deadline_ticks){return $false}
  if([Numerics.BigInteger]$now-ge[Numerics.BigInteger]$State.terminal_abort.capture_deadline_ticks){$State.terminal_abort.blocked_reason='CAPTURE_DEADLINE_REACHED';return $false}
  return $true
}
function Get-R19GrantReservationTerminalAbortCommand {
  param([object]$State,[ValidateSet('ground','vehicle')][string]$Role,[string]$NowTicks,[string]$CaptureDeadlineTicks)
  if(-not(Test-R19GrantReservationTerminalAbortClock $State $NowTicks $CaptureDeadlineTicks)){return $null}
  $r=$State.terminal_abort.roles.$Role
  if($State.terminal_abort.phase-ceq'ABORTED_CONFIRMED'-or$r.attempts-ne0-or$null-ne$r.ack-or$r.blocked_reason){return $null}
  $hello=if($Role-ceq'ground'){$State.hello_ground}else{$State.hello_vehicle}
  if($null-eq$State.prepared-or$null-eq$hello){$r.blocked_reason='NO_BOUND_LOCAL_IDENTITY_AND_TUPLE';return $null}
  # An unknown OUT prefix is not repaired by appending a new private frame.
  # This check is per USB role; the other role can still be retired once.
  foreach($c in $State.commands){
    if($c.role-ceq$Role-and$null-ne$c.started_ticks-and-not$c.write_success){$r.blocked_reason='PRIVATE_OUT_PREFIX_UNKNOWN';return $null}
  }
  if($Role-ceq'ground'-and$State.param_attempts-ne0-and($State.param_accepted_bytes-ne14-or$State.param_write_exception)){$r.blocked_reason='PARAM_OUT_PREFIX_UNKNOWN';return $null}
  if($null-ne$r.command){return $r.command}
  if($State.commands.Count-ge$State.maximum_commands){$r.blocked_reason='COMMAND_CAPACITY';return $null}
  [byte[]]$bytes=New-R19GrantReservationFrame -Opcode AbortRequest -Role $Role -ReaderSession $State.reader_session -SlotNonce $State.slot_nonce -BootId $hello.boot_id -UsbEpoch $hello.usb_epoch -GrantSession $State.prepared.grant_session -GrantCycle $State.prepared.grant_cycle -SlotToken $State.prepared.slot_token -Generation $State.prepared.generation -Version 3
  $c=[pscustomobject]@{index=$State.commands.Count+1;round=$State.round;kind=('Abort'+$Role);opcode='AbortRequest';role=$Role;bytes=$bytes;frame_base64=[Convert]::ToBase64String($bytes);built_ticks=$NowTicks;started_ticks=$null;returned_ticks=$null;accepted_bytes=$null;write_success=$false;error='';local_write_api_accepted_only=$true;remote_delivery_proven=$false}
  $State.commands.Add($c);$r.command=$c
  return $c
}
function Invoke-R19GrantReservationTerminalAbortPreflight {
  param([object]$State,[object[]]$States,[string]$NowTicks,[scriptblock]$NowTicksProvider=$null,[ValidateSet('','vehicle','ground')][string]$TargetRole='')
  if($null-eq$State-or-not$State.agreement_enabled-or$State.status-cne'Failed'){return $false}
  $snapshots=@{}
  foreach($role in @('vehicle','ground')){
    $rows=@($States|Where-Object{$_.spec.role-ceq$role})
    if($rows.Count-ne1){$State.terminal_abort.blocked_reason='READER_SET_NOT_BOUND';return $false}
    $snapshots[$role]=[pscustomobject]@{state=$rows[0];snapshot=$rows[0].reader.GetSnapshot()}
  }
  if($null-ne$NowTicksProvider){$NowTicks=[string](&$NowTicksProvider)}
  if(-not(Test-R19GrantReservationTerminalAbortClock $State $NowTicks)){return $false}
  foreach($role in @('vehicle','ground')){
    $r=$snapshots[$role].state;$snapshot=$snapshots[$role].snapshot;$monitor=$State.runtime_fault_monitors.$role
    if($snapshot.Stopped-or$snapshot.Overflow-or-not[string]::IsNullOrEmpty($snapshot.Failure)-or[string]$r.reader_id-cne$monitor.reader_id){$State.terminal_abort.blocked_reason='READER_NOT_CONTINUOUS';return $false}
    if(@($snapshot.Blocks).Count-gt4096-or[long]$snapshot.ByteCount-lt0-or[long]$snapshot.ByteCount-gt1048576){$State.terminal_abort.blocked_reason='READER_HISTORY_CAPACITY';return $false}
    # Continuity/identity is required for BOTH owners, but a partial ACK on the
    # other USB endpoint must not delay this endpoint's deauthorization OUT.
    if($TargetRole-and$role-cne$TargetRole){continue}
    # Native-prefix control delivery does not consume ordinary PollBytes.
    if($null-eq$r.PSObject.Properties['reservation_parser']-or$null-eq$r.reservation_parser-or[long]$r.reservation_parser.next_raw_offset-ne[long]$snapshot.ByteCount-or$monitor.next_raw_offset-ne[long]$snapshot.ByteCount-or$monitor.buffer.Count-ne0){return $false}
  }
  return $true
}
function Invoke-R19ReservationTerminalAbortWrite {
  param([object]$State,[object]$Command,[scriptblock]$NowTicks,[scriptblock]$Writer,[scriptblock]$BeforeWrite=$null)
  if($null-eq$State-or-not$State.agreement_enabled-or$State.status-cne'Failed'-or$null-eq$Command-or$Command.opcode-cne'AbortRequest'-or$Command.role-cnotin@('ground','vehicle')){throw 'INVALID_TERMINAL_ABORT_WRITE_STATE'}
  if($null-ne$BeforeWrite){$allowed=&$BeforeWrite;if($allowed-isnot[bool]-or-not$allowed){return $null}}
  if($State.status-cne'Failed'-or$Command.opcode-cne'AbortRequest'-or$Command.role-cnotin@('ground','vehicle')){throw 'INVALID_TERMINAL_ABORT_WRITE_STATE'}
  # Revalidate the exact current identity/tuple AFTER the last native-prefix
  # preflight, immediately before the irreversible one-shot attempt latch.
  $r=$State.terminal_abort.roles.($Command.role)
  if($null-eq$r.command-or$r.command.index-ne$Command.index-or$r.attempts-ne0-or$null-ne$Command.started_ticks-or$r.blocked_reason){throw 'TERMINAL_ABORT_WRITE_REPLAY_OR_NOT_PENDING'}
  if([Convert]::ToBase64String([byte[]]$Command.bytes)-cne$r.command.frame_base64){throw 'TERMINAL_ABORT_COMMAND_CHANGED'}
  $d=ConvertFrom-R19GrantReservationFrame ([byte[]]$Command.bytes) -AgreementEnabled $true
  $hello=if($Command.role-ceq'ground'){$State.hello_ground}else{$State.hello_vehicle}
  if(-not$d.valid-or$d.version-ne3-or$d.opcode-cne'AbortRequest'-or$d.component-ne197-or$d.role-cne$Command.role-or$d.reader_session-cne$State.reader_session-or$d.slot_nonce-cne$State.slot_nonce-or$null-eq$hello-or$d.boot_id-cne$hello.boot_id-or$d.usb_epoch-cne$hello.usb_epoch-or-not(Test-R19GrantReservationTuple $d $State.prepared)){throw 'TERMINAL_ABORT_COMMAND_IDENTITY_OR_TUPLE_CHANGED'}
  $start=[string](&$NowTicks)
  if(-not(Test-R19GrantReservationTerminalAbortClock $State $start)){return $null}
  $r.attempts=1;$r.started_ticks=$start;$Command.started_ticks=$start
  $accepted=$null;$exceptionType=''
  try{$accepted=&$Writer ([byte[]]$Command.bytes)}catch{$exceptionType=$_.Exception.GetType().FullName}
  $end=[string](&$NowTicks);$r.returned_ticks=$end;$Command.returned_ticks=$end;$r.accepted_bytes=$accepted;$Command.accepted_bytes=$accepted;$r.exception_type=$exceptionType;$Command.error=$exceptionType
  if([Numerics.BigInteger]$end-lt[Numerics.BigInteger]$start){$r.blocked_reason='PC_CLOCK_REGRESSION';throw 'TERMINAL_ABORT_WRITE_CLOCK_REGRESSION'}
  $State.terminal_abort.last_ticks=$end
  if(($accepted-is[int]-or$accepted-is[long])-and$accepted-eq66-and-not$exceptionType){$r.write_success=$true;$Command.write_success=$true}
  else{$r.blocked_reason='TERMINAL_OUT_PREFIX_UNKNOWN'}
  return $Command
}
function Add-R19GrantReservationTerminalAbortObservation {
  param([object]$State,[ValidateSet('ground','vehicle')][string]$ChannelRole,[byte[]]$Bytes,[string]$ReadCompletedTicks,[string]$NowTicks,[long]$RawOffset=0)
  if($null-eq$State-or-not$State.agreement_enabled-or$State.status-cne'Failed'){throw 'INVALID_TERMINAL_ABORT_OBSERVATION_STATE'}
  $d=ConvertFrom-R19GrantReservationFrame $Bytes -AgreementEnabled $State.agreement_enabled
  if(-not$d.valid-or$d.version-ne3-or$d.opcode-cne'AbortAck'-or$d.component-ne198-or$d.role-cne$ChannelRole){throw 'TERMINAL_ABORT_ACK_ONLY'}
  if(-not(Test-R19GrantReservationTerminalAbortClock $State $NowTicks)){throw 'TERMINAL_ABORT_ACK_OUTSIDE_CAPTURE'}
  $r=$State.terminal_abort.roles.$ChannelRole;$hello=if($ChannelRole-ceq'ground'){$State.hello_ground}else{$State.hello_vehicle}
  if($null-eq$hello-or$null-eq$State.prepared-or$d.reader_session-cne$State.reader_session-or$d.slot_nonce-cne$State.slot_nonce-or$d.boot_id-cne$hello.boot_id-or$d.usb_epoch-cne$hello.usb_epoch-or-not(Test-R19GrantReservationTuple $d $State.prepared)){throw 'TERMINAL_ABORT_ACK_IDENTITY_OR_TUPLE_MISMATCH'}
  if($r.attempts-ne1-or-not$r.write_success-or$null-eq$r.command-or$null-ne$r.ack){throw 'TERMINAL_ABORT_ACK_UNREQUESTED_OR_REPLAYED'}
  [uint64]$read=ConvertTo-R19GrantReservationUInt $ReadCompletedTicks 'terminal_read_completed_ticks' 9223372036854775807 -AllowZero
  [uint64]$minimumMs=[uint64]$hello.device_ms
  foreach($prior in @($State.('commit_'+$ChannelRole),$(if($ChannelRole-ceq'ground'){$State.bound}else{$State.prepared}),$(if($ChannelRole-ceq'ground'){$State.held}else{$State.tail_ready}))){if($null-ne$prior-and[uint64]$prior.device_ms-gt$minimumMs){$minimumMs=[uint64]$prior.device_ms}}
  if($null-ne$State.terminal_abort.trigger-and$State.terminal_abort.trigger.role-ceq$ChannelRole-and[uint64]$State.terminal_abort.trigger.decoded.device_ms-gt$minimumMs){$minimumMs=[uint64]$State.terminal_abort.trigger.decoded.device_ms}
  if([Numerics.BigInteger]$read-lt[Numerics.BigInteger]$r.started_ticks-or[Numerics.BigInteger]$read-gt[Numerics.BigInteger]$NowTicks-or[uint64]$d.device_ms-lt$minimumMs){throw 'TERMINAL_ABORT_ACK_INVALID_CAUSAL_TIME'}
  $r.ack=[pscustomobject]@{decoded=$d;read_completed_ticks=$ReadCompletedTicks;observation_ticks=$NowTicks;raw_offset=$RawOffset;frame_base64=[Convert]::ToBase64String($Bytes)}
  if($null-ne$State.terminal_abort.roles.ground.ack-and$null-ne$State.terminal_abort.roles.vehicle.ack){$State.terminal_abort.phase='ABORTED_CONFIRMED'}
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
  $preparedReads=@($State.observations|Where-Object{$_.decoded.opcode-ceq'Prepared'-and$_.decoded.slot_nonce-ceq$State.slot_nonce})
  $releases=@(Get-R19GrantReservationRoundCommands $State|Where-Object{$_.kind-ceq'ReleaseVehicle'-and$null-ne$_.started_ticks})
  $readTicks=if($preparedReads.Count-eq1){$preparedReads[0].read_completed_ticks}else{$null}
  $releaseTicks=if($releases.Count-eq1){$releases[0].started_ticks}else{$null}
  $delta=if($null-ne$readTicks-and$null-ne$releaseTicks){([Numerics.BigInteger]$releaseTicks-[Numerics.BigInteger]$readTicks).ToString()}else{$null}
  $copy|Add-Member NoteProperty prepared_to_release_pc_timing ([pscustomobject]@{clock_domain_id=$State.clock_domain_id;frequency=$State.frequency;prepared_native_read_ticks=$readTicks;release_write_started_ticks=$releaseTicks;elapsed_ticks=$delta;release_write_attempted=($null-ne$releaseTicks);mcu_hold_deadline_proven=$false;scope='PC native Prepared read completion to local Release OUT attempt only; not RF delivery or MCU hold lifetime.'})
  return $copy
}
