param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),[string]$OutputDirectory='',[string]$RunnerFixturePath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:checks=0
function Check([bool]$Condition,[string]$Name){if(-not$Condition){throw "FAIL $Name"};$script:checks++}
function Get-R19AcquisitionSha256([byte[]]$Bytes){$hash=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','')}finally{$hash.Dispose()}}
function Write-R19TimedPathJson([string]$Path,[object]$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 70),[Text.UTF8Encoding]::new($false))}
# No production runner is dot-sourced or executed. Only the allow-listed final
# persistence AST below can execute; every hardware/process command is forbidden.
foreach($commandName in @('Get-CimInstance','Get-PnpDeviceProperty','Get-PnpDevice','Get-Process','Start-Process','Add-Type','Invoke-Expression','Invoke-Command')){
  Set-Item -Path ('function:script:'+ $commandName) -Value {throw 'FORBIDDEN persistence fixture hardware/process call'}
}
if([string]::IsNullOrWhiteSpace($OutputDirectory)){$OutputDirectory=Join-Path $RepoRoot ('runs/validation/R19-TIMED-PATH-CAPTURE-PERSISTENCE-TEST-001/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+[Guid]::NewGuid().ToString('N'))}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$validationRoot=[IO.Path]::GetFullPath((Join-Path $RepoRoot 'runs/validation/'))
Check ($OutputDirectory.StartsWith($validationRoot,[StringComparison]::OrdinalIgnoreCase)) 'fixture IO confined to validation root'
Check (-not[IO.Directory]::Exists($OutputDirectory)) 'new fixture directory required'
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$script:fixtureRoot=$OutputDirectory

# Compile only the real immutable snapshot metadata declarations, never the
# ContinuousReader implementation, SerialPort source, worker or native IO owner.
$continuousSource=[IO.File]::ReadAllText((Join-Path $RepoRoot 'tools/r19_continuous_reader.cs'))
$metadataEnd=$continuousSource.IndexOf('    public sealed class ContinuousReader {',[StringComparison]::Ordinal)
Check ($metadataEnd-gt0) 'real C# snapshot metadata located'
$metadataBegin=$continuousSource.IndexOf('namespace VcLora.R19 {',[StringComparison]::Ordinal)
$metadataSource=$continuousSource.Substring($metadataBegin,$metadataEnd-$metadataBegin)+[Environment]::NewLine+'}'
Check (-not($metadataSource-match'SerialPort|Thread|DllImport|Process|IStartupReadSource')) 'metadata-only C# has no hardware/process API'
Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $metadataSource
Microsoft.PowerShell.Utility\Add-Type -TypeDefinition 'namespace R19PersistenceFixture { public sealed class BadText { public override string ToString() { throw new System.InvalidOperationException("FIXTURE_TEXT_CONVERSION_FAILURE"); } } }'
function New-ReadBlock([int]$Offset,[int]$Count,[long]$Begin,[long]$End){
  $constructor=[VcLora.R19.ContinuousReadBlock].GetConstructors([Reflection.BindingFlags]'Instance,NonPublic')[0]
  $arguments=[object[]]@($Offset,$Count,8192,0,[long]1,$Begin,$End,0,0,'STARTUP','STARTUP',$null)
  $constructor.Invoke($arguments)
}
function New-CaptureState([string]$Role,[byte[]]$Bytes){
  $snapshot=[VcLora.R19.ContinuousSnapshot]::new();$snapshot.Armed=$true;$snapshot.Stopped=$true;$snapshot.Closed=$true;$snapshot.ByteCount=$Bytes.Length;$snapshot.Failure='';$snapshot.CleanupFailure=''
  if($Bytes.Length-gt0){$snapshot.Blocks=[VcLora.R19.ContinuousReadBlock[]]@((New-ReadBlock 0 2 100 110),(New-ReadBlock 2 ($Bytes.Length-2) 120 140))}else{$snapshot.Blocks=[VcLora.R19.ContinuousReadBlock[]]@()}
  $snapshot.Phases=[VcLora.R19.ContinuousPhase[]]@()
  [pscustomobject]@{spec=[pscustomobject]@{role=$Role;port=$(if($Role-ceq'vehicle'){'COM3'}else{'COM6'});baud=$(if($Role-ceq'vehicle'){115200}else{57600})};reader_id=($Role+'-reader');nonce='123456789';open_before_ticks='1';open_after_ticks='2';read_started_ticks='3';opened=$true;joined=$true;cleanup_close_fallback=$false;snapshot=$snapshot;raw=$Bytes;workflow=$null;workflow_failure='';writes=[Collections.Generic.List[object]]::new();observations=[Collections.Generic.List[object]]::new();product_observations=[Collections.Generic.List[object]]::new()}
}
function Get-ValidatedPersistenceTail([string]$Path){
  $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$parseErrors)
  Check ($parseErrors.Count-eq0) 'runner parses'
  $statements=@($ast.EndBlock.Statements);$start=-1;$stop=-1
  for($index=0;$index-lt$statements.Count;$index++){
    if($statements[$index].Extent.Text.StartsWith('$roleResults=')){$start=$index}
    if($start-ge0-and$statements[$index].Extent.Text.StartsWith('Write-R19TimedPathJson (Join-Path $OutputDirectory')){$stop=$index;break}
  }
  Check ($start-ge0-and$stop-ge$start) 'actual persistence AST tail found'
  $text=($statements[$start..$stop]|ForEach-Object{$_.Extent.Text})-join[Environment]::NewLine
  $tailTokens=$null;$tailErrors=$null;$tailAst=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tailTokens,[ref]$tailErrors)
  Check ($tailErrors.Count-eq0) 'persistence AST parses independently'
  $commands=@('Join-Path','Get-R19AcquisitionSha256','Get-FileHash','Write-R19TimedPathJson')
  foreach($command in @($tailAst.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]},$true))){Check ($command.GetCommandName()-cin$commands) ('AST allow-listed command '+$command.GetCommandName())}
  $methods=@('new','WriteAllBytes','Add','ToArray','ToBase64String','ToString','IsNullOrEmpty')
  foreach($method in @($tailAst.FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true))){Check ($method.Member.Extent.Text-cin$methods) ('AST allow-listed member '+$method.Member.Extent.Text)}
  foreach($typeNode in @($tailAst.FindAll({param($node)$node-is[Management.Automation.Language.TypeExpressionAst]},$true))){Check ($typeNode.TypeName.FullName-cin@('Collections.Generic.List[object]','IO.File','Convert','string','DateTime')) ('AST allow-listed static type '+$typeNode.TypeName.FullName)}
  [scriptblock]::Create($text)
}
$runnerPath=Join-Path $RepoRoot 'tools/run_r19_timed_path_capture.ps1'
if($RunnerFixturePath){
  $runnerPath=[IO.Path]::GetFullPath($RunnerFixturePath)
  Check ($runnerPath.StartsWith($validationRoot,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($runnerPath)-ceq'run_r19_timed_path_capture.ps1') 'legacy replay fixture confined to saved validation runner'
}
$runnerSource=[IO.File]::ReadAllText($runnerPath)
if(-not$runnerSource.Contains('function Save-R19TimedPathCaptureEvidence')){
  # Retained RED path: execute the complete original production persistence tail,
  # not a substitute of the failing foreach. This path is never a hardware run.
  $tail=Get-ValidatedPersistenceTail $runnerPath
  $caseDirectory=Join-Path $OutputDirectory 'typed-permit-local';[void][IO.Directory]::CreateDirectory($caseDirectory)
  $fixtureFailure=''
  try{
    & {
      param($PersistenceTail,$Directory)
      [byte[]]$b=[Text.Encoding]::UTF8.GetBytes('fixture-candidate ExplicitHostArm')
      $OutputDirectory=$Directory;$states=[Collections.Generic.List[object]]::new()
      $states.Add((New-CaptureState 'vehicle' ([byte[]]@(1,2,3,4,5))))
      $states.Add((New-CaptureState 'ground' ([byte[]]@(253,9,8,7,6,5))))
      $pinInputs=[Collections.Generic.List[object]]::new();$identityEvidence=[Collections.Generic.List[object]]::new()
      $domain='fixture-domain';$frequency='10000000';$plan=[pscustomobject]@{candidate_id='fixture-candidate'};$Mode='ExplicitHostArm';$CaptureSeconds=40;$started='2026-10-22T00:00:00Z';$measurementStart='10';$measurementEnd='400000010';$cleanupProven=$true;$hardware=$false;$serialWrites=0;$failure='';$handoffSha='A'*64;$flashSha='B'*64;$repo=$RepoRoot
      . $PersistenceTail
    } $tail $caseDirectory
  }catch{$fixtureFailure=$_.Exception.Message}
  [IO.File]::WriteAllText((Join-Path $OutputDirectory 'observed_exception.txt'),$fixtureFailure,[Text.UTF8Encoding]::new($false))
  Write-R19TimedPathJson (Join-Path $OutputDirectory 'red_reproduction.json') ([pscustomobject]@{schema='vc-lora-r19-timed-path-persistence-regression-v1';result='RED';runner_path=$runnerPath;runner_sha256=(Get-R19AcquisitionSha256 ([IO.File]::ReadAllBytes($runnerPath)));powershell_version=[string]$PSVersionTable.PSVersion;exception=$fixtureFailure;hardware_interaction=$false;expected_failure_reproduced=($fixtureFailure-match'ContinuousReadBlock'-and$fixtureFailure-match'Byte\[\]');checks=$script:checks})
  Check ([string]::IsNullOrEmpty($fixtureFailure)) ('actual capture persistence must tolerate typed permit local; observed: '+$fixtureFailure)
  throw 'FAIL hardened Save-R19TimedPathCaptureEvidence API missing'
}

# Definitions-only extraction is deliberately separate from the entrypoint's
# parameter binding/import chain, authorization, COM, and permit consumption.
$parseTokens=$null;$parseErrors=$null;$runnerAst=[Management.Automation.Language.Parser]::ParseInput($runnerSource,[ref]$parseTokens,[ref]$parseErrors)
Check ($parseErrors.Count-eq0) 'fixed runner AST parses'
$persistenceNames=@('Write-R19TimedPathJson','Write-R19TimedPathRaw','Get-R19TimedPathRawRole','Get-R19TimedPathRoleMetadata','Save-R19TimedPathCaptureEvidence')
$definitions=@($runnerAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-cin$persistenceNames})
foreach($name in $persistenceNames){Check (@($definitions|Where-Object{$_.Name-ceq$name}).Count-eq1) ('required persistence-only definition '+$name)}
Check ($definitions.Count-eq$persistenceNames.Count) 'only the five persistence dependencies can be imported'
Check (@($definitions|Where-Object{$_.Name-clike'Get-R19ReadComparison*'-or$_.Name-ceq'Assert-R19TimedPathLiveIdentity'}).Count-eq0) 'unrelated comparison and live-identity definitions remain excluded'
Check (@($definitions|Where-Object{$_.Name-ceq'Save-R19TimedPathCaptureEvidence'}).Count-eq1) 'single persistence entry definition'
$definitionText=($definitions|ForEach-Object{$_.Extent.Text})-join[Environment]::NewLine
$safeCommands=@('Join-Path','ConvertTo-Json','ConvertFrom-Json','Get-FileHash','Get-R19AcquisitionSha256','Write-R19TimedPathJson','ForEach-Object','Where-Object','Sort-Object','Select-Object','Out-Null','Assert-R19Acquisition','Assert-R19GrantReservationCandidateContract','Assert-R19GrantReservationStopCandidateContract','Assert-R19GrantAgreementCaptureContract','Assert-R19GrantReservationFatalCaptureContract','Test-Path','Add-Member')+@($definitions|ForEach-Object{$_.Name})
foreach($definition in $definitions){
  foreach($command in @($definition.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]},$true))){Check ($command.GetCommandName()-cin$safeCommands) ('definition allow-listed command '+$command.GetCommandName())}
  foreach($member in @($definition.FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true))){
    Check ($member.Member.Extent.Text-cin@('Add','Dispose','Exists','Flush','GetBytes','IsNullOrEmpty','new','ReadAllBytes','ToArray','ToBase64String','ToString','Write')) ('definition allow-listed member '+$member.Member.Extent.Text)
    if($member.Member.Extent.Text-ceq'Write'){Check ($member.Expression.Extent.Text-cin@('$jsonStream','$rawStream')) 'Write receiver limited to evidence FileStreams'}
  }
  foreach($typeNode in @($definition.FindAll({param($node)$node-is[Management.Automation.Language.TypeExpressionAst]},$true))){Check ($typeNode.TypeName.FullName-cin@('byte[]','Collections.Generic.HashSet[string]','Collections.Generic.List[object]','Collections.Generic.List[string]','Convert','DateTime','IO.Directory','IO.File','IO.FileAccess','IO.FileMode','IO.FileShare','IO.FileStream','string','Text.UTF8Encoding','bool')) ('definition allow-listed static type '+$typeNode.TypeName.FullName)}
}
. ([scriptblock]::Create($definitionText))
# Close the new pure validator dependencies with real, independently checked
# definitions. Never dot-source the outer/runner CLI or replace a validator with
# Get-Command presence checks or a stub. Existing five persistence ASTs above
# retain their original command/member/type restrictions.
function Get-ValidatedPureDefinitions {
  param([string]$Relative,[string[]]$Names,[string[]]$Commands,[string[]]$Members,[string[]]$Types,
    [switch]$AllTopLevelFunctions,[string[]]$DotImports=@())
  $tokens=$null;$errors=$null;$path=Join-Path $RepoRoot $Relative
  $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
  Check (@($errors).Count-eq0) ('pure dependency parses '+$Relative)
  if($AllTopLevelFunctions){Check (@($ast.EndBlock.Statements|Where-Object{$_-isnot[Management.Automation.Language.FunctionDefinitionAst]}).Count-eq0) ('pure dependency has no executable top-level statements '+$Relative)}
  $selected=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-cin$Names})
  foreach($name in $Names){Check (@($selected|Where-Object{$_.Name-ceq$name}).Count-eq1) ('exact pure definition '+$name)}
  Check ($selected.Count-eq$Names.Count) ('exact pure definition count '+$Relative)
  if($AllTopLevelFunctions){Check ($ast.EndBlock.Statements.Count-eq$Names.Count) ('no undeclared pure dependency definitions '+$Relative)}
  foreach($node in $selected){
    foreach($command in @($node.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]},$true))){
      if($command.InvocationOperator-eq[Management.Automation.Language.TokenKind]::Dot){Check ($DotImports-ccontains$command.Extent.Text) ('exact pure dot import '+$command.Extent.Text)}
      else{Check ($command.GetCommandName()-cin$Commands) ('pure dependency command '+$command.GetCommandName())}
    }
    foreach($member in @($node.FindAll({param($n)$n-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true))){Check ($member.Member.Extent.Text-cin$Members) ('pure dependency member '+$member.Member.Extent.Text)}
    foreach($typeNode in @($node.FindAll({param($n)$n-is[Management.Automation.Language.TypeExpressionAst]},$true))){Check ($typeNode.TypeName.FullName-cin$Types) ('pure dependency type '+$typeNode.TypeName.FullName)}
  }
  ($selected|ForEach-Object{$_.Extent.Text})-join[Environment]::NewLine
}
$contractNames=@('Get-R19GrantReservationRoleCapabilities','Get-R19GrantReservationCandidateContract','Assert-R19GrantReservationShape','Assert-R19GrantReservationCandidateContract','Get-R19GrantReservationCancellationCapability','Get-R19GrantReservationStopCandidateContract','Assert-R19GrantReservationStopCandidateContract','Get-R19GrantAgreementCandidateContract','Assert-R19GrantAgreementCandidateContract','Get-R19GrantReservationFatalCandidateContract','Assert-R19GrantReservationFatalCandidateContract')
$contractText=Get-ValidatedPureDefinitions -Relative 'tools/r19_grant_reservation_contract.ps1' -Names $contractNames -Commands (@('Add-Member','ForEach-Object','Get-FileHash','Join-Path')+$contractNames) -Members @('ToUpperInvariant') -Types @('array','bool','int','long','string','ValueType') -AllTopLevelFunctions
$wireNames=@('ConvertTo-R19GrantReservationUInt','Get-R19GrantReservationOpcode','Get-R19GrantReservationCrc','New-R19GrantReservationFrame','ConvertFrom-R19GrantReservationFrame','New-R19GrantReservationParser','Add-R19GrantReservationBytes')
$wireText=Get-ValidatedPureDefinitions -Relative 'tools/r19_grant_reservation_wire.ps1' -Names $wireNames -Commands $wireNames -Members @('Add','GetRange','IndexOf','new','RemoveAt','RemoveRange','ToArray','ToString','TryParse') -Types @('Array','bool','byte[]','Collections.Generic.List[byte]','Collections.Generic.List[object]','Convert','double','Globalization.CultureInfo','Globalization.NumberStyles','single','uint64') -AllTopLevelFunctions
$validatorNames=@('Assert-R19GrantAgreementCaptureContract','Assert-R19GrantReservationFatalCaptureContract')
$validatorText=Get-ValidatedPureDefinitions -Relative 'tools/r19_timed_path_outer.ps1' -Names $validatorNames -Commands @('Assert-R19GrantAgreementCandidateContract','Assert-R19GrantReservationFatalCandidateContract','CheckAgreementFrame','ConvertFrom-R19GrantReservationFrame','ConvertTo-Json','ExactAgreementTicks','Join-Path','NeedAgreement','Set-StrictMode','Where-Object') -Members @('ComputeHash','ContainsKey','Create','Dispose','FromBase64String','IsNullOrWhiteSpace','Parse','Replace','ToBase64String','ToString') -Types @('BitConverter','bool','Convert','int','long','Numerics.BigInteger','Security.Cryptography.SHA256','string') -DotImports @('. (Join-Path $RepoRoot ''tools/r19_grant_reservation_contract.ps1'')','. (Join-Path $RepoRoot ''tools/r19_grant_reservation_wire.ps1'')')
. ([scriptblock]::Create(($contractText,$wireText,$validatorText)-join[Environment]::NewLine))
$pureDependencyPins=@('tools/r19_grant_reservation_contract.ps1','tools/r19_grant_reservation_wire.ps1','tools/r19_timed_path_outer.ps1'|ForEach-Object{[pscustomobject]@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $_) -Algorithm SHA256).Hash}})
$saveStatements=@($runnerAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left.Extent.Text-ceq'$summary'-and$_.Right.Extent.Text.StartsWith('Save-R19TimedPathCaptureEvidence ')})
Check ($saveStatements.Count-eq1) 'real CLI tail invokes persistence entry exactly once'
$saveStatement=$saveStatements[0]
foreach($command in @($saveStatement.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]},$true))){Check ($command.GetCommandName()-ceq'Save-R19TimedPathCaptureEvidence') 'CLI persistence tail has only save command'}
foreach($member in @($saveStatement.FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true))){Check ($member.Member.Extent.Text-ceq'ToArray') 'CLI persistence context has only inert array materialization'}
$script:cliSaveAssignment=[scriptblock]::Create($saveStatement.Extent.Text)
function Assert-R19Acquisition([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function New-CaptureContext{
  [pscustomobject]@{candidate_id='fixture-candidate';mode='ExplicitHostArm';capture_seconds=40;started_utc='2026-10-22T00:00:00Z';clock_domain_id='fixture-domain';frequency='10000000';measurement_start_ticks='10';measurement_end_ticks='400000010';cleanup_proven=$true;hardware_interaction=$false;serial_write_calls=0;failure='';identity_evidence=@();pinned_inputs=@();handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);repo_root=$RepoRoot}
}
function Save-Fixture([string]$Name,[object[]]$CaptureStates,[object]$Context,[string]$BlockRawRole='',[switch]$CliTail,[switch]$ExistingSummary){
  $directory=Join-Path $script:fixtureRoot $Name;[void][IO.Directory]::CreateDirectory($directory)
  $script:activeFixtureDirectory=$directory
  if($BlockRawRole){[IO.File]::WriteAllText((Join-Path $directory ($BlockRawRole+'.raw.bin')),'EXISTING_FILE_MUST_NOT_OVERWRITE')}
  if($ExistingSummary){[IO.File]::WriteAllText((Join-Path $directory 'summary.json'),'EXISTING_SUMMARY_MUST_NOT_OVERWRITE')}
  # Same caller pollution as the permit claim, plus prior frame/write variables.
  [byte[]]$b=[Text.Encoding]::UTF8.GetBytes('fixture-candidate ExplicitHostArm')
  [byte[]]$raw=[byte[]]@(77);[byte[]]$bytes=[byte[]]@(88)
  if($CliTail){
    $states=[Collections.Generic.List[object]]::new();foreach($state in $CaptureStates){$states.Add($state)}
    $OutputDirectory=$directory;$plan=[pscustomobject]@{candidate_id=$Context.candidate_id};$Mode=$Context.mode;$CaptureSeconds=$Context.capture_seconds;$started=$Context.started_utc;$domain=$Context.clock_domain_id;$frequency=$Context.frequency
    $measurementStart=$Context.measurement_start_ticks;$measurementEnd=$Context.measurement_end_ticks;$cleanupProven=$Context.cleanup_proven;$hardware=$Context.hardware_interaction;$serialWrites=$Context.serial_write_calls;$failure=$Context.failure
    $identityEvidence=[Collections.Generic.List[object]]::new();foreach($entry in $Context.identity_evidence){$identityEvidence.Add($entry)}
    $pinInputs=[Collections.Generic.List[object]]::new();foreach($entry in $Context.pinned_inputs){$pinInputs.Add($entry)}
    $handoffSha=$Context.handoff_sha256;$flashSha=$Context.flash_evidence_sha256;$repo=$Context.repo_root
    # This regression exercises legacy persistence only, never an intervention.
    $readComparison=$null
    . $script:cliSaveAssignment
    $value=$summary
  }else{$value=Save-R19TimedPathCaptureEvidence -States $CaptureStates -OutputDirectory $directory -Context $Context}
  $summaryPath=Join-Path $directory 'summary.json'
  if($ExistingSummary){$summaryPath=Join-Path $directory 'capture.failure.json'}
  Check ([IO.File]::Exists($summaryPath)) "$Name durable summary exists"
  $roundTrip=[IO.File]::ReadAllText($summaryPath)|ConvertFrom-Json
  Check ($roundTrip.schema-ceq'vc-lora-r19-timed-path-capture-v1') "$Name capture schema preserved"
  Check (-not$roundTrip.acceptance_eligible-and-not$roundTrip.deployment_authorized-and-not$roundTrip.root_cause_proven) "$Name never grants product acceptance"
  [pscustomobject]@{directory=$directory;summary=$roundTrip;returned=$value}
}
function Check-Raw([object]$Case,[string]$Role,[byte[]]$Expected){
  $path=Join-Path $Case.directory ($Role+'.raw.bin')
  Check ([IO.File]::Exists($path)) ($Role+' raw exists')
  [byte[]]$saved=[IO.File]::ReadAllBytes($path)
  Check ((Get-R19AcquisitionSha256 $saved)-ceq(Get-R19AcquisitionSha256 $Expected)) ($Role+' raw entire SHA roundtrip')
  $roleResult=@($Case.summary.roles|Where-Object{$_.role-ceq$Role})[0]
  Check ($roleResult.raw_available-and$roleResult.raw_saved) ($Role+' raw available/saved explicit')
  Check ($roleResult.raw_bytes-eq$Expected.Length) ($Role+' raw byte count exact')
  Check ($roleResult.raw_sha256-ceq(Get-R19AcquisitionSha256 $Expected)) ($Role+' summary SHA exact')
  Check ([Convert]::ToBase64String($Expected)-ceq$roleResult.raw_base64) ($Role+' base64 entire raw exact')
}

# Permanent explanation fixture: old loop and the typed permit local collide.
$oldException=''
try{&{[byte[]]$b=[byte[]]@(1);$s=New-CaptureState 'vehicle' ([byte[]]@(1,2,3));foreach($b in $s.snapshot.Blocks){[void]$b.Offset}}}catch{$oldException=$_.Exception.Message}
Check ($oldException-match'ContinuousReadBlock'-and$oldException-match'Byte\[\]') 'old typed-permit collision remains reproducible'

$vehicle=New-CaptureState 'vehicle' ([byte[]]@(1,2,3,4,5))
$ground=New-CaptureState 'ground' ([byte[]]@(253,9,8,7,6,5))
$good=Save-Fixture 'typed-permit-local' @($vehicle,$ground) (New-CaptureContext)
Check ($good.summary.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY') 'valid actual C# metadata completes capture only'
Check-Raw $good 'vehicle' $vehicle.raw;Check-Raw $good 'ground' $ground.raw
foreach($roleResult in $good.summary.roles){
  Check ($roleResult.blocks.Count-eq2) ($roleResult.role+' multiple blocks preserved')
  Check ($roleResult.blocks[0].offset-eq0-and$roleResult.blocks[0].count-eq2-and$roleResult.blocks[1].offset-eq2) ($roleResult.role+' block offsets exact')
  Check ($roleResult.blocks[0].begin_ticks-ceq'100'-and$roleResult.blocks[0].end_ticks-ceq'110'-and$roleResult.blocks[1].begin_ticks-ceq'120'-and$roleResult.blocks[1].end_ticks-ceq'140') ($roleResult.role+' block times exact strings')
  Check ($roleResult.blocks[0].clock_domain_id-ceq'fixture-domain'-and$roleResult.blocks[0].frequency-ceq'10000000') ($roleResult.role+' QPC domain retained')
}
$cliCase=Save-Fixture 'real-cli-tail' @($vehicle,$ground) (New-CaptureContext) -CliTail
Check ($cliCase.summary.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY') 'actual CLI tail saves both role evidence'
Check-Raw $cliCase 'vehicle' $vehicle.raw;Check-Raw $cliCase 'ground' $ground.raw
$empty=Save-Fixture 'measured-empty' @((New-CaptureState 'vehicle' ([byte[]]@())),(New-CaptureState 'ground' ([byte[]]@()))) (New-CaptureContext)
Check ($empty.summary.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY') 'measured empty is a valid observation not missing data'
Check-Raw $empty 'vehicle' ([byte[]]@());Check-Raw $empty 'ground' ([byte[]]@())
foreach($missingKind in @('raw','snapshot')){
  $badVehicle=New-CaptureState 'vehicle' ([byte[]]@(1,2,3));$badVehicle.$missingKind=$null
  $case=Save-Fixture ('missing-'+$missingKind) @($badVehicle,(New-CaptureState 'ground' ([byte[]]@(4,5,6)))) (New-CaptureContext)
  Check ($case.summary.result-ceq'INVALID_CAPTURE') ('missing '+$missingKind+' never promoted')
  $missingRole=@($case.summary.roles|Where-Object{$_.role-ceq'vehicle'})[0]
  if($missingKind-ceq'raw'){Check (-not$missingRole.raw_available-and$null-eq$missingRole.raw_bytes-and$null-eq$missingRole.raw_sha256-and$null-eq$missingRole.raw_base64) 'unavailable raw is null not measured zero'}
  Check-Raw $case 'ground' ([byte[]]@(4,5,6))
}
$badMetadata=New-CaptureState 'vehicle' ([byte[]]@(11,12,13));$badMetadata.snapshot=[pscustomobject]@{Overflow=$false;Failure='';CleanupFailure='';ByteCount=3}
$script:metadataSawBothRawFirst=$false
Add-Member -InputObject $badMetadata.snapshot -MemberType ScriptProperty -Name Blocks -Value {
  $script:metadataSawBothRawFirst=[IO.File]::Exists((Join-Path $script:activeFixtureDirectory 'vehicle.raw.bin'))-and[IO.File]::Exists((Join-Path $script:activeFixtureDirectory 'ground.raw.bin'))
  throw 'FIXTURE_METADATA_BLOCKS_FAILURE'
}
$metadataCase=Save-Fixture 'metadata-throws' @($badMetadata,(New-CaptureState 'ground' ([byte[]]@(21,22,23)))) (New-CaptureContext)
Check ($metadataCase.summary.result-ceq'INVALID_CAPTURE') 'metadata exception not promoted'
Check $script:metadataSawBothRawFirst 'both role raw files saved before first metadata getter'
Check-Raw $metadataCase 'vehicle' ([byte[]]@(11,12,13));Check-Raw $metadataCase 'ground' ([byte[]]@(21,22,23))
Check (-not$metadataCase.summary.roles[0].reader_continuous-and$metadataCase.summary.roles[0].export_error) 'metadata failure explicit and no continuous-read proof'
Check ($metadataCase.summary.preservation_errors.Count-gt0) 'metadata exception persisted in failure ledger'
$badText=New-CaptureState 'vehicle' ([byte[]]@(31,32,33));$validTextBlocks=$badText.snapshot.Blocks
$badText.snapshot=[pscustomobject]@{Overflow=$false;Failure=[R19PersistenceFixture.BadText]::new();CleanupFailure='';ByteCount=3;Blocks=$validTextBlocks}
$textCase=Save-Fixture 'metadata-text-throws' @($badText,(New-CaptureState 'ground' ([byte[]]@(41,42,43)))) (New-CaptureContext)
Check ($textCase.summary.result-ceq'INVALID_CAPTURE') 'metadata text conversion failure not promoted'
Check-Raw $textCase 'vehicle' ([byte[]]@(31,32,33));Check-Raw $textCase 'ground' ([byte[]]@(41,42,43))
Check ($textCase.summary.preservation_errors.Count-gt0) 'metadata text failure saved'
Check (($textCase.summary.preservation_errors|ConvertTo-Json -Depth 10)-match'FIXTURE_TEXT_CONVERSION_FAILURE') 'valid block coverage reaches and records injected text conversion failure'
$blocked=Save-Fixture 'raw-write-collision' @((New-CaptureState 'vehicle' ([byte[]]@(51,52,53))),(New-CaptureState 'ground' ([byte[]]@(61,62,63)))) (New-CaptureContext) 'vehicle'
Check ($blocked.summary.result-ceq'INVALID_CAPTURE') 'raw CreateNew failure not promoted'
Check ([IO.File]::ReadAllText((Join-Path $blocked.directory 'vehicle.raw.bin'))-ceq'EXISTING_FILE_MUST_NOT_OVERWRITE') 'raw write never overwrites existing evidence'
Check (-not$blocked.summary.roles[0].raw_saved) 'failed raw persistence not marked saved'
Check-Raw $blocked 'ground' ([byte[]]@(61,62,63))
$badPinContext=New-CaptureContext;$badPinContext.pinned_inputs=@([pscustomobject]@{path='tools/run_r19_timed_path_capture.ps1';sha256=('F'*64)})
$sourceChanged=Save-Fixture 'source-hash-mismatch' @((New-CaptureState 'vehicle' ([byte[]]@(71,72,73))),(New-CaptureState 'ground' ([byte[]]@(81,82,83)))) $badPinContext
Check ($sourceChanged.summary.result-ceq'INVALID_CAPTURE'-and-not$sourceChanged.summary.source_integrity_proven) 'source mismatch invalidates capture not raw preservation'
Check $sourceChanged.summary.cleanup_proven 'source mismatch does not falsify independent cleanup evidence'
Check-Raw $sourceChanged 'vehicle' ([byte[]]@(71,72,73));Check-Raw $sourceChanged 'ground' ([byte[]]@(81,82,83))
$missingPinContext=New-CaptureContext;$missingPinContext.pinned_inputs=@([pscustomobject]@{path=('runs/validation/R19-TIMED-PATH-CAPTURE-PERSISTENCE-TEST-001/absent-'+[Guid]::NewGuid().ToString('N')+'.ps1');sha256=('A'*64)})
$missingSource=Save-Fixture 'source-hash-read-throws' @((New-CaptureState 'vehicle' ([byte[]]@(111,112,113))),(New-CaptureState 'ground' ([byte[]]@(121,122,123)))) $missingPinContext
Check ($missingSource.summary.result-ceq'INVALID_CAPTURE'-and-not$missingSource.summary.source_integrity_proven) 'Get-FileHash missing source exception invalidates capture'
Check (($missingSource.summary.preservation_errors|ConvertTo-Json -Depth 10)-match'Source integrity') 'source read exception preserved in failure ledger'
Check $missingSource.summary.cleanup_proven 'source read exception leaves independent cleanup evidence intact'
Check-Raw $missingSource 'vehicle' ([byte[]]@(111,112,113));Check-Raw $missingSource 'ground' ([byte[]]@(121,122,123))
$existingSummary=Save-Fixture 'existing-summary-preserved' @((New-CaptureState 'vehicle' ([byte[]]@(131,132,133))),(New-CaptureState 'ground' ([byte[]]@(141,142,143)))) (New-CaptureContext) -ExistingSummary
Check ([IO.File]::ReadAllText((Join-Path $existingSummary.directory 'summary.json'))-ceq'EXISTING_SUMMARY_MUST_NOT_OVERWRITE') 'existing primary summary preserved byte for byte'
Check ($existingSummary.summary.result-ceq'INVALID_CAPTURE') 'existing summary produces separate INVALID fallback not success'
Check ($existingSummary.summary.preservation_errors.Count-gt0) 'existing summary collision recorded in fallback'
Check-Raw $existingSummary 'vehicle' ([byte[]]@(131,132,133));Check-Raw $existingSummary 'ground' ([byte[]]@(141,142,143))

# Deterministic ConvertTo-Json/writer failure injection, limited to this test
# process. The second write delegates to the real durable production writer.
$script:originalJsonWriter=(Get-Command Write-R19TimedPathJson).ScriptBlock
$script:jsonWriteAttempts=0
$script:jsonSawBothRawFirst=$false
function Write-R19TimedPathJson([string]$Path,[object]$Value){
  $script:jsonWriteAttempts++
  if($script:jsonWriteAttempts-eq1){
    $script:jsonSawBothRawFirst=[IO.File]::Exists((Join-Path $script:activeFixtureDirectory 'vehicle.raw.bin'))-and[IO.File]::Exists((Join-Path $script:activeFixtureDirectory 'ground.raw.bin'))
    throw 'FIXTURE_PRIMARY_JSON_SERIALIZATION_FAILURE'
  }
  & $script:originalJsonWriter -Path $Path -Value $Value
}
try{
  $jsonFallback=Save-Fixture 'serialization-failure' @((New-CaptureState 'vehicle' ([byte[]]@(91,92,93))),(New-CaptureState 'ground' ([byte[]]@(101,102,103)))) (New-CaptureContext)
  Check ($script:jsonWriteAttempts-eq2) 'primary JSON failure triggers single safe fallback'
  Check $script:jsonSawBothRawFirst 'both raw files exist before serialization injection'
  Check ($jsonFallback.summary.result-ceq'INVALID_CAPTURE') 'serialization failure cannot become capture success'
  Check (($jsonFallback.summary.preservation_errors|ConvertTo-Json -Depth 10)-match'FIXTURE_PRIMARY_JSON_SERIALIZATION_FAILURE') 'serialization failure preserved in fallback summary'
  Check-Raw $jsonFallback 'vehicle' ([byte[]]@(91,92,93));Check-Raw $jsonFallback 'ground' ([byte[]]@(101,102,103))
}finally{Set-Item -LiteralPath function:Write-R19TimedPathJson -Value $script:originalJsonWriter}
$context=New-CaptureContext;$context.failure='ORIGINAL_READER_FAILURE'
$priorFailure=Save-Fixture 'prior-failure' @((New-CaptureState 'vehicle' ([byte[]]@(1,2,3))),(New-CaptureState 'ground' ([byte[]]@(4,5,6)))) $context
Check ($priorFailure.summary.result-ceq'INVALID_CAPTURE'-and$priorFailure.summary.failure.Contains('ORIGINAL_READER_FAILURE')) 'original capture failure retained'
function New-FatalCaptureContext {
  $value=New-CaptureContext
  $base=Get-R19GrantReservationCandidateContract -RepoRoot $RepoRoot -Enabled $true -CancellationEnabled $true -AgreementEnabled $true -FatalEnabled $true
  $stop=Get-R19GrantReservationStopCandidateContract -RepoRoot $RepoRoot -Enabled $true -AgreementEnabled $true -FatalEnabled $true
  $agreement=Get-R19GrantAgreementCandidateContract -RepoRoot $RepoRoot -Enabled $true -FatalEnabled $true
  $fatal=Get-R19GrantReservationFatalCandidateContract -RepoRoot $RepoRoot -Enabled $true
  $workflow=[pscustomobject]@{schema='vc-lora-r19-grant-reservation-workflow-v1';status='Failed';failure='SYNTHETIC_PREPARATION_FAILURE';candidate_id=$value.candidate_id;handoff_sha256=$value.handoff_sha256;flash_evidence_sha256=$value.flash_evidence_sha256;clock_domain_id=$value.clock_domain_id;frequency=$value.frequency;agreement_enabled=$true;cancellation_enabled=$true;wire_version=3;param_attempts=0;commands=@();observations=@();maximum_commands=24;maximum_rounds=2;maximum_cancellations=1;high_speed_success_proven=$false;rf_delivery_proven=$false;acceptance_authorized=$false;deployment_authorized=$false;commit_is_irrevocable=$false;commit_ground=$null;commit_vehicle=$null;terminal_abort=[pscustomobject]@{phase='ABORT_UNCONFIRMED';roles=[pscustomobject]@{vehicle=[pscustomobject]@{attempts=0;ack=$null};ground=[pscustomobject]@{attempts=0;ack=$null}}}}
  foreach($entry in @{grant_reservation_diagnostics=$true;grant_reservation_contract=$base;grant_reservation_workflow=$workflow;grant_reservation_stop_diagnostics=$true;grant_reservation_stop_contract=$stop;grant_agreement_diagnostics=$true;grant_agreement_contract=$agreement;grant_reservation_fatal_diagnostics=$true;grant_reservation_fatal_contract=$fatal;reservation_raw_phases=[pscustomobject]@{roles=@([pscustomobject]@{role='vehicle';preparation_bytes=[byte[]]@(1,2,3,4,5);measurement_bytes=[byte[]]@()},[pscustomobject]@{role='ground';preparation_bytes=[byte[]]@(253,9,8,7,6,5);measurement_bytes=[byte[]]@()})}}.GetEnumerator()){Add-Member -InputObject $value -NotePropertyName $entry.Key -NotePropertyValue $entry.Value}
  return $value
}
$fatalContext=New-FatalCaptureContext
$fatalCase=Save-Fixture 'fatal-positive-real-validators' @((New-CaptureState 'vehicle' ([byte[]]@(1,2,3,4,5))),(New-CaptureState 'ground' ([byte[]]@(253,9,8,7,6,5)))) $fatalContext
Check ($fatalCase.summary.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY') 'actual real-validator Fatal persistence succeeds without PARAM or successful reservation claims'
Check ($fatalCase.summary.grant_reservation_fatal_diagnostics-is[bool]-and$fatalCase.summary.grant_reservation_fatal_diagnostics) 'Fatal persisted selection is exact Boolean true'
Assert-R19GrantReservationFatalCaptureContract -Summary $fatalCase.summary -Enabled $true -Contract $fatalContext.grant_reservation_fatal_contract -RepoRoot $RepoRoot
Check (($fatalCase.summary.grant_reservation_fatal_contract|ConvertTo-Json -Depth 25 -Compress)-ceq($fatalContext.grant_reservation_fatal_contract|ConvertTo-Json -Depth 25 -Compress)) 'Fatal source-bound contract survives durable JSON roundtrip'
Check-Raw $fatalCase vehicle ([byte[]]@(1,2,3,4,5));Check-Raw $fatalCase ground ([byte[]]@(253,9,8,7,6,5))
foreach($mutation in @('flag-string','scope','reads','missing-contract')){
  $bad=New-FatalCaptureContext
  switch($mutation){'flag-string'{$bad.grant_reservation_fatal_diagnostics='true'};'scope'{$bad.grant_reservation_fatal_contract.scope='all-runtime-faults'};'reads'{$bad.grant_reservation_fatal_contract.paired_raw_reads=22};'missing-contract'{$bad.PSObject.Properties.Remove('grant_reservation_fatal_contract')}}
  $negative=Save-Fixture ('fatal-negative-'+$mutation) @((New-CaptureState 'vehicle' ([byte[]]@(1,2,3,4,5))),(New-CaptureState 'ground' ([byte[]]@(253,9,8,7,6,5)))) $bad
  Check ($negative.summary.result-ceq'INVALID_CAPTURE'-and$negative.summary.preservation_errors.Count-gt0) ('real strict validator rejects Fatal '+$mutation)
  Check-Raw $negative vehicle ([byte[]]@(1,2,3,4,5));Check-Raw $negative ground ([byte[]]@(253,9,8,7,6,5))
}
$falseContext=New-CaptureContext;$falseContext|Add-Member NoteProperty grant_reservation_fatal_diagnostics $false;$falseContext|Add-Member NoteProperty grant_reservation_fatal_contract $null
$falseFatal=Save-Fixture 'legacy-explicit-fatal-false' @((New-CaptureState 'vehicle' ([byte[]]@(1,2,3,4,5))),(New-CaptureState 'ground' ([byte[]]@(253,9,8,7,6,5)))) $falseContext
Check ($falseFatal.summary.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY') 'legacy explicit false Fatal selection retains safe persistence'
foreach($pin in $pureDependencyPins){Check ((Get-FileHash -LiteralPath (Join-Path $RepoRoot $pin.path) -Algorithm SHA256).Hash-ceq$pin.sha256) ('pure dependency unchanged through real Save calls '+$pin.path)}
Write-R19TimedPathJson (Join-Path $OutputDirectory 'test_result.json') ([pscustomobject]@{schema='vc-lora-r19-timed-path-persistence-regression-v1';result='PASS';runner_path=$runnerPath;runner_sha256=(Get-R19AcquisitionSha256 ([IO.File]::ReadAllBytes($runnerPath)));test_sha256=(Get-R19AcquisitionSha256 ([IO.File]::ReadAllBytes($PSCommandPath)));powershell_version=[string]$PSVersionTable.PSVersion;hardware_interaction=$false;checks=$script:checks})
Write-Output "TIMED_PATH_CAPTURE_PERSISTENCE PASS $script:checks checks output=$OutputDirectory"
