param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$testId = 'FW-V2-STAGE-DIAG-LATEST-001'
if (-not $OutputDir) {
  $OutputDir = Join-Path $RepoRoot "runs\contracts\$testId"
}
$errors = [Collections.Generic.List[string]]::new()

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

function Get-FunctionBody([string]$Text, [string]$SignaturePattern) {
  $match = [regex]::Match($Text, $SignaturePattern)
  if (-not $match.Success) { return $null }
  $open = $Text.IndexOf('{', $match.Index + $match.Length)
  if ($open -lt 0) { return $null }
  $depth = 0
  for ($index = $open; $index -lt $Text.Length; ++$index) {
    if ($Text[$index] -eq '{') { ++$depth }
    elseif ($Text[$index] -eq '}') {
      --$depth
      if ($depth -eq 0) {
        return $Text.Substring($open + 1, $index - $open - 1)
      }
    }
  }
  return $null
}

function Get-GroundConservativeMaximumReportBytes([string]$Text) {
  $body = Get-FunctionBody $Text `
    'inline\s+void\s+format_report\s*\(\s*const\s+Snapshot&\s+s\s*\)\s*noexcept'
  if ($null -eq $body) { return $null }
  $formats = @([regex]::Matches(
      $body,
      'std::snprintf\(\s*[^,]+,\s*[^,]+,\s*' +
        '(?<literals>(?:"(?:[^"\\]|\\.)*"\s*)+),'))
  if ($formats.Count -ne 4) { return $null }
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
  if ($maximum -match '%(?:08lX|llu|lu|u|d|s)') { return $null }
  return [Text.Encoding]::ASCII.GetByteCount($maximum)
}

function Test-SnprintfFormatArity([string]$Text, [string]$Description) {
  $calls = @([regex]::Matches(
      $Text, 'std::snprintf\((?<call>[\s\S]*?)\);'))
  if ($calls.Count -eq 0) {
    Add-Failure "$Description has no bounded snprintf calls"
    return
  }
  for ($callIndex = 0; $callIndex -lt $calls.Count; ++$callIndex) {
    $call = $calls[$callIndex].Groups['call'].Value
    $specifierCount = 0
    foreach ($literal in [regex]::Matches(
        $call, '"(?<body>(?:[^"\\]|\\.)*)"')) {
      $specifierCount += [regex]::Matches(
          $literal.Groups['body'].Value, '(?<!%)%(?!%)').Count
    }

    $topLevelCommas = 0
    $parenDepth = 0
    $bracketDepth = 0
    $braceDepth = 0
    $inString = $false
    $inChar = $false
    $escaped = $false
    for ($index = 0; $index -lt $call.Length; ++$index) {
      $character = $call[$index]
      if ($escaped) {
        $escaped = $false
        continue
      }
      if (($inString -or $inChar) -and $character -eq '\') {
        $escaped = $true
        continue
      }
      if (-not $inChar -and $character -eq '"') {
        $inString = -not $inString
        continue
      }
      if (-not $inString -and $character -eq "'") {
        $inChar = -not $inChar
        continue
      }
      if ($inString -or $inChar) { continue }
      switch ($character) {
        '(' { ++$parenDepth }
        ')' { --$parenDepth }
        '[' { ++$bracketDepth }
        ']' { --$bracketDepth }
        '{' { ++$braceDepth }
        '}' { --$braceDepth }
        ',' {
          if ($parenDepth -eq 0 -and $bracketDepth -eq 0 -and
              $braceDepth -eq 0) {
            ++$topLevelCommas
          }
        }
      }
    }
    $valueArgumentCount = ($topLevelCommas + 1) - 3
    if ($specifierCount -ne $valueArgumentCount) {
      Add-Failure (
        "$Description snprintf[$callIndex] format arity mismatch: " +
        "$specifierCount specifiers, $valueArgumentCount values")
    }
  }
}

function Normalize-DiagnosticBridge([string]$Path) {
  $output = [Collections.Generic.List[string]]::new()
  $inDiagnostic = $false
  $depth = 0
  $keepElse = $false
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    if (-not $inDiagnostic) {
      if ($line -match ('^\s*#if\s+defined\(' +
          '(?:VC_LORA_PHASE6_(?:VEHICLE|GROUND)_DIAGNOSTICS|' +
          'VC_LORA_HIL_DROP_NATIVE_PARAM_INDEX_930)\)')) {
        $inDiagnostic = $true
        $depth = 1
        $keepElse = $false
      } else {
        $output.Add($line)
      }
      continue
    }
    if ($line -match '^\s*#if(?:def|ndef)?\b') {
      ++$depth
      if ($keepElse) { $output.Add($line) }
      continue
    }
    if ($line -match '^\s*#endif\b') {
      --$depth
      if ($depth -eq 0) {
        $inDiagnostic = $false
        $keepElse = $false
      } elseif ($keepElse) {
        $output.Add($line)
      }
      continue
    }
    if ($depth -eq 1 -and $line -match '^\s*#else\b') {
      $keepElse = $true
      continue
    }
    if ($keepElse) { $output.Add($line) }
  }
  if ($inDiagnostic -or $depth -ne 0) {
    throw "unterminated diagnostic preprocessor block in $Path"
  }
  # Removing a diagnostics-only preprocessor block may leave one extra blank
  # separator. Blank-line count is not executable adapter drift.
  return @($output | Where-Object { $_.Trim().Length -gt 0 }) -join "`n"
}

function Invoke-Native([string]$FilePath, [string[]]$Arguments) {
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldPreference
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = @($output | ForEach-Object ToString)
  }
}

$vehicleRoot = Join-Path $RepoRoot 'vc_lora_vehicle_diag_v2_stable_xiao_esp32s3'
$groundRoot = Join-Path $RepoRoot 'vc_lora_ground_diag_v2_stable_xiao_esp32s3'
$canonicalBridge = Join-Path $RepoRoot 'firmware\phase6\vc_lora_phase6_bridge.hpp'
$vehicleBridge = Join-Path $vehicleRoot 'vc_lora_phase6_bridge.hpp'
$groundBridge = Join-Path $groundRoot 'vc_lora_phase6_bridge.hpp'
$vehicleIno = Join-Path $vehicleRoot 'vc_lora_vehicle_diag_v2_stable_xiao_esp32s3.ino'
$vehicleReport = Join-Path $vehicleRoot 'vc_lora_vehicle_diag.hpp'
$vehicleObserver = Join-Path $vehicleRoot 'vc_lora_vehicle_diag_observer.hpp'
$groundReport = Join-Path $groundRoot 'vc_lora_ground_diag.hpp'
$groundObserver = Join-Path $groundRoot 'vc_lora_ground_diag_observer.hpp'
$groundHostTest = Join-Path $RepoRoot `
  'tests\host\standalone\ground_diag_query_observer_contract_tests.cpp'
$groundQueryTool = Join-Path $RepoRoot 'tools\ground_diag_query.ps1'
$continuousRunner = Join-Path $RepoRoot `
  'tools\run_dual_diag_continuous_hil.ps1'
$vehicleDiagnosticReadme = Join-Path $vehicleRoot 'README_DIAGNOSTIC.md'
$groundDiagnosticReadme = Join-Path $groundRoot 'README_DIAGNOSTIC.md'
$canonicalHostPresenceFilter = Join-Path $RepoRoot `
  'core\include\vc_lora\ground_usb_host_presence_filter.hpp'
$canonicalGroundProxy = Join-Path $RepoRoot `
  'core\include\vc_lora\ground_parameter_download_proxy.hpp'

$startedUtc = (Get-Date).ToUniversalTime()
$groundRuntimeLatchCount = 0
$groundRuntimeReasonCoverageCount = 0
$groundMaximumReportBytes = $null
$groundReportHeadroomBytes = $null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

