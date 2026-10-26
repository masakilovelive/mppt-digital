[CmdletBinding()]
param([string]$RepoRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=if($RepoRoot){(Resolve-Path -LiteralPath $RepoRoot).Path}else{Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$runner=Join-Path $root 'tools/run_r19_timed_path_capture.ps1'
$script:entryChecks=0
$script:entryFailures=[Collections.Generic.List[string]]::new()
$script:forbiddenCalls=[Collections.Generic.List[string]]::new()
$script:entryObservations=[Collections.Generic.List[object]]::new()
$script:entryCaseResults=[Collections.Generic.List[object]]::new()
function Check-Entry([bool]$Value,[string]$Name){
  $script:entryChecks++
  if(-not$Value){$script:entryFailures.Add($Name)}
}
function Need-SafeEntry([bool]$Value,[string]$Name){if(-not$Value){throw ('Unsafe entrypoint fixture; real runner was NOT invoked: '+$Name)}}
function Get-EntryFileSha([string]$Path){
  $hasher=[Security.Cryptography.SHA256]::Create()
  try{return ([BitConverter]::ToString($hasher.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-','')}finally{$hasher.Dispose()}
}
function Test-EntryExecutableAst($Node){
  $ancestor=$Node.Parent
  while($null-ne$ancestor){
    if($ancestor-is[Management.Automation.Language.FunctionDefinitionAst]){return $false}
    $ancestor=$ancestor.Parent
  }
  return $true
}

# Before invoking the real runner, prove that every tested negative path has an
# explicit early stop before COM, process, PnP, permit consumption or output IO.
# Shims are a second barrier, not permission to execute a weakened live guard.
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$parseErrors)
Need-SafeEntry ($parseErrors.Count-eq0) 'runner must parse'
$ifs=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and(Test-EntryExecutableAst $n)},$true))
$importGuard=@($ifs|Where-Object{$_.Clauses[0].Item1.Extent.Text-ceq'$ImportOnly'})
Need-SafeEntry ($importGuard.Count-eq1) 'one explicit ImportOnly guard'
Need-SafeEntry ($importGuard[0].Extent.Text.Contains('ImportOnly cannot execute')) 'ImportOnly plus Execute must reject'
Need-SafeEntry (@($importGuard[0].FindAll({param($n)$n-is[Management.Automation.Language.ReturnStatementAst]},$true)).Count-ge1) 'ImportOnly must return'
$executeGuard=@($ifs|Where-Object{$_.Clauses[0].Item1.Extent.Text-match'^-not\s*\$Execute$'})
Need-SafeEntry ($executeGuard.Count-eq1) 'one explicit no-Execute guard'
Need-SafeEntry (@($executeGuard[0].FindAll({param($n)$n-is[Management.Automation.Language.ThrowStatementAst]},$true)).Count-ge1) 'no Execute must throw'
$pathGuard=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.ForEachStatementAst]-and(Test-EntryExecutableAst $n)-and$n.Extent.Text.Contains('All explicit diagnostic paths are required')},$true))
Need-SafeEntry ($pathGuard.Count-eq1) 'explicit required-path guard'
foreach($name in @('OutputDirectory','CandidateHandoffPath','CandidateFlashEvidencePath','ExecutionPermitPath')){
  Need-SafeEntry ($pathGuard[0].Condition.Extent.Text.Contains(('$'+$name))) ('blank guard checks '+$name)
}
Need-SafeEntry ($pathGuard[0].Body.Extent.Text.Contains('IsNullOrWhiteSpace')) 'blank guard rejects whitespace'
$outputProbe=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]-and(Test-EntryExecutableAst $n)-and$n.GetCommandName()-ceq'Test-Path'-and$n.Extent.Text.Contains('$OutputDirectory')},$true))
Need-SafeEntry ($outputProbe.Count-eq1) 'one output existence probe is safe stop point'
Need-SafeEntry ($importGuard[0].Extent.EndOffset-lt$executeGuard[0].Extent.StartOffset-and$executeGuard[0].Extent.EndOffset-lt$pathGuard[0].Extent.StartOffset-and$pathGuard[0].Extent.EndOffset-lt$outputProbe[0].Extent.StartOffset) 'ImportOnly, Execute and path guards precede stop point'
$effects=@($ast.FindAll({param($n)
  if(-not(Test-EntryExecutableAst $n)){return $false}
  if($n-is[Management.Automation.Language.CommandAst]){
    return $n.GetCommandName()-cin@('Get-CimInstance','Get-PnpDevice','Get-PnpDeviceProperty','Get-Process','Start-Process','Add-Type','Get-R19TimedPathCapturePlan','Test-R19TimedPathExecutionPermit','New-Item','Set-Content','Out-File','Write-R19TimedPathJson')
  }
  if($n-is[Management.Automation.Language.InvokeMemberExpressionAst]){
    return $n.Extent.Text-match'(?i)\[(?:System\.)?IO\.(?:FileStream|Ports\.SerialPort|Directory|File)\].*(?:new|Create|Write)'
  }
  return $false
},$true))
Need-SafeEntry ($effects.Count-ge5) 'protected live effects were found, not silently ignored'
foreach($effect in $effects){Need-SafeEntry ($effect.Extent.StartOffset-gt$outputProbe[0].Extent.EndOffset) ('live effect before test stop point: '+$effect.Extent.Text)}

