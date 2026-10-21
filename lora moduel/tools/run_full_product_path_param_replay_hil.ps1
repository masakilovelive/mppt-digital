[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$EvidenceRoot,
  [string]$RepoRoot = '',
  [switch]$Execute,
  [switch]$OfflineSelfTest,

  [string]$GroundPort = '',
  [string]$GroundPnpDeviceId = '',
  [string]$GroundParentDeviceId = '',
  [string]$GroundVid = '',
  [string]$GroundPid = '',

  [string]$PixhawkFixturePort = '',
  [string]$PixhawkFixturePnpDeviceId = '',
  [string]$PixhawkFixtureParentDeviceId = '',
  [string]$PixhawkFixtureVid = '',
  [string]$PixhawkFixturePid = '',

  [string]$PixhawkIsolationAttestation = '',
  [string]$UsbUartElectricalAttestation = '',
  [ValidateRange(5,120)][int]$D6RequestTimeoutSeconds = 30,
  [ValidateRange(30,7200)][int]$MeasurementTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$newline = [Environment]::NewLine
$startedUtc = [DateTime]::UtcNow.ToString('o')

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
$allowedEvidenceBase = Join-Path $repo `
    'runs\high_speed\R19-HS-G2-FULL-PATH-REPLAY-HIL-001'
$fixtureRoot = Join-Path $repo `
    'runs\high_speed\R19-HS-G2-FROZEN-932-REPLAY-FIXTURE-001\OFFLINE-R18-ACCEPTED-V1'
$fixturePath = Join-Path $fixtureRoot 'param_value_932.mavlink.bin'
$fixtureManifestPath = Join-Path $fixtureRoot 'manifest.json'
$definitionPath = Join-Path $repo 'core\src\mavlink_frame.cpp'

$expectedFixtureSha256 = `
    'F23E2A80B2D72DCCB6F74E4EEE08452223317B22A59A5E4367A7832EF59339B6'
$expectedFixtureManifestSha256 = `
    '88FC22ECD53D95B41AF84210CD2A045E0B9E2833697BA7CD179843BEFFFDA7AD'
$expectedDefinitionSha256 = `
    'BD2890D8973C5A694D53AB2866A6B3DBF319FAE40B3CC308AE2DAE91B634F3A8'
$expectedFixtureId = 'R19-HS-G2-R18-ACCEPTED-PARAM-VALUE-932-V1'
$exactRequestHex = 'FD02000063FFBE1500000101D507'
[int64]$ParamPeriodUs = 25000
[int64]$HeartbeatPeriodUs = 1000000
[int64]$HeartbeatLimitUs = 2500000
[int64]$Target30LimitUs = 30000000
[int64]$Stretch10LimitUs = 10000000

$script:Evidence = $null
$script:EvidenceCompleted = $false
$script:Definitions = $null
$script:FixtureBytes = $null
$script:FixtureFrames = $null
$script:SequencePolicy = $null
$script:Preflight = [ordered]@{
  process_gate=[pscustomobject]@{result='NOT_RUN'}
  pixhawk_isolation=[pscustomobject]@{result='NOT_RUN'}
  ground_identity=[pscustomobject]@{result='NOT_RUN'}
  pixhawk_fixture_identity=[pscustomobject]@{result='NOT_RUN'}
}
$script:ExternalActions = [ordered]@{
  process_inventory_queried=$false
  pnp_queried=$false
  com_ports_enumerated=$false
  com_ports_opened=$false
  serial_bytes_written=$false
  firmware_write_attempted=$false
  firmware_changed=$false
}
$script:FirmwareProvenance = [pscustomobject][ordered]@{
  result='UNPROVEN'
  verified=$false
  ground_firmware_sha256=$null
  vehicle_firmware_sha256=$null
  limitation=('This measurement-only runner neither reads nor verifies the ' +
      'Ground/Vehicle application binaries or a runtime firmware identity.')
}
$script:E220ProfileProvenance = [pscustomobject][ordered]@{
  result='UNPROVEN'
  verified=$false
  ground_profile=$null
  vehicle_profile=$null
  limitation=('This measurement-only runner neither reads nor verifies either ' +
      'E220 profile or physical model during the sealed run.')
}

function Assert-Condition([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Get-Sha([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-ByteSha([byte[]]$Bytes) {
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    -join ($algorithm.ComputeHash($Bytes) | ForEach-Object {
      $_.ToString('X2')
    })
  } finally {
    $algorithm.Dispose()
  }
}

function Write-Durable([string]$Path,[string]$Text) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($parent)
  }
  $bytes = $utf8.GetBytes($Text)
  $stream = [IO.FileStream]::new(
      $Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,
      [IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
  try {
    $stream.Write($bytes,0,$bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
}

function Write-DurableJson([string]$Path,[object]$Value) {
  Write-Durable $Path ((ConvertTo-Json -InputObject $Value -Depth 32) +
      $newline)
  [void]([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Initialize-EvidenceRoot {
  if (-not (Test-Path -LiteralPath $allowedEvidenceBase -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($allowedEvidenceBase)
  }
  $allowed = [IO.Path]::GetFullPath($allowedEvidenceBase).TrimEnd('\')
  $requested = if ([IO.Path]::IsPathRooted($EvidenceRoot)) {
    [IO.Path]::GetFullPath($EvidenceRoot)
  } else {
    [IO.Path]::GetFullPath((Join-Path $repo $EvidenceRoot))
  }
  Assert-Condition ($requested.StartsWith(
      $allowed + '\',[StringComparison]::OrdinalIgnoreCase)) `
      "EvidenceRoot must be a new child of $allowed"
  Assert-Condition (-not (Test-Path -LiteralPath $requested)) `
      "Refusing to overwrite evidence: $requested"
  [void][IO.Directory]::CreateDirectory($requested)
  $script:Evidence = $requested
}

function Copy-PinnedInput([string]$Source,[string]$Name,[int64]$Bytes,
    [string]$Sha256) {
  Assert-Condition (Test-Path -LiteralPath $Source -PathType Leaf) `
      "Pinned input is absent: $Source"
  $item = Get-Item -LiteralPath $Source
  Assert-Condition ([int64]$item.Length -eq $Bytes) `
      "Pinned input size mismatch for $Name"
  Assert-Condition ((Get-Sha $Source) -ceq $Sha256) `
      "Pinned input SHA256 mismatch for $Name"
  $stage = Join-Path (Join-Path $script:Evidence 'staged') $Name
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $stage))
  [IO.File]::Copy($Source,$stage,$false)
  Assert-Condition ((Get-Sha $stage) -ceq $Sha256) `
      "Staged input SHA256 mismatch for $Name"
  return [pscustomobject][ordered]@{
    source=$Source;staged=$stage;bytes=$Bytes;sha256=$Sha256
  }
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
      'Required MAVLink CRC_EXTRA definitions changed.'
  return $definitions
}

function Convert-HexToBytes([string]$Hex) {
  Assert-Condition (($Hex.Length % 2) -eq 0) 'Odd hex length.'
  [byte[]]$output = New-Object byte[] ($Hex.Length / 2)
  for ($index = 0; $index -lt $output.Length; ++$index) {
    $output[$index] = [Convert]::ToByte($Hex.Substring($index * 2,2),16)
  }
  return $output
}

function Test-ByteEqual([byte[]]$Left,[byte[]]$Right) {
  if ($Left.Length -ne $Right.Length) { return $false }
  for ($index = 0; $index -lt $Left.Length; ++$index) {
    if ($Left[$index] -ne $Right[$index]) { return $false }
  }
  return $true
}

function Get-FixtureSequencePolicy([object[]]$Frames) {
  [int]$discontinuities = 0
  for ($index = 1; $index -lt $Frames.Count; ++$index) {
    [int]$previous = [int]([byte[]]$Frames[$index - 1])[4]
    [int]$current = [int]([byte[]]$Frames[$index])[4]
    if ($current -ne (($previous + 1) -band 0xFF)) {
      ++$discontinuities
    }
  }
  Assert-Condition ($discontinuities -eq 62) `
      "Frozen fixture sequence discontinuities changed: $discontinuities"
  return [pscustomobject][ordered]@{
    fixture_param_sequence_discontinuities=62
    fixture_sequence_origin='accepted stream with omitted interleaved frames'
    synthetic_heartbeat_sequence_series='independent ordinal modulo 256'
    transport_pass_condition=$false
    interpretation=('Sequence discontinuities are fixture provenance, not ' +
        'transport loss; exact frame/index/CRC accounting is the pass gate.')
  }
}

function Assert-PinnedInputs {
  $pins = [Collections.ArrayList]::new()
  [void]$pins.Add((Copy-PinnedInput $fixturePath `
      'param_value_932.mavlink.bin' (932 * 37) $expectedFixtureSha256))
  [void]$pins.Add((Copy-PinnedInput $fixtureManifestPath `
      'fixture.manifest.json' 2670 $expectedFixtureManifestSha256))
  [void]$pins.Add((Copy-PinnedInput $definitionPath `
      'mavlink_frame.cpp' 16510 $expectedDefinitionSha256))
  $runnerBytes = (Get-Item -LiteralPath $PSCommandPath).Length
  $runnerSha = Get-Sha $PSCommandPath
  [void]$pins.Add((Copy-PinnedInput $PSCommandPath `
      'runner.executed.ps1' $runnerBytes $runnerSha))

  $manifest = [IO.File]::ReadAllText($fixtureManifestPath) | ConvertFrom-Json
  Assert-Condition ([string]$manifest.fixture_id -ceq $expectedFixtureId) `
      'Frozen fixture_id changed.'
  Assert-Condition ([string]$manifest.result -ceq 'PASS') `
      'Frozen fixture manifest is not PASS.'
  Assert-Condition ([int]$manifest.fixture.frame_count -eq 932 -and
      [int]$manifest.fixture.frame_size_bytes -eq 37 -and
      [int]$manifest.fixture.stream_bytes -eq (932 * 37)) `
      'Frozen fixture shape changed.'
  Assert-Condition ([string]$manifest.fixture.stream_sha256 -ceq
      $expectedFixtureSha256) 'Frozen fixture manifest hash pin changed.'

  $script:Definitions = Get-MavlinkDefinitions $definitionPath
  [byte[]]$script:FixtureBytes = [IO.File]::ReadAllBytes($fixturePath)
  $frames = [Collections.ArrayList]::new()
  for ($index = 0; $index -lt 932; ++$index) {
    [byte[]]$frame = New-Object byte[] 37
    [Array]::Copy($script:FixtureBytes,$index * 37,$frame,0,37)
    [void]$frames.Add($frame)
  }
  $script:FixtureFrames = @($frames)
  $script:SequencePolicy = Get-FixtureSequencePolicy $script:FixtureFrames
  return @($pins)
}

function Update-X25Crc([uint16]$Crc,[byte]$Value) {
  [int]$mixed = ($Value -bxor ($Crc -band 0xFF)) -band 0xFF
  $mixed = ($mixed -bxor (($mixed -shl 4) -band 0xFF)) -band 0xFF
  return [uint16]((($Crc -shr 8) -bxor ($mixed -shl 8) -bxor
      ($mixed -shl 3) -bxor ($mixed -shr 4)) -band 0xFFFF)
}

function New-ExactParamRequestList {
  [byte[]]$request = Convert-HexToBytes $exactRequestHex
  Assert-Condition ($request.Length -eq 14) `
      'Exact PARAM_REQUEST_LIST must be 14 bytes.'
  return $request
}

