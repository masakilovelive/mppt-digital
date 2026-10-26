[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $OutputDirectory = Join-Path $repo `
      "runs\validation\R18-SINGLE-PARAM-LIVENESS-RUNNER-CONTRACT-001\$stamp"
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite contract evidence: $OutputDirectory"
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)

$checks = [Collections.ArrayList]::new()
function Add-Check([string]$Name,[bool]$Valid,[string]$Detail) {
  [void]$checks.Add([pscustomobject][ordered]@{
    name=$Name;valid=$Valid;detail=$Detail
  })
}

$runnerPath = Join-Path $repo 'tools\run_r18_single_param_liveness_hil.ps1'
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
    if ($matches.Count -ne 1) {return ''}
    return $matches[0].Extent.Text
  }
  function Get-FunctionAst([string]$Name) {
    $matches = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -ceq $Name
    },$true))
    if ($matches.Count -ne 1) {return $null}
    return $matches[0]
  }

  $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
  })
  $identity = Get-FunctionText 'Assert-ExactGroundIdentity'
  $processGate = Get-FunctionText 'Assert-NoCompetingClients'
  $processClassifier = Get-FunctionText 'Get-CompetingClientGateFromSnapshot'
  $claim = Get-FunctionText 'Claim-OneRunAuthorization'
  $serialFactory = Get-FunctionText 'New-GroundSerialPort'
  $requestFactory = Get-FunctionText 'New-ExactParamRequestRead'
  $requestWrite = Get-FunctionText 'Invoke-ExactRequestWrite'
  $parser = Get-FunctionText 'Add-MavlinkBytes'
  $dataByte = Get-FunctionText 'Add-MavlinkDataByte'
  $record = Get-FunctionText 'Convert-MavlinkFrameRecord'
  $primaryHeartbeat = Get-FunctionText 'Get-PrimaryHeartbeats'
  $freshPrimaryHeartbeat = Get-FunctionText 'Get-FreshPrimaryHeartbeats'
  $preflight = Get-FunctionText 'Wait-HeartbeatPreflight'
  $preflightEvidence = Get-FunctionText 'Get-HeartbeatPreflightSnapshot'
  $isolatedWarmup = Get-FunctionText 'Invoke-OfflinePrewarm'
  $boundary = Get-FunctionText 'Confirm-FinalRequestBoundary'
  $paramId = Get-FunctionText 'Get-ParamValueId'
  $targetResponse = Get-FunctionText 'Test-ExactTargetResponseRecord'
  $account = Get-FunctionText 'Get-SingleParamAcceptance'
  $pumpState = Get-FunctionText 'New-PumpTimingState'
  $pumpRegister = Get-FunctionText 'Register-PumpService'
  $pumpEvidence = Get-FunctionText 'Get-PumpTimingEvidence'
  $readPump = Get-FunctionText 'Read-AvailableSerial'
  $frameBuffer = Get-FunctionText 'Buffer-NewFrameEvents'
  $capturePersistence = Get-FunctionText 'Write-BufferedCaptureArtifacts'
  $historicalReplay = Get-FunctionText 'Invoke-HistoricalLiveRawReplay'
  $measurement = Get-FunctionText 'Invoke-LiveMeasurement'
  $measurementAst = Get-FunctionAst 'Invoke-LiveMeasurement'
  $cleanup = Get-FunctionText 'Invoke-FailClosedCleanupPlan'
  $selectedArtifact = Get-FunctionText 'Write-SelectedResponseArtifact'
  $offline = Get-FunctionText 'Invoke-OfflineSelfTest'
  $complete = Get-FunctionText 'Complete-Evidence'

  Add-Check 'live_requires_exact_one_run_safety_and_cold_boot_tokens' (
      $parameterNames -contains 'HilAuthorization' -and
      $parameterNames -contains 'AuthorizationId' -and
      $parameterNames -contains 'OperatorSafetyAttestation' -and
      $parameterNames -contains 'ColdBootAttestation' -and
      $source.Contains('4EEB5CC999ECFA4D9A6CEA5FF4A365EB6BBF15C9DD1F19CF43429A565F6C9914') -and
      $source.Contains('E80E5B41C124DD113EC0989D8E8D77F4257FA356C4B3419E5E731E5F01E526D4') -and
      $source.Contains('8854A0D9813F2783F9A368558BE5E5D59862CD82695300E74ECD1423C43925C5') -and
      $claim -match 'FileMode\]::CreateNew' -and
      $claim -match 'replay rejected' -and
      $source -match 'Claim-OneRunAuthorization\s+\$AuthorizationId' -and
      $source -match 'authorization_consumed=\(\$null-ne\$script:AuthorizationClaim\)' -and
      $source -match 'authorization_reusable=\$false') `
      'exact authorization, unique atomic claim, six-condition safety, and simultaneous >=5 s cold-boot attestations are hard gates'

  $claimCall = $source.IndexOf('Claim-OneRunAuthorization $AuthorizationId',
      [StringComparison]::Ordinal)
  $measurementCall = $source.LastIndexOf('$measurement=Invoke-LiveMeasurement',
      [StringComparison]::Ordinal)
  $processCall = $measurement.IndexOf('$processInventory=Assert-NoCompetingClients',
      [StringComparison]::Ordinal)
  $comOpenCall = $measurement.IndexOf('$serial.Open()',
      [StringComparison]::Ordinal)
  Add-Check 'authorization_claim_precedes_all_live_observation_and_open' (
      $claimCall -ge 0 -and $measurementCall -gt $claimCall -and
      $processCall -ge 0 -and $comOpenCall -gt $processCall -and
      $source -match "authorization_claim\.json" -and
      $source -match 'authorization_claim_sha256' -and
      $source -notmatch 'authorization_token=\$HilAuthorization' -and
      $source -notmatch 'operator_safety_attestation=\$OperatorSafetyAttestation' -and
      $source -notmatch 'cold_boot_attestation=\$ColdBootAttestation') `
      'atomic claim is consumed before live inspection/open and all evidence, including pinned runner, retains only token hashes'

  Add-Check 'exact_ground_com6_identity_and_com3_prohibition' (
      $source.Contains("GroundPort = 'COM6'") -and
      $source.Contains("ForbiddenPorts = @('COM3')") -and
      $source.Contains('USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000') -and
      $source.Contains('USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80') -and
      $identity -match 'Win32_SerialPort' -and
      $identity -match 'DEVPKEY_Device_Parent' -and
      $identity -match 'ConfigManagerErrorCode' -and
      $identity -match "Status\s*-ceq\s*'OK'" -and
      $identity -match 'Count\s*-eq\s*1' -and
      $source -notmatch "SerialPort\]::new\(\s*'COM3'") `
      'only the exact healthy Ground interface/parent may be opened; COM3 is never opened or written'

  Add-Check 'process_gate_checks_names_and_command_lines' (
      $processClassifier -match 'missionplanner' -and
      $processClassifier -match 'mavproxy' -and
      $processClassifier -match 'qgroundcontrol' -and
      $processClassifier -match 'putty' -and
      $processClassifier -match 'teraterm' -and
      $processClassifier -match 'ttermpro' -and
      $processClassifier -match 'coolterm' -and
      $processClassifier -match 'arduino' -and
      $processClassifier -match 'arduino-cli' -and
      $processClassifier -match 'serialstudio' -and
      $processClassifier -match 'esptool' -and
      $processClassifier -match 'platformio' -and
      $processClassifier -match 'plink' -and
      $processGate -match 'Win32_Process' -and
      $processClassifier -match 'CommandLine' -and
      $processClassifier -match 'COM3\|COM6' -and
      $processGate -match '\$PID' -and
      $source -match 'function Get-ProcessAncestorIds' -and
      $processClassifier -match 'Get-ProcessAncestorIds' -and
      $processClassifier -match 'ancestorSet' -and
      $processClassifier -match 'trustedAncestorNames' -and
      $processClassifier -match 'command_line_sha256' -and
      $processGate -match 'process_gate_before_open\.json') `
      'durable sanitized fail-closed process inventory is ancestor-aware/cycle-safe and includes expanded names and explicit COM references'

  Add-Check 'single_57600_8n1_handle_without_reset_lines' (
      $serialFactory -match '57600' -and
      $serialFactory -match 'Parity\]::None' -and
      $serialFactory -match 'StopBits\]::One' -and
      $serialFactory -match 'DtrEnable\s*=\s*\$false' -and
      $serialFactory -match 'RtsEnable\s*=\s*\$false' -and
      $serialFactory -match 'Handshake\]::None' -and
      [regex]::Matches($measurement,'\.Open\(').Count -eq 1 -and
      [regex]::Matches($measurement,'\.Close\(').Count -eq 1) `
      'one uninterrupted COM6 handle covers preflight, request, response and post-response heartbeat'

  Add-Check 'frozen_exact_param_request_read_written_once' (
      $source.Contains('FD14000061FFBE140000FFFF010153455249414C315F4241554400000000FC13') -and
      $source.Contains('821F1FE12A93B30FF42EEDB0CDA9CC7DE6A8D4D4E7347BDD2CB0B3A07572E2CC') -and
      $requestFactory -match 'Length\s*-eq\s*32' -and
      $requestFactory -match 'message.*20|PARAM_REQUEST_READ' -and
      $requestWrite -match 'request_attempted\s*-eq\s*0' -and
      $requestWrite -match '\.Write\(' -and
      $requestWrite -match 'request_writes_completed\s*=\s*1' -and
      $requestWrite -match 'retry.*forbidden|one-shot' -and
      $requestWrite -notmatch 'BaseStream\.Flush') `
      'the exact full 32-byte sys/comp 1/1 SERIAL1_BAUD #20 fixture is transmitted once without retry'

  $preflightCall = $measurement.IndexOf('Wait-HeartbeatPreflight',
      [StringComparison]::Ordinal)
  $boundaryCall = $measurement.IndexOf('Confirm-FinalRequestBoundary',
      [StringComparison]::Ordinal)
  $writeCall = $measurement.IndexOf('Invoke-ExactRequestWrite',
      [StringComparison]::Ordinal)
  Add-Check 'fresh_primary_heartbeat_pair_precedes_request' (
      $source -match 'HeartbeatLimitUs\s*=\s*\[int64\]2500000' -and
      $preflight -match 'Count\s*-ge\s*2' -and
      $primaryHeartbeat -match 'system_id\s*-eq\s*1' -and
      $primaryHeartbeat -match 'component_id\s*-eq\s*1' -and
      $primaryHeartbeat -match 'message_id\s*-eq\s*0' -and
      $preflightEvidence -match 'maximum_gap_us' -and
      $preflightEvidence -match 'last_heartbeat_age_us' -and
      $preflight -match '\$maximumGap\s*-le\s*\$HeartbeatLimitUs' -and
      $preflight -match '\$age\s*-le\s*\$HeartbeatLimitUs' -and
      $primaryHeartbeat -match 'version\s*-eq\s*2' -and
      $primaryHeartbeat -match 'signed' -and
      $boundary -match 'HeartbeatLimitUs' -and
      $measurement -match 'pre_heartbeat_pair=@\(\$final\.heartbeat_pair\)' -and
      $preflightCall -ge 0 -and $boundaryCall -gt $preflightCall -and
      $writeCall -gt $boundaryCall) `
      'at least two fresh unsigned MAVLink2 primary 1/1 heartbeats and <=2.5 s gap/age gate R0'

  Add-Check 'empty_preflight_heartbeat_collection_is_scalar_safe' (
      $preflight -match '@\(\$lastTwo\)\.Count' -and
      $preflight -notmatch '\$lastTwo\.Count') `
      'zero or one fresh heartbeat remains a countable collection and cannot abort preflight before the request'

  Add-Check 'initial_same_read_backlog_cannot_satisfy_preflight' (
      $record -match 'frame_start_read_ordinal' -and
      $record -match 'complete_read_ordinal' -and
      $freshPrimaryHeartbeat -match 'initial_backlog_read_ordinal' -and
      $freshPrimaryHeartbeat -match 'complete_read_ordinal' -and
      $preflightEvidence -match 'excluded_initial_backlog_heartbeat_count' -and
      $preflightEvidence -match 'distinct_read_ordinals' -and
      $preflight -match '\$distinctReads\s*-and\s*\$positiveGap' -and
      $boundary -match 'complete_read_ordinal' -and
      $boundary -match 'gap\s*-gt\s*0') `
      'the initial read batch is classified as backlog; two later positive-time heartbeats from distinct reads are required'

  Add-Check 'strict_mavlink2_crc_noise_partial_and_control_gate' (
      $dataByte -match '0xFD' -and $dataByte -match 'noise_bytes' -and
      $record -match 'Update-X25Crc' -and $record -match 'crc_extra' -and
      $record -match 'bad_crc' -and $record -match 'unsupported_flags' -and
      $record -match 'unknown_definition' -and
      $source -match '18D9E462805F310BC60FCE7C40CF998DE6F9B4EF1EE1E6A0FC652E82CB71A5EC' -and
      $parser -match 'classified_startup_bytes' -and
      $parser -match 'startup_classification_pending' -and
      $source -match "EXACT_INITIAL_ESP32S3_ROM_BANNER_ALLOWLIST_2_VARIANTS_ONLY" -and
      $account -match 'partial_bytes' -and
      $account -match 'control_leakage_bytes' -and
      $account -match 'parser_error_count' -and
      $account -match 'parser_error_count\s*-eq\s*0') `
      'strict parser classifies only a complete initial allowlisted banner and requires all unclassified CRC/noise/partial/control leakage zero'

  Add-Check 'boot_banner_allowlist_pins_both_observed_exact_variants' (
      $source -match 'F0CB01EE2BBA099E7F0F27AC965A52C22E0C3D417EE25D9D876EDCD483AB9AEC' -and
      $source -match '18D9E462805F310BC60FCE7C40CF998DE6F9B4EF1EE1E6A0FC652E82CB71A5EC' -and
      $source -match '\$exactBootBannerVariants' -and
      $parser -match 'startup_candidate_ids' -and
      $parser -match 'classified_startup_variant' -and
      $parser -match 'classified_startup_sha256' -and
      $parser -notmatch '\[regex\]|-replace|-like|-match') `
      'only the exact 265-byte boot 0xb and 266-byte boot 0x2b records may be classified; no pattern-based parser exemption'

  Add-Check 'preflight_timeout_retains_observed_snapshot_and_counts' (
      $preflightEvidence -match 'parser_snapshot' -and
      $preflightEvidence -match 'read_count' -and
      $preflightEvidence -match 'raw_bytes' -and
      $preflightEvidence -match 'heartbeat_count' -and
      $preflightEvidence -match 'parser_error_count' -and
      $preflight -match '\$script:LastPreflightEvidence\s*=' -and
      $preflight -match 'Get-HeartbeatPreflightSnapshot' -and
      $measurement -match '\$preflight\s*=\s*\$script:LastPreflightEvidence') `
      'a timeout preserves concrete zero or partial receive/parser/heartbeat evidence instead of a null preflight record'

  $warmupIndex=$measurement.IndexOf('Invoke-OfflinePrewarm',
      [StringComparison]::Ordinal)
  $liveParserIndex=$measurement.IndexOf("New-MavlinkParser 'ground_com6'",
      [StringComparison]::Ordinal)
  Add-Check 'cold_path_warmup_is_isolated_and_precedes_live_capture' (
      $isolatedWarmup -match 'New-MavlinkParser' -and
      $isolatedWarmup -match 'New-FakeSerial|Simulation' -and
      $isolatedWarmup -notmatch '\.Open\(|Get-CimInstance|Get-PnpDeviceProperty|Assert-ExactGroundIdentity|Invoke-ExactRequestWrite' -and
      $warmupIndex -ge 0 -and $liveParserIndex -gt $warmupIndex -and
      $comOpenCall -gt $warmupIndex -and
      $readPump -match 'read_parse_complete_us' -and
      $readPump -match 'read_parse_duration_us') `
      'simulated cold-path work occurs before a new empty live parser; substage evidence retains actual live pump costs and the 100 ms gate'

  Add-Check 'exact_one_serial1_baud_response_and_post_heartbeat' (
      $targetResponse -match 'message_id\s*-ne\s*22|Test-TargetParamIdRecord' -and
      $targetResponse -match 'system_id\s*-eq\s*1' -and
      $targetResponse -match 'component_id\s*-eq\s*1' -and
      $account -match 'SERIAL1_BAUD' -and
      $targetResponse -match '0x42640000' -and
      $account -match '57600' -and
      $targetResponse -match 'ToUInt16.*offset\+4.*-eq\s*932' -and
      $targetResponse -match 'ToUInt16.*offset\+6.*-eq\s*0xFFFF' -and
      $targetResponse -match 'offset\+24.*-eq\s*6' -and
      $account -match 'exact_response_count\s*-eq\s*1' -and
      $account -match 'message_id\s*-eq\s*345' -and
      $account -match 'param_error_frames' -and
      $account -match 'frame_start_us.*request_complete_write_edge_us' -and
      $account -match 'complete_us.*request_complete_write_edge_us' -and
      $account -match 'noncausal_parameter_frames' -and
      $account -match 'post_response_heartbeat_count' -and
      $account -match 'duplicate_observation_completed' -and
      $account -match 'gap_ledger' -and
      $account -match 'HeartbeatLimitUs' -and
      $source -match 'DuplicateObservationUs\s*=\s*\[int64\]10000000' -and
      $selectedArtifact -match 'exact_param_value_response\.bin' -and
      $selectedArtifact -match 'raw_sha256' -and
      $record -match 'stored_crc' -and $record -match 'computed_crc') `
      'one causal exact 1/1 #22 with full raw/tuple/CRC proof, no #345/duplicate for >=10 s, plus complete heartbeat ledger'

  Add-Check 'target_param_isolated_from_valid_background_param_values' (
      $paramId -match 'message_id.*22' -and
      $paramId -match 'payload_offset' -and
      $account -match 'target_parameter_frames' -and
      $account -match 'target_semantic_mismatch_count' -and
      $account -match 'duplicate_target_response_count' -and
      $account -match 'background_parameter_frames' -and
      $account -match 'background_parameter_ledger' -and
      $account -match 'exact_response_count\s*-eq\s*1' -and
      $account -match '\$targetSemanticMismatchCount\s*-eq\s*0' -and
      $account -notmatch '\$parameterFrames\.Count\s*-eq\s*1') `
      'only exact padded SERIAL1_BAUD is a target response; valid different-ID #22 frames are preserved and allowed'

  Add-Check 'bounded_90s_and_100ms_service_gates' (
      $source -match 'OverallTimeoutUs\s*=\s*\[int64\]90000000' -and
      $source -match 'PumpServiceLimitUs\s*=\s*\[int64\]100000' -and
      $measurement -match 'OverallTimeoutUs' -and
      $measurement -match 'Get-PumpTimingEvidence' -and
      $measurement -match '\$pumpTiming' -and
      $account -match 'maximum_pump_service_gap_us' -and
      $account -match 'PumpServiceLimitUs') `
      'one 90 s no-retry deadline and <=100 ms pump gap are hard gates'

  $timedLoopText=''
  if($null-ne$measurementAst) {
    $timedLoops=@($measurementAst.Body.FindAll({
      param($node)
      $node -is [Management.Automation.Language.WhileStatementAst] -and
          $node.Extent.Text -match 'Read-AvailableSerial'
    },$true))
    if($timedLoops.Count-eq1){$timedLoopText=$timedLoops[0].Extent.Text}
  }
  $openIndex=$measurement.IndexOf('$serial.Open()',
      [StringComparison]::Ordinal)
  $closeIndex=$measurement.IndexOf('$serial.Close()',
      [StringComparison]::Ordinal)
  $hotOpenInterval=if($openIndex-ge0 -and $closeIndex-gt$openIndex){
    $measurement.Substring($openIndex,$closeIndex-$openIndex)
  }else{''}
  Add-Check 'timed_pump_is_memory_only_incremental_and_phase_accounted' (
      $measurement -match 'MemoryStream' -and
      $measurement -match 'New-PumpTimingState' -and
      $measurement -match 'Set-PumpPhase' -and
      $readPump -match 'Register-PumpService' -and
      $readPump -notmatch 'Write-JsonLine|ConvertTo-Json|FileStream|Flush\(' -and
      $frameBuffer -notmatch 'Write-JsonLine|ConvertTo-Json|FileStream|Flush\(' -and
      $capturePersistence -match 'ground\.raw\.bin' -and
      $capturePersistence -match 'timeline\.jsonl' -and
      $capturePersistence -match 'frame_events\.jsonl' -and
      $pumpState -match 'gap_ledger' -and
      $pumpRegister -match 'from_phase' -and
      $pumpRegister -match 'to_phase' -and
      $pumpEvidence -match 'phase_summary' -and
      $pumpEvidence -match 'ledger_count' -and
      $readPump -match '\$readOrdinal-lt0' -and
      $timedLoopText -match 'Update-TargetResponseProgress' -and
      $timedLoopText -notmatch 'Get-SingleParamAcceptance|Where-Object|ConvertTo-Json|Write-Durable|FileStream|Get-FileHash|Get-CimInstance' -and
      $hotOpenInterval -notmatch 'Assert-ExactGroundIdentity|Get-CimInstance|Get-PnpDeviceProperty|Write-Durable|ConvertTo-Json|Get-FileHash' -and
      $account -match 'timing_result' -and
      $account -match 'PumpServiceLimitUs') `
      'timed capture performs memory-only incremental work and retains the unchanged 100 ms gate with a phase-aware gap ledger'

  Add-Check 'sealed_live_raw_replay_separates_product_and_harness_results' (
      $source -match 'FB2F9704EC1AD611ACFE8DE28681EA70AD0C89F0A88D4E3194183E09DB228366' -and
      $source -match 'F62DF76BA8C0083B3DE37749CD28F3B5318DE70BF86D29E062578C66718DD6BD' -and
      $historicalReplay -match 'product_path_result' -and
      $historicalReplay -match 'historical_harness_result' -and
      $historicalReplay -match 'preflight_freshness_result' -and
      $historicalReplay -match 'background_parameter_ledger' -and
      $historicalReplay -match 'source_immutable' -and
      $offline -match 'historical_live_raw_replay_product_path_positive' -and
      $offline -match 'historical_live_raw_replay_harness_failure_preserved') `
      'the immutable sealed raw capture replays as product-path PASS while preserving historical preflight/pump harness FAIL'

  Add-Check 'non_mutating_scope_and_cleanup_proof' (
      $source -match 'firmware_write_attempted=\$false' -and
      $source -match 'e220_write_attempted=\$false' -and
      $source -match 'actuator_command_attempted=\$false' -and
      $source -notmatch 'write_flash|erase_flash|arduino-cli\s+.*upload|openocd\s+-f' -and
      $cleanup -match 'foreach\s*\(\$step\s+in\s+\$Steps\)' -and
      $measurement -match 'serial_close' -and
      $measurement -match 'serial_dispose' -and
      $measurement -match 'buffered_capture_persist_after_close' -and
      $measurement.IndexOf("name='buffered_capture_persist_after_close'",
          [StringComparison]::Ordinal)-gt
          $measurement.IndexOf("name='serial_close'",[StringComparison]::Ordinal) -and
      $measurement -match 'serial_is_open_after_cleanup' -and
      $processGate -match 'process_gate_before_open\.json') `
      'no firmware/E220/actuator mutation; process and cleanup proofs are durable and failures are acceptance failures'

  Add-Check 'pinned_accepted_r18_and_durable_sealed_evidence' (
      $source.Contains('3F8A79F26457013C3918A82A1D9F64F69D55C76890CA72C6F842E43C35E20268') -and
      $source.Contains('30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5') -and
      $source.Contains('9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52') -and
      $complete -match 'summary\.json' -and
      $complete -match 'artifact_manifest\.json' -and
      $complete -match 'SHA256SUMS\.txt' -and
      $complete -match 'final_seal\.json' -and
      $complete -match 'runner_start_sha256' -and
      $complete -match 'runner_end_sha256' -and
      $complete -match 'authorization_claim_sha256' -and
      $complete -match 'authorization_consumed=\(\$null-ne\$script:AuthorizationClaim\)' -and
      $source -match 'Refusing to overwrite evidence') `
      'accepted-R18 proof and both role hashes are pinned; path-set, manifest, sums, seal and runner hashes are durable'

  Add-Check 'offline_suite_has_required_positive_and_negatives' (
      $offline -match 'positive_exact_roundtrip' -and
      $offline -match 'missing_preflight_heartbeat_negative' -and
      $offline -match 'heartbeat_gap_negative' -and
      $offline -match 'wrong_source_negative' -and
      $offline -match 'wrong_param_id_negative' -and
      $offline -match 'wrong_value_negative' -and
      $offline -match 'wrong_param_count_negative' -and
      $offline -match 'wrong_param_index_negative' -and
      $offline -match 'wrong_param_type_negative' -and
      $offline -match 'signed_response_negative' -and
      $offline -match 'mavlink1_response_negative' -and
      $offline -match 'wrong_payload_length_negative' -and
      $offline -match 'noncausal_response_negative' -and
      $offline -match 'duplicate_response_negative' -and
      $offline -match 'valid_background_param_values_positive' -and
      $offline -match 'target_semantic_mismatch_negative' -and
      $offline -match 'same_read_batch_preflight_heartbeats_not_fresh_negative' -and
      $offline -match 'missing_post_response_heartbeat_negative' -and
      $offline -match 'crc_negative' -and
      $offline -match 'noise_negative' -and
      $offline -match 'partial_negative' -and
      $offline -match 'pump_gap_negative' -and
      $offline -match 'write_retry_negative' -and
      $offline -match 'write_drain_ambiguity_negative' -and
      $offline -match 'near_boot_banner_negative' -and
      $offline -match 'cleanup_failure_negative' -and
      $offline -match 'process_gate_trusted_ancestor_cycle_positive' -and
      $offline -match 'process_gate_competitor_sanitized_negative' -and
      $offline -match 'authorization_atomic_claim_and_replay_negative' -and
      $offline -match 'offline_external_actions_zero') `
      'synthetic tests prove the positive path and each safety/acceptance failure independently'

  $offlineDirectory = Join-Path $OutputDirectory 'offline_behavior'
  try {
    $offlineOutput = & $runnerPath -RepoRoot $repo `
        -OutputDirectory $offlineDirectory -OfflineSelfTest 2>&1
    $offlineExit = $LASTEXITCODE
    $summaryPath = Join-Path $offlineDirectory 'summary.json'
    $summary = if (Test-Path -LiteralPath $summaryPath) {
      Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
    } else {$null}
    Add-Check 'offline_behavioral_suite_passes' (
        $offlineExit -eq 0 -and $null -ne $summary -and
        [string]$summary.result -ceq 'PASS' -and
        [int]$summary.failed_count -eq 0 -and
        [int]$summary.test_count -ge 30 -and
        -not [bool]$summary.external_actions.com_ports_opened -and
        -not [bool]$summary.external_actions.serial_write_attempted -and
        -not [bool]$summary.external_actions.firmware_write_attempted) `
        (($offlineOutput | Out-String).Trim())

    $requiredRegressionTests=@(
      'exact_boot_banner_265_classification_positive',
      'exact_boot_banner_266_classification_positive',
      'boot_banner_fragmented_positive',
      'boot_banner_unlisted_variant_negative',
      'boot_banner_truncated_negative',
      'near_boot_banner_negative',
      'boot_banner_each_variant_mutation_negative',
      'timeout_preflight_snapshot_zero_positive',
      'timeout_preflight_snapshot_partial_positive',
      'offline_prewarm_isolated_positive'
    )
    $regressionResults=[Collections.ArrayList]::new()
    foreach($testName in $requiredRegressionTests) {
      $matchingTests=if($null-ne$summary){
        @($summary.tests|Where-Object{[string]$_.name -ceq $testName})
      }else{@()}
      [void]$regressionResults.Add([pscustomobject]@{
        name=$testName
        valid=(@($matchingTests).Count-eq1 -and
          [string]$matchingTests[0].result-ceq'PASS')
      })
    }
    Add-Check 'observed_banner_timeout_and_warmup_regressions_execute_and_pass' (
        @($regressionResults|Where-Object{-not $_.valid}).Count-eq0) `
        (ConvertTo-Json @($regressionResults) -Compress)

    $manifestPath = Join-Path $offlineDirectory 'artifact_manifest.json'
    $sumsPath = Join-Path $offlineDirectory 'SHA256SUMS.txt'
    $sealPath = Join-Path $offlineDirectory 'final_seal.json'
    $selectedResponsePath = Join-Path $offlineDirectory `
        'exact_param_value_response.bin'
    $manifestValid = $false
    $sumsValid = $false
    $sealValid = $false
    if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
        (Test-Path -LiteralPath $sumsPath -PathType Leaf) -and
        (Test-Path -LiteralPath $sealPath -PathType Leaf)) {
      $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
      $manifestValid = $true
      foreach ($entry in @($manifest.artifacts)) {
        $path = Join-Path $offlineDirectory ([string]$entry.path).Replace('/','\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            [int64](Get-Item -LiteralPath $path).Length -ne [int64]$entry.bytes -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -cne
                [string]$entry.sha256) {$manifestValid=$false;break}
      }
      $sumsValid = $true
      foreach ($line in @(Get-Content -LiteralPath $sumsPath)) {
        $match = [regex]::Match($line,'^(?<sha>[0-9A-F]{64}) \*(?<path>.+)$')
        if (-not $match.Success) {$sumsValid=$false;break}
        $path = Join-Path $offlineDirectory $match.Groups['path'].Value.Replace('/','\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -cne
                $match.Groups['sha'].Value) {$sumsValid=$false;break}
      }
      $seal = Get-Content -Raw -LiteralPath $sealPath | ConvertFrom-Json
      $sealValid = [string]$seal.result -ceq 'PASS' -and
          [string]$seal.summary_sha256 -ceq
              (Get-FileHash -Algorithm SHA256 -LiteralPath $summaryPath).Hash -and
          [string]$seal.artifact_manifest_sha256 -ceq
              (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash -and
          [string]$seal.sha256sums_sha256 -ceq
              (Get-FileHash -Algorithm SHA256 -LiteralPath $sumsPath).Hash -and
          [string]$seal.runner_start_sha256 -ceq
              [string]$seal.runner_end_sha256 -and
          -not [bool]$seal.authorization_consumed -and
          [string]::IsNullOrEmpty([string]$seal.authorization_id) -and
          (Test-Path -LiteralPath $selectedResponsePath -PathType Leaf) -and
          [int64](Get-Item -LiteralPath $selectedResponsePath).Length -eq 37
    }
    Add-Check 'offline_evidence_recomputes' (
        $manifestValid -and $sumsValid -and $sealValid) `
        'all manifest/path-set/sums/seal and runner-integrity hashes recompute'
  } catch {
    Add-Check 'offline_behavioral_suite_passes' $false $_.Exception.Message
    Add-Check 'offline_evidence_recomputes' $false $_.Exception.Message
  }
}

$failed = @($checks | Where-Object {-not $_.valid})
$summary = [pscustomobject][ordered]@{
  schema='vc-lora-r18-single-param-liveness-runner-contract-v1'
  test_id='R18-SINGLE-PARAM-LIVENESS-RUNNER-CONTRACT-001'
  result=if ($failed.Count -eq 0) {'PASS'} else {'FAIL'}
  check_count=$checks.Count;failed_count=$failed.Count;checks=@($checks)
  runner_path=$runnerPath
}
$summaryPath = Join-Path $OutputDirectory 'summary.json'
[IO.File]::WriteAllText($summaryPath,
    (ConvertTo-Json $summary -Depth 20) + [Environment]::NewLine,$utf8)
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $summaryPath).Hash
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'),
    "$sha *summary.json$([Environment]::NewLine)",$utf8)
$summary | ConvertTo-Json -Depth 20
if ($failed.Count -ne 0) {exit 1}
exit 0
