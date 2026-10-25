[CmdletBinding()]
param(
  [string]$SourceRoot = 'E:/VESC/TRIAL_LOG/Loreley3_System/06_vc_lora_bridge',
  [string]$PublicationRoot = (Split-Path -Parent $PSScriptRoot),
  [switch]$PlanOnly,
  [switch]$RefreshInventoryOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# Packaging only. No runtime tool is imported or invoked. Every output is new.
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')
$PublicationRoot = [IO.Path]::GetFullPath($PublicationRoot).TrimEnd('\','/')
$expectedDestination = 'E:\VESC\_codex_build\mppt-lora-aux-20261022\lora moduel\publication\updates\2026-10-25-grant-reservation'
if ($PublicationRoot -cne $expectedDestination) { throw 'Unexpected publication destination' }
$local = 'runs/validation/R19-GRANT-RESERVATION-INTEGRATION-OFFLINE-001/20261025T-fix'
$trial = 'runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261025T043509262Z-grant-reservation-param-once-after-flash-metadata-fix'
$candidate = 'runs/candidates/R19-GRANT-RESERVATION-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/20261024T215821978Z-c1982cbd'
$flashBase = 'runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261025T043511024Z-0c60e726-'
$historicalParent = '011283705D8DF136FC124629E57A823C4DB92B43F1471183F37C80863F99728D'
$currentParent = 'AFC2EBC5EFA842DD00E6642D0B88CE20665DA9533C650AEC75D971CDC56374B1'
$currentFlash = 'E09A9F01C840EFFB7A6200A636A9FA52DB0796E52884F3B06F0BFF9D57BF9DDF'
$expectedTree = 'BBA7EE5CF24826768EC4EFD98EF5AF2338D1DDFA18DC936ECC220F934BFD5009'
$inventoryPath = Join-Path $SourceRoot "$local/reviewed_26_tool_source_inventory_v5.json"
if ((Get-FileHash -LiteralPath $inventoryPath).Hash -cne 'F3B7A605092D714B3DC580070650D87EE2D5991443A43E33D49BC740A13ADF55') { throw 'Historical v5 inventory drift' }
$historical = [IO.File]::ReadAllText($inventoryPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$candidateManifest = [IO.File]::ReadAllText((Join-Path $SourceRoot "$candidate/candidate_manifest.json"), [Text.Encoding]::UTF8) | ConvertFrom-Json
if ((Get-FileHash -LiteralPath (Join-Path $SourceRoot "$candidate/candidate_manifest.json")).Hash -cne '04AE6FC3F70B13CF2A83CF637A073617E76ADC8BDEE3BEEA0FBF43653C6FA770') { throw 'Candidate manifest drift' }
$canonical = @($historical.canonical_source_snapshot.records)
if ($canonical.Count -ne 83 -or $historical.canonical_source_snapshot.tree_sha256 -cne $expectedTree -or $candidateManifest.canonical_source_snapshot.tree_sha256 -cne $expectedTree) { throw 'Canonical source identity mismatch' }
$plans = [Collections.Generic.List[object]]::new()
$omissions = [Collections.Generic.List[object]]::new()
$destinations = @{}

function Resolve-Source([string]$Relative) {
  $path = [IO.Path]::GetFullPath((Join-Path $SourceRoot $Relative))
  if (-not $path.StartsWith($SourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Source escape: $Relative" }
  if (-not [IO.File]::Exists($path)) { throw "Missing required input: $Relative" }
  return $path
}
function Add-Copy([string]$Source, [string]$Target, [string]$ExpectedHash = '') {
  $sourcePath = Resolve-Source $Source
  $targetPath = [IO.Path]::GetFullPath((Join-Path $PublicationRoot $Target))
  if (-not $targetPath.StartsWith($PublicationRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Destination escape: $Target" }
  if ($destinations.ContainsKey($Target)) {
    if ($destinations[$Target] -cne $Source) { throw "Duplicate destination: $Target" }
    return
  }
  $targetExists = [IO.File]::Exists($targetPath)
  if ($targetExists -and -not $RefreshInventoryOnly) { throw "Refusing existing publication output: $Target" }
  $hash = (Get-FileHash -LiteralPath $sourcePath).Hash
  if ($ExpectedHash -and $hash -cne $ExpectedHash) { throw "Source drift: $Source" }
  $extension = [IO.Path]::GetExtension($sourcePath)
  if ($extension -notin @('.bin','.png','.jpg')) {
    $text = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8)
    $credentialPattern = '(?i)\b(?:ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,}|AKIA[0-9A-Z]{16}|sk-proj-[A-Za-z0-9_-]{20,})\b|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
    if ($text -match $credentialPattern) { throw "Suspected credential; no content printed: $Source" }
    if ($Target.StartsWith('evidence/') -and ($text -match 'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED' -or $text -match '"(?:safety_attestation|operator_safety_attestation|operator_safety_conditions|user_reply|reconnection_user_reply)"\s*:' -or $text -match '"hil_authorization_token"\s*:\s*"[^"\s]')) {
      if ($targetExists) { throw "Withheld evidence still present; remove only fresh archive copy before refresh: $Target" }
      $omissions.Add([pscustomobject]@{source=$Source;proposed_target=$Target;sha256=$hash;reason='OPERATOR_ATTESTATION_OR_CONSENT_MATERIAL_WITHHELD'})
      return
    }
  }
  if ($RefreshInventoryOnly -and (-not $targetExists -or (Get-FileHash -LiteralPath $targetPath).Hash -cne $hash -or (Get-Item -LiteralPath $targetPath).Length -ne (Get-Item -LiteralPath $sourcePath).Length)) { throw "Refresh requires unchanged existing copy: $Target" }
  $destinations[$Target] = $Source
  $plans.Add([pscustomobject]@{source=$Source;target=$Target;bytes=[int64](Get-Item -LiteralPath $sourcePath).Length;sha256=$hash;representation='BYTE_IDENTICAL_ORIGINAL'})
}
function Add-Tree([string]$Relative) {
  foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $SourceRoot $Relative) -File -Recurse)) {
    $relativePath = $file.FullName.Substring($SourceRoot.Length + 1).Replace('\','/')
    if ($relativePath -ceq 'tests/arduino_compile/fixtures/hwcdc_3_3_11_migration_fixture.zip.b64') {
      $omissions.Add([pscustomobject]@{source=$relativePath;proposed_target="source_snapshot/$relativePath";sha256=(Get-FileHash -LiteralPath $file.FullName).Hash;reason='BINARY_ENCODED_ARCHIVE_FIXTURE_WITHHELD_MIGRATION_TEST_DEPENDENCY_NOT_INCLUDED'})
      continue
    }
    Add-Copy $relativePath "source_snapshot/$relativePath"
  }
}
function Add-Local([string]$Name, [string]$Section = 'integration') {
  Add-Copy "$local/$Name" "evidence/$Section/$Name"
}

# Canonical c198 firmware, not a rebuild or a new candidate.
foreach ($record in $canonical) { Add-Copy $record.path "source_snapshot/$($record.path)" $record.sha256 }
$orderedCanonical = [Collections.Generic.List[object]]::new()
foreach ($record in $canonical) { $orderedCanonical.Add($record) }
$orderedCanonical.Sort([Comparison[object]]{param($a,$b) [StringComparer]::OrdinalIgnoreCase.Compare([string]$a.path,[string]$b.path)})
$canonicalText = ((@($orderedCanonical.ToArray() | ForEach-Object { "$($_.sha256)  $($_.path)" })) -join "`n") + "`n"
$sha = [Security.Cryptography.SHA256]::Create()
try { $tree = [BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($canonicalText))).Replace('-','') } finally { $sha.Dispose() }
if ($tree -cne $expectedTree) { throw 'Canonical aggregate hash mismatch' }
foreach ($name in @('AGENTS.md','CMakeLists.txt','CMakePresets.json')) { Add-Copy $name "source_snapshot/$name" }
foreach ($name in @('CURRENT_WORKSPACE_AND_SPEC_R19.md','R19_GRANT_RESERVATION_DIAGNOSTICS.md','R19_START_ADMISSION.md','SPEC.md','PROTOCOL.md')) { Add-Copy $name "source_snapshot/$name" }
Add-Tree 'tests/host'
Add-Tree 'tests/arduino_compile'
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'tests/hil') -File | Where-Object { $_.Name -match 'grant|start_admission' })) {
  Add-Copy "tests/hil/$($file.Name)" "source_snapshot/tests/hil/$($file.Name)"
}
Add-Tree 'third_party/esp32-core-3.3.11-vc-lora'
$references = @('tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1','tools/invoke_r19_candidate_app_flash_hil.ps1','tools/invoke_r19_jtag_preflash_gate.ps1')
if (@($historical.tools).Count -ne 26) { throw 'Expected exactly 26 historical live tools' }
foreach ($tool in $historical.tools) {
  $expected = [string]$tool.sha256
  if ($tool.path -ceq $references[0]) { $expected = $currentParent }
  if ($tool.path -ceq $references[1] -and $expected -cne $currentFlash) { throw 'Unexpected flash pin' }
  $target = if ($tool.path -cin $references) { "source_reference/$($tool.path).reference.txt" } else { "source_snapshot/$($tool.path)" }
  Add-Copy $tool.path $target $expected
}
foreach ($name in @('build_r19_candidate_artifacts.ps1','run_host_tests.ps1','run_host_sanitizers.ps1','r19_start_admission.ps1')) { Add-Copy "tools/$name" "source_snapshot/tools/$name" }

