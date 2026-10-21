[CmdletBinding()]
param(
  [switch]$Execute,
  [switch]$OfflineSelfTest,
  [string]$RepoRoot = '',
  [string]$OutputDirectory = '',
  [string]$HilAuthorization = '',
  [string]$AuthorizationId = '',
  [string]$OperatorSafetyAttestation = '',
  [string]$ColdBootAttestation = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$newline = [Environment]::NewLine

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
$script:TestId = 'R18-PRODUCTION-SINGLE-PARAM-LIVENESS-HIL-001'
$script:LiveMode = 'LIVE_R18_PRODUCTION_SINGLE_PARAM_LIVENESS'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $leaf = if ($OfflineSelfTest.IsPresent) {"OFFLINE-$stamp"} else {"LIVE-$stamp"}
  $OutputDirectory = Join-Path $repo "runs\hil\$($script:TestId)\$leaf"
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite evidence: $OutputDirectory"
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$evidence = (Resolve-Path -LiteralPath $OutputDirectory).Path

$GroundPort = 'COM6'
$ForbiddenPorts = @('COM3')
$GroundPnpDeviceId = 'USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000'
$GroundParentDeviceId = 'USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80'
$GroundVid = '303A'
$GroundPid = '1001'
$HeartbeatLimitUs = [int64]2500000
$PumpServiceLimitUs = [int64]100000
$OverallTimeoutUs = [int64]90000000
$WriteDrainTimeoutUs = [int64]5000000
$DuplicateObservationUs = [int64]10000000
$RawCaptureLimitBytes = [int64]1048576
$TimelineEventLimit = 65536
$FrameEventLimit = 32768
$PumpGapLedgerLimit = 32768
$authorizationSha256 = '4EEB5CC999ECFA4D9A6CEA5FF4A365EB6BBF15C9DD1F19CF43429A565F6C9914'
$safetySha256 = 'E80E5B41C124DD113EC0989D8E8D77F4257FA356C4B3419E5E731E5F01E526D4'
$coldBootSha256 = '8854A0D9813F2783F9A368558BE5E5D59862CD82695300E74ECD1423C43925C5'
$exactRequestHex = 'FD14000061FFBE140000FFFF010153455249414C315F4241554400000000FC13'
$exactRequestSha256 = '821F1FE12A93B30FF42EEDB0CDA9CC7DE6A8D4D4E7347BDD2CB0B3A07572E2CC'
$exactBootBannerText = "ESP-ROM:esp32s3-20210327`r`nBuild:Mar 27 2021`r`nrst:0x15 (USB_UART_CHIP_RESET),boot:0x2b (SPI_FAST_FLASH_BOOT)`r`nSaved PC:0x40377d32`r`nSPIWP:0xee`r`nmode:DIO, clock div:1`r`nload:0x3fce2820,len:0x10cc`r`nload:0x403c8700,len:0xc2c`r`nload:0x403cb700,len:0x30b0`r`nentry 0x403c88b8`r`n"
[byte[]]$exactBootBannerBytes = [Text.Encoding]::ASCII.GetBytes($exactBootBannerText)
$exactBootBannerSha256 = '18D9E462805F310BC60FCE7C40CF998DE6F9B4EF1EE1E6A0FC652E82CB71A5EC'
$definitionSha256 = 'BD2890D8973C5A694D53AB2866A6B3DBF319FAE40B3CC308AE2DAE91B634F3A8'
$acceptedProofSha256 = '3F8A79F26457013C3918A82A1D9F64F69D55C76890CA72C6F842E43C35E20268'
$groundR18Sha256 = '30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5'
$vehicleR18Sha256 = '9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52'
$definitionPath = Join-Path $repo 'core\src\mavlink_frame.cpp'
$acceptedProofPath = Join-Path $repo `
    'runs\hil\ACCEPTED-R18-REPROOF-HIL-001\20261013T230600394Z-ec66e6e1\summary.json'
$acceptedRoot = Join-Path $repo `
    'runs\baselines\R18-PRODUCTION-R4-ACCEPTED\20260914T225054625Z\artifacts'
$groundR18Path = Join-Path $acceptedRoot 'ground.application.bin'
$vehicleR18Path = Join-Path $acceptedRoot 'vehicle.application.bin'
$historicalLiveRoot = Join-Path $repo `
    'runs\hil\R18-PRODUCTION-SINGLE-PARAM-LIVENESS-HIL-001\LIVE-20261014T132547610Z-40c492ae'
$historicalLiveRawSha256 = 'FB2F9704EC1AD611ACFE8DE28681EA70AD0C89F0A88D4E3194183E09DB228366'
$historicalLiveTimelineSha256 = '4C2530A92BFB3D3262048E6150F8259AC38E2382D27054C7165A2EF755690512'
$historicalLiveSummarySha256 = 'F62DF76BA8C0083B3DE37749CD28F3B5318DE70BF86D29E062578C66718DD6BD'
$historicalLiveSealSha256 = '6F17FF8D68298AF1711EB1709FAF5928E9B980780B04F5F7088DE62B48CFDC7E'

$script:Definitions = @{}
$script:RunnerStartSha256 = ''
$script:RunnerEndSha256 = ''
$script:SummaryWritten = $false
$script:CleanupResult = $null
$script:LastMeasurement = $null
$script:AuthorizationClaim = $null
$script:PinRecords = [Collections.ArrayList]::new()
$script:StartedUtc = [DateTime]::UtcNow.ToString('o')
$script:RequestState = [pscustomobject][ordered]@{
  request_attempted=0;request_write_started_us=[int64]-1
  request_write_call_completed=0;request_writes_completed=0
  request_complete_write_edge_us=[int64]-1
  request_outcome='NOT_ATTEMPTED';request_sha256=$exactRequestSha256
}
$script:ExternalActions = [pscustomobject][ordered]@{
  cim_queried=$false;pnp_queried=$false;process_inventory_queried=$false
  com_ports_opened=$false;serial_write_attempted=$false
  serial_write_call_completed=$false;serial_bytes_drained=$false
  serial_bytes_written=$false;firmware_write_attempted=$false
  e220_write_attempted=$false;actuator_command_attempted=$false
}

function Assert-Condition([bool]$Condition,[string]$Message) {
  if (-not $Condition) {throw $Message}
}

function Get-Sha([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-ByteSha([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')}
  finally {$sha.Dispose()}
}

function Write-DurableBytes([string]$Path,[byte[]]$Bytes) {
  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    [void][IO.Directory]::CreateDirectory($parent)
  }
  $stream = [IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,[IO.FileShare]::Read,4096,
      [IO.FileOptions]::WriteThrough)
  try {
    if ($Bytes.Length -gt 0) {$stream.Write($Bytes,0,$Bytes.Length)}
    $stream.Flush($true)
  } finally {$stream.Dispose()}
}

function Write-Durable([string]$Path,[string]$Text) {
  Write-DurableBytes $Path $utf8.GetBytes($Text)
}

function Write-DurableJson([string]$Path,[object]$Value) {
  Write-Durable $Path ((ConvertTo-Json -InputObject $Value -Depth 30) + $newline)
}

function Claim-OneRunAuthorization([string]$Id,[string]$ClaimDirectory,
    [string]$BoundEvidencePath,[switch]$Simulation) {
  $parsed=[Guid]::Empty
  Assert-Condition ([Guid]::TryParseExact($Id,'D',[ref]$parsed)) `
      'AuthorizationId must be a canonical unique GUID.'
  $canonical=$parsed.ToString('D').ToLowerInvariant()
  Assert-Condition ($Id.ToLowerInvariant() -ceq $canonical) `
      'AuthorizationId must use canonical GUID formatting.'
  [void][IO.Directory]::CreateDirectory($ClaimDirectory)
  $claimPath=Join-Path $ClaimDirectory ($canonical+'.json')
  $record=[pscustomobject][ordered]@{
    schema='vc-lora-r18-single-param-atomic-claim-v1'
    authorization_id=$canonical;authorization_token_sha256=$authorizationSha256
    claimed_utc=[DateTime]::UtcNow.ToString('o')
    bound_evidence_path=$BoundEvidencePath
    authorization_consumed=$true;authorization_reusable=$false
    retry_allowed=$false;simulation=$Simulation.IsPresent
  }
  [byte[]]$bytes=$utf8.GetBytes((ConvertTo-Json $record -Depth 10)+$newline)
  try {
    $stream=[IO.FileStream]::new($claimPath,[IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,[IO.FileShare]::Read,4096,
        [IO.FileOptions]::WriteThrough)
  } catch [IO.IOException] {
    throw "One-run authorization replay rejected; claim already exists: $canonical"
  }
  try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}
  finally {$stream.Dispose()}
  return [pscustomobject][ordered]@{
    result='CLAIMED';authorization_id=$canonical;claim_path=$claimPath
    claim_sha256=Get-Sha $claimPath;record=$record
  }
}

function Copy-PinnedArtifact([string]$Source,[string]$Name,[int64]$Bytes,
    [string]$Sha256) {
  Assert-Condition (Test-Path -LiteralPath $Source -PathType Leaf) `
      "Pinned artifact missing: $Name"
  $item = Get-Item -LiteralPath $Source
  Assert-Condition ([int64]$item.Length -eq $Bytes) `
      "Pinned artifact size mismatch: $Name"
  Assert-Condition ((Get-Sha $Source) -ceq $Sha256) `
      "Pinned artifact SHA-256 mismatch: $Name"
  $target = Join-Path (Join-Path $evidence 'staged') $Name
  $input = [IO.FileStream]::new($Source,[IO.FileMode]::Open,
      [IO.FileAccess]::Read,[IO.FileShare]::Read)
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
  $output = [IO.FileStream]::new($target,[IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,[IO.FileShare]::Read,4096,
      [IO.FileOptions]::WriteThrough)
  try {$input.CopyTo($output);$output.Flush($true)}
  finally {$output.Dispose();$input.Dispose()}
  Assert-Condition ((Get-Sha $target) -ceq $Sha256) `
      "Staged artifact SHA-256 mismatch: $Name"
  $record = [pscustomobject][ordered]@{
    name=$Name;source=$Source;staged=$target;bytes=$Bytes;sha256=$Sha256
  }
  [void]$script:PinRecords.Add($record)
  return $record
}

function Assert-PinnedInputs {
  $script:RunnerStartSha256 = Get-Sha $PSCommandPath
  [void](Copy-PinnedArtifact $PSCommandPath 'runner.executed.ps1' `
      ([int64](Get-Item -LiteralPath $PSCommandPath).Length) `
      $script:RunnerStartSha256)
  [void](Copy-PinnedArtifact $definitionPath 'mavlink_frame.cpp' 16510 `
      $definitionSha256)
  [void](Copy-PinnedArtifact $acceptedProofPath `
      'accepted_r18_reproof.summary.json' 6427 $acceptedProofSha256)
  [void](Copy-PinnedArtifact $groundR18Path `
      'ground.r18.accepted.application.bin' 360208 $groundR18Sha256)
  [void](Copy-PinnedArtifact $vehicleR18Path `
      'vehicle.r18.accepted.application.bin' 389280 $vehicleR18Sha256)
  $proof = Get-Content -LiteralPath $acceptedProofPath -Raw | ConvertFrom-Json
  Assert-Condition ([string]$proof.status -ceq 'PASS_R18_ALREADY_ACCEPTED_BOTH') `
      'Pinned accepted-R18 reproof status changed.'
  $roles = @($proof.roles)
  Assert-Condition ($roles.Count -eq 2 -and
      @($roles | Where-Object {-not [bool]$_.accepted_r18_proven}).Count -eq 0 -and
      @($roles | Where-Object {[bool]$_.restore_attempted}).Count -eq 0) `
      'Pinned accepted-R18 reproof does not prove both roles without restore.'
  $script:Definitions = Get-MavlinkDefinitions $definitionPath
  Assert-Condition ($exactBootBannerBytes.Length -eq 266 -and
      (Get-ByteSha $exactBootBannerBytes) -ceq $exactBootBannerSha256) `
      'Pinned exact ESP32-S3 ROM banner changed.'
  [byte[]]$request = New-ExactParamRequestRead
  Write-DurableBytes (Join-Path $evidence 'request_fixture_exact_once.bin') $request
}

function Get-MavlinkDefinitions([string]$Path) {
  $text = [IO.File]::ReadAllText($Path)
  $matches = [regex]::Matches($text,
      '\{(?<id>[0-9]+)U,\s*(?<crc>[0-9]+)U,\s*(?<min>[0-9]+)U,\s*(?<max>[0-9]+)U\}')
  $definitions = @{}
  foreach ($match in $matches) {
    $id = [int]$match.Groups['id'].Value
    Assert-Condition (-not $definitions.ContainsKey($id)) `
        "Duplicate MAVLink definition $id"
    $definitions[$id] = [pscustomobject][ordered]@{
      crc_extra=[int]$match.Groups['crc'].Value
      min_payload=[int]$match.Groups['min'].Value
      max_payload=[int]$match.Groups['max'].Value
    }
  }
  Assert-Condition ($definitions.Count -eq 80) `
      "Expected 80 pinned MAVLink definitions, got $($definitions.Count)"
  Assert-Condition ($definitions[0].crc_extra -eq 50 -and
      $definitions[20].crc_extra -eq 214 -and
      $definitions[22].crc_extra -eq 220) 'Required MAVLink definitions changed.'
  return $definitions
}

function Convert-HexToBytes([string]$Hex) {
  Assert-Condition (($Hex.Length % 2) -eq 0) 'Odd hexadecimal length.'
  [byte[]]$bytes = New-Object byte[] ($Hex.Length / 2)
  for ($index=0;$index -lt $bytes.Length;++$index) {
    $bytes[$index] = [Convert]::ToByte($Hex.Substring($index*2,2),16)
  }
  return $bytes
}

function Test-ByteEqual([byte[]]$Left,[byte[]]$Right) {
  if ($Left.Length -ne $Right.Length) {return $false}
  for ($index=0;$index -lt $Left.Length;++$index) {
    if ($Left[$index] -ne $Right[$index]) {return $false}
  }
  return $true
}

function New-ExactParamRequestRead {
  [byte[]]$request = Convert-HexToBytes $exactRequestHex
  Assert-Condition ($request.Length -eq 32) `
      'Exact PARAM_REQUEST_READ length must be 32 bytes.'
  Assert-Condition ((Get-ByteSha $request) -ceq $exactRequestSha256) `
      'Exact PARAM_REQUEST_READ SHA-256 mismatch.'
  Assert-Condition ($request[0] -eq 0xFD -and $request[1] -eq 20 -and
      $request[7] -eq 20 -and $request[8] -eq 0 -and $request[9] -eq 0 -and
      $request[10] -eq 0xFF -and $request[11] -eq 0xFF -and
      $request[12] -eq 1 -and $request[13] -eq 1) `
      'Exact PARAM_REQUEST_READ message/target/index changed.'
  return $request
}

function Update-X25Crc([uint16]$Crc,[byte]$Value) {
  [int]$mixed = ($Value -bxor ($Crc -band 0xFF)) -band 0xFF
  $mixed = ($mixed -bxor (($mixed -shl 4) -band 0xFF)) -band 0xFF
  return [uint16]((($Crc -shr 8) -bxor ($mixed -shl 8) -bxor
      ($mixed -shl 3) -bxor ($mixed -shr 4)) -band 0xFFFF)
}

function New-MavlinkParser([string]$Name,[bool]$ComputeRawSha=$true) {
  return [pscustomobject][ordered]@{
    name=$Name;buffer=[Collections.Generic.List[byte]]::new();expected_size=0
    startup_classification_pending=$true
    startup_buffer=[Collections.Generic.List[byte]]::new()
    classified_startup_bytes=[int64]0;classified_startup_sha256=''
    frame_start_us=[int64]-1;frame_start_raw_offset=[int64]-1
    frame_start_read_ordinal=[int64]-1
    initial_backlog_read_ordinal=[int64]-1;next_ingest_read_ordinal=[int64]0
    total_bytes=[int64]0;noise_bytes=[int64]0;bad_length=[int64]0
    bad_crc=[int64]0;unsupported_flags=[int64]0
    unknown_definition=[int64]0;valid_frames=[int64]0
    compute_raw_sha=$ComputeRawSha;frames=[Collections.ArrayList]::new()
  }
}

function Add-MavlinkDataByte([object]$Parser,[byte]$Value,
    [int64]$RawOffset,[int64]$ElapsedUs,[int64]$ReadOrdinal) {
  if ($Parser.buffer.Count -eq 0) {
    if ($Value -ne 0xFD -and $Value -ne 0xFE) {
      $Parser.noise_bytes=[int64]$Parser.noise_bytes+1
      return
    }
    $Parser.frame_start_us=$ElapsedUs
    $Parser.frame_start_raw_offset=$RawOffset
    $Parser.frame_start_read_ordinal=$ReadOrdinal
  }
  $Parser.buffer.Add($Value)
  if ($Parser.buffer.Count -eq 2 -and $Parser.buffer[0] -eq 0xFE) {
    $Parser.expected_size=[int]$Parser.buffer[1]+8
  }
  if ($Parser.buffer.Count -eq 3 -and $Parser.buffer[0] -eq 0xFD) {
    $signature=if(($Parser.buffer[2] -band 1)-ne 0){13}else{0}
    $Parser.expected_size=[int]$Parser.buffer[1]+12+$signature
  }
  if ($Parser.expected_size -gt 0 -and
      $Parser.buffer.Count -eq $Parser.expected_size) {
    [byte[]]$raw=$Parser.buffer.ToArray()
    $record=Convert-MavlinkFrameRecord $raw `
        ([int64]$Parser.frame_start_us) $ElapsedUs `
        ([int64]$Parser.frame_start_raw_offset) `
        ([int64]$Parser.frame_start_read_ordinal) $ReadOrdinal `
        ([bool]$Parser.compute_raw_sha)
    if ($record.valid) {$Parser.valid_frames=[int64]$Parser.valid_frames+1}
    else {
      switch ($record.failure) {
        'bad_crc' {$Parser.bad_crc=[int64]$Parser.bad_crc+1}
        'bad_length' {$Parser.bad_length=[int64]$Parser.bad_length+1}
        'unsupported_flags' {$Parser.unsupported_flags=[int64]$Parser.unsupported_flags+1}
        'unknown_definition' {$Parser.unknown_definition=[int64]$Parser.unknown_definition+1}
      }
    }
    [void]$Parser.frames.Add($record)
    $Parser.buffer.Clear();$Parser.expected_size=0
    $Parser.frame_start_us=[int64]-1;$Parser.frame_start_raw_offset=[int64]-1
    $Parser.frame_start_read_ordinal=[int64]-1
  } elseif ($Parser.buffer.Count -gt 280) {
    $Parser.bad_length=[int64]$Parser.bad_length+1
    $Parser.buffer.Clear();$Parser.expected_size=0
    $Parser.frame_start_us=[int64]-1;$Parser.frame_start_raw_offset=[int64]-1
    $Parser.frame_start_read_ordinal=[int64]-1
  }
}

function Convert-MavlinkFrameRecord([byte[]]$Raw,[int64]$StartUs,
    [int64]$CompleteUs,[int64]$StartRawOffset,[int64]$StartReadOrdinal,
    [int64]$CompleteReadOrdinal,[bool]$ComputeRawSha) {
  $magic = [int]$Raw[0]
  $payloadLength = [int]$Raw[1]
  if ($magic -eq 0xFD) {
    $version=2;$incompat=[int]$Raw[2];$sequence=[int]$Raw[4]
    $systemId=[int]$Raw[5];$componentId=[int]$Raw[6]
    $messageId=[int]$Raw[7] -bor ([int]$Raw[8] -shl 8) -bor
        ([int]$Raw[9] -shl 16)
    $payloadOffset=10;$checksumOffset=10+$payloadLength
    $unsupportedFlags=(($incompat -band 0xFE) -ne 0)
  } else {
    $version=1;$incompat=0;$sequence=[int]$Raw[2]
    $systemId=[int]$Raw[3];$componentId=[int]$Raw[4]
    $messageId=[int]$Raw[5];$payloadOffset=6
    $checksumOffset=6+$payloadLength;$unsupportedFlags=$false
  }
  $failure=''
  [int]$computedCrc=-1
  [int]$storedCrc=-1
  if ($unsupportedFlags) {$failure='unsupported_flags'}
  elseif (-not $script:Definitions.ContainsKey($messageId)) {
    $failure='unknown_definition'
  } else {
    $definition=$script:Definitions[$messageId]
    $minimum=[int]$definition.min_payload
    if ($version -eq 2 -and $messageId -eq 20) {$minimum=4}
    if ($version -eq 2 -and $messageId -eq 76) {$minimum=30}
    if ($payloadLength -lt $minimum -or
        $payloadLength -gt [int]$definition.max_payload -or
        ($version -eq 1 -and $payloadLength -ne [int]$definition.min_payload)) {
      $failure='bad_length'
    } else {
      [uint16]$crc=0xFFFF
      for ($index=1;$index -lt $checksumOffset;++$index) {
        $crc=Update-X25Crc $crc $Raw[$index]
      }
      $crc=Update-X25Crc $crc ([byte]$definition.crc_extra)
      [uint16]$stored=[uint16]([int]$Raw[$checksumOffset] -bor
          ([int]$Raw[$checksumOffset+1] -shl 8))
      $computedCrc=[int]$crc;$storedCrc=[int]$stored
      if ($stored -ne $crc) {$failure='bad_crc'}
    }
  }
  return [pscustomobject][ordered]@{
    frame_start_us=$StartUs;complete_us=$CompleteUs
    frame_start_raw_offset=$StartRawOffset
    frame_start_read_ordinal=$StartReadOrdinal
    complete_read_ordinal=$CompleteReadOrdinal
    valid=[string]::IsNullOrEmpty($failure);failure=$failure
    version=$version;sequence=$sequence;system_id=$systemId
    component_id=$componentId;message_id=$messageId
    payload_length=$payloadLength;payload_offset=$payloadOffset
    signed=(($incompat -band 1) -ne 0);raw=$Raw;raw_length=$Raw.Length
    stored_crc=$storedCrc;computed_crc=$computedCrc
    raw_sha256=if($ComputeRawSha){Get-ByteSha $Raw}else{''}
  }
}

function Add-MavlinkBytes([object]$Parser,[byte[]]$Bytes,[int64]$ElapsedUs,
    [int64]$ReadOrdinal=-1) {
  if($ReadOrdinal -lt 0) {
    $Parser.next_ingest_read_ordinal=[int64]$Parser.next_ingest_read_ordinal+1
    $ReadOrdinal=[int64]$Parser.next_ingest_read_ordinal
  } elseif($ReadOrdinal -gt [int64]$Parser.next_ingest_read_ordinal) {
    $Parser.next_ingest_read_ordinal=$ReadOrdinal
  }
  if($Bytes.Length -gt 0 -and [int64]$Parser.initial_backlog_read_ordinal -lt 0) {
    $Parser.initial_backlog_read_ordinal=$ReadOrdinal
  }
  foreach ($value in $Bytes) {
    [int64]$rawOffset=[int64]$Parser.total_bytes
    $Parser.total_bytes=$rawOffset+1
    if ([bool]$Parser.startup_classification_pending) {
      $Parser.startup_buffer.Add($value)
      [int]$startupIndex=$Parser.startup_buffer.Count-1
      if ($startupIndex -ge $exactBootBannerBytes.Length -or
          $value -ne $exactBootBannerBytes[$startupIndex]) {
        [byte[]]$pending=$Parser.startup_buffer.ToArray()
        [int64]$pendingStart=[int64]$Parser.total_bytes-$pending.Length
        $Parser.startup_buffer.Clear()
        $Parser.startup_classification_pending=$false
        for($pendingIndex=0;$pendingIndex -lt $pending.Length;++$pendingIndex) {
          Add-MavlinkDataByte $Parser $pending[$pendingIndex] `
              ($pendingStart+$pendingIndex) $ElapsedUs $ReadOrdinal
        }
      } elseif ($Parser.startup_buffer.Count -eq $exactBootBannerBytes.Length) {
        [byte[]]$banner=$Parser.startup_buffer.ToArray()
        $Parser.startup_buffer.Clear()
        $Parser.startup_classification_pending=$false
        $Parser.classified_startup_bytes=[int64]$banner.Length
        $Parser.classified_startup_sha256=Get-ByteSha $banner
      }
      continue
    }
    Add-MavlinkDataByte $Parser $value $rawOffset $ElapsedUs $ReadOrdinal
  }
}

