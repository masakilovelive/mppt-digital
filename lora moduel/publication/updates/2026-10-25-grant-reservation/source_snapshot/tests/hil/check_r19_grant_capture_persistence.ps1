[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputRoot='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not$OutputRoot){$OutputRoot=Join-Path $repo ('runs/validation/R19-GRANT-CAPTURE-PERSISTENCE-TEST-001/'+[guid]::NewGuid().ToString('N'))}
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(-not$OutputRoot.StartsWith((Join-Path $repo 'runs/validation/'),[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture output must stay within validation'}
[void][IO.Directory]::CreateDirectory($OutputRoot)
$checks=0
function Check([bool]$Value,[string]$Name){if(-not$Value){throw $Name};$script:checks++}
function Reject([scriptblock]$Action,[string]$Name){$rejected=$false;try{&$Action|Out-Null}catch{$rejected=$true};Check $rejected $Name}
function CaseDirectory([string]$Name){$p=Join-Path $OutputRoot $Name;[void][IO.Directory]::CreateDirectory($p);return $p}
function Parse([string]$Path){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);Check (@($errors).Count-eq0) "Parse $Path";return $ast}
$capturePath=Join-Path $repo 'tools/run_r19_timed_path_capture.ps1'
$captureSource=[IO.File]::ReadAllText($capturePath);$captureAst=Parse $capturePath
$names=@('Write-R19TimedPathJson','Write-R19TimedPathRaw','Get-R19TimedPathRawRole','Get-R19TimedPathRoleMetadata','Save-R19TimedPathCaptureEvidence')
foreach($node in $captureAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-cin$names}){. ([scriptblock]::Create($node.Extent.Text))}
function Get-R19AcquisitionSha256([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','')}finally{$sha.Dispose()}}
# Real persistence functions only; no CLI, authorization, reader or device owner.
foreach($name in @('Get-CimInstance','Get-PnpDevice','Get-PnpDeviceProperty','Get-Process','Start-Process','Invoke-Expression')){Set-Item -Path ('function:script:'+$name) -Value {throw 'Forbidden hardware/process operation in offline fixture'}}
function NewState([string]$Role){
  [byte[]]$bytes=if($Role-ceq'ground'){@(4,5,6)}else{@(1,2,3)}
  [pscustomobject]@{spec=[pscustomobject]@{role=$Role;port=($Role+'-fixture');baud=57600};reader_id=($Role+'-fixture');nonce='1';opened=$true;joined=$true;cleanup_close_fallback=$false;open_before_ticks='1';open_after_ticks='2';read_started_ticks='3';snapshot=[pscustomobject]@{ByteCount=3;Blocks=@([pscustomobject]@{Offset=0;Count=3;BeginTicks=200L;EndTicks=201L});Overflow=$false;Failure='';LastReadEndTicks=201L};raw=$bytes;workflow=$null;workflow_failure='';writes=[Collections.Generic.List[object]]::new();observations=[Collections.Generic.List[object]]::new();product_observations=[Collections.Generic.List[object]]::new()}
}
function NewContext {
  [pscustomobject]@{candidate_id='GRANT-PERSISTENCE-SYNTHETIC-NOT-HARDWARE';mode='ExplicitHostArm';capture_seconds=40;started_utc='2026-10-24T00:00:00Z';clock_domain_id='fixture-clock';frequency='1000';measurement_start_ticks='0';measurement_end_ticks='40000';cleanup_proven=$true;hardware_interaction=$false;serial_write_calls=0;failure='';identity_evidence=@();pinned_inputs=@();handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);repo_root=$repo}
}
function SaveFixture([string]$Name,[object]$Context){
  $dir=CaseDirectory $Name;$saved=Save-R19TimedPathCaptureEvidence -States @((NewState vehicle),(NewState ground)) -OutputDirectory $dir -Context $Context
  $disk=Get-Content -LiteralPath (Join-Path $dir 'summary.json') -Raw|ConvertFrom-Json
  foreach($role in @('vehicle','ground')){$path=Join-Path $dir ($role+'.raw.bin');Check ((Get-Item -LiteralPath $path).Length-eq3) 'Both raw streams survive metadata processing';$row=@($disk.roles|Where-Object{$_.role-ceq$role})[0];Check ($row.raw_saved-and$row.raw_sha256-ceq(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) 'Raw identity remains durable'}
  Check (-not$disk.acceptance_eligible-and-not$disk.deployment_authorized-and-not$disk.root_cause_proven) 'Persistence cannot grant product authority'
  return [pscustomobject]@{saved=$saved;disk=$disk;directory=$dir}
}
foreach($value in @($true,$false)){
  $context=NewContext;$context|Add-Member NoteProperty grant_diagnostics_enabled $value
  $case=SaveFixture ('boolean-'+$value) $context
  foreach($obj in @($case.saved,$case.disk)){Check ($null-ne$obj.PSObject.Properties['grant_diagnostics_enabled']-and$obj.grant_diagnostics_enabled-is[bool]-and$obj.grant_diagnostics_enabled-eq$value) 'Actual Save return and disk must retain exact Grant Boolean';Check ($obj.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY') 'Valid Boolean capture remains observations-only'}
}
$legacy=SaveFixture 'legacy-omitted' (NewContext)
foreach($obj in @($legacy.saved,$legacy.disk)){Check ($null-eq$obj.PSObject.Properties['grant_diagnostics_enabled']) 'Legacy context omission remains omitted'}
foreach($badCase in @(@{name='string';value='true'},@{name='integer';value=1},@{name='null';value=$null},@{name='array';value=@($true)},@{name='case';value=$true;property='Grant_Diagnostics_Enabled'})){
  $context=NewContext;$property=if($badCase.ContainsKey('property')){$badCase.property}else{'grant_diagnostics_enabled'};$context|Add-Member NoteProperty $property $badCase.value
  $case=SaveFixture ('invalid-'+$badCase.name) $context
  foreach($obj in @($case.saved,$case.disk)){Check ($obj.result-ceq'INVALID_CAPTURE'-and$obj.failure-match'Grant'-and@($obj.preservation_errors).Count-gt0) 'Malformed Grant metadata fails closed after raw preservation';Check ($null-eq$obj.PSObject.Properties['grant_diagnostics_enabled']) 'Malformed flag cannot be published as a valid Boolean'}
}
foreach($badCase in @(@{name='presence-type';value='true';flag=$true},@{name='presence-case';value=$true;flag=$true;property='Grant_Diagnostics_Selection_Present'},@{name='presence-contradiction';value=$false;flag=$true},@{name='presence-without-flag';value=$true;omit_flag=$true})){
  $context=NewContext;$property=if($badCase.ContainsKey('property')){$badCase.property}else{'grant_diagnostics_selection_present'};$context|Add-Member NoteProperty $property $badCase.value
  if(-not$badCase.ContainsKey('omit_flag')){$context|Add-Member NoteProperty grant_diagnostics_enabled $badCase.flag}
  $case=SaveFixture ('invalid-'+$badCase.name) $context
  foreach($obj in @($case.saved,$case.disk)){Check ($obj.result-ceq'INVALID_CAPTURE'-and$obj.failure-match'Grant'-and$null-eq$obj.PSObject.Properties['grant_diagnostics_enabled']) 'Malformed or contradictory bound presence fails closed without a valid mode claim'}
}
# Replay the actual parameter/import prefix and actual CLI Save assignment.
# The prefix ends at ImportOnly, before identity/permit/port execution.
$boundary=$captureSource.IndexOf('if($ImportOnly){',[StringComparison]::Ordinal)
Check ($boundary-gt0) 'Actual definitions-only boundary found'
$prefix=$captureSource.Substring(0,$boundary).Replace('$PSScriptRoot',("'"+(Join-Path $repo 'tools').Replace("'","''")+"'"))
$script:prefixProbe=[scriptblock]::Create($prefix+[Environment]::NewLine+'[pscustomobject]@{present=($PSBoundParameters.Keys-ccontains"GrantDiagnostics");bound=[bool]$PSBoundParameters["GrantDiagnostics"];value=[bool]$GrantDiagnostics}')
$saveNodes=@($captureAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left.Extent.Text-ceq'$summary'-and$_.Right.Extent.Text.StartsWith('Save-R19TimedPathCaptureEvidence ')})
Check ($saveNodes.Count-eq1) 'Actual CLI persistence assignment found once'
$flag=@($captureAst.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantDiagnostics'})[0]
$script:saveAssignment=[scriptblock]::Create('[CmdletBinding()]'+[Environment]::NewLine+'param('+$flag.Extent.Text+')'+[Environment]::NewLine+$saveNodes[0].Extent.Text)
$parentAst=Parse (Join-Path $repo 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1')
$modeBranches=@($parentAst.FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Clauses[0].Item1.Extent.Text-ceq'$grantSelection'},$true))
$modeBranch=@($modeBranches|Where-Object{$_.Extent.Text.Contains('Capture Grant mode not explicitly proven')})
Check ($modeBranch.Count-eq1) 'Actual parent Grant mode assertion found once'
$script:parentModeAssertion=[scriptblock]::Create($modeBranch[0].Extent.Text)
function Assert-Condition([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function InlineCase([string]$Name,[hashtable]$Bindings){
  $OutputDirectory=CaseDirectory $Name;$states=[Collections.Generic.List[object]]::new();$states.Add((NewState vehicle));$states.Add((NewState ground))
  $plan=[pscustomobject]@{candidate_id='GRANT-CLI-SYNTHETIC-NOT-HARDWARE'};$Mode='ExplicitHostArm';$CaptureSeconds=40;$started='2026-10-24T00:00:00Z';$domain='fixture-clock';$frequency='1000';$measurementStart='0';$measurementEnd='40000';$cleanupProven=$true;$hardware=$false;$serialWrites=0;$failure=''
  $identityEvidence=[Collections.Generic.List[object]]::new();$pinInputs=[Collections.Generic.List[object]]::new();$handoffSha='A'*64;$flashSha='B'*64;$readComparison=$null
  . $script:saveAssignment @Bindings
  [pscustomobject]@{saved=$summary;disk=(Get-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Raw|ConvertFrom-Json)}
}
foreach($selection in @(@{name='default';specified=$false;enabled=$false},@{name='explicit-false';specified=$true;enabled=$false},@{name='enabled';specified=$true;enabled=$true})){
  $bindings=@{};if($selection.specified){$bindings.GrantDiagnostics=[bool]$selection.enabled}
  $probeArgs=@{ImportOnly=$true};foreach($key in $bindings.Keys){$probeArgs[$key]=$bindings[$key]}
  if($selection.enabled){$probeArgs.Mode='ExplicitHostArm';$probeArgs.AuxReadinessDiagnostics=$true;$probeArgs.DiagnosticUsbFailureDiagnostics=$true}
  $probe=& $script:prefixProbe @probeArgs
  Check ($probe.present-eq$selection.specified-and$probe.bound-eq$selection.enabled-and$probe.value-eq$selection.enabled) 'Real imports preserve Grant CLI binding and value'
  $case=InlineCase ('cli-'+$selection.name) $bindings
  foreach($obj in @($case.saved,$case.disk)){
    if($selection.specified){Check ($null-ne$obj.PSObject.Properties['grant_diagnostics_enabled']-and$obj.grant_diagnostics_enabled-is[bool]-and$obj.grant_diagnostics_enabled-eq$selection.enabled) 'Actual CLI to real Save round-trip retains explicit selection'}else{Check ($null-eq$obj.PSObject.Properties['grant_diagnostics_enabled']) 'Actual legacy CLI keeps Grant property absent'}
    $summary=$obj;$grantSelection=[bool]$selection.enabled;. $script:parentModeAssertion;Check $true 'Actual parent Grant assertion accepts matching saved selection'
    if($selection.enabled){$grantSelection=$false;Reject {. $script:parentModeAssertion} 'Parent still rejects undeclared enabled capture'}
  }
}
Write-Output "check_r19_grant_capture_persistence PASS checks=$checks hardware_interaction=false output=$OutputRoot"
