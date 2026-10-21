[CmdletBinding()]
param(
  [ValidatePattern('^COM[0-9]+$')]
  [string]$Port = 'COM3',

  [ValidateRange(1200, 2000000)]
  [int]$Baud = 115200,

  [ValidateRange(1, 60)]
  [int]$TimeoutSeconds = 20,

  [string]$OutputDirectory,

  [switch]$SelfTest,

  [ValidateRange(1, 10)]
  [int]$MaximumQueryAttempts = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-VcstatLine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Line
  )

  $normalized = $Line.TrimEnd("`r", "`n").Trim()
  $tokens = @($normalized -split '\s+')
  if ($tokens.Count -lt 1 -or $tokens[0] -notmatch '^VCSTAT[123]$') {
    return $null
  }

  $fields = [ordered]@{}
  $unparsed = New-Object System.Collections.Generic.List[string]
  for ($index = 1; $index -lt $tokens.Count; ++$index) {
    $token = $tokens[$index]
    $separator = $token.IndexOf('=')
    if ($separator -le 0) {
      $unparsed.Add($token)
      continue
    }

    $key = $token.Substring(0, $separator)
    $value = $token.Substring($separator + 1)
    if ($key -notmatch '^[A-Za-z][A-Za-z0-9_.-]*$') {
      $unparsed.Add($token)
      continue
    }
    $fields[$key] = $value
  }

  return [pscustomobject][ordered]@{
    tag = $tokens[0]
    line = $normalized
    fields = [pscustomobject]$fields
    unparsed_tokens = @($unparsed)
  }
}

function Test-VcstatCorrelation {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IDictionary]$Responses
  )

  $errors = New-Object System.Collections.Generic.List[string]
  $qValues = New-Object System.Collections.Generic.List[string]
  $msValues = New-Object System.Collections.Generic.List[string]
  foreach ($tag in @('VCSTAT1', 'VCSTAT2', 'VCSTAT3')) {
    if (-not $Responses.Contains($tag)) {
      $errors.Add("$tag is missing")
      continue
    }

    $fields = $Responses[$tag].fields
    $fieldNames = @($fields.PSObject.Properties.Name)
    foreach ($key in @('q', 'ms')) {
      if ($fieldNames -notcontains $key) {
        $errors.Add("$tag is missing $key")
        continue
      }
      $value = [string]$fields.$key
      if ([string]::IsNullOrWhiteSpace($value)) {
        $errors.Add("$tag has an empty $key")
      } elseif ($key -eq 'q') {
        $qValues.Add($value)
      } else {
        $msValues.Add($value)
      }
    }
  }

  $commonQ = $null
  $commonMs = $null
  if ($qValues.Count -eq 3) {
    $commonQ = $qValues[0]
    if (@($qValues | Select-Object -Unique).Count -ne 1) {
      $errors.Add('VCSTAT1/2/3 q values do not match')
      $commonQ = $null
    }
  }
  if ($msValues.Count -eq 3) {
    $commonMs = $msValues[0]
    if (@($msValues | Select-Object -Unique).Count -ne 1) {
      $errors.Add('VCSTAT1/2/3 ms values do not match')
      $commonMs = $null
    }
  }

  [uint32]$qNumber = 0
  [uint32]$msNumber = 0
  if ($null -ne $commonQ) {
    if (-not [uint32]::TryParse($commonQ, [ref]$qNumber) -or
        $qNumber -eq 0) {
      $errors.Add('common q is not a nonzero uint32 decimal value')
      $commonQ = $null
    }
  }
  if ($null -ne $commonMs) {
    if (-not [uint32]::TryParse($commonMs, [ref]$msNumber)) {
      $errors.Add('common ms is not a uint32 decimal value')
      $commonMs = $null
    }
  }

  return [pscustomobject][ordered]@{
    valid = ($errors.Count -eq 0)
    q = $commonQ
    q_uint32 = $(if ($null -ne $commonQ) { $qNumber } else { $null })
    ms = $commonMs
    ms_uint32 = $(if ($null -ne $commonMs) { $msNumber } else { $null })
    errors = @($errors)
  }
}

function Get-NextVcstatQuery {
  param(
    [Parameter(Mandatory = $true)]
    [uint32]$Current
  )

  if ($Current -eq 0) {
    throw 'A VCSTAT query sequence value of zero is invalid.'
  }
  if ($Current -eq [uint32]::MaxValue) {
    return [uint32]1
  }
  return [uint32]($Current + 1)
}

