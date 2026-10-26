[CmdletBinding()]
param(
  [switch]$Execute,
  [switch]$OfflineSelfTest,
  [switch]$PreflightOnly,
  [string]$RepoRoot = '',
  [string]$OutputDirectory = '',

  # Internal reuse boundary for the dedicated R19 wrapper.  Operators must
  # invoke tools/run_r19_pixhawk_param_list_e2e_hil.ps1 instead of setting
  # this switch directly; that wrapper validates and seals candidate/flash
  # provenance before this strict data-plane engine starts.
  [switch]$R19SharedMode,
  [string]$R19ProvenancePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$newline = [Environment]::NewLine

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
$script:TestId = if ($R19SharedMode.IsPresent) {
  'R19-PIXHAWK-PARAM-LIST-E2E-HIL-001'
} elseif ($PreflightOnly.IsPresent) {
  'R18-PIXHAWK-READONLY-PREFLIGHT-HIL-001'
} else {'R18-PIXHAWK-PARAM-LIST-E2E-HIL-001'}
$script:LiveMode = if ($R19SharedMode.IsPresent) {
  'LIVE_R19_PIXHAWK_E2E'
} elseif ($PreflightOnly.IsPresent) {
  'LIVE_R18_READONLY_PREFLIGHT'
} else {'LIVE_R18_PIXHAWK_E2E'}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $leaf = if ($OfflineSelfTest.IsPresent) {"OFFLINE-$stamp"} else {"LIVE-$stamp"}
  $OutputDirectory = Join-Path $repo ("runs\hil\{0}\{1}" -f `
      $script:TestId,$leaf)
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite evidence: $OutputDirectory"
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$evidence = (Resolve-Path -LiteralPath $OutputDirectory).Path

$GroundPort = 'COM6'
$GroundPnpDeviceId = 'USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000'
$GroundParentDeviceId = 'USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80'
$GroundVid = '303A'
$GroundPid = '1001'
$ForbiddenPorts = @('COM3')
$ExpectedParameters = 932
$HeartbeatLimitUs = [int64]2500000
$Target30LimitUs = [int64]30000000
$Stretch10LimitUs = [int64]10000000
$StallTimeoutUs = [int64]120000000
$OverallTimeoutUs = [int64]7200000000
$DuplicateGuardUs = [int64]30000000
$PreflightTimeoutUs = [int64]30000000
$PreflightParamQuietUs = [int64]2000000
$WriteDrainTimeoutUs = [int64]5000000
$PumpServiceLimitUs = [int64]100000
$exactRequestHex = 'FD02000063FFBE1500000101D507'
$exactRequestSha256 = `
    'FC3A47A83D35D44E96E044A216FDBF082805F9FACCDD5E4B9252E0C7026D4A75'
$definitionSha256 = `
    'BD2890D8973C5A694D53AB2866A6B3DBF319FAE40B3CC308AE2DAE91B634F3A8'
$groundR18Sha256 = `
    '30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5'
$vehicleR18Sha256 = `
    '9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52'
$restoreEvidenceSha256 = `
    'AEFF205534567E26AFD17AB5EDF5BF05E9DD735D6A4D52E51DB318B7FE23AC66'

$definitionPath = Join-Path $repo 'core\src\mavlink_frame.cpp'
$acceptedRoot = Join-Path $repo `
    'runs\baselines\R18-PRODUCTION-R4-ACCEPTED\20260914T225054625Z\artifacts'
$groundR18Path = Join-Path $acceptedRoot 'ground.application.bin'
$vehicleR18Path = Join-Path $acceptedRoot 'vehicle.application.bin'
$restoreEvidencePath = Join-Path $repo `
    'runs\high_speed\R19-HS-G0-E220-INVENTORY-HIL-001\LIVE-R3-20260915T130445974Z\summary.json'

$script:Definitions = @{}
$script:PinRecords = [Collections.ArrayList]::new()
$script:RequestState = [pscustomobject][ordered]@{
  request_attempted=0
  request_write_started_us=[int64]-1
  request_write_call_completed=0
  request_writes_completed=0
  request_complete_write_edge_us=[int64]-1
  request_outcome='NOT_ATTEMPTED'
  request_sha256=$exactRequestSha256
}
$script:ExternalActions = [pscustomobject][ordered]@{
  cim_queried=$false
  pnp_queried=$false
  process_inventory_queried=$false
  com_ports_opened=$false
  serial_write_attempted=$false
  serial_write_call_completed=$false
  serial_bytes_drained=$false
  serial_bytes_written=$false
  firmware_write_attempted=$false
  e220_write_attempted=$false
  actuator_command_attempted=$false
}
$script:StartedUtc = [DateTime]::UtcNow.ToString('o')
$script:RunnerStartSha256 = ''
$script:SummaryWritten = $false
$script:CleanupResult = $null
$script:R19Provenance = $null
$script:R19RuntimeFailDiagnostics = [Collections.ArrayList]::new()
$script:R19RuntimeFailOrdinals = [Collections.Generic.HashSet[int]]::new()
$r19RuntimeFailPattern =
    '^R19F:(?<role>[GV]):(?<line>[0-9A-F]{4}):' +
    '(?<time>[0-9A-F]{16}):(?<status>[0-9A-F]{12}):' +
    '(?<epoch>[0-9A-F]{8})$'

function Assert-Condition([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Get-Sha([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-ByteSha([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')
  } finally {$sha.Dispose()}
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
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
  $input = [IO.FileStream]::new($Source,[IO.FileMode]::Open,
      [IO.FileAccess]::Read,[IO.FileShare]::Read)
  $output = [IO.FileStream]::new($target,[IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,[IO.FileShare]::Read,4096,
      [IO.FileOptions]::WriteThrough)
  try {
    $input.CopyTo($output)
    $output.Flush($true)
  } finally {$output.Dispose();$input.Dispose()}
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
  $runnerLength = [int64](Get-Item -LiteralPath $PSCommandPath).Length
  [void](Copy-PinnedArtifact $PSCommandPath 'runner.executed.ps1' `
      $runnerLength $script:RunnerStartSha256)
  [void](Copy-PinnedArtifact $definitionPath 'mavlink_frame.cpp' `
      16510 $definitionSha256)
  if ($R19SharedMode.IsPresent) {
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($R19ProvenancePath)) `
        'R19SharedMode requires R19ProvenancePath from the dedicated wrapper.'
    $resolvedProvenance = (Resolve-Path -LiteralPath $R19ProvenancePath `
        -ErrorAction Stop).Path
    $provenanceBytes = [IO.File]::ReadAllBytes($resolvedProvenance)
    $provenance = $utf8.GetString($provenanceBytes) | ConvertFrom-Json
    Assert-Condition ([string]$provenance.schema -ceq
        'vc-lora-r19-live-acceptance-provenance-v1' -and
        [string]$provenance.result -ceq 'PASS') `
        'R19 provenance is not a validated PASS record.'
    Assert-Condition ($provenance.PSObject.Properties[
          'runtime_fail_diagnostics_enabled'] -and
        $provenance.runtime_fail_diagnostics_enabled -is [bool] -and
        -not [bool]$provenance.runtime_fail_diagnostics_enabled -and
        $provenance.PSObject.Properties['acceptance_eligible'] -and
        $provenance.acceptance_eligible -is [bool] -and
        [bool]$provenance.acceptance_eligible -and
        $provenance.PSObject.Properties['acceptance_authorized'] -and
        $provenance.acceptance_authorized -is [bool] -and
        -not [bool]$provenance.acceptance_authorized -and
        $provenance.PSObject.Properties['deployment_authorized'] -and
        $provenance.deployment_authorized -is [bool] -and
        -not [bool]$provenance.deployment_authorized) `
        ('R19 acceptance provenance requires diagnostics=false, ' +
         'acceptance_eligible=true, acceptance_authorized=false, and ' +
         'deployment_authorized=false.')
    $script:R19Provenance = $provenance
    [void](Copy-PinnedArtifact $resolvedProvenance `
        'r19.validated.provenance.json' ([int64]$provenanceBytes.Length) `
        (Get-ByteSha $provenanceBytes))
  } else {
    [void](Copy-PinnedArtifact $groundR18Path `
        'ground.r18.accepted.application.bin' 360208 $groundR18Sha256)
    [void](Copy-PinnedArtifact $vehicleR18Path `
        'vehicle.r18.accepted.application.bin' 389280 $vehicleR18Sha256)
    [void](Copy-PinnedArtifact $restoreEvidencePath `
        'prior.r18.restore_and_inventory.summary.json' 41140 `
        $restoreEvidenceSha256)
  }
  [byte[]]$request = New-ExactParamRequestList
  Write-DurableBytes (Join-Path $evidence 'request_fixture_exact_once.bin') $request
  Assert-Condition ((Get-Sha (Join-Path $evidence `
      'request_fixture_exact_once.bin')) -ceq $exactRequestSha256) `
      'Staged request fixture SHA-256 mismatch.'
  $script:Definitions = Get-MavlinkDefinitions $definitionPath
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
      $definitions[21].crc_extra -eq 159 -and
      $definitions[22].crc_extra -eq 220) `
      'Required MAVLink definitions changed.'
  return $definitions
}

function Convert-HexToBytes([string]$Hex) {
  Assert-Condition (($Hex.Length % 2) -eq 0) 'Odd hexadecimal length.'
  [byte[]]$bytes = New-Object byte[] ($Hex.Length / 2)
  for ($index = 0; $index -lt $bytes.Length; ++$index) {
    $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2,2),16)
  }
  return $bytes
}

function Test-ByteEqual([byte[]]$Left,[byte[]]$Right) {
  if ($Left.Length -ne $Right.Length) {return $false}
  for ($index = 0; $index -lt $Left.Length; ++$index) {
    if ($Left[$index] -ne $Right[$index]) {return $false}
  }
  return $true
}

function New-ExactParamRequestList {
  [byte[]]$request = Convert-HexToBytes $exactRequestHex
  Assert-Condition ($request.Length -eq 14) `
      'Exact PARAM_REQUEST_LIST length must be 14 bytes.'
  Assert-Condition ((Get-ByteSha $request) -ceq $exactRequestSha256) `
      'Exact PARAM_REQUEST_LIST SHA-256 mismatch.'
  return $request
}

function Update-X25Crc([uint16]$Crc,[byte]$Value) {
  [int]$mixed = ($Value -bxor ($Crc -band 0xFF)) -band 0xFF
  $mixed = ($mixed -bxor (($mixed -shl 4) -band 0xFF)) -band 0xFF
  return [uint16]((($Crc -shr 8) -bxor ($mixed -shl 8) -bxor
      ($mixed -shl 3) -bxor ($mixed -shr 4)) -band 0xFFFF)
}

function New-MavlinkParser([string]$Name,[bool]$ComputeRawSha = $true) {
  return [pscustomobject][ordered]@{
    name=$Name
    buffer=[Collections.Generic.List[byte]]::new()
    expected_size=0
    frame_start_us=[int64]-1
    frame_start_raw_offset=[int64]-1
    total_bytes=[int64]0
    noise_bytes=[int64]0
    bad_length=[int64]0
    bad_crc=[int64]0
    unsupported_flags=[int64]0
    unknown_definition=[int64]0
    valid_frames=[int64]0
    compute_raw_sha=$ComputeRawSha
    frames=[Collections.ArrayList]::new()
  }
}

function Convert-MavlinkFrameRecord([byte[]]$Raw,[int64]$StartUs,
    [int64]$CompleteUs,[int64]$StartRawOffset,[bool]$ComputeRawSha) {
  $magic = [int]$Raw[0]
  $payloadLength = [int]$Raw[1]
  if ($magic -eq 0xFD) {
    $version = 2
    $incompat = [int]$Raw[2]
    $sequence = [int]$Raw[4]
    $systemId = [int]$Raw[5]
    $componentId = [int]$Raw[6]
    $messageId = [int]$Raw[7] -bor ([int]$Raw[8] -shl 8) -bor
        ([int]$Raw[9] -shl 16)
    $payloadOffset = 10
    $checksumOffset = 10 + $payloadLength
    $unsupportedFlags = (($incompat -band 0xFE) -ne 0)
  } else {
    $version = 1
    $incompat = 0
    $sequence = [int]$Raw[2]
    $systemId = [int]$Raw[3]
    $componentId = [int]$Raw[4]
    $messageId = [int]$Raw[5]
    $payloadOffset = 6
    $checksumOffset = 6 + $payloadLength
    $unsupportedFlags = $false
  }
  $failure = ''
  if ($unsupportedFlags) {
    $failure = 'unsupported_flags'
  } elseif (-not $script:Definitions.ContainsKey($messageId)) {
    $failure = 'unknown_definition'
  } else {
    $definition = $script:Definitions[$messageId]
    $minimum = [int]$definition.min_payload
    if ($version -eq 2 -and $messageId -eq 20) {$minimum = 4}
    if ($version -eq 2 -and $messageId -eq 76) {$minimum = 30}
    if ($payloadLength -lt $minimum -or
        $payloadLength -gt [int]$definition.max_payload -or
        ($version -eq 1 -and $payloadLength -ne [int]$definition.min_payload)) {
      $failure = 'bad_length'
    } else {
      [uint16]$crc = 0xFFFF
      for ($index = 1; $index -lt $checksumOffset; ++$index) {
        $crc = Update-X25Crc $crc $Raw[$index]
      }
      $crc = Update-X25Crc $crc ([byte]$definition.crc_extra)
      [uint16]$stored = [uint16]([int]$Raw[$checksumOffset] -bor
          ([int]$Raw[$checksumOffset + 1] -shl 8))
      if ($stored -ne $crc) {$failure = 'bad_crc'}
    }
  }
  return [pscustomobject][ordered]@{
    frame_start_us=$StartUs
    complete_us=$CompleteUs
    frame_start_raw_offset=$StartRawOffset
    valid=[string]::IsNullOrEmpty($failure)
    failure=$failure
    version=$version
    sequence=$sequence
    system_id=$systemId
    component_id=$componentId
    message_id=$messageId
    payload_length=$payloadLength
    payload_offset=$payloadOffset
    signed=(($incompat -band 1) -ne 0)
    raw=$Raw
    raw_length=$Raw.Length
    raw_sha256=if ($ComputeRawSha) {Get-ByteSha $Raw} else {''}
  }
}

function Add-MavlinkBytes([object]$Parser,[byte[]]$Bytes,
    [int64]$ElapsedUs) {
  foreach ($value in $Bytes) {
    [int64]$rawOffset = [int64]$Parser.total_bytes
    $Parser.total_bytes = $rawOffset + 1
    if ($Parser.buffer.Count -eq 0) {
      if ($value -ne 0xFD -and $value -ne 0xFE) {
        $Parser.noise_bytes = [int64]$Parser.noise_bytes + 1
        continue
      }
      $Parser.frame_start_us = $ElapsedUs
      $Parser.frame_start_raw_offset = $rawOffset
    }
    $Parser.buffer.Add($value)
    if ($Parser.buffer.Count -eq 2 -and $Parser.buffer[0] -eq 0xFE) {
      $Parser.expected_size = [int]$Parser.buffer[1] + 8
    }
    if ($Parser.buffer.Count -eq 3 -and $Parser.buffer[0] -eq 0xFD) {
      $signature = if (($Parser.buffer[2] -band 1) -ne 0) {13} else {0}
      $Parser.expected_size = [int]$Parser.buffer[1] + 12 + $signature
    }
    if ($Parser.expected_size -gt 0 -and
        $Parser.buffer.Count -eq $Parser.expected_size) {
      [byte[]]$raw = $Parser.buffer.ToArray()
      $record = Convert-MavlinkFrameRecord $raw `
          ([int64]$Parser.frame_start_us) $ElapsedUs `
          ([int64]$Parser.frame_start_raw_offset) `
          ([bool]$Parser.compute_raw_sha)
      if ($record.valid) {
        $Parser.valid_frames = [int64]$Parser.valid_frames + 1
      } else {
        switch ($record.failure) {
          'bad_crc' {$Parser.bad_crc = [int64]$Parser.bad_crc + 1}
          'bad_length' {$Parser.bad_length = [int64]$Parser.bad_length + 1}
          'unsupported_flags' {
            $Parser.unsupported_flags = [int64]$Parser.unsupported_flags + 1
          }
          'unknown_definition' {
            $Parser.unknown_definition = [int64]$Parser.unknown_definition + 1
          }
        }
      }
      [void]$Parser.frames.Add($record)
      $Parser.buffer.Clear()
      $Parser.expected_size = 0
      $Parser.frame_start_us = [int64]-1
      $Parser.frame_start_raw_offset = [int64]-1
    } elseif ($Parser.buffer.Count -gt 280) {
      $Parser.bad_length = [int64]$Parser.bad_length + 1
      $Parser.buffer.Clear()
      $Parser.expected_size = 0
      $Parser.frame_start_us = [int64]-1
      $Parser.frame_start_raw_offset = [int64]-1
    }
  }
}

function Get-ParserSnapshot([object]$Parser) {
  return [pscustomobject][ordered]@{
    total_bytes=[int64]$Parser.total_bytes
    noise_bytes=[int64]$Parser.noise_bytes
    bad_lengths=[int64]$Parser.bad_length
    bad_crc=[int64]$Parser.bad_crc
    unsupported_flags=[int64]$Parser.unsupported_flags
    unknown_definition=[int64]$Parser.unknown_definition
    partial_bytes=[int]$Parser.buffer.Count
    frame_count=[int]$Parser.frames.Count
  }
}

function Get-R19RuntimeFailSourceBinding([string]$RoleCode,
    [object]$Provenance) {
  $role = if ($RoleCode -ceq 'G') {'ground'} elseif (
      $RoleCode -ceq 'V') {'vehicle'} else {''}
  $failure = ''
  $binding = $null
  $application = $null
  if ([string]::IsNullOrEmpty($role) -or $null -eq $Provenance -or
      $null -eq $Provenance.candidate) {
    $failure = 'source_provenance_missing'
  } else {
    $bindings = @($Provenance.candidate.source_bindings | Where-Object {
      [string]$_.role -ceq $role
    })
    $applications = @($Provenance.candidate.roles | Where-Object {
      [string]$_.role -ceq $role
    })
    if ($bindings.Count -ne 1 -or $applications.Count -ne 1) {
      $failure = 'source_mapping_not_unique'
    } else {
      $binding = $bindings[0]
      $application = $applications[0]
      $expectedPath = ('package/vc_lora_{0}_xiao_esp32s3/' +
          'vc_lora_phase6_bridge.hpp') -f $role
      $sourceSha = [string]$binding.source_sha256
      $verifiedSha = [string]$binding.verified_source_sha256
      $applicationSha = [string]$binding.application_sha256
      if ([string]$binding.source_path -cne $expectedPath -or
          $binding.source_verified -isnot [bool] -or
          -not [bool]$binding.source_verified -or
          $sourceSha -cnotmatch '^[0-9A-F]{64}$' -or
          $verifiedSha -cnotmatch '^[0-9A-F]{64}$' -or
          $sourceSha -cne $verifiedSha -or
          $applicationSha -cnotmatch '^[0-9A-F]{64}$' -or
          [string]$application.sha256 -cne $applicationSha) {
        $failure = 'source_hash_or_role_binding_mismatch'
      }
    }
  }
  return [pscustomobject][ordered]@{
    verified=[string]::IsNullOrEmpty($failure);failure=$failure;role=$role
    source_path=if ($null -ne $binding) {[string]$binding.source_path} else {''}
    source_sha256=if ($null -ne $binding) {
      [string]$binding.source_sha256
    } else {''}
    verified_source_sha256=if ($null -ne $binding) {
      [string]$binding.verified_source_sha256
    } else {''}
    application_sha256=if ($null -ne $binding) {
      [string]$binding.application_sha256
    } else {''}
  }
}

function Get-R19RuntimeFailDiagnosticRecord([object]$Record,[int]$Ordinal,
    [object]$Provenance) {
  [byte[]]$raw = [byte[]]$Record.raw
  [int]$payloadOffset = [int]$Record.payload_offset
  [int]$payloadLength = [int]$Record.payload_length
  $prefix = ''
  if ([int]$Record.version -eq 2 -and [int]$Record.message_id -eq 253 -and
      $payloadLength -ge 5 -and $raw.Length -ge ($payloadOffset + 5)) {
    $prefix = [Text.Encoding]::ASCII.GetString(
        $raw,$payloadOffset + 1,4)
  }
  $candidate = $prefix -ceq 'R19F'
  if (-not $candidate) {
    return [pscustomobject][ordered]@{candidate=$false}
  }

  $failures = [Collections.ArrayList]::new()
  $rawSha = Get-ByteSha $raw
  if (-not [bool]$Record.valid) {
    [void]$failures.Add('mavlink_' + [string]$Record.failure)
  }
  if ([int]$Record.version -ne 2 -or [bool]$Record.signed -or
      [int]$Record.system_id -ne 254 -or
      [int]$Record.component_id -ne 190 -or
      [int]$Record.message_id -ne 253 -or $payloadLength -ne 51 -or
      [int]$Record.raw_length -ne 63) {
    [void]$failures.Add('identity_or_length_mismatch')
  }
  if ($payloadLength -lt 51 -or $raw.Length -lt ($payloadOffset + 51)) {
    [void]$failures.Add('truncated_statustext_payload')
  }
  $severity = if ($raw.Length -gt $payloadOffset) {
    [int]$raw[$payloadOffset]
  } else {-1}
  if ($severity -ne 2) {[void]$failures.Add('severity_mismatch')}
  if ([string]$Record.raw_sha256 -cnotmatch '^[0-9A-F]{64}$' -or
      [string]$Record.raw_sha256 -cne $rawSha) {
    [void]$failures.Add('raw_frame_hash_mismatch')
  }

  $text = if ($payloadLength -ge 51 -and
      $raw.Length -ge ($payloadOffset + 51)) {
    [Text.Encoding]::ASCII.GetString($raw,$payloadOffset + 1,50)
  } else {''}
  $match = [regex]::Match($text,$r19RuntimeFailPattern,
      [Text.RegularExpressions.RegexOptions]::CultureInvariant)
  if (-not $match.Success) {[void]$failures.Add('text_format_mismatch')}

  $roleCode = if ($match.Success) {$match.Groups['role'].Value} else {''}
  $sourceBinding = Get-R19RuntimeFailSourceBinding $roleCode $Provenance
  if (-not [bool]$sourceBinding.verified) {
    [void]$failures.Add([string]$sourceBinding.failure)
  }
  [int]$sourceLine = 0
  [string]$monotonicHex = ''
  [string]$monotonicDecimal = ''
  [string]$statusHex = ''
  [int64]$usbEpoch = -1
  $status = $null
  if ($match.Success) {
    $sourceLine = [Convert]::ToInt32($match.Groups['line'].Value,16)
    $monotonicHex = $match.Groups['time'].Value
    $monotonicDecimal = [Convert]::ToUInt64($monotonicHex,16).ToString(
        [Globalization.CultureInfo]::InvariantCulture)
    $statusHex = $match.Groups['status'].Value
    $packed = [Convert]::ToInt32($statusHex.Substring(10,2),16)
    $status = [pscustomobject][ordered]@{
      startup_fault=[Convert]::ToInt32($statusHex.Substring(0,2),16)
      e220_state=[Convert]::ToInt32($statusHex.Substring(2,2),16)
      e220_fault=[Convert]::ToInt32($statusHex.Substring(4,2),16)
      writer_status=[Convert]::ToInt32($statusHex.Substring(6,2),16)
      radio_session_status=[Convert]::ToInt32(
          $statusHex.Substring(8,2),16)
      packed=$packed;adapter_fail_closed=(($packed -band 0x80) -ne 0)
      tdd_state=($packed -band 0x7F)
    }
    $usbEpoch = [Convert]::ToInt64($match.Groups['epoch'].Value,16)
    if ($sourceLine -eq 0) {[void]$failures.Add('source_line_zero')}
  }
  $success = $failures.Count -eq 0
  return [pscustomobject][ordered]@{
    candidate=$true;diagnostic_success=$success
    failure=if ($success) {''} else {@($failures) -join ','}
    ordinal=$Ordinal;frame_complete_us=[int64]$Record.complete_us
    frame_start_raw_offset=[int64]$Record.frame_start_raw_offset
    system_id=[int]$Record.system_id;component_id=[int]$Record.component_id
    message_id=[int]$Record.message_id;severity=$severity
    text=$text;role_code=$roleCode;role=[string]$sourceBinding.role
    source_line=$sourceLine;monotonic_ms_hex=$monotonicHex
    monotonic_ms_decimal=$monotonicDecimal;status_hex=$statusHex
    status=$status;usb_loss_epoch=$usbEpoch
    source_mapping_verified=[bool]$sourceBinding.verified
    source_path=[string]$sourceBinding.source_path
    source_sha256=[string]$sourceBinding.source_sha256
    application_sha256=[string]$sourceBinding.application_sha256
    raw_frame=[pscustomobject][ordered]@{
      path='';bytes=[int]$Record.raw_length;sha256=$rawSha
      parser_sha256=[string]$Record.raw_sha256
    }
  }
}

function Register-R19RuntimeFailFrame([object]$Record,[int]$Ordinal) {
  if (-not $R19SharedMode.IsPresent) {return}
  $decoded = Get-R19RuntimeFailDiagnosticRecord $Record $Ordinal `
      $script:R19Provenance
  if (-not [bool]$decoded.candidate -or
      -not $script:R19RuntimeFailOrdinals.Add($Ordinal)) {return}
  $directory = Join-Path $evidence 'runtime_fail_diagnostics'
  [void][IO.Directory]::CreateDirectory($directory)
  $leaf = 'frame-{0:D6}.bin' -f $Ordinal
  $rawPath = Join-Path $directory $leaf
  Write-DurableBytes $rawPath ([byte[]]$Record.raw)
  $decoded.raw_frame.path = 'runtime_fail_diagnostics/' + $leaf
  $metadataPath = Join-Path $directory ('frame-{0:D6}.json' -f $Ordinal)
  Write-DurableJson $metadataPath $decoded
  [void]$script:R19RuntimeFailDiagnostics.Add($decoded)
}

function Get-R19RuntimeFailAcceptanceResult([object[]]$Diagnostics) {
  $records = @($Diagnostics)
  if (@($records | Where-Object {[bool]$_.diagnostic_success}).Count -gt 0) {
    return 'FAIL_RUNTIME_DIAGNOSTIC_OBSERVED'
  }
  if ($records.Count -gt 0) {return 'FAIL_INVALID_RUNTIME_DIAGNOSTIC'}
  return 'PASS_NO_RUNTIME_FAILURE_DIAGNOSTIC'
}

function Get-R19RuntimeFailDiagnosticSummary {
  if (-not $R19SharedMode.IsPresent) {
    return [pscustomobject][ordered]@{
      result='NOT_APPLICABLE';acceptance_eligible=$true
      candidate_count=0;valid_diagnostic_count=0
      invalid_diagnostic_count=0;diagnostics=@()
    }
  }
  $records = @($script:R19RuntimeFailDiagnostics)
  $valid = @($records | Where-Object {[bool]$_.diagnostic_success})
  $invalid = @($records | Where-Object {-not [bool]$_.diagnostic_success})
  $result = Get-R19RuntimeFailAcceptanceResult $records
  return [pscustomobject][ordered]@{
    result=$result;acceptance_eligible=($records.Count -eq 0)
    candidate_count=$records.Count;valid_diagnostic_count=$valid.Count
    invalid_diagnostic_count=$invalid.Count;diagnostics=$records
  }
}

function Assert-NoR19RuntimeFailDiagnostic {
  $summary = Get-R19RuntimeFailDiagnosticSummary
  if ($R19SharedMode.IsPresent -and -not [bool]$summary.acceptance_eligible) {
    throw ("R19 acceptance forbidden: {0}; diagnostic_count={1}" -f `
        [string]$summary.result,[int]$summary.candidate_count)
  }
}

function Get-ParserErrorDelta([object]$Parser,[object]$Baseline) {
  return [pscustomobject][ordered]@{
    noise_bytes=[int64]$Parser.noise_bytes - [int64]$Baseline.noise_bytes
    bad_lengths=[int64]$Parser.bad_length - [int64]$Baseline.bad_lengths
    bad_crc=[int64]$Parser.bad_crc - [int64]$Baseline.bad_crc
    unsupported_flags=[int64]$Parser.unsupported_flags -
        [int64]$Baseline.unsupported_flags
    unknown_definition=[int64]$Parser.unknown_definition -
        [int64]$Baseline.unknown_definition
    partial_bytes=[int]$Parser.buffer.Count
  }
}

function Get-HeartbeatAcceptance([object[]]$PreHeartbeatFrames,
    [object[]]$PostHeartbeatFrames,[int64]$RequestWriteStartedUs,
    [int64]$LastParamUs,[int64]$CaptureEndUs) {
  $preTimes = @($PreHeartbeatFrames | ForEach-Object {[int64]$_.complete_us} |
      Sort-Object)
  $postTimes = @($PostHeartbeatFrames | ForEach-Object {[int64]$_.complete_us} |
      Sort-Object)
  [int64]$lastPre = if ($preTimes.Count -gt 0) {
    [int64]$preTimes[$preTimes.Count - 1]
  } else {-1}
  [int64]$firstPost = if ($postTimes.Count -gt 0) {
    [int64]$postTimes[0]
  } else {-1}
  $postCompletion = @()
  if ($LastParamUs -ge 0) {
    $postCompletion = @($postTimes | Where-Object {$_ -gt $LastParamUs} |
        Select-Object -First 1)
  }
  [int64]$preToRequest = if ($lastPre -ge 0) {
    $RequestWriteStartedUs - $lastPre
  } else {[int64]::MaxValue}
  [int64]$requestToFirst = if ($firstPost -ge 0) {
    $firstPost - $RequestWriteStartedUs
  } else {[int64]::MaxValue}
  [int64]$preToFirst = if ($lastPre -ge 0 -and $firstPost -ge 0) {
    $firstPost - $lastPre
  } else {[int64]::MaxValue}
  [int64]$maximumConsecutive = 0
  for ($index = 1; $index -lt $postTimes.Count; ++$index) {
    [int64]$gap = [int64]$postTimes[$index] - [int64]$postTimes[$index - 1]
    if ($gap -gt $maximumConsecutive) {$maximumConsecutive = $gap}
  }
  [int64]$completionToPost = if ($postCompletion.Count -eq 1) {
    [int64]$postCompletion[0] - $LastParamUs
  } else {[int64]::MaxValue}
  [int64]$tailGap = if ($postTimes.Count -gt 0) {
    $CaptureEndUs - [int64]$postTimes[$postTimes.Count - 1]
  } else {[int64]::MaxValue}
  [int64]$maximumFullWindow = 0
  foreach ($candidateGap in @(
      $preToRequest,$requestToFirst,$preToFirst,$maximumConsecutive,
      $completionToPost,$tailGap)) {
    if ([int64]$candidateGap -gt $maximumFullWindow) {
      $maximumFullWindow = [int64]$candidateGap
    }
  }
  $validNonnegative = $preToRequest -ge 0 -and $requestToFirst -ge 0 -and
      $preToFirst -ge 0 -and $completionToPost -ge 0 -and $tailGap -ge 0
  $pass = $preTimes.Count -ge 2 -and $postTimes.Count -ge 1 -and
      $postCompletion.Count -eq 1 -and $validNonnegative -and
      $preToRequest -le $HeartbeatLimitUs -and
      $requestToFirst -le $HeartbeatLimitUs -and
      $preToFirst -le $HeartbeatLimitUs -and
      $maximumConsecutive -le $HeartbeatLimitUs -and
      $completionToPost -le $HeartbeatLimitUs -and
      $tailGap -le $HeartbeatLimitUs
  return [pscustomobject][ordered]@{
    result=if ($pass) {'PASS'} else {'FAIL'}
    preflight_heartbeat_count=$preTimes.Count
    post_request_heartbeat_count=$postTimes.Count
    last_pre_heartbeat_us=$lastPre
    first_post_heartbeat_us=$firstPost
    pre_to_request_us=$preToRequest
    request_to_first_heartbeat_us=$requestToFirst
    last_pre_to_first_post_gap_us=$preToFirst
    maximum_consecutive_gap_us=$maximumConsecutive
    completion_to_post_heartbeat_us=$completionToPost
    tail_gap_us=$tailGap
    maximum_full_window_gap_us=$maximumFullWindow
    limit_us=$HeartbeatLimitUs
  }
}

function Test-ValidParamId([byte[]]$Raw,[int]$PayloadOffset,
    [ref]$ParamId) {
  $builder = [Text.StringBuilder]::new()
  $sawZero = $false
  for ($offset = 0; $offset -lt 16; ++$offset) {
    [int]$value = $Raw[$PayloadOffset + 8 + $offset]
    if ($value -eq 0) {
      $sawZero = $true
    } elseif ($sawZero -or $value -lt 0x20 -or $value -gt 0x7E) {
      $ParamId.Value = ''
      return $false
    } else {
      [void]$builder.Append([char]$value)
    }
  }
  $ParamId.Value = $builder.ToString()
  return $builder.Length -gt 0
}

function Get-StrictParamAccounting([object]$Parser,[object]$Boundary,
    [object[]]$PreHeartbeatFrames,[int64]$CaptureEndUs,
    [int64]$MaximumPumpServiceGapUs) {
  $records = @($Parser.frames | Where-Object {
    [int64]$_.frame_start_raw_offset -ge [int64]$Boundary.raw_offset -and
        [int64]$_.complete_us -ge [int64]$Boundary.request_write_started_us
  })
  $parameterFrames = @($records | Where-Object {$_.message_id -eq 22})
  $postHeartbeats = @($records | Where-Object {
    $_.valid -and $_.version -eq 2 -and -not $_.signed -and
        $_.message_id -eq 0 -and $_.system_id -eq 1 -and
        $_.component_id -eq 1 -and $_.payload_length -eq 9 -and
        $_.raw_length -eq 21
  })
  $seen = New-Object bool[] $ExpectedParameters
  $paramIds = [Collections.Generic.HashSet[string]]::new(
      [StringComparer]::Ordinal)
  [int]$missing = $ExpectedParameters
  [int]$duplicate = 0
  [int]$unexpected = 0
  [int]$future = 0
  [int]$outOfOrder = 0
  [int]$outOfRange = 0
  [int]$wrongSource = 0
  [int]$countMismatch = 0
  [int]$badPayload = 0
  [int]$invalidParamId = 0
  [int]$duplicateParamId = 0
  [int]$invalidParamType = 0
  [int]$paramOrdinal = 0
  [int64]$firstParamUs = -1
  [int64]$lastParamUs = -1
  $indexLedger = [Collections.ArrayList]::new()
  foreach ($record in $parameterFrames) {
    $acceptedShape = $record.valid -and $record.version -eq 2 -and
        -not $record.signed -and $record.payload_length -eq 25 -and
        $record.raw_length -eq 37
    if (-not $acceptedShape) {
      ++$badPayload
      ++$unexpected
      continue
    }
    if ($record.system_id -ne 1 -or $record.component_id -ne 1) {
      ++$wrongSource
      ++$unexpected
      continue
    }
    [byte[]]$raw = $record.raw
    [int]$payloadOffset = [int]$record.payload_offset
    [int]$paramCount = [BitConverter]::ToUInt16($raw,$payloadOffset + 4)
    [int]$paramIndex = [BitConverter]::ToUInt16($raw,$payloadOffset + 6)
    if ($paramCount -ne $ExpectedParameters) {
      ++$countMismatch
      ++$unexpected
    }
    if ($paramIndex -lt 0 -or $paramIndex -ge $ExpectedParameters) {
      ++$outOfRange
      ++$unexpected
      continue
    }
    [int]$expectedOrdinal = $paramOrdinal
    ++$paramOrdinal
    if ($paramIndex -ne $expectedOrdinal) {
      ++$unexpected
      if ($paramIndex -gt $expectedOrdinal) {++$future} else {++$outOfOrder}
    }
    if ($seen[$paramIndex]) {
      ++$duplicate
    } else {
      $seen[$paramIndex] = $true
      --$missing
    }
    $paramId = ''
    if (-not (Test-ValidParamId $raw $payloadOffset ([ref]$paramId))) {
      ++$invalidParamId
    } elseif (-not $paramIds.Add($paramId)) {
      ++$duplicateParamId
    }
    [int]$paramType = [int]$raw[$payloadOffset + 24]
    if ($paramType -lt 1 -or $paramType -gt 10) {++$invalidParamType}
    if ($paramIndex -eq 0 -and $firstParamUs -lt 0) {
      $firstParamUs = [int64]$record.complete_us
    }
    if ($paramIndex -eq ($ExpectedParameters - 1) -and $lastParamUs -lt 0) {
      $lastParamUs = [int64]$record.complete_us
    }
    [void]$indexLedger.Add([pscustomobject][ordered]@{
      index=$paramIndex;param_count=$paramCount;param_id=$paramId
      param_type=$paramType;sequence=[int]$record.sequence
      frame_start_us=[int64]$record.frame_start_us
      complete_us=[int64]$record.complete_us
      frame_start_raw_offset=[int64]$record.frame_start_raw_offset
      raw_sha256=[string]$record.raw_sha256
    })
  }
  $parserDelta = Get-ParserErrorDelta $Parser $Boundary.parser_baseline
  [int64]$parserErrorCount = [int64]$parserDelta.noise_bytes +
      [int64]$parserDelta.bad_lengths + [int64]$parserDelta.bad_crc +
      [int64]$parserDelta.unsupported_flags +
      [int64]$parserDelta.unknown_definition + [int64]$parserDelta.partial_bytes
  [int64]$requestToLastUs = if ($lastParamUs -ge 0) {
    $lastParamUs - [int64]$Boundary.request_write_started_us
  } else {-1}
  [int64]$completeEdgeToLastUs = if ($lastParamUs -ge 0 -and
      [int64]$Boundary.request_complete_write_edge_us -ge 0) {
    $lastParamUs - [int64]$Boundary.request_complete_write_edge_us
  } else {-1}
  $heartbeat = Get-HeartbeatAcceptance $PreHeartbeatFrames $postHeartbeats `
      ([int64]$Boundary.request_write_started_us) $lastParamUs $CaptureEndUs
  $duplicateGuardCompleted = $lastParamUs -ge 0 -and
      $CaptureEndUs -ge ($lastParamUs + $DuplicateGuardUs)
  $dataStrict = $parameterFrames.Count -eq $ExpectedParameters -and
      $missing -eq 0 -and $duplicate -eq 0 -and $unexpected -eq 0 -and
      $future -eq 0 -and $outOfOrder -eq 0 -and $outOfRange -eq 0 -and
      $wrongSource -eq 0 -and $countMismatch -eq 0 -and
      $badPayload -eq 0 -and $invalidParamId -eq 0 -and
      $duplicateParamId -eq 0 -and $invalidParamType -eq 0 -and
      $paramOrdinal -eq $ExpectedParameters -and $parserErrorCount -eq 0
  $timingAccurate = $MaximumPumpServiceGapUs -le $PumpServiceLimitUs
  $target30 = $dataStrict -and $requestToLastUs -ge 0 -and
      $requestToLastUs -le $Target30LimitUs
  $target10 = $dataStrict -and $requestToLastUs -ge 0 -and
      $requestToLastUs -le $Stretch10LimitUs
  $pass = $dataStrict -and $heartbeat.result -ceq 'PASS' -and
      $target30 -and $duplicateGuardCompleted -and $timingAccurate -and
      [string]$Boundary.request_outcome -ceq 'COMPLETE'
  $sequenceDiscontinuities = 0
  for ($index = 1; $index -lt $indexLedger.Count; ++$index) {
    if ([int]$indexLedger[$index].sequence -ne
        (([int]$indexLedger[$index - 1].sequence + 1) -band 0xFF)) {
      ++$sequenceDiscontinuities
    }
  }
  return [pscustomobject][ordered]@{
    result=if ($pass) {'PASS'} else {'FAIL'}
    data_result=if ($dataStrict) {'PASS'} else {'FAIL'}
    heartbeat_result=[string]$heartbeat.result
    expected=932
    parameter_frames=$parameterFrames.Count
    unique=$ExpectedParameters - $missing
    missing=$missing
    duplicate=$duplicate
    unexpected=$unexpected
    future=$future
    out_of_order=$outOfOrder
    out_of_range=$outOfRange
    wrong_source=$wrongSource
    count_mismatch=$countMismatch
    bad_payload=$badPayload
    invalid_param_id=$invalidParamId
    duplicate_param_id=$duplicateParamId
    invalid_param_type=$invalidParamType
    parser_error_count=$parserErrorCount
    control_leakage_bytes=[int64]$parserDelta.noise_bytes
    all_parser_crc_partial_control_errors_zero=($parserErrorCount -eq 0)
    parser=$parserDelta
    first_param_us=$firstParamUs
    last_param_us=$lastParamUs
    request_to_last_us=$requestToLastUs
    request_to_last_ms=if ($requestToLastUs -ge 0) {
      $requestToLastUs / 1000.0
    } else {$null}
    complete_edge_to_last_us=$completeEdgeToLastUs
    target_30s=if ($target30) {'PASS'} else {'FAIL'}
    target_10s=if ($target10) {'PASS'} else {'FAIL'}
    target_30s_hard_gate=$true
    target_10s_hard_gate=$false
    duplicate_guard_completed=$duplicateGuardCompleted
    duplicate_guard_us=$DuplicateGuardUs
    maximum_pump_service_gap_us=$MaximumPumpServiceGapUs
    pump_service_limit_us=$PumpServiceLimitUs
    heartbeat_timing_accurate=$timingAccurate
    mavlink_sequence_diagnostic_only=$true
    mavlink_sequence_discontinuities=$sequenceDiscontinuities
    heartbeat=$heartbeat
    index_ledger=@($indexLedger)
  }
}

function Get-ElapsedUs([Diagnostics.Stopwatch]$Clock) {
  return [int64][math]::Floor(
      ([double]$Clock.ElapsedTicks * 1000000.0) /
      [double][Diagnostics.Stopwatch]::Frequency)
}

function Assert-NoCompetingClients {
  $script:ExternalActions.process_inventory_queried = $true
  $names = @('MissionPlanner','mavproxy','qgroundcontrol','putty','teraterm',
      'arduino','arduino-cli')
  $found = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $names -contains $_.ProcessName
  } | Select-Object ProcessName,Id,Path)
  if ($found.Count -ne 0) {
    throw ('Competing serial client/process found: ' +
        (($found | ForEach-Object {"$($_.ProcessName):$($_.Id)"}) -join ','))
  }
  return @($found)
}

function Assert-ExactGroundIdentity([string]$Checkpoint) {
  Assert-Condition ($GroundPort -ceq 'COM6') 'Ground port pin changed.'
  Assert-Condition ($ForbiddenPorts -contains 'COM3') `
      'COM3 must remain explicitly forbidden.'
  $script:ExternalActions.cim_queried = $true
  $records = @(Get-CimInstance Win32_SerialPort -ErrorAction Stop |
      Where-Object {[string]$_.DeviceID -ceq $GroundPort})
  Assert-Condition ($records.Count -ne 0) `
      "Ground identity missing at ${Checkpoint}: $GroundPort"
  Assert-Condition ($records.Count -eq 1) `
      "Ground identity ambiguous at ${Checkpoint}: count=$($records.Count)"
  $record = $records[0]
  $actualPnp = [string]$record.PNPDeviceID
  Assert-Condition ([string]::Equals($actualPnp,$GroundPnpDeviceId,
      [StringComparison]::OrdinalIgnoreCase)) `
      "Ground PNP mismatch at ${Checkpoint}: $actualPnp"
  $upperPnp = $actualPnp.ToUpperInvariant()
  Assert-Condition ($upperPnp.Contains("VID_$GroundVid") -and
      $upperPnp.Contains("PID_$GroundPid")) `
      "Ground VID/PID mismatch at ${Checkpoint}: $actualPnp"
  Assert-Condition ([string]$record.Status -ceq 'OK' -and
      [int]$record.ConfigManagerErrorCode -eq 0) `
      ("Ground device health is not OK at {0}: status={1} cm_error={2}" -f `
       $Checkpoint,[string]$record.Status,[int]$record.ConfigManagerErrorCode)
  $script:ExternalActions.pnp_queried = $true
  $parentProperty = Get-PnpDeviceProperty -InstanceId $actualPnp `
      -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop
  $actualParent = [string]$parentProperty.Data
  Assert-Condition ([string]::Equals($actualParent,$GroundParentDeviceId,
      [StringComparison]::OrdinalIgnoreCase)) `
      "Ground parent mismatch at ${Checkpoint}: $actualParent"
  return [pscustomobject][ordered]@{
    result='PASS';checkpoint=$Checkpoint;port=[string]$record.DeviceID
    pnp_device_id=$actualPnp;parent_device_id=$actualParent
    vid=$GroundVid;pid=$GroundPid;name=[string]$record.Name
    status=[string]$record.Status
    config_manager_error_code=[int]$record.ConfigManagerErrorCode
  }
}

function New-GroundSerialPort {
  Assert-Condition ($GroundPort -notin $ForbiddenPorts) `
      'Configured ground port is forbidden.'
  $serial = [IO.Ports.SerialPort]::new($GroundPort,57600,
      [IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
  $serial.DtrEnable = $false
  $serial.RtsEnable = $false
  $serial.Handshake = [IO.Ports.Handshake]::None
  $serial.ReadTimeout = 50
  $serial.WriteTimeout = 5000
  $serial.ReadBufferSize = 1048576
  $serial.WriteBufferSize = 4096
  return $serial
}

function Invoke-ExactRequestWrite([object]$Serial,[byte[]]$Request,
    [scriptblock]$NowUs,[scriptblock]$WaitOneMillisecond,
    [int64]$DrainTimeoutUs = $WriteDrainTimeoutUs,[switch]$Simulation) {
  Assert-Condition ($script:RequestState.request_attempted -eq 0) `
      'PARAM_REQUEST_LIST transmission is one-shot; retry forbidden.'
  Assert-Condition ($script:RequestState.request_writes_completed -eq 0) `
      'PARAM_REQUEST_LIST already completed.'
  Assert-Condition ($Request.Length -eq 14 -and
      (Get-ByteSha $Request) -ceq $exactRequestSha256) `
      'PARAM_REQUEST_LIST bytes are not the frozen fixture.'
  $script:RequestState.request_attempted = 1
  $script:RequestState.request_outcome = 'AMBIGUOUS'
  [int64]$r0 = & $NowUs
  $script:RequestState.request_write_started_us = $r0
  if (-not $Simulation.IsPresent) {
    $script:ExternalActions.serial_write_attempted = $true
    # This flag is conservative: once Write is invoked, a throwing call may
    # already have transferred a prefix to the driver.  No retry is allowed.
    $script:ExternalActions.serial_bytes_written = $true
  }
  try {
    $Serial.Write($Request,0,$Request.Length)
    if (-not $Simulation.IsPresent) {
      $script:ExternalActions.serial_write_call_completed = $true
    }
    $script:RequestState.request_write_call_completed = 1
    [int64]$deadline = $r0 + $DrainTimeoutUs
    while ([int]$Serial.BytesToWrite -ne 0) {
      if (([int64](& $NowUs)) -ge $deadline) {
        throw 'PARAM_REQUEST_LIST transmit drain timeout; state is ambiguous and retry is forbidden.'
      }
      & $WaitOneMillisecond
    }
    [int64]$completeEdge = & $NowUs
    if (-not $Simulation.IsPresent) {
      $script:ExternalActions.serial_bytes_drained = $true
    }
    $script:RequestState.request_writes_completed = 1
    $script:RequestState.request_complete_write_edge_us = $completeEdge
    $script:RequestState.request_outcome = 'COMPLETE'
    return [pscustomobject][ordered]@{
      result='PASS';request_write_started_us=$r0
      request_complete_write_edge_us=$completeEdge
      request_drain_us=$completeEdge - $r0
      request_attempted=1;request_writes_completed=1
      request_sha256=$exactRequestSha256
    }
  } catch {
    $script:RequestState.request_outcome = 'AMBIGUOUS'
    throw
  }
}

function New-LogWriter([string]$Path) {
  $stream = [IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,[IO.FileShare]::Read,65536,
      [IO.FileOptions]::WriteThrough)
  $writer = [IO.StreamWriter]::new($stream,$utf8,65536,$true)
  return [pscustomobject][ordered]@{stream=$stream;writer=$writer}
}

function Write-JsonLine([IO.StreamWriter]$Writer,[object]$Value) {
  $Writer.WriteLine((ConvertTo-Json -InputObject $Value -Depth 12 -Compress))
}

function Sync-LogWriter([object]$Log) {
  if ($null -eq $Log) {return}
  $Log.writer.Flush()
  $Log.stream.Flush($true)
}

function Close-LogWriter([object]$Log) {
  if ($null -eq $Log) {return}
  try {Sync-LogWriter $Log} finally {
    try {$Log.writer.Dispose()} finally {$Log.stream.Dispose()}
  }
}

function Read-AvailableSerial([object]$Serial,[object]$Parser,
    [IO.FileStream]$Raw,[Diagnostics.Stopwatch]$Clock,
    [object]$TimelineLog,[ref]$LastPumpUs,[ref]$MaximumPumpGapUs) {
  [int64]$pumpStartedUs = Get-ElapsedUs $Clock
  if ([int64]$LastPumpUs.Value -ge 0) {
    [int64]$serviceGap = $pumpStartedUs - [int64]$LastPumpUs.Value
    if ($serviceGap -gt [int64]$MaximumPumpGapUs.Value) {
      $MaximumPumpGapUs.Value = $serviceGap
    }
  }
  $LastPumpUs.Value = $pumpStartedUs
  [int]$totalRead = 0
  do {
    [int]$available = [int]$Serial.BytesToRead
    if ($available -le 0) {break}
    [int]$size = [math]::Min(8192,$available)
    [byte[]]$buffer = New-Object byte[] $size
    [int64]$rawOffset = [int64]$Parser.total_bytes
    [int]$read = $Serial.Read($buffer,0,$buffer.Length)
    if ($read -le 0) {break}
    if ($read -ne $buffer.Length) {
      [byte[]]$exact = New-Object byte[] $read
      [Array]::Copy($buffer,$exact,$read)
      $buffer = $exact
    }
    $Raw.Write($buffer,0,$buffer.Length)
    [int64]$arrivalUs = Get-ElapsedUs $Clock
    Add-MavlinkBytes $Parser $buffer $arrivalUs
    $totalRead += $read
    Write-JsonLine $TimelineLog.writer ([ordered]@{
      kind='SERIAL_READ';read_started_us=$pumpStartedUs
      read_complete_us=$arrivalUs;raw_offset=$rawOffset;bytes=$read
      timestamp_basis='host high-frequency pump read-complete/frame-complete'
    })
  } while ([int]$Serial.BytesToRead -gt 0)
  return $totalRead
}

function Write-NewFrameEvents([object]$Parser,[ref]$FrameCursor,
    [object]$FrameLog) {
  while ([int]$FrameCursor.Value -lt $Parser.frames.Count) {
    $record = $Parser.frames[[int]$FrameCursor.Value]
    $FrameCursor.Value = [int]$FrameCursor.Value + 1
    [int]$ordinal = [int]$FrameCursor.Value - 1
    Write-JsonLine $FrameLog.writer ([ordered]@{
      ordinal=$ordinal
      frame_start_us=[int64]$record.frame_start_us
      complete_us=[int64]$record.complete_us
      frame_start_raw_offset=[int64]$record.frame_start_raw_offset
      raw_length=[int]$record.raw_length;raw_sha256=[string]$record.raw_sha256
      valid=[bool]$record.valid;failure=[string]$record.failure
      version=[int]$record.version;signed=[bool]$record.signed
      sequence=[int]$record.sequence;system_id=[int]$record.system_id
      component_id=[int]$record.component_id
      message_id=[int]$record.message_id
      payload_length=[int]$record.payload_length
    })
    Register-R19RuntimeFailFrame $record $ordinal
  }
}

function Get-PrimaryHeartbeatFrames([object]$Parser) {
  return @($Parser.frames | Where-Object {
    $_.valid -and $_.version -eq 2 -and -not $_.signed -and
        $_.message_id -eq 0 -and $_.system_id -eq 1 -and
        $_.component_id -eq 1 -and $_.payload_length -eq 9 -and
        $_.raw_length -eq 21
  })
}

function Get-PreflightEvidenceSnapshot([object]$Serial,[object]$Parser,
    [int64]$NowUs,[int64]$StartedUs,[int64]$LastParamUs,
    [int64]$MaximumPumpGapUs,[bool]$UseMaximumObservedGap,
    [string]$Result,[string]$Failure) {
  $heartbeats = @(Get-PrimaryHeartbeatFrames $Parser)
  $params = @($Parser.frames | Where-Object {$_.message_id -eq 22})
  [Nullable[int64]]$lastPairGapUs = $null
  [Nullable[int64]]$maximumObservedGapUs = $null
  [Nullable[int64]]$maximumGapForAcceptanceUs = $null
  [Nullable[int64]]$lastHeartbeatAgeUs = $null
  if ($heartbeats.Count -gt 0) {
    $lastHeartbeatAgeUs = [int64]($NowUs -
        [int64]$heartbeats[$heartbeats.Count - 1].complete_us)
  }
  if ($heartbeats.Count -ge 2) {
    $lastPairGapUs = [int64](
        [int64]$heartbeats[$heartbeats.Count - 1].complete_us -
        [int64]$heartbeats[$heartbeats.Count - 2].complete_us)
    [int64]$observedMaximum = 0
    for ([int]$heartbeatIndex = 1;
        $heartbeatIndex -lt $heartbeats.Count; ++$heartbeatIndex) {
      [int64]$observedGapUs =
          [int64]$heartbeats[$heartbeatIndex].complete_us -
          [int64]$heartbeats[$heartbeatIndex - 1].complete_us
      if ($observedGapUs -gt $observedMaximum) {
        $observedMaximum = $observedGapUs
      }
    }
    $maximumObservedGapUs = $observedMaximum
    $maximumGapForAcceptanceUs = if ($UseMaximumObservedGap) {
      $observedMaximum
    } else {[int64]$lastPairGapUs}
  }
  [int64]$paramQuietUs = if ($LastParamUs -ge 0) {
    $NowUs - $LastParamUs
  } else {[int64]::MaxValue}
  $parserEvidence = [pscustomobject][ordered]@{
    noise_bytes=[int64]$Parser.noise_bytes
    bad_lengths=[int64]$Parser.bad_length
    bad_crc=[int64]$Parser.bad_crc
    unsupported_flags=[int64]$Parser.unsupported_flags
    unknown_definition=[int64]$Parser.unknown_definition
    partial_bytes=[int]$Parser.buffer.Count
    parser_error_count=([int64]$Parser.noise_bytes +
        [int64]$Parser.bad_length + [int64]$Parser.bad_crc +
        [int64]$Parser.unsupported_flags +
        [int64]$Parser.unknown_definition + [int64]$Parser.buffer.Count)
  }
  return [pscustomobject][ordered]@{
    result=$Result;failure=$Failure
    elapsed_us=[int64]($NowUs - $StartedUs)
    raw_bytes=[int64]$Parser.total_bytes
    frame_count=[int]$Parser.frames.Count
    valid_frames=[int64]$Parser.valid_frames
    primary_heartbeat_count=[int]$heartbeats.Count
    heartbeat_count=[int]$heartbeats.Count
    heartbeat_pair=if ($heartbeats.Count -ge 2) {
      @($heartbeats[$heartbeats.Count - 2],
          $heartbeats[$heartbeats.Count - 1])
    } else {@()}
    last_pair_gap_us=$lastPairGapUs
    observed_maximum_gap_us=$maximumObservedGapUs
    maximum_heartbeat_gap_us=$maximumObservedGapUs
    maximum_gap_us=$maximumGapForAcceptanceUs
    last_heartbeat_age_us=$lastHeartbeatAgeUs
    unsolicited_param_value_count=[int]$params.Count
    pre_request_param_frames=[int]$params.Count
    param_quiet_us=$paramQuietUs
    parser_buffer_empty=($Parser.buffer.Count -eq 0)
    parser_partial_bytes=[int]$parserEvidence.partial_bytes
    parser_error_count=[int64]$parserEvidence.parser_error_count
    parser=$parserEvidence
    os_bytes_to_read=[int]$Serial.BytesToRead
    os_bytes_to_write=[int]$Serial.BytesToWrite
    maximum_pump_service_gap_us=$MaximumPumpGapUs
    pump_service_limit_us=$PumpServiceLimitUs
  }
}

function Wait-PrimaryHeartbeatPreflight([object]$Serial,[object]$Parser,
    [IO.FileStream]$Raw,[Diagnostics.Stopwatch]$Clock,
    [object]$TimelineLog,[object]$FrameLog,[ref]$FrameCursor,
    [ref]$LastPumpUs,[ref]$MaximumPumpGapUs) {
  [int64]$startedUs = Get-ElapsedUs $Clock
  [int64]$deadline = $startedUs + $PreflightTimeoutUs
  [int64]$lastParamUs = -1
  while ((Get-ElapsedUs $Clock) -le $deadline) {
    [void](Read-AvailableSerial $Serial $Parser $Raw $Clock $TimelineLog `
        $LastPumpUs $MaximumPumpGapUs)
    Write-NewFrameEvents $Parser $FrameCursor $FrameLog
    Assert-NoR19RuntimeFailDiagnostic
    $params = @($Parser.frames | Where-Object {$_.message_id -eq 22})
    if ($params.Count -gt 0) {
      $lastParamUs = [int64]$params[$params.Count - 1].complete_us
    }
    [int64]$nowUs = Get-ElapsedUs $Clock
    $observation = Get-PreflightEvidenceSnapshot $Serial $Parser $nowUs `
        $startedUs $lastParamUs ([int64]$MaximumPumpGapUs.Value) `
        $PreflightOnly.IsPresent 'OBSERVING' ''
    if ([int]$observation.primary_heartbeat_count -ge 2 -and
        [int64]$observation.maximum_gap_us -le $HeartbeatLimitUs -and
        [int64]$observation.last_heartbeat_age_us -le $HeartbeatLimitUs -and
        [int]$observation.unsolicited_param_value_count -eq 0 -and
        [int64]$observation.param_quiet_us -ge $PreflightParamQuietUs -and
        [bool]$observation.parser_buffer_empty -and
        [int]$observation.os_bytes_to_read -eq 0 -and
        [int]$observation.os_bytes_to_write -eq 0) {
      $observation.result = 'PASS'
      return $observation
    }
    Start-Sleep -Milliseconds 5
  }
  [int64]$timeoutUs = Get-ElapsedUs $Clock
  return Get-PreflightEvidenceSnapshot $Serial $Parser $timeoutUs $startedUs `
      $lastParamUs ([int64]$MaximumPumpGapUs.Value) `
      $PreflightOnly.IsPresent 'FAIL' `
      'Preflight timeout waiting for two fresh primary 1/1 heartbeats and an idle parser.'
}

function Assert-ReadOnlyPreflightInvariants([object]$Preflight,
    [object]$Serial,[object]$Parser,[int64]$MaximumPumpGapUs) {
  Assert-Condition ($null -ne $Preflight -and
      [string]$Preflight.result -ceq 'PASS') `
      'Read-only preflight did not produce a PASS observation.'
  Assert-Condition ([int]$Preflight.heartbeat_count -ge 2 -and
      [int64]$Preflight.maximum_gap_us -ge 0 -and
      [int64]$Preflight.maximum_gap_us -le $HeartbeatLimitUs -and
      [int64]$Preflight.last_heartbeat_age_us -ge 0 -and
      [int64]$Preflight.last_heartbeat_age_us -le $HeartbeatLimitUs) `
      'Read-only preflight heartbeat evidence is outside the 2.5 s limit.'
  Assert-Condition ([int]$Preflight.pre_request_param_frames -eq 0) `
      'Read-only preflight observed PARAM_VALUE traffic.'
  Assert-Condition ([bool]$Preflight.parser_buffer_empty -and
      $Parser.buffer.Count -eq 0) `
      'Read-only preflight ended with a partial parser frame.'
  Assert-Condition ([int]$Preflight.os_bytes_to_read -eq 0 -and
      [int]$Serial.BytesToRead -eq 0) `
      'Read-only preflight ended with pending OS receive bytes.'
  Assert-Condition ([int]$Serial.BytesToWrite -eq 0) `
      'Read-only preflight found pending OS transmit bytes.'
  Assert-Condition ($MaximumPumpGapUs -ge 0 -and
      $MaximumPumpGapUs -le $PumpServiceLimitUs) `
      "Read-only preflight pump service gap exceeded 100 ms: $MaximumPumpGapUs us."
  Assert-Condition ($script:RequestState.request_attempted -eq 0 -and
      $script:RequestState.request_write_call_completed -eq 0 -and
      $script:RequestState.request_writes_completed -eq 0 -and
      [int64]$script:RequestState.request_write_started_us -eq -1 -and
      [int64]$script:RequestState.request_complete_write_edge_us -eq -1 -and
      [string]$script:RequestState.request_outcome -ceq 'NOT_ATTEMPTED') `
      'Read-only preflight request state is not pristine.'
  Assert-Condition (-not [bool]$script:ExternalActions.serial_write_attempted -and
      -not [bool]$script:ExternalActions.serial_write_call_completed -and
      -not [bool]$script:ExternalActions.serial_bytes_drained -and
      -not [bool]$script:ExternalActions.serial_bytes_written) `
      'Read-only preflight crossed a serial-write boundary.'
  return [pscustomobject][ordered]@{
    result='PASS';read_only_preflight=$true
    serial_write_operation_count=0;serial_bytes_written=0
    request_outcome='NOT_ATTEMPTED';parser_buffer_empty=$true
    os_bytes_to_read=0;os_bytes_to_write=0
    maximum_pump_service_gap_us=$MaximumPumpGapUs
    pump_service_limit_us=$PumpServiceLimitUs
  }
}

function Confirm-FinalRequestBoundary([object]$Serial,[object]$Parser,
    [IO.FileStream]$Raw,[Diagnostics.Stopwatch]$Clock,
    [object]$TimelineLog,[object]$FrameLog,[ref]$FrameCursor,
    [ref]$LastPumpUs,[ref]$MaximumPumpGapUs) {
  # This is the final receive operation before R0.  Nothing that queries CIM,
  # hashes a file, or flushes evidence is allowed between this fence and Write.
  [void](Read-AvailableSerial $Serial $Parser $Raw $Clock $TimelineLog `
      $LastPumpUs $MaximumPumpGapUs)
  Write-NewFrameEvents $Parser $FrameCursor $FrameLog
  Assert-NoR19RuntimeFailDiagnostic
  $params = @($Parser.frames | Where-Object {$_.message_id -eq 22})
  Assert-Condition ($params.Count -eq 0) `
      'Pre-request PARAM_VALUE traffic makes request ownership ambiguous.'
  $heartbeats = @(Get-PrimaryHeartbeatFrames $Parser)
  Assert-Condition ($heartbeats.Count -ge 2) `
      'Final request boundary lacks a primary heartbeat pair.'
  $previous = $heartbeats[$heartbeats.Count - 2]
  $latest = $heartbeats[$heartbeats.Count - 1]
  [int64]$nowUs = Get-ElapsedUs $Clock
  [int64]$gap = [int64]$latest.complete_us - [int64]$previous.complete_us
  [int64]$age = $nowUs - [int64]$latest.complete_us
  Assert-Condition ($gap -ge 0 -and $gap -le $HeartbeatLimitUs -and
      $age -ge 0 -and $age -le $HeartbeatLimitUs) `
      "Final request boundary heartbeat is not fresh: gap=$gap age=$age"
  Assert-Condition ($Parser.buffer.Count -eq 0) `
      'Final request boundary has a partial parser frame.'
  Assert-Condition ([int]$Serial.BytesToRead -eq 0) `
      'Final request boundary has pending OS receive bytes.'
  return [pscustomobject][ordered]@{
    result='PASS';heartbeat_count=$heartbeats.Count
    heartbeat_pair=@($previous,$latest);maximum_gap_us=$gap
    last_heartbeat_age_us=$age;pre_request_param_frames=0
    parser_buffer_empty=$true;os_bytes_to_read=0
    raw_offset=[int64]$Parser.total_bytes;confirmed_us=$nowUs
  }
}

function New-LiveProgressState([object]$Parser) {
  return [pscustomobject][ordered]@{
    frame_cursor=[int]$Parser.frames.Count
    seen=(New-Object bool[] $ExpectedParameters)
    unique=0
    parameter_frames=0
    completion_us=[int64]-1
    last_progress_us=[int64]-1
    frames_processed=0
    idle_update_calls=0
  }
}

function Update-LiveParamProgress([object]$Parser,[object]$Boundary,
    [object]$State,[int64]$NowUs) {
  $before = [int]$State.frame_cursor
  while ([int]$State.frame_cursor -lt $Parser.frames.Count) {
    $record = $Parser.frames[[int]$State.frame_cursor]
    $State.frame_cursor = [int]$State.frame_cursor + 1
    $State.frames_processed = [int]$State.frames_processed + 1
    if ([int64]$record.frame_start_raw_offset -lt [int64]$Boundary.raw_offset -or
        [int64]$record.complete_us -lt
            [int64]$Boundary.request_write_started_us -or
        $record.message_id -ne 22) {continue}
    $State.parameter_frames = [int]$State.parameter_frames + 1
    if (-not $record.valid -or $record.version -ne 2 -or $record.signed -or
        $record.payload_length -ne 25 -or $record.raw_length -ne 37 -or
        $record.system_id -ne 1 -or $record.component_id -ne 1) {continue}
    [byte[]]$raw = $record.raw
    [int]$offset = [int]$record.payload_offset
    [int]$count = [BitConverter]::ToUInt16($raw,$offset + 4)
    [int]$index = [BitConverter]::ToUInt16($raw,$offset + 6)
    if ($count -ne $ExpectedParameters -or $index -lt 0 -or
        $index -ge $ExpectedParameters) {continue}
    if (-not $State.seen[$index]) {
      $State.seen[$index] = $true
      $State.unique = [int]$State.unique + 1
      $State.last_progress_us = $NowUs
    }
    if ([int]$State.unique -eq $ExpectedParameters -and
        $index -eq ($ExpectedParameters - 1) -and
        [int64]$State.completion_us -lt 0) {
      $State.completion_us = [int64]$record.complete_us
    }
  }
  if ([int]$State.frame_cursor -eq $before) {
    $State.idle_update_calls = [int]$State.idle_update_calls + 1
  }
  return $State
}

function Wait-CaptureTailIdle([object]$Serial,[object]$Parser,
    [IO.FileStream]$Raw,[Diagnostics.Stopwatch]$Clock,
    [object]$TimelineLog,[object]$FrameLog,[ref]$FrameCursor,
    [ref]$LastPumpUs,[ref]$MaximumPumpGapUs) {
  [int64]$deadline = (Get-ElapsedUs $Clock) + $HeartbeatLimitUs
  while ((Get-ElapsedUs $Clock) -le $deadline) {
    [void](Read-AvailableSerial $Serial $Parser $Raw $Clock $TimelineLog `
        $LastPumpUs $MaximumPumpGapUs)
    Write-NewFrameEvents $Parser $FrameCursor $FrameLog
    Assert-NoR19RuntimeFailDiagnostic
    if ($Parser.buffer.Count -eq 0 -and [int]$Serial.BytesToRead -eq 0) {
      return Get-ElapsedUs $Clock
    }
    Start-Sleep -Milliseconds 2
  }
  return Get-ElapsedUs $Clock
}

function Write-IndexLedger([object[]]$Records,[string]$Path) {
  $log = New-LogWriter $Path
  try {
    foreach ($record in $Records) {Write-JsonLine $log.writer $record}
  } finally {Close-LogWriter $log}
}

function Invoke-FailClosedCleanupPlan([object[]]$Steps) {
  $errors = [Collections.ArrayList]::new()
  $records = [Collections.ArrayList]::new()
  foreach ($step in $Steps) {
    try {
      [void](& $step.action)
      [void]$records.Add([pscustomobject][ordered]@{
        name=[string]$step.name;result='PASS';failure=''
      })
    } catch {
      [void]$records.Add([pscustomobject][ordered]@{
        name=[string]$step.name;result='FAIL';failure=$_.Exception.Message
      })
      [void]$errors.Add("$([string]$step.name): $($_.Exception.Message)")
    }
  }
  return [pscustomobject][ordered]@{
    result=if ($errors.Count -eq 0) {'PASS'} else {'FAIL'}
    error_count=$errors.Count;errors=@($errors);steps=@($records)
  }
}

function Invoke-R18PixhawkMeasurement {
  $rawPath = Join-Path $evidence 'ground.raw.bin'
  $framePath = Join-Path $evidence 'frame_events.jsonl'
  $timelinePath = Join-Path $evidence 'timeline.jsonl'
  $progressPath = Join-Path $evidence 'progress.jsonl'
  $indexPath = Join-Path $evidence 'param_index_ledger.jsonl'
  $raw = $null
  $frameLog = $null
  $timelineLog = $null
  $progressLog = $null
  $serial = $null
  $clock = [Diagnostics.Stopwatch]::new()
  $parser = New-MavlinkParser 'ground_com6'
  [int]$frameCursorValue = 0
  [int64]$lastPumpValue = -1
  [int64]$maximumPumpGapValue = 0
  [int64]$lastCaptureUs = -1
  $frameCursor = [ref]$frameCursorValue
  $lastPumpUs = [ref]$lastPumpValue
  $maximumPumpGapUs = [ref]$maximumPumpGapValue
  $preflight = $null
  $boundary = $null
  $accounting = $null
  $identityBeforeOpen = $null
  $identityAfterOpen = $null
  $processInventory = $null
  $failure = ''
  try {
    $processInventory = Assert-NoCompetingClients
    $identityBeforeOpen = Assert-ExactGroundIdentity 'before_open'
    $serial = New-GroundSerialPort
    $raw = [IO.FileStream]::new($rawPath,[IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,[IO.FileShare]::Read,65536,
        [IO.FileOptions]::WriteThrough)
    $frameLog = New-LogWriter $framePath
    $timelineLog = New-LogWriter $timelinePath
    $progressLog = New-LogWriter $progressPath
    $clock.Start()
    $serial.Open()
    $script:ExternalActions.com_ports_opened = $true
    Assert-Condition $serial.IsOpen 'Ground COM6 failed to open.'
    $identityAfterOpen = Assert-ExactGroundIdentity 'immediately_after_open'
    Write-JsonLine $timelineLog.writer ([ordered]@{
      kind='SERIAL_OPEN';elapsed_us=Get-ElapsedUs $clock;port=$GroundPort
      baud=57600;data_bits=8;parity='None';stop_bits='One'
      dtr_enable=$false;rts_enable=$false;handshake='None'
      discard_input_api_used=$false
    })
    $preflight = Wait-PrimaryHeartbeatPreflight $serial $parser $raw $clock `
        $timelineLog $frameLog $frameCursor $lastPumpUs $maximumPumpGapUs
    $lastCaptureUs = Get-ElapsedUs $clock
    if ([string]$preflight.result -cne 'PASS') {
      throw ([string]$preflight.failure)
    }
    if ($PreflightOnly.IsPresent) {
      $readOnlyProof = Assert-ReadOnlyPreflightInvariants $preflight $serial `
          $parser ([int64]$maximumPumpGapUs.Value)
      Write-JsonLine $timelineLog.writer ([ordered]@{
        kind='READ_ONLY_PREFLIGHT_COMPLETE';elapsed_us=$lastCaptureUs
        heartbeat_count=[int]$preflight.heartbeat_count
        maximum_heartbeat_gap_us=[int64]$preflight.maximum_gap_us
        last_heartbeat_age_us=[int64]$preflight.last_heartbeat_age_us
        parser_buffer_empty=$true;os_bytes_to_read=0;os_bytes_to_write=0
        request_attempted=0;serial_write_operation_count=0
      })
      $script:LastMeasurement = [pscustomobject][ordered]@{
        result='PASS';failure='';read_only_preflight=$true
        identity_before_open=$identityBeforeOpen
        identity_immediately_after_open=$identityAfterOpen
        process_inventory=@($processInventory)
        serial_configuration=[pscustomobject][ordered]@{
          port='COM6';baud=57600;data_bits=8;parity='None';stop_bits='One'
          dtr_enable=$false;rts_enable=$false;handshake='None'
        }
        preflight=$preflight;read_only_proof=$readOnlyProof
        request=$script:RequestState;capture_end_us=$lastCaptureUs
        runtime_failure_diagnostics=Get-R19RuntimeFailDiagnosticSummary
        timestamp_basis=('Stopwatch frame-complete timestamps from a high-' +
            'frequency pump; <=100 ms pump service gap is a hard timing gate.')
      }
      return $script:LastMeasurement
    }
    Assert-Condition ($parser.buffer.Count -eq 0 -and
        [int]$serial.BytesToRead -eq 0) `
        'Request boundary requires empty parser and OS receive queue.'
    Assert-Condition ([int]$preflight.pre_request_param_frames -eq 0) `
        'Pre-request PARAM_VALUE traffic makes request ownership ambiguous.'
    [byte[]]$request = New-ExactParamRequestList
    $nowUs = {Get-ElapsedUs $clock}
    $waitOne = {Start-Sleep -Milliseconds 1}
    $finalBoundary = Confirm-FinalRequestBoundary $serial $parser $raw $clock `
        $timelineLog $frameLog $frameCursor $lastPumpUs $maximumPumpGapUs
    $lastCaptureUs = Get-ElapsedUs $clock
    $preflight = $finalBoundary
    $baseline = Get-ParserSnapshot $parser
    [int64]$rawBoundary = [int64]$finalBoundary.raw_offset
    # Keep this adjacency: the irreversible R0 latch occurs inside the next
    # function immediately before the sole Serial.Write call.
    $writeResult = Invoke-ExactRequestWrite $serial $request $nowUs $waitOne
    $boundary = [pscustomobject][ordered]@{
      request_write_started_us=[int64]$writeResult.request_write_started_us
      request_complete_write_edge_us=
          [int64]$writeResult.request_complete_write_edge_us
      request_outcome='COMPLETE';raw_offset=$rawBoundary
      parser_baseline=$baseline
    }
    $progress = New-LiveProgressState $parser
    $progress.last_progress_us = [int64]$boundary.request_write_started_us
    [int64]$nextDurableFlushUs =
        [int64]$boundary.request_write_started_us + 30000000
    Write-JsonLine $timelineLog.writer ([ordered]@{
      kind='PARAM_REQUEST_LIST';request_attempted=1;request_writes_completed=1
      request_write_started_us=[int64]$boundary.request_write_started_us
      request_complete_write_edge_us=
          [int64]$boundary.request_complete_write_edge_us
      request_drain_us=[int64]$writeResult.request_drain_us
      bytes=14;sha256=$exactRequestSha256;raw_boundary_offset=$rawBoundary
      acceptance_epoch='request_write_started_us'
    })
    [int64]$completionUs = -1
    while ($true) {
      [int64]$now = Get-ElapsedUs $clock
      if ($now - [int64]$boundary.request_write_started_us -gt
          $OverallTimeoutUs) {
        throw 'PARAM_LIST overall timeout (7200 s).'
      }
      [void](Read-AvailableSerial $serial $parser $raw $clock $timelineLog `
          $lastPumpUs $maximumPumpGapUs)
      $lastCaptureUs = Get-ElapsedUs $clock
      Write-NewFrameEvents $parser $frameCursor $frameLog
      Assert-NoR19RuntimeFailDiagnostic
      [void](Update-LiveParamProgress $parser $boundary $progress `
          (Get-ElapsedUs $clock))
      if ($completionUs -lt 0 -and [int64]$progress.completion_us -ge 0) {
        $completionUs = [int64]$progress.completion_us
        Write-JsonLine $timelineLog.writer ([ordered]@{
          kind='INDEX_931_COMPLETE';elapsed_us=$completionUs
          unique=[int]$progress.unique;duplicate_guard_us=$DuplicateGuardUs
        })
      }
      $now = Get-ElapsedUs $clock
      if ($R19SharedMode.IsPresent) {
        $r19DeadlineFailure = Get-R19CompletionDeadlineFailure $now `
            ([int64]$boundary.request_write_started_us) $completionUs
        if (-not [string]::IsNullOrEmpty($r19DeadlineFailure)) {
          throw $r19DeadlineFailure
        }
      }
      if ($now -ge $nextDurableFlushUs) {
        [int64]$flushStartedUs = $now
        Write-JsonLine $progressLog.writer ([ordered]@{
          elapsed_us=$flushStartedUs;unique=[int]$progress.unique
          parameter_frames=[int]$progress.parameter_frames
          frames_processed=[int]$progress.frames_processed
          frame_cursor=[int]$progress.frame_cursor
        })
        $raw.Flush($true)
        Sync-LogWriter $frameLog
        Sync-LogWriter $timelineLog
        Sync-LogWriter $progressLog
        [int64]$flushFinishedUs = Get-ElapsedUs $clock
        [int64]$flushDurationUs = $flushFinishedUs - $flushStartedUs
        if ($flushDurationUs -gt [int64]$maximumPumpGapUs.Value) {
          $maximumPumpGapUs.Value = $flushDurationUs
        }
        Write-JsonLine $timelineLog.writer ([ordered]@{
          kind='PERIODIC_DURABLE_FLUSH';started_us=$flushStartedUs
          finished_us=$flushFinishedUs;duration_us=$flushDurationUs
          interval_limit_us=30000000
        })
        while ($nextDurableFlushUs -le $flushFinishedUs) {
          $nextDurableFlushUs += 30000000
        }
        $now = $flushFinishedUs
      }
      if ($completionUs -ge 0 -and $now -ge
          ($completionUs + $DuplicateGuardUs)) {break}
      if ($completionUs -lt 0 -and $now -
          [int64]$progress.last_progress_us -gt
          $StallTimeoutUs) {
        throw 'PARAM_LIST stall timeout (120 s without a new unique index).'
      }
      Start-Sleep -Milliseconds 5
    }
    [int64]$captureEndUs = Wait-CaptureTailIdle $serial $parser $raw $clock `
        $timelineLog $frameLog $frameCursor $lastPumpUs $maximumPumpGapUs
    $lastCaptureUs = $captureEndUs
    $accounting = Get-StrictParamAccounting $parser $boundary `
        @($preflight.heartbeat_pair) $captureEndUs `
        ([int64]$maximumPumpGapUs.Value)
    Write-IndexLedger @($accounting.index_ledger) $indexPath
    $script:LastMeasurement = [pscustomobject][ordered]@{
      result=[string]$accounting.result;failure=''
      identity_before_open=$identityBeforeOpen
      identity_immediately_after_open=$identityAfterOpen
      process_inventory=@($processInventory)
      serial_configuration=[pscustomobject][ordered]@{
        port='COM6';baud=57600;data_bits=8;parity='None';stop_bits='One'
        dtr_enable=$false;rts_enable=$false;handshake='None'
      }
      preflight=$preflight;request=$script:RequestState
      measurement_boundary=$boundary;capture_end_us=$captureEndUs
      live_progress=[pscustomobject][ordered]@{
        frames_processed=[int]$progress.frames_processed
        final_frame_cursor=[int]$progress.frame_cursor
        unique=[int]$progress.unique
        parameter_frames=[int]$progress.parameter_frames
        idle_update_calls=[int]$progress.idle_update_calls
        algorithm='incremental_O_new_frames'
      }
      accounting=$accounting
      runtime_failure_diagnostics=Get-R19RuntimeFailDiagnosticSummary
      timestamp_basis=('Stopwatch frame-complete timestamps from a high-' +
          'frequency pump; <=100 ms pump service gap is a hard timing gate.')
    }
    Assert-Condition ($accounting.result -ceq 'PASS') `
        'R18 Pixhawk PARAM_LIST acceptance failed.'
    return $script:LastMeasurement
  } catch {
    $failure = $_.Exception.Message
    if ($null -ne $boundary -and $null -eq $accounting) {
      try {
        [int64]$captureEndUs = if ($lastCaptureUs -ge 0) {
          $lastCaptureUs
        } else {[int64]$boundary.request_write_started_us}
        $accounting = Get-StrictParamAccounting $parser $boundary `
            $(if ($null -ne $preflight) {@($preflight.heartbeat_pair)} else {@()}) `
            $captureEndUs ([int64]$maximumPumpGapUs.Value)
        if (-not (Test-Path -LiteralPath $indexPath)) {
          Write-IndexLedger @($accounting.index_ledger) $indexPath
        }
      } catch {}
    }
    if ($null -eq $script:LastMeasurement) {
      $script:LastMeasurement = [pscustomobject][ordered]@{
        result='FAIL';failure=$failure
        identity_before_open=$identityBeforeOpen
        identity_immediately_after_open=$identityAfterOpen
        process_inventory=@($processInventory);preflight=$preflight
        request=$script:RequestState;measurement_boundary=$boundary
        accounting=$accounting;last_actual_capture_us=$lastCaptureUs
      }
    } else {
      $script:LastMeasurement.result = 'FAIL'
      $script:LastMeasurement.failure = $failure
    }
    $script:LastMeasurement | Add-Member NoteProperty `
        runtime_failure_diagnostics `
        (Get-R19RuntimeFailDiagnosticSummary) -Force
    throw
  } finally {
    $cleanupPlan = @(
      [pscustomobject]@{name='frame_ledger_final_append';action={
        if ($null -ne $parser -and $null -ne $frameLog) {
          Write-NewFrameEvents $parser $frameCursor $frameLog
        }
      }},
      [pscustomobject]@{name='serial_close';action={
        if ($null -ne $serial -and $serial.IsOpen) {$serial.Close()}
        if ($null -ne $serial -and $serial.IsOpen) {
          throw 'COM6 remained open after Close().'
        }
      }},
      [pscustomobject]@{name='serial_dispose';action={
        if ($null -ne $serial) {$serial.Dispose()}
      }},
      [pscustomobject]@{name='raw_fsync';action={
        if ($null -ne $raw) {$raw.Flush($true)}
      }},
      [pscustomobject]@{name='timeline_fsync_close';action={
        if ($null -ne $timelineLog) {Close-LogWriter $timelineLog}
      }},
      [pscustomobject]@{name='frame_fsync_close';action={
        if ($null -ne $frameLog) {Close-LogWriter $frameLog}
      }},
      [pscustomobject]@{name='progress_fsync_close';action={
        if ($null -ne $progressLog) {Close-LogWriter $progressLog}
      }},
      [pscustomobject]@{name='raw_dispose';action={
        if ($null -ne $raw) {$raw.Dispose()}
      }}
    )
    $cleanup = Invoke-FailClosedCleanupPlan $cleanupPlan
    $clock.Stop()
    $script:CleanupResult = [pscustomobject][ordered]@{
      result=[string]$cleanup.result
      error_count=[int]$cleanup.error_count;errors=@($cleanup.errors)
      steps=@($cleanup.steps);serial_is_open_after_cleanup=if ($null -ne $serial) {
        try {[bool]$serial.IsOpen} catch {$false}
      } else {$false}
    }
    if ($null -ne $script:LastMeasurement) {
      $script:LastMeasurement | Add-Member NoteProperty cleanup `
          $script:CleanupResult -Force
      if ([string]$cleanup.result -cne 'PASS') {
        $script:LastMeasurement.result = 'FAIL'
        $script:LastMeasurement.failure =
            (($script:LastMeasurement.failure + ' | cleanup: ' +
             (@($cleanup.errors) -join ' | ')).Trim(' ','|'))
      }
    }
    if ([string]$cleanup.result -cne 'PASS') {
      throw ('Measurement cleanup/durability failure: ' +
          (@($cleanup.errors) -join ' | '))
    }
  }
}

function New-SyntheticHeartbeatFrame([byte]$Sequence) {
  [byte[]]$frame = New-Object byte[] 21
  $frame[0] = 0xFD
  $frame[1] = 9
  $frame[4] = $Sequence
  $frame[5] = 1
  $frame[6] = 1
  $frame[14] = 11
  $frame[15] = 3
  $frame[16] = 0
  $frame[17] = 3
  $frame[18] = 3
  [uint16]$crc = 0xFFFF
  for ($index = 1; $index -lt 19; ++$index) {
    $crc = Update-X25Crc $crc $frame[$index]
  }
  $crc = Update-X25Crc $crc 50
  $frame[19] = [byte]($crc -band 0xFF)
  $frame[20] = [byte](($crc -shr 8) -band 0xFF)
  return $frame
}

function New-SyntheticR19RuntimeFailFrame([byte]$Sequence,
    [string]$Text =
      'R19F:G:01D2:00000000000004D2:010203040586:00000007',
    [byte]$SystemId = 254,[byte]$ComponentId = 190,
    [switch]$CorruptCrc) {
  [byte[]]$textBytes = [Text.Encoding]::ASCII.GetBytes($Text)
  Assert-Condition ($textBytes.Length -eq 50) `
      'Synthetic R19F text must be exactly 50 ASCII bytes.'
  [byte[]]$frame = New-Object byte[] 63
  $frame[0] = 0xFD;$frame[1] = 51;$frame[4] = $Sequence
  $frame[5] = $SystemId;$frame[6] = $ComponentId
  $frame[7] = 253;$frame[8] = 0;$frame[9] = 0
  $frame[10] = 2
  [Array]::Copy($textBytes,0,$frame,11,50)
  [uint16]$crc = 0xFFFF
  for ($offset = 1; $offset -lt 61; ++$offset) {
    $crc = Update-X25Crc $crc $frame[$offset]
  }
  $crc = Update-X25Crc $crc 83
  $frame[61] = [byte]($crc -band 0xFF)
  $frame[62] = [byte](($crc -shr 8) -band 0xFF)
  if ($CorruptCrc.IsPresent) {$frame[62] = $frame[62] -bxor 1}
  return $frame
}

function New-SyntheticR19DiagnosticProvenance([switch]$SourceHashMismatch) {
  $groundSource = 'A' * 64
  $vehicleSource = 'B' * 64
  return [pscustomobject][ordered]@{
    candidate=[pscustomobject][ordered]@{
      roles=@(
        [pscustomobject][ordered]@{role='vehicle';sha256=('C' * 64)},
        [pscustomobject][ordered]@{role='ground';sha256=('D' * 64)}
      )
      source_bindings=@(
        [pscustomobject][ordered]@{
          role='vehicle'
          source_path=('package/vc_lora_vehicle_xiao_esp32s3/' +
              'vc_lora_phase6_bridge.hpp')
          source_sha256=$vehicleSource
          verified_source_sha256=$vehicleSource;source_verified=$true
          application_sha256=('C' * 64)
        },
        [pscustomobject][ordered]@{
          role='ground'
          source_path=('package/vc_lora_ground_xiao_esp32s3/' +
              'vc_lora_phase6_bridge.hpp')
          source_sha256=$groundSource
          verified_source_sha256=if ($SourceHashMismatch.IsPresent) {
            'E' * 64
          } else {$groundSource}
          source_verified=$true;application_sha256=('D' * 64)
        }
      )
    }
  }
}

function New-SyntheticParamValueFrame([int]$Index,[byte]$Sequence) {
  [byte[]]$frame = New-Object byte[] 37
  $frame[0] = 0xFD
  $frame[1] = 25
  $frame[4] = $Sequence
  $frame[5] = 1
  $frame[6] = 1
  $frame[7] = 22
  $payload = 10
  [byte[]]$countBytes = [BitConverter]::GetBytes([uint16]$ExpectedParameters)
  [byte[]]$indexBytes = [BitConverter]::GetBytes([uint16]$Index)
  [Array]::Copy($countBytes,0,$frame,$payload + 4,2)
  [Array]::Copy($indexBytes,0,$frame,$payload + 6,2)
  $id = $utf8.GetBytes(('P{0:D6}' -f $Index))
  [Array]::Copy($id,0,$frame,$payload + 8,$id.Length)
  $frame[$payload + 24] = 9
  [uint16]$crc = 0xFFFF
  for ($offset = 1; $offset -lt 35; ++$offset) {
    $crc = Update-X25Crc $crc $frame[$offset]
  }
  $crc = Update-X25Crc $crc 220
  $frame[35] = [byte]($crc -band 0xFF)
  $frame[36] = [byte](($crc -shr 8) -band 0xFF)
  return $frame
}

function New-OfflineBoundary([object]$Parser,[int64]$R0) {
  return [pscustomobject][ordered]@{
    request_write_started_us=$R0
    request_complete_write_edge_us=$R0 + 3000
    request_outcome='COMPLETE'
    raw_offset=[int64]0
    parser_baseline=[pscustomobject][ordered]@{
      total_bytes=[int64]0;noise_bytes=[int64]0;bad_lengths=[int64]0
      bad_crc=[int64]0;unsupported_flags=[int64]0
      unknown_definition=[int64]0;partial_bytes=0;frame_count=0
    }
  }
}

function New-SyntheticScenario([int64]$LastParamOffsetUs,
    [int]$SkipIndex = -1,[int]$DuplicateIndex = -1,
    [switch]$SwapOneAndTwo,[switch]$HeartbeatGap,[switch]$CorruptCrc,
    [switch]$PartialTail) {
  [int64]$r0 = 10000000
  $parser = New-MavlinkParser 'offline_synthetic' $false
  $boundary = New-OfflineBoundary $parser $r0
  $order = [Collections.Generic.List[int]]::new()
  for ($index = 0; $index -lt $ExpectedParameters; ++$index) {
    if ($index -ne $SkipIndex) {$order.Add($index)}
  }
  if ($SwapOneAndTwo.IsPresent) {
    $temporary = $order[1];$order[1] = $order[2];$order[2] = $temporary
  }
  [byte]$sequence = 0
  for ($ordinal = 0; $ordinal -lt $order.Count; ++$ordinal) {
    [int]$paramIndex = $order[$ordinal]
    [byte[]]$frame = New-SyntheticParamValueFrame $paramIndex $sequence
    $sequence = [byte](($sequence + 1) -band 0xFF)
    if ($CorruptCrc.IsPresent -and $paramIndex -eq 400) {
      $frame[36] = $frame[36] -bxor 0x01
    }
    [int64]$time = $r0 + [int64][math]::Floor(
        ([double]$LastParamOffsetUs * ($paramIndex + 1)) /
        [double]$ExpectedParameters)
    if ($time -le $r0) {$time = $r0 + 1}
    Add-MavlinkBytes $parser $frame $time
    if ($paramIndex -eq $DuplicateIndex) {
      [byte[]]$duplicate = New-SyntheticParamValueFrame $paramIndex $sequence
      $sequence = [byte](($sequence + 1) -band 0xFF)
      Add-MavlinkBytes $parser $duplicate ($time + 1)
    }
  }
  [int64]$plannedLast = $r0 + $LastParamOffsetUs
  [int64]$captureEnd = $plannedLast + $DuplicateGuardUs
  [int]$heartbeatOrdinal = 1
  for ([int64]$time = $r0 + 1000000; $time -le $captureEnd;
      $time += 1000000) {
    if ($HeartbeatGap.IsPresent -and $time -gt ($r0 + 2000000) -and
        $time -lt ($r0 + 6000000)) {continue}
    Add-MavlinkBytes $parser `
        (New-SyntheticHeartbeatFrame ([byte]($heartbeatOrdinal -band 0xFF))) `
        $time
    ++$heartbeatOrdinal
  }
  if ($PartialTail.IsPresent) {
    Add-MavlinkBytes $parser ([byte[]]@(0xFD,0x19)) $captureEnd
  }
  $pre = @(
    [pscustomobject]@{complete_us=$r0 - 2000000},
    [pscustomobject]@{complete_us=$r0 - 1000000}
  )
  $accounting = Get-StrictParamAccounting $parser $boundary $pre `
      $captureEnd 5000
  return [pscustomobject][ordered]@{
    parser=$parser;boundary=$boundary;capture_end_us=$captureEnd
    pre_heartbeats=$pre;accounting=$accounting
  }
}

function Copy-SyntheticParser([object]$Source) {
  $copy = New-MavlinkParser ([string]$Source.name + '_copy') $false
  foreach ($property in @('expected_size','frame_start_us',
      'frame_start_raw_offset','total_bytes','noise_bytes','bad_length',
      'bad_crc','unsupported_flags','unknown_definition','valid_frames')) {
    $copy.$property = $Source.$property
  }
  foreach ($value in $Source.buffer) {$copy.buffer.Add([byte]$value)}
  foreach ($frame in $Source.frames) {[void]$copy.frames.Add($frame)}
  return $copy
}

function Copy-FrameRecord([object]$Record) {
  return [pscustomobject][ordered]@{
    frame_start_us=[int64]$Record.frame_start_us
    complete_us=[int64]$Record.complete_us
    frame_start_raw_offset=[int64]$Record.frame_start_raw_offset
    valid=[bool]$Record.valid;failure=[string]$Record.failure
    version=[int]$Record.version;sequence=[int]$Record.sequence
    system_id=[int]$Record.system_id;component_id=[int]$Record.component_id
    message_id=[int]$Record.message_id
    payload_length=[int]$Record.payload_length
    payload_offset=[int]$Record.payload_offset;signed=[bool]$Record.signed
    raw=[byte[]]$Record.raw.Clone();raw_length=[int]$Record.raw_length
    raw_sha256=[string]$Record.raw_sha256
  }
}

function Get-RecordParamIndex([object]$Record) {
  if ($Record.message_id -ne 22 -or $Record.raw_length -lt 18) {return -1}
  return [int][BitConverter]::ToUInt16(
      [byte[]]$Record.raw,[int]$Record.payload_offset + 6)
}

function New-DerivedSyntheticScenario([object]$Base,[string]$Mutation) {
  $parser = Copy-SyntheticParser $Base.parser
  [int64]$captureEnd = [int64]$Base.capture_end_us
  switch ($Mutation) {
    'over30' {
      for ($position = 0; $position -lt $parser.frames.Count; ++$position) {
        if ((Get-RecordParamIndex $parser.frames[$position]) -eq 931) {
          $changed = Copy-FrameRecord $parser.frames[$position]
          $changed.frame_start_us = [int64]$changed.frame_start_us + 1
          $changed.complete_us = [int64]$changed.complete_us + 1
          $parser.frames[$position] = $changed
          ++$captureEnd
          break
        }
      }
    }
    'missing931' {
      for ($position = 0; $position -lt $parser.frames.Count; ++$position) {
        if ((Get-RecordParamIndex $parser.frames[$position]) -eq 931) {
          $parser.frames.RemoveAt($position)
          $parser.valid_frames = [int64]$parser.valid_frames - 1
          break
        }
      }
    }
    'duplicate247' {
      for ($position = 0; $position -lt $parser.frames.Count; ++$position) {
        if ((Get-RecordParamIndex $parser.frames[$position]) -eq 247) {
          $changed = Copy-FrameRecord $parser.frames[$position]
          $changed.frame_start_us = [int64]$changed.frame_start_us + 1
          $changed.complete_us = [int64]$changed.complete_us + 1
          $parser.frames.Insert($position + 1,$changed)
          $parser.valid_frames = [int64]$parser.valid_frames + 1
          break
        }
      }
    }
    'swap1and2' {
      $first = -1;$second = -1
      for ($position = 0; $position -lt $parser.frames.Count; ++$position) {
        $index = Get-RecordParamIndex $parser.frames[$position]
        if ($index -eq 1) {$first = $position}
        if ($index -eq 2) {$second = $position;break}
      }
      $temporary = $parser.frames[$first]
      $parser.frames[$first] = $parser.frames[$second]
      $parser.frames[$second] = $temporary
    }
    'heartbeat_gap' {
      [int64]$r0 = [int64]$Base.boundary.request_write_started_us
      for ($position = $parser.frames.Count - 1; $position -ge 0; --$position) {
        $frame = $parser.frames[$position]
        if ($frame.message_id -eq 0 -and $frame.complete_us -gt ($r0 + 2000000) -and
            $frame.complete_us -lt ($r0 + 6000000)) {
          $parser.frames.RemoveAt($position)
          $parser.valid_frames = [int64]$parser.valid_frames - 1
        }
      }
    }
    'crc400' {
      for ($position = 0; $position -lt $parser.frames.Count; ++$position) {
        if ((Get-RecordParamIndex $parser.frames[$position]) -eq 400) {
          [byte[]]$bad = ([byte[]]$parser.frames[$position].raw).Clone()
          $bad[36] = $bad[36] -bxor 1
          $probe = New-MavlinkParser 'crc_probe' $false
          Add-MavlinkBytes $probe $bad ([int64]$parser.frames[$position].complete_us)
          Assert-Condition ($probe.frames.Count -eq 1 -and
              $probe.frames[0].failure -ceq 'bad_crc') `
              'Synthetic CRC mutation did not exercise the real parser.'
          $parser.frames[$position] = $probe.frames[0]
          $parser.valid_frames = [int64]$parser.valid_frames - 1
          $parser.bad_crc = [int64]$parser.bad_crc + 1
          break
        }
      }
    }
    'partial_tail' {
      Add-MavlinkBytes $parser ([byte[]]@(0xFD,0x19)) $captureEnd
    }
    default {throw "Unknown synthetic mutation: $Mutation"}
  }
  $accounting = Get-StrictParamAccounting $parser $Base.boundary `
      @($Base.pre_heartbeats) $captureEnd 5000
  return [pscustomobject][ordered]@{
    parser=$parser;boundary=$Base.boundary;capture_end_us=$captureEnd
    pre_heartbeats=@($Base.pre_heartbeats);accounting=$accounting
  }
}

function New-FakeSerial([switch]$NeverDrains,[switch]$ThrowOnWrite) {
  $baseStream = [pscustomobject][ordered]@{flush_count=0}
  $baseStream | Add-Member ScriptMethod Flush {
    $this.flush_count = [int]$this.flush_count + 1
  }
  $serial = [pscustomobject][ordered]@{
    BytesToRead=0;BytesToWrite=0;BaseStream=$baseStream
    write_calls=0;written=[Collections.Generic.List[byte]]::new()
    never_drains=$NeverDrains.IsPresent;throw_on_write=$ThrowOnWrite.IsPresent
  }
  $serial | Add-Member ScriptMethod Write {
    param([byte[]]$Buffer,[int]$Offset,[int]$Count)
    $this.write_calls = [int]$this.write_calls + 1
    if ([bool]$this.throw_on_write) {throw 'synthetic write failure'}
    for ($index = 0; $index -lt $Count; ++$index) {
      $this.written.Add($Buffer[$Offset + $index])
    }
    $this.BytesToWrite = if ([bool]$this.never_drains) {1} else {0}
  }
  return $serial
}

function Reset-OfflineRequestState {
  $script:RequestState.request_attempted = 0
  $script:RequestState.request_write_started_us = [int64]-1
  $script:RequestState.request_write_call_completed = 0
  $script:RequestState.request_writes_completed = 0
  $script:RequestState.request_complete_write_edge_us = [int64]-1
  $script:RequestState.request_outcome = 'NOT_ATTEMPTED'
}

function Get-DeadlineFailure([int64]$NowUs,[int64]$R0,
    [int64]$LastProgressUs,[bool]$Completed) {
  if ($NowUs - $R0 -gt $OverallTimeoutUs) {return 'overall_timeout'}
  if (-not $Completed -and $NowUs - $LastProgressUs -gt $StallTimeoutUs) {
    return 'stall_timeout'
  }
  return ''
}

function Get-R19CompletionDeadlineFailure([int64]$NowUs,[int64]$R0,
    [int64]$CompletionUs) {
  if ($CompletionUs -ge 0) {
    if ($CompletionUs - $R0 -gt $Target30LimitUs) {
      return 'R19 completion deadline exceeded: 30000000 us'
    }
    return ''
  }
  if ($NowUs - $R0 -gt $Target30LimitUs) {
    return 'R19 completion deadline exceeded: 30000000 us'
  }
  return ''
}

function Invoke-OfflineCleanupFaultProbe {
  $fake = [pscustomobject][ordered]@{}
  $fake | Add-Member ScriptMethod Flush {throw 'synthetic Flush failure'}
  $fake | Add-Member ScriptMethod Close {throw 'synthetic Close failure'}
  $fake | Add-Member ScriptMethod Dispose {throw 'synthetic Dispose failure'}
  return Invoke-FailClosedCleanupPlan @(
    [pscustomobject]@{name='fake_flush';action={$fake.Flush()}},
    [pscustomobject]@{name='fake_close';action={$fake.Close()}},
    [pscustomobject]@{name='fake_dispose';action={$fake.Dispose()}}
  )
}

function Apply-RunnerIntegrityGate([object]$Summary,[bool]$Stable,
    [string]$StartSha,[string]$EndSha) {
  if (-not $Stable) {
    $Summary.result = 'FAIL'
    if ($Summary.PSObject.Properties['failure']) {
      $Summary.failure = ([string]$Summary.failure +
          ' | runner source integrity changed during execution').Trim(' ','|')
    } else {
      $Summary | Add-Member NoteProperty failure `
          'runner source integrity changed during execution'
    }
  }
  $integrity = [pscustomobject][ordered]@{
    result=if ($Stable) {'PASS'} else {'FAIL'}
    start_sha256=$StartSha;end_sha256=$EndSha
  }
  if ($Summary.PSObject.Properties['runner_integrity']) {
    $Summary.runner_integrity = $integrity
  } else {
    $Summary | Add-Member NoteProperty runner_integrity $integrity
  }
  return $Summary
}

