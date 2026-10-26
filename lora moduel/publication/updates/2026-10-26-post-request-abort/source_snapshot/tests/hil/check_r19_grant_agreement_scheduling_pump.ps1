[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='', [switch]$MeasureWallClock)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent(Split-Path -Parent $PSScriptRoot)}
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_wire.ps1')
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_workflow.ps1')
$script:checks=0;$script:now=10L;$script:writes=[Collections.Generic.List[string]]::new();$script:preflights=0
function Check([bool]$Value,[string]$Name){$script:checks++;if(-not$Value){throw ('FAIL '+$Name)}}
function Reject([scriptblock]$Body,[string]$Name){$failed=$false;try{&$Body|Out-Null}catch{$failed=$true};Check $failed $Name}
foreach($name in @('Invoke-R19GrantReservationControlPump','Add-R19GrantReservationDeliveredBlock','Receive-R19GrantReservationControlPrefixes')){
  Check ($null-ne(Get-Command $name -ErrorAction SilentlyContinue)) ('Bounded scheduling definition exists '+$name)
}
foreach($name in @('Get-CimInstance','Get-PnpDevice','Get-Process','Start-Process')){Set-Item -Path ('function:script:'+$name) -Value {throw 'FORBIDDEN_OFFLINE_OPERATION'}}
$nonce=[Convert]::ToUInt64('521B000000000001',16).ToString()
function Tick{$script:now++;return $script:now.ToString()}
function Frame($State,[string]$Op,[string]$Role,[uint64]$DeviceMs=100){
  $a=@{Opcode=$Op;Role=$Role;ReaderSession=123;SlotNonce=$State.slot_nonce;BootId=$(if($Role-ceq'ground'){100}else{200});UsbEpoch=1;DeviceMs=$DeviceMs;Version=3}
  if($Op-ceq'HelloReply'){$a.GrantSession=661;$a.GrantCycle=2}
  else{$a.GrantSession=661;$a.GrantCycle=3;$a.SlotToken=77;$a.Generation=1}
  return ,(New-R19GrantReservationFrame @a)
}
function Observe($State,[string]$Op,[string]$Role,[uint64]$DeviceMs=100){$t=Tick;Add-R19GrantReservationObservation $State $Role (Frame $State $Op $Role $DeviceMs) $t $t 0}
function NextWrite($State,[string]$Expected){
  $c=Get-R19GrantReservationNextCommand $State (Tick);Check ($c.kind-ceq$Expected) ('Fixture '+$Expected)
  $null=Invoke-R19ReservationPrivateWrite $State $c {Tick} {param([byte[]]$Bytes)return [int]$Bytes.Length}
}
function PreparedFixture([bool]$ObservePrepared=$true){
  $script:now=10L;$script:writes.Clear();$script:preflights=0
  $s=New-R19GrantReservationWorkflow -CandidateId SYNTHETIC-PUMP -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession 123 -SlotNonce $nonce -ClockDomainId fixture -Frequency 1000 -StartTicks 0 -CancellationEnabled $true -AgreementEnabled $true
  Set-R19GrantReservationPrerequisites $s $true $true $true $true (Tick)
  NextWrite $s Helloground;NextWrite $s Hellovehicle;Observe $s HelloReply ground;Observe $s HelloReply vehicle;NextWrite $s PrepareVehicle
  if($ObservePrepared){Observe $s Prepared vehicle}
  return $s
}
function Pump($State,[scriptblock]$Drain={param($State)},[int]$MaximumCommands=8,[int]$MaximumMilliseconds=25,[scriptblock]$Preflight={param($State,$Command)$script:preflights++;return $true}){
  Invoke-R19GrantReservationControlPump -State $State -NowTicks {Tick} -Drain $Drain -BeforeWrite $Preflight -Writer {param($Command,[byte[]]$Bytes)$script:writes.Add($Command.kind);return [int]$Bytes.Length} -MaximumCommands $MaximumCommands -MaximumPumpMilliseconds $MaximumMilliseconds
}
$s=PreparedFixture;$originalDeadline=$s.prepare_deadline_ticks;$originalNonce=$s.slot_nonce
$p=Pump $s
Check (($script:writes-join',')-ceq'BindPeerVehicle,BindGround,BindPeerGround') 'Dependent-free Bind group advances in one bounded invocation'
Check ($p.commands_written-eq3-and$p.stop_reason-ceq'AWAIT_OBSERVATION'-and$script:preflights-eq3) 'Every Bind retains its own physical-write preflight'
Check ($s.slot_nonce-ceq$originalNonce-and$s.prepare_deadline_ticks-ceq$originalDeadline-and$s.maximum_commands-eq24-and$s.maximum_cancellations-eq1-and$s.maximum_rounds-eq2) 'Identity and original budgets stay fixed'
Observe $s Bound ground;$script:writes.Clear();$p=Pump $s
Check (($script:writes-join',')-ceq'CommitVehicle'-and$null-eq$s.commit_vehicle-and$null-eq$s.commit_ground-and$s.param_attempts-eq0) 'Vehicle Commit OUT still waits for actual ACK before Ground Commit or PARAM'
Observe $s CommitAck vehicle 110;$script:writes.Clear();$p=Pump $s
Check (($script:writes-join',')-ceq'CommitGround'-and$s.param_attempts-eq0) 'Ground Commit follows actual Vehicle ACK'
Observe $s CommitAck ground 120;$script:writes.Clear();$p=Pump $s
Check ($script:writes.Count-eq0-and(Test-R19GrantReservationRequestAllowed $s (Tick))) 'Pump never manufactures PARAM or skips bilateral ACKs'
[byte[]]$param=@(253,2,0,0,99,255,190,21,0,0,1,1,213,7)
Begin-R19GrantReservationParamWrite $s $param (Tick);Set-R19GrantReservationParamWriteResult $s 14 (Tick)
$p=Pump $s;Check ($p.commands_written-eq0) 'No Release before actual matching GroundHeld'
Observe $s GroundHeld ground 130;$script:writes.Clear();$p=Pump $s
Check (($script:writes-join',')-ceq'ReleaseVehicle'-and$s.param_attempts-eq1) 'Exactly one Release after one PARAM and actual Held'
$snapshot=Get-R19GrantReservationSnapshot $s
Check ($null-ne$snapshot.PSObject.Properties['control_pump_metrics']-and$snapshot.control_pump_metrics.invocations-ge6-and$snapshot.control_pump_metrics.total_commands_written-eq6-and$snapshot.control_pump_metrics.max_slice_elapsed_ticks-ne'0') 'Fixed-size pump counts and elapsed-PC-clock maximum survive snapshot'
Check ($null-ne$snapshot.PSObject.Properties['prepared_to_release_pc_timing']-and$snapshot.prepared_to_release_pc_timing.release_write_attempted-and-not$snapshot.prepared_to_release_pc_timing.mcu_hold_deadline_proven) 'Prepared native read to Release OUT timing is distinct from MCU hold proof'
Reject {Begin-R19GrantReservationParamWrite $s $param (Tick)} 'One-shot PARAM cannot be retried by pump'
$s=PreparedFixture;$p=Pump $s -MaximumCommands 1
Check ($p.commands_written-eq1-and$p.stop_reason-ceq'COMMAND_BUDGET') 'Hard iteration bound does not consume hidden command attempts'
$s=PreparedFixture;$p=Pump $s -Preflight {param($State,$Command)$State.write_preflight_pending=$true;return $false}
Check ($p.commands_written-eq0-and$p.stop_reason-ceq'PREFLIGHT_PENDING'-and$null-eq$s.pending_command.started_ticks-and$script:writes.Count-eq0) 'Unconsumed prefix keeps pending OUT physically unattempted'
$s=PreparedFixture;$p=Pump $s -Drain {param($State)$script:now+=30}
Check ($p.commands_written-eq0-and$p.stop_reason-ceq'TIME_BUDGET') 'Expired pump slice does not issue a new OUT'
$s=PreparedFixture;$p=Pump $s -Preflight {param($State,$Command)$script:now+=30;return $true}
Check ($p.commands_written-eq0-and$p.stop_reason-ceq'TIME_BUDGET'-and$null-eq$s.pending_command.started_ticks) 'Budget is rechecked after real preflight, before physical OUT attempt latch'
$s=PreparedFixture;Reject {Pump $s -Drain {param($State)Stop-R19GrantReservationWorkflow $State RUNTIME_FAIL_CLOSED_VEHICLE}} 'Drained runtime fault stops before first physical write'
Check ($script:writes.Count-eq0-and$s.param_attempts-eq0) 'Fault precedence preserves NOT_ATTEMPTED request'
Check ($s.control_pump_metrics.failed-eq1-and$s.control_pump_metrics.total_write_attempts-eq0) 'Fixed metrics retain a faulted slice without synthetic physical attempt'
$s=PreparedFixture;$script:now=15001;Reject {Pump $s} 'Original preparation deadline still expires in pump'
Check ($script:writes.Count-eq0) 'Expired preparation cannot send controls'
Check ($s.control_pump_metrics.failed-eq1) 'Preparation-expired slice is counted as failed without extending its clock'
$s=PreparedFixture;Reject {Invoke-R19GrantReservationControlPump -State $s -NowTicks {Tick} -Drain {param($State)} -BeforeWrite {param($State,$Command)return $true} -Writer {param($Command,[byte[]]$Bytes)$script:writes.Add($Command.kind);return 65} } 'Partial control write fails without retry'
Check ($script:writes.Count-eq1-and$s.status-ceq'Failed') 'Unknown prefix is not repaired by another command'
$s=PreparedFixture;$p=Pump $s -Preflight {param($State,$Command)Observe $State Withdrawn vehicle 105;$State.write_preflight_pending=$true;return $false}
Check ($script:writes.Count-eq0-and$s.cancelling-and$s.cancellation_count-eq1) 'Withdrawal before OUT revokes stale Bind and consumes only existing cancel budget'

