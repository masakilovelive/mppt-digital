[CmdletBinding()]
param(
  [string]$OriginalRepoRoot='E:/VESC/TRIAL_LOG/Loreley3_System/06_vc_lora_bridge',
  [string]$PublicationRoot=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($PublicationRoot)){$PublicationRoot=Split-Path -Parent $PSScriptRoot}
$source=(Resolve-Path -LiteralPath $OriginalRepoRoot).Path
$destination=(Resolve-Path -LiteralPath $PublicationRoot).Path
$records=[Collections.Generic.List[object]]::new()
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$excluded=@('tools/invoke_r19_candidate_app_flash_hil.ps1','tools/invoke_r19_jtag_preflash_gate.ps1','tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1')
function Copy-Original([string]$Relative,[string]$Target,[string]$ExpectedSha=''){
  $relativePath=$Relative.Replace('\','/');$targetPath=$Target.Replace('\','/')
  $from=[IO.Path]::GetFullPath((Join-Path $source $relativePath))
  $to=[IO.Path]::GetFullPath((Join-Path $destination $targetPath))
  foreach($pair in @(@($from,$source),@($to,$destination))){
    if(-not$pair[0].StartsWith($pair[1]+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)){throw 'Publication copy escaped its explicit root'}
  }
  $hash=(Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash
  if($ExpectedSha-and$hash-cne$ExpectedSha){throw ('Frozen original drifted: '+$relativePath)}
  if(Test-Path -LiteralPath $to){if((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash-cne$hash){throw ('Refuse to replace different published bytes: '+$targetPath)}}
  else{[void][IO.Directory]::CreateDirectory((Split-Path -Parent $to));Copy-Item -LiteralPath $from -Destination $to}
  if((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash-cne$hash){throw ('Post-copy SHA mismatch: '+$targetPath)}
  if($seen.Add($targetPath)){$records.Add([pscustomobject][ordered]@{source=$relativePath;destination=$targetPath;sha256=$hash;bytes=(Get-Item -LiteralPath $to).Length;representation='BYTE_IDENTICAL_ORIGINAL'})}
}
$fix='runs/validation/R19-PRENEGOTIATION-FALLBACK-FIX-OFFLINE-001/20261024T-fix'
$candidate='runs/candidates/R19-GRANT-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/20261024T134821302Z-9e36e182'
$manifest=Get-Content -LiteralPath (Join-Path $source ($candidate+'/candidate_manifest.json')) -Raw|ConvertFrom-Json
if($manifest.artifact_id-cne'20261024T134821302Z-9e36e182'-or$manifest.canonical_source_snapshot.file_count-ne76){throw 'Unexpected frozen candidate source inventory'}
foreach($entry in $manifest.canonical_source_snapshot.files){Copy-Original $entry.path ('source_snapshot/'+$entry.path) $entry.sha256}
foreach($relative in @('AGENTS.md','CMakeLists.txt','CMakePresets.json','tools/run_host_tests.ps1','tools/build_r19_candidate_artifacts.ps1','third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDCR19Diagnostic.h')){Copy-Original $relative ('source_snapshot/'+$relative)}
$pin=Get-Content -LiteralPath (Join-Path $source ($fix+'/prepared_run_fixed_fallback.json')) -Raw|ConvertFrom-Json
if($pin.candidate_id-cne$manifest.artifact_id-or$pin.tools.Count-ne22){throw 'Frozen live tool inventory differs'}
foreach($entry in $pin.tools){if($entry.path-notin$excluded){Copy-Original $entry.path ('source_snapshot/'+$entry.path) $entry.sha256}}
foreach($file in Get-ChildItem -LiteralPath (Join-Path $source 'tests/host') -Recurse -File){
  if($file.Extension-notin@('.cpp','.hpp','.h','.c','.cs','.ps1','.json','.txt','.md')){throw ('Unexpected host snapshot extension: '+$file.Name)}
  $relative=$file.FullName.Substring($source.Length+1).Replace('\','/')
  Copy-Original $relative ('source_snapshot/'+$relative)
}
foreach($file in Get-ChildItem -LiteralPath (Join-Path $source 'tests/hil') -File -Filter '*grant*.ps1'){
  $relative='tests/hil/'+$file.Name;Copy-Original $relative ('source_snapshot/'+$relative)
}
foreach($name in @('summary.json','bridge_implementation_summary.json','bridge_implementation.diff','adapter_test_plan.json','adapter_test_new_file.patch','fake_arduino_epoch_hook.diff','grant_hooks_negative_fixture.diff','host_CMakeLists.diff','behavioral_RED_success.log','behavioral_RED_epoch_transition.log','post_hardening_focused_green.log','host_suite_final_windows_ps51.log','candidate_build.log','artifact_verification.log','independent_bridge_review.json','offline_validation_audit.json','grant_fallback_trial_analysis.json','usb_aux_product_trial_analysis.json','trial_evaluation.json','trial_safety_evidence_audit.json')){Copy-Original ($fix+'/'+$name) ('evidence/fallback_fix/'+$name)}
$alignment='runs/validation/R19-GRANT-ADMISSION-ALIGNMENT-OFFLINE-001/20261024T-verification'
foreach($name in @('summary.json','contract_review.json','standard_phase_summary.json','independent_test_review.json','admission_characterization.log','standard_phase_characterization.log','admission_requirement_RED.log','standard_phase_requirement_RED.log','final_invariance_and_hashes.json')){Copy-Original ($alignment+'/'+$name) ('evidence/grant_alignment/'+$name)}
$previous='runs/validation/R19-GRANT-CAUSE-RETRY-PREPARATION-001/20261024T122232Z-persistence-fixed'
foreach($name in @('trial_evaluation.json','grant_cause_analysis.json','usb_aux_analysis.json','raw_analysis.json')){Copy-Original ($previous+'/'+$name) ('evidence/previous_grant_failure/'+$name)}
$trial='runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261024T140809428Z-fixed-pregrant-r18-fallback-param-once'
foreach($name in @('summary.json','timed_path_evaluation.json','param_list_diagnostics.json','capture/summary.json','capture/param_list_30s.json','capture/vehicle.raw.bin','capture/ground.raw.bin')){Copy-Original ($trial+'/'+$name) ('evidence/trial/'+$name)}
$paired=@('runtime-stage-first.bin','runtime-stage-second.bin','endpoint-fifo-first.bin','endpoint-fifo-second.bin','hwcdc-restart-first.bin','hwcdc-restart-second.bin','ground-usb-commit-first.bin','ground-usb-commit-second.bin','first-usb-failure-first.bin','first-usb-failure-second.bin','timed_path_first.bin','timed_path_second.bin','aux_readiness_first.bin','aux_readiness_second.bin','diagnostic_usb_failure_first.bin','diagnostic_usb_failure_second.bin','grant_diagnostic_first.bin','grant_diagnostic_second.bin')
foreach($role in @('vehicle','ground')){foreach($name in @('summary.json','openocd-attempt-1-cleanup.log')+$paired){Copy-Original ($trial+'/stage_'+$role+'/'+$name) ('evidence/trial/stage_'+$role+'/'+$name)}}
foreach($name in @('candidate_manifest.json','handoff.json','handoff.sha256','artifact_manifest.json','final_seal.json','final_seal.sha256','SHA256SUMS.txt')){Copy-Original ($candidate+'/'+$name) ('evidence/candidate_metadata/'+$name)}
foreach($phase in @('install','rollback')){
  $root='runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261024T140812604Z-1db5ddb9-'+$phase
  foreach($name in @('flash_record.json','artifact_manifest.json','final_seal.json','final_seal.sha256','SHA256SUMS.txt')){Copy-Original ($root+'/'+$name) ('evidence/'+$phase+'/'+$name)}
  foreach($file in Get-ChildItem -LiteralPath (Join-Path $source $root) -File){
    if($file.Name-cmatch'^(install|rollback)_\d+_(vehicle|ground)_(r19|r18)_(write|verify)(_attempt_1)?\.(record\.json|stdout\.log)$'){
      Copy-Original ($root+'/'+$file.Name) ('evidence/'+$phase+'/'+$file.Name)
    }
  }
}
$inventory=[pscustomobject][ordered]@{
  schema='vc-lora-pregrant-fallback-publication-inventory-v1';trial_date_jst='2026-10-24'
  candidate_id=$manifest.artifact_id;source_tree_sha256=$manifest.canonical_source_snapshot.tree_sha256
  scope='Selected byte-identical originals. No flashable firmware package, live permit, operator attestations, device inventory, build tree or executable.'
  original_canonical_source_files=76;original_live_tool_count=22;omitted_identity_bound_tools=$excluded
  omitted_dependencies='Candidate and restoration metadata intentionally reference omitted BIN/ELF/MAP and historical files. Do not run device tools from this archive.'
  files=@($records|Sort-Object destination)
}
$path=Join-Path $destination 'source_inventory.json'
if(Test-Path -LiteralPath $path){throw 'Never replace an existing publication inventory'}
[IO.File]::WriteAllText($path,($inventory|ConvertTo-Json -Depth 12)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
[pscustomobject]@{result='PACKAGED_BYTE_IDENTICAL_ORIGINALS';files=$records.Count;bytes=($records|Measure-Object bytes -Sum).Sum;inventory_sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;hardware_interaction=$false}|ConvertTo-Json
