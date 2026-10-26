[CmdletBinding()]
param([string]$RepoRoot='',[string]$OutputDirectory='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
if(-not$OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('runs/validation/R19-PARAM-LIST-DIAGNOSTICS-OFFLINE-001/20261024T090000JST/capture/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+[Guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$script:results=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Body){try{&$Body;$script:results.Add([pscustomobject]@{name=$Name;passed=$true;error=''})}catch{$script:results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message})}}
function Require([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
foreach($forbidden in @('Get-CimInstance','Get-PnpDeviceProperty','Get-PnpDevice','Get-Process','Start-Process','Invoke-Expression','Invoke-Command')){Set-Item -Path ('function:script:'+$forbidden) -Value {throw 'FORBIDDEN PARAM_LIST capture fixture hardware/process call'}}
function Add-Type {param([string]$AssemblyName);if($AssemblyName-cne'System.Numerics'){throw 'FORBIDDEN PARAM_LIST fixture dynamic type compilation'};Microsoft.PowerShell.Utility\Add-Type -AssemblyName System.Numerics}
$capturePath=Join-Path $RepoRoot 'tools/run_r19_timed_path_capture.ps1'
$captureSource=[IO.File]::ReadAllText($capturePath)
$tokens=$null;$errors=$null
$captureAst=[Management.Automation.Language.Parser]::ParseInput($captureSource,[ref]$tokens,[ref]$errors)
Check 'capture-parses' {Require ($errors.Count-eq0) 'Production capture AST must parse'}
Check 'PARAM_LIST-selection-is-explicit-switch-opt-in' {
  $parameter=@($captureAst.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'ParamListDiagnostics'})
  Require ($parameter.Count-eq1-and$parameter[0].StaticType-eq[Management.Automation.SwitchParameter]) 'Missing explicit ParamListDiagnostics switch'
}
Check 'default-ImportOnly-has-no-port-process-or-permit-effects' {
  $savedRepo=$RepoRoot;$savedOutput=$OutputDirectory
  try{. $capturePath -ImportOnly}finally{$RepoRoot=$savedRepo;$OutputDirectory=$savedOutput}
  Require ($null-ne(Get-Command Save-R19TimedPathCaptureEvidence -ErrorAction SilentlyContinue)) 'Definitions-only capture import must remain usable'
}
# The actual opt-in definitions are imported once, with hardware/process commands
# still forbidden. Subsequent fixtures execute extracted production AST only;
# none executes the CLI, consumes a permit, or creates a SerialPort.
$fixtureRepoRoot=$RepoRoot;$fixtureOutputDirectory=$OutputDirectory;$importError=''
try{. $capturePath -ImportOnly -ParamListDiagnostics -Mode ExplicitHostArm -AuxReadinessDiagnostics -DiagnosticUsbFailureDiagnostics}catch{$importError=$_.Exception.Message}
finally{$RepoRoot=$fixtureRepoRoot;$OutputDirectory=$fixtureOutputDirectory}
Check 'opt-in-ImportOnly-loads-the-real-pure-helper-and-capture-functions' {
  Require ([string]::IsNullOrEmpty($importError)) ('Opt-in import failed: '+$importError)
  foreach($name in @('Invoke-R19ParamListRequest','Update-R19ParamListCheckpoint','New-R19ParamListDiagnosticsState','Add-R19ParamListBytes','Get-R19ParamListSnapshot')){Require ($null-ne(Get-Command $name -ErrorAction SilentlyContinue)) ('Missing production definition '+$name)}
}
function Reject([scriptblock]$Body,[string]$Message='Expected refusal'){
  $caught='';try{&$Body|Out-Null}catch{$caught=$_.Exception.Message}
  Require (-not[string]::IsNullOrEmpty($caught)) $Message
  Require (-not$caught.Contains('FORBIDDEN')) ('A hardware/process attempt is not a valid policy rejection: '+$caught)
}
function CaseDirectory([string]$Name){$directory=Join-Path $OutputDirectory $Name;[void][IO.Directory]::CreateDirectory($directory);return $directory}
function New-RequestFixture {
  $state=New-R19ParamListDiagnosticsState -Frequency 1000 -ClockDomainId 'capture-fixture-native-clock'
  $script:requestSpy=[pscustomobject]@{state=$state;calls=0;clock=100L;payload=$null;reentrant=$null}
  return $state
}
function Invoke-RequestFixture {
  param([object]$State,[hashtable]$Overrides=@{},[scriptblock]$Writer={param([byte[]]$Payload)
    Require ($script:requestSpy.state.write_attempts-eq1) 'Attempt must be latched before entering writer'
    $script:requestSpy.calls++;$script:requestSpy.payload=[byte[]]$Payload.Clone();return [int]$Payload.Length})
  $arguments=@{State=$State;Role='ground';Workflow=[pscustomobject]@{arm_write_accepted=$true};HeartbeatCount=1;CaptureDeadlineTicks='40000';RawOffset=[long]0;ReaderPendingBytes=0;NowTicks={$script:requestSpy.clock.ToString()};Writer=$Writer}
  foreach($key in $Overrides.Keys){$arguments[$key]=$Overrides[$key]}
  return Invoke-R19ParamListRequest @arguments
}
function LocalCrc([uint16]$Crc,[byte]$Value){$t=($Value-bxor($Crc-band255))-band255;$t=($t-bxor($t-shl4))-band255;[uint16]((($Crc-shr8)-bxor($t-shl8)-bxor($t-shl3)-bxor($t-shr4))-band65535)}
function ParamFrame([int]$Index,[switch]$BadCrc){
  $bytes=[byte[]]::new(37);$bytes[0]=253;$bytes[1]=25;$bytes[5]=1;$bytes[6]=1;$bytes[7]=22
  $bytes[14]=164;$bytes[15]=3;$bytes[16]=[byte]($Index-band255);$bytes[17]=[byte](($Index-shr8)-band255)
  $id=[Text.Encoding]::ASCII.GetBytes(('P{0:D6}'-f$Index));[Array]::Copy($id,0,$bytes,18,$id.Length);$bytes[34]=9
  [uint16]$crc=65535;for($i=1;$i-lt35;$i++){$crc=LocalCrc $crc $bytes[$i]};$crc=LocalCrc $crc 220
  $bytes[35]=[byte]($crc-band255);$bytes[36]=[byte]($crc-shr8);if($BadCrc){$bytes[36]=$bytes[36]-bxor1};return ,$bytes
}
function HeartbeatFrame([switch]$BadCrc){
  $bytes=[byte[]]::new(21);$bytes[0]=253;$bytes[1]=9;$bytes[5]=1;$bytes[6]=1;$bytes[18]=3
  [uint16]$crc=65535;for($i=1;$i-lt19;$i++){$crc=LocalCrc $crc $bytes[$i]};$crc=LocalCrc $crc 50
  $bytes[19]=[byte]($crc-band255);$bytes[20]=[byte]($crc-shr8);if($BadCrc){$bytes[20]=$bytes[20]-bxor1};return ,$bytes
}
function Get-CommandArgumentText($Command,[string]$Name){
  for($i=0;$i-lt$Command.CommandElements.Count-1;$i++){if($Command.CommandElements[$i]-is[Management.Automation.Language.CommandParameterAst]-and$Command.CommandElements[$i].ParameterName-ceq$Name){return $Command.CommandElements[$i+1].Extent.Text}}
  throw ('Missing actual capture argument '+$Name)
}
function New-CaptureState([string]$Role,[byte[]]$Bytes){
  $blocks=@();if($Bytes.Length){$blocks=@([pscustomobject]@{Offset=0;Count=$Bytes.Length;BeginTicks=200L;EndTicks=201L})}
  [pscustomobject]@{spec=[pscustomobject]@{role=$Role;port=($Role+'-fixture-only');baud=$(if($Role-ceq'ground'){57600}else{115200})};reader_id=($Role+'-fixture-reader');nonce='123';opened=$true;joined=$true;cleanup_close_fallback=$false;open_before_ticks='1';open_after_ticks='2';read_started_ticks='3';snapshot=[pscustomobject]@{ByteCount=$Bytes.Length;Blocks=$blocks;Overflow=$false;Failure='';LastReadEndTicks=201L};raw=$Bytes;workflow=$null;workflow_failure='';writes=[Collections.Generic.List[object]]::new();observations=[Collections.Generic.List[object]]::new();product_observations=[Collections.Generic.List[object]]::new()}
}
function New-CaptureContext($ParamSnapshot,[string]$ParamFailure=''){
  [pscustomobject]@{candidate_id='PARAM-LIST-SYNTHETIC-NOT-HARDWARE';mode='ExplicitHostArm';capture_seconds=40;started_utc='2026-10-24T00:00:00Z';clock_domain_id='capture-fixture-native-clock';frequency='1000';measurement_start_ticks='0';measurement_end_ticks='40000';cleanup_proven=$true;hardware_interaction=$false;serial_write_calls=4;failure='';identity_evidence=@();pinned_inputs=@();handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);repo_root=$RepoRoot;param_list_diagnostics_enabled=$true;param_list_diagnostics=$ParamSnapshot;param_list_diagnostics_failure=$ParamFailure}
}

foreach($selection in @(
  @{name='SyncOnly';args=@{Mode='SyncOnly';AuxReadinessDiagnostics=$true;DiagnosticUsbFailureDiagnostics=$true}},
  @{name='without-AUX';args=@{Mode='ExplicitHostArm';DiagnosticUsbFailureDiagnostics=$true}},
  @{name='without-USB-diagnostic';args=@{Mode='ExplicitHostArm';AuxReadinessDiagnostics=$true}},
  @{name='with-read-pause';args=@{Mode='ExplicitHostArm';AuxReadinessDiagnostics=$true;DiagnosticUsbFailureDiagnostics=$true;ReadComparisonMode='GroundPauseResume'}})){
  Check ('opt-in-rejects-'+$selection.name) {
    $arguments=$selection.args;$savedRepo=$RepoRoot;$savedOutput=$OutputDirectory
    try{Reject {. $capturePath -ImportOnly -ParamListDiagnostics @arguments} 'Invalid PARAM_LIST selection accepted'}finally{$RepoRoot=$savedRepo;$OutputDirectory=$savedOutput}
  }
}
Check 'helper-import-is-under-the-explicit-opt-in-branch' {
  $imports=@($captureAst.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.InvocationOperator-eq[Management.Automation.Language.TokenKind]::Dot-and$node.Extent.Text.Contains('r19_param_list_diagnostics.ps1')},$true))
  Require ($imports.Count-eq1) 'Pure helper import must have exactly one opt-in site'
  $ancestor=$imports[0].Parent;while($null-ne$ancestor-and$ancestor-isnot[Management.Automation.Language.IfStatementAst]){$ancestor=$ancestor.Parent}
  Require ($null-ne$ancestor-and$ancestor.Clauses[0].Item1.Extent.Text-ceq'$ParamListDiagnostics') 'Default capture must not load the optional ledger'
}
Check 'eligible-request-latches-before-exact-canonical-write-and-never-retries' {
  $state=New-RequestFixture;Require (Invoke-RequestFixture $state) 'Eligible request not attempted'
  Require ($script:requestSpy.calls-eq1-and$state.write_attempts-eq1) 'Expected exactly one local writer call'
  Require (([BitConverter]::ToString($script:requestSpy.payload)-replace'-','')-ceq'FD02000063FFBE1500000101D507') 'Not the exact CRC-valid PARAM_REQUEST_LIST #21 wire frame'
  $snapshot=Get-R19ParamListSnapshot $state
  Require ($snapshot.request.accepted_bytes-eq14-and$snapshot.request.write_started_ticks-eq100-and$snapshot.request.write_returned_ticks-eq100-and$snapshot.request_attempts-eq1) 'Write provenance must use the monotonic clock and exact acceptance'
  Require (-not(Invoke-RequestFixture $state)-and$script:requestSpy.calls-eq1) 'Second call retried the request'
  Require ($snapshot.request.local_write_api_accepted_only-and-not$snapshot.request.delivery_proven-and-not$snapshot.acceptance_eligible-and-not$snapshot.deployment_authorized) 'Local write must not claim RF/Pixhawk/product acceptance'
}
foreach($gate in @(
  @{name='null-state';args=@{State=$null}},@{name='vehicle-role';args=@{Role='vehicle'}},
  @{name='null-workflow';args=@{Workflow=$null}},@{name='ARM-not-accepted';args=@{Workflow=[pscustomobject]@{arm_write_accepted=$false}}},
  @{name='ARM-string-not-boolean';args=@{Workflow=[pscustomobject]@{arm_write_accepted='true'}}},
  @{name='no-CRC-valid-heartbeat';args=@{HeartbeatCount=0}},@{name='reader-bytes-still-pending';args=@{ReaderPendingBytes=1}},
  @{name='only-thirty-seconds-remain';args=@{CaptureDeadlineTicks='30100'}},@{name='one-tick-short-of-thirty-one-seconds';args=@{CaptureDeadlineTicks='31099'}})){
  Check ('request-gate-'+$gate.name) {$state=New-RequestFixture;Require (-not(Invoke-RequestFixture $state $gate.args)) 'Closed gate still attempted a request';Require ($state.write_attempts-eq0-and$script:requestSpy.calls-eq0) 'Closed gate consumed attempt or called writer'}
}
Check 'exact-thirty-one-seconds-remaining-is-eligible' {$state=New-RequestFixture;Require (Invoke-RequestFixture $state @{CaptureDeadlineTicks='31100'}) 'Exact 31-second observation budget rejected';Require ($state.deadline_ticks-eq30100) '30-second deadline must originate at write attempt'}
Check 'unparsed-raw-cursor-is-rejected-before-attempt' {$state=New-RequestFixture;Reject {Invoke-RequestFixture $state @{RawOffset=1}};Require ($state.write_attempts-eq0-and$script:requestSpy.calls-eq0) 'Cursor mismatch still wrote a request'}
foreach($writeCase in @(
  @{name='partial';writer={param([byte[]]$Payload)$script:requestSpy.calls++;return [int]7};accepted=7},
  @{name='zero';writer={param([byte[]]$Payload)$script:requestSpy.calls++;return [int]0};accepted=0},
  @{name='exception';writer={param([byte[]]$Payload)$script:requestSpy.calls++;throw [IO.IOException]::new('FIXTURE_LOCAL_WRITE_EXCEPTION')};accepted=$null},
  @{name='void';writer={param([byte[]]$Payload)$script:requestSpy.calls++};accepted=$null})){
  Check ('request-'+$writeCase.name+'-is-one-attempt-without-retry') {
    $state=New-RequestFixture;Require (Invoke-RequestFixture $state -Writer $writeCase.writer) 'Attempt must remain observable even if write incomplete'
    Require ($state.write_attempts-eq1-and$script:requestSpy.calls-eq1-and$state.write_committed) 'Failure did not commit its immutable first attempt'
    Require (-not(Invoke-RequestFixture $state)-and$script:requestSpy.calls-eq1) 'Incomplete write authorized retry'
    $snapshot=Get-R19ParamListSnapshot $state
    if($null-eq$writeCase.accepted){Require ($null-eq$snapshot.request.accepted_bytes-and-not[string]::IsNullOrEmpty($snapshot.request.api_exception_type)) 'Unknown acceptance must be null with exception witness'}else{Require ($snapshot.request.accepted_bytes-eq$writeCase.accepted) 'Partial acceptance changed'}
    Require ($snapshot.result-ceq'WRITE_INCOMPLETE'-and-not$snapshot.acceptance_eligible) 'Write failure claimed a clean acquisition'
  }
}
Check 'reentrant-writer-observes-attempt-and-cannot-send-twice' {
  $state=New-RequestFixture
  $writer={param([byte[]]$Payload)$script:requestSpy.calls++;Require ($script:requestSpy.state.write_attempts-eq1) 'Reentrant state not latched';$script:requestSpy.reentrant=Invoke-RequestFixture $script:requestSpy.state;return [int]$Payload.Length}
  Require (Invoke-RequestFixture $state -Writer $writer) 'Outer attempt absent';Require ($script:requestSpy.reentrant-eq$false-and$script:requestSpy.calls-eq1) 'Reentrant request reached writer'
}

# Extract the actual production branches, not a replacement of their logic.
$requestBranches=@($captureAst.FindAll({param($node)$node-is[Management.Automation.Language.IfStatementAst]-and$node.Extent.Text.StartsWith('if($ParamListDiagnostics-and$s.spec.role')-and$node.Extent.Text.Contains('$attempted=Invoke-R19ParamListRequest')},$true))
$ingestBranches=@($captureAst.FindAll({param($node)$node-is[Management.Automation.Language.IfStatementAst]-and$node.Extent.Text.StartsWith('if($ParamListDiagnostics-and$s.spec.role')-and$node.Extent.Text.Contains('Add-R19ParamListBytes')-and-not$node.Extent.Text.Contains('Invoke-R19ParamListRequest')},$true))
$tailBranches=@($captureAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.IfStatementAst]-and$_.Extent.Text.StartsWith('if($ParamListDiagnostics-and-not$paramDiagnosticsFailure)')-and$_.Extent.Text.Contains('$gs.snapshot.Blocks')})
$productLoops=@($captureAst.FindAll({param($node)$node-is[Management.Automation.Language.ForEachStatementAst]-and$node.Variable.VariablePath.UserPath-ceq'product'},$true))
# Audit only the source-bound function closure needed by the new priority Abort
# path and its real workflow fixture. Do not execute either CLI or replace the
# new callback with a success stub. Retained-reader/port members are supplied by
# explicit inert fixture objects below; no device or process type is permitted.
$priorityDefinitions=@{};$prioritySources=[Collections.Generic.List[object]]::new()
foreach($relative in @('tools/run_r19_timed_path_capture.ps1','tools/r19_grant_reservation_workflow.ps1','tools/r19_grant_reservation_wire.ps1')){
  $path=Join-Path $RepoRoot $relative;$t=$null;$e=$null
  $a=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
  if($e.Count){throw ('Priority fixture source parse failure: '+$relative)}
  $prioritySources.Add([pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash})
  foreach($f in @($a.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]})){
    if($priorityDefinitions.ContainsKey($f.Name)){throw ('Duplicate source-bound fixture definition: '+$f.Name)}
    $priorityDefinitions[$f.Name]=$f
  }
}
function Get-VerifiedPriorityClosure([hashtable]$Definitions,[string[]]$Roots){
  $queue=[Collections.Generic.Queue[string]]::new();foreach($name in $Roots){$queue.Enqueue($name)}
  $visited=@{}
  $safeTypes=@('Array','BitConverter','bool','byte','byte[]','Collections.Generic.List[byte]','Collections.Generic.List[object]','Collections.Generic.List[string]','Convert','double','Globalization.CultureInfo','Globalization.NumberStyles','int','long','Math','Numerics.BigInteger','object','object[]','pscustomobject','ref','scriptblock','Security.Cryptography.SHA256','single','string','string[]','switch','Text.Encoding','uint16','uint32','uint64','void')
  $safeMembers=@('Add','ComputeHash','Copy','Create','Dispose','GetRange','GetSnapshot','GetString','GetType','IndexOf','IsNullOrEmpty','IsNullOrWhiteSpace','Min','new','ReadSlice','RemoveAt','RemoveRange','Replace','ToArray','ToBase64String','ToString','ToUInt16','ToUInt32','ToUInt64','ToUpperInvariant','TryParse','Write')
  while($queue.Count){
    $name=$queue.Dequeue();if($visited.ContainsKey($name)){continue}
    Require ($Definitions.ContainsKey($name)) ('Missing source-bound priority definition: '+$name)
    $f=$Definitions[$name];$visited[$name]=$f
    foreach($c in @($f.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]},$true))){
      $called=$c.GetCommandName()
      if([string]::IsNullOrEmpty($called)){
        Require ($c.InvocationOperator-eq[Management.Automation.Language.TokenKind]::Ampersand-and$c.CommandElements[0].Extent.Text-cin@('$BeforeWrite','$NowTicks','$NowTicksProvider','$terminalDriverWriter','$Writer')) 'Unreviewed dynamic call inside source-bound priority fixture'
      }elseif($Definitions.ContainsKey($called)){$queue.Enqueue($called)}
      else{
        Require ($called-cin@('New-Object','Where-Object')) ('Unreviewed command inside source-bound priority fixture: '+$called)
        if($called-ceq'New-Object'){Require ($c.CommandElements.Count-ge2-and$c.CommandElements[1].Extent.Text-ceq'byte[]') 'Unreviewed constructed type inside source-bound priority fixture'}
      }
    }
    foreach($type in @($f.FindAll({param($n)$n-is[Management.Automation.Language.TypeExpressionAst]-or$n-is[Management.Automation.Language.TypeConstraintAst]},$true))){Require ($type.TypeName.FullName-cin$safeTypes) ('Unreviewed type inside source-bound priority fixture: '+$type.TypeName.FullName)}
    foreach($m in @($f.FindAll({param($n)$n-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true))){
      Require ($m.Member.Extent.Text-cin$safeMembers) ('Unreviewed member inside source-bound priority fixture: '+$m.Member.Extent.Text)
      if($m.Member.Extent.Text-ceq'Write'){Require ($m.Expression.Extent.Text-ceq'$Target.port') 'Priority fixture Write must target the explicit inert port seam'}
    }
  }
  return ,$visited
}
$priorityRoots=@('Invoke-R19CaptureReservationPriorityAbort','New-R19GrantReservationWorkflow','Set-R19GrantReservationPrerequisites','Get-R19GrantReservationNextCommand','Invoke-R19ReservationPrivateWrite','New-R19GrantReservationParser','Begin-R19GrantReservationParamWrite','Set-R19GrantReservationParamWriteResult','Test-R19GrantReservationRequestAllowed','Invoke-R19GrantReservationRuntimePreflight')
$priorityClosure=$null;$priorityClosureVerified=$false
Check 'priority-abort-is-a-verified-actual-source-closure-not-a-stub' {
  $priorityClosure=Get-VerifiedPriorityClosure $priorityDefinitions $priorityRoots
  Require ($priorityClosure.ContainsKey('Invoke-R19CaptureReservationPriorityAbort')-and$priorityClosure.ContainsKey('Invoke-R19ReservationTerminalAbortWrite')-and$priorityClosure.ContainsKey('Receive-R19GrantReservationControlPrefixes')) 'Real driver/writer/retained-prefix dependencies missing'
  foreach($name in $priorityClosure.Keys){. ([scriptblock]::Create($priorityClosure[$name].Extent.Text));Set-Item -Path ('Function:script:'+$name) -Value (Get-Item ('Function:'+$name)).ScriptBlock}
  $script:verifiedPriorityClosure=$priorityClosure;$script:priorityClosureVerified=$true
}
foreach($mutation in @(
  @{name='unknown-command';body='Get-Process'},
  @{name='unknown-type';body="[IO.File]::ReadAllText('NOT-A-REAL-FIXTURE-INPUT')"},
  @{name='unknown-dynamic-call';body='& $unreviewedCallback'},
  @{name='unknown-constructor';body='New-Object IO.Ports.SerialPort'})){
  Check ('source-bound-priority-audit-rejects-'+$mutation.name) {
    $map=@{};foreach($key in $priorityDefinitions.Keys){$map[$key]=$priorityDefinitions[$key]}
    $original=$map['Invoke-R19CaptureReservationPriorityAbort'].Extent.Text
    $altered=$original.Substring(0,$original.LastIndexOf('}'))+[Environment]::NewLine+$mutation.body+[Environment]::NewLine+'}'
    $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseInput($altered,[ref]$t,[ref]$e)
    Require ($e.Count-eq0) 'Negative fixture must remain syntactically valid'
    $map['Invoke-R19CaptureReservationPriorityAbort']=$a.EndBlock.Statements[0]
    Reject {Get-VerifiedPriorityClosure $map $priorityRoots} 'Unreviewed priority dependency was accepted'
  }
}
$priorityDeliveredBranches=@($captureAst.FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Clauses[0].Item1.Extent.Text-ceq'$GrantReservationDiagnostics'-and$n.Extent.Text.Contains('try{Add-R19GrantReservationDeliveredBlock')},$true))
function Assert-ParamPriorityDeliveryBranch($Branch){
  foreach($command in @($Branch.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]},$true))){
    $name=$command.GetCommandName()
    Require ($name-cin@('Add-R19GrantReservationDeliveredBlock','Invoke-R19CaptureReservationPriorityAbort')-and$script:verifiedPriorityClosure.ContainsKey($name)) ('Unreviewed command inside actual priority delivery branch: '+$name)
  }
  foreach($type in @($Branch.FindAll({param($n)$n-is[Management.Automation.Language.TypeExpressionAst]-or$n-is[Management.Automation.Language.TypeConstraintAst]},$true))){Require ($type.TypeName.FullName-ceq'string') ('Unreviewed type inside actual priority delivery branch: '+$type.TypeName.FullName)}
  foreach($member in @($Branch.FindAll({param($n)$n-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true))){Require ($member.Member.Extent.Text-ceq'ToArray'-and$member.Expression.Extent.Text-ceq'$states'-and$null-eq$member.Arguments) 'Unreviewed member inside actual priority delivery branch'}
}
Check 'actual-production-param-branches-are-unique-and-hardware-free' {
  Require ($requestBranches.Count-eq1-and$ingestBranches.Count-eq1-and$tailBranches.Count-eq1) 'Cannot identify exact Ground live/request/tail production branches'
  Require ($script:priorityClosureVerified-and$priorityDeliveredBranches.Count-eq1) 'New priority helper may be admitted only after its actual closure and unique production delivery site are verified'
  Assert-ParamPriorityDeliveryBranch $priorityDeliveredBranches[0]
  foreach($branch in @($requestBranches[0],$ingestBranches[0],$tailBranches[0])){foreach($command in @($branch.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]},$true))){Require ($command.GetCommandName()-cin@('Invoke-R19ParamListRequest','Invoke-R19GrantReservationRuntimePreflight','Invoke-R19CaptureReservationPriorityAbort','Add-R19ParamListBytes','Update-R19ParamListCheckpoint','Where-Object','New-Object')) ('Unexpected command inside isolated production fixture: '+$command.GetCommandName())}}
}
Check 'actual-priority-delivery-branch-rejects-an-injected-command-before-execution' {
  $original=$priorityDeliveredBranches[0].Extent.Text
  $altered=$original.Substring(0,$original.LastIndexOf('}'))+[Environment]::NewLine+'Get-Process'+[Environment]::NewLine+'}'
  $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseInput($altered,[ref]$t,[ref]$e)
  Require ($e.Count-eq0-and$a.EndBlock.Statements.Count-eq1) 'Injected branch fixture must remain one valid production-shaped branch'
  Reject {Assert-ParamPriorityDeliveryBranch $a.EndBlock.Statements[0]} 'Actual delivered branch admitted an injected unreviewed command'
}
Check 'actual-Ground-request-branch-keeps-three-private-writes-and-adds-one-product-request' {
  $ParamListDiagnostics=$true;$paramDiagnosticsFailure='';$paramState=New-RequestFixture;$paramDeliveredOffset=0L;$deadline=40000L;$serialWrites=3
  $clock=[pscustomobject]@{ElapsedTicks=100L};$status=[pscustomobject]@{LastReadEndTicks=200L;PendingByteCount=0}
  $reader=[pscustomobject]@{status=$status};$reader|Add-Member ScriptMethod GetStatus {return $this.status}
  $port=[pscustomobject]@{};$port|Add-Member ScriptMethod Write {param([byte[]]$Payload,[int]$Offset,[int]$Count)Require ($script:requestSpy.state.write_attempts-eq1) 'Actual writer called before attempt latch';$script:requestSpy.calls++;$script:requestSpy.payload=[byte[]]$Payload.Clone()}
  $s=[pscustomobject]@{spec=[pscustomobject]@{role='ground'};workflow=[pscustomobject]@{arm_write_accepted=$true};workflow_failure='';product_observations=@([pscustomobject]@{crc_valid=$true});reader=$reader;port=$port}
  $actual=[scriptblock]::Create($requestBranches[0].Extent.Text);. $actual;. $actual
  Require ($paramDiagnosticsFailure-ceq''-and$serialWrites-eq4-and$script:requestSpy.calls-eq1-and$paramState.write_attempts-eq1) 'Actual Ground branch failed one-shot or changed private-write accounting'
}
Check 'actual-Ground-request-branch-does-not-retry-after-local-write-exception' {
  $ParamListDiagnostics=$true;$paramDiagnosticsFailure='';$paramState=New-RequestFixture;$paramDeliveredOffset=0L;$deadline=40000L;$serialWrites=3
  $clock=[pscustomobject]@{ElapsedTicks=100L};$reader=[pscustomobject]@{};$reader|Add-Member ScriptMethod GetStatus {return [pscustomobject]@{LastReadEndTicks=200L;PendingByteCount=0}}
  $port=[pscustomobject]@{};$port|Add-Member ScriptMethod Write {param([byte[]]$Payload,[int]$Offset,[int]$Count)$script:requestSpy.calls++;throw [IO.IOException]::new('FIXTURE_ACTUAL_BRANCH_EXCEPTION')}
  $s=[pscustomobject]@{spec=[pscustomobject]@{role='ground'};workflow=[pscustomobject]@{arm_write_accepted=$true};workflow_failure='';product_observations=@(1);reader=$reader;port=$port}
  $actual=[scriptblock]::Create($requestBranches[0].Extent.Text);. $actual;. $actual
  Require ($serialWrites-eq4-and$script:requestSpy.calls-eq1-and$paramState.write_attempts-eq1-and$null-eq$paramState.accepted_bytes) 'Actual request exception retried or hid attempt'
}
Check 'actual-request-branch-is-Ground-only-and-workflow-failure-closed' {
  $ParamListDiagnostics=$true;$paramDiagnosticsFailure='';$paramState=New-RequestFixture;$paramDeliveredOffset=0L;$deadline=40000L;$serialWrites=3;$clock=[pscustomobject]@{ElapsedTicks=100L}
  $reader=[pscustomobject]@{};$reader|Add-Member ScriptMethod GetStatus {return [pscustomobject]@{LastReadEndTicks=200L;PendingByteCount=0}}
  $port=[pscustomobject]@{};$port|Add-Member ScriptMethod Write {throw 'WRITER_MUST_NOT_BE_CALLED'}
  $s=[pscustomobject]@{spec=[pscustomobject]@{role='vehicle'};workflow=[pscustomobject]@{arm_write_accepted=$true};workflow_failure='';product_observations=@(1);reader=$reader;port=$port}
  $actual=[scriptblock]::Create($requestBranches[0].Extent.Text);. $actual;$s.spec.role='ground';$s.workflow_failure='FIXTURE_FAILED_WORKFLOW';. $actual
  Require ($paramDiagnosticsFailure-ceq''-and$serialWrites-eq3-and$paramState.write_attempts-eq0) 'Vehicle or failed workflow sent parameter request'
}
function ParamPriorityTick {$script:paramPriorityNow++;return $script:paramPriorityNow.ToString()}
function ParamPriorityFrame($State,[string]$Opcode,[string]$Role,[uint64]$DeviceMs=100){
  $arguments=@{Opcode=$Opcode;Role=$Role;ReaderSession=123;SlotNonce=$State.slot_nonce;BootId=$(if($Role-ceq'ground'){100}else{200});UsbEpoch=1;DeviceMs=$DeviceMs;Version=3}
  if($Opcode-ceq'HelloReply'){$arguments.GrantSession=661;$arguments.GrantCycle=2}else{$arguments.GrantSession=661;$arguments.GrantCycle=3;$arguments.SlotToken=77;$arguments.Generation=1}
  return ,(New-R19GrantReservationFrame @arguments)
}
function ParamPriorityObserve($State,[string]$Opcode,[string]$Role,[uint64]$DeviceMs=100){$t=ParamPriorityTick;Add-R19GrantReservationObservation $State $Role (ParamPriorityFrame $State $Opcode $Role $DeviceMs) $t $t 0}
function ParamPriorityNext($State){$command=Get-R19GrantReservationNextCommand $State (ParamPriorityTick);$null=Invoke-R19ReservationPrivateWrite $State $command {ParamPriorityTick} {param([byte[]]$Bytes)return [int]$Bytes.Length}}
function New-ParamPriorityRole($State,[string]$Role){
  $id='PARAM-PRIORITY-INERT-'+$Role;$State.runtime_fault_monitors.$Role.reader_id=$id
  $reader=[pscustomobject]@{data=([byte[]]@());poll_calls=0}
  $reader|Add-Member ScriptMethod GetSnapshot {[pscustomobject]@{Stopped=$false;Overflow=$false;Failure='';ByteCount=$this.data.Length;Blocks=$(if($this.data.Length){@([pscustomobject]@{Offset=0;Count=$this.data.Length;EndTicks=($script:paramPriorityNow-1)})}else{@()})}}
  $reader|Add-Member ScriptMethod ReadSlice {param([int]$Offset,[int]$Count)[byte[]]$bytes=New-Object byte[] $Count;[Array]::Copy($this.data,$Offset,$bytes,0,$Count);return ,$bytes}
  $reader|Add-Member ScriptMethod GetStatus {[pscustomobject]@{Stopped=$false;Overflow=$false;Failure='';FirstReadBeginTicks=1;PendingByteCount=0;LastReadEndTicks=($script:paramPriorityNow-1)}}
  $reader|Add-Member ScriptMethod PollBytes {throw 'FORBIDDEN PARAM_LIST fixture priority path must not consume PollBytes'}
  $port=[pscustomobject]@{role=$Role}
  $port|Add-Member ScriptMethod Write {param([byte[]]$Bytes,[int]$Offset,[int]$Count)$script:paramPriorityWrites.Add([pscustomobject]@{role=$this.role;bytes=([byte[]]$Bytes.Clone());ticks=$script:paramPriorityNow})}
  [pscustomobject]@{spec=[pscustomobject]@{role=$Role};reader=$reader;reader_id=$id;port=$port;workflow=[pscustomobject]@{arm_write_accepted=$true;reply_read_validated=$true};workflow_failure='';reservation_parser=(New-R19GrantReservationParser -AgreementEnabled $true);product_observations=@([pscustomobject]@{crc_valid=$true})}
}
Check 'actual-PARAM-then-native-Withdrawn-prioritizes-both-real-Aborts-without-ACK-or-reissue' {
  Require $script:priorityClosureVerified 'Cannot execute an unaudited priority closure'
  $script:paramPriorityNow=10L;$script:paramPriorityWrites=[Collections.Generic.List[object]]::new()
  $nonce=[Convert]::ToUInt64('521B000000000001',16).ToString()
  $reservationWorkflow=New-R19GrantReservationWorkflow -CandidateId PARAM-PRIORITY-INERT-FIXTURE -HandoffSha256 ('A'*64) -FlashSha256 ('B'*64) -ReaderSession 123 -SlotNonce $nonce -ClockDomainId capture-fixture-native-clock -Frequency 1000 -StartTicks 0 -CancellationEnabled $true -AgreementEnabled $true
  Set-R19GrantReservationPrerequisites $reservationWorkflow $true $true $true $true (ParamPriorityTick)
  ParamPriorityNext $reservationWorkflow;ParamPriorityNext $reservationWorkflow;ParamPriorityObserve $reservationWorkflow HelloReply ground;ParamPriorityObserve $reservationWorkflow HelloReply vehicle
  ParamPriorityNext $reservationWorkflow;ParamPriorityObserve $reservationWorkflow Prepared vehicle
  ParamPriorityNext $reservationWorkflow;ParamPriorityNext $reservationWorkflow;ParamPriorityNext $reservationWorkflow;ParamPriorityObserve $reservationWorkflow Bound ground
  ParamPriorityNext $reservationWorkflow;ParamPriorityObserve $reservationWorkflow CommitAck vehicle 110;ParamPriorityNext $reservationWorkflow;ParamPriorityObserve $reservationWorkflow CommitAck ground 120
  Require ($reservationWorkflow.status-ceq'CommittedReadyForOneParam') 'Actual v3 handshake did not reach the final PARAM gate'
  $reservationWorkflow.measurement_start_ticks='0';$measurementStart='0';$preparationDeadlineTicks='15000';$deadline=40000L;$serialWrites=3
  $ParamListDiagnostics=$true;$GrantReservationDiagnostics=$true;$GrantAgreementDiagnostics=$true;$paramDiagnosticsFailure='';$paramState=New-RequestFixture;$paramDeliveredOffset=0L
  $clock=[pscustomobject]@{};$clock|Add-Member ScriptProperty ElapsedTicks {$script:paramPriorityNow++;return $script:paramPriorityNow}
  $states=[Collections.Generic.List[object]]::new();$states.Add((New-ParamPriorityRole $reservationWorkflow vehicle));$states.Add((New-ParamPriorityRole $reservationWorkflow ground));$s=$states[1]
  $actualRequest=[scriptblock]::Create('[CmdletBinding()]param([switch]$GrantReservationDiagnostics)'+[Environment]::NewLine+$requestBranches[0].Extent.Text)
  . $actualRequest -GrantReservationDiagnostics
  Require ($paramDiagnosticsFailure-ceq''-and$paramState.write_attempts-eq1-and$reservationWorkflow.param_attempts-eq1-and$serialWrites-eq4) ('Actual PARAM branch did not send exactly once: '+$paramDiagnosticsFailure)
  Require ($script:paramPriorityWrites.Count-eq1-and([BitConverter]::ToString($script:paramPriorityWrites[0].bytes)-replace'-','')-ceq'FD02000063FFBE1500000101D507') 'Real PARAM writer did not receive the canonical 14-byte request'
  ParamPriorityObserve $reservationWorkflow GroundHeld ground 125
  $originalT0=$reservationWorkflow.param_write_started_ticks;$s=$states[0];$s.reader.data=ParamPriorityFrame $reservationWorkflow Withdrawn vehicle 130
  $block=[pscustomobject]@{Offset=0L;Data=$s.reader.data;EndTicks=([long](ParamPriorityTick))}
  # This is the exact production delivered-control branch, including its catch
  # and immediate priority call. No hand-written replacement dispatches Abort.
  . ([scriptblock]::Create($priorityDeliveredBranches[0].Extent.Text))
  Require ($reservationWorkflow.status-ceq'Failed'-and$reservationWorkflow.failure-ceq'ATTEMPTED_ABORT_WITHDRAWN_AFTER_REQUEST') 'Real native Withdrawn did not latch the immutable request failure'
  Require ($serialWrites-eq6-and$script:paramPriorityWrites.Count-eq3-and($script:paramPriorityWrites.role-join',')-ceq'ground,vehicle,ground') 'Both cleanup OUTs must follow one PARAM before waiting for either ACK'
  foreach($row in @($script:paramPriorityWrites|Select-Object -Skip 1)){Require ($row.bytes.Length-eq66-and$row.bytes[15]-eq21) 'Priority cleanup emitted a non-Abort frame'}
  Require ($reservationWorkflow.terminal_abort.phase-ceq'ABORT_UNCONFIRMED'-and$null-eq$reservationWorkflow.terminal_abort.roles.vehicle.ack-and$null-eq$reservationWorkflow.terminal_abort.roles.ground.ack) 'No-ACK fixture was promoted to successful cleanup'
  $s=$states[1];. $actualRequest -GrantReservationDiagnostics
  Require ($paramState.write_attempts-eq1-and$reservationWorkflow.param_attempts-eq1-and$reservationWorkflow.param_write_started_ticks-ceq$originalT0-and$script:paramPriorityWrites.Count-eq3-and$serialWrites-eq6) 'Failed workflow retried PARAM or cleanup, changed its origin, or hid a physical attempt'
  Require ($reservationWorkflow.commands.Count-le24-and$reservationWorkflow.terminal_abort.roles.vehicle.attempts-eq1-and$reservationWorkflow.terminal_abort.roles.ground.attempts-eq1) 'Cleanup exceeded the command/role attempt bounds'
}
Check 'actual-capture-heartbeat-input-is-the-validated-product-ledger' {
  $request=@($captureAst.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'Invoke-R19ParamListRequest'},$true));Require ($request.Count-eq1) 'Actual request must have one production call site'
  Require ((Get-CommandArgumentText $request[0] HeartbeatCount)-ceq'$s.product_observations.Count') 'Request must depend on CRC-validated product observations, not arbitrary raw bytes'
  Require ($productLoops.Count-eq1-and$productLoops[0].Body.Extent.Text.Contains('$s.product_observations.Add($product)')) 'Validated product foreach must own ledger admission'
  $decoders=@($productLoops[0].Condition.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'Add-R19TimedPathHeartbeatBytes'},$true))
  Require ($decoders.Count-eq1-and(Get-CommandArgumentText $decoders[0] ReadCompletedTicks)-ceq'([string]$block.EndTicks)') 'Product decoder must bind the actual native block completion'
  $private=@($captureAst.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'Invoke-R19TimedPathPrivateWrite'},$true))
  Require ($private.Count-eq2) 'Existing ClockRequest and diagnostic Arm sites must not gain a parameter-list/private write'
  Require (@($private|Where-Object{(Get-CommandArgumentText $_ Kind)-ceq'ClockRequest'}).Count-eq1-and@($private|Where-Object{(Get-CommandArgumentText $_ Kind)-ceq'Arm'}).Count-eq1) 'Existing private-write kinds changed'
}
Check 'actual-CRC-product-loop-keeps-request-closed-until-a-valid-heartbeat' {
  $ParamListDiagnostics=$true;$paramDiagnosticsFailure='';$paramState=New-RequestFixture;$paramDeliveredOffset=0L;$deadline=40000L;$serialWrites=3
  $clock=[pscustomobject]@{ElapsedTicks=300L};$domain='capture-fixture-native-clock';$frequency='1000'
  $reader=[pscustomobject]@{};$reader|Add-Member ScriptMethod GetStatus {return [pscustomobject]@{LastReadEndTicks=200L;PendingByteCount=0}}
  $port=[pscustomobject]@{};$port|Add-Member ScriptMethod Write {param([byte[]]$Payload,[int]$Offset,[int]$Count)$script:requestSpy.calls++}
  $s=[pscustomobject]@{spec=[pscustomobject]@{role='ground'};workflow=[pscustomobject]@{arm_write_accepted=$true};workflow_failure='';product_parser=(New-R19TimedPathHeartbeatParser);product_observations=[Collections.Generic.List[object]]::new();reader=$reader;port=$port}
  $decode=[scriptblock]::Create($productLoops[0].Extent.Text);$request=[scriptblock]::Create($requestBranches[0].Extent.Text)
  $block=[pscustomobject]@{Data=(HeartbeatFrame -BadCrc);Offset=0;EndTicks=200L};. $decode;. $request
  Require ($s.product_observations.Count-eq0-and$paramState.write_attempts-eq0-and$serialWrites-eq3) 'CRC-invalid Heartbeat allowed PARAM_REQUEST_LIST'
  $block=[pscustomobject]@{Data=(HeartbeatFrame);Offset=21;EndTicks=201L};. $decode;. $request
  Require ($s.product_observations.Count-eq1-and$paramState.write_attempts-eq1-and$script:requestSpy.calls-eq1-and$serialWrites-eq4) 'Actual valid Heartbeat did not release the one-shot request'
}
foreach($boundary in @(@{name='before';ticks=30099L;pending=0},@{name='equal';ticks=30100L;pending=0},@{name='pending';ticks=30101L;pending=1})){
  Check ('checkpoint-refuses-'+$boundary.name+'-native-watermark') {
    $state=New-RequestFixture;Invoke-RequestFixture $state|Out-Null;$directory=CaseDirectory ('checkpoint-'+$boundary.name)
    Require (-not(Update-R19ParamListCheckpoint -State $state -ReaderStatus ([pscustomobject]@{LastReadEndTicks=$boundary.ticks;PendingByteCount=$boundary.pending}) -OutputDirectory $directory)) 'Incomplete native watermark sealed snapshot'
    Require (-not$state.frozen-and-not[IO.File]::Exists((Join-Path $directory 'param_list_30s.json'))) 'Closed watermark still froze or saved window'
  }
}
Check 'strict-native-watermark-seals-once-and-durably-keeps-request-provenance' {
  $state=New-RequestFixture;Invoke-RequestFixture $state|Out-Null;$directory=CaseDirectory 'checkpoint-valid'
  $readerStatus=[pscustomobject]@{LastReadEndTicks=30101L;PendingByteCount=0}
  Require (Update-R19ParamListCheckpoint $state $readerStatus $directory) 'Strict native completion watermark not accepted'
  $path=Join-Path $directory 'param_list_30s.json';$firstHash=(Get-FileHash $path -Algorithm SHA256).Hash;$saved=[IO.File]::ReadAllText($path)|ConvertFrom-Json
  Require ($state.frozen-and$saved.snapshot_30s.sealed-and$saved.snapshot_30s.snapshot_complete-and$saved.request_attempts-eq1-and$saved.request.accepted_bytes-eq14-and$saved.clock_domain_id-ceq'capture-fixture-native-clock') 'Durable checkpoint lost native/request evidence'
  Require (-not(Update-R19ParamListCheckpoint $state $readerStatus $directory)-and(Get-FileHash $path -Algorithm SHA256).Hash-ceq$firstHash) 'Repeated checkpoint overwrote sealed evidence'
}
Check 'preexisting-checkpoint-is-never-overwritten' {
  $state=New-RequestFixture;Invoke-RequestFixture $state|Out-Null;$directory=CaseDirectory 'checkpoint-preexisting';$path=Join-Path $directory 'param_list_30s.json'
  Write-R19TimedPathJson $path ([pscustomobject]@{unchanged='ORIGINAL'});$firstHash=(Get-FileHash $path -Algorithm SHA256).Hash
  Reject {Update-R19ParamListCheckpoint $state ([pscustomobject]@{LastReadEndTicks=30101L;PendingByteCount=0}) $directory}
  Require ((Get-FileHash $path -Algorithm SHA256).Hash-ceq$firstHash) 'Checkpoint changed existing evidence'
}
Check 'actual-ingest-uses-native-completion-not-analysis-time-at-the-deadline' {
  $ParamListDiagnostics=$true;$paramDiagnosticsFailure='';$paramState=New-RequestFixture;Invoke-RequestFixture $paramState|Out-Null;$paramDeliveredOffset=0L;$s=[pscustomobject]@{spec=[pscustomobject]@{role='ground'}}
  $actual=[scriptblock]::Create($ingestBranches[0].Extent.Text)
  $block=[pscustomobject]@{Data=(ParamFrame 0);Offset=0L;EndTicks=30100L};. $actual
  $block=[pscustomobject]@{Data=(ParamFrame 1);Offset=37L;EndTicks=30101L};. $actual
  $snapshot=Get-R19ParamListSnapshot $paramState
  Require ($paramDiagnosticsFailure-ceq''-and$paramDeliveredOffset-eq74-and$snapshot.snapshot_30s.unique_count-eq1-and$snapshot.final.unique_count-eq2-and$snapshot.snapshot_30s.ledger[0].read_completed_ticks-eq30100) 'Actual ingest used analysis time or included data after deadline'
}
Check 'actual-stop-tail-reassembles-split-frame-with-final-native-completion-time' {
  $ParamListDiagnostics=$true;$paramDiagnosticsFailure='';$paramState=New-RequestFixture;Invoke-RequestFixture $paramState|Out-Null;$paramDeliveredOffset=20L
  [byte[]]$bytes=ParamFrame 0;Add-R19ParamListBytes $paramState ([byte[]]$bytes[0..19]) 30099 0
  $ground=New-CaptureState ground $bytes;$ground.snapshot.Blocks=@([pscustomobject]@{Offset=0L;Count=20;EndTicks=30099L},[pscustomobject]@{Offset=20L;Count=17;EndTicks=30101L});$ground.snapshot.LastReadEndTicks=30102L
  $states=@($ground);$OutputDirectory=CaseDirectory 'actual-tail';$actual=[scriptblock]::Create($tailBranches[0].Extent.Text);. $actual
  $snapshot=Get-R19ParamListSnapshot $paramState
  Require ($paramDiagnosticsFailure-ceq''-and$paramDeliveredOffset-eq37-and$paramState.frozen-and$snapshot.snapshot_30s.unique_count-eq0-and$snapshot.final.unique_count-eq1-and$snapshot.final.ledger[0].read_completed_ticks-eq30101) 'Post-stop tail used wrong offset, duplicate prefix, or analysis clock'
}
Check 'nine-hundred-thirty-two-values-completing-at-deadline-are-clean-not-product-acceptance' {
  $state=New-RequestFixture;Invoke-RequestFixture $state|Out-Null
  for($index=0;$index-lt932;$index++){Add-R19ParamListBytes $state (ParamFrame $index) 30100 $state.next_raw_offset}
  $directory=CaseDirectory '932-at-deadline';Require (Update-R19ParamListCheckpoint $state ([pscustomobject]@{LastReadEndTicks=30101L;PendingByteCount=0}) $directory) 'Full native window failed to checkpoint'
  $saved=[IO.File]::ReadAllText((Join-Path $directory 'param_list_30s.json'))|ConvertFrom-Json
  Require ($saved.snapshot_30s.unique_count-eq932-and$saved.snapshot_30s.errors.total-eq0-and@($saved.snapshot_30s.missing_indexes).Count-eq0-and$saved.snapshot_30s.result-ceq'COMPLETE_932_CLEAN'-and-not$saved.acceptance_eligible-and-not$saved.deployment_authorized) 'Full clean diagnostic window absent or overclaimed'
}
Check 'last-frame-completing-one-tick-late-leaves-exactly-one-missing-in-30s' {
  $state=New-RequestFixture;Invoke-RequestFixture $state|Out-Null
  for($index=0;$index-lt931;$index++){Add-R19ParamListBytes $state (ParamFrame $index) 30099 $state.next_raw_offset}
  [byte[]]$last=ParamFrame 931;Add-R19ParamListBytes $state ([byte[]]$last[0..19]) 30100 $state.next_raw_offset;Add-R19ParamListBytes $state ([byte[]]$last[20..36]) 30101 $state.next_raw_offset
  $directory=CaseDirectory '932-last-late';Update-R19ParamListCheckpoint $state ([pscustomobject]@{LastReadEndTicks=30102L;PendingByteCount=0}) $directory|Out-Null
  $saved=[IO.File]::ReadAllText((Join-Path $directory 'param_list_30s.json'))|ConvertFrom-Json
  Require ($saved.snapshot_30s.unique_count-eq931-and@($saved.snapshot_30s.missing_indexes).Count-eq1-and$saved.snapshot_30s.missing_indexes[0]-eq931-and$saved.final.unique_count-eq932-and-not$saved.snapshot_30s.all_932_received) 'Late final CRC was counted inside the 30-second window'
}
Check 'CRC-invalid-frame-does-not-fill-a-missing-index-in-actual-ingest' {
  $ParamListDiagnostics=$true;$paramDiagnosticsFailure='';$paramState=New-RequestFixture;Invoke-RequestFixture $paramState|Out-Null;$paramDeliveredOffset=0L;$s=[pscustomobject]@{spec=[pscustomobject]@{role='ground'}}
  $block=[pscustomobject]@{Data=(ParamFrame 0 -BadCrc);Offset=0L;EndTicks=200L};$actual=[scriptblock]::Create($ingestBranches[0].Extent.Text);. $actual
  $snapshot=Get-R19ParamListSnapshot $paramState;Require ($paramDiagnosticsFailure-ceq''-and$snapshot.snapshot_30s.unique_count-eq0-and$snapshot.snapshot_30s.errors.bad_crc-eq1-and@($snapshot.snapshot_30s.ledger).Count-eq0) 'Corrupt native block entered value ledger'
}
Check 'actual-summary-preserves-parameter-evidence-after-raw-streams' {
  $state=New-RequestFixture;Invoke-RequestFixture $state|Out-Null;Add-R19ParamListBytes $state (ParamFrame 0) 200 0
  $context=New-CaptureContext (Get-R19ParamListSnapshot $state);$directory=CaseDirectory 'summary-param-ledger'
  $vehicle=New-CaptureState vehicle ([byte[]]@(1,2,3));$ground=New-CaptureState ground (ParamFrame 0)
  $saved=Save-R19TimedPathCaptureEvidence -States @($vehicle,$ground) -OutputDirectory $directory -Context $context
  Require ($saved.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY'-and$saved.param_list_diagnostics_enabled-and$saved.param_list_diagnostics.snapshot_30s.unique_count-eq1-and$saved.param_list_diagnostics_failure-ceq'') 'Optional diagnostic ledger was not persisted'
  $roundTrip=[IO.File]::ReadAllText((Join-Path $directory 'summary.json'))|ConvertFrom-Json
  foreach($role in @('vehicle','ground')){$r=@($roundTrip.roles|Where-Object{$_.role-ceq$role})[0];Require ($r.raw_saved-and$r.raw_sha256-ceq(Get-FileHash (Join-Path $directory ($role+'.raw.bin')) -Algorithm SHA256).Hash) 'Raw stream durability/identity lost by optional ledger'}
  Require (-not$roundTrip.acceptance_eligible-and-not$roundTrip.root_cause_proven-and-not$roundTrip.deployment_authorized) 'Capture summary granted acceptance'
}
Check 'optional-ledger-serialization-failure-cannot-hide-either-raw-stream' {
  $state=New-RequestFixture;Invoke-RequestFixture $state|Out-Null;$context=New-CaptureContext (Get-R19ParamListSnapshot $state)
  # An integer-key dictionary is a deterministic JSON failure in both Windows
  # PowerShell 5.1 and PowerShell 7; depth overflow is silently stringified by 5.1.
  $bad=@{};$bad.Add(1,'FIXTURE_NON_STRING_JSON_KEY');$context.param_list_diagnostics=$bad
  $directory=CaseDirectory 'summary-param-failure';$vehicle=New-CaptureState vehicle ([byte[]]@(1,2,3));$ground=New-CaptureState ground ([byte[]]@(4,5,6))
  $threw=$false;try{Save-R19TimedPathCaptureEvidence -States @($vehicle,$ground) -OutputDirectory $directory -Context $context|Out-Null}catch{$threw=$true}
  foreach($role in @('vehicle','ground')){Require ([IO.File]::Exists((Join-Path $directory ($role+'.raw.bin')))) 'Optional metadata failure hid raw stream'}
  Require $threw 'Malformed optional ledger must fail serialization rather than silently fabricate a summary'
}
Check 'actual-plan-permit-pin-and-summary-context-bind-the-opt-in' {
  foreach($name in @('Get-R19TimedPathCapturePlan','Test-R19TimedPathExecutionPermit')){
    $commands=@($captureAst.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq$name},$true));Require ($commands.Count-eq1) ('Expected one actual '+$name+' call')
    Require ((Get-CommandArgumentText $commands[0] ParamListDiagnostics)-ceq'([bool]$ParamListDiagnostics)') ('Opt-in missing from '+$name)
  }
  Require ($captureSource.Contains("`$relative='tools/r19_param_list_diagnostics.ps1'")-and$captureSource.Contains('param_list_diagnostics_enabled')-and$captureSource.Contains('param_list_diagnostics_failure')) 'Optional source pin or summary diagnostic context missing'
  $saveFunction=@($captureAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Save-R19TimedPathCaptureEvidence'},$true))[0].Extent.Text
  Require ($saveFunction.IndexOf('Write-R19TimedPathRaw',[StringComparison]::Ordinal)-lt$saveFunction.IndexOf('Get-R19TimedPathRoleMetadata',[StringComparison]::Ordinal)) 'Optional metadata must not precede raw preservation'
}
$outerPath=Join-Path $RepoRoot 'tools/r19_timed_path_outer.ps1'
. $outerPath
function New-OuterContractSummary($Ledger){
  [pscustomobject]@{clock_domain_id='capture-fixture-native-clock';frequency='1000';measurement_start_ticks='0';measurement_end_ticks='40000';hardware_interaction=$false;serial_write_calls=(3+$Ledger.request_attempts);roles=@([pscustomobject]@{role='vehicle';writes=@([pscustomobject]@{kind='ClockRequest'})},[pscustomobject]@{role='ground';writes=@([pscustomobject]@{kind='ClockRequest'},[pscustomobject]@{kind='Arm'})});param_list_diagnostics_enabled=$true;param_list_diagnostics=$Ledger;param_list_diagnostics_failure=''}
}
Check 'actual-outer-contract-accepts-real-helper-zero-request-snapshot' {
  $state=New-RequestFixture;$ledger=Get-R19ParamListSnapshot $state;$summary=New-OuterContractSummary $ledger
  Assert-R19ParamListCaptureContract -Summary $summary -Enabled $true
  Require ($ledger.request_attempts-eq0-and$null-eq$ledger.request-and$ledger.result-ceq'NOT_ATTEMPTED'-and$summary.serial_write_calls-eq3) 'Zero attempt was fabricated as successful parameter acquisition'
}
Check 'actual-outer-contract-accepts-real-helper-partial-write-snapshot-without-promoting-it' {
  $state=New-RequestFixture;Invoke-RequestFixture $state -Writer {param([byte[]]$Payload)return [int]7}|Out-Null
  $ledger=Get-R19ParamListSnapshot $state;$summary=New-OuterContractSummary $ledger
  Assert-R19ParamListCaptureContract -Summary $summary -Enabled $true
  Require ($ledger.request_attempts-eq1-and$ledger.request.accepted_bytes-eq7-and$ledger.result-ceq'WRITE_INCOMPLETE'-and$summary.serial_write_calls-eq4-and-not$ledger.acceptance_eligible) 'Partial local write was promoted to acquisition or RF acceptance'
}
Check 'actual-outer-contract-accepts-real-helper-complete-932-native-deadline-checkpoint' {
  $checkpoint=Join-Path (CaseDirectory '932-at-deadline') 'param_list_30s.json'
  $ledger=[IO.File]::ReadAllText($checkpoint)|ConvertFrom-Json;$summary=New-OuterContractSummary $ledger
  Assert-R19ParamListCaptureContract -Summary $summary -Enabled $true
  Require ($ledger.snapshot_30s.unique_count-eq932-and$ledger.snapshot_30s.result-ceq'COMPLETE_932_CLEAN'-and$ledger.request.accepted_bytes-eq14-and$summary.serial_write_calls-eq4-and-not$ledger.acceptance_eligible) 'Real helper/capture checkpoint did not survive the outer contract'
}
foreach($corruption in @(
  @{name='mismatched-clock-domain';change={param($Summary)$Summary.clock_domain_id='WRONG-CLOCK'}},
  @{name='missing-product-write-attempt-count';change={param($Summary)$Summary.serial_write_calls=3}},
  @{name='two-request-attempts';change={param($Summary)$Summary.param_list_diagnostics.request_attempts=2}},
  @{name='string-local-acceptance';change={param($Summary)$Summary.param_list_diagnostics.request.accepted_bytes='14'}},
  @{name='fabricated-remote-delivery';change={param($Summary)$Summary.param_list_diagnostics.request.delivery_proven=$true}},
  @{name='request-outside-measurement';change={param($Summary)$Summary.measurement_end_ticks='99'}})){
  Check ('actual-outer-cross-contract-rejects-'+$corruption.name) {
    $state=New-RequestFixture;Invoke-RequestFixture $state|Out-Null;$summary=New-OuterContractSummary (Get-R19ParamListSnapshot $state)
    & $corruption.change $summary
    Reject {Assert-R19ParamListCaptureContract -Summary $summary -Enabled $true} 'Outer contract accepted corrupted actual helper evidence'
  }
}
# Exercise the exact CLI Save assignment as well as its callee. It must remain
# self-contained for legacy callers without helper/state locals in their scope.
$cliSaveStatements=@($captureAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left.Extent.Text-ceq'$summary'-and$_.Right.Extent.Text.StartsWith('Save-R19TimedPathCaptureEvidence ')})
Check 'actual-CLI-persistence-context-is-inline-and-inert' {
  Require ($cliSaveStatements.Count-eq1) 'Expected one actual CLI Save assignment'
  $saveCommands=@($cliSaveStatements[0].FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]},$true))
  Require ($saveCommands.Count-eq1-and$saveCommands[0].GetCommandName()-ceq'Save-R19TimedPathCaptureEvidence') 'CLI context must not invoke snapshot/helper/device commands'
  Require ((Get-CommandArgumentText $saveCommands[0] Context).StartsWith('([pscustomobject]@{')) 'CLI must materialize its inert context inline rather than depend on an undefined opt-in local'
  foreach($member in @($cliSaveStatements[0].FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true))){Require ($member.Member.Extent.Text-ceq'ToArray') 'CLI persistence assignment may only materialize inert arrays'}
}
$paramSwitchAst=@($captureAst.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'ParamListDiagnostics'})[0]
# A dot-sourced scriptblock without a param block gets an empty automatic
# PSBoundParameters dictionary. Reuse the real switch declaration so this AST
# fixture has the same bound presence/value as the real CLI assignment.
$script:cliParamSaveStatement=[scriptblock]::Create('[CmdletBinding()]'+[Environment]::NewLine+'param('+$paramSwitchAst.Extent.Text+')'+[Environment]::NewLine+$cliSaveStatements[0].Extent.Text)
function Invoke-InlinePersistenceFixture {
  [CmdletBinding()]
  param([string]$Name,[object]$Ledger,[switch]$ParamListDiagnostics)
  $OutputDirectory=CaseDirectory $Name
  $states=[Collections.Generic.List[object]]::new();$states.Add((New-CaptureState vehicle ([byte[]]@(1,2,3))));$states.Add((New-CaptureState ground ([byte[]]@(4,5,6))))
  $plan=[pscustomobject]@{candidate_id='INLINE-CONTEXT-SYNTHETIC-NOT-HARDWARE'};$Mode='ExplicitHostArm';$CaptureSeconds=40;$started='2026-10-24T00:00:00Z';$domain='capture-fixture-native-clock';$frequency='1000'
  $measurementStart='0';$measurementEnd='40000';$cleanupProven=$true;$hardware=$false;$serialWrites=3;$failure=''
  $identityEvidence=[Collections.Generic.List[object]]::new();$pinInputs=[Collections.Generic.List[object]]::new();$handoffSha='A'*64;$flashSha='B'*64;$repo=$RepoRoot;$readComparison=$null
  # Deliberately do not declare these opt-in locals for legacy/explicit-false.
  if($ParamListDiagnostics){$paramSnapshot=$Ledger;$paramDiagnosticsFailure='';$serialWrites+=$Ledger.request_attempts}
  $inlineBindings=@{};if($PSBoundParameters.ContainsKey('ParamListDiagnostics')){$inlineBindings.ParamListDiagnostics=[bool]$ParamListDiagnostics}
  . $script:cliParamSaveStatement @inlineBindings
  return [pscustomobject]@{directory=$OutputDirectory;summary=$summary;bound_contains_flag=$PSBoundParameters.ContainsKey('ParamListDiagnostics');bound_flag=[bool]$PSBoundParameters['ParamListDiagnostics']}
}
foreach($flagCase in @(@{name='default';specified=$false;enabled=$false},@{name='explicit-false';specified=$true;enabled=$false},@{name='enabled';specified=$true;enabled=$true})){
  Check ('actual-inline-CLI-summary-'+$flagCase.name+'-preserves-raw-and-option-schema') {
    $state=New-RequestFixture;Invoke-RequestFixture $state|Out-Null;Add-R19ParamListBytes $state (ParamFrame 0) 200 0;$ledger=Get-R19ParamListSnapshot $state
    $arguments=@{Name=('inline-'+$flagCase.name);Ledger=$ledger};if($flagCase.specified){$arguments.ParamListDiagnostics=[bool]$flagCase.enabled}
    $case=Invoke-InlinePersistenceFixture @arguments
    Require ($case.bound_contains_flag-eq$flagCase.specified-and$case.bound_flag-eq$flagCase.enabled) 'Switch presence/value differs at actual CLI assignment'
    $saved=[IO.File]::ReadAllText((Join-Path $case.directory 'summary.json'))|ConvertFrom-Json
    Require ($saved.result-ceq'CAPTURE_COMPLETE_OBSERVATIONS_ONLY') 'Inline context did not preserve normal observation-only capture'
    foreach($role in @('vehicle','ground')){
      $row=@($saved.roles|Where-Object{$_.role-ceq$role})[0];$path=Join-Path $case.directory ($role+'.raw.bin')
      Require ($row.raw_saved-and$row.raw_bytes-eq3-and$row.raw_sha256-ceq(Get-FileHash $path -Algorithm SHA256).Hash) 'Inline context lost a durable raw stream or hash'
    }
    if($flagCase.enabled){
      Require ($saved.param_list_diagnostics_enabled-is[bool]-and$saved.param_list_diagnostics_enabled-and$saved.param_list_diagnostics_failure-ceq'') 'Enabled CLI did not publish explicit optional evidence'
      Require ($saved.param_list_diagnostics.schema-ceq'vc-lora-r19-param-list-diagnostics-v1'-and$saved.param_list_diagnostics.request_attempts-eq1-and$saved.param_list_diagnostics.request.accepted_bytes-eq14-and$saved.param_list_diagnostics.snapshot_30s.unique_count-eq1-and$saved.serial_write_calls-eq4) 'Actual helper snapshot changed through inline context persistence'
    }else{
      foreach($field in @('param_list_diagnostics_enabled','param_list_diagnostics','param_list_diagnostics_failure')){Require ($null-eq$saved.PSObject.Properties[$field]) 'Legacy/false CLI unexpectedly publishes optional parameter fields'}
      Require ($saved.serial_write_calls-eq3) 'Disabled option changed private-write accounting'
    }
    Require (-not$saved.acceptance_eligible-and-not$saved.deployment_authorized-and-not$saved.root_cause_proven) 'Inline persistence claimed product acceptance'
  }
}

