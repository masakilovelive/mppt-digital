[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = 'E:/VESC/TRIAL_LOG/Loreley3_System/06_vc_lora_bridge'
$run = Join-Path $project 'runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261025T043509262Z-grant-reservation-param-once-after-flash-metadata-fix'
$output = Join-Path $project 'runs/validation/R19-GRANT-RESERVATION-INTEGRATION-OFFLINE-001/20261025T-fix/reservation_failure_derived_readonly_analysis.json'
function Read-Json([string]$path) { return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json }
function Hash-Bytes([byte[]]$bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
  finally { $sha.Dispose() }
}
function Check-Crc([byte[]]$frame, [byte]$extra) {
  [uint32]$crc = 65535
  foreach ($value in @($frame[1..($frame.Length-3)]) + @($extra)) {
    [uint32]$tmp = ([uint32]$value -bxor ($crc -band 255))
    $tmp = ($tmp -bxor ($tmp -shl 4)) -band 255
    $crc = (($crc -shr 8) -bxor ($tmp -shl 8) -bxor ($tmp -shl 3) -bxor ($tmp -shr 4)) -band 65535
  }
  $stored = [uint32]$frame[$frame.Length-2] + 256 * [uint32]$frame[$frame.Length-1]
  return [pscustomobject]@{computed=$crc;stored=$stored;valid=($crc -eq $stored);extra=$extra}
}
$capturePath = Join-Path $run 'capture/summary.json'
$capture = Read-Json $capturePath
$stages = @{}
$roleEvidence = @{}
foreach ($role in @('vehicle','ground')) {
  $stagePath = Join-Path $run "stage_$role/summary.json"
  $stage = Read-Json $stagePath
  $stages[$role] = $stage
  $metadata = @($capture.roles | Where-Object role -eq $role)[0]
  $rawPath = Join-Path $run "capture/$role.raw.bin"
  $raw = [IO.File]::ReadAllBytes($rawPath)
  $text = [Text.Encoding]::ASCII.GetString($raw)
  $match = [regex]::Match($text, 'R19F:[VG]:[A-F0-9]{4}:[A-F0-9]{16}:[A-F0-9]{12}:[A-F0-9]{8}')
  if (!$match.Success) { throw "Missing first R19F: $role" }
  $offset = $match.Index - 11
  [byte[]]$frame = $raw[$offset..($offset+62)]
  $crc = Check-Crc $frame 83
  if ($frame[0] -ne 253 -or $frame[1] -ne 51 -or $frame[5] -ne 254 -or $frame[6] -ne 190 -or $frame[7] -ne 253 -or $frame[8] -ne 0 -or $frame[9] -ne 0 -or !$crc.valid) { throw "Invalid runtime-failure frame: $role" }
  $lastOffset = $offset + $frame.Length - 1
  $blocks = @($metadata.blocks | Where-Object { [int64]$_.offset -le $lastOffset -and ([int64]$_.offset + [int64]$_.count) -gt $lastOffset })
  if ($blocks.Count -ne 1) { throw "Ambiguous final-byte block: $role" }
  $block = $blocks[0]
  if ($block.clock_domain_id -cne $capture.clock_domain_id -or [int64]$block.frequency -ne [int64]$capture.frequency) { throw 'Clock domain mismatch' }
  $status = $match.Value.Substring(29,12)
  $reservation = $stage.decoded.grant_reservation
  $identity = $reservation.identity
  $peerRole = if ($role -eq 'vehicle') { 'ground' } else { 'vehicle' }
  $hello = $capture.grant_reservation_workflow."hello_$role"
  $peerHello = $capture.grant_reservation_workflow."hello_$peerRole"
  $binding = [pscustomobject]@{
    role_matches=($reservation.role -ceq $role)
    own_boot_matches_usb_hello=([string]$identity.own_boot_id -ceq [string]$hello.boot_id)
    peer_boot_matches_usb_hello=([string]$identity.peer_boot_id -ceq [string]$peerHello.boot_id)
    own_epoch_matches_usb_hello=([string]$identity.own_usb_epoch -ceq [string]$hello.usb_epoch)
    reader_session_matches=([string]$identity.reader_session -ceq [string]$capture.grant_reservation_workflow.reader_session)
    slot_nonce_matches=([string]$identity.slot_nonce -ceq [string]$capture.grant_reservation_workflow.slot_nonce)
    prepared_grant_matches=([string]$identity.grant_session -ceq [string]$capture.grant_reservation_workflow.prepared.grant_session -and [string]$identity.grant_cycle -ceq [string]$capture.grant_reservation_workflow.prepared.grant_cycle)
    prepared_token_matches=([string]$identity.writer_token -ceq [string]$capture.grant_reservation_workflow.prepared.slot_token -and [string]$identity.writer_generation -ceq [string]$capture.grant_reservation_workflow.prepared.generation)
    decoder_identity_bound=$reservation.expected_identity_bound
  }
  foreach ($p in $binding.PSObject.Properties) { if ($p.Value -ne $true) { throw "Binding not proven: $role/$($p.Name)" } }
  $roleEvidence[$role] = [pscustomobject]@{
    stage_path=$stagePath;stage_sha256=(Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash
    raw_path=$rawPath;raw_size=$raw.Length;raw_sha256=(Hash-Bytes $raw)
    first_runtime_failure=[pscustomobject]@{
      text=$match.Value;raw_offset=$offset;raw_last_offset=$lastOffset;frame_bytes=$frame.Length
      frame_hex=([BitConverter]::ToString($frame)).Replace('-','');frame_base64=[Convert]::ToBase64String($frame);frame_sha256=(Hash-Bytes $frame);crc=$crc
      source_line=[Convert]::ToInt32($match.Value.Substring(7,4),16);device_ms=[Convert]::ToInt64($match.Value.Substring(12,16),16)
      status_hex=$status;status_bytes=@(0..5 | ForEach-Object { [Convert]::ToInt32($status.Substring(2*$_,2),16) })
      final_byte_read_block=$block
      block_semantics='PC read-return bracket for the block containing the complete failure frame; no claim of USB wire arrival time or MCU clock equality.'
    }
    record_binding=$binding;identity=$identity;reservation_first_failure=$reservation.first_failure;reservation_journal=$reservation.journal
    grant_diagnostic=$stage.decoded.grant_diagnostic | Select-Object failure_latched,first_failure,latest,journal_count,journal_dropped,journal_complete,journal
    product_first_usb_failure_latched=$stage.decoded.first_usb_failure.failure_latched
    boot_diagnostic_first_usb_failure=$stage.decoded.diagnostic_usb_failure.first_failure | Select-Object failure_observed_us,budget_ms,expected_frame_bytes,accepted_frame_bytes,sdk
    aux_summary=$stage.decoded.aux_readiness.aux_observation | Select-Object first_low_us,first_high_us,last_aux_level,last_uart_begin_us,last_uart_end_us,uart_calls,fault_code,first_fault_latched,maximum_poll_gap_us
    aux_edge_count=$stage.decoded.aux_readiness.aux_edges.event_count
  }
}
$vehicle = $roleEvidence.vehicle
$ground = $roleEvidence.ground
$request = $capture.param_list_diagnostics.request
$release = @($capture.grant_reservation_workflow.commands | Where-Object kind -eq 'ReleaseVehicle')
if ($release.Count -ne 1) { throw 'Expected exactly one ReleaseVehicle command' }
$release = $release[0]
$frequency = [decimal]$capture.frequency
$failureReadEnd = [decimal]$vehicle.first_runtime_failure.final_byte_read_block.end_ticks
$beforeParamMs = ([decimal]$request.write_started_ticks - $failureReadEnd) * 1000 / $frequency
$beforeReleaseMs = ([decimal]$release.started_ticks - $failureReadEnd) * 1000 / $frequency
if ($beforeParamMs -le 0 -or $beforeReleaseMs -le 0) { throw 'Failure did not precede both writes' }
$heartbeats = @()
$groundMeta = @($capture.roles | Where-Object role -eq 'ground')[0]
$groundRaw = [IO.File]::ReadAllBytes((Join-Path $run 'capture/ground.raw.bin'))
foreach ($item in $groundMeta.product_observations) {
  $offset = [int]$item.raw_offset
  [byte[]]$frame = $groundRaw[$offset..($offset+[int]$item.frame_bytes-1)]
  $crc = Check-Crc $frame 50
  $hash = Hash-Bytes $frame
  if ($frame[0] -ne 253 -or $frame[1] -ne 9 -or $frame[5] -ne 1 -or $frame[6] -ne 1 -or $frame[7] -ne 0 -or $frame[8] -ne 0 -or $frame[9] -ne 0 -or !$crc.valid -or $hash -cne $item.frame_sha256) { throw 'Heartbeat raw verification failed' }
  $heartbeats += [pscustomobject]@{raw_offset=$offset;read_completed_ticks=$item.read_completed_ticks;frame_sha256=$hash;crc_valid=$true;phase=$(if ([decimal]$item.read_completed_ticks -lt [decimal]$capture.measurement_start_ticks) {'preparation'} else {'measurement'})}
}
$path = $stages.ground.decoded.timed_path
$result = [ordered]@{
  schema='vc-lora-r19-reservation-failure-derived-readonly-v1';generated_at_utc=[DateTime]::UtcNow.ToString('o')
  mode='OFFLINE_SAVED_FILE_ANALYSIS';hardware_interaction=$false;original_files_modified=$false
  actual_run=$run;capture_path=$capturePath;capture_sha256=(Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
  candidate_id=$capture.candidate_id;handoff_sha256=$capture.handoff_sha256;flash_evidence_sha256=$capture.flash_evidence_sha256
  firmware_build_fingerprint=$stages.vehicle.decoded.grant_reservation.build_fingerprint
  cross_role_build_fingerprint_matches=(($stages.vehicle.decoded.grant_reservation.build_fingerprint -join ',') -ceq ($stages.ground.decoded.grant_reservation.build_fingerprint -join ','))
  roles=$roleEvidence
  pc_same_clock_order=[ordered]@{
    clock_domain_id=$capture.clock_domain_id;frequency=$capture.frequency
    vehicle_failure_complete_read_end_ticks=[string]$failureReadEnd;measurement_start_ticks=$capture.measurement_start_ticks
    param_write_start_ticks=$request.write_started_ticks;param_write_return_ticks=$request.write_returned_ticks;param_accepted_bytes=$request.accepted_bytes
    release_write_start_ticks=$release.started_ticks;release_write_return_ticks=$release.returned_ticks;release_accepted_bytes=$release.accepted_bytes
    vehicle_failure_received_before_param_ms=$beforeParamMs;vehicle_failure_received_before_release_ms=$beforeReleaseMs
    vehicle_failure_received_before_measurement=($failureReadEnd -lt [decimal]$capture.measurement_start_ticks)
    conclusion='Vehicle fail-closed notification was already completely read on the PC before PARAM and ReleaseVehicle writes. No PC/MCU offset or cross-MCU subtraction is used.'
  }
  same_mcu_deltas=[ordered]@{
    vehicle_prepared_ms=39202;vehicle_bound_peer_ms=39257;vehicle_external_fault_ms=39356;prepared_to_failure_ms=154;bound_peer_to_failure_ms=99
    ground_request_origin_ms=26016;ground_grant_deadline_failure_ms=26517;ground_wait_ms=501
  }
  release_and_grant_conclusions=[ordered]@{
    release_local_pc_write_accepted=$true;release_reached_vehicle_proven=$false
    reservation_vehicle_journal_complete=$stages.vehicle.decoded.grant_reservation.journal_complete
    reservation_vehicle_release_event_count=@($stages.vehicle.decoded.grant_reservation.journal | Where-Object event_name -eq 'ReleaseGrant').Count
    reserved_cycle_grant_generated=$true;reserved_cycle_uart_acceptance_observed=$false;reserved_cycle_physical_tail_observed=$false
    no_tail_ready=$true;ground_tail_permit_sent=$false;high_speed_started_proven=$false
    explanation='Vehicle failed while holding the generated Grant before PC sent ReleaseVehicle; the reserved cycle 661/3 was generated, but UART acceptance, RF tail, fresh Grant reception and TailReady were not observed. Ground then failed its own original 500 ms wait after 501 ms.'
  }
  source_interpretation=[ordered]@{
    branch_path='firmware/phase6/vc_lora_phase6_bridge.hpp';abort_detail=13;branch_lines='7202-7227';source_failure_publisher_line=7028
    unseparated_predicates=@('reservation.failed','heartbeat_urgent','direct aux_high() false','lease invalid or owner/action/generation mismatch','radio_busy','pending_radio_action.active','standard_radio_writer_tail_pending')
    vehicle_latched_status=[ordered]@{startup_fault=0;e220_state=1;e220_state_name='Ready';e220_fault=0;writer_status=1;writer_status_name='LeaseGranted';radio_session_status=0;radio_session_status_name='Idle';tdd_state=2;tdd_state_name='SendUlGrant';adapter_fail_closed=$false}
    exact_gpio_at_failure_proven=$false;exact_heartbeat_predicate_at_failure_proven=$false;exact_lease_fields_at_failure_proven=$false
    aux_observation_limit='The failing branch calls direct aux_high() at line 2746, not the timestamped overload; the record has no immutable GPIO sample for 39356 ms. Vehicle has no recorded LOW/ISR edge and no E220 fault, but continuous physical waveform/interrupt coverage is not proven.'
    strong_design_candidate=[ordered]@{
      hypothesis='A new queued Heartbeat while the reserved Grant is held triggers heartbeat_urgent and aborts the reservation before ReleaseVehicle.'
      proof_level='SOURCE_SUPPORTED_INFERENCE_NOT_MEASURED_PREDICATE'
      heartbeat_deadline_ms=2500;heartbeat_grant_reserve_ms=5050
      reasoning='Any available Heartbeat with enqueue+2500 ms deadline satisfies the <=5050 ms urgent reserve immediately. Pixhawk ingress runs at 7753 before held Grant service at 7816; while holding, service returns at 7220 and prevents the normal TDD tick at 7828. Standard TDD would reopen a Heartbeat tail instead (core/src/tdd_vehicle.cpp 280-284). No heartbeat-presence/deadline bit was saved at the ExternalFault13 boundary.'
      source_paths=@('core/include/vc_lora/runtime_contract.hpp:60','firmware/phase6/vc_lora_phase6_bridge.hpp:6935','firmware/phase6/vc_lora_phase6_bridge.hpp:7207','firmware/phase6/vc_lora_phase6_bridge.hpp:7753','core/src/tdd_vehicle.cpp:280')
    }
    runner_followup='The PC had read a valid runtime fail frame before issuing PARAM and ReleaseVehicle. The reservation runner did not turn this into an early aborted/final failure status; WaitingVehicleTail with empty failure is incomplete, not success.'
  }
  heartbeat_and_parameters=[ordered]@{
    raw_verified_heartbeat_count=$heartbeats.Count;preparation_heartbeat_count=@($heartbeats|Where-Object phase -eq 'preparation').Count;measurement_heartbeat_count=@($heartbeats|Where-Object phase -eq 'measurement').Count
    heartbeats=$heartbeats;first_heartbeat_usb_commit_us=([decimal]$path.timestamps.terminal_us-[decimal]$path.timestamps.enqueue_us);first_heartbeat_usb_completed=$path.usb_completed;product_budget_ms=$path.product_budget_ms
    continuity_40_seconds_proven=$false;target_count=932;parameters_30s=$capture.param_list_diagnostics.snapshot_30s.unique_count;parameters_final=$capture.param_list_diagnostics.unique_count
    parameter_request_attempts=$capture.param_list_diagnostics.request_attempts;parameter_parser_errors=$capture.param_list_diagnostics.errors
    all_system_errors_zero=$false
  }
  limitations=@('No hardware, network, COM, GPIO, process or JTAG operation performed by this analysis.','Original HIL result and artifacts are preserved. Derived analysis does not change FAIL_STAGE_READ_R18_RESTORED.','Runtime first failure and boot diagnostic USB flush timeout are distinct records and times. Product USB first-failure latch is false in both roles.','PC write acceptance alone does not prove MCU command processing, RF delivery or parameter transfer.','The exact ExternalFault13 OR operand is not recorded. No physical AUX waveform was acquired.','No additional test/retry authorization is implied.')
}
[IO.File]::WriteAllText($output, ($result | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{result='PASS_DERIVED_READONLY_ANALYSIS';output=$output;sha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash;before_param_ms=$beforeParamMs;before_release_ms=$beforeReleaseMs;heartbeat_total=$heartbeats.Count} | ConvertTo-Json