function Get-ParserSnapshot([object]$Parser) {
  return [pscustomobject][ordered]@{
    total_bytes=[int64]$Parser.total_bytes;noise_bytes=[int64]$Parser.noise_bytes
    bad_lengths=[int64]$Parser.bad_length;bad_crc=[int64]$Parser.bad_crc
    unsupported_flags=[int64]$Parser.unsupported_flags
    unknown_definition=[int64]$Parser.unknown_definition
    partial_bytes=[int]$Parser.buffer.Count
    unclassified_startup_bytes=[int]$Parser.startup_buffer.Count
    classified_startup_bytes=[int64]$Parser.classified_startup_bytes
    classified_startup_sha256=[string]$Parser.classified_startup_sha256
    initial_backlog_read_ordinal=[int64]$Parser.initial_backlog_read_ordinal
    frame_count=[int]$Parser.frames.Count
  }
}

function Get-ParserErrorDelta([object]$Parser,[object]$Baseline) {
  return [pscustomobject][ordered]@{
    noise_bytes=[int64]$Parser.noise_bytes-[int64]$Baseline.noise_bytes
    bad_lengths=[int64]$Parser.bad_length-[int64]$Baseline.bad_lengths
    bad_crc=[int64]$Parser.bad_crc-[int64]$Baseline.bad_crc
    unsupported_flags=[int64]$Parser.unsupported_flags-[int64]$Baseline.unsupported_flags
    unknown_definition=[int64]$Parser.unknown_definition-[int64]$Baseline.unknown_definition
    partial_bytes=[int]$Parser.buffer.Count
    unclassified_startup_bytes=[int]$Parser.startup_buffer.Count
  }
}

function Get-ElapsedUs([Diagnostics.Stopwatch]$Clock) {
  return [int64](($Clock.ElapsedTicks*1000000L)/[Diagnostics.Stopwatch]::Frequency)
}

function Get-PrimaryHeartbeats([object]$Parser) {
  return @($Parser.frames | Where-Object {
    $_.valid -and $_.version -eq 2 -and -not $_.signed -and
        $_.message_id -eq 0 -and $_.system_id -eq 1 -and
        $_.component_id -eq 1 -and $_.payload_length -eq 9 -and
        $_.raw_length -eq 21
  })
}

function Get-FreshPrimaryHeartbeats([object]$Parser) {
  [int64]$backlogOrdinal=[int64]$Parser.initial_backlog_read_ordinal
  $fresh=[Collections.ArrayList]::new()
  [int64]$lastRead=[int64]-1
  foreach($frame in @(Get-PrimaryHeartbeats $Parser)) {
    [int64]$readOrdinal=if($null-ne$frame.PSObject.Properties['complete_read_ordinal']){
      [int64]$frame.complete_read_ordinal
    }else{[int64]-1}
    if($readOrdinal -le $backlogOrdinal -or $readOrdinal -lt 0){continue}
    if($readOrdinal -eq $lastRead){continue}
    [void]$fresh.Add($frame);$lastRead=$readOrdinal
  }
  return @($fresh)
}

function Get-HeartbeatObservation([object]$Parser,[int64]$NowUs) {
  $heartbeats=@(Get-FreshPrimaryHeartbeats $Parser)
  [int64]$maximum=0
  for ($index=1;$index -lt $heartbeats.Count;++$index) {
    [int64]$gap=[int64]$heartbeats[$index].complete_us-
        [int64]$heartbeats[$index-1].complete_us
    if ($gap -gt $maximum) {$maximum=$gap}
  }
  [int64]$age=if($heartbeats.Count -gt 0){
    $NowUs-[int64]$heartbeats[$heartbeats.Count-1].complete_us
  }else{[int64]::MaxValue}
  return [pscustomobject][ordered]@{
    count=$heartbeats.Count;maximum_gap_us=$maximum
    last_heartbeat_age_us=$age;frames=$heartbeats
  }
}

function Get-ProcessAncestorIds([object[]]$Processes,[int]$StartProcessId) {
  $byId=@{}
  foreach($process in @($Processes)) {
    if($null-eq$process.PSObject.Properties['ProcessId']){continue}
    [int]$id=[int]$process.ProcessId
    if($id-gt 0){$byId[$id]=$process}
  }
  $result=[Collections.Generic.List[int]]::new()
  $seen=[Collections.Generic.HashSet[int]]::new()
  [int]$cursor=$StartProcessId
  while($cursor-gt 0 -and $seen.Add($cursor)) {
    $result.Add($cursor)
    if(-not$byId.ContainsKey($cursor) -or
        $null-eq$byId[$cursor].PSObject.Properties['ParentProcessId']){break}
    $cursor=[int]$byId[$cursor].ParentProcessId
  }
  return $result.ToArray()
}

function Get-CompetingClientGateFromSnapshot([object[]]$Processes,
    [int]$CurrentProcessId) {
  $known=@('missionplanner','mavproxy','qgroundcontrol','putty','teraterm',
      'ttermpro','coolterm','arduino','arduino-cli','arduino-ide',
      'serialstudio','esptool','platformio','plink')
  $trustedAncestorNames=@('powershell','pwsh','cmd','conhost','codex',
      'codex-cli','node','openai')
  $ancestors=@(Get-ProcessAncestorIds $Processes $CurrentProcessId)
  $ancestorSet=[Collections.Generic.HashSet[int]]::new()
  foreach($ancestorId in $ancestors){[void]$ancestorSet.Add([int]$ancestorId)}
  $blocked=[Collections.ArrayList]::new();$trusted=[Collections.ArrayList]::new()
  foreach($process in @($Processes)) {
    [int]$id=[int]$process.ProcessId
    if($id-eq$CurrentProcessId){continue}
    $rawName=[string]$process.Name
    $name=[IO.Path]::GetFileNameWithoutExtension($rawName).ToLowerInvariant()
    $command=[string]$process.CommandLine
    $isAncestor=$ancestorSet.Contains($id)
    $trustedAncestor=$isAncestor -and $trustedAncestorNames -contains $name -and
        ($name -in @('codex','codex-cli','node','openai','conhost') -or
         $command -match '(?i)run_r18_single_param_liveness_hil\.ps1')
    $nameBlocked=$known -contains $name
    $toolReference=$command -match '(?i)(missionplanner|mavproxy|qgroundcontrol|putty|teraterm|ttermpro|coolterm|arduino(?:-cli|-ide)?|serialstudio|esptool|platformio|plink)'
    $portReference=$command -match '(?i)(?:^|[^A-Za-z0-9])(?:COM3|COM6)(?:$|[^0-9])'
    $reason=''
    if($nameBlocked){$reason='blocked_process_name'}
    elseif($toolReference){$reason='blocked_tool_command_line_reference'}
    elseif($portReference -and -not$trustedAncestor){$reason='explicit_com3_or_com6_command_line_reference'}
    if($trustedAncestor){
      [void]$trusted.Add([pscustomobject][ordered]@{
        process_id=$id;parent_process_id=[int]$process.ParentProcessId
        name=$rawName;classification='trusted_invocation_ancestor'
        command_line_sha256=if([string]::IsNullOrEmpty($command)){''}else{
          Get-ByteSha $utf8.GetBytes($command)
        }
      })
    }
    if(-not[string]::IsNullOrEmpty($reason)) {
      [void]$blocked.Add([pscustomobject][ordered]@{
        process_id=$id;parent_process_id=[int]$process.ParentProcessId
        name=$rawName;reason=$reason;is_ancestor=$isAncestor
        trusted_ancestor=$trustedAncestor
        explicit_port_reference=$portReference;blocked_tool_reference=$toolReference
        command_line_sha256=if([string]::IsNullOrEmpty($command)){''}else{
          Get-ByteSha $utf8.GetBytes($command)
        }
      })
    }
  }
  return [pscustomobject][ordered]@{
    schema='vc-lora-r18-single-param-process-gate-v1'
    captured_utc=[DateTime]::UtcNow.ToString('o');fail_closed=$true
    sanitized=$true;result=if($blocked.Count-eq 0){'PASS'}else{'FAIL'}
    inventory_count=@($Processes).Count;ancestor_ids=@($ancestors)
    trusted_ancestors=@($trusted);blocked_processes=@($blocked)
  }
}

