[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Join-Path $PSScriptRoot '../..'}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not$OutputRoot){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-aux-capture-routing-'+[guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
$OutputRoot=(Resolve-Path -LiteralPath $OutputRoot).Path
$checks=[Collections.Generic.List[object]]::new()
$observations=[Collections.Generic.List[object]]::new()
function Require([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){
  try{&$Body;$checks.Add([pscustomobject]@{name=$Name;passed=$true;error=''})}
  catch{$checks.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message})}
}
function Parse-Source([string]$Relative){
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $Relative),[ref]$tokens,[ref]$errors)
  Require ($errors.Count-eq0) ('Source does not parse: '+$Relative)
  return $ast
}
function Get-Assignment($Ast,[string]$Name){
  return @($Ast.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left.Extent.Text-ceq('$'+$Name)},$true))
}
function Get-StatementSlice($First,$Last){
  Require ($First.Parent-eq$Last.Parent) 'Test slice endpoints must be sibling statements'
  return @($First.Parent.Statements|Where-Object{$_.Extent.StartOffset-ge$First.Extent.StartOffset-and$_.Extent.EndOffset-le$Last.Extent.EndOffset})
}
function Assert-SafeSlice([object[]]$Statements,[string[]]$Commands,[string[]]$DynamicCommands=@()){
  foreach($s in $Statements){
    foreach($n in $s.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]},$true)){
      $name=$n.GetCommandName()
      if($null-eq$name){
        Require ($n.InvocationOperator-eq[Management.Automation.Language.TokenKind]::Ampersand-and$n.CommandElements[0].Extent.Text-cin$DynamicCommands) ('Unexpected dynamic command: '+$n.Extent.Text)
      }else{Require ($name-cin$Commands) ('Unsafe command in offline AST slice: '+$name)}
    }
    foreach($n in $s.FindAll({param($n)$n-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true)){
      Require ($n.Extent.Text-cin@('[DateTime]::UtcNow.ToString(''o'')','$issued.ToString(''o'')','$issued.AddSeconds(120).ToString(''o'')','$issued.AddSeconds(120)')) ('Unexpected method in offline AST slice: '+$n.Extent.Text)
    }
  }
}
function Assert-SafeAuxGuard($Guard){
  $effects=@($Guard.FindAll({param($n)
    $n-is[Management.Automation.Language.CommandAst]-or
    $n-is[Management.Automation.Language.InvokeMemberExpressionAst]-or
    $n-is[Management.Automation.Language.MemberExpressionAst]-or
    $n-is[Management.Automation.Language.AssignmentStatementAst]-or
    $n-is[Management.Automation.Language.TypeExpressionAst]-or
    $n-is[Management.Automation.Language.ScriptBlockExpressionAst]
  },$true))
  Require ($effects.Count-eq0) 'Offline AUX guard may contain comparisons/throw only; command, assignment or member operation rejected'
}
function Assert-SafeVerifierEngine([object[]]$Statements){
  $engines=@(foreach($s in $Statements){Get-Assignment $s engine})
  Require ($engines.Count-eq1) 'Offline verifier slice must assign its engine exactly once'
  Require ($engines[0].Operator-eq[Management.Automation.Language.TokenKind]::Equals-and
    $engines[0].Right.Extent.Text-ceq'(Get-Process -Id $PID).Path') 'Offline verifier engine must resolve only through the harness Get-Process shim'
}
function Count-Token([object[]]$Arguments,[string]$Token){return @($Arguments|Where-Object{[string]$_-ceq$Token}).Count}
function Token-Value([object[]]$Arguments,[string]$Token){
  Require ((Count-Token $Arguments $Token)-eq1) ('Argument must occur exactly once: '+$Token)
  $i=[Array]::IndexOf($Arguments,$Token)
  Require ($i-ge0-and$i+1-lt$Arguments.Count) ('Missing value: '+$Token)
  return [string]$Arguments[$i+1]
}
$outer=Parse-Source 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1'
$runner=Parse-Source 'tools/run_r19_timed_path_capture.ps1'
$verifier=Parse-Source 'tools/verify_r19_candidate_artifact.ps1'
$first=@(Get-Assignment $outer captureArguments|Where-Object{$_.Operator-eq[Management.Automation.Language.TokenKind]::Equals})
$last=@(Get-Assignment $outer captureStep)
Require ($first.Count-eq1-and$last.Count-eq1) 'Unique real outer capture argument construction and invocation required'
$outerStatements=Get-StatementSlice $first[0] $last[0]
Assert-SafeSlice $outerStatements @('Read-JsonIfPresent','Join-Path','Write-DurableJson','Get-Sha256','Invoke-ExperimentStep')
$outerText=($outerStatements|ForEach-Object{$_.Extent.Text})-join"`n"
$verifierStart=@(Get-Assignment $runner verifier)
$verifierLast=@(Get-Assignment $runner verifyOutput)
Require ($verifierStart.Count-eq1-and$verifierLast.Count-eq1) 'Unique real runner verifier invocation required'
$runnerStatements=Get-StatementSlice $verifierStart[0] $verifierLast[0]
Assert-SafeSlice $runnerStatements @('Join-Path','Get-Process') @('$engine')
Assert-SafeVerifierEngine $runnerStatements
$runnerText=($runnerStatements|ForEach-Object{$_.Extent.Text})-join"`n"
$auxGuards=@($runner.EndBlock.Statements|Where-Object{
  $_-is[Management.Automation.Language.IfStatementAst]-and
  @($_.Clauses[0].Item1.FindAll({param($n)$n-is[Management.Automation.Language.VariableExpressionAst]-and$n.VariablePath.UserPath-ceq'AuxReadinessDiagnostics'},$true)).Count-gt0
})
foreach($guard in $auxGuards){Assert-SafeAuxGuard $guard}
$paramNames=@($runner.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})
$guardText=($auxGuards|ForEach-Object{$_.Extent.Text})-join"`n"
$runnerBindingText='[CmdletBinding()]'+"`n"+$runner.ParamBlock.Extent.Text+"`n"+$guardText+"`n"+$runnerText

