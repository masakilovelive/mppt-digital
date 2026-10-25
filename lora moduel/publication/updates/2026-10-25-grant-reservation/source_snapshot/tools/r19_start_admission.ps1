# Pure bounded planning only. There is no future-slot producer or live authority.
function Get-R19StartAdmissionInteger {
  param([object]$Value,[string]$Name,[bool]$StringOnly=$true,[string]$Maximum='18446744073709551615')
  if($StringOnly){if($Value-isnot[string]-or$Value-cnotmatch'^(0|[1-9][0-9]*)$'){throw ('INVALID_'+$Name)}}
  elseif(($Value-isnot[int]-and$Value-isnot[long])-or$Value-lt0){throw ('INVALID_'+$Name)}
  $n=[Numerics.BigInteger]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)
  if($n-gt[Numerics.BigInteger]::Parse($Maximum)){throw ('INVALID_'+$Name)}
  return $n
}
function Assert-R19StartAdmissionFields {
  param([object]$Value,[string[]]$Fields,[string]$Name)
  if($null-eq$Value-or$Value-is[string]-or$Value-is[ValueType]-or$Value-is[array]){throw ('INVALID_'+$Name)}
  $actual=@($Value.PSObject.Properties.Name)
  if($actual.Count-ne$Fields.Count){throw ('INVALID_'+$Name+'_FIELDS')}
  foreach($f in $Fields){if($actual-cnotcontains$f){throw ('INVALID_'+$Name+'_FIELDS')}}
}
function Get-R19StartAdmissionIdentity {
  param([object]$Value,[switch]$Expected)
  $fields=@('candidate_id','build_fingerprint','boot_id','reader_session','usb_epoch','ground_clock_id','slot_token','slot_generation','grant_session','grant_cycle')
  if($Expected){$fields+=@('baseline_session','baseline_cycle','baseline_slot_generation')}
  Assert-R19StartAdmissionFields $Value $fields 'IDENTITY'
  if($Value.candidate_id-isnot[string]-or$Value.candidate_id-cnotmatch'^[A-Za-z0-9._-]{1,128}$'){throw 'INVALID_CANDIDATE_ID'}
  foreach($f in @('build_fingerprint','boot_id','ground_clock_id')){if($Value.$f-isnot[string]-or$Value.$f-cnotmatch'^[A-F0-9]{32}$'){throw ('INVALID_'+$f)}}
  if($Value.boot_id-ceq('0'*32)){throw 'INVALID_BOOT_ID'}
  foreach($f in @('reader_session','usb_epoch')){[void](Get-R19StartAdmissionInteger $Value.$f $f)}
  if($Value.reader_session-ceq'0'){throw 'INVALID_READER_SESSION'}
  foreach($f in @('slot_token','slot_generation','grant_session','grant_cycle')){[void](Get-R19StartAdmissionInteger $Value.$f $f $false $(if($f-like'grant_*'){'65535'}else{'4294967295'}))}
  if($Value.slot_token-eq0-or$Value.slot_generation-eq0){throw 'INVALID_SLOT_TOKEN_OR_GENERATION'}
  if($Value.grant_session-eq0-or$Value.grant_cycle-eq0){throw 'INVALID_ZERO_GRANT_SESSION_OR_CYCLE'}
  if($Expected){
    foreach($f in @('baseline_session','baseline_cycle','baseline_slot_generation')){[void](Get-R19StartAdmissionInteger $Value.$f $f $false $(if($f-ceq'baseline_slot_generation'){'4294967295'}else{'65535'}))}
    if($Value.baseline_session-eq0){throw 'INVALID_UNINITIALIZED_BASELINE_SESSION'}
  }
  # Copy scalar values so a caller mutation cannot change the expected tuple.
  $copy=[ordered]@{};foreach($f in $fields){$copy[$f]=$Value.$f};return [pscustomobject]$copy
}
function New-R19StartAdmissionState {
  param([object]$ExpectedBinding=$null,[Parameter(Mandatory)][int64]$Frequency,
    [Parameter(Mandatory)][string]$ClockDomainId,[string]$OriginalT0GroundMs='',
    [bool]$OfflineSimulation=$false,[ValidateRange(2,256)][int]$MaximumEvents=64)
  if($Frequency-lt1-or$Frequency-gt1000000000-or[string]::IsNullOrWhiteSpace($ClockDomainId)-or$ClockDomainId.Length-gt128){throw 'INVALID_PC_CLOCK'}
  $binding=if($null-ne$ExpectedBinding){Get-R19StartAdmissionIdentity $ExpectedBinding -Expected}else{$null}
  if($OriginalT0GroundMs){[void](Get-R19StartAdmissionInteger $OriginalT0GroundMs 'ORIGINAL_T0')}
  [pscustomobject]@{schema='vc-lora-r19-start-admission-state-v1';frequency=$Frequency.ToString([Globalization.CultureInfo]::InvariantCulture);clock_domain_id=$ClockDomainId
    expected_binding=$binding;original_t0_ground_ms=$OriginalT0GroundMs;offline_simulation=$OfflineSimulation;maximum_events=$MaximumEvents
    evaluation_count=0L;events_dropped=0L;events=[Collections.Generic.List[object]]::new();last_now_ticks=$null;simulation_writer_attempted=$false}
}
function Add-R19StartAdmissionHistory {
  param([object]$State,[object]$Decision)
  if($State.evaluation_count-ge[int64]::MaxValue){throw 'ADMISSION_HISTORY_COUNTER_EXHAUSTED'}
  $State.evaluation_count++
  # Deep-copy only bounded normalized scalar evidence, never a caller's mutable
  # object. This history is arithmetic evidence, not slot authentication.
  $event=$Decision|ConvertTo-Json -Depth 12 -Compress|ConvertFrom-Json
  Add-Member -InputObject $event -NotePropertyName ordinal -NotePropertyValue $State.evaluation_count
  if($State.events.Count-ge$State.maximum_events){$State.events.RemoveAt([int]($State.maximum_events/2));$State.events_dropped++}
  $State.events.Add($event)
}
function Test-R19StartAdmissionNewerGrant {
  param([int]$Session,[int]$Cycle,[int]$BaselineSession,[int]$BaselineCycle)
  $sessionDelta=([long]$Session-$BaselineSession+65536)%65536
  if($sessionDelta-ne0){return $sessionDelta-lt32768}
  $cycleDelta=([long]$Cycle-$BaselineCycle+65536)%65536
  return $cycleDelta-gt0-and$cycleDelta-lt32768
}
function Get-R19StartAdmissionInterval {
  param([object]$Value,[string]$Name)
  Assert-R19StartAdmissionFields $Value @('earliest_ms','latest_ms','bounded') $Name
  if($Value.bounded-isnot[bool]-or-not$Value.bounded){throw ('UNBOUNDED_'+$Name)}
  $lo=Get-R19StartAdmissionInteger $Value.earliest_ms ($Name+'_EARLIEST')
  $hi=Get-R19StartAdmissionInteger $Value.latest_ms ($Name+'_LATEST')
  if($lo-gt$hi){throw ('REVERSED_'+$Name)}
  [pscustomobject]@{low=$lo;high=$hi}
}
function Get-R19StartAdmissionGroundNow {
  param([object]$Correlation,[object]$State,[Numerics.BigInteger]$Now)
  Assert-R19StartAdmissionFields $Correlation @('schema','clock_domain_id','frequency','ground_clock_id','pc_anchor_ticks','ground_at_anchor','valid_until_ticks','max_age_ms','maximum_drift_ppm') 'CLOCK_MAPPING'
  if($Correlation.schema-cne'vc-lora-r19-bounded-pc-ground-clock-v1'-or$Correlation.clock_domain_id-cne$State.clock_domain_id-or$Correlation.frequency-cne$State.frequency-or$Correlation.ground_clock_id-cne$State.expected_binding.ground_clock_id){throw 'CLOCK_MAPPING_IDENTITY_MISMATCH'}
  $anchor=Get-R19StartAdmissionInteger $Correlation.pc_anchor_ticks 'CLOCK_ANCHOR' $true '9223372036854775807'
  $until=Get-R19StartAdmissionInteger $Correlation.valid_until_ticks 'CLOCK_UNTIL' $true '9223372036854775807'
  $age=Get-R19StartAdmissionInteger $Correlation.max_age_ms 'CLOCK_MAX_AGE' $false '60000'
  $ppm=Get-R19StartAdmissionInteger $Correlation.maximum_drift_ppm 'CLOCK_DRIFT' $false '1000000'
  if($age-eq0-or$until-lt$anchor-or$Now-lt$anchor-or$Now-gt$until){throw 'CLOCK_MAPPING_EXPIRED_OR_FUTURE'}
  $at=Get-R19StartAdmissionInterval $Correlation.ground_at_anchor 'CLOCK_ANCHOR_INTERVAL'
  $frequency=[Numerics.BigInteger]::Parse($State.frequency);$numerator=($Now-$anchor)*1000
  if($numerator-gt$age*$frequency){throw 'CLOCK_MAPPING_TOO_OLD'}
  $floor=[Numerics.BigInteger]::Divide($numerator,$frequency)
  $ceil=[Numerics.BigInteger]::Divide($numerator+$frequency-1,$frequency)
  $denominator=$frequency*1000000
  $drift=[Numerics.BigInteger]::Divide($numerator*$ppm+$denominator-1,$denominator)
  $lo=$at.low+$floor-$drift;$hi=$at.high+$ceil+$drift
  if($lo-lt0-or$hi-gt[Numerics.BigInteger]::Parse('18446744073709551615')){throw 'CLOCK_MAPPING_OVERFLOW'}
  [pscustomobject]@{low=$lo;high=$hi}
}
function Test-R19StartAdmissionEvidence {
  param([Parameter(Mandatory)][object]$State,[object]$Evidence=$null,[Parameter(Mandatory)][string]$NowTicks,[string]$PrerequisiteFailure='')
  $decision=[pscustomobject][ordered]@{schema='vc-lora-r19-start-admission-decision-v1';result='NOT_READY_NO_WRITE';reason='UNKNOWN';now_ticks=$NowTicks
    feasible_plan=$false;live_start_authorized=$false;reservation_proven=$false;offline_simulation=$false
    expected_binding=$null;evaluated_slot_identity=$null;original_t0_ground_ms=$null;evidence_sha256=$null;evidence_hash_scope='UTF8_COMPRESSED_JSON_NOT_CANONICAL_AUTHENTICATION'
    ground_now=$null;ground_request_accept=$null;ground_next_grant=$null;ground_wait_max_ms=$null;vehicle_age_max_ms=$null;projected_vehicle_complete=$null
    limitations=@('Synthetic bounded plan only; no implemented future-slot producer authenticates or reserves this slot.','PC and MCU clocks are compared only through the explicit bounded interval; the two MCU clocks are never subtracted.','500 ms Ground/Vehicle windows, 100 ms guard, original PARAM deadline and single-write policy are unchanged.')}
  try{
    if($State.schema-cne'vc-lora-r19-start-admission-state-v1'){throw 'INVALID_ADMISSION_STATE'}
    $now=Get-R19StartAdmissionInteger $NowTicks 'NOW_TICKS' $true '9223372036854775807'
    if($null-ne$State.last_now_ticks-and$now-lt[Numerics.BigInteger]::Parse($State.last_now_ticks)){throw 'PC_CLOCK_REGRESSION'}
    $State.last_now_ticks=$NowTicks
    if($PrerequisiteFailure){throw $PrerequisiteFailure}
    if($State.offline_simulation-isnot[bool]-or-not$State.offline_simulation){throw 'FUTURE_SLOT_PRODUCER_UNAVAILABLE_LIVE_START_FORBIDDEN'}
    $decision.offline_simulation=$true
    if($State.simulation_writer_attempted-isnot[bool]-or$State.simulation_writer_attempted){throw 'SLOT_ALREADY_USED'}
    if($null-eq$State.expected_binding-or-not$State.original_t0_ground_ms){throw 'EXPECTED_BINDING_OR_REQUEST_ORIGIN_MISSING'}
    $expected=Get-R19StartAdmissionIdentity $State.expected_binding -Expected
    $decision.expected_binding=$expected
    if($null-eq$Evidence){throw 'FUTURE_SLOT_EVIDENCE_MISSING'}
    Assert-R19StartAdmissionFields $Evidence @('schema','mode','identity','producer_bound','unused','request_before_grant_at_equal_timestamp','issued_ground_ms','expires_ground_ms','original_t0_ground_ms','clock_correlation','ground_request_accept','ground_next_grant','vehicle_grant_physical_tail','vehicle_complete_vcbn','vehicle_clock_at_ground_grant','transport_after_ground_guard') 'EVIDENCE'
    if($Evidence.schema-cne'vc-lora-r19-start-admission-plan-evidence-v1'-or$Evidence.mode-cne'OFFLINE_SIMULATION'){throw 'UNSUPPORTED_SLOT_EVIDENCE'}
    $identity=Get-R19StartAdmissionIdentity $Evidence.identity
    $decision.evaluated_slot_identity=$identity
    foreach($f in $identity.PSObject.Properties.Name){if($identity.$f-cne$expected.$f){throw ('SLOT_IDENTITY_MISMATCH_'+$f)}}
    if($identity.slot_generation-le$expected.baseline_slot_generation-or-not(Test-R19StartAdmissionNewerGrant $identity.grant_session $identity.grant_cycle $expected.baseline_session $expected.baseline_cycle)){throw 'STALE_OR_AMBIGUOUS_BASELINE_GRANT'}
    foreach($f in @('producer_bound','unused','request_before_grant_at_equal_timestamp')){if($Evidence.$f-isnot[bool]){throw ('NON_BOOLEAN_'+$f)}}
    if(-not$Evidence.producer_bound){throw 'SLOT_PRODUCER_UNBOUND'}
    if(-not$Evidence.unused){throw 'SLOT_ALREADY_USED'}
    $origin=Get-R19StartAdmissionInteger $Evidence.original_t0_ground_ms 'REQUEST_ORIGIN'
    $decision.original_t0_ground_ms=$origin.ToString()
    if($Evidence.original_t0_ground_ms-cne$State.original_t0_ground_ms){throw 'REQUEST_ORIGIN_CHANGED'}
    $groundNow=Get-R19StartAdmissionGroundNow $Evidence.clock_correlation $State $now
    $decision.ground_now=[pscustomobject]@{earliest_ms=$groundNow.low.ToString();latest_ms=$groundNow.high.ToString()}
    $issued=Get-R19StartAdmissionInteger $Evidence.issued_ground_ms 'SLOT_ISSUED'
    $expires=Get-R19StartAdmissionInteger $Evidence.expires_ground_ms 'SLOT_EXPIRES'
    if($issued-gt$groundNow.low-or$expires-lt$groundNow.high-or$expires-le$issued){throw 'SLOT_EXPIRED_OR_NOT_YET_ISSUED'}
    $request=Get-R19StartAdmissionInterval $Evidence.ground_request_accept 'GROUND_REQUEST'
    $grant=Get-R19StartAdmissionInterval $Evidence.ground_next_grant 'GROUND_GRANT'
    $decision.ground_request_accept=[pscustomobject]@{earliest_ms=$request.low.ToString();latest_ms=$request.high.ToString()}
    $decision.ground_next_grant=[pscustomobject]@{earliest_ms=$grant.low.ToString();latest_ms=$grant.high.ToString()}
    if($issued-gt$request.low-or$expires-lt$grant.high){throw 'SLOT_VALIDITY_DOES_NOT_COVER_REQUEST_AND_GRANT'}
    # This is a proposed request time and clock interval in an explicit offline
    # fixture, not evidence that any real MCU accepted a request at that time.
    if($origin-lt$request.low-or$origin-gt$request.high-or$groundNow.low-lt$request.low-or$groundNow.high-gt$request.high){throw 'REQUEST_OUTSIDE_MAPPED_GROUND_INTERVAL'}
    if($request.high-gt$grant.low){throw 'GRANT_MAY_PRECEDE_REQUEST'}
    if($request.high-eq$grant.low-and-not$Evidence.request_before_grant_at_equal_timestamp){throw 'EQUAL_TIMESTAMP_ORDER_UNPROVEN'}
    $groundWait=$grant.high-$request.low
    $decision.ground_wait_max_ms=$groundWait.ToString()
    if($groundWait-gt500){throw 'GROUND_GRANT_500_MS_EXCEEDED'}
    $tail=Get-R19StartAdmissionInterval $Evidence.vehicle_grant_physical_tail 'VEHICLE_TAIL'
    $complete=Get-R19StartAdmissionInterval $Evidence.vehicle_complete_vcbn 'VEHICLE_COMPLETE'
    if($complete.low-lt$tail.high){throw 'VEHICLE_COMPLETE_MAY_PRECEDE_TAIL'}
    $vehicleAge=$complete.high-$tail.low
    $decision.vehicle_age_max_ms=$vehicleAge.ToString()
    if($vehicleAge-gt500){throw 'VEHICLE_GRANT_500_MS_EXCEEDED'}
    $mapping=Get-R19StartAdmissionInterval $Evidence.vehicle_clock_at_ground_grant 'VEHICLE_CLOCK_AT_GROUND_GRANT'
    $transport=Get-R19StartAdmissionInterval $Evidence.transport_after_ground_guard 'TRANSPORT_AFTER_GROUND_GUARD'
    $projectionLo=$mapping.low+100+$transport.low;$projectionHi=$mapping.high+100+$transport.high
    if($projectionHi-gt[Numerics.BigInteger]::Parse('18446744073709551615')){throw 'GUARD_TRANSPORT_PROJECTION_OVERFLOW'}
    if($complete.low-gt$projectionLo-or$complete.high-lt$projectionHi){throw 'VEHICLE_INTERVAL_DOES_NOT_CONTAIN_GUARD_TRANSPORT_PROJECTION'}
    $decision.ground_wait_max_ms=$groundWait.ToString();$decision.vehicle_age_max_ms=$vehicleAge.ToString()
    $decision.projected_vehicle_complete=[pscustomobject]@{earliest_ms=$projectionLo.ToString();latest_ms=$projectionHi.ToString()}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$decision.evidence_sha256=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Evidence|ConvertTo-Json -Depth 10 -Compress)))).Replace('-','')}finally{$sha.Dispose()}
    $decision.feasible_plan=$true;$decision.result='FEASIBLE_PLAN_NOT_RESERVATION';$decision.reason='OFFLINE_BOUNDED_PLAN_FEASIBLE_NOT_LIVE_AUTHORITY'
  }catch{$decision.reason=$_.Exception.Message}
  Add-R19StartAdmissionHistory $State $decision
  return $decision
}
function Get-R19StartAdmissionSnapshot {
  param([Parameter(Mandatory)][object]$State)
  $events=@($State.events.ToArray()|ForEach-Object{$_|ConvertTo-Json -Depth 12 -Compress|ConvertFrom-Json})
  [pscustomobject]@{schema='vc-lora-r19-start-admission-history-v1';frequency=$State.frequency;clock_domain_id=$State.clock_domain_id
    offline_simulation=$State.offline_simulation;request_origin_ground_ms=$State.original_t0_ground_ms;evaluation_count=$State.evaluation_count
    maximum_events=$State.maximum_events;events_dropped=$State.events_dropped;history_complete=($State.events_dropped-eq0)
    simulation_writer_attempted=$State.simulation_writer_attempted;events=$events;live_start_authorized=$false;reservation_proven=$false}
}
function Get-R19TransferRouteClassification {
  param([object]$Observations=$null)
  # Current records do not expose the fallback RAM counter or any authenticated
  # future-slot reservation. Counts, caller flags and plan feasibility are not
  # substitutes. In particular a caller cannot promote Boolean claims here.
  [pscustomobject]@{schema='vc-lora-r19-transfer-route-classification-v1';classification='UNKNOWN_ROUTE_NOT_HIGH_SPEED_SUCCESS'
    high_speed_success_proven=$false;r18_fallback_proven=$false;rf_delivery_proven=$false;acceptance_authorized=$false;deployment_authorized=$false
    reason='CURRENT_PROVENANCE_AND_FUTURE_SLOT_PRODUCER_UNAVAILABLE';observation_status='NOT_OBSERVED';actual_negotiation_start_ms=$null;actual_bulk_start_ms=$null
    limitations=@('Heartbeat or PARAM_VALUE counts do not identify the route.','A feasible plan is neither a reservation nor recorded high-speed transfer success.','Current JTAG ABI does not expose the fallback-only RAM counter; do not infer it from continued traffic.','Caller-provided success/fallback/provenance Booleans are not trusted observations.')}
}
