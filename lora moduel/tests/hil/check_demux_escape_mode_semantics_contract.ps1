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
      "runs\contracts\HIL-DEMUX-ESCAPE-MODE-SEMANTICS-001\$stamp"
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite evidence: $OutputDirectory"
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)

$runnerPath = Join-Path $RepoRoot 'tools\run_dual_diag_param_list_hil.ps1'
$bridgePath = Join-Path $RepoRoot `
    'vc_lora_ground_diag_v2_stable_xiao_esp32s3\vc_lora_phase6_bridge.hpp'
$diagPath = Join-Path $RepoRoot `
    'vc_lora_ground_diag_v2_stable_xiao_esp32s3\vc_lora_ground_diag.hpp'
$runner = [IO.File]::ReadAllText($runnerPath)
$bridge = [IO.File]::ReadAllText($bridgePath)
$diag = [IO.File]::ReadAllText($diagPath)

$checks = @(
  [pscustomobject][ordered]@{
    name='ground_demux_constructed_with_escape_mode_enabled'
    valid=($bridge -match 'TddLinkDemux\s+radio_demux\s*\(\s*true\s*\)')
  },
  [pscustomobject][ordered]@{
    name='rfdmesc_reports_configuration_not_pending_state'
    valid=($diag -match '(?s)radio_demux_escaping\s*=\s*radio_demux\.link_data_escaping\s*\(\s*\)\s*\?\s*1U\s*:\s*0U')
  },
  [pscustomobject][ordered]@{
    name='baseline_requires_escape_mode_enabled'
    valid=($runner -match "@\('ground_radio_demux_escape_mode_enabled'\s*,\s*\`$GroundSnapshot\s*,\s*'rfdmesc'\s*,\s*\[uint64\]1\)")
  },
  [pscustomobject][ordered]@{
    name='baseline_requires_demux_buffer_empty'
    valid=($runner -match "@\('ground_radio_demux_buffer_empty'\s*,\s*\`$GroundSnapshot\s*,\s*'rfdmbuf'\s*,\s*\[uint64\]0\)")
  },
  [pscustomobject][ordered]@{
    name='post_requires_escape_mode_enabled'
    valid=($runner -match "ground_radio_demux_escape_mode_enabled_post[\s\S]{0,300}'rfdmesc'[\s\S]{0,300}\[uint64\]1")
  },
  [pscustomobject][ordered]@{
    name='post_requires_demux_buffer_empty'
    valid=($runner -match "ground_radio_demux_buffer_empty_post[\s\S]{0,200}'rfdmbuf'[\s\S]{0,200}\[uint64\]0")
  },
  [pscustomobject][ordered]@{
    name='offline_valid_fixture_uses_enabled_mode'
    valid=($runner -match 'rfdmesc\s*=\s*1')
  },
  [pscustomobject][ordered]@{
    name='disabled_mode_is_negative_fixture'
    valid=($runner -match "@\('rfdmesc'\s*,\s*\[uint64\]0\)")
  },
  [pscustomobject][ordered]@{
    name='live_progress_records_demux_diagnosis'
    valid=($runner -match '(?s)backlog_drain_progress[\s\S]{0,700}failed_check_names[\s\S]{0,700}rfdmbuf[\s\S]{0,300}rfdmesc')
  },
  [pscustomobject][ordered]@{
    name='baseline_demux_faults_have_dynamic_negative_cases'
    valid=($runner -match "Add-SelfCase\s+'baseline_demux_buffer_nonzero_rejected'" -and
      $runner -match "Add-SelfCase\s+'baseline_demux_escape_mode_disabled_rejected'")
  }
)
$failed = @($checks | Where-Object { -not $_.valid })
$summary = [ordered]@{
  schema_version=1
  test='HIL-DEMUX-ESCAPE-MODE-SEMANTICS-001'
  result=if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
  finished_utc=[DateTime]::UtcNow.ToString('o')
  hardware_interaction=$false
  checks=$checks
  failures=@($failed | ForEach-Object { $_.name })
  runner_sha256=(Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash
}
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText(
    (Join-Path $OutputDirectory 'summary.json'),
    (($summary | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8)
if ($failed.Count -ne 0) {
  Write-Host "FAIL HIL-DEMUX-ESCAPE-MODE-SEMANTICS-001 failures=$($failed.Count)"
  exit 1
}
Write-Host 'PASS HIL-DEMUX-ESCAPE-MODE-SEMANTICS-001'
