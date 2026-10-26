[CmdletBinding()]
param(
  [ValidatePattern('^COM[0-9]+$')]
  [string]$Port = 'COM3',

  [ValidateRange(1200, 2000000)]
  [int]$Baud = 115200,

  [ValidateRange(1, 1000)]
  [int]$Iterations = 20,

  [ValidateRange(100, 60000)]
  [int]$ResponseTimeoutMs = 10000,

  [ValidateRange(1, 1000)]
  [int]$QuietWindowMs = 50,

  [ValidateRange(1, 1000)]
  [int]$InitialQuietWindowMs = 100,

  [ValidateRange(16, 4096)]
  [int]$ReadSliceBytes = 512,

  [string]$OutputDirectory = '',

  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TestId = 'FW-VEHICLE-DIAG-USB-STRESS-001'
$script:MaximumLineBytes = 16384
$script:FailureDataKey = 'vc_lora_usb_stress_failure_code'

function Stop-StressFailure {
  param(
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$Message
  )
  $exception = New-Object System.IO.InvalidDataException(
      "$Code`: $Message")
  $exception.Data[$script:FailureDataKey] = $Code
  throw $exception
}

function Get-NextVcstatQuery {
  param([Parameter(Mandatory = $true)][uint32]$Current)
  if ($Current -eq 0) {
    Stop-StressFailure -Code 'INVALID_Q' `
        -Message 'VCSTAT q=0 is forbidden'
  }
  if ($Current -eq [uint32]::MaxValue) {
    return [uint32]1
  }
  return [uint32]($Current + 1)
}

function Get-ByteSha256 {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [byte[]]$Bytes
  )
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return (($sha.ComputeHash($Bytes) | ForEach-Object {
          $_.ToString('X2')
        }) -join '')
  } finally {
    $sha.Dispose()
  }
}

function ConvertFrom-StrictVcstatLine {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$ExpectedTag
  )

  if ([string]::IsNullOrEmpty($Text) -or $Text.Trim() -cne $Text -or
      $Text.Contains("`t") -or $Text.Contains("`r") -or
      $Text.Contains("`n") -or $Text.Contains('  ')) {
    Stop-StressFailure -Code 'MALFORMED_LINE' `
        -Message "line for $ExpectedTag has whitespace outside the exact format"
  }
  [string[]]$tokens = $Text.Split([char]' ')
  if ($tokens.Count -lt 3) {
    Stop-StressFailure -Code 'MALFORMED_LINE' `
        -Message "line for $ExpectedTag has fewer than three tokens"
  }
  if ($tokens[0] -cne $ExpectedTag) {
    Stop-StressFailure -Code 'UNEXPECTED_TAG' `
        -Message "expected $ExpectedTag, received $($tokens[0])"
  }
  if (-not $tokens[1].StartsWith('q=',
      [StringComparison]::Ordinal) -or
      -not $tokens[2].StartsWith('ms=',
      [StringComparison]::Ordinal)) {
    Stop-StressFailure -Code 'MALFORMED_LINE' `
        -Message "$ExpectedTag must begin with exact q= then ms= fields"
  }

  $keys = New-Object 'System.Collections.Generic.HashSet[string]' `
      ([StringComparer]::Ordinal)
  $fields = [ordered]@{}
  for ($index = 1; $index -lt $tokens.Count; ++$index) {
    $token = $tokens[$index]
    $separator = $token.IndexOf('=')
    if ($separator -le 0 -or $separator -eq $token.Length - 1) {
      Stop-StressFailure -Code 'MALFORMED_FIELD' `
          -Message "$ExpectedTag has a malformed key=value token"
    }
    $key = $token.Substring(0, $separator)
    $value = $token.Substring($separator + 1)
    if ($key -cnotmatch '^[A-Za-z][A-Za-z0-9_.-]*$') {
      Stop-StressFailure -Code 'MALFORMED_FIELD' `
          -Message "$ExpectedTag has an invalid field name"
    }
    if (-not $keys.Add($key)) {
      Stop-StressFailure -Code 'DUPLICATE_FIELD' `
          -Message "$ExpectedTag repeats field $key"
    }
    $fields[$key] = $value
  }
  if (-not $keys.Contains('q') -or -not $keys.Contains('ms')) {
    Stop-StressFailure -Code 'MISSING_CORRELATION' `
        -Message "$ExpectedTag is missing q or ms"
  }

  [uint32]$q = 0
  [uint64]$ms = 0
  if (-not [uint32]::TryParse([string]$fields.q, [ref]$q) -or
      $q -eq 0) {
    Stop-StressFailure -Code 'INVALID_Q' `
        -Message "$ExpectedTag q is not a nonzero uint32 decimal"
  }
  if (-not [uint64]::TryParse([string]$fields.ms, [ref]$ms)) {
    Stop-StressFailure -Code 'INVALID_MS' `
        -Message "$ExpectedTag ms is not a uint64 decimal"
  }

  return [pscustomobject][ordered]@{
    tag = $ExpectedTag
    q = $q
    ms = $ms
    field_count = $fields.Count
  }
}

function Add-StressEvent {
  param(
    [Parameter(Mandatory = $true)]$Events,
    [Parameter(Mandatory = $true)][Diagnostics.Stopwatch]$Watch,
    [Parameter(Mandatory = $true)][string]$Type,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Details
  )
  $row = [ordered]@{
    sequence = [uint64]$Events.Count
    type = $Type
    elapsed_ms = [Math]::Round($Watch.Elapsed.TotalMilliseconds, 3)
    utc = [DateTime]::UtcNow.ToString('o')
  }
  foreach ($key in $Details.Keys) {
    $row[$key] = $Details[$key]
  }
  $Events.Add([pscustomobject]$row)
}

function Read-AndRecordAvailable {
  param(
    [Parameter(Mandatory = $true)]$Serial,
    [Parameter(Mandatory = $true)][byte[]]$Buffer,
    [Parameter(Mandatory = $true)][IO.MemoryStream]$Raw
  )
  [int]$available = $Serial.BytesToRead
  if ($available -le 0) {
    return [pscustomobject]@{ count = 0; offset = [long]$Raw.Position }
  }
  [int]$wanted = [Math]::Min($available, $Buffer.Length)
  [int]$read = $Serial.Read($Buffer, 0, $wanted)
  if ($read -lt 0 -or $read -gt $wanted) {
    Stop-StressFailure -Code 'SERIAL_READ_ERROR' `
        -Message "Serial.Read returned invalid count $read/$wanted"
  }
  [long]$offset = $Raw.Position
  if ($read -gt 0) {
    $Raw.Write($Buffer, 0, $read)
  }
  return [pscustomobject]@{ count = $read; offset = $offset }
}

