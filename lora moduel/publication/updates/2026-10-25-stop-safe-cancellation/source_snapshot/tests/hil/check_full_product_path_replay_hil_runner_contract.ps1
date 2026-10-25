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
      "runs\high_speed\HS-G2-FULL-PATH-RUNNER-CONTRACT-001\$stamp"
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

$runnerPath = Join-Path $repo `
    'tools\run_full_product_path_param_replay_hil.ps1'
$fixtureRoot = Join-Path $repo `
    'runs\high_speed\R19-HS-G2-FROZEN-932-REPLAY-FIXTURE-001\OFFLINE-R18-ACCEPTED-V1'
$streamPath = Join-Path $fixtureRoot 'param_value_932.mavlink.bin'
$manifestPath = Join-Path $fixtureRoot 'manifest.json'
$definitionPath = Join-Path $repo 'core\src\mavlink_frame.cpp'
$expectedStreamSha = `
    'F23E2A80B2D72DCCB6F74E4EEE08452223317B22A59A5E4367A7832EF59339B6'
$expectedManifestSha = `
    '88FC22ECD53D95B41AF84210CD2A045E0B9E2833697BA7CD179843BEFFFDA7AD'
$expectedDefinitionSha = `
    'BD2890D8973C5A694D53AB2866A6B3DBF319FAE40B3CC308AE2DAE91B634F3A8'

if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
  Add-Check 'runner_exists' $false $runnerPath
} else {
  Add-Check 'runner_exists' $true $runnerPath
  $source = [IO.File]::ReadAllText($runnerPath)
  $tokens = $null
  $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile(
      $runnerPath,[ref]$tokens,[ref]$parseErrors)
  Add-Check 'runner_parses_without_error' (@($parseErrors).Count -eq 0) `
      (@($parseErrors) -join '; ')

  function Get-FunctionText([string]$Name) {
    $matches = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -ceq $Name
    },$true))
    if ($matches.Count -ne 1) { return '' }
    $matches[0].Extent.Text
  }

  $pins = Get-FunctionText 'Assert-PinnedInputs'
  $argsGate = Get-FunctionText 'Assert-LiveArguments'
  $isolation = Get-FunctionText 'Assert-PixhawkIsolated'
  $identity = Get-FunctionText 'Assert-ExplicitPortIdentity'
  $request = Get-FunctionText 'New-ExactParamRequestList'
  $replay = Get-FunctionText 'Invoke-FullPathReplay'
  $readSerial = Get-FunctionText 'Read-AvailableSerial'
  $d6Fence = Get-FunctionText 'Assert-D6ReplayFenceState'
  $parserRuntime = Get-FunctionText 'Assert-ParserRuntimeClean'
  $groundOnline = Get-FunctionText 'Assert-GroundFrameStrictOnline'
  $sequence = Get-FunctionText 'Get-FixtureSequencePolicy'
  $processRecords = Get-FunctionText 'Assert-NoCompetingProcessRecords'
  $processInventory = Get-FunctionText 'Assert-NoCompetingClients'
  $parser = Get-FunctionText 'Add-MavlinkBytes'
  $acceptance = Get-FunctionText 'Get-HighSpeedReplayAcceptance'
  $analysis = Get-FunctionText 'Get-StrictCaptureResult'
  $offline = Get-FunctionText 'Invoke-OfflineSelfTest'
  $complete = Get-FunctionText 'Complete-Evidence'

  Add-Check 'frozen_fixture_and_definitions_are_exactly_pinned' (
      (Get-FileHash -Algorithm SHA256 -LiteralPath $streamPath).Hash `
          -ceq $expectedStreamSha -and
      (Get-Item -LiteralPath $streamPath).Length -eq 34484 -and
      (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash `
          -ceq $expectedManifestSha -and
      (Get-FileHash -Algorithm SHA256 -LiteralPath $definitionPath).Hash `
          -ceq $expectedDefinitionSha -and
      $source.Contains($expectedStreamSha) -and
      $source.Contains($expectedManifestSha) -and
      $source.Contains($expectedDefinitionSha) -and
      $pins -match '932\s*\*\s*37' -and
      $pins -match 'fixture_id') `
      'accepted R18 932 stream, manifest, and MAVLink definition pins'

  Add-Check 'request_is_exact_single_mavlink2_message_21' (
      $source.Contains('FD02000063FFBE1500000101D507') -and
      $request -match '14' -and
      $replay -match 'request_writes' -and
      $replay -match 'request_writes\s*-ne\s*1') `
      'one exact 14-byte PARAM_REQUEST_LIST from GCS 255/190 to 1/1'

  Add-Check 'two_physical_ports_serve_three_logical_endpoints' (
      $source -match '\[string\]\$GroundPort' -and
      $source -match '\[string\]\$PixhawkFixturePort' -and
      $source -notmatch '\[string\]\$(?:D6|D7|Third)Port' -and
      $argsGate -match 'GroundPort' -and
      $argsGate -match 'PixhawkFixturePort' -and
      $argsGate -match 'must be distinct' -and
      $replay -match 'Read-AvailableSerial\s+\$fixtureSerial' -and
      $readSerial -match '\$Serial\.Read' -and
      $source -match '\$fixtureSerial\.Write') `
      'Ground USB plus one full-duplex D6-sniffer/D7-replayer adapter'

  Add-Check 'live_requires_explicit_exact_port_identities' (
      $source -match '\[string\]\$GroundPnpDeviceId' -and
      $source -match '\[string\]\$GroundParentDeviceId' -and
      $source -match '\[string\]\$GroundVid' -and
      $source -match '\[string\]\$GroundPid' -and
      $source -match '\[string\]\$PixhawkFixturePnpDeviceId' -and
      $source -match '\[string\]\$PixhawkFixtureParentDeviceId' -and
      $source -match '\[string\]\$PixhawkFixtureVid' -and
      $source -match '\[string\]\$PixhawkFixturePid' -and
      $argsGate -match 'IsNullOrWhiteSpace' -and
      $identity -match 'Win32_SerialPort' -and
      $identity -match 'DEVPKEY_Device_Parent' -and
      $identity -match 'PNPDeviceID' -and
      $identity -match 'VID_' -and $identity -match 'PID_') `
      'both physical ports require caller-supplied COM, PNP, parent, VID, PID'

  Add-Check 'identity_helper_avoids_readonly_pid_variable' (
      $identity -match '\[string\]\$DevicePid' -and
      $identity -notmatch '\[string\]\$Pid(?:\W|$)' -and
      $identity -match 'DevicePid\.ToUpperInvariant') `
      'PowerShell automatic read-only $PID is never rebound by identity helper'

  Add-Check 'partial_identity_preflight_is_preserved_on_failure' (
      $source -match '\$script:Preflight' -and
      $source -match 'ground_identity' -and
      $source -match 'pixhawk_fixture_identity' -and
      $source -match 'result=''PASS'';identity=\$groundIdentity' -and
      $source -match 'result=''FAIL'';failure=\$_\.Exception\.Message' -and
      $source -match 'preflight=\[pscustomobject\]\$script:Preflight') `
      'COM6 PASS remains explicit when later missing adapter identity fails'

  Add-Check 'pixhawk_coexistence_is_fail_closed' (
      $source -match 'PIXHAWK_TELEM1_D6_D7_AND_USB_DISCONNECTED' -and
      $argsGate -match 'PixhawkIsolationAttestation' -and
      $isolation -match 'Get-PnpDevice' -and
      $isolation -match 'Pixhawk|ArduPilot|Cube' -and
      $isolation -match 'throw' -and
      $source -notmatch 'AllowPixhawk') `
      'physical attestation plus detectable USB/PnP coexistence refusal'

  Add-Check 'empty_process_inventory_is_strictmode_safe' (
      $processRecords -match 'Records\.Count\s*-eq\s*0' -and
      $processRecords -match 'return' -and
      $processRecords -match 'ForEach-Object' -and
      $processRecords -notmatch '\$Records\.ProcessName' -and
      $processInventory -match 'Assert-NoCompetingProcessRecords' -and
      $processInventory -notmatch '\$found\.ProcessName' -and
      $offline -match 'empty_process_inventory_regression' -and
      $offline -match 'single_process_inventory_negative' -and
      $offline -match 'multiple_process_inventory_negative') `
      '0 records continue; 1/multiple records fail without empty-array property access'

  Add-Check 'usb_uart_electrical_safety_is_attested' (
      $source -match '\[string\]\$UsbUartElectricalAttestation' -and
      $source -match 'USB_UART_IS_3V3_TTL_VCC_DISCONNECTED_GND_COMMON' -and
      $argsGate -match 'UsbUartElectricalAttestation' -and
      $source -match 'five_volt_tx_forbidden' -and
      $source -match 'usb_uart_electrical_attestation') `
      'live mode requires 3.3 V TTL, VCC disconnected, common ground; 5 V TX forbidden'

  Add-Check 'd6_exact_request_is_a_hard_replay_fence' (
      $source -match 'd6_exact_request_observed' -and
      $d6Fence -match 'Test-ByteEqual' -and
      $source -match 'D6 request timeout' -and
      $source -match '(?s)d6_exact_request_observed.*?These absolute deadlines.*?nextParamDueUs') `
      'no D7 replay is scheduled before byte-exact request appears on D6'

  Add-Check 'd6_control_anomaly_stops_replay_immediately' (
      $d6Fence -match 'message_id\s*-eq\s*20' -and
      $d6Fence -match 'PARAM_REQUEST_READ' -and
      $d6Fence -match 'message_id\s*-eq\s*21' -and
      $d6Fence -match 'ExactRequestCount' -and
      $d6Fence -match 'throw' -and
      $replay -match 'Assert-D6ReplayFenceState' -and
      $source -match 'D7 writes stop immediately') `
      'any #20, mismatched #21, or second exact #21 hard-aborts before another D7 write'

  Add-Check 'd6_parser_integrity_is_strict_and_bounded' (
      $parserRuntime -match 'noise_bytes' -and
      $parserRuntime -match 'bad_crc' -and
      $parserRuntime -match 'bad_length' -and
      $parserRuntime -match 'unsupported_flags' -and
      $parserRuntime -match 'unknown_definition' -and
      $parserRuntime -match 'buffer\.Count' -and
      $parserRuntime -match '100000' -and
      $parserRuntime -match 'throw' -and
      $source -match 'd6_parser_result' -and
      $source -match 'partial_bytes') `
      'all D6 parser failures and an idle partial frame fail closed'

  Add-Check 'ground_online_anomaly_stops_remaining_replay' (
      $groundOnline -match 'message_id\s*-ne\s*22' -and
      $groundOnline -match 'expected' -and
      $groundOnline -match 'count' -and
      $groundOnline -match 'Test-ByteEqual' -and
      $groundOnline -match 'throw' -and
      $replay -match 'Assert-GroundFrameStrictOnline' -and
      $replay -match 'Assert-ParserRuntimeClean\s+\$groundParser') `
      'observable Ground parser/data anomaly aborts before remaining D7 frames'

  Add-Check 'absolute_25ms_param_and_1hz_heartbeat_schedule' (
      $source -match 'ParamPeriodUs\s*=\s*25000' -and
      $source -match 'HeartbeatPeriodUs\s*=\s*1000000' -and
      $source -match 'replayEpochUs\s*\+\s*\r?\n?\s*\(?\[int64\]\$paramIndex\s*\*\s*\$ParamPeriodUs' -and
      $source -match 'replayEpochUs\s*\+\s*\r?\n?\s*\(\$heartbeatOrdinal\s*\*\s*\$HeartbeatPeriodUs' -and
      $source -match 'schedule_slip_us') `
      'absolute deadlines, not chained sleeps or relative pacing'

  Add-Check 'ground_capture_parser_and_strict_932_accounting' (
      $parser -match '0xFD' -and $parser -match '0xFE' -and
      $parser -match 'unsupported_flags' -and
      $parser -match 'bad_crc' -and
      $source -match 'byte_exact_mismatch' -and
      $source -match 'missing' -and
      $source -match 'duplicate' -and
      $source -match 'out_of_order' -and
      $source -match 'wrong_source' -and
      $source -match 'count_mismatch' -and
      $source -match 'invalid_param_id' -and
      $source -match 'expected=932' -and
      $source -match 'HeartbeatLimitUs\s*=\s*2500000' -and
      $source -match 'target_30s' -and
      $source -match 'target_10s') `
      'wire CRC plus exact indexes/source/count/IDs/bytes and heartbeat SLA'

  Add-Check 'completion_targets_include_uplink_latency' (
      $replay -match 'Get-StrictCaptureResult\s+\$groundParser\s+\$FixtureFrames\s+`?\s*\r?\n?\s*\$requestWriteUs' -and
      $source -match 'ground_request_to_last_ms' -and
      $source -match 'd6_request_to_last_ms' -and
      $source -match 'ground_to_vehicle_request_latency_ms' -and
      $source -match "NotePropertyName\s+completion_epoch(?s:.*?)NotePropertyValue\s+'GROUND_REQUEST_WRITE'") `
      '30 s/10 s are measured from Ground write; D6 latency remains separate'

  Add-Check 'thirty_second_target_is_top_level_hard_gate' (
      $source -match 'Target30LimitUs\s*=\s*30000000' -and
      $source -match 'Stretch10LimitUs\s*=\s*10000000' -and
      $acceptance -match 'RequestToLastUs\s*-ge\s*0' -and
      $acceptance -match 'RequestToLastUs\s*-le\s*\$Target30LimitUs' -and
      $acceptance -match 'RequestToLastUs\s*-le\s*\$Stretch10LimitUs' -and
      $acceptance -match '(?s)result=if\s*\(\$StrictData.*?\$HeartbeatPassed.*?\$target30Pass' -and
      $analysis -match 'Get-HighSpeedReplayAcceptance' -and
      $analysis -match 'request_to_last_us' -and
      $replay -match '\$capture\.result\s*-ceq\s*''PASS''' -and
      $source -match 'result=\[string\]\$measurement\.result') `
      '30,000,000 us is a hard gate propagated through capture, measurement, and summary; 10 s remains a metric'

  Add-Check 'thirty_second_boundaries_have_offline_behavioral_coverage' (
      $offline -match 'Get-HighSpeedReplayAcceptance\s+\$true\s+\$true\s+30000000' -and
      $offline -match 'Get-HighSpeedReplayAcceptance\s+\$true\s+\$true\s+30000001' -and
      $offline -match 'Get-HighSpeedReplayAcceptance\s+\$true\s+\$true\s+10000001' -and
      $offline -match 'Get-HighSpeedReplayAcceptance\s+\$true\s+\$true\s+\(-1\)' -and
      $offline -match 'target_30s_boundary' -and
      $offline -match 'target_30s_overrun_negative' -and
      $offline -match 'target_30s_missing_negative' -and
      $offline -match 'target_10s_stretch_non_gate') `
      'offline tests cover 30,000,000 PASS, 30,000,001 FAIL, missing completion FAIL, and 10 s non-gating behavior'

  Add-Check 'unproven_firmware_and_e220_provenance_is_explicit' (
      $source -match 'FirmwareProvenance' -and
      $source -match 'E220ProfileProvenance' -and
      $complete -match 'firmware_provenance' -and
      $complete -match 'e220_profile_provenance' -and
      $source -match 'result=''UNPROVEN''' -and
      $source -match 'verified=\$false' -and
      $source -notmatch 'firmware_provenance[^\r\n]*PASS' -and
      $source -notmatch 'e220_profile_provenance[^\r\n]*PASS' -and
      $offline -match 'provenance_unproven') `
      'firmware and E220 profile provenance are sealed as UNPROVEN, never falsely PASS'

  Add-Check 'ground_frame_and_index_timing_ledger_is_durable' (
      $source -match 'ground_frame_ledger\.jsonl' -and
      $source -match 'ground_param_index_ledger\.jsonl' -and
      $source -match 'ground_receive_elapsed_us' -and
      $source -match 'd7_write_start_us' -and
      $source -match 'd7_to_ground_latency_us' -and
      $source -match 'per_index_latency_basis' -and
      $complete -match 'artifact_manifest\.json') `
      'valid Ground frames and per-index D7-to-Ground timestamps are sealed'

  Add-Check 'fixture_sequence_is_explicitly_non_transport' (
      $sequence -match '62' -and
      $sequence -match 'independent' -and
      $sequence -match 'transport_pass_condition' -and
      $source -match 'fixture_param_sequence_discontinuities' -and
      $source -match 'synthetic_heartbeat_sequence_series') `
      '62 frozen-source gaps and independent synthetic HB sequence are metrics, not pass gates'

  Add-Check 'offline_selftest_has_no_external_access_path' (
      $source -match 'if\s*\(\$OfflineSelfTest\.IsPresent\)' -and
      $source -match 'return\s*\n\s*\}' -and
      $offline -match 'external_actions' -and
      $offline -match 'pnp_queried\s*=\s*\$false' -and
      $offline -match 'com_ports_opened\s*=\s*\$false' -and
      $offline -match 'serial_bytes_written\s*=\s*\$false' -and
      $offline -match 'firmware_write_attempted\s*=\s*\$false' -and
      $offline -match 'ideal_ground_capture' -and
      $offline -match 'heartbeat_gap_boundary') `
      'offline simulation validates positive and negative paths before live code'

  Add-Check 'offline_covers_abort_and_epoch_regressions' (
      $offline -match 'd6_param_request_read_negative' -and
      $offline -match 'd6_second_list_negative' -and
      $offline -match 'd6_parser_noise_negative' -and
      $offline -match 'd6_parser_partial_negative' -and
      $offline -match 'ground_online_order_negative' -and
      $offline -match 'ground_request_epoch_includes_uplink' -and
      $offline -match 'writes_after_abort\s*=\s*0') `
      'offline negatives prove hard abort, full D6 integrity, and uplink-inclusive timing'

  Add-Check 'offline_covers_safety_ledgers_and_sequence_policy' (
      $offline -match 'electrical_attestation_negative' -and
      $offline -match 'ground_frame_ledger' -and
      $offline -match 'ground_param_index_ledger' -and
      $offline -match 'per_index_latency' -and
      $offline -match 'fixture_sequence_policy') `
      'offline evidence covers electrical gate, joinable ledgers, and sequence interpretation'

  Add-Check 'measurement_only_evidence_is_sealed' (
      $source -match 'R19-HS-G2-FULL-PATH-REPLAY-HIL-001' -and
      $source -match 'ground\.raw\.bin' -and
      $source -match 'vehicle_d6\.raw\.bin' -and
      $source -match 'tx_timeline\.jsonl' -and
      $complete -match 'summary\.json' -and
      $complete -match 'artifact_manifest\.json' -and
      $complete -match 'SHA256SUMS\.txt' -and
      $complete -match 'final_seal\.json' -and
      $source -match 'firmware_write_attempted=\$false' -and
      $source -notmatch 'esptool') `
      'raw captures, timing ledger, immutable inputs, summary, and final seal'
}

$failed = @($checks | Where-Object {-not $_.valid})
$summary = [pscustomobject][ordered]@{
  schema_version=1
  test_id='HS-G2-FULL-PATH-RUNNER-CONTRACT-001'
  result=if ($failed.Count -eq 0) {'PASS'} else {'FAIL'}
  check_count=$checks.Count
  failed_count=$failed.Count
  runner_path=$runnerPath
  checks=@($checks)
}
$summaryPath = Join-Path $OutputDirectory 'summary.json'
[IO.File]::WriteAllText(
    $summaryPath,(ConvertTo-Json $summary -Depth 16) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $summaryPath).Hash
[IO.File]::WriteAllText(
    (Join-Path $OutputDirectory 'SHA256SUMS.txt'),
    "$sha *summary.json$([Environment]::NewLine)",
    [Text.UTF8Encoding]::new($false))

$summary | ConvertTo-Json -Depth 16
if ($failed.Count -ne 0) { exit 1 }
