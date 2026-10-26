[CmdletBinding()]
param(
  [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$testId = 'R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-ORCHESTRATOR-CONTRACT-001'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$repo = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
$runnerPath = Join-Path $repo `
    'tools\invoke_r19_runtime_stage_cause_experiment_hil.ps1'
$flashToolPath = Join-Path $repo 'tools\invoke_r19_candidate_app_flash_hil.ps1'
$captureToolPath = Join-Path $repo 'tools\run_r19_runtime_fail_diagnostic_hil.ps1'
$readerPath = Join-Path $repo 'tools\read_r19_runtime_stage_jtag.ps1'
$gatePath = Join-Path $repo 'tools\invoke_r19_jtag_preflash_gate.ps1'
$candidateLatestPath = Join-Path $repo `
    'runs\candidates\R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001\latest.json'
$nativeMockPath = Join-Path $repo `
    'tests\hil\fixtures\mock_native_stderr_exit.ps1'

function Assert-Contract([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "$testId`: $Message" }
}

Assert-Contract (Test-Path -LiteralPath $runnerPath -PathType Leaf) `
    "missing runtime-stage cause experiment orchestrator: $runnerPath"
Assert-Contract (Test-Path -LiteralPath $flashToolPath -PathType Leaf) `
    "missing candidate flash child tool: $flashToolPath"
Assert-Contract (Test-Path -LiteralPath $captureToolPath -PathType Leaf) `
    "missing runtime-fail diagnostic capture tool: $captureToolPath"
Assert-Contract (Test-Path -LiteralPath $readerPath -PathType Leaf) `
    "missing runtime-stage JTAG reader: $readerPath"
Assert-Contract (Test-Path -LiteralPath $gatePath -PathType Leaf) `
    "missing standalone JTAG pre-flash gate: $gatePath"
Assert-Contract (Test-Path -LiteralPath $candidateLatestPath -PathType Leaf) `
    "missing canonical diagnostic candidate pointer: $candidateLatestPath"
$source = Get-Content -LiteralPath $runnerPath -Raw
$flashToolSha256 = (Get-FileHash -LiteralPath $flashToolPath -Algorithm SHA256).
    Hash.ToUpperInvariant()
$captureToolSha256 =
    (Get-FileHash -LiteralPath $captureToolPath -Algorithm SHA256).
    Hash.ToUpperInvariant()
$readerSource = Get-Content -LiteralPath $readerPath -Raw
$readerSha256 = (Get-FileHash -LiteralPath $readerPath -Algorithm SHA256).
    Hash.ToUpperInvariant()
$gateSha256 = (Get-FileHash -LiteralPath $gatePath -Algorithm SHA256).
    Hash.ToUpperInvariant()
$candidateLatestSha256 =
    (Get-FileHash -LiteralPath $candidateLatestPath -Algorithm SHA256).
    Hash.ToUpperInvariant()
$candidateLatest = Get-Content -LiteralPath $candidateLatestPath -Raw |
    ConvertFrom-Json
$candidateArtifactId = [string]$candidateLatest.artifact_id
$expectedCandidateArtifactId = $candidateArtifactId
$expectedCandidateLatestSha256 = $candidateLatestSha256
Assert-Contract ($candidateArtifactId -ceq
    '20261020T123447347Z-b414028b' -and
    $candidateLatestSha256 -ceq
    '7B9E24D307963177D3489627AB305023B8A31744B5008FD36210590D60F4DA41') `
    'canonical latest is not the reviewed exact diagnostic candidate'
$candidateArtifactRoot = (Resolve-Path -LiteralPath (Join-Path $repo `
    ([string]$candidateLatest.artifact_root).Replace('/','\'))).Path
$candidateManifestPath = (Resolve-Path -LiteralPath (Join-Path $repo `
    ([string]$candidateLatest.candidate_manifest.path).Replace('/','\'))).Path
Assert-Contract ((Get-FileHash -LiteralPath $candidateManifestPath `
      -Algorithm SHA256).Hash.ToUpperInvariant() -ceq
    [string]$candidateLatest.candidate_manifest.sha256) `
    'canonical candidate manifest does not match the sealed latest pointer'
$candidateManifest = Get-Content -LiteralPath $candidateManifestPath -Raw |
    ConvertFrom-Json
Assert-Contract ([string]$candidateManifest.artifact_id -ceq
    $candidateArtifactId) `
    'canonical candidate manifest artifact identity mismatch'

function Get-SealedRuntimeStageAddress([string]$Role) {
  $roleDocuments = @($candidateManifest.roles | Where-Object {
      [string]$_.role -ceq $Role
    })
  Assert-Contract ($roleDocuments.Count -eq 1) `
      "canonical candidate has invalid role count: $Role"
  $sealedFiles = @($roleDocuments[0].reproducibility_artifacts.files)
  $mapRecords = @($sealedFiles | Where-Object {
      [string]$_.path -ceq "evidence/build/$Role/application.map"
    })
  $elfRecords = @($sealedFiles | Where-Object {
      [string]$_.path -ceq "evidence/build/$Role/application.elf"
    })
  Assert-Contract ($mapRecords.Count -eq 1 -and $elfRecords.Count -eq 1) `
      "canonical candidate lacks one sealed MAP/ELF pair: $Role"
  $mapPath = (Resolve-Path -LiteralPath (Join-Path $candidateArtifactRoot `
      ([string]$mapRecords[0].path).Replace('/','\'))).Path
  $elfPath = (Resolve-Path -LiteralPath (Join-Path $candidateArtifactRoot `
      ([string]$elfRecords[0].path).Replace('/','\'))).Path
  Assert-Contract ((Get-FileHash -LiteralPath $mapPath -Algorithm SHA256).
      Hash.ToUpperInvariant() -ceq [string]$mapRecords[0].sha256 -and
      (Get-FileHash -LiteralPath $elfPath -Algorithm SHA256).
      Hash.ToUpperInvariant() -ceq [string]$elfRecords[0].sha256) `
      "canonical candidate MAP/ELF seal mismatch: $Role"
  $symbolMatches = [regex]::Matches(
      (Get-Content -LiteralPath $mapPath -Raw),
      '(?m)^\s*(0x[0-9a-fA-F]+)\s+vc_lora_r19_runtime_stage_record\s*$')
  Assert-Contract ($symbolMatches.Count -eq 1) `
      "canonical candidate runtime-stage MAP symbol is not unique: $Role"
  [string]$symbolMatches[0].Groups[1].Value.ToLowerInvariant()
}

$vehicleRuntimeStageAddress = Get-SealedRuntimeStageAddress 'vehicle'
$groundRuntimeStageAddress = Get-SealedRuntimeStageAddress 'ground'
Assert-Contract ($vehicleRuntimeStageAddress -ceq '0x3fcab680' -and
    $groundRuntimeStageAddress -ceq '0x3fca2bf8') `
    'canonical candidate runtime-stage addresses are not the reviewed pair'
$flashToolPinMatch = [regex]::Match($source,
    '(?s)\$expectedFlashToolSha256\s*=\s*''([0-9A-F]{64})''')
Assert-Contract ($flashToolPinMatch.Success -and
    [string]$flashToolPinMatch.Groups[1].Value -ceq $flashToolSha256) `
    'runtime-stage orchestrator flash child pin does not match the actual child'
$captureToolPinMatch = [regex]::Match($source,
    '(?s)\$expectedCaptureToolSha256\s*=\s*''([0-9A-F]{64})''')
Assert-Contract ($captureToolPinMatch.Success -and
    [string]$captureToolPinMatch.Groups[1].Value -ceq $captureToolSha256) `
    'runtime-stage orchestrator capture child pin does not match the actual child'
$readerPinMatch = [regex]::Match($source,
    '(?s)\$expectedStageReaderSha256\s*=\s*''([0-9A-F]{64})''')
Assert-Contract ($readerPinMatch.Success -and
    [string]$readerPinMatch.Groups[1].Value -ceq $readerSha256) `
    'runtime-stage orchestrator stage reader pin does not match the actual child'
$gatePinMatch = [regex]::Match($source,
    '(?s)\$expectedJtagPreflightGateSha256\s*=\s*''([0-9A-F]{64})''')
Assert-Contract ($gatePinMatch.Success -and
    [string]$gatePinMatch.Groups[1].Value -ceq $gateSha256) `
    'runtime-stage orchestrator preflight pin does not match the actual child'
$candidateArtifactPinMatch = [regex]::Match($source,
    '(?s)\$expectedCandidateArtifactId\s*=\s*''([^'']+)''')
Assert-Contract ($candidateArtifactPinMatch.Success -and
    [string]$candidateArtifactPinMatch.Groups[1].Value -ceq
      $candidateArtifactId) `
    'runtime-stage orchestrator artifact identity pin is stale or missing'
$candidateLatestPinMatch = [regex]::Match($source,
    '(?s)\$expectedCandidateLatestSha256\s*=\s*''([0-9A-F]{64})''')
Assert-Contract ($candidateLatestPinMatch.Success -and
    [string]$candidateLatestPinMatch.Groups[1].Value -ceq
      $candidateLatestSha256) `
    'runtime-stage orchestrator canonical latest pin is stale or missing'
$vehicleAddressPinMatch = [regex]::Match($source,
    '(?s)\$expectedVehicleRuntimeStageAddress\s*=\s*''(0x[0-9a-f]+)''')
$groundAddressPinMatch = [regex]::Match($source,
    '(?s)\$expectedGroundRuntimeStageAddress\s*=\s*''(0x[0-9a-f]+)''')
Assert-Contract ($vehicleAddressPinMatch.Success -and
    [string]$vehicleAddressPinMatch.Groups[1].Value -ceq
      $vehicleRuntimeStageAddress -and $groundAddressPinMatch.Success -and
    [string]$groundAddressPinMatch.Groups[1].Value -ceq
      $groundRuntimeStageAddress) `
    'runtime-stage orchestrator address pins do not match the sealed MAP/ELF pair'
foreach ($readerParameter in @('FlashEvidencePath','FlashEvidenceSha256',
    'NmExecutable','NmSha256','OpenOcdExecutable','OpenOcdSha256',
    'InterfaceConfig','InterfaceConfigSha256','TargetConfig',
    'TargetConfigSha256','ScriptsRoot','OutputRoot')) {
  Assert-Contract ($readerSource -match
      ('\[string\]\${0}\b' -f [regex]::Escape($readerParameter))) `
      "JTAG reader CLI lacks parameter: $readerParameter"
}
Assert-Contract ($readerSource -match 'resume_shutdown_cleanup_proven' -and
    $readerSource -match 'target_may_be_halted') `
    'JTAG reader does not expose cleanup safety proof required by orchestrator'

foreach ($pattern in @(
    '\[switch\]\$Execute',
    '\[switch\]\$OfflineContractTest',
    '\[switch\]\$ReadOnlyToolDiscoveryPreflight',
    '\[string\]\$VehicleProbeUsbLocation\b',
    '\[string\]\$GroundProbeUsbLocation\b',
    'R19_RUNTIME_FAIL_DIAGNOSTIC_HIL_ONE_RUN_NOT_ACCEPTANCE_NOT_DEPLOYMENT',
    'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED',
    'RESTORE_ACCEPTED_R18_AFTER_R19_HIL',
    'invoke_r19_candidate_app_flash_hil\.ps1',
    'run_r19_runtime_fail_diagnostic_hil\.ps1',
    'invoke_r19_jtag_preflash_gate\.ps1',
    'read_r19_runtime_stage_jtag\.ps1',
    'FlashEvidencePath',
    'FlashEvidenceSha256',
    'NmExecutable',
    'NmSha256',
    'AC8D55C45DBCAEFE082299357245D7F12786C61A4E3C06A8E21F31D6890FB29E',
    '7461DBBEC251F1D4A2189C3C57B74A45B2FE64DEC1EC1B9EDDCB348A2AB2EBAB',
    '9C2201DDCDB416A471E8D7F8BF309E4F20C364BBF416CA67D6475A8495934722',
    'D140078D0505475C8D8732CDD57938D0B81AC3E7B770A1BE6EBE5DB29A7DB18B',
    '3FB3130F7D4B17FE870EA6532B3F8EB5B0F27F506F1953A1A4EC9E1369D7BB84',
    $readerSha256,
    $gateSha256,
    $captureToolSha256,
    'PASS_WINUSB_DRIVER_BINDING_PNP_ONLY',
    'FAIL_ACTIVE_JTAG_UNPROVEN_PNP_ONLY_NO_FLASH',
    'driver_binding_proven',
    'offline_downstream_branch_mock',
    'ProbeUsbLocation',
    'jtag_preflight',
    'active_jtag_vehicle',
    'active_jtag_ground',
    'PASS_JTAG_PREFLIGHT_TAP_RESET_SCAN_POSSIBLE_NO_CPU_HALT_OR_SYSTEM_RESET_COMMAND',
    'ScriptsRoot',
    'Get-DirectoryTreeSha256',
    'vc-lora-r19-runtime-stage-jtag-read-v3',
    'endpoint_fifo_schema',
    'endpoint_fifo_size_bytes',
    'runtime_stage_size_bytes',
    'reader_schema',
    'decoded\.endpoint_fifo',
    'decoded\.usb_tx_boundary_classification',
    'runtime_stage_address',
    'endpoint_fifo_address',
    'Get-StageProof',
    'CaptureSeconds',
    '40',
    'R19A_TERMINAL_PREFIX_STALL',
    'FAIL_R19A_TERMINAL_PREFIX_STALL',
    'r19a_terminal_partial_contract',
    'alive_tail_stall_failure_admitted_for_stage_read',
    'FAIL_CAPTURE_R19A_TAIL_STALL_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED',
    'R19F_CAPTURE_BOUNDARY_PARTIAL',
    'FAIL_R19F_CAPTURE_BOUNDARY_PARTIAL',
    'r19f_boundary_partial_contract',
    'Test-R19FailureBoundaryPartialEvidence',
    'boundary_partial_failure_admitted_for_stage_read',
    'boundary_partial_raw_replay',
    'PASS_R18_ROLLBACK_COMPLETE',
    'FAIL_ROLLBACK_UNPROVEN_POWER_OFF_REQUIRED',
    '0x3fcab680',
    '0x3fca2bf8',
    'vehicle',
    'ground')) {
  Assert-Contract ($source -match $pattern) `
      "orchestrator lacks required contract pattern: $pattern"
}

Assert-Contract ($source -notmatch 'Invoke-Expression|\biex\b') `
    'orchestrator must not execute a constructed command string'
Assert-Contract ($source -notmatch 'System\.IO\.Ports|SerialPort|write[-_]flash|erase[-_]flash') `
    'orchestrator must delegate all hardware access to pinned child tools'
Assert-Contract ($source -match
    '\[object\[\]\]\$nmMatches\s*=\s*@\(' -and
    $source -match '\[object\[\]\]\$openOcdMatches\s*=\s*@\(') `
    'installed-tool discovery must preserve zero/one/many results as arrays under StrictMode'
Assert-Contract ($source -notmatch 'DeviceBindingPath|ReadbackEvidencePath') `
    'orchestrator contains an obsolete JTAG-reader evidence contract'
Assert-Contract ($source -match '(?s)try\s*\{.*Invoke-ExperimentStep.*capture.*Invoke-ExperimentStep.*stage_vehicle.*Invoke-ExperimentStep.*stage_ground.*\}\s*finally\s*\{.*rollback') `
    'capture and both stage reads must precede rollback in a finally block'
Assert-Contract ($source -match
    '(?s)Invoke-ExperimentStep.*jtag_preflight.*Get-JtagPreflightProof.*driver_binding_proven.*Invoke-ExperimentStep.*active_jtag_vehicle.*Invoke-ExperimentStep.*active_jtag_ground.*firmware_install_allowed.*experimentStarted\s*=\s*\$true.*Invoke-ExperimentStep.*install') `
    'exact PnP-only proof and both bound active JTAG preflights must precede install'
Assert-Contract ($source -match
    '(?s)\$activeJtagVehicleArguments.*-Preflight.*-Role.*vehicle.*-ProbeSerial.*90:70:69:11:81:A4.*-ProbeUsbLocation' -and
    $source -match
    '(?s)\$activeJtagGroundArguments.*-Preflight.*-Role.*ground.*-ProbeSerial.*1C:DB:D4:5A:83:80.*-ProbeUsbLocation') `
    'active JTAG preflight steps are not bound to the exact role, serial, and explicit USB location'
Assert-Contract ($source -match
    'vc-lora-r19-jtag-preflight-v1' -and
    $source -match
    'PASS_JTAG_PREFLIGHT_TAP_RESET_SCAN_POSSIBLE_NO_CPU_HALT_OR_SYSTEM_RESET_COMMAND' -and
    $source -match 'live-jtag-preflight' -and
    $source -match 'requested_serial' -and
    $source -match 'requested_usb_location' -and
    $source -match 'opened_serial' -and
    $source -match 'opened_usb_location' -and
    $source -match 'process_termination_proven' -and
    $source -match 'shutdown_proven' -and
    $source -match 'target_config_loaded' -and
    $source -match 'cpu_halt_command_issued' -and
    $source -match 'system_reset_command_issued' -and
    $source -match 'transport_init_completion_proven' -and
    $source -match 'tap_reset_or_scan_possible') `
    'active JTAG preflight proof lacks exact identity, termination, shutdown, or safety-field validation'
Assert-Contract ($source -match 'activeJtagCleanupUnproven' -and
    $source -match
      'FAIL_ACTIVE_JTAG_CLEANUP_UNPROVEN_POWER_OFF_REQUIRED' -and
    $source -match
      '(?s)Get-ActiveJtagPreflightProof.*activeJtagVehicleEvidence.*hardware_interaction.*process_termination_proven.*shutdown_proven.*activeJtagCleanupUnproven' -and
    $source -match
      '(?s)Get-ActiveJtagPreflightProof.*activeJtagGroundEvidence.*hardware_interaction.*process_termination_proven.*shutdown_proven.*activeJtagCleanupUnproven') `
    'outer must inspect each active preflight hardware/termination/shutdown proof and fail closed before flash when cleanup is unproven'
Assert-Contract ($source -match
    '(?s)VehicleProbeUsbLocation.*pnp_port_chain' -and
    $source -match '(?s)GroundProbeUsbLocation.*pnp_port_chain' -and
    $source -match
      '\$VehicleProbeUsbLocation\s+-cne\s+\$GroundProbeUsbLocation' -and
    $source -notmatch "ProbeUsbLocation\s*=\s*'1-" -and
    $source -notmatch 'ProbeUsbLocation\s*=\s*"1-') `
    'explicit active-JTAG locations must be distinct and suffix-bound to PnP chains without inferring a USB bus'
Assert-Contract ($source -match
    '(?s)OfflineContractTest.*VehicleProbeUsbLocation.*GroundProbeUsbLocation.*reject' -or
    $source -match
    '(?s)VehicleProbeUsbLocation.*GroundProbeUsbLocation.*Offline contract mode rejects') `
    'live-only probe-location parameters are not rejected by offline contract mode'
Assert-Contract ($source -match
    '(?s)Get-StageArguments.*ProbeUsbLocation.*-ProbeUsbLocation') `
    'normal stage reads are not bound to the location proven before flash'
Assert-Contract ($source -match
    "PSObject\.Properties\['diagnostic_classification'\]" -and
    $source -match "PSObject\.Properties\['diagnostic_status'\]") `
    'live capture disposition does not safely bind optional diagnostic fields before use'
Assert-Contract ($source -match
    'vc-lora-r19-runtime-fail-diagnostic-summary-v1' -and
    $source -match 'candidate_provenance' -and
    $source -match 'flash_readback_verified' -and
    $source -match 'hardware_interaction' -and
    $source -match 'serial_write_calls') `
    'live capture disposition lacks strict summary/provenance/safety binding'
Assert-Contract ($source -match
    '\[IO\.File\]::ReadAllText\(\$Path,\s*\$utf8\)' -and
    $source -match
      '\[IO\.File\]::ReadAllText\(\$latestPath,\s*\$utf8\)') `
    'JSON evidence is not decoded as explicit UTF-8 under Windows PowerShell'
Assert-Contract ($source -match '(?s)Assert-InstallProof.*candidate\.artifact_id.*candidate\.latest_sha256.*candidate\.handoff_sha256') `
    'candidate install proof is not bound to the selected sealed candidate'
Assert-Contract ($source -match
    '(?s)function\s+Get-CanonicalCandidate.*candidate_manifest.*Get-Sha256.*Assert-CandidateDiagnosticAbiContract.*handoff.*Assert-CandidateDiagnosticAbiContract' -and
    $source -match
      '(?s)\$candidate\s*=\s*Get-CanonicalCandidate.*\$jtagPreflightStep.*\$installStep') `
    'candidate manifest and handoff diagnostic ABI are not fail-closed before install'
Assert-Contract ($source -match
    '(?s)function\s+Assert-CanonicalCandidatePin.*LatestSha256.*expectedCandidateLatestSha256.*ArtifactId.*expectedCandidateArtifactId' -and
    $source -match
    '(?s)function\s+Get-CanonicalCandidate.*FileStream\]::new\(\$latestPath.*FileShare\]::Read.*\$latestSha256\s*=\s*Get-Sha256\s+\$latestPath.*ReadAllText\(\$latestPath,\s*\$utf8\).*Assert-CanonicalCandidatePin\s+\$latestSha256\s+\(\[string\]\$latest\.artifact_id\).*Resolve-RepoPath' -and
    $source -match
      'latest_sha256\s*=\s*\$latestSha256' -and
    $source -match
      'latest_lock_retained_until_outer_exit\s*=\s*\$true') `
    'canonical candidate is not exact-SHA/exact-artifact pinned and read-locked before artifact resolution'
Assert-Contract ($source -match
    '(?s)\$vehicleArguments.*Get-StageArguments\s+''vehicle''\s+\$expectedVehicleRuntimeStageAddress.*Get-StageProof\s+\$stageVehicleStep\s+''vehicle''\s+.*\$expectedVehicleRuntimeStageAddress' -and
    $source -match
    '(?s)\$groundArguments.*Get-StageArguments\s+''ground''\s+\$expectedGroundRuntimeStageAddress.*Get-StageProof\s+\$stageGroundStep\s+''ground''\s+.*\$expectedGroundRuntimeStageAddress' -and
    $source -match
    '(?s)stage_evidence=.*vehicle=.*address=\$expectedVehicleRuntimeStageAddress.*ground=.*address=\$expectedGroundRuntimeStageAddress') `
    'live stage calls, proof checks, and summary fallbacks do not share the sealed address pins'
Assert-Contract ($source -notmatch '0x3fcab470|0x3fca2690') `
    'orchestrator retains a stale runtime-stage address'
Assert-Contract ($source -match '(?s)Assert-Condition.*Get-Sha256\s+\$script:NmExecutable.*expectedNmSha256' -and
    $source -match '(?s)Assert-Condition.*Get-Sha256\s+\$script:OpenOcdExecutable.*expectedOpenOcdSha256') `
    'live debugger tools are not restricted to pinned tested hashes'
Assert-Contract ($source -match
    '(?s)Assert-Condition.*Get-Sha256\s+\$flashTool.*expectedFlashToolSha256' -and
    $source -match
    '(?s)Assert-Condition.*Get-Sha256\s+\$captureTool.*expectedCaptureToolSha256' -and
    $source -match
    '(?s)Get-Sha256\s+\$flashTool.*Get-Sha256\s+\$captureTool.*\$jtagPreflightStep\s*=\s*Invoke-ExperimentStep') `
    'live flash and capture child tools are not pinned to the reviewed hashes before hardware starts'
Assert-Contract ($source -match
    '(?s)function\s+Invoke-ChildPowerShell.*ExpectedScriptSha256.*FileShare\]::Read.*ComputeHash.*process\.Start\(\)' -and
    $source -match
    '(?s)function\s+Invoke-ExperimentStep.*ExpectedScriptSha256.*Invoke-ChildPowerShell.*ExpectedScriptSha256') `
    'child tools are not hash-verified under a read lock at their actual launch boundary'
Assert-Contract ($source -match 'unprovenChildScriptLocks' -and
    $source -match
    '(?s)retainScriptLock.*terminationProven.*processTreeTerminationProven' -and
    $source -match 'script_lock_retained_until_outer_exit') `
    'an unproven child can outlive the reviewed-script read lock'
Assert-Contract ($source -match
    '(?s)runner_integrity\.start_sha256.*expectedCaptureToolSha256') `
    'capture evidence is not bound to the exact reviewed capture child hash'
Assert-Contract ($source -match 'resume_shutdown_cleanup_proven' -and
    $source -match 'target_may_be_halted') `
    'stage proof does not require proven resume/shutdown cleanup'
Assert-Contract ($source -match
    '(?s)\$reads\.Count\s*-eq\s*4.*runtime_stage.*size=68.*endpoint_fifo.*size=112' -and
    $source -match
      '\[int\]\$read\.size_bytes\s*-eq\s*\[int\]\$expectedRead\.size') `
    'stage proof does not require all four fixed-size v3 record reads'
Assert-Contract ($source -match
    '(?s)decoded\.endpoint_fifo.*0x48313946.*usb_tx_boundary_classification') `
    'stage proof does not validate the Endpoint FIFO record and classification'
Assert-Contract ($source -match 'lastEventBusReset' -and
    $source -match 'last_event_bus_reset' -and
    $source -match 'usb_tx_boundary_completion_proven' -and
    $source -match
      '(?s)stageVehicleEvidence\.proven.*usb_tx_boundary_completion_proven' -and
    $source -match
      '(?s)stageGroundEvidence\.proven.*usb_tx_boundary_completion_proven') `
    'last-event BUS_RESET evidence can still be accepted as TX completion'
Assert-Contract ($source -match 'fifoCounterBasesValid' -and
    $source -match 'positiveFifoWriteAttempts' -and
    $source -match 'nonZlpWrDone' -and
    $source -match 'fifoCausalInvariantValid' -and
    $source -match 'payload_flush_pending' -and
    $source -match '0x00002000') `
    'stage proof does not enforce guarded Endpoint FIFO causal accounting'
Assert-Contract ($source -match 'decodedOperationalFlagsMatchMask' -and
    $source -match "'connected'\s*=\s*\[uint32\]0x00000004" -and
    $source -match "'fifo_writable'\s*=\s*\[uint32\]0x00000008" -and
    $source -match "'payload_in_flight'\s*=\s*\[uint32\]0x00000010" -and
    $source -match "'fifo_quarantined'\s*=\s*\[uint32\]0x00000020" -and
    $source -match "'reset_pending'\s*=\s*\[uint32\]0x00000040" -and
    $source -match "'bootstrap_fence'\s*=\s*\[uint32\]0x00000080" -and
    $source -match "'bootstrap_aborted'\s*=\s*\[uint32\]0x00000100" -and
    $source -match "'debug_writer_active'\s*=\s*\[uint32\]0x00000200") `
    'stage proof does not independently bind decoded operational flags to bits 2-9'
Assert-Contract ($source -match 'flags\.flush_active' -and
    $source -match 'counters\.flush_abort_inferred' -and
    $source -match
      '(?s)flushTerminalCount.*flushOpenCount.*flushAccountedCount.*flushAbortCount') `
    'stage proof does not enforce complete flush-attempt accounting'
Assert-Contract ($source -match 'last_flush_outcome' -and
    $source -match 'last_flush_outcome_code' -and
    $source -match 'last_flush_task_zlp_count' -and
    $source -match 'last_flush_isr_zlp_count' -and
    $source -match 'last_flush_terminal_blocker_mask' -and
    $source -match 'last_flush_terminal_blocker_mask_code' -and
    $source -match 'last_flush_classification' -and
    $source -match 'lastFlushOutcomeValid') `
    'stage proof does not validate schema-2 per-flush terminal-ZLP evidence'
Assert-Contract ($source -match 'WaitForExit\(\$TimeoutMilliseconds\)' -and
    $source -match '\$exitCode\s*=\s*124' -and
    $source -match 'Diagnostics\.ProcessStartInfo' -and
    $source -match 'RedirectStandardOutput\s*=\s*\$true' -and
    $source -match 'RedirectStandardError\s*=\s*\$true' -and
    $source -match 'CreateNoWindow\s*=\s*\$true' -and
    $source -match '(?s)else\s*\{.{0,300}?\$process\.WaitForExit\(\)\s*\$process\.Refresh\(\)\s*\$exitCode\s*=\s*\[int\]\$process\.ExitCode' -and
    $source -match "'active_jtag_vehicle'\s*\{[0-9]+\}" -and
    $source -match "'active_jtag_ground'\s*\{[0-9]+\}" -and
    $source -match "'rollback'\s*\{300000\}" -and
    $source -notmatch 'Start-Process\s+-FilePath\s+\(Get-PowerShellExecutable\)') `
    'child processes do not have bounded timeouts plus durable redirected-stream exit-code capture'
Assert-Contract ($source -match 'termination_proven' -and
    $source -match 'process_tree_termination_proven' -and
    $source -match 'Invoke-TaskkillProcessTree' -and
    $source -match 'tree_termination_proven' -and
    $source -match 'childTerminationUnproven' -and
    $source -match 'FAIL_CHILD_TERMINATION_UNPROVEN_POWER_OFF_REQUIRED' -and
    $source -match '(?s)if\s*\(\$childTerminationUnproven\).*?rollback') `
    'unproven child termination does not block all later hardware children and require power-off'
Assert-Contract ($source -match '(?s)Invoke-ExperimentStep.*?capture.*?Get-CaptureDisposition.*?Assert-Condition.*?captureDisposition\.acceptable.*?Invoke-ExperimentStep.*?stage_vehicle') `
    'capture evidence is not validated before the first JTAG stage read'
Assert-Contract ($source -match '\$vehiclePortChain' -and
    $source -match '\$groundPortChain' -and
    $source -match '\$vehiclePortChain\s+-cne\s+\$groundPortChain' -and
    $source -notmatch "pnp_port_chain\s*-ceq\s*'3\.[24]'") `
    'outer gate proof must accept runtime topology only when role chains are distinct'
Assert-Contract ($source -match
    '(?s)function\s+Get-JtagPreflightProof.*\$roles\.Count\s*-eq\s*2.*function\s+Test-ProbeLocationMatchesPnpChain') `
    'live PnP-only proof must require exactly two roles before accepting role identities'

$scenarios = @(
  [pscustomobject]@{
    name='usb_boundary_incomplete';expectedExit=1
    expectedStatus='FAIL_USB_TX_BOUNDARY_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground',
      'install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='ground_heartbeat_failure_observed';expectedExit=1
    expectedStatus='FAIL_GROUND_HEARTBEAT_PUBLICATION_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground',
      'install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='success';expectedExit=0;expectedStatus='PASS_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='capture_no_beacon';expectedExit=0;expectedStatus='PASS_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='capture_failure';expectedExit=1;expectedStatus='FAIL_CAPTURE_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','rollback')
  },
  [pscustomobject]@{
    name='capture_timing_sla_failure';expectedExit=1
    expectedStatus=
      'FAIL_CAPTURE_TIMING_SLA_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='capture_terminal_prefix_stall';expectedExit=1
    expectedStatus=
      'FAIL_CAPTURE_R19F_TAIL_STALL_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='capture_terminal_prefix_stall_stage_failure';expectedExit=1
    expectedStatus='FAIL_STAGE_READ_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='capture_alive_terminal_prefix_stall';expectedExit=1
    expectedStatus=
      'FAIL_CAPTURE_R19A_TAIL_STALL_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='capture_alive_terminal_prefix_stall_stage_failure';expectedExit=1
    expectedStatus='FAIL_STAGE_READ_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='capture_boundary_partial';expectedExit=1
    expectedStatus=
      'FAIL_CAPTURE_R19F_BOUNDARY_PARTIAL_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='capture_boundary_partial_stage_failure';expectedExit=1
    expectedStatus='FAIL_STAGE_READ_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='jtag_vehicle_failure';expectedExit=1;expectedStatus='FAIL_STAGE_READ_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='jtag_vehicle_cleanup_unproven';expectedExit=1;expectedStatus='FAIL_STAGE_READ_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','rollback')
  },
  [pscustomobject]@{
    name='jtag_vehicle_timeout';expectedExit=2;expectedStatus='FAIL_CHILD_TERMINATION_UNPROVEN_POWER_OFF_REQUIRED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle')
  },
  [pscustomobject]@{
    name='jtag_ground_failure';expectedExit=1;expectedStatus='FAIL_STAGE_READ_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='rollback_failure';expectedExit=2;expectedStatus='FAIL_ROLLBACK_UNPROVEN_POWER_OFF_REQUIRED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','capture','stage_vehicle','stage_ground','rollback')
  },
  [pscustomobject]@{
    name='install_failure';expectedExit=1;expectedStatus='FAIL_INSTALL_R18_RESTORED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground','install','rollback')
  },
  [pscustomobject]@{
    name='active_jtag_vehicle_failure';expectedExit=1
    expectedStatus='FAIL_ACTIVE_JTAG_PREFLIGHT_NO_FLASH'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle')
  },
  [pscustomobject]@{
    name='active_jtag_ground_failure';expectedExit=1
    expectedStatus='FAIL_ACTIVE_JTAG_PREFLIGHT_NO_FLASH'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground')
  },
  [pscustomobject]@{
    name='active_jtag_vehicle_cleanup_unproven';expectedExit=2
    expectedStatus='FAIL_ACTIVE_JTAG_CLEANUP_UNPROVEN_POWER_OFF_REQUIRED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle')
  },
  [pscustomobject]@{
    name='active_jtag_ground_cleanup_unproven';expectedExit=2
    expectedStatus='FAIL_ACTIVE_JTAG_CLEANUP_UNPROVEN_POWER_OFF_REQUIRED'
    expectedSteps=@('jtag_preflight','active_jtag_vehicle','active_jtag_ground')
  },
  [pscustomobject]@{
    name='active_jtag_location_mismatch';expectedExit=1
    expectedStatus='FAIL_ACTIVE_JTAG_LOCATION_BINDING_NO_FLASH'
    expectedSteps=@('jtag_preflight')
  },
  [pscustomobject]@{
    name='jtag_preflight_failure';expectedExit=1
    expectedStatus='FAIL_JTAG_PREFLIGHT_NO_FLASH'
    expectedSteps=@('jtag_preflight')
  },
  [pscustomobject]@{
    name='reader_missing';expectedExit=1;expectedStatus='FAIL_PREFLIGHT_NO_HARDWARE'
    expectedSteps=@()
  }
)

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('vc_lora_r19_stage_cause_contract_' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  $parseTokens = $null
  $parseErrors = $null
  $runnerAst = [Management.Automation.Language.Parser]::ParseFile(
      $runnerPath,[ref]$parseTokens,[ref]$parseErrors)
  Assert-Contract (@($parseErrors).Count -eq 0) `
      'orchestrator cannot be parsed for child-launcher behavior test'
  foreach ($functionName in @('Assert-Condition','Get-Sha256',
      'Assert-CanonicalCandidatePin',
      'Resolve-RepoPath','Get-CanonicalCandidate',
      'Assert-CandidateDiagnosticAbiContract',
      'Read-JsonIfPresent','Get-CaptureDisposition','Get-JtagPreflightProof',
      'Test-R19AliveTerminalPartialEvidence',
      'Test-R19FailureBoundaryPartialEvidence',
      'Test-ProbeLocationMatchesPnpChain','Get-ActiveJtagPreflightProof',
      'Assert-RawProjection','Get-RawRestartState','Get-RawFifoBoundary',
      'Get-RawFirstFailureU64','Get-RawFirstUsbFailureRecord',
      'Get-FirstUsbFailureCauseObservation',
      'Get-ExtendedStageRawReplay',
      'Get-StageProof',
      'Get-PowerShellExecutable',
      'Convert-ArgumentForStartProcess','Write-Text',
      'Invoke-ChildPowerShell')) {
    $matches = @($runnerAst.FindAll({
          param($node)
          $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -ceq $functionName
        },$true))
    Assert-Contract ($matches.Count -eq 1) `
        "orchestrator function is absent or ambiguous: $functionName"
    . ([scriptblock]::Create($matches[0].Extent.Text))
  }
  Assert-CanonicalCandidatePin $candidateLatestSha256 $candidateArtifactId
  foreach ($candidatePinMutation in @(
      [pscustomobject]@{name='different_latest_sha';sha=('0' * 64)
        artifact=$candidateArtifactId},
      [pscustomobject]@{name='different_artifact_id';sha=$candidateLatestSha256
        artifact='20261012T151448091Z-different'}
    )) {
    $candidatePinRejected = $false
    try {
      Assert-CanonicalCandidatePin $candidatePinMutation.sha `
          $candidatePinMutation.artifact
    } catch {$candidatePinRejected = $true}
    Assert-Contract $candidatePinRejected `
        "canonical candidate pin mutation was accepted: $($candidatePinMutation.name)"
  }
  $latestPath = $candidateLatestPath
  $utf8 = [Text.UTF8Encoding]::new($false)
  $script:candidateLatestLock = $null
  try {
    $canonicalCandidate = Get-CanonicalCandidate
    Assert-Contract ([string]$canonicalCandidate.artifact_id -ceq
        $candidateArtifactId -and
        [string]$canonicalCandidate.latest_sha256 -ceq
          $candidateLatestSha256 -and
        [bool]$canonicalCandidate.latest_lock_retained_until_outer_exit) `
        'canonical candidate reader did not return the exact pinned identity'
    $latestWriteBlocked = $false
    try {
      $latestWriteProbe = [IO.FileStream]::new($candidateLatestPath,
          [IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
      $latestWriteProbe.Dispose()
    } catch [IO.IOException] {$latestWriteBlocked = $true}
    Assert-Contract $latestWriteBlocked `
        'canonical latest remained writable after exact candidate selection'
  } finally {
    if ($null -ne $script:candidateLatestLock) {
      $script:candidateLatestLock.Dispose()
      $script:candidateLatestLock = $null
    }
  }
  $validDiagnosticAbi = [pscustomobject][ordered]@{
    endpoint_fifo_schema=2
    endpoint_fifo_size_bytes=112
    runtime_stage_size_bytes=68
    reader_schema='vc-lora-r19-runtime-stage-jtag-read-v3'
  }
  Assert-CandidateDiagnosticAbiContract $validDiagnosticAbi 'valid-fixture'
  $validExtendedAbi = $validDiagnosticAbi | ConvertTo-Json -Depth 12 |
      ConvertFrom-Json
  $validExtendedAbi.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v4'
  $validExtendedAbi | Add-Member NoteProperty usb_extended_diagnostics (
    [pscustomobject][ordered]@{
      schema='vc-lora-r19-usb-extended-diagnostics-v1';enabled=$true
      records=[pscustomobject][ordered]@{
        hwcdc_restart=[pscustomobject]@{
          symbol='vc_lora_r19_hwcdc_restart_diagnostic_record'
          schema_version=1;size_bytes=128}
        ground_usb_commit=[pscustomobject]@{
          symbol='vc_lora_r19_ground_usb_commit_record'
          schema_version=1;size_bytes=128}
      }
    })
  Assert-CandidateDiagnosticAbiContract $validExtendedAbi 'valid-v4-fixture'
  foreach($mutation in @(
      @{name='v4_missing_extension';apply={param($v)$v.PSObject.Properties.Remove('usb_extended_diagnostics')}},
      @{name='v4_disabled';apply={param($v)$v.usb_extended_diagnostics.enabled=$false}},
      @{name='v4_string_enabled';apply={param($v)$v.usb_extended_diagnostics.enabled='true'}},
      @{name='v4_unknown_extension';apply={param($v)$v.usb_extended_diagnostics.schema='v2'}},
      @{name='v4_wrong_symbol';apply={param($v)$v.usb_extended_diagnostics.records.ground_usb_commit.symbol='other'}},
      @{name='v4_wrong_size';apply={param($v)$v.usb_extended_diagnostics.records.hwcdc_restart.size_bytes=124}},
      @{name='v4_string_size';apply={param($v)$v.usb_extended_diagnostics.records.hwcdc_restart.size_bytes='128'}},
      @{name='v4_wrong_version';apply={param($v)$v.usb_extended_diagnostics.records.ground_usb_commit.schema_version=2}},
      @{name='v3_extension_present';apply={param($v)$v.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v3'}}
    )){
    $v=$validExtendedAbi|ConvertTo-Json -Depth 12|ConvertFrom-Json
    & $mutation.apply $v
    $rejected=$false
    try{Assert-CandidateDiagnosticAbiContract $v $mutation.name}catch{$rejected=$true}
    Assert-Contract $rejected "extended ABI mutation accepted: $($mutation.name)"
  }
  foreach ($abiMutation in @(
      [pscustomobject]@{name='missing_endpoint_fifo_schema';apply={param($v)
        $v.PSObject.Properties.Remove('endpoint_fifo_schema')}},
      [pscustomobject]@{name='legacy_endpoint_fifo_schema';apply={param($v)
        $v.endpoint_fifo_schema=1}},
      [pscustomobject]@{name='legacy_endpoint_fifo_size';apply={param($v)
        $v.endpoint_fifo_size_bytes=96}},
      [pscustomobject]@{name='wrong_runtime_stage_size';apply={param($v)
        $v.runtime_stage_size_bytes=64}},
      [pscustomobject]@{name='legacy_reader_schema';apply={param($v)
        $v.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v2'}},
      [pscustomobject]@{name='numeric_value_as_string';apply={param($v)
        $v.endpoint_fifo_size_bytes='112'}}
    )) {
    $invalidDiagnosticAbi = [pscustomobject][ordered]@{
      endpoint_fifo_schema=2
      endpoint_fifo_size_bytes=112
      runtime_stage_size_bytes=68
      reader_schema='vc-lora-r19-runtime-stage-jtag-read-v3'
    }
    & $abiMutation.apply $invalidDiagnosticAbi
    $abiRejected = $false
    try {
      Assert-CandidateDiagnosticAbiContract $invalidDiagnosticAbi `
          $abiMutation.name
    } catch {$abiRejected = $true}
    Assert-Contract $abiRejected `
        "candidate diagnostic ABI mutation was accepted: $($abiMutation.name)"
  }
  Assert-Contract (Test-Path -LiteralPath $nativeMockPath -PathType Leaf) `
      'native stderr/exit mock is missing'
  $OutputDirectory = Join-Path $tempRoot 'child-launcher-probe'
  New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
  $utf8 = [Text.UTF8Encoding]::new($false)
  $newline = [Environment]::NewLine
  $nativeMockSha256 = Get-Sha256 $nativeMockPath
  $childFailureSummaryPath = Join-Path $OutputDirectory `
      'controlled-failure-summary.json'
  $childFailureStep = Invoke-ChildPowerShell -Name 'controlled_failure' `
      -ScriptPath $nativeMockPath -Arguments @(
        '-ExitCode','23','-SummaryPath',$childFailureSummaryPath) `
      -TimeoutMilliseconds 5000 -ExpectedScriptSha256 $nativeMockSha256
  Assert-Contract (Test-Path -LiteralPath $childFailureSummaryPath -PathType Leaf) `
      ('summary-producing child did not write its summary; step=' +
        ($childFailureStep | ConvertTo-Json -Depth 5 -Compress))
  $childFailureSummary = Get-Content -LiteralPath $childFailureSummaryPath `
      -Raw | ConvertFrom-Json
  Assert-Contract ([int]$childFailureStep.exit_code -eq 23 -and
      [string]$childFailureStep.result -ceq 'FAIL' -and
      -not [bool]$childFailureStep.timed_out -and
      [bool]$childFailureStep.termination_proven -and
      [bool]$childFailureStep.process_tree_termination_proven -and
      [string]$childFailureSummary.result -ceq 'FAIL' -and
      (Get-Content -LiteralPath $childFailureStep.stderr_path -Raw) -match
        'MOCK_NATIVE_STDERR_SENTINEL') `
      ('outer child step did not preserve a summary-producing child nonzero exit; step=' +
        ($childFailureStep | ConvertTo-Json -Depth 5 -Compress) +
        '; summary=' + ($childFailureSummary | ConvertTo-Json -Compress))
  $childZeroStep = Invoke-ChildPowerShell -Name 'controlled_zero' `
      -ScriptPath $nativeMockPath -Arguments @('-ExitCode','0') `
      -TimeoutMilliseconds 5000 -ExpectedScriptSha256 $nativeMockSha256
  Assert-Contract ([int]$childZeroStep.exit_code -eq 0 -and
      [string]$childZeroStep.result -ceq 'PASS' -and
      [bool]$childZeroStep.termination_proven -and
      [bool]$childZeroStep.process_tree_termination_proven -and
      (Get-Content -LiteralPath $childZeroStep.stderr_path -Raw) -match
        'MOCK_NATIVE_STDERR_SENTINEL') `
      'outer child step treated expected stderr as failure or lost exit zero'
  $mutatedChildPath = Join-Path $tempRoot 'mutated-child.ps1'
  [IO.File]::Copy($nativeMockPath,$mutatedChildPath)
  $preMutationSha256 = Get-Sha256 $mutatedChildPath
  [IO.File]::AppendAllText($mutatedChildPath,$newline + '# mutation',$utf8)
  $mutationRejected = $false
  try {
    [void](Invoke-ChildPowerShell -Name 'mutated_child' `
      -ScriptPath $mutatedChildPath -Arguments @('-ExitCode','0') `
      -TimeoutMilliseconds 5000 -ExpectedScriptSha256 $preMutationSha256)
  } catch {
    $mutationRejected = $_.Exception.Message -match 'reviewed pinned tool'
  }
  Assert-Contract $mutationRejected `
      'child mutation after the initial gate was not rejected at launch'

  function Invoke-TaskkillProcessTree([int]$ProcessId,
      [int]$TimeoutMilliseconds=10000) {
    try {Stop-Process -Id $ProcessId -Force -ErrorAction Stop} catch {}
    [pscustomobject][ordered]@{
      started=$true;exit_code=1;timed_out=$false;process_exited=$true
      tree_termination_proven=$false;failure='contract_forced_unproven_tree'
    }
  }
  $script:unprovenChildScriptLocks =
      New-Object 'System.Collections.Generic.List[System.IO.FileStream]'
  $unprovenChildPath = Join-Path $tempRoot 'unproven-child.ps1'
  [IO.File]::Copy($nativeMockPath,$unprovenChildPath)
  $unprovenChildSha256 = Get-Sha256 $unprovenChildPath
  try {
    $unprovenStep = Invoke-ChildPowerShell -Name 'unproven_child' `
        -ScriptPath $unprovenChildPath -Arguments @(
          '-ExitCode','0','-HangMilliseconds','60000') `
        -TimeoutMilliseconds 100 -ExpectedScriptSha256 $unprovenChildSha256
    Assert-Contract ([bool]$unprovenStep.timed_out -and
        [bool]$unprovenStep.termination_proven -and
        -not[bool]$unprovenStep.process_tree_termination_proven -and
        [bool]$unprovenStep.script_lock_retained_until_outer_exit) `
        'forced unproven child did not enter the retained-lock path'
    $writeBlocked = $false
    try {
      $writeProbe = [IO.FileStream]::new($unprovenChildPath,
          [IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
      $writeProbe.Dispose()
    } catch [IO.IOException] {$writeBlocked = $true}
    Assert-Contract ($writeBlocked -and
        $script:unprovenChildScriptLocks.Count -eq 1 -and
        (Get-Sha256 $unprovenChildPath) -ceq $unprovenChildSha256) `
        'reviewed child script was writable after termination became unproven'
  } finally {
    foreach($retainedLock in @($script:unprovenChildScriptLocks)) {
      $retainedLock.Dispose()
    }
    $script:unprovenChildScriptLocks.Clear()
  }
  $releasedProbe = [IO.FileStream]::new($unprovenChildPath,
      [IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $releasedProbe.Dispose()

  $OfflineContractTest = [Management.Automation.SwitchParameter]$false
  $CaptureSeconds = 40
  $candidate = [pscustomobject]@{artifact_id=$candidateArtifactId}
  $stageEvidenceDirectory = Join-Path $tempRoot 'stage-v3-live-json-validation'
  New-Item -ItemType Directory -Path $stageEvidenceDirectory | Out-Null
  $stageSummaryPath = Join-Path $stageEvidenceDirectory 'summary.json'
  $stageRuntimeFirstPath = Join-Path $stageEvidenceDirectory `
      'runtime-stage-first.bin'
  $stageRuntimeSecondPath = Join-Path $stageEvidenceDirectory `
      'runtime-stage-second.bin'
  $stageFifoFirstPath = Join-Path $stageEvidenceDirectory `
      'endpoint-fifo-first.bin'
  $stageFifoSecondPath = Join-Path $stageEvidenceDirectory `
      'endpoint-fifo-second.bin'
  [byte[]]$stageRuntimeBytes = 1..68 | ForEach-Object {[byte]$_}
  [byte[]]$stageFifoBytes = 1..112 | ForEach-Object {[byte](($_+31)-band 0xff)}
  [IO.File]::WriteAllBytes($stageRuntimeFirstPath,$stageRuntimeBytes)
  [IO.File]::WriteAllBytes($stageRuntimeSecondPath,$stageRuntimeBytes)
  [IO.File]::WriteAllBytes($stageFifoFirstPath,$stageFifoBytes)
  [IO.File]::WriteAllBytes($stageFifoSecondPath,$stageFifoBytes)
  $stageRuntimeSha256 = Get-Sha256 $stageRuntimeFirstPath
  $stageFifoSha256 = Get-Sha256 $stageFifoFirstPath
  $stageStep = [pscustomobject]@{exit_code=0}
  function New-ValidStageV3Summary {
    [pscustomobject][ordered]@{
      schema='vc-lora-r19-runtime-stage-jtag-read-v3'
      result='PASS';mode='live-jtag';hardware_interaction=$true
      safety=[pscustomobject][ordered]@{
        com_opened=$false;flash_written=$false;target_restart_issued=$false
        two_identical_reads=$true
        resume_shutdown_cleanup_attempted=$true
        resume_shutdown_cleanup_proven=$true
        native_processes_termination_proven=$true
        target_may_be_halted=$false
      }
      binding=[pscustomobject][ordered]@{
        artifact_id=$candidateArtifactId;role='vehicle'
        address='0x3fcab480';runtime_stage_address='0x3fcab480'
        endpoint_fifo_address='0x3fcab7f4'
        probe=[pscustomobject]@{
          requested_usb_location='1-4.2'
          opened_identity_proven_before_halt=$true
        }
      }
      reads=@(
        [pscustomobject]@{record='runtime_stage';sample=1;size_bytes=68
          sha256=$stageRuntimeSha256;path=$stageRuntimeFirstPath},
        [pscustomobject]@{record='endpoint_fifo';sample=1;size_bytes=112
          sha256=$stageFifoSha256;path=$stageFifoFirstPath},
        [pscustomobject]@{record='runtime_stage';sample=2;size_bytes=68
          sha256=$stageRuntimeSha256;path=$stageRuntimeSecondPath},
        [pscustomobject]@{record='endpoint_fifo';sample=2;size_bytes=112
          sha256=$stageFifoSha256;path=$stageFifoSecondPath}
      )
      decoded=[pscustomobject][ordered]@{
        active_writer=0;sequence=24;magic='0x52313953';schema=1
        role='vehicle';boundary_classification='loop-entered-before-host-gate'
        first_failure=[pscustomobject]@{code='0x00000000';name='None'
          stage_mask='0x00000000';detail=0}
        endpoint_fifo=[pscustomobject][ordered]@{
          active_writer=0;sequence=12;magic='0x48313946';schema=2
          state_semantics=
            'last-committed-diagnostic-event-not-live-hardware-state'
          flags=[pscustomobject]@{mask='0x00000003';initialized=$true
            observation_active=$true;connected=$false;fifo_writable=$false
            payload_in_flight=$false;fifo_quarantined=$false
            reset_pending=$false;bootstrap_fence=$false
            bootstrap_aborted=$false;debug_writer_active=$false
            diagnostic_observation_window_started=$true
            fifo_write_attempt_observed=$true
            positive_fifo_write_observed=$true
            wr_done_observed=$true;payload_pickup_observed=$true
            last_event_bus_reset=$false;flush_active=$false
            payload_publish_pending=$false;payload_publish_aborted=$false
            payload_flush_pending=$false}
          last_fifo_write_size=32
          counters=[pscustomobject]@{fifo_write_attempt=1;fifo_write_bytes=32
            fifo_zero_write=0;wr_done=2;in_empty_irq=1
            payload_in_empty=1;bus_reset=0;flush_attempt=1
            flush_success=1;flush_timeout=0;flush_abort_inferred=0
            zlp_flush=1}
          generations=[pscustomobject]@{publish=1;pickup=1
            relationship='publish-equals-pickup'}
          last_interrupt_status='0x00000008'
          flush_blockers=[pscustomobject]@{mask='0x00000000';names=@()}
          last_flush_outcome='Success';last_flush_outcome_code=2
          last_flush_task_zlp_count=1;last_flush_isr_zlp_count=0
          last_flush_terminal_blocker_mask='0x00000000'
          last_flush_terminal_blocker_mask_code=0
          last_flush_terminal_blocker_names=@()
          last_flush_classification='success-with-task-zlp'
          boundary_classification='usb-tx-boundary-complete'
          usb_tx_boundary_completion_proven=$true
        }
        usb_tx_boundary_classification='usb-tx-boundary-complete'
        usb_tx_boundary_completion_proven=$true
      }
    }
  }
  function Write-StageSummary([object]$Value) {
    [IO.File]::WriteAllText($stageSummaryPath,
        ($Value|ConvertTo-Json -Depth 12),$utf8)
  }
  $validStageV3 = New-ValidStageV3Summary
  Write-StageSummary $validStageV3
  $validStageProof = Get-StageProof $stageStep 'vehicle' '0x3fcab480' `
      '1-4.2' $stageEvidenceDirectory
  Assert-Contract ([bool]$validStageProof.proven -and
      [bool]$validStageProof.usb_tx_boundary_completion_proven -and
      [string]$validStageProof.usb_tx_boundary_classification -ceq
        'usb-tx-boundary-complete' -and
      [int]$validStageProof.endpoint_fifo.schema -eq 2 -and
      [string]$validStageProof.endpoint_fifo.last_flush_outcome -ceq
        'Success') `
      'valid reader-v3 dual-record proof was not accepted'

  # Reader-v3 explicitly represents a legitimate short-packet completion with
  # no terminal ZLP. Preserve all old malformed-success mutations below.
  $shortPacketStageV3=New-ValidStageV3Summary
  $shortPacketStageV3.decoded.endpoint_fifo.last_fifo_write_size=31
  $shortPacketStageV3.decoded.endpoint_fifo.counters.fifo_write_bytes=31
  $shortPacketStageV3.decoded.endpoint_fifo.counters.zlp_flush=0
  $shortPacketStageV3.decoded.endpoint_fifo.counters.wr_done=1
  $shortPacketStageV3.decoded.endpoint_fifo.last_flush_task_zlp_count=0
  $shortPacketStageV3.decoded.endpoint_fifo.last_flush_classification=
      'success-with-short-packet-no-zlp'
  Write-StageSummary $shortPacketStageV3
  $shortPacketProof=Get-StageProof $stageStep 'vehicle' '0x3fcab480' `
      '1-4.2' $stageEvidenceDirectory
  Assert-Contract ([bool]$shortPacketProof.proven-and
      [bool]$shortPacketProof.usb_tx_boundary_completion_proven-and
      [string]$shortPacketProof.endpoint_fifo.last_flush_classification-ceq
        'success-with-short-packet-no-zlp') `
      'valid reader-v3 short packet without terminal ZLP was rejected'
  foreach($malformedClassification in @('success-with-task-zlp',
      'success-without-terminal-zlp','abort-epoch-mismatch')){
    $malformedShort=$shortPacketStageV3|ConvertTo-Json -Depth 20|ConvertFrom-Json
    $malformedShort.decoded.endpoint_fifo.last_flush_classification=
        $malformedClassification
    Write-StageSummary $malformedShort
    Assert-Contract (-not[bool](Get-StageProof $stageStep 'vehicle' `
        '0x3fcab480' '1-4.2' $stageEvidenceDirectory).proven) `
        "short-packet proof accepted inconsistent classification: $malformedClassification"
  }
  foreach($shortMutation in @(
      [pscustomobject]@{name='zero_last_write';apply={param($v)
        $v.decoded.endpoint_fifo.last_fifo_write_size=0}},
      [pscustomobject]@{name='full_packet_last_write';apply={param($v)
        $v.decoded.endpoint_fifo.last_fifo_write_size=64}},
      [pscustomobject]@{name='isr_zlp_not_zero';apply={param($v)
        $v.decoded.endpoint_fifo.last_flush_isr_zlp_count=1}})){
    $malformedShort=$shortPacketStageV3|ConvertTo-Json -Depth 20|ConvertFrom-Json
    & $shortMutation.apply $malformedShort
    Write-StageSummary $malformedShort
    Assert-Contract (-not[bool](Get-StageProof $stageStep 'vehicle' `
        '0x3fcab480' '1-4.2' $stageEvidenceDirectory).proven) `
        "short-packet proof accepted non-short evidence: $($shortMutation.name)"
  }

  $resetStageV3 = New-ValidStageV3Summary
  $resetStageV3.decoded.endpoint_fifo.counters.bus_reset = 1
  $resetStageV3.decoded.endpoint_fifo.last_interrupt_status = '0x00000200'
  $resetStageV3.decoded.endpoint_fifo.flags.last_event_bus_reset = $true
  $resetStageV3.decoded.endpoint_fifo.boundary_classification =
    'last-event-bus-reset'
  $resetStageV3.decoded.endpoint_fifo.usb_tx_boundary_completion_proven =
    $false
  $resetStageV3.decoded.usb_tx_boundary_classification =
    'last-event-bus-reset'
  $resetStageV3.decoded.usb_tx_boundary_completion_proven = $false
  Write-StageSummary $resetStageV3
  $resetStageProof = Get-StageProof $stageStep 'vehicle' '0x3fcab480' `
      '1-4.2' $stageEvidenceDirectory
  Assert-Contract ([bool]$resetStageProof.proven -and
      -not [bool]$resetStageProof.usb_tx_boundary_completion_proven -and
      [string]$resetStageProof.usb_tx_boundary_classification -ceq
        'last-event-bus-reset') `
      'coherent last-event BUS_RESET evidence was accepted as TX completion'

  $pendingStageV3 = New-ValidStageV3Summary
  $pendingStageV3.decoded.endpoint_fifo.flags.mask = '0x00002803'
  $pendingStageV3.decoded.endpoint_fifo.flags.payload_publish_pending = $true
  $pendingStageV3.decoded.endpoint_fifo.flags.payload_flush_pending = $true
  $pendingStageV3.decoded.endpoint_fifo.counters.fifo_write_attempt = 2
  $pendingStageV3.decoded.endpoint_fifo.counters.fifo_write_bytes = 51
  $pendingStageV3.decoded.endpoint_fifo.last_fifo_write_size = 19
  $pendingStageV3.decoded.endpoint_fifo.boundary_classification =
    'payload-publish-pending'
  $pendingStageV3.decoded.endpoint_fifo.usb_tx_boundary_completion_proven =
    $false
  $pendingStageV3.decoded.usb_tx_boundary_classification =
    'payload-publish-pending'
  $pendingStageV3.decoded.usb_tx_boundary_completion_proven = $false
  Write-StageSummary $pendingStageV3
  $pendingStageProof = Get-StageProof $stageStep 'vehicle' '0x3fcab480' `
      '1-4.2' $stageEvidenceDirectory
  Assert-Contract ([bool]$pendingStageProof.proven -and
      -not [bool]$pendingStageProof.usb_tx_boundary_completion_proven -and
      [string]$pendingStageProof.usb_tx_boundary_classification -ceq
        'payload-publish-pending') `
      'pending second payload reused historical success as TX completion'

  $abortedStageV3 = New-ValidStageV3Summary
  $abortedStageV3.decoded.endpoint_fifo.flags.mask = '0x00001003'
  $abortedStageV3.decoded.endpoint_fifo.flags.payload_publish_aborted = $true
  $abortedStageV3.decoded.endpoint_fifo.counters.bus_reset = 1
  $abortedStageV3.decoded.endpoint_fifo.boundary_classification =
    'payload-publish-aborted'
  $abortedStageV3.decoded.endpoint_fifo.usb_tx_boundary_completion_proven =
    $false
  $abortedStageV3.decoded.usb_tx_boundary_classification =
    'payload-publish-aborted'
  $abortedStageV3.decoded.usb_tx_boundary_completion_proven = $false
  Write-StageSummary $abortedStageV3
  $abortedStageProof = Get-StageProof $stageStep 'vehicle' '0x3fcab480' `
      '1-4.2' $stageEvidenceDirectory
  Assert-Contract ([bool]$abortedStageProof.proven -and
      -not [bool]$abortedStageProof.usb_tx_boundary_completion_proven -and
      [string]$abortedStageProof.usb_tx_boundary_classification -ceq
        'payload-publish-aborted') `
      'task discard after BUS_RESET reused historical success as TX completion'

  $flushPendingStageV3 = New-ValidStageV3Summary
  $flushPendingStageV3.decoded.endpoint_fifo.flags.mask = '0x00002003'
  $flushPendingStageV3.decoded.endpoint_fifo.flags.payload_flush_pending = $true
  $flushPendingStageV3.decoded.endpoint_fifo.counters.bus_reset = 1
  $flushPendingStageV3.decoded.endpoint_fifo.boundary_classification =
    'payload-flush-pending'
  $flushPendingStageV3.decoded.endpoint_fifo.usb_tx_boundary_completion_proven =
    $false
  $flushPendingStageV3.decoded.usb_tx_boundary_classification =
    'payload-flush-pending'
  $flushPendingStageV3.decoded.usb_tx_boundary_completion_proven = $false
  Write-StageSummary $flushPendingStageV3
  $flushPendingStageProof = Get-StageProof $stageStep 'vehicle' '0x3fcab480' `
      '1-4.2' $stageEvidenceDirectory
  Assert-Contract ([bool]$flushPendingStageProof.proven -and
      -not [bool]$flushPendingStageProof.usb_tx_boundary_completion_proven -and
      [string]$flushPendingStageProof.usb_tx_boundary_classification -ceq
        'payload-flush-pending') `
      'picked-up new payload reused historical flush success before its new flush'

  foreach ($mutation in @(
      [pscustomobject]@{name='v2_schema';apply={param($v)
        $v.schema='vc-lora-r19-runtime-stage-jtag-read-v2'}},
      [pscustomobject]@{name='missing_endpoint_record';apply={param($v)
        $v.decoded.PSObject.Properties.Remove('endpoint_fifo')}},
      [pscustomobject]@{name='missing_endpoint_read';apply={param($v)
        $v.reads=@($v.reads|Where-Object{[string]$_.record-cne'endpoint_fifo' -or
          [int]$_.sample-ne2})}},
      [pscustomobject]@{name='wrong_endpoint_size';apply={param($v)
        $v.reads[1].size_bytes=96}},
      [pscustomobject]@{name='unstable_endpoint_reads';apply={param($v)
        $v.reads[3].sha256=('C'*64)}},
      [pscustomobject]@{name='wrong_endpoint_magic';apply={param($v)
        $v.decoded.endpoint_fifo.magic='0x00000000'}},
      [pscustomobject]@{name='classification_mismatch';apply={param($v)
        $v.decoded.usb_tx_boundary_classification='flush-blocked'}},
      [pscustomobject]@{name='missing_flush_active';apply={param($v)
        $v.decoded.endpoint_fifo.flags.PSObject.Properties.Remove(
          'flush_active')}},
      [pscustomobject]@{name='missing_flush_abort';apply={param($v)
        $v.decoded.endpoint_fifo.counters.PSObject.Properties.Remove(
          'flush_abort_inferred')}},
      [pscustomobject]@{name='legacy_fifo_schema';apply={param($v)
        $v.decoded.endpoint_fifo.schema=1}},
      [pscustomobject]@{name='missing_last_flush_outcome';apply={param($v)
        $v.decoded.endpoint_fifo.PSObject.Properties.Remove(
          'last_flush_outcome')}},
      [pscustomobject]@{name='unknown_last_flush_outcome';apply={param($v)
        $v.decoded.endpoint_fifo.last_flush_outcome='Unknown'}},
      [pscustomobject]@{name='wrong_last_flush_outcome_code';apply={param($v)
        $v.decoded.endpoint_fifo.last_flush_outcome_code=3}},
      [pscustomobject]@{name='missing_last_flush_task_zlp';apply={param($v)
        $v.decoded.endpoint_fifo.PSObject.Properties.Remove(
          'last_flush_task_zlp_count')}},
      [pscustomobject]@{name='missing_last_flush_isr_zlp';apply={param($v)
        $v.decoded.endpoint_fifo.PSObject.Properties.Remove(
          'last_flush_isr_zlp_count')}},
      [pscustomobject]@{name='unknown_terminal_blocker_bit';apply={param($v)
        $v.decoded.endpoint_fifo.last_flush_terminal_blocker_mask=
          '0x00000100'
        $v.decoded.endpoint_fifo.last_flush_terminal_blocker_mask_code=256}},
      [pscustomobject]@{name='missing_last_flush_classification';apply={param($v)
        $v.decoded.endpoint_fifo.PSObject.Properties.Remove(
          'last_flush_classification')}},
      [pscustomobject]@{name='wrong_last_flush_classification';apply={param($v)
        $v.decoded.endpoint_fifo.last_flush_classification=
          'timeout-without-terminal-blocker'}},
      [pscustomobject]@{name='fifo_not_initialized';apply={param($v)
        $v.decoded.endpoint_fifo.flags.initialized=$false
        $v.decoded.endpoint_fifo.flags.mask='0x00000002'}},
      [pscustomobject]@{name='observation_window_not_started';apply={param($v)
        $v.decoded.endpoint_fifo.flags.observation_active=$false
        $v.decoded.endpoint_fifo.flags.mask='0x00000001'}},
      [pscustomobject]@{name='wrong_state_semantics';apply={param($v)
        $v.decoded.endpoint_fifo.state_semantics='live-hardware-state'}},
      [pscustomobject]@{name='last_bus_reset_reuses_historical_success';apply={param($v)
        $v.decoded.endpoint_fifo.counters.bus_reset=1
        $v.decoded.endpoint_fifo.last_interrupt_status='0x00000200'
        $v.decoded.endpoint_fifo.flags.last_event_bus_reset=$true}},
      [pscustomobject]@{name='fifo_activity_witness_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.positive_fifo_write_observed=$false}},
      [pscustomobject]@{name='payload_publish_pending_mask_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.payload_publish_pending=$true}},
      [pscustomobject]@{name='payload_publish_aborted_mask_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.payload_publish_aborted=$true}},
      [pscustomobject]@{name='payload_flush_pending_mask_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.payload_flush_pending=$true}},
      [pscustomobject]@{name='connected_mask_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.connected=$true}},
      [pscustomobject]@{name='fifo_writable_mask_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.fifo_writable=$true}},
      [pscustomobject]@{name='payload_in_flight_mask_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.payload_in_flight=$true}},
      [pscustomobject]@{name='fifo_quarantined_mask_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.fifo_quarantined=$true}},
      [pscustomobject]@{name='reset_pending_mask_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.reset_pending=$true}},
      [pscustomobject]@{name='bootstrap_fence_mask_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.bootstrap_fence=$true}},
      [pscustomobject]@{name='bootstrap_aborted_mask_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.bootstrap_aborted=$true}},
      [pscustomobject]@{name='debug_writer_active_mask_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.flags.debug_writer_active=$true}},
      [pscustomobject]@{name='fifo_zero_write_exceeds_attempt';apply={param($v)
        $v.decoded.endpoint_fifo.counters.fifo_zero_write=2}},
      [pscustomobject]@{name='fifo_zlp_flush_exceeds_wr_done';apply={param($v)
        $v.decoded.endpoint_fifo.counters.zlp_flush=3}},
      [pscustomobject]@{name='fifo_payload_exceeds_non_zlp_wr_done';apply={param($v)
        $v.decoded.endpoint_fifo.counters.payload_in_empty=2
        $v.decoded.endpoint_fifo.counters.in_empty_irq=2}},
      [pscustomobject]@{name='fifo_non_zlp_wr_done_exceeds_positive_write';apply={param($v)
        $v.decoded.endpoint_fifo.counters.wr_done=3}},
      [pscustomobject]@{name='success_without_task_final_zlp';apply={param($v)
        $v.decoded.endpoint_fifo.counters.zlp_flush=0
        $v.decoded.endpoint_fifo.counters.wr_done=1
        $v.decoded.endpoint_fifo.last_flush_task_zlp_count=0
        $v.decoded.endpoint_fifo.last_flush_classification=
          'success-without-terminal-zlp'}},
      [pscustomobject]@{name='abort_without_epoch_mismatch';apply={param($v)
        $v.decoded.endpoint_fifo.counters.flush_attempt=2
        $v.decoded.endpoint_fifo.counters.flush_abort_inferred=1
        $v.decoded.endpoint_fifo.last_flush_outcome='Abort'
        $v.decoded.endpoint_fifo.last_flush_outcome_code=4
        $v.decoded.endpoint_fifo.last_flush_terminal_blocker_mask=
          '0x00000000'
        $v.decoded.endpoint_fifo.last_flush_terminal_blocker_mask_code=0
        $v.decoded.endpoint_fifo.last_flush_terminal_blocker_names=@()
        $v.decoded.endpoint_fifo.last_flush_classification=
          'abort-without-terminal-blocker'}},
      [pscustomobject]@{name='active_plus_terminal_exceeds_attempt';apply={param($v)
        $v.decoded.endpoint_fifo.flags.flush_active=$true
        $v.decoded.endpoint_fifo.flags.mask='0x00000403'}},
      [pscustomobject]@{name='wrong_flush_abort_count';apply={param($v)
        $v.decoded.endpoint_fifo.counters.flush_abort_inferred=1}},
      [pscustomobject]@{name='address_alias';apply={param($v)
        $v.binding.endpoint_fifo_address=$v.binding.runtime_stage_address}}
    )) {
    $invalidStage = New-ValidStageV3Summary
    & $mutation.apply $invalidStage
    Write-StageSummary $invalidStage
    $invalidStageProof = Get-StageProof $stageStep 'vehicle' '0x3fcab480' `
        '1-4.2' $stageEvidenceDirectory
    Assert-Contract (-not[bool]$invalidStageProof.proven -and
        -not[bool]$invalidStageProof.usb_tx_boundary_completion_proven) `
        "reader-v3 proof accepted invalid evidence: $($mutation.name)"
  }

  # New v4 fixtures use all eight real byte records, unlike the retained
  # legacy-v3 JSON contract fixtures above. Reader decoder is a fixture oracle
  # only; the outer must independently replay those bytes without calling it.
  $readerTokens=$null;$readerErrors=$null
  $readerAst=[Management.Automation.Language.Parser]::ParseFile(
      $readerPath,[ref]$readerTokens,[ref]$readerErrors)
  foreach($variableName in @('stageRecordBytes','fifoRecordBytes','stageNames',
      'failureNames','fifoFlushOutcomeNames','fifoFlagNames','fifoFlushBlockerNames',
      'fifoBusResetInterruptMask')){
    $assignments=@($readerAst.FindAll({param($node)
      $node-is[Management.Automation.Language.AssignmentStatementAst]-and
        $node.Left.Extent.Text-ceq('$'+$variableName)},$true))
    Assert-Contract ($assignments.Count-eq1) "reader fixture variable $variableName"
    . ([scriptblock]::Create($assignments[0].Extent.Text))
  }
  foreach($functionName in @('Convert-Words','Decode-StableStageRecord',
      'Decode-StableFifoRecord','Decode-StableDiagnosticRecords',
      'Decode-ExtendedStableWords','Decode-ExtendedRestartState',
      'Decode-ExtendedRestartRecord','Decode-ExtendedCommitRecord')){
    $functions=@($readerAst.FindAll({param($node)
      $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
        $node.Name-ceq$functionName},$true))
    . ([scriptblock]::Create($functions[0].Extent.Text))
  }
  $fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo `
      'tests\arduino_compile\check_r19_usb_extended_records_reader_contract.ps1'),
      [ref]$readerTokens,[ref]$readerErrors)
  foreach($functionName in @('Pack-Words','New-Fixture','Set-Word','New-LatchedFixture')){
    $functions=@($fixtureAst.FindAll({param($node)
      $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
        $node.Name-ceq$functionName},$true))
    . ([scriptblock]::Create($functions[0].Extent.Text))
  }
  $extendedDirectory=Join-Path $tempRoot 'v4-eight-raw-live-json-validation'
  New-Item -ItemType Directory -Path $extendedDirectory|Out-Null
  $extendedSizes=[ordered]@{runtime_stage=68;endpoint_fifo=112
    hwcdc_restart=128;ground_usb_commit=128}
  $extendedSymbols=[ordered]@{runtime_stage='vc_lora_r19_runtime_stage_record'
    endpoint_fifo='vc_lora_r19_hwcdc_fifo_diagnostic_record'
    hwcdc_restart='vc_lora_r19_hwcdc_restart_diagnostic_record'
    ground_usb_commit='vc_lora_r19_ground_usb_commit_record'}
  $extendedLeaves=@{runtime_stage='runtime-stage';endpoint_fifo='endpoint-fifo'
    hwcdc_restart='hwcdc-restart';ground_usb_commit='ground-usb-commit'}
  $extendedManifestPath=Join-Path $extendedDirectory 'candidate_manifest.json'
  $savedCandidate=$candidate
  function New-ValidExtendedSummary {
    $fixture=New-LatchedFixture
    $raw=@{};$reads=@()
    foreach($sample in 1,2){
      foreach($name in $extendedSizes.Keys){
        $sampleName=if($sample-eq1){'first'}else{'second'}
        [byte[]]$bytes=[Convert]::FromBase64String(
            $fixture[$name+'_'+$sampleName+'_read_base64'])
        $path=Join-Path $extendedDirectory ($extendedLeaves[$name]+'-'+$sampleName+'.bin')
        [IO.File]::WriteAllBytes($path,$bytes);$raw[$name]=$bytes
        $reads+=@([pscustomobject]@{record=$name;sample=$sample
          size_bytes=$extendedSizes[$name];path=$path;sha256=Get-Sha256 $path})
      }
    }
    $decoded=Decode-StableDiagnosticRecords $raw.runtime_stage $raw.runtime_stage `
        $raw.endpoint_fifo $raw.endpoint_fifo 'ground'
    $decoded['hwcdc_restart']=Decode-ExtendedRestartRecord $raw.hwcdc_restart $raw.hwcdc_restart
    $decoded['ground_usb_commit']=Decode-ExtendedCommitRecord $raw.ground_usb_commit $raw.ground_usb_commit 'ground'
    $elfPath=Join-Path $extendedDirectory 'application.elf'
    $mapPath=Join-Path $extendedDirectory 'application.map'
    $appPath=Join-Path $extendedDirectory 'application.bin'
    [IO.File]::WriteAllBytes($elfPath,[byte[]]@(1,2,3,4))
    [IO.File]::WriteAllBytes($appPath,[byte[]]@(5,6,7,8))
    $mapLines=@(foreach($name in $extendedSizes.Keys){
      $fixture[$name+'_address']+' '+$extendedSymbols[$name]})
    [IO.File]::WriteAllText($mapPath,($mapLines-join[Environment]::NewLine),$utf8)
    $metadata=[ordered]@{schema='vc-lora-r19-runtime-diagnostic-symbols-v1'
      elf_sha256=(Get-Sha256 $elfPath);map_sha256=(Get-Sha256 $mapPath)
      application_sha256=(Get-Sha256 $appPath)
      symbols=[ordered]@{}}
    foreach($name in $extendedSizes.Keys){
      $metadata.symbols[$name]=[ordered]@{name=$extendedSymbols[$name]
        address=$fixture[$name+'_address'];size_bytes=$extendedSizes[$name]
        aligned_32_bit=$true}
    }
    $manifest=$validExtendedAbi|ConvertTo-Json -Depth 12|ConvertFrom-Json
    $manifest|Add-Member NoteProperty artifact_id $candidateArtifactId
    $manifest|Add-Member NoteProperty roles @([pscustomobject]@{
      role='ground';runtime_diagnostic_symbols=$metadata
      application=[pscustomobject]@{path='application.bin'
        sha256=$metadata.application_sha256}
      reproducibility_artifacts=[pscustomobject]@{files=@(
        [pscustomobject]@{path='application.elf';sha256=$metadata.elf_sha256},
        [pscustomobject]@{path='application.map';sha256=$metadata.map_sha256})}})
    [IO.File]::WriteAllText($extendedManifestPath,($manifest|ConvertTo-Json -Depth 15),$utf8)
    $script:extendedFixtureCandidate=[pscustomobject]@{artifact_id=$candidateArtifactId
      candidate_manifest_path=$extendedManifestPath
      candidate_manifest_sha256=Get-Sha256 $extendedManifestPath
      artifact_root=$extendedDirectory
      reader_schema='vc-lora-r19-runtime-stage-jtag-read-v4'}
    $flashPath=Join-Path $extendedDirectory 'flash_record.json'
    $flashRole=[pscustomobject]@{role='ground';port='COM6'
      pnp_device_id='USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000'
      parent_device_id='USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80'
      mac='1c:db:d4:5a:83:80';sha256=$metadata.application_sha256
      write_pass=$true;verify_pass=$true;reenumeration_pass=$true}
    $flash=[pscustomobject]@{schema='vc-lora-r19-candidate-flash-evidence-v1'
      result='PASS';status='PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY'
      candidate=[pscustomobject]@{artifact_id=$candidateArtifactId}
      roles=@($flashRole)}
    [IO.File]::WriteAllText($flashPath,($flash|ConvertTo-Json -Depth 12),$utf8)
    $summary=New-ValidStageV3Summary
    $summary.schema='vc-lora-r19-runtime-stage-jtag-read-v4'
    $summary.safety|Add-Member NoteProperty halted_for_reads $true
    $summary.safety|Add-Member NoteProperty capture_process_termination_proven $true
    $summary.binding.role='ground';$summary.binding.address=$fixture.runtime_stage_address
    $summary.binding.runtime_stage_address=$fixture.runtime_stage_address
    $summary.binding.endpoint_fifo_address=$fixture.endpoint_fifo_address
    foreach($name in @('hwcdc_restart','ground_usb_commit')){
      $summary.binding|Add-Member NoteProperty ($name+'_address') $fixture[$name+'_address']
    }
    $summary.binding.probe.requested_usb_location='1-4.4'
    $summary.binding.probe|Add-Member NoteProperty requested_serial '1C:DB:D4:5A:83:80'
    $summary.binding.probe|Add-Member NoteProperty opened_serial '1c:db:d4:5a:83:80'
    $summary.binding.probe|Add-Member NoteProperty opened_usb_location '1-4.4'
    $summary.binding|Add-Member NoteProperty artifact ([pscustomobject]@{
      extended_records_enabled=$true;extended_record_metadata=$metadata
      root=$extendedDirectory;artifact_id=$candidateArtifactId;role='ground'
      manifest_path=$extendedManifestPath
      manifest_sha256=$script:extendedFixtureCandidate.candidate_manifest_sha256
      elf_path=$elfPath;elf_sha256=$metadata.elf_sha256
      map_path=$mapPath;map_sha256=$metadata.map_sha256
      application_sha256=$metadata.application_sha256
      symbols=$metadata.symbols})
    $summary.binding|Add-Member NoteProperty flash ([pscustomobject]@{
      path=$flashPath;sha256=(Get-Sha256 $flashPath);role='ground';port='COM6'
      pnp_device_id=$flashRole.pnp_device_id;parent_device_id=$flashRole.parent_device_id
      probe_serial=$flashRole.mac;application_sha256=$metadata.application_sha256})
    $summary.reads=$reads;$summary.decoded=$decoded
    $summary|ConvertTo-Json -Depth 24|ConvertFrom-Json
  }
  function Get-ExtendedProof([object]$Summary){
    $candidate=$script:extendedFixtureCandidate
    $flashRecordPath=Join-Path $extendedDirectory 'flash_record.json'
    $stageStep=[pscustomobject]@{exit_code=0;timed_out=$false
      termination_proven=$true;process_tree_termination_proven=$true}
    [IO.File]::WriteAllText((Join-Path $extendedDirectory 'summary.json'),
        ($Summary|ConvertTo-Json -Depth 24),$utf8)
    Get-StageProof $stageStep 'ground' '0x3fcab000' '1-4.4' $extendedDirectory
  }
  $extendedSummary=New-ValidExtendedSummary
  $extendedProof=Get-ExtendedProof $extendedSummary
  Assert-Contract ([bool]$extendedProof.proven-and
      [bool]$extendedProof.extended_raw_replay.proven-and
      [int]$extendedProof.extended_raw_replay.raw_read_count-eq8-and
      [string]$extendedProof.extended_raw_replay.first_heartbeat_reason-ceq
        'PublicationRejected'-and
      @($extendedProof.extended_raw_replay.first_heartbeat_failed_predicates).Count-eq1-and
      [string]$extendedProof.extended_raw_replay.first_heartbeat_failed_predicates[0]-ceq
        'transport_published'-and
      [string]$extendedProof.extended_raw_replay.restart_classification-ceq
        'restart-payload-published-host-pickup-not-proven') `
      ('valid v4 eight-raw proof or cause classification was rejected: '+
        ($extendedProof|ConvertTo-Json -Depth 12 -Compress))
  function Set-ExtendedFifoWords([object]$Summary,[object[]]$Changes){
    foreach($read in @($Summary.reads|Where-Object{$_.record-ceq'endpoint_fifo'})){
      [byte[]]$bytes=[IO.File]::ReadAllBytes([string]$read.path)
      foreach($change in $Changes){
        [BitConverter]::GetBytes([uint32]$change[1]).CopyTo($bytes,4*[int]$change[0])
      }
      [IO.File]::WriteAllBytes([string]$read.path,$bytes)
      $read.sha256=Get-Sha256 ([string]$read.path)
    }
    $Summary.decoded.endpoint_fifo=(Decode-StableFifoRecord $bytes $bytes|
      ConvertTo-Json -Depth 16|ConvertFrom-Json)
    $Summary.decoded.endpoint_fifo.boundary_classification='usb-tx-boundary-complete'
    $Summary.decoded.endpoint_fifo.usb_tx_boundary_completion_proven=$true
    $Summary.decoded.usb_tx_boundary_classification='usb-tx-boundary-complete'
    $Summary.decoded.usb_tx_boundary_completion_proven=$true
  }
  foreach($forgery in @(
      @{name='blocked';changes=@(,@(23,4))},
      @{name='debug_writer';changes=@(,@(4,527))},
      @{name='quarantined';changes=@(,@(4,47))},
      @{name='reset_pending';changes=@(,@(4,79))},
      @{name='last_busreset';changes=@(@(22,512),@(15,1))},
      @{name='timeout';changes=@(@(17,0),@(18,2),@(24,3),@(27,4))}
    )){
    $s=New-ValidExtendedSummary
    Set-ExtendedFifoWords $s $forgery.changes
    Assert-Contract (-not[bool](Get-ExtendedProof $s).proven) `
        "v4 forged USB complete accepted for raw $($forgery.name)"
  }
  foreach($mutation in @(
      @{name='string_cleanup_bool';apply={param($s)$s.safety.resume_shutdown_cleanup_proven='false'}},
      @{name='capture_process_unproven';apply={param($s)$s.safety.capture_process_termination_proven=$false}},
      @{name='halt_not_proven';apply={param($s)$s.safety.halted_for_reads=$false}},
      @{name='string_usb_complete_bool';apply={param($s)$s.decoded.usb_tx_boundary_completion_proven='false'}},
      @{name='string_operational_bool';apply={param($s)$s.decoded.endpoint_fifo.flags.connected='false'}},
      @{name='string_predicate_bool';apply={param($s)$s.decoded.ground_usb_commit.predicates.endpoint_ready.value='true'}},
      @{name='wrong_runtime_boundary';apply={param($s)$s.decoded.boundary_classification='record-initialized-without-setup-witness'}},
      @{name='wrong_runtime_last_stage';apply={param($s)$s.decoded.last_reached_stage='None'}},
      @{name='wrong_runtime_failure_name';apply={param($s)$s.decoded.first_failure.name='FlushFailed'}},
      @{name='missing_raw';apply={param($s)$s.reads=@($s.reads|Select-Object -First 7)}},
      @{name='wrong_schema';apply={param($s)$s.schema='vc-lora-r19-runtime-stage-jtag-read-v3'}},
      @{name='wrong_opened_serial';apply={param($s)$s.binding.probe.opened_serial='AA:BB:CC:DD:EE:FF'}},
      @{name='wrong_opened_location';apply={param($s)$s.binding.probe.opened_usb_location='1-4.2'}},
      @{name='wrong_flash_pnp';apply={param($s)$s.binding.flash.pnp_device_id='OTHER'}},
      @{name='wrong_flash_parent';apply={param($s)$s.binding.flash.parent_device_id='OTHER'}},
      @{name='wrong_flash_sha';apply={param($s)$s.binding.flash.sha256=('D'*64)}},
      @{name='wrong_flash_role';apply={param($s)$s.binding.flash.role='vehicle'}},
      @{name='wrong_artifact_root';apply={param($s)$s.binding.artifact.root='C:\other'}},
      @{name='wrong_extension_address';apply={param($s)$s.binding.hwcdc_restart_address='0x3fcab204'}},
      @{name='wrong_sealed_hash';apply={param($s)$s.binding.artifact.extended_record_metadata.map_sha256=('D'*64)}},
      @{name='wrong_symbol_schema';apply={param($s)$s.binding.artifact.extended_record_metadata.schema='v2'}},
      @{name='wrong_symbol_size';apply={param($s)$s.binding.artifact.symbols.ground_usb_commit.size_bytes=124}},
      @{name='missing_cleanup';apply={param($s)$s.safety.resume_shutdown_cleanup_proven=$false}},
      @{name='changed_runtime_decoded';apply={param($s)$s.decoded.counters.loop++}},
      @{name='changed_fifo_decoded';apply={param($s)$s.decoded.endpoint_fifo.pending_bytes.ring=31}},
      @{name='changed_restart_decoded';apply={param($s)$s.decoded.hwcdc_restart.latest.written_bytes=30}},
      @{name='changed_commit_predicate';apply={param($s)$s.decoded.ground_usb_commit.predicates.transport_published.value=$true}}
    )){
    $s=New-ValidExtendedSummary;& $mutation.apply $s
    Assert-Contract (-not[bool](Get-ExtendedProof $s).proven) `
        "v4 mutation accepted: $($mutation.name)"
  }
  for($readIndex=0;$readIndex-lt8;++$readIndex){
    $s=New-ValidExtendedSummary;$read=$s.reads[$readIndex]
    [byte[]]$bytes=[IO.File]::ReadAllBytes([string]$read.path);$bytes[0]=1
    [IO.File]::WriteAllBytes([string]$read.path,$bytes)
    $read.sha256=Get-Sha256 ([string]$read.path)
    Assert-Contract (-not[bool](Get-ExtendedProof $s).proven) `
        "v4 rehashed raw mutation accepted at sample $readIndex"
  }
  foreach($runtimeMutation in @(
      @{name='unknown_failure_domain';word=14;value=[uint32]0x12340001
        field='code';text='0x12340001'},
      @{name='unknown_failure_reason';word=14;value=[uint32]0x545200ff
        field='code';text='0x545200ff'},
      @{name='detail_without_failure';word=16;value=[uint32]1
        field='detail';text=1}
    )){
    $s=New-ValidExtendedSummary
    foreach($read in @($s.reads|Where-Object{$_.record-ceq'runtime_stage'})){
      [byte[]]$bytes=[IO.File]::ReadAllBytes([string]$read.path)
      [BitConverter]::GetBytes([uint32]$runtimeMutation.value).CopyTo(
          $bytes,4*[int]$runtimeMutation.word)
      [IO.File]::WriteAllBytes([string]$read.path,$bytes)
      $read.sha256=Get-Sha256 ([string]$read.path)
    }
    $s.decoded.first_failure.($runtimeMutation.field)=$runtimeMutation.text
    Assert-Contract (-not[bool](Get-ExtendedProof $s).proven) `
        "v4 raw runtime invalid failure accepted: $($runtimeMutation.name)"
  }
  $candidate=$savedCandidate

  $pnpOnlyEvidenceDirectory=Join-Path $tempRoot `
      'pnp-only-live-json-validation'
  New-Item -ItemType Directory -Path $pnpOnlyEvidenceDirectory | Out-Null
  $pnpOnlySummaryPath=Join-Path $pnpOnlyEvidenceDirectory 'summary.json'
  $pnpOnlyStep=[pscustomobject]@{exit_code=1}
  function New-ValidPnpOnlySummary {
    [pscustomobject][ordered]@{
      schema='vc-lora-r19-jtag-preflash-gate-v1'
      result='PASS';status='PASS_WINUSB_DRIVER_BINDING_PNP_ONLY'
      mode='LIVE_PNP_ONLY';hardware_interaction=$false;fail_closed=$true
      safety=[pscustomobject][ordered]@{
        com_opened=$false;flash_written=$false
        target_config_loaded=$false;target_halt_or_reset_issued=$false
        target_state_modified=$false;device_opened=$false
        jtag_clocks_issued=$false;tap_reset_issued=$false
        openocd_invoked=$false;reader_preflight_invoked=$false
        active_jtag_proven=$false;firmware_install_allowed=$false
      }
      toolchain=[pscustomobject][ordered]@{
        policy='PNP_ONLY_OPENOCD_AND_READER_NOT_INVOKED'
        openocd_invoked=$false;reader_invoked=$false
      }
      roles=@(
        [pscustomobject][ordered]@{
          role='vehicle';com='COM3';serial='90:70:69:11:81:A4'
          pnp_port_chain='4.2';driver_binding_proven=$true
          interface_registration_proven=$true;openocd_usb_location=''
          reader_preflight_proven=$false
        },
        [pscustomobject][ordered]@{
          role='ground';com='COM6';serial='1C:DB:D4:5A:83:80'
          pnp_port_chain='4.4';driver_binding_proven=$true
          interface_registration_proven=$true;openocd_usb_location=''
          reader_preflight_proven=$false
        }
      )
    }
  }
  function Write-PnpOnlySummary([object]$Value) {
    [IO.File]::WriteAllText($pnpOnlySummaryPath,
        ($Value|ConvertTo-Json -Depth 12),$utf8)
  }
  $validPnpOnlySummary=New-ValidPnpOnlySummary
  Write-PnpOnlySummary $validPnpOnlySummary
  $validPnpOnlyProof=Get-JtagPreflightProof $pnpOnlyStep `
      $pnpOnlyEvidenceDirectory
  Assert-Contract ([bool]$validPnpOnlyProof.driver_binding_proven -and
      -not[bool]$validPnpOnlyProof.proven -and
      -not[bool]$validPnpOnlyProof.firmware_install_allowed -and
      @($validPnpOnlyProof.roles).Count-eq2) `
      'strict valid live PnP-only summary was rejected or authorized flash'

  $pnpOnlyMutations=@(
    [pscustomobject]@{name='third_extra_role';apply={param($s)
      $s.roles=@($s.roles)+[pscustomobject][ordered]@{
        role='observer';com='COM9';serial='AA:BB:CC:DD:EE:FF'
        pnp_port_chain='4.6';driver_binding_proven=$true
        interface_registration_proven=$true;openocd_usb_location=''
        reader_preflight_proven=$false}}},
    [pscustomobject]@{name='duplicate_port_chain';apply={param($s)
      $s.roles[1].pnp_port_chain='4.2'}},
    [pscustomobject]@{name='wrong_status';apply={param($s)
      $s.status='PASS_ACTIVE_JTAG'}},
    [pscustomobject]@{name='wrong_mode';apply={param($s)
      $s.mode='LIVE_JTAG'}},
    [pscustomobject]@{name='hardware_interaction';apply={param($s)
      $s.hardware_interaction=$true}},
    [pscustomobject]@{name='role_identity_mismatch';apply={param($s)
      $s.roles[0].serial='90:70:69:11:81:A5'}}
  )
  foreach($mutation in $pnpOnlyMutations){
    $mutatedPnpOnlySummary=New-ValidPnpOnlySummary
    & $mutation.apply $mutatedPnpOnlySummary
    Write-PnpOnlySummary $mutatedPnpOnlySummary
    $mutatedPnpOnlyProof=Get-JtagPreflightProof $pnpOnlyStep `
        $pnpOnlyEvidenceDirectory
    Assert-Contract (-not[bool]$mutatedPnpOnlyProof.driver_binding_proven-and
        -not[bool]$mutatedPnpOnlyProof.proven-and
        -not[bool]$mutatedPnpOnlyProof.firmware_install_allowed) `
        "live PnP-only JSON validation accepted mutation: $($mutation.name)"
  }

  $activeJtagEvidenceDirectory = Join-Path $tempRoot `
      'active-jtag-live-json-validation'
  New-Item -ItemType Directory -Path $activeJtagEvidenceDirectory |
      Out-Null
  $activeJtagSummaryPath = Join-Path $activeJtagEvidenceDirectory `
      'summary.json'
  $activeJtagStep = [pscustomobject]@{
    exit_code=0;process_tree_termination_proven=$true
  }
  function New-ValidActiveJtagPreflightSummary {
    [pscustomobject][ordered]@{
      schema='vc-lora-r19-jtag-preflight-v1'
      result='PASS'
      status=
        'PASS_JTAG_PREFLIGHT_TAP_RESET_SCAN_POSSIBLE_NO_CPU_HALT_OR_SYSTEM_RESET_COMMAND'
      mode='live-jtag-preflight'
      hardware_interaction=$true
      binding=[pscustomobject][ordered]@{
        role='vehicle'
        requested_serial='90:70:69:11:81:a4'
        requested_usb_location='1-4.2'
        opened_serial='90:70:69:11:81:a4'
        opened_usb_location='1-4.2'
      }
      safety=[pscustomobject][ordered]@{
        com_opened=$false;flash_written=$false
        target_config_loaded=$false;cpu_halt_command_issued=$false
        system_reset_command_issued=$false
        transport_init_requested=$true
        transport_init_completion_proven=$true
        jtag_clock_activity_possible=$true;tap_reset_or_scan_possible=$true
        target_state_modified=$null;target_state_modification_known=$false
        process_termination_proven=$true;shutdown_proven=$true
      }
      native=[pscustomobject][ordered]@{
        exit_code=0;timed_out=$false;termination_proven=$true
      }
    }
  }
  function Write-ActiveJtagPreflightSummary([object]$Value) {
    [IO.File]::WriteAllText($activeJtagSummaryPath,
        ($Value|ConvertTo-Json -Depth 12),$utf8)
  }
  function Get-VehicleActiveJtagProof {
    Get-ActiveJtagPreflightProof $activeJtagStep 'vehicle' `
        '90:70:69:11:81:A4' '1-4.2' '4.2' `
        $activeJtagEvidenceDirectory
  }

  $validActiveJtagSummary=New-ValidActiveJtagPreflightSummary
  Write-ActiveJtagPreflightSummary $validActiveJtagSummary
  $validActiveJtagProof=Get-VehicleActiveJtagProof
  Assert-Contract ([bool]$validActiveJtagProof.proven -and
      [string]$validActiveJtagProof.role-ceq'vehicle' -and
      [string]$validActiveJtagProof.opened_serial-ceq
        '90:70:69:11:81:a4' -and
      [string]$validActiveJtagProof.opened_usb_location-ceq'1-4.2' -and
      [bool]$validActiveJtagProof.safety.process_termination_proven -and
      [bool]$validActiveJtagProof.safety.shutdown_proven) `
      'strict valid live active-JTAG preflight summary was rejected'

  $activeJtagMutations=@(
    [pscustomobject]@{name='wrong_schema';apply={param($s)
      $s.schema='wrong-schema'}},
    [pscustomobject]@{name='wrong_status';apply={param($s)
      $s.status='PASS_JTAG_PREFLIGHT_NO_RESET_NO_HALT'}},
    [pscustomobject]@{name='wrong_opened_serial';apply={param($s)
      $s.binding.opened_serial='1c:db:d4:5a:83:80'}},
    [pscustomobject]@{name='wrong_opened_location';apply={param($s)
      $s.binding.opened_usb_location='1-4.4'}},
    [pscustomobject]@{name='process_termination_unproven';apply={param($s)
      $s.safety.process_termination_proven=$false}},
    [pscustomobject]@{name='shutdown_unproven';apply={param($s)
      $s.safety.shutdown_proven=$false}}
  )
  foreach($mutation in $activeJtagMutations){
    $mutatedActiveJtagSummary=New-ValidActiveJtagPreflightSummary
    & $mutation.apply $mutatedActiveJtagSummary
    Write-ActiveJtagPreflightSummary $mutatedActiveJtagSummary
    $mutatedActiveJtagProof=Get-VehicleActiveJtagProof
    Assert-Contract (-not[bool]$mutatedActiveJtagProof.proven) `
        "live active-JTAG JSON validation accepted mutation: $($mutation.name)"
  }

  $readerStyleFailedActiveJtagSummary=[pscustomobject][ordered]@{
    schema='vc-lora-r19-jtag-preflight-v1'
    result='FAIL';status='FAIL_JTAG_PREFLIGHT'
    mode='live-jtag-preflight';hardware_interaction=$true
    binding=[pscustomobject][ordered]@{
      role='vehicle'
      requested_serial='90:70:69:11:81:a4'
      requested_usb_location='1-4.2'
    }
    safety=[pscustomobject][ordered]@{
      com_opened=$false;flash_written=$false
      target_config_loaded=$false;cpu_halt_command_issued=$false
      system_reset_command_issued=$false
      transport_init_requested=$true
      transport_init_completion_proven=$false
      jtag_clock_activity_possible=$true;tap_reset_or_scan_possible=$true
      target_state_modified=$null;target_state_modification_known=$false
      process_termination_proven=$true;shutdown_proven=$true
    }
    native=[pscustomobject][ordered]@{
      exit_code=1;timed_out=$false;termination_proven=$true
    }
    error='synthetic reader-style active preflight failure'
    fail_closed=$true
  }
  $readerStyleFailedStep=[pscustomobject]@{
    exit_code=1;process_tree_termination_proven=$true
    hardware_interaction=$true
  }
  Write-ActiveJtagPreflightSummary $readerStyleFailedActiveJtagSummary
  $readerStyleFailedProof=Get-ActiveJtagPreflightProof `
      $readerStyleFailedStep 'vehicle' '90:70:69:11:81:A4' `
      '1-4.2' '4.2' $activeJtagEvidenceDirectory
  Assert-Contract (-not[bool]$readerStyleFailedProof.proven -and
      [bool]$readerStyleFailedProof.hardware_interaction -and
      [bool]$readerStyleFailedProof.safety.process_termination_proven -and
      [bool]$readerStyleFailedProof.safety.shutdown_proven -and
      [string]$readerStyleFailedProof.opened_serial-ceq'' -and
      [string]$readerStyleFailedProof.opened_usb_location-ceq'') `
      'reader-style failed active preflight collapsed preserved cleanup evidence under StrictMode'

  $readerStyleFailedActiveJtagSummary.safety.shutdown_proven=$false
  Write-ActiveJtagPreflightSummary $readerStyleFailedActiveJtagSummary
  $readerStyleShutdownUnproven=Get-ActiveJtagPreflightProof `
      $readerStyleFailedStep 'vehicle' '90:70:69:11:81:A4' `
      '1-4.2' '4.2' $activeJtagEvidenceDirectory
  Assert-Contract (-not[bool]$readerStyleShutdownUnproven.proven -and
      [bool]$readerStyleShutdownUnproven.hardware_interaction -and
      [bool]$readerStyleShutdownUnproven.safety.process_termination_proven -and
      -not[bool]$readerStyleShutdownUnproven.safety.shutdown_proven) `
      'reader-style failed active preflight did not preserve shutdown=false'

  [IO.File]::Delete($activeJtagSummaryPath)
  $missingActiveJtagSummaryProof=Get-ActiveJtagPreflightProof `
      $readerStyleFailedStep 'vehicle' '90:70:69:11:81:A4' `
      '1-4.2' '4.2' $activeJtagEvidenceDirectory
  Assert-Contract (-not[bool]$missingActiveJtagSummaryProof.proven -and
      [bool]$missingActiveJtagSummaryProof.hardware_interaction -and
      -not[bool]$missingActiveJtagSummaryProof.safety.process_termination_proven -and
      -not[bool]$missingActiveJtagSummaryProof.safety.shutdown_proven) `
      'missing active-preflight live summary erased known hardware interaction or invented cleanup proof'

  [IO.File]::WriteAllText($activeJtagSummaryPath,
      '{corrupt-active-jtag-json',$utf8)
  $corruptActiveJtagSummaryProof=Get-ActiveJtagPreflightProof `
      $readerStyleFailedStep 'vehicle' '90:70:69:11:81:A4' `
      '1-4.2' '4.2' $activeJtagEvidenceDirectory
  Assert-Contract (-not[bool]$corruptActiveJtagSummaryProof.proven -and
      [bool]$corruptActiveJtagSummaryProof.hardware_interaction -and
      -not[bool]$corruptActiveJtagSummaryProof.safety.process_termination_proven -and
      -not[bool]$corruptActiveJtagSummaryProof.safety.shutdown_proven) `
      'corrupt active-preflight live summary erased known hardware interaction or invented cleanup proof'

  # Immutable historical captures must remain bound to their original 3880
  # firmware/source manifest. Never relabel those bytes as a fresh candidate.
  $currentCandidateContext=[ordered]@{artifact_id=$candidateArtifactId
    latest_sha256=$candidateLatestSha256;latest=$candidateLatest
    artifact_root=$candidateArtifactRoot;manifest_path=$candidateManifestPath}
  $candidateArtifactId='20261012T151448091Z-3880c286'
  $candidateLatestSha256='41FA55658E49A21F4A32FE3A142CD73AD65D30DAC2DE2B15A9AF6EEAC899AA9D'
  $candidateArtifactRoot=Join-Path $repo ('runs\candidates\'+
      'R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001\'+$candidateArtifactId)
  $candidateManifestPath=Join-Path $candidateArtifactRoot 'candidate_manifest.json'
  $legacyManifestSha='80B15BD49B1FD4395D36EC111A58B056F62AA7731DA1DDB4F1CEEC7E2AC0C253'
  $legacyHandoffSha='E6EA26F4E65886C1807DCC906C74D982E9D3AED385A5DD8CF5475AF1FB6336D3'
  Assert-Contract ((Get-Sha256 $candidateManifestPath)-ceq$legacyManifestSha-and
      (Get-Sha256 (Join-Path $candidateArtifactRoot 'handoff.json'))-ceq$legacyHandoffSha) `
      'immutable legacy 3880 replay identity changed'
  $candidateLatest=[pscustomobject]@{
    handoff=[pscustomobject]@{sha256=$legacyHandoffSha}
    candidate_manifest=[pscustomobject]@{sha256=$legacyManifestSha}}
  $candidate = [pscustomobject]@{
    artifact_id = $candidateArtifactId
    latest_sha256 = $candidateLatestSha256
    handoff_sha256 = [string]$candidateLatest.handoff.sha256
    artifact_root = $candidateArtifactRoot
    candidate_manifest_path = $candidateManifestPath
    candidate_manifest_sha256 = [string]$candidateLatest.candidate_manifest.sha256
  }
  $flashRecordPath = Join-Path $tempRoot 'installed-flash-record.json'
  $expectedCaptureToolSha256 = ('C' * 64)
  [IO.File]::WriteAllText($flashRecordPath,'{"result":"PASS"}',$utf8)
  $captureDirectory = Join-Path $tempRoot 'capture-disposition'
  New-Item -ItemType Directory -Path $captureDirectory | Out-Null
  $captureSummaryPath = Join-Path $captureDirectory 'summary.json'
  $utf8ProbePath = Join-Path $tempRoot 'utf8-probe.json'
  [IO.File]::WriteAllText($utf8ProbePath,
      '{"message":"診断メッセージ"}',$utf8)
  $utf8Probe = Read-JsonIfPresent $utf8ProbePath
  Assert-Contract ([string]$utf8Probe.message -ceq '診断メッセージ') `
      'Read-JsonIfPresent did not preserve explicit UTF-8 JSON text'

  function New-ValidCaptureSummary {
    [pscustomobject][ordered]@{
      schema='vc-lora-r19-runtime-fail-diagnostic-summary-v1'
      test_id='R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001'
      result='PASS';mode='LIVE_DIAGNOSTIC_ONLY';hardware_interaction=$true
      diagnostic_status='PASS_ALIVE_BEACON_CAPTURED'
      diagnostic_classification='ALIVE_WITH_PRODUCT_TRAFFIC'
      diagnostic_only=$true;acceptance_eligible=$false
      acceptance_authorized=$false;deployment_authorized=$false
      serial_write_calls=0;capture_seconds=40
      pump_service_limit_us=100000
      parser_clean=$true;alive_sequence_time_monotonic=$true
      r19f_repeat_contract=[pscustomobject]@{valid=$true}
      invalid_diagnostic_count=0
      ports=@(
        [pscustomobject]@{role='vehicle';maximum_service_gap_us=50000
          parser_clean=$true},
        [pscustomobject]@{role='ground';maximum_service_gap_us=60000
          parser_clean=$true})
      cleanup=[pscustomobject]@{result='PASS';errors=@()}
      external_actions=[pscustomobject]@{com_ports_opened=$true
        serial_write_attempted=$false;firmware_write_attempted=$false
        e220_write_attempted=$false}
      runner_integrity=[pscustomobject]@{result='PASS'
        start_sha256=('C'*64);end_sha256=('C'*64)}
      candidate_provenance=[pscustomobject]@{
        runtime_fail_diagnostics_enabled=$true
        acceptance_eligible=$false;acceptance_authorized=$false
        deployment_authorized=$false;flash_readback_verified=$true
        artifact_id=$candidateArtifactId
        latest_sha256=$candidateLatestSha256
        handoff_sha256=[string]$candidateLatest.handoff.sha256
        flash_record_path=$flashRecordPath
        flash_record_sha256=Get-Sha256 $flashRecordPath
        diagnostic_flash_status='PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY'}
    }
  }
  function New-TerminalPrefixStallCaptureSummary {
    $capture=New-ValidCaptureSummary
    $capture.result='FAIL'
    $capture.diagnostic_classification='R19F_TERMINAL_PREFIX_STALL'
    $capture.diagnostic_status='FAIL_R19F_TERMINAL_PREFIX_STALL'
    $capture.parser_clean=$false
    $capture.ports[0] | Add-Member -NotePropertyName noise_bytes `
        -NotePropertyValue 0
    $capture.ports[0] | Add-Member -NotePropertyName partial_bytes `
        -NotePropertyValue 0
    $capture.ports[0] | Add-Member -NotePropertyName bad_crc `
        -NotePropertyValue 0
    $capture.ports[0] | Add-Member -NotePropertyName bad_length `
        -NotePropertyValue 0
    $capture.ports[0] | Add-Member -NotePropertyName unsupported_flags `
        -NotePropertyValue 0
    $capture.ports[0] | Add-Member -NotePropertyName unknown_definition `
        -NotePropertyValue 0
    $capture.ports[0] | Add-Member -NotePropertyName port `
        -NotePropertyValue 'COM3'
    $capture.ports[0] | Add-Member -NotePropertyName raw_bytes `
        -NotePropertyValue 2646
    $capture.ports[1].parser_clean=$false
    $capture.ports[1] | Add-Member -NotePropertyName noise_bytes `
        -NotePropertyValue 0
    $capture.ports[1] | Add-Member -NotePropertyName partial_bytes `
        -NotePropertyValue 32
    $capture.ports[1] | Add-Member -NotePropertyName bad_crc `
        -NotePropertyValue 0
    $capture.ports[1] | Add-Member -NotePropertyName bad_length `
        -NotePropertyValue 0
    $capture.ports[1] | Add-Member -NotePropertyName unsupported_flags `
        -NotePropertyValue 0
    $capture.ports[1] | Add-Member -NotePropertyName unknown_definition `
        -NotePropertyValue 0
    $capture.ports[1] | Add-Member -NotePropertyName port `
        -NotePropertyValue 'COM6'
    $capture.ports[1] | Add-Member -NotePropertyName raw_bytes `
        -NotePropertyValue 662
    $capture | Add-Member -NotePropertyName terminal_partial_contract `
        -NotePropertyValue ([pscustomobject][ordered]@{
      valid=$true;one_role_only=$true;only_parser_defect=$true
      role='ground';port='COM6';prior_r19f_count=10;attempted_port_count=1
      drain_attempted=$true;drain_completed=$false
      result='TIMEOUT_INCOMPLETE_SAME_FRAME'
      no_read_exception=$true;read_exception=''
      started_frame=$true;header_known=$true;expected_size=63
      observed=32;remaining=31;partial_bytes=32
      raw_offset=630;raw_suffix_exact=$true
      terminal_offset_plus_length_equals_raw_bytes=$true
      all_other_parser_counters_zero=$true
      raw_bytes=662;exact_tail_bytes_required=31;exact_tail_bytes_read=0
      prefix_is_source_bound_r19f=$true;role_matches_port=$true
      source_binding_verified=$true;mavlink_sequence=11
      expected_next_sequence=11;sequence_matches_next=$true
      expected_frame_available=$true
      byte_exact_expected_next_r19f_prefix=$true
      failure_snapshot_matches_previous=$true
      ports=@(
        [pscustomobject]@{role='vehicle';port='COM3';attempted=$false
          result='NOT_REQUIRED';tail_drain=[pscustomobject]@{
            drain_attempted=$false}},
        [pscustomobject]@{role='ground';port='COM6';attempted=$true
          result='TIMEOUT_INCOMPLETE_SAME_FRAME';tail_drain=[pscustomobject]@{
            drain_attempted=$true}})
    })
    $capture
  }
  function Write-CaptureSummary([object]$Value) {
    [IO.File]::WriteAllText($captureSummaryPath,
        ($Value|ConvertTo-Json -Depth 15),$utf8)
  }
  # Immutable hardware bytes are replayed here; identity rows are explicitly
  # synthetic offline fixtures, not retroactive proof of the old live capture.
  $recordedCaptureDirectory=Join-Path $repo ('runs\hil\'+
      'R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001\'+
      '20261018T161748244Z-13604e50\capture')
  Assert-Contract ((Get-Sha256 (Join-Path $recordedCaptureDirectory `
      'ground.raw.bin'))-ceq
      '889DCA240FA7424DF7B7E489D96161E283A08BEF1A9ECCB25E9C715329741136'-and
      (Get-Sha256 (Join-Path $recordedCaptureDirectory 'vehicle.raw.bin'))-ceq
      '80EFBFE58C76B4D3237EA88C35F71F9DC465C9B0667F9224B2D71D17352F3E3F') `
      'recorded raw bytes for outer cause-admission replay changed'
  function New-AliveTerminalPrefixStallCaptureSummary {
    $capture=Get-Content -LiteralPath (Join-Path $recordedCaptureDirectory `
        'summary.json') -Raw | ConvertFrom-Json
    $capture.result='FAIL'
    $capture.diagnostic_classification='R19A_TERMINAL_PREFIX_STALL'
    $capture.diagnostic_status='FAIL_R19A_TERMINAL_PREFIX_STALL'
    $capture.runner_integrity.start_sha256=('C'*64)
    $capture.runner_integrity.end_sha256=('C'*64)
    $capture.candidate_provenance.latest_sha256=$candidateLatestSha256
    $capture.candidate_provenance.handoff_sha256=
        [string]$candidateLatest.handoff.sha256
    $capture.candidate_provenance.flash_record_path=$flashRecordPath
    $capture.candidate_provenance.flash_record_sha256=Get-Sha256 $flashRecordPath
    $identities=@()
    foreach($role in @('vehicle','ground')){
      Copy-Item -LiteralPath (Join-Path $recordedCaptureDirectory `
          ($role+'.raw.bin')) -Destination (Join-Path $captureDirectory `
          ($role+'.raw.bin')) -Force
      $row=@($capture.ports|Where-Object{$_.role-ceq$role})[0]
      $row | Add-Member -NotePropertyName raw_sha256 -NotePropertyValue (
          Get-Sha256 (Join-Path $captureDirectory ($role+'.raw.bin')))
      $isGround=$role-ceq'ground'
      foreach($checkpoint in @('before_open','after_open')){
        $identities+=,[pscustomobject]@{role=$role
          port=if($isGround){'COM6'}else{'COM3'};checkpoint=$checkpoint
          pnp=if($isGround){'USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000'}else{
            'USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000'}
          parent=if($isGround){'USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80'}else{
            'USB\VID_303A&PID_1001\90:70:69:11:81:A4'}
          result='PASS';offline_fixture=$true}
      }
    }
    $capture.external_actions | Add-Member -NotePropertyName `
        port_identity_evidence -NotePropertyValue $identities
    $ground=@($capture.ports|Where-Object{$_.role-ceq'ground'})[0]
    $source=@($capture.candidate_provenance.source_bindings|Where-Object{
        $_.role-ceq'ground'})[0]
    [byte[]]$raw=[IO.File]::ReadAllBytes((Join-Path $captureDirectory `
        'ground.raw.bin'))
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$prefixSha=([BitConverter]::ToString($sha.ComputeHash(
        [byte[]]$raw[777..808]))).Replace('-','')}finally{$sha.Dispose()}
    $capture | Add-Member -NotePropertyName r19a_terminal_partial_contract `
        -NotePropertyValue ([pscustomobject][ordered]@{
      schema='vc-lora-r19a-terminal-partial-cause-contract-v1'
      valid=$true;fail_only=$true;reconstruction_performed=$false
      missing_crc_verified=$false;role='ground';port='COM6'
      expected_size=63;partial_bytes=32;raw_offset=777;raw_bytes=809
      raw_sha256=[string]$ground.raw_sha256;prefix_sha256=$prefixSha
      prior_alive_count=10;prior_alive_contiguous=$true
      prior_complete_frames_crc_valid=$true;prior_source_binding_verified=$true
      next_sequence=12;next_ordinal=12;prefix_identity_valid=$true
      prefix_next_identity_valid=$true;drain_attempted=$true
      drain_completed=$false;result='TIMEOUT_INCOMPLETE_SAME_FRAME'
      bytes_read=0;remaining=31;no_read_exception=$true
      no_progress_us=[int64]$ground.tail_drain.deadline_us-
          [int64]$ground.tail_drain.last_progress_us
      only_parser_defect=$true;source_path=[string]$source.source_path
      source_sha256=[string]$source.source_sha256
      application_sha256=[string]$source.application_sha256
    })
    return $capture
  }
  $captureStepZero=[pscustomobject]@{exit_code=0}
  $captureStepOne=[pscustomobject]@{exit_code=1}
  $validCapture=New-ValidCaptureSummary
  Write-CaptureSummary $validCapture
  $validDisposition=Get-CaptureDisposition $captureStepZero
  Assert-Contract ([bool]$validDisposition.acceptable -and
      [bool]$validDisposition.evidence_contract_proven -and
      [string]$validDisposition.timing_sla_result -ceq 'PASS' -and
      -not[bool]$validDisposition.timing_sla_failure_admitted_for_stage_read) `
      'strict valid live capture summary was rejected'

  $timingSlaCapture=New-ValidCaptureSummary
  $timingSlaCapture.result='FAIL'
  $timingSlaCapture.ports[0].maximum_service_gap_us=203592
  $timingSlaCapture.ports[1].maximum_service_gap_us=187366
  Write-CaptureSummary $timingSlaCapture
  $timingSlaDisposition=Get-CaptureDisposition $captureStepOne
  Assert-Contract ([bool]$timingSlaDisposition.acceptable-and
      [bool]$timingSlaDisposition.evidence_contract_proven-and
      [string]$timingSlaDisposition.timing_sla_result-ceq'FAIL'-and
      [bool]$timingSlaDisposition.timing_sla_failure_admitted_for_stage_read-and
      @($timingSlaDisposition.rejection_reasons).Count-eq0) `
      'strict timing-only capture failure was not admitted for stage diagnosis'

  $unexplainedFailureCapture=New-ValidCaptureSummary
  $unexplainedFailureCapture.result='FAIL'
  Write-CaptureSummary $unexplainedFailureCapture
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'unexplained child result FAIL was admitted without an exceeded timing SLA'

  $wrongLimitCapture=New-ValidCaptureSummary
  $wrongLimitCapture.result='FAIL'
  $wrongLimitCapture.pump_service_limit_us=99999
  $wrongLimitCapture.ports[0].maximum_service_gap_us=203592
  Write-CaptureSummary $wrongLimitCapture
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'timing failure with the wrong service limit was admitted'

  $missingRoleCapture=New-ValidCaptureSummary
  $missingRoleCapture.result='FAIL'
  $missingRoleCapture.ports=@($missingRoleCapture.ports[0])
  $missingRoleCapture.ports[0].maximum_service_gap_us=203592
  Write-CaptureSummary $missingRoleCapture
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'timing failure without the exact two capture roles was admitted'

  $duplicateRoleCapture=New-ValidCaptureSummary
  $duplicateRoleCapture.result='FAIL'
  $duplicateRoleCapture.ports[0].maximum_service_gap_us=203592
  $duplicateRoleCapture.ports[1].role='vehicle'
  Write-CaptureSummary $duplicateRoleCapture
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'timing failure with duplicate capture roles was admitted'

  $dirtyTimingCapture=New-ValidCaptureSummary
  $dirtyTimingCapture.result='FAIL'
  $dirtyTimingCapture.ports[0].maximum_service_gap_us=203592
  $dirtyTimingCapture.parser_clean=$false
  Write-CaptureSummary $dirtyTimingCapture
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'timing failure with an unclean parser was admitted'

  $dirtyPortTimingCapture=New-ValidCaptureSummary
  $dirtyPortTimingCapture.result='FAIL'
  $dirtyPortTimingCapture.ports[0].maximum_service_gap_us=203592
  $dirtyPortTimingCapture.ports[1].parser_clean=$false
  Write-CaptureSummary $dirtyPortTimingCapture
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'timing failure with an unclean role parser was admitted'

  $nonMonotonicTimingCapture=New-ValidCaptureSummary
  $nonMonotonicTimingCapture.result='FAIL'
  $nonMonotonicTimingCapture.ports[0].maximum_service_gap_us=203592
  $nonMonotonicTimingCapture.alive_sequence_time_monotonic=$false
  Write-CaptureSummary $nonMonotonicTimingCapture
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'timing failure with non-monotonic ALIVE evidence was admitted'

  $invalidRepeatTimingCapture=New-ValidCaptureSummary
  $invalidRepeatTimingCapture.result='FAIL'
  $invalidRepeatTimingCapture.ports[0].maximum_service_gap_us=203592
  $invalidRepeatTimingCapture.r19f_repeat_contract.valid=$false
  Write-CaptureSummary $invalidRepeatTimingCapture
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'timing failure with an invalid R19F repeat contract was admitted'

  $invalidDiagnosticTimingCapture=New-ValidCaptureSummary
  $invalidDiagnosticTimingCapture.result='FAIL'
  $invalidDiagnosticTimingCapture.ports[0].maximum_service_gap_us=203592
  $invalidDiagnosticTimingCapture.invalid_diagnostic_count=1
  Write-CaptureSummary $invalidDiagnosticTimingCapture
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'timing failure with an invalid diagnostic was admitted'

  $cleanupFailureTimingCapture=New-ValidCaptureSummary
  $cleanupFailureTimingCapture.result='FAIL'
  $cleanupFailureTimingCapture.ports[0].maximum_service_gap_us=203592
  $cleanupFailureTimingCapture.cleanup.result='FAIL'
  $cleanupFailureTimingCapture.cleanup.errors=@('injected cleanup failure')
  Write-CaptureSummary $cleanupFailureTimingCapture
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'timing failure with failed cleanup was admitted'

  $staleExitCapture=New-ValidCaptureSummary
  $staleExitCapture.result='FAIL'
  Write-CaptureSummary $staleExitCapture
  $staleExitDisposition=Get-CaptureDisposition $captureStepZero
  Assert-Contract (-not [bool]$staleExitDisposition.acceptable) `
      'exit zero incorrectly overrode capture summary result FAIL'

  $wrongSchemaCapture=New-ValidCaptureSummary
  $wrongSchemaCapture.schema='wrong-schema'
  Write-CaptureSummary $wrongSchemaCapture
  Assert-Contract (-not [bool](Get-CaptureDisposition `
        $captureStepZero).acceptable) `
      'capture disposition accepted the wrong summary schema'

  $earlyFailureCapture=[pscustomobject][ordered]@{
    schema='vc-lora-r19-runtime-fail-diagnostic-summary-v1'
    test_id='R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001'
    result='FAIL';failure='capture cleanup failed before classification'
  }
  Write-CaptureSummary $earlyFailureCapture
  $earlyFailureThrew=$false
  try{$earlyFailureDisposition=Get-CaptureDisposition $captureStepOne}catch{
    $earlyFailureThrew=$true}
  Assert-Contract (-not$earlyFailureThrew-and
      -not[bool]$earlyFailureDisposition.acceptable-and
      @($earlyFailureDisposition.rejection_reasons|Where-Object{
        $_-match'^summary_contract_exception:'}).Count-eq1) `
      'early capture failure summary escaped fail-closed disposition handling'

  $wrongProvenanceCapture=New-ValidCaptureSummary
  $wrongProvenanceCapture.candidate_provenance.flash_record_sha256=('D'*64)
  Write-CaptureSummary $wrongProvenanceCapture
  Assert-Contract (-not [bool](Get-CaptureDisposition `
        $captureStepZero).acceptable) `
      'capture disposition accepted mismatched flash provenance'

  $wrongRunnerCapture=New-ValidCaptureSummary
  $wrongRunnerCapture.runner_integrity.start_sha256=('D'*64)
  $wrongRunnerCapture.runner_integrity.end_sha256=('D'*64)
  Write-CaptureSummary $wrongRunnerCapture
  Assert-Contract (-not [bool](Get-CaptureDisposition `
        $captureStepZero).acceptable) `
      'capture disposition accepted an unreviewed capture child hash'

  $noBeaconCapture=New-ValidCaptureSummary
  $noBeaconCapture.result='FAIL'
  $noBeaconCapture.diagnostic_classification='NO_BEACON'
  $noBeaconCapture.diagnostic_status='FAIL_NO_DIAGNOSTIC_BEACON'
  Write-CaptureSummary $noBeaconCapture
  $noBeaconDisposition=Get-CaptureDisposition $captureStepOne
  Assert-Contract ([bool]$noBeaconDisposition.acceptable -and
      [bool]$noBeaconDisposition.evidence_contract_proven) `
      'strict NO_BEACON evidence was not admitted for stage diagnosis'

  $tailStallCapture=New-TerminalPrefixStallCaptureSummary
  Write-CaptureSummary $tailStallCapture
  $tailStallDisposition=Get-CaptureDisposition $captureStepOne
  Assert-Contract ([bool]$tailStallDisposition.acceptable-and
      [bool]$tailStallDisposition.evidence_contract_proven-and
      [bool]$tailStallDisposition.tail_stall_failure_admitted_for_stage_read-and
      @($tailStallDisposition.rejection_reasons).Count-eq0) `
      'strict source-bound next-R19F terminal-prefix stall was not admitted for cause read'

  $tailStallMutations=@(
    [pscustomobject]@{name='wrong_sequence';apply={param($x)
      $x.terminal_partial_contract.sequence_matches_next=$false}},
    [pscustomobject]@{name='wrong_prefix';apply={param($x)
      $x.terminal_partial_contract.byte_exact_expected_next_r19f_prefix=$false}},
    [pscustomobject]@{name='wrong_role';apply={param($x)
      $x.terminal_partial_contract.role_matches_port=$false}},
    [pscustomobject]@{name='wrong_source';apply={param($x)
      $x.terminal_partial_contract.source_binding_verified=$false}},
    [pscustomobject]@{name='wrong_snapshot';apply={param($x)
      $x.terminal_partial_contract.failure_snapshot_matches_previous=$false}},
    [pscustomobject]@{name='two_ports';apply={param($x)
      $x.terminal_partial_contract.one_role_only=$false
      $x.terminal_partial_contract.attempted_port_count=2}},
    [pscustomobject]@{name='other_parser_error';apply={param($x)
      $x.terminal_partial_contract.all_other_parser_counters_zero=$false
      $x.ports[0].noise_bytes=1}},
    [pscustomobject]@{name='tail_unattempted';apply={param($x)
      $x.terminal_partial_contract.drain_attempted=$false}},
    [pscustomobject]@{name='tail_exception';apply={param($x)
      $x.terminal_partial_contract.no_read_exception=$false
      $x.terminal_partial_contract.read_exception='injected'}},
    [pscustomobject]@{name='repeat_invalid';apply={param($x)
      $x.r19f_repeat_contract.valid=$false}},
    [pscustomobject]@{name='common_invalid';apply={param($x)
      $x.cleanup.result='FAIL';$x.cleanup.errors=@('injected')}},
    [pscustomobject]@{name='raw_offset_invalid';apply={param($x)
      $x.terminal_partial_contract.raw_suffix_exact=$false
      $x.terminal_partial_contract.terminal_offset_plus_length_equals_raw_bytes=$false}}
  )
  foreach($mutation in $tailStallMutations){
    $mutated=New-TerminalPrefixStallCaptureSummary
    & $mutation.apply $mutated
    Write-CaptureSummary $mutated
    $mutationDisposition=Get-CaptureDisposition $captureStepOne
    Assert-Contract (-not[bool]$mutationDisposition.acceptable-and
        -not[bool]$mutationDisposition.tail_stall_failure_admitted_for_stage_read) `
        "terminal-prefix stall mutation was admitted: $($mutation.name)"
  }

  $genericParserCorruption=New-TerminalPrefixStallCaptureSummary
  $genericParserCorruption.diagnostic_classification='INVALID'
  $genericParserCorruption.diagnostic_status='FAIL_PARSER_CORRUPTION'
  Write-CaptureSummary $genericParserCorruption
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'generic parser corruption was admitted as a terminal-prefix stall'

  $invalidRepeatClassification=New-TerminalPrefixStallCaptureSummary
  $invalidRepeatClassification.diagnostic_classification='INVALID'
  $invalidRepeatClassification.diagnostic_status='FAIL_INVALID_R19F_REPEAT'
  Write-CaptureSummary $invalidRepeatClassification
  Assert-Contract (-not[bool](Get-CaptureDisposition `
        $captureStepOne).acceptable) `
      'generic invalid R19F repeat was admitted as a terminal-prefix stall'

  $aliveStallCapture=New-AliveTerminalPrefixStallCaptureSummary
  Write-CaptureSummary $aliveStallCapture
  $aliveStallDisposition=Get-CaptureDisposition $captureStepOne
  Assert-Contract ([bool]$aliveStallDisposition.acceptable-and
      [bool]$aliveStallDisposition.evidence_contract_proven-and
      [bool]$aliveStallDisposition.alive_tail_stall_failure_admitted_for_stage_read-and
      -not[bool]$aliveStallDisposition.tail_stall_failure_admitted_for_stage_read-and
      [string]$aliveStallDisposition.classification-ceq'R19A_TERMINAL_PREFIX_STALL'-and
      [string]$aliveStallDisposition.status-ceq'FAIL_R19A_TERMINAL_PREFIX_STALL'-and
      [string]$aliveStallCapture.result-ceq'FAIL'-and
      -not[bool]$aliveStallCapture.acceptance_eligible-and
      -not[bool]$aliveStallCapture.r19a_terminal_partial_contract.reconstruction_performed-and
      -not[bool]$aliveStallCapture.r19a_terminal_partial_contract.missing_crc_verified) `
      ('recorded Ground ALIVE32/63 was not admitted fail-only: '+
        (@($aliveStallDisposition.rejection_reasons)-join';'))
  $aliveStallMutations=@(
    [pscustomobject]@{name='pass_exit';exit_code=0;apply={param($x)}},
    [pscustomobject]@{name='promoted_result';apply={param($x)$x.result='PASS'}},
    [pscustomobject]@{name='promoted_acceptance';apply={param($x)
      $x.acceptance_eligible=$true}},
    [pscustomobject]@{name='reconstructed_suffix';apply={param($x)
      $x.r19a_terminal_partial_contract.reconstruction_performed=$true}},
    [pscustomobject]@{name='fabricated_crc';apply={param($x)
      $x.r19a_terminal_partial_contract.missing_crc_verified=$true}},
    [pscustomobject]@{name='not_fail_only';apply={param($x)
      $x.r19a_terminal_partial_contract.fail_only=$false}},
    [pscustomobject]@{name='wrong_role';apply={param($x)
      $x.r19a_terminal_partial_contract.role='vehicle'}},
    [pscustomobject]@{name='wrong_size';apply={param($x)
      $x.r19a_terminal_partial_contract.partial_bytes=31}},
    [pscustomobject]@{name='unknown_prefix';apply={param($x)
      $x.r19a_terminal_partial_contract.prefix_sha256=('0'*64)}},
    [pscustomobject]@{name='stale_sequence';apply={param($x)
      $x.r19a_terminal_partial_contract.next_sequence=11}},
    [pscustomobject]@{name='stale_ordinal';apply={param($x)
      $x.r19a_terminal_partial_contract.next_ordinal=11}},
    [pscustomobject]@{name='mixed_failure';apply={param($x)$x.r19f_count=1}},
    [pscustomobject]@{name='missing_identity';apply={param($x)
      $x.external_actions.port_identity_evidence=@()}},
    [pscustomobject]@{name='wrong_identity';apply={param($x)
      $x.external_actions.port_identity_evidence[0].parent='wrong'}},
    [pscustomobject]@{name='wrong_source';apply={param($x)
      $x.candidate_provenance.source_bindings[1].source_sha256=('0'*64)}},
    [pscustomobject]@{name='bad_crc_counter';apply={param($x)
      $x.ports[1].bad_crc=1}},
    [pscustomobject]@{name='two_partials';apply={param($x)
      $x.ports[0].partial_bytes=32;$x.ports[0].parser_clean=$false}},
    [pscustomobject]@{name='tail_read_exception';apply={param($x)
      $x.ports[1].tail_drain.no_read_exception=$false}},
    [pscustomobject]@{name='tail_progress';apply={param($x)
      $x.r19a_terminal_partial_contract.bytes_read=1}},
    [pscustomobject]@{name='raw_sha_mismatch';apply={param($x)
      $x.ports[1].raw_sha256=('0'*64)}}
  )
  foreach($mutation in $aliveStallMutations){
    $mutated=New-AliveTerminalPrefixStallCaptureSummary
    & $mutation.apply $mutated
    Write-CaptureSummary $mutated
    $step=if($null-ne$mutation.PSObject.Properties['exit_code']){
      [pscustomobject]@{exit_code=$mutation.exit_code}}else{$captureStepOne}
    $disposition=Get-CaptureDisposition $step
    Assert-Contract (-not[bool]$disposition.acceptable-and
        -not[bool]$disposition.alive_tail_stall_failure_admitted_for_stage_read) `
        "ALIVE terminal32/63 mutation was admitted: $($mutation.name)"
  }
  $aliveRawMutations=@(
    [pscustomobject]@{name='complete_crc';offset=61;value=0
      xor=$true;reason='r19a_raw_crc'},
    [pscustomobject]@{name='terminal_flags';offset=779;value=1
      xor=$false;reason='r19a_raw_flags'},
    [pscustomobject]@{name='terminal_sequence';offset=781;value=11
      xor=$false;reason='r19a_raw_terminal_identity'},
    [pscustomobject]@{name='terminal_role';offset=793;value=86
      xor=$false;reason='r19a_raw_terminal_ordinal'},
    [pscustomobject]@{name='terminal_state';offset=795;value=65
      xor=$false;reason='r19a_raw_terminal_ordinal'},
    [pscustomobject]@{name='terminal_stale_ordinal';offset=804;value=66
      xor=$false;reason='r19a_raw_terminal_ordinal'},
    [pscustomobject]@{name='terminal_unknown_time';offset=806;value=90
      xor=$false;reason='r19a_raw_terminal_ordinal'})
  foreach($mutation in $aliveRawMutations){
    $mutated=New-AliveTerminalPrefixStallCaptureSummary
    $rawPath=Join-Path $captureDirectory 'ground.raw.bin'
    [byte[]]$raw=[IO.File]::ReadAllBytes($rawPath)
    $raw[$mutation.offset]=if($mutation.xor){
      [byte]($raw[$mutation.offset]-bxor1)}else{[byte]$mutation.value}
    [IO.File]::WriteAllBytes($rawPath,$raw)
    # Rebind all raw/prefix hashes deliberately. Rejection must come from
    # independent byte/CRC/identity analysis, not merely a stale file hash.
    $rawSha=Get-Sha256 $rawPath
    $mutated.ports[1].raw_sha256=$rawSha
    $mutated.r19a_terminal_partial_contract.raw_sha256=$rawSha
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$mutated.r19a_terminal_partial_contract.prefix_sha256=
      ([BitConverter]::ToString($sha.ComputeHash(
        [byte[]]$raw[777..808]))).Replace('-','')}finally{$sha.Dispose()}
    Write-CaptureSummary $mutated
    $disposition=Get-CaptureDisposition $captureStepOne
    Assert-Contract (-not[bool]$disposition.acceptable-and
        -not[bool]$disposition.alive_tail_stall_failure_admitted_for_stage_read-and
        ((@($disposition.rejection_reasons)-join';')-match
          [regex]::Escape([string]$mutation.reason))) `
        "Rehashed ALIVE raw mutation was not independently rejected: $($mutation.name)"
  }
  Write-Output 'Recorded ALIVE32/63 outer admission PASS: fail-only; 20 unsafe evidence mutations rejected; synthetic identity fixtures only.'
  Write-Output 'Recorded ALIVE raw independent validation PASS: 7 rehashed CRC/identity mutations rejected.'
  # The previous R19F capture starts with an exact CRC-bearing suffix, not an
  # arbitrary noise allowance. Bind immutable raw independently of its claims.
  $boundaryCaptureDirectory=Join-Path $repo ('runs\hil\'+
      'R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001\'+
      '20261018T171157707Z-e0e2304d\capture')
  Assert-Contract ((Get-Sha256 (Join-Path $boundaryCaptureDirectory `
      'ground.raw.bin'))-ceq
      '8DD5417C6309A4003760D30FDFC17EBB1FE07BAB01A311CE2E359DAB15C271A7'-and
      (Get-Sha256 (Join-Path $boundaryCaptureDirectory 'vehicle.raw.bin'))-ceq
      '6740EB36ADA929A34A86C43CB6F02F3C492EFFE132A10E83AF96EF190FBC77B2') `
      'recorded R19F boundary raw bytes changed'
  function Get-ContractByteSha([byte[]]$Bytes){
    $hasher=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($hasher.ComputeHash($Bytes))).Replace('-','')}
    finally{$hasher.Dispose()}
  }
  function Set-ContractFrameCrc([byte[]]$Bytes,[int]$Offset){
    [int]$crc=65535
    foreach($value in @($Bytes[($Offset+1)..($Offset+60)])+@(83)){
      [int]$mixed=([int]$value-bxor($crc-band255))-band255
      $mixed=($mixed-bxor(($mixed-shl4)-band255))-band255
      $crc=(($crc-shr8)-bxor($mixed-shl8)-bxor($mixed-shl3)-bxor
          ($mixed-shr4))-band65535
    }
    $Bytes[$Offset+61]=[byte]($crc-band255)
    $Bytes[$Offset+62]=[byte](($crc-shr8)-band255)
  }
  function New-FailureBoundaryCaptureSummary {
    $capture=Get-Content -LiteralPath (Join-Path $boundaryCaptureDirectory `
        'summary.json') -Raw | ConvertFrom-Json
    $capture.result='FAIL';$capture.parser_clean=$false
    $capture.diagnostic_classification='R19F_CAPTURE_BOUNDARY_PARTIAL'
    $capture.diagnostic_status='FAIL_R19F_CAPTURE_BOUNDARY_PARTIAL'
    $capture.runner_integrity.start_sha256=('C'*64)
    $capture.runner_integrity.end_sha256=('C'*64)
    $capture.candidate_provenance.latest_sha256=$candidateLatestSha256
    $capture.candidate_provenance.handoff_sha256=
        [string]$candidateLatest.handoff.sha256
    $capture.candidate_provenance.flash_record_path=$flashRecordPath
    $capture.candidate_provenance.flash_record_sha256=Get-Sha256 $flashRecordPath
    $identities=@()
    foreach($role in @('vehicle','ground')){
      Copy-Item -LiteralPath (Join-Path $boundaryCaptureDirectory `
          ($role+'.raw.bin')) -Destination (Join-Path $captureDirectory `
          ($role+'.raw.bin')) -Force
      $isGround=$role-ceq'ground'
      foreach($checkpoint in @('before_open','after_open')){
        $identities+=,[pscustomobject]@{role=$role
          port=if($isGround){'COM6'}else{'COM3'};checkpoint=$checkpoint
          pnp=if($isGround){'USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000'}else{
            'USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000'}
          parent=if($isGround){'USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80'}else{
            'USB\VID_303A&PID_1001\90:70:69:11:81:A4'}
          result='PASS';offline_fixture=$true}
      }
    }
    $capture.external_actions|Add-Member -Force -NotePropertyName `
        port_identity_evidence -NotePropertyValue $identities
    $source=@($capture.candidate_provenance.source_bindings|Where-Object{
        $_.role-ceq'ground'})[0]
    [byte[]]$raw=[IO.File]::ReadAllBytes((Join-Path $captureDirectory `
        'ground.raw.bin'))
    $capture|Add-Member -Force -NotePropertyName r19f_boundary_partial_contract `
        -NotePropertyValue ([pscustomobject][ordered]@{
      schema='vc-lora-r19f-boundary-partial-cause-contract-v1'
      valid=$true;fail_only=$true;reconstruction_performed=$false
      missing_prefix_received=$false;missing_terminal_crc_verified=$false
      role='ground';port='COM6';leading_bytes=31;leading_raw_offset=0
      leading_sha256=Get-ContractByteSha ([byte[]]$raw[0..30])
      raw_bytes=441;raw_sha256=Get-Sha256 (Join-Path $captureDirectory 'ground.raw.bin')
      leading_prior_sequence=2;leading_sequence_unique=$true
      leading_suffix_exact=$true;prior_r19f_count=6
      prior_complete_frames_crc_valid=$true;prior_source_binding_verified=$true
      prior_snapshots_identical=$true;prior_sequences_contiguous=$true
      terminal_partial_bytes=32;terminal_raw_offset=409
      terminal_prefix_sha256=Get-ContractByteSha ([byte[]]$raw[409..440])
      terminal_sequence=9;terminal_prefix_exact=$true
      no_progress_us=34348968;only_parser_defects=$true
      source_path=[string]$source.source_path
      source_sha256=[string]$source.source_sha256
      application_sha256=[string]$source.application_sha256
    })
    return $capture
  }
  $boundaryCapture=New-FailureBoundaryCaptureSummary
  Write-CaptureSummary $boundaryCapture
  $boundaryDisposition=Get-CaptureDisposition $captureStepOne
  Assert-Contract ([bool]$boundaryDisposition.acceptable-and
      [bool]$boundaryDisposition.evidence_contract_proven-and
      [bool]$boundaryDisposition.boundary_partial_failure_admitted_for_stage_read-and
      [string]$boundaryDisposition.classification-ceq'R19F_CAPTURE_BOUNDARY_PARTIAL'-and
      [string]$boundaryCapture.result-ceq'FAIL'-and
      -not[bool]$boundaryCapture.parser_clean-and
      [int]$boundaryCapture.ports[1].noise_bytes-eq31-and
      [int]$boundaryCapture.ports[1].partial_bytes-eq32) `
      ('recorded R19F boundary was not admitted fail-only: '+
        ($boundaryDisposition|ConvertTo-Json -Depth 8 -Compress))
  $boundaryMetadataMutations=@(
    [pscustomobject]@{name='success_exit';apply={param($v)$v.result='PASS'}},
    [pscustomobject]@{name='acceptance';apply={param($v)$v.acceptance_authorized=$true}},
    [pscustomobject]@{name='deployment';apply={param($v)$v.deployment_authorized=$true}},
    [pscustomobject]@{name='fabricated_prefix';apply={param($v)
      $v.r19f_boundary_partial_contract.missing_prefix_received=$true}},
    [pscustomobject]@{name='fabricated_terminal_crc';apply={param($v)
      $v.r19f_boundary_partial_contract.missing_terminal_crc_verified=$true}},
    [pscustomobject]@{name='reconstructed';apply={param($v)
      $v.r19f_boundary_partial_contract.reconstruction_performed=$true}},
    [pscustomobject]@{name='false_clean';apply={param($v)$v.parser_clean=$true}},
    [pscustomobject]@{name='unexplained_noise';apply={param($v)$v.ports[1].noise_bytes=32}},
    [pscustomobject]@{name='wrong_role';apply={param($v)
      $v.r19f_boundary_partial_contract.role='vehicle'}},
    [pscustomobject]@{name='source_hash';apply={param($v)
      $v.r19f_boundary_partial_contract.source_sha256='0'*64}},
    [pscustomobject]@{name='application_hash';apply={param($v)
      $v.r19f_boundary_partial_contract.application_sha256='0'*64}},
    [pscustomobject]@{name='non_unique_sequence';apply={param($v)
      $v.r19f_boundary_partial_contract.leading_sequence_unique=$false}},
    [pscustomobject]@{name='wrong_prior_sequence';apply={param($v)
      $v.r19f_boundary_partial_contract.leading_prior_sequence=1}},
    [pscustomobject]@{name='terminal_offset';apply={param($v)
      $v.r19f_boundary_partial_contract.terminal_raw_offset=408}},
    [pscustomobject]@{name='cleanup';apply={param($v)$v.cleanup.result='FAIL'}},
    [pscustomobject]@{name='read_exception';apply={param($v)
      $v.ports[1].tail_drain.no_read_exception=$false}},
    [pscustomobject]@{name='identity';apply={param($v)
      $v.external_actions.port_identity_evidence[3].parent='USB\WRONG'}},
    [pscustomobject]@{name='candidate';apply={param($v)
      $v.candidate_provenance.latest_sha256='0'*64}}
  )
  foreach($mutation in $boundaryMetadataMutations){
    $mutated=New-FailureBoundaryCaptureSummary
    & $mutation.apply $mutated
    Write-CaptureSummary $mutated
    Assert-Contract (-not[bool](Get-CaptureDisposition $captureStepOne).acceptable) `
        "R19F boundary metadata mutation admitted: $($mutation.name)"
  }
  $boundaryRawMutations=@(
    [pscustomobject]@{name='leading_noise';offset=0;value=1;xor=$true},
    [pscustomobject]@{name='leading_crc';offset=30;value=1;xor=$true},
    [pscustomobject]@{name='complete_crc';offset=92;value=1;xor=$true},
    [pscustomobject]@{name='complete_sequence';offset=98;value=17;xor=$false},
    [pscustomobject]@{name='complete_snapshot';offset=54;value=1;xor=$true},
    [pscustomobject]@{name='leading_wrong_prior';offset=29;value=1;xor=$true},
    [pscustomobject]@{name='terminal_sequence';offset=413;value=8;xor=$false},
    [pscustomobject]@{name='terminal_role';offset=425;value=86;xor=$false},
    [pscustomobject]@{name='terminal_flags';offset=411;value=1;xor=$false})
  foreach($mutation in $boundaryRawMutations){
    $mutated=New-FailureBoundaryCaptureSummary
    $path=Join-Path $captureDirectory 'ground.raw.bin'
    [byte[]]$raw=[IO.File]::ReadAllBytes($path)
    $raw[$mutation.offset]=if($mutation.xor){
      [byte]($raw[$mutation.offset]-bxor$mutation.value)}else{[byte]$mutation.value}
    if($mutation.name-ceq'complete_sequence'){Set-ContractFrameCrc $raw 94}
    if($mutation.name-ceq'complete_snapshot'){Set-ContractFrameCrc $raw 31}
    if($mutation.name-ceq'leading_wrong_prior'){
      [byte[]]$preceding=$raw[31..93];$preceding[4]=1
      Set-ContractFrameCrc $preceding 0
      [Array]::Copy($preceding,32,$raw,0,31)
    }
    [IO.File]::WriteAllBytes($path,$raw)
    # Rebind hashes so no stale digest can substitute for semantic validation.
    $mutated.ports[1].raw_sha256=Get-Sha256 $path
    $mutated.r19f_boundary_partial_contract.raw_sha256=Get-Sha256 $path
    $mutated.r19f_boundary_partial_contract.leading_sha256=
        Get-ContractByteSha ([byte[]]$raw[0..30])
    $mutated.r19f_boundary_partial_contract.terminal_prefix_sha256=
        Get-ContractByteSha ([byte[]]$raw[409..440])
    Write-CaptureSummary $mutated
    Assert-Contract (-not[bool](Get-CaptureDisposition $captureStepOne).acceptable) `
        "Rehashed R19F boundary raw mutation admitted: $($mutation.name)"
  }
  Write-Output 'Recorded R19F boundary outer admission PASS: 441/2646 immutable bytes; fail-only; 18 metadata and 9 rehashed raw mutations rejected, including CRC-repaired snapshot/sequence and valid wrong-prior suffix.'
  $candidateArtifactId=[string]$currentCandidateContext.artifact_id
  $candidateLatestSha256=[string]$currentCandidateContext.latest_sha256
  $candidateLatest=$currentCandidateContext.latest
  $candidateArtifactRoot=[string]$currentCandidateContext.artifact_root
  $candidateManifestPath=[string]$currentCandidateContext.manifest_path
  foreach ($scenario in $scenarios) {
    $output = Join-Path $tempRoot $scenario.name
    $stdout = Join-Path $tempRoot ($scenario.name + '.stdout.txt')
    $stderr = Join-Path $tempRoot ($scenario.name + '.stderr.txt')
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath,
      '-RepoRoot', $repo, '-OfflineContractTest',
      '-OfflineScenario', $scenario.name, '-OutputDirectory', $output
    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr
    Assert-Contract ($process.ExitCode -eq $scenario.expectedExit) `
        ("scenario {0} exit mismatch: expected={1} actual={2}; stdout={3}; stderr={4}" -f
          $scenario.name,$scenario.expectedExit,$process.ExitCode,
          (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue),
          (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue))
    $summaryPath = Join-Path $output 'summary.json'
    Assert-Contract (Test-Path -LiteralPath $summaryPath -PathType Leaf) `
        "scenario $($scenario.name) summary is missing"
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    Assert-Contract ([string]$summary.schema -ceq `
        'vc-lora-r19-runtime-stage-cause-experiment-v1') `
        "scenario $($scenario.name) schema mismatch"
    Assert-Contract ([string]$summary.mode -ceq 'OFFLINE_CONTRACT' -and
        -not [bool]$summary.hardware_interaction -and
        -not [bool]$summary.acceptance_authorized -and
        -not [bool]$summary.deployment_authorized -and
        [int]$summary.capture_seconds -eq 40) `
        "scenario $($scenario.name) offline safety metadata mismatch"
    Assert-Contract ([string]$summary.candidate.artifact_id -ceq
        $candidateArtifactId -and
        [string]$summary.candidate.latest_sha256 -ceq
          $candidateLatestSha256 -and
        -not [bool]$summary.candidate.latest_lock_retained_until_outer_exit) `
        "scenario $($scenario.name) lost the exact offline candidate pin"
    Assert-Contract ([string]$summary.stage_evidence.vehicle.address -ceq
        $vehicleRuntimeStageAddress -and
        [string]$summary.stage_evidence.ground.address -ceq
          $groundRuntimeStageAddress) `
        "scenario $($scenario.name) stage address/fallback mismatch"
    Assert-Contract ([string]$summary.status -ceq $scenario.expectedStatus) `
        "scenario $($scenario.name) status mismatch"
    if($scenario.name-in@('usb_boundary_incomplete','ground_heartbeat_failure_observed')){
      Assert-Contract ([bool]$summary.stage_evidence.vehicle.proven-and
          [bool]$summary.stage_evidence.ground.proven-and
          [string]$summary.diagnostic_outcomes.record_acquisition_result-ceq'PASS'-and
          -not[bool]$summary.diagnostic_outcomes.usb_observation_is_continuous_live_hardware_state-and
          -not[bool]$summary.diagnostic_outcomes.usb_observation_proves_windows_cdc_consumption) `
          "cause observations were confused with acquisition failure: $($scenario.name)"
    }
    if($scenario.name-ceq'usb_boundary_incomplete'){
      Assert-Contract ([string]$summary.diagnostic_outcomes.usb_boundary_observation_result-ceq
          'INCOMPLETE_AT_RECORDED_BOUNDARY') 'incomplete USB boundary was promoted to complete'
    }
    if($scenario.name-ceq'capture_timing_sla_failure'){
      Assert-Contract ([string]$summary.result-ceq'FAIL'-and
          [bool]$summary.capture.acceptable-and
          [bool]$summary.capture.evidence_contract_proven-and
          [string]$summary.capture.timing_sla_result-ceq'FAIL'-and
          [bool]$summary.capture.timing_sla_failure_admitted_for_stage_read-and
          [bool]$summary.rollback.proven-and
          -not[bool]$summary.power_off_required) `
          'timing-only evidence did not continue to stage reads while preserving final SLA failure'
    }
    if($scenario.name-ceq'capture_terminal_prefix_stall'){
      Assert-Contract ([string]$summary.result-ceq'FAIL'-and
          [bool]$summary.capture.acceptable-and
          [bool]$summary.capture.evidence_contract_proven-and
          [bool]$summary.capture.tail_stall_failure_admitted_for_stage_read-and
          [bool]$summary.rollback.proven-and
          -not[bool]$summary.power_off_required) `
          'terminal-prefix stall did not continue to stage reads while preserving final failure'
    }
    if($scenario.name-ceq'capture_terminal_prefix_stall_stage_failure'){
      Assert-Contract ([string]$summary.result-ceq'FAIL'-and
          [bool]$summary.capture.tail_stall_failure_admitted_for_stage_read-and
          -not[bool]$summary.stage_evidence.vehicle.proven-and
          [bool]$summary.rollback.proven-and
          -not[bool]$summary.power_off_required) `
          'stage failure after terminal-prefix stall did not remain a stage failure with rollback'
    }
    if($scenario.name-ceq'capture_alive_terminal_prefix_stall'){
      Assert-Contract ([string]$summary.result-ceq'FAIL'-and
          [bool]$summary.capture.acceptable-and
          [bool]$summary.capture.evidence_contract_proven-and
          [bool]$summary.capture.alive_tail_stall_failure_admitted_for_stage_read-and
          [string]$summary.capture.classification-ceq'R19A_TERMINAL_PREFIX_STALL'-and
          [string]$summary.capture.status-ceq'FAIL_R19A_TERMINAL_PREFIX_STALL'-and
          [bool]$summary.stage_evidence.vehicle.proven-and
          [bool]$summary.stage_evidence.ground.proven-and
          [bool]$summary.rollback.proven-and
          -not[bool]$summary.acceptance_authorized-and
          -not[bool]$summary.deployment_authorized-and
          -not[bool]$summary.power_off_required) `
          'ALIVE terminal32/63 did not read both roles and restore R18 while preserving diagnostic failure'
    }
    if($scenario.name-ceq'capture_alive_terminal_prefix_stall_stage_failure'){
      Assert-Contract ([string]$summary.result-ceq'FAIL'-and
          [bool]$summary.capture.alive_tail_stall_failure_admitted_for_stage_read-and
          -not[bool]$summary.stage_evidence.vehicle.proven-and
          [bool]$summary.rollback.proven-and
          -not[bool]$summary.power_off_required) `
          'stage failure after ALIVE terminal32/63 did not remain failed with mandatory rollback'
    }
    if($scenario.name-ceq'capture_boundary_partial'){
      Assert-Contract ([string]$summary.result-ceq'FAIL'-and
          [bool]$summary.capture.acceptable-and
          [bool]$summary.capture.evidence_contract_proven-and
          [bool]$summary.capture.boundary_partial_failure_admitted_for_stage_read-and
          [string]$summary.capture.classification-ceq'R19F_CAPTURE_BOUNDARY_PARTIAL'-and
          [string]$summary.capture.status-ceq'FAIL_R19F_CAPTURE_BOUNDARY_PARTIAL'-and
          [bool]$summary.stage_evidence.vehicle.proven-and
          [bool]$summary.stage_evidence.ground.proven-and
          [bool]$summary.rollback.proven-and
          -not[bool]$summary.acceptance_authorized-and
          -not[bool]$summary.deployment_authorized-and
          -not[bool]$summary.power_off_required) `
          'R19F capture boundary did not read both roles and restore R18 while retaining FAIL'
    }
    if($scenario.name-ceq'capture_boundary_partial_stage_failure'){
      Assert-Contract ([string]$summary.result-ceq'FAIL'-and
          [bool]$summary.capture.boundary_partial_failure_admitted_for_stage_read-and
          -not[bool]$summary.stage_evidence.vehicle.proven-and
          [bool]$summary.rollback.proven-and
          -not[bool]$summary.power_off_required) `
          'stage failure after R19F boundary did not remain failed with mandatory rollback'
    }
    Assert-Contract (-not [bool]$summary.stage_read_policy.simultaneous -and
        [bool]$summary.stage_read_policy.stage_mask_monotonic -and
        [bool]$summary.stage_read_policy.first_failure_latched -and
        @($summary.stage_read_policy.order).Count -eq 2) `
        "scenario $($scenario.name) sequential-stage limitation is missing"
    [string[]]$actualSteps = @($summary.steps | ForEach-Object {[string]$_.name})
    Assert-Contract (($actualSteps -join ',') -ceq
        (@($scenario.expectedSteps) -join ',')) `
        "scenario $($scenario.name) step order mismatch"
    Assert-Contract (@($summary.steps | Where-Object {
          [bool]$_.hardware_interaction
        }).Count -eq 0) `
        "scenario $($scenario.name) offline mock reached hardware"
    $beforeInstallFailure = $scenario.name -in @(
      'reader_missing','jtag_preflight_failure',
      'active_jtag_vehicle_failure','active_jtag_ground_failure',
      'active_jtag_vehicle_cleanup_unproven',
      'active_jtag_ground_cleanup_unproven',
      'active_jtag_location_mismatch')
    if (-not $beforeInstallFailure -and
        $scenario.name -cne 'jtag_vehicle_timeout') {
      Assert-Contract ([bool]$summary.rollback.attempted) `
          "scenario $($scenario.name) did not attempt rollback"
    }
    if ($scenario.name -eq 'jtag_vehicle_timeout') {
      Assert-Contract (-not [bool]$summary.rollback.attempted -and
          -not [bool]$summary.rollback.proven -and
          [bool]$summary.power_off_required -and
          [bool]$summary.hardware_quiescence.further_child_launch_blocked -and
          -not [bool]$summary.hardware_quiescence.child_termination_proven) `
          'unproven child termination did not suppress rollback and require power-off'
    } elseif ($scenario.name -eq 'rollback_failure') {
      Assert-Contract (-not [bool]$summary.rollback.proven -and
          [bool]$summary.power_off_required) `
          'rollback failure did not fail closed with power-off requirement'
    } elseif (-not $beforeInstallFailure) {
      Assert-Contract ([bool]$summary.rollback.proven -and
          -not [bool]$summary.power_off_required) `
          "scenario $($scenario.name) did not prove accepted-R18 rollback"
    }
    if ($scenario.name -eq 'jtag_preflight_failure') {
      Assert-Contract (-not [bool]$summary.rollback.attempted -and
          -not [bool]$summary.jtag_preflight.proven -and
          -not [bool]$summary.jtag_preflight.firmware_install_allowed) `
          'failed JTAG pre-flash gate did not block install without rollback'
    }
    if ($scenario.name -notin @('reader_missing','jtag_preflight_failure')) {
      $pnpSteps=@($summary.steps|Where-Object{[string]$_.name-ceq'jtag_preflight'})
      Assert-Contract ($pnpSteps.Count-eq1-and[int]$pnpSteps[0].exit_code-eq1-and
          [string]$pnpSteps[0].result-ceq'FAIL'-and
          [string]$pnpSteps[0].semantic_result-ceq
            'PASS_PNP_DRIVER_BINDING_ONLY_EXPECTED_EXIT_1') `
          'PnP-only expected exit 1 was hidden or misclassified'
      $pnpVehicle=@($summary.jtag_preflight.roles|Where-Object{
        [string]$_.role-ceq'vehicle'})
      $pnpGround=@($summary.jtag_preflight.roles|Where-Object{
        [string]$_.role-ceq'ground'})
      Assert-Contract ([bool]$summary.jtag_preflight.driver_binding_proven -and
          -not [bool]$summary.jtag_preflight.firmware_install_allowed -and
          [string]$summary.jtag_preflight.status -ceq
            'PASS_WINUSB_DRIVER_BINDING_PNP_ONLY' -and
          $pnpVehicle.Count-eq1-and$pnpGround.Count-eq1-and
          [string]$pnpVehicle[0].pnp_port_chain-ceq'4.2'-and
          [string]$pnpGround[0].pnp_port_chain-ceq'4.4'-and
          [string]$pnpVehicle[0].pnp_port_chain-cne
            [string]$pnpGround[0].pnp_port_chain) `
          "scenario $($scenario.name) did not retain the exact PnP-only proof"
    }
    $activeSucceeded = -not $beforeInstallFailure
    if ($activeSucceeded) {
      $activeVehicle=@($summary.active_jtag_preflight.roles|Where-Object{
        [string]$_.role-ceq'vehicle'})
      $activeGround=@($summary.active_jtag_preflight.roles|Where-Object{
        [string]$_.role-ceq'ground'})
      Assert-Contract ([bool]$summary.active_jtag_preflight.proven -and
          [bool]$summary.active_jtag_preflight.firmware_install_allowed -and
          $activeVehicle.Count-eq1-and$activeGround.Count-eq1-and
          [string]$activeVehicle[0].status-ceq
            'PASS_JTAG_PREFLIGHT_TAP_RESET_SCAN_POSSIBLE_NO_CPU_HALT_OR_SYSTEM_RESET_COMMAND'-and
          [string]$activeVehicle[0].requested_serial-ceq
            '90:70:69:11:81:a4'-and
          [string]$activeVehicle[0].opened_serial-ceq
            '90:70:69:11:81:a4'-and
          [string]$activeVehicle[0].requested_usb_location-ceq'1-4.2'-and
          [string]$activeVehicle[0].opened_usb_location-ceq'1-4.2'-and
          [string]$activeVehicle[0].pnp_port_chain-ceq'4.2'-and
          [bool]$activeVehicle[0].pnp_location_suffix_matched-and
          [bool]$activeVehicle[0].safety.process_termination_proven-and
          [bool]$activeVehicle[0].safety.shutdown_proven-and
          -not[bool]$activeVehicle[0].safety.target_config_loaded-and
          -not[bool]$activeVehicle[0].safety.cpu_halt_command_issued-and
          -not[bool]$activeVehicle[0].safety.system_reset_command_issued-and
          [string]$activeGround[0].status-ceq
            'PASS_JTAG_PREFLIGHT_TAP_RESET_SCAN_POSSIBLE_NO_CPU_HALT_OR_SYSTEM_RESET_COMMAND'-and
          [string]$activeGround[0].requested_serial-ceq
            '1c:db:d4:5a:83:80'-and
          [string]$activeGround[0].opened_serial-ceq
            '1c:db:d4:5a:83:80'-and
          [string]$activeGround[0].requested_usb_location-ceq'1-4.4'-and
          [string]$activeGround[0].opened_usb_location-ceq'1-4.4'-and
          [string]$activeGround[0].pnp_port_chain-ceq'4.4'-and
          [bool]$activeGround[0].pnp_location_suffix_matched-and
          [bool]$activeGround[0].safety.process_termination_proven-and
          [bool]$activeGround[0].safety.shutdown_proven-and
          -not[bool]$activeGround[0].safety.target_config_loaded-and
          -not[bool]$activeGround[0].safety.cpu_halt_command_issued-and
          -not[bool]$activeGround[0].safety.system_reset_command_issued-and
          [string]$activeVehicle[0].opened_usb_location-cne
            [string]$activeGround[0].opened_usb_location) `
          "scenario $($scenario.name) did not prove both exact active-JTAG bindings"
    } elseif ($scenario.name -like 'active_jtag_*') {
      Assert-Contract (-not [bool]$summary.rollback.attempted -and
          -not [bool]$summary.active_jtag_preflight.proven -and
          -not [bool]$summary.active_jtag_preflight.firmware_install_allowed) `
          "scenario $($scenario.name) did not fail closed before install"
      if ($scenario.name -in @('active_jtag_vehicle_cleanup_unproven',
          'active_jtag_ground_cleanup_unproven')) {
        $cleanupRole=if($scenario.name -like '*vehicle*'){'vehicle'}else{'ground'}
        $cleanupEvidence=@($summary.active_jtag_preflight.roles|
          Where-Object{[string]$_.role-ceq$cleanupRole})
        Assert-Contract ([bool]$summary.power_off_required -and
            -not [bool]$summary.rollback.attempted -and
            @($summary.steps|Where-Object{[string]$_.name-ceq'install'}).
              Count-eq0-and
            $cleanupEvidence.Count-eq1-and
            [bool]$cleanupEvidence[0].hardware_interaction-and
            (-not[bool]$cleanupEvidence[0].safety.process_termination_proven-or
              -not[bool]$cleanupEvidence[0].safety.shutdown_proven)) `
            "scenario $($scenario.name) did not require power-off before flash"
      } elseif ($scenario.name -in @('active_jtag_vehicle_failure',
          'active_jtag_ground_failure')) {
        $safeFailureRole=if($scenario.name -like '*vehicle*'){
          'vehicle'}else{'ground'}
        $safeFailureEvidence=@($summary.active_jtag_preflight.roles|
          Where-Object{[string]$_.role-ceq$safeFailureRole})
        Assert-Contract (-not [bool]$summary.power_off_required-and
            $safeFailureEvidence.Count-eq1-and
            [bool]$safeFailureEvidence[0].hardware_interaction-and
            [bool]$safeFailureEvidence[0].safety.process_termination_proven-and
            [bool]$safeFailureEvidence[0].safety.shutdown_proven) `
            "scenario $($scenario.name) treated proven safe cleanup as unproven"
      }
    }
  }

  $unsafeOutput = Join-Path $tempRoot 'unsafe-token'
  $unsafeProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath,
    '-RepoRoot', $repo, '-OfflineContractTest', '-OfflineScenario', 'success',
    '-OutputDirectory', $unsafeOutput, '-HilAuthorization',
    'R19_RUNTIME_FAIL_DIAGNOSTIC_HIL_ONE_RUN_NOT_ACCEPTANCE_NOT_DEPLOYMENT'
  ) -Wait -PassThru -WindowStyle Hidden
  Assert-Contract ($unsafeProcess.ExitCode -ne 0) `
      'offline contract mode accepted a live authorization token'

  $unsafeLocationOutput = Join-Path $tempRoot 'unsafe-live-location'
  $unsafeLocationProcess = Start-Process -FilePath 'powershell.exe' `
      -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,
        '-RepoRoot',$repo,'-OfflineContractTest','-OfflineScenario','success',
        '-OutputDirectory',$unsafeLocationOutput,
        '-VehicleProbeUsbLocation','1-4.2',
        '-GroundProbeUsbLocation','1-4.4') `
      -Wait -PassThru -WindowStyle Hidden
  Assert-Contract ($unsafeLocationProcess.ExitCode -ne 0) `
      'offline contract mode accepted live-only probe USB locations'

  $discoveryOutput = Join-Path $tempRoot 'read-only-tool-discovery'
  $discoveryStdout = Join-Path $tempRoot 'read-only-tool-discovery.stdout.txt'
  $discoveryStderr = Join-Path $tempRoot 'read-only-tool-discovery.stderr.txt'
  $discoveryProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath,
    '-RepoRoot', $repo, '-ReadOnlyToolDiscoveryPreflight',
    '-OutputDirectory', $discoveryOutput
  ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput `
      $discoveryStdout -RedirectStandardError $discoveryStderr
  Assert-Contract ($discoveryProcess.ExitCode -eq 0) `
      ("read-only installed-tool discovery failed: stdout={0}; stderr={1}" -f
        (Get-Content -LiteralPath $discoveryStdout -Raw `
          -ErrorAction SilentlyContinue),
        (Get-Content -LiteralPath $discoveryStderr -Raw `
          -ErrorAction SilentlyContinue))
  $discoverySummaryPath = Join-Path $discoveryOutput 'summary.json'
  Assert-Contract (Test-Path -LiteralPath $discoverySummaryPath -PathType Leaf) `
      'read-only installed-tool discovery summary is missing'
  $discoverySummary = Get-Content -LiteralPath $discoverySummaryPath -Raw |
      ConvertFrom-Json
  Assert-Contract ([string]$discoverySummary.mode -ceq
      'READ_ONLY_TOOL_DISCOVERY' -and
      [string]$discoverySummary.result -ceq 'PASS' -and
      [string]$discoverySummary.status -ceq 'PASS_TOOL_DISCOVERY_NO_HARDWARE' -and
      -not [bool]$discoverySummary.hardware_interaction -and
      @($discoverySummary.steps).Count -eq 0) `
      'read-only installed-tool discovery did not remain hardware-free'
  Assert-Contract ([string]$discoverySummary.tooling.nm_sha256 -ceq
      'AC8D55C45DBCAEFE082299357245D7F12786C61A4E3C06A8E21F31D6890FB29E' -and
      [string]$discoverySummary.tooling.executable_sha256 -ceq
      '7461DBBEC251F1D4A2189C3C57B74A45B2FE64DEC1EC1B9EDDCB348A2AB2EBAB') `
      'read-only installed-tool discovery did not bind the pinned binaries'

  Write-Output "$testId PASS"
} finally {
  $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($tempRoot.StartsWith($tempPrefix,
        [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $tempRoot) -match
        '^vc_lora_r19_stage_cause_contract_[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