function New-HeartbeatFrame([byte]$Sequence) {
  [byte[]]$frame = New-Object byte[] 21
  $frame[0] = 0xFD
  $frame[1] = 9
  $frame[4] = $Sequence
  $frame[5] = 1
  $frame[6] = 1
  # message id 0; custom_mode 0; SURFACE_BOAT, ArduPilot, base_mode 0,
  # system_status STANDBY, MAVLink version 3.
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

function New-ParamRequestReadFrame {
  [byte[]]$frame = New-Object byte[] 32
  $frame[0] = 0xFD
  $frame[1] = 20
  $frame[4] = 64
  $frame[5] = 255
  $frame[6] = 190
  $frame[7] = 20
  $frame[10] = 0xFF
  $frame[11] = 0xFF
  $frame[12] = 1
  $frame[13] = 1
  [uint16]$crc = 0xFFFF
  for ($index = 1; $index -lt 30; ++$index) {
    $crc = Update-X25Crc $crc $frame[$index]
  }
  $crc = Update-X25Crc $crc 214
  $frame[30] = [byte]($crc -band 0xFF)
  $frame[31] = [byte](($crc -shr 8) -band 0xFF)
  return $frame
}

function New-MavlinkParser([string]$Name) {
  return [pscustomobject][ordered]@{
    name=$Name
    buffer=[Collections.Generic.List[byte]]::new()
    expected_size=0
    total_bytes=[int64]0
    noise_bytes=[int64]0
    bad_length=[int64]0
    bad_crc=[int64]0
    unsupported_flags=[int64]0
    unknown_definition=[int64]0
    valid_frames=[int64]0
    frames=[Collections.ArrayList]::new()
  }
}

function Convert-MavlinkFrameRecord([byte[]]$Raw,[int64]$ElapsedUs) {
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
    if ($version -eq 2 -and $messageId -eq 20) { $minimum = 4 }
    if ($version -eq 2 -and $messageId -eq 76) { $minimum = 30 }
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
      if ($stored -ne $crc) { $failure = 'bad_crc' }
    }
  }
  return [pscustomobject][ordered]@{
    elapsed_us=$ElapsedUs
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
    raw_sha256=Get-ByteSha $Raw
  }
}

