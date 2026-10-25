[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$testId = 'FW-VEHICLE-DIAG-USB-STRESS-RUNNER-CONTRACT-001'
$runner = Join-Path $RepoRoot 'tools\run_vehicle_diag_usb_stress.ps1'
$errors = New-Object 'System.Collections.Generic.List[string]'
$checks = New-Object 'System.Collections.Generic.List[object]'

function Add-Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Passed,
    [Parameter(Mandatory = $true)][string]$Detail
  )
  $script:checks.Add([pscustomobject][ordered]@{
    name = $Name
    passed = $Passed
    detail = $Detail
  })
  if (-not $Passed) {
    $script:errors.Add("$Name`: $Detail")
  }
}

function Test-Pattern {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Detail
  )
  Add-Check -Name $Name -Passed ([regex]::IsMatch(
      $Source, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) `
      -Detail $Detail
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $OutputDirectory = Join-Path $RepoRoot `
      "runs\contracts\$testId\$timestamp"
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite contract evidence: $OutputDirectory"
}
$parent = Split-Path -Parent $OutputDirectory
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
  [void][IO.Directory]::CreateDirectory($parent)
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)

$source = ''
if (Test-Path -LiteralPath $runner -PathType Leaf) {
  $source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $runner).Path)
} else {
  Add-Check -Name 'runner_exists' -Passed $false `
      -Detail "missing runner: $runner"
}

if (-not [string]::IsNullOrEmpty($source)) {
  Test-Pattern -Source $source -Name 'default_vehicle_port' `
      -Pattern "\[string\]\`$Port\s*=\s*'COM3'" `
      -Detail 'the live default must remain Vehicle COM3'
  Test-Pattern -Source $source -Name 'default_vehicle_baud' `
      -Pattern '\[int\]\$Baud\s*=\s*115200' `
      -Detail 'the live default must remain 115200 bps'
  Test-Pattern -Source $source -Name 'configurable_iterations' `
      -Pattern '\[int\]\$Iterations\s*=\s*[0-9]+' `
      -Detail 'iteration count must be a typed parameter'
  Test-Pattern -Source $source -Name 'configurable_response_timeout' `
      -Pattern '\[int\]\$ResponseTimeoutMs\s*=\s*[0-9]+' `
      -Detail 'per-query timeout must be configurable in milliseconds'
  Test-Pattern -Source $source -Name 'configurable_quiet_window' `
      -Pattern '\[int\]\$QuietWindowMs\s*=\s*[0-9]+' `
      -Detail 'post-report quiet window must be configurable'
  Test-Pattern -Source $source -Name 'exact_query' `
      -Pattern 'GetBytes\("VCSTAT\?`n"\)' `
      -Detail 'query must be exact ASCII VCSTAT?<LF>'
  Test-Pattern -Source $source -Name 'strict_order' `
      -Pattern "'VCSTAT'\s*\+\s*\[string\]\(\`$lineNumber\s*\+\s*1\)" `
      -Detail 'each report must require VCSTAT1 then VCSTAT2 then VCSTAT3'
  Test-Pattern -Source $source -Name 'same_q_gate' `
      -Pattern "failure_code.*Q_MISMATCH|Q_MISMATCH" `
      -Detail 'all three lines must have the same q'
  Test-Pattern -Source $source -Name 'same_ms_gate' `
      -Pattern "failure_code.*MS_MISMATCH|MS_MISMATCH" `
      -Detail 'all three lines must have the same ms'
  Test-Pattern -Source $source -Name 'q_sequence_gate' `
      -Pattern 'Q_SEQUENCE' `
      -Detail 'successive reports must use the exact next nonzero uint32 q'
  Test-Pattern -Source $source -Name 'partial_gate' `
      -Pattern 'TIMEOUT_PARTIAL' `
      -Detail 'unterminated partial lines must fail closed'
  Test-Pattern -Source $source -Name 'trailing_gate' `
      -Pattern 'TRAILING_BYTES' `
      -Detail 'duplicates or bytes after VCSTAT3 must fail closed'
  Test-Pattern -Source $source -Name 'invalid_byte_gate' `
      -Pattern 'INVALID_BYTE' `
      -Detail 'non-printable/non-ASCII report bytes must fail closed'
  foreach ($artifact in @('rx_raw.bin', 'events.json', 'summary.json',
      'artifact_hashes.json')) {
    Add-Check -Name "artifact_$artifact" `
        -Passed $source.Contains("'$artifact'") `
        -Detail "$artifact must be written"
  }
  foreach ($forbidden in @('DiscardInBuffer', 'DiscardOutBuffer',
      'ReadExisting', 'arduino-cli', 'esptool')) {
    Add-Check -Name ("forbidden_" + ($forbidden -replace '[^A-Za-z]', '_')) `
        -Passed (-not $source.Contains($forbidden)) `
        -Detail "forbidden live/destructive token must be absent: $forbidden"
  }

  $openCalls = [regex]::Matches(
      $source, '(?m)^\s*\$Serial\.Open\(\)\s*$').Count
  Add-Check -Name 'exactly_one_open_site' -Passed ($openCalls -eq 1) `
      -Detail "expected one session Open call site; found $openCalls"
  $closeCalls = [regex]::Matches(
      $source, '(?m)^\s*\$Serial\.Close\(\)\s*$').Count
  Add-Check -Name 'exactly_one_close_site' -Passed ($closeCalls -eq 1) `
      -Detail "expected one session Close call site; found $closeCalls"

  $selfTestBranch = $source.IndexOf('if ($SelfTest.IsPresent)')
  $realSerialConstruction =
      $source.IndexOf('New-Object System.IO.Ports.SerialPort')
  Add-Check -Name 'selftest_before_real_serial' -Passed (
      $selfTestBranch -ge 0 -and $realSerialConstruction -gt $selfTestBranch) `
      -Detail 'offline self-test must return before real SerialPort construction'
}

