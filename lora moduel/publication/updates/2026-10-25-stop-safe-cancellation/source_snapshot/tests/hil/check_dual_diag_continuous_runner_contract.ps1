[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runner = Join-Path $repo 'tools\run_dual_diag_continuous_hil.ps1'
$fixture = Join-Path $repo `
    'runs\hil\E2E-MAV-PARAM-READ-VALID-001\serial1_baud_request.bin'

if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
  throw "Missing continuous dual-COM runner: $runner"
}
if (-not (Test-Path -LiteralPath $fixture -PathType Leaf)) {
  throw "Missing PARAM_REQUEST_READ fixture: $fixture"
}

$source = Get-Content -Raw -LiteralPath $runner

function Assert-SourceContains {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Pattern,

    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  if ($source -notmatch $Pattern) {
    throw "Runner contract missing: $Description"
  }
}

foreach ($forbidden in @(
    'DiscardInBuffer',
    'DiscardOutBuffer',
    'ReadExisting')) {
  if ($source.Contains($forbidden)) {
    throw "Runner must preserve all serial evidence; forbidden API: $forbidden"
  }
}

Assert-SourceContains -Pattern "\[string\]\`$VehiclePort\s*=\s*'COM3'" `
    -Description 'Vehicle default COM3'
Assert-SourceContains -Pattern "\[int\]\`$VehicleBaud\s*=\s*115200" `
    -Description 'Vehicle default 115200 baud'
Assert-SourceContains -Pattern "\[string\]\`$GroundPort\s*=\s*'COM6'" `
    -Description 'Ground default COM6'
Assert-SourceContains -Pattern "\[int\]\`$GroundBaud\s*=\s*57600" `
    -Description 'Ground default 57600 baud'
Assert-SourceContains `
    -Pattern "ValidateRange\(1,\s*600\)[\s\S]{0,100}\[int\]\`$ResponseTimeoutSeconds\s*=\s*20" `
    -Description 'bounded configurable strict-target response timeout'
Assert-SourceContains `
    -Pattern '\$targetWait\.Elapsed\.TotalSeconds\s+-lt\s+\$ResponseTimeoutSeconds' `
    -Description 'live target wait uses configured response timeout'
Assert-SourceContains `
    -Pattern 'timeout_seconds\s*=\s*\$ResponseTimeoutSeconds' `
    -Description 'timeline records configured response timeout'
Assert-SourceContains `
    -Pattern '-TimeoutMs\s+\(1000\.0\s*\*\s*\$ResponseTimeoutSeconds\)' `
    -Description 'strict target judgment uses configured response timeout'
Assert-SourceContains -Pattern '\$vehicleSerial\.Open\(\)' `
    -Description 'one explicit Vehicle handle open'
Assert-SourceContains -Pattern '\$groundSerial\.Open\(\)' `
    -Description 'one explicit Ground handle open'
Assert-SourceContains -Pattern 'GetBytes\("VCSTAT\?`n"\)' `
    -Description 'exact Vehicle query command'
Assert-SourceContains -Pattern 'GetBytes\("VCGSTAT\?`n"\)' `
    -Description 'exact Ground query command'
Assert-SourceContains -Pattern 'vehicle_rx\.raw\.bin' `
    -Description 'contiguous Vehicle RX evidence'
Assert-SourceContains -Pattern 'ground_rx\.raw\.bin' `
    -Description 'contiguous Ground RX evidence'
Assert-SourceContains -Pattern 'ascii_spans\.json' `
    -Description 'byte-offset ASCII report spans'
Assert-SourceContains -Pattern 'ValidateRange\(5000,\s*60000\)' `
    -Description 'non-bypassable minimum power-off confirmation'
Assert-SourceContains -Pattern 'POWER_OFF_CONFIRMED_WAITING_FOR_PORTS' `
    -Description 'operator reconnect marker'
Assert-SourceContains -Pattern 'R0_causal_gate_stop_no_request' `
    -Description 'pre-R0 clean/zero-target injection suppression'
Assert-SourceContains -Pattern 'Import-MavlinkDefinitions' `
    -Description 'canonical all-message MAVLink definitions'
foreach ($field in @('Unsupported', 'UnsupportedFlags', 'BadPayloadLength',
    'BadCrc', 'NoiseBytes', 'partial_buffer_bytes')) {
  Assert-SourceContains -Pattern ([regex]::Escape($field)) `
      -Description "M0-M1 parser integrity field $field"
}
Assert-SourceContains -Pattern "'upb'\s+'exact'\s+32" `
    -Description 'exact 32-byte request uplink'
Assert-SourceContains -Pattern 'ground_diagnostic_delta_zero_' `
    -Description 'Ground invalid/drop/overflow/backlog delta gates'
Assert-SourceContains `
    -Pattern "s1Queued\.delta[\s\S]{0,320}s1Backlog\.delta[\s\S]{0,80}-le\s+1[\s\S]{0,320}endpoint_exact_backlog_optional" `
    -Description 'target may traverse backlog then endpoint exactly once'
Assert-SourceContains -Pattern 'vehicle_diagnostic_delta_zero_' `
    -Description 'Vehicle invalid/drop/overflow delta gates'
foreach ($key in @('ci', 'cc', 'cuv', 'cut', 'cm', 'upinv', 's1ego',
    'hd', 'ubuf', 'eo', 'sc', 'evo', 'tar')) {
  Assert-SourceContains -Pattern ("'{0}'" -f $key) `
      -Description "specific invalid/drop/overflow/current gate $key"
}
Assert-SourceContains `
    -Pattern "vehicle_commit_preflight_ok'[\s\S]{0,100}'tpf'[\s\S]{0,250}vehicle_commit_take_ok'[\s\S]{0,100}'ttk'[\s\S]{0,250}vehicle_commit_egress_ok'[\s\S]{0,100}'tei'" `
    -Description 'atomic commit tri-state success gates'
Assert-SourceContains -Pattern "'tcb'\s+'exact'\s+32" `
    -Description 'atomic commit exact 32-byte gate'
Assert-SourceContains -Pattern "'tcf'\s+'exact'" `
    -Description 'atomic commit exact one-frame gate'
if ($source -match
    "ground_diagnostic_delta_zero_[\s\S]{0,1200}'dlf'") {
  throw 'Runner must not require valid downlink frame count dlf to stay zero'
}
Assert-SourceContains -Pattern 'strictly_increasing' `
    -Description 'post snapshot ms monotonic gate'
Assert-SourceContains -Pattern 'FileOptions\]::WriteThrough' `
    -Description 'write-through evidence files'
Assert-SourceContains -Pattern 'Flush\(\$true\)' `
    -Description 'filesystem flush before close'
Assert-SourceContains -Pattern 'postclose_finalization_error\.json' `
    -Description 'durable post-close ERROR record'
Assert-SourceContains `
    -Pattern "acceptance_scope\s*=\s*\('single strict PARAM_VALUE" `
    -Description 'single-target/HB scope is explicit and not full-list proof'

# Exercise the exact post-close helper implementations without dot-sourcing the
# runner (which would execute its main path).  A timed-out snapshot is valid
# measured FAIL evidence and must be represented by a durable zero-byte file.
$tokens = $null
$parseErrors = $null
$runnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $runner, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
  throw "Runner parse failed: $($parseErrors[0].Message)"
}
$durableFunctionNames = @(
  'Write-BytesDurable',
  'Write-TextDurable',
  'Write-SnapshotText',
  'Write-JsonDurable')
$durableDefinitions = New-Object 'System.Collections.Generic.List[string]'
foreach ($functionName in $durableFunctionNames) {
  $matches = @($runnerAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
      }, $true))
  if ($matches.Count -ne 1) {
    throw "Expected exactly one $functionName definition; found $($matches.Count)"
  }
  $durableDefinitions.Add($matches[0].Extent.Text)
}
Invoke-Expression ($durableDefinitions -join [Environment]::NewLine)

$temporaryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetTempPath())
$postCloseDirectory = Join-Path $temporaryRoot `
    ('vc_lora_postclose_fail_' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($postCloseDirectory)
try {
  $emptyBytesPath = Join-Path $postCloseDirectory 'explicit_empty.bin'
  $nullBytesPath = Join-Path $postCloseDirectory 'unopened_port_null.bin'
  $baselineVehiclePath = Join-Path $postCloseDirectory 'baseline_vehicle.txt'
  $postVehiclePath = Join-Path $postCloseDirectory 'post_vehicle.txt'
  Write-BytesDurable -Path $emptyBytesPath -Bytes ([byte[]]@())
  Write-BytesDurable -Path $nullBytesPath -Bytes $null
  Write-SnapshotText -Path $baselineVehiclePath `
      -Snapshot ([pscustomobject]@{ status = 'TIMEOUT' })
  Write-SnapshotText -Path $postVehiclePath `
      -Snapshot ([pscustomobject]@{ status = 'TIMEOUT' })
  if ((Get-Item -LiteralPath $emptyBytesPath).Length -ne 0 -or
      (Get-Item -LiteralPath $nullBytesPath).Length -ne 0 -or
      (Get-Item -LiteralPath $baselineVehiclePath).Length -ne 0 -or
      (Get-Item -LiteralPath $postVehiclePath).Length -ne 0) {
    throw 'Durable empty-evidence files must remain exactly zero bytes'
  }

  $modeledSummary = [ordered]@{
    schema_version = 1
    status = 'FAIL'
    errors = @('Vehicle baseline VCSTAT snapshot timed out')
    setup_invalid_request_suppressed = $true
    fixture = [ordered]@{ write_count = 0 }
  }
  $summaryPath = Join-Path $postCloseDirectory 'summary.json'
  Write-JsonDurable -Path $summaryPath -Value $modeledSummary
  $hashRows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($file in @(Get-ChildItem -LiteralPath $postCloseDirectory -File |
      Sort-Object Name)) {
    $hashRows.Add([pscustomobject][ordered]@{
      file = $file.Name
      size_bytes = $file.Length
      sha256 = (Get-FileHash -Algorithm SHA256 `
          -LiteralPath $file.FullName).Hash
    })
  }
  $artifactHashesPath = Join-Path $postCloseDirectory 'artifact_hashes.json'
  Write-JsonDurable -Path $artifactHashesPath -Value $hashRows.ToArray()

  $writtenSummary = Get-Content -Raw -LiteralPath $summaryPath |
      ConvertFrom-Json
  $writtenHashes = Get-Content -Raw -LiteralPath $artifactHashesPath |
      ConvertFrom-Json
  [int]$modeledExitCode = if ($writtenSummary.status -eq 'PASS') {
    0
  } elseif ($writtenSummary.status -eq 'ERROR') {
    2
  } else {
    1
  }
  if ($writtenSummary.status -ne 'FAIL' -or $modeledExitCode -ne 1 -or
      -not $writtenSummary.setup_invalid_request_suppressed -or
      $writtenSummary.fixture.write_count -ne 0 -or
      -not (Test-Path -LiteralPath $artifactHashesPath -PathType Leaf) -or
      @($writtenHashes | Where-Object file -eq 'summary.json').Count -ne 1 -or
      @($writtenHashes | Where-Object file -eq 'baseline_vehicle.txt').Count -ne 1) {
    throw 'Measured FAIL post-close summary/hash/exit-1 model failed'
  }
} finally {
  $resolvedPostCloseDirectory = [System.IO.Path]::GetFullPath(
      $postCloseDirectory)
  if (-not $resolvedPostCloseDirectory.StartsWith(
      $temporaryRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
      -not (Split-Path -Leaf $resolvedPostCloseDirectory).StartsWith(
          'vc_lora_postclose_fail_')) {
    throw "Unsafe temporary cleanup target: $resolvedPostCloseDirectory"
  }
  if ([System.IO.Directory]::Exists($resolvedPostCloseDirectory)) {
    [System.IO.Directory]::Delete($resolvedPostCloseDirectory, $true)
  }
}

$openCalls = [regex]::Matches(
    $source, '(?m)^\s*\$(?:vehicle|ground)Serial\.Open\(\)\s*$').Count
if ($openCalls -ne 2) {
  throw "Runner must contain exactly two explicit Open calls; found $openCalls"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
    -SelfTest -FixturePath $fixture -ResponseTimeoutSeconds 180
if ($LASTEXITCODE -ne 0) {
  throw "Runner offline self-test exited with code $LASTEXITCODE"
}

Write-Host 'PASS dual diagnostic continuous runner contract (no COM access)'
