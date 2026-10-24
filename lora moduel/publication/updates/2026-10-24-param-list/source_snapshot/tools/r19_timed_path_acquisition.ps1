[CmdletBinding()]
param([switch]$ImportOnly)
# Pure definitions only. No port, clock sample, JTAG, process, file read/write or
# nonce generation is performed by importing this module.
# A nested definitions import must not grant ImportOnly to this module's caller.
$r19AcquisitionRequestedImportOnly=$ImportOnly
try{
  . (Join-Path $PSScriptRoot 'r19_host_readiness_wire.ps1')
  . (Join-Path $PSScriptRoot 'r19_usb_clock_correlation.ps1')
  . (Join-Path $PSScriptRoot 'r19_host_readiness_workflow.ps1')
  . (Join-Path $PSScriptRoot 'r19_timed_path_trace.ps1') -ImportOnly
  . (Join-Path $PSScriptRoot 'r19_usb_role_contract.ps1')
}finally{
  $ImportOnly=$r19AcquisitionRequestedImportOnly
}

function Assert-R19Acquisition([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Get-R19AcquisitionSha256([byte[]]$Bytes){
  $sha=[Security.Cryptography.SHA256]::Create()
  try{([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')}finally{$sha.Dispose()}
}
function Test-R19AcquisitionSha([string]$Value){$Value-cmatch'^[A-Fa-f0-9]{64}$'}
function Test-R19TimedPathExecutionPermit {
  param([Parameter(Mandatory)][object]$Permit,[Parameter(Mandatory)][ValidateSet('SyncOnly','ExplicitHostArm')][string]$Mode,
    [Parameter(Mandatory)][string]$CandidateId,[Parameter(Mandatory)][string]$HandoffSha256,
    [Parameter(Mandatory)][string]$FlashEvidenceSha256,[Parameter(Mandatory)][DateTime]$NowUtc,
    [ValidateSet('None','GroundPauseResume')][string]$ReadComparisonMode='None',
    [bool]$ParamListDiagnostics=$false)
  Set-StrictMode -Version Latest
  Assert-R19Acquisition ($Permit.schema-ceq'vc-lora-r19-timed-path-execution-permit-v1'-and$Permit.status-ceq'AUTHORIZED_SINGLE_CAPTURE') 'Unknown execution permit'
  Assert-R19Acquisition ($Permit.candidate_id-ceq$CandidateId-and$Permit.mode-ceq$Mode) 'Permit candidate/mode mismatch'
  $permitComparison='None'
  if($null-ne$Permit.PSObject.Properties['read_comparison_mode']){
    Assert-R19Acquisition ($Permit.read_comparison_mode-is[string]-and$Permit.read_comparison_mode-cin@('None','GroundPauseResume')) 'Permit comparison mode is invalid'
    $permitComparison=$Permit.read_comparison_mode
  }
  Assert-R19Acquisition ($permitComparison-ceq$ReadComparisonMode) 'Permit read comparison mode mismatch'
  Assert-R19Acquisition ($ReadComparisonMode-ceq'None'-or$Mode-ceq'ExplicitHostArm') 'Read comparison requires ExplicitHostArm'
  $permitParamList=$false
  if($null-ne$Permit.PSObject.Properties['param_list_diagnostics']){
    Assert-R19Acquisition ($Permit.param_list_diagnostics-is[bool]) 'Permit parameter-list option must be boolean'
    $permitParamList=$Permit.param_list_diagnostics
  }
  Assert-R19Acquisition ($permitParamList-eq$ParamListDiagnostics) 'Permit parameter-list option mismatch'
  Assert-R19Acquisition (-not$ParamListDiagnostics-or($Mode-ceq'ExplicitHostArm'-and$ReadComparisonMode-ceq'None')) 'Parameter-list permit requires ExplicitHostArm without read comparison'
  foreach($field in @('safety_confirmed','one_time','restore_required')){Assert-R19Acquisition ($Permit.$field-is[bool]-and$Permit.$field) "Permit $field is not explicit true"}
  Assert-R19Acquisition ((Test-R19AcquisitionSha $HandoffSha256)-and(Test-R19AcquisitionSha $FlashEvidenceSha256)-and$Permit.handoff_sha256-ceq$HandoffSha256-and$Permit.flash_evidence_sha256-ceq$FlashEvidenceSha256) 'Permit provenance mismatch'
  $issued=[DateTime]::Parse($Permit.issued_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
  $expires=[DateTime]::Parse($Permit.expires_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
  Assert-R19Acquisition ($issued.Kind-eq[DateTimeKind]::Utc-and$expires.Kind-eq[DateTimeKind]::Utc-and$issued-le$NowUtc-and$NowUtc-lt$expires-and($expires-$issued).TotalSeconds-le120) 'Permit is expired, future-dated or not bounded UTC'
  Assert-R19Acquisition ($Permit.capture_seconds-is[int]-or$Permit.capture_seconds-is[long]) 'Capture seconds must be exact integer'
  Assert-R19Acquisition ($Permit.capture_seconds-eq40) 'Only one fixed 40 second diagnostic capture is permitted'
  $ports=@($Permit.ports);Assert-R19Acquisition ($ports.Count-eq2) 'Exactly two role-bound ports are required'
  foreach($spec in @(@('vehicle','COM3',115200),@('ground','COM6',57600))){
    $rows=@($ports|Where-Object{$_.role-ceq$spec[0]})
    Assert-R19Acquisition ($rows.Count-eq1) 'Role port mapping is not unique'
    $p=$rows[0];Assert-R19Acquisition ($p.port-ceq$spec[1]-and$p.baud-eq$spec[2]-and-not[string]::IsNullOrWhiteSpace([string]$p.pnp_instance_id)-and-not[string]::IsNullOrWhiteSpace([string]$p.usb_parent_instance_id)) 'Port/baud/USB identity mismatch'
  }
  Assert-R19Acquisition ($ports[0].pnp_instance_id-cne$ports[1].pnp_instance_id-and$ports[0].usb_parent_instance_id-cne$ports[1].usb_parent_instance_id) 'Two roles cannot name the same USB device'
  [pscustomobject]@{valid=$true;hardware_interaction=$false;capture_seconds=40;mode=$Mode;candidate_id=$CandidateId}
}
function Get-R19TimedPathCapturePlan {
  param([Parameter(Mandatory)][object]$Handoff,[Parameter(Mandatory)][object]$FlashEvidence,[Parameter(Mandatory)][object]$Permit,
    [Parameter(Mandatory)][ValidateSet('SyncOnly','ExplicitHostArm')][string]$Mode,[Parameter(Mandatory)][string]$HandoffSha256,
    [Parameter(Mandatory)][string]$FlashEvidenceSha256,[Parameter(Mandatory)][DateTime]$NowUtc,
    [bool]$DiagnosticUsbFailureDiagnostics=$false,[string]$RepoRoot='',
    [ValidateSet('None','GroundPauseResume')][string]$ReadComparisonMode='None',
    [bool]$ParamListDiagnostics=$false,[bool]$AuxReadinessDiagnostics=$false)
  Set-StrictMode -Version Latest
  Assert-R19Acquisition ($ReadComparisonMode-ceq'None'-or($Mode-ceq'ExplicitHostArm'-and$DiagnosticUsbFailureDiagnostics)) 'Read comparison requires explicit diagnostic role capabilities'
  Assert-R19Acquisition (-not$ParamListDiagnostics-or($Mode-ceq'ExplicitHostArm'-and$AuxReadinessDiagnostics-and$DiagnosticUsbFailureDiagnostics-and$ReadComparisonMode-ceq'None')) 'Parameter-list capture requires ExplicitHostArm AUX/diagnostic mode without read comparison'
  Assert-R19Acquisition ($Handoff.schema-ceq'vc-lora-r19-candidate-artifact-handoff-v1'-and$Handoff.result-ceq'PASS') 'Candidate handoff is not accepted diagnostic artifact evidence'
  Assert-R19Acquisition ($Handoff.runtime_fail_diagnostics_enabled-is[bool]-and$Handoff.runtime_fail_diagnostics_enabled) 'Candidate diagnostics are disabled'
  $d=$Handoff.timed_path_diagnostics
  Assert-R19Acquisition ($d.schema-ceq'vc-lora-r19-timed-path-candidate-v1'-and$d.enabled-is[bool]-and$d.enabled-and$d.mode-ceq$Mode-and$d.mode_value-eq$(if($Mode-ceq'SyncOnly'){1}else{2})-and$d.record.symbol-ceq'vc_lora_r19_timed_path_record'-and$d.record.size_bytes-eq512-and$d.record.schema_version-eq1) 'Candidate does not bind the selected timed-path mode/record'
  Assert-R19Acquisition ($FlashEvidence.schema-ceq'vc-lora-r19-candidate-flash-evidence-v1'-and$FlashEvidence.result-ceq'PASS'-and$FlashEvidence.status-ceq'PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY'-and$FlashEvidence.candidate.handoff_sha256-ceq$HandoffSha256) 'Fresh flash evidence does not bind handoff'
  Assert-R19Acquisition ($FlashEvidence.timed_path_diagnostics.mode-ceq$Mode-and$FlashEvidence.timed_path_diagnostics.enabled-is[bool]-and$FlashEvidence.timed_path_diagnostics.enabled) 'Fresh flash mode mismatch'
  if($DiagnosticUsbFailureDiagnostics){
    Assert-R19Acquisition ($Mode-ceq'ExplicitHostArm') 'Diagnostic USB failure capture requires ExplicitHostArm'
    Assert-R19Acquisition (-not[string]::IsNullOrWhiteSpace($RepoRoot)) 'New diagnostic role capabilities require an explicit canonical repository source binding'
    foreach($value in @($Handoff,$FlashEvidence)){
      Assert-R19Acquisition ($null-ne$value.PSObject.Properties['diagnostic_usb_failure_diagnostics']-and$null-ne$value.PSObject.Properties['usb_role_capabilities']) 'Missing new diagnostic USB failure/role capability declaration'
      Assert-R19Acquisition ($value.runtime_fail_diagnostics_enabled-is[bool]-and$value.runtime_fail_diagnostics_enabled-and$value.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v8'-and$value.aux_readiness_diagnostics.enabled-is[bool]-and$value.aux_readiness_diagnostics.enabled-and$value.aux_readiness_diagnostics.schema-ceq'vc-lora-r19-aux-readiness-candidate-v1'-and$value.aux_readiness_diagnostics.record.size_bytes-eq6144) 'New capture requires runtime/AUX diagnostics and reader v8'
      $failureAbi=$value.diagnostic_usb_failure_diagnostics
      Assert-R19Acquisition ($failureAbi.schema-ceq'vc-lora-r19-diagnostic-usb-failure-candidate-v1'-and$failureAbi.enabled-is[bool]-and$failureAbi.enabled-and$failureAbi.macro-ceq'VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD'-and$failureAbi.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v8'-and$failureAbi.record.symbol-ceq'vc_lora_r19_diagnostic_usb_failure_record'-and$failureAbi.record.schema_version-eq1-and$failureAbi.record.size_bytes-eq256) 'New diagnostic USB failure ABI mismatch'
      Assert-R19Acquisition ($failureAbi.decoder.path-ceq'tools/read_r19_diagnostic_usb_failure_record.ps1'-and$failureAbi.decoder.sha256-ceq(Get-FileHash -LiteralPath (Join-Path $RepoRoot $failureAbi.decoder.path) -Algorithm SHA256 -ErrorAction Stop).Hash) 'Diagnostic USB failure decoder is not canonical-source bound'
      Assert-R19UsbRoleCapabilityShape $value.usb_role_capabilities
      if($RepoRoot){Assert-R19UsbRoleCapabilities -Contract $value.usb_role_capabilities -RepoRoot $RepoRoot -Mode $Mode}
      foreach($role in @('vehicle','ground')){[void](Get-R19UsbRoleEffectiveMode -Contract $value.usb_role_capabilities -Role $role -RequestedMode $Mode)}
    }
    Assert-R19Acquisition (($Handoff.diagnostic_usb_failure_diagnostics|ConvertTo-Json -Depth 15 -Compress)-ceq($FlashEvidence.diagnostic_usb_failure_diagnostics|ConvertTo-Json -Depth 15 -Compress)-and($Handoff.usb_role_capabilities|ConvertTo-Json -Depth 15 -Compress)-ceq($FlashEvidence.usb_role_capabilities|ConvertTo-Json -Depth 15 -Compress)) 'Fresh flash and handoff disagree on diagnostic USB failure/capability bindings'
  }else{
    Assert-R19Acquisition ($null-eq$Handoff.PSObject.Properties['diagnostic_usb_failure_diagnostics']) 'New diagnostic candidate requires its explicit capture flag'
  }
  Assert-R19Acquisition ($FlashEvidence.one_run_hil_authorized-is[bool]-and$FlashEvidence.one_run_hil_authorized) 'Flash is not authorized for one diagnostic capture'
  Assert-R19Acquisition (@($FlashEvidence.roles).Count-eq2) 'Flash evidence must have exactly two roles'
  foreach($r in @('vehicle','ground')){
    $rows=@($FlashEvidence.roles|Where-Object{$_.role-ceq$r});Assert-R19Acquisition ($rows.Count-eq1-and$rows[0].write_pass-is[bool]-and$rows[0].write_pass-and$rows[0].verify_pass-is[bool]-and$rows[0].verify_pass-and$rows[0].reenumeration_pass-is[bool]-and$rows[0].reenumeration_pass) 'Both roles require flash/readback/reenumeration PASS'
    $portRows=@($Permit.ports|Where-Object{$_.role-ceq$r});Assert-R19Acquisition ($portRows.Count-eq1) 'Permit role is not unique'
    Assert-R19Acquisition ($rows[0].port-ceq$portRows[0].port-and$rows[0].pnp_device_id-ceq$portRows[0].pnp_instance_id-and$rows[0].parent_device_id-ceq$portRows[0].usb_parent_instance_id) 'Permit must bind the exact freshly flashed USB devices'
  }
  Test-R19TimedPathExecutionPermit -Permit $Permit -Mode $Mode -CandidateId $Handoff.artifact_id -HandoffSha256 $HandoffSha256 -FlashEvidenceSha256 $FlashEvidenceSha256 -NowUtc $NowUtc -ReadComparisonMode $ReadComparisonMode -ParamListDiagnostics $ParamListDiagnostics
}

function New-R19TimedPathPrivateParser {
  param([Parameter(Mandatory)][object]$Nonce)
  Assert-R19Acquisition (Test-R19TimesyncNonce $Nonce) 'Parser nonce outside private domain'
  [pscustomobject]@{nonce=[string]$Nonce;buffer=[Collections.Generic.List[byte]]::new();input_bytes=0;accepted_frames=0}
}
function Invoke-R19TimedPathPrivateWrite {
  param([Parameter(Mandatory)][ValidateSet('ClockRequest','Arm')][string]$Kind,[Parameter(Mandatory)][byte[]]$Bytes,
    [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Ledger,[Parameter(Mandatory)][string]$ClockDomainId,
    [Parameter(Mandatory)][string]$Frequency,[Parameter(Mandatory)][scriptblock]$NowTicks,[Parameter(Mandatory)][scriptblock]$Writer)
  # The external writer and clock are injected explicitly. Only a canonical
  # USB-local frame may reach it; partial/throwing writes never invent acceptance.
  if($Kind-ceq'ClockRequest'){
    Assert-R19Acquisition ($Bytes.Length-eq28) 'Only private clock request bytes permitted'
    [byte[]]$expected=New-R19TimesyncRequest -Nonce ([BitConverter]::ToInt64($Bytes,18)) -Sequence $Bytes[4]
    Assert-R19Acquisition ((Get-R19AcquisitionSha256 $expected)-ceq(Get-R19AcquisitionSha256 $Bytes)) 'Noncanonical private clock request'
  }else{
    $decoded=ConvertFrom-R19HostReadinessFrame $Bytes
    Assert-R19Acquisition ($decoded.valid-and$decoded.opcode-ceq'Arm'-and$decoded.role-ceq'Ground') 'Only canonical Ground host-readiness ARM is permitted'
  }
  $begin=[string](& $NowTicks);$null=Get-R19ClockInteger $begin 'private write begin'
  $entry=[pscustomobject][ordered]@{kind=$Kind;started_ticks=$begin;returned_ticks='';base64=[Convert]::ToBase64String($Bytes);sha256=(Get-R19AcquisitionSha256 $Bytes);accepted_bytes=$null;write_success=$false;error='';clock_domain_id=$ClockDomainId;frequency=$Frequency}
  $Ledger.Add($entry)
  try{[void](& $Writer $Bytes);$entry.accepted_bytes=$Bytes.Length;$entry.write_success=$true}
  catch{$entry.error=$_.Exception.Message;throw}
  finally{$entry.returned_ticks=[string](& $NowTicks)}
  return $entry
}
function Add-R19TimedPathPrivateBytes {
  param([Parameter(Mandatory)][object]$Parser,[Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,[Parameter(Mandatory)][string]$ReadCompletedTicks)
  $null=Get-R19ClockInteger $ReadCompletedTicks 'read completed ticks' '9223372036854775807'
  Assert-R19Acquisition ($Bytes.Length-le8192-and$Parser.buffer.Count+$Bytes.Length-le16384) 'Private parser bounded byte limit'
  foreach($b in $Bytes){$Parser.buffer.Add($b)};$Parser.input_bytes+=$Bytes.Length
  $found=[Collections.Generic.List[object]]::new()
  while($Parser.buffer.Count-ge10){
    $b=$Parser.buffer
    $reply=$b[0]-eq253-and$b[1]-eq16-and$b[2]-eq0-and$b[3]-eq0-and$b[5]-eq249-and$b[6]-eq194-and$b[7]-eq111-and$b[8]-eq0-and$b[9]-eq0
    $ready=$b[0]-eq253-and$b[1]-eq54-and$b[2]-eq0-and$b[3]-eq0-and$b[5]-eq249-and$b[6]-eq196-and$b[7]-eq253-and$b[8]-eq0-and$b[9]-eq0
    if(-not$reply-and-not$ready){$b.RemoveAt(0);continue}
    $length=if($reply){28}else{66};if($b.Count-lt$length){break}
    [byte[]]$frame=$b.GetRange(0,$length).ToArray()
    $decoded=if($reply){ConvertFrom-R19TimesyncResponse -Bytes $frame -ExpectedNonce ([long]$Parser.nonce)}else{ConvertFrom-R19HostReadinessFrame -Bytes $frame}
    if(-not$decoded.valid-or($ready-and$decoded.nonce-cne$Parser.nonce)){$b.RemoveAt(0);continue}
    $b.RemoveRange(0,$length);$Parser.accepted_frames++
    $found.Add([pscustomobject]@{kind=$(if($reply){'ClockReply'}else{'Ready'});read_completed_ticks=$ReadCompletedTicks;bytes=$frame;decoded=$decoded;sha256=Get-R19AcquisitionSha256 $frame})
  }
  return ,$found.ToArray()
}

function Test-R19TimedPathHeartbeat {
  param([Parameter(Mandatory)][byte[]]$Frame,[switch]$AllowSignedCrcOnly)
  if($Frame.Length-lt21-or$Frame[0]-ne253-or$Frame[1]-ne9-or$Frame[3]-ne0-or$Frame[7]-ne0-or$Frame[8]-ne0-or$Frame[9]-ne0){return $false}
  if($AllowSignedCrcOnly){if($Frame[2]-ne1-or$Frame.Length-ne34){return $false}}elseif($Frame[2]-ne0-or$Frame.Length-ne21){return $false}
  [uint16]$crc=65535
  foreach($value in @($Frame[1..18])+@(50)){[uint16]$tmp=([uint16]$value-bxor($crc-band255));$tmp=($tmp-bxor(($tmp-shl4)-band255))-band255;$crc=(($crc-shr8)-bxor($tmp-shl8)-bxor($tmp-shl3)-bxor($tmp-shr4))-band65535}
  return $crc-eq([uint16]$Frame[19]-bor([uint16]$Frame[20]-shl8))
}
function New-R19TimedPathHeartbeatParser {
  [pscustomobject]@{buffer=[Collections.Generic.List[byte]]::new();next_raw_offset=0;buffer_raw_offset=0}
}
function Add-R19TimedPathHeartbeatBytes {
  param([Parameter(Mandatory)][object]$Parser,[Parameter(Mandatory)][byte[]]$Bytes,[Parameter(Mandatory)][int]$RawOffset,
    [Parameter(Mandatory)][string]$ReadCompletedTicks,[Parameter(Mandatory)][string]$ClockDomainId,[Parameter(Mandatory)][string]$Frequency,
    [Parameter(Mandatory)][scriptblock]$SampleValidationTicks)
  Assert-R19Acquisition ($Bytes.Length-le8192-and$RawOffset-eq$Parser.next_raw_offset-and$Parser.buffer.Count+$Bytes.Length-le16384) 'Product CRC parser raw prefix or bounded capacity mismatch'
  foreach($b in $Bytes){$Parser.buffer.Add($b)};$Parser.next_raw_offset+=$Bytes.Length
  $found=[Collections.Generic.List[object]]::new()
  while($Parser.buffer.Count-ge10){
    $b=$Parser.buffer
    $header=$b[0]-eq253-and$b[1]-eq9-and$b[2]-eq0-and$b[3]-eq0-and$b[7]-eq0-and$b[8]-eq0-and$b[9]-eq0
    if(-not$header){$b.RemoveAt(0);$Parser.buffer_raw_offset++;continue}
    if($b.Count-lt21){break}
    [byte[]]$frame=$b.GetRange(0,21).ToArray()
    if(-not(Test-R19TimedPathHeartbeat $frame)){$b.RemoveAt(0);$Parser.buffer_raw_offset++;continue}
    # This sample is taken only after the actual runtime CRC computation above.
    $validated=[string](& $SampleValidationTicks)
    Assert-R19Acquisition ((Get-R19ClockInteger $validated 'CRC validation QPC')-ge(Get-R19ClockInteger $ReadCompletedTicks 'native read return')) 'Runtime validation clock precedes native read return'
    $found.Add([pscustomobject]@{raw_offset=$Parser.buffer_raw_offset;frame_bytes=21;frame_sha256=(Get-R19AcquisitionSha256 $frame);read_completed_ticks=$ReadCompletedTicks;validation_ticks=$validated;clock_domain_id=$ClockDomainId;frequency=$Frequency})
    $b.RemoveRange(0,21);$Parser.buffer_raw_offset+=21
  }
  return ,$found.ToArray()
}

function Get-R19TimedPathRawHandshake {
  param([Parameter(Mandatory)][object]$RoleCapture,[Parameter(Mandatory)][byte[]]$Raw,[Parameter(Mandatory)][ValidateSet('SyncOnly','ExplicitHostArm')][string]$Mode)
  Set-StrictMode -Version Latest
  $p=New-R19TimedPathPrivateParser -Nonce $RoleCapture.nonce
  $observations=[Collections.Generic.List[object]]::new()
  foreach($block in @($RoleCapture.blocks)){
    [byte[]]$part=[byte[]]::new($block.count);[Array]::Copy($Raw,$block.offset,$part,0,$part.Length)
    foreach($o in (Add-R19TimedPathPrivateBytes $p $part $block.end_ticks)){$observations.Add($o)}
  }
  $reply=@($observations|Where-Object{$_.kind-ceq'ClockReply'});Assert-R19Acquisition ($reply.Count-eq1) 'Saved native raw must contain one exact matching CRC-valid clock reply'
  $writes=@($RoleCapture.writes);$clockWrites=@($writes|Where-Object{$_.kind-ceq'ClockRequest'});$armWrites=@($writes|Where-Object{$_.kind-ceq'Arm'})
  Assert-R19Acquisition ($clockWrites.Count-eq1-and$writes.Count-eq$(if($Mode-ceq'ExplicitHostArm'){2}else{1})-and$armWrites.Count-eq$(if($Mode-ceq'ExplicitHostArm'){1}else{0})) 'Private OUT write ledger must exactly match control mode'
  foreach($w in $writes){
    [byte[]]$b=[Convert]::FromBase64String($w.base64)
    Assert-R19Acquisition ($w.clock_domain_id-ceq$RoleCapture.clock_domain_id-and$w.frequency-ceq$RoleCapture.frequency-and(Get-R19AcquisitionSha256 $b)-ceq$w.sha256-and$w.accepted_bytes-eq$b.Length) 'Raw private OUT hash/count/clock mismatch'
    $start=Get-R19ClockInteger $w.started_ticks 'write start';$end=Get-R19ClockInteger $w.returned_ticks 'write return'
    Assert-R19Acquisition ($start-ge(Get-R19ClockInteger $RoleCapture.read_started_ticks 'reader start')-and$end-ge$start) 'Private OUT time interval is invalid'
  }
  [byte[]]$request=[Convert]::FromBase64String($clockWrites[0].base64)
  Assert-R19Acquisition ($request.Length-eq28) 'Clock OUT size mismatch'
  [byte[]]$expected=New-R19TimesyncRequest -Nonce ([long]$RoleCapture.nonce) -Sequence $request[4]
  Assert-R19Acquisition ((Get-R19AcquisitionSha256 $request)-ceq(Get-R19AcquisitionSha256 $expected)-and(Get-R19ClockInteger $reply[0].read_completed_ticks 'reply read')-ge(Get-R19ClockInteger $clockWrites[0].started_ticks 'request started')) 'Clock reply/OUT nonce or read ordering mismatch'
  $ready=$null
  if($Mode-ceq'ExplicitHostArm'){
    $readyRows=@($observations|Where-Object{$_.kind-ceq'Ready'});Assert-R19Acquisition ($readyRows.Count-eq1) 'Saved native raw must contain one exact matching READY'
    $ready=$readyRows[0]
    Assert-R19Acquisition ($ready.decoded.role-ceq'Ground'-and$ready.decoded.reply_device_us-ceq$reply[0].decoded.device_microseconds-and(Get-R19ClockInteger $ready.read_completed_ticks 'READY read')-ge(Get-R19ClockInteger $reply[0].read_completed_ticks 'reply read')) 'READY does not bind the same response and reader sequence'
    [byte[]]$arm=[Convert]::FromBase64String($armWrites[0].base64)
    $decodedArm=ConvertFrom-R19HostReadinessFrame $arm
    Assert-R19Acquisition ((Test-R19HostReadinessBinding $ready.decoded $decodedArm)-and(Get-R19ClockInteger $armWrites[0].started_ticks 'ARM start')-ge(Get-R19ClockInteger $ready.read_completed_ticks 'READY read')) 'ARM OUT must follow the matching canonical READY read'
  }
  [pscustomobject]@{reply=$reply[0];ready=$ready;clock_write=$clockWrites[0];arm_write=$(if($armWrites.Count-eq1){$armWrites[0]}else{$null})}
}

function ConvertTo-R19TimedPathEvidence {
  [CmdletBinding()]
  param([Parameter(Mandatory)][object]$Capture,[Parameter(Mandatory)][object]$DeviceRecord,[Parameter(Mandatory)][string]$CandidateId,
    [Parameter(Mandatory)][string]$DeviceRecordSha256)
  Set-StrictMode -Version Latest
  Assert-R19Acquisition ($Capture.schema-ceq'vc-lora-r19-timed-path-capture-v1'-and$Capture.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY'-and$Capture.cleanup_proven-is[bool]-and$Capture.cleanup_proven-and$Capture.candidate_id-ceq$CandidateId-and$Capture.capture_seconds-eq40) 'Capture is not complete, cleaned up or candidate-bound'
  Assert-R19Acquisition (Test-R19AcquisitionSha $DeviceRecordSha256) 'Device raw record SHA256 required'
  Assert-R19Acquisition ($DeviceRecord.schema-ceq'vc-lora-r19-timed-path-record-v1'-and$DeviceRecord.role-ceq'ground'-and$DeviceRecord.mode-ceq$Capture.mode-and$DeviceRecord.size_bytes-eq512) 'MCU record mode/role/schema mismatch'
  $g=@($Capture.roles|Where-Object{$_.role-ceq'ground'});Assert-R19Acquisition ($g.Count-eq1) 'Ground capture not unique';$g=$g[0]
  Assert-R19Acquisition ($g.reader_continuous-is[bool]-and$g.reader_continuous-and-not$g.overflow-and$g.clock_domain_id-ceq$Capture.clock_domain_id-and$g.frequency-ceq$Capture.frequency) 'Reader clock/owner continuity unavailable'
  [byte[]]$raw=[Convert]::FromBase64String($g.raw_base64);Assert-R19Acquisition ($raw.Length-le1048576-and$raw.Length-eq$g.raw_bytes-and(Get-R19AcquisitionSha256 $raw)-ceq$g.raw_sha256) 'Raw capture SHA/size mismatch'
  $offset=0;$last='0';$readStarted=Get-R19ClockInteger $g.read_started_ticks 'native read started ticks'
  foreach($block in @($g.blocks)){
    $begin=Get-R19ClockInteger $block.begin_ticks 'block begin';$end=Get-R19ClockInteger $block.end_ticks 'block end'
    Assert-R19Acquisition ($block.clock_domain_id-ceq$g.clock_domain_id-and$block.frequency-ceq$g.frequency) 'Native read block clock identity/frequency mismatch'
    Assert-R19Acquisition ($block.offset-eq$offset-and$block.count-gt0-and$block.count-le8192-and$begin-ge$readStarted-and$begin-ge(Get-R19ClockInteger $last 'last block end')-and$end-ge$begin) 'Raw read blocks are not exact continuous prefix metadata'
    $offset+=$block.count;$last=$block.end_ticks
  }
  Assert-R19Acquisition ($offset-eq$raw.Length) 'Raw read blocks do not cover saved bytes'
  $empty=[pscustomobject][ordered]@{schema='vc-lora-r19-timed-path-evidence-v1';identity=$null;clock_correlation=$null;trace_complete=$false;trace_overflow=[bool]$g.overflow;events=@()}
  Assert-R19Acquisition ($DeviceRecord.schema_version-eq1) 'Unknown MCU timestamp contract version'
  $flags=Get-R19ClockInteger $DeviceRecord.flags 'record flags' '1023'
  if(($flags-band768)-ne0){return [pscustomobject]@{schema='vc-lora-r19-timed-path-normalization-v1';evidence=$empty;evaluation=(Get-R19TimedPathTraceEvaluation $empty);binding_status='TAINTED_MCU_CLOCK_OR_IDENTITY';hardware_interaction=$false}}
  if(-not$DeviceRecord.frame_enqueued-or-not$DeviceRecord.session_observed){return [pscustomobject]@{schema='vc-lora-r19-timed-path-normalization-v1';evidence=$empty;evaluation=(Get-R19TimedPathTraceEvaluation $empty);binding_status='MISSING_BOUND_FRAME_OR_SESSION';hardware_interaction=$false}}
  Assert-R19Acquisition ($DeviceRecord.nonce-ceq$g.nonce-and$DeviceRecord.usb_epoch-eq$DeviceRecord.observed_epoch) 'MCU nonce/USB epoch continuity mismatch'
  $handshake=Get-R19TimedPathRawHandshake -RoleCapture $g -Raw $raw -Mode $Capture.mode
  Assert-R19Acquisition ($g.workflow.reply_read_validated-is[bool]-and$g.workflow.reply_read_validated-and$g.workflow.reply.nonce-ceq$g.nonce-and$g.workflow.reply.device_microseconds-ceq$DeviceRecord.timestamps.clock_request_us-and$handshake.reply.decoded.device_microseconds-ceq$DeviceRecord.timestamps.clock_request_us) 'Clock reply does not bind MCU session timestamp'
  if($Capture.mode-ceq'ExplicitHostArm'){
    Assert-R19Acquisition ($g.workflow.ready_binding_validated-and$g.workflow.arm_write_accepted-and$g.workflow.ready.reader_session-ceq$DeviceRecord.reader_session-and$g.workflow.ready.usb_epoch-eq$DeviceRecord.usb_epoch) 'READY/ARM tuple mismatch'
    $wireBoot=(Get-R19ClockInteger $DeviceRecord.boot_id[0] 'boot low word' '4294967295')+(Get-R19ClockInteger $DeviceRecord.boot_id[1] 'boot high word' '4294967295')*[Numerics.BigInteger]4294967296
    if($wireBoot-eq0){$wireBoot=[Numerics.BigInteger]::One}
    Assert-R19Acquisition ([string]$wireBoot-ceq$g.workflow.ready.boot_id-and[string]$wireBoot-ceq$handshake.ready.decoded.boot_id-and$handshake.ready.decoded.reader_session-ceq$DeviceRecord.reader_session-and$handshake.ready.decoded.usb_epoch-eq$DeviceRecord.usb_epoch) 'READY boot/session identity does not bind full MCU record'
  }
  [byte[]]$frame=[Convert]::FromBase64String($DeviceRecord.raw_frame_base64)
  Assert-R19Acquisition ($frame.Length-eq$DeviceRecord.frame_bytes-and(Get-R19AcquisitionSha256 $frame)-ceq$DeviceRecord.frame_sha256) 'MCU first frame byte/SHA binding is invalid'
  if(Test-R19TimedPathHeartbeat $frame -AllowSignedCrcOnly){return [pscustomobject]@{schema='vc-lora-r19-timed-path-normalization-v1';evidence=$empty;evaluation=(Get-R19TimedPathTraceEvaluation $empty);binding_status='UNSUPPORTED_SIGNED_HEARTBEAT_PARTIAL';hardware_interaction=$false;limitations=@('Signed Heartbeat CRC was checked but signature authentication and signed transaction normalization are outside this acquisition version.')}}
  Assert-R19Acquisition (Test-R19TimedPathHeartbeat $frame) 'MCU first frame is not exact CRC-valid unsigned MAVLink2 Heartbeat'
  $identity=[pscustomobject][ordered]@{role='ground';candidate_id=$CandidateId;build_fingerprint=@($DeviceRecord.build_id);boot_instance=@($DeviceRecord.boot_id);usb_epoch=$DeviceRecord.usb_epoch;reader_session=[string]$DeviceRecord.reader_session;nonce=[string]$DeviceRecord.nonce;frame_id=('first-product-heartbeat-token-'+[string]$DeviceRecord.token);frame_sha256=$DeviceRecord.frame_sha256;frame_kind='PRODUCT_HEARTBEAT';expected_frame_bytes=$DeviceRecord.frame_bytes}
  $events=[Collections.Generic.List[object]]::new()
  function Add([string]$Kind,[string]$Time,[object]$Details,[string]$Sha){$events.Add([pscustomobject][ordered]@{kind=$Kind;ordinal=$events.Count;domain=$(if($Kind.StartsWith('PC_')){'PC_TICKS'}else{'MCU_US'});timestamp=$Time;identity=$identity;evidence_sha256=$Sha;details=$Details})}
  Add 'PC_READ_STARTED' $g.read_started_ticks ([pscustomobject]@{clock_domain_id=$g.clock_domain_id;reader_owner_verified=$true;frequency=$g.frequency}) $g.raw_sha256
  # v1 producer contract: all stage times use the same esp_timer_get_time clock;
  # sticky regression/identity flags cover calls after a detected discontinuity.
  # This establishes the recorded MCU-relative domain only, never a PC rate bound.
  if($DeviceRecord.arm_accepted){
    Assert-R19Acquisition ((Get-R19ClockInteger $DeviceRecord.timestamps.clock_request_us 'request time')-le(Get-R19ClockInteger $DeviceRecord.timestamps.arm_us 'ARM time')-and(Get-R19ClockInteger $DeviceRecord.timestamps.arm_us 'ARM time')-le(Get-R19ClockInteger $DeviceRecord.timestamps.enqueue_us 'enqueue time')) 'MCU readiness timestamps violate the shared clock contract'
    Add 'MCU_ARM_ACCEPTED' $DeviceRecord.timestamps.arm_us ([pscustomobject]@{accepted=$true;device_clock_continuity_verified=$true}) $DeviceRecordSha256
  }
  Add 'MCU_FRAME_ENQUEUED' $DeviceRecord.timestamps.enqueue_us ([pscustomobject]@{frame_bytes=$frame.Length}) $DeviceRecordSha256
  if($DeviceRecord.hwcdc_accepted_observed){Add 'MCU_HWCDC_ACCEPTED' $DeviceRecord.timestamps.accepted_us ([pscustomobject]@{accepted_bytes=$DeviceRecord.accepted_bytes}) $DeviceRecordSha256}
  if($DeviceRecord.sdk_snapshot_observed){
    Add 'MCU_USB_PUBLISHED' $DeviceRecord.timestamps.sdk_snapshot_us ([pscustomobject]@{publish_generation=$DeviceRecord.sdk.publish_generation;ring_pending_bytes=$DeviceRecord.sdk.ring_bytes;stash_pending_bytes=$DeviceRecord.sdk.stash_bytes}) $DeviceRecordSha256
    Add 'MCU_USB_PICKUP_OBSERVED' $DeviceRecord.timestamps.sdk_snapshot_us ([pscustomobject]@{pickup_generation=$DeviceRecord.sdk.pickup_generation}) $DeviceRecordSha256
  }
  if($DeviceRecord.usb_completed){Add 'MCU_USB_COMPLETED' $DeviceRecord.timestamps.terminal_us ([pscustomobject]@{completed_bytes=$DeviceRecord.accepted_bytes}) $DeviceRecordSha256}
  if($DeviceRecord.usb_failed){Add 'MCU_USB_FAILED' $DeviceRecord.timestamps.failure_returned_us ([pscustomobject]@{budget_ms=$DeviceRecord.product_budget_ms;started_us=$DeviceRecord.timestamps.failure_started_us;finished_us=$DeviceRecord.timestamps.failure_returned_us;accepted_bytes=$DeviceRecord.accepted_bytes;reason=('MCU_REASON_'+$DeviceRecord.failure_reason)}) $DeviceRecordSha256}
  # The immutable failure-return sample can precede the later SDK/record snapshot.
  # Sort only the common MCU_US domain; mixed PC/MCU ordinal order proves nothing.
  $pcStart=$events[0];$sorted=@($events.ToArray()|Where-Object{$_.domain-ceq'MCU_US'}|Sort-Object -Property @{Expression={Get-R19ClockInteger $_.timestamp 'MCU event timestamp'}})
  $events.Clear();$events.Add($pcStart);foreach($e in $sorted){$e.ordinal=$events.Count;$events.Add($e)}
  $matches=[Collections.Generic.List[int]]::new()
  for($i=0;$i-le$raw.Length-$frame.Length;$i++){if($raw[$i]-ne$frame[0]){continue};$same=$true;for($j=1;$j-lt$frame.Length;$j++){if($raw[$i+$j]-ne$frame[$j]){$same=$false;break}};if($same){$matches.Add($i)}}
  if($matches.Count-eq1){
    $endOffset=$matches[0]+$frame.Length;$block=@($g.blocks|Where-Object{$_.offset+$_.count-ge$endOffset})[0]
    if($Capture.mode-ceq'ExplicitHostArm'-and$DeviceRecord.arm_accepted){Assert-R19Acquisition ((Get-R19ClockInteger $block.end_ticks 'product read return')-ge(Get-R19ClockInteger $handshake.arm_write.started_ticks 'ARM write start')) 'A gated product frame cannot be read before its matching ARM OUT begins'}
    $validations=@($g.product_observations|Where-Object{$_.raw_offset-eq$matches[0]-and$_.frame_sha256-ceq$DeviceRecord.frame_sha256})
    if($validations.Count-eq1){
      $v=$validations[0]
      Assert-R19Acquisition ($v.clock_domain_id-ceq$g.clock_domain_id-and$v.frequency-ceq$g.frequency-and$v.frame_bytes-eq$frame.Length-and$v.read_completed_ticks-ceq$block.end_ticks-and(Get-R19ClockInteger $v.validation_ticks 'runtime validation QPC')-ge(Get-R19ClockInteger $block.end_ticks 'native read return')) 'Runtime CRC ledger clock, byte offset or validation boundary is inconsistent'
      Add 'PC_FRAME_VALIDATED' $v.validation_ticks ([pscustomobject]@{received_bytes=$frame.Length;crc_valid=$true;complete_frame=$true;frame_sha256=$DeviceRecord.frame_sha256}) $g.raw_sha256
    }
  }
  $evidence=[pscustomobject][ordered]@{schema='vc-lora-r19-timed-path-evidence-v1';identity=$identity;clock_correlation=$null;trace_complete=$true;trace_overflow=$false;events=$events.ToArray()}
  [pscustomobject][ordered]@{schema='vc-lora-r19-timed-path-normalization-v1';evidence=$evidence;evaluation=(Get-R19TimedPathTraceEvaluation $evidence);binding_status='RAW_BYTES_AND_MCU_RECORD_BOUND';matched_pc_frame_occurrences=$matches.Count;record_observation_us=$DeviceRecord.timestamps.terminal_us;clock_mapping='UNKNOWN_NO_GUARANTEED_RATE_BOUND_OR_CONTINUITY_PROOF';hardware_interaction=$false;limitations=@('Event MCU_USB_PUBLISHED is the recorded SDK counter observation timestamp, not physical FIFO publication time.','Private ARM is host-readiness admission, never flight arming.','Same boot tuple and nominal clocks alone do not establish guaranteed PC/MCU time bounds.','API accepted bytes zero is not proof that no physical byte was emitted.')}
}

if(-not$ImportOnly){throw 'This is an ImportOnly support module. Use the separately authorized capture runner.'}
