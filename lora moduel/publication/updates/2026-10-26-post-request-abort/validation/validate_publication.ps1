[CmdletBinding()]
param([string]$OriginalRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=(Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
$project=(Resolve-Path -LiteralPath (Join-Path $root '../../..')).Path
$script:checks=0
function Check([bool]$Value,[string]$Message){$script:checks++;if(-not$Value){throw $Message}}
function Read-Json([string]$Relative){Get-Content -LiteralPath (Join-Path $root $Relative) -Raw -Encoding UTF8 | ConvertFrom-Json}
$inventory=Read-Json 'source_inventory.json'
Check ($inventory.current_source_freeze_count-eq606) 'Expected606 verification inputs'
Check ($inventory.source_frozen_inputs_published-eq584) 'Expected584 selected frozen inputs'
Check (@($inventory.excluded_generated_frozen_inputs).Count-eq22) 'Expected22 generated exclusions'
Check ($inventory.copied_original_count-eq764) 'Expected764 selected original files'
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$originalChecks=0
foreach($item in $inventory.files){
  $path=[IO.Path]::GetFullPath((Join-Path $root ([string]$item.target)))
  Check ($path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Inventory target stays inside update'
  Check ($seen.Add([string]$item.target)) 'Inventory targets are unique'
  Check (Test-Path -LiteralPath $path -PathType Leaf) ('Missing selected file: '+$item.target)
  Check ((Get-Item -LiteralPath $path).Length-eq[long]$item.bytes) ('Size mismatch: '+$item.target)
  Check ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash-ceq[string]$item.sha256) ('SHA mismatch: '+$item.target)
  if($OriginalRoot){
    $source=Join-Path $OriginalRoot ([string]$item.source)
    Check (Test-Path -LiteralPath $source -PathType Leaf) ('Original missing: '+$item.source)
    Check ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash-ceq[string]$item.sha256) ('Original changed: '+$item.source)
    $originalChecks++
  }
}
$all=@(Get-ChildItem -LiteralPath $root -Recurse -File)
$patterns=[ordered]@{
  vercel_key='vck_[A-Za-z0-9_-]{20,}'
  openai_key='(?<![A-Za-z0-9_])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}'
  github_key='(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,})'
  private_key='-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----'
  literal_bearer='Bearer[ \t]+[A-Za-z0-9_\-\.]{30,}'
  aws_key='AKIA[0-9A-Z]{16}'
}
$textExtensions=@('.md','.json','.log','.diff','.ps1','.txt','.cpp','.hpp','.h','.ino','.cs','.py')
$utf8=[Text.UTF8Encoding]::new($false,$true)
$jsonCount=0;$textCount=0;$rawCount=0
foreach($file in $all){
  $relative=$file.FullName.Substring($root.Length+1).Replace('\','/')
  Check ($relative-notmatch'(?i)(^|/)(?:\.git(?:/|$)|\.env(?:\.|$)|execution-permit(?:\.|/)|operator-confirmation)') ('Forbidden publication path: '+$relative)
  Check ($file.Extension-notin@('.elf','.map','.exe','.dll','.o','.a','.pem','.pfx','.p12')) ('Compiler or credential output: '+$relative)
  if($file.Extension-ceq'.bin'){
    Check ($relative-match'^evidence/preceding_live/(stage_(vehicle|ground)|capture)/[^/]+\.bin$'-and$file.Length-le65536) 'Only small preceding-live communication/record raw is allowed'
    $rawCount++
  }
  if($relative.StartsWith('source_snapshot/')){Check ($relative-notmatch'(^|/)build[^/]*/'-and$file.Extension-cne'.bin') 'Source snapshot excludes generated outputs'}
  if($file.Extension-in$textExtensions){
    $content=$utf8.GetString([IO.File]::ReadAllBytes($file.FullName));$textCount++
    foreach($pattern in $patterns.GetEnumerator()){
      Check (-not[regex]::IsMatch($content,$pattern.Value)) ('Credential pattern '+$pattern.Key+' in '+$relative)
    }
    if($file.Extension-ceq'.json'){
      # Some preserved Windows JSON originals have a UTF8 BOM. Accept that
      # encoding marker for parsing only, without rewriting original bytes.
      $jsonText=if($content.Length-gt0-and$content[0]-eq[char]0xFEFF){$content.Substring(1)}else{$content}
      [void]($jsonText|ConvertFrom-Json);$jsonCount++;Check $true ('JSON parses: '+$relative)
    }
  }
}
$offline=Read-Json 'evidence/offline/summary.json'
Check ($offline.final_full_validation.passed-eq548-and$offline.final_full_validation.failed-eq0-and$offline.final_full_validation.exit_code-eq0) 'Final548 result must pass'
Check ((Get-Content -LiteralPath (Join-Path $root 'evidence/offline/full-host-verified.log') -Raw -Encoding UTF8)-match'100% tests passed, 0 tests failed out of 548') 'Final log contains full548 success'
Check (-not$offline.hardware_interaction-and-not$offline.r18_hardware_changed) 'Repair turn is offline'
Check ($offline.all932_within30_seconds-ceq'NOT_RETESTED'-and-not$offline.live_high_speed_resolution_proven) 'No high-speed acceptance claim'
Check (-not$offline.acceptance_authorized-and-not$offline.deployment_authorized) 'No acceptance or deployment authority'
Check ($offline.unchanged_limits.product_usb_ms-eq106-and$offline.unchanged_limits.ground_fresh_grant_ms-eq500-and$offline.unchanged_limits.vehicle_tail_to_start_ms-eq500) 'Original timing limits retained'
Check ($offline.arduino_vehicle_then_ground.result-ceq'PASS'-and($offline.arduino_vehicle_then_ground.compile_order-join',')-ceq'vehicle,ground') 'Both builds in required order'
Check ($offline.arduino_vehicle_then_ground.independent_verification.result-ceq'PASS') 'Candidate independent verification passed'
foreach($role in @('vehicle','ground')){
  $compile=Read-Json "evidence/candidate_metadata/evidence/compile-$role.json"
  Check ($compile.result-ceq'PASS'-and$compile.exit_code-eq0) ('Compile passed: '+$role)
  Check ([string]$compile.application.sha256-ceq[string]$offline.arduino_vehicle_then_ground.$role.application_sha256) ('Compile application matches: '+$role)
}
foreach($engine in @('ps51','ps7')){
  $reader=Read-Json "evidence/offline/sealed-reader-$engine/summary.json"
  Check ($reader.result-ceq'PASS'-and$reader.checks-eq109) ('Reader109 passed: '+$engine)
  Check (-not$reader.hardware_interaction-and-not$reader.production_main_executed-and-not$reader.native_nm_or_openocd_invoked) ('Reader check is offline: '+$engine)
}
$live=Read-Json 'evidence/preceding_live/assessment/root-result-summary-001.json'
Check ($live.parameter_test.unique_parameters_at30_seconds-eq0-and$live.parameter_test.unique_parameters_final-eq0) 'Preceding live trial remains0/932'
Check ($live.parameter_test.request_attempts-eq1-and$live.reservation.release_out_attempts-eq0) 'Preceding live attempt count and noRelease retained'
Check ($live.restoration.both_roles_restored_written_verified_and_reenumerated-and$live.restoration.status-ceq'PASS_R18_ROLLBACK_COMPLETE') 'Preceding R18 restoration is not relabeled acceptance'
foreach($name in @('candidate_manifest.json','handoff.json','final_seal.json')){
  $field=switch($name){'candidate_manifest.json'{'manifest_sha256'};'handoff.json'{'handoff_sha256'};'final_seal.json'{'final_seal_sha256'}}
  Check ((Get-FileHash -LiteralPath (Join-Path $root "evidence/candidate_metadata/$name") -Algorithm SHA256).Hash-ceq[string]$offline.arduino_vehicle_then_ground.$field) ('Candidate metadata SHA matches: '+$name)
}
$linkCount=0
foreach($docPath in @((Join-Path $root 'README.md'),(Join-Path $project 'README.md'))){
  $content=Get-Content -LiteralPath $docPath -Raw -Encoding UTF8
  foreach($match in [regex]::Matches($content,'(?<!!)\[[^\]]+\]\(([^)]+)\)')){
    $target=$match.Groups[1].Value
    if($target-match'^(?:[a-z]+:|#)'){continue}
    $target=($target-split'#')[0]
    Check (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $docPath) $target)) ('Broken document link: '+$target)
    $linkCount++
  }
}
$summary=[ordered]@{
  schema='vc-lora-post-request-abort-publication-validation-v1';result='PASS';date_jst='2026-10-26';checks=$script:checks;powershell_version=$PSVersionTable.PSVersion.ToString();
  selected_originals=764;original_files_rechecked=$originalChecks;source_frozen_inputs_published=584;generated_inputs_excluded=22;
  json_files_parsed=$jsonCount;text_files_scanned=$textCount;credential_pattern_hits=0;small_live_raw_files=$rawCount;document_links_checked=$linkCount;
  original_full_host_suite='548/548 PASS in original workspace before publication';original_both_arduino_builds='PASS before publication';
  publication_full_host_suite_rerun=$false;publication_arduino_build_rerun=$false;hardware_interaction=$false;
  candidate_export='METADATA_ONLY_NOT_COMPLETE_NOT_FLASHABLE';current_repair_hardware_retested=$false;all932_within30_seconds='NOT_RETESTED';
  acceptance_authorized=$false;deployment_authorized=$false;
  source_inventory_sha256=(Get-FileHash -LiteralPath (Join-Path $root 'source_inventory.json') -Algorithm SHA256).Hash;
  update_readme_sha256=(Get-FileHash -LiteralPath (Join-Path $root 'README.md') -Algorithm SHA256).Hash;
  project_readme_sha256=(Get-FileHash -LiteralPath (Join-Path $project 'README.md') -Algorithm SHA256).Hash
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'summary.json'),($summary|ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false))
Write-Output ('PUBLICATION_VALIDATION PASS checks='+$script:checks+' originals=764 secret_hits=0 links='+$linkCount)