function Add-MavlinkBytes([object]$Parser,[byte[]]$Bytes,
    [int64]$ElapsedUs) {
  foreach ($value in $Bytes) {
    $Parser.total_bytes = [int64]$Parser.total_bytes + 1
    if ($Parser.buffer.Count -eq 0) {
      if ($value -ne 0xFD -and $value -ne 0xFE) {
        $Parser.noise_bytes = [int64]$Parser.noise_bytes + 1
        continue
      }
    }
    $Parser.buffer.Add($value)
    if ($Parser.buffer.Count -eq 2) {
      $payloadLength = [int]$Parser.buffer[1]
      if ($Parser.buffer[0] -eq 0xFE) {
        $Parser.expected_size = $payloadLength + 8
      }
    }
    if ($Parser.buffer.Count -eq 3 -and $Parser.buffer[0] -eq 0xFD) {
      $signature = if (($Parser.buffer[2] -band 1) -ne 0) {13} else {0}
      $Parser.expected_size = [int]$Parser.buffer[1] + 12 + $signature
    }
    if ($Parser.expected_size -gt 0 -and
        $Parser.buffer.Count -eq $Parser.expected_size) {
      [byte[]]$raw = $Parser.buffer.ToArray()
      $record = Convert-MavlinkFrameRecord $raw $ElapsedUs
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
            $Parser.unknown_definition = `
                [int64]$Parser.unknown_definition + 1
          }
        }
      }
      [void]$Parser.frames.Add($record)
      $Parser.buffer.Clear()
      $Parser.expected_size = 0
    } elseif ($Parser.buffer.Count -gt 280) {
      $Parser.bad_length = [int64]$Parser.bad_length + 1
      $Parser.buffer.Clear()
      $Parser.expected_size = 0
    }
  }
}

function Get-ParserHealth([object]$Parser) {
  $pass = [int64]$Parser.noise_bytes -eq 0 -and
      [int64]$Parser.bad_crc -eq 0 -and
      [int64]$Parser.bad_length -eq 0 -and
      [int64]$Parser.unsupported_flags -eq 0 -and
      [int64]$Parser.unknown_definition -eq 0 -and
      $Parser.buffer.Count -eq 0
  return [pscustomobject][ordered]@{
    result=if ($pass) {'PASS'} else {'FAIL'}
    total_bytes=[int64]$Parser.total_bytes
    valid_frames=[int64]$Parser.valid_frames
    noise_bytes=[int64]$Parser.noise_bytes
    bad_lengths=[int64]$Parser.bad_length
    bad_crc=[int64]$Parser.bad_crc
    unsupported_flags=[int64]$Parser.unsupported_flags
    unknown_definition=[int64]$Parser.unknown_definition
    partial_bytes=[int]$Parser.buffer.Count
  }
}

function Assert-ParserRuntimeClean([object]$Parser,[int64]$NowUs,
    [ref]$PartialSinceUs,[string]$Role) {
  $hardErrors = [int64]$Parser.noise_bytes + [int64]$Parser.bad_crc +
      [int64]$Parser.bad_length + [int64]$Parser.unsupported_flags +
      [int64]$Parser.unknown_definition
  if ($hardErrors -ne 0) {
    throw "$Role parser integrity failure; D7 writes stop immediately."
  }
  if ($Parser.buffer.Count -eq 0) {
    $PartialSinceUs.Value = [int64]-1
  } elseif ([int64]$PartialSinceUs.Value -lt 0) {
    $PartialSinceUs.Value = $NowUs
  } elseif ($NowUs - [int64]$PartialSinceUs.Value -gt 100000) {
    throw "$Role parser partial frame persisted over 100000 us; D7 writes stop immediately."
  }
}

function Assert-D6ReplayFenceState([object]$Parser,[ref]$FrameCursor,
    [byte[]]$ExactRequest,[ref]$ExactRequestCount,
    [ref]$GateObserved,[ref]$ReplayEpochUs) {
  while ([int]$FrameCursor.Value -lt $Parser.frames.Count) {
    $record = $Parser.frames[[int]$FrameCursor.Value]
    $FrameCursor.Value = [int]$FrameCursor.Value + 1
    if (-not $record.valid) { continue }
    if ($record.message_id -eq 20) {
      throw 'D6 observed PARAM_REQUEST_READ (#20); D7 writes stop immediately.'
    }
    if ($record.message_id -eq 21) {
      if (-not (Test-ByteEqual ([byte[]]$record.raw) $ExactRequest)) {
        throw 'D6 observed non-exact PARAM_REQUEST_LIST (#21); D7 writes stop immediately.'
      }
      if ([int]$ExactRequestCount.Value -ne 0) {
        throw 'D6 observed a second exact PARAM_REQUEST_LIST (#21); D7 writes stop immediately.'
      }
      $ExactRequestCount.Value = 1
      $GateObserved.Value = $true
      $ReplayEpochUs.Value = [int64]$record.elapsed_us
    }
  }
}

function Assert-GroundFrameStrictOnline([object]$Record,
    [ref]$NextExpectedIndex,[object[]]$FixtureFrames,
    [bool]$ReplayStarted) {
  if (-not $Record.valid -or $Record.message_id -ne 22) { return -1 }
  if (-not $ReplayStarted) {
    throw 'Ground PARAM_VALUE arrived before the D6 request fence; D7 writes stop immediately.'
  }
  if ($Record.system_id -ne 1 -or $Record.component_id -ne 1 -or
      $Record.version -ne 2 -or $Record.payload_length -ne 25) {
    throw 'Ground PARAM_VALUE source/version/payload anomaly; D7 writes stop immediately.'
  }
  [byte[]]$raw = $Record.raw
  [int]$offset = [int]$Record.payload_offset
  [int]$count = [BitConverter]::ToUInt16($raw,$offset + 4)
  [int]$index = [BitConverter]::ToUInt16($raw,$offset + 6)
  if ($count -ne 932 -or $index -lt 0 -or $index -ge 932) {
    throw 'Ground PARAM_VALUE count/index anomaly; D7 writes stop immediately.'
  }
  [int]$expected = [int]$NextExpectedIndex.Value
  if ($index -ne $expected) {
    throw "Ground PARAM_VALUE order anomaly expected=$expected actual=$index; D7 writes stop immediately."
  }
  if (-not (Test-ByteEqual $raw ([byte[]]$FixtureFrames[$index]))) {
    throw "Ground PARAM_VALUE byte mismatch index=$index; D7 writes stop immediately."
  }
  $NextExpectedIndex.Value = $expected + 1
  return $index
}

function Get-HeartbeatSla([int64[]]$HeartbeatTimes,[int64]$MeasurementStartUs,
    [int64]$LastParamUs) {
  $ordered = @($HeartbeatTimes | Where-Object {
    $_ -ge $MeasurementStartUs
  } | Sort-Object)
  $first = @($ordered | Select-Object -First 1)
  $post = @($ordered | Where-Object {$_ -gt $LastParamUs} |
      Select-Object -First 1)
  [int64]$windowStart = if ($first.Count -eq 1) {$first[0]} else {-1}
  [int64]$firstBoundary = if ($first.Count -eq 1) {
    $first[0] - $MeasurementStartUs
  } else {[int64]::MaxValue}
  [int64]$postBoundary = if ($post.Count -eq 1) {
    $post[0] - $LastParamUs
  } else {[int64]::MaxValue}
  $windowHeartbeats = if ($windowStart -ge 0 -and $post.Count -eq 1) {
    @($ordered | Where-Object {$_ -ge $windowStart -and $_ -le $post[0]})
  } else {@()}
  [int64]$maxGap = 0
  for ($index = 1; $index -lt $windowHeartbeats.Count; ++$index) {
    [int64]$gap = $windowHeartbeats[$index] - $windowHeartbeats[$index - 1]
    if ($gap -gt $maxGap) { $maxGap = $gap }
  }
  $pass = $windowHeartbeats.Count -ge 2 -and
      $firstBoundary -le $HeartbeatLimitUs -and
      $postBoundary -le $HeartbeatLimitUs -and
      $maxGap -le $HeartbeatLimitUs
  return [pscustomobject][ordered]@{
    result=if ($pass) {'PASS'} else {'FAIL'}
    heartbeat_count=$ordered.Count
    window_heartbeat_count=$windowHeartbeats.Count
    request_to_first_heartbeat_us=$firstBoundary
    maximum_gap_us=$maxGap
    completion_to_post_heartbeat_us=$postBoundary
    limit_us=$HeartbeatLimitUs
  }
}

function Get-HighSpeedReplayAcceptance([bool]$StrictData,
    [bool]$HeartbeatPassed,[int64]$RequestToLastUs) {
  $completionObserved = $RequestToLastUs -ge 0
  $target30Pass = $StrictData -and $completionObserved -and
      $RequestToLastUs -le $Target30LimitUs
  $target10Pass = $StrictData -and $completionObserved -and
      $RequestToLastUs -le $Stretch10LimitUs
  return [pscustomobject][ordered]@{
    result=if ($StrictData -and $HeartbeatPassed -and $target30Pass) {
      'PASS'
    } else {'FAIL'}
    data_result=if ($StrictData) {'PASS'} else {'FAIL'}
    heartbeat_result=if ($HeartbeatPassed) {'PASS'} else {'FAIL'}
    completion_observed=$completionObserved
    request_to_last_us=$RequestToLastUs
    target_30s=if ($target30Pass) {'PASS'} else {'FAIL'}
    target_10s=if ($target10Pass) {'PASS'} else {'FAIL'}
    target_30s_hard_gate=$true
    target_10s_hard_gate=$false
  }
}

function Get-StrictCaptureResult([object]$Parser,[object[]]$FixtureFrames,
    [int64]$MeasurementStartUs) {
  $parameterFrames = @($Parser.frames | Where-Object {
    $_.valid -and $_.elapsed_us -ge $MeasurementStartUs -and
        $_.message_id -eq 22
  })
  $heartbeats = @($Parser.frames | Where-Object {
    $_.valid -and $_.elapsed_us -ge $MeasurementStartUs -and
        $_.message_id -eq 0 -and $_.system_id -eq 1 -and
        $_.component_id -eq 1
  })
  [int]$missing = 932
  [int]$duplicate = 0
  [int]$outOfOrder = 0
  [int]$outOfRange = 0
  [int]$wrongSource = 0
  [int]$countMismatch = 0
  [int]$badPayload = 0
  [int]$invalidParamId = 0
  [int]$duplicateParamId = 0
  [int]$byteExactMismatch = 0
  [int]$expectedIndex = 0
  $seen = New-Object bool[] 932
  $ids = [Collections.Generic.HashSet[string]]::new(
      [StringComparer]::Ordinal)
  [int64]$firstParamUs = -1
  [int64]$lastParamUs = -1
  foreach ($record in $parameterFrames) {
    if ($record.system_id -ne 1 -or $record.component_id -ne 1) {
      ++$wrongSource
      continue
    }
    if ($record.version -ne 2 -or $record.payload_length -ne 25) {
      ++$badPayload
      continue
    }
    [byte[]]$raw = $record.raw
    $offset = [int]$record.payload_offset
    $paramCount = [BitConverter]::ToUInt16($raw,$offset + 4)
    $paramIndex = [BitConverter]::ToUInt16($raw,$offset + 6)
    if ($paramCount -ne 932) { ++$countMismatch }
    if ($paramIndex -ge 932) {
      ++$outOfRange
      continue
    }
    if ($seen[$paramIndex]) { ++$duplicate } else {
      $seen[$paramIndex] = $true
      --$missing
    }
    if ($paramIndex -ne $expectedIndex) { ++$outOfOrder } else {
      ++$expectedIndex
    }
    $sawZero = $false
    $idBuilder = [Text.StringBuilder]::new()
    for ($idOffset = 0; $idOffset -lt 16; ++$idOffset) {
      $idByte = [int]$raw[$offset + 8 + $idOffset]
      if ($idByte -eq 0) {
        $sawZero = $true
      } elseif ($sawZero -or $idByte -lt 0x20 -or $idByte -gt 0x7E) {
        ++$invalidParamId
        break
      } else {
        [void]$idBuilder.Append([char]$idByte)
      }
    }
    if ($idBuilder.Length -eq 0) { ++$invalidParamId }
    if (-not $ids.Add($idBuilder.ToString())) { ++$duplicateParamId }
    if (-not (Test-ByteEqual $raw ([byte[]]$FixtureFrames[$paramIndex]))) {
      ++$byteExactMismatch
    }
    if ($paramIndex -eq 0 -and $firstParamUs -lt 0) {
      $firstParamUs = [int64]$record.elapsed_us
    }
    if ($paramIndex -eq 931 -and $lastParamUs -lt 0) {
      $lastParamUs = [int64]$record.elapsed_us
    }
  }
  $heartbeatTimes = @($heartbeats | ForEach-Object {[int64]$_.elapsed_us})
  $heartbeat = if ($firstParamUs -ge 0 -and $lastParamUs -ge 0) {
    Get-HeartbeatSla $heartbeatTimes $MeasurementStartUs $lastParamUs
  } else {
    [pscustomobject][ordered]@{
      result='FAIL';heartbeat_count=$heartbeatTimes.Count
      window_heartbeat_count=0
      request_to_first_heartbeat_us=[int64]::MaxValue
      maximum_gap_us=[int64]::MaxValue
      completion_to_post_heartbeat_us=[int64]::MaxValue
      limit_us=$HeartbeatLimitUs
    }
  }
  $parserErrors = [int64]$Parser.noise_bytes + [int64]$Parser.bad_length +
      [int64]$Parser.bad_crc + [int64]$Parser.unsupported_flags +
      [int64]$Parser.unknown_definition + [int64]$Parser.buffer.Count
  [int64]$elapsedUs = if ($lastParamUs -ge $MeasurementStartUs) {
    $lastParamUs - $MeasurementStartUs
  } else {-1}
  [double]$elapsedMs = if ($elapsedUs -ge 0) {
    $elapsedUs / 1000.0
  } else {[double]::PositiveInfinity}
  $strictData = $parameterFrames.Count -eq 932 -and $missing -eq 0 -and
      $duplicate -eq 0 -and $outOfOrder -eq 0 -and
      $outOfRange -eq 0 -and $wrongSource -eq 0 -and
      $countMismatch -eq 0 -and $badPayload -eq 0 -and
      $invalidParamId -eq 0 -and $duplicateParamId -eq 0 -and
      $byteExactMismatch -eq 0 -and $parserErrors -eq 0
  $acceptance = Get-HighSpeedReplayAcceptance $strictData `
      ($heartbeat.result -ceq 'PASS') $elapsedUs
  return [pscustomobject][ordered]@{
    result=[string]$acceptance.result
    data_result=[string]$acceptance.data_result
    heartbeat_result=[string]$acceptance.heartbeat_result
    expected=932
    parameter_frames=$parameterFrames.Count
    unique=932 - $missing
    missing=$missing
    duplicate=$duplicate
    out_of_order=$outOfOrder
    out_of_range=$outOfRange
    wrong_source=$wrongSource
    count_mismatch=$countMismatch
    bad_payload=$badPayload
    invalid_param_id=$invalidParamId
    duplicate_param_id=$duplicateParamId
    byte_exact_mismatch=$byteExactMismatch
    parser=[pscustomobject][ordered]@{
      total_bytes=[int64]$Parser.total_bytes
      valid_frames=[int64]$Parser.valid_frames
      noise_bytes=[int64]$Parser.noise_bytes
      bad_lengths=[int64]$Parser.bad_length
      bad_crc=[int64]$Parser.bad_crc
      unsupported_flags=[int64]$Parser.unsupported_flags
      unknown_definition=[int64]$Parser.unknown_definition
      partial_bytes=[int]$Parser.buffer.Count
    }
    first_param_us=$firstParamUs
    last_param_us=$lastParamUs
    request_to_last_us=$elapsedUs
    request_to_last_ms=$elapsedMs
    throughput_parameters_per_second=if ($elapsedMs -gt 0 -and
        -not [double]::IsInfinity($elapsedMs)) {932000.0 / $elapsedMs} else {0}
    target_30s=[string]$acceptance.target_30s
    target_10s=[string]$acceptance.target_10s
    target_30s_hard_gate=[bool]$acceptance.target_30s_hard_gate
    target_10s_hard_gate=[bool]$acceptance.target_10s_hard_gate
    heartbeat=$heartbeat
  }
}

function Assert-UsbUartElectricalAttestation([string]$Attestation) {
  Assert-Condition ($Attestation -ceq
      'USB_UART_IS_3V3_TTL_VCC_DISCONNECTED_GND_COMMON') `
      ('USB-UART safety attestation absent: use 3.3 V TTL, leave VCC ' +
       'disconnected, share GND; 5 V TX is forbidden.')
}

function Assert-LiveArguments {
  $required = [ordered]@{
    GroundPort=$GroundPort
    GroundPnpDeviceId=$GroundPnpDeviceId
    GroundParentDeviceId=$GroundParentDeviceId
    GroundVid=$GroundVid
    GroundPid=$GroundPid
    PixhawkFixturePort=$PixhawkFixturePort
    PixhawkFixturePnpDeviceId=$PixhawkFixturePnpDeviceId
    PixhawkFixtureParentDeviceId=$PixhawkFixtureParentDeviceId
    PixhawkFixtureVid=$PixhawkFixtureVid
    PixhawkFixturePid=$PixhawkFixturePid
    PixhawkIsolationAttestation=$PixhawkIsolationAttestation
    UsbUartElectricalAttestation=$UsbUartElectricalAttestation
  }
  foreach ($entry in $required.GetEnumerator()) {
    Assert-Condition (-not [string]::IsNullOrWhiteSpace(
        [string]$entry.Value)) "Live input $($entry.Key) is mandatory."
  }
  Assert-Condition (-not $GroundPort.Equals(
      $PixhawkFixturePort,[StringComparison]::OrdinalIgnoreCase)) `
      'GroundPort and PixhawkFixturePort must be distinct.'
  Assert-Condition ($PixhawkIsolationAttestation -ceq
      'PIXHAWK_TELEM1_D6_D7_AND_USB_DISCONNECTED') `
      'Pixhawk coexistence is forbidden; exact isolation attestation absent.'
  Assert-UsbUartElectricalAttestation $UsbUartElectricalAttestation
  Assert-Condition ($GroundVid -match '^[0-9A-Fa-f]{4}$' -and
      $GroundPid -match '^[0-9A-Fa-f]{4}$' -and
      $PixhawkFixtureVid -match '^[0-9A-Fa-f]{4}$' -and
      $PixhawkFixturePid -match '^[0-9A-Fa-f]{4}$') `
      'VID/PID values must be four hexadecimal digits.'
}

function Assert-NoCompetingProcessRecords(
    [AllowNull()][object[]]$Records) {
  if ($null -eq $Records -or $Records.Count -eq 0) {
    return
  }
  $names = @($Records | ForEach-Object {
    $property = $_.PSObject.Properties['ProcessName']
    if ($null -eq $property -or
        [string]::IsNullOrWhiteSpace([string]$property.Value)) {
      '<unknown-process>'
    } else {
      [string]$property.Value
    }
  })
  throw "Competing serial client present: $($names -join ',')"
}

function Assert-NoCompetingClients {
  $script:ExternalActions.process_inventory_queried = $true
  $blocked = @('MissionPlanner','QGroundControl','mavproxy','putty',
      'ttermpro','coolterm','arduino-ide','arduino-cli')
  $found = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $blocked -contains $_.ProcessName
  })
  Assert-NoCompetingProcessRecords $found
}

