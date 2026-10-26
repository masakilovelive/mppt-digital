[CmdletBinding()]
param([string]$RepoRoot='', [string]$SourceToolPath='', [string]$OutputDirectory='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
if(-not$SourceToolPath){$SourceToolPath=Join-Path $RepoRoot 'tools/invoke_r19_candidate_app_flash_hil.ps1'}
if(-not$OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('runs/validation/R19-GRANT-RESERVATION-INTEGRATION-OFFLINE-001/20261025T-fix/operation-regression-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))}
if(Test-Path -LiteralPath $OutputDirectory){throw 'A fresh offline regression directory is required'}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$script:checks=0;$script:mockExternalCalls=0;$script:mockBehavior='pass'
function Check([bool]$Value,[string]$Name){$script:checks++;if(-not$Value){throw ('FAIL '+$Name)}}
function ReadUtf8Json([string]$Path){[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json}
function Same($A,$B){($A|ConvertTo-Json -Depth 30 -Compress)-ceq($B|ConvertTo-Json -Depth 30 -Compress)}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($SourceToolPath,[ref]$tokens,[ref]$errors)
Check (@($errors).Count-eq0) 'Actual production function source parses'
$functions=@('Assert-Condition','Get-Sha256','Write-DurableBytes','Write-DurableText','Write-DurableJson','Get-RelativePath','New-ExactArgv','Assert-SafeArgv','Invoke-ToolOperation','Invoke-ReenumerationOperation')
foreach($name in $functions){
  $nodes=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq$name})
  Check ($nodes.Count-eq1) ('Actual function exists once '+$name)
  . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$utf8=[Text.UTF8Encoding]::new($false);$newline=[Environment]::NewLine
# Keep the actual durable serializer/readback. This wrapper only counts writes.
$script:actualJsonWriter=(Get-Item Function:Write-DurableJson).ScriptBlock
$script:jsonWritePaths=[Collections.Generic.List[string]]::new()
function Write-DurableJson([string]$Path,[object]$Value){$script:jsonWritePaths.Add($Path);&$script:actualJsonWriter $Path $Value}

# These are the only external-service seams. Neither the tool main nor any
# native executable, COM/PnP/process query, reset or flash operation is called.
function Assert-NoCompetingClients {[pscustomobject]@{offline_mock=$true;known_serial_clients=@();explicit_com3_or_com6_refs=@()}}
function Wait-RoleIdentity([object]$Role,[int]$TimeoutSeconds=20){[pscustomobject]@{port=$Role.port;offline_mock=$true;name='OFFLINE-FIXTURE'}}
function Invoke-CapturedEspTool([string]$Prefix,[string[]]$Tokens){
  $script:mockExternalCalls++
  $kind=$Tokens[10]
  if($kind-ceq'write-flash'){
    Check (Test-Path -LiteralPath (Join-Path $evidence ($Prefix+'.intent.json'))) 'Actual write intent precedes mocked external writer'
    Check ($script:ExternalActions.firmware_write_attempted-and$script:ExternalActions.firmware_may_have_changed) 'Actual attempted-write flags precede mocked writer'
    $stdout='Hash of data verified.'
  }elseif($kind-ceq'verify-flash'){$stdout='Verification successful (digest matched).'}
  else{Check ($kind-ceq'read-mac') 'Only frozen harmless operation shapes reach mock';$stdout='MAC: '+$script:mockMac}
  $exit=0;$stderr=''
  if($script:mockBehavior-ceq'wrong-mac'){$stdout='MAC: ff:ff:ff:ff:ff:ff'}
  elseif($script:mockBehavior-ceq'bad-exit'){$exit=5;$stderr='OFFLINE_INJECTED_ERROR'}
  elseif($script:mockBehavior-ceq'missing-marker'){$stdout='OFFLINE_NO_SUCCESS_MARKER'}
  $out=Join-Path $evidence ($Prefix+'.stdout.log');$err=Join-Path $evidence ($Prefix+'.stderr.log')
  Write-DurableText $out $stdout;Write-DurableText $err $stderr;Write-DurableText (Join-Path $evidence ($Prefix+'.exit.txt')) ([string]$exit)
  [pscustomobject]@{exit_code=$exit;invoke_failure=$null;stdout_path=$out;stderr_path=$err;stdout_text=$stdout;stderr_text=$stderr}
}
$operationFields=@('label','role','kind','result','exit_code','issues','parsed_mac','identity_before','competing_client_gate','argv_path','stdout_path','stderr_path','application_sha256')
$reenumerationFields=@('label','role','kind','result','exit_code','issues','identity')
$cases=[Collections.Generic.List[object]]::new()
foreach($enabled in @($false,$true)){
  foreach($isRollback in @($false,$true)){
    $grantReservationEnabled=$enabled
    $Bundle=[pscustomobject]@{offline_fixture=$true} # non-null exercises the missed live branch
    Remove-Variable -Name modeHandoff -ErrorAction SilentlyContinue
    $script:Operations=[Collections.ArrayList]::new();$script:RollbackOperations=[Collections.ArrayList]::new()
    $script:SuccessfulCandidateWrites=0;$script:SuccessfulRollbackWrites=0
    $script:ExternalActions=[ordered]@{firmware_write_attempted=$false;firmware_may_have_changed=$false}
    $script:CandidateWriteMayHaveChangedDevice=$false
    $evidence=Join-Path $OutputDirectory ('reservation-'+$enabled.ToString()+'-rollback-'+$isRollback.ToString())
    [void][IO.Directory]::CreateDirectory($evidence)
    $application=Join-Path $evidence 'synthetic.application.bin'
    [IO.File]::WriteAllBytes($application,[byte[]]@(0,1,2,253,254,255))
    foreach($roleName in @('vehicle','ground')){
      $role=[pscustomobject]@{key=$roleName;name=('OFFLINE-'+$roleName);port=('OFFLINE-PORT-'+$roleName);mac=$(if($roleName-ceq'vehicle'){'01:02:03:04:05:06'}else{'06:05:04:03:02:01'})}
      $script:mockMac=$role.mac
      foreach($kind in @('read_mac','write','verify','reenumeration')){
        $list=$script:Operations
        if($isRollback){$list=$script:RollbackOperations}
        $countBefore=$list.Count;$writesBefore=$script:jsonWritePaths.Count
        $label=$roleName+'_'+$kind
        if($kind-ceq'reenumeration'){Invoke-ReenumerationOperation $label $role $isRollback}
        else{Invoke-ToolOperation $label $role $kind $(if($kind-ceq'read_mac'){''}else{$application}) $isRollback}
        Check ($list.Count-eq$countBefore+1) ('Real '+$kind+' appends exactly once flag='+$enabled+' rollback='+$isRollback)
        $record=$list[$list.Count-1]
        $path=Join-Path $evidence $record.record_path
        $decoded=ReadUtf8Json $path
        $expected=if($kind-ceq'reenumeration'){$reenumerationFields}else{$operationFields}
        $actual=@($decoded.PSObject.Properties.Name)
        Check ($actual.Count-eq$expected.Count-and@($actual|Where-Object{$expected-cnotcontains$_}).Count-eq0) ('Exact legacy per-operation schema '+$kind)
        Check (@($script:jsonWritePaths.GetRange($writesBefore,$script:jsonWritePaths.Count-$writesBefore)|Where-Object{$_-ceq$path}).Count-eq1) ('One durable record write '+$kind)
        Check ($decoded.result-ceq'PASS'-and$decoded.kind-ceq$kind-and$decoded.role-ceq$roleName-and$decoded.exit_code-eq0-and$decoded.issues-is[array]-and$decoded.issues.Count-eq0) ('Actual operation readback fields '+$kind)
        Check ((Get-Sha256 $path)-ceq$record.record_sha256) ('Appended record SHA matches bytes '+$kind)
        foreach($forbidden in @('grant_reservation_diagnostics','reader_schema','authorization_scope','next_required_action')){Check ($null-eq$decoded.PSObject.Properties[$forbidden]) ('Aggregate field absent on operation '+$forbidden)}
        if($kind-ceq'read_mac'){Check ($decoded.parsed_mac-ceq$role.mac-and$null-eq$decoded.application_sha256) 'Read-MAC is identity only'}
        elseif($kind-cne'reenumeration'){Check ($decoded.application_sha256-ceq(Get-Sha256 $application)) 'Write/verify retain exact mock image SHA'}
      }
    }
    Check ($script:Operations.Count-eq$(if($isRollback){0}else{8})-and$script:RollbackOperations.Count-eq$(if($isRollback){8}else{0})) 'Candidate and rollback ledgers remain separate'
    Check ($script:SuccessfulCandidateWrites-eq$(if($isRollback){0}else{2})-and$script:SuccessfulRollbackWrites-eq$(if($isRollback){2}else{0})) 'Successful-write accounting is exact in mock boundary'
    Check ($script:CandidateWriteMayHaveChangedDevice-eq(-not$isRollback)) 'Candidate attempted-write flag remains candidate-only'
    $cases.Add([pscustomobject]@{reservation=$enabled;rollback=$isRollback;operations=8;hardware_interaction=$false})
  }
}

# Rejected external results still produce one immutable failed record and one
# attempted-operation ledger entry; they never count as successful writes.
foreach($enabled in @($false,$true)){
  foreach($failure in @(@('read_mac','wrong-mac'),@('read_mac','bad-exit'),@('write','missing-marker'),@('verify','missing-marker'))){
    $grantReservationEnabled=$enabled;$Bundle=[pscustomobject]@{offline_fixture=$true}
    Remove-Variable -Name modeHandoff -ErrorAction SilentlyContinue
    $script:mockBehavior=$failure[1]
    $script:Operations=[Collections.ArrayList]::new();$script:RollbackOperations=[Collections.ArrayList]::new()
    $script:SuccessfulCandidateWrites=0;$script:SuccessfulRollbackWrites=0
    $script:ExternalActions=[ordered]@{firmware_write_attempted=$false;firmware_may_have_changed=$false}
    $script:CandidateWriteMayHaveChangedDevice=$false
    $evidence=Join-Path $OutputDirectory ('reject-'+$enabled.ToString()+'-'+$failure[0]+'-'+$failure[1]);[void][IO.Directory]::CreateDirectory($evidence)
    $application=Join-Path $evidence 'synthetic.application.bin';[IO.File]::WriteAllBytes($application,[byte[]]@(1,2,3))
    $role=[pscustomobject]@{key='vehicle';name='OFFLINE-vehicle';port='OFFLINE-PORT-vehicle';mac='01:02:03:04:05:06'};$script:mockMac=$role.mac
    $exception='';try{Invoke-ToolOperation ('reject_'+$failure[0]) $role $failure[0] $(if($failure[0]-ceq'read_mac'){''}else{$application}) $true}catch{$exception=$_.Exception.Message}
    Check ($exception-like('*reject_'+$failure[0]+' failed:*')) 'Actual operation rejects invalid external result'
    Check ($script:Operations.Count-eq0-and$script:RollbackOperations.Count-eq1-and$script:SuccessfulRollbackWrites-eq0) 'Rejected rollback operation remains one attempted non-success'
    $rejected=$script:RollbackOperations[0];$decoded=ReadUtf8Json (Join-Path $evidence $rejected.record_path)
    Check ($decoded.result-ceq'FAIL_STOP'-and$decoded.issues-is[array]-and$decoded.issues.Count-gt0) 'Rejected record retains original failure schema and issues'
    Check ($null-eq$decoded.PSObject.Properties['grant_reservation_diagnostics']-and$null-eq$decoded.PSObject.Properties['reader_schema']) 'Failure record cannot gain aggregate authority metadata'
  }
}
$script:mockBehavior='pass'

# Exercise the real serializer with multilingual nested failure data, escaped
# quotes/backslashes, an empty array, null, and non-BMP text in the file path.
$japanese=ConvertFrom-Json '"\u5909\u6570\u306e\u8a3a\u65ad\u5931\u6557"'
$emoji=[char]::ConvertFromUtf32(0x1F680)
$unicodePath=Join-Path $OutputDirectory ($japanese+$emoji+'.json')
$unicode=[pscustomobject][ordered]@{failure=$japanese+' "quote" \path'+"`r`n"+$emoji;failures=@($japanese,$japanese);empty=@();missing=$null;enabled=$false;count=[long]4294967295}
Write-DurableJson $unicodePath $unicode
$decoded=ReadUtf8Json $unicodePath
Check (Same $unicode $decoded) 'Actual BOMlessUTF8 writer/readback preserves Japanese nested failure data'
Check ($decoded.failures-is[array]-and$decoded.failures.Count-eq2-and$decoded.empty-is[array]-and$decoded.empty.Count-eq0-and$null-eq$decoded.missing) 'JSON array/null shapes preserved'
[byte[]]$bytes=[IO.File]::ReadAllBytes($unicodePath)
Check (-not($bytes.Length-ge3-and$bytes[0]-eq239-and$bytes[1]-eq187-and$bytes[2]-eq191)) 'Serializer remains BOMlessUTF8'
$summary=[pscustomobject]@{schema='vc-lora-r19-grant-reservation-flash-operation-regression-v1';result='PASS';checks=$script:checks;source_sha256=Get-Sha256 $SourceToolPath;cases=$cases.ToArray();mock_external_calls=$script:mockExternalCalls;actual_operation_bodies=$true;actual_durable_serializer=$true;hardware_interaction=$false;native_tool_executed=$false;process_inventory_queried=$false;candidate_or_prepared_pin_modified=$false;acceptance_authorized=$false;deployment_authorized=$false}
Write-DurableJson (Join-Path $OutputDirectory 'summary.json') $summary
Write-Output ('R19_GRANT_RESERVATION_FLASH_OPERATION_REGRESSION PASS checks='+$script:checks+' hardware_interaction=false output='+$OutputDirectory)
