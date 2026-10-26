param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop'
$failures=0;$checks=0
foreach($path in @('tools/sync_arduino_sketch_core.ps1','tools/r19_candidate_artifact_common.ps1')) {
  $source=Get-Content -LiteralPath (Join-Path $RepoRoot $path) -Raw
  foreach($name in @('r19_first_usb_failure_record.hpp','r19_usb_clock_sync.hpp')) {
    ++$checks
    if(-not$source.Contains("'$name'")){++$failures;Write-Output "FAIL $path missing $name"}
  }
}
Write-Output "R19-FIRST-FAILURE-PACKAGING-001 checks=$checks failures=$failures"
if($failures-ne0){exit 1}
