[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $OutputDirectory = Join-Path $repo `
      "runs\high_speed\HS-G1-D7-HIL-RUNNER-CONTRACT-001\$stamp"
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite contract evidence: $OutputDirectory"
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)

$checks = [Collections.ArrayList]::new()
function Add-Check([string]$Name, [bool]$Valid, [string]$Detail) {
  [void]$checks.Add([pscustomobject][ordered]@{
    name=$Name;valid=$Valid;detail=$Detail
  })
}

$runnerPath = Join-Path $repo 'tools\run_pixhawk_d7_param_benchmark_hil.ps1'
$sketchPath = Join-Path $repo `
    'runs\candidates\R19-HS-G1-D7-BENCHMARK-004\20260915T114743494Z\source\vc_lora_vehicle_pixhawk_param_benchmark_xiao_esp32s3.ino'
$candidateBinPath = Join-Path $repo `
    'runs\candidates\R19-HS-G1-D7-BENCHMARK-004\20260915T114743494Z\firmware\vc_lora_vehicle_pixhawk_param_benchmark_xiao_esp32s3.ino.bin'
$expectedSketchSha256 = `
    '5328C86DC88F403802D2F9521DA016D9DC39AE74BCBD5A2518B84ED2EC20E5EB'
$expectedCandidateSha256 = `
    '493DA28D328E6F6DBBEE457887B81F29674F44A987E6A2879277BE686C1CF897'
if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
  Add-Check 'runner_exists' $false $runnerPath
} else {
  Add-Check 'runner_exists' $true $runnerPath
  $source = [IO.File]::ReadAllText($runnerPath)
  $sketch = [IO.File]::ReadAllText($sketchPath)
  $tokens = $null
  $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile(
      $runnerPath, [ref]$tokens, [ref]$parseErrors)
  Add-Check 'runner_parses_without_error' (@($parseErrors).Count -eq 0) `
      (@($parseErrors) -join '; ')

  function Get-FunctionText([string]$Name) {
    $matches = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -ceq $Name
    }, $true))
    if ($matches.Count -ne 1) { return '' }
    $matches[0].Extent.Text
  }

  $pinText = Get-FunctionText 'Test-StaticPins'
  $safeArgvText = Get-FunctionText 'Assert-SafeEspToolArgv'
  $clientText = Get-FunctionText 'Assert-NoCompetingClients'
  $serialText = Get-FunctionText 'Invoke-ThreeRunMeasurement'
  $readyText = Get-FunctionText 'Wait-BenchmarkReady'
  $readyParserText = Get-FunctionText 'Convert-StrictReadyLine'
  $ackParserText = Get-FunctionText 'Convert-StrictStartAckLine'
  $progressParserText = Get-FunctionText 'Assert-ProgressProtocol'
  $protocolLineText = Get-FunctionText 'Register-ProtocolLine'
  $protocolPrefixText = ''
  $postResultDrainText = Get-FunctionText 'Assert-PostResultLineQuiet'
  $strayRecordText = Get-FunctionText 'Assert-NoStrayRequestRecord'
  $resultText = Get-FunctionText 'Assert-StrictResult'
  $restoreText = Get-FunctionText 'Invoke-ProductionRestore'
  $finalizeText = Get-FunctionText 'Complete-Evidence'
  $runnerLockText = Get-FunctionText 'Lock-RunnerSource'
  $runnerPinText = Get-FunctionText 'Assert-RunnerPinned'
  $runnerStagePinText = Get-FunctionText 'Assert-RunnerStagePinned'
  $runnerIntegrityText = Get-FunctionText 'Get-RunnerSourceIntegrity'
  $capturedEspToolText = Get-FunctionText 'Invoke-CapturedEspTool'
  $recoveryCaptureText = Get-FunctionText 'Invoke-RecoveryEspToolMemoryCapture'
  $bestEffortWriteText = Get-FunctionText 'Invoke-BestEffortEvidenceWrite'
  $recoveryOrchestrationText = `
      Get-FunctionText 'Invoke-BoundedRecoveryOrchestration'
  $flashStepText = Get-FunctionText 'Invoke-FlashStep'
  $recoveryConflictText = Get-FunctionText 'Assert-RecoveryCom3Available'

  $protocolPrefixMatch = [regex]::Match($sketch,
      '(?s)void\s+print_protocol_prefix\s*\([^)]*\)\s*\{(?<body>.*?)\n\}')
  if ($protocolPrefixMatch.Success) {
    $protocolPrefixText = $protocolPrefixMatch.Groups['body'].Value
  }
  $actualSketchSha256 = (Get-FileHash -Algorithm SHA256 `
      -LiteralPath $sketchPath).Hash
  $actualCandidateSha256 = (Get-FileHash -Algorithm SHA256 `
      -LiteralPath $candidateBinPath).Hash

  Add-Check 'artifact_pins_are_exact' (
      $actualCandidateSha256 -ceq $expectedCandidateSha256 -and
      (Get-Item -LiteralPath $candidateBinPath).Length -eq 288864 -and
      $actualSketchSha256 -ceq $expectedSketchSha256 -and
      (Get-Item -LiteralPath $sketchPath).Length -eq 24999 -and
      $source.Contains($expectedCandidateSha256) -and
      $source.Contains($expectedSketchSha256) -and
      $source -match '(?s)candidate.*288864' -and
      $source -match '(?s)candidateSource.*24999' -and
      $source -match 'R19-HS-G1-D7-BENCHMARK-004\\20260915T114743494Z' -and
      $source.Contains('9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52') -and
      $source -match '(?s)rollback.*389280' -and
      $source.Contains('A939E28FE2FBB53E65E46F0246A4D71B9FD6C052EF0E046182DF4A4FE8BEC946') -and
      $source -match '(?s)esptool.*14323136' -and
      $pinText -match 'Assert-PinnedFile') `
      'candidate app/frozen source, R18 rollback, and staged esptool exact pins'

  Add-Check 'vehicle_identity_is_exact' (
      $source.Contains("port='COM3'") -and
      $source.Contains("vid='303A'") -and $source.Contains("pid='1001'") -and
      $source.Contains('USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000') -and
      $source.Contains('USB\VID_303A&PID_1001\90:70:69:11:81:A4') -and
      $source.Contains("mac='90:70:69:11:81:a4'")) `
      'COM3, VID/PID, interface PNP, parent identity, and efuse MAC'

  Add-Check 'flash_argv_is_app_only_and_fail_closed' (
      $safeArgvText -match "0x10000" -and
      $safeArgvText -match 'erase-flash|erase-all' -and
      $safeArgvText -match 'merged' -and
      $safeArgvText -match 'bootloader' -and
      $safeArgvText -match 'partitions' -and
      $safeArgvText -match 'exactly one application binary' -and
      $source -notmatch '(?im)^\s*&\s+.*erase-(flash|all)') `
      'one 0x10000 application image; destructive/full-image tokens rejected'

  Add-Check 'mission_planner_and_open_conflicts_are_refused' (
      $clientText -match 'missionplanner\.exe' -and
      $clientText -match 'COM3' -and
      $source -match 'Test-ExclusiveSerialOwnership' -and
      $source -match 'DtrEnable\s*=\s*\$false' -and
      $source -match 'RtsEnable\s*=\s*\$false') `
      'process inventory plus exclusive-open probe with reset lines disabled'

  Add-Check 'three_nonce_bound_runs_and_ready_gate' (
      $serialText -match 'for\s*\(\$runNumber\s*=\s*1;\s*\$runNumber\s*-le\s*3' -and
      $serialText -match 'Wait-BenchmarkReady' -and
      $readyText -match 'heartbeat_count' -and
      $readyText -match '\$count\s*-lt\s*2' -and
      $readyText -match 'heartbeat_last_gap_us' -and
      $readyText -match '\$lastGap\s*-le\s*2500000' -and
      $readyText -match '\$quiet\s*-lt\s*2000000' -and
      $readyText -match "parser_idle" -and
      $serialText -match 'START\s+\$nonce' -and
      $serialText -match 'START_ACK' -and
      $serialText -match '\[RESULT\]' -and
      $serialText -match 'serial\.raw\.bin' -and
      $serialText -match 'serial\.text\.log') `
      'READY/HB gate, exactly three generated nonces, raw and text capture'

  $printReadyMatch = [regex]::Match($sketch,
      '(?s)void\s+print_ready\s*\(\s*\)\s*\{(?<body>.*?)\n\}')
  $canonicalReadyBody = if ($printReadyMatch.Success) {
    $printReadyMatch.Groups['body'].Value
  } else {''}
  $ageIndex = $canonicalReadyBody.IndexOf(' heartbeat_age_us=',
      [StringComparison]::Ordinal)
  $quietIndex = $canonicalReadyBody.IndexOf(' indexed_quiet_age_us=',
      [StringComparison]::Ordinal)
  $lastGapIndex = $canonicalReadyBody.IndexOf(' heartbeat_last_gap_us=',
      [StringComparison]::Ordinal)
  $idleIndex = $canonicalReadyBody.IndexOf(' parser_idle=',
      [StringComparison]::Ordinal)
  $commandIndex = $canonicalReadyBody.IndexOf(' command=START <nonce>',
      [StringComparison]::Ordinal)
  $exactReadyRegex = '^\[READY\] protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2 role=vehicle uart=2 rx=D7 tx=D6 baud=57600 expected=932 heartbeat_count=(?<count>[0-9]+) heartbeat_age_us=(?<age>NA|[0-9]+) indexed_quiet_age_us=(?<quiet>[0-9]+) heartbeat_last_gap_us=(?<lastgap>NA|[0-9]+) parser_idle=(?<idle>[01]) command=START <nonce>$'
  Add-Check 'runner_ready_layout_matches_canonical_sketch' (
      $printReadyMatch.Success -and
      $canonicalReadyBody.Contains('print_protocol_prefix("[READY]")') -and
      $ageIndex -ge 0 -and $quietIndex -gt $ageIndex -and
      $lastGapIndex -gt $quietIndex -and $idleIndex -gt $lastGapIndex -and
      $commandIndex -gt $idleIndex -and
      $readyParserText.Contains($exactReadyRegex) -and
      $readyText -match 'Convert-StrictReadyLine') `
      'canonical sketch order is age, indexed quiet, last gap, parser idle, command'

  $setupMatch = [regex]::Match($sketch,
      '(?s)void\s+setup\s*\(\s*\)\s*\{(?<body>.*?)\n\}')
  $setupBody = if ($setupMatch.Success) {
    $setupMatch.Groups['body'].Value
  } else {''}
  $usbCommandHandlerMatch = [regex]::Match($sketch,
      '(?s)void\s+handle_usb_command\s*\([^)]*\)\s*\{(?<body>.*?)(?=\n\}\s*\n\s*void\s+service_usb\s*\()')
  $usbCommandHandlerBody = if ($usbCommandHandlerMatch.Success) {
    $usbCommandHandlerMatch.Groups['body'].Value
  } else {''}
  $readyCallCount = [regex]::Matches($sketch,
      '(?m)^\s*print_ready\s*\(\s*\)\s*;\s*$').Count
  Add-Check 'ready_is_status_driven_after_boot_drain' (
      $setupMatch.Success -and
      $setupBody.Contains('print_protocol_prefix("[BOOT]")') -and
      -not $setupBody.Contains('print_ready()') -and
      $usbCommandHandlerMatch.Success -and
      $usbCommandHandlerBody -match 'std::strcmp\s*\(\s*line\s*,\s*"STATUS"\s*\)\s*==\s*0(?s:.*?)print_ready\s*\(\s*\)' -and
      $readyCallCount -eq 1 -and
      $readyText -match '\$firstProtocolWait\s*=\s*-not\s+\[bool\]\$ProtocolState\.accepted_ready' -and
      $readyText -match '\$initialDrainMs\s*=\s*if\s*\(\$firstProtocolWait\)\s*\{\s*2000\s*\}\s*else\s*\{\s*500\s*\}' -and
      $readyText -match '\$bootCountBefore\s*=\s*\[int\]\$ProtocolState\.boot_count' -and
      $readyText -match '(?s)Register-ProtocolLine.*?\$firstProtocolWait.*?boot_count\s*-gt\s*\$bootCountBefore.*?\$nextStatus\s*=\s*\[DateTime\]::UtcNow\.AddMilliseconds\(500\)' -and
      $readyText -match '\$nextStatus\s*=\s*\[DateTime\]::UtcNow\.AddMilliseconds\(750\)') `
      'sole READY is STATUS-driven; first STATUS follows observed BOOT +500 ms or a 2000 ms fallback drain'

  Add-Check 'protocol_identity_gates_ready_ack_progress_result' (
      $protocolPrefixMatch.Success -and
      $protocolPrefixText.Contains('Serial.print(" protocol=")') -and
      $protocolPrefixText.Contains('Serial.print(kProtocolIdentity)') -and
      $sketch.Contains('print_protocol_prefix("[BOOT]");') -and
      $sketch.Contains('print_protocol_prefix("[READY]");') -and
      $sketch.Contains('print_protocol_prefix("[START_ACK]");') -and
      $sketch.Contains('print_protocol_prefix("[PROGRESS]");') -and
      $sketch.Contains('print_protocol_prefix("[RESULT]");') -and
      $sketch.Contains('Serial.println(" diagnostic=PIXHAWK_D7_PARAM_BENCHMARK_V2 mutation=none");') -and
      $protocolLineText -match 'PIXHAWK_D7_PARAM_BENCHMARK_V2' -and
      $readyParserText -match 'protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2' -and
      $ackParserText -match 'START_ACK.*protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2' -and
      $serialText -match 'Convert-StrictStartAckLine' -and
      $serialText -match 'Assert-ProgressProtocol' -and
      $progressParserText -match 'PROGRESS.*protocol=PIXHAWK_D7_PARAM_BENCHMARK_V2' -and
      $resultText -match "'protocol'" -and
      $resultText -match 'PIXHAWK_D7_PARAM_BENCHMARK_V2' -and
      $readyText -match 'Register-ProtocolLine' -and
      $serialText -notmatch 'Wait-BenchmarkBoot') `
      'self-identifying protocol is mandatory on every accepted machine record'

  Add-Check 'boot_is_optional_before_ready_and_fatal_after_protocol_lock' (
      $protocolLineText -match 'accepted_ready' -and
      $protocolLineText -match 'start_transmitted' -and
      $protocolLineText -match 'reboot' -and
      $protocolLineText -match 'boot_count' -and
      $readyText -match 'accepted_ready\s*=\s*\$true' -and
      $serialText -match 'start_transmitted\s*=\s*\$true') `
      'zero-or-one pre-ready BOOT is optional; later BOOT is immediate reboot failure'

  Add-Check 'start_retry_is_bounded_before_ack_only' (
      $serialText -match '\$startAttempt\s*-lt\s*3' -and
      $serialText -match 'AddSeconds\(15\)' -and
      $serialText -match 'heartbeat_not_ready\|heartbeat_stale\|heartbeat_pair_not_ready\|indexed_stream_not_quiet\|parser_not_idle\|uart_rx_pending\|uart_backpressure' -and
      $serialText -notmatch '\|uart_not_ready' -and
      $serialText -match '\$ackCount\s*-eq\s*0' -and
      $serialText -match 'Non-retryable START_REJECT' -and
      $serialText -match 'bounded pre-request START retries') `
      'only an unacknowledged readiness rejection can receive a bounded retry'

  Add-Check 'ready_wait_and_post_result_drain_reject_stray_records' (
      $readyText -match 'Assert-NoStrayRequestRecord' -and
      $strayRecordText -match 'START_ACK' -and
      $strayRecordText -match 'START_REJECT' -and
      $strayRecordText -match 'PROGRESS' -and
      $strayRecordText -match 'RESULT' -and
      $postResultDrainText -match '400' -and
      $postResultDrainText -match 'Register-ProtocolLine' -and
      $postResultDrainText -match 'Assert-NoStrayRequestRecord' -and
      $postResultDrainText -match 'LineBuffer\.Length\s*-eq\s*0' -and
      $serialText -match 'Assert-PostResultLineQuiet' -and
      $serialText -match 'post_result_quiet') `
      'READY waits reject delayed run records; every RESULT has a captured 400 ms quiet drain'

  $strictZeroFields = @(
    'missing','duplicate','out_of_order','out_of_range','wrong_source',
    'count_mismatch','bad_payload','crc_errors','bad_lengths',
    'unsupported_flags','noise_bytes')
  $allZeroFields = $true
  foreach ($field in $strictZeroFields) {
    if ($resultText -notmatch [regex]::Escape($field)) {
      $allZeroFields = $false
    }
  }
  Add-Check 'result_accounting_is_strict' (
      $allZeroFields -and
      $resultText -match "result.*PASS" -and
      $resultText -match "strict_932_and_post_heartbeat" -and
      $resultText -match 'data_result' -and
      $resultText -match 'heartbeat_result' -and
      $resultText -match 'heartbeatMaxGap\s*-le\s*2500000' -and
      $resultText -match 'statRuntimeExcluded' -and
      $resultText -match 'parameterFrames\s*-eq\s*932\s*\+\s*\$statRuntimeExcluded' -and
      $resultText -match 'target_10s_data_result' -and
      $resultText -match '\$target10\s*=\s*if' -and
      $resultText -notmatch 'target_10s_(?:data_)?result[^\r\n]{0,120}-ceq\s+''PASS''' -and
      $resultText -match 'request_writes' -and
      $resultText -match 'expected' -and
      $resultText -match 'unique' -and
      $resultText -match 'parameter_frames' -and
      $resultText -match '120000000') `
      '932 unique/exact frames, one request, every anomaly zero, <=120 s'

  Add-Check 'production_restore_is_outer_finally_mandatory' (
      $source -match '(?s)MEASUREMENT_OR_PREFLIGHT_FAIL_PENDING_RESTORE_DECISION.*?\}\s*finally\s*\{.*?Invoke-ProductionRestore.*?Complete-Evidence' -and
      $restoreText -match 'rollback' -and
      $restoreText -match "'write'" -and
      $restoreText -match "'verify'" -and
      $restoreText -match 'RestoreAttempted' -and
      $source -match 'FirmwareMayHaveChanged') `
      'R18 application write plus explicit verify is attempted after any candidate write'

  Add-Check 'new_high_speed_evidence_is_sealed' (
      $source -match 'runs\\high_speed\\R19-HS-G1-D7-DIRECT-HIL-001' -and
      $source -match 'Initialize-EvidenceRoot' -and
      $finalizeText -match 'summary\.json' -and
      $finalizeText -match 'artifact_manifest\.json' -and
      $finalizeText -match 'SHA256SUMS\.txt' -and
      $finalizeText -match 'final_seal\.json') `
      'new-run evidence confinement, summary, manifest, sums, and final seal'

  Add-Check 'runner_source_is_locked_and_rechecked' (
      $runnerLockText -match 'FileShare\]::Read' -and
      $runnerLockText -match 'RunnerStartSha256' -and
      $runnerLockText -match 'runner\.executed\.ps1' -and
      $runnerLockText -match 'RunnerStageSha256' -and
      $runnerPinText -match 'Get-Sha\s+\$PSCommandPath' -and
      $runnerStagePinText -match 'RunnerStagePath' -and
      $pinText -match 'Assert-PinnedFile' -and
      $source -match 'Assert-RunnerStagePinned\s+''production_restore_entry''' -and
      $finalizeText -match 'Assert-RunnerStagePinned' -and
      $finalizeText -match 'Get-RunnerSourceIntegrity' -and
      $runnerIntegrityText -match "result='FAIL'" -and
      $finalizeText -match 'runner_stage_sha256') `
      'runner is source-checked normally; restore/seal rely on its locked exact copy and record drift'

  Add-Check 'restore_uses_locked_stage_if_originals_drift' (
      $restoreText -match 'Assert-AllPinned\s+''before_production_restore''\s+\$true\s+\$false' -and
      $restoreText -match 'RecoveryMode' -and
      $capturedEspToolText -match 'RecoveryMode' -and
      $capturedEspToolText -match '-not\s+\$RecoveryMode\.IsPresent') `
      'mandatory restore remains possible from immutable stages after source drift'

  $restoreVerifiedIndex = $recoveryOrchestrationText.IndexOf(
      '$script:RestoreVerified = $true',[StringComparison]::Ordinal)
  $restoreMemoryRecordIndex = $recoveryOrchestrationText.IndexOf(
      '$hardwareVerified = $true',[StringComparison]::Ordinal)
  $restorePassEvidenceIndex = $recoveryOrchestrationText.IndexOf(
      '& $AttemptEvidenceWriter',[StringComparison]::Ordinal)
  Add-Check 'recovery_evidence_io_is_downstream_and_best_effort' (
      $recoveryCaptureText -match 'RedirectStandardOutput\s*=\s*\$true' -and
      $recoveryCaptureText -match 'RedirectStandardError\s*=\s*\$true' -and
      $recoveryCaptureText -match 'ReadToEndAsync' -and
      $recoveryCaptureText -match 'WaitForExit\(\$timeoutMilliseconds\)' -and
      $recoveryCaptureText -match '\$timeoutMilliseconds\s*=\s*60000' -and
      $recoveryCaptureText -match '\$stdoutTask\.Wait\(5000\)' -and
      $recoveryCaptureText -match '\$stderrTask\.Wait\(5000\)' -and
      $recoveryCaptureText -match 'capture_drain_timeout_5000ms' -and
      $recoveryCaptureText -match '\.Kill\(' -and
      $capturedEspToolText -match '(?s)RecoveryMode.*?Invoke-RecoveryEspToolMemoryCapture.*?Invoke-BestEffortEvidenceWrite' -and
      $flashStepText -match '(?s)RecoveryMode.*?Invoke-BestEffortEvidenceWrite.*?Invoke-CapturedEspTool' -and
      $flashStepText -match '(?s)FlashSteps\.Add.*?Invoke-BestEffortEvidenceWrite.*?record' -and
      $bestEffortWriteText -match "result='FAIL'" -and
      $restoreMemoryRecordIndex -ge 0 -and
      $restoreVerifiedIndex -gt $restoreMemoryRecordIndex -and
      $restorePassEvidenceIndex -gt $restoreVerifiedIndex -and
      $finalizeText -match 'RecoveryEvidenceFailures' -and
      $finalizeText -match 'FAIL_R18_PRODUCTION_RESTORED_EVIDENCE_INCOMPLETE' -and
      $source -match 'offline_injected_recovery_evidence_io_fault' -and
      $source -match 'PASS_CONTINUED' -and
      $source -match 'fail_then_verified_simulation' -and
      $source -match 'all_three_fail_simulation' -and
      $source -match '(?s)restoreVerifiedBeforeSimulation\s*=\s*\$script:RestoreVerified.*?\$script:RestoreVerified\s*=\s*\$false.*?Invoke-BoundedRecoveryOrchestration.*?-UpdateGlobalRestoreState.*?Assert-Condition.*?\$script:RestoreVerified.*?finally\s*\{.*?\$script:RestoreVerified\s*=\s*\$restoreVerifiedBeforeSimulation') `
      'recovery executes with memory capture; argv/log/record persistence faults are non-throwing'

  Add-Check 'all_esptool_invocations_are_process_bounded' (
      $capturedEspToolText -match '(?s)EspToolExecuted.*?Invoke-RecoveryEspToolMemoryCapture\s+\$Tokens.*?if\s*\(\$RecoveryMode\.IsPresent\)' -and
      $capturedEspToolText -notmatch '(?m)^\s*&\s+\$espTool' -and
      $capturedEspToolText -match '(?s)else\s*\{\s*Write-Durable\s+\$stdoutPath\s+\$stdoutText\s*Write-Durable\s+\$stderrPath\s+\$stderrText\s*Write-Durable\s+\$exitPath' -and
      $recoveryCaptureText -match '\$timeoutMilliseconds\s*=\s*60000' -and
      $recoveryCaptureText -match 'WaitForExit\(\$timeoutMilliseconds\)' -and
      $recoveryCaptureText -match 'capture_drain_timeout_5000ms') `
      'candidate write/verify and recovery all use bounded in-memory process capture; normal evidence stays fail-closed'

  Add-Check 'recovery_blocks_only_explicit_com3_and_records_all_attempts' (
      $recoveryConflictText -match 'explicit_com3_references' -and
      $recoveryConflictText -notmatch 'Assert-Condition\s+\(@\(\$snapshot\.known_serial_clients' -and
      $recoveryConflictText -match 'FAIL_CONTINUE_TO_COM3_CLAIM' -and
      $recoveryOrchestrationText -match 'for\s*\(\$attempt\s*=\s*1;\s*\$attempt\s*-le\s*\$MaxAttempts' -and
      $recoveryOrchestrationText -match '\$MaxAttempts\s*-eq\s*3' -and
      $restoreText -match 'MaxAttempts\s+3' -and
      $restoreText -match 'RestoreAttempts\.Add' -and
      $restoreText -match 'restore_attempt_.*\.json' -and
      $recoveryOrchestrationText -match "result='FAIL'" -and
      $recoveryOrchestrationText -match "result='PASS'" -and
      $finalizeText -match 'restore_attempts') `
      'running tools are inventory-only in recovery; every bounded attempt is durable'

  $baselineReadIndex = $source.IndexOf(
      "Invoke-FlashStep 1 'candidate_read_mac' 'read_mac'",
      [StringComparison]::Ordinal)
  $baselineVerifyIndex = $source.IndexOf(
      "Invoke-FlashStep 2 'baseline_r18_verify' 'verify' `$rollback",
      [StringComparison]::Ordinal)
  $candidateWriteIndex = $source.IndexOf(
      "Invoke-FlashStep 3 'candidate_write' 'write' `$candidate",
      [StringComparison]::Ordinal)
  Add-Check 'pinned_r18_is_verified_before_candidate_write' (
      $baselineReadIndex -ge 0 -and
      $baselineVerifyIndex -gt $baselineReadIndex -and
      $candidateWriteIndex -gt $baselineVerifyIndex) `
      'MAC then explicit R18 0x10000 verify must pass before candidate mutation'

  Add-Check 'offline_self_test_precedes_device_path' (
      $source -match '(?s)if\s*\(\$OfflineSelfTest\.IsPresent\).*?exit\s+0.*?# Live device path starts below' -and
      $source -match 'ready_v1_protocol' -and
      $source -match 'ready_missing_protocol' -and
      $source -match 'ready_wrong_order' -and
      $source -match 'result_missing_protocol' -and
      $source -match 'stray_result_during_ready' -and
      $source -match 'INJECTED_RECOVERY_EVIDENCE_IO_FAILURE' -and
      $source -match 'offlineExternalActions' -and
      $source -match 'DeviceAccessAttempted' -and
      $source -match 'EspToolExecuted' -and
      $source -match 'Offline self-test performed external action') `
      'offline mode exits before process/PnP/SerialPort/esptool execution'

  Add-Check 'terminal_failure_message_is_fully_formatted' (
      $source -match '(?s)throw\s*\(\(\s*"PIXHAWK D7 BENCHMARK HIL STOP status=\{0\} main=\{1\} restore=\{2\} ".*?"evidence=\{3\}"\s*\)\s*-f\s*\$script:Status\s*,\s*\$script:MainFailure\s*,\s*\$script:RestoreFailure\s*,\s*\$evidence\s*\)') `
      'the -f operator applies to the complete concatenated terminal failure template'
}

$failed = @($checks | Where-Object {-not $_.valid})
$summary = [ordered]@{
  schema_version=1
  checked_utc=[DateTime]::UtcNow.ToString('o')
  result=if ($failed.Count -eq 0) {'PASS'} else {'FAIL'}
  runner_path=$runnerPath
  check_count=$checks.Count
  failed_count=$failed.Count
  checks=@($checks)
  external_actions=[ordered]@{
    device_access_attempted=$false
    process_inventory_queried=$false
    pnp_queried=$false
    com_ports_enumerated=$false
    com_ports_opened=$false
    esptool_executed=$false
    firmware_write_attempted=$false
  }
}
$summaryPath = Join-Path $OutputDirectory 'summary.json'
[IO.File]::WriteAllText($summaryPath,
    (ConvertTo-Json -InputObject $summary -Depth 12) +
    [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))

if ($failed.Count -ne 0) {
  foreach ($failure in $failed) {
    Write-Error "CONTRACT FAIL: $($failure.name): $($failure.detail)"
  }
  exit 1
}
Write-Output ("PIXHAWK D7 PARAM BENCHMARK HIL RUNNER CONTRACT PASS " +
    "checks=$($checks.Count) evidence=$OutputDirectory")
exit 0