# This is the actual pre-ImportOnly capture prefix, not a substitute import
# sequence. Only the module-root literal is rebound for in-memory execution.
$importOnlyBoundary=$captureSource.IndexOf('if($ImportOnly){',[StringComparison]::Ordinal)
$moduleRoot=(Join-Path $RepoRoot 'tools').Replace("'","''")
$capturePrefix=$captureSource.Substring(0,$importOnlyBoundary).Replace('$PSScriptRoot',("'"+$moduleRoot+"'"))
$script:boundCaptureProbe=[scriptblock]::Create($capturePrefix+[Environment]::NewLine+'[pscustomobject]@{bound_contains_flag=$PSBoundParameters.ContainsKey("ParamListDiagnostics");bound_flag=[bool]$PSBoundParameters["ParamListDiagnostics"];variable_flag=[bool]$ParamListDiagnostics}')
$outerEntryPath=Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1'
$outerEntrySource=[IO.File]::ReadAllText($outerEntryPath);$outerTokens=$null;$outerErrors=$null;$outerEntryAst=[Management.Automation.Language.Parser]::ParseInput($outerEntrySource,[ref]$outerTokens,[ref]$outerErrors)
$captureFlagBranches=@($outerEntryAst.FindAll({param($node)$node-is[Management.Automation.Language.IfStatementAst]-and$node.Clauses[0].Item1.Extent.Text-ceq"`$PSBoundParameters['ParamListDiagnostics']"-and$node.Extent.Text.Contains('$captureArguments')},$true))
Check 'actual-parent-capture-argv-has-one-pure-param-list-flag-branch' {
  Require ($outerErrors.Count-eq0-and$captureFlagBranches.Count-eq1) 'Cannot identify one actual parent capture opt-in branch'
  Require (@($captureFlagBranches[0].FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-or$node-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true)).Count-eq0) 'Parent flag branch must be inert argument construction only'
}
$outerParamSwitchAst=@($outerEntryAst.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'ParamListDiagnostics'})[0]
$script:captureFlagBranch=[scriptblock]::Create('[CmdletBinding()]'+[Environment]::NewLine+'param('+$outerParamSwitchAst.Extent.Text+')'+[Environment]::NewLine+$captureFlagBranches[0].Extent.Text)
function Invoke-ParentArgumentFixture {
  [CmdletBinding()]
  param([switch]$ParamListDiagnostics)
  $captureArguments=@('-Execute','-TimedPathMode','ExplicitHostArm')
  $flagBindings=@{};if($PSBoundParameters.ContainsKey('ParamListDiagnostics')){$flagBindings.ParamListDiagnostics=[bool]$ParamListDiagnostics}
  . $script:captureFlagBranch @flagBindings
  return [pscustomobject]@{arguments=@($captureArguments);bound_contains_flag=$PSBoundParameters.ContainsKey('ParamListDiagnostics');bound_flag=[bool]$PSBoundParameters['ParamListDiagnostics']}
}
foreach($flagCase in @(@{name='default';specified=$false;enabled=$false},@{name='explicit-false';specified=$true;enabled=$false},@{name='enabled';specified=$true;enabled=$true})){
  Check ('actual-capture-prefix-preserves-bound-switch-'+$flagCase.name+'-after-nested-imports') {
    $arguments=@{ImportOnly=$true};if($flagCase.specified){$arguments.ParamListDiagnostics=[bool]$flagCase.enabled};if($flagCase.enabled){$arguments.Mode='ExplicitHostArm';$arguments.AuxReadinessDiagnostics=$true;$arguments.DiagnosticUsbFailureDiagnostics=$true}
    $probe=& $script:boundCaptureProbe @arguments
    Require ($probe.bound_contains_flag-eq$flagCase.specified-and$probe.bound_flag-eq$flagCase.enabled-and$probe.variable_flag-eq$flagCase.enabled) 'Nested definition import lost or invented CLI switch binding'
  }
  Check ('actual-parent-argv-forwards-param-list-switch-'+$flagCase.name+'-without-implicit-opt-in') {
    $arguments=@{};if($flagCase.specified){$arguments.ParamListDiagnostics=[bool]$flagCase.enabled}
    $probe=Invoke-ParentArgumentFixture @arguments
    Require ($probe.bound_contains_flag-eq$flagCase.specified-and$probe.bound_flag-eq$flagCase.enabled-and@($probe.arguments|Where-Object{$_-ceq'-ParamListDiagnostics'}).Count-eq$(if($flagCase.enabled){1}else{0})) 'Actual parent branch changed explicit flag presence/value or appended duplicates'
  }
}
$failed=@($script:results|Where-Object{-not$_.passed})
$summary=[ordered]@{schema='vc-lora-r19-param-list-capture-contract-v1';result=$(if($failed.Count){'FAIL'}else{'PASS'});hardware_interaction=$false;com_open_attempts=0;native_process_calls=0;permit_consumed=$false;passed_count=$script:results.Count-$failed.Count;failed_count=$failed.Count;checks=$script:results.ToArray();capture_sha256=(Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash;helper_sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot 'tools/r19_param_list_diagnostics.ps1') -Algorithm SHA256).Hash;outer_sha256=(Get-FileHash -LiteralPath $outerPath -Algorithm SHA256).Hash;test_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash}
$summary|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding utf8
$summary|ConvertTo-Json -Depth 20
if($failed.Count){exit 1}
