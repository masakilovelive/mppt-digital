param(
  [Parameter(Mandatory = $true)]
  [string]$DecisionInputPath,
  [string]$OutputRoot,
  [string]$PolicyPath,
  [switch]$EnableNetwork
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $repoRoot 'runs\decision'
}
if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
  $PolicyPath = Join-Path $repoRoot 'tools\jev_advisor\policies\r19_actions.json'
}

$runnerArguments = @(
  '-3.12',
  '-m', 'tools.jev_advisor.src.run_shadow',
  '--input', [IO.Path]::GetFullPath($DecisionInputPath),
  '--output-root', [IO.Path]::GetFullPath($OutputRoot),
  '--policy', [IO.Path]::GetFullPath($PolicyPath)
)
if ($EnableNetwork) {
  $runnerArguments += '--enable-network'
}

Push-Location $repoRoot
try {
  & py @runnerArguments
  $runnerExitCode = $LASTEXITCODE
}
finally {
  Pop-Location
}
exit $runnerExitCode