$relativeInputs=@('tools/run_r19_timed_path_capture.ps1','tools/r19_timed_path_acquisition.ps1','tools/r19_host_readiness_wire.ps1','tools/r19_usb_clock_correlation.ps1','tools/r19_host_readiness_workflow.ps1','tools/r19_timed_path_trace.ps1')
$hashes=@(foreach($relative in $relativeInputs){[pscustomobject]@{path=$relative;sha256=(Get-EntryFileSha (Join-Path $root $relative))}})
foreach($relative in $relativeInputs[1..5]){
  $sourceAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative),[ref]$tokens,[ref]$parseErrors)
  Need-SafeEntry ($parseErrors.Count-eq0) ('dependency parses: '+$relative)
  $hardwareNodes=@($sourceAst.FindAll({param($n)
    if($n-is[Management.Automation.Language.CommandAst]){
      if($n.GetCommandName()-ceq'Add-Type'-and$n.Extent.Text-ceq'Add-Type -AssemblyName System.Numerics'){return $false}
      return $n.GetCommandName()-cin@('Get-CimInstance','Get-PnpDevice','Get-PnpDeviceProperty','Get-Process','Start-Process','Add-Type')
    }
    return $n-is[Management.Automation.Language.TypeExpressionAst]-and$n.TypeName.FullName-match'(?i)(SerialPort|FileStream)$'
  },$true))
  Need-SafeEntry ($hardwareNodes.Count-eq0) ('import dependency contains no native acquisition: '+$relative)
}

function Stop-EntryForbidden([string]$Name){(Get-Variable -Name forbiddenCalls -ValueOnly).Add($Name);throw ('FORBIDDEN_OFFLINE_ENTRY_CALL: '+$Name)}
function Get-CimInstance {Stop-EntryForbidden 'Get-CimInstance'}
function Get-PnpDevice {Stop-EntryForbidden 'Get-PnpDevice'}
function Get-PnpDeviceProperty {Stop-EntryForbidden 'Get-PnpDeviceProperty'}
function Get-Process {Stop-EntryForbidden 'Get-Process'}
function Start-Process {Stop-EntryForbidden 'Start-Process'}
function Add-Type {
  [CmdletBinding()]
  param([string]$AssemblyName,[string]$TypeDefinition)
  if($AssemblyName-ceq'System.Numerics'-and[string]::IsNullOrEmpty($TypeDefinition)){
    Microsoft.PowerShell.Utility\Add-Type -AssemblyName System.Numerics
    return
  }
  Stop-EntryForbidden 'Add-Type'
}
function New-Item {Stop-EntryForbidden 'New-Item'}
function Set-Content {Stop-EntryForbidden 'Set-Content'}
function Out-File {Stop-EntryForbidden 'Out-File'}
function Test-Path {
  [CmdletBinding()]
  param([string]$LiteralPath)
  # This is the first runner operation after all path guards. Stop here before
  # resolving/reading even a fake permit, and capture the actual caller binding.
  $values=[ordered]@{probe_path=$LiteralPath}
  foreach($name in @('ImportOnly','Execute','RepoRoot','OutputDirectory','CandidateHandoffPath','CandidateFlashEvidencePath','ExecutionPermitPath','Mode','CaptureSeconds','AuxReadinessDiagnostics')){
    $values[$name]=Get-Variable -Name $name -Scope 1 -ValueOnly
  }
  # A function inherited by another script resolves $script: to that script's
  # scope. Look up the deliberately inherited harness ledger dynamically instead.
  (Get-Variable -Name entryObservations -ValueOnly).Add([pscustomobject]$values)
  throw 'OFFLINE_ENTRY_STOP_BEFORE_PERMIT_AND_OUTPUT'
}
function Invoke-EntryCase([hashtable]$Arguments){
  $errorText='';$output=@();$before=$script:entryObservations.Count
  try{$output=@(& $runner @Arguments)}catch{$errorText=$_.Exception.Message}
  $result=[pscustomobject]@{kind='runner';arguments=[pscustomobject]$Arguments;error=$errorText;output_count=$output.Count;probe_calls=($script:entryObservations.Count-$before)}
  $script:entryCaseResults.Add($result)
  return $result
}
function Invoke-SupportEntryCase([hashtable]$Arguments){
  $errorText='';$output=@()
  try{$output=@(& (Join-Path $root 'tools/r19_timed_path_acquisition.ps1') @Arguments)}catch{$errorText=$_.Exception.Message}
  $result=[pscustomobject]@{kind='support';arguments=[pscustomobject]$Arguments;error=$errorText;output_count=$output.Count}
  $script:entryCaseResults.Add($result)
  return $result
}

