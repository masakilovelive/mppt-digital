[CmdletBinding()]
param([string]$RepoRoot='',[string]$BuilderFixturePath='')
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Check $failed $Message}
. (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')
Check ((Get-R19CandidateOutputLeaf $true 'ExplicitHostArm' $true) -ceq 'R19-AUX-READINESS-EXPLICIT-HOST-ARM-DIAGNOSTIC-CANDIDATE-BUILD-001') 'AUX diagnostics require isolated explicit opt-in output'
Reject {Get-R19CandidateOutputLeaf $false 'ExplicitHostArm' $true} 'AUX diagnostics without runtime fail must reject'
Reject {Get-R19CandidateOutputLeaf $true 'Disabled' $true} 'AUX diagnostics without timed mode must reject'
Reject {Get-R19CandidateOutputLeaf $true 'SyncOnly' $true} 'AUX diagnostics require ExplicitHostArm'
$flashToolText=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/invoke_r19_candidate_app_flash_hil.ps1') -Raw
Check ($flashToolText.Contains('[switch]$AuxReadinessDiagnostics')) 'Flash orchestrator requires an explicit new AUX diagnostic switch'
$flashAst=[Management.Automation.Language.Parser]::ParseInput($flashToolText,[ref]$null,[ref]$null)
$pinBranches=@($flashAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.IfStatementAst]-and$_.Extent.Text.Contains("expectedCandidateVerifierSha256=")})
Check ($pinBranches.Count-eq1) 'Exactly one mode-bound fixed verifier/common pin branch'
foreach($enabled in @($false,$true)){
  & {
    $auxReadinessEnabled=$enabled
    . ([scriptblock]::Create($pinBranches[0].Extent.Text))
    if($enabled){
      Check ($expectedCandidateVerifierSha256-ceq(Get-FileHash -LiteralPath (Join-Path $RepoRoot 'tools/verify_r19_candidate_artifact.ps1')).Hash-and$expectedCandidateCommonSha256-ceq(Get-FileHash -LiteralPath (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')).Hash) 'New AUX mode pins exact current verifier/common bytes'
    }else{
      Check ($expectedCandidateVerifierSha256-ceq'66DFCFC5B7E59D4B51B704F098ED5A1912312188A2785E1ED2DD59A3B55DE2F2'-and$expectedCandidateCommonSha256-ceq'DCE02A5C0202C9B7A206F78872D8C3954C7112954CE61F455415AD2F46FACFED') 'Legacy verifier/common pins remain immutable and do not authorize new mode'
    }
  }
}
$contract=Get-R19AuxReadinessCandidateContract $RepoRoot $true
Check ($contract.record.size_bytes-eq6144-and$contract.record.schema_version-eq1-and$contract.record.symbol-ceq'vc_lora_r19_aux_readiness_record') 'AUX exact aggregate ABI binding'
Check ($contract.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v7'-and$contract.decoder.path-ceq'tools/read_r19_aux_readiness_record.ps1'-and$contract.decoder.sha256-cmatch'^[A-F0-9]{64}$') 'AUX decoder fingerprint and reader v7 required'
Check ((Get-R19CandidateCompileProperty $true ExplicitHostArm $true).EndsWith(' -DVC_LORA_R19_AUX_READINESS_DIAGNOSTICS=1')) 'AUX macro is explicit diagnostic opt-in'
Check ($null-eq(Get-R19AuxReadinessCandidateContract $RepoRoot $false)) 'No AUX declaration in legacy mode'
Check ((Get-R19CandidateOutputLeaf $true ExplicitHostArm)-ceq'R19-TIMED-PATH-EXPLICIT-HOST-ARM-DIAGNOSTIC-CANDIDATE-BUILD-001') 'Legacy timed output retained'
$sourceFiles=@(Get-R19CandidateSourceFiles $RepoRoot ExplicitHostArm $true|ForEach-Object{$_.FullName.Replace('\','/')})
Check (@($sourceFiles|Where-Object{$_.EndsWith('/firmware/high_speed/r19_aux_readiness_record.hpp')}).Count-eq1) 'Declared AUX header source bound exactly once'
Check (@($sourceFiles|Where-Object{$_.EndsWith('/tools/read_r19_aux_readiness_record.ps1')}).Count-eq1) 'Declared AUX decoder source bound exactly once'
$oldSource=@(Get-R19CandidateSourceFiles $RepoRoot ExplicitHostArm|ForEach-Object{$_.FullName.Replace('\','/')})
Check (@($oldSource|Where-Object{$_.EndsWith('/r19_aux_readiness_record.hpp')-or$_.EndsWith('/read_r19_aux_readiness_record.ps1')}).Count-eq0) 'Legacy candidates do not silently acquire new AUX source'
$repo=$RepoRoot
$tokens=$null;$errors=$null
$readerPath=Join-Path $RepoRoot 'tools/read_r19_runtime_stage_jtag.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($readerPath,[ref]$tokens,[ref]$errors)
Check ($errors.Count-eq0) 'JTAG reader parses'
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
foreach($section in @('aux_observation','aux_edges','usb_readiness')){Check (Test-TransientSnapshotError ('AUX/READY record rejected: '+$section+' active writer, odd or uncommitted sequence')) 'A halted in-flight section retries only through existing bounded resume path'}
Check (Test-TransientSnapshotError 'AUX/READY record rejected: two reads differ at byte 6143') 'AUX unequal snapshot pair is bounded retryable'
Check (-not(Test-TransientSnapshotError 'AUX/READY record rejected: two reads differ at byte 6144')) 'Out-of-ABI transient message cannot become a retry'
Check (-not(Test-TransientSnapshotError 'AUX/READY record rejected: aux_edges unknown magic/schema')) 'Malformed AUX ABI is terminal, not a transient retry'
$fixtures=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'tests/arduino_compile/check_r19_usb_extended_live_reader_contract.ps1'),[ref]$tokens,[ref]$errors)
foreach($f in $fixtures.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-in@('New-Candidate','New-FirstFailureCandidate','Save-Candidate','Json-Write')},$true)){. ([scriptblock]::Create($f.Extent.Text))}
$OutputRoot=Join-Path $RepoRoot ('runs/validation/R19-AUX-READINESS-ARTIFACT-TEST-001/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$script:R19FirstFailureDecoderPath=Join-Path $RepoRoot 'tools/read_r19_first_usb_failure_record.ps1'
$script:R19TimedPathDecoderPath=Join-Path $RepoRoot 'tools/read_r19_timed_path_record.ps1'
$script:R19AuxReadinessDecoderPath=Join-Path $RepoRoot 'tools/read_r19_aux_readiness_record.ps1'
$NmExecutable=Join-Path $OutputRoot 'mock-nm.ps1'
[IO.File]::WriteAllText($NmExecutable,'param($a,$b,$c);Get-Content (Join-Path $PSScriptRoot ''nm.txt'');$global:LASTEXITCODE=0')
$NmSha256=Get-Sha256 $NmExecutable
$nmBase=@('3fcab000 00000044 B vc_lora_r19_runtime_stage_record','3fcab100 00000070 B vc_lora_r19_hwcdc_fifo_diagnostic_record','3fcab200 00000080 B vc_lora_r19_hwcdc_restart_diagnostic_record','3fcab300 00000080 B vc_lora_r19_ground_usb_commit_record','3fcab400 00000180 B vc_lora_r19_first_usb_failure_record','3fcab600 00000200 B vc_lora_r19_timed_path_record')-join"`n"
$nmAux='3fcac000 00001800 B vc_lora_r19_aux_readiness_record'
[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmBase+"`n"+$nmAux)
function New-AuxCandidate([string]$Name){
  $c=New-FirstFailureCandidate $Name
  $timed=Get-R19TimedPathCandidateContract $RepoRoot ExplicitHostArm
  $aux=Get-R19AuxReadinessCandidateContract $RepoRoot $true
  foreach($doc in @($c.manifest,$c.seal,$c.handoff)){
    $doc.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v7'
    $doc.timed_path_diagnostics=$timed;$doc.aux_readiness_diagnostics=$aux
    $doc.roles[0].runtime_diagnostic_symbols.symbols.timed_path=[ordered]@{name='vc_lora_r19_timed_path_record';address='0x3fcab600';size_bytes=512;aligned_32_bit=$true}
    $doc.roles[0].runtime_diagnostic_symbols.symbols.aux_readiness=[ordered]@{name='vc_lora_r19_aux_readiness_record';address='0x3fcac000';size_bytes=6144;aligned_32_bit=$true}
  }
  $property=Get-R19CandidateCompileProperty $true ExplicitHostArm $true
  $c.manifest.candidate_enable=[ordered]@{property=$property};$c.manifest.roles[0].compile=[ordered]@{argv=@($property)}
  foreach($pin in @($timed,$aux)){
    $canonical=Join-Path $RepoRoot $pin.decoder.path
    $c.manifest.canonical_source_snapshot.files+=@([ordered]@{path=$pin.decoder.path;sha256=$pin.decoder.sha256;size_bytes=(Get-Item $canonical).Length})
    Copy-Item -LiteralPath $canonical -Destination (Join-Path $c.root ('evidence/tools/'+[IO.Path]::GetFileName($canonical)))
  }
  Save-Candidate $c
  return $c
}
function Bind-Aux($C){Assert-ArtifactBinding -Root $C.root -ExpectedArtifactId mock-candidate -ExpectedRole ground -ExpectedAddress ([uint32]0x3fcab000)}
$c=New-AuxCandidate 'positive';$bound=Bind-Aux $c
Check ($bound.aux_readiness_enabled-and$bound.aux_readiness_address-ceq'0x3fcac000'-and$bound.symbols.Count-eq7) 'Seventh symbol binds exact aggregate to sealed identity'
Check ($script:R19AuxDecoderVerifiedSha256-ceq$contract.decoder.sha256-and-not[string]::IsNullOrWhiteSpace($script:R19AuxDecoderVerifiedText)) 'Decoder verified once into memory against source/sealed SHA'
foreach($mutation in @('missing-contract','wrong-size','wrong-schema','wrong-reader','wrong-property-case','bad-decoder','missing-sealed-decoder','missing-source','wrong-flag','undeclared-symbol','wrong-storage','wrong-nm-size','overlap','no-timed')){
  [IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmBase+"`n"+$nmAux)
  $c=New-AuxCandidate $mutation
  switch($mutation){
    'missing-contract'{$c.seal.Remove('aux_readiness_diagnostics')}
    'wrong-size'{$c.manifest.aux_readiness_diagnostics.record.size_bytes=6140}
    'wrong-schema'{$c.manifest.aux_readiness_diagnostics.schema='unexpected'}
    'wrong-reader'{$c.seal.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v5'}
    'wrong-property-case'{$value=$c.manifest.aux_readiness_diagnostics;$c.manifest.Remove('aux_readiness_diagnostics');$c.manifest.Aux_Readiness_Diagnostics=$value}
    'bad-decoder'{$c.manifest.aux_readiness_diagnostics.decoder.sha256='0'*64}
    'missing-sealed-decoder'{Remove-Item -LiteralPath (Join-Path $c.root 'evidence/tools/read_r19_aux_readiness_record.ps1')}
    'missing-source'{$c.manifest.canonical_source_snapshot.files=@($c.manifest.canonical_source_snapshot.files|Where-Object{$_.path-cne'tools/read_r19_aux_readiness_record.ps1'})}
    'wrong-flag'{$c.manifest.roles[0].compile.argv=@((Get-R19CandidateCompileProperty $true ExplicitHostArm))}
    'undeclared-symbol'{foreach($doc in @($c.manifest,$c.seal,$c.handoff)){$doc.Remove('aux_readiness_diagnostics')}}
    'wrong-storage'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmBase+"`n"+$nmAux.Replace(' B ',' D '))}
    'wrong-nm-size'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmBase+"`n"+$nmAux.Replace('00001800','000017fc'))}
    'overlap'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmBase+"`n"+$nmAux.Replace('3fcac000','3fcab600'))}
    'no-timed'{foreach($doc in @($c.manifest,$c.seal,$c.handoff)){$doc.Remove('timed_path_diagnostics')}}
  }
  Save-Candidate $c;Reject {Bind-Aux $c} "AUX artifact mutation admitted: $mutation"
}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmBase+"`n"+$nmAux)
$c=New-AuxCandidate 'mock-capture';$bound=Bind-Aux $c
& {
  $stageRecordBytes=68;$fifoRecordBytes=112;$ScriptsRoot=$OutputRoot;$OpenOcdExecutable=$readerPath;$OpenOcdSha256=Get-Sha256 $readerPath
  $InterfaceConfig=$readerPath;$InterfaceConfigSha256=$OpenOcdSha256;$TargetConfig=$readerPath;$TargetConfigSha256=$OpenOcdSha256
  $ProbeSerial='1c:db:d4:5a:83:80';$ProbeUsbLocation='1-4.4'
  function Invoke-NativeProcessCapture{
    param($Executable,$Arguments,$LogPath,$TimeoutMilliseconds)
    $cmd=$Arguments-join"`n";$dump=[regex]::Matches($cmd,'dump_image \{([^}]+)\} (0x[0-9a-f]{8}) (\d+)')
    Check ($dump.Count-eq14-and@($Arguments|Where-Object{$_-ceq'halt'}).Count-eq1-and$cmd.LastIndexOf('dump_image')-lt$cmd.IndexOf('catch { resume }')) 'Fourteen records require one SMP halt and precede resume'
    Check (@($dump|Where-Object{$_.Groups[2].Value-ceq'0x3fcac000'-and$_.Groups[3].Value-ceq'6144'}).Count-eq2) 'Both AUX reads bind exact address and 6144 bytes'
    Check ($cmd.Contains('VC_LORA_RESUME_CURSTATE_CPU0=[esp32s3.cpu0 curstate]')-and$cmd.Contains('VC_LORA_RESUME_CURSTATE_CPU1=[esp32s3.cpu1 curstate]')) 'Both CPU cleanup proof markers retained'
    foreach($d in $dump){[IO.File]::WriteAllBytes($d.Groups[1].Value,(New-Object byte[] ([int]$d.Groups[3].Value)))}
    [IO.File]::WriteAllText($LogPath,(@('VC_LORA_JTAG_OPEN_SERIAL=1c:db:d4:5a:83:80','VC_LORA_JTAG_OPEN_LOCATION=1-4.4','VC_LORA_JTAG_IDENTITY_MATCHED','VC_LORA_HALT_CPU0','VC_LORA_HALT_CURSTATE_CPU0=halted','VC_LORA_HALT_CPU1','VC_LORA_HALT_CURSTATE_CPU1=halted','VC_LORA_RESUME_CURSTATE_CPU0=running','VC_LORA_RESUME_CURSTATE_CPU1=running','shutdown command invoked')-join"`n"))
    [pscustomobject]@{exit_code=0;timed_out=$false;termination_proven=$true;launch_failure='';stdout_path='';stderr_path=''}
  }
  function Invoke-OpenOcdCleanup{[pscustomobject]@{required=$true;attempted=$true;exit_code=0;timed_out=$false;process_termination_proven=$true;resume_shutdown_proven=$true}}
  $capture=Read-LiveStageRecord -Artifact $bound -OutputDirectory $OutputRoot -Attempt 1
  Check ($capture.aux_readiness_first.Length-eq6144-and$capture.aux_readiness_second.Length-eq6144) 'Both AUX raw samples retained'
  Check ($capture.smp_capture_proven-and$capture.cleanup.resume_shutdown_proven) 'Record extension does not bypass cleanup proof'
}
$builderPath=if($BuilderFixturePath){$BuilderFixturePath}else{Join-Path $RepoRoot 'tools/build_r19_candidate_artifacts.ps1'}
$builder=Get-Content -LiteralPath $builderPath -Raw
$verifier=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/verify_r19_candidate_artifact.ps1') -Raw
$builderAst=[Management.Automation.Language.Parser]::ParseInput($builder,[ref]$null,[ref]$null)
$headerTables=@($builderAst.FindAll({param($n)$n-is[Management.Automation.Language.HashtableAst]-and@($n.KeyValuePairs|Where-Object{$_.Item1.Extent.Text-ceq'header_count'}).Count-eq1},$true))
Check ($headerTables.Count-eq1) 'Exactly one canonical candidate header-count expression'
$headerCountExpression=($headerTables[0].KeyValuePairs|Where-Object{$_.Item1.Extent.Text-ceq'header_count'}).Item2.Extent.Text
& {$timedPathEnabled=$true;$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$false;$count=&([scriptblock]::Create($headerCountExpression));Check ($count-eq$script:R19CandidateHeaderNames.Count+2) 'Manifest header_count includes timed and AUX headers exactly'}
foreach($text in @($builder,$verifier)){
  Check ($text.Contains('[switch]$AuxReadinessDiagnostics')-and$text.Contains('aux_readiness_diagnostics')-and$text.Contains('-DVC_LORA_R19_AUX_READINESS_DIAGNOSTICS=1')) 'Builder/verifier require explicit macro and mode binding'
}
Check ($builder.Contains('$auxReadinessEnabled')-and$builder.Contains('r19_aux_readiness_record.hpp')-and$builder.Contains('read_r19_aux_readiness_record.ps1')) 'Staging and decoder evidence integrated'
foreach($definition in $builderAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-in@('Copy-CandidateRolePackage','Add-OptionalUsbFailureMetadata','Add-DiagnosticAbiMetadata')},$true)){. ([scriptblock]::Create($definition.Extent.Text))}
& {
  $runtimeFailDiagnosticsEnabled=$true;$timedPathEnabled=$true;$auxReadinessEnabled=$true
  $diagnosticUsbFailureEnabled=$false;$diagnosticUsbFailureContract=$null;$usbRoleCapabilities=$null
  $timedPathContract=Get-R19TimedPathCandidateContract $RepoRoot ExplicitHostArm
  $auxReadinessContract=Get-R19AuxReadinessCandidateContract $RepoRoot $true
  $runRoot=Join-Path $OutputRoot 'actual-staging';New-Item -ItemType Directory -Path $runRoot|Out-Null
  $metadata=[pscustomobject]@{};Add-DiagnosticAbiMetadata $metadata
  Check ($metadata.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v7'-and$metadata.aux_readiness_diagnostics.record.size_bytes-eq6144) 'Actual builder ABI metadata emits new v7 declaration'
  Check ($metadata.first_usb_failure_decoder.sha256-ceq(Get-R19FirstFailureDecoderBinding $RepoRoot).sha256-and$metadata.timed_path_diagnostics.mode-ceq'ExplicitHostArm') 'Actual builder retains the preceding five/six-record contracts'
  Check ($null-eq$metadata.PSObject.Properties['diagnostic_usb_failure_diagnostics']-and$null-eq$metadata.PSObject.Properties['usb_role_capabilities']) 'False diagnostic opt-in keeps legacy v7 metadata free of v8 feature declarations'
  foreach($role in $script:R19CandidateRoles){
    $staged=Copy-CandidateRolePackage $role
    foreach($relative in @('high_speed/r19_aux_readiness_record.hpp','high_speed/r19_timed_path_record.hpp','diagnostics/r19_host_readiness.hpp')){
      $source=Join-Path $RepoRoot ('firmware/'+$relative)
      Check ((Get-R19Sha256 (Join-Path $staged $relative))-ceq(Get-R19Sha256 $source)) ('Actual '+$role.role+' staging must retain exact '+$relative)
    }
  }
}
& {
  $runtimeFailDiagnosticsEnabled=$true;$timedPathEnabled=$true;$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$true
  $timedPathContract=Get-R19TimedPathCandidateContract $RepoRoot ExplicitHostArm
  $auxReadinessContract=Get-R19AuxReadinessCandidateContract $RepoRoot $true
  $diagnosticUsbFailureContract=Get-R19DiagnosticUsbFailureCandidateContract $RepoRoot $true
  $usbRoleCapabilities=Get-R19UsbRoleCapabilities -RepoRoot $RepoRoot -Mode ExplicitHostArm -Enabled $true
  $count=&([scriptblock]::Create($headerCountExpression))
  Check ($count-eq$script:R19CandidateHeaderNames.Count+3) 'Explicit v8 feature includes exactly one additional diagnostic USB failure header'
  $metadata=[pscustomobject]@{};Add-DiagnosticAbiMetadata $metadata
  Check ($metadata.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v8'-and$metadata.diagnostic_usb_failure_diagnostics.record.size_bytes-eq256) 'Actual builder emits v8 and the exact 256-byte optional record only for explicit feature opt-in'
  Check (($metadata.usb_role_capabilities|ConvertTo-Json -Depth 30 -Compress)-ceq($usbRoleCapabilities|ConvertTo-Json -Depth 30 -Compress)) 'Actual builder preserves the source-bound per-role capability contract'
  Check ($metadata.aux_readiness_diagnostics.record.size_bytes-eq6144-and$metadata.first_usb_failure_decoder.sha256-ceq(Get-R19FirstFailureDecoderBinding $RepoRoot).sha256-and$metadata.timed_path_diagnostics.mode-ceq'ExplicitHostArm') 'Actual v8 builder retains the preceding first-failure, timed-path and AUX declarations'
  $runRoot=Join-Path $OutputRoot 'actual-staging-v8';New-Item -ItemType Directory -Path $runRoot|Out-Null
  foreach($role in $script:R19CandidateRoles){
    $staged=Copy-CandidateRolePackage $role
    $relative='high_speed/r19_diagnostic_usb_failure_record.hpp'
    Check ((Get-R19Sha256 (Join-Path $staged $relative))-ceq(Get-R19Sha256 (Join-Path $RepoRoot ('firmware/'+$relative)))) ('Actual '+$role.role+' v8 staging binds the exact diagnostic USB failure header')
  }
}
Check ($ast.Extent.Text.Contains('ConvertFrom-R19AuxReadinessRecord -First $auxReadinessFirstBytes -Second $auxReadinessSecondBytes -ExpectedRole $expectedRole -ExpectedFingerprint $legacy.build_fingerprint -ExpectedBoot $legacy.boot_instance')) 'Decoded aggregate binds preceding independent build and boot identity'
Check ($ast.Extent.Text.Contains("record='aux_readiness';sample=")) 'v7 summary retains both aggregate raw read records'
Write-Output "check_r19_aux_readiness_artifact PASS checks=$checks hardware_interaction=false"