# Only extracted argument-construction statements execute. Every external/native
# call is either excluded by the AST whitelist or replaced with a local shim.
# No live outer/runner script, serial reader, process enumeration or permit is run.
function Invoke-OuterRoute([string]$RouteMode,[bool]$Aux){
  & {
    $OfflineContractTest=$false;$timedPathEnabled=$true;$TimedPathMode=$RouteMode
    $AuxReadinessDiagnostics=[switch]$Aux;$CaptureSeconds=40;$ReadComparisonMode='None'
    $captureDirectory=Join-Path $OutputRoot 'not-created-capture'
    $OutputDirectory=Join-Path $OutputRoot 'not-created-outer'
    $candidate=[pscustomobject]@{handoff_path='offline-handoff.json';artifact_id='offline-route-only';handoff_sha256=('A'*64)}
    $flashRecordPath='offline-flash.json';$captureTool=Join-Path $repo 'tools/run_r19_timed_path_capture.ps1';$expectedCaptureToolSha256='B'*64
    $script:routeInvocation=$null;$script:routePermit=$null
    function Read-JsonIfPresent {param($Path);[pscustomobject]@{roles=@([pscustomobject]@{role='vehicle';port='FIXTURE_V';pnp_device_id='OFFLINE_V';parent_device_id='OFFLINE_PARENT_V'},[pscustomobject]@{role='ground';port='FIXTURE_G';pnp_device_id='OFFLINE_G';parent_device_id='OFFLINE_PARENT_G'})}}
    function Get-Sha256 {param($Path);return ('C'*64)}
    function Write-DurableJson {param($Path,$Value);$script:routePermit=[pscustomobject]@{path=$Path;value=$Value}}
    function Invoke-ExperimentStep {param($Name,$ScriptPath,$Arguments,$ExpectedSha);$script:routeInvocation=[pscustomobject]@{name=$Name;script_path=$ScriptPath;arguments=@($Arguments);sha=$ExpectedSha};return [pscustomobject]@{exit_code=0}}
    . ([scriptblock]::Create($outerText))
    Require ($null-ne$script:routeInvocation) 'Real outer slice never invoked capture shim'
    return [pscustomobject]@{invocation=$script:routeInvocation;permit=$script:routePermit}
  }
}
function Invoke-RunnerRoute([string]$RouteMode,[bool]$Aux,[object[]]$CaptureArguments=@()){
  & {
    $script:verifierInvocation=$null
    function Get-Process {param($Id);[pscustomobject]@{Path='Invoke-OfflineCandidateVerifier'}}
    function Invoke-OfflineCandidateVerifier {$script:verifierInvocation=@($args);$global:LASTEXITCODE=0;return 'OFFLINE_VERIFIER_ARGV_ONLY'}
    $arguments=@{RepoRoot=$repo;Mode=$RouteMode;ImportOnly=$true}
    if($Aux){$arguments.AuxReadinessDiagnostics=$true}
    if($CaptureArguments.Count){
      # Convert native child argv to a parameter splat using the real runner's
      # parameter AST. A removed/renamed parameter therefore fails this route,
      # rather than being silently discarded by the test's own argument model.
      $arguments=@{}
      for($i=0;$i-lt$CaptureArguments.Count;$i++){
        $name=([string]$CaptureArguments[$i]).TrimStart('-')
        $p=@($runner.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq$name})
        Require ($p.Count-eq1-and-not$arguments.ContainsKey($name)) ('Unknown/duplicate actual capture argument: '+$name)
        if($p[0].StaticType-eq[Management.Automation.SwitchParameter]){$arguments[$name]=$true}
        else{$i++;Require ($i-lt$CaptureArguments.Count) ('Capture argument value missing: '+$name);$arguments[$name]=$CaptureArguments[$i]}
      }
    }
    $handoffPath='offline-route-handoff.json';$errorText=''
    try{& ([scriptblock]::Create($runnerBindingText)) @arguments|Out-Null}catch{$errorText=$_.Exception.Message}
    return [pscustomobject]@{arguments=$script:verifierInvocation;error=$errorText}
  }
}
. (Join-Path $repo 'tools/r19_candidate_artifact_common.ps1')
$modeAssert=@($verifier.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Assert-ModeContract'},$true))
Require ($modeAssert.Count-eq1) 'Real candidate verifier mode assertion required'
function Invoke-RealModeAssertion([object[]]$Arguments,[string]$ExpectedMode,[bool]$ExpectedAux){
  & {
    $TimedPathMode=Token-Value $Arguments '-TimedPathMode'
    $runtimeFailDiagnosticsEnabled=(Count-Token $Arguments '-RuntimeFailDiagnostics')-eq1
    $acceptanceEligible=-not$runtimeFailDiagnosticsEnabled
    $auxReadinessEnabled=(Count-Token $Arguments '-AuxReadinessDiagnostics')-eq1
    $timedPathEnabled=$TimedPathMode-cne'Disabled'
    $timedPathContract=Get-R19TimedPathCandidateContract $repo $TimedPathMode
    $auxReadinessContract=Get-R19AuxReadinessCandidateContract $repo $auxReadinessEnabled
    function Assert-Condition([bool]$Condition,[string]$Message){Require $Condition $Message}
    . ([scriptblock]::Create($modeAssert[0].Extent.Text))
    $record=[ordered]@{runtime_fail_diagnostics_enabled=$true;acceptance_authorized=$false;acceptance_eligible=$false;deployment_authorized=$false;timed_path_diagnostics=(Get-R19TimedPathCandidateContract $repo $ExpectedMode)}
    if($ExpectedAux){$record.aux_readiness_diagnostics=Get-R19AuxReadinessCandidateContract $repo $true}
    Assert-ModeContract ([pscustomobject]$record) 'offline generated argv'
  }
}
Check 'offline-safety-rejects-guard-command-before-execution' {
  $mutation=[Management.Automation.Language.Parser]::ParseInput('if($AuxReadinessDiagnostics-and$Mode-cne''ExplicitHostArm''){Get-PnpDevice;throw ''incompatible mode''}',[ref]$null,[ref]$null)
  $rejected=$false;try{Assert-SafeAuxGuard $mutation.EndBlock.Statements[0]}catch{$rejected=$true}
  Require $rejected 'Guard command safety mutation was accepted'
}
Check 'offline-safety-rejects-guard-native-member-before-execution' {
  $mutation=[Management.Automation.Language.Parser]::ParseInput('if($AuxReadinessDiagnostics-and$Mode-cne''ExplicitHostArm''){[IO.Ports.SerialPort]::GetPortNames();throw ''incompatible mode''}',[ref]$null,[ref]$null)
  $rejected=$false;try{Assert-SafeAuxGuard $mutation.EndBlock.Statements[0]}catch{$rejected=$true}
  Require $rejected 'Guard native member safety mutation was accepted'
}
Check 'offline-safety-rejects-fixed-native-engine-before-execution' {
  $mutation=[Management.Automation.Language.Parser]::ParseInput('$engine=''powershell.exe''',[ref]$null,[ref]$null)
  $rejected=$false;try{Assert-SafeVerifierEngine @($mutation.EndBlock.Statements)}catch{$rejected=$true}
  Require $rejected 'Fixed native engine safety mutation was accepted'
}
Check 'offline-safety-rejects-engine-reassignment-before-execution' {
  $mutation=[Management.Automation.Language.Parser]::ParseInput('$engine=(Get-Process -Id $PID).Path;$engine=''powershell.exe''',[ref]$null,[ref]$null)
  $rejected=$false;try{Assert-SafeVerifierEngine @($mutation.EndBlock.Statements)}catch{$rejected=$true}
  Require $rejected 'Engine reassignment safety mutation was accepted'
}
Check 'runner-declares-explicit-switch' {
  Require ('AuxReadinessDiagnostics'-cin$paramNames) 'Runner does not bind AuxReadinessDiagnostics'
  $parameter=@($runner.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'AuxReadinessDiagnostics'})[0]
  Require ($parameter.StaticType-eq[Management.Automation.SwitchParameter]) 'AUX selection must be a switch, not a coercible string'
}
Check 'runner-rejects-incompatible-mode-before-live-io' {
  Require ($auxGuards.Count-eq1) 'Runner requires one explicit AUX/mode guard'
  Require (@($auxGuards[0].FindAll({param($n)$n-is[Management.Automation.Language.ThrowStatementAst]},$true)).Count-eq1) 'AUX/mode guard must throw'
  $firstProbe=@($runner.EndBlock.Statements|Where-Object{$_.Extent.Text.Contains('Capture output must be a new directory')})
  Require ($firstProbe.Count-eq1-and$auxGuards[0].Extent.EndOffset-lt$firstProbe[0].Extent.StartOffset) 'Mode rejection must precede permit/output/device effects'
  $r=Invoke-RunnerRoute SyncOnly $true
  Require ($r.error-like'*AUX/readiness*ExplicitHostArm*'-and$null-eq$r.arguments) ('AUX+SyncOnly was not rejected before verifier invocation: '+$r.error)
}
foreach($case in @([pscustomobject]@{mode='SyncOnly';aux=$false},[pscustomobject]@{mode='ExplicitHostArm';aux=$false},[pscustomobject]@{mode='ExplicitHostArm';aux=$true})){
  $label=$case.mode+'-aux-'+$case.aux
  Check ('outer-actual-argv-'+$label) {
    $r=Invoke-OuterRoute $case.mode $case.aux;$a=@($r.invocation.arguments)
    $observations.Add([pscustomobject]@{boundary='outer-to-capture';mode=$case.mode;aux=$case.aux;argv=$a})
    Require ((Count-Token $a '-AuxReadinessDiagnostics')-eq$(if($case.aux){1}else{0})) 'Outer lost or silently added AUX selection'
    Require ((Token-Value $a '-Mode')-ceq$case.mode) 'Outer changed timed-path mode'
    Require ((Token-Value $a '-CaptureSeconds')-ceq'40'-and(Count-Token $a '-Execute')-eq1) 'Outer changed bounded capture or execution selection'
    Require ((Token-Value $a '-ExecutionPermitPath')-ceq$r.permit.path-and$r.permit.value.mode-ceq$case.mode) 'Outer permit path/mode differs from capture'
    Require ($r.permit.value.read_comparison_mode-ceq'None'-and(Count-Token $a '-ReadComparisonMode')-eq0) 'Legacy route must remain explicitly non-intervening'
    Require ($r.invocation.name-ceq'capture'-and$r.invocation.script_path-ceq(Join-Path $repo 'tools/run_r19_timed_path_capture.ps1')) 'Outer invoked another acquisition path'
  }
  Check ('capture-actual-verifier-argv-'+$label) {
    $r=Invoke-RunnerRoute $case.mode $case.aux
    Require ([string]::IsNullOrEmpty($r.error)) ('Runner argument route rejected: '+$r.error)
    $a=@($r.arguments);$observations.Add([pscustomobject]@{boundary='capture-to-verifier';mode=$case.mode;aux=$case.aux;argv=$a})
    Require ((Count-Token $a '-AuxReadinessDiagnostics')-eq$(if($case.aux){1}else{0})) 'Capture lost or silently added AUX verifier selection'
    Require ((Token-Value $a '-TimedPathMode')-ceq$case.mode) 'Capture changed verifier mode'
    Require ((Count-Token $a '-RuntimeFailDiagnostics')-eq1) 'Capture removed runtime-fail diagnostic selection'
    Require ((Token-Value $a '-File')-ceq(Join-Path $repo 'tools/verify_r19_candidate_artifact.ps1')) 'Capture bypassed real sealed candidate verifier'
    Invoke-RealModeAssertion $a $case.mode $case.aux
  }
  Check ('whole-actual-argv-route-'+$label) {
    $outerRoute=Invoke-OuterRoute $case.mode $case.aux
    $runnerRoute=Invoke-RunnerRoute $case.mode $case.aux @($outerRoute.invocation.arguments)
    Require ([string]::IsNullOrEmpty($runnerRoute.error)) ('Actual outer argv did not bind through runner: '+$runnerRoute.error)
    $a=@($runnerRoute.arguments)
    Require ((Count-Token $a '-AuxReadinessDiagnostics')-eq$(if($case.aux){1}else{0})) 'Full route silently changed AUX selection'
    Require ((Token-Value $a '-TimedPathMode')-ceq$case.mode) 'Full route silently changed timed mode'
    Invoke-RealModeAssertion $a $case.mode $case.aux
  }
}
Check 'real-verifier-rejects-aux-flag-removal' {
  $r=Invoke-RunnerRoute ExplicitHostArm $true;Require ([string]::IsNullOrEmpty($r.error)) ('Unable to construct AUX verifier argv: '+$r.error)
  $a=@($r.arguments|Where-Object{[string]$_-cne'-AuxReadinessDiagnostics'});$rejected=$false
  try{Invoke-RealModeAssertion $a ExplicitHostArm $true}catch{$rejected=$_.Exception.Message-like'*undeclared AUX readiness diagnostics*'}
  Require $rejected 'Removing propagated AUX flag was not rejected by real verifier mode assertion'
}
Check 'real-verifier-rejects-silent-aux-promotion' {
  $r=Invoke-RunnerRoute ExplicitHostArm $false;Require ([string]::IsNullOrEmpty($r.error)) $r.error
  $a=@($r.arguments)+@('-AuxReadinessDiagnostics');$rejected=$false
  try{Invoke-RealModeAssertion $a ExplicitHostArm $false}catch{$rejected=$_.Exception.Message-like'*AUX readiness mode/ABI/decoder binding mismatch*'}
  Require $rejected 'Adding AUX silently to legacy candidate was not rejected by real verifier mode assertion'
}
Check 'offline-slices-did-not-create-live-output-or-permit' {
  Require (-not(Test-Path -LiteralPath (Join-Path $OutputRoot 'not-created-capture'))-and-not(Test-Path -LiteralPath (Join-Path $OutputRoot 'not-created-outer'))) 'Offline route unexpectedly wrote a capture/permit'
}
$failed=@($checks|Where-Object{-not$_.passed})
$summary=[ordered]@{schema='vc-lora-r19-aux-readiness-capture-routing-offline-v1';result=$(if($failed.Count){'FAIL'}else{'PASS'});powershell=$PSVersionTable.PSVersion.ToString();hardware_interaction=$false;com_open_attempts=0;native_process_calls=0;permit_consumed=$false;passed_count=$checks.Count-$failed.Count;failed_count=$failed.Count;checks=@($checks);observations=@($observations);scope='Actual AST-extracted argument construction and verifier mode assertion; does not claim a full sealed candidate or live communication acceptance.'}
$summary|ConvertTo-Json -Depth 24|Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json') -Encoding UTF8
$summary|ConvertTo-Json -Depth 24
if($failed.Count){exit 1}
