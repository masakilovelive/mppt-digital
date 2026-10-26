[CmdletBinding()]
param([string]$OutputRoot)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if(-not$OutputRoot){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-clock-'+[guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
$checks=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Body){try{&$Body;$checks.Add([ordered]@{name=$Name;passed=$true})}catch{$checks.Add([ordered]@{name=$Name;passed=$false;error=$_.Exception.Message})}}
function Require([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
$module=Join-Path $repo 'tools/r19_usb_clock_correlation.ps1'
if(Test-Path -LiteralPath $module){. $module}
function New-Observation {
  $identity=[ordered]@{role='ground';candidate_id='candidate-v1';session_id='session-v1';boot_instance=@(101,202,303,404)}
  [ordered]@{
    schema='vc-lora-r19-usb-clock-correlation-observation-v1'
    identity=$identity
    failure=[ordered]@{role='ground';candidate_id='candidate-v1';session_id='session-v1';boot_instance=@(101,202,303,404);device_us=5335000;quantization_us=1}
    sync=[ordered]@{role='ground';candidate_id='candidate-v1';session_id='session-v1';boot_instance=@(101,202,303,404);nonce='5915773860520034305';echoed_nonce='5915773860520034305';device_us=10000000;quantization_us=1}
    pc=[ordered]@{clock_domain_id='qpc-domain-v1';open_clock_domain_id='qpc-domain-v1';sync_clock_domain_id='qpc-domain-v1';frequency=1000000;open_before_ticks=8000000;open_after_ticks=8000100;send_before_ticks=10000000;receive_after_ticks=10001000}
    continuity=[ordered]@{same_boot=$true;reset_absent=$true;sleep_absent=$true;halt_absent=$true;clock_reinitialization_absent=$true}
    error_bound=[ordered]@{guaranteed=$true;rate_error_ppb=100000;additive_us=5;source='reviewed synthetic bound'}
  }|ConvertTo-Json -Depth 9|ConvertFrom-Json
}
Check 'module-exists' {Require (Test-Path -LiteralPath $module) 'clock module absent'}
Check 'strict-pre' {$o=New-Observation;$r=Get-R19UsbClockCorrelation $o;Require ($r.classification-ceq'PRE_PC_OPEN'-and$r.bounds_valid) 'PRE expected'}
Check 'strict-post' {$o=New-Observation;$o.failure.device_us=9000000;$r=Get-R19UsbClockCorrelation $o;Require ($r.classification-ceq'POST_PC_OPEN') 'POST expected'}
Check 'send-cannot-precede-open-return' {
  $o=New-Observation;$o.pc.send_before_ticks=8000099
  $r=Get-R19UsbClockCorrelation $o
  Require ($r.classification-ceq'UNKNOWN'-and-not$r.bounds_valid) 'sync send before open returned must invalidate correlation'
}
Check 'optional-read-events-absent-remain-unknown' {
  $r=Get-R19UsbClockCorrelation (New-Observation)
  Require ($r.bounds_valid-and$r.classification-ceq'PRE_PC_OPEN') 'legacy open classification changed'
  Require ($r.read_loop_comparison.classification-ceq'UNKNOWN'-and$r.first_positive_read_comparison.classification-ceq'UNKNOWN') 'missing read timing was inferred'
}
Check 'read-loop-and-first-positive-are-separate-application-events' {
  foreach($post in @($false,$true)){
    $o=New-Observation;$o.failure.device_us=$(if($post){9700000}else{9000000})
    $o.failure.quantization_us=0;$o.sync.quantization_us=0;$o.error_bound.rate_error_ppb=0;$o.error_bound.additive_us=0
    $o.pc|Add-Member NoteProperty read_loop_armed_ticks 9500000
    $o.pc|Add-Member NoteProperty first_positive_read_ticks 9600000
    $r=Get-R19UsbClockCorrelation $o
    $prefix=if($post){'POST'}else{'PRE'}
    Require ($r.classification-ceq'POST_PC_OPEN') 'open boundary lost its independent meaning'
    Require ($r.read_loop_comparison.classification-ceq($prefix+'_READ_LOOP_ARMED')) 'read loop comparison differs'
    Require ($r.first_positive_read_comparison.classification-ceq($prefix+'_FIRST_POSITIVE_READ')) 'first positive read comparison differs'
    Require ($r.first_positive_read_comparison.semantics-ceq'application-read-return-sample-not-physical-usb-arrival') 'physical arrival must not be claimed'
  }
}
Check 'read-event-endpoint-touches-are-unknown' {
  foreach($ticks in @(9000000,9001000)){
    $o=New-Observation;$o.failure.device_us=9000000;$o.failure.quantization_us=0;$o.sync.quantization_us=0;$o.error_bound.rate_error_ppb=0;$o.error_bound.additive_us=0
    $o.pc|Add-Member NoteProperty read_loop_armed_ticks $ticks
    $o.pc|Add-Member NoteProperty first_positive_read_ticks $ticks
    $r=Get-R19UsbClockCorrelation $o
    Require ($r.bounds_valid-and$r.read_loop_comparison.classification-ceq'UNKNOWN'-and$r.first_positive_read_comparison.classification-ceq'UNKNOWN') 'event endpoint touch must not classify strictly'
  }
}
Check 'challenge-send-then-read-loop-is-valid' {
  $o=New-Observation;$o.failure.device_us=9000000
  $o.pc|Add-Member NoteProperty read_loop_armed_ticks 10000001
  $o.pc|Add-Member NoteProperty first_positive_read_ticks 10000500
  $r=Get-R19UsbClockCorrelation $o
  Require ($r.bounds_valid-and$r.classification-ceq'POST_PC_OPEN') 'valid send-then-read ordering rejected'
  Require ($r.read_loop_comparison.classification-ceq'PRE_READ_LOOP_ARMED'-and$r.first_positive_read_comparison.classification-ceq'PRE_FIRST_POSITIVE_READ') 'read instrumentation boundary comparisons differ'
}
Check 'read-events-invalid-order-fail-closed' {
  foreach($case in @('loop-before-open','loop-after-response','positive-before-open','positive-before-loop','positive-after-response','fractional-loop','string-positive')){
    $o=New-Observation;$o.pc|Add-Member NoteProperty read_loop_armed_ticks 9000000;$o.pc|Add-Member NoteProperty first_positive_read_ticks 9500000
    switch($case){'loop-before-open'{$o.pc.read_loop_armed_ticks=8000099}'loop-after-response'{$o.pc.read_loop_armed_ticks=10001001}'positive-before-open'{$o.pc.first_positive_read_ticks=8000099}'positive-before-loop'{$o.pc.first_positive_read_ticks=8999999}'positive-after-response'{$o.pc.first_positive_read_ticks=10001001}'fractional-loop'{$o.pc.read_loop_armed_ticks=9000000.5}'string-positive'{$o.pc.first_positive_read_ticks='bad'}}
    $r=Get-R19UsbClockCorrelation $o
    Require ($r.classification-ceq'UNKNOWN'-and-not$r.bounds_valid-and$r.read_loop_comparison.classification-ceq'UNKNOWN'-and$r.first_positive_read_comparison.classification-ceq'UNKNOWN') ('invalid read event accepted: '+$case)
  }
}
Check 'incomplete-or-overflowed-trace-cannot-classify' {
  foreach($case in @('overflow','incomplete','string-overflow','string-incomplete','result-incomplete','result-wrong-case')){
    $o=New-Observation
    switch($case){'overflow'{$o.pc|Add-Member NoteProperty trace_overflow $true}'incomplete'{$o.pc|Add-Member NoteProperty trace_incomplete $true}'string-overflow'{$o.pc|Add-Member NoteProperty trace_overflow 'false'}'string-incomplete'{$o.pc|Add-Member NoteProperty trace_incomplete 'false'}'result-incomplete'{$o.pc|Add-Member NoteProperty lifecycle_trace_result 'INCOMPLETE'}'result-wrong-case'{$o.pc|Add-Member NoteProperty lifecycle_trace_result 'complete'}}
    $r=Get-R19UsbClockCorrelation $o
    Require ($r.classification-ceq'UNKNOWN'-and-not$r.bounds_valid) ('unsafe trace accepted: '+$case)
  }
  $o=New-Observation;$o.pc|Add-Member NoteProperty trace_overflow $false;$o.pc|Add-Member NoteProperty trace_incomplete $false;$o.pc|Add-Member NoteProperty lifecycle_trace_result 'COMPLETE'
  Require (Get-R19UsbClockCorrelation $o).bounds_valid 'explicit complete trace rejected'
}
foreach($case in @('no-bound','unreviewed-bound','reset','sleep','halt','clock-reinit','boot-mismatch','scalar-boot','zero-boot','role-mismatch','candidate-mismatch','session-mismatch','qpc-domain-mismatch','nonce-mismatch','invalid-rate','negative-frequency','reversed-rtt','reversed-open','failure-overflow','sync-overflow','fractional-ticks')){
  Check ('unknown-'+$case) {
    $o=New-Observation
    switch($case){
      'no-bound'{$o.error_bound=$null}
      'unreviewed-bound'{$o.error_bound.guaranteed=$false}
      'reset'{$o.continuity.reset_absent=$false}
      'sleep'{$o.continuity.sleep_absent=$false}
      'halt'{$o.continuity.halt_absent=$false}
      'clock-reinit'{$o.continuity.clock_reinitialization_absent=$false}
      'boot-mismatch'{$o.sync.boot_instance[3]=999}
      'scalar-boot'{$o.identity.boot_instance=1}
      'zero-boot'{$o.identity.boot_instance=@(0,0,0,0)}
      'role-mismatch'{$o.sync.role='vehicle'}
      'candidate-mismatch'{$o.failure.candidate_id='another'}
      'session-mismatch'{$o.sync.session_id='another'}
      'qpc-domain-mismatch'{$o.pc.open_clock_domain_id='another'}
      'nonce-mismatch'{$o.sync.echoed_nonce='5915773860520034306'}
      'invalid-rate'{$o.error_bound.rate_error_ppb=1000000000}
      'negative-frequency'{$o.pc.frequency=-1}
      'reversed-rtt'{$o.pc.receive_after_ticks=9999999}
      'reversed-open'{$o.pc.open_after_ticks=7999999}
      'failure-overflow'{$o.failure.device_us='18446744073709551615'}
      'sync-overflow'{$o.sync.device_us='18446744073709551615'}
      'fractional-ticks'{$o.pc.send_before_ticks=10000000.5}
    }
    $r=Get-R19UsbClockCorrelation $o;Require ($r.classification-ceq'UNKNOWN'-and-not$r.bounds_valid) 'must fail closed to UNKNOWN'
  }
}
foreach($which in @('lower-touch','upper-touch','overlap')){
  Check ('strict-endpoint-'+$which) {
    $o=New-Observation;$o.error_bound.rate_error_ppb=0;$o.error_bound.additive_us=0;$o.failure.quantization_us=0;$o.sync.quantization_us=0
    $o.failure.device_us=8000000
    switch($which){'lower-touch'{$o.pc.open_before_ticks=8001000;$o.pc.open_after_ticks=8001100}'upper-touch'{$o.pc.open_before_ticks=7999900;$o.pc.open_after_ticks=8000000}'overlap'{$o.pc.open_before_ticks=8000200;$o.pc.open_after_ticks=8000300}}
    $r=Get-R19UsbClockCorrelation $o;Require ($r.classification-ceq'UNKNOWN'-and$r.bounds_valid) 'touch/overlap must remain UNKNOWN'
  }
}
Check 'negative-delta-asymmetric-rate-and-rounding' {
  $o=New-Observation;$o.pc.frequency=3000000;$o.pc.send_before_ticks=30000000;$o.pc.receive_after_ticks=30000001;$o.error_bound.rate_error_ppb=100000000;$o.error_bound.additive_us=0
  $o.failure.device_us=9999990;$o.failure.quantization_us=0;$o.sync.quantization_us=0
  $r=Get-R19UsbClockCorrelation $o
  Require ($r.lower_pc_us-ceq'9999988'-and$r.upper_pc_us-ceq'9999992') 'outward rational bounds differ'
}
Check 'uint64-extremes-no-double-or-overflow' {
  $o=New-Observation;$o.failure.device_us='18446744073709551615';$o.failure.quantization_us=0;$o.sync.quantization_us=0;$o.error_bound.rate_error_ppb=999999999
  $r=Get-R19UsbClockCorrelation $o;Require ($r.bounds_valid-and$r.classification-ceq'POST_PC_OPEN') 'full-width arithmetic failed'
}
Check 'exhaustive-zero-drift-integer-grid' {
  $tested=0
  foreach($delta in -20..20){foreach($open in 9950..10050){
    # Shift both sync clocks +10000, not the historical failure/open events.
    # This retains the exact original [10000+delta,10002+delta] interval while
    # ensuring every sync request is physically after COM open returned.
    $o=New-Observation;$o.sync.device_us=20000;$o.failure.device_us=10000+$delta;$o.failure.quantization_us=0;$o.sync.quantization_us=0
    $o.pc.send_before_ticks=20000;$o.pc.receive_after_ticks=20002;$o.pc.open_before_ticks=$open;$o.pc.open_after_ticks=$open+1;$o.error_bound.rate_error_ppb=0;$o.error_bound.additive_us=0
    $r=Get-R19UsbClockCorrelation $o
    Require ($r.lower_pc_us-ceq([string](10000+$delta))-and$r.upper_pc_us-ceq([string](10002+$delta))) 'physical-order fixture shift changed the historical interval'
    $expected=if(10002+$delta-lt$open){'PRE_PC_OPEN'}elseif(10000+$delta-gt$open+1){'POST_PC_OPEN'}else{'UNKNOWN'}
    Require ($r.classification-ceq$expected) "grid mismatch delta=$delta open=$open";++$tested
  }}
  Require ($tested-eq4141) 'grid count changed'
}
Check 'exhaustive-rate-extrema-interval-coverage' {
  $tested=0
  foreach($delta in -20..20){
    $o=New-Observation;$o.sync.device_us=10000;$o.failure.device_us=10000+$delta;$o.failure.quantization_us=0;$o.sync.quantization_us=0
    $o.pc.send_before_ticks=10000;$o.pc.receive_after_ticks=10002;$o.pc.open_before_ticks=9999;$o.pc.open_after_ticks=10000;$o.error_bound.rate_error_ppb=100000000;$o.error_bound.additive_us=0
    $r=Get-R19UsbClockCorrelation $o;Require $r.bounds_valid 'rate interval rejected'
    foreach($rateNumerator in 9,10,11){foreach($syncPc in 10000..10002){
      [long]$trueNumerator=$syncPc*$rateNumerator+$delta*10
      Require (([long]$r.lower_pc_us)*$rateNumerator-le$trueNumerator-and([long]$r.upper_pc_us)*$rateNumerator-ge$trueNumerator) 'rate extrema escaped outward bounds'
      if($r.classification-ceq'PRE_PC_OPEN'){Require ($trueNumerator-lt9999*$rateNumerator) 'false PRE'}
      if($r.classification-ceq'POST_PC_OPEN'){Require ($trueNumerator-gt10000*$rateNumerator) 'false POST'}
      ++$tested
    }}
  }
  Require ($tested-eq369) 'rate coverage count changed'
}
Check 'booleans-are-not-coerced-from-strings' {
  foreach($field in @('same_boot','reset_absent','sleep_absent','halt_absent','clock_reinitialization_absent')){
    $o=New-Observation;$o.continuity.$field='true';Require (-not(Get-R19UsbClockCorrelation $o).bounds_valid) 'string continuity flag accepted'
  }
  $o=New-Observation;$o.error_bound.guaranteed='true';Require (-not(Get-R19UsbClockCorrelation $o).bounds_valid) 'string guaranteed bound accepted'
}
Check 'timesync-codec-roundtrip' {
  $nonce=New-R19TimesyncNonce
  $request=New-R19TimesyncRequest -Nonce $nonce -Sequence 255
  Require ($request.Length-eq28-and$request[0]-eq253-and$request[5]-eq249-and$request[6]-eq193-and$request[7]-eq111) 'canonical request differs'
  $response=[byte[]]$request.Clone();$response[6]=194;[BitConverter]::GetBytes([long]123456789000).CopyTo($response,10)
  $crc=Get-R19TimesyncCrc $response;[BitConverter]::GetBytes([uint16]$crc).CopyTo($response,26)
  $r=ConvertFrom-R19TimesyncResponse -Bytes $response -ExpectedNonce $nonce
  Require ($r.valid-and$r.device_microseconds-ceq'123456789'-and$r.nonce-ceq([string]$nonce)) 'response did not decode exactly'
  foreach($index in 0..27){$bad=[byte[]]$response.Clone();$bad[$index]=$bad[$index]-bxor1;$d=ConvertFrom-R19TimesyncResponse $bad $nonce;Require (-not$d.valid) "bit mutation accepted at $index"}
}
Check 'timesync-max-int64-exact-no-double-rounding' {
  $nonce=[long]0x5219ffffffffffff
  $bytes=New-R19TimesyncRequest $nonce 254;$bytes[6]=194
  [BitConverter]::GetBytes([long]9223372036854775000).CopyTo($bytes,10)
  [BitConverter]::GetBytes([uint16](Get-R19TimesyncCrc $bytes)).CopyTo($bytes,26)
  $r=ConvertFrom-R19TimesyncResponse $bytes $nonce
  Require ($r.valid-and$r.device_microseconds-ceq'9223372036854775') 'int64 ns conversion lost integer precision'
}
Check 'timesync-independent-wide-integer-vectors' {
  $nonce=[long]0x5219000000000001
  foreach($pair in @(
      @('1000','1'),
      @('9007199254740991000','9007199254740991'),
      @('9007199254740992000','9007199254740992'),
      @('9007199254740993000','9007199254740993'),
      @('9223372036854774000','9223372036854774'),
      @('9223372036854775000','9223372036854775'))){
    $bytes=New-R19TimesyncRequest $nonce;$bytes[6]=194
    $ns=[long]::Parse($pair[0],[Globalization.CultureInfo]::InvariantCulture)
    $reference=[Numerics.BigInteger]::Divide([Numerics.BigInteger]::Parse($pair[0]),[Numerics.BigInteger]1000)
    Require ($reference.ToString([Globalization.CultureInfo]::InvariantCulture)-ceq$pair[1]) 'independent reference disagrees with literal expected'
    [BitConverter]::GetBytes($ns).CopyTo($bytes,10)
    [BitConverter]::GetBytes([uint16](Get-R19TimesyncCrc $bytes)).CopyTo($bytes,26)
    $r=ConvertFrom-R19TimesyncResponse $bytes $nonce
    Require ($r.valid-and$r.device_microseconds-ceq$pair[1]) ('wide timestamp precision lost: '+$pair[0])
  }
}
Check 'codec-and-classifier-forbid-interpreter-floating-division' {
  $tokens=$null;$parseErrors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($module,[ref]$tokens,[ref]$parseErrors)
  Require ($parseErrors.Count-eq0) 'module parse errors'
  foreach($functionName in @('ConvertFrom-R19TimesyncResponse','Get-R19UsbClockCorrelation')){
    $function=$ast.Find({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$functionName},$true)
    Require ($null-ne$function) ('function absent: '+$functionName)
    $division=@($function.FindAll({param($node)$node-is[Management.Automation.Language.BinaryExpressionAst]-and$node.Operator-eq[Management.Automation.Language.TokenKind]::Divide},$true))
    Require ($division.Count-eq0) ('interpreter division remains in '+$functionName)
  }
}
Check 'timesync-rehashed-invalid-headers-and-timestamps' {
  $nonce=[long]0x5219000000000001
  foreach($case in @('wrong-source','wrong-component','wrong-message','signed','compat-flag','zero-timestamp','negative-timestamp','fractional-us','nonce-zero-suffix')){
    $bytes=New-R19TimesyncRequest $nonce;$bytes[6]=194;[BitConverter]::GetBytes([long]12345000).CopyTo($bytes,10)
    switch($case){'wrong-source'{$bytes[5]=1}'wrong-component'{$bytes[6]=193}'wrong-message'{$bytes[7]=110}'signed'{$bytes[2]=1}'compat-flag'{$bytes[3]=1}'zero-timestamp'{[BitConverter]::GetBytes([long]0).CopyTo($bytes,10)}'negative-timestamp'{[BitConverter]::GetBytes([long]-1000).CopyTo($bytes,10)}'fractional-us'{[BitConverter]::GetBytes([long]12345001).CopyTo($bytes,10)}'nonce-zero-suffix'{[BitConverter]::GetBytes([long]0x5219000000000000).CopyTo($bytes,18)}}
    [BitConverter]::GetBytes([uint16](Get-R19TimesyncCrc $bytes)).CopyTo($bytes,26)
    Require (-not(ConvertFrom-R19TimesyncResponse $bytes $nonce).valid) "invalid rehashed response accepted $case"
  }
}
Check 'independent-bitwise-crc-reference' {
  $bytes=New-R19TimesyncRequest ([long]0x5219000000000001) 17
  [int]$crc=65535
  foreach($b in @($bytes[1..25])+@(34)){$crc=$crc-bxor[int]$b;for($i=0;$i-lt8;++$i){$crc=if(($crc-band1)-ne0){($crc-shr1)-bxor0x8408}else{$crc-shr1}}}
  Require ($crc-eq[BitConverter]::ToUInt16($bytes,26)) 'CRC reference mismatch'
}
$failed=@($checks|Where-Object{-not$_.passed})
$summary=[ordered]@{schema='vc-lora-r19-usb-clock-correlation-contract-v1';result=$(if($failed.Count){'FAIL'}else{'PASS'});hardware_interaction=$false;passed_count=$checks.Count-$failed.Count;failed_count=$failed.Count;exhaustive_grid_cases=4141;exhaustive_rate_cases=369;checks=@($checks)}
$summary|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json') -Encoding UTF8
$summary|ConvertTo-Json -Depth 10
if($failed.Count){exit 1}
