param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:checks=0;$script:failures=0
function Check($Value,[string]$Name){$script:checks++;if(-not$Value){$script:failures++;Write-Output "FAIL $Name"}}
function Reject([scriptblock]$Action,[string]$Name){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Check $rejected $Name}
. (Join-Path $RepoRoot 'tools/r19_timed_path_outer.ps1')
$paths=@(Get-R19TimedPathOuterToolPaths)
Check ($paths.Count-eq17) 'legacy prepared tools remain exactly 17'
Check (@(Get-R19TimedPathOuterToolPaths -AuxReadinessDiagnostics $true).Count-eq18) 'AUX prepared tools remain exactly 18'
$newToolParameter=(Get-Command Get-R19TimedPathOuterToolPaths).Parameters.ContainsKey('DiagnosticUsbFailureDiagnostics')
Check $newToolParameter 'new mode has an explicit tool inventory parameter'
$newPinParameter=(Get-Command Assert-R19TimedPathPreparedContract).Parameters.ContainsKey('DiagnosticUsbFailureDiagnostics')
Check $newPinParameter 'new mode has an explicit prepared pin parameter'
if($newToolParameter-and$newPinParameter){
  $newPaths=@(Get-R19TimedPathOuterToolPaths -AuxReadinessDiagnostics $true -DiagnosticUsbFailureDiagnostics $true)
  Check ($newPaths.Count-eq20-and$newPaths-contains'tools/read_r19_diagnostic_usb_failure_record.ps1'-and$newPaths-contains'tools/r19_usb_role_contract.ps1') 'v8 pins both decoder and role contract in exactly 20 tools'
  Reject {Get-R19TimedPathOuterToolPaths -DiagnosticUsbFailureDiagnostics $true} 'new mode cannot omit required AUX mode'
  . (Join-Path $RepoRoot 'tools/r19_usb_role_contract.ps1')
  $pin=[pscustomobject]@{schema='vc-lora-r19-timed-path-prepared-run-v1';mode='ExplicitHostArm';aux_readiness_diagnostics=$true;diagnostic_usb_failure_diagnostics=$true
    candidate_id='test-diagnostic-usb-001';latest_sha256=('A'*64);latest_path='runs/candidates/R19-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json'
    capture_seconds=40;product_budget_ms=106;acceptance_authorized=$false;deployment_authorized=$false;live_authorization_granted=$false
    vehicle_runtime_stage_address='0x3fcad390';ground_runtime_stage_address='0x3fca49a8'
    usb_role_capabilities=(Get-R19UsbRoleCapabilities -RepoRoot $RepoRoot -Mode ExplicitHostArm -Enabled $true)
    tools=@($newPaths|ForEach-Object{[pscustomobject]@{path=$_;sha256=('B'*64)}})}
  $accepted=$false;try{$null=Assert-R19TimedPathPreparedContract $pin ExplicitHostArm $true $true;$accepted=$true}catch{}
  Check $accepted 'complete diagnostic v8 prepared pin accepted without granting hardware permission'
  Reject {Assert-R19TimedPathPreparedContract $pin ExplicitHostArm $true $false} 'new metadata cannot masquerade as legacy AUX'
  Reject {Assert-R19TimedPathPreparedContract $pin SyncOnly $true $true} 'new feature cannot be SyncOnly candidate mode'
  $pin.usb_role_capabilities.roles[0].arm=$true
  Reject {Assert-R19TimedPathPreparedContract $pin ExplicitHostArm $true $true} 'Vehicle ARM escalation rejected'
  $pin.usb_role_capabilities.roles[0].arm=$false
  $pin.usb_role_capabilities.roles[0].clock_request_reply=$false
  Reject {Assert-R19TimedPathPreparedContract $pin ExplicitHostArm $true $true} 'missing Vehicle ClockResponse capability rejected'
}
$outer=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1') -Raw
$flash=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/invoke_r19_candidate_app_flash_hil.ps1') -Raw
foreach($source in @($outer,$flash)){
  foreach($term in @('[switch]$DiagnosticUsbFailureDiagnostics','diagnostic_usb_failure_diagnostics','usb_role_capabilities','vc-lora-r19-runtime-stage-jtag-read-v8')){
    Check ($source.Contains($term)) ('live entry source explicitly binds '+$term)
  }
}
foreach($term in @('ConvertFrom-R19DiagnosticUsbFailureRecord','diagnostic_usb_failure_first.bin','diagnostic_usb_failure_second.bin','Get-R19UsbRoleEffectiveMode')){
  Check ($outer.Contains($term)) ('outer independently verifies '+$term)
}
Check ($outer.Contains("if(`$PSBoundParameters['DiagnosticUsbFailureDiagnostics']){`$installArguments+=@('-DiagnosticUsbFailureDiagnostics')}")) 'outer forwards explicit new opt-in to installer with legacy absent=false'
Check ($outer.Contains("if(`$PSBoundParameters['DiagnosticUsbFailureDiagnostics']){`$captureArguments+=,'-DiagnosticUsbFailureDiagnostics'}")) 'outer forwards explicit new opt-in to capture with legacy absent=false'
Check ($outer.Contains("if(`$PSBoundParameters['DiagnosticUsbFailureDiagnostics']){`$rollbackArguments+=@('-DiagnosticUsbFailureDiagnostics')}")) 'outer preserves explicit new mode during mandatory R18 rollback with legacy absent=false'
Check ($flash.Contains("'r19_usb_role_contract.ps1'")) 'frozen verifier stages the role module beside common module'
Check ($flash.Contains('sourceRoleContract')-and$flash.Contains('stagedRoleContractLock')) 'frozen verifier pins and locks role module during execution'
Check ($flash.Contains("`$modeArguments.DiagnosticUsbFailureDiagnostics=`$true")) 'frozen verifier receives exact new feature opt-in'
Check ($flash.Contains('all eight diagnostic records twice')) 'flash handoff requires 16 raw reads rather than seven-record downgrade'
Write-Output "R19_DIAGNOSTIC_USB_OUTER checks=$script:checks failures=$script:failures"
if($script:failures-ne0){exit 1}
