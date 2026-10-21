[CmdletBinding()]
param([string]$RepoRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
function Assert-Condition([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
$helper=Join-Path $repo 'tools/r19_continuous_reader.cs'
Assert-Condition (Test-Path -LiteralPath $helper) 'Missing continuous read owner; identity must not stop/join or transfer serial Read ownership.'
$fixture=@'
namespace VcLora.R19 {
  public sealed class FakeContinuousSource : IStartupReadSource {
    readonly object gate = new object();
    readonly System.Collections.Generic.Queue<byte> bytes = new System.Collections.Generic.Queue<byte>();
    public int Calls, Closes, MaximumRead = 8192, MaximumConcurrentReads;
    public bool Fail, BlockUntilClose, BlockUntilFeed, InvalidCount, ReturnZero;
    int active; bool closed;
    public int BytesToRead { get { lock(gate) return bytes.Count; } }
    public void Feed(byte[] data) { lock(gate) { foreach(byte b in data) bytes.Enqueue(b); System.Threading.Monitor.PulseAll(gate); } }
    public int Read(byte[] buffer,int offset,int count) {
      lock(gate) {
        Calls++; active++; MaximumConcurrentReads=System.Math.Max(MaximumConcurrentReads,active);
        System.Threading.Monitor.PulseAll(gate);
        try {
          if(Fail) throw new System.IO.IOException("injected read failure");
          if(InvalidCount) return count+1;
          if(ReturnZero) return 0;
          while(BlockUntilClose && !closed) System.Threading.Monitor.Wait(gate,20);
          while(BlockUntilFeed && bytes.Count==0 && !closed) System.Threading.Monitor.Wait(gate,20);
          if(closed) throw new System.ObjectDisposedException("fixture source");
          if(bytes.Count==0) System.Threading.Monitor.Wait(gate,20);
          if(closed) throw new System.ObjectDisposedException("fixture source");
          if(bytes.Count==0) throw new System.TimeoutException();
          int n=System.Math.Min(count,System.Math.Min(MaximumRead,bytes.Count));
          for(int i=0;i<n;i++) buffer[offset+i]=bytes.Dequeue();
          return n;
        } finally { active--; }
      }
    }
    public void Close() { lock(gate) { Closes++;closed=true;System.Threading.Monitor.PulseAll(gate); } }
    public bool WaitCalls(int wanted,int milliseconds) {
      var timer=System.Diagnostics.Stopwatch.StartNew();
      lock(gate) { while(Calls<wanted && timer.ElapsedMilliseconds<milliseconds) System.Threading.Monitor.Wait(gate,5);return Calls>=wanted; }
    }
  }
}
'@
$startup=Join-Path $repo 'tools/r19_startup_reader.cs'
Add-Type -TypeDefinition (([IO.File]::ReadAllText($startup))+[Environment]::NewLine+([IO.File]::ReadAllText($helper))+[Environment]::NewLine+$fixture)
$script:count=0
function Pass([string]$Name){$script:count++;Write-Output "PASS $Name"}
function Wait-Bytes($Reader,[int]$Count){
  $timer=[Diagnostics.Stopwatch]::StartNew()
  while($Reader.GetSnapshot().ByteCount-lt$Count-and$timer.ElapsedMilliseconds-lt1500){[Threading.Thread]::Sleep(1)}
  Assert-Condition ($Reader.GetSnapshot().ByteCount-ge$Count) "Reader did not retain $Count bytes."
}
function Join-BlockBytes($Blocks){
  $bytes=[Collections.Generic.List[byte]]::new()
  foreach($block in $Blocks){$bytes.AddRange([byte[]]$block.Data)}
  return ,$bytes.ToArray()
}
$clock=[Diagnostics.Stopwatch]::StartNew()
$v=[VcLora.R19.FakeContinuousSource]::new();$g=[VcLora.R19.FakeContinuousSource]::new()
$vr=[VcLora.R19.ContinuousReader]::new($v,$clock,1048576,4096)
$gr=[VcLora.R19.ContinuousReader]::new($g,$clock,1048576,4096)
try {
  Assert-Condition ($vr.WaitReady(1000)-and$gr.WaitReady(1000)) 'Workers must warm and wait before source Open/Arm.'
  Assert-Condition ($v.Calls-eq0-and$g.Calls-eq0) 'Unarmed worker accessed source.'
  Pass 'pre_open_warmup_has_no_serial_access'
  $vr.Arm($clock.ElapsedTicks)
  Assert-Condition ($v.WaitCalls(1,1000)) 'Empty queue must issue actual Read, not poll BytesToRead.'
  [Threading.Thread]::Sleep(120)
  Assert-Condition ($v.Calls-ge4-and$g.Calls-eq0) 'Slow second Open suspended first role or read unopened second role.'
  $gr.Arm($clock.ElapsedTicks);Assert-Condition ($g.WaitCalls(1,1000)) 'Second role did not Read.'
  Pass 'empty_read_and_delayed_second_open'
  $v.Feed([byte[]](1,2,3));$g.Feed([byte[]](9,8));Wait-Bytes $vr 3;Wait-Bytes $gr 2
  $before=$v.Calls
  [void]$vr.MarkPhase('IDENTITY_VERIFIED');[void]$gr.MarkPhase('IDENTITY_VERIFIED')
  [void]$vr.MarkPhase('LIVE');[void]$gr.MarkPhase('LIVE')
  [Threading.Thread]::Sleep(120)
  Assert-Condition ($v.Calls-gt$before-and-not$vr.GetSnapshot().Stopped-and$v.Closes-eq0) 'Identity/LIVE marker interrupted read ownership.'
  Pass 'identity_to_live_marker_has_no_stop_join_or_close'
  $s=$vr.GetSnapshot();Assert-Condition ($s.Timeouts-gt0-and$s.Failure-ceq''-and$s.FirstReadBeginTicks-ge$s.OpenReturnTicks) 'Live snapshot lacks timeout or QPC evidence.'
  Assert-Condition ($s.MaximumServiceGapTicks-ge0-and$s.PendingByteCount-eq3-and$s.ConsumedByteCount-eq0) 'Live snapshot accounting invalid.'
  Pass 'snapshots_while_pending_read_are_safe'
  $status=$vr.GetStatus()
  Assert-Condition ($status.Blocks.Count-eq0-and$status.Phases.Count-eq0-and$status.ByteCount-eq$s.ByteCount) 'Hot-loop status materializes full historical records.'
  Assert-Condition (($status.MaximumGapEndTicks-$status.MaximumGapStartTicks)-eq$status.MaximumServiceGapTicks) 'Maximum gap cannot be located on native QPC.'
  Pass 'constant_cost_status_and_locatable_native_read_gap'
  $blocks=@($vr.PollBytes(2));Assert-Condition (([BitConverter]::ToString((Join-BlockBytes $blocks)))-ceq'01-02') 'Byte budget not exact.'
  $tail=@($vr.PollBytes(1));Assert-Condition (([BitConverter]::ToString((Join-BlockBytes $tail)))-ceq'03') 'Unconsumed tail was dropped or duplicated.'
  Assert-Condition ($blocks[0].Batch-eq$tail[0].Batch-and$blocks[0].BeginTicks-eq$tail[0].BeginTicks-and$tail[0].Offset-eq2) 'Native metadata was fabricated for partial delivery.'
  Assert-Condition (@($vr.PollBytes(8)).Count-eq0-and$vr.GetSnapshot().ConsumedByteCount-eq3) 'Consumed bytes delivered twice.'
  Pass 'bounded_partial_poll_exactly_once_preserves_native_batch'
  $blocks[0].Data[0]=99
  Assert-Condition (([BitConverter]::ToString($vr.GetBytes()))-ceq'01-02-03') 'Consumer mutated immutable retained evidence.'
  $v.Feed([byte[]](4,5,6,7));Wait-Bytes $vr 7
  [void]$vr.MarkPhase('TAIL')
  $v.Feed([byte[]](8,9));Wait-Bytes $vr 9
  $live=@($vr.PollBytes(64))
  Assert-Condition (([BitConverter]::ToString((Join-BlockBytes $live)))-ceq'04-05-06-07-08-09') 'LIVE/TAIL boundary changed byte order.'
  Assert-Condition (([BitConverter]::ToString($vr.GetBytes()))-ceq'01-02-03-04-05-06-07-08-09'-and$v.MaximumConcurrentReads-eq1) 'Evidence missing or overlapping Read owners.'
  Pass 'one_owner_through_live_and_tail_keeps_full_raw'
  Assert-Condition ($vr.Stop(1000)-and$gr.Stop(1000)-and$v.Closes-eq0-and$g.Closes-eq0) 'Normal finite stop must not Close source.'
  Pass 'normal_stop_uses_read_timeout_without_close'
} finally {[void]$vr.Stop(1000);[void]$gr.Stop(1000)}

$source=[VcLora.R19.FakeContinuousSource]::new();$source.MaximumRead=2;$source.Feed([byte[]](10,11,12))
$reader=[VcLora.R19.ContinuousReader]::new($source,$clock,128,32)
try {
  [void]$reader.WaitReady(1000);$reader.Arm();Wait-Bytes $reader 3
  $source.Feed([byte[]](13,14));Wait-Bytes $reader 5
  $all=@($reader.PollBytes(128));$s=$reader.GetSnapshot()
  Assert-Condition ($s.InitialBytes-eq3-and($all|Measure-Object -Property InitialByteCount -Sum).Sum-eq3) 'Initial queue watermark classification lost.'
  Assert-Condition ($s.Blocks.Count-ge3-and$s.Blocks[0].RequestedCount-ge$s.Blocks[0].Count-and$s.Blocks[0].EndTicks-ge$s.Blocks[0].BeginTicks) 'Read metadata invalid.'
  Assert-Condition (([BitConverter]::ToString((Join-BlockBytes $all)))-ceq'0A-0B-0C-0D-0E') 'Partial source reads changed bytes.'
  Pass 'initial_watermark_and_partial_native_reads'
  $bad=$false;try{$reader.Arm()}catch{$bad=$true};Assert-Condition $bad 'Second Arm must fail.'
  $bad=$false;try{[void]$reader.PollBytes(0)}catch{$bad=$true};Assert-Condition $bad 'Zero poll budget must fail explicitly.'
  Pass 'invalid_rearm_and_budget_fail_explicitly'
} finally {[void]$reader.Stop(1000)}

$source=[VcLora.R19.FakeContinuousSource]::new();$source.BlockUntilFeed=$true
$reader=[VcLora.R19.ContinuousReader]::new($source,$clock,128,32)
try {
  [void]$reader.WaitReady(1000);$reader.Arm();Assert-Condition ($source.WaitCalls(1,1000)) 'Boundary read not started.'
  [void]$reader.MarkPhase('LIVE');$source.Feed([byte[]](21,22,23));Wait-Bytes $reader 3
  $parts=@($reader.PollBytes(2));$rest=@($reader.PollBytes(2))
  Assert-Condition ($parts[0].BeginPhase-ceq'STARTUP'-and$parts[0].EndPhase-ceq'LIVE'-and
    $rest[0].BeginPhaseIndex-eq$parts[0].BeginPhaseIndex-and$rest[0].EndPhaseIndex-eq$parts[0].EndPhaseIndex) 'Read spanning identity marker was assigned a fabricated single phase.'
  Pass 'inflight_read_preserves_both_phase_boundaries'
} finally {[void]$reader.CloseAndStop(1000)}

$source=[VcLora.R19.FakeContinuousSource]::new();$source.MaximumRead=37
$reader=[VcLora.R19.ContinuousReader]::new($source,$clock,12000,1024)
$expected=[byte[]]::new(10000);for($i=0;$i-lt$expected.Length;$i++){$expected[$i]=[byte]($i%256)}
$received=[Collections.Generic.List[byte]]::new()
try {
  [void]$reader.WaitReady(1000);$reader.Arm();$source.Feed($expected)
  $timer=[Diagnostics.Stopwatch]::StartNew()
  while($received.Count-lt$expected.Length-and$timer.ElapsedMilliseconds-lt3000){
    $chunks=@($reader.PollBytes(63))
    $n=0;foreach($chunk in $chunks){$received.AddRange([byte[]]$chunk.Data);$n+=$chunk.Count}
    Assert-Condition ($n-le63) 'Stream poll exceeded byte service budget.'
    $status=$reader.GetStatus();Assert-Condition ($status.Failure-ceq''-and$status.PendingByteCount-ge0) 'Live status lost accounting during append.'
    if($chunks.Count-eq0){[Threading.Thread]::Sleep(1)}
  }
  Assert-Condition ($received.Count-eq10000-and([Convert]::ToBase64String($received.ToArray()))-ceq([Convert]::ToBase64String($expected))) 'Long stream bytes lost, duplicated or reordered.'
  Assert-Condition (([Convert]::ToBase64String($reader.GetBytes()))-ceq([Convert]::ToBase64String($expected))-and
    ([BitConverter]::ToString($reader.ReadSlice(9997,3)))-ceq'0D-0E-0F') 'Evidence export differs from consumed stream.'
  Assert-Condition ($reader.GetStatus().ConsumedByteCount-eq10000-and$source.MaximumConcurrentReads-eq1) 'Long stream ownership/cursor invalid.'
  Pass 'ten_thousand_bytes_budgeted_delivery_and_complete_evidence'
} finally {[void]$reader.Stop(1000)}

foreach($fault in @('read','invalid','capacity','blocks','phases')) {
  $source=[VcLora.R19.FakeContinuousSource]::new();$source.MaximumRead=2
  if($fault-ceq'read'){$source.Fail=$true}elseif($fault-ceq'invalid'){$source.InvalidCount=$true}else{$source.Feed([byte[]](1,2,3,4,5,6))}
  $capacity=if($fault-ceq'capacity'){4}else{128};$blocks=if($fault-ceq'blocks'){1}else{32}
  $reader=[VcLora.R19.ContinuousReader]::new($source,$clock,$capacity,$blocks,2)
  try {
    [void]$reader.WaitReady(1000);$reader.Arm()
    if($fault-ceq'phases'){[void]$reader.MarkPhase('LIVE');$bad=$false;try{[void]$reader.MarkPhase('TAIL')}catch{$bad=$true};Assert-Condition $bad 'Phase overflow not explicit.'}
    [Threading.Thread]::Sleep(60);Assert-Condition ($reader.Stop(1000)) 'Fault worker did not stop.'
    $s=$reader.GetSnapshot();Assert-Condition (-not[string]::IsNullOrEmpty($s.Failure)) "Fault $fault silently passed."
    Assert-Condition ($reader.GetBytes().Length-eq$s.ByteCount-and$s.PendingByteCount-eq($s.ByteCount-$s.ConsumedByteCount)) 'Fault discarded evidence or accounting.'
    if($fault-in@('capacity','blocks')){Assert-Condition ($s.Overflow-and$s.ByteCount-gt0) 'Capacity exhausted without explicit overflow and retained prefix.'}
    if($fault-eq'read'){Assert-Condition ($s.ReadErrors-eq1) 'Unexpected read error not counted.'}
    Pass ($fault+'_fails_closed_with_retained_evidence')
  } finally {[void]$reader.Stop(1000)}
}

$source=[VcLora.R19.FakeContinuousSource]::new();$source.BlockUntilClose=$true
$reader=[VcLora.R19.ContinuousReader]::new($source,$clock,128,32)
try {
  [void]$reader.WaitReady(1000);$reader.Arm();[void]$source.WaitCalls(1,1000)
  Assert-Condition (-not$reader.Stop(20)-and$source.Closes-eq0) 'Stop must report unjoined owner without silently closing.'
  Assert-Condition ($reader.CloseAndStop(1000)-and$source.Closes-eq1-and$reader.GetSnapshot().Closed) 'Cleanup Close fallback did not terminate blocking read.'
  Assert-Condition ($reader.GetSnapshot().Failure-ceq'') 'Expected cleanup cancellation became product read failure.'
  Pass 'blocked_read_close_fallback_is_cleanup_only_and_finite'
} finally {[void]$reader.CloseAndStop(1000)}
$source=[VcLora.R19.FakeContinuousSource]::new()
$reader=[VcLora.R19.ContinuousReader]::new($source,$clock,128,32)
[void]$reader.WaitReady(1000);Assert-Condition ($reader.Stop(1000)-and$source.Calls-eq0) 'Unarmed worker cannot stop without accessing source.'
Pass 'unarmed_stop_has_no_source_access'
$source=[VcLora.R19.FakeContinuousSource]::new();$source.ReturnZero=$true
$reader=[VcLora.R19.ContinuousReader]::new($source,$clock,128,32)
try {
  [void]$reader.WaitReady(1000);$reader.Arm();Assert-Condition ($source.WaitCalls(3,1000)) 'Zero-read source stalled.'
  Assert-Condition ($reader.GetSnapshot().ZeroReads-gt0-and$reader.GetSnapshot().Failure-ceq'') 'Zero reads treated as byte evidence or failure.'
  Pass 'zero_read_is_explicit_and_not_payload'
} finally {[void]$reader.Stop(1000)}
Write-Output "Continuous reader offline contract PASS tests=$script:count; memory-only; no COM, PnP, process inventory, native hardware or network; not a USB timing or parser fairness proof."