function Assert-NoCompetingClients {
  $script:ExternalActions.process_inventory_queried=$true
  $processes=@(Get-CimInstance Win32_Process -ErrorAction Stop)
  $gate=Get-CompetingClientGateFromSnapshot $processes $PID
  Write-DurableJson (Join-Path $evidence 'process_gate_before_open.json') $gate
  Assert-Condition ([string]$gate.result -ceq 'PASS') `
      ('Competing serial process or explicit COM3|COM6 command-line reference found: '+
       ((@($gate.blocked_processes)|ForEach-Object{"$($_.name):$($_.process_id):$($_.reason)"})-join','))
  return $gate
}

function Assert-ExactGroundIdentity([string]$Checkpoint) {
  Assert-Condition ($GroundPort -ceq 'COM6') 'Ground port pin changed.'
  Assert-Condition ($ForbiddenPorts -contains 'COM3') 'COM3 must remain forbidden.'
  $script:ExternalActions.cim_queried=$true
  $records=@(Get-CimInstance Win32_SerialPort -ErrorAction Stop |
      Where-Object {[string]$_.DeviceID -ceq $GroundPort})
  Assert-Condition ($records.Count -eq 1) `
      "Ground identity missing or ambiguous at ${Checkpoint}: count=$($records.Count)"
  $record=$records[0];$actualPnp=[string]$record.PNPDeviceID
  Assert-Condition ([string]::Equals($actualPnp,$GroundPnpDeviceId,
      [StringComparison]::OrdinalIgnoreCase)) `
      "Ground PNP mismatch at ${Checkpoint}: $actualPnp"
  Assert-Condition ($actualPnp.ToUpperInvariant().Contains("VID_$GroundVid") -and
      $actualPnp.ToUpperInvariant().Contains("PID_$GroundPid")) `
      "Ground VID/PID mismatch at ${Checkpoint}: $actualPnp"
  Assert-Condition ([string]$record.Status -ceq 'OK' -and
      [int]$record.ConfigManagerErrorCode -eq 0) `
      "Ground health failed at ${Checkpoint}."
  $script:ExternalActions.pnp_queried=$true
  $parent=(Get-PnpDeviceProperty -InstanceId $actualPnp `
      -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
  Assert-Condition ([string]::Equals([string]$parent,$GroundParentDeviceId,
      [StringComparison]::OrdinalIgnoreCase)) `
      "Ground parent mismatch at ${Checkpoint}: $parent"
  return [pscustomobject][ordered]@{
    result='PASS';checkpoint=$Checkpoint;port=[string]$record.DeviceID
    pnp_device_id=$actualPnp;parent_device_id=[string]$parent
    status=[string]$record.Status
    config_manager_error_code=[int]$record.ConfigManagerErrorCode
  }
}

function New-GroundSerialPort {
  Assert-Condition ($GroundPort -notin $ForbiddenPorts) 'Ground port is forbidden.'
  $serial=[IO.Ports.SerialPort]::new($GroundPort,57600,
      [IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
  $serial.DtrEnable=$false;$serial.RtsEnable=$false
  $serial.Handshake=[IO.Ports.Handshake]::None
  $serial.ReadTimeout=50;$serial.WriteTimeout=5000
  $serial.ReadBufferSize=1048576;$serial.WriteBufferSize=4096
  return $serial
}

function Invoke-ExactRequestWrite([object]$Serial,[byte[]]$Request,
    [scriptblock]$NowUs,[scriptblock]$WaitOneMillisecond,
    [int64]$DrainTimeoutUs=$WriteDrainTimeoutUs,[switch]$Simulation) {
  Assert-Condition ($script:RequestState.request_attempted -eq 0) `
      'PARAM_REQUEST_READ transmission is one-shot; retry forbidden.'
  Assert-Condition ($script:RequestState.request_writes_completed -eq 0) `
      'PARAM_REQUEST_READ already completed; retry forbidden.'
  Assert-Condition ($Request.Length -eq 32 -and
      (Get-ByteSha $Request) -ceq $exactRequestSha256) `
      'PARAM_REQUEST_READ bytes are not the frozen fixture.'
  $script:RequestState.request_attempted=1
  $script:RequestState.request_outcome='AMBIGUOUS'
  [int64]$r0=& $NowUs
  $script:RequestState.request_write_started_us=$r0
  if (-not $Simulation.IsPresent) {
    $script:ExternalActions.serial_write_attempted=$true
    $script:ExternalActions.serial_bytes_written=$true
  }
  try {
    $Serial.Write($Request,0,$Request.Length)
    if(-not $Simulation.IsPresent){$script:ExternalActions.serial_write_call_completed=$true}
    $script:RequestState.request_write_call_completed=1
    [int64]$deadline=$r0+$DrainTimeoutUs
    while([int]$Serial.BytesToWrite -ne 0) {
      if([int64](& $NowUs) -ge $deadline) {
        throw 'PARAM_REQUEST_READ drain timeout; state ambiguous and retry forbidden.'
      }
      & $WaitOneMillisecond
    }
    [int64]$edge=& $NowUs
    if(-not $Simulation.IsPresent){$script:ExternalActions.serial_bytes_drained=$true}
    $script:RequestState.request_writes_completed=1
    $script:RequestState.request_complete_write_edge_us=$edge
    $script:RequestState.request_outcome='COMPLETE'
    return [pscustomobject][ordered]@{
      result='PASS';request_write_started_us=$r0
      request_complete_write_edge_us=$edge;request_drain_us=$edge-$r0
      request_attempted=1;request_writes_completed=1
      request_sha256=$exactRequestSha256
    }
  } catch {$script:RequestState.request_outcome='AMBIGUOUS';throw}
}

function New-PumpTimingState {
  return [pscustomobject][ordered]@{
    current_phase='not_started';last_phase='';last_pump_us=[int64]-1
    maximum_gap_us=[int64]0;pump_count=[int64]0;read_ordinal=[int64]0
    gap_ledger=[Collections.ArrayList]::new()
  }
}

function Set-PumpPhase([object]$State,[string]$Phase) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($Phase)) `
      'Pump phase must be non-empty.'
  $State.current_phase=$Phase
}

function Register-PumpService([object]$State,[int64]$PumpStartedUs) {
  [string]$phase=[string]$State.current_phase
  if([int64]$State.last_pump_us -ge 0) {
    Assert-Condition ($State.gap_ledger.Count-lt$PumpGapLedgerLimit) `
        'Pump gap ledger exceeded its fail-closed in-memory limit.'
    [int64]$gap=$PumpStartedUs-[int64]$State.last_pump_us
    if($gap -gt [int64]$State.maximum_gap_us){$State.maximum_gap_us=$gap}
    [void]$State.gap_ledger.Add([pscustomobject][ordered]@{
      ordinal=[int64]$State.gap_ledger.Count+1
      previous_pump_us=[int64]$State.last_pump_us;pump_started_us=$PumpStartedUs
      gap_us=$gap;from_phase=[string]$State.last_phase;to_phase=$phase
      within_limit=($gap-ge 0 -and $gap-le$PumpServiceLimitUs)
      result=if($gap-ge 0 -and $gap-le$PumpServiceLimitUs){'PASS'}else{'FAIL'}
    })
  }
  $State.last_pump_us=$PumpStartedUs;$State.last_phase=$phase
  $State.pump_count=[int64]$State.pump_count+1
}

function Get-PumpTimingEvidence([object]$State) {
  $phaseSummary=[Collections.ArrayList]::new()
  foreach($group in @($State.gap_ledger|Group-Object to_phase)) {
    [int64]$maximum=0;[int]$violations=0
    foreach($entry in @($group.Group)) {
      if([int64]$entry.gap_us-gt$maximum){$maximum=[int64]$entry.gap_us}
      if(-not[bool]$entry.within_limit){++$violations}
    }
    [void]$phaseSummary.Add([pscustomobject][ordered]@{
      phase=[string]$group.Name;gap_count=@($group.Group).Count
      maximum_gap_us=$maximum;violation_count=$violations
    })
  }
  return [pscustomobject][ordered]@{
    result=if([int64]$State.maximum_gap_us-le$PumpServiceLimitUs){'PASS'}else{'FAIL'}
    maximum_gap_us=[int64]$State.maximum_gap_us;limit_us=$PumpServiceLimitUs
    pump_count=[int64]$State.pump_count;ledger_count=[int]$State.gap_ledger.Count
    phase_summary=@($phaseSummary);gap_ledger=@($State.gap_ledger)
    ledger_artifact='pump_gap_ledger.jsonl'
  }
}

function Read-AvailableSerial([object]$Serial,[object]$Parser,
    [IO.MemoryStream]$Raw,[Diagnostics.Stopwatch]$Clock,
    [Collections.ArrayList]$Timeline,[object]$PumpState) {
  [int64]$pumpStarted=Get-ElapsedUs $Clock
  Register-PumpService $PumpState $pumpStarted
  [int]$total=0
  [int64]$readOrdinal=[int64]-1
  do {
    [int]$available=[int]$Serial.BytesToRead
    if($available -le 0){break}
    if($readOrdinal-lt0) {
      $PumpState.read_ordinal=[int64]$PumpState.read_ordinal+1
      $readOrdinal=[int64]$PumpState.read_ordinal
    }
    [int]$size=[math]::Min(8192,$available)
    [byte[]]$buffer=New-Object byte[] $size
    [int64]$offset=[int64]$Parser.total_bytes
    [int]$read=$Serial.Read($buffer,0,$buffer.Length)
    if($read -le 0){break}
    if($read -ne $buffer.Length){[byte[]]$exact=New-Object byte[] $read;[array]::Copy($buffer,$exact,$read);$buffer=$exact}
    Assert-Condition ([int64]$Raw.Length+$buffer.Length-le$RawCaptureLimitBytes) `
        'Raw capture exceeded its fail-closed 1 MiB in-memory limit.'
    Assert-Condition ($Timeline.Count-lt$TimelineEventLimit) `
        'Timeline exceeded its fail-closed in-memory event limit.'
    $Raw.Write($buffer,0,$buffer.Length)
    [int64]$arrival=Get-ElapsedUs $Clock
    Add-MavlinkBytes $Parser $buffer $arrival $readOrdinal;$total+=$read
    [void]$Timeline.Add([pscustomobject][ordered]@{
      kind='SERIAL_READ';read_started_us=$pumpStarted;read_complete_us=$arrival
      read_ordinal=$readOrdinal;phase=[string]$PumpState.current_phase
      raw_offset=$offset;bytes=$read
      timestamp_basis='host high-frequency pump read-complete/frame-complete'
    })
  }while([int]$Serial.BytesToRead -gt 0)
  return $total
}

function Buffer-NewFrameEvents([object]$Parser,[ref]$Cursor,
    [Collections.ArrayList]$FrameLog) {
  while([int]$Cursor.Value -lt $Parser.frames.Count) {
    Assert-Condition ($FrameLog.Count-lt$FrameEventLimit) `
        'Frame ledger exceeded its fail-closed in-memory event limit.'
    $record=$Parser.frames[[int]$Cursor.Value]
    [void]$FrameLog.Add([pscustomobject][ordered]@{
      ordinal=[int]$Cursor.Value;valid=[bool]$record.valid
      failure=[string]$record.failure;version=[int]$record.version
      sequence=[int]$record.sequence;system_id=[int]$record.system_id
      component_id=[int]$record.component_id;message_id=[int]$record.message_id
      payload_length=[int]$record.payload_length;raw_length=[int]$record.raw_length
      frame_start_us=[int64]$record.frame_start_us;complete_us=[int64]$record.complete_us
      frame_start_raw_offset=[int64]$record.frame_start_raw_offset
      frame_start_read_ordinal=[int64]$record.frame_start_read_ordinal
      complete_read_ordinal=[int64]$record.complete_read_ordinal
      raw_sha256=[string]$record.raw_sha256
    })
    $Cursor.Value=[int]$Cursor.Value+1
  }
}

function Convert-JsonLines([object[]]$Records) {
  if(@($Records).Count -eq 0){return ''}
  return ((@($Records)|ForEach-Object{
    ConvertTo-Json -InputObject $_ -Compress -Depth 30
  })-join$newline)+$newline
}

function Write-BufferedCaptureArtifacts([string]$OutputRoot,
    [IO.MemoryStream]$Raw,[Collections.ArrayList]$Timeline,
    [Collections.ArrayList]$FrameLog,[object]$PumpTiming) {
  $rawPath=Join-Path $OutputRoot 'ground.raw.bin'
  $timelinePath=Join-Path $OutputRoot 'timeline.jsonl'
  $framePath=Join-Path $OutputRoot 'frame_events.jsonl'
  $pumpPath=Join-Path $OutputRoot 'pump_gap_ledger.jsonl'
  Write-DurableBytes $rawPath $Raw.ToArray()
  Write-Durable $timelinePath (Convert-JsonLines @($Timeline))
  Write-Durable $framePath (Convert-JsonLines @($FrameLog))
  Write-Durable $pumpPath (Convert-JsonLines @($PumpTiming.gap_ledger))
  return [pscustomobject][ordered]@{
    result='PASS';persisted_after_serial_close=$true
    raw_bytes=[int64]$Raw.Length;timeline_count=[int]$Timeline.Count
    frame_count=[int]$FrameLog.Count;pump_gap_count=[int]$PumpTiming.ledger_count
    raw_sha256=Get-Sha $rawPath;timeline_sha256=Get-Sha $timelinePath
    frame_events_sha256=Get-Sha $framePath;pump_gap_ledger_sha256=Get-Sha $pumpPath
  }
}

function Wait-HeartbeatPreflight([object]$Serial,[object]$Parser,
    [IO.MemoryStream]$Raw,[Diagnostics.Stopwatch]$Clock,
    [Collections.ArrayList]$Timeline,[Collections.ArrayList]$FrameLog,
    [ref]$FrameCursor,[object]$PumpState,[int64]$DeadlineUs) {
  [int]$analysisCursor=0;[int]$allHeartbeatCount=0
  [int]$excludedBacklogHeartbeatCount=0;[int]$targetParamCount=0
  [int]$backgroundParamCount=0;[int64]$lastFreshRead=[int64]-1
  $freshHeartbeats=[Collections.ArrayList]::new()
  while((Get-ElapsedUs $Clock) -le $DeadlineUs) {
    [void](Read-AvailableSerial $Serial $Parser $Raw $Clock $Timeline `
        $PumpState)
    Buffer-NewFrameEvents $Parser $FrameCursor $FrameLog
    while($analysisCursor-lt$Parser.frames.Count) {
      $record=$Parser.frames[$analysisCursor];++$analysisCursor
      $isPrimary=$record.valid -and [int]$record.version-eq2 -and
          -not[bool]$record.signed -and [int]$record.message_id-eq0 -and
          [int]$record.system_id-eq1 -and [int]$record.component_id-eq1 -and
          [int]$record.payload_length-eq9 -and [int]$record.raw_length-eq21
      if($isPrimary) {
        ++$allHeartbeatCount
        [int64]$ordinal=[int64]$record.complete_read_ordinal
        if($ordinal-le[int64]$Parser.initial_backlog_read_ordinal -or $ordinal-lt0) {
          ++$excludedBacklogHeartbeatCount
        } elseif($ordinal-ne$lastFreshRead) {
          [void]$freshHeartbeats.Add($record);$lastFreshRead=$ordinal
        }
      }
      if([int]$record.message_id-eq22) {
        if(Test-TargetParamIdRecord $record){++$targetParamCount}
        else{++$backgroundParamCount}
      }
    }
    [int64]$now=Get-ElapsedUs $Clock
    [int64]$maximumGap=0
    for($index=1;$index-lt$freshHeartbeats.Count;++$index) {
      [int64]$candidateGap=[int64]$freshHeartbeats[$index].complete_us-
          [int64]$freshHeartbeats[$index-1].complete_us
      if($candidateGap-gt$maximumGap){$maximumGap=$candidateGap}
    }
    [int64]$age=if($freshHeartbeats.Count-gt0){
      $now-[int64]$freshHeartbeats[$freshHeartbeats.Count-1].complete_us
    }else{[int64]::MaxValue}
    $lastTwo=if($freshHeartbeats.Count-ge2){
      @($freshHeartbeats[$freshHeartbeats.Count-2],
        $freshHeartbeats[$freshHeartbeats.Count-1])
    }else{@()}
    $lastTwoCount=@($lastTwo).Count
    $distinctReads=$lastTwoCount-eq2 -and
        [int64]$lastTwo[0].complete_read_ordinal -ne
        [int64]$lastTwo[1].complete_read_ordinal
    $positiveGap=$lastTwoCount-eq2 -and
        [int64]$lastTwo[1].complete_us-[int64]$lastTwo[0].complete_us -gt 0
    if($freshHeartbeats.Count -ge 2 -and
        $distinctReads -and $positiveGap -and
        $maximumGap -le $HeartbeatLimitUs -and $age -le $HeartbeatLimitUs -and
        $targetParamCount -eq 0 -and $Parser.buffer.Count -eq 0 -and
        [int]$Serial.BytesToRead -eq 0 -and [int]$Serial.BytesToWrite -eq 0) {
      return [pscustomobject][ordered]@{
        result='PASS';failure='';heartbeat_count=$freshHeartbeats.Count
        heartbeat_pair=@($freshHeartbeats[$freshHeartbeats.Count-2],
            $freshHeartbeats[$freshHeartbeats.Count-1])
        maximum_gap_us=$maximumGap;last_heartbeat_age_us=$age
        parser_error_count=([int64]$Parser.noise_bytes+[int64]$Parser.bad_length+
            [int64]$Parser.bad_crc+[int64]$Parser.unsupported_flags+
            [int64]$Parser.unknown_definition+[int64]$Parser.buffer.Count+
            [int64]$Parser.startup_buffer.Count)
        classified_startup_bytes=[int64]$Parser.classified_startup_bytes
        classified_startup_sha256=[string]$Parser.classified_startup_sha256
        initial_backlog_read_ordinal=[int64]$Parser.initial_backlog_read_ordinal
        all_primary_heartbeat_count=$allHeartbeatCount
        excluded_initial_backlog_heartbeat_count=$excludedBacklogHeartbeatCount
        fresh_heartbeat_count=$freshHeartbeats.Count
        distinct_read_ordinals=$distinctReads;positive_timestamp_gap=$positiveGap
        unsolicited_target_param_value_count=$targetParamCount
        background_param_value_count=$backgroundParamCount
      }
    }
    Start-Sleep -Milliseconds 5
  }
  throw "90 s overall timeout during heartbeat preflight: fresh_count=$($freshHeartbeats.Count) max=$maximumGap age=$age"
}