function Assert-QuietSerialWindow {
  param(
    [Parameter(Mandatory = $true)]$Serial,
    [Parameter(Mandatory = $true)][byte[]]$Buffer,
    [Parameter(Mandatory = $true)][IO.MemoryStream]$Raw,
    [Parameter(Mandatory = $true)][Diagnostics.Stopwatch]$SessionWatch,
    [Parameter(Mandatory = $true)]$Events,
    [Parameter(Mandatory = $true)][int]$WindowMs,
    [Parameter(Mandatory = $true)][string]$FailureCode,
    [Parameter(Mandatory = $true)][string]$Phase,
    [int]$Iteration = 0
  )

  $quiet = [Diagnostics.Stopwatch]::StartNew()
  while ($quiet.Elapsed.TotalMilliseconds -lt $WindowMs) {
    $sample = Read-AndRecordAvailable -Serial $Serial -Buffer $Buffer `
        -Raw $Raw
    if ($sample.count -gt 0) {
      Add-StressEvent -Events $Events -Watch $SessionWatch `
          -Type 'unexpected_rx' -Details ([ordered]@{
            phase = $Phase
            iteration = $Iteration
            raw_offset = $sample.offset
            byte_count = $sample.count
          })
      Stop-StressFailure -Code $FailureCode `
          -Message "$sample.count unexpected byte(s) during $Phase"
    }
    Start-Sleep -Milliseconds 1
  }
  $quiet.Stop()
}

function Invoke-VehicleUsbStressSession {
  param(
    [Parameter(Mandatory = $true)]$Serial,
    [Parameter(Mandatory = $true)][int]$IterationCount,
    [Parameter(Mandatory = $true)][int]$PerQueryTimeoutMs,
    [Parameter(Mandatory = $true)][int]$PostReportQuietMs,
    [Parameter(Mandatory = $true)][int]$InitialQuietMs,
    [Parameter(Mandatory = $true)][int]$ReadBufferBytes
  )

  $ascii = [Text.Encoding]::ASCII
  [byte[]]$queryBytes = $ascii.GetBytes("VCSTAT?`n")
  [byte[]]$expectedQuery = [byte[]](
      0x56, 0x43, 0x53, 0x54, 0x41, 0x54, 0x3F, 0x0A)
  if ([Convert]::ToBase64String($queryBytes) -cne
      [Convert]::ToBase64String($expectedQuery)) {
    throw 'Internal exact query invariant failed.'
  }

  $watch = [Diagnostics.Stopwatch]::StartNew()
  $raw = New-Object IO.MemoryStream
  $events = New-Object 'System.Collections.Generic.List[object]'
  [byte[]]$buffer = New-Object byte[] $ReadBufferBytes
  [int]$openAttempts = 0
  [int]$openCount = 0
  [int]$closeCount = 0
  [int]$disposeCount = 0
  [int]$queryWriteAttempts = 0
  [int]$queryWriteCount = 0
  [int]$completedIterations = 0
  [int]$acceptedLines = 0
  [int]$lastPendingLineBytes = 0
  [Nullable[uint32]]$firstQ = $null
  [Nullable[uint32]]$lastQ = $null
  [Nullable[uint32]]$expectedQ = $null
  $failureCode = $null
  $failureMessage = $null
  [bool]$opened = $false

  try {
    ++$openAttempts
    try {
      $Serial.Open()
      $opened = $true
      ++$openCount
    } catch {
      Stop-StressFailure -Code 'OPEN_FAILED' -Message $_.Exception.Message
    }
    Add-StressEvent -Events $events -Watch $watch -Type 'serial_opened' `
        -Details ([ordered]@{ open_count = $openCount })

    Assert-QuietSerialWindow -Serial $Serial -Buffer $buffer -Raw $raw `
        -SessionWatch $watch -Events $events -WindowMs $InitialQuietMs `
        -FailureCode 'PREEXISTING_BYTES' -Phase 'initial_quiet'
    Add-StressEvent -Events $events -Watch $watch `
        -Type 'initial_quiet_complete' -Details ([ordered]@{
          quiet_window_ms = $InitialQuietMs
        })

    for ($iteration = 1; $iteration -le $IterationCount; ++$iteration) {
      [long]$iterationRawStart = $raw.Position
      [double]$queryStartedMs = $watch.Elapsed.TotalMilliseconds
      ++$queryWriteAttempts
      Add-StressEvent -Events $events -Watch $watch -Type 'query_write' `
          -Details ([ordered]@{
            iteration = $iteration
            byte_count = $queryBytes.Length
            query_hex = '56 43 53 54 41 54 3F 0A'
          })
      try {
        $Serial.Write($queryBytes, 0, $queryBytes.Length)
        $Serial.BaseStream.Flush()
        ++$queryWriteCount
      } catch {
        Stop-StressFailure -Code 'SERIAL_WRITE_ERROR' `
            -Message $_.Exception.Message
      }

      $lineBytes = New-Object 'System.Collections.Generic.List[byte]'
      $seenTags = New-Object 'System.Collections.Generic.HashSet[string]' `
          ([StringComparer]::Ordinal)
      [int]$lineNumber = 0
      [Nullable[uint32]]$reportQ = $null
      [Nullable[uint64]]$reportMs = $null
      [bool]$reportComplete = $false
      [double]$firstByteMs = -1.0
      [double]$lastByteMs = -1.0
      [double]$deadlineMs = $queryStartedMs + $PerQueryTimeoutMs

      while (-not $reportComplete -and
          $watch.Elapsed.TotalMilliseconds -lt $deadlineMs) {
        $sample = Read-AndRecordAvailable -Serial $Serial -Buffer $buffer `
            -Raw $raw
        if ($sample.count -le 0) {
          Start-Sleep -Milliseconds 1
          continue
        }
        if ($firstByteMs -lt 0.0) {
          $firstByteMs = $watch.Elapsed.TotalMilliseconds
        }
        $lastByteMs = $watch.Elapsed.TotalMilliseconds

        for ($byteIndex = 0; $byteIndex -lt $sample.count; ++$byteIndex) {
          [byte]$value = $buffer[$byteIndex]
          [long]$absoluteOffset = [long]$sample.offset + $byteIndex
          if ($reportComplete) {
            Stop-StressFailure -Code 'TRAILING_BYTES' `
                -Message "iteration $iteration has bytes after VCSTAT3 LF"
          }
          if ($value -eq 0x0A) {
            if ($lineBytes.Count -eq 0) {
              Stop-StressFailure -Code 'EMPTY_LINE' `
                  -Message "iteration $iteration contains an empty line"
            }
            [byte[]]$lineArray = $lineBytes.ToArray()
            [string]$lineText = $ascii.GetString($lineArray)
            $expectedTag = 'VCSTAT' + [string]($lineNumber + 1)
            [string]$actualTag = $lineText.Split([char]' ')[0]
            if ($seenTags.Contains($actualTag)) {
              Stop-StressFailure -Code 'DUPLICATE_TAG' `
                  -Message "iteration $iteration repeats $actualTag"
            }
            if ($actualTag -cne $expectedTag) {
              Stop-StressFailure -Code 'UNEXPECTED_TAG' `
                  -Message ("iteration $iteration expected $expectedTag, " +
                    "received $actualTag")
            }
            $parsed = ConvertFrom-StrictVcstatLine -Text $lineText `
                -ExpectedTag $expectedTag
            [void]$seenTags.Add($parsed.tag)
            if ($lineNumber -eq 0) {
              $reportQ = [uint32]$parsed.q
              $reportMs = [uint64]$parsed.ms
            } else {
              if ([uint32]$parsed.q -ne [uint32]$reportQ) {
                Stop-StressFailure -Code 'Q_MISMATCH' `
                    -Message "iteration $iteration lines do not share q"
              }
              if ([uint64]$parsed.ms -ne [uint64]$reportMs) {
                Stop-StressFailure -Code 'MS_MISMATCH' `
                    -Message "iteration $iteration lines do not share ms"
              }
            }

            [byte[]]$terminatedLine = New-Object byte[] ($lineArray.Length + 1)
            [Array]::Copy($lineArray, $terminatedLine, $lineArray.Length)
            $terminatedLine[$terminatedLine.Length - 1] = 0x0A
            [long]$lineStartOffset =
                $absoluteOffset - [long]$lineArray.Length
            Add-StressEvent -Events $events -Watch $watch -Type 'line' `
                -Details ([ordered]@{
                  iteration = $iteration
                  ordinal = $lineNumber + 1
                  tag = $parsed.tag
                  q = [uint32]$parsed.q
                  ms = [uint64]$parsed.ms
                  field_count = $parsed.field_count
                  raw_offset_start = $lineStartOffset
                  raw_offset_end_exclusive = $absoluteOffset + 1
                  terminated_byte_count = $terminatedLine.Length
                  sha256 = Get-ByteSha256 -Bytes $terminatedLine
                  text = $lineText
                })
            ++$acceptedLines
            ++$lineNumber
            $lineBytes.Clear()
            if ($lineNumber -eq 3) {
              if ($null -ne $expectedQ -and
                  [uint32]$reportQ -ne [uint32]$expectedQ) {
                Stop-StressFailure -Code 'Q_SEQUENCE' `
                    -Message ("iteration $iteration expected q=$expectedQ, " +
                      "received q=$reportQ")
              }
              if ($null -eq $firstQ) {
                $firstQ = [uint32]$reportQ
              }
              $lastQ = [uint32]$reportQ
              $expectedQ = Get-NextVcstatQuery -Current ([uint32]$reportQ)
              $reportComplete = $true
            }
          } else {
            if ($value -lt 0x20 -or $value -gt 0x7E) {
              Stop-StressFailure -Code 'INVALID_BYTE' `
                  -Message ("iteration $iteration received non-printable " +
                    "byte 0x$($value.ToString('X2'))")
            }
            if ($lineBytes.Count -ge $script:MaximumLineBytes) {
              Stop-StressFailure -Code 'LINE_TOO_LONG' `
                  -Message "iteration $iteration exceeded line byte bound"
            }
            $lineBytes.Add($value)
          }
        }
      }

      $lastPendingLineBytes = $lineBytes.Count
      if (-not $reportComplete) {
        if ($lineNumber -gt 0 -or $lineBytes.Count -gt 0) {
          Stop-StressFailure -Code 'TIMEOUT_PARTIAL' `
              -Message ("iteration $iteration timed out with $lineNumber/3 " +
                "complete lines and $($lineBytes.Count) unterminated bytes")
        }
        Stop-StressFailure -Code 'TIMEOUT_NO_RESPONSE' `
            -Message "iteration $iteration received no complete response"
      }
      if ($lineBytes.Count -ne 0 -or $seenTags.Count -ne 3) {
        Stop-StressFailure -Code 'INTERNAL_REPORT_STATE' `
            -Message "iteration $iteration ended with incomplete parser state"
      }

      Add-StressEvent -Events $events -Watch $watch `
          -Type 'iteration_complete' -Details ([ordered]@{
            iteration = $iteration
            q = [uint32]$reportQ
            ms = [uint64]$reportMs
            raw_offset_start = $iterationRawStart
            raw_offset_end_exclusive = [long]$raw.Position
            response_bytes = [long]$raw.Position - $iterationRawStart
            first_byte_latency_ms = [Math]::Round(
                $firstByteMs - $queryStartedMs, 3)
            complete_latency_ms = [Math]::Round(
                $lastByteMs - $queryStartedMs, 3)
          })

      Assert-QuietSerialWindow -Serial $Serial -Buffer $buffer -Raw $raw `
          -SessionWatch $watch -Events $events `
          -WindowMs $PostReportQuietMs -FailureCode 'TRAILING_BYTES' `
          -Phase 'post_report_quiet' -Iteration $iteration
      ++$completedIterations
    }
  } catch {
    $failureMessage = $_.Exception.Message
    if ($_.Exception.Data.Contains($script:FailureDataKey)) {
      $failureCode = [string]$_.Exception.Data[$script:FailureDataKey]
    } else {
      $failureCode = 'UNEXPECTED_EXCEPTION'
    }
    Add-StressEvent -Events $events -Watch $watch -Type 'failure' `
        -Details ([ordered]@{
          failure_code = $failureCode
          message = $failureMessage
          completed_iterations = $completedIterations
          query_write_count = $queryWriteCount
          raw_bytes = [long]$raw.Length
        })
  } finally {
    if ($opened) {
      try {
        $Serial.Close()
        ++$closeCount
      } catch {
        if ($null -eq $failureCode) {
          $failureCode = 'CLOSE_FAILED'
          $failureMessage = $_.Exception.Message
        }
      }
    }
    try {
      $Serial.Dispose()
      ++$disposeCount
    } catch {
      if ($null -eq $failureCode) {
        $failureCode = 'DISPOSE_FAILED'
        $failureMessage = $_.Exception.Message
      }
    }
    Add-StressEvent -Events $events -Watch $watch -Type 'serial_closed' `
        -Details ([ordered]@{
          open_attempts = $openAttempts
          open_count = $openCount
          close_count = $closeCount
          dispose_count = $disposeCount
        })
    $watch.Stop()
  }

  [byte[]]$rawBytes = $raw.ToArray()
  $raw.Dispose()
  [bool]$passed = ($null -eq $failureCode -and
      $openAttempts -eq 1 -and $openCount -eq 1 -and
      $closeCount -eq 1 -and $disposeCount -eq 1 -and
      $queryWriteAttempts -eq $IterationCount -and
      $queryWriteCount -eq $IterationCount -and
      $completedIterations -eq $IterationCount -and
      $acceptedLines -eq 3 * $IterationCount -and
      $lastPendingLineBytes -eq 0)
  if (-not $passed -and $null -eq $failureCode) {
    $failureCode = 'SESSION_ACCOUNTING'
    $failureMessage = 'final exact session accounting did not balance'
  }

  return [pscustomobject][ordered]@{
    passed = $passed
    failure_code = $failureCode
    failure_message = $failureMessage
    duration_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
    open_attempts = $openAttempts
    open_count = $openCount
    close_count = $closeCount
    dispose_count = $disposeCount
    query_write_attempts = $queryWriteAttempts
    query_write_count = $queryWriteCount
    completed_iterations = $completedIterations
    accepted_lines = $acceptedLines
    last_pending_line_bytes = $lastPendingLineBytes
    first_q = $firstQ
    last_q = $lastQ
    next_expected_q = $expectedQ
    raw_bytes = $rawBytes
    events = $events.ToArray()
  }
}

function New-OfflineVcstatReport {
  param(
    [Parameter(Mandatory = $true)][uint32]$Q,
    [Parameter(Mandatory = $true)][uint64]$Ms
  )
  return ("VCSTAT1 q=$Q ms=$Ms marker=one`n" +
      "VCSTAT2 q=$Q ms=$Ms marker=two`n" +
      "VCSTAT3 q=$Q ms=$Ms marker=three`n")
}

function New-OfflineStressSerial {
  param(
    [Parameter(Mandatory = $true)][object[]]$ResponsesByWrite,
    [ValidateRange(1, 4096)][int]$MaximumReadChunk = 7
  )
  $state = [pscustomobject]@{
    pending = New-Object 'System.Collections.Generic.Queue[byte]'
    responses = @($ResponsesByWrite)
    maximum_read_chunk = $MaximumReadChunk
    is_open = $false
    open_count = 0
    close_count = 0
    dispose_count = 0
    write_count = 0
    flush_count = 0
  }
  $baseStream = [pscustomobject]@{ state = $state }
  $baseStream | Add-Member -MemberType ScriptMethod -Name Flush -Value {
    ++$this.state.flush_count
  }
  $serial = [pscustomobject]@{
    state = $state
    BaseStream = $baseStream
  }
  $serial | Add-Member -MemberType ScriptProperty -Name IsOpen -Value {
    return [bool]$this.state.is_open
  }
  $serial | Add-Member -MemberType ScriptProperty -Name BytesToRead -Value {
    return [Math]::Min(
        $this.state.pending.Count, $this.state.maximum_read_chunk)
  }
  $serial | Add-Member -MemberType ScriptMethod -Name Open -Value {
    if ($this.state.is_open) { throw 'fixture already open' }
    $this.state.is_open = $true
    ++$this.state.open_count
  }
  $serial | Add-Member -MemberType ScriptMethod -Name Close -Value {
    if (-not $this.state.is_open) { throw 'fixture not open' }
    $this.state.is_open = $false
    ++$this.state.close_count
  }
  $serial | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
    ++$this.state.dispose_count
  }
  $serial | Add-Member -MemberType ScriptMethod -Name Write -Value {
    param([byte[]]$Buffer, [int]$Offset, [int]$Count)
    if (-not $this.state.is_open) { throw 'fixture write while closed' }
    [byte[]]$expected = [byte[]](
        0x56, 0x43, 0x53, 0x54, 0x41, 0x54, 0x3F, 0x0A)
    if ($Offset -ne 0 -or $Count -ne $expected.Length) {
      throw 'fixture received a non-exact query length'
    }
    for ($index = 0; $index -lt $expected.Length; ++$index) {
      if ($Buffer[$index] -ne $expected[$index]) {
        throw 'fixture received non-exact query bytes'
      }
    }
    [int]$responseIndex = $this.state.write_count
    ++$this.state.write_count
    if ($responseIndex -ge $this.state.responses.Count) { return }
    $response = $this.state.responses[$responseIndex]
    [byte[]]$bytes = if ($response -is [byte[]]) {
      [byte[]]$response
    } else {
      [Text.Encoding]::ASCII.GetBytes([string]$response)
    }
    foreach ($byte in $bytes) { $this.state.pending.Enqueue($byte) }
  }
  $serial | Add-Member -MemberType ScriptMethod -Name Read -Value {
    param([byte[]]$Buffer, [int]$Offset, [int]$Count)
    if (-not $this.state.is_open) { throw 'fixture read while closed' }
    [int]$readCount = [Math]::Min(
        $Count, [Math]::Min($this.state.pending.Count,
          $this.state.maximum_read_chunk))
    for ($index = 0; $index -lt $readCount; ++$index) {
      $Buffer[$Offset + $index] = $this.state.pending.Dequeue()
    }
    return $readCount
  }
  return $serial
}

