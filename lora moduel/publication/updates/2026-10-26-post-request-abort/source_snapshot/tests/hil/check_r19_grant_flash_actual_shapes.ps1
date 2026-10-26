[CmdletBinding()]
param([string]$RepoRoot='', [string]$LatestPath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
if([string]::IsNullOrWhiteSpace($LatestPath)){$LatestPath=Join-Path $repo 'runs/candidates/R19-GRANT-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json'}
$checks=0
function Check([bool]$Value,[string]$Name){if(-not$Value){throw $Name};$script:checks++}
function Reject([scriptblock]$Action,[string]$Name){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Check $failed $Name}
function Clone([object]$Value){$Value|ConvertTo-Json -Depth 40 -Compress|ConvertFrom-Json}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'tools/invoke_r19_candidate_app_flash_hil.ps1'),[ref]$tokens,[ref]$errors)
Check (@($errors).Count-eq0) 'Flash parser must succeed'
foreach($node in $ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-in@('Assert-Condition','Get-Sha256','Assert-CandidateModeRecord')}){. ([scriptblock]::Create($node.Extent.Text))}
$runtimeFailDiagnosticsEnabled=$true;$timedPathEnabled=$true;$TimedPathMode='ExplicitHostArm'
$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$true;$grantDiagnosticsEnabled=$true;$acceptanceEligible=$false
$latest=Get-Content -LiteralPath $LatestPath -Raw|ConvertFrom-Json
Check ($latest.schema-ceq'vc-lora-r19-candidate-artifact-latest-v1'-and$null-eq$latest.PSObject.Properties['reader_schema']) 'Regression input is the actual v1 pointer without a top-level reader field'
Check ($latest.grant_diagnostics.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v9') 'Actual pointer binds Grant decoder v9 inside its strict contract'
Assert-CandidateModeRecord $latest 'Actual sealed latest pointer'
Check $true 'Actual sealed latest pointer shape accepted without inventing a top-level field'
$documents=@(foreach($kind in @('handoff','candidate_manifest','final_seal')){$record=$latest.$kind;Check ((Get-Sha256 (Join-Path $repo $record.path))-ceq$record.sha256) "Actual $kind is SHA-bound by latest";Get-Content -LiteralPath (Join-Path $repo $record.path) -Raw|ConvertFrom-Json})
foreach($doc in $documents){
  Check ($doc.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v9') 'Detailed sealed document has required top-level v9'
  Assert-CandidateModeRecord $doc 'Actual sealed detailed document';Check $true 'Actual sealed detailed document accepted'
  $bad=Clone $doc;$bad.PSObject.Properties.Remove('reader_schema');Reject {Assert-CandidateModeRecord $bad 'missing detailed reader'} 'Detailed document must not inherit pointer omission exception'
  $bad=Clone $doc;$bad.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8';Reject {Assert-CandidateModeRecord $bad 'downgraded detailed reader'} 'Detailed reader downgrade rejected'
  $bad=Clone $doc;$bad.reader_schema=9;Reject {Assert-CandidateModeRecord $bad 'numeric detailed reader'} 'Detailed reader must remain a string'
  $bad=Clone $doc;$bad.reader_schema=$bad.reader_schema.ToUpperInvariant();Reject {Assert-CandidateModeRecord $bad 'case-changed detailed reader'} 'Detailed reader case mismatch rejected'
}
foreach($schema in @('unknown','VC-LORA-R19-CANDIDATE-ARTIFACT-LATEST-V1')){$bad=Clone $latest;$bad.schema=$schema;Reject {Assert-CandidateModeRecord $bad 'unknown pointer shape'} 'Only exact versioned latest schema can omit top-level reader'}
$bad=Clone $latest;$bad|Add-Member NoteProperty reader_schema 'vc-lora-r19-runtime-stage-jtag-read-v9';Reject {Assert-CandidateModeRecord $bad 'invented pointer top-level reader'} 'Even a consistent top-level reader is not part of the canonical latest-v1 shape'
$bad=Clone $documents[0];$bad.PSObject.Properties.Remove('schema');Reject {Assert-CandidateModeRecord $bad 'schema absent'} 'A Grant detailed document cannot omit its versioned schema'
$bad=Clone $documents[0];$bad.schema='unknown';Reject {Assert-CandidateModeRecord $bad 'unknown schema with otherwise-valid reader'} 'Valid nested and top-level readers do not admit an unknown document kind'
foreach($value in @('vc-lora-r19-runtime-stage-jtag-read-v8',9)){$bad=Clone $latest;$bad|Add-Member NoteProperty reader_schema $value;Reject {Assert-CandidateModeRecord $bad 'contradictory pointer reader'} 'Pointer cannot contradict nested v9 contract'}
$bad=Clone $latest;$bad.grant_diagnostics.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8';Reject {Assert-CandidateModeRecord $bad 'nested reader downgrade'} 'Pointer nested reader stays exact v9'
$bad=Clone $latest;$bad.grant_diagnostics.PSObject.Properties.Remove('reader_schema');Reject {Assert-CandidateModeRecord $bad 'missing nested reader'} 'Pointer missing nested reader rejected'
$bad=Clone $latest;$bad.grant_diagnostics.record.size_bytes='1024';Reject {Assert-CandidateModeRecord $bad 'string size'} 'Grant size cannot become a numeric string'
$bad=Clone $latest;$bad.grant_diagnostics.record.size_bytes=1024.5;Reject {Assert-CandidateModeRecord $bad 'fractional size'} 'Grant size cannot become fractional'
$bad=Clone $latest;$bad.grant_diagnostics.enabled='true';Reject {Assert-CandidateModeRecord $bad 'string enable'} 'Grant enable must remain a Boolean'
$bad=Clone $latest;$bad.grant_diagnostics.decoder.sha256=('0'*64);Reject {Assert-CandidateModeRecord $bad 'decoder mismatch'} 'Grant decoder SHA remains strictly bound'
$bad=Clone $latest;$bad.grant_diagnostics|Add-Member NoteProperty unreviewed $true;Reject {Assert-CandidateModeRecord $bad 'extra contract property'} 'Pointer exception must not weaken closed Grant contract'
$grantDiagnosticsEnabled=$false
Reject {Assert-CandidateModeRecord $latest 'undeclared Grant mode'} 'Actual Grant pointer cannot escalate a default-off invocation'
Write-Output "check_r19_grant_flash_actual_shapes PASS checks=$checks hardware_interaction=false"
