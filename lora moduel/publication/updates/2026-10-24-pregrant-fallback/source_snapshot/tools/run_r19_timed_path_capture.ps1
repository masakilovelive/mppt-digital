[CmdletBinding()]
param([switch]$ImportOnly,[switch]$Execute,[string]$RepoRoot='', [string]$OutputDirectory='',
  [string]$CandidateHandoffPath='', [string]$CandidateFlashEvidencePath='', [string]$ExecutionPermitPath='',
  [switch]$AuxReadinessDiagnostics,
  [switch]$DiagnosticUsbFailureDiagnostics,
  [switch]$ParamListDiagnostics,
  [switch]$GrantDiagnostics,
  [ValidateSet('None','GroundPauseResume')][string]$ReadComparisonMode='None',
  [ValidateSet('SyncOnly','ExplicitHostArm')][string]$Mode='SyncOnly',[ValidateRange(40,40)][int]$CaptureSeconds=40)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# Dot-sourced script parameters share this scope. Keep the caller's execution
# switches intact even when a definitions-only dependency binds ImportOnly.
$r19CaptureRequestedImportOnly=$ImportOnly
$r19CaptureRequestedExecute=$Execute
try{
  . (Join-Path $PSScriptRoot 'r19_timed_path_acquisition.ps1') -ImportOnly
}finally{
  $ImportOnly=$r19CaptureRequestedImportOnly
  $Execute=$r19CaptureRequestedExecute
}
if($ParamListDiagnostics){. (Join-Path $PSScriptRoot 'r19_param_list_diagnostics.ps1')}

function Invoke-R19ParamListRequest {
  param([object]$State,[string]$Role,[object]$Workflow,[int]$HeartbeatCount,
    [string]$CaptureDeadlineTicks,[long]$RawOffset,[int]$ReaderPendingBytes,
    [scriptblock]$NowTicks,[scriptblock]$Writer)
  if($null-eq$State-or$Role-cne'ground'-or$State.write_attempts-ne0-or
      $null-eq$Workflow-or$Workflow.arm_write_accepted-isnot[bool]-or-not$Workflow.arm_write_accepted-or
      $HeartbeatCount-lt1-or$ReaderPendingBytes-ne0){return $false}
  $now=[string](& $NowTicks)
  # A bounded 40-second capture must still contain the entire 30-second
  # request-origin window plus a second of observation, not a truncated SLA.
  if([Numerics.BigInteger]$CaptureDeadlineTicks-[Numerics.BigInteger]$now-lt31*[Numerics.BigInteger]$State.frequency){return $false}
  [byte[]]$requestBytes=Begin-R19ParamListWrite -State $State -WriteStartedTicks $now -RawOffsetAtWriteStart $RawOffset
  try{
    $accepted=& $Writer $requestBytes
    if($accepted-isnot[int]-and$accepted-isnot[long]){throw 'Request writer did not report an exact accepted-byte count'}
    $null=Commit-R19ParamListWrite -State $State -AcceptedBytes $accepted -WriteReturnedTicks ([string](& $NowTicks))
  }catch{$null=Commit-R19ParamListWrite -State $State -AcceptedBytes $null -ExceptionType $_.Exception.GetType().FullName -WriteReturnedTicks ([string](& $NowTicks))}
  return $true
}
function Update-R19ParamListCheckpoint {
  param([object]$State,[object]$ReaderStatus,[string]$OutputDirectory)
  if($null-eq$State-or$State.write_attempts-ne1-or$State.frozen-or$null-eq$State.deadline_ticks){return $false}
  # This atomic native-reader status is the watermark. Wall-clock time alone
  # cannot prove that all predeadline bytes have reached the parser.
  if([Numerics.BigInteger]$ReaderStatus.LastReadEndTicks-le[Numerics.BigInteger]$State.deadline_ticks-or$ReaderStatus.PendingByteCount-ne0){return $false}
  $null=Freeze-R19ParamList30 -State $State -ObservationComplete $true
  Write-R19TimedPathJson -Path (Join-Path $OutputDirectory 'param_list_30s.json') -Value (Get-R19ParamListSnapshot -State $State)
  return $true
}

