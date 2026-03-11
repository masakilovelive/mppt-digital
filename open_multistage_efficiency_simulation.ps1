$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $root "multistage_efficiency_simulation.html"

if (-not (Test-Path -LiteralPath $target)) {
  Write-Error "File not found: $target"
  exit 1
}

Start-Process -FilePath $target
