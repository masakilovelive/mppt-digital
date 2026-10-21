[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$readerPath = Join-Path $repoRoot 'tools\read_r19_runtime_stage_jtag.ps1'
$nativeMockPath = Join-Path $repoRoot `
    'tests\hil\fixtures\mock_native_stderr_exit.ps1'
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
  param([string]$Name, [bool]$Passed, [string]$Detail)
  $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
}

function Get-PortableSha256 {
  param([Parameter(Mandatory)][string]$LiteralPath)
  $stream = [IO.File]::OpenRead($LiteralPath)
  try {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
      ([BitConverter]::ToString($algorithm.ComputeHash($stream)) -replace '-', '')
    } finally {
      $algorithm.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Invoke-Reader {
  param([string[]]$Arguments)
  $stdoutPath = Join-Path $script:tempRoot (([guid]::NewGuid().ToString('N')) + '.out')
  $stderrPath = Join-Path $script:tempRoot (([guid]::NewGuid().ToString('N')) + '.err')
  $argumentList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $readerPath
  ) + $Arguments
  $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList `
    -Wait -PassThru -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath
  [pscustomobject]@{
    ExitCode = $process.ExitCode
    Stdout = if (Test-Path -LiteralPath $stdoutPath) {
      Get-Content -LiteralPath $stdoutPath -Raw
    } else { '' }
    Stderr = if (Test-Path -LiteralPath $stderrPath) {
      Get-Content -LiteralPath $stderrPath -Raw
    } else { '' }
  }
}

function New-StageBytes {
  param(
    [uint32]$ActiveWriter = 0,
    [uint32]$Sequence = 24,
    [uint32]$Magic = 0x52313953,
    [uint32]$Schema = 1,
    [uint32]$Role = 2,
    [uint32]$StageMask = 0x7FFF,
    [uint32]$FirstFailure = 0,
    [uint32]$FirstFailureStageMask = 0,
    [uint32]$FirstFailureDetail = 0
  )
  [uint32[]]$words = @(
    $ActiveWriter, $Sequence, $Magic, $Schema, $Role,
    0x52313944, 0x53544731, 0x32303236, 0x31303033,
    $StageMask, 1, 11, 2, 3,
    $FirstFailure, $FirstFailureStageMask, $FirstFailureDetail
  )
  $bytes = [byte[]]::new(68)
  for ($index = 0; $index -lt $words.Count; ++$index) {
    [BitConverter]::GetBytes($words[$index]).CopyTo($bytes, $index * 4)
  }
  $bytes
}

function New-FifoBytes {
  param(
    [uint32]$ActiveWriter = 0,
    [uint32]$Sequence = 40,
    [uint32]$Magic = 0x48313946,
    [uint32]$Schema = 2,
    [uint32]$Flags = 0x0000000F,
    [uint32]$TxLossEpoch = 2,
    [uint32]$FifoWriteAttemptCount = 2,
    [uint32]$FifoWriteBytes = 64,
    [uint32]$FifoZeroWriteCount = 0,
    [uint32]$LastFifoWriteSize = 32,
    [uint32]$WrDoneCount = 3,
    [uint32]$InEmptyIrqCount = 2,
    [uint32]$PayloadInEmptyCount = 2,
    [uint32]$PublishGeneration = 2,
    [uint32]$PickupGeneration = 2,
    [uint32]$BusResetCount = 0,
    [uint32]$FlushAttemptCount = 2,
    [uint32]$FlushSuccessCount = 2,
    [uint32]$FlushTimeoutCount = 0,
    [uint32]$ZlpFlushCount = 1,
    [uint32]$LastRingPendingBytes = 0,
    [uint32]$LastStashPendingBytes = 0,
    [uint32]$LastInterruptStatus = 0x80,
    [uint32]$LastFlushBlockerMask = 0,
    [uint32]$LastFlushOutcome = 2,
    [uint32]$LastFlushTaskZlpCount = 1,
    [uint32]$LastFlushIsrZlpCount = 0,
    [uint32]$LastFlushTerminalBlockerMask = 0
  )
  [uint32[]]$words = @(
    $ActiveWriter, $Sequence, $Magic, $Schema, $Flags, $TxLossEpoch,
    $FifoWriteAttemptCount, $FifoWriteBytes, $FifoZeroWriteCount,
    $LastFifoWriteSize, $WrDoneCount, $InEmptyIrqCount,
    $PayloadInEmptyCount, $PublishGeneration, $PickupGeneration,
    $BusResetCount, $FlushAttemptCount, $FlushSuccessCount,
    $FlushTimeoutCount, $ZlpFlushCount, $LastRingPendingBytes,
    $LastStashPendingBytes, $LastInterruptStatus, $LastFlushBlockerMask,
    $LastFlushOutcome, $LastFlushTaskZlpCount, $LastFlushIsrZlpCount,
    $LastFlushTerminalBlockerMask
  )
  $bytes = [byte[]]::new(112)
  for ($index = 0; $index -lt $words.Count; ++$index) {
    [BitConverter]::GetBytes($words[$index]).CopyTo($bytes, $index * 4)
  }
  $bytes
}

