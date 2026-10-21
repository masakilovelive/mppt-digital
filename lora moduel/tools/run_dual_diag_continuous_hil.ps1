[CmdletBinding()]
param(
  [ValidatePattern('^COM[0-9]+$')]
  [string]$VehiclePort = 'COM3',

  [ValidateRange(1200, 2000000)]
  [int]$VehicleBaud = 115200,

  [ValidatePattern('^COM[0-9]+$')]
  [string]$GroundPort = 'COM6',

  [ValidateRange(1200, 2000000)]
  [int]$GroundBaud = 57600,

  [string]$FixturePath,

  [string]$OutputDirectory,

  [ValidateRange(1, 600)]
  [int]$PortWaitTimeoutSeconds = 120,

  [ValidateRange(5000, 60000)]
  [int]$PowerOffConfirmMs = 5000,

  [ValidateRange(1, 60)]
  [int]$SnapshotTimeoutSeconds = 10,

  [ValidateRange(1, 600)]
  [int]$ResponseTimeoutSeconds = 20,

  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RunWatch = $null
$script:CurrentPhase = 'not_started'
$script:Timeline = $null
$script:MaximumTaggedLineBytes = 16384
$script:OutputDirectoryOwned = $false

function Update-X25Crc {
  param(
    [Parameter(Mandatory = $true)]
    [int]$Crc,

    [Parameter(Mandatory = $true)]
    [byte]$Value
  )

  [int]$temporary = ([int]$Value -bxor ($Crc -band 0xFF))
  $temporary = ($temporary -bxor (($temporary -shl 4) -band 0xFF)) `
      -band 0xFF
  return ((($Crc -shr 8) -bxor ($temporary -shl 8) -bxor
      ($temporary -shl 3) -bxor ($temporary -shr 4)) -band 0xFFFF)
}

function Get-MavlinkCrc {
  param(
    [Parameter(Mandatory = $true)]
    [byte[]]$Bytes,

    [Parameter(Mandatory = $true)]
    [int]$Start,

    [Parameter(Mandatory = $true)]
    [int]$Count,

    [Parameter(Mandatory = $true)]
    [byte]$Extra
  )

  [int]$crc = 0xFFFF
  for ($index = 0; $index -lt $Count; ++$index) {
    $crc = Update-X25Crc -Crc $crc -Value $Bytes[$Start + $index]
  }
  return (Update-X25Crc -Crc $crc -Value $Extra)
}

function Test-MavlinkFrameCrc {
  param(
    [Parameter(Mandatory = $true)]
    [byte[]]$Frame,

    [Parameter(Mandatory = $true)]
    [byte]$Extra
  )

  if ($Frame.Length -lt 8) {
    return $false
  }
  [int]$headerLength = 0
  if ($Frame[0] -eq 0xFE) {
    $headerLength = 6
  } elseif ($Frame[0] -eq 0xFD) {
    $headerLength = 10
  } else {
    return $false
  }
  [int]$payloadLength = $Frame[1]
  [int]$checksumIndex = $headerLength + $payloadLength
  if ($checksumIndex + 1 -ge $Frame.Length) {
    return $false
  }
  [int]$crc = Get-MavlinkCrc -Bytes $Frame -Start 1 `
      -Count ($checksumIndex - 1) -Extra $Extra
  return ($Frame[$checksumIndex] -eq ($crc -band 0xFF) -and
      $Frame[$checksumIndex + 1] -eq (($crc -shr 8) -band 0xFF))
}

function Import-MavlinkDefinitions {
  param(
    [Parameter(Mandatory = $true)][string]$Path
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "MAVLink definition source is missing: $Path"
  }
  [string]$source = [System.IO.File]::ReadAllText($Path)
  $matches = [regex]::Matches($source,
      '\{\s*(\d+)U\s*,\s*(\d+)U\s*,\s*(\d+)U\s*,\s*(\d+)U\s*\}')
  $definitions = @{}
  foreach ($match in $matches) {
    [int]$messageId = [int]$match.Groups[1].Value
    $definitions[$messageId] = [pscustomobject][ordered]@{
      message_id = $messageId
      crc_extra = [byte][int]$match.Groups[2].Value
      minimum_payload_length = [int]$match.Groups[3].Value
      maximum_payload_length = [int]$match.Groups[4].Value
    }
  }
  if (-not $definitions.ContainsKey(0) -or
      $definitions[0].crc_extra -ne 50 -or
      $definitions[0].minimum_payload_length -ne 9 -or
      $definitions[0].maximum_payload_length -ne 9 -or
      -not $definitions.ContainsKey(22) -or
      $definitions[22].crc_extra -ne 220) {
    throw "Authoritative MAVLink definitions were not parsed from $Path"
  }
  return [pscustomobject][ordered]@{
    path = (Resolve-Path -LiteralPath $Path).Path
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    count = $definitions.Count
    definitions = $definitions
  }
}

function Get-UInt16Le {
  param([byte[]]$Bytes, [int]$Offset)
  return [uint16]([int]$Bytes[$Offset] -bor
      ([int]$Bytes[$Offset + 1] -shl 8))
}

function Get-UInt32Le {
  param([byte[]]$Bytes, [int]$Offset)
  return [uint32]([uint32]$Bytes[$Offset] -bor
      ([uint32]$Bytes[$Offset + 1] -shl 8) -bor
      ([uint32]$Bytes[$Offset + 2] -shl 16) -bor
      ([uint32]$Bytes[$Offset + 3] -shl 24))
}

function Test-ExactSerial1BaudPayload {
  param(
    [Parameter(Mandatory = $true)]
    [byte[]]$Payload,

    [Parameter(Mandatory = $true)]
    [int]$SystemId,

    [Parameter(Mandatory = $true)]
    [int]$ComponentId
  )

  if ($Payload.Length -ne 25 -or $SystemId -ne 1 -or
      $ComponentId -ne 1) {
    return $false
  }
  [byte[]]$expectedId = [System.Text.Encoding]::ASCII.GetBytes(
      'SERIAL1_BAUD' + ([char]0) + ([char]0) + ([char]0) + ([char]0))
  for ($index = 0; $index -lt 16; ++$index) {
    if ($Payload[8 + $index] -ne $expectedId[$index]) {
      return $false
    }
  }
  return ((Get-UInt32Le -Bytes $Payload -Offset 0) -eq [uint32]0x42640000 -and
      (Get-UInt16Le -Bytes $Payload -Offset 4) -ne 0 -and
      (Get-UInt16Le -Bytes $Payload -Offset 6) -eq 0xFFFF -and
      $Payload[24] -eq 6)
}

function New-Mavlink2TestFrame {
  param(
    [Parameter(Mandatory = $true)]
    [int]$MessageId,

    [Parameter(Mandatory = $true)]
    [byte[]]$Payload,

    [Parameter(Mandatory = $true)]
    [byte]$CrcExtra,

    [byte]$Sequence = 1,
    [byte]$SystemId = 1,
    [byte]$ComponentId = 1
  )

  [byte[]]$frame = New-Object byte[] (12 + $Payload.Length)
  $frame[0] = 0xFD
  $frame[1] = [byte]$Payload.Length
  $frame[2] = 0
  $frame[3] = 0
  $frame[4] = $Sequence
  $frame[5] = $SystemId
  $frame[6] = $ComponentId
  $frame[7] = [byte]($MessageId -band 0xFF)
  $frame[8] = [byte](($MessageId -shr 8) -band 0xFF)
  $frame[9] = [byte](($MessageId -shr 16) -band 0xFF)
  [Array]::Copy($Payload, 0, $frame, 10, $Payload.Length)
  [int]$crc = Get-MavlinkCrc -Bytes $frame -Start 1 `
      -Count (9 + $Payload.Length) -Extra $CrcExtra
  $frame[10 + $Payload.Length] = [byte]($crc -band 0xFF)
  $frame[11 + $Payload.Length] = [byte](($crc -shr 8) -band 0xFF)
  return $frame
}

function Test-ExactRequestFixture {
  param(
    [Parameter(Mandatory = $true)]
    [byte[]]$Bytes
  )

  $errors = New-Object System.Collections.Generic.List[string]
  if ($Bytes.Length -ne 32) {
    $errors.Add("fixture length is $($Bytes.Length), expected exactly 32")
  }
  if ($Bytes.Length -ge 32) {
    if ($Bytes[0] -ne 0xFD -or $Bytes[1] -ne 20 -or
        ($Bytes[2] -band 1) -ne 0) {
      $errors.Add('fixture is not an unsigned MAVLink2 frame with payload length 20')
    }
    [int]$messageId = [int]$Bytes[7] -bor ([int]$Bytes[8] -shl 8) `
        -bor ([int]$Bytes[9] -shl 16)
    if ($messageId -ne 20) {
      $errors.Add("fixture message id is $messageId, expected PARAM_REQUEST_READ #20")
    }
    if ((Get-UInt16Le -Bytes $Bytes -Offset 10) -ne 0xFFFF -or
        $Bytes[12] -ne 1 -or $Bytes[13] -ne 1) {
      $errors.Add('fixture must request by ID (index -1) from target 1/1')
    }
    [byte[]]$expectedId = [System.Text.Encoding]::ASCII.GetBytes(
        'SERIAL1_BAUD' + ([char]0) + ([char]0) + ([char]0) + ([char]0))
    for ($index = 0; $index -lt 16; ++$index) {
      if ($Bytes[14 + $index] -ne $expectedId[$index]) {
        $errors.Add('fixture param_id is not exact padded SERIAL1_BAUD')
        break
      }
    }
    if (-not (Test-MavlinkFrameCrc -Frame $Bytes -Extra 214)) {
      $errors.Add('fixture MAVLink CRC is invalid for PARAM_REQUEST_READ')
    }
  }
  return [pscustomobject][ordered]@{
    valid = ($errors.Count -eq 0)
    errors = @($errors)
  }
}

function New-MavlinkAnalysisState {
  return [pscustomobject][ordered]@{
    Buffer = New-Object 'System.Collections.Generic.List[byte]'
    ExpectedLength = 0
    StartOffset = [long]-1
    Enabled = $true
    ExplicitResets = New-Object 'System.Collections.Generic.List[object]'
    ValidEvents = New-Object 'System.Collections.Generic.List[object]'
    ExactTargetEvents = New-Object 'System.Collections.Generic.List[object]'
    Definitions = @{}
    Unsupported = [uint64]0
    UnsupportedFlags = [uint64]0
    BadPayloadLength = [uint64]0
    BadCrc = [uint64]0
    NoiseBytes = [uint64]0
    InvalidCrc = [uint64]0
    InvalidLength = [uint64]0
  }
}

function Clear-MavlinkCandidate {
  param($Parser)
  $Parser.Buffer.Clear()
  $Parser.ExpectedLength = 0
  $Parser.StartOffset = [long]-1
}

function Reset-MavlinkAnalysis {
  param(
    [Parameter(Mandatory = $true)]$Parser,
    [Parameter(Mandatory = $true)][string]$Reason,
    [Parameter(Mandatory = $true)][long]$RawOffset
  )
  Clear-MavlinkCandidate -Parser $Parser
  $Parser.ExplicitResets.Add([pscustomobject][ordered]@{
    reason = $Reason
    raw_offset = $RawOffset
    elapsed_ms = [Math]::Round($script:RunWatch.Elapsed.TotalMilliseconds, 3)
    utc = (Get-Date).ToUniversalTime().ToString('o')
  })
}

