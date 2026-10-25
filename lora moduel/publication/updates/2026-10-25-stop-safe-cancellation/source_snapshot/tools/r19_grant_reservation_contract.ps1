# Separate, source-bound diagnostic capability contract. Existing USB role-v1
# metadata remains unchanged. This is never constructed from a feasible plan.
function Get-R19GrantReservationRoleCapabilities {
  [pscustomobject][ordered]@{ground=@('Bind','Held','TailPermit');vehicle=@('Prepare','Release','TailReady')}
}
function Get-R19GrantReservationCandidateContract {
  param([Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false,[bool]$CancellationEnabled=$false)
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
  param([object]$Value,[Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false,[bool]$CancellationEnabled=$false)
  $expected=Get-R19GrantReservationCandidateContract -RepoRoot $RepoRoot -Enabled $Enabled -CancellationEnabled $CancellationEnabled
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
  param([Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false)
  if(-not$Enabled){return $null}
  $decoder='tools/read_r19_grant_reservation_stop_record.ps1'
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-grant-reservation-stop-candidate-v1';enabled=$true
    macro='VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS'
    record_schema=1;size_bytes=128;symbol='vc_lora_r19_grant_reservation_stop_record'
    decoder_path=$decoder
    decoder_sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $decoder) -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    runtime_reader_schema='vc-lora-r19-runtime-stage-jtag-read-v11'
    usb_control_schema='vc-lora-r19-grant-reservation-usb-v2'
    cancellation=Get-R19GrantReservationCancellationCapability
  }
}
function Assert-R19GrantReservationStopCandidateContract {
  param([object]$Value,[Parameter(Mandatory)][string]$RepoRoot,[bool]$Enabled=$false)
  $expected=Get-R19GrantReservationStopCandidateContract -RepoRoot $RepoRoot -Enabled $Enabled
  Assert-R19GrantReservationShape $Value $expected 'grant_reservation_stop_diagnostics'
  return $expected
}
