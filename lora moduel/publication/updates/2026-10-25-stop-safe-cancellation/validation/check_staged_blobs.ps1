[CmdletBinding()]
param([string]$GitRoot='E:/VESC/_codex_build/mppt-lora-aux-20261022')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$relative='lora moduel/publication/updates/2026-10-25-stop-safe-cancellation'
$pub=Join-Path $GitRoot $relative
$inventory=Get-Content -LiteralPath (Join-Path $pub 'source_inventory.json') -Raw|ConvertFrom-Json
$format=& git -c ('safe.directory='+$GitRoot) -C $GitRoot rev-parse --show-object-format
if($LASTEXITCODE-ne0-or$format-cne'sha1'){throw 'Expected SHA1 Git object format'}
$entries=& git -c ('safe.directory='+$GitRoot) -C $GitRoot ls-files --stage -- $relative
if($LASTEXITCODE-ne0){throw 'Cannot inspect staged files'}
$index=@{}
foreach($line in $entries){if($line-cnotmatch'^100644 ([0-9a-f]{40}) 0\t(.+)$'){throw 'Unexpected index mode or stage'};$index[$Matches[2]]=$Matches[1]}
$checked=0
foreach($entry in $inventory.files){
  $path=$relative+'/'+$entry.target
  if(-not$index.ContainsKey($path)){throw ('Missing staged original: '+$entry.target)}
  $bytes=[IO.File]::ReadAllBytes((Join-Path $pub $entry.target))
  $header=[Text.Encoding]::UTF8.GetBytes(('blob '+$bytes.Length+[char]0))
  $sha=[Security.Cryptography.SHA1]::Create()
  try{$blob=([BitConverter]::ToString($sha.ComputeHash([byte[]]($header+$bytes)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
  if($blob-cne$index[$path]){throw ('Git index transformed original bytes: '+$entry.target)}
  $checked++
}
$result=[ordered]@{schema='vc-lora-publication-git-blob-audit-v1';result='PASS_BYTE_IDENTICAL_INDEX';copied_originals_checked=$checked;source_inventory_sha256=(Get-FileHash -LiteralPath (Join-Path $pub 'source_inventory.json') -Algorithm SHA256).Hash;source_snapshot_reformatted=$false;hardware_interaction=$false;network_operation=$false;acceptance_authorized=$false;deployment_authorized=$false}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'git_blob_audit.json'),($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$result|ConvertTo-Json