function Complete-MavlinkCandidate {
  param(
    [Parameter(Mandatory = $true)]$Parser,
    [Parameter(Mandatory = $true)][long]$EndOffsetExclusive
  )

  [byte[]]$frame = $Parser.Buffer.ToArray()
  [int]$headerLength = $(if ($frame[0] -eq 0xFD) { 10 } else { 6 })
  [int]$payloadLength = $frame[1]
  [int]$messageId = 0
  [int]$sequence = 0
  [int]$systemId = 0
  [int]$componentId = 0
  if ($frame[0] -eq 0xFD) {
    $messageId = [int]$frame[7] -bor ([int]$frame[8] -shl 8) `
        -bor ([int]$frame[9] -shl 16)
    $sequence = $frame[4]
    $systemId = $frame[5]
    $componentId = $frame[6]
  } else {
    $messageId = $frame[5]
    $sequence = $frame[2]
    $systemId = $frame[3]
    $componentId = $frame[4]
  }

  $definition = $null
  if ($Parser.Definitions.ContainsKey($messageId)) {
    $definition = $Parser.Definitions[$messageId]
  }
  if ($null -eq $definition) {
    ++$Parser.Unsupported
  } elseif ($frame[0] -eq 0xFD -and ($frame[2] -band 0xFE) -ne 0) {
    ++$Parser.UnsupportedFlags
  } elseif ($payloadLength -lt $definition.minimum_payload_length -or
      $payloadLength -gt $definition.maximum_payload_length -or
      ($frame[0] -eq 0xFE -and
        $payloadLength -ne $definition.minimum_payload_length)) {
    ++$Parser.BadPayloadLength
    ++$Parser.InvalidLength
  } else {
    if (Test-MavlinkFrameCrc -Frame $frame `
        -Extra ([byte]$definition.crc_extra)) {
      [byte[]]$payload = New-Object byte[] $payloadLength
      if ($payloadLength -gt 0) {
        [Array]::Copy($frame, $headerLength, $payload, 0, $payloadLength)
      }
      $event = [pscustomobject][ordered]@{
        message_id = $messageId
        sequence = $sequence
        system_id = $systemId
        component_id = $componentId
        frame_version = $(if ($frame[0] -eq 0xFD) { 2 } else { 1 })
        frame_size = $frame.Length
        raw_start_offset = $Parser.StartOffset
        raw_end_offset_exclusive = $EndOffsetExclusive
        elapsed_ms = [Math]::Round($script:RunWatch.Elapsed.TotalMilliseconds, 3)
        utc = (Get-Date).ToUniversalTime().ToString('o')
        phase = $script:CurrentPhase
      }
      $Parser.ValidEvents.Add($event)
      if ($messageId -eq 22 -and
          (Test-ExactSerial1BaudPayload -Payload $payload `
              -SystemId $systemId -ComponentId $componentId)) {
        $Parser.ExactTargetEvents.Add([pscustomobject][ordered]@{
          message_id = 22
          sequence = $sequence
          system_id = $systemId
          component_id = $componentId
          value_bits_hex = '{0:X8}' -f (Get-UInt32Le -Bytes $payload -Offset 0)
          param_count = Get-UInt16Le -Bytes $payload -Offset 4
          param_index = Get-UInt16Le -Bytes $payload -Offset 6
          param_type = $payload[24]
          frame_version = $(if ($frame[0] -eq 0xFD) { 2 } else { 1 })
          frame_size = $frame.Length
          raw_start_offset = $Parser.StartOffset
          raw_end_offset_exclusive = $EndOffsetExclusive
          elapsed_ms = $event.elapsed_ms
          utc = $event.utc
          phase = $event.phase
        })
      }
    } else {
      ++$Parser.BadCrc
      ++$Parser.InvalidCrc
    }
  }
  Clear-MavlinkCandidate -Parser $Parser
}

function Add-MavlinkAnalysisByte {
  param(
    [Parameter(Mandatory = $true)]$Parser,
    [Parameter(Mandatory = $true)][byte]$Byte,
    [Parameter(Mandatory = $true)][long]$RawOffset
  )

  if (-not $Parser.Enabled) {
    return
  }
  if ($Parser.Buffer.Count -eq 0) {
    if ($Byte -eq 0xFD -or $Byte -eq 0xFE) {
      $Parser.StartOffset = $RawOffset
      $Parser.Buffer.Add($Byte)
    } else {
      ++$Parser.NoiseBytes
    }
    return
  }

  $Parser.Buffer.Add($Byte)
  if ($Parser.Buffer.Count -eq 2) {
    [int]$payloadLength = $Parser.Buffer[1]
    if ($Parser.Buffer[0] -eq 0xFE) {
      $Parser.ExpectedLength = 8 + $payloadLength
    }
  } elseif ($Parser.Buffer.Count -eq 3 -and
      $Parser.Buffer[0] -eq 0xFD) {
    [int]$signatureLength = $(if (($Parser.Buffer[2] -band 1) -ne 0) {
        13
      } else { 0 })
    $Parser.ExpectedLength = 12 + [int]$Parser.Buffer[1] + $signatureLength
  }
  if ($Parser.ExpectedLength -gt 300 -or $Parser.Buffer.Count -gt 300) {
    ++$Parser.InvalidLength
    Clear-MavlinkCandidate -Parser $Parser
    return
  }
  if ($Parser.ExpectedLength -gt 0 -and
      $Parser.Buffer.Count -eq $Parser.ExpectedLength) {
    Complete-MavlinkCandidate -Parser $Parser `
        -EndOffsetExclusive ($RawOffset + 1)
  }
}

function New-CaptureState {
  param(
    [Parameter(Mandatory = $true)][string]$Role,
    [Parameter(Mandatory = $true)][string]$TagBase,
    [switch]$WithMavlinkAnalysis
  )

  return [pscustomobject][ordered]@{
    Role = $Role
    TagBase = $TagBase
    TagBaseBytes = [System.Text.Encoding]::ASCII.GetBytes($TagBase)
    Raw = New-Object System.IO.MemoryStream
    Chunks = New-Object 'System.Collections.Generic.List[object]'
    TaggedLines = New-Object 'System.Collections.Generic.List[object]'
    MatcherCandidate = New-Object 'System.Collections.Generic.List[byte]'
    MatcherStartOffset = [long]-1
    MatcherOverflows = [uint64]0
    Mavlink = $(if ($WithMavlinkAnalysis.IsPresent) {
        New-MavlinkAnalysisState
      } else { $null })
  }
}

function Reset-TagMatcherCandidate {
  param($State)
  $State.MatcherCandidate.Clear()
  $State.MatcherStartOffset = [long]-1
}

function Add-TaggedMatcherByte {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][byte]$Byte,
    [Parameter(Mandatory = $true)][long]$RawOffset
  )

  [byte]$first = $State.TagBaseBytes[0]
  if ($State.MatcherCandidate.Count -eq 0) {
    if ($Byte -eq $first) {
      $State.MatcherStartOffset = $RawOffset
      $State.MatcherCandidate.Add($Byte)
    }
    return
  }

  $State.MatcherCandidate.Add($Byte)
  [int]$count = $State.MatcherCandidate.Count
  [bool]$validPrefix = $true
  if ($count -le $State.TagBaseBytes.Length) {
    $validPrefix = ($Byte -eq $State.TagBaseBytes[$count - 1])
  } elseif ($count -eq $State.TagBaseBytes.Length + 1) {
    $validPrefix = ($Byte -ge [byte][char]'1' -and
        $Byte -le [byte][char]'3')
  } elseif ($count -eq $State.TagBaseBytes.Length + 2) {
    $validPrefix = ($Byte -eq [byte][char]' ')
  }

  if (-not $validPrefix) {
    Reset-TagMatcherCandidate -State $State
    if ($Byte -eq $first) {
      $State.MatcherStartOffset = $RawOffset
      $State.MatcherCandidate.Add($Byte)
    }
    return
  }
  if ($count -gt $script:MaximumTaggedLineBytes) {
    ++$State.MatcherOverflows
    Reset-TagMatcherCandidate -State $State
    return
  }
  if ($count -le $State.TagBaseBytes.Length + 2 -or $Byte -ne 0x0A) {
    return
  }

  [byte[]]$lineBytes = $State.MatcherCandidate.ToArray()
  [int]$lineLength = $lineBytes.Length
  while ($lineLength -gt 0 -and
      ($lineBytes[$lineLength - 1] -eq 0x0A -or
       $lineBytes[$lineLength - 1] -eq 0x0D)) {
    --$lineLength
  }
  [string]$line = [System.Text.Encoding]::ASCII.GetString(
      $lineBytes, 0, $lineLength)
  [string[]]$tokens = @($line -split '\s+')
  $fields = [ordered]@{}
  for ($index = 1; $index -lt $tokens.Count; ++$index) {
    [int]$separator = $tokens[$index].IndexOf('=')
    if ($separator -le 0) {
      continue
    }
    [string]$key = $tokens[$index].Substring(0, $separator)
    if ($key -notmatch '^[A-Za-z][A-Za-z0-9_.-]*$') {
      continue
    }
    $fields[$key] = $tokens[$index].Substring($separator + 1)
  }
  [uint32]$q = 0
  [uint64]$ms = 0
  [bool]$validCorrelation = ($fields.Contains('q') -and
      $fields.Contains('ms') -and
      [uint32]::TryParse([string]$fields['q'], [ref]$q) -and
      $q -ne 0 -and
      [uint64]::TryParse([string]$fields['ms'], [ref]$ms))
  $State.TaggedLines.Add([pscustomobject][ordered]@{
    sequence = $State.TaggedLines.Count
    role = $State.Role
    tag = $tokens[0]
    line = $line
    fields = [pscustomobject]$fields
    valid_correlation = $validCorrelation
    q_uint32 = $(if ($validCorrelation) { $q } else { $null })
    ms_uint64 = $(if ($validCorrelation) { $ms } else { $null })
    raw_start_offset = $State.MatcherStartOffset
    raw_end_offset_exclusive = $RawOffset + 1
    elapsed_ms = [Math]::Round($script:RunWatch.Elapsed.TotalMilliseconds, 3)
    utc = (Get-Date).ToUniversalTime().ToString('o')
    phase = $script:CurrentPhase
  })
  Reset-TagMatcherCandidate -State $State
}

function Add-CaptureBytes {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][byte[]]$Buffer,
    [Parameter(Mandatory = $true)][int]$Count
  )

  if ($Count -le 0) {
    return
  }
  [long]$startOffset = $State.Raw.Length
  $State.Raw.Write($Buffer, 0, $Count)
  $State.Chunks.Add([pscustomobject][ordered]@{
    raw_start_offset = $startOffset
    byte_count = $Count
    elapsed_ms = [Math]::Round($script:RunWatch.Elapsed.TotalMilliseconds, 3)
    utc = (Get-Date).ToUniversalTime().ToString('o')
    phase = $script:CurrentPhase
  })
  for ($index = 0; $index -lt $Count; ++$index) {
    [long]$offset = $startOffset + $index
    Add-TaggedMatcherByte -State $State -Byte $Buffer[$index] `
        -RawOffset $offset
    if ($null -ne $State.Mavlink) {
      Add-MavlinkAnalysisByte -Parser $State.Mavlink -Byte $Buffer[$index] `
          -RawOffset $offset
    }
  }
}

function Select-CorrelatedReport {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][int]$StartLineIndex,
    [Nullable[uint32]]$ExpectedQ = $null
  )

  $groups = [ordered]@{}
  for ($index = $StartLineIndex; $index -lt $State.TaggedLines.Count; ++$index) {
    $candidate = $State.TaggedLines[$index]
    if (-not $candidate.valid_correlation) {
      continue
    }
    if ($null -ne $ExpectedQ -and
        [uint32]$candidate.q_uint32 -ne [uint32]$ExpectedQ) {
      continue
    }
    [string]$key = '{0}:{1}' -f $candidate.q_uint32, $candidate.ms_uint64
    if (-not $groups.Contains($key)) {
      $groups[$key] = [ordered]@{}
    }
    if (-not $groups[$key].Contains($candidate.tag)) {
      $groups[$key][$candidate.tag] = $candidate
    }
    [string[]]$tags = @(
      "$($State.TagBase)1", "$($State.TagBase)2", "$($State.TagBase)3")
    [bool]$complete = $true
    foreach ($tag in $tags) {
      if (-not $groups[$key].Contains($tag)) {
        $complete = $false
      }
    }
    if ($complete) {
      return [pscustomobject][ordered]@{
        complete = $true
        q_uint32 = [uint32]$candidate.q_uint32
        ms_uint64 = [uint64]$candidate.ms_uint64
        responses = @($tags | ForEach-Object { $groups[$key][$_] })
      }
    }
  }
  return [pscustomobject][ordered]@{
    complete = $false
    q_uint32 = $null
    ms_uint64 = $null
    responses = @()
  }
}

function Get-NextQueryId {
  param([Parameter(Mandatory = $true)][uint32]$Current)
  if ($Current -eq 0) {
    throw 'query id zero is invalid'
  }
  if ($Current -eq [uint32]::MaxValue) {
    return [uint32]1
  }
  return [uint32]($Current + 1)
}

function Write-ExactRequestOnce {
  param(
    [Parameter(Mandatory = $true)]$Serial,
    [Parameter(Mandatory = $true)][byte[]]$Fixture,
    [Parameter(Mandatory = $true)]$InjectionState
  )
  if ($InjectionState.write_count -ne 0) {
    throw 'PARAM_REQUEST_READ injection was attempted more than once'
  }
  if ($Fixture.Length -ne 32) {
    throw 'PARAM_REQUEST_READ injection is not exactly 32 bytes'
  }
  $Serial.Write($Fixture, 0, $Fixture.Length)
  $Serial.BaseStream.Flush()
  $InjectionState.write_count = 1
  $InjectionState.final_write_elapsed_ms =
      [Math]::Round($script:RunWatch.Elapsed.TotalMilliseconds, 3)
  $InjectionState.final_write_utc = (Get-Date).ToUniversalTime().ToString('o')
}

