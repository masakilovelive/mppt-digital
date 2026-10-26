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
      "runs\hil\R18-PIXHAWK-PARAM-E2E-RUNNER-CONTRACT-001\$stamp"
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

$runnerPath = Join-Path $repo 'tools\run_r18_pixhawk_param_list_e2e_hil.ps1'
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
    return $matches[0].Extent.Text
  }

  $identity = Get-FunctionText 'Assert-ExactGroundIdentity'
  $serial = Get-FunctionText 'New-GroundSerialPort'
  $request = Get-FunctionText 'New-ExactParamRequestList'
  $write = Get-FunctionText 'Invoke-ExactRequestWrite'
  $parser = Get-FunctionText 'Add-MavlinkBytes'
  $record = Get-FunctionText 'Convert-MavlinkFrameRecord'
  $preflightEvidence = Get-FunctionText 'Get-PreflightEvidenceSnapshot'
  $preflight = Get-FunctionText 'Wait-PrimaryHeartbeatPreflight'
  $primaryHeartbeat = Get-FunctionText 'Get-PrimaryHeartbeatFrames'
  $boundary = Get-FunctionText 'Confirm-FinalRequestBoundary'
  $account = Get-FunctionText 'Get-StrictParamAccounting'
  $heartbeat = Get-FunctionText 'Get-HeartbeatAcceptance'
  $measurement = Get-FunctionText 'Invoke-R18PixhawkMeasurement'
  $progress = Get-FunctionText 'Update-LiveParamProgress'
  $cleanupPlan = Get-FunctionText 'Invoke-FailClosedCleanupPlan'
  $cleanupProbe = Get-FunctionText 'Invoke-OfflineCleanupFaultProbe'
  $readOnlyInvariant = Get-FunctionText 'Assert-ReadOnlyPreflightInvariants'
  $integrity = Get-FunctionText 'Apply-RunnerIntegrityGate'
  $offline = Get-FunctionText 'Invoke-OfflineSelfTest'
  $complete = Get-FunctionText 'Complete-Evidence'

  Add-Check 'exact_ground_com6_identity_is_fail_closed' (
      $source.Contains("GroundPort = 'COM6'") -and
      $source.Contains('USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000') -and
      $source.Contains('USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80') -and
      $identity -match 'Win32_SerialPort' -and
      $identity -match 'PNPDeviceID' -and
      $identity -match 'DEVPKEY_Device_Parent' -and
      $identity -match 'ConfigManagerErrorCode' -and
      $identity -match "Status\s*-ceq\s*'OK'" -and
      $identity -match 'OrdinalIgnoreCase' -and
      $identity -match 'Count\s*-ne\s*0' -and
      $identity -match 'Count\s*-eq\s*1') `
      'only exact COM6 / interface PnP identity is accepted'

  Add-Check 'serial_is_exact_57600_8n1_without_reset_lines' (
      $serial -match '57600' -and
      $serial -match 'Parity\]::None' -and
      $serial -match '8' -and
      $serial -match 'StopBits\]::One' -and
      $serial -match 'DtrEnable\s*=\s*\$false' -and
      $serial -match 'RtsEnable\s*=\s*\$false' -and
      $serial -match 'Handshake\]::None') `
      '57600 8N1, no handshake, DTR/RTS false'

  Add-Check 'com3_is_never_opened_or_written' (
      $source -match "ForbiddenPorts\s*=\s*@\('COM3'\)" -and
      $source -notmatch "SerialPort\]::new\(\s*'COM3'" -and
      $source -notmatch "\.PortName\s*=\s*'COM3'" -and
      $measurement -match 'New-GroundSerialPort' -and
      $measurement -notmatch 'COM3') `
      'the sole live serial object is Ground COM6; COM3 is policy-forbidden'

  Add-Check 'preflight_requires_two_primary_heartbeats' (
      $primaryHeartbeat -match 'system_id\s*-eq\s*1' -and
      $primaryHeartbeat -match 'component_id\s*-eq\s*1' -and
      $primaryHeartbeat -match 'message_id\s*-eq\s*0' -and
      $preflight -match 'Count\s*-ge\s*2' -and
      $preflight -match 'HeartbeatLimitUs' -and
      $source -match 'HeartbeatLimitUs\s*=\s*\[int64\]2500000' -and
      $preflight -match 'maximum_gap_us') `
      'source 1/1 heartbeat pair with <=2.5 s gap gates request transmission'

  $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
  })
  Add-Check 'readonly_preflight_switch_is_r18_only' (
      $parameterNames -contains 'PreflightOnly' -and
      $source -match '(?s)PreflightOnly\.IsPresent.*R19SharedMode\.IsPresent.*mutually exclusive' -and
      -not ([IO.File]::ReadAllText((Join-Path $repo `
          'tools\run_r19_pixhawk_param_list_e2e_hil.ps1')).Contains(
          'PreflightOnly'))) `
      'an explicit R18-only switch exists and cannot enter through the R19 wrapper'

  $readOnlyBranch = $measurement.IndexOf('if ($PreflightOnly.IsPresent)',
      [StringComparison]::Ordinal)
  $requestConstruction = $measurement.IndexOf('New-ExactParamRequestList',
      [StringComparison]::Ordinal)
  Add-Check 'readonly_preflight_returns_before_any_serial_write_path' (
      $readOnlyBranch -ge 0 -and $requestConstruction -gt $readOnlyBranch -and
      $readOnlyInvariant -match 'request_attempted\s*-eq\s*0' -and
      $readOnlyInvariant -match "request_outcome\s*-ceq\s*'NOT_ATTEMPTED'" -and
      $readOnlyInvariant -match 'serial_write_attempted' -and
      $readOnlyInvariant -match 'serial_write_call_completed' -and
      $readOnlyInvariant -match 'serial_bytes_drained' -and
      $readOnlyInvariant -match 'serial_bytes_written' -and
      $source.Contains("'none (read-only preflight)'") -and
      $source -match 'read_only_preflight=\$true') `
      'read-only mode seals request NOT_ATTEMPTED and every serial-write flag false'

  Add-Check 'readonly_preflight_checks_maximum_of_all_observed_gaps' (
      $preflightEvidence -match 'observedMaximum' -and
      $preflightEvidence -match '(?s)for\s*\(.*heartbeatIndex.*heartbeats\.Count' -and
      $preflightEvidence -match '(?s)maximumGapForAcceptanceUs\s*=\s*if\s*\(\$UseMaximumObservedGap\).*observedMaximum' -and
      $preflightEvidence -match 'maximum_gap_us=\$maximumGapForAcceptanceUs' -and
      $preflight -match 'observation\.maximum_gap_us\s*-le\s*\$HeartbeatLimitUs') `
      'every observed consecutive primary heartbeat interval is included in the 2.5 s gate'

  Add-Check 'preflight_timeout_preserves_detailed_observation' (
      $preflightEvidence -match 'raw_bytes' -and
      $preflightEvidence -match 'valid_frames' -and
      $preflightEvidence -match 'primary_heartbeat_count' -and
      $preflightEvidence -match 'unsolicited_param_value_count' -and
      $preflightEvidence -match 'partial_bytes' -and
      $preflightEvidence -match 'parser_error_count' -and
      $preflightEvidence -match 'maximum_heartbeat_gap_us' -and
      $preflightEvidence -match 'last_heartbeat_age_us' -and
      $preflightEvidence -match 'os_bytes_to_read' -and
      $preflightEvidence -match 'os_bytes_to_write' -and
      $preflightEvidence -match 'maximum_pump_service_gap_us' -and
      $preflight -match "(?s)'FAIL'.*Preflight timeout" -and
      $preflight -match 'Get-PreflightEvidenceSnapshot' -and
      $measurement -match "preflight\.result\s*-cne\s*'PASS'" -and
      $measurement -match '\$preflight\.failure') `
      'timeout snapshot survives in summary.measurement.preflight before failure'

  $firstIdentityCall = $measurement.IndexOf(
      "Assert-ExactGroundIdentity 'before_open'",[StringComparison]::Ordinal)
  $secondIdentityCall = $measurement.IndexOf(
      "Assert-ExactGroundIdentity 'immediately_after_open'",
      [StringComparison]::Ordinal)
  $preflightCall = $measurement.IndexOf('Wait-PrimaryHeartbeatPreflight',
      [StringComparison]::Ordinal)
  $finalBoundaryCall = $measurement.IndexOf('Confirm-FinalRequestBoundary',
      [StringComparison]::Ordinal)
  $writeCall = $measurement.IndexOf('Invoke-ExactRequestWrite',
      [StringComparison]::Ordinal)
  Add-Check 'identity_twice_then_clean_request_boundary' (
      $firstIdentityCall -ge 0 -and $secondIdentityCall -gt $firstIdentityCall -and
      $preflightCall -gt $secondIdentityCall -and
      $finalBoundaryCall -gt $preflightCall -and $writeCall -gt $finalBoundaryCall -and
      [regex]::Matches($measurement,'Assert-ExactGroundIdentity').Count -eq 2 -and
      $boundary -match 'Read-AvailableSerial' -and
      $boundary -match 'pre-request PARAM_VALUE' -and
      $boundary -match 'Parser\.buffer\.Count\s*-eq\s*0' -and
      $boundary -match 'BytesToRead\s*-eq\s*0' -and
      $boundary -notmatch 'CimInstance|PnpDevice') `
      'identity is checked before/immediately after open; final pump/idle fence directly precedes R0/write'

  Add-Check 'request_fixture_is_exact_and_written_once' (
      $source.Contains('FD02000063FFBE1500000101D507') -and
      $source.Contains('FC3A47A83D35D44E96E044A216FDBF082805F9FACCDD5E4B9252E0C7026D4A75') -and
      $request -match 'Length\s*-eq\s*14' -and
      $write -match 'request_attempted\s*-eq\s*0' -and
      $write -match '\.Write\(' -and
      $write -notmatch 'BaseStream\.Flush\(' -and
      $write -match 'BytesToWrite' -and
      $write -match 'DrainTimeoutUs' -and
      $write -match 'request_write_started_us\s*=\s*\$r0' -and
      $write -match 'request_writes_completed\s*=\s*1' -and
      $write -match 'request_complete_write_edge_us') `
      'R0 is latched before one exact Write; bounded BytesToWrite==0 supplies a separate complete edge'

  Add-Check 'mavlink2_crc_parser_is_strict' (
      $parser -match '0xFD' -and
      $parser -match 'noise_bytes' -and
      $parser -match 'expected_size' -and
      $record -match 'Update-X25Crc' -and
      $record -match 'crc_extra' -and
      $record -match 'bad_crc' -and
      $record -match 'unsupported_flags' -and
      $record -match 'unknown_definition') `
      'MAVLink2 framing, CRC_EXTRA and every parser anomaly are accounted'

  Add-Check 'strict_932_accounting_and_30s_gate' (
      $account -match 'expected=932' -and
      $account -match 'parameter_frames' -and
      $account -match 'unique' -and
      $account -match 'missing' -and
      $account -match 'duplicate' -and
      $account -match 'future' -and
      $account -match 'out_of_order' -and
      $account -match 'wrong_source' -and
      $account -match 'count_mismatch' -and
      $account -match 'raw_length\s*-eq\s*37' -and
      $account -match 'not\s+\$record\.signed' -and
      $account -match 'invalid_param_id' -and
      $account -match 'duplicate_param_id' -and
      $account -match 'parser_error_count' -and
      $account -match 'request_to_last_us' -and
      $account -match 'Target30LimitUs' -and
      $source -match 'Target30LimitUs\s*=\s*\[int64\]30000000') `
      'exact contiguous unique indexes 0..931, count=932 and <=30,000,000 us'

  Add-Check 'heartbeat_covers_request_stream_and_tail' (
      $heartbeat -match 'pre_to_request_us' -and
      $heartbeat -match 'request_to_first_heartbeat_us' -and
      $heartbeat -match 'last_pre_to_first_post_gap_us' -and
      $heartbeat -match 'maximum_consecutive_gap_us' -and
      $heartbeat -match 'completion_to_post_heartbeat_us' -and
      $heartbeat -match 'tail_gap_us' -and
      $heartbeat -match 'HeartbeatLimitUs' -and
      $account -match 'heartbeat') `
      'request edge, every consecutive gap, and final tail are <=2.5 s'

  Add-Check 'live_progress_is_incremental_o_new_frames' (
      $progress -match 'frame_cursor' -and
      $progress -match 'while\s*\(\[int\]\$State\.frame_cursor\s*-lt\s*\$Parser\.frames\.Count' -and
      $progress -match 'frames_processed' -and
      $progress -notmatch 'Where-Object' -and
      $measurement -notmatch 'Get-LiveParamProgress' -and
      $offline -match 'incremental_many_idle_turns_fairness') `
      'each newly parsed frame is consumed once; idle turns never rescan history'

  Add-Check 'timeouts_and_duplicate_guard_are_bounded' (
      $source -match 'StallTimeoutUs\s*=.*120000000' -and
      $source -match 'OverallTimeoutUs\s*=.*7200000000' -and
      $source -match 'DuplicateGuardUs\s*=.*30000000' -and
      $measurement -match 'stall timeout' -and
      $measurement -match 'overall timeout' -and
      $measurement -match 'duplicate_guard') `
      '120 s no-progress, 7200 s overall and 30 s post-completion duplicate guard'

  Add-Check 'evidence_is_durable_and_sealed' (
      $source -match 'ground\.raw\.bin' -and
      $source -match 'frame_events\.jsonl' -and
      $source -match 'timeline\.jsonl' -and
      $source -match 'progress\.jsonl' -and
      $measurement -match 'PERIODIC_DURABLE_FLUSH' -and
      $measurement -match '30000000' -and
      $complete -match 'summary\.json' -and
      $complete -match 'artifact_manifest\.json' -and
      $complete -match 'SHA256SUMS\.txt' -and
      $complete -match 'final_seal\.json' -and
      $source -match 'Flush\(\$true\)') `
      'raw, event, timeline, summary, hashes and final seal are durable'

  Add-Check 'measurement_is_non_mutating_except_one_read_request' (
      $source -match 'firmware_write_attempted=\$false' -and
      $source -match 'e220_write_attempted=\$false' -and
      $source -match 'actuator_command_attempted=\$false' -and
      $source -notmatch 'esptool' -and
      $source -notmatch 'arduino-cli.*upload' -and
      $source -notmatch 'Restart-Computer|Stop-Computer|shutdown\.exe') `
      'no firmware/E220/actuator mutation and no power-cycle requirement'

  Add-Check 'accepted_r18_artifacts_are_pinned_but_runtime_is_unproven' (
      $source.Contains('30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5') -and
      $source.Contains('9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52') -and
      $source.Contains('AEFF205534567E26AFD17AB5EDF5BF05E9DD735D6A4D52E51DB318B7FE23AC66') -and
      $source -match 'UNPROVEN_NO_DEVICE_READBACK' -and
      $source -match 'accepted_files_verified') `
      'known R18 files/prior restore are immutable inputs; current flash is not overclaimed'

  Add-Check 'cleanup_and_runner_integrity_are_shared_hard_gates' (
      $cleanupPlan -match 'foreach\s*\(\$step\s+in\s+\$Steps\)' -and
      $cleanupPlan -match "(?s)result=if.*'PASS'.*'FAIL'" -and
      $measurement -match 'Invoke-FailClosedCleanupPlan' -and
      $cleanupProbe -match 'Invoke-FailClosedCleanupPlan' -and
      $offline -match 'cleanup_flush_close_dispose_failure_negative' -and
      $integrity -match "Summary\.result\s*=\s*'FAIL'" -and
      $complete -match 'Apply-RunnerIntegrityGate' -and
      $complete -match 'CleanupResult\.result' -and
      $offline -match 'runner_integrity_mismatch_negative') `
      'the actual cleanup path is fake-tested; cleanup and source drift both force top-level FAIL'

  Add-Check 'offline_suite_covers_required_negatives' (
      $offline -match 'target_30s_boundary' -and
      $offline -match 'target_30s_overrun_negative' -and
      $offline -match 'missing_931_negative' -and
      $offline -match 'duplicate_negative' -and
      $offline -match 'out_of_order_negative' -and
      $offline -match 'heartbeat_gap_negative' -and
      $offline -match 'crc_negative' -and
      $offline -match 'partial_negative' -and
      $offline -match 'stall_timeout_negative' -and
      $offline -match 'overall_timeout_negative' -and
      $offline -match 'write_count_negative' -and
      $offline -match 'write_drain_timeout_ambiguous_negative' -and
      $offline -match 'readonly_preflight_zero_write_positive' -and
      $offline -match 'readonly_preflight_gap_overrun_negative' -and
      $offline -match 'readonly_preflight_timeout_evidence_positive' -and
      $offline -match 'offline_external_actions_zero' -and
      $offline -match 'external_actions') `
      'synthetic/fake serial tests cover boundaries and all specified failures'

  $offlineDirectory = Join-Path $OutputDirectory 'offline_behavior'
  try {
    $offlineOutput = & $runnerPath -RepoRoot $repo `
        -OutputDirectory $offlineDirectory -OfflineSelfTest 2>&1
    $offlineExit = $LASTEXITCODE
    $offlineSummaryPath = Join-Path $offlineDirectory 'summary.json'
    $offlineSummary = if (Test-Path -LiteralPath $offlineSummaryPath) {
      Get-Content -Raw -LiteralPath $offlineSummaryPath | ConvertFrom-Json
    } else {$null}
    Add-Check 'offline_behavioral_suite_passes' (
        $offlineExit -eq 0 -and $null -ne $offlineSummary -and
        [string]$offlineSummary.result -ceq 'PASS' -and
        [int]$offlineSummary.test_count -ge 12 -and
        [int]$offlineSummary.failed_count -eq 0 -and
        -not [bool]$offlineSummary.external_actions.cim_queried -and
        -not [bool]$offlineSummary.external_actions.pnp_queried -and
        -not [bool]$offlineSummary.external_actions.process_inventory_queried -and
        -not [bool]$offlineSummary.external_actions.com_ports_opened -and
        -not [bool]$offlineSummary.external_actions.serial_write_attempted -and
        -not [bool]$offlineSummary.external_actions.serial_write_call_completed -and
        -not [bool]$offlineSummary.external_actions.serial_bytes_drained -and
        -not [bool]$offlineSummary.external_actions.serial_bytes_written -and
        -not [bool]$offlineSummary.external_actions.firmware_write_attempted -and
        -not [bool]$offlineSummary.external_actions.e220_write_attempted -and
        -not [bool]$offlineSummary.external_actions.actuator_command_attempted) `
        (($offlineOutput | Out-String).Trim())

    $sealPath = Join-Path $offlineDirectory 'final_seal.json'
    $manifestPath = Join-Path $offlineDirectory 'artifact_manifest.json'
    $sumsPath = Join-Path $offlineDirectory 'SHA256SUMS.txt'
    $sealValid = $false
    $manifestEntriesValid = $false
    $sumEntriesValid = $false
    if ((Test-Path -LiteralPath $sealPath -PathType Leaf) -and
        (Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
        (Test-Path -LiteralPath $sumsPath -PathType Leaf)) {
      $seal = Get-Content -Raw -LiteralPath $sealPath | ConvertFrom-Json
      $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
      $sealValid = [string]$seal.result -ceq 'PASS' -and
          [string]$seal.runner_integrity -ceq 'PASS' -and
          [string]$seal.summary_sha256 -ceq
              (Get-FileHash -Algorithm SHA256 -LiteralPath $offlineSummaryPath).Hash -and
          [string]$seal.artifact_manifest_sha256 -ceq
              (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash -and
          [string]$seal.sha256sums_sha256 -ceq
              (Get-FileHash -Algorithm SHA256 -LiteralPath $sumsPath).Hash
      $manifestEntriesValid = $true
      foreach ($entry in @($manifest.artifacts)) {
        $path = Join-Path $offlineDirectory `
            ([string]$entry.path).Replace('/','\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            [int64](Get-Item -LiteralPath $path).Length -ne [int64]$entry.bytes -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -cne
                [string]$entry.sha256) {
          $manifestEntriesValid = $false
          break
        }
      }
      $sumEntriesValid = $true
      foreach ($line in @(Get-Content -LiteralPath $sumsPath)) {
        $match = [regex]::Match($line,
            '^(?<sha>[0-9A-F]{64}) \*(?<path>.+)$')
        if (-not $match.Success) {$sumEntriesValid = $false;break}
        $path = Join-Path $offlineDirectory `
            $match.Groups['path'].Value.Replace('/','\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -cne
                $match.Groups['sha'].Value) {
          $sumEntriesValid = $false
          break
        }
      }
    }
    Add-Check 'offline_evidence_seal_and_all_hash_entries_verify' (
        $sealValid -and $manifestEntriesValid -and $sumEntriesValid) `
        'final seal hashes, manifest entries, and SHA256SUMS entries all recompute'
  } catch {
    Add-Check 'offline_behavioral_suite_passes' $false $_.Exception.Message
    Add-Check 'offline_evidence_seal_and_all_hash_entries_verify' $false `
        $_.Exception.Message
  }
}

$failed = @($checks | Where-Object {-not $_.valid})
$summary = [pscustomobject][ordered]@{
  schema_version=1
  test_id='R18-PIXHAWK-PARAM-E2E-RUNNER-CONTRACT-001'
  result=if ($failed.Count -eq 0) {'PASS'} else {'FAIL'}
  check_count=$checks.Count
  failed_count=$failed.Count
  runner_path=$runnerPath
  checks=@($checks)
}
$summaryPath = Join-Path $OutputDirectory 'summary.json'
[IO.File]::WriteAllText($summaryPath,
    (ConvertTo-Json $summary -Depth 20) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $summaryPath).Hash
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'),
    "$sha *summary.json$([Environment]::NewLine)",
    [Text.UTF8Encoding]::new($false))

$summary | ConvertTo-Json -Depth 20
if ($failed.Count -ne 0) { exit 1 }
exit 0