function Select-VcstatReport {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IEnumerable]$Lines,

    [Nullable[uint32]]$ExpectedQ = $null
  )

  $groups = [ordered]@{}
  $acceptedCandidateLines = 0
  $ignoredCandidateLines = 0
  foreach ($line in $Lines) {
    $parsed = ConvertFrom-VcstatLine -Line ([string]$line)
    if ($null -eq $parsed) {
      continue
    }

    $fieldNames = @($parsed.fields.PSObject.Properties.Name)
    if ($fieldNames -notcontains 'q' -or $fieldNames -notcontains 'ms') {
      ++$ignoredCandidateLines
      continue
    }
    [uint32]$qNumber = 0
    [uint32]$msNumber = 0
    if (-not [uint32]::TryParse([string]$parsed.fields.q, [ref]$qNumber) -or
        $qNumber -eq 0 -or
        -not [uint32]::TryParse([string]$parsed.fields.ms, [ref]$msNumber)) {
      ++$ignoredCandidateLines
      continue
    }
    if ($null -ne $ExpectedQ -and $qNumber -ne [uint32]$ExpectedQ) {
      ++$ignoredCandidateLines
      continue
    }

    ++$acceptedCandidateLines
    $groupKey = '{0}:{1}' -f $qNumber, $msNumber
    if (-not $groups.Contains($groupKey)) {
      $groups[$groupKey] = [ordered]@{}
    }
    $group = $groups[$groupKey]
    if (-not $group.Contains($parsed.tag)) {
      $group[$parsed.tag] = $parsed
    }
    if ($group.Count -eq 3) {
      $correlation = Test-VcstatCorrelation -Responses $group
      if ($correlation.valid) {
        $orderedResponses = New-Object System.Collections.Generic.List[object]
        foreach ($tag in @('VCSTAT1', 'VCSTAT2', 'VCSTAT3')) {
          $orderedResponses.Add($group[$tag])
        }
        return [pscustomobject][ordered]@{
          complete = $true
          responses = $orderedResponses.ToArray()
          correlation = $correlation
          accepted_candidate_lines = $acceptedCandidateLines
          ignored_candidate_lines = $ignoredCandidateLines
        }
      }
    }
  }

  return [pscustomobject][ordered]@{
    complete = $false
    responses = @()
    correlation = $null
    accepted_candidate_lines = $acceptedCandidateLines
    ignored_candidate_lines = $ignoredCandidateLines
  }
}

