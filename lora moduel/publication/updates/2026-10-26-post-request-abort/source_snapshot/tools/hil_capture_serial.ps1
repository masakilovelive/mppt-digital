[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^COM[0-9]+$')]
  [string]$Port,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^(FW|E2E-MAV)-[A-Z0-9-]+$')]
  [string]$TestId,

  [ValidateSet('ground_usb', 'vehicle_usb', 'pixhawk_fixture')]
  [string]$Endpoint = 'ground_usb',

  [ValidateRange(1, 86400)]
  [int]$DurationSeconds = 60,

  [ValidateRange(1200, 2000000)]
  [int]$Baud = 57600,

  [string]$OutputDirectory,

  [string]$TransmitFile,

  [ValidateRange(0, 86400000)]
  [int]$TransmitDelayMs = 0,

  [ValidateRange(1, 1000)]
  [int]$TransmitCount = 1,

  [ValidateRange(0, 86400000)]
  [int]$TransmitIntervalMs = 0,

  [switch]$DtrEnable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('System.IO.Ports.SerialPort' -as [type])) {
  Add-Type -AssemblyName System.IO.Ports
}

if ($TransmitCount -gt 1 -and $TransmitIntervalMs -le 0) {
  throw 'TransmitIntervalMs must be greater than zero when TransmitCount is greater than one.'
}

