[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OriginalRepoRoot,[string]$PublicationRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$source=[IO.Path]::GetFullPath($OriginalRepoRoot)
$destination=[IO.Path]::GetFullPath($PublicationRoot)
$records=[Collections.Generic.List[object]]::new()
function Copy-Evidence([string]$Relative,[string]$Target){
  $from=[IO.Path]::GetFullPath((Join-Path $source $Relative))
  $to=[IO.Path]::GetFullPath((Join-Path $destination $Target))
  if(-not $from.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not $to.StartsWith($destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Copy escaped explicit roots'}
  $hash=(Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash
  if(Test-Path -LiteralPath $to){if((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash -cne $hash){throw ('Refuse different existing destination: '+$Target)}}
  else{[void][IO.Directory]::CreateDirectory((Split-Path -Parent $to));Copy-Item -LiteralPath $from -Destination $to}
  if((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash -cne $hash){throw 'Post-copy mismatch'}
  $records.Add([pscustomobject]@{source=$Relative.Replace('\','/');destination=$Target.Replace('\','/');sha256=$hash;bytes=(Get-Item -LiteralPath $to).Length;representation='BYTE_IDENTICAL_ORIGINAL'})
}
$hil='runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/'
$param=$hil+'20261024T040509Z-param-list-once-retry'
$heartbeat=$hil+'20261024T013752Z-aux-usb-recurrence'
$pre=$hil+'20261024T004000Z-param-list-once'
$offline='runs/validation/R19-PARAM-LIST-DIAGNOSTICS-OFFLINE-001/20261024T090000JST'
$cause='runs/validation/R19-AUX-USB-CAUSE-INVESTIGATION-001/20261024T010000Z'
Copy-Evidence ($param+'/analysis/summary.json') 'evidence/param_attempt/summary.json'
Copy-Evidence ($param+'/analysis/parameter_review.json') 'evidence/param_attempt/parameter_review.json'
Copy-Evidence ($param+'/analysis/device_review.json') 'evidence/param_attempt/device_review.json'
Copy-Evidence ($param+'/capture/param_list_30s.json') 'evidence/param_attempt/param_list_30s.json'
Copy-Evidence ($heartbeat+'/analysis/summary.json') 'evidence/heartbeat_only/summary.json'
Copy-Evidence ($heartbeat+'/analysis/capture_review.json') 'evidence/heartbeat_only/capture_review.json'
Copy-Evidence ($pre+'/analysis/summary.json') 'evidence/pre_arm_aux/summary.json'
foreach($name in @('summary.json','changes_final.patch','host_final.log','arduino_vehicle.log','arduino_ground.log','ledger/summary.json','capture/summary.json','outer/summary.json')){Copy-Evidence ($offline+'/'+$name) ('evidence/offline_param_instrumentation/'+$name)}
foreach($name in @('summary.json','aux_review.json','usb_review.json','comparison_review.json')){Copy-Evidence ($cause+'/'+$name) ('evidence/aux_usb_cause/'+$name)}
$change=Get-Content -LiteralPath (Join-Path $source ($offline+'/summary.json')) -Raw|ConvertFrom-Json
$pin=Get-Content -LiteralPath (Join-Path $source 'runs/validation/R19-PARAM-LIST-RETRY-LIVE-PREPARATION-001/20261024T040509Z/prepared_run.json') -Raw|ConvertFrom-Json
$sourceFiles=@('AGENTS.md')+@($change.verification.sources|ForEach-Object{$_.path})+@($pin.tools|ForEach-Object{$_.path})
$sourceFiles+=@('firmware/phase6/vc_lora_phase6_bridge.hpp','firmware/high_speed/high_speed_phase6_adapter.hpp','firmware/high_speed/r19_diagnostic_usb_failure_record.hpp','core/src/bulk_session_controller.cpp','core/src/high_speed_tdd_coordinator.cpp')
foreach($entry in $change.verification.sources){if((Get-FileHash -LiteralPath (Join-Path $source $entry.path) -Algorithm SHA256).Hash -cne $entry.sha256){throw ('Source differs from tested offline snapshot: '+$entry.path)}}
foreach($entry in $pin.tools){if((Get-FileHash -LiteralPath (Join-Path $source $entry.path) -Algorithm SHA256).Hash -cne $entry.sha256){throw ('Tool differs from live pin: '+$entry.path)}}
$excludedIdentityBoundTools=@('tools/invoke_r19_candidate_app_flash_hil.ps1','tools/invoke_r19_jtag_preflash_gate.ps1','tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1')
foreach($file in $sourceFiles|Sort-Object -Unique){if($file -notin $excludedIdentityBoundTools){Copy-Evidence $file ('source_snapshot/'+$file)}}
$inventory=[ordered]@{schema='vc-lora-param-progress-source-inventory-v1';scope='Allowlisted byte-identical evidence and selected tested sources; no executable, live permit, PnP records, parent raw log or hardware interaction';candidate_id=$pin.candidate_id;live_tool_count=$pin.tools.Count;omitted_identity_bound_tools=$excludedIdentityBoundTools;files=@($records|Sort-Object destination)}
[IO.File]::WriteAllText((Join-Path $destination 'source_inventory.json'),($inventory|ConvertTo-Json -Depth 14)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
[pscustomobject]@{result='PACKAGED';files=$records.Count;bytes=($records|Measure-Object bytes -Sum).Sum;hardware_interaction=$false}|ConvertTo-Json
