[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputRoot='', [string]$OuterFixturePath='', [string]$CaseFilter='')
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Join-Path $PSScriptRoot '../..'}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not$OutputRoot){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-diagnostic-outer-v8-'+[guid]::NewGuid().ToString('N'))}
# Reuse only the existing pure v7 fixture constructors/setup. The prefix stops
# before any test or live entry point; imported outer functions are never run
# except the independent immutable-byte Get-StageProof validation path.
$fixtureSource=Join-Path $RepoRoot 'tests/hil/check_r19_aux_readiness_outer.ps1'
$tokens=$null;$errors=$null
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile($fixtureSource,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'AUX fixture does not parse'}
$firstCheck=@($fixtureAst.EndBlock.Statements|Where-Object{$_.Extent.Text.StartsWith("Check 'v7-fourteen-raw-baseline")})
if($firstCheck.Count-ne1){throw 'Unique safe fixture setup boundary required'}
$prefix=[IO.File]::ReadAllText($fixtureSource).Substring(0,$firstCheck[0].Extent.StartOffset)
. ([scriptblock]::Create($prefix)) -RepoRoot $RepoRoot -OutputRoot $OutputRoot -OuterFixturePath $OuterFixturePath
. (Join-Path $repo 'tools/read_r19_diagnostic_usb_failure_record.ps1') -ImportOnly
$DiagnosticUsbFailureDiagnostics=[switch]$true
$v8Checks=[Collections.Generic.List[object]]::new()
function V8Check([string]$Name,[scriptblock]$Body){
  try{&$Body;$v8Checks.Add([pscustomobject]@{name=$Name;passed=$true;error=''})}
  catch{$v8Checks.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message})}
}
function New-V8Summary {
  $s=New-V7Summary
  $s.schema='vc-lora-r19-runtime-stage-jtag-read-v8'
  $s|Add-Member NoteProperty diagnostic_usb_failure_required $true
  $manifest=Get-Content -LiteralPath $extendedManifestPath -Raw|ConvertFrom-Json
  $contract=Get-R19DiagnosticUsbFailureCandidateContract $repo $true
  $cap=Get-R19UsbRoleCapabilities -RepoRoot $repo -Mode ExplicitHostArm -Enabled $true
  $manifest.reader_schema=$s.schema
  $manifest|Add-Member NoteProperty diagnostic_usb_failure_diagnostics $contract
  $manifest|Add-Member NoteProperty usb_role_capabilities $cap
  $symbol=[pscustomobject]@{name='vc_lora_r19_diagnostic_usb_failure_record';address='0x3fcad800';size_bytes=256;aligned_32_bit=$true}
  $manifest.roles[0].runtime_diagnostic_symbols.symbols|Add-Member NoteProperty diagnostic_usb_failure $symbol
  $s.binding.artifact.symbols|Add-Member NoteProperty diagnostic_usb_failure (Copy-Json $symbol)
  $s.binding.artifact.extended_record_metadata.symbols|Add-Member NoteProperty diagnostic_usb_failure (Copy-Json $symbol)
  $s.binding|Add-Member NoteProperty diagnostic_usb_failure_address $symbol.address
  $s.binding.artifact|Add-Member NoteProperty diagnostic_usb_failure_enabled $true
  foreach($node in @($s.binding,$s.binding.artifact)){
    $node|Add-Member NoteProperty diagnostic_usb_failure_diagnostics (Copy-Json $contract)
    $node|Add-Member NoteProperty usb_role_capabilities (Copy-Json $cap)
  }
  Copy-Item -LiteralPath (Join-Path $repo $contract.decoder.path) -Destination (Join-Path $extendedDirectory ('evidence/'+$contract.decoder.path)) -Force
  $map=[string]$s.binding.artifact.map_path
  [IO.File]::AppendAllText($map,[Environment]::NewLine+'0x3fcad800 vc_lora_r19_diagnostic_usb_failure_record',$utf8)
  $mapSha=Get-Sha256 $map
  $manifest.roles[0].runtime_diagnostic_symbols.map_sha256=$mapSha
  $manifest.roles[0].reproducibility_artifacts.files[1].sha256=$mapSha
  $s.binding.artifact.map_sha256=$mapSha
  $s.binding.artifact.extended_record_metadata.map_sha256=$mapSha
  [uint32[]]$words=New-Object uint32[] 64
  $words[1]=2;$words[2]=0x44313955;$words[3]=1;$words[4]=1;$words[13]=1
  for($i=0;$i-lt4;$i++){$words[5+$i]=@(0x52313944,0x53544731,0x32303236,0x31303033)[$i];$words[9+$i]=@(170,187,204,221)[$i]}
  [byte[]]$bytes=Pack-Words $words
  foreach($sample in 1,2){
    $leaf=if($sample-eq1){'diagnostic_usb_failure_first.bin'}else{'diagnostic_usb_failure_second.bin'}
    $path=Join-Path $extendedDirectory $leaf;[IO.File]::WriteAllBytes($path,$bytes)
    $s.reads+=@([pscustomobject]@{record='diagnostic_usb_failure';sample=$sample;size_bytes=256;path=$path;sha256=Get-Sha256 $path})
  }
  $s.decoded|Add-Member NoteProperty diagnostic_usb_failure (ConvertFrom-R19DiagnosticUsbFailureRecord -First $bytes -Second $bytes -ExpectedRole ground -ExpectedFingerprint ([uint32[]]@(0x52313944,0x53544731,0x32303236,0x31303033)) -ExpectedBoot ([uint32[]]@(170,187,204,221)))
  Save-Manifest $manifest $s
  $script:extendedFixtureCandidate.reader_schema=$s.schema
  $flashPath=Join-Path $extendedDirectory 'flash_record.json'
  $flash=Get-Content -LiteralPath $flashPath -Raw|ConvertFrom-Json
  $flash|Add-Member NoteProperty diagnostic_usb_failure_diagnostics (Copy-Json $contract)
  $flash|Add-Member NoteProperty usb_role_capabilities (Copy-Json $cap)
  $flash|Add-Member NoteProperty reader_schema $s.schema
  [IO.File]::WriteAllText($flashPath,($flash|ConvertTo-Json -Depth 30),$utf8)
  $s.binding.flash.sha256=Get-Sha256 $flashPath
  return $s
}
function Change-DiagnosticRaw($Summary,[int]$Word,[uint32]$Value,[switch]$OnlyFirst){
  foreach($read in @($Summary.reads|Where-Object{$_.record-ceq'diagnostic_usb_failure'-and(-not$OnlyFirst-or$_.sample-eq1)})){
    [byte[]]$bytes=[IO.File]::ReadAllBytes($read.path);Set-U32 $bytes $Word $Value
    [IO.File]::WriteAllBytes($read.path,$bytes);$read.sha256=Get-Sha256 $read.path
  }
}
V8Check 'v8-sixteen-raw-real-outer-baseline' {
  $s=New-V8Summary;$proof=Get-ExtendedProof $s
  Require ($proof.proven-and$proof.extended_raw_replay.raw_read_count-eq16) ('v8 baseline rejected: '+$proof.validation_error)
  Require ($proof.extended_raw_replay.diagnostic_usb_failure_record.schema-ceq'vc-lora-r19-diagnostic-usb-failure-decoded-v1') 'eighth raw record not returned'
  Require (-not$proof.extended_raw_replay.record_acquisition_proves_usb_success) 'raw acquisition invented USB success'
}
foreach($case in @('raw-sha','raw-unrehashed','unstable','missing-read','extra-read','wrong-order','short-raw','wrong-leaf','wrong-role','wrong-boot','wrong-build','odd-sequence','active-writer','reserved','metadata-size','redundant-symbol-size','metadata-address','decoder-sha','decoder-copy','decoded-json','missing-required','string-required','role-escalation','missing-optin','artifact-disabled','flash-role-mismatch')|Where-Object{-not$CaseFilter-or$_-ceq$CaseFilter}){
  V8Check ('v8-reject-'+$case) {
    $s=New-V8Summary
    switch($case){
      'raw-sha'{$s.reads[14].sha256='0'*64}
      'raw-unrehashed'{[byte[]]$b=[IO.File]::ReadAllBytes($s.reads[14].path);$b[0]=1;[IO.File]::WriteAllBytes($s.reads[14].path,$b)}
      'unstable'{Change-DiagnosticRaw $s 1 4 -OnlyFirst}
      'missing-read'{$s.reads=@($s.reads|Select-Object -First 15)}
      'extra-read'{$s.reads+=@($s.reads[14])}
      'wrong-order'{$swap=$s.reads[14];$s.reads[14]=$s.reads[15];$s.reads[15]=$swap}
      'short-raw'{[byte[]]$b=[IO.File]::ReadAllBytes($s.reads[14].path);[IO.File]::WriteAllBytes($s.reads[14].path,$b[0..251]);$s.reads[14].sha256=Get-Sha256 $s.reads[14].path}
      'wrong-leaf'{$p=Join-Path $extendedDirectory 'wrong-diagnostic.bin';Copy-Item $s.reads[14].path $p -Force;$s.reads[14].path=$p}
      'wrong-role'{Change-DiagnosticRaw $s 4 2}
      'wrong-boot'{Change-DiagnosticRaw $s 9 171}
      'wrong-build'{Change-DiagnosticRaw $s 5 1}
      'odd-sequence'{Change-DiagnosticRaw $s 1 3}
      'active-writer'{Change-DiagnosticRaw $s 0 1}
      'reserved'{Change-DiagnosticRaw $s 63 1}
      'metadata-size'{$s.binding.artifact.extended_record_metadata.symbols.diagnostic_usb_failure.size_bytes=252}
      'redundant-symbol-size'{$s.binding.artifact.symbols.diagnostic_usb_failure.size_bytes=252}
      'metadata-address'{$s.binding.diagnostic_usb_failure_address='0x3fcad900'}
      'decoder-sha'{$s.binding.diagnostic_usb_failure_diagnostics.decoder.sha256='0'*64}
      'decoder-copy'{[IO.File]::AppendAllText((Join-Path $extendedDirectory 'evidence/tools/read_r19_diagnostic_usb_failure_record.ps1'),'#changed',$utf8)}
      'decoded-json'{$s.decoded.diagnostic_usb_failure.failure_latched=$true}
      'missing-required'{$s.PSObject.Properties.Remove('diagnostic_usb_failure_required')}
      'string-required'{$s.diagnostic_usb_failure_required='true'}
      'role-escalation'{$s.binding.usb_role_capabilities.roles[0].arm=$true}
      'missing-optin'{$DiagnosticUsbFailureDiagnostics=[switch]$false}
      'artifact-disabled'{$s.binding.artifact.diagnostic_usb_failure_enabled=$false}
      'flash-role-mismatch'{$p=Join-Path $extendedDirectory 'flash_record.json';$f=Get-Content $p -Raw|ConvertFrom-Json;$f.usb_role_capabilities.roles[0].arm=$true;[IO.File]::WriteAllText($p,($f|ConvertTo-Json -Depth 30),$utf8);$s.binding.flash.sha256=Get-Sha256 $p}
    }
    try{$proof=Get-ExtendedProof $s}finally{$DiagnosticUsbFailureDiagnostics=[switch]$true}
    Require (-not$proof.proven) ('v8 mutation accepted: '+$case)
  }
}
$failed=@($v8Checks|Where-Object{-not$_.passed})
$result=[pscustomobject][ordered]@{schema='vc-lora-r19-diagnostic-usb-outer-raw-contract-v1';result=$(if($failed.Count){'FAIL'}else{'PASS'});hardware_interaction=$false;com_open_attempts=0;native_hardware_calls=0;passed_count=($v8Checks.Count-$failed.Count);failed_count=$failed.Count;checks=@($v8Checks)}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'diagnostic_usb_outer_raw_summary.json'),($result|ConvertTo-Json -Depth 12),$utf8)
$result|ConvertTo-Json -Depth 12
if($failed.Count){exit 1}
