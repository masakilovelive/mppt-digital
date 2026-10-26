[CmdletBinding()]
param(
  [switch]$Execute,
  [switch]$OfflineSelfTest,
  [switch]$OfflineCaptureFailureProbe,
  [string]$RepoRoot = '',
  [string]$OutputDirectory = '',
  [string]$CandidateHandoffPath = '',
  [string]$CandidateFlashEvidencePath = '',
  [int]$CaptureSeconds = 40
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$newline = [Environment]::NewLine
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
$TestId = 'R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001'
$VehiclePort = 'COM3'
$GroundPort = 'COM6'
$PumpServiceLimitUs = [int64]100000
$PumpReadBudgetBytes = 8192
$ExpectedStartupReaderSha256 =
    '939EF6C3333B1BC67782CFB02AEBFBC067EE6AAC7C789FB171F06C2B9F8A8C2E'
$ExpectedContinuousReaderSha256 =
    'B9C22B9E74F32E09C1210F976363CF4513C66F3131780B96972BEC48B1F907EF'
$TerminalTailDrainLimitUs = [int64]500000
$DiagnosticFlashStatus = 'PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY'
$DiagnosticAuthorizationScope =
    'one immediate R19 runtime-fail diagnostic capture only'
$DiagnosticNextAction =
    'Run one dual-COM read-only runtime-fail diagnostic capture, then mandatory accepted R18 rollback'
$DiagnosticAuthorizationToken =
    'R19_RUNTIME_FAIL_DIAGNOSTIC_HIL_ONE_RUN_NOT_ACCEPTANCE_NOT_DEPLOYMENT'
$r19Pattern = '^R19F:(?<role>[GV]):(?<line>[0-9A-F]{4}):' +
    '(?<time>[0-9A-F]{16}):(?<status>[0-9A-F]{12}):' +
    '(?<epoch>[0-9A-F]{8})$'
$r19AlivePattern = '^R19A:(?<role>[GV]):(?<state>[AL]):' +
    '(?<ordinal>[0-9A-F]{8}):(?<time>[0-9A-F]{16}):' +
    '(?<status>[0-9A-F]{12})\x00{3}$'
$portSpecs = @(
  [pscustomobject][ordered]@{
    role='vehicle';code='V';port=$VehiclePort;baud=115200
    pnp='USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000'
    parent='USB\VID_303A&PID_1001\90:70:69:11:81:A4'
  },
  [pscustomobject][ordered]@{
    role='ground';code='G';port=$GroundPort;baud=57600
    pnp='USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000'
    parent='USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80'
  }
)
$script:ExternalActions = [pscustomobject][ordered]@{
  cim_queried=$false;pnp_queried=$false;process_inventory_queried=$false
  com_ports_opened=$false;serial_write_attempted=$false
  opened_ports=[Collections.ArrayList]::new()
  serial_port_open_evidence=[Collections.ArrayList]::new()
  port_identity_evidence=[Collections.ArrayList]::new()
  firmware_write_attempted=$false;e220_write_attempted=$false
}
$script:SerialWriteCalls = 0
$script:StartedUtc = [DateTime]::UtcNow.ToString('o')
$script:RunnerStartSha = ''
$script:PinnedInputs = [Collections.ArrayList]::new()
$script:Definitions = @{}
$script:CaptureCleanupResult = $null
$script:CaptureLifecycleTrace = $null
$script:StartupReaderEvidence = $null
$script:StartupReaderSource = $null
$script:ContinuousReaderSource = $null

function Assert-Condition([bool]$Condition,[string]$Message) {
  if (-not $Condition) {throw $Message}
}

function Get-Sha([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash
}

function Get-ByteSha([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')
  } finally {$sha.Dispose()}
}

function Write-DurableBytes([string]$Path,[byte[]]$Bytes) {
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
  $stream = [IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,[IO.FileShare]::Read,4096,
      [IO.FileOptions]::WriteThrough)
  try {
    if ($Bytes.Length -gt 0) {$stream.Write($Bytes,0,$Bytes.Length)}
    $stream.Flush($true)
  } finally {$stream.Dispose()}
}

function Write-DurableJson([string]$Path,[object]$Value) {
  Write-DurableBytes $Path $utf8.GetBytes(
      (ConvertTo-Json $Value -Depth 30) + $newline)
}

function New-R19PcLifecycleTrace([ValidateRange(16,65536)][int]$Capacity=8192) {
  # This independent clock begins before Open. The legacy capture stopwatch
  # retains its original origin, fairness SLA and startup-drain semantics.
  [pscustomobject]@{clock=[Diagnostics.Stopwatch]::StartNew()
    clock_domain_id=[guid]::NewGuid().ToString('N')
    frequency=[Diagnostics.Stopwatch]::Frequency
    utc_display_anchor=[DateTime]::UtcNow.ToString('o')
    capacity=$Capacity;words=[long[]]::new($Capacity*6)
    count=0;dropped_events=[long]0;first_positive_role_mask=0}
}

function Add-R19PcLifecycleEvent([object]$Trace,[int]$Code,[string]$Role,
    [long]$Batch=0,[long]$ByteCount=0,[long]$Detail=0,[long]$Ticks=-1) {
  if($null-eq$Trace){return}
  if($Trace.count-ge$Trace.capacity){
    if($Trace.dropped_events-lt[long]::MaxValue){$Trace.dropped_events++}
    return
  }
  if($Ticks-lt0){$Ticks=$Trace.clock.ElapsedTicks}
  $roleCode=if($Role-ceq'ground'){2}elseif($Role-ceq'vehicle'){1}else{0}
  $offset=$Trace.count*6
  $Trace.words[$offset]=$Code;$Trace.words[$offset+1]=$roleCode
  $Trace.words[$offset+2]=$Ticks;$Trace.words[$offset+3]=$Batch
  $Trace.words[$offset+4]=$ByteCount;$Trace.words[$offset+5]=$Detail
  $Trace.count++
}

function ConvertTo-R19PcLifecycleEvidence([object]$Trace) {
  $names=@('INVALID','OPEN_BEGIN','OPEN_RETURN','OPEN_ERROR','READ_LOOP_ARMED',
    'READ_BEGIN','READ_END','FIRST_POSITIVE_READ','FRAME_COMPLETE','READ_ERROR',
    'CLOSE_BEGIN','CLOSE_RETURN','CLOSE_ERROR')
  $events=[Collections.ArrayList]::new()
  for($i=0;$i-lt$Trace.count;++$i){
    $o=$i*6;$code=[int]$Trace.words[$o]
    [void]$events.Add([pscustomobject]@{event=$names[$code];event_code=$code
      role=@('unspecified','vehicle','ground')[[int]$Trace.words[$o+1]]
      elapsed_ticks=[string]$Trace.words[$o+2];batch_id=$Trace.words[$o+3]
      byte_count=$Trace.words[$o+4];detail=$Trace.words[$o+5];source='main-thread'})
  }
  # Native readers never write the PowerShell-owned trace concurrently.
  # Merge their stopped, bounded evidence by the SAME QPC only after cleanup.
  [long]$mergeDropped=0
  foreach($reader in @($script:StartupReaderEvidence)){
    if($null-eq$reader-or$reader.clock_domain_id-cne$Trace.clock_domain_id-or-not$reader.armed){continue}
    $native=[Collections.ArrayList]::new()
    [void]$native.Add(@(4,[long]$reader.arm_ticks,0,0))
    if([long]$reader.first_read_begin_ticks-ge0){
      [void]$native.Add(@(5,[long]$reader.first_read_begin_ticks,1,[long]$reader.first_read_requested_count))
    }
    if([long]$reader.first_read_end_ticks-ge0){
      $firstBytes=if($reader.blocks.Count-gt0-and$reader.blocks[0].Batch-eq1){$reader.blocks[0].Count}else{0}
      [void]$native.Add(@(6,[long]$reader.first_read_end_ticks,1,[long]$firstBytes))
    }
    foreach($block in $reader.blocks){
      if($block.Batch-ne1){
        [void]$native.Add(@(5,[long]$block.BeginTicks,[long]$block.Batch,[long]$block.RequestedCount))
        [void]$native.Add(@(6,[long]$block.EndTicks,[long]$block.Batch,[long]$block.Count))
      }
    }
    if($reader.blocks.Count-gt0){
      $first=$reader.blocks[0]
      [void]$native.Add(@(7,[long]$first.EndTicks,[long]$first.Batch,[long]$first.Count))
    }
    foreach($entry in $native){
      if($events.Count-ge$Trace.capacity){$mergeDropped++;continue}
      [void]$events.Add([pscustomobject]@{event=$names[[int]$entry[0]]
        event_code=[int]$entry[0];role=[string]$reader.role
        elapsed_ticks=[string]$entry[1];batch_id=[long]$entry[2]
        byte_count=[long]$entry[3];detail=2;source=$(if($reader.PSObject.Properties['schema']-and$reader.schema-ceq'vc-lora-r19-continuous-reader-v1'){'continuous-native'}else{'startup-native'})})
    }
  }
  # Windows PowerShell 5.1 Sort-Object is not stable for equal keys. Several
  # observations intentionally share the read-return tick, so preserve their
  # insertion order without inventing distinct timestamps. This allocation
  # and sorting occur only after reader cleanup, never in the event path.
  $indexedEvents=for($eventIndex=0;$eventIndex-lt$events.Count;++$eventIndex){
    [pscustomobject]@{ordinal=$eventIndex;value=$events[$eventIndex]}
  }
  $orderedEvents=@($indexedEvents|
    Sort-Object @{Expression={[long]$_.value.elapsed_ticks}},ordinal|
    ForEach-Object {$_.value})
  [long]$dropped=$Trace.dropped_events+$mergeDropped
  [pscustomobject][ordered]@{schema='vc-lora-r19-pc-usb-lifecycle-trace-v1'
    result=$(if($dropped-eq0){'COMPLETE'}else{'INCOMPLETE'})
    clock_domain_id=$Trace.clock_domain_id;clock='shared-stopwatch-qpc'
    frequency=[string]$Trace.frequency;frequency_gt_zero=($Trace.frequency-gt0)
    utc_display_anchor=$Trace.utc_display_anchor;utc_used_for_ordering=$false
    capacity_events=$Trace.capacity;storage_bytes=$Trace.words.Length*8
    event_count=$orderedEvents.Count;dropped_events=$dropped;events=$orderedEvents
    startup_native_events_merged=$true
    limitations=@('READ_BEGIN is an application call boundary, not proof of a kernel-pending request or host USB polling.','Native no-data retries are summarized by reader counters; not every timeout is a trace event.','READ_END and FRAME_COMPLETE are application observations, not physical USB arrival timestamps.','Startup-drain bytes may predate Open or the read loop.','QPC ticks alone cannot correlate a separate device clock.','If dropped_events is nonzero the trace must not prove missing event ordering.','Equal QPC ticks preserve merge/insertion order for display, not physical ordering between owners.')}
}

function Save-DiagnosticCaptureEvidence([object[]]$States,
    [Collections.ArrayList]$Errors) {
  foreach($state in $States){
    $role=[string]$state.spec.role
    try{
      $rawPath=Join-Path $evidence ("{0}.raw.bin"-f$role)
      Write-DurableBytes $rawPath ([byte[]]$state.raw.ToArray())
      if($state.PSObject.Properties['continuous_raw']-and$null-ne$state.continuous_raw){
        # Includes unconsumed suffixes and identity-quarantined data on failures.
        # This is the authoritative full native capture, not parser admission.
        Write-DurableBytes (Join-Path $evidence ("{0}.continuous.raw.bin"-f$role)) `
            ([byte[]]$state.continuous_raw)
      }
    }catch{
      [void]$Errors.Add(
          ('deferred raw evidence persistence failed for {0}: {1}' -f
            $role,$_.Exception.Message))
    }
    foreach($pending in $state.pending_frames){
      $pendingPath=''
      try{
        $pendingPath=[string]$pending.path
        Write-DurableBytes (Join-Path $evidence ([string]$pending.path)) `
            ([byte[]]$pending.bytes)
      }catch{
        [void]$Errors.Add(
            ('deferred frame evidence persistence failed for {0}/{1}: {2}' -f
              $role,$pendingPath,$_.Exception.Message))
      }
    }
    try{$state.raw.Dispose()}catch{
      [void]$Errors.Add(
          ('raw buffer dispose failed for {0}: {1}' -f
            $role,$_.Exception.Message))}
  }
}

function Invoke-DiagnosticCaptureCleanup([object[]]$States,
    [Collections.ArrayList]$Errors) {
  $steps=[Collections.ArrayList]::new()
  # On failure the quarantined bytes still belong to evidence, not to a
  # successful diagnostic classification. Join before persisting/disposal.
  foreach($state in $States){
    if($state.PSObject.Properties['continuous_reader']){
      try{Stop-R19ContinuousCapture $state}catch{
        [void]$Errors.Add(('continuous reader cleanup failed for {0}: {1}'-f
            $state.spec.role,$_.Exception.Message))}
    }elseif($state.PSObject.Properties['startup_reader']){
      try{Stop-R19StartupCapture $state $true}catch{
        [void]$Errors.Add(('startup reader cleanup failed for {0}: {1}' -f
            $state.spec.role,$_.Exception.Message))}
    }
  }
  if(@($States|Where-Object{$_.PSObject.Properties['startup_reader']}).Count-gt0){
    $script:StartupReaderEvidence=@($States|ForEach-Object{$_.startup_evidence})
  }
  foreach($state in $States){
    $role=[string]$state.spec.role
    $trace=if($state.PSObject.Properties['lifecycle_trace']){$state.lifecycle_trace}else{$null}
    if($null-ne$trace){Add-R19PcLifecycleEvent $trace 10 $role}
    try{
      if($state.serial.IsOpen){$state.serial.Close()}
      if($null-ne$trace){Add-R19PcLifecycleEvent $trace 11 $role}
      [void]$steps.Add([pscustomobject][ordered]@{
        name=('serial_close:'+$role);result='PASS';failure=''})
    }catch{
      if($null-ne$trace){Add-R19PcLifecycleEvent $trace 12 $role}
      $message='serial close failed for {0}: {1}'-f$role,$_.Exception.Message
      [void]$Errors.Add($message)
      [void]$steps.Add([pscustomobject][ordered]@{
        name=('serial_close:'+$role);result='FAIL';failure=$message})
    }
    try{
      $state.serial.Dispose()
      [void]$steps.Add([pscustomobject][ordered]@{
        name=('serial_dispose:'+$role);result='PASS';failure=''})
    }catch{
      $message='serial dispose failed for {0}: {1}'-f$role,$_.Exception.Message
      [void]$Errors.Add($message)
      [void]$steps.Add([pscustomobject][ordered]@{
        name=('serial_dispose:'+$role);result='FAIL';failure=$message})
    }
  }
  [int]$beforePersistence=$Errors.Count
  Save-DiagnosticCaptureEvidence $States $Errors
  [string[]]$persistenceErrors=@()
  if($Errors.Count-gt$beforePersistence){
    $persistenceErrors=@($Errors.GetRange(
        $beforePersistence,$Errors.Count-$beforePersistence)|
        ForEach-Object{[string]$_})
  }
  [void]$steps.Add([pscustomobject][ordered]@{
    name='deferred_evidence_persistence'
    result=if($persistenceErrors.Count-eq0){'PASS'}else{'FAIL'}
    failure=$persistenceErrors-join' | '})
  return [pscustomobject][ordered]@{
    result=if($Errors.Count-eq0){'PASS'}else{'FAIL'}
    error_count=[int]$Errors.Count;errors=@($Errors);steps=@($steps)
  }
}

function Get-DiagnosticFrameLeaf([string]$Role,[int]$FrameOrdinal) {
  Assert-Condition ($Role -cin @('vehicle','ground')) `
      "Invalid diagnostic frame role: $Role"
  Assert-Condition ($FrameOrdinal -ge 1) `
      "Diagnostic frame ordinal must be positive: $FrameOrdinal"
  return ('{0}.frame-{1:D6}.bin' -f $Role,$FrameOrdinal)
}

function Copy-PinnedInput([string]$Source,[string]$Name) {
  [byte[]]$bytes=[IO.File]::ReadAllBytes($Source)
  $sourceSha=Get-ByteSha $bytes
  $target=Join-Path $evidence ('inputs\'+$Name)
  Write-DurableBytes $target $bytes
  Assert-Condition ((Get-Sha $Source)-ceq$sourceSha -and
      (Get-Sha $target)-ceq$sourceSha) `
      "Pinned input changed during copy: $Name"
  $record=[pscustomobject][ordered]@{name=$Name;source=$Source
    staged=$target;bytes=$bytes.Length;sha256=$sourceSha}
  [void]$script:PinnedInputs.Add($record)
  return $record
}

function Update-X25Crc([uint16]$Crc,[byte]$Value) {
  [int]$mixed = ($Value -bxor ($Crc -band 0xFF)) -band 0xFF
  $mixed = ($mixed -bxor (($mixed -shl 4) -band 0xFF)) -band 0xFF
  return [uint16]((($Crc -shr 8) -bxor ($mixed -shl 8) -bxor
      ($mixed -shl 3) -bxor ($mixed -shr 4)) -band 0xFFFF)
}

function Get-MavlinkDefinitions([string]$Path) {
  $text=[IO.File]::ReadAllText($Path)
  $matches=[regex]::Matches($text,
      '\{(?<id>[0-9]+)U,\s*(?<crc>[0-9]+)U,\s*(?<min>[0-9]+)U,\s*(?<max>[0-9]+)U\}')
  $definitions=@{}
  foreach($match in $matches){
    $id=[int]$match.Groups['id'].Value
    Assert-Condition (-not$definitions.ContainsKey($id)) `
        "Duplicate MAVLink definition $id"
    $definitions[$id]=[pscustomobject][ordered]@{
      crc_extra=[int]$match.Groups['crc'].Value
      min_payload=[int]$match.Groups['min'].Value
      max_payload=[int]$match.Groups['max'].Value}
  }
  Assert-Condition ($definitions.Count-eq80) `
      "Expected 80 pinned MAVLink definitions, got $($definitions.Count)"
  Assert-Condition ($definitions[0].crc_extra-eq50-and
      $definitions[21].crc_extra-eq159-and
      $definitions[22].crc_extra-eq220-and
      $definitions[253].crc_extra-eq83) `
      'Required pinned MAVLink definitions changed.'
  return $definitions
}

function New-DiagnosticParser([string]$Name) {
  [pscustomobject][ordered]@{
    name=$Name;buffer=[Collections.Generic.List[byte]]::new()
    expected_size=0;total_bytes=[int64]0;noise_bytes=[int64]0
    frame_start_read_batch_id=[int64]-1
    frame_start_capture_origin='UNSPECIFIED'
    partial_first_seen_us=[int64]-1;partial_last_progress_us=[int64]-1
    partial_raw_offset=[int64]-1
    partial_bytes=0;bad_length=[int64]0;bad_crc=[int64]0
    unsupported_flags=[int64]0;unknown_definition=[int64]0
    valid_frames=[int64]0;frames=[Collections.ArrayList]::new()
  }
}

function Add-DiagnosticBytes([object]$Parser,[byte[]]$Bytes,[int64]$NowUs,
    [int64]$ReadBatchId=-1,[string]$CaptureOrigin='SYNTHETIC',
    [object]$LifecycleTrace=$null,[long]$LifecycleTicks=-1) {
  foreach ($value in $Bytes) {
    [int64]$offset = $Parser.total_bytes
    $Parser.total_bytes = $offset + 1
    if ($Parser.buffer.Count -eq 0) {
      if($value -ne 0xFD){
        $Parser.noise_bytes = [int64]$Parser.noise_bytes + 1
        continue
      }
      $Parser.frame_start_read_batch_id=$ReadBatchId
      $Parser.frame_start_capture_origin=$CaptureOrigin
      $Parser.partial_first_seen_us=$NowUs
      $Parser.partial_raw_offset=$offset
    }
    $Parser.buffer.Add([byte]$value)
    $Parser.partial_last_progress_us=$NowUs
    if ($Parser.buffer.Count -eq 3) {
      $signature = if (($Parser.buffer[2] -band 1) -ne 0) {13} else {0}
      $Parser.expected_size = [int]$Parser.buffer[1] + 12 + $signature
    }
    if ($Parser.expected_size -gt 0 -and
        $Parser.buffer.Count -eq $Parser.expected_size) {
      [byte[]]$raw = $Parser.buffer.ToArray()
      [int]$payloadLength = $raw[1]
      [int]$messageId = [int]$raw[7] -bor ([int]$raw[8] -shl 8) -bor
          ([int]$raw[9] -shl 16)
      $failure = ''
      if (($raw[2] -band 0xFE) -ne 0) {
        $failure='unsupported_flags'
      }elseif(-not$script:Definitions.ContainsKey($messageId)){
        $failure='unknown_definition'
      }else{
        $definition=$script:Definitions[$messageId]
        [int]$minimum=[int]$definition.min_payload
        if($messageId-eq20){$minimum=4}
        if($messageId-eq76){$minimum=30}
        if($payloadLength-lt$minimum-or
            $payloadLength-gt[int]$definition.max_payload){
          $failure='bad_length'
        }else{
          [int]$checksumOffset=10+$payloadLength
          [uint16]$crc=0xFFFF
          for($i=1;$i-lt$checksumOffset;++$i){
            $crc=Update-X25Crc $crc $raw[$i]
          }
          $crc=Update-X25Crc $crc ([byte]$definition.crc_extra)
          [uint16]$stored=[uint16]([int]$raw[$checksumOffset]-bor
              ([int]$raw[$checksumOffset+1]-shl8))
          if($stored-ne$crc){$failure='bad_crc'}
        }
      }
      $prefix = if($messageId -eq 253 -and $payloadLength -ge 5 -and
          $raw.Length -ge 15){
        [Text.Encoding]::ASCII.GetString($raw,11,4)}else{''}
      if ($prefix -in @('R19F','R19A') -and
          ($payloadLength-ne51-or$raw.Length-ne63)) {
        $failure='bad_length'
      }
      $record=[pscustomobject][ordered]@{
        complete_us=$NowUs;raw_offset=$offset-$raw.Length+1
        read_batch_id=$ReadBatchId;capture_origin=$CaptureOrigin
        start_read_batch_id=[int64]$Parser.frame_start_read_batch_id
        start_capture_origin=[string]$Parser.frame_start_capture_origin
        raw=$raw;raw_length=$raw.Length;raw_sha256=Get-ByteSha $raw
        valid=[string]::IsNullOrEmpty($failure);failure=$failure
        signed=(($raw[2] -band 1) -ne 0);sequence=[int]$raw[4]
        system_id=[int]$raw[5];component_id=[int]$raw[6]
        message_id=$messageId;payload_length=$payloadLength
      }
      if($null-ne$LifecycleTrace){
        Add-R19PcLifecycleEvent $LifecycleTrace 8 ([string]$Parser.name) `
            $ReadBatchId $raw.Length $messageId $LifecycleTicks
      }
      if($record.valid){
        $Parser.valid_frames=[int64]$Parser.valid_frames+1
      }else{
        switch($record.failure){
          'bad_crc' {$Parser.bad_crc=[int64]$Parser.bad_crc+1}
          'bad_length' {$Parser.bad_length=[int64]$Parser.bad_length+1}
          'unsupported_flags' {
            $Parser.unsupported_flags=[int64]$Parser.unsupported_flags+1}
          'unknown_definition' {
            $Parser.unknown_definition=[int64]$Parser.unknown_definition+1}
        }
      }
      [void]$Parser.frames.Add($record)
      $Parser.buffer.Clear();$Parser.expected_size=0
      $Parser.frame_start_read_batch_id=[int64]-1
      $Parser.frame_start_capture_origin='UNSPECIFIED'
      $Parser.partial_first_seen_us=[int64]-1
      $Parser.partial_last_progress_us=[int64]-1
      $Parser.partial_raw_offset=[int64]-1
    } elseif ($Parser.buffer.Count -gt 280) {
      $Parser.bad_length=[int64]$Parser.bad_length+1
      $Parser.buffer.Clear();$Parser.expected_size=0
      $Parser.frame_start_read_batch_id=[int64]-1
      $Parser.frame_start_capture_origin='UNSPECIFIED'
      $Parser.partial_first_seen_us=[int64]-1
      $Parser.partial_last_progress_us=[int64]-1
      $Parser.partial_raw_offset=[int64]-1
    }
  }
  $Parser.partial_bytes=$Parser.buffer.Count
}

function Get-DiagnosticParserSnapshot([object]$Parser) {
  [pscustomobject][ordered]@{
    total_bytes=[int64]$Parser.total_bytes
    noise_bytes=[int64]$Parser.noise_bytes
    partial_bytes=[int]$Parser.partial_bytes
    bad_length=[int64]$Parser.bad_length
    bad_crc=[int64]$Parser.bad_crc
    unsupported_flags=[int64]$Parser.unsupported_flags
    unknown_definition=[int64]$Parser.unknown_definition
    valid_frames=[int64]$Parser.valid_frames
    frame_count=[int]$Parser.frames.Count
  }
}

function Test-DiagnosticParserClean([object]$Parser) {
  return [int64]$Parser.noise_bytes-eq0-and
      [int]$Parser.partial_bytes-eq0-and
      [int64]$Parser.bad_length-eq0-and
      [int64]$Parser.bad_crc-eq0-and
      [int64]$Parser.unsupported_flags-eq0-and
      [int64]$Parser.unknown_definition-eq0
}

function Get-SourceBinding([string]$RoleCode,[object]$Provenance) {
  $role=if($RoleCode -ceq 'G'){'ground'}elseif($RoleCode -ceq 'V'){
    'vehicle'}else{''}
  $bindings=@($Provenance.source_bindings|Where-Object {$_.role -ceq $role})
  $apps=@($Provenance.roles|Where-Object {$_.role -ceq $role})
  $verified=$bindings.Count -eq 1 -and $apps.Count -eq 1
  $binding=if($bindings.Count -eq 1){$bindings[0]}else{$null}
  if($verified){
    $expected=('package/vc_lora_{0}_xiao_esp32s3/' +
        'vc_lora_phase6_bridge.hpp') -f $role
    $verified=[string]$binding.source_path -ceq $expected -and
        $binding.source_verified -is [bool] -and
        [bool]$binding.source_verified -and
        [string]$binding.source_sha256 -cmatch '^[0-9A-F]{64}$' -and
        [string]$binding.source_sha256 -ceq
          [string]$binding.verified_source_sha256 -and
        [string]$binding.application_sha256 -ceq [string]$apps[0].sha256
  }
  [pscustomobject][ordered]@{
    verified=$verified;role=$role
    source_path=if($null-ne$binding){[string]$binding.source_path}else{''}
    source_sha256=if($null-ne$binding){[string]$binding.source_sha256}else{''}
    application_sha256=if($null-ne$binding){
      [string]$binding.application_sha256}else{''}
  }
}

function Convert-R19Diagnostic([object]$Frame,[string]$PortRole,
    [object]$Provenance) {
  [byte[]]$raw=$Frame.raw
  $prefix=if($Frame.message_id -eq 253 -and $Frame.payload_length -ge 5 -and
      $raw.Length -ge 15){[Text.Encoding]::ASCII.GetString($raw,11,4)}else{''}
  if($prefix -notin @('R19F','R19A')){
    return [pscustomobject]@{candidate=$false}
  }
  $isFailure=$prefix-ceq'R19F'
  $failures=[Collections.ArrayList]::new()
  if(-not $Frame.valid){[void]$failures.Add('mavlink_'+$Frame.failure)}
  if($Frame.signed -or $Frame.system_id -ne 254 -or
      $Frame.component_id -ne 190 -or $Frame.payload_length -ne 51 -or
      $Frame.raw_length -ne 63){[void]$failures.Add('identity_or_length')}
  $expectedSeverity=if($isFailure){2}else{6}
  if($raw[10] -ne $expectedSeverity){[void]$failures.Add('severity')}
  $text=if($raw.Length -ge 61){[Text.Encoding]::ASCII.GetString($raw,11,50)}else{''}
  $pattern=if($isFailure){$r19Pattern}else{$r19AlivePattern}
  $match=[regex]::Match($text,$pattern)
  if(-not $match.Success){[void]$failures.Add('format')}
  $roleCode=if($match.Success){$match.Groups['role'].Value}else{''}
  if($roleCode -cne $PortRole){[void]$failures.Add('port_role_mismatch')}
  $binding=Get-SourceBinding $roleCode $Provenance
  if(-not $binding.verified){[void]$failures.Add('source_hash_mismatch')}
  if($isFailure-and$match.Success -and
      [Convert]::ToInt32($match.Groups['line'].Value,16) -eq 0){
    [void]$failures.Add('source_line_zero')
  }
  $statusHex=if($match.Success){$match.Groups['status'].Value}else{''}
  $packed=if($match.Success){[Convert]::ToInt32($statusHex.Substring(10,2),16)}else{0}
  [pscustomobject][ordered]@{
    candidate=$true;diagnostic_kind=if($isFailure){'R19F'}else{'R19A'}
    diagnostic_success=($failures.Count-eq 0)
    failure=if($failures.Count-eq 0){''}else{@($failures)-join ','}
    port_role=$PortRole;role=[string]$binding.role;role_code=$roleCode
    beacon_state=if(-not$isFailure-and$match.Success){
      if($match.Groups['state'].Value-ceq'A'){'ARMED'}else{'ALIVE'}}else{''}
    diagnostic_ordinal_hex=if(-not$isFailure-and$match.Success){
      $match.Groups['ordinal'].Value}else{''}
    diagnostic_ordinal=if(-not$isFailure-and$match.Success){
      [Convert]::ToUInt32($match.Groups['ordinal'].Value,16)}else{[uint32]0}
    source_line=if($isFailure-and$match.Success){
      [Convert]::ToInt32($match.Groups['line'].Value,16)}else{0}
    monotonic_ms_hex=if($match.Success){$match.Groups['time'].Value}else{''}
    monotonic_ms=if($match.Success){
      [Convert]::ToUInt64($match.Groups['time'].Value,16)}else{[uint64]0}
    status_hex=$statusHex
    status=if($match.Success){[pscustomobject][ordered]@{
      startup_fault=[Convert]::ToInt32($statusHex.Substring(0,2),16)
      e220_state=[Convert]::ToInt32($statusHex.Substring(2,2),16)
      e220_fault=[Convert]::ToInt32($statusHex.Substring(4,2),16)
      writer_status=[Convert]::ToInt32($statusHex.Substring(6,2),16)
      radio_session_status=[Convert]::ToInt32($statusHex.Substring(8,2),16)
      packed=$packed;adapter_fail_closed=(($packed-band 0x80)-ne 0)
      tdd_state=($packed-band 0x7F)}}else{$null}
    usb_loss_epoch=if($isFailure-and$match.Success){
      [Convert]::ToInt64($match.Groups['epoch'].Value,16)}else{-1}
    source_mapping_verified=[bool]$binding.verified
    source_path=[string]$binding.source_path
    source_sha256=[string]$binding.source_sha256
    application_sha256=[string]$binding.application_sha256
    mavlink_sequence=[int]$Frame.sequence
    raw_sha256=[string]$Frame.raw_sha256;raw_bytes=[int]$Frame.raw_length
    complete_us=[int64]$Frame.complete_us
    read_batch_id=[int64]$Frame.read_batch_id
    capture_origin=[string]$Frame.capture_origin
    start_read_batch_id=[int64]$Frame.start_read_batch_id
    start_capture_origin=[string]$Frame.start_capture_origin
  }
}

function New-SyntheticFrame([string]$RoleCode,[byte]$Sequence,
    [string]$SourceLine='01D2',[switch]$CorruptCrc) {
  $text=('R19F:{0}:{1}:00000000000004D2:010203040586:00000007' -f
      $RoleCode,$SourceLine)
  [byte[]]$frame=New-Object byte[] 63
  $frame[0]=0xFD;$frame[1]=51;$frame[4]=$Sequence
  $frame[5]=254;$frame[6]=190;$frame[7]=253;$frame[10]=2
  [byte[]]$textBytes=[Text.Encoding]::ASCII.GetBytes($text)
  [Array]::Copy($textBytes,0,$frame,11,50)
  [uint16]$crc=0xFFFF
  for($i=1;$i-lt61;++$i){$crc=Update-X25Crc $crc $frame[$i]}
  $crc=Update-X25Crc $crc 83
  $frame[61]=[byte]($crc-band 0xFF);$frame[62]=[byte](($crc-shr8)-band 0xFF)
  if($CorruptCrc.IsPresent){$frame[62]=$frame[62]-bxor1}
  return $frame
}

function New-SyntheticAliveFrame([string]$RoleCode,[byte]$Sequence,
    [ValidateSet('A','L')][string]$StateCode='L',
    [uint32]$DiagnosticOrdinal=2,[uint64]$MonotonicMs=1234,
    [switch]$CorruptCrc,[switch]$BadPadding,[byte]$Severity=6) {
  $text=('R19A:{0}:{1}:{2:X8}:{3:X16}:010203040586' -f
      $RoleCode,$StateCode,$DiagnosticOrdinal,$MonotonicMs)
  [byte[]]$frame=New-Object byte[] 63
  $frame[0]=0xFD;$frame[1]=51;$frame[4]=$Sequence
  $frame[5]=254;$frame[6]=190;$frame[7]=253;$frame[10]=$Severity
  [byte[]]$textBytes=[Text.Encoding]::ASCII.GetBytes($text)
  Assert-Condition ($textBytes.Length-eq47) `
      'Synthetic R19A text must be exactly 47 bytes.'
  [Array]::Copy($textBytes,0,$frame,11,$textBytes.Length)
  if($BadPadding.IsPresent){$frame[60]=0x58}
  [uint16]$crc=0xFFFF
  for($i=1;$i-lt61;++$i){$crc=Update-X25Crc $crc $frame[$i]}
  $crc=Update-X25Crc $crc 83
  $frame[61]=[byte]($crc-band0xFF);$frame[62]=[byte](($crc-shr8)-band0xFF)
  if($CorruptCrc.IsPresent){$frame[62]=$frame[62]-bxor1}
  return $frame
}

function New-SyntheticProductFrame([byte]$Sequence,[switch]$CorruptCrc) {
  [byte[]]$frame=New-Object byte[] 21
  $frame[0]=0xFD;$frame[1]=9;$frame[4]=$Sequence
  $frame[5]=1;$frame[6]=1;$frame[7]=0
  $frame[10]=0x78;$frame[11]=0x56;$frame[12]=0x34;$frame[13]=0x12
  $frame[18]=3
  [uint16]$crc=0xFFFF
  for($i=1;$i-lt19;++$i){$crc=Update-X25Crc $crc $frame[$i]}
  $crc=Update-X25Crc $crc 50
  $frame[19]=[byte]($crc-band0xFF);$frame[20]=[byte](($crc-shr8)-band0xFF)
  if($CorruptCrc.IsPresent){$frame[20]=$frame[20]-bxor1}
  return $frame
}

function Test-R19AliveMonotonic([object[]]$Diagnostics) {
  foreach($roleCode in @('V','G')){
    $events=@($Diagnostics|Where-Object{
      $_.candidate-and$_.diagnostic_success-and
      $_.diagnostic_kind-ceq'R19A'-and$_.role_code-ceq$roleCode})
    for($i=1;$i-lt$events.Count;++$i){
      if([uint32]$events[$i].diagnostic_ordinal-le
          [uint32]$events[$i-1].diagnostic_ordinal-or
          [uint64]$events[$i].monotonic_ms-le
          [uint64]$events[$i-1].monotonic_ms){return $false}
    }
  }
  return $true
}

function Get-R19FailureSnapshotKey([object]$Diagnostic) {
  return [string]::Join('|',@(
    [string]$Diagnostic.role_code
    [string]$Diagnostic.source_line
    [string]$Diagnostic.monotonic_ms_hex
    [string]$Diagnostic.status_hex
    [string]$Diagnostic.usb_loss_epoch
    [string]$Diagnostic.source_path
    [string]$Diagnostic.source_sha256
    [string]$Diagnostic.application_sha256
  ))
}

function Test-R19FailureRepeatContract([object[]]$Diagnostics) {
  $roleResults=[Collections.ArrayList]::new()
  $allValid=$true
  foreach($roleCode in @('V','G')){
    $events=@($Diagnostics|Where-Object{
      $_.candidate-and$_.diagnostic_success-and
      $_.diagnostic_kind-ceq'R19F'-and$_.role_code-ceq$roleCode})
    $withinLimit=$events.Count-le120
    $snapshots=@($events|ForEach-Object{Get-R19FailureSnapshotKey $_}|
        Sort-Object -Unique)
    $immutable=$events.Count-eq0-or
        ($snapshots.Count-eq1-and-not[string]::IsNullOrWhiteSpace($snapshots[0]))
    $sequenceForward=$true
    for($i=1;$i-lt$events.Count;++$i){
      [int]$expectedSequence=([int]$events[$i-1].mavlink_sequence+1)-band0xFF
      if([int]$events[$i].mavlink_sequence-ne$expectedSequence){
        $sequenceForward=$false
      }
    }
    $timestampsPresent=@($events|Where-Object{
      [int64]$_.complete_us-lt0}).Count-eq0
    [int]$observableIntervals=0;[int]$unobservableIntervals=0
    $cadenceSane=$true;[int64]$minimumGap=-1;[int64]$maximumGap=-1
    if($events.Count-ge2-and$timestampsPresent){
      for($i=1;$i-lt$events.Count;++$i){
        [string]$priorOrigin=[string]$events[$i-1].capture_origin
        [string]$currentOrigin=[string]$events[$i].capture_origin
        [string]$priorStartOrigin=[string]$events[$i-1].start_capture_origin
        [string]$currentStartOrigin=[string]$events[$i].start_capture_origin
        if($priorOrigin-ceq'STARTUP_DRAIN'-or
            $currentOrigin-ceq'STARTUP_DRAIN'-or
            $priorStartOrigin-ceq'STARTUP_DRAIN'-or
            $currentStartOrigin-ceq'STARTUP_DRAIN'){
          ++$unobservableIntervals
          continue
        }
        ++$observableIntervals
        [int64]$gap=[int64]$events[$i].complete_us-
            [int64]$events[$i-1].complete_us
        if($minimumGap-lt0-or$gap-lt$minimumGap){$minimumGap=$gap}
        if($gap-gt$maximumGap){$maximumGap=$gap}
        if($gap-lt500000-or$gap-gt1500000){$cadenceSane=$false}
      }
    }
    $cadenceChecked=$events.Count-lt2-or$observableIntervals-ge2
    if(-not$timestampsPresent-or-not$cadenceChecked){$cadenceSane=$false}
    $roleValid=$withinLimit-and$immutable-and$sequenceForward-and$cadenceSane
    if(-not$roleValid){$allValid=$false}
    [void]$roleResults.Add([pscustomobject][ordered]@{
      role_code=$roleCode;count=$events.Count;within_repeat_limit=$withinLimit
      immutable_snapshot=$immutable
      sequence_forward_contiguous=$sequenceForward
      cadence_checked=$cadenceChecked
      cadence_sane=$cadenceSane;minimum_gap_us=$minimumGap
      maximum_gap_us=$maximumGap
      observable_interval_count=$observableIntervals
      unobservable_interval_count=$unobservableIntervals
      logical_snapshot_key_sha256=if($snapshots.Count-eq1){
        Get-ByteSha $utf8.GetBytes($snapshots[0])}else{''}
    })
  }
  [pscustomobject][ordered]@{valid=$allValid;maximum_repeats_per_role=120
    minimum_cadence_gap_us=500000;maximum_cadence_gap_us=1500000
    roles=@($roleResults)}
}

function Get-R19DiagnosticClassification([object[]]$Diagnostics,
    [int]$OtherCompleteFrameCount=0,[bool]$AliveMonotonic=$true,
    [bool]$ParserClean=$true,[bool]$R19FailureRepeatValid=$true,
    [object]$TerminalPartialContract=$null,
    [object]$R19AliveTerminalPartialContract=$null,
    [object]$R19FailureBoundaryPartialContract=$null) {
  $invalid=@($Diagnostics|Where-Object{-not$_.diagnostic_success})
  $failures=@($Diagnostics|Where-Object{
    $_.diagnostic_success-and$_.diagnostic_kind-ceq'R19F'})
  $armed=@($Diagnostics|Where-Object{$_.diagnostic_success-and
    $_.diagnostic_kind-ceq'R19A'-and$_.beacon_state-ceq'ARMED'})
  $alive=@($Diagnostics|Where-Object{$_.diagnostic_success-and
    $_.diagnostic_kind-ceq'R19A'-and$_.beacon_state-ceq'ALIVE'})
  $aliveRoles=@($alive|ForEach-Object{$_.role_code}|Sort-Object -Unique)
  $coverage=if($aliveRoles.Count-eq2){'BOTH'}elseif($aliveRoles.Count-eq1){
    'PARTIAL'}else{'NONE'}
  if($invalid.Count-gt0-or-not$AliveMonotonic){
    return [pscustomobject][ordered]@{classification='INVALID'
      status='FAIL_INVALID_RUNTIME_DIAGNOSTIC';result='FAIL'
      engineering_disposition='FAIL_INVALID_RUNTIME_DIAGNOSTIC'
      alive_role_coverage=$coverage;alive_roles=$aliveRoles
      armed_count=$armed.Count;alive_count=$alive.Count}
  }
  if(-not$R19FailureRepeatValid){
    return [pscustomobject][ordered]@{classification='INVALID'
      status='FAIL_INVALID_R19F_REPEAT';result='FAIL'
      engineering_disposition='FAIL_INVALID_R19F_REPEAT'
      alive_role_coverage=$coverage;alive_roles=$aliveRoles
      armed_count=$armed.Count;alive_count=$alive.Count}
  }
  if($null-ne$TerminalPartialContract-and
      [bool]$TerminalPartialContract.valid-and
      [bool]$TerminalPartialContract.one_role_only-and
      [bool]$TerminalPartialContract.only_parser_defect-and
      [bool]$TerminalPartialContract.drain_attempted-and
      -not[bool]$TerminalPartialContract.drain_completed-and
      [string]$TerminalPartialContract.result-ceq
        'TIMEOUT_INCOMPLETE_SAME_FRAME'-and
      [bool]$TerminalPartialContract.no_read_exception-and
      [bool]$TerminalPartialContract.started_frame-and
      [bool]$TerminalPartialContract.header_known-and
      [bool]$TerminalPartialContract.raw_terminal_offset_valid-and
      [bool]$TerminalPartialContract.prefix_is_source_bound_r19f-and
      [bool]$TerminalPartialContract.role_matches_port-and
      [bool]$TerminalPartialContract.source_binding_verified-and
      [bool]$TerminalPartialContract.sequence_matches_next-and
      [bool]$TerminalPartialContract.expected_frame_available-and
      [bool]$TerminalPartialContract.byte_exact_expected_next_r19f_prefix-and
      [bool]$TerminalPartialContract.failure_snapshot_matches_previous){
    return [pscustomobject][ordered]@{
      classification='R19F_TERMINAL_PREFIX_STALL'
      status='FAIL_R19F_TERMINAL_PREFIX_STALL';result='FAIL'
      engineering_disposition='CAUSE_READ_R19F_TERMINAL_PREFIX_STALL'
      alive_role_coverage=$coverage;alive_roles=$aliveRoles
      armed_count=$armed.Count;alive_count=$alive.Count}
  }
  if($null-ne$R19AliveTerminalPartialContract-and
      [bool]$R19AliveTerminalPartialContract.valid-and
      [bool]$R19AliveTerminalPartialContract.fail_only-and
      -not[bool]$R19AliveTerminalPartialContract.reconstruction_performed-and
      -not[bool]$R19AliveTerminalPartialContract.missing_crc_verified){
    return [pscustomobject][ordered]@{
      classification='R19A_TERMINAL_PREFIX_STALL'
      status='FAIL_R19A_TERMINAL_PREFIX_STALL';result='FAIL'
      engineering_disposition='CAUSE_READ_R19A_TERMINAL_PREFIX_STALL'
      alive_role_coverage=$coverage;alive_roles=$aliveRoles
      armed_count=$armed.Count;alive_count=$alive.Count}
  }
  if($null-ne$R19FailureBoundaryPartialContract-and
      [bool]$R19FailureBoundaryPartialContract.valid-and
      [bool]$R19FailureBoundaryPartialContract.fail_only-and
      -not[bool]$R19FailureBoundaryPartialContract.reconstruction_performed-and
      -not[bool]$R19FailureBoundaryPartialContract.missing_prefix_received-and
      -not[bool]$R19FailureBoundaryPartialContract.missing_terminal_crc_verified){
    return [pscustomobject][ordered]@{
      classification='R19F_CAPTURE_BOUNDARY_PARTIAL'
      status='FAIL_R19F_CAPTURE_BOUNDARY_PARTIAL';result='FAIL'
      engineering_disposition='CAUSE_READ_R19F_CAPTURE_BOUNDARY_PARTIAL'
      alive_role_coverage=$coverage;alive_roles=$aliveRoles
      armed_count=$armed.Count;alive_count=$alive.Count}
  }
  if(-not$ParserClean){
    return [pscustomobject][ordered]@{classification='INVALID'
      status='FAIL_PARSER_CORRUPTION';result='FAIL'
      engineering_disposition='FAIL_PARSER_CORRUPTION'
      alive_role_coverage=$coverage;alive_roles=$aliveRoles
      armed_count=$armed.Count;alive_count=$alive.Count}
  }
  if($failures.Count-gt0){
    return [pscustomobject][ordered]@{classification='R19F'
      status='PASS_DIAGNOSTIC_CAPTURED';result='PASS'
      engineering_disposition='RUNTIME_FAILURE_OBSERVED'
      alive_role_coverage=$coverage;alive_roles=$aliveRoles
      armed_count=$armed.Count;alive_count=$alive.Count}
  }
  if($alive.Count-gt0-and$OtherCompleteFrameCount-gt0){
    return [pscustomobject][ordered]@{classification='ALIVE_WITH_PRODUCT_TRAFFIC'
      status='PASS_ALIVE_BEACON_CAPTURED';result='PASS'
      engineering_disposition=if($coverage-ceq'BOTH'){
        'ADVISORY_ALIVE_WITH_PRODUCT_TRAFFIC'}else{
        'PARTIAL_ALIVE_WITH_PRODUCT_TRAFFIC'}
      alive_role_coverage=$coverage;alive_roles=$aliveRoles
      armed_count=$armed.Count;alive_count=$alive.Count}
  }
  if($alive.Count-gt0){
    return [pscustomobject][ordered]@{classification='ALIVE_NO_TRAFFIC'
      status='PASS_ALIVE_BEACON_CAPTURED';result='PASS'
      engineering_disposition=if($coverage-ceq'BOTH'){
        'FAIL_ALIVE_NO_PRODUCT_TRAFFIC'}else{
        'PARTIAL_ALIVE_NO_PRODUCT_TRAFFIC'}
      alive_role_coverage=$coverage;alive_roles=$aliveRoles
      armed_count=$armed.Count;alive_count=$alive.Count}
  }
  [pscustomobject][ordered]@{classification='NO_BEACON'
    status='FAIL_NO_DIAGNOSTIC_BEACON';result='FAIL'
    engineering_disposition='EVIDENCE_REQUIRED_NO_BEACON'
    alive_role_coverage=$coverage;alive_roles=$aliveRoles
    armed_count=$armed.Count;alive_count=$alive.Count}
}

function New-OfflineProvenance([switch]$Mismatch) {
  [pscustomobject][ordered]@{
    runtime_fail_diagnostics_enabled=$true
    acceptance_eligible=$false;acceptance_authorized=$false
    deployment_authorized=$false
    roles=@([pscustomobject]@{role='vehicle';sha256=('C'*64)},
      [pscustomobject]@{role='ground';sha256=('D'*64)})
    source_bindings=@(
      [pscustomobject]@{role='vehicle';source_path=
          'package/vc_lora_vehicle_xiao_esp32s3/vc_lora_phase6_bridge.hpp'
        source_sha256=('A'*64);verified_source_sha256=('A'*64)
        source_verified=$true;application_sha256=('C'*64)},
      [pscustomobject]@{role='ground';source_path=
          'package/vc_lora_ground_xiao_esp32s3/vc_lora_phase6_bridge.hpp'
        source_sha256=('B'*64);verified_source_sha256=if($Mismatch){'E'*64}else{'B'*64}
        source_verified=$true;application_sha256=('D'*64)})
  }
}

function Resolve-RepoFile([string]$Path,[string]$Description) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($Path)) `
      "$Description path is empty."
  $candidate=if([IO.Path]::IsPathRooted($Path)){
    [IO.Path]::GetFullPath($Path)}else{
    [IO.Path]::GetFullPath((Join-Path $repo $Path.Replace('/','\')))}
  Assert-Condition ($candidate.StartsWith($repo+'\',
      [StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $candidate -PathType Leaf)) `
      "$Description escaped the repo or is missing."
  (Resolve-Path -LiteralPath $candidate).Path
}

function Resolve-RepoDirectory([string]$Path,[string]$Description) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($Path)) `
      "$Description path is empty."
  $candidate=if([IO.Path]::IsPathRooted($Path)){
    [IO.Path]::GetFullPath($Path)}else{
    [IO.Path]::GetFullPath((Join-Path $repo $Path.Replace('/','\')))}
  Assert-Condition ($candidate.StartsWith($repo+'\',
      [StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $candidate -PathType Container)) `
      "$Description escaped the repo or is missing."
  (Resolve-Path -LiteralPath $candidate).Path.TrimEnd('\')
}

function Resolve-WithinDirectory([string]$Root,[string]$RelativePath,
                                 [string]$Description) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($RelativePath) -and
      -not [IO.Path]::IsPathRooted($RelativePath)) `
      "$Description must be a non-empty relative path."
  $rootFull=(Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path.TrimEnd('\')
  $candidate=[IO.Path]::GetFullPath((Join-Path $rootFull `
      $RelativePath.Replace('/','\')))
  Assert-Condition ($candidate.StartsWith($rootFull+'\',
      [StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $candidate -PathType Leaf)) `
      "$Description escaped the candidate root or is missing."
  (Resolve-Path -LiteralPath $candidate).Path
}

function Assert-HashSidecar([string]$SidecarPath,[string]$TargetPath,
                            [string]$TargetName,[string]$Description) {
  $resolved=Resolve-RepoFile $SidecarPath $Description
  $expected=(Get-Sha $TargetPath)+' *'+$TargetName
  $actual=(Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop).Trim()
  Assert-Condition ($actual-ceq$expected) "$Description content mismatch."
  return $resolved
}

function Assert-DiagnosticEnabledRecord([object]$Record,[string]$Name) {
  Assert-Condition ($null-ne$Record -and
      $Record.PSObject.Properties['runtime_fail_diagnostics_enabled'] -and
      $Record.runtime_fail_diagnostics_enabled-is[bool] -and
      [bool]$Record.runtime_fail_diagnostics_enabled -and
      $Record.PSObject.Properties['acceptance_eligible'] -and
      $Record.acceptance_eligible-is[bool] -and
      -not [bool]$Record.acceptance_eligible -and
      $Record.PSObject.Properties['acceptance_authorized'] -and
      $Record.acceptance_authorized-is[bool] -and
      -not [bool]$Record.acceptance_authorized -and
      $Record.PSObject.Properties['deployment_authorized'] -and
      $Record.deployment_authorized-is[bool] -and
      -not [bool]$Record.deployment_authorized) `
      ("$Name must set diagnostics=true, acceptance_eligible=false, " +
       'acceptance_authorized=false, deployment_authorized=false.')
}

function Assert-DiagnosticFlashAuthorization([object]$Record) {
  Assert-Condition ($null-ne$Record -and
      [string]$Record.status-ceq$DiagnosticFlashStatus -and
      $Record.one_run_hil_authorized-is[bool] -and
      [bool]$Record.one_run_hil_authorized -and
      [string]$Record.authorization.scope-ceq$DiagnosticAuthorizationScope -and
      $Record.authorization.reusable-is[bool] -and
        -not[bool]$Record.authorization.reusable -and
      $Record.authorization.deployment_authorization-is[bool] -and
        -not[bool]$Record.authorization.deployment_authorization -and
      [string]$Record.authorization.attestation_sha256-ceq
        (Get-ByteSha $utf8.GetBytes($DiagnosticAuthorizationToken)) -and
      [string]$Record.next_required_action-ceq$DiagnosticNextAction) `
      'Diagnostic flash status/scope/token/next action mismatch.'
}

function Get-CandidateProvenance([string]$HandoffPath,[string]$FlashPath,
                                [string]$ExpectedCandidateBase='') {
  $handoffResolved=Resolve-RepoFile $HandoffPath 'CandidateHandoffPath'
  $candidateRoot=(Split-Path -Parent $handoffResolved).TrimEnd('\')
  $candidateBase=(Split-Path -Parent $candidateRoot).TrimEnd('\')
  if([string]::IsNullOrWhiteSpace($ExpectedCandidateBase)){
    $ExpectedCandidateBase=Join-Path $repo `
        'runs\candidates\R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001'
  }
  $expectedCandidateBase=[IO.Path]::GetFullPath($ExpectedCandidateBase).TrimEnd('\')
  Assert-Condition ($expectedCandidateBase.StartsWith($repo+'\',
      [StringComparison]::OrdinalIgnoreCase)) `
      'Expected diagnostic candidate base escaped the repository.'
  Assert-Condition ($candidateBase-ceq$expectedCandidateBase) `
      'Candidate handoff is outside the diagnostic candidate base.'
  $latestPath=Resolve-RepoFile (Join-Path $candidateBase 'latest.json') `
      'diagnostic candidate latest pointer'
  $latestSidecar=Assert-HashSidecar `
      (Join-Path $candidateBase 'latest.sha256') $latestPath 'latest.json' `
      'diagnostic candidate latest sidecar'
  $latest=Get-Content -LiteralPath $latestPath -Raw|ConvertFrom-Json
  Assert-Condition ([string]$latest.schema-ceq
      'vc-lora-r19-candidate-artifact-latest-v1' -and
      [string]$latest.result-ceq'PASS') `
      'Diagnostic candidate latest pointer is not PASS.'
  Assert-DiagnosticEnabledRecord $latest 'diagnostic candidate latest pointer'
  Assert-Condition ((Resolve-RepoFile ([string]$latest.handoff.path) `
        'latest handoff')-ceq$handoffResolved -and
      [string]$latest.handoff.sha256-ceq(Get-Sha $handoffResolved)) `
      'Diagnostic latest pointer does not bind the selected handoff.'
  $handoff=Get-Content -LiteralPath $handoffResolved -Raw|ConvertFrom-Json
  Assert-Condition ([string]$handoff.schema-ceq
      'vc-lora-r19-candidate-artifact-handoff-v1' -and
      [string]$handoff.result-ceq'PASS') 'Candidate handoff is not PASS.'
  Assert-DiagnosticEnabledRecord $handoff 'candidate handoff'
  $declaredLatestRoot=Resolve-RepoDirectory ([string]$latest.artifact_root) `
      'latest artifact root'
  $declaredHandoffRoot=Resolve-RepoDirectory ([string]$handoff.artifact_root) `
      'handoff artifact root'
  Assert-Condition ($declaredLatestRoot-ceq$candidateRoot -and
      $declaredHandoffRoot-ceq$candidateRoot -and
      [string]$latest.artifact_id-ceq[string]$handoff.artifact_id) `
      'Latest/handoff candidate identity or artifact root mismatch.'
  $resolved=Resolve-RepoFile ([string]$handoff.candidate_manifest.path) `
      'candidate manifest'
  Assert-Condition ((Get-Sha $resolved)-ceq
      [string]$handoff.candidate_manifest.sha256) `
      'Handoff candidate manifest hash mismatch.'
  $manifest=Get-Content -LiteralPath $resolved -Raw|ConvertFrom-Json
  Assert-Condition ([string]$manifest.schema-ceq
      'vc-lora-r19-candidate-artifact-manifest-v1' -and
      [string]$manifest.result-ceq'PASS') 'Candidate manifest is not PASS.'
  Assert-DiagnosticEnabledRecord $manifest 'candidate manifest'
  $declaredManifestRoot=Resolve-RepoDirectory ([string]$manifest.artifact_root) `
      'manifest artifact root'
  Assert-Condition ($declaredManifestRoot-ceq$candidateRoot -and
      [string]$manifest.artifact_id-ceq[string]$handoff.artifact_id -and
      (Resolve-RepoFile ([string]$latest.candidate_manifest.path) `
        'latest candidate manifest')-ceq$resolved -and
      [string]$latest.candidate_manifest.sha256-ceq(Get-Sha $resolved)) `
      'Latest/manifest candidate identity, root, path, or hash mismatch.'
  $candidateSealPath=Resolve-RepoFile ([string]$handoff.final_seal.path) `
      'candidate final seal'
  Assert-Condition ((Get-Sha $candidateSealPath)-ceq
      [string]$handoff.final_seal.sha256) 'Candidate final seal hash mismatch.'
  $candidateSeal=Get-Content $candidateSealPath -Raw|ConvertFrom-Json
  Assert-Condition ([string]$candidateSeal.schema-ceq
      'vc-lora-r19-candidate-final-seal-v1' -and
      [string]$candidateSeal.result-ceq'PASS' -and
      [string]$candidateSeal.candidate_manifest_sha256-ceq(Get-Sha $resolved)) `
      'Candidate final seal does not bind the manifest.'
  Assert-DiagnosticEnabledRecord $candidateSeal 'candidate final seal'
  Assert-Condition ([string]$candidateSeal.artifact_id-ceq
        [string]$handoff.artifact_id -and
      (Resolve-RepoFile ([string]$latest.final_seal.path) `
        'latest candidate final seal')-ceq$candidateSealPath -and
      [string]$latest.final_seal.sha256-ceq(Get-Sha $candidateSealPath)) `
      'Latest/candidate final seal identity, path, or hash mismatch.'
  $candidateSealSidecar=Assert-HashSidecar `
      (Join-Path $candidateRoot 'final_seal.sha256') $candidateSealPath `
      'final_seal.json' 'candidate final seal sidecar'
  $handoffSidecar=Assert-HashSidecar (Join-Path $candidateRoot 'handoff.sha256') `
      $handoffResolved 'handoff.json' 'candidate handoff sidecar'
  $root=$candidateRoot
  $roles=[Collections.ArrayList]::new();$bindings=[Collections.ArrayList]::new()
  foreach($role in @('vehicle','ground')){
    $roleRows=@($manifest.roles|Where-Object {$_.role -ceq $role})
    Assert-Condition ($roleRows.Count-eq1) "$role application is not unique."
    $app=$roleRows[0].application
    $appPath=Resolve-WithinDirectory $root ([string]$app.path) `
        "$role application"
    Assert-Condition ((Get-Sha $appPath)-ceq[string]$app.sha256) `
        "$role application hash mismatch."
    [void]$roles.Add([pscustomobject]@{role=$role;sha256=[string]$app.sha256})
    $relative=('package/vc_lora_{0}_xiao_esp32s3/' +
        'vc_lora_phase6_bridge.hpp')-f$role
    $sourceRows=@($manifest.staged_package_snapshot.files|Where-Object{
      $_.path -ceq $relative})
    Assert-Condition ($sourceRows.Count-eq1) "$role source is not unique."
    $source=$sourceRows[0]
    $sourcePath=Resolve-WithinDirectory $root $relative "$role bridge source"
    $sourceSha=Get-Sha $sourcePath
    Assert-Condition ($sourceSha-ceq[string]$source.sha256) `
        "$role bridge source hash mismatch."
    [void]$bindings.Add([pscustomobject]@{role=$role;source_path=$relative
      source_sha256=$sourceSha;verified_source_sha256=$sourceSha
      source_verified=$true;application_sha256=[string]$app.sha256})
  }
  $flashResolved=Resolve-RepoFile $FlashPath 'CandidateFlashEvidencePath'
  $flash=Get-Content $flashResolved -Raw|ConvertFrom-Json
  Assert-Condition ([string]$flash.schema-ceq
      'vc-lora-r19-candidate-flash-evidence-v1' -and
      [string]$flash.result-ceq'PASS' -and
      [string]$flash.status-ceq$DiagnosticFlashStatus) `
      'Candidate diagnostic flash evidence status is not exact.'
  Assert-DiagnosticEnabledRecord $flash 'candidate flash evidence'
  Assert-DiagnosticFlashAuthorization $flash
  Assert-Condition ([string]$flash.candidate.latest_sha256-ceq
        (Get-Sha $latestPath) -and
      [string]$flash.candidate.handoff_sha256-ceq
        (Get-Sha $handoffResolved) -and
      [string]$flash.candidate.candidate_manifest_sha256-ceq
        (Get-Sha $resolved) -and
      [string]$flash.candidate.candidate_final_seal_sha256-ceq
        (Get-Sha $candidateSealPath)) `
      'Flash evidence is not bound to latest/handoff/manifest/final seal.'
  $flashRoles=@($flash.roles)
  Assert-Condition ($flashRoles.Count-eq2) 'Flash evidence role count mismatch.'
  foreach($roleIndex in 0..1){
    $expectedRole=@('vehicle','ground')[$roleIndex]
    $expectedPort=@('COM3','COM6')[$roleIndex]
    $expectedApp=@($roles|Where-Object{$_.role-ceq$expectedRole})[0]
    $actual=$flashRoles[$roleIndex]
    Assert-Condition ([string]$actual.role-ceq$expectedRole -and
        [string]$actual.port-ceq$expectedPort -and
        [string]$actual.sha256-ceq[string]$expectedApp.sha256 -and
        $actual.write_pass-is[bool] -and [bool]$actual.write_pass -and
        $actual.verify_pass-is[bool] -and [bool]$actual.verify_pass -and
        $actual.reenumeration_pass-is[bool] -and
          [bool]$actual.reenumeration_pass) `
        "$expectedRole flash/read-back binding failed."
  }
  $flashSealPath=Join-Path (Split-Path -Parent $flashResolved) 'final_seal.json'
  $flashSeal=Get-Content $flashSealPath -Raw|ConvertFrom-Json
  Assert-Condition ([string]$flashSeal.schema-ceq
      'vc-lora-r19-candidate-flash-final-seal-v1' -and
      [string]$flashSeal.result-ceq'PASS' -and
      [string]$flashSeal.status-ceq$DiagnosticFlashStatus -and
      [string]$flashSeal.flash_record_sha256-ceq(Get-Sha $flashResolved) -and
      [string]$flashSeal.final_seal_sha256-ceq(Get-Sha $candidateSealPath) -and
      $flashSeal.one_run_hil_authorized-is[bool] -and
        [bool]$flashSeal.one_run_hil_authorized -and
      [string]$flashSeal.authorization_scope-ceq$DiagnosticAuthorizationScope -and
      [string]$flashSeal.hil_authorization_token-ceq
        $DiagnosticAuthorizationToken -and
      [string]$flashSeal.next_required_action-ceq$DiagnosticNextAction) `
      'Flash final seal does not bind read-back evidence.'
  Assert-DiagnosticEnabledRecord $flashSeal 'flash final seal'
  $flashSealSidecar=Assert-HashSidecar `
      (Join-Path (Split-Path -Parent $flashResolved) 'final_seal.sha256') `
      $flashSealPath 'final_seal.json' 'flash final seal sidecar'
  [void](Copy-PinnedInput $latestPath 'candidate.latest.json')
  [void](Copy-PinnedInput $latestSidecar 'candidate.latest.sha256')
  [void](Copy-PinnedInput $handoffResolved 'candidate.handoff.json')
  [void](Copy-PinnedInput $handoffSidecar 'candidate.handoff.sha256')
  [void](Copy-PinnedInput $resolved 'candidate.manifest.json')
  [void](Copy-PinnedInput $candidateSealPath 'candidate.final_seal.json')
  [void](Copy-PinnedInput $candidateSealSidecar 'candidate.final_seal.sha256')
  [void](Copy-PinnedInput $flashResolved 'flash.record.json')
  [void](Copy-PinnedInput $flashSealPath 'flash.final_seal.json')
  [void](Copy-PinnedInput $flashSealSidecar 'flash.final_seal.sha256')
  $definitionSource=Resolve-RepoFile 'core/src/mavlink_frame.cpp' `
      'pinned MAVLink definition source'
  $definitionRecord=Copy-PinnedInput $definitionSource `
      'core.mavlink_frame.cpp'
  $script:Definitions=Get-MavlinkDefinitions ([string]$definitionRecord.staged)
  Assert-Condition ((Get-Sha $latestPath)-ceq[string]$script:PinnedInputs[0].sha256 -and
      (Get-Sha $handoffResolved)-ceq[string]$latest.handoff.sha256 -and
      (Get-Sha $resolved)-ceq[string]$latest.candidate_manifest.sha256 -and
      (Get-Sha $candidateSealPath)-ceq[string]$latest.final_seal.sha256 -and
      (Get-Sha $flashResolved)-ceq[string]$flashSeal.flash_record_sha256) `
      'A diagnostic provenance input changed while it was being pinned.'
  [pscustomobject][ordered]@{
    runtime_fail_diagnostics_enabled=$true;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$false
    latest_path=$latestPath;latest_sha256=Get-Sha $latestPath
    manifest_path=$resolved
    manifest_sha256=Get-Sha $resolved;handoff_path=$handoffResolved
    handoff_sha256=Get-Sha $handoffResolved
    candidate_final_seal_sha256=Get-Sha $candidateSealPath
    flash_record_path=$flashResolved;flash_record_sha256=Get-Sha $flashResolved
    flash_final_seal_sha256=Get-Sha $flashSealPath
    mavlink_definition_sha256=[string]$definitionRecord.sha256
    diagnostic_flash_status=$DiagnosticFlashStatus
    diagnostic_authorization_scope=$DiagnosticAuthorizationScope
    diagnostic_next_required_action=$DiagnosticNextAction
    flash_readback_verified=$true;roles=@($roles);source_bindings=@($bindings)
    pinned_inputs=@($script:PinnedInputs)
  }
}

function Assert-ExactPortIdentity([object]$Spec,[string]$Checkpoint) {
  $script:ExternalActions.cim_queried=$true
  $rows=@(Get-CimInstance Win32_SerialPort -ErrorAction Stop|Where-Object{
    [string]$_.DeviceID -ceq [string]$Spec.port})
  Assert-Condition ($rows.Count-eq1) "$($Spec.port) identity count is not one."
  Assert-Condition ([string]::Equals([string]$rows[0].PNPDeviceID,
      [string]$Spec.pnp,[StringComparison]::OrdinalIgnoreCase)) `
      "$($Spec.port) PNP mismatch at $Checkpoint."
  $script:ExternalActions.pnp_queried=$true
  $parent=Get-PnpDeviceProperty -InstanceId ([string]$rows[0].PNPDeviceID) `
      -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop
  Assert-Condition ([string]::Equals([string]$parent.Data,[string]$Spec.parent,
      [StringComparison]::OrdinalIgnoreCase)) `
      "$($Spec.port) parent mismatch at $Checkpoint."
  [void]$script:ExternalActions.port_identity_evidence.Add(
      [pscustomobject][ordered]@{role=[string]$Spec.role
        port=[string]$Spec.port;checkpoint=$Checkpoint
        pnp=[string]$rows[0].PNPDeviceID;parent=[string]$parent.Data
        result='PASS'})
}

function New-DiagnosticSerialPort([object]$Spec) {
  $serial=[IO.Ports.SerialPort]::new([string]$Spec.port,[int]$Spec.baud,
      [IO.Ports.Parity]::None,
      8,[IO.Ports.StopBits]::One)
  $serial.DtrEnable = $false
  $serial.RtsEnable = $false
  $serial.Handshake=[IO.Ports.Handshake]::None
  $serial.ReadTimeout=20;$serial.WriteTimeout=20
  $serial.ReadBufferSize=1048576
  return $serial
}

function Open-DiagnosticSerialPort([object]$Serial,[object]$Evidence,
    [scriptblock]$UtcNow=$null,[object]$LifecycleTrace=$null,[string]$Role='',
    [object]$StartupReader=$null) {
  [DateTime]$before=if($null-ne$UtcNow){[DateTime](& $UtcNow)}else{
    [DateTime]::UtcNow}
  $before=$before.ToUniversalTime()
  $Evidence.serial_port_open_before_utc=$before.ToString('o')
  if($null-ne$LifecycleTrace){Add-R19PcLifecycleEvent $LifecycleTrace 1 $Role}
  try{
    [void]$Serial.Open()
  }catch{
    if($null-ne$LifecycleTrace){Add-R19PcLifecycleEvent $LifecycleTrace 3 $Role}
    $Evidence.result='FAIL'
    $Evidence.failure=$_.Exception.Message
    throw
  }
  [long]$openReturnTicks=if($null-ne$LifecycleTrace){$LifecycleTrace.clock.ElapsedTicks}else{-1}
  if($null-ne$StartupReader){
    # Signal before PnP, decoding, timestamp formatting, or the next Open.
    $StartupReader.Arm($openReturnTicks)
  }
  if($null-ne$LifecycleTrace){Add-R19PcLifecycleEvent $LifecycleTrace 2 $Role 0 0 0 $openReturnTicks}
  [DateTime]$after=if($null-ne$UtcNow){[DateTime](& $UtcNow)}else{
    [DateTime]::UtcNow}
  $after=$after.ToUniversalTime()
  $Evidence.serial_port_open_after_utc=$after.ToString('o')
  $Evidence.serial_port_open_duration_ms=
      [Math]::Round(($after-$before).TotalMilliseconds,3)
  $Evidence.result='PASS'
}

function Initialize-R19StartupReader {
  $helper=Copy-PinnedInput (Join-Path $repo 'tools/r19_startup_reader.cs') `
      'r19_startup_reader.cs'
  $script:StartupReaderSource=$helper
  Assert-Condition ($null-eq('VcLora.R19.StartupReader'-as[type])) `
      'Startup reader type already loaded; use a fresh isolated runner process.'
  [byte[]]$bytes=[IO.File]::ReadAllBytes($helper.staged)
  Assert-Condition ((Get-ByteSha $bytes)-ceq$helper.sha256-and
      $helper.sha256-ceq$ExpectedStartupReaderSha256) `
      'Startup reader source changed after pinning.'
  $continuous=Copy-PinnedInput (Join-Path $repo 'tools/r19_continuous_reader.cs') `
      'r19_continuous_reader.cs'
  [byte[]]$continuousBytes=[IO.File]::ReadAllBytes($continuous.staged)
  Assert-Condition ((Get-ByteSha $continuousBytes)-ceq$continuous.sha256-and
      $continuous.sha256-ceq$ExpectedContinuousReaderSha256) `
      'Continuous reader source changed after pinning.'
  $script:ContinuousReaderSource=$continuous
  Add-Type -TypeDefinition (([Text.Encoding]::UTF8.GetString($bytes))+
      [Environment]::NewLine+([Text.Encoding]::UTF8.GetString($continuousBytes)))
}

function Start-R19ContinuousCapture([object[]]$States,[object]$Trace) {
  foreach($state in $States){
    $source=[VcLora.R19.SerialStartupSource]::new($state.serial)
    $reader=[VcLora.R19.ContinuousReader]::new($source,$Trace.clock,1048576,4096)
    $state|Add-Member NoteProperty continuous_reader $reader -Force
    $state|Add-Member NoteProperty continuous_evidence $null -Force
    $state|Add-Member NoteProperty continuous_raw $null -Force
    $state.read_state|Add-Member NoteProperty continuous_reader $reader -Force
    $state.read_state|Add-Member NoteProperty identity_verified $false -Force
    $state.read_state|Add-Member NoteProperty first_service_us ([long]-1) -Force
    $state.read_state|Add-Member NoteProperty maximum_gap_begin_us ([long]-1) -Force
    $state.read_state|Add-Member NoteProperty maximum_gap_end_us ([long]-1) -Force
  }
  foreach($state in $States){
    Assert-Condition ($state.continuous_reader.WaitReady(1000)) `
        ('Continuous reader preparation timeout: '+$state.spec.role)
    # Warm source-independent status/delivery paths without opening/reading COM.
    [void]$state.continuous_reader.GetStatus()
    [void]$state.continuous_reader.PollBytes(1)
    [void]$state.continuous_reader.GetSnapshot()
  }
}

function Confirm-R19ContinuousIdentity([object[]]$States) {
  Assert-Condition (@($States|Where-Object{-not$_.startup_identity_verified}).Count-eq0) `
      'Quarantined bytes cannot be parsed before both post-open identities pass.'
  foreach($state in $States){
    # Observation only: do not Stop/Join/Close or hand physical Read to PowerShell.
    $phase=$state.continuous_reader.MarkPhase('IDENTITY_VERIFIED')
    $state.read_state.identity_verified=$true
    $state.last=[long][math]::Floor($phase.Ticks*1000000.0/[Diagnostics.Stopwatch]::Frequency)
    [void]$state.continuous_reader.MarkPhase('LIVE')
  }
}

function Read-R19ContinuousBytes([object]$ReadState,[object]$Parser,
    [IO.MemoryStream]$Raw,[Diagnostics.Stopwatch]$Clock,[int]$Budget,
    [ValidateSet('AUTO','TERMINAL_TAIL')][string]$Origin='AUTO') {
  Assert-Condition $ReadState.identity_verified 'Continuous bytes remain identity-quarantined.'
  $reader=$ReadState.continuous_reader;$status=$reader.GetStatus()
  Assert-Condition ([string]::IsNullOrEmpty($status.Failure)-and-not$status.Stopped) `
      ('Continuous reader failed or stopped: '+$status.Failure)
  if($status.InitialBytes-ge0-and$ReadState.initial_drain_bytes-lt0){
    $ReadState.initial_drain_bytes=[long]$status.InitialBytes
    $ReadState.initial_drain_remaining=[long]$status.InitialBytes
  }
  [int]$total=0
  foreach($block in $reader.PollBytes($Budget)){
    Assert-Condition ($block.Offset-eq$Raw.Length-and$block.Data.Length-eq$block.Count) `
        'Continuous parser/raw delivery lost exact prefix accounting.'
    $ReadState.read_batch_id=[long]$block.Batch
    [int]$offset=0
    while($offset-lt$block.Count){
      [bool]$initial=$offset-lt$block.InitialByteCount
      [int]$count=if($initial){$block.InitialByteCount-$offset}else{$block.Count-$offset}
      [byte[]]$part=New-Object byte[] $count
      [Array]::Copy($block.Data,$offset,$part,0,$count)
      $Raw.Write($part,0,$part.Length)
      if($initial){$ReadState.initial_drain_remaining-=$count}
      [long]$nativeUs=[long][math]::Floor($block.EndTicks*1000000.0/[Diagnostics.Stopwatch]::Frequency)
      $captureOrigin=if($Origin-ceq'TERMINAL_TAIL'){'TERMINAL_TAIL'}elseif($initial){'STARTUP_DRAIN'}else{'LIVE'}
      $trace=$ReadState.lifecycle_trace
      # Native arrival observation and application parser observation are distinct.
      Add-DiagnosticBytes $Parser $part $nativeUs ([long]$block.Batch) $captureOrigin `
          $trace $trace.clock.ElapsedTicks
      $offset+=$count;$total+=$count
    }
  }
  return $total
}

function Stop-R19ContinuousCapture([object]$State) {
  if($null-ne$State.continuous_evidence-and$State.continuous_evidence.stopped){return}
  $reader=$State.continuous_reader
  $joined=$reader.Stop(500)
  if(-not$joined){
    $State.startup_close_required=$true
    $joined=$reader.CloseAndStop(1000)
  }
  # Even an unjoinable reader supports a consistent published-prefix snapshot.
  # Preserve it before reporting cleanup failure; never lose the primary evidence.
  $s=$reader.GetSnapshot();[byte[]]$bytes=$reader.ReadSlice(0,$s.ByteCount)
  $State.continuous_raw=$bytes;$State.startup_snapshot=$s
  $frequency=[double][Diagnostics.Stopwatch]::Frequency
  $firstUs=if($s.FirstReadBeginTicks-ge0){($s.FirstReadBeginTicks-$s.OpenReturnTicks)*1000000.0/$frequency}else{-1.0}
  $gapUs=$s.MaximumServiceGapTicks*1000000.0/$frequency
  [byte[]]$parsed=$State.raw.ToArray()
  $prefixExact=Test-ExactBytePrefix $parsed $bytes
  $unparsed=$bytes.Length-$parsed.Length
  $State.continuous_evidence=[pscustomobject][ordered]@{
    schema='vc-lora-r19-continuous-reader-v1';role=[string]$State.spec.role
    clock_domain_id=[string]$State.lifecycle_trace.clock_domain_id
    frequency=[string][Diagnostics.Stopwatch]::Frequency
    armed=$s.Armed;stopped=$s.Stopped;closed_by_reader=$s.Closed
    identity_verified=[bool]$State.startup_identity_verified
    raw_bytes=$s.ByteCount;raw_sha256=Get-ByteSha $bytes
    native_raw_path=([string]$State.spec.role+'.continuous.raw.bin')
    parser_bytes=$parsed.Length;parser_prefix_exact=$prefixExact
    consumed_bytes=$s.ConsumedByteCount;unparsed_bytes=$unparsed
    unparsed_suffix_accepted=$false;overflow=$s.Overflow
    initial_drain_bytes=$s.InitialBytes
    open_return_ticks=[string]$s.OpenReturnTicks;arm_ticks=[string]$s.ArmTicks
    first_read_begin_ticks=[string]$s.FirstReadBeginTicks;first_read_end_ticks=[string]$s.FirstReadEndTicks
    first_read_requested_count=$s.FirstReadRequestedCount
    last_read_begin_ticks=[string]$s.LastReadBeginTicks;last_read_end_ticks=[string]$s.LastReadEndTicks
    maximum_gap_begin_ticks=[string]$s.MaximumGapStartTicks
    maximum_gap_end_ticks=[string]$s.MaximumGapEndTicks
    open_to_first_read_us=$firstUs;maximum_service_gap_us=$gapUs
    maximum_read_duration_us=$s.MaximumReadDurationTicks*1000000.0/$frequency
    read_calls=$s.Calls;timeouts=$s.Timeouts;zero_reads=$s.ZeroReads
    read_errors=$s.ReadErrors;cleanup_read_interruptions=$s.CleanupReadInterruptions
    close_required=[bool]$State.startup_close_required;failure=[string]$s.Failure
    cleanup_failure=[string]$s.CleanupFailure;blocks=@($s.Blocks);phases=@($s.Phases)
    replayed=[bool]$State.read_state.identity_verified
    valid=($s.Armed-and$s.Stopped-and$firstUs-ge0-and$firstUs-le$PumpServiceLimitUs-and
      $gapUs-le$PumpServiceLimitUs-and
      ($s.MaximumReadDurationTicks*1000000.0/$frequency)-le$PumpServiceLimitUs-and
      -not$State.startup_close_required-and
      [string]::IsNullOrEmpty($s.Failure)-and[string]::IsNullOrEmpty($s.CleanupFailure)-and
      $State.startup_identity_verified-and$prefixExact-and$unparsed-eq0-and
      $s.ConsumedByteCount-eq$parsed.Length)
    limitations=@('Application Read is not proof of kernel-pending requests or physical host polling.',
      'Continuous native Read and parser-pump fairness are evaluated independently.',
      'Unparsed raw suffixes are preserved but never accepted as communication success.',
      'Read timestamps cannot correlate MCU time without a bounded nonce exchange.')
  }
  # Compatibility field name; the schema explicitly distinguishes lifetime owner.
  $State.startup_evidence=$State.continuous_evidence
  Assert-Condition $joined ('Continuous reader did not terminate: '+$State.spec.role)
}

function Start-R19StartupCapture([object[]]$States,[object]$Trace) {
  # Construct and warm both threads before either real Open. No COM access.
  foreach($state in $States){
    $source=[VcLora.R19.SerialStartupSource]::new($state.serial)
    $state.startup_reader=[VcLora.R19.StartupReader]::new(
        $source,$Trace.clock,1048576,4096)
  }
  foreach($state in $States){
    Assert-Condition ($state.startup_reader.WaitReady(1000)) `
        ('Startup reader preparation timeout: '+$state.spec.role)
  }
  # Exercise the existing parser, read wrapper, CRC and decoder on private
  # memory-only fixtures. No fixture enters real raw/frame/lifecycle evidence.
  foreach($state in $States){
    $parser=New-DiagnosticParser ([string]$state.spec.role)
    $raw=[IO.MemoryStream]::new();$serial=New-OfflineBufferedSerial (
        New-SyntheticFrame ([string]$state.spec.code) 0)
    $last=[long]-1;$gap=[long]0
    try{
      Read-DiagnosticSerial $serial $parser $raw $Trace.clock `
          ([ref]$last) ([ref]$gap)
      [void](Convert-R19Diagnostic $parser.frames[0] $state.spec.code `
          (New-OfflineProvenance))
      [void](Get-DiagnosticFrameLeaf $state.spec.role 1)
    }finally{$raw.Dispose()}
  }
}

function Stop-R19StartupCapture([object]$State,[bool]$Cleanup=$false) {
  if($null-eq$State.startup_reader){return}
  if($null-ne$State.startup_snapshot){
    if(-not$Cleanup){
      Assert-Condition (-not$State.startup_close_required-and
          [string]::IsNullOrEmpty($State.startup_snapshot.Failure)) `
          ('Startup reader cannot hand over: '+$State.spec.role+' '+$State.startup_snapshot.Failure)
    }
    return
  }
  $joined=$State.startup_reader.Stop(500)
  if(-not$joined){
    # Closing is an exceptional unblock only, never a successful handover.
    try{$State.serial.Close()}catch{}
    $joined=$State.startup_reader.Stop(1000)
    $State.startup_close_required=$true
  }
  Assert-Condition $joined ('Startup reader did not terminate: '+$State.spec.role)
  $snapshot=$State.startup_reader.GetSnapshot()
  $State.startup_snapshot=$snapshot
  [byte[]]$bytes=$State.startup_reader.GetBytes()
  # Copy once even if identity verification or replay subsequently fails.
  $State.raw.Write($bytes,0,$bytes.Length)
  $frequency=[double][Diagnostics.Stopwatch]::Frequency
  $firstUs=if($snapshot.FirstReadBeginTicks-ge0){
    ($snapshot.FirstReadBeginTicks-$snapshot.OpenReturnTicks)*1000000.0/$frequency
  }else{-1.0}
  $gapUs=$snapshot.MaximumServiceGapTicks*1000000.0/$frequency
  $State.startup_evidence=[pscustomobject][ordered]@{
    schema='vc-lora-r19-startup-reader-v1';role=[string]$State.spec.role
    clock_domain_id=[string]$State.lifecycle_trace.clock_domain_id
    frequency=[string][Diagnostics.Stopwatch]::Frequency
    armed=$snapshot.Armed;stopped=$snapshot.Stopped
    identity_verified=[bool]$State.startup_identity_verified
    raw_bytes=$snapshot.ByteCount;raw_sha256=Get-ByteSha $bytes
    initial_drain_bytes=$snapshot.InitialBytes
    open_return_ticks=[string]$snapshot.OpenReturnTicks
    arm_ticks=[string]$snapshot.ArmTicks
    first_read_begin_ticks=[string]$snapshot.FirstReadBeginTicks
    first_read_end_ticks=[string]$snapshot.FirstReadEndTicks
    first_read_requested_count=$snapshot.FirstReadRequestedCount
    last_read_begin_ticks=[string]$snapshot.LastReadBeginTicks
    last_read_end_ticks=[string]$snapshot.LastReadEndTicks
    open_to_first_read_us=$firstUs;maximum_service_gap_us=$gapUs
    read_calls=$snapshot.Calls;timeouts=$snapshot.Timeouts;zero_reads=$snapshot.ZeroReads
    close_required=[bool]$State.startup_close_required;failure=[string]$snapshot.Failure
    blocks=@($snapshot.Blocks);replayed=$false
    valid=($snapshot.Armed-and$snapshot.Stopped-and$firstUs-ge0-and
        $firstUs-le$PumpServiceLimitUs-and$gapUs-le$PumpServiceLimitUs-and
        -not$State.startup_close_required-and[string]::IsNullOrEmpty($snapshot.Failure))
    limitations=@('Read begin is the PC application call boundary, not a physical USB transaction.','Startup raw is quarantined until both post-open identities pass.','PC QPC alone does not correlate the MCU clock.','The startup interval is additional to the 40-second measurement window.')
  }
  if(-not$Cleanup){
    Assert-Condition (-not$State.startup_close_required-and
        [string]::IsNullOrEmpty($snapshot.Failure)) `
        ('Startup reader cannot hand over: '+$State.spec.role+' '+$snapshot.Failure)
  }
}

function Receive-R19StartupCapture([object[]]$States) {
  Assert-Condition (@($States|Where-Object{-not$_.startup_identity_verified}).Count-eq0) `
      'Quarantined bytes cannot be parsed before both post-open identities pass.'
  foreach($state in $States){Stop-R19StartupCapture $state}
  # The exclusive native Read owners have ALL joined. Preserve physical read
  # batches/timestamps and the original initial-byte watermark on replay.
  foreach($state in $States){
    $snapshot=$state.startup_snapshot
    [byte[]]$raw=$state.startup_reader.GetBytes()
    $state.read_state.initial_drain_bytes=[long]$snapshot.InitialBytes
    $state.read_state.initial_drain_remaining=[math]::Max(0,
        [long]$snapshot.InitialBytes-$raw.Length)
    foreach($block in $snapshot.Blocks){
      $state.read_state.read_batch_id=[long]$block.Batch
      [int]$offset=$block.Offset;[int]$remaining=$block.Count
      while($remaining-gt0){
        $startup=$offset-lt$snapshot.InitialBytes
        [int]$count=if($startup){[math]::Min($remaining,$snapshot.InitialBytes-$offset)}else{$remaining}
        [byte[]]$part=New-Object byte[] $count
        [Array]::Copy($raw,$offset,$part,0,$count)
        $us=[long][math]::Floor($block.EndTicks*1000000.0/[Diagnostics.Stopwatch]::Frequency)
        Add-DiagnosticBytes $state.parser $part $us $state.read_state.read_batch_id `
            $(if($startup){'STARTUP_DRAIN'}else{'LIVE'})
        $offset+=$count;$remaining-=$count
      }
    }
    # The first main pump service includes the handover/replay scheduling gap.
    $state.last=[long][math]::Floor($snapshot.LastReadBeginTicks*1000000.0/
        [Diagnostics.Stopwatch]::Frequency)
    $state.read_state.read_batch_id=[long]$snapshot.Calls
    $state.startup_evidence.replayed=$true
  }
}

function Get-R19MeasurementWindowEvidence([object[]]$States,[long]$StartUs,
    [long]$EndUs=[long]::MaxValue) {
  Assert-Condition ($StartUs-ge0-and$EndUs-gt$StartUs) 'Invalid measurement window.'
  $ports=@();[bool]$valid=$true;[int]$total=0
  foreach($state in $States){
    $startup=@($state.parser.frames|Where-Object{$_.complete_us-lt$StartUs})
    $measured=@($state.parser.frames|Where-Object{
      $_.complete_us-ge$StartUs-and$_.complete_us-lt$EndUs})
    $observed=@($state.diagnostics|Where-Object{$_.diagnostic_success})
    $diagnostics=@($observed|Where-Object{
      $_.complete_us-ge$StartUs-and$_.complete_us-lt$EndUs})
    # A role seen only during startup cannot masquerade as continued activity.
    if($observed.Count-gt0-and$diagnostics.Count-eq0){$valid=$false}
    $total+=$diagnostics.Count
    [long]$startupBytes=0;foreach($frame in $startup){$startupBytes+=$frame.raw_length}
    [long]$measuredBytes=0;foreach($frame in $measured){$measuredBytes+=$frame.raw_length}
    $ports+=,[pscustomobject][ordered]@{role=[string]$state.spec.role
      startup_bytes=$startupBytes;startup_frames=$startup.Count
      measurement_complete_frames=$measured.Count
      measurement_complete_frame_bytes=$measuredBytes
      measurement_valid_diagnostics=$diagnostics.Count
      observed_diagnostic_role_active_in_window=($observed.Count-eq0-or$diagnostics.Count-gt0)}
  }
  $valid=$valid-and$total-gt0
  [pscustomobject][ordered]@{valid=$valid
    result=$(if($valid){'PASS_DIAGNOSTIC_ACTIVITY_IN_WINDOW'}else{'FAIL_NO_DIAGNOSTIC_IN_MEASUREMENT_WINDOW'})
    start_us=$StartUs;end_exclusive_us=$EndUs;valid_diagnostic_count=$total;ports=$ports
    semantics='Frame counts/bytes use application-observed frame completion times; startup_bytes counts complete-frame bytes, not all raw bytes. Additional startup raw remains separately preserved. A passing activity gate does not prove uninterrupted communication or product acceptance.'}
}

function Get-ElapsedUs([Diagnostics.Stopwatch]$Clock) {
  [int64][math]::Floor(([double]$Clock.ElapsedTicks*1000000.0)/
      [double][Diagnostics.Stopwatch]::Frequency)
}

function Read-DiagnosticSerial([object]$Serial,[object]$Parser,
    [IO.MemoryStream]$Raw,[Diagnostics.Stopwatch]$Clock,[ref]$LastServiceUs,
    [ref]$MaximumGapUs,[scriptblock]$NowUs=$null,[object]$ReadState=$null) {
  if($null-eq$ReadState){
    $ReadState=[pscustomobject]@{read_batch_id=[int64]0
      initial_drain_bytes=[int64]-1;initial_drain_remaining=[int64]-1}
  }
  foreach($property in @('read_batch_id','initial_drain_bytes',
      'initial_drain_remaining')){
    Assert-Condition ($null-ne$ReadState.PSObject.Properties[$property]) `
        "Diagnostic read state is missing $property."
  }
  $trace=if($ReadState.PSObject.Properties['lifecycle_trace']){$ReadState.lifecycle_trace}else{$null}
  [int64]$now=if($null-ne$NowUs){[int64](& $NowUs)}else{
    Get-ElapsedUs $Clock}
  if([int64]$LastServiceUs.Value-ge0){
    [int64]$gap=$now-[int64]$LastServiceUs.Value
    if($gap-gt[int64]$MaximumGapUs.Value){
      $MaximumGapUs.Value=$gap
      if($ReadState.PSObject.Properties['maximum_gap_begin_us']){
        $ReadState.maximum_gap_begin_us=[long]$LastServiceUs.Value
        $ReadState.maximum_gap_end_us=$now
      }
    }
  }
  $LastServiceUs.Value=$now
  if($ReadState.PSObject.Properties['continuous_reader']){
    if($ReadState.first_service_us-lt0){$ReadState.first_service_us=$now}
    [void](Read-R19ContinuousBytes $ReadState $Parser $Raw $Clock $PumpReadBudgetBytes)
    return
  }
  if([int64]$ReadState.initial_drain_remaining-lt0){
    [int64]$initial=[int]$Serial.BytesToRead
    $ReadState.initial_drain_bytes=$initial
    $ReadState.initial_drain_remaining=$initial
  }
  [int]$remaining=$PumpReadBudgetBytes
  while($remaining-gt0-and[int]$Serial.BytesToRead-gt0){
    [bool]$isStartupDrain=[int64]$ReadState.initial_drain_remaining-gt0
    [int]$count=[math]::Min($remaining,
        [math]::Min(8192,[int]$Serial.BytesToRead))
    if($isStartupDrain){
      $count=[math]::Min($count,[int64]$ReadState.initial_drain_remaining)
    }
    if($count-le0){break}
    [byte[]]$bytes=New-Object byte[] $count
    $ReadState.read_batch_id=[int64]$ReadState.read_batch_id+1
    if($null-ne$trace){Add-R19PcLifecycleEvent $trace 5 ([string]$Parser.name) $ReadState.read_batch_id $count}
    try{[int]$read=$Serial.Read($bytes,0,$count)}catch{
      if($null-ne$trace){Add-R19PcLifecycleEvent $trace 9 ([string]$Parser.name) $ReadState.read_batch_id}
      throw
    }
    [long]$readTicks=if($null-ne$trace){$trace.clock.ElapsedTicks}else{-1}
    if($null-ne$trace){Add-R19PcLifecycleEvent $trace 6 ([string]$Parser.name) $ReadState.read_batch_id $read 0 $readTicks}
    if($read-gt0-and$null-ne$trace){
      $roleBit=if($Parser.name-ceq'ground'){2}else{1}
      if(($trace.first_positive_role_mask-band$roleBit)-eq0){
        Add-R19PcLifecycleEvent $trace 7 ([string]$Parser.name) $ReadState.read_batch_id $read 0 $readTicks
        $trace.first_positive_role_mask=$trace.first_positive_role_mask-bor$roleBit
      }
    }
    if($read-le0){break}
    if($read-ne$count){[Array]::Resize([ref]$bytes,$read)}
    $remaining-=$read
    if($isStartupDrain){
      $ReadState.initial_drain_remaining=
          [int64]$ReadState.initial_drain_remaining-$read
    }
    $Raw.Write($bytes,0,$bytes.Length)
    [int64]$completeUs=if($null-ne$NowUs){[int64](& $NowUs)}else{
      Get-ElapsedUs $Clock}
    Add-DiagnosticBytes $Parser $bytes $completeUs `
        ([int64]$ReadState.read_batch_id) `
        $(if($isStartupDrain){'STARTUP_DRAIN'}else{'LIVE'}) $trace $readTicks
    if($isStartupDrain-and
        [int64]$ReadState.initial_drain_remaining-eq0){break}
  }
}

function Add-DiagnosticStateFrames([object]$State,[object]$Provenance) {
  while($State.cursor-lt$State.parser.frames.Count){
    $frame=$State.parser.frames[$State.cursor];$State.cursor++
    $decoded=Convert-R19Diagnostic $frame $State.spec.code $Provenance
    if($decoded.candidate){
      $leaf=Get-DiagnosticFrameLeaf ([string]$State.spec.role) `
          ([int]$State.cursor)
      $decoded|Add-Member NoteProperty raw_path $leaf
      [void]$State.diagnostics.Add($decoded)
      [void]$State.pending_frames.Add([pscustomobject]@{
        path=$leaf;bytes=[byte[]]$frame.raw})
    }elseif($frame.valid){
      $State.non_diagnostic_complete_frame_count++
    }
  }
}

function Get-ExpectedNextR19FailureFrame([object]$Parser) {
  for($i=$Parser.frames.Count-1;$i-ge0;--$i){
    $frame=$Parser.frames[$i]
    if(-not$frame.valid-or$frame.message_id-ne253-or$frame.raw_length-ne63){
      continue
    }
    [byte[]]$raw=[byte[]]$frame.raw
    if([Text.Encoding]::ASCII.GetString($raw,11,5)-cne'R19F:'){continue}
    [byte[]]$expected=[byte[]]$raw.Clone()
    $expected[4]=[byte](([int]$raw[4]+1)-band0xFF)
    [uint16]$crc=0xFFFF
    for($offset=1;$offset-lt61;++$offset){
      $crc=Update-X25Crc $crc $expected[$offset]
    }
    $crc=Update-X25Crc $crc 83
    $expected[61]=[byte]($crc-band0xFF)
    $expected[62]=[byte](($crc-shr8)-band0xFF)
    return $expected
  }
  return $null
}

function Test-ExactBytePrefix([byte[]]$Actual,[byte[]]$Expected) {
  if($null-eq$Expected-or$Actual.Length-gt$Expected.Length){return $false}
  for($i=0;$i-lt$Actual.Length;++$i){
    if($Actual[$i]-ne$Expected[$i]){return $false}
  }
  return $true
}

function Invoke-DiagnosticExactTailDrain([object]$Serial,[object]$Parser,
    [IO.MemoryStream]$Raw,[Diagnostics.Stopwatch]$Clock,[object]$ReadState,
    [int64]$DeadlineUs,[scriptblock]$NowUs=$null,
    [string]$PortRoleCode='',[int]$ExpectedNextSequence=-1,
    [byte[]]$ExpectedFrame=$null) {
  $trace=if($ReadState.PSObject.Properties['lifecycle_trace']){$ReadState.lifecycle_trace}else{$null}
  [int64]$tailStartUs=if($null-ne$NowUs){[int64](& $NowUs)}else{
    Get-ElapsedUs $Clock}
  [int]$initialPartial=[int]$Parser.buffer.Count
  [int]$expectedSize=[int]$Parser.expected_size
  [byte[]]$prefixBytes=$Parser.buffer.ToArray()
  $observedBytes=[Collections.Generic.List[byte]]::new()
  foreach($value in $prefixBytes){$observedBytes.Add($value)}
  [int64]$partialFirstSeen=[int64]$Parser.partial_first_seen_us
  [int64]$partialLastProgress=[int64]$Parser.partial_last_progress_us
  [int64]$partialLastProgressBeforeTail=$partialLastProgress
  [int64]$partialRawOffset=[int64]$Parser.partial_raw_offset
  $startedFrame=$initialPartial-gt0
  $headerKnown=$startedFrame-and$expectedSize-gt$initialPartial
  [int]$sequence=if($initialPartial-gt4){[int]$prefixBytes[4]}else{-1}
  [string]$frameRole=if($initialPartial-gt16){
    [char]$prefixBytes[16]}else{''}
  $roleMatches=-not[string]::IsNullOrWhiteSpace($PortRoleCode)-and
      $frameRole-ceq$PortRoleCode
  $prefixR19f=$initialPartial-ge17-and$prefixBytes[0]-eq0xFD-and
      $prefixBytes[1]-eq51-and$prefixBytes[7]-eq253-and
      $prefixBytes[8]-eq0-and$prefixBytes[9]-eq0-and
      $prefixBytes[10]-eq2-and
      [Text.Encoding]::ASCII.GetString($prefixBytes,11,5)-ceq'R19F:'
  $sourceBound=$prefixR19f-and$roleMatches
  $sequenceMatches=$ExpectedNextSequence-ge0-and
      $sequence-eq($ExpectedNextSequence-band0xFF)
  $expectedAvailable=$null-ne$ExpectedFrame-and$ExpectedFrame.Length-eq63
  [int]$required=if($headerKnown){$expectedSize-$initialPartial}else{0}
  [int]$readTotal=0
  [int]$startFrameCount=[int]$Parser.frames.Count
  [int64]$firstBatch=[int64]$ReadState.read_batch_id+1
  [string]$readException=''
  if($headerKnown){
    [int64]$now=$tailStartUs
    while($readTotal-lt$required){
      if($now-ge$DeadlineUs){break}
      if($ReadState.PSObject.Properties['continuous_reader']){
        # The native owner may have prefetched later frames. Consume only this
        # already-started frame's remainder; retain the suffix as separate evidence.
        [long]$beforeLength=$Raw.Length
        try{
          [int]$read=Read-R19ContinuousBytes $ReadState $Parser $Raw $Clock `
              ($required-$readTotal) 'TERMINAL_TAIL'
        }catch{$readException=$_.Exception.Message;break}
        if($read-gt0){
          [byte[]]$slice=$Raw.ToArray()
          for([int]$i=[int]$beforeLength;$i-lt$slice.Length;++$i){$observedBytes.Add($slice[$i])}
          $readTotal+=$read
          $partialLastProgress=Get-ElapsedUs $Clock
        }elseif($null-eq$NowUs){Start-Sleep -Milliseconds 1}
        $now=if($null-ne$NowUs){[int64](& $NowUs)}else{Get-ElapsedUs $Clock}
        continue
      }
      [int]$available=[int]$Serial.BytesToRead
      if($available-le0){
        if($null-eq$NowUs){Start-Sleep -Milliseconds 1}
        $now=if($null-ne$NowUs){[int64](& $NowUs)}else{
          Get-ElapsedUs $Clock}
        continue
      }
      [int]$count=[math]::Min($available,$required-$readTotal)
      $count=[math]::Min($count,8192)
      [byte[]]$bytes=New-Object byte[] $count
      $ReadState.read_batch_id=[int64]$ReadState.read_batch_id+1
      if($null-ne$trace){Add-R19PcLifecycleEvent $trace 5 ([string]$Parser.name) $ReadState.read_batch_id $count 1}
      try{
        [int]$read=$Serial.Read($bytes,0,$count)
      }catch{
        if($null-ne$trace){Add-R19PcLifecycleEvent $trace 9 ([string]$Parser.name) $ReadState.read_batch_id 0 1}
        $readException=$_.Exception.Message
        break
      }
      [long]$readTicks=if($null-ne$trace){$trace.clock.ElapsedTicks}else{-1}
      if($null-ne$trace){Add-R19PcLifecycleEvent $trace 6 ([string]$Parser.name) $ReadState.read_batch_id $read 1 $readTicks}
      if($read-gt0-and$null-ne$trace){
        $roleBit=if($Parser.name-ceq'ground'){2}else{1}
        if(($trace.first_positive_role_mask-band$roleBit)-eq0){
          Add-R19PcLifecycleEvent $trace 7 ([string]$Parser.name) $ReadState.read_batch_id $read 1 $readTicks
          $trace.first_positive_role_mask=$trace.first_positive_role_mask-bor$roleBit
        }
      }
      if($read-le0){
        if($null-eq$NowUs){Start-Sleep -Milliseconds 1}
        $now=if($null-ne$NowUs){[int64](& $NowUs)}else{
          Get-ElapsedUs $Clock}
        continue
      }
      if($read-ne$count){[Array]::Resize([ref]$bytes,$read)}
      $readTotal+=$read
      foreach($value in $bytes){$observedBytes.Add($value)}
      $Raw.Write($bytes,0,$bytes.Length)
      [int64]$completeUs=if($null-ne$NowUs){[int64](& $NowUs)}else{
        Get-ElapsedUs $Clock}
      $partialLastProgress=$completeUs
      Add-DiagnosticBytes $Parser $bytes $completeUs `
          ([int64]$ReadState.read_batch_id) 'TERMINAL_TAIL' $trace $readTicks
      $now=$completeUs
    }
  }
  [bool]$completed=$headerKnown-and$readTotal-eq$required-and
      [int]$Parser.frames.Count-eq$startFrameCount+1-and
      [int]$Parser.partial_bytes-eq0
  [int]$observed=$initialPartial+$readTotal
  [int]$remainingBytes=if($headerKnown){$required-$readTotal}else{
    if($startedFrame){-1}else{0}}
  [byte[]]$observedArray=$observedBytes.ToArray()
  $byteExact=$expectedAvailable-and
      (Test-ExactBytePrefix $observedArray $ExpectedFrame)
  [bool]$rawSuffixExact=$partialRawOffset-ge0-and
      $partialRawOffset+$observed-eq[long]$Raw.Length
  [bool]$valid=if(-not$headerKnown){-not$startedFrame}else{
    [string]::IsNullOrEmpty($readException)-and$readTotal-le$required-and
    $remainingBytes-ge0-and
    (($completed-and$observed-eq$expectedSize)-or
     (-not$completed-and$observed-lt$expectedSize-and
      [int]$Parser.frames.Count-eq$startFrameCount))}
  [string]$result=if(-not$headerKnown){
    if($startedFrame){'INELIGIBLE_HEADER_UNKNOWN'}else{'NOT_REQUIRED'}
  }elseif(-not[string]::IsNullOrEmpty($readException)){
    'READ_EXCEPTION'
  }elseif($completed){'COMPLETED'}else{'TIMEOUT_INCOMPLETE_SAME_FRAME'}
  [pscustomobject][ordered]@{
    valid=$valid;drain_attempted=$headerKnown;drain_completed=$completed
    result=$result;no_read_exception=[string]::IsNullOrEmpty($readException)
    read_exception=$readException
    started_frame=$startedFrame;header_known=$headerKnown
    expected_size=$expectedSize;observed=$observed;remaining=$remainingBytes
    initial_partial_bytes=$initialPartial;partial_bytes=$observed
    bytes_required=$required;bytes_read=$readTotal
    bytes_remaining=$remainingBytes;deadline_us=$DeadlineUs
    tail_start_us=$tailStartUs;partial_first_seen_us=$partialFirstSeen
    last_progress_us=$partialLastProgress
    last_progress_before_tail_us=$partialLastProgressBeforeTail
    age_before_tail_us=if($partialFirstSeen-ge0){
      $tailStartUs-$partialFirstSeen}else{-1}
    age_since_last_progress_before_tail_us=
        if($partialLastProgressBeforeTail-ge0){
          $tailStartUs-$partialLastProgressBeforeTail}else{-1}
    raw_offset=$partialRawOffset;raw_bytes=[int64]$Raw.Length
    raw_suffix_exact=$rawSuffixExact
    terminal_offset_plus_length_equals_raw_bytes=$rawSuffixExact
    first_read_batch_id=$firstBatch
    last_read_batch_id=if($readTotal-gt0){
      [int64]$ReadState.read_batch_id}else{[int64]-1}
    prefix_is_source_bound_r19f=$sourceBound
    role_matches_port=$roleMatches;mavlink_sequence=$sequence
    expected_next_sequence=$ExpectedNextSequence
    sequence_matches_next=$sequenceMatches
    expected_frame_available=$expectedAvailable
    byte_exact_expected_next_r19f_prefix=$byteExact
    failure_snapshot_matches_previous=$byteExact
  }
}

function Get-TerminalPartialContract([object[]]$States,
    [bool]$CaptureOtherwiseValid=$true) {
  $records=@($States|ForEach-Object{$_.tail_drain})
  $attemptedStates=@($States|Where-Object{$_.tail_drain.drain_attempted})
  $persistent=@($attemptedStates|Where-Object{
    -not$_.tail_drain.drain_completed-and[int]$_.parser.partial_bytes-gt0})
  $subjectState=if($persistent.Count-gt0){$persistent[0]}elseif(
      $attemptedStates.Count-gt0){$attemptedStates[0]}elseif($States.Count-gt0){
      $States[0]}else{$null}
  $subject=if($null-ne$subjectState){$subjectState.tail_drain}else{$null}
  $allOtherParserCountersZero=@($States|Where-Object{
    [int64]$_.parser.noise_bytes-ne0-or[int64]$_.parser.bad_length-ne0-or
    [int64]$_.parser.bad_crc-ne0-or
    [int64]$_.parser.unsupported_flags-ne0-or
    [int64]$_.parser.unknown_definition-ne0
  }).Count-eq0
  $unexpectedPartial=@($States|Where-Object{
    [int]$_.parser.partial_bytes-gt0-and$_-notin$persistent}).Count-gt0
  $priorR19f=@()
  if($null-ne$subjectState-and
      $null-ne$subjectState.PSObject.Properties['diagnostics']){
    $priorR19f=@($subjectState.diagnostics|Where-Object{
      $_.candidate-and$_.diagnostic_success-and$_.diagnostic_kind-ceq'R19F'})
  }
  $sourceBindingVerified=$priorR19f.Count-ge1-and
      @($priorR19f|Where-Object{-not$_.source_mapping_verified}).Count-eq0
  $persistentIdentityValid=$persistent.Count-eq1-and
      [bool]$subject.prefix_is_source_bound_r19f-and
      [bool]$subject.role_matches_port-and$sourceBindingVerified-and
      [bool]$subject.sequence_matches_next-and
      [bool]$subject.expected_frame_available-and
      [bool]$subject.byte_exact_expected_next_r19f_prefix-and
      [bool]$subject.raw_suffix_exact-and[bool]$subject.no_read_exception
  $onlyParserDefect=$CaptureOtherwiseValid-and$persistentIdentityValid-and
      $allOtherParserCountersZero-and-not$unexpectedPartial
  $allValid=$records.Count-eq$States.Count-and
      @($records|Where-Object{-not$_.valid}).Count-eq0
  $allCompleted=$attemptedStates.Count-gt0-and
      @($attemptedStates|Where-Object{
        -not$_.tail_drain.drain_completed}).Count-eq0
  $portRecords=@($States|ForEach-Object{[pscustomobject][ordered]@{
    role=if($null-ne$_.spec.PSObject.Properties['role']){
      [string]$_.spec.role}else{''}
    port=if($null-ne$_.spec.PSObject.Properties['port']){
      [string]$_.spec.port}else{''}
    tail_drain=$_.tail_drain}})
  [pscustomobject][ordered]@{
    valid=$allValid;one_role_only=$persistent.Count-eq1
    role=if($null-ne$subjectState-and
        $null-ne$subjectState.spec.PSObject.Properties['role']){
      [string]$subjectState.spec.role}else{''}
    port=if($null-ne$subjectState-and
        $null-ne$subjectState.spec.PSObject.Properties['port']){
      [string]$subjectState.spec.port}else{''}
    prior_r19f_count=$priorR19f.Count
    drain_attempted=$attemptedStates.Count-gt0;drain_completed=$allCompleted
    result=if($null-ne$subject){[string]$subject.result}else{'NOT_REQUIRED'}
    no_read_exception=if($null-ne$subject){
      [bool]$subject.no_read_exception}else{$true}
    read_exception=if($null-ne$subject){[string]$subject.read_exception}else{''}
    started_frame=if($null-ne$subject){[bool]$subject.started_frame}else{$false}
    header_known=if($null-ne$subject){[bool]$subject.header_known}else{$false}
    expected_size=if($null-ne$subject){[int]$subject.expected_size}else{0}
    observed=if($null-ne$subject){[int]$subject.observed}else{0}
    remaining=if($null-ne$subject){[int]$subject.remaining}else{0}
    partial_first_seen_us=if($null-ne$subject){
      [int64]$subject.partial_first_seen_us}else{-1}
    last_progress_us=if($null-ne$subject){
      [int64]$subject.last_progress_us}else{-1}
    last_progress_before_tail_us=if($null-ne$subject){
      [int64]$subject.last_progress_before_tail_us}else{-1}
    age_before_tail_us=if($null-ne$subject){
      [int64]$subject.age_before_tail_us}else{-1}
    age_since_last_progress_before_tail_us=if($null-ne$subject){
      [int64]$subject.age_since_last_progress_before_tail_us}else{-1}
    raw_offset=if($null-ne$subject){[int64]$subject.raw_offset}else{-1}
    partial_bytes=if($null-ne$subject){[int]$subject.partial_bytes}else{0}
    raw_bytes=if($null-ne$subject){[int64]$subject.raw_bytes}else{0}
    raw_suffix_exact=if($null-ne$subject){
      [bool]$subject.raw_suffix_exact}else{$false}
    raw_terminal_offset_valid=if($null-ne$subject){
      [bool]$subject.raw_suffix_exact}else{$false}
    terminal_offset_plus_length_equals_raw_bytes=if($null-ne$subject){
      [bool]$subject.terminal_offset_plus_length_equals_raw_bytes}else{$false}
    prefix_is_source_bound_r19f=if($null-ne$subject){
      [bool]$subject.prefix_is_source_bound_r19f}else{$false}
    role_matches_port=if($null-ne$subject){
      [bool]$subject.role_matches_port}else{$false}
    source_binding_verified=$sourceBindingVerified
    mavlink_sequence=if($null-ne$subject){
      [int]$subject.mavlink_sequence}else{-1}
    expected_next_sequence=if($null-ne$subject){
      [int]$subject.expected_next_sequence}else{-1}
    sequence_matches_next=if($null-ne$subject){
      [bool]$subject.sequence_matches_next}else{$false}
    expected_frame_available=if($null-ne$subject){
      [bool]$subject.expected_frame_available}else{$false}
    byte_exact_expected_next_r19f_prefix=if($null-ne$subject){
      [bool]$subject.byte_exact_expected_next_r19f_prefix}else{$false}
    failure_snapshot_matches_previous=if($null-ne$subject){
      [bool]$subject.failure_snapshot_matches_previous}else{$false}
    all_other_parser_counters_zero=$allOtherParserCountersZero
    exact_tail_bytes_required=if($null-ne$subject){
      [int]$subject.bytes_required}else{0}
    exact_tail_bytes_read=if($null-ne$subject){
      [int]$subject.bytes_read}else{0}
    only_parser_defect=$onlyParserDefect
    attempted_port_count=$attemptedStates.Count;ports=$portRecords
  }
}

function Get-R19FailureBoundaryPartialContract([object[]]$States,
    [bool]$CaptureOtherwiseValid=$true) {
  # Expected templates identify the observed boundary bytes only. Never append
  # missing bytes to raw capture or count either partial frame as received.
  $raw=[byte[]]@();$leading=[byte[]]@();$prefix=[byte[]]@();$prior=@()
  $source=$null;$leadingSequence=-1;$terminalSequence=-1;$offset=[int64]-1
  $unique=$false;$suffixExact=$false;$snapshots=$false;$contiguous=$false
  $crcValid=$false;$sourceBound=$false;$prefixExact=$false;$onlyDefects=$false
  $noProgress=[int64]-1;$rejections=[Collections.Generic.List[string]]::new()
  try{
    $ground=@($States|Where-Object{$_.spec.role-ceq'ground'-and
      $_.spec.port-ceq'COM6'})
    $vehicle=@($States|Where-Object{$_.spec.role-ceq'vehicle'-and
      $_.spec.port-ceq'COM3'})
    Assert-Condition ($CaptureOtherwiseValid-and$States.Count-eq2-and
      $ground.Count-eq1-and$vehicle.Count-eq1) 'r19f_boundary_capture_scope'
    $state=$ground[0];$tail=$state.tail_drain
    $raw=[byte[]]$state.raw.ToArray();$prefix=$state.parser.buffer.ToArray()
    $offset=[int64]$state.parser.partial_raw_offset
    $prior=@($state.diagnostics|Where-Object{$_.candidate-and
      $_.diagnostic_success-and$_.diagnostic_kind-ceq'R19F'-and
      $_.role_code-ceq'G'})
    $sourceBound=$prior.Count-ge2-and@($prior|Where-Object{
      -not$_.source_mapping_verified}).Count-eq0
    $snapshots=$prior.Count-ge2-and@($prior|ForEach-Object{
      Get-R19FailureSnapshotKey $_}|Sort-Object -Unique).Count-eq1
    $contiguous=$prior.Count-ge2
    for($i=1;$i-lt$prior.Count;++$i){
      if([int]$prior[$i].mavlink_sequence-ne
          (([int]$prior[$i-1].mavlink_sequence+1)-band255)){$contiguous=$false}
    }
    $crcValid=@($state.parser.frames|Where-Object{-not$_.valid}).Count-eq0
    $onlyDefects=(Test-DiagnosticParserClean $vehicle[0].parser)-and
      [int64]$state.parser.noise_bytes-eq31-and
      [int64]$state.parser.bad_length-eq0-and[int64]$state.parser.bad_crc-eq0-and
      [int64]$state.parser.unsupported_flags-eq0-and
      [int64]$state.parser.unknown_definition-eq0-and
      [int]$state.parser.partial_bytes-eq32-and$prefix.Length-eq32-and
      $state.parser.frames.Count-eq$prior.Count-and
      $state.diagnostics.Count-eq$prior.Count-and
      $raw.Length-eq31+63*$prior.Count+32-and$offset-eq31+63*$prior.Count
    Assert-Condition ($sourceBound-and$snapshots-and$contiguous-and
      $crcValid-and$onlyDefects) 'r19f_boundary_parser_or_snapshot'
    $source=$prior[0];$leading=[byte[]]$raw[0..30]
    [byte[]]$first=$state.parser.frames[0].raw
    Assert-Condition ($first.Length-eq63-and$first[0]-eq253-and
      $first[1]-eq51-and$first[2]-eq0-and$first[3]-eq0-and
      $first[5]-eq254-and$first[6]-eq190-and$first[7]-eq253-and
      $first[8]-eq0-and$first[9]-eq0-and$first[10]-eq2-and
      [Text.Encoding]::ASCII.GetString($first,11,7)-ceq'R19F:G:') `
      'r19f_boundary_complete_identity'
    $derive={param([byte[]]$Template,[int]$Sequence)
      [byte[]]$expected=$Template.Clone();$expected[4]=[byte]$Sequence
      [uint16]$crc=65535
      for($j=1;$j-lt61;++$j){$crc=Update-X25Crc $crc $expected[$j]}
      $crc=Update-X25Crc $crc 83
      $expected[61]=[byte]($crc-band255)
      $expected[62]=[byte](($crc-shr8)-band255)
      return ,$expected
    }
    $matches=[Collections.Generic.List[int]]::new()
    for($sequence=0;$sequence-lt256;++$sequence){
      [byte[]]$expected=& $derive $first $sequence
      if(Test-ExactBytePrefix $leading ([byte[]]$expected[32..62])){
        $matches.Add($sequence)
      }
    }
    $unique=$matches.Count-eq1
    if($unique){$leadingSequence=$matches[0]}
    $suffixExact=$unique-and$leadingSequence-eq(([int]$first[4]+255)-band255)
    Assert-Condition ($suffixExact) 'r19f_boundary_leading_suffix_not_unique_previous'
    for($i=0;$i-lt$prior.Count;++$i){
      [byte[]]$expected=& $derive $first (([int]$first[4]+$i)-band255)
      [byte[]]$observed=$raw[(31+63*$i)..(31+63*$i+62)]
      Assert-Condition ((Test-ExactBytePrefix $observed $expected)-and
        (Test-ExactBytePrefix ([byte[]]$state.parser.frames[$i].raw) $expected)-and
        [int64]$state.parser.frames[$i].raw_offset-eq31+63*$i) `
        'r19f_boundary_complete_raw_mismatch'
    }
    $terminalSequence=([int]$first[4]+$prior.Count)-band255
    [byte[]]$expected=& $derive $first $terminalSequence
    $prefixExact=(Test-ExactBytePrefix $prefix $expected)-and
      (Test-ExactBytePrefix $prefix ([byte[]]$raw[$offset..($raw.Length-1)]))
    $noProgress=[int64]$tail.deadline_us-[int64]$tail.last_progress_us
    Assert-Condition ($prefixExact-and[bool]$tail.valid-and
      [bool]$tail.drain_attempted-and-not[bool]$tail.drain_completed-and
      [string]$tail.result-ceq'TIMEOUT_INCOMPLETE_SAME_FRAME'-and
      [bool]$tail.no_read_exception-and
      [string]::IsNullOrEmpty([string]$tail.read_exception)-and
      [int]$tail.expected_size-eq63-and[int]$tail.initial_partial_bytes-eq32-and
      [int]$tail.partial_bytes-eq32-and[int]$tail.bytes_required-eq31-and
      [int]$tail.bytes_read-eq0-and[int]$tail.remaining-eq31-and
      [int]$tail.bytes_remaining-eq31-and[int64]$tail.raw_offset-eq$offset-and
      [int64]$tail.raw_bytes-eq$raw.Length-and$noProgress-ge500000) `
      'r19f_boundary_terminal_stall'
  }catch{[void]$rejections.Add($_.Exception.Message)}
  [pscustomobject][ordered]@{
    schema='vc-lora-r19f-boundary-partial-cause-contract-v1'
    valid=$rejections.Count-eq0;fail_only=$true;reconstruction_performed=$false
    missing_prefix_received=$false;missing_terminal_crc_verified=$false
    role='ground';port='COM6';leading_bytes=$leading.Length
    leading_raw_offset=0;leading_sha256=Get-ByteSha $leading
    raw_bytes=$raw.Length;raw_sha256=Get-ByteSha $raw
    leading_prior_sequence=$leadingSequence;leading_sequence_unique=$unique
    leading_suffix_exact=$suffixExact;prior_r19f_count=$prior.Count
    prior_complete_frames_crc_valid=$crcValid
    prior_source_binding_verified=$sourceBound;prior_snapshots_identical=$snapshots
    prior_sequences_contiguous=$contiguous;terminal_partial_bytes=$prefix.Length
    terminal_raw_offset=$offset;terminal_prefix_sha256=Get-ByteSha $prefix
    terminal_sequence=$terminalSequence;terminal_prefix_exact=$prefixExact
    no_progress_us=$noProgress;only_parser_defects=$onlyDefects
    source_path=if($null-ne$source){[string]$source.source_path}else{''}
    source_sha256=if($null-ne$source){[string]$source.source_sha256}else{''}
    application_sha256=if($null-ne$source){[string]$source.application_sha256}else{''}
    rejection_reasons=@($rejections)
  }
}

function Get-R19AliveTerminalPartialContract([object[]]$States,
    [bool]$CaptureOtherwiseValid=$true) {
  $ground=@($States|Where-Object{$_.spec.role-ceq'ground'-and
      $_.spec.port-ceq'COM6'})
  $valid=$false;$raw=[byte[]]@();$prefix=[byte[]]@();$alive=@()
  $source=$null;$tail=$null;$offset=[int64]-1
  $nextSequence=-1;$nextOrdinal=[int64]-1;$noProgress=[int64]-1
  $contiguous=$false;$sourceBound=$false;$crcValid=$false
  $prefixIdentity=$false;$nextIdentity=$false;$onlyDefect=$false
  if($States.Count-eq2-and$ground.Count-eq1){
    $state=$ground[0];$tail=$state.tail_drain
    $raw=[byte[]]$state.raw.ToArray();$prefix=$state.parser.buffer.ToArray()
    $offset=[int64]$state.parser.partial_raw_offset
    $alive=@($state.diagnostics|Where-Object{$_.candidate-and
      $_.diagnostic_success-and$_.diagnostic_kind-ceq'R19A'-and
      $_.beacon_state-ceq'ALIVE'-and$_.role_code-ceq'G'})
    $sourceBound=$alive.Count-ge2-and@($alive|Where-Object{
      -not$_.source_mapping_verified}).Count-eq0
    $contiguous=$alive.Count-ge2
    for($i=1;$i-lt$alive.Count;++$i){
      if([int]$alive[$i].mavlink_sequence-ne
          (([int]$alive[$i-1].mavlink_sequence+1)-band255)-or
          [uint64]$alive[$i].diagnostic_ordinal-ne
            [uint64]$alive[$i-1].diagnostic_ordinal+1-or
          [uint64]$alive[$i].monotonic_ms-le
            [uint64]$alive[$i-1].monotonic_ms){$contiguous=$false}
    }
    if($alive.Count-ge1){
      $source=$alive[-1]
      $nextSequence=([int]$source.mavlink_sequence+1)-band255
      $nextOrdinal=[int64]$source.diagnostic_ordinal+1
    }
    $crcValid=@($state.parser.frames|Where-Object{-not$_.valid}).Count-eq0
    $prefixIdentity=$prefix.Length-eq32-and$prefix[0]-eq253-and
      $prefix[1]-eq51-and$prefix[2]-eq0-and$prefix[3]-eq0-and
      $prefix[5]-eq254-and$prefix[6]-eq190-and$prefix[7]-eq253-and
      $prefix[8]-eq0-and$prefix[9]-eq0-and$prefix[10]-eq6-and
      [Text.Encoding]::ASCII.GetString($prefix,11,9)-ceq'R19A:G:L:'
    if($prefixIdentity-and$nextOrdinal-le[uint32]::MaxValue){
      $text=[Text.Encoding]::ASCII.GetString($prefix,11,21)
      $nextIdentity=[int]$prefix[4]-eq$nextSequence-and
        $text-cmatch'^R19A:G:L:[0-9A-F]{8}:[0-9A-F]{3}$'-and
        $text.Substring(9,8)-ceq('{0:X8}'-f$nextOrdinal)
    }
    $noProgress=[int64]$tail.deadline_us-[int64]$tail.last_progress_us
    $onlyDefect=$CaptureOtherwiseValid-and@($States|Where-Object{
      [int64]$_.parser.noise_bytes-ne0-or[int64]$_.parser.bad_length-ne0-or
      [int64]$_.parser.bad_crc-ne0-or
      [int64]$_.parser.unsupported_flags-ne0-or
      [int64]$_.parser.unknown_definition-ne0}).Count-eq0-and
      @($States|Where-Object{[int]$_.parser.partial_bytes-gt0}).Count-eq1-and
      [int]$state.parser.partial_bytes-eq32
    $valid=$onlyDefect-and$sourceBound-and$contiguous-and$crcValid-and
      $prefixIdentity-and$nextIdentity-and$offset-ge0-and
      $offset+32-eq$raw.Length-and
      (Test-ExactBytePrefix $prefix ([byte[]]$raw[$offset..($raw.Length-1)]))-and
      [bool]$tail.valid-and[bool]$tail.drain_attempted-and
      -not[bool]$tail.drain_completed-and
      [string]$tail.result-ceq'TIMEOUT_INCOMPLETE_SAME_FRAME'-and
      [bool]$tail.no_read_exception-and
      [string]::IsNullOrEmpty([string]$tail.read_exception)-and
      [int]$tail.expected_size-eq63-and[int]$tail.bytes_read-eq0-and
      [int]$tail.remaining-eq31-and$noProgress-ge500000
  }
  [pscustomobject][ordered]@{
    schema='vc-lora-r19a-terminal-partial-cause-contract-v1'
    valid=$valid;fail_only=$true;reconstruction_performed=$false
    missing_crc_verified=$false;role='ground';port='COM6'
    expected_size=63;partial_bytes=$prefix.Length;raw_offset=$offset
    raw_bytes=$raw.Length;raw_sha256=Get-ByteSha $raw
    prefix_sha256=Get-ByteSha $prefix;prior_alive_count=$alive.Count
    prior_alive_contiguous=$contiguous
    prior_complete_frames_crc_valid=$crcValid
    prior_source_binding_verified=$sourceBound
    next_sequence=$nextSequence;next_ordinal=$nextOrdinal
    prefix_identity_valid=$prefixIdentity;prefix_next_identity_valid=$nextIdentity
    drain_attempted=if($null-ne$tail){[bool]$tail.drain_attempted}else{$false}
    drain_completed=if($null-ne$tail){[bool]$tail.drain_completed}else{$false}
    result=if($null-ne$tail){[string]$tail.result}else{'NOT_REQUIRED'}
    bytes_read=if($null-ne$tail){[int]$tail.bytes_read}else{0}
    remaining=if($null-ne$tail){[int]$tail.remaining}else{0}
    no_read_exception=if($null-ne$tail){[bool]$tail.no_read_exception}else{$true}
    no_progress_us=$noProgress;only_parser_defect=$onlyDefect
    source_path=if($null-ne$source){[string]$source.source_path}else{''}
    source_sha256=if($null-ne$source){[string]$source.source_sha256}else{''}
    application_sha256=if($null-ne$source){
      [string]$source.application_sha256}else{''}
  }
}

function New-OfflineBufferedSerial([byte[]]$Bytes) {
  $serial=[pscustomobject][ordered]@{
    data=[byte[]]($Bytes.Clone());offset=0;read_calls=0;maximum_requested=0
  }
  $serial|Add-Member ScriptProperty BytesToRead {
    return [int]($this.data.Length-$this.offset)
  }
  $serial|Add-Member ScriptMethod Read {
    param([byte[]]$Buffer,[int]$BufferOffset,[int]$Count)
    [int]$available=$this.data.Length-$this.offset
    [int]$take=[math]::Min($Count,$available)
    if($take-le0){return 0}
    [Array]::Copy($this.data,$this.offset,$Buffer,$BufferOffset,$take)
    $this.offset+=$take
    $this.read_calls++
    if($Count-gt$this.maximum_requested){$this.maximum_requested=$Count}
    return $take
  }
  return $serial
}

function Invoke-OfflineCaptureFailureProbe {
  $serial=[pscustomobject][ordered]@{IsOpen=$true}
  $serial|Add-Member ScriptMethod Close {
    throw 'injected serial close failure'
  }
  $serial|Add-Member ScriptMethod Dispose {
    throw 'injected serial dispose failure'
  }
  $raw=[pscustomobject][ordered]@{}
  $raw|Add-Member ScriptMethod ToArray {
    throw 'injected deferred persistence failure'
  }
  $raw|Add-Member ScriptMethod Dispose {
    throw 'injected raw dispose failure'
  }
  $pendingOne=[pscustomobject][ordered]@{
    path='offline_injected\injected pending frame one failure.bin'
    bytes=$null
  }
  $pendingTwo=[pscustomobject][ordered]@{
    path='offline_injected\injected pending frame two failure.bin'
    bytes=$null
  }
  $state=[pscustomobject][ordered]@{
    spec=[pscustomobject]@{role='offline-injected'}
    serial=$serial;raw=$raw;pending_frames=@($pendingOne,$pendingTwo)
  }
  $errors=[Collections.ArrayList]::new()
  try{
    throw 'injected capture body failure'
  }finally{
    $script:CaptureCleanupResult=
        Invoke-DiagnosticCaptureCleanup @($state) $errors
  }
}

function Invoke-R19RuntimeFailDiagnosticCapture([object]$Provenance) {
  Assert-Condition ($CaptureSeconds-ge1 -and $CaptureSeconds-le60) `
      'CaptureSeconds must be within 1..60.'
  $script:ExternalActions.process_inventory_queried=$true
  $names=@('MissionPlanner','mavproxy','qgroundcontrol','putty','teraterm')
  $busy=@(Get-Process -ErrorAction SilentlyContinue|Where-Object{
    $names -contains $_.ProcessName})
  Assert-Condition ($busy.Count-eq0) 'Competing serial client found.'
  foreach($spec in $portSpecs){Assert-ExactPortIdentity $spec 'before_open'}
  Initialize-R19StartupReader
  $lifecycleTrace=New-R19PcLifecycleTrace
  $script:CaptureLifecycleTrace=$lifecycleTrace
  $states=@()
  foreach($spec in $portSpecs){
    $serial=New-DiagnosticSerialPort $spec
    $raw=[IO.MemoryStream]::new()
    $openEvidence=[pscustomobject][ordered]@{
      role=[string]$spec.role;port=[string]$spec.port
      serial_port_open_before_utc=$null
      serial_port_open_after_utc=$null
      serial_port_open_duration_ms=$null
      result='NOT_ATTEMPTED';failure=$null
    }
    [void]$script:ExternalActions.serial_port_open_evidence.Add($openEvidence)
    $states+=,[pscustomobject][ordered]@{spec=$spec;serial=$serial;raw=$raw
      parser=New-DiagnosticParser $spec.role;cursor=0;last=[int64]-1
      max_gap=[int64]0;diagnostics=[Collections.ArrayList]::new()
      pending_frames=[Collections.ArrayList]::new()
      non_diagnostic_complete_frame_count=0;open_evidence=$openEvidence;lifecycle_trace=$lifecycleTrace
      read_state=[pscustomobject]@{read_batch_id=[int64]0
        initial_drain_bytes=[int64]-1;initial_drain_remaining=[int64]-1;lifecycle_trace=$lifecycleTrace}
      tail_drain=$null;startup_reader=$null;startup_snapshot=$null
      startup_evidence=$null;startup_identity_verified=$false;startup_close_required=$false}
  }
  # Share the QPC origin with native startup records; 40 s begins later.
  $clock=$lifecycleTrace.clock;$cleanupErrors=[Collections.ArrayList]::new()
  $script:CaptureCleanupResult=$null
  try{
    Start-R19ContinuousCapture $states $lifecycleTrace
    foreach($state in $states){
      [void](Open-DiagnosticSerialPort $state.serial $state.open_evidence $null `
          $lifecycleTrace ([string]$state.spec.role) $state.continuous_reader)
      $script:ExternalActions.com_ports_opened=$true
      [void]$script:ExternalActions.opened_ports.Add([string]$state.spec.port)
    }
    foreach($spec in $portSpecs){Assert-ExactPortIdentity $spec 'after_open'}
    foreach($state in $states){$state.startup_identity_verified=$true}
    Confirm-R19ContinuousIdentity $states
    foreach($state in $states){Add-R19PcLifecycleEvent $lifecycleTrace 4 ([string]$state.spec.role)}
    $clock.Start();[int]$turn=0
    [long]$measurementWindowStartUs=Get-ElapsedUs $clock
    while(((Get-ElapsedUs $clock)-$measurementWindowStartUs)-lt([int64]$CaptureSeconds*1000000)){
      $order=if(($turn-band1)-eq0){@(0,1)}else{@(1,0)}
      foreach($index in $order){
        $state=$states[$index];[int64]$last=$state.last;[int64]$gap=$state.max_gap
        [void](Read-DiagnosticSerial $state.serial $state.parser $state.raw `
            $clock ([ref]$last) ([ref]$gap) $null $state.read_state)
        $state.last=$last;$state.max_gap=$gap
        Add-DiagnosticStateFrames $state $Provenance
      }
      ++$turn;Start-Sleep -Milliseconds 2
    }
    # Close the final LIVE interval: a slow last decode must not disappear merely
    # because no subsequent pump call occurs before the measurement window ends.
    [long]$lastLiveServiceUs=Get-ElapsedUs $clock
    foreach($state in $states){
      [long]$gap=$lastLiveServiceUs-$state.last
      if($state.last-ge0-and$gap-gt$state.max_gap){
        $state.max_gap=$gap
        $state.read_state.maximum_gap_begin_us=$state.last
        $state.read_state.maximum_gap_end_us=$lastLiveServiceUs
      }
    }
    [int64]$tailDeadline=Get-ElapsedUs $clock
    $tailDeadline+=$TerminalTailDrainLimitUs
    foreach($state in $states){
      [void]$state.continuous_reader.MarkPhase('TAIL')
      [byte[]]$expectedFrame=Get-ExpectedNextR19FailureFrame $state.parser
      [int]$expectedNext=if($null-ne$expectedFrame){
        [int]$expectedFrame[4]}else{-1}
      $state.tail_drain=Invoke-DiagnosticExactTailDrain $state.serial `
          $state.parser $state.raw $clock $state.read_state $tailDeadline `
          $null ([string]$state.spec.code) $expectedNext $expectedFrame
      Add-DiagnosticStateFrames $state $Provenance
    }
  }finally{
    $script:CaptureCleanupResult=
        Invoke-DiagnosticCaptureCleanup $states $cleanupErrors
    $clock.Stop()
    $lifecycleTrace.clock.Stop()
  }
  $lifecycleEvidence=ConvertTo-R19PcLifecycleEvidence $lifecycleTrace
  $all=@($states|ForEach-Object{@($_.diagnostics)})
  $valid=@($all|Where-Object{$_.diagnostic_success})
  $invalid=@($all|Where-Object{-not $_.diagnostic_success})
  $fair=(@($states|Where-Object{$_.max_gap-gt$PumpServiceLimitUs}).Count-eq0)
  $startupReadersValid=@($states|Where-Object{
    $null-eq$_.startup_evidence-or-not$_.startup_evidence.valid-or
    -not$_.startup_evidence.identity_verified-or-not$_.startup_evidence.replayed}).Count-eq0
  $measurementWindow=Get-R19MeasurementWindowEvidence $states $measurementWindowStartUs `
      ($measurementWindowStartUs+[long]$CaptureSeconds*1000000)
  $aliveMonotonic=Test-R19AliveMonotonic $all
  $parserClean=@($states|Where-Object{
    -not(Test-DiagnosticParserClean $_.parser)}).Count-eq0
  $repeatContract=Test-R19FailureRepeatContract $all
  $otherComplete=[int](@($states|Measure-Object `
      -Property non_diagnostic_complete_frame_count -Sum).Sum)
  $classificationWithoutParser=Get-R19DiagnosticClassification $all `
      $otherComplete $aliveMonotonic $true ([bool]$repeatContract.valid)
  $terminalPartialContract=Get-TerminalPartialContract $states `
      ([string]$classificationWithoutParser.result-ceq'PASS')
  $alivePartialContract=Get-R19AliveTerminalPartialContract $states `
      ([string]$classificationWithoutParser.result-ceq'PASS')
  $boundaryPartialContract=Get-R19FailureBoundaryPartialContract $states `
      ([string]$classificationWithoutParser.result-ceq'PASS')
  $classification=Get-R19DiagnosticClassification $all $otherComplete `
      $aliveMonotonic $parserClean ([bool]$repeatContract.valid) `
      $terminalPartialContract $alivePartialContract $boundaryPartialContract
  [pscustomobject][ordered]@{
    result=if($classification.result-ceq'PASS'-and$fair-and$startupReadersValid-and$measurementWindow.valid-and
        $cleanupErrors.Count-eq0){'PASS'}else{'FAIL'}
    diagnostic_status=[string]$classification.status
    diagnostic_classification=[string]$classification.classification
    engineering_disposition=[string]$classification.engineering_disposition
    alive_role_coverage=[string]$classification.alive_role_coverage
    alive_roles=@($classification.alive_roles)
    armed_count=[int]$classification.armed_count
    alive_count=[int]$classification.alive_count
    r19f_count=@($valid|Where-Object{$_.diagnostic_kind-ceq'R19F'}).Count
    diagnostic_only=$true;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$false
    serial_write_calls=0;capture_seconds=$CaptureSeconds
    measurement_window_start_us=$measurementWindowStartUs
    measurement_window=$measurementWindow
    raw_includes_additional_startup_interval=$true
    startup_readers_valid=$startupReadersValid
    startup_reader_evidence=@($states|ForEach-Object{$_.startup_evidence})
    continuous_readers_valid=$startupReadersValid
    continuous_reader_evidence=@($states|ForEach-Object{$_.continuous_evidence})
    pc_lifecycle_trace=$lifecycleEvidence
    pump_service_limit_us=$PumpServiceLimitUs
    parser_service_scope='LIVE parser pump including final interval; separate bounded terminal-tail drain excluded. Native Read service is checked for the entire Open-to-cleanup lifetime.'
    terminal_tail_drain_limit_us=$TerminalTailDrainLimitUs
    alive_sequence_time_monotonic=$aliveMonotonic
    parser_clean=$parserClean
    r19f_repeat_contract=$repeatContract
    terminal_partial_contract=$terminalPartialContract
    r19a_terminal_partial_contract=$alivePartialContract
    r19f_boundary_partial_contract=$boundaryPartialContract
    non_diagnostic_complete_frame_count=$otherComplete
    ports=@($states|ForEach-Object{[pscustomobject]@{role=$_.spec.role
      port=$_.spec.port;raw_bytes=$_.parser.total_bytes
      raw_sha256=Get-ByteSha ([byte[]]$_.raw.ToArray())
      baud=[int]$_.spec.baud
      serial_port_open_before_utc=
        [string]$_.open_evidence.serial_port_open_before_utc
      serial_port_open_after_utc=
        [string]$_.open_evidence.serial_port_open_after_utc
      serial_port_open_duration_ms=
        [double]$_.open_evidence.serial_port_open_duration_ms
      read_batch_id=[int64]$_.read_state.read_batch_id
      startup_drain=[pscustomobject]@{
        initial_bytes=[int64]$_.read_state.initial_drain_bytes
        remaining=[int64]$_.read_state.initial_drain_remaining
        completed=[int64]$_.read_state.initial_drain_remaining-eq0}
      tail_drain=$_.tail_drain
      maximum_service_gap_us=$_.max_gap
      parser_first_service_us=$_.read_state.first_service_us
      parser_maximum_gap_begin_us=$_.read_state.maximum_gap_begin_us
      parser_maximum_gap_end_us=$_.read_state.maximum_gap_end_us
      native_read_maximum_service_gap_us=$_.continuous_evidence.maximum_service_gap_us
      native_raw_bytes=$_.continuous_evidence.raw_bytes
      unparsed_native_bytes=$_.continuous_evidence.unparsed_bytes
      frame_count=$_.parser.frames.Count
      noise_bytes=[int64]$_.parser.noise_bytes
      partial_bytes=[int]$_.parser.partial_bytes
      bad_length=[int64]$_.parser.bad_length
      bad_crc=[int64]$_.parser.bad_crc
      unsupported_flags=[int64]$_.parser.unsupported_flags
      unknown_definition=[int64]$_.parser.unknown_definition
      valid_frame_count=[int64]$_.parser.valid_frames
      parser_clean=(Test-DiagnosticParserClean $_.parser)
      non_diagnostic_complete_frame_count=
        [int]$_.non_diagnostic_complete_frame_count
      armed_count=@($_.diagnostics|Where-Object{$_.diagnostic_success-and
        $_.diagnostic_kind-ceq'R19A'-and$_.beacon_state-ceq'ARMED'}).Count
      alive_count=@($_.diagnostics|Where-Object{$_.diagnostic_success-and
        $_.diagnostic_kind-ceq'R19A'-and$_.beacon_state-ceq'ALIVE'}).Count
      r19f_count=@($_.diagnostics|Where-Object{$_.diagnostic_success-and
        $_.diagnostic_kind-ceq'R19F'}).Count
      diagnostics=@($_.diagnostics)}})
    valid_diagnostic_count=$valid.Count;invalid_diagnostic_count=$invalid.Count
    cleanup=$script:CaptureCleanupResult
  }
}

function Get-RepoRelativePath([string]$Path) {
  $full=[IO.Path]::GetFullPath($Path)
  Assert-Condition ($full.StartsWith($repo+'\',
      [StringComparison]::OrdinalIgnoreCase)) `
      'Offline fixture path escaped the repository.'
  $full.Substring($repo.Length+1).Replace('\','/')
}

function New-OfflineDiagnosticArtifactChain {
  $base=Join-Path $evidence 'offline_fixture\candidate_base'
  $root=Join-Path $base 'OFFLINE-DIAGNOSTIC-CANDIDATE-001'
  $flashRoot=Join-Path $evidence 'offline_fixture\flash_evidence'
  [void][IO.Directory]::CreateDirectory($root)
  [void][IO.Directory]::CreateDirectory($flashRoot)
  $vehicleApp=Join-Path $root 'artifacts\vehicle.application.bin'
  $groundApp=Join-Path $root 'artifacts\ground.application.bin'
  $vehicleSource=Join-Path $root `
      'package\vc_lora_vehicle_xiao_esp32s3\vc_lora_phase6_bridge.hpp'
  $groundSource=Join-Path $root `
      'package\vc_lora_ground_xiao_esp32s3\vc_lora_phase6_bridge.hpp'
  Write-DurableBytes $vehicleApp ([byte[]](1,2,3,4))
  Write-DurableBytes $groundApp ([byte[]](5,6,7,8))
  Write-DurableBytes $vehicleSource $utf8.GetBytes('offline vehicle source')
  Write-DurableBytes $groundSource $utf8.GetBytes('offline ground source')
  $artifactId='OFFLINE-DIAGNOSTIC-CANDIDATE-001'
  $manifestPath=Join-Path $root 'candidate_manifest.json'
  $manifest=[pscustomobject][ordered]@{
    schema='vc-lora-r19-candidate-artifact-manifest-v1'
    artifact_id=$artifactId;result='PASS'
    runtime_fail_diagnostics_enabled=$true;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$false
    artifact_root=Get-RepoRelativePath $root
    roles=@(
      [pscustomobject]@{role='vehicle';application=[pscustomobject]@{
        path='artifacts/vehicle.application.bin';sha256=Get-Sha $vehicleApp}},
      [pscustomobject]@{role='ground';application=[pscustomobject]@{
        path='artifacts/ground.application.bin';sha256=Get-Sha $groundApp}})
    staged_package_snapshot=[pscustomobject]@{files=@(
      [pscustomobject]@{
        path='package/vc_lora_vehicle_xiao_esp32s3/vc_lora_phase6_bridge.hpp'
        sha256=Get-Sha $vehicleSource},
      [pscustomobject]@{
        path='package/vc_lora_ground_xiao_esp32s3/vc_lora_phase6_bridge.hpp'
        sha256=Get-Sha $groundSource})}
  }
  Write-DurableJson $manifestPath $manifest
  $candidateSealPath=Join-Path $root 'final_seal.json'
  Write-DurableJson $candidateSealPath ([pscustomobject][ordered]@{
    schema='vc-lora-r19-candidate-final-seal-v1';artifact_id=$artifactId
    result='PASS';runtime_fail_diagnostics_enabled=$true
    acceptance_eligible=$false;acceptance_authorized=$false
    deployment_authorized=$false
    candidate_manifest_sha256=Get-Sha $manifestPath})
  Write-DurableBytes (Join-Path $root 'final_seal.sha256') $utf8.GetBytes(
      ((Get-Sha $candidateSealPath)+' *final_seal.json'+$newline))
  $handoffPath=Join-Path $root 'handoff.json'
  Write-DurableJson $handoffPath ([pscustomobject][ordered]@{
    schema='vc-lora-r19-candidate-artifact-handoff-v1'
    artifact_id=$artifactId;result='PASS'
    runtime_fail_diagnostics_enabled=$true;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$false
    artifact_root=Get-RepoRelativePath $root
    candidate_manifest=[pscustomobject]@{path=Get-RepoRelativePath $manifestPath
      sha256=Get-Sha $manifestPath}
    final_seal=[pscustomobject]@{path=Get-RepoRelativePath $candidateSealPath
      sha256=Get-Sha $candidateSealPath}})
  Write-DurableBytes (Join-Path $root 'handoff.sha256') $utf8.GetBytes(
      ((Get-Sha $handoffPath)+' *handoff.json'+$newline))
  $latestPath=Join-Path $base 'latest.json'
  Write-DurableJson $latestPath ([pscustomobject][ordered]@{
    schema='vc-lora-r19-candidate-artifact-latest-v1';result='PASS'
    runtime_fail_diagnostics_enabled=$true;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$false
    artifact_id=$artifactId;artifact_root=Get-RepoRelativePath $root
    handoff=[pscustomobject]@{path=Get-RepoRelativePath $handoffPath
      sha256=Get-Sha $handoffPath}
    candidate_manifest=[pscustomobject]@{path=Get-RepoRelativePath $manifestPath
      sha256=Get-Sha $manifestPath}
    final_seal=[pscustomobject]@{path=Get-RepoRelativePath $candidateSealPath
      sha256=Get-Sha $candidateSealPath}})
  Write-DurableBytes (Join-Path $base 'latest.sha256') $utf8.GetBytes(
      ((Get-Sha $latestPath)+' *latest.json'+$newline))
  $flashPath=Join-Path $flashRoot 'flash_record.json'
  Write-DurableJson $flashPath ([pscustomobject][ordered]@{
    schema='vc-lora-r19-candidate-flash-evidence-v1';result='PASS'
    status=$DiagnosticFlashStatus;runtime_fail_diagnostics_enabled=$true
    acceptance_eligible=$false;acceptance_authorized=$false
    deployment_authorized=$false;one_run_hil_authorized=$true
    authorization=[pscustomobject]@{scope=$DiagnosticAuthorizationScope
      reusable=$false;deployment_authorization=$false
      attestation_sha256=Get-ByteSha $utf8.GetBytes($DiagnosticAuthorizationToken)}
    next_required_action=$DiagnosticNextAction
    candidate=[pscustomobject]@{latest_sha256=Get-Sha $latestPath
      handoff_sha256=Get-Sha $handoffPath
      candidate_manifest_sha256=Get-Sha $manifestPath
      candidate_final_seal_sha256=Get-Sha $candidateSealPath}
    roles=@(
      [pscustomobject]@{role='vehicle';port='COM3';sha256=Get-Sha $vehicleApp
        write_pass=$true;verify_pass=$true;reenumeration_pass=$true},
      [pscustomobject]@{role='ground';port='COM6';sha256=Get-Sha $groundApp
        write_pass=$true;verify_pass=$true;reenumeration_pass=$true})})
  $flashSealPath=Join-Path $flashRoot 'final_seal.json'
  Write-DurableJson $flashSealPath ([pscustomobject][ordered]@{
    schema='vc-lora-r19-candidate-flash-final-seal-v1';result='PASS'
    status=$DiagnosticFlashStatus;flash_record_sha256=Get-Sha $flashPath
    final_seal_sha256=Get-Sha $candidateSealPath
    runtime_fail_diagnostics_enabled=$true;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$false
    one_run_hil_authorized=$true
    hil_authorization_token=$DiagnosticAuthorizationToken
    authorization_scope=$DiagnosticAuthorizationScope
    next_required_action=$DiagnosticNextAction})
  Write-DurableBytes (Join-Path $flashRoot 'final_seal.sha256') `
      $utf8.GetBytes((Get-Sha $flashSealPath)+' *final_seal.json'+$newline)
  [pscustomobject]@{base=$base;handoff=$handoffPath;flash=$flashPath}
}

function Invoke-OfflineSelfTest {
  $tests=[Collections.ArrayList]::new()
  function Add-Test([string]$Name,[bool]$Pass,[string]$Detail){
    [void]$tests.Add([pscustomobject]@{name=$Name
      result=if($Pass){'PASS'}else{'FAIL'};detail=$Detail})}
  $fixture=New-OfflineDiagnosticArtifactChain
  $validatedChain=Get-CandidateProvenance $fixture.handoff $fixture.flash `
      $fixture.base
  Add-Test 'diagnostic_chain_latest_and_inputs_pinned' (
      [bool]$validatedChain.runtime_fail_diagnostics_enabled-and
      -not[bool]$validatedChain.acceptance_eligible-and
      -not[bool]$validatedChain.deployment_authorized-and
      [bool]$validatedChain.flash_readback_verified-and
      @($validatedChain.pinned_inputs).Count-eq11-and
      @($validatedChain.pinned_inputs|Where-Object{
        $_.name-ceq'candidate.latest.json'}).Count-eq1-and
      @($validatedChain.pinned_inputs|Where-Object{
        $_.name-ceq'flash.final_seal.sha256'}).Count-eq1-and
      @($validatedChain.pinned_inputs|Where-Object{
        $_.name-ceq'core.mavlink_frame.cpp'}).Count-eq1) `
      'latest chain and eleven immutable inputs are validated before COM open'
  $provenance=New-OfflineProvenance
  $ground=New-DiagnosticParser 'ground';$vehicle=New-DiagnosticParser 'vehicle'
  [byte[]]$groundBytes=New-SyntheticFrame 'G' 1
  [byte[]]$vehicleBytes=New-SyntheticFrame 'V' 2
  Add-DiagnosticBytes $ground $groundBytes 1000
  Add-DiagnosticBytes $vehicle $vehicleBytes 1000
  $groundDecoded=Convert-R19Diagnostic $ground.frames[0] 'G' $provenance
  $vehicleDecoded=Convert-R19Diagnostic $vehicle.frames[0] 'V' $provenance
  Write-DurableBytes (Join-Path $evidence 'offline_raw\ground.r19f.bin') $groundBytes
  Write-DurableBytes (Join-Path $evidence 'offline_raw\vehicle.r19f.bin') $vehicleBytes
  $vehicleFrameLeaf=Get-DiagnosticFrameLeaf 'vehicle' 1
  $groundFrameLeaf=Get-DiagnosticFrameLeaf 'ground' 1
  Write-DurableBytes (Join-Path $evidence `
      ('offline_raw\'+$vehicleFrameLeaf)) $vehicleBytes
  Write-DurableBytes (Join-Path $evidence `
      ('offline_raw\'+$groundFrameLeaf)) $groundBytes
  Add-Test 'diagnostic_frame_filename_ordinal_contract' (
      $vehicleFrameLeaf -ceq 'vehicle.frame-000001.bin' -and
      $groundFrameLeaf -ceq 'ground.frame-000001.bin' -and
      (Get-DiagnosticFrameLeaf 'vehicle' 2) -ceq
        'vehicle.frame-000002.bin') `
      'Live capture frame filenames use positive six-digit ordinals without arithmetic on formatted text'
  Add-Test 'valid_ground_r19f_decode' ($groundDecoded.diagnostic_success-and
      $groundDecoded.role-ceq'ground'-and$groundDecoded.source_line-eq466) `
      'Ground frame decodes with role/source binding'
  Add-Test 'valid_vehicle_r19f_decode' ($vehicleDecoded.diagnostic_success-and
      $vehicleDecoded.role-ceq'vehicle'-and$vehicleDecoded.source_line-eq466) `
      'Vehicle frame decodes with role/source binding'
  $groundAliveParser=New-DiagnosticParser 'ground_alive'
  $vehicleAliveParser=New-DiagnosticParser 'vehicle_alive'
  [byte[]]$groundArmedBytes=New-SyntheticAliveFrame 'G' 10 'A' 1 1000
  [byte[]]$groundAliveBytes=New-SyntheticAliveFrame 'G' 11 'L' 2 2000
  [byte[]]$vehicleArmedBytes=New-SyntheticAliveFrame 'V' 20 'A' 1 1100
  [byte[]]$vehicleAliveBytes=New-SyntheticAliveFrame 'V' 21 'L' 2 2100
  Add-DiagnosticBytes $groundAliveParser $groundArmedBytes 1000
  Add-DiagnosticBytes $groundAliveParser $groundAliveBytes 2000
  Add-DiagnosticBytes $vehicleAliveParser $vehicleArmedBytes 1100
  Add-DiagnosticBytes $vehicleAliveParser $vehicleAliveBytes 2100
  $groundArmed=Convert-R19Diagnostic $groundAliveParser.frames[0] 'G' $provenance
  $groundAlive=Convert-R19Diagnostic $groundAliveParser.frames[1] 'G' $provenance
  $vehicleArmed=Convert-R19Diagnostic $vehicleAliveParser.frames[0] 'V' $provenance
  $vehicleAlive=Convert-R19Diagnostic $vehicleAliveParser.frames[1] 'V' $provenance
  Write-DurableBytes (Join-Path $evidence `
      'offline_raw\ground.r19a-armed.bin') $groundArmedBytes
  Write-DurableBytes (Join-Path $evidence `
      'offline_raw\ground.r19a-alive.bin') $groundAliveBytes
  Write-DurableBytes (Join-Path $evidence `
      'offline_raw\vehicle.r19a-armed.bin') $vehicleArmedBytes
  Write-DurableBytes (Join-Path $evidence `
      'offline_raw\vehicle.r19a-alive.bin') $vehicleAliveBytes
  Add-Test 'valid_ground_r19a_armed_decode' (
      $groundArmed.diagnostic_success-and
      $groundArmed.diagnostic_kind-ceq'R19A'-and
      $groundArmed.beacon_state-ceq'ARMED'-and
      $groundArmed.diagnostic_ordinal-eq1-and
      $groundArmed.source_mapping_verified) `
      'Ground ARMED beacon has strict identity, role and source provenance'
  Add-Test 'valid_ground_r19a_alive_decode' (
      $groundAlive.diagnostic_success-and
      $groundAlive.beacon_state-ceq'ALIVE'-and
      $groundAlive.diagnostic_ordinal-eq2-and
      $groundAlive.monotonic_ms-eq2000) `
      'Ground ALIVE beacon decodes exact ordinal/time/status fields'
  Add-Test 'valid_vehicle_r19a_armed_decode' (
      $vehicleArmed.diagnostic_success-and
      $vehicleArmed.role-ceq'vehicle'-and
      $vehicleArmed.beacon_state-ceq'ARMED') `
      'Vehicle ARMED beacon is bound to COM3 role provenance'
  Add-Test 'valid_vehicle_r19a_alive_decode' (
      $vehicleAlive.diagnostic_success-and
      $vehicleAlive.role_code-ceq'V'-and
      $vehicleAlive.beacon_state-ceq'ALIVE') `
      'Vehicle ALIVE beacon is bound to COM3 role provenance'
  $badAliveParser=New-DiagnosticParser 'bad_alive'
  Add-DiagnosticBytes $badAliveParser `
      (New-SyntheticAliveFrame 'G' 30 'L' 3 3000 -CorruptCrc) 3000
  $badAlive=Convert-R19Diagnostic $badAliveParser.frames[0] 'G' $provenance
  Add-Test 'r19a_bad_crc_not_success' ($badAlive.candidate-and
      -not$badAlive.diagnostic_success-and$badAlive.failure-match'bad_crc') `
      'R19A bad CRC remains invalid diagnostic evidence'
  $badPaddingParser=New-DiagnosticParser 'bad_padding'
  Add-DiagnosticBytes $badPaddingParser `
      (New-SyntheticAliveFrame 'G' 31 'L' 3 3000 -BadPadding) 3000
  $badPadding=Convert-R19Diagnostic $badPaddingParser.frames[0] 'G' $provenance
  Add-Test 'r19a_bad_padding_not_success' ($badPadding.candidate-and
      -not$badPadding.diagnostic_success-and$badPadding.failure-match'format') `
      'R19A must contain exactly three trailing NUL bytes'
  $badSeverityParser=New-DiagnosticParser 'bad_severity'
  Add-DiagnosticBytes $badSeverityParser `
      (New-SyntheticAliveFrame 'G' 32 'L' 3 3000 -Severity 2) 3000
  $badSeverity=Convert-R19Diagnostic $badSeverityParser.frames[0] 'G' `
      $provenance
  Add-Test 'r19a_wrong_severity_not_success' ($badSeverity.candidate-and
      -not$badSeverity.diagnostic_success-and
      $badSeverity.failure-match'severity') `
      'R19A requires STATUSTEXT INFO severity 6'
  $roleMismatch=Convert-R19Diagnostic $groundAliveParser.frames[1] 'V' `
      $provenance
  Add-Test 'r19a_role_mismatch_not_success' ($roleMismatch.candidate-and
      -not$roleMismatch.diagnostic_success-and
      $roleMismatch.failure-match'port_role_mismatch') `
      'R19A role must match the physical COM role'
  $aliveSourceMismatch=Convert-R19Diagnostic `
      $groundAliveParser.frames[1] 'G' (New-OfflineProvenance -Mismatch)
  Add-Test 'r19a_source_hash_mismatch_not_success' (
      $aliveSourceMismatch.candidate-and
      -not$aliveSourceMismatch.diagnostic_success-and
      $aliveSourceMismatch.failure-match'source_hash_mismatch') `
      'R19A role source and flashed application provenance remain bound'
  $aliveSet=@($groundArmed,$groundAlive,$vehicleArmed,$vehicleAlive)
  $nonMonotonic=($aliveSet|ConvertTo-Json -Depth 8|ConvertFrom-Json)
  $nonMonotonic[1].diagnostic_ordinal=0
  Add-Test 'r19a_sequence_time_monotonic' (
      (Test-R19AliveMonotonic $aliveSet)-and
      -not(Test-R19AliveMonotonic $nonMonotonic)) `
      'Per-role R19A diagnostic ordinal and monotonic time strictly increase'
  $sameReadOrdered=@(
    ($groundArmed|Select-Object *)
    ($groundAlive|Select-Object *)
  )
  $sameReadOrdered[0].complete_us=[int64]5000
  $sameReadOrdered[1].complete_us=[int64]5000
  $sameReadReversed=@($sameReadOrdered[1],$sameReadOrdered[0])
  Add-Test 'r19a_same_read_capture_order_monotonic' (
      (Test-R19AliveMonotonic $sameReadOrdered)-and
      -not(Test-R19AliveMonotonic $sameReadReversed)) `
      'Equal completion timestamps preserve parser arrival order for monotonic checks'
  $productParser=New-DiagnosticParser 'valid_product'
  Add-DiagnosticBytes $productParser (New-SyntheticProductFrame 40) 4000
  $badProductParser=New-DiagnosticParser 'bad_product'
  Add-DiagnosticBytes $badProductParser `
      (New-SyntheticProductFrame 41 -CorruptCrc) 4100
  Add-Test 'valid_non_diagnostic_crc_counted_as_product_traffic' (
      $productParser.frames.Count-eq1-and$productParser.frames[0].valid-and
      $productParser.frames[0].message_id-eq0-and
      $productParser.valid_frames-eq1-and
      (Test-DiagnosticParserClean $productParser)) `
      'Only a recognized CRC-valid MAVLink2 frame proves product traffic'
  Add-Test 'bad_crc_non_diagnostic_not_product_traffic' (
      $badProductParser.frames.Count-eq1-and
      -not$badProductParser.frames[0].valid-and
      $badProductParser.frames[0].failure-ceq'bad_crc'-and
      $badProductParser.valid_frames-eq0-and$badProductParser.bad_crc-eq1) `
      'A complete non-diagnostic frame with bad CRC is parser corruption, not traffic'
  $noiseParser=New-DiagnosticParser 'noise'
  Add-DiagnosticBytes $noiseParser ([byte[]](0x01,0x02)) 4200
  $noiseClass=Get-R19DiagnosticClassification $aliveSet 1 $true `
      (Test-DiagnosticParserClean $noiseParser) $true
  $noiseSnapshot=Get-DiagnosticParserSnapshot $noiseParser
  Add-Test 'parser_noise_strict_failure' (
      $noiseSnapshot.noise_bytes-eq2-and$noiseSnapshot.partial_bytes-eq0-and
      $noiseClass.result-ceq'FAIL'-and
      $noiseClass.status-ceq'FAIL_PARSER_CORRUPTION') `
      'Noise bytes are persisted and make runtime evidence fail closed'
  $partialParser=New-DiagnosticParser 'partial'
  Add-DiagnosticBytes $partialParser ([byte[]](0xFD,0x09,0x00)) 4300
  $partialClass=Get-R19DiagnosticClassification $aliveSet 1 $true `
      (Test-DiagnosticParserClean $partialParser) $true
  $partialSnapshot=Get-DiagnosticParserSnapshot $partialParser
  Add-Test 'parser_partial_strict_failure' (
      $partialSnapshot.noise_bytes-eq0-and
      $partialSnapshot.partial_bytes-eq3-and
      $partialClass.result-ceq'FAIL'-and
      $partialClass.status-ceq'FAIL_PARSER_CORRUPTION') `
      'Trailing partial MAVLink bytes are persisted and make evidence fail closed'
  $repeatSet=[Collections.ArrayList]::new()
  $repeatInputs=@(
    [pscustomobject]@{sequence=[byte]50;complete_us=[int64]1000000}
    [pscustomobject]@{sequence=[byte]51;complete_us=[int64]2000000}
    [pscustomobject]@{sequence=[byte]52;complete_us=[int64]3000000}
  )
  foreach($input in $repeatInputs){
    $repeatParser=New-DiagnosticParser ('repeat_'+$input.sequence)
    Add-DiagnosticBytes $repeatParser `
        (New-SyntheticFrame 'G' ([byte]$input.sequence)) `
        ([int64]$input.complete_us)
    [void]$repeatSet.Add((Convert-R19Diagnostic $repeatParser.frames[0] `
        'G' $provenance))
  }
  $repeatExact=Test-R19FailureRepeatContract @($repeatSet)
  Add-Test 'r19f_repeat_exact_snapshot' (
      $repeatExact.valid-and
      @($repeatExact.roles|Where-Object{$_.role_code-ceq'G'})[0].count-eq3-and
      @($repeatExact.roles|Where-Object{
        $_.role_code-ceq'G'})[0].immutable_snapshot) `
      'Repeated R19F frames preserve one immutable logical first-failure snapshot'
  Add-Test 'r19f_repeat_sequence_may_advance' (
      $repeatExact.valid-and
      @($repeatSet|ForEach-Object{$_.mavlink_sequence}|
        Sort-Object -Unique).Count-eq3-and
      @($repeatSet|ForEach-Object{$_.raw_sha256}|
        Sort-Object -Unique).Count-eq3) `
      'MAVLink sequence, CRC and raw SHA may advance across valid R19F repeats'
  $mutatedParser=New-DiagnosticParser 'repeat_mutated_source_line'
  Add-DiagnosticBytes $mutatedParser `
      (New-SyntheticFrame 'G' 53 '01D3') 2000000
  $mutatedDecoded=Convert-R19Diagnostic $mutatedParser.frames[0] 'G' $provenance
  $mutatedSet=@($repeatSet[0],$mutatedDecoded)
  $repeatMutation=Test-R19FailureRepeatContract $mutatedSet
  $mutationClass=Get-R19DiagnosticClassification $mutatedSet 0 $true $true `
      ([bool]$repeatMutation.valid)
  Add-Test 'r19f_repeat_mutation_rejected' (
      -not$repeatMutation.valid-and$mutationClass.result-ceq'FAIL'-and
      $mutationClass.status-ceq'FAIL_INVALID_R19F_REPEAT') `
      'A changed repeated R19F snapshot is invalid diagnostic evidence'
  $overLimit=[Collections.ArrayList]::new()
  for($i=0;$i-lt121;++$i){
    $copy=$groundDecoded|Select-Object *
    $copy.complete_us=[int64]1000000+([int64]$i*1000000)
    [void]$overLimit.Add($copy)
  }
  $repeatLimit=Test-R19FailureRepeatContract @($overLimit)
  $groundLimit=@($repeatLimit.roles|Where-Object{$_.role_code-ceq'G'})[0]
  Add-Test 'r19f_repeat_count_bound' (
      -not$repeatLimit.valid-and
      -not[bool]$groundLimit.within_repeat_limit) `
      'R19F is bounded to at most 120 physical-flush-committed frames per role'
  $badCadence=@(
    ($repeatSet[0]|Select-Object *)
    ($repeatSet[1]|Select-Object *)
  )
  $badCadence[0].complete_us=[int64]1000000
  $badCadence[1].complete_us=[int64]1100000
  $repeatCadenceBad=Test-R19FailureRepeatContract $badCadence
  Add-Test 'r19f_repeat_cadence_sanity' (
      $repeatExact.valid-and
      @($repeatExact.roles|Where-Object{
        $_.role_code-ceq'G'})[0].cadence_sane-and
      -not$repeatCadenceBad.valid) `
      'Available capture timestamps enforce a basic 0.5..1.5 s repeat cadence'
  [byte[]]$coalescedBytes=(New-SyntheticFrame 'G' 60)+
      (New-SyntheticFrame 'G' 61)
  $coalescedSerial=New-OfflineBufferedSerial $coalescedBytes
  $coalescedParser=New-DiagnosticParser 'coalesced_startup_drain'
  $coalescedRaw=[IO.MemoryStream]::new()
  [int64]$coalescedLast=-1;[int64]$coalescedGap=0
  $coalescedReadState=[pscustomobject]@{read_batch_id=[int64]0
    initial_drain_bytes=[int64]-1;initial_drain_remaining=[int64]-1}
  $coalescedNow={return [int64]5000}
  [void](Read-DiagnosticSerial $coalescedSerial $coalescedParser `
      $coalescedRaw ([Diagnostics.Stopwatch]::new()) `
      ([ref]$coalescedLast) ([ref]$coalescedGap) $coalescedNow `
      $coalescedReadState)
  $coalescedMetadataPass=$coalescedParser.frames.Count-eq2-and
      @($coalescedParser.frames|Where-Object{
        $null-eq$_.PSObject.Properties['read_batch_id']-or
        $null-eq$_.PSObject.Properties['capture_origin']-or
        [int64]$_.read_batch_id-ne1-or
        [string]$_.capture_origin-cne'STARTUP_DRAIN'
      }).Count-eq0
  Add-Test 'serial_read_batch_identity_preserved' $coalescedMetadataPass `
      'Every completed frame preserves the identity and origin of its Serial.Read batch'
  [byte[]]$snapshotInitial=New-SyntheticFrame 'G' 62
  [byte[]]$snapshotLate=New-SyntheticFrame 'G' 63
  $snapshotSerial=[pscustomobject][ordered]@{
    data=[byte[]]($snapshotInitial.Clone());offset=0;late=$snapshotLate
    appended=$false;read_calls=0;maximum_requested=0
  }
  $snapshotSerial|Add-Member ScriptProperty BytesToRead {
    return [int]($this.data.Length-$this.offset)
  }
  $snapshotSerial|Add-Member ScriptMethod Read {
    param([byte[]]$Buffer,[int]$BufferOffset,[int]$Count)
    [int]$available=$this.data.Length-$this.offset
    [int]$take=[math]::Min($Count,$available)
    if($take-le0){return 0}
    [Array]::Copy($this.data,$this.offset,$Buffer,$BufferOffset,$take)
    $this.offset+=$take;$this.read_calls++
    if($Count-gt$this.maximum_requested){$this.maximum_requested=$Count}
    if(-not$this.appended){
      [byte[]]$expanded=New-Object byte[] ($this.data.Length+$this.late.Length)
      [Array]::Copy($this.data,0,$expanded,0,$this.data.Length)
      [Array]::Copy($this.late,0,$expanded,$this.data.Length,$this.late.Length)
      $this.data=$expanded;$this.appended=$true
    }
    return $take
  }
  $snapshotParser=New-DiagnosticParser 'startup_snapshot_boundary'
  $snapshotRaw=[IO.MemoryStream]::new()
  [int64]$snapshotLast=-1;[int64]$snapshotGap=0
  $snapshotReadState=[pscustomobject]@{read_batch_id=[int64]0
    initial_drain_bytes=[int64]-1;initial_drain_remaining=[int64]-1}
  [void](Read-DiagnosticSerial $snapshotSerial $snapshotParser $snapshotRaw `
      ([Diagnostics.Stopwatch]::new()) ([ref]$snapshotLast) `
      ([ref]$snapshotGap) $coalescedNow $snapshotReadState)
  $startupSnapshotHeld=$snapshotParser.frames.Count-eq1-and
      $snapshotSerial.BytesToRead-eq63-and
      $snapshotReadState.initial_drain_bytes-eq63-and
      $snapshotReadState.initial_drain_remaining-eq0-and
      [string]$snapshotParser.frames[0].capture_origin-ceq'STARTUP_DRAIN'
  [void](Read-DiagnosticSerial $snapshotSerial $snapshotParser $snapshotRaw `
      ([Diagnostics.Stopwatch]::new()) ([ref]$snapshotLast) `
      ([ref]$snapshotGap) $coalescedNow $snapshotReadState)
  Add-Test 'startup_drain_uses_one_time_byte_snapshot' (
      $startupSnapshotHeld-and$snapshotParser.frames.Count-eq2-and
      $snapshotSerial.BytesToRead-eq0-and
      [string]$snapshotParser.frames[1].capture_origin-ceq'LIVE'-and
      [int64]$snapshotParser.frames[1].read_batch_id-eq2) `
      'The first service snapshots startup bytes once and never absorbs later LIVE arrivals'
  $snapshotRaw.Dispose()
  $startupThenLive=[Collections.ArrayList]::new()
  foreach($input in @(
      [pscustomobject]@{sequence=[byte]70;complete_us=[int64]5000
        read_batch_id=[int64]1;capture_origin='STARTUP_DRAIN'},
      [pscustomobject]@{sequence=[byte]71;complete_us=[int64]5000
        read_batch_id=[int64]1;capture_origin='STARTUP_DRAIN'},
      [pscustomobject]@{sequence=[byte]72;complete_us=[int64]1000000
        read_batch_id=[int64]2;capture_origin='LIVE'},
      [pscustomobject]@{sequence=[byte]73;complete_us=[int64]2000000
        read_batch_id=[int64]3;capture_origin='LIVE'},
      [pscustomobject]@{sequence=[byte]74;complete_us=[int64]3000000
        read_batch_id=[int64]4;capture_origin='LIVE'})){
    $parser=New-DiagnosticParser ('startup_then_live_'+$input.sequence)
    Add-DiagnosticBytes $parser (New-SyntheticFrame 'G' $input.sequence) `
        $input.complete_us
    $decoded=Convert-R19Diagnostic $parser.frames[0] 'G' $provenance
    $decoded.read_batch_id=$input.read_batch_id
    $decoded.capture_origin=$input.capture_origin
    [void]$startupThenLive.Add($decoded)
  }
  $startupThenLiveContract=Test-R19FailureRepeatContract @($startupThenLive)
  $startupThenLiveGround=@($startupThenLiveContract.roles|Where-Object{
      $_.role_code-ceq'G'})[0]
  Add-Test 'r19f_startup_coalescing_cadence_unobservable' (
      $startupThenLiveContract.valid-and
      [int]$startupThenLiveGround.unobservable_interval_count-eq2-and
      [int]$startupThenLiveGround.observable_interval_count-eq2-and
      $startupThenLiveGround.cadence_sane) `
      'Startup-drain coalescing is explicit observer-unmeasurable cadence evidence'
  $startupSpanning=@(
    ($startupThenLive[0]|Select-Object *)
    ($startupThenLive[2]|Select-Object *)
    ($startupThenLive[3]|Select-Object *)
    ($startupThenLive[4]|Select-Object *)
  )
  $startupSpanning[0].capture_origin='LIVE'
  $startupSpanning[0].start_capture_origin='STARTUP_DRAIN'
  for($i=0;$i-lt$startupSpanning.Count;++$i){
    $startupSpanning[$i].mavlink_sequence=70+$i
  }
  $startupSpanningContract=Test-R19FailureRepeatContract $startupSpanning
  $startupSpanningGround=@($startupSpanningContract.roles|Where-Object{
      $_.role_code-ceq'G'})[0]
  Add-Test 'r19f_startup_spanning_frame_cadence_unobservable' (
      $startupSpanningContract.valid-and
      $startupSpanningGround.unobservable_interval_count-eq1-and
      $startupSpanningGround.observable_interval_count-eq2) `
      'A frame started in the startup snapshot stays cadence-unobservable when completed LIVE'
  $liveCoalesced=@(
    ($startupThenLive[2]|Select-Object *)
    ($startupThenLive[3]|Select-Object *)
  )
  $liveCoalesced[0].complete_us=[int64]3000000
  $liveCoalesced[1].complete_us=[int64]3000000
  $liveCoalesced[1].read_batch_id=[int64]2
  $liveCoalesced[0].capture_origin='LIVE'
  $liveCoalesced[1].capture_origin='LIVE'
  $liveCoalescedContract=Test-R19FailureRepeatContract $liveCoalesced
  Add-Test 'r19f_live_coalescing_still_rejected' (
      -not$liveCoalescedContract.valid-and
      -not@($liveCoalescedContract.roles|Where-Object{
        $_.role_code-ceq'G'})[0].cadence_sane) `
      'A zero-gap coalesced batch after startup drain remains fail-closed'
  $sequenceGap=@(
    ($startupThenLive[2]|Select-Object *)
    ($startupThenLive[3]|Select-Object *)
    ($startupThenLive[4]|Select-Object *)
  )
  $sequenceGap[1].mavlink_sequence=74
  $sequenceGap[2].mavlink_sequence=75
  $sequenceGapContract=Test-R19FailureRepeatContract $sequenceGap
  $sequenceWrap=@(
    ($startupThenLive[2]|Select-Object *)
    ($startupThenLive[3]|Select-Object *)
    ($startupThenLive[4]|Select-Object *)
  )
  $sequenceWrap[0].mavlink_sequence=254
  $sequenceWrap[1].mavlink_sequence=255
  $sequenceWrap[2].mavlink_sequence=0
  $sequenceWrapContract=Test-R19FailureRepeatContract $sequenceWrap
  $sequenceWrapGround=@($sequenceWrapContract.roles|Where-Object{
      $_.role_code-ceq'G'})[0]
  Add-Test 'r19f_repeat_sequence_contiguous_modulo_256' (
      -not$sequenceGapContract.valid-and
      -not@($sequenceGapContract.roles|Where-Object{
        $_.role_code-ceq'G'})[0].sequence_forward_contiguous-and
      $sequenceWrapContract.valid-and
      $null-ne$sequenceWrapGround.PSObject.Properties[
        'sequence_forward_contiguous']-and
      $sequenceWrapGround.sequence_forward_contiguous) `
      'Repeated R19F MAVLink sequence numbers must advance by one modulo 256'
  $tailDrainCommand=Get-Command Invoke-DiagnosticExactTailDrain `
      -CommandType Function -ErrorAction SilentlyContinue
  $terminalContractCommand=Get-Command Get-TerminalPartialContract `
      -CommandType Function -ErrorAction SilentlyContinue
  if($null-eq$tailDrainCommand-or$null-eq$terminalContractCommand){
    Add-Test 'terminal_exact_tail_drain_one_frame' $false `
        'Exact terminal drain helper is missing'
    Add-Test 'terminal_incomplete_tail_preserves_failure' $false `
        'Incomplete terminal drain contract helper is missing'
    Add-Test 'terminal_bad_crc_preserves_failure' $false `
        'Bad-CRC terminal drain contract helper is missing'
    Add-Test 'terminal_expected_next_frame_derivation' $false `
        'Expected-next R19F derivation helper is missing'
    Add-Test 'terminal_read_exception_distinct_failure' $false `
        'Terminal read-exception evidence helper is missing'
  }else{
    [byte[]]$tailFrame=New-SyntheticFrame 'G' 80
    $tailPriorParser=New-DiagnosticParser 'terminal_prior_r19f'
    $tailPriorDiagnostics=[Collections.ArrayList]::new()
    $tailPriorRaw=[IO.MemoryStream]::new()
    for($i=0;$i-lt3;++$i){
      [byte[]]$priorFrame=New-SyntheticFrame 'G' ([byte](77+$i))
      [int64]$priorUs=[int64](36000000+($i*1000000))
      Add-DiagnosticBytes $tailPriorParser $priorFrame $priorUs (7+$i) 'LIVE'
      $tailPriorRaw.Write($priorFrame,0,$priorFrame.Length)
      [void]$tailPriorDiagnostics.Add((Convert-R19Diagnostic `
          $tailPriorParser.frames[$i] 'G' $provenance))
    }
    [byte[]]$derivedTailFrame=Get-ExpectedNextR19FailureFrame $tailPriorParser
    Add-Test 'terminal_expected_next_frame_derivation' (
        $null-ne$derivedTailFrame-and$derivedTailFrame.Length-eq63-and
        (Get-ByteSha $derivedTailFrame)-ceq(Get-ByteSha $tailFrame)) `
        'Expected terminal frame is derived byte-exactly from the prior immutable R19F snapshot and next sequence'
    [byte[]]$tailPrefix=New-Object byte[] 32
    [Array]::Copy($tailFrame,0,$tailPrefix,0,$tailPrefix.Length)
    [byte[]]$tailAndSentinel=New-Object byte[] 32
    [Array]::Copy($tailFrame,32,$tailAndSentinel,0,31)
    $tailAndSentinel[31]=0xA5
    $tailParser=New-DiagnosticParser 'terminal_exact'
    Add-DiagnosticBytes $tailParser $tailPrefix 39000000 10 'LIVE'
    $tailSerial=New-OfflineBufferedSerial $tailAndSentinel
    $tailRaw=[IO.MemoryStream]::new()
    $tailRaw.Write($tailPrefix,0,$tailPrefix.Length)
    $tailReadState=[pscustomobject]@{read_batch_id=[int64]10
      initial_drain_bytes=[int64]0;initial_drain_remaining=[int64]0}
    $tailNowState=[pscustomobject]@{now_us=[int64]40000000}
    $tailNow={$tailNowState.now_us}.GetNewClosure()
    $tailDrain=Invoke-DiagnosticExactTailDrain $tailSerial $tailParser `
        $tailRaw ([Diagnostics.Stopwatch]::new()) $tailReadState `
        40100000 $tailNow 'G' 80 $tailFrame
    $tailState=[pscustomobject]@{spec=[pscustomobject]@{
        code='G';role='ground';port='OFFLINE'}
      parser=$tailParser;tail_drain=$tailDrain
      diagnostics=@($tailPriorDiagnostics)}
    $tailContract=Get-TerminalPartialContract @($tailState) $true
    Add-Test 'terminal_exact_tail_drain_one_frame' (
        $tailDrain.valid-and$tailDrain.drain_attempted-and
        $tailDrain.drain_completed-and$tailDrain.bytes_required-eq31-and
        $tailDrain.bytes_read-eq31-and$tailSerial.BytesToRead-eq1-and
        $tailRaw.Length-eq63-and$tailParser.frames.Count-eq1-and
        $tailParser.partial_bytes-eq0-and
        $tailContract.started_frame-and$tailContract.header_known-and
        $tailContract.expected_size-eq63-and$tailContract.observed-eq63-and
        $tailContract.remaining-eq0-and
        $tailContract.prefix_is_source_bound_r19f-and
        $tailContract.role_matches_port-and
        $tailContract.mavlink_sequence-eq80-and
        $tailContract.expected_next_sequence-eq80-and
        $tailContract.sequence_matches_next-and
        $tailContract.byte_exact_expected_next_r19f_prefix-and
        $tailContract.result-ceq'COMPLETED'-and
        (Get-ByteSha $tailRaw.ToArray())-ceq(Get-ByteSha $tailFrame)-and
        [int64]$tailParser.frames[0].read_batch_id-eq11-and
        [string]$tailParser.frames[0].capture_origin-ceq'TERMINAL_TAIL'-and
        $tailContract.valid-and$tailContract.drain_attempted-and
        $tailContract.drain_completed-and-not$tailContract.only_parser_defect) `
        'Terminal drain consumes exactly the missing bytes of one preexisting frame and no next byte'
    $tailRaw.Dispose()
    $incompleteParser=$tailPriorParser
    Add-DiagnosticBytes $incompleteParser $tailPrefix 39000000 20 'LIVE'
    [byte[]]$shortTail=New-Object byte[] 7
    [Array]::Copy($tailFrame,32,$shortTail,0,$shortTail.Length)
    $incompleteSerial=New-OfflineBufferedSerial $shortTail
    $incompleteRaw=[IO.MemoryStream]::new()
    [byte[]]$priorRawBytes=$tailPriorRaw.ToArray()
    $incompleteRaw.Write($priorRawBytes,0,$priorRawBytes.Length)
    $incompleteRaw.Write($tailPrefix,0,$tailPrefix.Length)
    $incompleteReadState=[pscustomobject]@{read_batch_id=[int64]20
      initial_drain_bytes=[int64]0;initial_drain_remaining=[int64]0}
    $incompleteNowState=[pscustomobject]@{now_us=[int64]40000000}
    $incompleteNow={
      $incompleteNowState.now_us=[int64]$incompleteNowState.now_us+50000
      return $incompleteNowState.now_us
    }.GetNewClosure()
    $incompleteDrain=Invoke-DiagnosticExactTailDrain $incompleteSerial `
        $incompleteParser $incompleteRaw ([Diagnostics.Stopwatch]::new()) `
        $incompleteReadState 40100000 $incompleteNow 'G' 80 `
        $derivedTailFrame
    $incompleteState=[pscustomobject]@{
      spec=[pscustomobject]@{code='G';role='ground';port='OFFLINE'}
      parser=$incompleteParser;tail_drain=$incompleteDrain
      diagnostics=@($tailPriorDiagnostics)}
    $incompleteContract=Get-TerminalPartialContract @($incompleteState) $true
    $incompleteClass=Get-R19DiagnosticClassification `
        @($tailPriorDiagnostics) 0 $true `
        (Test-DiagnosticParserClean $incompleteParser) $true `
        $incompleteContract
    Add-Test 'terminal_incomplete_tail_preserves_failure' (
        $incompleteDrain.valid-and$incompleteDrain.drain_attempted-and
        -not$incompleteDrain.drain_completed-and
        $incompleteDrain.bytes_read-eq7-and
        $incompleteDrain.bytes_remaining-eq24-and
        $incompleteParser.partial_bytes-eq39-and
        -not(Test-DiagnosticParserClean $incompleteParser)-and
        $incompleteClass.classification-ceq'R19F_TERMINAL_PREFIX_STALL'-and
        $incompleteClass.status-ceq'FAIL_R19F_TERMINAL_PREFIX_STALL'-and
        $incompleteClass.result-ceq'FAIL'-and
        $incompleteContract.valid-and$incompleteContract.drain_attempted-and
        -not$incompleteContract.drain_completed-and
        $incompleteContract.only_parser_defect-and
        $incompleteContract.one_role_only-and
        $incompleteContract.prior_r19f_count-eq3-and
        $incompleteContract.all_other_parser_counters_zero-and
        $incompleteContract.started_frame-and
        $incompleteContract.header_known-and
        $incompleteContract.expected_size-eq63-and
        $incompleteContract.observed-eq39-and
        $incompleteContract.remaining-eq24-and
        $incompleteContract.prefix_is_source_bound_r19f-and
        $incompleteContract.role_matches_port-and
        $incompleteContract.mavlink_sequence-eq80-and
        $incompleteContract.expected_next_sequence-eq80-and
        $incompleteContract.sequence_matches_next-and
        $incompleteContract.partial_first_seen_us-eq39000000-and
        $incompleteContract.last_progress_us-eq40100000-and
        $incompleteContract.age_before_tail_us-eq1050000-and
        $null-ne$incompleteContract.PSObject.Properties[
          'last_progress_before_tail_us']-and
        $incompleteContract.last_progress_before_tail_us-eq39000000-and
        $incompleteContract.age_since_last_progress_before_tail_us-eq1050000-and
        $incompleteContract.raw_offset-eq189-and
        $incompleteContract.partial_bytes-eq39-and
        $incompleteContract.raw_bytes-eq228-and
        $incompleteContract.raw_suffix_exact-and
        $incompleteContract.terminal_offset_plus_length_equals_raw_bytes-and
        $incompleteContract.byte_exact_expected_next_r19f_prefix-and
        $incompleteContract.result-ceq'TIMEOUT_INCOMPLETE_SAME_FRAME') `
        'A bounded incomplete tail remains explicit parser corruption rather than a capture pass'
    $incompleteRaw.Dispose()
    [byte[]]$badTailFrame=New-SyntheticFrame 'G' 81 -CorruptCrc
    [byte[]]$badTailPrefix=New-Object byte[] 32
    [byte[]]$badTailBytes=New-Object byte[] 31
    [Array]::Copy($badTailFrame,0,$badTailPrefix,0,32)
    [Array]::Copy($badTailFrame,32,$badTailBytes,0,31)
    $badTailParser=New-DiagnosticParser 'terminal_bad_crc'
    Add-DiagnosticBytes $badTailParser $badTailPrefix 39000000 30 'LIVE'
    $badTailSerial=New-OfflineBufferedSerial $badTailBytes
    $badTailRaw=[IO.MemoryStream]::new()
    $badTailRaw.Write($badTailPrefix,0,$badTailPrefix.Length)
    $badTailReadState=[pscustomobject]@{read_batch_id=[int64]30
      initial_drain_bytes=[int64]0;initial_drain_remaining=[int64]0}
    $badTailNow={return [int64]40000000}
    [byte[]]$expectedGoodTailFrame=New-SyntheticFrame 'G' 81
    $badTailDrain=Invoke-DiagnosticExactTailDrain $badTailSerial `
        $badTailParser $badTailRaw ([Diagnostics.Stopwatch]::new()) `
        $badTailReadState 40100000 $badTailNow 'G' 81 `
        $expectedGoodTailFrame
    $badTailState=[pscustomobject]@{
      spec=[pscustomobject]@{code='G';role='ground';port='OFFLINE'}
      parser=$badTailParser;tail_drain=$badTailDrain
      diagnostics=@($tailPriorDiagnostics)}
    $badTailContract=Get-TerminalPartialContract @($badTailState) $true
    Add-Test 'terminal_bad_crc_preserves_failure' (
        $badTailDrain.drain_completed-and$badTailParser.bad_crc-eq1-and
        -not(Test-DiagnosticParserClean $badTailParser)-and
        $badTailContract.valid-and-not$badTailContract.only_parser_defect) `
        'Completing a bad-CRC tail preserves the independent parser defect'
    $badTailRaw.Dispose()
    $throwTailParser=New-DiagnosticParser 'terminal_read_exception'
    Add-DiagnosticBytes $throwTailParser $tailPrefix 39000000 40 'LIVE'
    $throwTailSerial=[pscustomobject]@{BytesToRead=31;read_calls=0}
    $throwTailSerial|Add-Member ScriptMethod Read {
      param([byte[]]$Buffer,[int]$BufferOffset,[int]$Count)
      $this.read_calls++
      throw 'injected terminal read failure'
    }
    $throwTailRaw=[IO.MemoryStream]::new()
    $throwTailRaw.Write($tailPrefix,0,$tailPrefix.Length)
    $throwTailReadState=[pscustomobject]@{read_batch_id=[int64]40
      initial_drain_bytes=[int64]0;initial_drain_remaining=[int64]0}
    $throwTailNow={return [int64]40000000}
    $throwTailDrain=Invoke-DiagnosticExactTailDrain $throwTailSerial `
        $throwTailParser $throwTailRaw ([Diagnostics.Stopwatch]::new()) `
        $throwTailReadState 40500000 $throwTailNow 'G' 80 `
        $derivedTailFrame
    $throwTailState=[pscustomobject]@{
      spec=[pscustomobject]@{code='G';role='ground';port='OFFLINE'}
      parser=$throwTailParser;tail_drain=$throwTailDrain
      diagnostics=@($tailPriorDiagnostics)}
    $throwTailContract=Get-TerminalPartialContract @($throwTailState) $true
    $throwTailClass=Get-R19DiagnosticClassification `
        @($tailPriorDiagnostics) 0 $true `
        (Test-DiagnosticParserClean $throwTailParser) $true `
        $throwTailContract
    Add-Test 'terminal_read_exception_distinct_failure' (
        $throwTailSerial.read_calls-eq1-and
        $throwTailDrain.result-ceq'READ_EXCEPTION'-and
        -not$throwTailDrain.no_read_exception-and
        $throwTailDrain.read_exception-cmatch'injected terminal read failure'-and
        -not$throwTailDrain.valid-and-not$throwTailContract.valid-and
        -not$throwTailContract.only_parser_defect-and
        $throwTailClass.classification-ceq'INVALID'-and
        $throwTailClass.status-ceq'FAIL_PARSER_CORRUPTION'-and
        $throwTailClass.result-ceq'FAIL') `
        'Serial read exceptions remain distinct from an exact same-frame timeout and fail closed'
    $throwTailRaw.Dispose()
    $tailPriorRaw.Dispose()
  }
  $noBeaconClass=Get-R19DiagnosticClassification @() 0 $true
  $aliveNoTrafficClass=Get-R19DiagnosticClassification $aliveSet 0 $true
  $aliveTrafficClass=Get-R19DiagnosticClassification $aliveSet 4 $true
  $r19fClass=Get-R19DiagnosticClassification `
      @($groundArmed,$groundAlive,$vehicleArmed,$vehicleAlive,$groundDecoded) `
      0 $true
  $partialAliveClass=Get-R19DiagnosticClassification @($groundAlive) 0 $true
  $invalidClass=Get-R19DiagnosticClassification `
      @($groundDecoded,$badAlive) 8 $true
  $armedOnlyClass=Get-R19DiagnosticClassification `
      @($groundArmed,$vehicleArmed) 0 $true
  Add-Test 'classification_no_beacon' (
      $noBeaconClass.classification-ceq'NO_BEACON'-and
      $noBeaconClass.status-ceq'FAIL_NO_DIAGNOSTIC_BEACON'-and
      $noBeaconClass.result-ceq'FAIL') `
      'No R19A/R19F evidence is distinguished as no beacon'
  Add-Test 'classification_alive_no_traffic' (
      $aliveNoTrafficClass.classification-ceq'ALIVE_NO_TRAFFIC'-and
      $aliveNoTrafficClass.status-ceq'PASS_ALIVE_BEACON_CAPTURED'-and
      $aliveNoTrafficClass.engineering_disposition-ceq
        'FAIL_ALIVE_NO_PRODUCT_TRAFFIC'-and
      $aliveNoTrafficClass.alive_role_coverage-ceq'BOTH'-and
      $aliveNoTrafficClass.result-ceq'PASS') `
      'Valid dual-role ALIVE is evidence PASS but product-traffic engineering fail'
  Add-Test 'classification_alive_with_product_traffic' (
      $aliveTrafficClass.classification-ceq'ALIVE_WITH_PRODUCT_TRAFFIC'-and
      $aliveTrafficClass.engineering_disposition-ceq
        'ADVISORY_ALIVE_WITH_PRODUCT_TRAFFIC'-and
      $aliveTrafficClass.result-ceq'PASS') `
      'Non-diagnostic complete MAVLink separates alive-with-traffic evidence'
  Add-Test 'classification_partial_alive_role' (
      $partialAliveClass.alive_role_coverage-ceq'PARTIAL'-and
      $partialAliveClass.engineering_disposition-ceq
        'PARTIAL_ALIVE_NO_PRODUCT_TRAFFIC'-and
      $partialAliveClass.result-ceq'PASS') `
      'Single-role ALIVE is captured as evidence but engineering remains PARTIAL'
  Add-Test 'classification_invalid_precedence' (
      $invalidClass.classification-ceq'INVALID'-and
      $invalidClass.status-ceq'FAIL_INVALID_RUNTIME_DIAGNOSTIC'-and
      $invalidClass.result-ceq'FAIL') `
      'Invalid candidate takes precedence over valid R19F and product traffic'
  Add-Test 'classification_armed_only_no_beacon' (
      $armedOnlyClass.classification-ceq'NO_BEACON'-and
      $armedOnlyClass.armed_count-eq2-and$armedOnlyClass.alive_count-eq0) `
      'ARMED without a periodic ALIVE frame does not prove runtime liveness'
  Add-Test 'classification_r19f' ($r19fClass.classification-ceq'R19F'-and
      $r19fClass.status-ceq'PASS_DIAGNOSTIC_CAPTURED'-and
      $r19fClass.engineering_disposition-ceq'RUNTIME_FAILURE_OBSERVED'-and
      $r19fClass.result-ceq'PASS') `
      'Valid R19F takes precedence over alive/product-traffic classification'
  $bad=New-DiagnosticParser 'bad';Add-DiagnosticBytes $bad `
      (New-SyntheticFrame 'G' 3 -CorruptCrc) 2000
  $badDecoded=Convert-R19Diagnostic $bad.frames[0] 'G' $provenance
  Add-Test 'bad_crc_not_success' ($badDecoded.candidate-and
      -not$badDecoded.diagnostic_success-and$badDecoded.failure-match'bad_crc') `
      'bad CRC is candidate failure, never diagnostic success'
  $mismatch=Convert-R19Diagnostic $ground.frames[0] 'G' `
      (New-OfflineProvenance -Mismatch)
  Add-Test 'source_hash_mismatch_not_success' ($mismatch.candidate-and
      -not$mismatch.diagnostic_success-and
      $mismatch.failure-match'source_hash_mismatch') `
      'source hash mismatch is fail-closed'
  $zeroLine=New-DiagnosticParser 'zero_line'
  Add-DiagnosticBytes $zeroLine (New-SyntheticFrame 'G' 4 '0000') 3000
  $zeroDecoded=Convert-R19Diagnostic $zeroLine.frames[0] 'G' $provenance
  Add-Test 'source_line_zero_not_success' ($zeroDecoded.candidate-and
      -not$zeroDecoded.diagnostic_success-and
      $zeroDecoded.failure-match'source_line_zero') `
      'source line zero cannot become successful diagnostic evidence'
  $missingFlagRejected=$false;$disabledFlagRejected=$false
  try{Assert-DiagnosticEnabledRecord ([pscustomobject]@{}) 'missing'}catch{
    $missingFlagRejected=$true}
  try{Assert-DiagnosticEnabledRecord ([pscustomobject]@{
    runtime_fail_diagnostics_enabled=$false;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$false}) 'disabled'}catch{
    $disabledFlagRejected=$true}
  Assert-DiagnosticEnabledRecord ([pscustomobject]@{
    runtime_fail_diagnostics_enabled=$true;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$false}) 'enabled'
  $missingDeploymentRejected=$false;$trueDeploymentRejected=$false
  try{Assert-DiagnosticEnabledRecord ([pscustomobject]@{
    runtime_fail_diagnostics_enabled=$true;acceptance_eligible=$false
    acceptance_authorized=$false}) 'missing_deployment'}catch{
    $missingDeploymentRejected=$true}
  try{Assert-DiagnosticEnabledRecord ([pscustomobject]@{
    runtime_fail_diagnostics_enabled=$true;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$true
  }) 'true_deployment'}catch{$trueDeploymentRejected=$true}
  Add-Test 'diagnostic_artifact_chain_requires_true' (
      $missingFlagRejected-and$disabledFlagRejected-and
      $missingDeploymentRejected-and$trueDeploymentRejected) `
      'manifest/handoff/seals/flash require explicit diagnostic=true'
  $validAuthorization=[pscustomobject][ordered]@{
    status=$DiagnosticFlashStatus;one_run_hil_authorized=$true
    authorization=[pscustomobject][ordered]@{
      scope=$DiagnosticAuthorizationScope;reusable=$false
      deployment_authorization=$false
      attestation_sha256=Get-ByteSha $utf8.GetBytes($DiagnosticAuthorizationToken)
    }
    next_required_action=$DiagnosticNextAction
  }
  Assert-DiagnosticFlashAuthorization $validAuthorization
  $wrongScope=($validAuthorization|ConvertTo-Json -Depth 8|ConvertFrom-Json)
  $wrongScope.authorization.scope='one immediate R19 physical acceptance run only'
  $scopeRejected=$false
  try{Assert-DiagnosticFlashAuthorization $wrongScope}catch{$scopeRejected=$true}
  $wrongStatus=($validAuthorization|ConvertTo-Json -Depth 8|ConvertFrom-Json)
  $wrongStatus.status='PASS_CANDIDATE_INSTALLED_HIL_ONE_RUN_ONLY'
  $statusRejected=$false
  try{Assert-DiagnosticFlashAuthorization $wrongStatus}catch{$statusRejected=$true}
  Add-Test 'diagnostic_scope_status_contract' (
      $scopeRejected-and$statusRejected) `
      'diagnostic flash exact status/scope/token/next action are fail-closed'
  $syntheticFlash=@(
    [pscustomobject]@{role='vehicle';port='COM3';sha256=('C'*64)
      write_pass=$true;verify_pass=$true;reenumeration_pass=$true},
    [pscustomobject]@{role='ground';port='COM6';sha256=('D'*64)
      write_pass=$true;verify_pass=$true;reenumeration_pass=$true})
  Add-Test 'flash_readback_binding_contract' (
      $syntheticFlash[0].role-ceq'vehicle'-and
      $syntheticFlash[0].port-ceq'COM3'-and$syntheticFlash[0].verify_pass-and
      $syntheticFlash[1].role-ceq'ground'-and
      $syntheticFlash[1].port-ceq'COM6'-and$syntheticFlash[1].verify_pass) `
      'diagnostic provenance remains bound to per-role write/read-back proof'
  Add-Test 'role_baud_contract' (
      [int]$portSpecs[0].baud-eq115200-and
      [int]$portSpecs[1].baud-eq57600) `
      'Vehicle COM3 is 115200 and Ground COM6 is 57600'
  $openSuccessSerial=[pscustomobject][ordered]@{open_calls=0}
  $openSuccessSerial|Add-Member ScriptMethod Open {
    $this.open_calls=[int]$this.open_calls+1
  }
  $openSuccessTimes=@(
    [DateTime]::new(2026,10,12,1,2,3,[DateTimeKind]::Utc),
    [DateTime]::new(2026,10,12,1,2,3,125,[DateTimeKind]::Utc)
  )
  $openSuccessClock=[pscustomobject]@{index=0;values=$openSuccessTimes}
  $openSuccessNow={
    $value=$openSuccessClock.values[$openSuccessClock.index]
    $openSuccessClock.index=[int]$openSuccessClock.index+1
    return $value
  }.GetNewClosure()
  $openSuccessEvidence=[pscustomobject][ordered]@{
    role='vehicle';port='COM3';serial_port_open_before_utc=$null
    serial_port_open_after_utc=$null;serial_port_open_duration_ms=$null
    result='NOT_ATTEMPTED';failure=$null
  }
  [void](Open-DiagnosticSerialPort $openSuccessSerial $openSuccessEvidence `
      $openSuccessNow)
  Add-Test 'serial_port_open_utc_evidence_success' (
      $openSuccessSerial.open_calls-eq1-and
      [string]$openSuccessEvidence.port-ceq'COM3'-and
      [string]$openSuccessEvidence.serial_port_open_before_utc-ceq
        $openSuccessTimes[0].ToString('o')-and
      [string]$openSuccessEvidence.serial_port_open_after_utc-ceq
        $openSuccessTimes[1].ToString('o')-and
      [double]$openSuccessEvidence.serial_port_open_duration_ms-eq125.0-and
      [string]$openSuccessEvidence.result-ceq'PASS'-and
      $null-eq$openSuccessEvidence.failure) `
      'COM3 evidence records exact UTC timestamps bracketing successful SerialPort.Open'
  $openFailureSerial=[pscustomobject][ordered]@{open_calls=0}
  $openFailureSerial|Add-Member ScriptMethod Open {
    $this.open_calls=[int]$this.open_calls+1
    throw 'injected serial open failure'
  }
  $openFailureTime=[DateTime]::new(
      2026,10,12,4,5,6,[DateTimeKind]::Utc)
  $openFailureNow={return $openFailureTime}.GetNewClosure()
  $openFailureEvidence=[pscustomobject][ordered]@{
    role='ground';port='COM6';serial_port_open_before_utc=$null
    serial_port_open_after_utc=$null;serial_port_open_duration_ms=$null
    result='NOT_ATTEMPTED';failure=$null
  }
  $openFailureCaught=$false
  try{
    [void](Open-DiagnosticSerialPort $openFailureSerial $openFailureEvidence `
        $openFailureNow)
  }catch{
    $openFailureCaught=$_.Exception.Message-match'injected serial open failure'
  }
  Add-Test 'serial_port_open_utc_evidence_failure' (
      $openFailureCaught-and$openFailureSerial.open_calls-eq1-and
      [string]$openFailureEvidence.port-ceq'COM6'-and
      [string]$openFailureEvidence.serial_port_open_before_utc-ceq
        $openFailureTime.ToString('o')-and
      $null-eq$openFailureEvidence.serial_port_open_after_utc-and
      $null-eq$openFailureEvidence.serial_port_open_duration_ms-and
      [string]$openFailureEvidence.result-ceq'FAIL'-and
      [string]$openFailureEvidence.failure-cmatch
        'injected serial open failure') `
      'COM6 failure evidence retains pre-Open UTC and leaves post-Open fields null'
  [byte[]]$vehicleLoad=New-Object byte[] ($PumpReadBudgetBytes*8+123)
  [byte[]]$groundLoad=New-Object byte[] ($PumpReadBudgetBytes*11+57)
  $pumpStates=@(
    [pscustomobject][ordered]@{
      role='vehicle';serial=New-OfflineBufferedSerial $vehicleLoad
      parser=New-DiagnosticParser 'offline_pump_vehicle'
      raw=[IO.MemoryStream]::new();last=[int64]-1;max_gap=[int64]0
      read_state=[pscustomobject]@{read_batch_id=[int64]0
        initial_drain_bytes=[int64]-1;initial_drain_remaining=[int64]-1}
      services=0;max_consumed=0
    },
    [pscustomobject][ordered]@{
      role='ground';serial=New-OfflineBufferedSerial $groundLoad
      parser=New-DiagnosticParser 'offline_pump_ground'
      raw=[IO.MemoryStream]::new();last=[int64]-1;max_gap=[int64]0
      read_state=[pscustomobject]@{read_batch_id=[int64]0
        initial_drain_bytes=[int64]-1;initial_drain_remaining=[int64]-1}
      services=0;max_consumed=0
    }
  )
  $pumpTime=[pscustomobject]@{now_us=[int64]0}
  $pumpNow={$pumpTime.now_us}.GetNewClosure()
  [int]$pumpTurns=0
  while(@($pumpStates|Where-Object{$_.serial.BytesToRead-gt0}).Count-gt0-and
      $pumpTurns-lt1000){
    $order=if(($pumpTurns-band1)-eq0){@(0,1)}else{@(1,0)}
    foreach($index in $order){
      $state=$pumpStates[$index]
      if([int]$state.serial.BytesToRead-le0){continue}
      [int]$before=[int]$state.serial.BytesToRead
      $pumpTime.now_us=[int64]$pumpTime.now_us+1000
      [int64]$last=$state.last;[int64]$gap=$state.max_gap
      [void](Read-DiagnosticSerial $state.serial $state.parser $state.raw `
          ([Diagnostics.Stopwatch]::new()) ([ref]$last) ([ref]$gap) `
          $pumpNow $state.read_state)
      $state.last=$last;$state.max_gap=$gap;$state.services++
      [int]$consumed=$before-[int]$state.serial.BytesToRead
      if($consumed-gt$state.max_consumed){$state.max_consumed=$consumed}
      $pumpTime.now_us=[int64]$pumpTime.now_us+([int64]$consumed*2)
    }
    ++$pumpTurns
  }
  $pumpFair=@($pumpStates|Where-Object{
    $_.services-lt2-or$_.max_gap-le0-or
    $_.max_gap-gt$PumpServiceLimitUs}).Count-eq0
  $pumpLoadPass=$pumpFair-and$pumpTurns-ge11-and
      @($pumpStates|Where-Object{
        $_.serial.BytesToRead-ne0-or
        $_.max_consumed-gt$PumpReadBudgetBytes-or
        $_.serial.maximum_requested-gt$PumpReadBudgetBytes-or
        $_.services-lt8-or
        $_.raw.GetType()-ne[IO.MemoryStream]-or
        $_.parser.total_bytes-ne$_.raw.Length}).Count-eq0-and
      (Get-ByteSha $pumpStates[0].raw.ToArray())-ceq(Get-ByteSha $vehicleLoad)-and
      (Get-ByteSha $pumpStates[1].raw.ToArray())-ceq(Get-ByteSha $groundLoad)
  Add-Test 'dual_port_100ms_fairness' $pumpFair `
      'deterministic offline service model remains within 100 ms on both ports'
  Add-Test 'dual_port_buffered_pump_load_fairness' $pumpLoadPass `
      ('unequal synthetic loads are alternated, bounded, and captured exactly; ' +
       'not a hardware timing proof; live capture measures real service gaps')
  foreach($state in $pumpStates){$state.raw.Dispose()}
  [byte[]]$deferredRawBytes=1,2,3,4,5
  [byte[]]$deferredFrameBytes=New-SyntheticAliveFrame 'V' 22 'L' 3 3000
  $deferredStream=[IO.MemoryStream]::new()
  $deferredStream.Write($deferredRawBytes,0,$deferredRawBytes.Length)
  $deferredErrors=[Collections.ArrayList]::new()
  $deferredState=[pscustomobject]@{
    spec=[pscustomobject]@{role='offline-deferred'}
    raw=$deferredStream
    pending_frames=@([pscustomobject]@{
      path='offline_deferred\vehicle.frame-000001.bin'
      bytes=$deferredFrameBytes})
  }
  Save-DiagnosticCaptureEvidence @($deferredState) $deferredErrors
  $deferredRawPath=Join-Path $evidence 'offline-deferred.raw.bin'
  $deferredFramePath=Join-Path $evidence `
      'offline_deferred\vehicle.frame-000001.bin'
  Add-Test 'deferred_capture_evidence_complete_after_close' (
      $deferredErrors.Count-eq0-and
      (Test-Path -LiteralPath $deferredRawPath -PathType Leaf)-and
      (Test-Path -LiteralPath $deferredFramePath -PathType Leaf)-and
      (Get-Sha $deferredRawPath)-ceq(Get-ByteSha $deferredRawBytes)-and
      (Get-Sha $deferredFramePath)-ceq(Get-ByteSha $deferredFrameBytes)-and
      -not$deferredStream.CanWrite) `
      'Buffered raw and diagnostic frames persist completely after timed COM capture closes'
  $cleanupSerial=[pscustomobject][ordered]@{IsOpen=$false}
  $cleanupSerial|Add-Member ScriptMethod Close {}
  $cleanupSerial|Add-Member ScriptMethod Dispose {}
  $cleanupStream=[IO.MemoryStream]::new()
  [byte[]]$cleanupBytes=9,8,7
  $cleanupStream.Write($cleanupBytes,0,$cleanupBytes.Length)
  $cleanupErrors=[Collections.ArrayList]::new()
  $cleanupState=[pscustomobject][ordered]@{
    spec=[pscustomobject]@{role='offline-cleanup-success'}
    serial=$cleanupSerial;raw=$cleanupStream;pending_frames=@()
  }
  $cleanupResult=Invoke-DiagnosticCaptureCleanup @($cleanupState) $cleanupErrors
  $cleanupPath=Join-Path $evidence 'offline-cleanup-success.raw.bin'
  Add-Test 'capture_cleanup_zero_error_array_contract' (
      [string]$cleanupResult.result-ceq'PASS'-and
      [int]$cleanupResult.error_count-eq0-and
      @($cleanupResult.errors).Count-eq0-and
      @($cleanupResult.steps|Where-Object{
        $_.name-ceq'deferred_evidence_persistence'-and$_.result-ceq'PASS'
      }).Count-eq1-and
      (Test-Path -LiteralPath $cleanupPath -PathType Leaf)-and
      (Get-Sha $cleanupPath)-ceq(Get-ByteSha $cleanupBytes)-and
      -not$cleanupStream.CanWrite) `
      'Zero-error cleanup must return an empty array rather than a strict-mode null'
  Add-Test 'dual_port_read_only_zero_write' ($script:SerialWriteCalls-eq0-and
      -not$script:ExternalActions.com_ports_opened) `
      'offline and live serial code expose no write path'
  $aliveTailStates=@()
  foreach($roleCode in @('V','G')){
    $roleName=if($roleCode-ceq'G'){'ground'}else{'vehicle'}
    $aliveTailState=[pscustomobject]@{spec=[pscustomobject]@{
        role=$roleName;port=if($roleCode-ceq'G'){'COM6'}else{'COM3'}}
      parser=New-DiagnosticParser ('alive_tail_'+$roleName)
      raw=[IO.MemoryStream]::new();diagnostics=[Collections.ArrayList]::new()
      tail_drain=$null}
    foreach($ordinal in 10..11){
      [byte[]]$bytes=New-SyntheticAliveFrame $roleCode ([byte]$ordinal) `
        'L' ([uint32]$ordinal) ([uint64]($ordinal*1000))
      Add-DiagnosticBytes $aliveTailState.parser $bytes ($ordinal*1000000)
      $aliveTailState.raw.Write($bytes,0,$bytes.Length)
      [void]$aliveTailState.diagnostics.Add((Convert-R19Diagnostic `
        $aliveTailState.parser.frames[-1] $roleCode $provenance))
    }
    if($roleCode-ceq'G'){
      [byte[]]$nextAlive=New-SyntheticAliveFrame 'G' 12 'L' 12 12000
      [byte[]]$prefix=$nextAlive[0..31]
      Add-DiagnosticBytes $aliveTailState.parser $prefix 12000000
      $aliveTailState.raw.Write($prefix,0,32)
    }
    $nowAliveState=[pscustomobject]@{now_us=[int64]40000000}
    $nowAlive={
      $nowAliveState.now_us+=50000;return $nowAliveState.now_us
    }.GetNewClosure()
    $aliveTailState.tail_drain=Invoke-DiagnosticExactTailDrain `
      (New-OfflineBufferedSerial ([byte[]]@())) $aliveTailState.parser `
      $aliveTailState.raw ([Diagnostics.Stopwatch]::new()) `
      ([pscustomobject]@{read_batch_id=[int64]1}) 40550000 $nowAlive $roleCode
    $aliveTailStates+=,$aliveTailState
  }
  $aliveTailContract=Get-R19AliveTerminalPartialContract $aliveTailStates $true
  $aliveTailDiagnostics=@($aliveTailStates|ForEach-Object{@($_.diagnostics)})
  $aliveTailClass=Get-R19DiagnosticClassification $aliveTailDiagnostics 0 `
    $true $false $true $null $aliveTailContract
  Add-Test 'r19a_terminal_ground_32_prefix_cause_only' (
    $aliveTailContract.valid-and$aliveTailContract.prior_alive_count-eq2-and
    $aliveTailContract.partial_bytes-eq32-and$aliveTailContract.remaining-eq31-and
    $aliveTailClass.classification-ceq'R19A_TERMINAL_PREFIX_STALL'-and
    $aliveTailClass.status-ceq'FAIL_R19A_TERMINAL_PREFIX_STALL'-and
    $aliveTailClass.result-ceq'FAIL') `
    'Source-bound Ground R19A 32/63 terminal prefix permits cause evidence only'
  $mutationsRejected=$true
  foreach($index in @(0,1,2,3,4,5,6,7,8,9,10,16,18,27,28,29)){
    $saved=$aliveTailStates[1].parser.buffer[$index]
    $aliveTailStates[1].parser.buffer[$index]=$saved-bxor1
    $mutatedAlive=Get-R19AliveTerminalPartialContract $aliveTailStates $true
    if($mutatedAlive.valid){$mutationsRejected=$false}
    $aliveTailStates[1].parser.buffer[$index]=$saved
  }
  $noSource=$aliveTailStates[1].diagnostics[0].source_mapping_verified
  $aliveTailStates[1].diagnostics[0].source_mapping_verified=$false
  $badBindingAlive=Get-R19AliveTerminalPartialContract $aliveTailStates $true
  $aliveTailStates[1].diagnostics[0].source_mapping_verified=$noSource
  Add-Test 'r19a_terminal_prefix_mutations_rejected' (
    $mutationsRejected-and-not$badBindingAlive.valid) `
    'Header, role, state, sequence, ordinal, raw suffix and source mutations fail closed'
  Add-Test 'r19a_terminal_prefix_never_complete_or_acceptance' (
    $aliveTailContract.fail_only-and
    -not$aliveTailContract.reconstruction_performed-and
    -not$aliveTailContract.missing_crc_verified-and
    -not$aliveTailContract.drain_completed-and
    $aliveTailStates[1].parser.partial_bytes-eq32-and
    $aliveTailStates[1].parser.frames.Count-eq2-and
    $aliveTailClass.result-ceq'FAIL') `
    'Missing timestamp/status/CRC bytes remain unknown, incomplete and never accepted'
  foreach($state in $aliveTailStates){$state.raw.Dispose()}
  $failed=@($tests|Where-Object{$_.result-cne'PASS'})
  [pscustomobject][ordered]@{
    result=if($failed.Count-eq0){'PASS'}else{'FAIL'}
    mode='OFFLINE_SELF_TEST';diagnostic_only=$true;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$false
    serial_write_calls=0;tests=@($tests);test_count=$tests.Count
    failed_count=$failed.Count;external_actions=$script:ExternalActions
    canonical_wire=[pscustomobject]@{
      r19f=[pscustomobject]@{prefix='R19F:';severity=2;text_length=50
        message_id=253;system_id=254;component_id=190
        payload_length=51;wire_length=63}
      r19a=[pscustomobject]@{prefix='R19A:';severity=6;text_length=47
        trailing_nul_bytes=3;message_id=253;system_id=254;component_id=190
        payload_length=51;wire_length=63}}
  }
}

function Complete-Evidence([object]$Summary) {
  if($null-ne$script:ContinuousReaderSource){
    $Summary|Add-Member NoteProperty continuous_reader_source $script:ContinuousReaderSource -Force
  }
  if($null-ne$script:StartupReaderSource){
    $Summary|Add-Member NoteProperty startup_reader_source $script:StartupReaderSource -Force
  }
  if($null-ne$script:StartupReaderEvidence-and-not$Summary.PSObject.Properties['startup_reader_evidence']){
    $Summary|Add-Member NoteProperty startup_reader_evidence $script:StartupReaderEvidence
  }
  if($null-ne$script:CaptureLifecycleTrace-and-not$Summary.PSObject.Properties['pc_lifecycle_trace']){
    $script:CaptureLifecycleTrace.clock.Stop()
    $Summary|Add-Member NoteProperty pc_lifecycle_trace (ConvertTo-R19PcLifecycleEvidence $script:CaptureLifecycleTrace)
  }
  $endSha=Get-Sha $PSCommandPath
  if($endSha-cne$script:RunnerStartSha){$Summary.result='FAIL'}
  $Summary|Add-Member NoteProperty schema `
      'vc-lora-r19-runtime-fail-diagnostic-summary-v1' -Force
  $Summary|Add-Member NoteProperty hardware_interaction `
      ([bool]$Execute.IsPresent) -Force
  $Summary|Add-Member NoteProperty test_id $TestId -Force
  $Summary|Add-Member NoteProperty started_utc $script:StartedUtc -Force
  $Summary|Add-Member NoteProperty finished_utc ([DateTime]::UtcNow.ToString('o')) -Force
  $Summary|Add-Member NoteProperty runner_integrity ([pscustomobject]@{
    result=if($endSha-ceq$script:RunnerStartSha){'PASS'}else{'FAIL'}
    start_sha256=$script:RunnerStartSha;end_sha256=$endSha}) -Force
  $summaryPath=Join-Path $evidence 'summary.json';Write-DurableJson $summaryPath $Summary
  $files=@(Get-ChildItem $evidence -Recurse -File|Where-Object{
    $_.Name-notin@('artifact_manifest.json','SHA256SUMS.txt','final_seal.json',
      'final_seal.sha256')}|
    Sort-Object FullName)
  $records=@($files|ForEach-Object{[pscustomobject]@{
    path=$_.FullName.Substring($evidence.Length+1).Replace('\','/')
    bytes=$_.Length;sha256=Get-Sha $_.FullName}})
  $manifestPath=Join-Path $evidence 'artifact_manifest.json'
  Write-DurableJson $manifestPath ([pscustomobject]@{test_id=$TestId
    artifact_count=$records.Count;artifacts=$records})
  $lines=@($files|ForEach-Object{"$(Get-Sha $_.FullName) *$($_.FullName.Substring($evidence.Length+1).Replace('\','/'))"})
  $sumsPath=Join-Path $evidence 'SHA256SUMS.txt'
  Write-DurableBytes $sumsPath $utf8.GetBytes(($lines-join$newline)+$newline)
  $sealPath=Join-Path $evidence 'final_seal.json'
  Write-DurableJson $sealPath ([pscustomobject]@{
    test_id=$TestId;result=$Summary.result;summary_sha256=Get-Sha $summaryPath
    artifact_manifest_sha256=Get-Sha $manifestPath
    sha256sums_sha256=Get-Sha $sumsPath;diagnostic_only=$true
    acceptance_eligible=$false;acceptance_authorized=$false
    deployment_authorized=$false})
  Write-DurableBytes (Join-Path $evidence 'final_seal.sha256') `
      $utf8.GetBytes((Get-Sha $sealPath)+' *final_seal.json'+$newline)
}

Assert-Condition (-not($Execute.IsPresent-and$OfflineSelfTest.IsPresent)) `
    'Execute and OfflineSelfTest are mutually exclusive.'
Assert-Condition (-not($OfflineCaptureFailureProbe.IsPresent-and
    -not$OfflineSelfTest.IsPresent)) `
    'OfflineCaptureFailureProbe requires OfflineSelfTest.'
Assert-Condition ($Execute.IsPresent-or$OfflineSelfTest.IsPresent) `
    'Choose -OfflineSelfTest or explicitly supply -Execute.'
if([string]::IsNullOrWhiteSpace($OutputDirectory)){
  $OutputDirectory=Join-Path $repo ("runs\hil\$TestId\"+
      [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))}
Assert-Condition (-not(Test-Path -LiteralPath $OutputDirectory)) `
    "Refusing to overwrite evidence: $OutputDirectory"
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$evidence=(Resolve-Path $OutputDirectory).Path
$script:RunnerStartSha=Get-Sha $PSCommandPath
$summary=$null
try{
  if($OfflineSelfTest.IsPresent){
    if($OfflineCaptureFailureProbe.IsPresent){
      Invoke-OfflineCaptureFailureProbe
    }else{$summary=Invoke-OfflineSelfTest}
  }else{
    $provenance=Get-CandidateProvenance $CandidateHandoffPath `
        $CandidateFlashEvidencePath
    $summary=Invoke-R19RuntimeFailDiagnosticCapture $provenance
    $summary|Add-Member NoteProperty mode 'LIVE_DIAGNOSTIC_ONLY'
    $summary|Add-Member NoteProperty external_actions $script:ExternalActions
    $summary|Add-Member NoteProperty candidate_provenance $provenance
  }
}catch{
  $captureFailure=$_.Exception.Message
  $failure=$captureFailure
  if($null-ne$script:CaptureCleanupResult-and
      [string]$script:CaptureCleanupResult.result-cne'PASS'){
    $failure+=' | cleanup: '+
        (@($script:CaptureCleanupResult.errors)-join' | ')
  }
  $summary=[pscustomobject][ordered]@{result='FAIL'
    mode=if($OfflineSelfTest){'OFFLINE_SELF_TEST'}else{'LIVE_DIAGNOSTIC_ONLY'}
    failure=$failure;capture_failure=$captureFailure
    cleanup=$script:CaptureCleanupResult
    diagnostic_only=$true;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$false
    serial_write_calls=0;external_actions=$script:ExternalActions}
}finally{Complete-Evidence $summary}
if($summary.result-cne'PASS'){
  $failureText=if($summary.PSObject.Properties['failure']){
    [string]$summary.failure}else{'summary result FAIL'}
  Write-Error ("R19 runtime-fail diagnostic failed: {0}; evidence={1}" -f
      $failureText,$evidence);exit 1}
Write-Output "R19 runtime-fail diagnostic PASS evidence=$evidence";exit 0