function Get-HeartbeatWindowMetrics {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IEnumerable]$Events,
    [Parameter(Mandatory = $true)][double]$M0ElapsedMs,
    [Parameter(Mandatory = $true)][double]$R0ElapsedMs,
    [Parameter(Mandatory = $true)][double]$M1ElapsedMs,
    [double]$MaximumGapMs = 2500.0
  )

  $heartbeats = @($Events | Where-Object {
      $_.message_id -eq 0 -and $_.system_id -eq 1 -and
      $_.component_id -eq 1 -and
      [double]$_.elapsed_ms -ge $M0ElapsedMs -and
      [double]$_.elapsed_ms -le $M1ElapsedMs
    } | Sort-Object { [double]$_.elapsed_ms })
  $gaps = New-Object 'System.Collections.Generic.List[object]'
  if ($heartbeats.Count -gt 0) {
    $gaps.Add([pscustomobject][ordered]@{
      kind = 'first_from_M0'
      from_elapsed_ms = $M0ElapsedMs
      to_elapsed_ms = [double]$heartbeats[0].elapsed_ms
      gap_ms = [Math]::Round(
          [double]$heartbeats[0].elapsed_ms - $M0ElapsedMs, 3)
    })
    for ($index = 1; $index -lt $heartbeats.Count; ++$index) {
      $gaps.Add([pscustomobject][ordered]@{
        kind = 'consecutive'
        from_elapsed_ms = [double]$heartbeats[$index - 1].elapsed_ms
        to_elapsed_ms = [double]$heartbeats[$index].elapsed_ms
        gap_ms = [Math]::Round(
            [double]$heartbeats[$index].elapsed_ms -
            [double]$heartbeats[$index - 1].elapsed_ms, 3)
      })
    }
    $gaps.Add([pscustomobject][ordered]@{
      kind = 'tail_to_M1'
      from_elapsed_ms = [double]$heartbeats[-1].elapsed_ms
      to_elapsed_ms = $M1ElapsedMs
      gap_ms = [Math]::Round(
          $M1ElapsedMs - [double]$heartbeats[-1].elapsed_ms, 3)
    })
  }
  $exceedances = @($gaps | Where-Object {
      [double]$_.gap_ms -gt $MaximumGapMs })
  [double]$maximumGap = 0.0
  if ($gaps.Count -gt 0) {
    $maximumGap = [double](($gaps | Measure-Object -Property gap_ms `
        -Maximum).Maximum)
  }
  return [pscustomobject][ordered]@{
    valid = ($heartbeats.Count -ge 2 -and $exceedances.Count -eq 0)
    source_system_id = 1
    source_component_id = 1
    m0_elapsed_ms = $M0ElapsedMs
    r0_elapsed_ms = $R0ElapsedMs
    m1_elapsed_ms = $M1ElapsedMs
    maximum_allowed_gap_ms = $MaximumGapMs
    count = $heartbeats.Count
    pre_request_count = @($heartbeats | Where-Object {
        [double]$_.elapsed_ms -lt $R0ElapsedMs }).Count
    post_request_count = @($heartbeats | Where-Object {
        [double]$_.elapsed_ms -ge $R0ElapsedMs }).Count
    first_gap_ms = $(if ($gaps.Count -gt 0) { $gaps[0].gap_ms } else { $null })
    maximum_gap_ms = $(if ($gaps.Count -gt 0) { $maximumGap } else { $null })
    tail_gap_ms = $(if ($gaps.Count -gt 0) {
        $gaps[$gaps.Count - 1].gap_ms
      } else { $null })
    gaps = @($gaps.ToArray())
    gap_exceedances = @($exceedances)
    heartbeats = @($heartbeats)
  }
}

function Get-TargetResponseWindow {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IEnumerable]$Events,
    [Parameter(Mandatory = $true)][double]$M0ElapsedMs,
    [Parameter(Mandatory = $true)][double]$R0ElapsedMs,
    [Parameter(Mandatory = $true)][double]$M1ElapsedMs,
    [double]$TimeoutMs = 20000.0
  )

  $all = @($Events | Sort-Object { [double]$_.elapsed_ms })
  $responses = @($all | Where-Object {
      [double]$_.elapsed_ms -gt $R0ElapsedMs -and
      [double]$_.elapsed_ms -le $M1ElapsedMs })
  $preRequestWindow = @($all | Where-Object {
      [double]$_.elapsed_ms -ge $M0ElapsedMs -and
      [double]$_.elapsed_ms -le $R0ElapsedMs })
  $selected = $(if ($responses.Count -gt 0) { $responses[0] } else { $null })
  [double]$latency = 0.0
  if ($null -ne $selected) {
    $latency = [Math]::Round(
        [double]$selected.elapsed_ms - $R0ElapsedMs, 3)
  }
  return [pscustomobject][ordered]@{
    valid = ($preRequestWindow.Count -eq 0 -and
        $responses.Count -eq 1 -and $latency -gt 0.0 -and
        $latency -le $TimeoutMs)
    m0_elapsed_ms = $M0ElapsedMs
    r0_elapsed_ms = $R0ElapsedMs
    m1_elapsed_ms = $M1ElapsedMs
    timeout_ms = $TimeoutMs
    before_m0_count = @($all | Where-Object {
        [double]$_.elapsed_ms -lt $M0ElapsedMs }).Count
    pre_or_at_r0_count = $preRequestWindow.Count
    response_count = $responses.Count
    duplicate_count = [Math]::Max(0, $responses.Count - 1)
    selected_latency_ms = $(if ($null -ne $selected) { $latency } else { $null })
    selected = $selected
    responses = @($responses)
  }
}

function Get-SnapshotUInt64 {
  param(
    $Snapshot,
    [Parameter(Mandatory = $true)][string]$Key
  )
  if ($null -eq $Snapshot -or $Snapshot.status -ne 'COMPLETE') {
    return [pscustomobject]@{ found = $false; value = $null }
  }
  foreach ($response in @($Snapshot.responses)) {
    $property = $response.fields.PSObject.Properties[$Key]
    if ($null -eq $property) { continue }
    [uint64]$value = 0
    if ([uint64]::TryParse([string]$property.Value, [ref]$value)) {
      return [pscustomobject]@{ found = $true; value = $value }
    }
  }
  return [pscustomobject]@{ found = $false; value = $null }
}

function Get-SnapshotDelta {
  param($Baseline, $Post, [string]$Key)
  $before = Get-SnapshotUInt64 -Snapshot $Baseline -Key $Key
  $after = Get-SnapshotUInt64 -Snapshot $Post -Key $Key
  [bool]$monotonic = ($before.found -and $after.found -and
      [uint64]$after.value -ge [uint64]$before.value)
  return [pscustomobject][ordered]@{
    key = $Key
    found = ($before.found -and $after.found)
    monotonic = $monotonic
    before = $before.value
    after = $after.value
    delta = $(if ($monotonic) {
        [uint64]$after.value - [uint64]$before.value
      } else { $null })
  }
}

function Test-BaselineSetup {
  param($GroundSnapshot, $VehicleSnapshot)
  $checks = New-Object 'System.Collections.Generic.List[object]'
  foreach ($specification in @(
      @('ground_ready', $GroundSnapshot, 'ready', [uint64]1),
      @('ground_fail', $GroundSnapshot, 'fail', [uint64]0),
      @('ground_rse', $GroundSnapshot, 'rse', [uint64]0),
      @('vehicle_ready', $VehicleSnapshot, 'r', [uint64]1),
      @('vehicle_fail', $VehicleSnapshot, 'f', [uint64]0))) {
    $field = Get-SnapshotUInt64 -Snapshot $specification[1] `
        -Key $specification[2]
    $checks.Add([pscustomobject][ordered]@{
      name = $specification[0]
      key = $specification[2]
      found = $field.found
      actual = $field.value
      expected = $specification[3]
      valid = ($field.found -and
          [uint64]$field.value -eq [uint64]$specification[3])
    })
  }
  foreach ($bootSpec in @(
      @('ground_boot_present', $GroundSnapshot),
      @('vehicle_boot_present', $VehicleSnapshot))) {
    $boot = Get-SnapshotUInt64 -Snapshot $bootSpec[1] -Key 'boot'
    $checks.Add([pscustomobject][ordered]@{
      name = $bootSpec[0]
      key = 'boot'
      found = $boot.found
      actual = $boot.value
      expected = 'nonzero'
      valid = ($boot.found -and [uint64]$boot.value -ne 0)
    })
  }
  return [pscustomobject][ordered]@{
    valid = @($checks | Where-Object { -not $_.valid }).Count -eq 0
    checks = @($checks.ToArray())
  }
}

function Get-StageAssessment {
  param($BaselineGround, $PostGround, $BaselineVehicle, $PostVehicle)
  $stages = New-Object 'System.Collections.Generic.List[object]'
  function Add-DeltaStage {
    param([string]$Name, $Baseline, $Post, [string]$Key,
          [string]$Rule, [uint64]$Expected = 1)
    $delta = Get-SnapshotDelta -Baseline $Baseline -Post $Post -Key $Key
    [bool]$valid = $false
    if ($delta.monotonic) {
      if ($Rule -eq 'exact') {
        $valid = ([uint64]$delta.delta -eq $Expected)
      } elseif ($Rule -eq 'positive') {
        $valid = ([uint64]$delta.delta -gt 0)
      } elseif ($Rule -eq 'unchanged_zero') {
        $valid = ([uint64]$delta.before -eq 0 -and
            [uint64]$delta.after -eq 0)
      } elseif ($Rule -eq 'delta_zero') {
        $valid = ([uint64]$delta.delta -eq 0)
      }
    }
    $stages.Add([pscustomobject][ordered]@{
      name = $Name; key = $Key; rule = $Rule; expected = $Expected
      valid = $valid; evidence = $delta
    })
  }

  Add-DeltaStage 'ground_usb_valid_20' $BaselineGround $PostGround `
      'uv20' 'exact'
  Add-DeltaStage 'ground_proxy_forwarded' $BaselineGround $PostGround `
      'upfwd' 'exact'
  Add-DeltaStage 'ground_usb_queued_frame' $BaselineGround $PostGround `
      'uqf' 'exact'
  Add-DeltaStage 'ground_front_dequeued' $BaselineGround $PostGround `
      'ufdq' 'exact'
  Add-DeltaStage 'ground_uplink_transaction' $BaselineGround $PostGround `
      'utx' 'exact'
  Add-DeltaStage 'ground_uplink_bytes' $BaselineGround $PostGround `
      'upb' 'exact' 32
  Add-DeltaStage 'ground_direct_tx' $BaselineGround $PostGround `
      'dtx' 'exact'
  Add-DeltaStage 'vehicle_rf_valid_20' $BaselineVehicle $PostVehicle `
      'r20' 'exact'
  Add-DeltaStage 'vehicle_d6_20' $BaselineVehicle $PostVehicle `
      'd620' 'exact'
  Add-DeltaStage 'vehicle_d6_exact' $BaselineVehicle $PostVehicle `
      'td6ex' 'exact'
  Add-DeltaStage 'vehicle_strict_param_value' $BaselineVehicle $PostVehicle `
      'pvs1' 'exact'
  Add-DeltaStage 'vehicle_strict_d7_target' $BaselineVehicle $PostVehicle `
      'td7mi' 'exact'
  foreach ($commitState in @(
      @('vehicle_commit_preflight_ok', 'tpf'),
      @('vehicle_commit_take_ok', 'ttk'),
      @('vehicle_commit_egress_ok', 'tei'))) {
    $commitDelta = Get-SnapshotDelta -Baseline $BaselineVehicle `
        -Post $PostVehicle -Key $commitState[1]
    $stages.Add([pscustomobject][ordered]@{
      name = $commitState[0]; key = $commitState[1]
      rule = 'zero_to_success'; expected = 2
      valid = ($commitDelta.monotonic -and
          [uint64]$commitDelta.before -eq 0 -and
          [uint64]$commitDelta.after -eq 2)
      evidence = $commitDelta
    })
  }
  Add-DeltaStage 'vehicle_commit_bytes' $BaselineVehicle $PostVehicle `
      'tcb' 'exact' 32
  Add-DeltaStage 'vehicle_commit_frames' $BaselineVehicle $PostVehicle `
      'tcf' 'exact'
  Add-DeltaStage 'ground_strict_rf_target' $BaselineGround $PostGround `
      's1rx' 'exact'
  Add-DeltaStage 'ground_strict_expected_target' $BaselineGround $PostGround `
      's1ok' 'exact'

  $s1Queued = Get-SnapshotDelta -Baseline $BaselineGround -Post $PostGround `
      -Key 's1q'
  $s1Backlog = Get-SnapshotDelta -Baseline $BaselineGround -Post $PostGround `
      -Key 's1bq'
  [bool]$dispositionValid = ($s1Queued.monotonic -and
      $s1Backlog.monotonic -and
      [uint64]$s1Queued.delta -eq 1 -and
      [uint64]$s1Backlog.delta -le 1)
  $stages.Add([pscustomobject][ordered]@{
    name = 'ground_strict_disposition'; key = 's1q;s1bq'
    rule = 'endpoint_exact_backlog_optional'
    expected = 's1q=1,s1bq=0..1'; valid = $dispositionValid
    evidence = [pscustomobject]@{ s1q = $s1Queued; s1bq = $s1Backlog }
  })
  Add-DeltaStage 'ground_strict_egress_admission' $BaselineGround $PostGround `
      's1ega' 'exact'
  Add-DeltaStage 'ground_strict_egress_commit' $BaselineGround $PostGround `
      's1egc' 'exact'

  foreach ($key in @('ci', 'cc', 'cuv', 'cut', 'cm', 'ucr', 'uiv',
      'udf', 'udb', 'uoe', 'urc', 'uic', 'dli', 'dlo', 'upinv',
      'epinv', 'rfinv', 'obif', 'obof', 's1dc', 's1d',
      's1pc', 's1iv', 's1ego', 'hd', 'dnak', 'xnak', 'inak',
      'pwto', 'psfail', 'prej')) {
    Add-DeltaStage ("ground_diagnostic_delta_zero_$key") `
        $BaselineGround $PostGround $key 'delta_zero' 0
  }
  foreach ($key in @('uqfb', 'uqb', 'ubuf', 'dlq',
      's1egp')) {
    Add-DeltaStage ("ground_current_zero_$key") $BaselineGround `
        $PostGround $key 'unchanged_zero' 0
  }
  foreach ($key in @('cc', 'rcr', 'riv', 'ocr', 'oiv', 'eiv', 'eov',
      'out', 'd6cr', 'd7cr', 'pvbad', 'pvov', 'eo', 'sc',
      'evo')) {
    Add-DeltaStage ("vehicle_diagnostic_delta_zero_$key") `
        $BaselineVehicle $PostVehicle $key 'delta_zero' 0
  }
  foreach ($key in @('pb', 'qb', 'tar')) {
    Add-DeltaStage ("vehicle_current_zero_$key") $BaselineVehicle `
        $PostVehicle $key 'unchanged_zero' 0
  }
  Add-DeltaStage 'ground_runtime_stop_unchanged' $BaselineGround $PostGround `
      'rse' 'unchanged_zero' 0
  Add-DeltaStage 'ground_fail_unchanged' $BaselineGround $PostGround `
      'fail' 'unchanged_zero' 0
  Add-DeltaStage 'vehicle_fail_unchanged' $BaselineVehicle $PostVehicle `
      'f' 'unchanged_zero' 0

  foreach ($role in @(
      @('ground_boot_same', $BaselineGround, $PostGround),
      @('vehicle_boot_same', $BaselineVehicle, $PostVehicle))) {
    $before = Get-SnapshotUInt64 -Snapshot $role[1] -Key 'boot'
    $after = Get-SnapshotUInt64 -Snapshot $role[2] -Key 'boot'
    $stages.Add([pscustomobject][ordered]@{
      name = $role[0]; key = 'boot'; rule = 'same_nonzero'; expected = $null
      valid = ($before.found -and $after.found -and
          [uint64]$before.value -ne 0 -and
          [uint64]$before.value -eq [uint64]$after.value)
      evidence = [pscustomobject]@{ before = $before; after = $after }
    })
  }

  foreach ($role in @(
      @('ground_snapshot_ms_monotonic', $BaselineGround, $PostGround),
      @('vehicle_snapshot_ms_monotonic', $BaselineVehicle, $PostVehicle))) {
    [bool]$msValid = ($null -ne $role[1] -and $null -ne $role[2] -and
        $role[1].status -eq 'COMPLETE' -and
        $role[2].status -eq 'COMPLETE' -and
        [uint64]$role[2].ms_uint64 -gt [uint64]$role[1].ms_uint64)
    $stages.Add([pscustomobject][ordered]@{
      name = $role[0]; key = 'ms'; rule = 'strictly_increasing'
      expected = 'post>baseline'; valid = $msValid
      evidence = [pscustomobject]@{
        before = $(if ($null -ne $role[1]) { $role[1].ms_uint64 } else { $null })
        after = $(if ($null -ne $role[2]) { $role[2].ms_uint64 } else { $null })
      }
    })
  }

  $failed = @($stages | Where-Object { -not $_.valid })
  return [pscustomobject][ordered]@{
    valid = ($failed.Count -eq 0)
    first_missing = $(if ($failed.Count -gt 0) { $failed[0].name } else { $null })
    failed_count = $failed.Count
    stages = @($stages.ToArray())
  }
}

function New-OfflineSnapshot {
  param(
    [hashtable]$Fields,
    [uint32]$Q = 1,
    [uint64]$Ms = 100
  )
  return [pscustomobject][ordered]@{
    status = 'COMPLETE'
    q_uint32 = $Q
    ms_uint64 = $Ms
    responses = @([pscustomobject]@{ fields = [pscustomobject]$Fields })
  }
}

function Test-OfflinePowerSequence {
  param(
    [Parameter(Mandatory = $true)][object[]]$Samples,
    [int]$RequiredAbsentMs = 5000
  )
  $absentSince = $null
  $confirmedAt = $null
  $enumeratedAt = $null
  foreach ($sample in @($Samples | Sort-Object elapsed_ms)) {
    if (-not $sample.vehicle_present -and -not $sample.ground_present) {
      if ($null -eq $absentSince) { $absentSince = [int]$sample.elapsed_ms }
      if ($null -eq $confirmedAt -and
          [int]$sample.elapsed_ms - $absentSince -ge $RequiredAbsentMs) {
        $confirmedAt = [int]$sample.elapsed_ms
      }
    } elseif ($null -eq $confirmedAt) {
      $absentSince = $null
    }
    if ($null -ne $confirmedAt -and $sample.vehicle_present -and
        $sample.ground_present) {
      $enumeratedAt = [int]$sample.elapsed_ms
      break
    }
  }
  return [pscustomobject]@{
    power_off_confirmed = ($null -ne $confirmedAt)
    confirmed_elapsed_ms = $confirmedAt
    both_enumerated_after_confirmation = ($null -ne $enumeratedAt)
    enumerated_elapsed_ms = $enumeratedAt
  }
}

function Test-FooterCloseOrdering {
  param($FooterFsyncElapsedMs, $VehicleCloseElapsedMs,
        $GroundCloseElapsedMs)
  return ($null -ne $FooterFsyncElapsedMs -and
      $null -ne $VehicleCloseElapsedMs -and
      $null -ne $GroundCloseElapsedMs -and
      [double]$FooterFsyncElapsedMs -lt [double]$VehicleCloseElapsedMs -and
      [double]$FooterFsyncElapsedMs -lt [double]$GroundCloseElapsedMs)
}

function New-OfflineWriteSerial {
  $state = [pscustomobject]@{
    write_count = 0
    bytes = New-Object 'System.Collections.Generic.List[byte]'
  }
  $baseStream = New-Object psobject
  $baseStream | Add-Member -MemberType ScriptMethod -Name Flush -Value {}
  $serial = [pscustomobject]@{ state = $state; BaseStream = $baseStream }
  $serial | Add-Member -MemberType ScriptMethod -Name Write -Value {
    param([byte[]]$Buffer, [int]$Offset, [int]$Count)
    ++$this.state.write_count
    for ($index = 0; $index -lt $Count; ++$index) {
      $this.state.bytes.Add($Buffer[$Offset + $index])
    }
  }
  return $serial
}

function Invoke-OfflineSelfTest {
  $script:RunWatch = [System.Diagnostics.Stopwatch]::StartNew()
  $script:CurrentPhase = 'selftest'
  $script:Timeline = New-Object 'System.Collections.Generic.List[object]'
  [byte[]]$vehicleCommand = [System.Text.Encoding]::ASCII.GetBytes("VCSTAT?`n")
  [byte[]]$groundCommand = [System.Text.Encoding]::ASCII.GetBytes("VCGSTAT?`n")
  if ((($vehicleCommand | ForEach-Object { $_.ToString('X2') }) -join ' ') -ne
      '56 43 53 54 41 54 3F 0A' -or
      (($groundCommand | ForEach-Object { $_.ToString('X2') }) -join ' ') -ne
      '56 43 47 53 54 41 54 3F 0A') {
    throw 'SelfTest: diagnostic query bytes are not exact LF-only commands'
  }

  [byte[]]$requestPayload = New-Object byte[] 20
  $requestPayload[0] = 0xFF
  $requestPayload[1] = 0xFF
  $requestPayload[2] = 1
  $requestPayload[3] = 1
  [byte[]]$requestId = [System.Text.Encoding]::ASCII.GetBytes('SERIAL1_BAUD')
  [Array]::Copy($requestId, 0, $requestPayload, 4, $requestId.Length)
  [byte[]]$request = New-Mavlink2TestFrame -MessageId 20 `
      -Payload $requestPayload -CrcExtra 214 -Sequence 7 `
      -SystemId 255 -ComponentId 190
  $requestCheck = Test-ExactRequestFixture -Bytes $request
  if (-not $requestCheck.valid -or $request.Length -ne 32) {
    throw "SelfTest: exact #20 fixture rejected: $($requestCheck.errors -join '; ')"
  }
  [byte[]]$corruptRequest = [byte[]]$request.Clone()
  $corruptRequest[31] = $corruptRequest[31] -bxor 0x80
  if ((Test-ExactRequestFixture -Bytes $corruptRequest).valid) {
    throw 'SelfTest: CRC-bad #20 fixture was accepted'
  }

  $fakeSerial = New-OfflineWriteSerial
  $injection = [pscustomobject]@{
    write_count = 0
    final_write_elapsed_ms = $null
    final_write_utc = $null
  }
  Write-ExactRequestOnce -Serial $fakeSerial -Fixture $request `
      -InjectionState $injection
  [bool]$secondWriteRejected = $false
  try {
    Write-ExactRequestOnce -Serial $fakeSerial -Fixture $request `
        -InjectionState $injection
  } catch {
    $secondWriteRejected = $true
  }
  if (-not $secondWriteRejected -or $injection.write_count -ne 1 -or
      $fakeSerial.state.write_count -ne 1 -or
      $fakeSerial.state.bytes.Count -ne 32) {
    throw 'SelfTest: #20 exactly-once write guard failed'
  }

  $ground = New-CaptureState -Role 'ground' -TagBase 'GCSTAT' `
      -WithMavlinkAnalysis
  $selfDefinitionSource = Join-Path `
      (Split-Path -Parent $PSScriptRoot) 'core\src\mavlink_frame.cpp'
  $selfDefinitions = Import-MavlinkDefinitions -Path $selfDefinitionSource
  $ground.Mavlink.Definitions = $selfDefinitions.definitions
  if ($selfDefinitions.count -lt 80) {
    throw 'SelfTest: authoritative all-message definition table is incomplete'
  }
  [byte[]]$prefix = New-Object byte[] 256
  for ($index = 0; $index -lt 256; ++$index) {
    $prefix[$index] = [byte]$index
  }
  Add-CaptureBytes -State $ground -Buffer $prefix -Count $prefix.Length
  $ground.Mavlink.InvalidCrc = [uint64]7
  $ground.Mavlink.InvalidLength = [uint64]3
  $ground.Mavlink.Unsupported = [uint64]5
  $ground.Mavlink.UnsupportedFlags = [uint64]4
  $ground.Mavlink.BadPayloadLength = [uint64]3
  $ground.Mavlink.BadCrc = [uint64]7
  $ground.Mavlink.NoiseBytes = [uint64]11
  [uint64]$invalidCrcAtBoundary = $ground.Mavlink.InvalidCrc
  [uint64]$invalidLengthAtBoundary = $ground.Mavlink.InvalidLength
  [uint64]$unsupportedAtBoundary = $ground.Mavlink.Unsupported
  [uint64]$unsupportedFlagsAtBoundary = $ground.Mavlink.UnsupportedFlags
  [uint64]$badPayloadAtBoundary = $ground.Mavlink.BadPayloadLength
  [uint64]$badCrcAtBoundary = $ground.Mavlink.BadCrc
  [uint64]$noiseAtBoundary = $ground.Mavlink.NoiseBytes
  Reset-MavlinkAnalysis -Parser $ground.Mavlink `
      -Reason 'selftest_analysis_boundary' -RawOffset $ground.Raw.Length

  function New-SelfTestParamValue {
    param(
      [string]$Id,
      [uint32]$ValueBits = [uint32]0x42640000,
      [byte]$SystemId = 1,
      [byte]$ComponentId = 1,
      [byte]$Sequence = 1
    )
    [byte[]]$payload = New-Object byte[] 25
    $payload[0] = [byte]($ValueBits -band 0xFF)
    $payload[1] = [byte](($ValueBits -shr 8) -band 0xFF)
    $payload[2] = [byte](($ValueBits -shr 16) -band 0xFF)
    $payload[3] = [byte](($ValueBits -shr 24) -band 0xFF)
    $payload[4] = 0x34
    $payload[5] = 0x12
    $payload[6] = 0xFF
    $payload[7] = 0xFF
    [byte[]]$idBytes = [System.Text.Encoding]::ASCII.GetBytes($Id)
    [Array]::Copy($idBytes, 0, $payload, 8,
        [Math]::Min(16, $idBytes.Length))
    $payload[24] = 6
    return New-Mavlink2TestFrame -MessageId 22 -Payload $payload `
        -CrcExtra 220 -Sequence $Sequence -SystemId $SystemId `
        -ComponentId $ComponentId
  }

  [byte[][]]$negativeFrames = @(
    (New-SelfTestParamValue -Id 'STAT_RUNTIME' -Sequence 10),
    (New-SelfTestParamValue -Id 'SERIAL1_BAUD' -SystemId 2 -Sequence 11),
    (New-SelfTestParamValue -Id 'SERIAL1_BAUD' `
        -ValueBits ([uint32]0x42680000) -Sequence 12))
  foreach ($frame in $negativeFrames) {
    Add-CaptureBytes -State $ground -Buffer $frame -Count $frame.Length
  }
  [byte[]]$exactFrame = New-SelfTestParamValue -Id 'SERIAL1_BAUD' `
      -Sequence 13
  Add-CaptureBytes -State $ground -Buffer $exactFrame -Count $exactFrame.Length
  if ($ground.Mavlink.ExactTargetEvents.Count -ne 1 -or
      $ground.Mavlink.ExactTargetEvents[0].sequence -ne 13) {
    throw 'SelfTest: strict #22 parser accepted a negative or lost the target'
  }
  $ground.Mavlink.Enabled = $false

  [string]$reportText = ([char]1) + ([char]2) +
      "GCSTAT1 q=17 ms=4294967296 a=1`n" +
      "GCSTAT2 q=17 ms=4294967296 b=2`n" +
      "GCSTAT3 q=17 ms=4294967296 c=3`n"
  [byte[]]$reportBytes = [System.Text.Encoding]::ASCII.GetBytes($reportText)
  foreach ($piece in @(1, 2, 5, 3, 11, 7, 19, 1000)) {
    if ($reportBytes.Length -eq 0) { break }
    [int]$count = [Math]::Min($piece, $reportBytes.Length)
    [byte[]]$chunk = New-Object byte[] $count
    [Array]::Copy($reportBytes, 0, $chunk, 0, $count)
    Add-CaptureBytes -State $ground -Buffer $chunk -Count $count
    if ($count -eq $reportBytes.Length) {
      $reportBytes = [byte[]]@()
    } else {
      [byte[]]$remaining = New-Object byte[] ($reportBytes.Length - $count)
      [Array]::Copy($reportBytes, $count, $remaining, 0, $remaining.Length)
      $reportBytes = $remaining
    }
  }
  $report = Select-CorrelatedReport -State $ground -StartLineIndex 0
  if (-not $report.complete -or $report.q_uint32 -ne 17 -or
      $report.ms_uint64 -ne [uint64]4294967296) {
    throw 'SelfTest: fragmented tagged q/ms report was not correlated'
  }
  $wrongQ = Select-CorrelatedReport -State $ground -StartLineIndex 0 `
      -ExpectedQ 18
  if ($wrongQ.complete -or (Get-NextQueryId -Current 17) -ne 18 -or
      (Get-NextQueryId -Current ([uint32]::MaxValue)) -ne 1) {
    throw 'SelfTest: query-id filter or wrap contract failed'
  }

  [byte[]]$raw = $ground.Raw.ToArray()
  if ($raw.Length -le 256) {
    throw 'SelfTest: contiguous raw capture did not retain later bytes'
  }
  for ($index = 0; $index -lt 256; ++$index) {
    if ($raw[$index] -ne [byte]$index) {
      throw 'SelfTest: one of the initial 256 raw bytes was discarded'
    }
  }
  if ($ground.Mavlink.ExplicitResets.Count -ne 1 -or
      $ground.Mavlink.ExplicitResets[0].raw_offset -ne 256) {
    throw 'SelfTest: analysis-only reset did not preserve the raw boundary'
  }
  if ($invalidCrcAtBoundary -eq 0 -or $invalidLengthAtBoundary -eq 0 -or
      ($ground.Mavlink.InvalidCrc - $invalidCrcAtBoundary) -ne 0 -or
      ($ground.Mavlink.InvalidLength - $invalidLengthAtBoundary) -ne 0 -or
      ($ground.Mavlink.Unsupported - $unsupportedAtBoundary) -ne 0 -or
      ($ground.Mavlink.UnsupportedFlags - $unsupportedFlagsAtBoundary) -ne 0 -or
      ($ground.Mavlink.BadPayloadLength - $badPayloadAtBoundary) -ne 0 -or
      ($ground.Mavlink.BadCrc - $badCrcAtBoundary) -ne 0 -or
      ($ground.Mavlink.NoiseBytes - $noiseAtBoundary) -ne 0 -or
      $ground.Mavlink.Buffer.Count -ne 0 -or
      $ground.Mavlink.ExpectedLength -ne 0) {
    throw 'SelfTest: M0-to-M1 parser integrity contract failed'
  }

  $badAnalysis = New-CaptureState -Role 'ground_bad' -TagBase 'GCSTAT' `
      -WithMavlinkAnalysis
  $badAnalysis.Mavlink.Definitions = $selfDefinitions.definitions
  Add-CaptureBytes -State $badAnalysis -Buffer ([byte[]]@(0x55)) -Count 1
  [byte[]]$heartbeatPayload = New-Object byte[] 9
  [byte[]]$badCrcFrame = New-Mavlink2TestFrame -MessageId 0 `
      -Payload $heartbeatPayload -CrcExtra 50 -Sequence 30
  $badCrcFrame[$badCrcFrame.Length - 1] =
      $badCrcFrame[$badCrcFrame.Length - 1] -bxor 0x80
  Add-CaptureBytes -State $badAnalysis -Buffer $badCrcFrame `
      -Count $badCrcFrame.Length
  [byte[]]$badLengthFrame = New-Mavlink2TestFrame -MessageId 0 `
      -Payload (New-Object byte[] 8) -CrcExtra 50 -Sequence 31
  Add-CaptureBytes -State $badAnalysis -Buffer $badLengthFrame `
      -Count $badLengthFrame.Length
  [byte[]]$unsupportedFrame = New-Mavlink2TestFrame -MessageId 999 `
      -Payload ([byte[]]@(0)) -CrcExtra 0 -Sequence 32
  Add-CaptureBytes -State $badAnalysis -Buffer $unsupportedFrame `
      -Count $unsupportedFrame.Length
  [byte[]]$unsupportedFlagsFrame = New-Mavlink2TestFrame -MessageId 0 `
      -Payload $heartbeatPayload -CrcExtra 50 -Sequence 33
  $unsupportedFlagsFrame[2] = 2
  Add-CaptureBytes -State $badAnalysis -Buffer $unsupportedFlagsFrame `
      -Count $unsupportedFlagsFrame.Length
  if ($badAnalysis.Mavlink.NoiseBytes -ne 1 -or
      $badAnalysis.Mavlink.BadCrc -ne 1 -or
      $badAnalysis.Mavlink.BadPayloadLength -ne 1 -or
      $badAnalysis.Mavlink.Unsupported -ne 1 -or
      $badAnalysis.Mavlink.UnsupportedFlags -ne 1 -or
      $badAnalysis.Mavlink.Buffer.Count -ne 0) {
    throw 'SelfTest: all-message badCRC/badlen/unsupported/noise gates failed'
  }
  $badAnalysis.Raw.Dispose()

  $heartbeatEvents = @(
    [pscustomobject]@{ message_id = 0; system_id = 2; component_id = 1; elapsed_ms = 500 },
    [pscustomobject]@{ message_id = 0; system_id = 1; component_id = 2; elapsed_ms = 750 },
    [pscustomobject]@{ message_id = 0; system_id = 1; component_id = 1; elapsed_ms = 1000 },
    [pscustomobject]@{ message_id = 0; system_id = 1; component_id = 1; elapsed_ms = 3000 },
    [pscustomobject]@{ message_id = 0; system_id = 1; component_id = 1; elapsed_ms = 5200 },
    [pscustomobject]@{ message_id = 0; system_id = 1; component_id = 1; elapsed_ms = 7000 },
    [pscustomobject]@{ message_id = 0; system_id = 1; component_id = 1; elapsed_ms = 8500 })
  $heartbeatPass = Get-HeartbeatWindowMetrics -Events $heartbeatEvents `
      -M0ElapsedMs 0 -R0ElapsedMs 5000 -M1ElapsedMs 9000
  if (-not $heartbeatPass.valid -or $heartbeatPass.count -ne 5 -or
      $heartbeatPass.first_gap_ms -ne 1000 -or
      $heartbeatPass.maximum_gap_ms -ne 2200 -or
      $heartbeatPass.tail_gap_ms -ne 500) {
    throw 'SelfTest: heartbeat first/consecutive/tail PASS contract failed'
  }
  $heartbeatGapFail = Get-HeartbeatWindowMetrics -Events @(
      [pscustomobject]@{ message_id = 0; system_id = 1; component_id = 1; elapsed_ms = 2600 },
      [pscustomobject]@{ message_id = 0; system_id = 1; component_id = 1; elapsed_ms = 6000 }) `
      -M0ElapsedMs 0 -R0ElapsedMs 4000 -M1ElapsedMs 9000
  $heartbeatCountFail = Get-HeartbeatWindowMetrics -Events @(
      [pscustomobject]@{ message_id = 0; system_id = 1; component_id = 1; elapsed_ms = 1000 }) `
      -M0ElapsedMs 0 -R0ElapsedMs 2000 -M1ElapsedMs 3000
  if ($heartbeatGapFail.valid -or
      $heartbeatGapFail.gap_exceedances.Count -ne 3 -or
      $heartbeatCountFail.valid) {
    throw 'SelfTest: heartbeat gap/count FAIL contract failed'
  }

  $targetPre = [pscustomobject]@{ elapsed_ms = 4999; sequence = 1 }
  $targetAtR0 = [pscustomobject]@{ elapsed_ms = 5000; sequence = 9 }
  $targetBeforeM0 = [pscustomobject]@{ elapsed_ms = -1; sequence = 8 }
  $targetGood = [pscustomobject]@{ elapsed_ms = 6000; sequence = 2 }
  $targetDuplicate = [pscustomobject]@{ elapsed_ms = 7000; sequence = 3 }
  $targetPass = Get-TargetResponseWindow `
      -Events @($targetBeforeM0, $targetGood) -M0ElapsedMs 0 `
      -R0ElapsedMs 5000 -M1ElapsedMs 25000
  $targetCausalFail = Get-TargetResponseWindow `
      -Events @($targetPre, $targetAtR0, $targetGood) -M0ElapsedMs 0 `
      -R0ElapsedMs 5000 -M1ElapsedMs 25000
  $targetDuplicateFail = Get-TargetResponseWindow `
      -Events @($targetGood, $targetDuplicate) -M0ElapsedMs 0 `
      -R0ElapsedMs 5000 -M1ElapsedMs 25000
  $targetLateFail = Get-TargetResponseWindow -Events @(
      [pscustomobject]@{ elapsed_ms = 25501; sequence = 4 }) `
      -M0ElapsedMs 0 -R0ElapsedMs 5000 -M1ElapsedMs 30000
  $targetTimeoutFail = Get-TargetResponseWindow `
      -Events @($targetBeforeM0) -M0ElapsedMs 0 `
      -R0ElapsedMs 5000 -M1ElapsedMs 25000
  if (-not $targetPass.valid -or $targetPass.response_count -ne 1 -or
      $targetPass.pre_or_at_r0_count -ne 0 -or
      $targetPass.before_m0_count -ne 1 -or $targetCausalFail.valid -or
      $targetCausalFail.pre_or_at_r0_count -ne 2 -or
      $targetDuplicateFail.valid -or
      $targetDuplicateFail.duplicate_count -ne 1 -or
      $targetLateFail.valid -or $targetTimeoutFail.valid) {
    throw 'SelfTest: strict response R0/count/timeout contract failed'
  }

  $baselineGroundFields = @{
    ready = 1; fail = 0; rse = 0; boot = 101
    uv20 = 0; upfwd = 0; uqf = 0; ufdq = 0; utx = 0; upb = 0
    dtx = 0; s1rx = 0; s1ok = 0; s1q = 0; s1bq = 0
    s1ega = 0; s1egc = 0; dlf = 0
  }
  $postGroundFields = @{
    ready = 1; fail = 0; rse = 0; boot = 101
    uv20 = 1; upfwd = 1; uqf = 1; ufdq = 1; utx = 1; upb = 32
    dtx = 1; s1rx = 1; s1ok = 1; s1q = 1; s1bq = 1
    s1ega = 1; s1egc = 1; dlf = 1
  }
  $baselineVehicleFields = @{
    r = 1; f = 0; boot = 202; r20 = 0; d620 = 0; td6ex = 0
    pvs1 = 0; td7mi = 0; tpf = 0; ttk = 0; tei = 0
    tcb = 0; tcf = 0
  }
  $postVehicleFields = @{
    r = 1; f = 0; boot = 202; r20 = 1; d620 = 1; td6ex = 1
    pvs1 = 1; td7mi = 1; tpf = 2; ttk = 2; tei = 2
    tcb = 32; tcf = 1
  }
  foreach ($key in @('ci', 'cc', 'cuv', 'cut', 'cm', 'ucr', 'uiv',
      'udf', 'udb', 'uoe', 'urc', 'uic', 'dli', 'dlo', 'upinv', 'rfd',
      'epinv', 'rfinv', 'rfbq', 'obfq',
      'obfr', 'obif', 'obof', 'obdf', 'obdb', 's1dc', 's1d', 's1pc',
      's1iv', 's1ego', 'hd', 'ubdrop', 'dnak', 'xnak', 'inak', 'pwto',
      'psfail', 'prej', 'obf', 'obb', 'uqfb', 'uqb', 'ubuf', 'dlq',
      's1egp')) {
    if (-not $baselineGroundFields.ContainsKey($key)) {
      $baselineGroundFields[$key] = 0
    }
    if (-not $postGroundFields.ContainsKey($key)) {
      $postGroundFields[$key] = 0
    }
  }
  foreach ($key in @('cc', 'rcr', 'riv', 'ocr', 'oiv', 'eiv', 'eov',
      'out', 'd6cr', 'd7cr', 'd7iv', 'pvbad', 'pvov', 'eo', 'sc',
      'evo', 'pb', 'd7pb', 'qb', 'tar')) {
    $baselineVehicleFields[$key] = 0
    $postVehicleFields[$key] = 0
  }
  $offlineBaselineGround = New-OfflineSnapshot -Fields $baselineGroundFields
  $offlinePostGround = New-OfflineSnapshot -Fields $postGroundFields -Q 2 -Ms 200
  $offlineBaselineVehicle = New-OfflineSnapshot -Fields $baselineVehicleFields
  $offlinePostVehicle = New-OfflineSnapshot -Fields $postVehicleFields -Q 2 -Ms 200
  $setupPass = Test-BaselineSetup -GroundSnapshot $offlineBaselineGround `
      -VehicleSnapshot $offlineBaselineVehicle
  $stagePass = Get-StageAssessment -BaselineGround $offlineBaselineGround `
      -PostGround $offlinePostGround -BaselineVehicle $offlineBaselineVehicle `
      -PostVehicle $offlinePostVehicle
  if (-not $setupPass.valid -or -not $stagePass.valid) {
    throw 'SelfTest: valid baseline/stage chain was rejected'
  }
  foreach ($normalCounter in @{
      rfd = 48; rfbq = 89; obfq = 89; obfr = 86; obdf = 3;
      obdb = 63; ubdrop = 48; obf = 2; obb = 42
    }.GetEnumerator()) {
    $offlinePostGround.responses[0].fields.PSObject.Properties[
        $normalCounter.Key].Value = $normalCounter.Value
  }
  $offlinePostVehicle.responses[0].fields.d7iv = 1806
  $offlinePostVehicle.responses[0].fields.d7pb = 6
  $normalPacerTrafficPass = Get-StageAssessment `
      -BaselineGround $offlineBaselineGround -PostGround $offlinePostGround `
      -BaselineVehicle $offlineBaselineVehicle -PostVehicle $offlinePostVehicle
  if (-not $normalPacerTrafficPass.valid) {
    throw 'SelfTest: normal HB backlog/replay counters rejected target path'
  }
  $offlinePostGround.responses[0].fields.s1bq = 0
  $directDispositionPass = Get-StageAssessment `
      -BaselineGround $offlineBaselineGround -PostGround $offlinePostGround `
      -BaselineVehicle $offlineBaselineVehicle -PostVehicle $offlinePostVehicle
  $offlinePostGround.responses[0].fields.s1bq = 2
  $duplicateBacklogFail = Get-StageAssessment `
      -BaselineGround $offlineBaselineGround -PostGround $offlinePostGround `
      -BaselineVehicle $offlineBaselineVehicle -PostVehicle $offlinePostVehicle
  if (-not $directDispositionPass.valid -or $duplicateBacklogFail.valid -or
      $duplicateBacklogFail.first_missing -ne 'ground_strict_disposition') {
    throw 'SelfTest: optional-once target backlog disposition gate failed'
  }
  $offlinePostGround.responses[0].fields.s1bq = 1
  $offlinePostVehicle.responses[0].fields.tpf = 0
  $commitStateFail = Get-StageAssessment `
      -BaselineGround $offlineBaselineGround -PostGround $offlinePostGround `
      -BaselineVehicle $offlineBaselineVehicle -PostVehicle $offlinePostVehicle
  if ($commitStateFail.valid -or
      $commitStateFail.first_missing -ne 'vehicle_commit_preflight_ok') {
    throw 'SelfTest: atomic commit zero-to-success gate failed'
  }
  $offlinePostVehicle.responses[0].fields.tpf = 2
  $offlinePostVehicle.responses[0].fields.d620 = 0
  $stageFail = Get-StageAssessment -BaselineGround $offlineBaselineGround `
      -PostGround $offlinePostGround -BaselineVehicle $offlineBaselineVehicle `
      -PostVehicle $offlinePostVehicle
  if ($stageFail.valid -or $stageFail.first_missing -ne 'vehicle_d6_20') {
    throw 'SelfTest: stage first-missing localization failed'
  }
  $offlinePostVehicle.responses[0].fields.d620 = 1
  $offlinePostGround.responses[0].fields.upinv = 1
  $groundDiagnosticFail = Get-StageAssessment `
      -BaselineGround $offlineBaselineGround -PostGround $offlinePostGround `
      -BaselineVehicle $offlineBaselineVehicle -PostVehicle $offlinePostVehicle
  if ($groundDiagnosticFail.valid -or
      $groundDiagnosticFail.first_missing -ne
          'ground_diagnostic_delta_zero_upinv') {
    throw 'SelfTest: Ground invalid/drop/overflow/backlog gate failed'
  }
  $offlinePostGround.responses[0].fields.upinv = 0
  $offlinePostVehicle.responses[0].fields.pvov = 1
  $diagnosticDeltaFail = Get-StageAssessment `
      -BaselineGround $offlineBaselineGround -PostGround $offlinePostGround `
      -BaselineVehicle $offlineBaselineVehicle -PostVehicle $offlinePostVehicle
  if ($diagnosticDeltaFail.valid -or
      $diagnosticDeltaFail.first_missing -ne
          'vehicle_diagnostic_delta_zero_pvov') {
    throw 'SelfTest: invalid/drop/overflow/backlog delta-zero gate failed'
  }
  $offlinePostVehicle.responses[0].fields.pvov = 0
  $offlinePostVehicle.ms_uint64 = 100
  $snapshotTimeFail = Get-StageAssessment `
      -BaselineGround $offlineBaselineGround -PostGround $offlinePostGround `
      -BaselineVehicle $offlineBaselineVehicle -PostVehicle $offlinePostVehicle
  if ($snapshotTimeFail.valid -or
      $snapshotTimeFail.first_missing -ne 'vehicle_snapshot_ms_monotonic') {
    throw 'SelfTest: post snapshot ms monotonic gate failed'
  }
  $offlinePostVehicle.ms_uint64 = 200
  $offlineBaselineGround.responses[0].fields.ready = 0
  $setupFail = Test-BaselineSetup -GroundSnapshot $offlineBaselineGround `
      -VehicleSnapshot $offlineBaselineVehicle
  $noWriteSerial = New-OfflineWriteSerial
  $noWriteInjection = [pscustomobject]@{ write_count = 0
    final_write_elapsed_ms = $null; final_write_utc = $null }
  if ($setupFail.valid) {
    Write-ExactRequestOnce -Serial $noWriteSerial -Fixture $request `
        -InjectionState $noWriteInjection
  }
  if ($setupFail.valid -or $noWriteSerial.state.write_count -ne 0 -or
      $noWriteInjection.write_count -ne 0) {
    throw 'SelfTest: invalid baseline did not suppress request injection'
  }

  $powerPass = Test-OfflinePowerSequence -RequiredAbsentMs 5000 -Samples @(
      [pscustomobject]@{ elapsed_ms = 0; vehicle_present = $true; ground_present = $true },
      [pscustomobject]@{ elapsed_ms = 1000; vehicle_present = $false; ground_present = $false },
      [pscustomobject]@{ elapsed_ms = 6000; vehicle_present = $false; ground_present = $false },
      [pscustomobject]@{ elapsed_ms = 7000; vehicle_present = $true; ground_present = $true })
  $powerFail = Test-OfflinePowerSequence -RequiredAbsentMs 5000 -Samples @(
      [pscustomobject]@{ elapsed_ms = 0; vehicle_present = $false; ground_present = $false },
      [pscustomobject]@{ elapsed_ms = 4999; vehicle_present = $false; ground_present = $false },
      [pscustomobject]@{ elapsed_ms = 5000; vehicle_present = $true; ground_present = $true })
  if (-not $powerPass.power_off_confirmed -or
      -not $powerPass.both_enumerated_after_confirmation -or
      $powerFail.power_off_confirmed) {
    throw 'SelfTest: power-off confirmation/enumeration timeline contract failed'
  }
  if (-not (Test-FooterCloseOrdering -FooterFsyncElapsedMs 100 `
          -VehicleCloseElapsedMs 101 -GroundCloseElapsedMs 102) -or
      (Test-FooterCloseOrdering -FooterFsyncElapsedMs 103 `
          -VehicleCloseElapsedMs 101 -GroundCloseElapsedMs 102)) {
    throw 'SelfTest: footer-fsync-before-close ordering contract failed'
  }
  $ground.Raw.Dispose()
  $script:RunWatch.Stop()
  Write-Host ('SELFTEST PASS run_dual_diag_continuous_hil.ps1 ' +
      '(offline; no port enumeration, SerialPort construction, or COM open)')
}

# This return deliberately precedes Add-Type, GetPortNames and every
# System.IO.Ports.SerialPort construction. The self-test is strictly offline.
if ($SelfTest.IsPresent) {
  Invoke-OfflineSelfTest
  return
}

function Add-TimelineEvent {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [hashtable]$Details = @{}
  )
  $script:Timeline.Add([pscustomobject][ordered]@{
    name = $Name
    elapsed_ms = [Math]::Round($script:RunWatch.Elapsed.TotalMilliseconds, 3)
    utc = (Get-Date).ToUniversalTime().ToString('o')
    phase = $script:CurrentPhase
    details = [pscustomobject]$Details
  })
}

function Read-SerialAvailable {
  param(
    $Serial,
    $State
  )
  if ($null -eq $Serial -or -not $Serial.IsOpen) {
    return 0
  }
  [int]$total = 0
  [byte[]]$buffer = New-Object byte[] 4096
  for ($iteration = 0; $iteration -lt 64; ++$iteration) {
    [int]$available = $Serial.BytesToRead
    if ($available -le 0) { break }
    [int]$wanted = [Math]::Min($available, $buffer.Length)
    try {
      [int]$read = $Serial.Read($buffer, 0, $wanted)
    } catch [System.TimeoutException] {
      break
    }
    if ($read -le 0) { break }
    Add-CaptureBytes -State $State -Buffer $buffer -Count $read
    $total += $read
  }
  return $total
}

function Invoke-PumpPair {
  param($VehicleSerial, $VehicleState, $GroundSerial, $GroundState)
  [int]$read = 0
  $read += Read-SerialAvailable -Serial $VehicleSerial -State $VehicleState
  $read += Read-SerialAvailable -Serial $GroundSerial -State $GroundState
  return $read
}

function Invoke-CaptureInterval {
  param(
    [Parameter(Mandatory = $true)][int]$Milliseconds,
    [Parameter(Mandatory = $true)][string]$Phase,
    $VehicleSerial, $VehicleState, $GroundSerial, $GroundState
  )
  $script:CurrentPhase = $Phase
  Add-TimelineEvent -Name ($Phase + '_start')
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  while ($watch.ElapsedMilliseconds -lt $Milliseconds) {
    [int]$read = Invoke-PumpPair -VehicleSerial $VehicleSerial `
        -VehicleState $VehicleState -GroundSerial $GroundSerial `
        -GroundState $GroundState
    if ($read -eq 0) {
      Start-Sleep -Milliseconds 2
    }
  }
  [void](Invoke-PumpPair -VehicleSerial $VehicleSerial `
      -VehicleState $VehicleState -GroundSerial $GroundSerial `
      -GroundState $GroundState)
  Add-TimelineEvent -Name ($Phase + '_end')
}

function Invoke-SnapshotQuery {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)]$Serial,
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][byte[]]$Command,
    [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
    [Nullable[uint32]]$ExpectedQ,
    $VehicleSerial, $VehicleState, $GroundSerial, $GroundState
  )
  $script:CurrentPhase = $Name
  [int]$startLineIndex = $State.TaggedLines.Count
  [long]$startRawOffset = $State.Raw.Length
  [double]$startedMs = $script:RunWatch.Elapsed.TotalMilliseconds
  Add-TimelineEvent -Name ($Name + '_query_tx') -Details @{
    role = $State.Role
    command_hex = (($Command | ForEach-Object { $_.ToString('X2') }) -join ' ')
    raw_rx_offset_at_tx = $startRawOffset
  }
  $Serial.Write($Command, 0, $Command.Length)
  $Serial.BaseStream.Flush()
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $report = Select-CorrelatedReport -State $State `
      -StartLineIndex $startLineIndex -ExpectedQ $ExpectedQ
  while (-not $report.complete -and
      $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    [int]$read = Invoke-PumpPair -VehicleSerial $VehicleSerial `
        -VehicleState $VehicleState -GroundSerial $GroundSerial `
        -GroundState $GroundState
    $report = Select-CorrelatedReport -State $State `
        -StartLineIndex $startLineIndex -ExpectedQ $ExpectedQ
    if ($read -eq 0 -and -not $report.complete) {
      Start-Sleep -Milliseconds 2
    }
  }
  [void](Invoke-PumpPair -VehicleSerial $VehicleSerial `
      -VehicleState $VehicleState -GroundSerial $GroundSerial `
      -GroundState $GroundState)
  $report = Select-CorrelatedReport -State $State `
      -StartLineIndex $startLineIndex -ExpectedQ $ExpectedQ
  Add-TimelineEvent -Name ($Name + '_complete') -Details @{
    status = $(if ($report.complete) { 'COMPLETE' } else { 'TIMEOUT' })
    q = $report.q_uint32
    ms = $report.ms_uint64
  }
  return [pscustomobject][ordered]@{
    name = $Name
    role = $State.Role
    status = $(if ($report.complete) { 'COMPLETE' } else { 'TIMEOUT' })
    query_count = 1
    query_ascii = [System.Text.Encoding]::ASCII.GetString($Command).Replace("`n", '\n')
    query_hex = (($Command | ForEach-Object { $_.ToString('X2') }) -join ' ')
    expected_q = $(if ($null -ne $ExpectedQ) { [uint32]$ExpectedQ } else { $null })
    q_uint32 = $report.q_uint32
    ms_uint64 = $report.ms_uint64
    started_elapsed_ms = [Math]::Round($startedMs, 3)
    finished_elapsed_ms = [Math]::Round(
        $script:RunWatch.Elapsed.TotalMilliseconds, 3)
    raw_rx_start_offset = $startRawOffset
    raw_rx_end_offset = $State.Raw.Length
    responses = @($report.responses)
  }
}

function Wait-ForBothPorts {
  param([string]$First, [string]$Second, [int]$TimeoutSeconds)
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  [string[]]$lastPorts = @()
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $lastPorts = @([System.IO.Ports.SerialPort]::GetPortNames())
    [bool]$firstFound = @($lastPorts | Where-Object {
        $_ -ieq $First }).Count -gt 0
    [bool]$secondFound = @($lastPorts | Where-Object {
        $_ -ieq $Second }).Count -gt 0
    if ($firstFound -and $secondFound) {
      return [pscustomobject][ordered]@{
        found = $true
        elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
        ports = @($lastPorts | Sort-Object)
      }
    }
    Start-Sleep -Milliseconds 100
  }
  return [pscustomobject][ordered]@{
    found = $false
    elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
    ports = @($lastPorts | Sort-Object)
  }
}

