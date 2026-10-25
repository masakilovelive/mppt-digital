[CmdletBinding()]
param(
  [string]$SourceRoot='E:/VESC/TRIAL_LOG/Loreley3_System/06_vc_lora_bridge',
  [string]$PublicationRoot='',
  [switch]$PlanOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not$PublicationRoot){$PublicationRoot=Split-Path -Parent $PSScriptRoot}
$SourceRoot=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')
$PublicationRoot=[IO.Path]::GetFullPath($PublicationRoot).TrimEnd('\','/')
if($PublicationRoot-cne'E:\VESC\_codex_build\mppt-lora-aux-20261022\lora moduel\publication\updates\2026-10-25-stop-safe-cancellation'){throw 'Unexpected publication destination'}
$offline='runs/validation/R19-GRANT-RESERVATION-HEARTBEAT-STOP-FIX-OFFLINE-001/20261025T-fix'
$trial='runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261025T083255978Z-stop-v11-param-once'
$candidate='runs/candidates/R19-GRANT-RESERVATION-STOP-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/20261025T075246002Z-0508974a'
$flashBase='runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261025T083258538Z-f8b12f3c-'
$prep='runs/validation/R19-STOP-HIL-READINESS-20261025T-new-request/20261025T082252772Z-root-preparation'
function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function From-Source([string]$Relative){
  $p=[IO.Path]::GetFullPath((Join-Path $SourceRoot $Relative))
  if(-not$p.StartsWith($SourceRoot+'\',[StringComparison]::OrdinalIgnoreCase)-or-not[IO.File]::Exists($p)){throw "Invalid source: $Relative"};$p
}
function Read-Source([string]$Relative){[IO.File]::ReadAllText((From-Source $Relative))|ConvertFrom-Json}
$frozen=Read-Source "$offline/offline_frozen_source_before_final.json"
$manifest=Read-Source "$candidate/candidate_manifest.json"
if((Sha (From-Source "$candidate/candidate_manifest.json"))-cne'8D73CE3FB64601460813295012FAEA9B479D24D7C92C431CB2C40AC556EDC5E1'){throw 'Candidate drift'}
if($frozen.canonical_source.file_count-ne85-or$frozen.canonical_source.tree_sha256-cne'C27939367A5E34481DE6A552F387620A15E97A108BACD2398B9BAC5C7478AA5A'-or$manifest.canonical_source_snapshot.tree_sha256-cne$frozen.canonical_source.tree_sha256-or@($frozen.tools).Count-ne27){throw 'Frozen source scope mismatch'}
$plans=[Collections.Generic.List[object]]::new()
$omissions=[Collections.Generic.List[object]]::new()
$destinations=@{}
$credentialPatterns=@('vck_[A-Za-z0-9_-]{24,}','(?<![A-Za-z0-9_-])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}','gh[pousr]_[A-Za-z0-9]{30,}','github_pat_[A-Za-z0-9_]{30,}','AKIA[0-9A-Z]{16}','-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----','https?://[^\s/@:]+:[^\s/@]+@github\.com')
function Add-Copy([string]$Source,[string]$Target,[string]$ExpectedHash=''){
  $from=From-Source $Source
  $to=[IO.Path]::GetFullPath((Join-Path $PublicationRoot $Target))
  if(-not$to.StartsWith($PublicationRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Destination escape'}
  if($destinations.ContainsKey($Target)){if($destinations[$Target]-cne$Source){throw 'Destination collision'};return}
  if([IO.File]::Exists($to)){throw "Refusing existing output: $Target"}
  $hash=Sha $from
  if($ExpectedHash-and$hash-cne$ExpectedHash){throw "Frozen input mismatch: $Source"}
  $text=if([IO.Path]::GetExtension($from)-ceq'.bin'){[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($from))}else{[IO.File]::ReadAllText($from)}
  foreach($pattern in $credentialPatterns){if([regex]::IsMatch($text,$pattern)){throw "Credential-like material withheld; inspect privately: $Source"}}
  if($Target.StartsWith('evidence/')-and($text-match 'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED|"(?:safety_attestation|operator_safety_attestation|operator_safety_conditions|user_reply|reconnection_user_reply)"\s*:|"hil_authorization_token"\s*:\s*"[^"\s]')){
    $omissions.Add([pscustomobject]@{source=$Source;target=$Target;sha256=$hash;reason='OPERATOR_CONSENT_OR_SAFETY_DECLARATION_WITHHELD'});return
  }
  $destinations[$Target]=$Source
  $plans.Add([pscustomobject]@{source=$Source;target=$Target;bytes=[long](Get-Item -LiteralPath $from).Length;sha256=$hash;representation='BYTE_IDENTICAL_ORIGINAL'})
}
# All copied runtime files are data; none is imported or executed by this packager.
foreach($r in $frozen.canonical_source.records){Add-Copy $r.path ('source_snapshot/'+$r.path) $r.sha256}
$references=@('tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1','tools/invoke_r19_candidate_app_flash_hil.ps1','tools/invoke_r19_jtag_preflash_gate.ps1')
foreach($r in $frozen.tools){$target=if($r.path-cin$references){'source_reference/'+$r.path+'.reference.txt'}else{'source_snapshot/'+$r.path};Add-Copy $r.path $target $r.sha256}
foreach($r in $frozen.test_source_files){
  if($r.path-match'(^|/)__pycache__/|\.pyc$|\.b64$'){$omissions.Add([pscustomobject]@{source=$r.path;sha256=$r.sha256;reason='CACHE_OR_ENCODED_BINARY_FIXTURE_NOT_PUBLISHED'});continue}
  Add-Copy $r.path ('source_snapshot/'+$r.path) $r.sha256
}
Add-Copy $frozen.cmake.path ('source_snapshot/'+$frozen.cmake.path) $frozen.cmake.sha256
foreach($name in @('AGENTS.md','CMakePresets.json','CURRENT_WORKSPACE_AND_SPEC_R19.md','R19_GRANT_RESERVATION_DIAGNOSTICS.md','R19_START_ADMISSION.md','SPEC.md','PROTOCOL.md','tools/build_r19_candidate_artifacts.ps1','tools/run_host_tests.ps1','tools/run_host_sanitizers.ps1','tools/r19_start_admission.ps1')){Add-Copy $name ('source_snapshot/'+$name)}
foreach($file in Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'third_party/esp32-core-3.3.11-vc-lora') -File -Recurse){$rel=$file.FullName.Substring($SourceRoot.Length+1).Replace('\','/');Add-Copy $rel ('source_snapshot/'+$rel)}
# Offline top-level logs, diffs and summaries only; no generated fixture/build trees.
foreach($file in Get-ChildItem -LiteralPath (Join-Path $SourceRoot $offline) -File){
  if($file.Extension-cin@('.log','.diff')-or$file.Name-match'^(?:summary|.*summary|candidate_independent_audit|offline_frozen_source_(?:before|after)_final|legacy_runner_timeout_analysis)\.json$'){
    Add-Copy ($offline+'/'+$file.Name) ('evidence/offline/'+$file.Name)
  }
}
foreach($name in @('candidate_manifest.json','artifact_manifest.json','handoff.json','handoff.sha256','final_seal.json','final_seal.sha256','SHA256SUMS.txt')){Add-Copy "$candidate/$name" "evidence/candidate_metadata/$name"}
foreach($name in @('summary.json','param_list_30s.json','vehicle.raw.bin','vehicle.preparation.raw.bin','vehicle.measurement.raw.bin','ground.raw.bin','ground.preparation.raw.bin','ground.measurement.raw.bin')){Add-Copy "$trial/capture/$name" "evidence/trial/capture/$name"}
Add-Copy "$trial/param_list_diagnostics.json" 'evidence/trial/param_list_diagnostics.json'
foreach($role in @('vehicle','ground')){
  Add-Copy "$trial/stage_$role/summary.json" "evidence/trial/stage_$role/summary.json"
  $stage=Read-Source "$trial/stage_$role/summary.json"
  if($stage.schema-cne'vc-lora-r19-runtime-stage-jtag-read-v11'-or@($stage.reads).Count-ne22){throw 'Expected v11 twenty-two paired raw reads'}
  foreach($read in $stage.reads){
    $full=[IO.Path]::GetFullPath($read.path)
    if(-not$full.StartsWith((Join-Path $SourceRoot "$trial/stage_$role/").Replace('/','\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Stage path escape'}
    $rel=$full.Substring($SourceRoot.Length+1).Replace('\','/')
    Add-Copy $rel ("evidence/trial/stage_$role/"+[IO.Path]::GetFileName($full)) $read.sha256
  }
  foreach($name in @('openocd-attempt-1-capture.log','openocd-attempt-1-cleanup.log')){Add-Copy "$trial/stage_$role/$name" "evidence/trial/stage_$role/$name"}
}
foreach($mode in @('install','rollback')){
  $dir=$flashBase+$mode
  foreach($name in @('artifact_manifest.json','final_seal.json','final_seal.sha256','SHA256SUMS.txt','terminal_status.json')){Add-Copy "$dir/$name" "evidence/$mode/$name"}
  foreach($file in Get-ChildItem -LiteralPath (Join-Path $SourceRoot $dir) -File | Where-Object {$_.Name-match'(?:write|verify)_attempt_1\.(?:record\.json|stdout\.log)$'}){Add-Copy ($dir+'/'+$file.Name) ('evidence/'+$mode+'/'+$file.Name)}
}
$withheld=@("$trial/summary.json","$prep/physical_run_assessment.json")
foreach($name in $withheld){$omissions.Add([pscustomobject]@{source=$name;sha256=(Sha (From-Source $name));reason='ORIGINAL_LOCAL_PARENT_OR_ASSESSMENT_WITHHELD_PUBLIC_DERIVED_EXTRACT_INSTEAD'})}
$omissions.Add([pscustomobject]@{source='all live permits, prepared pins, dispatch wrappers and authorization records';reason='NOT_SELECTED_NO_FUTURE_HARDWARE_AUTHORITY'})
$omissions.Add([pscustomobject]@{source='application images, ELF/MAP/EXE files, compiler outputs and fixture/build trees';reason='NOT_SELECTED_NOT_A_FLASHABLE_OR_COMPLETE_SEALED_RELEASE'})
$bytes=[long](($plans|Measure-Object bytes -Sum).Sum)
if($PlanOnly){[pscustomobject]@{result='PASS_PLAN_ONLY';files=$plans.Count;bytes=$bytes;omissions=$omissions.Count}|ConvertTo-Json -Compress;return}
if(Test-Path -LiteralPath (Join-Path $PublicationRoot 'source_inventory.json')){throw 'Existing publication inventory'}
foreach($p in $plans){
  $from=From-Source $p.source;$to=Join-Path $PublicationRoot $p.target
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to))
  $sourceStream=[IO.File]::Open($from,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{
    $sha=[Security.Cryptography.SHA256]::Create();try{$held=[BitConverter]::ToString($sha.ComputeHash($sourceStream)).Replace('-','')}finally{$sha.Dispose()}
    if($held-cne$p.sha256-or$sourceStream.Length-ne$p.bytes){throw 'Source changed during copy'};$sourceStream.Position=0
    $destinationStream=[IO.File]::Open($to,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$sourceStream.CopyTo($destinationStream);$destinationStream.Flush()}finally{$destinationStream.Dispose()}
  }finally{$sourceStream.Dispose()}
  if((Sha $to)-cne$p.sha256){throw 'Copied bytes mismatch'}
}
$inventory=[ordered]@{
  schema='vc-lora-stop-cancellation-publication-inventory-v1';date_jst='2026-10-25'
  candidate_id='20261025T075246002Z-0508974a';canonical_source_count=85
  canonical_source_tree_sha256=$frozen.canonical_source.tree_sha256;live_tool_inventory_count=27
  frozen_test_inventory_records=256;files=$plans.ToArray();omissions=$omissions.ToArray()
  original_file_count=$plans.Count;total_original_bytes=$bytes
  representation='SELECTED_BYTE_IDENTICAL_ORIGINALS_WITH_SEPARATE_DERIVED_PUBLIC_STATUS'
  runtime_invokers='Three active identity-bound invokers are reference.txt data, not runnable snapshot entrypoints.'
  release_scope='Not a full clean-clone test package, sealed release or flashable package. Manifests may reference intentionally omitted files.'
  hardware_interaction=$false;live_authorization_granted=$false;acceptance_authorized=$false;deployment_authorized=$false
}
[IO.File]::WriteAllText((Join-Path $PublicationRoot 'source_inventory.json'),($inventory|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$a=Read-Source "$prep/physical_run_assessment.json"
$s=Read-Source "$trial/summary.json"
$status=[ordered]@{
  schema='vc-lora-stop-cancellation-public-status-v1';date_jst='2026-10-25'
  representation='DERIVED_PUBLICATION_EXTRACT_NOT_BYTE_IDENTICAL_HIL_SUMMARY'
  source_hil_path="$trial/summary.json";source_hil_sha256=(Sha (From-Source "$trial/summary.json"))
  source_assessment_path="$prep/physical_run_assessment.json";source_assessment_sha256=(Sha (From-Source "$prep/physical_run_assessment.json"))
  started_utc=$s.started_utc;finished_utc=$s.finished_utc;original_parent_status=$s.status
  candidate_id=$a.candidate_id;physical_trial_count=1;target_verdict=$a.target_verdict
  parameters=$a.parameter_request;heartbeat=$a.heartbeat;reservation=$a.reservation;aux=$a.aux;diagnostic_usb=$a.diagnostic_usb
  r18_restored_both_roles=$s.rollback.proven;r18_vehicle_sha256='9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52'
  r18_ground_sha256='30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5'
  hardware_quiescence=$s.hardware_quiescence;power_off_required=$s.power_off_required
  offline_host_tests=479;offline_host_failures=0;offline_host_seconds=665.53
  pretrial_vehicle_and_ground_arduino_build='PASS';publication_hardware_interaction=$false
  publication_full479_rerun=$false;publication_arduino_build_rerun=$false
  acceptance_authorized=$false;deployment_authorized=$false
  limitations=$a.limitations
}
[IO.File]::WriteAllText((Join-Path $PublicationRoot 'PUBLICATION_STATUS.json'),($status|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
[pscustomobject]@{result='PASS_PACKAGED';files=$plans.Count;bytes=$bytes;omissions=$omissions.Count}|ConvertTo-Json -Compress