$selfTestOutput = @()
$selfTestExitCode = $null
if (Test-Path -LiteralPath $runner -PathType Leaf) {
  $powerShellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
  $selfTestOutput = @(& $powerShellExe -NoProfile -ExecutionPolicy Bypass `
      -File $runner -SelfTest 2>&1)
  $selfTestExitCode = $LASTEXITCODE
  Add-Check -Name 'offline_selftest_exit' `
      -Passed ($selfTestExitCode -eq 0) `
      -Detail ("exit={0}; output={1}" -f $selfTestExitCode,
        ($selfTestOutput -join ' | '))
  Add-Check -Name 'offline_selftest_marker' `
      -Passed (($selfTestOutput -join "`n") -match
          'SELFTEST PASS.*serial port was not opened') `
      -Detail 'self-test must explicitly report that no serial port was opened'
}

$passed = ($errors.Count -eq 0)
$summary = [ordered]@{
  schema_version = 1
  test_id = $testId
  result = if ($passed) { 'PASS' } else { 'FAIL' }
  finished_utc = [DateTime]::UtcNow.ToString('o')
  hardware_interaction = $false
  runner = $runner
  runner_sha256 = if (Test-Path -LiteralPath $runner -PathType Leaf) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $runner).Hash
  } else { $null }
  selftest_exit_code = $selfTestExitCode
  selftest_output = @($selfTestOutput | ForEach-Object { [string]$_ })
  checks = $checks.ToArray()
  errors = $errors.ToArray()
}
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText(
    (Join-Path $OutputDirectory 'summary.json'),
    (($summary | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    $utf8NoBom)

if (-not $passed) {
  [Console]::Error.WriteLine(
      "FAIL $testId evidence=$OutputDirectory errors=$($errors.Count)")
  exit 1
}
Write-Host "PASS $testId evidence=$OutputDirectory (no COM access)"
exit 0
