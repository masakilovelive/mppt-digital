[CmdletBinding()]
param(
  [string]$ArduinoCli =
      'C:\resources\app\lib\backend\resources\arduino-cli.exe',
  [string]$Fqbn = 'esp32:esp32:XIAO_ESP32S3',
  [string]$RepoRoot = '',
  [string]$IdeConfig =
      (Join-Path $env:USERPROFILE '.arduinoIDE\arduino-cli.yaml'),
  [string]$OutputDirectory = '',
  [switch]$SkipCompile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testId = 'FW-FUTURE-INDEX-RECOVERY-FAULT-CONTRACT-001'
$faultMacro = 'VC_LORA_HIL_DROP_NATIVE_PARAM_INDEX_930'
$expectedProductionAdapterSha256 =
    'D4328924FBDA498A1512A384778C1D02F86F7E3DA6198E496EAAB43EBCAC2F35'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $OutputDirectory = Join-Path $RepoRoot `
      "runs\validation\$testId\$stamp"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory -PathType Container) {
  $existingEvidence = @(Get-ChildItem -LiteralPath $OutputDirectory -Force)
  if ($existingEvidence.Count -ne 0) {
    throw "Evidence directory is not empty; refusing mixed evidence: $OutputDirectory"
  }
}
[void][System.IO.Directory]::CreateDirectory($OutputDirectory)

function Write-JsonDurable {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  $json = $Value | ConvertTo-Json -Depth 40
  $bytes = $utf8NoBom.GetBytes($json + "`n")
  $stream = New-Object System.IO.FileStream(
      $Path, [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read,
      4096, [System.IO.FileOptions]::WriteThrough)
  try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
}

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-CppFunctionRegion {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$SignaturePattern
  )
  $match = [regex]::Match($Text, $SignaturePattern,
      [Text.RegularExpressions.RegexOptions]::Singleline)
  if (-not $match.Success) { return $null }
  $brace = $Text.IndexOf('{', $match.Index + $match.Length)
  if ($brace -lt 0) { return $null }
  [int]$depth = 0
  [bool]$inString = $false
  [bool]$inCharacter = $false
  [bool]$escaped = $false
  for ($index = $brace; $index -lt $Text.Length; ++$index) {
    [char]$character = $Text[$index]
    if ($escaped) { $escaped = $false; continue }
    if (($inString -or $inCharacter) -and $character -eq '\') {
      $escaped = $true
      continue
    }
    if (-not $inCharacter -and $character -eq '"') {
      $inString = -not $inString
      continue
    }
    if (-not $inString -and $character -eq "'") {
      $inCharacter = -not $inCharacter
      continue
    }
    if ($inString -or $inCharacter) { continue }
    if ($character -eq '{') { ++$depth }
    if ($character -eq '}') {
      --$depth
      if ($depth -eq 0) {
        return [pscustomobject][ordered]@{
          start=$match.Index
          end_exclusive=$index + 1
          text=$Text.Substring($match.Index, $index + 1 - $match.Index)
          body=$Text.Substring($brace + 1, $index - $brace - 1)
        }
      }
    }
  }
  return $null
}

function Remove-CppComments {
  param([Parameter(Mandatory = $true)][string]$Text)
  $withoutBlocks = [regex]::Replace($Text, '/\*.*?\*/', '',
      [Text.RegularExpressions.RegexOptions]::Singleline)
  return [regex]::Replace($withoutBlocks, '(?m)//.*$', '')
}

$checks = New-Object 'System.Collections.Generic.List[object]'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Add-Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Passed,
    [Parameter(Mandatory = $true)][string]$Detail,
    $Expected = $null,
    $Actual = $null
  )
  $checks.Add([pscustomobject][ordered]@{
    name=$Name;passed=$Passed;detail=$Detail;expected=$Expected;actual=$Actual
  })
  if (-not $Passed) { $failures.Add("$Name`: $Detail") }
}