$r=Invoke-SupportEntryCase @{ImportOnly=$true}
Check-Entry ($r.error-ceq''-and$r.output_count-eq0) 'support ImportOnly defines helpers without acquisition'
foreach($arguments in @(@{},@{ImportOnly=$false})){
  $r=Invoke-SupportEntryCase $arguments
  Check-Entry ($r.error-like'This is an ImportOnly support module.*'-and$r.output_count-eq0) ('support rejects direct execution, bound arguments='+$arguments.Count)
}
$r=Invoke-EntryCase @{ImportOnly=$true}
Check-Entry ($r.error-ceq''-and$r.output_count-eq0-and$r.probe_calls-eq0) 'ImportOnly defines helpers and returns without live IO'
$r=Invoke-EntryCase @{ImportOnly=$true;Execute=$true}
Check-Entry ($r.error-like'*ImportOnly cannot execute*'-and$r.probe_calls-eq0) 'ImportOnly plus Execute explicitly rejects'
$r=Invoke-EntryCase @{}
Check-Entry ($r.error-like'*requires Execute and a fresh one-time outer permit*'-and$r.probe_calls-eq0) 'missing Execute rejects rather than silent ImportOnly success'
$r=Invoke-EntryCase @{Execute=$true;RepoRoot=$root;OutputDirectory='';CandidateHandoffPath='';CandidateFlashEvidencePath='';ExecutionPermitPath=''}
Check-Entry ($r.error-like'*All explicit diagnostic paths are required*'-and$r.probe_calls-eq0) 'Execute with every blank diagnostic path rejects rather than import return'
foreach($entryCase in @([pscustomobject]@{mode='SyncOnly';aux=$false},[pscustomobject]@{mode='ExplicitHostArm';aux=$false},[pscustomobject]@{mode='ExplicitHostArm';aux=$true})){
  $mode=$entryCase.mode
  $caseLabel=$mode+$(if($entryCase.aux){'-AuxReadinessDiagnostics'}else{''})
  $prefix=Join-Path $root ('__offline_capture_must_not_exist_'+[Guid]::NewGuid().ToString('N'))
  $arguments=@{Execute=$true;ImportOnly=$false;RepoRoot=$root;OutputDirectory=($prefix+'.output');CandidateHandoffPath=($prefix+'.handoff.json');CandidateFlashEvidencePath=($prefix+'.flash.json');ExecutionPermitPath=($prefix+'.permit.json');Mode=$mode;CaptureSeconds=40}
  if($entryCase.aux){$arguments.AuxReadinessDiagnostics=$true}
  $r=Invoke-EntryCase $arguments
  Check-Entry ($r.error-ceq'OFFLINE_ENTRY_STOP_BEFORE_PERMIT_AND_OUTPUT'-and$r.probe_calls-eq1) ($caseLabel+' explicit arguments reach safe validation stop instead of silent return')
  if($r.probe_calls-eq1){
    $seen=$script:entryObservations[$script:entryObservations.Count-1]
    foreach($name in $arguments.Keys){Check-Entry ([string]$seen.$name-ceq[string]$arguments[$name]) ($caseLabel+' import preserves bound '+$name)}
    Check-Entry ([bool]$seen.AuxReadinessDiagnostics-eq$entryCase.aux) ($caseLabel+' import preserves exact AUX diagnostic selection')
    Check-Entry ($seen.probe_path-ceq$arguments.OutputDirectory) ($caseLabel+' validates exact caller output path')
  }
  foreach($suffix in @('.output','.handoff.json','.flash.json','.permit.json','.permit.json.consumed')){
    Check-Entry (-not(Microsoft.PowerShell.Management\Test-Path -LiteralPath ($prefix+$suffix))) ($caseLabel+' no created artifact '+$suffix)
  }
}
Check-Entry ($script:forbiddenCalls.Count-eq0) 'PnP/process/COM supporting commands were never invoked'
foreach($input in $hashes){Check-Entry ((Get-EntryFileSha (Join-Path $root $input.path))-ceq$input.sha256) ('source unchanged throughout entrypoint tests: '+$input.path)}
$evidence=[pscustomobject][ordered]@{schema='vc-lora-r19-timed-path-capture-entrypoint-offline-v1';result=$(if($script:entryFailures.Count-eq0){'PASS'}else{'FAIL'});powershell=$PSVersionTable.PSVersion.ToString();checks=$script:entryChecks;failures=$script:entryFailures.ToArray();ast_safety_preflight=$true;hardware_interaction=$false;com_open_attempts=0;permit_consumed=$false;forbidden_calls=$script:forbiddenCalls.ToArray();safe_probe_observations=$script:entryObservations.ToArray();case_results=$script:entryCaseResults.ToArray();source_hashes=$hashes}
Write-Output ($evidence|ConvertTo-Json -Depth 20 -Compress)
if($script:entryFailures.Count-gt0){throw ('TIMED_PATH_CAPTURE_ENTRYPOINT FAIL '+$script:entryFailures.Count+' / '+$script:entryChecks+': '+($script:entryFailures-join'; '))}
Write-Output ('TIMED_PATH_CAPTURE_ENTRYPOINT PASS '+$script:entryChecks+' checks; no hardware interaction')