function Assert-OfflineCondition {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) { throw "SelfTest: $Message" }
}

function Invoke-OfflineSelfTest {
  Assert-OfflineCondition -Condition (
      (Get-ByteSha256 -Bytes ([byte[]]@())) -ceq
      'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855') `
      -Message 'empty raw evidence SHA-256 is not preserved'

  $goodSerial = New-OfflineStressSerial -MaximumReadChunk 5 `
      -ResponsesByWrite @(
        (New-OfflineVcstatReport -Q ([uint32]::MaxValue) -Ms 1000),
        (New-OfflineVcstatReport -Q 1 -Ms 1001),
        (New-OfflineVcstatReport -Q 2 -Ms 1002))
  $good = Invoke-VehicleUsbStressSession -Serial $goodSerial `
      -IterationCount 3 -PerQueryTimeoutMs 2000 `
      -PostReportQuietMs 1 -InitialQuietMs 1 -ReadBufferBytes 17
  Assert-OfflineCondition -Condition (
      $good.passed -and $good.completed_iterations -eq 3 -and
      $good.accepted_lines -eq 9 -and $good.first_q -eq [uint32]::MaxValue -and
      $good.last_q -eq 2 -and $good.next_expected_q -eq 3 -and
      $good.open_count -eq 1 -and $good.close_count -eq 1 -and
      $good.query_write_count -eq 3 -and
      $goodSerial.state.open_count -eq 1 -and
      $goodSerial.state.close_count -eq 1 -and
      $goodSerial.state.dispose_count -eq 1 -and
      $goodSerial.state.flush_count -eq 3) `
      -Message 'valid fragmented q-wrap session did not balance exactly'

  $duplicateSerial = New-OfflineStressSerial -MaximumReadChunk 4096 `
      -ResponsesByWrite @(
        ("VCSTAT1 q=7 ms=10 x=1`n" +
         "VCSTAT1 q=7 ms=10 x=2`n" +
         "VCSTAT3 q=7 ms=10 x=3`n"))
  $duplicate = Invoke-VehicleUsbStressSession -Serial $duplicateSerial `
      -IterationCount 1 -PerQueryTimeoutMs 2000 `
      -PostReportQuietMs 1 -InitialQuietMs 1 -ReadBufferBytes 512
  Assert-OfflineCondition -Condition (
      -not $duplicate.passed -and
      $duplicate.failure_code -eq 'DUPLICATE_TAG' -and
      $duplicate.open_count -eq 1 -and $duplicate.close_count -eq 1) `
      -Message 'duplicate tag was not rejected in one open session'

  $gapSerial = New-OfflineStressSerial -MaximumReadChunk 23 `
      -ResponsesByWrite @(
        (New-OfflineVcstatReport -Q 10 -Ms 20),
        (New-OfflineVcstatReport -Q 12 -Ms 21))
  $gap = Invoke-VehicleUsbStressSession -Serial $gapSerial `
      -IterationCount 2 -PerQueryTimeoutMs 2000 `
      -PostReportQuietMs 1 -InitialQuietMs 1 -ReadBufferBytes 64
  Assert-OfflineCondition -Condition (
      -not $gap.passed -and $gap.failure_code -eq 'Q_SEQUENCE' -and
      $gap.query_write_count -eq 2 -and $gap.open_count -eq 1 -and
      $gap.close_count -eq 1) `
      -Message 'q gap was not rejected without reopening'

  $partialSerial = New-OfflineStressSerial -MaximumReadChunk 9 `
      -ResponsesByWrite @('VCSTAT1 q=1 ms=1 marker=unterminated')
  $partial = Invoke-VehicleUsbStressSession -Serial $partialSerial `
      -IterationCount 1 -PerQueryTimeoutMs 20 `
      -PostReportQuietMs 1 -InitialQuietMs 1 -ReadBufferBytes 32
  Assert-OfflineCondition -Condition (
      -not $partial.passed -and
      $partial.failure_code -eq 'TIMEOUT_PARTIAL' -and
      $partial.last_pending_line_bytes -gt 0 -and
      $partial.open_count -eq 1 -and $partial.close_count -eq 1) `
      -Message 'unterminated partial response was not rejected'

  $invalidSerial = New-OfflineStressSerial -MaximumReadChunk 64 `
      -ResponsesByWrite @("VCSTAT1 q=1 ms=1 marker=crlf`r`n")
  $invalid = Invoke-VehicleUsbStressSession -Serial $invalidSerial `
      -IterationCount 1 -PerQueryTimeoutMs 2000 `
      -PostReportQuietMs 1 -InitialQuietMs 1 -ReadBufferBytes 64
  Assert-OfflineCondition -Condition (
      -not $invalid.passed -and $invalid.failure_code -eq 'INVALID_BYTE' -and
      $invalid.open_count -eq 1 -and $invalid.close_count -eq 1) `
      -Message 'non-LF control byte was not rejected'

  $trailingSerial = New-OfflineStressSerial -MaximumReadChunk 4096 `
      -ResponsesByWrite @(
        ((New-OfflineVcstatReport -Q 3 -Ms 30) + 'X'))
  $trailing = Invoke-VehicleUsbStressSession -Serial $trailingSerial `
      -IterationCount 1 -PerQueryTimeoutMs 2000 `
      -PostReportQuietMs 1 -InitialQuietMs 1 -ReadBufferBytes 512
  Assert-OfflineCondition -Condition (
      -not $trailing.passed -and
      $trailing.failure_code -eq 'TRAILING_BYTES' -and
      $trailing.open_count -eq 1 -and $trailing.close_count -eq 1) `
      -Message 'byte after VCSTAT3 LF was not rejected'

  Write-Host ('SELFTEST PASS run_vehicle_diag_usb_stress.ps1 ' +
      '(fragmentation, q wrap, duplicate, q gap, partial, invalid byte, ' +
      'trailing byte; serial port was not opened)')
}

if ($SelfTest.IsPresent) {
  Invoke-OfflineSelfTest
  return
}

if (-not ('System.IO.Ports.SerialPort' -as [type])) {
  Add-Type -AssemblyName System.IO.Ports
}

$repo = Split-Path -Parent $PSScriptRoot
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $repo `
      "runs\hil\$script:TestId\$timestamp-$Port"
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite USB stress evidence: $OutputDirectory"
}
$parentDirectory = Split-Path -Parent $OutputDirectory
if ($parentDirectory -and -not (Test-Path -LiteralPath $parentDirectory)) {
  [void][IO.Directory]::CreateDirectory($parentDirectory)
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

$serial = New-Object System.IO.Ports.SerialPort
$serial.PortName = $Port
$serial.BaudRate = $Baud
$serial.DataBits = 8
$serial.Parity = [System.IO.Ports.Parity]::None
$serial.StopBits = [System.IO.Ports.StopBits]::One
$serial.Handshake = [System.IO.Ports.Handshake]::None
$serial.ReadTimeout = [Math]::Min($ResponseTimeoutMs, 1000)
$serial.WriteTimeout = [Math]::Min($ResponseTimeoutMs, 2000)
$serial.DtrEnable = $false
$serial.RtsEnable = $false

$startedUtc = [DateTime]::UtcNow
$runnerSha256 = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $PSCommandPath).Hash
$result = Invoke-VehicleUsbStressSession -Serial $serial `
    -IterationCount $Iterations -PerQueryTimeoutMs $ResponseTimeoutMs `
    -PostReportQuietMs $QuietWindowMs `
    -InitialQuietMs $InitialQuietWindowMs `
    -ReadBufferBytes $ReadSliceBytes
