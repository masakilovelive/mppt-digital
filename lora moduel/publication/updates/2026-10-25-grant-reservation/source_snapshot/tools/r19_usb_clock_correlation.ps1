# Pure offline clock correlation and diagnostic MAVLink TIMESYNC codec.
# No COM, process, filesystem, network, hardware or wall-clock access occurs.
Add-Type -AssemblyName System.Numerics

function Get-R19ClockInteger {
  param([object]$Value,[string]$Label,[string]$Maximum='18446744073709551615')
  if($null-eq$Value-or$Value-is[bool]-or$Value-is[float]-or$Value-is[double]){throw "$Label must be an exact integer"}
  $text=[Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)
  if($text-cnotmatch'^(0|[1-9][0-9]*)$'){throw "$Label is not a canonical nonnegative integer"}
  $number=[Numerics.BigInteger]::Parse($text,[Globalization.CultureInfo]::InvariantCulture)
  if($number-gt[Numerics.BigInteger]::Parse($Maximum)){throw "$Label exceeds its declared integer width"}
  $number
}

function Get-R19RationalFloor {
  param([Numerics.BigInteger]$Numerator,[Numerics.BigInteger]$Denominator)
  if($Denominator-le0){throw 'Nonpositive rational denominator'}
  $q=[Numerics.BigInteger]::Divide($Numerator,$Denominator)
  if($Numerator-lt0-and[Numerics.BigInteger]::Remainder($Numerator,$Denominator)-ne0){$q-=[Numerics.BigInteger]::One}
  $q
}

function Get-R19RationalCeiling {
  param([Numerics.BigInteger]$Numerator,[Numerics.BigInteger]$Denominator)
  -(Get-R19RationalFloor (-$Numerator) $Denominator)
}

function Test-R19TimesyncNonce {
  param([object]$Nonce)
  try{
    $n=Get-R19ClockInteger $Nonce 'nonce' '9223372036854775807'
    $v=[long]$n
    (($v-shr48)-eq0x5219)-and(($v-band[long]0x0000FFFFFFFFFFFF)-ne0)
  }catch{$false}
}

function New-R19TimesyncNonce {
  $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
  try{
    [byte[]]$bytes=[byte[]]::new(8)
    do{$rng.GetBytes($bytes);$bytes[6]=0x19;$bytes[7]=0x52;$n=[BitConverter]::ToInt64($bytes,0)}while(($n-band[long]0x0000FFFFFFFFFFFF)-eq0)
    $n
  }finally{$rng.Dispose()}
}

function Get-R19TimesyncCrc {
  param([byte[]]$Bytes)
  if($null-eq$Bytes-or$Bytes.Length-ne28){throw 'TIMESYNC must be exactly 28 bytes'}
  [uint16]$crc=65535
  foreach($value in @($Bytes[1..25])+@(34)){
    [uint16]$tmp=([uint16]$value-bxor($crc-band255))
    $tmp=($tmp-bxor(($tmp-shl4)-band255))-band255
    $crc=(($crc-shr8)-bxor($tmp-shl8)-bxor($tmp-shl3)-bxor($tmp-shr4))-band65535
  }
  $crc
}

function New-R19TimesyncRequest {
  param([Parameter(Mandatory)][long]$Nonce,[byte]$Sequence=0)
  if(-not(Test-R19TimesyncNonce $Nonce)){throw 'Diagnostic nonce must have 0x5219 prefix and nonzero low 48 bits'}
  [byte[]]$bytes=[byte[]]::new(28)
  $bytes[0]=253;$bytes[1]=16;$bytes[4]=$Sequence;$bytes[5]=249;$bytes[6]=193;$bytes[7]=111
  [BitConverter]::GetBytes($Nonce).CopyTo($bytes,18)
  [BitConverter]::GetBytes([uint16](Get-R19TimesyncCrc $bytes)).CopyTo($bytes,26)
  return ,$bytes
}

