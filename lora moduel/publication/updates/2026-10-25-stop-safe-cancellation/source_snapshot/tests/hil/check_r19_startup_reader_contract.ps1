[CmdletBinding()]
param([string]$RepoRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
function Assert-Condition([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}
$helper=Join-Path $repo 'tools/r19_startup_reader.cs'
Assert-Condition (Test-Path -LiteralPath $helper) 'Missing bounded pre-open-warmed startup reader.'
$fixture=@'
namespace VcLora.R19 {
  // Test-only completion witness: wait for the injected fault to terminate
  // the worker naturally, rather than cancelling it after an arbitrary sleep.
  // It neither modifies the reader nor calls Stop/Close to manufacture exit.
  public static class StartupReaderTestWitness {
    public static bool WaitExited(StartupReader reader, int timeout) {
      var field=typeof(StartupReader).GetField("worker",
          System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic);
      if(field==null) throw new System.InvalidOperationException("Missing reader worker witness");
      var worker=(System.Threading.Thread)field.GetValue(reader);
      return worker.Join(timeout);
    }
  }
  public sealed class FakeStartupSource : IStartupReadSource {
    readonly object gate = new object();
    readonly System.Collections.Generic.Queue<byte> bytes = new System.Collections.Generic.Queue<byte>();
    public int Calls, Closes; public bool Fail, IgnoreStop; public int MaximumRead = 8192;
    public int BytesToRead { get { lock(gate) return bytes.Count; } }
    public void Feed(byte[] input) { lock(gate) { foreach(byte b in input) bytes.Enqueue(b); System.Threading.Monitor.PulseAll(gate); } }
    public int Read(byte[] buffer, int offset, int count) {
      lock(gate) {
        Calls++; System.Threading.Monitor.PulseAll(gate);
        if(Fail) throw new System.IO.IOException("injected read failure");
        if(bytes.Count==0) System.Threading.Monitor.Wait(gate,20);
        if(bytes.Count==0) throw new System.TimeoutException();
        int n=System.Math.Min(count,System.Math.Min(MaximumRead,bytes.Count));
        for(int i=0;i<n;i++) buffer[offset+i]=bytes.Dequeue();
        return n;
      }
    }
    public void Close() { lock(gate) {Closes++;System.Threading.Monitor.PulseAll(gate);} }
    public bool WaitCalls(int wanted,int timeout) {
      var clock=System.Diagnostics.Stopwatch.StartNew();
      lock(gate) {while(Calls<wanted && clock.ElapsedMilliseconds<timeout) System.Threading.Monitor.Wait(gate,10);return Calls>=wanted;}
    }
  }
}
'@
Add-Type -TypeDefinition (([IO.File]::ReadAllText($helper))+[Environment]::NewLine+$fixture)
$count=0
function Pass([string]$Name){$script:count++;Write-Output "PASS $Name"}
$clock=[Diagnostics.Stopwatch]::StartNew()
$v=[VcLora.R19.FakeStartupSource]::new();$g=[VcLora.R19.FakeStartupSource]::new()
$vr=[VcLora.R19.StartupReader]::new($v,$clock,1048576,4096)
$gr=[VcLora.R19.StartupReader]::new($g,$clock,1048576,4096)
try{
  Assert-Condition ($vr.WaitReady(1000)-and$gr.WaitReady(1000)) 'Readers must be warmed before Open.'
  $vr.Arm()
  Assert-Condition ($v.WaitCalls(1,1000)) 'No data must still issue an actual Read.'
  Pass 'empty_open_issues_read'
  # An intentionally slow second Open cannot suspend the first reader.
  [Threading.Thread]::Sleep(160)
  Assert-Condition ($v.WaitCalls(4,1000)-and$g.Calls-eq0) 'Second Open blocked first reader or armed unopened role.'
  Pass 'delayed_second_open_keeps_first_reader_running'
  $gr.Arm();Assert-Condition ($g.WaitCalls(1,1000)) 'Ground Read not issued.'
  $v.Feed([byte[]](1,2,3));$g.Feed([byte[]](9,8))
  # Simulate slow post-open identity queries on the controlling thread.
  [Threading.Thread]::Sleep(160)
  Assert-Condition ($v.Calls-ge8-and$g.Calls-ge4) 'Post-open identity queries suspended readers.'
  Assert-Condition ($vr.Stop(1000)-and$gr.Stop(1000)) 'Bounded stop failed.'
  Assert-Condition ($v.Closes-eq0-and$g.Closes-eq0) 'Normal handover must keep ports open.'
  Assert-Condition (([BitConverter]::ToString($vr.GetBytes()))-ceq'01-02-03'-and
      ([BitConverter]::ToString($gr.GetBytes()))-ceq'09-08') 'Quarantine bytes lost or reordered.'
  Assert-Condition ($vr.GetSnapshot().Timeouts-gt0-and$vr.GetSnapshot().Failure-ceq'') 'No-data timeout became a failure.'
  Pass 'identity_delay_quarantine_and_timeout_preserved'
}finally{[void]$vr.Stop(1000);[void]$gr.Stop(1000)}
$source=[VcLora.R19.FakeStartupSource]::new();$source.Feed([byte[]](1,2,3));$source.MaximumRead=2
$reader=[VcLora.R19.StartupReader]::new($source,$clock,64,16)
try{
  [void]$reader.WaitReady(1000);$reader.Arm();[void]$source.WaitCalls(3,1000)
  $source.Feed([byte[]](4,5));[void]$source.WaitCalls(5,1000);[void]$reader.Stop(1000)
  $s=$reader.GetSnapshot()
  Assert-Condition ($s.InitialBytes-eq3-and$s.Failure-ceq''-and$s.Blocks.Count-ge3) 'Initial watermark or partial batch lost.'
  Assert-Condition (([BitConverter]::ToString($reader.GetBytes()))-ceq'01-02-03-04-05') 'Partial reads duplicated or lost bytes.'
  Assert-Condition ($s.Blocks[0].BeginTicks-ge$s.FirstReadBeginTicks-and$s.Blocks[0].EndTicks-ge$s.Blocks[0].BeginTicks) 'Native QPC missing.'
  Pass 'partial_read_exact_bytes_watermark_and_native_qpc'
}finally{[void]$reader.Stop(1000)}
foreach($fault in @('read','capacity','blocks')){
  $source=[VcLora.R19.FakeStartupSource]::new()
  if($fault-ceq'read'){$source.Fail=$true}else{$source.Feed([byte[]](1,2,3,4,5,6));$source.MaximumRead=2}
  $capacity=if($fault-ceq'capacity'){4}else{64}
  $blocks=if($fault-ceq'blocks'){1}else{16}
  $reader=[VcLora.R19.StartupReader]::new($source,$clock,$capacity,$blocks)
  try{
    Assert-Condition ($reader.WaitReady(1000)) 'Fault reader was not ready.'
    $reader.Arm()
    Assert-Condition ([VcLora.R19.StartupReaderTestWitness]::WaitExited($reader,1000)) 'Injected fault did not terminate the worker before cancellation.'
    Assert-Condition ($reader.Stop(1000)) 'Fault reader did not stop.'
    $s=$reader.GetSnapshot()
    Assert-Condition (-not[string]::IsNullOrEmpty($s.Failure)) "Fault $fault silently passed."
    $expectedFault=if($fault-ceq'read'){'IOException: injected read failure'}elseif($fault-ceq'capacity'){'STARTUP_BYTE_CAPACITY'}else{'STARTUP_BLOCK_CAPACITY'}
    Assert-Condition ($s.Failure-ceq$expectedFault) "Wrong terminal failure for $fault."
    Assert-Condition ($reader.GetBytes().Length-eq$s.ByteCount) 'Fault discarded retained raw.'
    if($fault-cne'read'){Assert-Condition ($s.ByteCount-gt0) 'Fault lost prefix evidence.'}
    Pass ($fault+'_fails_closed_with_raw_retained')
  }finally{[void]$reader.Stop(1000)}
}
$runner=Join-Path $repo 'tools/run_r19_runtime_fail_diagnostic_hil.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
Assert-Condition ($errors.Count-eq0) 'Runner parse failure.'
foreach($name in @('Start-R19StartupCapture','Receive-R19StartupCapture','Stop-R19StartupCapture')){
  Assert-Condition (@($ast.FindAll({param($n)
    $n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$name},$true)).Count-eq1) "Missing production integration: $name"
}
$capture=@($ast.FindAll({param($n)
  $n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Invoke-R19RuntimeFailDiagnosticCapture'},$true))[0].Extent.Text
# The lifetime owner supersedes the legacy stop/join handover; the legacy
# functions above remain covered as compatibility APIs, not the live path.
Assert-Condition ($capture.IndexOf('Start-R19ContinuousCapture')-ge0-and
  $capture.IndexOf('Start-R19ContinuousCapture')-lt$capture.IndexOf("'after_open'")-and
  $capture.IndexOf('Confirm-R19ContinuousIdentity')-gt$capture.IndexOf("'after_open'")) 'Identity gate must quarantine before successful verification.'
$confirm=@($ast.FindAll({param($n)
  $n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Confirm-R19ContinuousIdentity'},$true))[0].Extent.Text
Assert-Condition ($confirm.Contains('before both post-open identities pass.')-and
  $confirm.Contains("MarkPhase('IDENTITY_VERIFIED')")-and
  -not($capture.Contains('Receive-R19StartupCapture')-or$confirm-match'\.Stop\(|\.Close\(|\.Join\(')) `
    'Identity verification must not transfer physical Read ownership or release bytes early.'
Assert-Condition ($capture.Contains('startup_reader_evidence')-and$capture.Contains('startup_readers_valid')-and
  $capture.Contains('measurement_window_start_us')) 'Early reader evidence/strict gate/window origin missing.'
Pass 'production_quarantine_identity_and_result_gate'
$converter=@($ast.FindAll({param($n)
  $n-is[Management.Automation.Language.FunctionDefinitionAst]-and
    $n.Name-ceq'ConvertTo-R19PcLifecycleEvidence'},$true))[0]
. ([scriptblock]::Create($converter.Extent.Text))
$words=[long[]]::new(16*6)
$words[0]=2;$words[1]=1;$words[2]=100
$words[6]=5;$words[7]=1;$words[8]=500
$trace=[pscustomobject]@{capacity=16;words=$words;count=2;dropped_events=0
  clock_domain_id='memory-only-shared-qpc';frequency=[long]10000000;utc_display_anchor='display-only'}
$script:StartupReaderEvidence=@([pscustomobject]@{clock_domain_id=$trace.clock_domain_id
  armed=$true;role='vehicle';arm_ticks='105';first_read_begin_ticks='110'
  first_read_end_ticks='130';first_read_requested_count=8192
  blocks=@([pscustomobject]@{Batch=1;BeginTicks=110;EndTicks=130;Count=2;RequestedCount=8192})})
$merged=ConvertTo-R19PcLifecycleEvidence $trace
$firstRead=@($merged.events|Where-Object{$_.event-ceq'READ_BEGIN'})[0]
Assert-Condition ($merged.result-ceq'COMPLETE'-and$firstRead.source-ceq'startup-native'-and
  $firstRead.elapsed_ticks-ceq'110'-and$firstRead.byte_count-eq8192-and
  $merged.events[0].event-ceq'OPEN_RETURN') 'Native QPC was omitted, fabricated, or sorted after the later main read.'
Pass 'native_first_read_merged_before_main_by_shared_qpc'
$overflow=@();foreach($i in 1..20){$overflow+=,[pscustomobject]@{Batch=$i;BeginTicks=(100+$i*20);EndTicks=(110+$i*20);Count=1;RequestedCount=8192}}
$script:StartupReaderEvidence[0].blocks=$overflow
$merged=ConvertTo-R19PcLifecycleEvidence $trace
Assert-Condition ($merged.result-ceq'INCOMPLETE'-and$merged.dropped_events-gt0-and
  $merged.event_count-eq16) 'Native trace capacity was silently exceeded.'
Pass 'merged_trace_overflow_explicit_not_ordering_proof'
$initialize=@($ast.FindAll({param($n)
  $n-is[Management.Automation.Language.FunctionDefinitionAst]-and
    $n.Name-ceq'Initialize-R19StartupReader'},$true))[0].Extent.Text
Assert-Condition ($initialize.Contains('Copy-PinnedInput')-and$initialize.Contains('Get-ByteSha $bytes')-and
  $initialize.Contains('UTF8.GetString($bytes)')-and$initialize.Contains('$script:StartupReaderSource=$helper')-and
  $initialize.Contains('$helper.sha256-ceq$ExpectedStartupReaderSha256')) 'Compiled helper is not tied to pinned source bytes.'
$sha=[Security.Cryptography.SHA256]::Create()
try{$expected=([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($helper)))).Replace('-','')}finally{$sha.Dispose()}
Assert-Condition ([IO.File]::ReadAllText($runner).Contains($expected)) 'Reviewed native helper SHA does not match production pin.'
Pass 'helper_compiles_verified_pinned_bytes_and_exports_provenance'
Write-Output "Startup reader offline contract PASS tests=$count; no COM, PnP, process inventory, or hardware accessed; not a physical USB timing proof."
