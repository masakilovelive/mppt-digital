[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='', [string]$FlashSourcePath='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
if(-not$FlashSourcePath){$FlashSourcePath=Join-Path $RepoRoot 'tools/invoke_r19_candidate_app_flash_hil.ps1'}
if(-not$OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('runs/validation/R19-GRANT-RESERVATION-INTEGRATION-OFFLINE-001/20261025T-fix/flash_boundary-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Boundary output must be fresh'}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$script:checks=0;$script:cases=[Collections.ArrayList]::new()
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Action){
  try{&$Action;[void]$script:cases.Add([ordered]@{name=$Name;result='PASS';error=$null});Write-Output ('PASS '+$Name)}
  catch{[void]$script:cases.Add([ordered]@{name=$Name;result='FAIL';error=$_.Exception.Message;stack=$_.ScriptStackTrace});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message+' '+$_.ScriptStackTrace)}
}
function Import-Actual([string]$Path,[string[]]$Names){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
  Check (@($errors).Count-eq0) ('Actual source parses '+$Path)
  foreach($name in $Names){
    $nodes=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq$name})
    Check ($nodes.Count-eq1) ('Exactly one actual function '+$name)
    . ([scriptblock]::Create($nodes[0].Extent.Text))
    Set-Item -Path ('Function:script:'+$name) -Value (Get-Item ('Function:'+$name)).ScriptBlock
  }
}
Import-Actual $FlashSourcePath @('Assert-Condition','Get-Sha256','Get-TextSha256','Write-DurableBytes','Write-DurableText','Write-DurableJson','Flush-Existing','Get-RelativePath','New-ExactArgv','Assert-SafeArgv','Invoke-CapturedEspTool','Invoke-ToolOperation','Write-SealedEvidence')
Import-Actual (Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1') @('Read-JsonIfPresent','Assert-InstallProof','Test-RollbackProof','Assert-RawProjection')
$utf8=[Text.UTF8Encoding]::new($false,$true);$newline=[Environment]::NewLine
$startedUtc=[DateTime]::UtcNow.ToString('o');$testId='OFFLINE-ACTUAL-FLASH-BOUNDARY';$flashEvidenceSchema='vc-lora-r19-candidate-flash-evidence-v1'
$runtimeFailDiagnosticsEnabled=$true;$acceptanceEligible=$false
$activeAuthorizationText='R19_RUNTIME_FAIL_DIAGNOSTIC_HIL_ONE_RUN_NOT_ACCEPTANCE_NOT_DEPLOYMENT'
$operatorSafetyAttestationText='OFFLINE_FIXTURE_NOT_LIVE_AUTHORIZATION'
$acceptedR18RootRelative='fixture/accepted-r18';$MaxRollbackAttempts=3
$OfflineContractTest=[Management.Automation.SwitchParameter]::new($false)
$Execute=[Management.Automation.SwitchParameter]::new($false)
$hilToken=$activeAuthorizationText
$fakeNative=Join-Path $OutputDirectory 'harmless-fake-esptool.cmd'
# This native child ignores all argv, emits a fixed fixture MAC, and cannot access a device.
[IO.File]::WriteAllText($fakeNative,"@echo off`r`necho MAC: 10:20:30:40:50:60`r`nexit /b 0`r`n",[Text.Encoding]::ASCII)
$espTool=[pscustomobject]@{execution_path=$fakeNative;execution_sha256=Get-Sha256 $fakeNative}
function Wait-RoleIdentity([object]$Role,[int]$TimeoutSeconds=20){[pscustomobject]@{fixture=$true;port=$Role.port;pnp=$Role.pnp}}
function Assert-NoCompetingClients {throw 'This read-MAC fixture must not enter any write gate'}
function Reset-State([string]$Name,[bool]$Reservation){
  $script:evidence=Join-Path $OutputDirectory $Name;[void][IO.Directory]::CreateDirectory($script:evidence)
  $script:Operations=[Collections.ArrayList]::new();$script:RollbackOperations=[Collections.ArrayList]::new();$script:CompetingClientGateFailures=[Collections.ArrayList]::new()
  $script:CandidateWriteMayHaveChangedDevice=$false;$script:SuccessfulCandidateWrites=0;$script:SuccessfulRollbackWrites=0
  $script:ExternalActions=[ordered]@{device_access_attempted=$false;process_inventory_queried=$false;esptool_executed=$false;firmware_write_attempted=$false;firmware_may_have_changed=$false;device_power_changed=$false;erase_performed=$false;bootloader_written=$false;partition_table_written=$false;merged_image_written=$false}
  $script:timedPathEnabled=$Reservation;$script:auxReadinessEnabled=$Reservation;$script:diagnosticUsbFailureEnabled=$Reservation;$script:grantDiagnosticsEnabled=$Reservation;$script:grantReservationEnabled=$Reservation
  $script:DiagnosticUsbFailureDiagnostics=[Management.Automation.SwitchParameter]::new($Reservation);$script:GrantDiagnostics=[Management.Automation.SwitchParameter]::new($Reservation);$script:GrantReservationDiagnostics=[Management.Automation.SwitchParameter]::new($Reservation)
}
$role=[pscustomobject]@{key='vehicle';name='FIXTURE';port='OFFLINE-NOT-A-COM';pnp='OFFLINE';parent='OFFLINE';mac='10:20:30:40:50:60'}
$handoff=[ordered]@{timed_path_diagnostics=[ordered]@{fixture='timed'};aux_readiness_diagnostics=[ordered]@{fixture='aux'};diagnostic_usb_failure_diagnostics=[ordered]@{fixture='usb'};usb_role_capabilities=[ordered]@{fixture='roles'};grant_diagnostics=[ordered]@{fixture='grant'};grant_reservation_diagnostics=[ordered]@{schema='vc-lora-r19-grant-reservation-candidate-v1';enabled=$true;reader_schema='vc-lora-r19-runtime-stage-jtag-read-v10';capture=[ordered]@{prepare_seconds=15;measurement_seconds=40;param_request_maximum=1}}}
$handoffPath=Join-Path $OutputDirectory 'fixture_handoff.json';[IO.File]::WriteAllText($handoffPath,($handoff|ConvertTo-Json -Depth 20),$utf8)
$manifestPath=Join-Path $OutputDirectory 'fixture_manifest.json';[IO.File]::WriteAllText($manifestPath,($handoff|ConvertTo-Json -Depth 20),$utf8)
$bundle=[pscustomobject]@{runtime_fail_diagnostics_enabled=$true;latest_path='fixture/latest.json';latest_sha256=('1'*64);handoff_path=$handoffPath;handoff_sha256=Get-Sha256 $handoffPath;candidate_manifest_path=$manifestPath;candidate_manifest_sha256=Get-Sha256 $manifestPath;candidate_final_seal_path='fixture/final_seal.json';candidate_final_seal_sha256=('4'*64);artifact_id='offline-fixture-not-a-candidate'}
$candidate=$bundle
# Build non-ASCII text without depending on how Windows PowerShell decodes this test source.
$japanese=-join([char[]]@(0x5909,0x6570,0x20,0x27,0x24,0x6d,0x6f,0x64,0x65,0x48,0x61,0x6e,0x64,0x6f,0x66,0x66,0x27,0x20,0x306f,0x3001,0x8a2d,0x5b9a,0x3055,0x308c,0x3066,0x3044,0x306a,0x3044,0x305f,0x3081,0x306b,0x53d6,0x5f97,0x3067,0x304d,0x307e,0x305b,0x3093,0x3002))
foreach($reservation in @($false,$true)){
  foreach($rollback in @($false,$true)){
    $name='native-read-mac-reservation-'+$reservation+'-rollback-'+$rollback
    Case $name {
      Reset-State $name $reservation
      Invoke-ToolOperation fixture_read_mac $role read_mac '' $rollback
      $rows=@(if($rollback){@($script:RollbackOperations)}else{@($script:Operations)})
      Check ($rows.Count-eq1-and$rows[0].result-ceq'PASS') 'Actual operation must append successful bookkeeping once'
      Check ($script:ExternalActions.esptool_executed-and-not$script:ExternalActions.firmware_write_attempted-and-not$script:ExternalActions.firmware_may_have_changed) 'Harmless native read must never produce firmware write intent'
      $disk=Read-JsonIfPresent (Join-Path $evidence $rows[0].record_path)
      Check ($disk.kind-ceq'read_mac'-and$disk.parsed_mac-ceq$role.mac) 'Actual argv/native parser preserves exact MAC'
      Check (@($disk.PSObject.Properties|Where-Object{$_.Name-cin@('reader_schema','grant_reservation_diagnostics','authorization_scope')}).Count-eq0) 'Per-operation record must not contain aggregate reservation metadata'
      Check (@(Get-ChildItem -LiteralPath $evidence -Filter '*.intent.json').Count-eq0) 'Read-only native fixture has zero write intents'
    }
  }
}
Case 'durable-json-japanese-lossless' {
  $path=Join-Path $OutputDirectory 'japanese.json'
  Write-DurableJson $path ([ordered]@{failure=$japanese;quotation='"quoted"';value=$true})
  $decoded=Read-JsonIfPresent $path
  Check ($null-ne$decoded-and$decoded.failure-ceq$japanese-and$decoded.quotation-ceq'"quoted"') 'Actual writer and parent readback preserve exact Japanese and JSON escapes'
}
foreach($reservation in @($false,$true)){
  foreach($failed in @($false,$true)){
    $name='sealed-reservation-'+$reservation+'-failed-'+$failed
    Case $name {
      Reset-State $name $reservation
      $rollback=if($failed){[pscustomobject]@{result='FAIL';required=$true;roles=@();operations=@()}}else{$null}
      $status=if($failed){'FAIL_ROLLBACK_UNPROVEN_POWER_OFF_REQUIRED'}else{'PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY'}
      $result=if($failed){'FAIL_STOP'}else{'PASS'}
      $message=if($failed){$japanese}else{''}
      $recordPath=Write-SealedEvidence $result $status $message $bundle @() $rollback (-not$failed)
      $record=Read-JsonIfPresent $recordPath;$terminal=Read-JsonIfPresent (Join-Path $evidence 'terminal_status.json');$seal=Read-JsonIfPresent (Join-Path $evidence 'final_seal.json')
      Check ($null-ne$record-and$null-ne$terminal-and$null-ne$seal) 'Existing parent readback accepts all actual sealed JSON'
      Check ($record.failure-ceq$message-and$terminal.failure-ceq$message) 'Japanese failure survives the full actual evidence finalizer'
      Check ($seal.flash_record_sha256-ceq(Get-Sha256 $recordPath)) 'Final seal binds exact actual flash record bytes'
      Check ($record.authorization_scope-ceq$record.authorization.scope-and$record.authorization_scope-ceq$seal.authorization_scope-and$record.next_required_action-ceq$seal.next_required_action) 'Record, nested authorization and final seal must agree'
      if($reservation){
        Check ($record.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v10') 'Reservation aggregate evidence selects v10, never v9'
        Check (($record.grant_reservation_diagnostics|ConvertTo-Json -Depth 20 -Compress)-ceq($handoff.grant_reservation_diagnostics|ConvertTo-Json -Depth 20 -Compress)) 'Reservation aggregate evidence binds the exact sidecar'
      }else{
        Check (@($record.PSObject.Properties|Where-Object{$_.Name-ceq'grant_reservation_diagnostics'}).Count-eq0) 'Default-off evidence has no reservation sidecar'
      }
      if($failed){
        Check ($record.authorization.operator_safety_conditions-is[Array]-and$record.authorization.operator_safety_conditions.Count-eq0) 'Unauthorized safety conditions remain an empty array, not null'
        Check ($terminal.power_off_required-and-not$record.one_run_hil_authorized-and$record.next_required_action-ceq'Disconnect all power; do not operate either bridge until accepted R18 is verified on both roles') 'Failed rollback must require power off and must never instruct a new capture'
        Check (-not(Test-RollbackProof ([pscustomobject]@{exit_code=0}) $recordPath)) 'Actual parent rollback proof refuses an unproven restore'
      }else{
        Assert-InstallProof ([pscustomobject]@{exit_code=0}) $recordPath
        Check $true 'Actual parent install proof accepts exact schema, token, candidate identity and selected ABI'
      }
      $inventory=Read-JsonIfPresent (Join-Path $evidence 'artifact_manifest.json')
      foreach($file in @($inventory.files)){Check ((Get-Sha256 (Join-Path $evidence $file.path))-ceq$file.sha256) ('Every sealed artifact byte is independently rebound '+$file.path)}
    }
  }
}
foreach($reservation in @($false,$true)){
  $name='rollback-null-bundle-reservation-'+$reservation
  Case $name {
    Reset-State $name $reservation
    $rollback=[pscustomobject]@{result='FAIL';required=$true;roles=@();operations=@()}
    $recordPath=Write-SealedEvidence FAIL_STOP FAIL_ROLLBACK_UNPROVEN_POWER_OFF_REQUIRED $japanese $null @() $rollback $false
    $record=Read-JsonIfPresent $recordPath;$seal=Read-JsonIfPresent (Join-Path $evidence 'final_seal.json')
    Check ($null-ne$record-and$record.failure-ceq$japanese) 'Rollback-only finalizer supports a null candidate bundle and Japanese failure'
    Check ($record.next_required_action-ceq'Disconnect all power; do not operate either bridge until accepted R18 is verified on both roles'-and$seal.next_required_action-ceq$record.next_required_action) 'Null-bundle rollback never creates capture authorization'
    Check (@($record.PSObject.Properties|Where-Object{$_.Name-ceq'grant_reservation_diagnostics'}).Count-eq0) 'Null-bundle rollback does not fabricate reservation capability'
    Check ($record.authorization.operator_safety_conditions-is[Array]-and$record.authorization.operator_safety_conditions.Count-eq0) 'Null-bundle unauthorized safety conditions remain an empty array'
    Check (-not(Test-RollbackProof ([pscustomobject]@{exit_code=0}) $recordPath)) 'Actual parent refuses null-bundle unproven rollback'
  }
}
$summary=[ordered]@{schema='vc-lora-r19-flash-boundary-regression-v1';result=if(@($script:cases|Where-Object{$_.result-ceq'FAIL'}).Count){'FAIL'}else{'PASS'};checks=$script:checks;shell=$PSVersionTable.PSVersion.ToString();flash_source_sha256=Get-Sha256 $FlashSourcePath;cases=@($script:cases);native_child='fresh local CMD echo-only fixture; exact production argv and parser; no device access';live_authority=$false;hardware_access=$false}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'summary.json'),($summary|ConvertTo-Json -Depth 20),$utf8)
Write-Output ('flash_boundary '+$summary.result+' checks='+$script:checks)
if($summary.result-cne'PASS'){exit 1}
