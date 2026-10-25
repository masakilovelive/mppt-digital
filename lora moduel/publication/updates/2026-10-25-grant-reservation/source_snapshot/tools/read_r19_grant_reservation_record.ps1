[CmdletBinding()]
param([switch]$ImportOnly,[string]$FirstPath='', [string]$SecondPath='', [string]$ExpectedRole='', [string]$OutputPath='')
function ConvertFrom-R19GrantReservationRecord {
  param([Parameter(Mandatory)][byte[]]$First,[Parameter(Mandatory)][byte[]]$Second,
    [ValidateSet('ground','vehicle','')][string]$ExpectedRole='',[uint32[]]$ExpectedFingerprint=$null,[uint32[]]$ExpectedBoot=$null)
  if($First.Length-ne512-or$Second.Length-ne512){throw 'Grant reservation record must be exactly512 bytes'}
  for($i=0;$i-lt512;$i++){if($First[$i]-ne$Second[$i]){throw 'Grant reservation paired reads differ'}}
  [uint32[]]$w=[uint32[]]::new(128);for($i=0;$i-lt128;$i++){$w[$i]=[BitConverter]::ToUInt32($First,4*$i)}
  if($w[0]-ne0-or($w[1]-band1)-ne0-or$w[1]-eq0){throw 'Grant reservation record is not a committed stable writer snapshot'}
  if($w[2]-ne0x52313952-or$w[3]-ne1-or$w[14]-ne512-or$w[31]-ne0){throw 'Grant reservation record ABI or reserved word differs'}
  if($w[4]-ne1-and$w[4]-ne2){throw 'Grant reservation role is invalid'}
  $role=if($w[4]-eq1){'ground'}else{'vehicle'}
  if($ExpectedRole-and$ExpectedRole-cne$role){throw 'Grant reservation role differs'}
  [uint32[]]$build=@($w[5..8]);[uint32[]]$boot=@($w[9..12])
  if(@($build|Where-Object{$_-ne0}).Count-eq0-or@($boot|Where-Object{$_-ne0}).Count-eq0){throw 'Grant reservation build/boot identity is unavailable'}
  if(($boot[0]-eq0-and$boot[1]-eq0)-or$w[18]-ne$boot[0]-or$w[19]-ne$boot[1]){throw 'Grant reservation local producer boot scope differs from the bound record boot'}
  foreach($spec in @(@($ExpectedFingerprint,$build,'build'),@($ExpectedBoot,$boot,'boot'))){
    if($null-ne$spec[0]){if($spec[0].Count-ne4){throw 'Expected reservation identity must contain4words'};for($i=0;$i-lt4;$i++){if($spec[0][$i]-ne$spec[1][$i]){throw ('Grant reservation '+$spec[2]+' differs')}}}
  }
  if($w[13]-ne1-and$w[13]-ne7){throw 'Grant reservation initialized/failure/frozen flags differ'}
  $state=[int]($w[15]-band65535);$reason=[int]($w[15]-shr16)
  if($state-gt14-or$reason-gt21){throw 'Grant reservation header enum is unknown'}
  $failed=$w[13]-eq7
  if(($failed-and($state-ne14-or$reason-eq0))-or(-not$failed-and($state-eq14-or$reason-ne0))){throw 'Grant reservation failure state/flags disagree'}
  $used=[int]($w[17]-band65535);$dropped=[int]($w[17]-shr16)
  if($used-gt12-or[uint64]$w[16]-ne([uint64]$used+[uint64]$dropped)){throw 'Grant reservation bounded journal counters disagree'}
  $states=@('Cold','HelloPending','HelloReady','AwaitVehicleGrant','VehiclePrepared','GroundLocalBound','GroundBound','GroundHeld','GroundGranted','VehicleReleaseGranted','VehicleGrantWritten','VehicleTailReady','GroundTailPermitted','Started','Failed')
  $reasons=@('None','InvalidConfiguration','InvalidWire','WrongRole','WrongScope','WrongBoot','WrongEpoch','WrongState','WrongGrant','WrongToken','Replay','ClockRegression','TimeOverflow','PrepareExpired','HoldExpired','GrantWaitExpired','TailWaitExpired','VehicleWindowExpired','QueueFull','UnsafeHold','CanonicalRequestMismatch','ExternalFault')
  $events=@('None','Hello','Baseline','Prepare','Prepared','BoundLocal','BoundPeer','GroundHeld','ReleaseGrant','GrantWritten','GrantObserved','TailObserved','TailPermit','Started','ReplyCommitted','Failure')
  $journal=@();[uint64]$lastTime=0
  for($slot=0;$slot-lt12;$slot++){
    $at=32+8*$slot
    if($slot-ge$used){for($j=0;$j-lt8;$j++){if($w[$at+$j]-ne0){throw 'Unused grant reservation journal slot is nonzero'}};continue}
    $event=[int]$w[$at];$es=[int]($w[$at+1]-band65535);$er=[int]($w[$at+1]-shr16)
    [uint64]$time=[uint64]$w[$at+2]+[uint64]$w[$at+3]*[uint64]4294967296
    if($event-lt1-or$event-gt15-or$es-gt14-or$er-gt21-or($slot-gt0-and$time-lt$lastTime)){throw 'Grant reservation journal enum or MCU time order differs'}
    $lastTime=$time
    $journal+=,[pscustomobject][ordered]@{event=$event;event_name=$events[$event];state=$es;state_name=$states[$es];reason=$er;reason_name=$reasons[$er];observed_ms=$time.ToString();grant_session=[int]($w[$at+4]-band65535);grant_cycle=[int]($w[$at+4]-shr16);writer_token=$w[$at+5];writer_generation=$w[$at+6];auxiliary=$w[$at+7]}
  }
  if($failed-and($used-eq0-or$journal[-1].event-ne15-or$journal[-1].state-ne14-or$journal[-1].reason-ne$reason)){throw 'Frozen grant reservation failure has no matching terminal first-failure event'}
  function ReservationU64([int]$At){return ([uint64]$w[$At]+[uint64]$w[$At+1]*[uint64]4294967296).ToString()}
  $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($First)).Replace('-','')}finally{$sha.Dispose()}
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-grant-reservation-decoded-v1';result='PASS';mode='offline-only';hardware_interaction=$false
    raw_size_bytes=512;raw_sha256=$hash;record_schema=1;sequence=$w[1];role=$role;build_fingerprint=$build;boot_instance=$boot
    expected_identity_bound=($null-ne$ExpectedFingerprint-and$null-ne$ExpectedBoot-and$ExpectedRole-cne'')
    initialized=$true;failure_latched=$failed;frozen=$failed;state=$state;state_name=$states[$state];reason=$reason;reason_name=$reasons[$reason]
    identity=[pscustomobject][ordered]@{own_boot_id=ReservationU64 18;peer_boot_id=ReservationU64 20;own_usb_epoch=$w[22];peer_usb_epoch=$w[23];slot_nonce=ReservationU64 24;reader_session=ReservationU64 26;grant_session=[int]($w[28]-band65535);grant_cycle=[int]($w[28]-shr16);writer_token=$w[29];writer_generation=$w[30]}
    identity_semantics='Zero-valued fields may be unavailable before their producer event;USB epoch0 is valid and must not imply absence. Journal/state determine event availability.'
    event_count=$w[16];journal_count=$used;journal_dropped=$dropped;journal_complete=($dropped-eq0);journal_retention='first-eight-last-four';journal=$journal
    first_failure=$(if($failed){$journal[-1]}else{$null})
    reservation_protocol_complete_proven=$false;high_speed_start_proven=$false;rf_delivery_proven=$false;acceptance_authorized=$false;deployment_authorized=$false
    limitations=@('Stable local JTAG record, not an RF waveform or authorization.','Journal overflow makes event absence inconclusive.','Failure freezes the entire record;subsequent progress is not observable in this first-failure image.','Logical producer events and their MCU timestamps must be joined with bound USB raw/control evidence and the other role;no PC/MCU clock equality is assumed.')
  }
}
if($ImportOnly){return}
if(-not$FirstPath-or-not$SecondPath){throw 'Paired reservation record paths are required'}
$decoded=ConvertFrom-R19GrantReservationRecord -First ([IO.File]::ReadAllBytes($FirstPath)) -Second ([IO.File]::ReadAllBytes($SecondPath)) -ExpectedRole $ExpectedRole
if($OutputPath){[IO.File]::WriteAllText($OutputPath,($decoded|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))}else{$decoded}