function Invoke-VcstatQueryStage {
  param(
    [Parameter(Mandatory = $true)]
    $Serial,

    [Parameter(Mandatory = $true)]
    [byte[]]$QueryBytes,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds,

    [Nullable[uint32]]$ExpectedQ = $null,

    [ValidateRange(1, 10)]
    [int]$MaximumQueryAttempts = 3,

    [System.Collections.IEnumerable]$InitialLines = @(),

    [string]$InitialPendingText = ''
  )

  $ascii = [System.Text.Encoding]::ASCII
  $raw = New-Object System.IO.MemoryStream
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($initialLine in @($InitialLines)) {
    $lines.Add([string]$initialLine)
  }
  $initialLineCount = $lines.Count
  $pendingText = $InitialPendingText
  $initialPendingCharacters = $pendingText.Length
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $startedUtc = (Get-Date).ToUniversalTime()
  $buffer = New-Object byte[] 1024
  $report = Select-VcstatReport -Lines $lines -ExpectedQ $ExpectedQ
  $queryAttempts = 0
  $attempts = New-Object System.Collections.Generic.List[object]

  while ($queryAttempts -lt $MaximumQueryAttempts -and
      -not $report.complete) {
    ++$queryAttempts
    $attemptStartedUtc = (Get-Date).ToUniversalTime()
    $attemptWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $rxBytesAtAttemptStart = $raw.Length
    $Serial.Write($QueryBytes, 0, $QueryBytes.Length)
    $Serial.BaseStream.Flush()

    while ($attemptWatch.Elapsed.TotalSeconds -lt $TimeoutSeconds -and
        -not $report.complete) {
      $available = $Serial.BytesToRead
      if ($available -le 0) {
        Start-Sleep -Milliseconds 1
        continue
      }
      $wanted = [Math]::Min($available, $buffer.Length)
      $read = $Serial.Read($buffer, 0, $wanted)
      if ($read -le 0) {
        continue
      }
      $raw.Write($buffer, 0, $read)
      $pendingText += $ascii.GetString($buffer, 0, $read)
      while (($newline = $pendingText.IndexOf("`n")) -ge 0) {
        $line = $pendingText.Substring(0, $newline).TrimEnd("`r")
        $pendingText = $pendingText.Substring($newline + 1)
        $lines.Add($line)
      }
      $report = Select-VcstatReport -Lines $lines -ExpectedQ $ExpectedQ
    }
    $attemptWatch.Stop()
    $attempts.Add([pscustomobject][ordered]@{
      attempt = $queryAttempts
      started_utc = $attemptStartedUtc.ToString('o')
      duration_ms = [Math]::Round($attemptWatch.Elapsed.TotalMilliseconds, 3)
      rx_bytes = [uint64]($raw.Length - $rxBytesAtAttemptStart)
      status = $(if ($report.complete) { 'COMPLETE' } else { 'INCOMPLETE' })
    })
  }

  $watch.Stop()
  $bytes = $raw.ToArray()
  $raw.Dispose()
  return [pscustomobject][ordered]@{
    metadata = [pscustomobject][ordered]@{
      name = $Name
      query_sent = ($queryAttempts -gt 0)
      query_attempts = $queryAttempts
      maximum_query_attempts = $MaximumQueryAttempts
      attempts = $attempts.ToArray()
      initial_complete_newline_lines = $initialLineCount
      initial_pending_characters = $initialPendingCharacters
      expected_q = $(if ($null -ne $ExpectedQ) { [uint32]$ExpectedQ } else { $null })
      status = $(if ($report.complete) { 'COMPLETE' } else { 'TIMEOUT' })
      timeout_seconds = $TimeoutSeconds
      timeout_seconds_per_attempt = $TimeoutSeconds
      maximum_stage_seconds = $TimeoutSeconds * $MaximumQueryAttempts
      started_utc = $startedUtc.ToString('o')
      duration_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
      rx_bytes = $bytes.Length
      complete_newline_lines = $lines.Count
      accepted_candidate_lines = $report.accepted_candidate_lines
      ignored_candidate_lines = $report.ignored_candidate_lines
      responses = @($report.responses)
      correlation = $report.correlation
    }
    raw_bytes = $bytes
    received_text = $ascii.GetString($bytes)
    complete_lines = $lines.ToArray()
    pending_text = $pendingText
    report = $report
  }
}

function Clear-SerialInputUntilQuiet {
  param(
    [Parameter(Mandatory = $true)]
    $Serial,

    [ValidateRange(10, 1000)]
    [int]$QuietMilliseconds = 100,

    [ValidateRange(100, 10000)]
    [int]$MaximumMilliseconds = 1000
  )

  $total = [System.Diagnostics.Stopwatch]::StartNew()
  $quiet = [System.Diagnostics.Stopwatch]::StartNew()
  $discarded = [uint64]0
  $buffer = New-Object byte[] 1024
  while ($total.ElapsedMilliseconds -lt $MaximumMilliseconds) {
    $available = $Serial.BytesToRead
    if ($available -gt 0) {
      $wanted = [Math]::Min($available, $buffer.Length)
      $read = $Serial.Read($buffer, 0, $wanted)
      if ($read -gt 0) {
        $discarded += [uint64]$read
        $quiet.Restart()
      }
      continue
    }
    if ($quiet.ElapsedMilliseconds -ge $QuietMilliseconds) {
      break
    }
    Start-Sleep -Milliseconds 1
  }
  $quietAchieved = ($quiet.ElapsedMilliseconds -ge $QuietMilliseconds)
  $total.Stop()
  $quiet.Stop()

  return [pscustomobject][ordered]@{
    discarded_bytes = $discarded
    quiet_ms_required = $QuietMilliseconds
    max_ms = $MaximumMilliseconds
    duration_ms = [Math]::Round($total.Elapsed.TotalMilliseconds, 3)
    quiet_achieved = $quietAchieved
  }
}