function Invoke-OfflineSelfTest {
  $tests = [Collections.ArrayList]::new()
  function Add-Test([string]$Name,[bool]$Passed,[string]$Detail) {
    [void]$tests.Add([pscustomobject][ordered]@{
      name=$Name;result=if ($Passed) {'PASS'} else {'FAIL'};detail=$Detail
    })
  }

  [byte[]]$request = New-ExactParamRequestList
  Add-Test 'exact_request_fixture' ($request.Length -eq 14 -and
      (Get-ByteSha $request) -ceq $exactRequestSha256) `
      '14-byte fixture and SHA-256 pin'

  $diagnosticProvenance = New-SyntheticR19DiagnosticProvenance
  $diagnosticParser = New-MavlinkParser 'r19f_valid' $true
  Add-MavlinkBytes $diagnosticParser `
      (New-SyntheticR19RuntimeFailFrame 42) 1234567
  $validDiagnostic = Get-R19RuntimeFailDiagnosticRecord `
      $diagnosticParser.frames[0] 0 $diagnosticProvenance
  $rawEvidenceWritten = $true
  if ($R19SharedMode.IsPresent) {
    $savedProvenance = $script:R19Provenance
    try {
      $script:R19Provenance = $diagnosticProvenance
      Register-R19RuntimeFailFrame $diagnosticParser.frames[0] 190000
      $registered = @($script:R19RuntimeFailDiagnostics | Where-Object {
        [int]$_.ordinal -eq 190000
      })
      $rawEvidenceWritten = $registered.Count -eq 1 -and
          (Test-Path -LiteralPath (Join-Path $evidence `
            'runtime_fail_diagnostics\frame-190000.bin') -PathType Leaf) -and
          (Get-Sha (Join-Path $evidence `
            'runtime_fail_diagnostics\frame-190000.bin')) -ceq
            [string]$registered[0].raw_frame.sha256
    } finally {
      $script:R19Provenance = $savedProvenance
      $script:R19RuntimeFailDiagnostics.Clear()
      $script:R19RuntimeFailOrdinals.Clear()
    }
  }
  Add-Test 'r19f_valid_frame_decodes_and_forces_acceptance_fail' (
      [bool]$validDiagnostic.diagnostic_success -and
      [string]$validDiagnostic.role -ceq 'ground' -and
      [int]$validDiagnostic.source_line -eq 0x01D2 -and
      [string]$validDiagnostic.monotonic_ms_decimal -ceq '1234' -and
      [int]$validDiagnostic.status.startup_fault -eq 1 -and
      [int]$validDiagnostic.status.e220_state -eq 2 -and
      [int]$validDiagnostic.status.e220_fault -eq 3 -and
      [int]$validDiagnostic.status.writer_status -eq 4 -and
      [int]$validDiagnostic.status.radio_session_status -eq 5 -and
      [bool]$validDiagnostic.status.adapter_fail_closed -and
      [int]$validDiagnostic.status.tdd_state -eq 6 -and
      [int64]$validDiagnostic.usb_loss_epoch -eq 7 -and
      [bool]$validDiagnostic.source_mapping_verified -and
      [string]$validDiagnostic.source_sha256 -cmatch '^[0-9A-F]{64}$' -and
      [string]$validDiagnostic.raw_frame.sha256 -cmatch '^[0-9A-F]{64}$' -and
      $rawEvidenceWritten -and
      (Get-R19RuntimeFailAcceptanceResult @($validDiagnostic)) -ceq
        'FAIL_RUNTIME_DIAGNOSTIC_OBSERVED') `
      'valid R19F evidence is decoded, source-bound, persisted, and never accepted'

  $badCrcParser = New-MavlinkParser 'r19f_bad_crc' $true
  Add-MavlinkBytes $badCrcParser `
      (New-SyntheticR19RuntimeFailFrame 43 -CorruptCrc) 1234568
  $badCrcDiagnostic = Get-R19RuntimeFailDiagnosticRecord `
      $badCrcParser.frames[0] 0 $diagnosticProvenance
  Add-Test 'r19f_bad_crc_is_not_diagnostic_success' (
      [bool]$badCrcDiagnostic.candidate -and
      -not [bool]$badCrcDiagnostic.diagnostic_success -and
      [string]$badCrcDiagnostic.failure -match 'mavlink_bad_crc' -and
      (Get-R19RuntimeFailAcceptanceResult @($badCrcDiagnostic)) -ceq
        'FAIL_INVALID_RUNTIME_DIAGNOSTIC') `
      'R19F with an invalid MAVLink CRC is evidence of failure, never success'

  $canonicalText =
      'R19F:G:01D2:00000000000004D2:010203040586:00000007'
  $badFormatText = $canonicalText.Remove(6,1).Insert(6,';')
  $badFormatParser = New-MavlinkParser 'r19f_bad_format' $true
  Add-MavlinkBytes $badFormatParser `
      (New-SyntheticR19RuntimeFailFrame 44 $badFormatText) 1234569
  $badFormatDiagnostic = Get-R19RuntimeFailDiagnosticRecord `
      $badFormatParser.frames[0] 0 $diagnosticProvenance
  Add-Test 'r19f_bad_format_is_not_diagnostic_success' (
      [bool]$badFormatDiagnostic.candidate -and
      -not [bool]$badFormatDiagnostic.diagnostic_success -and
      [string]$badFormatDiagnostic.failure -match 'text_format_mismatch' -and
      (Get-R19RuntimeFailAcceptanceResult @($badFormatDiagnostic)) -ceq
        'FAIL_INVALID_RUNTIME_DIAGNOSTIC') `
      'R19F with a non-canonical fixed field layout never decodes as success'

  $mismatchProvenance =
      New-SyntheticR19DiagnosticProvenance -SourceHashMismatch
  $mismatchDiagnostic = Get-R19RuntimeFailDiagnosticRecord `
      $diagnosticParser.frames[0] 0 $mismatchProvenance
  Add-Test 'r19f_source_hash_mismatch_is_not_diagnostic_success' (
      [bool]$mismatchDiagnostic.candidate -and
      -not [bool]$mismatchDiagnostic.diagnostic_success -and
      -not [bool]$mismatchDiagnostic.source_mapping_verified -and
      [string]$mismatchDiagnostic.failure -match
        'source_hash_or_role_binding_mismatch' -and
      (Get-R19RuntimeFailAcceptanceResult @($mismatchDiagnostic)) -ceq
        'FAIL_INVALID_RUNTIME_DIAGNOSTIC') `
      'a role source hash mismatch is fail-closed and not diagnostic success'

  $boundary30 = New-SyntheticScenario 30000000
  Add-Test 'target_30s_boundary' (
      $boundary30.accounting.result -ceq 'PASS' -and
      $boundary30.accounting.request_to_last_us -eq 30000000 -and
      $boundary30.accounting.target_30s -ceq 'PASS') `
      '30,000,000 us must pass inclusively'

  $over30 = New-DerivedSyntheticScenario $boundary30 'over30'
  Add-Test 'target_30s_overrun_negative' (
      $over30.accounting.result -ceq 'FAIL' -and
      $over30.accounting.request_to_last_us -eq 30000001 -and
      $over30.accounting.target_30s -ceq 'FAIL') `
      '30,000,001 us must fail hard gate'
  Add-Test 'r19_live_deadline_boundary' (
      (Get-R19CompletionDeadlineFailure 30000000 0 -1) -ceq '' -and
      (Get-R19CompletionDeadlineFailure 30000001 0 30000000) -ceq '') `
      'an exact 30,000,000 us completion passes inclusively'
  Add-Test 'r19_live_deadline_incomplete_negative' (
      (Get-R19CompletionDeadlineFailure 30000001 0 -1) -ceq
          'R19 completion deadline exceeded: 30000000 us') `
      'an incomplete stream fails immediately after 30,000,000 us'
  Add-Test 'r19_live_deadline_late_completion_negative' (
      (Get-R19CompletionDeadlineFailure 30000001 0 30000001) -ceq
          'R19 completion deadline exceeded: 30000000 us') `
      'a terminal frame timestamp after the boundary fails immediately'

  $missing = New-DerivedSyntheticScenario $boundary30 'missing931'
  Add-Test 'missing_931_negative' (
      $missing.accounting.result -ceq 'FAIL' -and
      $missing.accounting.missing -eq 1 -and
      $missing.accounting.unique -eq 931) 'one missing terminal index fails'

  $duplicate = New-DerivedSyntheticScenario $boundary30 'duplicate247'
  Add-Test 'duplicate_negative' (
      $duplicate.accounting.result -ceq 'FAIL' -and
      $duplicate.accounting.duplicate -eq 1 -and
      $duplicate.accounting.parameter_frames -eq 933) `
      'one duplicate/extra PARAM_VALUE fails'

  $order = New-DerivedSyntheticScenario $boundary30 'swap1and2'
  Add-Test 'out_of_order_negative' (
      $order.accounting.result -ceq 'FAIL' -and
      $order.accounting.out_of_order -gt 0 -and
      $order.accounting.future -gt 0) 'future and late indexes fail'

  $heartbeatGap = New-DerivedSyntheticScenario $boundary30 'heartbeat_gap'
  Add-Test 'heartbeat_gap_negative' (
      $heartbeatGap.accounting.result -ceq 'FAIL' -and
      $heartbeatGap.accounting.heartbeat.maximum_consecutive_gap_us -gt
          $HeartbeatLimitUs) 'a >2.5 s primary heartbeat gap fails'

  $crc = New-DerivedSyntheticScenario $boundary30 'crc400'
  Add-Test 'crc_negative' ($crc.accounting.result -ceq 'FAIL' -and
      $crc.accounting.parser.bad_crc -eq 1 -and
      -not $crc.accounting.all_parser_crc_partial_control_errors_zero) `
      'CRC corruption fails parser/control gate'

  $partial = New-DerivedSyntheticScenario $boundary30 'partial_tail'
  Add-Test 'partial_negative' ($partial.accounting.result -ceq 'FAIL' -and
      $partial.accounting.parser.partial_bytes -eq 2) `
      'terminal partial frame fails parser gate'

  Add-Test 'stall_timeout_negative' (
      (Get-DeadlineFailure 120000001 0 0 $false) -ceq 'stall_timeout') `
      '120,000,001 us without unique progress fails'
  Add-Test 'overall_timeout_negative' (
      (Get-DeadlineFailure 7200000001 0 7199999999 $false) -ceq
          'overall_timeout') '7,200,000,001 us overall fails'

  Reset-OfflineRequestState
  $readOnlyParser = New-MavlinkParser 'read_only_preflight_invariant' $false
  $readOnlySerial = New-FakeSerial
  $readOnlyPreflight = [pscustomobject][ordered]@{
    result='PASS';heartbeat_count=3;maximum_gap_us=[int64]2500000
    last_heartbeat_age_us=[int64]1000000;pre_request_param_frames=0
    parser_buffer_empty=$true;os_bytes_to_read=0
  }
  $readOnlyProof = Assert-ReadOnlyPreflightInvariants $readOnlyPreflight `
      $readOnlySerial $readOnlyParser 5000
  Add-Test 'readonly_preflight_zero_write_positive' (
      $readOnlyProof.result -ceq 'PASS' -and
      $readOnlyProof.serial_write_operation_count -eq 0 -and
      $readOnlySerial.write_calls -eq 0 -and
      $script:RequestState.request_outcome -ceq 'NOT_ATTEMPTED') `
      '2.5 s boundary passes without a serial Write or request-state transition'
  $readOnlyGapRejected = $false
  $readOnlyPreflight.maximum_gap_us = [int64]2500001
  try {
    [void](Assert-ReadOnlyPreflightInvariants $readOnlyPreflight `
        $readOnlySerial $readOnlyParser 5000)
  } catch {$readOnlyGapRejected = $true}
  Add-Test 'readonly_preflight_gap_overrun_negative' (
      $readOnlyGapRejected -and $readOnlySerial.write_calls -eq 0 -and
      $script:RequestState.request_outcome -ceq 'NOT_ATTEMPTED') `
      '2,500,001 us fails before any serial Write'

  $timeoutParser = New-MavlinkParser 'read_only_timeout_evidence' $false
  Add-MavlinkBytes $timeoutParser (New-SyntheticHeartbeatFrame 1) 1000000
  Add-MavlinkBytes $timeoutParser (New-SyntheticParamValueFrame 0 2) 2000000
  Add-MavlinkBytes $timeoutParser ([byte[]]@(0xAA,0xFD,0x19)) 3000000
  $timeoutSerial = New-FakeSerial
  $timeoutSerial.BytesToRead = 7
  $timeoutSerial.BytesToWrite = 3
  $timeoutEvidence = Get-PreflightEvidenceSnapshot $timeoutSerial `
      $timeoutParser 4000000 0 2000000 100001 $true 'FAIL' `
      'synthetic preflight timeout'
  Add-Test 'readonly_preflight_timeout_evidence_positive' (
      $timeoutEvidence.result -ceq 'FAIL' -and
      $timeoutEvidence.raw_bytes -eq 61 -and
      $timeoutEvidence.frame_count -eq 2 -and
      $timeoutEvidence.valid_frames -eq 2 -and
      $timeoutEvidence.primary_heartbeat_count -eq 1 -and
      $timeoutEvidence.unsolicited_param_value_count -eq 1 -and
      $timeoutEvidence.maximum_heartbeat_gap_us -eq $null -and
      $timeoutEvidence.last_heartbeat_age_us -eq 3000000 -and
      $timeoutEvidence.parser.partial_bytes -eq 2 -and
      $timeoutEvidence.parser.noise_bytes -eq 1 -and
      $timeoutEvidence.parser_error_count -eq 3 -and
      $timeoutEvidence.os_bytes_to_read -eq 7 -and
      $timeoutEvidence.os_bytes_to_write -eq 3 -and
      $timeoutEvidence.maximum_pump_service_gap_us -eq 100001 -and
      $timeoutEvidence.pump_service_limit_us -eq $PumpServiceLimitUs) `
      'timeout retains raw/frame/HB/PARAM/parser/queue/pump counters'

  Reset-OfflineRequestState
  $fake = New-FakeSerial
  $fakeClock = [pscustomobject]@{now_us=[int64]1000000}
  $now = {$fakeClock.now_us}.GetNewClosure()
  $wait = {$fakeClock.now_us += 1000}.GetNewClosure()
  $write = Invoke-ExactRequestWrite $fake $request $now $wait `
      -DrainTimeoutUs 10000 -Simulation
  Add-Test 'fake_serial_exact_once_positive' (
      $write.result -ceq 'PASS' -and $fake.write_calls -eq 1 -and
      $fake.written.Count -eq 14 -and
      (Get-ByteSha $fake.written.ToArray()) -ceq $exactRequestSha256 -and
      $fake.BaseStream.flush_count -eq 0 -and
      $script:RequestState.request_writes_completed -eq 1) `
      'fake serial receives one exact write and completes drain edge'
  $secondRejected = $false
  try {
    [void](Invoke-ExactRequestWrite $fake $request $now $wait `
        -DrainTimeoutUs 10000 -Simulation)
  } catch {$secondRejected = $true}
  Add-Test 'write_count_negative' ($secondRejected -and
      $fake.write_calls -eq 1) 'second request is rejected before Write'

  Reset-OfflineRequestState
  $stuck = New-FakeSerial -NeverDrains
  $stuckClock = [pscustomobject]@{now_us=[int64]2000000}
  $stuckNow = {$stuckClock.now_us}.GetNewClosure()
  $stuckWait = {$stuckClock.now_us += 1000}.GetNewClosure()
  $drainRejected = $false
  try {
    [void](Invoke-ExactRequestWrite $stuck $request $stuckNow $stuckWait `
        -DrainTimeoutUs 3000 -Simulation)
  } catch {$drainRejected = $true}
  Add-Test 'write_drain_timeout_ambiguous_negative' (
      $drainRejected -and $stuck.write_calls -eq 1 -and
      $script:RequestState.request_outcome -ceq 'AMBIGUOUS' -and
      $script:RequestState.request_writes_completed -eq 0) `
      'drain timeout is ambiguous, failed, and never retried'

  # Regression for the long R18 run: a state update consumes each new frame
  # once, while 100,000 idle turns do no history scan or allocation.
  $fairParser = New-MavlinkParser 'incremental_fairness' $false
  $fairBoundary = New-OfflineBoundary $fairParser 0
  $fairState = New-LiveProgressState $fairParser
  for ($index = 0; $index -lt 1000; ++$index) {
    Add-MavlinkBytes $fairParser `
        (New-SyntheticHeartbeatFrame ([byte]($index -band 0xFF))) `
        ($index + 1)
  }
  [void](Update-LiveParamProgress $fairParser $fairBoundary $fairState 1001)
  for ($turn = 0; $turn -lt 1000; ++$turn) {
    [void](Update-LiveParamProgress $fairParser $fairBoundary $fairState `
        (1002 + $turn))
  }
  Add-Test 'incremental_many_idle_turns_fairness' (
      $fairState.frames_processed -eq 1000 -and
      $fairState.frame_cursor -eq 1000 -and
      $fairState.idle_update_calls -eq 1000 -and
      $fairState.unique -eq 0) `
      '1,000 frames are processed exactly once across 1,000 idle turns'

  $cleanupFault = Invoke-OfflineCleanupFaultProbe
  Add-Test 'cleanup_flush_close_dispose_failure_negative' (
      $cleanupFault.result -ceq 'FAIL' -and
      $cleanupFault.error_count -eq 3) `
      'fake Flush/Close/Dispose failures produce cleanup FAIL'

  $integrityProbe = [pscustomobject][ordered]@{
    result='PASS';failure='';runner_integrity=$null
  }
  [void](Apply-RunnerIntegrityGate $integrityProbe $false ('A' * 64) ('B' * 64))
  Add-Test 'runner_integrity_mismatch_negative' (
      $integrityProbe.result -ceq 'FAIL' -and
      $integrityProbe.runner_integrity.result -ceq 'FAIL') `
      'runner source hash mismatch downgrades top-level result'

  # Fake tests used -Simulation.  This is a behavioral gate, not a hardcoded
  # projection: any accidental external path makes the offline suite fail.
  $externalZero = -not [bool]$script:ExternalActions.cim_queried -and
      -not [bool]$script:ExternalActions.pnp_queried -and
      -not [bool]$script:ExternalActions.process_inventory_queried -and
      -not [bool]$script:ExternalActions.com_ports_opened -and
      -not [bool]$script:ExternalActions.serial_write_attempted -and
      -not [bool]$script:ExternalActions.serial_write_call_completed -and
      -not [bool]$script:ExternalActions.serial_bytes_drained -and
      -not [bool]$script:ExternalActions.serial_bytes_written -and
      -not [bool]$script:ExternalActions.firmware_write_attempted -and
      -not [bool]$script:ExternalActions.e220_write_attempted -and
      -not [bool]$script:ExternalActions.actuator_command_attempted
  Add-Test 'offline_external_actions_zero' $externalZero `
      'offline mode performs no CIM/PnP/process/COM/write/device action'

  $failed = @($tests | Where-Object {$_.result -cne 'PASS'})
  $diagnosticTests = @($tests | Where-Object {$_.name -like 'r19f_*'})
  $diagnosticFailed = @($diagnosticTests | Where-Object {
    $_.result -cne 'PASS'
  })
  return [pscustomobject][ordered]@{
    schema_version=1;test_id=$script:TestId
    mode='OFFLINE_SELF_TEST';result=if ($failed.Count -eq 0) {'PASS'} else {'FAIL'}
    acceptance_profile=if ($R19SharedMode.IsPresent) {'R19'} else {'R18'}
    test_count=$tests.Count;failed_count=$failed.Count;tests=@($tests)
    measurement=$null;request=$script:RequestState;cleanup=$null
    external_actions=$script:ExternalActions
    safety=[pscustomobject][ordered]@{
      firmware_write_attempted=$false;e220_write_attempted=$false
      actuator_command_attempted=$false;power_cycle_required=$false
      com3_opened=$false;com3_written=$false
    }
    runtime_failure_diagnostic_contract=[pscustomobject][ordered]@{
      result=if ($diagnosticFailed.Count -eq 0) {'PASS'} else {'FAIL'}
      prefix='R19F:';message_id=253;system_id=254;component_id=190
      severity=2;payload_length=51;wire_length=63
      status_layout=('startup_fault,e220_state,e220_fault,writer_status,' +
          'radio_session_status,packed(adapter_fail_closed|tdd_state)')
      valid_frame_acceptance_result='FAIL_RUNTIME_DIAGNOSTIC_OBSERVED'
      invalid_frame_acceptance_result='FAIL_INVALID_RUNTIME_DIAGNOSTIC'
      source_mapping_required=$true;raw_frame_evidence_required=$true
      tests=$diagnosticTests
    }
  }
}