function Wait-ForBothPortsAbsent {
  param(
    [string]$First,
    [string]$Second,
    [int]$RequiredAbsentMs,
    [int]$TimeoutSeconds
  )
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  [Nullable[double]]$absentSinceMs = $null
  [string[]]$lastPorts = @()
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $lastPorts = @([System.IO.Ports.SerialPort]::GetPortNames())
    [bool]$firstFound = @($lastPorts | Where-Object {
        $_ -ieq $First }).Count -gt 0
    [bool]$secondFound = @($lastPorts | Where-Object {
        $_ -ieq $Second }).Count -gt 0
    [double]$nowMs = $watch.Elapsed.TotalMilliseconds
    if (-not $firstFound -and -not $secondFound) {
      if ($null -eq $absentSinceMs) { $absentSinceMs = $nowMs }
      if ($nowMs - [double]$absentSinceMs -ge $RequiredAbsentMs) {
        return [pscustomobject][ordered]@{
          confirmed = $true
          required_absent_ms = $RequiredAbsentMs
          continuous_absent_ms = [Math]::Round(
              $nowMs - [double]$absentSinceMs, 3)
          elapsed_ms = [Math]::Round($nowMs, 3)
          ports = @($lastPorts | Sort-Object)
        }
      }
    } else {
      $absentSinceMs = $null
    }
    Start-Sleep -Milliseconds 100
  }
  return [pscustomobject][ordered]@{
    confirmed = $false
    required_absent_ms = $RequiredAbsentMs
    continuous_absent_ms = 0
    elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
    ports = @($lastPorts | Sort-Object)
  }
}