function Assert-PixhawkIsolated {
  Assert-Condition ($PixhawkIsolationAttestation -ceq
      'PIXHAWK_TELEM1_D6_D7_AND_USB_DISCONNECTED') `
      'Pixhawk TELEM1 D6/D7 and USB must be physically disconnected.'
  $script:ExternalActions.pnp_queried = $true
  $present = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
    (($_.FriendlyName -as [string]) -match 'Pixhawk|ArduPilot|Cube') -or
    (($_.InstanceId -as [string]) -match 'Pixhawk|ArduPilot')
  })
  if ($present.Count -ne 0) {
    throw ('Detected Pixhawk/ArduPilot/Cube USB/PnP coexistence: ' +
        (($present | ForEach-Object {$_.InstanceId}) -join ','))
  }
  return [pscustomobject][ordered]@{
    operator_attestation=$PixhawkIsolationAttestation
    usb_uart_electrical_attestation=$UsbUartElectricalAttestation
    five_volt_tx_forbidden=$true
    fixture_vcc_must_be_disconnected=$true
    common_ground_required=$true
    detectable_pixhawk_usb_count=0
    limitation=('Software cannot detect an externally powered TELEM wire; ' +
        'the exact operator attestation remains mandatory.')
  }
}

function Assert-ExplicitPortIdentity([string]$Role,[string]$Port,
    [string]$PnpDeviceId,[string]$ParentDeviceId,[string]$Vid,
    [string]$DevicePid) {
  $script:ExternalActions.com_ports_enumerated = $true
  $script:ExternalActions.pnp_queried = $true
  $rows = @(Get-CimInstance Win32_SerialPort | Where-Object {
    [string]$_.DeviceID -ieq $Port
  })
  Assert-Condition ($rows.Count -eq 1) `
      "$Role port $Port must resolve to exactly one Win32_SerialPort row."
  $row = $rows[0]
  Assert-Condition ([string]$row.PNPDeviceID -ieq $PnpDeviceId) `
      "$Role PNPDeviceID mismatch."
  $parent = Get-PnpDeviceProperty -InstanceId $row.PNPDeviceID `
      -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop
  Assert-Condition ([string]$parent.Data -ieq $ParentDeviceId) `
      "$Role parent device identity mismatch."
  $expectedToken = "VID_$($Vid.ToUpperInvariant())&PID_$($DevicePid.ToUpperInvariant())"
  Assert-Condition ($row.PNPDeviceID.ToUpperInvariant().Contains(
      $expectedToken)) "$Role VID/PID mismatch."
  return [pscustomobject][ordered]@{
    role=$Role;port=[string]$row.DeviceID
    pnp_device_id=[string]$row.PNPDeviceID
    parent_device_id=[string]$parent.Data
    vid=$Vid.ToUpperInvariant();pid=$DevicePid.ToUpperInvariant()
    caption=[string]$row.Caption;status=[string]$row.Status
  }
}

function New-ConfiguredSerial([string]$Port) {
  $serial = [IO.Ports.SerialPort]::new()
  $serial.PortName = $Port
  $serial.BaudRate = 57600
  $serial.DataBits = 8
  $serial.Parity = [IO.Ports.Parity]::None
  $serial.StopBits = [IO.Ports.StopBits]::One
  $serial.Handshake = [IO.Ports.Handshake]::None
  $serial.DtrEnable = $false
  $serial.RtsEnable = $false
  $serial.ReadTimeout = 20
  $serial.WriteTimeout = 2000
  $serial.ReadBufferSize = 65536
  $serial.WriteBufferSize = 65536
  return $serial
}

function Read-AvailableSerial([IO.Ports.SerialPort]$Serial,
    [IO.FileStream]$Raw,[object]$Parser,[Diagnostics.Stopwatch]$Clock) {
  [int]$total = 0
  while ($Serial.BytesToRead -gt 0) {
    [int]$available = [Math]::Min($Serial.BytesToRead,4096)
    [byte[]]$buffer = New-Object byte[] $available
    [int]$read = $Serial.Read($buffer,0,$buffer.Length)
    if ($read -le 0) { break }
    if ($read -ne $buffer.Length) {
      [byte[]]$actual = New-Object byte[] $read
      [Array]::Copy($buffer,$actual,$read)
      $buffer = $actual
    }
    $Raw.Write($buffer,0,$buffer.Length)
    [int64]$elapsedUs = [int64][Math]::Round(
        $Clock.ElapsedTicks * 1000000.0 / [Diagnostics.Stopwatch]::Frequency)
    Add-MavlinkBytes $Parser $buffer $elapsedUs
    $total += $read
  }
  return $total
}

function Get-ElapsedUs([Diagnostics.Stopwatch]$Clock) {
  return [int64][Math]::Round(
      $Clock.ElapsedTicks * 1000000.0 / [Diagnostics.Stopwatch]::Frequency)
}

function Write-TimelineRecord([IO.StreamWriter]$Writer,[object]$Value) {
  $Writer.WriteLine((ConvertTo-Json $Value -Compress -Depth 8))
  $Writer.Flush()
}

function Write-GroundFrameLedgerRecord([IO.StreamWriter]$Writer,
    [object]$Record,[int64]$Ordinal) {
  if (-not $Record.valid) { return }
  $Writer.WriteLine((ConvertTo-Json ([pscustomobject][ordered]@{
    valid_frame_ordinal=$Ordinal
    ground_receive_elapsed_us=[int64]$Record.elapsed_us
    version=[int]$Record.version
    message_id=[int]$Record.message_id
    sequence=[int]$Record.sequence
    system_id=[int]$Record.system_id
    component_id=[int]$Record.component_id
    payload_length=[int]$Record.payload_length
    raw_bytes=([byte[]]$Record.raw).Length
    raw_sha256=[string]$Record.raw_sha256
  }) -Compress))
  $Writer.Flush()
}

function Invoke-FullPathReplay([object[]]$FixtureFrames,
    [object]$GroundIdentity,[object]$FixtureIdentity) {
  [byte[]]$request = New-ExactParamRequestList
  $groundParser = New-MavlinkParser 'ground_host_rx'
  $d6Parser = New-MavlinkParser 'vehicle_d6_tx'
  $groundRawPath = Join-Path $script:Evidence 'ground.raw.bin'
  $d6RawPath = Join-Path $script:Evidence 'vehicle_d6.raw.bin'
  $timelinePath = Join-Path $script:Evidence 'tx_timeline.jsonl'
  $groundFrameLedgerPath = Join-Path $script:Evidence `
      'ground_frame_ledger.jsonl'
  $groundIndexLedgerPath = Join-Path $script:Evidence `
      'ground_param_index_ledger.jsonl'
  [IO.File]::WriteAllBytes(
      (Join-Path $script:Evidence 'request_fixture_exact_once.bin'),$request)
  $groundRaw = [IO.FileStream]::new($groundRawPath,[IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,[IO.FileShare]::Read,65536,
      [IO.FileOptions]::WriteThrough)
  $d6Raw = [IO.FileStream]::new($d6RawPath,[IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,[IO.FileShare]::Read,65536,
      [IO.FileOptions]::WriteThrough)
  $timeline = [IO.StreamWriter]::new($timelinePath,$false,$utf8,65536)
  $groundFrameLedger = [IO.StreamWriter]::new(
      $groundFrameLedgerPath,$false,$utf8,65536)
  $groundIndexLedger = [IO.StreamWriter]::new(
      $groundIndexLedgerPath,$false,$utf8,65536)
  $groundSerial = New-ConfiguredSerial $GroundIdentity.port
  $fixtureSerial = New-ConfiguredSerial $FixtureIdentity.port
  $clock = [Diagnostics.Stopwatch]::new()
  [int]$request_writes = 0
  [int]$d6FrameCursor = 0
  [int]$groundFrameCursor = 0
  [int]$exactD6RequestCount = 0
  [int]$paramIndex = 0
  [int]$nextGroundParamIndex = 0
  [int64]$groundValidFrameOrdinal = 0
  [int64]$heartbeatOrdinal = 0
  [int64]$maxScheduleSlipUs = 0
  [int64]$replayEpochUs = -1
  [int64]$lastIndexGroundUs = -1
  [int64]$postCompletionHeartbeatUs = -1
  [int64]$d6PartialSinceUs = -1
  [int64]$groundPartialSinceUs = -1
  [int64[]]$paramWriteStartUs = New-Object 'int64[]' 932
  for ($slot = 0; $slot -lt 932; ++$slot) {
    $paramWriteStartUs[$slot] = -1
  }
  $perIndexLatencies = [Collections.ArrayList]::new()
  try {
    $fixtureSerial.Open()
    $groundSerial.Open()
    $script:ExternalActions.com_ports_opened = $true
    Start-Sleep -Milliseconds 500
    $fixtureSerial.DiscardInBuffer()
    $groundSerial.DiscardInBuffer()
    $clock.Start()

    [int64]$requestWriteUs = Get-ElapsedUs $clock
    $groundSerial.Write($request,0,$request.Length)
    $script:ExternalActions.serial_bytes_written = $true
    ++$request_writes
    Write-TimelineRecord $timeline ([pscustomobject][ordered]@{
      kind='GROUND_PARAM_REQUEST_LIST';ordinal=0;due_us=$requestWriteUs
      write_start_us=$requestWriteUs;write_end_us=(Get-ElapsedUs $clock)
      bytes=14;sha256=Get-ByteSha $request
    })
    if ($request_writes -ne 1) {
      throw "request_writes must equal one, got $request_writes"
    }

    $gateDeadline = [int64]$requestWriteUs +
        ([int64]$D6RequestTimeoutSeconds * 1000000)
    $d6_exact_request_observed = $false
    while (-not $d6_exact_request_observed) {
      [void](Read-AvailableSerial $fixtureSerial $d6Raw $d6Parser $clock)
      [void](Read-AvailableSerial $groundSerial $groundRaw $groundParser $clock)
      [int64]$gateNowUs = Get-ElapsedUs $clock
      Assert-ParserRuntimeClean $d6Parser $gateNowUs `
          ([ref]$d6PartialSinceUs) 'D6'
      Assert-ParserRuntimeClean $groundParser $gateNowUs `
          ([ref]$groundPartialSinceUs) 'Ground'
      Assert-D6ReplayFenceState $d6Parser ([ref]$d6FrameCursor) $request `
          ([ref]$exactD6RequestCount) ([ref]$d6_exact_request_observed) `
          ([ref]$replayEpochUs)
      while ($groundFrameCursor -lt $groundParser.frames.Count) {
        $frame = $groundParser.frames[$groundFrameCursor++]
        if ($frame.valid) {
          Write-GroundFrameLedgerRecord $groundFrameLedger $frame `
              $groundValidFrameOrdinal
          ++$groundValidFrameOrdinal
        }
        [void](Assert-GroundFrameStrictOnline $frame `
            ([ref]$nextGroundParamIndex) $FixtureFrames $false)
      }
      if ($gateNowUs -gt $gateDeadline) {
        throw 'D6 request timeout before exact 14-byte PARAM_REQUEST_LIST.'
      }
      if (-not $d6_exact_request_observed) { Start-Sleep -Milliseconds 1 }
    }

    # These absolute deadlines are initialized only after the exact D6 fence.
    [int64]$nextParamDueUs = $replayEpochUs +
        ([int64]$paramIndex * $ParamPeriodUs)
    [int64]$nextHeartbeatDueUs = $replayEpochUs +
        ($heartbeatOrdinal * $HeartbeatPeriodUs)
    [int64]$measurementDeadlineUs = $requestWriteUs +
        ([int64]$MeasurementTimeoutSeconds * 1000000)
    while ($true) {
      [void](Read-AvailableSerial $fixtureSerial $d6Raw $d6Parser $clock)
      [void](Read-AvailableSerial $groundSerial $groundRaw $groundParser $clock)
      [int64]$nowUs = Get-ElapsedUs $clock
      # All newly observable anomalies are checked before the next scheduled
      # write. D7 writes stop immediately by throwing into the close-only
      # finally block; no remaining replay frames are sent.
      Assert-ParserRuntimeClean $d6Parser $nowUs `
          ([ref]$d6PartialSinceUs) 'D6'
      Assert-ParserRuntimeClean $groundParser $nowUs `
          ([ref]$groundPartialSinceUs) 'Ground'
      Assert-D6ReplayFenceState $d6Parser ([ref]$d6FrameCursor) $request `
          ([ref]$exactD6RequestCount) ([ref]$d6_exact_request_observed) `
          ([ref]$replayEpochUs)
      while ($groundFrameCursor -lt $groundParser.frames.Count) {
        $frame = $groundParser.frames[$groundFrameCursor++]
        if ($frame.valid) {
          Write-GroundFrameLedgerRecord $groundFrameLedger $frame `
              $groundValidFrameOrdinal
          ++$groundValidFrameOrdinal
        }
        [int]$wireIndex = Assert-GroundFrameStrictOnline $frame `
            ([ref]$nextGroundParamIndex) $FixtureFrames $true
        if ($wireIndex -ge 0) {
          Assert-Condition ($paramWriteStartUs[$wireIndex] -ge 0) `
              "Ground index $wireIndex arrived before its D7 write."
          [int64]$latencyUs = [int64]$frame.elapsed_us -
              $paramWriteStartUs[$wireIndex]
          Assert-Condition ($latencyUs -ge 0) `
              "Negative D7-to-Ground latency at index $wireIndex."
          [void]$perIndexLatencies.Add($latencyUs)
          Write-TimelineRecord $groundIndexLedger ([pscustomobject][ordered]@{
            param_index=$wireIndex
            d7_write_start_us=$paramWriteStartUs[$wireIndex]
            ground_receive_elapsed_us=[int64]$frame.elapsed_us
            d7_to_ground_latency_us=$latencyUs
            raw_sha256=[string]$frame.raw_sha256
          })
          if ($wireIndex -eq 931 -and $lastIndexGroundUs -lt 0) {
            $lastIndexGroundUs = [int64]$frame.elapsed_us
          }
        } elseif ($frame.valid -and $frame.message_id -eq 0 -and
            $frame.system_id -eq 1 -and $frame.component_id -eq 1 -and
            $lastIndexGroundUs -ge 0 -and
            $frame.elapsed_us -gt $lastIndexGroundUs -and
            $postCompletionHeartbeatUs -lt 0) {
          $postCompletionHeartbeatUs = [int64]$frame.elapsed_us
        }
      }
      $wrote = $false
      if ($nextHeartbeatDueUs -le $nowUs -and
          ($paramIndex -ge 932 -or $nextHeartbeatDueUs -le $nextParamDueUs)) {
        [byte[]]$heartbeat = New-HeartbeatFrame ([byte]($heartbeatOrdinal -band 0xFF))
        [int64]$writeStartUs = Get-ElapsedUs $clock
        $fixtureSerial.Write($heartbeat,0,$heartbeat.Length)
        [int64]$writeEndUs = Get-ElapsedUs $clock
        [int64]$slipUs = $writeStartUs - $nextHeartbeatDueUs
        if ($slipUs -gt $maxScheduleSlipUs) { $maxScheduleSlipUs = $slipUs }
        Write-TimelineRecord $timeline ([pscustomobject][ordered]@{
          kind='D7_HEARTBEAT';ordinal=$heartbeatOrdinal
          due_us=$nextHeartbeatDueUs;write_start_us=$writeStartUs
          write_end_us=$writeEndUs;schedule_slip_us=$slipUs
          bytes=$heartbeat.Length;sha256=Get-ByteSha $heartbeat
        })
        ++$heartbeatOrdinal
        $nextHeartbeatDueUs = $replayEpochUs +
            ($heartbeatOrdinal * $HeartbeatPeriodUs)
        $wrote = $true
      } elseif ($paramIndex -lt 932 -and $nextParamDueUs -le $nowUs) {
        [byte[]]$parameter = $FixtureFrames[$paramIndex]
        [int64]$writeStartUs = Get-ElapsedUs $clock
        $fixtureSerial.Write($parameter,0,$parameter.Length)
        $paramWriteStartUs[$paramIndex] = $writeStartUs
        [int64]$writeEndUs = Get-ElapsedUs $clock
        [int64]$slipUs = $writeStartUs - $nextParamDueUs
        if ($slipUs -gt $maxScheduleSlipUs) { $maxScheduleSlipUs = $slipUs }
        Write-TimelineRecord $timeline ([pscustomobject][ordered]@{
          kind='D7_PARAM_VALUE';ordinal=$paramIndex
          due_us=$nextParamDueUs;write_start_us=$writeStartUs
          write_end_us=$writeEndUs;schedule_slip_us=$slipUs
          bytes=$parameter.Length;sha256=Get-ByteSha $parameter
        })
        ++$paramIndex
        $nextParamDueUs = $replayEpochUs +
            ([int64]$paramIndex * $ParamPeriodUs)
        $wrote = $true
      }

      # Capture for a full 2.5 s after index 931 to expose delayed duplicates.
      if ($paramIndex -eq 932 -and $lastIndexGroundUs -ge 0 -and
          $postCompletionHeartbeatUs -ge 0 -and
          $nowUs - $lastIndexGroundUs -ge $HeartbeatLimitUs) {
        break
      }
      if ($nowUs -gt $measurementDeadlineUs) {
        throw "Measurement timeout after $MeasurementTimeoutSeconds seconds."
      }
      if (-not $wrote) { Start-Sleep -Milliseconds 1 }
    }
    [void](Read-AvailableSerial $fixtureSerial $d6Raw $d6Parser $clock)
    [void](Read-AvailableSerial $groundSerial $groundRaw $groundParser $clock)
    [int64]$finalNowUs = Get-ElapsedUs $clock
    Assert-ParserRuntimeClean $d6Parser $finalNowUs `
        ([ref]$d6PartialSinceUs) 'D6'
    Assert-ParserRuntimeClean $groundParser $finalNowUs `
        ([ref]$groundPartialSinceUs) 'Ground'
    Assert-D6ReplayFenceState $d6Parser ([ref]$d6FrameCursor) $request `
        ([ref]$exactD6RequestCount) ([ref]$d6_exact_request_observed) `
        ([ref]$replayEpochUs)
    while ($groundFrameCursor -lt $groundParser.frames.Count) {
      $frame = $groundParser.frames[$groundFrameCursor++]
      if ($frame.valid) {
        Write-GroundFrameLedgerRecord $groundFrameLedger $frame `
            $groundValidFrameOrdinal
        ++$groundValidFrameOrdinal
      }
      [int]$wireIndex = Assert-GroundFrameStrictOnline $frame `
          ([ref]$nextGroundParamIndex) $FixtureFrames $true
      if ($wireIndex -ge 0) {
        throw "Ground PARAM_VALUE arrived after completion drain index=$wireIndex."
      }
    }
    $groundRaw.Flush($true)
    $d6Raw.Flush($true)
    $groundFrameLedger.Flush()
    $groundIndexLedger.Flush()
    $capture = Get-StrictCaptureResult $groundParser $FixtureFrames `
        $requestWriteUs
    $capture | Add-Member -NotePropertyName completion_epoch `
        -NotePropertyValue 'GROUND_REQUEST_WRITE' -Force
    $capture | Add-Member -NotePropertyName ground_request_to_last_ms `
        -NotePropertyValue ([double]$capture.request_to_last_ms) -Force
    $capture | Add-Member -NotePropertyName d6_request_to_last_ms `
        -NotePropertyValue (($capture.last_param_us - $replayEpochUs) / 1000.0) `
        -Force
    $injectionCompleteUs = $replayEpochUs + (931 * $ParamPeriodUs)
    $injectionTimingPass = $paramIndex -eq 932 -and
        $maxScheduleSlipUs -le 10000
    $d6Health = Get-ParserHealth $d6Parser
    $groundHealth = Get-ParserHealth $groundParser
    $sortedLatencies = @($perIndexLatencies | Sort-Object)
    $latencyComplete = $sortedLatencies.Count -eq 932
    $latencyMetrics = [pscustomobject][ordered]@{
      result=if ($latencyComplete) {'PASS'} else {'FAIL'}
      count=$sortedLatencies.Count
      minimum_us=if ($latencyComplete) {[int64]$sortedLatencies[0]} else {$null}
      maximum_us=if ($latencyComplete) {[int64]$sortedLatencies[-1]} else {$null}
      mean_us=if ($latencyComplete) {
        [double](($sortedLatencies | Measure-Object -Average).Average)
      } else {$null}
      p95_us=if ($latencyComplete) {
        [int64]$sortedLatencies[[int][Math]::Ceiling(0.95 * 932) - 1]
      } else {$null}
      per_index_latency_basis=(
          'ground_param_index_ledger.jsonl joins param_index and the shared ' +
          'Stopwatch epoch: d7_write_start_us -> ground_receive_elapsed_us')
    }
    $strict = $capture.result -ceq 'PASS' -and
        $exactD6RequestCount -eq 1 -and $request_writes -eq 1 -and
        $injectionTimingPass -and $d6Health.result -ceq 'PASS' -and
        $groundHealth.result -ceq 'PASS' -and $latencyComplete
    return [pscustomobject][ordered]@{
      result=if ($strict) {'PASS'} else {'FAIL'}
      mode='LIVE_TWO_PORT_THREE_ENDPOINT'
      topology=[pscustomobject][ordered]@{
        ground_host_port=$GroundIdentity.port
        fixture_duplex_port=$FixtureIdentity.port
        fixture_rx='Vehicle D6 (sniffer)'
        fixture_tx='Vehicle D7 (replayer)'
        third_usb_uart_required=$false
      }
      request=[pscustomobject][ordered]@{
        bytes=14;hex=$exactRequestHex;request_writes=$request_writes
        d6_exact_request_observed=$d6_exact_request_observed
        d6_exact_request_count=$exactD6RequestCount
        d6_other_list_count=0
        d6_param_request_read_count=0
        request_write_us=$requestWriteUs;d6_observed_us=$replayEpochUs
        ground_to_vehicle_request_latency_ms=
            ($replayEpochUs - $requestWriteUs) / 1000.0
      }
      injection=[pscustomobject][ordered]@{
        param_count=$paramIndex;param_period_us=$ParamPeriodUs
        heartbeat_count=$heartbeatOrdinal
        heartbeat_period_us=$HeartbeatPeriodUs
        absolute_deadlines=$true
        expected_last_param_due_us=$injectionCompleteUs
        maximum_schedule_slip_us=$maxScheduleSlipUs
        timing_limit_us=10000
        result=if ($injectionTimingPass) {'PASS'} else {'FAIL'}
      }
      d6=[pscustomobject][ordered]@{
        d6_parser_result=[string]$d6Health.result
        parser=$d6Health
      }
      ground_capture=$capture
      ground_parser_result=[string]$groundHealth.result
      per_index_latency=$latencyMetrics
      fixture_sequence_policy=$script:SequencePolicy
    }
  } finally {
    try {$timeline.Flush()} catch {}
    try {$timeline.Dispose()} catch {}
    try {$groundFrameLedger.Flush()} catch {}
    try {$groundFrameLedger.Dispose()} catch {}
    try {$groundIndexLedger.Flush()} catch {}
    try {$groundIndexLedger.Dispose()} catch {}
    try {$groundRaw.Flush($true)} catch {}
    try {$groundRaw.Dispose()} catch {}
    try {$d6Raw.Flush($true)} catch {}
    try {$d6Raw.Dispose()} catch {}
    if ($groundSerial.IsOpen) { try {$groundSerial.Close()} catch {} }
    if ($fixtureSerial.IsOpen) { try {$fixtureSerial.Close()} catch {} }
    $groundSerial.Dispose()
    $fixtureSerial.Dispose()
  }
}

