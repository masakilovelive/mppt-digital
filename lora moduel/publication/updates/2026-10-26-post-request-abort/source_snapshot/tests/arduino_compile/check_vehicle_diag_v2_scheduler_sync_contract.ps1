param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$DiagRoot,
  [string]$Compiler,
  [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$testId = 'FW-VEHICLE-DIAG-SCHED-SYNC-001'
if (-not $OutputDir) {
  $OutputDir = Join-Path $RepoRoot `
    'runs\contracts\FW-VEHICLE-DIAG-SCHED-SYNC-001'
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

function Require-PatternCount {
  param(
    [string]$Text,
    [string]$Pattern,
    [int]$Expected,
    [string]$Description
  )
  $actual = [regex]::Matches($Text, $Pattern).Count
  if ($actual -ne $Expected) {
    Add-Failure "$Description expected $Expected match(es), got $actual"
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
$canonicalHeader = Join-Path $RepoRoot `
  'core\include\vc_lora\mavlink_scheduler.hpp'
$canonicalSource = Join-Path $RepoRoot 'core\src\mavlink_scheduler.cpp'
$packagedHeader = Join-Path $diagRoot 'vc_lora\mavlink_scheduler.hpp'
$packagedSource = Join-Path $diagRoot 'src\mavlink_scheduler.cpp'
$groundDiagRoot = Join-Path $RepoRoot `
  'vc_lora_ground_diag_v2_stable_xiao_esp32s3'
$groundPackagedHeader = Join-Path $groundDiagRoot `
  'vc_lora\mavlink_scheduler.hpp'
$groundPackagedSource = Join-Path $groundDiagRoot 'src\mavlink_scheduler.cpp'
$syncScript = Join-Path $RepoRoot 'tools\sync_arduino_sketch_core.ps1'
$diagAdapter = Join-Path $diagRoot 'vc_lora_phase6_bridge.hpp'
$observerPath = Join-Path $diagRoot 'vc_lora_vehicle_diag_observer.hpp'
$reportPath = Join-Path $diagRoot 'vc_lora_vehicle_diag.hpp'
$hostSource = Join-Path $RepoRoot `
  'tests\host\standalone\vehicle_diag_scheduler_sync_contract_tests.cpp'
$mavlinkSource = Join-Path $RepoRoot 'core\src\mavlink_frame.cpp'
$coreInclude = Join-Path $RepoRoot 'core\include'

$startedUtc = (Get-Date).ToUniversalTime()
$compilerPath = $null
$compileExit = $null
$hostExit = $null
$staticPassed = $false
$hostPassed = $false
$canonicalHeaderSha = $null
$canonicalSourceSha = $null
$packagedHeaderSha = $null
$packagedSourceSha = $null
$groundPackagedHeaderSha = $null
$groundPackagedSourceSha = $null

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$compileLog = Join-Path $OutputDir 'compile.log'
$hostLog = Join-Path $OutputDir 'host.log'
$summaryPath = Join-Path $OutputDir 'summary.json'
$executable = Join-Path $OutputDir `
  'vehicle_diag_scheduler_sync_contract_tests.exe'

try {
  foreach ($path in @($canonicalHeader, $canonicalSource, $packagedHeader,
      $packagedSource, $groundPackagedHeader, $groundPackagedSource,
      $syncScript, $diagAdapter, $observerPath, $reportPath, $hostSource,
      $mavlinkSource)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      Add-Failure "required input is missing: $path"
    }
  }

  if ($errors.Count -eq 0) {
    $canonicalHeaderSha =
      (Get-FileHash -Algorithm SHA256 -LiteralPath $canonicalHeader).Hash
    $canonicalSourceSha =
      (Get-FileHash -Algorithm SHA256 -LiteralPath $canonicalSource).Hash
    $packagedHeaderSha =
      (Get-FileHash -Algorithm SHA256 -LiteralPath $packagedHeader).Hash
    $packagedSourceSha =
      (Get-FileHash -Algorithm SHA256 -LiteralPath $packagedSource).Hash
    $groundPackagedHeaderSha =
      (Get-FileHash -Algorithm SHA256 -LiteralPath $groundPackagedHeader).Hash
    $groundPackagedSourceSha =
      (Get-FileHash -Algorithm SHA256 -LiteralPath $groundPackagedSource).Hash
    if ($canonicalHeaderSha -ne $packagedHeaderSha) {
      Add-Failure 'stable Vehicle scheduler header differs from canonical core'
    }
    if ($canonicalSourceSha -ne $packagedSourceSha) {
      Add-Failure 'stable Vehicle scheduler source differs from canonical core'
    }
    if ($canonicalHeaderSha -ne $groundPackagedHeaderSha) {
      Add-Failure 'stable Ground scheduler header differs from canonical core'
    }
    if ($canonicalSourceSha -ne $groundPackagedSourceSha) {
      Add-Failure 'stable Ground scheduler source differs from canonical core'
    }

    $header = Get-Content -Raw -LiteralPath $packagedHeader
    $source = Get-Content -Raw -LiteralPath $packagedSource
    $adapter = Get-Content -Raw -LiteralPath $diagAdapter
    $observer = Get-Content -Raw -LiteralPath $observerPath
    $report = Get-Content -Raw -LiteralPath $reportPath
    $sync = Get-Content -Raw -LiteralPath $syncScript

    foreach ($stableTarget in @(
        'vc_lora_vehicle_diag_v2_stable_xiao_esp32s3',
        'vc_lora_ground_diag_v2_stable_xiao_esp32s3')) {
      Require-Pattern $sync ([regex]::Escape("'$stableTarget'")) `
        "core sync target $stableTarget"
    }

    Require-Pattern $adapter `
      'remember_vehicle_parameter_requests\s*\([\s\S]{0,240}std::uint64_t\s+now_ms' `
      'timestamped committed-request tracker'
    Require-Pattern $adapter `
      'begin_native_parameter_list\s*\(\s*frame\s*,\s*now_ms\s*\)' `
      'native fence timestamp plumbing'
    Require-Pattern $adapter `
      'vehicle_commit_uplink_transaction\s*\(\s*std::uint64_t\s+now_ms\s*\)' `
      'timestamped uplink transaction commit'
    Require-PatternCount $adapter `
      'vehicle_commit_uplink_transaction\s*\(\s*now_ms\s*\)' 2 `
      'both native/late terminal commit timestamps'

    Require-Pattern $header `
      'parameter_download_frame_capacity\s*\(\s*\)[\s\S]{0,80}return\s+1024U' `
      '1024-frame PARAM_VALUE capacity API'
    Require-Pattern $header `
      'parameter_download_byte_capacity\s*\(\s*\)[\s\S]{0,100}return\s+64U\s*\*\s*1024U' `
      '64-KiB PARAM_VALUE byte capacity API'
    Require-Pattern $header `
      'std::array\s*<\s*std::uint8_t\s*,\s*64U\s*\*\s*1024U\s*>\s+parameter_bytes_' `
      'fixed PARAM_VALUE byte FIFO'
    Require-Pattern $header `
      'std::array\s*<\s*std::uint16_t\s*,\s*1024U\s*>\s+parameter_lengths_' `
      'fixed PARAM_VALUE frame-length FIFO'
    foreach ($field in @(
        'native_list_stat_runtime_frames_cancelled',
        'native_list_stat_runtime_bytes_cancelled',
        'native_list_other_frames_cancelled',
        'native_list_other_bytes_cancelled',
        'native_list_stat_runtime_frames_filtered',
        'native_list_other_frames_filtered',
        'native_list_stat_runtime_first_filter_ms',
        'native_list_stat_runtime_last_filter_ms',
        'native_list_stat_runtime_min_filter_gap_ms',
        'native_list_stat_runtime_filter_time_regressions',
        'native_list_stale_classification_errors',
        'native_list_unexpected_latched',
        'native_list_unexpected_mismatch_mask',
        'native_list_unexpected_value_bits',
        'native_list_unexpected_parameter_id')) {
      Require-Pattern $header ("\b{0}\b" -f [regex]::Escape($field)) `
        "strict native exclusion diagnostic $field"
    }
    foreach ($field in @('parameter_byte_head_', 'parameter_byte_tail_',
        'parameter_byte_count_', 'parameter_frame_head_',
        'parameter_frame_tail_', 'parameter_frame_count_',
        'parameter_active_offset_', 'parameter_active_')) {
      Require-Pattern $header ("\b{0}\b" -f [regex]::Escape($field)) `
        "PARAM_VALUE FIFO state $field"
    }
    Reject-Pattern $header `
      '\b(?:vector|deque|list|string)\s*<|\b(?:malloc|calloc|realloc|free)\b|\bnew\s+' `
      'scheduler dynamic-allocation purity'

    Require-Pattern $header `
      'parameter_request_capacity\s*\(\s*\)[\s\S]{0,80}return\s+8U' `
      'fixed eight-slot PARAM_REQUEST_READ tracker capacity API'
    Require-Pattern $header `
      'target_parameter_capacity\s*\(\s*\)[\s\S]{0,100}return\s+parameter_request_capacity\s*\(\s*\)' `
      'target PARAM_VALUE lane capacity API'
    Require-Pattern $header `
      'std::array\s*<\s*ParameterRequestIdentity\s*,\s*8U\s*>\s+parameter_requests_' `
      'fixed eight-slot request tracker storage'
    Require-Pattern $header `
      'std::array\s*<\s*TargetParameterFrame\s*,\s*8U\s*>\s+target_parameter_frames_' `
      'fixed eight-slot target PARAM_VALUE lane storage'
    Require-Pattern $header `
      'MavlinkParameterRequestStatus\s+remember_parameter_request\s*\(\s*const\s+MavlinkFrame&\s+frame\s*\)' `
      'request identity retention API'
    Require-Pattern $header `
      'prioritized_parameter_values\s*\(\s*\)[\s\S]{0,100}return\s+target_parameter_count_' `
      'target PARAM_VALUE lane depth API'
    Require-Pattern $header `
      'parameter_download_queued_frames\s*\(\s*\)[\s\S]{0,100}return\s+parameter_frame_count_' `
      'generic PARAM_VALUE lane depth API'
    Require-Pattern $header `
      'parameter_download_active\s*\(\s*\)[\s\S]{0,100}return\s+parameter_active_' `
      'generic PARAM_VALUE active-frame API'
    Require-Pattern $header `
      'bool\s+heartbeat_tail_available\s*\(\s*\)\s*const\s+noexcept' `
      'target-aware heartbeat tail API'
    Require-Pattern $header `
      'MavlinkHeartbeatCandidate\s+heartbeat_candidate\s*\(\s*\)\s*const\s+noexcept' `
      'coherent heartbeat identity/enqueue-time API'

    $enqueueImplStart = $source.IndexOf(
      'MavlinkEnqueueStatus MavlinkFrameScheduler::enqueue_impl(')
    $enqueueImplEnd = if ($enqueueImplStart -ge 0) {
      $source.IndexOf(
        'MavlinkEnqueueStatus MavlinkFrameScheduler::enqueue(',
        $enqueueImplStart + 1)
    } else { -1 }
    $normalRouteMarker =
      '  const Priority priority = priority_for(decoded.message_id);'
    $normalRoute = if ($enqueueImplStart -ge 0) {
      $source.IndexOf($normalRouteMarker, $enqueueImplStart)
    } else { -1 }
    if ($enqueueImplStart -lt 0 -or $enqueueImplEnd -le $enqueueImplStart -or
        $normalRoute -le $enqueueImplStart -or $normalRoute -ge $enqueueImplEnd) {
      Add-Failure 'could not isolate enqueue_impl #22 route before normal priority'
      $enqueueImpl = ''
      $msg22Slice = ''
      $outsideMsg22Slice = ''
    } else {
      $enqueueImpl = $source.Substring(
        $enqueueImplStart, $enqueueImplEnd - $enqueueImplStart)
      $relativeNormalRoute = $normalRoute - $enqueueImplStart
      $msg22Match = [regex]::Match(
        $enqueueImpl,
        'if\s*\(\s*decoded\.message_id\s*==\s*22U\s*\)\s*\{')
      if (-not $msg22Match.Success -or
          $msg22Match.Index -ge $relativeNormalRoute) {
        Add-Failure 'could not isolate the #22 branch inside enqueue_impl'
        $msg22Slice = ''
        $outsideMsg22Slice = $enqueueImpl
      } else {
        $msg22Slice = $enqueueImpl.Substring(
          $msg22Match.Index, $relativeNormalRoute - $msg22Match.Index)
        $outsideMsg22Slice =
          $enqueueImpl.Substring(0, $msg22Match.Index) +
          $enqueueImpl.Substring($relativeNormalRoute)
      }
    }
    Require-PatternCount $enqueueImpl `
      'if\s*\(\s*decoded\.message_id\s*==\s*22U\s*\)\s*\{' 1 `
      'unique enqueue_impl #22 branch'
    Require-PatternCount $msg22Slice `
      'return\s+enqueue_target_parameter_value\s*\(\s*decoded\s*,\s*pending_request\s*\)\s*;' 1 `
      'unique matching-response target-lane return'
    Require-PatternCount $msg22Slice `
      'return\s+enqueue_parameter_value\s*\(\s*decoded\s*\)\s*;' 1 `
      'unique unmatched-response generic FIFO fallback'
    Require-Pattern $msg22Slice `
      'const\s+std::size_t\s+pending_request\s*=\s*find_parameter_request\s*\(\s*decoded\s*,\s*ParameterRequestState::Pending\s*\)\s*;[\s\S]{0,220}if\s*\(\s*pending_request\s*<\s*parameter_request_capacity\s*\(\s*\)\s*\)\s*\{\s*return\s+enqueue_target_parameter_value\s*\(\s*decoded\s*,\s*pending_request\s*\)\s*;' `
      'Pending request match precedes target-lane enqueue'
    Require-Pattern $msg22Slice `
      'return\s+enqueue_target_parameter_value[\s\S]{0,420}const\s+std::size_t\s+queued_request\s*=\s*find_parameter_request\s*\(\s*decoded\s*,\s*ParameterRequestState::ResponseQueued\s*\)\s*;[\s\S]{0,220}if\s*\(\s*queued_request\s*<\s*parameter_request_capacity\s*\(\s*\)\s*\)\s*\{[\s\S]{0,260}target_parameter_duplicate_frames[\s\S]{0,180}policy_filtered_frames[\s\S]{0,180}policy_filtered_bytes[\s\S]{0,180}return\s+MavlinkEnqueueStatus::Filtered\s*;' `
      'queued target duplicate is diagnosed and filtered'
    Require-Pattern ($msg22Slice.TrimEnd()) `
      'return\s+MavlinkEnqueueStatus::Filtered\s*;\s*\}[\s\S]{0,900}(?:return\s+enqueue_native_parameter_value\s*\(\s*decoded\s*\)\s*;[\s\S]{0,160})?return\s+enqueue_parameter_value\s*\(\s*decoded\s*\)\s*;\s*\}$' `
      'unmatched #22 uses native stream when fenced, otherwise generic fallback'
    Reject-Pattern $outsideMsg22Slice `
      'return\s+enqueue_target_parameter_value\s*\(' `
      'target PARAM_VALUE routing outside the unique #22 branch'
    Reject-Pattern $outsideMsg22Slice `
      'return\s+enqueue_parameter_value\s*\(\s*decoded\s*\)' `
      'generic PARAM_VALUE routing outside the unique #22 branch'

    Require-Pattern $source `
      'heartbeat_tail_available\s*\(\s*\)\s*const\s+noexcept\s*\{\s*if\s*\(\s*!has_pending_heartbeat\s*\(\s*\)\s*\)\s*\{\s*return\s+false\s*;\s*\}\s*if\s*\(\s*target_parameter_count_\s*==\s*0U\s*\|\|\s*target_parameter_active_\s*\)\s*\{\s*return\s+true\s*;\s*\}\s*return\s+!target_heartbeat_yielded_\s*;\s*\}' `
      'heartbeat tail yields at most once before a waiting target response'
    Require-Pattern $adapter `
      'vehicle_scheduler\.heartbeat_candidate\s*\(\s*\)[\s\S]{0,260}input\.heartbeat_tail_available\s*=\s*heartbeat\.tail_available\s*;' `
      'diagnostic adapter uses coherent target-aware heartbeat candidate'
    Require-Pattern $adapter `
      'input\.heartbeat_deadline_valid\s*=\s*true[\s\S]{0,500}input\.heartbeat_order\s*=\s*heartbeat\.order[\s\S]{0,500}input\.heartbeat_enqueued_ms\s*=\s*heartbeat\.enqueued_ms[\s\S]{0,900}input\.heartbeat_deadline_ms\s*=' `
      'diagnostic adapter binds heartbeat identity and absolute deadline'
    Reject-Pattern $adapter `
      'input\.heartbeat_tail_available\s*=\s*vehicle_scheduler\.has_pending_heartbeat\s*\(\s*\)\s*;' `
      'diagnostic adapter direct pending-heartbeat bypass'
    Require-Pattern $source `
      'enqueue_parameter_value[\s\S]{0,900}parameter_bytes_\s*\[[^\]]*parameter_byte_tail_[^\]]*\][\s\S]{0,500}parameter_lengths_\s*\[[^\]]*parameter_frame_tail_[^\]]*\]' `
      'encoded-frame FIFO append order'
    Require-Pattern $source `
      'parameter_frame_count_\s*>=\s*parameter_lengths_\.size\s*\(\s*\)[\s\S]{0,160}parameter_bytes_\.size\s*\(\s*\)\s*-\s*parameter_byte_count_' `
      'frame and byte capacity fail-closed checks'
    Require-Pattern $source `
      'parameter_value_precedes[\s\S]{0,420}Priority::Heartbeat[\s\S]{0,80}return\s+false' `
      'heartbeat precedence over pending PARAM_VALUE'
    Require-Pattern $source `
      'if\s*\(\s*parameter_active_\s*\)[\s\S]{0,500}parameter_byte_head_[\s\S]{0,300}parameter_frame_head_' `
      'active PARAM_VALUE FIFO dequeue and frame completion'
    Require-Pattern $source `
      'parameter_bytes_\s*=\s*\{\}[\s\S]{0,120}parameter_lengths_\s*=\s*\{\}' `
      'PARAM_VALUE FIFO reset clearing'
    Require-Pattern $source `
      'is_exact_stat_runtime[\s\S]*MavlinkVersion::V2[\s\S]*signed_frame[\s\S]*message_id[\s\S]*22U[\s\S]*payload_length[\s\S]*25U[\s\S]*system_id[\s\S]*1U[\s\S]*component_id[\s\S]*1U[\s\S]*STAT_RUNTIME' `
      'exact STAT_RUNTIME full-tuple classifier'
    Require-Pattern $source `
      'native_list_stat_runtime_frames_cancelled[\s\S]*native_list_other_frames_cancelled[\s\S]*native_list_unexpected' `
      'complete native-fence cancellation classification'
    Require-Pattern $source `
      'record_native_list_filtered[\s\S]*native_list_stat_runtime_frames_filtered' `
      'exact STAT_RUNTIME post-fence classification'
    Require-Pattern $source `
      'record_native_list_filtered[\s\S]*native_list_other_frames_filtered' `
      'non-STAT_RUNTIME post-fence classification'
    foreach ($field in @(
        'native_list_stat_runtime_first_filter_ms',
        'native_list_stat_runtime_last_filter_ms',
        'native_list_stat_runtime_min_filter_gap_ms',
        'native_list_stat_runtime_filter_time_regressions')) {
      Require-Pattern $source `
        ("record_native_list_filtered[\s\S]*\b{0}\b" -f
          [regex]::Escape($field)) `
        "exact STAT_RUNTIME post-fence cadence evidence $field"
    }
    Require-Pattern $adapter `
      'bool\s+remember_vehicle_parameter_requests\s*\([\s\S]{0,260}std::uint16_t\s+expected_frames\s*,\s*std::uint64_t\s+now_ms\s*\)\s*noexcept[\s\S]{0,900}begin_native_parameter_list\s*\(\s*frame\s*,\s*now_ms\s*\)' `
      'native fence receives the immutable transaction timestamp'
    Require-Pattern $adapter `
      'bool\s+vehicle_commit_uplink_transaction\s*\(\s*std::uint64_t\s+now_ms\s*\)\s*noexcept[\s\S]{0,4000}remember_vehicle_parameter_requests\s*\([\s\S]{0,220}committed_frames\s*,\s*now_ms\s*\)' `
      'Vehicle commit propagates now_ms to native exclusion diagnostics'
    Require-PatternCount $adapter `
      'vehicle_commit_uplink_transaction\s*\(\s*now_ms\s*\)' 2 `
      'normal/late terminal timestamp propagation'

    # Scheduler synchronization must not discard the diagnostic observer used
    # to identify the exact Pixhawk response.
    Require-Pattern $observer 'struct\s+D7ParamValueStats\s*\{' `
      'D7 PARAM_VALUE diagnostic observer retention'
    Require-Pattern $observer '\bserial1_baud_exact\b' `
      'exact SERIAL1_BAUD diagnostic counter retention'
    Require-Pattern $observer '\bobserve_d7_param_value\s*\(' `
      'D7 PARAM_VALUE decoder retention'
    Require-Pattern $report 'VCSTAT1[^"\r\n]*\bv=6\b' `
      'diagnostic schema v6 retention'
    foreach ($key in @('pvok', 'pvs1', 'pvid', 'pvval', 'pvcnt', 'pvidx',
        'pvtype', 'pvseq', 'pvsys', 'pvcomp', 'pvms', 'pvbad', 'pvov')) {
      Require-Pattern $report ("\b{0}=%" -f $key) `
        "VCSTAT3 observer key $key retention"
    }
    foreach ($key in @('sqf', 'sqb', 'sact', 'pgq', 'pga', 'prq', 'ptq',
        'hbp', 'hbta', 'hbac', 'hbpr', 'hbseen', 'hgd', 'hdm', 'squeued', 'sdropf',
        'sdropb', 'srej', 'sncsf', 'sncsb', 'sncof', 'sncob', 'snfsf',
        'snfof', 'snffm', 'snflm', 'snfmg', 'snftr', 'snul', 'snur',
        'sncerr', 'snuv', 'snusg', 'snusz', 'snup', 'snusy', 'snucp',
        'snusq', 'snumask', 'snuval', 'snui', 'snuc', 'snut', 'snums',
        'snuid', 'smaxf', 'smaxb')) {
      Require-Pattern $report ("\b{0}=%" -f $key) `
        "VCSTAT3 scheduler state/diagnostic key $key"
    }
    $staticPassed = $errors.Count -eq 0
  }

  try {
    $compilerPath = Find-Compiler $Compiler
    $compile = Invoke-NativeCapture $compilerPath @(
      '-std=c++17', '-Wall', '-Wextra', '-Wpedantic', '-Wconversion',
      "-I$diagRoot", "-I$coreInclude", $hostSource, $packagedSource,
      $mavlinkSource, '-static', '-o', $executable
    )
    $compileExit = $compile.ExitCode
    $compile.Output -join [Environment]::NewLine |
      Set-Content -LiteralPath $compileLog -Encoding UTF8
    if ($compile.ExitCode -ne 0) {
      Add-Failure "host scheduler contract compile failed (exit $($compile.ExitCode))"
    } else {
      $hostRun = Invoke-NativeCapture $executable @()
      $hostExit = $hostRun.ExitCode
      $hostRun.Output -join [Environment]::NewLine |
        Set-Content -LiteralPath $hostLog -Encoding UTF8
      if ($hostRun.ExitCode -ne 0) {
        Add-Failure "host scheduler contract failed (exit $($hostRun.ExitCode))"
      } else {
        $hostPassed = $true
      }
    }
  } catch {
    Add-Failure "host scheduler infrastructure failed: $($_.Exception.Message)"
  }
} catch {
  Add-Failure "unexpected scheduler contract failure: $($_.Exception.Message)"
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
    compile_exit_code = $compileExit
    host_exit_code = $hostExit
    canonical_header_sha256 = $canonicalHeaderSha
    packaged_header_sha256 = $packagedHeaderSha
    canonical_source_sha256 = $canonicalSourceSha
    packaged_source_sha256 = $packagedSourceSha
    ground_packaged_header_sha256 = $groundPackagedHeaderSha
    ground_packaged_source_sha256 = $groundPackagedSourceSha
    errors = @($errors)
    compile_log = $compileLog
    host_log = $hostLog
    requirements = @(
      'both stable diagnostic scheduler hpp/cpp copies have byte parity with canonical core',
      'core synchronization script includes both stable diagnostic sketches',
      'fixed eight-slot request tracker and equal target PARAM_VALUE lane',
      'matching #22 uses one target-lane route; queued duplicates are filtered; unmatched #22 uses one generic FIFO fallback',
      'target-aware heartbeat tail yields at most once before a waiting target response',
      'fixed 1024-frame and 64-KiB PARAM_VALUE FIFO',
      'strict FIFO order across ring wrap and fail-closed overflow',
      'heartbeat precedes pending PARAM_VALUE',
      'active PARAM_VALUE is never split by a later heartbeat',
      'PARAM_VALUE precedes normal display telemetry',
      'all native exclusions classified as exact STAT_RUNTIME or latched other',
      'exact STAT_RUNTIME filter cadence retained without dynamic memory',
      'diagnostic schema v6 and PARAM_VALUE observer keys retained'
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