function New-ConfiguredSerialPort {
  param([string]$Port, [int]$Baud)
  $serial = New-Object System.IO.Ports.SerialPort
  $serial.PortName = $Port
  $serial.BaudRate = $Baud
  $serial.DataBits = 8
  $serial.Parity = [System.IO.Ports.Parity]::None
  $serial.StopBits = [System.IO.Ports.StopBits]::One
  $serial.Handshake = [System.IO.Ports.Handshake]::None
  $serial.ReadTimeout = 20
  $serial.WriteTimeout = 2000
  $serial.DtrEnable = $false
  $serial.RtsEnable = $false
  return $serial
}

function Get-BytesSha256 {
  param([byte[]]$Bytes)
  $algorithm = [System.Security.Cryptography.SHA256]::Create()
  try {
    [byte[]]$hash = $algorithm.ComputeHash($Bytes)
  } finally {
    $algorithm.Dispose()
  }
  return (($hash | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Get-InitialPrefix {
  param([byte[]]$Bytes)
  if ($Bytes.Length -eq 0) {
    return [byte[]]@()
  }
  [int]$length = [Math]::Min(256, $Bytes.Length)
  [byte[]]$prefix = New-Object byte[] $length
  [Array]::Copy($Bytes, 0, $prefix, 0, $length)
  return $prefix
}

function Write-JsonNoBom {
  param([string]$Path, $Value, [int]$Depth = 12)
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,
      (($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine),
      $encoding)
}

function Write-BytesDurable {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowNull()][AllowEmptyCollection()]
    [Parameter(Mandatory = $true)][byte[]]$Bytes
  )
  if ($null -eq $Bytes) {
    $Bytes = [byte[]]@()
  }
  $stream = [System.IO.FileStream]::new(
      $Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::Read, 4096, [System.IO.FileOptions]::WriteThrough)
  try {
    if ($Bytes.Length -gt 0) {
      $stream.Write($Bytes, 0, $Bytes.Length)
    }
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
}

function Write-TextDurable {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowEmptyString()][Parameter(Mandatory = $true)][string]$Text
  )
  $encoding = New-Object System.Text.UTF8Encoding($false)
  Write-BytesDurable -Path $Path -Bytes $encoding.GetBytes($Text)
}

