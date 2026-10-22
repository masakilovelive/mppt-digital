# Pure decoder only. Dot-sourcing defines a function; it performs no device or file I/O.
function ConvertFrom-R19AuxReadinessRecord {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$First,
    [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Second,
    [Parameter(Mandatory)][ValidateSet('ground','vehicle')][string]$ExpectedRole,
    [AllowNull()][object[]]$ExpectedFingerprint,
    [AllowNull()][object[]]$ExpectedBoot
  )
  $ErrorActionPreference='Stop'
  Set-StrictMode -Version Latest
  function Require([bool]$Condition,[string]$Message){if(-not $Condition){throw ('AUX/READY record rejected: '+$Message)}}
  function Time([int]$Section,[int]$Word){return [BitConverter]::ToUInt64($First,$Section*2048+$Word*4)}
  function TextTime([int]$Section,[int]$Word){return (Time $Section $Word).ToString([Globalization.CultureInfo]::InvariantCulture)}
  function SplitTimeText([uint32]$Low,[uint32]$High){return (([uint64]$High-shl32)-bor[uint64]$Low).ToString([Globalization.CultureInfo]::InvariantCulture)}
  function MaybeTime([bool]$Observed,[int]$Section,[int]$Word){if($Observed){return TextTime $Section $Word};return $null}
  function ZeroWords([uint32[]]$Words,[int]$Start,[int]$End,[string]$Name){for($z=$Start;$z-le$End;$z++){Require ($Words[$z]-eq0) ($Name+' word '+$z+' is not zero')}}
  function Identity([object[]]$Expected,[uint32[]]$Words,[int]$Offset,[string]$Name){
    Require (@($Expected).Count-eq4) ($Name+' requires four uint32 words')
    for($j=0;$j-lt4;$j++){
      [decimal]$n=$Expected[$j]
      Require ($n-ge0-and$n-le[uint32]::MaxValue-and$n-eq[math]::Floor($n)) ($Name+' is not uint32')
      Require ([uint32]$n-eq$Words[$Offset+$j]) ($Name+' mismatch')
    }
  }
  Require ($First.Length-eq6144-and$Second.Length-eq6144) 'two exact 6144-byte reads required'
  # Base64 is an injective byte encoding: this compares every byte exactly, not
  # a digest or numeric coercion, without 6144 interpreted function invocations.
  if([Convert]::ToBase64String($First)-cne[Convert]::ToBase64String($Second)){
    for($i=0;$i-lt6144;$i++){if($First[$i]-ne$Second[$i]){Require $false ('two reads differ at byte '+$i)}}
  }
  $sections=@()
  [uint32[]]$magics=@(0x5231414F,0x52314145,0x52315552)
  [string[]]$names=@('aux_observation','aux_edges','usb_readiness')
  $roleCode=if($ExpectedRole-ceq'ground'){1}else{2}
  for($section=0;$section-lt3;$section++){
    [uint32[]]$words=New-Object uint32[] 512
    for($i=0;$i-lt512;$i++){$words[$i]=[BitConverter]::ToUInt32($First,$section*2048+$i*4)}
    Require ($words[0]-eq0-and($words[1]-ne0-or($words[13]-band32)-ne0)-and($words[1]-band1)-eq0) ($names[$section]+' active writer, odd or uncommitted sequence')
    Require ($words[2]-eq$magics[$section]-and$words[3]-eq1) ($names[$section]+' unknown magic/schema')
    Require ($words[4]-eq$roleCode) ($names[$section]+' role mismatch')
    Require (($words[13]-band1)-ne0) ($names[$section]+' uninitialized')
    [uint32]$knownFlags=if($section-eq1){127}else{63}
    Require (($words[13]-band(-bnot$knownFlags))-eq0) ($names[$section]+' unknown flags')
    Require (($words[9]-bor$words[10]-bor$words[11]-bor$words[12])-ne0) ($names[$section]+' zero boot identity')
    if($section-eq0){
      if($null-ne$ExpectedFingerprint){Identity $ExpectedFingerprint $words 5 'expected build'}
      if($null-ne$ExpectedBoot){Identity $ExpectedBoot $words 9 'expected boot'}
    }else{
      for($i=5;$i-le12;$i++){Require ($words[$i]-eq$sections[0][$i]) 'cross-section build/boot mismatch'}
    }
    $sections+=,$words
  }
  [uint32[]]$aux=$sections[0];[uint32[]]$edges=$sections[1];[uint32[]]$ready=$sections[2]
  Require ($aux[15]-eq0) 'AUX reserved header'
  ZeroWords $aux 78 79 'AUX fault reserved';ZeroWords $aux 93 95 'AUX fault reserved';ZeroWords $aux 109 127 'AUX live reserved'
  Require ($aux[17]-le48-and$aux[18]-lt48) 'AUX ring used/next bounds'
  if(($aux[13]-band4)-eq0){
    Require ($aux[17]-eq[math]::Min([uint64]$aux[14],[uint64]48)-and$aux[18]-eq($aux[14]%48)) 'AUX history/event accounting inconsistent'
    Require ([uint64]$aux[19]-eq([math]::Max([int64]$aux[14]-48,[int64]0))) 'AUX replacement count inconsistent'
    Require ([uint64]$aux[14]-eq([uint64]$aux[16]+[uint64]$aux[32]+[uint64]$aux[42]+[uint64]$aux[44])) 'AUX type counters inconsistent'
  }
  if($aux[19]-gt0){Require (($aux[13]-band8)-ne0) 'AUX wrap has no coverage-loss flag'}
  Require ($aux[31]-le1-and$aux[65]-le1) 'AUX level not boolean'
  Require ($aux[34]-le$aux[33]-and$aux[67]-le$aux[66]) 'UART byte accounting invalid'
  Require ($aux[44]-le1) 'fault latch not boolean'
  Require (($aux[45]-band0xFFFFFFF8L)-eq0-and($aux[77]-band0xFFFFFFF8L)-eq0) 'unknown AUX observation bits'
  Require (($aux[97]-band0xFFFFFFFCL)-eq0-and($aux[81]-band0xFFFFFFFCL)-eq0) 'unknown transaction observation bits'
  foreach($spec in @(@(1,20),@(2,22),@(4,40))){if(($aux[45]-band$spec[0])-eq0){Require ((Time 0 $spec[1])-eq0) 'unobserved AUX timestamp nonzero'}}
  if(($aux[45]-band3)-ne0){Require ($aux[16]-gt0) 'AUX first GPIO observation lacks polling'}
  if(($aux[45]-band4)-ne0){Require ($aux[32]-gt0) 'UART acceptance lacks a call'}
  if($aux[16]-gt0){Require ((Time 0 26)-ge(Time 0 24)) 'GPIO read bracket reversed'}
  else{ZeroWords $aux 24 31 'unobserved GPIO polling'}
  if($aux[32]-gt0){Require ((Time 0 38)-ge(Time 0 36)) 'UART bracket reversed'}
  else{ZeroWords $aux 33 34 'unobserved UART';ZeroWords $aux 36 41 'unobserved UART'}
  if((Time 0 28)-gt0){Require ((Time 0 106)-ge(Time 0 104)) 'maximum poll gap bracket reversed';Require (((Time 0 106)-(Time 0 104))-eq(Time 0 28)) 'maximum poll gap does not match bracket'}
  else{Require ((Time 0 104)-eq0-and(Time 0 106)-eq0) 'zero maximum gap has nonzero bracket'}
  if($aux[96]-eq0){ZeroWords $aux 97 103 'unobserved transaction'}
  foreach($spec in @(@(1,100),@(2,102))){if(($aux[97]-band$spec[0])-eq0){Require ((Time 0 $spec[1])-eq0) 'unobserved transaction edge time nonzero'}}
  $faultLatched=$aux[44]-ne0
  if(-not$faultLatched){Require ($aux[43]-eq0) 'unlatched fault code nonzero';ZeroWords $aux 48 95 'unlatched fault'}
  else{
    Require ($aux[50]-ne0-and$aux[43]-eq$aux[50]) 'latched fault code inconsistent'
    Require ((Time 0 60)-ge(Time 0 58)-and(Time 0 70)-ge(Time 0 68)) 'fault snapshot bracket reversed'
    Require ((Time 0 48)-ge(Time 0 60)-and(Time 0 48)-ge(Time 0 70)) 'fault snapshot observations postdate fault'
    Require (($aux[74]-band0xFFFFFFC0L)-eq0-and($aux[74]-band1)-ne0) 'fault snapshot flags invalid'
    Require ($aux[52]-le$aux[16]-and$aux[53]-le$aux[32]-and$aux[75]-le$aux[42]-and$aux[76]-le$aux[14]) 'fault snapshot counters exceed live counters'
    foreach($spec in @(@(1,54),@(2,56),@(4,72))){if(($aux[77]-band$spec[0])-eq0){Require ((Time 0 $spec[1])-eq0) 'unobserved fault timestamp nonzero'}}
    if((Time 0 62)-gt0){Require ((Time 0 90)-ge(Time 0 88)) 'fault gap bracket reversed';Require (((Time 0 90)-(Time 0 88))-eq(Time 0 62)) 'fault gap bracket mismatch'}
    if($aux[80]-eq0){ZeroWords $aux 81 87 'unobserved fault transaction'}
    foreach($spec in @(@(1,84),@(2,86))){if(($aux[81]-band$spec[0])-eq0){Require ((Time 0 $spec[1])-eq0) 'unobserved fault transaction edge nonzero'}}
  }
  $auxHistory=@();$lastBegin=$null;$auxKinds=@('Unknown','GpioPoll','UartWrite','BackendState','FirstFault')
  $start=if($aux[17]-eq48){[int]$aux[18]}else{0}
  for($i=0;$i-lt[int]$aux[17];$i++){
    $slot=($start+$i)%48;$at=128+$slot*8
    [uint64]$begin=Time 0 $at;[uint64]$end=Time 0 ($at+2)
    $kind=$aux[$at+7]
    Require ($kind-ge1-and$kind-le4) 'unknown AUX history event'
    Require ($end-ge$begin) 'AUX history bracket reversed'
    if($null-ne$lastBegin){Require ($begin-ge$lastBegin) 'AUX committed history clock is nonmonotonic'}
    if($kind-eq1){Require ($aux[$at+5]-le1) 'GPIO history level invalid'}
    if($kind-eq2){Require ($aux[$at+5]-le$aux[$at+4]) 'UART history accepted exceeds requested'}
    $auxHistory+=[pscustomobject][ordered]@{ring_slot=$slot;kind=$kind;name=$auxKinds[$kind];begin_us=$begin.ToString();end_us=$end.ToString();a=$aux[$at+4];b=$aux[$at+5];c=$aux[$at+6]}
    $lastBegin=$begin
  }
  if($aux[17]-lt48){Require ($aux[18]-eq$aux[17]) 'partial AUX ring next index inconsistent';ZeroWords $aux (128+[int]$aux[17]*8) 511 'unused AUX history'}
  Require ($edges[15]-le120-and$edges[16]-eq120) 'ISR capacity/used invalid'
  Require ($edges[18]-le1-and($edges[19]-band0xFFFFFFF8L)-eq0) 'ISR initial level or observation bits invalid'
  Require ($edges[29]-eq0) 'ISR reserved word nonzero'
  Require ((($edges[13]-band64)-ne0)-eq($edges[17]-gt0)) 'ISR overflow flag/count inconsistent'
  if(($edges[13]-band4)-eq0){Require ([uint64]$edges[14]-eq([uint64]$edges[15]+[uint64]$edges[17])-and$edges[28]-eq$edges[14]) 'ISR count/sequence accounting invalid'}
  if($edges[17]-gt0){Require ($edges[15]-eq120-and($edges[13]-band8)-ne0) 'ISR overflow lacks full history/coverage loss'}
  foreach($spec in @(@(1,24),@(2,26),@(4,20))){if(($edges[19]-band$spec[0])-eq0){Require ((Time 1 $spec[1])-eq0) 'unobserved ISR time nonzero'}}
  $edgeHistory=@();$previousTime=$null;$previousSequence=[uint32]0
  for($i=0;$i-lt[int]$edges[15];$i++){
    $at=32+$i*4;[uint64]$edgeTime=Time 1 $at;$level=$edges[$at+2];$edgeSequence=$edges[$at+3]
    Require ($level-le1-and$edgeSequence-ne0) 'ISR event level/sequence invalid'
    Require ($edgeTime-ge(Time 1 30)) 'ISR event precedes initialization'
    if($null-ne$previousTime){Require ($edgeTime-ge$previousTime) 'ISR committed clock nonmonotonic'}
    if(($edges[13]-band36)-eq0){Require ($edgeSequence-gt$previousSequence) 'ISR sequence nonmonotonic'}
    $edgeHistory+=[pscustomobject][ordered]@{slot=$i;timestamp_us=$edgeTime.ToString();level=$level;sequence=$edgeSequence}
    $previousTime=$edgeTime;$previousSequence=$edgeSequence
  }
  if($edges[15]-eq0){Require (($edges[19]-band4)-eq0-and$edges[28]-eq0) 'empty ISR history claims an edge'}
  else{
    Require (($edges[19]-band4)-ne0) 'ISR events lack observed flag'
    Require ((Time 1 20)-eq[uint64]$edgeHistory[0].timestamp_us) 'ISR first edge summary mismatch'
    if($edges[17]-eq0){Require ((Time 1 22)-eq[uint64]$edgeHistory[-1].timestamp_us-and$edges[28]-eq$edgeHistory[-1].sequence) 'ISR last edge summary mismatch'}
  }
  if($edges[15]-lt120){ZeroWords $edges (32+[int]$edges[15]*4) 511 'unused ISR history'}
  Require ($ready[15]-eq0) 'READY reserved header nonzero'
  Require ($ready[17]-le54-and$ready[19]-le12-and($ready[28]-band0xFFFFFFFCL)-eq0) 'READY count/event/observation bits invalid'
  Require ($ready[14]-eq$ready[16]) 'READY common event count mismatch'
  if(($ready[13]-band4)-eq0){Require ([uint64]$ready[16]-eq([uint64]$ready[17]+[uint64]$ready[18])) 'READY stored/dropped accounting invalid'}
  ZeroWords $ready 29 31 'READY reserved'
  if($ready[18]-gt0){Require ($ready[17]-eq54-and($ready[13]-band8)-ne0) 'READY overflow lacks history/coverage loss'}
  foreach($spec in @(@(1,24),@(2,26))){if(($ready[28]-band$spec[0])-eq0){Require ((Time 2 $spec[1])-eq0) 'unobserved READY stage timestamp nonzero'}}
  $intervals=@();$intervalNames=@('PrivateReply','RuntimeDiagnostic','AliveDrain','Loop')
  for($i=0;$i-lt4;$i++){
    $at=32+$i*12;$count=$ready[$at];[uint64]$begin=Time 2 ($at+1);[uint64]$end=Time 2 ($at+3);[uint64]$maximum=Time 2 ($at+5);$early=$ready[$at+7]
    [uint64]$maximumBegin=Time 2 ($at+8);[uint64]$maximumEnd=Time 2 ($at+10)
    if($count-eq0){ZeroWords $ready ($at+1) ($at+11) 'unobserved interval'}
    else{Require ($end-ge$begin) 'USB interval bracket reversed';Require ($maximum-ge($end-$begin)) 'interval maximum shorter than latest duration';Require ($early-le$count) 'interval early-return count exceeds count';Require ($maximumEnd-ge$maximumBegin-and($maximumEnd-$maximumBegin)-eq$maximum) 'maximum interval bracket mismatch'}
    $intervals+=[pscustomobject][ordered]@{kind=$i;name=$intervalNames[$i];count=$count;last_begin_us=if($count){$begin.ToString()}else{$null};last_end_us=if($count){$end.ToString()}else{$null};maximum_duration_us=$maximum.ToString();maximum_begin_us=if($count){$maximumBegin.ToString()}else{$null};maximum_end_us=if($count){$maximumEnd.ToString()}else{$null};early_return_count=$early}
  }
  $eventNames=@('Unknown','ClockFlushBegin','ClockFlushEnd','GateUpdate','ReadyEncode','ReadyPublishBegin','ReadyPublishEnd','ArmReceived','ArmAccepted','IrqAttach','GateReset','ReadySuppressed','ClockFlushContext')
  $readyHistory=@();$previousTime=$null;$previousSequence=[uint32]0
  for($i=0;$i-lt[int]$ready[17];$i++){
    $at=80+$i*8;[uint64]$eventTime=Time 2 $at;$kind=$ready[$at+2];$eventSequence=$ready[$at+7]
    Require ($kind-ge1-and$kind-le12-and$eventSequence-ne0) 'READY history unknown event or zero sequence'
    if($null-ne$previousTime){Require ($eventTime-ge$previousTime) 'READY committed clock nonmonotonic'}
    if(($ready[13]-band36)-eq0){Require ($eventSequence-gt$previousSequence) 'READY sequence nonmonotonic'}
    $readyHistory+=[pscustomobject][ordered]@{slot=$i;timestamp_us=$eventTime.ToString();kind=$kind;name=$eventNames[$kind];a=$ready[$at+3];b=$ready[$at+4];c=$ready[$at+5];d=$ready[$at+6];sequence=$eventSequence;clock_context_budget_ms=if($kind-eq12){$ready[$at+3]}else{$null};clock_context_expected_epoch=if($kind-eq12){$ready[$at+4]}else{$null};clock_context_deadline_us=if($kind-eq12){SplitTimeText $ready[$at+5] $ready[$at+6]}else{$null}}
    $previousTime=$eventTime;$previousSequence=$eventSequence
  }
  if($ready[17]-eq0){Require ($ready[19]-eq0) 'empty READY history has last event type'}
  if($ready[16]-eq0-and$ready[32]-eq0-and$ready[44]-eq0-and$ready[56]-eq0-and$ready[68]-eq0){Require ((Time 2 20)-eq0) 'unobserved READY last time nonzero'}
  if($ready[17]-lt54){ZeroWords $ready (80+[int]$ready[17]*8) 511 'unused READY history'}
  if($ready[18]-eq0){
    $armEvents=@($readyHistory|Where-Object {$_.kind-eq8-and$_.a-ne0});$publishEvents=@($readyHistory|Where-Object {$_.kind-eq6-and$_.a-ne0})
    Require ((($ready[28]-band1)-ne0)-eq($armEvents.Count-gt0)) 'ARM observation flag/event accounting inconsistent'
    Require ((($ready[28]-band2)-ne0)-eq($publishEvents.Count-gt0)) 'READY publish observation flag/event accounting inconsistent'
    if($armEvents.Count){Require ((Time 2 24)-eq[uint64]$armEvents[0].timestamp_us) 'first ARM timestamp mismatch'}
    if($publishEvents.Count){Require ((Time 2 26)-eq[uint64]$publishEvents[-1].timestamp_us) 'last READY publish timestamp mismatch'}
    if($readyHistory.Count){Require ($ready[19]-eq$readyHistory[-1].kind-and(Time 2 20)-ge[uint64]$readyHistory[-1].timestamp_us) 'READY latest summary mismatch'}
  }
  $irqAttach=@($readyHistory|Where-Object {$_.kind-eq9})
  $sha=[Security.Cryptography.SHA256]::Create();try{$rawSha=([BitConverter]::ToString($sha.ComputeHash($First))).Replace('-','')}finally{$sha.Dispose()}
  $snapshot=if($faultLatched){[pscustomobject][ordered]@{
    timestamp_us=TextTime 0 48;code=$aux[50];state=$aux[51];poll_count=$aux[52];uart_calls=$aux[53]
    first_low_us=MaybeTime (($aux[77]-band1)-ne0) 0 54;first_high_us=MaybeTime (($aux[77]-band2)-ne0) 0 56
    last_poll_begin_us=MaybeTime ($aux[52]-gt0) 0 58;last_poll_end_us=MaybeTime ($aux[52]-gt0) 0 60;maximum_poll_gap_us=TextTime 0 62
    supplied_runtime_now_ms=if($aux[52]){SplitTimeText $aux[64] $aux[92]}else{$null};last_aux_level=$aux[65];last_requested_bytes=$aux[66];last_written_bytes=$aux[67];last_uart_begin_us=MaybeTime ($aux[53]-gt0) 0 68;last_uart_end_us=MaybeTime ($aux[53]-gt0) 0 70
    first_accepted_us=MaybeTime (($aux[77]-band4)-ne0) 0 72;flags=$aux[74];state_changes=$aux[75];event_count=$aux[76]
    transaction_sequence=$aux[80];transaction_accepted_us=MaybeTime ($aux[80]-gt0) 0 82;transaction_first_low_us=MaybeTime (($aux[81]-band1)-ne0) 0 84;transaction_first_high_us=MaybeTime (($aux[81]-band2)-ne0) 0 86
    maximum_gap_previous_end_us=MaybeTime ((Time 0 62)-gt0) 0 88;maximum_gap_next_begin_us=MaybeTime ((Time 0 62)-gt0) 0 90
  }}else{$null}
  $comparisonRows=@();$gapPresent=$faultLatched-and(Time 0 62)-gt0
  $gapTransactionRelation='UNKNOWN'
  if($gapPresent-and$aux[80]-gt0){
    if((Time 0 90)-lt(Time 0 82)){$gapTransactionRelation='PREVIOUS_TRANSACTION_INTERVAL'}
    elseif((Time 0 88)-ge(Time 0 82)){$gapTransactionRelation='WITHIN_CURRENT_FAULT_TRANSACTION'}
    else{$gapTransactionRelation='STRADDLES_TRANSACTION_ACCEPTANCE'}
  }
  foreach($interval in $intervals){
    $classification='UNKNOWN';$intersection=$null
    if($gapPresent-and$interval.count-gt0){
      [uint64]$intervalBegin=[uint64]$interval.maximum_begin_us;[uint64]$intervalEnd=[uint64]$interval.maximum_end_us
      if($intervalEnd-gt(Time 0 48)){$classification='NOT_COMPARABLE_POST_FAULT'}
      elseif(($aux[74]-band30)-ne0-or($ready[13]-band22)-ne0){$classification='NOT_COMPARABLE_TAINTED_CLOCK_OR_COUNTERS'}
      else{
        [uint64]$gapBegin=Time 0 88;[uint64]$gapEnd=Time 0 90
        [uint64]$overlapBegin=if($gapBegin-ge$intervalBegin){$gapBegin}else{$intervalBegin}
        [uint64]$overlapEnd=if($gapEnd-le$intervalEnd){$gapEnd}else{$intervalEnd}
        [uint64]$overlap=if($overlapEnd-gt$overlapBegin){$overlapEnd-$overlapBegin}else{0}
        $intersection=$overlap.ToString([Globalization.CultureInfo]::InvariantCulture)
        $classification=if($overlap-gt0){'OBSERVED_INTERVAL_OVERLAP_NOT_CAUSAL'}else{'OBSERVED_INTERVALS_DISJOINT_NOT_CAUSAL'}
      }
    }
    $comparisonRows+=[pscustomobject][ordered]@{kind=$interval.kind;name=$interval.name;classification=$classification;intersection_us=$intersection;maximum_begin_us=$interval.maximum_begin_us;maximum_end_us=$interval.maximum_end_us;maximum_duration_us=$interval.maximum_duration_us;early_return_count=$interval.early_return_count}
  }
  return [pscustomobject][ordered]@{
    schema='vc-lora-r19-aux-readiness-decoded-v1';result='PASS';mode='offline-only';hardware_interaction=$false;raw_size_bytes=6144;raw_sha256=$rawSha
    record_symbol='vc_lora_r19_aux_readiness_record';record_schema=1;role=$ExpectedRole;build_fingerprint=@($aux[5..8]);boot_instance=@($aux[9..12])
    section_sequences=[pscustomobject]@{aux=$aux[1];edges=$edges[1];ready=$ready[1]}
    aux_observation=[pscustomobject][ordered]@{
      flags=$aux[13];event_count=$aux[14];poll_count=$aux[16];history_used=$aux[17];history_next=$aux[18];history_wraps=$aux[19];history_capacity=48
      first_low_us=MaybeTime (($aux[45]-band1)-ne0) 0 20;first_high_us=MaybeTime (($aux[45]-band2)-ne0) 0 22
      last_gpio_begin_us=MaybeTime ($aux[16]-gt0) 0 24;last_gpio_end_us=MaybeTime ($aux[16]-gt0) 0 26;maximum_poll_gap_us=TextTime 0 28;supplied_runtime_now_ms=if($aux[16]){SplitTimeText $aux[30] $aux[108]}else{$null};last_aux_level=if($aux[16]){$aux[31]}else{$null}
      uart_calls=$aux[32];last_requested_bytes=$aux[33];last_written_bytes=$aux[34];last_backend_state=$aux[35]
      last_uart_begin_us=MaybeTime ($aux[32]-gt0) 0 36;last_uart_end_us=MaybeTime ($aux[32]-gt0) 0 38;first_accepted_us=MaybeTime (($aux[45]-band4)-ne0) 0 40
      state_changes=$aux[42];fault_code=$aux[43];first_fault_latched=$faultLatched;first_fault=$snapshot
      transaction_sequence=$aux[96];transaction_accepted_us=MaybeTime ($aux[96]-gt0) 0 98;transaction_first_low_us=MaybeTime (($aux[97]-band1)-ne0) 0 100;transaction_first_high_us=MaybeTime (($aux[97]-band2)-ne0) 0 102
      maximum_gap_previous_end_us=MaybeTime ((Time 0 28)-gt0) 0 104;maximum_gap_next_begin_us=MaybeTime ((Time 0 28)-gt0) 0 106;history=$auxHistory
    }
    aux_edges=[pscustomobject][ordered]@{flags=$edges[13];event_count=$edges[14];history_used=$edges[15];history_capacity=120;overflow_count=$edges[17];initial_level=$edges[18];initial_us=TextTime 1 30;first_edge_us=MaybeTime (($edges[19]-band4)-ne0) 1 20;last_edge_us=MaybeTime (($edges[19]-band4)-ne0) 1 22;first_low_us=MaybeTime (($edges[19]-band1)-ne0) 1 24;first_high_us=MaybeTime (($edges[19]-band2)-ne0) 1 26;last_edge_sequence=$edges[28];history=$edgeHistory;irq_attach_events=$irqAttach;continuous_interrupt_coverage_proven=$false}
    usb_readiness=[pscustomobject][ordered]@{flags=$ready[13];event_count=$ready[16];history_used=$ready[17];history_capacity=54;dropped_events=$ready[18];last_event_kind=$ready[19];last_observation_us=MaybeTime (($ready[16]-gt0)-or($ready[32]-gt0)-or($ready[44]-gt0)-or($ready[56]-gt0)-or($ready[68]-gt0)) 2 20;epoch=$ready[22];gate_flags=$ready[23];first_arm_us=MaybeTime (($ready[28]-band1)-ne0) 2 24;last_ready_publish_us=MaybeTime (($ready[28]-band2)-ne0) 2 26;intervals=$intervals;history=$readyHistory;ready_received_by_pc_proven=$false;arm_protocol_success_proven=$false}
    usb_vs_aux_observation_gap=[pscustomobject][ordered]@{first_fault_gap_available=$gapPresent;first_fault_gap_begin_us=MaybeTime $gapPresent 0 88;first_fault_gap_end_us=MaybeTime $gapPresent 0 90;first_fault_gap_us=MaybeTime $gapPresent 0 62;gap_relation_to_fault_transaction=$gapTransactionRelation;intervals=$comparisonRows;root_cause_proven=$false;limitation='Compares separately recorded maximum intervals only. Overlap is not causation; maxima can belong to different transactions and unrecorded shorter intervals may overlap.'}
    aux_busy_vs_observation_delay=[pscustomobject][ordered]@{verdict='UNKNOWN';physical_busy_proven=$false;observation_delay_root_cause_proven=$false;reasons=@('ISR events show observed digital transitions only; continuous interrupt and physical waveform coverage are not independently proven.','Ordinal/event sequence is not physical ordering across independent writers; compare same-clock brackets and retain overlaps as ambiguous.','AUX LOW alone is not proof of RF airtime or E220 hardware failure.')}
    acceptance='NOT_EVALUATED';root_cause_proven=$false;acceptance_authorized=$false;deployment_authorized=$false
    limitations=@('Committed duplicate record decoding is not hardware acquisition, USB completion, RF delivery, READY receipt or 932-parameter acceptance.','Independent sections have different commit times; first-fault snapshot is the immutable boundary, not a simultaneous aggregate sample.','Clock-regression, overflow, history wrap and invalid-input flags are preserved; missing evidence is not converted into success.','MCU microseconds are unsigned decimal strings; no PC/MCU clock correlation or cross-writer ordering is inferred.')
  }
}
