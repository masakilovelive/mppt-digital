[CmdletBinding()]
param([switch]$ImportOnly,[switch]$Execute,[string]$RepoRoot='', [string]$OutputDirectory='',
  [string]$CandidateHandoffPath='', [string]$CandidateFlashEvidencePath='', [string]$ExecutionPermitPath='',
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

function Assert-R19TimedPathLiveIdentity([object]$Spec,[string]$Checkpoint){
  $rows=@(Get-CimInstance Win32_SerialPort -ErrorAction Stop|Where-Object{[string]$_.DeviceID-ceq$Spec.port})
  Assert-R19Acquisition ($rows.Count-eq1-and[string]::Equals([string]$rows[0].PNPDeviceID,[string]$Spec.pnp_instance_id,[StringComparison]::OrdinalIgnoreCase)) ('USB role identity mismatch at '+$Checkpoint)
  $parent=Get-PnpDeviceProperty -InstanceId ([string]$rows[0].PNPDeviceID) -KeyName DEVPKEY_Device_Parent -ErrorAction Stop
  Assert-R19Acquisition ([string]::Equals([string]$parent.Data,[string]$Spec.usb_parent_instance_id,[StringComparison]::OrdinalIgnoreCase)) ('USB parent identity mismatch at '+$Checkpoint)
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
  [pscustomobject][ordered]@{role=$RawEvidence.role;port=$State.spec.port;baud=$State.spec.baud;reader_id=$State.reader_id
    clock_domain_id=$Context.clock_domain_id;frequency=$Context.frequency;nonce=$State.nonce
    open_before_ticks=$State.open_before_ticks;open_after_ticks=$State.open_after_ticks;read_started_ticks=$State.read_started_ticks
    reader_continuous=($State.opened-and$State.joined-and-not$State.cleanup_close_fallback-and-not$State.snapshot.Overflow-and[string]::IsNullOrEmpty($State.snapshot.Failure))
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
$plan=Get-R19TimedPathCapturePlan -Handoff $handoff -FlashEvidence $flash -Permit $permit -Mode $Mode -HandoffSha256 $handoffSha -FlashEvidenceSha256 $flashSha -NowUtc ([DateTime]::UtcNow)
# The safe outer owns flashing, JTAG, rollback and the human safety grant. This
# runner consumes that one grant atomically. It never flashes or restores itself.
$claim=[IO.FileStream]::new(($permitPath+'.consumed'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{[byte[]]$permitClaimBytes=[Text.Encoding]::UTF8.GetBytes($plan.candidate_id+' '+$Mode);$claim.Write($permitClaimBytes,0,$permitClaimBytes.Length);$claim.Flush($true)}finally{$claim.Dispose()}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$started=[DateTime]::UtcNow.ToString('o');$failure='';$cleanupProven=$true;$hardware=$false;$serialWrites=0
$states=[Collections.Generic.List[object]]::new();$identityEvidence=[Collections.Generic.List[object]]::new()
$clock=[Diagnostics.Stopwatch]::StartNew();$domain=[Guid]::NewGuid().ToString('N');$frequency=[string][Diagnostics.Stopwatch]::Frequency
$measurementStart='';$measurementEnd='';$pinInputs=[Collections.Generic.List[object]]::new()
try{
  # Independently verify the full sealed candidate before any port is opened.
  $verifier=Join-Path $repo 'tools/verify_r19_candidate_artifact.ps1'
  $engine=(Get-Process -Id $PID).Path
  $verifyOutput=& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $verifier -RepoRoot $repo -HandoffPath $handoffPath -RuntimeFailDiagnostics -TimedPathMode $Mode 2>&1
  [IO.File]::WriteAllLines((Join-Path $OutputDirectory 'candidate_verify.log'),[string[]]@($verifyOutput),[Text.UTF8Encoding]::new($false))
  Assert-R19Acquisition ($LASTEXITCODE-eq0) 'Mode-specific sealed candidate verification failed'
  foreach($relative in @('tools/r19_timed_path_acquisition.ps1','tools/r19_continuous_reader.cs','tools/r19_startup_reader.cs','tools/r19_host_readiness_workflow.ps1','tools/r19_host_readiness_wire.ps1','tools/r19_usb_clock_correlation.ps1','tools/r19_timed_path_trace.ps1')){
    $p=Join-Path $repo $relative;$pinInputs.Add([pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash})
  }
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
    $states.Add([pscustomobject]@{spec=$spec;port=$port;reader=$reader;reader_id=[Guid]::NewGuid().ToString('N');nonce=$nonce;parser=(New-R19TimedPathPrivateParser $nonce);product_parser=(New-R19TimedPathHeartbeatParser);product_observations=[Collections.Generic.List[object]]::new();workflow=$null;workflow_failure='';observations=[Collections.Generic.List[object]]::new();writes=[Collections.Generic.List[object]]::new();opened=$false;open_before_ticks='';open_after_ticks='';read_started_ticks='';snapshot=$null;raw=$null;joined=$false;cleanup_close_fallback=$false})
  }
  foreach($s in $states){Assert-R19Acquisition ($s.reader.WaitReady(1000)) 'Native read owner preparation timeout';[void]$s.reader.GetStatus();[void]$s.reader.PollBytes(1)}
  [void](Test-R19TimedPathExecutionPermit -Permit $permit -Mode $Mode -CandidateId $plan.candidate_id -HandoffSha256 $handoffSha -FlashEvidenceSha256 $flashSha -NowUtc ([DateTime]::UtcNow))
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
    foreach($s in $states){
      $status=$s.reader.GetStatus()
      Assert-R19Acquisition (-not$status.Stopped-and-not$status.Overflow-and[string]::IsNullOrEmpty($status.Failure)) ('Read owner failed: '+$s.spec.role+' '+$status.Failure)
      if($null-eq$s.workflow-and$status.FirstReadBeginTicks-ge0){
        $s.read_started_ticks=[string]$status.FirstReadBeginTicks
        $roleMode=if($s.spec.role-ceq'ground'){$Mode}else{'SyncOnly'}
        $s.workflow=New-R19HostReadinessWorkflow -Mode $roleMode -Role $s.spec.role -Nonce $s.nonce -ReaderIdentity $s.reader_id -ClockDomainId $domain -TickFrequency $frequency -StartTicks ([string]$clock.ElapsedTicks) -ReadStartedTicks $s.read_started_ticks -TimeoutTicks ([string]([Numerics.BigInteger]::Parse($frequency)*5))
        try{
          [byte[]]$bytes=New-R19HostReadinessClockRequest -State $s.workflow -NowTicks ([string]$clock.ElapsedTicks) -ReaderIdentity $s.reader_id -ReaderAlive $true -ClockDomainId $domain
          $serialWrites++
          $write=Invoke-R19TimedPathPrivateWrite -Kind ClockRequest -Bytes $bytes -Ledger $s.writes -ClockDomainId $domain -Frequency $frequency -NowTicks {[string]$clock.ElapsedTicks} -Writer {param([byte[]]$payload)$s.port.Write($payload,0,$payload.Length)}
          Set-R19HostReadinessWriteCommit -State $s.workflow -Kind ClockRequest -AcceptedBytes $write.accepted_bytes -WriteStartedTicks $write.started_ticks -NowTicks $write.returned_ticks -ReaderIdentity $s.reader_id -ReaderAlive $true -ClockDomainId $domain
        }catch{$s.workflow_failure=$_.Exception.Message}
      }
      foreach($block in $s.reader.PollBytes(8192)){
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
    try{if($s.port.IsOpen){$s.port.Close()};$s.port.Dispose()}catch{$cleanupProven=$false}
  }
}
$summary=Save-R19TimedPathCaptureEvidence -States $states.ToArray() -OutputDirectory $OutputDirectory -Context ([pscustomobject]@{
  candidate_id=$plan.candidate_id;mode=$Mode;capture_seconds=$CaptureSeconds;started_utc=$started;clock_domain_id=$domain;frequency=$frequency
  measurement_start_ticks=$measurementStart;measurement_end_ticks=$measurementEnd;cleanup_proven=$cleanupProven;hardware_interaction=$hardware
  serial_write_calls=$serialWrites;failure=$failure;identity_evidence=$identityEvidence.ToArray();pinned_inputs=$pinInputs.ToArray()
  handoff_sha256=$handoffSha;flash_evidence_sha256=$flashSha;repo_root=$repo})
Write-Output ($summary.result+' candidate='+$plan.candidate_id+' mode='+$Mode)
if($summary.result-ceq'INVALID_CAPTURE'){exit 1}