function New-OfflineVcstatSerialFixture {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$ResponsesByWrite
  )

  $state = [pscustomobject]@{
    pending = New-Object 'System.Collections.Generic.Queue[byte]'
    responses = @($ResponsesByWrite)
    write_count = 0
  }
  $baseStream = New-Object psobject
  $baseStream | Add-Member -MemberType ScriptMethod -Name Flush -Value {}
  $serial = [pscustomobject]@{
    state = $state
    BaseStream = $baseStream
  }
  $serial | Add-Member -MemberType ScriptProperty -Name BytesToRead -Value {
    return $this.state.pending.Count
  }
  $serial | Add-Member -MemberType ScriptMethod -Name Write -Value {
    param([byte[]]$Buffer, [int]$Offset, [int]$Count)
    $responseIndex = $this.state.write_count
    ++$this.state.write_count
    if ($responseIndex -ge $this.state.responses.Count) {
      return
    }
    $bytes = [System.Text.Encoding]::ASCII.GetBytes(
        [string]$this.state.responses[$responseIndex])
    foreach ($byte in $bytes) {
      $this.state.pending.Enqueue($byte)
    }
  }
  $serial | Add-Member -MemberType ScriptMethod -Name Read -Value {
    param([byte[]]$Buffer, [int]$Offset, [int]$Count)
    $readCount = [Math]::Min($Count, $this.state.pending.Count)
    for ($index = 0; $index -lt $readCount; ++$index) {
      $Buffer[$Offset + $index] = $this.state.pending.Dequeue()
    }
    return $readCount
  }
  return $serial
}

