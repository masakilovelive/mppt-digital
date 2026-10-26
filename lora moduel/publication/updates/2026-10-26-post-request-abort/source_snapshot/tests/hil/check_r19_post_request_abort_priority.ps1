[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent(Split-Path -Parent $PSScriptRoot)}
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_wire.ps1')
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_workflow.ps1')
. (Join-Path $RepoRoot 'tools/r19_param_list_diagnostics.ps1')
. (Join-Path $RepoRoot 'tools/r19_timed_path_acquisition.ps1') -ImportOnly
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'tools/run_r19_timed_path_capture.ps1'),[ref]$tokens,[ref]$errors)
$script:checks=0;$script:now=10L;$script:writes=[Collections.Generic.List[object]]::new();$script:normal=0
function Check([bool]$Value,[string]$Name){$script:checks++;if(-not$Value){throw ('FAIL '+$Name)}}
function Reject([scriptblock]$Body,[string]$Name){$failed=$false;try{&$Body|Out-Null}catch{$failed=$true};Check $failed $Name}
Check (@($errors).Count-eq0) 'Actual capture parses'
foreach($f in @($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]})){. ([scriptblock]::Create($f.Extent.Text))}
foreach($name in @('Get-CimInstance','Get-PnpDevice','Get-PnpDeviceProperty','Get-Process','Start-Process','Get-WmiObject')){Set-Item ('function:script:'+$name) {throw 'FORBIDDEN_OFFLINE_OPERATION'}}
function Tick{$script:now++;$script:now.ToString()}
$nonce=[Convert]::ToUInt64('521B000000000001',16).ToString()
function Frame($State,[string]$Opcode,[string]$Role,[uint64]$DeviceMs=100){
  $a=@{Opcode=$Opcode;Role=$Role;ReaderSession=123;SlotNonce=$State.slot_nonce;BootId=$(if($Role-ceq'ground'){100}else{200});UsbEpoch=1;DeviceMs=$DeviceMs;Version=3}
  if($Opcode-ceq'HelloReply'){$a.GrantSession=661;$a.GrantCycle=2}else{$a.GrantSession=661;$a.GrantCycle=3;$a.SlotToken=77;$a.Generation=1}
  return ,(New-R19GrantReservationFrame @a)
}
function Observe($State,[string]$Opcode,[string]$Role,[uint64]$DeviceMs=100){$t=Tick;Add-R19GrantReservationObservation $State $Role (Frame $State $Opcode $Role $DeviceMs) $t $t 0}
function NextWrite($State){$c=Get-R19GrantReservationNextCommand $State (Tick);$null=Invoke-R19ReservationPrivateWrite $State $c {Tick} {param([byte[]]$Bytes)return [int]$Bytes.Length}}
function Committed([bool]$Attempt=$true){
  $script:now=10L;$script:writes.Clear();$script:normal=0
  $s=New-R19GrantReservationWorkflow -CandidateId SYNTHETIC-ABORT-PRIORITY -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession 123 -SlotNonce $nonce -ClockDomainId fixture -Frequency 1000 -StartTicks 0 -CancellationEnabled $true -AgreementEnabled $true
  Set-R19GrantReservationPrerequisites $s $true $true $true $true (Tick)
  NextWrite $s;NextWrite $s;Observe $s HelloReply ground;Observe $s HelloReply vehicle;NextWrite $s;Observe $s Prepared vehicle
  NextWrite $s;NextWrite $s;NextWrite $s;Observe $s Bound ground;NextWrite $s;Observe $s CommitAck vehicle 110;NextWrite $s;Observe $s CommitAck ground 120
  $s.measurement_start_ticks='1000'
  if($Attempt){Begin-R19GrantReservationParamWrite $s ([byte[]]@(253,2,0,0,99,255,190,21,0,0,1,1,213,7)) (Tick);Set-R19GrantReservationParamWriteResult $s 14 (Tick);Observe $s GroundHeld ground 125}
  return $s
}
function NativeRole($State,[string]$Role,[byte[]]$Data=([byte[]]@())){
  $id='SYNTHETIC-'+$Role;$State.runtime_fault_monitors.$Role.reader_id=$id
  $reader=[pscustomobject]@{data=$Data;poll_calls=0;polled=$false;Stopped=$false;Overflow=$false;Failure=''}
  $reader|Add-Member ScriptMethod GetSnapshot {[pscustomobject]@{Stopped=$this.Stopped;Overflow=$this.Overflow;Failure=$this.Failure;ByteCount=$this.data.Length;Blocks=$(if($this.data.Length){@([pscustomobject]@{Offset=0;Count=$this.data.Length;EndTicks=($script:now-1)})}else{@()})}}
  $reader|Add-Member ScriptMethod ReadSlice {param([int]$Offset,[int]$Count)[byte[]]$b=New-Object byte[] $Count;[Array]::Copy($this.data,$Offset,$b,0,$Count);return ,$b}
  $reader|Add-Member ScriptMethod GetStatus {[pscustomobject]@{Stopped=$this.Stopped;Overflow=$this.Overflow;Failure=$this.Failure;FirstReadBeginTicks=1;PendingByteCount=0;LastReadEndTicks=($script:now-1)}}
  $reader|Add-Member ScriptMethod PollBytes {param([int]$Count)$this.poll_calls++;if(-not$this.polled-and$this.data.Length){$this.polled=$true;return ,([pscustomobject]@{Offset=0;Data=$this.data;EndTicks=($script:now-1)})}}
  $port=[pscustomobject]@{role=$Role}
  $port|Add-Member ScriptMethod Write {param([byte[]]$Bytes,[int]$Offset,[int]$Count)$script:writes.Add([pscustomobject]@{role=$this.role;normal=$script:normal;ticks=$script:now;opcode=$Bytes[15]})}
  [pscustomobject]@{spec=[pscustomobject]@{role=$Role};reader=$reader;reader_id=$id;port=$port;workflow=[pscustomobject]@{reply_read_validated=$true};workflow_failure='offline readiness updates disabled';reservation_parser=(New-R19GrantReservationParser -AgreementEnabled $true);product_parser=$null;parser=$null;product_observations=[Collections.Generic.List[object]]::new();observations=[Collections.Generic.List[object]]::new()}
}
function Roles($State,[byte[]]$Vehicle=([byte[]]@())){@((NativeRole $State vehicle $Vehicle),(NativeRole $State ground))}
function AbortPriority($State,$Roles,[scriptblock]$Writer={param($Target,[byte[]]$Bytes)$script:writes.Add([pscustomobject]@{role=$Target.spec.role;normal=$script:normal;ticks=$script:now;opcode=$Bytes[15]});return [int]$Bytes.Length}){
  Invoke-R19CaptureReservationPriorityAbort -State $State -States $Roles -PreparationDeadlineTicks '15000' -MeasurementDeadlineTicks '41000' -NowTicks {Tick} -Writer $Writer
}
# A complete Withdrawn must not remain in the runtime monitor after its fail
# latch. No later native byte is required just to retire this parsed frame.
$s=Committed;$roles=Roles $s (Frame $s Withdrawn vehicle 130);$v=$roles[0]
try{Add-R19GrantReservationRuntimeBlock $s $v ([pscustomobject]@{Offset=0;Data=$v.reader.data;EndTicks=($script:now-1)}) (Tick)}catch{}
Check ($s.status-ceq'Failed'-and$s.failure-ceq'ATTEMPTED_ABORT_WITHDRAWN_AFTER_REQUEST') 'Actual prepeek latches post-request withdrawal'
Check ($s.runtime_fault_monitors.vehicle.buffer.Count-eq0-and$s.runtime_fault_monitors.vehicle.buffer_raw_offset-eq66) 'Complete withdrawn frame is retired even when its first-failure transition throws'
Check ($null-ne(Get-Command Invoke-R19CaptureReservationPriorityAbort -ErrorAction SilentlyContinue)) 'Priority cleanup integration exists'
$failure=$s.failure;$originalT0=$s.param_write_started_ticks
$n=AbortPriority $s $roles
Check ($n-eq2-and($script:writes.role-join',')-ceq'vehicle,ground') 'Both Abort OUTs precede any ACK, PollBytes or normal product processing'
Check (@($script:writes|Where-Object{$_.opcode-ne21-or$_.normal-ne0}).Count-eq0-and$roles[0].reader.poll_calls-eq0-and$roles[1].reader.poll_calls-eq0) 'Priority path sends only typed Abort and never consumes PollBytes'
Check ($s.status-ceq'Failed'-and$s.failure-ceq$failure-and$s.param_attempts-eq1-and$s.param_write_started_ticks-ceq$originalT0-and$s.prepare_deadline_ticks-ceq'15000'-and$s.terminal_abort.capture_deadline_ticks-ceq'41000') 'First cause, one PARAM and original deadlines stay fixed'
Check ((AbortPriority $s $roles)-eq0-and$script:writes.Count-eq2) 'Missing ACK never retries a role'
Reject {Get-R19GrantReservationNextCommand $s (Tick)} 'Ordinary failed command gate remains closed'
Reject {Begin-R19GrantReservationParamWrite $s ([byte[]]@(253,2,0,0,99,255,190,21,0,0,1,1,213,7)) (Tick)} 'Cleanup cannot reissue PARAM'
# A partial Vehicle AbortAck arriving immediately after its OUT must not gate
# the independent Ground Abort OUT on completion of that ACK.
$s=Committed;$roles=Roles $s;try{Observe $s Withdrawn vehicle 130}catch{}
$n=AbortPriority $s $roles -Writer {param($Target,[byte[]]$Bytes)$script:writes.Add([pscustomobject]@{role=$Target.spec.role});if($Target.spec.role-ceq'vehicle'){[byte[]]$ack=Frame $s AbortAck vehicle 140;$Target.reader.data=[byte[]]$ack[0..31]};return [int]$Bytes.Length}
Check ($n-eq2-and($script:writes.role-join',')-ceq'vehicle,ground'-and$null-eq$s.terminal_abort.roles.vehicle.ack) 'A partial first-role ACK cannot delay second-role Abort'
Check ($s.runtime_fault_monitors.vehicle.buffer.Count-eq32-and$s.terminal_abort.phase-ceq'ABORT_UNCONFIRMED') 'Partial ACK remains unconfirmed evidence, never success'
# A same-reader runtime-failure frame closes ordinary writes but cannot close
# the separately constrained deauthorization-only path.
[byte[]]$runtimeBytes=for($i=0;$i-lt126;$i+=2){[Convert]::ToByte('FD33000014FEBEFD000002523139463A563A314237343A303030303030303030303030393942433A3030303130303031303030323A3030303030303031D694'.Substring($i,2),16)}
$s=Committed;$roles=Roles $s $runtimeBytes
Receive-R19GrantReservationControlPrefixes $s $roles {Tick}
Check ($s.status-ceq'Failed'-and$s.failure-ceq'RUNTIME_FAIL_CLOSED_VEHICLE'-and$null-ne$s.runtime_fault_first) 'Actual retained runtime frame is recorded before cleanup'
Check ((AbortPriority $s $roles)-eq2-and$s.failure-ceq'RUNTIME_FAIL_CLOSED_VEHICLE'-and$s.param_attempts-eq1) 'Only cleanup remains allowed after runtime fault; first fault and PARAM origin are unchanged'
Check (-not(Invoke-R19GrantReservationRuntimePreflight $s $roles (Tick))) 'Runtime-failed ordinary preflight remains denied after cleanup'
$s=Committed;$roles=Roles $s;try{Observe $s Withdrawn vehicle 130}catch{}
[byte[]]$groundAck=Frame $s AbortAck ground 140;$roles[1].reader.data=[byte[]]$groundAck[0..31]
Check ((AbortPriority $s $roles)-eq1-and($script:writes.role-join',')-ceq'vehicle'-and$s.terminal_abort.roles.ground.attempts-eq0) 'A partial TARGET prefix still blocks its own OUT without blocking independent peer cleanup'
foreach($kind in @('partial-out','writer-throw')){
  $s=Committed;$roles=Roles $s;try{Observe $s Withdrawn vehicle 130}catch{}
  $n=AbortPriority $s $roles -Writer {param($Target,[byte[]]$Bytes)$script:writes.Add([pscustomobject]@{role=$Target.spec.role});if($Target.spec.role-ceq'vehicle'){if($kind-ceq'writer-throw'){throw 'synthetic unknown prefix'};return 32};return [int]$Bytes.Length}
  Check ($n-eq2-and$s.terminal_abort.roles.vehicle.attempts-eq1-and-not$s.terminal_abort.roles.vehicle.write_success-and$s.terminal_abort.roles.ground.write_success) ('Unknown first-role OUT is not retried and does not prevent peer retirement '+$kind)
  Check ((AbortPriority $s $roles)-eq0) ('One attempt per role remains bounded '+$kind)
}
foreach($kind in @('reader-stopped','reader-overflow','reader-id','command-capacity','capture-expired')){
  $s=Committed;$roles=Roles $s;try{Observe $s Withdrawn vehicle 130}catch{}
  switch($kind){'reader-stopped'{$roles[0].reader.Stopped=$true};'reader-overflow'{$roles[1].reader.Overflow=$true};'reader-id'{$roles[0].reader_id='changed'};'command-capacity'{while($s.commands.Count-lt24){$s.commands.Add([pscustomobject]@{role='vehicle';started_ticks=$null;write_success=$false})}};'capture-expired'{$script:now=41000}}
  try{$n=AbortPriority $s $roles}catch{$n=0}
  Check ($script:writes.Count-eq0-and$s.terminal_abort.roles.vehicle.attempts-eq0-and$s.terminal_abort.roles.ground.attempts-eq0) ('Unsafe cleanup proof causes zero OUT '+$kind)
}
$s=Committed;$roles=Roles $s;try{Observe $s Withdrawn vehicle 130}catch{}
$c=Get-R19GrantReservationTerminalAbortCommand $s vehicle (Tick) '41000'
Reject {Invoke-R19ReservationTerminalAbortWrite $s $c {Tick} {param($Bytes)$script:writes.Add($Bytes);return 66} -BeforeWrite {$s.prepared.generation='2';return $true}} 'Tuple is revalidated after the last preflight callback'
Check ($script:writes.Count-eq0-and$s.terminal_abort.roles.vehicle.attempts-eq0) 'Preflight tuple mutation cannot become an OUT attempt'
# Before PARAM, both agreement tuples must still be the prepared tuple.
$s=Committed $false;$s.commit_vehicle.generation='2'
Check (-not(Test-R19GrantReservationRequestAllowed $s (Tick))) 'Final PARAM gate rejects an obsolete committed tuple'
$s=Committed $false;$roles=Roles $s (Frame $s Withdrawn vehicle 130)
$allowed=Invoke-R19GrantReservationRuntimePreflight $s $roles (Tick) BeforeParam -NowTicksProvider {Tick}
Check (-not$allowed-and$s.cancelling-and$s.param_attempts-eq0) 'Pending pre-PARAM withdrawal closes final request gate without consuming PARAM'
# Execute the actual loop body, not a hand-written ordering surrogate. Normal
# frame analyses advance a synthetic clock by500ms each, proving cleanup order.
$loops=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.WhileStatementAst]-and$n.Extent.Text.Contains('Invoke-R19CaptureReservationControlPump')-and$n.Extent.Text.Contains('Add-R19TimedPathHeartbeatBytes')},$true))
Check ($loops.Count-eq1) 'One actual capture observation loop extracted'
function Add-R19TimedPathHeartbeatBytes {$script:normal++;$script:now+=500}
function Add-R19TimedPathPrivateBytes {$script:normal++;$script:now+=500}
function Start-Sleep {param($Milliseconds)}
$reservationWorkflow=Committed;$roleArray=Roles $reservationWorkflow (Frame $reservationWorkflow Withdrawn vehicle 130)
$states=[Collections.Generic.List[object]]::new();foreach($r in $roleArray){$states.Add($r)}
$GrantReservationDiagnostics=$true;$GrantAgreementDiagnostics=$true;$ParamListDiagnostics=$false;$DiagnosticUsbFailureDiagnostics=$false;$readComparisonPlan=[pscustomobject]@{enabled=$false};$measurementStart='1000';$preparationDeadlineTicks='15000';$deadline=[Numerics.BigInteger]41000;$serialWrites=0;$domain='fixture';$frequency='1000';$clock=[pscustomobject]@{}
$clock|Add-Member ScriptProperty ElapsedTicks {$script:now}
. ([scriptblock]::Create($loops[0].Body.Extent.Text.Trim().Substring(1,$loops[0].Body.Extent.Text.Trim().Length-2)))
Check ($script:writes.Count-eq2-and@($script:writes|Where-Object{$_.normal-ne0}).Count-eq0) 'Actual loop sends both Abort OUTs before slow HB/private analysis'
Check ($script:normal-ge2-and$serialWrites-eq2-and$reservationWorkflow.param_attempts-eq1) 'Normal raw consumers still run afterwards and physical attempt count remains exact'
if($OutputDirectory){[void][IO.Directory]::CreateDirectory($OutputDirectory);[IO.File]::WriteAllText((Join-Path $OutputDirectory 'summary.json'),([pscustomobject]@{schema='r19-post-request-abort-priority-test-v1';result='PASS';checks=$script:checks;hardware_interaction=$false;synthetic_fixture=$true;timing_guarantee=$false}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
Write-Output ('POST_REQUEST_ABORT_PRIORITY PASS checks='+$script:checks+' hardware_interaction=false timing_guarantee=false')
