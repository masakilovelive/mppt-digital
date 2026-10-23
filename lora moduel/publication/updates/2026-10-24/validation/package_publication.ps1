[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OriginalRepoRoot,[string]$PublicationRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath($OriginalRepoRoot)
$destination=[IO.Path]::GetFullPath($PublicationRoot)
$records=[Collections.Generic.List[object]]::new()
function Copy-Evidence([string]$Relative,[string]$Target){
  $from=[IO.Path]::GetFullPath((Join-Path $source $Relative))
  $to=[IO.Path]::GetFullPath((Join-Path $destination $Target))
  if(-not $from.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not $to.StartsWith($destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Copy escaped explicit roots'}
  $hash=(Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash
  if(Test-Path -LiteralPath $to){if((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash -ne $hash){throw ('Refuse different existing destination: '+$Target)}}
  else{[void][IO.Directory]::CreateDirectory((Split-Path -Parent $to));Copy-Item -LiteralPath $from -Destination $to}
  if((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash -ne $hash){throw 'Post-copy mismatch'}
  $records.Add([pscustomobject]@{source=$Relative.Replace('\','/');destination=$Target.Replace('\','/');sha256=$hash;bytes=(Get-Item -LiteralPath $to).Length})
}
$clock='runs/validation/R19-VEHICLE-CLOCK-DIAGNOSTIC-FIRST-FAIL-FIX-001/20261023T113004Z'
$read='runs/validation/R19-PC-LIFECYCLE-READ-COMPARISON-FIX-001/20261023T152500Z'
$prior='runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261023T134700Z-vehicle-clock-first-fail'
$current='runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261023T155139Z-read-pause-lifecycle'
$sourceFiles=@('AGENTS.md','core/src/runtime_contract.cpp','core/include/vc_lora/runtime_contract.hpp')
$sourceFiles+=@(Get-ChildItem -LiteralPath (Join-Path $source 'core') -Recurse -File|Where-Object{$_.Extension -in @('.cpp','.hpp','.h')}|ForEach-Object{$_.FullName.Substring($source.Length+1).Replace('\','/')})
foreach($base in @($clock,$read)){$integrity=Get-Content -LiteralPath (Join-Path $source ($base+'/after_integrity.json')) -Raw|ConvertFrom-Json;$sourceFiles+=@($integrity.changed_sources|ForEach-Object{$_.path})}
$pin=Get-Content -LiteralPath (Join-Path $source ($read+'/prepared_run.json')) -Raw|ConvertFrom-Json
$sourceFiles+=@($pin.tools|ForEach-Object{$_.path})
foreach($file in $sourceFiles|Sort-Object -Unique){Copy-Evidence $file ('source_snapshot/'+$file)}
Copy-Evidence ($clock+'/summary.json') 'evidence/clock_fix/summary.json'
Copy-Evidence ($clock+'/changes.diff') 'evidence/clock_fix/changes.diff'
Copy-Evidence ($clock+'/outer_tools_final.diff') 'evidence/clock_fix/outer_tools_final.diff'
Copy-Evidence ($read+'/summary.json') 'evidence/read_comparison_fix/summary.json'
Copy-Evidence ($read+'/source_changes.diff') 'evidence/read_comparison_fix/source_changes.diff'
foreach($name in @('full_host_tests.log','failed_tests_repaired.log','final_affected_regression.log','arduino_vehicle.log','arduino_ground.log','permit_green.log','permit_red.log')){Copy-Evidence ($read+'/'+$name) ('evidence/read_comparison_fix/'+$name)}
foreach($name in @('reader/summary.json','capture_contract/summary.json','compatibility/summary.json')){Copy-Evidence ($read+'/'+$name) ('evidence/read_comparison_fix/'+$name)}
Copy-Evidence ($prior+'/analysis/independent_review/summary.json') 'evidence/previous/independent_review.json'
Copy-Evidence ($current+'/analysis/summary.json') 'evidence/current/comparison_outcome.json'
Copy-Evidence ($current+'/analysis/independent_review/summary.json') 'evidence/current/independent_review.json'
Copy-Evidence 'runs/validation/R19-HOST-VS-PICKUP-CAUSE-VERIFICATION-001/20261023T150909Z/summary.json' 'evidence/usb_cause/summary.json'
$inventory=[ordered]@{schema='vc-lora-publication-source-inventory-v1';scope='Selected byte-identical code and small evidence copies; no hardware interaction';files=@($records|Sort-Object destination)}
[IO.File]::WriteAllText((Join-Path $destination 'source_inventory.json'),($inventory|ConvertTo-Json -Depth 12)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
[pscustomobject]@{result='PACKAGED';files=$records.Count;bytes=($records|Measure-Object bytes -Sum).Sum;hardware_interaction=$false}|ConvertTo-Json
