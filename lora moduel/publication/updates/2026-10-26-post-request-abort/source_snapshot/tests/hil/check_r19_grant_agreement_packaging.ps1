[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not$OutputRoot){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-agreement-package-'+[Guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($OutputRoot)
. (Join-Path $repo 'tools/r19_candidate_artifact_common.ps1')
$script:checks=0;$script:failures=0
function Check([bool]$Value,[string]$Name){$script:checks++;if(-not$Value){$script:failures++;Write-Output ('FAIL '+$Name)}}
function Reject([scriptblock]$Action,[string]$Name){$rejected=$false;try{&$Action|Out-Null}catch{$rejected=$true};Check $rejected $Name}
function Parse([string]$Relative){$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $Relative),[ref]$t,[ref]$e);Check (@($e).Count-eq0) ('Parses '+$Relative);return $a}
function ImportFunctions([string]$Relative,[string[]]$Names){
  $a=Parse $Relative
  foreach($name in $Names){$nodes=@($a.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq$name});Check ($nodes.Count-eq1) ('Unique production function '+$name);if($nodes.Count-eq1){. ([scriptblock]::Create($nodes[0].Extent.Text));Set-Item -Path ('Function:script:'+$name) -Value (Get-Item ('Function:'+$name)).ScriptBlock}}
}
foreach($relative in @('tools/build_r19_candidate_artifacts.ps1','tools/verify_r19_candidate_artifact.ps1')){
  $a=Parse $relative
  Check (@($a.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantAgreementDiagnostics'}).Count-eq1) ('Explicit agreement opt-in '+$relative)
}
$legacyLeaf=Get-R19CandidateOutputLeaf $true 'ExplicitHostArm' $true $true $true $true $true
Check ($legacyLeaf-ceq'R19-GRANT-RESERVATION-STOP-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001') 'Legacy STOP namespace unchanged'
try{Check ((Get-R19CandidateOutputLeaf $true 'ExplicitHostArm' $true $true $true $true $true $true)-ceq'R19-GRANT-AGREEMENT-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001') 'Agreement separate namespace'}catch{Check $false ('Agreement namespace '+$_.Exception.Message)}
$legacyFlags=Get-R19CandidateCompileProperty $true 'ExplicitHostArm' $true $true $true $true $true
Check (-not$legacyFlags.Contains('VC_LORA_R19_GRANT_AGREEMENT_DIAGNOSTICS')) 'Legacy STOP flags do not enable v3'
try{Check ((Get-R19CandidateCompileProperty $true 'ExplicitHostArm' $true $true $true $true $true $true)-ceq($legacyFlags+' -DVC_LORA_R19_GRANT_AGREEMENT_DIAGNOSTICS=1')) 'Agreement exact flags'}catch{Check $false ('Agreement flags '+$_.Exception.Message)}
Reject {Get-R19CandidateOutputLeaf $true 'ExplicitHostArm' $true $true $true $true $false $true} 'Agreement requires STOP'
Reject {Get-R19CandidateSourceFiles $repo 'ExplicitHostArm' $true $true $true $true $false $true} 'Agreement inventory requires STOP'
$builderAst=Parse 'tools/build_r19_candidate_artifacts.ps1'
$compileAssignment=@($builderAst.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left.Extent.Text-ceq'$compileArguments'},$true))
Check ($compileAssignment.Count-eq1) 'Actual builder compile argv assignment is unique'
if($compileAssignment.Count-eq1){
  foreach($enabled in @($false,$true)){
    $grantAgreementEnabled=$enabled;$globalArgs=@('--config-file','offline.yaml');$Fqbn='offline-fqbn';$buildPath='offline-build';$outputPath='offline-output';$compileProperty='offline-property';$role=[pscustomobject]@{role='vehicle'};$stagedRoles=@{vehicle='offline-stage'}
    . ([scriptblock]::Create($compileAssignment[0].Extent.Text))
    $jobs=@(for($i=0;$i-lt$compileArguments.Count;$i++){if($compileArguments[$i]-ceq'--jobs'){$i}})
    Check ($jobs.Count-eq$(if($enabled){1}else{0})) ('Actual builder concurrency is separately opt-in '+$enabled)
    if($enabled-and$jobs.Count-eq1){Check ($compileArguments[$jobs[0]+1]-ceq'2') 'Agreement build limits concurrent jobs to two'}
  }
}
try{
  $agreement=Get-R19GrantAgreementCandidateContract -RepoRoot $repo -Enabled $true
  Check ($agreement.usb_control_schema-ceq'vc-lora-r19-grant-reservation-usb-v3'-and$agreement.wire_version-eq3-and$agreement.frame_bytes-eq66) 'Agreement exact wire3 contract'
  Check ($agreement.runtime_reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v11'-and$agreement.reservation_record_bytes-eq512-and$agreement.stop_record_bytes-eq128) 'Existing reader and record ABIs unchanged'
  Check ($agreement.opcodes.CommitRequest-eq19-and$agreement.opcodes.CommitAck-eq20-and$agreement.opcodes.AbortRequest-eq21-and$agreement.opcodes.AbortAck-eq22) 'Exact v3 operation numbers'
  Check ($agreement.terminal_abort.requires_both_role_ack-and-not$agreement.terminal_abort.unknown_prefix_retry_allowed-and$agreement.commit.requires_both_role_ack_before_param) 'ACK facts distinct from future atomic guarantee'
  foreach($binding in @($agreement.source_bindings)){
    Check ($binding.sha256-ceq(Get-R19Sha256 (Join-Path $repo $binding.path))) ('Agreement source binding '+$binding.path)
  }
  $sourceFiles=@(Get-R19CandidateSourceFiles $repo 'ExplicitHostArm' $true $true $true $true $true $true)
  foreach($binding in @($agreement.source_bindings)){
    Check (@($sourceFiles|Where-Object{(Get-R19RelativePath $repo $_.FullName)-ceq$binding.path}).Count-eq1) ('Canonical closure includes exact '+$binding.path)
  }
  foreach($kind in @('wire','opcode','reader','hash','extra','boolean','case')){
    $bad=$agreement|ConvertTo-Json -Depth 24|ConvertFrom-Json
    switch($kind){'wire'{$bad.wire_version=2};'opcode'{$bad.opcodes.CommitRequest=18};'reader'{$bad.runtime_reader_schema='vc-lora-r19-runtime-stage-jtag-read-v10'};'hash'{$bad.source_bindings[0].sha256='0'*64};'extra'{$bad|Add-Member NoteProperty extra $true};'boolean'{$bad.commit.requires_both_role_ack_before_param='true'};'case'{$value=$bad.wire_version;$bad.PSObject.Properties.Remove('wire_version');$bad|Add-Member NoteProperty WIRE_VERSION $value}}
    Reject {Assert-R19GrantAgreementCandidateContract -Value $bad -RepoRoot $repo -Enabled $true} ('Reject malformed agreement '+$kind)
  }
}catch{Check $false ('Agreement contract '+$_.Exception.Message)}
ImportFunctions 'tools/build_r19_candidate_artifacts.ps1' @('Add-OptionalUsbFailureMetadata','Add-DiagnosticAbiMetadata')
ImportFunctions 'tools/verify_r19_candidate_artifact.ps1' @('Assert-Condition','Assert-ModeContract','Assert-DiagnosticAbiContract')
$runtimeFailDiagnosticsEnabled=$true;$acceptanceEligible=$false;$timedPathEnabled=$true;$TimedPathMode='ExplicitHostArm'
$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$true;$grantDiagnosticsEnabled=$true;$grantReservationEnabled=$true;$grantReservationStopEnabled=$true
$timedPathContract=Get-R19TimedPathCandidateContract $repo $TimedPathMode
$auxReadinessContract=Get-R19AuxReadinessCandidateContract $repo $true
$diagnosticUsbFailureContract=Get-R19DiagnosticUsbFailureCandidateContract $repo $true
$grantDiagnosticContract=Get-R19GrantDiagnosticCandidateContract $repo $true
$usbRoleCapabilities=Get-R19UsbRoleCapabilities -RepoRoot $repo -Mode $TimedPathMode -Enabled $true
foreach($enabled in @($false,$true)){
  $grantAgreementEnabled=$enabled
  try{
    $grantReservationContract=Get-R19GrantReservationCandidateContract -RepoRoot $repo -Enabled $true -CancellationEnabled $true -AgreementEnabled $enabled
    $grantReservationStopContract=Get-R19GrantReservationStopCandidateContract -RepoRoot $repo -Enabled $true -AgreementEnabled $enabled
    $grantAgreementContract=Get-R19GrantAgreementCandidateContract -RepoRoot $repo -Enabled $enabled
    $record=[pscustomobject][ordered]@{runtime_fail_diagnostics_enabled=$true;acceptance_authorized=$false;acceptance_eligible=$false;deployment_authorized=$false}
    Add-DiagnosticAbiMetadata $record
    Check (($null-ne$record.PSObject.Properties['grant_agreement_diagnostics'])-eq$enabled) ('Exact opt-in declaration '+$enabled)
    Assert-ModeContract $record 'fixture';Assert-DiagnosticAbiContract $record 'fixture';Check $true ('Production metadata accepted '+$enabled)
    if($enabled){
      Check ($record.grant_reservation_diagnostics.usb_control.schema-ceq'vc-lora-r19-grant-reservation-usb-v3'-and$record.grant_reservation_stop_diagnostics.usb_control_schema-ceq'vc-lora-r19-grant-reservation-usb-v3') 'All nested contracts bind wire3'
      foreach($property in @('grant_agreement_diagnostics','grant_reservation_diagnostics','grant_reservation_stop_diagnostics')){
        $bad=$record|ConvertTo-Json -Depth 24|ConvertFrom-Json;$bad.PSObject.Properties.Remove($property)
        Reject {Assert-ModeContract $bad 'fixture'} ('Reject missing agreement chain '+$property)
      }
      $record.grant_reservation_diagnostics.usb_control.schema='vc-lora-r19-grant-reservation-usb-v2'
      Reject {Assert-ModeContract $record 'fixture'} 'Reject nested wire downgrade'
    }else{
      $record|Add-Member NoteProperty grant_agreement_diagnostics (Get-R19GrantAgreementCandidateContract -RepoRoot $repo -Enabled $true)
      Reject {Assert-ModeContract $record 'fixture'} 'Legacy cannot claim agreement implicitly'
    }
  }catch{Check $false ('Metadata opt-in='+$enabled+' '+$_.Exception.Message)}
}
function New-AgreementElf([string]$Path,[bool]$IncludeMarker,[int]$MarkerSize=4){
  $defs=@(@('vc_lora_r19_runtime_stage_record',68),@('vc_lora_r19_hwcdc_fifo_diagnostic_record',112),@('vc_lora_r19_hwcdc_restart_diagnostic_record',128),@('vc_lora_r19_ground_usb_commit_record',128),@('vc_lora_r19_first_usb_failure_record',384),@('vc_lora_r19_timed_path_record',512),@('vc_lora_r19_aux_readiness_record',6144),@('vc_lora_r19_diagnostic_usb_failure_record',256),@('vc_lora_r19_grant_diagnostic_record',1024),@('vc_lora_r19_grant_reservation_record',512),@('vc_lora_r19_grant_reservation_stop_record',128))
  if($IncludeMarker){$defs+=,@('vc_lora_r19_grant_agreement_capability',$MarkerSize)}
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
$legacyElf=Join-Path $OutputRoot 'legacy-stop.elf';$agreementElf=Join-Path $OutputRoot 'agreement.elf';$badElf=Join-Path $OutputRoot 'agreement-wrong-marker.elf'
New-AgreementElf $legacyElf $false;New-AgreementElf $agreementElf $true;New-AgreementElf $badElf $true 8
try{Check (@((Get-R19ElfDiagnosticSymbols $legacyElf $true $true $true $true $true $true $true $true).PSObject.Properties).Count-eq11) 'Legacy STOP eleven symbols unchanged'}catch{Check $false ('Legacy ELF '+$_.Exception.Message)}
try{$symbols=Get-R19ElfDiagnosticSymbols $agreementElf $true $true $true $true $true $true $true $true $true;Check ($symbols.grant_agreement_capability.name-ceq'vc_lora_r19_grant_agreement_capability'-and$symbols.grant_agreement_capability.size_bytes-eq4) 'Agreement actual sealed ELF has exact capability marker'}catch{Check $false ('Agreement ELF '+$_.Exception.Message)}
Reject {Get-R19ElfDiagnosticSymbols $legacyElf $true $true $true $true $true $true $true $true $true} 'Agreement rejects v2 ELF without marker'
Reject {Get-R19ElfDiagnosticSymbols $agreementElf $true $true $true $true $true $true $true $true} 'Legacy rejects undeclared v3 ELF marker'
Reject {Get-R19ElfDiagnosticSymbols $badElf $true $true $true $true $true $true $true $true $true} 'Agreement rejects wrong-sized marker'
$summary=[pscustomobject]@{schema='vc-lora-r19-agreement-packaging-test-v1';checks=$script:checks;failures=$script:failures;result=$(if($script:failures){'FAIL'}else{'PASS'});hardware_interaction=$false}
$summary|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json') -Encoding utf8
if($script:failures-gt0){throw ('R19_AGREEMENT_PACKAGING RED checks='+$script:checks+' failures='+$script:failures)}
Write-Output ('R19_AGREEMENT_PACKAGING PASS checks='+$script:checks+' hardware_interaction=false')