function Invoke-OfflineSelfTest {
  $command = [System.Text.Encoding]::ASCII.GetBytes("VCSTAT?`n")
  $expectedCommand = [byte[]](0x56, 0x43, 0x53, 0x54, 0x41, 0x54, 0x3F, 0x0A)
  if ([Convert]::ToBase64String($command) -ne
      [Convert]::ToBase64String($expectedCommand)) {
    throw 'SelfTest: query command is not the exact ASCII VCSTAT?<LF> sequence.'
  }

  $heartbeatDiagnosticKeys = @(
    'sqf', 'sqb', 'sact', 'pgq', 'pga', 'prq', 'ptq', 'hbp', 'hbta',
    'hbac', 'hbpr', 'hbseen', 'squeued', 'sbytes', 'sm194f', 'sm194b',
    'spolf', 'spolb', 'srlf', 'srlb', 'sinv', 'sdropf', 'sdropb',
    'srej', 'sprobs', 'sprmem', 'sprdup', 'sprover', 'sprinv', 'stqf',
    'stdup', 'stsel', 'stchunk', 'stdone', 'strej', 'shby', 'smaxf',
    'smaxb',
    'd7he', 'd7ho', 'd7hv', 'd7hls', 'd7hlm', 'd7hlg', 'd7hlms',
    'd7hlp', 'd7hlc', 'd7hmg', 'd7hmms', 'd7hmp', 'd7hmc', 'd7hmst',
    'd7hmcy', 'd7hmaux', 'd7hmrb', 'd7hmpa', 'd7hmsqf', 'd7hmsqb',
    'd7hmpgq', 'd7hmpga', 'd7hmprq', 'd7hmptq', 'd7hmhbp',
    'd7hmhbta', 'd7hmhbac', 'd7hmhbpr', 'd7hvg', 'd7hvms', 'd7hvp',
    'd7hvc', 'd7hvst', 'd7hvcy', 'd7hvaux', 'd7hvrb', 'd7hvpa',
    'd7hvsqf', 'd7hvsqb', 'd7hvpgq', 'd7hvpga', 'd7hvprq',
    'd7hvptq', 'd7hvhbp', 'd7hvhbta', 'd7hvhbac', 'd7hvhbpr'
  )
  $heartbeatDiagnosticText = @(
    for ($index = 0; $index -lt $heartbeatDiagnosticKeys.Count; ++$index) {
      '{0}={1}' -f $heartbeatDiagnosticKeys[$index], ($index + 1)
    }
  ) -join ' '
  $fixture = @(
    'boot message',
    'VCSTAT1 q=17 ms=1234 role=vehicle uptime_ms=1234 rx=9',
    'VCSTAT2 q=17 ms=1234 radio_rx=8 radio_tx=7 pending=0',
    ('VCSTAT3 q=17 ms=1234 pix_rx=6 pix_tx=5 state=RUN ' +
      $heartbeatDiagnosticText)
  )
  $responses = [ordered]@{}
  foreach ($line in $fixture) {
    $parsed = ConvertFrom-VcstatLine -Line $line
    if ($null -ne $parsed) {
      $responses[$parsed.tag] = $parsed
    }
  }

  foreach ($tag in @('VCSTAT1', 'VCSTAT2', 'VCSTAT3')) {
    if (-not $responses.Contains($tag)) {
      throw "SelfTest: missing parsed response $tag."
    }
  }
  if ($responses['VCSTAT1'].fields.uptime_ms -ne '1234' -or
      $responses['VCSTAT3'].fields.state -ne 'RUN') {
    throw 'SelfTest: key=value parsing produced an unexpected value.'
  }
  for ($index = 0; $index -lt $heartbeatDiagnosticKeys.Count; ++$index) {
    $key = $heartbeatDiagnosticKeys[$index]
    $property = $responses['VCSTAT3'].fields.PSObject.Properties[$key]
    if ($null -eq $property -or $property.Value -ne [string]($index + 1)) {
      throw "SelfTest: heartbeat diagnostic field $key did not round-trip."
    }
  }
  $correlation = Test-VcstatCorrelation -Responses $responses
  if (-not $correlation.valid -or $correlation.q -ne '17' -or
      $correlation.ms -ne '1234') {
    throw 'SelfTest: matching q/ms correlation was rejected.'
  }

  $responses['VCSTAT2'].fields.q = '18'
  if ((Test-VcstatCorrelation -Responses $responses).valid) {
    throw 'SelfTest: unequal q values were accepted.'
  }
  $responses['VCSTAT2'].fields.q = '17'
  $responses['VCSTAT3'].fields.ms = '1235'
  if ((Test-VcstatCorrelation -Responses $responses).valid) {
    throw 'SelfTest: unequal ms values were accepted.'
  }
  $responses['VCSTAT3'].fields.ms = '1234'
  $responses['VCSTAT1'].fields.PSObject.Properties.Remove('q')
  if ((Test-VcstatCorrelation -Responses $responses).valid) {
    throw 'SelfTest: a missing correlation field was accepted.'
  }
  if ($null -ne (ConvertFrom-VcstatLine -Line 'VCSTAT4 invalid=1')) {
    throw 'SelfTest: an unsupported response tag was accepted.'
  }

  if ((Get-NextVcstatQuery -Current 17) -ne 18 -or
      (Get-NextVcstatQuery -Current ([uint32]::MaxValue)) -ne 1) {
    throw 'SelfTest: uint32 q increment/wrap-with-zero-skip is incorrect.'
  }

  # A delayed stale report may be fully valid internally. During measurement it
  # must be ignored until the report with the exact next q is complete.
  $staleDelayedLines = @(
    'VCSTAT1 q=41 ms=900 state=STALE',
    'VCSTAT2 q=41 ms=900 state=STALE',
    'VCSTAT3 q=41 ms=900 state=STALE',
    'VCSTAT1 q=42 ms=1000 state=MEASURE',
    'VCSTAT2 q=42 ms=1000 state=MEASURE',
    'VCSTAT3 q=42 ms=1000 state=MEASURE'
  )
  $selected = Select-VcstatReport -Lines $staleDelayedLines -ExpectedQ 42
  if (-not $selected.complete -or $selected.correlation.q_uint32 -ne 42 -or
      $selected.ignored_candidate_lines -ne 3) {
    throw 'SelfTest: delayed stale report was not rejected during measurement.'
  }

  $wrongSequenceLines = @(
    'VCSTAT1 q=43 ms=1001 state=WRONG',
    'VCSTAT2 q=43 ms=1001 state=WRONG',
    'VCSTAT3 q=43 ms=1001 state=WRONG'
  )
  if ((Select-VcstatReport -Lines $wrongSequenceLines -ExpectedQ 42).complete) {
    throw 'SelfTest: an out-of-sequence measurement report was accepted.'
  }

  $wrapLines = @(
    'VCSTAT1 q=1 ms=0 state=WRAP',
    'VCSTAT2 q=1 ms=0 state=WRAP',
    'VCSTAT3 q=1 ms=0 state=WRAP'
  )
  if (-not (Select-VcstatReport -Lines $wrapLines -ExpectedQ 1).complete) {
    throw 'SelfTest: wrapped q=1 measurement report was rejected.'
  }

  # Regression: a previous invocation closed after the first 64 bytes of a
  # deferred report. The next invocation therefore starts inside VCSTAT1, and
  # its first query is rejected while that old report is still being pumped.
  # Once the old suffix finishes, the host must retry in the same open session
  # and acquire the fresh, complete report produced by that retry.
  $oldSuffix = @(
    'old-vcstat1-suffix-without-a-parseable-prefix',
    'VCSTAT2 q=41 ms=900 state=OLD',
    'VCSTAT3 q=41 ms=900 state=OLD'
  ) -join "`n"
  $oldSuffix += "`n"
  $freshReport = @(
    'VCSTAT1 q=42 ms=1000 state=FRESH',
    'VCSTAT2 q=42 ms=1000 state=FRESH',
    'VCSTAT3 q=42 ms=1000 state=FRESH'
  ) -join "`n"
  $freshReport += "`n"
  $freshMeasurementReport = @(
    'VCSTAT1 q=43 ms=1100 state=MEASUREMENT',
    'VCSTAT2 q=43 ms=1100 state=MEASUREMENT',
    'VCSTAT3 q=43 ms=1100 state=MEASUREMENT'
  ) -join "`n"
  $freshMeasurementReport += "`n"
  $serialFixture = New-OfflineVcstatSerialFixture -ResponsesByWrite @(
      $oldSuffix, $freshReport, $freshMeasurementReport)
  $recovered = Invoke-VcstatQueryStage -Serial $serialFixture `
      -QueryBytes $command -Name 'offline-partial-old-report' `
      -TimeoutSeconds 1
  if (-not $recovered.report.complete -or
      $recovered.report.correlation.q_uint32 -ne 42 -or
      $serialFixture.state.write_count -ne 2) {
    throw ('SelfTest: an invocation starting inside an old deferred report ' +
        'did not retry boundedly and acquire the fresh q=42 report.')
  }
  $recoveredMeasurement = Invoke-VcstatQueryStage -Serial $serialFixture `
      -QueryBytes $command -Name 'offline-recovered-measurement' `
      -TimeoutSeconds 1 -ExpectedQ 43 `
      -InitialLines $recovered.complete_lines `
      -InitialPendingText $recovered.pending_text
  if (-not $recoveredMeasurement.report.complete -or
      $recoveredMeasurement.report.correlation.q_uint32 -ne 43 -or
      $serialFixture.state.write_count -ne 3) {
    throw ('SelfTest: recovered synchronization did not preserve the ' +
        'two-stage exact-next-q measurement contract.')
  }

  # If a stale complete sync report and the response to our first query are
  # delivered in one USB read, stage 1 may parse both. Stage 2 must inherit the
  # already-read q+1 lines instead of draining or losing that fresh response.
  $staleComplete = @(
    'VCSTAT1 q=51 ms=1100 state=STALE',
    'VCSTAT2 q=51 ms=1100 state=STALE',
    'VCSTAT3 q=51 ms=1100 state=STALE'
  ) -join "`n"
  $staleComplete += "`n"
  $freshAlreadyRead = @(
    'VCSTAT1 q=52 ms=1200 state=FRESH',
    'VCSTAT2 q=52 ms=1200 state=FRESH',
    'VCSTAT3 q=52 ms=1200 state=FRESH'
  ) -join "`n"
  $freshAlreadyRead += "`n"
  $carryFixture = New-OfflineVcstatSerialFixture -ResponsesByWrite @(
      ($staleComplete + $freshAlreadyRead))
  $carrySync = Invoke-VcstatQueryStage -Serial $carryFixture `
      -QueryBytes $command -Name 'offline-carry-sync' -TimeoutSeconds 1
  $carryExpectedQ = Get-NextVcstatQuery `
      -Current $carrySync.report.correlation.q_uint32
  $carryMeasurement = Invoke-VcstatQueryStage -Serial $carryFixture `
      -QueryBytes $command -Name 'offline-carry-measurement' `
      -TimeoutSeconds 1 -ExpectedQ $carryExpectedQ `
      -InitialLines $carrySync.complete_lines `
      -InitialPendingText $carrySync.pending_text
  if (-not $carrySync.report.complete -or
      $carrySync.report.correlation.q_uint32 -ne 51 -or
      -not $carryMeasurement.report.complete -or
      $carryMeasurement.report.correlation.q_uint32 -ne 52 -or
      $carryMeasurement.metadata.query_attempts -ne 0 -or
      $carryFixture.state.write_count -ne 1) {
    throw ('SelfTest: stage handoff lost a fresh exact-next-q report that ' +
        'was already read with the synchronization report.')
  }

  Write-Host ('SELFTEST PASS vehicle_diag_query.ps1 ' +
      '(partial-old retry=2, exact-next-q=43, carried-next-q=52; ' +
      'serial port was not opened)')
}

