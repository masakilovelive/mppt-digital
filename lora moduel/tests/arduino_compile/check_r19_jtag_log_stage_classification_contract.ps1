[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$readerPath = Join-Path $repoRoot 'tools\read_r19_runtime_stage_jtag.ps1'
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
  param([string]$Name, [bool]$Passed, [string]$Detail)
  $checks.Add([ordered]@{name=$Name;passed=$Passed;detail=$Detail})
}

try {
  $tokens = $null
  $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile(
      $readerPath, [ref]$tokens, [ref]$parseErrors)
  Add-Check 'reader_parses' (@($parseErrors).Count -eq 0) `
      (@($parseErrors | ForEach-Object {$_.Message}) -join '; ')

  $stageFunctions = @($ast.FindAll({param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -in @('Assert-SmpCurstate','Assert-SmpRunningCurstate',
        'Get-OpenOcdLogStage')}, $true))
  $riskFunctions = @($ast.FindAll({param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Get-TargetMayBeHalted'}, $true))
  Add-Check 'stage_parser_exists' ($stageFunctions.Count -eq 3) `
      'curstate helpers and Get-OpenOcdLogStage must each exist exactly once'
  Add-Check 'target_risk_classifier_exists' ($riskFunctions.Count -eq 1) `
      'Get-TargetMayBeHalted must be defined exactly once'

  if ($stageFunctions.Count -eq 3) {
    foreach ($stageFunction in $stageFunctions) {
      . ([scriptblock]::Create($stageFunction.Extent.Text))
    }
    if ($riskFunctions.Count -eq 1) {
      . ([scriptblock]::Create($riskFunctions[0].Extent.Text))
    }

    $usbOpenFailure = @'
Open On-Chip Debugger v0.12.0-esp32-20260424
Info : esp_usb_jtag: VID set to 0x303a and PID to 0x1001
Info : esp_usb_jtag: capabilities descriptor set to 0x2000
Error: libusb_open() failed with LIBUSB_ERROR_NOT_FOUND
Error: esp_usb_jtag: could not find or open device!
'@
    $preAttach = Get-OpenOcdLogStage -Text $usbOpenFailure
    Add-Check 'usb_open_failure_is_pre_attach' (
        -not [bool]$preAttach.device_opened -and
        -not [bool]$preAttach.target_examined -and
        -not [bool]$preAttach.halt_possible -and
        -not [bool]$preAttach.resume_proven -and
        -not [bool]$preAttach.cleanup_required -and
        [string]$preAttach.failure_classification -ceq
          'FAIL_JTAG_USB_OPEN') ($preAttach | ConvertTo-Json -Compress)
    if ($riskFunctions.Count -eq 1) {
      Add-Check 'pre_attach_failure_cannot_have_halted_target' (
          -not (Get-TargetMayBeHalted $true $preAttach $true $false)) `
        'terminated OpenOCD that never opened USB-JTAG cannot have halted CPU'
    }

    $examinedFailure = @'
Info : clock speed 40000 kHz
Info : JTAG tap: esp32s3.cpu0 tap/device found: 0x120034e5
Info : [esp32s3.cpu0] Examination succeed
Error: target not halted
'@
    $postAttach = Get-OpenOcdLogStage -Text $examinedFailure
    Add-Check 'post_attach_failure_latches_halt_risk' (
        [bool]$postAttach.device_opened -and
        [bool]$postAttach.target_examined -and
        [bool]$postAttach.halt_possible -and
        -not [bool]$postAttach.resume_proven -and
        [bool]$postAttach.cleanup_required -and
        [string]$postAttach.failure_classification -ceq
          'FAIL_JTAG_AFTER_TARGET_EXAMINE') `
      ($postAttach | ConvertTo-Json -Compress)

    $resumed = @'
Info : JTAG tap: esp32s3.cpu0 tap/device found: 0x120034e5
Info : [esp32s3.cpu0] Examination succeed
VC_LORA_HALT_CPU0
VC_LORA_HALT_CURSTATE_CPU0=halted
VC_LORA_HALT_CPU1
VC_LORA_HALT_CURSTATE_CPU1=halted
VC_LORA_RESUME_CPU0
VC_LORA_RESUME_CURSTATE_CPU0=running
VC_LORA_RESUME_CPU1
VC_LORA_RESUME_CURSTATE_CPU1=running
shutdown command invoked
'@
    $postResume = Get-OpenOcdLogStage -Text $resumed
    Add-Check 'resume_markers_are_stage_evidence' (
        [bool]$postResume.device_opened -and
        [bool]$postResume.target_examined -and
        [bool]$postResume.halt_possible -and
        [bool]$postResume.resume_proven) `
      ($postResume | ConvertTo-Json -Compress)

    $legacyResume = $resumed -replace
      'VC_LORA_RESUME_CURSTATE_CPU0=running','target state: running' -replace
      'VC_LORA_RESUME_CURSTATE_CPU1=running','target state: running'
    $legacyPostResume = Get-OpenOcdLogStage -Text $legacyResume
    Add-Check 'generic_running_text_is_not_resume_evidence' (
        -not [bool]$legacyPostResume.resume_proven) `
      ($legacyPostResume | ConvertTo-Json -Compress)
  }

  $source = Get-Content -LiteralPath $readerPath -Raw
  Add-Check 'pre_attach_cleanup_is_suppressed' (
      $source -match 'skipped_due_to_pre_attach_failure' -and
      $source -match 'FAIL_JTAG_USB_OPEN') `
      'recognized USB-open failures must not start a second OpenOCD process'
} catch {
  Add-Check 'contract_execution' $false $_.Exception.Message
}

$failed = @($checks | Where-Object {-not $_.passed})
$summary = [ordered]@{
  schema = 'vc-lora-r19-jtag-log-stage-classification-contract-v1'
  result = if ($failed.Count -eq 0) {'PASS'} else {'FAIL'}
  hardware_interaction = $false
  checks = $checks
  totals = [ordered]@{
    total=$checks.Count;passed=$checks.Count-$failed.Count;failed=$failed.Count
  }
}
$summary | ConvertTo-Json -Depth 8
if ($failed.Count -ne 0) {exit 1}
