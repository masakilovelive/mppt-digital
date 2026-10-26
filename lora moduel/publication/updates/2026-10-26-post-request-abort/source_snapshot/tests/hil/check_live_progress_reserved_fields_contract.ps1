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
      "runs\contracts\HIL-LIVE-PROGRESS-RESERVED-FIELDS-001\$stamp"
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite evidence: $OutputDirectory"
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)

$runnerPath = Join-Path $RepoRoot 'tools\run_dual_diag_param_list_hil.ps1'
$runner = [IO.File]::ReadAllText($runnerPath)
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $runnerPath, [ref]$tokens, [ref]$parseErrors)
$progressFunction = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -ceq 'Add-LiveProgressRecord'
    }, $true))
$progressCalls = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst] -and
          $node.GetCommandName() -ceq 'Add-LiveProgressRecord'
    }, $true))

[string[]]$reservedKeys = @('event','elapsed_s','utc','phase')
$collisions = New-Object 'System.Collections.Generic.List[object]'
foreach ($call in $progressCalls) {
  foreach ($table in @($call.CommandElements | Where-Object {
        $_ -is [Management.Automation.Language.HashtableAst]
      })) {
    foreach ($pair in $table.KeyValuePairs) {
      [string]$key = $pair.Item1.Extent.Text.Trim("'`"")
      if ($key -cin $reservedKeys) {
        $collisions.Add([pscustomobject][ordered]@{
          line=$pair.Item1.Extent.StartLineNumber
          key=$key
          call_line=$call.Extent.StartLineNumber
        })
      }
    }
  }
}

$functionText = if ($progressFunction.Count -eq 1) {
  $progressFunction[0].Extent.Text
} else { '' }
$checks = @(
  [pscustomobject][ordered]@{
    name='runner_parses_without_error'
    valid=(@($parseErrors).Count -eq 0)
  },
  [pscustomobject][ordered]@{
    name='one_live_progress_function'
    valid=($progressFunction.Count -eq 1)
  },
  [pscustomobject][ordered]@{
    name='reserved_keys_are_explicitly_guarded'
    valid=($functionText -match
      "(?s)reservedKeys\s*=\s*@\(\s*'event'\s*,\s*'elapsed_s'\s*,\s*'utc'\s*,\s*'phase'\s*\).*?-contains\s+\[string\]\s*\`$key.*?throw")
  },
  [pscustomobject][ordered]@{
    name='details_never_override_reserved_keys'
    valid=($collisions.Count -eq 0)
  },
  [pscustomobject][ordered]@{
    name='readiness_subphase_has_distinct_name'
    valid=($runner -match
      "(?s)data_plane_readiness_window[\s\S]{0,500}readiness_phase\s*=\s*'passive_prefilter'")
  },
  [pscustomobject][ordered]@{
    name='backlog_gate_elapsed_has_distinct_name'
    valid=($runner -match
      '(?s)backlog_drain_progress[\s\S]{0,700}gate_elapsed_s\s*=')
  },
  [pscustomobject][ordered]@{
    name='acquisition_elapsed_has_distinct_name'
    valid=($runner -match
      '(?s)Add-LiveProgressRecord\s+-Event\s+''progress''[\s\S]{0,300}acquisition_elapsed_s\s*=')
  },
  [pscustomobject][ordered]@{
    name='backlog_progress_records_demux_buffer_actual'
    valid=($runner -match
      '(?s)backlog_drain_progress[\s\S]{0,700}rfdmbuf\s*=\s*\$rfdmbuf\.value')
  }
)
$failed = @($checks | Where-Object { -not $_.valid })
$summary = [ordered]@{
  schema_version=1
  test='HIL-LIVE-PROGRESS-RESERVED-FIELDS-001'
  result=if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
  finished_utc=[DateTime]::UtcNow.ToString('o')
  hardware_interaction=$false
  checks=$checks
  failures=@($failed | ForEach-Object { $_.name })
  reserved_key_collisions=$collisions.ToArray()
  live_progress_call_count=$progressCalls.Count
  runner_sha256=(Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash
}
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText(
    (Join-Path $OutputDirectory 'summary.json'),
    (($summary | ConvertTo-Json -Depth 8) + [Environment]::NewLine), $utf8)
if ($failed.Count -ne 0) {
  Write-Host "FAIL HIL-LIVE-PROGRESS-RESERVED-FIELDS-001 failures=$($failed.Count) collisions=$($collisions.Count)"
  exit 1
}
Write-Host 'PASS HIL-LIVE-PROGRESS-RESERVED-FIELDS-001'