function Write-JsonDurable {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value,
    [int]$Depth = 20
  )
  [string]$text = ($Value | ConvertTo-Json -Depth $Depth) +
      [Environment]::NewLine
  Write-TextDurable -Path $Path -Text $text
}

function Write-SnapshotText {
  param([string]$Path, $Snapshot)
  [string]$text = ''
  if ($null -ne $Snapshot -and $Snapshot.status -eq 'COMPLETE') {
    $text = (($Snapshot.responses | ForEach-Object { $_.line }) -join "`n") + "`n"
  }
  Write-TextDurable -Path $Path -Text $text
}

# Any otherwise-unhandled setup/finalization exception is an infrastructure
# ERROR (exit 2), never a semantic HIL FAIL (exit 1). If this run already owns
# a new evidence directory, leave a durable secondary error record.
trap {
  [string]$unhandledMessage = "unhandled runner error: $($_.Exception.Message)"
  try {
    if ($script:OutputDirectoryOwned -and
        -not [string]::IsNullOrWhiteSpace($OutputDirectory) -and
        (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
      Write-JsonDurable `
          -Path (Join-Path $OutputDirectory 'runner_unhandled_error.json') `
          -Value ([ordered]@{
            schema_version = 1; status = 'ERROR'; completed = $false
            written_utc = (Get-Date).ToUniversalTime().ToString('o')
            error = $unhandledMessage
          })
    }
  } catch {
    # Console error and exit code remain authoritative if disk finalization also
    # fails; never reopen a COM handle here.
  }
  [Console]::Error.WriteLine($unhandledMessage)
  exit 2
}

if ([string]::Equals($VehiclePort, $GroundPort,
    [System.StringComparison]::OrdinalIgnoreCase)) {
  throw 'VehiclePort and GroundPort must be different ports'
}
if ([string]::IsNullOrWhiteSpace($FixturePath) -or
    -not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) {
  throw 'FixturePath must name an existing exact 32-byte PARAM_REQUEST_READ fixture'
}
[byte[]]$fixture = [System.IO.File]::ReadAllBytes(
    (Resolve-Path -LiteralPath $FixturePath).Path)
$fixtureContract = Test-ExactRequestFixture -Bytes $fixture
if (-not $fixtureContract.valid) {
  throw "Fixture contract failed: $($fixtureContract.errors -join '; ')"
}

if (-not ('System.IO.Ports.SerialPort' -as [type])) {
  Add-Type -AssemblyName System.IO.Ports
}

$repo = Split-Path -Parent $PSScriptRoot
$mavlinkDefinitionSet = Import-MavlinkDefinitions -Path `
    (Join-Path $repo 'core\src\mavlink_frame.cpp')
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $repo `
      "runs\hil\HIL-DUAL-DIAG-CONTINUOUS-001\$timestamp"
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite existing HIL evidence: $OutputDirectory"
}
$parentDirectory = Split-Path -Parent $OutputDirectory
if ($parentDirectory -and -not (Test-Path -LiteralPath $parentDirectory)) {
  New-Item -ItemType Directory -Force -Path $parentDirectory | Out-Null
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$script:OutputDirectoryOwned = $true

$script:RunWatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:Timeline = New-Object 'System.Collections.Generic.List[object]'
$script:CurrentPhase = 'confirm_power_off'
$vehicleCapture = New-CaptureState -Role 'vehicle' -TagBase 'VCSTAT'
$groundCapture = New-CaptureState -Role 'ground' -TagBase 'GCSTAT' `
    -WithMavlinkAnalysis
$groundCapture.Mavlink.Definitions = $mavlinkDefinitionSet.definitions
$vehicleSerial = $null
$groundSerial = $null
$powerOffWait = $null
$portWait = $null
$baselineVehicle = $null
$baselineGround = $null
$postGround = $null
$postVehicle = $null
$baselineSetup = $null
$setupInvalid = $false
$stageAssessment = $null
$heartbeatMetrics = $null
$targetWindow = $null
$parserIntegrity = $null
$targetResponse = $null
$m0 = $null
$r0 = $null
$m1 = $null
$m0InvalidCrc = $null
$m0InvalidLength = $null
$m0ParserCounters = $null
$r0CausalGate = $null
$failure = $null
$footerRecorded = $false
$footerSequenceCompleted = $false
$footerFsyncElapsedMs = $null
$preCloseStatus = 'ERROR'
$vehicleOpenCount = 0
$groundOpenCount = 0
$vehicleCloseElapsedMs = $null
$groundCloseElapsedMs = $null
[byte[]]$vehicleRaw = [byte[]]@()
[byte[]]$groundRaw = [byte[]]@()
$errors = New-Object System.Collections.Generic.List[string]
$injection = [pscustomobject][ordered]@{
  write_count = 0
  final_write_elapsed_ms = $null
  final_write_utc = $null
}
[byte[]]$vehicleCommand = [System.Text.Encoding]::ASCII.GetBytes("VCSTAT?`n")
[byte[]]$groundCommand = [System.Text.Encoding]::ASCII.GetBytes("VCGSTAT?`n")

try {
  $powerOffWait = Wait-ForBothPortsAbsent -First $VehiclePort `
      -Second $GroundPort -RequiredAbsentMs $PowerOffConfirmMs `
      -TimeoutSeconds $PortWaitTimeoutSeconds
  if (-not $powerOffWait.confirmed) {
    throw ("Both target ports were not continuously absent for {0} ms " +
        "within {1} seconds" -f $PowerOffConfirmMs, $PortWaitTimeoutSeconds)
  }
  Write-Host 'POWER_OFF_CONFIRMED_WAITING_FOR_PORTS'
  Add-TimelineEvent -Name 'POWER_OFF_CONFIRMED_WAITING_FOR_PORTS' -Details @{
    required_absent_ms = $PowerOffConfirmMs
    observed_absent_ms = $powerOffWait.continuous_absent_ms
  }
  $script:CurrentPhase = 'wait_for_enumeration_after_power_off'
  $portWait = Wait-ForBothPorts -First $VehiclePort -Second $GroundPort `
      -TimeoutSeconds $PortWaitTimeoutSeconds
  if (-not $portWait.found) {
    throw "Ports did not enumerate within $PortWaitTimeoutSeconds seconds: $($portWait.ports -join ', ')"
  }
  Add-TimelineEvent -Name 'ports_enumerated' -Details @{
    ports = ($portWait.ports -join ',')
  }

  $vehicleSerial = New-ConfiguredSerialPort -Port $VehiclePort `
      -Baud $VehicleBaud
  $groundSerial = New-ConfiguredSerialPort -Port $GroundPort -Baud $GroundBaud
  $vehicleSerial.Open()
  ++$vehicleOpenCount
  Add-TimelineEvent -Name 'vehicle_open' -Details @{ port = $VehiclePort }
  $groundSerial.Open()
  ++$groundOpenCount
  Add-TimelineEvent -Name 'ground_open' -Details @{ port = $GroundPort }

  Invoke-CaptureInterval -Milliseconds 3000 -Phase 'boot_prefix_0_3s' `
      -VehicleSerial $vehicleSerial -VehicleState $vehicleCapture `
      -GroundSerial $groundSerial -GroundState $groundCapture
  Reset-MavlinkAnalysis -Parser $groundCapture.Mavlink `
      -Reason 'boot_prefix_T0_plus_3s_analysis_boundary' `
      -RawOffset $groundCapture.Raw.Length
  Invoke-CaptureInterval -Milliseconds 12000 -Phase 'live_observe_3_15s' `
      -VehicleSerial $vehicleSerial -VehicleState $vehicleCapture `
      -GroundSerial $groundSerial -GroundState $groundCapture

  $baselineVehicle = Invoke-SnapshotQuery -Name 'baseline_vehicle' `
      -Serial $vehicleSerial -State $vehicleCapture -Command $vehicleCommand `
      -TimeoutSeconds $SnapshotTimeoutSeconds -ExpectedQ $null `
      -VehicleSerial $vehicleSerial -VehicleState $vehicleCapture `
      -GroundSerial $groundSerial -GroundState $groundCapture
  if ($baselineVehicle.status -ne 'COMPLETE') {
    $errors.Add('Vehicle baseline VCSTAT snapshot timed out')
  }
  $baselineGround = Invoke-SnapshotQuery -Name 'baseline_ground' `
      -Serial $groundSerial -State $groundCapture -Command $groundCommand `
      -TimeoutSeconds $SnapshotTimeoutSeconds -ExpectedQ $null `
      -VehicleSerial $vehicleSerial -VehicleState $vehicleCapture `
      -GroundSerial $groundSerial -GroundState $groundCapture
  if ($baselineGround.status -ne 'COMPLETE') {
    $errors.Add('Ground baseline VCGSTAT snapshot timed out')
  }

  $baselineSetup = Test-BaselineSetup -GroundSnapshot $baselineGround `
      -VehicleSnapshot $baselineVehicle
  $setupInvalid = -not $baselineSetup.valid
  if ($setupInvalid) {
    $errors.Add('setup_invalid: baseline readiness/fail/boot contract rejected; #20 suppressed')
    Add-TimelineEvent -Name 'baseline_stop_no_request' -Details @{
      write_count = $injection.write_count
      failed_checks = @($baselineSetup.checks | Where-Object { -not $_.valid }).Count
    }
    Invoke-CaptureInterval -Milliseconds 3000 -Phase 'setup_invalid_observe_3s' `
        -VehicleSerial $vehicleSerial -VehicleState $vehicleCapture `
        -GroundSerial $groundSerial -GroundState $groundCapture
  } else {
    Invoke-CaptureInterval -Milliseconds 3000 -Phase 'post_baseline_recovery_3s' `
        -VehicleSerial $vehicleSerial -VehicleState $vehicleCapture `
        -GroundSerial $groundSerial -GroundState $groundCapture
    $script:CurrentPhase = 'M0_pre_request_lead_5s'
    Reset-MavlinkAnalysis -Parser $groundCapture.Mavlink `
        -Reason 'M0_post_recovery_continuous_analysis_start' `
        -RawOffset $groundCapture.Raw.Length
    $m0InvalidCrc = [uint64]$groundCapture.Mavlink.InvalidCrc
    $m0InvalidLength = [uint64]$groundCapture.Mavlink.InvalidLength
    $m0ParserCounters = [pscustomobject][ordered]@{
      unsupported = [uint64]$groundCapture.Mavlink.Unsupported
      unsupported_flags = [uint64]$groundCapture.Mavlink.UnsupportedFlags
      bad_payload_length = [uint64]$groundCapture.Mavlink.BadPayloadLength
      bad_crc = [uint64]$groundCapture.Mavlink.BadCrc
      noise_bytes = [uint64]$groundCapture.Mavlink.NoiseBytes
      invalid_crc = $m0InvalidCrc
      invalid_length = $m0InvalidLength
    }
    $m0 = [pscustomobject][ordered]@{
      elapsed_ms = [Math]::Round($script:RunWatch.Elapsed.TotalMilliseconds, 3)
      utc = (Get-Date).ToUniversalTime().ToString('o')
      ground_raw_offset = $groundCapture.Raw.Length
      invalid_crc_baseline = $m0InvalidCrc
      invalid_length_baseline = $m0InvalidLength
      parser_counters = $m0ParserCounters
    }
    Add-TimelineEvent -Name 'M0_analysis_start'
    Invoke-CaptureInterval -Milliseconds 5000 -Phase 'M0_pre_request_lead_5s' `
        -VehicleSerial $vehicleSerial -VehicleState $vehicleCapture `
        -GroundSerial $groundSerial -GroundState $groundCapture

    $script:CurrentPhase = 'R0_causal_boundary'
    $r0BoundaryWait = [System.Diagnostics.Stopwatch]::StartNew()
    do {
      [int]$read = Invoke-PumpPair -VehicleSerial $vehicleSerial `
          -VehicleState $vehicleCapture -GroundSerial $groundSerial `
          -GroundState $groundCapture
      if ($groundCapture.Mavlink.Buffer.Count -eq 0 -and
          $groundCapture.Mavlink.ExpectedLength -eq 0) { break }
      if ($read -eq 0) { Start-Sleep -Milliseconds 2 }
    } while ($r0BoundaryWait.ElapsedMilliseconds -lt 250)
    [double]$r0GateElapsedMs =
        $script:RunWatch.Elapsed.TotalMilliseconds
    [int]$preRequestExactCount = @(
      $groundCapture.Mavlink.ExactTargetEvents | Where-Object {
        [double]$_.elapsed_ms -ge [double]$m0.elapsed_ms -and
        [double]$_.elapsed_ms -le $r0GateElapsedMs
      }).Count
    $r0CausalGate = [pscustomobject][ordered]@{
      valid = ($groundCapture.Mavlink.Buffer.Count -eq 0 -and
          $groundCapture.Mavlink.ExpectedLength -eq 0 -and
          $preRequestExactCount -eq 0 -and
          ([uint64]$groundCapture.Mavlink.Unsupported -
            [uint64]$m0ParserCounters.unsupported) -eq 0 -and
          ([uint64]$groundCapture.Mavlink.UnsupportedFlags -
            [uint64]$m0ParserCounters.unsupported_flags) -eq 0 -and
          ([uint64]$groundCapture.Mavlink.BadPayloadLength -
            [uint64]$m0ParserCounters.bad_payload_length) -eq 0 -and
          ([uint64]$groundCapture.Mavlink.BadCrc -
            [uint64]$m0ParserCounters.bad_crc) -eq 0 -and
          ([uint64]$groundCapture.Mavlink.NoiseBytes -
            [uint64]$m0ParserCounters.noise_bytes) -eq 0)
      checked_elapsed_ms = [Math]::Round($r0GateElapsedMs, 3)
      parser_buffer_bytes = $groundCapture.Mavlink.Buffer.Count
      parser_expected_length = $groundCapture.Mavlink.ExpectedLength
      pre_or_at_request_exact_target_count = $preRequestExactCount
      unsupported_delta = [uint64]$groundCapture.Mavlink.Unsupported -
          [uint64]$m0ParserCounters.unsupported
      unsupported_flags_delta =
          [uint64]$groundCapture.Mavlink.UnsupportedFlags -
          [uint64]$m0ParserCounters.unsupported_flags
      bad_payload_length_delta =
          [uint64]$groundCapture.Mavlink.BadPayloadLength -
          [uint64]$m0ParserCounters.bad_payload_length
      bad_crc_delta = [uint64]$groundCapture.Mavlink.BadCrc -
          [uint64]$m0ParserCounters.bad_crc
      noise_bytes_delta = [uint64]$groundCapture.Mavlink.NoiseBytes -
          [uint64]$m0ParserCounters.noise_bytes
    }
    if (-not $r0CausalGate.valid) {
      $setupInvalid = $true
      $errors.Add('causal_gate_invalid: pre-R0 target/parser integrity failed; #20 suppressed')
      Add-TimelineEvent -Name 'R0_causal_gate_stop_no_request' -Details @{
        write_count = $injection.write_count
        pre_target_count = $preRequestExactCount
        parser_clean = ($r0CausalGate.parser_buffer_bytes -eq 0 -and
            $r0CausalGate.parser_expected_length -eq 0)
      }
      $groundCapture.Mavlink.Enabled = $false
    } else {
    $script:CurrentPhase = 'R0_request_write'
    Write-ExactRequestOnce -Serial $groundSerial -Fixture $fixture `
        -InjectionState $injection
    $r0 = [pscustomobject][ordered]@{
      elapsed_ms = $injection.final_write_elapsed_ms
      utc = $injection.final_write_utc
      ground_raw_offset = $groundCapture.Raw.Length
    }
    Add-TimelineEvent -Name 'R0_exact_request_final_write' -Details @{
      fixture_bytes = $fixture.Length
      write_count = $injection.write_count
    }

    $script:CurrentPhase = 'wait_exact_target_22'
    $targetWait = [System.Diagnostics.Stopwatch]::StartNew()
    while ($targetWait.Elapsed.TotalSeconds -lt $ResponseTimeoutSeconds -and
        $null -eq $targetResponse) {
      [int]$read = Invoke-PumpPair -VehicleSerial $vehicleSerial `
          -VehicleState $vehicleCapture -GroundSerial $groundSerial `
          -GroundState $groundCapture
      foreach ($candidate in $groundCapture.Mavlink.ExactTargetEvents) {
        if ([double]$candidate.elapsed_ms -gt [double]$r0.elapsed_ms) {
          $targetResponse = $candidate
          break
        }
      }
      if ($read -eq 0 -and $null -eq $targetResponse) {
        Start-Sleep -Milliseconds 2
      }
    }
    Add-TimelineEvent -Name 'exact_target_wait_complete' -Details @{
      found = ($null -ne $targetResponse)
      timeout_seconds = $ResponseTimeoutSeconds
    }

    Invoke-CaptureInterval -Milliseconds 10000 -Phase 'post_response_idle_10s' `
        -VehicleSerial $vehicleSerial -VehicleState $vehicleCapture `
        -GroundSerial $groundSerial -GroundState $groundCapture
    $script:CurrentPhase = 'M1_parser_boundary'
    $boundaryWait = [System.Diagnostics.Stopwatch]::StartNew()
    do {
      [int]$read = Invoke-PumpPair -VehicleSerial $vehicleSerial `
          -VehicleState $vehicleCapture -GroundSerial $groundSerial `
          -GroundState $groundCapture
      if ($groundCapture.Mavlink.Buffer.Count -eq 0 -and
          $groundCapture.Mavlink.ExpectedLength -eq 0) { break }
      if ($read -eq 0) { Start-Sleep -Milliseconds 2 }
    } while ($boundaryWait.ElapsedMilliseconds -lt 250)
    $m1 = [pscustomobject][ordered]@{
      elapsed_ms = [Math]::Round($script:RunWatch.Elapsed.TotalMilliseconds, 3)
      utc = (Get-Date).ToUniversalTime().ToString('o')
      ground_raw_offset = $groundCapture.Raw.Length
    }
    $parserIntegrity = [pscustomobject][ordered]@{
      definition_source = $mavlinkDefinitionSet.path
      definition_sha256 = $mavlinkDefinitionSet.sha256
      definition_count = $mavlinkDefinitionSet.count
      unsupported_at_m0 = [uint64]$m0ParserCounters.unsupported
      unsupported_at_m1 = [uint64]$groundCapture.Mavlink.Unsupported
      unsupported_delta = [uint64]$groundCapture.Mavlink.Unsupported -
          [uint64]$m0ParserCounters.unsupported
      unsupported_flags_at_m0 = [uint64]$m0ParserCounters.unsupported_flags
      unsupported_flags_at_m1 = [uint64]$groundCapture.Mavlink.UnsupportedFlags
      unsupported_flags_delta =
          [uint64]$groundCapture.Mavlink.UnsupportedFlags -
          [uint64]$m0ParserCounters.unsupported_flags
      bad_payload_length_at_m0 =
          [uint64]$m0ParserCounters.bad_payload_length
      bad_payload_length_at_m1 =
          [uint64]$groundCapture.Mavlink.BadPayloadLength
      bad_payload_length_delta =
          [uint64]$groundCapture.Mavlink.BadPayloadLength -
          [uint64]$m0ParserCounters.bad_payload_length
      bad_crc_at_m0 = [uint64]$m0ParserCounters.bad_crc
      bad_crc_at_m1 = [uint64]$groundCapture.Mavlink.BadCrc
      bad_crc_delta = [uint64]$groundCapture.Mavlink.BadCrc -
          [uint64]$m0ParserCounters.bad_crc
      noise_bytes_at_m0 = [uint64]$m0ParserCounters.noise_bytes
      noise_bytes_at_m1 = [uint64]$groundCapture.Mavlink.NoiseBytes
      noise_bytes_delta = [uint64]$groundCapture.Mavlink.NoiseBytes -
          [uint64]$m0ParserCounters.noise_bytes
      invalid_crc_at_m0 = $m0InvalidCrc
      invalid_crc_at_m1 = [uint64]$groundCapture.Mavlink.InvalidCrc
      invalid_crc_delta = [uint64]$groundCapture.Mavlink.InvalidCrc -
          [uint64]$m0InvalidCrc
      invalid_length_at_m0 = $m0InvalidLength
      invalid_length_at_m1 = [uint64]$groundCapture.Mavlink.InvalidLength
      invalid_length_delta = [uint64]$groundCapture.Mavlink.InvalidLength -
          [uint64]$m0InvalidLength
      partial_buffer_bytes = $groundCapture.Mavlink.Buffer.Count
      expected_length = $groundCapture.Mavlink.ExpectedLength
    }
    $parserIntegrity | Add-Member -NotePropertyName valid `
        -NotePropertyValue ($parserIntegrity.unsupported_delta -eq 0 -and
          $parserIntegrity.unsupported_flags_delta -eq 0 -and
          $parserIntegrity.bad_payload_length_delta -eq 0 -and
          $parserIntegrity.bad_crc_delta -eq 0 -and
          $parserIntegrity.noise_bytes_delta -eq 0 -and
          $parserIntegrity.invalid_crc_delta -eq 0 -and
          $parserIntegrity.invalid_length_delta -eq 0 -and
          $parserIntegrity.partial_buffer_bytes -eq 0 -and
          $parserIntegrity.expected_length -eq 0)
    $groundCapture.Mavlink.Enabled = $false
    Add-TimelineEvent -Name 'M1_analysis_end_post_query_next' -Details @{
      parser_integrity = $parserIntegrity.valid
    }
    }
  }

  [Nullable[uint32]]$expectedGroundQ = $null
  if ($null -ne $baselineGround -and $baselineGround.status -eq 'COMPLETE') {
    $expectedGroundQ = Get-NextQueryId -Current $baselineGround.q_uint32
  }
  $postGround = Invoke-SnapshotQuery -Name 'post_ground' `
      -Serial $groundSerial -State $groundCapture -Command $groundCommand `
      -TimeoutSeconds $SnapshotTimeoutSeconds -ExpectedQ $expectedGroundQ `
      -VehicleSerial $vehicleSerial -VehicleState $vehicleCapture `
      -GroundSerial $groundSerial -GroundState $groundCapture
  if ($postGround.status -ne 'COMPLETE') {
    $errors.Add('Ground post VCGSTAT snapshot timed out')
  }

  [Nullable[uint32]]$expectedVehicleQ = $null
  if ($null -ne $baselineVehicle -and $baselineVehicle.status -eq 'COMPLETE') {
    $expectedVehicleQ = Get-NextQueryId -Current $baselineVehicle.q_uint32
  }
  $postVehicle = Invoke-SnapshotQuery -Name 'post_vehicle' `
      -Serial $vehicleSerial -State $vehicleCapture -Command $vehicleCommand `
      -TimeoutSeconds $SnapshotTimeoutSeconds -ExpectedQ $expectedVehicleQ `
      -VehicleSerial $vehicleSerial -VehicleState $vehicleCapture `
      -GroundSerial $groundSerial -GroundState $groundCapture
  if ($postVehicle.status -ne 'COMPLETE') {
    $errors.Add('Vehicle post VCSTAT snapshot timed out')
  }

  if (-not $setupInvalid) {
    $heartbeatMetrics = Get-HeartbeatWindowMetrics `
        -Events $groundCapture.Mavlink.ValidEvents `
        -M0ElapsedMs $m0.elapsed_ms -R0ElapsedMs $r0.elapsed_ms `
        -M1ElapsedMs $m1.elapsed_ms
    if (-not $heartbeatMetrics.valid) {
      $errors.Add('Heartbeat continuity failed: source 1/1 count<2 or a full-window gap exceeded 2500 ms')
    }
    $targetWindow = Get-TargetResponseWindow `
        -Events $groundCapture.Mavlink.ExactTargetEvents `
        -M0ElapsedMs $m0.elapsed_ms `
        -R0ElapsedMs $r0.elapsed_ms -M1ElapsedMs $m1.elapsed_ms `
        -TimeoutMs (1000.0 * $ResponseTimeoutSeconds)
    $targetResponse = $targetWindow.selected
    if (-not $targetWindow.valid) {
      $errors.Add(("Strict target response failed: pre_or_at_r0={0} count={1} duplicates={2} latency_ms={3}" -f
          $targetWindow.pre_or_at_r0_count, $targetWindow.response_count,
          $targetWindow.duplicate_count, $targetWindow.selected_latency_ms))
    }
    if (-not $parserIntegrity.valid) {
      $errors.Add('M0-to-M1 MAVLink parser integrity failed')
    }
    $stageAssessment = Get-StageAssessment -BaselineGround $baselineGround `
        -PostGround $postGround -BaselineVehicle $baselineVehicle `
        -PostVehicle $postVehicle
    if (-not $stageAssessment.valid) {
      $errors.Add("Observer stage chain failed first_missing=$($stageAssessment.first_missing)")
    }
  }

  Invoke-CaptureInterval -Milliseconds 250 -Phase 'footer_drain' `
      -VehicleSerial $vehicleSerial -VehicleState $vehicleCapture `
      -GroundSerial $groundSerial -GroundState $groundCapture
  $footerSequenceCompleted = $true
  $completeSnapshotsBeforeClose = ($baselineVehicle.status -eq 'COMPLETE' -and
      $baselineGround.status -eq 'COMPLETE' -and
      $postGround.status -eq 'COMPLETE' -and $postVehicle.status -eq 'COMPLETE')
  if ($setupInvalid) {
    $preCloseStatus = 'FAIL'
  } else {
    $preCloseStatus = if ($errors.Count -eq 0 -and
        $completeSnapshotsBeforeClose -and $baselineSetup.valid -and
        $r0CausalGate.valid -and
        $heartbeatMetrics.valid -and $targetWindow.valid -and
        $parserIntegrity.valid -and $stageAssessment.valid -and
        $injection.write_count -eq 1 -and $vehicleOpenCount -eq 1 -and
        $groundOpenCount -eq 1) { 'PASS' } else { 'FAIL' }
  }
} catch {
  $failure = $_.Exception.Message
  $errors.Add($failure)
  $preCloseStatus = 'ERROR'
} finally {
  try {
    # Snapshot first so a final read exception can never erase already captured
    # evidence. The best-effort pump is isolated, then a second snapshot adds
    # any bytes it successfully drained.
    $vehicleRaw = $vehicleCapture.Raw.ToArray()
    $groundRaw = $groundCapture.Raw.ToArray()
    try {
      [void](Invoke-PumpPair -VehicleSerial $vehicleSerial `
          -VehicleState $vehicleCapture -GroundSerial $groundSerial `
          -GroundState $groundCapture)
    } catch {
      $finalPumpFailure = "final best-effort pump failure: $($_.Exception.Message)"
      if ($null -eq $failure) { $failure = $finalPumpFailure }
      $errors.Add($finalPumpFailure)
      $preCloseStatus = 'ERROR'
    }
    $vehicleRaw = $vehicleCapture.Raw.ToArray()
    $groundRaw = $groundCapture.Raw.ToArray()
    $script:CurrentPhase = 'capture_footer_fsync'
    Add-TimelineEvent -Name 'capture_footer_fsync_start' -Details @{
      completed = $footerSequenceCompleted
      status = $preCloseStatus
      errors = $errors.Count
    }
    Write-BytesDurable -Path (Join-Path $OutputDirectory 'vehicle_rx.raw.bin') `
        -Bytes $vehicleRaw
    Write-BytesDurable -Path (Join-Path $OutputDirectory 'ground_rx.raw.bin') `
        -Bytes $groundRaw
    Write-JsonDurable -Path (Join-Path $OutputDirectory 'timeline.json') `
        -Value $script:Timeline.ToArray()
    Write-JsonDurable -Path (Join-Path $OutputDirectory 'vehicle_read_spans.json') `
        -Value $vehicleCapture.Chunks.ToArray()
    Write-JsonDurable -Path (Join-Path $OutputDirectory 'ground_read_spans.json') `
        -Value $groundCapture.Chunks.ToArray()
    Write-JsonDurable `
        -Path (Join-Path $OutputDirectory 'vehicle_tagged_ascii_spans.json') `
        -Value $vehicleCapture.TaggedLines.ToArray()
    Write-JsonDurable `
        -Path (Join-Path $OutputDirectory 'ground_tagged_ascii_spans.json') `
        -Value $groundCapture.TaggedLines.ToArray()
    Write-JsonDurable `
        -Path (Join-Path $OutputDirectory 'ground_mavlink_valid_events.json') `
        -Value $groundCapture.Mavlink.ValidEvents.ToArray()
    Write-JsonDurable `
        -Path (Join-Path $OutputDirectory 'ground_exact_target_events.json') `
        -Value $groundCapture.Mavlink.ExactTargetEvents.ToArray()
    $captureFooter = [ordered]@{
      schema_version = 1
      completed = $footerSequenceCompleted
      status = $preCloseStatus
      written_utc = (Get-Date).ToUniversalTime().ToString('o')
      elapsed_ms_before_fsync = [Math]::Round(
          $script:RunWatch.Elapsed.TotalMilliseconds, 3)
      error_count = $errors.Count
      errors = $errors.ToArray()
      snapshots = [ordered]@{
        baseline_vehicle = $(if ($null -ne $baselineVehicle) {
            $baselineVehicle.status } else { 'NOT_RUN' })
        baseline_ground = $(if ($null -ne $baselineGround) {
            $baselineGround.status } else { 'NOT_RUN' })
        post_ground = $(if ($null -ne $postGround) {
            $postGround.status } else { 'NOT_RUN' })
        post_vehicle = $(if ($null -ne $postVehicle) {
            $postVehicle.status } else { 'NOT_RUN' })
      }
      analysis_contract = [ordered]@{
        mavlink_definition_source = $mavlinkDefinitionSet.path
        mavlink_definition_sha256 = $mavlinkDefinitionSet.sha256
        mavlink_definition_count = $mavlinkDefinitionSet.count
        r0_causal_gate = $r0CausalGate
        parser_integrity_m0_m1 = $parserIntegrity
      }
      raw_capture = [ordered]@{
        vehicle_file = 'vehicle_rx.raw.bin'
        vehicle_bytes = $vehicleRaw.Length
        vehicle_sha256 = Get-BytesSha256 -Bytes $vehicleRaw
        ground_file = 'ground_rx.raw.bin'
        ground_bytes = $groundRaw.Length
        ground_sha256 = Get-BytesSha256 -Bytes $groundRaw
      }
      durability = [ordered]@{
        file_options = 'WriteThrough'
        flush_to_disk = 'FileStream.Flush(true)'
        ports_close_only_after_this_footer_returns_from_flush = $true
      }
      open_counts = [ordered]@{
        vehicle = $vehicleOpenCount
        ground = $groundOpenCount
      }
    }
    Write-JsonDurable -Path (Join-Path $OutputDirectory 'capture_footer.json') `
        -Value $captureFooter
    $footerFsyncElapsedMs = $script:RunWatch.Elapsed.TotalMilliseconds
    $footerRecorded = $true
  } catch {
    $durableFailure = "durable evidence/footer failure: $($_.Exception.Message)"
    if ($null -eq $failure) { $failure = $durableFailure }
    $errors.Add($durableFailure)
    $preCloseStatus = 'ERROR'
    try {
      $fallbackFooter = [ordered]@{
        schema_version = 1
        completed = $false
        status = 'ERROR'
        written_utc = (Get-Date).ToUniversalTime().ToString('o')
        error = $durableFailure
        error_count = $errors.Count
        raw_capture = [ordered]@{
          vehicle_file = 'vehicle_rx.raw.bin'
          vehicle_bytes = $vehicleRaw.Length
          vehicle_sha256 = Get-BytesSha256 -Bytes $vehicleRaw
          ground_file = 'ground_rx.raw.bin'
          ground_bytes = $groundRaw.Length
          ground_sha256 = Get-BytesSha256 -Bytes $groundRaw
        }
        durability = [ordered]@{
          file_options = 'WriteThrough'
          flush_to_disk = 'FileStream.Flush(true)'
          fallback_after_evidence_failure = $true
        }
      }
      Write-JsonDurable `
          -Path (Join-Path $OutputDirectory 'capture_footer.json') `
          -Value $fallbackFooter
      $footerFsyncElapsedMs = $script:RunWatch.Elapsed.TotalMilliseconds
      $footerRecorded = $true
    } catch {
      $errors.Add("fallback capture footer failure: $($_.Exception.Message)")
    }
  } finally {
    if ($null -ne $groundSerial) {
      try {
        if ($groundSerial.IsOpen) {
          $groundSerial.Close()
          $groundCloseElapsedMs = $script:RunWatch.Elapsed.TotalMilliseconds
        }
      } catch {
        if ($null -eq $failure) { $failure = $_.Exception.Message }
        $errors.Add("Ground COM close failure: $($_.Exception.Message)")
        $preCloseStatus = 'ERROR'
      } finally {
        $groundSerial.Dispose()
      }
    }
    if ($null -ne $vehicleSerial) {
      try {
        if ($vehicleSerial.IsOpen) {
          $vehicleSerial.Close()
          $vehicleCloseElapsedMs = $script:RunWatch.Elapsed.TotalMilliseconds
        }
      } catch {
        if ($null -eq $failure) { $failure = $_.Exception.Message }
        $errors.Add("Vehicle COM close failure: $($_.Exception.Message)")
        $preCloseStatus = 'ERROR'
      } finally {
        $vehicleSerial.Dispose()
      }
    }
    $script:RunWatch.Stop()
  }
}

