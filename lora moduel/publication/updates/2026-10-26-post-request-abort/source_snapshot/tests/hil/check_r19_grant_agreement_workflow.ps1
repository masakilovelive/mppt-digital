[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='', [switch]$BaselineProbe)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent(Split-Path -Parent $PSScriptRoot)}
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_wire.ps1')
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_workflow.ps1')
$script:checks=0;$script:now=10L;$script:writes=0
function Check([bool]$V,[string]$Message){$script:checks++;if(-not$V){throw ('FAIL '+$Message)}}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Check $failed $Message}
$nonce=[Convert]::ToUInt64('521B000000000001',16).ToString()
$freshNonce=[Convert]::ToUInt64('521B000000000002',16).ToString()
function Tick {$script:now+=10;return $script:now.ToString()}
function Fixture {
  $script:now=10L
  $a=@{CandidateId='SYNTHETIC-AGREEMENT';HandoffSha256=('A'*64);FlashSha256=('B'*64);ReaderSession=123;SlotNonce=$nonce;ClockDomainId='fixture';Frequency='1000';StartTicks='0';CancellationEnabled=$true}
  if((Get-Command New-R19GrantReservationWorkflow).Parameters.ContainsKey('AgreementEnabled')){$a.AgreementEnabled=$true}
  $s=New-R19GrantReservationWorkflow @a
  Set-R19GrantReservationPrerequisites $s $true $true $true $true '10'
  return $s
}
function WriteNext([object]$S,[string]$Expected){
  $c=Get-R19GrantReservationNextCommand $S (Tick)
  Check ($null-ne$c-and$c.kind-ceq$Expected) ('next '+$Expected)
  $null=Invoke-R19ReservationPrivateWrite $S $c {$script:now.ToString()} {param([byte[]]$Bytes)$script:writes++;return [int]$Bytes.Length}
  return $c
}
function Frame([object]$S,[string]$Op,[string]$Role,[hashtable]$Override=@{}){
  $a=@{Opcode=$Op;Role=$Role;ReaderSession=123;SlotNonce=$S.slot_nonce;BootId=$(if($Role-ceq'ground'){100}else{200});UsbEpoch=1;DeviceMs=100;Version=$S.wire_version}
  if($Op-ceq'HelloReply'){$a.GrantSession=661;$a.GrantCycle=2}
  elseif($Op-cne'Fault'){$a.GrantSession=661;$a.GrantCycle=3;$a.SlotToken=77;$a.Generation=1}
  if($Op-ceq'CancelPeerConfirmed'){$a.Response=$true}
  foreach($k in $Override.Keys){$a[$k]=$Override[$k]}
  return ,(New-R19GrantReservationFrame @a)
}
function Observe([object]$S,[string]$Op,[string]$Role,[hashtable]$Override=@{}){
  [byte[]]$bytes=Frame $S $Op $Role $Override;$t=Tick
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
Check (-not(Test-R19GrantReservationRequestAllowed $s (Tick))) 'v3 Bound alone cannot authorize PARAM before bilateral commit'
if($BaselineProbe){Write-Output ('AGREEMENT_BASELINE PASS checks='+$script:checks);exit 0}
Check ($s.wire_version-eq3-and$s.agreement_enabled) 'agreement is explicit wirev3'
function Commit([object]$S){
  $null=WriteNext $S CommitVehicle
  Check (-not(Test-R19GrantReservationRequestAllowed $S (Tick))) 'one commit OUT is not acknowledgment'
  Observe $S CommitAck vehicle @{DeviceMs=110}
  Check (-not(Test-R19GrantReservationRequestAllowed $S (Tick))) 'one MCU commit ACK does not authorize PARAM'
  $null=WriteNext $S CommitGround
  Observe $S CommitAck ground @{DeviceMs=120}
  Check (Test-R19GrantReservationRequestAllowed $S (Tick)) 'both actual tuple-bound ACKs authorize at most one attempt'
}
Commit $s
Check (-not$s.high_speed_success_proven-and-not$s.rf_delivery_proven) 'bilateral commit is not irrevocable reservation or RF delivery'
$committedNow=$script:now
foreach($bad in @('before-write','one-role','boot','epoch','nonce','reader','tuple','early-ms','early-native','duplicate','wrong-role')){
  $x=BoundFixture
  if($bad-cne'before-write'){$null=WriteNext $x CommitVehicle}
  $over=@{DeviceMs=110}
  switch($bad){'boot'{$over.BootId=201};'epoch'{$over.UsbEpoch=2};'nonce'{$over.SlotNonce=$freshNonce};'reader'{$over.ReaderSession=124};'tuple'{$over.Generation=2};'early-ms'{$over.DeviceMs=99};'duplicate'{Observe $x CommitAck vehicle @{DeviceMs=110}}}
  if($bad-ceq'one-role'){
    Observe $x CommitAck vehicle @{DeviceMs=110}
    Check (-not(Test-R19GrantReservationRequestAllowed $x (Tick))) 'one valid role commit still leaves PARAM gate closed'
    continue
  }
  if($bad-ceq'early-native'){
    [byte[]]$b=Frame $x CommitAck vehicle @{DeviceMs=110};$t=Tick
    Reject {Add-R19GrantReservationObservation $x vehicle $b '0' $t 0} ('commit '+$bad)
  }elseif($bad-ceq'wrong-role'){Reject {Observe $x CommitAck ground @{DeviceMs=110}} ('commit '+$bad)}
  else{Reject {Observe $x CommitAck vehicle $over} ('commit '+$bad)}
  Check ($x.status-ceq'Failed'-and$x.param_attempts-eq0) ('invalid commit keeps zero PARAM '+$bad)
}
$script:now=$committedNow
[byte[]]$param=@(253,2,0,0,99,255,190,21,0,0,1,1,213,7)
Begin-R19GrantReservationParamWrite $s $param (Tick)
$t0=$s.param_write_started_ticks;Set-R19GrantReservationParamWriteResult $s 14 (Tick)
Reject {Observe $s Withdrawn vehicle @{DeviceMs=130}} 'post-request withdrawal is terminal attempted abort'
Check ($s.status-ceq'Failed'-and$s.failure-ceq'ATTEMPTED_ABORT_WITHDRAWN_AFTER_REQUEST'-and$s.param_attempts-eq1-and$s.param_write_started_ticks-ceq$t0) 'failure and original PARAM origin remain immutable'
Check ($s.terminal_abort.phase-ceq'ABORT_UNCONFIRMED') 'terminal cleanup is independent from failed workflow'
Reject {Get-R19GrantReservationNextCommand $s (Tick)} 'normal failed-state write path stays closed'
function AbortWrite([object]$S,[string]$Role,[scriptblock]$Writer={param([byte[]]$Bytes)$script:writes++;return [int]$Bytes.Length}){
  $c=Get-R19GrantReservationTerminalAbortCommand -State $S -Role $Role -NowTicks (Tick) -CaptureDeadlineTicks '40000'
  Check ($null-ne$c-and$c.opcode-ceq'AbortRequest'-and$c.role-ceq$Role) ('single terminal command '+$Role)
  $null=Invoke-R19ReservationTerminalAbortWrite -State $S -Command $c -NowTicks {$script:now.ToString()} -Writer $Writer
  return $c
}
function AbortAck([object]$S,[string]$Role,[hashtable]$Override=@{}){
  [byte[]]$bytes=Frame $S AbortAck $Role $Override;$t=Tick
  Add-R19GrantReservationTerminalAbortObservation -State $S -ChannelRole $Role -Bytes $bytes -ReadCompletedTicks $t -NowTicks $t -RawOffset 0
}
$null=AbortWrite $s vehicle;AbortAck $s vehicle @{DeviceMs=140}
Check ($s.terminal_abort.phase-ceq'ABORT_UNCONFIRMED'-and$s.status-ceq'Failed') 'one AbortAck cannot prove bilateral abort'
$null=AbortWrite $s ground;AbortAck $s ground @{DeviceMs=150}
Check ($s.terminal_abort.phase-ceq'ABORTED_CONFIRMED'-and$s.status-ceq'Failed'-and$s.param_write_started_ticks-ceq$t0) 'both exact ACKs confirm retirement without reviving normal workflow'
foreach($role in @('ground','vehicle')){Check ($null-eq(Get-R19GrantReservationTerminalAbortCommand $s $role (Tick) '40000')) ('no terminal retry '+$role)}
Check ((Get-R19GrantReservationSnapshot $s).request_outcome-ceq'ATTEMPTED_ABORT') 'cleanup does not turn attempted abort into success'
foreach($bad in @('boot','epoch','nonce','reader','tuple','version','before-write','before-native','duplicate')){
  $x=BoundFixture;Commit $x;Begin-R19GrantReservationParamWrite $x $param (Tick);Set-R19GrantReservationParamWriteResult $x 14 (Tick)
  Reject {Observe $x Withdrawn vehicle @{DeviceMs=130}} ('trigger '+$bad)
  if($bad-cne'before-write'){$null=AbortWrite $x vehicle}
  $over=@{DeviceMs=140}
  switch($bad){'boot'{$over.BootId=201};'epoch'{$over.UsbEpoch=2};'nonce'{$over.SlotNonce=$freshNonce};'reader'{$over.ReaderSession=124};'tuple'{$over.SlotToken=78};'version'{$over.Version=2};'duplicate'{AbortAck $x vehicle @{DeviceMs=140}}}
  if($bad-ceq'version'){
    [byte[]]$b=Frame $x AbortAck vehicle @{DeviceMs=140};$b[14]=2;[uint16]$crc=Get-R19GrantReservationCrc $b;$b[64]=[byte]($crc-band255);$b[65]=[byte]($crc-shr8);$t=Tick
    Reject {Add-R19GrantReservationTerminalAbortObservation $x vehicle $b $t $t 0} ('reject '+$bad)
  }elseif($bad-ceq'before-native'){
    [byte[]]$b=Frame $x AbortAck vehicle @{DeviceMs=140};$t=Tick
    Reject {Add-R19GrantReservationTerminalAbortObservation $x vehicle $b '0' $t 0} ('reject '+$bad)
  }else{Reject {AbortAck $x vehicle $over} ('reject '+$bad)}
  Check ($x.status-ceq'Failed'-and$x.terminal_abort.phase-ceq'ABORT_UNCONFIRMED') ($bad+' never fabricates bilateral acknowledgment')
}
foreach($kind in @('private-partial','private-throw','param-partial','param-unknown','abort-partial','abort-throw')){
  $x=BoundFixture;Commit $x
  if($kind-like'private-*'){
    Begin-R19GrantReservationParamWrite $x $param (Tick);Set-R19GrantReservationParamWriteResult $x 14 (Tick);Observe $x GroundHeld ground @{DeviceMs=125}
    $c=Get-R19GrantReservationNextCommand $x (Tick)
    if($kind-ceq'private-partial'){Reject {Invoke-R19ReservationPrivateWrite $x $c {$script:now.ToString()} {param($Bytes)return [int]32}} $kind}
    else{Reject {Invoke-R19ReservationPrivateWrite $x $c {$script:now.ToString()} {param($Bytes)throw 'injected'}} $kind}
    Check ($null-eq(Get-R19GrantReservationTerminalAbortCommand $x vehicle (Tick) '40000')-and$x.terminal_abort.roles.vehicle.blocked_reason-ceq'PRIVATE_OUT_PREFIX_UNKNOWN') 'unknown private prefix prevents additional abort OUT to that role'
  }elseif($kind-like'param-*'){
    Begin-R19GrantReservationParamWrite $x $param (Tick)
    $count=if($kind-ceq'param-partial'){7}else{$null}
    Reject {Set-R19GrantReservationParamWriteResult $x $count (Tick) $(if($kind-ceq'param-unknown'){'Injected'}else{''})} $kind
    Check ($null-eq(Get-R19GrantReservationTerminalAbortCommand $x ground (Tick) '40000')-and$x.terminal_abort.roles.ground.blocked_reason-ceq'PARAM_OUT_PREFIX_UNKNOWN') 'unknown PARAM prefix prevents Ground abort OUT'
  }else{
    Begin-R19GrantReservationParamWrite $x $param (Tick);Set-R19GrantReservationParamWriteResult $x 14 (Tick);Reject {Observe $x Withdrawn vehicle @{DeviceMs=130}} 'terminal trigger'
    if($kind-ceq'abort-partial'){$null=AbortWrite $x vehicle {param($Bytes)$script:writes++;return [int]32}}
    else{$null=AbortWrite $x vehicle {param($Bytes)$script:writes++;throw 'injected'}}
    Check ($null-eq(Get-R19GrantReservationTerminalAbortCommand $x vehicle (Tick) '40000')-and$x.terminal_abort.roles.vehicle.attempts-eq1-and-not$x.terminal_abort.roles.vehicle.write_success) 'unknown terminal prefix never retries'
  }
  Check ($x.status-ceq'Failed'-and$x.param_attempts-eq1) ($kind+' remains failed with one PARAM attempt')
}
$x=BoundFixture;Commit $x;Observe $x Withdrawn vehicle @{DeviceMs=130}
Check (-not(Test-R19GrantReservationRequestAllowed $x (Tick))) 'pre-PARAM withdrawal closes committed authorization'
$null=WriteNext $x CancelGround;Observe $x CancelAck ground @{DeviceMs=140}
$null=WriteNext $x CancelVehicle;Observe $x CancelAck vehicle @{DeviceMs=150}
$null=WriteNext $x CancelPeerGround;Observe $x CancelPeerConfirmed ground @{DeviceMs=160}
$null=WriteNext $x CancelPeerVehicle;Observe $x CancelPeerConfirmed vehicle @{DeviceMs=170}
Start-R19GrantReservationNextRound $x $freshNonce (Tick)
Check ($null-eq$x.commit_ground-and$null-eq$x.commit_vehicle-and$x.param_attempts-eq0-and$x.prepare_deadline_ticks-ceq'15000'-and$x.wire_version-eq3) 'fresh nonce resets both commit ACKs, not original deadlines or PARAM budget'
$null=WriteNext $x Helloground;$null=WriteNext $x Hellovehicle;Observe $x HelloReply ground @{GrantCycle=3};Observe $x HelloReply vehicle @{GrantCycle=3};$null=WriteNext $x PrepareVehicle
Reject {Observe $x Prepared vehicle} 'old RF tuple rejected even under a fresh nonce'
foreach($op in @('CommitRequest','CommitAck','AbortRequest','AbortAck')){
  [byte[]]$b=Frame $s $op vehicle @{DeviceMs=$(if($op-like'*Request'){0}else{140})}
  $d=ConvertFrom-R19GrantReservationFrame $b -AgreementEnabled $true
  Check ($d.valid-and$d.version-eq3-and$d.component-eq$(if($op-like'*Request'){197}else{198})) ('v3 canonical '+$op)
  Reject {Frame $s $op vehicle @{Version=2;DeviceMs=0}} ('legacy v2 rejects '+$op)
  Reject {Frame $s $op vehicle @{SlotToken=0;DeviceMs=0}} ('incomplete tuple rejects '+$op)
  if($op-like'*Request'){Reject {Frame $s $op vehicle @{DeviceMs=1}} ('request cannot claim MCU time '+$op)}
}
[byte[]]$v3frame=Frame $s CommitAck vehicle @{DeviceMs=140}
Check (-not(ConvertFrom-R19GrantReservationFrame $v3frame).valid) 'default decoder does not gain v3 authority'
for($split=1;$split-lt66;$split++){
  $parser=New-R19GrantReservationParser -AgreementEnabled $true
  $first=Add-R19GrantReservationBytes $parser ([byte[]]$v3frame[0..($split-1)]) 0 '100'
  $last=Add-R19GrantReservationBytes $parser ([byte[]]$v3frame[$split..65]) $split '110'
  Check (@($first).Count-eq0-and@($last).Count-eq1-and$last[0].decoded.opcode-ceq'CommitAck') ('v3 parser every split '+$split)
}
$parser=New-R19GrantReservationParser
$found=Add-R19GrantReservationBytes $parser $v3frame 0 '100'
Check (@($found).Count-eq0-and$parser.invalid_namespace_frames-eq1) 'default parser does not gain v3 authority'
$x=BoundFixture;Commit $x;Observe $x Withdrawn vehicle @{DeviceMs=130}
$null=WriteNext $x CancelGround;Observe $x CancelAck ground @{DeviceMs=140}
$null=WriteNext $x CancelVehicle;Observe $x CancelAck vehicle @{DeviceMs=150}
$null=WriteNext $x CancelPeerGround;Observe $x CancelPeerConfirmed ground @{DeviceMs=160}
$null=WriteNext $x CancelPeerVehicle;Observe $x CancelPeerConfirmed vehicle @{DeviceMs=170}
Start-R19GrantReservationNextRound $x $freshNonce (Tick)
$null=WriteNext $x Helloground;$null=WriteNext $x Hellovehicle;Observe $x HelloReply ground @{GrantCycle=3};Observe $x HelloReply vehicle @{GrantCycle=3};$null=WriteNext $x PrepareVehicle
$newTuple=@{GrantCycle=4;SlotToken=78;Generation=2;DeviceMs=200}
Observe $x Prepared vehicle $newTuple
$null=WriteNext $x BindPeerVehicle;$null=WriteNext $x BindGround;$null=WriteNext $x BindPeerGround;Observe $x Bound ground $newTuple
Check (-not(Test-R19GrantReservationRequestAllowed $x (Tick))) 'new round Bound cannot reuse old bilateral commit'
$null=WriteNext $x CommitVehicle;Observe $x CommitAck vehicle $newTuple
$null=WriteNext $x CommitGround;Observe $x CommitAck ground $newTuple
Check (Test-R19GrantReservationRequestAllowed $x (Tick)) 'only new tuple new bilateral commits allow the one request'
Begin-R19GrantReservationParamWrite $x $param (Tick);Set-R19GrantReservationParamWriteResult $x 14 (Tick)
$newTuple.DeviceMs=350;Observe $x GroundHeld ground $newTuple;$null=WriteNext $x ReleaseVehicle
$newTuple.DeviceMs=900;Observe $x TailReady vehicle $newTuple;$null=WriteNext $x TailPermitGround
Check ($x.commands.Count-eq22-and$x.maximum_commands-eq24-and$x.prepare_deadline_ticks-ceq'15000') 'v3 two-round maximum is22 ordinary controls plus two deauthorization controls without resetting origin'
Reject {Stop-R19GrantReservationWorkflow $x 'OFFLINE_TERMINAL_COMPARISON'} 'offline terminal boundary'
$null=AbortWrite $x vehicle;$newTuple.DeviceMs=1000;AbortAck $x vehicle $newTuple
$null=AbortWrite $x ground;$newTuple.DeviceMs=1200;AbortAck $x ground $newTuple
Check ($x.commands.Count-eq24-and$x.terminal_abort.phase-ceq'ABORTED_CONFIRMED'-and$x.param_attempts-eq1) 'worst bounded v3 trace fits exact24 controls and one PARAM'
$legacy=New-R19GrantReservationWorkflow -CandidateId SYNTHETIC-LEGACY -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession 123 -SlotNonce $nonce -ClockDomainId fixture -Frequency 1000 -StartTicks 0
Check ($legacy.wire_version-eq1-and-not$legacy.agreement_enabled) 'legacy default has no agreement authority'
Reject {New-R19GrantReservationWorkflow -CandidateId SYNTHETIC-INVALID -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession 123 -SlotNonce $nonce -ClockDomainId fixture -Frequency 1000 -StartTicks 0 -AgreementEnabled $true} 'agreement requires explicit cancellation capability'
$capture=Join-Path $RepoRoot 'tools/run_r19_timed_path_capture.ps1'
$savedRoot=$RepoRoot;$savedOutput=$OutputDirectory
$import=@{ImportOnly=$true;ParamListDiagnostics=$true;Mode='ExplicitHostArm';AuxReadinessDiagnostics=$true;DiagnosticUsbFailureDiagnostics=$true;GrantDiagnostics=$true;GrantReservationDiagnostics=$true;GrantReservationStopDiagnostics=$true}
$captureInfo=Get-Command $capture
Check ($captureInfo.Parameters.ContainsKey('GrantAgreementDiagnostics')-and$captureInfo.Parameters['GrantAgreementDiagnostics'].Aliases-ccontains'GrantAgreementDiagnosticsEnabled') 'live integration preserves the prior offline flag as a canonical agreement alias'
$import.GrantAgreementDiagnosticsEnabled=$true
try{. $capture @import}finally{$RepoRoot=$savedRoot;$OutputDirectory=$savedOutput}
$script:markers=0
$reader=[pscustomobject]@{}
$reader|Add-Member ScriptMethod MarkPhase {param($Name)$script:markers++;[pscustomobject]@{ByteCount=0;Ticks=999}}
$roles=@([pscustomobject]@{reader=$reader;preparation_cut_offset=0L;preparation_cut_ticks=''},[pscustomobject]@{reader=$reader;preparation_cut_offset=0L;preparation_cut_ticks=''})
$x=BoundFixture
$started=$null;try{$started=Start-R19ReservationMeasurement $x $roles {'999'}}catch{}
Check ($null-eq$started-and$null-eq$x.measurement_start_ticks-and$script:markers-eq0) 'capture cannot mark measurement before bilateral commit'
Commit $x
Check ((Start-R19ReservationMeasurement $x $roles {'999'})-ceq'999'-and$script:markers-eq2) 'both commit ACKs permit one measurement boundary'
Reject {Start-R19ReservationMeasurement $x $roles {'1000'}} 'measurement boundary cannot restart'
function NativeRole([object]$S,[string]$Role,[long]$ByteCount=0){
  $id='synthetic-'+$Role;$S.runtime_fault_monitors.$Role.reader_id=$id
  $r=[pscustomobject]@{byte_count=$ByteCount}
  $r|Add-Member ScriptMethod GetSnapshot {[pscustomobject]@{Stopped=$false;Overflow=$false;Failure='';ByteCount=$this.byte_count;Blocks=@()}}
  [pscustomobject]@{spec=[pscustomobject]@{role=$Role};reader=$r;reader_id=$id;reservation_parser=(New-R19GrantReservationParser)}
}
function FailedCommitted {
  $s=BoundFixture;Commit $s;Begin-R19GrantReservationParamWrite $s $param (Tick);Set-R19GrantReservationParamWriteResult $s 14 (Tick)
  Reject {Observe $s Withdrawn vehicle @{DeviceMs=130}} 'terminal driver trigger'
  return $s
}
$x=FailedCommitted
$roles=@((NativeRole $x ground),(NativeRole $x vehicle));$script:driverWrites=0
Check (-not(Invoke-R19GrantReservationRuntimePreflight $x $roles (Tick))) 'normal failed-state preflight still rejects all ordinary OUT'
$n=Invoke-R19GrantReservationTerminalAbortDriver -State $x -States $roles -CaptureDeadlineTicks '40000' -NowTicks {$script:now.ToString()} -Writer {param($Target,[byte[]]$Bytes)$script:driverWrites++;Check ($Target.spec.role-cin@('vehicle','ground')-and$Bytes[15]-eq21) 'terminal driver only sends typed AbortRequest';return [int]$Bytes.Length}
Check ($n-eq2-and$script:driverWrites-eq2-and$x.status-ceq'Failed'-and$x.terminal_abort.phase-ceq'ABORT_UNCONFIRMED') 'capture terminal driver is bounded to one OUT per role and waits for actual ACKs'
$n=Invoke-R19GrantReservationTerminalAbortDriver -State $x -States $roles -CaptureDeadlineTicks '40000' -NowTicks {$script:now.ToString()} -Writer {param($Target,[byte[]]$Bytes)$script:driverWrites++;return [int]$Bytes.Length}
Check ($n-eq0-and$script:driverWrites-eq2) 'capture terminal driver never retries missing ACK'
AbortAck $x vehicle @{DeviceMs=140};AbortAck $x ground @{DeviceMs=150}
Check ($x.terminal_abort.phase-ceq'ABORTED_CONFIRMED'-and$x.status-ceq'Failed') 'capture integration can collect both ACKs without normal Failed revival'
$first=$x.terminal_abort.first_reason
Reject {Stop-R19GrantReservationWorkflow $x 'SECONDARY_ERROR'} 'secondary failure is still terminal'
Check ($x.terminal_abort.first_reason-ceq$first-and$x.failure-ceq$first) 'first workflow and cleanup failure causes are immutable'
$x=FailedCommitted;$roles=@((NativeRole $x ground 1),(NativeRole $x vehicle));$before=$script:driverWrites
$n=Invoke-R19GrantReservationTerminalAbortDriver -State $x -States $roles -CaptureDeadlineTicks '40000' -NowTicks {$script:now.ToString()} -Writer {param($Target,[byte[]]$Bytes)$script:driverWrites++;return [int]$Bytes.Length}
Check ($n-eq0-and$script:driverWrites-eq$before-and$x.terminal_abort.roles.ground.attempts-eq0-and$x.terminal_abort.roles.vehicle.attempts-eq0) 'undelivered native prefix defers cleanup with zero OUT attempts'
$x=FailedCommitted;$c=Get-R19GrantReservationTerminalAbortCommand $x vehicle (Tick) '40000'
Reject {Get-R19GrantReservationTerminalAbortCommand $x ground (Tick) '40001'} 'cleanup cannot extend the original capture deadline'
Check ($x.prepare_deadline_ticks-ceq'15000'-and$x.terminal_abort.capture_deadline_ticks-ceq'40000') 'preparation and capture origins are unchanged'
$x=FailedCommitted;$c=Get-R19GrantReservationTerminalAbortCommand $x vehicle (Tick) '40000'
[byte[]]$mutated=New-R19GrantReservationFrame -Opcode AbortRequest -Role vehicle -ReaderSession 123 -SlotNonce $x.slot_nonce -BootId 200 -UsbEpoch 1 -GrantSession 661 -GrantCycle 3 -SlotToken 78 -Generation 1 -Version 3
$c.bytes=$mutated;$c.frame_base64=[Convert]::ToBase64String($mutated);$before=$script:driverWrites
Reject {Invoke-R19ReservationTerminalAbortWrite $x $c {$script:now.ToString()} {param($Bytes)$script:driverWrites++;return 66}} 'changed canonical AbortRequest cannot target a different tuple even if the cached bytes hash is changed'
Check ($script:driverWrites-eq$before-and$x.terminal_abort.roles.vehicle.attempts-eq0) 'mutated command consumes no OUT attempt'
$x=FailedCommitted;$c=Get-R19GrantReservationTerminalAbortCommand $x vehicle (Tick) '40000'
[byte[]]$wrongRole=New-R19GrantReservationFrame -Opcode AbortRequest -Role ground -ReaderSession 123 -SlotNonce $x.slot_nonce -BootId 200 -UsbEpoch 1 -GrantSession 661 -GrantCycle 3 -SlotToken 77 -Generation 1 -Version 3
$c.bytes=$wrongRole;$c.frame_base64=[Convert]::ToBase64String($wrongRole);$before=$script:driverWrites
Reject {Invoke-R19ReservationTerminalAbortWrite $x $c {$script:now.ToString()} {param($Bytes)$script:driverWrites++;return 66}} 'AbortRequest wire role must equal selected physical command role'
Check ($script:driverWrites-eq$before-and$x.terminal_abort.roles.vehicle.attempts-eq0) 'wrong wire role consumes zero OUT attempts'
$live=@{Execute=$true;GrantAgreementDiagnosticsEnabled=$true;GrantReservationStopDiagnostics=$true;GrantReservationDiagnostics=$true;GrantDiagnostics=$true;ParamListDiagnostics=$true;Mode='ExplicitHostArm';AuxReadinessDiagnostics=$true;DiagnosticUsbFailureDiagnostics=$true;ExecutionPermitPath='MUST-NOT-EXIST-OFFLINE-PERMIT'}
$script:forbiddenLiveCalls=0
foreach($forbidden in @('Get-CimInstance','Get-PnpDevice','Get-PnpDeviceProperty','Get-Process','Start-Process')){Set-Item -Path ('function:script:'+$forbidden) -Value {$script:forbiddenLiveCalls++;throw 'FORBIDDEN_LIVE_CALL'}}
$liveError='';try{&$capture @live}catch{$liveError=$_.Exception.Message}
Check ($liveError-ceq'All explicit diagnostic paths are required') 'unpackaged agreement remains rejected before permit read, claim or device access'
Check ($script:forbiddenLiveCalls-eq0-and-not(Test-Path -LiteralPath ($live.ExecutionPermitPath+'.consumed'))) 'missing trusted live paths make zero process/device calls and consume zero permits'
Write-Output ('AGREEMENT_WORKFLOW PASS checks='+$script:checks+' hardware_interaction=false')
