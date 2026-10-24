param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$OutputDir = (Join-Path $RepoRoot 'runs\high_speed\HS-CANDIDATE-OFFLINE-001'),
  [string]$SanitizerCompiler = ''
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath($RepoRoot)
$output = [IO.Path]::GetFullPath($OutputDir)
$repoPrefix = $repo.TrimEnd('\') + '\'
if (-not $output.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "output directory escaped repository: $output"
}
New-Item -ItemType Directory -Path $output -Force | Out-Null

$checks = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Passed, [string]$Detail) {
  $checks.Add([pscustomobject]@{
      name = $Name
      passed = $Passed
      detail = $Detail
    })
}

function Convert-HexBytes([string]$Hex) {
  if (($Hex.Length % 2) -ne 0) { throw "odd hex length: $Hex" }
  $bytes = New-Object byte[] ($Hex.Length / 2)
  for ($offset = 0; $offset -lt $Hex.Length; $offset += 2) {
    $bytes[$offset / 2] = [Convert]::ToByte($Hex.Substring($offset, 2), 16)
  }
  return ,$bytes
}

function Get-FileEvidence([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $item = Get-Item -LiteralPath $Path
  return [pscustomobject]@{
    path = $item.FullName.Substring($repoPrefix.Length).Replace('\', '/')
    bytes = [uint64]$item.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash
  }
}

$candidatePath = Join-Path $repo `
  'firmware\high_speed\vc_lora_high_speed_candidate.hpp'
$compileFixturePath = Join-Path $repo `
  'tests\host\standalone\high_speed_candidate_contract_compile.cpp'
$transportModelPath = Join-Path $repo `
  'firmware\high_speed\e220_high_speed_transport_model.hpp'
$transportTestPath = Join-Path $repo `
  'tests\host\standalone\high_speed_transport_model_tests.cpp'
$corpusPath = Join-Path $repo `
  'runs\diagnostics\param_proxy_capture_analyzer_20260823\historical_932.json'
$vehicleSketch = Join-Path $repo `
  'vc_lora_vehicle_xiao_esp32s3\vc_lora_vehicle_xiao_esp32s3.ino'
$groundSketch = Join-Path $repo `
  'vc_lora_ground_xiao_esp32s3\vc_lora_ground_xiao_esp32s3.ino'

$candidateExists = Test-Path -LiteralPath $candidatePath -PathType Leaf
Add-Check 'candidate_header_exists' $candidateExists `
  'The experimental contract is a separate, reviewable header.'

if ($candidateExists) {
  $candidateText = Get-Content -Raw -LiteralPath $candidatePath
  Add-Check 'measured_inventory_is_pinned' `
    ($candidateText -match `
      'expected_inventory_version\s*=\s*0x20U' -and
     $candidateText -match `
      '0x00U,\s*0x00U,\s*0xE5U,\s*0xC3U,\s*0x46U,\s*0x00U,\s*0x00U,\s*0x00U') `
    'Both measured version 0x20 and raw profile 0000E5C346000000 are explicit.'
  Add-Check 'persistent_writes_are_forbidden' `
    ($candidateText -match `
       'persistent_profile_writes_allowed\s*=\s*false' -and
     $candidateText -notmatch `
       'write_e220_profile|config_command|HardwareSerial|\b0xC0U\b|\b0xC2U\b') `
    'The design-only candidate contains no E220 write command or Arduino I/O.'
  Add-Check 'live_gate_is_closed' `
    ($candidateText -match 'live_flash_authorized\s*=\s*false' -and
     $candidateText -match 'physical_model_label_required\s*=\s*true' -and
     $candidateText -match `
       'inventory_version_is_model_identity\s*=\s*false') `
    'Version 0x20 is not accepted as a physical model identity.'
  Add-Check 'strict_order_and_heartbeat_contract' `
    ($candidateText -match 'preserve_mavlink_frame_order\s*=\s*true' -and
     $candidateText -match `
       'preserve_real_heartbeat_priority\s*=\s*true' -and
     $candidateText -match 'heartbeat_hard_deadline_ms\s*=\s*2500U') `
    'The proposal does not relax exact PARAM_VALUE order or heartbeat SLA.'
  Add-Check 'proposed_transport_values_are_explicit' `
    ($candidateText -match 'candidate_uart_write_gap_ms\s*=\s*3U' -and
     $candidateText -match 'initial_downlink_ms\s*=\s*100U' -and
     $candidateText -match 'native_stream_downlink_ms\s*=\s*28000U' -and
     $candidateText -match 'direction_guard_ms\s*=\s*100U' -and
     $candidateText -match 'uplink_window_ms\s*=\s*150U' -and
     $candidateText -match 'param_value_wire_chunks_per_frame\s*=' -and
     $candidateText -match 'heartbeat_wire_chunks_per_frame\s*=') `
    'All proposed pacing/TDD changes are inspectable and stay on 19.2 kbps/32 B.'
  Add-Check 'vcb1_heartbeat_and_parameter_wire_accounting_are_exact' `
    ($candidateText -match 'bulk_fragment_payload_bytes\s*=\s*19U' -and
     $candidateText -match 'heartbeat_wire_chunks_per_frame[\s\S]*bulk_fragment_payload_bytes' -and
     $candidateText -match 'heartbeat_wire_chunks_per_frame\s*==[\s\r\n]*2U' -and
     $candidateText -match 'heartbeat_wire_bytes_per_frame\s*==[\s\r\n]*64U' -and
     $candidateText -match 'expected_parameter_wire_chunks\s*=\s*1864U' -and
     $candidateText -match 'expected_parameter_wire_bytes\s*=\s*59648U') `
    'VCB1 carries 19 payload bytes, so HB is 2x32 B while PARAM terminal evidence remains 1864/59648.'
} else {
  foreach ($name in @(
      'measured_inventory_is_pinned',
      'persistent_writes_are_forbidden',
      'live_gate_is_closed',
      'strict_order_and_heartbeat_contract',
      'proposed_transport_values_are_explicit',
      'vcb1_heartbeat_and_parameter_wire_accounting_are_exact')) {
    Add-Check $name $false 'Candidate header is missing.'
  }
}

$productionReferencesCandidate = $false
foreach ($path in @($vehicleSketch, $groundSketch)) {
  if ((Get-Content -Raw -LiteralPath $path) -match `
      'vc_lora_high_speed_candidate|VC_LORA_EXPERIMENTAL_HIGH_SPEED') {
    $productionReferencesCandidate = $true
  }
}
Add-Check 'accepted_r18_sketches_are_not_modified_by_candidate' `
  (-not $productionReferencesCandidate) `
  'The accepted production sketch entry points do not select the experiment.'

$compiler = Get-Command clang++ -ErrorAction SilentlyContinue
if (-not $compiler) {
  $fallback = Join-Path $env:TEMP `
    'vc_lora_host_tools\llvm-mingw-20260616-tar\llvm-mingw-20260616-ucrt-x86_64\bin\clang++.exe'
  if (Test-Path -LiteralPath $fallback -PathType Leaf) {
    $compiler = Get-Item -LiteralPath $fallback
  }
}
$compilePassed = $false
$compileExit = $null
$compileOutput = @()
if ($compiler -and $candidateExists) {
  $exePath = Join-Path $output 'high_speed_candidate_contract.exe'
  $compilerPath = if ($compiler.Source) { $compiler.Source } else {
    $compiler.FullName
  }
  $savedErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $compileOutput = @(& $compilerPath -std=c++17 -Wall -Wextra -Wpedantic `
        -Wconversion $compileFixturePath -o $exePath 2>&1)
    $compileExit = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $savedErrorActionPreference
  }
  if ($compileExit -eq 0) {
    & $exePath
    $compileExit = $LASTEXITCODE
  }
  $compilePassed = $compileExit -eq 0
}
Add-Check 'candidate_cpp_contract_compiles' $compilePassed `
  "clang++ compile/run exit=$compileExit"

$transportModelExists = Test-Path -LiteralPath $transportModelPath -PathType Leaf
Add-Check 'transport_model_exists' $transportModelExists `
  'Admission, drain-fence, and native-bulk logic remain isolated from R18.'
$transportCompilePassed = $false
$transportCompileExit = $null
$transportCompileOutput = @()
$transportRuntimeOutput = @()
if ($compiler -and (Test-Path -LiteralPath $transportTestPath -PathType Leaf)) {
  $transportExePath = Join-Path $output 'high_speed_transport_model_tests.exe'
  $compilerPath = if ($compiler.Source) { $compiler.Source } else {
    $compiler.FullName
  }
  $savedErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $transportCompileOutput = @(& $compilerPath -std=c++17 -Wall -Wextra `
        -Wpedantic -Wconversion -Werror $transportTestPath `
        -o $transportExePath 2>&1)
    $transportCompileExit = $LASTEXITCODE
    if ($transportCompileExit -eq 0) {
      $transportRuntimeOutput = @(& $transportExePath 2>&1)
      $transportCompileExit = $LASTEXITCODE
    }
  }
  finally {
    $ErrorActionPreference = $savedErrorActionPreference
  }
  $transportCompilePassed = $transportCompileExit -eq 0
}
Add-Check 'transport_model_runtime_contract_passes' $transportCompilePassed `
  "clang++ compile/runtime exit=$transportCompileExit"

$sanitizerCompileExit = $null
$sanitizerRuntimeOutput = @()
$sanitizerRuntimePath = $null
if ($SanitizerCompiler) {
  $sanitizerCompilerPath = [IO.Path]::GetFullPath($SanitizerCompiler)
  $sanitizerRuntimePath = Join-Path `
    (Split-Path -Parent $sanitizerCompilerPath) `
    'libclang_rt.asan_dynamic-x86_64.dll'
  $sanitizerPassed = $false
  if ((Test-Path -LiteralPath $sanitizerCompilerPath -PathType Leaf) -and
      (Test-Path -LiteralPath $sanitizerRuntimePath -PathType Leaf)) {
    $sanitizerExePath = Join-Path $output `
      'high_speed_transport_model_sanitize.exe'
    $savedPath = $env:PATH
    $savedAsanOptions = $env:ASAN_OPTIONS
    $savedUbsanOptions = $env:UBSAN_OPTIONS
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $compilerDir = Split-Path -Parent $sanitizerCompilerPath
      $env:PATH = "$compilerDir;$savedPath"
      $env:ASAN_OPTIONS = 'detect_leaks=0:halt_on_error=1'
      $env:UBSAN_OPTIONS = 'halt_on_error=1:print_stacktrace=1'
      $sanitizerRuntimeOutput = @(
        & $sanitizerCompilerPath '-std=c++17' '-Wall' '-Wextra' `
          '-Wpedantic' '-Wconversion' '-Werror' `
          '-fsanitize=address,undefined' '-fno-omit-frame-pointer' `
          $transportTestPath '-o' $sanitizerExePath 2>&1)
      $sanitizerCompileExit = $LASTEXITCODE
      if ($sanitizerCompileExit -eq 0) {
        $sanitizerRuntimeOutput += @(& $sanitizerExePath 2>&1)
        $sanitizerCompileExit = $LASTEXITCODE
      }
      $sanitizerPassed = $sanitizerCompileExit -eq 0
    }
    finally {
      $ErrorActionPreference = $savedErrorActionPreference
      $env:PATH = $savedPath
      $env:ASAN_OPTIONS = $savedAsanOptions
      $env:UBSAN_OPTIONS = $savedUbsanOptions
    }
  }
  Add-Check 'transport_model_asan_ubsan_passes' $sanitizerPassed `
    "ASan+UBSan compile/runtime exit=$sanitizerCompileExit"
}

if ($transportModelExists) {
  $transportModelText = Get-Content -Raw -LiteralPath $transportModelPath
  Add-Check 'transport_model_has_no_device_or_profile_io' `
    ($transportModelText -notmatch `
      'HardwareSerial|digitalWrite|pinMode|write_e220_profile|\b0xC0U\b|\b0xC2U\b' -and
     $transportModelText -match 'live_flash_authorized') `
    'The model has no Arduino/E220 configuration I/O and inherits the closed live gate.'
  Add-Check 'bulk_terminal_inputs_and_outcomes_are_explicit' `
    ($transportModelText -match 'fifo_has_complete_frame' -and
     $transportModelText -match 'upstream_stream_complete' -and
     $transportModelText -match 'parser_partial' -and
     $transportModelText -match 'queued_backlog' -and
     $transportModelText -match 'SuccessPending' -and
     $transportModelText -match 'IncompletePending' -and
     $transportModelText -match 'LateParamAfterExit') `
    'Transient FIFO state cannot be confused with clean upstream completion.'
  Add-Check 'heartbeat_uses_ackless_local_handoff_and_ground_sla' `
    ($transportModelText -match 'estimated_worst_case_frame_service_ms' -and
     $transportModelText -match 'radio_buffer_payload_floor_ms' -and
     $transportModelText -match 'heartbeat_reserve_floor_ms' -and
     $transportModelText -match 'confirm_heartbeat_local_buffer_handoff' -and
     $transportModelText -match 'class RemoteHeartbeatSlaLedger' -and
     $transportModelText -match 'baseline_heartbeat_ms' -and
     $transportModelText -match 'seal_terminal_sla' -and
     $transportModelText -notmatch 'confirm_heartbeat_delivery' -and
     $transportModelText -match 'ReceiverEvidencePollEpoch' -and
     $transportModelText -match 'receiver_events_drained_through_ms' -and
     $transportModelText -match 'poll_time_is_forward' -and
     $transportModelText -match 'HeartbeatDeadlineMiss') `
    'Heartbeat uses local semantic handoff midstream; Ground returns cumulative SLA only in the terminal ACK.'
  Add-Check 'credit_and_drain_use_generation_direction_tail' `
    ($transportModelText -match 'class TransferToken' -and
     $transportModelText -match 'class ProgressProof' -and
     $transportModelText -match 'class DrainProof' -and
     $transportModelText -match 'generation' -and
     $transportModelText -match 'direction' -and
     $transportModelText -match 'tail' -and
     $transportModelText -match 'release_buffer_credit_from_local_aux' -and
     $transportModelText -match 'local_release_low_seen_since_accept_' -and
     $transportModelText -match 'proof.source\(\) != EvidenceSource::ExplicitTxComplete' -and
     $transportModelText -notmatch 'unlock_direction\s*\(\s*bool' -and
     $transportModelText -notmatch 'confirm_radio_buffer_consumed') `
    'Remote progress cannot replenish admission credit; fresh local AUX evidence is one-shot and cannot unlock direction.'
  Add-Check 'aux_overlap_is_nominal_and_nonoverlap_bound_is_retained' `
    ($transportModelText -match 'at most 13 ms' -and
     $transportModelText -match '2 ms remains outside' -and
     $transportModelText -match 'timing hypothesis, not a guarantee' -and
     $transportModelText -match 'non-overlapped case' -and
     $transportModelText -match 'live gate remains false') `
    'Only the nominal path overlaps AUX stabilization with tail airtime; the >28-s non-overlap bound remains explicit.'
  Add-Check 'final_param_success_requires_remote_tail_before_deadline' `
    ($transportModelText -match 'bind_final_parameter_tail' -and
     $transportModelText -match 'confirm_final_parameter_delivery' -and
     $transportModelText -match 'WaitForFinalParamDelivery' -and
     $transportModelText -match 'FinalTailAfterAbsoluteMax' -and
     $transportModelText -match 'FinalLocalHandoffAfterAbsoluteMax' -and
     $transportModelText -match 'final_param_local_handoff_ms_' -and
     $transportModelText -match 'remote_request_started_ms' -and
     $transportModelText -match 'ground_arrival_target_ms' -and
     $transportModelText -match 'final_param_delivery_on_time_') `
    'Ground request-to-last-PARAM time, not terminal ACK receipt or first-PARAM time, controls the 30-second target.'
  Add-Check 'proof_capability_is_opaque_and_session_scoped' `
    ($transportModelText -match 'friend class E220UartAdmissionGate' -and
     $transportModelText -match 'friend class E220DirectionDrainFence' -and
     $transportModelText -match 'friend class RemoteDeliveryLedger' -and
     $transportModelText -match 'session_id' -and
     $transportModelText -match 'stream_id' -and
     $transportModelText -match 'session_fault_latched' -and
     $transportModelText -match 'class ParameterChunkWatermark' -and
     $transportModelText -match 'class HeartbeatTailWatermark' -and
     $transportModelText -match 'class FinalParameterTailWatermark' -and
     $transportModelText -match 'class HeartbeatDeliveryProof' -and
     $transportModelText -match 'class RemoteHeartbeatSlaProof' -and
     $transportModelText -match 'class ParameterStreamDeliveryProof' -and
     $transportModelText -match 'commit_parameter_chunk' -and
     $transportModelText -match 'commit_heartbeat_chunk' -and
     $transportModelText -match 'remote_observed_at_ms' -and
     $transportModelText -match 'terminal_ack_received_ms' -and
     $transportModelText -notmatch 'struct TransferToken' -and
     $transportModelText -notmatch 'struct ProgressProof' -and
     $transportModelText -notmatch 'struct DrainProof') `
    'Gate/fence issue opaque session/stream capabilities; delivery time is immutable in proof.'
  Add-Check 'terminal_pair_is_atomic_cross_bound_and_wire_blocked' `
    ($transportModelText -match 'seal_terminal_receiver_evidence' -and
     $transportModelText -match 'current_parameter_delivery_matches' -and
     $transportModelText -match 'current_sla_matches' -and
     $transportModelText -match 'parameter_issuer_' -and
     $transportModelText -match 'parameter_receiver_revision_' -and
     $transportModelText -match 'open_terminal_ack_window' -and
     $transportModelText -match 'TerminalAckTimeout' -and
     $transportModelText -match 'WIRE INTEGRATION BLOCKER' -and
     $transportModelText -match 'Production v2 uses exact fixed 32-byte control/data' -and
     $transportModelText -match 'multi-frame vNext ACK' -and
     $transportModelText -notmatch '22-byte control versus fixed 32-byte data' -and
     $transportModelText -match 'CRC' -and
     $transportModelText -match 'live gate remains false') `
    'Terminal PARAM/HB evidence is atomically cross-bound; finite ACK timing is modeled while the wire codec remains blocked.'
  Add-Check 'physical_and_remote_parameter_ledgers_are_contiguous' `
    ($transportModelText -match 'class RemoteDeliveryLedger' -and
     $transportModelText -match 'global_chunk_ordinal' -and
     $transportModelText -match 'seal_parameter_stream_delivery' -and
     $transportModelText -match 'consume_current_parameter_delivery' -and
     $transportModelText -match 'receiver_revision_' -and
     $transportModelText -match 'received_parameter_count_' -and
     $transportModelText -match 'physically_committed_param_count_' -and
     $transportModelText -match 'expected_parameter_wire_chunks' -and
     $transportModelText -match 'expected_parameter_wire_bytes') `
    'Success is coupled to ordered 0..931 sender commits and contiguous receiver evidence.'
  Add-Check 'unknown_writes_quarantine_and_counters_fail_latched' `
    ($transportModelText -match 'enter_quarantine' -and
     $transportModelText -match 'record_unknown_accepted' -and
     $transportModelText -match 'ExplicitQuarantineDrain' -and
     $transportModelText -match 'counter_fault_latched') `
    'Positive unknown writes and counter overflow cannot silently resume.'
} else {
  Add-Check 'transport_model_has_no_device_or_profile_io' $false `
    'Transport model is missing.'
  foreach ($name in @(
      'bulk_terminal_inputs_and_outcomes_are_explicit',
      'heartbeat_uses_ackless_local_handoff_and_ground_sla',
      'credit_and_drain_use_generation_direction_tail',
      'aux_overlap_is_nominal_and_nonoverlap_bound_is_retained',
      'final_param_success_requires_remote_tail_before_deadline',
      'proof_capability_is_opaque_and_session_scoped',
      'terminal_pair_is_atomic_cross_bound_and_wire_blocked',
      'physical_and_remote_parameter_ledgers_are_contiguous',
      'unknown_writes_quarantine_and_counters_fail_latched')) {
    Add-Check $name $false 'Transport model is missing.'
  }
}

$transportTestExists = Test-Path -LiteralPath $transportTestPath -PathType Leaf
if ($transportTestExists) {
  $transportTestText = Get-Content -Raw -LiteralPath $transportTestPath
  Add-Check 'critical_finding_negative_matrix_is_present' `
    ($transportTestText -match 'test_transient_fifo_empty_is_not_terminal' -and
     $transportTestText -match 'test_inactivity_never_discards_backlog_or_parser_partial' -and
     $transportTestText -match 'test_actual_932_success_requires_clean_upstream_completion' -and
     $transportTestText -match 'test_clean_completion_waits_for_active_frame' -and
     $transportTestText -match 'test_local_ack_timestamp_controls_absolute_deadline' -and
     $transportTestText -match 'test_frozen_932_accounted_transport_success_path' -and
     $transportTestText -match 'test_partial_and_unadmitted_positive_write_enter_quarantine' -and
     $transportTestText -match 'test_direction_fence_never_reuses_old_complete_or_evidence' -and
     $transportTestText -match 'test_heartbeat_before_bulk_is_schedulable_and_needs_drain_proof' -and
     $transportTestText -match 'test_param_order_and_counter_overflow_are_hard_faults' -and
     $transportTestText -match 'test_session_identity_rejects_proof_replay_after_reboot' -and
     $transportTestText -match 'test_bulk_rejects_old_session_stream_and_uplink_capabilities' -and
     $transportTestText -match 'test_heartbeat_capability_is_bound_to_current_request' -and
     $transportTestText -match 'test_bulk_session_and_stream_zero_fail_closed' -and
     $transportTestText -match 'test_final_parameter_transaction_requires_both_chunks_once_in_order' -and
     $transportTestText -match 'test_heartbeat_transaction_requires_two_chunks_and_is_one_shot' -and
     $transportTestText -match 'test_local_ack_time_is_applied_before_deadline_poll' -and
     $transportTestText -match 'test_poll_epoch_rejects_cached_future_replay_and_time_regression' -and
     $transportTestText -match 'test_physical_parameter_ledger_starts_at_zero_and_rejects_fresh_gate' -and
     $transportTestText -match 'test_remote_delivery_ledger_rejects_noncontiguous_or_wrong_stream' -and
     $transportTestText -match 'test_heartbeat_delivery_is_purpose_specific_and_frame_boundary_only' -and
     $transportTestText -match 'test_parameter_proof_is_revoked_by_post_seal_duplicate_before_terminal_commit' -and
     $transportTestText -match 'test_remote_clock_offset_cannot_change_hb_or_final_deadline_result' -and
     $transportTestText -match 'test_completed_parameter_stream_rejects_cached_index_zero_permit' -and
     $transportTestText -match 'test_half_duplex_bulk_can_prove_heartbeat_sla_without_midstream_reverse_ack' -and
     $transportTestText -match 'test_aux_tail_airtime_overlap_is_nominal_only_and_nonoverlap_misses_28s' -and
     $transportTestText -match 'test_sender_local_full_handoff_hard_deadline_boundary' -and
     $transportTestText -match 'test_ackless_downlink_replenishes_400_byte_credit_from_local_e220_evidence' -and
     $transportTestText -match 'test_remote_heartbeat_sla_rejects_missing_gap_duplicate_wrong_lease_and_bad_baseline' -and
     $transportTestText -match 'test_rejects_first_in_stream_heartbeat_when_pre_stream_baseline_gap_exceeds_sla' -and
     $transportTestText -match 'test_terminal_pair_is_atomic_cross_bound_and_revocable' -and
     $transportTestText -match 'test_terminal_ack_wait_is_finite_and_separate_from_ground_30s_metric' -and
     $transportTestText -match 'test_all_timers_are_wrap_safe') `
    'All critical findings, including sender/receiver contiguous ledgers, have executable negative coverage.'
} else {
  Add-Check 'critical_finding_negative_matrix_is_present' $false `
    'Transport model test is missing.'
}

$corpusExists = Test-Path -LiteralPath $corpusPath -PathType Leaf
Add-Check 'accepted_932_corpus_exists' $corpusExists `
  'The calculation uses the preserved real PARAM_VALUE corpus.'

$metrics = $null
if ($corpusExists) {
  $document = Get-Content -Raw -LiteralPath $corpusPath | ConvertFrom-Json
  $firstByIndex = @{}
  $sourceValidIndexes = [Collections.Generic.List[int]]::new()
  foreach ($value in $document.param_values) {
    $index = [int]$value.index
    if ($index -ge 0 -and $index -lt 932) {
      $sourceValidIndexes.Add($index)
      if (-not $firstByIndex.ContainsKey($index)) {
        $firstByIndex[$index] = $value
      }
    }
  }
  $strictSourceOrder = $sourceValidIndexes.Count -eq 932
  if ($strictSourceOrder) {
    for ($position = 0; $position -lt 932; ++$position) {
      if ($sourceValidIndexes[$position] -ne $position) {
        $strictSourceOrder = $false
        break
      }
    }
  }

  [uint64]$rawBytes = 0
  [uint64]$wireChunks = 0
  [uint64]$twoChunkFrames = 0
  [uint64]$otherChunkFrames = 0
  [uint64]$badFrameSizes = 0
  for ($index = 0; $index -lt 932; ++$index) {
    if (-not $firstByIndex.ContainsKey($index)) { continue }
    $value = $firstByIndex[$index]
    $frame = [Collections.Generic.List[byte]]::new()
    [byte[]]$header = @(
      0xFD, 25, 0, 0, [byte]$value.sequence,
      [byte]$value.system_id, [byte]$value.component_id, 22, 0, 0)
    $frame.AddRange($header)
    [byte[]]$valueBytes = Convert-HexBytes $value.value_bits_hex
    $frame.AddRange($valueBytes)
    $frame.Add([byte]([int]$value.count -band 0xFF))
    $frame.Add([byte](([int]$value.count -shr 8) -band 0xFF))
    $frame.Add([byte]($index -band 0xFF))
    $frame.Add([byte](($index -shr 8) -band 0xFF))
    [byte[]]$idBytes = Convert-HexBytes $value.id_raw_hex
    $frame.AddRange($idBytes)
    $frame.Add([byte]$value.type)
    $frame.Add([byte]([int]$value.crc -band 0xFF))
    $frame.Add([byte](([int]$value.crc -shr 8) -band 0xFF))

    if ($frame.Count -ne 37) { ++$badFrameSizes }
    $rawBytes += [uint64]$frame.Count
    $position = 0
    $frameChunks = 0
    while ($position -lt $frame.Count) {
      $wire = 0
      while ($position -lt $frame.Count) {
        $byte = $frame[$position]
        $needed = if ($byte -eq 0x7D -or $byte -eq 0x56 -or
                          $byte -eq 0x7E) { 2 } else { 1 }
        if ($wire + $needed -gt 32) { break }
        $wire += $needed
        ++$position
      }
      ++$frameChunks
      ++$wireChunks
    }
    if ($frameChunks -eq 2) { ++$twoChunkFrames } else {
      ++$otherChunkFrames
    }
  }

  [uint64]$wireBytes = $wireChunks * 32
  [uint64]$airLowerBoundMs = [uint64][Math]::Ceiling(
    $wireBytes * 8.0 * 1000.0 / 19200.0)
  [uint64]$productionFloorMs = $wireChunks * 550
  [uint64]$productionGapMs = $wireChunks * 180
  [uint64]$candidateFeedMs = $wireChunks * 3
  $metrics = [pscustomobject]@{
    unique_indexed_parameters = [uint64]$firstByIndex.Count
    raw_mavlink_bytes = $rawBytes
    wire_chunks = $wireChunks
    wire_bytes = $wireBytes
    two_chunk_frames = $twoChunkFrames
    other_chunk_frames = $otherChunkFrames
    bad_frame_sizes = $badFrameSizes
    strict_source_index_order = $strictSourceOrder
    nominal_air_lower_bound_ms = $airLowerBoundMs
    production_550ms_floor_lower_bound_ms = $productionFloorMs
    production_180ms_gap_lower_bound_ms = $productionGapMs
    candidate_3ms_uart_feed_ms = $candidateFeedMs
    target_ms = 30000
    stretch_target_ms = 10000
  }
  Add-Check 'corpus_is_exact_932_order_domain' `
    ($firstByIndex.Count -eq 932 -and $badFrameSizes -eq 0) `
    "unique indexes=$($firstByIndex.Count), 37-byte failures=$badFrameSizes"
  Add-Check 'frozen_corpus_preserves_strict_index_order' `
    $strictSourceOrder `
    "The 932 in-domain source records are exactly index 0 through 931."
  Add-Check 'wire_accounting_is_exact' `
    ($rawBytes -eq 34484 -and $wireChunks -eq 1864 -and
     $wireBytes -eq 59648 -and $twoChunkFrames -eq 932 -and
     $otherChunkFrames -eq 0) `
    "raw=$rawBytes, chunks=$wireChunks, padded wire=$wireBytes"
  Add-Check 'thirty_seconds_is_nominally_feasible' `
    ($airLowerBoundMs -eq 24854 -and $airLowerBoundMs -lt 30000) `
    "19.2-kbps payload-only lower bound=$airLowerBoundMs ms; margin excludes LoRa overhead"
  Add-Check 'ten_seconds_is_impossible_without_profile_change' `
    ($airLowerBoundMs -gt 10000) `
    "The RF payload lower bound alone exceeds 10,000 ms."
  Add-Check 'current_pacing_cannot_meet_target' `
    ($productionFloorMs -eq 1025200 -and
     $productionGapMs -eq 335520 -and
     $productionFloorMs -gt 30000 -and
     $productionGapMs -gt 30000) `
    "550-ms floor=$productionFloorMs ms; 180-ms gap=$productionGapMs ms"
} else {
  foreach ($name in @(
      'corpus_is_exact_932_order_domain',
      'frozen_corpus_preserves_strict_index_order',
      'wire_accounting_is_exact',
      'thirty_seconds_is_nominally_feasible',
      'ten_seconds_is_impossible_without_profile_change',
      'current_pacing_cannot_meet_target')) {
    Add-Check $name $false 'Accepted corpus is missing.'
  }
}

$passed = @($checks | Where-Object { -not $_.passed }).Count -eq 0
$summary = [ordered]@{
  schema_version = 1
  test_id = 'HS-CANDIDATE-OFFLINE-003'
  status = if ($passed) { 'PASS' } else { 'FAIL' }
  measurement_only = $true
  hardware_touched = $false
  persistent_e220_registers_touched = $false
  candidate_stage = 'DESIGN_ONLY_LIVE_GATE_CLOSED_CRITICAL_FINDINGS_FIXED'
  measured_inventory = [ordered]@{
    raw_profile = 'C100080000E5C346000000'
    version = '0x20'
    version_identifies_physical_model = $false
  }
  metrics = $metrics
  checks = @($checks)
  inputs = @(
    Get-FileEvidence $PSCommandPath
    Get-FileEvidence $candidatePath
    Get-FileEvidence $compileFixturePath
    Get-FileEvidence $transportModelPath
    Get-FileEvidence $transportTestPath
    Get-FileEvidence $corpusPath
  ) | Where-Object { $_ -ne $null }
  compiler_output = @($compileOutput | ForEach-Object { "$_" })
  transport_compiler_output = @(
    $transportCompileOutput | ForEach-Object { "$_" }
  )
  transport_runtime_output = @(
    $transportRuntimeOutput | ForEach-Object { "$_" }
  )
  sanitizer = [ordered]@{
    requested = [bool]$SanitizerCompiler
    compiler = if ($SanitizerCompiler) {
      [IO.Path]::GetFullPath($SanitizerCompiler)
    } else { $null }
    runtime = $sanitizerRuntimePath
    exit_code = $sanitizerCompileExit
    output = @($sanitizerRuntimeOutput | ForEach-Object { "$_" })
  }
}
$summaryPath = Join-Path $output 'summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath `
  -Encoding UTF8
$summaryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $summaryPath).Hash
Set-Content -LiteralPath (Join-Path $output 'summary.sha256') `
  -Value "$summaryHash  summary.json" -Encoding ASCII

Write-Output "HS-CANDIDATE-OFFLINE-003 $($summary.status)"
Write-Output "summary=$summaryPath"
if (-not $passed) { exit 1 }