# Selected offline evidence. Never recursively copy the fixture/build trees.
foreach ($name in @(
  'full_host_final449_after_flash_fix.log','host_final449_build.log','host_final449_configure.log',
  'reservation_core_implementation_summary.json','metadata_reader_summary.json','runner_summary.json',
  'reservation_end_to_end_independent_review.json','offline_flash_repair_independent_review.json','flash_boundary_fix_summary.json',
  'root_bridge_core_and_tests_final.diff','root_CMakeLists.final447.diff','reservation_core_implementation.diff','runner_changes_v3.diff',
  'root_review_flash_boundary_fix.diff','root_CMakeLists.flash_boundary_tests.diff',
  'reservation_legacy_behavior_RED_attempt2.log','reservation_core_GREEN_attempt1.log',
  'reservation_deadline_callback_RED.log','reservation_deadline_callback_GREEN.log','reservation_record_strict_RED.log','reservation_record_strict_GREEN.log',
  'runner_ordering_RED_ps51.log','runner_capture_RED_ps51.log','runner_capture_GREEN_ps51_final.log','runner_capture_GREEN_ps7_final.log',
  'runner_workflow_GREEN_ps51_final.log','runner_workflow_GREEN_ps7.log',
  'enable_provenance_main_RED_ps51.log','enable_provenance_main_GREEN_ps51.log','enable_provenance_main_GREEN_ps7.log',
  'flash_boundary_actual_RED_ps51.log','flash_boundary_actual_RED_ps7.log','flash_boundary_expanded_RED_ps7.log',
  'flash_boundary_GREEN_ps51.log','flash_boundary_GREEN_ps7.log','operation_regression_RED_ps51.log','operation_regression_GREEN_ps51.log','operation_regression_GREEN_ps7.log'
)) { Add-Local $name }
foreach ($name in @('flash_boundary_GREEN_ps51','flash_boundary_GREEN_ps7','operation_regression_GREEN_ps51','operation_regression_GREEN_ps7','builder_whole_main_ps51_final','builder_whole_main_ps7_attempt2')) { Add-Local "$name/summary.json" }
Add-Copy "$local/reviewed_26_tool_source_inventory_v5.json" 'evidence/integration/reviewed_26_tool_source_inventory_v5.HISTORICAL.json'
foreach ($name in @('v10_stage_final_gate_fix_summary.json','v10_stage_final_gate_fix.diff','stage_final_gate_RED_ps51.log','stage_final_gate_RED_ps7.log','stage_final_gate_saved_RED_ps51.log','stage_final_gate_saved_RED_ps7.log','stage_final_gate_GREEN_ps51.log','stage_final_gate_GREEN_ps7.log','stage_final_gate_related_GREEN_ps51.log','stage_final_gate_related_GREEN_ps7.log','stage_final_gate_legacy_orchestrator_GREEN_ps51.log','stage_final_gate_v9_history_diagnostic_RED_ps7.log','stage_final_gate_GREEN_ps51/summary.json','stage_final_gate_GREEN_ps7/summary.json')) { Add-Local $name 'stage_gate_fix' }
foreach ($name in @('reservation_failure_derived_readonly_analysis.json','reservation_failure_derived_readonly_analysis.ps1','post_repaired_hil_stage_gate_analysis.json','retrial_restore_artifact_independent_audit_20261025T043509262Z.json')) { Add-Local $name 'cause_analysis' }
Add-Local 'postfailure_independent_review_20261025T033913241Z.json' 'previous_failure'
foreach ($name in @('candidate_manifest.json','artifact_manifest.json','final_seal.json','final_seal.sha256','SHA256SUMS.txt','handoff.json','handoff.sha256')) { Add-Copy "$candidate/$name" "evidence/candidate_metadata/$name" }
foreach ($name in @('summary.json','param_list_30s.json','vehicle.raw.bin','vehicle.preparation.raw.bin','vehicle.measurement.raw.bin','ground.raw.bin','ground.preparation.raw.bin','ground.measurement.raw.bin')) { Add-Copy "$trial/capture/$name" "evidence/trial/capture/$name" }
Add-Copy "$trial/param_list_diagnostics.json" 'evidence/trial/param_list_diagnostics.json'
foreach ($role in @('vehicle','ground')) {
  $summaryPath = "$trial/stage_$role/summary.json"
  Add-Copy $summaryPath "evidence/trial/stage_$role/summary.json"
  $stage = [IO.File]::ReadAllText((Resolve-Source $summaryPath), [Text.Encoding]::UTF8) | ConvertFrom-Json
  if ($stage.schema -cne 'vc-lora-r19-runtime-stage-jtag-read-v10' -or @($stage.reads).Count -ne 20) { throw "Unexpected stage inputs: $role" }
  foreach ($read in $stage.reads) {
    $relative = ([IO.Path]::GetFullPath($read.path)).Substring($SourceRoot.Length + 1).Replace('\','/')
    if (-not $relative.StartsWith("$trial/stage_$role/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Stage read path escape' }
    Add-Copy $relative "evidence/trial/stage_$role/$([IO.Path]::GetFileName($read.path))" $read.sha256
  }
  foreach ($name in @('openocd-attempt-1-capture.log','openocd-attempt-1-cleanup.log')) { Add-Copy "$trial/stage_$role/$name" "evidence/trial/stage_$role/$name" }
}
foreach ($mode in @('install','rollback')) {
  $flashDir = "$flashBase$mode"
  foreach ($name in @('flash_record.json','artifact_manifest.json','final_seal.json','final_seal.sha256','SHA256SUMS.txt')) { Add-Copy "$flashDir/$name" "evidence/$mode/$name" }
  foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $SourceRoot $flashDir) -File | Where-Object { $_.Name -match '(?:write|verify)(?:_attempt_1)?\.(?:record\.json|stdout\.log)$' })) { Add-Copy "$flashDir/$($file.Name)" "evidence/$mode/$($file.Name)" }
}
$omissions.Add([pscustomobject]@{source="$trial/summary.json";proposed_target='evidence/trial/summary.json';reason='FULL_PARENT_OPERATOR_ATTESTATIONS_WITHHELD'})
$omissions.Add([pscustomobject]@{source="$local/summary.json";proposed_target='evidence/integration/summary.json';reason='LOCAL_AUTHORIZATION_AND_DISPATCH_STATE_WITHHELD'})
$omissions.Add([pscustomobject]@{source='permits, prepared pins, authorization/dispatch records, live wrappers and command logs';reason='INTENTIONALLY_NOT_SELECTED'})
$omissions.Add([pscustomobject]@{source='application BIN/ELF/MAP/EXE, compiler/build trees and fixture clones';reason='NOT_A_FLASHABLE_OR_COMPLETE_SEALED_RELEASE'})