try {
  foreach ($path in @($canonicalBridge, $vehicleBridge, $groundBridge,
      $vehicleIno, $vehicleReport, $vehicleObserver, $groundReport,
      $groundObserver, $groundHostTest, $continuousRunner,
      $vehicleDiagnosticReadme, $groundDiagnosticReadme,
      $canonicalHostPresenceFilter, $canonicalGroundProxy)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      Add-Failure "missing required source: $path"
    }
  }

  $canonicalHeaders = @(Get-ChildItem -LiteralPath `
      (Join-Path $RepoRoot 'core\include\vc_lora') -File)
  $canonicalSources = @(Get-ChildItem -LiteralPath `
      (Join-Path $RepoRoot 'core\src') -File)
  foreach ($role in @($vehicleRoot, $groundRoot)) {
    $packagedHeaders = @(Get-ChildItem -LiteralPath `
        (Join-Path $role 'vc_lora') -File)
    $packagedSources = @(Get-ChildItem -LiteralPath `
        (Join-Path $role 'src') -File)
    foreach ($set in @(
        @($canonicalHeaders.Name | Sort-Object),
        @($canonicalSources.Name | Sort-Object))) {
      $packagedSet = if ($set[0] -like '*.hpp') {
        @($packagedHeaders.Name | Sort-Object)
      } else {
        @($packagedSources.Name | Sort-Object)
      }
      $delta = @(Compare-Object $set $packagedSet)
      if ($delta.Count -ne 0) {
        Add-Failure "canonical basename set mismatch in $role`: $($delta | Out-String)"
      }
    }
    foreach ($canonical in @($canonicalHeaders) + @($canonicalSources)) {
      $subdir = if ($canonical.Extension -eq '.hpp') { 'vc_lora' } else { 'src' }
      $packaged = Join-Path (Join-Path $role $subdir) $canonical.Name
      if (-not (Test-Path -LiteralPath $packaged -PathType Leaf)) {
        Add-Failure "canonical core file missing from $role`: $subdir\$($canonical.Name)"
        continue
      }
      $canonicalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $canonical.FullName).Hash
      $packagedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packaged).Hash
      if ($canonicalHash -ne $packagedHash) {
        Add-Failure "canonical core parity mismatch in $role`: $subdir\$($canonical.Name)"
      }
    }
  }

  if ($errors.Count -eq 0 -or
      ((Test-Path $vehicleBridge) -and (Test-Path $groundBridge))) {
    $canonical = Get-Content -Raw -LiteralPath $canonicalBridge
    $vehicle = Get-Content -Raw -LiteralPath $vehicleBridge
    $ground = Get-Content -Raw -LiteralPath $groundBridge
    $vehicleInoText = Get-Content -Raw -LiteralPath $vehicleIno
    $vehicleReportText = Get-Content -Raw -LiteralPath $vehicleReport
    $vehicleObserverText = Get-Content -Raw -LiteralPath $vehicleObserver
    $groundReportText = Get-Content -Raw -LiteralPath $groundReport
    $groundObserverText = Get-Content -Raw -LiteralPath $groundObserver
    $canonicalGroundProxyText = Get-Content -Raw `
        -LiteralPath $canonicalGroundProxy
    $groundHostTestText = Get-Content -Raw -LiteralPath $groundHostTest
    $continuousRunnerText = Get-Content -Raw -LiteralPath $continuousRunner
    Test-SnprintfFormatArity $groundReportText 'Ground diagnostic report'
    Test-SnprintfFormatArity $vehicleReportText 'Vehicle diagnostic report'
    $vehicleDiagnosticReadmeText = Get-Content -Raw `
        -LiteralPath $vehicleDiagnosticReadme
    $groundDiagnosticReadmeText = Get-Content -Raw `
        -LiteralPath $groundDiagnosticReadme

    foreach ($entry in @(
        @('ground_parameter_download_proxy\.hpp', 'Ground proxy include'),
        @('service_ground_parameter_proxy\s*\(', 'Ground proxy service'),
        @('ground_proxy_request_dequeue_goal', 'descriptor dequeue stage'),
        @('ground_proxy_request_done_goal', 'explicit UL_DONE stage'),
        @('input\.front_frame_bytes\s*=\s*ground_ingress\.front_frame_remaining\s*\(\s*\)', 'front-frame boundary'),
        @('ground_ingress\.front_frame_wire_bytes\s*\(\s*\)', 'whole-frame wire budget'),
        @('service_pixhawk_link_heartbeat\s*\(', 'canonical Vehicle heartbeat'))) {
      Require-Pattern $canonical $entry[0] "canonical $($entry[1])"
      Require-Pattern $vehicle $entry[0] "Vehicle diagnostic $($entry[1])"
      Require-Pattern $ground $entry[0] "Ground diagnostic $($entry[1])"
    }
    foreach ($bridge in @($vehicle, $ground)) {
      Require-Pattern $bridge 'kTddProtocolVersion\s*==\s*2U' 'explicit-DONE v2 pin'
      if ($bridge -match 'kTddProtocolVersion\s*==\s*3U') {
        Add-Failure 'diagnostic bridge contains a v3 transport pin'
      }
    }
    $canonicalNormalized = Normalize-DiagnosticBridge $canonicalBridge
    if ((Normalize-DiagnosticBridge $vehicleBridge) -cne $canonicalNormalized) {
      Add-Failure 'Vehicle adapter contains non-diagnostic drift from canonical'
    }
    if ((Normalize-DiagnosticBridge $groundBridge) -cne $canonicalNormalized) {
      Add-Failure 'Ground adapter contains non-diagnostic drift from canonical'
    }

    foreach ($bridgeEntry in @(
        @($vehicle, 'Vehicle diagnostic'),
        @($ground, 'Ground diagnostic'))) {
      $replayBody = Get-FunctionBody $bridgeEntry[0] `
        'bool\s+replay_ground_usb_ordered_backlog\s*\('
      if ($null -eq $replayBody) {
        Add-Failure "$($bridgeEntry[1]) ordered-backlog replay body was not found"
        continue
      }
      $preclassifyIndex = $replayBody.IndexOf(
          'ground_parameter_proxy.preclassify_vehicle_frame')
      $consumedIndex = $replayBody.IndexOf(
          'GroundParameterProxyDisposition::Consumed')
      $invalidIndex = $replayBody.IndexOf(
          'GroundParameterProxyDisposition::Invalid')
      $admissionIndex = $replayBody.IndexOf(
          'radio_application_endpoint.admit_validated_frame')
      if ($preclassifyIndex -lt 0 -or $consumedIndex -le $preclassifyIndex -or
          $invalidIndex -le $consumedIndex -or
          $admissionIndex -le $invalidIndex) {
        Add-Failure (
          "$($bridgeEntry[1]) backlog replay does not revalidate before " +
          'Consumed/Invalid handling and irreversible USB admission')
      }
      Require-Pattern $replayBody `
        'replay_preclassification[\s\S]{0,220}GroundParameterProxyDisposition::Consumed[\s\S]{0,500}ground_usb_ordered_backlog\.discard_front\s*\(\s*\)[\s\S]{0,700}continue\s*;' `
        "$($bridgeEntry[1]) backlog replay consumes and discards stale frames"
      Require-Pattern $replayBody `
        'replay_preclassification[\s\S]{0,900}GroundParameterProxyDisposition::Invalid[\s\S]{0,500}ground_usb_ordered_backlog\.discard_front\s*\(\s*\)[\s\S]{0,500}\+\+link_diagnostics\.mavlink_crc_errors[\s\S]{0,700}latch_runtime_fail_closed\s*\(\s*\)[\s\S]{0,120}return\s+false\s*;' `
        "$($bridgeEntry[1]) backlog replay fails closed on invalid revalidation"
    }
    $groundReplayBody = Get-FunctionBody $ground `
      'bool\s+replay_ground_usb_ordered_backlog\s*\('
    if ($null -ne $groundReplayBody) {
      Require-Pattern $groundReplayBody `
        'GroundParameterProxyDisposition::Consumed[\s\S]{0,1000}observe_ground_ordered_backlog_removed\s*\(\s*frame\s*\)[\s\S]{0,400}GroundDownlinkDisposition::[\s\S]{0,80}ProxyConsumed' `
        'Ground diagnostic backlog Consumed occupancy/disposition observers'
      Require-Pattern $groundReplayBody `
        'GroundParameterProxyDisposition::Invalid[\s\S]{0,1000}observe_ground_ordered_backlog_removed\s*\(\s*frame\s*\)[\s\S]{0,400}GroundDownlinkDisposition::Invalid' `
        'Ground diagnostic backlog Invalid occupancy/disposition observers'
    }

    foreach ($entry in @(
        @('observe_pixhawk_write\s*\(', 'D6 accepted observer hook'),
        @('observe_pixhawk_read\s*\(', 'D7 observer hook'),
        @('observe_uplink_ingest\s*\(', 'RF application observer hook'),
        @('observe_uplink_terminal\s*\(', 'explicit terminal observer hook'),
        @('observe_uplink_commit\s*\(', 'atomic commit observer hook'))) {
      Require-Pattern $vehicle $entry[0] $entry[1]
    }
    foreach ($entry in @(
        @('route_usb_byte\s*\(', 'query-safe Ground USB observer hook'),
        @('observe_usb_frame\s*\(', 'CRC-valid Ground USB frame hook'),
        @('observe_usb_connection\s*\(', 'sticky HWCDC predicate observer hook'),
        @('observe_usb_host_presence\s*\(', 'USB SOF host-presence observer hook'),
        @('observe_usb_egress_pump\s*\(', 'USB queued/committed pump observer hook'),
        @('observe_ground_validated_frame\s*\(', 'RF-valid Ground frame observer hook'),
        @('observe_ground_downlink\s*\(', 'Ground downlink disposition observer hook'),
        @('observe_target_egress_admission\s*\(', 'target #22 egress-goal observer hook'),
        @('observe_radio_result\s*\(', 'E220 DATA/DONE completion observer hook'),
        @('observe_proxy_watchdog\s*\(', 'parameter watchdog reason observer hook'),
        @('observe_runtime_fail_closed\s*\(', 'runtime-stop first-cause observer hook'),
        @('collect_ground_fail_closed_query\s*\(', 'stopped-state Ground query collector'),
        @('consume_fail_closed_usb_byte\s*\(', 'isolated stopped-state query matcher'),
        @('observe_action_issued\s*\(', 'Ground DATA/DONE action hook'),
        @('observe_ground_controller\s*\(', 'Ground state observer hook'))) {
      Require-Pattern $ground $entry[0] $entry[1]
    }
    foreach ($entry in @(
        @('observe_ground_primary_heartbeat_rf\s*\(', 'RF primary-heartbeat gap hook'),
        @('observe_ground_primary_heartbeat_usb_commit\s*\(', 'USB physical-commit heartbeat gap hook'),
        @('capture_ground_heartbeat_runtime_context\s*\(', 'event-time heartbeat runtime context'))) {
      Require-Pattern $ground $entry[0] $entry[1]
    }
    $groundValidatedHandler = Get-FunctionBody $ground `
      'void\s+handle_ground_validated_frame\s*\('
    if ($null -eq $groundValidatedHandler) {
      Add-Failure 'Ground validated-frame handler body was not found'
    } else {
      $validatedHookIndex = $groundValidatedHandler.IndexOf(
          'observe_ground_validated_frame')
      $rfHeartbeatHookIndex = $groundValidatedHandler.IndexOf(
          'observe_ground_primary_heartbeat_rf')
      $connectionUpdateIndex = $groundValidatedHandler.IndexOf(
          'update_ground_usb_connection')
      $usbGateIndex = $groundValidatedHandler.IndexOf(
          'ground_usb_can_accept_downlink')
      if ($validatedHookIndex -lt 0 -or $rfHeartbeatHookIndex -lt 0 -or
          $connectionUpdateIndex -lt 0 -or $usbGateIndex -lt 0 -or
          $rfHeartbeatHookIndex -le $validatedHookIndex -or
          $rfHeartbeatHookIndex -ge $connectionUpdateIndex -or
          $rfHeartbeatHookIndex -ge $usbGateIndex) {
        Add-Failure (
          'Ground RF-primary heartbeat hook is not at CRC-valid RF ingress ' +
          'before USB connection/update/rejection')
      }
    }
    Require-Pattern $groundHostTestText `
      'USB-disconnected RF heartbeat supply was not latched independently' `
      'Ground disconnected RF-heartbeat supply/USB separation semantic test'
    foreach ($bridgeEntry in @(
        @($canonical, 'canonical'), @($vehicle, 'Vehicle diagnostic'),
        @($ground, 'Ground diagnostic'))) {
      Require-Pattern $bridgeEntry[0] `
        '#include\s+<vc_lora/ground_usb_host_presence_filter\.hpp>' `
        "$($bridgeEntry[1]) confirmed USB host-presence filter include"
      Require-Pattern $bridgeEntry[0] `
        'kGroundUsbHostLossConfirmMs\s*=\s*50U[\s\S]{0,220}GroundUsbHostPresenceFilterConfig\s*\{\s*kGroundUsbHostLossConfirmMs\s*\}' `
        "$($bridgeEntry[1]) exact 50-ms USB host-loss confirmation"
      Require-Pattern $bridgeEntry[0] `
        'static_assert\s*\(\s*kGroundUsbHostLossConfirmMs\s*>\s*0U\s*,[\s\S]{0,120}Ground USB host-loss confirmation must be positive' `
        "$($bridgeEntry[1]) positive USB host-loss confirmation bound"
      Require-Pattern $bridgeEntry[0] `
        'ground_usb_host_present_now\s*\(\s*\)[\s\S]{0,150}Serial\.isPlugged\s*\(\s*\)' `
        "$($bridgeEntry[1]) USB host-presence sampler"
      Require-Pattern $bridgeEntry[0] `
        'ground_usb_endpoint_ready_now\s*\(\s*bool\s+host_present\s*\)[\s\S]{0,180}host_present\s*&&\s*static_cast<bool>\s*\(\s*Serial\s*\)' `
        "$($bridgeEntry[1]) USB endpoint-ready sampler"
      Require-Pattern $bridgeEntry[0] `
        'update_ground_usb_connection\s*\(\s*std::uint64_t\s+now_ms\s*\)\s*noexcept\s*\{[\s\S]{0,300}raw_host_present\s*=\s*ground_usb_host_present_now\s*\(\s*\)[\s\S]{0,250}ground_usb_endpoint_ready_now\s*\(\s*raw_host_present\s*\)[\s\S]{0,600}ground_usb_host_presence_filter\.observe\s*\(\s*raw_host_present\s*,\s*now_ms\s*\)[\s\S]{0,250}ground_usb_host_presence_filter\.confirmed_present\s*\(\s*\)[\s\S]{0,500}ConfirmedConnected[\s\S]{0,180}ConfirmedDisconnected[\s\S]{0,300}return\s*;[\s\S]{0,180}set_usb_connected\s*\(\s*host_present\s*,\s*now_ms\s*\)' `
        "$($bridgeEntry[1]) raw-stop/confirmed-loss USB split"
      Require-Pattern $bridgeEntry[0] `
        'raw_host_present\s*=\s*ground_usb_host_present_now\s*\(\s*\)[\s\S]{0,180}ground_usb_host_presence_filter\.reset\s*\(\s*raw_host_present\s*,\s*now_ms\s*\)[\s\S]{0,180}ground_usb_host_presence_filter\.confirmed_present\s*\(\s*\)[\s\S]{0,180}ground_usb_endpoint_ready_now\s*\(\s*raw_host_present\s*\)' `
        "$($bridgeEntry[1]) boot-time raw absence has no grace"
    }
    Require-Pattern $ground `
      'observe_usb_host_presence\s*\(\s*raw_host_present\s*,' `
      'Ground diagnostic usjp family observes raw isPlugged state'
    Require-Pattern $ground `
      'presence_update\s*!=[\s\S]{0,180}ConfirmedConnected[\s\S]{0,180}ConfirmedDisconnected[\s\S]{0,180}return\s*;[\s\S]{0,220}set_usb_connected\s*\(\s*host_present' `
      'Ground diagnostic hpdis changes only on confirmed host loss'
    Require-Pattern $groundReportText `
      'Serial\.isPlugged\s*\(\s*\)\s*&&\s*static_cast<bool>\s*\(\s*Serial\s*\)[\s\S]{0,300}availableForWrite' `
      'Ground diagnostic report writer pauses on host or endpoint unavailability'

    # Tag every fail-stop call reachable in the Ground diagnostic build. The
    # fixed expected count catches removal of both a tag and its reason arm;
    # the fallback observer separately guarantees that any future missed path
    # still reports a nonzero unknown reason instead of rsr=0.
    $expectedGroundRuntimeLatchCount = 38
    $groundRuntimeLatchCount = [regex]::Matches(
      $ground, 'VC_LORA_GROUND_RUNTIME_REASON_COVERED').Count
    $reasonedLatchPattern = '(?ms)' +
      '#if\s+defined\(VC_LORA_PHASE6_GROUND_DIAGNOSTICS\)' +
      '(?:(?!^\s*#endif\b)[\s\S])*?' +
      'arm_runtime_stop_reason\s*\(' +
      '(?:(?!^\s*#endif\b)[\s\S])*?' +
      'VC_LORA_GROUND_RUNTIME_REASON_COVERED' +
      '(?:(?!^\s*#endif\b)[\s\S])*?' +
      '^\s*#endif\s*$\s*' +
      'latch_runtime_fail_closed\s*\(\s*\)\s*;'
    $groundRuntimeReasonCoverageCount = [regex]::Matches(
      $ground, $reasonedLatchPattern).Count
    if ($groundRuntimeLatchCount -ne $expectedGroundRuntimeLatchCount) {
      Add-Failure (
        'Ground runtime-stop source contract expected ' +
        "$expectedGroundRuntimeLatchCount tagged callsites, found " +
        $groundRuntimeLatchCount)
    }
    if ($groundRuntimeReasonCoverageCount -ne $groundRuntimeLatchCount) {
      Add-Failure (
        'Ground runtime-stop reason coverage is incomplete ' +
        "($groundRuntimeReasonCoverageCount/$groundRuntimeLatchCount callsites)")
    }
    Require-Pattern $groundObserverText `
      'UnknownRuntimeFault\s*=\s*255U' `
      'nonzero fallback for an unarmed runtime-stop cause'
    Require-Pattern $groundObserverText `
      'ground_report_can_start\s*\(' `
      'frame-boundary report admission predicate'
    Require-Pattern $groundObserverText `
      'begin_usb_report\s*\(' `
      'deferred report activation hook'
    Require-Pattern $groundReportText `
      'ground_report_can_start\s*\([\s\S]{0,500}egress\.empty\s*\(\s*\)[\s\S]{0,200}egress\.write_pending\s*\(\s*\)' `
      'normal report waits for an empty LocalEgress frame boundary'
    Require-Pattern $groundObserverText `
      '!action_pending\s*&&\s*egress_empty\s*&&\s*!egress_write_pending' `
      'report admission rejects a partial/active LocalEgress frame'

    foreach ($key in @('uv20', 'padm', 'front', 'wire', 'deq', 'data',
        'done', 'pst', 'pact', 'pidx', 'pcnt', 'pnat', 'ppois', 'pnq',
        'ppre', 'pgen', 'ptx')) {
      Require-Pattern $groundReportText ("\b{0}=%" -f $key) "GCSTAT proxy-stage key $key"
    }
    foreach ($key in @('mcr', 'rfpbs', 'rfpfa', 'rfpno', 'rfpbl',
        'rfpcr', 'rfpum', 'rfpuf', 'rfprs', 'rfpbuf', 'rfdmbuf',
        'rfdmesc', 'pvto', 'punm', 'pract', 'prold', 'prfut', 'prgap', 'prto',
        'prq', 'prtx', 'prv', 'prusb', 'prlv', 'prlr', 'prlex', 'prlrx',
        'prlcnt', 'prlseq', 'prlms')) {
      Require-Pattern $groundReportText ("\b{0}=%" -f $key) `
        "GCSTAT RF-parser/recovery key $key"
    }
    Require-Pattern $groundReportText `
      'mcr=%llu\s+rfpbs=%llu\s+rfpfa=%llu\s+rfpno=%llu\s+rfpbl=%llu\s+rfpcr=%llu\s+rfpum=%llu\s+rfpuf=%llu\s+rfprs=%llu\s+rfpbuf=%u\s+rfdmbuf=%u\s+rfdmesc=%u' `
      'fixed RF parser/demux report format widths'
    Require-Pattern $groundReportText `
      'pvto=%llu\s+punm=%llu\s+pract=%u\s+prold=%llu\s+prfut=%llu\s+prgap=%llu\s+prto=%llu\s+prq=%llu\s+prtx=%llu\s+prv=%llu\s+prusb=%llu\s+prlv=%u\s+prlr=%u\s+prlex=%u\s+prlrx=%u\s+prlcnt=%u\s+prlseq=%u\s+prlms=%llu' `
      'fixed proxy recovery report format widths'
    Require-Pattern $groundReportText `
      'pnat=%llu\s+ppois=%llu\s+pnq=%llu\s+ppre=%llu\s+pgen=%llu' `
      'fixed native precommit quarantine report order and widths'
    Require-Pattern $canonicalGroundProxyText `
      'enum\s+class\s+GroundParameterRecoveryReason\s*:\s*std::uint8_t\s*\{\s*None\s*=\s*0U\s*,\s*FutureIndex\s*=\s*1U\s*,\s*InterValueTimeout\s*=\s*2U\s*,\s*InvalidFrame\s*=\s*3U\s*,\s*SourceMismatch\s*=\s*4U\s*,\s*CountMismatch\s*=\s*5U\s*,\s*UsbRejected\s*=\s*6U' `
      'fixed recovery first-fault reason codes'
    Require-Pattern $canonicalGroundProxyText `
      'struct\s+GroundParameterRecoveryLatch\s*\{[\s\S]{0,700}bool\s+valid\s*\{\s*false\s*\}[\s\S]{0,160}GroundParameterRecoveryReason\s+reason\s*\{[\s\S]{0,160}std::uint16_t\s+expected_index[\s\S]{0,160}std::uint16_t\s+received_index[\s\S]{0,160}std::uint16_t\s+received_count[\s\S]{0,160}std::uint8_t\s+received_sequence[\s\S]{0,160}std::uint64_t\s+observed_at_ms' `
      'fixed-width recovery first-fault latch schema'
    foreach ($field in @('native_stream_precommit_values_quarantined',
        'native_stream_old_duplicates_consumed',
        'native_stream_future_values_quarantined',
        'native_stream_gap_recoveries', 'native_stream_timeout_recoveries',
        'native_stream_recovery_requests_generated',
        'native_stream_recovery_request_tx_accepted',
        'native_stream_recovery_values_seen',
        'native_stream_recovery_values_usb_queued')) {
      Require-Pattern $canonicalGroundProxyText `
        ("std::uint64_t\s+{0}\s*\{{\s*0U\s*\}}" -f $field) `
        "fixed 64-bit proxy recovery counter $field"
    }
    Require-Pattern $canonicalGroundProxyText `
      'bool\s+native_stream_recovery_active\s*\(\s*\)\s*const\s+noexcept' `
      'fixed native-stream recovery-active accessor'
    Require-Pattern $canonicalGroundProxyText `
      'const\s+GroundParameterRecoveryLatch&\s+recovery_latch\s*\(\s*\)\s*const\s+noexcept' `
      'fixed first recovery latch accessor'
    Require-Pattern $groundReportText `
      'MavlinkParserDiagnostics\s+radio_parser\s*\{\s*\}' `
      'query-snapshot RF MAVLink parser diagnostics POD'
    Require-Pattern $groundReportText `
      'GroundParameterRecoveryLatch\s+proxy_recovery_latch\s*\{\s*\}' `
      'query-snapshot first recovery latch POD'
    foreach ($entry in @(
        @('snapshot\.radio_parser\s*=\s*ground_radio_application_parser\.diagnostics\s*\(\s*\)',
          'RF parser diagnostics captured at query snapshot'),
        @('snapshot\.radio_parser_buffered\s*=\s*ground_radio_application_parser\.buffered_size\s*\(\s*\)',
          'RF parser buffered bytes captured at query snapshot'),
        @('snapshot\.radio_demux_buffered\s*=\s*radio_demux\.buffered_size\s*\(\s*\)',
          'TDD demux buffered bytes captured at query snapshot'),
        @('snapshot\.radio_demux_escaping\s*=\s*radio_demux\.link_data_escaping\s*\(\s*\)\s*\?\s*1U\s*:\s*0U',
          'TDD demux escaping mode captured as fixed integer'),
        @('snapshot\.proxy_recovery_active\s*=\s*ground_parameter_proxy\.native_stream_recovery_active\s*\(\s*\)\s*\?\s*1U\s*:\s*0U',
          'proxy recovery state captured as fixed integer'),
        @('snapshot\.proxy_recovery_latch\s*=\s*ground_parameter_proxy\.recovery_latch\s*\(\s*\)',
          'first recovery fault captured at query snapshot'))) {
      Require-Pattern $groundReportText $entry[0] $entry[1]
    }
    foreach ($entry in @(
        @('static_cast<unsigned long long>\s*\(\s*d\.mavlink_crc_errors\s*\)',
          'aggregate MAVLink error uses unsigned 64-bit formatter argument'),
        @('static_cast<unsigned long long>\s*\(\s*rp\.crc_errors\s*\)',
          'RF parser CRC errors use unsigned 64-bit formatter argument'),
        @('static_cast<unsigned long long>\s*\(\s*p\.value_timeouts\s*\)',
          'proxy value timeouts use unsigned 64-bit formatter argument'),
        @('static_cast<unsigned long long>\s*\(\s*p\.unmatched_values_forwarded\s*\)',
          'proxy unmatched forwarded count uses unsigned 64-bit formatter argument'),
        @('static_cast<unsigned long long>\s*\(\s*p\.native_stream_precommit_values_quarantined\s*\)',
          'precommit quarantine count uses unsigned 64-bit formatter argument'),
        @('static_cast<unsigned long long>\s*\(\s*p\.native_stream_gap_recoveries\s*\)',
          'gap recovery count uses unsigned 64-bit formatter argument'),
        @('static_cast<unsigned long long>\s*\(\s*p\.native_stream_recovery_requests_generated\s*\)',
          'recovery request count uses unsigned 64-bit formatter argument'),
        @('static_cast<unsigned long long>\s*\(\s*p\.native_stream_recovery_request_tx_accepted\s*\)',
          'accepted recovery request count uses unsigned 64-bit formatter argument'),
        @('static_cast<unsigned long long>\s*\(\s*p\.native_stream_recovery_values_seen\s*\)',
          'recovery value count uses unsigned 64-bit formatter argument'),
        @('static_cast<unsigned long long>\s*\(\s*p\.native_stream_recovery_values_usb_queued\s*\)',
          'USB-queued recovery value count uses unsigned 64-bit formatter argument'),
        @('static_cast<unsigned int>\s*\(\s*prl\.reason\s*\)',
          'first recovery reason uses unsigned integer formatter argument'),
        @('static_cast<unsigned int>\s*\(\s*prl\.expected_index\s*\)',
          'first recovery expected index uses unsigned integer formatter argument'),
        @('static_cast<unsigned int>\s*\(\s*prl\.received_index\s*\)',
          'first recovery received index uses unsigned integer formatter argument'),
        @('static_cast<unsigned int>\s*\(\s*prl\.received_count\s*\)',
          'first recovery received count uses unsigned integer formatter argument'),
        @('static_cast<unsigned int>\s*\(\s*prl\.received_sequence\s*\)',
          'first recovery received sequence uses unsigned integer formatter argument'),
        @('static_cast<unsigned long long>\s*\(\s*prl\.observed_at_ms\s*\)',
          'first recovery timestamp uses unsigned 64-bit formatter argument'))) {
      Require-Pattern $groundReportText $entry[0] $entry[1]
    }
    Require-Pattern $groundReportText `
      'static_cast<unsigned long long>\s*\(\s*p\.native_list_requests_leased\s*\)\s*,\s*static_cast<unsigned long long>\s*\(\s*p\.native_stream_poison_events\s*\)\s*,\s*static_cast<unsigned long long>\s*\(\s*p\.native_stream_values_quarantined\s*\)\s*,\s*static_cast<unsigned long long>\s*\(\s*p\.native_stream_precommit_values_quarantined\s*\)\s*,\s*static_cast<unsigned long long>\s*\(\s*p\.requests_generated\s*\)' `
      'native precommit quarantine formatter argument order'
    foreach ($key in @('cdcp', 'cdcs', 'cdct', 'cdcup', 'cdcdn',
        'cdcms', 'usjp', 'usjps', 'usjpt', 'usjpup', 'usjpdn', 'usjpms',
        'rfv', 'rf20', 'rf22', 'rfdc', 'rfq', 'rfd',
        'epc', 'epdis', 'epwait', 'epprog', 'epinv', 'eplqb',
        'eplqa', 'eplcb', 'eplca', 'dacc', 'dnak', 'xacc', 'xnak',
        'iacc', 'inak', 'pwe', 'pwr', 'pwtok', 'pwms', 'rse',
        'rsr', 'rsms', 'rsst', 'rscy', 'rsrdy', 'rfbq', 'rfpc',
        'rfinv', 'obf', 'obb', 'obp22', 'obfq', 'obfr', 'obif', 'obof',
        'obdf', 'obdb', 's1rx', 's1ok', 's1q', 's1bq', 's1dc', 's1d',
        's1pc', 's1iv', 's1ega', 's1egc', 's1egp', 's1val',
        's1cnt', 's1idx', 's1ty', 's1seq', 's1sys', 's1cmp',
        's1ms')) {
      Require-Pattern $groundReportText ("\b{0}=%" -f $key) `
        "GCSTAT continuous-open stage key $key"
    }
    foreach ($key in @('hpq', 'hpp', 'hpada', 'hpv', 'hpe', 'hpx',
        'hpr', 'hpinv', 'hpfor', 'hpdup', 'hpadm', 'hpia', 'hprej',
        'hpabort', 'hpiab', 'hpdc', 'hpblk', 'hpdrop', 'hpshort',
        'hpback', 'hpwu', 'hpcon', 'hpdis', 'hpmaxb', 'hphold',
        'hpusbg', 'hpmaxq', 'hre', 'hro', 'hrv', 'hrlg', 'hrmg',
        'hrvg', 'hrvms', 'hrvst', 'hrvcy', 'hrvaux', 'hrvrb',
        'hrvpa', 'hrvpq', 'hrvpp', 'hrvpad', 'hrvobf', 'hrvob',
        'hrvuq', 'hrvuwp', 'hrvuw', 'hue', 'huo', 'huv', 'hulg',
        'humg', 'huvg', 'huvms', 'huvst', 'huvcy', 'huvaux',
        'huvrb', 'huvpa', 'huvpq', 'huvpp', 'huvpad', 'huvobf',
        'huvob', 'huvuq', 'huvuwp', 'huvuw')) {
      Require-Pattern $groundReportText ("\b{0}=%" -f $key) `
        "GCSTAT heartbeat/pacer key $key"
    }
    Require-Pattern $groundObserverText `
      'gap_observations[\s\S]{0,120}gap_violation_count[\s\S]{0,300}latest_violation' `
      'Ground heartbeat observation/violation/latest-violation latch'
    Require-Pattern $groundObserverText `
      'candidate\s*>\s*kHeartbeatGapViolationMs[\s\S]{0,120}\+\+gap\.gap_violation_count[\s\S]{0,120}gap\.latest_violation\s*=\s*event' `
      'Ground >2500-ms violation threshold and latest context update'
    Require-Pattern $groundObserverText `
      'std::uint16_t\s+ordered_backlog_param_value_frames' `
      'Ground bounded instantaneous ordered-backlog #22 field'
    Require-Pattern $groundObserverText `
      'observe_ground_ordered_backlog_enqueued[\s\S]{0,900}observe_ground_ordered_backlog_removed[\s\S]{0,600}observe_ground_ordered_backlog_cleared' `
      'Ground instantaneous ordered-backlog #22 observer lifecycle'
    Require-Pattern $ground `
      'observe_ground_ordered_backlog_enqueued\s*\(\s*frame\s*\)' `
      'Ground successful ordered-backlog enqueue #22 hook'
    Require-Pattern $ground `
      'observe_ground_ordered_backlog_removed\s*\(\s*frame\s*\)' `
      'Ground ordered-backlog release/discard #22 hook'
    Require-Pattern $ground `
      'observe_ground_ordered_backlog_cleared\s*\(\s*\)' `
      'Ground whole-backlog clear #22 hook'
    Require-Pattern $groundHostTestText `
      'held heartbeats were misclassified[\s\S]{0,1200}queued #22 did not arm[\s\S]{0,1200}whole-backlog discard retained stale #22' `
      'Ground #22 occupancy semantic self-test'
    Require-Pattern $groundReportText `
      'kReportCapacity\s*=\s*10240U' `
      'fixed 10240-byte Ground report capacity'
    $groundMaximumReportBytes =
      Get-GroundConservativeMaximumReportBytes $groundReportText
    if ($null -eq $groundMaximumReportBytes -or
        $groundMaximumReportBytes -ge 10240) {
      Add-Failure "Ground conservative report maximum is not below 10240: $groundMaximumReportBytes"
    } else {
      # Include the trailing NUL required by snprintf and retain enough fixed
      # space for boundary-value evidence without a format-error fallback.
      $groundReportHeadroomBytes = 10240 - ($groundMaximumReportBytes + 1)
      if ($groundReportHeadroomBytes -lt 512) {
        Add-Failure (
          'Ground conservative report headroom is below 512 bytes: ' +
          $groundReportHeadroomBytes)
      }
    }
    foreach ($key in @('r20', 'tdcc', 'tdac', 'tpf', 'ttk', 'tei',
        'd620', 'd722', 'pvid', 'trseq', 'tridx', 'trts', 'trtc',
        'trlen', 'td6ex', 'td7mi', 'pvs1val', 'pvs1cnt', 'pvs1idx',
        'pvs1type', 'pvs1seq', 'pvs1sys', 'pvs1comp', 'pvs1ms')) {
      Require-Pattern $vehicleReportText ("\b{0}=%" -f $key) "VCSTAT #20-stage key $key"
    }
    Require-Pattern $groundObserverText 'observe_usb_frame\s*\(\s*const\s+vc_lora::MavlinkFrame\s*&' `
      'validated Ground USB frame observer API'
    Require-Pattern $groundObserverText `
      'enum\s+class\s+GroundRuntimeStopReason\s*:\s*std::uint8_t' `
      'fixed Ground runtime-stop reason enum'
    Require-Pattern $groundObserverText `
      'enum\s+class\s+GroundProxyWatchdogReason\s*:\s*std::uint8_t' `
      'fixed Ground proxy-watchdog reason enum'
    Require-Pattern $groundObserverText `
      'static_assert\s*\(\s*std::is_trivially_copyable\s*<\s*ObserverStats\s*>' `
      'Ground observer remains fixed POD'
    Require-Pattern $groundObserverText `
      "'S',\s*'E',\s*'R',\s*'I',\s*'A',\s*'L',\s*'1',\s*'_'[\s\S]{0,100}'B',\s*'A',\s*'U',\s*'D'" `
      'Ground retains exact 16-byte SERIAL1_BAUD identity'
    Require-Pattern $groundObserverText `
      'is_expected_serial1_baud_param_value[\s\S]{0,900}frame\.system_id\s*!=\s*1U[\s\S]{0,120}frame\.component_id\s*!=\s*1U[\s\S]{0,900}0x42640000U[\s\S]{0,120}count\s*!=\s*0U[\s\S]{0,160}0xFFFFU[\s\S]{0,120}payload\[24U\]\s*==\s*6U' `
      'Ground strict SERIAL1_BAUD expected-response predicate'
    $groundStrictUses = [regex]::Matches(
      $groundObserverText,
      'is_expected_serial1_baud_param_value\s*\(\s*frame\s*\)').Count
    if ($groundStrictUses -ne 3) {
      Add-Failure "Ground strict target predicate must gate RF, disposition and egress admission (expected 3 uses, got $groundStrictUses)"
    }
    Require-Pattern $groundHostTestText `
      'STAT_RUNTIME[\s\S]{0,5000}same_serial1_chain' `
      'Ground STAT_RUNTIME negative target-chain test'
    Require-Pattern $groundHostTestText `
      'serial1_wrong_source[\s\S]{0,300}serial1_wrong_value[\s\S]{0,8000}same_serial1_chain' `
      'Ground wrong-source/value target-chain negative tests'
    Require-Pattern $ground `
      'GroundUsbOrderedBacklogStatus::Queued[\s\S]{0,700}GroundDownlinkDisposition::[\s\S]{0,80}BacklogQueued' `
      'successful ordered-backlog admission is observed'
    if ($vehicleInoText -match 'VC_LORA_PHASE6_VEHICLE_HEARTBEAT_AB|service_pixhawk_heartbeat_ab') {
      Add-Failure 'Vehicle diagnostic still injects a second A/B heartbeat'
    }
    if ($vehicleObserverText -match '(?s)TargetEventCode::D6Msg20\s*,\s*vc_lora::VehicleTddState::ReturnGuard') {
      Add-Failure 'D6 physical-write event is falsely hardcoded to ReturnGuard'
    }
    Require-Pattern $vehicleObserverText `
      'TargetEventCode::D6Msg20[\s\S]{0,160}observed_state' `
      'D6 physical-write event uses latest observed controller state'
    Require-Pattern $vehicleObserverText `
      'is_expected_serial1_baud_param_value[\s\S]{0,900}frame\.system_id\s*!=\s*1U[\s\S]{0,120}frame\.component_id\s*!=\s*1U[\s\S]{0,900}0x42640000U[\s\S]{0,120}count\s*!=\s*0U[\s\S]{0,160}0xFFFFU[\s\S]{0,120}payload\[24U\]\s*==\s*6U' `
      'Vehicle strict SERIAL1_BAUD expected-response predicate'
    Require-Pattern $vehicleObserverText `
      'const\s+bool\s+expected_target\s*=\s*observe_d7_param_value[\s\S]{0,220}if\s*\(\s*expected_target[\s\S]{0,220}d6_exact\s*>\s*0U' `
      'Vehicle D7 target stages share strict decoded-response predicate'

    Require-Pattern $continuousRunnerText `
      'GetBytes\(\s*"VCSTAT\?`n"\s*\)[\s\S]{0,220}GetBytes\(\s*"VCGSTAT\?`n"\s*\)' `
      'continuous runner exact LF-only query commands'
    Require-Pattern $continuousRunnerText `
      'Write-ExactRequestOnce[\s\S]{0,500}write_count\s*-ne\s*0[\s\S]{0,700}Fixture\.Length\s*-ne\s*32' `
      'continuous runner exact 32-byte one-write guard'
    foreach ($timelineMarker in @('boot_prefix_0_3s', 'live_observe_3_15s',
        'post_baseline_recovery_3s',
        'M0_post_recovery_continuous_analysis_start',
        'M0_pre_request_lead_5s', 'R0_exact_request_final_write',
        'post_response_idle_10s', 'M1_analysis_end_post_query_next')) {
      Require-Pattern $continuousRunnerText ([regex]::Escape($timelineMarker)) `
        "continuous runner timeline marker $timelineMarker"
    }
    Require-Pattern $continuousRunnerText `
      '\$postGround\s*=\s*Invoke-SnapshotQuery[\s\S]{0,3200}\$postVehicle\s*=\s*Invoke-SnapshotQuery[\s\S]{0,8000}\$footerSequenceCompleted\s*=\s*\$true' `
      'continuous runner Ground-then-Vehicle post-query ordering'
    Require-Pattern $continuousRunnerText `
      'vehicle_rx\.raw\.bin[\s\S]{0,300}ground_rx\.raw\.bin[\s\S]{0,5200}vehicle_initial_up_to_256\.bin[\s\S]{0,300}ground_initial_up_to_256\.bin' `
      'continuous raw and initial-256 evidence files'
    if ($continuousRunnerText -match '_rx_contiguous\.bin') {
      Add-Failure 'continuous runner retains obsolete post-close contiguous raw files'
    }
    Require-Pattern $continuousRunnerText `
      'ValidateRange\(5000,\s*60000\)[\s\S]{0,80}PowerOffConfirmMs\s*=\s*5000' `
      'continuous runner default 5-second power-off confirmation'
    if ($continuousRunnerText -match
        '(?i)(Skip|Bypass|Disable|Ignore)[A-Za-z0-9_]*PowerOff') {
      Add-Failure 'continuous runner exposes a power-off confirmation bypass'
    }
    Require-Pattern $continuousRunnerText `
      '\$powerOffWait\s*=\s*Wait-ForBothPortsAbsent[\s\S]{0,1200}POWER_OFF_CONFIRMED_WAITING_FOR_PORTS[\s\S]{0,1200}\$portWait\s*=\s*Wait-ForBothPorts' `
      'continuous runner mandatory 5-second power-off then enumeration preflight'
    Require-Pattern $continuousRunnerText `
      'message_id\s*-eq\s*0\s*-and\s*\$_\.system_id\s*-eq\s*1\s*-and[\s\S]{0,80}\$_\.component_id\s*-eq\s*1[\s\S]{0,1000}first_from_M0[\s\S]{0,1000}consecutive[\s\S]{0,1000}tail_to_M1[\s\S]{0,1000}heartbeats\.Count\s*-ge\s*2[\s\S]{0,120}exceedances\.Count\s*-eq\s*0' `
      'continuous runner source-filtered full-window heartbeat metric'
    Require-Pattern $continuousRunnerText `
      'MaximumGapMs\s*=\s*2500\.0' `
      'continuous runner 2500-ms full-window heartbeat limit'
    Require-Pattern $continuousRunnerText `
      'gap_exceedances\s*=\s*@\(\$exceedances\)' `
      'continuous runner records every heartbeat gap exceedance'
    Require-Pattern $continuousRunnerText `
      '\$heartbeatMetrics\s*=\s*Get-HeartbeatWindowMetrics[\s\S]{0,400}\$heartbeatMetrics\.valid[\s\S]{0,3600}\$heartbeatMetrics\.valid' `
      'continuous runner heartbeat call, error and PASS gates'
    Require-Pattern $continuousRunnerText `
      'elapsed_ms\s*-gt\s*\$R0ElapsedMs\s*-and[\s\S]{0,100}elapsed_ms\s*-le\s*\$M1ElapsedMs[\s\S]{0,700}preRequestWindow\.Count\s*-eq\s*0[\s\S]{0,100}responses\.Count\s*-eq\s*1[\s\S]{0,160}latency\s*-le\s*\$TimeoutMs[\s\S]{0,700}duplicate_count' `
      'continuous runner strict post-R0 single-target window helper'
    Require-Pattern $continuousRunnerText `
      'TimeoutMs\s*=\s*20000\.0' `
      'continuous runner 20-second strict-target timeout'
    Require-Pattern $continuousRunnerText `
      'candidate\.elapsed_ms\s*-gt\s*\[double\]\$r0\.elapsed_ms' `
      'continuous runner live response filter excludes at-R0 events'
    Require-Pattern $continuousRunnerText `
      '\$targetWindow\s*=\s*Get-TargetResponseWindow[\s\S]{0,500}\$targetWindow\.valid[\s\S]{0,3200}\$targetWindow\.valid' `
      'continuous runner strict response call, error and PASS gates'
    $baselineGateIndex = $continuousRunnerText.IndexOf(
        '$baselineSetup = Test-BaselineSetup')
    $baselineStopIndex = $continuousRunnerText.IndexOf(
        "baseline_stop_no_request")
    $causalStopIndex = $continuousRunnerText.IndexOf(
        'R0_causal_gate_stop_no_request')
    $groundWriteIndex = $continuousRunnerText.IndexOf(
        'Write-ExactRequestOnce -Serial $groundSerial')
    if ($baselineGateIndex -lt 0 -or $baselineStopIndex -lt $baselineGateIndex -or
        $causalStopIndex -lt $baselineStopIndex -or
        $groundWriteIndex -lt $causalStopIndex) {
      Add-Failure 'continuous runner baseline/causal request-suppression ordering is missing'
    }
    Require-Pattern $continuousRunnerText `
      'preRequestExactCount[\s\S]{0,1800}Buffer\.Count\s*-eq\s*0[\s\S]{0,200}ExpectedLength\s*-eq\s*0[\s\S]{0,200}preRequestExactCount\s*-eq\s*0[\s\S]{0,1800}causal_gate_invalid' `
      'continuous runner pre-R0 clean parser and zero-target causal gate'
    Require-Pattern $continuousRunnerText `
      '\$stageAssessment\s*=\s*Get-StageAssessment[\s\S]{0,500}first_missing[\s\S]{0,3200}\$stageAssessment\.valid' `
      'continuous runner observer-chain localization and PASS gate'
    foreach ($stageKey in @('uv20', 'upfwd', 'uqf', 'ufdq', 'utx', 'upb',
        'dtx', 'r20', 'd620', 'td6ex', 'pvs1', 'td7mi', 's1rx', 's1ok',
        's1q', 's1bq', 's1ega', 's1egc')) {
      Require-Pattern $continuousRunnerText ("'{0}'" -f $stageKey) `
        "continuous runner stage key $stageKey"
    }
    Require-Pattern $continuousRunnerText `
      "'upb'\s+'exact'\s+32[\s\S]{0,3800}s1Queued\.delta[\s\S]{0,500}s1Backlog\.delta[\s\S]{0,80}-le\s+1[\s\S]{0,500}endpoint_exact_backlog_optional" `
      'continuous runner exact uplink and backlog-to-endpoint disposition rules'
    Require-Pattern $continuousRunnerText `
      "'rse'\s+'unchanged_zero'\s+0[\s\S]{0,200}'fail'\s+'unchanged_zero'\s+0[\s\S]{0,220}'f'\s+'unchanged_zero'\s+0" `
      'continuous runner runtime/fail unchanged-zero rules'
    Require-Pattern $continuousRunnerText `
      'same_nonzero[\s\S]{0,1500}strictly_increasing' `
      'continuous runner boot identity and post-ms monotonic rules'
    Require-Pattern $continuousRunnerText `
      'Import-MavlinkDefinitions[\s\S]{0,1600}minimum_payload_length[\s\S]{0,300}maximum_payload_length' `
      'continuous runner authoritative all-message definitions loader'
    foreach ($parserCounter in @('Definitions', 'Unsupported',
        'UnsupportedFlags', 'BadPayloadLength', 'BadCrc', 'NoiseBytes')) {
      Require-Pattern $continuousRunnerText ("{0}\s*=" -f $parserCounter) `
        "continuous runner all-message parser field $parserCounter"
    }
    Require-Pattern $continuousRunnerText `
      "Join-Path \`$repo 'core\\src\\mavlink_frame\.cpp'" `
      'continuous runner canonical MAVLink definition source'
    foreach ($integrityField in @('unsupported_delta',
        'unsupported_flags_delta', 'bad_payload_length_delta',
        'bad_crc_delta', 'noise_bytes_delta', 'partial_buffer_bytes',
        'expected_length')) {
      Require-Pattern $continuousRunnerText ("{0}\s*=" -f $integrityField) `
        "continuous runner M0/M1 integrity field $integrityField"
    }
    Require-Pattern $continuousRunnerText `
      '\$parserIntegrity\.valid[\s\S]{0,5000}\$parserIntegrity\.valid' `
      'continuous runner parser-integrity error and PASS gates'
    foreach ($diagnosticPrefix in @('ground_diagnostic_delta_zero_',
        'vehicle_diagnostic_delta_zero_', 'ground_current_zero_',
        'vehicle_current_zero_')) {
      Require-Pattern $continuousRunnerText ([regex]::Escape($diagnosticPrefix)) `
        "continuous runner diagnostic gate $diagnosticPrefix"
    }
    $stageStart = $continuousRunnerText.IndexOf(
        'function Get-StageAssessment')
    $stageEnd = $continuousRunnerText.IndexOf(
        'function New-OfflineSnapshot', $stageStart)
    if ($stageStart -lt 0 -or $stageEnd -le $stageStart) {
      Add-Failure 'continuous runner stage-assessment function boundaries missing'
    } else {
      $stageText = $continuousRunnerText.Substring(
          $stageStart, $stageEnd - $stageStart)
      function Require-ExactStageKeySet {
        param([string]$Prefix, [string[]]$Expected)
        $blockPattern = (@'
foreach \(\$key in @\((?<keys>(?:\s*'[^']+'\s*,?)+)\)\) \{\s*Add-DeltaStage \("__PREFIX__\$key"\)
'@).Trim().Replace('__PREFIX__', [regex]::Escape($Prefix))
        $match = [regex]::Match($stageText, $blockPattern)
        if (-not $match.Success) {
          Add-Failure "continuous runner exact key-set block missing: $Prefix"
          return
        }
        $actual = @([regex]::Matches($match.Groups['keys'].Value,
            "'([^']+)'") | ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique)
        $wanted = @($Expected | Sort-Object -Unique)
        if (($actual -join ',') -ne ($wanted -join ',')) {
          Add-Failure ("continuous runner key-set mismatch for ${Prefix}: " +
              "actual=[$($actual -join ',')] " +
              "expected=[$($wanted -join ',')]")
        }
      }
      Require-ExactStageKeySet 'ground_diagnostic_delta_zero_' @(
        'ci', 'cc', 'cuv', 'cut', 'cm', 'ucr', 'uiv', 'udf', 'udb',
        'uoe', 'urc', 'uic', 'dli', 'dlo', 'upinv', 'epinv',
        'rfinv', 'obif', 'obof', 's1dc', 's1d', 's1pc', 's1iv',
        's1ego', 'hd', 'dnak', 'xnak', 'inak', 'pwto', 'psfail', 'prej')
      Require-ExactStageKeySet 'ground_current_zero_' @(
        'uqfb', 'uqb', 'ubuf', 'dlq', 's1egp')
      Require-ExactStageKeySet 'vehicle_diagnostic_delta_zero_' @(
        'cc', 'rcr', 'riv', 'ocr', 'oiv', 'eiv', 'eov', 'out', 'd6cr',
        'd7cr', 'pvbad', 'pvov', 'eo', 'sc', 'evo')
      Require-ExactStageKeySet 'vehicle_current_zero_' @(
        'pb', 'qb', 'tar')
      Require-Pattern $stageText `
        "vehicle_commit_preflight_ok'[\s\S]{0,100}'tpf'[\s\S]{0,250}vehicle_commit_take_ok'[\s\S]{0,100}'ttk'[\s\S]{0,250}vehicle_commit_egress_ok'[\s\S]{0,100}'tei'[\s\S]{0,700}zero_to_success'[\s\S]{0,100}expected\s*=\s*2" `
        'continuous runner atomic commit tri-state success gates'
      Require-Pattern $stageText `
        "vehicle_commit_bytes'[\s\S]{0,120}'tcb'\s+'exact'\s+32[\s\S]{0,180}vehicle_commit_frames'[\s\S]{0,120}'tcf'\s+'exact'" `
        'continuous runner atomic commit byte/frame gates'
      if ($stageText -match
          "ground_diagnostic_delta_zero_[\s\S]{0,1200}'dlf'") {
        Add-Failure 'continuous runner incorrectly treats valid downlink frames as delta-zero'
      }
    }
    Require-Pattern $continuousRunnerText `
      'FileOptions\]::WriteThrough[\s\S]{0,400}Flush\(\$true\)' `
      'continuous runner durable write implementation'
    Require-Pattern $continuousRunnerText `
      '}\s*finally\s*\{[\s\S]{0,500}\$vehicleRaw\s*=\s*\$vehicleCapture\.Raw\.ToArray\(\)[\s\S]{0,500}Invoke-PumpPair[\s\S]{0,800}\$vehicleRaw\s*=\s*\$vehicleCapture\.Raw\.ToArray\(\)' `
      'continuous runner snapshot-before-best-effort-pump evidence preservation'
    Require-Pattern $continuousRunnerText `
      'capture_footer\.json[\s\S]{0,300}\$footerFsyncElapsedMs[\s\S]{0,200}\$footerRecorded\s*=\s*\$true[\s\S]{0,7000}Test-FooterCloseOrdering' `
      'continuous runner durable footer-before-close contract'
    Require-Pattern $continuousRunnerText `
      'completed\s*=\s*\$footerSequenceCompleted[\s\S]{0,200}status\s*=\s*\$preCloseStatus[\s\S]{0,300}error_count[\s\S]{0,500}snapshots[\s\S]{0,1500}vehicle_sha256[\s\S]{0,300}ground_sha256[\s\S]{0,3000}completed\s*=\s*\$false' `
      'continuous runner normal and fallback footer schema'
    $firstCloseIndex = @(
      $continuousRunnerText.IndexOf('$groundSerial.Close()'),
      $continuousRunnerText.IndexOf('$vehicleSerial.Close()')) |
        Where-Object { $_ -ge 0 } | Measure-Object -Minimum |
        Select-Object -ExpandProperty Minimum
    foreach ($evidenceName in @('vehicle_rx.raw.bin', 'ground_rx.raw.bin',
        'timeline.json', 'vehicle_read_spans.json', 'ground_read_spans.json',
        'vehicle_tagged_ascii_spans.json', 'ground_tagged_ascii_spans.json',
        'ground_mavlink_valid_events.json', 'ground_exact_target_events.json')) {
      $writePattern = 'Write-(?:Bytes|Json)Durable[\s\S]{0,220}' +
          [regex]::Escape($evidenceName)
      $writeMatches = [regex]::Matches($continuousRunnerText, $writePattern)
      if ($writeMatches.Count -ne 1 -or $firstCloseIndex -lt 0 -or
          $writeMatches[0].Index -gt $firstCloseIndex) {
        Add-Failure "durable pre-close evidence write contract failed for $evidenceName"
      }
    }
    Require-Pattern $continuousRunnerText `
      'postclose_finalization_error\.json[\s\S]{0,1200}exit\s+2' `
      'continuous runner durable post-close ERROR/exit2 contract'
    Require-Pattern $continuousRunnerText `
      'STAT_RUNTIME[\s\S]{0,500}SystemId\s+2[\s\S]{0,500}0x42680000[\s\S]{0,1400}ExactTargetEvents\.Count\s*-ne\s*1' `
      'runner strict-target negative self-test fixtures'
    foreach ($selfTestMarker in @(
        'heartbeat first/consecutive/tail PASS contract failed',
        'heartbeat gap/count FAIL contract failed',
        'strict response R0/count/timeout contract failed',
        'valid baseline/stage chain was rejected',
        'atomic commit zero-to-success gate failed',
        'stage first-missing localization failed',
        'invalid baseline did not suppress request injection',
        'M0-to-M1 parser integrity contract failed',
        'all-message badCRC/badlen/unsupported/noise gates failed',
        'Ground invalid/drop/overflow/backlog gate failed',
        'invalid/drop/overflow/backlog delta-zero gate failed',
        'post snapshot ms monotonic gate failed',
        'power-off confirmation/enumeration timeline contract failed',
        'footer-fsync-before-close ordering contract failed')) {
      Require-Pattern $continuousRunnerText ([regex]::Escape($selfTestMarker)) `
        "runner offline SelfTest marker $selfTestMarker"
    }
    foreach ($readmeText in @($vehicleDiagnosticReadmeText,
        $groundDiagnosticReadmeText)) {
      Require-Pattern $readmeText `
        'POWER_OFF_CONFIRMED_WAITING_FOR_PORTS[\s\S]{0,1000}5000|5000[\s\S]{0,1000}POWER_OFF_CONFIRMED_WAITING_FOR_PORTS' `
        'diagnostic README clean power-cycle workflow'
      Require-Pattern $readmeText `
        'vehicle_rx\.raw\.bin[\s\S]{0,300}ground_rx\.raw\.bin[\s\S]{0,500}capture_footer\.json' `
        'diagnostic README durable continuous raw/footer evidence'
      Require-Pattern $readmeText `
        'PASS[\s\S]{0,2200}((heartbeat|HEARTBEAT)[\s\S]{0,900}(parser|MAVLink)|(parser|MAVLink)[\s\S]{0,900}(heartbeat|HEARTBEAT))' `
        'diagnostic README PASS heartbeat/parser gates'
    }
    Require-Pattern $groundDiagnosticReadmeText `
      'pnq[\s\S]{0,220}ppre[\s\S]{0,260}pnq>0[\s\S]{0,160}accounted\s+for\s+by[\s\S]{0,40}ppre[\s\S]{0,120}ppois=0' `
      'Ground diagnostic README precommit quarantine accounting relation'
    if ($continuousRunnerText -match
        'DiscardInBuffer|DiscardOutBuffer|Clear-SerialInput') {
      Add-Failure 'continuous runner contains an input-discard path'
    }
    $openCount = [regex]::Matches($continuousRunnerText,
      '\.Open\s*\(\s*\)').Count
    $closeCount = [regex]::Matches($continuousRunnerText,
      '\.Close\s*\(\s*\)').Count
    if ($openCount -ne 2 -or $closeCount -ne 2) {
      Add-Failure "continuous runner must have exactly one open/close site per port (open=$openCount close=$closeCount)"
    }
    $selfTestGate = [regex]::Match($continuousRunnerText,
      'if\s*\(\s*\$SelfTest\.IsPresent\s*\)[\s\S]{0,100}Invoke-OfflineSelfTest[\s\S]{0,60}return')
    $firstSerialConstruction = [regex]::Match($continuousRunnerText,
      'New-Object\s+System\.IO\.Ports\.SerialPort')
    $firstEnumeration = [regex]::Match($continuousRunnerText,
      '\[System\.IO\.Ports\.SerialPort\]::GetPortNames')
    if (-not $selfTestGate.Success -or -not $firstSerialConstruction.Success -or
        -not $firstEnumeration.Success -or
        $selfTestGate.Index -gt $firstSerialConstruction.Index -or
        $selfTestGate.Index -gt $firstEnumeration.Index) {
      Add-Failure 'runner SelfTest does not return before COM enumeration/construction'
    }

    $groundQ = [regex]::Matches(
      $groundReportText,
      'static_cast<unsigned long>\s*\(\s*s\.query_id\s*\)').Count
    $groundMs = [regex]::Matches(
      $groundReportText,
      'static_cast<unsigned long long>\s*\(\s*s\.now_ms\s*\)').Count
    if ($groundQ -ne 3 -or $groundMs -ne 3) {
      Add-Failure "GCSTAT1/2/3 do not share one q/ms snapshot (q=$groundQ ms=$groundMs)"
    }
    if ([regex]::Matches($groundReportText, 'GCSTAT[123]\s+q=%').Count -ne 3) {
      Add-Failure 'Ground report is not exactly three GCSTAT q-correlated lines'
    }
  }

  $compiler = (Get-Command clang++ -ErrorAction SilentlyContinue).Source
  if (-not $compiler) {
    $compiler = Join-Path $env:TEMP `
      'vc_lora_host_tools\llvm-mingw-20260616-tar\llvm-mingw-20260616-ucrt-x86_64\bin\clang++.exe'
  }
  if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    Add-Failure 'clang++ required for Ground query semantic test was not found'
  } else {
    $hostExe = Join-Path $OutputDir 'ground_diag_query_observer_contract_tests.exe'
    $hostCompile = Invoke-Native $compiler @(
      '-std=c++17', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
      "-I$groundRoot", $groundHostTest,
      (Join-Path $groundRoot 'src\mavlink_frame.cpp'), '-static',
      '-o', $hostExe)
    $hostCompile.Output -join [Environment]::NewLine |
      Set-Content -LiteralPath (Join-Path $OutputDir 'host_compile.log') -Encoding UTF8
    if ($hostCompile.ExitCode -ne 0) {
      Add-Failure "Ground query semantic test compile failed ($($hostCompile.ExitCode))"
    } else {
      $hostRun = Invoke-Native $hostExe @()
      $hostRun.Output -join [Environment]::NewLine |
        Set-Content -LiteralPath (Join-Path $OutputDir 'host_run.log') -Encoding UTF8
      if ($hostRun.ExitCode -ne 0) {
        Add-Failure "Ground query semantic test failed ($($hostRun.ExitCode))"
      }
    }
  }

  if (Test-Path -LiteralPath $groundQueryTool -PathType Leaf) {
    $querySelfTest = Invoke-Native 'powershell.exe' @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      $groundQueryTool, '-SelfTest')
    $querySelfTest.Output -join [Environment]::NewLine |
      Set-Content -LiteralPath (Join-Path $OutputDir 'query_tool_selftest.log') -Encoding UTF8
    if ($querySelfTest.ExitCode -ne 0) {
      Add-Failure "Ground query collector self-test failed ($($querySelfTest.ExitCode))"
    }
  } else {
    Add-Failure 'Ground query collector is missing'
  }
  if (Test-Path -LiteralPath $continuousRunner -PathType Leaf) {
    $runnerSelfTest = Invoke-Native 'powershell.exe' @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      $continuousRunner, '-SelfTest')
    $runnerSelfTest.Output -join [Environment]::NewLine |
      Set-Content -LiteralPath `
        (Join-Path $OutputDir 'continuous_runner_selftest.log') -Encoding UTF8
    if ($runnerSelfTest.ExitCode -ne 0) {
      Add-Failure "continuous dual-COM runner self-test failed ($($runnerSelfTest.ExitCode))"
    }
  } else {
    Add-Failure 'continuous dual-COM runner is missing'
  }
} catch {
  Add-Failure "unexpected contract failure: $($_.Exception.Message)"
} finally {
  $finishedUtc = (Get-Date).ToUniversalTime()
  $summary = [ordered]@{
    schema_version = 1
    test = $testId
    result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
    started_utc = $startedUtc.ToString('o')
    finished_utc = $finishedUtc.ToString('o')
    canonical_bridge_sha256 = if (Test-Path $canonicalBridge) {
      (Get-FileHash -Algorithm SHA256 -LiteralPath $canonicalBridge).Hash
    } else { $null }
    ground_conservative_maximum_report_bytes = $groundMaximumReportBytes
    ground_conservative_report_headroom_bytes = $groundReportHeadroomBytes
    errors = @($errors)
    requirements = @(
      'both diagnostic cores are byte-identical to canonical core',
      'both adapters retain latest v2 proxy/dequeue/DONE/front-frame contracts',
      'both adapters revalidate ordered-backlog frames and handle Consumed or Invalid before USB admission',
      'Ground exposes USB-valid/admission/front/wire/dequeue/DATA/DONE/proxy state',
      'Ground snapshots aggregate MAVLink errors plus RF parser and demux state using fixed-width report arguments',
      'Ground exposes bounded native-stream recovery counters and a non-overwriting first-fault latch',
      'Ground diagnostic report retains at least 512 bytes of conservative boundary-value headroom including its trailing NUL',
      'Ground exposes sticky HWCDC predicate, RF-valid/downlink, USB egress progress, watchdog and first runtime-stop cause',
      'Ground raw isPlugged loss pauses writes immediately but only 50 ms continuous loss changes admission, pacer, parser or discard state',
      'Ground usjp remains the raw HWCDC observation while hpdis records only confirmed host loss',
      'Ground RF-primary heartbeat supply is latched at CRC-valid ingress before USB connection rejection',
      "Ground arms a reason at every runtime fail-stop callsite ($groundRuntimeReasonCoverageCount/$groundRuntimeLatchCount)",
      'Ground strict target predicate gates RF, disposition, admission and physical-commit goal stages',
      'Vehicle strict target predicate gates D7 target counter, timestamp and retained tuple',
      'STAT_RUNTIME cannot advance either strict SERIAL1_BAUD target chain',
      'continuous dual-COM runner passes its offline self-test',
      'runner requires a non-bypassable five-second both-ports-absent power-cycle preflight',
      'runner suppresses injection unless baseline and pre-R0 causal parser/target gates pass',
      'continuous runner opens each COM once, snapshots before final pump, fsyncs raw/events/footer and closes afterward',
      'M0-to-M1 parser uses canonical all-message definitions and gates unsupported, length, CRC, noise and partial deltas at zero',
      'source-1/1 heartbeat first/consecutive/tail gaps remain at most 2500 ms',
      'exact SERIAL1_BAUD response is absent before R0 and occurs exactly once within 20000 ms afterward',
      'observer chain requires exact upb=32, direct target disposition, no invalid/drop/overflow/backlog deltas and monotonic snapshot ms',
      'runner infrastructure/finalization errors produce durable secondary evidence and exit 2',
      'Vehicle exposes RF #20/terminal commit/D6 exact #20/D7 exact target and param_id',
      'Vehicle uses only the canonical queued 1-Hz heartbeat'
    )
  }
  $summary | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $OutputDir 'summary.json') -Encoding UTF8
  Write-Host "$($summary.result) $testId summary=$(Join-Path $OutputDir 'summary.json')"
}

if ($errors.Count -ne 0) { exit 1 }
exit 0
