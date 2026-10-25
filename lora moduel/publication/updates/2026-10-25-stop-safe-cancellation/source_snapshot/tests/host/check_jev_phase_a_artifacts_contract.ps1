param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath($RepoRoot)

function Assert-Contract([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw "JEV-PHASE-A-CONTRACT: $Message"
  }
}

function Read-JsonObject([string]$Path) {
  Assert-Contract (Test-Path -LiteralPath $Path -PathType Leaf) `
    "missing artifact: $Path"
  try {
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path |
      ConvertFrom-Json
  }
  catch {
    throw "JEV-PHASE-A-CONTRACT: invalid JSON in ${Path}: $($_.Exception.Message)"
  }
}

function Assert-ExactSet([object[]]$Actual, [string[]]$Expected,
                         [string]$Label) {
  $actualValues = @($Actual | ForEach-Object { [string]$_ } | Sort-Object -Unique)
  $expectedValues = @($Expected | Sort-Object -Unique)
  Assert-Contract ($actualValues.Count -eq $expectedValues.Count) `
    "$Label count mismatch: actual=$($actualValues.Count) expected=$($expectedValues.Count)"
  Assert-Contract ((Compare-Object $actualValues $expectedValues).Count -eq 0) `
    "$Label mismatch"
}

$schemaDir = Join-Path $repo 'tools\jev_advisor\schemas'
$policyDir = Join-Path $repo 'tools\jev_advisor\policies'
$decisionPath = Join-Path $schemaDir 'r19_decision_input.schema.json'
$measurementPath = Join-Path $schemaDir 'token_measurement.schema.json'
$policyPath = Join-Path $policyDir 'r19_actions.json'

$decision = Read-JsonObject $decisionPath
$measurement = Read-JsonObject $measurementPath
$policy = Read-JsonObject $policyPath

$draft = 'https://json-schema.org/draft/2020-12/schema'
Assert-Contract ($decision.'$schema' -ceq $draft) `
  'decision input must use JSON Schema draft 2020-12'
Assert-Contract ($measurement.'$schema' -ceq $draft) `
  'token measurement must use JSON Schema draft 2020-12'
Assert-Contract ($decision.type -ceq 'object' -and
  $decision.additionalProperties -eq $false) `
  'decision input must be a closed object'
Assert-Contract ($measurement.type -ceq 'object' -and
  $measurement.additionalProperties -eq $false) `
  'token measurement must be a closed object'

$decisionRequired = @(
  'schema_version', 'run_id', 'source_manifest', 'source_hash', 'test_scope',
  'evidence_scope',
  'host_tests_passed', 'host_tests_failed', 'sanitizer_errors',
  'failed_test_ids',
  'expected_params', 'received_params', 'first_missing_index',
  'completion_ms', 'heartbeat_count', 'heartbeat_first_ms', 'heartbeat_max_ms',
  'heartbeat_post_ms', 'missing_params', 'duplicate_params',
  'out_of_order_params', 'crc_errors', 'parser_errors', 'partial_frames',
  'control_leakage', 'retry_identity_status',
  'standard_grant_handoff_status', 'direction_guard_status',
  'physical_tail_status', 'vcta_physical_drain_status',
  'live_flash_authorized', 'hardware_operation_requested',
  'communication_parameter_change_requested',
  'acceptance_relaxation_requested'
)
Assert-ExactSet @($decision.required) $decisionRequired `
  'decision required fields'
Assert-Contract ($decision.properties.schema_version.const -ceq
  'r19-jev-input-2') 'decision schema version is not pinned'
Assert-Contract ([int]$decision.properties.expected_params.const -eq 932) `
  'expected PARAM_VALUE count must remain exactly 932'
Assert-Contract ($decision.properties.source_hash.pattern -ceq
  '^[A-Fa-f0-9]{64}$') 'source_hash must be a SHA-256 hex digest'
Assert-ExactSet @($decision.properties.test_scope.enum) @('host', 'hil') `
  'decision test_scope values'
Assert-ExactSet @($decision.properties.evidence_scope.enum) `
  @('host_model', 'hil_physical') 'decision evidence_scope values'
Assert-Contract ($decision.properties.source_manifest.type -ceq 'array' -and
  [int]$decision.properties.source_manifest.minItems -eq 1 -and
  [int]$decision.properties.source_manifest.maxItems -eq 64 -and
  $decision.properties.source_manifest.uniqueItems -eq $true) `
  'source_manifest must be explicit, bounded, and non-empty'
$manifestItem = $decision.properties.source_manifest.items
Assert-Contract ($manifestItem.type -ceq 'object' -and
  $manifestItem.additionalProperties -eq $false) `
  'source_manifest entries must be closed objects'
Assert-ExactSet @($manifestItem.required) @('path', 'sha256') `
  'source_manifest item required fields'
Assert-Contract ($manifestItem.properties.path.pattern -ceq
  '^(?!/)(?!.*(?:^|/)\.{1,2}(?:/|$))(?!.*[\\*?\[\]])[^/\\]+(?:/[^/\\]+)*$') `
  'source_manifest path must reject absolute, traversal, glob, and backslash paths'
Assert-Contract ($manifestItem.properties.sha256.pattern -ceq
  '^[A-Fa-f0-9]{64}$') `
  'source_manifest file digest must be SHA-256 hex'
Assert-Contract ($decision.properties.failed_test_ids.type -ceq 'array' -and
  [int]$decision.properties.failed_test_ids.maxItems -eq 64 -and
  $decision.properties.failed_test_ids.uniqueItems -eq $true) `
  'failed_test_ids must be bounded and unique'

foreach ($name in @(
    'host_tests_passed', 'host_tests_failed', 'sanitizer_errors',
    'received_params', 'missing_params', 'duplicate_params',
    'out_of_order_params', 'crc_errors', 'parser_errors', 'partial_frames',
    'control_leakage')) {
  $property = $decision.properties.$name
  Assert-Contract ($property.type -ceq 'integer' -and
    [int]$property.minimum -eq 0) "$name must be a non-negative integer"
}
Assert-Contract ($decision.properties.heartbeat_count.type -ceq 'integer' -and
  [int]$decision.properties.heartbeat_count.minimum -eq 1) `
  'heartbeat_count must require at least one measured Heartbeat'
foreach ($name in @(
    'completion_ms', 'heartbeat_first_ms', 'heartbeat_max_ms',
    'heartbeat_post_ms')) {
  Assert-Contract ($decision.properties.$name.type -ceq 'number' -and
    $decision.properties.$name.exclusiveMinimum -eq 0) `
    "$name must be a positive measured number"
}
foreach ($name in @(
    'live_flash_authorized', 'hardware_operation_requested',
    'communication_parameter_change_requested',
    'acceptance_relaxation_requested')) {
  Assert-Contract ($decision.properties.$name.type -ceq 'boolean') `
    "$name must be boolean"
}
Assert-ExactSet @($decision.'$defs'.evidenceStatus.enum) `
  @('proven', 'disproven', 'unknown') 'evidence status values'
foreach ($name in @(
    'retry_identity_status', 'standard_grant_handoff_status',
    'direction_guard_status', 'physical_tail_status',
    'vcta_physical_drain_status')) {
  Assert-Contract ($decision.properties.$name.'$ref' -ceq
    '#/$defs/evidenceStatus') "$name must use the closed evidence status"
}
$scopeRule = @($decision.allOf | Where-Object { $null -ne $_.oneOf })[0]
Assert-Contract ($null -ne $scopeRule -and @($scopeRule.oneOf).Count -eq 2) `
  'test_scope and evidence_scope must be linked by a two-branch rule'
$scopePairs = @($scopeRule.oneOf | ForEach-Object {
    "$($_.properties.test_scope.const):$($_.properties.evidence_scope.const)"
  })
Assert-ExactSet $scopePairs @('host:host_model', 'hil:hil_physical') `
  'test/evidence scope pairs'

$measurementRequired = @(
  'measurement_schema', 'run_id', 'issue_id', 'mode', 'source_hash',
  'codex_model', 'reasoning_effort', 'codex_called', 'jev_called', 'input_tokens',
  'cached_input_tokens', 'output_tokens', 'total_tokens',
  'jev_input_tokens', 'jev_output_tokens', 'action_id', 'confidence',
  'route_correct', 'accepted_fix', 'human_adjudication_id', 'adjudicated_at',
  'retry_count', 'safety_violation', 'elapsed_seconds',
  'codex_credits', 'jev_cost_usd', 'usage_source', 'rate_card_version',
  'jev_generation_id', 'rate_card_hash', 'rate_card_source',
  'rate_card_retrieved_at', 'measured_at'
)
Assert-ExactSet @($measurement.required) $measurementRequired `
  'measurement required fields'
Assert-Contract ($measurement.properties.measurement_schema.const -ceq
  'jev-token-eval-2') 'measurement schema version is not pinned'
Assert-ExactSet @($measurement.properties.mode.enum) `
  @('baseline_codex', 'jev_hybrid') 'measurement modes'
Assert-ExactSet @($measurement.properties.usage_source.enum) `
  @('api_exact', 'dashboard_batch', 'estimated') `
  'measurement usage sources'
Assert-ExactSet @($measurement.properties.confidence.type) `
  @('number', 'null') 'nullable confidence types'
Assert-Contract ($measurement.properties.confidence.minimum -eq 0 -and
  $measurement.properties.confidence.maximum -eq 1) `
  'non-null confidence must be in the inclusive range 0..1'
Assert-Contract ($measurement.properties.measured_at.format -ceq
  'date-time') 'measured_at must use the date-time format'
Assert-Contract ($measurement.properties.rate_card_retrieved_at.format -ceq
  'date-time' -and $measurement.properties.adjudicated_at.format -ceq
  'date-time') 'measurement provenance timestamps must use date-time'
Assert-Contract ($measurement.properties.rate_card_hash.pattern -ceq
  '^[A-Fa-f0-9]{64}$' -and
  $measurement.properties.rate_card_source.format -ceq 'uri' -and
  $measurement.properties.rate_card_source.pattern -ceq '^https://') `
  'rate-card provenance must be a hashed HTTPS source'
foreach ($name in @(
    'input_tokens', 'cached_input_tokens', 'output_tokens', 'total_tokens',
    'jev_input_tokens', 'jev_output_tokens', 'retry_count')) {
  $property = $measurement.properties.$name
  Assert-Contract ($property.type -ceq 'integer' -and
    [int]$property.minimum -eq 0) "$name must be a non-negative integer"
}
foreach ($name in @('elapsed_seconds', 'codex_credits', 'jev_cost_usd')) {
  Assert-Contract ($measurement.properties.$name.minimum -eq 0) `
    "$name must be non-negative"
}
$notCalledRule = @($measurement.allOf)[0]
Assert-Contract ($notCalledRule.if.properties.codex_called.const -eq $false) `
  'the zero-usage rule must select codex_called=false'
foreach ($name in @(
    'input_tokens', 'cached_input_tokens', 'output_tokens', 'total_tokens',
    'codex_credits')) {
  Assert-Contract ($notCalledRule.then.properties.$name.const -eq 0) `
    "$name must be zero when Codex is not called"
}
$jevNotCalledRule = @($measurement.allOf)[1]
Assert-Contract ($jevNotCalledRule.if.properties.jev_called.const -eq $false) `
  'the Jev zero-usage rule must select jev_called=false'
foreach ($name in @('jev_input_tokens', 'jev_output_tokens', 'jev_cost_usd')) {
  Assert-Contract ($jevNotCalledRule.then.properties.$name.const -eq 0) `
    "$name must be zero when Jev is not called"
}
foreach ($name in @('action_id', 'confidence', 'jev_generation_id')) {
  Assert-Contract ($null -eq $jevNotCalledRule.then.properties.$name.const) `
    "$name must be null when Jev is not called"
}
$jevExactRule = @($measurement.allOf)[2]
Assert-Contract ($jevExactRule.if.properties.jev_called.const -eq $true -and
  $jevExactRule.if.properties.usage_source.const -ceq 'api_exact' -and
  $jevExactRule.then.properties.jev_generation_id.type -ceq 'string') `
  'exact Jev API usage must carry a provider generation receipt'
$adjudicationRule = @($measurement.allOf)[3]
Assert-Contract ($adjudicationRule.then.properties.human_adjudication_id.type `
  -ceq 'string' -and
  $adjudicationRule.then.properties.adjudicated_at.type -ceq 'string') `
  'non-null human judgments must carry adjudication provenance'

$expectedActions = @(
  'RUN_FOCUSED_GRANT_TEST',
  'RUN_DIRECTION_GUARD_TEST',
  'INSPECT_FINAL_VCB1_TAIL',
  'INSPECT_VCTA_PHYSICAL_DRAIN',
  'COLLECT_MORE_EVIDENCE',
  'CODE_REVIEW_REQUIRED',
  'HUMAN_REVIEW_REQUIRED',
  'STOP_SAFETY_CONDITION'
)
$measurementActions = @($measurement.properties.action_id.enum |
  Where-Object { $null -ne $_ })
Assert-ExactSet $measurementActions $expectedActions `
  'measurement action IDs'
Assert-Contract (@($measurement.properties.action_id.type) -contains 'null' `
  -and @($measurement.properties.action_id.enum) -contains $null) `
  'action_id must support fixed local runs without a Jev action'
foreach ($name in @('route_correct', 'accepted_fix')) {
  Assert-ExactSet @($measurement.properties.$name.type) `
    @('boolean', 'null') "nullable $name types"
}
Assert-Contract ($policy.policy_version -ceq 'r19-actions-2') `
  'action policy version is not pinned'
Assert-Contract ($policy.input_schema_version -ceq 'r19-jev-input-2') `
  'policy input schema version mismatch'
Assert-Contract ($policy.measurement_schema_version -ceq
  'jev-token-eval-2') 'policy measurement schema version mismatch'
Assert-Contract ($policy.phase_a.mode -ceq 'shadow_evaluation' -and
  $policy.phase_a.execute_actions -eq $false) `
  'Phase A must be shadow-only and must not execute actions'
Assert-Contract ($policy.phase_a.hardware_access_allowed -eq $false -and
  $policy.phase_a.com_access_allowed -eq $false -and
  $policy.phase_a.firmware_write_allowed -eq $false) `
  'Phase A must not access hardware, COM, or firmware writes'
Assert-Contract ($policy.phase_a.human_decision_comparison_required -eq $true `
  -and $policy.phase_a.token_savings_are_simulated -eq $true) `
  'Phase A must retain human comparison and simulated-only savings'

Assert-Contract ([int]$policy.fixed_acceptance.expected_params -eq 932) `
  'policy must preserve exact 932 parameters'
Assert-Contract ([int]$policy.fixed_acceptance.max_elapsed_ms -eq 30000) `
  'policy must preserve the 30,000 ms deadline'
Assert-Contract ([int]$policy.fixed_acceptance.max_heartbeat_gap_ms -eq
  2500) 'policy must preserve the 2,500 ms heartbeat limit'
Assert-Contract ([int]$policy.fixed_acceptance.minimum_heartbeat_samples -eq
  1) 'policy must require measured Heartbeat evidence'
Assert-Contract ([int]$policy.fixed_acceptance.max_error_count -eq 0) `
  'policy must not permit errors'
Assert-Contract ($policy.fixed_acceptance.live_flash_requires_explicit_authorization `
  -eq $true) 'live flash must require explicit authorization'
Assert-Contract ($policy.fixed_acceptance.rejected_write_preserves_bytes_and_accounting `
  -eq $true) 'rejected writes must preserve bytes and accounting'
Assert-Contract ($policy.fixed_acceptance.full_acceptance_evidence_scope -ceq
  'hil_physical' -and
  $policy.fixed_acceptance.host_model_success_verdict -ceq
  'PASS_HOST_MODEL' -and
  $policy.fixed_acceptance.hil_physical_success_verdict -ceq 'PASS_FIXED') `
  'host-model success must never be reported as physical acceptance'

$actualActions = @($policy.actions | ForEach-Object { $_.action_id })
Assert-ExactSet $actualActions $expectedActions 'policy action IDs'
Assert-Contract (@($policy.actions).Count -eq $expectedActions.Count) `
  'policy action IDs must be unique'
$actionContracts = @{
  'RUN_FOCUSED_GRANT_TEST' = @(
    'GRANT_HANDOFF_SUSPECTED', 'focused_host_test', $true, $false, $false)
  'RUN_DIRECTION_GUARD_TEST' = @(
    'DIRECTION_GUARD_BOUNDARY_SUSPECTED', 'focused_host_test',
    $true, $false, $false)
  'INSPECT_FINAL_VCB1_TAIL' = @(
    'FINAL_VCB1_TAIL_UNPROVEN', 'read_only_inspection',
    $true, $false, $false)
  'INSPECT_VCTA_PHYSICAL_DRAIN' = @(
    'VCTA_PHYSICAL_DRAIN_UNPROVEN', 'read_only_inspection',
    $true, $false, $false)
  'COLLECT_MORE_EVIDENCE' = @(
    'EVIDENCE_INSUFFICIENT_OR_LOW_CONFIDENCE', 'evidence_request',
    $false, $false, $true)
  'CODE_REVIEW_REQUIRED' = @(
    'UNKNOWN_OR_SOURCE_LEVEL_DEFECT', 'codex_escalation',
    $false, $true, $true)
  'HUMAN_REVIEW_REQUIRED' = @(
    'AUTHORIZATION_OR_AMBIGUOUS_OPERATION_REQUIRED', 'human_escalation',
    $false, $false, $true)
  'STOP_SAFETY_CONDITION' = @(
    'SAFETY_RULE_OR_FIXED_ACCEPTANCE_VIOLATION', 'safety_stop',
    $false, $false, $true)
}
foreach ($action in @($policy.actions)) {
  $expectedAction = $actionContracts[[string]$action.action_id]
  Assert-Contract ($action.cause_id -ceq $expectedAction[0] -and
    $action.category -ceq $expectedAction[1] -and
    $action.future_high_confidence_candidate -eq $expectedAction[2] -and
    $action.requires_codex -eq $expectedAction[3] -and
    $action.requires_human -eq $expectedAction[4]) `
    "$($action.action_id) semantics changed"
  Assert-Contract ($action.phase_a_effect -ceq 'record_only') `
    "$($action.action_id) must remain record-only in Phase A"
  Assert-Contract ($null -ne $action.context_allowlist) `
    "$($action.action_id) must have an explicit context allowlist"
  Assert-Contract (@($action.context_allowlist).Count -le
    [int]$policy.context_limits.max_optional_files) `
    "$($action.action_id) exceeds the bounded context file count"
  foreach ($allowedPath in @($action.context_allowlist)) {
    $candidate = [string]$allowedPath
    Assert-Contract (-not [string]::IsNullOrWhiteSpace($candidate) -and
      $candidate -notmatch '^(?:[A-Za-z]:|[\\/])' -and
      $candidate -notmatch '(^|[\\/])\.\.([\\/]|$)' -and
      $candidate -notmatch '[\\*?\[\]]') `
      "$($action.action_id) has an unsafe context path: $candidate"
    Assert-Contract ($candidate -notmatch
      '(?i)\.(?:log|tlog|trace|raw|bin|csv)$') `
      "$($action.action_id) allowlists a raw log: $candidate"
  }
}
Assert-Contract ($policy.context_limits.project_wide_source_upload_allowed `
  -eq $false -and $policy.context_limits.raw_log_upload_allowed -eq $false `
  -and $policy.context_limits.source_manifest_required -eq $true -and
  [int]$policy.context_limits.max_optional_files -eq 12) `
  'context policy must reject project-wide source and raw-log uploads'

$codeReview = @($policy.actions | Where-Object {
    $_.action_id -ceq 'CODE_REVIEW_REQUIRED'
  })[0]
Assert-Contract ($codeReview.requires_codex -eq $true) `
  'only the CODE_REVIEW_REQUIRED route may require Codex'
Assert-Contract (@($policy.actions | Where-Object {
      $_.action_id -cne 'CODE_REVIEW_REQUIRED' -and $_.requires_codex
    }).Count -eq 0) 'non-review actions must not require Codex'

Assert-Contract ($policy.confidence_routing.high.minimum -eq 0.90) `
  'high-confidence threshold must remain 0.90'
Assert-Contract ($policy.confidence_routing.review.minimum -eq 0.70 -and
  $policy.confidence_routing.review.maximum_exclusive -eq 0.90) `
  'review band must remain 0.70 <= confidence < 0.90'
Assert-Contract ($policy.confidence_routing.low.maximum_exclusive -eq
  0.70 -and $policy.confidence_routing.low.forced_action_id -ceq
  'COLLECT_MORE_EVIDENCE') 'low confidence must collect more evidence'
Assert-Contract ($policy.confidence_routing.api_failure.execute_action -eq
  $false) 'API failure must not execute an advised action'
Assert-Contract ($policy.confidence_routing.safety_condition.overrides_confidence `
  -eq $true -and
  $policy.confidence_routing.safety_condition.forced_action_id -ceq
  'STOP_SAFETY_CONDITION') 'safety stop must override confidence'

$expectedForbidden = @(
  'vehicle_ground_auto_flash',
  'automatic_com_operation',
  'e220_persistent_setting_change',
  'uart_air_rate_sub_packet_tdd_change',
  'live_flash_authorized_mutation',
  'acceptance_threshold_relaxation',
  'fixed_fail_override'
)
Assert-ExactSet @($policy.forbidden_operations) $expectedForbidden `
  'forbidden operations'

Write-Output 'JEV_PHASE_A_ARTIFACTS PASS schemas=2 actions=8 shadow_only=true'
