[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent(Split-Path -Parent $PSScriptRoot)}
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_wire.ps1')
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_workflow.ps1')
$script:checks=0
function Check([bool]$V,[string]$Message){$script:checks++;if(-not$V){throw ('FAIL '+$Message)}}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Check $failed $Message}
$nonce=[Convert]::ToUInt64('521B000000000001',16).ToString()
$base=@{Role='vehicle';ReaderSession=123;SlotNonce=$nonce;BootId=200;UsbEpoch=1;GrantSession=661;GrantCycle=3;SlotToken=77;Generation=1;DeviceMs=0}
$initial=$base.Clone();$initial.Opcode='CancelRequest'
if((Get-Command New-R19GrantReservationFrame).Parameters.ContainsKey('Version')){$initial.Version=2}
[byte[]]$request=New-R19GrantReservationFrame @initial
Check ($request[14]-eq2-and$request[15]-eq15-and$request[6]-eq197) 'CancelRequest requires explicit wirev2 request namespace'
$d=ConvertFrom-R19GrantReservationFrame $request
Check ($d.valid-and$d.version-eq2-and$d.opcode-ceq'CancelRequest') 'CancelRequest canonical roundtrip'
Reject {New-R19GrantReservationFrame @base -Opcode CancelRequest -Version 1} 'Legacy v1 cannot silently gain cancel authority'
[byte[]]$old=New-R19GrantReservationFrame -Opcode HelloRequest -Role vehicle -ReaderSession 123 -SlotNonce $nonce
Check ($old[14]-eq1) 'Legacy default wire version remains1'
foreach($op in @('CancelAck','Withdrawn')){
  $bytes=New-R19GrantReservationFrame @base -Opcode $op -Version 2
  $decoded=ConvertFrom-R19GrantReservationFrame $bytes
  Check ($decoded.valid-and$decoded.component-eq198-and$decoded.opcode-ceq$op) 'Only canonical typed cancellation responses are accepted'
}
foreach($response in @($false,$true)){
  $b=New-R19GrantReservationFrame @base -Opcode CancelPeerConfirmed -Version 2 -Response:$response
  $d=ConvertFrom-R19GrantReservationFrame $b
  Check ($d.valid-and$d.component-eq$(if($response){198}else{197})) 'Peer relay and own confirmation are distinct directions'
}
$script:now=10L
function Tick {$script:now+=10;return $script:now.ToString()}
function Fixture {
  $script:now=10L
  $args=@{CandidateId='SYNTHETIC-CANCELLATION';HandoffSha256=('A'*64);FlashSha256=('B'*64);ReaderSession=123;SlotNonce=$nonce;ClockDomainId='fixture';Frequency='1000';StartTicks='0'}
  if((Get-Command New-R19GrantReservationWorkflow).Parameters.ContainsKey('CancellationEnabled')){$args.CancellationEnabled=$true}
  $s=New-R19GrantReservationWorkflow @args
  Set-R19GrantReservationPrerequisites $s $true $true $true $true '10'
  return $s
}
function WriteNext([object]$S,[string]$Expected){
  $c=Get-R19GrantReservationNextCommand $S (Tick)
  Check ($null-ne$c-and$c.kind-ceq$Expected) ('next command '+$Expected)
  $null=Invoke-R19ReservationPrivateWrite $S $c {$script:now.ToString()} {param([byte[]]$Bytes)return [int]$Bytes.Length}
  return $c
}
function Observe([object]$S,[string]$Op,[string]$Role,[hashtable]$Override=@{}){
  $a=@{Opcode=$Op;Role=$Role;ReaderSession=123;SlotNonce=$S.slot_nonce;BootId=$(if($Role-ceq'ground'){100}else{200});UsbEpoch=1;DeviceMs=100;Version=2}
  if($Op-ceq'HelloReply'){$a.GrantSession=661;$a.GrantCycle=2}
  else{$a.GrantSession=661;$a.GrantCycle=3;$a.SlotToken=77;$a.Generation=1}
  if($Op-ceq'CancelPeerConfirmed'){$a.Response=$true}
  foreach($k in $Override.Keys){$a[$k]=$Override[$k]}
  $invalidLegacyCancel=$a.Version-eq1-and$Op-in@('CancelAck','Withdrawn','CancelPeerConfirmed')
  if($invalidLegacyCancel){$a.Version=2}
  [byte[]]$bytes=New-R19GrantReservationFrame @a
  if($invalidLegacyCancel){$bytes[14]=1;[uint16]$crc=Get-R19GrantReservationCrc $bytes;$bytes[64]=[byte]($crc-band255);$bytes[65]=[byte]($crc-shr8)}
  $t=Tick
  Add-R19GrantReservationObservation $S $Role $bytes $t $t 0
}
function BoundFixture {
  $s=Fixture
  $null=WriteNext $s Helloground;$null=WriteNext $s Hellovehicle
  Observe $s HelloReply ground;Observe $s HelloReply vehicle
  $null=WriteNext $s PrepareVehicle;Observe $s Prepared vehicle
  $null=WriteNext $s BindPeerVehicle;$null=WriteNext $s BindGround;$null=WriteNext $s BindPeerGround
  Observe $s Bound ground
  return $s
}
$s=BoundFixture
$fault='';try{Observe $s Withdrawn vehicle @{DeviceMs=120}}catch{$fault=$_.Exception.Message}
Check ($s.status-cne'Failed'-and$s.param_attempts-eq0) 'actual matched prePARAM withdrawal must cancel old slot rather than silently authorize or fatal-retry'
$c=WriteNext $s CancelGround;Check ((ConvertFrom-R19GrantReservationFrame $c.bytes).boot_id-ceq'100') 'Ground cancel names own old identity'
Observe $s CancelAck ground @{DeviceMs=130}
$c=WriteNext $s CancelVehicle;Check ((ConvertFrom-R19GrantReservationFrame $c.bytes).boot_id-ceq'200') 'Vehicle still receivesCancel after spontaneousWithdrawn'
Observe $s CancelAck vehicle @{DeviceMs=140}
$c=WriteNext $s CancelPeerGround;$d=ConvertFrom-R19GrantReservationFrame $c.bytes
Check ($d.boot_id-ceq'200'-and$d.device_ms-ceq'140') 'Ground peerconfirm forwards VehicleACK time unchanged, not a PC/local-time comparison'
Observe $s CancelPeerConfirmed ground @{DeviceMs=150}
$c=WriteNext $s CancelPeerVehicle;$d=ConvertFrom-R19GrantReservationFrame $c.bytes
Check ($d.boot_id-ceq'100'-and$d.device_ms-ceq'130') 'Vehicle peerconfirm forwards GroundACK time unchanged'
Check ($null-eq(Get-R19GrantReservationNextCommand $s (Tick))) 'one peer confirmation cannot authorize freshHello'
Observe $s CancelPeerConfirmed vehicle @{DeviceMs=160}
Check ($s.status-ceq'CancelledReadyForFreshNonce'-and$s.param_attempts-eq0) 'both actual peer confirmations gate fresh nonce round'
$deadline=$s.prepare_deadline_ticks;$newNonce=[Convert]::ToUInt64('521B000000000002',16).ToString()
Start-R19GrantReservationNextRound $s $newNonce (Tick)
Check ($s.round-eq2-and$s.slot_nonce-ceq$newNonce-and$s.reader_session-ceq'123'-and$s.prepare_deadline_ticks-ceq$deadline-and$s.param_attempts-eq0) 'one bounded reprepare preserves original15s and global one-request ledger'
$c=WriteNext $s Helloground;$d=ConvertFrom-R19GrantReservationFrame $c.bytes
Check ($d.version-eq2-and$d.boot_id-ceq'0'-and$d.usb_epoch-ceq'0'-and$d.slot_nonce-ceq$newNonce) 'freshHello has newnonce, same reader andzeroidentity'
$null=WriteNext $s Hellovehicle;Observe $s HelloReply ground @{GrantCycle=3};Observe $s HelloReply vehicle @{GrantCycle=3}
$null=WriteNext $s PrepareVehicle
Reject {Observe $s Prepared vehicle} 'retired RF tuple cannot resurrect under freshnonce'
Check ($s.status-ceq'Failed'-and$s.param_attempts-eq0) 'stale prepared doesnot fabricate success/request'
function Retire([object]$S){
  Observe $S Withdrawn vehicle @{DeviceMs=120}
  $null=WriteNext $S CancelGround;Observe $S CancelAck ground @{DeviceMs=130}
  $null=WriteNext $S CancelVehicle;Observe $S CancelAck vehicle @{DeviceMs=140}
  $null=WriteNext $S CancelPeerGround;Observe $S CancelPeerConfirmed ground @{DeviceMs=150}
  $null=WriteNext $S CancelPeerVehicle;Observe $S CancelPeerConfirmed vehicle @{DeviceMs=160}
}
$s=BoundFixture;Retire $s;Start-R19GrantReservationNextRound $s $newNonce (Tick)
$null=WriteNext $s Helloground;$null=WriteNext $s Hellovehicle
Observe $s HelloReply ground @{GrantCycle=3};Observe $s HelloReply vehicle @{GrantCycle=3};$null=WriteNext $s PrepareVehicle
Observe $s Prepared vehicle @{GrantCycle=4;SlotToken=78;Generation=2}
$null=WriteNext $s BindPeerVehicle;$null=WriteNext $s BindGround;$null=WriteNext $s BindPeerGround
Observe $s Bound ground @{GrantCycle=4;SlotToken=78;Generation=2}
Check (Test-R19GrantReservationRequestAllowed $s (Tick)) 'strictnewRFcycle/token/generation after bilateralretirement mayadmitfirstonlyrequest'
Begin-R19GrantReservationParamWrite $s ([byte[]]@(253,2,0,0,99,255,190,21,0,0,1,1,213,7)) (Tick)
Set-R19GrantReservationParamWriteResult $s 14 (Tick)
Observe $s GroundHeld ground @{GrantCycle=4;SlotToken=78;Generation=2;DeviceMs=350}
$null=WriteNext $s ReleaseVehicle
Observe $s TailReady vehicle @{GrantCycle=4;SlotToken=78;Generation=2;DeviceMs=900}
$null=WriteNext $s TailPermitGround
Check ($s.commands.Count-eq18-and$s.param_attempts-eq1-and$s.prepare_deadline_ticks-ceq'15000'-and-not$s.high_speed_success_proven) 'two-round upperbound18controlOUT+onePARAM never provesRFsuccess or resetsoriginaldeadline'
$s=BoundFixture
Begin-R19GrantReservationParamWrite $s ([byte[]]@(253,2,0,0,99,255,190,21,0,0,1,1,213,7)) (Tick)
$t0=$s.param_write_started_ticks;Set-R19GrantReservationParamWriteResult $s 14 (Tick)
Reject {Observe $s Withdrawn vehicle @{DeviceMs=120}} 'withdrawal afterPARAM isabort not automaticnewround'
Check ($s.param_attempts-eq1-and$s.param_write_started_ticks-ceq$t0-and$s.cancellation_count-eq0-and(Get-R19GrantReservationSnapshot $s).request_outcome-ceq'ATTEMPTED_ABORT') 'onceattempted retainactualt0andnever cancel/retryPARAM'
$s=BoundFixture;Observe $s Withdrawn vehicle @{DeviceMs=120};$null=WriteNext $s CancelGround
Reject {Get-R19GrantReservationNextCommand $s '15001'} 'lostACK expires atoriginal15s; no deadlineextension'
Check ($s.status-ceq'Failed'-and$s.param_attempts-eq0-and$s.round-eq1) 'lostACK never authorizesnewHello orPARAM'
foreach($bad in @('wrong-ack-boot','wrong-ack-tuple','ack-before-write','ack-before-hello','wrong-version','wrongtuple-resurrection','withdrawn-replay','peer-before-ownack')){
  $s=BoundFixture;Observe $s Withdrawn vehicle @{DeviceMs=120}
  switch($bad){
    'wrong-ack-boot'{$null=WriteNext $s CancelGround;Reject {Observe $s CancelAck ground @{BootId=101;DeviceMs=130}} $bad}
    'wrong-ack-tuple'{$null=WriteNext $s CancelGround;Reject {Observe $s CancelAck ground @{SlotToken=78;DeviceMs=130}} $bad}
    'ack-before-write'{Reject {Observe $s CancelAck ground @{DeviceMs=130}} $bad}
    'ack-before-hello'{$null=WriteNext $s CancelGround;Reject {Observe $s CancelAck ground @{DeviceMs=99}} $bad}
    'wrong-version'{$null=WriteNext $s CancelGround;Reject {Observe $s CancelAck ground @{Version=1;DeviceMs=130}} $bad}
    'wrongtuple-resurrection'{Reject {Observe $s Bound ground @{SlotToken=78}} $bad}
    'withdrawn-replay'{Reject {Observe $s Withdrawn vehicle @{DeviceMs=120}} $bad}
    'peer-before-ownack'{Reject {Observe $s CancelPeerConfirmed ground @{DeviceMs=130}} $bad}
  }
  Check ($s.status-ceq'Failed'-and$s.param_attempts-eq0) ($bad+' remainsclosed withzeroPARAM')
}
$s=BoundFixture;Retire $s
Reject {Start-R19GrantReservationNextRound $s $nonce (Tick)} 'oldnonce cannot replay retiredreservation'
$s=BoundFixture;Retire $s
Reject {Start-R19GrantReservationNextRound $s $newNonce '15001'} 'completedcancel doesnot resetoriginal15s'
function NativeRole([string]$Role,[byte[]]$Bytes,[long]$End){
  $r=[pscustomobject]@{bytes=$Bytes;end=$End}
  $r|Add-Member ScriptMethod GetSnapshot {[pscustomobject]@{Stopped=$false;Overflow=$false;Failure='';ByteCount=$this.bytes.Length;Blocks=@([pscustomobject]@{Offset=0;Count=$this.bytes.Length;EndTicks=$this.end})}}
  $r|Add-Member ScriptMethod ReadSlice {param([int]$Offset,[int]$Count)if($Count-eq0){return ,[byte[]]@()};return ,[byte[]]$this.bytes[$Offset..($Offset+$Count-1)]}
  [pscustomobject]@{spec=[pscustomobject]@{role=$Role};reader=$r;reader_id=('synthetic-'+$Role);reservation_parser=(New-R19GrantReservationParser);workflow=[pscustomobject]@{reply_read_validated=$true}}
}
$s=BoundFixture
[byte[]]$withdraw=New-R19GrantReservationFrame -Opcode Withdrawn -Role vehicle -ReaderSession 123 -SlotNonce $nonce -BootId 200 -UsbEpoch 1 -GrantSession 661 -GrantCycle 3 -SlotToken 77 -Generation 1 -DeviceMs 120 -Version 2
$t=Tick;$roles=@((NativeRole vehicle $withdraw ([long]$t)),(NativeRole ground ([byte[]]@()) ([long]$t)))
Check (-not(Invoke-R19GrantReservationRuntimePreflight $s $roles $t)) 'prePARAM nativeprefix drains matchingWithdrawal butdefersOUT untilordinarydelivery'
Check (-not(Test-R19GrantReservationRequestAllowed $s $t)-and$s.status-ceq'CancellationPending'-and$s.param_attempts-eq0) 'withdrawal alreadyreceived natively deniesPARAM evenbefore normalpollparse'
$before=$s.observations.Count;Add-R19GrantReservationObservation $s vehicle $withdraw $t $t 0
Check ($s.observations.Count-eq$before) 'prepeekdoesnotstealpollstream; exactsamepublishedframe isdeduplicated once'
Reject {Add-R19GrantReservationObservation $s vehicle $withdraw $t $t 66} 'samebytes atdifferentnativeoffset isactualreplay nothiddenbydedup'
function PreparingFixture {
  $s=Fixture;$null=WriteNext $s Helloground;$null=WriteNext $s Hellovehicle
  Observe $s HelloReply ground;Observe $s HelloReply vehicle;$null=WriteNext $s PrepareVehicle
  return $s
}
$s=PreparingFixture
[byte[]]$preparedFrame=New-R19GrantReservationFrame -Opcode Prepared -Role vehicle -ReaderSession 123 -SlotNonce $nonce -BootId 200 -UsbEpoch 1 -GrantSession 661 -GrantCycle 3 -SlotToken 77 -Generation 1 -DeviceMs 100 -Version 2
$t=Tick;[byte[]]$coalesced=$preparedFrame+$withdraw
$roles=@((NativeRole vehicle $coalesced ([long]$t)),(NativeRole ground ([byte[]]@()) ([long]$t)))
$denied=$false;try{$denied=-not(Invoke-R19GrantReservationRuntimePreflight $s $roles $t)}catch{}
Check ($denied-and$s.status-cne'Failed'-and$s.param_attempts-eq0) 'coalescedPrepared+Withdrawn DEFERs untilnormal causalparse, not falsefatal or unsafeOUT'
$parser=New-R19GrantReservationParser
foreach($r in (Add-R19GrantReservationBytes $parser $coalesced 0 $t)){Add-R19GrantReservationObservation $s vehicle $r.bytes $r.read_completed_ticks $t $r.raw_offset}
Check ($s.status-ceq'CancellationPending'-and$s.param_attempts-eq0) 'normalPrepared-thenWithdrawn order progressesonlycancellation'
$null=WriteNext $s CancelGround
$s=BoundFixture
[byte[]]$faultFrame=New-R19GrantReservationFrame -Opcode Fault -Role vehicle -ReaderSession 123 -SlotNonce $nonce -BootId 200 -UsbEpoch 1 -Version 2
$t=Tick;$roles=@((NativeRole vehicle $faultFrame ([long]$t)),(NativeRole ground ([byte[]]@()) ([long]$t)))
$denied=$false;try{$denied=-not(Invoke-R19GrantReservationRuntimePreflight $s $roles $t)}catch{}
Check (($denied-or$s.status-ceq'Failed')-and$s.status-ceq'Failed'-and$s.param_attempts-eq0) 'typedmatchingR19RFault inpublishedprefix blocksOUT before normalpollcursor'
$s=BoundFixture;Observe $s Withdrawn vehicle @{DeviceMs=120}
$status=$s.status;$before=$s.observations.Count
$errorText='';try{Observe $s Bound ground}catch{$errorText=$_.Exception.Message}
Check ($s.status-ceq$status-and$s.param_attempts-eq0-and-not(Test-R19GrantReservationRequestAllowed $s (Tick))) 'exactoldqueuedBound afterWithdrawal drainswithoutresurrectingpermit or falsefatal'
Check ($s.observations.Count-eq($before+1)-and$s.obsolete_controls.Count-eq1) 'obsoleteoldBound retainsboundedrawledger evidence'
$null=WriteNext $s CancelGround
Write-Output ('CANCELLATION_WORKFLOW PASS checks='+$script:checks+' hardware_interaction=false')