function Confirm-FinalRequestBoundary([object]$Serial,[object]$Parser,
    [IO.MemoryStream]$Raw,[Diagnostics.Stopwatch]$Clock,
    [Collections.ArrayList]$Timeline,[Collections.ArrayList]$FrameLog,
    [ref]$FrameCursor,[object]$PumpState) {
  [void](Read-AvailableSerial $Serial $Parser $Raw $Clock $Timeline `
      $PumpState)
  Buffer-NewFrameEvents $Parser $FrameCursor $FrameLog
  $targetParams=@($Parser.frames|Where-Object{Test-TargetParamIdRecord $_})
  Assert-Condition ($targetParams.Count -eq 0) `
      'Pre-request target PARAM_VALUE traffic makes ownership ambiguous.'
  $heartbeats=@(Get-FreshPrimaryHeartbeats $Parser)
  Assert-Condition ($heartbeats.Count -ge 2) `
      'Final request boundary lacks two fresh post-backlog primary heartbeats.'
  $previous=$heartbeats[$heartbeats.Count-2];$latest=$heartbeats[$heartbeats.Count-1]
  [int64]$now=Get-ElapsedUs $Clock
  [int64]$gap=[int64]$latest.complete_us-[int64]$previous.complete_us
  [int64]$age=$now-[int64]$latest.complete_us
  Assert-Condition ($gap -gt 0 -and $gap -le $HeartbeatLimitUs -and
      [int64]$previous.complete_read_ordinal -ne
          [int64]$latest.complete_read_ordinal -and
      [int64]$previous.complete_read_ordinal -gt
          [int64]$Parser.initial_backlog_read_ordinal -and
      $age -ge 0 -and $age -le $HeartbeatLimitUs) `
      "Final heartbeat not fresh: gap=$gap age=$age"
  Assert-Condition ($Parser.buffer.Count -eq 0 -and
      $Parser.startup_buffer.Count -eq 0 -and
      -not [bool]$Parser.startup_classification_pending -and
      [int]$Serial.BytesToRead -eq 0 -and [int]$Serial.BytesToWrite -eq 0) `
      'Final boundary is not idle/complete.'
  return [pscustomobject][ordered]@{
    result='PASS';heartbeat_pair=@($previous,$latest);maximum_gap_us=$gap
    last_heartbeat_age_us=$age;raw_offset=[int64]$Parser.total_bytes
    frame_index=[int]$Parser.frames.Count
    initial_backlog_read_ordinal=[int64]$Parser.initial_backlog_read_ordinal
    parser_baseline=Get-ParserSnapshot $Parser;confirmed_us=$now
  }
}

function Test-ExactPaddedParamId([byte[]]$Raw,[int]$PayloadOffset) {
  [byte[]]$expected=[Text.Encoding]::ASCII.GetBytes(
      'SERIAL1_BAUD'+[char]0+[char]0+[char]0+[char]0)
  for($index=0;$index -lt 16;++$index) {
    if($Raw[$PayloadOffset+8+$index] -ne $expected[$index]){return $false}
  }
  return $true
}

function Get-ParamValueId([object]$Record) {
  if($null-eq$Record -or [int]$Record.message_id-ne22 -or
      [int]$Record.payload_length-lt24){return ''}
  [byte[]]$raw=$Record.raw;[int]$offset=[int]$Record.payload_offset
  if($offset-lt0 -or $raw.Length-lt($offset+24)){return ''}
  return [Text.Encoding]::ASCII.GetString($raw,$offset+8,16).TrimEnd([char]0)
}

function Test-TargetParamIdRecord([object]$Record) {
  if($null-eq$Record -or [int]$Record.message_id-ne22 -or
      [int]$Record.payload_length-lt24){return $false}
  [byte[]]$raw=$Record.raw;[int]$offset=[int]$Record.payload_offset
  if($offset-lt0 -or $raw.Length-lt($offset+24)){return $false}
  return Test-ExactPaddedParamId $raw $offset
}

function Test-ExactTargetResponseRecord([object]$Record) {
  if(-not(Test-TargetParamIdRecord $Record)){return $false}
  $shape=$Record.valid -and [int]$Record.version-eq2 -and
      -not[bool]$Record.signed -and [int]$Record.system_id-eq1 -and
      [int]$Record.component_id-eq1 -and [int]$Record.payload_length-eq25 -and
      [int]$Record.raw_length-eq37
  if(-not$shape){return $false}
  [byte[]]$raw=$Record.raw;[int]$offset=[int]$Record.payload_offset
  return [BitConverter]::ToUInt32($raw,$offset)-eq[uint32]0x42640000 -and
      [BitConverter]::ToUInt16($raw,$offset+4)-eq932 -and
      [BitConverter]::ToUInt16($raw,$offset+6)-eq0xFFFF -and
      [int]$raw[$offset+24]-eq6
}

function Convert-ParamValueLedgerRecord([object]$Record,[string]$Classification,
    [object]$Boundary) {
  [byte[]]$raw=$Record.raw;[int]$offset=[int]$Record.payload_offset
  $decodable=[int]$Record.payload_length-ge25 -and $raw.Length-ge($offset+25)
  return [pscustomobject][ordered]@{
    classification=$Classification;valid=[bool]$Record.valid
    failure=[string]$Record.failure;param_id=(Get-ParamValueId $Record)
    value_bits=if($decodable){'0x{0:X8}'-f[BitConverter]::ToUInt32($raw,$offset)}else{''}
    firmware_value=if($decodable){[BitConverter]::ToSingle($raw,$offset)}else{$null}
    param_count=if($decodable){[BitConverter]::ToUInt16($raw,$offset+4)}else{-1}
    param_index=if($decodable){[BitConverter]::ToUInt16($raw,$offset+6)}else{-1}
    param_type=if($decodable){[int]$raw[$offset+24]}else{-1}
    sequence=[int]$Record.sequence;system_id=[int]$Record.system_id
    component_id=[int]$Record.component_id;version=[int]$Record.version
    signed=[bool]$Record.signed;frame_start_us=[int64]$Record.frame_start_us
    complete_us=[int64]$Record.complete_us
    after_request_complete_edge=([int64]$Record.frame_start_us-ge
        [int64]$Boundary.request_complete_write_edge_us -and
        [int64]$Record.complete_us-ge[int64]$Boundary.request_complete_write_edge_us)
    frame_start_raw_offset=[int64]$Record.frame_start_raw_offset
    raw_length=[int]$Record.raw_length;raw_sha256=[string]$Record.raw_sha256
    stored_crc=[int]$Record.stored_crc;computed_crc=[int]$Record.computed_crc
    crc_match=([int]$Record.stored_crc-eq[int]$Record.computed_crc)
  }
}

function New-TargetResponseProgress([int]$StartFrameIndex) {
  return [pscustomobject][ordered]@{
    next_frame_index=$StartFrameIndex;response_complete_us=[int64]-1
    exact_target_count=0;post_response_heartbeat_count=0
  }
}

function Update-TargetResponseProgress([object]$Parser,[object]$Progress,
    [object]$Boundary) {
  while([int]$Progress.next_frame_index-lt$Parser.frames.Count) {
    $record=$Parser.frames[[int]$Progress.next_frame_index]
    $Progress.next_frame_index=[int]$Progress.next_frame_index+1
    $causal=[int64]$record.frame_start_us-ge
        [int64]$Boundary.request_complete_write_edge_us -and
        [int64]$record.complete_us-ge[int64]$Boundary.request_complete_write_edge_us
    if($causal -and (Test-ExactTargetResponseRecord $record)) {
      $Progress.exact_target_count=[int]$Progress.exact_target_count+1
      if([int64]$Progress.response_complete_us-lt0){
        $Progress.response_complete_us=[int64]$record.complete_us
      }
    }
    if([int64]$Progress.response_complete_us-ge0 -and [bool]$record.valid -and
        [int]$record.version-eq2 -and -not[bool]$record.signed -and
        [int]$record.message_id-eq0 -and [int]$record.system_id-eq1 -and
        [int]$record.component_id-eq1 -and [int]$record.payload_length-eq9 -and
        [int64]$record.complete_us-gt[int64]$Progress.response_complete_us) {
      $Progress.post_response_heartbeat_count=[int]$Progress.post_response_heartbeat_count+1
    }
  }
  return $Progress
}

function Get-SingleParamAcceptance([object]$Parser,[object]$Boundary,
    [object[]]$PreHeartbeats,[int64]$CaptureEndUs,
    [object]$PumpTiming) {
  $records=@($Parser.frames|Where-Object{
    [int64]$_.frame_start_raw_offset -ge [int64]$Boundary.raw_offset -and
        [int64]$_.complete_us -ge [int64]$Boundary.request_write_started_us
  })
  $parameterFrames=@($records|Where-Object{$_.message_id -eq 22})
  $causalParameterFrames=@($parameterFrames|Where-Object{
    [int64]$_.frame_start_us -ge [int64]$Boundary.request_complete_write_edge_us -and
        [int64]$_.complete_us -ge [int64]$Boundary.request_complete_write_edge_us
  })
  [int]$noncausalParameterFrames=$parameterFrames.Count-$causalParameterFrames.Count
  $paramErrorFrames=@($records|Where-Object{$_.message_id -eq 345})
  $postHeartbeats=@($records|Where-Object{
    $_.valid -and $_.version -eq 2 -and -not $_.signed -and
        $_.message_id -eq 0 -and $_.system_id -eq 1 -and
        $_.component_id -eq 1 -and $_.payload_length -eq 9 -and
        $_.raw_length -eq 21
  })
  $targetParameterFrames=@($parameterFrames|Where-Object{
    Test-TargetParamIdRecord $_
  })
  $backgroundParameterFrames=@($parameterFrames|Where-Object{
    -not(Test-TargetParamIdRecord $_)
  })
  $causalTargetFrames=@($targetParameterFrames|Where-Object{
    [int64]$_.frame_start_us-ge[int64]$Boundary.request_complete_write_edge_us -and
        [int64]$_.complete_us-ge[int64]$Boundary.request_complete_write_edge_us
  })
  [int]$noncausalTargetFrames=$targetParameterFrames.Count-$causalTargetFrames.Count
  $exact=[Collections.ArrayList]::new();[int]$targetSemanticMismatchCount=0
  foreach($record in $causalTargetFrames) {
    if(Test-ExactTargetResponseRecord $record){[void]$exact.Add($record)}
    else{++$targetSemanticMismatchCount}
  }
  $backgroundLedger=[Collections.ArrayList]::new()
  foreach($record in $backgroundParameterFrames) {
    [void]$backgroundLedger.Add((Convert-ParamValueLedgerRecord $record `
        'BACKGROUND_DIFFERENT_PARAM_ID' $Boundary))
  }
  [int]$exact_response_count=$exact.Count
  $selectedResponse=$null
  [int64]$responseUs=if($exact_response_count -ge 1){
    [int64]$exact[0].complete_us
  }else{[int64]-1}
  if($exact_response_count -ge 1) {
    $selected=$exact[0];[byte[]]$selectedRaw=$selected.raw
    [int]$selectedOffset=[int]$selected.payload_offset
    $selectedResponse=[pscustomobject][ordered]@{
      param_id='SERIAL1_BAUD'
      value_bits=('0x{0:X8}' -f [BitConverter]::ToUInt32($selectedRaw,$selectedOffset))
      firmware_value=[BitConverter]::ToSingle($selectedRaw,$selectedOffset)
      physical_baud_interpretation=57600
      param_count=[BitConverter]::ToUInt16($selectedRaw,$selectedOffset+4)
      param_index=[BitConverter]::ToUInt16($selectedRaw,$selectedOffset+6)
      param_type=[int]$selectedRaw[$selectedOffset+24]
      sequence=[int]$selected.sequence;system_id=[int]$selected.system_id
      component_id=[int]$selected.component_id
      frame_start_us=[int64]$selected.frame_start_us
      complete_us=[int64]$selected.complete_us
      frame_start_raw_offset=[int64]$selected.frame_start_raw_offset
      raw_length=[int]$selected.raw_length
      raw_sha256=[string]$selected.raw_sha256
      raw_hex=(-join($selectedRaw|ForEach-Object{$_.ToString('X2')}))
      stored_crc=[int]$selected.stored_crc
      computed_crc=[int]$selected.computed_crc
      crc_match=([int]$selected.stored_crc -eq [int]$selected.computed_crc)
      artifact_path='exact_param_value_response.bin'
    }
  }
  $laterHeartbeats=@($postHeartbeats|Where-Object{
    [int64]$_.complete_us -gt $responseUs
  })
  [int]$post_response_heartbeat_count=$laterHeartbeats.Count
  $preFrames=@($PreHeartbeats|Sort-Object complete_us,complete_read_ordinal)
  $postFrames=@($postHeartbeats|Sort-Object complete_us,complete_read_ordinal)
  $preTimes=@($preFrames|ForEach-Object{[int64]$_.complete_us})
  $postTimes=@($postFrames|ForEach-Object{[int64]$_.complete_us})
  [int64]$lastPre=if($preTimes.Count){[int64]$preTimes[-1]}else{-1}
  [int64]$firstPost=if($postTimes.Count){[int64]$postTimes[0]}else{[int64]::MaxValue}
  [int64]$preGap=if($preTimes.Count -ge 2){
    [int64]$preTimes[-1]-[int64]$preTimes[-2]
  }else{[int64]::MaxValue}
  $preDistinctReads=$preFrames.Count-ge2 -and
      [int64]$preFrames[-1].complete_read_ordinal -gt 0 -and
      [int64]$preFrames[-2].complete_read_ordinal -gt 0 -and
      [int64]$preFrames[-1].complete_read_ordinal -ne
          [int64]$preFrames[-2].complete_read_ordinal
  $prePositiveGap=$preGap-gt0 -and $preGap-ne[int64]::MaxValue
  [int64]$preAge=[int64]$Boundary.request_complete_write_edge_us-$lastPre
  [int64]$lastPreToFirst=$firstPost-$lastPre
  [int64]$requestToFirst=$firstPost-[int64]$Boundary.request_complete_write_edge_us
  [int64]$maxPost=0
  for($i=1;$i -lt $postTimes.Count;++$i){
    [int64]$gap=[int64]$postTimes[$i]-[int64]$postTimes[$i-1]
    if($gap -gt $maxPost){$maxPost=$gap}
  }
  [int64]$responseToPost=if($laterHeartbeats.Count){
    [int64]$laterHeartbeats[0].complete_us-$responseUs
  }else{[int64]::MaxValue}
  [int64]$tailGap=if($postTimes.Count){$CaptureEndUs-[int64]$postTimes[-1]}
      else{[int64]::MaxValue}
  $allHeartbeatFrames=@($preFrames+$postFrames|Sort-Object complete_us)
  $gapLedger=[Collections.ArrayList]::new();[int64]$maximumLedgerGap=0
  for($ledgerIndex=1;$ledgerIndex-lt$allHeartbeatFrames.Count;++$ledgerIndex) {
    $from=$allHeartbeatFrames[$ledgerIndex-1];$to=$allHeartbeatFrames[$ledgerIndex]
    [int64]$ledgerGap=[int64]$to.complete_us-[int64]$from.complete_us
    if($ledgerGap-gt$maximumLedgerGap){$maximumLedgerGap=$ledgerGap}
    [void]$gapLedger.Add([pscustomobject][ordered]@{
      ordinal=$ledgerIndex;from_complete_us=[int64]$from.complete_us
      to_complete_us=[int64]$to.complete_us;gap_us=$ledgerGap
      from_sequence=[int]$from.sequence;to_sequence=[int]$to.sequence
      crosses_request_complete_edge=([int64]$from.complete_us -le
          [int64]$Boundary.request_complete_write_edge_us -and
          [int64]$to.complete_us -ge [int64]$Boundary.request_complete_write_edge_us)
      within_limit=($ledgerGap-ge 0 -and $ledgerGap-le$HeartbeatLimitUs)
    })
  }
  [int64]$duplicateObservation=if($responseUs-ge 0){$CaptureEndUs-$responseUs}else{-1}
  $duplicateTailCompleted=$duplicateObservation-ge$DuplicateObservationUs
  $delta=Get-ParserErrorDelta $Parser $Boundary.parser_baseline
  [int64]$parser_error_count=[int64]$delta.noise_bytes+
      [int64]$delta.bad_lengths+[int64]$delta.bad_crc+
      [int64]$delta.unsupported_flags+[int64]$delta.unknown_definition+
      [int64]$delta.partial_bytes+[int64]$delta.unclassified_startup_bytes
  [int64]$control_leakage_bytes=[int64]$delta.noise_bytes
  [int]$duplicateTargetResponseCount=[math]::Max(0,
      $causalTargetFrames.Count-1)
  $heartbeatPass=$preTimes.Count -ge 2 -and $preDistinctReads -and
      $prePositiveGap -and $postTimes.Count -ge 1 -and
      $post_response_heartbeat_count -ge 1 -and $preGap -le $HeartbeatLimitUs -and
      $preAge -ge 0 -and $preAge -le $HeartbeatLimitUs -and
      $lastPreToFirst -ge 0 -and $lastPreToFirst -le $HeartbeatLimitUs -and
      $requestToFirst -ge 0 -and $requestToFirst -le $HeartbeatLimitUs -and
      $maxPost -le $HeartbeatLimitUs -and $maximumLedgerGap-le$HeartbeatLimitUs -and
      $responseToPost -ge 0 -and
      $responseToPost -le $HeartbeatLimitUs -and $tailGap -ge 0 -and
      $tailGap -le $HeartbeatLimitUs
  $responsePass=$targetParameterFrames.Count -eq 1 -and
      $causalTargetFrames.Count -eq 1 -and $noncausalTargetFrames-eq 0 -and
      $exact_response_count -eq 1 -and $targetSemanticMismatchCount-eq 0 -and
      $duplicateTargetResponseCount-eq0 -and
      $paramErrorFrames.Count -eq 0 -and $duplicateTailCompleted
  [int64]$maximumPumpServiceGapUs=[int64]$PumpTiming.maximum_gap_us
  $timingPass=$maximumPumpServiceGapUs -le $PumpServiceLimitUs
  $pass=$responsePass -and $heartbeatPass -and $parser_error_count -eq 0 -and
      $control_leakage_bytes -eq 0 -and $timingPass -and
      [string]$Boundary.request_outcome -ceq 'COMPLETE'
  return [pscustomobject][ordered]@{
    result=if($pass){'PASS'}else{'FAIL'}
    response_result=if($responsePass){'PASS'}else{'FAIL'}
    heartbeat_result=if($heartbeatPass){'PASS'}else{'FAIL'}
    parameter_frames=$parameterFrames.Count
    causal_parameter_frames=$causalParameterFrames.Count
    noncausal_parameter_frames=$noncausalParameterFrames
    target_parameter_frames=$targetParameterFrames.Count
    causal_target_parameter_frames=$causalTargetFrames.Count
    noncausal_target_parameter_frames=$noncausalTargetFrames
    background_parameter_frames=$backgroundParameterFrames.Count
    valid_background_parameter_frames=@($backgroundParameterFrames|Where-Object{
      [bool]$_.valid
    }).Count
    background_parameter_ledger=@($backgroundLedger)
    exact_response_count=$exact_response_count
    target_semantic_mismatch_count=$targetSemanticMismatchCount
    duplicate_target_response_count=$duplicateTargetResponseCount
    param_error_frames=$paramErrorFrames.Count
    selected_response=$selectedResponse
    wrong_or_unexpected_response_count=$targetSemanticMismatchCount
    response_complete_us=$responseUs
    response_latency_us=if($responseUs -ge 0){
      $responseUs-[int64]$Boundary.request_complete_write_edge_us
    }else{-1}
    param_id='SERIAL1_BAUD';expected_firmware_value=57.0
    physical_baud_interpretation=57600;expected_value_bits='0x42640000'
    post_response_heartbeat_count=$post_response_heartbeat_count
    duplicate_observation_us=$duplicateObservation
    duplicate_observation_required_us=$DuplicateObservationUs
    duplicate_observation_completed=$duplicateTailCompleted
    heartbeat=[pscustomobject][ordered]@{
      preflight_count=$preTimes.Count;post_request_count=$postTimes.Count
      preflight_pair_gap_us=$preGap
      preflight_distinct_read_ordinals=$preDistinctReads
      preflight_positive_timestamp_gap=$prePositiveGap
      pre_to_request_age_us=$preAge
      last_pre_to_first_post_gap_us=$lastPreToFirst
      request_to_first_post_us=$requestToFirst
      maximum_consecutive_post_gap_us=$maxPost
      maximum_full_gap_ledger_us=$maximumLedgerGap
      gap_ledger=@($gapLedger)
      response_to_next_heartbeat_us=$responseToPost;tail_gap_us=$tailGap
      limit_us=$HeartbeatLimitUs
    }
    parser=$delta;parser_error_count=$parser_error_count
    control_leakage_bytes=$control_leakage_bytes
    all_parser_crc_noise_partial_control_errors_zero=($parser_error_count -eq 0)
    classified_startup_bytes=[int64]$Parser.classified_startup_bytes
    classified_startup_sha256=[string]$Parser.classified_startup_sha256
    initial_boot_banner_policy='EXACT_INITIAL_266_BYTE_ESP32S3_ROM_BANNER_ONLY'
    timing_result=if($timingPass){'PASS'}else{'FAIL'}
    pump_timing=$PumpTiming
    maximum_pump_service_gap_us=$maximumPumpServiceGapUs
    pump_service_limit_us=$PumpServiceLimitUs
  }
}

