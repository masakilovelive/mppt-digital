[CmdletBinding()]
param([string]$RepoRoot='')
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Check $failed $Message}
. (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')
Check ($null-ne(Get-Command Get-R19GrantDiagnosticCandidateContract -ErrorAction SilentlyContinue)) 'Missing explicit Grant diagnostic artifact contract'
Check ((Get-R19CandidateOutputLeaf $true ExplicitHostArm $true $true $true)-ceq'R19-GRANT-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001') 'Grant diagnostics must publish to a fresh isolated output leaf'
foreach($modeArgs in @(@($false,'ExplicitHostArm',$true,$true,$true),@($true,'Disabled',$true,$true,$true),@($true,'ExplicitHostArm',$false,$true,$true),@($true,'ExplicitHostArm',$true,$false,$true))){Reject {Get-R19CandidateOutputLeaf $modeArgs[0] $modeArgs[1] $modeArgs[2] $modeArgs[3] $modeArgs[4]} 'Partial Grant diagnostic mode must reject'}
Check ((Get-R19CandidateOutputLeaf $true ExplicitHostArm $true $true)-ceq'R19-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001') 'Default-off legacy v8 output must remain unchanged'
Check ($null-eq(Get-R19GrantDiagnosticCandidateContract $RepoRoot $false)) 'Default-off mode must have no Grant record contract'
function Import-Functions([string]$Relative,[string[]]$Names){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $Relative),[ref]$tokens,[ref]$errors)
  Check (@($errors).Count-eq0) ('PowerShell parse '+$Relative)
  foreach($node in $ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and($Names.Count-eq0-or$_.Name-cin$Names)}){. ([scriptblock]::Create($node.Extent.Text));Set-Item -Path ('Function:script:'+$node.Name) -Value (Get-Item ('Function:'+$node.Name)).ScriptBlock}
}
Import-Functions 'tools/read_r19_runtime_stage_jtag.ps1' @()
Import-Functions 'tests/arduino_compile/check_r19_usb_extended_live_reader_contract.ps1' @('New-Candidate','New-FirstFailureCandidate','Save-Candidate','Json-Write')
Import-Functions 'tests/hil/check_r19_aux_readiness_artifact.ps1' @('New-AuxCandidate')
Import-Functions 'tests/hil/check_r19_diagnostic_usb_failure_record.ps1' @('Pack','NewV8Fixture','NewV8Candidate')
$fixtureRoot=Join-Path $RepoRoot ('runs/validation/R19-GRANT-ARTIFACT-CONTRACT-TEST-001/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$OutputRoot=Join-Path $fixtureRoot 'sealed';[void][IO.Directory]::CreateDirectory($OutputRoot)
$repo=$RepoRoot;$readerPath=Join-Path $RepoRoot 'tools/read_r19_runtime_stage_jtag.ps1'
foreach($spec in @(@('R19FirstFailureDecoderPath','read_r19_first_usb_failure_record.ps1'),@('R19TimedPathDecoderPath','read_r19_timed_path_record.ps1'),@('R19AuxReadinessDecoderPath','read_r19_aux_readiness_record.ps1'),@('R19DiagnosticUsbFailureDecoderPath','read_r19_diagnostic_usb_failure_record.ps1'),@('R19GrantDiagnosticDecoderPath','read_r19_grant_diagnostic_record.ps1'))){Set-Variable -Scope Script -Name $spec[0] -Value (Join-Path $RepoRoot ('tools/'+$spec[1]))}
$grantContract=Get-R19GrantDiagnosticCandidateContract $RepoRoot $true
Check ($grantContract.record.size_bytes-eq1024-and$grantContract.record.symbol-ceq'vc_lora_r19_grant_diagnostic_record'-and$grantContract.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v9') 'Grant exact ABI and reader generation'
Check ($grantContract.decoder.sha256-ceq(Get-Sha256 $script:R19GrantDiagnosticDecoderPath)) 'Grant decoder exact fingerprint'
Check ((Get-R19CandidateCompileProperty $true ExplicitHostArm $true $true $true).EndsWith(' -DVC_LORA_R19_GRANT_DIAGNOSTICS=1')) 'Grant macro is explicit opt-in'
$source=@(Get-R19CandidateSourceFiles $RepoRoot ExplicitHostArm $true $true $true|ForEach-Object{$_.FullName.Replace('\','/')})
foreach($suffix in @('/firmware/high_speed/r19_grant_diagnostic_record.hpp','/tools/read_r19_grant_diagnostic_record.ps1')){Check (@($source|Where-Object{$_.EndsWith($suffix)}).Count-eq1) ('Grant canonical source exactly once '+$suffix)}
$legacySource=@(Get-R19CandidateSourceFiles $RepoRoot ExplicitHostArm $true $true|ForEach-Object{$_.FullName.Replace('\','/')})
Check (@($legacySource|Where-Object{$_.EndsWith('/r19_grant_diagnostic_record.hpp')-or$_.EndsWith('/read_r19_grant_diagnostic_record.ps1')}).Count-eq0) 'Legacy mode has no silently enabled Grant source'
$NmExecutable=Join-Path $OutputRoot 'mock-nm.ps1'
[IO.File]::WriteAllText($NmExecutable,'param($a,$b,$c);Get-Content (Join-Path $PSScriptRoot ''nm.txt'');$global:LASTEXITCODE=0')
$NmSha256=Get-Sha256 $NmExecutable
$nmNine=@('3fcab000 00000044 B vc_lora_r19_runtime_stage_record','3fcab100 00000070 B vc_lora_r19_hwcdc_fifo_diagnostic_record','3fcab200 00000080 B vc_lora_r19_hwcdc_restart_diagnostic_record','3fcab300 00000080 B vc_lora_r19_ground_usb_commit_record','3fcab400 00000180 B vc_lora_r19_first_usb_failure_record','3fcab600 00000200 B vc_lora_r19_timed_path_record','3fcac000 00001800 B vc_lora_r19_aux_readiness_record','3fcad800 00000100 B vc_lora_r19_diagnostic_usb_failure_record','3fcadc00 00000400 B vc_lora_r19_grant_diagnostic_record')-join"`n"
function NewV9Candidate([string]$Name){
  $c=NewV8Candidate $Name;$pin=Get-R19GrantDiagnosticCandidateContract $RepoRoot $true
  foreach($doc in @($c.manifest,$c.seal,$c.handoff)){
    $doc.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9';$doc.grant_diagnostics=$pin
    $doc.roles[0].runtime_diagnostic_symbols.symbols.grant_diagnostic=[ordered]@{name='vc_lora_r19_grant_diagnostic_record';address='0x3fcadc00';size_bytes=1024;aligned_32_bit=$true}
  }
  $flag=Get-R19CandidateCompileProperty $true ExplicitHostArm $true $true $true
  $c.manifest.candidate_enable.property=$flag;$c.manifest.roles[0].compile.argv=@($flag)
  $c.manifest.canonical_source_snapshot.files+=@([ordered]@{path=$pin.decoder.path;sha256=$pin.decoder.sha256;size_bytes=(Get-Item -LiteralPath $script:R19GrantDiagnosticDecoderPath).Length})
  Copy-Item -LiteralPath $script:R19GrantDiagnosticDecoderPath -Destination (Join-Path $c.root 'evidence/tools/read_r19_grant_diagnostic_record.ps1')
  Save-Candidate $c;return $c
}
function BindV9($Candidate){Assert-ArtifactBinding -Root $Candidate.root -ExpectedArtifactId mock-candidate -ExpectedRole ground -ExpectedAddress ([uint32]0x3fcab000)}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmNine)
$candidate=NewV9Candidate 'positive';$bound=BindV9 $candidate
Check ($bound.grant_diagnostics_enabled-and$bound.grant_diagnostic_address-ceq'0x3fcadc00'-and$bound.symbols.Count-eq9) 'Strict sealed ninth symbol binding'
Check ($script:R19GrantDecoderVerifiedSha256-ceq$grantContract.decoder.sha256-and-not[string]::IsNullOrWhiteSpace($script:R19GrantDecoderVerifiedText)) 'Ninth decoder fingerprint verified into memory'
foreach($mutation in @('missing-seal','downgrade','missing-symbol','wrong-size','wrong-storage','overlap','missing-decoder','decoder-source','decoder-hash','missing-flag','undeclared-contract','no-usb','wrong-case')){
  [IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmNine);$candidate=NewV9Candidate ('reject-'+$mutation)
  switch($mutation){
    'missing-seal'{$candidate.seal.Remove('grant_diagnostics')}
    'downgrade'{$candidate.handoff.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8'}
    'missing-symbol'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),(($nmNine-split"`n"|Where-Object{$_-notmatch'grant_diagnostic_record'})-join"`n"))}
    'wrong-size'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmNine.Replace('00000400 B vc_lora_r19_grant','000003fc B vc_lora_r19_grant'))}
    'wrong-storage'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmNine.Replace('00000400 B vc_lora_r19_grant','00000400 D vc_lora_r19_grant'))}
    'overlap'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmNine.Replace('3fcadc00','3fcad7fc'))}
    'missing-decoder'{[IO.File]::WriteAllText((Join-Path $candidate.root 'evidence/tools/read_r19_grant_diagnostic_record.ps1'),'not the sealed decoder')}
    'decoder-source'{$candidate.manifest.canonical_source_snapshot.files=@($candidate.manifest.canonical_source_snapshot.files|Where-Object{$_.path-cne'tools/read_r19_grant_diagnostic_record.ps1'})}
    'decoder-hash'{$candidate.manifest.grant_diagnostics.decoder.sha256='0'*64}
    'missing-flag'{$candidate.manifest.roles[0].compile.argv=@((Get-R19CandidateCompileProperty $true ExplicitHostArm $true $true))}
    'undeclared-contract'{foreach($doc in @($candidate.manifest,$candidate.seal,$candidate.handoff)){$doc.Remove('grant_diagnostics')}}
    'no-usb'{foreach($doc in @($candidate.manifest,$candidate.seal,$candidate.handoff)){$doc.Remove('diagnostic_usb_failure_diagnostics')}}
    'wrong-case'{$value=$candidate.manifest.grant_diagnostics;$candidate.manifest.Remove('grant_diagnostics');$candidate.manifest.Grant_Diagnostics=$value}
  }
  Save-Candidate $candidate;Reject {BindV9 $candidate} ('Strict v9 candidate mutation '+$mutation)
}
function NewV9Fixture([string]$Role='ground'){
  $f=NewV8Fixture $Role;$f.schema='vc-lora-r19-usb-extended-jtag-fixture-v9';$f.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9'
  $f.grant_diagnostics=Get-R19GrantDiagnosticCandidateContract $RepoRoot $true
  [uint32[]]$words=[uint32[]]::new(256);$words[1]=2;$words[2]=0x52313947;$words[3]=1;$words[4]=if($Role-ceq'ground'){1}else{2};$words[13]=1;$words[14]=1024
  for($i=0;$i-lt4;$i++){$words[5+$i]=[uint32]@(0x52313944,0x53544731,0x32303236,0x31303033)[$i];$words[9+$i]=[uint32](1+$i)}
  $f.grant_diagnostic_address='0x3fcadc00';$f.grant_diagnostic_first_read_base64=[Convert]::ToBase64String((Pack $words));$f.grant_diagnostic_second_read_base64=$f.grant_diagnostic_first_read_base64
  return $f
}
$shellPath=if($PSVersionTable.PSEdition-ceq'Core'){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
function RunV9Fixture([string]$Name,$Fixture,[bool]$Pass){
  $caseRoot=Join-Path $fixtureRoot $Name;[void][IO.Directory]::CreateDirectory($caseRoot)
  $path=Join-Path $caseRoot 'fixture.json';[IO.File]::WriteAllText($path,($Fixture|ConvertTo-Json -Depth 25))
  & $shellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $readerPath -OfflineExtendedRecordFixtureOnly -FixturePath $path -OutputRoot (Join-Path $caseRoot 'read') *> (Join-Path $caseRoot 'reader.log')
  $code=$LASTEXITCODE;$result=Get-Content -LiteralPath (Join-Path $caseRoot 'read/summary.json') -Raw|ConvertFrom-Json
  Check $(if($Pass){$code-eq0-and$result.result-ceq'PASS'-and@($result.reads).Count-eq18-and$result.schema-ceq'vc-lora-r19-usb-extended-offline-read-v9'-and$result.decoded.grant_diagnostic.expected_identity_bound}else{$code-ne0-and$result.result-ceq'FAIL'}) ('Offline v9 fixture '+$Name)
  return $result
}
$ground=RunV9Fixture 'ground-nine-records' (NewV9Fixture ground) $true
$vehicle=RunV9Fixture 'vehicle-nine-records' (NewV9Fixture vehicle) $true
Check (-not$ground.hardware_interaction-and$vehicle.decoded.grant_diagnostic.role-ceq'vehicle'-and$vehicle.decoded.timed_path.mode-ceq'SyncOnly') 'Offline decoded role and no hardware interaction'
foreach($mutation in @('downgrade','fixture-downgrade','missing-second','size','different-read','new-boot','new-build','overlap','decoder-pin','missing-contract')){
  $f=NewV9Fixture
  switch($mutation){
    'downgrade'{$f.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8'}
    'fixture-downgrade'{$f.schema='vc-lora-r19-usb-extended-jtag-fixture-v8';$f.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8'}
    'missing-second'{$f.Remove('grant_diagnostic_second_read_base64')}
    'size'{$f.grant_diagnostic_first_read_base64=[Convert]::ToBase64String([byte[]]::new(1020))}
    'different-read'{$bytes=[Convert]::FromBase64String($f.grant_diagnostic_first_read_base64);$bytes[64]=1;$f.grant_diagnostic_first_read_base64=[Convert]::ToBase64String($bytes)}
    'new-boot'{foreach($sample in @('first','second')){$key='grant_diagnostic_'+$sample+'_read_base64';$bytes=[Convert]::FromBase64String($f[$key]);$bytes[36]=99;$f[$key]=[Convert]::ToBase64String($bytes)}}
    'new-build'{foreach($sample in @('first','second')){$key='grant_diagnostic_'+$sample+'_read_base64';$bytes=[Convert]::FromBase64String($f[$key]);$bytes[20]=99;$f[$key]=[Convert]::ToBase64String($bytes)}}
    'overlap'{$f.grant_diagnostic_address='0x3fcad7fc'}
    'decoder-pin'{$f.grant_diagnostics.decoder.sha256='0'*64}
    'missing-contract'{$f.Remove('grant_diagnostics')}
  }
  $null=RunV9Fixture ('reject-'+$mutation) $f $false
}
Import-Functions 'tools/build_r19_candidate_artifacts.ps1' @('Add-OptionalUsbFailureMetadata','Add-DiagnosticAbiMetadata','Copy-CandidateRolePackage')
& {
  $runtimeFailDiagnosticsEnabled=$true;$timedPathEnabled=$true;$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$true;$grantDiagnosticsEnabled=$true
  $timedPathContract=Get-R19TimedPathCandidateContract $RepoRoot ExplicitHostArm;$auxReadinessContract=Get-R19AuxReadinessCandidateContract $RepoRoot $true
  $diagnosticUsbFailureContract=Get-R19DiagnosticUsbFailureCandidateContract $RepoRoot $true;$grantDiagnosticContract=Get-R19GrantDiagnosticCandidateContract $RepoRoot $true
  $usbRoleCapabilities=Get-R19UsbRoleCapabilities -RepoRoot $RepoRoot -Mode ExplicitHostArm -Enabled $true
  $metadata=[pscustomobject]@{};Add-DiagnosticAbiMetadata $metadata
  Check ($metadata.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v9'-and$metadata.grant_diagnostics.record.size_bytes-eq1024-and$metadata.diagnostic_usb_failure_diagnostics.record.size_bytes-eq256) 'Actual builder emits v9 with all preceding declarations'
  $runRoot=Join-Path $fixtureRoot 'actual-builder-staging';[void][IO.Directory]::CreateDirectory($runRoot)
  foreach($role in $script:R19CandidateRoles){$staged=Copy-CandidateRolePackage $role;Check ((Get-Sha256 (Join-Path $staged 'high_speed/r19_grant_diagnostic_record.hpp'))-ceq(Get-Sha256 (Join-Path $RepoRoot 'firmware/high_speed/r19_grant_diagnostic_record.hpp'))) ('Actual builder exact '+$role.role+' Grant header')}
}
function New-GrantContractElf([string]$Path,[bool]$IncludeGrant,[int]$GrantSize=1024){
  $defs=@(@('vc_lora_r19_runtime_stage_record',68),@('vc_lora_r19_hwcdc_fifo_diagnostic_record',112),@('vc_lora_r19_hwcdc_restart_diagnostic_record',128),@('vc_lora_r19_ground_usb_commit_record',128),@('vc_lora_r19_first_usb_failure_record',384),@('vc_lora_r19_timed_path_record',512),@('vc_lora_r19_aux_readiness_record',6144),@('vc_lora_r19_diagnostic_usb_failure_record',256))
  if($IncludeGrant){$defs+=,@('vc_lora_r19_grant_diagnostic_record',$GrantSize)}
  $strings=[Collections.Generic.List[byte]]::new();$strings.Add(0);$names=@()
  foreach($def in $defs){$names+=$strings.Count;$strings.AddRange([Text.Encoding]::ASCII.GetBytes($def[0]));$strings.Add(0)}
  $tableOffset=212;$tableSize=16*($defs.Count+1);$stringsOffset=$tableOffset+$tableSize
  [byte[]]$bytes=[byte[]]::new($stringsOffset+$strings.Count);([byte[]]@(127,69,76,70,1,1,1)).CopyTo($bytes,0)
  [BitConverter]::GetBytes([uint16]2).CopyTo($bytes,16);[BitConverter]::GetBytes([uint16]94).CopyTo($bytes,18);[BitConverter]::GetBytes([uint32]1).CopyTo($bytes,20)
  [BitConverter]::GetBytes([uint32]52).CopyTo($bytes,32);[BitConverter]::GetBytes([uint16]40).CopyTo($bytes,46);[BitConverter]::GetBytes([uint16]4).CopyTo($bytes,48)
  [uint32]$address=0x3FC80000;$total=0;foreach($def in $defs){$total+=[int]$def[1]}
  [BitConverter]::GetBytes([uint32]8).CopyTo($bytes,96);[BitConverter]::GetBytes([uint32]3).CopyTo($bytes,100);[BitConverter]::GetBytes($address).CopyTo($bytes,104);[BitConverter]::GetBytes([uint32]$total).CopyTo($bytes,112)
  [BitConverter]::GetBytes([uint32]2).CopyTo($bytes,136);[BitConverter]::GetBytes([uint32]$tableOffset).CopyTo($bytes,148);[BitConverter]::GetBytes([uint32]$tableSize).CopyTo($bytes,152);[BitConverter]::GetBytes([uint32]3).CopyTo($bytes,156);[BitConverter]::GetBytes([uint32]16).CopyTo($bytes,168)
  [BitConverter]::GetBytes([uint32]3).CopyTo($bytes,176);[BitConverter]::GetBytes([uint32]$stringsOffset).CopyTo($bytes,188);[BitConverter]::GetBytes([uint32]$strings.Count).CopyTo($bytes,192)
  for($i=0;$i-lt$defs.Count;$i++){$at=$tableOffset+16*($i+1);[BitConverter]::GetBytes([uint32]$names[$i]).CopyTo($bytes,$at);[BitConverter]::GetBytes($address).CopyTo($bytes,$at+4);[BitConverter]::GetBytes([uint32]$defs[$i][1]).CopyTo($bytes,$at+8);$bytes[$at+12]=17;[BitConverter]::GetBytes([uint16]1).CopyTo($bytes,$at+14);$address+=[uint32]$defs[$i][1]}
  $strings.ToArray().CopyTo($bytes,$stringsOffset);[IO.File]::WriteAllBytes($Path,$bytes)
}
$elf8=Join-Path $fixtureRoot 'legacy-eight.elf';$elf9=Join-Path $fixtureRoot 'grant-nine.elf';$badElf=Join-Path $fixtureRoot 'grant-wrong-size.elf'
New-GrantContractElf $elf8 $false;New-GrantContractElf $elf9 $true;New-GrantContractElf $badElf $true 1020
Check (@((Get-R19ElfDiagnosticSymbols $elf8 $true $true $true $true $true).PSObject.Properties).Count-eq8) 'Legacy actual ELF parser remains eight symbols'
Check (@((Get-R19ElfDiagnosticSymbols $elf9 $true $true $true $true $true $true).PSObject.Properties).Count-eq9) 'New actual ELF parser binds nine writable BSS symbols'
Reject {Get-R19ElfDiagnosticSymbols $elf8 $true $true $true $true $true $true} 'v9 rejects ELF missing Grant symbol'
Reject {Get-R19ElfDiagnosticSymbols $elf9 $true $true $true $true $true} 'v8 rejects undeclared ninth ELF symbol'
Reject {Get-R19ElfDiagnosticSymbols $badElf $true $true $true $true $true $true} 'v9 rejects ELF with non1024-byte Grant object'
& {
  $mockFixture=NewV9Fixture
  $mockArtifact=[pscustomobject]@{extended_records_enabled=$true;first_usb_failure_enabled=$true;timed_path_enabled=$true;aux_readiness_enabled=$true;diagnostic_usb_failure_enabled=$true;grant_diagnostics_enabled=$true}
  $names=@('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit','first_usb_failure','timed_path','aux_readiness','diagnostic_usb_failure','grant_diagnostic')
  foreach($name in $names){$mockArtifact|Add-Member NoteProperty ($name+'_address') $mockFixture[$name+'_address']}
  $mockRoot=Join-Path $fixtureRoot 'mock-capture';[void][IO.Directory]::CreateDirectory($mockRoot)
  $ScriptsRoot=$mockRoot;$OpenOcdExecutable=$readerPath;$OpenOcdSha256=Get-Sha256 $readerPath
  $InterfaceConfig=$readerPath;$InterfaceConfigSha256=$OpenOcdSha256;$TargetConfig=$readerPath;$TargetConfigSha256=$OpenOcdSha256
  $ProbeSerial='mock-offline-only';$ProbeUsbLocation='1-1.1';$stageRecordBytes=68;$fifoRecordBytes=112
  function Invoke-NativeProcessCapture {
    param($Executable,$Arguments,$LogPath,$TimeoutMilliseconds)
    Check (@($Arguments|Where-Object{$_-ceq'halt'}).Count-eq1) 'Ninth-record mock capture exactly one SMP halt'
    $command=$Arguments-join"`n";$matches=[regex]::Matches($command,'dump_image \{([^}]+)\} (0x[0-9a-f]{8}) (\d+)')
    Check ($matches.Count-eq18) 'Ninth-record mock capture retains exactly eighteen raw reads'
    Check ($command.LastIndexOf('dump_image')-lt$command.IndexOf('catch { resume }')) 'All eighteen reads precede SMP resume cleanup'
    for($ordinal=0;$ordinal-lt18;$ordinal++){$m=$matches[$ordinal];$name=$names[$ordinal%9];$sample=if($ordinal-lt9){'first'}else{'second'};$bytes=[Convert]::FromBase64String($mockFixture[$name+'_'+$sample+'_read_base64']);Check ([int]$m.Groups[3].Value-eq$bytes.Length-and$m.Groups[2].Value-ceq$mockFixture[$name+'_address']) ('Mock exact size/address '+$name+' '+$sample);[IO.File]::WriteAllBytes($m.Groups[1].Value,$bytes)}
    [IO.File]::WriteAllText($LogPath,(@('VC_LORA_JTAG_OPEN_SERIAL=mock-offline-only','VC_LORA_JTAG_OPEN_LOCATION=1-1.1','VC_LORA_JTAG_IDENTITY_MATCHED','VC_LORA_HALT_CPU0','VC_LORA_HALT_CURSTATE_CPU0=halted','VC_LORA_HALT_CURSTATE_CPU1=halted','VC_LORA_RESUME_CURSTATE_CPU0=running','VC_LORA_RESUME_CURSTATE_CPU1=running','shutdown command invoked')-join"`n"))
    [pscustomobject]@{exit_code=0;timed_out=$false;termination_proven=$true;launch_failure='';stdout_path='';stderr_path=''}
  }
  function Invoke-OpenOcdCleanup {[pscustomobject]@{required=$true;attempted=$true;exit_code=0;process_termination_proven=$true;resume_shutdown_proven=$true}}
  $raw=Read-LiveStageRecord -Artifact $mockArtifact -OutputDirectory $mockRoot -Attempt 1
  Check ($raw.smp_capture_proven-and$raw.cleanup.resume_shutdown_proven-and$raw.grant_diagnostic_first.Length-eq1024-and$raw.grant_diagnostic_second.Length-eq1024) 'Paired ninth record retained without weakening SMP cleanup proof'
}
Import-Functions 'tools/verify_r19_candidate_artifact.ps1' @('Assert-Condition','Assert-ModeContract','Assert-DiagnosticAbiContract')
& {
  $runtimeFailDiagnosticsEnabled=$true;$acceptanceEligible=$false;$timedPathEnabled=$true;$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$true;$grantDiagnosticsEnabled=$true;$TimedPathMode='ExplicitHostArm'
  $timedPathContract=Get-R19TimedPathCandidateContract $RepoRoot ExplicitHostArm;$auxReadinessContract=Get-R19AuxReadinessCandidateContract $RepoRoot $true
  $diagnosticUsbFailureContract=Get-R19DiagnosticUsbFailureCandidateContract $RepoRoot $true;$grantDiagnosticContract=Get-R19GrantDiagnosticCandidateContract $RepoRoot $true
  $usbRoleCapabilities=Get-R19UsbRoleCapabilities -RepoRoot $RepoRoot -Mode ExplicitHostArm -Enabled $true
  $record=[pscustomobject]@{runtime_fail_diagnostics_enabled=$true;acceptance_authorized=$false;acceptance_eligible=$false;deployment_authorized=$false}
  Add-DiagnosticAbiMetadata $record
  Assert-ModeContract $record fixture;Assert-DiagnosticAbiContract $record fixture;Check $true 'Actual verifier accepts exact v9 metadata'
  foreach($mutation in @('top-case','inner-case','string-size','fractional-size','string-schema','extra-field','reader-downgrade','undeclared-grant')){
    $bad=$record|ConvertTo-Json -Depth 30|ConvertFrom-Json
    switch($mutation){
      'top-case'{$value=$bad.grant_diagnostics;$bad.PSObject.Properties.Remove('grant_diagnostics');$bad|Add-Member NoteProperty Grant_Diagnostics $value}
      'inner-case'{$value=$bad.grant_diagnostics.record.size_bytes;$bad.grant_diagnostics.record.PSObject.Properties.Remove('size_bytes');$bad.grant_diagnostics.record|Add-Member NoteProperty Size_Bytes $value}
      'string-size'{$bad.grant_diagnostics.record.size_bytes='1024'}
      'fractional-size'{$bad.grant_diagnostics.record.size_bytes=1024.5}
      'string-schema'{$bad.grant_diagnostics.record.schema_version='1'}
      'extra-field'{$bad.grant_diagnostics|Add-Member NoteProperty extra $true}
      'reader-downgrade'{$bad.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8'}
      'undeclared-grant'{$grantDiagnosticsEnabled=$false}
    }
    Reject {Assert-ModeContract $bad fixture;Assert-DiagnosticAbiContract $bad fixture} ('Actual verifier rejects '+$mutation)
    $grantDiagnosticsEnabled=$true
  }
}
$global:LASTEXITCODE=0
Write-Output "check_r19_grant_artifact_contract PASS checks=$checks hardware_interaction=false"
