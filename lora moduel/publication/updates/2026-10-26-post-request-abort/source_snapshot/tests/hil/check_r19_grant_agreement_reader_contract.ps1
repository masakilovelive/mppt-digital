[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='', [string]$SealedCandidateRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
if(-not$OutputDirectory){$OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('vc_lora_agreement_reader_'+[Guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Test output must be fresh'}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$utf8=[Text.UTF8Encoding]::new($false)
$script:checks=0;$script:cases=[Collections.Generic.List[object]]::new()
function Check([bool]$Value,[string]$Message){$script:checks++;if(-not$Value){throw $Message}}
function Case([string]$Name,[scriptblock]$Action){try{&$Action;$script:cases.Add([ordered]@{name=$Name;result='PASS'})}catch{$script:cases.Add([ordered]@{name=$Name;result='FAIL';error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}}
function Reject([scriptblock]$Action){$rejected=$false;try{&$Action|Out-Null}catch{$rejected=$true};Check $rejected 'Invalid agreement acquisition binding must fail closed'}
function Clone($Value){$Value|ConvertTo-Json -Depth 32 -Compress|ConvertFrom-Json}
$readerPath=Join-Path $RepoRoot 'tools/read_r19_runtime_stage_jtag.ps1'
$gatePath=Join-Path $RepoRoot 'tools/invoke_r19_jtag_preflash_gate.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($readerPath,[ref]$tokens,[ref]$errors)
Check (@($errors).Count-eq0) 'Actual reader parses'
$functions=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]})
$required=@('Assert-ExactProperties','Test-ExactDiagnosticInteger','Assert-R19ReaderGrantAgreementSelection','Assert-R19ReaderGrantAgreementBinding','Assert-R19ReaderGrantAgreementFlashBinding','Assert-R19ReaderGrantAgreementRamFixture')
foreach($name in $required){$matches=@($functions|Where-Object{$_.Name-ceq$name});Check ($matches.Count-eq1) ('Actual reader helper exists: '+$name);. ([scriptblock]::Create($matches[0].Extent.Text))}
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_contract.ps1')
function NewFixture([bool]$Enabled=$true){
  $contract=Get-R19GrantAgreementCandidateContract -RepoRoot $RepoRoot -Enabled $Enabled
  $flag='compiler.cpp.extra_flags=-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1 -DVC_LORA_R19_GRANT_AGREEMENT_DIAGNOSTICS=1'
  $marker=[pscustomobject][ordered]@{name='vc_lora_r19_grant_agreement_capability';address='0x3fcaa000';size_bytes=4;aligned_32_bit=$true}
  $docs=@(foreach($kind in @('manifest','seal','handoff')){
    $d=[pscustomobject]@{kind=$kind;roles=@([pscustomobject]@{role='vehicle';runtime_diagnostic_symbols=[pscustomobject]@{symbols=[pscustomobject]@{}}})}
    if($Enabled){$d|Add-Member NoteProperty grant_agreement_diagnostics (Clone $contract);$d.roles[0].runtime_diagnostic_symbols.symbols|Add-Member NoteProperty grant_agreement_capability (Clone $marker)}
    $d
  })
  $docs[0]|Add-Member NoteProperty candidate_enable ([pscustomobject]@{property=$(if($Enabled){$flag}else{'compiler.cpp.extra_flags=-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1'})})
  $docs[0]|Add-Member NoteProperty canonical_source_snapshot ([pscustomobject]@{files=@(if($Enabled){$contract.source_bindings|ForEach-Object{[pscustomobject]@{path=$_.path;sha256=$_.sha256;size_bytes=(Get-Item -LiteralPath (Join-Path $RepoRoot $_.path)).Length}}})})
  $role=[pscustomobject]@{role='vehicle';compile=[pscustomobject]@{argv=@('--build-property',$docs[0].candidate_enable.property)}}
  [pscustomobject]@{docs=$docs;role=$role;nm=$(if($Enabled){'3fcaa000 00000004 B vc_lora_r19_grant_agreement_capability'}else{''});enabled=$Enabled}
}
function InvokeFixture($f,[bool]$Requested=$true,[bool]$Stop=$true){Assert-R19ReaderGrantAgreementBinding -Documents $f.docs -RoleEntry $f.role -ExpectedRole vehicle -NmText $f.nm -RepoRoot $RepoRoot -Requested $Requested -StopRequested $Stop}
Case 'explicit-v3-binding' {$r=InvokeFixture (NewFixture);Check $r.enabled 'Explicit compiled v3 capability accepted';Check (-not$r.runtime_completion_proven) 'Capability marker is not RAM completion proof'}
Case 'legacy-v2-unchanged' {$r=InvokeFixture (NewFixture $false) $false $true;Check (-not$r.enabled) 'No agreement flag or metadata preserves legacy'}
Case 'legacy-without-compile-container' {$f=NewFixture $false;$f.role.PSObject.Properties.Remove('compile');$r=InvokeFixture $f $false $true;Check (-not$r.enabled) 'Old non-timed diagnostic artifacts need no new compiler container'}
Case 'legacy-artifact-does-not-resolve-opt-in-decoder-root' {
  $actual=@($functions|Where-Object{$_.Name-ceq'Assert-ExtendedArtifactBinding'})[0]
  $start=$actual.Body.Extent.Text.IndexOf('$fatalRequested=')
  $end=$actual.Body.Extent.Text.IndexOf('$timedEnabled=', $start)
  Check ($start-ge0-and$end-gt$start) 'Actual agreement preamble is bounded before legacy metadata checks'
  # Preserve the real parameter defaults (including FatalMatches=@()) and all
  # opt-in initializers. This isolated preamble must not inherit invented
  # enabled values or omit a dependency supplied by the actual function.
  $preamble=[scriptblock]::Create($actual.Body.ParamBlock.Extent.Text+"`n"+$actual.Body.Extent.Text.Substring($start,$end-$start))
  $fixture=NewFixture $false
  & {
    $Documents=$fixture.docs
    $script:R19GrantReservationDecoderPath=$null
    $script:R19FatalDecoderVerifiedText=$null
    . $preamble -RoleEntry $fixture.role -ExpectedRole vehicle -NmText ''
    Check (-not$agreementBinding.enabled) 'Default-off v9 performs undeclared agreement rejection without requiring new decoder path'
    Check (-not$fatalEnabled-and$agreementRepo-ceq'') 'Default-off fatal preamble preserves false selection and never resolves the opt-in root'
    $Documents[0]|Add-Member NoteProperty grant_reservation_fatal_diagnostics $true
    Reject {. $preamble -RoleEntry $fixture.role -ExpectedRole vehicle -NmText ''}
    $Documents[0].PSObject.Properties.Remove('grant_reservation_fatal_diagnostics')
    $fixture.role|Add-Member NoteProperty runtime_diagnostic_symbols ([pscustomobject]@{symbols=[pscustomobject]@{grant_reservation_fatal=[pscustomobject]@{size_bytes=128}}})
    Reject {. $preamble -RoleEntry $fixture.role -ExpectedRole vehicle -NmText ''}
    $fixture.role.PSObject.Properties.Remove('runtime_diagnostic_symbols')
    $Documents[0]|Add-Member NoteProperty grant_agreement_diagnostics $true
    Reject {. $preamble -RoleEntry $fixture.role -ExpectedRole vehicle -NmText ''}
  }
}
Case 'portable-full-exact-compiler-property-boundary' {
  $actual=@($functions|Where-Object{$_.Name-ceq'Assert-ExtendedArtifactBinding'})[0]
  $timedBranch=@($actual.Body.FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Clauses[0].Item1.Extent.Text-ceq'$timedEnabled'-and$n.Extent.Text.Contains('timed path compile flags not mode bound')},$true))
  Check ($timedBranch.Count-eq1) 'Actual timed-path compiler-property validation branch is unique'
  $parts=@($timedBranch[0].Clauses[0].Item2.Statements)
  $start=-1
  for($i=0;$i-lt$parts.Count;$i++){if($parts[$i]-is[Management.Automation.Language.AssignmentStatementAst]-and$parts[$i].Left.Extent.Text-ceq'$expectedFlag'){$start=$i;break}}
  Check ($start-ge0) 'Actual complete expectedFlag construction is present'
  $exactPropertyGate=[scriptblock]::Create(($parts[$start..($parts.Count-1)]|ForEach-Object{$_.Extent.Text})-join"`n")
  & {
    . (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')
    $expectedMode=2
    foreach($mode in @('timed-v6','agreement-v11','fatal-v12')){
      $auxEnabled=$mode-cne'timed-v6';$diagnosticUsbEnabled=$auxEnabled;$grantEnabled=$auxEnabled;$reservationEnabled=$auxEnabled;$stopEnabled=$auxEnabled;$agreementEnabled=$auxEnabled;$fatalEnabled=$mode-ceq'fatal-v12'
      $property=Get-R19CandidateCompileProperty $true ExplicitHostArm $auxEnabled $diagnosticUsbEnabled $grantEnabled $reservationEnabled $stopEnabled $agreementEnabled $fatalEnabled
      $Manifest=[pscustomobject]@{candidate_enable=[pscustomobject]@{property=$property}}
      $RoleEntry=[pscustomobject]@{compile=[pscustomobject]@{argv=@('--build-property',$property)}}
      . $exactPropertyGate
      Check $true ('Actual exact property accepts '+$mode)
    }
    foreach($mutation in @('missing','duplicate','disabled','undeclared','role-mismatch')){
      $bad=$property;$fatalEnabled=$true
      switch($mutation){
        'missing'{$bad=$property.Replace(' -DVC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS=1','')}
        'duplicate'{$bad+=' -DVC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS=1'}
        'disabled'{$bad=$property.Replace('VC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS=1','VC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS=0')}
        'undeclared'{$fatalEnabled=$false}
      }
      $Manifest=[pscustomobject]@{candidate_enable=[pscustomobject]@{property=$bad}}
      $RoleEntry=[pscustomobject]@{compile=[pscustomobject]@{argv=@('--build-property',$(if($mutation-ceq'role-mismatch'){$property+' -DUNKNOWN_OVERRIDE=1'}else{$bad}))}}
      Reject {. $exactPropertyGate}
    }
  }
}
if($SealedCandidateRoot){
  Case 'actual-sealed-fatal-candidate-entire-extended-binding' {
    # All invoked reader helpers below are file/metadata validators. The live
    # main, native nm, OpenOCD, COM and JTAG functions are never imported/called.
    $pure=@('Assert-ExtendedArtifactBinding','Get-Sha256','Assert-ExtendedArtifactReference',
      'Get-VerifiedFirstUsbDecoderText','Get-VerifiedR19StopDecoderText','Get-VerifiedR19FatalDecoderText',
      'Assert-R19GrantFatalSelection','Assert-R19ReaderGrantFatalBinding','Assert-R19GrantDiagnosticContract','Assert-R19ReaderUsbRoleCapabilities')
    foreach($name in $pure){$matches=@($functions|Where-Object{$_.Name-ceq$name});Check ($matches.Count-eq1) ('Actual full-binding pure dependency '+$name);. ([scriptblock]::Create($matches[0].Extent.Text))}
    . (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')
    $root=(Resolve-Path -LiteralPath $SealedCandidateRoot).Path
    $manifest=Get-Content -LiteralPath (Join-Path $root 'candidate_manifest.json') -Raw|ConvertFrom-Json
    $seal=Get-Content -LiteralPath (Join-Path $root 'final_seal.json') -Raw|ConvertFrom-Json
    foreach($spec in @(@('R19FirstFailureDecoderPath','read_r19_first_usb_failure_record.ps1'),@('R19TimedPathDecoderPath','read_r19_timed_path_record.ps1'),@('R19AuxReadinessDecoderPath','read_r19_aux_readiness_record.ps1'),@('R19DiagnosticUsbFailureDecoderPath','read_r19_diagnostic_usb_failure_record.ps1'),@('R19GrantDiagnosticDecoderPath','read_r19_grant_diagnostic_record.ps1'),@('R19GrantReservationDecoderPath','read_r19_grant_reservation_record.ps1'),@('R19GrantReservationStopDecoderPath','read_r19_grant_reservation_stop_record.ps1'),@('R19GrantReservationFatalDecoderPath','read_r19_grant_reservation_fatal_record.ps1'))){Set-Variable -Name $spec[0] -Scope Script -Value (Join-Path $RepoRoot ('tools/'+$spec[1]))}
    function Invoke-ActualSealedBinding([string]$RoleName,[string]$Mutation=''){
      $GrantReservationStopDiagnostics=$true;$GrantAgreementDiagnostics=$true;$GrantReservationFatalDiagnostics=$true
      $m=Clone $manifest;$s=Clone $seal;$r=@($m.roles|Where-Object{$_.role-ceq$RoleName})[0]
      $elf=Join-Path $root ('evidence/build/'+$RoleName+'/application.elf');$map=Join-Path $root ('evidence/build/'+$RoleName+'/application.map')
      $actual=Get-R19DiagnosticSymbolBinding $elf $map $r.application.sha256 $true $true $true $true $true $true $true $true $true
      Check (@($actual.symbols.PSObject.Properties).Count-eq13) ('Actual ELF supplies13 symbols '+$RoleName)
      $lines=@($actual.symbols.PSObject.Properties|ForEach-Object{('{0} {1:x8} B {2}'-f$_.Value.address.Substring(2),[uint32]$_.Value.size_bytes,$_.Value.name)})
      $nm=$lines-join"`n"
      $bindingArguments=@{Manifest=$m;Seal=$s;Root=$root;RoleEntry=$r;ExpectedRole=$RoleName;ElfSha256=$actual.elf_sha256;MapSha256=$actual.map_sha256;NmText=$nm}
      foreach($pair in @(@('StageMatches','runtime_stage'),@('FifoMatches','endpoint_fifo'),@('RestartMatches','hwcdc_restart'),@('CommitMatches','ground_usb_commit'),@('FirstFailureMatches','first_usb_failure'),@('TimedMatches','timed_path'),@('AuxMatches','aux_readiness'),@('DiagnosticUsbMatches','diagnostic_usb_failure'),@('GrantMatches','grant_diagnostic'),@('ReservationMatches','grant_reservation'),@('StopMatches','grant_reservation_stop'),@('FatalMatches','grant_reservation_fatal'))){$name=$actual.symbols.($pair[1]).name;$bindingArguments[$pair[0]]=[regex]::Matches($nm,('(?m)^([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})\s+[Bb]\s+'+[regex]::Escape($name)+'\s*$'))}
      $property=$m.candidate_enable.property
      switch($Mutation){
        'missing'{$m.candidate_enable.property=$property.Replace(' -DVC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS=1','')}
        'duplicate'{$m.candidate_enable.property=$property+' -DVC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS=1'}
        'disabled'{$m.candidate_enable.property=$property.Replace('VC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS=1','VC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS=0')}
        'undeclared'{$GrantReservationFatalDiagnostics=$false}
      }
      if($Mutation-cin@('missing','duplicate','disabled')){$r.compile.argv=@($r.compile.argv|ForEach-Object{if($_-ceq$property){$m.candidate_enable.property}else{$_}})}
      Assert-ExtendedArtifactBinding @bindingArguments
    }
    foreach($roleName in @('vehicle','ground')){
      $binding=Invoke-ActualSealedBinding $roleName
      Check ($binding.enabled-and$binding.grant_reservation_fatal_enabled-and$binding.grant_agreement_enabled-and$binding.metadata.symbols.grant_reservation_fatal.size_bytes-eq128) ('Entire real sealed binding reaches v12 metadata '+$roleName)
      foreach($mutation in @('missing','duplicate','disabled','undeclared')){Reject {Invoke-ActualSealedBinding $roleName $mutation}}
    }
  }
}
Case 'offline-summary-does-not-require-live-artifact' {
  $matches=@($ast.FindAll({param($node)
    $node-is[Management.Automation.Language.IfStatementAst]-and
    $node.Clauses[0].Item1.Extent.Text.Contains('$artifactBinding.PSObject.Properties[''grant_agreement_enabled'']')
  },$true))
  Check ($matches.Count-eq1) 'Actual main summary agreement publication guard is unique'
  $expression=[scriptblock]::Create($matches[0].Clauses[0].Item1.Extent.Text)
  $artifactBinding=$null
  $publish=. $expression
  Check ($publish-is[bool]-and-not$publish) 'Offline v4/v5 summary without a live artifact does not publish agreement proof or throw'
}
Case 'agreement-requires-stop' {Reject {InvokeFixture (NewFixture) $true $false}}
Case 'ram-only-fixture-cannot-prove-compiled-agreement' {Reject {Assert-R19ReaderGrantAgreementRamFixture -Fixture ([pscustomobject]@{}) -Requested $true}}
Case 'ram-only-fixture-rejects-undeclared-agreement' {Reject {Assert-R19ReaderGrantAgreementRamFixture -Fixture ([pscustomobject]@{grant_agreement_diagnostics=$true}) -Requested $false}}
Case 'undeclared-v3' {Reject {InvokeFixture (NewFixture) $false $true}}
Case 'missing-v3' {Reject {InvokeFixture (NewFixture $false) $true $true}}
foreach($mutation in @('missing-seal','missing-handoff','case-metadata','extra-contract-field','wrong-contract-wire','missing-marker','duplicate-marker','marker-data','marker-nosize','marker-size','marker-address','marker-metadata-size','marker-metadata-case','missing-role','duplicate-role','wrong-role-entry','missing-compile','missing-compile-container','duplicate-compile','overridden-compile','legacy-compile','source-missing','source-digest')){
  Case ('reject-'+$mutation) {
    $f=NewFixture
    switch($mutation){
      'missing-seal' {$f.docs[1].PSObject.Properties.Remove('grant_agreement_diagnostics')}
      'missing-handoff' {$f.docs[2].PSObject.Properties.Remove('grant_agreement_diagnostics')}
      'case-metadata' {$c=$f.docs[0].grant_agreement_diagnostics;$f.docs[0].PSObject.Properties.Remove('grant_agreement_diagnostics');$f.docs[0]|Add-Member NoteProperty Grant_Agreement_Diagnostics $c}
      'extra-contract-field' {$f.docs[1].grant_agreement_diagnostics|Add-Member NoteProperty unexpected $true}
      'wrong-contract-wire' {$f.docs[0].grant_agreement_diagnostics.wire_version=2}
      'missing-marker' {$f.nm=''}
      'duplicate-marker' {$f.nm+="`n"+$f.nm}
      'marker-data' {$f.nm=$f.nm.Replace(' B ',' D ')}
      'marker-nosize' {$f.nm='3fcaa000 B vc_lora_r19_grant_agreement_capability'}
      'marker-size' {$f.nm=$f.nm.Replace('00000004','00000008')}
      'marker-address' {$f.nm=$f.nm.Replace('3fcaa000','3fcaa001')}
      'marker-metadata-size' {$f.docs[1].roles[0].runtime_diagnostic_symbols.symbols.grant_agreement_capability.size_bytes=8}
      'marker-metadata-case' {$m=$f.docs[1].roles[0].runtime_diagnostic_symbols.symbols.grant_agreement_capability;$f.docs[1].roles[0].runtime_diagnostic_symbols.symbols.PSObject.Properties.Remove('grant_agreement_capability');$f.docs[1].roles[0].runtime_diagnostic_symbols.symbols|Add-Member NoteProperty Grant_Agreement_Capability $m}
      'missing-role' {$f.docs[1].roles=@()}
      'duplicate-role' {$f.docs[1].roles+=@($f.docs[1].roles[0])}
      'wrong-role-entry' {$f.role.role='ground'}
      'missing-compile' {$f.role.compile.argv=@()}
      'missing-compile-container' {$f.role.PSObject.Properties.Remove('compile')}
      'duplicate-compile' {$f.role.compile.argv+=@($f.docs[0].candidate_enable.property)}
      'overridden-compile' {$f.role.compile.argv[1]+=' -DVC_LORA_R19_GRANT_AGREEMENT_DIAGNOSTICS=0'}
      'legacy-compile' {$f.docs[0].candidate_enable.property=$f.docs[0].candidate_enable.property.Replace(' -DVC_LORA_R19_GRANT_AGREEMENT_DIAGNOSTICS=1','');$f.role.compile.argv[1]=$f.docs[0].candidate_enable.property}
      'source-missing' {$f.docs[0].canonical_source_snapshot.files=@($f.docs[0].canonical_source_snapshot.files|Select-Object -Skip 1)}
      'source-digest' {$f.docs[0].canonical_source_snapshot.files[0].sha256='0'*64}
    }
    Reject {InvokeFixture $f}
  }
}
foreach($mutation in @('marker','compile','metadata')){Case ('legacy-reject-hidden-'+$mutation){$f=NewFixture $false;switch($mutation){'marker'{$f.nm='3fcaa000 00000004 B vc_lora_r19_grant_agreement_capability'} 'compile'{$f.role.compile.argv[1]+=' -DVC_LORA_R19_GRANT_AGREEMENT_DIAGNOSTICS=1'} 'metadata'{$f.docs[2]|Add-Member NoteProperty grant_agreement_diagnostics (Get-R19GrantAgreementCandidateContract -RepoRoot $RepoRoot -Enabled $true)}};Reject {InvokeFixture $f $false $true}}}
Case 'flash-exact-projection' {$f=NewFixture;$artifact=[pscustomobject]@{grant_agreement_enabled=$true;grant_agreement_diagnostics=$f.docs[0].grant_agreement_diagnostics};$b=[pscustomobject]@{grant_agreement_diagnostics=(Clone $artifact.grant_agreement_diagnostics)};Assert-R19ReaderGrantAgreementFlashBinding -Binding $b -Artifact $artifact -Requested $true;Check $true 'Flash agreement metadata matches'}
foreach($mutation in @('missing','case','wrong','undeclared','selection')){Case ('flash-reject-'+$mutation){$f=NewFixture;$artifact=[pscustomobject]@{grant_agreement_enabled=$true;grant_agreement_diagnostics=$f.docs[0].grant_agreement_diagnostics};$b=[pscustomobject]@{grant_agreement_diagnostics=(Clone $artifact.grant_agreement_diagnostics)};$requested=$true;switch($mutation){'missing'{$b.PSObject.Properties.Remove('grant_agreement_diagnostics')} 'case'{$c=$b.grant_agreement_diagnostics;$b.PSObject.Properties.Remove('grant_agreement_diagnostics');$b|Add-Member NoteProperty Grant_Agreement_Diagnostics $c} 'wrong'{$b.grant_agreement_diagnostics.wire_version=2} 'undeclared'{$artifact.grant_agreement_enabled=$false;$requested=$false} 'selection'{$requested=$false}};Reject {Assert-R19ReaderGrantAgreementFlashBinding -Binding $b -Artifact $artifact -Requested $requested}}}
Case 'entry-flags-and-call-order' {
  Check (@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantAgreementDiagnostics'}).Count-eq1) 'Reader explicit agreement flag'
  $source=[IO.File]::ReadAllText($readerPath)
  Check ($source.IndexOf('Assert-R19ReaderGrantAgreementSelection -Requested')-lt$source.IndexOf('$PinnedOpenOcdSha256')) 'Agreement/STOP selection rejected before live tool setup'
  Check ($source.Contains('if($agreementEnabled){$expectedFlag+=')) 'Exact full compile mode also includes agreement flag'
  Check ($source.Contains('grant_agreement_capability')) 'Marker included in sealed symbol set without additional RAM read'
  Check ($source.Contains("if(@(`$summary.reads).Count-ne22)")) 'STOP remains exactly22 paired reads'
  Check ($source.Contains('curstate')-and$source.Contains('running')) 'Explicit CPU running cleanup proof retained'
  $gate=[IO.File]::ReadAllText($gatePath)
  Check ($gate.Contains('[switch]$GrantAgreementDiagnostics')) 'Gate explicit agreement flag'
  Check ($gate.Contains("Grant agreement preflight requires explicit STOP diagnostics")) 'Gate rejects agreement without STOP'
  Check ($gate.Contains("if(`$GrantAgreementDiagnostics){`$arguments+=@('-GrantAgreementDiagnostics','-GrantReservationStopDiagnostics')}")) 'Reader preflight propagates agreement and STOP without changing role authority'
}
Case 'legacy-gate-ast-closure-keeps-agreement-disabled' {
  $gateText=[IO.File]::ReadAllText($gatePath)
  $tokens=$null;$errors=$null;$gateAst=[Management.Automation.Language.Parser]::ParseFile($gatePath,[ref]$tokens,[ref]$errors)
  Check (@($errors).Count-eq0) 'Actual gate parses for legacy closure'
  $summaryNode=@($gateAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left.Extent.Text-ceq'$summary'})
  Check ($summaryNode.Count-eq1) 'Gate actual evidence projection is unique'
  $guardStart=$gateText.IndexOf('if($GrantReservationDiagnostics');$guardEnd=$gateText.IndexOf('$utf8',$guardStart)
  $guard=[scriptblock]::Create($gateText.Substring($guardStart,$guardEnd-$guardStart))
  $projection=[scriptblock]::Create($summaryNode[0].Extent.Text)
  & {
    $GrantDiagnostics=[Management.Automation.SwitchParameter]::new($true);$GrantReservationDiagnostics=[Management.Automation.SwitchParameter]::new($true);$GrantReservationStopDiagnostics=[Management.Automation.SwitchParameter]::new($true)
    # No GrantAgreementDiagnostics local exists: a legacy AST closure is not a
    # new capability grant and must neither throw nor inherit admission.
    . $guard
    $schema='offline';$testId='offline';$startedUtc='offline';$driverBindingPassed=$true;$terminalStatus='PASS_WINUSB_DRIVER_BINDING_PNP_ONLY';$failure='';$hardwareInteraction=$false;$toolchainEvidence=$null;$roles=@();$steps=@();$OfflineContractTest=[Management.Automation.SwitchParameter]::new($true)
    . $projection
    Check ($summary.grant_agreement_diagnostics_enabled-is[bool]-and-not$summary.grant_agreement_diagnostics_enabled) 'Absent new flag produces exact false without new caller variable'
  }
  Reject {& {
    $GrantDiagnostics=[Management.Automation.SwitchParameter]::new($true);$GrantReservationDiagnostics=[Management.Automation.SwitchParameter]::new($true);$GrantReservationStopDiagnostics=[Management.Automation.SwitchParameter]::new($false);$GrantAgreementDiagnostics=[Management.Automation.SwitchParameter]::new($true)
    . $guard
  }}
}
$failed=@($script:cases|Where-Object{$_.result-ceq'FAIL'}).Count
$summary=[ordered]@{schema='vc-lora-r19-grant-agreement-reader-contract-test-v1';result=$(if($failed){'FAIL'}else{'PASS'});checks=$script:checks;cases=$script:cases.ToArray();failed_cases=$failed;shell=$PSVersionTable.PSVersion.ToString();hardware_interaction=$false;production_main_executed=$false;actual_sealed_candidate_root=$SealedCandidateRoot;actual_sealed_candidate_requested=[bool]$SealedCandidateRoot;native_nm_or_openocd_invoked=$false;reader_source_sha256=(Get-FileHash -LiteralPath $readerPath -Algorithm SHA256).Hash;gate_source_sha256=(Get-FileHash -LiteralPath $gatePath -Algorithm SHA256).Hash}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'summary.json'),($summary|ConvertTo-Json -Depth 12),$utf8)
Write-Output ('AGREEMENT_READER '+$summary.result+' checks='+$script:checks+' failures='+$failed)
if($failed){exit 1}