try {
$vehicleCapture.Raw.Dispose()
$groundCapture.Raw.Dispose()
Write-BytesDurable `
    -Path (Join-Path $OutputDirectory 'request_fixture_exact_once.bin') `
    -Bytes $fixture
[byte[]]$vehiclePrefix = Get-InitialPrefix -Bytes $vehicleRaw
[byte[]]$groundPrefix = Get-InitialPrefix -Bytes $groundRaw
Write-BytesDurable `
    -Path (Join-Path $OutputDirectory 'vehicle_initial_up_to_256.bin') `
    -Bytes $vehiclePrefix
Write-BytesDurable `
    -Path (Join-Path $OutputDirectory 'ground_initial_up_to_256.bin') `
    -Bytes $groundPrefix

Write-SnapshotText -Path (Join-Path $OutputDirectory 'baseline_vehicle.txt') `
    -Snapshot $baselineVehicle
Write-SnapshotText -Path (Join-Path $OutputDirectory 'baseline_ground.txt') `
    -Snapshot $baselineGround
Write-SnapshotText -Path (Join-Path $OutputDirectory 'post_ground.txt') `
    -Snapshot $postGround
Write-SnapshotText -Path (Join-Path $OutputDirectory 'post_vehicle.txt') `
    -Snapshot $postVehicle

if ($null -ne $targetResponse) {
  [int]$windowStart = [Math]::Max(0,
      [int]$targetResponse.raw_start_offset - 256)
  [int]$windowEnd = [Math]::Min($groundRaw.Length,
      [int]$targetResponse.raw_end_offset_exclusive + 256)
  [int]$windowLength = $windowEnd - $windowStart
  [byte[]]$window = New-Object byte[] $windowLength
  if ($windowLength -gt 0) {
    [Array]::Copy($groundRaw, $windowStart, $window, 0, $windowLength)
  }
  Write-BytesDurable `
      -Path (Join-Path $OutputDirectory 'ground_exact22_window.bin') `
      -Bytes $window
}

[bool]$closeAfterFooter = ($footerRecorded -and
    (Test-FooterCloseOrdering -FooterFsyncElapsedMs $footerFsyncElapsedMs `
        -VehicleCloseElapsedMs $vehicleCloseElapsedMs `
        -GroundCloseElapsedMs $groundCloseElapsedMs))
[bool]$completeSnapshots = ($null -ne $baselineVehicle -and
    $baselineVehicle.status -eq 'COMPLETE' -and
    $null -ne $baselineGround -and $baselineGround.status -eq 'COMPLETE' -and
    $null -ne $postGround -and $postGround.status -eq 'COMPLETE' -and
    $null -ne $postVehicle -and $postVehicle.status -eq 'COMPLETE')
[string]$status = if ($null -ne $failure -or $preCloseStatus -eq 'ERROR') {
  'ERROR'
} elseif ($preCloseStatus -eq 'PASS' -and $errors.Count -eq 0 -and
    $completeSnapshots -and $footerSequenceCompleted -and $closeAfterFooter) {
  'PASS'
} else {
  'FAIL'
}

$summary = [ordered]@{
  schema_version = 1
  test_id = 'HIL-DUAL-DIAG-CONTINUOUS-001'
  status = $status
  acceptance_scope = ('single strict PARAM_VALUE response plus primary ' +
      'HEARTBEAT continuity; this result is not proof that a full ' +
      'PARAM_VALUE list is lossless')
  started_utc = $(if ($script:Timeline.Count -gt 0) {
      $script:Timeline[0].utc
    } else { $null })
  finished_utc = (Get-Date).ToUniversalTime().ToString('o')
  duration_ms = [Math]::Round($script:RunWatch.Elapsed.TotalMilliseconds, 3)
  errors = $errors.ToArray()
  ports = [ordered]@{
    vehicle = [ordered]@{
      name = $VehiclePort; baud = $VehicleBaud; open_count = $vehicleOpenCount
      close_elapsed_ms = $vehicleCloseElapsedMs
    }
    ground = [ordered]@{
      name = $GroundPort; baud = $GroundBaud; open_count = $groundOpenCount
      close_elapsed_ms = $groundCloseElapsedMs
    }
    enumeration = $portWait
    power_off_preflight = $powerOffWait
    dtr_enabled = $false
    rts_enabled = $false
    close_after_footer = $closeAfterFooter
    footer_fsync_elapsed_ms = $footerFsyncElapsedMs
    discard_input_api_used = $false
  }
  timeline_markers = [ordered]@{ M0 = $m0; R0 = $r0; M1 = $m1 }
  fixture = [ordered]@{
    source_path = (Resolve-Path -LiteralPath $FixturePath).Path
    size_bytes = $fixture.Length
    sha256 = Get-BytesSha256 -Bytes $fixture
    strict_contract = $fixtureContract
    write_count = $injection.write_count
    final_write_elapsed_ms = $injection.final_write_elapsed_ms
    final_write_utc = $injection.final_write_utc
  }
  snapshots = [ordered]@{
    baseline_vehicle = $baselineVehicle
    baseline_ground = $baselineGround
    post_ground = $postGround
    post_vehicle = $postVehicle
  }
  baseline_setup = $baselineSetup
  r0_causal_gate = $r0CausalGate
  setup_invalid_request_suppressed = ($setupInvalid -and
      $injection.write_count -eq 0)
  stage_localization = $stageAssessment
  strict_target_window = $targetWindow
  exact_target_response = $targetResponse
  heartbeat_window = $heartbeatMetrics
  parser_integrity_m0_m1 = $parserIntegrity
  mavlink_definitions = [ordered]@{
    source = $mavlinkDefinitionSet.path
    sha256 = $mavlinkDefinitionSet.sha256
    count = $mavlinkDefinitionSet.count
  }
  raw_capture = [ordered]@{
    vehicle_bytes = $vehicleRaw.Length
    vehicle_sha256 = Get-BytesSha256 -Bytes $vehicleRaw
    vehicle_initial_prefix_saved = $vehiclePrefix.Length
    ground_bytes = $groundRaw.Length
    ground_sha256 = Get-BytesSha256 -Bytes $groundRaw
    ground_initial_prefix_saved = $groundPrefix.Length
    vehicle_file = 'vehicle_rx.raw.bin'
    ground_file = 'ground_rx.raw.bin'
    raw_streams_never_reset_or_overwritten = $true
    analysis_resets = $groundCapture.Mavlink.ExplicitResets.ToArray()
    analysis_invalid_crc = $groundCapture.Mavlink.InvalidCrc
    analysis_invalid_length = $groundCapture.Mavlink.InvalidLength
    analysis_unsupported = $groundCapture.Mavlink.Unsupported
    analysis_unsupported_flags = $groundCapture.Mavlink.UnsupportedFlags
    analysis_bad_payload_length = $groundCapture.Mavlink.BadPayloadLength
    analysis_bad_crc = $groundCapture.Mavlink.BadCrc
    analysis_noise_bytes = $groundCapture.Mavlink.NoiseBytes
  }
  commands = [ordered]@{
    vehicle_ascii = 'VCSTAT?\n'
    vehicle_hex = (($vehicleCommand | ForEach-Object { $_.ToString('X2') }) -join ' ')
    ground_ascii = 'VCGSTAT?\n'
    ground_hex = (($groundCommand | ForEach-Object { $_.ToString('X2') }) -join ' ')
  }
  evidence_note = ('bool(Serial) is HWCDC USB/SOF/endpoint evidence, not ' +
      'proof that a Windows COM handle is open. This run uses one host handle ' +
      'per port and closes only after post reports and the capture footer.')
  runner_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash
}
Write-JsonDurable -Path (Join-Path $OutputDirectory 'summary.json') `
    -Value $summary -Depth 20

$hashRows = New-Object 'System.Collections.Generic.List[object]'
foreach ($file in @(Get-ChildItem -LiteralPath $OutputDirectory -File |
    Sort-Object Name)) {
  $hashRows.Add([pscustomobject][ordered]@{
    file = $file.Name
    size_bytes = $file.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
  })
}
Write-JsonDurable -Path (Join-Path $OutputDirectory 'artifact_hashes.json') `
    -Value $hashRows.ToArray()
} catch {
  $finalizationMessage = "post-close finalization error: $($_.Exception.Message)"
  try {
    Write-JsonDurable `
        -Path (Join-Path $OutputDirectory 'postclose_finalization_error.json') `
        -Value ([ordered]@{
          schema_version = 1; status = 'ERROR'; completed = $false
          written_utc = (Get-Date).ToUniversalTime().ToString('o')
          capture_footer_recorded = $footerRecorded
          capture_footer_fsync_elapsed_ms = $footerFsyncElapsedMs
          vehicle_raw_bytes = $vehicleRaw.Length
          vehicle_raw_sha256 = Get-BytesSha256 -Bytes $vehicleRaw
          ground_raw_bytes = $groundRaw.Length
          ground_raw_sha256 = Get-BytesSha256 -Bytes $groundRaw
          error = $finalizationMessage
        })
  } catch {
    # The console status and exit 2 still distinguish infrastructure ERROR.
  }
  [Console]::Error.WriteLine($finalizationMessage)
  exit 2
}

if ($status -eq 'PASS') {
  Write-Host ("PASS HIL-DUAL-DIAG-CONTINUOUS-001 target=1 " +
      "vehicle_q={0}->{1} ground_q={2}->{3} evidence={4}" -f
      $baselineVehicle.q_uint32, $postVehicle.q_uint32,
      $baselineGround.q_uint32, $postGround.q_uint32, $OutputDirectory)
  exit 0
}
[Console]::Error.WriteLine(("$status HIL-DUAL-DIAG-CONTINUOUS-001: " +
    "$($errors -join '; ') (evidence: $OutputDirectory)"))
if ($status -eq 'ERROR') { exit 2 }
exit 1
