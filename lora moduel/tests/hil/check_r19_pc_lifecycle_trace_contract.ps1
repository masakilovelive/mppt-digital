[CmdletBinding()]
param([string]$OutputRoot)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if(-not$OutputRoot){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-pc-trace-'+[guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
$checks=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Body){try{&$Body;$checks.Add([ordered]@{name=$Name;passed=$true})}catch{$checks.Add([ordered]@{name=$Name;passed=$false;error=$_.Exception.Message})}}
function Require([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
$reader=Join-Path $repo 'tools/run_r19_runtime_fail_diagnostic_hil.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($reader,[ref]$tokens,[ref]$errors)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
$PumpReadBudgetBytes=8192
$script:Definitions=@{111=[pscustomobject]@{min_payload=16;max_payload=16;crc_extra=34}}
Check 'bounded-array-and-overflow' {
  $trace=New-R19PcLifecycleTrace -Capacity 16
  for($i=0;$i-lt20;++$i){Add-R19PcLifecycleEvent $trace 5 'ground' $i 28 0}
  $view=ConvertTo-R19PcLifecycleEvidence $trace
  Require ($trace.words.Length-eq96-and$view.event_count-eq16-and$view.dropped_events-eq4-and$view.result-ceq'INCOMPLETE') 'trace is not bounded or drops hidden'
}
Check 'shared-clock-open-read-frame-close-order' {
  . (Join-Path $repo 'tools/r19_usb_clock_correlation.ps1')
  $trace=New-R19PcLifecycleTrace -Capacity 64
  $serial=[pscustomobject]@{IsOpen=$false;BytesToRead=28;payload=(New-R19TimesyncRequest -Nonce ([long]0x5219000000000001));closed_count=0}
  $serial|Add-Member ScriptMethod Open {$this.IsOpen=$true}
  $serial|Add-Member ScriptMethod Read {param([byte[]]$Buffer,[int]$Offset,[int]$Count);$this.payload.CopyTo($Buffer,$Offset);$this.BytesToRead=0;return $Count}
  $serial|Add-Member ScriptMethod Close {$this.IsOpen=$false;$this.closed_count++}
  $serial|Add-Member ScriptMethod Dispose {}
  $evidence=[pscustomobject]@{serial_port_open_before_utc=$null;serial_port_open_after_utc=$null;serial_port_open_duration_ms=$null;result='';failure=''}
  Open-DiagnosticSerialPort $serial $evidence $null $trace 'ground'|Out-Null
  Add-R19PcLifecycleEvent $trace 4 'ground' 0 0 0
  $parser=New-DiagnosticParser 'ground';$raw=[IO.MemoryStream]::new();$clock=[Diagnostics.Stopwatch]::StartNew()
  $state=[pscustomobject]@{read_batch_id=[long]0;initial_drain_bytes=[long]-1;initial_drain_remaining=[long]-1;lifecycle_trace=$trace}
  [long]$last=-1;[long]$gap=0
  Read-DiagnosticSerial $serial $parser $raw $clock ([ref]$last) ([ref]$gap) $null $state
  $states=@([pscustomobject]@{spec=[pscustomobject]@{role='ground'};serial=$serial;raw=$raw;pending_frames=@();lifecycle_trace=$trace})
  function Save-DiagnosticCaptureEvidence {param($States,$Errors)}
  Invoke-DiagnosticCaptureCleanup $states ([Collections.ArrayList]::new())|Out-Null
  $view=ConvertTo-R19PcLifecycleEvidence $trace
  $names=@($view.events|ForEach-Object event)
  Require (($names-join',')-ceq'OPEN_BEGIN,OPEN_RETURN,READ_LOOP_ARMED,READ_BEGIN,READ_END,FIRST_POSITIVE_READ,FRAME_COMPLETE,CLOSE_BEGIN,CLOSE_RETURN') 'lifecycle events collapsed or reordered'
  Require ($view.result-ceq'COMPLETE'-and$view.frequency_gt_zero-and$serial.closed_count-eq1) 'trace clock or close failed'
  Require ($view.events[3].batch_id-eq1-and$view.events[4].byte_count-eq28-and$view.events[5].elapsed_ticks-ceq$view.events[4].elapsed_ticks-and$view.events[6].elapsed_ticks-ceq$view.events[4].elapsed_ticks) 'read/frame boundary timestamps not anchored to read return'
  Require ($parser.frames.Count-eq1-and$parser.total_bytes-eq28-and$raw.Length-eq28-and$state.initial_drain_bytes-eq28) 'instrumentation discarded data'
}
Check 'trace-has-no-file-io-or-unbounded-append-in-event-path' {
  $f=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Add-R19PcLifecycleEvent'},$true))
  Require ($f.Count-eq1-and$f[0].Extent.Text-notmatch'Set-Content|WriteAll|Write-Durable|\.Add\(|\+=') 'event path must use preallocated numeric slots only'
}
Check 'clock-before-open-and-export-after-close' {
  $f=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Invoke-R19RuntimeFailDiagnosticCapture'},$true))[0].Extent.Text
  Require ($f.IndexOf('New-R19PcLifecycleTrace')-lt$f.IndexOf('Open-DiagnosticSerialPort')-and$f.IndexOf('ConvertTo-R19PcLifecycleEvidence')-gt$f.IndexOf('Invoke-DiagnosticCaptureCleanup')) 'clock starts late or trace serialized in pump'
  Require ($f-match'serial_write_calls=0') 'read-only contract changed'
}
$quantitative=$null
Check 'quantitative-fixed-storage-and-event-cost' {
  $trace=New-R19PcLifecycleTrace -Capacity 1024
  [long]$worst=0;$watch=[Diagnostics.Stopwatch]::StartNew()
  for($i=0;$i-lt1024;++$i){$before=[Diagnostics.Stopwatch]::GetTimestamp();Add-R19PcLifecycleEvent $trace 5 'ground' $i 28 0;$cost=[Diagnostics.Stopwatch]::GetTimestamp()-$before;if($cost-gt$worst){$worst=$cost}}
  $watch.Stop()
  $script:quantitative=[ordered]@{sample_events=1024;storage_bytes=$trace.words.Length*8;total_us=[math]::Ceiling($watch.Elapsed.TotalMilliseconds*1000);maximum_observed_call_us=[math]::Ceiling($worst*1000000.0/[Diagnostics.Stopwatch]::Frequency);mean_inclusive_call_us=$watch.Elapsed.TotalMilliseconds*1000/1024;legacy_service_limit_us=100000;measurement_is_host_load_dependent=$true;hardware_performance_proven=$false}
  Require ($trace.count-eq1024-and$trace.words.Length-eq6144-and$trace.dropped_events-eq0) 'fixed-storage measurement changed'
}
Check 'open-failure-retains-distinct-error-and-cleanup-events' {
  $trace=New-R19PcLifecycleTrace -Capacity 32
  $serial=[pscustomobject]@{IsOpen=$false};$serial|Add-Member ScriptMethod Open {throw 'synthetic-open-failure'}
  $serial|Add-Member ScriptMethod Dispose {}
  $evidence=[pscustomobject]@{serial_port_open_before_utc=$null;serial_port_open_after_utc=$null;serial_port_open_duration_ms=$null;result='';failure=''}
  try{Open-DiagnosticSerialPort $serial $evidence $null $trace 'ground';throw 'expected failure missing'}catch{Require ($_.Exception.Message-match'synthetic-open-failure') 'unexpected open result'}
  $raw=[IO.MemoryStream]::new();$states=@([pscustomobject]@{spec=[pscustomobject]@{role='ground'};serial=$serial;raw=$raw;pending_frames=@();lifecycle_trace=$trace})
  function Save-DiagnosticCaptureEvidence {param($States,$Errors)}
  Invoke-DiagnosticCaptureCleanup $states ([Collections.ArrayList]::new())|Out-Null
  $view=ConvertTo-R19PcLifecycleEvidence $trace
  Require ((@($view.events|ForEach-Object event)-join',')-ceq'OPEN_BEGIN,OPEN_ERROR,CLOSE_BEGIN,CLOSE_RETURN') 'failure trace lost or claims OPEN_RETURN'
  $f=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Complete-Evidence'},$true))[0].Extent.Text
  Require ($f-match'CaptureLifecycleTrace'-and$f-match'pc_lifecycle_trace') 'failure evidence does not retain lifecycle trace'
}
$failed=@($checks|Where-Object{-not$_.passed})
$summary=[ordered]@{schema='vc-lora-r19-pc-lifecycle-trace-contract-v1';result=$(if($failed.Count){'FAIL'}else{'PASS'});hardware_interaction=$false;checks=@($checks);passed_count=$checks.Count-$failed.Count;failed_count=$failed.Count;quantitative=$quantitative}
$summary|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json') -Encoding UTF8
$summary|ConvertTo-Json -Depth 10
if($failed.Count){exit 1}