function Write-SelectedResponseArtifact([object]$Accounting) {
  if($null-eq$Accounting -or $null-eq$Accounting.selected_response){return}
  [byte[]]$bytes=Convert-HexToBytes ([string]$Accounting.selected_response.raw_hex)
  $expected=[string]$Accounting.selected_response.raw_sha256
  Assert-Condition ($bytes.Length-eq 37 -and (Get-ByteSha $bytes)-ceq$expected) `
      'Selected PARAM_VALUE raw artifact integrity mismatch.'
  $path=Join-Path $evidence 'exact_param_value_response.bin'
  if(Test-Path -LiteralPath $path -PathType Leaf){
    Assert-Condition ((Get-Sha $path)-ceq$expected) `
        'Existing selected PARAM_VALUE artifact does not match.'
  }else{Write-DurableBytes $path $bytes}
}

function Invoke-FailClosedCleanupPlan([object[]]$Steps) {
  $errors=[Collections.ArrayList]::new();$records=[Collections.ArrayList]::new()
  foreach($step in $Steps) {
    try {[void](& $step.action);[void]$records.Add([pscustomobject][ordered]@{name=[string]$step.name;result='PASS';failure=''})}
    catch {[void]$records.Add([pscustomobject][ordered]@{name=[string]$step.name;result='FAIL';failure=$_.Exception.Message});[void]$errors.Add("$([string]$step.name): $($_.Exception.Message)")}
  }
  return [pscustomobject][ordered]@{
    result=if($errors.Count -eq 0){'PASS'}else{'FAIL'}
    error_count=$errors.Count;errors=@($errors);steps=@($records)
  }
}

