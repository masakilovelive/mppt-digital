[CmdletBinding()]
param([switch]$ImportOnly,[string]$FirstPath='',[string]$SecondPath='',[string]$ExpectedRole='',[string]$OutputPath='')

function ConvertFrom-R19GrantReservationFatalRecord {
  param([Parameter(Mandatory)][byte[]]$First,[Parameter(Mandatory)][byte[]]$Second,
    [ValidateSet('ground','vehicle','')][string]$ExpectedRole='',
    [uint32[]]$ExpectedFingerprint=$null,[uint32[]]$ExpectedBoot=$null)
  if($First.Length-ne128-or$Second.Length-ne128){throw 'FATAL128 requires two exact128-byte records'}
  for($i=0;$i-lt128;$i++){if($First[$i]-ne$Second[$i]){throw 'FATAL128 paired reads differ'}}
  [uint32[]]$w=[uint32[]]::new(32)
  for($i=0;$i-lt32;$i++){$w[$i]=[BitConverter]::ToUInt32($First,4*$i)}
  if($w[0]-ne0-or($w[1]-band1)-ne0-or$w[1]-eq0){throw 'FATAL128 is not a committed stable writer snapshot'}
  if($w[2]-ne0x52314654-or$w[3]-ne1-or$w[14]-ne128){throw 'FATAL128 ABI differs'}
  if($w[4]-ne1-and$w[4]-ne2){throw 'FATAL128 role is invalid'}
  $role=if($w[4]-eq1){'ground'}else{'vehicle'}
  if($ExpectedRole-and$ExpectedRole-cne$role){throw 'FATAL128 role differs'}
  [uint32[]]$build=@($w[5..8]);[uint32[]]$boot=@($w[9..12])
  if(@($build|Where-Object{$_-ne0}).Count-eq0-or($boot[0]-eq0-and$boot[1]-eq0)){throw 'FATAL128 build/boot identity is unavailable'}
  foreach($spec in @(@($ExpectedFingerprint,$build,'build'),@($ExpectedBoot,$boot,'boot'))){
    if($null-ne$spec[0]){if($spec[0].Count-ne4){throw 'Expected FATAL128 identity must contain4words'};for($i=0;$i-lt4;$i++){if($spec[0][$i]-ne$spec[1][$i]){throw ('FATAL128 '+$spec[2]+' differs')}}}
  }
  if(($w[13]-band4294836472)-ne0-or($w[13]-band255)-notin@(1,7)){throw 'FATAL128 flags are unknown'}
  $latched=($w[13]-band255)-eq7
  $contextFlags=$w[13]-shr8
  if(-not$latched-and$w[13]-ne1){throw 'Unlatched FATAL128 context is nonzero'}
  if(($latched-and$w[1]-ne4)-or(-not$latched-and$w[1]-ne2)){throw 'FATAL128 sequence/first-wins flags disagree'}
  if(-not$latched){foreach($at in 15..31){if($w[$at]-ne0){throw 'Unlatched FATAL128 payload is nonzero'}}}
  function StopU64([int]$At){return [uint64]$w[$At]+[uint64]$w[$At+1]*[uint64]4294967296}
  [uint64]$now=StopU64 16;[uint64]$heartbeatDeadline=StopU64 18;[uint64]$holdDeadline=StopU64 20
  $predicates=[uint32]$w[22];$reason=[int]($w[15]-band255)
  $detail=[int](($w[15]-shr8)-band255);$block=[int](($w[15]-shr16)-band255);$phase=[int]($w[15]-shr24)
  if(($predicates-band4294966784)-ne0-or$reason-gt10){throw 'FATAL128 predicate mask/reason is unknown'}
  if($latched){
    if($role-cne'vehicle'-or$reason-eq0-or$w[23]-eq0){throw 'FATAL128 latched role/reason/reserve is invalid'}
    if($detail-ne13-or$block-gt18-or$phase-gt3){throw 'FATAL128 detail/block/phase is invalid'}
    if($block-eq1-and($contextFlags-band2)-ne0){throw 'Unavailable cancellation conflicts with context'}
    # Reproduce the firmware's first-matching predicate, not only enum range.
    $observedReason=0
    if(($predicates-band16)-ne0){$observedReason=1}
    elseif(($predicates-band3)-eq3-and($heartbeatDeadline-le$now-or$heartbeatDeadline-$now-le[uint64]$w[23])){$observedReason=2}
    elseif(($predicates-band4)-eq0){$observedReason=3}
    elseif(($predicates-band8)-eq0){$observedReason=4}
    elseif($w[28]-ne1){$observedReason=5}
    elseif($w[26]-ne$w[24]){$observedReason=6}
    elseif($w[27]-ne$w[25]){$observedReason=7}
    elseif(($predicates-band32)-ne0){$observedReason=8}
    elseif(($predicates-band64)-ne0){$observedReason=9}
    elseif(($predicates-band128)-ne0){$observedReason=10}
    if($observedReason-ne$reason){throw 'FATAL128 first-stop reason disagrees with predicates'}
  }
  $reasons=@('None','ReservationFailed','HeartbeatDeadlineConflict','AuxLow','LeaseInvalid','LeaseOwnerMismatch','ActionTokenMismatch','WriterGenerationMismatch','RadioBusy','PendingRadioAction','WriterTailPending')
  $disposition=if($latched){'FATAL_RESERVED_GRANT13'}else{'NONE'}
  $blocks=@('None','Unavailable','HoldExpired','ActionUnavailable','UartAccepted','Releasing','RadioBusy','PendingAction','TailPending','ActionTypeMismatch','LeaseInvalid','LeaseOwnerMismatch','TokenMismatch','GenerationMismatch','EpochMismatch','NotHolding','TddOrWriterReleaseRejected','BeginCancelRejected','NotHeartbeatOnlyConflict')
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$hash=[BitConverter]::ToString($sha.ComputeHash($First)).Replace('-','')}finally{$sha.Dispose()}
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-grant-reservation-fatal-decoded-v1';result='PASS';mode='offline-only';hardware_interaction=$false
    raw_size_bytes=128;raw_sha256=$hash;record_schema=1;sequence=$w[1];role=$role;build_fingerprint=$build;boot_instance=$boot
    expected_identity_bound=($null-ne$ExpectedFingerprint-and$null-ne$ExpectedBoot-and$ExpectedRole-cne'')
    initialized=$true;fatal_latched=$latched;frozen=$latched;fatal_detail=$detail;scope='reserved-grant-detail13-only'
    disposition=$disposition
    reason=$reason;reason_name=$reasons[$reason];observed_ms=$now.ToString();heartbeat_deadline_ms=$heartbeatDeadline.ToString();hold_deadline_ms=$holdDeadline.ToString()
    predicate_mask=$predicates;reserve_ms=$w[23]
    predicates=[pscustomobject][ordered]@{heartbeat_valid=($predicates-band1)-ne0;heartbeat_available=($predicates-band2)-ne0;aux_high=($predicates-band4)-ne0;lease_valid=($predicates-band8)-ne0;reservation_failed=($predicates-band16)-ne0;radio_busy=($predicates-band32)-ne0;pending_action=($predicates-band64)-ne0;tail_pending=($predicates-band128)-ne0;release_requested=($predicates-band256)-ne0;zero_uart_proven=($predicates-band512)-ne0;old_cycle_retired=($predicates-band1024)-ne0;old_lease_retired=($predicates-band2048)-ne0}
    context=[pscustomobject][ordered]@{cancellation_supported=($contextFlags-band1)-ne0;cancellation_available=($contextFlags-band2)-ne0;cancellation_pending=($contextFlags-band4)-ne0;holding=($contextFlags-band8)-ne0;agreement_committed=($contextFlags-band16)-ne0;uart_accepted=($contextFlags-band32)-ne0;releasing=($contextFlags-band64)-ne0;epoch_matches=($contextFlags-band128)-ne0;action_valid=($contextFlags-band256)-ne0;cancellation_phase=$phase;cancel_block_reason=$block;cancel_block_name=$blocks[$block]}
    writer=[pscustomobject][ordered]@{expected_token=$w[24];expected_generation=$w[25];active_token=$w[26];active_generation=$w[27];active_owner=$w[28]}
    heartbeat_order=(StopU64 29).ToString();current_usb_epoch=$w[31]
    cancellation_completion_proven=$false;heartbeat_deadline_met_proven=$false;reservation_protocol_complete_proven=$false;high_speed_start_proven=$false;acceptance_authorized=$false;deployment_authorized=$false
    limitations=@('Independent first fatal for reserved-Grant detail13 only; original STOP128 SAFE_CANCEL is unchanged.','Snapshot precedes runtime abort and preserves first-matching stop predicate; it is not a waveform or RF/USB delivery proof.','NotHeartbeatOnlyConflict means heartbeat-only cancellation eligibility failed, including compound HB+AUX/lease faults; it does not exclude a Heartbeat predicate.','USB epoch0 is valid. PC, Vehicle and Ground clocks are not interchangeable.')
  }
}
if($ImportOnly){return}
if(-not$FirstPath-or-not$SecondPath){throw 'Paired FATAL128 record paths are required'}
$decoded=ConvertFrom-R19GrantReservationFatalRecord -First ([IO.File]::ReadAllBytes($FirstPath)) -Second ([IO.File]::ReadAllBytes($SecondPath)) -ExpectedRole $ExpectedRole
if($OutputPath){[IO.File]::WriteAllText($OutputPath,($decoded|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}else{$decoded}


