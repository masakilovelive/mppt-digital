param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$DiagRoot,
  [string]$Compiler,
  [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$testId = 'FW-D7-PARAM-OBSERVER-001'
$errors = New-Object System.Collections.Generic.List[string]
if (-not $OutputDir) {
  $OutputDir = Join-Path $RepoRoot `
    'runs\contracts\FW-D7-PARAM-OBSERVER-001'
}

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

function Find-Compiler([string]$Explicit) {
  if ($Explicit) {
    if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
      throw "Compiler not found: $Explicit"
    }
    return (Resolve-Path -LiteralPath $Explicit).Path
  }
  $found = Get-Command clang++ -ErrorAction SilentlyContinue
  if ($found) {
    return $found.Source
  }
  $fallback = Join-Path $env:TEMP `
    'vc_lora_host_tools\llvm-mingw-20260616-tar\llvm-mingw-20260616-ucrt-x86_64\bin\clang++.exe'
  if (Test-Path -LiteralPath $fallback -PathType Leaf) {
    return (Resolve-Path -LiteralPath $fallback).Path
  }
  throw 'Required host compiler clang++ was not found'
}

function Invoke-NativeCapture {
  param([string]$FilePath, [string[]]$Arguments)
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = @($output | ForEach-Object { $_.ToString() })
  }
}

