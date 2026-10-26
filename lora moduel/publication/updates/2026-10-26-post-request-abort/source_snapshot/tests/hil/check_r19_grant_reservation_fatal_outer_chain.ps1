param([string]$RepoRoot='')
$ErrorActionPreference='Stop'
if(!$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$checks=0
function Check($ok,$label){$script:checks++;if(!$ok){throw $label}}
foreach($name in @('read_r19_runtime_stage_jtag.ps1','invoke_r19_jtag_preflash_gate.ps1','invoke_r19_runtime_stage_cause_experiment_hil.ps1','run_r19_timed_path_capture.ps1','invoke_r19_candidate_app_flash_hil.ps1')){
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot ('tools/'+$name)),[ref]$tokens,[ref]$errors)
  Check ($errors.Count-eq0) ('parse '+$name)
  Check (@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantReservationFatalDiagnostics'}).Count-eq1) ('explicit fatal flag missing '+$name)
  $guard=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Assert-R19GrantFatalSelection'},$true))
  Check ($guard.Count-eq1) ('pure dependency guard missing '+$name)
  . ([scriptblock]::Create($guard[0].Extent.Text))
  foreach($a in @($false,$true)){foreach($s in @($false,$true)){
    $caught=$false;try{Assert-R19GrantFatalSelection -Requested $true -AgreementRequested $a -StopRequested $s}catch{$caught=$_.Exception.Message-clike'Grant reservation fatal requires*'}
    Check ($caught-eq(-not($a-and$s))) ('fatal dependency '+$name)
    Assert-R19GrantFatalSelection -Requested $false -AgreementRequested $a -StopRequested $s
    Check $true ('legacy dependency no-op '+$name)
  }}
}
foreach($name in @('r19_timed_path_acquisition.ps1','r19_timed_path_outer.ps1')){
  $source=Get-Content -LiteralPath (Join-Path $RepoRoot ('tools/'+$name)) -Raw
  Check ($source.Contains('GrantReservationFatalDiagnostics')) ('fatal propagation missing '+$name)
}
$reader=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/read_r19_runtime_stage_jtag.ps1') -Raw
Check ($reader.Contains('vc-lora-r19-runtime-stage-jtag-read-v12')) 'reader v12 required'
Check ($reader.Contains('grant_reservation_fatal_first')-and$reader.Contains('grant_reservation_fatal_second')) 'paired fatal raw acquisition required'
Check ($reader.Contains('exactly24 paired reads')) 'strict24 reads required'
# Execute the actual default-off replay branch, without invoking parent main,
# native tools, serial I/O or a mocked success path.
$tokens=$null;$errors=$null
$outerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1'),[ref]$tokens,[ref]$errors)
$extended=@($outerAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Get-ExtendedStageRawReplay'},$true))[0]
$fatalBranch=@($extended.FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Clauses[0].Item1.Extent.Text-ceq'$hasFatal'-and$n.Extent.Text.Contains('Undeclared fatal raw replay')},$true))[0]
Check ($null-ne$fatalBranch.ElseClause) 'actual fatal default-off replay branch'
$rejectUndeclared=[scriptblock]::Create($fatalBranch.ElseClause.Extent.Text.TrimStart('{').TrimEnd('}'))
function Assert-Condition([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
foreach($mutation in @('none','false','true','stringfalse','wrongcase','top-address','binding-address','artifact-address','decoded')){
  $manifest=[pscustomobject]@{};$sealed=[pscustomobject]@{symbols=[pscustomobject]@{}}
  $Summary=[pscustomobject]@{binding=[pscustomobject]@{artifact=[pscustomobject]@{}};decoded=[pscustomobject]@{}}
  switch($mutation){
    'false'{$Summary.binding.artifact|Add-Member NoteProperty grant_reservation_fatal_enabled $false}
    'true'{$Summary.binding.artifact|Add-Member NoteProperty grant_reservation_fatal_enabled $true}
    'stringfalse'{$Summary.binding.artifact|Add-Member NoteProperty grant_reservation_fatal_enabled 'false'}
    'wrongcase'{$Summary.binding.artifact|Add-Member NoteProperty Grant_reservation_fatal_enabled $false}
    'top-address'{$Summary|Add-Member NoteProperty grant_reservation_fatal_address '0x3FC80000'}
    'binding-address'{$Summary.binding|Add-Member NoteProperty grant_reservation_fatal_address '0x3FC80000'}
    'artifact-address'{$Summary.binding.artifact|Add-Member NoteProperty grant_reservation_fatal_address '0x3FC80000'}
    'decoded'{$Summary.decoded|Add-Member NoteProperty grant_reservation_fatal ([pscustomobject]@{fatal_latched=$false})}
  }
  $caught=$false;try{. $rejectUndeclared}catch{$caught=$true}
  Check ($caught-eq($mutation-cnotin@('none','false'))) ('default-off exact fatal evidence '+$mutation)
}
$outerText=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1') -Raw
foreach($projection in @('install fatal binding','fatal flash binding','candidate fatal contract','prepared fatal contract','seal fatal contract')){
  Check ($outerText.Contains($projection)) ('fatal projection boundary '+$projection)
}
$captureText=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/run_r19_timed_path_capture.ps1') -Raw
Check ($captureText.Contains("if(`$GrantReservationFatalDiagnostics){`$relative='tools/read_r19_grant_reservation_fatal_record.ps1'")) 'capture pins fatal decoder source'
Check ($captureText.Contains('Undeclared fatal capture contract without selection')) 'capture rejects orphan fatal contract'
$readerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'tools/read_r19_runtime_stage_jtag.ps1'),[ref]$tokens,[ref]$errors)
$bindingFunction=@($readerAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Assert-ExtendedArtifactBinding'},$true))[0]
$readerFatalBranch=@($bindingFunction.FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Clauses[0].Item1.Extent.Text-ceq'$fatalRequested'-and$n.Extent.Text.Contains('Undeclared fatal capability metadata symbol or compiler flag')},$true))[0]
$rejectHiddenSymbol=[scriptblock]::Create($readerFatalBranch.ElseClause.Extent.Text.TrimStart('{').TrimEnd('}'))
$FatalMatches=@();$documents=@([pscustomobject]@{});$RoleEntry=[pscustomobject]@{runtime_diagnostic_symbols=[pscustomobject]@{symbols=[pscustomobject]@{grant_reservation_fatal=[pscustomobject]@{size_bytes=128}}}}
$caught=$false;try{. $rejectHiddenSymbol}catch{$caught=$true}
Check $caught 'reader default-off refuses hidden sealed fatal symbol'
Write-Output ('fatal outer-chain checks='+$checks+' PASS')