function Write-Fixture {
  param(
    [string]$Path,
    [byte[]]$StageFirst,
    [byte[]]$StageSecond,
    [byte[]]$FifoFirst = (New-FifoBytes),
    [byte[]]$FifoSecond = $FifoFirst,
    [string]$Role = 'vehicle'
  )
  [ordered]@{
    schema = 'vc-lora-r19-runtime-stage-jtag-fixture-v3'
    artifact_id = 'offline-fixture'
    role = $Role
    runtime_stage_address = '0x3fcab470'
    endpoint_fifo_address = '0x3fcab4b4'
    runtime_stage_first_read_base64 = [Convert]::ToBase64String($StageFirst)
    runtime_stage_second_read_base64 = [Convert]::ToBase64String($StageSecond)
    endpoint_fifo_first_read_base64 = [Convert]::ToBase64String($FifoFirst)
    endpoint_fifo_second_read_base64 = [Convert]::ToBase64String($FifoSecond)
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('vc-lora-jtag-reader-contract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
  Add-Check 'reader_exists' (Test-Path -LiteralPath $readerPath -PathType Leaf) $readerPath
  if (-not (Test-Path -LiteralPath $readerPath -PathType Leaf)) {
    throw "missing reader: $readerPath"
  }

  $source = Get-Content -LiteralPath $readerPath -Raw
  Add-Check 'execute_is_explicit_switch' ($source -match '\[switch\]\$Execute') 'live mode must require -Execute'
  Add-Check 'live_requires_exact_role' ($source -match '\[ValidateSet\(''ground'',\s*''vehicle''\)\]') 'role must be exact'
  Add-Check 'live_requires_exact_address' (
    $source -match "'Role',\s*'Address',\s*'ArtifactRoot'") 'address is mandatory in live mode'
  Add-Check 'live_requires_artifact_binding' ($source -match 'Assert-ArtifactBinding') 'sealed artifact binding is mandatory'
  Add-Check 'symbol_derived_from_sealed_elf_by_nm' (
    $source -match 'NmExecutable' -and
    $source -match "'-S'\s*'--defined-only'" -and
    $source -match "vc_lora_r19_runtime_stage_record" -and
    $source -match "vc_lora_r19_hwcdc_fifo_diagnostic_record") `
      'nm must prove both exact symbol addresses and sizes'
  Add-Check 'sealed_elf_symbols_are_unique_sized_aligned_and_disjoint' (
    $source -match 'stageSymbolMatches\.Count\s*-ne\s*1' -and
    $source -match 'fifoSymbolMatches\.Count\s*-ne\s*1' -and
    $source -match 'stageSymbolSize\s*-ne\s*0x44' -and
    $source -match 'fifoSymbolSize\s*-ne\s*0x70' -and
    $source -match 'stageSymbolAddress\s*-band\s*3' -and
    $source -match 'fifoSymbolAddress\s*-band\s*3' -and
    $source -match 'diagnostic symbols overlap') `
      'sealed ELF must contain one aligned 68-byte stage and one aligned 112-byte FIFO schema-2 record at disjoint addresses'
  Add-Check 'toolchain_paths_and_hashes_are_pinned' (
    $source -match 'PinnedOpenOcdSha256' -and
    $source -match 'PinnedNmSha256' -and
    $source -match 'PinnedOpenOcdScriptsTreeSha256' -and
    $source -match 'Assert-PinnedToolchain') 'caller-supplied tools/configs must not self-authorize'
  Add-Check 'live_requires_exact_flash_binding' (
    $source -match 'Assert-FlashBinding' -and
    $source -match 'vc-lora-r19-candidate-flash-evidence-v1' -and
    $source -notmatch 'vc-lora-r19-app-readback-evidence-v1') 'real installer flash evidence is mandatory'
  Add-Check 'live_requires_unique_probe_binding' (
    $source -match 'allMacs' -and
    $source -match 'ExpectedProbeSerial') 'unique role/probe evidence is mandatory'
  Add-Check 'no_com_api' ($source -notmatch 'System\.IO\.Ports|SerialPort|Get-CimInstance\s+Win32_SerialPort') 'reader must never open or enumerate COM'
  Add-Check 'no_flash_tool' (
    $source -notmatch 'esptool|write_flash' -and
    $source -notmatch "(?i)-c',\s*'(program|flash|erase)") 'reader must never write flash'
  Add-Check 'no_target_restart_command' ($source -notmatch '(?im)["'']\s*(reset|soft_reset_halt|hard_reset)[;\s"'']') 'reader must not issue target restart commands'
  Add-Check 'halt_then_stable_paired_reads' (
    $source -match '(?s)halt.*dump_image.*stageFirstPath.*dump_image.*fifoFirstPath.*dump_image.*stageSecondPath.*dump_image.*fifoSecondPath') `
      'both records must be read twice while both CPUs are halted'
  Add-Check 'finally_cleanup' (
    $source -match '(?s)finally\s*\{.*Invoke-OpenOcdCleanup') 'finally must attempt resume/shutdown cleanup'
  Add-Check 'cleanup_blocked_when_capture_termination_unproven' (
    $source -match '(?s)finally\s*\{.{0,900}?captureNative\.termination_proven.{0,900}?Invoke-OpenOcdCleanup.{0,900}?skipped_due_to_unproven_capture_termination') `
      'a second OpenOCD must not start while the capture process may still own the probe'
  Add-Check 'native_process_streams_are_redirected_without_native_error_pipeline' (
    $source -match 'function\s+Invoke-NativeProcessCapture' -and
    $source -match 'RedirectStandardOutput\s*=\s*\$true' -and
    $source -match 'RedirectStandardError\s*=\s*\$true' -and
    $source -notmatch '&\s+\$OpenOcdExecutable[\s\S]{0,300}?2>&1' -and
    $source -notmatch '&\s+\$Executable[\s\S]{0,300}?2>&1') `
      'OpenOCD stderr must be captured as data, not converted to a PowerShell NativeCommandError'
  Add-Check 'native_process_true_exit_and_timeout_are_explicit' (
    $source -match 'WaitForExit\(\$TimeoutMilliseconds\)' -and
    $source -match '\$process\.ExitCode' -and
    $source -match 'timed_out' -and
    $source -match '\$exitCode\s*=\s*124') `
      'native exit code and bounded timeout must be observed directly from the process'
  Add-Check 'openocd_logs_are_decoded_as_utf8' (
    $source -match
      '\[IO\.File\]::ReadAllText\(\s*\$LiteralPath,\s*\[Text\.UTF8Encoding\]::new\(\$false\)\)') `
      'OpenOCD marker logs must use explicit UTF-8 decoding under Windows PowerShell'
  Add-Check 'cleanup_success_required_for_pass' (
    $source -match 'resume_shutdown_cleanup_proven' -and
    $source -match 'cleanup\.exit_code\s*-ne\s*0' -and
    $source -match 'target_may_be_halted' -and
    $source -match 'native_processes_termination_proven') `
      'PASS requires cleanup plus termination proof; target and process risks must be separate'
  Add-Check 'smp_halt_resume_log_proof_required' (
    $source -match 'Assert-SmpCaptureLog' -and
    $source -match
      'VC_LORA_HALT_CURSTATE_CPU0=\[esp32s3\.cpu0 curstate\]' -and
    $source -match
      'VC_LORA_HALT_CURSTATE_CPU1=\[esp32s3\.cpu1 curstate\]' -and
    $source -match
      'VC_LORA_RESUME_CURSTATE_CPU0=\[esp32s3\.cpu0 curstate\]' -and
    $source -match
      'VC_LORA_RESUME_CURSTATE_CPU1=\[esp32s3\.cpu1 curstate\]') `
      'both ESP32-S3 cores must have exact halted and running curstate proof'
  Add-Check 'resume_proof_uses_exact_per_core_curstate' (
    $source -match 'function\s+Assert-SmpCurstate' -and
    $source -match 'function\s+Assert-SmpHaltedCurstate' -and
    $source -match 'function\s+Assert-SmpRunningCurstate' -and
    $source -match 'state\s+-cne\s+\$ExpectedState' -and
    $source -match 'marker count' -and
    $source -match
      '(?s)function\s+Get-OpenOcdLogStage.*Assert-SmpRunningCurstate') `
      'halt/resume proof must require one exact curstate marker per core'
  Add-Check 'mid_write_snapshot_retries_after_resume' (
    $source -match 'Test-TransientSnapshotError' -and
    $source -match '\$attempt\s*-le\s*3' -and
    $source -match 'RETRY_AFTER_RESUME') 'mid-write halt must resume before bounded retry'
  Add-Check 'stable_writer_contract' (
    $source -match '\$firstWords\[0\]\s*-ne\s*0' -and
    $source -match '\$firstWords\[1\]\s*-band\s*1' -and
    $source -match '\$firstWords\[1\]\s*-ne\s*\$secondWords\[1\]') 'active writer zero and equal even sequence required'
  Add-Check 'fifo_decoder_has_fail_closed_abi_invariants' (
    $source -match '0x48313946' -and
    $source -match 'WordCount\s+28' -and
    $source -match 'firstWords\[3\]\s*-ne\s*2' -and
    $source -match '0x00003FFF' -and
    $source -match '0x000000FF' -and
    $source -match 'payload IN_EMPTY count exceeds raw IN_EMPTY count' -and
    $source -match 'ZLP flush count exceeds wr_done count' -and
    $source -match 'zero-write count exceeds FIFO write attempt count' -and
    $source -match
      'payload IN_EMPTY count exceeds non-ZLP wr_done count' -and
    $source -match
      'non-ZLP wr_done count exceeds positive FIFO write attempt count' -and
    $source -match
      'PayloadPublishPending requires an unmatched[\s\S]*positive FIFO write' -and
    $source -match 'payload-in-flight flag disagrees with generation relationship' -and
    $source -match 'flush success count or timeout count exceeds flush attempt count' -and
    $source -match 'flush terminal and active counts exceed flush attempt count' -and
    $source -match 'flush_abort_inferred' -and
    $source -match 'FlushActive' -and
    $source -match 'PayloadPublishPending' -and
    $source -match 'PayloadPublishAborted' -and
    $source -match 'PayloadFlushPending' -and
    $source -match 'PayloadInFlight requires PayloadFlushPending' -and
    $source -match
      'PayloadPublishAborted is mutually exclusive with' -and
    $source -match 'last FIFO write size exceeds 32 bytes' -and
    $source -match 'last flush outcome is unknown' -and
    $source -match 'last flush outcome disagrees with FlushActive' -and
    $source -match 'last flush terminal blocker mask contains unknown bits' -and
    $source -match 'last flush ZLP count exceeds cumulative ZLP count') `
      'FIFO decoder must reject malformed or contradictory records'
  Add-Check 'summary_schema_and_endpoint_fifo_are_v3' (
    $source -match 'vc-lora-r19-runtime-stage-jtag-fixture-v3' -and
    $source -match 'vc-lora-r19-runtime-stage-jtag-read-v3' -and
    $source -match '\[''endpoint_fifo''\]\s*=\s*\$fifo' -and
    $source -match 'usb_tx_boundary_classification' -and
    $source -match 'last_flush_outcome' -and
    $source -match 'last_flush_task_zlp_count' -and
    $source -match 'last_flush_isr_zlp_count' -and
    $source -match 'last_flush_terminal_blocker_mask' -and
    $source -match 'last_flush_classification') `
      'v3 fixture/read summaries must expose decoded schema-2 Endpoint FIFO evidence'
  Add-Check 'short_packet_success_policy_is_explicit_and_history_compatible' (
    $source -match 'success-with-short-packet-no-zlp' -and
    $source -match 'successful flush lacks task-origin final ZLP' -and
    $source -match 'success-with-task-zlp') `
      '1..63-byte final packets may complete without ZLP; unknown/full evidence remains strict and historical task-ZLP evidence remains readable'
  Add-Check 'generation_fingerprint_validated' (
    $source -match '0x52313944' -and $source -match 'diagnostic generation fingerprint') 'fixed diagnostic generation marker required'
  Add-Check 'conditional_setup_bits_not_mandatory' (
    $source -match 'conditional_setup_witnesses' -and
    $source -match 'IdentityReady' -and $source -match 'E220ProfileChecked') 'conditional setup witnesses must be separate'
  $groundReasonVocabularyPresent = $true
  foreach ($reasonName in @(
      'GroundBoundaryHostLostWhileDraining',
      'GroundBoundaryHostAbsentWithIrreversiblePrefix',
      'GroundBoundaryEpochChanged',
      'GroundBoundaryDeadlineExpired',
      'GroundBoundaryOrderedBacklogDiscardFailed',
      'GroundBoundaryHeldHeartbeatDiscardFailed',
      'GroundBoundaryEgressPumpInvalid',
      'GroundBoundaryFlushFailed',
      'GroundBoundaryFlushEpochChanged',
      'GroundBoundaryFlushLate')) {
    $groundReasonVocabularyPresent = $groundReasonVocabularyPresent -and
      $source.IndexOf("'$reasonName'", [StringComparison]::Ordinal) -ge 0
  }
  Add-Check 'ground_boundary_leaf_reason_vocabulary_is_complete' `
      $groundReasonVocabularyPresent `
      'reader must append all ten branch-specific Ground boundary reasons without renumbering existing reasons'

  Add-Check 'preflight_requires_explicit_execute_and_usb_location' (
    $source -match '\[switch\]\$Preflight' -and
    $source -match '\[string\]\$ProbeUsbLocation' -and
    $source -match "Preflight requires the explicit -Execute switch" -and
    $source -match "'Role',\s*'ProbeSerial',\s*'ProbeUsbLocation'") `
      'live JTAG preflight must be explicit and bind role, serial, and USB location'

  $readerTokens=$null;$readerParseErrors=$null
  $readerAst=[Management.Automation.Language.Parser]::ParseFile(
      $readerPath,[ref]$readerTokens,[ref]$readerParseErrors)
  $preflightFunctions=@($readerAst.FindAll({param($node)
      $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
      $node.Name-ceq'Invoke-JtagPreflight'},$true))
  $preflightContract=$false
  if(@($readerParseErrors).Count-eq0-and$preflightFunctions.Count-eq1){
    $preflightText=$preflightFunctions[0].Extent.Text
    $serialBindingIndex=$preflightText.IndexOf(
      'adapter serial $ProbeSerial',[StringComparison]::Ordinal)
    $locationBindingIndex=$preflightText.IndexOf(
      'adapter usb location $ProbeUsbLocation',[StringComparison]::Ordinal)
    $transportInitIndex=$preflightText.IndexOf(
      "'-c', 'transport init'",[StringComparison]::Ordinal)
    $preflightContract=(
      $preflightText-match 'adapter serial \$ProbeSerial' -and
      $preflightText-match 'adapter usb location \$ProbeUsbLocation' -and
      $preflightText-match "'-c',\s*'transport init'" -and
      $preflightText-match 'espusbjtag get_serial' -and
      $preflightText-match 'espusbjtag get_location' -and
      $preflightText-notmatch "'-f'.*TargetConfig" -and
      $preflightText-notmatch '(?im)["'']\s*(halt|reset|soft_reset_halt|hard_reset)\b' -and
      $serialBindingIndex-ge0-and$serialBindingIndex-lt$transportInitIndex-and
      $locationBindingIndex-ge0-and$locationBindingIndex-lt$transportInitIndex)
  }
  Add-Check 'preflight_binds_serial_and_location_before_transport_init' `
      $preflightContract `
      'preflight must bind serial and USB location before transport init, omit target cfg, and issue no CPU halt/system reset command'

  Add-Check 'preflight_checks_opened_serial_and_location' (
    $source -match 'Assert-JtagPreflightLog' -and
    $source -match 'VC_LORA_JTAG_OPEN_SERIAL' -and
    $source -match 'VC_LORA_JTAG_OPEN_LOCATION' -and
    $source -match 'ExpectedProbeSerial' -and
    $source -match 'ExpectedUsbLocation') `
      'post-open serial and USB location must both match the requested role binding'

  Add-Check 'preflight_discloses_transport_init_tap_state_risk' (
    $source -match
      'PASS_JTAG_PREFLIGHT_TAP_RESET_SCAN_POSSIBLE_NO_CPU_HALT_OR_SYSTEM_RESET_COMMAND' -and
    $source -notmatch 'PASS_JTAG_PREFLIGHT_NO_RESET_NO_HALT' -and
    $source -match 'VC_LORA_JTAG_TRANSPORT_INIT_REQUESTED' -and
    $source -match 'VC_LORA_JTAG_TRANSPORT_INIT_COMPLETED' -and
    $source -match
      'VC_LORA_JTAG_PREFLIGHT_POLICY=TAP_INIT_POSSIBLE_NO_TARGET_CONFIG_NO_CPU_HALT_NO_SYSTEM_RESET_COMMAND' -and
    $source -match 'transport_init_requested\s*=\s*\$true' -and
    $source -match 'transport_init_completion_proven\s*=\s*\$true' -and
    $source -match 'jtag_clock_activity_possible\s*=\s*\$true' -and
    $source -match 'tap_reset_or_scan_possible\s*=\s*\$true' -and
    $source -match 'cpu_halt_command_issued\s*=\s*\$false' -and
    $source -match 'system_reset_command_issued\s*=\s*\$false' -and
    $source -match 'target_state_modified\s*=\s*\$null' -and
    $source -match
      'transport init can clock, initialize, reset, or scan the JTAG TAP') `
      'preflight must disclose TAP-state risk without claiming no reset/state change'

  Add-Check 'preflight_pass_requires_shutdown_and_process_termination' (
    $source -match 'shutdown_proven' -and
    $source -match 'process_termination_proven' -and
    $source -match 'target_config_loaded\s*=\s*\$false' -and
    $source -match 'cpu_halt_command_issued\s*=\s*\$false' -and
    $source -match 'system_reset_command_issued\s*=\s*\$false') `
      'preflight PASS must prove shutdown and process termination and issue no CPU halt/system reset command'

  # Byte-for-byte fixture from the Vehicle preflight evidence captured at
  # runs/hil/R19-ACTIVE-JTAG-PREFLIGHT-001/
  # 20261004T162202635Z-vehicle/openocd-preflight.log.  OpenOCD emitted CRLF.
  $crlfPreflightLogBase64 = 'PT09IFNURE9VVCA9PT0NCg0KPT09IFNUREVSUiA9PT0NCk9wZW4gT24tQ2hpcCBEZWJ1Z2dlciB2MC4xMi4wLWVzcDMyLTIwMjYwNDI0ICgyMDI2LTA0LTI0LTE1OjEzKQ0KTGljZW5zZWQgdW5kZXIgR05VIEdQTCB2Mg0KRm9yIGJ1ZyByZXBvcnRzLCByZWFkDQoJaHR0cDovL29wZW5vY2Qub3JnL2RvYy9kb3h5Z2VuL2J1Z3MuaHRtbA0KSW5mbyA6IGVzcF91c2JfanRhZzogVklEIHNldCB0byAweDMwM2EgYW5kIFBJRCB0byAweDEwMDENCkluZm8gOiBlc3BfdXNiX2p0YWc6IGNhcGFiaWxpdGllcyBkZXNjcmlwdG9yIHNldCB0byAweDIwMDANCmFkYXB0ZXIgdXNiIGxvY2F0aW9uOiAxLTQuMg0KVkNfTE9SQV9KVEFHX1BSRUZMSUdIVF9QT0xJQ1k9VEFQX0lOSVRfUE9TU0lCTEVfTk9fVEFSR0VUX0NPTkZJR19OT19DUFVfSEFMVF9OT19TWVNURU1fUkVTRVRfQ09NTUFORA0KVkNfTE9SQV9KVEFHX1RSQU5TUE9SVF9JTklUX1JFUVVFU1RFRA0KSW5mbyA6IGVzcF91c2JfanRhZzogc2VyaWFsICg5MDo3MDo2OToxMTo4MTpBNCkNCkluZm8gOiBlc3BfdXNiX2p0YWc6IERldmljZSBmb3VuZC4gQmFzZSBzcGVlZCA0MDAwMEtIeiwgZGl2IHJhbmdlIDEgdG8gMjU1DQpJbmZvIDogY2xvY2sgc3BlZWQgNDAwMDAga0h6DQpXYXJuIDogVGhlcmUgYXJlIG5vIGVuYWJsZWQgdGFwcy4gIEFVVE8gUFJPQklORyBNSUdIVCBOT1QgV09SSyEhDQpJbmZvIDogSlRBRyB0YXA6IGF1dG8wLnRhcCB0YXAvZGV2aWNlIGZvdW5kOiAweDEyMDAzNGU1IChtZmc6IDB4MjcyIChUZW5zaWxpY2EpLCBwYXJ0OiAweDIwMDMsIHZlcjogMHgxKQ0KSW5mbyA6IEpUQUcgdGFwOiBhdXRvMS50YXAgdGFwL2RldmljZSBmb3VuZDogMHgxMjAwMzRlNSAobWZnOiAweDI3MiAoVGVuc2lsaWNhKSwgcGFydDogMHgyMDAzLCB2ZXI6IDB4MSkNCldhcm4gOiBBVVRPIGF1dG8wLnRhcCAtIHVzZSAianRhZyBuZXd0YXAgYXV0bzAgdGFwIC1pcmxlbiA1IC1leHBlY3RlZC1pZCAweDEyMDAzNGU1Ig0KV2FybiA6IEFVVE8gYXV0bzEudGFwIC0gdXNlICJqdGFnIG5ld3RhcCBhdXRvMSB0YXAgLWlybGVuIDUgLWV4cGVjdGVkLWlkIDB4MTIwMDM0ZTUiDQpWQ19MT1JBX0pUQUdfVFJBTlNQT1JUX0lOSVRfQ09NUExFVEVEDQpWQ19MT1JBX0pUQUdfT1BFTl9TRVJJQUw9OTA6NzA6Njk6MTE6ODE6QTQNClZDX0xPUkFfSlRBR19PUEVOX0xPQ0FUSU9OPTEtNC4yDQpWQ19MT1JBX0pUQUdfUFJFRkxJR0hUX09QRU4NCnNodXRkb3duIGNvbW1hbmQgaW52b2tlZA0K'
  $crlfPreflightBytes = [Convert]::FromBase64String($crlfPreflightLogBase64)
  $crlfPreflightPath = Join-Path $tempRoot 'vehicle-preflight-real-crlf.log'
  [IO.File]::WriteAllBytes($crlfPreflightPath, $crlfPreflightBytes)
  $crlfFixtureIntegrity = (
    $crlfPreflightBytes.Length -eq 1257 -and
    (Get-PortableSha256 -LiteralPath $crlfPreflightPath) -ceq
      '933F64AB1C92372C04C182722FFE8D43104D51C630171DEFF94961C14A289D0E' -and
    ([Text.UTF8Encoding]::new($false).GetString($crlfPreflightBytes) -match
      "VC_LORA_JTAG_PREFLIGHT_OPEN`r`nshutdown command invoked`r`n"))
  Add-Check 'real_preflight_crlf_fixture_integrity' $crlfFixtureIntegrity `
      'captured Vehicle OpenOCD log must remain byte-identical CRLF evidence'

  $preflightLogFunctions=@($readerAst.FindAll({param($node)
      $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
      $node.Name-ceq'Assert-JtagPreflightLog'},$true))
  $crlfPreflightProof=$false
  if(@($readerParseErrors).Count-eq0-and$preflightLogFunctions.Count-eq1){
    . ([scriptblock]::Create($preflightLogFunctions[0].Extent.Text))
    try {
      $proof=Assert-JtagPreflightLog -LiteralPath $crlfPreflightPath `
        -ExpectedProbeSerial '90:70:69:11:81:A4' `
        -ExpectedUsbLocation '1-4.2'
      $crlfPreflightProof=(
        [bool]$proof.open_marker_proven-and
        [bool]$proof.transport_init_requested_proven-and
        [bool]$proof.transport_init_completed_proven-and
        [bool]$proof.shutdown_proven)
    } catch {}
  }
  Add-Check 'real_preflight_crlf_markers_are_accepted' $crlfPreflightProof `
      'line-anchored marker parsing must accept OpenOCD CRLF output'

  $stageReadFunctions=@($readerAst.FindAll({param($node)
      $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
      $node.Name-ceq'Read-LiveStageRecord'},$true))
  $stageReadLocationContract=$false
  if(@($readerParseErrors).Count-eq0-and$stageReadFunctions.Count-eq1){
    $stageReadText=$stageReadFunctions[0].Extent.Text
    $identityMarkerIndex=$stageReadText.IndexOf(
      "'-c', 'echo VC_LORA_JTAG_IDENTITY_MATCHED'",
      [StringComparison]::Ordinal)
    $haltCommandIndex=$stageReadText.IndexOf(
      "'-c', 'halt'", [StringComparison]::Ordinal)
    $stageReadLocationContract=(
      $stageReadText-match 'adapter usb location \$ProbeUsbLocation' -and
      $stageReadText-notmatch 'adapter serial \$ProbeSerial' -and
      $stageReadText-match 'espusbjtag get_serial' -and
      $stageReadText-match 'espusbjtag get_location' -and
      $stageReadText-match 'VC_LORA_JTAG_SERIAL_MISMATCH' -and
      $stageReadText-match 'VC_LORA_JTAG_LOCATION_MISMATCH' -and
      $identityMarkerIndex-ge0-and$haltCommandIndex-gt$identityMarkerIndex)
  }
  Add-Check 'stage_read_uses_location_and_proves_identity_before_halt' `
      $stageReadLocationContract `
      'stage read must bind USB location and verify opened serial/location before halt'
  Add-Check 'stage_read_live_parameters_require_usb_location' (
    $source -match "'ProbeSerial',\s*'ProbeUsbLocation',\s*'FlashEvidencePath'" -and
    $source -match 'Assert-ProbeBindingSyntax\s*\r?\n\s*Assert-PinnedToolchain') `
      'full live stage read must require validated USB location'
  Add-Check 'capture_log_identity_is_part_of_dump_proof' (
    $source -match 'function\s+Assert-SmpCaptureLog' -and
    $source -match 'opened JTAG identity was not proven before halt' -and
    $source -match 'ExpectedProbeSerial' -and
    $source -match 'ExpectedUsbLocation') `
      'capture proof must reject absent, mismatched, or post-halt identity markers'

  $captureLogProofFunctions=@($readerAst.FindAll({param($node)
      $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
      $node.Name-in@('Assert-SmpCurstate','Assert-SmpHaltedCurstate',
        'Assert-SmpRunningCurstate','Assert-SmpCaptureLog',
        'Assert-SmpCleanupLog')},$true))
  $validCaptureProof=$false
  $mismatchedCaptureRejected=$false
  $lateIdentityRejected=$false
  $legacyGenericHaltedRejected=$false
  $wrongHaltCurstateRejected=$false
  $legacyGenericRunningRejected=$false
  $alreadyRunningCleanupProof=$false
  $haltedCleanupRejected=$false
  $unknownCleanupRejected=$false
  $missingCleanupRejected=$false
  $duplicateCleanupRejected=$false
  if(@($readerParseErrors).Count-eq0-and$captureLogProofFunctions.Count-eq5){
    foreach($functionAst in $captureLogProofFunctions){
      . ([scriptblock]::Create($functionAst.Extent.Text))
    }
    $captureProofPath=Join-Path $tempRoot 'capture-proof.log'
    $validCaptureLog=@'
VC_LORA_JTAG_OPEN_SERIAL=90:70:69:11:81:A4
VC_LORA_JTAG_OPEN_LOCATION=1-2.3
VC_LORA_JTAG_IDENTITY_MATCHED
VC_LORA_HALT_CPU0
VC_LORA_HALT_CURSTATE_CPU0=halted
VC_LORA_HALT_CPU1
VC_LORA_HALT_CURSTATE_CPU1=halted
VC_LORA_RESUME_CPU0
VC_LORA_RESUME_CURSTATE_CPU0=running
VC_LORA_RESUME_CPU1
VC_LORA_RESUME_CURSTATE_CPU1=running
shutdown command invoked
'@
    [IO.File]::WriteAllText(
      $captureProofPath,$validCaptureLog,[Text.UTF8Encoding]::new($false))
    try {
      Assert-SmpCaptureLog -LiteralPath $captureProofPath `
        -ExpectedProbeSerial '90:70:69:11:81:A4' `
        -ExpectedUsbLocation '1-2.3'
      $validCaptureProof=$true
    } catch {}
    try {
      Assert-SmpCaptureLog -LiteralPath $captureProofPath `
        -ExpectedProbeSerial '1C:DB:D4:5A:83:80' `
        -ExpectedUsbLocation '1-2.3'
    } catch {
      $mismatchedCaptureRejected=$_.Exception.Message-match
        'serial does not match'
    }
    $lateCaptureLog=$validCaptureLog -replace
      'VC_LORA_JTAG_IDENTITY_MATCHED\r?\nVC_LORA_HALT_CPU0',
      "VC_LORA_HALT_CPU0`r`nVC_LORA_JTAG_IDENTITY_MATCHED"
    [IO.File]::WriteAllText(
      $captureProofPath,$lateCaptureLog,[Text.UTF8Encoding]::new($false))
    try {
      Assert-SmpCaptureLog -LiteralPath $captureProofPath `
        -ExpectedProbeSerial '90:70:69:11:81:A4' `
        -ExpectedUsbLocation '1-2.3'
    } catch {
      $lateIdentityRejected=$_.Exception.Message-match
        'identity was not proven before halt'
    }

    $legacyHaltLog=$validCaptureLog -replace
      'VC_LORA_HALT_CURSTATE_CPU0=halted','target halted' -replace
      'VC_LORA_HALT_CURSTATE_CPU1=halted','target halted'
    [IO.File]::WriteAllText(
      $captureProofPath,$legacyHaltLog,[Text.UTF8Encoding]::new($false))
    try {
      Assert-SmpCaptureLog -LiteralPath $captureProofPath `
        -ExpectedProbeSerial '90:70:69:11:81:A4' `
        -ExpectedUsbLocation '1-2.3'
    } catch {
      $legacyGenericHaltedRejected=$_.Exception.Message-match
        'HALT.*curstate.*marker count'
    }

    $wrongHaltLog=$validCaptureLog -replace
      'VC_LORA_HALT_CURSTATE_CPU1=halted',
      'VC_LORA_HALT_CURSTATE_CPU1=running'
    [IO.File]::WriteAllText(
      $captureProofPath,$wrongHaltLog,[Text.UTF8Encoding]::new($false))
    try {
      Assert-SmpCaptureLog -LiteralPath $captureProofPath `
        -ExpectedProbeSerial '90:70:69:11:81:A4' `
        -ExpectedUsbLocation '1-2.3'
    } catch {
      $wrongHaltCurstateRejected=$_.Exception.Message-match
        'CPU1.*HALT.*expected halted.*running'
    }

    $legacyCaptureLog=$validCaptureLog -replace
      'VC_LORA_RESUME_CURSTATE_CPU0=running','target running' -replace
      'VC_LORA_RESUME_CURSTATE_CPU1=running','target running'
    [IO.File]::WriteAllText(
      $captureProofPath,$legacyCaptureLog,[Text.UTF8Encoding]::new($false))
    try {
      Assert-SmpCaptureLog -LiteralPath $captureProofPath `
        -ExpectedProbeSerial '90:70:69:11:81:A4' `
        -ExpectedUsbLocation '1-2.3'
    } catch {
      $legacyGenericRunningRejected=$_.Exception.Message-match
        'curstate.*marker count'
    }

    $cleanupProofPath=Join-Path $tempRoot 'cleanup-proof.log'
    $alreadyRunningCleanupLog=@'
Error: [esp32s3.cpu0] not halted
Error: [esp32s3.cpu0] Failed to prepare for resume!
VC_LORA_RESUME_CPU0
VC_LORA_RESUME_CURSTATE_CPU0=running
VC_LORA_RESUME_CPU1
VC_LORA_RESUME_CURSTATE_CPU1=running
shutdown command invoked
'@
    [IO.File]::WriteAllText($cleanupProofPath,$alreadyRunningCleanupLog,
      [Text.UTF8Encoding]::new($false))
    try {
      Assert-SmpCleanupLog -LiteralPath $cleanupProofPath
      $alreadyRunningCleanupProof=$true
    } catch {}

    $haltedCleanupLog=$alreadyRunningCleanupLog -replace
      'VC_LORA_RESUME_CURSTATE_CPU1=running',
      'VC_LORA_RESUME_CURSTATE_CPU1=halted'
    [IO.File]::WriteAllText($cleanupProofPath,$haltedCleanupLog,
      [Text.UTF8Encoding]::new($false))
    try { Assert-SmpCleanupLog -LiteralPath $cleanupProofPath } catch {
      $haltedCleanupRejected=$_.Exception.Message-match
        'CPU1.*expected running.*halted'
    }

    $unknownCleanupLog=$alreadyRunningCleanupLog -replace
      'VC_LORA_RESUME_CURSTATE_CPU1=running',
      'VC_LORA_RESUME_CURSTATE_CPU1=unknown'
    [IO.File]::WriteAllText($cleanupProofPath,$unknownCleanupLog,
      [Text.UTF8Encoding]::new($false))
    try { Assert-SmpCleanupLog -LiteralPath $cleanupProofPath } catch {
      $unknownCleanupRejected=$_.Exception.Message-match
        'CPU1.*expected running.*unknown'
    }

    $missingCleanupLog=$alreadyRunningCleanupLog -replace
      'VC_LORA_RESUME_CURSTATE_CPU1=running\r?\n',''
    [IO.File]::WriteAllText($cleanupProofPath,$missingCleanupLog,
      [Text.UTF8Encoding]::new($false))
    try { Assert-SmpCleanupLog -LiteralPath $cleanupProofPath } catch {
      $missingCleanupRejected=$_.Exception.Message-match
        'CPU1.*marker count.*0'
    }

    $duplicateCleanupLog=$alreadyRunningCleanupLog -replace
      'VC_LORA_RESUME_CURSTATE_CPU0=running',
      "VC_LORA_RESUME_CURSTATE_CPU0=running`r`nVC_LORA_RESUME_CURSTATE_CPU0=running"
    [IO.File]::WriteAllText($cleanupProofPath,$duplicateCleanupLog,
      [Text.UTF8Encoding]::new($false))
    try { Assert-SmpCleanupLog -LiteralPath $cleanupProofPath } catch {
      $duplicateCleanupRejected=$_.Exception.Message-match
        'CPU0.*marker count.*2'
    }
  }
  Add-Check 'valid_pre_halt_identity_capture_log_passes' `
    $validCaptureProof 'valid role-bound capture log must pass'
  Add-Check 'mismatched_opened_serial_fails_capture_proof' `
    $mismatchedCaptureRejected 'wrong opened device must fail closed'
  Add-Check 'post_halt_identity_marker_fails_capture_proof' `
    $lateIdentityRejected 'identity proof must precede target halt'
  Add-Check 'legacy_generic_halted_text_fails_halt_proof' `
    $legacyGenericHaltedRejected `
    'generic halted text must not replace exact per-core curstate evidence'
  Add-Check 'wrong_halt_curstate_fails_capture_proof' `
    $wrongHaltCurstateRejected `
    'either core reporting running during the halted snapshot must fail closed'
  Add-Check 'legacy_generic_running_text_fails_resume_proof' `
    $legacyGenericRunningRejected `
    'generic running text must not replace exact per-core curstate evidence'
  Add-Check 'already_running_cleanup_with_exact_curstate_passes' `
    $alreadyRunningCleanupProof `
    'not-halted resume errors are acceptable only when both curstates prove running'
  Add-Check 'halted_core_fails_cleanup_proof' $haltedCleanupRejected `
    'either halted core must fail closed'
  Add-Check 'unknown_core_fails_cleanup_proof' $unknownCleanupRejected `
    'either unknown core must fail closed'
  Add-Check 'missing_core_curstate_fails_cleanup_proof' `
    $missingCleanupRejected 'both explicit core markers are mandatory'
  Add-Check 'duplicate_core_curstate_fails_cleanup_proof' `
    $duplicateCleanupRejected 'ambiguous duplicate core markers must fail closed'

  Add-Check 'openocd_stage_classification_controls_cleanup' (
    $source -match 'function\s+Get-OpenOcdLogStage' -and
    $source -match 'device_opened' -and
    $source -match 'target_examined' -and
    $source -match 'halt_possible' -and
    $source -match 'resume_proven' -and
    $source -match 'FAIL_JTAG_USB_OPEN' -and
    $source -match 'skipped_due_to_pre_attach_failure') `
      'pre-attach USB-open failure must be classified without redundant cleanup'

  $targetRiskFunctions=@($readerAst.FindAll({param($node)
      $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
      $node.Name-ceq'Get-TargetMayBeHalted'},$true))
  $targetRiskContract=$false
  if(@($readerParseErrors).Count-eq0-and$targetRiskFunctions.Count-eq1){
    . ([scriptblock]::Create($targetRiskFunctions[0].Extent.Text))
    $preAttachStage=[pscustomobject]@{
      device_opened=$false;target_examined=$false
      halt_possible=$false;resume_proven=$false}
    $postAttachStage=[pscustomobject]@{
      device_opened=$true;target_examined=$true
      halt_possible=$true;resume_proven=$false}
    $targetRiskContract=(
      (Get-TargetMayBeHalted $true $preAttachStage $false $true)-and
      (Get-TargetMayBeHalted $true $postAttachStage $true $false)-and
      -not(Get-TargetMayBeHalted $true $postAttachStage $true $true)-and
      -not(Get-TargetMayBeHalted $true $preAttachStage $true $false)-and
      -not(Get-TargetMayBeHalted $false $postAttachStage $false $false))
  }
  Add-Check 'unproven_capture_termination_keeps_halt_risk_latched' `
      $targetRiskContract `
      'cleanup success cannot erase risk from an unproven capture-process termination'

  $defaultResult = Invoke-Reader @('-OutputRoot', (Join-Path $tempRoot 'default'))
  Add-Check 'default_is_offline_fixture_pass' (
    $defaultResult.ExitCode -eq 0 -and $defaultResult.Stdout -match '"mode":"offline-fixture"' -and
    $defaultResult.Stdout -match '"result":"PASS"') ($defaultResult.Stdout + $defaultResult.Stderr)

  Add-Check 'native_mock_exists' (
    Test-Path -LiteralPath $nativeMockPath -PathType Leaf) $nativeMockPath
  $spacedNativeMockPath = Join-Path $tempRoot 'mock native with spaces.ps1'
  Copy-Item -LiteralPath $nativeMockPath -Destination $spacedNativeMockPath
  $nativeZeroRoot = Join-Path $tempRoot 'native-zero'
  $nativeZero = Invoke-Reader @(
    '-OfflineNativeInvocationContractTest', '-NativeContractScript',
    ('"' + $spacedNativeMockPath + '"'), '-NativeContractExitCode', '0',
    '-NativeContractTimeoutMilliseconds', '5000', '-OutputRoot',
    $nativeZeroRoot)
  $nativeZeroSummary = if (Test-Path -LiteralPath (
      Join-Path $nativeZeroRoot 'summary.json') -PathType Leaf) {
    Get-Content -LiteralPath (Join-Path $nativeZeroRoot 'summary.json') -Raw |
      ConvertFrom-Json
  } else { $null }
  Add-Check 'native_stderr_does_not_fail_zero_exit' (
    $nativeZero.ExitCode -eq 0 -and $null -ne $nativeZeroSummary -and
    [int]$nativeZeroSummary.native.exit_code -eq 0 -and
    -not [bool]$nativeZeroSummary.native.timed_out -and
    (Get-Content -LiteralPath $nativeZeroSummary.native.stdout_path -Raw) -match
      'MOCK_NATIVE_STDOUT_SENTINEL' -and
    (Get-Content -LiteralPath $nativeZeroSummary.native.stderr_path -Raw) -match
      'MOCK_NATIVE_STDERR_SENTINEL') `
      ($nativeZero.Stdout + $nativeZero.Stderr)

  $nativeNonzeroRoot = Join-Path $tempRoot 'native-nonzero'
  $nativeNonzero = Invoke-Reader @(
    '-OfflineNativeInvocationContractTest', '-NativeContractScript',
    $nativeMockPath, '-NativeContractExitCode', '23',
    '-NativeContractTimeoutMilliseconds', '5000', '-OutputRoot',
    $nativeNonzeroRoot)
  $nativeNonzeroSummary = if (Test-Path -LiteralPath (
      Join-Path $nativeNonzeroRoot 'summary.json') -PathType Leaf) {
    Get-Content -LiteralPath (Join-Path $nativeNonzeroRoot 'summary.json') -Raw |
      ConvertFrom-Json
  } else { $null }
  Add-Check 'native_nonzero_exit_is_preserved_with_stderr' (
    $nativeNonzero.ExitCode -eq 23 -and $null -ne $nativeNonzeroSummary -and
    [int]$nativeNonzeroSummary.native.exit_code -eq 23 -and
    -not [bool]$nativeNonzeroSummary.native.timed_out -and
    (Get-Content -LiteralPath $nativeNonzeroSummary.native.stderr_path -Raw) -match
      'MOCK_NATIVE_STDERR_SENTINEL') `
      ($nativeNonzero.Stdout + $nativeNonzero.Stderr)

  $nativeTimeoutRoot = Join-Path $tempRoot 'native-timeout'
  $nativeTimeout = Invoke-Reader @(
    '-OfflineNativeInvocationContractTest', '-NativeContractScript',
    $nativeMockPath, '-NativeContractExitCode', '0',
    '-NativeContractHangMilliseconds', '3000',
    '-NativeContractTimeoutMilliseconds', '200', '-OutputRoot',
    $nativeTimeoutRoot)
  $nativeTimeoutSummary = if (Test-Path -LiteralPath (
      Join-Path $nativeTimeoutRoot 'summary.json') -PathType Leaf) {
    Get-Content -LiteralPath (Join-Path $nativeTimeoutRoot 'summary.json') -Raw |
      ConvertFrom-Json
  } else { $null }
  Add-Check 'native_timeout_is_bounded_and_reported' (
    $nativeTimeout.ExitCode -eq 124 -and $null -ne $nativeTimeoutSummary -and
    [int]$nativeTimeoutSummary.native.exit_code -eq 124 -and
    [bool]$nativeTimeoutSummary.native.timed_out) `
      ($nativeTimeout.Stdout + $nativeTimeout.Stderr)

  $valid = New-StageBytes
  $validFifo = New-FifoBytes
  $validFixture = Join-Path $tempRoot 'valid.json'
  Write-Fixture $validFixture $valid $valid $validFifo $validFifo
  $validResult = Invoke-Reader @('-FixturePath', $validFixture, '-OutputRoot', (Join-Path $tempRoot 'valid-out'))
  Add-Check 'valid_fixture_decodes_both_records' (
    $validResult.ExitCode -eq 0 -and
    $validResult.Stdout -match '"schema":"vc-lora-r19-runtime-stage-jtag-read-v3"' -and
    $validResult.Stdout -match '"last_reached_stage":"FlushCompleted"' -and
    $validResult.Stdout -match '"role":"vehicle"' -and
    $validResult.Stdout -match '"endpoint_fifo":' -and
    $validResult.Stdout -match
      '"state_semantics":"last-committed-diagnostic-event-not-live-hardware-state"' -and
    $validResult.Stdout -match '"fifo_write_attempt_observed":true' -and
    $validResult.Stdout -match '"positive_fifo_write_observed":true' -and
    $validResult.Stdout -match '"wr_done_observed":true' -and
    $validResult.Stdout -match '"payload_pickup_observed":true' -and
    $validResult.Stdout -match '"usb_tx_boundary_classification":"usb-tx-boundary-complete"' -and
    $validResult.Stdout -match '"last_flush_outcome":"Success"' -and
    $validResult.Stdout -match '"last_flush_outcome_code":2' -and
    $validResult.Stdout -match '"last_flush_task_zlp_count":1' -and
    $validResult.Stdout -match '"last_flush_isr_zlp_count":0' -and
    $validResult.Stdout -match '"last_flush_terminal_blocker_mask":"0x00000000"' -and
    $validResult.Stdout -match '"last_flush_terminal_blocker_mask_code":0' -and
    $validResult.Stdout -match
      '"last_flush_classification":"success-with-task-zlp"' -and
    $validResult.Stdout -match '"Initialized"' -and
    $validResult.Stdout -match '"ObservationActive"') `
      ($validResult.Stdout + $validResult.Stderr)

  $recoveryEnteredFixture = Join-Path $tempRoot 'recovery-entered.json'
  $recoveryEntered = New-StageBytes -StageMask 0x8000
  Write-Fixture $recoveryEnteredFixture $recoveryEntered $recoveryEntered
  $recoveryEnteredResult = Invoke-Reader @(
    '-FixturePath', $recoveryEnteredFixture, '-OutputRoot',
    (Join-Path $tempRoot 'recovery-entered-out'))
  Add-Check 'transport_recovery_entered_stage_decodes' (
    $recoveryEnteredResult.ExitCode -eq 0 -and
    $recoveryEnteredResult.Stdout -match
      '"stage_mask":"0x00008000"' -and
    $recoveryEnteredResult.Stdout -match
      '"last_reached_stage":"TransportRecoveryEntered"' -and
    $recoveryEnteredResult.Stdout -match '"TransportRecoveryEntered"') `
      ($recoveryEnteredResult.Stdout + $recoveryEnteredResult.Stderr)

  $recoveryCompletedFixture = Join-Path $tempRoot 'recovery-completed.json'
  $recoveryCompleted = New-StageBytes -StageMask 0x10000
  Write-Fixture $recoveryCompletedFixture $recoveryCompleted `
    $recoveryCompleted
  $recoveryCompletedResult = Invoke-Reader @(
    '-FixturePath', $recoveryCompletedFixture, '-OutputRoot',
    (Join-Path $tempRoot 'recovery-completed-out'))
  Add-Check 'transport_recovery_completed_stage_decodes' (
    $recoveryCompletedResult.ExitCode -eq 0 -and
    $recoveryCompletedResult.Stdout -match
      '"stage_mask":"0x00010000"' -and
    $recoveryCompletedResult.Stdout -match
      '"last_reached_stage":"TransportRecoveryCompleted"' -and
    $recoveryCompletedResult.Stdout -match '"TransportRecoveryCompleted"') `
      ($recoveryCompletedResult.Stdout + $recoveryCompletedResult.Stderr)

  $shortPacketNoZlpFixture = Join-Path $tempRoot `
    'fifo-short-packet-success-without-zlp.json'
  $shortPacketNoZlp = New-FifoBytes -FifoWriteAttemptCount 2 `
    -FifoWriteBytes 63 -LastFifoWriteSize 31 -WrDoneCount 2 `
    -InEmptyIrqCount 2 -PayloadInEmptyCount 2 -ZlpFlushCount 0 `
    -LastFlushTaskZlpCount 0 -LastFlushIsrZlpCount 0
  Write-Fixture $shortPacketNoZlpFixture $valid $valid `
    $shortPacketNoZlp $shortPacketNoZlp
  $shortPacketNoZlpResult = Invoke-Reader @('-FixturePath',
    $shortPacketNoZlpFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-short-packet-success-without-zlp-out'))
  Add-Check 'fifo_short_packet_success_requires_no_zlp' (
    $shortPacketNoZlpResult.ExitCode -eq 0 -and
    $shortPacketNoZlpResult.Stdout -match
      '"last_fifo_write_size":31' -and
    $shortPacketNoZlpResult.Stdout -match
      '"last_flush_task_zlp_count":0' -and
    $shortPacketNoZlpResult.Stdout -match
      '"last_flush_isr_zlp_count":0' -and
    $shortPacketNoZlpResult.Stdout -match
      '"last_flush_classification":"success-with-short-packet-no-zlp"' -and
    $shortPacketNoZlpResult.Stdout -match
      '"usb_tx_boundary_completion_proven":true') `
      ($shortPacketNoZlpResult.Stdout + $shortPacketNoZlpResult.Stderr)

  $fifoLastEventBusResetFixture = Join-Path $tempRoot `
    'fifo-last-event-bus-reset.json'
  $fifoLastEventBusReset = New-FifoBytes -BusResetCount 1 `
    -LastInterruptStatus 0x00000200
  Write-Fixture $fifoLastEventBusResetFixture $valid $valid `
    $fifoLastEventBusReset $fifoLastEventBusReset
  $fifoLastEventBusResetResult = Invoke-Reader @('-FixturePath',
    $fifoLastEventBusResetFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-last-event-bus-reset-out'))
  Add-Check 'fifo_last_bus_reset_dominates_historical_success' (
    $fifoLastEventBusResetResult.ExitCode -eq 0 -and
    $fifoLastEventBusResetResult.Stdout -match
      '"last_interrupt_status":"0x00000200"' -and
    $fifoLastEventBusResetResult.Stdout -match
      '"last_event_bus_reset":true' -and
    $fifoLastEventBusResetResult.Stdout -match
      '"usb_tx_boundary_completion_proven":false' -and
    $fifoLastEventBusResetResult.Stdout -match
      '"usb_tx_boundary_classification":"last-event-bus-reset"' -and
    $fifoLastEventBusResetResult.Stdout -notmatch
      '"usb_tx_boundary_classification":"usb-tx-boundary-complete"') `
      ($fifoLastEventBusResetResult.Stdout +
        $fifoLastEventBusResetResult.Stderr)

  $fifoSecondPublishPendingFixture = Join-Path $tempRoot `
    'fifo-second-publish-pending-after-success.json'
  $fifoSecondPublishPending = New-FifoBytes -Flags 0x0000280F `
    -FifoWriteAttemptCount 3 -FifoWriteBytes 83 -FifoZeroWriteCount 0 `
    -LastFifoWriteSize 19 -WrDoneCount 3 -ZlpFlushCount 1 `
    -PayloadInEmptyCount 2 -InEmptyIrqCount 2
  Write-Fixture $fifoSecondPublishPendingFixture $valid $valid `
    $fifoSecondPublishPending $fifoSecondPublishPending
  $fifoSecondPublishPendingResult = Invoke-Reader @('-FixturePath',
    $fifoSecondPublishPendingFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-second-publish-pending-after-success-out'))
  Add-Check 'fifo_pending_second_publish_dominates_historical_success' (
    $fifoSecondPublishPendingResult.ExitCode -eq 0 -and
    $fifoSecondPublishPendingResult.Stdout -match
      '"PayloadPublishPending"' -and
    $fifoSecondPublishPendingResult.Stdout -match
      '"payload_publish_pending":true' -and
    $fifoSecondPublishPendingResult.Stdout -match
      '"usb_tx_boundary_completion_proven":false' -and
    $fifoSecondPublishPendingResult.Stdout -match
      '"usb_tx_boundary_classification":"payload-publish-pending"') `
      ($fifoSecondPublishPendingResult.Stdout +
        $fifoSecondPublishPendingResult.Stderr)

  $fifoPublishAbortedFixture = Join-Path $tempRoot `
    'fifo-task-discard-after-reset-and-historical-success.json'
  $fifoPublishAborted = New-FifoBytes -Flags 0x0000100F `
    -FifoWriteAttemptCount 2 -FifoWriteBytes 64 -FifoZeroWriteCount 0 `
    -LastFifoWriteSize 32 -WrDoneCount 3 -ZlpFlushCount 1 `
    -PayloadInEmptyCount 2 -InEmptyIrqCount 3 -BusResetCount 1 `
    -LastInterruptStatus 0
  Write-Fixture $fifoPublishAbortedFixture $valid $valid `
    $fifoPublishAborted $fifoPublishAborted
  $fifoPublishAbortedResult = Invoke-Reader @('-FixturePath',
    $fifoPublishAbortedFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-task-discard-after-reset-out'))
  Add-Check 'fifo_task_discard_dominates_historical_success' (
    $fifoPublishAbortedResult.ExitCode -eq 0 -and
    $fifoPublishAbortedResult.Stdout -match '"PayloadPublishAborted"' -and
    $fifoPublishAbortedResult.Stdout -match
      '"payload_publish_aborted":true' -and
    $fifoPublishAbortedResult.Stdout -match
      '"usb_tx_boundary_completion_proven":false' -and
    $fifoPublishAbortedResult.Stdout -match
      '"usb_tx_boundary_classification":"payload-publish-aborted"') `
      ($fifoPublishAbortedResult.Stdout +
        $fifoPublishAbortedResult.Stderr)

  $fifoPayloadFlushPendingFixture = Join-Path $tempRoot `
    'fifo-new-payload-picked-up-before-new-flush-success.json'
  $fifoPayloadFlushPending = New-FifoBytes -Flags 0x0000200F `
    -FifoWriteAttemptCount 2 -FifoWriteBytes 64 -FifoZeroWriteCount 0 `
    -LastFifoWriteSize 32 -WrDoneCount 3 -ZlpFlushCount 1 `
    -PayloadInEmptyCount 2 -InEmptyIrqCount 2 -BusResetCount 1 `
    -PublishGeneration 3 -PickupGeneration 3 `
    -FlushAttemptCount 1 -FlushSuccessCount 1 -LastInterruptStatus 0
  Write-Fixture $fifoPayloadFlushPendingFixture $valid $valid `
    $fifoPayloadFlushPending $fifoPayloadFlushPending
  $fifoPayloadFlushPendingResult = Invoke-Reader @('-FixturePath',
    $fifoPayloadFlushPendingFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-payload-flush-pending-out'))
  Add-Check 'fifo_new_payload_requires_new_flush_success' (
    $fifoPayloadFlushPendingResult.ExitCode -eq 0 -and
    $fifoPayloadFlushPendingResult.Stdout -match '"PayloadFlushPending"' -and
    $fifoPayloadFlushPendingResult.Stdout -match
      '"payload_flush_pending":true' -and
    $fifoPayloadFlushPendingResult.Stdout -match
      '"usb_tx_boundary_completion_proven":false' -and
    $fifoPayloadFlushPendingResult.Stdout -match
      '"usb_tx_boundary_classification":"payload-flush-pending"') `
      ($fifoPayloadFlushPendingResult.Stdout +
        $fifoPayloadFlushPendingResult.Stderr)

  $writerFixture = Join-Path $tempRoot 'writer.json'
  $writer = New-StageBytes -ActiveWriter 1
  Write-Fixture $writerFixture $writer $writer
  $writerResult = Invoke-Reader @('-FixturePath', $writerFixture, '-OutputRoot', (Join-Path $tempRoot 'writer-out'))
  Add-Check 'active_writer_fails_closed' ($writerResult.ExitCode -ne 0) ($writerResult.Stdout + $writerResult.Stderr)

  $oddFixture = Join-Path $tempRoot 'odd.json'
  $odd = New-StageBytes -Sequence 25
  Write-Fixture $oddFixture $odd $odd
  $oddResult = Invoke-Reader @('-FixturePath', $oddFixture, '-OutputRoot', (Join-Path $tempRoot 'odd-out'))
  Add-Check 'odd_sequence_fails_closed' ($oddResult.ExitCode -ne 0) ($oddResult.Stdout + $oddResult.Stderr)

  $mismatchFixture = Join-Path $tempRoot 'mismatch.json'
  $later = New-StageBytes -Sequence 26
  Write-Fixture $mismatchFixture $valid $later
  $mismatchResult = Invoke-Reader @('-FixturePath', $mismatchFixture, '-OutputRoot', (Join-Path $tempRoot 'mismatch-out'))
  Add-Check 'different_reads_fail_closed' ($mismatchResult.ExitCode -ne 0) ($mismatchResult.Stdout + $mismatchResult.Stderr)

  $wrongRoleFixture = Join-Path $tempRoot 'wrong-role.json'
  Write-Fixture -Path $wrongRoleFixture -StageFirst $valid `
    -StageSecond $valid -Role 'ground'
  $wrongRoleResult = Invoke-Reader @('-FixturePath', $wrongRoleFixture, '-OutputRoot', (Join-Path $tempRoot 'wrong-role-out'))
  Add-Check 'record_role_mismatch_fails_closed' ($wrongRoleResult.ExitCode -ne 0) ($wrongRoleResult.Stdout + $wrongRoleResult.Stderr)

  $unknownStageFixture = Join-Path $tempRoot 'unknown-stage.json'
  $unknownStage = New-StageBytes -StageMask 0x20000
  Write-Fixture $unknownStageFixture $unknownStage $unknownStage
  $unknownStageResult = Invoke-Reader @('-FixturePath', $unknownStageFixture, '-OutputRoot', (Join-Path $tempRoot 'unknown-stage-out'))
  Add-Check 'unknown_stage_bits_fail_closed' ($unknownStageResult.ExitCode -ne 0) ($unknownStageResult.Stdout + $unknownStageResult.Stderr)

  $unknownFailureFixture = Join-Path $tempRoot 'unknown-failure.json'
  $unknownFailure = New-StageBytes -FirstFailure 0x545200ff -FirstFailureStageMask 0x1000 -FirstFailureDetail 1
  Write-Fixture $unknownFailureFixture $unknownFailure $unknownFailure
  $unknownFailureResult = Invoke-Reader @('-FixturePath', $unknownFailureFixture, '-OutputRoot', (Join-Path $tempRoot 'unknown-failure-out'))
  Add-Check 'unknown_failure_code_fails_closed' ($unknownFailureResult.ExitCode -ne 0) ($unknownFailureResult.Stdout + $unknownFailureResult.Stderr)

  [string[]]$groundBoundaryFailureNames = @(
    'GroundBoundaryHostLostWhileDraining',
    'GroundBoundaryHostAbsentWithIrreversiblePrefix',
    'GroundBoundaryEpochChanged',
    'GroundBoundaryDeadlineExpired',
    'GroundBoundaryOrderedBacklogDiscardFailed',
    'GroundBoundaryHeldHeartbeatDiscardFailed',
    'GroundBoundaryEgressPumpInvalid',
    'GroundBoundaryFlushFailed',
    'GroundBoundaryFlushEpochChanged',
    'GroundBoundaryFlushLate'
  )
  for ($reasonOffset = 0; $reasonOffset -lt
      $groundBoundaryFailureNames.Count; ++$reasonOffset) {
    $reasonNumber = 21 + $reasonOffset
    $reasonName = $groundBoundaryFailureNames[$reasonOffset]
    $reasonFixture = Join-Path $tempRoot (
        'ground-boundary-reason-{0}.json' -f $reasonNumber)
    $reasonBytes = New-StageBytes `
      -FirstFailure ([uint32](0x54520000 + $reasonNumber)) `
      -FirstFailureStageMask 0x2000 -FirstFailureDetail 77
    Write-Fixture $reasonFixture $reasonBytes $reasonBytes
    $reasonResult = Invoke-Reader @('-FixturePath', $reasonFixture,
      '-OutputRoot', (Join-Path $tempRoot (
        'ground-boundary-reason-{0}-out' -f $reasonNumber)))
    Add-Check ('ground_boundary_reason_{0}_decodes' -f $reasonNumber) (
      $reasonResult.ExitCode -eq 0 -and
      $reasonResult.Stdout -match
        ('"name":"{0}"' -f [regex]::Escape($reasonName))) `
        ($reasonResult.Stdout + $reasonResult.Stderr)
  }

  $orphanFailureFixture = Join-Path $tempRoot 'orphan-failure.json'
  $orphanFailure = New-StageBytes -FirstFailure 0 -FirstFailureStageMask 0x1000 -FirstFailureDetail 1
  Write-Fixture $orphanFailureFixture $orphanFailure $orphanFailure
  $orphanFailureResult = Invoke-Reader @('-FixturePath', $orphanFailureFixture, '-OutputRoot', (Join-Path $tempRoot 'orphan-failure-out'))
  Add-Check 'orphan_failure_fields_fail_closed' ($orphanFailureResult.ExitCode -ne 0) ($orphanFailureResult.Stdout + $orphanFailureResult.Stderr)

  $fifoWriterFixture = Join-Path $tempRoot 'fifo-writer.json'
  $fifoWriter = New-FifoBytes -ActiveWriter 1
  Write-Fixture $fifoWriterFixture $valid $valid $fifoWriter $fifoWriter
  $fifoWriterResult = Invoke-Reader @('-FixturePath', $fifoWriterFixture,
    '-OutputRoot', (Join-Path $tempRoot 'fifo-writer-out'))
  Add-Check 'fifo_active_writer_fails_closed' (
    $fifoWriterResult.ExitCode -ne 0 -and
    ($fifoWriterResult.Stdout + $fifoWriterResult.Stderr) -match
      'Endpoint FIFO active_writer is nonzero') `
      ($fifoWriterResult.Stdout + $fifoWriterResult.Stderr)

  $fifoOddFixture = Join-Path $tempRoot 'fifo-odd.json'
  $fifoOdd = New-FifoBytes -Sequence 41
  Write-Fixture $fifoOddFixture $valid $valid $fifoOdd $fifoOdd
  $fifoOddResult = Invoke-Reader @('-FixturePath', $fifoOddFixture,
    '-OutputRoot', (Join-Path $tempRoot 'fifo-odd-out'))
  Add-Check 'fifo_odd_sequence_fails_closed' (
    $fifoOddResult.ExitCode -ne 0 -and
    ($fifoOddResult.Stdout + $fifoOddResult.Stderr) -match
      'Endpoint FIFO sequence is odd') `
      ($fifoOddResult.Stdout + $fifoOddResult.Stderr)

  $fifoMismatchFixture = Join-Path $tempRoot 'fifo-mismatch.json'
  $fifoLater = New-FifoBytes -Sequence 42
  Write-Fixture $fifoMismatchFixture $valid $valid $validFifo $fifoLater
  $fifoMismatchResult = Invoke-Reader @('-FixturePath', $fifoMismatchFixture,
    '-OutputRoot', (Join-Path $tempRoot 'fifo-mismatch-out'))
  Add-Check 'fifo_different_reads_fail_closed' (
    $fifoMismatchResult.ExitCode -ne 0 -and
    ($fifoMismatchResult.Stdout + $fifoMismatchResult.Stderr) -match
      'two halted Endpoint FIFO JTAG reads are not identical') `
      ($fifoMismatchResult.Stdout + $fifoMismatchResult.Stderr)

  $fifoBadMagicFixture = Join-Path $tempRoot 'fifo-bad-magic.json'
  $fifoBadMagic = New-FifoBytes -Magic 0x48313947
  Write-Fixture $fifoBadMagicFixture $valid $valid $fifoBadMagic $fifoBadMagic
  $fifoBadMagicResult = Invoke-Reader @('-FixturePath', $fifoBadMagicFixture,
    '-OutputRoot', (Join-Path $tempRoot 'fifo-bad-magic-out'))
  Add-Check 'fifo_bad_magic_fails_closed' (
    $fifoBadMagicResult.ExitCode -ne 0 -and
    ($fifoBadMagicResult.Stdout + $fifoBadMagicResult.Stderr) -match
      'Endpoint FIFO diagnostic header is invalid') `
      ($fifoBadMagicResult.Stdout + $fifoBadMagicResult.Stderr)

  $fifoBadSchemaFixture = Join-Path $tempRoot 'fifo-bad-schema.json'
  $fifoBadSchema = New-FifoBytes -Schema 1
  Write-Fixture $fifoBadSchemaFixture $valid $valid $fifoBadSchema $fifoBadSchema
  $fifoBadSchemaResult = Invoke-Reader @('-FixturePath', $fifoBadSchemaFixture,
    '-OutputRoot', (Join-Path $tempRoot 'fifo-bad-schema-out'))
  Add-Check 'fifo_legacy_schema_fails_closed' (
    $fifoBadSchemaResult.ExitCode -ne 0 -and
    ($fifoBadSchemaResult.Stdout + $fifoBadSchemaResult.Stderr) -match
      'Endpoint FIFO diagnostic header is invalid') `
      ($fifoBadSchemaResult.Stdout + $fifoBadSchemaResult.Stderr)

  $legacyFixture = Join-Path $tempRoot 'legacy-v2-fixture.json'
  $legacyObject = [ordered]@{
    schema = 'vc-lora-r19-runtime-stage-jtag-fixture-v2'
    artifact_id = 'legacy-offline-fixture'
    role = 'vehicle'
    runtime_stage_address = '0x3fcab470'
    endpoint_fifo_address = '0x3fcab4b4'
    runtime_stage_first_read_base64 = [Convert]::ToBase64String($valid)
    runtime_stage_second_read_base64 = [Convert]::ToBase64String($valid)
    endpoint_fifo_first_read_base64 = [Convert]::ToBase64String(
        [byte[]]::new(96))
    endpoint_fifo_second_read_base64 = [Convert]::ToBase64String(
        [byte[]]::new(96))
  }
  $legacyObject | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath `
      $legacyFixture -Encoding utf8
  $legacyResult = Invoke-Reader @('-FixturePath', $legacyFixture,
    '-OutputRoot', (Join-Path $tempRoot 'legacy-v2-fixture-out'))
  Add-Check 'legacy_v2_fixture_fails_closed' (
    $legacyResult.ExitCode -ne 0 -and
    ($legacyResult.Stdout + $legacyResult.Stderr) -match
      'fixture schema mismatch') `
      ($legacyResult.Stdout + $legacyResult.Stderr)

  $fifoUninitializedFixture = Join-Path $tempRoot `
    'fifo-uninitialized.json'
  $fifoUninitialized = New-FifoBytes -Flags 0x0000000E
  Write-Fixture $fifoUninitializedFixture $valid $valid `
    $fifoUninitialized $fifoUninitialized
  $fifoUninitializedResult = Invoke-Reader @('-FixturePath',
    $fifoUninitializedFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-uninitialized-out'))
  Add-Check 'fifo_uninitialized_record_fails_closed' (
    $fifoUninitializedResult.ExitCode -ne 0 -and
    ($fifoUninitializedResult.Stdout + $fifoUninitializedResult.Stderr) `
      -match 'diagnostic record is not initialized') `
      ($fifoUninitializedResult.Stdout + $fifoUninitializedResult.Stderr)

  $fifoObservationNotStartedFixture = Join-Path $tempRoot `
    'fifo-observation-not-started.json'
  $fifoObservationNotStarted = New-FifoBytes -Flags 0x0000000D
  Write-Fixture $fifoObservationNotStartedFixture $valid $valid `
    $fifoObservationNotStarted $fifoObservationNotStarted
  $fifoObservationNotStartedResult = Invoke-Reader @('-FixturePath',
    $fifoObservationNotStartedFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-observation-not-started-out'))
  Add-Check 'fifo_observation_window_not_started_fails_closed' (
    $fifoObservationNotStartedResult.ExitCode -ne 0 -and
    ($fifoObservationNotStartedResult.Stdout +
      $fifoObservationNotStartedResult.Stderr) -match
      'diagnostic observation window was not started') `
      ($fifoObservationNotStartedResult.Stdout +
        $fifoObservationNotStartedResult.Stderr)

  $fifoUnknownFlagFixture = Join-Path $tempRoot 'fifo-unknown-flag.json'
  $fifoUnknownFlag = New-FifoBytes -Flags 0x0000400F
  Write-Fixture $fifoUnknownFlagFixture $valid $valid `
    $fifoUnknownFlag $fifoUnknownFlag
  $fifoUnknownFlagResult = Invoke-Reader @('-FixturePath',
    $fifoUnknownFlagFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-unknown-flag-out'))
  Add-Check 'fifo_unknown_flags_fail_closed' (
    $fifoUnknownFlagResult.ExitCode -ne 0 -and
    ($fifoUnknownFlagResult.Stdout + $fifoUnknownFlagResult.Stderr) -match
      'flags contain unknown bits') `
      ($fifoUnknownFlagResult.Stdout + $fifoUnknownFlagResult.Stderr)

  $fifoPickupAccountingFixture = Join-Path $tempRoot 'fifo-pickup-accounting.json'
  $fifoPickupAccounting = New-FifoBytes -InEmptyIrqCount 1 `
    -PayloadInEmptyCount 2
  Write-Fixture $fifoPickupAccountingFixture $valid $valid `
    $fifoPickupAccounting $fifoPickupAccounting
  $fifoPickupAccountingResult = Invoke-Reader @('-FixturePath',
    $fifoPickupAccountingFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-pickup-accounting-out'))
  Add-Check 'fifo_payload_pickup_accounting_fails_closed' (
    $fifoPickupAccountingResult.ExitCode -ne 0 -and
    ($fifoPickupAccountingResult.Stdout + $fifoPickupAccountingResult.Stderr) `
      -match 'payload IN_EMPTY count exceeds raw IN_EMPTY count') `
      ($fifoPickupAccountingResult.Stdout + $fifoPickupAccountingResult.Stderr)

  $fifoZeroWriteUnderflowFixture = Join-Path $tempRoot `
    'fifo-zero-write-underflow.json'
  $fifoZeroWriteUnderflow = New-FifoBytes -FifoWriteAttemptCount 2 `
    -FifoZeroWriteCount 3
  Write-Fixture $fifoZeroWriteUnderflowFixture $valid $valid `
    $fifoZeroWriteUnderflow $fifoZeroWriteUnderflow
  $fifoZeroWriteUnderflowResult = Invoke-Reader @('-FixturePath',
    $fifoZeroWriteUnderflowFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-zero-write-underflow-out'))
  Add-Check 'fifo_positive_write_subtraction_underflow_fails_closed' (
    $fifoZeroWriteUnderflowResult.ExitCode -ne 0 -and
    ($fifoZeroWriteUnderflowResult.Stdout +
      $fifoZeroWriteUnderflowResult.Stderr) -match
      'zero-write count exceeds FIFO write attempt count') `
      ($fifoZeroWriteUnderflowResult.Stdout +
        $fifoZeroWriteUnderflowResult.Stderr)

  $fifoZlpUnderflowFixture = Join-Path $tempRoot 'fifo-zlp-underflow.json'
  $fifoZlpUnderflow = New-FifoBytes -WrDoneCount 1 -ZlpFlushCount 2
  Write-Fixture $fifoZlpUnderflowFixture $valid $valid `
    $fifoZlpUnderflow $fifoZlpUnderflow
  $fifoZlpUnderflowResult = Invoke-Reader @('-FixturePath',
    $fifoZlpUnderflowFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-zlp-underflow-out'))
  Add-Check 'fifo_non_zlp_wr_done_subtraction_underflow_fails_closed' (
    $fifoZlpUnderflowResult.ExitCode -ne 0 -and
    ($fifoZlpUnderflowResult.Stdout + $fifoZlpUnderflowResult.Stderr) -match
      'ZLP flush count exceeds wr_done count') `
      ($fifoZlpUnderflowResult.Stdout + $fifoZlpUnderflowResult.Stderr)

  $fifoPayloadCausalityFixture = Join-Path $tempRoot `
    'fifo-payload-exceeds-non-zlp-wr-done.json'
  $fifoPayloadCausality = New-FifoBytes -WrDoneCount 3 -ZlpFlushCount 2 `
    -PayloadInEmptyCount 2 -InEmptyIrqCount 2
  Write-Fixture $fifoPayloadCausalityFixture $valid $valid `
    $fifoPayloadCausality $fifoPayloadCausality
  $fifoPayloadCausalityResult = Invoke-Reader @('-FixturePath',
    $fifoPayloadCausalityFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-payload-exceeds-non-zlp-wr-done-out'))
  Add-Check 'fifo_payload_exceeds_non_zlp_wr_done_fails_closed' (
    $fifoPayloadCausalityResult.ExitCode -ne 0 -and
    ($fifoPayloadCausalityResult.Stdout +
      $fifoPayloadCausalityResult.Stderr) -match
      'payload IN_EMPTY count exceeds non-ZLP wr_done count') `
      ($fifoPayloadCausalityResult.Stdout +
        $fifoPayloadCausalityResult.Stderr)

  $fifoWrDoneCausalityFixture = Join-Path $tempRoot `
    'fifo-non-zlp-wr-done-exceeds-positive-write.json'
  $fifoWrDoneCausality = New-FifoBytes -FifoWriteAttemptCount 2 `
    -FifoZeroWriteCount 1 -WrDoneCount 3 -ZlpFlushCount 1 `
    -PayloadInEmptyCount 1
  Write-Fixture $fifoWrDoneCausalityFixture $valid $valid `
    $fifoWrDoneCausality $fifoWrDoneCausality
  $fifoWrDoneCausalityResult = Invoke-Reader @('-FixturePath',
    $fifoWrDoneCausalityFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-non-zlp-wr-done-exceeds-positive-write-out'))
  Add-Check 'fifo_non_zlp_wr_done_exceeds_positive_write_fails_closed' (
    $fifoWrDoneCausalityResult.ExitCode -ne 0 -and
    ($fifoWrDoneCausalityResult.Stdout +
      $fifoWrDoneCausalityResult.Stderr) -match
      'non-ZLP wr_done count exceeds positive FIFO write attempt count') `
      ($fifoWrDoneCausalityResult.Stdout +
        $fifoWrDoneCausalityResult.Stderr)

  $fifoPendingWithoutGapFixture = Join-Path $tempRoot `
    'fifo-pending-without-unmatched-positive-write.json'
  $fifoPendingWithoutGap = New-FifoBytes -Flags 0x0000280F
  Write-Fixture $fifoPendingWithoutGapFixture $valid $valid `
    $fifoPendingWithoutGap $fifoPendingWithoutGap
  $fifoPendingWithoutGapResult = Invoke-Reader @('-FixturePath',
    $fifoPendingWithoutGapFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-pending-without-gap-out'))
  Add-Check 'fifo_pending_requires_unmatched_positive_write' (
    $fifoPendingWithoutGapResult.ExitCode -ne 0 -and
    ($fifoPendingWithoutGapResult.Stdout +
      $fifoPendingWithoutGapResult.Stderr) -match
      'PayloadPublishPending requires an unmatched positive FIFO write') `
      ($fifoPendingWithoutGapResult.Stdout +
        $fifoPendingWithoutGapResult.Stderr)

  $fifoGenerationFixture = Join-Path $tempRoot 'fifo-generation.json'
  $fifoGeneration = New-FifoBytes -Flags 0x0000201F `
    -PublishGeneration 2 -PickupGeneration 2
  Write-Fixture $fifoGenerationFixture $valid $valid `
    $fifoGeneration $fifoGeneration
  $fifoGenerationResult = Invoke-Reader @('-FixturePath',
    $fifoGenerationFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-generation-out'))
  Add-Check 'fifo_generation_relationship_fails_closed' (
    $fifoGenerationResult.ExitCode -ne 0 -and
    ($fifoGenerationResult.Stdout + $fifoGenerationResult.Stderr) -match
      'payload-in-flight flag disagrees with generation relationship') `
      ($fifoGenerationResult.Stdout + $fifoGenerationResult.Stderr)

  $fifoGenerationWrapFixture = Join-Path $tempRoot 'fifo-generation-wrap.json'
  $fifoGenerationWrap = New-FifoBytes -Flags 0x0000201F `
    -PublishGeneration 0 -PickupGeneration ([uint32]::MaxValue)
  Write-Fixture $fifoGenerationWrapFixture $valid $valid `
    $fifoGenerationWrap $fifoGenerationWrap
  $fifoGenerationWrapResult = Invoke-Reader @('-FixturePath',
    $fifoGenerationWrapFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-generation-wrap-out'))
  Add-Check 'fifo_generation_wrap_relationship_is_valid' (
    $fifoGenerationWrapResult.ExitCode -eq 0 -and
    $fifoGenerationWrapResult.Stdout -match
      '"usb_tx_boundary_classification":"payload-flush-pending"' -and
    $fifoGenerationWrapResult.Stdout -match
      '"usb_tx_boundary_completion_proven":false') `
      ($fifoGenerationWrapResult.Stdout + $fifoGenerationWrapResult.Stderr)

  $fifoSuccessFixture = Join-Path $tempRoot 'fifo-success-accounting.json'
  $fifoSuccess = New-FifoBytes -FlushAttemptCount 1 -FlushSuccessCount 1 `
    -FlushTimeoutCount 1
  Write-Fixture $fifoSuccessFixture $valid $valid $fifoSuccess $fifoSuccess
  $fifoSuccessResult = Invoke-Reader @('-FixturePath', $fifoSuccessFixture,
    '-OutputRoot', (Join-Path $tempRoot 'fifo-success-accounting-out'))
  Add-Check 'fifo_flush_success_accounting_fails_closed' (
    $fifoSuccessResult.ExitCode -ne 0 -and
    ($fifoSuccessResult.Stdout + $fifoSuccessResult.Stderr) -match
      'flush success count or timeout count exceeds flush attempt count') `
      ($fifoSuccessResult.Stdout + $fifoSuccessResult.Stderr)

  $fifoActiveFixture = Join-Path $tempRoot 'fifo-flush-active.json'
  $fifoActive = New-FifoBytes -Flags 0x0000040F `
    -FlushAttemptCount 2 -FlushSuccessCount 1 -FlushTimeoutCount 0 `
    -LastFlushOutcome 1
  Write-Fixture $fifoActiveFixture $valid $valid $fifoActive $fifoActive
  $fifoActiveResult = Invoke-Reader @('-FixturePath', $fifoActiveFixture,
    '-OutputRoot', (Join-Path $tempRoot 'fifo-flush-active-out'))
  Add-Check 'fifo_active_flush_is_not_misclassified_as_abort' (
    $fifoActiveResult.ExitCode -eq 0 -and
    $fifoActiveResult.Stdout -match '"FlushActive"' -and
    $fifoActiveResult.Stdout -match '"flush_active":true' -and
    $fifoActiveResult.Stdout -match '"flush_abort_inferred":0' -and
    $fifoActiveResult.Stdout -match
      '"usb_tx_boundary_classification":"flush-attempt-active"') `
      ($fifoActiveResult.Stdout + $fifoActiveResult.Stderr)

  $fifoAbortFixture = Join-Path $tempRoot 'fifo-flush-abort.json'
  $fifoAbort = New-FifoBytes -Flags 0x0000000F `
    -FlushAttemptCount 2 -FlushSuccessCount 1 -FlushTimeoutCount 0 `
    -LastFlushBlockerMask 0x00000002 -LastFlushOutcome 4 `
    -LastFlushTerminalBlockerMask 0x00000002
  Write-Fixture $fifoAbortFixture $valid $valid $fifoAbort $fifoAbort
  $fifoAbortResult = Invoke-Reader @('-FixturePath', $fifoAbortFixture,
    '-OutputRoot', (Join-Path $tempRoot 'fifo-flush-abort-out'))
  Add-Check 'fifo_epoch_abort_is_a_closed_non_timeout_attempt' (
    $fifoAbortResult.ExitCode -eq 0 -and
    $fifoAbortResult.Stdout -match '"EpochMismatch"' -and
    $fifoAbortResult.Stdout -match '"flush_abort_inferred":1' -and
    $fifoAbortResult.Stdout -match
      '"last_flush_classification":"abort-epoch-mismatch"' -and
    $fifoAbortResult.Stdout -match
      '"usb_tx_boundary_classification":"flush-aborted-epoch-mismatch"') `
      ($fifoAbortResult.Stdout + $fifoAbortResult.Stderr)

  $fifoSuccessWithoutTaskZlpFixture = Join-Path $tempRoot `
    'fifo-success-without-task-zlp.json'
  $fifoSuccessWithoutTaskZlp = New-FifoBytes -LastFifoWriteSize 0 `
    -WrDoneCount 2 -ZlpFlushCount 0 -LastFlushTaskZlpCount 0 `
    -LastFlushIsrZlpCount 0
  Write-Fixture $fifoSuccessWithoutTaskZlpFixture $valid $valid `
    $fifoSuccessWithoutTaskZlp $fifoSuccessWithoutTaskZlp
  $fifoSuccessWithoutTaskZlpResult = Invoke-Reader @('-FixturePath',
    $fifoSuccessWithoutTaskZlpFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-success-without-task-zlp-out'))
  Add-Check 'fifo_unknown_final_packet_without_task_zlp_fails_closed' (
    $fifoSuccessWithoutTaskZlpResult.ExitCode -ne 0 -and
    ($fifoSuccessWithoutTaskZlpResult.Stdout +
      $fifoSuccessWithoutTaskZlpResult.Stderr) -match
      'successful flush lacks task-origin final ZLP evidence') `
      ($fifoSuccessWithoutTaskZlpResult.Stdout +
        $fifoSuccessWithoutTaskZlpResult.Stderr)

  $fifoAbortWithoutEpochFixture = Join-Path $tempRoot `
    'fifo-abort-without-epoch-mismatch.json'
  $fifoAbortWithoutEpoch = New-FifoBytes -FlushAttemptCount 2 `
    -FlushSuccessCount 1 -FlushTimeoutCount 0 -LastFlushOutcome 4 `
    -LastFlushTerminalBlockerMask 0
  Write-Fixture $fifoAbortWithoutEpochFixture $valid $valid `
    $fifoAbortWithoutEpoch $fifoAbortWithoutEpoch
  $fifoAbortWithoutEpochResult = Invoke-Reader @('-FixturePath',
    $fifoAbortWithoutEpochFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-abort-without-epoch-mismatch-out'))
  Add-Check 'fifo_abort_without_epoch_mismatch_fails_closed' (
    $fifoAbortWithoutEpochResult.ExitCode -ne 0 -and
    ($fifoAbortWithoutEpochResult.Stdout +
      $fifoAbortWithoutEpochResult.Stderr) -match
      'aborted flush lacks EpochMismatch terminal evidence') `
      ($fifoAbortWithoutEpochResult.Stdout +
        $fifoAbortWithoutEpochResult.Stderr)

  $fifoImpossibleActiveFixture = Join-Path $tempRoot `
    'fifo-impossible-flush-active.json'
  $fifoImpossibleActive = New-FifoBytes -Flags 0x0000040F `
    -FlushAttemptCount 1 -FlushSuccessCount 1 -FlushTimeoutCount 0 `
    -LastFlushOutcome 1
  Write-Fixture $fifoImpossibleActiveFixture $valid $valid `
    $fifoImpossibleActive $fifoImpossibleActive
  $fifoImpossibleActiveResult = Invoke-Reader @('-FixturePath',
    $fifoImpossibleActiveFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-impossible-flush-active-out'))
  Add-Check 'fifo_impossible_active_accounting_fails_closed' (
    $fifoImpossibleActiveResult.ExitCode -ne 0 -and
    ($fifoImpossibleActiveResult.Stdout + $fifoImpossibleActiveResult.Stderr) `
      -match 'flush terminal and active counts exceed flush attempt count') `
      ($fifoImpossibleActiveResult.Stdout +
        $fifoImpossibleActiveResult.Stderr)

  $fifoLastWriteFixture = Join-Path $tempRoot 'fifo-last-write.json'
  $fifoLastWrite = New-FifoBytes -LastFifoWriteSize 33
  Write-Fixture $fifoLastWriteFixture $valid $valid $fifoLastWrite $fifoLastWrite
  $fifoLastWriteResult = Invoke-Reader @('-FixturePath', $fifoLastWriteFixture,
    '-OutputRoot', (Join-Path $tempRoot 'fifo-last-write-out'))
  Add-Check 'fifo_last_write_size_fails_closed' (
    $fifoLastWriteResult.ExitCode -ne 0 -and
    ($fifoLastWriteResult.Stdout + $fifoLastWriteResult.Stderr) -match
      'last FIFO write size exceeds 32 bytes') `
      ($fifoLastWriteResult.Stdout + $fifoLastWriteResult.Stderr)

  $fifoBlockerFixture = Join-Path $tempRoot 'fifo-blocker.json'
  $fifoBlocker = New-FifoBytes -LastFlushBlockerMask 0x00000100
  Write-Fixture $fifoBlockerFixture $valid $valid $fifoBlocker $fifoBlocker
  $fifoBlockerResult = Invoke-Reader @('-FixturePath', $fifoBlockerFixture,
    '-OutputRoot', (Join-Path $tempRoot 'fifo-blocker-out'))
  Add-Check 'fifo_unknown_blockers_fail_closed' (
    $fifoBlockerResult.ExitCode -ne 0 -and
    ($fifoBlockerResult.Stdout + $fifoBlockerResult.Stderr) -match
      'flush blockers contain unknown bits') `
      ($fifoBlockerResult.Stdout + $fifoBlockerResult.Stderr)

  $fifoKnownBlockerFixture = Join-Path $tempRoot 'fifo-known-blocker.json'
  $fifoKnownBlocker = New-FifoBytes -LastFlushBlockerMask 0x00000014
  Write-Fixture $fifoKnownBlockerFixture $valid $valid `
    $fifoKnownBlocker $fifoKnownBlocker
  $fifoKnownBlockerResult = Invoke-Reader @('-FixturePath',
    $fifoKnownBlockerFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-known-blocker-out'))
  Add-Check 'fifo_known_blockers_are_decoded' (
    $fifoKnownBlockerResult.ExitCode -eq 0 -and
    $fifoKnownBlockerResult.Stdout -match '"SoftwarePending"' -and
    $fifoKnownBlockerResult.Stdout -match '"PayloadPickupPending"' -and
    $fifoKnownBlockerResult.Stdout -match
      '"usb_tx_boundary_classification":"flush-blocked"') `
      ($fifoKnownBlockerResult.Stdout + $fifoKnownBlockerResult.Stderr)

  $fifoUnknownOutcomeFixture = Join-Path $tempRoot `
    'fifo-unknown-last-flush-outcome.json'
  $fifoUnknownOutcome = New-FifoBytes -LastFlushOutcome 5
  Write-Fixture $fifoUnknownOutcomeFixture $valid $valid `
    $fifoUnknownOutcome $fifoUnknownOutcome
  $fifoUnknownOutcomeResult = Invoke-Reader @('-FixturePath',
    $fifoUnknownOutcomeFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-unknown-last-flush-outcome-out'))
  Add-Check 'fifo_unknown_last_flush_outcome_fails_closed' (
    $fifoUnknownOutcomeResult.ExitCode -ne 0 -and
    ($fifoUnknownOutcomeResult.Stdout + $fifoUnknownOutcomeResult.Stderr) `
      -match 'last flush outcome is unknown') `
      ($fifoUnknownOutcomeResult.Stdout + $fifoUnknownOutcomeResult.Stderr)

  $fifoOutcomeMismatchFixture = Join-Path $tempRoot `
    'fifo-last-flush-outcome-mismatch.json'
  $fifoOutcomeMismatch = New-FifoBytes -Flags 0x0000000F `
    -LastFlushOutcome 1
  Write-Fixture $fifoOutcomeMismatchFixture $valid $valid `
    $fifoOutcomeMismatch $fifoOutcomeMismatch
  $fifoOutcomeMismatchResult = Invoke-Reader @('-FixturePath',
    $fifoOutcomeMismatchFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-last-flush-outcome-mismatch-out'))
  Add-Check 'fifo_last_flush_outcome_mismatch_fails_closed' (
    $fifoOutcomeMismatchResult.ExitCode -ne 0 -and
    ($fifoOutcomeMismatchResult.Stdout + $fifoOutcomeMismatchResult.Stderr) `
      -match 'last flush outcome disagrees with FlushActive') `
      ($fifoOutcomeMismatchResult.Stdout +
        $fifoOutcomeMismatchResult.Stderr)

  $fifoTerminalBlockerFixture = Join-Path $tempRoot `
    'fifo-last-flush-terminal-blocker.json'
  $fifoTerminalBlocker = New-FifoBytes `
    -LastFlushTerminalBlockerMask 0x00000100
  Write-Fixture $fifoTerminalBlockerFixture $valid $valid `
    $fifoTerminalBlocker $fifoTerminalBlocker
  $fifoTerminalBlockerResult = Invoke-Reader @('-FixturePath',
    $fifoTerminalBlockerFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-last-flush-terminal-blocker-out'))
  Add-Check 'fifo_unknown_last_flush_terminal_blocker_fails_closed' (
    $fifoTerminalBlockerResult.ExitCode -ne 0 -and
    ($fifoTerminalBlockerResult.Stdout +
      $fifoTerminalBlockerResult.Stderr) -match
      'last flush terminal blocker mask contains unknown bits') `
      ($fifoTerminalBlockerResult.Stdout +
        $fifoTerminalBlockerResult.Stderr)

  $fifoZlpAccountingFixture = Join-Path $tempRoot `
    'fifo-last-flush-zlp-accounting.json'
  $fifoZlpAccounting = New-FifoBytes -ZlpFlushCount 1 `
    -LastFlushTaskZlpCount 1 -LastFlushIsrZlpCount 1
  Write-Fixture $fifoZlpAccountingFixture $valid $valid `
    $fifoZlpAccounting $fifoZlpAccounting
  $fifoZlpAccountingResult = Invoke-Reader @('-FixturePath',
    $fifoZlpAccountingFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-last-flush-zlp-accounting-out'))
  Add-Check 'fifo_last_flush_zlp_accounting_fails_closed' (
    $fifoZlpAccountingResult.ExitCode -ne 0 -and
    ($fifoZlpAccountingResult.Stdout + $fifoZlpAccountingResult.Stderr) `
      -match 'last flush ZLP count exceeds cumulative ZLP count') `
      ($fifoZlpAccountingResult.Stdout +
        $fifoZlpAccountingResult.Stderr)

  $fifoRepeatedTaskZlpFixture = Join-Path $tempRoot `
    'fifo-repeated-terminal-task-zlp.json'
  $fifoRepeatedTaskZlp = New-FifoBytes -WrDoneCount 4 -ZlpFlushCount 2 `
    -LastFlushTaskZlpCount 2 -LastFlushIsrZlpCount 0
  Write-Fixture $fifoRepeatedTaskZlpFixture $valid $valid `
    $fifoRepeatedTaskZlp $fifoRepeatedTaskZlp
  $fifoRepeatedTaskZlpResult = Invoke-Reader @('-FixturePath',
    $fifoRepeatedTaskZlpFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-repeated-terminal-task-zlp-out'))
  Add-Check 'fifo_multiple_task_zlp_during_attempt_is_classified' (
    $fifoRepeatedTaskZlpResult.ExitCode -eq 0 -and
    $fifoRepeatedTaskZlpResult.Stdout -match
      '"last_flush_classification":"multiple-task-zlp-during-attempt"') `
      ($fifoRepeatedTaskZlpResult.Stdout +
        $fifoRepeatedTaskZlpResult.Stderr)

  $fifoTimeoutNoBlockerFixture = Join-Path $tempRoot `
    'fifo-timeout-without-terminal-blocker.json'
  $fifoTimeoutNoBlocker = New-FifoBytes -FlushAttemptCount 2 `
    -FlushSuccessCount 1 -FlushTimeoutCount 1 -LastFlushOutcome 3 `
    -LastFlushTerminalBlockerMask 0
  Write-Fixture $fifoTimeoutNoBlockerFixture $valid $valid `
    $fifoTimeoutNoBlocker $fifoTimeoutNoBlocker
  $fifoTimeoutNoBlockerResult = Invoke-Reader @('-FixturePath',
    $fifoTimeoutNoBlockerFixture, '-OutputRoot',
    (Join-Path $tempRoot 'fifo-timeout-without-terminal-blocker-out'))
  Add-Check 'fifo_timeout_without_terminal_blocker_is_classified' (
    $fifoTimeoutNoBlockerResult.ExitCode -eq 0 -and
    $fifoTimeoutNoBlockerResult.Stdout -match
      '"last_flush_classification":"timeout-without-terminal-blocker"') `
      ($fifoTimeoutNoBlockerResult.Stdout +
        $fifoTimeoutNoBlockerResult.Stderr)

  $preflightNoExecuteRoot = Join-Path $tempRoot 'preflight-no-execute'
  $preflightNoExecute = Invoke-Reader @(
    '-Preflight', '-Role', 'vehicle', '-ProbeSerial',
    '90:70:69:11:81:A4', '-ProbeUsbLocation', '1-2.3',
    '-OutputRoot', $preflightNoExecuteRoot)
  $preflightNoExecuteSummary = if (Test-Path -LiteralPath (
      Join-Path $preflightNoExecuteRoot 'summary.json') -PathType Leaf) {
    Get-Content -LiteralPath (
      Join-Path $preflightNoExecuteRoot 'summary.json') -Raw | ConvertFrom-Json
  } else { $null }
  Add-Check 'preflight_without_execute_fails_before_hardware' (
    $preflightNoExecute.ExitCode -ne 0 -and
    $null -ne $preflightNoExecuteSummary -and
    $preflightNoExecuteSummary.result -eq 'FAIL' -and
    -not [bool]$preflightNoExecuteSummary.hardware_interaction -and
    -not [bool]$preflightNoExecuteSummary.safety.cpu_halt_command_issued -and
    -not [bool]$preflightNoExecuteSummary.safety.system_reset_command_issued -and
    -not [bool]$preflightNoExecuteSummary.safety.transport_init_requested -and
    -not [bool]$preflightNoExecuteSummary.safety.tap_reset_or_scan_possible -and
    $preflightNoExecuteSummary.safety.target_state_modified -eq $false -and
    $preflightNoExecuteSummary.error -match 'explicit -Execute') `
      ($preflightNoExecute.Stdout + $preflightNoExecute.Stderr)

  $liveResult = Invoke-Reader @(
    '-Execute', '-Role', 'vehicle', '-Address', '0x3fcab470',
    '-ArtifactRoot', $tempRoot, '-ArtifactId', 'not-real',
    '-OutputRoot', (Join-Path $tempRoot 'live-negative')
  )
  Add-Check 'incomplete_live_binding_fails_closed' (
    $liveResult.ExitCode -ne 0 -and
    ($liveResult.Stdout + $liveResult.Stderr) -match 'missing live parameter') ($liveResult.Stdout + $liveResult.Stderr)
} catch {
  Add-Check 'contract_execution' $false $_.Exception.Message
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($checks | Where-Object { -not $_.passed })
$summary = [ordered]@{
  schema = 'vc-lora-r19-runtime-stage-jtag-reader-contract-v2'
  result = if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
  hardware_interaction = $false
  checks = $checks
  totals = [ordered]@{ total = $checks.Count; passed = $checks.Count - $failed.Count; failed = $failed.Count }
}
$summary | ConvertTo-Json -Depth 8
if ($failed.Count -ne 0) { exit 1 }
