[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='', [switch]$BaselineProbe)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent(Split-Path -Parent $PSScriptRoot)}
$capture=Join-Path $RepoRoot 'tools/run_r19_timed_path_capture.ps1'
$savedRoot=$RepoRoot;$savedOutput=$OutputDirectory
try{. $capture -ImportOnly -ParamListDiagnostics -Mode ExplicitHostArm -AuxReadinessDiagnostics -DiagnosticUsbFailureDiagnostics}finally{$RepoRoot=$savedRoot;$OutputDirectory=$savedOutput}
$script:checks=0;$script:writes=0
function Check([bool]$Value,[string]$Name){$script:checks++;if(-not$Value){throw ('FAIL '+$Name)}}
$paramState=New-R19ParamListDiagnosticsState -Frequency 1000 -ClockDomainId 'reservation-fixture'
$arguments=@{State=$paramState;Role='ground';Workflow=[pscustomobject]@{arm_write_accepted=$true};HeartbeatCount=1;CaptureDeadlineTicks='40000';RawOffset=0L;ReaderPendingBytes=0;NowTicks={'100'};Writer={param([byte[]]$Bytes)$script:writes++;return [int]$Bytes.Length}}
# A reservation-mode request is intended here even on the old implementation.
# Call the old real helper, not a missing-parameter/parse-error substitute.
if((Get-Command Invoke-R19ParamListRequest).Parameters.ContainsKey('GrantReservationDiagnostics')){$arguments.GrantReservationDiagnostics=$true}
$sent=Invoke-R19ParamListRequest @arguments
Check (-not$sent-and$script:writes-eq0-and$paramState.write_attempts-eq0) 'reservation request cannot send with ARM+Heartbeat but no actual Bound slot'
if($BaselineProbe){Write-Output "R19_GRANT_RESERVATION behavioral PASS checks=$script:checks hardware_interaction=false";exit 0}
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_wire.ps1')
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_workflow.ps1')
function Reject([scriptblock]$Body,[string]$Name){$message='';try{&$Body|Out-Null}catch{$message=$_.Exception.Message};Check (-not[string]::IsNullOrWhiteSpace($message)) $Name}
$nonce=[Convert]::ToUInt64('521B000000000001',16).ToString()
$script:now=10L
function Fixture {
  $s=New-R19GrantReservationWorkflow -CandidateId SYNTHETIC-NOT-HARDWARE -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession '123' -SlotNonce $nonce -ClockDomainId fixture -Frequency '1000' -StartTicks '0'
  Set-R19GrantReservationPrerequisites $s $true $true $true $true '10'
  return $s
}
function Tick {$script:now+=10;return $script:now.ToString()}
function NextWrite([object]$S,[string]$Expected){
  $c=Get-R19GrantReservationNextCommand $S (Tick);Check ($null-ne$c-and$c.opcode-ceq$Expected) ('next canonical command '+$Expected)
  $null=Invoke-R19ReservationPrivateWrite -State $S -Command $c -NowTicks {$script:now.ToString()} -Writer {param([byte[]]$Bytes)$script:writes++;return [int]$Bytes.Length}
  return $c
}
function Response([string]$Opcode,[string]$Role,[hashtable]$Override=@{}){
  $a=@{Opcode=$Opcode;Role=$Role;ReaderSession='123';SlotNonce=$nonce;BootId=$(if($Role-ceq'ground'){'100'}else{'200'});UsbEpoch=0;DeviceMs=100}
  if($Opcode-ceq'HelloReply'){$a.GrantSession=$(if($Role-ceq'ground'){1}else{0});$a.GrantCycle=$(if($Role-ceq'ground'){1}else{0})}
  elseif($Opcode-cne'Fault'){$a.GrantSession=1;$a.GrantCycle=2;$a.SlotToken=77;$a.Generation=1}
  foreach($k in $Override.Keys){$a[$k]=$Override[$k]};return ,(New-R19GrantReservationFrame @a)
}
function Observe([object]$S,[string]$Opcode,[string]$Role,[hashtable]$Override=@{}){
  [byte[]]$b=Response $Opcode $Role $Override;$t=Tick
  Add-R19GrantReservationObservation $S $Role $b $t $t 0
}
function BoundFixture {
  param([switch]$BeforeBound)
  $script:now=10L;$s=Fixture
  $null=NextWrite $s HelloRequest;$null=NextWrite $s HelloRequest
  Observe $s HelloReply vehicle;Observe $s HelloReply ground
  $c=NextWrite $s PrepareVehicle;$d=ConvertFrom-R19GrantReservationFrame $c.bytes
  Check ($d.boot_id-ceq'200'-and$d.usb_epoch-ceq'0'-and$d.grant_session-ceq'1'-and$d.grant_cycle-ceq'1'-and$d.slot_token-ceq'0') 'Prepare uses localVehicle identity and actualGround baseline'
  Observe $s Prepared vehicle
  $c=NextWrite $s BindPeerVehicle;$d=ConvertFrom-R19GrantReservationFrame $c.bytes;Check ($d.boot_id-ceq'100'-and$d.role-ceq'vehicle') 'Vehicle bind names peerGround identity'
  $c=NextWrite $s BindGround;$d=ConvertFrom-R19GrantReservationFrame $c.bytes;Check ($d.boot_id-ceq'100'-and$d.device_ms-ceq'0') 'Ground bind names ownGround identity'
  $c=NextWrite $s BindPeerGround;$d=ConvertFrom-R19GrantReservationFrame $c.bytes;Check ($d.boot_id-ceq'200'-and$d.role-ceq'ground') 'Ground peerbind names Vehicle identity'
  if($BeforeBound){return $s}
  Observe $s Bound ground
  Check (Test-R19GrantReservationRequestAllowed $s (Tick)) 'only actualBound slot opens one-request gate'
  return $s
}
function WriteParam([object]$S,[scriptblock]$Writer={param([byte[]]$Bytes)$script:writes++;return [int]$Bytes.Length}){
  $p=New-R19ParamListDiagnosticsState -Frequency 1000 -ClockDomainId fixture
  $a=@{State=$p;Role='ground';Workflow=[pscustomobject]@{arm_write_accepted=$true};HeartbeatCount=1;CaptureDeadlineTicks='40000';RawOffset=0L;ReaderPendingBytes=0;NowTicks={$script:now.ToString()};Writer=$Writer;GrantReservationDiagnostics=$true;ReservationWorkflow=$S}
  $ok=Invoke-R19ParamListRequest @a
  return [pscustomobject]@{param=$p;sent=$ok;arguments=$a}
}
$script:now=10;$s=Fixture
Check ($null-eq(Get-R19GrantReservationNextCommand (New-R19GrantReservationWorkflow -CandidateId SYNTHETIC-NOT-HARDWARE -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession '123' -SlotNonce $nonce -ClockDomainId fixture -Frequency '1000' -StartTicks '0') '10')) 'noHello before bothclock,ARM,postARMprimaryHB prerequisites'
$s=BoundFixture;$p=WriteParam $s
Check ($p.sent-and$p.param.write_attempts-eq1-and$p.param.accepted_bytes-eq14-and$p.param.deadline_ticks-eq($p.param.request_write_started_ticks+30000)) 'realhelper exact14once preserves original30second t0'
$again=$p.arguments;Check (-not(Invoke-R19ParamListRequest @again)-and$p.param.write_attempts-eq1) 'same realhelper never sends a second request'
Check ($null-eq(Get-R19GrantReservationNextCommand $s (Tick))) 'PC cannot releaseVehicle without trueGroundHeld response'
Observe $s GroundHeld ground @{DeviceMs=350}
$c=NextWrite $s ReleaseVehicle;$d=ConvertFrom-R19GrantReservationFrame $c.bytes
Check ($d.boot_id-ceq'200'-and$d.device_ms-ceq'350') 'Release uses ownVehicle identity and forwards actualGround t0 as a peer claim'
Check ($null-eq(Get-R19GrantReservationNextCommand $s (Tick))) 'PC cannot sendGroundTailPermit without actualVehicleTailReady'
Observe $s TailReady vehicle @{DeviceMs=900}
$c=NextWrite $s TailPermitGround;$d=ConvertFrom-R19GrantReservationFrame $c.bytes
Check ($d.boot_id-ceq'200'-and$d.role-ceq'ground'-and$d.device_ms-ceq'900') 'TailPermit names peerVehicle identity and forwards actualP claim unchanged'
Check ($s.commands.Count-eq8-and$s.param_attempts-eq1-and$null-eq(Get-R19GrantReservationNextCommand $s (Tick))) 'bounded normalflow has8reservationOUT plus1canonicalPARAM and no retries'
Check (-not$s.high_speed_success_proven-and-not$s.rf_delivery_proven-and-not$s.acceptance_authorized) 'USB control sequence is never RF/highspeed/product success'
$script:now=10;$x=Fixture;$c=Get-R19GrantReservationNextCommand $x (Tick)
Check ($null-eq$c.started_ticks) 'builtbutunattempted command is not an OUT attempt'
$null=Invoke-R19ReservationPrivateWrite $x $c {$script:now.ToString()} {param([byte[]]$Bytes)Check ($null-ne$x.pending_command.started_ticks) 'OUT attempt timestamp is fixed before injected callback';return [int]$Bytes.Length}
foreach($which in @('HelloReply','Prepared','Bound','TailReady')){
  if($which-ceq'HelloReply'){$script:now=10;$x=Fixture;$null=NextWrite $x HelloRequest;$role='ground'}
  elseif($which-ceq'Prepared'){$script:now=10;$x=Fixture;$null=NextWrite $x HelloRequest;$null=NextWrite $x HelloRequest;Observe $x HelloReply ground;Observe $x HelloReply vehicle;$null=NextWrite $x PrepareVehicle;$role='vehicle'}
  elseif($which-ceq'Bound'){$x=BoundFixture -BeforeBound;$role='ground'}
  else{$x=BoundFixture;$null=WriteParam $x;Observe $x GroundHeld ground @{DeviceMs=350};$null=NextWrite $x ReleaseVehicle;$role='vehicle'}
  [byte[]]$earlyResponse=Response $which $role;$t=Tick
  Reject {Add-R19GrantReservationObservation $x $role $earlyResponse '0' $t 0} ($which+' cannot use native bytes received before matching OUT began')
}
foreach($case in @(
  @{name='Held-before-request';op='GroundHeld';role='ground';changes=@{};param=$false},
  @{name='Held-wrong-slot';op='GroundHeld';role='ground';changes=@{SlotToken=78};param=$true},
  @{name='Held-wrong-generation';op='GroundHeld';role='ground';changes=@{Generation=2};param=$true},
  @{name='Held-wrong-boot';op='GroundHeld';role='ground';changes=@{BootId='101'};param=$true},
  @{name='Held-wrong-epoch';op='GroundHeld';role='ground';changes=@{UsbEpoch=1};param=$true},
  @{name='Held-wrong-nonce';op='GroundHeld';role='ground';changes=@{SlotNonce=([Convert]::ToUInt64('521B000000000002',16).ToString())};param=$true},
  @{name='Held-wrong-reader';op='GroundHeld';role='ground';changes=@{ReaderSession='124'};param=$true},
  @{name='Tail-before-release';op='TailReady';role='vehicle';changes=@{DeviceMs=900};param=$true})){
  $x=BoundFixture;if($case.param){$null=WriteParam $x};$beforeCount=$x.commands.Count
  Reject {Observe $x $case.op $case.role $case.changes} $case.name
  Check ($x.status-ceq'Failed'-and$x.commands.Count-eq$beforeCount) ($case.name+' blocks further command construction')
}
$x=BoundFixture;$null=WriteParam $x
[byte[]]$held=Response GroundHeld ground @{DeviceMs=350};$t=Tick
Reject {Add-R19GrantReservationObservation $x vehicle $held $t $t 0} 'response role cannot be moved to the otherUSB channel'
foreach($accepted in @(0,32,65)){
  $script:now=10;$x=Fixture;$c=Get-R19GrantReservationNextCommand $x (Tick)
  Reject {Set-R19GrantReservationWriteResult $x $accepted $script:now.ToString() $script:now.ToString()} ('partialprivatewrite'+$accepted)
  Check ($x.commands.Count-eq1-and$x.status-ceq'Failed'-and-not$x.commands[0].write_success) 'partialprivatewrite remains one failed attempt'
  Reject {Get-R19GrantReservationNextCommand $x (Tick)} 'partialprivatewrite cannot automaticallyretry'
}
$script:now=10;$x=Fixture;$c=Get-R19GrantReservationNextCommand $x (Tick)
Reject {Invoke-R19ReservationPrivateWrite $x $c {$script:now.ToString()} {param([byte[]]$Bytes)throw 'OFFLINE_INJECTED_WRITE_ERROR'}} 'throwingprivatewriter cannot invent acceptance'
Check ($x.commands.Count-eq1-and$x.status-ceq'Failed'-and$x.commands[0].accepted_bytes-eq$null) 'unknownaccepted prefix stays unknown and cannotretry'
$x=BoundFixture
Reject {WriteParam $x {param([byte[]]$Bytes)$script:writes++;return [int]7}} 'partialPARAMwrite fails reservation workflow without release'
Check ($x.param_attempts-eq1-and$x.param_accepted_bytes-eq7-and$x.status-ceq'Failed') 'partialPARAM remains one immutableattempt'
$script:now=10;$x=Fixture
Reject {Get-R19GrantReservationNextCommand $x '15001'} 'preparation15seconds bounded without resettingmeasurement or requestt0'
Check ($x.param_attempts-eq0-and$x.commands.Count-eq0) 'expiredpreparation didnot consumePARAM or buildrelease'
Check ($x.failure_phase-ceq'HelloPending'-and$x.not_ready_count-eq1-and$x.failure-ceq'PREPARATION_15_SECONDS_EXPIRED') 'failedphase reasonandnotreadycount survive passive capture transition'
$x=BoundFixture;$null=WriteParam $x;Observe $x GroundHeld ground @{DeviceMs=350}
Reject {Observe $x GroundHeld ground @{DeviceMs=350}} 'replayedHeld doesnot authorize duplicateVehicleRelease'
foreach($b in @(
  @{name='HelloRequest';role='ground';args=@{BootId='0';DeviceMs=0}},
  @{name='HelloReply';role='ground';args=@{BootId='100';GrantSession=1;GrantCycle=0}},
  @{name='HelloReply';role='vehicle';args=@{BootId='200'}},
  @{name='PrepareVehicle';role='vehicle';args=@{BootId='200';GrantSession=1;GrantCycle=0}},
  @{name='Prepared';role='vehicle';args=@{BootId='200';GrantSession=1;GrantCycle=2;SlotToken=77;Generation=1}},
  @{name='Fault';role='ground';args=@{BootId='100'}})){
  $a=@{Opcode=$b.name;Role=$b.role;ReaderSession='123';SlotNonce=$nonce};foreach($k in $b.args.Keys){$a[$k]=$b.args[$k]}
  [byte[]]$encoded=New-R19GrantReservationFrame @a;$decoded=ConvertFrom-R19GrantReservationFrame $encoded
  Check ($encoded.Length-eq66-and$decoded.valid-and$decoded.opcode-ceq$b.name-and$decoded.usb_epoch-ceq'0') ('canonicalcodecroundtrip '+$b.name+'/'+$b.role+' zeroepochvalid')
}
Reject {New-R19GrantReservationFrame -Opcode Started -Role vehicle -ReaderSession '123' -SlotNonce $nonce -BootId '200' -GrantSession 1 -GrantCycle 2 -SlotToken 77 -Generation 1} 'Started14is record-only,notwire'
Reject {New-R19GrantReservationFrame -Opcode Fault -Role ground -ReaderSession '123' -SlotNonce $nonce -BootId '100' -Flags 1} 'Faultflags alsozero;reasononlyJTAG'
foreach($field in @('ReaderSession','SlotNonce','BootId','UsbEpoch','GrantSession','GrantCycle','SlotToken','Generation','DeviceMs')){
  $a=@{Opcode='Prepared';Role='vehicle';ReaderSession='123';SlotNonce=$nonce;BootId='200';UsbEpoch=0;GrantSession=1;GrantCycle=2;SlotToken=77;Generation=1;DeviceMs=100};$a[$field]=$true
  Reject {New-R19GrantReservationFrame @a} ('Boolean cannot become integer '+$field)
}
foreach($change in @(@(2,1),@(3,1),@(5,1),@(6,197),@(10,83),@(14,3),@(15,14),@(16,1),@(17,1),@(62,0))){
  [byte[]]$bad=Response Prepared vehicle;$bad[$change[0]]=[byte]$change[1];[uint16]$crc=Get-R19GrantReservationCrc $bad;$bad[64]=[byte]($crc-band255);$bad[65]=[byte]($crc-shr8)
  Check (-not(ConvertFrom-R19GrantReservationFrame $bad).valid) ('CRC-valid wrongnamespace/opcode rejected atbyte'+$change[0])
}
[byte[]]$bad=Response Prepared vehicle;$bad[65]=$bad[65]-bxor1;Check (-not(ConvertFrom-R19GrantReservationFrame $bad).valid) 'badCRC cannot advanceworkflow'
[byte[]]$valid=Response Prepared vehicle
for($split=1;$split-lt66;$split++){
  $parser=New-R19GrantReservationParser
  $first=Add-R19GrantReservationBytes $parser ([byte[]]$valid[0..($split-1)]) 0 '100'
  $last=Add-R19GrantReservationBytes $parser ([byte[]]$valid[$split..65]) $split '110'
  Check (@($first).Count-eq0-and@($last).Count-eq1-and$last[0].decoded.opcode-ceq'Prepared') ('all66byte splits reconstructonce '+$split)
}
$outer=[byte[]]::new(78);$outer[0]=253;$outer[1]=66;$outer[5]=1;$outer[6]=1;$outer[7]=253;[Array]::Copy($valid,0,$outer,10,66)
$parser=New-R19GrantReservationParser;[byte[]]$stream=$outer+$valid
$found=Add-R19GrantReservationBytes $parser $stream 0 '100'
Check (@($found).Count-eq1-and$found[0].raw_offset-eq78) 'embeddedR19R in otherMAVLinkpayload is not a top-levelreservationresponse'
$snap=Get-R19GrantReservationSnapshot $s
Check ($snap.actual_negotiation_start_ms-eq$null-and$snap.actual_bulk_start_ms-eq$null-and$snap.status-ceq'TailPermitWrittenAwaitingMcuEvidence') 'unknownMCUprotocoltimes remainnull afterallUSBcommands'
$snap.commands[0].kind='MUTATED';Check ($s.commands[0].kind-cne'MUTATED') 'snapshotcannot mutateworkflowevidence'
if(-not$OutputDirectory){$OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('r19-reservation-'+[guid]::NewGuid().ToString('N'))};[void][IO.Directory]::CreateDirectory($OutputDirectory)
$path=Join-Path $OutputDirectory 'workflow.json';$saved=Get-R19GrantReservationSnapshot $s;[IO.File]::WriteAllText($path,($saved|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false));$read=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
Check (($saved|ConvertTo-Json -Depth 20 -Compress)-ceq($read|ConvertTo-Json -Depth 20 -Compress)) 'actualsavedworkflowJSONroundtrip preservesallcommands/observations/t0/identity'
Write-Output "R19_GRANT_RESERVATION_WORKFLOW PASS checks=$script:checks hardware_interaction=false automatic_retries=0 output=$OutputDirectory"