function Invoke-OfflineSelfTest {
  # This function intentionally contains no process, CIM/PnP, COM, or device
  # call. It exercises the same parser, fixture, request fence, scheduler model,
  # strict accounting, and heartbeat math used by live mode.
  [byte[]]$request = New-ExactParamRequestList
  Assert-Condition ((-join ($request | ForEach-Object {$_.ToString('X2')})) `
      -ceq $exactRequestHex) 'Exact request self-test failed.'

  $d6 = New-MavlinkParser 'offline_vehicle_d6'
  Add-MavlinkBytes $d6 $request 100000
  [int]$offlineD6Cursor = 0
  [int]$offlineExactCount = 0
  [bool]$offlineGateObserved = $false
  [int64]$offlineReplayEpochUs = -1
  [int64]$offlineD6PartialSinceUs = -1
  Assert-ParserRuntimeClean $d6 100000 `
      ([ref]$offlineD6PartialSinceUs) 'offline D6'
  Assert-D6ReplayFenceState $d6 ([ref]$offlineD6Cursor) $request `
      ([ref]$offlineExactCount) ([ref]$offlineGateObserved) `
      ([ref]$offlineReplayEpochUs)
  $d6Exact = $offlineD6Cursor -eq 1 -and $offlineExactCount -eq 1 -and
      $offlineGateObserved -and $offlineReplayEpochUs -eq 100000
  Assert-Condition $d6Exact 'Offline exact D6 request fence failed.'

  $ground = New-MavlinkParser 'offline_ground'
  $groundBytes = [Collections.Generic.List[byte]]::new()
  $timelineRecords = [Collections.ArrayList]::new()
  [int64]$groundRequestWriteUs = 0
  [int64]$replayEpochUs = 100000
  [int64]$transportUs = 200000
  [int64]$heartbeatOrdinal = 0
  [int64]$nextHeartbeatDueUs = $replayEpochUs
  for ($paramIndex = 0; $paramIndex -lt 932; ++$paramIndex) {
    [int64]$nextParamDueUs = $replayEpochUs +
        ([int64]$paramIndex * $ParamPeriodUs)
    while ($nextHeartbeatDueUs -le $nextParamDueUs) {
      [byte[]]$heartbeat = New-HeartbeatFrame ([byte]($heartbeatOrdinal -band 0xFF))
      Add-MavlinkBytes $ground $heartbeat ($nextHeartbeatDueUs + $transportUs)
      $groundBytes.AddRange($heartbeat)
      [void]$timelineRecords.Add([pscustomobject][ordered]@{
        kind='D7_HEARTBEAT';ordinal=$heartbeatOrdinal
        due_us=$nextHeartbeatDueUs;write_start_us=$nextHeartbeatDueUs
        write_end_us=$nextHeartbeatDueUs;schedule_slip_us=0
      })
      ++$heartbeatOrdinal
      $nextHeartbeatDueUs = $replayEpochUs +
          ($heartbeatOrdinal * $HeartbeatPeriodUs)
    }
    [byte[]]$parameter = $script:FixtureFrames[$paramIndex]
    Add-MavlinkBytes $ground $parameter ($nextParamDueUs + $transportUs)
    $groundBytes.AddRange($parameter)
    [void]$timelineRecords.Add([pscustomobject][ordered]@{
      kind='D7_PARAM_VALUE';ordinal=$paramIndex;due_us=$nextParamDueUs
      write_start_us=$nextParamDueUs;write_end_us=$nextParamDueUs
      schedule_slip_us=0
    })
  }
  [int64]$lastParamDueUs = $replayEpochUs + (931 * $ParamPeriodUs)
  while ($nextHeartbeatDueUs -le $lastParamDueUs + 3000000) {
    [byte[]]$heartbeat = New-HeartbeatFrame ([byte]($heartbeatOrdinal -band 0xFF))
    Add-MavlinkBytes $ground $heartbeat ($nextHeartbeatDueUs + $transportUs)
    $groundBytes.AddRange($heartbeat)
    [void]$timelineRecords.Add([pscustomobject][ordered]@{
      kind='D7_HEARTBEAT';ordinal=$heartbeatOrdinal
      due_us=$nextHeartbeatDueUs;write_start_us=$nextHeartbeatDueUs
      write_end_us=$nextHeartbeatDueUs;schedule_slip_us=0
    })
    ++$heartbeatOrdinal
    $nextHeartbeatDueUs = $replayEpochUs +
        ($heartbeatOrdinal * $HeartbeatPeriodUs)
  }
  $ideal = Get-StrictCaptureResult $ground $script:FixtureFrames `
      $groundRequestWriteUs
  $ideal | Add-Member -NotePropertyName completion_epoch `
      -NotePropertyValue 'GROUND_REQUEST_WRITE' -Force
  $ideal | Add-Member -NotePropertyName ground_request_to_last_ms `
      -NotePropertyValue ([double]$ideal.request_to_last_ms) -Force
  $ideal | Add-Member -NotePropertyName d6_request_to_last_ms `
      -NotePropertyValue (($ideal.last_param_us - $replayEpochUs) / 1000.0) `
      -Force
  $groundRequestEpochIncludesUplink =
      [Math]::Abs(($ideal.ground_request_to_last_ms -
       $ideal.d6_request_to_last_ms) - 100.0) -lt 0.001
  Assert-Condition ($ideal.result -ceq 'PASS' -and
      $ideal.data_result -ceq 'PASS' -and
      $ideal.heartbeat_result -ceq 'PASS' -and
      $ideal.target_30s -ceq 'PASS' -and
      $ideal.target_10s -ceq 'FAIL' -and
      $groundRequestEpochIncludesUplink) `
      'Ideal ground capture self-test failed.'

  $target30Boundary = Get-HighSpeedReplayAcceptance $true $true 30000000
  Assert-Condition ($target30Boundary.result -ceq 'PASS' -and
      $target30Boundary.target_30s -ceq 'PASS') `
      '30,000,000-us hard-gate boundary did not pass.'
  $target30Overrun = Get-HighSpeedReplayAcceptance $true $true 30000001
  Assert-Condition ($target30Overrun.data_result -ceq 'PASS' -and
      $target30Overrun.heartbeat_result -ceq 'PASS' -and
      $target30Overrun.target_30s -ceq 'FAIL' -and
      $target30Overrun.result -ceq 'FAIL') `
      '30,000,001-us hard-gate negative did not fail overall.'
  $target10Stretch = Get-HighSpeedReplayAcceptance $true $true 10000001
  Assert-Condition ($target10Stretch.target_10s -ceq 'FAIL' -and
      $target10Stretch.target_30s -ceq 'PASS' -and
      $target10Stretch.result -ceq 'PASS') `
      '10-second stretch metric incorrectly gated overall acceptance.'
  $target30Missing = Get-HighSpeedReplayAcceptance $true $true (-1)
  Assert-Condition (-not $target30Missing.completion_observed -and
      $target30Missing.target_30s -ceq 'FAIL' -and
      $target30Missing.result -ceq 'FAIL') `
      'Missing completion did not fail the 30-second hard gate.'

  $missingParser = New-MavlinkParser 'offline_missing_index'
  for ($index = 0; $index -lt 932; ++$index) {
    if ($index -ne 500) {
      Add-MavlinkBytes $missingParser ([byte[]]$script:FixtureFrames[$index]) `
          ($replayEpochUs + $index * $ParamPeriodUs)
    }
  }
  Add-MavlinkBytes $missingParser (New-HeartbeatFrame 1) $replayEpochUs
  Add-MavlinkBytes $missingParser (New-HeartbeatFrame 2) `
      ($lastParamDueUs + 1000000)
  $missing = Get-StrictCaptureResult $missingParser $script:FixtureFrames `
      $replayEpochUs
  Assert-Condition ($missing.result -ceq 'FAIL' -and $missing.missing -eq 1) `
      'Missing-index negative self-test did not fail closed.'

  [byte[]]$corrupt = (New-HeartbeatFrame 9).Clone()
  $corrupt[12] = $corrupt[12] -bxor 1
  $corruptParser = New-MavlinkParser 'offline_crc_tamper'
  Add-MavlinkBytes $corruptParser $corrupt 1
  Assert-Condition ($corruptParser.bad_crc -eq 1) `
      'CRC negative self-test did not fail closed.'

  $heartbeatGapBoundary = Get-HeartbeatSla `
      ([int64[]]@(0,2500001)) 0 2500000
  Assert-Condition ($heartbeatGapBoundary.result -ceq 'FAIL') `
      'heartbeat_gap_boundary at 2500001 us did not fail.'
  $firstHeartbeatPreParamGap = Get-HeartbeatSla `
      ([int64[]]@(2500001,3500001)) 0 3000000
  Assert-Condition ($firstHeartbeatPreParamGap.result -ceq 'FAIL' -and
      $firstHeartbeatPreParamGap.request_to_first_heartbeat_us -eq 2500001) `
      'first PARAM pre-window heartbeat gap at 2500001 us did not fail.'

  [byte[]]$wrongRequest = $request.Clone()
  $wrongRequest[4] = $wrongRequest[4] -bxor 1
  Assert-Condition (-not (Test-ByteEqual $wrongRequest $request)) `
      'D6 request mismatch negative self-test failed.'

  [int]$writes_after_abort = 0
  $preReadParser = New-MavlinkParser 'offline_d6_read_pre_gate'
  Add-MavlinkBytes $preReadParser (New-ParamRequestReadFrame) 1
  [int]$preReadCursor = 0;[int]$preReadExact = 0
  [bool]$preReadGate = $false;[int64]$preReadEpoch = -1
  $preReadCaught = $false
  try {
    Assert-D6ReplayFenceState $preReadParser ([ref]$preReadCursor) $request `
        ([ref]$preReadExact) ([ref]$preReadGate) ([ref]$preReadEpoch)
    ++$writes_after_abort
  } catch {$preReadCaught = $true}
  Assert-Condition ($preReadCaught -and $writes_after_abort -eq 0) `
      'D6 pre-gate PARAM_REQUEST_READ negative did not hard abort.'

  $postReadParser = New-MavlinkParser 'offline_d6_read_post_gate'
  Add-MavlinkBytes $postReadParser $request 1
  [int]$postReadCursor = 0;[int]$postReadExact = 0
  [bool]$postReadGate = $false;[int64]$postReadEpoch = -1
  Assert-D6ReplayFenceState $postReadParser ([ref]$postReadCursor) $request `
      ([ref]$postReadExact) ([ref]$postReadGate) ([ref]$postReadEpoch)
  Add-MavlinkBytes $postReadParser (New-ParamRequestReadFrame) 2
  $postReadCaught = $false
  try {
    Assert-D6ReplayFenceState $postReadParser ([ref]$postReadCursor) $request `
        ([ref]$postReadExact) ([ref]$postReadGate) ([ref]$postReadEpoch)
    ++$writes_after_abort
  } catch {$postReadCaught = $true}
  Assert-Condition ($postReadCaught -and $writes_after_abort -eq 0) `
      'D6 post-gate PARAM_REQUEST_READ negative did not hard abort.'

  $secondListParser = New-MavlinkParser 'offline_d6_second_list'
  Add-MavlinkBytes $secondListParser $request 1
  Add-MavlinkBytes $secondListParser $request 2
  [int]$secondListCursor = 0;[int]$secondListExact = 0
  [bool]$secondListGate = $false;[int64]$secondListEpoch = -1
  $secondListCaught = $false
  try {
    Assert-D6ReplayFenceState $secondListParser ([ref]$secondListCursor) `
        $request ([ref]$secondListExact) ([ref]$secondListGate) `
        ([ref]$secondListEpoch)
    ++$writes_after_abort
  } catch {$secondListCaught = $true}
  Assert-Condition ($secondListCaught -and $secondListExact -eq 1 -and
      $writes_after_abort -eq 0) `
      'D6 second exact PARAM_REQUEST_LIST negative did not hard abort.'

  $noiseParser = New-MavlinkParser 'offline_d6_noise'
  Add-MavlinkBytes $noiseParser ([byte[]]@(0x55)) 1
  [int64]$noisePartial = -1;$noiseCaught = $false
  try {
    Assert-ParserRuntimeClean $noiseParser 1 ([ref]$noisePartial) 'D6'
    ++$writes_after_abort
  } catch {$noiseCaught = $true}
  Assert-Condition ($noiseCaught -and $writes_after_abort -eq 0) `
      'D6 parser noise negative did not hard abort.'

  [byte[]]$badCrcRequest = $request.Clone()
  $badCrcRequest[10] = $badCrcRequest[10] -bxor 1
  $badCrcParser = New-MavlinkParser 'offline_d6_bad_crc'
  Add-MavlinkBytes $badCrcParser $badCrcRequest 1
  [int64]$badCrcPartial = -1;$badCrcCaught = $false
  try {
    Assert-ParserRuntimeClean $badCrcParser 1 ([ref]$badCrcPartial) 'D6'
    ++$writes_after_abort
  } catch {$badCrcCaught = $true}
  Assert-Condition ($badCrcCaught -and $writes_after_abort -eq 0) `
      'D6 parser bad CRC negative did not hard abort.'

  [byte[]]$badLengthFrame = New-Object byte[] 20
  $badLengthFrame[0]=0xFD;$badLengthFrame[1]=8;$badLengthFrame[5]=1
  $badLengthParser = New-MavlinkParser 'offline_d6_bad_length'
  Add-MavlinkBytes $badLengthParser $badLengthFrame 1
  [int64]$badLengthPartial = -1;$badLengthCaught = $false
  try {
    Assert-ParserRuntimeClean $badLengthParser 1 `
        ([ref]$badLengthPartial) 'D6'
    ++$writes_after_abort
  } catch {$badLengthCaught = $true}
  Assert-Condition ($badLengthCaught -and $writes_after_abort -eq 0) `
      'D6 parser bad length negative did not hard abort.'

  [byte[]]$unsupportedFrame = $request.Clone()
  $unsupportedFrame[2] = 2
  $unsupportedParser = New-MavlinkParser 'offline_d6_flags'
  Add-MavlinkBytes $unsupportedParser $unsupportedFrame 1
  [int64]$unsupportedPartial = -1;$unsupportedCaught = $false
  try {
    Assert-ParserRuntimeClean $unsupportedParser 1 `
        ([ref]$unsupportedPartial) 'D6'
    ++$writes_after_abort
  } catch {$unsupportedCaught = $true}
  Assert-Condition ($unsupportedCaught -and $writes_after_abort -eq 0) `
      'D6 parser unsupported flags negative did not hard abort.'

  [byte[]]$unknownFrame = New-Object byte[] 12
  $unknownFrame[0]=0xFD;$unknownFrame[1]=0;$unknownFrame[5]=1
  $unknownFrame[6]=1;$unknownFrame[7]=0xE7;$unknownFrame[8]=0x03
  $unknownParser = New-MavlinkParser 'offline_d6_unknown'
  Add-MavlinkBytes $unknownParser $unknownFrame 1
  [int64]$unknownPartial = -1;$unknownCaught = $false
  try {
    Assert-ParserRuntimeClean $unknownParser 1 ([ref]$unknownPartial) 'D6'
    ++$writes_after_abort
  } catch {$unknownCaught = $true}
  Assert-Condition ($unknownCaught -and $writes_after_abort -eq 0) `
      'D6 parser unknown definition negative did not hard abort.'

  $partialParser = New-MavlinkParser 'offline_d6_partial'
  Add-MavlinkBytes $partialParser ([byte[]]@(0xFD,0x09)) 1
  [int64]$partialSince = -1
  Assert-ParserRuntimeClean $partialParser 1 ([ref]$partialSince) 'D6'
  $partialCaught = $false
  try {
    Assert-ParserRuntimeClean $partialParser 100002 `
        ([ref]$partialSince) 'D6'
    ++$writes_after_abort
  } catch {$partialCaught = $true}
  Assert-Condition ($partialCaught -and $writes_after_abort -eq 0) `
      'D6 parser partial negative did not hard abort.'

  $orderParser = New-MavlinkParser 'offline_ground_order'
  Add-MavlinkBytes $orderParser ([byte[]]$script:FixtureFrames[1]) 1
  [int]$orderExpected = 0;$orderCaught = $false
  try {
    [void](Assert-GroundFrameStrictOnline $orderParser.frames[0] `
        ([ref]$orderExpected) $script:FixtureFrames $true)
    ++$writes_after_abort
  } catch {$orderCaught = $true}
  Assert-Condition ($orderCaught -and $writes_after_abort -eq 0) `
      'Ground online order negative did not hard abort.'

  $electricalCaught = $false
  try {
    Assert-UsbUartElectricalAttestation `
        'USB_UART_IS_5V_TTL_VCC_CONNECTED'
  } catch {$electricalCaught = $true}
  Assert-Condition $electricalCaught `
      'Electrical attestation negative did not fail closed.'

  [object[]]$emptyProcessRecords = @()
  Assert-NoCompetingProcessRecords $emptyProcessRecords
  $singleProcessCaught = $false
  try {
    Assert-NoCompetingProcessRecords @(
      [pscustomobject]@{ProcessName='MissionPlanner'})
  } catch {
    $singleProcessCaught = $_.Exception.Message -match 'MissionPlanner'
  }
  Assert-Condition $singleProcessCaught `
      'Single competing-process negative did not fail closed.'
  $multipleProcessCaught = $false
  try {
    Assert-NoCompetingProcessRecords @(
      [pscustomobject]@{ProcessName='MissionPlanner'},
      [pscustomobject]@{ProcessName='QGroundControl'})
  } catch {
    $multipleProcessCaught = $_.Exception.Message -match 'MissionPlanner' -and
        $_.Exception.Message -match 'QGroundControl'
  }
  Assert-Condition $multipleProcessCaught `
      'Multiple competing-process negative did not fail closed.'

  $groundFrameLedgerText = [Text.StringBuilder]::new()
  $groundIndexLedgerText = [Text.StringBuilder]::new()
  $offlineLatencies = [Collections.ArrayList]::new()
  [int64]$validOrdinal = 0
  foreach ($record in $ground.frames) {
    if (-not $record.valid) { continue }
    [void]$groundFrameLedgerText.AppendLine((ConvertTo-Json `
        ([pscustomobject][ordered]@{
          valid_frame_ordinal=$validOrdinal
          ground_receive_elapsed_us=[int64]$record.elapsed_us
          message_id=[int]$record.message_id
          sequence=[int]$record.sequence
          system_id=[int]$record.system_id
          component_id=[int]$record.component_id
          raw_sha256=[string]$record.raw_sha256
        }) -Compress))
    ++$validOrdinal
    if ($record.message_id -eq 22) {
      [int]$ledgerIndex = [BitConverter]::ToUInt16(
          [byte[]]$record.raw,[int]$record.payload_offset + 6)
      [int64]$writeUs = $replayEpochUs + $ledgerIndex * $ParamPeriodUs
      [int64]$latencyUs = [int64]$record.elapsed_us - $writeUs
      [void]$offlineLatencies.Add($latencyUs)
      [void]$groundIndexLedgerText.AppendLine((ConvertTo-Json `
          ([pscustomobject][ordered]@{
            param_index=$ledgerIndex;d7_write_start_us=$writeUs
            ground_receive_elapsed_us=[int64]$record.elapsed_us
            d7_to_ground_latency_us=$latencyUs
            raw_sha256=[string]$record.raw_sha256
          }) -Compress))
    }
  }
  Assert-Condition ($offlineLatencies.Count -eq 932 -and
      @($offlineLatencies | Where-Object {$_ -ne $transportUs}).Count -eq 0) `
      'Offline per-index latency ledger is not exactly joinable.'

  [IO.File]::WriteAllBytes((Join-Path $script:Evidence 'ground.raw.bin'),
      $groundBytes.ToArray())
  [IO.File]::WriteAllBytes((Join-Path $script:Evidence 'vehicle_d6.raw.bin'),
      $request)
  [IO.File]::WriteAllBytes(
      (Join-Path $script:Evidence 'request_fixture_exact_once.bin'),$request)
  $timelineText = [Text.StringBuilder]::new()
  foreach ($record in $timelineRecords) {
    [void]$timelineText.AppendLine((ConvertTo-Json $record -Compress))
  }
  Write-Durable (Join-Path $script:Evidence 'tx_timeline.jsonl') `
      $timelineText.ToString()
  Write-Durable (Join-Path $script:Evidence 'ground_frame_ledger.jsonl') `
      $groundFrameLedgerText.ToString()
  Write-Durable (Join-Path $script:Evidence `
      'ground_param_index_ledger.jsonl') $groundIndexLedgerText.ToString()

  return [pscustomobject][ordered]@{
    result='PASS'
    mode='OFFLINE_SELF_TEST'
    ideal_ground_capture=$ideal
    d6_exact_request_fence='PASS'
    absolute_25ms_param_schedule='PASS'
    absolute_1hz_heartbeat_schedule='PASS'
    missing_index_negative='PASS'
    crc_tamper_negative='PASS'
    heartbeat_gap_boundary='PASS_REJECTED_2500001_US'
    first_param_pre_window_heartbeat_gap_negative=
        'PASS_REJECTED_REQUEST_TO_FIRST_HB_2500001_US'
    d6_request_mismatch_negative='PASS'
    d6_param_request_read_negative='PASS_PRE_AND_POST_GATE_ABORT'
    d6_second_list_negative='PASS_ABORT'
    d6_parser_noise_negative='PASS_ABORT'
    d6_parser_crc_negative='PASS_ABORT'
    d6_parser_bad_length_negative='PASS_ABORT'
    d6_parser_unsupported_flags_negative='PASS_ABORT'
    d6_parser_unknown_definition_negative='PASS_ABORT'
    d6_parser_partial_negative='PASS_ABORT_AFTER_100000_US'
    ground_online_order_negative='PASS_ABORT'
    writes_after_abort=$writes_after_abort
    electrical_attestation_negative='PASS_REJECTED_5V_AND_VCC'
    empty_process_inventory_regression='PASS_CONTINUED'
    single_process_inventory_negative='PASS_REJECTED'
    multiple_process_inventory_negative='PASS_REJECTED'
    ground_request_epoch_includes_uplink=if (
        $groundRequestEpochIncludesUplink) {'PASS'} else {'FAIL'}
    target_30s_boundary='PASS_ACCEPTED_30000000_US'
    target_30s_overrun_negative='PASS_REJECTED_30000001_US'
    target_30s_missing_negative='PASS_REJECTED_MISSING_COMPLETION'
    target_10s_stretch_non_gate='PASS_AT_10000001_US'
    provenance_unproven=if (
        $script:FirmwareProvenance.result -ceq 'UNPROVEN' -and
        -not $script:FirmwareProvenance.verified -and
        $script:E220ProfileProvenance.result -ceq 'UNPROVEN' -and
        -not $script:E220ProfileProvenance.verified) {'PASS'} else {'FAIL'}
    ground_frame_ledger=[pscustomobject][ordered]@{
      valid_frame_count=$validOrdinal;file='ground_frame_ledger.jsonl'
    }
    ground_param_index_ledger=[pscustomobject][ordered]@{
      index_count=$offlineLatencies.Count
      file='ground_param_index_ledger.jsonl'
    }
    per_index_latency=[pscustomobject][ordered]@{
      count=$offlineLatencies.Count;minimum_us=$transportUs
      maximum_us=$transportUs;mean_us=[double]$transportUs
      per_index_latency_basis='shared offline Stopwatch epoch'
    }
    fixture_sequence_policy=$script:SequencePolicy
    topology=[pscustomobject][ordered]@{
      logical_endpoints=3;physical_serial_ports=2
      third_usb_uart_required=$false
    }
    external_actions=[pscustomobject][ordered]@{
      process_inventory_queried=$false
      pnp_queried=$false
      com_ports_enumerated=$false
      com_ports_opened=$false
      serial_bytes_written=$false
      firmware_write_attempted=$false
      firmware_changed=$false
    }
  }
}

function Complete-Evidence([object]$Summary) {
  if ($script:EvidenceCompleted) { return }
  $Summary | Add-Member -NotePropertyName firmware_provenance `
      -NotePropertyValue $script:FirmwareProvenance -Force
  $Summary | Add-Member -NotePropertyName e220_profile_provenance `
      -NotePropertyValue $script:E220ProfileProvenance -Force
  $Summary | Add-Member -NotePropertyName schema_version `
      -NotePropertyValue 1 -Force
  $Summary | Add-Member -NotePropertyName test_id `
      -NotePropertyValue 'R19-HS-G2-FULL-PATH-REPLAY-HIL-001' -Force
  $Summary | Add-Member -NotePropertyName started_utc `
      -NotePropertyValue $startedUtc -Force
  $Summary | Add-Member -NotePropertyName completed_utc `
      -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
  $Summary | Add-Member -NotePropertyName external_actions `
      -NotePropertyValue ([pscustomobject]$script:ExternalActions) -Force
  $summaryPath = Join-Path $script:Evidence 'summary.json'
  Write-DurableJson $summaryPath $Summary

  $artifacts = [Collections.ArrayList]::new()
  foreach ($file in @(Get-ChildItem -LiteralPath $script:Evidence -File `
      -Recurse | Sort-Object FullName)) {
    if ($file.Name -in @('artifact_manifest.json','SHA256SUMS.txt',
        'final_seal.json')) { continue }
    [void]$artifacts.Add([pscustomobject][ordered]@{
      path=$file.FullName.Substring($script:Evidence.Length + 1).
          Replace('\','/')
      bytes=[int64]$file.Length
      sha256=Get-Sha $file.FullName
    })
  }
  $manifest = [pscustomobject][ordered]@{
    schema_version=1;artifact_count=$artifacts.Count;artifacts=@($artifacts)
  }
  $manifestPath = Join-Path $script:Evidence 'artifact_manifest.json'
  Write-DurableJson $manifestPath $manifest
  $sumLines = [Text.StringBuilder]::new()
  foreach ($artifact in $artifacts) {
    [void]$sumLines.AppendLine("$($artifact.sha256) *$($artifact.path)")
  }
  [void]$sumLines.AppendLine("$(Get-Sha $manifestPath) *artifact_manifest.json")
  $sumsPath = Join-Path $script:Evidence 'SHA256SUMS.txt'
  Write-Durable $sumsPath $sumLines.ToString()
  $seal = [pscustomobject][ordered]@{
    schema_version=1
    result=[string]$Summary.result
    summary_sha256=Get-Sha $summaryPath
    artifact_manifest_sha256=Get-Sha $manifestPath
    sha256sums_sha256=Get-Sha $sumsPath
    sealed_utc=[DateTime]::UtcNow.ToString('o')
  }
  Write-DurableJson (Join-Path $script:Evidence 'final_seal.json') $seal
  $script:EvidenceCompleted = $true
}

Initialize-EvidenceRoot
$pinnedInputs = $null
try {
  $pinnedInputs = Assert-PinnedInputs
  if ($OfflineSelfTest.IsPresent) {
    Assert-Condition (-not $Execute.IsPresent) `
        'OfflineSelfTest and Execute are mutually exclusive.'
    $offline = Invoke-OfflineSelfTest
    Complete-Evidence $offline
    $offline | ConvertTo-Json -Depth 16
    return
  }

  Assert-Condition $Execute.IsPresent `
      'Live hardware access requires explicit -Execute.'
  Assert-LiveArguments
  Assert-NoCompetingClients
  $script:Preflight.process_gate = [pscustomobject][ordered]@{
    result='PASS';competing_process_count=0
  }
  try {
    $isolation = Assert-PixhawkIsolated
    $script:Preflight.pixhawk_isolation = [pscustomobject][ordered]@{
      result='PASS';detail=$isolation
    }
  } catch {
    $script:Preflight.pixhawk_isolation = [pscustomobject][ordered]@{
      result='FAIL';failure=$_.Exception.Message
    }
    throw
  }
  try {
    $groundIdentity = Assert-ExplicitPortIdentity 'Ground' $GroundPort `
        $GroundPnpDeviceId $GroundParentDeviceId $GroundVid $GroundPid
    $script:Preflight.ground_identity = [pscustomobject][ordered]@{
      result='PASS';identity=$groundIdentity;failure=''
    }
  } catch {
    $script:Preflight.ground_identity = [pscustomobject][ordered]@{
      result='FAIL';failure=$_.Exception.Message
    }
    throw
  }
  try {
    $fixtureIdentity = Assert-ExplicitPortIdentity 'PixhawkFixture' `
        $PixhawkFixturePort $PixhawkFixturePnpDeviceId `
        $PixhawkFixtureParentDeviceId $PixhawkFixtureVid $PixhawkFixturePid
    $script:Preflight.pixhawk_fixture_identity = [pscustomobject][ordered]@{
      result='PASS';identity=$fixtureIdentity;failure=''
    }
  } catch {
    $script:Preflight.pixhawk_fixture_identity = [pscustomobject][ordered]@{
      result='FAIL';failure=$_.Exception.Message
    }
    throw
  }
  $measurement = Invoke-FullPathReplay $script:FixtureFrames `
      $groundIdentity $fixtureIdentity
  $summary = [pscustomobject][ordered]@{
    result=[string]$measurement.result
    mode='LIVE'
    measurement=$measurement
    identities=[pscustomobject][ordered]@{
      ground=$groundIdentity;pixhawk_fixture=$fixtureIdentity
    }
    pixhawk_isolation=$isolation
    preflight=[pscustomobject]$script:Preflight
    immutable_inputs=$pinnedInputs
    firmware_write_attempted=$false
    production_firmware_changed=$false
  }
  Complete-Evidence $summary
  $summary | ConvertTo-Json -Depth 24
  if ($summary.result -ne 'PASS') { exit 1 }
} catch {
  $failure = $_.Exception.Message
  if (-not $script:EvidenceCompleted) {
    $failedSummary = [pscustomobject][ordered]@{
      result='FAIL';mode=if ($OfflineSelfTest.IsPresent) {
        'OFFLINE_SELF_TEST'
      } else {'LIVE'}
      failure=$failure
      immutable_inputs=$pinnedInputs
      firmware_write_attempted=$false
      production_firmware_changed=$false
      preflight=[pscustomobject]$script:Preflight
    }
    Complete-Evidence $failedSummary
  }
  Write-Error $failure
  exit 1
}