$repo = Split-Path -Parent $PSScriptRoot
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
if (-not $OutputDirectory) {
  $OutputDirectory = Join-Path $repo ("runs\hil\{0}\{1}-{2}" -f `
      $TestId, $timestamp, $Endpoint)
}

$capturePath = Join-Path $OutputDirectory 'capture.jsonl'
$rxPath = Join-Path $OutputDirectory 'rx.bin'
$txPath = Join-Path $OutputDirectory 'tx.bin'
$metadataPath = Join-Path $OutputDirectory 'capture_metadata.json'

foreach ($path in @($capturePath, $rxPath, $txPath, $metadataPath)) {
  if (Test-Path -LiteralPath $path) {
    throw "Refusing to overwrite existing HIL evidence: $path"
  }
}

$txBytes = [byte[]]@()
if ($TransmitFile) {
  if (-not (Test-Path -LiteralPath $TransmitFile -PathType Leaf)) {
    throw "Transmit fixture not found: $TransmitFile"
  }
  $txBytes = [System.IO.File]::ReadAllBytes(
      (Resolve-Path -LiteralPath $TransmitFile).Path)
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$captureWriter = New-Object System.IO.StreamWriter(
    $capturePath, $false, $utf8NoBom)
$rxStream = New-Object System.IO.FileStream(
    $rxPath, [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
$txStream = New-Object System.IO.FileStream(
    $txPath, [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)

$serial = New-Object System.IO.Ports.SerialPort
$serial.PortName = $Port
$serial.BaudRate = $Baud
$serial.DataBits = 8
$serial.Parity = [System.IO.Ports.Parity]::None
$serial.StopBits = [System.IO.Ports.StopBits]::One
$serial.Handshake = [System.IO.Ports.Handshake]::None
$serial.ReadTimeout = 20
$serial.WriteTimeout = 2000
$serial.DtrEnable = $DtrEnable.IsPresent
$serial.RtsEnable = $false
$stopwatch = [System.Diagnostics.Stopwatch]::new()
$startedUtc = (Get-Date).ToUniversalTime()
$txSentCount = 0
$rxCount = [uint64]0
$txCount = [uint64]0
$completed = $false

function Get-ElapsedMicroseconds {
  return [uint64](
      ($stopwatch.ElapsedTicks * 1000000.0) /
      [System.Diagnostics.Stopwatch]::Frequency)
}

function Write-CaptureRecord([System.Collections.IDictionary]$Record) {
  $captureWriter.WriteLine(($Record | ConvertTo-Json -Compress))
  $captureWriter.Flush()
}

try {
  Write-CaptureRecord ([ordered]@{
    kind = 'header'
    schema_version = 1
    tool = 'hil_capture_serial.ps1'
    test_id = $TestId
    endpoint = $Endpoint
    port = $Port
    baud = $Baud
    format = '8N1'
    dtr_enabled = $DtrEnable.IsPresent
    started_utc = $startedUtc.ToString('o')
  })

  $serial.Open()
  $stopwatch.Start()
  $buffer = New-Object byte[] 4096

  while ($stopwatch.Elapsed.TotalSeconds -lt $DurationSeconds) {
    $nextTransmitMs = $TransmitDelayMs +
        ($txSentCount * $TransmitIntervalMs)
    if ($txSentCount -lt $TransmitCount -and $txBytes.Length -gt 0 -and
        $stopwatch.ElapsedMilliseconds -ge $nextTransmitMs) {
      $serial.Write($txBytes, 0, $txBytes.Length)
      $serial.BaseStream.Flush()
      $txStream.Write($txBytes, 0, $txBytes.Length)
      $txCount += [uint64]$txBytes.Length
      Write-CaptureRecord ([ordered]@{
        kind = 'bytes'
        t_us = Get-ElapsedMicroseconds
        direction = 'tx'
        transmit_index = $txSentCount + 1
        data_b64 = [Convert]::ToBase64String($txBytes)
      })
      $txSentCount++
    }

    $available = $serial.BytesToRead
    if ($available -le 0) {
      Start-Sleep -Milliseconds 1
      continue
    }
    $wanted = [Math]::Min($available, $buffer.Length)
    $read = $serial.Read($buffer, 0, $wanted)
    if ($read -le 0) {
      continue
    }
    $chunk = New-Object byte[] $read
    [Array]::Copy($buffer, 0, $chunk, 0, $read)
    $rxStream.Write($chunk, 0, $chunk.Length)
    $rxCount += [uint64]$chunk.Length
    Write-CaptureRecord ([ordered]@{
      kind = 'bytes'
      t_us = Get-ElapsedMicroseconds
      direction = 'rx'
      data_b64 = [Convert]::ToBase64String($chunk)
    })
  }
  $completed = $true
} finally {
  $stopwatch.Stop()
  if ($serial.IsOpen) {
    $serial.Close()
  }
  Write-CaptureRecord ([ordered]@{
    kind = 'footer'
    completed = $completed
    duration_us = Get-ElapsedMicroseconds
    rx_bytes = $rxCount
    tx_bytes = $txCount
    finished_utc = (Get-Date).ToUniversalTime().ToString('o')
  })
  $captureWriter.Dispose()
  $rxStream.Dispose()
  $txStream.Dispose()
  $serial.Dispose()
}

$metadata = [ordered]@{
  schema_version = 1
  status = $(if ($completed) { 'CAPTURED' } else { 'INCOMPLETE' })
  test_id = $TestId
  endpoint = $Endpoint
  port = $Port
  baud = $Baud
  format = '8N1'
  dtr_enabled = $DtrEnable.IsPresent
  started_utc = $startedUtc.ToString('o')
  finished_utc = (Get-Date).ToUniversalTime().ToString('o')
  duration_us = Get-ElapsedMicroseconds
  rx_bytes = $rxCount
  tx_bytes = $txCount
  transmit_fixture = $(if ($TransmitFile) {
      (Resolve-Path -LiteralPath $TransmitFile).Path
    } else { $null })
  transmit_count_requested = $TransmitCount
  transmit_count_completed = $txSentCount
  transmit_interval_ms = $TransmitIntervalMs
  capture_jsonl = $capturePath
  rx_binary = $rxPath
  tx_binary = $txPath
}
[System.IO.File]::WriteAllText(
    $metadataPath,
    (($metadata | ConvertTo-Json -Depth 4) + [Environment]::NewLine),
    $utf8NoBom)

Write-Host ("CAPTURED {0} endpoint={1} rx={2} tx={3} evidence={4}" -f `
    $TestId, $Endpoint, $rxCount, $txCount, $OutputDirectory)
