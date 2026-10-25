[CmdletBinding()]
param(
  [string]$OriginalRepoRoot='E:/VESC/TRIAL_LOG/Loreley3_System/06_vc_lora_bridge',
  [string]$PublicationRoot=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $PublicationRoot){$PublicationRoot=Split-Path -Parent $PSScriptRoot}
$pub=(Resolve-Path -LiteralPath $PublicationRoot).Path
$original=(Resolve-Path -LiteralPath $OriginalRepoRoot).Path
$utf8=[Text.UTF8Encoding]::new($false,$true)
$script:checks=0
function Need([bool]$Value,[string]$Message){$script:checks++;if(-not $Value){throw $Message}}
function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function ReadJson([string]$Path){[IO.File]::ReadAllText($Path,$utf8)|ConvertFrom-Json}
$inventory=ReadJson (Join-Path $pub 'source_inventory.json')
Need ($inventory.canonical_source_count-eq83-and$inventory.canonical_source_tree_sha256-ceq'BBA7EE5CF24826768EC4EFD98EF5AF2338D1DDFA18DC936ECC220F934BFD5009') 'Canonical source scope must match the measured candidate'
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($entry in $inventory.files){
  $from=[IO.Path]::GetFullPath((Join-Path $original $entry.source))
  $to=[IO.Path]::GetFullPath((Join-Path $pub $entry.target))
  Need ($from.StartsWith($original+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)-and$to.StartsWith($pub+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)) 'Explicit publication roots must contain every copied path'
  Need ($seen.Add($entry.target)-and$entry.representation-ceq'BYTE_IDENTICAL_ORIGINAL') 'Copied originals require unique paths and accurate representation'
  Need ((Get-Item -LiteralPath $to).Length-eq$entry.bytes-and(Sha $to)-ceq$entry.sha256-and(Sha $from)-ceq$entry.sha256) ('Original bytes drifted: '+$entry.target)
}
$patterns=@(
  'vck_[A-Za-z0-9_-]{24,}',
  '(?<![A-Za-z0-9_-])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}',
  'gh[pousr]_[A-Za-z0-9]{30,}',
  'github_pat_[A-Za-z0-9_]{30,}',
  'AKIA[0-9A-Z]{16}',
  '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
  'https?://[^\s/@:]+:[^\s/@]+@github\.com'
)
# Key-shaped standalone strings remain forbidden; a suffix inside "fifo-task-"
# fixture filenames is not a standalone secret. No source file is allowlisted.
Need ([regex]::IsMatch(('sk-'+('A'*32)),$patterns[1])) 'The key scanner must still detect standalone secret-shaped tokens'
Need ([regex]::IsMatch(('Authorization Bearer sk-'+('A'*32)),$patterns[1])) 'The key scanner must still detect bearer values'
Need (-not[regex]::IsMatch('fifo-task-payload-publish-aborted-rejected.json',$patterns[1])) 'Do not misclassify fixture filenames as secrets'
$jsonCount=0;$textCount=0;$binaryCount=0
$binAllowed='^evidence/trial/(capture/(vehicle|ground)(\.(preparation|measurement))?\.raw\.bin|stage_(vehicle|ground)/((runtime-stage|endpoint-fifo|hwcdc-restart|ground-usb-commit|first-usb-failure)-(first|second)|(timed_path|aux_readiness|diagnostic_usb_failure|grant_diagnostic|grant_reservation)_(first|second))\.bin)$'
foreach($file in Get-ChildItem -LiteralPath $pub -Recurse -Force -File){
  $rel=$file.FullName.Substring($pub.Length+1).Replace('\','/')
  if($rel-match'^(source_snapshot|source_reference|evidence)/'){
    Need ($seen.Contains($rel)) ('Unlisted copied file: '+$rel)
  }
  Need ($file.Extension-notin@('.exe','.dll','.elf','.map','.zip','.uf2','.pdb','.pem','.key','.b64')-and$file.Name-notmatch'(?i)^(\.env(?:\..*)?|credentials|flash_record\.json|execution-permit.*|one_time_dispatch.*|dispatch_complete.*|prepared_run.*|retrial_authorization.*|live_parent.*|prepare_and_invoke_single_trial.*|pnputil-.*)$') ('Forbidden publication file: '+$rel)
  Need ($file.Length-lt20MB) ('Unexpected large file: '+$rel)
  if($file.Extension-ceq'.bin'){
    Need ($rel-cmatch$binAllowed-and$file.Length-le6144) ('Only small transport/raw records are allowed: '+$rel)
    $text=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($file.FullName));$binaryCount++
  }else{
    $text=[IO.File]::ReadAllText($file.FullName);$textCount++
    if($file.Extension-ceq'.json'){
      $null=$text|ConvertFrom-Json;$jsonCount++
      if($rel.StartsWith('evidence/')){
        Need (-not[regex]::IsMatch($text,'"(?:hil_authorization_token|safety_attestation|operator_safety_attestation|user_reply|reconnection_user_reply)"\s*:\s*"[^"\r\n]+"')) ('Operator consent declarations must be withheld: '+$rel)
      }
    }
  }
  foreach($pattern in $patterns){Need (-not[regex]::IsMatch($text,$pattern)) ('Credential-like material found; withhold and inspect privately: '+$rel)}
}
Need ($binaryCount-eq46) 'Six transport raw files and forty paired JTAG records must be present'
$moduleRoot=[IO.Path]::GetFullPath((Join-Path $pub '../../..'))
$linkCount=0
foreach($doc in @((Join-Path $pub 'README.md'),(Join-Path $moduleRoot 'README.md'))){
  $text=[IO.File]::ReadAllText($doc)
  foreach($match in [regex]::Matches($text,'\[[^\]]+\]\(([^)]+)\)')){
    $target=$match.Groups[1].Value
    if($target-match'^(https?://|#)'){continue}
    $target=$target.Split('#')[0]
    Need (Test-Path -LiteralPath ([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $doc) $target)))) ('Broken publication navigation: '+$target)
    $linkCount++
  }
}
$status=ReadJson (Join-Path $pub 'PUBLICATION_STATUS.json')
$cause=ReadJson (Join-Path $pub 'evidence/cause_analysis/reservation_failure_derived_readonly_analysis.json')
$gate=ReadJson (Join-Path $pub 'evidence/stage_gate_fix/v10_stage_final_gate_fix_summary.json')
$capture=ReadJson (Join-Path $pub 'evidence/trial/capture/summary.json')
Need ($status.representation-ceq'DERIVED_PUBLICATION_EXTRACT_NOT_BYTE_IDENTICAL_HIL_SUMMARY') 'Public result is a derived extract, not an original summary'
Need ((Sha (Join-Path $original $status.source_hil_path))-ceq$status.source_hil_sha256) 'Withheld original HIL summary must remain byte-identical'
Need ($status.parameters_at_30s-eq0-and$status.parameters_at_capture_end-eq0-and$status.param_request_attempts-eq1-and$status.param_request_local_accepted_bytes-eq14) 'Do not change parameter result or request count'
Need ($capture.param_list_diagnostics.snapshot_30s.unique_count-eq0-and$capture.param_list_diagnostics.final.unique_count-eq0-and$capture.param_list_diagnostics.request_attempts-eq1) 'Copied capture must support published parameter counts'
Need ($status.original_parent_status_preserved-ceq'FAIL_STAGE_READ_R18_RESTORED'-and-not$status.high_speed_success_proven-and$status.accepted_r18_restored_and_digest_verified_both_roles) 'Restoration is not high-speed acceptance'
Need ($cause.same_mcu_deltas.prepared_to_failure_ms-eq154-and$cause.same_mcu_deltas.ground_wait_ms-eq501) 'Published MCU intervals must use each same clock'
$pc=$cause.pc_same_clock_order
Need ([math]::Abs(([double]$pc.param_write_start_ticks-[double]$pc.vehicle_failure_complete_read_end_ticks)*1000/[double]$pc.frequency-80.4178)-lt0.000001) 'PC failure-before-request ordering must be quantitative'
Need ([math]::Abs(([double]$pc.release_write_start_ticks-[double]$pc.vehicle_failure_complete_read_end_ticks)*1000/[double]$pc.frequency-171.4479)-lt0.000001) 'PC failure-before-release ordering must be quantitative'
Need ($status.ground_product_heartbeats_preparation-eq11-and$status.ground_product_heartbeats_measurement-eq1-and$status.ground_first_product_heartbeat_usb_completion_us-eq472) 'Do not turn preparation Heartbeats into forty-second continuity'
Need ($gate.parent_sha256-ceq$status.post_trial_reference_parent_sha256-and$gate.historical_hil_summary_sha256-ceq$status.source_hil_sha256-and$gate.historical_status_preserved) 'Historical trial and later tool fix are separate epochs'
$reference=Join-Path $pub 'source_reference/tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1.reference.txt'
Need ((Sha $reference)-ceq$status.post_trial_reference_parent_sha256) 'The archived parent reference must contain the actual v10 gate fix'
Need ([IO.File]::ReadAllText((Join-Path $pub 'evidence/integration/full_host_final449_after_flash_fix.log')).Contains('100% tests passed, 0 tests failed out of 449')) 'Pretrial full449 evidence must be retained without claiming full450'
foreach($shell in @('ps51','ps7')){
  $test=ReadJson (Join-Path $pub ('validation/snapshot_final_gate_'+$shell+'/summary.json'))
  Need ($test.result-ceq'PASS'-and$test.checks-eq59-and-not$test.hardware_interaction-and-not$test.production_main_executed) 'Each published portable snapshot test must pass without device operations'
}
Need (-not$status.full450_or_arduino_build_rerun_after_final_gate_fix-and-not$status.publication_hardware_interaction-and-not$status.new_live_authorization-and-not$status.acceptance_authorized-and-not$status.deployment_authorized) 'Publication must not elevate authority or test scope'
[pscustomobject][ordered]@{
  schema='vc-lora-grant-reservation-publication-validation-v1'
  result='PASS_PUBLICATION_CHECKS_NOT_PRODUCT_ACCEPTANCE'
  checks=$checks
  original_files=$inventory.files.Count
  original_bytes=($inventory.files|Measure-Object bytes -Sum).Sum
  source_inventory_sha256=Sha (Join-Path $pub 'source_inventory.json')
  json_files_parsed=$jsonCount
  text_files_credential_scanned=$textCount
  raw_files_credential_scanned=$binaryCount
  credential_pattern_findings=0
  local_navigation_links_checked=$linkCount
  original_workspace_pretrial_host_suite=449
  published_snapshot_final_gate_checks_each_ps51_ps7=59
  saved_original_record_replay109_rerun_for_publication=$false
  full449_or450_rerun_for_publication=$false
  arduino_build_rerun_for_publication=$false
  hardware_interaction=$false
  live_authorization_granted=$false
  acceptance_authorized=$false
  deployment_authorized=$false
  limitations=@('Pattern checks are scoped checks, not a proof against arbitrary secrets.','Metadata and original documents reference intentionally omitted files.','Selected source is not a complete clean-clone or flashable release.','Original workspace paths and USB identities remain as provenance.','Historical original outer FAIL remains unchanged; post-trial replay is not a new HIL PASS.')
}|ConvertTo-Json -Depth 8