function Test-Pattern {
  param([string]$Text, [string]$Pattern)
  return [regex]::IsMatch($Text, $Pattern,
      [Text.RegularExpressions.RegexOptions]::Singleline)
}

$diagAdapter = Join-Path $RepoRoot `
    'vc_lora_ground_diag_v2_stable_xiao_esp32s3\vc_lora_phase6_bridge.hpp'
$diagSketch = Join-Path $RepoRoot `
    'vc_lora_ground_diag_v2_stable_xiao_esp32s3\vc_lora_ground_diag_v2_stable_xiao_esp32s3.ino'
$canonicalAdapter = Join-Path $RepoRoot `
    'firmware\phase6\vc_lora_phase6_bridge.hpp'
$productionGroundAdapter = Join-Path $RepoRoot `
    'vc_lora_ground_xiao_esp32s3\vc_lora_phase6_bridge.hpp'
$productionVehicleAdapter = Join-Path $RepoRoot `
    'vc_lora_vehicle_xiao_esp32s3\vc_lora_phase6_bridge.hpp'
$contractScript = $MyInvocation.MyCommand.Path
$sourceHashes = [ordered]@{}
$compileEvidence = [ordered]@{
  requested=(-not $SkipCompile.IsPresent)
  status=if($SkipCompile.IsPresent){'SKIPPED_BY_CALLER'}else{'NOT_RUN'}
  fault_macro=$faultMacro
  fqbn=$Fqbn
  exit_code=$null
  success=$false
  binary_path=$null
  binary_sha256=$null
  output_file=$null
}
$unexpectedFailure = $null

try {
  foreach ($requiredPath in @($diagAdapter, $diagSketch, $canonicalAdapter,
      $productionGroundAdapter, $productionVehicleAdapter)) {
    Add-Check -Name ('file_present_' +
        [IO.Path]::GetFileName((Split-Path -Parent $requiredPath)) + '_' +
        [IO.Path]::GetFileName($requiredPath)) `
        -Passed (Test-Path -LiteralPath $requiredPath -PathType Leaf) `
        -Detail "required contract input exists: $requiredPath"
  }

  foreach ($adapter in @(
      [pscustomobject]@{name='canonical';path=$canonicalAdapter},
      [pscustomobject]@{name='production_ground';path=$productionGroundAdapter},
      [pscustomobject]@{name='production_vehicle';path=$productionVehicleAdapter})) {
    $hash = Get-Sha256 -Path $adapter.path
    $sourceHashes[$adapter.name] = [ordered]@{path=$adapter.path;sha256=$hash}
    Add-Check -Name ('production_adapter_sha256_' + $adapter.name) `
        -Passed ($hash -ceq $expectedProductionAdapterSha256) `
        -Detail 'production adapter must remain byte-exact while the directed fault stays diagnostic-only' `
        -Expected $expectedProductionAdapterSha256 -Actual $hash
  }

  if (Test-Path -LiteralPath $diagAdapter -PathType Leaf) {
    $diagText = [System.IO.File]::ReadAllText($diagAdapter)
    $sourceHashes['diagnostic_ground'] = [ordered]@{
      path=$diagAdapter;sha256=(Get-Sha256 -Path $diagAdapter)
    }

    $roleGuardPattern =
        '(?m)^\s*#\s*if\s+defined\s*\(\s*' +
        [regex]::Escape($faultMacro) +
        '\s*\)\s*&&\s*(?:\\\s*)?\(\s*!\s*defined\s*\(\s*VC_LORA_PHASE6_GROUND\s*\)\s*\|\|\s*(?:\\\s*)?!\s*defined\s*\(\s*VC_LORA_PHASE6_GROUND_DIAGNOSTICS\s*\)\s*\|\|\s*(?:\\\s*)?defined\s*\(\s*VC_LORA_PHASE6_VEHICLE\s*\)\s*\)\s*(?:\\\s*)?\r?\n\s*#\s*error\b[^\r\n]*\r?\n\s*#\s*endif\b'
    Add-Check -Name 'fault_macro_exact_ground_diagnostic_role_guard' `
        -Passed (Test-Pattern $diagText $roleGuardPattern) `
        -Detail 'macro must fail compilation unless role is Ground diagnostics and never Vehicle'

    $latchMatches = [regex]::Matches($diagText,
        '\bbool\s+ground_hil_native_param_index_930_dropped\s*(?:=\s*false|\{\s*false\s*\})\s*;')
    Add-Check -Name 'one_shot_latch_single_false_declaration' `
        -Passed ($latchMatches.Count -eq 1) `
        -Detail 'one fixed bool latch starts false exactly once' `
        -Expected 1 -Actual $latchMatches.Count

    $helper = Get-CppFunctionRegion -Text $diagText -SignaturePattern `
        'bool\s+should_drop_ground_hil_native_param_index_930\s*\(\s*const\s+MavlinkFrame\s*&\s*frame\s*\)\s*noexcept\s*'
    Add-Check -Name 'fault_helper_exact_signature' -Passed ($null -ne $helper) `
        -Detail 'diagnostic helper has one fixed, noexcept, frame-only signature'
    if ($null -ne $helper) {
      [string]$body = $helper.body
      foreach ($condition in @(
          @('latch_rejects_second_drop',
            'if\s*\([\s\S]{0,2400}\bground_hil_native_param_index_930_dropped\b[\s\S]{0,2400}\)\s*\{?\s*return\s+false\s*;'),
          @('native_stream_strategy_only',
            'ground_parameter_proxy\s*\.\s*list_strategy\s*\(\s*\)\s*!=\s*GroundParameterListStrategy::NativeStream'),
          @('active_proxy_only',
            '!\s*ground_parameter_proxy\s*\.\s*active\s*\(\s*\)'),
          @('recovery_must_not_already_be_active',
            'ground_parameter_proxy\s*\.\s*native_stream_recovery_active\s*\(\s*\)'),
          @('expected_index_is_exactly_930',
            'ground_parameter_proxy\s*\.\s*expected_index\s*\(\s*\)\s*!=\s*930U?'),
          @('usb_host_must_be_present',
            '!\s*ground_usb_can_accept_downlink\s*\(\s*\)'),
          @('message_id_is_exactly_22',
            'frame\s*\.\s*message_id\s*!=\s*22U?'),
          @('source_system_is_exactly_1',
            'frame\s*\.\s*system_id\s*!=\s*1U?'),
          @('source_component_is_exactly_1',
            'frame\s*\.\s*component_id\s*!=\s*1U?'),
          @('payload_length_is_exactly_25',
            'frame\s*\.\s*payload_length\s*!=\s*25U?'),
          @('param_count_payload_offset_4',
            '(?:frame\s*\.\s*)?payload(?:\s*\(\s*\))?\s*(?:\+\s*4U?|\[\s*4U?\s*\])'),
          @('param_index_payload_offset_6',
            '(?:frame\s*\.\s*)?payload(?:\s*\(\s*\))?\s*(?:\+\s*6U?|\[\s*6U?\s*\])'),
          @('param_count_is_exactly_932',
            '\b(?:param_?count|count)\b\s*!=\s*932U?'),
          @('received_index_is_exactly_930',
            '\b(?:param_?index|index)\b\s*!=\s*930U?'),
          @('latch_set_once',
            'ground_hil_native_param_index_930_dropped\s*=\s*true\s*;[\s\S]{0,120}\breturn\s+true\s*;')
        )) {
        Add-Check -Name ([string]$condition[0]) `
            -Passed (Test-Pattern $body ([string]$condition[1])) `
            -Detail "fault helper must enforce $($condition[0])"
      }
      $latchTrueCount = [regex]::Matches($body,
          'ground_hil_native_param_index_930_dropped\s*=\s*true\s*;').Count
      $latchTrueMatch = [regex]::Match($body,
          'ground_hil_native_param_index_930_dropped\s*=\s*true\s*;')
      $falseReturnMatch = [regex]::Match($body, '\breturn\s+false\s*;')
      [int]$latchTrueIndex = if($latchTrueMatch.Success){$latchTrueMatch.Index}else{-1}
      [int]$falseReturnIndex = if($falseReturnMatch.Success){$falseReturnMatch.Index}else{-1}
      $runtimeBody = Remove-CppComments -Text $body
      Add-Check -Name 'one_shot_latch_single_true_write' `
          -Passed ($latchTrueCount -eq 1) `
          -Detail 'the exact matched frame consumes the only intentional drop' `
          -Expected 1 -Actual $latchTrueCount
      Add-Check -Name 'all_rejections_precede_one_shot_commit' `
          -Passed ($falseReturnIndex -ge 0 -and $latchTrueIndex -gt $falseReturnIndex) `
          -Detail 'all mismatch/state rejection paths run before the irreversible one-shot latch'
      Add-Check -Name 'fault_helper_has_no_runtime_ascii' `
          -Passed ($runtimeBody -notmatch '["'']|\b(?:Serial|printf|puts)\b') `
          -Detail 'fault injection emits no runtime ASCII and never writes a transport'
      Add-Check -Name 'fault_helper_has_no_dynamic_allocation' `
          -Passed ($runtimeBody -notmatch
            '\b(?:String|std::string|std::vector|malloc|calloc|realloc|free)\b|\bnew\s+|\bdelete\s+') `
          -Detail 'fault injection uses fixed storage only'
    }

    $handler = Get-CppFunctionRegion -Text $diagText -SignaturePattern `
        'void\s+handle_ground_validated_frame\s*\(\s*const\s+MavlinkFrame\s*&\s*frame\s*,\s*std::uint64_t\s+now_ms\s*\)\s*noexcept\s*'
    Add-Check -Name 'ground_validated_handler_present' -Passed ($null -ne $handler) `
        -Detail 'fault hook must be in the validated Ground frame handler'
    if ($null -ne $handler) {
      [string]$handlerText = $handler.text
      [string]$preclassToken =
          'ground_parameter_proxy.preclassify_vehicle_frame(frame, now_ms);'
      [string]$dropToken =
          'should_drop_ground_hil_native_param_index_930(frame)'
      $observerMatch = [regex]::Match($handlerText,
          'vc_lora_ground_diag_observer::observe_ground_validated_frame\s*\(\s*frame\s*,\s*now_ms\s*\)\s*;')
      [int]$observerIndex = if($observerMatch.Success){$observerMatch.Index}else{-1}
      [int]$updateIndex = $handlerText.IndexOf('update_ground_usb_connection(now_ms);')
      [int]$preclassIndex = $handlerText.IndexOf($preclassToken)
      [int]$consumedIndex = $handlerText.IndexOf(
          'GroundParameterProxyDisposition::Consumed', $preclassIndex + 1)
      [int]$invalidIndex = $handlerText.IndexOf(
          'GroundParameterProxyDisposition::Invalid', $preclassIndex + 1)
      [int]$dropIndex = $handlerText.IndexOf($dropToken)
      [int]$usbPresenceIndex = $handlerText.IndexOf(
          'if (!ground_usb_can_accept_downlink())')
      [int]$admissionIndex = $handlerText.IndexOf('admit_validated_frame')
      [int]$postAdmissionIndex = $handlerText.IndexOf('note_ground_usb_admission')
      [bool]$orderValid = ($observerIndex -ge 0 -and
          $observerIndex -lt $updateIndex -and $updateIndex -lt $preclassIndex -and
          $preclassIndex -lt $consumedIndex -and
          $consumedIndex -lt $invalidIndex -and $invalidIndex -lt $dropIndex -and
          $dropIndex -lt $usbPresenceIndex -and $usbPresenceIndex -lt $admissionIndex -and
          $admissionIndex -lt $postAdmissionIndex)
      Add-Check -Name 'fault_hook_exact_validated_pipeline_order' `
          -Passed $orderValid `
          -Detail ('required order is observer, connection update, preclassification ' +
            'Forward, one-shot drop, USB presence, admission, on_vehicle_frame commit') `
          -Actual ([ordered]@{observer=$observerIndex;update=$updateIndex
            preclassification=$preclassIndex;consumed=$consumedIndex
            invalid=$invalidIndex;drop=$dropIndex;usb_presence=$usbPresenceIndex
            admission=$admissionIndex;post_admission=$postAdmissionIndex})
      $dropCallCount = [regex]::Matches($handlerText,
          'should_drop_ground_hil_native_param_index_930\s*\(\s*frame\s*\)').Count
      Add-Check -Name 'fault_hook_called_exactly_once' `
          -Passed ($dropCallCount -eq 1) `
          -Detail 'one validated frame location owns the diagnostic intervention' `
          -Expected 1 -Actual $dropCallCount
      Add-Check -Name 'fault_hook_is_compile_time_opt_in' `
          -Passed (Test-Pattern $handlerText (
            '#\s*if\s+defined\s*\(\s*' + [regex]::Escape($faultMacro) +
            '\s*\)[\s\S]{0,240}should_drop_ground_hil_native_param_index_930\s*\(\s*frame\s*\)[\s\S]{0,160}\breturn\s*;[\s\S]{0,120}#\s*endif')) `
          -Detail 'the drop return is unavailable in the default diagnostic build'
    }
  }

  $sourceRoots = @(
      (Join-Path $RepoRoot 'core'),
      (Join-Path $RepoRoot 'firmware')) +
      @(Get-ChildItem -LiteralPath $RepoRoot -Directory |
        Where-Object { $_.Name -like 'vc_lora_*' } |
        ForEach-Object FullName)
  $macroSourceFiles = New-Object 'System.Collections.Generic.List[string]'
  foreach ($sourceRoot in $sourceRoots) {
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File |
        Where-Object {
          $_.Extension -in @('.ino','.h','.hpp','.cpp') -and
          $_.FullName -notmatch '[\\/]build[\\/]'
        }) {
      if ([System.IO.File]::ReadAllText($file.FullName).Contains($faultMacro)) {
        $macroSourceFiles.Add($file.FullName)
      }
    }
  }
  Add-Check -Name 'fault_macro_localized_to_one_diagnostic_ground_header' `
      -Passed ($macroSourceFiles.Count -eq 1 -and
        [string]$macroSourceFiles[0] -ceq $diagAdapter) `
      -Detail 'macro must not leak to core, canonical, production, Vehicle, or stable firmware' `
      -Expected @($diagAdapter) -Actual $macroSourceFiles.ToArray()

  $inoMacroFiles = New-Object 'System.Collections.Generic.List[string]'
  foreach ($ino in Get-ChildItem -LiteralPath $RepoRoot -Recurse -File `
      -Filter '*.ino' | Where-Object {
        $_.FullName -notmatch '[\\/](?:runs|build)[\\/]'
      }) {
    if ([System.IO.File]::ReadAllText($ino.FullName).Contains($faultMacro)) {
      $inoMacroFiles.Add($ino.FullName)
    }
  }
  Add-Check -Name 'all_default_sketches_leave_fault_disabled' `
      -Passed ($inoMacroFiles.Count -eq 0) `
      -Detail 'no checked-in .ino may opt into the directed fault' `
      -Expected 0 -Actual $inoMacroFiles.ToArray()

  if (-not $SkipCompile.IsPresent -and $failures.Count -eq 0) {
    if (-not (Test-Path -LiteralPath $ArduinoCli -PathType Leaf)) {
      Add-Check -Name 'arduino_cli_present' -Passed $false `
          -Detail "Arduino CLI missing: $ArduinoCli"
      $compileEvidence.status = 'CLI_MISSING'
    } else {
      $buildPath = Join-Path $OutputDirectory 'compile_build'
      [void][System.IO.Directory]::CreateDirectory($buildPath)
      $globalArgs = @()
      if ($IdeConfig -and (Test-Path -LiteralPath $IdeConfig -PathType Leaf)) {
        $globalArgs += @('--config-file', $IdeConfig)
      }
      $arguments = @($globalArgs + @(
        'compile','--fqbn',$Fqbn,'--warnings','all','--clean',
        '--build-path',$buildPath,
        '--build-property',
        ('compiler.cpp.extra_flags=-D' + $faultMacro + '=1'),
        '--json',(Split-Path -Parent $diagAdapter)))
      $output = @(& $ArduinoCli @arguments 2>&1)
      [int]$compileExit = $LASTEXITCODE
      $compileLog = [ordered]@{
        command=$ArduinoCli;arguments=$arguments;exit_code=$compileExit
        output=@($output | ForEach-Object { [string]$_ })
      }
      $compileLogPath = Join-Path $OutputDirectory 'compile_result.json'
      Write-JsonDurable -Path $compileLogPath -Value $compileLog
      $binary = Join-Path $buildPath `
          'vc_lora_ground_diag_v2_stable_xiao_esp32s3.ino.bin'
      [bool]$compilePassed = ($compileExit -eq 0 -and
          (Test-Path -LiteralPath $binary -PathType Leaf))
      $compileEvidence.status = if($compilePassed){'PASS'}else{'FAIL'}
      $compileEvidence.exit_code = $compileExit
      $compileEvidence.success = $compilePassed
      $compileEvidence.binary_path = if($compilePassed){$binary}else{$null}
      $compileEvidence.binary_sha256 = if($compilePassed){
        Get-Sha256 -Path $binary
      }else{$null}
      $compileEvidence.output_file = 'compile_result.json'
      Add-Check -Name 'diagnostic_ground_fault_variant_compiles' `
          -Passed $compilePassed `
          -Detail 'Ground diagnostic firmware must compile with only the explicit index-930 macro enabled' `
          -Expected 0 -Actual $compileExit
    }
  } elseif (-not $SkipCompile.IsPresent) {
    $compileEvidence.status = 'NOT_RUN_STATIC_FAILURE'
  }
} catch {
  $unexpectedFailure = $_.Exception.ToString()
  $failures.Add('unexpected_exception: ' + $_.Exception.Message)
}