function ConvertFrom-R19TimesyncResponse {
  param([byte[]]$Bytes,[long]$ExpectedNonce)
  try{
    if(-not(Test-R19TimesyncNonce $ExpectedNonce)){throw 'Expected nonce is invalid'}
    if($null-eq$Bytes-or$Bytes.Length-ne28-or$Bytes[0]-ne253-or$Bytes[1]-ne16-or
        $Bytes[2]-ne0-or$Bytes[3]-ne0-or$Bytes[5]-ne249-or$Bytes[6]-ne194-or
        $Bytes[7]-ne111-or$Bytes[8]-ne0-or$Bytes[9]-ne0){throw 'Response is not canonical diagnostic MAVLink2 TIMESYNC'}
    if([BitConverter]::ToUInt16($Bytes,26)-ne(Get-R19TimesyncCrc $Bytes)){throw 'Response CRC mismatch'}
    $nonce=[BitConverter]::ToInt64($Bytes,18);$ns=[BitConverter]::ToInt64($Bytes,10)
    if($nonce-ne$ExpectedNonce-or-not(Test-R19TimesyncNonce $nonce)){throw 'Response nonce mismatch'}
    if($ns-le0-or($ns%1000)-ne0){throw 'Response timestamp is nonpositive or not exact microseconds'}
    # Use explicit integer division even when PowerShell's exact-divisible
    # Int64 fast path would work. No interpreter numeric promotion is allowed.
    $microseconds=[Numerics.BigInteger]::Divide([Numerics.BigInteger]$ns,[Numerics.BigInteger]1000)
    [pscustomobject][ordered]@{schema='vc-lora-r19-timesync-response-v1';valid=$true;nonce=[string]$nonce
      device_nanoseconds=[string]$ns;device_microseconds=$microseconds.ToString([Globalization.CultureInfo]::InvariantCulture);sequence=[int]$Bytes[4];error=''}
  }catch{[pscustomobject][ordered]@{schema='vc-lora-r19-timesync-response-v1';valid=$false;nonce='';device_nanoseconds='';device_microseconds='';sequence=-1;error=$_.Exception.Message}}
}

function Test-R19ClockProperty {
  param([object]$Object,[string]$Name)
  if($null-eq$Object){return $false}
  if($Object-is[Collections.IDictionary]){return $Object.Contains($Name)}
  $null-ne$Object.PSObject.Properties[$Name]
}

function Get-R19PcReadEventComparison {
  param([Numerics.BigInteger]$Lower,[Numerics.BigInteger]$Upper,
        [Numerics.BigInteger]$Frequency,[Numerics.BigInteger]$Ticks,[string]$Event)
  $million=[Numerics.BigInteger]1000000
  $classification=if($Upper*$Frequency-lt$Ticks*$million){'PRE_'+$Event}elseif($Lower*$Frequency-gt$Ticks*$million){'POST_'+$Event}else{'UNKNOWN'}
  [pscustomobject][ordered]@{classification=$classification;event_ticks=[string]$Ticks
    reason=$(if($classification-ceq'UNKNOWN'){'interval_touches_or_overlaps_application_event'}else{'strict_disjoint_interval'})
    semantics=$(if($Event-ceq'FIRST_POSITIVE_READ'){'application-read-return-sample-not-physical-usb-arrival'}else{'application-instrumentation-boundary-not-pending-read-or-host-polling'})}
}

