[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
$script:checks=0
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw ('FAIL '+$Message)}}
function Reject([scriptblock]$Action,[string]$Message){$threw=$false;try{&$Action|Out-Null}catch{$threw=$true};Check $threw $Message}
function Read-Ast([string]$Relative){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $Relative),[ref]$tokens,[ref]$errors);Check (@($errors).Count-eq0) ('Syntax '+$Relative);return $ast}
function Import-PureFunctions([string]$Relative,[string[]]$Names=@()){
  $ast=Read-Ast $Relative
  foreach($node in $ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and($Names.Count-eq0-or$_.Name-cin$Names)}){
    . ([scriptblock]::Create($node.Extent.Text));Set-Item -Path ('Function:script:'+$node.Name) -Value (Get-Item ('Function:'+$node.Name)).ScriptBlock
  }
}
$flashRelative='tools/invoke_r19_candidate_app_flash_hil.ps1'
$gateRelative='tools/invoke_r19_jtag_preflash_gate.ps1'
$flashAst=Read-Ast $flashRelative;$gateAst=Read-Ast $gateRelative
foreach($entry in @(@($flashAst,'Flash'),@($gateAst,'Preflash'))){
  Check (@($entry[0].ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantReservationStopDiagnostics'}).Count-eq1) ($entry[1]+' has explicit default-off STOP128 switch')
}
Import-PureFunctions $flashRelative @('Assert-Condition','Get-Sha256','Read-PinnedFileUnderLock','Assert-CandidateModeRecord','Assert-GrantReservationStopSourceBinding','Write-SealedEvidence','Write-DurableJson','Write-DurableText','Write-DurableBytes','Get-RelativePath','Get-TextSha256')
Import-PureFunctions 'tools/r19_grant_reservation_contract.ps1'
Import-PureFunctions 'tools/r19_candidate_artifact_common.ps1' @('Get-R19Sha256','Get-R19TimedPathCandidateContract','Get-R19AuxReadinessCandidateContract','Get-R19DiagnosticUsbFailureCandidateContract','Get-R19GrantDiagnosticCandidateContract')
Import-PureFunctions 'tools/r19_usb_role_contract.ps1' @('Get-R19UsbRoleCapabilities')
$runtimeFailDiagnosticsEnabled=$true;$timedPathEnabled=$true;$TimedPathMode='ExplicitHostArm'
$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$true;$grantDiagnosticsEnabled=$true;$grantReservationEnabled=$true;$grantReservationStopEnabled=$true;$acceptanceEligible=$false
# Extracted functions receive an explicit file-fixture pin. The canonical main
# retains its reviewed constants; no live entry point or verifier is invoked.
$expectedGrantReservationContractSha256=Get-Sha256 (Join-Path $repo 'tools/r19_grant_reservation_contract.ps1')
function New-ModeFixture([bool]$Stop=$true,[string]$Schema='vc-lora-r19-candidate-artifact-manifest-v1'){
  $doc=[pscustomobject][ordered]@{
    schema=$Schema;runtime_fail_diagnostics_enabled=$true;acceptance_eligible=$false;acceptance_authorized=$false;deployment_authorized=$false
    reader_schema=$(if($Stop){'vc-lora-r19-runtime-stage-jtag-read-v11'}else{'vc-lora-r19-runtime-stage-jtag-read-v10'})
    timed_path_diagnostics=Get-R19TimedPathCandidateContract $repo ExplicitHostArm
    aux_readiness_diagnostics=Get-R19AuxReadinessCandidateContract $repo $true
    diagnostic_usb_failure_diagnostics=Get-R19DiagnosticUsbFailureCandidateContract $repo $true
    usb_role_capabilities=Get-R19UsbRoleCapabilities $repo ExplicitHostArm $true
    grant_diagnostics=Get-R19GrantDiagnosticCandidateContract $repo $true
    grant_reservation_diagnostics=Get-R19GrantReservationCandidateContract -RepoRoot $repo -Enabled $true -CancellationEnabled $Stop
  }
  if($Stop){$doc|Add-Member NoteProperty grant_reservation_stop_diagnostics (Get-R19GrantReservationStopCandidateContract -RepoRoot $repo -Enabled $true)}
  if($Schema-ceq'vc-lora-r19-candidate-artifact-latest-v1'){$doc.PSObject.Properties.Remove('reader_schema')}
  return $doc
}
foreach($schema in @('vc-lora-r19-candidate-artifact-manifest-v1','vc-lora-r19-candidate-artifact-handoff-v1','vc-lora-r19-candidate-final-seal-v1','vc-lora-r19-candidate-artifact-latest-v1')){
  $good=New-ModeFixture $true $schema;Assert-CandidateModeRecord $good 'STOP128 valid document';Check $true ('Strict STOP128 metadata accepts '+$schema)
  foreach($mutation in @('missing-stop','wrong-case','hash','size','extra','legacy-reader','legacy-wire','old-base-contract','missing-cancellation','grant-reader-downgrade')){
    $bad=New-ModeFixture $true $schema
    switch($mutation){
      'missing-stop'{$bad.PSObject.Properties.Remove('grant_reservation_stop_diagnostics')}
      'wrong-case'{$v=$bad.grant_reservation_stop_diagnostics;$bad.PSObject.Properties.Remove('grant_reservation_stop_diagnostics');$bad|Add-Member NoteProperty Grant_Reservation_Stop_Diagnostics $v}
      'hash'{$bad.grant_reservation_stop_diagnostics.decoder_sha256='0'*64}
      'size'{$bad.grant_reservation_stop_diagnostics.size_bytes=124}
      'extra'{$bad.grant_reservation_stop_diagnostics|Add-Member NoteProperty undeclared $true}
      'legacy-reader'{$bad.grant_reservation_stop_diagnostics.runtime_reader_schema='vc-lora-r19-runtime-stage-jtag-read-v10'}
      'legacy-wire'{$bad.grant_reservation_stop_diagnostics.usb_control_schema='vc-lora-r19-grant-reservation-usb-v1'}
      'old-base-contract'{$bad.grant_reservation_diagnostics=Get-R19GrantReservationCandidateContract -RepoRoot $repo -Enabled $true}
      'missing-cancellation'{$bad.grant_reservation_diagnostics.PSObject.Properties.Remove('cancellation')}
      'grant-reader-downgrade'{$bad.grant_reservation_diagnostics.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v10'}
    }
    Reject {Assert-CandidateModeRecord $bad 'STOP128 invalid document'} ('Strict STOP128 rejects '+$mutation+' '+$schema)
  }
  if($schema-cne'vc-lora-r19-candidate-artifact-latest-v1'){
    $bad=New-ModeFixture $true $schema;$bad.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v10'
    Reject {Assert-CandidateModeRecord $bad 'top-level downgrade'} ('STOP128 rejects top-level v10 '+$schema)
  }
}
$pinnedHash=$expectedGrantReservationContractSha256;$expectedGrantReservationContractSha256='0'*64
Reject {Assert-CandidateModeRecord (New-ModeFixture) 'changed reviewed source'} 'Actual file-lock helper rejects a changed reviewed contract pin'
$expectedGrantReservationContractSha256=$pinnedHash
$grantReservationStopEnabled=$false
Assert-CandidateModeRecord (New-ModeFixture $false) 'legacy v10';Check $true 'Disabled STOP preserves exact legacy v10'
Reject {Assert-CandidateModeRecord (New-ModeFixture $true) 'undeclared STOP'} 'STOP128 metadata cannot escalate an unselected invocation'
$bad=New-ModeFixture $false;$bad.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v11'
Reject {Assert-CandidateModeRecord $bad 'legacy promoted to v11'} 'Legacy v10 cannot downcast or invent v11'
$grantReservationStopEnabled=$true
if(-not$OutputDirectory){$OutputDirectory=Join-Path $repo ('runs/validation/R19-GRANT-RESERVATION-HEARTBEAT-STOP-FIX-OFFLINE-001/20261025T-fix/stop-flash-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$sourceArtifact=Join-Path $OutputDirectory 'source-fixture';[void][IO.Directory]::CreateDirectory((Join-Path $sourceArtifact 'evidence/tools'))
$sourceRows=@(foreach($relative in @('firmware/high_speed/r19_grant_reservation_stop_record.hpp','tools/read_r19_grant_reservation_stop_record.ps1')){$sourceFile=Get-Item -LiteralPath (Join-Path $repo $relative);[pscustomobject]@{path=$relative;sha256=Get-Sha256 $sourceFile.FullName;size_bytes=[int64]$sourceFile.Length}})
Copy-Item -LiteralPath (Join-Path $repo 'tools/read_r19_grant_reservation_stop_record.ps1') -Destination (Join-Path $sourceArtifact 'evidence/tools/read_r19_grant_reservation_stop_record.ps1')
$sourceManifest=[pscustomobject]@{canonical_source_snapshot=[pscustomobject]@{files=$sourceRows}}
Assert-GrantReservationStopSourceBinding $sourceManifest $sourceArtifact;Check $true 'Actual STOP128 source/staged decoder closure accepts exact bytes'
foreach($mutation in @('missing-header','duplicate','hash','size','string-size')){
  $bad=$sourceManifest|ConvertTo-Json -Depth 8|ConvertFrom-Json
  switch($mutation){
    'missing-header'{$bad.canonical_source_snapshot.files=@($bad.canonical_source_snapshot.files|Where-Object{$_.path-cne'firmware/high_speed/r19_grant_reservation_stop_record.hpp'})}
    'duplicate'{$bad.canonical_source_snapshot.files+=@($bad.canonical_source_snapshot.files[0])}
    'hash'{$bad.canonical_source_snapshot.files[0].sha256='0'*64}
    'size'{$bad.canonical_source_snapshot.files[0].size_bytes=1}
    'string-size'{$bad.canonical_source_snapshot.files[0].size_bytes=[string]$bad.canonical_source_snapshot.files[0].size_bytes}
  }
  Reject {Assert-GrantReservationStopSourceBinding $bad $sourceArtifact} ('STOP128 source closure rejects '+$mutation)
}
[IO.File]::WriteAllText((Join-Path $sourceArtifact 'evidence/tools/read_r19_grant_reservation_stop_record.ps1'),'changed fixture bytes')
Reject {Assert-GrantReservationStopSourceBinding $sourceManifest $sourceArtifact} 'STOP128 source closure rejects changed staged decoder'
$flashText=Get-Content -LiteralPath (Join-Path $repo $flashRelative) -Raw
$modeStart=$flashText.IndexOf('$runtimeFailDiagnosticsEnabled =');$modeEnd=$flashText.IndexOf('$acceptanceEligible =',$modeStart)
Check ($modeStart-ge0-and$modeEnd-gt$modeStart) 'Mode guard is isolated before execution setup'
$modeSource=[scriptblock]::Create($flashText.Substring($modeStart,$modeEnd-$modeStart))
foreach($missing in @('runtime','mode','aux','diagnostic-usb','grant','reservation')){
  Reject {&{
    $RuntimeFailDiagnostics=[Management.Automation.SwitchParameter]::new($missing-cne'runtime');$TimedPathMode=if($missing-ceq'mode'){'SyncOnly'}else{'ExplicitHostArm'}
    $AuxReadinessDiagnostics=[Management.Automation.SwitchParameter]::new($missing-cne'aux');$DiagnosticUsbFailureDiagnostics=[Management.Automation.SwitchParameter]::new($missing-cne'diagnostic-usb')
    $GrantDiagnostics=[Management.Automation.SwitchParameter]::new($missing-cne'grant');$GrantReservationDiagnostics=[Management.Automation.SwitchParameter]::new($missing-cne'reservation');$GrantReservationStopDiagnostics=[Management.Automation.SwitchParameter]::new($true)
    . $modeSource
  }} ('STOP128 rejects missing prerequisite '+$missing+' before main')
}
Check ($flashText.Contains('$modeArguments.GrantReservationStopDiagnostics=$true')) 'STOP128 selection reaches the staged verifier'
Check ($flashText.Contains('R19-GRANT-RESERVATION-STOP-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001')) 'STOP128 selects the separately declared candidate leaf'
$gateText=Get-Content -LiteralPath (Join-Path $repo $gateRelative) -Raw
$gateGuardStart=$gateText.IndexOf('if($GrantReservationDiagnostics');$gateGuardEnd=$gateText.IndexOf('$utf8',$gateGuardStart)
$gateGuard=[scriptblock]::Create($gateText.Substring($gateGuardStart,$gateGuardEnd-$gateGuardStart))
foreach($missing in @('grant','reservation')){Reject {&{
  $GrantDiagnostics=[Management.Automation.SwitchParameter]::new($missing-cne'grant');$GrantReservationDiagnostics=[Management.Automation.SwitchParameter]::new($missing-cne'reservation');$GrantReservationStopDiagnostics=[Management.Automation.SwitchParameter]::new($true);. $gateGuard
}} ('PnP-only STOP metadata rejects missing '+$missing)}
$gateRuntime=$gateText.Substring($gateText.LastIndexOf('Initialize-OutputDirectory',[StringComparison]::Ordinal))
Check ($gateRuntime-notmatch'Invoke-ReaderPreflight|Assert-LiveToolchain|Invoke-OpenOcd|transport init') 'STOP128 flag cannot activate JTAG in the PnP-only gate'
$summaryNode=@($gateAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left-is[Management.Automation.Language.VariableExpressionAst]-and$_.Left.VariablePath.UserPath-ceq'summary'})
Check ($summaryNode.Count-eq1) 'PnP-only evidence projection is unambiguous'
$summarySource=[scriptblock]::Create($summaryNode[0].Extent.Text)
foreach($stop in @($false,$true)){&{
  $schema='vc-lora-r19-jtag-preflash-gate-v1';$testId='offline-stop-metadata';$startedUtc='offline';$driverBindingPassed=$true;$terminalStatus='PASS_WINUSB_DRIVER_BINDING_PNP_ONLY';$failure='';$hardwareInteraction=$false;$toolchainEvidence=$null;$roles=@();$steps=@()
  $OfflineContractTest=[Management.Automation.SwitchParameter]::new($true);$GrantDiagnostics=[Management.Automation.SwitchParameter]::new($true);$GrantReservationDiagnostics=[Management.Automation.SwitchParameter]::new($true);$GrantReservationStopDiagnostics=[Management.Automation.SwitchParameter]::new($stop)
  . $summarySource
  $wanted=if($stop){'vc-lora-r19-runtime-stage-jtag-read-v11'}else{'vc-lora-r19-runtime-stage-jtag-read-v10'}
  Check ($summary.reader_schema-ceq$wanted-and$summary.grant_reservation_stop_diagnostics_enabled-eq$stop) 'Actual PnP-only evidence keeps exact selected generation'
  foreach($property in $summary.safety.PSObject.Properties){Check (-not[bool]$property.Value) ('PnP-only '+$property.Name+' remains false')}
}}
foreach($stop in @($false,$true)){&{
  $grantReservationStopEnabled=$stop
  $evidenceLeaf=$(if($stop){'flash-evidence-v11'}else{'flash-evidence-v10'})+'-'+[Guid]::NewGuid().ToString('N')
  $evidence=Join-Path $OutputDirectory $evidenceLeaf
  [void][IO.Directory]::CreateDirectory($evidence)
  $utf8=[Text.UTF8Encoding]::new($false);$newline=[Environment]::NewLine
  $testId='OFFLINE-STOP-FLASH-PROJECTION';$startedUtc='offline-file-fixture';$flashEvidenceSchema='vc-lora-r19-candidate-flash-evidence-v1'
  $OfflineContractTest=[Management.Automation.SwitchParameter]::new($true);$Execute=[Management.Automation.SwitchParameter]::new($false)
  $acceptedR18RootRelative='offline-fixture-only';$MaxRollbackAttempts=3
  $script:Operations=[Collections.ArrayList]::new();$script:CompetingClientGateFailures=[Collections.ArrayList]::new()
  $script:ExternalActions=[ordered]@{device_access_attempted=$false;process_inventory_queried=$false;esptool_executed=$false;firmware_write_attempted=$false}
  $handoffPath=Join-Path $evidence 'fixture-handoff.json'
  $handoff=New-ModeFixture $stop 'vc-lora-r19-candidate-artifact-handoff-v1';Write-DurableJson $handoffPath $handoff
  $bundle=[pscustomobject]@{runtime_fail_diagnostics_enabled=$true;latest_path='offline-latest';latest_sha256='A'*64;handoff_path=$handoffPath;handoff_sha256=Get-Sha256 $handoffPath;candidate_manifest_path='offline-manifest';candidate_manifest_sha256='B'*64;candidate_final_seal_path='offline-candidate-seal';candidate_final_seal_sha256='C'*64;artifact_id='offline-stop-fixture'}
  $recordPath=Write-SealedEvidence -Result PASS -Status OFFLINE_FILE_PROJECTION -Failure '' -Bundle $bundle -Roles @() -RollbackResult $null -OneRunAuthorized $false
  $record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json
  $seal=Get-Content -LiteralPath (Join-Path $evidence 'final_seal.json') -Raw|ConvertFrom-Json
  $wanted=if($stop){'vc-lora-r19-runtime-stage-jtag-read-v11'}else{'vc-lora-r19-runtime-stage-jtag-read-v10'}
  Check ($record.reader_schema-ceq$wanted-and-not$record.one_run_hil_authorized-and-not$record.acceptance_authorized-and-not$record.deployment_authorized) 'Actual flash record preserves generation without granting authority'
  Check ($seal.flash_record_sha256-ceq(Get-Sha256 $recordPath)-and-not$seal.one_run_hil_authorized-and-not$seal.deployment_authorized) 'Actual flash seal binds the emitted record and remains unauthorized'
  if($stop){
    foreach($doc in @($record,$seal)){
      Check ($doc.reader_schema-ceq$wanted) 'STOP128 record and seal both declare exact reader-v11'
      $null=Assert-R19GrantReservationStopCandidateContract -Value $doc.grant_reservation_stop_diagnostics -RepoRoot $repo -Enabled $true
      $null=Assert-R19GrantReservationCandidateContract -Value $doc.grant_reservation_diagnostics -RepoRoot $repo -Enabled $true -CancellationEnabled $true
      Check $true 'Actual flash projection retains exact source-bound STOP128 and cancellation contracts'
    }
  }else{
    Check ($null-eq$record.PSObject.Properties['grant_reservation_stop_diagnostics']-and$null-eq$seal.PSObject.Properties['grant_reservation_stop_diagnostics']-and$null-eq$seal.PSObject.Properties['reader_schema']) 'Disabled STOP leaves legacy flash seal and metadata unchanged'
  }
}}
Write-Output "check_r19_grant_reservation_stop_flash_contract PASS checks=$script:checks hardware_interaction=false"