$status = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
$summary = [ordered]@{
  schema_version=1
  test_id=$testId
  status=$status
  started_with_fault_macro_disabled_in_ino=$true
  fault_contract=[ordered]@{
    macro=$faultMacro;index=930;received_future_index=931
    expected_param_count=932;message_id=22;source_system=1
    source_component=1;payload_length=25;one_shot=$true
  }
  expected_production_adapter_sha256=$expectedProductionAdapterSha256
  source_hashes=$sourceHashes
  compile=$compileEvidence
  checks=$checks.ToArray()
  failed_count=$failures.Count
  failures=$failures.ToArray()
  unexpected_failure=$unexpectedFailure
  checker_sha256=Get-Sha256 -Path $contractScript
  finished_utc=[DateTime]::UtcNow.ToString('o')
  durability=[ordered]@{
    json_file_mode='CreateNew';file_options='WriteThrough';flush='Flush(true)'
  }
}

$summaryPath = Join-Path $OutputDirectory 'summary.json'
Write-JsonDurable -Path $summaryPath -Value $summary
$artifactRows = @(
  [pscustomobject][ordered]@{
    file='summary.json';sha256=(Get-Sha256 -Path $summaryPath)
    bytes=(Get-Item -LiteralPath $summaryPath).Length
  }
)
if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'compile_result.json')) {
  $compileResultPath = Join-Path $OutputDirectory 'compile_result.json'
  $artifactRows += [pscustomobject][ordered]@{
    file='compile_result.json';sha256=(Get-Sha256 -Path $compileResultPath)
    bytes=(Get-Item -LiteralPath $compileResultPath).Length
  }
}
Write-JsonDurable -Path (Join-Path $OutputDirectory 'artifact_hashes.json') `
    -Value $artifactRows

Write-Output ("$status $testId summary=$summaryPath failed=$($failures.Count)")
if ($status -ceq 'PASS') { exit 0 }
exit 1
