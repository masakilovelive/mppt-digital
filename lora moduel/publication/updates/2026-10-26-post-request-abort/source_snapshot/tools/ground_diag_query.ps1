[CmdletBinding()]
param(
  [ValidatePattern('^COM[0-9]+$')]
  [string]$Port = 'COM6',

  [ValidateRange(1200, 2000000)]
  [int]$Baud = 57600,

  [ValidateRange(1, 60)]
  [int]$TimeoutSeconds = 20,

  [string]$OutputDirectory,

  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-GcstatLine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Line
  )

  $normalized = $Line.TrimEnd("`r", "`n").Trim()
  $tokens = @($normalized -split '\s+')
  if ($tokens.Count -lt 1 -or $tokens[0] -notmatch '^GCSTAT[123]$') {
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

function Test-GcstatCorrelation {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IDictionary]$Responses
  )

  $errors = New-Object System.Collections.Generic.List[string]
  $qValues = New-Object System.Collections.Generic.List[string]
  $msValues = New-Object System.Collections.Generic.List[string]
  foreach ($tag in @('GCSTAT1', 'GCSTAT2', 'GCSTAT3')) {
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
      $errors.Add('GCSTAT1/2/3 q values do not match')
      $commonQ = $null
    }
  }
  if ($msValues.Count -eq 3) {
    $commonMs = $msValues[0]
    if (@($msValues | Select-Object -Unique).Count -ne 1) {
      $errors.Add('GCSTAT1/2/3 ms values do not match')
      $commonMs = $null
    }
  }

  [uint32]$qNumber = 0
  [uint64]$msNumber = 0
  if ($null -ne $commonQ) {
    if (-not [uint32]::TryParse($commonQ, [ref]$qNumber) -or
        $qNumber -eq 0) {
      $errors.Add('common q is not a nonzero uint32 decimal value')
      $commonQ = $null
    }
  }
  if ($null -ne $commonMs) {
    if (-not [uint64]::TryParse($commonMs, [ref]$msNumber)) {
      $errors.Add('common ms is not a uint64 decimal value')
      $commonMs = $null
    }
  }

  return [pscustomobject][ordered]@{
    valid = ($errors.Count -eq 0)
    q = $commonQ
    q_uint32 = $(if ($null -ne $commonQ) { $qNumber } else { $null })
    ms = $commonMs
    ms_uint64 = $(if ($null -ne $commonMs) { $msNumber } else { $null })
    errors = @($errors)
  }
}

function Get-NextGcstatQuery {
  param(
    [Parameter(Mandatory = $true)]
    [uint32]$Current
  )

  if ($Current -eq 0) {
    throw 'A GCSTAT query sequence value of zero is invalid.'
  }
  if ($Current -eq [uint32]::MaxValue) {
    return [uint32]1
  }
  return [uint32]($Current + 1)
}

