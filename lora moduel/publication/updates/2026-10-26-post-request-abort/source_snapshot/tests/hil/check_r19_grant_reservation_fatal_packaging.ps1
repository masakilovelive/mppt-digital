[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputRoot='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not$OutputRoot){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-fatal-packaging-'+[Guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($OutputRoot)
. (Join-Path $repo 'tools/r19_candidate_artifact_common.ps1')
$script:checks=0;$script:failures=0
function Check([bool]$Value,[string]$Name){$script:checks++;if(-not$Value){$script:failures++;Write-Output ('FAIL '+$Name)}}
function Reject([scriptblock]$Action,[string]$Name){$rejected=$false;try{&$Action|Out-Null}catch{$rejected=$true};Check $rejected $Name}
function Parse([string]$Relative){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $Relative),[ref]$tokens,[ref]$errors);Check (@($errors).Count-eq0) ('Parses '+$Relative);return $ast}
function ImportFunctions([string]$Relative,[string[]]$Names){
  $ast=Parse $Relative
  foreach($name in $Names){$nodes=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq$name});Check ($nodes.Count-eq1) ('Unique production function '+$name);if($nodes.Count-eq1){. ([scriptblock]::Create($nodes[0].Extent.Text));Set-Item -Path ('Function:script:'+$name) -Value (Get-Item ('Function:'+$name)).ScriptBlock}}
}
foreach($relative in @('tools/build_r19_candidate_artifacts.ps1','tools/verify_r19_candidate_artifact.ps1')){
  $ast=Parse $relative
  Check (@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantReservationFatalDiagnostics'}).Count-eq1) ('Explicit fatal opt-in '+$relative)
}
foreach($relative in @('tools/invoke_r19_candidate_app_flash_hil.ps1','tools/invoke_r19_jtag_preflash_gate.ps1')){
  $ast=Parse $relative
  Check (@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantReservationFatalDiagnostics'}).Count-eq1) ('Explicit fatal boundary '+$relative)
  $guards=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq'Assert-R19GrantFatalSelection'})
  Check ($guards.Count-eq1) ('Fatal guard precedes devices '+$relative)
  if($guards.Count-eq1){
    . ([scriptblock]::Create($guards[0].Extent.Text))
    foreach($agreement in @($false,$true)){foreach($stop in @($false,$true)){
      if($agreement-and$stop){Assert-R19GrantFatalSelection -Requested $true -AgreementRequested $agreement -StopRequested $stop;Check $true ('Fatal dependencies accepted '+$relative)}else{Reject {Assert-R19GrantFatalSelection -Requested $true -AgreementRequested $agreement -StopRequested $stop} ('Reject partial fatal dependencies '+$relative)}
      Assert-R19GrantFatalSelection -Requested $false -AgreementRequested $agreement -StopRequested $stop;Check $true ('Default-off legacy selection '+$relative)
    }}
  }
}
ImportFunctions 'tools/invoke_r19_candidate_app_flash_hil.ps1' @('Assert-GrantReservationFatalDocument')
if(Get-Command Assert-GrantReservationFatalDocument -ErrorAction SilentlyContinue){
  $fatalDocument=[pscustomobject]@{grant_reservation_fatal_diagnostics=Get-R19GrantReservationFatalCandidateContract -RepoRoot $repo -Enabled $true}
  Assert-GrantReservationFatalDocument -Record $fatalDocument -RequireFatal $true -RequireAgreement $true -RequireStop $true -RepoRoot $repo
  Check $true 'Flash boundary accepts exact independently source-bound Fatal128'
  foreach($kind in @('missing','case','extra','boolean','reader','undeclared')){
    $bad=$fatalDocument|ConvertTo-Json -Depth 24|ConvertFrom-Json
    switch($kind){'missing'{$bad.PSObject.Properties.Remove('grant_reservation_fatal_diagnostics')};'case'{$value=$bad.grant_reservation_fatal_diagnostics;$bad.PSObject.Properties.Remove('grant_reservation_fatal_diagnostics');$bad|Add-Member NoteProperty Grant_Reservation_Fatal_Diagnostics $value};'extra'{$bad.grant_reservation_fatal_diagnostics|Add-Member NoteProperty extra $true};'boolean'{$bad.grant_reservation_fatal_diagnostics=$true};'reader'{$bad.grant_reservation_fatal_diagnostics.runtime_reader_schema='vc-lora-r19-runtime-stage-jtag-read-v11'}}
    Reject {Assert-GrantReservationFatalDocument -Record $bad -RequireFatal ($kind-cne'undeclared') -RequireAgreement $true -RequireStop $true -RepoRoot $repo} ('Flash rejects malformed fatal '+$kind)
  }
}
$prepareRelative='tools/prepare_r19_fatal_diagnostic_run.ps1'
Check (Test-Path -LiteralPath (Join-Path $repo $prepareRelative) -PathType Leaf) 'New standalone fatal preparation maker exists'
if(Test-Path -LiteralPath (Join-Path $repo $prepareRelative) -PathType Leaf){
  $prepareAst=Parse $prepareRelative
  Check (@($prepareAst.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'CandidateId'}).Count-eq1) 'Fatal preparation binds explicit candidate identity'
  Check (@($prepareAst.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'OutputDirectory'-and$_.Attributes.Extent.Text-match'Mandatory'}).Count-eq1) 'Canonical preparation requires an explicit output directory'
  $repoDefault=@($prepareAst.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'RepoRoot'})
  Check ($repoDefault.Count-eq1-and$repoDefault[0].DefaultValue.Extent.Text-ceq'(Split-Path -Parent $PSScriptRoot)') 'Canonical preparation resolves repository from its own location'
  $prepText=$prepareAst.Extent.Text
  Check ($prepText.Contains('CreateNew')-and$prepText.Contains('Assert-R19TimedPathPreparedContract')-and$prepText.Contains('grant_reservation_fatal_contract')) 'Preparation atomically refuses overwrite and validates new exact contract'
  ImportFunctions $prepareRelative @('Get-R19FatalPreparedOutputPath')
  Reject {Get-R19FatalPreparedOutputPath -OutputDirectory ''} 'Preparation rejects missing output before candidate access'
  Reject {Get-R19FatalPreparedOutputPath -OutputDirectory 'relative/path'} 'Preparation rejects relative output before candidate access'
  Reject {Get-R19FatalPreparedOutputPath -OutputDirectory 'E:drive-relative'} 'Preparation rejects drive-relative output before candidate access'
  $freshOutput=[IO.Path]::GetFullPath((Join-Path $OutputRoot 'fresh-not-created'))
  $preparedOutput=Get-R19FatalPreparedOutputPath -OutputDirectory $freshOutput
  Check ($preparedOutput-ceq(Join-Path $freshOutput 'prepared_fatal_explicit_host_arm.json')-and-not(Test-Path -LiteralPath $freshOutput)) 'Preparation output planning has no file or directory side effects'
  $occupied=Join-Path $OutputRoot 'occupied-output';[void][IO.Directory]::CreateDirectory($occupied)
  [IO.File]::WriteAllText((Join-Path $occupied 'prepared_fatal_explicit_host_arm.json'),'immutable-fixture')
  Reject {Get-R19FatalPreparedOutputPath -OutputDirectory ([IO.Path]::GetFullPath($occupied))} 'Preparation refuses existing output before source or candidate access'
  Reject {Get-R19FatalPreparedOutputPath -OutputDirectory ([IO.Path]::GetFullPath((Join-Path $occupied 'prepared_fatal_explicit_host_arm.json')))} 'Preparation rejects a file used as output directory'
}
Check ((Get-R19CandidateOutputLeaf $true 'ExplicitHostArm' $true $true $true $true $true $true)-ceq'R19-GRANT-AGREEMENT-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001') 'Agreement namespace unchanged'
try{Check ((Get-R19CandidateOutputLeaf $true 'ExplicitHostArm' $true $true $true $true $true $true $true)-ceq'R19-GRANT-FATAL-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001') 'Fatal separate namespace'}catch{Check $false ('Fatal namespace '+$_.Exception.Message)}
$flags=Get-R19CandidateCompileProperty $true 'ExplicitHostArm' $true $true $true $true $true $true
Check (-not$flags.Contains('VC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS')) 'Agreement does not implicitly enable fatal record'
try{Check ((Get-R19CandidateCompileProperty $true 'ExplicitHostArm' $true $true $true $true $true $true $true)-ceq($flags+' -DVC_LORA_R19_GRANT_RESERVATION_FATAL_DIAGNOSTICS=1')) 'Fatal exact compile flags'}catch{Check $false ('Fatal flags '+$_.Exception.Message)}
Reject {Get-R19CandidateOutputLeaf $true 'ExplicitHostArm' $true $true $true $true $true $false $true} 'Fatal requires agreement'
Reject {Get-R19CandidateOutputLeaf $true 'ExplicitHostArm' $true $true $true $true $false $true $true} 'Fatal requires STOP'
Reject {Get-R19CandidateSourceFiles $repo 'ExplicitHostArm' $true $true $true $true $true $false $true} 'Fatal source inventory requires agreement'
try{
  $fatal=Get-R19GrantReservationFatalCandidateContract -RepoRoot $repo -Enabled $true
  Check ($fatal.enabled-and$fatal.scope-ceq'reserved-grant-detail13-only'-and$fatal.paired_raw_reads-eq24) 'Fatal scope and independent pair count'
  Check ($fatal.record.symbol-ceq'vc_lora_r19_grant_reservation_fatal_record'-and$fatal.record.schema_version-eq1-and$fatal.record.size_bytes-eq128) 'Fatal exact independent128 ABI'
  Check ($fatal.runtime_reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v12'-and$fatal.decoder.path-ceq'tools/read_r19_grant_reservation_fatal_record.ps1'-and$fatal.decoder.sha256-ceq(Get-R19Sha256 (Join-Path $repo $fatal.decoder.path))) 'Fatal reader and exact decoder binding'
  foreach($kind in @('size','reader','reads','scope','hash','extra','boolean','case','float')){
    $bad=$fatal|ConvertTo-Json -Depth 20|ConvertFrom-Json
    switch($kind){'size'{$bad.record.size_bytes=512};'reader'{$bad.runtime_reader_schema='vc-lora-r19-runtime-stage-jtag-read-v11'};'reads'{$bad.paired_raw_reads=22};'scope'{$bad.scope='all-runtime-faults'};'hash'{$bad.decoder.sha256='0'*64};'extra'{$bad|Add-Member NoteProperty extra $true};'boolean'{$bad.enabled='true'};'case'{$bad.PSObject.Properties.Remove('enabled');$bad|Add-Member NoteProperty ENABLED $true};'float'{$bad.paired_raw_reads=[double]24}}
    Reject {Assert-R19GrantReservationFatalCandidateContract -Value $bad -RepoRoot $repo -Enabled $true} ('Reject malformed fatal '+$kind)
  }
  Reject {Assert-R19GrantReservationFatalCandidateContract -Value $fatal -RepoRoot $repo -Enabled $false} 'Fatal contract cannot be undeclared'
  $base=Get-R19GrantReservationCandidateContract -RepoRoot $repo -Enabled $true -CancellationEnabled $true -AgreementEnabled $true -FatalEnabled $true
  $stop=Get-R19GrantReservationStopCandidateContract -RepoRoot $repo -Enabled $true -AgreementEnabled $true -FatalEnabled $true
  $agreement=Get-R19GrantAgreementCandidateContract -RepoRoot $repo -Enabled $true -FatalEnabled $true
  Check ($base.reader_schema-ceq$fatal.runtime_reader_schema-and$stop.runtime_reader_schema-ceq$fatal.runtime_reader_schema-and$agreement.runtime_reader_schema-ceq$fatal.runtime_reader_schema) 'All nested fatal reader contracts agree'
  Check ($base.record.size_bytes-eq512-and$stop.size_bytes-eq128-and$agreement.reservation_record_bytes-eq512-and$agreement.stop_record_bytes-eq128) 'Fatal mode preserves original record ABIs'
  $sources=@(Get-R19CandidateSourceFiles $repo 'ExplicitHostArm' $true $true $true $true $true $true $true)
  foreach($relative in @('firmware/high_speed/r19_grant_reservation_fatal_record.hpp','tools/read_r19_grant_reservation_fatal_record.ps1')){Check (@($sources|Where-Object{(Get-R19RelativePath $repo $_.FullName)-ceq$relative}).Count-eq1) ('Fatal exact canonical source '+$relative)}
}catch{Check $false ('Fatal contract '+$_.Exception.Message)}
ImportFunctions 'tools/build_r19_candidate_artifacts.ps1' @('Add-OptionalUsbFailureMetadata','Add-DiagnosticAbiMetadata')
ImportFunctions 'tools/verify_r19_candidate_artifact.ps1' @('Assert-Condition','Assert-ModeContract','Assert-DiagnosticAbiContract')
$builderText=Get-Content -LiteralPath (Join-Path $repo 'tools/build_r19_candidate_artifacts.ps1') -Raw
foreach($field in @('header_count','header_names')){
  $expression=([regex]::Match($builderText,('(?m)^\s*'+$field+'\s*=\s*(.+)$'))).Groups[1].Value
  try{
    & {
      Set-StrictMode -Version Latest
      $timedPathEnabled=$false;$auxReadinessEnabled=$false;$diagnosticUsbFailureEnabled=$false
      $grantDiagnosticsEnabled=$false;$grantReservationEnabled=$false;$grantReservationStopEnabled=$false
      $value=& ([scriptblock]::Create($expression))
      Check ($(if($field-ceq'header_count'){$value-eq$script:R19CandidateHeaderNames.Count}else{@($value).Count-eq$script:R19CandidateHeaderNames.Count})) ('Legacy isolated builder expression defaults fatal off '+$field)
    }
  }catch{Check $false ('Legacy isolated builder expression '+$field+' '+$_.Exception.Message)}
}
$runtimeFailDiagnosticsEnabled=$true;$acceptanceEligible=$false;$timedPathEnabled=$true;$TimedPathMode='ExplicitHostArm'
$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$true;$grantDiagnosticsEnabled=$true;$grantReservationEnabled=$true;$grantReservationStopEnabled=$true;$grantAgreementEnabled=$true
$timedPathContract=Get-R19TimedPathCandidateContract $repo $TimedPathMode
$auxReadinessContract=Get-R19AuxReadinessCandidateContract $repo $true
$diagnosticUsbFailureContract=Get-R19DiagnosticUsbFailureCandidateContract $repo $true
$grantDiagnosticContract=Get-R19GrantDiagnosticCandidateContract $repo $true
$usbRoleCapabilities=Get-R19UsbRoleCapabilities -RepoRoot $repo -Mode $TimedPathMode -Enabled $true
foreach($fatalEnabled in @($false,$true)){
  $grantReservationFatalEnabled=$fatalEnabled
  try{
    $grantReservationContract=Get-R19GrantReservationCandidateContract -RepoRoot $repo -Enabled $true -CancellationEnabled $true -AgreementEnabled $true -FatalEnabled $fatalEnabled
    $grantReservationStopContract=Get-R19GrantReservationStopCandidateContract -RepoRoot $repo -Enabled $true -AgreementEnabled $true -FatalEnabled $fatalEnabled
    $grantAgreementContract=Get-R19GrantAgreementCandidateContract -RepoRoot $repo -Enabled $true -FatalEnabled $fatalEnabled
    $grantReservationFatalContract=Get-R19GrantReservationFatalCandidateContract -RepoRoot $repo -Enabled $fatalEnabled
    $record=[pscustomobject][ordered]@{runtime_fail_diagnostics_enabled=$true;acceptance_authorized=$false;acceptance_eligible=$false;deployment_authorized=$false}
    Add-DiagnosticAbiMetadata $record
    Check (($null-ne$record.PSObject.Properties['grant_reservation_fatal_diagnostics'])-eq$fatalEnabled) ('Builder exact fatal declaration '+$fatalEnabled)
    Check ($record.reader_schema-ceq$(if($fatalEnabled){'vc-lora-r19-runtime-stage-jtag-read-v12'}else{'vc-lora-r19-runtime-stage-jtag-read-v11'})) ('Builder exact selected reader '+$fatalEnabled)
    Assert-ModeContract $record 'fixture';Assert-DiagnosticAbiContract $record 'fixture';Check $true ('Production fatal metadata accepted '+$fatalEnabled)
    if($fatalEnabled){
      foreach($property in @('grant_reservation_fatal_diagnostics','grant_agreement_diagnostics','grant_reservation_stop_diagnostics')){$bad=$record|ConvertTo-Json -Depth 24|ConvertFrom-Json;$bad.PSObject.Properties.Remove($property);Reject {Assert-ModeContract $bad 'fixture'} ('Reject missing fatal chain '+$property)}
      foreach($readerVersion in @(3,4,5,7,8,9,10,11)){
        $bad=$record|ConvertTo-Json -Depth 24|ConvertFrom-Json;$bad.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v'+$readerVersion
        if($readerVersion-eq3){$bad.PSObject.Properties.Remove('usb_extended_diagnostics');$bad.PSObject.Properties.Remove('first_usb_failure_decoder')}
        Reject {Assert-DiagnosticAbiContract $bad 'fixture'} ('Reject top-level reader downgrade '+$readerVersion)
      }
    }else{
      $record|Add-Member NoteProperty grant_reservation_fatal_diagnostics (Get-R19GrantReservationFatalCandidateContract -RepoRoot $repo -Enabled $true)
      Reject {Assert-ModeContract $record 'fixture'} 'Agreement cannot silently claim fatal capability'
    }
  }catch{Check $false ('Metadata fatal='+$fatalEnabled+' '+$_.Exception.Message)}
}
function New-FatalElf([string]$Path,[bool]$IncludeFatal,[int]$FatalSize=128){
  $defs=@(@('vc_lora_r19_runtime_stage_record',68),@('vc_lora_r19_hwcdc_fifo_diagnostic_record',112),@('vc_lora_r19_hwcdc_restart_diagnostic_record',128),@('vc_lora_r19_ground_usb_commit_record',128),@('vc_lora_r19_first_usb_failure_record',384),@('vc_lora_r19_timed_path_record',512),@('vc_lora_r19_aux_readiness_record',6144),@('vc_lora_r19_diagnostic_usb_failure_record',256),@('vc_lora_r19_grant_diagnostic_record',1024),@('vc_lora_r19_grant_reservation_record',512),@('vc_lora_r19_grant_reservation_stop_record',128),@('vc_lora_r19_grant_agreement_capability',4))
  if($IncludeFatal){$defs+=,@('vc_lora_r19_grant_reservation_fatal_record',$FatalSize)}
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
$agreementElf=Join-Path $OutputRoot 'agreement.elf';$fatalElf=Join-Path $OutputRoot 'fatal.elf';$wrongElf=Join-Path $OutputRoot 'fatal-wrong-size.elf'
New-FatalElf $agreementElf $false;New-FatalElf $fatalElf $true;New-FatalElf $wrongElf $true 132
try{Check (@((Get-R19ElfDiagnosticSymbols $agreementElf $true $true $true $true $true $true $true $true $true).PSObject.Properties).Count-eq12) 'Legacy agreement sealed ELF retains twelve symbols'}catch{Check $false ('Legacy agreement ELF '+$_.Exception.Message)}
try{$symbols=Get-R19ElfDiagnosticSymbols $fatalElf $true $true $true $true $true $true $true $true $true $true;Check (@($symbols.PSObject.Properties).Count-eq13-and$symbols.grant_reservation_fatal.size_bytes-eq128) 'Fatal sealed ELF exact thirteen independent symbols'}catch{Check $false ('Fatal ELF '+$_.Exception.Message)}
Reject {Get-R19ElfDiagnosticSymbols $agreementElf $true $true $true $true $true $true $true $true $true $true} 'Reject missing sealed fatal symbol'
Reject {Get-R19ElfDiagnosticSymbols $fatalElf $true $true $true $true $true $true $true $true $true} 'Reject undeclared sealed fatal symbol'
Reject {Get-R19ElfDiagnosticSymbols $wrongElf $true $true $true $true $true $true $true $true $true $true} 'Reject wrong-sized sealed fatal symbol'
# Run the maker's actual sealed-vs-ELF comparison. ELF readers return uint32
# sizes, while the sealed JSON carries exact signed integers. Only the raw
# expected binding may be canonicalized; malformed sealed values must fail.
$bindingMap=Join-Path $OutputRoot 'fatal.map'
[IO.File]::WriteAllText($bindingMap,'synthetic-map-hash-binding-only')
$actual=Get-R19DiagnosticSymbolBinding $fatalElf $bindingMap ('A'*64) $true $true $true $true $true $true $true $true $true
$sealedBinding=$actual|ConvertTo-Json -Depth 20|ConvertFrom-Json
Check ($actual.symbols.runtime_stage.size_bytes-is[uint32]) 'Actual ELF binding exposes uint32 size bytes'
Check ($sealedBinding.symbols.runtime_stage.size_bytes-is[int]-or$sealedBinding.symbols.runtime_stage.size_bytes-is[long]) 'Sealed JSON binding exposes exact signed integer size bytes'
$bindingComparisons=@($prepareAst.FindAll({param($node)
  $node-is[Management.Automation.Language.CommandAst]-and
  $node.GetCommandName()-ceq'Assert-R19GrantReservationShape'-and
  $node.Extent.Text.Contains('prepared-symbols.')
},$true))
Check ($bindingComparisons.Count-eq1) 'One actual maker sealed-symbol comparison is extracted without candidate generation'
if($bindingComparisons.Count-eq1){
  $comparison=[scriptblock]::Create($bindingComparisons[0].Extent.Text)
  $roleName='vehicle';$role=[pscustomobject]@{runtime_diagnostic_symbols=$sealedBinding}
  try{. $comparison;Check $true 'Maker accepts exact sealed JSON against actual ELF uint32 binding'}catch{Check $false ('Maker unsigned ELF comparison '+$_.Exception.Message)}
  foreach($kind in @('string-size','float-size','wrong-size','extra','missing','case','application-hash')){
    $bad=$sealedBinding|ConvertTo-Json -Depth 20|ConvertFrom-Json
    switch($kind){
      'string-size'{$bad.symbols.runtime_stage.size_bytes='68'}
      'float-size'{$bad.symbols.runtime_stage.size_bytes=[double]68}
      'wrong-size'{$bad.symbols.runtime_stage.size_bytes=69}
      'extra'{$bad.symbols.runtime_stage|Add-Member NoteProperty unexpected $true}
      'missing'{$bad.symbols.runtime_stage.PSObject.Properties.Remove('size_bytes')}
      'case'{$bad.symbols.runtime_stage.PSObject.Properties.Remove('size_bytes');$bad.symbols.runtime_stage|Add-Member NoteProperty SIZE_BYTES 68}
      'application-hash'{$bad.application_sha256='B'*64}
    }
    $role=[pscustomobject]@{runtime_diagnostic_symbols=$bad}
    Reject {. $comparison} ('Maker rejects malformed sealed binding '+$kind)
  }
}
$summary=[pscustomobject]@{schema='vc-lora-r19-fatal-packaging-test-v1';checks=$script:checks;failures=$script:failures;result=$(if($script:failures){'FAIL'}else{'PASS'});hardware_interaction=$false}
$summary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json') -Encoding utf8
if($script:failures){throw ('R19_FATAL_PACKAGING RED checks='+$script:checks+' failures='+$script:failures)}
Write-Output ('R19_FATAL_PACKAGING PASS checks='+$script:checks+' hardware_interaction=false')
