[CmdletBinding()]
param(
  [string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$OutputDirectory,
  [string]$CppFixturePath,
  [string]$CppOverflowFixturePath,
  [string]$CppEmptyFixturePath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not $OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('runs/validation/R19-AUX-READINESS-DECODER-TEST-001/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+[guid]::NewGuid().ToString('N'))}
[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
$script:checks=0
function Check([bool]$Condition,[string]$Name){$script:checks++;if(-not $Condition){throw "CHECK FAILED: $Name"}}
function PutWord([byte[]]$Bytes,[int]$Section,[int]$Word,[uint32]$Value){[Array]::Copy([BitConverter]::GetBytes($Value),0,$Bytes,$Section*2048+$Word*4,4)}
function PutTime([byte[]]$Bytes,[int]$Section,[int]$Word,[uint64]$Value){[Array]::Copy([BitConverter]::GetBytes($Value),0,$Bytes,$Section*2048+$Word*4,8)}
function NewRecord([uint32]$Role=1){
  [byte[]]$bytes=New-Object byte[] 6144
  [uint32[]]$magics=@(0x5231414F,0x52314145,0x52315552)
  for($section=0;$section-lt3;$section++){
    PutWord $bytes $section 1 2;PutWord $bytes $section 2 $magics[$section];PutWord $bytes $section 3 1;PutWord $bytes $section 4 $Role
    for($i=0;$i-lt4;$i++){PutWord $bytes $section (5+$i) ([uint32](100+$i));PutWord $bytes $section (9+$i) ([uint32](200+$i))}
    PutWord $bytes $section 13 1
  }
  PutWord $bytes 1 16 120
  return ,$bytes
}
function Decode([byte[]]$Bytes,[string]$Role='ground'){
  ConvertFrom-R19AuxReadinessRecord -First $Bytes -Second ([byte[]]$Bytes.Clone()) -ExpectedRole $Role -ExpectedFingerprint @(100,101,102,103) -ExpectedBoot @(200,201,202,203)
}
function Reject([byte[]]$Bytes,[string]$Name){$rejected=$false;try{$null=Decode $Bytes}catch{$rejected=$true};Check $rejected $Name}
try{
  $decoder=Join-Path $RepoRoot 'tools/read_r19_aux_readiness_record.ps1'
  Check (Test-Path -LiteralPath $decoder -PathType Leaf) 'decoder exists'
  . $decoder
  if(-not$CppFixturePath-or-not$CppOverflowFixturePath-or-not$CppEmptyFixturePath){
    $catalog=Get-Content -LiteralPath (Join-Path $RepoRoot 'tests/hil/fixtures/r19_aux_readiness_cpp_fixture_v1.json') -Raw|ConvertFrom-Json
    Check ($catalog.schema-ceq'vc-lora-r19-aux-readiness-cpp-fixtures-v1') 'packaged C++ fixture schema'
    Check ($catalog.generator_source_sha256-ceq(Get-FileHash -LiteralPath (Join-Path $RepoRoot $catalog.generator_source) -Algorithm SHA256).Hash) 'packaged fixture generator source matches'
    Check ($catalog.header_source_sha256-ceq(Get-FileHash -LiteralPath (Join-Path $RepoRoot 'firmware/high_speed/r19_aux_readiness_record.hpp') -Algorithm SHA256).Hash) 'packaged fixture ABI header matches'
    foreach($fixtureRecord in $catalog.records){
      [byte[]]$fixtureBytes=[Convert]::FromBase64String($fixtureRecord.base64)
      $hasher=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($hasher.ComputeHash($fixtureBytes))).Replace('-','')}finally{$hasher.Dispose()}
      Check ($fixtureBytes.Length-eq6144-and$hash-ceq$fixtureRecord.sha256) ('packaged fixture bytes '+$fixtureRecord.name)
      $path=Join-Path $OutputDirectory ('cpp_source_'+$fixtureRecord.name+'.bin');[IO.File]::WriteAllBytes($path,$fixtureBytes)
      switch($fixtureRecord.name){'main'{if(-not$CppFixturePath){$CppFixturePath=$path}}'empty'{if(-not$CppEmptyFixturePath){$CppEmptyFixturePath=$path}}'overflow'{if(-not$CppOverflowFixturePath){$CppOverflowFixturePath=$path}}default{throw 'Unknown packaged C++ fixture'}}
    }
  }
  $base=NewRecord
  $decoded=Decode $base
  Check ($decoded.raw_size_bytes-eq6144) 'exact ABI size'
  Check ($decoded.result-ceq'PASS') 'pure decode pass'
  Check ($decoded.acceptance-ceq'NOT_EVALUATED') 'decode not acceptance'
  Check (-not $decoded.hardware_interaction) 'decode has no hardware access'
  Check ($decoded.aux_busy_vs_observation_delay.verdict-ceq'UNKNOWN') 'no physical conclusion from empty evidence'
  Check ($decoded.aux_observation.first_low_us-eq$null) 'unobserved zero is null'
  $vehicle=Decode (NewRecord 2) 'vehicle';Check ($vehicle.role-ceq'vehicle') 'vehicle role'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 0 0 1;Reject $mutated 'active AUX writer rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 1 1 3;Reject $mutated 'odd ISR sequence rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 2 1 0;Reject $mutated 'uncommitted READY section rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 0 2 1;Reject $mutated 'unknown magic rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 2 3 2;Reject $mutated 'unknown schema rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 1 4 2;Reject $mutated 'cross-section role mismatch rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 2 5 999;Reject $mutated 'cross-section build mismatch rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 1 10 999;Reject $mutated 'cross-section boot mismatch rejected'
  $mutated=[byte[]]$base.Clone();for($s=0;$s-lt3;$s++){for($i=9;$i-lt13;$i++){PutWord $mutated $s $i 0}};Reject $mutated 'zero boot rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 0 13 0x80000001L;Reject $mutated 'unknown AUX flags rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 0 15 1;Reject $mutated 'AUX reserved header rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 0 109 1;Reject $mutated 'AUX reserved body rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 1 29 1;Reject $mutated 'edge reserved rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 2 31 1;Reject $mutated 'READY reserved rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 1 16 119;Reject $mutated 'edge capacity ABI immutable'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 0 17 49;Reject $mutated 'AUX history count bounded'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 1 15 121;Reject $mutated 'edge history count bounded'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 2 17 55;Reject $mutated 'READY history count bounded'
  $badSecond=[byte[]]$base.Clone();$badSecond[6000]=1;$rejected=$false;try{$null=ConvertFrom-R19AuxReadinessRecord -First $base -Second $badSecond -ExpectedRole ground}catch{$rejected=$true};Check $rejected 'two raw reads must exactly match'
  $rejected=$false;try{$null=ConvertFrom-R19AuxReadinessRecord -First ([byte[]]$base[0..6142]) -Second $base -ExpectedRole ground}catch{$rejected=$true};Check $rejected 'truncated record rejected'
  $observed=[byte[]]$base.Clone();PutWord $observed 0 14 1;PutWord $observed 0 16 1;PutWord $observed 0 17 1;PutWord $observed 0 18 1;PutWord $observed 0 45 1;PutWord $observed 0 135 1
  $z=Decode $observed;Check ($z.aux_observation.first_low_us-ceq'0') 'observed MCU time zero retained as string'
  $precision=[uint64]::Parse('18446744073709550000',[Globalization.CultureInfo]::InvariantCulture)
  PutTime $observed 0 20 $precision
  foreach($word in @(24,26,46,128,130)){PutTime $observed 0 $word $precision}
  $p=Decode $observed;Check ($p.aux_observation.first_low_us-ceq$precision.ToString([Globalization.CultureInfo]::InvariantCulture)) 'uint64 precision exact'
  Check (($p|ConvertTo-Json -Depth 30)-match('"'+$precision.ToString()+'"')) 'uint64 JSON encoded as string'
  PutWord $observed 0 30 7;PutWord $observed 0 108 1
  $p=Decode $observed;Check ($p.aux_observation.supplied_runtime_now_ms-ceq'4294967303') 'independent supplied runtime millisecond uint64 exact'
  $intervalOnly=[byte[]]$base.Clone();PutWord $intervalOnly 2 32 2;PutTime $intervalOnly 2 33 10;PutTime $intervalOnly 2 35 30;PutTime $intervalOnly 2 37 20;PutWord $intervalOnly 2 39 1;PutTime $intervalOnly 2 20 30
  PutTime $intervalOnly 2 40 10;PutTime $intervalOnly 2 42 30
  $intervalResult=Decode $intervalOnly
  Check ($intervalResult.usb_readiness.event_count-eq0-and$intervalResult.usb_readiness.intervals[0].count-eq2) 'intervals do not fabricate READY events'
  Check ($intervalResult.usb_readiness.last_observation_us-ceq'30') 'interval-only last observation retained'
  Check ($intervalResult.usb_readiness.intervals[0].early_return_count-eq1) 'private early-return count retained'
  $mutated=[byte[]]$intervalOnly.Clone();PutWord $mutated 2 39 3;Reject $mutated 'interval early-return accounting rejected'
  $mutated=[byte[]]$intervalOnly.Clone();PutTime $mutated 2 37 19;Reject $mutated 'interval maximum duration contradiction rejected'
  $mutated=[byte[]]$intervalOnly.Clone();PutTime $mutated 2 33 31;Reject $mutated 'interval backward bracket rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 0 43 5;PutWord $mutated 0 50 5;Reject $mutated 'fault snapshot cannot exist without latch'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 0 34 2;PutWord $mutated 0 33 1;Reject $mutated 'UART written cannot exceed requested'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 0 45 1;Reject $mutated 'GPIO observed flag requires polling'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 0 97 1;Reject $mutated 'transaction observations require transaction'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 2 28 1;PutTime $mutated 2 24 100
  Reject $mutated 'ARM stage cannot exist without event accounting'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 2 14 1;Reject $mutated 'READY duplicate event count mismatch rejected'
  $mutated=[byte[]]$base.Clone();PutWord $mutated 0 19 1;Reject $mutated 'AUX replacement count must match total events'
  $failedPublish=[byte[]]$base.Clone();PutWord $failedPublish 2 14 1;PutWord $failedPublish 2 16 1;PutWord $failedPublish 2 17 1;PutWord $failedPublish 2 19 6;PutTime $failedPublish 2 20 100;PutTime $failedPublish 2 80 100;PutWord $failedPublish 2 82 6;PutWord $failedPublish 2 87 1
  $failedPublishResult=Decode $failedPublish
  Check ($failedPublishResult.usb_readiness.last_ready_publish_us-eq$null) 'failed READY return does not latch publish success'
  if($CppFixturePath){
    [byte[]]$cpp=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $CppFixturePath))
    $cppResult=ConvertFrom-R19AuxReadinessRecord -First $cpp -Second ([byte[]]$cpp.Clone()) -ExpectedRole ground
    Check ($cppResult.result-ceq'PASS') 'real C++ ABI fixture decodes'
    Check ($cppResult.acceptance-ceq'NOT_EVALUATED') 'C++ fixture not live proof'
    Check ($cppResult.aux_observation.first_fault.code-eq5) 'C++ first fault retained'
    Check ($cppResult.aux_observation.maximum_poll_gap_us-ceq'1999999') 'C++ poll gap exact'
    Check ($cppResult.aux_edges.history[-1].timestamp_us-ceq'1000') 'C++ independent IRQ edge exact'
    Check ($cppResult.aux_observation.transaction_first_high_us-ceq'2000111') 'C++ late poll edge exact'
    Check ($cppResult.aux_busy_vs_observation_delay.verdict-ceq'UNKNOWN') 'ISR observation is not continuous waveform proof'
    Check (-not$cppResult.usb_readiness.arm_protocol_success_proven) 'MCU ARM event is not E2E protocol proof'
    [byte[]]$withInterval=$cpp.Clone();PutWord $withInterval 2 32 1;PutTime $withInterval 2 33 200;PutTime $withInterval 2 35 1000;PutTime $withInterval 2 37 800;PutWord $withInterval 2 39 1;PutTime $withInterval 2 40 200;PutTime $withInterval 2 42 1000
    $comparison=ConvertFrom-R19AuxReadinessRecord -First $withInterval -Second ([byte[]]$withInterval.Clone()) -ExpectedRole ground
    Check ($comparison.usb_vs_aux_observation_gap.intervals[0].intersection_us-ceq'800') 'same-MCU interval intersection exact'
    Check ($comparison.usb_vs_aux_observation_gap.intervals[0].classification-ceq'OBSERVED_INTERVAL_OVERLAP_NOT_CAUSAL') 'overlap not promoted to causation'
    PutTime $withInterval 2 33 2000200;PutTime $withInterval 2 35 2000300;PutTime $withInterval 2 37 100;PutTime $withInterval 2 40 2000200;PutTime $withInterval 2 42 2000300
    $comparison=ConvertFrom-R19AuxReadinessRecord -First $withInterval -Second ([byte[]]$withInterval.Clone()) -ExpectedRole ground
    Check ($comparison.usb_vs_aux_observation_gap.intervals[0].classification-ceq'NOT_COMPARABLE_POST_FAULT'-and$comparison.usb_vs_aux_observation_gap.intervals[0].intersection_us-eq$null) 'post-fault maximum interval cannot explain frozen fault'
    [byte[]]$cppNormalized=$cpp.Clone()
    for($s=0;$s-lt3;$s++){for($j=0;$j-lt4;$j++){PutWord $cppNormalized $s (5+$j) ([uint32](100+$j));PutWord $cppNormalized $s (9+$j) ([uint32](200+$j))}}
    $mutated=[byte[]]$cppNormalized.Clone();PutWord $mutated 0 135 99;Reject $mutated 'unknown AUX event enum rejected'
    $mutated=[byte[]]$cppNormalized.Clone();PutWord $mutated 1 34 2;Reject $mutated 'ISR history GPIO not boolean rejected'
    $mutated=[byte[]]$cppNormalized.Clone();PutWord $mutated 2 82 13;Reject $mutated 'unknown READY event enum rejected'
    $mutated=[byte[]]$cppNormalized.Clone();PutTime $mutated 0 106 2000112;Reject $mutated 'maximum GPIO gap bracket mismatch rejected'
    $mutated=[byte[]]$cppNormalized.Clone();PutWord $mutated 0 50 6;Reject $mutated 'first fault cannot disagree with latched code'
    $mutated=[byte[]]$cppNormalized.Clone();PutWord $mutated 0 52 3;Reject $mutated 'snapshot count cannot exceed current count'
    $mutated=[byte[]]$cppNormalized.Clone();PutTime $mutated 1 20 99;Reject $mutated 'ISR first timestamp summary mismatch rejected'
    $mutated=[byte[]]$cppNormalized.Clone();PutWord $mutated 2 87 0;Reject $mutated 'READY event sequence zero rejected'
    $mutated=[byte[]]$cppNormalized.Clone();PutWord $mutated 1 13 65;Reject $mutated 'ISR overflow requires dropped count'
    $cppResult|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $OutputDirectory 'cpp_fixture_decoded.json') -Encoding UTF8
  }
  if($CppOverflowFixturePath){
    [byte[]]$overflow=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $CppOverflowFixturePath))
    $overflowResult=ConvertFrom-R19AuxReadinessRecord -First $overflow -Second ([byte[]]$overflow.Clone()) -ExpectedRole ground
    Check ($overflowResult.aux_observation.history_wraps-gt0) 'real C++ AUX wrap retained'
    Check ($overflowResult.aux_edges.overflow_count-gt0) 'real C++ ISR overflow retained'
    Check ($overflowResult.usb_readiness.dropped_events-gt0) 'real C++ READY drops retained'
    Check ($overflowResult.aux_busy_vs_observation_delay.verdict-ceq'UNKNOWN') 'overflow cannot prove physical Busy/delay'
    $overflowResult|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $OutputDirectory 'cpp_overflow_decoded.json') -Encoding UTF8
  }
  if($CppEmptyFixturePath){
    [byte[]]$empty=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $CppEmptyFixturePath))
    $emptyResult=ConvertFrom-R19AuxReadinessRecord -First $empty -Second ([byte[]]$empty.Clone()) -ExpectedRole ground
    Check ($emptyResult.aux_observation.first_low_us-eq$null-and$emptyResult.aux_edges.first_low_us-eq$null) 'real C++ empty observation is unknown, not time zero'
    Check ($emptyResult.aux_busy_vs_observation_delay.verdict-ceq'UNKNOWN') 'empty ISR cannot prove no transition'
  }
  $summary=[ordered]@{schema='vc-lora-r19-aux-readiness-decoder-test-v1';result='PASS';checks=$script:checks;ps_version=$PSVersionTable.PSVersion.ToString();hardware_interaction=$false;cpp_fixture=$CppFixturePath;output=$OutputDirectory}
  $summary|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding UTF8
  Write-Output ('R19_AUX_READINESS_RECORD PASS '+$script:checks+' checks output='+$OutputDirectory)
}catch{
  [ordered]@{schema='vc-lora-r19-aux-readiness-decoder-test-v1';result='FAIL';checks=$script:checks;ps_version=$PSVersionTable.PSVersion.ToString();hardware_interaction=$false;error=$_.Exception.Message}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding UTF8
  throw
}