function RoleState($State,[byte[]]$Data,[string]$Role='vehicle'){
  $reader=[pscustomobject]@{data=$Data;poll_calls=0;read_calls=0}
  $reader|Add-Member ScriptMethod GetSnapshot { [pscustomobject]@{Stopped=$false;Overflow=$false;Failure='';ByteCount=$this.data.Length;Blocks=$(if($this.data.Length){@([pscustomobject]@{Offset=0;Count=$this.data.Length;EndTicks='1000'})}else{@()})} }
  $reader|Add-Member ScriptMethod ReadSlice {param([int]$Offset,[int]$Count)$this.read_calls++;[byte[]]$result=New-Object byte[] $Count;[Array]::Copy($this.data,$Offset,$result,0,$Count);return ,$result}
  $reader|Add-Member ScriptMethod PollBytes {param([int]$Count)$this.poll_calls++;return ,([pscustomobject]@{Offset=0;Data=$this.data;EndTicks='1000'})}
  [pscustomobject]@{spec=[pscustomobject]@{role=$Role};reader_id=('SYNTHETIC-'+$Role);reader=$reader;workflow=[pscustomobject]@{reply_read_validated=$true};reservation_parser=(New-R19GrantReservationParser -AgreementEnabled $true)}
}
$s=PreparedFixture $false;$script:now=1001;$v=RoleState $s (Frame $s Prepared vehicle);$g=RoleState $s ([byte[]]@()) ground
Receive-R19GrantReservationControlPrefixes -State $s -States @($v,$g) -NowTicks {Tick}
Check ($null-ne$s.prepared-and$v.reservation_parser.next_raw_offset-eq66-and$v.reader.poll_calls-eq0) 'Priority prefix delivery uses immutable raw bytes without consuming normal PollBytes'
$normalBlock=$v.reader.PollBytes(8192)
Check ($normalBlock.Offset-eq0-and$normalBlock.Data.Length-eq66-and[BitConverter]::ToString($normalBlock.Data)-ceq[BitConverter]::ToString($v.reader.data)) 'Normal PARAM/product/private consumers retain the entire exact raw block after priority delivery'
Add-R19GrantReservationDeliveredBlock -State $s -RoleState $v -Block $normalBlock -NowTicks (Tick)
Check ($s.observations.Count-eq3-and$v.reservation_parser.accepted_frames-eq1) 'Later full normal delivery does not replay reservation ACKs'
$s=PreparedFixture $false;$script:now=1001;[byte[]]$bytes=Frame $s Prepared vehicle;$v=RoleState $s $bytes
Add-R19GrantReservationDeliveredBlock $s $v ([pscustomobject]@{Offset=0;Data=[byte[]]$bytes[0..31];EndTicks='1000'}) (Tick)
Check ($null-eq$s.prepared-and$v.reservation_parser.next_raw_offset-eq32) 'Partial prefix never becomes an observation'
Add-R19GrantReservationDeliveredBlock $s $v ([pscustomobject]@{Offset=0;Data=$bytes;EndTicks='1000'}) (Tick)
Check ($null-ne$s.prepared-and$v.reservation_parser.next_raw_offset-eq66-and$v.reservation_parser.accepted_frames-eq1) 'Overlapping retained block delivers only new suffix exactly once'
Reject {Add-R19GrantReservationDeliveredBlock $s $v ([pscustomobject]@{Offset=67;Data=[byte[]]@(1);EndTicks='1000'}) (Tick)} 'Raw prefix gap remains fatal'
$s=PreparedFixture $false;$script:now=1001;$v=RoleState $s (Frame $s Prepared vehicle);$g=RoleState $s (Frame $s Fault ground)
Reject {Pump $s -Drain {param($State)Receive-R19GrantReservationControlPrefixes $State @($v,$g) {Tick}}} 'Both native prefixes are drained before first control OUT'
Check ($script:writes.Count-eq0-and$s.status-ceq'Failed'-and$s.param_attempts-eq0) 'A peer fault wins even when Prepared was earlier in the other role prefix'

