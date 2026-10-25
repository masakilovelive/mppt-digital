[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$TrialRoot,[Parameter(Mandatory)][string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$utf8=[Text.UTF8Encoding]::new($false)
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path;$TrialRoot=(Resolve-Path -LiteralPath $TrialRoot).Path;$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(-not$OutputRoot.StartsWith((Join-Path $repo 'runs/validation/'),[StringComparison]::OrdinalIgnoreCase)-or(Test-Path -LiteralPath $OutputRoot)){throw 'Counterfactual fixture requires a fresh validation directory'}
[void][IO.Directory]::CreateDirectory($OutputRoot)
$checks=0
function Check([bool]$Value,[string]$Name){if(-not$Value){throw $Name};$script:checks++}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
foreach($name in @('Get-CimInstance','Get-PnpDevice','Get-PnpDeviceProperty','Get-Process','Start-Process','Invoke-Expression')){Set-Item -Path ('function:script:'+$name) -Value {throw 'Forbidden hardware/process operation in counterfactual fixture'}}
$originalSummaryPath=Join-Path $TrialRoot 'capture/summary.json';$originalSummarySha=Hash $originalSummaryPath
$actual=Get-Content -LiteralPath $originalSummaryPath -Raw|ConvertFrom-Json;$outer=Get-Content -LiteralPath (Join-Path $TrialRoot 'summary.json') -Raw|ConvertFrom-Json
$permit=Get-Content -LiteralPath (Join-Path $TrialRoot 'execution-permit.json') -Raw|ConvertFrom-Json
Check ($permit.grant_diagnostics-is[bool]-and$permit.grant_diagnostics-and$permit.param_list_diagnostics-is[bool]-and$permit.param_list_diagnostics) 'Original spent permit selected exact Grant and parameter modes'
Check (Test-Path -LiteralPath (Join-Path $TrialRoot 'execution-permit.json.consumed')) 'Historical one-time permit was already consumed'
Check ($null-eq$actual.PSObject.Properties['grant_diagnostics_enabled']) 'Actual capture has the diagnosed persistence omission'
$installText=[IO.File]::ReadAllText((Join-Path $TrialRoot 'install.stdout.log'));$match=[regex]::Match($installText,'record=(?<path>[^\r\n]+?) seal_sha256=')
Check $match.Success 'Original installation record path is explicit in saved output'
$flashRecordPath=$match.Groups['path'].Value
Check ((Hash $flashRecordPath)-ceq$permit.flash_evidence_sha256-and$actual.flash_evidence_sha256-ceq$permit.flash_evidence_sha256) 'Original saved flash provenance matches spent permit and capture'
. (Join-Path $repo 'tools/r19_timed_path_outer.ps1')
$parentPath=Join-Path $repo 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($parentPath,[ref]$tokens,[ref]$errors)
Check (@($errors).Count-eq0) 'Original parent source parses'
foreach($node in $ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-cin@('Assert-Condition','Read-JsonIfPresent','Get-Sha256','Get-CaptureDisposition')}){. ([scriptblock]::Create($node.Extent.Text))}
$timedPathEnabled=$true;$ReadComparisonMode='None';$ParamListDiagnostics=$permit.param_list_diagnostics;$GrantDiagnostics=$permit.grant_diagnostics;$TimedPathMode=$permit.mode;$candidate=$outer.candidate
$step=@($outer.steps|Where-Object{$_.name-ceq'capture'})[0]
$results=[Collections.Generic.List[object]]::new()
foreach($variant in @('baseline-historical-missing-flag','hypothetical-future-persistence-with-only-flag')){
  $OutputDirectory=Join-Path $OutputRoot $variant;$captureDirectory=Join-Path $OutputDirectory 'capture';[void][IO.Directory]::CreateDirectory($captureDirectory)
  # Copy only spent evidence. No executable permit or live tool is created/run.
  Copy-Item -LiteralPath (Join-Path $TrialRoot 'execution-permit.json.consumed') -Destination (Join-Path $OutputDirectory 'execution-permit.json.consumed')
  foreach($role in @('vehicle','ground')){Copy-Item -LiteralPath (Join-Path $TrialRoot ('capture/'+$role+'.raw.bin')) -Destination (Join-Path $captureDirectory ($role+'.raw.bin'))}
  if($variant-ceq'baseline-historical-missing-flag'){Copy-Item -LiteralPath $originalSummaryPath -Destination (Join-Path $captureDirectory 'summary.json')}else{
    $hypothetical=Get-Content -LiteralPath $originalSummaryPath -Raw|ConvertFrom-Json
    $hypothetical|Add-Member NoteProperty grant_diagnostics_enabled $permit.grant_diagnostics
    [IO.File]::WriteAllText((Join-Path $captureDirectory 'summary.json'),($hypothetical|ConvertTo-Json -Depth 70),[Text.UTF8Encoding]::new($false))
    $withoutFlag=$hypothetical|ConvertTo-Json -Depth 70|ConvertFrom-Json;$withoutFlag.PSObject.Properties.Remove('grant_diagnostics_enabled')
    Check (($withoutFlag|ConvertTo-Json -Depth 70 -Compress)-ceq($actual|ConvertTo-Json -Depth 70 -Compress)) 'Counterfactual changes only the missing Boolean in logical JSON'
  }
  $result=Get-CaptureDisposition -Step $step
  if($variant-ceq'baseline-historical-missing-flag'){Check (-not$result.acceptable-and$result.rejection_reasons-ccontains'Capture Grant mode not explicitly proven') 'Full original parent reproduces actual rejection'}else{Check ($result.acceptable-and$result.evidence_contract_proven-and@($result.rejection_reasons).Count-eq0) 'Full original parent finds no adjacent evidence/provenance/raw/permit gate mismatch after hypothetical persistence correction'}
  $results.Add([pscustomobject]@{variant=$variant;classification='OFFLINE_COUNTERFACTUAL_NOT_HISTORICAL_RECLASSIFICATION';disposition=$result})
}
Check ((Hash $originalSummaryPath)-ceq$originalSummarySha) 'Historical capture bytes were not changed'
$report=[pscustomobject]@{schema='vc-lora-r19-grant-capture-parent-counterfactual-v1';status='PASS_OFFLINE_COUNTERFACTUAL_ONLY';checks=$checks;hardware_interaction=$false;historical_trial_reclassified=$false;jtag_authorization_or_operation_performed=$false;historical_summary_sha256=$originalSummarySha;parent_source_sha256=(Hash $parentPath);results=$results;limitations=@('This is not a successful historical JTAG/readiness decision. Actual trial remains failed.','Only fresh future evidence can prove Grant owner/coordinator failure states.','Spent permit evidence was copied only into an offline fixture; no authority was created or reused.')}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'summary.json'),($report|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
Write-Output "check_r19_grant_capture_actual_parent_replay PASS checks=$checks hardware_interaction=false historical_reclassification=false output=$OutputRoot"
