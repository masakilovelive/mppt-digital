[CmdletBinding()]
param([switch]$ImportOnly,[switch]$DecodeOnly,[switch]$TestOnly,
  [string]$FixturePath,[string]$OutputPath)
# Definitions only on import. This decoder has no live/hardware/process mode.
function ConvertFrom-R19GrantDiagnosticRecord {
  param([byte[]]$First,[byte[]]$Second,
    [ValidateSet('ground','vehicle')][string]$ExpectedRole,
    [AllowNull()][object[]]$ExpectedFingerprint,[AllowNull()][object[]]$ExpectedBoot)
  $ErrorActionPreference='Stop';Set-StrictMode -Version Latest
  function Require([bool]$v,[string]$message){if(-not$v){throw $message}}
  function U64([uint32[]]$words,[int]$n){[uint64]$words[$n]+[uint64]$words[$n+1]*[uint64]4294967296}
  function Identity([object[]]$expected,[uint32[]]$words,[int]$offset){
    Require (@($expected).Count-eq4) 'Identity requires four uint32 words'
    for($i=0;$i-lt4;$i++){
      [decimal]$v=$expected[$i]
      Require ($v-ge0-and$v-le[uint32]::MaxValue-and$v-eq[math]::Floor($v)) 'Invalid identity word'
      Require ([uint32]$v-eq$words[$offset+$i]) 'Identity mismatch'
    }
  }
  $eventNames=@('None','Other','ObserveStandardGrant','ParameterRequest','FreshGrant','Tick','GrantGenerated','GrantWriteAccepted','GrantPhysicalTail','GrantReceivedRaw')
  $ownerStates=@('Disabled','Standard','AwaitFreshGrant','RequestReady','AwaitResponse','BulkReceive','TerminalEvidenceReady','TerminalAckReady','Complete','FailClosed')
  $coordinatorStates=@('Disabled','Idle','AwaitFreshGrant','RequestGuard','RequestReady','RequestDrain','AwaitResponse','BulkReceive','AwaitBulkTail','DirectionGuard','TerminalTransmit','AwaitTerminalPhysicalTail','AwaitTerminalCommit','Complete','FailClosed')
  $ownerResults=@('NoAction','FeatureDisabled','PassThrough','NotHighSpeedReady','GrantBaselineCaptured','ParameterRequestHeld','BusyHold','GrantArmed','NegotiationRequestReady','NegotiationRequestCommitted','NegotiationResponseReady','NegotiationResponseCommitted','BulkReceiveEnabled','BulkDownlinkEnabled','TerminalEvidenceReady','TerminalWindowOpened','TerminalAckCommitted','RetryRetained','SessionComplete','Rearmed','InvalidConfiguration','InvalidArgument','InvalidMavlink','InvalidState','StaleGrant','GrantDeadlineExceeded','PartialNegotiationRecord','InvalidNegotiationRecord','WrongGrantIdentity','PeerRejected','ReplayDetected','IdentityReuse','LeaseExpired','CompletionEvidenceMismatch','TerminalEvidenceMismatch','TerminalWindowEvidenceMismatch','TerminalWindowTimeout','TerminalAckTimeout','DecoderIncomplete','SenderIncomplete','ClockRegression','Latched')
  $coordinatorResults=@('NoAction','Ready','ActionReady','Accepted','RetryRetained','TailDrainAccepted','AwaitingPeer','BulkEnabled','TerminalWindowReady','SessionComplete','InvalidArgument','InvalidState','InvalidToken','InvalidWireRecord','EvidenceMismatch','GrantDeadlineExceeded','LeaseExpired','DirectionGuardIncomplete','TerminalWindowTimeout','ClockRegression','TokenExhausted','Latched')
  $adapterResults=@('NoAction','Disabled','PassThrough','Ready','Held','ActionReady','Accepted','RetryRetained','TailAccepted','BulkEnabled','UsbFrameStaged','AwaitUsbCommit','AwaitPixhawkCommit','UsbCommitted','TerminalReady','WindowOpened','Complete','Busy','InvalidArgument','InvalidState','OwnerRejected','CoordinatorRejected','ProducerRejected','LeaseRejected','ClockRegression','DeadlineExceeded','FailClosed')
  function Evidence([uint32[]]$words,[int]$offset){
    [uint32[]]$v=$words[$offset..($offset+31)]
    Require ($v[0]-le9-and($v[1]-band0xFFFFFF80L)-eq0) 'Unknown event/validity flags'
    Require ($v[2]-le9-and$v[3]-le9-and$v[4]-le14-and$v[5]-le14) 'Unknown owner/coordinator state'
    Require ($v[6]-le41-and$v[7]-le41-and$v[8]-le21-and$v[9]-le21) 'Unknown owner/coordinator result'
    Require ($v[10]-le26-and$v[11]-le26) 'Unknown adapter status/failure'
    for($i=24;$i-le27;$i++){Require ($v[$i]-le65535) 'Grant identity exceeds uint16'}
    Require ($v[31]-le255) 'Unknown wire disposition'
    if(($v[1]-band1)-eq0){Require ($v[6]-eq0) 'Unobserved owner result must be zero'}
    if(($v[1]-band2)-eq0){Require ($v[8]-eq0) 'Unobserved coordinator result must be zero'}
    foreach($spec in @(@(4,14),@(8,16),@(16,18),@(32,20),@(64,22))){if(($v[1]-band$spec[0])-eq0){Require ((U64 $v $spec[1])-eq0) 'Unavailable MCU clock must be zero'}}
    if(($v[1]-band16)-eq0){Require ($v[24]-eq0-and$v[25]-eq0) 'Unavailable standard Grant identity must be zero'}
    if(($v[1]-band32)-eq0){Require ($v[26]-eq0-and$v[27]-eq0) 'Unavailable fresh Grant identity must be zero'}
    if($v[0]-le5){Require ($v[29]-eq0-and$v[30]-eq0-and$v[31]-eq0) 'Adapter evidence reserved words must be zero'}
    else{
      Require ($v[1]-eq16-and(U64 $v 18)-eq(U64 $v 12)) 'Wire Grant requires matching observation clock'
      for($i=2;$i-le11;$i++){Require ($v[$i]-eq0) 'Wire Grant cannot invent adapter state'}
    }
    [pscustomobject][ordered]@{
      event=$v[0];event_name=$eventNames[$v[0]];validity_flags=$v[1]
      owner_state_before=$v[2];owner_state_after=$v[3];owner_state_before_name=$ownerStates[$v[2]];owner_state_after_name=$ownerStates[$v[3]]
      coordinator_state_before=$v[4];coordinator_state_after=$v[5];coordinator_state_before_name=$coordinatorStates[$v[4]];coordinator_state_after_name=$coordinatorStates[$v[5]]
      owner_result=$(if(($v[1]-band1)-ne0){$v[6]}else{$null});owner_result_observed=[bool](($v[1]-band1)-ne0);owner_last_error=$v[7]
      owner_result_name=$(if(($v[1]-band1)-ne0){$ownerResults[$v[6]]}else{'NotObserved'});owner_last_error_name=$ownerResults[$v[7]]
      coordinator_result=$(if(($v[1]-band2)-ne0){$v[8]}else{$null});coordinator_result_observed=[bool](($v[1]-band2)-ne0);coordinator_last_error=$v[9]
      coordinator_result_name=$(if(($v[1]-band2)-ne0){$coordinatorResults[$v[8]]}else{'NotObserved'});coordinator_last_error_name=$coordinatorResults[$v[9]]
      adapter_status=$v[10];adapter_failure_reason=$v[11];observed_ms=(U64 $v 12).ToString()
      adapter_status_name=$adapterResults[$v[10]];adapter_failure_reason_name=$adapterResults[$v[11]]
      request_origin_ms=$(if(($v[1]-band4)-ne0){(U64 $v 14).ToString()}else{$null})
      await_fresh_grant_started_ms=$(if(($v[1]-band8)-ne0){(U64 $v 16).ToString()}else{$null})
      standard_grant_observed_ms=$(if(($v[1]-band16)-ne0){(U64 $v 18).ToString()}else{$null})
      fresh_grant_observed_ms=$(if(($v[1]-band32)-ne0){(U64 $v 20).ToString()}else{$null})
      coordinator_grant_staged_ms=$(if(($v[1]-band64)-ne0){(U64 $v 22).ToString()}else{$null})
      standard_grant_session=$(if(($v[1]-band16)-ne0){$v[24]}else{$null});standard_grant_cycle=$(if(($v[1]-band16)-ne0){$v[25]}else{$null})
      fresh_grant_session=$(if(($v[1]-band32)-ne0){$v[26]}else{$null});fresh_grant_cycle=$(if(($v[1]-band32)-ne0){$v[27]}else{$null})
      source_line=$v[28];action_token=$(if($v[0]-ge6){$v[29]}else{$null});generation=$(if($v[0]-ge6){$v[30]}else{$null});disposition=$(if($v[0]-ge6){$v[31]}else{$null})
    }
  }
  Require ($ExpectedRole-ceq'ground'-or$ExpectedRole-ceq'vehicle') 'Unknown expected role'
  Require ([BitConverter]::IsLittleEndian) 'Decoder requires little-endian host'
  Require ($null-ne$First-and$null-ne$Second-and$First.Length-eq1024-and$Second.Length-eq1024) 'Record size must be exactly1024 bytes'
  for($i=0;$i-lt1024;$i++){Require ($First[$i]-eq$Second[$i]) 'Two reads differ'}
  [uint32[]]$w=[uint32[]]::new(256)
  for($i=0;$i-lt256;$i++){$w[$i]=[BitConverter]::ToUInt32($First,4*$i)}
  Require ($w[0]-eq0-and($w[1]-band1)-eq0) 'Unstable seqlock sample'
  Require ($w[2]-eq0x52313947-and$w[3]-eq1-and$w[14]-eq1024) 'Unknown record magic/schema/size'
  Require ($w[4]-eq$(if($ExpectedRole-ceq'ground'){1}else{2})) 'Role mismatch'
  if($null-ne$ExpectedFingerprint){Identity $ExpectedFingerprint $w 5};if($null-ne$ExpectedBoot){Identity $ExpectedBoot $w 9}
  Require (($w[9]-bor$w[10]-bor$w[11]-bor$w[12])-ne0) 'Zero boot identity'
  Require ($w[13]-eq1-or$w[13]-eq3) 'Uninitialized, unknown flags, or counter-overflow record'
  Require ($w[15]-eq0) 'Reserved header must be zero'
  for($i=85;$i-lt96;$i++){Require ($w[$i]-eq0) 'Reserved metadata must be zero'}
  $latched=($w[13]-band2)-ne0
  [uint64]$journalTotal=[uint64]$w[81]+[uint64]$w[83]
  Require ($w[81]-le10-and$journalTotal-le$w[80]) 'Journal/count capacity contradiction'
  Require ($w[81]-eq[math]::Min([uint64]10,$journalTotal)) 'Journal/drop count contradiction'
  $expectedNext=if($journalTotal-lt6){$journalTotal}else{6+($journalTotal-6)%4}
  Require ($w[82]-eq$expectedNext) 'Journal cursor contradiction'
  Require (($w[80]-eq0)-eq($w[81]-eq0)) 'Observed event missing from journal'
  $latest=Evidence $w 16;$firstFailure=Evidence $w 48
  if($w[80]-eq0){for($i=16;$i-lt48;$i++){Require ($w[$i]-eq0) 'Unobserved latest evidence must be zero'}}
  if(-not$latched){
    Require ($w[84]-eq0) 'Unlatched failure ordinal must be zero'
    for($i=48;$i-lt80;$i++){Require ($w[$i]-eq0) 'Unlatched first failure evidence must be zero'}
  }else{
    Require ($w[80]-gt0-and$w[84]-eq$w[80]) 'First-failure ordinal contradiction'
    for($i=0;$i-lt32;$i++){Require ($w[48+$i]-eq$w[16+$i]) 'Frozen latest/first failure differ'}
  }
  $journal=[Collections.Generic.List[object]]::new();[uint32]$previousOrdinal=0
  for($i=0;$i-lt$w[81];$i++){
    $slot=if($w[81]-lt10-or$i-lt6){$i}else{6+($w[82]-6+$i-6)%4};$o=96+16*$slot
    Require ($w[$o]-gt$previousOrdinal-and$w[$o]-le$w[80]) 'Journal ordinal out of order'
    $previousOrdinal=$w[$o]
    Require ($w[$o+1]-le9-and$w[$o+2]-le255) 'Unknown journal event/flags'
    [uint32]$journalValidity=$w[$o+2]-shr1
    if($w[$o+1]-le5){
      Require ($w[$o+5]-le9-and$w[$o+6]-le9-and$w[$o+7]-le14-and$w[$o+8]-le14) 'Unknown journal state'
      Require ($w[$o+9]-le41-and$w[$o+10]-le41-and$w[$o+11]-le21-and$w[$o+12]-le21-and$w[$o+13]-le26-and$w[$o+14]-le26) 'Unknown journal result'
      if(($journalValidity-band1)-eq0){Require ($w[$o+9]-eq0) 'Unobserved journal owner result must be zero'}
      if(($journalValidity-band2)-eq0){Require ($w[$o+11]-eq0) 'Unobserved journal coordinator result must be zero'}
    }else{
      Require ($journalValidity-eq16) 'Wire journal requires Grant observation availability'
      Require ($w[$o+5]-le65535-and$w[$o+6]-le65535-and$w[$o+9]-le255) 'Invalid Grant journal identity/disposition'
      for($k=10;$k-le14;$k++){Require ($w[$o+$k]-eq0) 'Wire journal reserved words must be zero'}
    }
    $isFailure=($w[$o+2]-band1)-eq1
    Require (-not$isFailure-or($latched-and$i-eq$w[81]-1-and$w[$o]-eq$w[84])) 'Failure flag outside immutable terminal event'
    $journal.Add([pscustomobject][ordered]@{
      ordinal=$w[$o];event=$w[$o+1];event_name=$eventNames[$w[$o+1]];failure=$isFailure;validity_flags=$journalValidity;observed_ms=(U64 $w ($o+3)).ToString()
      owner_state_before=$(if($w[$o+1]-le5){$w[$o+5]}else{$null});owner_state_after=$(if($w[$o+1]-le5){$w[$o+6]}else{$null})
      coordinator_state_before=$(if($w[$o+1]-le5){$w[$o+7]}else{$null});coordinator_state_after=$(if($w[$o+1]-le5){$w[$o+8]}else{$null})
      owner_result=$(if($w[$o+1]-le5-and($journalValidity-band1)-ne0){$w[$o+9]}else{$null});owner_last_error=$(if($w[$o+1]-le5){$w[$o+10]}else{$null})
      coordinator_result=$(if($w[$o+1]-le5-and($journalValidity-band2)-ne0){$w[$o+11]}else{$null});coordinator_last_error=$(if($w[$o+1]-le5){$w[$o+12]}else{$null})
      adapter_status=$(if($w[$o+1]-le5){$w[$o+13]}else{$null});adapter_failure_reason=$(if($w[$o+1]-le5){$w[$o+14]}else{$null})
      session=$(if($w[$o+1]-ge6){$w[$o+5]}else{$null});cycle=$(if($w[$o+1]-ge6){$w[$o+6]}else{$null})
      action_token=$(if($w[$o+1]-ge6){$w[$o+7]}else{$null});generation=$(if($w[$o+1]-ge6){$w[$o+8]}else{$null});disposition=$(if($w[$o+1]-ge6){$w[$o+9]}else{$null});source_line=$w[$o+15]
    })
  }
  for($i=$w[81];$i-lt10;$i++){for($k=0;$k-lt16;$k++){Require ($w[96+16*$i+$k]-eq0) 'Unused journal slot must be zero'}}
  if($latched){
    $last=$journal[$journal.Count-1]
    Require ($last.failure-and$last.ordinal-eq$w[84]-and$last.event-eq$firstFailure.event-and$last.observed_ms-ceq$firstFailure.observed_ms-and$last.source_line-eq$firstFailure.source_line) 'Terminal journal/failure contradiction'
    Require ($last.validity_flags-eq$firstFailure.validity_flags) 'Terminal journal/failure availability differs'
    if($last.event-le5){
      foreach($name in @('owner_state_before','owner_state_after','coordinator_state_before','coordinator_state_after','owner_result','owner_last_error','coordinator_result','coordinator_last_error','adapter_status','adapter_failure_reason')){Require ($last.$name-eq$firstFailure.$name) 'Terminal journal/failure state differs'}
    }else{
      Require ($last.session-eq$firstFailure.standard_grant_session-and$last.cycle-eq$firstFailure.standard_grant_cycle-and$last.action_token-eq$firstFailure.action_token-and$last.generation-eq$firstFailure.generation-and$last.disposition-eq$firstFailure.disposition) 'Terminal wire Grant/failure differs'
    }
  }
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$hash=([BitConverter]::ToString($sha.ComputeHash($First))).Replace('-','')}finally{$sha.Dispose()}
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-grant-diagnostic-decoded-v1';result='PASS';mode='offline-only';hardware_interaction=$false
    raw_size_bytes=1024;raw_sha256=$hash;record_schema=$w[3];sequence=$w[1];role=$ExpectedRole
    build_fingerprint=@($w[5..8]);boot_instance=@($w[9..12]);expected_identity_bound=[bool]($null-ne$ExpectedFingerprint-and$null-ne$ExpectedBoot)
    failure_latched=$latched;observation_count=$w[80];latest=$(if($w[80]-gt0){$latest}else{$null});first_failure=$(if($latched){$firstFailure}else{$null})
    first_failure_ordinal=$w[84];journal_count=$w[81];journal_dropped=$w[83];journal_complete=[bool]($w[83]-eq0);journal_retention='first-six-last-four';journal=@($journal.ToArray())
    grant_deadline_exceeded_proven=$false;rf_delivery_proven=$false;acceptance_authorized=$false;deployment_authorized=$false
    limitations=@(
      'JTAG-only RAM observations; no change to500ms,2000ms,106ms, UART, RF, or TDD policy.',
      'Unavailable clocks/results remain null; MCU milliseconds are not PC clock or physical RF timing.',
      'Standard/fresh Grant observation, adapter staging, UART acceptance, and physical-tail completion are separate boundaries.',
      'Journal retains first six and last four meaningful events; dropped events prohibit conclusions from absence.',
      'A recorded adapter error explains the local stop contract, not automatically the upstream reason a Grant did not arrive.',
      'Stable decoding alone proves neither hardware acquisition provenance nor product acceptance.'
    )
  }
}
if($ImportOnly){if($DecodeOnly-or$TestOnly-or$FixturePath-or$OutputPath){throw 'ImportOnly forbids CLI I/O'};return}
try{
  if(-not($DecodeOnly-or$TestOnly)){throw 'DecodeOnly or TestOnly required; no live mode exists'}
  $fixture=Get-Content -LiteralPath $FixturePath -Raw|ConvertFrom-Json
  if($fixture.schema-cne'vc-lora-r19-grant-diagnostic-fixture-v1'){throw 'Unknown fixture schema'}
  if(-not$fixture.PSObject.Properties['build_fingerprint']-or-not$fixture.PSObject.Properties['boot_instance']){throw 'CLI fixture requires fingerprint and boot'}
  $decoded=ConvertFrom-R19GrantDiagnosticRecord -First ([Convert]::FromBase64String($fixture.first_read_base64)) -Second ([Convert]::FromBase64String($fixture.second_read_base64)) -ExpectedRole $fixture.role -ExpectedFingerprint $fixture.build_fingerprint -ExpectedBoot $fixture.boot_instance
  $json=$decoded|ConvertTo-Json -Depth 14;if($OutputPath){$json|Set-Content -LiteralPath $OutputPath -Encoding utf8};$json;exit 0
}catch{Write-Error -ErrorAction Continue ('OFFLINE_DECODE_REJECTED: '+$_.Exception.Message);exit 1}