function Invoke-LiveMeasurement {
  $serial=$null
  $raw=[IO.MemoryStream]::new()
  $timeline=[Collections.ArrayList]::new()
  $frameLog=[Collections.ArrayList]::new()
  $pumpState=New-PumpTimingState;$pumpTiming=$null
  $parser=New-MavlinkParser 'ground_com6';$clock=[Diagnostics.Stopwatch]::StartNew()
  [int]$frameCursor=0
  $identityBefore=$null;$identityAtOpen=$null;$processInventory=$null
  $identityAfterCloseHolder=[pscustomobject]@{value=$null}
  $preflight=$null;$boundary=$null;$accounting=$null;[int64]$captureEnd=-1
  $captureHolder=[pscustomobject]@{value=$null};$progress=$null
  try {
    $processInventory=Assert-NoCompetingClients
    $identityBefore=Assert-ExactGroundIdentity 'before_open'
    $identityAtOpen=Assert-ExactGroundIdentity 'immediately_before_open'
    $serial=New-GroundSerialPort
    $serial.Open();$script:ExternalActions.com_ports_opened=$true
    [int64]$deadline=$OverallTimeoutUs
    Set-PumpPhase $pumpState 'preflight'
    $preflight=Wait-HeartbeatPreflight $serial $parser $raw $clock $timeline `
        $frameLog ([ref]$frameCursor) $pumpState $deadline
    Assert-Condition ([int64]$preflight.parser_error_count -eq 0) `
        'Preflight parser was not clean.'
    Set-PumpPhase $pumpState 'boundary'
    $final=Confirm-FinalRequestBoundary $serial $parser $raw $clock $timeline `
        $frameLog ([ref]$frameCursor) $pumpState
    [byte[]]$request=New-ExactParamRequestRead
    $nowUs={Get-ElapsedUs $clock};$waitOne={Start-Sleep -Milliseconds 1}
    [int64]$rawBoundary=[int64]$final.raw_offset
    Set-PumpPhase $pumpState 'request_drain'
    Register-PumpService $pumpState (Get-ElapsedUs $clock)
    $write=Invoke-ExactRequestWrite $serial $request $nowUs $waitOne
    Register-PumpService $pumpState (Get-ElapsedUs $clock)
    $boundary=[pscustomobject][ordered]@{
      request_write_started_us=[int64]$write.request_write_started_us
      request_complete_write_edge_us=[int64]$write.request_complete_write_edge_us
      request_outcome='COMPLETE';raw_offset=$rawBoundary
      frame_index=[int]$final.frame_index
      parser_baseline=$final.parser_baseline
      pre_heartbeat_pair=@($final.heartbeat_pair)
    }
    Assert-Condition ($timeline.Count-lt$TimelineEventLimit) `
        'Timeline exceeded its fail-closed in-memory event limit.'
    [void]$timeline.Add([pscustomobject][ordered]@{
      kind='PARAM_REQUEST_READ';bytes=32;sha256=$exactRequestSha256
      request_write_started_us=[int64]$write.request_write_started_us
      request_complete_write_edge_us=[int64]$write.request_complete_write_edge_us
      exactly_once=$true;retry_allowed=$false
    })
    $progress=New-TargetResponseProgress ([int]$boundary.frame_index)
    Set-PumpPhase $pumpState 'response_tail'
    while($true) {
      [int64]$now=Get-ElapsedUs $clock
      if($now -gt $OverallTimeoutUs){throw 'Single-parameter liveness overall timeout (90 s); no retry.'}
      [void](Read-AvailableSerial $serial $parser $raw $clock $timeline $pumpState)
      Buffer-NewFrameEvents $parser ([ref]$frameCursor) $frameLog
      [void](Update-TargetResponseProgress $parser $progress $boundary)
      if([int64]$progress.response_complete_us -ge 0 -and
          $now -ge [int64]$progress.response_complete_us+$DuplicateObservationUs -and
          [int]$progress.post_response_heartbeat_count -ge 1){break}
      Start-Sleep -Milliseconds 5
    }
    Set-PumpPhase $pumpState 'final_drain'
    [void](Read-AvailableSerial $serial $parser $raw $clock $timeline $pumpState)
    Buffer-NewFrameEvents $parser ([ref]$frameCursor) $frameLog
    [void](Update-TargetResponseProgress $parser $progress $boundary)
    $captureEnd=Get-ElapsedUs $clock
    Set-PumpPhase $pumpState 'capture_complete'
    $pumpTiming=Get-PumpTimingEvidence $pumpState
    $accounting=Get-SingleParamAcceptance $parser $boundary `
        @($boundary.pre_heartbeat_pair) $captureEnd $pumpTiming
    $script:LastMeasurement=[pscustomobject][ordered]@{
      result=[string]$accounting.result;failure=''
      identity_before_open=$identityBefore
      identity_immediately_before_open=$identityAtOpen
      identity_after_close=$null
      process_inventory_count=[int]$processInventory.inventory_count
      process_gate=$processInventory
      serial_configuration=[pscustomobject][ordered]@{
        port='COM6';baud=57600;data_bits=8;parity='None';stop_bits='One'
        dtr_enable=$false;rts_enable=$false;handshake='None'
        uninterrupted_handle_count=1
      }
      preflight=$preflight;request=$script:RequestState
      measurement_boundary=$boundary;capture_end_us=$captureEnd
      accounting=$accounting;pump_timing=$pumpTiming
      capture_persistence=$null
      timestamp_basis='Stopwatch frame-complete high-frequency pump; <=100 ms hard gate.'
    }
    Assert-Condition ([string]$accounting.result -ceq 'PASS') `
        'R18 production single-parameter liveness acceptance failed.'
    return $script:LastMeasurement
  } catch {
    $failure=$_.Exception.Message
    if($null -ne $boundary -and $null -eq $accounting) {
      try {
        if($captureEnd-lt0){$captureEnd=Get-ElapsedUs $clock}
        if($null-eq$pumpTiming){$pumpTiming=Get-PumpTimingEvidence $pumpState}
        $accounting=Get-SingleParamAcceptance $parser $boundary `
          $(if($boundary.PSObject.Properties['pre_heartbeat_pair']){
            @($boundary.pre_heartbeat_pair)
          }elseif($null-ne$preflight){@($preflight.heartbeat_pair)}else{@()}) `
          $captureEnd $pumpTiming
      }catch{}
    }
    $script:LastMeasurement=[pscustomobject][ordered]@{
      result='FAIL';failure=$failure;identity_before_open=$identityBefore
      identity_immediately_before_open=$identityAtOpen
      identity_after_close=$null
      process_inventory_count=if($null-ne$processInventory){[int]$processInventory.inventory_count}else{0}
      process_gate=$processInventory
      preflight=$preflight;request=$script:RequestState
      measurement_boundary=$boundary;capture_end_us=$captureEnd;accounting=$accounting
      pump_timing=$pumpTiming;capture_persistence=$null
    }
    throw
  } finally {
    if($null-eq$pumpTiming){$pumpTiming=Get-PumpTimingEvidence $pumpState}
    $cleanupPlan=@(
      [pscustomobject]@{name='frame_ledger_final_append';action={
        Buffer-NewFrameEvents $parser ([ref]$frameCursor) $frameLog
      }},
      [pscustomobject]@{name='serial_close';action={if($null-ne$serial -and $serial.IsOpen){$serial.Close()};if($null-ne$serial -and $serial.IsOpen){throw 'COM6 remained open after Close().'}}},
      [pscustomobject]@{name='serial_dispose';action={if($null-ne$serial){$serial.Dispose()}}},
      [pscustomobject]@{name='identity_after_close';action={
        if($null-ne$serial){
          $identityAfterCloseHolder.value=Assert-ExactGroundIdentity 'after_close'
        }
      }},
      [pscustomobject]@{name='buffered_capture_persist_after_close';action={
        $captureHolder.value=Write-BufferedCaptureArtifacts $evidence $raw `
            $timeline $frameLog $pumpTiming
      }},
      [pscustomobject]@{name='selected_response_persist_after_close';action={
        if($null-ne$accounting){Write-SelectedResponseArtifact $accounting}
      }},
      [pscustomobject]@{name='raw_memory_dispose';action={
        if($null-ne$raw){$raw.Dispose()}
      }}
    )
    $cleanup=Invoke-FailClosedCleanupPlan $cleanupPlan;$clock.Stop()
    $script:CleanupResult=[pscustomobject][ordered]@{
      result=[string]$cleanup.result;error_count=[int]$cleanup.error_count
      errors=@($cleanup.errors);steps=@($cleanup.steps)
      serial_is_open_after_cleanup=if($null-ne$serial){try{[bool]$serial.IsOpen}catch{$false}}else{$false}
    }
    if($null-ne$script:LastMeasurement){
      $script:LastMeasurement|Add-Member NoteProperty cleanup $script:CleanupResult -Force
      $script:LastMeasurement.capture_persistence=$captureHolder.value
      $script:LastMeasurement.pump_timing=$pumpTiming
      $script:LastMeasurement.identity_after_close=$identityAfterCloseHolder.value
      if([string]$cleanup.result -cne 'PASS'){
        $script:LastMeasurement.result='FAIL'
        $script:LastMeasurement.failure=([string]$script:LastMeasurement.failure+' | cleanup: '+(@($cleanup.errors)-join ' | ')).Trim(' ','|')
      }
    }
    if([string]$cleanup.result -cne 'PASS'){
      throw ('Measurement cleanup/durability failure: '+(@($cleanup.errors)-join ' | '))
    }
  }
}

function New-SyntheticFrame([int]$MessageId,[byte[]]$Payload,[byte]$CrcExtra,
    [byte]$Sequence=1,[byte]$SystemId=1,[byte]$ComponentId=1,
    [switch]$Signed) {
  [int]$signatureBytes=if($Signed.IsPresent){13}else{0}
  [byte[]]$frame=New-Object byte[] (12+$Payload.Length+$signatureBytes)
  $frame[0]=0xFD;$frame[1]=[byte]$Payload.Length
  $frame[2]=if($Signed.IsPresent){1}else{0};$frame[4]=$Sequence
  $frame[5]=$SystemId;$frame[6]=$ComponentId;$frame[7]=[byte]($MessageId-band 0xFF)
  $frame[8]=[byte](($MessageId-shr 8)-band 0xFF);$frame[9]=[byte](($MessageId-shr 16)-band 0xFF)
  [array]::Copy($Payload,0,$frame,10,$Payload.Length)
  [uint16]$crc=0xFFFF
  for($i=1;$i -lt 10+$Payload.Length;++$i){$crc=Update-X25Crc $crc $frame[$i]}
  $crc=Update-X25Crc $crc $CrcExtra
  $frame[10+$Payload.Length]=[byte]($crc-band 0xFF)
  $frame[11+$Payload.Length]=[byte](($crc-shr 8)-band 0xFF)
  return $frame
}
function New-SyntheticHeartbeat([byte]$Sequence=1,[byte]$SystemId=1,
    [byte]$ComponentId=1) {
  [byte[]]$payload=New-Object byte[] 9
  return New-SyntheticFrame 0 $payload 50 $Sequence $SystemId $ComponentId
}
function New-SyntheticParamValue([string]$Id='SERIAL1_BAUD',
    [uint32]$ValueBits=[uint32]0x42640000,[byte]$SystemId=1,
    [byte]$ComponentId=1,[byte]$Sequence=1,[int]$ParamCount=932,
    [int]$ParamIndex=65535,[int]$ParamType=6,[switch]$Signed) {
  [byte[]]$payload=New-Object byte[] 25
  $payload[0]=[byte]($ValueBits-band 0xFF);$payload[1]=[byte](($ValueBits-shr 8)-band 0xFF)
  $payload[2]=[byte](($ValueBits-shr 16)-band 0xFF);$payload[3]=[byte](($ValueBits-shr 24)-band 0xFF)
  $payload[4]=[byte]($ParamCount-band 0xFF)
  $payload[5]=[byte](($ParamCount-shr 8)-band 0xFF)
  $payload[6]=[byte]($ParamIndex-band 0xFF)
  $payload[7]=[byte](($ParamIndex-shr 8)-band 0xFF)
  [byte[]]$idBytes=[Text.Encoding]::ASCII.GetBytes($Id)
  [array]::Copy($idBytes,0,$payload,8,[math]::Min(16,$idBytes.Length));$payload[24]=[byte]$ParamType
  return New-SyntheticFrame 22 $payload 220 $Sequence $SystemId $ComponentId `
      -Signed:$Signed.IsPresent
}
function New-SyntheticMavlink1ParamValue([byte]$Sequence=1) {
  [byte[]]$v2=New-SyntheticParamValue -Sequence $Sequence
  [byte[]]$payload=New-Object byte[] 25;[array]::Copy($v2,10,$payload,0,25)
  [byte[]]$frame=New-Object byte[] 33
  $frame[0]=0xFE;$frame[1]=25;$frame[2]=$Sequence;$frame[3]=1;$frame[4]=1;$frame[5]=22
  [array]::Copy($payload,0,$frame,6,25);[uint16]$crc=0xFFFF
  for($i=1;$i-lt31;++$i){$crc=Update-X25Crc $crc $frame[$i]}
  $crc=Update-X25Crc $crc 220;$frame[31]=[byte]($crc-band 0xFF)
  $frame[32]=[byte](($crc-shr 8)-band 0xFF);return $frame
}
function New-SyntheticShortParamValue([byte]$Sequence=1) {
  [byte[]]$payload=New-Object byte[] 24
  return New-SyntheticFrame 22 $payload 220 $Sequence 1 1
}
function New-SyntheticParamError([byte]$Sequence=9) {
  [byte[]]$payload=New-Object byte[] 21
  return New-SyntheticFrame 345 $payload 209 $Sequence 1 1
}

function Reset-OfflineState {
  $script:RequestState.request_attempted=0
  $script:RequestState.request_write_started_us=[int64]-1
  $script:RequestState.request_write_call_completed=0
  $script:RequestState.request_writes_completed=0
  $script:RequestState.request_complete_write_edge_us=[int64]-1
  $script:RequestState.request_outcome='NOT_ATTEMPTED'
}

function New-FakeSerial([switch]$NeverDrains) {
  $state=[pscustomobject]@{writes=0;bytes=[Collections.Generic.List[byte]]::new()}
  $object=[pscustomobject]@{BytesToWrite=if($NeverDrains.IsPresent){1}else{0};state=$state}
  $object|Add-Member ScriptMethod Write {
    param([byte[]]$buffer,[int]$offset,[int]$count)
    $this.state.writes++
    for($i=0;$i-lt$count;++$i){$this.state.bytes.Add($buffer[$offset+$i])}
  }
  return $object
}

function New-SyntheticScenario([string]$Mutation='none') {
  $parser=New-MavlinkParser 'offline' $true
  [int64]$readOrdinal=1
  Add-MavlinkBytes $parser (New-SyntheticHeartbeat 0) 500000 $readOrdinal
  ++$readOrdinal
  Add-MavlinkBytes $parser (New-SyntheticHeartbeat 1) 1000000 $readOrdinal
  if($Mutation -ne 'missing_preflight'){
    ++$readOrdinal
    $secondTime=if($Mutation -eq 'heartbeat_gap'){4000001}else{2000000}
    Add-MavlinkBytes $parser (New-SyntheticHeartbeat 2) $secondTime $readOrdinal
  }
  $pre=@(Get-FreshPrimaryHeartbeats $parser)
  [int64]$r0=if($Mutation -eq 'heartbeat_gap'){4100000}else{2100000}
  $boundary=[pscustomobject][ordered]@{
    request_write_started_us=$r0;request_complete_write_edge_us=$r0+1000
    request_outcome='COMPLETE';raw_offset=[int64]$parser.total_bytes
    frame_index=[int]$parser.frames.Count
    parser_baseline=Get-ParserSnapshot $parser
    pre_heartbeat_pair=@($pre|Sort-Object complete_us|Select-Object -Last 2)
  }
  ++$readOrdinal
  Add-MavlinkBytes $parser (New-SyntheticHeartbeat 3) ($r0+900000) $readOrdinal
  $response=if($Mutation -eq 'wrong_source'){
    New-SyntheticParamValue -SystemId 2 -Sequence 4
  }elseif($Mutation -eq 'wrong_id' -or $Mutation -eq 'background_only'){
    New-SyntheticParamValue -Id 'STAT_RUNTIME' -Sequence 4
  }elseif($Mutation -eq 'wrong_value'){
    New-SyntheticParamValue -ValueBits ([uint32]0x42680000) -Sequence 4
  }elseif($Mutation -eq 'wrong_count'){
    New-SyntheticParamValue -ParamCount 933 -Sequence 4
  }elseif($Mutation -eq 'wrong_index'){
    New-SyntheticParamValue -ParamIndex 0 -Sequence 4
  }elseif($Mutation -eq 'wrong_type'){
    New-SyntheticParamValue -ParamType 9 -Sequence 4
  }elseif($Mutation -eq 'signed'){
    New-SyntheticParamValue -Signed -Sequence 4
  }elseif($Mutation -eq 'v1'){
    New-SyntheticMavlink1ParamValue -Sequence 4
  }elseif($Mutation -eq 'length'){
    New-SyntheticShortParamValue -Sequence 4
  }else{New-SyntheticParamValue -Sequence 4}
  if($Mutation -eq 'crc'){$response[$response.Length-1]=$response[$response.Length-1]-bxor 0x80}
  [int64]$responseTime=if($Mutation -eq 'noncausal'){
    $r0+500
  }else{$r0+1900000}
  if($Mutation -eq 'background') {
    ++$readOrdinal
    Add-MavlinkBytes $parser (New-SyntheticParamValue -Id 'BARO1_GND_PRESS' `
        -ValueBits ([uint32]0x47C65F75) -Sequence 4 -ParamCount 922 `
        -ParamType 9) ($responseTime-100000) $readOrdinal
  }
  ++$readOrdinal;Add-MavlinkBytes $parser $response $responseTime $readOrdinal
  if($Mutation -eq 'background') {
    ++$readOrdinal
    Add-MavlinkBytes $parser (New-SyntheticParamValue -Id 'BARO2_GND_PRESS' `
        -ValueBits ([uint32]0x47C66A17) -Sequence 5 -ParamCount 922 `
        -ParamType 9) ($responseTime+100000) $readOrdinal
  }
  if($Mutation -eq 'duplicate'){
    ++$readOrdinal
    Add-MavlinkBytes $parser (New-SyntheticParamValue -Sequence 5) `
        ($responseTime+100000) $readOrdinal
  }
  if($Mutation -eq 'param_error'){
    ++$readOrdinal
    Add-MavlinkBytes $parser (New-SyntheticParamError 5) `
        ($responseTime+100000) $readOrdinal
  }
  if($Mutation -ne 'missing_post'){
    foreach($heartbeat in @(
        @{sequence=6;delta=500000},@{sequence=7;delta=2500000},
        @{sequence=8;delta=4500000},@{sequence=9;delta=6500000},
        @{sequence=10;delta=8500000},@{sequence=11;delta=10000000})) {
      ++$readOrdinal
      Add-MavlinkBytes $parser (New-SyntheticHeartbeat ([byte]$heartbeat.sequence)) `
          ($responseTime+[int64]$heartbeat.delta) $readOrdinal
    }
  }
  if($Mutation -eq 'noise'){
    ++$readOrdinal;Add-MavlinkBytes $parser ([byte[]]@(0x41)) `
        ($responseTime+10050000) $readOrdinal
  }
  if($Mutation -eq 'partial'){
    ++$readOrdinal;Add-MavlinkBytes $parser ([byte[]]@(0xFD,0x19)) `
        ($responseTime+10050000) $readOrdinal
  }
  [int64]$syntheticPumpGap=if($Mutation -eq 'pump_gap'){100001}else{5000}
  $pump=[pscustomobject][ordered]@{
    result=if($syntheticPumpGap-le$PumpServiceLimitUs){'PASS'}else{'FAIL'}
    maximum_gap_us=$syntheticPumpGap;limit_us=$PumpServiceLimitUs
    pump_count=2;ledger_count=1
    phase_summary=@([pscustomobject][ordered]@{
      phase='response_tail';gap_count=1;maximum_gap_us=$syntheticPumpGap
      violation_count=if($syntheticPumpGap-le$PumpServiceLimitUs){0}else{1}
    })
    gap_ledger=@([pscustomobject][ordered]@{
      ordinal=1;previous_pump_us=0;pump_started_us=$syntheticPumpGap
      gap_us=$syntheticPumpGap;from_phase='request_drain'
      to_phase='response_tail';within_limit=$syntheticPumpGap-le$PumpServiceLimitUs
      result=if($syntheticPumpGap-le$PumpServiceLimitUs){'PASS'}else{'FAIL'}
    });ledger_artifact='pump_gap_ledger.jsonl'
  }
  [int64]$captureEnd=$responseTime+10100000
  $account=Get-SingleParamAcceptance $parser $boundary `
      @($boundary.pre_heartbeat_pair) $captureEnd $pump
  return [pscustomobject]@{parser=$parser;boundary=$boundary;pre=$pre;accounting=$account}
}

function Get-HistoricalSealedEvidenceState {
  $rawPath=Join-Path $historicalLiveRoot 'ground.raw.bin'
  $timelinePath=Join-Path $historicalLiveRoot 'timeline.jsonl'
  $summaryPath=Join-Path $historicalLiveRoot 'summary.json'
  $manifestPath=Join-Path $historicalLiveRoot 'artifact_manifest.json'
  $sumsPath=Join-Path $historicalLiveRoot 'SHA256SUMS.txt'
  $sealPath=Join-Path $historicalLiveRoot 'final_seal.json'
  foreach($path in @($rawPath,$timelinePath,$summaryPath,$manifestPath,$sumsPath,
      $sealPath)) {
    Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) `
        "Historical sealed evidence is missing: $path"
  }
  $hashes=[pscustomobject][ordered]@{
    raw=Get-Sha $rawPath;timeline=Get-Sha $timelinePath
    summary=Get-Sha $summaryPath;manifest=Get-Sha $manifestPath
    sums=Get-Sha $sumsPath;seal=Get-Sha $sealPath
  }
  Assert-Condition ([string]$hashes.raw-ceq$historicalLiveRawSha256 -and
      [string]$hashes.timeline-ceq$historicalLiveTimelineSha256 -and
      [string]$hashes.summary-ceq$historicalLiveSummarySha256 -and
      [string]$hashes.seal-ceq$historicalLiveSealSha256) `
      'Historical sealed evidence does not match pinned source hashes.'
  $summary=Get-Content -LiteralPath $summaryPath -Raw|ConvertFrom-Json
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  $seal=Get-Content -LiteralPath $sealPath -Raw|ConvertFrom-Json
  Assert-Condition ([string]$summary.result-ceq'FAIL' -and
      [string]$seal.result-ceq'FAIL' -and
      [string]$seal.summary_sha256-ceq[string]$hashes.summary -and
      [string]$seal.artifact_manifest_sha256-ceq[string]$hashes.manifest -and
      [string]$seal.sha256sums_sha256-ceq[string]$hashes.sums -and
      [string]$seal.runner_start_sha256-ceq[string]$seal.runner_end_sha256 -and
      [bool]$seal.authorization_consumed -and
      [string]$seal.authorization_id-ceq[string]$summary.authorization.authorization_id -and
      [string]$seal.authorization_claim_sha256-ceq
          [string]$summary.authorization.authorization_claim_sha256) `
      'Historical summary/seal/runner/authorization binding is invalid.'
  $excluded=@('artifact_manifest.json','SHA256SUMS.txt','final_seal.json')
  $diskManifestItems=@(Get-ChildItem -LiteralPath $historicalLiveRoot -Recurse -File|
      Where-Object{$excluded-notcontains$_.Name}|Sort-Object FullName)
  $diskManifestPaths=@($diskManifestItems|ForEach-Object{
    $_.FullName.Substring($historicalLiveRoot.Length+1).Replace('\','/')
  })
  $manifestPaths=@($manifest.artifacts|ForEach-Object{[string]$_.path})
  Assert-Condition ([int]$manifest.artifact_count-eq$diskManifestItems.Count -and
      $manifestPaths.Count-eq$diskManifestPaths.Count -and
      (@(Compare-Object $manifestPaths $diskManifestPaths).Count-eq0)) `
      'Historical manifest does not exactly match its disk artifact set.'
  foreach($artifact in @($manifest.artifacts)) {
    $artifactPath=Join-Path $historicalLiveRoot ([string]$artifact.path).Replace('/','\')
    $item=Get-Item -LiteralPath $artifactPath
    Assert-Condition ([int64]$item.Length-eq[int64]$artifact.bytes -and
        (Get-Sha $artifactPath)-ceq[string]$artifact.sha256) `
        "Historical manifest artifact mismatch: $([string]$artifact.path)"
  }
  $pathSetSha=Get-ByteSha $utf8.GetBytes(($diskManifestPaths-join"`n"))
  Assert-Condition ($pathSetSha-ceq[string]$manifest.artifact_path_set_sha256 -and
      $pathSetSha-ceq[string]$seal.artifact_path_set_sha256) `
      'Historical manifest path-set hash mismatch.'
  $sumEntries=[Collections.ArrayList]::new()
  foreach($line in @(Get-Content -LiteralPath $sumsPath)) {
    if([string]::IsNullOrWhiteSpace($line)){continue}
    Assert-Condition ($line-match '^([0-9A-F]{64}) \*(.+)$') `
        'Historical SHA256SUMS contains an invalid line.'
    [void]$sumEntries.Add([pscustomobject]@{sha=$Matches[1];path=$Matches[2]})
  }
  Assert-Condition (@($sumEntries|Group-Object path|Where-Object{
        [int]$_.Count-gt1
      }).Count-eq0) `
      'Historical SHA256SUMS contains duplicate paths.'
  $diskSumItems=@(Get-ChildItem -LiteralPath $historicalLiveRoot -Recurse -File|
      Where-Object{$_.Name-notin@('SHA256SUMS.txt','final_seal.json')}|
      Sort-Object FullName)
  $diskSumPaths=@($diskSumItems|ForEach-Object{
    $_.FullName.Substring($historicalLiveRoot.Length+1).Replace('\','/')
  })
  Assert-Condition ($sumEntries.Count-eq$diskSumItems.Count -and
      @(Compare-Object @($sumEntries.path) $diskSumPaths).Count-eq0) `
      'Historical SHA256SUMS does not exactly match its disk artifact set.'
  foreach($entry in @($sumEntries)) {
    $sumFile=Join-Path $historicalLiveRoot ([string]$entry.path).Replace('/','\')
    Assert-Condition ((Get-Sha $sumFile)-ceq[string]$entry.sha) `
        "Historical SHA256SUMS mismatch: $([string]$entry.path)"
  }
  return [pscustomobject][ordered]@{
    result='PASS';hashes=$hashes;summary=$summary;seal=$seal
    manifest_artifact_count=$diskManifestItems.Count
    sums_artifact_count=$diskSumItems.Count;path_set_sha256=$pathSetSha
    exact_disk_sets_verified=$true;runner_stable=$true
    authorization_binding_verified=$true
  }
}

function Invoke-HistoricalLiveRawReplay {
  $before=Get-HistoricalSealedEvidenceState
  $rawPath=Join-Path $historicalLiveRoot 'ground.raw.bin'
  $timelinePath=Join-Path $historicalLiveRoot 'timeline.jsonl'
  [byte[]]$raw=[IO.File]::ReadAllBytes($rawPath)
  $timeline=@(Get-Content -LiteralPath $timelinePath|Where-Object{
    -not[string]::IsNullOrWhiteSpace($_)
  }|ForEach-Object{$_|ConvertFrom-Json})
  $parser=New-MavlinkParser 'historical_sealed_raw_replay' $true
  [int64]$readOrdinal=0
  foreach($event in @($timeline|Where-Object{[string]$_.kind-ceq'SERIAL_READ'})) {
    [int64]$offset=[int64]$event.raw_offset;[int]$length=[int]$event.bytes
    Assert-Condition ($offset-ge0 -and $length-gt0 -and
        $offset+$length-le$raw.Length) `
        'Historical timeline references bytes outside ground.raw.bin.'
    [byte[]]$chunk=New-Object byte[] $length
    [array]::Copy($raw,$offset,$chunk,0,$length);++$readOrdinal
    Add-MavlinkBytes $parser $chunk ([int64]$event.read_complete_us) $readOrdinal
  }
  Assert-Condition ([int64]$parser.total_bytes-eq$raw.Length) `
      'Historical replay did not consume the exact raw byte count.'
  $summary=$before.summary;$historicalBoundary=$summary.measurement.measurement_boundary
  $pre=@(Get-PrimaryHeartbeats $parser|Where-Object{
    [int64]$_.frame_start_raw_offset-lt[int64]$historicalBoundary.raw_offset
  }|Sort-Object complete_us,complete_read_ordinal|Select-Object -Last 2)
  $boundary=[pscustomobject][ordered]@{
    request_write_started_us=[int64]$historicalBoundary.request_write_started_us
    request_complete_write_edge_us=[int64]$historicalBoundary.request_complete_write_edge_us
    request_outcome=[string]$historicalBoundary.request_outcome
    raw_offset=[int64]$historicalBoundary.raw_offset
    frame_index=[int]$historicalBoundary.parser_baseline.frame_count
    parser_baseline=$historicalBoundary.parser_baseline
    pre_heartbeat_pair=$pre
  }
  $historicalPump=[pscustomobject][ordered]@{
    result='FAIL';maximum_gap_us=[int64]228528;limit_us=$PumpServiceLimitUs
    pump_count=0;ledger_count=0;phase_summary=@();gap_ledger=@()
    ledger_artifact='NOT_AVAILABLE_IN_HISTORICAL_CAPTURE'
    source='sealed historical summary maximum only'
  }
  $accounting=Get-SingleParamAcceptance $parser $boundary $pre `
      ([int64]$summary.measurement.capture_end_us) $historicalPump
  $sameInitialRead=$pre.Count-eq2 -and
      [int64]$pre[0].complete_read_ordinal-eq
          [int64]$parser.initial_backlog_read_ordinal -and
      [int64]$pre[1].complete_read_ordinal-eq
          [int64]$parser.initial_backlog_read_ordinal
  $productPathPass=[string]$accounting.response_result-ceq'PASS' -and
      [int]$accounting.target_parameter_frames-eq1 -and
      [int]$accounting.background_parameter_frames-eq2 -and
      [int]$accounting.target_semantic_mismatch_count-eq0 -and
      [int]$accounting.duplicate_target_response_count-eq0 -and
      [int]$accounting.param_error_frames-eq0 -and
      [int64]$accounting.parser_error_count-eq0 -and
      [int64]$accounting.heartbeat.maximum_consecutive_post_gap_us-le
          $HeartbeatLimitUs -and
      [int64]$accounting.heartbeat.response_to_next_heartbeat_us-le
          $HeartbeatLimitUs
  $after=Get-HistoricalSealedEvidenceState
  $sourceImmutable=(ConvertTo-Json $before.hashes -Compress)-ceq
      (ConvertTo-Json $after.hashes -Compress)
  $result=[pscustomobject][ordered]@{
    schema='vc-lora-r18-sealed-live-raw-replay-v1'
    source_root=$historicalLiveRoot;source_immutable=$sourceImmutable
    source_integrity_result=if($sourceImmutable){'PASS'}else{'FAIL'}
    source_hashes=$after.hashes
    sealed_manifest_artifact_count=[int]$after.manifest_artifact_count
    sealed_sums_artifact_count=[int]$after.sums_artifact_count
    sealed_path_set_sha256=[string]$after.path_set_sha256
    product_path_result=if($productPathPass){'PASS'}else{'FAIL'}
    historical_harness_result=[string]$summary.result
    historical_harness_wrong_or_unexpected_response_count=
        [int]$summary.measurement.accounting.wrong_or_unexpected_response_count
    historical_harness_maximum_pump_service_gap_us=
        [int64]$summary.measurement.accounting.maximum_pump_service_gap_us
    preflight_freshness_result=if($sameInitialRead){
      'FAIL_SAME_INITIAL_READ_BATCH'
    }else{'UNEXPECTED'}
    live_acceptance='NOT_GRANTED'
    replay_formal_acceptance_result=[string]$accounting.result
    target_response_latency_us=[int64]$accounting.response_latency_us
    target_response_raw_sha256=[string]$accounting.selected_response.raw_sha256
    background_parameter_ledger=@($accounting.background_parameter_ledger)
    post_request_heartbeat_maximum_gap_us=
        [int64]$accounting.heartbeat.maximum_consecutive_post_gap_us
    parser_error_count=[int64]$accounting.parser_error_count
    param_error_frames=[int]$accounting.param_error_frames
    target_semantic_mismatch_count=[int]$accounting.target_semantic_mismatch_count
    duplicate_target_response_count=[int]$accounting.duplicate_target_response_count
    initial_backlog_read_ordinal=[int64]$parser.initial_backlog_read_ordinal
    preflight_read_ordinals=@($pre|ForEach-Object{
      [int64]$_.complete_read_ordinal
    })
    replay_accounting=$accounting
  }
  Assert-Condition ($sourceImmutable -and $productPathPass -and $sameInitialRead -and
      [string]$summary.result-ceq'FAIL' -and [string]$accounting.result-ceq'FAIL') `
      'Historical replay split result did not match the pinned evidence.'
  Write-DurableJson (Join-Path $evidence 'historical_live_replay.json') $result
  return $result
}

function Invoke-OfflineSelfTest {
  $tests=[Collections.ArrayList]::new()
  function Add-Test([string]$Name,[bool]$Pass,[string]$Detail) {
    [void]$tests.Add([pscustomobject][ordered]@{name=$Name;result=if($Pass){'PASS'}else{'FAIL'};detail=$Detail})
  }
  [byte[]]$request=New-ExactParamRequestRead
  Add-Test 'frozen_fixture_positive' ($request.Length -eq 32 -and
      (Get-ByteSha $request) -ceq $exactRequestSha256) 'exact frozen #20'
  $positive=New-SyntheticScenario
  Write-SelectedResponseArtifact $positive.accounting
  Add-Test 'positive_exact_roundtrip' ([string]$positive.accounting.result -ceq 'PASS' -and
      [bool]$positive.accounting.duplicate_observation_completed -and
      @($positive.accounting.heartbeat.gap_ledger).Count -ge 2 -and
      $null-ne$positive.accounting.selected_response -and
      [string]$positive.accounting.selected_response.raw_sha256 -match '^[0-9A-F]{64}$') `
      'exact #22, >=10 s duplicate tail, selected raw proof, and full heartbeat ledger'
  $backgroundPositive=New-SyntheticScenario 'background'
  Add-Test 'valid_background_param_values_positive' (
      [string]$backgroundPositive.accounting.result-ceq'PASS' -and
      [int]$backgroundPositive.accounting.target_parameter_frames-eq1 -and
      [int]$backgroundPositive.accounting.background_parameter_frames-eq2 -and
      [int]$backgroundPositive.accounting.valid_background_parameter_frames-eq2 -and
      @($backgroundPositive.accounting.background_parameter_ledger).Count-eq2 -and
      @($backgroundPositive.accounting.background_parameter_ledger)[0].param_id-ceq
          'BARO1_GND_PRESS' -and
      @($backgroundPositive.accounting.background_parameter_ledger)[1].param_id-ceq
          'BARO2_GND_PRESS') `
      'valid different-ID #22 frames are preserved as background and allowed'
  Add-Test 'missing_preflight_heartbeat_negative' ((New-SyntheticScenario 'missing_preflight').accounting.result -ceq 'FAIL') 'two pre-HBs required'
  $gapNegative=New-SyntheticScenario 'heartbeat_gap'
  Add-Test 'heartbeat_gap_negative' ($gapNegative.accounting.result -ceq 'FAIL' -and
      [int64]$gapNegative.accounting.heartbeat.preflight_pair_gap_us -gt $HeartbeatLimitUs -and
      [int64]$gapNegative.accounting.heartbeat.pre_to_request_age_us -ge 0 -and
      [int64]$gapNegative.accounting.heartbeat.pre_to_request_age_us -le $HeartbeatLimitUs) `
      'failure is specifically caused by a >2.5 s preflight pair gap, not negative age'
  Add-Test 'wrong_source_negative' ((New-SyntheticScenario 'wrong_source').accounting.result -ceq 'FAIL') 'source 1/1 required'
  Add-Test 'wrong_param_id_negative' ((New-SyntheticScenario 'wrong_id').accounting.result -ceq 'FAIL') 'exact ID required'
  Add-Test 'wrong_value_negative' ((New-SyntheticScenario 'wrong_value').accounting.result -ceq 'FAIL') '57.0 required'
  $semanticMismatch=New-SyntheticScenario 'wrong_value'
  Add-Test 'target_semantic_mismatch_negative' (
      [string]$semanticMismatch.accounting.result-ceq'FAIL' -and
      [int]$semanticMismatch.accounting.target_semantic_mismatch_count-eq1 -and
      [int]$semanticMismatch.accounting.background_parameter_frames-eq0) `
      'target ID with wrong semantics remains a target failure'
  Add-Test 'wrong_param_count_negative' ((New-SyntheticScenario 'wrong_count').accounting.result -ceq 'FAIL') 'count 932 required'
  Add-Test 'wrong_param_index_negative' ((New-SyntheticScenario 'wrong_index').accounting.result -ceq 'FAIL') 'index 65535 required'
  Add-Test 'wrong_param_type_negative' ((New-SyntheticScenario 'wrong_type').accounting.result -ceq 'FAIL') 'type 6 required'
  Add-Test 'signed_response_negative' ((New-SyntheticScenario 'signed').accounting.result -ceq 'FAIL') 'signed MAVLink2 rejected'
  Add-Test 'mavlink1_response_negative' ((New-SyntheticScenario 'v1').accounting.result -ceq 'FAIL') 'MAVLink1 rejected'
  Add-Test 'wrong_payload_length_negative' ((New-SyntheticScenario 'length').accounting.result -ceq 'FAIL') 'exact #22 payload length required'
  Add-Test 'noncausal_response_negative' ((New-SyntheticScenario 'noncausal').accounting.result -ceq 'FAIL') `
      'response start and completion must follow request complete-write edge'
  Add-Test 'duplicate_response_negative' ((New-SyntheticScenario 'duplicate').accounting.result -ceq 'FAIL') 'exactly one response'
  Add-Test 'param_error_negative' ((New-SyntheticScenario 'param_error').accounting.result -ceq 'FAIL') '#345 rejected'
  Add-Test 'missing_post_response_heartbeat_negative' ((New-SyntheticScenario 'missing_post').accounting.result -ceq 'FAIL') 'post-response HB required'
  Add-Test 'crc_negative' ((New-SyntheticScenario 'crc').accounting.result -ceq 'FAIL') 'CRC error rejected'
  Add-Test 'noise_negative' ((New-SyntheticScenario 'noise').accounting.result -ceq 'FAIL') 'noise/control leakage rejected'
  Add-Test 'partial_negative' ((New-SyntheticScenario 'partial').accounting.result -ceq 'FAIL') 'partial tail rejected'
  Add-Test 'pump_gap_negative' ((New-SyntheticScenario 'pump_gap').accounting.result -ceq 'FAIL') '>100ms rejected'
  $sameReadParser=New-MavlinkParser 'same_read_freshness' $true
  [byte[]]$initialBatch=(New-SyntheticHeartbeat 20)+(New-SyntheticHeartbeat 21)
  Add-MavlinkBytes $sameReadParser $initialBatch 1000000 1
  $initialFresh=@(Get-FreshPrimaryHeartbeats $sameReadParser)
  Add-MavlinkBytes $sameReadParser (New-SyntheticHeartbeat 22) 2000000 2
  Add-MavlinkBytes $sameReadParser (New-SyntheticHeartbeat 23) 3000000 2
  $sameReadFresh=@(Get-FreshPrimaryHeartbeats $sameReadParser)
  Add-MavlinkBytes $sameReadParser (New-SyntheticHeartbeat 24) 4000000 3
  $distinctReadFresh=@(Get-FreshPrimaryHeartbeats $sameReadParser)
  Add-Test 'same_read_batch_preflight_heartbeats_not_fresh_negative' (
      $initialFresh.Count-eq0 -and $sameReadFresh.Count-eq1 -and
      $distinctReadFresh.Count-eq2 -and
      [int64]$distinctReadFresh[1].complete_us-
          [int64]$distinctReadFresh[0].complete_us-gt0) `
      'initial backlog and duplicate heartbeat observations in one read batch do not satisfy freshness'
  $zeroGapParser=New-MavlinkParser 'zero_gap_freshness' $true
  Add-MavlinkBytes $zeroGapParser (New-SyntheticHeartbeat 30) 1000000 1
  Add-MavlinkBytes $zeroGapParser (New-SyntheticHeartbeat 31) 2000000 2
  Add-MavlinkBytes $zeroGapParser (New-SyntheticHeartbeat 32) 2000000 3
  $zeroGapFresh=@(Get-FreshPrimaryHeartbeats $zeroGapParser)
  Add-Test 'distinct_read_zero_timestamp_gap_negative' (
      $zeroGapFresh.Count-eq2 -and
      [int64]$zeroGapFresh[1].complete_us-
          [int64]$zeroGapFresh[0].complete_us-eq0) `
      'distinct reads still require a positive heartbeat timestamp gap'
  $phasePump=New-PumpTimingState
  Set-PumpPhase $phasePump 'preflight';Register-PumpService $phasePump 1000
  Set-PumpPhase $phasePump 'boundary';Register-PumpService $phasePump 2000
  Set-PumpPhase $phasePump 'request_drain';Register-PumpService $phasePump 3000
  Set-PumpPhase $phasePump 'response_tail';Register-PumpService $phasePump 4000
  Set-PumpPhase $phasePump 'final_drain';Register-PumpService $phasePump 5000
  $phaseEvidence=Get-PumpTimingEvidence $phasePump
  Add-Test 'phase_aware_pump_gap_ledger_positive' (
      [string]$phaseEvidence.result-ceq'PASS' -and
      [int]$phaseEvidence.ledger_count-eq4 -and
      @($phaseEvidence.phase_summary).Count-eq4 -and
      @($phaseEvidence.gap_ledger|Where-Object{
        [string]::IsNullOrWhiteSpace([string]$_.from_phase) -or
        [string]::IsNullOrWhiteSpace([string]$_.to_phase) -or
        [string]$_.result-cne'PASS'
      }).Count-eq0) `
      'each measured pump gap retains its phase transition and unchanged 100 ms result'
  $bannerParser=New-MavlinkParser 'banner' $false
  Add-MavlinkBytes $bannerParser $exactBootBannerBytes 100
  Add-MavlinkBytes $bannerParser (New-SyntheticHeartbeat 99) 200
  Add-Test 'exact_boot_banner_classification_positive' (
      $bannerParser.classified_startup_bytes -eq 266 -and
      $bannerParser.classified_startup_sha256 -ceq $exactBootBannerSha256 -and
      $bannerParser.noise_bytes -eq 0 -and $bannerParser.frames.Count -eq 1) `
      'only exact complete initial ROM banner is classified'
  [byte[]]$nearBanner=New-Object byte[] $exactBootBannerBytes.Length
  [array]::Copy($exactBootBannerBytes,$nearBanner,$exactBootBannerBytes.Length)
  $nearBanner[20]=$nearBanner[20]-bxor 1
  $nearBannerParser=New-MavlinkParser 'near_banner' $false
  Add-MavlinkBytes $nearBannerParser $nearBanner 100
  Add-MavlinkBytes $nearBannerParser (New-SyntheticHeartbeat 100) 200
  Add-Test 'near_boot_banner_negative' (
      $nearBannerParser.classified_startup_bytes -eq 0 -and
      $nearBannerParser.noise_bytes -gt 0) `
      'a one-byte near banner remains unclassified noise'
  Reset-OfflineState;$fake=New-FakeSerial;[int64]$tick=100
  $now={$script:OfflineTick+=100;return [int64]$script:OfflineTick}
  $script:OfflineTick=0;$wait={}
  [void](Invoke-ExactRequestWrite $fake $request $now $wait -Simulation)
  $rejected=$false
  try{[void](Invoke-ExactRequestWrite $fake $request $now $wait -Simulation)}catch{$rejected=$true}
  Add-Test 'write_retry_negative' ($rejected -and $fake.state.writes -eq 1) 'one-shot guard'
  Reset-OfflineState;$drainFake=New-FakeSerial -NeverDrains;$script:OfflineTick=0
  $drainRejected=$false
  try{[void](Invoke-ExactRequestWrite $drainFake $request $now $wait `
      -DrainTimeoutUs 250 -Simulation)}catch{$drainRejected=$true}
  $drainRetryRejected=$false
  try{[void](Invoke-ExactRequestWrite $drainFake $request $now $wait `
      -DrainTimeoutUs 250 -Simulation)}catch{$drainRetryRejected=$true}
  Add-Test 'write_drain_ambiguity_negative' ($drainRejected -and
      $drainRetryRejected -and $drainFake.state.writes -eq 1 -and
      [string]$script:RequestState.request_outcome -ceq 'AMBIGUOUS' -and
      [int]$script:RequestState.request_writes_completed -eq 0) `
      'ambiguous drain is fail-closed and may not be retried'

  $cleanupNegative=Invoke-FailClosedCleanupPlan @(
      [pscustomobject]@{name='synthetic_cleanup_failure';action={throw 'synthetic cleanup fault'}})
  Add-Test 'cleanup_failure_negative' ([string]$cleanupNegative.result -ceq 'FAIL' -and
      [int]$cleanupNegative.error_count -eq 1) 'cleanup failure remains an acceptance failure'

  $historicalReplayResult=Invoke-HistoricalLiveRawReplay
  Add-Test 'historical_live_raw_replay_product_path_positive' (
      [string]$historicalReplayResult.product_path_result-ceq'PASS' -and
      [bool]$historicalReplayResult.source_immutable -and
      [int64]$historicalReplayResult.target_response_latency_us-eq7305428 -and
      @($historicalReplayResult.background_parameter_ledger).Count-eq2 -and
      [int64]$historicalReplayResult.parser_error_count-eq0) `
      'sealed raw proves the target product roundtrip, background ledger, heartbeat and clean parser'
  Add-Test 'historical_live_raw_replay_harness_failure_preserved' (
      [string]$historicalReplayResult.historical_harness_result-ceq'FAIL' -and
      [string]$historicalReplayResult.preflight_freshness_result-ceq
          'FAIL_SAME_INITIAL_READ_BATCH' -and
      [string]$historicalReplayResult.replay_formal_acceptance_result-ceq'FAIL' -and
      [string]$historicalReplayResult.live_acceptance-ceq'NOT_GRANTED' -and
      [int64]$historicalReplayResult.historical_harness_maximum_pump_service_gap_us-eq228528) `
      'historical official FAIL and same-initial-read/pump harness defects are not upgraded'

  $processSnapshot=@(
    [pscustomobject]@{ProcessId=100;ParentProcessId=200;Name='powershell.exe';CommandLine='child'},
    [pscustomobject]@{ProcessId=200;ParentProcessId=300;Name='powershell.exe';CommandLine='powershell -File run_r18_single_param_liveness_hil.ps1 -Execute -AuthorizationId redacted COM6'},
    [pscustomobject]@{ProcessId=300;ParentProcessId=200;Name='codex.exe';CommandLine='codex host'})
  $trustedGate=Get-CompetingClientGateFromSnapshot $processSnapshot 100
  Add-Test 'process_gate_trusted_ancestor_cycle_positive' (
      [string]$trustedGate.result -ceq 'PASS' -and
      @($trustedGate.trusted_ancestors).Count -eq 2 -and
      @($trustedGate.blocked_processes).Count -eq 0) `
      'only classified invocation ancestors are trusted and ancestry is cycle-safe'
  $blockedSnapshot=@($processSnapshot+[pscustomobject]@{
      ProcessId=400;ParentProcessId=1;Name='ttermpro.exe';CommandLine='ttermpro /C=6 COM6 secret'})
  $blockedGate=Get-CompetingClientGateFromSnapshot $blockedSnapshot 100
  $blockedRecord=@($blockedGate.blocked_processes)[0]
  Add-Test 'process_gate_competitor_sanitized_negative' (
      [string]$blockedGate.result -ceq 'FAIL' -and
      @($blockedGate.blocked_processes).Count -eq 1 -and
      $blockedRecord.PSObject.Properties.Name -contains 'command_line_sha256' -and
      $blockedRecord.PSObject.Properties.Name -notcontains 'command_line') `
      'expanded competing clients are rejected without retaining raw command lines'

  $claimProbe=Join-Path $evidence 'offline_claim_probe'
  $claimId='11111111-1111-1111-1111-111111111111'
  $firstClaim=Claim-OneRunAuthorization $claimId $claimProbe $evidence -Simulation
  $replayRejected=$false
  try{[void](Claim-OneRunAuthorization $claimId $claimProbe $evidence -Simulation)}
  catch{$replayRejected=$_.Exception.Message -match 'replay rejected'}
  Add-Test 'authorization_atomic_claim_and_replay_negative' (
      [string]$firstClaim.result -ceq 'CLAIMED' -and $replayRejected -and
      [bool]$firstClaim.record.authorization_consumed -and
      -not[bool]$firstClaim.record.authorization_reusable) `
      'atomic CreateNew claim is consumed before live use and rejects replay'
  Add-Test 'offline_external_actions_zero' (-not $script:ExternalActions.cim_queried -and
      -not $script:ExternalActions.pnp_queried -and
      -not $script:ExternalActions.process_inventory_queried -and
      -not $script:ExternalActions.com_ports_opened -and
      -not $script:ExternalActions.serial_write_attempted -and
      -not $script:ExternalActions.firmware_write_attempted -and
      -not $script:ExternalActions.e220_write_attempted -and
      -not $script:ExternalActions.actuator_command_attempted) 'offline mode touches no device'
  $failed=@($tests|Where-Object{$_.result -cne 'PASS'})
  return [pscustomobject][ordered]@{
    schema='vc-lora-r18-single-param-liveness-offline-v2'
    test_id=$script:TestId;mode='OFFLINE_SELF_TEST'
    result=if($failed.Count-eq 0){'PASS'}else{'FAIL'}
    failure=''
    test_count=$tests.Count;failed_count=$failed.Count;tests=@($tests)
    started_utc=$script:StartedUtc;finished_utc=''
    authorization=[pscustomobject][ordered]@{
      required_live_token_sha256=$authorizationSha256
      authorization_id='';authorization_claim_sha256=''
      authorization_consumed=$false
      authorization_reusable=$false;safety_attestation_verified=$false
      cold_boot_attestation_verified=$false
    }
    historical_live_replay=$historicalReplayResult
    external_actions=$script:ExternalActions;cleanup=$null;runner_integrity=$null
  }
}

function Complete-Evidence([object]$Summary) {
  Assert-Condition (-not $script:SummaryWritten) 'Evidence completion may only run once.'
  $script:SummaryWritten=$true
  $script:RunnerEndSha256=Get-Sha $PSCommandPath
  $stable=-not [string]::IsNullOrWhiteSpace($script:RunnerStartSha256) -and
      $script:RunnerStartSha256 -ceq $script:RunnerEndSha256
  if(-not $stable){$Summary.result='FAIL';$Summary.failure=([string]$Summary.failure+' | runner source changed').Trim(' ','|')}
  $integrity=[pscustomobject][ordered]@{
    result=if($stable){'PASS'}else{'FAIL'}
    runner_start_sha256=$script:RunnerStartSha256
    runner_end_sha256=$script:RunnerEndSha256
  }
  if($Summary.PSObject.Properties['runner_integrity']){$Summary.runner_integrity=$integrity}
  else{$Summary|Add-Member NoteProperty runner_integrity $integrity}
  if([string]$Summary.mode -ceq $script:LiveMode -and [string]$Summary.result -ceq 'PASS' -and
      ($null-eq$script:CleanupResult -or [string]$script:CleanupResult.result -cne 'PASS')){
    $Summary.result='FAIL';$Summary.failure='live cleanup proof missing or failed'
  }
  $Summary.finished_utc=[DateTime]::UtcNow.ToString('o')
  $summaryPath=Join-Path $evidence 'summary.json';Write-DurableJson $summaryPath $Summary
  $excluded=@('artifact_manifest.json','SHA256SUMS.txt','final_seal.json')
  $artifacts=@(Get-ChildItem -LiteralPath $evidence -Recurse -File|
      Where-Object{$excluded -notcontains $_.Name}|Sort-Object FullName|ForEach-Object{
        [pscustomobject][ordered]@{
          path=$_.FullName.Substring($evidence.Length+1).Replace('\','/')
          bytes=[int64]$_.Length;sha256=Get-Sha $_.FullName
        }
      })
  $paths=($artifacts|ForEach-Object{$_.path}) -join "`n"
  $pathSetSha=Get-ByteSha $utf8.GetBytes($paths)
  $manifest=[pscustomobject][ordered]@{
    schema='vc-lora-evidence-manifest-v1';test_id=$script:TestId
    artifact_count=$artifacts.Count;artifact_path_set_sha256=$pathSetSha
    artifacts=$artifacts
  }
  $manifestPath=Join-Path $evidence 'artifact_manifest.json';Write-DurableJson $manifestPath $manifest
  $items=@(Get-ChildItem -LiteralPath $evidence -Recurse -File|
      Where-Object{$_.Name -notin @('SHA256SUMS.txt','final_seal.json')}|Sort-Object FullName)
  $lines=foreach($item in $items){
    $relative=$item.FullName.Substring($evidence.Length+1).Replace('\','/')
    '{0} *{1}' -f (Get-Sha $item.FullName),$relative
  }
  $sumsPath=Join-Path $evidence 'SHA256SUMS.txt';Write-Durable $sumsPath (($lines-join$newline)+$newline)
  $seal=[pscustomobject][ordered]@{
    schema='vc-lora-r18-single-param-liveness-final-seal-v1'
    sealed_utc=[DateTime]::UtcNow.ToString('o');result=[string]$Summary.result
    summary_sha256=Get-Sha $summaryPath
    artifact_manifest_sha256=Get-Sha $manifestPath
    sha256sums_sha256=Get-Sha $sumsPath
    artifact_path_set_sha256=$pathSetSha
    runner_start_sha256=$script:RunnerStartSha256
    runner_end_sha256=$script:RunnerEndSha256
    runner_integrity=if($stable){'PASS'}else{'FAIL'};immutable_after_seal=$true
    authorization_id=if($null-ne$script:AuthorizationClaim){
      [string]$script:AuthorizationClaim.authorization_id}else{''}
    authorization_claim_sha256=if($null-ne$script:AuthorizationClaim){
      [string]$script:AuthorizationClaim.claim_sha256}else{''}
    authorization_consumed=($null-ne$script:AuthorizationClaim)
    authorization_reusable=$false
  }
  Write-DurableJson (Join-Path $evidence 'final_seal.json') $seal
}

$finalSummary=$null;$mainFailure=''
try {
  Assert-Condition (-not($Execute.IsPresent -and $OfflineSelfTest.IsPresent)) `
      'Execute and OfflineSelfTest are mutually exclusive.'
  Assert-Condition ($Execute.IsPresent -or $OfflineSelfTest.IsPresent) `
      'Choose -OfflineSelfTest or explicitly supply -Execute.'
  if($Execute.IsPresent){
    Assert-Condition ((Get-ByteSha $utf8.GetBytes($HilAuthorization)) -ceq
        $authorizationSha256) `
        'Exact unique one-run HIL authorization is required.'
    Assert-Condition ((Get-ByteSha $utf8.GetBytes($OperatorSafetyAttestation)) -ceq
        $safetySha256) `
        'Exact six-condition operator safety attestation is required.'
    Assert-Condition ((Get-ByteSha $utf8.GetBytes($ColdBootAttestation)) -ceq
        $coldBootSha256) `
        'Exact simultaneous >5 s power-off/cold-boot attestation is required.'
    $parsedAuthorizationId=[Guid]::Empty
    Assert-Condition ([Guid]::TryParseExact($AuthorizationId,'D',
        [ref]$parsedAuthorizationId)) `
        'A canonical unique AuthorizationId is required.'
  }else{
    Assert-Condition ([string]::IsNullOrEmpty($HilAuthorization) -and
        [string]::IsNullOrEmpty($AuthorizationId) -and
        [string]::IsNullOrEmpty($OperatorSafetyAttestation) -and
        [string]::IsNullOrEmpty($ColdBootAttestation)) `
        'OfflineSelfTest rejects live authorization/attestation values.'
  }
  if($Execute.IsPresent){
    # The one-run authority is atomically consumed before any CIM, process,
    # PnP, COM-open, or serial-write action. A duplicate GUID is fail-closed.
    $script:RunnerStartSha256=Get-Sha $PSCommandPath
    $claimDirectory=Join-Path $repo `
        "runs\hil\$($script:TestId)\authorization_claims"
    $script:AuthorizationClaim=Claim-OneRunAuthorization $AuthorizationId `
        $claimDirectory $evidence
    [byte[]]$claimBytes=[IO.File]::ReadAllBytes(
        [string]$script:AuthorizationClaim.claim_path)
    Write-DurableBytes (Join-Path $evidence 'authorization_claim.json') $claimBytes
    Write-DurableJson (Join-Path $evidence 'operator_authorization.json') `
        ([pscustomobject][ordered]@{
          schema='vc-lora-r18-single-param-one-run-authorization-v1'
          claimed_utc=[DateTime]::UtcNow.ToString('o')
          authorization_id=[string]$script:AuthorizationClaim.authorization_id
          authorization_claim_sha256=[string]$script:AuthorizationClaim.claim_sha256
          authorization_token_sha256=(Get-ByteSha $utf8.GetBytes($HilAuthorization))
          authorization_supplied=$true
          authorization_consumed=$true;authorization_reusable=$false
          operator_safety_attestation_sha256=(Get-ByteSha `
              $utf8.GetBytes($OperatorSafetyAttestation))
          operator_safety_attestation_verified=$true
          cold_boot_attestation_sha256=(Get-ByteSha `
              $utf8.GetBytes($ColdBootAttestation))
          cold_boot_attestation_verified=$true
          cold_boot_physical_state_verified_by_runner=$false
          cold_boot_contract='both XIAOs plus Pixhawk/external power simultaneously OFF >5 s before cold boot'
          retry_allowed=$false
        })
  }
  Assert-PinnedInputs
  if($OfflineSelfTest.IsPresent){$finalSummary=Invoke-OfflineSelfTest}
  else{
    $measurement=Invoke-LiveMeasurement
    $finalSummary=[pscustomobject][ordered]@{
      schema='vc-lora-r18-production-single-param-liveness-v1'
      test_id=$script:TestId;mode=$script:LiveMode
      result=[string]$measurement.result;failure=''
      started_utc=$script:StartedUtc;finished_utc='';measurement=$measurement
      request=$script:RequestState;external_actions=$script:ExternalActions
      cleanup=$script:CleanupResult
      authorization=[pscustomobject][ordered]@{
        authorization_id=[string]$script:AuthorizationClaim.authorization_id
        authorization_claim_sha256=[string]$script:AuthorizationClaim.claim_sha256
        token_sha256=(Get-ByteSha $utf8.GetBytes($HilAuthorization))
        supplied=((Get-ByteSha $utf8.GetBytes($HilAuthorization))-ceq
            $authorizationSha256)
        authorization_consumed=($null-ne$script:AuthorizationClaim)
        authorization_reusable=$false
        operator_safety_attestation_verified=((Get-ByteSha `
            $utf8.GetBytes($OperatorSafetyAttestation))-ceq$safetySha256)
        cold_boot_attestation_verified=((Get-ByteSha `
            $utf8.GetBytes($ColdBootAttestation))-ceq$coldBootSha256)
        cold_boot_contract='both XIAOs plus Pixhawk/external power simultaneously OFF >5 s before cold boot'
      }
      safety=[pscustomobject][ordered]@{
        firmware_write_attempted=$false;e220_write_attempted=$false
        actuator_command_attempted=$false;power_cycle_performed_by_runner=$false
        com3_opened=$false;com3_written=$false
        only_permitted_write='one exact MAVLink2 PARAM_REQUEST_READ #20 on COM6'
        initial_boot_banner_policy='EXACT_INITIAL_266_BYTE_ESP32S3_ROM_BANNER_ONLY'
      }
      accepted_r18_provenance=[pscustomobject][ordered]@{
        result='PASS_PINNED_PRIOR_REPROOF';current_flash_readback_performed=$false
        prior_proof_sha256=$acceptedProofSha256
        ground_application_sha256=$groundR18Sha256
        vehicle_application_sha256=$vehicleR18Sha256;pins=@($script:PinRecords)
      }
      runner_integrity=$null
    }
  }
}catch{
  $mainFailure=$_.Exception.Message
  $finalSummary=[pscustomobject][ordered]@{
    schema='vc-lora-r18-production-single-param-liveness-v1'
    test_id=$script:TestId
    mode=if($OfflineSelfTest.IsPresent){'OFFLINE_SELF_TEST'}else{$script:LiveMode}
    result='FAIL';failure=$mainFailure;started_utc=$script:StartedUtc;finished_utc=''
    measurement=$script:LastMeasurement;request=$script:RequestState
    external_actions=$script:ExternalActions;cleanup=$script:CleanupResult
    authorization=[pscustomobject][ordered]@{
      authorization_id=if($null-ne$script:AuthorizationClaim){
        [string]$script:AuthorizationClaim.authorization_id}else{$AuthorizationId}
      authorization_claim_sha256=if($null-ne$script:AuthorizationClaim){
        [string]$script:AuthorizationClaim.claim_sha256}else{''}
      token_sha256=if($Execute.IsPresent){
        Get-ByteSha $utf8.GetBytes($HilAuthorization)}else{''}
      authorization_consumed=($null-ne$script:AuthorizationClaim)
      authorization_reusable=$false
      operator_safety_attestation_verified=($Execute.IsPresent-and
          (Get-ByteSha $utf8.GetBytes($OperatorSafetyAttestation))-ceq$safetySha256)
      cold_boot_attestation_verified=($Execute.IsPresent-and
          (Get-ByteSha $utf8.GetBytes($ColdBootAttestation))-ceq$coldBootSha256)
    }
    safety=[pscustomobject][ordered]@{
      firmware_write_attempted=$false;e220_write_attempted=$false
      actuator_command_attempted=$false;com3_opened=$false;com3_written=$false
      only_permitted_write='one exact MAVLink2 PARAM_REQUEST_READ #20 on COM6'
      initial_boot_banner_policy='EXACT_INITIAL_266_BYTE_ESP32S3_ROM_BANNER_ONLY'
    }
    accepted_r18_provenance=[pscustomobject][ordered]@{
      result=if($script:PinRecords.Count-ge 5){'PASS_PINNED_PRIOR_REPROOF'}else{'INCOMPLETE'}
      prior_proof_sha256=$acceptedProofSha256;pins=@($script:PinRecords)
    }
    runner_integrity=$null
  }
}finally{Complete-Evidence $finalSummary}

if([string]$finalSummary.result -cne 'PASS'){
  Write-Error "R18 single-parameter liveness FAIL: $mainFailure; evidence=$evidence"
  exit 1
}
Write-Output "R18 single-parameter liveness PASS mode=$([string]$finalSummary.mode) evidence=$evidence"
exit 0
