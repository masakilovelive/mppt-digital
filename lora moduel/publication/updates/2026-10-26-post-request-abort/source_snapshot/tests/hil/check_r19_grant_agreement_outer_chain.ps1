param([string]$RepoRoot='')
$ErrorActionPreference='Stop'
if(!$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_contract.ps1')
$checks=0
function Check($ok,$message){$script:checks++;if(!$ok){throw $message}}
function Reject($body,$message){$caught=$false;try{&$body}catch{$caught=$true};Check $caught $message}
foreach($name in @('invoke_r19_candidate_app_flash_hil.ps1','invoke_r19_runtime_stage_cause_experiment_hil.ps1')){
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot ('tools/'+$name)),[ref]$tokens,[ref]$errors)
  Check ($errors.Count-eq0) ('parse '+$name)
  Check (@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantAgreementDiagnostics'}).Count-eq1) ('canonical agreement flag missing '+$name)
  $f=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Assert-GrantAgreementDocument'},$true))
  Check ($f.Count-eq1) ('strict agreement document boundary missing '+$name)
  . ([scriptblock]::Create($f[0].Extent.Text))
  $contract=Get-R19GrantAgreementCandidateContract -RepoRoot $RepoRoot -Enabled $true
  $record=[pscustomobject]@{grant_agreement_diagnostics=$contract}
  [void](Assert-GrantAgreementDocument -Record $record -RequireAgreement $true -RequireStop $true -RepoRoot $RepoRoot)
  Check $true ('canonical v3 accepted '+$name)
  Reject {Assert-GrantAgreementDocument -Record $record -RequireAgreement $false -RequireStop $true -RepoRoot $RepoRoot} 'undeclared agreement cannot downgrade'
  Reject {Assert-GrantAgreementDocument -Record $record -RequireAgreement $true -RequireStop $false -RepoRoot $RepoRoot} 'agreement needs STOP'
  Reject {Assert-GrantAgreementDocument -Record ([pscustomobject]@{}) -RequireAgreement $true -RequireStop $true -RepoRoot $RepoRoot} 'missing agreement rejected'
  Reject {Assert-GrantAgreementDocument -Record ([pscustomobject]@{Grant_Agreement_Diagnostics=$contract}) -RequireAgreement $true -RequireStop $true -RepoRoot $RepoRoot} 'case-variant agreement rejected'
  Reject {Assert-GrantAgreementDocument -Record ([pscustomobject]@{grant_agreement_diagnostics=$true}) -RequireAgreement $true -RequireStop $true -RepoRoot $RepoRoot} 'bool cannot replace capability object'
  $bad=$record|ConvertTo-Json -Depth 25|ConvertFrom-Json
  $bad.grant_agreement_diagnostics|Add-Member NoteProperty unreviewed_extra $true
  Reject {Assert-GrantAgreementDocument -Record $bad -RequireAgreement $true -RequireStop $true -RepoRoot $RepoRoot} 'extra contract field rejected'
  foreach($switch in @('GrantAgreementDiagnostics')){
    $modeArgs=@{$switch=$true}
    $caught='';try{& (Join-Path $RepoRoot ('tools/'+$name)) -Execute @modeArgs}catch{$caught=$_.Exception.Message}
    Check ($caught-clike'Grant agreement requires*') ('dependency failure must precede devices '+$name)
  }
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1'),[ref]$tokens,[ref]$errors)
$f=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Assert-GrantAgreementStageMetadata'},$true))
Check ($f.Count-eq1) 'exact stage agreement binding helper missing'
. ([scriptblock]::Create($f[0].Extent.Text))
function Assert-Condition($ok,$message){Check $ok $message}
function Assert-RawProjection($a,$b,$message){Check (($a|ConvertTo-Json -Depth 20 -Compress)-ceq($b|ConvertTo-Json -Depth 20 -Compress)) $message}
$marker=[pscustomobject]@{name='vc_lora_r19_grant_agreement_capability';address='0x3FC90000';size_bytes=4;aligned_32_bit=$true}
$sealed=[pscustomobject]@{symbols=[pscustomobject]@{grant_agreement_capability=$marker}}
$manifest=[pscustomobject]@{grant_agreement_diagnostics=$contract}
$summary=[pscustomobject]@{grant_agreement_required=$true;binding=[pscustomobject]@{grant_agreement_diagnostics=$contract;grant_agreement_capability=$marker;artifact=[pscustomobject]@{grant_agreement_enabled=$true;grant_agreement_diagnostics=$contract;symbols=$sealed.symbols}}}
Assert-GrantAgreementStageMetadata $summary $manifest $sealed $true $RepoRoot
foreach($mutation in @('required','contract','artifact_contract','contract_extra','contract_case','marker','symbol','size','float_size')){
  $bad=$summary|ConvertTo-Json -Depth 25|ConvertFrom-Json
  switch($mutation){'required'{$bad.grant_agreement_required=$false};'contract'{$bad.binding.grant_agreement_diagnostics=$null};'artifact_contract'{$bad.binding.artifact.grant_agreement_diagnostics=$null};'marker'{$bad.binding.grant_agreement_capability=$null};'symbol'{$bad.binding.artifact.symbols=[pscustomobject]@{}};'size'{$bad.binding.grant_agreement_capability.size_bytes=8};'float_size'{$bad.binding.grant_agreement_capability.size_bytes=[single]4}}
  if($mutation-ceq'contract_extra'){$bad.binding.grant_agreement_diagnostics|Add-Member NoteProperty unreviewed_extra $true}
  if($mutation-ceq'contract_case'){$v=$bad.binding.grant_agreement_diagnostics.wire_version;$bad.binding.grant_agreement_diagnostics.PSObject.Properties.Remove('wire_version');$bad.binding.grant_agreement_diagnostics|Add-Member NoteProperty Wire_Version $v}
  Reject {Assert-GrantAgreementStageMetadata $bad $manifest $sealed $true $RepoRoot} ('stage mutation rejected '+$mutation)
}
Reject {Assert-GrantAgreementStageMetadata $summary $manifest $sealed $false $RepoRoot} 'v3 stage cannot downgrade to undeclared mode'
$legacy=[pscustomobject]@{binding=[pscustomobject]@{artifact=[pscustomobject]@{symbols=[pscustomobject]@{}}}}
Assert-GrantAgreementStageMetadata $legacy ([pscustomobject]@{}) ([pscustomobject]@{symbols=[pscustomobject]@{}}) $false $RepoRoot
foreach($field in @('grant_agreement_enabled','grant_agreement_diagnostics')){
  $bad=$legacy|ConvertTo-Json -Depth 25|ConvertFrom-Json
  $bad.binding.artifact|Add-Member NoteProperty $field $true
  Reject {Assert-GrantAgreementStageMetadata $bad ([pscustomobject]@{}) ([pscustomobject]@{symbols=[pscustomobject]@{}}) $false $RepoRoot} ('undeclared artifact field '+$field)
}
Write-Output ('AGREEMENT_OUTER_CHAIN PASS checks='+$checks+' hardware_interaction=false')