$finishedUtc = [DateTime]::UtcNow

$rawPath = Join-Path $resolvedOutputDirectory 'rx_raw.bin'
$eventsPath = Join-Path $resolvedOutputDirectory 'events.json'
$summaryPath = Join-Path $resolvedOutputDirectory 'summary.json'
$hashesPath = Join-Path $resolvedOutputDirectory 'artifact_hashes.json'
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllBytes($rawPath, [byte[]]$result.raw_bytes)
$eventsDocument = [ordered]@{
  schema_version = 1
  test_id = $script:TestId
  raw_file = 'rx_raw.bin'
  raw_size_bytes = $result.raw_bytes.Length
  raw_sha256 = Get-ByteSha256 -Bytes ([byte[]]$result.raw_bytes)
  events = @($result.events)
}
[IO.File]::WriteAllText($eventsPath,
    (($eventsDocument | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    $utf8NoBom)

$summary = [ordered]@{
  schema_version = 1
  test_id = $script:TestId
  status = if ($result.passed) { 'PASS' } else { 'FAIL' }
  started_utc = $startedUtc.ToString('o')
  finished_utc = $finishedUtc.ToString('o')
  duration_ms = $result.duration_ms
  port = $Port
  baud = $Baud
  format = '8N1'
  dtr_enabled = $false
  rts_enabled = $false
  configuration = [ordered]@{
    iterations = $Iterations
    response_timeout_ms = $ResponseTimeoutMs
    initial_quiet_window_ms = $InitialQuietWindowMs
    post_report_quiet_window_ms = $QuietWindowMs
    read_slice_bytes = $ReadSliceBytes
    maximum_line_bytes = $script:MaximumLineBytes
  }
  exact_protocol = [ordered]@{
    query_ascii = 'VCSTAT?\n'
    query_hex = '56 43 53 54 41 54 3F 0A'
    lines_per_report = 3
    required_tag_order = @('VCSTAT1', 'VCSTAT2', 'VCSTAT3')
    same_q_required = $true
    same_ms_required = $true
    exact_next_q_required = $true
    terminator = 'LF'
    other_control_bytes_allowed = $false
    retries_allowed = $false
  }
  session = [ordered]@{
    open_attempts = $result.open_attempts
    open_count = $result.open_count
    close_count = $result.close_count
    dispose_count = $result.dispose_count
    one_open_contract_valid = ($result.open_attempts -eq 1 -and
        $result.open_count -eq 1 -and $result.close_count -eq 1)
    query_write_attempts = $result.query_write_attempts
    query_write_count = $result.query_write_count
    completed_iterations = $result.completed_iterations
    expected_iterations = $Iterations
    accepted_lines = $result.accepted_lines
    expected_lines = 3 * $Iterations
    last_pending_line_bytes = $result.last_pending_line_bytes
    first_q = $result.first_q
    last_q = $result.last_q
    next_expected_q = $result.next_expected_q
  }
  failure = if ($result.passed) { $null } else {
    [ordered]@{
      code = $result.failure_code
      message = $result.failure_message
    }
  }
  artifacts = [ordered]@{
    raw = 'rx_raw.bin'
    events = 'events.json'
    hashes = 'artifact_hashes.json'
  }
  raw_size_bytes = $result.raw_bytes.Length
  raw_sha256 = Get-ByteSha256 -Bytes ([byte[]]$result.raw_bytes)
  runner_sha256 = $runnerSha256
  external_actions = [ordered]@{
    serial_port_opened = ($result.open_count -eq 1)
    firmware_write = $false
    pixhawk_parameter_write = $false
    actuator_command = $false
  }
}
[IO.File]::WriteAllText($summaryPath,
    (($summary | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    $utf8NoBom)

$hashRows = New-Object 'System.Collections.Generic.List[object]'
foreach ($path in @($rawPath, $eventsPath, $summaryPath)) {
  $item = Get-Item -LiteralPath $path
  $hashRows.Add([pscustomobject][ordered]@{
    file = $item.Name
    size_bytes = [long]$item.Length
    sha256 = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath $item.FullName).Hash
  })
}
$hashDocument = [ordered]@{
  schema_version = 1
  coverage = 'rx_raw.bin, events.json, and summary.json after serial close'
  covered_file_count = $hashRows.Count
  files = $hashRows.ToArray()
}
[IO.File]::WriteAllText($hashesPath,
    (($hashDocument | ConvertTo-Json -Depth 6) + [Environment]::NewLine),
    $utf8NoBom)

if (-not $result.passed) {
  [Console]::Error.WriteLine(
      ('FAIL {0} port={1} completed={2}/{3} code={4} evidence={5}' -f
        $script:TestId, $Port, $result.completed_iterations, $Iterations,
        $result.failure_code, $resolvedOutputDirectory))
  exit 1
}
Write-Host ('PASS {0} port={1} iterations={2}/{2} q={3}..{4} ' +
    'open=1 close=1 raw={5} evidence={6}' -f $script:TestId, $Port,
    $Iterations, $result.first_q, $result.last_q,
    $result.raw_bytes.Length, $resolvedOutputDirectory)
exit 0
