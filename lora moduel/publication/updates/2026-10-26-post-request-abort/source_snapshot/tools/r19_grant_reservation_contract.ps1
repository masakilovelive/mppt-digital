# Separate, source-bound diagnostic capability contract. Existing USB role-v1
# metadata remains unchanged. This is never constructed from a feasible plan.
function Get-R19GrantReservationRoleCapabilities {
  [pscustomobject][ordered]@{ground=@('Bind','Held','TailPermit');vehicle=@('Prepare','Release','TailReady')}
}
function Get-R19GrantReservationCandidateContract {
  param([Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false,[bool]$CancellationEnabled=$false,[bool]$AgreementEnabled=$false,[bool]$FatalEnabled=$false)
  if($FatalEnabled-and-not$AgreementEnabled){throw 'Fatal diagnostics require agreement diagnostics'}
  if($AgreementEnabled-and-not$CancellationEnabled){throw 'Agreement requires cancellation diagnostics'}
  if($CancellationEnabled-and-not$Enabled){throw 'Cancellation requires reservation diagnostics'}
  if(-not$Enabled){return $null}
  $decoder='tools/read_r19_grant_reservation_record.ps1'
  $contract=[pscustomobject][ordered]@{
    schema='vc-lora-r19-grant-reservation-candidate-v1';enabled=$true
    macro='VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS';reader_schema='vc-lora-r19-runtime-stage-jtag-read-v10'
    record=[pscustomobject][ordered]@{symbol='vc_lora_r19_grant_reservation_record';schema_version=1;size_bytes=512}
    decoder=[pscustomobject][ordered]@{path=$decoder;sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $decoder) -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()}
    usb_control=[pscustomobject][ordered]@{schema='vc-lora-r19-grant-reservation-usb-v1';frame_bytes=66;magic='R19R';request_component=197;response_component=198}
    capture=[pscustomobject][ordered]@{mode='HostAssistedDualUsbReservation';prepare_seconds=15;measurement_seconds=40;param_request_maximum=1}
    producer=[pscustomobject][ordered]@{kind='actual-dual-usb-grant-hold-tail-release';role_capabilities=Get-R19GrantReservationRoleCapabilities}
  }
  if($CancellationEnabled){
    $contract.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v11'
    $contract.usb_control.schema='vc-lora-r19-grant-reservation-usb-v2'
    $contract|Add-Member -NotePropertyName cancellation -NotePropertyValue (Get-R19GrantReservationCancellationCapability)
  }
  if($AgreementEnabled){$contract.usb_control.schema='vc-lora-r19-grant-reservation-usb-v3'}
  if($FatalEnabled){$contract.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v12'}
  return $contract
}
function Assert-R19GrantReservationShape {
  param([object]$Actual,[object]$Expected,[string]$Path)
  if($null-eq$Expected){if($null-ne$Actual){throw "Unexpected reservation metadata: $Path"};return}
  if($Expected-is[bool]){if($Actual-isnot[bool]-or$Actual-ne$Expected){throw "Reservation Boolean differs: $Path"};return}
  if($Expected-is[string]){if($Actual-isnot[string]-or$Actual-cne$Expected){throw "Reservation string differs: $Path"};return}
  if($Expected-is[int]-or$Expected-is[long]){if(($Actual-isnot[int]-and$Actual-isnot[long])-or$Actual-ne$Expected){throw "Reservation exact integer differs: $Path"};return}
  if($Expected-is[array]){
    if($Actual-isnot[array]-or$Actual.Count-ne$Expected.Count){throw "Reservation array differs: $Path"}
    for($i=0;$i-lt$Expected.Count;$i++){Assert-R19GrantReservationShape $Actual[$i] $Expected[$i] ($Path+'['+$i+']')}
    return
  }
  if($null-eq$Actual-or$Actual-is[string]-or$Actual-is[ValueType]-or$Actual-is[array]){throw "Reservation object missing: $Path"}
  $names=@($Actual.PSObject.Properties.Name);$expectedNames=@($Expected.PSObject.Properties.Name)
  if($names.Count-ne$expectedNames.Count){throw "Reservation property count differs: $Path"}
  foreach($name in $expectedNames){
    if($names-cnotcontains$name){throw "Reservation exact property missing: $Path.$name"}
    Assert-R19GrantReservationShape $Actual.$name $Expected.$name ($Path+'.'+$name)
  }
}
function Assert-R19GrantReservationCandidateContract {
  param([object]$Value,[Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false,[bool]$CancellationEnabled=$false,[bool]$AgreementEnabled=$false,[bool]$FatalEnabled=$false)
  $expected=Get-R19GrantReservationCandidateContract -RepoRoot $RepoRoot -Enabled $Enabled -CancellationEnabled $CancellationEnabled -AgreementEnabled $AgreementEnabled -FatalEnabled $FatalEnabled
  Assert-R19GrantReservationShape $Value $expected 'grant_reservation_diagnostics'
  return $expected
}

function Get-R19GrantReservationCancellationCapability {
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-grant-reservation-cancellation-v1';maximum_cancellations=1
    opcodes=[pscustomobject][ordered]@{CancelRequest=15;CancelAck=16;Withdrawn=17;CancelPeerConfirmed=18}
  }
}

# Separately opt-in; the original reservation-v10 contract is unchanged.
function Get-R19GrantReservationStopCandidateContract {
  param([Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false,[bool]$AgreementEnabled=$false,[bool]$FatalEnabled=$false)
  if($FatalEnabled-and-not$AgreementEnabled){throw 'Fatal diagnostics require agreement diagnostics'}
  if($AgreementEnabled-and-not$Enabled){throw 'Agreement requires STOP diagnostics'}
  if(-not$Enabled){return $null}
  $decoder='tools/read_r19_grant_reservation_stop_record.ps1'
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-grant-reservation-stop-candidate-v1';enabled=$true
    macro='VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS'
    record_schema=1;size_bytes=128;symbol='vc_lora_r19_grant_reservation_stop_record'
    decoder_path=$decoder
    decoder_sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $decoder) -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    runtime_reader_schema=$(if($FatalEnabled){'vc-lora-r19-runtime-stage-jtag-read-v12'}else{'vc-lora-r19-runtime-stage-jtag-read-v11'})
    usb_control_schema=$(if($AgreementEnabled){'vc-lora-r19-grant-reservation-usb-v3'}else{'vc-lora-r19-grant-reservation-usb-v2'})
    cancellation=Get-R19GrantReservationCancellationCapability
  }
}
function Assert-R19GrantReservationStopCandidateContract {
  param([object]$Value,[Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false,[bool]$AgreementEnabled=$false,[bool]$FatalEnabled=$false)
  $expected=Get-R19GrantReservationStopCandidateContract -RepoRoot $RepoRoot -Enabled $Enabled -AgreementEnabled $AgreementEnabled -FatalEnabled $FatalEnabled
  Assert-R19GrantReservationShape $Value $expected 'grant_reservation_stop_diagnostics'
  return $expected
}

# Wire-v3 capability is separate from the unchanged reservation512/STOP128
# observation ABI. CommitAck is a point-in-time fact, not distributed atomicity.
function Get-R19GrantAgreementCandidateContract {
  param([Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false,[bool]$FatalEnabled=$false)
  if($FatalEnabled-and-not$Enabled){throw 'Fatal diagnostics require agreement diagnostics'}
  if(-not$Enabled){return $null}
  $paths=@('firmware/phase6/vc_lora_phase6_bridge.hpp','firmware/high_speed/r19_grant_reservation.hpp',
    'tools/r19_grant_reservation_wire.ps1','tools/r19_grant_reservation_workflow.ps1',
    'tools/r19_grant_reservation_contract.ps1','tools/run_r19_timed_path_capture.ps1',
    'tools/build_r19_candidate_artifacts.ps1','tools/r19_candidate_artifact_common.ps1','tools/verify_r19_candidate_artifact.ps1')
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-grant-agreement-candidate-v1';enabled=$true
    macro='VC_LORA_R19_GRANT_AGREEMENT_DIAGNOSTICS'
    requires_stop_diagnostics=$true;usb_control_schema='vc-lora-r19-grant-reservation-usb-v3';wire_version=3;frame_bytes=66
    runtime_reader_schema=$(if($FatalEnabled){'vc-lora-r19-runtime-stage-jtag-read-v12'}else{'vc-lora-r19-runtime-stage-jtag-read-v11'});reservation_record_bytes=512;stop_record_bytes=128
    capability_symbol='vc_lora_r19_grant_agreement_capability';capability_symbol_bytes=4
    capability_symbol_evidence='compiled-v3-capability-only-not-runtime-completion'
    opcodes=[pscustomobject][ordered]@{CommitRequest=19;CommitAck=20;AbortRequest=21;AbortAck=22}
    commit=[pscustomobject][ordered]@{requires_both_role_ack_before_param=$true;ack_is_future_cancellation_guarantee=$false;current_tuple_revalidated=$true}
    terminal_abort=[pscustomobject][ordered]@{requires_both_role_ack=$true;unknown_prefix_retry_allowed=$false;param_reissue_allowed=$false;maximum_abort_requests_per_role=1;missing_ack_result='ABORTED_UNCONFIRMED'}
    source_bindings=@($paths|ForEach-Object{[pscustomobject][ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $_) -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()}})
  }
}
function Assert-R19GrantAgreementCandidateContract {
  param([object]$Value,[Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false,[bool]$FatalEnabled=$false)
  $expected=Get-R19GrantAgreementCandidateContract -RepoRoot $RepoRoot -Enabled $Enabled -FatalEnabled $FatalEnabled
  Assert-R19GrantReservationShape $Value $expected 'grant_agreement_diagnostics'
  return $expected
}

# A separate first-fatal latch does not change reservation512 or first-STOP128.
function Get-R19GrantReservationFatalCandidateContract {
  param([Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false)
  if(-not$Enabled){return $null}
  $decoder='tools/read_r19_grant_reservation_fatal_record.ps1'
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-grant-reservation-fatal-candidate-v1';enabled=$true
    macro='VC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS'
    scope='reserved-grant-detail13-only'
    runtime_reader_schema='vc-lora-r19-runtime-stage-jtag-read-v12'
    record=[pscustomobject][ordered]@{symbol='vc_lora_r19_grant_reservation_fatal_record';schema_version=1;size_bytes=128}
    decoder=[pscustomobject][ordered]@{path=$decoder;sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $decoder) -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()}
    paired_raw_reads=24
  }
}
function Assert-R19GrantReservationFatalCandidateContract {
  param([object]$Value,[Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false)
  $expected=Get-R19GrantReservationFatalCandidateContract -RepoRoot $RepoRoot -Enabled $Enabled
  Assert-R19GrantReservationShape $Value $expected 'grant_reservation_fatal_diagnostics'
  return $expected
}