if (-not $DiagRoot) {
  $DiagRoot = Join-Path $RepoRoot `
    'vc_lora_vehicle_diag_v2_stable_xiao_esp32s3'
}
$observerPath = Join-Path $diagRoot 'vc_lora_vehicle_diag_observer.hpp'
$reportPath = Join-Path $diagRoot 'vc_lora_vehicle_diag.hpp'
$adapterPath = Join-Path $diagRoot 'vc_lora_phase6_bridge.hpp'
$hostSource = Join-Path $RepoRoot `
  'tests\host\standalone\d7_param_observer_contract_tests.cpp'
$mavlinkSource = Join-Path $RepoRoot 'core\src\mavlink_frame.cpp'
$coreInclude = Join-Path $RepoRoot 'core\include'

$startedUtc = (Get-Date).ToUniversalTime()
$compilerPath = $null
$compileExit = $null
$hostExit = $null
$staticPassed = $false
$hostPassed = $false

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$compileLog = Join-Path $OutputDir 'compile.log'
$hostLog = Join-Path $OutputDir 'host.log'
$summaryPath = Join-Path $OutputDir 'summary.json'
$executable = Join-Path $OutputDir 'd7_param_observer_contract_tests.exe'

try {
  foreach ($path in @($observerPath, $reportPath, $adapterPath,
      $hostSource, $mavlinkSource)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      Add-Failure "required input is missing: $path"
    }
  }

  if ($errors.Count -eq 0) {
    $observer = Get-Content -Raw -LiteralPath $observerPath
    $report = Get-Content -Raw -LiteralPath $reportPath
    $adapter = Get-Content -Raw -LiteralPath $adapterPath
    $hostSourceText = Get-Content -Raw -LiteralPath $hostSource

    Require-Pattern $observer `
      'struct\s+D7ParamValueStats\s*\{' `
      'D7 PARAM_VALUE POD structure'
    Require-Pattern $observer `
      'std::array\s*<\s*char\s*,\s*17U\s*>\s+last_param_id' `
      'fixed 16-byte param_id plus NUL storage'
    foreach ($field in @('decoded', 'serial1_baud_exact', 'decode_errors',
        'counter_overflows', 'last_ms', 'last_value_bits', 'last_count',
        'last_index', 'last_type', 'last_sequence', 'last_system_id',
        'last_component_id', 'serial1_last_ms',
        'serial1_last_value_bits', 'serial1_last_count',
        'serial1_last_index', 'serial1_last_type',
        'serial1_last_sequence', 'serial1_last_system_id',
        'serial1_last_component_id')) {
      Require-Pattern $observer ("\b{0}\b" -f $field) `
        "D7 PARAM_VALUE field $field"
    }
    Require-Pattern $observer `
      'static_assert\s*\(\s*std::is_trivially_copyable\s*<\s*D7ParamValueStats\s*>' `
      'D7 PARAM_VALUE fixed POD contract'
    Require-Pattern $observer `
      'D7ParamValueStats\s+pixhawk_d7_param_value' `
      'D7 PARAM_VALUE observer state ownership'
    Require-Pattern $observer `
      'observe_d7_param_value\s*\(\s*const\s+vc_lora::MavlinkFrame\s*&' `
      'validated-frame PARAM_VALUE decoder'
    Require-Pattern $observer `
      'message_id\s*!=\s*22U[\s\S]{0,100}payload_length\s*!=\s*25U' `
      'PARAM_VALUE message and payload length revalidation'
    Require-Pattern $observer `
      'payload\[\s*8U\s*\+\s*index\s*\]' `
      'full wire param_id extraction'
    Require-Pattern $observer `
      "'S'\s*,\s*'E'\s*,\s*'R'\s*,\s*'I'\s*,\s*'A'\s*,\s*'L'\s*,\s*'1'\s*,\s*'_'[\s\S]{0,100}'B'\s*,\s*'A'\s*,\s*'U'\s*,\s*'D'[\s\S]{0,100}0U\s*,\s*0U\s*,\s*0U\s*,\s*0U" `
      'exact padded SERIAL1_BAUD wire identifier'
    Require-Pattern $observer `
      'memcmp\s*\(\s*payload\s*\+\s*8U[\s\S]{0,100}size\s*\(\s*\)' `
      'full 16-byte SERIAL1_BAUD equality check'
    Require-Pattern $observer `
      'is_expected_serial1_baud_param_value[\s\S]{0,900}frame\.system_id\s*!=\s*1U[\s\S]{0,120}frame\.component_id\s*!=\s*1U[\s\S]{0,900}0x42640000U[\s\S]{0,120}count\s*!=\s*0U[\s\S]{0,160}0xFFFFU[\s\S]{0,120}payload\[24U\]\s*==\s*6U' `
      'strict expected SERIAL1_BAUD tuple predicate'
    Require-Pattern $observer `
      'const\s+bool\s+expected_target\s*=\s*observe_d7_param_value[\s\S]{0,220}if\s*\(\s*expected_target[\s\S]{0,220}d6_exact\s*>\s*0U' `
      'strict predicate gates target counter and timestamp'
    Require-Pattern $hostSourceText `
      'wrong_source[\s\S]{0,1000}wrong_value[\s\S]{0,2500}STAT_RUNTIME[\s\S]{0,2200}d7_matching_index\s*==\s*1U[\s\S]{0,200}d7_msg22_ms\s*==\s*1234U' `
      'wrong-source/value and STAT_RUNTIME do not advance target D7 evidence'
    Require-Pattern $observer `
      'observe_stream_byte\s*\(\s*pixhawk_d7_parser[\s\S]{0,220}frame\s*\)[\s\S]{0,650}frame\.message_id\s*!=\s*22U[\s\S]{0,180}observe_d7_param_value\s*\(\s*frame\s*,\s*now_ms\s*\)' `
      'PARAM_VALUE decoding only after CRC-valid D7 parser completion'
    Require-Pattern $observer `
      'gap_observations[\s\S]{0,120}gap_violation_count[\s\S]{0,300}latest_violation' `
      'D7 heartbeat observation/violation/latest-violation latch'
    Require-Pattern $observer `
      'candidate\s*>\s*kHeartbeatGapViolationMs[\s\S]{0,120}\+\+gap\.gap_violation_count[\s\S]{0,120}gap\.latest_violation\s*=\s*event' `
      'D7 heartbeat violation threshold and latest context update'
    Require-Pattern $observer `
      'frame\.message_id\s*==\s*0U[\s\S]{0,100}frame\.system_id\s*==\s*1U[\s\S]{0,100}frame\.component_id\s*==\s*1U[\s\S]{0,180}observe_vehicle_heartbeat_gap' `
      'D7 primary 1/1 heartbeat-only gap observer'
    Reject-Pattern $observer `
      '\b(?:String|malloc|calloc|realloc|free)\b|\bnew\s+' `
      'observer dynamic-allocation purity'

    # The observer and scheduler must receive the very same byte read from D7,
    # with no synthetic or second UART read in between.
    Require-Pattern $adapter `
      'const\s+int\s+(?<d7value>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*pixhawk_serial\.read\s*\(\s*\)[\s\S]{0,2400}observe_pixhawk_read\s*\(\s*static_cast\s*<\s*std::uint8_t\s*>\s*\(\s*\k<d7value>\s*\)\s*,\s*now_ms\s*,\s*heartbeat_context\s*\)[\s\S]{0,180}vehicle_scheduler\.ingest_byte\s*\(\s*static_cast\s*<\s*std::uint8_t\s*>\s*\(\s*\k<d7value>\s*\)\s*,\s*now_ms\s*\)' `
      'same physical D7 byte observer/scheduler fan-out'

    Require-Pattern $report 'VCSTAT1\s+q=%[^"\r\n]*\sms=%' `
      'VCSTAT1 correlated q/ms fields'
    Require-Pattern $report 'VCSTAT2\s+q=%[^"\r\n]*\sms=%' `
      'VCSTAT2 correlated q/ms fields'
    Require-Pattern $report 'VCSTAT3\s+q=%[^"\r\n]*\sms=%' `
      'VCSTAT3 correlated q/ms fields'
    Reject-Pattern $report 'VCSTAT4' 'three-line VCSTAT schema'
    Require-Pattern $report 'VCSTAT1[^"\r\n]*\bv=6\b' `
      'Vehicle diagnostic schema v6'
    foreach ($key in @('d7iv', 'd7pb', 'pvok', 'pvs1', 'pvid', 'pvval',
        'pvcnt', 'pvidx', 'pvtype', 'pvseq', 'pvsys', 'pvcomp', 'pvms',
        'pvbad', 'pvov', 'pvs1val', 'pvs1cnt', 'pvs1idx', 'pvs1type',
        'pvs1seq', 'pvs1sys', 'pvs1comp', 'pvs1ms')) {
      Require-Pattern $report ("\b{0}=%" -f $key) `
        "VCSTAT3 PARAM_VALUE key $key"
    }
    foreach ($key in @('d7he', 'd7ho', 'd7hv', 'd7hlg', 'd7hmg',
        'd7hvg', 'd7hvms', 'd7hvst', 'd7hvcy', 'd7hvaux', 'd7hvrb',
        'd7hvpa', 'd7hvsqf', 'd7hvsqb', 'd7hvpgq', 'd7hvpga',
        'd7hvprq', 'd7hvptq', 'd7hvhbp', 'd7hvhbta', 'd7hvhbac',
        'd7hvhbpr')) {
      Require-Pattern $report ("\b{0}=%" -f $key) `
        "VCSTAT3 D7 heartbeat gap key $key"
    }
    Require-Pattern $report '\bpvval=%08lX\b' `
      'locale-independent IEEE754 hexadecimal pvval'
    Reject-Pattern $report '\bpvval=%[-+ #0-9.]*[aAeEfFgG]' `
      'locale-sensitive floating-point pvval formatting'

    $qCount = [regex]::Matches(
      $report, 'static_cast<unsigned long>\s*\(\s*s\.query_id\s*\)').Count
    $msCount = [regex]::Matches(
      $report,
      'static_cast<unsigned long long>\s*\(\s*s\.now_ms\s*\)').Count
    if ($qCount -ne 3 -or $msCount -ne 3) {
      Add-Failure "VCSTAT1/2/3 must each format the same q/ms snapshot (q=$qCount ms=$msCount)"
    }

    $capacityMatch = [regex]::Match(
      $report, 'kReportCapacity\s*=\s*(?<capacity>[0-9]+)U')
    if (-not $capacityMatch.Success) {
      Add-Failure 'bounded report capacity declaration is missing'
    } elseif ([int]$capacityMatch.Groups['capacity'].Value -ne 10240) {
      Add-Failure 'report capacity is not the fixed 10240-byte bound'
    }
    Require-Pattern $report `
      'written\s*<=\s*0\s*\|\|\s*static_cast<std::size_t>\s*\(\s*written\s*\)\s*>=\s*report\.size\s*\(\s*\)' `
      'bounded snprintf overflow fail-closed check'
    $staticPassed = $errors.Count -eq 0
  }

  try {
    $compilerPath = Find-Compiler $Compiler
    $compile = Invoke-NativeCapture $compilerPath @(
      '-std=c++17', '-Wall', '-Wextra', '-Wpedantic', '-Wconversion',
      "-I$coreInclude", "-I$diagRoot", $hostSource, $mavlinkSource,
      '-static', '-o', $executable
    )
    $compileExit = $compile.ExitCode
    $compile.Output -join [Environment]::NewLine |
      Set-Content -LiteralPath $compileLog -Encoding UTF8
    if ($compile.ExitCode -ne 0) {
      Add-Failure "host semantic contract compile failed (exit $($compile.ExitCode))"
    } else {
      $hostRun = Invoke-NativeCapture $executable @()
      $hostExit = $hostRun.ExitCode
      $hostRun.Output -join [Environment]::NewLine |
        Set-Content -LiteralPath $hostLog -Encoding UTF8
      if ($hostRun.ExitCode -ne 0) {
        Add-Failure "host semantic contract failed (exit $($hostRun.ExitCode))"
      } else {
        $hostPassed = $true
      }
    }
  } catch {
    Add-Failure "host semantic contract infrastructure failed: $($_.Exception.Message)"
  }
} catch {
  Add-Failure "unexpected contract failure: $($_.Exception.Message)"
} finally {
  $finishedUtc = (Get-Date).ToUniversalTime()
  $passed = $errors.Count -eq 0 -and $staticPassed -and $hostPassed
  $summary = [ordered]@{
    schema_version = 1
    test = $testId
    result = if ($passed) { 'PASS' } else { 'FAIL' }
    started_utc = $startedUtc.ToString('o')
    finished_utc = $finishedUtc.ToString('o')
    duration_seconds = [math]::Round(
      ($finishedUtc - $startedUtc).TotalSeconds, 3)
    static_contract_passed = $staticPassed
    host_semantic_passed = $hostPassed
    compiler = $compilerPath
    diagnostic_root = $diagRoot
    compile_exit_code = $compileExit
    host_exit_code = $hostExit
    errors = @($errors)
    compile_log = $compileLog
    host_log = $hostLog
    requirements = @(
      'valid MAVLink1/2 PARAM_VALUE decode',
      'strict SERIAL1_BAUD expected tuple cumulative count',
      'STAT_RUNTIME distinguishable without clearing pvs1 or advancing td7',
      'later STAT_RUNTIME cannot overwrite the retained SERIAL1_BAUD tuple or timestamp',
      'partial, CRC-bad, and unsupported input do not count',
      'last id/value/count/index/type/sys/comp/seq/ms metadata',
      'fixed POD storage with no heap',
      'same physical D7 byte observed and scheduled',
      'exactly three correlated VCSTAT q/ms lines',
      'schema v6 bounded report with locale-independent pvval'
    )
  }
  $summary | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $summaryPath -Encoding UTF8
  Write-Host "$($summary.result) $testId summary=$summaryPath"
  if (-not $passed) {
    exit 1
  }
}

exit 0
