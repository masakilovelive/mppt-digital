# Pure, bounded PARAM_REQUEST_LIST accounting. No device or write API is called.
# ReadCompletedTicks must be the native read completion, never analysis time.
Set-StrictMode -Version Latest

function Update-R19ParamListCrc([uint16]$Crc,[byte]$Value) {
  $t=($Value -bxor ($Crc -band 255)) -band 255
  $t=($t -bxor ($t -shl 4)) -band 255
  return [uint16]((($Crc -shr 8) -bxor ($t -shl 8) -bxor ($t -shl 3) -bxor ($t -shr 4)) -band 65535)
}
function New-R19ParamListTracker {
  [pscustomobject]@{seen=[bool[]]::new(932);ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);unique_count=0;complete_read_completed_ticks=$null;last_index=-1;out_of_order_count=0;sentinel_count=0;pre_request_count=0;outside_window_count=0;ledger=[Collections.Generic.List[object]]::new();errors=[ordered]@{bad_crc=0;bad_length=0;unsupported_flags=0;unsupported_signed=0;invalid_source=0;invalid_count=0;invalid_index=0;invalid_id=0;invalid_type=0;duplicate_index=0;duplicate_id=0;noise_bytes=0;partial_frame=0}}
}
function New-R19ParamListDiagnosticsState {
  param([Parameter(Mandatory=$true)][ValidateRange(1,1000000000)][int64]$Frequency,[string]$ClockDomainId='unspecified',[ValidateRange(1,16777216)][int]$MaximumRawBytes=4194304,[ValidateRange(1,65536)][int]$MaximumFrames=8192)
  [pscustomobject]@{frequency=$Frequency;clock_domain_id=$ClockDomainId;maximum_raw_bytes=$MaximumRawBytes;maximum_frames=$MaximumFrames;next_raw_offset=[int64]0;last_read_completed_ticks=$null;write_attempts=0;request_write_started_ticks=$null;request_write_returned_ticks=$null;request_raw_offset=$null;deadline_ticks=$null;accepted_bytes=$null;api_exception_type='';write_committed=$false;buffer=[Collections.Generic.List[byte]]::new();frame_start_raw_offset=[int64]-1;frame_start_read_ticks=$null;expected_size=0;parsed_frames=0;unknown_frames=0;error_events=[Collections.Generic.List[object]]::new();capacity_exceeded=$false;frozen=$false;observation_complete=$false;late_predeadline_data=$false;frozen_view=$null;thirty=(New-R19ParamListTracker);final=(New-R19ParamListTracker)}
}
function Begin-R19ParamListWrite {
  param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)][ValidateRange(0,[int64]::MaxValue)][int64]$WriteStartedTicks,[Nullable[int64]]$RawOffsetAtWriteStart=$null)
  if($State.write_attempts -ne 0){throw 'PARAM_REQUEST_LIST is one-shot; another attempt is forbidden.'}
  if($State.frozen){throw 'Cannot begin after snapshot sealing.'}
  if($null -ne $RawOffsetAtWriteStart -and $RawOffsetAtWriteStart -ne $State.next_raw_offset){throw 'Write raw cursor must match the completely ingested raw prefix.'}
  if($WriteStartedTicks -gt ([int64]::MaxValue - 30*$State.frequency)){throw 'Deadline overflow.'}
  # Latch before returning bytes: exceptions and partial acceptance cannot retry.
  $State.write_attempts=1;$State.request_write_started_ticks=$WriteStartedTicks;$State.request_raw_offset=$State.next_raw_offset;$State.deadline_ticks=[int64]($WriteStartedTicks+30*$State.frequency)
  return ,([byte[]]@(253,2,0,0,99,255,190,21,0,0,1,1,213,7))
}
function Commit-R19ParamListWrite {
  param([Parameter(Mandatory=$true)]$State,[Nullable[int]]$AcceptedBytes=$null,[Nullable[int64]]$WriteReturnedTicks=$null,[string]$ExceptionType='')
  if($State.write_attempts -ne 1 -or $State.write_committed){throw 'Write result requires exactly one uncommitted attempt.'}
  if($null -ne $AcceptedBytes -and ($AcceptedBytes -lt 0 -or $AcceptedBytes -gt 14)){throw 'Local accepted byte count must be null or 0..14.'}
  if($null -ne $WriteReturnedTicks -and $WriteReturnedTicks -lt $State.request_write_started_ticks){throw 'Write returned before it started.'}
  $State.write_committed=$true;$State.accepted_bytes=$AcceptedBytes;$State.request_write_returned_ticks=$WriteReturnedTicks;$State.api_exception_type=$ExceptionType
}
function Add-R19ParamListValueToTracker($Tracker,$Record,[string]$WindowStatus) {
  $entry=[pscustomobject][ordered]@{raw_offset=$Record.raw_offset;read_completed_ticks=$Record.read_completed_ticks;frame_start_read_completed_ticks=$Record.frame_start_read_completed_ticks;frame_sha256=$Record.frame_sha256;frame_bytes=$Record.frame_bytes;version=$Record.version;mavlink_sequence=$Record.mavlink_sequence;source_system=$Record.source_system;source_component=$Record.source_component;param_count=$Record.param_count;index=$Record.index;id_16_hex=$Record.id_16_hex;param_id=$Record.param_id;param_type=$Record.param_type;param_value_bits_hex=$Record.param_value_bits_hex;id_valid=$Record.id_valid;crc_valid=$true;window_status=$WindowStatus;classification='VALID';read_begin_relation='NOT_OBSERVED_NO_PHYSICAL_RESPONSE_CAUSAL_PROOF'}
  if($WindowStatus -eq 'PRE_REQUEST'){$entry.classification='PRE_REQUEST';$Tracker.pre_request_count++}
  elseif($WindowStatus -eq 'AFTER_DEADLINE'){$entry.classification='OUTSIDE_WINDOW';$Tracker.outside_window_count++}
  else {
    $valid=$true
    if($Record.source_system -ne 1 -or $Record.source_component -ne 1){$Tracker.errors.invalid_source++;$entry.classification='INVALID_SOURCE';$valid=$false}
    if($Record.param_count -ne 932){$Tracker.errors.invalid_count++;$entry.classification='INVALID_COUNT';$valid=$false}
    # This exact existing sentinel tuple alone is outside the parameter index range.
    $sentinel=$Record.source_system -eq 1 -and $Record.source_component -eq 1 -and $Record.param_count -eq 932 -and $Record.index -eq 65535 -and $Record.param_type -eq 6 -and $Record.id_valid -and $Record.param_id -ceq 'STAT_RUNTIME'
    if($sentinel){$Tracker.sentinel_count++;$entry.classification='STAT_RUNTIME_SENTINEL';$valid=$false}
    elseif($Record.index -lt 0 -or $Record.index -ge 932){$Tracker.errors.invalid_index++;$entry.classification='INVALID_INDEX';$valid=$false}
    if(-not $Record.id_valid){$Tracker.errors.invalid_id++;$entry.classification='INVALID_ID';$valid=$false}
    if($Record.param_type -lt 1 -or $Record.param_type -gt 10){$Tracker.errors.invalid_type++;$entry.classification='INVALID_TYPE';$valid=$false}
    if($valid){
      if($Tracker.seen[$Record.index]){$Tracker.errors.duplicate_index++;$entry.classification='DUPLICATE_INDEX'}
      else {
        if($Tracker.last_index -ge 0 -and $Record.index -lt $Tracker.last_index){$Tracker.out_of_order_count++}
        $Tracker.last_index=$Record.index
        if(-not $Tracker.ids.Add($Record.param_id)){$Tracker.errors.duplicate_id++;$entry.classification='DUPLICATE_ID'}
        $Tracker.seen[$Record.index]=$true;$Tracker.unique_count++
        if($Tracker.unique_count-eq932-and$null-eq$Tracker.complete_read_completed_ticks){$Tracker.complete_read_completed_ticks=[int64]$Record.read_completed_ticks}
      }
    }
  }
  $Tracker.ledger.Add($entry)
}
function Add-R19ParamListParserError($State,[string]$Name,[int64]$Ticks,[int64]$RawOffset,[int]$Count=1) {
  if($State.write_attempts -eq 0 -or $Ticks -lt $State.request_write_started_ticks -or $RawOffset -lt $State.request_raw_offset){return}
  $last=if($State.error_events.Count-gt0){$State.error_events[$State.error_events.Count-1]}else{$null}
  if($null-ne$last-and$last.name-ceq$Name-and$last.ticks-eq$Ticks){$last.count+=$Count}
  else {
    if($State.error_events.Count-ge$State.maximum_frames){$State.capacity_exceeded=$true;throw 'Bounded parser error event capacity exceeded.'}
    $State.error_events.Add([pscustomobject]@{name=$Name;ticks=$Ticks;count=$Count})
  }
  $State.final.errors[$Name]+=$Count
  if(-not $State.frozen -and $Ticks -le $State.deadline_ticks){$State.thirty.errors[$Name]+=$Count}
}
function Add-R19ParamListCompleteFrame($State,[byte[]]$Raw,[int64]$Ticks) {
  $v=if($Raw[0] -eq 253){2}else{1};$p=if($v -eq 2){10}else{6};$length=[int]$Raw[1]
  $id=if($v -eq 2){[int]$Raw[7] -bor ([int]$Raw[8] -shl 8) -bor ([int]$Raw[9] -shl 16)}else{[int]$Raw[5]}
  if($id -ne 22){$State.unknown_frames++;return}
  if($length -ne 25){Add-R19ParamListParserError $State 'bad_length' $Ticks $State.frame_start_raw_offset;return}
  [uint16]$crc=65535;for($i=1;$i -lt ($p+25);$i++){$crc=Update-R19ParamListCrc $crc $Raw[$i]};$crc=Update-R19ParamListCrc $crc 220
  $stored=[int]$Raw[$p+25] -bor ([int]$Raw[$p+26] -shl 8)
  if($stored -ne $crc){Add-R19ParamListParserError $State 'bad_crc' $Ticks $State.frame_start_raw_offset;return}
  if($v -eq 2 -and ($Raw[2] -band 254) -ne 0){Add-R19ParamListParserError $State 'unsupported_flags' $Ticks $State.frame_start_raw_offset;return}
  if($v -eq 2 -and ($Raw[2] -band 1) -ne 0){Add-R19ParamListParserError $State 'unsupported_signed' $Ticks $State.frame_start_raw_offset;return}
  $idBytes=[byte[]]::new(16);[Array]::Copy($Raw,$p+8,$idBytes,0,16)
  $name=[Text.StringBuilder]::new();$zero=$false;$valid=$true
  foreach($b in $idBytes){if($b -eq 0){$zero=$true}elseif($zero -or $b -lt 32 -or $b -gt 126){$valid=$false}else{[void]$name.Append([char]$b)}}
  if($name.Length -eq 0){$valid=$false}
  $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($Raw)).Replace('-','')}finally{$sha.Dispose()}
  $r=[pscustomobject]@{raw_offset=$State.frame_start_raw_offset.ToString();read_completed_ticks=$Ticks.ToString();frame_start_read_completed_ticks=$State.frame_start_read_ticks.ToString();frame_sha256=$hash;frame_bytes=$Raw.Length;version=$v;mavlink_sequence=if($v-eq2){[int]$Raw[4]}else{[int]$Raw[2]};source_system=if($v-eq2){[int]$Raw[5]}else{[int]$Raw[3]};source_component=if($v-eq2){[int]$Raw[6]}else{[int]$Raw[4]};param_count=([int]$Raw[$p+4] -bor ([int]$Raw[$p+5] -shl 8));index=([int]$Raw[$p+6] -bor ([int]$Raw[$p+7] -shl 8));id_16_hex=[BitConverter]::ToString($idBytes).Replace('-','');param_id=$name.ToString();param_type=[int]$Raw[$p+24];param_value_bits_hex=[BitConverter]::ToString($Raw,$p,4).Replace('-','');id_valid=$valid}
  $pre=$State.write_attempts -eq 0 -or $Ticks -lt $State.request_write_started_ticks -or $State.frame_start_raw_offset -lt $State.request_raw_offset
  $status=if($pre){'PRE_REQUEST'}else{'IN_WINDOW'}
  Add-R19ParamListValueToTracker $State.final $r $status
  if(-not $State.frozen){$status=if($pre){'PRE_REQUEST'}elseif($Ticks -gt $State.deadline_ticks){'AFTER_DEADLINE'}else{'IN_WINDOW'};Add-R19ParamListValueToTracker $State.thirty $r $status}
}
function Add-R19ParamListBytes {
  param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes,[Parameter(Mandatory=$true)][ValidateRange(0,[int64]::MaxValue)][int64]$ReadCompletedTicks,[Parameter(Mandatory=$true)][ValidateRange(0,[int64]::MaxValue)][int64]$RawOffset)
  if($RawOffset -ne $State.next_raw_offset){throw 'Raw offsets must be contiguous, non-overlapping, and ordered.'}
  if($null -ne $State.last_read_completed_ticks -and $ReadCompletedTicks -lt $State.last_read_completed_ticks){throw 'Native read completion ticks reversed.'}
  if($State.capacity_exceeded){throw 'Evidence capacity already exceeded.'}
  if($Bytes.Length -gt ($State.maximum_raw_bytes-$State.next_raw_offset)){$State.capacity_exceeded=$true;throw 'Bounded raw byte capacity exceeded.'}
  if($State.frozen -and $Bytes.Length -gt 0 -and $ReadCompletedTicks -le $State.deadline_ticks){$State.late_predeadline_data=$true}
  $State.last_read_completed_ticks=$ReadCompletedTicks
  foreach($b in $Bytes){
    $offset=$State.next_raw_offset;$State.next_raw_offset++
    if($State.buffer.Count -eq 0){
      if($b -ne 253 -and $b -ne 254){Add-R19ParamListParserError $State 'noise_bytes' $ReadCompletedTicks $offset;continue}
      $State.frame_start_raw_offset=$offset;$State.frame_start_read_ticks=$ReadCompletedTicks
    }
    $State.buffer.Add($b)
    if($State.buffer.Count -eq 2 -and $State.buffer[0] -eq 254){$State.expected_size=[int]$State.buffer[1]+8}
    if($State.buffer.Count -eq 3 -and $State.buffer[0] -eq 253){$State.expected_size=[int]$State.buffer[1]+12+$(if(($State.buffer[2]-band1)-ne0){13}else{0})}
    if($State.expected_size -gt 0 -and $State.buffer.Count -eq $State.expected_size){
      if($State.parsed_frames -ge $State.maximum_frames){$State.capacity_exceeded=$true;throw 'Bounded frame capacity exceeded.'}
      $State.parsed_frames++;Add-R19ParamListCompleteFrame $State $State.buffer.ToArray() $ReadCompletedTicks
      $State.buffer.Clear();$State.expected_size=0;$State.frame_start_raw_offset=[int64]-1;$State.frame_start_read_ticks=$null
    }
  }
}
function Get-R19ParamListTrackerView($State,$Tracker,[bool]$Sealed,[bool]$Complete,[int64]$PendingBytes) {
  $missing=[Collections.Generic.List[int]]::new();for($i=0;$i -lt 932;$i++){if(-not $Tracker.seen[$i]){$missing.Add($i)}}
  $errors=[ordered]@{};$sum=0;foreach($key in $Tracker.errors.Keys){$n=[int]$Tracker.errors[$key];if($key -eq 'partial_frame' -and $PendingBytes -gt 0){$n++};$errors[$key]=$n;$sum+=$n};$errors.total=$sum
  $clean=$sum-eq0-and$Tracker.out_of_order_count-eq0
  $elapsed=if($null-ne$Tracker.complete_read_completed_ticks-and$null-ne$State.request_write_started_ticks){[decimal]::Floor(([decimal]$Tracker.complete_read_completed_ticks-$State.request_write_started_ticks)*1000000/[decimal]$State.frequency).ToString([Globalization.CultureInfo]::InvariantCulture)}else{$null}
  $result=if($State.write_attempts -eq 0){'NOT_ATTEMPTED'}elseif($State.capacity_exceeded -or $State.late_predeadline_data -or ($Sealed -and -not $Complete)){'INCOMPLETE_EVIDENCE'}elseif(-not $State.write_committed -or $State.accepted_bytes -ne 14 -or $State.api_exception_type){'WRITE_INCOMPLETE'}elseif($Tracker.unique_count -eq 932 -and $clean){'COMPLETE_932_CLEAN'}elseif($Tracker.unique_count -eq 932){'COMPLETE_932_WITH_ERRORS'}elseif($sum -gt 0){'INCOMPLETE_WITH_ERRORS'}else{'INCOMPLETE_PARAMETERS'}
  [pscustomobject][ordered]@{result=$result;target_count=932;unique_count=$Tracker.unique_count;all_932_received=($Tracker.unique_count -eq 932);clean_conditions_met=$clean;complete_read_completed_ticks=if($null-ne$Tracker.complete_read_completed_ticks){$Tracker.complete_read_completed_ticks.ToString()}else{$null};elapsed_us=$elapsed;snapshot_complete=$Complete;sealed=$Sealed;late_predeadline_data=$State.late_predeadline_data;capacity_exceeded=$State.capacity_exceeded;deadline_ticks=if($null-ne$State.deadline_ticks){$State.deadline_ticks.ToString()}else{$null};missing_indexes=@($missing);errors=[pscustomobject]$errors;out_of_order_count=$Tracker.out_of_order_count;sentinel_count=$Tracker.sentinel_count;pre_request_count=$Tracker.pre_request_count;outside_window_count=$Tracker.outside_window_count;ledger=@($Tracker.ledger);parser=[pscustomobject]@{pending_bytes=$PendingBytes;unknown_frames=$State.unknown_frames;parsed_frames=$State.parsed_frames;total_raw_bytes=$State.next_raw_offset};acceptance_eligible=$false;deployment_authorized=$false}
}
function Get-R19ParamListSnapshot {
  param([Parameter(Mandatory=$true)]$State,[Nullable[int64]]$AtTicks=$null)
  $complete=$State.frozen -and $State.observation_complete -and -not $State.capacity_exceeded -and -not $State.late_predeadline_data
  if($State.frozen){$view=$State.frozen_view|ConvertTo-Json -Depth 20|ConvertFrom-Json;$view.snapshot_complete=$complete;$view.late_predeadline_data=$State.late_predeadline_data;$view.capacity_exceeded=$State.capacity_exceeded;if(-not$complete){$view.result='INCOMPLETE_EVIDENCE'}}
  else {
    $tracker=$State.thirty
    # Optional historical display is computed only on snapshot, never per-byte.
    if($null-ne$AtTicks -and $null-ne$State.deadline_ticks -and $AtTicks -lt $State.deadline_ticks){
      $tracker=New-R19ParamListTracker
      foreach($entry in $State.thirty.ledger){if([int64]$entry.read_completed_ticks -le $AtTicks){Add-R19ParamListValueToTracker $tracker $entry $entry.window_status}}
      foreach($event in $State.error_events){if($event.ticks-le$AtTicks){$tracker.errors[$event.name]+=$event.count}}
    }
    $pending=if($State.buffer.Count-gt0-and$null-ne$State.deadline_ticks-and$State.frame_start_read_ticks-le$State.deadline_ticks-and($null-eq$AtTicks-or$State.frame_start_read_ticks-le$AtTicks)){$State.buffer.Count}else{0}
    $view=Get-R19ParamListTrackerView $State $tracker $false $false $pending
  }
  # Final means all ingested raw, not a proof that future device/reader data is absent.
  $final=Get-R19ParamListTrackerView $State $State.final $false $false $State.buffer.Count
  $final|Add-Member -NotePropertyName coverage -NotePropertyValue 'INGESTED_RAW_PREFIX_ONLY'
  $request=if($State.write_attempts-eq1){[pscustomobject][ordered]@{write_started_ticks=$State.request_write_started_ticks.ToString();write_returned_ticks=if($null-ne$State.request_write_returned_ticks){$State.request_write_returned_ticks.ToString()}else{$null};accepted_bytes=$State.accepted_bytes;api_exception_type=$State.api_exception_type;exception_type=$State.api_exception_type;local_write_api_accepted_only=$true;delivery_proven=$false;raw_offset_at_write_start=$State.request_raw_offset.ToString();request_frame_hex='FD02000063FFBE1500000101D507';expected_bytes=14;frame_sha256='FC3A47A83D35D44E96E044A216FDBF082805F9FACCDD5E4B9252E0C7026D4A75'}}else{$null}
  $out=[ordered]@{schema='vc-lora-r19-param-list-diagnostics-v1';target_count=932;deadline_us='30000000';clock_domain_id=$State.clock_domain_id;frequency=$State.frequency.ToString();request_attempts=$State.write_attempts;request=$request;snapshot_30s=$view;final=$final;errors_scope='PARAM_VALUE_LEDGER_AND_STREAM_FRAMING_ONLY';acceptance_eligible=$false;deployment_authorized=$false;limitations=@('Local write API acceptance is not Pixhawk or RF delivery proof.','Native read completion timestamps define receive windows; no physical response causal proof is asserted.','Unknown messages are skipped at declared frame boundaries, not scanned for nested magic.','CRC validation is limited to PARAM_VALUE #22; skipped messages are not certified.','Signed PARAM_VALUE is unsupported, not authenticated.','Snapshot completeness requires an explicit caller native-reader watermark.','No MCU clock correlation or product acceptance is inferred.')}
  foreach($p in $view.PSObject.Properties){if(-not$out.Contains($p.Name)){$out[$p.Name]=$p.Value}}
  return [pscustomobject]$out
}
function Freeze-R19ParamList30 {
  param([Parameter(Mandatory=$true)]$State,[bool]$ObservationComplete=$false)
  if($State.write_attempts-ne1){throw 'Cannot freeze a request that was not attempted.'}
  if(-not$State.frozen){
    # A partial whose first native completion is strictly after the deadline
    # cannot contain a complete deadline-eligible PARAM_VALUE. Keep it in final.
    $pending=if($State.buffer.Count-gt0-and$State.frame_start_read_ticks-le$State.deadline_ticks){$State.buffer.Count}else{0}
    $State.observation_complete=$ObservationComplete -and $pending-eq0
    $State.frozen_view=Get-R19ParamListTrackerView $State $State.thirty $true $State.observation_complete $pending;$State.frozen=$true
  }
  return Get-R19ParamListSnapshot $State
}