if ($SelfTest.IsPresent) {
  Invoke-OfflineSelfTest
  return
}

if (-not ('System.IO.Ports.SerialPort' -as [type])) {
  Add-Type -AssemblyName System.IO.Ports
}

$repo = Split-Path -Parent $PSScriptRoot
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
if (-not $OutputDirectory) {
  $OutputDirectory = Join-Path $repo (
      "runs\hil\FW-VEHICLE-DIAG-001\{0}-{1}" -f $timestamp, $Port)
}

# A diagnostic run is immutable evidence. Refuse an existing directory even if
# it is empty, rather than silently mixing or replacing two measurements.
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite existing diagnostic evidence: $OutputDirectory"
}

$parentDirectory = Split-Path -Parent $OutputDirectory
if ($parentDirectory -and -not (Test-Path -LiteralPath $parentDirectory)) {
  New-Item -ItemType Directory -Force -Path $parentDirectory | Out-Null
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null

$rawPath = Join-Path $OutputDirectory 'rx_raw.bin'
$rxTextPath = Join-Path $OutputDirectory 'rx_text.txt'
$textPath = Join-Path $OutputDirectory 'response.txt'
$syncRawPath = Join-Path $OutputDirectory 'sync_rx_raw.bin'
$syncRxTextPath = Join-Path $OutputDirectory 'sync_rx_text.txt'
$syncTextPath = Join-Path $OutputDirectory 'sync_response.txt'
$metadataPath = Join-Path $OutputDirectory 'metadata.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ascii = [System.Text.Encoding]::ASCII
$queryBytes = $ascii.GetBytes("VCSTAT?`n")
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

$startedUtc = (Get-Date).ToUniversalTime()
$finishedUtc = $null
$totalWatch = [System.Diagnostics.Stopwatch]::StartNew()
$failure = $null
$preQueryDrain = $null
$interstageDrain = $null
$syncStage = $null
$measurementStage = $null
$expectedMeasurementQ = $null

try {
  $serial.Open()
  $preQueryDrain = Clear-SerialInputUntilQuiet -Serial $serial
  if (-not $preQueryDrain.quiet_achieved) {
    throw ("RX did not become quiet before the query within {0} ms" -f `
        $preQueryDrain.max_ms)
  }

  # Stage 1 establishes the device-side query sequence. Its complete report is
  # retained as evidence but is never used as the diagnostic measurement.
  $syncStage = Invoke-VcstatQueryStage -Serial $serial `
      -QueryBytes $queryBytes -Name 'synchronization' `
      -TimeoutSeconds $TimeoutSeconds `
      -MaximumQueryAttempts $MaximumQueryAttempts
  if (-not $syncStage.report.complete) {
    throw ("Synchronization query timed out after {0} attempts of {1} " +
        "seconds each" -f $MaximumQueryAttempts, $TimeoutSeconds)
  }
  $expectedMeasurementQ = Get-NextVcstatQuery `
      -Current $syncStage.report.correlation.q_uint32

  # Do not discard between stages. If the synchronization report was already
  # queued when its query was sent, that query may have produced q+1 before the
  # host finished parsing q. Carry every complete line and partial suffix into
  # stage 2 so the exact expected q remains recoverable.
  $interstageDrain = [pscustomobject][ordered]@{
    operation = 'SKIPPED'
    reason = 'preserve exact-next-q bytes across logical stages'
    discarded_bytes = [uint64]0
    quiet_achieved = $true
  }

  # Stage 2 accepts only the exact next nonzero uint32 q. Other complete reports
  # (including delayed stale reports) remain raw evidence but are not official.
  $measurementStage = Invoke-VcstatQueryStage -Serial $serial `
      -QueryBytes $queryBytes -Name 'measurement' `
      -TimeoutSeconds $TimeoutSeconds -ExpectedQ $expectedMeasurementQ `
      -MaximumQueryAttempts $MaximumQueryAttempts `
      -InitialLines $syncStage.complete_lines `
      -InitialPendingText $syncStage.pending_text
  if (-not $measurementStage.report.complete) {
    throw ("Measurement query timed out waiting for q={0} after {1} " +
        "attempts of {2} seconds each" -f $expectedMeasurementQ,
        $MaximumQueryAttempts, $TimeoutSeconds)
  }
} catch {
  $failure = $_.Exception.Message
} finally {
  $totalWatch.Stop()
  $finishedUtc = (Get-Date).ToUniversalTime()
  if ($serial.IsOpen) {
    $serial.Close()
  }
  $serial.Dispose()
}

$syncBytes = [byte[]]@()
$syncReceivedText = ''
$syncOfficialText = ''
if ($null -ne $syncStage) {
  $syncBytes = $syncStage.raw_bytes
  $syncReceivedText = $syncStage.received_text
  if ($syncStage.report.complete) {
    $syncOfficialText = (($syncStage.report.responses | ForEach-Object {
          $_.line
        }) -join "`n") + "`n"
  }
}
$measurementBytes = [byte[]]@()
$measurementReceivedText = ''
$measurementOfficialText = ''
if ($null -ne $measurementStage) {
  $measurementBytes = $measurementStage.raw_bytes
  $measurementReceivedText = $measurementStage.received_text
  if ($measurementStage.report.complete) {
    $measurementOfficialText = (($measurementStage.report.responses |
        ForEach-Object { $_.line }) -join "`n") + "`n"
  }
}

[System.IO.File]::WriteAllBytes($syncRawPath, $syncBytes)
[System.IO.File]::WriteAllText(
    $syncRxTextPath, $syncReceivedText, $utf8NoBom)
[System.IO.File]::WriteAllText(
    $syncTextPath, $syncOfficialText, $utf8NoBom)
[System.IO.File]::WriteAllBytes($rawPath, $measurementBytes)
[System.IO.File]::WriteAllText(
    $rxTextPath, $measurementReceivedText, $utf8NoBom)
[System.IO.File]::WriteAllText(
    $textPath, $measurementOfficialText, $utf8NoBom)

$complete = ($null -eq $failure -and $null -ne $syncStage -and
    $syncStage.report.complete -and $null -ne $measurementStage -and
    $measurementStage.report.complete)
$metadata = [ordered]@{
  schema_version = 3
  test_id = 'FW-VEHICLE-DIAG-001'
  status = $(if ($complete) { 'PASS' } else { 'ERROR' })
  port = $Port
  baud = $Baud
  format = '8N1'
  dtr_enabled = $false
  rts_enabled = $false
  pre_query_drain = $preQueryDrain
  interstage_drain = $interstageDrain
  query_ascii = 'VCSTAT?\n'
  query_hex = (($queryBytes | ForEach-Object { $_.ToString('X2') }) -join ' ')
  timeout_seconds_per_attempt = $TimeoutSeconds
  maximum_query_attempts_per_stage = $MaximumQueryAttempts
  maximum_query_wait_seconds =
      2 * $TimeoutSeconds * $MaximumQueryAttempts
  required_logical_stage_count = 2
  nominal_query_count = 2
  actual_query_count = $(
      $(if ($null -ne $syncStage) {
          $syncStage.metadata.query_attempts
        } else { 0 }) +
      $(if ($null -ne $measurementStage) {
          $measurementStage.metadata.query_attempts
        } else { 0 }))
  expected_measurement_q = $expectedMeasurementQ
  started_utc = $startedUtc.ToString('o')
  finished_utc = $finishedUtc.ToString('o')
  duration_ms = [Math]::Round($totalWatch.Elapsed.TotalMilliseconds, 3)
  synchronization_stage = $(
      if ($null -ne $syncStage) { $syncStage.metadata } else { $null })
  measurement_stage = $(
      if ($null -ne $measurementStage) { $measurementStage.metadata } else { $null })
  official_responses = $(
      if ($null -ne $measurementStage) {
        @($measurementStage.report.responses)
      } else { @() })
  error = $failure
  sync_raw_binary = $syncRawPath
  sync_rx_text = $syncRxTextPath
  sync_response_text = $syncTextPath
  raw_binary = $rawPath
  rx_text = $rxTextPath
  response_text = $textPath
}
[System.IO.File]::WriteAllText(
    $metadataPath,
    (($metadata | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    $utf8NoBom)

if (-not $complete) {
  throw "Vehicle diagnostic failed: $failure (evidence: $OutputDirectory)"
}

Write-Host ("PASS FW-VEHICLE-DIAG-001 port={0} sync_q={1} measurement_q={2} " +
    "responses=3/3 rx={3} evidence={4}" -f $Port,
    $syncStage.report.correlation.q_uint32,
    $measurementStage.report.correlation.q_uint32,
    $measurementBytes.Length, $OutputDirectory)
