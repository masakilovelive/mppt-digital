[CmdletBinding()]
param([string]$PublicationRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath($PublicationRoot)
$checks=0
function Need([bool]$Condition,[string]$Name){if(-not $Condition){throw $Name};$script:checks++}
$inventory=Get-Content -LiteralPath (Join-Path $root 'source_inventory.json') -Raw|ConvertFrom-Json
Need ($inventory.files.Count -gt 15) 'Selected source and evidence inventory required'
foreach($entry in $inventory.files){
  $path=[IO.Path]::GetFullPath((Join-Path $root $entry.destination))
  Need ($path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Inventory path escaped publication'
  Need ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $entry.sha256) ('Hash mismatch: '+$entry.destination)
}
$p=Get-Content -LiteralPath (Join-Path $root 'evidence/param_attempt/summary.json') -Raw|ConvertFrom-Json
$h=Get-Content -LiteralPath (Join-Path $root 'evidence/heartbeat_only/summary.json') -Raw|ConvertFrom-Json
$a=Get-Content -LiteralPath (Join-Path $root 'evidence/pre_arm_aux/summary.json') -Raw|ConvertFrom-Json
$ledger=Get-Content -LiteralPath (Join-Path $root 'evidence/param_attempt/param_list_30s.json') -Raw|ConvertFrom-Json
Need ($p.request.local_write_attempts -eq 1 -and $p.request.accepted_bytes -eq 14 -and -not $p.request.Vehicle_or_Pixhawk_delivery_proven) 'Request must mean one local API acceptance only'
Need ($p.acquisition.checkpoint_30s.unique_parameters -eq 0 -and $p.acquisition.checkpoint_30s.sealed -and $p.acquisition.checkpoint_30s.snapshot_complete) 'Latest sealed checkpoint must remain zero of932'
Need ($ledger.unique_count -eq 0 -and $ledger.sealed -and @($ledger.missing_indexes).Count -eq 932) 'Full missing-index checkpoint required'
Need ((@($ledger.missing_indexes) -join ',') -ceq ((0..931) -join ',')) 'Missing indexes must be exactly0..931'
Need ($p.captured_communication.Ground_product_Heartbeat_frames -eq 1 -and $p.observed_product_stop.frozen_bridge_source_line -eq 2299) 'High-speed adapter stop scope changed'
Need ($p.observed_product_stop.Ground_AUX_fault -eq 0 -and $p.observed_product_stop.initial_product_Heartbeat_USB_elapsed_us -eq 450) 'Do not substitute prior AUX or USB failure'
Need ($h.capture.Ground_Heartbeat_raw_replay_count -eq 39 -and $h.capture.Ground_Heartbeat_saved_live_observations -eq 38 -and -not $h.measurement_aggregation_discrepancy.runner_fix_implemented) 'Heartbeat aggregation discrepancy must remain explicit'
Need ($a.parameter_evaluation.request_attempts -eq 0 -and $a.parameter_evaluation.result -ceq 'NOT_ATTEMPTED') 'Prior blocked run was not an acquisition attempt'
Need ($p.restoration_and_cleanup.accepted_R18_restored_both_roles -and $h.restoration.accepted_R18_restored_both_roles -and $a.restoration.accepted_R18_restored_both_roles) 'R18 disposition must remain proven'
Need (-not $p.acceptance_eligible -and -not $p.deployment_authorized) 'No product acceptance or deployment'
foreach($shell in @('ps7','ps51')){
  $test=Get-Content -LiteralPath (Join-Path $root ('validation/pure_ledger_'+$shell+'/summary.json')) -Raw|ConvertFrom-Json
  Need ($test.tests -eq 47 -and $test.passed -eq 47 -and $test.failed -eq 0 -and $test.hardware_operations -eq 0) ('Published pure ledger fixture failed: '+$shell)
}
$forbidden=@('.exe','.dll','.elf','.map','.bin','.pyc','.zip','.env','.pem','.pfx','.key')
$patterns=@('vck_[A-Za-z0-9_-]{25,}','ghp_[A-Za-z0-9]{30,}','github_pat_[A-Za-z0-9_]{30,}','sk-proj-[A-Za-z0-9_-]{25,}','-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----','\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b')
foreach($file in Get-ChildItem -LiteralPath $root -Recurse -File){
  Need ($file.Extension.ToLowerInvariant() -notin $forbidden -and $file.Name -notlike '.env*' -and $file.Name -notlike '*execution-permit*.json') 'Forbidden file type or live permit'
  Need ($file.Length -lt 2MB) 'Unexpected large file'
  $content=[IO.File]::ReadAllText($file.FullName)
  foreach($pattern in $patterns){Need (-not ($content -match $pattern)) 'Potential credential or physical device identifier; value withheld'}
  if($file.Extension -eq '.json'){$null=$content|ConvertFrom-Json;$script:checks++}
  if($file.Extension -eq '.ps1'){$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors);Need ($errors.Count -eq 0) 'PowerShell syntax error'}
  if($file.Extension -eq '.md'){
    foreach($m in [regex]::Matches($content,'\]\(([^)]+)\)')){
      $link=$m.Groups[1].Value
      if($link -match '^(https?:|#|mailto:)'){continue}
      $target=Join-Path $file.DirectoryName ([Uri]::UnescapeDataString(($link -split '#')[0]))
      Need (Test-Path -LiteralPath $target) ('Broken Markdown link: '+$link)
    }
  }
}
[pscustomobject]@{schema='vc-lora-param-progress-publication-validation-v1';result='PASS';checks=$checks;inventoried_files=$inventory.files.Count;secret_pattern_findings=0;forbidden_files=0;local_links='PASS';json_parse='PASS';powershell_syntax='PASS';hardware_interaction=$false;product_acceptance=$false}|ConvertTo-Json