function Complete-Evidence([object]$Summary) {
  Assert-Condition (-not $script:SummaryWritten) `
      'Evidence completion may only run once.'
  $script:SummaryWritten = $true
  $runnerEndSha = Get-Sha $PSCommandPath
  $runnerStable = -not [string]::IsNullOrWhiteSpace($script:RunnerStartSha256) -and
      $runnerEndSha -ceq $script:RunnerStartSha256
  [void](Apply-RunnerIntegrityGate $Summary $runnerStable `
      $script:RunnerStartSha256 $runnerEndSha)
  if ([string]$Summary.mode -ceq $script:LiveMode -and
      [string]$Summary.result -ceq 'PASS') {
    if ($null -eq $script:CleanupResult -or
        [string]$script:CleanupResult.result -cne 'PASS') {
      $Summary.result = 'FAIL'
      if ($Summary.PSObject.Properties['failure']) {
        $Summary.failure = ([string]$Summary.failure +
            ' | live cleanup/durability proof missing or failed').Trim(' ','|')
      } else {
        $Summary | Add-Member NoteProperty failure `
            'live cleanup/durability proof missing or failed'
      }
    }
  }
  if ($Summary.PSObject.Properties['finished_utc']) {
    $Summary.finished_utc = [DateTime]::UtcNow.ToString('o')
  } else {
    $Summary | Add-Member NoteProperty finished_utc `
        ([DateTime]::UtcNow.ToString('o'))
  }
  $summaryPath = Join-Path $evidence 'summary.json'
  Write-DurableJson $summaryPath $Summary

  $excluded = @('artifact_manifest.json','SHA256SUMS.txt','final_seal.json')
  $artifacts = @(
    Get-ChildItem -LiteralPath $evidence -Recurse -File |
      Where-Object {$excluded -notcontains $_.Name} |
      Sort-Object FullName |
      ForEach-Object {
        [pscustomobject][ordered]@{
          path=$_.FullName.Substring($evidence.Length + 1).Replace('\','/')
          bytes=[int64]$_.Length
          sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
        }
      }
  )
  $manifest = [pscustomobject][ordered]@{
    schema_version=1;test_id=$script:TestId
    artifact_count=$artifacts.Count;artifacts=$artifacts
  }
  $manifestPath = Join-Path $evidence 'artifact_manifest.json'
  Write-DurableJson $manifestPath $manifest

  $sumItems = @(
    Get-ChildItem -LiteralPath $evidence -Recurse -File |
      Where-Object {$_.Name -notin @('SHA256SUMS.txt','final_seal.json')} |
      Sort-Object FullName
  )
  $sumLines = foreach ($item in $sumItems) {
    $relative = $item.FullName.Substring($evidence.Length + 1).Replace('\','/')
    '{0} *{1}' -f (Get-FileHash -Algorithm SHA256 `
        -LiteralPath $item.FullName).Hash,$relative
  }
  $sumsPath = Join-Path $evidence 'SHA256SUMS.txt'
  Write-Durable $sumsPath (($sumLines -join $newline) + $newline)

  $seal = [pscustomobject][ordered]@{
    schema_version=1;sealed_utc=[DateTime]::UtcNow.ToString('o')
    result=[string]$Summary.result
    summary_sha256=Get-Sha $summaryPath
    artifact_manifest_sha256=Get-Sha $manifestPath
    sha256sums_sha256=Get-Sha $sumsPath
    runner_integrity=if ($runnerStable) {'PASS'} else {'FAIL'}
    immutable_after_seal=$true
  }
  Write-DurableJson (Join-Path $evidence 'final_seal.json') $seal
}

$script:LastMeasurement = $null
$finalSummary = $null
$mainFailure = ''
try {
  Assert-Condition (-not ($Execute.IsPresent -and $OfflineSelfTest.IsPresent)) `
      'Execute and OfflineSelfTest are mutually exclusive.'
  Assert-Condition (-not ($PreflightOnly.IsPresent -and
      $OfflineSelfTest.IsPresent)) `
      'PreflightOnly and OfflineSelfTest are mutually exclusive.'
  Assert-Condition (-not ($PreflightOnly.IsPresent -and
      $R19SharedMode.IsPresent)) `
      'PreflightOnly and R19SharedMode are mutually exclusive.'
  Assert-Condition ($Execute.IsPresent -or $OfflineSelfTest.IsPresent) `
      'Choose -OfflineSelfTest or explicitly supply -Execute.'
  Assert-PinnedInputs
  if ($OfflineSelfTest.IsPresent) {
    $finalSummary = Invoke-OfflineSelfTest
  } else {
    $measurement = Invoke-R18PixhawkMeasurement
    $finalSummary = [pscustomobject][ordered]@{
      schema_version=1;test_id=$script:TestId
      mode=$script:LiveMode;result=[string]$measurement.result
      acceptance_profile=if ($R19SharedMode.IsPresent) {'R19'} else {'R18'}
      started_utc=$script:StartedUtc;finished_utc=''
      failure='';measurement=$measurement
      request=$script:RequestState;external_actions=$script:ExternalActions
      cleanup=$script:CleanupResult
      safety=[pscustomobject][ordered]@{
        firmware_write_attempted=$false;e220_write_attempted=$false
        actuator_command_attempted=$false;power_cycle_required=$false
        com3_opened=$false;com3_written=$false
        read_only_preflight=$PreflightOnly.IsPresent
        only_permitted_write=if ($PreflightOnly.IsPresent) {
          'none (read-only preflight)'
        } else {'one exact MAVLink PARAM_REQUEST_LIST #21 on COM6'}
      }
      r18_artifact_provenance=[pscustomobject][ordered]@{
        result=if ($R19SharedMode.IsPresent) {'NOT_APPLICABLE'} else {'PASS'}
        accepted_files_verified=(-not $R19SharedMode.IsPresent)
        pins=@($script:PinRecords | Where-Object {
          $_.name -like '*.r18.*' -or $_.name -like 'prior.*'})
      }
      r19_artifact_provenance=[pscustomobject][ordered]@{
        result=if ($R19SharedMode.IsPresent) {'PASS'} else {'NOT_APPLICABLE'}
        validated=$R19SharedMode.IsPresent
        record=$script:R19Provenance
      }
      runtime_firmware_provenance=[pscustomobject][ordered]@{
        result=if ($R19SharedMode.IsPresent) {
          'PASS_MANIFEST_BOUND_FLASH_EVIDENCE'
        } else {'UNPROVEN_NO_DEVICE_READBACK'}
        verified=$R19SharedMode.IsPresent
        interpretation=if ($R19SharedMode.IsPresent) {
          ('The dedicated R19 wrapper validated immutable candidate build ' +
           'and Execute-mode write/verify evidence before COM6 open.')
        } else {
          ('Accepted R18 binaries and prior restore evidence are pinned, ' +
           'but this measurement-only runner does not read flash.')
        }
      }
      runtime_failure_diagnostic_contract=[pscustomobject][ordered]@{
        result=if ($R19SharedMode.IsPresent) {'PASS'} else {'NOT_APPLICABLE'}
        prefix='R19F:';message_id=253;system_id=254;component_id=190
        severity=2;payload_length=51;wire_length=63
        valid_frame_acceptance_result='FAIL_RUNTIME_DIAGNOSTIC_OBSERVED'
        invalid_frame_acceptance_result='FAIL_INVALID_RUNTIME_DIAGNOSTIC'
        source_mapping_required=$true;raw_frame_evidence_required=$true
        tests=@()
      }
      runner_integrity=$null
    }
  }
} catch {
  $mainFailure = $_.Exception.Message
  $finalSummary = [pscustomobject][ordered]@{
    schema_version=1;test_id=$script:TestId
    mode=if ($OfflineSelfTest.IsPresent) {'OFFLINE_SELF_TEST'} else {$script:LiveMode}
    acceptance_profile=if ($R19SharedMode.IsPresent) {'R19'} else {'R18'}
    result='FAIL';started_utc=$script:StartedUtc;finished_utc=''
    failure=$mainFailure;measurement=$script:LastMeasurement
    request=$script:RequestState;external_actions=$script:ExternalActions
    cleanup=$script:CleanupResult
    safety=[pscustomobject][ordered]@{
      firmware_write_attempted=$false;e220_write_attempted=$false
      actuator_command_attempted=$false;power_cycle_required=$false
      com3_opened=$false;com3_written=$false
      read_only_preflight=$PreflightOnly.IsPresent
      only_permitted_write=if ($PreflightOnly.IsPresent) {
        'none (read-only preflight)'
      } else {'one exact MAVLink PARAM_REQUEST_LIST #21 on COM6'}
    }
    r18_artifact_provenance=[pscustomobject][ordered]@{
      result=if ($R19SharedMode.IsPresent) {'NOT_APPLICABLE'} elseif (
          $script:PinRecords.Count -ge 5) {'PASS'} else {'INCOMPLETE'}
      accepted_files_verified=(-not $R19SharedMode.IsPresent -and
          $script:PinRecords.Count -ge 5)
      pins=@($script:PinRecords)
    }
    r19_artifact_provenance=[pscustomobject][ordered]@{
      result=if ($R19SharedMode.IsPresent -and $null -ne
          $script:R19Provenance) {'PASS'} elseif ($R19SharedMode.IsPresent) {
          'INCOMPLETE'
        } else {'NOT_APPLICABLE'}
      validated=($R19SharedMode.IsPresent -and $null -ne
          $script:R19Provenance)
      record=$script:R19Provenance
    }
    runtime_firmware_provenance=[pscustomobject][ordered]@{
      result='UNPROVEN_NO_DEVICE_READBACK';verified=$false
    }
    runtime_failure_diagnostic_contract=[pscustomobject][ordered]@{
      result=if ($R19SharedMode.IsPresent) {'PASS'} else {'NOT_APPLICABLE'}
      prefix='R19F:';message_id=253;system_id=254;component_id=190
      severity=2;payload_length=51;wire_length=63
      valid_frame_acceptance_result='FAIL_RUNTIME_DIAGNOSTIC_OBSERVED'
      invalid_frame_acceptance_result='FAIL_INVALID_RUNTIME_DIAGNOSTIC'
      source_mapping_required=$true;raw_frame_evidence_required=$true
      tests=@()
    }
    runner_integrity=$null
  }
} finally {
  Complete-Evidence $finalSummary
}

if ([string]$finalSummary.result -cne 'PASS') {
  Write-Error ("{0} Pixhawk PARAM_LIST E2E FAIL: {1}; evidence={2}" -f `
      $(if ($R19SharedMode.IsPresent) {'R19'} else {'R18'}),
      $mainFailure,$evidence)
  exit 1
}
Write-Output ("{0} Pixhawk PARAM_LIST E2E PASS mode={1} evidence={2}" -f `
    $(if ($R19SharedMode.IsPresent) {'R19'} else {'R18'}),
    [string]$finalSummary.mode,$evidence)
exit 0
