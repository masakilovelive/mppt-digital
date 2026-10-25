[CmdletBinding()]
param([string]$RepoRoot='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Check $failed $Message}
function Parse([string]$Path){$tokens=$null;$errors=$null;$a=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);Check (@($errors).Count-eq0) "Parse errors: $Path";return $a}
$flashPath=Join-Path $repo 'tools/invoke_r19_candidate_app_flash_hil.ps1'
$gatePath=Join-Path $repo 'tools/invoke_r19_jtag_preflash_gate.ps1'
$ast=Parse $flashPath
Check (@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantDiagnostics'}).Count-eq1) 'Flash must accept explicit default-off GrantDiagnostics'
$gateAst=Parse $gatePath
Check (@($gateAst.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantDiagnostics'}).Count-eq1) 'PnP-only gate must describe Grant mode without enabling JTAG'
foreach($node in $ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-in@('Assert-Condition','Get-Sha256','Assert-CandidateModeRecord')}){. ([scriptblock]::Create($node.Extent.Text))}
. (Join-Path $repo 'tools/r19_candidate_artifact_common.ps1')
. (Join-Path $repo 'tools/r19_usb_role_contract.ps1')
$runtimeFailDiagnosticsEnabled=$true;$timedPathEnabled=$true;$TimedPathMode='ExplicitHostArm'
$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$true;$grantDiagnosticsEnabled=$true;$acceptanceEligible=$false
function Fixture {
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-candidate-artifact-manifest-v1'
    runtime_fail_diagnostics_enabled=$true;acceptance_eligible=$false
    acceptance_authorized=$false;deployment_authorized=$false
    reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9'
    timed_path_diagnostics=Get-R19TimedPathCandidateContract $repo ExplicitHostArm
    aux_readiness_diagnostics=Get-R19AuxReadinessCandidateContract $repo $true
    diagnostic_usb_failure_diagnostics=Get-R19DiagnosticUsbFailureCandidateContract $repo $true
    usb_role_capabilities=Get-R19UsbRoleCapabilities $repo ExplicitHostArm $true
    grant_diagnostics=Get-R19GrantDiagnosticCandidateContract $repo $true
  }
}
$good=Fixture
Assert-CandidateModeRecord $good 'valid Grant fixture';Check $true 'Exact v9 Grant fixture accepted'
foreach($pair in @(@('enabled',$false),@('schema','unknown'),@('reader_schema','vc-lora-r19-runtime-stage-jtag-read-v8'),@('macro','wrong'))){
  $bad=Fixture;$bad.grant_diagnostics.($pair[0])=$pair[1]
  Reject {Assert-CandidateModeRecord $bad 'invalid Grant fixture'} "Grant field mismatch rejected: $($pair[0])"
}
foreach($pair in @(@('size_bytes',256),@('schema_version',2),@('symbol','wrong'))){
  $bad=Fixture;$bad.grant_diagnostics.record.($pair[0])=$pair[1]
  Reject {Assert-CandidateModeRecord $bad 'invalid Grant record'} "Grant ABI mismatch rejected: $($pair[0])"
}
$bad=Fixture;$bad.grant_diagnostics.decoder.sha256=('0'*64);Reject {Assert-CandidateModeRecord $bad 'decoder mismatch'} 'Grant decoder hash mismatch rejected'
$bad=Fixture;$bad.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8';Reject {Assert-CandidateModeRecord $bad 'top reader downgrade'} 'Grant top-level reader downgrade rejected'
$bad=Fixture;$bad.PSObject.Properties.Remove('grant_diagnostics');Reject {Assert-CandidateModeRecord $bad 'missing Grant contract'} 'Grant flag cannot accept a legacy candidate'
$bad=Fixture;$bad.grant_diagnostics|Add-Member NoteProperty unexpected $true;Reject {Assert-CandidateModeRecord $bad 'extra Grant field'} 'Unreviewed Grant contract fields rejected'
$grantDiagnosticsEnabled=$false
Reject {Assert-CandidateModeRecord (Fixture) 'undeclared Grant'} 'Candidate Grant mode cannot escalate undeclared invocation'
$legacy=Fixture;$legacy.PSObject.Properties.Remove('grant_diagnostics');$legacy.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8'
Assert-CandidateModeRecord $legacy 'legacy v8 fixture';Check $true 'Legacy v8 candidate remains supported without Grant flag'
Check ($legacy.diagnostic_usb_failure_diagnostics.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v8') 'Underlying diagnostic USB contract stays v8'
$text=Get-Content -LiteralPath $flashPath -Raw
$initialModeStart=$text.IndexOf('$runtimeFailDiagnosticsEnabled =')
$initialModeEnd=$text.IndexOf('$acceptanceEligible =', $initialModeStart)
Check ($initialModeStart-ge0-and$initialModeEnd-gt$initialModeStart) 'Mode validation occurs before execution setup'
$initialModeSource=[scriptblock]::Create($text.Substring($initialModeStart,$initialModeEnd-$initialModeStart))
foreach($modeCase in @(@($false,'ExplicitHostArm',$true,$true),@($true,'Disabled',$true,$true),@($true,'ExplicitHostArm',$false,$true),@($true,'ExplicitHostArm',$true,$false))){
  Reject { & {
    $RuntimeFailDiagnostics=[Management.Automation.SwitchParameter]::new([bool]$modeCase[0])
    $TimedPathMode=[string]$modeCase[1]
    $AuxReadinessDiagnostics=[Management.Automation.SwitchParameter]::new([bool]$modeCase[2])
    $DiagnosticUsbFailureDiagnostics=[Management.Automation.SwitchParameter]::new([bool]$modeCase[3])
    $GrantDiagnostics=[Management.Automation.SwitchParameter]::new($true)
    . $initialModeSource
  }} 'Incomplete Grant diagnostic invocation rejects before any execution setup'
}
Check ($text.Contains('$modeArguments.GrantDiagnostics=$true')) 'Flash forwards Grant switch to staged verifier'
Check ($text.Contains('R19-GRANT-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001')) 'Flash selects isolated Grant output leaf'
Check ($text.Contains('$record[''grant_diagnostics'']=$modeHandoff.grant_diagnostics')) 'Flash evidence preserves exact handoff Grant metadata'
$gateText=Get-Content -LiteralPath $gatePath -Raw
$runtime=$gateText.Substring($gateText.LastIndexOf('Initialize-OutputDirectory',[StringComparison]::Ordinal))
Check ($runtime-notmatch 'Invoke-ReaderPreflight|Assert-LiveToolchain|Invoke-OpenOcd|transport init') 'Grant flag must not turn PnP-only gate into active JTAG'
Check ($runtime.Contains('firmware_install_allowed=$false')-and$runtime.Contains('active_jtag_proven=$false')) 'PnP-only install and JTAG prohibitions unchanged'
Write-Output "check_r19_grant_flash_contract PASS checks=$checks hardware_interaction=false"
