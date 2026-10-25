[CmdletBinding()]
param([string]$SourceRoot='E:/VESC/TRIAL_LOG/Loreley3_System/06_vc_lora_bridge',[string]$PublicationRoot='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not$PublicationRoot){$PublicationRoot=Split-Path -Parent $PSScriptRoot}
$pub=[IO.Path]::GetFullPath($PublicationRoot).TrimEnd('\','/')
$src=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')
$script:checks=0
function Need([bool]$Value,[string]$Message){$script:checks++;if(-not$Value){throw $Message}}
function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Json([string]$Path){[IO.File]::ReadAllText($Path)|ConvertFrom-Json}
Need (Test-Path -LiteralPath (Join-Path $pub 'source_inventory.json')) 'Publication inventory must exist'
$inventory=Json (Join-Path $pub 'source_inventory.json')
Need ($inventory.canonical_source_count-eq85-and$inventory.live_tool_inventory_count-eq27-and$inventory.canonical_source_tree_sha256-ceq'C27939367A5E34481DE6A552F387620A15E97A108BACD2398B9BAC5C7478AA5A') 'Correct frozen candidate source inventory'
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($entry in $inventory.files){
  $from=[IO.Path]::GetFullPath((Join-Path $src $entry.source));$to=[IO.Path]::GetFullPath((Join-Path $pub $entry.target))
  Need ($from.StartsWith($src+'\',[StringComparison]::OrdinalIgnoreCase)-and$to.StartsWith($pub+'\',[StringComparison]::OrdinalIgnoreCase)) 'Copy path containment'
  Need ($seen.Add($entry.target)-and$entry.representation-ceq'BYTE_IDENTICAL_ORIGINAL') 'Unique original copy mapping'
  Need ((Sha $from)-ceq$entry.sha256-and(Sha $to)-ceq$entry.sha256-and(Get-Item -LiteralPath $to).Length-eq$entry.bytes) ('Byte identical original: '+$entry.target)
}
$patterns=@('vck_[A-Za-z0-9_-]{24,}','(?<![A-Za-z0-9_-])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}','gh[pousr]_[A-Za-z0-9]{30,}','github_pat_[A-Za-z0-9_]{30,}','AKIA[0-9A-Z]{16}','-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----','https?://[^\s/@:]+:[^\s/@]+@github\.com')
Need ([regex]::IsMatch(('Authorization Bearer sk-'+('A'*32)),$patterns[1])) 'Scanner detects key-shaped bearer values'
Need (-not[regex]::IsMatch('fifo-task-payload-publish-aborted-rejected.json',$patterns[1])) 'Scanner distinguishes fixture filenames'
$binaryCount=0;$jsonCount=0;$textCount=0
foreach($file in Get-ChildItem -LiteralPath $pub -File -Recurse -Force){
  $rel=$file.FullName.Substring($pub.Length+1).Replace('\','/')
  if($rel-match'^(source_snapshot|source_reference|evidence)/'){Need ($seen.Contains($rel)) ('No unlisted copied file: '+$rel)}
  Need ($file.Length-lt20MB-and$file.Extension-notin@('.exe','.elf','.dll','.map','.zip','.uf2','.pyc','.b64','.pem','.key')) ('Only small selected text/raw files: '+$rel)
  Need ($file.Name-notmatch'(?i)^(?:\.env(?:\..*)?|flash_record\.json|execution-permit.*|prepared_.*|dispatch_.*|one_run_.*)$') ('No active permit or dispatch artifact: '+$rel)
  if($file.Extension-ceq'.bin'){
    Need ($rel-match'^evidence/trial/(?:capture/(?:vehicle|ground)(?:\.(?:preparation|measurement))?\.raw\.bin|stage_(?:vehicle|ground)/[a-z_-]+(?:first|second)\.bin)$'-and$file.Length-le6144) ('Only small diagnostic transport/paired raw records: '+$rel)
    $text=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($file.FullName));$binaryCount++
  }else{
    $text=[IO.File]::ReadAllText($file.FullName);$textCount++
    if($file.Extension-ceq'.json'){$null=$text|ConvertFrom-Json;$jsonCount++}
    if($rel.StartsWith('evidence/')){Need (-not[regex]::IsMatch($text,'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED|"(?:safety_attestation|operator_safety_attestation|operator_safety_conditions|user_reply|reconnection_user_reply)"\s*:|"hil_authorization_token"\s*:\s*"[^"\s]')) ('No operator consent evidence: '+$rel)}
  }
  foreach($pattern in $patterns){Need (-not[regex]::IsMatch($text,$pattern)) ('Credential scan no findings: '+$rel)}
}
Need ($binaryCount-eq50) 'Six transport and forty-four paired JTAG raw records'
$status=Json (Join-Path $pub 'PUBLICATION_STATUS.json')
$capture=Json (Join-Path $pub 'evidence/trial/capture/summary.json')
Need ($status.representation-ceq'DERIVED_PUBLICATION_EXTRACT_NOT_BYTE_IDENTICAL_HIL_SUMMARY') 'Extract must not masquerade as an original summary'
Need ((Sha (Join-Path $src $status.source_hil_path))-ceq$status.source_hil_sha256-and$status.source_hil_sha256-ceq'8F15942832D95B586E813EF0BA0A4733E7A747F1ED627ADD338EBC4823B97457') 'Historical outer remains byte identical'
Need ($status.parameters.at_30s-eq0-and$status.parameters.at_end-eq0-and$status.parameters.attempts-eq1-and$status.parameters.accepted_bytes-eq14-and-not$status.parameters.rf_or_pixhawk_delivery_proven) 'Zero parameters and local-only single request'
Need ($capture.param_list_diagnostics.snapshot_30s.unique_count-eq0-and$capture.param_list_diagnostics.final.unique_count-eq0-and$capture.param_list_diagnostics.request_attempts-eq1) 'Copied acquisition ledger supports the published result'
Need ($status.heartbeat.preparation_count-eq9-and$status.heartbeat.measurement_count-eq1-and$status.heartbeat.crc_valid_total-eq10-and$status.heartbeat.first_local_usb_completion_us-eq457-and[math]::Abs($status.heartbeat.final_silence_ms-39735.2043)-lt0.000001) 'Heartbeat continuity cannot be claimed from initial success'
Need ($status.reservation.vehicle_stop.disposition-ceq'SAFE_CANCEL'-and$status.reservation.vehicle_stop.reason_name-ceq'HeartbeatDeadlineConflict'-and$status.reservation.completed_cancellation_count-eq0-and-not$status.reservation.high_speed_start_proven-and-not$status.reservation.release_sent) 'Safe selection is not cancellation/rebinding/high-speed success'
Need ($status.reservation.ground_wait_elapsed_ms-eq501-and$status.reservation.ground_reason-ceq'GrantWaitExpired'-and$status.reservation.vehicle_later_reason-ceq'PrepareExpired'-and$status.reservation.ground_500ms_acceptance.result-ceq'NOT_EVALUATED') 'Separate reservation expiry from formal high-speed window acceptance'
Need ($status.aux.vehicle_fault_code-eq0-and$status.aux.ground_fault_code-eq0-and-not$status.aux.physical_waveform_measured) 'No AUX fault in this run is not waveform proof'
Need ($status.diagnostic_usb.vehicle_pending_bytes-eq31-and$status.diagnostic_usb.ground_pending_bytes-eq31-and-not$status.parameters.system_all_errors_zero) 'Ledger clean is not all-system zero errors'
foreach($role in @('vehicle','ground')){
  $stage=Json (Join-Path $pub "evidence/trial/stage_$role/summary.json")
  Need ($stage.schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v11'-and$stage.reads.Count-eq22-and$stage.safety.two_identical_reads-and$stage.safety.resume_shutdown_cleanup_proven-and-not$stage.safety.target_may_be_halted) ('Paired records and CPU cleanup: '+$role)
  $verify=@(Get-ChildItem -LiteralPath (Join-Path $pub 'evidence/rollback') -File | Where-Object {$_.Name-match($role+'_r18_verify_attempt_1\.stdout\.log$')})
  Need ($verify.Count-eq1-and[IO.File]::ReadAllText($verify[0].FullName).Contains('Verification successful (digest matched)')) ('R18 digest verified: '+$role)
}
Need ($status.r18_restored_both_roles-and$status.hardware_quiescence.child_termination_proven-and$status.hardware_quiescence.active_jtag_cleanup_proven-and-not$status.power_off_required) 'Restoration and child shutdown are proven'
Need ([IO.File]::ReadAllText((Join-Path $pub 'evidence/offline/full-host-final.log')).Contains('100% tests passed, 0 tests failed out of 479')) 'Original full479 final log'
Need ($status.offline_host_tests-eq479-and$status.offline_host_failures-eq0-and-not$status.publication_full479_rerun-and-not$status.publication_arduino_build_rerun-and-not$status.publication_hardware_interaction-and-not$status.acceptance_authorized-and-not$status.deployment_authorized) 'No publication-time rebuild, hardware use or acceptance elevation'
$linkCount=0
foreach($doc in @((Join-Path $pub 'README.md'),(Join-Path $pub '../../../README.md'))){
  foreach($match in [regex]::Matches([IO.File]::ReadAllText($doc),'\[[^\]]+\]\(([^)]+)\)')){
    $target=$match.Groups[1].Value;if($target-match'^(https?://|#)'){continue};$target=$target.Split('#')[0]
    Need (Test-Path -LiteralPath ([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $doc) $target)))) ('Working navigation: '+$target);$linkCount++
  }
}
[pscustomobject][ordered]@{schema='vc-lora-stop-publication-validation-v1';result='PASS_PUBLICATION_CHECKS_NOT_PRODUCT_ACCEPTANCE';checks=$script:checks;original_files=$inventory.files.Count;original_bytes=$inventory.total_original_bytes;source_inventory_sha256=(Sha (Join-Path $pub 'source_inventory.json'));text_files_scanned=$textCount;json_files_parsed=$jsonCount;raw_files_scanned=$binaryCount;credential_pattern_findings=0;local_links_checked=$linkCount;hardware_interaction=$false;live_authorization_granted=$false;acceptance_authorized=$false;deployment_authorized=$false}|ConvertTo-Json -Depth 5