function Assert-R19TimedPathLiveIdentity([object]$Spec,[string]$Checkpoint){
  $rows=@(Get-CimInstance Win32_SerialPort -ErrorAction Stop|Where-Object{[string]$_.DeviceID-ceq$Spec.port})
  Assert-R19Acquisition ($rows.Count-eq1-and[string]::Equals([string]$rows[0].PNPDeviceID,[string]$Spec.pnp_instance_id,[StringComparison]::OrdinalIgnoreCase)) ('USB role identity mismatch at '+$Checkpoint)
  $parent=Get-PnpDeviceProperty -InstanceId ([string]$rows[0].PNPDeviceID) -KeyName DEVPKEY_Device_Parent -ErrorAction Stop
  Assert-R19Acquisition ([string]::Equals([string]$parent.Data,[string]$Spec.usb_parent_instance_id,[StringComparison]::OrdinalIgnoreCase)) ('USB parent identity mismatch at '+$Checkpoint)
}
function Assert-R19DiagnosticUsbFailureCaptureSelection([bool]$AuxEnabled,[string]$RequestedMode){
  if(-not$AuxEnabled-or$RequestedMode-cne'ExplicitHostArm'){throw 'Diagnostic USB failure diagnostics require AUX/readiness ExplicitHostArm mode'}
}
function Get-R19ReadComparisonPlan {
  param([ValidateSet('None','GroundPauseResume')][string]$ReadComparisonMode='None',
    [ValidateSet('SyncOnly','ExplicitHostArm')][string]$Mode='SyncOnly',
    [int]$CaptureSeconds=40,[bool]$AuxReadinessDiagnostics=$false,[bool]$DiagnosticUsbFailureDiagnostics=$false)
  if($CaptureSeconds-ne40){throw 'Read comparison requires one fixed 40-second capture'}
  $enabled=$ReadComparisonMode-ceq'GroundPauseResume'
  if($enabled-and($Mode-cne'ExplicitHostArm'-or-not$AuxReadinessDiagnostics-or-not$DiagnosticUsbFailureDiagnostics)){
    throw 'Ground read comparison requires ExplicitHostArm, AUX and diagnostic USB failure records'
  }
  [pscustomobject][ordered]@{schema='vc-lora-r19-read-comparison-plan-v1';mode=$ReadComparisonMode
    enabled=$enabled;role='ground';pause_after_seconds=20;pause_ms=2000;capture_seconds=40
    semantics='APPLICATION_READ_PAUSE_NOT_USB_IN_SUPPRESSION';acceptance_eligible=$false;deployment_authorized=$false;root_cause_proven=$false}
}
function Get-R19ReadComparisonEvaluation {
  param([object]$Plan,[object]$Evidence)
  $reasons=[Collections.Generic.List[string]]::new();$requested=$false;$observedMode=''
  try{
    if($null-ne$Plan-and$null-ne$Plan.PSObject.Properties['mode']-and$Plan.mode-is[string]){$observedMode=$Plan.mode}
    if($null-eq$Plan-or$Plan.schema-cne'vc-lora-r19-read-comparison-plan-v1'-or$Plan.enabled-isnot[bool]){throw 'Unknown comparison plan'}
    if($Plan.role-cne'ground'){throw 'Comparison role must be Ground'}
    foreach($flag in @('acceptance_eligible','deployment_authorized','root_cause_proven')){if($Plan.$flag-isnot[bool]-or$Plan.$flag){throw 'Comparison plan cannot claim authority or a proven cause'}}
    $requested=$Plan.enabled
    if($requested){
      if($Plan.mode-cne'GroundPauseResume'-or$Plan.semantics-cne'APPLICATION_READ_PAUSE_NOT_USB_IN_SUPPRESSION'-or$Plan.pause_after_seconds-ne20-or$Plan.pause_ms-ne2000-or$Plan.capture_seconds-ne40){throw 'Comparison policy changed'}
      if([string]::IsNullOrWhiteSpace($Evidence.clock_domain_id)){throw 'Comparison clock identity missing'}
      $frequency=Get-R19ClockInteger $Evidence.frequency 'comparison frequency'
      $start=Get-R19ClockInteger $Evidence.measurement_start_ticks 'measurement start'
      $end=Get-R19ClockInteger $Evidence.measurement_end_ticks 'measurement end'
      if($frequency-le0-or$end-lt$start+40*$frequency){throw 'Comparison duration or frequency invalid'}
      if(@($Evidence.roles).Count-ne2){throw 'Comparison must contain both role owners'}
      foreach($role in @('vehicle','ground')){
        $rows=@($Evidence.roles|Where-Object{$_.role-ceq$role})
        if($rows.Count-ne1){throw 'Comparison role missing or duplicated'}
        $r=$rows[0];$l=$r.lifecycle;$p=$r.pause
        if([string]::IsNullOrWhiteSpace($r.reader_id)){throw 'Comparison reader identity missing'}
        foreach($flag in @('close_attempted','close_completed')){if($l.$flag-isnot[bool]-or-not$l.$flag){throw 'Port close not proven'}}
        if($l.close_failure-isnot[string]-or$l.close_failure.Length-ne0){throw 'Port close failed'}
        $stop=Get-R19ClockInteger $l.stop_requested_ticks 'stop requested'
        $stopped=Get-R19ClockInteger $l.worker_stopped_ticks 'worker stopped'
        $closeStart=Get-R19ClockInteger $l.close_start_ticks 'close start'
        $closeEnd=Get-R19ClockInteger $l.close_end_ticks 'close end'
        if($stop-lt$end-or$stopped-lt$stop-or$closeStart-lt$stopped-or$closeEnd-lt$closeStart){throw 'Stop and port close boundaries out of order'}
        if($p.requested-isnot[bool]){throw 'Pause request observation missing'}
        if($role-ceq'vehicle'){
          if($p.requested-or$r.reader_continuous-isnot[bool]-or-not$r.reader_continuous){throw 'Vehicle reader must remain continuous'}
        }else{
          if(-not$p.requested-or$r.reader_continuous-isnot[bool]-or$r.reader_continuous){throw 'Ground pause must not be labelled continuous'}
          $request=Get-R19ClockInteger $p.requested_ticks 'pause request'
          $begin=Get-R19ClockInteger $p.begin_ticks 'pause acknowledged'
          $finish=Get-R19ClockInteger $p.end_ticks 'pause ended'
          $resumed=Get-R19ClockInteger $p.resumed_read_ticks 'first resumed Read'
          $beginCalls=Get-R19ClockInteger ([string]$p.begin_calls) 'pause begin calls'
          $endCalls=Get-R19ClockInteger ([string]$p.end_calls) 'pause end calls'
          if($p.duration_ms-ne2000-or$p.end_reason-cne'Deadline'-or$beginCalls-ne$endCalls){throw 'Pause duration, termination or no-Read witness invalid'}
          if($request-lt$start+20*$frequency-or$begin-lt$request-or$finish-lt$begin+2*$frequency-or
              ($finish-$begin)*2-gt5*$frequency-or$resumed-lt$finish-or$resumed-ge$end){throw 'Pause and resume time boundaries invalid'}
        }
      }
      if($Evidence.roles[0].reader_id-ceq$Evidence.roles[1].reader_id){throw 'Roles cannot share a reader owner'}
    }elseif($Plan.mode-cne'None'){throw 'Inactive comparison plan has unexpected mode'}
  }catch{$reasons.Add($_.Exception.Message)}
  $valid=$requested-and$reasons.Count-eq0
  [pscustomobject][ordered]@{schema='vc-lora-r19-read-comparison-evaluation-v1';mode=$observedMode
    result=$(if($valid){'VALID_COMPARISON'}elseif($requested-or$reasons.Count){'INVALID_COMPARISON'}else{'NOT_REQUESTED'})
    valid=$valid;reasons=$reasons.ToArray();causal_disposition='INDETERMINATE'
    physical_host_in_suppression_proven=$false;root_cause_proven=$false;acceptance_eligible=$false;deployment_authorized=$false
    limitations=@('Application Read pause does not prove physical USB IN suppression; Windows may prefetch.',
      'No comparison-period MCU snapshot is acquired. A first failure latched before intervention is not an intervention outcome.',
      'Read, USB pickup, RF delivery and product acceptance remain distinct. PC/MCU physical cause requires bounded event/USB-transfer evidence.')}
}
function Get-R19ReadComparisonSnapshotValue([object]$Snapshot,[string]$Name){
  if($null-eq$Snapshot-or$null-eq$Snapshot.PSObject.Properties[$Name]){return $null}
  $value=$Snapshot.$Name
  if($Name.EndsWith('Ticks')){if($null-eq$value-or[long]$value-lt0){return $null};return [string]$value}
  return $value
}
function Get-R19ReadComparisonEvidence([object[]]$States,[object]$Context){
  $roles=@(foreach($s in $States){
    $n=$s.snapshot;$requested=Get-R19ReadComparisonSnapshotValue $n 'DiagnosticPauseRequestedTicks'
    [pscustomobject]@{role=$s.spec.role;reader_id=$s.reader_id
      reader_continuous=($s.opened-and$s.joined-and-not$s.cleanup_close_fallback-and$null-eq$requested-and$null-ne$n-and-not$n.Overflow-and[string]::IsNullOrEmpty($n.Failure))
      lifecycle=[pscustomobject]@{stop_requested_ticks=(Get-R19ReadComparisonSnapshotValue $n 'StopRequestedTicks');worker_stopped_ticks=(Get-R19ReadComparisonSnapshotValue $n 'WorkerStoppedTicks')
        close_start_ticks=(Get-R19ReadComparisonSnapshotValue $n 'CloseStartTicks');close_end_ticks=(Get-R19ReadComparisonSnapshotValue $n 'CloseEndTicks')
        close_attempted=(Get-R19ReadComparisonSnapshotValue $n 'CloseAttempted');close_completed=(Get-R19ReadComparisonSnapshotValue $n 'CloseCompleted');close_failure=(Get-R19ReadComparisonSnapshotValue $n 'CloseFailure')}
      pause=[pscustomobject]@{requested=($null-ne$requested);requested_ticks=$requested
        begin_ticks=(Get-R19ReadComparisonSnapshotValue $n 'DiagnosticPauseBeginTicks');end_ticks=(Get-R19ReadComparisonSnapshotValue $n 'DiagnosticPauseEndTicks')
        resumed_read_ticks=(Get-R19ReadComparisonSnapshotValue $n 'DiagnosticPauseResumedReadTicks')
        begin_calls=(Get-R19ReadComparisonSnapshotValue $n 'DiagnosticPauseBeginCalls');end_calls=(Get-R19ReadComparisonSnapshotValue $n 'DiagnosticPauseEndCalls')
        duration_ms=(Get-R19ReadComparisonSnapshotValue $n 'DiagnosticPauseMilliseconds');end_reason=(Get-R19ReadComparisonSnapshotValue $n 'DiagnosticPauseEndReason')}}
  })
  [pscustomobject]@{clock_domain_id=$Context.clock_domain_id;frequency=$Context.frequency;measurement_start_ticks=$Context.measurement_start_ticks;measurement_end_ticks=$Context.measurement_end_ticks;roles=$roles}
}
function Write-R19TimedPathJson([string]$Path,[object]$Value){
  $json=$Value|ConvertTo-Json -Depth 70 -WarningAction Stop -ErrorAction Stop
  [byte[]]$jsonBytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
  $jsonStream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$jsonStream.Write($jsonBytes,0,$jsonBytes.Length);$jsonStream.Flush($true)}finally{$jsonStream.Dispose()}
}
function Write-R19TimedPathRaw([string]$Path,[AllowEmptyCollection()][byte[]]$Bytes){
  $rawStream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$rawStream.Write($Bytes,0,$Bytes.Length);$rawStream.Flush($true)}finally{$rawStream.Dispose()}
  [byte[]]$savedBytes=[IO.File]::ReadAllBytes($Path)
  if($savedBytes.Length-ne$Bytes.Length-or(Get-R19AcquisitionSha256 $savedBytes)-cne(Get-R19AcquisitionSha256 $Bytes)){throw 'Saved raw bytes differ from the reader snapshot'}
}
function Get-R19TimedPathRawRole([object]$RawEvidence){
  [pscustomobject][ordered]@{role=$RawEvidence.role;raw_available=$RawEvidence.raw_available;raw_saved=$RawEvidence.raw_saved
    raw_bytes=$RawEvidence.raw_bytes;raw_sha256=$RawEvidence.raw_sha256;raw_base64=$RawEvidence.raw_base64
    reader_continuous=$false;overflow=$null;blocks=@();reader_snapshot=$null;export_error=$RawEvidence.export_error}
}
function Get-R19TimedPathRoleMetadata([object]$State,[object]$RawEvidence,[object]$Context){
  if(-not$RawEvidence.raw_available-or$null-eq$State.snapshot){throw 'Raw data or reader snapshot is unavailable'}
  if($State.snapshot.ByteCount-ne$RawEvidence.raw_bytes){throw 'Snapshot byte count differs from captured raw data'}
  $blockResults=[Collections.Generic.List[object]]::new();[long]$expectedOffset=0
  foreach($readBlock in $State.snapshot.Blocks){
    [long]$blockOffset=$readBlock.Offset;[long]$blockCount=$readBlock.Count
    [long]$beginTicks=$readBlock.BeginTicks;[long]$endTicks=$readBlock.EndTicks
    if($blockOffset-ne$expectedOffset-or$blockCount-le0-or$blockCount-gt($RawEvidence.raw_bytes-$expectedOffset)-or$beginTicks-lt0-or$endTicks-lt$beginTicks){throw 'Reader block coverage or timing is inconsistent'}
    $blockResults.Add([pscustomobject]@{offset=$blockOffset;count=$blockCount;begin_ticks=[string]$beginTicks;end_ticks=[string]$endTicks;clock_domain_id=$Context.clock_domain_id;frequency=$Context.frequency})
    $expectedOffset+=$blockCount
  }
  if($expectedOffset-ne$RawEvidence.raw_bytes){throw 'Reader block metadata does not cover all captured bytes'}
  $plannedPause=$null-ne$Context.PSObject.Properties['read_comparison']-and$null-ne$Context.read_comparison-and$Context.read_comparison.plan.enabled-and$RawEvidence.role-ceq'ground'
  [pscustomobject][ordered]@{role=$RawEvidence.role;port=$State.spec.port;baud=$State.spec.baud;reader_id=$State.reader_id
    clock_domain_id=$Context.clock_domain_id;frequency=$Context.frequency;nonce=$State.nonce
    open_before_ticks=$State.open_before_ticks;open_after_ticks=$State.open_after_ticks;read_started_ticks=$State.read_started_ticks
    reader_continuous=($State.opened-and$State.joined-and-not$State.cleanup_close_fallback-and-not$plannedPause-and-not$State.snapshot.Overflow-and[string]::IsNullOrEmpty($State.snapshot.Failure))
    overflow=[bool]$State.snapshot.Overflow;raw_available=$true;raw_saved=$RawEvidence.raw_saved
    raw_bytes=$RawEvidence.raw_bytes;raw_sha256=$RawEvidence.raw_sha256;raw_base64=$RawEvidence.raw_base64
    blocks=$blockResults.ToArray();workflow=$State.workflow;workflow_failure=$State.workflow_failure
    writes=$State.writes.ToArray();private_observations=$State.observations.ToArray();product_observations=$State.product_observations.ToArray()
    reader_snapshot=$State.snapshot;export_error=''}
}
function Save-R19TimedPathCaptureEvidence([object[]]$States,[string]$OutputDirectory,[object]$Context){
  # No port/reader/device operations belong here. Preserve every raw stream before
  # touching optional block/workflow metadata, so one bad role cannot hide another.
  if(-not[IO.Directory]::Exists($OutputDirectory)){throw 'Capture evidence directory must already exist'}
  $persistenceErrors=[Collections.Generic.List[string]]::new()
  $rawEvidence=[Collections.Generic.List[object]]::new();$seenRoles=[Collections.Generic.HashSet[string]]::new()
  foreach($captureState in $States){
    $role=[string]$captureState.spec.role
    if($role-cnotin@('vehicle','ground')-or-not$seenRoles.Add($role)){$persistenceErrors.Add('Invalid or duplicate capture role');continue}
    $savedRole=[pscustomobject]@{role=$role;state=$captureState;raw_available=$false;raw_saved=$false;raw_bytes=$null;raw_sha256=$null;raw_base64=$null;export_error=''}
    $rawEvidence.Add($savedRole)
    try{
      if($null-eq$captureState.raw){throw 'Raw data was not obtained; it is not a measured empty stream'}
      if($captureState.raw-isnot[byte[]]){throw 'Reader raw data is not a byte array'}
      [byte[]]$roleBytes=$captureState.raw
      $savedRole.raw_available=$true;$savedRole.raw_bytes=$roleBytes.Length
      $savedRole.raw_sha256=Get-R19AcquisitionSha256 $roleBytes;$savedRole.raw_base64=[Convert]::ToBase64String($roleBytes)
      Write-R19TimedPathRaw -Path (Join-Path $OutputDirectory ($role+'.raw.bin')) -Bytes $roleBytes
      $savedRole.raw_saved=$true
    }catch{$savedRole.export_error=$_.Exception.Message;$persistenceErrors.Add($role+': raw preservation: '+$_.Exception.Message)}
  }
  if($seenRoles.Count-ne2){$persistenceErrors.Add('Both role states were not available')}
  $roleResults=[Collections.Generic.List[object]]::new()
  foreach($savedRole in $rawEvidence){
    try{$roleResults.Add((Get-R19TimedPathRoleMetadata -State $savedRole.state -RawEvidence $savedRole -Context $Context))
    }catch{$savedRole.export_error=$_.Exception.Message;$persistenceErrors.Add($savedRole.role+': metadata: '+$_.Exception.Message);$roleResults.Add((Get-R19TimedPathRawRole $savedRole))}
  }
  $sourceIntegrityProven=$true
  foreach($sourcePin in $Context.pinned_inputs){
    try{if((Get-FileHash -LiteralPath (Join-Path $Context.repo_root $sourcePin.path) -Algorithm SHA256 -ErrorAction Stop).Hash-cne$sourcePin.sha256){throw 'Source changed during capture'}
    }catch{$sourceIntegrityProven=$false;$persistenceErrors.Add('Source integrity: '+$_.Exception.Message)}
  }
  # Validate optional mode evidence only after preserving both raw streams.
  # Contexts predating Grant diagnostics omit it; explicit false is not absence.
  $grantFlag=$Context.PSObject.Properties['grant_diagnostics_enabled']
  $grantSelection=$Context.PSObject.Properties['grant_diagnostics_selection_present']
  $grantMetadataValid=($null-eq$grantFlag-or($grantFlag.Name-ceq'grant_diagnostics_enabled'-and$grantFlag.Value-is[bool]))-and
    ($null-eq$grantSelection-or($grantSelection.Name-ceq'grant_diagnostics_selection_present'-and$grantSelection.Value-is[bool]))
  if($grantMetadataValid-and$null-ne$grantSelection){
    $grantMetadataValid=($grantSelection.Value-and$null-ne$grantFlag)-or
      (-not$grantSelection.Value-and($null-eq$grantFlag-or-not$grantFlag.Value))
  }
  if(-not$grantMetadataValid){$persistenceErrors.Add('Grant diagnostic selection requires exact Boolean metadata with consistent bound presence')}
  $publishGrantFlag=$grantMetadataValid-and$null-ne$grantFlag-and($null-eq$grantSelection-or$grantSelection.Value)
  $failure=[string]$Context.failure
  if(-not$failure-and$persistenceErrors.Count-gt0){$failure='Capture persistence: '+$persistenceErrors[0]}
  $summary=[pscustomobject][ordered]@{schema='vc-lora-r19-timed-path-capture-v1'
    result=$(if(-not$failure-and$Context.cleanup_proven-and$persistenceErrors.Count-eq0-and$States.Count-eq2){'CAPTURE_COMPLETE_OBSERVATIONS_ONLY'}else{'INVALID_CAPTURE'})
    candidate_id=$Context.candidate_id;mode=$Context.mode;capture_seconds=$Context.capture_seconds
    started_utc=$Context.started_utc;completed_utc=[DateTime]::UtcNow.ToString('o')
    clock_domain_id=$Context.clock_domain_id;frequency=$Context.frequency
    measurement_start_ticks=$Context.measurement_start_ticks;measurement_end_ticks=$Context.measurement_end_ticks
    cleanup_proven=$Context.cleanup_proven;hardware_interaction=$Context.hardware_interaction;serial_write_calls=$Context.serial_write_calls
    failure=$failure;original_failure=[string]$Context.failure;preservation_errors=$persistenceErrors.ToArray();source_integrity_proven=$sourceIntegrityProven
    roles=$roleResults.ToArray();identity_evidence=$Context.identity_evidence;pinned_inputs=$Context.pinned_inputs
    handoff_sha256=$Context.handoff_sha256;flash_evidence_sha256=$Context.flash_evidence_sha256
    acceptance_eligible=$false;deployment_authorized=$false;root_cause_proven=$false
    limitations=@('Missing reply, READY or ARM is a diagnostic observation failure, not automatic invalidation of raw capture.','A successful private ARM write proves PC-local acceptance only; MCU ARM acceptance comes from JTAG.','No parameter, flight-command, RF-rate or product timeout changes are performed.','The safe outer must perform JTAG acquisition and mandatory accepted R18 restoration.')}
  if($null-ne$Context.PSObject.Properties['read_comparison']){Add-Member -InputObject $summary -NotePropertyName read_comparison -NotePropertyValue $Context.read_comparison}
  if($publishGrantFlag){Add-Member -InputObject $summary -NotePropertyName grant_diagnostics_enabled -NotePropertyValue $grantFlag.Value}
  if($null-ne$Context.PSObject.Properties['param_list_diagnostics_enabled']-and$Context.param_list_diagnostics_enabled){
    Add-Member -InputObject $summary -NotePropertyName param_list_diagnostics_enabled -NotePropertyValue ([bool]$Context.param_list_diagnostics_enabled)
    Add-Member -InputObject $summary -NotePropertyName param_list_diagnostics -NotePropertyValue $Context.param_list_diagnostics
    Add-Member -InputObject $summary -NotePropertyName param_list_diagnostics_failure -NotePropertyValue ([string]$Context.param_list_diagnostics_failure)
  }
  if($States.Count-gt0-and$null-ne$States[0].PSObject.Properties['diagnostic_usb_failure_diagnostics']-and$null-ne$States[0].diagnostic_usb_failure_diagnostics){
    Add-Member -InputObject $summary -NotePropertyName diagnostic_usb_failure_diagnostics -NotePropertyValue $States[0].diagnostic_usb_failure_diagnostics
    Add-Member -InputObject $summary -NotePropertyName usb_role_capabilities -NotePropertyValue $States[0].usb_role_capabilities
    Add-Member -InputObject $summary -NotePropertyName usb_role_contract_version -NotePropertyValue 'v1-source-bound'
  }elseif($States.Count-gt0-and$null-ne$States[0].PSObject.Properties['usb_role_contract_version']){
    Add-Member -InputObject $summary -NotePropertyName usb_role_contract_version -NotePropertyValue 'legacy-v0-role-name-workflow-not-a-support-assertion'
  }
  $summaryPath=Join-Path $OutputDirectory 'summary.json'
  try{Write-R19TimedPathJson $summaryPath $summary}catch{
    $persistenceErrors.Add('Summary serialization/write: '+$_.Exception.Message)
    $summary.result='INVALID_CAPTURE';if(-not$summary.failure){$summary.failure='Capture persistence: '+$persistenceErrors[$persistenceErrors.Count-1]}
    # Keep a primitive-only failure report if optional workflow/snapshot objects
    # cannot serialize. Do not overwrite a partial or pre-existing summary file.
    $safeRoles=[Collections.Generic.List[object]]::new();foreach($savedRole in $rawEvidence){$safeRoles.Add((Get-R19TimedPathRawRole $savedRole))}
    $summary.roles=$safeRoles.ToArray();$summary.identity_evidence=@();$summary.pinned_inputs=@();$summary.preservation_errors=$persistenceErrors.ToArray()
    if([IO.File]::Exists($summaryPath)){$summaryPath=Join-Path $OutputDirectory 'capture.failure.json'}
    Write-R19TimedPathJson $summaryPath $summary
  }
  return $summary
}
if($AuxReadinessDiagnostics-and$Mode-cne'ExplicitHostArm'){
  throw 'AUX/readiness diagnostics require ExplicitHostArm timed-path mode'
}
if($DiagnosticUsbFailureDiagnostics){Assert-R19DiagnosticUsbFailureCaptureSelection -AuxEnabled $AuxReadinessDiagnostics.IsPresent -RequestedMode $Mode}
if($GrantDiagnostics){
  if($Mode-cne'ExplicitHostArm'-or-not$AuxReadinessDiagnostics-or-not$DiagnosticUsbFailureDiagnostics-or$ReadComparisonMode-cne'None'){
    throw 'Grant diagnostics require full ExplicitHostArm diagnostics without comparison'
  }
}
if($ParamListDiagnostics){
  if($Mode-cne'ExplicitHostArm'-or-not$AuxReadinessDiagnostics-or-not$DiagnosticUsbFailureDiagnostics-or$ReadComparisonMode-cne'None'){
    throw 'Parameter-list diagnostics require ExplicitHostArm, AUX and diagnostic USB records, without a read pause'
  }
}
$readComparisonPlan=Get-R19ReadComparisonPlan -ReadComparisonMode $ReadComparisonMode -Mode $Mode -CaptureSeconds $CaptureSeconds -AuxReadinessDiagnostics ([bool]$AuxReadinessDiagnostics) -DiagnosticUsbFailureDiagnostics ([bool]$DiagnosticUsbFailureDiagnostics)
if($ImportOnly){if($Execute){throw 'ImportOnly cannot execute'};return}
if(-not$Execute){throw 'This diagnostic runner requires Execute and a fresh one-time outer permit. No hardware was opened.'}
if($PSVersionTable.PSEdition-ceq'Core'-and-not$IsWindows){throw 'Windows diagnostic host required'}
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent $PSScriptRoot}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
foreach($value in @($OutputDirectory,$CandidateHandoffPath,$CandidateFlashEvidencePath,$ExecutionPermitPath)){Assert-R19Acquisition (-not[string]::IsNullOrWhiteSpace($value)) 'All explicit diagnostic paths are required'}
Assert-R19Acquisition (-not(Test-Path -LiteralPath $OutputDirectory)) 'Capture output must be a new directory'
$handoffPath=(Resolve-Path -LiteralPath $CandidateHandoffPath).Path
$flashPath=(Resolve-Path -LiteralPath $CandidateFlashEvidencePath).Path
$permitPath=(Resolve-Path -LiteralPath $ExecutionPermitPath).Path
$handoff=Get-Content -LiteralPath $handoffPath -Raw|ConvertFrom-Json
$flash=Get-Content -LiteralPath $flashPath -Raw|ConvertFrom-Json
$permit=Get-Content -LiteralPath $permitPath -Raw|ConvertFrom-Json
$handoffSha=(Get-FileHash -LiteralPath $handoffPath -Algorithm SHA256).Hash
$flashSha=(Get-FileHash -LiteralPath $flashPath -Algorithm SHA256).Hash
$plan=Get-R19TimedPathCapturePlan -Handoff $handoff -FlashEvidence $flash -Permit $permit -Mode $Mode -HandoffSha256 $handoffSha -FlashEvidenceSha256 $flashSha -NowUtc ([DateTime]::UtcNow) -DiagnosticUsbFailureDiagnostics $DiagnosticUsbFailureDiagnostics.IsPresent -RepoRoot $repo -ReadComparisonMode $ReadComparisonMode -ParamListDiagnostics ([bool]$ParamListDiagnostics) -AuxReadinessDiagnostics ([bool]$AuxReadinessDiagnostics) -GrantDiagnostics ([bool]$GrantDiagnostics)
if($DiagnosticUsbFailureDiagnostics){
  Assert-R19UsbRoleCapabilities -Contract $handoff.usb_role_capabilities -RepoRoot $repo -Mode $Mode
  foreach($role in @('vehicle','ground')){[void](Get-R19UsbRoleEffectiveMode -Contract $handoff.usb_role_capabilities -Role $role -RequestedMode $Mode)}
}
# The safe outer owns flashing, JTAG, rollback and the human safety grant. This
# runner consumes that one grant atomically. It never flashes or restores itself.
$claim=[IO.FileStream]::new(($permitPath+'.consumed'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{[byte[]]$permitClaimBytes=[Text.Encoding]::UTF8.GetBytes($plan.candidate_id+' '+$Mode);$claim.Write($permitClaimBytes,0,$permitClaimBytes.Length);$claim.Flush($true)}finally{$claim.Dispose()}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$started=[DateTime]::UtcNow.ToString('o');$failure='';$cleanupProven=$true;$hardware=$false;$serialWrites=0
$states=[Collections.Generic.List[object]]::new();$identityEvidence=[Collections.Generic.List[object]]::new()
$clock=[Diagnostics.Stopwatch]::StartNew();$domain=[Guid]::NewGuid().ToString('N');$frequency=[string][Diagnostics.Stopwatch]::Frequency
$measurementStart='';$measurementEnd='';$pinInputs=[Collections.Generic.List[object]]::new();$readComparisonRequested=$false
$paramState=$null;$paramDeliveredOffset=[long]0;$paramDiagnosticsFailure=''
if($ParamListDiagnostics){$paramState=New-R19ParamListDiagnosticsState -Frequency $frequency -ClockDomainId $domain}
try{
  # Independently verify the full sealed candidate before any port is opened.
  $verifier=Join-Path $repo 'tools/verify_r19_candidate_artifact.ps1'
  $engine=(Get-Process -Id $PID).Path
  $verifierArguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File',$verifier,'-RepoRoot',$repo,'-HandoffPath',$handoffPath,
    '-RuntimeFailDiagnostics','-TimedPathMode',$Mode)
  if($AuxReadinessDiagnostics){$verifierArguments+=,'-AuxReadinessDiagnostics'}
  if($DiagnosticUsbFailureDiagnostics){$verifierArguments+=,'-DiagnosticUsbFailureDiagnostics'}
  if($GrantDiagnostics){$verifierArguments+=,'-GrantDiagnostics'}
  $verifyOutput=& $engine @verifierArguments 2>&1
  [IO.File]::WriteAllLines((Join-Path $OutputDirectory 'candidate_verify.log'),[string[]]@($verifyOutput),[Text.UTF8Encoding]::new($false))
  Assert-R19Acquisition ($LASTEXITCODE-eq0) 'Mode-specific sealed candidate verification failed'
  foreach($relative in @('tools/r19_timed_path_acquisition.ps1','tools/r19_continuous_reader.cs','tools/r19_startup_reader.cs','tools/r19_host_readiness_workflow.ps1','tools/r19_host_readiness_wire.ps1','tools/r19_usb_clock_correlation.ps1','tools/r19_timed_path_trace.ps1')){
    $p=Join-Path $repo $relative;$pinInputs.Add([pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash})
  }
  if($DiagnosticUsbFailureDiagnostics){$relative='tools/r19_usb_role_contract.ps1';$pinInputs.Add([pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath (Join-Path $repo $relative) -Algorithm SHA256).Hash})}
  if($ParamListDiagnostics){$relative='tools/r19_param_list_diagnostics.ps1';$pinInputs.Add([pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath (Join-Path $repo $relative) -Algorithm SHA256).Hash})}
  if($GrantDiagnostics){$relative='tools/read_r19_grant_diagnostic_record.ps1';$pinInputs.Add([pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath (Join-Path $repo $relative) -Algorithm SHA256).Hash})}
  Assert-R19Acquisition ($null-eq('VcLora.R19.ContinuousReader'-as[type])) 'Fresh isolated capture process required'
  $startupSource=[IO.File]::ReadAllText((Join-Path $repo 'tools/r19_startup_reader.cs'))
  $continuousSource=[IO.File]::ReadAllText((Join-Path $repo 'tools/r19_continuous_reader.cs'))
  Add-Type -TypeDefinition ($startupSource+[Environment]::NewLine+$continuousSource)
  # Prepare both read owners, parsers and private nonces before opening either.
  foreach($spec in @($permit.ports)){
    Assert-R19TimedPathLiveIdentity $spec 'PRE_OPEN';$identityEvidence.Add([pscustomobject]@{role=$spec.role;checkpoint='PRE_OPEN';result='PASS'})
    $port=[IO.Ports.SerialPort]::new($spec.port,[int]$spec.baud,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
    $port.DtrEnable=$false;$port.RtsEnable=$false;$port.Handshake=[IO.Ports.Handshake]::None;$port.ReadTimeout=20;$port.WriteTimeout=20
    $reader=[VcLora.R19.ContinuousReader]::new([VcLora.R19.SerialStartupSource]::new($port),$clock,1048576,4096)
    $nonce=[string](New-R19TimesyncNonce)
    $states.Add([pscustomobject]@{spec=$spec;port=$port;reader=$reader;reader_id=[Guid]::NewGuid().ToString('N');nonce=$nonce;parser=(New-R19TimedPathPrivateParser $nonce);product_parser=(New-R19TimedPathHeartbeatParser);product_observations=[Collections.Generic.List[object]]::new();workflow=$null;workflow_failure='';observations=[Collections.Generic.List[object]]::new();writes=[Collections.Generic.List[object]]::new();opened=$false;open_before_ticks='';open_after_ticks='';read_started_ticks='';snapshot=$null;raw=$null;joined=$false;cleanup_close_fallback=$false;diagnostic_usb_failure_diagnostics=$(if($DiagnosticUsbFailureDiagnostics){$handoff.diagnostic_usb_failure_diagnostics}else{$null});usb_role_capabilities=$(if($DiagnosticUsbFailureDiagnostics){$handoff.usb_role_capabilities}else{$null});usb_role_contract_version=$(if($DiagnosticUsbFailureDiagnostics){'v1-source-bound'}else{'legacy-v0-role-name-workflow-not-a-support-assertion'})})
  }
  foreach($s in $states){Assert-R19Acquisition ($s.reader.WaitReady(1000)) 'Native read owner preparation timeout';[void]$s.reader.GetStatus();[void]$s.reader.PollBytes(1)}
  [void](Test-R19TimedPathExecutionPermit -Permit $permit -Mode $Mode -CandidateId $plan.candidate_id -HandoffSha256 $handoffSha -FlashEvidenceSha256 $flashSha -NowUtc ([DateTime]::UtcNow) -ReadComparisonMode $ReadComparisonMode -ParamListDiagnostics ([bool]$ParamListDiagnostics) -GrantDiagnostics ([bool]$GrantDiagnostics))
  Assert-R19Acquisition ((Get-FileHash -LiteralPath $handoffPath -Algorithm SHA256).Hash-ceq$handoffSha-and(Get-FileHash -LiteralPath $flashPath -Algorithm SHA256).Hash-ceq$flashSha) 'Provenance changed before Open'
  foreach($s in $states){
    $s.open_before_ticks=[string]$clock.ElapsedTicks;$hardware=$true
    $s.port.Open();$s.opened=$true;$s.open_after_ticks=[string]$clock.ElapsedTicks
    # Arm first: no identity query, decoding, logging or second Open can displace Read.
    $s.reader.Arm([long]$s.open_after_ticks)
    Assert-R19TimedPathLiveIdentity $s.spec 'POST_OPEN';$identityEvidence.Add([pscustomobject]@{role=$s.spec.role;checkpoint='POST_OPEN';result='PASS'})
  }
  $measurementStart=[string]$clock.ElapsedTicks
  $deadline=[Numerics.BigInteger]::Parse($measurementStart)+[Numerics.BigInteger]::Parse($frequency)*40
  while([Numerics.BigInteger]$clock.ElapsedTicks-lt$deadline){
    if($readComparisonPlan.enabled-and-not$readComparisonRequested-and[long]$clock.ElapsedTicks-ge([long]$measurementStart+20*[long]$frequency)){
      $groundOwner=@($states|Where-Object{$_.spec.role-ceq'ground'})
      Assert-R19Acquisition ($groundOwner.Count-eq1) 'Comparison Ground owner missing'
      $readComparisonRequested=$true
      Assert-R19Acquisition ($groundOwner[0].reader.RequestDiagnosticReadPause(2000)) 'Comparison pause request rejected'
    }
    foreach($s in $states){
      $status=$s.reader.GetStatus()
      Assert-R19Acquisition (-not$status.Stopped-and-not$status.Overflow-and[string]::IsNullOrEmpty($status.Failure)) ('Read owner failed: '+$s.spec.role+' '+$status.Failure)
      if($null-eq$s.workflow-and$status.FirstReadBeginTicks-ge0){
        $s.read_started_ticks=[string]$status.FirstReadBeginTicks
        $roleMode=if($DiagnosticUsbFailureDiagnostics){Get-R19UsbRoleEffectiveMode -Contract $handoff.usb_role_capabilities -Role $s.spec.role -RequestedMode $Mode}else{Get-R19UsbRoleEffectiveMode -Contract $null -Role $s.spec.role -RequestedMode $Mode -AllowLegacyV0}
        $s.workflow=New-R19HostReadinessWorkflow -Mode $roleMode -Role $s.spec.role -Nonce $s.nonce -ReaderIdentity $s.reader_id -ClockDomainId $domain -TickFrequency $frequency -StartTicks ([string]$clock.ElapsedTicks) -ReadStartedTicks $s.read_started_ticks -TimeoutTicks ([string]([Numerics.BigInteger]::Parse($frequency)*5))
        try{
          [byte[]]$bytes=New-R19HostReadinessClockRequest -State $s.workflow -NowTicks ([string]$clock.ElapsedTicks) -ReaderIdentity $s.reader_id -ReaderAlive $true -ClockDomainId $domain
          if($DiagnosticUsbFailureDiagnostics){Assert-R19UsbRolePrivateWrite -Contract $handoff.usb_role_capabilities -Role $s.spec.role -Kind ClockRequest}
          $serialWrites++
          $write=Invoke-R19TimedPathPrivateWrite -Kind ClockRequest -Bytes $bytes -Ledger $s.writes -ClockDomainId $domain -Frequency $frequency -NowTicks {[string]$clock.ElapsedTicks} -Writer {param([byte[]]$payload)$s.port.Write($payload,0,$payload.Length)}
          Set-R19HostReadinessWriteCommit -State $s.workflow -Kind ClockRequest -AcceptedBytes $write.accepted_bytes -WriteStartedTicks $write.started_ticks -NowTicks $write.returned_ticks -ReaderIdentity $s.reader_id -ReaderAlive $true -ClockDomainId $domain
        }catch{$s.workflow_failure=$_.Exception.Message}
      }
      foreach($block in $s.reader.PollBytes(8192)){
        if($ParamListDiagnostics-and$s.spec.role-ceq'ground'-and-not$paramDiagnosticsFailure){
          try{
            $null=Add-R19ParamListBytes -State $paramState -Bytes $block.Data -RawOffset $block.Offset -ReadCompletedTicks ([string]$block.EndTicks)
            $paramDeliveredOffset=[long]$block.Offset+[long]$block.Data.Length
          }catch{$paramDiagnosticsFailure=$_.Exception.Message}
        }
        foreach($product in (Add-R19TimedPathHeartbeatBytes -Parser $s.product_parser -Bytes $block.Data -RawOffset $block.Offset -ReadCompletedTicks ([string]$block.EndTicks) -ClockDomainId $domain -Frequency $frequency -SampleValidationTicks {[string]$clock.ElapsedTicks})){
          Assert-R19Acquisition ($s.product_observations.Count-lt512) 'Runtime product validation ledger capacity exceeded';$s.product_observations.Add($product)
        }
        foreach($o in (Add-R19TimedPathPrivateBytes -Parser $s.parser -Bytes $block.Data -ReadCompletedTicks ([string]$block.EndTicks))){
          Assert-R19Acquisition ($s.observations.Count-lt128) 'Private observation limit exceeded';$s.observations.Add($o)
          if($null-ne$s.workflow-and[string]::IsNullOrEmpty($s.workflow_failure)){
            try{
              Add-R19HostReadinessObservation -State $s.workflow -Kind $o.kind -Bytes $o.bytes -ReadCompletedTicks $o.read_completed_ticks -NowTicks ([string]$clock.ElapsedTicks) -ReaderIdentity $s.reader_id -ReaderAlive $true -ClockDomainId $domain
              if($s.workflow.status-ceq'ReadyValidated'){
                [byte[]]$bytes=New-R19HostReadinessWorkflowArm -State $s.workflow -NowTicks ([string]$clock.ElapsedTicks) -ReaderIdentity $s.reader_id -ReaderAlive $true -ClockDomainId $domain
                if($DiagnosticUsbFailureDiagnostics){Assert-R19UsbRolePrivateWrite -Contract $handoff.usb_role_capabilities -Role $s.spec.role -Kind Arm}
                $serialWrites++
                $write=Invoke-R19TimedPathPrivateWrite -Kind Arm -Bytes $bytes -Ledger $s.writes -ClockDomainId $domain -Frequency $frequency -NowTicks {[string]$clock.ElapsedTicks} -Writer {param([byte[]]$payload)$s.port.Write($payload,0,$payload.Length)}
                Set-R19HostReadinessWriteCommit -State $s.workflow -Kind Arm -AcceptedBytes $write.accepted_bytes -WriteStartedTicks $write.started_ticks -NowTicks $write.returned_ticks -ReaderIdentity $s.reader_id -ReaderAlive $true -ClockDomainId $domain
              }
            }catch{$s.workflow_failure=$_.Exception.Message}
          }
        }
      }
      if($null-ne$s.workflow-and[string]::IsNullOrEmpty($s.workflow_failure)){
        try{Update-R19HostReadinessWorkflow -State $s.workflow -NowTicks ([string]$clock.ElapsedTicks) -ReaderIdentity $s.reader_id -ReaderAlive $true -ClockDomainId $domain}catch{$s.workflow_failure=$_.Exception.Message}
      }
      if($ParamListDiagnostics-and$s.spec.role-ceq'ground'-and-not$paramDiagnosticsFailure){
        try{
          $paramReaderStatus=$s.reader.GetStatus()
          if([string]::IsNullOrEmpty($s.workflow_failure)){
            $attempted=Invoke-R19ParamListRequest -State $paramState -Role $s.spec.role -Workflow $s.workflow -HeartbeatCount $s.product_observations.Count -CaptureDeadlineTicks ([string]$deadline) -RawOffset $paramDeliveredOffset -ReaderPendingBytes $paramReaderStatus.PendingByteCount -NowTicks {[string]$clock.ElapsedTicks} -Writer {param([byte[]]$payload)$s.port.Write($payload,0,$payload.Length);return [int]$payload.Length}
            if($attempted){$serialWrites++}
          }
          [void](Update-R19ParamListCheckpoint -State $paramState -ReaderStatus $paramReaderStatus -OutputDirectory $OutputDirectory)
        }catch{$paramDiagnosticsFailure=$_.Exception.Message}
      }
    }
    # Native read owners continue independently during the bounded parser pause.
    Start-Sleep -Milliseconds 2
  }
  $measurementEnd=[string]$clock.ElapsedTicks
}catch{$failure=$_.Exception.Message}
finally{
  foreach($s in $states){
    try{
      $s.joined=$s.reader.Stop(500)
      if(-not$s.joined){$s.cleanup_close_fallback=$true;$s.joined=$s.reader.CloseAndStop(1000)}
      $s.snapshot=$s.reader.GetSnapshot();$s.raw=$s.reader.ReadSlice(0,$s.snapshot.ByteCount)
      if(-not$s.joined-or$s.cleanup_close_fallback-or$s.snapshot.Overflow-or-not[string]::IsNullOrEmpty($s.snapshot.Failure)-or-not[string]::IsNullOrEmpty($s.snapshot.CleanupFailure)){$cleanupProven=$false}
    }catch{$cleanupProven=$false;if(-not$failure){$failure='Reader cleanup: '+$_.Exception.Message}}
    try{
      if($s.joined){Assert-R19Acquisition ($s.reader.CloseSourceAfterStop()) 'Tracked port close failed'}
      elseif($s.port.IsOpen){$s.port.Close()}
    }catch{$cleanupProven=$false;if(-not$failure){$failure='Port close: '+$_.Exception.Message}}
    finally{
      try{$s.snapshot=$s.reader.GetSnapshot()}catch{$cleanupProven=$false}
      try{$s.port.Dispose()}catch{$cleanupProven=$false}
    }
  }
}
if($ParamListDiagnostics-and-not$paramDiagnosticsFailure){
  # Retain and ingest the final native tail after stopping, never by reopening
  # COM or discarding bytes. A late predeadline slice invalidates an already
  # sealed checkpoint in the final ledger rather than rewriting history.
  try{
    $groundState=@($states|Where-Object{$_.spec.role-ceq'ground'})
    if($groundState.Count-eq1-and$null-ne$groundState[0].raw-and$null-ne$groundState[0].snapshot){
      $gs=$groundState[0]
      foreach($nativeBlock in $gs.snapshot.Blocks){
        [long]$endOffset=[long]$nativeBlock.Offset+[long]$nativeBlock.Count
        if($endOffset-le$paramDeliveredOffset){continue}
        [long]$sliceStart=[Math]::Max([long]$nativeBlock.Offset,$paramDeliveredOffset)
        [byte[]]$slice=New-Object byte[] ([int]($endOffset-$sliceStart))
        [Array]::Copy($gs.raw,$sliceStart,$slice,0,$slice.Length)
        $null=Add-R19ParamListBytes -State $paramState -Bytes $slice -RawOffset $sliceStart -ReadCompletedTicks ([string]$nativeBlock.EndTicks)
        $paramDeliveredOffset=$endOffset
      }
      if(-not$paramState.frozen-and$paramDeliveredOffset-eq$gs.snapshot.ByteCount){
        $watermark=[pscustomobject]@{LastReadEndTicks=$gs.snapshot.LastReadEndTicks;PendingByteCount=0}
        [void](Update-R19ParamListCheckpoint -State $paramState -ReaderStatus $watermark -OutputDirectory $OutputDirectory)
      }
    }
  }catch{$paramDiagnosticsFailure=$_.Exception.Message}
}
$readComparisonContext=[pscustomobject]@{clock_domain_id=$domain;frequency=$frequency;measurement_start_ticks=$measurementStart;measurement_end_ticks=$measurementEnd}
$readComparisonEvidence=Get-R19ReadComparisonEvidence -States $states.ToArray() -Context $readComparisonContext
$readComparison=[pscustomobject]@{plan=$readComparisonPlan;evidence=$readComparisonEvidence;evaluation=(Get-R19ReadComparisonEvaluation -Plan $readComparisonPlan -Evidence $readComparisonEvidence)}
$paramSnapshot=$null
if($ParamListDiagnostics){$paramSnapshot=Get-R19ParamListSnapshot -State $paramState}
# Keep the persistence entry self-contained: legacy callers can materialize the
# inert CLI context without opt-in locals, helper imports or device operations.
$summary=Save-R19TimedPathCaptureEvidence -States $states.ToArray() -OutputDirectory $OutputDirectory -Context ([pscustomobject]@{
  candidate_id=$plan.candidate_id;mode=$Mode;capture_seconds=$CaptureSeconds;started_utc=$started;clock_domain_id=$domain;frequency=$frequency
  measurement_start_ticks=$measurementStart;measurement_end_ticks=$measurementEnd;cleanup_proven=$cleanupProven;hardware_interaction=$hardware
  serial_write_calls=$serialWrites;failure=$failure;identity_evidence=$identityEvidence.ToArray();pinned_inputs=$pinInputs.ToArray()
  handoff_sha256=$handoffSha;flash_evidence_sha256=$flashSha;repo_root=$repo;read_comparison=$readComparison
  param_list_diagnostics_enabled=[bool]$PSBoundParameters['ParamListDiagnostics']
  grant_diagnostics_enabled=[bool]$PSBoundParameters['GrantDiagnostics']
  grant_diagnostics_selection_present=($PSBoundParameters.Keys-ccontains'GrantDiagnostics')
  param_list_diagnostics=if($PSBoundParameters['ParamListDiagnostics']){$paramSnapshot}else{$null}
  param_list_diagnostics_failure=if($PSBoundParameters['ParamListDiagnostics']){$paramDiagnosticsFailure}else{''}})
Write-Output ($summary.result+' candidate='+$plan.candidate_id+' mode='+$Mode)
if($summary.result-ceq'INVALID_CAPTURE'){exit 1}