$totalBytes = [int64]0
foreach ($plan in $plans) { $totalBytes += $plan.bytes }
if ($PlanOnly) {
  [pscustomobject]@{result='PASS_PLAN_ONLY_NO_OUTPUTS_WRITTEN';files=$plans.Count;bytes=$totalBytes;omissions=$omissions.Count;canonical_sources=83;tree_sha256=$tree} | ConvertTo-Json -Compress
  return
}
if ([IO.File]::Exists((Join-Path $PublicationRoot 'source_inventory.json')) -and -not $RefreshInventoryOnly) { throw 'Refusing existing inventory' }
if ($RefreshInventoryOnly -and -not [IO.File]::Exists((Join-Path $PublicationRoot 'source_inventory.json'))) { throw 'Refresh requires existing new publication inventory' }
foreach ($plan in $plans) {
  if ($RefreshInventoryOnly) { continue }
  $sourcePath = Resolve-Source $plan.source
  $targetPath = Join-Path $PublicationRoot $plan.target
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($targetPath))
  $sourceStream = [IO.File]::Open($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $heldHash = [BitConverter]::ToString($sha.ComputeHash($sourceStream)).Replace('-','') } finally { $sha.Dispose() }
    if ($heldHash -cne $plan.sha256 -or $sourceStream.Length -ne $plan.bytes) { throw "Source changed during packaging: $($plan.source)" }
    $sourceStream.Position = 0
    $outputStream = [IO.File]::Open($targetPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $sourceStream.CopyTo($outputStream); $outputStream.Flush() } finally { $outputStream.Dispose() }
  } finally { $sourceStream.Dispose() }
  if ((Get-FileHash -LiteralPath $targetPath).Hash -cne $plan.sha256) { throw "Copied-byte mismatch: $($plan.target)" }
}
$record = [ordered]@{
  schema='vc-lora-grant-reservation-publication-inventory-v1'
  publication_date_jst='2026-10-25'
  candidate_id='20261024T215821978Z-c1982cbd'
  canonical_source_count=83
  canonical_source_tree_sha256=$tree
  original_live_tool_count=26
  historical_v5_executed_parent_sha256=$historicalParent
  current_post_trial_offline_fixed_parent_sha256=$currentParent
  current_flash_sha256=$currentFlash
  source_scope='Selected immutable firmware and evidence originals. Current tools include post-trial acquisition-gate fix; no new hardware trial, full450 suite or firmware build is implied.'
  source_reference_policy='Three active identity-bound invokers are byte-identical reference.txt data, not directly executable source_snapshot scripts.'
  attestation_policy='Parent/local overall summaries and evidence containing operator-consent fields are withheld. Small raw/stage data retain device and session identities intentionally.'
  evidence_scope='449/449 is pretrial; post-trial 59 portable /109 saved-replay checks per shell are separate. Original HIL FAIL remains unchanged; R18 restored and 0/932 are not product acceptance.'
  partial_seal_policy='Published manifests/seal sidecars may reference intentionally omitted application images, attestation-bearing flash records/install seal and historical files; this is not a complete sealed flash package.'
  clean_clone_policy='The binary-encoded HWCDC migration archive fixture is intentionally omitted; its dependent migration test is not promised reproducible. This selected snapshot is not a full clean-clone test package.'
  cause_script_caveat='The byte-identical historical cause analysis script contains original absolute paths and an output write to its historical analysis path. Inspect/adapt it in a separate offline working copy; do not execute unchanged against the original workspace.'
  files=$plans.ToArray()
  omissions=$omissions.ToArray()
  file_count=$plans.Count
  total_original_bytes=$totalBytes
  hardware_interaction=$false
  git_or_network_operation=$false
  acceptance_authorized=$false
  deployment_authorized=$false
}
$json = ($record | ConvertTo-Json -Depth 12) + "`n"
$inventoryOutput = Join-Path $PublicationRoot 'source_inventory.json'
$inventoryMode = if ($RefreshInventoryOnly) { [IO.FileMode]::Create } else { [IO.FileMode]::CreateNew }
$stream = [IO.File]::Open($inventoryOutput, $inventoryMode, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $data = [Text.UTF8Encoding]::new($false).GetBytes($json); $stream.Write($data,0,$data.Length); $stream.Flush() } finally { $stream.Dispose() }
[pscustomobject]@{result=($(if ($RefreshInventoryOnly) { 'PASS_INVENTORY_REFRESH_EXISTING_ORIGINALS_REVERIFIED' } else { 'PASS_PACKAGED_BYTE_IDENTICAL_ORIGINALS' }));files=$plans.Count;bytes=$totalBytes;omissions=$omissions.Count;inventory_sha256=(Get-FileHash -LiteralPath $inventoryOutput).Hash;publication_root=$PublicationRoot} | ConvertTo-Json -Compress
