[CmdletBinding()]
param([string]$OriginalRepoRoot='E:/VESC/TRIAL_LOG/Loreley3_System/06_vc_lora_bridge',[string]$PublicationRoot='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($PublicationRoot)){$PublicationRoot=Split-Path -Parent $PSScriptRoot}
$pub=(Resolve-Path -LiteralPath $PublicationRoot).Path
$original=(Resolve-Path -LiteralPath $OriginalRepoRoot).Path
$checks=0
function Need([bool]$Value,[string]$Message){$script:checks++;if(-not$Value){throw $Message}}
function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
$inventoryPath=Join-Path $pub 'source_inventory.json'
$inventory=Get-Content -LiteralPath $inventoryPath -Raw|ConvertFrom-Json
Need ($inventory.candidate_id-ceq'20261024T134821302Z-9e36e182') 'Publication candidate identity differs'
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($entry in $inventory.files){
  $from=[IO.Path]::GetFullPath((Join-Path $original $entry.source));$to=[IO.Path]::GetFullPath((Join-Path $pub $entry.destination))
  Need ($from.StartsWith($original+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)-and$to.StartsWith($pub+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)) 'Inventory path escaped explicit roots'
  Need ($seen.Add($entry.destination)-and$entry.representation-ceq'BYTE_IDENTICAL_ORIGINAL') 'Duplicate/non-original source inventory record'
  Need ((Get-Item -LiteralPath $to).Length-eq$entry.bytes-and(Sha $to)-ceq$entry.sha256-and(Sha $from)-ceq$entry.sha256) ('Original/source copy differs: '+$entry.destination)
}
$jsonCount=0;$textCount=0
$patterns=@(
  'vck_[A-Za-z0-9_-]{24,}',
  'sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}',
  'gh[pousr]_[A-Za-z0-9]{30,}',
  'github_pat_[A-Za-z0-9_]{30,}',
  'AKIA[0-9A-Z]{16}',
  '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
  'https?://[^\s/@:]+:[^\s/@]+@github\.com'
)
$binAllowed='^evidence/trial/(capture/(vehicle|ground)\.raw\.bin|stage_(vehicle|ground)/((runtime-stage|endpoint-fifo|hwcdc-restart|ground-usb-commit|first-usb-failure)-(first|second)|(timed_path|aux_readiness|diagnostic_usb_failure|grant_diagnostic)_(first|second))\.bin)$'
foreach($file in Get-ChildItem -LiteralPath $pub -Recurse -Force -File){
  $rel=$file.FullName.Substring($pub.Length+1).Replace('\','/')
  Need ($file.Extension-notin@('.exe','.dll','.elf','.map','.zip','.uf2','.pdb','.pem','.key')-and$file.Name-notmatch'(?i)^(\.env(?:\..*)?|credentials|execution-permit.*|one_time_dispatch.*)$') ('Forbidden publication file: '+$rel)
  if($file.Extension-ceq'.bin'){Need ($rel-cmatch$binAllowed) ('Only raw transport/fixed-record BINs are allowed: '+$rel);continue}
  if($file.Extension-ceq'.json'){$null=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json;$jsonCount++}
  if($file.Extension-in@('.cpp','.hpp','.h','.c','.cs','.ino','.py','.ps1','.json','.log','.txt','.md','.patch','.diff')){
    $text=[string](Get-Content -LiteralPath $file.FullName -Raw);$textCount++
    foreach($pattern in $patterns){Need (-not[regex]::IsMatch($text,$pattern)) ('Credential-like value detected; inspect privately before publication: '+$rel)}
  }
}
$moduleRoot=[IO.Path]::GetFullPath((Join-Path $pub '../../..'))
$linkCount=0
foreach($doc in @((Join-Path $pub 'README.md'),(Join-Path $moduleRoot 'README.md'))){
  $text=Get-Content -LiteralPath $doc -Raw
  foreach($match in [regex]::Matches($text,'\[[^\]]+\]\(([^)]+)\)')){
    $target=$match.Groups[1].Value
    if($target-match'^(https?://|#)'){continue}
    $target=$target.Split('#')[0];$resolved=[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $doc) $target))
    Need (Test-Path -LiteralPath $resolved) ('Broken local Markdown link in '+$doc+': '+$target);$linkCount++
  }
}
$trial=Get-Content -LiteralPath (Join-Path $pub 'evidence/fallback_fix/trial_evaluation.json') -Raw|ConvertFrom-Json
Need ($trial.measurement.pc_param_request_attempts-eq1-and$trial.measurement.unique_param_values_at_30_seconds-eq4-and$trial.measurement.unique_param_values_at_measurement_end-eq6-and$trial.measurement.pc_observed_product_heartbeats-eq37-and$trial.measurement.maximum_inter_heartbeat_gap_ms-eq2099.9267) 'Published metrics differ from reviewed trial'
Need (-not$trial.target_assessment.R19_high_speed_negotiation_succeeded-and-not$trial.target_assessment.full_acceptance-and$trial.restoration.accepted_R18_restore_proven_by_parent) 'Publication must not upgrade fallback to high-speed acceptance'
Need ((Sha (Join-Path $pub 'source_snapshot/firmware/phase6/vc_lora_phase6_bridge.hpp'))-ceq$trial.bridge_sha256) 'Copied source does not match actual tested candidate'
$hostLog=Get-Content -LiteralPath (Join-Path $pub 'evidence/fallback_fix/host_suite_final_windows_ps51.log') -Raw
Need ($hostLog.Contains('100% tests passed, 0 tests failed out of 430')) 'Original full430 test evidence missing'
$snap=Get-Content -LiteralPath (Join-Path $pub 'validation/snapshot_tests/summary.json') -Raw|ConvertFrom-Json
Need ($snap.result-ceq'PASS_SELECTED_SNAPSHOT_CPP_TESTS_NOT_FULL_SUITE'-and$snap.ctest_exit_code-eq0-and$snap.tests_passed-eq18-and$snap.tests_failed-eq0) 'Selected snapshot18 tests did not pass'
[pscustomobject][ordered]@{
  schema='vc-lora-pregrant-publication-validation-v1';result='PASS_PUBLICATION_CHECKS_NOT_PRODUCT_ACCEPTANCE'
  checks=$checks;original_files=$inventory.files.Count;original_bytes=($inventory.files|Measure-Object bytes -Sum).Sum
  inventory_sha256=(Sha $inventoryPath);json_files_parsed=$jsonCount;text_files_credential_scanned=$textCount
  credential_pattern_findings=0;local_markdown_links_checked=$linkCount;forbidden_files=0
  original_workspace_host_tests=430;original_workspace_host_test_failures=0;original_workspace_vehicle_ground_diagnostic_builds='PASS'
  published_snapshot_tests_passed=18;published_snapshot_tests_failed=0
  full_430_tests_rerun_for_publication=$false;arduino_compilation_rerun_for_publication=$false
  hardware_interaction=$false;live_authorization_consumed=$false;acceptance_authorized=$false;deployment_authorized=$false
  source_scope='Selected sources including canonical candidate76 and host source129; identity-bound live tools and sealed binary/history dependencies omitted'
  limitations=@('Credential pattern checks are scoped checks, not a proof that arbitrary secrets cannot exist.','Candidate/restoration manifests refer to intentionally omitted binaries; this is not a flashable or complete sealed package.','PC paths and device identifiers remain in byte-identical experimental evidence.','The18 reproduced tests do not certify full430 clean-clone reproducibility or physical high-speed performance.')
}|ConvertTo-Json -Depth 8
