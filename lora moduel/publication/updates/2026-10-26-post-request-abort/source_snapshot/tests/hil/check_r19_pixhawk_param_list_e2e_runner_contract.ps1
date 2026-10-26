[CmdletBinding()]
param(
  [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
$runner = Join-Path $repo 'tools\run_r19_pixhawk_param_list_e2e_hil.ps1'
$shared = Join-Path $repo 'tools\run_r18_pixhawk_param_list_e2e_hil.ps1'

function Assert-Condition([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw $Message }
}

Assert-Condition (Test-Path -LiteralPath $runner -PathType Leaf) `
    "R19 live acceptance runner is missing: $runner"
Assert-Condition (Test-Path -LiteralPath $shared -PathType Leaf) `
    "Shared strict accounting runner is missing: $shared"

$runnerText = [IO.File]::ReadAllText($runner)
$sharedText = [IO.File]::ReadAllText($shared)

foreach ($required in @(
    'R19-PIXHAWK-PARAM-LIST-E2E-HIL-001',
    'CandidateHandoffPath',
    'CandidateFlashEvidencePath',
    'vc-lora-r19-candidate-artifact-manifest-v1',
    'vc-lora-r19-candidate-flash-evidence-v1',
    'vc-lora-r19-candidate-final-seal-v1',
    'vc-lora-r19-candidate-flash-final-seal-v1',
    'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED',
    'R19_EXPERIMENTAL_HIL_ONE_RUN_NOT_DEPLOYMENT',
    'R19-LIVE-ONE-RUN-CLAIMS',
    '[IO.FileMode]::CreateNew',
    'candidate_manifest_sha256',
    'final_seal_sha256',
    'runtime_fail_diagnostics_enabled',
    'COM3',
    'COM6',
    'R19SharedMode')) {
  Assert-Condition ($runnerText.Contains($required)) `
      "R19 runner contract token is missing: $required"
}

foreach ($required in @(
    'R19SharedMode',
    'R19ProvenancePath',
    'Get-R19RuntimeFailDiagnosticRecord',
    'Register-R19RuntimeFailFrame',
    'R19F:',
    'FAIL_RUNTIME_DIAGNOSTIC_OBSERVED',
    'FAIL_INVALID_RUNTIME_DIAGNOSTIC',
    'R19 completion deadline exceeded: 30000000 us',
    'maximum_consecutive_gap_us',
    'parser_error_count',
    'duplicate_guard_completed',
    'pump_service_limit_us',
    'COM3 must remain explicitly forbidden')) {
  Assert-Condition ($sharedText.Contains($required)) `
      "Shared strict runner R19 contract token is missing: $required"
}

$offlineRoot = Join-Path $repo `
    ('runs\validation\R19-LIVE-RUNNER-CONTRACT-001\' +
     [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' +
     [Guid]::NewGuid().ToString('N').Substring(0,8))
& $runner -OfflineSelfTest -RepoRoot $repo -OutputDirectory $offlineRoot
Assert-Condition ($LASTEXITCODE -eq 0) `
    "R19 runner offline self-test exited $LASTEXITCODE"

$summaryPath = Join-Path $offlineRoot 'summary.json'
Assert-Condition (Test-Path -LiteralPath $summaryPath -PathType Leaf) `
    'R19 runner offline self-test summary is missing.'
$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
Assert-Condition ([string]$summary.test_id -ceq
    'R19-PIXHAWK-PARAM-LIST-E2E-HIL-001') `
    'R19 offline summary test_id mismatch.'
Assert-Condition ([string]$summary.mode -ceq 'OFFLINE_SELF_TEST' -and
    [string]$summary.result -ceq 'PASS') `
    'R19 offline self-test did not pass.'
Assert-Condition (-not [bool]$summary.external_actions.com_ports_opened -and
    -not [bool]$summary.external_actions.serial_write_attempted -and
    -not [bool]$summary.external_actions.firmware_write_attempted) `
    'R19 offline self-test performed a forbidden external action.'
Assert-Condition ([string]$summary.r19_artifact_provenance.result -ceq 'PASS' -and
    [string]$summary.r19_flash_provenance.result -ceq 'PASS' -and
    $summary.r19_artifact_provenance.runtime_fail_diagnostics_enabled `
      -is [bool] -and
    -not [bool]$summary.r19_artifact_provenance.
      runtime_fail_diagnostics_enabled -and
    [bool]$summary.r19_artifact_provenance.acceptance_eligible -and
    -not [bool]$summary.r19_artifact_provenance.acceptance_authorized -and
    -not [bool]$summary.r19_artifact_provenance.deployment_authorized) `
    'R19 offline self-test did not exercise provenance validation.'
Assert-Condition ([string]$summary.deadline_contract.result -ceq 'PASS' -and
    [int64]$summary.deadline_contract.inclusive_limit_us -eq 30000000 -and
    [int64]$summary.deadline_contract.rejected_us -eq 30000001) `
    'R19 30-second inclusive deadline contract is absent.'
Assert-Condition ([string]$summary.one_run_claim.result -ceq 'PASS' -and
    [bool]$summary.one_run_claim.atomic_create_new -and
    [string]$summary.one_run_claim.replay_attempt_result -ceq 'REJECTED' -and
    [string]$summary.one_run_claim.flash_record_sha256 -cmatch
      '^[0-9A-F]{64}$' -and
    [string]$summary.one_run_claim.claim_sha256 -cmatch '^[0-9A-F]{64}$') `
    'R19 offline self-test did not prove atomic one-run anti-replay.'
Assert-Condition ([string]$summary.r19_flash_provenance.authorization.result `
      -ceq 'PASS' -and
    [string]$summary.r19_flash_provenance.authorization.scope -ceq
      'one immediate R19 physical acceptance run only' -and
    -not [bool]$summary.r19_flash_provenance.authorization.reusable -and
    [string]$summary.r19_flash_provenance.authorization.
      operator_safety_attestation_sha256 -cmatch '^[0-9A-F]{64}$') `
    'R19 offline self-test did not preserve the operator safety authorization.'

$eligibility = $summary.diagnostic_build_eligibility_contract
Assert-Condition ($null -ne $eligibility -and
    [string]$eligibility.result -ceq 'PASS' -and
    [bool]$eligibility.explicit_disabled_accepted -and
    [bool]$eligibility.missing_flag_rejected -and
    [bool]$eligibility.enabled_flag_rejected -and
    [int]$eligibility.artifact_record_count -eq 4 -and
    [int]$eligibility.artifact_negative_probe_count -eq 24 -and
    [int]$eligibility.artifact_negative_rejected_count -eq 24 -and
    -not [bool]$eligibility.diagnostic_build_acceptance_eligible) `
    'Diagnostic-enabled or unlabelled R19 builds remain acceptance-eligible.'

$diagnostic = $summary.runtime_failure_diagnostic_contract
Assert-Condition ($null -ne $diagnostic -and
    [string]$diagnostic.result -ceq 'PASS' -and
    [string]$diagnostic.prefix -ceq 'R19F:' -and
    [int]$diagnostic.message_id -eq 253 -and
    [int]$diagnostic.system_id -eq 254 -and
    [int]$diagnostic.component_id -eq 190 -and
    [int]$diagnostic.payload_length -eq 51 -and
    [int]$diagnostic.wire_length -eq 63 -and
    [string]$diagnostic.valid_frame_acceptance_result -ceq
      'FAIL_RUNTIME_DIAGNOSTIC_OBSERVED' -and
    [string]$diagnostic.invalid_frame_acceptance_result -ceq
      'FAIL_INVALID_RUNTIME_DIAGNOSTIC' -and
    [bool]$diagnostic.source_mapping_required -and
    [bool]$diagnostic.raw_frame_evidence_required) `
    'R19 runtime-failure diagnostic contract is absent or fail-open.'
$diagnosticTests = @($diagnostic.tests | ForEach-Object {[string]$_.name})
foreach ($requiredTest in @(
    'r19f_valid_frame_decodes_and_forces_acceptance_fail',
    'r19f_bad_crc_is_not_diagnostic_success',
    'r19f_bad_format_is_not_diagnostic_success',
    'r19f_source_hash_mismatch_is_not_diagnostic_success')) {
  Assert-Condition ($diagnosticTests -ccontains $requiredTest) `
      "R19 diagnostic offline proof is missing: $requiredTest"
}

$sealPath = Join-Path $offlineRoot 'final_seal.json'
Assert-Condition (Test-Path -LiteralPath $sealPath -PathType Leaf) `
    'R19 runner final seal is missing.'
$seal = Get-Content -LiteralPath $sealPath -Raw | ConvertFrom-Json
Assert-Condition ([string]$seal.one_run_claim_sha256 -ceq
      [string]$summary.one_run_claim.claim_sha256 -and
    [string]$seal.flash_record_sha256 -ceq
      [string]$summary.one_run_claim.flash_record_sha256) `
    'R19 runner final seal did not bind the one-run claim and flash record.'

Write-Output ("R19-PIXHAWK-PARAM-LIST-E2E-RUNNER-CONTRACT-001 PASS " +
    "evidence=$offlineRoot")
exit 0
