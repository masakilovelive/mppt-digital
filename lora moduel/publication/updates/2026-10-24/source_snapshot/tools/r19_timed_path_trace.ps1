[CmdletBinding()]
param([switch]$ImportOnly,[string]$InputPath,[string]$OutputPath)
# Pure offline evaluation of supplied, transaction-bound diagnostic records.
# ImportOnly defines functions; it never acquires observations or starts a test.
. (Join-Path $PSScriptRoot 'r19_usb_clock_correlation.ps1')

function Get-R19TimedPathTraceEvaluation {
  [CmdletBinding()]
  param([Parameter(Mandatory)][object]$Evidence)
  Set-StrictMode -Version Latest
  $ErrorActionPreference='Stop'
  function Need([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
  function Has($Object,[string]$Name){
    if($null-eq$Object){return $false}
    if($Object-is[Collections.IDictionary]){return $Object.Contains($Name)}
    return $null-ne$Object.PSObject.Properties[$Name]
  }
  function Fields($Object,[string[]]$Allowed,[string[]]$Required){
    Need ($null-ne$Object-and$Object-isnot[string]-and$Object-isnot[ValueType]-and$Object-isnot[Array]) 'Expected a record object'
    $names=if($Object-is[Collections.IDictionary]){@($Object.Keys)}else{@($Object.PSObject.Properties.Name)}
    foreach($name in $names){Need ($name-cin$Allowed) "Unknown field: $name"}
    foreach($name in $Required){Need (Has $Object $name) "Missing field: $name"}
  }
  function UInt($Value,[string]$Name,[string]$Maximum='18446744073709551615',[switch]$StringOnly){
    if($StringOnly){Need ($Value-is[string]) "$Name requires an exact canonical integer string"}
    return Get-R19ClockInteger $Value $Name $Maximum
  }
  function Text($Value,[string]$Name){Need ($Value-is[string]-and-not[string]::IsNullOrWhiteSpace($Value)) "$Name requires a nonempty string"}
  function Bool($Value,[string]$Name){Need ($Value-is[bool]) "$Name requires a boolean";return $Value}
  function Sha($Value,[string]$Name){Need ($Value-is[string]-and$Value-cmatch'^[0-9A-Fa-f]{64}$') "$Name requires a SHA256"}
  function Words($Value,[string]$Name){
    Need ($Value-is[Array]-and$Value.Count-eq4) "$Name requires four uint32 words"
    $words=@();foreach($word in $Value){$words+=[string](UInt $word $Name '4294967295')};return ,$words
  }
  function ValidateIdentity($Value){
    $names=@('role','candidate_id','build_fingerprint','boot_instance','usb_epoch','reader_session','nonce','frame_id','frame_sha256','frame_kind','expected_frame_bytes')
    Fields $Value $names $names
    Need ($Value.role-is[string]-and$Value.role-ceq'ground') 'Only the Ground USB transaction is covered'
    Text $Value.candidate_id 'candidate_id';Text $Value.frame_id 'frame_id'
    $null=Words $Value.build_fingerprint 'build_fingerprint';$boot=Words $Value.boot_instance 'boot_instance'
    Need (($boot-join',')-cne'0,0,0,0') 'Zero boot identity'
    $null=UInt $Value.usb_epoch 'usb_epoch' '4294967295'
    $session=UInt $Value.reader_session 'reader_session' '18446744073709551615' -StringOnly
    Need ($session-gt0) 'reader_session must be nonzero'
    $null=UInt $Value.nonce 'nonce' '9223372036854775807' -StringOnly
    Need (Test-R19TimesyncNonce $Value.nonce) 'Invalid private diagnostic nonce'
    Sha $Value.frame_sha256 'frame_sha256'
    Need ($Value.frame_kind-is[string]-and$Value.frame_kind-cin@('PRODUCT_HEARTBEAT','DIAGNOSTIC')) 'Unknown frame kind'
    $length=UInt $Value.expected_frame_bytes 'expected_frame_bytes' '280'
    Need ($length-gt0) 'Expected frame length must be positive'
    if($Value.frame_kind-ceq'PRODUCT_HEARTBEAT'){Need ($length-ge21) 'A product Heartbeat cannot be shorter than 21 bytes'}
  }
  function SameIdentity($A,$B){
    ValidateIdentity $B
    foreach($name in @('role','candidate_id','reader_session','nonce','frame_id','frame_kind')){Need ($A.$name-ceq$B.$name) "Transaction identity mismatch: $name"}
    Need ($A.frame_sha256-ieq$B.frame_sha256) 'Transaction frame SHA256 mismatch'
    foreach($name in @('build_fingerprint','boot_instance')){
      $aWords=Words $A.$name $name;$bWords=Words $B.$name $name
      Need (($aWords-join',')-ceq($bWords-join',')) "Transaction identity mismatch: $name"
    }
    foreach($name in @('usb_epoch','expected_frame_bytes')){Need ((UInt $A.$name $name)-eq(UInt $B.$name $name)) "Transaction identity mismatch: $name"}
  }
  function RawIdentity($Record,$Binding,[string]$Label,[string[]]$Extra){
    $names=@('role','candidate_id','session_id','boot_instance')+$Extra
    Fields $Record $names $names
    Need ($Record.role-is[string]-and$Record.role-ceq$Binding.role-and$Record.candidate_id-is[string]-and$Record.candidate_id-ceq$Binding.candidate_id) "$Label role/candidate mismatch"
    Need ($Record.session_id-is[string]-and$Record.session_id-ceq$Binding.reader_session) "$Label reader session mismatch"
    $boot=Words $Record.boot_instance "$Label boot_instance";$expected=Words $Binding.boot_instance 'binding boot_instance'
    Need (($boot-join',')-ceq($expected-join',')) "$Label boot mismatch"
  }

  $topNames=@('schema','identity','clock_correlation','trace_complete','trace_overflow','events')
  Fields $Evidence $topNames $topNames
  Need ($Evidence.schema-is[string]-and$Evidence.schema-ceq'vc-lora-r19-timed-path-evidence-v1') 'Unknown timed trace evidence schema'
  $complete=Bool $Evidence.trace_complete 'trace_complete';$overflow=Bool $Evidence.trace_overflow 'trace_overflow'
  Need ($Evidence.events-is[Array]) 'events must be an array'
  $events=@($Evidence.events);$identity=$Evidence.identity
  if($null-eq$identity){Need ($events.Count-eq0-and$null-eq$Evidence.clock_correlation) 'Missing identity is permitted only for an empty trace without clock evidence'}else{ValidateIdentity $identity}
  $allStages=@('PC_READ_STARTED','MCU_ARM_ACCEPTED','MCU_FRAME_ENQUEUED','MCU_HWCDC_ACCEPTED','MCU_USB_PUBLISHED','MCU_USB_PICKUP_OBSERVED','MCU_USB_COMPLETED','MCU_USB_FAILED','PC_FRAME_VALIDATED')
  $stageRecords=@{};$observed=@();$timeline=@();$mcu=@();$lastByDomain=@{};$pcRead=$null;$arm=$null;$failure=$null;$completed=$false;$validated=$false
  for($i=0;$i-lt$events.Count;$i++){
    $event=$events[$i];$eventNames=@('kind','ordinal','domain','timestamp','identity','evidence_sha256','details')
    Fields $event $eventNames $eventNames
    Need ($event.kind-is[string]-and$event.kind-cin$allStages) 'Unknown trace event kind'
    Need ((UInt $event.ordinal 'ordinal')-eq$i) 'Event ordinals must be the exact contiguous array indices'
    $domain=if($event.kind.StartsWith('PC_')){'PC_TICKS'}else{'MCU_US'}
    Need ($event.domain-is[string]-and$event.domain-ceq$domain) 'Event clock domain does not match its stage'
    $timestamp=UInt $event.timestamp 'timestamp' '18446744073709551615' -StringOnly
    if($lastByDomain.ContainsKey($domain)){Need ($timestamp-ge$lastByDomain[$domain]) 'Backward timestamp within one clock domain'}
    $lastByDomain[$domain]=$timestamp
    SameIdentity $identity $event.identity;Sha $event.evidence_sha256 'event evidence_sha256'
    Need (-not$stageRecords.ContainsKey($event.kind)) 'Duplicate transaction stage is ambiguous'
    $stageRecords[$event.kind]=$event;$observed+=$event.kind
    $details=$event.details
    switch -CaseSensitive ($event.kind){
      'PC_READ_STARTED'{
        $names=@('clock_domain_id','reader_owner_verified','frequency');Fields $details $names $names
        Text $details.clock_domain_id 'clock_domain_id';$null=Bool $details.reader_owner_verified 'reader_owner_verified'
        Need ((UInt $details.frequency 'PC frequency' '9223372036854775807' -StringOnly)-gt0) 'PC frequency must be positive';$pcRead=$event
      }
      'MCU_ARM_ACCEPTED'{
        $names=@('accepted','device_clock_continuity_verified');Fields $details $names $names
        Need (Bool $details.accepted 'accepted') 'The ARM_ACCEPTED event must contain actual acceptance'
        $null=Bool $details.device_clock_continuity_verified 'device_clock_continuity_verified';$arm=$event
      }
      'MCU_FRAME_ENQUEUED'{
        Fields $details @('frame_bytes') @('frame_bytes')
        Need ((UInt $details.frame_bytes 'frame_bytes' '280')-eq(UInt $identity.expected_frame_bytes 'expected_frame_bytes')) 'Enqueued bytes differ from the bound frame'
      }
      'MCU_HWCDC_ACCEPTED'{
        Fields $details @('accepted_bytes') @('accepted_bytes')
        Need ((UInt $details.accepted_bytes 'accepted_bytes' '280')-le(UInt $identity.expected_frame_bytes 'expected_frame_bytes')) 'Accepted bytes exceed the bound frame'
      }
      'MCU_USB_PUBLISHED'{
        $names=@('publish_generation','ring_pending_bytes','stash_pending_bytes');Fields $details $names $names
        foreach($name in $names){$null=UInt $details.$name $name '4294967295'}
      }
      'MCU_USB_PICKUP_OBSERVED'{Fields $details @('pickup_generation') @('pickup_generation');$null=UInt $details.pickup_generation 'pickup_generation' '4294967295'}
      'MCU_USB_COMPLETED'{
        Fields $details @('completed_bytes') @('completed_bytes')
        Need ((UInt $details.completed_bytes 'completed_bytes' '280')-eq(UInt $identity.expected_frame_bytes 'expected_frame_bytes')) 'Completed bytes differ from the bound frame';$completed=$true
      }
      'MCU_USB_FAILED'{
        Need ($identity.frame_kind-ceq'PRODUCT_HEARTBEAT') 'Diagnostic failure budgets are distinct and are not modeled by this product completion contract'
        $names=@('budget_ms','started_us','finished_us','accepted_bytes','reason');Fields $details $names $names
        Need ((UInt $details.budget_ms 'budget_ms' '4294967295')-eq106) 'The 106 ms product completion contract is unchanged'
        $start=UInt $details.started_us 'started_us' '18446744073709551615' -StringOnly
        $finish=UInt $details.finished_us 'finished_us' '18446744073709551615' -StringOnly
        Need ($finish-ge$start-and$timestamp-eq$finish) 'Invalid immutable failure interval or event timestamp'
        Need ((UInt $details.accepted_bytes 'failure accepted_bytes' '280')-le(UInt $identity.expected_frame_bytes 'expected_frame_bytes')) 'Failure accepted bytes exceed the bound frame'
        Text $details.reason 'failure reason';$failure=$event
      }
      'PC_FRAME_VALIDATED'{
        $names=@('received_bytes','crc_valid','complete_frame','frame_sha256');Fields $details $names $names
        Need ((UInt $details.received_bytes 'received_bytes' '280')-eq(UInt $identity.expected_frame_bytes 'expected_frame_bytes')) 'Received bytes differ from the bound frame'
        Need ((Bool $details.crc_valid 'crc_valid')-and(Bool $details.complete_frame 'complete_frame')) 'A validated frame must be complete with a valid CRC'
        Sha $details.frame_sha256 'validated frame_sha256';Need ($details.frame_sha256-ieq$identity.frame_sha256) 'Validated frame SHA256 mismatch';$validated=$true
      }
    }
    # Preserve validated observations in the report without sharing mutable
    # detail objects with the caller. Counts are observations, not location proof.
    $detailCopy=ConvertTo-Json -InputObject $details -Depth 20|ConvertFrom-Json
    $timeline+=[pscustomobject][ordered]@{kind=$event.kind;domain=$domain;timestamp=[string]$timestamp;evidence_sha256=$event.evidence_sha256;details=$detailCopy;pc_bounds=$null}
    if($domain-ceq'MCU_US'){$mcu+=$event}
  }
  Need (-not($completed-and$null-ne$failure)) 'One bound transaction cannot have conflicting local completion and failure terminals'
  if($completed){
    $completion=$stageRecords['MCU_USB_COMPLETED']
    if($stageRecords.ContainsKey('MCU_FRAME_ENQUEUED')){
      Need ((UInt $completion.timestamp 'completion timestamp')-ge(UInt $stageRecords['MCU_FRAME_ENQUEUED'].timestamp 'enqueue timestamp')) 'Local completion cannot precede the same frame enqueue boundary'
    }
    if($stageRecords.ContainsKey('MCU_HWCDC_ACCEPTED')){
      Need ((UInt $completion.details.completed_bytes 'completed_bytes')-eq(UInt $stageRecords['MCU_HWCDC_ACCEPTED'].details.accepted_bytes 'final accepted_bytes')) 'Local completion and final cumulative HWCDC accepted bytes disagree'
    }
  }
  if($null-ne$failure){
    if($stageRecords.ContainsKey('MCU_FRAME_ENQUEUED')){
      Need ((UInt $failure.details.started_us 'failure started_us')-ge(UInt $stageRecords['MCU_FRAME_ENQUEUED'].timestamp 'enqueue timestamp')) 'Failure transaction cannot start before the same frame was enqueued'
    }
    if($stageRecords.ContainsKey('MCU_HWCDC_ACCEPTED')){
      Need ((UInt $failure.details.accepted_bytes 'failure accepted_bytes')-eq(UInt $stageRecords['MCU_HWCDC_ACCEPTED'].details.accepted_bytes 'HWCDC accepted_bytes')) 'Failure and final cumulative HWCDC accepted bytes disagree'
    }
  }

  $correlation=$Evidence.clock_correlation;$raw=$null
  if($null-ne$correlation){
    $names=@('binding','observation','evidence_sha256');Fields $correlation $names $names
    SameIdentity $identity $correlation.binding;Sha $correlation.evidence_sha256 'clock evidence_sha256'
    $raw=$correlation.observation;$names=@('schema','identity','failure','sync','pc','continuity','error_bound');Fields $raw $names $names
    Need ($raw.schema-is[string]-and$raw.schema-ceq'vc-lora-r19-usb-clock-correlation-observation-v1') 'Unknown raw clock observation schema'
    RawIdentity $raw.identity $identity 'clock identity' @()
    RawIdentity $raw.failure $identity 'clock failure' @('device_us','quantization_us')
    RawIdentity $raw.sync $identity 'clock sync' @('device_us','quantization_us','nonce','echoed_nonce')
    foreach($record in @($raw.failure,$raw.sync)){$null=UInt $record.device_us 'raw device_us';$null=UInt $record.quantization_us 'raw quantization_us'}
    Need ($raw.sync.nonce-is[string]-and$raw.sync.nonce-ceq$identity.nonce-and$raw.sync.echoed_nonce-is[string]-and$raw.sync.echoed_nonce-ceq$identity.nonce) 'Clock nonce mismatch'
    $names=@('same_boot','reset_absent','sleep_absent','halt_absent','clock_reinitialization_absent');Fields $raw.continuity $names $names
    foreach($name in $names){$null=Bool $raw.continuity.$name $name}
    $names=@('guaranteed','rate_error_ppb','additive_us','source');Fields $raw.error_bound $names $names
    $null=Bool $raw.error_bound.guaranteed 'guaranteed';$null=UInt $raw.error_bound.rate_error_ppb 'rate_error_ppb' '999999999'
    $null=UInt $raw.error_bound.additive_us 'additive_us';Text $raw.error_bound.source 'error_bound source'
    $pcRequired=@('clock_domain_id','open_clock_domain_id','sync_clock_domain_id','frequency','open_before_ticks','open_after_ticks','send_before_ticks','receive_after_ticks','read_loop_armed_ticks')
    $pcAllowed=$pcRequired+@('first_positive_read_ticks','trace_overflow','trace_incomplete','lifecycle_trace_result');Fields $raw.pc $pcAllowed $pcRequired
    foreach($name in @('clock_domain_id','open_clock_domain_id','sync_clock_domain_id')){Text $raw.pc.$name $name}
    foreach($name in @('frequency','open_before_ticks','open_after_ticks','send_before_ticks','receive_after_ticks','read_loop_armed_ticks')){$null=UInt $raw.pc.$name $name '9223372036854775807'}
    if(Has $raw.pc 'first_positive_read_ticks'){$null=UInt $raw.pc.first_positive_read_ticks 'first_positive_read_ticks' '9223372036854775807'}
    foreach($name in @('trace_overflow','trace_incomplete')){if(Has $raw.pc $name){$null=Bool $raw.pc.$name $name}}
    if(Has $raw.pc 'lifecycle_trace_result'){Text $raw.pc.lifecycle_trace_result 'lifecycle_trace_result'}
    Need ($null-ne$pcRead) 'Clock mapping requires a bound PC_READ_STARTED event'
    Need ($raw.pc.clock_domain_id-ceq$pcRead.details.clock_domain_id-and$raw.pc.open_clock_domain_id-ceq$pcRead.details.clock_domain_id-and$raw.pc.sync_clock_domain_id-ceq$pcRead.details.clock_domain_id) 'PC clock domain binding mismatch'
    Need ((UInt $raw.pc.frequency 'clock frequency')-eq(UInt $pcRead.details.frequency 'reader frequency')) 'PC frequency binding mismatch'
    Need ((UInt $raw.pc.read_loop_armed_ticks 'raw reader boundary')-eq(UInt $pcRead.timestamp 'reader timestamp')) 'PC read boundary binding mismatch'
  }

  $mcuContinuity=$null-ne$arm-and$arm.details.device_clock_continuity_verified
  $deltas=@();if($mcuContinuity){
    for($i=1;$i-lt$mcu.Count;$i++){
      $delta=(UInt $mcu[$i].timestamp 'MCU timestamp')-(UInt $mcu[$i-1].timestamp 'MCU timestamp')
      $deltas+=[pscustomobject][ordered]@{from=$mcu[$i-1].kind;to=$mcu[$i].kind;elapsed_us=[string]$delta}
    }
  }
  $clockValid=$false;$clockReasons=@()
  if($null-ne$raw-and$complete-and-not$overflow-and($null-eq$arm-or$mcuContinuity)-and$pcRead.details.reader_owner_verified){
    $clockValid=$mcu.Count-gt0
    for($i=0;$i-lt$timeline.Count;$i++){
      if($timeline[$i].domain-cne'MCU_US'){continue}
      # Retain the raw observations and their guaranteed error bound. The
      # helper independently maps each event with outward exact arithmetic.
      $perEvent=$raw|ConvertTo-Json -Depth 30|ConvertFrom-Json
      $perEvent.failure.device_us=$timeline[$i].timestamp
      $mapped=Get-R19UsbClockCorrelation -Observation $perEvent
      $timeline[$i].pc_bounds=[pscustomobject][ordered]@{lower_pc_us=$mapped.lower_pc_us;upper_pc_us=$mapped.upper_pc_us;interval_width_us=$mapped.interval_width_us;bounds_valid=$mapped.bounds_valid;read_relation=$mapped.read_loop_comparison.classification}
      if(-not$mapped.bounds_valid){$clockValid=$false;$clockReasons+=$mapped.reason}
    }
  }elseif($null-ne$raw){$clockReasons+= 'Trace coverage, MCU continuity or verified reader ownership is insufficient for clock mapping.'}
  if($validated-and$null-ne$raw-and$stageRecords.ContainsKey('MCU_FRAME_ENQUEUED')){
    $enqueueBounds=@($timeline|Where-Object{$_.kind-ceq'MCU_FRAME_ENQUEUED'})[0].pc_bounds
    if($null-ne$enqueueBounds-and$enqueueBounds.bounds_valid){
      $pcValidatedTicks=UInt $stageRecords['PC_FRAME_VALIDATED'].timestamp 'PC validated timestamp'
      $frequency=UInt $raw.pc.frequency 'PC clock frequency'
      $lower=[Numerics.BigInteger]::Parse($enqueueBounds.lower_pc_us,[Globalization.CultureInfo]::InvariantCulture)
      Need ($pcValidatedTicks*[Numerics.BigInteger]1000000-ge$lower*$frequency) 'Bound complete PC reception strictly precedes the same frame enqueue interval'
    }
  }

  $classification='PARTIAL_TRACE';$failureElapsed=$null
  if($events.Count-eq0){$classification='NO_TRACE_EVIDENCE'}
  elseif($null-ne$failure){
    $classification='USB_FAILURE_ORDER_UNKNOWN'
    $start=UInt $failure.details.started_us 'started_us';$finish=UInt $failure.details.finished_us 'finished_us';$failureElapsed=[string]($finish-$start)
    if($mcuContinuity){
      $armTime=UInt $arm.timestamp 'ARM timestamp'
      if($start-ge$armTime){$classification='USB_FAILURE_AFTER_DEVICE_ARM'}elseif($finish-lt$armTime){$classification='USB_FAILURE_BEFORE_DEVICE_ARM'}else{$classification='USB_FAILURE_OVERLAPS_DEVICE_ARM'}
    }
  }elseif($validated){$classification='PC_FRAME_VALIDATED_OBSERVED'}elseif($completed){$classification='LOCAL_USB_COMPLETION_OBSERVED'}
  if(-not$complete-or$overflow){$classification='TRACE_INCOMPLETE'}
  $lastMcu='NONE';if($mcu.Count-gt0){$lastMcu=$mcu[-1].kind}
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-timed-path-evaluation-v1';mode='OFFLINE_ONLY';classification=$classification
    identity=$identity;last_observed_mcu_stage=$lastMcu;observed_stages=@($observed);missing_stages=@($allStages|Where-Object{$_-cnotin$observed})
    event_timeline=@($timeline);mcu_deltas=@($deltas);mcu_clock_continuity_verified=[bool]$mcuContinuity;failure_elapsed_us=$failureElapsed
    pc_frame_validated=$validated;local_usb_completed=$completed;clock_bounds_valid=$clockValid;clock_mapping_reasons=@($clockReasons|Select-Object -Unique)
    trace_complete=$complete;trace_overflow=$overflow;hardware_interaction=$false;physical_fifo_fault_proven=$false
    kernel_pending_read_proven=$false;root_cause_proven=$false;acceptance_eligible=$false;deployment_authorized=$false
    rf_status='NOT_EVALUATED';parameters_status='NOT_EVALUATED'
    limitations=@(
      'This evaluates supplied records only. SHA256 syntax and equality establish claimed joins, not authenticity, ownership or acquisition provenance.',
      'PC_READ_STARTED has a post-hoc frame tuple join; it does not prove that this frame was known at reader startup, a kernel-pending Read, or physical host polling.',
      'Only a continuous common MCU_US clock establishes MCU elapsed times; SDK millis32 values cannot be substituted for caller 64-bit microseconds.',
      'Every mapped MCU_US boundary must use the same continuous 64-bit microsecond clock and the common quantization bound supplied as observation.failure.quantization_us. Per-stage or SDK millisecond timestamps with different bounds are not interchangeable.',
      'Mixed-domain array ordinals are acquisition indices, never a PC-to-MCU execution order. Clock bounds retain guaranteed-error and continuity assumptions.',
      'Host ARM before a failure narrows an observed boundary; ARM after a failure calls for gate/binding review. Neither establishes host-readiness causation.',
      'Publication and pickup counters, zero ring/stash byte counts, and later FIFO snapshots do not locate a physical FIFO fault or prove payload transmission. Counter subtraction is not missing-byte accounting.',
      'MCU_HWCDC_ACCEPTED is one final cumulative acceptance observation for this bound frame, not a partial in-progress chunk. MCU_USB_PICKUP_OBSERVED is a counter observation only; a publish/pickup gap does not prove matching transaction pickup.',
      'Missing stages are unobserved, not necessarily failed. MCU_USB_COMPLETED and MCU_USB_FAILED are alternative local terminals, not two required success stages.',
      'Later complete CRC-valid PC reception cannot erase an earlier recorded local completion failure. Product Heartbeat and diagnostic frames are distinct transactions.',
      'MCU_USB_FAILED covers only the 106 ms PRODUCT_HEARTBEAT contract. DIAGNOSTIC partial/success observations are permitted, but diagnostic failures and their separate 500 ms budget are not modeled or reinterpreted as product failures.',
      'The frame enqueue timestamp is a prior-to-exposure boundary for this transaction. A strictly earlier bound PC frame validation is inconsistent evidence; equal or overlapping intervals do not establish order. A PC read may precede the later local flush return, which is not compared as a physical delivery boundary.',
      'Local USB completion, PC frame validation, RF delivery and 932-parameter acquisition are separate layers; this trace cannot authorize acceptance or deployment.')
  }
}

if($ImportOnly){if($InputPath-or$OutputPath){throw 'ImportOnly forbids CLI I/O arguments'};return}
try{
  if(-not$InputPath){throw 'InputPath is required; this tool evaluates saved JSON only'}
  $evidence=Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json
  $json=Get-R19TimedPathTraceEvaluation -Evidence $evidence|ConvertTo-Json -Depth 40
  if($OutputPath){$json|Set-Content -LiteralPath $OutputPath -Encoding utf8}
  $json
}catch{Write-Error -ErrorAction Continue ('OFFLINE_TIMED_PATH_TRACE_REJECTED: '+$_.Exception.Message);exit 1}
