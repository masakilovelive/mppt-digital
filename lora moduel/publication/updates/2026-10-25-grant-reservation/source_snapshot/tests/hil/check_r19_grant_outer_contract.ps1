[CmdletBinding()]
param([string]$RepoRoot='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
. (Join-Path $RepoRoot 'tools/r19_timed_path_outer.ps1')
$script:checks=0
function Need([bool]$Value,[string]$Name){if(-not $Value){throw $Name};$script:checks++}
function Reject([scriptblock]$Body,[string]$Name){$rejected=$false;try{&$Body|Out-Null}catch{$rejected=$true};Need $rejected $Name}
function Clone($Value){$Value|ConvertTo-Json -Depth 35|ConvertFrom-Json}
$base=@{AuxReadinessDiagnostics=$true;DiagnosticUsbFailureDiagnostics=$true;ParamListDiagnostics=$true}
$oldPaths=@(Get-R19TimedPathOuterToolPaths @base)
Need ($oldPaths.Count-eq21) 'Legacy parameter mode must still pin21tools'
$paths=@(Get-R19TimedPathOuterToolPaths @base -GrantDiagnostics $true)
Need ($paths.Count-eq22-and@($paths|Where-Object{$_-ceq'tools/read_r19_grant_diagnostic_record.ps1'}).Count-eq1) 'Grant mode requires exact22tools including decoder'
Reject {Get-R19TimedPathOuterToolPaths -GrantDiagnostics $true} 'Grant diagnostics cannot bypass AUX and USB diagnostics'
$pin=[pscustomobject]@{schema='vc-lora-r19-timed-path-prepared-run-v1';mode='ExplicitHostArm';candidate_id='grant-test';latest_sha256=('A'*64);latest_path='runs/candidates/R19-GRANT-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json';capture_seconds=40;product_budget_ms=106;acceptance_authorized=$false;deployment_authorized=$false;live_authorization_granted=$false;vehicle_runtime_stage_address='0x3fcad7f0';ground_runtime_stage_address='0x3fca4b68';aux_readiness_diagnostics=$true;diagnostic_usb_failure_diagnostics=$true;param_list_diagnostics=$true;grant_diagnostics=$true;tools=@($paths|ForEach-Object{[pscustomobject]@{path=$_;sha256=('B'*64)}});usb_role_capabilities=[pscustomobject]@{schema='vc-lora-r19-usb-role-capabilities-v1';mode='ExplicitHostArm';implementation_bound=$true;roles=@([pscustomobject]@{role='vehicle';effective_mode='SyncOnly';clock_request_reply=$true;ready=$false;arm=$false},[pscustomobject]@{role='ground';effective_mode='ExplicitHostArm';clock_request_reply=$true;ready=$true;arm=$true});canonical_sources=@('firmware/phase6/vc_lora_phase6_bridge.hpp','firmware/high_speed/r19_diagnostic_usb_failure_record.hpp','tools/r19_usb_role_contract.ps1'|ForEach-Object{[pscustomobject]@{path=$_;sha256=('C'*64)}})}}
Need ($null-ne(Assert-R19TimedPathPreparedContract -Pin $pin -Mode ExplicitHostArm @base -GrantDiagnostics $true)) 'Fresh Grant prepared pin must pass'
Reject {Assert-R19TimedPathPreparedContract -Pin $pin -Mode ExplicitHostArm @base} 'Grant prepared pin cannot downgrade silently'
foreach($value in @('true',1,$null)){$bad=Clone $pin;$bad.grant_diagnostics=$value;Reject {Assert-R19TimedPathPreparedContract -Pin $bad -Mode ExplicitHostArm @base -GrantDiagnostics $true} 'Grant option must be typed boolean'}
$bad=Clone $pin;$bad.latest_path='runs/candidates/R19-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json';Reject {Assert-R19TimedPathPreparedContract -Pin $bad -Mode ExplicitHostArm @base -GrantDiagnostics $true} 'Grant mode must not overwrite old candidate leaf'
$bad=Clone $pin;$bad.tools=@($oldPaths|ForEach-Object{[pscustomobject]@{path=$_;sha256=('B'*64)}});Reject {Assert-R19TimedPathPreparedContract -Pin $bad -Mode ExplicitHostArm @base -GrantDiagnostics $true} 'Legacy tool pin cannot authorize new decoder'
$bad=Clone $pin;$bad.product_budget_ms=107;Reject {Assert-R19TimedPathPreparedContract -Pin $bad -Mode ExplicitHostArm @base -GrantDiagnostics $true} 'Product106ms contract must remain'
$bad=Clone $pin;$bad.capture_seconds=41;Reject {Assert-R19TimedPathPreparedContract -Pin $bad -Mode ExplicitHostArm @base -GrantDiagnostics $true} 'No capture extension'
foreach($relative in @('tools/run_r19_timed_path_capture.ps1','tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1')){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $relative),[ref]$tokens,[ref]$errors)
  Need ($errors.Count-eq0) ('AST parse: '+$relative)
  $flag=@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantDiagnostics'})
  Need ($flag.Count-eq1-and$flag[0].StaticType-eq[Management.Automation.SwitchParameter]) ('Explicit Grant flag: '+$relative)
}
$bridge=Get-Content -LiteralPath (Join-Path $RepoRoot 'firmware/phase6/vc_lora_phase6_bridge.hpp') -Raw
foreach($token in @('VC_LORA_R19_GRANT_DIAGNOSTICS','vc_lora_r19_grant_diagnostic_record','r19_note_ground_adapter_diagnostics','R19GrantDiagnosticEvent::GrantGenerated','R19GrantDiagnosticEvent::GrantWriteAccepted','R19GrantDiagnosticEvent::GrantPhysicalTail','R19GrantDiagnosticEvent::GrantReceivedRaw')){Need ($bridge.Contains($token)) ('Missing actual bridge hook: '+$token)}
Need ($bridge.Contains('first_failure_diagnostics()')) 'Bridge must preserve uncollapsed firstfailure snapshot'
. (Join-Path $RepoRoot 'tools/r19_timed_path_acquisition.ps1') -ImportOnly
$contract=[pscustomobject]@{reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9';grant_diagnostics=[pscustomobject]@{schema='vc-lora-r19-grant-diagnostic-candidate-v1';enabled=$true;macro='VC_LORA_R19_GRANT_DIAGNOSTICS';reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9';record=[pscustomobject]@{symbol='vc_lora_r19_grant_diagnostic_record';schema_version=1;size_bytes=1024};decoder=[pscustomobject]@{path='tools/read_r19_grant_diagnostic_record.ps1';sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot 'tools/read_r19_grant_diagnostic_record.ps1') -Algorithm SHA256).Hash}}}
Assert-R19GrantCaptureMetadata -Value $contract -RepoRoot $RepoRoot -Enabled $true;Need $true 'Exact source-bound contract accepted'
Reject {Assert-R19GrantCaptureMetadata -Value $contract -RepoRoot $RepoRoot} 'Capture cannot silently ignore new record'
foreach($value in @('1024',1024.0,1024.1,$true)){$bad=Clone $contract;$bad.grant_diagnostics.record.size_bytes=$value;Reject {Assert-R19GrantCaptureMetadata -Value $bad -RepoRoot $RepoRoot -Enabled $true} 'Record size cannot be coerced'}
$bad=Clone $contract;$bad.grant_diagnostics|Add-Member -NotePropertyName extra -NotePropertyValue 0;Reject {Assert-R19GrantCaptureMetadata -Value $bad -RepoRoot $RepoRoot -Enabled $true} 'Unknown contract property rejected'
$bad=Clone $contract;$bad.grant_diagnostics.decoder.path='tools/../tools/read_r19_grant_diagnostic_record.ps1';Reject {Assert-R19GrantCaptureMetadata -Value $bad -RepoRoot $RepoRoot -Enabled $true} 'Decoder path aliases rejected'
$bad=Clone $contract;$bad.grant_diagnostics.decoder.sha256=('0'*64);Reject {Assert-R19GrantCaptureMetadata -Value $bad -RepoRoot $RepoRoot -Enabled $true} 'Decoder digest mismatch rejected'
[pscustomobject]@{schema='vc-lora-r19-grant-outer-offline-v1';result='PASS';checks=$checks;hardware_operations=0;deadline_changes=0}|ConvertTo-Json