function Get-R19UsbClockCorrelation {
  param([Parameter(Mandatory)][object]$Observation)
  $unknown=[ordered]@{schema='vc-lora-r19-usb-clock-correlation-result-v1';classification='UNKNOWN';bounds_valid=$false
    lower_pc_us='';upper_pc_us='';interval_width_us='';reason='';hardware_interaction=$false
    semantics='failure-decision-sample-not-physical-fault-onset';clock_domain_id=''
    read_loop_comparison=[pscustomobject][ordered]@{classification='UNKNOWN';event_ticks='';reason='read_event_not_recorded_or_correlation_invalid';semantics='application-instrumentation-boundary-not-pending-read-or-host-polling'}
    first_positive_read_comparison=[pscustomobject][ordered]@{classification='UNKNOWN';event_ticks='';reason='read_event_not_recorded_or_correlation_invalid';semantics='application-read-return-sample-not-physical-usb-arrival'}
    assumptions='Caller must independently verify boot identity, clock continuity and the guaranteed error bound.'}
  try{
    if($Observation.schema-cne'vc-lora-r19-usb-clock-correlation-observation-v1'){throw 'observation_schema_invalid'}
    $identity=$Observation.identity
    if($identity.role-cnotin@('ground','vehicle')-or[string]::IsNullOrWhiteSpace([string]$identity.candidate_id)-or[string]::IsNullOrWhiteSpace([string]$identity.session_id)){throw 'identity_invalid'}
    $boot=@($identity.boot_instance)
    if($boot.Count-ne4){throw 'boot_instance_requires_four_words'}
    $bootText=@();foreach($v in $boot){$bootText+=[string](Get-R19ClockInteger $v 'boot word' '4294967295')}
    if(($bootText-join',')-ceq'0,0,0,0'){throw 'zero_boot_instance'}
    foreach($record in @($Observation.failure,$Observation.sync)){
      foreach($name in @('role','candidate_id','session_id')){if($record.$name-isnot[string]-or$record.$name-cne$identity.$name){throw 'record_identity_mismatch'}}
      $other=@($record.boot_instance);if($other.Count-ne4){throw 'record_boot_instance_invalid'}
      for($i=0;$i-lt4;++$i){if([string](Get-R19ClockInteger $other[$i] 'record boot word' '4294967295')-cne$bootText[$i]){throw 'record_boot_mismatch'}}
    }
    foreach($name in @('same_boot','reset_absent','sleep_absent','halt_absent','clock_reinitialization_absent')){
      if($Observation.continuity.$name-isnot[bool]-or-not$Observation.continuity.$name){throw 'clock_continuity_unproven'}
    }
    $bound=$Observation.error_bound
    if($null-eq$bound-or$bound.guaranteed-isnot[bool]-or-not$bound.guaranteed-or[string]::IsNullOrWhiteSpace([string]$bound.source)){throw 'guaranteed_error_bound_absent'}
    $ppb=Get-R19ClockInteger $bound.rate_error_ppb 'rate_error_ppb' '999999999'
    $errorUs=Get-R19ClockInteger $bound.additive_us 'additive_us'
    $pc=$Observation.pc
    if($pc.clock_domain_id-isnot[string]-or[string]::IsNullOrWhiteSpace($pc.clock_domain_id)-or
        $pc.open_clock_domain_id-cne$pc.clock_domain_id-or$pc.sync_clock_domain_id-cne$pc.clock_domain_id){throw 'qpc_domain_mismatch'}
    foreach($flag in @('trace_overflow','trace_incomplete')){
      if((Test-R19ClockProperty $pc $flag)-and($pc.$flag-isnot[bool]-or$pc.$flag)){throw 'lifecycle_trace_incomplete_or_overflowed'}
    }
    if((Test-R19ClockProperty $pc 'lifecycle_trace_result')-and
        ($pc.lifecycle_trace_result-isnot[string]-or$pc.lifecycle_trace_result-cne'COMPLETE')){throw 'lifecycle_trace_incomplete_or_overflowed'}
    $unknown.clock_domain_id=$pc.clock_domain_id
    $frequency=Get-R19ClockInteger $pc.frequency 'QPC frequency' '9223372036854775807'
    if($frequency-eq0){throw 'zero_qpc_frequency'}
    $openBefore=Get-R19ClockInteger $pc.open_before_ticks 'open before' '9223372036854775807'
    $openAfter=Get-R19ClockInteger $pc.open_after_ticks 'open after' '9223372036854775807'
    $send=Get-R19ClockInteger $pc.send_before_ticks 'send before' '9223372036854775807'
    $receive=Get-R19ClockInteger $pc.receive_after_ticks 'receive after' '9223372036854775807'
    if($openBefore-gt$openAfter-or$openAfter-gt$send-or$send-gt$receive){throw 'pc_event_order_invalid'}
    $hasReadLoop=Test-R19ClockProperty $pc 'read_loop_armed_ticks'
    $hasFirstPositive=Test-R19ClockProperty $pc 'first_positive_read_ticks'
    if($hasReadLoop){
      $readLoop=Get-R19ClockInteger $pc.read_loop_armed_ticks 'read loop armed' '9223372036854775807'
      if($readLoop-lt$openAfter-or$readLoop-gt$receive){throw 'pc_read_event_order_invalid'}
    }
    if($hasFirstPositive){
      $firstPositive=Get-R19ClockInteger $pc.first_positive_read_ticks 'first positive read' '9223372036854775807'
      if($firstPositive-lt$openAfter-or$firstPositive-gt$receive-or($hasReadLoop-and$firstPositive-lt$readLoop)){throw 'pc_read_event_order_invalid'}
    }
    if(-not(Test-R19TimesyncNonce $Observation.sync.nonce)-or
        [string]$Observation.sync.nonce-cne[string]$Observation.sync.echoed_nonce){throw 'sync_nonce_invalid'}
    $failure=Get-R19ClockInteger $Observation.failure.device_us 'failure device us'
    $sync=Get-R19ClockInteger $Observation.sync.device_us 'sync device us'
    $failureQ=Get-R19ClockInteger $Observation.failure.quantization_us 'failure quantization'
    $syncQ=Get-R19ClockInteger $Observation.sync.quantization_us 'sync quantization'
    $max=[Numerics.BigInteger]::Parse('18446744073709551615')
    if($failure+$failureQ-gt$max-or$sync+$syncQ-gt$max){throw 'device_timestamp_quantization_overflows_uint64'}
    $minDelta=$failure-($sync+$syncQ);$maxDelta=($failure+$failureQ)-$sync
    $billion=[Numerics.BigInteger]1000000000;$million=[Numerics.BigInteger]1000000
    $lowRate=if($minDelta-lt0){$billion-$ppb}else{$billion+$ppb}
    $highRate=if($maxDelta-lt0){$billion+$ppb}else{$billion-$ppb}
    # Exact rational arithmetic, including negative offsets. No double or
    # integer division before outward floor/ceil is permitted here.
    $lowDen=$frequency*$lowRate;$highDen=$frequency*$highRate
    $lowNum=$send*$million*$lowRate+$minDelta*$billion*$frequency-$errorUs*$lowDen
    $highNum=$receive*$million*$highRate+$maxDelta*$billion*$frequency+$errorUs*$highDen
    $lower=Get-R19RationalFloor $lowNum $lowDen
    $upper=Get-R19RationalCeiling $highNum $highDen
    if($lower-gt$upper){throw 'correlation_interval_invalid'}
    $classification=if($upper*$frequency-lt$openBefore*$million){'PRE_PC_OPEN'}elseif($lower*$frequency-gt$openAfter*$million){'POST_PC_OPEN'}else{'UNKNOWN'}
    $unknown.classification=$classification;$unknown.bounds_valid=$true
    $unknown.lower_pc_us=[string]$lower;$unknown.upper_pc_us=[string]$upper;$unknown.interval_width_us=[string]($upper-$lower)
    $unknown.reason=if($classification-ceq'UNKNOWN'){'interval_touches_or_overlaps_open'}else{'strict_disjoint_interval'}
    if($hasReadLoop){$unknown.read_loop_comparison=Get-R19PcReadEventComparison $lower $upper $frequency $readLoop 'READ_LOOP_ARMED'}
    if($hasFirstPositive){$unknown.first_positive_read_comparison=Get-R19PcReadEventComparison $lower $upper $frequency $firstPositive 'FIRST_POSITIVE_READ'}
    [pscustomobject]$unknown
  }catch{$unknown.reason=$_.Exception.Message;[pscustomobject]$unknown}
}
