[CmdletBinding()]
param([string]$PublicationRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($PublicationRoot)
$inventory=Get-Content -LiteralPath (Join-Path $root 'source_inventory.json') -Raw|ConvertFrom-Json
$checked=0
foreach($entry in $inventory.files){
  $path=[IO.Path]::GetFullPath((Join-Path $root $entry.destination))
  if(-not $path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Inventory path escapes publication'}
  if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256){throw ('Hash mismatch: '+$entry.destination)}
  $checked++
}
$forbidden=@('.exe','.dll','.elf','.map','.bin','.pyc','.zip','.env','.pem','.pfx','.key')
$findings=[Collections.Generic.List[string]]::new()
$patterns=@('vck_[A-Za-z0-9_-]{25,}','ghp_[A-Za-z0-9]{30,}','github_pat_[A-Za-z0-9_]{30,}','sk-proj-[A-Za-z0-9_-]{25,}','-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----')
foreach($file in Get-ChildItem -LiteralPath $root -Recurse -File){
  if($file.Extension.ToLowerInvariant() -in $forbidden -or $file.Name -like '.env*'){throw ('Forbidden publication file: '+$file.Name)}
  if($file.Length -gt 2MB){throw ('Unexpected large file: '+$file.Name)}
  $content=[IO.File]::ReadAllText($file.FullName)
  foreach($pattern in $patterns){if($content -match $pattern){$findings.Add($file.FullName);break}}
  if($file.Extension -eq '.json'){$null=$content|ConvertFrom-Json}
  if($file.Extension -eq '.md'){
    foreach($m in [regex]::Matches($content,'\]\(([^)]+)\)')){
      $link=$m.Groups[1].Value
      if($link -match '^(https?:|#|mailto:)'){continue}
      $target=Join-Path $file.DirectoryName ([Uri]::UnescapeDataString(($link -split '#')[0]))
      if(-not(Test-Path -LiteralPath $target)){throw ('Broken local Markdown link: '+$link)}
    }
  }
}
if($findings.Count){throw ('Potential credentials in '+$findings.Count+' files; values withheld')}
$current=Get-Content -LiteralPath (Join-Path $root 'evidence/current/comparison_outcome.json') -Raw|ConvertFrom-Json
if($current.product_evaluation.ground_product_heartbeat_frames -ne 0 -or $current.product_evaluation.product_usb_106ms -ne 'NOT_EVALUATED'){throw 'Current run product scope changed'}
if(-not $current.accepted_r18_restored_both_roles -or $current.conclusion.root_cause_proven){throw 'Current run disposition changed'}
[pscustomobject]@{schema='vc-lora-publication-validation-v1';result='PASS';original_files_hash_verified=$checked;secret_pattern_findings=0;forbidden_files=0;local_links='PASS';json_parse='PASS';hardware_interaction=$false}|ConvertTo-Json