$capture=Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'tools/run_r19_timed_path_capture.ps1')
Check ($capture.Contains('Invoke-R19GrantReservationControlPump')-and$capture.Contains('Receive-R19GrantReservationControlPrefixes')) 'Actual capture invokes bounded priority pump and native prefix drain'
Check ($capture.Contains('Add-R19GrantReservationDeliveredBlock')-and$capture.Contains('Add-R19ParamListBytes')-and$capture.Contains('Add-R19TimedPathHeartbeatBytes')-and$capture.Contains('Add-R19TimedPathPrivateBytes')) 'Normal PollBytes still feeds reservation, PARAM, product and private ledgers'
Check ($capture.Contains('Start-R19ReservationMeasurement')-and$capture.Contains('Invoke-R19ParamListRequest')) 'Measurement and one-shot PARAM lifecycle remains explicit'
if($MeasureWallClock){
  function MeasurePump([int]$Maximum){
    $state=PreparedFixture;$v=RoleState $state ([byte[]]@());$g=RoleState $state ([byte[]]@()) ground;$roles=@($v,$g)
    $clock=[Diagnostics.Stopwatch]::StartNew();$state.frequency=[Diagnostics.Stopwatch]::Frequency.ToString();$state.last_ticks='0';$state.prepare_deadline_ticks=([Numerics.BigInteger]15*[Diagnostics.Stopwatch]::Frequency).ToString()
    $invocations=0
    while($script:writes.Count-lt3-and$invocations-lt24){
      $invocations++
      $null=Invoke-R19GrantReservationControlPump -State $state -NowTicks {[string]$clock.ElapsedTicks} -MaximumCommands $Maximum -Drain {param($s)Receive-R19GrantReservationControlPrefixes $s $roles {[string]$clock.ElapsedTicks}} -BeforeWrite {param($s,$command)Invoke-R19GrantReservationRuntimePreflight $s $roles ([string]$clock.ElapsedTicks) BeforeSyntheticBind -NowTicksProvider {[string]$clock.ElapsedTicks}} -Writer {param($command,[byte[]]$bytes)$script:writes.Add($command.kind);return [int]$bytes.Length}
    }
    $clock.Stop()
    [pscustomobject]@{maximum_commands=$Maximum;invocations=$invocations;physical_writer_callbacks=$script:writes.Count;elapsed_ms=$clock.Elapsed.TotalMilliseconds;complete=($script:writes.Count-eq3)}
  }
  $null=MeasurePump 1;$null=MeasurePump 8
  $samples=@(foreach($i in 1..7){MeasurePump 1;MeasurePump 8})
  $single=@($samples|Where-Object{$_.maximum_commands-eq1}|ForEach-Object{$_.elapsed_ms}|Sort-Object)
  $bounded=@($samples|Where-Object{$_.maximum_commands-eq8}|ForEach-Object{$_.elapsed_ms}|Sort-Object)
  Check (@($samples|Where-Object{-not$_.complete}).Count-eq0) 'Real-clock synthetic snapshot/preflight benchmark completes all three Bind writes'
  $benchmark=[pscustomobject]@{schema='vc-lora-r19-control-pump-synthetic-wallclock-v1';powershell=$PSVersionTable.PSVersion.ToString();samples=$samples;single_command_median_ms=$single[3];bounded_pump_median_ms=$bounded[3];hardware_interaction=$false;timing_guarantee=$false;scope='Same actual workflow and native-prefix/preflight functions with empty fake snapshots and three independent Bind writes. This excludes unrelated full capture-loop parsing and real USB/MCU ACK latency; it is not a live deadline proof.'}
  if($OutputDirectory){New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null;[IO.File]::WriteAllText((Join-Path $OutputDirectory 'wallclock.json'),($benchmark|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
  Write-Output ('SYNTHETIC_WALLCLOCK single_median_ms='+$single[3]+' bounded_median_ms='+$bounded[3])
}
if($OutputDirectory){New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null;[IO.File]::WriteAllText((Join-Path $OutputDirectory 'summary.json'),([pscustomobject]@{result='PASS';checks=$script:checks;hardware_interaction=$false;timing_guarantee=$false;synthetic_fixture=$true}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
Write-Output ('SCHEDULING_PUMP PASS checks='+$script:checks)
