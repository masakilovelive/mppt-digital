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
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $OutputDirectory = Join-Path $RepoRoot `
      "runs\contracts\HIL-PRE-REQUEST-ISOLATED-D7-RECHECK-001\$stamp"
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite evidence: $OutputDirectory"
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)

$runnerPath = Join-Path $RepoRoot 'tools\run_dual_diag_param_list_hil.ps1'
$diagPath = Join-Path $RepoRoot `
    'vc_lora_vehicle_diag_v2_stable_xiao_esp32s3\vc_lora_vehicle_diag.hpp'
$runner = [IO.File]::ReadAllText($runnerPath)
$diag = [IO.File]::ReadAllText($diagPath)
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $runnerPath, [ref]$tokens, [ref]$parseErrors)
function Get-FunctionText {
  param([string]$Name)
  $matches = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -ceq $Name
    }, $true))
  if ($matches.Count -ne 1) { return '' }
  return $matches[0].Extent.Text
}
$classifier = Get-FunctionText -Name `
    'Test-IsolatedPartialD7SnapshotRaceContract'
$obsoleteDirectRecheck = Get-FunctionText -Name `
    'Test-IsolatedPartialD7RecheckContract'
$disposition = Get-FunctionText -Name 'Get-PreRequestAttemptDisposition'
$gate = Get-FunctionText -Name 'Invoke-OfficialPreRequestGate'
$selfTest = Get-FunctionText -Name 'Invoke-OfflineSelfTest'

[string[]]$requiredSelfCases = @(
  'pre_request_isolated_partial_d7_attempt3_arms_extra_write0',
  'pre_request_isolated_partial_d7_bounds_and_fail_closed',
  'pre_request_isolated_partial_d7_dedicated_budget_single_use_write0',
  'pre_request_isolated_partial_d7_attempt4_clean_accept_write0',
  'pre_request_isolated_partial_d7_attempt4_nonclean_rejected_write0')
[bool]$selfCasesPresent = $true
foreach ($caseName in $requiredSelfCases) {
  if ([regex]::Matches($selfTest,
      "Add-SelfCase\s+'" + [regex]::Escape($caseName) + "'").Count -ne 1) {
    $selfCasesPresent = $false
  }
}

$checks = @(
  [pscustomobject][ordered]@{
    name='runner_parses_without_error'
    valid=(@($parseErrors).Count -eq 0)
  },
  [pscustomobject][ordered]@{
    name='d7pb_is_atomic_shadow_parser_buffered_size'
    valid=($diag -match '(?s)pixhawk_d7_parser_buffered\s*=\s*vc_lora_vehicle_diag_observer::pixhawk_d7_parser\.buffered_size\(\)')
  },
  [pscustomobject][ordered]@{
    name='isolated_classifier_is_exact_and_fail_closed'
    valid=([string]::IsNullOrEmpty($obsoleteDirectRecheck) -and
      $classifier -match
      '(?s)(?=.*requiredVehicleCheckNames)(?=.*failed.*d7pb_empty.*Count\s*-eq\s*1)(?=.*CausalGate.*valid)(?=.*m0_epoch_completed)(?=.*parser_integrity)(?=.*heartbeat)(?=.*events.*Count\s*-eq\s*0)(?=.*snapshots_complete)(?=.*d7pb.*(?:279|MaximumFrame))(?=.*d722)(?=.*pvok)(?=.*rf22)(?=.*pgq)(?=.*pga)(?=.*prq)(?=.*ptq)(?=.*pvs1)(?=.*d7cr)(?=.*d7_stream_active_and_monotonic)(?=.*valid)')
  },
  [pscustomobject][ordered]@{
    name='disposition_has_distinct_one_shot_action'
    valid=($disposition -match
      '(?s)IsolatedPartialD7ExtraRetryAvailable.*Test-IsolatedPartialD7SnapshotRaceContract.*MaxAttempts\s*-eq\s*3.*AttemptNumber\s*-eq\s*3.*RETRY_ISOLATED_D7PB.*isolated_partial_D7_snapshot_race.*fixture_write_count\s*=\s*0')
  },
  [pscustomobject][ordered]@{
    name='gate_consumes_one_token_and_reuses_full_bilateral_recovery'
    valid=($gate -match
      '(?s)isolatedPartialD7ExtraRetryLimit\s*=\s*1.*isolatedPartialD7ExtraRetryUsed.*isolatedPartialD7ExtraAttemptArmed.*RETRY_ISOLATED_D7PB.*Invoke-PreBaselineBacklogDrainGate.*Test-PreRequestRecoveryBacklogPairPromotion.*fixture_write_count\s*=\s*0')
  },
  [pscustomobject][ordered]@{
    name='gate_retains_three_general_attempts_one_extra_and_absolute_deadline'
    valid=($gate -match 'MaxAttempts\s*=\s*3' -and
      $gate -match 'isolatedPartialD7ExtraRetryLimit\s*=\s*1' -and
      $gate -match 'attempt\s*-lt\s*\$totalAttemptLimit' -and
      $gate -match 'total_attempt_limit' -and
      $gate -match 'DeadlineElapsedMs' -and
      $gate -match 'deadline_extended\s*=\s*\$false' -and
      $gate -notmatch '(?m)^\s*\$DeadlineElapsedMs\s*=' -and
      $gate -notmatch 'Write-ExactRequestOnce')
  },
  [pscustomobject][ordered]@{
    name='offline_positive_and_negative_cases_present'
    valid=$selfCasesPresent
  }
)
$failed = @($checks | Where-Object { -not $_.valid })
$summary = [ordered]@{
  schema_version=1
  test='HIL-PRE-REQUEST-ISOLATED-D7-RECHECK-001'
  result=if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
  finished_utc=[DateTime]::UtcNow.ToString('o')
  hardware_interaction=$false
  checks=$checks
  failures=@($failed | ForEach-Object { $_.name })
  runner_sha256=(Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash
  diagnostic_sha256=(Get-FileHash -LiteralPath $diagPath -Algorithm SHA256).Hash
}
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText(
    (Join-Path $OutputDirectory 'summary.json'),
    (($summary | ConvertTo-Json -Depth 7) + [Environment]::NewLine), $utf8)
if ($failed.Count -ne 0) {
  Write-Host "FAIL HIL-PRE-REQUEST-ISOLATED-D7-RECHECK-001 failures=$($failed.Count)"
  exit 1
}
Write-Host 'PASS HIL-PRE-REQUEST-ISOLATED-D7-RECHECK-001'
