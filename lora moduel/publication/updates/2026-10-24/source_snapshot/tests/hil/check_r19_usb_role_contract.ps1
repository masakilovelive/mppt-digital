[CmdletBinding()]
param([string]$RepoRoot='')
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$checks=0;$failures=0
function Check([bool]$Value,[string]$Message){$script:checks++;if(-not$Value){$script:failures++;Write-Output ('FAIL: '+$Message)}}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Check $rejected $Message}
. (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')
$module=Join-Path $RepoRoot 'tools/r19_usb_role_contract.ps1'
Check (Test-Path -LiteralPath $module -PathType Leaf) 'Pure role capability contract is missing'
if(-not(Test-Path -LiteralPath $module -PathType Leaf)){Write-Output "R19-USB-ROLE-CONTRACT checks=$checks failures=$failures";exit 1}
. $module
$legacyLeaf=Get-R19CandidateOutputLeaf $true ExplicitHostArm $true
$newLeaf=Get-R19CandidateOutputLeaf $true ExplicitHostArm $true $true
Check ($legacyLeaf-ceq'R19-AUX-READINESS-EXPLICIT-HOST-ARM-DIAGNOSTIC-CANDIDATE-BUILD-001') 'Existing AUX candidate leaf changed'
Check ($newLeaf-ceq'R19-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001'-and$newLeaf-cne$legacyLeaf) 'New feature reuses an existing latest/output leaf'
Reject {Get-R19CandidateOutputLeaf $false ExplicitHostArm $true $true} 'New feature accepts missing runtime diagnostics'
Reject {Get-R19CandidateOutputLeaf $true SyncOnly $true $true} 'New feature accepts wrong timed-path mode'
Reject {Get-R19CandidateOutputLeaf $true ExplicitHostArm $false $true} 'New feature accepts missing AUX diagnostics'
Check ((Get-R19CandidateCompileProperty $true ExplicitHostArm $true $true)-match'VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD=1') 'New feature macro missing'
Check ((Get-R19CandidateCompileProperty $true ExplicitHostArm $true)-notmatch'VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD') 'New feature leaks into legacy compiler flags'
$contract=Get-R19UsbRoleCapabilities -RepoRoot $RepoRoot -Mode ExplicitHostArm -Enabled $true
Assert-R19UsbRoleCapabilities -Contract $contract -RepoRoot $RepoRoot -Mode ExplicitHostArm
Check ($contract.schema-ceq'vc-lora-r19-usb-role-capabilities-v1') 'Role contract schema changed'
Check (@($contract.roles).Count-eq2) 'Role contract lacks exact role inventory'
Check ((Get-R19UsbRoleEffectiveMode -Contract $contract -Role vehicle -RequestedMode ExplicitHostArm)-ceq'SyncOnly') 'Vehicle mode is not clock-only'
Check ((Get-R19UsbRoleEffectiveMode -Contract $contract -Role ground -RequestedMode ExplicitHostArm)-ceq'ExplicitHostArm') 'Ground mode is not ExplicitHostArm'
Assert-R19UsbRolePrivateWrite -Contract $contract -Role vehicle -Kind ClockRequest
Assert-R19UsbRolePrivateWrite -Contract $contract -Role ground -Kind ClockRequest
Assert-R19UsbRolePrivateWrite -Contract $contract -Role ground -Kind Arm
Reject {Assert-R19UsbRolePrivateWrite -Contract $contract -Role vehicle -Kind Arm} 'Vehicle ARM was not rejected before a writer call'
Reject {Get-R19UsbRoleEffectiveMode -Contract $null -Role vehicle -RequestedMode ExplicitHostArm} 'Absent capability was treated as supported'
Check ((Get-R19UsbRoleEffectiveMode -Contract $null -Role vehicle -RequestedMode ExplicitHostArm -AllowLegacyV0)-ceq'SyncOnly') 'Explicit versioned legacy compatibility changed'
$malformed=$contract|ConvertTo-Json -Depth 12|ConvertFrom-Json
$malformed.roles[0].clock_request_reply='true'
Reject {Assert-R19UsbRoleCapabilities $malformed $RepoRoot ExplicitHostArm} 'String capability passed strict boolean validation'
$duplicate=$contract|ConvertTo-Json -Depth 12|ConvertFrom-Json
$duplicate.roles[1].role='vehicle'
Reject {Assert-R19UsbRoleCapabilities $duplicate $RepoRoot ExplicitHostArm} 'Duplicate roles passed validation'
$sourceTamper=$contract|ConvertTo-Json -Depth 12|ConvertFrom-Json
$sourceTamper.canonical_sources[0].sha256='0'*64
Reject {Assert-R19UsbRoleCapabilities $sourceTamper $RepoRoot ExplicitHostArm} 'Capability detached from exact implementation source'
$armTamper=$contract|ConvertTo-Json -Depth 12|ConvertFrom-Json
$armTamper.roles[0].arm=$true
Reject {Assert-R19UsbRoleCapabilities $armTamper $RepoRoot ExplicitHostArm} 'Forged Vehicle ARM declaration accepted'
$abi=Get-R19DiagnosticUsbFailureCandidateContract $RepoRoot $true
Check ($abi.record.symbol-ceq'vc_lora_r19_diagnostic_usb_failure_record'-and$abi.record.size_bytes-eq256-and$abi.record.schema_version-eq1-and$abi.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v8') 'New first-fail ABI declaration is wrong'
foreach($relative in @('tools/build_r19_candidate_artifacts.ps1','tools/verify_r19_candidate_artifact.ps1','tools/run_r19_timed_path_capture.ps1')){
 $source=Get-Content -LiteralPath (Join-Path $RepoRoot $relative) -Raw
 Check ($source-match'\[switch\]\$DiagnosticUsbFailureDiagnostics') ($relative+' lacks opt-in switch')
 Check ($source-match'usb_role_capabilities') ($relative+' lacks bound role metadata')
}
$capture=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/run_r19_timed_path_capture.ps1') -Raw
Check ($capture.IndexOf('Assert-R19UsbRoleCapabilities')-lt$capture.IndexOf('$s.port.Open()')) 'Capability validation occurs after COM open'
Check ($capture-match'Assert-R19UsbRolePrivateWrite') 'Private OUT is not checked against role capabilities'
Check ($capture-match'Get-R19UsbRoleEffectiveMode') 'Capture still infers supported mode solely from a role name'
. (Join-Path $RepoRoot 'tools/r19_timed_path_acquisition.ps1') -ImportOnly
$sync=New-R19HostReadinessWorkflow -Mode SyncOnly -Role Vehicle -Nonce ([long]0x5219000000000001) -ReaderIdentity 'fixture-reader' -ClockDomainId 'fixture-clock' -TickFrequency 1000 -StartTicks 2 -ReadStartedTicks 1 -TimeoutTicks 100
$request=New-R19HostReadinessClockRequest $sync 3 'fixture-reader' $true 'fixture-clock'
Set-R19HostReadinessWriteCommit $sync ClockRequest 28 3 4 'fixture-reader' $true 'fixture-clock'
Reject {New-R19HostReadinessClockRequest $sync 5 'fixture-reader' $true 'fixture-clock'} 'A duplicate Vehicle ClockRequest was replayed by workflow'
$vehicleArm=New-R19HostReadinessWorkflow -Mode SyncOnly -Role Vehicle -Nonce ([long]0x5219000000000002) -ReaderIdentity 'fixture-reader' -ClockDomainId 'fixture-clock' -TickFrequency 1000 -StartTicks 2 -ReadStartedTicks 1 -TimeoutTicks 100
Reject {New-R19HostReadinessWorkflowArm $vehicleArm 3 'fixture-reader' $true 'fixture-clock'} 'Vehicle workflow accepted private ARM'
$fixtureRoot=Join-Path $RepoRoot ('runs/validation/R19-USB-ROLE-CONTRACT-TEST-001/'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function New-RoleContractElf([string]$Path,[bool]$IncludeNew,[int]$NewSize=256){
  $defs=@(@('vc_lora_r19_runtime_stage_record',68),@('vc_lora_r19_hwcdc_fifo_diagnostic_record',112),@('vc_lora_r19_hwcdc_restart_diagnostic_record',128),@('vc_lora_r19_ground_usb_commit_record',128),@('vc_lora_r19_first_usb_failure_record',384),@('vc_lora_r19_timed_path_record',512),@('vc_lora_r19_aux_readiness_record',6144))
  if($IncludeNew){$defs+=,@('vc_lora_r19_diagnostic_usb_failure_record',$NewSize)}
  $strings=[Collections.Generic.List[byte]]::new();$strings.Add(0);$names=@()
  foreach($def in $defs){$names+=$strings.Count;$strings.AddRange([Text.Encoding]::ASCII.GetBytes($def[0]));$strings.Add(0)}
  $tableOffset=212;$tableSize=16*($defs.Count+1);$stringsOffset=$tableOffset+$tableSize
  [byte[]]$bytes=[byte[]]::new($stringsOffset+$strings.Count)
  ([byte[]]@(127,69,76,70,1,1,1)).CopyTo($bytes,0)
  [BitConverter]::GetBytes([uint16]2).CopyTo($bytes,16);[BitConverter]::GetBytes([uint16]94).CopyTo($bytes,18);[BitConverter]::GetBytes([uint32]1).CopyTo($bytes,20)
  [BitConverter]::GetBytes([uint32]52).CopyTo($bytes,32);[BitConverter]::GetBytes([uint16]40).CopyTo($bytes,46);[BitConverter]::GetBytes([uint16]4).CopyTo($bytes,48)
  [uint32]$address=0x3FC80000;$total=0;foreach($def in $defs){$total+=[int]$def[1]}
  [BitConverter]::GetBytes([uint32]8).CopyTo($bytes,96);[BitConverter]::GetBytes([uint32]3).CopyTo($bytes,100);[BitConverter]::GetBytes($address).CopyTo($bytes,104);[BitConverter]::GetBytes([uint32]$total).CopyTo($bytes,112)
  [BitConverter]::GetBytes([uint32]2).CopyTo($bytes,136);[BitConverter]::GetBytes([uint32]$tableOffset).CopyTo($bytes,148);[BitConverter]::GetBytes([uint32]$tableSize).CopyTo($bytes,152);[BitConverter]::GetBytes([uint32]3).CopyTo($bytes,156);[BitConverter]::GetBytes([uint32]16).CopyTo($bytes,168)
  [BitConverter]::GetBytes([uint32]3).CopyTo($bytes,176);[BitConverter]::GetBytes([uint32]$stringsOffset).CopyTo($bytes,188);[BitConverter]::GetBytes([uint32]$strings.Count).CopyTo($bytes,192)
  for($i=0;$i-lt$defs.Count;$i++){$at=$tableOffset+16*($i+1);[BitConverter]::GetBytes([uint32]$names[$i]).CopyTo($bytes,$at);[BitConverter]::GetBytes($address).CopyTo($bytes,$at+4);[BitConverter]::GetBytes([uint32]$defs[$i][1]).CopyTo($bytes,$at+8);$bytes[$at+12]=17;[BitConverter]::GetBytes([uint16]1).CopyTo($bytes,$at+14);$address+=[uint32]$defs[$i][1]}
  $strings.ToArray().CopyTo($bytes,$stringsOffset);[IO.File]::WriteAllBytes($Path,$bytes)
}
$elf7=Join-Path $fixtureRoot 'legacy-seven.elf';$elf8=Join-Path $fixtureRoot 'new-eight.elf';$badElf=Join-Path $fixtureRoot 'wrong-size.elf'
New-RoleContractElf $elf7 $false;New-RoleContractElf $elf8 $true;New-RoleContractElf $badElf $true 252
Check (@((Get-R19ElfDiagnosticSymbols $elf7 $true $true $true $true).PSObject.Properties).Count-eq7) 'Legacy seven-record ELF contract changed'
Check (@((Get-R19ElfDiagnosticSymbols $elf8 $true $true $true $true $true).PSObject.Properties).Count-eq8) 'New v8 ELF does not require exactly eight records'
Reject {Get-R19ElfDiagnosticSymbols $elf7 $true $true $true $true $true} 'New feature accepted an absent diagnostic USB record'
Reject {Get-R19ElfDiagnosticSymbols $elf8 $true $true $true $true} 'Legacy feature accepted an undeclared eighth record'
Reject {Get-R19ElfDiagnosticSymbols $badElf $true $true $true $true $true} 'Wrong-size diagnostic USB record accepted'
$fixtureNow=[DateTime]::Parse('2026-10-23T12:00:00Z').ToUniversalTime()
$timed=Get-R19TimedPathCandidateContract $RepoRoot ExplicitHostArm
$aux=Get-R19AuxReadinessCandidateContract $RepoRoot $true
$ports=@([pscustomobject]@{role='vehicle';port='COM3';baud=115200;pnp_instance_id='fixture-vehicle';usb_parent_instance_id='fixture-parent-vehicle'},[pscustomobject]@{role='ground';port='COM6';baud=57600;pnp_instance_id='fixture-ground';usb_parent_instance_id='fixture-parent-ground'})
$handoff=[pscustomobject]@{schema='vc-lora-r19-candidate-artifact-handoff-v1';result='PASS';artifact_id='fixture-v8';runtime_fail_diagnostics_enabled=$true;reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8';timed_path_diagnostics=$timed;aux_readiness_diagnostics=$aux;diagnostic_usb_failure_diagnostics=$abi;usb_role_capabilities=$contract}
$flashRoles=@(foreach($p in $ports){[pscustomobject]@{role=$p.role;port=$p.port;pnp_device_id=$p.pnp_instance_id;parent_device_id=$p.usb_parent_instance_id;write_pass=$true;verify_pass=$true;reenumeration_pass=$true}})
$flash=[pscustomobject]@{schema='vc-lora-r19-candidate-flash-evidence-v1';result='PASS';status='PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY';candidate=[pscustomobject]@{handoff_sha256=('A'*64)};runtime_fail_diagnostics_enabled=$true;reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8';timed_path_diagnostics=$timed;aux_readiness_diagnostics=$aux;diagnostic_usb_failure_diagnostics=$abi;usb_role_capabilities=$contract;one_run_hil_authorized=$true;roles=$flashRoles}
$permit=[pscustomobject]@{schema='vc-lora-r19-timed-path-execution-permit-v1';status='AUTHORIZED_SINGLE_CAPTURE';candidate_id='fixture-v8';mode='ExplicitHostArm';safety_confirmed=$true;one_time=$true;restore_required=$true;handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);issued_utc=$fixtureNow.AddSeconds(-10).ToString('o');expires_utc=$fixtureNow.AddSeconds(60).ToString('o');capture_seconds=40;ports=$ports}
$planArgs=@{Handoff=$handoff;FlashEvidence=$flash;Permit=$permit;Mode='ExplicitHostArm';HandoffSha256=('A'*64);FlashEvidenceSha256=('B'*64);NowUtc=$fixtureNow;DiagnosticUsbFailureDiagnostics=$true;RepoRoot=$RepoRoot}
Check ((Get-R19TimedPathCapturePlan @planArgs).valid) 'Valid source-bound new capture plan was rejected'
$missing=$handoff|ConvertTo-Json -Depth 20|ConvertFrom-Json
$missing.PSObject.Properties.Remove('usb_role_capabilities')
$badArgs=$planArgs.Clone();$badArgs.Handoff=$missing
Reject {Get-R19TimedPathCapturePlan @badArgs} 'New capture accepted missing role capabilities before COM open'
$mismatch=$flash|ConvertTo-Json -Depth 20|ConvertFrom-Json
$mismatch.usb_role_capabilities.roles[0].arm=$true
$badArgs=$planArgs.Clone();$badArgs.FlashEvidence=$mismatch
Reject {Get-R19TimedPathCapturePlan @badArgs} 'Fresh flash Vehicle ARM escalation was accepted'
$wrongDecoder=$handoff|ConvertTo-Json -Depth 20|ConvertFrom-Json
$wrongDecoder.diagnostic_usb_failure_diagnostics.decoder.sha256='0'*64
$badArgs=$planArgs.Clone();$badArgs.Handoff=$wrongDecoder
Reject {Get-R19TimedPathCapturePlan @badArgs} 'Capture accepted mismatched diagnostic decoder fingerprint'
$badArgs=$planArgs.Clone();$badArgs.RepoRoot=''
Reject {Get-R19TimedPathCapturePlan @badArgs} 'New capture accepted no canonical source authority'
$badArgs=$planArgs.Clone();$badArgs.DiagnosticUsbFailureDiagnostics=$false
Reject {Get-R19TimedPathCapturePlan @badArgs} 'New feature candidate ran without its explicit opt-in capture flag'
Write-Output "R19-USB-ROLE-CONTRACT checks=$checks failures=$failures"
if($failures){exit 1}
