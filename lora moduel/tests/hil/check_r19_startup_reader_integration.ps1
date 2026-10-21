[CmdletBinding()]
param([string]$RepoRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path

# Only function definitions are imported. The runner's entry point, COM/PnP
# inventory, candidate handling and any executable hardware path are not run.
$runner=Join-Path $repo 'tools/run_r19_runtime_fail_diagnostic_hil.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count-ne0){throw 'Runner AST parse failed.'}
$functions=@('Assert-Condition','Get-ByteSha','New-R19PcLifecycleTrace',
  'Add-R19PcLifecycleEvent','Get-DiagnosticFrameLeaf','Update-X25Crc',
  'Get-MavlinkDefinitions','New-DiagnosticParser','Add-DiagnosticBytes',
  'Get-SourceBinding','Convert-R19Diagnostic','New-SyntheticFrame',
  'New-OfflineProvenance','New-OfflineBufferedSerial','Open-DiagnosticSerialPort',
  'Start-R19StartupCapture','Stop-R19StartupCapture','Receive-R19StartupCapture',
  'Get-ElapsedUs','Read-DiagnosticSerial','Save-DiagnosticCaptureEvidence',
  'Invoke-DiagnosticCaptureCleanup')
foreach($name in $functions){
  $found=@($ast.FindAll({param($node)
    $node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$name},$true))
  if($found.Count-ne1){throw "Missing/ambiguous production function $name"}
  Invoke-Expression $found[0].Extent.Text
}
# A separately tested new pure window gate may not exist during the RED run.
$windowGate=@($ast.FindAll({param($node)
  $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
    $node.Name-ceq'Get-R19MeasurementWindowEvidence'},$true))
if($windowGate.Count-eq1){Invoke-Expression $windowGate[0].Extent.Text}
# Import the unchanged production limits and decoder patterns, not copied values.
foreach($name in @('PumpServiceLimitUs','PumpReadBudgetBytes','r19Pattern','r19AlivePattern')){
  $found=@($ast.EndBlock.Statements|Where-Object{
    $_-is[Management.Automation.Language.AssignmentStatementAst]-and
      $_.Left-is[Management.Automation.Language.VariableExpressionAst]-and
      $_.Left.VariablePath.UserPath-ceq$name})
  Assert-Condition ($found.Count-eq1) "Missing production constant $name"
  Invoke-Expression $found[0].Extent.Text
}
$script:Definitions=Get-MavlinkDefinitions (Join-Path $repo 'core/src/mavlink_frame.cpp')
$script:StartupReaderEvidence=$null
$evidence='OFFLINE_MEMORY_SINK'

# Persistence is a deliberately injected memory sink; capture/cleanup wrappers
# remain real. No test file or serial device is created by this test suite.
$script:Persisted=[Collections.ArrayList]::new()
$script:PersistenceFault=$false
function Write-DurableBytes([string]$Path,[byte[]]$Bytes){
  if($script:PersistenceFault){throw 'injected persistence fault'}
  [void]$script:Persisted.Add([pscustomobject]@{path=$Path;bytes=$Bytes.Clone()})
}

$fixture=@'
namespace VcLora.R19 {
  public sealed class IntegrationSerial {
    readonly object gate = new object();
    readonly System.Collections.Generic.Queue<byte> data = new System.Collections.Generic.Queue<byte>();
    public bool IsOpen { get; private set; }
    public int Opens, Closes, Disposes, Calls, Delivered;
    public int BlockAfterRead = -1;
    public bool CloseReleases = true, ThrowClose, ThrowDispose;
    public byte[] AppendOnFirstRead;
    bool released;
    public int BytesToRead { get { lock(gate) return data.Count; } }
    public void Open() { lock(gate) { IsOpen=true; Opens++; } }
    public void Feed(byte[] bytes) { lock(gate) { foreach(byte b in bytes) data.Enqueue(b); System.Threading.Monitor.PulseAll(gate); } }
    public int Read(byte[] output,int offset,int count) {
      lock(gate) {
        Calls++;System.Threading.Monitor.PulseAll(gate);
        if(Calls==1 && AppendOnFirstRead!=null) foreach(byte b in AppendOnFirstRead) data.Enqueue(b);
        while(BlockAfterRead>=0 && Calls>BlockAfterRead && !released)
          System.Threading.Monitor.Wait(gate,20);
        if(data.Count==0) System.Threading.Monitor.Wait(gate,20);
        if(data.Count==0) throw new System.TimeoutException();
        int n=System.Math.Min(count,data.Count);
        for(int i=0;i<n;i++) output[offset+i]=data.Dequeue();
        Delivered+=n;System.Threading.Monitor.PulseAll(gate);return n;
      }
    }
    public void Close() { lock(gate) { Closes++;if(CloseReleases){released=true;System.Threading.Monitor.PulseAll(gate);}if(ThrowClose)throw new System.IO.IOException("injected close fault");IsOpen=false; } }
    public void Dispose() { lock(gate) { Disposes++;if(ThrowDispose)throw new System.IO.IOException("injected dispose fault"); } }
    public void Release() { lock(gate) { released=true;System.Threading.Monitor.PulseAll(gate); } }
    public bool WaitReads(int wanted,int timeout) {
      var timer=System.Diagnostics.Stopwatch.StartNew();
      lock(gate) { while(Calls<wanted && timer.ElapsedMilliseconds<timeout) System.Threading.Monitor.Wait(gate,10);return Calls>=wanted; }
    }
  }
}
'@
Add-Type -TypeDefinition (([IO.File]::ReadAllText((Join-Path $repo 'tools/r19_startup_reader.cs')))+[Environment]::NewLine+$fixture)

$script:Passed=0;$script:Failed=[Collections.ArrayList]::new()
$script:Measurements=[Collections.ArrayList]::new()
function Test-Case([string]$Name,[scriptblock]$Body){
  try{& $Body;$script:Passed++;Write-Output "PASS $Name"}
  catch{[void]$script:Failed.Add("${Name}: $($_.Exception.Message)");Write-Output "FAIL ${Name}: $($_.Exception.Message)"}
}
function Assert-Throws([scriptblock]$Body,[string]$Contains){
  $caught=$null
  try{& $Body}catch{$caught=$_}
  Assert-Condition ($null-ne$caught) "Expected failure containing: $Contains"
  Assert-Condition ($caught.Exception.Message.Contains($Contains)) "Unexpected failure: $($caught.Exception.Message)"
}
function New-State([string]$Role,[object]$Trace){
  [pscustomobject]@{
    spec=[pscustomobject]@{role=$Role;code=$(if($Role-ceq'vehicle'){'V'}else{'G'})}
    serial=[VcLora.R19.IntegrationSerial]::new();raw=[IO.MemoryStream]::new()
    parser=New-DiagnosticParser $Role;lifecycle_trace=$Trace
    open_evidence=[pscustomobject]@{serial_port_open_before_utc=$null;serial_port_open_after_utc=$null;serial_port_open_duration_ms=$null;result='NOT_ATTEMPTED';failure=$null}
    read_state=[pscustomobject]@{read_batch_id=[long]0;initial_drain_bytes=[long]-1;initial_drain_remaining=[long]-1;lifecycle_trace=$Trace}
    startup_reader=$null;startup_snapshot=$null;startup_evidence=$null
    startup_identity_verified=$false;startup_close_required=$false
    pending_frames=[Collections.ArrayList]::new();last=[long]-1;max_gap=[long]0
  }
}
function Open-State([object]$State,[object]$Trace){
  Open-DiagnosticSerialPort $State.serial $State.open_evidence $null $Trace $State.spec.role $State.startup_reader
  Assert-Condition ($State.serial.WaitReads(1,1000)) 'Open did not arm an actual Read.'
}
function Release-States([object[]]$States){
  foreach($state in $States){
    $state.serial.Release()
    if($null-ne$state.startup_reader){[void]$state.startup_reader.Stop(1000)}
    $state.raw.Dispose()
  }
}

Test-Case 'real_wrappers_quarantine_until_both_identities_pass' {
  $trace=New-R19PcLifecycleTrace;$states=@((New-State 'vehicle' $trace),(New-State 'ground' $trace))
  try{
    foreach($state in $states){$state.serial.Feed([byte[]](New-SyntheticFrame $state.spec.code 1))}
    Start-R19StartupCapture $states $trace
    foreach($state in $states){Open-State $state $trace;Assert-Condition ($state.serial.WaitReads(2,1000)) 'Positive read was not completed.'}
    $states[0].startup_identity_verified=$true
    Assert-Throws {Receive-R19StartupCapture $states} 'before both post-open identities pass'
    foreach($state in $states){Assert-Condition ($state.parser.total_bytes-eq0-and$state.raw.Length-eq0) 'Quarantined data was parsed or released early.'}
    $states[1].startup_identity_verified=$true;Receive-R19StartupCapture $states
    foreach($state in $states){
      Assert-Condition ($state.raw.Length-eq63-and$state.parser.valid_frames-eq1) 'Verified handover lost raw or failed real parser replay.'
      Assert-Condition ($state.startup_evidence.replayed-and$state.startup_evidence.identity_verified) 'Verified replay evidence missing.'
      Assert-Condition ($state.serial.Closes-eq0) 'Normal handover closed serial source.'
      [void]$script:Measurements.Add([pscustomobject]@{case='quarantine';role=$state.spec.role;open_to_first_read_us=$state.startup_evidence.open_to_first_read_us;scope='offline fake source only'})
    }
  }finally{Release-States $states}
}

Test-Case 'identity_mismatch_cleanup_preserves_raw_without_parsing' {
  $trace=New-R19PcLifecycleTrace;$states=@((New-State 'vehicle' $trace),(New-State 'ground' $trace));$before=$script:Persisted.Count
  try{
    foreach($state in $states){$state.serial.Feed([byte[]](New-SyntheticFrame $state.spec.code 2))}
    Start-R19StartupCapture $states $trace
    foreach($state in $states){Open-State $state $trace;Assert-Condition ($state.serial.WaitReads(2,1000)) 'Read not completed.'}
    $states[0].startup_identity_verified=$true
    $errors=[Collections.ArrayList]::new();$cleanup=Invoke-DiagnosticCaptureCleanup $states $errors
    Assert-Condition ($cleanup.result-ceq'PASS'-and$script:Persisted.Count-eq$before+2) 'Mismatch cleanup did not preserve both raw streams.'
    foreach($state in $states){Assert-Condition ($state.parser.total_bytes-eq0-and-not$state.startup_evidence.replayed-and$state.startup_evidence.raw_bytes-eq63) 'Mismatch data was parsed or discarded.'}
    Assert-Condition (-not$states[1].startup_evidence.identity_verified) 'Mismatch identity was fabricated.'
  }finally{Release-States $states}
}

Test-Case 'physical_initial_watermark_splits_one_native_batch_without_fabricated_reads' {
  $trace=New-R19PcLifecycleTrace;$state=New-State 'ground' $trace
  try{
    [byte[]]$frames=@(New-SyntheticFrame 'G' 3)+@(New-SyntheticFrame 'G' 4)
    $state.serial.Feed([byte[]]$frames[0..9]);$state.serial.AppendOnFirstRead=[byte[]]$frames[10..125]
    Start-R19StartupCapture @($state) $trace;Open-State $state $trace
    Assert-Condition ($state.serial.WaitReads(2,1000)) 'Native batch did not complete.'
    $state.startup_identity_verified=$true;Receive-R19StartupCapture @($state)
    $s=$state.startup_snapshot;$a=$state.parser.frames[0];$b=$state.parser.frames[1]
    Assert-Condition ($s.InitialBytes-eq10-and$s.Blocks.Count-eq1-and$s.Blocks[0].Count-eq126) 'Physical initial watermark/native batch was changed.'
    Assert-Condition ($a.start_capture_origin-ceq'STARTUP_DRAIN'-and$a.capture_origin-ceq'LIVE'-and$b.start_capture_origin-ceq'LIVE') 'Watermark provenance was lost on a spanning frame.'
    Assert-Condition ($a.read_batch_id-eq$b.read_batch_id-and$a.complete_us-eq$b.complete_us-and$a.start_read_batch_id-eq$a.read_batch_id) 'Replay fabricated independent read/timing observations.'
    Assert-Condition ($state.raw.Length-eq126-and$state.parser.valid_frames-eq2-and$state.read_state.initial_drain_remaining-eq0) 'Same-batch split lost or duplicated bytes.'
  }finally{Release-States @($state)}
}

Test-Case 'unarmed_stop_and_cleanup_terminate_without_read_or_close_fallback' {
  $trace=New-R19PcLifecycleTrace;$state=New-State 'vehicle' $trace
  try{
    Start-R19StartupCapture @($state) $trace;Stop-R19StartupCapture $state $true
    Assert-Condition ($state.serial.Calls-eq0-and$state.serial.Opens-eq0-and$state.serial.Closes-eq0) 'Unarmed cleanup touched serial source.'
    Assert-Condition ($state.startup_snapshot.Stopped-and-not$state.startup_snapshot.Armed-and-not$state.startup_evidence.valid) 'Unarmed reader was classified as valid.'
    $errors=[Collections.ArrayList]::new();$cleanup=Invoke-DiagnosticCaptureCleanup @($state) $errors
    Assert-Condition ($cleanup.result-ceq'PASS'-and$state.serial.Disposes-eq1-and$state.parser.total_bytes-eq0) 'Unarmed cleanup failed.'
  }finally{Release-States @($state)}
}

Test-Case 'handover_gap_over_100ms_remains_a_fairness_failure' {
  $trace=New-R19PcLifecycleTrace;$state=New-State 'ground' $trace
  try{
    Start-R19StartupCapture @($state) $trace;Open-State $state $trace
    $state.startup_identity_verified=$true;Receive-R19StartupCapture @($state)
    [Threading.Thread]::Sleep(140)
    $last=[long]$state.last;$gap=[long]0
    Read-DiagnosticSerial $state.serial $state.parser $state.raw $trace.clock ([ref]$last) ([ref]$gap) $null $state.read_state
    Assert-Condition ($gap-gt$PumpServiceLimitUs) 'Handover gap was reset or hidden by a new measurement origin.'
    [void]$script:Measurements.Add([pscustomobject]@{case='injected_handover_gap';maximum_service_gap_us=$gap;limit_us=$PumpServiceLimitUs;expected_fairness='FAIL';scope='offline injected delay only'})
  }finally{Release-States @($state)}
}

Test-Case 'fallback_close_join_success_never_allows_normal_replay_even_on_retry' {
  $trace=New-R19PcLifecycleTrace;$state=New-State 'ground' $trace
  try{
    $state.serial.Feed([byte[]](New-SyntheticFrame 'G' 5));$state.serial.BlockAfterRead=1
    Start-R19StartupCapture @($state) $trace;Open-State $state $trace
    Assert-Condition ($state.serial.WaitReads(2,1000)) 'Fixture did not reach blocked second Read.'
    Assert-Throws {Stop-R19StartupCapture $state} 'cannot hand over'
    Assert-Condition ($state.startup_close_required-and$state.serial.Closes-eq1-and$state.raw.Length-eq63-and-not$state.startup_evidence.valid) 'Fallback Close was accepted or raw lost.'
    $state.startup_identity_verified=$true
    Assert-Throws {Receive-R19StartupCapture @($state)} 'cannot hand over'
    Assert-Condition ($state.parser.total_bytes-eq0-and-not$state.startup_evidence.replayed) 'Retry bypassed failed handover and parsed quarantined data.'
  }finally{Release-States @($state)}
}

Test-Case 'failed_join_forbids_handover_and_cleanup_reports_failure' {
  $trace=New-R19PcLifecycleTrace;$state=New-State 'vehicle' $trace
  try{
    $state.serial.BlockAfterRead=0;$state.serial.CloseReleases=$false
    Start-R19StartupCapture @($state) $trace;Open-State $state $trace
    Assert-Throws {Stop-R19StartupCapture $state} 'did not terminate'
    Assert-Condition ($state.startup_close_required-and$null-eq$state.startup_snapshot-and$state.parser.total_bytes-eq0) 'Failed join permitted snapshot/replay.'
    $errors=[Collections.ArrayList]::new();$cleanup=Invoke-DiagnosticCaptureCleanup @($state) $errors
    Assert-Condition ($cleanup.result-ceq'FAIL'-and@($errors|Where-Object{$_-like'startup reader cleanup failed*'}).Count-eq1) 'Join failure disappeared during cleanup.'
  }finally{Release-States @($state)}
}

Test-Case 'primary_failure_survives_multiple_cleanup_failures' {
  $trace=New-R19PcLifecycleTrace;$state=New-State 'ground' $trace;$primary='';$cleanup=$null
  try{
    Start-R19StartupCapture @($state) $trace;Open-State $state $trace
    $state.serial.ThrowClose=$true;$state.serial.ThrowDispose=$true;$script:PersistenceFault=$true
    $errors=[Collections.ArrayList]::new()
    try{
      try{throw 'injected primary identity mismatch'}finally{$cleanup=Invoke-DiagnosticCaptureCleanup @($state) $errors}
    }catch{$primary=$_.Exception.Message}
    Assert-Condition ($primary-ceq'injected primary identity mismatch') 'Cleanup replaced the primary failure.'
    Assert-Condition ($cleanup.result-ceq'FAIL'-and$errors.Count-eq3) 'Cleanup did not retain close, dispose and persistence failures.'
    Assert-Condition (@($cleanup.steps|Where-Object{$_.result-ceq'FAIL'}).Count-eq3) 'Cleanup failure diagnostics incomplete.'
  }finally{$script:PersistenceFault=$false;Release-States @($state)}
}

Test-Case 'startup_only_diagnostics_cannot_satisfy_measurement_window' {
  Assert-Condition ($windowGate.Count-eq1) 'Missing production measurement-window evidence gate.'
  $states=@()
  foreach($role in @('vehicle','ground')){
    $states+=,[pscustomobject]@{spec=[pscustomobject]@{role=$role}
      parser=[pscustomobject]@{frames=@([pscustomobject]@{raw_length=63;complete_us=[long]900})}
      diagnostics=@([pscustomobject]@{diagnostic_success=$true;complete_us=[long]900})}
  }
  $result=Get-R19MeasurementWindowEvidence $states 1000
  Assert-Condition (-not$result.valid-and$result.ports.Count-eq2) 'Startup-only activity was accepted as measured-window activity.'
  foreach($port in $result.ports){
    Assert-Condition ($port.startup_bytes-eq63-and$port.startup_frames-eq1-and$port.measurement_complete_frames-eq0-and$port.measurement_valid_diagnostics-eq0) 'Window/startup accounting incorrect.'
  }
}

Test-Case 'measurement_gate_is_per_role_and_includes_exact_window_boundary' {
  Assert-Condition ($windowGate.Count-eq1) 'Missing production measurement-window evidence gate.'
  $states=@()
  foreach($role in @('vehicle','ground')){
    $states+=,[pscustomobject]@{spec=[pscustomobject]@{role=$role}
      parser=[pscustomobject]@{frames=@([pscustomobject]@{raw_length=63;complete_us=[long]900},[pscustomobject]@{raw_length=63;complete_us=[long]1000})}
      diagnostics=@([pscustomobject]@{diagnostic_success=$true;complete_us=[long]900},[pscustomobject]@{diagnostic_success=$true;complete_us=[long]1000})}
  }
  $pass=Get-R19MeasurementWindowEvidence $states 1000
  Assert-Condition $pass.valid 'A real diagnostic exactly at window start was excluded.'
  foreach($port in $pass.ports){Assert-Condition ($port.startup_bytes-eq63-and$port.startup_frames-eq1-and$port.measurement_complete_frames-eq1-and$port.measurement_valid_diagnostics-eq1) 'Exact-boundary measurement counts incorrect.'}
  $states[1].diagnostics[1].diagnostic_success=$false
  $fail=Get-R19MeasurementWindowEvidence $states 1000
  Assert-Condition (-not$fail.valid) 'One role or invalid diagnostic was allowed to satisfy both roles.'
}

foreach($measurement in $script:Measurements){Write-Output ('MEASUREMENT '+(ConvertTo-Json $measurement -Compress))}
Write-Output "Startup integration offline tests: PASS=$script:Passed FAIL=$($script:Failed.Count); no COM, PnP, process inventory, network or hardware accessed."
Write-Output 'Measurements use fake in-memory serial sources; they do not establish physical USB latency, MCU deadline compliance, or product acceptance.'
if($script:Failed.Count-gt0){throw ($script:Failed-join[Environment]::NewLine)}
