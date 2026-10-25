param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$DiagRoot,
  [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$testId = 'FW-VEHICLE-DIAG-USB-PUMP-001'
if (-not $DiagRoot) {
  $DiagRoot = Join-Path $RepoRoot `
    'vc_lora_vehicle_diag_v2_stable_xiao_esp32s3'
}
if (-not $OutputDir) {
  $OutputDir = Join-Path $RepoRoot "runs\contracts\$testId"
}

$errors = New-Object System.Collections.Generic.List[string]
function Add-Failure([string]$Message) {
  $script:errors.Add($Message)
  Write-Host "FAIL: $Message"
}

function Require-Pattern {
  param([string]$Text, [string]$Pattern, [string]$Description)
  if ($Text -notmatch $Pattern) {
    Add-Failure "$Description does not satisfy /$Pattern/"
  }
}

function Reject-Pattern {
  param([string]$Text, [string]$Pattern, [string]$Description)
  if ($Text -match $Pattern) {
    Add-Failure "$Description unexpectedly satisfies /$Pattern/"
  }
}

function Get-FunctionBody {
  param([string]$Text, [string]$SignaturePattern)
  $match = [regex]::Match($Text, $SignaturePattern)
  if (-not $match.Success) {
    return $null
  }
  $open = $Text.IndexOf('{', $match.Index + $match.Length)
  if ($open -lt 0) {
    return $null
  }
  $depth = 0
  for ($index = $open; $index -lt $Text.Length; ++$index) {
    if ($Text[$index] -eq '{') {
      ++$depth
    } elseif ($Text[$index] -eq '}') {
      --$depth
      if ($depth -eq 0) {
        return $Text.Substring($open + 1, $index - $open - 1)
      }
    }
  }
  return $null
}

function Get-MinimumFormattedReportBytes([string]$Text) {
  $format = [regex]::Match(
    $Text,
    'std::snprintf\(\s*report\.data\(\),\s*report\.size\(\),\s*' +
      '(?<literals>(?:"(?:[^"\\]|\\.)*"\s*)+),')
  if (-not $format.Success) {
    return $null
  }
  $joined = ''
  foreach ($literal in [regex]::Matches(
      $format.Groups['literals'].Value,
      '"(?<body>(?:[^"\\]|\\.)*)"')) {
    $joined += [regex]::Unescape($literal.Groups['body'].Value)
  }
  $minimum = [regex]::Replace($joined, '%08lX', '00000000')
  $minimum = [regex]::Replace($minimum, '%(?:llu|lu|u|d)', '0')
  $minimum = [regex]::Replace($minimum, '%s', '-')
  return [System.Text.Encoding]::ASCII.GetByteCount($minimum)
}

function Get-ConservativeMaximumFormattedReportBytes([string]$Text) {
  $body = Get-FunctionBody $Text `
    'inline\s+void\s+format_report\s*\(\s*const\s+Snapshot&\s+s\s*\)\s*noexcept'
  if ($null -eq $body) {
    return $null
  }
  $formats = @([regex]::Matches(
      $body,
      'std::snprintf\(\s*[^,]+,\s*[^,]+,\s*' +
        '(?<literals>(?:"(?:[^"\\]|\\.)*"\s*)+),'))
  if ($formats.Count -ne 3) {
    return $null
  }
  $joined = ''
  foreach ($format in $formats) {
    foreach ($literal in [regex]::Matches(
        $format.Groups['literals'].Value,
        '"(?<body>(?:[^"\\]|\\.)*)"')) {
      $joined += [regex]::Unescape($literal.Groups['body'].Value)
    }
  }
  $maximum = $joined.Replace('%08lX', ('F' * 8))
  $maximum = $maximum.Replace('%llu', ('9' * 20))
  $maximum = $maximum.Replace('%lu', ('9' * 10))
  $maximum = $maximum.Replace('%u', ('9' * 10))
  $maximum = $maximum.Replace('%d', ('-' + ('9' * 10)))
  # The two bounded strings are param_id[16] and event_text[2048].
  foreach ($bound in @(16, 2047)) {
    $index = $maximum.IndexOf('%s', [StringComparison]::Ordinal)
    if ($index -lt 0) {
      return $null
    }
    $maximum = $maximum.Substring(0, $index) + ('X' * $bound) +
      $maximum.Substring($index + 2)
  }
  if ($maximum -match '%(?:08lX|llu|lu|u|d|s)') {
    return $null
  }
  return [System.Text.Encoding]::ASCII.GetByteCount($maximum)
}

$startedUtc = (Get-Date).ToUniversalTime()
$reportPath = Join-Path $DiagRoot 'vc_lora_vehicle_diag.hpp'
$productionPath = Join-Path $RepoRoot `
  'vc_lora_vehicle_xiao_esp32s3\vc_lora_phase6_bridge.hpp'
$diagBridgePath = Join-Path $DiagRoot 'vc_lora_phase6_bridge.hpp'
$minimumReportBytes = $null
$maximumReportBytes = $null
$legacyBytesIn10Seconds = $null
$worstCaseCalls = $null
$worstCaseCompletionMs = $null
$productionSha256 = $null
$diagBridgeSha256 = $null

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$summaryPath = Join-Path $OutputDir 'summary.json'

try {
  foreach ($path in @($reportPath, $productionPath, $diagBridgePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      Add-Failure "required input is missing: $path"
    }
  }

  if ($errors.Count -eq 0) {
    $report = Get-Content -Raw -LiteralPath $reportPath
    $productionSha256 =
      (Get-FileHash -Algorithm SHA256 -LiteralPath $productionPath).Hash
    $diagBridgeSha256 =
      (Get-FileHash -Algorithm SHA256 -LiteralPath $diagBridgePath).Hash
    $minimumReportBytes = Get-MinimumFormattedReportBytes $report
    if ($null -eq $minimumReportBytes -or $minimumReportBytes -le 0) {
      Add-Failure 'could not derive the minimum three-line VCSTAT report size'
    }
    $maximumReportBytes = Get-ConservativeMaximumFormattedReportBytes $report
    if ($null -eq $maximumReportBytes -or $maximumReportBytes -le 0) {
      Add-Failure 'could not derive the conservative maximum VCSTAT report size'
    } elseif ($maximumReportBytes -ge 10240) {
      Add-Failure "conservative maximum report size $maximumReportBytes is not below 10240"
    }

    $pump = Get-FunctionBody $report `
      'inline\s+void\s+pump_report\s*\(\s*\)\s*noexcept'
    $service = Get-FunctionBody $report `
      'inline\s+void\s+service\s*\(\s*\)\s*noexcept'
    if ($null -eq $pump) {
      Add-Failure 'pump_report() body is missing'
    }
    if ($null -eq $service) {
      Add-Failure 'service() body is missing'
    }

    Require-Pattern $report `
      'constexpr\s+std::size_t\s+kReportCapacity\s*=\s*10240U' `
      'fixed diagnostic report capacity'
    Require-Pattern $report `
      'constexpr\s+std::size_t\s+kUsbChunkCapacity\s*=\s*64U' `
      'single-call USB admission bound'

    if ($null -ne $pump) {
      Require-Pattern $pump `
        'Serial\.isPlugged\s*\(\s*\)[\s\S]*static_cast\s*<\s*bool\s*>\s*\(\s*Serial\s*\)[\s\S]*Serial\.availableForWrite\s*\(\s*\)' `
        'connected HWCDC endpoint gate before writable-capacity admission'
      Require-Pattern $pump 'Serial\.availableForWrite\s*\(\s*\)' `
        'USB writable-capacity admission'
      Require-Pattern $pump `
        'std::min\s*\([\s\S]*remaining[\s\S]*available[\s\S]*kUsbChunkCapacity' `
        'remaining/writable/64-byte bound'
      Require-Pattern $pump `
        'Serial\.write\s*\([\s\S]*report\.data\(\)\s*\+\s*report_offset[\s\S]*chunk_size' `
        'length-bounded direct HWCDC write'
      Require-Pattern $pump `
        'report_offset\s*\+=\s*std::min\s*\(\s*accepted\s*,\s*chunk_size\s*\)' `
        'accepted-byte progress accounting'
      Reject-Pattern $pump 'Serial\.print\s*\(' `
        'NUL-scanned diagnostic emission'
    }

    # ESP32-S3 HWCDC can still expose private-ring capacity while its CDC
    # endpoint is not connected. A diagnostic report must retain its current
    # byte until both raw plug presence and CDC readiness recover; otherwise
    # write() can accept bytes into the lossy private ring and falsely retire
    # the report. This models the QUAL-009-R3 175-byte partial response.
    $partialOffset = 175
    $partialSize = 2158
    foreach ($endpoint in @(
        [pscustomobject]@{ plugged = $false; ready = $false; writable = 256 },
        [pscustomobject]@{ plugged = $true; ready = $false; writable = 256 })) {
      if ($endpoint.plugged -and $endpoint.ready -and
          $endpoint.writable -gt 0) {
        $partialOffset += [Math]::Min(
          $partialSize - $partialOffset,
          [Math]::Min([int]$endpoint.writable, 64))
      }
    }
    if ($partialOffset -ne 175) {
      Add-Failure 'disconnected HWCDC fixture retired partial report bytes'
    }
    $connectedEndpoint =
      [pscustomobject]@{ plugged = $true; ready = $true; writable = 256 }
    if ($connectedEndpoint.plugged -and $connectedEndpoint.ready -and
        $connectedEndpoint.writable -gt 0) {
      $partialOffset += [Math]::Min(
        $partialSize - $partialOffset,
        [Math]::Min([int]$connectedEndpoint.writable, 64))
    }
    if ($partialOffset -ne 239) {
      Add-Failure 'reconnected HWCDC fixture did not resume exact report byte'
    }

    if ($null -ne $service) {
      Require-Pattern $service `
        'collect_query\s*\(\s*\)[\s\S]*snapshot_pending\s*&&\s*safe_to_format\s*\(\s*\)' `
        'safe snapshot-format admission'
      Require-Pattern $service `
        'snapshot_pending\s*&&\s*safe_to_format\s*\(\s*\)[\s\S]*format_report[\s\S]*pump_report\s*\(\s*\)' `
        'format-gated but continuously pumped report service'
      Reject-Pattern $service `
        'if\s*\(\s*!\s*safe_to_(?:report|format)\s*\(\s*\)\s*\)\s*\{?\s*return' `
        'TDD-state early return before USB report progress'
    }

    # HIL observed one 64-byte admission per approximately 5.3-second TDD
    # cycle. Even the shortest representable v6 report cannot meet 10 seconds
    # under that policy. This is an evidence fixture, not a timing relaxation.
    if ($null -ne $minimumReportBytes) {
      $legacyAdmissions = 2 # t=0 ms and t=5300 ms
      $legacyBytesIn10Seconds = $legacyAdmissions * 64
      if ($legacyBytesIn10Seconds -ge $minimumReportBytes) {
        Add-Failure 'legacy one-chunk-per-cycle fixture unexpectedly completes'
      }
    }

    # A connected HWCDC endpoint serviced at a deliberately conservative
    # 100-ms cadence must drain the largest valid report (<10240 bytes) within
    # the runner's 20-second snapshot deadline. Each service call is bounded
    # to one 64-byte admission and never exceeds availableForWrite().
    $remaining = 10239
    $elapsedMs = 0
    $calls = 0
    while ($remaining -gt 0 -and $elapsedMs -lt 20000) {
      $available = 256
      $accepted = [Math]::Min($remaining, [Math]::Min($available, 64))
      if ($accepted -le 0 -or $accepted -gt 64 -or
          $accepted -gt $available) {
        Add-Failure 'semantic fixture violated one-call USB admission bounds'
        break
      }
      $remaining -= $accepted
      ++$calls
      $elapsedMs += 100
    }
    $worstCaseCalls = $calls
    $worstCaseCompletionMs = $elapsedMs
    if ($remaining -ne 0 -or $elapsedMs -gt 20000) {
      Add-Failure 'largest valid three-line report did not drain within 20 s'
    }
  }
} catch {
  Add-Failure "unexpected USB report pump contract failure: $($_.Exception.Message)"
} finally {
  $finishedUtc = (Get-Date).ToUniversalTime()
  $passed = $errors.Count -eq 0
  $summary = [ordered]@{
    schema_version = 1
    test = $testId
    result = if ($passed) { 'PASS' } else { 'FAIL' }
    started_utc = $startedUtc.ToString('o')
    finished_utc = $finishedUtc.ToString('o')
    duration_seconds = [Math]::Round(
      ($finishedUtc - $startedUtc).TotalSeconds, 3)
    minimum_formatted_report_bytes = $minimumReportBytes
    conservative_maximum_formatted_report_bytes = $maximumReportBytes
    observed_hil_chunk_bytes = 64
    observed_hil_cycle_ms_approx = 5300
    legacy_bytes_in_10_seconds = $legacyBytesIn10Seconds
    largest_valid_report_bytes = 10239
    bounded_calls_to_drain_largest = $worstCaseCalls
    conservative_service_cadence_ms = 100
    largest_completion_ms = $worstCaseCompletionMs
    production_bridge_sha256 = $productionSha256
    diagnostic_bridge_sha256 = $diagBridgeSha256
    failures = @($errors)
  }
  $summary | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $summaryPath -Encoding UTF8
  if ($passed) {
    Write-Host ("PASS $testId " +
      "(minimum=$minimumReportBytes B, conservative=$maximumReportBytes B, " +
      "max=10239 B/$worstCaseCalls calls/" +
      "$worstCaseCompletionMs ms)")
  }
}

if ($errors.Count -ne 0) {
  exit 1
}