function Select-GcstatReport {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IEnumerable]$Lines,

    [Nullable[uint32]]$ExpectedQ = $null
  )

  $groups = [ordered]@{}
  $acceptedCandidateLines = 0
  $ignoredCandidateLines = 0
  foreach ($line in $Lines) {
    $parsed = ConvertFrom-GcstatLine -Line ([string]$line)
    if ($null -eq $parsed) {
      continue
    }

    $fieldNames = @($parsed.fields.PSObject.Properties.Name)
    if ($fieldNames -notcontains 'q' -or $fieldNames -notcontains 'ms') {
      ++$ignoredCandidateLines
      continue
    }
    [uint32]$qNumber = 0
    [uint64]$msNumber = 0
    if (-not [uint32]::TryParse([string]$parsed.fields.q, [ref]$qNumber) -or
        $qNumber -eq 0 -or
        -not [uint64]::TryParse([string]$parsed.fields.ms, [ref]$msNumber)) {
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
      $correlation = Test-GcstatCorrelation -Responses $group
      if ($correlation.valid) {
        $orderedResponses = New-Object System.Collections.Generic.List[object]
        foreach ($tag in @('GCSTAT1', 'GCSTAT2', 'GCSTAT3')) {
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

function Invoke-GcstatQueryStage {
  param(
    [Parameter(Mandatory = $true)]
    $Serial,

    [Parameter(Mandatory = $true)]
    [byte[]]$QueryBytes,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds,

    [Nullable[uint32]]$ExpectedQ = $null
  )

  $ascii = [System.Text.Encoding]::ASCII
  $raw = New-Object System.IO.MemoryStream
  $lines = New-Object System.Collections.Generic.List[string]
  $pendingText = ''
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $startedUtc = (Get-Date).ToUniversalTime()
  $Serial.Write($QueryBytes, 0, $QueryBytes.Length)
  $Serial.BaseStream.Flush()
  $buffer = New-Object byte[] 1024
  $report = Select-GcstatReport -Lines $lines -ExpectedQ $ExpectedQ

  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds -and
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
    $report = Select-GcstatReport -Lines $lines -ExpectedQ $ExpectedQ
  }

  $watch.Stop()
  $bytes = $raw.ToArray()
  $raw.Dispose()
  return [pscustomobject][ordered]@{
    metadata = [pscustomobject][ordered]@{
      name = $Name
      query_sent = $true
      expected_q = $(if ($null -ne $ExpectedQ) { [uint32]$ExpectedQ } else { $null })
      status = $(if ($report.complete) { 'COMPLETE' } else { 'TIMEOUT' })
      timeout_seconds = $TimeoutSeconds
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

function Invoke-OfflineSelfTest {
  $command = [System.Text.Encoding]::ASCII.GetBytes("VCGSTAT?`n")
  $expectedCommand = [byte[]](0x56, 0x43, 0x47, 0x53, 0x54, 0x41, 0x54, 0x3F, 0x0A)
  if ([Convert]::ToBase64String($command) -ne
      [Convert]::ToBase64String($expectedCommand)) {
    throw 'SelfTest: query command is not the exact ASCII VCGSTAT?<LF> sequence.'
  }

  $heartbeatDiagnosticKeys = @(
    'hpq', 'hpp', 'hpada', 'hpv', 'hpe', 'hpx', 'hpr', 'hpinv',
    'hpfor', 'hpdup', 'hpadm', 'hpia', 'hprej', 'hpabort', 'hpiab',
    'hpdc', 'hpblk', 'hpdrop', 'hpshort', 'hpback', 'hpwu', 'hpcon',
    'hpdis', 'hpmaxb', 'hphold', 'hpusbg', 'hpmaxq',
    'hre', 'hro', 'hrv', 'hrls', 'hrlm', 'hrlg', 'hrlms', 'hrlp',
    'hrlc', 'hrmg', 'hrmms', 'hrmp', 'hrmc', 'hrmst', 'hrmcy',
    'hrmaux', 'hrmrb', 'hrmpa', 'hrmpq', 'hrmpp', 'hrmpad',
    'hrmobf', 'hrmob', 'hrmuq', 'hrmuwp', 'hrmuw', 'hrvg', 'hrvms',
    'hrvp', 'hrvc', 'hrvst', 'hrvcy', 'hrvaux', 'hrvrb', 'hrvpa',
    'hrvpq', 'hrvpp', 'hrvpad', 'hrvobf', 'hrvob', 'hrvuq',
    'hrvuwp', 'hrvuw',
    'hue', 'huo', 'huv', 'huls', 'hulm', 'hulg', 'hulms', 'hulp',
    'hulc', 'humg', 'humms', 'hump', 'humc', 'humst', 'humcy',
    'humaux', 'humrb', 'humpa', 'humpq', 'humpp', 'humpad',
    'humobf', 'humob', 'humuq', 'humuwp', 'humuw', 'huvg', 'huvms',
    'huvp', 'huvc', 'huvst', 'huvcy', 'huvaux', 'huvrb', 'huvpa',
    'huvpq', 'huvpp', 'huvpad', 'huvobf', 'huvob', 'huvuq',
    'huvuwp', 'huvuw'
  )
  $heartbeatDiagnosticText = @(
    for ($index = 0; $index -lt $heartbeatDiagnosticKeys.Count; ++$index) {
      '{0}={1}' -f $heartbeatDiagnosticKeys[$index], ($index + 1)
    }
  ) -join ' '
  $fixture = @(
    'boot message',
    'GCSTAT1 q=17 ms=1234 role=ground uptime_ms=1234 rx=9',
    'GCSTAT2 q=17 ms=1234 radio_rx=8 radio_tx=7 pending=0 obp22=3',
    ('GCSTAT3 q=17 ms=1234 usb_rx=6 radio_tx=5 state=RUN ' +
      $heartbeatDiagnosticText)
  )
  $responses = [ordered]@{}
  foreach ($line in $fixture) {
    $parsed = ConvertFrom-GcstatLine -Line $line
    if ($null -ne $parsed) {
      $responses[$parsed.tag] = $parsed
    }
  }

  foreach ($tag in @('GCSTAT1', 'GCSTAT2', 'GCSTAT3')) {
    if (-not $responses.Contains($tag)) {
      throw "SelfTest: missing parsed response $tag."
    }
  }
  if ($responses['GCSTAT1'].fields.uptime_ms -ne '1234' -or
      $responses['GCSTAT2'].fields.obp22 -ne '3' -or
      $responses['GCSTAT3'].fields.state -ne 'RUN') {
    throw 'SelfTest: key=value parsing produced an unexpected value.'
  }
  for ($index = 0; $index -lt $heartbeatDiagnosticKeys.Count; ++$index) {
    $key = $heartbeatDiagnosticKeys[$index]
    $property = $responses['GCSTAT3'].fields.PSObject.Properties[$key]
    if ($null -eq $property -or $property.Value -ne [string]($index + 1)) {
      throw "SelfTest: heartbeat diagnostic field $key did not round-trip."
    }
  }
  $correlation = Test-GcstatCorrelation -Responses $responses
  if (-not $correlation.valid -or $correlation.q -ne '17' -or
      $correlation.ms -ne '1234') {
    throw 'SelfTest: matching q/ms correlation was rejected.'
  }

  $responses['GCSTAT2'].fields.q = '18'
  if ((Test-GcstatCorrelation -Responses $responses).valid) {
    throw 'SelfTest: unequal q values were accepted.'
  }
  $responses['GCSTAT2'].fields.q = '17'
  $responses['GCSTAT3'].fields.ms = '1235'
  if ((Test-GcstatCorrelation -Responses $responses).valid) {
    throw 'SelfTest: unequal ms values were accepted.'
  }
  $responses['GCSTAT3'].fields.ms = '1234'
  $responses['GCSTAT1'].fields.PSObject.Properties.Remove('q')
  if ((Test-GcstatCorrelation -Responses $responses).valid) {
    throw 'SelfTest: a missing correlation field was accepted.'
  }
  if ($null -ne (ConvertFrom-GcstatLine -Line 'GCSTAT4 invalid=1')) {
    throw 'SelfTest: an unsupported response tag was accepted.'
  }

  if ((Get-NextGcstatQuery -Current 17) -ne 18 -or
      (Get-NextGcstatQuery -Current ([uint32]::MaxValue)) -ne 1) {
    throw 'SelfTest: uint32 q increment/wrap-with-zero-skip is incorrect.'
  }

  # A delayed stale report may be fully valid internally. During measurement it
  # must be ignored until the report with the exact next q is complete.
  $staleDelayedLines = @(
    'GCSTAT1 q=41 ms=900 state=STALE',
    'GCSTAT2 q=41 ms=900 state=STALE',
    'GCSTAT3 q=41 ms=900 state=STALE',
    'GCSTAT1 q=42 ms=1000 state=MEASURE',
    'GCSTAT2 q=42 ms=1000 state=MEASURE',
    'GCSTAT3 q=42 ms=1000 state=MEASURE'
  )
  $selected = Select-GcstatReport -Lines $staleDelayedLines -ExpectedQ 42
  if (-not $selected.complete -or $selected.correlation.q_uint32 -ne 42 -or
      $selected.ignored_candidate_lines -ne 3) {
    throw 'SelfTest: delayed stale report was not rejected during measurement.'
  }

  $wrongSequenceLines = @(
    'GCSTAT1 q=43 ms=1001 state=WRONG',
    'GCSTAT2 q=43 ms=1001 state=WRONG',
    'GCSTAT3 q=43 ms=1001 state=WRONG'
  )
  if ((Select-GcstatReport -Lines $wrongSequenceLines -ExpectedQ 42).complete) {
    throw 'SelfTest: an out-of-sequence measurement report was accepted.'
  }

  $wrapLines = @(
    'GCSTAT1 q=1 ms=0 state=WRAP',
    'GCSTAT2 q=1 ms=0 state=WRAP',
    'GCSTAT3 q=1 ms=0 state=WRAP'
  )
  if (-not (Select-GcstatReport -Lines $wrapLines -ExpectedQ 1).complete) {
    throw 'SelfTest: wrapped q=1 measurement report was rejected.'
  }

  $longUptimeLines = @(
    'GCSTAT1 q=2 ms=4294967296 state=LONG',
    'GCSTAT2 q=2 ms=4294967296 state=LONG',
    'GCSTAT3 q=2 ms=4294967296 state=LONG'
  )
  $longUptime = Select-GcstatReport -Lines $longUptimeLines -ExpectedQ 2
  if (-not $longUptime.complete -or
      $longUptime.correlation.ms_uint64 -ne [uint64]4294967296) {
    throw 'SelfTest: uint64 device uptime correlation was rejected.'
  }

  Write-Host 'SELFTEST PASS ground_diag_query.ps1 (serial port was not opened)'
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
      "runs\hil\FW-GROUND-DIAG-001\{0}-{1}" -f $timestamp, $Port)
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
$queryBytes = $ascii.GetBytes("VCGSTAT?`n")
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
  $syncStage = Invoke-GcstatQueryStage -Serial $serial `
      -QueryBytes $queryBytes -Name 'synchronization' `
      -TimeoutSeconds $TimeoutSeconds
  if (-not $syncStage.report.complete) {
    throw "Synchronization query timed out after $TimeoutSeconds seconds"
  }
  $expectedMeasurementQ = Get-NextGcstatQuery `
      -Current $syncStage.report.correlation.q_uint32

  # Remove any suffix or delayed bytes belonging to the synchronization stage.
  # The q sequence check below remains authoritative after this hygiene drain.
  $interstageDrain = Clear-SerialInputUntilQuiet -Serial $serial
  if (-not $interstageDrain.quiet_achieved) {
    throw ("RX did not become quiet between query stages within {0} ms" -f `
        $interstageDrain.max_ms)
  }

  # Stage 2 accepts only the exact next nonzero uint32 q. Other complete reports
  # (including delayed stale reports) remain raw evidence but are not official.
  $measurementStage = Invoke-GcstatQueryStage -Serial $serial `
      -QueryBytes $queryBytes -Name 'measurement' `
      -TimeoutSeconds $TimeoutSeconds -ExpectedQ $expectedMeasurementQ
  if (-not $measurementStage.report.complete) {
    throw ("Measurement query timed out waiting for q={0} after {1} seconds" -f `
        $expectedMeasurementQ, $TimeoutSeconds)
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
  schema_version = 2
  test_id = 'FW-GROUND-DIAG-001'
  status = $(if ($complete) { 'PASS' } else { 'ERROR' })
  port = $Port
  baud = $Baud
  format = '8N1'
  dtr_enabled = $false
  rts_enabled = $false
  pre_query_drain = $preQueryDrain
  interstage_drain = $interstageDrain
  query_ascii = 'VCGSTAT?\n'
  query_hex = (($queryBytes | ForEach-Object { $_.ToString('X2') }) -join ' ')
  timeout_seconds_per_stage = $TimeoutSeconds
  required_query_count = 2
  actual_query_count = $(
      $(if ($null -ne $syncStage) { 1 } else { 0 }) +
      $(if ($null -ne $measurementStage) { 1 } else { 0 }))
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
  throw "Ground diagnostic failed: $failure (evidence: $OutputDirectory)"
}

Write-Host ("PASS FW-GROUND-DIAG-001 port={0} sync_q={1} measurement_q={2} " +
    "responses=3/3 rx={3} evidence={4}" -f $Port,
    $syncStage.report.correlation.q_uint32,
    $measurementStage.report.correlation.q_uint32,
    $measurementBytes.Length, $OutputDirectory)
