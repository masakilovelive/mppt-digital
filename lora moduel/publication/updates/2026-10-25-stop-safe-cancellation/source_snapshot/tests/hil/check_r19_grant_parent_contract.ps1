param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),[string]$OutputRoot='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$script:checks=0
function Check([bool]$v,[string]$name){if(-not$v){throw "FAIL $name"};$script:checks++}
$parent=Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1'
$text=Get-Content -LiteralPath $parent -Raw
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($parent,[ref]$tokens,[ref]$errors)
Check (@($errors).Count-eq0) 'parent AST parses'
Check (@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantDiagnostics'}).Count-eq1) 'explicit opt-in Grant CLI parameter'
Check ($text.Contains('-GrantDiagnostics ([bool]$GrantDiagnostics)')) 'prepared contract Grant selection is typed and explicit'
Check ($text.Contains('grant_diagnostics=[bool]$PSBoundParameters[''GrantDiagnostics'']')) 'single-run execution permit binds typed Grant selection'
foreach($name in @('installArguments','captureArguments','rollbackArguments','jtagPreflightArguments')){
  Check ($text-match('\$'+$name+'\s*\+=.*GrantDiagnostics')) ('Grant flag propagated to '+$name)
}
Check ($text.Contains('grant_diagnostics_enabled=[bool]$GrantDiagnostics')) 'top summary records Grant mode'
Check ($text.Contains('function Get-GrantDiagnosticRawReplay')) 'independent paired Grant raw replay exists'
Check ($text.Contains('grant_diagnostic_record=if($hasGrantDiagnostics)')) 'summary retains independent Grant raw reprojection'
function ImportFunction([string[]]$Names){foreach($f in $ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-cin$Names}){. ([scriptblock]::Create('function script:'+($f.Extent.Text.Substring(9))))}}
ImportFunction @('Assert-Condition','Assert-RawProjection','Get-Sha256','Get-GrantDiagnosticRawReplay','Assert-CandidateDiagnosticAbiContract')
if(-not$OutputRoot){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-grant-parent-'+[guid]::NewGuid().ToString('N'))}
[void](New-Item -ItemType Directory -Force -Path $OutputRoot)
$repo=$RepoRoot
. (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')
. (Join-Path $RepoRoot 'tools/read_r19_grant_diagnostic_record.ps1') -ImportOnly
$timedPathEnabled=$true;$AuxReadinessDiagnostics=$true;$DiagnosticUsbFailureDiagnostics=$true;$TimedPathMode='ExplicitHostArm';$GrantDiagnostics=$true
function NewAbi {
  [pscustomobject]@{endpoint_fifo_schema=2;endpoint_fifo_size_bytes=112;runtime_stage_size_bytes=68;reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9'
    usb_extended_diagnostics=[pscustomobject]@{schema='vc-lora-r19-usb-extended-diagnostics-v2';enabled=$true;records=[pscustomobject]@{
      hwcdc_restart=[pscustomobject]@{symbol='vc_lora_r19_hwcdc_restart_diagnostic_record';schema_version=1;size_bytes=128}
      ground_usb_commit=[pscustomobject]@{symbol='vc_lora_r19_ground_usb_commit_record';schema_version=1;size_bytes=128}
      first_usb_failure=[pscustomobject]@{symbol='vc_lora_r19_first_usb_failure_record';schema_version=1;size_bytes=384}}}
    first_usb_failure_decoder=[pscustomobject]@{path='tools/read_r19_first_usb_failure_record.ps1';sha256=Get-Sha256 (Join-Path $RepoRoot 'tools/read_r19_first_usb_failure_record.ps1')}
    timed_path_diagnostics=(Get-R19TimedPathCandidateContract $RepoRoot $TimedPathMode)
    aux_readiness_diagnostics=(Get-R19AuxReadinessCandidateContract $RepoRoot $true)
    diagnostic_usb_failure_diagnostics=(Get-R19DiagnosticUsbFailureCandidateContract $RepoRoot $true)
    usb_role_capabilities=(Get-R19UsbRoleCapabilities $RepoRoot $TimedPathMode $true)
    grant_diagnostics=(Get-R19GrantDiagnosticCandidateContract $RepoRoot $true)}
}
$abi=NewAbi;Assert-CandidateDiagnosticAbiContract $abi 'valid-v9';Check ($abi.diagnostic_usb_failure_diagnostics.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v8') 'v9 top retains unchanged nested v8 USB ABI'
foreach($mutation in @('top-downgrade','grant-size','grant-version','grant-decoder','grant-reader','missing-grant','nested-usb-upgrade')){
  $abi=NewAbi
  switch($mutation){
    'top-downgrade'{$abi.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8'}
    'grant-size'{$abi.grant_diagnostics.record.size_bytes=1020}
    'grant-version'{$abi.grant_diagnostics.record.schema_version=2}
    'grant-decoder'{$abi.grant_diagnostics.decoder.sha256='0'*64}
    'grant-reader'{$abi.grant_diagnostics.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8'}
    'missing-grant'{$abi.PSObject.Properties.Remove('grant_diagnostics')}
    'nested-usb-upgrade'{$abi.diagnostic_usb_failure_diagnostics.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9'}
  }
  $rejected=$false;try{Assert-CandidateDiagnosticAbiContract $abi $mutation}catch{$rejected=$true};Check $rejected ('ABI reject '+$mutation)
}
$abi=NewAbi;$GrantDiagnostics=$false;$rejected=$false;try{Assert-CandidateDiagnosticAbiContract $abi 'not-opted-in'}catch{$rejected=$true};Check $rejected 'Grant v9 cannot silently upgrade old mode'
$abi.PSObject.Properties.Remove('grant_diagnostics');$abi.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8';Assert-CandidateDiagnosticAbiContract $abi 'old-v8';Check $true 'legacy v8 remains valid without opt-in'
$GrantDiagnostics=$true
$candidate=[pscustomobject]@{artifact_root=$OutputRoot}
$sealedDecoder=Join-Path $OutputRoot 'evidence/tools/read_r19_grant_diagnostic_record.ps1'
[void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sealedDecoder))
Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/read_r19_grant_diagnostic_record.ps1') -Destination $sealedDecoder
[uint32[]]$legacy=[uint32[]]::new(17);$legacy[5]=1;$legacy[6]=2;$legacy[7]=3;$legacy[8]=4
$firstUsb=[pscustomobject]@{boot_instance=@(5,6,7,8)}
function NewFixture {
  $contract=Get-R19GrantDiagnosticCandidateContract $RepoRoot $true
  [uint32[]]$words=[uint32[]]::new(256);$words[1]=2;$words[2]=0x52313947;$words[3]=1;$words[4]=1;$words[13]=1;$words[14]=1024
  for($n=0;$n-lt4;$n++){$words[5+$n]=[uint32](1+$n);$words[9+$n]=[uint32](5+$n)}
  [byte[]]$bytes=[byte[]]::new(1024);for($n=0;$n-lt256;$n++){[BitConverter]::GetBytes($words[$n]).CopyTo($bytes,4*$n)}
  $reads=@(0..15|ForEach-Object{$null})
  foreach($sample in 1,2){$name=if($sample-eq1){'first'}else{'second'};$path=Join-Path $OutputRoot ('grant_diagnostic_'+$name+'.bin');[IO.File]::WriteAllBytes($path,$bytes);$reads+=,[pscustomobject]@{record='grant_diagnostic';sample=$sample;size_bytes=1024;path=$path;sha256=Get-Sha256 $path}}
  $symbol=[pscustomobject]@{name='vc_lora_r19_grant_diagnostic_record';address='0x3fcb0000';size_bytes=1024;aligned_32_bit=$true}
  $manifest=[pscustomobject]@{grant_diagnostics=$contract;canonical_source_snapshot=[pscustomobject]@{files=@([pscustomobject]@{path=$contract.decoder.path;sha256=$contract.decoder.sha256})}}
  $summary=[pscustomobject]@{schema='vc-lora-r19-runtime-stage-jtag-read-v9';grant_diagnostics_required=$true;reads=$reads
    binding=[pscustomobject]@{grant_diagnostics=$contract;grant_diagnostic_address=$symbol.address;artifact=[pscustomobject]@{grant_diagnostics=$contract;grant_diagnostics_enabled=$true;symbols=[pscustomobject]@{grant_diagnostic=$symbol}}}
    decoded=[pscustomobject]@{grant_diagnostic=(ConvertFrom-R19GrantDiagnosticRecord -First $bytes -Second $bytes -ExpectedRole ground -ExpectedFingerprint @(1,2,3,4) -ExpectedBoot @(5,6,7,8))}}
  return [pscustomobject]@{summary=$summary;manifest=$manifest;sealed=[pscustomobject]@{symbols=[pscustomobject]@{grant_diagnostic=$symbol}}}
}
function Replay($f){Get-GrantDiagnosticRawReplay -Summary $f.summary -Role ground -EvidenceDirectory $OutputRoot -Manifest $f.manifest -Sealed $f.sealed -Ranges @([pscustomobject]@{start=[uint64]0x3fca0000;end=[uint64]0x3fca0100}) -TimedStart ([uint64]0x3fca1000) -AuxStart ([uint64]0x3fca2000) -DiagnosticStart ([uint64]0x3fca4000) -LegacyWords $legacy -FirstUsbFailure $firstUsb}
$f=NewFixture;$d=Replay $f
Check ($d.role-ceq'ground'-and$d.raw_size_bytes-eq1024-and$d.expected_identity_bound-and-not$d.acceptance_authorized) 'ninth record independently decoded and build/boot bound'
foreach($mutation in @('missing-required','string-required','missing-artifact-flag','string-artifact-flag','wrong-top-contract','wrong-artifact-contract','symbol-name','symbol-size','symbol-string-size','unaligned','overlap-legacy','overlap-timed','overlap-aux','overlap-diagnostic','wrong-read-order','wrong-sample','string-sample','short-read','string-size','outside-directory','wrong-name','hash-tamper','different-reads','wrong-boot','wrong-build','decoded-role','decoded-boolean','missing-source','wrong-source-sha','sealed-decoder-sha')){
  $f=NewFixture
  switch($mutation){
    'missing-required'{$f.summary.PSObject.Properties.Remove('grant_diagnostics_required')}
    'string-required'{$f.summary.grant_diagnostics_required='true'}
    'missing-artifact-flag'{$f.summary.binding.artifact.PSObject.Properties.Remove('grant_diagnostics_enabled')}
    'string-artifact-flag'{$f.summary.binding.artifact.grant_diagnostics_enabled='true'}
    'wrong-top-contract'{$f.summary.binding.grant_diagnostics=$null}
    'wrong-artifact-contract'{$f.summary.binding.artifact.grant_diagnostics=$null}
    'symbol-name'{$f.sealed.symbols.grant_diagnostic.name='not-grant'}
    'symbol-size'{$f.sealed.symbols.grant_diagnostic.size_bytes=1020}
    'symbol-string-size'{$f.sealed.symbols.grant_diagnostic.size_bytes='1024'}
    'unaligned'{$f.sealed.symbols.grant_diagnostic.address='0x3fcb0001'}
    'overlap-legacy'{$f.sealed.symbols.grant_diagnostic.address='0x3fca0000'}
    'overlap-timed'{$f.sealed.symbols.grant_diagnostic.address='0x3fca1000'}
    'overlap-aux'{$f.sealed.symbols.grant_diagnostic.address='0x3fca2000'}
    'overlap-diagnostic'{$f.sealed.symbols.grant_diagnostic.address='0x3fca4000'}
    'wrong-read-order'{$f.summary.reads[16].record='diagnostic_usb_failure'}
    'wrong-sample'{$f.summary.reads[16].sample=2}
    'string-sample'{$f.summary.reads[16].sample='1'}
    'short-read'{$f.summary.reads[16].size_bytes=1020}
    'string-size'{$f.summary.reads[16].size_bytes='1024'}
    'outside-directory'{$outside=Join-Path $OutputRoot 'outside';[void](New-Item -ItemType Directory -Force -Path $outside);$path=Join-Path $outside 'grant_diagnostic_first.bin';Copy-Item -LiteralPath $f.summary.reads[16].path -Destination $path;$f.summary.reads[16].path=$path}
    'wrong-name'{$path=Join-Path $OutputRoot 'renamed.bin';Copy-Item -LiteralPath $f.summary.reads[16].path -Destination $path;$f.summary.reads[16].path=$path}
    'hash-tamper'{$f.summary.reads[16].sha256='0'*64}
    'different-reads'{$path=$f.summary.reads[17].path;$bytes=[IO.File]::ReadAllBytes($path);$bytes[4]=4;[IO.File]::WriteAllBytes($path,$bytes);$f.summary.reads[17].sha256=Get-Sha256 $path}
    'wrong-boot'{$f.summary.decoded.grant_diagnostic.boot_instance[0]=99}
    'wrong-build'{$f.summary.decoded.grant_diagnostic.build_fingerprint[0]=99}
    'decoded-role'{$f.summary.decoded.grant_diagnostic.role='vehicle'}
    'decoded-boolean'{$f.summary.decoded.grant_diagnostic.failure_latched='false'}
    'missing-source'{$f.manifest.canonical_source_snapshot.files=@()}
    'wrong-source-sha'{$f.manifest.canonical_source_snapshot.files[0].sha256='0'*64}
    'sealed-decoder-sha'{[IO.File]::AppendAllText($sealedDecoder,'# mutation')}
  }
  if($mutation-in@('unaligned','overlap-legacy','overlap-timed','overlap-aux','overlap-diagnostic')){$f.summary.binding.grant_diagnostic_address=$f.sealed.symbols.grant_diagnostic.address}
  $rejected=$false;try{$null=Replay $f}catch{$rejected=$true};Check $rejected ('reject '+$mutation)
  if($mutation-ceq'sealed-decoder-sha'){Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/read_r19_grant_diagnostic_record.ps1') -Destination $sealedDecoder -Force}
}
Write-Output "GRANT_PARENT_CONTRACT PASS $script:checks checks fixtures=$OutputRoot"
